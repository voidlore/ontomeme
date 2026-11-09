# shellcheck shell=bash disable=SC2034  # FIXTURE_REASON and CASE_OUT are read by the sourcing tests
# Fixtures and a tiny test harness for the scripts/sign tests. Source it:
#   . "$(dirname "$0")/lib_fixtures.sh"
# Synthetic fixtures are built at test time with openssl and python3 (stdlib);
# nothing here touches ~/Documents/Ontomeme or the repo's .godot.

# --- harness ---------------------------------------------------------------

TESTS_FAILED=0
CASE_OUT=""

t_pass() { echo "PASS  $1"; }
t_skip() { echo "SKIP  $1"; }
t_fail() {
  echo "FAIL  $1: $2"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

# check_case NAME WANT_EXIT [--has TEXT | --lacks TEXT | --match ERE]... -- CMD [ARG]...
# Runs CMD with stdout and stderr captured in CASE_OUT. PASS when it exits
# WANT_EXIT, the output holds every --has text and --match pattern, and no
# --lacks text.
check_case() {
  local name="$1" want="$2" code=0 kind value
  local -a checks=()
  shift 2
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    checks+=("$1" "$2")
    shift 2
  done
  shift
  CASE_OUT="$("$@" 2>&1)" || code=$?
  if [ "$code" != "$want" ]; then
    t_fail "$name" "exit $code, wanted $want; output: $(printf '%s' "$CASE_OUT" | tail -n 4 | tr '\n' '|')"
    return 0
  fi
  set -- "${checks[@]}"
  while [ $# -gt 0 ]; do
    kind="$1" value="$2"
    shift 2
    case "$kind" in
      --has) grep -qF -- "$value" <<<"$CASE_OUT" || { t_fail "$name" "output lacks '$value'"; return 0; } ;;
      --lacks) ! grep -qF -- "$value" <<<"$CASE_OUT" || { t_fail "$name" "output has '$value'"; return 0; } ;;
      --match) grep -qE -- "$value" <<<"$CASE_OUT" || { t_fail "$name" "output does not match /$value/"; return 0; } ;;
      *) t_fail "$name" "check_case: unknown check $kind"; return 0 ;;
    esac
  done
  t_pass "$name"
}

# t_finish: the exit status of a test script.
t_finish() {
  if [ "$TESTS_FAILED" -eq 0 ]; then return 0; fi
  echo "$TESTS_FAILED case(s) failed"
  return 1
}

# --- certificates ----------------------------------------------------------

TEST_DEVID_CN="Developer ID Application: Test Person (ABCDE12345)"

