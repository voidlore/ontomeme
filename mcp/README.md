# Ontomeme MCP server

Lets Claude (or any MCP client) list, read, search, create, edit and delete
the notes in an Ontomeme vault.

## Files

| File | What it is |
|---|---|
| `protocol.gd` | JSON-RPC 2.0 + MCP lifecycle (`initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`). Pure: `handle(message) -> response or null`. No I/O. |
| `vault_tools.gd` | The six tools, over one vault folder. No UI, no stdio. |
| `stdio_transport.gd` | A Node that reads stdin on a thread and writes replies to stdout, one JSON message per line. |
| `stdio_server.gd` | `-s` entry point for development (editor builds only; see below). |

The protocol and tools don't depend on stdio or on the app's window, so the
same code can run headless (launched by the client) or inside the running app
behind a bridge. Which one ships is still open.

## Tools

| Tool | Does | Notes |
|---|---|---|
| `list_notes` | notes (path, title, folder, tags, dates) and folders | optional `folder` |
| `read_note` | title, tags, dates, Markdown body, `hash` | `raw: true` adds the `.tres` text |
| `create_note` | new note named `note_<title>.tres`, like the app | refuses if the file exists |
| `update_note` | replace title / body / tags | needs `hash`; `destructiveHint` |
| `delete_note` | moves the file to `<vault>/.trash/<path>` | needs `hash`; `destructiveHint`; never hard-deletes |
| `search_notes` | `query` (title or body), `title`, `tag`, `folder`, `limit` | case-insensitive, filters AND together |

- A note is addressed by its path inside the vault (`Physics/note_waves.tres`).
  Paths outside the vault, absolute paths and hidden folders are refused.
- `hash` is the SHA-256 of the file's bytes on disk. If the file changed since
  it was read (the app saved it, a sync tool replaced it), `update_note` and
  `delete_note` refuse with `isError: true`, `error.code = "conflict"` and the
  `current_hash`. Read again, re-apply, retry.
- Writes are atomic: the note is saved to `<vault>/.ontomeme/tmp/` and renamed
  over the target, so nothing ever sees a half-written note.
- Notes are written with the app's own `ContentLayer` resource, so the app
  loads them unchanged.
- Tool failures come back as results with `isError: true` and
  `structuredContent.error = {code, message}`. Protocol mistakes (unknown
  method or tool, bad params, bad JSON) are JSON-RPC errors.
- Confirmations never go over stdio (it carries the protocol). Clients ask the
  user before `destructiveHint` tools using their own approval prompts.

## Running it (development)

```
godot --headless --no-header --path . -s res://mcp/stdio_server.gd -- --vault=/path/to/vault
```

The vault can also come from `ONTOMEME_VAULT`. Logs go to stderr. The server
exits when stdin closes.

## Wiring into Claude Desktop

Claude Desktop starts MCP servers itself. In its config file
(`claude_desktop_config.json`: Settings → Developer → Edit Config):

```json
{
  "mcpServers": {
    "ontomeme": {
      "command": "/path/to/godot",
      "args": ["--headless", "--no-header", "--path", "/path/to/ontomeme",
               "-s", "res://mcp/stdio_server.gd", "--", "--vault=/path/to/vault"]
    }
  }
}
```

Restart Claude Desktop; the Ontomeme tools appear under the tools menu.
Use absolute paths. With a shipped build the command will be the Ontomeme app
itself and the args will change (see "Shipped builds" below); that entry
point is not wired yet.

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

So: **use `--headless --no-header`, never `--quiet`, and never call `print()`
on the server path.** The tools don't call the `VaultStore` functions that
`print` (load/repair/save messages); they load notes with `ResourceLoader`
directly. `print()` flushes per line on a pipe (two prints 0.8 s apart arrived
0.8 s apart), so replies aren't held in a buffer.

**Release export.** In an exported Linux release build (embedded pck, official
template), `ontomeme --headless --no-header -- --mcp-stdio --vault=<dir>`
with a throwaway startup hook produced exactly three JSON-RPC lines for
initialize → tools/list → tools/call, nothing else on stdout, and exit code 0
on stdin EOF. Without `--no-header` the banner and an empty line came first,
as in the editor. A ping round trip including startup and exit took about
250 ms.

**Shipped builds can't use `-s`.** `godot --help` marks `-s/--script` and
`--main-loop` as "X: only in editor builds, and export templates compiled with
`disable_path_overrides=false`". The official release and debug templates
ignore `-s` and start the normal app. The release-build test above used a
startup hook instead: an autoload that sees `--mcp-stdio` in
`OS.get_cmdline_user_args()` and adds `stdio_transport.gd` to the tree.
Setting `application/run/main_scene` from that autoload's `_init` does **not**
stop the main scene from loading (verified with `--verbose`: `note.tscn` was
still loaded). A shipped headless mode therefore needs the app's own startup
code to skip building the main window when `--mcp-stdio` is passed (for
example a small boot scene that picks the window or the MCP transport).

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
Windows), and what the app's main scene prints if it runs headless with a
large vault.

## Working alongside the open app

The app keeps no hash of its own inside the `.tres` files.
`conflict_resolver.gd` computes `String.hash()` of the file text when asked,
so there's nothing for the server to keep in step. But the app's own check
doesn't protect against outside edits yet: `VaultStore.save_note()` hashes the
file just before it compares, so the comparison always matches, and
`pre_save()` looks at a path built from the title rather than the note's real
file. If the app has a note open and saves it after the server changed that
note, the server's change is overwritten without a conflict copy (verified).
The app's 1.5 s disk poll reloads the note before that only if no autosave is
pending (it skips the poll while the user is typing). The fix belongs in the app: remember the hash read at load and
compare against that on save.
