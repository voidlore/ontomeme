extends SceneTree
## The app and Claude on one vault at the same time: note.tscn has the vault
## open while a separate MCP server process (started the shipped way, through
## the boot switch: `-- --mcp-stdio --vault=<this vault>`) lists, reads,
## edits and trashes notes over stdio, and the app shows each change.
## The server gets throwaway XDG dirs, so it never sees the user's vaults.
##   godot --headless --path . -s res://tests/mcp_live_test.gd

const TestVault = preload("res://tests/test_vault.gd")

const CLIENT_INFO: Dictionary = {"name": "live-test", "version": "1"}
const REPLY_TIMEOUT_MS: int = 10000
const RUNTIME_LIMIT_MS: int = 60000

var fails: int = 0
var V: String = ""
var app: Control = null
## OS.execute_with_pipe() of the server: {stdio, stderr, pid}.
var server: Dictionary = {}
## Server stdout read so far but not yet a whole line.
var _out := PackedByteArray()
## False once any server stdout line is not a JSON-RPC message.
var _stdout_clean: bool = true
var _next_id: int = 1
var _home: String = ""


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func _init() -> void:
	var started: int = Time.get_ticks_msec()
	JourneyStore.file_override = "user://test_journey_mcp_live.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_mcp_live.json"   # never touch real progress
	ProgressStore.reset()
	_home = ProjectSettings.globalize_path("user://test-mcp-live-home/")
	TestVault.remove_tree(_home)
	var user_before: Dictionary = user_files()
	V = TestVault.open("mcp-live", false)
	seed_notes()
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.check_disk_changes()   # absorb the app's own startup work

	start_server()
	check(not server.is_empty(), "the server process started through the boot switch")
	if not server.is_empty():
		await test_initialize()
		await test_list_matches_app()
		await test_create_seen_by_watcher()
		await test_update_open_note()
		await test_app_save_beats_stale_read()
		await test_delete_open_note()
		await test_same_second_create_update()
		await test_server_exit()

	app.queue_free()
	await frames(2)
	TestVault.remove_tree(V)
	TestVault.remove_tree(_home)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	var stray: Array[String] = changed_user_files(user_before, user_files())
	check(stray.is_empty(), "nothing under user:// was written besides the test vault and overrides %s" % [stray])
	var ms: int = Time.get_ticks_msec() - started
	check(ms < RUNTIME_LIMIT_MS, "the live run takes under %d s (%.1f s)" % [RUNTIME_LIMIT_MS / 1000, ms / 1000.0])
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


# ── The vault and the app ───────────────────────────────────────────────────

## A few notes the app writes itself, one in a folder, a second apart so the
## sidebar order is fixed.
func seed_notes() -> void:
	VaultStore.create_folder("Physics")
	var specs: Array = [["Waves", "Physics", "λ = v / f"], ["Groceries", "", "- milk"], ["Ideas", "", "# Ideas\nmore 3D"]]
	for s in specs:
		var n: ContentLayer = VaultStore.create_note(s[0], s[1])
		n.raw_text = s[2]
		VaultStore.save_note(n)
	VaultStore.refresh_note_list()


func note_titled(title: String) -> ContentLayer:
	var i: int = VaultStore.get_note_index(title)
	return VaultStore.note_list[i] if i >= 0 else null


## True when the app's sidebar shows a row for the note titled `title`.
func in_sidebar(title: String) -> bool:
	for note in app._note_buttons:
		var btn: Button = app._note_buttons[note]
		if is_instance_valid(btn) and btn.text == title and note.title == title:
			return true
	return false


func app_text() -> String:
	return app.raw_text_layer.text


func stat(rel: String) -> Array:
	return [FileAccess.get_modified_time(V + rel), FileAccess.get_size(V + rel)]


## Sleep until just past the next whole second, so the writes that follow share
## one mtime second (mtimes are whole seconds).
func next_second() -> void:
	var t: float = Time.get_unix_time_from_system()
	OS.delay_msec(int((floorf(t) + 1.0 - t) * 1000.0) + 20)


# ── The MCP client: one server process, one JSON-RPC line each way ─────────

