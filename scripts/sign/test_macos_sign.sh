#!/usr/bin/env bash
# Tests for macos_sign.sh and install_rcodesign.sh. They run against stand-in
# rcodesign and curl tools on PATH (lib_fixtures.sh), so nothing is downloaded
# or run from the network. Opt-in: with RCODESIGN pointing at a real rcodesign
# and GODOT set, a throwaway self-signed p12 also signs the real macOS export.
#   [RCODESIGN=/path/to/rcodesign GODOT=/path/to/godot] scripts/sign/test_macos_sign.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib_fixtures.sh
. "$here/lib_fixtures.sh"

umask 022
REAL_RCODESIGN="${RCODESIGN:-}"
unset RCODESIGN

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
f="$work/fixtures" stubs="$work/stubs" tmp="$work/tmpdir" log="$work/stub.log"
mkdir -p "$f/in" "$f/two/Ontomeme.app/Contents/MacOS"
fixture_rcodesign_stub "$stubs"
fixture_curl_stub "$stubs"

PASSWORD='p12-Pa55-quux'
WRONG_PASSWORD='p12-wr0ng-xyzzy'
SELFTEST_CN="Ontomeme Selftest"

fixture_signing_certs "$f"
fixture_cert "$f/selftest" "/CN=$SELFTEST_CN" "" -addext "extendedKeyUsage=codeSigning"
# APPLE_P12 as a Linux user builds it: `openssl pkcs12 -export` with OpenSSL 3's
# defaults (SHA-256 MAC, PBES2 AES-256), the issuing CA after the leaf. Neither
# reaches rcodesign 0.29 as given (see the stand-in contract below).
fixture_p12 "$f/devid.p12" "$f/devid" "$PASSWORD" "$f/ca" "${P12_MODERN[@]}"
fixture_p12 "$f/selftest.p12" "$f/selftest" "$PASSWORD" "" "${P12_MODERN[@]}"
DEVID_P12="$(base64 -w0 "$f/devid.p12")"
SELFTEST_P12="$(base64 -w0 "$f/selftest.p12")"

# The input: Godot's export shape, a universal ad-hoc Ontomeme.app with
# entitlements, privacy strings and an Ontomeme.pck, zipped without dir entries.
cat >"$f/entitlements.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict>
</plist>
XML
FIXTURE_ENTITLEMENTS="$f/entitlements.xml" fixture_macho "$f/x86_64.macho" x86_64 adhoc
FIXTURE_ENTITLEMENTS="$f/entitlements.xml" fixture_macho "$f/arm64.macho" arm64 adhoc
fixture_py fat "$f/universal.macho" "$f/x86_64.macho" "$f/arm64.macho"
fixture_app "$f/in" Ontomeme "$f/universal.macho"
rm -r "$f/in/Ontomeme.app/Contents/_CodeSignature"
cat >"$f/in/Ontomeme.app/Contents/Info.plist" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Ontomeme</string>
	<key>CFBundleIdentifier</key>
	<string>com.voidlore.ontomeme</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>Ontomeme keeps your notes in a folder in Documents.</string>
	<key>NSDesktopFolderUsageDescription</key>
	<string>Ontomeme can open a notes folder on your Desktop.</string>
</dict>
</plist>
XML
head -c 4096 /dev/urandom >"$f/in/Ontomeme.app/Contents/Resources/Ontomeme.pck"
fixture_py zip "$f/in.zip" "$f/in"
cp -f "$f/universal.macho" "$f/two/Ontomeme.app/Contents/MacOS/Ontomeme"
printf 'stray' >"$f/two/README.txt"
fixture_py zip "$f/two.zip" "$f/two"
mkdir -p "$f/noexe"
cp -Rp "$f/in/Ontomeme.app" "$f/noexe/"
sed -i.orig 's|<string>Ontomeme</string>|<string>Gone</string>|' "$f/noexe/Ontomeme.app/Contents/Info.plist"
rm -f "$f/noexe/Ontomeme.app/Contents/Info.plist.orig"
fixture_py zip "$f/noexe.zip" "$f/noexe"