# fixture_cert OUT SUBJECT [ISSUER] [openssl req args...]
# Writes OUT.key and OUT.pem: an EC P-256 certificate, self-signed or issued
# by ISSUER (ISSUER.pem + ISSUER.key). Extra args go to `openssl req -x509`.
fixture_cert() {
  local out="$1" subject="$2" issuer="${3:-}"
  local -a args=(req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes
    -keyout "$out.key" -out "$out.pem" -subj "$subject" -days 30)
  shift $(($# < 3 ? $# : 3))
  if [ -n "$issuer" ]; then args+=(-CA "$issuer.pem" -CAkey "$issuer.key"); fi
  openssl "${args[@]}" "$@" 2>/dev/null
}

# fixture_signing_certs DIR: DIR/ca (CN Developer ID Certification Authority),
# DIR/devid (CN $TEST_DEVID_CN, issued by DIR/ca) and DIR/dev (a self-signed
# 'Apple Development' certificate, which is not a Developer ID one).
fixture_signing_certs() {
  local dir="$1"
  fixture_cert "$dir/ca" "/CN=Developer ID Certification Authority/OU=G2/O=Test CA/C=US" "" \
    -addext "basicConstraints=critical,CA:true" -addext "keyUsage=critical,keyCertSign,cRLSign" &&
    fixture_cert "$dir/devid" "/CN=$TEST_DEVID_CN/OU=ABCDE12345/O=Test Person/C=US" "$dir/ca" \
      -addext "extendedKeyUsage=codeSigning" &&
    fixture_cert "$dir/dev" "/CN=Apple Development: Test Person (ABCDE12345)/OU=ABCDE12345/C=US" "" \
      -addext "extendedKeyUsage=codeSigning"
}

# fixture_cms IN OUT SIGNER [CHAIN]: a detached CMS signature over IN, DER.
fixture_cms() {
  local -a args=(cms -sign -binary -outform DER -in "$1" -out "$2" -signer "$3.pem" -inkey "$3.key")
  if [ -n "${4:-}" ]; then args+=(-certfile "$4.pem"); fi
  openssl "${args[@]}"
}

# --- binaries --------------------------------------------------------------

# fixture_py COMMAND ARGS...: build a binary fixture.
#   codedirectory OUT FLAGS IDENT TEAM   a CodeDirectory blob (TEAM may be '')
#   macho OUT ARCH [CD CMS|- [ENTS]]     thin 64-bit Mach-O; no CD = unsigned,
#                                        CMS '-' = an empty CMS blob (ad-hoc),
#                                        ENTS = the entitlements plist (slot 5)
#   fat OUT SLICE...                     fat Mach-O from thin slices
#   pe OUT intact|missing|corrupt [DER]  PE32+ with a 'pck' section; DER = a
#                                        PKCS#7 in the security directory
#   pe_sign FILE DER                     append DER as FILE's Authenticode
#                                        WIN_CERTIFICATE, in place
#   zip OUT DIR                          zip DIR's files, keeping their modes
fixture_py() {
  python3 -I - "$@" <<'PY'
import os, struct, sys, zipfile

ARCHS = {"x86_64": (0x01000007, 3), "arm64": (0x0100000C, 0)}

def codedirectory(out, flags, ident, team):
    ident_b = ident.encode() + b"\0"
    team_b = team.encode() + b"\0" if team else b""
    header = 88
    ident_off = header
    team_off = header + len(ident_b) if team else 0
    hash_off = header + len(ident_b) + len(team_b)
    length = hash_off
    blob = struct.pack(">IIIIIIIIIBBBBIIIIQQQQ", 0xFADE0C02, length, 0x20400, int(flags, 0),
                       hash_off, ident_off, 0, 0, 0x1000, 32, 2, 0, 12, 0, 0, team_off, 0, 0, 0, 0, 0)
    open(out, "wb").write(blob + ident_b + team_b)

EMPTY_ENTITLEMENTS = b'<?xml version="1.0"?><plist version="1.0"><dict/></plist>'

def superblob(cd, cms, ents_xml=EMPTY_ENTITLEMENTS):
    blobs = [(0, cd), (5, struct.pack(">II", 0xFADE7171, 8 + len(ents_xml)) + ents_xml),
             (0x10000, struct.pack(">II", 0xFADE0B01, 8 + len(cms)) + cms)]
    offset = 12 + 8 * len(blobs)
    index, body = b"", b""
    for slot, blob in blobs:
        index += struct.pack(">II", slot, offset + len(body))
        body += blob
    return struct.pack(">III", 0xFADE0CC0, offset + len(body), len(blobs)) + index + body

def macho(out, arch, cd=None, cms=None, ents=None):
    cputype, subtype = ARCHS[arch]
    uuid_cmd = struct.pack("<II16s", 0x1B, 24, b"fixture-uuid-016")
    code = b"\xc3" * 256
    cmds, sig = uuid_cmd, b""
    if cd:
        ents_xml = open(ents, "rb").read() if ents else EMPTY_ENTITLEMENTS
        sig = superblob(open(cd, "rb").read(), b"" if cms == "-" else open(cms, "rb").read(), ents_xml)
        dataoff = 32 + len(uuid_cmd) + 16 + len(code)
        cmds += struct.pack("<IIII", 0x1D, 16, dataoff, len(sig))
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, cputype, subtype, 2, 2 if cd else 1, len(cmds), 0, 0)
    open(out, "wb").write(header + cmds + code + sig)

def fat(out, *slices):
    datas = [open(s, "rb").read() for s in slices]
    entries, body, offset = b"", b"", 0x4000
    for data in datas:
        cputype, subtype = struct.unpack_from("<II", data, 4)
        entries += struct.pack(">IIIII", cputype, subtype, offset + len(body), len(data), 14)
        body += data + b"\0" * (-len(data) % 0x4000)
    header = struct.pack(">II", 0xCAFEBABE, len(datas)) + entries
    open(out, "wb").write(header + b"\0" * (0x4000 - len(header)) + body)

def pe(out, pck, der=None):
    sections = [(b".text", b"\xc3" * 0x200)]
    if pck != "missing":
        magic = b"GDPC" if pck == "intact" else b"XXXX"
        sections.append((b"pck", magic + b"\x04\0\0\0" + b"\0" * (0x200 - 8)))
    optional_at, optional_size = 0x40 + 24, 112 + 16 * 8
    raw = 0x400
    image = bytearray(b"MZ" + b"\0" * 0x3A + struct.pack("<I", 0x40))
    image += b"PE\0\0" + struct.pack("<HHIIIHH", 0x8664, len(sections), 0, 0, 0, optional_size, 0x22)
    optional = bytearray(optional_size)
    struct.pack_into("<H", optional, 0, 0x20B)
    struct.pack_into("<I", optional, 108, 16)
    image += optional
    for name, data in sections:
        image += struct.pack("<8sIIIIIIHHI", name, len(data), raw, len(data), raw, 0, 0, 0, 0, 0x60000020)
        raw += len(data)
    image += b"\0" * (0x400 - len(image))
    for _, data in sections:
        image += data
    if der:
        cert = open(der, "rb").read()
        entry = struct.pack("<IHH", 8 + len(cert), 0x0200, 0x0002) + cert
        entry += b"\0" * (-len(entry) % 8)
        struct.pack_into("<II", image, optional_at + 112 + 4 * 8, len(image), len(entry))
        image += entry
    open(out, "wb").write(bytes(image))

def pe_sign(path, der):
    image = bytearray(open(path, "rb").read())
    optional = struct.unpack_from("<I", image, 0x3C)[0] + 24
    directories = optional + (112 if struct.unpack_from("<H", image, optional)[0] == 0x20B else 96)
    cert = open(der, "rb").read()
    entry = struct.pack("<IHH", 8 + len(cert), 0x0200, 0x0002) + cert
    entry += b"\0" * (-len(entry) % 8)
    image += b"\0" * (-len(image) % 8)
    struct.pack_into("<II", image, directories + 4 * 8, len(image), len(entry))
    open(path, "wb").write(bytes(image + entry))

def zip_dir(out, root):
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for parent, dirs, names in os.walk(root):
            dirs.sort()
            for name in sorted(names):
                full = os.path.join(parent, name)
                info = zipfile.ZipInfo(os.path.relpath(full, root))
                info.external_attr = (os.stat(full).st_mode & 0xFFFF) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, open(full, "rb").read())

command, args = sys.argv[1], sys.argv[2:]
{"codedirectory": codedirectory, "macho": macho, "fat": fat, "pe": pe, "pe_sign": pe_sign,
 "zip": zip_dir}[command](*args)
PY
}

