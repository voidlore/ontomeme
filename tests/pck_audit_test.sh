#!/usr/bin/env bash
# Tests scripts/pck_list.py and scripts/check_pck_contents.sh on packs a tiny
# writer below builds: PCK formats v2, v3 and v4, as a bare .pck, embedded in
# an executable (found by its trailer, or by its "pck" section when signing
# appended a certificate table), and inside a macOS zip, a Windows zip and a
# Linux tarball.
#   tests/pck_audit_test.sh
# Opt-in runs on real exports, each of which must pass the audit:
#   PCK_AUDIT_ARTIFACTS="<Ontomeme.x86_64> <Ontomeme.zip> ..."
#   PCK_AUDIT_GODOT=<godot 4.7>   exports this checkout's HEAD with the
#                                 "Linux x86_64" and "Windows x86_64"
#                                 presets into a temp dir, and audits the
#                                 .exe signed the way Authenticode appends
#                                 its certificate too (needs the templates)
# Prints RESULT: ALL PASS (0 failures), or RESULT: FAIL (n failures) and exits 1.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python="${PYTHON:-python3}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

pass() { echo "PASS  $*"; }
fail() {
  echo "FAIL  $*"
  failures=$((failures + 1))
}

# make_pck.py <out> <version>[enc] <kind> <entry>...: a pack holding each
# entry. An entry is PATH, PATH=TEXT (its bytes) or -PATH (a removal record,
# as a patch pack writes). <kind> is pck, exe, mac-zip, win-zip, linux-tgz
# or packless-zip (a zip with no pack in it); or an executable whose "pck"
# section points at the pack, as an export writes it: pe-exe, signed-exe
# (a certificate table after the trailer, as Authenticode signing appends),
# signed-win-zip, elf64-tail and elf32-tail (bytes after the trailer); or
# one where only a section could find the pack, and it can't: stale-section
# (a signed exe whose pck section points elsewhere), pe-cut and elf-cut
# (cut inside the header, no trailer).
# make_pck.py --sign <in.exe> <out.exe> signs a real export that way.
# "enc" sets the encrypted-directory flag. v2 paths keep their res:// prefix
# and the directory follows the header; v3 and v4 put it after the data.
cat >"$tmp/make_pck.py" <<'EOF'
import io, struct, sys, tarfile, zipfile

REL_FILEBASE, DIR_ENCRYPTED, FILE_REMOVAL = 2, 1, 2

def pack(version, encrypted, specs):
    flags = REL_FILEBASE | (DIR_ENCRYPTED if encrypted else 0)
    data, records = b"", []
    for spec in specs:
        removed = spec.startswith("-")
        path, _, text = spec.lstrip("-").partition("=")
        body = (text or "x").encode() if not removed else b""
        if version == 2:
            path = "res://" + path
        name = path.encode()
        name += b"\0" * (-len(name) % 4)
        records.append(struct.pack("<I", len(name)) + name
                       + struct.pack("<QQ", len(data), len(body)) + b"\0" * 16
                       + struct.pack("<I", FILE_REMOVAL if removed else 0))
        data += body
    directory = struct.pack("<I", len(records)) + b"".join(records)
    minor = 3 if version == 2 else 7
    head = b"GDPC" + struct.pack("<5I", version, 4, minor, 2, flags)
    if version == 2:
        file_base = len(head) + 8 + 64 + len(directory)
        return head + struct.pack("<Q", file_base) + b"\0" * 64 + directory + data
    file_base = len(head) + 16 + 64
    return (head + struct.pack("<QQ", file_base, file_base + len(data)) + b"\0" * 64
            + data + directory)

def exe(p):
    return b"\x7fELF" + b"\0" * 1020 + p + struct.pack("<Q", len(p)) + b"GDPC"

def trailer(p):
    return struct.pack("<Q", len(p)) + b"GDPC"

