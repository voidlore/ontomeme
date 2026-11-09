#!/usr/bin/env bash
# Validate the release signing secrets in seconds, before a long release run,
# and say what will be signed. Run it locally before pushing the secrets, or as
# the first signing step in CI.
#
#   APPLE_P12=<base64 .p12> APPLE_P12_PASSWORD=... APPLE_TEAM_ID=... \
#   ASC_KEY=<base64 or PEM .p8> ASC_KEY_ID=... ASC_ISSUER_ID=... \
#   WIN_SIGN_STORETYPE=... WIN_SIGN_*=... scripts/sign/preflight.sh
#
# Every variable is optional. A group whose main secret (APPLE_P12, ASC_KEY,
# WIN_SIGN_STORETYPE) is empty is off, which is not an error. A group that is
# set must validate: a Developer ID Application certificate with its private
# key, unexpired, whose team ID equals APPLE_TEAM_ID; an EC P-256 App Store
# Connect key with a 10-character key ID and a UUID issuer; and, for Windows,
# the WIN_SIGN_* variables its jsign storetype needs (presence only; ESIGNER
# also needs WIN_SIGN_KEYPASS, its TOTP secret).
#
# Exit 0 when every group that is set validates, 1 otherwise. With
# GITHUB_OUTPUT set, appends macos_sign, macos_notarize and windows_sign
# (true|false). It prints only the certificate CN, team ID and expiry date,
# never a secret value, and keeps decoded secrets in a private temp dir that
# is removed on exit.
set +x # never trace: the environment holds secrets
set -uo pipefail
umask 077

work=""
cleanup() { if [ -n "$work" ]; then rm -rf "$work"; fi; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
work="$(mktemp -d)" || {
  echo "preflight: cannot create a temp dir" >&2
  exit 1
}

DEVELOPER_ID_CN='^Developer ID Application: .+ \(([A-Z0-9]{10})\)$'
TEN_CHAR_ID='^[A-Z0-9]{10}$'
UUID='^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$'
THIRTY_DAYS=2592000

failed=0
macos_sign=false
macos_notarize=false
windows_sign=false

# error GROUP MESSAGE / warn GROUP MESSAGE: one line on stderr, as a GitHub
# annotation when running in Actions.
error() {
  failed=1
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error::$1: $2" >&2; else echo "$1: ERROR: $2" >&2; fi
}
warn() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::warning::$1: $2" >&2; else echo "$1: warning: $2" >&2; fi
}

# decode_base64 VALUE OUT: decode VALUE (whitespace ignored) into OUT; fails on
# bad input or an empty result. printf is a builtin, so VALUE is never in argv.
decode_base64() {
  printf '%s' "$1" | tr -d '[:space:]' | base64 -d >"$2" 2>/dev/null && [ -s "$2" ]
}

# --- macOS signing ---------------------------------------------------------

P12_MODE=() # empty, or (-legacy) for the RC2/3DES files older Keychain Access exports

# p12 ARGS...: openssl pkcs12 on the decoded APPLE_P12; the password comes from
# the environment (never argv) and openssl's messages go to a private log.
p12() {
  openssl pkcs12 ${P12_MODE[@]+"${P12_MODE[@]}"} -in "$work/apple.p12" -passin env:APPLE_P12_PASSWORD "$@" 2>>"$work/openssl.log"
}

# open_p12: find the mode that opens the file, extracting its certificates.
open_p12() {
  P12_MODE=()
  if p12 -nokeys -out "$work/certs.pem"; then return 0; fi
  P12_MODE=(-legacy)
  p12 -nokeys -out "$work/certs.pem"
}

cert_cn() {
  openssl x509 -in "$1" -noout -subject -nameopt multiline,utf8,-esc_msb 2>/dev/null |
    sed -n 's/^ *commonName *= //p' | head -n 1
}

