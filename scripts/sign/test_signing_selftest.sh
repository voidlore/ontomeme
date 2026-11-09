#!/usr/bin/env bash
# Runs the Linux 'sign' job of .github/workflows/signing-selftest.yml here,
# step by step, as GitHub runs it: each run: script verbatim under
# `bash --noprofile --norc -eo pipefail` in a temp workspace, with the job's
# env and what each step adds to GITHUB_ENV and GITHUB_PATH. It runs every
# step from the export through check_signatures. The two download steps are
# stood in for: Godot is a stand-in that writes ready exports, and the
# signers step's bin dir holds the rcodesign and jsign stand-ins from
# lib_fixtures.sh. Also shellchecks every bash run: script in the workflow.
# Opt-in: with GODOT set the exports are real Godot exports, and RCODESIGN
# and JSIGN put the real signers in place of the stand-ins.
#   [GODOT=/path/to/godot [RCODESIGN=/path/to/rcodesign] [JSIGN=/path/to/jsign.jar]] \
#     scripts/sign/test_signing_selftest.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib_fixtures.sh
. "$here/lib_fixtures.sh"

umask 022
REAL_RCODESIGN="${RCODESIGN:-}" REAL_JSIGN="${JSIGN:-}"
unset RCODESIGN JSIGN
repo="$(cd "$here/../.." && pwd)"
workflow="$repo/.github/workflows/signing-selftest.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
f="$work/fixtures" stubs="$work/stubs" log="$work/stub.log"
mkdir -p "$f/exports" "$f/app"
SELFTEST_CN="Ontomeme Selftest"

if ! python3 -I -c 'import yaml' 2>/dev/null; then
  t_skip "signing-selftest.yml steps (PyYAML is not installed for python3)"
  exit 0
fi

# --- the workflow's run: steps -------------------------------------------------

# Writes $work/steps/<job>.<n>.sh for every run: step and prints one
# "<job> <n> <id> <shell>" line each; the shell is the step's, else its job's
# or the workflow's defaults.run.shell, else 'default'.
python3 -I - "$workflow" "$work/steps" >"$work/steps.txt" <<'PY'
import os, sys, yaml
workflow = yaml.safe_load(open(sys.argv[1]))
out = sys.argv[2]
os.makedirs(out)
top = (workflow.get("defaults") or {}).get("run", {}).get("shell")
for job_id, job in workflow["jobs"].items():
    shell = (job.get("defaults") or {}).get("run", {}).get("shell") or top
    for n, step in enumerate(job.get("steps", [])):
        if "run" in step:
            with open(f"{out}/{job_id}.{n}.sh", "w") as f:
                f.write(step["run"])
            print(job_id, n, step.get("id", "-"), step.get("shell") or shell or "default")
PY

# step_file JOB ID: the script of JOB's run: step with that id.
step_file() {
  local n
  n="$(awk -v job="$1" -v id="$2" '$1 == job && $3 == id { print $2 }' "$work/steps.txt")"
  if [ -n "$n" ]; then echo "$work/steps/$1.$n.sh"; fi
}

sign_ids="$(awk '$1 == "sign" { printf "%s ", $3 }' "$work/steps.txt")"
check_case "the sign job's run: steps, in order" 0 \
  --has "godot export signers cert sign-macos sign-windows check " -- echo "$sign_ids"
check_case "every sign step runs in bash -eo pipefail (shell: bash)" 0 --lacks "sign" \
  -- awk '$1 == "sign" && $4 != "bash"' "$work/steps.txt"
check_case "no sign step interpolates \${{ }} into its script" 0 \
  -- sh -c '! grep -l "\${{" "$@"' _ "$work"/steps/sign.*.sh
check_case "verify-mac runs in bash, verify-win in pwsh" 0 --has "verify-mac bash" --has "verify-win pwsh" \
  --lacks "verify-mac default" --lacks "verify-win default" \
  -- awk '$1 != "sign" { print $1, $4 }' "$work/steps.txt"

if command -v shellcheck >/dev/null 2>&1; then
  bash_steps=()
  while read -r job n _id shell; do
    if [ "$shell" = bash ]; then bash_steps+=("$work/steps/$job.$n.sh"); fi
  done <"$work/steps.txt"
  # SC2164 (cd without || exit) is moot: GitHub runs each step with bash -e.
  check_case "shellcheck -S warning on every bash run: step (${#bash_steps[@]})" 0 \
    -- shellcheck -S warning -s bash -e SC2164 "${bash_steps[@]}"
