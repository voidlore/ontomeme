#!/usr/bin/env bash
# Notarize the Developer-ID-signed Ontomeme.app in SIGNED.zip with Apple's
# notary service, using an App Store Connect API key, staple the ticket into
# the app and write the re-zipped result. Runs on Linux, after macos_sign.sh,
# so the first-time Mac user's Gatekeeper finds the ticket inside the app.
#
#   ASC_KEY=<base64 or PEM .p8> ASC_KEY_ID=... ASC_ISSUER_ID=... \
#   [NOTARY_TIMEOUT=1800] [RCODESIGN=/path/to/rcodesign] \
#     scripts/sign/macos_notarize.sh build/macos/Ontomeme-signed.zip build/macos/Ontomeme-notarized.zip
#
# When ASC_KEY, ASC_KEY_ID or ASC_ISSUER_ID is empty it copies IN to OUT byte
# for byte, prints 'macOS notarization skipped (...)' and exits 0. Otherwise,
# inside a private temp dir that is removed on exit, it:
#   1. requires check_signatures.py --expect-macos=developer-id on IN (Apple
#      rejects anything else, so this fails in seconds, not after an upload),
#   2. decodes the .p8 to a file and turns it into rcodesign's API key file:
#      `rcodesign encode-app-store-connect-api-key -o key.json ISSUER KEY_ID key.p8`,
#   3. extracts the zip and runs `timeout NOTARY_TIMEOUT rcodesign notary-submit
#      --api-key-file key.json --max-wait-seconds NOTARY_TIMEOUT --staple X.app`,
#   4. on failure, finds the submission ID in rcodesign's output and runs
#      `rcodesign notary-log` so Apple's list of issues lands in the CI log,
#      then exits 1,
#   5. on success re-zips the stapled app (lib_zip.sh, as macos_sign.sh does)
#      and asserts check_signatures.py --expect-macos=stapled on it.
# OUT is written only when every step passes. It never prints key material.
# Exit 0 on success or skip, 1 on failure, 2 on a usage error.
set +x # never trace: the environment holds secrets
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib_zip.sh
. "$here/lib_zip.sh"

fail() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error::macOS notarization: $1" >&2; else echo "macOS notarization: ERROR: $1" >&2; fi
  exit 1
}

if [ $# -ne 2 ]; then
  echo "usage: macos_notarize.sh SIGNED.zip OUT.zip" >&2
  exit 2
fi
in="$1" out="$2"
limit="${NOTARY_TIMEOUT:-1800}"
if ! [[ $limit =~ ^[1-9][0-9]*$ ]]; then
  echo "macos_notarize.sh: NOTARY_TIMEOUT must be a whole number of seconds, not '$limit'" >&2
  exit 2
fi
[ -f "$in" ] || fail "no such file: $in"

missing=()
for var in ASC_KEY ASC_KEY_ID ASC_ISSUER_ID; do
  if [ -z "${!var:-}" ]; then missing+=("$var"); fi
done
if [ ${#missing[@]} -gt 0 ]; then
  zip_copy_through "$in" "$out"
  echo "macOS notarization skipped (no ${missing[*]})"
  exit 0
fi

check() { python3 -I "$here/check_signatures.py" "$@"; }

check --expect-macos=developer-id "$in" >/dev/null ||
  fail "$in is not Developer ID signed, so Apple would reject it (sign it with macos_sign.sh and a Developer ID Application certificate first)"

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

# --- the API key ------------------------------------------------------------

key_p8="$work/key.p8" key_json="$work/key.json"
# printf is a builtin, so the key never reaches argv.
if [[ $ASC_KEY == *"-----BEGIN"* ]]; then
  printf '%s\n' "$ASC_KEY" >"$key_p8"
else
  printf '%s' "$ASC_KEY" | tr -d '[:space:]' | base64 -d >"$key_p8" 2>/dev/null && [ -s "$key_p8" ] ||
    fail "ASC_KEY is neither a PEM key nor valid base64 (encode the .p8 with: base64 -w0 AuthKey.p8)"
fi
"$rcodesign" encode-app-store-connect-api-key -o "$key_json" "$ASC_ISSUER_ID" "$ASC_KEY_ID" "$key_p8" ||
  fail "rcodesign cannot read the App Store Connect API key (scripts/sign/preflight.sh says more)"

# --- submit, wait, staple ------------------------------------------------------

zip_extract "$in" "$work/app" || fail "cannot extract $in"
app="$(zip_single_app "$work/app")" || fail "$in does not hold just one .app"

limiter=()
if command -v timeout >/dev/null 2>&1; then limiter=(timeout "$limit"); fi
echo "macOS notarization: submitting $(basename "$app") to Apple, waiting up to ${limit}s"
status=0
${limiter[@]+"${limiter[@]}"} "$rcodesign" notary-submit --api-key-file "$key_json" \
  --max-wait-seconds "$limit" --staple "$app" 2>&1 | tee "$work/submit.log" || status=$?

if [ "$status" -ne 0 ]; then
  id="$(sed -n 's/.*created submission ID: \([0-9A-Za-z-]*\).*/\1/p' "$work/submit.log" | tail -n 1)"
  reason="rcodesign notary-submit failed (exit $status)"
  if [ "$status" -eq 124 ]; then reason="no result within NOTARY_TIMEOUT=${limit}s"; fi
  if [ -z "$id" ]; then fail "$reason, before Apple created a submission"; fi
  echo "macOS notarization: Apple's log for submission $id:"
  "$rcodesign" notary-log --api-key-file "$key_json" "$id" || echo "(rcodesign notary-log could not fetch it)"
  fail "$reason (submission $id)"
fi

zip_create "$work/app" "$(basename "$app")" "$work/stapled.zip" || fail "cannot re-zip the stapled app"
check --expect-macos=stapled "$work/stapled.zip" ||
  fail "the re-zipped app has no stapled notarization ticket (see check_signatures.py above)"
mv -f "$work/stapled.zip" "$out"
chmod 644 "$out"
echo "macOS notarization: done, $out holds $(basename "$app") notarized with the ticket stapled"
