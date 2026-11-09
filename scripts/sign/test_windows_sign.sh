#!/usr/bin/env bash
# Tests for windows_sign.sh and install_jsign.sh against stand-in jsign, java
# and curl tools on PATH (lib_fixtures.sh): nothing is downloaded and no
# signing service is called. Opt-in: with JSIGN pointing at a real jsign (a jar
# or command) and GODOT set, a throwaway self-signed PKCS12 signs the real
# Windows export.
#   [JSIGN=/path/to/jsign-7.5.jar GODOT=/path/to/godot] scripts/sign/test_windows_sign.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib_fixtures.sh
. "$here/lib_fixtures.sh"

umask 022
REAL_JSIGN="${JSIGN:-}"
unset JSIGN
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
f="$work/fixtures" stubs="$work/stubs" tmp="$work/tmpdir" log="$work/stub.log"
mkdir -p "$f"
fixture_jsign_stub "$stubs"
fixture_curl_stub "$stubs"

STOREPASS='pfx-Pa55-plover'
TOKEN='eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.stand-in-access-token'
ESIGNER_PASS='esigner-user|esigner-Pa55-grue'
TOTP='totp-SECRET-zork-0123456789'
SELFTEST_CN="Ontomeme Selftest"
CLOUD_CN="Ontomeme Cloud Test"

fixture_cert "$f/selftest" "/CN=$SELFTEST_CN" "" -addext "extendedKeyUsage=codeSigning"
fixture_cert "$f/cloud" "/CN=$CLOUD_CN" "" -addext "extendedKeyUsage=codeSigning"
fixture_p12 "$f/selftest.p12" "$f/selftest" "$STOREPASS"
PFX="$(base64 -w0 "$f/selftest.p12")"
fixture_py pe "$f/Ontomeme.exe" intact
PKCS12=(WIN_SIGN_STORETYPE=PKCS12 WIN_PFX="$PFX" WIN_SIGN_STOREPASS="$STOREPASS")
TRUSTED=(WIN_SIGN_STORETYPE=TRUSTEDSIGNING WIN_SIGN_KEYSTORE=weu.codesigning.azure.net
  WIN_SIGN_STOREPASS="$TOKEN" WIN_SIGN_ALIAS=ontomeme-account/ontomeme-profile STUB_JSIGN_SIGNER="$f/cloud")
ESIGNER=(WIN_SIGN_STORETYPE=ESIGNER WIN_SIGN_KEYSTORE=https://cs.ssl.com WIN_SIGN_STOREPASS="$ESIGNER_PASS"
  WIN_SIGN_ALIAS=8b072e22-7685-4771-b5c6-48e46614915f WIN_SIGN_KEYPASS="$TOTP" STUB_JSIGN_SIGNER="$f/cloud")
APP_ARGS='--name Ontomeme --url https://github\.com/voidlore/ontomeme --alg SHA-256'

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

# sign_case NAME WANT_EXIT [checks]... -- EXE VAR=VALUE...: copy the fixture exe
# to EXE, then check_case on windows_sign.sh EXE, isolated; no secret may
# appear in the output.
sign_case() {
  local name="$1" want="$2" exe
  local -a checks=()
  shift 2
  while [ "$1" != "--" ]; do
    checks+=("$1" "$2")
    shift 2
  done
  exe="$2"
  shift 2
  cp -f "$f/Ontomeme.exe" "$exe"
  check_case "$name" "$want" "${checks[@]}" \
    --lacks "$STOREPASS" --lacks "$TOKEN" --lacks "$ESIGNER_PASS" --lacks "$TOTP" --lacks "${PFX:0:40}" \
    -- isolated "$@" -- bash "$here/windows_sign.sh" "$exe"
}

# log_case NAME [checks]...: check_case on the stub log, which must hold no secret.
log_case() {
  local name="$1"
  shift
  check_case "$name" 0 "$@" --lacks "$STOREPASS" --lacks "$TOKEN" --lacks "$ESIGNER_PASS" --lacks "$TOTP" \
    --lacks "${PFX:0:40}" -- cat "$log"
}

unchanged() {
  check_case "$1" 0 --has "$(sha256sum <"$f/Ontomeme.exe")" -- sha256sum <"$2"
}

signed_by() {
  check_case "$1" 0 --has "Windows $(basename "$2"): signed" --has "signer: $3" \
    --has "pck section: intact (starts with GDPC)" \
    -- python3 -I "$here/check_signatures.py" --expect-windows=signed "$2"
}

