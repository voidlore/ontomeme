#!/usr/bin/env bash
# Tests for preflight.sh with throwaway openssl secrets. Every case runs the
# script in a clean environment with its own TMPDIR and GITHUB_OUTPUT, and
# fails when the output holds a secret or the TMPDIR is left non-empty.
#   scripts/sign/test_preflight.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib_fixtures.sh
. "$here/lib_fixtures.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
f="$work/fixtures"
tmp="$work/tmpdir"
outputs="$work/github_output"
mkdir -p "$f"

PASSWORD='s3cr3t-Pa55-xyzzy'
WRONG_PASSWORD='wr0ng-Pa55-plugh'
STOREPASS='st0re-Pa55-frotz'
TEAM=ABCDE12345
KEY_ID=2X9R4HXF34
ISSUER=69a6de7e-1234-47e3-e053-5b8c7c11a4d1

# p12 OUT CERT [openssl pkcs12 -export args...]: CERT.pem + CERT.key as a .p12
# under $PASSWORD.
p12() {
  local out="$1" cert="$2"
  shift 2
  P12_PW="$PASSWORD" openssl pkcs12 -export -inkey "$cert.key" -in "$cert.pem" -passout env:P12_PW -out "$out" "$@"
}
b64() { base64 -w0 "$1"; }

fixture_cert "$f/devid" "/CN=$TEST_DEVID_CN/OU=$TEAM/O=Test Person/C=US" "" -days 400 -addext "extendedKeyUsage=codeSigning"
fixture_cert "$f/distribution" "/CN=Apple Distribution: X ($TEAM)/OU=$TEAM/C=US"
fixture_cert "$f/soon" "/CN=$TEST_DEVID_CN" "" -days 10
p12 "$f/good.p12" "$f/devid"
p12 "$f/distribution.p12" "$f/distribution"
p12 "$f/soon.p12" "$f/soon"
P12_PW="$PASSWORD" openssl pkcs12 -export -nokeys -in "$f/devid.pem" -passout env:P12_PW -out "$f/nokey.p12"
printf 'this is not a p12 file' >"$f/notp12.bin"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$f/asc.p8" 2>/dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$f/p384.p8" 2>/dev/null
ASC_SECRET_LINE="$(sed -n 2p "$f/asc.p8")"

