#!/usr/bin/env bash
# Run every tests/*_test.gd headless. A test passes only if it prints
# "RESULT: ALL PASS", exits 0 within the timeout, and logs no script errors
# and no engine "ERROR:" line it didn't expect. A test expects one by printing
# "EXPECT-ERROR: <fixed substring>" before triggering it; ERROR lines that
# contain a declared substring are ignored.
#   GODOT=/path/to/godot tests/run_all.sh [timeout_seconds]
# Each run gets its own temp XDG home, so user:// and the Documents folder are
# throwaway: no test reaches the real ~/Documents/Ontomeme, and runs in two
# worktrees don't share user://test-vault-*. A test that still creates the
# app's default vault fails, wherever the app puts it: <Documents>/Ontomeme.
# RUN_ALL_NO_SANDBOX=1 skips the sandbox where XDG doesn't apply (macOS,
# Windows); TestVault.hold() still guards those.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
godot="${GODOT:-godot}"
limit="${1:-240}"
logs="$(mktemp -d)"

# Godot keeps user:// under XDG_DATA_HOME and asks xdg-user-dir, which reads
# $XDG_CONFIG_HOME/user-dirs.dirs, where Documents is.
sandbox=""
if [ "${RUN_ALL_NO_SANDBOX:-}" != 1 ]; then
  sandbox="$(mktemp -d)"
  printf 'XDG_DOCUMENTS_DIR="%s/Documents"\n' "$sandbox" >"$sandbox/user-dirs.dirs"
  export XDG_CONFIG_HOME="$sandbox" XDG_DATA_HOME="$sandbox/data" XDG_CACHE_HOME="$sandbox/cache"
  trap 'rm -rf "$sandbox" 2>/dev/null' EXIT
fi
leaked=""   # the first test after which $default_vault existed

# timeout(1) is GNU coreutils: stock macOS has neither it nor gtimeout.
# watchdog <seconds> <command...> stands in for it: TERM the command when the
# time is up, KILL it 5 s later, and exit 124 as timeout does.
watchdog_flag="$logs/.watchdog"   # non-empty once the watchdog fired
watchdog() {
  local secs="$1" pid dog code
  shift
  : >"$watchdog_flag"
  "$@" &
  pid=$!
  (
    nap=""
    trap 'kill "$nap" 2>/dev/null; exit 0' TERM   # the run ended in time
    sleep "$secs" &
    nap=$!
    wait "$nap"
    trap - TERM
    echo fired >"$watchdog_flag"
    kill -TERM "$pid"
    sleep 5
    kill -KILL "$pid"
  ) >/dev/null 2>&1 &
  dog=$!
  wait "$pid"
  code=$?
  kill -TERM "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null
  if [ -s "$watchdog_flag" ]; then code=124; fi
  return "$code"
}
if command -v timeout >/dev/null 2>&1; then timer=timeout
elif command -v gtimeout >/dev/null 2>&1; then timer=gtimeout
else timer=watchdog
fi

# unexpected_errors <log>: its engine "ERROR:" lines that no "EXPECT-ERROR: "
# line in it excuses.
unexpected_errors() {
  local expected="${1%.log}.expected-errors"
  sed -n 's/^EXPECT-ERROR: \(.\)/\1/p' "$1" >"$expected"
  if [ -s "$expected" ]; then
    grep -E '^ERROR:' "$1" | grep -vF -f "$expected"
  else
    grep -E '^ERROR:' "$1"
  fi
}

"$godot" --headless --path . --import >/dev/null 2>&1 || true

# Where the app creates its default vault in this run: ask it rather than
# assume <sandbox>/Documents. With no xdg-user-dir on PATH, Godot finds no
# Documents folder and the app reads the sandbox's user-dirs.dirs itself; a
# GODOT wrapper may set XDG dirs of its own.
default_vault=""
if [ -n "$sandbox" ]; then
  default_vault="$("$timer" "$limit" "$godot" --headless --path . -s res://tests/print_default_vault.gd 2>&1 \
    | sed -n 's/^DEFAULT-VAULT: //p' | head -n 1)"
  default_vault="${default_vault%/}"
  case "$default_vault" in
    "") echo "FAILED: tests/print_default_vault.gd printed no DEFAULT-VAULT line"; exit 1 ;;
    /* | ?:/*) ;;
    *) default_vault="$PWD/$default_vault" ;;
  esac
  if [ -e "$default_vault" ]; then
    echo "FAILED: the default vault $default_vault exists before any test ran, so a test that creates it can't be caught."
    echo "        Remove it if an earlier run leaked it, or set RUN_ALL_NO_SANDBOX=1 to skip this check."
    exit 1
  fi
fi
failed=()
ran=0
for t in tests/*_test.gd; do
  [ -e "$t" ] || continue   # the glob matched nothing
  ran=$((ran + 1))
  name="$(basename "$t" .gd)"
  log="$logs/$name.log"
  "$timer" "$limit" "$godot" --headless --path . -s "res://$t" >"$log" 2>&1
  code=$?
  errors=$(grep -cE 'SCRIPT ERROR|Parse Error' "$log")
  engine_errors=$(unexpected_errors "$log" | grep -c .)
  if [ -n "$default_vault" ] && [ -z "$leaked" ] && [ -e "$default_vault" ]; then
    leaked="$name"
  fi
  if [ $code -eq 0 ] && [ "$errors" -eq 0 ] && [ "$engine_errors" -eq 0 ] && [ "$leaked" != "$name" ] \
      && grep -q 'RESULT: ALL PASS' "$log"; then
    echo "PASS  $name"
  else
    echo "FAIL  $name (exit $code, $errors script errors)"
    grep -E 'FAIL |SCRIPT ERROR|Parse Error' "$log" | head -20 | sed 's/^/      /'
    if [ "$engine_errors" -gt 0 ]; then
      unexpected_errors "$log" | head -20 | sed 's/^/      /'
      echo "      (unexpected engine errors: $engine_errors. A test that means one prints \"EXPECT-ERROR: <substring>\" before it.)"
    fi
    if [ "$leaked" = "$name" ]; then
      echo "      created the app's default vault $default_vault: call TestVault.hold() before the first await"
      case "$default_vault" in
        "$sandbox"/*) ;;
        *) echo "      (it is outside the run's sandbox: remove it before the next run)" ;;
      esac
    fi
    failed+=("$name")
  fi
done
echo
echo "$ran tests run"
if [ "$ran" -eq 0 ]; then echo "FAILED: no tests match tests/*_test.gd"; exit 1; fi
if [ ${#failed[@]} -eq 0 ]; then echo "ALL TESTS PASS"; else echo "FAILED: ${failed[*]}"; exit 1; fi