# --- skip path -----------------------------------------------------------------

sign_case "no WIN_SIGN_STORETYPE -> skipped, exit 0" 0 \
  --has "Windows signing skipped (no WIN_SIGN_STORETYPE)" \
  -- "$work/skip.exe"
unchanged "skip path: EXE is byte-identical (sha256)" "$work/skip.exe"
check_case "skip path: jsign never runs" 0 --lacks "jsign" -- cat "$log"

# --- signing with the stand-in jsign -------------------------------------------

sign_case "PKCS12 -> signed in place, pck intact" 0 \
  --has "Windows signing: signing pkcs12.exe with jsign (storetype PKCS12, timestamp http://timestamp.digicert.com)" \
  --has "Windows pkcs12.exe: signed" --has "Windows signing: done, $work/pkcs12.exe is signed" \
  -- "$work/pkcs12.exe" "${PKCS12[@]}"
log_case "PKCS12 args: 0600 keystore file, env: storepass, app name/url, SHA-256, RFC 3161 timestamp" \
  --match "^jsign --storetype PKCS12 --keystore $tmp/[^ ]+/signing\.p12 --storepass env:WIN_SIGN_STOREPASS $APP_ARGS --tsaurl http://timestamp\.digicert\.com --tsmode RFC3161 $tmp/[^ ]+/pkcs12\.exe $" \
  --has "fact keystore-mode=600" --has "fact storepass-env=set"
signed_by "PKCS12: check_signatures says signed by the p12's certificate" "$work/pkcs12.exe" "$SELFTEST_CN"

sign_case "PKCS12 with WIN_SIGN_ALIAS passes --alias" 0 \
  --has "Windows signing: done" \
  -- "$work/alias.exe" "${PKCS12[@]}" WIN_SIGN_ALIAS=1
log_case "PKCS12 alias arg" --match "--storepass env:WIN_SIGN_STOREPASS --alias 1 --name Ontomeme "

sign_case "TRUSTEDSIGNING -> signed" 0 \
  --has "storetype TRUSTEDSIGNING, timestamp http://timestamp.acs.microsoft.com" \
  --has "Windows signing: done" \
  -- "$work/trusted.exe" "${TRUSTED[@]}"
log_case "TRUSTEDSIGNING args: endpoint, env: token, account/profile alias, Microsoft TSA" \
  --match "^jsign --storetype TRUSTEDSIGNING --keystore weu\.codesigning\.azure\.net --storepass env:WIN_SIGN_STOREPASS --alias ontomeme-account/ontomeme-profile $APP_ARGS --tsaurl http://timestamp\.acs\.microsoft\.com --tsmode RFC3161 $tmp/[^ ]+/trusted\.exe $"
signed_by "TRUSTEDSIGNING: signed by the service's certificate" "$work/trusted.exe" "$CLOUD_CN"

sign_case "ESIGNER -> signed" 0 \
  --has "storetype ESIGNER, timestamp http://ts.ssl.com" --has "Windows signing: done" \
  -- "$work/esigner.exe" "${ESIGNER[@]}"
log_case "ESIGNER args: env: storepass and keypass (TOTP), credential alias, SSL.com TSA" \
  --match "^jsign --storetype ESIGNER --keystore https://cs\.ssl\.com --storepass env:WIN_SIGN_STOREPASS --alias 8b072e22-7685-4771-b5c6-48e46614915f --keypass env:WIN_SIGN_KEYPASS $APP_ARGS --tsaurl http://ts\.ssl\.com --tsmode RFC3161 $tmp/[^ ]+/esigner\.exe $" \
  --has "fact storepass-env=set keypass-env=set"

sign_case "WIN_SIGN_TSA_URL=none -> no timestamp" 0 \
  --has "timestamp none" --has "Windows signing: done" \
  -- "$work/notsa.exe" "${PKCS12[@]}" WIN_SIGN_TSA_URL=none
log_case "no timestamp: no --tsaurl or --tsmode" --lacks "--tsaurl" --lacks "--tsmode"

sign_case "WIN_SIGN_TSA_URL overrides the default" 0 --has "Windows signing: done" \
  -- "$work/tsa.exe" "${TRUSTED[@]}" WIN_SIGN_TSA_URL=http://timestamp.sectigo.com
log_case "custom TSA arg" --has "--tsaurl http://timestamp.sectigo.com --tsmode RFC3161 "