cert_expiry() {
  local end
  end="$(openssl x509 -in "$1" -noout -enddate -dateopt iso_8601 2>/dev/null ||
    openssl x509 -in "$1" -noout -enddate 2>/dev/null)"
  echo "${end#notAfter=}"
}

check_macos_signing() {
  local group="macOS signing" leaf="$work/leaf.pem" cn team expiry key_pub cert_pub
  if [ -z "${APPLE_P12:-}" ]; then
    echo "$group: off (no APPLE_P12)"
    if [ -n "${APPLE_P12_PASSWORD:-}${APPLE_TEAM_ID:-}" ]; then
      warn "$group" "APPLE_P12_PASSWORD or APPLE_TEAM_ID is set but APPLE_P12 is empty, so nothing is signed"
    fi
    return 0
  fi
  if ! decode_base64 "$APPLE_P12" "$work/apple.p12"; then
    error "$group" "APPLE_P12 is not valid base64 (encode the .p12 with: base64 -w0 cert.p12)"
    return 1
  fi
  export APPLE_P12_PASSWORD="${APPLE_P12_PASSWORD-}"
  if ! open_p12; then
    if grep -qiE 'invalid password|mac verify' "$work/openssl.log"; then
      error "$group" "APPLE_P12_PASSWORD does not open APPLE_P12 (wrong password?)"
    else
      error "$group" "APPLE_P12 does not decode to a readable .p12 file"
    fi
    return 1
  fi
  # The key only ever flows through a pipe, never to disk or a variable.
  key_pub="$(p12 -nocerts -nodes | openssl pkey -pubout 2>/dev/null)"
  if [ -z "$key_pub" ]; then
    error "$group" "APPLE_P12 holds no private key (export the certificate together with its key)"
    return 1
  fi
  p12 -nokeys -clcerts -out "$leaf" || true
  if ! grep -q 'BEGIN CERTIFICATE' "$leaf" 2>/dev/null; then cp -f "$work/certs.pem" "$leaf"; fi
  cn="$(cert_cn "$leaf")"
  if [ -z "$cn" ]; then
    error "$group" "APPLE_P12 holds no certificate with a common name"
    return 1
  fi
  cert_pub="$(openssl x509 -in "$leaf" -noout -pubkey 2>/dev/null)"
  if [ "$key_pub" != "$cert_pub" ]; then
    error "$group" "the private key in APPLE_P12 does not match its certificate '$cn'"
    return 1
  fi
  case "$cn" in
    "Apple Distribution:"* | "Apple Development:"*)
      error "$group" "the certificate is '$cn', not a Developer ID Application certificate (export 'Developer ID Application' from Keychain Access instead)"
      return 1
      ;;
  esac
  if ! [[ $cn =~ $DEVELOPER_ID_CN ]]; then
    error "$group" "the certificate is '$cn', not a Developer ID Application certificate"
    return 1
  fi
  team="${BASH_REMATCH[1]}"
  if [ -z "${APPLE_TEAM_ID:-}" ]; then
    error "$group" "APPLE_TEAM_ID is not set (the certificate's team ID is $team)"
    return 1
  fi
  if [ "$team" != "$APPLE_TEAM_ID" ]; then
    error "$group" "the certificate's team ID $team does not match APPLE_TEAM_ID ($APPLE_TEAM_ID)"
    return 1
  fi
  expiry="$(cert_expiry "$leaf")"
  if ! openssl x509 -in "$leaf" -noout -checkend 0 >/dev/null 2>&1; then
    error "$group" "the certificate '$cn' expired on $expiry"
    return 1
  fi
  if ! openssl x509 -in "$leaf" -noout -checkend "$THIRTY_DAYS" >/dev/null 2>&1; then
    warn "$group" "the certificate '$cn' expires on $expiry, in under 30 days: renew it"
  fi
  macos_sign=true
  echo "$group: on, '$cn', team $team, expires $expiry"
}

# --- macOS notarization ----------------------------------------------------

