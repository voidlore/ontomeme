# Ontomeme MCP server

Lets Claude (or any MCP client) list, read, search, create, edit, move and
delete the notes in an Ontomeme vault, list its tags, attach notes as
read-only resources, and read the learner's quiz results and Learning
Journey.

## Files

| File | What it is |
|---|---|
| `protocol.gd` | JSON-RPC 2.0 + MCP lifecycle (`initialize`, `notifications/initialized`, `notifications/cancelled`, `ping`, `tools/list`, `tools/call`, and `resources/list`, `resources/templates/list`, `resources/read` when the tools object has the resource methods), plus requests from the server to the client. Pure: `handle(message) -> response or null`, an `outgoing` signal for what it sends on its own, and a `client_initialized` signal for the host to log. No I/O. |
| `vault_tools.gd` | The tools and resources (below), over one vault folder. No UI, no stdio. |
| `note_guide.md` | What `get_note_guide` returns: a byte-for-byte copy of `skills/ontomeme-notes/references/markup.md`. |
| `stdio_transport.gd` | A Node that reads stdin on a thread and writes replies and `outgoing` messages to stdout, one JSON message per line, and calls the protocol's `tick` every frame. Every message is written with `McpProtocol.to_json`, not `JSON.stringify`: Godot's leaves most control characters raw and writes U+000B as `\v`, which strict JSON parsers refuse, so one pasted vertical tab or ANSI colour code lost a whole reply. |
| `serve.gd` | Picks the vault, reads the confirmations setting and starts the stdio transport. Shared by the app's boot scene (`--mcp-stdio`) and `stdio_server.gd`. |
| `stdio_server.gd` | `-s` entry point for development (editor builds only; see below). |
| `../boot.gd` | The app's main scene: `--mcp-stdio` serves MCP with no window, anything else opens `note.tscn`. |
| `desktop_config.gd` | The Claude Desktop config entry for this install (`snippet()`, `config_path_hint()`) and the palette's "Connect Claude Desktop…" dialog that shows it with a Copy button. Never writes Claude's config file. |

The protocol and tools don't depend on stdio or on the app's window, so the
same code can run headless (launched by the client) or inside the running app
behind a bridge. Shipped builds run it headless: the client starts the app
with `--headless -- --mcp-stdio` (the boot switch in `../boot.gd`). An
in-app bridge is not built.

## Tools