# fixture_macho OUT ARCH unsigned|adhoc|signed [SIGNER [CHAIN]]
# A thin Mach-O: no signature; ad-hoc (flags adhoc|runtime, empty CMS); or a
# CMS signature by SIGNER over its CodeDirectory (flags runtime, team ABCDE12345).
# A signature carries the entitlements plist at $FIXTURE_ENTITLEMENTS when that
# is set, else an empty one.
fixture_macho() {
  local out="$1" arch="$2" kind="$3" signer="${4:-}" chain="${5:-}" ents="${FIXTURE_ENTITLEMENTS:-}"
  case "$kind" in
    unsigned) fixture_py macho "$out" "$arch" ;;
    adhoc)
      fixture_py codedirectory "$out.cd" 0x10002 com.example.fixture "" &&
        fixture_py macho "$out" "$arch" "$out.cd" - "$ents"
      ;;
    signed)
      fixture_py codedirectory "$out.cd" 0x10000 com.example.fixture ABCDE12345 &&
        fixture_cms "$out.cd" "$out.cms" "$signer" "$chain" &&
        fixture_py macho "$out" "$arch" "$out.cd" "$out.cms" "$ents"
      ;;
    *) echo "fixture_macho: unknown kind $kind" >&2; return 1 ;;
  esac
}

# fixture_app DIR NAME MACHO [stapled]: DIR/NAME.app holding MACHO as its
# executable, an _CodeSignature/CodeResources seal and, with 'stapled', a
# Contents/CodeResources notarization ticket stand-in.
fixture_app() {
  local app="$1/$2.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/_CodeSignature" "$app/Contents/Resources"
  cp -f "$3" "$app/Contents/MacOS/$2"
  chmod 755 "$app/Contents/MacOS/$2"
  printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n' >"$app/Contents/Info.plist"
  printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n' >"$app/Contents/_CodeSignature/CodeResources"
  if [ "${4:-}" = stapled ]; then printf 'stand-in notarization ticket' >"$app/Contents/CodeResources"; fi
}

# --- real Godot exports (opt-in) -------------------------------------------

FIXTURE_REASON=""