check_macos_notarization() {
  local group="macOS notarization" key="$work/asc.p8" ok=true
  if [ -z "${ASC_KEY:-}" ]; then
    echo "$group: off (no ASC_KEY)"
    if [ -n "${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]; then
      warn "$group" "ASC_KEY_ID or ASC_ISSUER_ID is set but ASC_KEY is empty, so nothing is notarized"
    fi
    return 0
  fi
  if [[ $ASC_KEY == *"-----BEGIN"* ]]; then
    printf '%s\n' "$ASC_KEY" >"$key"
  elif ! decode_base64 "$ASC_KEY" "$key"; then
    error "$group" "ASC_KEY is neither a PEM key nor valid base64 (encode the .p8 with: base64 -w0 AuthKey.p8)"
    ok=false
  fi
  if [ "$ok" = true ] && ! openssl pkey -in "$key" -noout 2>/dev/null; then
    error "$group" "ASC_KEY is not a readable private key (.p8)"
    ok=false
  elif [ "$ok" = true ] && ! openssl pkey -in "$key" -pubout 2>/dev/null |
    openssl pkey -pubin -noout -text 2>/dev/null | grep -qE 'prime256v1|P-256'; then
    error "$group" "ASC_KEY is not an EC P-256 key (App Store Connect API keys are)"
    ok=false
  fi
  if ! [[ ${ASC_KEY_ID:-} =~ $TEN_CHAR_ID ]]; then
    error "$group" "ASC_KEY_ID is not a 10-character key ID (A-Z, 0-9)"
    ok=false
  fi
  if ! [[ ${ASC_ISSUER_ID:-} =~ $UUID ]]; then
    error "$group" "ASC_ISSUER_ID is not an issuer UUID (8-4-4-4-12 hex digits)"
    ok=false
  fi
  if [ "$ok" != true ]; then return 1; fi
  if [ "$macos_sign" != true ]; then
    echo "$group: off (needs macOS signing: only a Developer ID signed app can be notarized)"
    return 0
  fi
  macos_notarize=true
  echo "$group: on (App Store Connect API key, EC P-256)"
}

# --- Windows signing (presence only) ---------------------------------------

check_windows_signing() {
  local group="Windows signing" store="${WIN_SIGN_STORETYPE:-}" var
  local -a required missing=()
  if [ -z "$store" ]; then
    echo "$group: off (no WIN_SIGN_STORETYPE)"
    return 0
  fi
  if ! [[ $store =~ ^[A-Za-z0-9_]+$ ]]; then
    error "$group" "WIN_SIGN_STORETYPE is not a jsign storetype name (letters, digits, _)"
    return 1
  fi
  # The same requirements as windows_sign.sh.
  case "$store" in
    PKCS12) required=(WIN_PFX WIN_SIGN_STOREPASS) ;;
    ESIGNER) required=(WIN_SIGN_KEYSTORE WIN_SIGN_STOREPASS WIN_SIGN_ALIAS WIN_SIGN_KEYPASS) ;;
    *) required=(WIN_SIGN_KEYSTORE WIN_SIGN_STOREPASS WIN_SIGN_ALIAS) ;;
  esac
  for var in "${required[@]}"; do
    if [ -z "${!var:-}" ]; then missing+=("$var"); fi
  done
  if [ ${#missing[@]} -eq 1 ]; then
    error "$group" "WIN_SIGN_STORETYPE=$store also needs ${missing[0]}, which is not set"
    return 1
  elif [ ${#missing[@]} -gt 1 ]; then
    error "$group" "WIN_SIGN_STORETYPE=$store also needs ${missing[*]}, which are not set"
    return 1
  fi
  windows_sign=true
  echo "$group: on (jsign storetype $store; ${required[*]} set)"
}

check_macos_signing
check_macos_notarization
check_windows_signing

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'macos_sign=%s\nmacos_notarize=%s\nwindows_sign=%s\n' \
    "$macos_sign" "$macos_notarize" "$windows_sign" >>"$GITHUB_OUTPUT"
fi
exit "$failed"
