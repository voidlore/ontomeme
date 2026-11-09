#!/usr/bin/env bash
# First-run smoke test for an exported Ontomeme build: launch it the way a
# brand-new user does, check what the first launch made, launch it again and
# check that nothing was seeded twice.
#
#   scripts/smoke_first_run.sh <app-binary> [--linux-sandbox] [--timeout 150]
#   scripts/smoke_first_run.sh <app-binary> --docs <documents-dir> --userdata <godot-user-dir> [--timeout 150]
#
# --linux-sandbox (the default on Linux) runs the app with a throwaway HOME,
#   XDG_CONFIG_HOME, XDG_DATA_HOME and a user-dirs.dirs naming its own
#   Documents folder, all in one mktemp dir, so the real ~/Documents/Ontomeme
#   and user:// are never touched. Needs xdg-user-dir (package xdg-user-dirs).
# --docs/--userdata name the folders the app itself will use on a clean
#   machine (macOS and Windows runners, where XDG doesn't apply), e.g.
#     macOS:   --docs ~/Documents --userdata ~/"Library/Application Support/Godot/app_userdata/Ontomeme"
#     Windows: --docs "$USERPROFILE/Documents" --userdata "$APPDATA/Godot/app_userdata/Ontomeme"
#   Nothing is deleted there: the script refuses to run if <docs>/Ontomeme or
#   <userdata>/vaults.json already exists, because then it isn't a first run.
#
# Launch 1 (`<bin> --headless --quit-after 200`) must exit 0 and leave
# <docs>/Ontomeme holding the starter courses, models/rocket.glb and
# .ontomeme/starter-seeded, with <userdata>/vaults.json's "last" naming that
# vault. Neither launch may log SCRIPT ERROR, Parse Error or an "ERROR:"
# line, on stdout/stderr or in <userdata>/logs/godot.log. Launch 2 must find
# the same notes and rewrite none of them. Exits 0 when all of that holds,
# 1 when a check fails (the vault tree and the log tails are printed, and a
# sandbox is kept for a look), 2 on bad arguments.
set -uo pipefail

# What the first launch seeds: <folder>:<number of notes (.tres) in it>.
# Observed 2026-11-07; change these when a course gains or loses a lesson.
COURSES="Tutorials:8 Godot:5 Memetics:6"
SEEDED_FILES="models/rocket.glb .ontomeme/starter-seeded"
LOG_PROBLEMS='SCRIPT ERROR|Parse Error|^ERROR:'

usage() {
  sed -n 's/^#   \(scripts\/smoke_first_run\.sh .*\)/\1/p' "$0" >&2
  exit 2
}

bad_args() {
  echo "smoke: $*" >&2
  [ -z "${work:-}" ] || rm -rf "$work"
  exit 2
}

work=""   # the mktemp dir bad_args removes; never one the caller's environment named
bin=""
mode=""
docs=""
userdata=""
limit=150
while [ $# -gt 0 ]; do
  case "$1" in
    --linux-sandbox) mode=sandbox ;;
    --docs) [ $# -ge 2 ] || usage; docs="$2"; shift ;;
    --userdata) [ $# -ge 2 ] || usage; userdata="$2"; shift ;;
    --timeout) [ $# -ge 2 ] || usage; limit="$2"; shift ;;
    -h | --help) usage ;;
    -*) bad_args "unknown option $1" ;;
    *) [ -z "$bin" ] || usage; bin="$1" ;;
  esac
  shift
done
[ -n "$bin" ] || usage
case "$limit" in '' | *[!0-9]*) bad_args "--timeout takes whole seconds, not '$limit'" ;; esac
if [ -n "$docs$userdata" ]; then
  [ "$mode" != sandbox ] || bad_args "--linux-sandbox picks its own folders: drop --docs/--userdata"
  [ -n "$docs" ] && [ -n "$userdata" ] || bad_args "--docs and --userdata go together"
  mode=given
elif [ -z "$mode" ]; then
  [ "$(uname -s)" = Linux ] || bad_args "outside Linux, name the app's folders with --docs and --userdata"
  mode=sandbox