GOOD_P12="$(b64 "$f/good.p12")"
GOOD_ASC="$(b64 "$f/asc.p8")"
GOOD_APPLE=(APPLE_P12="$GOOD_P12" APPLE_P12_PASSWORD="$PASSWORD" APPLE_TEAM_ID="$TEAM")
GOOD_NOTARY=(ASC_KEY="$GOOD_ASC" ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER")

# run_preflight VAR=VALUE...: preflight.sh with only these variables set. Exits
# 99 when it leaves anything in its TMPDIR.
run_preflight() {
  local code=0
  rm -rf "$tmp"
  mkdir -p "$tmp"
  : >"$outputs"
  env -i PATH="$PATH" HOME="$HOME" TMPDIR="$tmp" GITHUB_OUTPUT="$outputs" "$@" bash "$here/preflight.sh" || code=$?
  if [ -n "$(ls -A "$tmp")" ]; then
    echo "LEFT IN TMPDIR: $(ls -A "$tmp" | tr '\n' ' ')"
    return 99
  fi
  return "$code"
}

# preflight_case NAME WANT_EXIT [checks]... -- VAR=VALUE...: check_case on
# run_preflight, also requiring that no secret appears in the output.
preflight_case() {
  local name="$1" want="$2"
  local -a checks=()
  shift 2
  while [ "$1" != "--" ]; do
    checks+=("$1" "$2")
    shift 2
  done
  shift
  check_case "$name" "$want" "${checks[@]}" \
    --lacks "$PASSWORD" --lacks "$WRONG_PASSWORD" --lacks "$STOREPASS" --lacks "$ASC_SECRET_LINE" \
    --lacks "${GOOD_P12:0:40}" \
    -- run_preflight "$@"
}

preflight_case "no env: everything off, exit 0" 0 \
  --has "macOS signing: off (no APPLE_P12)" \
  --has "macOS notarization: off (no ASC_KEY)" \
  --has "Windows signing: off (no WIN_SIGN_STORETYPE)" \
  --lacks "ERROR" --
check_case "no env: GITHUB_OUTPUT gets all three false" 0 \
  --has "macos_sign=false" --has "macos_notarize=false" --has "windows_sign=false" \
  -- cat "$outputs"

preflight_case "good p12 + ASC key: signing and notarization on" 0 \
  --has "macOS signing: on, '$TEST_DEVID_CN', team $TEAM, expires " \
  --has "macOS notarization: on" \
  --has "Windows signing: off" \
  --lacks "ERROR" --lacks "warning" \
  -- "${GOOD_APPLE[@]}" "${GOOD_NOTARY[@]}"
check_case "good: GITHUB_OUTPUT says sign and notarize" 0 \
  --has "macos_sign=true" --has "macos_notarize=true" --has "windows_sign=false" \
  -- cat "$outputs"

if p12 "$f/legacy.p12" "$f/devid" -legacy 2>/dev/null; then
  preflight_case "legacy (RC2) p12 opens through the -legacy retry" 0 \
    --has "macOS signing: on, '$TEST_DEVID_CN'" \
    -- APPLE_P12="$(b64 "$f/legacy.p12")" APPLE_P12_PASSWORD="$PASSWORD" APPLE_TEAM_ID="$TEAM"
else
  t_skip "legacy (RC2) p12 (this openssl cannot write one)"
fi

preflight_case "wrong password -> exit 1, plain message" 1 \
  --has "macOS signing: ERROR: APPLE_P12_PASSWORD does not open APPLE_P12 (wrong password?)" \
  -- APPLE_P12="$GOOD_P12" APPLE_P12_PASSWORD="$WRONG_PASSWORD" APPLE_TEAM_ID="$TEAM"

preflight_case "team mismatch -> exit 1" 1 \
  --has "the certificate's team ID $TEAM does not match APPLE_TEAM_ID (ZZZZZ99999)" \
  -- APPLE_P12="$GOOD_P12" APPLE_P12_PASSWORD="$PASSWORD" APPLE_TEAM_ID=ZZZZZ99999

preflight_case "APPLE_TEAM_ID unset -> exit 1" 1 \
  --has "APPLE_TEAM_ID is not set (the certificate's team ID is $TEAM)" \
  -- APPLE_P12="$GOOD_P12" APPLE_P12_PASSWORD="$PASSWORD"

preflight_case "Apple Distribution certificate rejected by name" 1 \
  --has "the certificate is 'Apple Distribution: X ($TEAM)', not a Developer ID Application certificate" \
  -- APPLE_P12="$(b64 "$f/distribution.p12")" APPLE_P12_PASSWORD="$PASSWORD" APPLE_TEAM_ID="$TEAM"

if fixture_cert "$f/expired" "/CN=$TEST_DEVID_CN" "" -not_before 20200101000000Z -not_after 20210101000000Z; then
  p12 "$f/expired.p12" "$f/expired"
  preflight_case "expired certificate -> exit 1" 1 \
    --has "the certificate '$TEST_DEVID_CN' expired on 2021-01-01" \
    -- APPLE_P12="$(b64 "$f/expired.p12")" APPLE_P12_PASSWORD="$PASSWORD" APPLE_TEAM_ID="$TEAM"
else
  t_skip "expired certificate (this openssl has no req -not_before/-not_after)"
fi

preflight_case "certificate expiring within 30 days -> warning, exit 0" 0 \
  --has "macOS signing: warning: the certificate '$TEST_DEVID_CN' expires on " \
  --has "in under 30 days: renew it" --has "macOS signing: on" \
  -- APPLE_P12="$(b64 "$f/soon.p12")" APPLE_P12_PASSWORD="$PASSWORD" APPLE_TEAM_ID="$TEAM"

preflight_case "garbage base64 -> exit 1" 1 \
  --has "APPLE_P12 is not valid base64" \
  -- APPLE_P12='!!! not base64 !!!' APPLE_P12_PASSWORD="$PASSWORD" APPLE_TEAM_ID="$TEAM"

preflight_case "base64 of something that is not a p12 -> exit 1" 1 \
  --has "APPLE_P12 does not decode to a readable .p12 file" \
  -- APPLE_P12="$(b64 "$f/notp12.bin")" APPLE_P12_PASSWORD="$PASSWORD" APPLE_TEAM_ID="$TEAM"

preflight_case "p12 without a private key -> exit 1" 1 \
  --has "APPLE_P12 holds no private key" \
  -- APPLE_P12="$(b64 "$f/nokey.p12")" APPLE_P12_PASSWORD="$PASSWORD" APPLE_TEAM_ID="$TEAM"

preflight_case "bad ASC_KEY_ID -> exit 1" 1 \
  --has "ASC_KEY_ID is not a 10-character key ID" --has "macOS signing: on" \
  -- "${GOOD_APPLE[@]}" ASC_KEY="$GOOD_ASC" ASC_KEY_ID=abc ASC_ISSUER_ID="$ISSUER"
check_case "bad ASC_KEY_ID: GITHUB_OUTPUT keeps notarization off" 0 \
  --has "macos_sign=true" --has "macos_notarize=false" \
  -- cat "$outputs"

preflight_case "bad ASC_ISSUER_ID -> exit 1" 1 \
  --has "ASC_ISSUER_ID is not an issuer UUID" \
  -- "${GOOD_APPLE[@]}" ASC_KEY="$GOOD_ASC" ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID=not-a-uuid

preflight_case "ASC key on P-384 -> exit 1" 1 \
  --has "ASC_KEY is not an EC P-256 key" \
  -- "${GOOD_APPLE[@]}" ASC_KEY="$(b64 "$f/p384.p8")" ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER"

preflight_case "ASC key that is not a key -> exit 1" 1 \
  --has "ASC_KEY is not a readable private key (.p8)" \
  -- "${GOOD_APPLE[@]}" ASC_KEY="$(b64 "$f/notp12.bin")" ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER"

preflight_case "ASC key given as PEM text -> notarization on" 0 \
  --has "macOS notarization: on" \
  -- "${GOOD_APPLE[@]}" ASC_KEY="$(cat "$f/asc.p8")" ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER"

preflight_case "ASC key without APPLE_P12 -> notarization off, exit 0" 0 \
  --has "macOS signing: off (no APPLE_P12)" \
  --has "macOS notarization: off (needs macOS signing" \
  -- "${GOOD_NOTARY[@]}"

preflight_case "Windows PKCS12 with WIN_PFX and storepass -> on" 0 \
  --has "Windows signing: on (jsign storetype PKCS12; WIN_PFX WIN_SIGN_STOREPASS set)" \
  -- WIN_SIGN_STORETYPE=PKCS12 WIN_PFX="$GOOD_P12" WIN_SIGN_STOREPASS="$STOREPASS"
check_case "Windows on: GITHUB_OUTPUT says windows_sign=true" 0 \
  --has "windows_sign=true" --has "macos_sign=false" \
  -- cat "$outputs"

preflight_case "Windows TRUSTEDSIGNING without an alias -> exit 1" 1 \
  --has "WIN_SIGN_STORETYPE=TRUSTEDSIGNING also needs WIN_SIGN_ALIAS, which is not set" \
  -- WIN_SIGN_STORETYPE=TRUSTEDSIGNING WIN_SIGN_KEYSTORE=weu.codesigning.azure.net WIN_SIGN_STOREPASS="$STOREPASS"

preflight_case "Windows ESIGNER without the TOTP secret (WIN_SIGN_KEYPASS) -> exit 1" 1 \
  --has "WIN_SIGN_STORETYPE=ESIGNER also needs WIN_SIGN_KEYPASS, which is not set" \
  -- WIN_SIGN_STORETYPE=ESIGNER WIN_SIGN_KEYSTORE=https://cs.ssl.com WIN_SIGN_STOREPASS="user|$STOREPASS" \
  WIN_SIGN_ALIAS=8b072e22-7685-4771-b5c6-48e46614915f

preflight_case "in GitHub Actions, errors are ::error:: annotations" 1 \
  --has "::error::macOS signing: APPLE_P12_PASSWORD does not open APPLE_P12" \
  -- GITHUB_ACTIONS=true APPLE_P12="$GOOD_P12" APPLE_P12_PASSWORD="$WRONG_PASSWORD" APPLE_TEAM_ID="$TEAM"

check_case "bash -x does not trace secrets" 0 \
  --has "macOS signing: on" --lacks "$PASSWORD" --lacks "${GOOD_P12:0:40}" \
  -- env -i PATH="$PATH" TMPDIR="$work" "${GOOD_APPLE[@]}" bash -x "$here/preflight.sh"

t_finish