def pe(p, pck_at=0x600):
    """A PE32+ with a .text and a "pck" section, the pack at 0x600."""
    dos = b"MZ" + b"\0" * 58 + struct.pack("<I", 0x80)
    dos += b"\0" * (0x80 - len(dos))
    opt = struct.pack("<H", 0x20B) + b"\0" * 110 + b"\0" * 128   # 16 empty data directories at 112
    sections = [(b".text", 0x400, 0x200), (b"pck", pck_at, len(p) + 12)]
    coff = b"PE\0\0" + struct.pack("<HHIIIHH", 0x8664, len(sections), 0, 0, 0, len(opt), 0x22)
    table = b"".join(struct.pack("<8sIIIIIIHHI", name, size, 0, size, raw, 0, 0, 0, 0, 0)
                     for name, raw, size in sections)
    head = dos + coff + opt + table
    return head + b"\0" * (0x400 - len(head)) + b"\xcc" * 0x200 + p + trailer(p)

def sign(exe_bytes):
    """Append a WIN_CERTIFICATE and point the security directory at it."""
    data = bytearray(exe_bytes)
    opt = struct.unpack_from("<I", data, 0x3C)[0] + 24
    plus = struct.unpack_from("<H", data, opt)[0] == 0x20B
    data += b"\0" * (-len(data) % 8)
    blob = b"\x30\x82" + b"\x11" * 2046   # stands in for the PKCS#7 SignedData
    cert = struct.pack("<IHH", 8 + len(blob), 0x0200, 0x0002) + blob
    struct.pack_into("<II", data, opt + (112 if plus else 96) + 4 * 8, len(data), len(cert))
    return bytes(data + cert)

