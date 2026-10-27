#!/usr/bin/env bash
# Run every tests/*_test.gd headless. A test passes only if it prints
# "RESULT: ALL PASS", exits 0 within the timeout, and logs no script errors.
#   GODOT=/path/to/godot tests/run_all.sh [timeout_seconds]
set -uo pipefail
cd "$(dirname "$0")/.."
godot="${GODOT:-godot}"
limit="${1:-240}"
logs="$(mktemp -d)"
"$godot" --headless --path . --import >/dev/null 2>&1 || true
failed=()
for t in tests/*_test.gd; do
  name="$(basename "$t" .gd)"
  log="$logs/$name.log"
  timeout "$limit" "$godot" --headless --path . -s "res://$t" >"$log" 2>&1
  code=$?
  errors=$(grep -cE 'SCRIPT ERROR|Parse Error' "$log")
  if [ $code -eq 0 ] && [ "$errors" -eq 0 ] && grep -q 'RESULT: ALL PASS' "$log"; then
    echo "PASS  $name"
  else
    echo "FAIL  $name (exit $code, $errors script errors)"
    grep -E 'FAIL |SCRIPT ERROR|Parse Error' "$log" | head -20 | sed 's/^/      /'
    failed+=("$name")
  fi
done
echo
if [ ${#failed[@]} -eq 0 ]; then echo "ALL TESTS PASS"; else echo "FAILED: ${failed[*]}"; exit 1; fi