| Tool | Does | Notes |
|---|---|---|
| `list_notes` | notes (path, title, folder, tags, dates, `starred_at`, `pinned_at`, `format`), a page at a time, and folders | optional `folder`, `limit`, `cursor`; includes `.txt` files; folders on the first page only |
| `read_note` | title, tags, dates, `starred_at`, `pinned_at`, Markdown body, `hash`, `editable` | `raw: true` adds the `.tres` text (no-op for `.txt`); `.txt` adds `encoding` |
| `create_note` | new note named `note_<title>.tres`, like the app | `format: "text"` writes a raw `.txt`; refuses if the file exists; returns lint `warnings` |
| `update_note` | replace title / body / tags (`.txt`: body only, UTF-8 only). A new title renames the file the way the app does, and [[links]], quiz `learn:`/`next:` lines, Journey and progress follow it | needs `hash`; `destructiveHint`; asks the user first (see Confirmations); `exists` for a title another note has; `not_utf8` for a non-UTF-8 `.txt`; returns the new `path`, the other notes rewritten (`changed`) and lint `warnings` |
| `delete_note` | moves the file (`.tres` or `.txt`) to `<vault>/.trash/<path>` | needs `hash`; `destructiveHint`; asks the user first (see Confirmations); never hard-deletes |
| `move_note` | moves the file into `folder` (created if missing; `""` = top level) | needs `hash`; refuses `exists` if the folder has that file name; returns the new `path` and `hash` |
| `search_notes` | `query` (title or body), `title`, `tag`, `folder`, a page at a time | case-insensitive, AND; `tag` never matches `.txt`; `limit`, `cursor`; `total` counts every match |
| `list_tags` | the vault's tags with how many notes carry each, most used first | optional `folder`; read-only; trashed notes not counted |
| `get_note_guide` | the note markup guide: Markdown, `[[links]]`, ```` ```3d ```` blocks, quizzes, flashcards | optional `topic` (`3d`, `quiz`, `flashcards`, `links`); `readOnlyHint`; works without a vault |
| `get_progress` | per note: each quiz's `passed`, `score` (best), `last`, `total`; `missed` questions with their `learn:` target | optional `note` (title or path); read-only |
| `get_journey` | topics → objectives (`met`) → demos (`done`, `attempts`, `latest`) and the score `log` | journey.json's v1 shape plus those fields; read-only |

- A note is addressed by its path inside the vault (`Physics/note_waves.tres`,
  `notes/field.txt`). Paths outside the vault, absolute paths, hidden
  folders (`.trash`, `.ontomeme`) and the root asset folder `models/` are
  refused with `invalid_path`.
- The app itself is `.tres`-only and never lists `.txt` notes, but the server
  reads, creates, edits, trashes and searches both. A `.txt` file is raw
  text: its body is the file, it has no title/tags/dates (its "title" is the
  file stem), and only its body can be edited.
- A `.txt` is edited only if its bytes are UTF-8 (a UTF-8 BOM is fine and is
  kept). Anything else (UTF-16 from Windows PowerShell 5.1's `>` or Notepad's
  "Unicode", Latin-1 / CP-1252) is read best-effort: `read_note` returns
  `editable: false`, its `encoding` and a `warning`, and `update_note` refuses
  it with `not_utf8`, because writing back a lossy decoding would replace the
  characters it could not decode. UTF-16 files are decoded by their BOM for
  reading and search. `move_note` and `delete_note` work on any bytes.
- `list_notes` and `search_notes` return one page: `limit` notes (default
  100, at most 500; a larger limit is capped), `count` on this page, `total`
  in all, and `next_cursor` while more remain. Pass it back as `cursor`, with
  the same other arguments, for the next page; a cursor that doesn't decode
  is refused with `invalid_arguments`. Pages are newest `modified` first, the
  path breaking ties (`.txt` notes have no date and come last). A cursor
  holds the sort key of its page's last note, not an offset, so a note
  created or trashed between calls doesn't shift or repeat the rest. A note
  edited mid-walk jumps to the front, behind the cursor, so the rest of that
  walk skips it. The folder tree comes with the first page only. A page of 100 notes
  is about 40 KB of JSON-RPC (`test_pagination`, 450 notes).
- `hash` is the SHA-256 of the file's bytes on disk. If the file changed since
  it was read (the app saved it, a sync tool replaced it), `update_note`,
  `delete_note` and `move_note` refuse with `isError: true`,
  `error.code = "conflict"` and the `current_hash`. Read again, re-apply, retry.
- `move_note` is one rename of the file, so the note's bytes and hash don't
  change: created date, stars, pins and tags stay, and no copy is left in the
  trash (deleting and recreating would lose all that). Moving into the folder
  it is already in returns `moved: false`. The open app picks the move up
  through its disk poll; when the user is typing in that note, see
  "Moving, renaming or deleting a note the app is about to autosave" under
  "Working alongside the open app".
- Writes are atomic: the note is saved to `<vault>/.ontomeme/tmp/` and renamed
  over the target, so nothing ever sees a half-written note. Before the rename
  the temp file is checked: a `.txt` is read back and compared byte for byte,
  a `.tres` is loaded back and every saved field compared with the note. If it
  was not written in full (disk full, quota, a network share), it is removed
  and the call fails with `write_failed`, leaving the note as it was. The check
  is needed even for a small note: its bytes sit in a buffer until the file
  is closed, so the write itself reports no error. Verified for `.txt` and
  `.tres`, for updates and creates, with large notes (`test_short_write`,
  server under `ulimit -f 100`) and small ones (`test_short_write_small`,
  `ulimit -f 1`, a 3,000-byte body).
- Notes are written with the app's own `ContentLayer` resource, so the app
  loads them unchanged.
- `create_note` and `update_note` return `warnings`: what the app would
  render wrong in the body as saved, each `{level, line, message}` (`line`
  is 1-based in the Markdown; a problem inside a ```` ```3d ```` block is on
  its opening fence line). `level` is `"error"` when the app would drop or
  break something (an unclosed fence, a quiz question without one `a*:`, a
  `learn:` or `next:` naming a missing note, a missing `model:` file) and
  `"warning"` for probable mistakes (a `[[link]]` to a missing note, an
  `objective:` not in the journey, a `[text](target)` that is not http,
  https or mailto, an image line Read view can't show). The write happens
  either way: a clean body returns `warnings: []`. The checks are `NoteLint`
  (`note_lint.gd`, at the project root so exports ship it), the same core
  `scripts/lint_notes.gd` prints, checked against the served vault: links
  against its `.tres` titles (case-insensitive; a note may link to itself),
  models against its `models/`, images against its `images/`, objectives
  against its `.ontomeme/journey.json`, each read fresh and only when the
  body needs it.
- `starred_at` and `pinned_at` (in `list_notes`, `read_note` and
  `search_notes` results) are when the user starred or pinned the note in the
  app, like `"2026-11-07T14:03:00"`, or `""` when it isn't (always `""` for
  a `.txt`). They are stored in
  the note's own `.tres`, so `update_note` keeps them. No tool sets them yet:
  that waits for v0.2's MCP scope.
