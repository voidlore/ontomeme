#!/usr/bin/env bash
# Tests for check_workflows.py: the repo's workflows pass, and fixture
# workflows that break each rule fail with a FAIL line naming it. Also parses
# signing-selftest.yml with yaml.safe_load, and runs actionlint on it when
# actionlint is installed.
#   scripts/sign/test_check_workflows.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib_fixtures.sh
. "$here/lib_fixtures.sh"

repo="$(cd "$here/../.." && pwd)"
selftest="$repo/.github/workflows/signing-selftest.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
check() { python3 -I "$here/check_workflows.py" "$@"; }

if ! python3 -I -c 'import yaml' 2>/dev/null; then
  t_skip "check_workflows.py tests (PyYAML is not installed for python3)"
  exit 0
fi

# --- the repo's workflows ----------------------------------------------------

check_case "signing-selftest.yml passes the self-test rules" 0 \
  --has "PASS $selftest (self-test rules)" -- check "$selftest"
check_case "release.yml and test.yml pass the common rules" 0 \
  --has "release.yml (common rules)" --has "test.yml (common rules)" \
  -- check "$repo/.github/workflows/release.yml" "$repo/.github/workflows/test.yml"
check_case "yaml.safe_load parses signing-selftest.yml" 0 --has "jobs: sign verify-mac verify-win" \
  -- python3 -I -c 'import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
print("jobs:", " ".join(w["jobs"]))' "$selftest"
if command -v actionlint >/dev/null 2>&1; then
  check_case "actionlint is clean on signing-selftest.yml" 0 -- actionlint "$selftest"
else
  t_skip "actionlint on signing-selftest.yml (actionlint is not installed)"
fi

# --- fixtures: one broken rule each ------------------------------------------

# variant NAME FILE PYTHON: write $work/NAME/FILE, the self-test workflow
# after the Python statement PYTHON edits its parsed data `w`.
variant() {
  mkdir -p "$work/$1"
  python3 -I - "$selftest" "$work/$1/$2" "$3" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
w["on"] = w.pop(True)
exec(sys.argv[3])
yaml.safe_dump(w, open(sys.argv[2], "w"), sort_keys=False)
PY
}

broken() {
  local name="$1" file="$2" edit="$3" want="$4"
  variant "$name" "$file" "$edit"
  check_case "$name -> exit 1" 1 --has "FAIL $work/$name/$file: $want" -- check "$work/$name/$file"
}

variant roundtrip signing-selftest.yml "pass"
check_case "the self-test workflow, re-dumped unchanged, still passes" 0 --has "PASS" \
  -- check "$work/roundtrip/signing-selftest.yml"

broken secret-in-env signing-selftest.yml \
  'w["jobs"]["sign"]["steps"][5]["env"] = {"APPLE_P12": "${{ secrets.APPLE_P12 }}"}' \
  "jobs.sign.steps[5].env.APPLE_P12: references a secret; a self-test uses none"
broken secret-bracket signing-selftest.yml \
  'w["env"] = {"P": "${{ secrets[format(\"APPLE_{0}\", \"P12\")] }}"}' \
  "env.P: references a secret"
# The whole secrets object counts as much as one secret: toJSON(secrets) dumps
# them all. So do other letter cases (GitHub's context names ignore case), and
# a }} inside a string literal does not end the expression early.
broken secrets-tojson signing-selftest.yml \
  'w["jobs"]["sign"]["env"]["ALL"] = "${{ toJSON(secrets) }}"' \
  "jobs.sign.env.ALL: references a secret; a self-test uses none"
broken secrets-bare signing-selftest.yml \
  'w["env"] = {"S": "${{ secrets }}"}' \
  "env.S: references a secret"
broken secrets-upper-case signing-selftest.yml \
  'w["jobs"]["sign"]["steps"][5]["env"] = {"P": "${{ SECRETS.APPLE_P12 }}"}' \
  "jobs.sign.steps[5].env.P: references a secret"
broken secrets-after-braces-literal signing-selftest.yml \
  'w["jobs"]["sign"]["steps"][5]["env"] = {"P": "${{ format('"'}}{0}'"', secrets.APPLE_P12) }}"}' \
  "jobs.sign.steps[5].env.P: references a secret"
broken secrets-tojson-in-if signing-selftest.yml \
  'w["jobs"]["sign"]["steps"][5]["if"] = "toJSON(secrets) != '"'{}'"'"' \
  "job 'sign', step 'Sign the macOS app (rcodesign)': references a secret; a self-test uses none"
# ...but the word in a string literal or as a property name is no secret.
variant secrets-word-only signing-selftest.yml \
  'w["jobs"]["sign"]["steps"][5]["if"] = "!contains(github.event.inputs.skip, '"'secrets'"')"
