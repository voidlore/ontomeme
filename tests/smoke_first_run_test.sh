#!/usr/bin/env bash
# Tests scripts/smoke_first_run.sh without an export: its argument errors and
# refusals, then whole runs against a stand-in app (a shell script seeding
# what the real first launch seeds). Every run has `work` exported, naming a
# folder of the caller's: the script must never remove it, and must leave
# nothing in TMPDIR unless it failed and kept its sandbox for a look.
#   tests/smoke_first_run_test.sh
# Prints RESULT: ALL PASS (0 failures), or RESULT: FAIL (n failures) and exits 1.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

pass() { echo "PASS  $*"; }
fail() {
  echo "FAIL  $*"
  failures=$((failures + 1))
}

# The script's own mktemp dirs land here, where a test can see one left behind.
export TMPDIR="$tmp/tmpdir"
victim="$tmp/victim"

# The stand-in app. Its folders come from FAKE_DOCS/FAKE_USERDATA when set
# (as --docs/--userdata name them), else from the XDG dirs the sandbox gives
# it. FAKE_APP=reseed rewrites the notes on every launch, FAKE_APP=error logs
# an engine ERROR line.
app="$tmp/app/Ontomeme.x86_64"
mkdir -p "$tmp/app"
cat >"$app" <<'EOF'
#!/usr/bin/env bash
set -u
if [ -n "${FAKE_DOCS:-}" ]; then
  docs="$FAKE_DOCS"
  userdata="$FAKE_USERDATA"
else
  docs="$(sed -n 's/^XDG_DOCUMENTS_DIR="\(.*\)"$/\1/p' "$XDG_CONFIG_HOME/user-dirs.dirs")"
  userdata="$XDG_DATA_HOME/godot/app_userdata/Ontomeme"
fi
vault="$docs/Ontomeme"
mkdir -p "$userdata/logs"
echo "Godot Engine (stand-in), pid $$" >"$userdata/logs/godot.log"
if [ ! -e "$vault/.ontomeme/starter-seeded" ] || [ "${FAKE_APP:-}" = reseed ]; then
  for c in Tutorials:8 Godot:5 Memetics:6; do
    mkdir -p "$vault/${c%%:*}"
    i=0
    while [ "$i" -lt "${c#*:}" ]; do
      i=$((i + 1))
      echo note >"$vault/${c%%:*}/note$i.tres"
    done
  done
  mkdir -p "$vault/models" "$vault/.ontomeme"
  echo glb >"$vault/models/rocket.glb"
  echo seeded >"$vault/.ontomeme/starter-seeded"
fi
printf '{\n\t"last": "%s/",\n\t"recent": []\n}\n' "$vault" >"$userdata/vaults.json"
if [ "${FAKE_APP:-}" = error ]; then echo "ERROR: stand-in engine error"; fi
exit 0
EOF
chmod +x "$app"

# expect_smoke <exit> <what> <must-print> <smoke_first_run.sh args...>
expect_smoke() {
  local want="$1" what="$2" needle="$3" code left
  shift 3
  rm -rf "$victim" "$TMPDIR"
  mkdir -p "$victim" "$TMPDIR"
  echo precious >"$victim/data.txt"
  work="$victim" bash scripts/smoke_first_run.sh "$@" >"$tmp/smoke.out" 2>&1
  code=$?
  left="$(ls -A "$TMPDIR")"
  if [ "$code" -ne "$want" ]; then
    fail "$what: exit $code, expected $want"
  elif [ -n "$needle" ] && ! grep -qF -- "$needle" "$tmp/smoke.out"; then
    fail "$what: the output doesn't say '$needle'"
  elif [ ! -f "$victim/data.txt" ]; then
    fail "$what: removed $victim, the folder the caller's exported \$work named"
  elif [ "$want" -ne 1 ] && [ -n "$left" ]; then
    fail "$what: left $left in TMPDIR"
  else
    pass "$what"
    return 0
  fi
  sed 's/^/      /' "$tmp/smoke.out"
  return 1
}

# fresh <name>: an empty Documents folder and no user data, as --docs/--userdata take them.
fresh() {
  rm -rf "${tmp:?}/${1:?}"
  mkdir -p "$tmp/$1/Documents"
  docs="$tmp/$1/Documents"
  userdata="$tmp/$1/userdata"
}

# --- argument errors: exit 2, the caller's folders untouched
fresh args
expect_smoke 2 "no arguments print the usage" "scripts/smoke_first_run.sh <app-binary>"
expect_smoke 2 "a binary that isn't there" "not an executable file" "$tmp/no-such.x86_64" --linux-sandbox
expect_smoke 2 "an unknown option" "unknown option --timout" "$app" --timout 5
expect_smoke 2 "a --timeout that isn't whole seconds" "takes whole seconds" "$app" --timeout soon
expect_smoke 2 "--linux-sandbox with --docs/--userdata" "picks its own folders" \
  "$app" --linux-sandbox --docs "$docs" --userdata "$userdata"
expect_smoke 2 "--docs without --userdata" "go together" "$app" --docs "$docs"
expect_smoke 2 "a --docs folder that isn't there" "no documents folder" \
  "$app" --docs "$tmp/no-such-docs" --userdata "$userdata"

# --- not a first run: refused, and nothing of the user's is touched
fresh used-vault
mkdir -p "$docs/Ontomeme"
echo mine >"$docs/Ontomeme/mine.tres"
expect_smoke 2 "an existing vault is refused" "is not a first run" "$app" --docs "$docs" --userdata "$userdata"
if [ -f "$docs/Ontomeme/mine.tres" ]; then pass "the existing vault is untouched"; else fail "the existing vault lost mine.tres"; fi
fresh used-registry
mkdir -p "$userdata"
echo '{}' >"$userdata/vaults.json"
expect_smoke 2 "an existing vaults.json is refused" "is not a first run" "$app" --docs "$docs" --userdata "$userdata"
if [ "$(cat "$userdata/vaults.json")" = '{}' ]; then pass "the existing vaults.json is untouched"; else fail "the existing vaults.json changed"; fi

# --- whole runs against the stand-in app
if command -v xdg-user-dir >/dev/null 2>&1; then
  expect_smoke 0 "a good app passes in the Linux sandbox" "RESULT: ALL PASS" "$app" --linux-sandbox
else
  expect_smoke 2 "the Linux sandbox wants xdg-user-dir" "needs xdg-user-dir" "$app" --linux-sandbox
fi
fresh good
FAKE_DOCS="$docs" FAKE_USERDATA="$userdata" \
  expect_smoke 0 "a good app passes with --docs/--userdata" "RESULT: ALL PASS" "$app" --docs "$docs" --userdata "$userdata"
fresh reseed
FAKE_APP=reseed FAKE_DOCS="$docs" FAKE_USERDATA="$userdata" \
  expect_smoke 1 "an app that re-seeds on launch 2 fails" "launch 2 rewrote seeded files" \
  "$app" --docs "$docs" --userdata "$userdata"
fresh error
FAKE_APP=error FAKE_DOCS="$docs" FAKE_USERDATA="$userdata" \
  expect_smoke 1 "an app that logs an ERROR line fails" "launch 1 logged errors" \
  "$app" --docs "$docs" --userdata "$userdata"

echo
if [ "$failures" -eq 0 ]; then
  echo "RESULT: ALL PASS (0 failures)"
else
  echo "RESULT: FAIL ($failures failures)"
  exit 1
fi