## `<godot> --headless --path <res> -- --mcp-stdio --vault=<V>`, the way Claude
## Desktop starts a shipped build, with XDG dirs under user://test-mcp-live-home/.
func start_server() -> void:
	for d in ["config", "data"]:
		DirAccess.make_dir_recursive_absolute(_home + d)
	var env: Dictionary = {"XDG_CONFIG_HOME": _home + "config", "XDG_DATA_HOME": _home + "data"}
	var saved: Dictionary = {}
	for k in env:
		saved[k] = OS.get_environment(k) if OS.has_environment(k) else null
		OS.set_environment(k, env[k])
	OS.unset_environment("ONTOMEME_VAULT")
	var args: PackedStringArray = ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--", "--mcp-stdio", "--vault=" + V]
	server = OS.execute_with_pipe(OS.get_executable_path(), args, false)
	for k in saved:
		if saved[k] == null:
			OS.unset_environment(k)
		else:
			OS.set_environment(k, saved[k])


## Send one request and wait for its reply (the app keeps running meanwhile).
## The reply Dictionary, or {} on timeout.
func rpc(method: String, params: Dictionary = {}) -> Dictionary:
	var id: int = _next_id
	_next_id += 1
	var msg: Dictionary = {"jsonrpc": "2.0", "id": id, "method": method}
	if not params.is_empty():
		msg["params"] = params
	send(msg)
	var deadline: int = Time.get_ticks_msec() + REPLY_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline and OS.is_process_running(server.pid):
		for line in read_lines():
			var reply: Variant = JSON.parse_string(line)
			if not (reply is Dictionary) or reply.get("jsonrpc") != "2.0":
				_stdout_clean = false
				print("      not a JSON-RPC line: ", line.c_escape().left(200))
			elif int(reply.get("id", -1)) == id:
				return reply
		await create_timer(0.01).timeout
	print("      no reply to ", method, " #", id)
	return {}


func send(msg: Dictionary) -> void:
	var io: FileAccess = server.stdio
	io.store_string(JSON.stringify(msg) + "\n")
	io.flush()


## Whole lines the server has written to stdout since the last call.
func read_lines() -> Array[String]:
	var lines: Array[String] = []
	_out.append_array((server.stdio as FileAccess).get_buffer(65536))
	var nl: int = _out.find(10)
	while nl >= 0:
		lines.append(_out.slice(0, nl).get_string_from_utf8())
		_out = _out.slice(nl + 1)
		nl = _out.find(10)
	return lines


## tools/call: the tool's structuredContent, plus "_isError".
func tool(name: String, args: Dictionary) -> Dictionary:
	var reply: Dictionary = await rpc("tools/call", {"name": name, "arguments": args})
	var result: Dictionary = reply.get("result", {})
	var out: Dictionary = result.get("structuredContent", {}).duplicate()
	out["_isError"] = result.get("isError", true)
	return out


func err_code(r: Dictionary) -> String:
	return str(r.get("error", {}).get("code", "")) if r.get("_isError", false) else ""


# ── Tests ───────────────────────────────────────────────────────────────────

func test_initialize() -> void:
	var r: Dictionary = await rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": CLIENT_INFO})
	check(r.has("result") and str(r.result.get("instructions", "")).contains(V.trim_suffix("/")), "initialize: the server serves the vault the app has open")
	send({"jsonrpc": "2.0", "method": "notifications/initialized"})


## Claude sees exactly the notes the app lists.
func test_list_matches_app() -> void:
	var r: Dictionary = await tool("list_notes", {})
	var titles: Array = []
	for n in r.get("notes", []):
		titles.append(n.title)
	titles.sort()
	var app_titles: Array = []
	for n in VaultStore.note_list:
		app_titles.append(n.title)
	app_titles.sort()
	check(int(r.get("count", -1)) == VaultStore.note_list.size() and VaultStore.note_list.size() == 3, "list_notes count == the app's note_list size (%s == %d)" % [r.get("count"), VaultStore.note_list.size()])
	check(titles == app_titles, "…with the same titles %s" % [titles])