# fixture_godot_exports DIR: export the 'macOS' and 'Windows x86_64' presets of
# `git archive HEAD` to DIR/Ontomeme.zip and DIR/Ontomeme.exe with $GODOT, the
# XDG config, data and cache dirs under DIR (XDG_DOCUMENTS_DIR too), and the
# export templates symlinked in. HOME stays the caller's: a launcher such as
# ~/.local/bin/godot finds the engine through it.
# Returns 0 when both exist, 2 (skip) without $GODOT or templates, 1 on failure;
# FIXTURE_REASON says why.
fixture_godot_exports() {
  local dir="$1" repo version templates sandbox src preset target
  if [ -z "${GODOT:-}" ]; then FIXTURE_REASON="GODOT is not set"; return 2; fi
  version="$("$GODOT" --version 2>/dev/null | sed -E 's/^([0-9.]*[0-9]\.[a-z]+[0-9]*).*/\1/')"
  templates="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$version"
  if [ -z "$version" ] || [ ! -d "$templates" ]; then
    FIXTURE_REASON="no export templates at $templates"
    return 2
  fi
  repo="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)" || {
    FIXTURE_REASON="not in a git checkout"
    return 1
  }
  sandbox="$dir/sandbox" src="$dir/src"
  mkdir -p "$src" "$sandbox/config" "$sandbox/cache" "$sandbox/Documents" "$sandbox/data/godot/export_templates"
  ln -s "$templates" "$sandbox/data/godot/export_templates/$version"
  printf 'XDG_DOCUMENTS_DIR="%s"\n' "$sandbox/Documents" >"$sandbox/config/user-dirs.dirs"
  git -C "$repo" archive HEAD | tar -x -C "$src"
  godot_sandboxed() {
    XDG_CONFIG_HOME="$sandbox/config" XDG_DATA_HOME="$sandbox/data" XDG_CACHE_HOME="$sandbox/cache" \
      timeout 600 "$GODOT" --headless --path "$src" "$@"
  }
  godot_sandboxed --import >"$dir/import.log" 2>&1 || true
  for preset in "macOS:Ontomeme.zip" "Windows x86_64:Ontomeme.exe"; do
    target="$dir/${preset#*:}"
    godot_sandboxed --export-release "${preset%%:*}" "$target" >"$dir/export.log" 2>&1
    if [ ! -s "$target" ]; then
      FIXTURE_REASON="export of '${preset%%:*}' failed: $(tail -n 3 "$dir/export.log" | tr '\n' ' ')"
      return 1
    fi
  done
  return 0
}

# fixture_p12 OUT CERT PASSWORD [CHAIN [EXPORT ARGS...]]: CERT.pem + CERT.key
# (plus CHAIN.pem after them; '' for none) as a .p12 file under PASSWORD
# (passed through the environment). EXPORT ARGS go to `openssl pkcs12 -export`:
# P12_MODERN for OpenSSL 3's default format whatever this openssl's default,
# P12_RCODESIGN for the one rcodesign 0.29 reads, -legacy for Keychain Access's.
P12_MODERN=(-certpbe AES-256-CBC -keypbe AES-256-CBC -macalg sha256)
P12_RCODESIGN=(-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1)
fixture_p12() {
  local out="$1" cert="$2" password="$3" chain="${4:-}"
  shift $(($# < 4 ? $# : 4))
  local -a args=(pkcs12 -export -inkey "$cert.key" -in "$cert.pem" -passout env:FIXTURE_P12_PASSWORD -out "$out")
  if [ -n "$chain" ]; then args+=(-certfile "$chain.pem"); fi
  FIXTURE_P12_PASSWORD="$password" openssl "${args[@]}" "$@"
}

# file_mode FILE: its permission bits in octal, e.g. 600.
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# --- stand-in tools ----------------------------------------------------------
# Each stub logs one line per call to $STUB_LOG, "<tool> <args, %q-quoted>",
# plus "fact ..." lines with what it saw (file modes, which env was set), so
# tests can assert argument shapes and that no secret reached argv.

# fixture_stub_start DIR NAME: begin the executable stub DIR/NAME; the caller
# appends its body. The stub can source this file from $SIGN_DIR.
fixture_stub_start() {
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\n# Stand-in %s for the scripts/sign tests (written by lib_fixtures.sh).\nSIGN_DIR=%q\n' \
    "$2" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" >"$1/$2"
  cat >>"$1/$2" <<'STUB'
set -uo pipefail
# shellcheck source=/dev/null
. "$SIGN_DIR/lib_fixtures.sh"
stub_log() { printf '%s\n' "$*" >>"${STUB_LOG:-/dev/null}"; }
STUB
  chmod 755 "$1/$2"
}

# fixture_curl_stub DIR: DIR/curl, accepting only `curl -fsSL -o PATH URL`; it
# writes the file $STUB_CURL_BODY to PATH, or fails like an HTTP 404 when that
# is unset.
fixture_curl_stub() {
  fixture_stub_start "$1" curl
  cat >>"$1/curl" <<'STUB'
stub_log "curl $(printf '%q ' "$@")"
out="" url="" opts=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o | --output) out="${2:-}"; shift 2 ;;
    -O | --remote-name) echo "curl stand-in: -O is not allowed, use -o PATH" >&2; exit 2 ;;
    -*) opts="$opts $1"; shift ;;
    *) url="$1"; shift ;;
  esac
