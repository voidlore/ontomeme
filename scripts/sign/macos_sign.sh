#!/usr/bin/env bash
# Developer-ID sign the Ontomeme.app inside Godot's macOS export zip, on Linux,
# with rcodesign, and write the re-zipped result. Runs after the export, so
# export_presets.cfg keeps its built-in ad-hoc signing and unsigned builds work.
#
#   APPLE_P12=<base64 .p12> APPLE_P12_PASSWORD=... [RCODESIGN=/path/to/rcodesign] \
#     scripts/sign/macos_sign.sh build/macos/Ontomeme.zip build/macos/Ontomeme-signed.zip
#
# Without APPLE_P12 it copies IN to OUT byte for byte, prints 'macOS signing
# skipped (no APPLE_P12)' and exits 0. With it, inside a private temp dir that
# is removed on exit, it:
#   1. decodes the .p12 and writes its password to a file (never argv), then
#      re-exports its signing certificate and key as the .p12 rcodesign
#      0.29.0 can read (SHA-1 MAC, 3DES, the leaf certificate alone; see
#      below), so a .p12 made with OpenSSL 3's defaults works too,
#   2. extracts the zip keeping file modes (lib_zip.sh),
#   3. runs `rcodesign sign --p12-file F --p12-password-file PF
#      --code-signature-flags runtime [--for-notarization] X.app`, then
#      `rcodesign verify X.app/Contents/MacOS/X` (verify reads one Mach-O
#      file and refuses a bundle path); --for-notarization is passed when this
#      rcodesign lists it in `sign --help` and the certificate is a Developer
#      ID Application one (rcodesign refuses it for any other certificate),
#   4. compares check_signatures.py --json before and after: the entitlements
#      (code signature slot 5) and Info.plist privacy strings must survive; if
#      rcodesign dropped the entitlements it signs again with
#      --entitlements-xml-path holding the original ones,
#   5. re-zips the .app (Contents/MacOS/* stays 0755) and asserts
#      check_signatures.py --expect-macos=signed on it.
# OUT is written only when every step passes. RCODESIGN selects the binary
# (default: rcodesign on PATH; install it with install_rcodesign.sh).
# Exit 0 on success or skip, 1 on failure, 2 on a usage error.
set +x # never trace: the environment holds secrets
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib_zip.sh
. "$here/lib_zip.sh"

fail() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error::macOS signing: $1" >&2; else echo "macOS signing: ERROR: $1" >&2; fi
  exit 1
}

