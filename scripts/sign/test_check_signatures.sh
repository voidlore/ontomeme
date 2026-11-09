#!/usr/bin/env bash
# Tests for check_signatures.py. Synthetic Mach-O and PE fixtures always run;
# with GODOT set, the real 'macOS' and 'Windows x86_64' exports are checked too.
#   [GODOT=/path/to/godot] scripts/sign/test_check_signatures.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib_fixtures.sh
. "$here/lib_fixtures.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
check() { python3 -I "$here/check_signatures.py" "$@"; }

# one_line_reason NAME WANT_EXIT CMD...: PASS when CMD exits WANT_EXIT and writes
# exactly one line, starting 'FAIL ', to stderr.
one_line_reason() {
  local name="$1" want="$2" code=0 err
  shift 2
  "$@" >/dev/null 2>"$work/stderr" || code=$?
  err="$(cat "$work/stderr")"
  if [ "$code" != "$want" ]; then
    t_fail "$name" "exit $code, wanted $want"
  elif [ "$(wc -l <"$work/stderr")" -ne 1 ] || [ "${err#FAIL }" = "$err" ]; then
    t_fail "$name" "wanted one 'FAIL ' line on stderr, got: $err"
  else
    t_pass "$name"
  fi
}

# --- synthetic fixtures ----------------------------------------------------

f="$work/fixtures"
mkdir -p "$f/adhoc" "$f/signed" "$f/stapled" "$f/dev" "$f/lookalike" "$f/fat" "$f/mixed" "$f/unsigned" \
  "$f/zip/Ontomeme-0.0.0-windows" "$f/zipapp"
fixture_signing_certs "$f"
fixture_cert "$f/lookalike-cert" "/CN=$TEST_DEVID_CN"

fixture_macho "$f/adhoc.macho" arm64 adhoc
fixture_macho "$f/adhoc-x86.macho" x86_64 adhoc
fixture_macho "$f/signed.macho" arm64 signed "$f/devid" "$f/ca"
fixture_macho "$f/dev.macho" arm64 signed "$f/dev"
fixture_macho "$f/lookalike.macho" arm64 signed "$f/lookalike-cert"
fixture_macho "$f/unsigned.macho" arm64 unsigned
fixture_py fat "$f/fat.macho" "$f/adhoc-x86.macho" "$f/adhoc.macho"
fixture_py fat "$f/mixed.macho" "$f/adhoc-x86.macho" "$f/signed.macho"
fixture_app "$f/adhoc" Test "$f/adhoc.macho"
fixture_app "$f/signed" Test "$f/signed.macho"
fixture_app "$f/stapled" Test "$f/signed.macho" stapled
fixture_app "$f/dev" Test "$f/dev.macho"
fixture_app "$f/lookalike" Test "$f/lookalike.macho"
fixture_app "$f/fat" Test "$f/fat.macho"
fixture_app "$f/mixed" Test "$f/mixed.macho"
fixture_app "$f/unsigned" Test "$f/unsigned.macho"
fixture_app "$f/zipapp" Test "$f/signed.macho"
fixture_py zip "$f/signed-app.zip" "$f/zipapp"
head -c 400 "$f/signed.macho" >"$f/truncated.macho"

printf 'Authenticode stand-in content' >"$f/pe-content"
openssl cms -sign -binary -nodetach -outform DER -in "$f/pe-content" -out "$f/pe.p7" \
  -signer "$f/devid.pem" -inkey "$f/devid.key" -certfile "$f/ca.pem"
fixture_py pe "$f/unsigned.exe" intact
fixture_py pe "$f/signed.exe" intact "$f/pe.p7"
fixture_py pe "$f/nopck.exe" missing
fixture_py pe "$f/badpck.exe" corrupt "$f/pe.p7"
cp -f "$f/unsigned.exe" "$f/zip/Ontomeme-0.0.0-windows/Ontomeme.exe"
fixture_py zip "$f/windows.zip" "$f/zip"
printf 'not an artifact' >"$f/garbage.bin"