w["jobs"]["sign"]["steps"][5]["env"] = {"S": "${{ steps.secrets.outputs.dir }}", "T": "${{ hashFiles('"'**/secrets.txt'"') }}"}'
check_case "secrets-word-only (a literal and a property named secrets) -> exit 0" 0 \
  --has "PASS $work/secrets-word-only/signing-selftest.yml (self-test rules)" \
  -- check "$work/secrets-word-only/signing-selftest.yml"
broken secrets-inherit signing-selftest.yml \
  'w["jobs"]["reuse"] = {"if": "github.repository == '"'voidlore/ontomeme'"'", "uses": "./.github/workflows/x.yml", "secrets": "inherit"}' \
  "job 'reuse' passes secrets: to a reusable workflow"
broken push-trigger signing-selftest.yml \
  'w["on"] = {"workflow_dispatch": None, "push": {"branches": ["main"]}}' \
  "runs on push; a self-test runs on workflow_dispatch only"
broken no-guard signing-selftest.yml \
  'del w["jobs"]["verify-win"]["if"]' \
  "job 'verify-win' lacks the guard if: github.repository == 'voidlore/ontomeme'"
broken other-repo signing-selftest.yml \
  'w["jobs"]["sign"]["if"] = "github.repository == '"'someone/fork'"'"' \
  "job 'sign' lacks the guard"
broken bypassed-guard signing-selftest.yml \
  'w["jobs"]["verify-mac"]["if"] = "github.repository == '"'voidlore/ontomeme'"' || always()"' \
  "job 'verify-mac': '||' in its if: can bypass the repository guard"
broken write-token signing-selftest.yml \
  'w["permissions"] = {"contents": "write"}' \
  "permissions give 'contents: write'; a self-test needs no write scope"
broken job-write-token signing-selftest.yml \
  'w["jobs"]["sign"]["permissions"] = "write-all"' \
  "job 'sign' permissions give 'write-all'"
broken no-permissions signing-selftest.yml \
  'del w["permissions"]' \
  "declares no top-level permissions"

# The common rules hold for any workflow, by any name.
broken secret-in-if release.yml \
  'w["jobs"]["sign"]["steps"][5]["if"] = "secrets.APPLE_P12 != '"''"'"' \
  "job 'sign', step 'Sign the macOS app (rcodesign)': secrets in an if:"
broken secret-in-run release.yml \
  'w["jobs"]["sign"]["steps"][6]["run"] = "echo \"${{ secrets.WIN_PFX }}\" | base64 -d >x.pfx"' \
  "job 'sign', step 'Sign the Windows exe (jsign, PKCS12)': a secret is pasted into run:"
broken secrets-tojson-in-run release.yml \
  'w["jobs"]["sign"]["steps"][6]["run"] = "echo '"'"'${{ toJSON(secrets) }}'"'"' >all.json"' \
  "job 'sign', step 'Sign the Windows exe (jsign, PKCS12)': a secret is pasted into run:"
broken secrets-tojson-in-job-if release.yml \
  'w["jobs"]["sign"]["if"] = "toJSON(secrets) != '"'{}'"'"' \
  "job 'sign': secrets in an if:"
variant gated release.yml \
  'w["jobs"]["sign"]["env"]["HAS_APPLE_SIGNING"] = "${{ secrets.APPLE_P12 != '"''"' }}"
w["jobs"]["sign"]["steps"][5]["if"] = "env.HAS_APPLE_SIGNING == '"'true'"'"
w["jobs"]["sign"]["steps"][5]["env"] = {"APPLE_P12": "${{ secrets.APPLE_P12 }}"}'
check_case "a release.yml gating on a job env boolean, secrets in step env -> exit 0" 0 \
  --has "PASS $work/gated/release.yml (common rules)" -- check "$work/gated/release.yml"

# --- usage and unreadable files ------------------------------------------------

printf 'jobs:\n  a:\n    runs-on: x\n  a:\n    runs-on: y\non: push\n' >"$work/duplicate.yml"
check_case "a duplicated key -> exit 2" 2 --has "duplicate key 'a'" -- check "$work/duplicate.yml"
printf 'jobs: [unclosed\n' >"$work/bad.yml"
check_case "invalid YAML -> exit 2" 2 --has "not valid YAML" -- check "$work/bad.yml"
check_case "a missing file -> exit 2" 2 --has "ERROR $work/missing.yml" -- check "$work/missing.yml"
printf -- '- just\n- a list\n' >"$work/list.yml"
check_case "a top level that is not a mapping -> exit 2" 2 --has "not a workflow" -- check "$work/list.yml"
check_case "no arguments -> usage, exit 2" 2 --has "usage: check_workflows.py WORKFLOW..." -- check
check_case "one bad file among good ones -> exit 1, the good one still passes" 1 \
  --has "PASS $selftest" --has "FAIL $work/no-guard/signing-selftest.yml" \
  -- check "$selftest" "$work/no-guard/signing-selftest.yml"

t_finish
