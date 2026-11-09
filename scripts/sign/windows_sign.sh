#!/usr/bin/env bash
# Authenticode-sign the exported Ontomeme.exe in place with jsign, on Linux,
# whichever key the Windows signing route ends up using: a PKCS12 file, Azure
# Trusted Signing, SSL.com eSigner or another jsign storetype. Runs after the
# export, so export_presets.cfg keeps codesign/enable=false.
#
#   WIN_SIGN_STORETYPE=PKCS12 WIN_PFX=<base64 .pfx> WIN_SIGN_STOREPASS=... \
#     scripts/sign/windows_sign.sh build/windows/Ontomeme.exe
#   WIN_SIGN_STORETYPE=TRUSTEDSIGNING WIN_SIGN_KEYSTORE=weu.codesigning.azure.net \
#   WIN_SIGN_STOREPASS=<access token> WIN_SIGN_ALIAS=<account>/<profile> \
#     scripts/sign/windows_sign.sh build/windows/Ontomeme.exe
#
# Without WIN_SIGN_STORETYPE it prints 'Windows signing skipped (no
# WIN_SIGN_STORETYPE)' and exits 0, leaving EXE untouched. Otherwise:
#   - PKCS12 needs WIN_PFX (base64; decoded to a 0600 file in a private temp
#     dir that is removed on exit) and WIN_SIGN_STOREPASS; WIN_SIGN_ALIAS is
#     optional. Every other storetype needs WIN_SIGN_KEYSTORE,
#     WIN_SIGN_STOREPASS and WIN_SIGN_ALIAS as jsign reads them for it, and
#     ESIGNER also WIN_SIGN_KEYPASS (the eSigner TOTP secret).
#   - The passwords reach jsign as env:WIN_SIGN_STOREPASS and
#     env:WIN_SIGN_KEYPASS, never in argv.
#   - It adds --name Ontomeme --url https://github.com/voidlore/ontomeme
#     --alg SHA-256, and an RFC 3161 timestamp from WIN_SIGN_TSA_URL, which
#     defaults per storetype (TRUSTEDSIGNING http://timestamp.acs.microsoft.com,
#     ESIGNER http://ts.ssl.com, else http://timestamp.digicert.com);
#     WIN_SIGN_TSA_URL=none signs without a timestamp.
#   - jsign signs a copy in the temp dir. The copy must pass
#     check_signatures.py --expect-windows=signed, which also requires the
#     'pck' section to still start with GDPC, before it replaces EXE, so a
#     failure leaves EXE as it was.
# JSIGN selects jsign: a command or a .jar run with java (default: jsign on
# PATH; install_jsign.sh installs one). Exit 0 on success or skip, 1 on
# failure, 2 on a usage error.
set +x # never trace: the environment holds secrets
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error::Windows signing: $1" >&2; else echo "Windows signing: ERROR: $1" >&2; fi
  exit 1
}

if [ $# -ne 1 ]; then
  echo "usage: windows_sign.sh EXE" >&2
  exit 2
fi
exe="$1"
store="${WIN_SIGN_STORETYPE:-}"

if [ -z "$store" ]; then
  echo "Windows signing skipped (no WIN_SIGN_STORETYPE)"
  exit 0
fi
[ -f "$exe" ] || fail "no such file: $exe"
[[ $store =~ ^[A-Za-z0-9_]+$ ]] || fail "WIN_SIGN_STORETYPE is not a jsign storetype name (letters, digits, _)"

case "$store" in
  PKCS12) required=(WIN_PFX WIN_SIGN_STOREPASS) ;;
  ESIGNER) required=(WIN_SIGN_KEYSTORE WIN_SIGN_STOREPASS WIN_SIGN_ALIAS WIN_SIGN_KEYPASS) ;;
  *) required=(WIN_SIGN_KEYSTORE WIN_SIGN_STOREPASS WIN_SIGN_ALIAS) ;;
esac
missing=()
for var in "${required[@]}"; do
  if [ -z "${!var:-}" ]; then missing+=("$var"); fi
done
if [ ${#missing[@]} -eq 1 ]; then
  fail "WIN_SIGN_STORETYPE=$store also needs ${missing[0]}, which is not set"
elif [ ${#missing[@]} -gt 1 ]; then
  fail "WIN_SIGN_STORETYPE=$store also needs ${missing[*]}, which are not set"
fi

# jsign reads the passwords from the environment (env:NAME), never argv.
export WIN_SIGN_STOREPASS
if [ -n "${WIN_SIGN_KEYPASS:-}" ]; then export WIN_SIGN_KEYPASS; fi

case "${JSIGN:-jsign}" in
  *.jar)
    jar="$JSIGN"
    [ -f "$jar" ] || fail "jsign not found ('$jar'): run scripts/sign/install_jsign.sh DIR or set JSIGN"
    command -v java >/dev/null 2>&1 || fail "java is not on PATH, and JSIGN=$jar needs it"
    jsign=(java -jar "$jar")
    ;;
  *)
    command -v "${JSIGN:-jsign}" >/dev/null 2>&1 ||
      fail "jsign not found ('${JSIGN:-jsign}'): run scripts/sign/install_jsign.sh DIR or set JSIGN"
    jsign=("$(command -v "${JSIGN:-jsign}")")
    ;;
esac

case "${WIN_SIGN_TSA_URL:-}" in
  none) tsa="" ;;
  "")
    case "$store" in
      TRUSTEDSIGNING) tsa=http://timestamp.acs.microsoft.com ;;
      ESIGNER) tsa=http://ts.ssl.com ;;
      *) tsa=http://timestamp.digicert.com ;;
    esac
    ;;
  *) tsa="$WIN_SIGN_TSA_URL" ;;
esac

umask 077
work=""
cleanup() { if [ -n "$work" ]; then rm -rf "$work"; fi; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
work="$(mktemp -d)" || fail "cannot create a temp dir"

args=(--storetype "$store")
if [ "$store" = PKCS12 ]; then
  # printf is a builtin, so the key never reaches argv.
  printf '%s' "$WIN_PFX" | tr -d '[:space:]' | base64 -d >"$work/signing.p12" 2>/dev/null && [ -s "$work/signing.p12" ] ||
    fail "WIN_PFX is not valid base64 (encode the .pfx with: base64 -w0 cert.pfx)"
  args+=(--keystore "$work/signing.p12" --storepass env:WIN_SIGN_STOREPASS)
  if [ -n "${WIN_SIGN_ALIAS:-}" ]; then args+=(--alias "$WIN_SIGN_ALIAS"); fi
else
  args+=(--keystore "$WIN_SIGN_KEYSTORE" --storepass env:WIN_SIGN_STOREPASS --alias "$WIN_SIGN_ALIAS")
fi
if [ -n "${WIN_SIGN_KEYPASS:-}" ]; then args+=(--keypass env:WIN_SIGN_KEYPASS); fi
args+=(--name Ontomeme --url https://github.com/voidlore/ontomeme --alg SHA-256)
if [ -n "$tsa" ]; then args+=(--tsaurl "$tsa" --tsmode RFC3161); fi

copy="$work/$(basename "$exe")"
cp -f -- "$exe" "$copy"
echo "Windows signing: signing $(basename "$exe") with jsign (storetype $store, timestamp ${tsa:-none})"
"${jsign[@]}" "${args[@]}" "$copy" || fail "jsign failed; $exe is unchanged"
python3 -I "$here/check_signatures.py" --expect-windows=signed "$copy" ||
  fail "the signed copy does not check out (see check_signatures.py above); $exe is unchanged"
cp -f -- "$copy" "$exe"
echo "Windows signing: done, $exe is signed"