sign_case "ESIGNER without WIN_SIGN_KEYPASS -> exit 1, jsign never runs" 1 \
  --has "Windows signing: ERROR: WIN_SIGN_STORETYPE=ESIGNER also needs WIN_SIGN_KEYPASS, which is not set" \
  -- "$work/nototp.exe" "${ESIGNER[@]}" WIN_SIGN_KEYPASS=
check_case "missing variable: jsign never runs" 0 --lacks "jsign" -- cat "$log"
unchanged "missing variable: EXE unchanged" "$work/nototp.exe"

sign_case "TRUSTEDSIGNING without an alias or keystore -> exit 1" 1 \
  --has "also needs WIN_SIGN_KEYSTORE WIN_SIGN_ALIAS, which are not set" \
  -- "$work/noalias.exe" WIN_SIGN_STORETYPE=TRUSTEDSIGNING WIN_SIGN_STOREPASS="$TOKEN"

sign_case "jsign fails -> exit 1, EXE unchanged" 1 \
  --has "Windows signing: ERROR: jsign failed; $work/failed.exe is unchanged" \
  -- "$work/failed.exe" "${PKCS12[@]}" STUB_JSIGN=fail
unchanged "jsign failed: EXE byte-identical" "$work/failed.exe"

sign_case "signed copy loses its pck -> exit 1, EXE unchanged" 1 \
  --has "the 'pck' section does not start with GDPC" --has "the signed copy does not check out" \
  -- "$work/badpck.exe" "${PKCS12[@]}" STUB_JSIGN=corrupt-pck
unchanged "lost pck: EXE byte-identical" "$work/badpck.exe"

sign_case "wrong PKCS12 password -> exit 1, EXE unchanged" 1 \
  --has "Failed to load the keystore" --has "jsign failed" \
  -- "$work/wrongpw.exe" "${PKCS12[@]}" WIN_SIGN_STOREPASS=wr0ng
unchanged "wrong password: EXE byte-identical" "$work/wrongpw.exe"

sign_case "WIN_PFX that is not base64 -> exit 1" 1 \
  --has "WIN_PFX is not valid base64" \
  -- "$work/garbage.exe" WIN_SIGN_STORETYPE=PKCS12 WIN_PFX='!!! not base64 !!!' WIN_SIGN_STOREPASS="$STOREPASS"

sign_case "a storetype name with odd characters -> exit 1" 1 \
  --has "WIN_SIGN_STORETYPE is not a jsign storetype name" \
  -- "$work/odd.exe" "${PKCS12[@]}" 'WIN_SIGN_STORETYPE=PKCS12 --debug'

sign_case "JSIGN naming a missing command -> exit 1, says how to install" 1 \
  --has "jsign not found ('/nonexistent/jsign'): run scripts/sign/install_jsign.sh DIR or set JSIGN" \
  -- "$work/missing.exe" "${PKCS12[@]}" JSIGN=/nonexistent/jsign

printf 'stand-in jar' >"$f/jsign-7.5.jar"
sign_case "JSIGN naming a .jar -> run with java -jar" 0 \
  --has "Windows signing: done" \
  -- "$work/jar.exe" "${PKCS12[@]}" JSIGN="$f/jsign-7.5.jar"
log_case "jar: java -jar JAR, then the jsign args" \
  --match "^java -jar $f/jsign-7\.5\.jar --storetype PKCS12 " --match "^jsign --storetype PKCS12 "

check_case "missing EXE -> exit 1" 1 --has "no such file: $work/nowhere.exe" \
  -- isolated "${PKCS12[@]}" -- bash "$here/windows_sign.sh" "$work/nowhere.exe"
check_case "no argument -> usage, exit 2" 2 --has "usage: windows_sign.sh EXE" -- bash "$here/windows_sign.sh"

sign_case "in GitHub Actions, errors are ::error:: annotations" 1 \
  --has "::error::Windows signing: jsign failed" \
  -- "$work/gha.exe" "${PKCS12[@]}" GITHUB_ACTIONS=true STUB_JSIGN=fail

cp -f "$f/Ontomeme.exe" "$work/traced.exe"
check_case "bash -x does not trace secrets" 0 \
  --has "Windows signing: done" --lacks "$STOREPASS" --lacks "${PFX:0:40}" \
  -- isolated "${PKCS12[@]}" -- bash -x "$here/windows_sign.sh" "$work/traced.exe"

# --- install_jsign.sh with the stand-in curl ------------------------------------