## Claude creates a note; the app's own 1.5 s watcher (no direct
## check_disk_changes call) puts it in the sidebar.
func test_create_seen_by_watcher() -> void:
	check(app._auto_save_timer.is_stopped(), "(no autosave pending, so the watcher polls)")
	app.status_label.text = "quiet"
	var c: Dictionary = await tool("create_note", {"title": "From Claude", "markdown": "Written over MCP ✓"})
	check(not c._isError and FileAccess.file_exists(V + "note_from_claude.tres"), "create_note wrote note_from_claude.tres")
	var t0: int = Time.get_ticks_msec()
	var limit_ms: int = int(app.WATCH_INTERVAL * 1000.0) * 2 + 1000
	while not in_sidebar("From Claude") and Time.get_ticks_msec() - t0 < limit_ms:
		await create_timer(0.1).timeout
	var waited: float = (Time.get_ticks_msec() - t0) / 1000.0
	check(note_titled("From Claude") != null, "the app's watcher loaded the new note into VaultStore.note_list (%.1f s)" % waited)
	check(in_sidebar("From Claude"), "…and the sidebar shows a row for it")
	check(app.status_label.text.contains("changed on disk"), "…and the status bar says the vault changed on disk (%s)" % app.status_label.text)


## The note is open in the app; Claude reads it and replaces the body.
func test_update_open_note() -> void:
	app.open_note_by_title("From Claude")
	check(app.current_note != null and app.current_note.title == "From Claude" and app_text() == "Written over MCP ✓", "(the app opened Claude's note)")
	var rd: Dictionary = await tool("read_note", {"path": "note_from_claude.tres"})
	check(not rd._isError and rd.get("markdown") == app_text(), "read_note returns what the app shows")
	var body: String = "Claude's new body\n- a list item\n- **bold** 日本"
	var u: Dictionary = await tool("update_note", {"path": "note_from_claude.tres", "hash": rd.get("hash", ""), "markdown": body})
	check(not u._isError, "update_note with the read hash succeeds")
	app.status_label.text = "quiet"
	app.check_disk_changes()
	await frames(2)
	check(app_text() == body, "the open note shows Claude's body (%s)" % app_text().c_escape())
	check(app.current_note != null and app.current_note.title == "From Claude", "…and stays the open note")
	check(app.status_label.text.contains("changed on disk"), "…and the status bar says the vault changed on disk (%s)" % app.status_label.text)


## Claude reads, the user types and the app autosaves, then Claude writes with
## the stale hash: refused with "conflict", and the user's words stay.
func test_app_save_beats_stale_read() -> void:
	var rd: Dictionary = await tool("read_note", {"path": "note_from_claude.tres"})
	var typed: String = app_text() + "\nI typed this in the app"
	var editor: TextEdit = app.raw_text_layer
	editor.set_caret_line(editor.get_line_count() - 1)
	editor.set_caret_column(editor.get_line(editor.get_line_count() - 1).length())
	editor.insert_text_at_caret("\nI typed this in the app")   # an edit, like typing
	await frames(2)   # TextEdit emits text_changed deferred
	check(app_text() == typed and not app._auto_save_timer.is_stopped(), "(typing started the autosave timer)")
	var t0: int = Time.get_ticks_msec()
	while not app._auto_save_timer.is_stopped() and Time.get_ticks_msec() - t0 < 3000:
		await create_timer(0.05).timeout
	check(FileAccess.get_file_as_string(V + "note_from_claude.tres").contains("I typed this in the app"), "the app autosaved the typed text")
	var notes_before: int = VaultStore.note_list.size()
	var u: Dictionary = await tool("update_note", {"path": "note_from_claude.tres", "hash": rd.get("hash", ""), "markdown": "Claude's stale rewrite"})
	check(err_code(u) == "conflict", "update_note with the hash from before the app's save returns code 'conflict' (%s)" % err_code(u))
	check(str(u.get("error", {}).get("current_hash", "")) == FileAccess.get_sha256(V + "note_from_claude.tres"), "…and names the current hash")
	app.check_disk_changes()
	await frames(2)
	check(app_text() == typed, "the app's text is intact")
	check(FileAccess.get_file_as_string(V + "note_from_claude.tres").contains("I typed this in the app"), "…and so is the file")
	check(VaultStore.note_list.size() == notes_before and note_titled("From Claude (conflict copy)") == null, "…with no conflict copy")


