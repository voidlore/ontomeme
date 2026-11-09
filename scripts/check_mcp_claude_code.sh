#!/usr/bin/env bash
# Live check with a real Anthropic MCP client: Claude Code (`claude -p`)
# starts Ontomeme's MCP server through the --mcp-stdio boot switch, the way
# Claude Desktop does, and edits a scratch vault through it.
#
#   GODOT=/path/to/godot bash scripts/check_mcp_claude_code.sh
#
# It seeds a throwaway vault with two notes over stdio, writes a one-run MCP
# config for this checkout, and asks Claude to list the notes, append a line
# to one and move the other to the trash. Then it checks the disk: the line
# is in the first note and its SHA-256 changed, the second is in .trash/,
# nothing else changed. It prints the protocol version and clientInfo the
# client sent (the server logs them to stderr; Claude Code's debug log
# carries the server's stderr).
#
# Not in tests/run_all.sh: each run spends a little of your Claude quota
# (CHECK_MODEL, default sonnet; CHECK_BUDGET_USD caps it, default 1).
# Needs `claude` signed in (CLAUDE=<path> picks the binary) and python3.
# It never runs `claude mcp add` and never edits ~/.claude.json: the server
# is passed for this run only (--mcp-config with --strict-mcp-config), user
# settings, hooks, plugins and other MCP servers stay off, and Claude gets
# no built-in tools, only the five Ontomeme tools named below. The server
# runs in throwaway HOME and XDG dirs. KEEP_TMP=1 keeps the temp dir.
# Prints PASS per step and exits 0 only if all passed.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$(pwd)"
godot="$(command -v "${GODOT:-godot}" || true)"
claude_bin="$(command -v "${CLAUDE:-claude}" || true)"
model="${CHECK_MODEL:-sonnet}"
budget="${CHECK_BUDGET_USD:-1}"
[ -n "$godot" ] || { echo "FAIL  no Godot: set GODOT=/path/to/godot"; exit 1; }
[ -n "$claude_bin" ] || { echo "FAIL  no claude on PATH: set CLAUDE=/path/to/claude"; exit 1; }
case "$godot" in /*) ;; *) godot="$repo/$godot" ;; esac

tmp="$(mktemp -d)"
work="$tmp/work"
# Claude Code makes an empty ~/.claude/projects/<cwd>/memory folder for the
# temp working dir; rmdir removes it only while it is still empty.
claude_project="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$work")"
cleanup() {
  rmdir "$claude_project/memory" "$claude_project" 2>/dev/null || true
  if [ "${KEEP_TMP:-}" = "1" ]; then echo "      temp dir kept: $tmp"; else rm -rf "$tmp"; fi
}
trap cleanup EXIT
fail() { echo "FAIL  $*"; exit 1; }

vault="$tmp/vault"
home="$tmp/server-home"
mkdir -p "$vault" "$work" "$home/config" "$home/data" "$home/cache" "$home/Documents"
printf 'XDG_DOCUMENTS_DIR="%s/Documents"\n' "$home" >"$home/config/user-dirs.dirs"
server_args=(--headless --path "$repo" -- --mcp-stdio "--vault=$vault")
in_home() {
  env -u ONTOMEME_VAULT HOME="$home" XDG_CONFIG_HOME="$home/config" \
    XDG_DATA_HOME="$home/data" XDG_CACHE_HOME="$home/cache" "$@"
}

"$godot" --headless --path . --import >"$tmp/import.log" 2>&1 || true

# 1. Seed two notes over stdio with create_note.
note_a="Shopping List"
note_b="Old Draft"
marker="Checked by Claude Code $(date +%s)-$RANDOM"
in_home python3 -I - "$note_a" "$note_b" "$godot" "${server_args[@]}" >"$tmp/seed.txt" <<'PY' \
  || fail "seed: create_note over stdio ($(cat "$tmp/seed.txt" 2>/dev/null))"
import json, subprocess, sys
a, b, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
msgs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "check-seed", "version": "1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "create_note", "arguments": {
        "title": a, "markdown": "# %s\n\n- apples\n- bread\n" % a}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "create_note", "arguments": {
        "title": b, "markdown": "Scratch text that can go.\n"}}},
]
p = subprocess.run(cmd, input="".join(json.dumps(m) + "\n" for m in msgs), capture_output=True, text=True, timeout=60)
replies = {r.get("id"): r for r in (json.loads(l) for l in p.stdout.splitlines() if l.strip())}
paths = []
for i in (2, 3):
    res = replies.get(i, {}).get("result", {})
    if res.get("isError") is not False:
        sys.exit("create_note %d failed: %s" % (i, replies.get(i)))
    paths.append(res["structuredContent"]["path"])
print("\n".join(paths))
PY
path_a="$(sed -n 1p "$tmp/seed.txt")"
path_b="$(sed -n 2p "$tmp/seed.txt")"
[ -f "$vault/$path_a" ] && [ -f "$vault/$path_b" ] || fail "seed: the two notes are not in the vault"
hash_a="$(sha256sum "$vault/$path_a" | cut -d' ' -f1)"
hash_b="$(sha256sum "$vault/$path_b" | cut -d' ' -f1)"
echo "PASS  seed: '$note_a' ($path_a) and '$note_b' ($path_b) over stdio"

# 2. A one-run MCP config: the shipped entry (--headless -- --mcp-stdio)
#    with --path for a source checkout, in the throwaway home.
cfg="$tmp/mcp.json"
python3 -I - "$cfg" "$godot" "$home" "${server_args[@]}" <<'PY'
import json, sys
cfg, godot, home, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
env = {"HOME": home, "XDG_CONFIG_HOME": home + "/config", "XDG_DATA_HOME": home + "/data", "XDG_CACHE_HOME": home + "/cache"}
json.dump({"mcpServers": {"ontomeme": {"command": godot, "args": args, "env": env}}}, open(cfg, "w"), indent=2)
PY

# 3. Claude Code as the client. The session variables of an enclosing Claude
#    Code session are dropped, so a run from inside one behaves like a run
#    from a terminal.
tools="mcp__ontomeme__list_notes,mcp__ontomeme__read_note,mcp__ontomeme__update_note,mcp__ontomeme__delete_note,mcp__ontomeme__create_note"
prompt="Use only the ontomeme tools. 1) List the notes. 2) Append one new last line to the note titled \"$note_a\", exactly: $marker
Keep the rest of its body unchanged. 3) Move the note titled \"$note_b\" to the trash. Then answer with the titles you listed, one per line."
unset_session=()
for v in CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION \
    CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN \
    CLAUDE_CODE_BRIDGE_SESSION_ID CLAUDE_CODE_AGENT CLAUDE_CODE_EXECPATH CLAUDE_PID CLAUDE_EFFORT CLAUDE_JOB_DIR; do
  unset_session+=(-u "$v")
done
echo "      run: claude -p --model $model --mcp-config <tmp>/mcp.json --strict-mcp-config --tools '' --allowedTools <5 ontomeme tools>"
code=0
(cd "$work" && env "${unset_session[@]}" timeout 600 "$claude_bin" -p \
    --model "$model" --max-budget-usd "$budget" \
    --mcp-config "$cfg" --strict-mcp-config \
    --setting-sources project,local --tools "" --allowedTools "$tools" --permission-mode dontAsk \
    --no-session-persistence --debug-file "$tmp/claude-debug.log" \
    --output-format json "$prompt" >"$tmp/claude.json" 2>"$tmp/claude.err") || code=$?
python3 -I - "$tmp/claude.json" "$code" >"$tmp/summary.txt" <<'PY' || { cat "$tmp/summary.txt"; tail -5 "$tmp/claude.err" | sed 's/^/      stderr: /'; fail "claude -p did not finish cleanly"; }
import json, sys
code = int(sys.argv[2])
try:
    out = json.load(open(sys.argv[1]))
except ValueError:
    sys.exit("      claude printed no JSON result (exit %d)" % code)
denied = [d.get("tool_name") for d in out.get("permission_denials", [])]
print("      claude: exit %d, %s, %s turns, $%.4f, denied %s" % (code, out.get("subtype"), out.get("num_turns"), out.get("total_cost_usd") or 0, denied or "none"))
for line in str(out.get("result", "")).strip().splitlines()[:8]:
    print("      answer: " + line)
sys.exit(0 if code == 0 and out.get("is_error") is False and not denied else 1)
PY
cat "$tmp/summary.txt"
echo "PASS  claude -p finished: no error, no permission denials"

# 4. The disk.
[ -f "$vault/$path_a" ] || fail "'$note_a' is gone from $path_a"
grep -qF "$marker" "$vault/$path_a" || fail "'$note_a' does not contain the line Claude was asked to append"
grep -qF -- "- bread" "$vault/$path_a" || fail "'$note_a' lost its earlier lines"
new_hash_a="$(sha256sum "$vault/$path_a" | cut -d' ' -f1)"
[ "$new_hash_a" != "$hash_a" ] || fail "'$note_a' has the same SHA-256 as before"
echo "PASS  '$note_a' has the appended line and its earlier lines; SHA-256 ${hash_a:0:12} -> ${new_hash_a:0:12}"
[ ! -e "$vault/$path_b" ] || fail "'$note_b' is still at $path_b"
trashed="$(cd "$vault" && find .trash -type f -name '*.tres' 2>/dev/null | head -1)"
[ -n "$trashed" ] || fail "'$note_b' is not in .trash/"
[ "$(sha256sum "$vault/$trashed" | cut -d' ' -f1)" = "$hash_b" ] || fail "the trashed file is not the note as seeded"
echo "PASS  '$note_b' moved to $trashed, byte-identical"
others="$(cd "$vault" && find . -type f ! -path "./$path_a" ! -path "./$trashed" | sed 's|^\./||')"
[ -z "$others" ] || fail "other files in the vault: $others"
echo "PASS  no other file in the vault"

# 5. What the client sent: the server logs it to stderr, and Claude Code's
#    debug log carries the server's stderr (as JSON string literals).
python3 -I - "$tmp/claude-debug.log" <<'PY' || fail "the server's 'client requested protocol' line or Claude Code's negotiated version is not in the debug log"
import json, re, sys
stderr, negotiated = [], None
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = re.search(r'\] ("MCP server .*")$', line.rstrip("\n"))
    if m and "Server stderr:" in m.group(1):
        stderr += json.loads(m.group(1)).split("Server stderr:", 1)[1].strip().splitlines()
    m = re.search(r'MCP server "ontomeme": Connection established with capabilities: (\{.*\})', line)
    if m:
        negotiated = json.loads(m.group(1)).get("negotiatedProtocolVersion")
hello = [l.split("] ", 1)[1] for l in stderr if "] client requested protocol " in l]
for l in stderr:
    print("      server stderr: " + l)
if not hello:
    sys.exit(1)
answered = re.search(r"answered (\S+?)[ ;]", hello[0])
print("PASS  the server logged the client's initialize: " + hello[0])
print("      Claude Code: negotiatedProtocolVersion %s" % negotiated)
sys.exit(0 if negotiated and answered and answered.group(1) == negotiated else 1)
PY
echo "PASS  Claude Code connected with the version the server answered"

# 6. Nothing was registered: no MCP server in ~/.claude.json points into this run.
cfg_home="${CLAUDE_CONFIG_DIR:-$HOME}"
# shellcheck disable=SC2088  # "~/.claude.json" is a message, not a path
python3 -I - "$cfg_home/.claude.json" "$tmp" <<'PY' || fail "~/.claude.json lists an MCP server from this run"
import json, os, sys
path, tmp = sys.argv[1], sys.argv[2]
if not os.path.isfile(path):
    sys.exit(0)
data = json.load(open(path))
servers = [data.get("mcpServers") or {}] + [(p or {}).get("mcpServers") or {} for p in (data.get("projects") or {}).values()]
sys.exit(1 if any(tmp in json.dumps(s) for s in servers) else 0)
PY
echo "PASS  no MCP server from this run is registered in ~/.claude.json"
echo "RESULT: ALL PASS"