done
if [[ "$opts " != *" -fsSL "* ]] || [ -z "$out" ] || [ -z "$url" ]; then
  echo "curl stand-in: wanted curl -fsSL -o PATH URL" >&2
  exit 2
fi
if [ -z "${STUB_CURL_BODY:-}" ]; then
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
cat "$STUB_CURL_BODY" >"$out"
STUB
}

# fixture_rcodesign_stub DIR: DIR/rcodesign, enough of apple-codesign 0.29 for
# macos_sign.sh and macos_notarize.sh. `sign` opens the .p12 with the password
# file the way rcodesign 0.29.0 does (only a SHA-1 MAC and SHA-1 RC2/3DES
# encryption; the last certificate in the file is the signer, with no chain)
# and re-signs every architecture of X.app/Contents/MacOS/X with it (keeping
# the entitlements, like rcodesign, or taking --entitlements-xml-path); it logs
# what the .p12 held. `notary-submit --staple` writes the ticket
# stand-in X.app/Contents/CodeResources; `verify` takes one Mach-O file, never
# a bundle. $STUB_RCODESIGN lists modes, comma
# separated: old-help (sign --help lacks --for-notarization), fail-sign,
# fail-verify, drop-entitlements (unless --entitlements-xml-path is given),
# drop-entitlements-always, edit-info-plist, notary-invalid, notary-auth-fail,
# notary-hang, no-ticket (accepted, but --staple writes no ticket). Its
# submission ID is $STUB_SUBMISSION_ID.
STUB_SUBMISSION_ID=4a2a6f1e-0c1d-4b8e-9f00-5e1ec7ab1e00
fixture_rcodesign_stub() {
  fixture_stub_start "$1" rcodesign
  cat >>"$1/rcodesign" <<'STUB'
stub_mode() { [[ ",${STUB_RCODESIGN:-}," == *",$1,"* ]]; }
stub_log "rcodesign $(printf '%q ' "$@")"
tmp=""
trap 'if [ -n "$tmp" ]; then rm -rf "$tmp"; fi' EXIT

stub_sign_help() {
  echo "Usage: rcodesign sign [OPTIONS] <INPUT_PATH> [OUTPUT_PATH]"
  echo "      --p12-file <PATH>"
  echo "      --p12-password-file <PATH>"
  echo "      --code-signature-flags <SCOPE:FLAG>"
  echo "      --entitlements-xml-file <SCOPE:PATH>"
  if ! stub_mode old-help; then echo "      --for-notarization"; fi
}

# stub_open_p12 P12 PASSWORD_FILE DIR: DIR/signer.pem and DIR/signer.key as
# rcodesign 0.29.0 reads P12 (apple-codesign cryptography.rs parse_pfx_data on
# the p12 0.6.3 crate): verify_mac is HMAC-SHA1 only, so any other MAC is an
# 'incorrect password'; PBES2 (AES) bags do not decrypt; and each certificate
# bag replaces the one before, so the last certificate is the signer.
stub_open_p12() {
  local p12="$1" pass="$2" dir="$3" info mode=""
  if ! info="$(openssl pkcs12 -info -noout -in "$p12" -passin "file:$pass" 2>&1)"; then
    mode=-legacy
    info="$(openssl pkcs12 -legacy -info -noout -in "$p12" -passin "file:$pass" 2>&1)" ||
      { echo "Error: incorrect password given when decrypting PFX data" >&2; return 1; }
  fi
  stub_log "fact p12 $(grep -E '^(MAC:|PKCS7 Encrypted data:|Shrouded Keybag:)' <<<"$info" | sed 's/, Iteration.*//' | tr '\n' ';')"
  if ! grep -q '^MAC: sha1,' <<<"$info"; then
    echo "Error: incorrect password given when decrypting PFX data" >&2
    return 1
  fi
  if grep -q 'PBES2' <<<"$info"; then
    echo "Error: PFX data parse error: failed decrypting inner EncryptedData" >&2
    return 1
  fi
  # shellcheck disable=SC2086 # $mode is one optional word
  openssl pkcs12 $mode -in "$p12" -passin "file:$pass" -nokeys -out "$dir/certs.pem" 2>/dev/null &&
    openssl pkcs12 $mode -in "$p12" -passin "file:$pass" -nocerts -nodes -out "$dir/signer.key" 2>/dev/null || {
    echo "Error: incorrect password given when decrypting PFX data" >&2
    return 1
  }
  awk '/-----BEGIN CERTIFICATE-----/ { cert = ""; on = 1 } on { cert = cert $0 "\n" }
    /-----END CERTIFICATE-----/ { on = 0; last = cert; n++ } END { printf "%s", last; exit n == 0 }' \
    "$dir/certs.pem" >"$dir/signer.pem" || { echo "Error: PFX data parse error: failed to find x509 certificate in PFX data" >&2; return 1; }
  stub_log "fact p12-certs=$(grep -c 'BEGIN CERTIFICATE' "$dir/certs.pem")"
  if [ "$(openssl x509 -in "$dir/signer.pem" -noout -pubkey)" != "$(openssl pkey -in "$dir/signer.key" -pubout)" ]; then
    echo "error: rcodesign 0.29 signs with the last certificate in the .p12, $(openssl x509 -in "$dir/signer.pem" -noout -subject), which is not the key's (stand-in)" >&2
    return 1
  fi
}

stub_sign() {
  local p12="" pass="" ents="" app="" exe use="" arch
  local -a slices=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help) stub_sign_help; return 0 ;;
      --p12-file) p12="$2"; shift 2 ;;
      --p12-password-file) pass="$2"; shift 2 ;;
      --entitlements-xml-path | --entitlements-xml-file) ents="$2"; shift 2 ;;
      --code-signature-flags) shift 2 ;;
      --for-notarization) shift ;;
      -*) echo "error: unexpected argument '$1'" >&2; return 2 ;;
      *) app="$1"; shift ;;
    esac
  done
  if stub_mode fail-sign; then echo "error: stand-in signing failure" >&2; return 1; fi
  exe="$app/Contents/MacOS/$(basename "$app" .app)"
  if [ ! -f "$p12" ] || [ ! -f "$pass" ] || [ ! -f "$exe" ]; then
    echo "error: missing --p12-file, --p12-password-file or $exe" >&2
    return 1
  fi
  stub_log "fact p12-mode=$(file_mode "$p12") password-mode=$(file_mode "$pass")"
  stub_log "fact clear-keys-beside-p12=$(grep -rlI 'PRIVATE KEY' "$(dirname "$p12")" 2>/dev/null | wc -l | tr -d ' ')"
  tmp="$(mktemp -d)"
  if ! stub_open_p12 "$p12" "$pass" "$tmp"; then return 1; fi
  python3 -I - "$SIGN_DIR" "$exe" "$tmp" <<'PY' || return 1
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import check_signatures as cs
exe, tmp = sys.argv[2:4]
with cs.mapped_path(exe) as buf, open(f"{tmp}/arches", "w") as arches:
    for arch, offset, size in cs.macho_slices(buf):
        arches.write(arch + "\n")
        sig = cs.code_signature(buf, offset, size)
        for slot, _magic, blob in cs.superblob_slots(sig) if sig else ():
            if slot == cs.CSSLOT_ENTITLEMENTS:
                open(f"{tmp}/entitlements.xml", "wb").write(bytes(blob[8:]))