else
  t_skip "shellcheck on the workflow's bash steps (shellcheck is not installed)"
fi

# --- the exports and tools the download steps would have provided ----------------

real_exports=false
status=0
if [ -n "${GODOT:-}" ]; then fixture_godot_exports "$f/exports" || status=$?; fi
if [ -n "${GODOT:-}" ] && [ "$status" -eq 0 ]; then
  real_exports=true
else
  if [ -n "${GODOT:-}" ] && [ "$status" -eq 2 ]; then
    t_skip "real Godot exports ($FIXTURE_REASON); synthetic exports instead"
  elif [ -n "${GODOT:-}" ]; then
    t_fail "real Godot exports" "$FIXTURE_REASON"
  fi
  # Godot's shapes: a universal ad-hoc app zipped without dir entries, and a
  # PE32+ whose 'pck' section starts with GDPC.
  fixture_macho "$f/x86_64.macho" x86_64 adhoc
  fixture_macho "$f/arm64.macho" arm64 adhoc
  fixture_py fat "$f/universal.macho" "$f/x86_64.macho" "$f/arm64.macho"
  fixture_app "$f/app" Ontomeme "$f/universal.macho"
  rm -r "$f/app/Ontomeme.app/Contents/_CodeSignature"
  head -c 4096 /dev/urandom >"$f/app/Ontomeme.app/Contents/Resources/Ontomeme.pck"
  fixture_py zip "$f/exports/Ontomeme.zip" "$f/app"
  fixture_py pe "$f/exports/Ontomeme.exe" intact
fi

# A Godot stand-in for the export step: --export-release PRESET PATH copies
# the ready export for PRESET from $STUB_EXPORTS; anything else does nothing.
fixture_stub_start "$stubs" godot
cat >>"$stubs/godot" <<'STUB'
stub_log "godot $(printf '%q ' "$@")"
preset="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --export-release) preset="$2" out="$3"; shift 3 ;;
    *) shift ;;
  esac
done
case "$preset" in
  "") exit 0 ;;
  macOS) cp -f "$STUB_EXPORTS/Ontomeme.zip" "$out" ;;
  "Windows x86_64") cp -f "$STUB_EXPORTS/Ontomeme.exe" "$out" ;;
  *) echo "ERROR: Cannot export project with preset \"$preset\" (stand-in)" >&2; exit 1 ;;
esac
STUB
fixture_rcodesign_stub "$stubs"
fixture_jsign_stub "$stubs"

# signer_bin DIR: the signers step's bin dir (install_rcodesign.sh and
# install_jsign.sh put rcodesign and jsign there), holding the stand-ins or,
# opted in, links to the real tools.
signer_bin() {
  mkdir -p "$1"
  if [ -n "$REAL_RCODESIGN" ]; then ln -s "$(command -v "$REAL_RCODESIGN")" "$1/rcodesign"; else cp -f "$stubs/rcodesign" "$1/"; fi
  case "$REAL_JSIGN" in
    "") cp -f "$stubs/jsign" "$1/" ;;
    *.jar) printf '#!/bin/sh\nexec %q -jar %q "$@"\n' "$(command -v java)" "$REAL_JSIGN" >"$1/jsign" && chmod 755 "$1/jsign" ;;
    *) ln -s "$(command -v "$REAL_JSIGN")" "$1/jsign" ;;
  esac
}

# --- the job runner ----------------------------------------------------------------