## Claude trashes the note the app has open.
func test_delete_open_note() -> void:
	app.open_note_by_title("From Claude")
	var rd: Dictionary = await tool("read_note", {"path": "note_from_claude.tres"})
	var d: Dictionary = await tool("delete_note", {"path": "note_from_claude.tres", "hash": rd.get("hash", "")})
	check(not d._isError and d.get("trashed_to") == ".trash/note_from_claude.tres", "delete_note moves it to .trash/ (%s)" % d.get("trashed_to"))
	check(FileAccess.file_exists(V + ".trash/note_from_claude.tres") and not FileAccess.file_exists(V + "note_from_claude.tres"), "the file sits in <vault>/.trash/, not at its old path")
	app.check_disk_changes()
	await frames(2)
	check(not in_sidebar("From Claude") and note_titled("From Claude") == null, "the note leaves the sidebar")
	check(app.current_note != null and app.current_note.title != "From Claude", "the editor moves to another note (%s)" % (app.current_note.title if app.current_note else "none"))
	check(app.current_note != null and app_text() == app.current_note.raw_text, "…and shows that note's text")
	check(VaultStore.note_list.size() == 3, "the app lists the 3 notes it started with (%d)" % VaultStore.note_list.size())


## Regression for the watcher fix: Claude creates a note and updates it within
## one second (same mtime, same size); the open app shows the second body.
func test_same_second_create_update() -> void:
	var ok: bool = false
	for attempt in range(3):   # a slow machine can cross a second boundary; retry
		var title: String = "Quick %d" % attempt
		next_second()
		var c: Dictionary = await tool("create_note", {"title": title, "markdown": "v1"})
		var st1: Array = stat(str(c.get("path", "")))
		app.check_disk_changes()
		app.open_note_by_title(title)
		var opened: bool = app.current_note != null and app.current_note.title == title and app_text() == "v1"
		var u: Dictionary = await tool("update_note", {"path": c.get("path", ""), "hash": c.get("hash", ""), "markdown": "v2"})
		if u._isError or not opened or stat(str(c.get("path", ""))) != st1:
			print("      (attempt %d: opened %s, update error %s, crossed a second %s; retrying)" % [attempt, opened, err_code(u), stat(str(c.get("path", ""))) != st1])
			continue
		check(app._auto_save_timer.is_stopped(), "(no autosave pending, so the watcher polls)")
		app.check_disk_changes()
		await frames(2)
		check(app_text() == "v2", "a create then update in one second (same mtime and size) shows the second body (%s)" % app_text())
		ok = true
		break
	check(ok, "(a same-second run happened)")


func test_server_exit() -> void:
	var io: FileAccess = server.stdio
	io.close()   # stdin EOF: the server quits by itself
	var deadline: int = Time.get_ticks_msec() + 10000
	while OS.is_process_running(server.pid) and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	var exited: bool = not OS.is_process_running(server.pid)
	if not exited:
		OS.kill(server.pid)
	check(exited and OS.get_process_exit_code(server.pid) == 0, "the server exits with code 0 on stdin EOF")
	check(_stdout_clean and _out.is_empty(), "every server stdout line was a JSON-RPC message")
	var err: String = ""
	if server.stderr is FileAccess:
		err = (server.stderr as FileAccess).get_buffer(1 << 20).get_string_from_utf8()
		(server.stderr as FileAccess).close()
	check(err.contains("[ontomeme-mcp] serving vault " + V.trim_suffix("/")), "the server's stderr names the vault it served")


# ── user:// stays clean ────────────────────────────────────────────────────

## Every file under user://, relative path -> "mtime size". The engine's own
## log folder is left out.
func user_files(rel: String = "") -> Dictionary:
	var out: Dictionary = {}
	var base: String = OS.get_user_data_dir().path_join(rel)
	var d := DirAccess.open(base)
	if d == null:
		return out
	d.include_hidden = true
	for f in d.get_files():
		var p: String = rel.path_join(f) if rel != "" else f
		out[p] = "%d %d" % [FileAccess.get_modified_time(base.path_join(f)), FileAccess.get_size(base.path_join(f))]
	for sub in d.get_directories():
		if rel == "" and sub == "logs":
			continue
		out.merge(user_files(rel.path_join(sub) if rel != "" else sub))
	return out


## Files added or changed between two user_files() snapshots, other than the
## ones this test owns (its vault, the server's home, the store overrides).
func changed_user_files(before: Dictionary, after: Dictionary) -> Array[String]:
	var owned: Array[String] = ["test-vault-mcp-live/", "test-mcp-live-home/", "test_journey_mcp_live.json", "test_progress_mcp_live.json"]
	var out: Array[String] = []
	for p in after:
		if before.get(p) == after[p]:
			continue
		var mine: bool = false
		for o in owned:
			mine = mine or p == o or p.begins_with(o)
		if not mine:
			out.append(p)
	return out