PY
  if [ -n "$ents" ] && ! stub_mode drop-entitlements-always; then
    use="$ents"
  elif stub_mode drop-entitlements || stub_mode drop-entitlements-always; then
    use=""
  elif [ -s "$tmp/entitlements.xml" ]; then
    use="$tmp/entitlements.xml"
  fi
  while read -r arch; do
    FIXTURE_ENTITLEMENTS="$use" fixture_macho "$tmp/$arch" "$arch" signed "$tmp/signer" || return 1
    slices+=("$tmp/$arch")
  done <"$tmp/arches"
  if [ ${#slices[@]} -gt 1 ]; then
    fixture_py fat "$tmp/signed" "${slices[@]}" || return 1
  else
    cp -f "${slices[0]}" "$tmp/signed"
  fi
  cat "$tmp/signed" >"$exe"
  mkdir -p "$app/Contents/_CodeSignature"
  printf '<plist><dict><key>stand-in</key><string>seal</string></dict></plist>\n' \
    >"$app/Contents/_CodeSignature/CodeResources"
  if stub_mode edit-info-plist; then
    sed -i.orig 's/NSDocumentsFolderUsageDescription/NSDocumentsFolderUsageDescriptionGone/' "$app/Contents/Info.plist"
    rm -f "$app/Contents/Info.plist.orig"
  fi
  echo "signing $app in place (stand-in)" >&2
}

# stub_verify PATH: like rcodesign 0.29 verify, which reads one Mach-O file and
# refuses any other path, a .app bundle directory too; it fails when an
# architecture carries no embedded signature.
stub_verify() {
  if [ $# -ne 1 ]; then echo "error: wanted verify PATH" >&2; return 2; fi
  if stub_mode fail-verify; then echo "error: stand-in verification failure" >&2; return 1; fi
  python3 -I - "$SIGN_DIR" "$1" <<'PY'
import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import check_signatures as cs
path = sys.argv[2]
if os.path.isdir(path):
    kind = "Bundle"
elif not os.path.isfile(path):
    sys.exit("Error: I/O error: No such file or directory (os error 2)")
else:
    with open(path, "rb") as f:
        kind = "MachO" if cs.is_macho(f.read(8)) else "Other"
if kind != "MachO":
    sys.exit(f"Error: verify command only works on Mach-O binaries; provided path is a {kind}")
with cs.mapped_path(path) as buf:
    for arch, offset, size in cs.macho_slices(buf):
        if cs.code_signature(buf, offset, size) is None:
            sys.exit(f"Error: {arch}: no embedded code signature")
print("no problems detected!", file=sys.stderr)
PY
}

stub_encode_key() {
  local out=""
  local -a pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -o | --output-path) out="$2"; shift 2 ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  if [ ${#pos[@]} -ne 3 ] || [ ! -f "${pos[2]}" ] || ! openssl pkey -in "${pos[2]}" -noout 2>/dev/null; then
    echo "error: wanted encode-app-store-connect-api-key -o OUT ISSUER_ID KEY_ID PRIVATE_KEY_PATH" >&2
    return 2
  fi
  stub_log "fact p8-mode=$(file_mode "${pos[2]}")"
  python3 -I -c 'import json, sys
json.dump({"issuer_id": sys.argv[1], "key_id": sys.argv[2], "private_key": open(sys.argv[3]).read()},
          open(sys.argv[4], "w"))' "${pos[0]}" "${pos[1]}" "${pos[2]}" "${out:-/dev/stdout}"
  echo "writing unified key JSON to ${out:-stdout}" >&2
}

stub_notary_submit() {
  local key="" app="" staple=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --api-key-file | --api-key-path) key="$2"; shift 2 ;;
      --max-wait-seconds) shift 2 ;;
      --staple) staple=true; shift ;;
      --wait) shift ;;
      -*) echo "error: unexpected argument '$1'" >&2; return 2 ;;
      *) app="$1"; shift ;;
    esac
  done
  if [ ! -f "$key" ] || [ ! -e "$app" ]; then echo "error: missing --api-key-file or the path" >&2; return 1; fi
  stub_log "fact key-json-mode=$(file_mode "$key")"
  if stub_mode notary-auth-fail; then echo "error: HTTP 401 Unauthorized from the Notary API" >&2; return 1; fi
  echo "creating Notary API submission for $(basename "$app") (sha256: stand-in)" >&2
  echo "created submission ID: $STUB_SUBMISSION_ID" >&2
  echo "waiting up to 600s for package upload $STUB_SUBMISSION_ID to finish processing" >&2
  if stub_mode notary-hang; then sleep 30; fi
  if stub_mode notary-invalid; then
    echo "poll state after 5s: Invalid" >&2
    echo "Notary API Server has finished processing the uploaded asset" >&2
    echo "Error: notarization package is invalid" >&2
    return 1
  fi
  echo "poll state after 5s: Accepted" >&2
  if [ "$staple" = true ] && ! stub_mode no-ticket; then
    printf 'stand-in notarization ticket' >"$app/Contents/CodeResources"
  fi
}

