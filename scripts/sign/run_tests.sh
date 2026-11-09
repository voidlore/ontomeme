#!/usr/bin/env bash
# Run every scripts/sign/test_*.sh, then lint the signing scripts with
# `shellcheck -S warning` when it is installed. Each test prints PASS/FAIL/SKIP
# lines; this exits non-zero when any test script (or the lint) fails.
#   [GODOT=/path/to/godot] [RCODESIGN=/path/to/rcodesign] [JSIGN=/path/to/jsign.jar] \
#     scripts/sign/run_tests.sh
# The signers and downloaders (rcodesign, jsign, java, curl) are stand-ins on
# PATH, so nothing is downloaded or sent to Apple or a signing service.
# With GODOT set, tests that need real Godot exports run too (and skip, saying
# why, when the export templates are missing); with RCODESIGN or JSIGN as well,
# a real rcodesign or jsign signs that export with a throwaway self-signed
# certificate. The workflow tests (check_workflows.py, and signing-selftest.yml's
# Linux job run step by step) need PyYAML and skip without it.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()

for test in "$here"/test_*.sh; do
  name="$(basename "$test" .sh)"
  echo "== $name"
  if ! bash "$test"; then failed+=("$name"); fi
done

echo "== shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning -x "$here"/*.sh; then
    echo "PASS  shellcheck -S warning scripts/sign/*.sh"
  else
    echo "FAIL  shellcheck -S warning scripts/sign/*.sh"
    failed+=(shellcheck)
  fi
else
  echo "SKIP  shellcheck is not installed"
fi

echo
if [ ${#failed[@]} -eq 0 ]; then
  echo "ALL SIGNING TESTS PASS"
else
  echo "FAILED: ${failed[*]}"
  exit 1
fi