check_case "adhoc Mach-O -> adhoc, runtime flag" 0 \
  --has "macOS Test.app: adhoc" \
  --has "Contents/MacOS/Test arm64: adhoc, flags 0x10002 (adhoc, runtime), identifier com.example.fixture" \
  --has "_CodeSignature/CodeResources: present" \
  --has "notarization ticket (Contents/CodeResources): absent" \
  -- check "$f/adhoc/Test.app"

check_case "signed Mach-O -> developer-id with the test CN" 0 \
  --has "macOS Test.app: developer-id" \
  --has "signer: $TEST_DEVID_CN (issuer Developer ID Certification Authority" \
  --has "team ABCDE12345" \
  -- check --expect-macos=developer-id "$f/signed/Test.app"

check_case "developer-id without a ticket fails --expect-macos=stapled" 1 \
  --has "is developer-id, expected stapled" --has "no notarization ticket at Contents/CodeResources" \
  -- check --expect-macos=stapled "$f/signed/Test.app"

check_case "signed + Contents/CodeResources -> stapled" 0 \
  --has "macOS Test.app: stapled" --has "notarization ticket (Contents/CodeResources): present" \
  -- check --expect-macos=stapled "$f/stapled/Test.app"

check_case "Apple Development certificate -> signed, not developer-id" 1 \
  --has "macOS Test.app: signed" --has "not a Developer ID Application certificate" \
  --has "is signed, expected developer-id" \
  -- check --expect-macos=developer-id "$f/dev/Test.app"

check_case "self-signed Developer ID look-alike -> signed" 0 \
  --has "macOS Test.app: signed" --has "signer: $TEST_DEVID_CN (issuer $TEST_DEVID_CN" \
  -- check --expect-macos=signed "$f/lookalike/Test.app"

check_case "Mach-O without LC_CODE_SIGNATURE -> unsigned" 1 \
  --has "macOS Test.app: unsigned" --has "is unsigned, expected adhoc" \
  -- check --expect-macos=adhoc "$f/unsigned/Test.app"

check_case "fat adhoc Mach-O -> adhoc with runtime on both arches" 0 \
  --has "Contents/MacOS/Test x86_64: adhoc, flags 0x10002 (adhoc, runtime)" \
  --has "Contents/MacOS/Test arm64: adhoc, flags 0x10002 (adhoc, runtime)" \
  -- check --expect-macos=adhoc "$f/fat/Test.app"

check_case "fat Mach-O with one ad-hoc arch -> adhoc, naming that arch" 0 \
  --has "macOS Test.app: adhoc (Contents/MacOS/Test x86_64: ad-hoc signature" \
  --has "Contents/MacOS/Test arm64: developer-id" \
  -- check "$f/mixed/Test.app"

check_case "zip holding a signed .app -> developer-id" 0 \
  --has "signed-app.zip: macOS Test.app: developer-id" \
  -- check --expect-macos=developer-id "$f/signed-app.zip"

check_case "bare Mach-O file -> adhoc" 0 \
  --has "adhoc.macho: macOS adhoc.macho: adhoc" \
  -- check "$f/adhoc.macho"

check_case "truncated signature -> a FAIL problem" 1 \
  --has "FAIL" --has "LC_CODE_SIGNATURE points past the end of the slice" \
  -- check "$f/truncated.macho"

check_case "unsigned PE -> unsigned, pck intact" 0 \
  --has "Windows unsigned.exe: unsigned" --has "pck section: intact (starts with GDPC)" \
  -- check --expect-windows=unsigned "$f/unsigned.exe"

check_case "signed PE -> signed with the test CN" 0 \
  --has "Windows signed.exe: signed" --has "signer: $TEST_DEVID_CN" \
  --has "pck section: intact" \
  -- check --expect-windows=signed "$f/signed.exe"

check_case "unsigned PE fails --expect-windows=signed" 1 \
  --has "is unsigned, expected signed" \
  -- check --expect-windows=signed "$f/unsigned.exe"