stub_notary_log() {
  local key="" id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --api-key-file | --api-key-path) key="$2"; shift 2 ;;
      *) id="$1"; shift ;;
    esac
  done
  if [ ! -f "$key" ] || [ -z "$id" ]; then echo "error: wanted notary-log --api-key-file F ID" >&2; return 2; fi
  printf '{\n  "jobId": "%s",\n  "status": "Invalid",\n  "issues": [\n    {"severity": "error", "path": "Ontomeme.app/Contents/MacOS/Ontomeme",\n     "message": "The binary is not signed with a valid Developer ID certificate."}\n  ]\n}\n' "$id"
}

command="${1:-}"
shift || true
case "$command" in
  sign) stub_sign "$@" ;;
  verify) stub_verify "$@" ;;
  encode-app-store-connect-api-key) stub_encode_key "$@" ;;
  notary-submit) stub_notary_submit "$@" ;;
  notary-log) stub_notary_log "$@" ;;
  *) echo "error: the rcodesign stand-in has no '$command' command" >&2; exit 2 ;;
esac
STUB
}

# fixture_jsign_stub DIR: DIR/jsign, enough of jsign 7.5 for windows_sign.sh,
# and DIR/java, which runs `java -jar X.jar ARGS` as DIR/jsign ARGS. A PKCS12
# --keystore is opened with --storepass (env:NAME, file:PATH or literal); any
# other storetype signs with the fixture certificate $STUB_JSIGN_SIGNER (.pem
# and .key). The signature is appended to the exe in place. $STUB_JSIGN lists
# modes: fail, corrupt-pck (the signed exe loses its pck section's GDPC).
fixture_jsign_stub() {
  fixture_stub_start "$1" jsign
  cat >>"$1/jsign" <<'STUB'
stub_mode() { [[ ",${STUB_JSIGN:-}," == *",$1,"* ]]; }
stub_log "jsign $(printf '%q ' "$@")"
stub_log "fact storepass-env=${WIN_SIGN_STOREPASS:+set} keypass-env=${WIN_SIGN_KEYPASS:+set}"
tmp=""
trap 'if [ -n "$tmp" ]; then rm -rf "$tmp"; fi' EXIT

# stub_secret VALUE: a jsign password argument resolved like jsign does.
stub_secret() {
  case "$1" in
    env:*) local name="${1#env:}"; printf '%s' "${!name-}" ;;
    file:*) head -n 1 "${1#file:}" ;;
    *) printf '%s' "$1" ;;
  esac
}