fi
[ -f "$bin" ] && [ -x "$bin" ] || bad_args "not an executable file: $bin"
case "$bin" in /* | ?:[\\/]*) ;; *) bin="$PWD/$bin" ;; esac

work="$(mktemp -d)" || bad_args "mktemp failed"
launch_env=()

# set_up_sandbox: a fresh HOME, XDG dirs and Documents folder under $work.
# Godot finds Documents by running xdg-user-dir, which reads
# $XDG_CONFIG_HOME/user-dirs.dirs. Keep it out of any Godot project: Godot
# turns a path inside the project into res://, which breaks
# VaultStore.folder_of (seen running the app from source).
set_up_sandbox() {
  local up="$work"
  command -v xdg-user-dir >/dev/null 2>&1 \
    || bad_args "--linux-sandbox needs xdg-user-dir (package xdg-user-dirs): without it Godot finds no Documents folder"
  while [ -n "$up" ] && [ "$up" != / ]; do
    [ ! -e "$up/project.godot" ] || bad_args "the temp dir $work is inside the Godot project $up: set TMPDIR elsewhere"
    up="$(dirname "$up")"
  done
  mkdir -p "$work/home" "$work/config" "$work/data" "$work/cache" "$work/Documents"
  printf 'XDG_DOCUMENTS_DIR="%s/Documents"\n' "$work" >"$work/config/user-dirs.dirs"
  launch_env=(HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" XDG_CACHE_HOME="$work/cache")
  docs="$work/Documents"
  userdata="$work/data/godot/app_userdata/Ontomeme"
}

if [ "$mode" = sandbox ]; then
  set_up_sandbox
else
  [ -d "$docs" ] || bad_args "no documents folder at $docs"
  docs="$(cd "$docs" && pwd)"
  case "$userdata" in /* | ?:[\\/]*) ;; *) userdata="$PWD/$userdata" ;; esac
  [ ! -e "$docs/Ontomeme" ] || bad_args "$docs/Ontomeme already exists, so this is not a first run (nothing was changed)"
  [ ! -e "$userdata/vaults.json" ] || bad_args "$userdata/vaults.json already exists, so this is not a first run (nothing was changed)"
fi
vault="$docs/Ontomeme"
failures=0

ok() { echo "ok    $*"; }
fail() {
  echo "FAIL  $*"
  failures=$((failures + 1))
}

# A working timeout(1): GNU coreutils, gtimeout on macOS with coreutils, and
# not Windows' own timeout.exe, which Git Bash can find first on PATH.
timer=""
for t in timeout gtimeout; do
  if command -v "$t" >/dev/null 2>&1 && "$t" 5 true >/dev/null 2>&1; then
    timer="$t"
    break
  fi
done

# watchdog <seconds> <command...>: timeout(1) for machines without one.
# TERM the command when time is up, KILL it 5 s later, return 124 if it fired.
watchdog() {
  local secs="$1" pid dog code flag="$work/.watchdog-fired"
  shift
  rm -f "$flag"
  "$@" &
  pid=$!
  (
    nap=""
    trap 'kill "$nap" 2>/dev/null; exit 0' TERM   # the launch ended in time
    sleep "$secs" &
    nap=$!
    wait "$nap"
    trap - TERM
    : >"$flag"
    kill -TERM "$pid"
    sleep 5
    kill -KILL "$pid"
  ) >/dev/null 2>&1 &
  dog=$!
  wait "$pid"
  code=$?
  kill -TERM "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null
  if [ -e "$flag" ]; then code=124; fi
  return "$code"
}

# launch <n>: run the app headless for 200 frames from $work (so a stray
# relative path lands there), saving its output and this launch's godot.log
# as $work/launch<n>.out and $work/launch<n>.log. Godot renames the previous
# godot.log at startup, so the copy has to happen now. A godot.log that is
# byte for byte the one from before the launch is not this launch's.
launch() {
  local n="$1" code log="$userdata/logs/godot.log" prior
  prior="$work/before-launch$n.log"
  rm -f "$prior"
  if [ -f "$log" ]; then cp "$log" "$prior"; fi
  (
    cd "$work" || exit 1
    if [ -n "$timer" ]; then
      "$timer" "$limit" env ${launch_env[@]+"${launch_env[@]}"} "$bin" --headless --quit-after 200
    else
      watchdog "$limit" env ${launch_env[@]+"${launch_env[@]}"} "$bin" --headless --quit-after 200
    fi
  ) >"$work/launch$n.out" 2>&1
  code=$?
  case "$code" in
    0) ok "launch $n exited 0" ;;
    124) fail "launch $n timed out after $limit s" ;;
    *) fail "launch $n exited $code" ;;
  esac
  if [ -f "$log" ] && ! { [ -f "$prior" ] && cmp -s "$log" "$prior"; }; then
    cp "$log" "$work/launch$n.log"
  else
    fail "launch $n wrote no $log"
  fi
  check_log "$n"
}

# check_log <n>: no script or engine errors in launch n's output or log.
check_log() {
  local n="$1" f found=0
  for f in "$work/launch$n.out" "$work/launch$n.log"; do
    [ -f "$f" ] || continue
    if grep -qE "$LOG_PROBLEMS" "$f"; then
      found=1
      fail "launch $n logged errors in $(basename "$f"):"
      grep -E "$LOG_PROBLEMS" "$f" | head -n 20 | sed 's/^/        /'
    fi
  done
  [ "$found" -eq 1 ] || ok "launch $n logged no errors"
}

note_count() {
  find "$vault/$1" -maxdepth 1 -type f -name '*.tres' 2>/dev/null | wc -l | tr -d ' '
}

# counts: "<folder>=<notes>" for each course, to compare launches by.
counts() {
  local c
  for c in $COURSES; do printf '%s=%s ' "${c%%:*}" "$(note_count "${c%%:*}")"; done
}

check_vault() {
  local c folder want have f
  if [ ! -d "$vault" ]; then
    fail "no vault at $vault"
  fi
  for c in $COURSES; do
    folder="${c%%:*}"
    want="${c#*:}"
    if [ ! -d "$vault/$folder" ]; then
      fail "missing the $folder folder: $vault/$folder"
      continue
    fi
    have="$(note_count "$folder")"
    if [ "$have" -eq "$want" ]; then ok "$folder holds $have notes"; else fail "$folder holds $have notes, expected $want"; fi
  done
  for f in $SEEDED_FILES; do
    if [ -f "$vault/$f" ]; then ok "$f is there"; else fail "missing $vault/$f"; fi
  done
}

# same_path <a> <b>: equal once slashes, a trailing slash and Git Bash's
# /c/... spelling of C:/... are evened out.
same_path() {
  local a="$1" b="$2"
  if command -v cygpath >/dev/null 2>&1; then
    a="$(cygpath -m "$a")"
    b="$(cygpath -m "$b")"
  fi
  a="${a//\\//}"
  b="${b//\\//}"
  [ "${a%/}" = "${b%/}" ]
}

# check_registry: user://vaults.json remembers the new vault as the last one.
# Godot writes it with one key per line: "last": "<path>",
check_registry() {
  local f="$userdata/vaults.json" last
  if [ ! -f "$f" ]; then
    fail "no $f"
    return
  fi
  last="$(sed -n 's/^[[:space:]]*"last":[[:space:]]*"\(.*\)",\{0,1\}[[:space:]]*$/\1/p' "$f" | head -n 1)"
  if same_path "$last" "$vault/"; then ok "vaults.json remembers $last"; else fail "vaults.json's last is '$last', expected '$vault/'"; fi
}

# check_no_reseed <stamp>: launch 2 rewrote no note and no seeded file.
check_no_reseed() {
  local rewritten
  rewritten="$(find "$vault" -type f \( -name '*.tres' -o -path "$vault/models/rocket.glb" \
    -o -path "$vault/.ontomeme/starter-seeded" \) -newer "$1" 2>/dev/null | sed "s|^$vault/||")"
  if [ -z "$rewritten" ]; then
    ok "launch 2 rewrote no note"
  else
    fail "launch 2 rewrote seeded files:"
    printf '%s\n' "$rewritten" | head -n 20 | sed 's/^/        /'
  fi
}

report_failure() {
  local f
  echo
  echo "--- vault tree ($vault)"
  if [ -d "$vault" ]; then
    find "$vault" | sed "s|^$vault/\{0,1\}|  |" | sort
  else
    echo "  (missing)"
  fi
  for f in "$work"/launch*.out "$work"/launch*.log; do
    [ -f "$f" ] || continue
    echo "--- last 30 lines of $(basename "$f")"
    tail -n 30 "$f"
  done
  echo
  if [ "$mode" = sandbox ]; then echo "kept the sandbox for a look: $work"; else echo "launch output kept in $work"; fi
  echo "RESULT: FAIL ($failures failures)"
  exit 1
}

echo "smoke: $bin"
echo "       vault $vault"
echo "       user data $userdata"
launch 1
check_vault
check_registry
[ "$failures" -eq 0 ] || report_failure

before="$(counts)"
touch "$work/.before-launch-2"
sleep 1   # a launch-2 write lands in a later second even on 1 s mtime filesystems
launch 2
after="$(counts)"
if [ "$after" = "$before" ]; then ok "launch 2 kept the notes: ${after% }"; else fail "launch 2 changed the notes: ${before% } became ${after% }"; fi
check_no_reseed "$work/.before-launch-2"
check_registry
[ "$failures" -eq 0 ] || report_failure

rm -rf "$work"
echo "RESULT: ALL PASS (0 failures)"
