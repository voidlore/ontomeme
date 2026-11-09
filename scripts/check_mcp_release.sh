#!/usr/bin/env bash
# Export the Linux release build and prove that the shipped binary serves MCP
# over stdio: `Ontomeme.x86_64 --headless --log-file user://logs/mcp.log --
# --mcp-stdio --vault=<dir>`, the README's args.
# Release templates ignore -s, so only a real export proves the boot switch;
# the tests run the editor binary only.
#
#   GODOT=/path/to/godot bash scripts/check_mcp_release.sh [--binary <Ontomeme.x86_64>]
#
# --binary   check a build you already exported instead of exporting one.
# Needs Linux, python3 and the export templates for the editor's version
# (Editor > Manage Export Templates; found in $GODOT_TEMPLATES or
# ${XDG_DATA_HOME:-~/.local/share}/godot/export_templates). Reads
# export_presets.cfg, never writes it. Every run gets throwaway HOME and XDG
# dirs, so nothing reaches ~/Documents/Ontomeme or the real user:// dir.
# Prints PASS per step and exits 0 only if all passed. CHECK_MCP_FLAG=""
# drops --mcp-stdio from the run args, to see the check fail.
set -euo pipefail
cd "$(dirname "$0")/.."
godot="${GODOT:-godot}"
flag="${CHECK_MCP_FLAG-"--mcp-stdio"}"
preset="Linux x86_64"
binary=""
if [ "${1:-}" = "--binary" ]; then
  binary="$(realpath "${2:?--binary needs a path}")"
elif [ $# -gt 0 ]; then
  echo "usage: GODOT=<godot> bash scripts/check_mcp_release.sh [--binary <Ontomeme.x86_64>]" >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL  $*"; exit 1; }

# A throwaway machine: HOME, XDG config/data/cache and a Documents folder.
make_home() {
  local home="$tmp/$1"
  mkdir -p "$home/config" "$home/data" "$home/cache" "$home/Documents"
  printf 'XDG_DOCUMENTS_DIR="%s/Documents"\n' "$home" >"$home/config/user-dirs.dirs"
  echo "$home"
}

in_home() {
  local home="$1"; shift
  env -u ONTOMEME_VAULT HOME="$home" XDG_CONFIG_HOME="$home/config" \
    XDG_DATA_HOME="$home/data" XDG_CACHE_HOME="$home/cache" "$@"
}

export_build() {
  local version tver templates home log
  version="$("$godot" --headless --version 2>/dev/null | tail -1)"
  tver="$(grep -oE '^[0-9]+(\.[0-9]+)+\.[a-z]+[0-9]*' <<<"$version" || true)"
  [ -n "$tver" ] || fail "could not read the Godot version from: $version"
  templates="${GODOT_TEMPLATES:-${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates}/$tver"
  [ -f "$templates/linux_release.x86_64" ] || fail "no $tver export templates in $templates"
  home="$(make_home export)"
  mkdir -p "$home/data/godot/export_templates" "$tmp/build"
  ln -s "$templates" "$home/data/godot/export_templates/$tver"
  binary="$tmp/build/Ontomeme.x86_64"
  log="$tmp/export.log"
  in_home "$home" "$godot" --headless --path . --import >"$log" 2>&1 || true
  if ! in_home "$home" "$godot" --headless --path . --export-release "$preset" "$binary" >>"$log" 2>&1 \
      || [ ! -x "$binary" ]; then
    tail -20 "$log" | sed 's/^/      /'
    fail "export: '$preset' release build"
  fi
  echo "PASS  export: '$preset' release build with the $tver templates ($(du -m "$binary" | cut -f1) MB)"
}

# Drive the build over stdio in its own home. Returns the driver's exit code.
drive() {
  local name="$1" timeout="$2" run_flag="$3" home vault args
  home="$(make_home "$name")"
  vault="$tmp/vault-$name"
  mkdir -p "$vault"
  args=(--headless --log-file user://logs/mcp.log --)
  [ -n "$run_flag" ] && args+=("$run_flag")
  args+=("--vault=$vault")
  in_home "$home" python3 -I scripts/mcp_drive.py --vault "$vault" --timeout "$timeout" \
    -- "$binary" "${args[@]}"
}

no_user_writes() {
  local home="$tmp/$1" user
  user="$home/data/godot/app_userdata/Ontomeme"
  [ ! -e "$home/Documents/Ontomeme" ] || fail "MCP mode created <Documents>/Ontomeme"
  [ ! -e "$user/vaults.json" ] || fail "MCP mode wrote user://vaults.json"
  [ ! -e "$user/display.json" ] || fail "MCP mode wrote user://display.json"
  echo "PASS  no <Documents>/Ontomeme, user://vaults.json or user://display.json (HOME and XDG overridden)"
  # Every reply holds note text: it goes to the server's own log, never to
  # godot.log, the app's log a bug report asks for.
  [ ! -e "$user/logs/godot.log" ] || fail "MCP mode wrote user://logs/godot.log, the app's log"
  grep -q '\[ontomeme-mcp\] serving vault' "$user/logs/mcp.log" 2>/dev/null \
    || fail "MCP mode logged nothing to user://logs/mcp.log"
  echo "PASS  the server logs to user://logs/mcp.log, not the app's user://logs/godot.log"
}

if [ -z "$binary" ]; then
  export_build
fi
[ -x "$binary" ] || fail "not an executable build: $binary"
echo "      run: Ontomeme.x86_64 --headless --log-file user://logs/mcp.log -- ${flag:+$flag }--vault=<tmp>"
drive run 20 "$flag" || fail "the release build did not serve MCP over stdio"
no_user_writes run
# The driver must fail on a build that is not serving: without --mcp-stdio the
# app starts its (windowless) note window instead and never answers.
if [ -n "$flag" ]; then
  if drive control 8 "" >"$tmp/control.log" 2>&1; then
    fail "sanity: the driver passed without --mcp-stdio, so it detects nothing"
  fi
  echo "PASS  sanity: without --mcp-stdio the same drive fails ($(grep -m1 '^FAIL' "$tmp/control.log" | cut -c7-80))"
fi
echo "RESULT: ALL PASS"