- Tags are normalized the way the app shows them (`TagOps`: lowercase, no
  leading `#`, spaces as `-`): `create_note`/`update_note` store
  `["#Foo Bar", "foo bar", "X"]` as `["foo-bar", "x"]`, and `search_notes`'
  `tag` compares normalized forms. Agents should reuse `list_tags`' tags.
- `get_progress` and `get_journey` read `<vault>/.ontomeme/progress.json`
  and `journey.json` through `ProgressStore.read_progress` and
  `JourneyStore.read_journey`: the app's own parsing and sanitize pass, but
  nothing is written, created or copied, and the app's in-memory copies are
  left alone. A missing file gives an empty result (with only a `.tmp` left
  by an unfinished save, that is read). A file that doesn't parse or can't
  be opened is refused with `isError`, `error.code = "unreadable"` and its
  `path`; its bytes stay as they are (the app keeps a copy aside when it
  next opens the vault). Journey entries the sanitize pass left out are
  counted in `broken_entries`. The format is
  `skills/ontomeme-notes/references/objectives-protocol.md`.
- Tool failures come back as results with `isError: true` and
  `structuredContent.error = {code, message}`. Protocol mistakes (unknown
  method or tool, bad params, bad JSON) are JSON-RPC errors.
- `get_note_guide` exists because an MCP client has no Ontomeme skill: without
  it, a model writes plain Markdown and never uses 3D scenes or quizzes. The
  `initialize` instructions tell clients to call it first, and its result text
  is the guide's Markdown itself (not JSON). It reads `res://mcp/note_guide.md`,
  which every export preset packs (`mcp/*`). **When you edit
  `skills/ontomeme-notes/references/markup.md`, copy it over
  `mcp/note_guide.md` in the same commit**, or `tests/mcp_test.gd`
  fails. A topic is a list of the guide's headings (`GUIDE_TOPICS` in
  `vault_tools.gd`); renaming a heading there needs the matching update.
- `update_note` and `delete_note` carry `destructiveHint`, so clients ask the
  user before them with their own approval prompts. When the client can show
  Ontomeme's own prompt too (MCP elicitation), Ontomeme asks as well: see
  "Confirmations" below.

## Resources

Every note is also a read-only MCP resource, so a client can offer notes in
its own attach menu without a tool call.
`initialize` advertises `resources: {listChanged: false}`.