# isolated VAR=VALUE... -- CMD...: CMD in a clean environment with the stubs
# first on PATH and a fresh TMPDIR; exits 99 when CMD leaves anything there.
isolated() {
  local code=0
  local -a vars=()
  while [ "$1" != "--" ]; do
    vars+=("$1")
    shift
  done
  shift
  rm -rf "$tmp"
  mkdir -p "$tmp"
  : >"$log"
  env -i PATH="$stubs:$PATH" HOME="$HOME" TMPDIR="$tmp" STUB_LOG="$log" ${vars[@]+"${vars[@]}"} "$@" || code=$?
  if [ -n "$(ls -A "$tmp")" ]; then
    echo "LEFT IN TMPDIR: $(ls -A "$tmp" | tr '\n' ' ')"
    return 99
  fi
  return "$code"
}

# run_sign OUT VAR=VALUE...: macos_sign.sh in.zip OUT, isolated.
run_sign() {
  local out="$1"
  shift
  isolated "$@" -- bash "$here/macos_sign.sh" "$f/in.zip" "$out"
}

# sign_case NAME WANT_EXIT [checks]... -- OUT VAR=VALUE...: check_case on
# run_sign, also requiring that no secret appears in the output.
sign_case() {
  local name="$1" want="$2"
  local -a checks=()
  shift 2
  while [ "$1" != "--" ]; do
    checks+=("$1" "$2")
    shift 2
  done
  shift
  check_case "$name" "$want" "${checks[@]}" \
    --lacks "$PASSWORD" --lacks "$WRONG_PASSWORD" --lacks "${DEVID_P12:0:40}" --lacks "${SELFTEST_P12:0:40}" \
    -- run_sign "$@"
}

# log_case NAME [checks]...: check_case on the stub log of the last run, which
# must never hold a secret.
log_case() {
  local name="$1"
  shift
  check_case "$name" 0 "$@" --lacks "$PASSWORD" --lacks "${DEVID_P12:0:40}" -- cat "$log"
}

absent() {
  if [ -e "$2" ]; then t_fail "$1" "$2 exists"; else t_pass "$1"; fi
}

# signed_zip_case NAME ZIP ORIGINAL CN LEVEL: ZIP is LEVEL, signed by CN with
# the runtime flag on x86_64 and arm64, and keeps ORIGINAL's entitlements,
# privacy strings, Ontomeme.pck bytes and 0755 executable.
signed_zip_case() {
  check_case "$1" 0 -- python3 -I -c '
import hashlib, json, subprocess, sys, zipfile
checker, out, original, cn, level = sys.argv[1:6]
def report(path, *args):
    run = subprocess.run([sys.executable, "-I", checker, "--json", *args, path], capture_output=True, text=True)
    assert run.returncode == 0, run.stderr
    return json.loads(run.stdout)["artifacts"][0]
new, old = report(out, f"--expect-macos={level}"), report(original)
assert new["level"] == level, (new["level"], new["reason"])
arches = {b["arch"]: b for b in new["binaries"]}
assert {"x86_64", "arm64"} <= set(arches), sorted(arches)
for b in new["binaries"]:
    assert "runtime" in b["flag_names"] and "adhoc" not in b["flag_names"], b
    assert b["signer"]["subject_cn"] == cn, b["signer"]
assert [b["entitlements"] for b in new["binaries"]] == [b["entitlements"] for b in old["binaries"]], "entitlements"
assert new["privacy"] and new["privacy"] == old["privacy"], (new["privacy"], old["privacy"])
with zipfile.ZipFile(out) as a, zipfile.ZipFile(original) as b:
    pck = "Ontomeme.app/Contents/Resources/Ontomeme.pck"
    assert hashlib.sha256(a.read(pck)).digest() == hashlib.sha256(b.read(pck)).digest(), "pck changed"
    mode = a.getinfo("Ontomeme.app/Contents/MacOS/Ontomeme").external_attr >> 16
    assert mode & 0o777 == 0o755, oct(mode)
' "$here/check_signatures.py" "$2" "$3" "$4" "$5"
}

# --- the stand-in keeps rcodesign 0.29.0's contract -----------------------------
# The macos_sign cases below are only as good as the stand-in, so it refuses
# what the real tool refuses (apple-codesign/src/cli/mod.rs, Verify::run;
# cryptography.rs parse_pfx_data on the p12 0.6.3 crate).

check_case "stand-in verify refuses a .app bundle, like rcodesign 0.29" 1 \
  --has "verify command only works on Mach-O binaries; provided path is a Bundle" \
  -- "$stubs/rcodesign" verify "$f/in/Ontomeme.app"
check_case "stand-in verify refuses a file that is not Mach-O" 1 \
  --has "provided path is a Other" -- "$stubs/rcodesign" verify "$f/in/Ontomeme.app/Contents/Info.plist"
