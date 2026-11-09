#!/usr/bin/env bash
# Tests for lib_fixtures.sh's fixture_godot_exports, with a stand-in Godot (no
# real export runs). The stand-in is reached through a launcher that finds the
# engine via $HOME, like ~/.local/bin/godot does.
#   scripts/sign/test_lib_fixtures.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib_fixtures.sh
. "$here/lib_fixtures.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
VERSION_DIR=4.7.2.stable

# The caller's home: the engine where the launcher looks for it, and the export
# templates where fixture_godot_exports looks for them without XDG_DATA_HOME.
caller_home="$work/caller-home"
engine="$caller_home/.local/share/Steam/steamapps/common/Godot Engine/godot.bin"
mkdir -p "$(dirname "$engine")" "$caller_home/.local/share/godot/export_templates/$VERSION_DIR" "$work/bin"
calls="$work/calls.log"

cat >"$engine" <<'ENGINE'
#!/usr/bin/env bash
# Stand-in Godot: logs its environment and arguments, writes the export target.
printf 'HOME=%s|CONFIG=%s|DATA=%s|CACHE=%s|ARGS=%s\n' "$HOME" "${XDG_CONFIG_HOME:-}" \
  "${XDG_DATA_HOME:-}" "${XDG_CACHE_HOME:-}" "$*" >>"$FAKE_GODOT_CALLS"
if [ "${1:-}" = --version ]; then echo 4.7.2.stable.custom_build.0123abcd; exit 0; fi
while [ $# -gt 0 ]; do
  if [ "$1" = --export-release ]; then
    if [ "$2" = "${FAKE_GODOT_FAIL_PRESET:-}" ]; then echo "ERROR: Cannot export '$2'"; exit 1; fi
    [ -d "$XDG_DATA_HOME/godot/export_templates/4.7.2.stable" ] || { echo "ERROR: no templates"; exit 1; }
    printf 'stand-in %s export\n' "$2" >"$3"
    exit 0
  fi
  shift
done
exit 0
ENGINE

# The launcher, shaped like ~/.local/bin/godot.
cat >"$work/bin/godot" <<'LAUNCHER'
#!/usr/bin/env bash
exec "$HOME/.local/share/Steam/steamapps/common/Godot Engine/godot.bin" "$@"
LAUNCHER
chmod 755 "$engine" "$work/bin/godot"

# exports DIR [FAIL_PRESET]: fixture_godot_exports DIR as a caller whose HOME
# is $caller_home and whose XDG dirs are unset, the stand-in failing the export
# of FAIL_PRESET; prints its status and reason.
exports() {
  local dir="$1"
  mkdir -p "$dir"
  (
    unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
    export HOME="$caller_home" GODOT="$work/bin/godot" FAKE_GODOT_CALLS="$calls" FAKE_GODOT_FAIL_PRESET="${2:-}"
    status=0
    fixture_godot_exports "$dir" || status=$?
    echo "status=$status reason=$FIXTURE_REASON"
    exit "$status"
  )
}

: >"$calls"
check_case "a launcher that finds Godot through \$HOME exports both presets" 0 \
  --has "status=0" \
  -- exports "$work/ok"
for file in Ontomeme.zip Ontomeme.exe; do
  if [ -s "$work/ok/$file" ]; then t_pass "$file exported"; else t_fail "$file exported" "missing"; fi
done

check_case "import and exports keep HOME and sandbox the XDG dirs under DIR" 0 -- \
  python3 -I -c '
import sys
calls, home, out = sys.argv[1:4]
runs = [dict(f.split("=", 1) for f in line.rstrip("\n").split("|")) for line in open(calls)]
godot = [r for r in runs if r["ARGS"] != "--version"]
args = [r["ARGS"] for r in godot]
assert len(godot) == 3, args
assert "--import" in args[0] and "--export-release macOS" in args[1], args
assert "--export-release Windows x86_64" in args[2], args
for r in godot:
    assert r["HOME"] == home, ("HOME was replaced", r)
    for key in ("CONFIG", "DATA", "CACHE"):
        assert r[key].startswith(out + "/"), (key, "is not under DIR", r)
' "$calls" "$caller_home" "$work/ok"

check_case "a failed export -> status 1 naming the preset and the log" 1 \
  --has "status=1" --has "export of 'Windows x86_64' failed" --has "ERROR: Cannot export 'Windows x86_64'" \
  -- exports "$work/fail" "Windows x86_64"

rm -r "$caller_home/.local/share/godot/export_templates/$VERSION_DIR"
check_case "no export templates -> skip (status 2) saying where it looked" 2 \
  --has "status=2" --has "no export templates at $caller_home/.local/share/godot/export_templates/$VERSION_DIR" \
  -- exports "$work/notemplates"

t_finish