# A fresh job: workspace $ws (the checkout: just scripts/), $runner_temp,
# TMPDIR $tmp, and the job env from the workflow.
job_env=()
new_job() {
  rm -rf "$work/job"
  ws="$work/job/workspace" runner_temp="$work/job/runner_temp" tmp="$work/job/tmp"
  mkdir -p "$ws" "$runner_temp" "$tmp"
  ln -s "$repo/scripts" "$ws/scripts"
  : >"$log"
  mapfile -t job_env < <(python3 -I -c 'import sys, yaml
for k, v in (yaml.safe_load(open(sys.argv[1]))["jobs"]["sign"].get("env") or {}).items():
    print(f"{k}={v}")' "$workflow")
  # What the skipped steps leave behind: Godot in GITHUB_ENV, the signers
  # dir in GITHUB_PATH.
  job_env+=("GODOT=$stubs/godot")
  signer_bin "$runner_temp/bin"
  printf '%s\n' "$runner_temp/bin" >"$work/job/github_path"
}

# read_github_env FILE: NAME=VALUE lines, NUL-terminated, from a GITHUB_ENV
# file (NAME=VALUE lines and NAME<<DELIMITER blocks).
read_github_env() {
  python3 -I - "$1" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
i = 0
while i < len(lines):
    line = lines[i]
    i += 1
    if "<<" in line and ("=" not in line or line.index("<<") < line.index("=")):
        name, delimiter = line.split("<<", 1)
        body = []
        while i < len(lines) and lines[i] != delimiter:
            body.append(lines[i])
            i += 1
        i += 1
        sys.stdout.write(f"{name}={chr(10).join(body)}\0")
    elif "=" in line:
        sys.stdout.write(line + "\0")
PY
}

# run_step ID [VAR=VALUE...]: the sign job's step ID, as GitHub runs it, in
# $ws; output in $work/job/ID.log. Applies the step's GITHUB_ENV and
# GITHUB_PATH to the later steps. Returns the step's exit code.
run_step() {
  local id="$1" script code=0 path="" dir kv
  shift
  script="$(step_file sign "$id")"
  [ -n "$script" ] || { echo "no step $id"; return 98; }
  : >"$work/job/github_env.step"
  : >"$work/job/github_path.step"
  while read -r dir; do path="$dir:$path"; done <"$work/job/github_path"
  (cd "$ws" && env -i PATH="$path$PATH" HOME="$HOME" TMPDIR="$tmp" CI=true GITHUB_ACTIONS=true \
    RUNNER_TEMP="$runner_temp" GITHUB_WORKSPACE="$ws" GITHUB_ENV="$work/job/github_env.step" \
    GITHUB_PATH="$work/job/github_path.step" STUB_LOG="$log" STUB_EXPORTS="$f/exports" \
    "${job_env[@]}" "$@" bash --noprofile --norc -eo pipefail "$script") >"$work/job/$id.log" 2>&1 || code=$?
  while IFS= read -r -d '' kv; do job_env+=("$kv"); done < <(read_github_env "$work/job/github_env.step")
  cat "$work/job/github_path.step" >>"$work/job/github_path"
  return "$code"
}

# step_case NAME ID WANT_EXIT [--has|--lacks|--match X]... [-- VAR=VALUE...]
step_case() {
  local name="$1" id="$2" want="$3" code=0
  local -a checks=()
  shift 3
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    checks+=("$1" "$2")
    shift 2
  done
  if [ $# -gt 0 ]; then shift; fi
  run_step "$id" "$@" || code=$?
  check_case "$name" "$want" "${checks[@]}" -- sh -c 'cat "$1"; exit "$2"' _ "$work/job/$id.log" "$code"
}

# env_value NAME: the last NAME=VALUE the steps set so far.
env_value() {
  local kv value=""
  for kv in "${job_env[@]}"; do
    if [ "${kv%%=*}" = "$1" ]; then value="${kv#*=}"; fi
  done
  printf '%s' "$value"
}

# --- the sign job, export through check_signatures --------------------------------

kind="synthetic exports"
if [ "$real_exports" = true ]; then kind="the real exports"; fi
signers="stand-in signers"
if [ -n "$REAL_RCODESIGN$REAL_JSIGN" ]; then signers="real ${REAL_RCODESIGN:+rcodesign }${REAL_JSIGN:+jsign }"; fi
tsa=()
if [ -n "$REAL_JSIGN" ]; then tsa=(WIN_SIGN_TSA_URL=none); fi
new_job

step_case "export ($kind): both presets, the app is ad-hoc as exported" export 0 \
  --has "Ontomeme.app: adhoc" --match "Ontomeme.exe: (Windows )?Ontomeme.exe: unsigned" \
  --has "pck section: intact (starts with GDPC)"
step_case "cert: a self-signed '$SELFTEST_CN' code-signing p12, its password masked" cert 0 \
  --has "subject=CN=$SELFTEST_CN" --has "::add-mask::"
password="$(env_value SELFTEST_P12_PASSWORD)"
check_case "cert: GITHUB_ENV carries SELFTEST_P12 and its password, the key file is gone" 0 \
  --has "selftest.p12 600" --lacks "key.pem" --has "Code Signing" \
  -- sh -c 'cd "$1" && for p in *; do echo "$p $(stat -c %a "$p")"; done
    printf "%s" "$2" | base64 -d >"$3/check.p12" && SELFTEST_P12_PASSWORD="$4" openssl pkcs12 \
      -in "$3/check.p12" -passin env:SELFTEST_P12_PASSWORD -nokeys -clcerts 2>/dev/null |
      openssl x509 -noout -ext extendedKeyUsage' \
  _ "$runner_temp/selftest-cert" "$(env_value SELFTEST_P12)" "$work" "$password"
step_case "sign-macos ($signers): macos_sign.sh signs the app as '$SELFTEST_CN'" sign-macos 0 \
  --has "macOS signing: done" --has "signed by '$SELFTEST_CN'" --lacks "$password"
step_case "sign-windows ($signers): windows_sign.sh signs the exe with PKCS12" sign-windows 0 \
  --has "storetype PKCS12" --has "Windows signing: done" --lacks "$password" -- ${tsa[@]+"${tsa[@]}"}
step_case "check: both signed by '$SELFTEST_CN', pck intact" check 0 \
  --match "Ontomeme-signed.zip: macOS Ontomeme.app: signed" --has "signer: $SELFTEST_CN (" \
  --match "Ontomeme.exe: (Windows )?Ontomeme.exe: signed" --has "pck section: intact"
check_case "no password reached a signer's argv, and TMPDIR is left empty" 0 --lacks "$password" \
  -- sh -c 'cat "$1"; ls -A "$2"' _ "$log" "$tmp"
if [ -z "$REAL_RCODESIGN$REAL_JSIGN" ]; then
  check_case "the stand-ins ran: rcodesign sign and verify, jsign with a PKCS12 keystore" 0 \
    --match "^rcodesign sign .*--code-signature-flags runtime" --match "^rcodesign verify " \
    --match "^jsign --storetype PKCS12 --keystore [^ ]+ --storepass env:WIN_SIGN_STOREPASS" \
    -- cat "$log"
fi
check_case "the two upload paths exist" 0 \
  -- test -s "$ws/build/macos/Ontomeme-signed.zip" -a -s "$ws/build/windows/Ontomeme.exe"

# --- failures stop the job ------------------------------------------------------------

if [ -z "$REAL_RCODESIGN$REAL_JSIGN" ]; then
  new_job
  run_step export >/dev/null && run_step cert >/dev/null || t_fail "failing job setup" "export or cert failed"
  step_case "sign-macos: rcodesign failing fails the step with ::error::" sign-macos 1 \
    --has "::error::macOS signing: rcodesign sign failed" -- STUB_RCODESIGN=fail-sign
  step_case "sign-windows: a signed exe that lost its pck fails the step" sign-windows 1 \
    --has "::error::Windows signing:" -- STUB_JSIGN=corrupt-pck
fi

# The check step against artifacts another certificate signed.
new_job
mkdir -p "$ws/build/macos" "$ws/build/windows"
fixture_cert "$f/other" "/CN=Other Signer" "" -addext "extendedKeyUsage=codeSigning"
printf 'Authenticode stand-in content' >"$f/content"
openssl cms -sign -binary -nodetach -outform DER -in "$f/content" -out "$f/other.p7" \
  -signer "$f/other.pem" -inkey "$f/other.key"
fixture_py pe "$ws/build/windows/Ontomeme.exe" intact "$f/other.p7"
fixture_cert "$f/selftest" "/CN=$SELFTEST_CN" "" -addext "extendedKeyUsage=codeSigning"
fixture_macho "$f/signed-x86_64.macho" x86_64 signed "$f/selftest"
mkdir -p "$f/signed-app"
fixture_app "$f/signed-app" Ontomeme "$f/signed-x86_64.macho"
fixture_py zip "$ws/build/macos/Ontomeme-signed.zip" "$f/signed-app"
step_case "check: an exe signed by another certificate fails the step" check 1 \
  --has "signer: Other Signer (" --has "::error::an artifact is not signed by $SELFTEST_CN"

t_finish