head -c 1024 /dev/urandom >"$f/wrong.jar"
check_case "install_jsign: jar sha256 mismatch -> exit 1, nothing installed" 1 \
  --has "install_jsign: sha256 mismatch for https://github.com/ebourg/jsign/releases/download/7.5/jsign-7.5.jar" \
  --has "nothing installed" \
  -- isolated STUB_CURL_BODY="$f/wrong.jar" -- bash "$here/install_jsign.sh" "$work/bin-bad"
check_case "install_jsign: downloads the 7.5 jar with curl -fsSL -o" 0 \
  --match "^curl -fsSL -o $tmp/[^ ]+/jsign-7\.5\.jar https://github\.com/ebourg/jsign/releases/download/7\.5/jsign-7\.5\.jar $" \
  -- cat "$log"
check_case "install_jsign: a refused jar leaves no jar and no jsign wrapper" 0 \
  --lacks "jsign" -- ls -A "$work/bin-bad"

check_case "install_jsign: failed download -> exit 1" 1 --has "install_jsign: download failed" \
  -- isolated -- bash "$here/install_jsign.sh" "$work/bin-404"
check_case "install_jsign: no DEST_DIR -> usage, exit 2" 2 --has "usage: install_jsign.sh DEST_DIR" \
  -- bash "$here/install_jsign.sh"

jar_sha="$(sha256sum "$f/jsign-7.5.jar" | cut -d ' ' -f 1)"
: >"$work/github_path"
check_case "install_from: verified jar -> DEST/jsign-7.5.jar + DEST/jsign, path printed" 0 \
  --has "$work/bin-ok/jsign" \
  -- isolated STUB_CURL_BODY="$f/jsign-7.5.jar" GITHUB_PATH="$work/github_path" -- \
  bash -c '. "$1" && install_from https://example.invalid/jsign.jar "$2" "$3"' \
  _ "$here/install_jsign.sh" "$jar_sha" "$work/bin-ok"
check_case "install_from: GITHUB_PATH gets DEST_DIR" 0 --has "$work/bin-ok" -- cat "$work/github_path"
check_case "install_from: the jsign wrapper runs java -jar on the installed jar" 0 \
  --match "^java -jar $work/bin-ok/jsign-7\.5\.jar --storetype PKCS12 " \
  -- sh -c 'cp -f "$1" "$2" && env PATH="$3:$PATH" STUB_LOG="$4" WIN_SIGN_STOREPASS="$5" \
    "$6/jsign" --storetype PKCS12 --keystore "$7" --storepass env:WIN_SIGN_STOREPASS "$2" >/dev/null && cat "$4"' \
  _ "$f/Ontomeme.exe" "$work/wrapper.exe" "$stubs" "$work/wrapper.log" "$STOREPASS" "$work/bin-ok" "$f/selftest.p12"

# --- real jsign on the real export (opt-in) ---------------------------------------

if [ -z "$REAL_JSIGN" ]; then
  t_skip "real jsign run (JSIGN is not set)"
else
  real="$work/real"
  mkdir -p "$real"
  status=0
  fixture_godot_exports "$real" || status=$?
  if [ "$status" -eq 2 ]; then
    t_skip "real jsign run ($FIXTURE_REASON)"
  elif [ "$status" -ne 0 ]; then
    t_fail "real jsign run" "$FIXTURE_REASON"
  else
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$f/selftest-rsa.key" -out "$f/selftest-rsa.pem" \
      -subj "/CN=$SELFTEST_CN" -days 2 -addext "extendedKeyUsage=codeSigning" 2>/dev/null
    fixture_p12 "$f/selftest-rsa.p12" "$f/selftest-rsa" "$STOREPASS"
    check_case "real jsign signs the real export with a self-signed PKCS12 (no timestamp)" 0 \
      --has "Windows signing: done" --lacks "$STOREPASS" \
      -- isolated WIN_SIGN_STORETYPE=PKCS12 WIN_PFX="$(base64 -w0 "$f/selftest-rsa.p12")" \
      WIN_SIGN_STOREPASS="$STOREPASS" WIN_SIGN_TSA_URL=none JSIGN="$REAL_JSIGN" PATH="$PATH" -- \
      bash "$here/windows_sign.sh" "$real/Ontomeme.exe"
    signed_by "real export: signed by $SELFTEST_CN, pck section starts with GDPC" "$real/Ontomeme.exe" "$SELFTEST_CN"
  fi
fi

t_finish