if [ $# -ne 2 ]; then
  echo "usage: macos_sign.sh IN.zip OUT.zip" >&2
  exit 2
fi
in="$1" out="$2"
[ -f "$in" ] || fail "no such file: $in"

if [ -z "${APPLE_P12:-}" ]; then
  zip_copy_through "$in" "$out"
  echo "macOS signing skipped (no APPLE_P12)"
  exit 0
fi

umask 077
work=""
cleanup() { if [ -n "$work" ]; then rm -rf "$work"; fi; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
work="$(mktemp -d)" || fail "cannot create a temp dir"

rcodesign="${RCODESIGN:-rcodesign}"
command -v "$rcodesign" >/dev/null 2>&1 ||
  fail "rcodesign not found ('$rcodesign'): run scripts/sign/install_rcodesign.sh DIR or set RCODESIGN"
rcodesign="$(command -v "$rcodesign")"

check() { python3 -I "$here/check_signatures.py" "$@"; }

# --- secrets ----------------------------------------------------------------

p12="$work/cert.p12" password_file="$work/p12.password"
leaf="$work/leaf.pem" signing_p12="$work/signing.p12"
# printf is a builtin, so neither secret reaches argv.
printf '%s' "$APPLE_P12" | tr -d '[:space:]' | base64 -d >"$p12" 2>/dev/null && [ -s "$p12" ] ||
  fail "APPLE_P12 is not valid base64 (encode the .p12 with: base64 -w0 cert.p12)"
# rcodesign and openssl both read the first line of the password file.
printf '%s\n' "${APPLE_P12_PASSWORD-}" >"$password_file"

# open_p12: write the .p12's signing certificate (the first one bound to its
# key) to $leaf and set p12_mode to the openssl option that opened it: none, or
# -legacy for the RC2 files older Keychain Access exports.
p12_mode=""
open_p12() {
  local mode
  for mode in "" -legacy; do
    # shellcheck disable=SC2086 # $mode is one optional word
    if openssl pkcs12 $mode -in "$p12" -passin "file:$password_file" -nokeys -clcerts -out "$work/certs.pem" 2>/dev/null &&
      openssl x509 -in "$work/certs.pem" -out "$leaf" 2>/dev/null; then
      p12_mode="$mode"
      return 0
    fi
  done
  return 1
}

open_p12 || fail "APPLE_P12_PASSWORD does not open APPLE_P12 (scripts/sign/preflight.sh says more)"
cn="$(openssl x509 -in "$leaf" -noout -subject -nameopt multiline,utf8,-esc_msb 2>/dev/null |
  sed -n 's/^ *commonName *= //p' | head -n 1)"

# rcodesign 0.29.0 reads a .p12 with the p12 0.6 crate, which knows only a
# SHA-1 MAC and SHA-1 RC2/3DES encryption: OpenSSL 3's default export (SHA-256
# MAC, PBES2 AES-256), the usual way to build APPLE_P12 on Linux, reaches it as
# 'incorrect password'. And it signs with the last certificate in the file, so
# a chain exported after the leaf would sign as the CA. So rcodesign gets
# $signing_p12: the leaf alone and its key, re-exported with 3DES and a SHA-1
# MAC under the same password. The key only flows through the pipe.
# shellcheck disable=SC2086 # $p12_mode is one optional word
openssl pkcs12 $p12_mode -in "$p12" -passin "file:$password_file" -nocerts -nodes 2>/dev/null |
  openssl pkcs12 -export -inkey /dev/stdin -in "$leaf" -passout "file:$password_file" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -out "$signing_p12" 2>"$work/export.log" ||
  fail "cannot re-export APPLE_P12 for rcodesign (does its key match '$cn'?): $(head -n 1 "$work/export.log")"

for_notarization=false
sign_help="$("$rcodesign" sign --help 2>&1 || true)"
if [[ $cn != "Developer ID Application:"* ]]; then
  echo "macOS signing: note: '$cn' is not a Developer ID Application certificate, so the app is signed without --for-notarization and Apple will not notarize it"
elif [[ $sign_help == *--for-notarization* ]]; then
  for_notarization=true
fi

# --- the app ----------------------------------------------------------------

zip_extract "$in" "$work/app" || fail "cannot extract $in"
app="$(zip_single_app "$work/app")" || fail "$in does not hold just one .app"

# app_executable APP: the path of APP's main executable,
# Contents/MacOS/<CFBundleExecutable> (APP's own name when Info.plist has none).
app_executable() {
  python3 -I - "$1" <<'PY'
import os, plistlib, sys

app = sys.argv[1]
try:
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        exe = plistlib.load(f).get("CFBundleExecutable")
except (OSError, plistlib.InvalidFileException, ValueError):
    exe = None
if not isinstance(exe, str) or not exe or "/" in exe or exe in (".", ".."):
    exe = os.path.basename(app)[: -len(".app")]
print(os.path.join(app, "Contents", "MacOS", exe))
PY
}

exe="$(app_executable "$app")" && [ -f "$exe" ] ||
  fail "$(basename "$app") has no main executable at ${exe#"$app/"}"

# save_entitlements EXE OUT: the main executable's entitlements plist (code
# signature slot 5) exactly as embedded, to OUT; no OUT when it has none.
save_entitlements() {
  python3 -I - "$here" "$1" "$2" <<'PY'
import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import check_signatures as cs

exe, out = sys.argv[2:4]
found = set()
with cs.mapped_path(exe) as buf:
    for _arch, offset, size in cs.macho_slices(buf):
        sig = cs.code_signature(buf, offset, size)
        for slot, _magic, blob in cs.superblob_slots(sig) if sig else ():
            if slot == cs.CSSLOT_ENTITLEMENTS:
                found.add(bytes(blob[8:]))
if len(found) > 1:
    sys.exit(f"the architectures of Contents/MacOS/{os.path.basename(exe)} carry different entitlements")
if found:
    with open(out, "wb") as f:
        f.write(found.pop())
PY
}

# state_diff KIND BEFORE AFTER: print how KIND (entitlements or privacy)
# differs between two check_signatures.py --json reports; exit 1 if it does.
state_diff() {
  python3 -I - "$@" <<'PY'
import json, sys

kind, before, after = sys.argv[1:4]


def state(path):
    with open(path) as f:
        report = next((r for r in json.load(f)["artifacts"] if r["platform"] == "macos"), None)
    if report is None:
        sys.exit(f"{path}: check_signatures.py found no macOS app")
    if kind == "privacy":
        return {"Contents/Info.plist": report.get("privacy")}
    return {f"{b['path']} {b['arch']}": (b.get("entitlements_sha256") is not None, b.get("entitlements"))
            for b in report["binaries"]}


def show(value):
    if isinstance(value, tuple):
        present, parsed = value
        value = parsed if present else None
    if value is None:
        return "none"
    if isinstance(value, dict):
        return "{" + ", ".join(sorted(value)) + "}"
    return "unreadable"


old, new = state(before), state(after)
label = "privacy strings" if kind == "privacy" else kind
diffs = [f"{label} of {key} changed: {show(value)} -> {show(new.get(key))}"
         for key, value in old.items() if new.get(key) != value]
print("\n".join(diffs))
sys.exit(1 if diffs else 0)
PY
}

check --json "$app" >"$work/before.json" || [ $? -eq 1 ] || fail "check_signatures.py cannot read $app"
save_entitlements "$exe" "$work/entitlements.xml" || fail "cannot read the entitlements of $app"

# sign_app [EXTRA ARGS...]: rcodesign sign the app in place, then verify its
# main executable (every architecture). rcodesign 0.29's verify takes only a
# Mach-O file ('provided path is a Bundle' for X.app); check_signatures.py
# covers the rest of the bundle.
sign_app() {
  local -a args=(sign --p12-file "$signing_p12" --p12-password-file "$password_file" --code-signature-flags runtime)
  if [ "$for_notarization" = true ]; then args+=(--for-notarization); fi
  args+=("$@" "$app")
  "$rcodesign" "${args[@]}" || fail "rcodesign sign failed"
  "$rcodesign" verify "$exe" || fail "rcodesign verify failed on the signed app's ${exe#"$app/"}"
  check --json "$app" >"$work/after.json" || [ $? -eq 1 ] || fail "check_signatures.py cannot read the signed app"
}

echo "macOS signing: signing $(basename "$app") as '$cn'"
sign_app
if ! diffs="$(state_diff entitlements "$work/before.json" "$work/after.json")"; then
  [ -s "$work/entitlements.xml" ] || fail "$diffs"
  echo "macOS signing: rcodesign did not keep the entitlements ($diffs); signing again with --entitlements-xml-path"
  sign_app --entitlements-xml-path "$work/entitlements.xml"
  diffs="$(state_diff entitlements "$work/before.json" "$work/after.json")" || fail "$diffs"
fi
diffs="$(state_diff privacy "$work/before.json" "$work/after.json")" || fail "$diffs"

zip_create "$work/app" "$(basename "$app")" "$work/signed.zip" || fail "cannot re-zip the signed app"
check --expect-macos=signed "$work/signed.zip" || fail "the re-zipped app is not signed (see check_signatures.py above)"
mv -f "$work/signed.zip" "$out"
chmod 644 "$out"
echo "macOS signing: done, $out holds $(basename "$app") signed by '$cn'"