check_case "PE without a pck section -> FAIL" 1 \
  --has "no 'pck' section" \
  -- check "$f/nopck.exe"

check_case "PE whose pck section lost GDPC -> FAIL" 1 \
  --has "the 'pck' section does not start with GDPC" \
  -- check --expect-windows=signed "$f/badpck.exe"

check_case "packaged Windows zip -> the exe inside it" 0 \
  --has "windows.zip: Windows Ontomeme-0.0.0-windows/Ontomeme.exe: unsigned" \
  -- check "$f/windows.zip"

check_case "--expect-macos with no macOS artifact -> FAIL" 1 \
  --has "no macOS artifact found to check --expect-macos=adhoc" \
  -- check --expect-macos=adhoc "$f/unsigned.exe"

check_case "an unrecognized file -> exit 2" 2 \
  --has "ERROR" --has "not a zip, .app, PE or Mach-O file" \
  -- check "$f/garbage.bin"

check_case "a missing file -> exit 2" 2 --has "ERROR" -- check "$f/no-such-file.zip"

check_case "an unknown --expect level -> usage error" 2 \
  --has "invalid choice" \
  -- check --expect-macos=notarized "$f/adhoc.macho"

one_line_reason "--expect-macos=developer-id on adhoc -> one-line reason" 1 \
  check --expect-macos=developer-id "$f/adhoc/Test.app"

check_case "--json reports levels, arches, flags and the signer" 0 -- \
  python3 -I -c '
import json, subprocess, sys
out = subprocess.run([sys.executable, "-I", sys.argv[1], "--json", *sys.argv[2:4]],
                     capture_output=True, text=True, check=True).stdout
data = json.loads(out)
mac, win = data["artifacts"]
assert data["ok"] is True and data["failures"] == [], data
assert (mac["platform"], mac["level"], mac["ticket"]) == ("macos", "stapled", True), mac
binary = mac["binaries"][0]
assert binary["arch"] == "arm64" and "runtime" in binary["flag_names"], binary
assert binary["signer"]["subject_cn"] == sys.argv[4], binary["signer"]
assert binary["entitlements_sha256"] and mac["info_plist_sha256"], mac
assert binary["entitlements"] == {} and mac["privacy"] == {}, (binary["entitlements"], mac["privacy"])
assert (win["platform"], win["level"], win["pck"]) == ("windows", "signed", "intact"), win
assert win["signer"]["subject_cn"] == sys.argv[4], win
' "$here/check_signatures.py" "$f/stapled/Test.app" "$f/signed.exe" "$TEST_DEVID_CN"

# --- real Godot exports (opt-in: GODOT) --------------------------------------

real="$work/real"
mkdir -p "$real"
status=0
fixture_godot_exports "$real" || status=$?
if [ "$status" -eq 2 ]; then
  t_skip "real Godot exports ($FIXTURE_REASON)"
elif [ "$status" -ne 0 ]; then
  t_fail "real Godot exports" "$FIXTURE_REASON"
else
  check_case "real macOS export -> adhoc, runtime on x86_64 and arm64" 0 \
    --has "Ontomeme.zip: macOS Ontomeme.app: adhoc" \
    --match "Contents/MacOS/Ontomeme x86_64: adhoc, flags 0x[0-9a-f]+ \(adhoc, runtime\)" \
    --match "Contents/MacOS/Ontomeme arm64: adhoc, flags 0x[0-9a-f]+ \(adhoc, runtime\)" \
    --has "_CodeSignature/CodeResources: present" \
    -- check --expect-macos=adhoc "$real/Ontomeme.zip"
  check_case "real Windows export -> unsigned, pck section intact" 0 \
    --has "Ontomeme.exe: Windows Ontomeme.exe: unsigned" --has "pck section: intact (starts with GDPC)" \
    -- check --expect-windows=unsigned "$real/Ontomeme.exe"
  one_line_reason "real macOS export fails --expect-macos=developer-id in one line" 1 \
    check --expect-macos=developer-id "$real/Ontomeme.zip"
fi

t_finish