| Method | Returns |
|---|---|
| `resources/list` | the notes `list_notes` lists, in its order, 100 a page with `nextCursor`: `{uri, name (the title), description (the path), mimeType: "text/markdown"}` |
| `resources/templates/list` | `ontomeme://note/{path}` |
| `resources/read` | `{contents: [{uri, mimeType, text}]}`: the note's Markdown body (a `.txt` note's text). The raw `.tres` text stays `read_note` with `raw: true`. |

- A note's URI is `ontomeme://note/` + its vault path, percent-encoded with
  `/` as `%2F` (`ontomeme://note/Physics%2Fnote_waves.tres`). Reading also
  accepts unescaped slashes and lowercase escapes; `+` stays `+`.
- The decoded path goes through the same check as a tool's `path`: a URI
  outside the vault (`ontomeme://note/..%2Fx.tres`), into a hidden folder or
  `models/`, not ending in `.tres` / `.txt`, with a bad `%` escape, or not an
  `ontomeme://note/` URI is refused with JSON-RPC `-32602`. A note that isn't
  there is `-32002` (MCP's "resource not found") with the `uri` in `data`.
- `protocol.gd` routes `resources/*` only when the tools object has
  `list_resources`, `resource_templates` and `read_resource`; they report a
  failure as `{error: {code, message}}`, which `RESOURCE_ERRORS` maps to the
  JSON-RPC code. `vault_tools.gd` stays transport-free.

## Requests to the client

MCP lets the server ask the client things too (elicitation: a prompt the
client shows the user). `protocol.gd` supports that without changing how
the transport feeds it:

- `send_request(method, params, on_reply)` sends a request through the
  `outgoing(message)` signal and returns its id: `"s-1"`, `"s-2"`... Strings,
  so they can't collide with a client's ids. The client's response, fed to
  `handle()` like any message, goes to `on_reply` once, as the response
  message (`{id, result}` or `{id, error: {code, message}}`). A response to an
  id the server isn't waiting on is dropped, never answered.
- `tick(now_ms)` (the transport calls it every frame with
  `Time.get_ticks_msec()`) times out a request after `request_timeout_ms`
  (120 s): its `on_reply` gets error `-32001` and the client gets
  `notifications/cancelled` for it.
- A tool that has to wait returns `{"pending": true}` from `call_tool`. The
  `tools/call` then has no immediate reply (`handle()` returns null,
  `handle_line()` `""`); the tool keeps `proto.current_call_id` (the call
  being run) and later calls `proto.complete(id, result)`, which sends the
  response through `outgoing`. A tools object gets the protocol through an
  optional `attach_protocol(proto)`, called by `McpProtocol.new`.
- `notifications/cancelled` for a waiting call drops it: no response is sent
  (`complete()` returns false), and the requests it sent are withdrawn (the
  client gets `notifications/cancelled` for each; their `on_reply` is never
  called).
- `handle()` / `handle_line()` still return every immediate reply, so a
  caller that never connects `outgoing` works as before.
  `stdio_transport.gd` prints each `outgoing` message as one line from the
  main thread, in the order emitted (a request sent while a `tools/call` runs
  is written before anything that call answers). Tested in
  `test_server_requests` (`tests/mcp_test.gd`) with a fake client and a test
  tool.

## Confirmations

When the client declares the `elicitation` capability in `initialize` and
confirmations are on (the default), `update_note` and `delete_note` ask the
user before they write, with an `elicitation/create` request:

- `delete_note`: `Move "<title>" (<path>) to the trash?`
- `update_note`: `Save this change to "<title>" (<path>)?`, then what
  changes: `Title: "<old>" → "<new>"`, `Body: +N / -M lines` with the first
  three removed (`- `) and added (`+ `) lines (each cut to 100 characters,
  and a count of the rest), and `Tags: +new, -gone`. A `.txt` note's title
  is its file stem.
- Both ask for one required boolean, `confirm` (titled "Move to trash" or
  "Save the change").

The call waits for the answer (`{"pending": true}`, see "Requests to the
client"). Only `action: "accept"` with `confirm: true` writes, and only after
the hash is checked again: a note edited while the user decided is refused
with `conflict`, as if the change had been sent then. `decline`, `cancel`,
or `accept` without `confirm: true` is refused with `declined`; no answer
(the client returned an error, or 120 s passed) with `not_confirmed`. Either
way the note is untouched. If the client cancels the `tools/call`
meanwhile, nothing is written and nothing is answered. A request that is
refused anyway (bad path or arguments, stale hash, `not_utf8`) is refused at
once, without asking. `move_note` and `create_note` never ask: neither loses
anything.

A client without `elicitation` gets the old behaviour: no request, the
result at once, the client's own approval (`destructiveHint`) the only
prompt. The same when confirmations are off: pass `--confirm-writes=off`
after `--` (also `false`, `no`, `0`) or set `ONTOMEME_MCP_CONFIRM=0` (or
`off`, `false`, `no`). The flag wins over the variable; any other value keeps
confirmations on. `VaultTools.confirm_writes_setting(user_args, env_value)`
reads both, for whichever entry point starts the server, and sets
`confirm_writes`. The `initialize` instructions state the mode the client
gets (on with prompts, on without elicitation, or off), and the server logs
it to stderr. The app calling the tools directly (outside a `tools/call`)
is never asked. Tested in `test_elicitation` and, over real stdio, in
`test_stdio_elicitation` (`tests/mcp_test.gd`).

## Running it (development)

```
godot --headless --path . -- --mcp-stdio --vault=/path/to/vault
godot --headless --path . -s res://mcp/stdio_server.gd -- --vault=/path/to/vault
```

The first is the shipped entry (release templates ignore `-s`); a built app
takes the same arguments: `ontomeme --headless -- --mcp-stdio`. The vault is
`--vault=`, else `ONTOMEME_VAULT`, else the vault the app last used
(`user://vaults.json`, only read), else `~/Documents/Ontomeme` if it exists.
The server never creates or seeds a vault: with none it exits with code 2
and says why on stderr. Add `--confirm-writes=off` after `--` (or set
`ONTOMEME_MCP_CONFIRM=0`) to turn confirmations off. In MCP mode the app
builds no window, opens no startup vault, writes no `user://` files, and
logs (including the vault it serves, the confirmations mode, and each
client's `initialize`: the protocol version it asked for, the one answered,
its `clientInfo` and the names of its capabilities) go to stderr. The
project sets `application/run/print_header=false`, so no engine banner
reaches stdout and `--no-header` is no longer needed. The server exits when
stdin closes.

Godot copies everything a process prints, stdout and stderr, into its log
file, and every reply carries note text. By default that file is
`user://logs/godot.log`, the app's own log, which a bug report asks users to
attach; each start also rotated the app's log out (Godot keeps 5). So every
client config passes `--log-file user://logs/mcp.log` before `--`
(`DesktopConfig.LOG_ARGS`): the server gets a log of its own, replaced each
start, and the app's `godot.log` stays the app's. `tests/mcp_boot_test.gd`
checks it on this install's entry.

## Wiring into Claude Desktop

Claude Desktop starts MCP servers itself, from its config file
(`claude_desktop_config.json`: Settings → Developer → Edit Config).

**A shipped build** serves MCP through the boot switch: the command is the
Ontomeme app itself and the args are
`["--headless", "--log-file", "user://logs/mcp.log", "--", "--mcp-stdio"]`,
plus `"--vault=/path/to/vault"` to pick a vault other than the last used one.
The app's palette entry **Connect Claude Desktop…** shows that entry
for the running install (`OS.get_executable_path()`, the open vault as
`--vault=`, and `--path <project>` on an editor build), built with
`JSON.stringify` so Windows backslashes come out escaped, plus where the
config file lives and a Copy button. It doesn't write Claude's config file;
whether it should is a decision for later. `tests/mcp_boot_test.gd` checks
the entry per OS, that it matches the README's snippets for the same paths,
and runs this install's entry; `tests/ui_click_test.gd` opens it from the
palette with real clicks.
The user-facing steps, with one snippet per OS, are in the top-level
README's "Use with Claude Desktop (MCP)" section; `tests/readme_mcp_test.gd`
parses each snippet and runs its args for an `initialize` round trip, and
`scripts/check_mcp_release.sh` runs the same args on a real release export.

**From source** (contributors), with the editor binary and the dev entry:

```json
{
  "mcpServers": {
    "ontomeme": {
      "command": "/path/to/godot",
      "args": ["--headless", "--log-file", "user://logs/mcp.log", "--path", "/path/to/ontomeme",
               "-s", "res://mcp/stdio_server.gd", "--", "--vault=/path/to/vault"]
    }
  }
}
```

(`"args": ["--headless", "--log-file", "user://logs/mcp.log", "--path",
"/path/to/ontomeme", "--", "--mcp-stdio"]` does the same through the boot
switch.) Restart Claude Desktop; the Ontomeme
tools appear under the tools menu. Use absolute paths.

## Findings: can stdout carry only protocol bytes?

Measured on Linux with Godot 4.7.2 (editor binary and the official 4.7.2
Linux export templates). Commands were run from bash, with a probe script that
calls `print`, `printraw`, `printerr`, `push_warning`, `push_error` and
`print_rich`.

**Flags**

| Flags | stdout |
|---|---|
| `--headless` | `Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org`, an empty line, then the script's `print` output |
| `--headless --no-header` | only the script's `print` / `printraw` / `print_rich` output |
| `--headless --quiet` (with or without `--no-header`) | nothing at all: `print` and `printraw` are silenced too, so replies can't be written |

In every case `printerr`, `push_warning`, `push_error` and engine
`WARNING:` / `ERROR:` lines went to stderr. Opening `/dev/stdout` with
`FileAccess` as a way round `--quiet` fails (`ERR_FILE_CANT_OPEN`) when stdout
is a pipe.

So: **keep the banner off, never use `--quiet`, and never call `print()` on
the server path.** The project sets `application/run/print_header=false`, so
plain `--headless` is enough (`--no-header` still works). The tools don't
call the `VaultStore` functions that `print` (load/repair/save messages); they
load notes with `ResourceLoader` directly. In the editor, `print()` flushes
per line on a pipe (two prints 0.8 s apart arrived 0.8 s apart). **A release
build does not:** `application/run/flush_stdout_on_print` defaults to `false`
outside debug builds, so every reply sat in the stdout buffer until the
process exited and a client waiting for `initialize` hung (found by
`scripts/check_mcp_release.sh`). `project.godot` now sets it to `true`;
`tests/mcp_boot_test.gd` checks the setting, since the editor binary can't
show the difference.

**Release export.** In an exported Linux release build (embedded pck, official
template), `ontomeme --headless --no-header -- --mcp-stdio --vault=<dir>`
with a throwaway startup hook produced exactly three JSON-RPC lines for
initialize → tools/list → tools/call, nothing else on stdout, and exit code 0
on stdin EOF. Without `--no-header` the banner and an empty line came first,
as in the editor. A ping round trip including startup and exit took about
250 ms. (All requests were sent before stdin closed, which hid the buffering
described above.)

`scripts/check_mcp_release.sh` repeats this on every run with the real boot
switch: it exports the `Linux x86_64` preset into a temp dir, runs
`Ontomeme.x86_64 --headless -- --mcp-stdio --vault=<tmp>` in throwaway HOME
and XDG dirs, and `scripts/mcp_drive.py` drives it one request at a time
(initialize, tools/list, create, read, update, a stale update, delete), with
a UTF-8 and emoji title. It checks that stdout carries only JSON-RPC lines,
the note lands in the vault and then in `.trash/`, and the process exits 0
on stdin EOF within 20 s; then, as a control, that the same drive fails
without `--mcp-stdio`. `--binary <path>` checks a build you already have.

**Shipped builds can't use `-s`.** `godot --help` marks `-s/--script` and
`--main-loop` as "X: only in editor builds, and export templates compiled with
`disable_path_overrides=false`". The official release and debug templates
ignore `-s` and start the normal app. The release-build test above used a
startup hook instead: an autoload that sees `--mcp-stdio` in
`OS.get_cmdline_user_args()` and adds `stdio_transport.gd` to the tree.
Setting `application/run/main_scene` from that autoload's `_init` does **not**
stop the main scene from loading (verified with `--verbose`: `note.tscn` was
still loaded). A shipped headless mode therefore needs the app's own startup
code to skip building the main window when `--mcp-stdio` is passed. That is
now `boot.tscn` (the main scene): it starts `serve.gd` for `--mcp-stdio` and
otherwise changes to `note.tscn`; the VaultStore autoload skips the startup
vault under `--mcp-stdio`.

**Reading stdin.**

- Every stdin read blocks the calling thread, so reading happens on a worker
  thread. With a reader thread the main loop kept running (about 140 frames
  per second, frame counters kept rising while the thread waited on stdin).
- `OS.read_string_from_stdin(n)` returns one line, newline stripped, as soon as
  the line arrives. But it returns `""` for both a blank line and EOF, and it
  splits lines longer than `n` without saying so.
- `OS.read_buffer_from_stdin(n)` works like `fread`: it blocks until it has `n`
  bytes or reaches EOF. With `n = 65536`, two short requests sent 1 s apart
  both arrived only at EOF, about 2.9 s later. A client waiting for a reply
  would hang.
- `OS.read_buffer_from_stdin(1)` in a loop returns each byte as it arrives
  (requests sent 1 s apart arrived at 0.9 s and 1.9 s), keeps blank lines,
  joins long lines correctly, and an empty result means EOF. A 1 MB line took
  about 80 ms. The transport uses this.
- `OS.get_stdin_type()` reports `STD_HANDLE_PIPE` (3) for a pipe.

**Not verified yet:** Windows and macOS (stdout from a GUI-subsystem
`.exe`, `read_buffer_from_stdin` on Windows pipes, rename-over-existing on
Windows). The top-level README's Mac and Windows snippets follow the Linux
result and still need a run on a real machine (a GitHub runner job for
`scripts/mcp_drive.py` needs `release.yml`). MCP mode no longer loads the
main scene, so what it prints on a large vault no longer matters here.

## Checked with a real client: Claude Code

Claude Desktop isn't made for Linux, but Claude Code is an MCP client over
stdio too. `scripts/check_mcp_claude_code.sh` seeds a temp vault with two
notes, gives `claude -p` a one-run MCP config (`--mcp-config` with
`--strict-mcp-config`; nothing is registered, `~/.claude.json` is never
edited) that starts this checkout with `--headless --path <repo> --
--mcp-stdio --vault=<tmp>`, and asks Claude to list the notes, append a line
to one and move the other to the trash. Claude gets only the five Ontomeme
tools it needs and no built-in tools. The script then checks the disk (the
line is in the note and its SHA-256 changed; the other note is in `.trash/`,
byte-identical; no other file) and reads the server's stderr out of Claude
Code's debug log. It spends a little of your Claude quota (about $0.03 with
the default `CHECK_MODEL=sonnet`), so it is not part of `tests/run_all.sh`.

First run, 2026-11-07, Claude Code 2.1.319: list, two reads, update and
delete in 6 turns, all on disk as asked. The client's `initialize` asked for
protocol `2025-11-25` with `clientInfo`
`{"name":"claude-code","title":"Claude Code","version":"2.1.319","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"}`
and the `roots` capability among others. The server answered `2025-06-18`
(the newest it then spoke) and Claude Code took it: its debug log says
`"protocolEra":"legacy","negotiatedProtocolVersion":"2025-06-18"`. Claude
Code read the tool schemas, the `structuredContent` results and the hashes
without trouble. With `2025-11-25` supported (below), the same run
negotiated `2025-11-25` on both sides.

## Protocol versions

`protocol.gd` accepts `2025-11-25` (the latest), `2025-06-18`, `2025-03-26`
and `2024-11-05`; for any other version it answers with its latest and the
client decides. Checked against the spec's revision list on 2026-11-07:

- **`2025-11-25` is supported**, since it adds nothing this server must do
  and doesn't. Its changes are HTTP authorization (not stdio), optional
  icons and experimental tasks (only when declared), client-side features
  (new kinds of questions a server may put to the user through the client,
  tool calls in sampling),
  SHOULDs on tool names (ours are lowercase ASCII with `_`), JSON Schema
  2020-12 as the default dialect (our `inputSchema`s are plain 2020-12
  objects), stderr allowed for any logging (ours), and input validation
  errors as tool results (ours return `isError` with `invalid_arguments`;
  only arguments that aren't an object, which fail the `CallToolRequest`
  schema itself, are a protocol error, as the spec lists).
- **`2026-07-28` (current) is not**: it removes the `initialize` handshake,
  so every request carries its version in `_meta`, and servers must
  implement `server/discover`, return `resultType` on every result and
  `ttlMs`/`cacheScope` on list results. A client of both eras probes stdio
  with `server/discover` first and falls back to `initialize` on any error
  that isn't a modern one (codes -32020 to -32099); this server answers
  that probe with -32002 (not initialized), so such a client falls back.
  Claude Code 2.1.319 sent `initialize` directly.

Each `initialize` is logged to stderr: the version asked for, the one
answered, `clientInfo` and the capability names. `McpProtocol` itself does
no I/O; it emits `client_initialized` and `serve.gd` prints the line.

## Working alongside the open app

Neither side stores a hash inside the note files, so both hash the bytes on
demand and keep the comparison in memory:

- **The app** records each note file's SHA-256 when it reads it
  (`VaultStore._hashes`) and updates it after every save. `save_note()`
  re-hashes the file first; if it no longer matches the record — an edit by
  the server, a sync tool, another editor — the app keeps the disk version and
  saves its own as `"<title> (conflict copy)"` instead of overwriting it
  (verified in `tests/conflict_test.gd`). The 1.5 s disk poll reloads outside
  edits before that, unless an autosave is pending (the poll is skipped while
  the user is typing).
- **The server** returns the file's SHA-256 from `read_note` / `create_note`
  and re-checks it before every `update_note` / `delete_note` / `move_note`;
  a mismatch is refused with `conflict` (verified in `tests/mcp_test.gd`).

So a server edit and an app edit of the same note both survive: the app ends
up with the note plus a conflict copy, and the server is told to re-read. One
limit: the app's record is in memory — restarting the app re-reads the disk
and forgets what was there before, so a stale pre-restart copy cannot conflict
with anything. `.txt` notes are invisible to the app (it is .tres-only), so
only the server's hash gate covers them.

**Moving, renaming or deleting a note the app is about to autosave.** The
app skips its disk poll while an autosave is pending (the save fires 0.8 s
after the last keystroke; the poll runs every 1.5 s). If `move_note`,
`delete_note` or a title change in `update_note` takes the file away in that
window, the autosave finds the file it last read gone and treats that as an
outside change: it doesn't write the old path again, but saves the user's
typing as `"<title> (conflict copy)"` (in the note's folder, or at the top
level when that folder is gone too), opens it and says the note was renamed
or deleted on disk (verified in `tests/conflict_test.gd`). Nothing typed is
lost, and no second note with the old title appears; the moved or renamed
note holds the version from before that typing. After moving, renaming or
deleting a note the user may be typing in, check `list_notes` for a
conflict copy.

A title change in `update_note` also rewrites `.ontomeme/progress.json` and
`journey.json`. The app notices: `ProgressStore` and `JourneyStore` remember
each file's SHA-256 as they last read or wrote it, the disk poll re-reads a
file whose hash changed (the sidebar's ✓ / ● marks and the Journey tab
follow), and the app's own progress and Journey writes re-read a changed
file before they write, so they don't put the old keys back.