check_case "stand-in verify accepts the signed main executable" 0 \
  --has "no problems detected!" -- "$stubs/rcodesign" verify "$f/in/Ontomeme.app/Contents/MacOS/Ontomeme"
fixture_macho "$f/unsigned.macho" arm64 unsigned
check_case "stand-in verify refuses an unsigned Mach-O" 1 \
  --has "arm64: no embedded code signature" -- "$stubs/rcodesign" verify "$f/unsigned.macho"

mkdir -p "$f/contract"
cp -Rp "$f/in/Ontomeme.app" "$f/contract/"
printf '%s\n' "$PASSWORD" >"$f/contract/p12.password"
fixture_p12 "$f/contract/sha1-chain.p12" "$f/devid" "$PASSWORD" "$f/ca" "${P12_RCODESIGN[@]}"
fixture_p12 "$f/contract/sha1-leaf.p12" "$f/devid" "$PASSWORD" "" "${P12_RCODESIGN[@]}"
# contract_sign P12: the stand-in's sign on the contract copy of the app.
contract_sign() {
  "$stubs/rcodesign" sign --p12-file "$1" --p12-password-file "$f/contract/p12.password" "$f/contract/Ontomeme.app"
}
check_case "stand-in sign refuses an OpenSSL 3 default p12 (SHA-256 MAC) as rcodesign 0.29 does" 1 \
  --has "Error: incorrect password given when decrypting PFX data" -- contract_sign "$f/devid.p12"
check_case "stand-in sign takes the last certificate in the p12 as the signer, as rcodesign 0.29 does" 1 \
  --has "signs with the last certificate in the .p12, subject=CN=Developer ID Certification Authority" \
  -- contract_sign "$f/contract/sha1-chain.p12"
check_case "stand-in sign takes a SHA-1 MAC, 3DES p12 holding the leaf alone" 0 \
  --has "signing $f/contract/Ontomeme.app in place (stand-in)" -- contract_sign "$f/contract/sha1-leaf.p12"

# --- skip path -----------------------------------------------------------------

sign_case "no APPLE_P12 -> skipped, exit 0" 0 \
  --has "macOS signing skipped (no APPLE_P12)" \
  -- "$work/skip.zip"
check_case "skip path: OUT is byte-identical to IN (sha256)" 0 \
  --has "$(sha256sum <"$f/in.zip")" -- sha256sum <"$work/skip.zip"
check_case "skip path: rcodesign never runs" 0 --lacks "rcodesign" -- cat "$log"
check_case "skip path: OUT keeps a readable mode" 0 --has "644" -- file_mode "$work/skip.zip"

# --- signing with the stand-in rcodesign ---------------------------------------

sign_case "Developer ID p12 -> signed, verified, re-zipped" 0 \
  --has "macOS signing: signing Ontomeme.app as '$TEST_DEVID_CN'" \
  --has "Ontomeme.app: developer-id" --has "macOS signing: done, $work/devid.zip holds Ontomeme.app" \
  -- "$work/devid.zip" APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$PASSWORD"
log_case "rcodesign sign args: p12 and password files, runtime flag, --for-notarization" \
  --match "^rcodesign sign --p12-file $tmp/[^ ]+/signing\.p12 --p12-password-file $tmp/[^ ]+/p12\.password --code-signature-flags runtime --for-notarization $tmp/[^ ]+/Ontomeme\.app $" \
  --match "^rcodesign verify $tmp/[^ ]+/Ontomeme\.app/Contents/MacOS/Ontomeme $"
log_case "the p12 and its password file are private (0600) while rcodesign runs" \
  --has "fact p12-mode=600 password-mode=600"
log_case "rcodesign gets APPLE_P12 re-exported: SHA-1 MAC, 3DES, the leaf alone" \
  --has "fact p12 MAC: sha1;" --has "Shrouded Keybag: pbeWithSHA1And3-KeyTripleDES-CBC;" \
  --lacks "PBES2" --has "fact p12-certs=1"
log_case "no private key lies in the clear beside the p12 while rcodesign runs" \
  --has "fact clear-keys-beside-p12=0"
signed_zip_case "signed zip: developer-id, runtime on both arches, entitlements, privacy, pck, 0755" \
  "$work/devid.zip" "$f/in.zip" "$TEST_DEVID_CN" developer-id
check_case "signed zip mode is 644" 0 --has "644" -- file_mode "$work/devid.zip"