storetype="" keystore="" storepass="" file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --storetype) storetype="$2"; shift 2 ;;
    -s | --keystore) keystore="$2"; shift 2 ;;
    --storepass) storepass="$2"; shift 2 ;;
    -a | --alias | --keypass | -n | --name | -u | --url | -d | --alg | -t | --tsaurl | -m | --tsmode) shift 2 ;;
    --replace | --quiet) shift ;;
    -*) echo "jsign: Unrecognized option: $1" >&2; exit 1 ;;
    *) file="$1"; shift ;;
  esac
done
if stub_mode fail; then echo "jsign: Couldn't sign $file (stand-in failure)" >&2; exit 1; fi
if [ ! -f "$file" ]; then echo "jsign: Couldn't find $file" >&2; exit 1; fi
tmp="$(mktemp -d)"
if [ "$storetype" = PKCS12 ]; then
  stub_log "fact keystore-mode=$(file_mode "$keystore")"
  export STUB_STOREPASS
  STUB_STOREPASS="$(stub_secret "$storepass")"
  if ! openssl pkcs12 -in "$keystore" -passin env:STUB_STOREPASS -nokeys -clcerts -out "$tmp/signer.pem" 2>/dev/null ||
    ! openssl pkcs12 -in "$keystore" -passin env:STUB_STOREPASS -nocerts -nodes -out "$tmp/signer.key" 2>/dev/null; then
    echo "jsign: Failed to load the keystore $keystore" >&2
    exit 1
  fi
  signer="$tmp/signer"
else
  signer="${STUB_JSIGN_SIGNER:?}"
fi
printf 'Authenticode stand-in content' >"$tmp/content"
openssl cms -sign -binary -nodetach -outform DER -in "$tmp/content" -out "$tmp/signature.p7" \
  -signer "$signer.pem" -inkey "$signer.key" || exit 1
if stub_mode corrupt-pck; then
  fixture_py pe "$file" corrupt "$tmp/signature.p7" || exit 1
else
  fixture_py pe_sign "$file" "$tmp/signature.p7" || exit 1
fi
echo "Adding Authenticode signature to $(basename "$file")"
STUB
  fixture_stub_start "$1" java
  cat >>"$1/java" <<'STUB'
stub_log "java $(printf '%q ' "$@")"
if [ "${1:-}" != -jar ] || [ ! -f "${2:-}" ]; then echo "java stand-in: wanted -jar JAR ARGS" >&2; exit 2; fi
shift 2
exec "$(dirname "${BASH_SOURCE[0]}")/jsign" "$@"
STUB
}