def elf(p, bits, tail=b""):
    """An ELF with .shstrtab and a "pck" section over the pack and trailer."""
    names = b"\0.shstrtab\0pck\0"
    if bits == 64:
        ehsize, shsize, fmt = 64, 64, "<IIQQQQIIQQ"
    else:
        ehsize, shsize, fmt = 52, 40, "<IIIIIIIIII"
    shoff = ehsize + len(names)
    shoff += -shoff % 8
    pack_at = shoff + 3 * shsize
    table = (struct.pack(fmt, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
             + struct.pack(fmt, 1, 3, 0, 0, ehsize, len(names), 0, 0, 1, 0)
             + struct.pack(fmt, 11, 1, 2, 0, pack_at, len(p) + 12, 0, 0, 8, 0))
    ident = b"\x7fELF" + bytes([2 if bits == 64 else 1, 1, 1]) + b"\0" * 9
    if bits == 64:
        head = ident + struct.pack("<HHIQQQIHHHHHH", 2, 0x3E, 1, 0, 0, shoff, 0, 64, 0, 0, 64, 3, 1)
    else:
        head = ident + struct.pack("<HHIIIIIHHHHHH", 2, 3, 1, 0, 0, shoff, 0, 52, 0, 0, 40, 3, 1)
    body = head + names
    return body + b"\0" * (shoff - len(body)) + table + p + trailer(p) + tail

def zipped(members):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, body in members:
            z.writestr(name, body)
    return buf.getvalue()

def tarred(members):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for name, body in members:
            info = tarfile.TarInfo(name)
            info.size = len(body)
            t.addfile(info, io.BytesIO(body))
    return buf.getvalue()

if sys.argv[1] == "--sign":
    with open(sys.argv[2], "rb") as f:
        signed = sign(f.read())
    with open(sys.argv[3], "wb") as f:
        f.write(signed)
    sys.exit(0)
out, version, kind, specs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
p = pack(int(version.rstrip("enc")), version.endswith("enc"), specs)
blob = {
    "pck": lambda: p,
    "exe": lambda: exe(p),
    "mac-zip": lambda: zipped([("Ontomeme.app/Contents/Info.plist", b"<plist/>"),
                               ("Ontomeme.app/Contents/MacOS/Ontomeme", b"\xcf\xfa\xed\xfe"),
                               ("Ontomeme.app/Contents/Resources/Ontomeme.pck", p)]),
    "win-zip": lambda: zipped([("Ontomeme-0.1.0-windows/Ontomeme.exe", exe(p))]),
    "linux-tgz": lambda: tarred([("Ontomeme-0.1.0-linux/Ontomeme.x86_64", exe(p))]),
    "packless-zip": lambda: zipped([("Ontomeme/README.txt", b"no pack here")]),
    "pe-exe": lambda: pe(p),
    "signed-exe": lambda: sign(pe(p)),
    "signed-win-zip": lambda: zipped([("Ontomeme-0.1.0-windows/Ontomeme.exe", sign(pe(p)))]),
    "elf64-tail": lambda: elf(p, 64, b"\0" * 8 + b"appended after the pack"),
    "elf32-tail": lambda: elf(p, 32, b"\0" * 8 + b"appended after the pack"),
    "stale-section": lambda: sign(pe(p, pck_at=0x400)),
    "pe-cut": lambda: pe(p)[:0x90],
    "elf-cut": lambda: elf(p, 64)[:0x30],
}[kind]()
with open(out, "wb") as f:
    f.write(blob)
EOF

make_pck() {
  "$python" -I "$tmp/make_pck.py" "$@" || { echo "FAIL  the test's pack writer failed: $*"; exit 1; }
}

# What a healthy export packs: the required files plus a few ordinary ones.
clean=(project.binary note.tscn.remap note.gdc .godot/global_script_class_cache.cfg
  mcp/README.md mcp/note_guide.md Ontomeme_Logo.ico)
for f in ontomeme-notes/*.md; do clean+=("$f"); done
for f in fonts/*.ttf; do clean+=("$f.import"); done
expected_list="$(printf '%s\n' "${clean[@]}")"

# without <path>: the clean entries minus one.
without() {
  local e
  for e in "${clean[@]}"; do [ "$e" = "$1" ] || printf '%s\n' "$e"; done
}

# expect_audit <exit> <what> <must-print> <check_pck_contents.sh args...>
expect_audit() {
  local want="$1" what="$2" needle="$3" code
  shift 3
  scripts/check_pck_contents.sh "$@" >"$tmp/audit.out" 2>&1
  code=$?
  if [ "$code" -ne "$want" ]; then
    fail "$what: exit $code, expected $want"
  elif [ -n "$needle" ] && ! grep -qF -- "$needle" "$tmp/audit.out"; then
    fail "$what: the output doesn't say '$needle'"
  elif grep -q Traceback "$tmp/audit.out"; then
    fail "$what: a Python traceback"
  else
    pass "$what"
    return 0
  fi
  sed 's/^/      /' "$tmp/audit.out"
  return 1
}

# expect_list <what> <artifact> <expected listing>
expect_list() {
  local got
  got="$("$python" -I scripts/pck_list.py "$2" 2>&1)"
  if [ "$got" = "$3" ]; then
    pass "$1"
  else
    fail "$1: listed"
    printf '%s\n' "$got" | head -n 20 | sed 's/^/      /'
  fi
}

# --- pck_list.py reads every format and container
for v in 2 3 4; do
  for kind in pck exe; do
    make_pck "$tmp/v$v.$kind" "$v" "$kind" "${clean[@]}"
    expect_list "pck_list.py reads a v$v $kind" "$tmp/v$v.$kind" "$expected_list"
  done
done
for kind in mac-zip win-zip linux-tgz; do
  make_pck "$tmp/v4.$kind" 4 "$kind" "${clean[@]}"
  expect_list "pck_list.py reads a v4 pack in a $kind" "$tmp/v4.$kind" "$expected_list"
done
make_pck "$tmp/removal.pck" 4 pck "${clean[@]}" -docs/old.md
expect_list "pck_list.py leaves out a patch pack's removal records" "$tmp/removal.pck" "$expected_list"
for kind in pe-exe signed-exe signed-win-zip elf64-tail elf32-tail; do
  make_pck "$tmp/v4.$kind" 4 "$kind" "${clean[@]}"
  expect_list "pck_list.py finds a v4 pack through the pck section: $kind" "$tmp/v4.$kind" "$expected_list"
done
long="$("$python" -I scripts/pck_list.py --long "$tmp/v4.exe" | head -n 1)"
case "$long" in
  *"pck v4 from Godot 4.7.2"*"${#clean[@]} files") pass "pck_list.py --long sums up the pack" ;;
  *) fail "pck_list.py --long sums up the pack: '$long'" ;;
esac

# --- a clean export passes, and the count is printed
for kind in pck exe mac-zip win-zip linux-tgz; do
  expect_audit 0 "a clean v4 $kind passes" "${#clean[@]} files" "$tmp/v4.$kind"
done
expect_audit 0 "a clean v2 exe passes" "${#clean[@]} files" "$tmp/v2.exe"
for kind in signed-exe signed-win-zip elf64-tail; do
  expect_audit 0 "clean $kind passes" "${#clean[@]} files" "$tmp/v4.$kind"
done
expect_audit 0 "a removal record of docs/old.md is not a packed file" "" "$tmp/removal.pck"

# --- development and methodology files fail, each named
make_pck "$tmp/docs.pck" 4 pck "${clean[@]}" docs/x.md
expect_audit 1 "a v4 pck with docs/x.md fails" "        docs/x.md" "$tmp/docs.pck"
make_pck "$tmp/docs-v2.exe" 2 exe "${clean[@]}" docs/x.md
expect_audit 1 "a v2 exe with res://docs/x.md fails" "        docs/x.md" "$tmp/docs-v2.exe"
make_pck "$tmp/docs-mac.zip" 4 mac-zip "${clean[@]}" docs/x.md
expect_audit 1 "a macOS zip with docs/x.md fails" "        docs/x.md" "$tmp/docs-mac.zip"
make_pck "$tmp/docs-signed.zip" 4 signed-win-zip "${clean[@]}" docs/x.md
expect_audit 1 "a signed Windows zip with docs/x.md fails" "        docs/x.md" "$tmp/docs-signed.zip"
for dev in tests/boot_test.gd.remap scripts/pck_list.py skills/ontomeme-notes/SKILL.md \
  media/demo.png.import .publish/allow .github/workflows/release.yml .agents/x .claude/x \
  .foi/x \~/Documents/note.tres AGENTS.md CLAUDE.md RELEASING.md ANALYSIS.md PWA-analysis.md \
  SECURITY_ANALYSIS.md component.md mcp/component.md ontomeme-notes/contract.md index.html check_js.py; do
  make_pck "$tmp/dev.pck" 4 pck "${clean[@]}" "$dev"
  expect_audit 1 "$dev fails" "        $dev" "$tmp/dev.pck"
done
for near in my_docs/x.md docs.gdc mediaplayer.gdc ontomeme-notes/contracts.md mcp/AGENTS.md.txt; do
  make_pck "$tmp/near.pck" 4 pck "${clean[@]}" "$near"
  expect_audit 0 "$near passes" "" "$tmp/near.pck"
done

# --- a missing required file fails, named
for need in project.binary note.tscn.remap mcp/note_guide.md "$(printf '%s\n' "${clean[@]}" | grep -m1 '^ontomeme-notes/')" \
  "$(printf '%s\n' "${clean[@]}" | grep -m1 '^fonts/')"; do
  rest=()
  while IFS= read -r e; do rest+=("$e"); done < <(without "$need")
  make_pck "$tmp/missing.pck" 4 pck "${rest[@]}"
  expect_audit 1 "a pack without $need fails" "        $need" "$tmp/missing.pck"
done

# --- bytes matching the private-names list fail, wherever they hide
printf 'dev-only-marker-[0-9]+\n' >"$tmp/forbidden"
make_pck "$tmp/marked.exe" 4 exe "${clean[@]}" "theme.res=colours dev-only-marker-42 end"
expect_audit 1 "an exe whose theme.res holds a private name fails" "        in theme.res" \
  --forbidden "$tmp/forbidden" "$tmp/marked.exe"
make_pck "$tmp/marked.zip" 4 mac-zip "${clean[@]}" "theme.res=colours dev-only-marker-42 end"
expect_audit 1 "a macOS zip (deflated) holding a private name fails" "dev-only-marker-42" \
  --forbidden "$tmp/forbidden" "$tmp/marked.zip"
make_pck "$tmp/marked-signed.exe" 4 signed-exe "${clean[@]}" "theme.res=colours dev-only-marker-42 end"
expect_audit 1 "a signed exe whose theme.res holds a private name fails" "        in theme.res" \
  --forbidden "$tmp/forbidden" "$tmp/marked-signed.exe"
expect_audit 0 "a clean exe passes the private-name check" "ok    no bytes match" \
  --forbidden "$tmp/forbidden" "$tmp/v4.exe"
expect_audit 2 "a --forbidden file that doesn't exist is a usage error" "" \
  --forbidden "$tmp/no-such-file" "$tmp/v4.exe"

# --- what isn't a readable pack fails cleanly
printf 'not a pack at all\n' >"$tmp/garbage.bin"
expect_audit 1 "a file with no pack fails" "no Godot pack" "$tmp/garbage.bin"
head -c 300 "$tmp/v4.pck" >"$tmp/cut.pck"
expect_audit 1 "a pack cut inside its data fails" "more than the pack can hold" "$tmp/cut.pck"
head -c $(($(wc -c <"$tmp/v4.pck") - 10)) "$tmp/v4.pck" >"$tmp/cut.pck"
expect_audit 1 "a pack cut inside its directory fails" "cut short" "$tmp/cut.pck"
make_pck "$tmp/enc.pck" 4enc pck "${clean[@]}"
expect_audit 1 "an encrypted directory fails" "encrypted" "$tmp/enc.pck"
make_pck "$tmp/v5.pck" 5 pck "${clean[@]}"
expect_audit 1 "pack format v5 fails" "v5" "$tmp/v5.pck"
for kind in stale-section pe-cut elf-cut; do
  make_pck "$tmp/bad.$kind" 4 "$kind" "${clean[@]}"
  expect_audit 1 "$kind with no findable pack fails" "no Godot pack" "$tmp/bad.$kind"
done
make_pck "$tmp/packless.zip" 4 packless-zip
expect_audit 1 "a zip with no pack in it fails" "no .pck and no Godot executable" "$tmp/packless.zip"
expect_audit 2 "no artifact is a usage error" ""

# --- opt-in: real exports
artifacts=()
if [ -n "${PCK_AUDIT_ARTIFACTS:-}" ]; then
  read -r -a artifacts <<<"$PCK_AUDIT_ARTIFACTS"
fi
if [ -n "${PCK_AUDIT_GODOT:-}" ]; then
  mkdir -p "$tmp/export-src" "$tmp/export"
  git archive HEAD | tar -x -C "$tmp/export-src"
  "$PCK_AUDIT_GODOT" --headless --path "$tmp/export-src" --import >"$tmp/import.log" 2>&1
  for preset in "Linux x86_64:Ontomeme.x86_64" "Windows x86_64:Ontomeme.exe"; do
    out="$tmp/export/${preset#*:}"
    if "$PCK_AUDIT_GODOT" --headless --path "$tmp/export-src" --export-release "${preset%%:*}" \
      "$out" >"$tmp/export.log" 2>&1 && [ -f "$out" ]; then
      artifacts+=("$out")
    else
      fail "PCK_AUDIT_GODOT couldn't export HEAD with the ${preset%%:*} preset:"
      tail -n 20 "$tmp/export.log" | sed 's/^/      /'
    fi
  done
  if [ -f "$tmp/export/Ontomeme.exe" ]; then
    make_pck --sign "$tmp/export/Ontomeme.exe" "$tmp/export/Ontomeme-signed.exe"
    artifacts+=("$tmp/export/Ontomeme-signed.exe")
  fi
fi
for a in ${artifacts[@]+"${artifacts[@]}"}; do
  expect_audit 0 "the export $a passes" " files" "$a" && grep -E '^pack  ' "$tmp/audit.out" | sed 's/^/      /'
done

echo
if [ "$failures" -eq 0 ]; then
  echo "RESULT: ALL PASS (0 failures)"
else
  echo "RESULT: FAIL ($failures failures)"
  exit 1
fi