if fixture_p12 "$f/keychain.p12" "$f/devid" "$PASSWORD" "$f/ca" -legacy 2>/dev/null; then
  KEYCHAIN_P12="$(base64 -w0 "$f/keychain.p12")"
  sign_case "Keychain-style p12 (RC2-40 certificates, 3DES key, SHA-1 MAC) -> signed" 0 \
    --has "macOS signing: done" --lacks "${KEYCHAIN_P12:0:40}" \
    -- "$work/keychain.zip" APPLE_P12="$KEYCHAIN_P12" APPLE_P12_PASSWORD="$PASSWORD"
  log_case "Keychain-style p12: rcodesign still gets the SHA-1 MAC, 3DES leaf-only re-export" \
    --has "fact p12 MAC: sha1;PKCS7 Encrypted data: pbeWithSHA1And3-KeyTripleDES-CBC;" --has "fact p12-certs=1"
  signed_zip_case "Keychain-style p12: developer-id, signed by the leaf, runtime on both arches" \
    "$work/keychain.zip" "$f/in.zip" "$TEST_DEVID_CN" developer-id
else
  t_skip "Keychain-style p12 (this openssl cannot write a -legacy p12)"
fi

sign_case "rcodesign without --for-notarization in sign --help -> not passed" 0 \
  --has "macOS signing: done" \
  -- "$work/old.zip" APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$PASSWORD" STUB_RCODESIGN=old-help
log_case "older rcodesign: sign args lack --for-notarization" \
  --match "^rcodesign sign .*--code-signature-flags runtime $tmp/[^ ]+/Ontomeme\.app $" --lacks "--for-notarization"

sign_case "self-signed (not Developer ID) p12 -> signed, without --for-notarization" 0 \
  --has "'$SELFTEST_CN' is not a Developer ID Application certificate" \
  --has "Ontomeme.app: signed" --has "macOS signing: done" \
  -- "$work/selftest.zip" APPLE_P12="$SELFTEST_P12" APPLE_P12_PASSWORD="$PASSWORD"
log_case "self-signed: sign args lack --for-notarization" --lacks "--for-notarization"
signed_zip_case "self-signed zip: signed by $SELFTEST_CN, runtime on both arches, pck, 0755" \
  "$work/selftest.zip" "$f/in.zip" "$SELFTEST_CN" signed

sign_case "rcodesign drops the entitlements -> signs again with --entitlements-xml-path" 0 \
  --has "rcodesign did not keep the entitlements" \
  --has "entitlements of Contents/MacOS/Ontomeme x86_64 changed: {com.apple.security.cs.allow-jit, com.apple.security.device.audio-input} -> {}" \
  --has "macOS signing: done" \
  -- "$work/dropped.zip" APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$PASSWORD" STUB_RCODESIGN=drop-entitlements
log_case "second sign passes the original entitlements file" \
  --match "^rcodesign sign .* --entitlements-xml-path $tmp/[^ ]+/entitlements\.xml $tmp/[^ ]+/Ontomeme\.app $"
signed_zip_case "re-signed zip keeps the original entitlements" \
  "$work/dropped.zip" "$f/in.zip" "$TEST_DEVID_CN" developer-id

sign_case "entitlements still lost after --entitlements-xml-path -> exit 1" 1 \
  --has "macOS signing: ERROR: entitlements of Contents/MacOS/Ontomeme x86_64 changed" \
  -- "$work/lost.zip" APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$PASSWORD" STUB_RCODESIGN=drop-entitlements-always
absent "entitlements lost: no OUT written" "$work/lost.zip"

sign_case "Info.plist privacy strings changed -> exit 1" 1 \
  --has "privacy strings of Contents/Info.plist changed" \
  -- "$work/privacy.zip" APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$PASSWORD" STUB_RCODESIGN=edit-info-plist
absent "privacy strings changed: no OUT written" "$work/privacy.zip"

sign_case "rcodesign sign fails -> exit 1, no OUT, temp dir removed" 1 \
  --has "macOS signing: ERROR: rcodesign sign failed" --has "stand-in signing failure" \
  -- "$work/failsign.zip" APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$PASSWORD" STUB_RCODESIGN=fail-sign
absent "rcodesign sign failed: no OUT written" "$work/failsign.zip"

sign_case "rcodesign verify fails -> exit 1" 1 \
  --has "macOS signing: ERROR: rcodesign verify failed on the signed app's Contents/MacOS/Ontomeme" \
  -- "$work/failverify.zip" APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$PASSWORD" STUB_RCODESIGN=fail-verify
