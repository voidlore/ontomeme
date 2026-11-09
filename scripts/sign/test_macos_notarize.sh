#!/usr/bin/env bash
# Tests for macos_notarize.sh against the stand-in rcodesign (lib_fixtures.sh):
# nothing reaches Apple. Every case runs with a fresh TMPDIR, which must be
# empty afterwards (no key.json or key.p8 left), and output that must never
# hold the .p8 body or the issuer ID.
#   scripts/sign/test_macos_notarize.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib_fixtures.sh
. "$here/lib_fixtures.sh"

umask 022
unset RCODESIGN
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
f="$work/fixtures" stubs="$work/stubs" tmp="$work/tmpdir" log="$work/stub.log"
mkdir -p "$f/signed" "$f/adhoc"
fixture_rcodesign_stub "$stubs"

KEY_ID=2X9R4HXF34
ISSUER=69a6de7e-1234-47e3-e053-5b8c7c11a4d1
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$f/AuthKey.p8" 2>/dev/null
ASC_PEM="$(cat "$f/AuthKey.p8")"
ASC_B64="$(base64 -w0 "$f/AuthKey.p8")"
P8_BODY_LINE="$(sed -n 2p "$f/AuthKey.p8")"
GOOD_ASC=(ASC_KEY="$ASC_B64" ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER")

# A Developer ID signed universal Ontomeme.app (what macos_sign.sh writes) and
# an ad-hoc one (what Godot exports).
fixture_signing_certs "$f"
for arch in x86_64 arm64; do
  fixture_macho "$f/$arch.signed" "$arch" signed "$f/devid" "$f/ca"
  fixture_macho "$f/$arch.adhoc" "$arch" adhoc
done
fixture_py fat "$f/signed.macho" "$f/x86_64.signed" "$f/arm64.signed"
fixture_py fat "$f/adhoc.macho" "$f/x86_64.adhoc" "$f/arm64.adhoc"
fixture_app "$f/signed" Ontomeme "$f/signed.macho"
fixture_app "$f/adhoc" Ontomeme "$f/adhoc.macho"
fixture_py zip "$f/signed.zip" "$f/signed"
fixture_py zip "$f/adhoc.zip" "$f/adhoc"

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

# notarize_case NAME WANT_EXIT [checks]... -- IN OUT VAR=VALUE...: check_case on
# macos_notarize.sh IN OUT, isolated; the output must not hold key material
# or the issuer ID.
notarize_case() {
  local name="$1" want="$2" in out
  local -a checks=()
  shift 2
  while [ "$1" != "--" ]; do
    checks+=("$1" "$2")
    shift 2
  done
  in="$2" out="$3"
  shift 3
  check_case "$name" "$want" "${checks[@]}" \
    --lacks "$P8_BODY_LINE" --lacks "${ASC_B64:0:40}" --lacks "$ISSUER" \
    -- isolated "$@" -- bash "$here/macos_notarize.sh" "$in" "$out"
}

log_case() {
  local name="$1"
  shift
  check_case "$name" 0 "$@" --lacks "$P8_BODY_LINE" --lacks "${ASC_B64:0:40}" -- cat "$log"
}

absent() {
  if [ -e "$2" ]; then t_fail "$1" "$2 exists"; else t_pass "$1"; fi
}

same_bytes() {
  check_case "$1" 0 --has "$(sha256sum <"$2")" -- sha256sum <"$3"
}

# --- skip path -----------------------------------------------------------------

notarize_case "no ASC_* -> skipped, exit 0" 0 \
  --has "macOS notarization skipped (no ASC_KEY ASC_KEY_ID ASC_ISSUER_ID)" \
  -- "$f/signed.zip" "$work/skip.zip"
same_bytes "skip path: OUT is byte-identical to IN (sha256)" "$f/signed.zip" "$work/skip.zip"
check_case "skip path: rcodesign never runs" 0 --lacks "rcodesign" -- cat "$log"

notarize_case "ASC_KEY without ASC_ISSUER_ID -> skipped, naming it" 0 \
  --has "macOS notarization skipped (no ASC_ISSUER_ID)" \
  -- "$f/signed.zip" "$work/skip2.zip" ASC_KEY="$ASC_B64" ASC_KEY_ID="$KEY_ID"
same_bytes "partial secrets: OUT is byte-identical to IN (sha256)" "$f/signed.zip" "$work/skip2.zip"

# --- notarizing with the stand-in rcodesign ----------------------------------------

notarize_case "accepted -> stapled, re-zipped, temp dir removed" 0 \
  --has "macOS notarization: submitting Ontomeme.app to Apple, waiting up to 1800s" \
  --has "created submission ID: $STUB_SUBMISSION_ID" \
  --has "Ontomeme.app: stapled" --has "notarization ticket (Contents/CodeResources): present" \
  --has "macOS notarization: done, $work/stapled.zip holds Ontomeme.app notarized with the ticket stapled" \
  -- "$f/signed.zip" "$work/stapled.zip" "${GOOD_ASC[@]}"
log_case "rcodesign args: encode the key, then notary-submit --staple with a time limit" \
  --match "^rcodesign encode-app-store-connect-api-key -o $tmp/[^ ]+/key\.json $ISSUER $KEY_ID $tmp/[^ ]+/key\.p8 $" \
  --match "^rcodesign notary-submit --api-key-file $tmp/[^ ]+/key\.json --max-wait-seconds 1800 --staple $tmp/[^ ]+/Ontomeme\.app $" \
  --has "fact p8-mode=600" --has "fact key-json-mode=600" --lacks "notary-log"
check_case "stapled zip: check_signatures --expect-macos=stapled, executable 0755" 0 \
  --has "Ontomeme.app: stapled" --has "100755" \
  -- sh -c 'python3 -I "$1" --expect-macos=stapled "$2" &&
    python3 -I -c "import sys, zipfile; print(oct(zipfile.ZipFile(sys.argv[1]).getinfo(\"Ontomeme.app/Contents/MacOS/Ontomeme\").external_attr >> 16))" "$2"' \
  _ "$here/check_signatures.py" "$work/stapled.zip"

notarize_case "ASC_KEY as PEM text, NOTARY_TIMEOUT -> accepted" 0 \
  --has "waiting up to 600s" --has "Ontomeme.app: stapled" \
  -- "$f/signed.zip" "$work/pem.zip" ASC_KEY="$ASC_PEM" ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" NOTARY_TIMEOUT=600
log_case "NOTARY_TIMEOUT also bounds rcodesign's own wait" --has "--max-wait-seconds 600 "

notarize_case "Apple says Invalid -> notary-log printed, exit 1" 1 \
  --has "poll state after 5s: Invalid" \
  --has "macOS notarization: Apple's log for submission $STUB_SUBMISSION_ID:" \
  --has "The binary is not signed with a valid Developer ID certificate." \
  --has "macOS notarization: ERROR: rcodesign notary-submit failed (exit 1) (submission $STUB_SUBMISSION_ID)" \
  -- "$f/signed.zip" "$work/invalid.zip" "${GOOD_ASC[@]}" STUB_RCODESIGN=notary-invalid
log_case "rejection: notary-log runs with the key file and the submission ID" \
  --match "^rcodesign notary-log --api-key-file $tmp/[^ ]+/key\.json $STUB_SUBMISSION_ID $"
absent "rejection: no OUT written" "$work/invalid.zip"

notarize_case "no result within NOTARY_TIMEOUT -> notary-log, exit 1" 1 \
  --has "no result within NOTARY_TIMEOUT=1s (submission $STUB_SUBMISSION_ID)" \
  --has "Apple's log for submission $STUB_SUBMISSION_ID" \
  -- "$f/signed.zip" "$work/hang.zip" "${GOOD_ASC[@]}" STUB_RCODESIGN=notary-hang NOTARY_TIMEOUT=1
absent "timeout: no OUT written" "$work/hang.zip"

notarize_case "upload refused before a submission exists -> exit 1, no notary-log" 1 \
  --has "rcodesign notary-submit failed (exit 1), before Apple created a submission" \
  -- "$f/signed.zip" "$work/auth.zip" "${GOOD_ASC[@]}" STUB_RCODESIGN=notary-auth-fail
log_case "upload refused: notary-log never runs" --lacks "notary-log"

notarize_case "accepted but no ticket stapled -> exit 1" 1 \
  --has "the re-zipped app has no stapled notarization ticket" \
  -- "$f/signed.zip" "$work/noticket.zip" "${GOOD_ASC[@]}" STUB_RCODESIGN=no-ticket
absent "no ticket: no OUT written" "$work/noticket.zip"

notarize_case "an ad-hoc app -> exit 1 before anything is uploaded" 1 \
  --has "is not Developer ID signed, so Apple would reject it" \
  -- "$f/adhoc.zip" "$work/adhoc-out.zip" "${GOOD_ASC[@]}"
check_case "ad-hoc app: rcodesign never runs" 0 --lacks "rcodesign" -- cat "$log"

notarize_case "ASC_KEY that is neither PEM nor base64 -> exit 1" 1 \
  --has "ASC_KEY is neither a PEM key nor valid base64" \
  -- "$f/signed.zip" "$work/badkey.zip" ASC_KEY='!!! not a key !!!' ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER"

notarize_case "ASC_KEY that decodes to no key -> exit 1" 1 \
  --has "rcodesign cannot read the App Store Connect API key" \
  -- "$f/signed.zip" "$work/notkey.zip" ASC_KEY="$(printf 'not a key' | base64 -w0)" ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER"

notarize_case "RCODESIGN naming a missing binary -> exit 1" 1 \
  --has "rcodesign not found ('/nonexistent/rcodesign')" \
  -- "$f/signed.zip" "$work/missing.zip" "${GOOD_ASC[@]}" RCODESIGN=/nonexistent/rcodesign

notarize_case "NOTARY_TIMEOUT that is not a number -> usage, exit 2" 2 \
  --has "NOTARY_TIMEOUT must be a whole number of seconds" \
  -- "$f/signed.zip" "$work/badlimit.zip" "${GOOD_ASC[@]}" NOTARY_TIMEOUT=soon

check_case "one argument -> usage, exit 2" 2 --has "usage: macos_notarize.sh SIGNED.zip OUT.zip" \
  -- bash "$here/macos_notarize.sh" "$f/signed.zip"

notarize_case "in GitHub Actions, errors are ::error:: annotations" 1 \
  --has "::error::macOS notarization: rcodesign notary-submit failed" \
  -- "$f/signed.zip" "$work/gha.zip" "${GOOD_ASC[@]}" GITHUB_ACTIONS=true STUB_RCODESIGN=notary-invalid

check_case "bash -x does not trace key material" 0 \
  --has "macOS notarization: done" --lacks "$P8_BODY_LINE" --lacks "${ASC_B64:0:40}" \
  -- isolated "${GOOD_ASC[@]}" -- bash -x "$here/macos_notarize.sh" "$f/signed.zip" "$work/traced.zip"

t_finish