absent "rcodesign verify failed: no OUT written" "$work/failverify.zip"

sign_case "wrong APPLE_P12_PASSWORD -> exit 1 before rcodesign signs" 1 \
  --has "APPLE_P12_PASSWORD does not open APPLE_P12" \
  -- "$work/wrongpw.zip" APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$WRONG_PASSWORD"
check_case "wrong password: rcodesign never signs" 0 --lacks "rcodesign sign --p12" -- cat "$log"

sign_case "APPLE_P12 that is not base64 -> exit 1" 1 \
  --has "APPLE_P12 is not valid base64" \
  -- "$work/garbage.zip" APPLE_P12='!!! not base64 !!!' APPLE_P12_PASSWORD="$PASSWORD"

sign_case "RCODESIGN naming a missing binary -> exit 1, says how to install" 1 \
  --has "rcodesign not found ('/nonexistent/rcodesign'): run scripts/sign/install_rcodesign.sh DIR or set RCODESIGN" \
  -- "$work/missing.zip" APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$PASSWORD" RCODESIGN=/nonexistent/rcodesign

mkdir -p "$work/elsewhere"
cp -f "$stubs/rcodesign" "$work/elsewhere/my-rcodesign"
check_case "RCODESIGN selects a binary that is not on PATH" 0 \
  --has "macOS signing: done" \
  -- isolated APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$PASSWORD" RCODESIGN="$work/elsewhere/my-rcodesign" \
  PATH="/usr/bin:/bin" -- bash "$here/macos_sign.sh" "$f/in.zip" "$work/elsewhere.zip"

check_case "a zip holding more than the .app -> exit 1" 1 \
  --has "expected the zip to hold one X.app and nothing else" \
  -- isolated APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$PASSWORD" -- \
  bash "$here/macos_sign.sh" "$f/two.zip" "$work/two-out.zip"

check_case "CFBundleExecutable names a missing file -> exit 1 before rcodesign runs" 1 \
  --has "Ontomeme.app has no main executable at Contents/MacOS/Gone" \
  -- isolated APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$PASSWORD" -- \
  bash "$here/macos_sign.sh" "$f/noexe.zip" "$work/noexe-out.zip"
check_case "missing main executable: rcodesign never signs" 0 --lacks "rcodesign sign --p12" -- cat "$log"

check_case "one argument -> usage, exit 2" 2 --has "usage: macos_sign.sh IN.zip OUT.zip" \
  -- bash "$here/macos_sign.sh" "$f/in.zip"

sign_case "in GitHub Actions, errors are ::error:: annotations" 1 \
  --has "::error::macOS signing: rcodesign sign failed" \
  -- "$work/gha.zip" GITHUB_ACTIONS=true APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$PASSWORD" STUB_RCODESIGN=fail-sign

check_case "bash -x does not trace secrets" 0 \
  --has "macOS signing: done" --lacks "$PASSWORD" --lacks "${DEVID_P12:0:40}" \
  -- isolated APPLE_P12="$DEVID_P12" APPLE_P12_PASSWORD="$PASSWORD" -- \
  bash -x "$here/macos_sign.sh" "$f/in.zip" "$work/traced.zip"

# --- install_rcodesign.sh with the stand-in curl ----------------------------------

head -c 1024 /dev/urandom >"$f/wrong-bytes.tar.gz"
check_case "install_rcodesign: sha256 mismatch -> exit 1, nothing extracted" 1 \
  --has "install_rcodesign: sha256 mismatch for https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/0.29.0/apple-codesign-0.29.0-" \
  --has "nothing installed" \
  -- isolated STUB_CURL_BODY="$f/wrong-bytes.tar.gz" -- bash "$here/install_rcodesign.sh" "$work/bin-bad"
check_case "install_rcodesign: downloads with curl -fsSL -o to a fixed path" 0 \
  --match "^curl -fsSL -o $tmp/[^ ]+/rcodesign\.tar\.gz https://github\.com/indygreg/apple-platform-rs/releases/download/apple-codesign/0\.29\.0/apple-codesign-0\.29\.0-[a-z0-9_]+-[a-z]+-[a-z]+(-musl)?\.tar\.gz $" \
  -- cat "$log"
check_case "install_rcodesign: refused download leaves DEST_DIR without rcodesign" 0 \
  --lacks "rcodesign" -- ls -A "$work/bin-bad"

check_case "install_rcodesign: failed download -> exit 1" 1 \
  --has "install_rcodesign: download failed" \
  -- isolated -- bash "$here/install_rcodesign.sh" "$work/bin-404"

mkdir -p "$work/uname"
printf '#!/bin/sh\ncase "$1" in -s) echo Plan9 ;; -m) echo mips ;; *) echo Plan9 ;; esac\n' >"$work/uname/uname"
chmod 755 "$work/uname/uname"
check_case "install_rcodesign: a host without a pinned build -> exit 1" 1 \
  --has "no pinned apple-codesign 0.29.0 build for Plan9 mips" \
  -- isolated STUB_CURL_BODY="$f/wrong-bytes.tar.gz" PATH="$work/uname:$stubs:$PATH" -- \
  bash "$here/install_rcodesign.sh" "$work/bin-plan9"

check_case "install_rcodesign: no DEST_DIR -> usage, exit 2" 2 \
  --has "usage: install_rcodesign.sh DEST_DIR" -- bash "$here/install_rcodesign.sh"

mkdir -p "$f/tarball/apple-codesign-0.29.0-test"
printf '#!/bin/sh\necho stand-in rcodesign\n' >"$f/tarball/apple-codesign-0.29.0-test/rcodesign"
printf 'license' >"$f/tarball/apple-codesign-0.29.0-test/COPYING"
tar -czf "$f/good.tar.gz" -C "$f/tarball" apple-codesign-0.29.0-test
good_sha="$(sha256sum "$f/good.tar.gz" | cut -d ' ' -f 1)"
: >"$work/github_path"
check_case "install_from: verified tarball -> DEST/rcodesign, path printed, GITHUB_PATH appended" 0 \
  --has "$work/bin-ok/rcodesign" \
  -- isolated STUB_CURL_BODY="$f/good.tar.gz" GITHUB_PATH="$work/github_path" -- \
  bash -c '. "$1" && install_from https://example.invalid/good.tar.gz "$2" apple-codesign-0.29.0-test/rcodesign "$3"' \
  _ "$here/install_rcodesign.sh" "$good_sha" "$work/bin-ok"
check_case "install_from: rcodesign is 0755 and runs; only it is installed" 0 \
  --has "stand-in rcodesign" --has "755" --lacks "COPYING" \
  -- sh -c '"$1/rcodesign"; stat -c %a "$1/rcodesign"; ls -A "$1"' _ "$work/bin-ok"
check_case "install_from: GITHUB_PATH gets DEST_DIR" 0 --has "$work/bin-ok" -- cat "$work/github_path"

# --- real rcodesign on the real export (opt-in) -----------------------------------

if [ -z "$REAL_RCODESIGN" ]; then
  t_skip "real rcodesign run (RCODESIGN is not set)"
else
  real="$work/real"
  mkdir -p "$real"
  status=0
  fixture_godot_exports "$real" || status=$?
  if [ "$status" -eq 2 ]; then
    t_skip "real rcodesign run ($FIXTURE_REASON)"
  elif [ "$status" -ne 0 ]; then
    t_fail "real rcodesign run" "$FIXTURE_REASON"
  else
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$f/selftest-rsa.key" -out "$f/selftest-rsa.pem" \
      -subj "/CN=$SELFTEST_CN" -days 2 -addext "extendedKeyUsage=codeSigning" 2>/dev/null
    # The p12 a Linux user makes (OpenSSL 3 defaults) with a CA certificate
    # after the leaf: real rcodesign 0.29 reads neither as given, so this also
    # proves macos_sign.sh's re-export (the signer must be the leaf).
    fixture_p12 "$f/selftest-rsa.p12" "$f/selftest-rsa" "$PASSWORD" "$f/ca" "${P12_MODERN[@]}"
    check_case "real rcodesign signs the real export with a self-signed p12" 0 \
      --has "macOS signing: done" --lacks "$PASSWORD" \
      -- isolated APPLE_P12="$(base64 -w0 "$f/selftest-rsa.p12")" APPLE_P12_PASSWORD="$PASSWORD" \
      RCODESIGN="$REAL_RCODESIGN" -- bash "$here/macos_sign.sh" "$real/Ontomeme.zip" "$real/signed.zip"
    signed_zip_case "real export: signed by $SELFTEST_CN, runtime on x86_64 and arm64, pck unchanged, 0755" \
      "$real/signed.zip" "$real/Ontomeme.zip" "$SELFTEST_CN" signed
  fi
fi

t_finish
