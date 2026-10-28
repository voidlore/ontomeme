extends SceneTree
## MCP server core: protocol lifecycle, every vault tool, hash-conflict
## refusals, trash on delete, and an end-to-end stdio run in a subprocess.
##   godot --headless --path . -s res://tests/mcp_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const McpProtocol = preload("res://mcp/protocol.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")

var fails: int = 0
var _next_id: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func req(proto: RefCounted, method: String, params: Variant = null) -> Variant:
	_next_id += 1
	var m: Dictionary = {"jsonrpc": "2.0", "id": _next_id, "method": method}
	if params != null:
		m["params"] = params
	return proto.handle(m)


## tools/call → the CallToolResult (or {} if the call failed at protocol level).
func call_tool(proto: RefCounted, name: String, args: Dictionary) -> Dictionary:
	var r: Variant = req(proto, "tools/call", {"name": name, "arguments": args})
	return r.result if r is Dictionary and r.has("result") else {}


func data(result: Dictionary) -> Dictionary:
	return result.get("structuredContent", {})


func err_code(result: Dictionary) -> String:
	return str(data(result).get("error", {}).get("code", "")) if result.get("isError", false) else ""


func _init() -> void:
	ProgressStore.file_override = "user://test_progress_mcp.json"   # never touch real progress
	JourneyStore.file_override = "user://test_journey_mcp.json"     # never touch the real journey
	var V: String = TestVault.open("mcp")
	test_protocol(V)
	test_tools(V)
	test_app_compat(V)
	await test_stdio_e2e()
	for f in [ProgressStore.file_override, JourneyStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	TestVault.remove_tree(V)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)


# ── Protocol ────────────────────────────────────────────────────────────────

func test_protocol(V: String) -> void:
	var p: RefCounted = McpProtocol.new(VaultTools.new(V))
	var r: Variant = req(p, "tools/list")
	check(r.error.code == McpProtocol.NOT_INITIALIZED, "tools/list before initialize is refused")
	r = req(p, "ping")
	check(r.has("result") and r.result.is_empty(), "ping works before initialize")

	r = req(p, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}})
	check(r.result.protocolVersion == "2025-06-18", "initialize: 2025-06-18 accepted")
	check(r.result.capabilities.has("tools") and r.result.serverInfo.name == "ontomeme", "initialize: tools capability + serverInfo")
	check(r.id is int and r.id == _next_id, "integer id echoed as an integer")
	check(JSON.stringify(r).contains("\"id\":%d," % _next_id), "integer id serialised without .0")
	var older: Variant = McpProtocol.new(null).handle({"jsonrpc": "2.0", "id": "a", "method": "initialize", "params": {"protocolVersion": "2025-03-26"}})
	check(older.id == "a" and older.result.protocolVersion == "2025-03-26", "initialize: a supported older version is accepted")
	var unknown: Variant = McpProtocol.new(null).handle({"jsonrpc": "2.0", "id": 9, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}})
	check(unknown.result.protocolVersion == McpProtocol.LATEST_VERSION, "initialize: unknown version → server offers its latest")
	check(McpProtocol.new(null).handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}).error.code == McpProtocol.INVALID_PARAMS, "initialize without protocolVersion → -32602")

	check(p.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}) == null and p.client_ready, "notifications/initialized: no reply, client marked ready")
	check(p.handle({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 1}}) == null, "other notifications: no reply")
	check(p.handle({"jsonrpc": "2.0", "id": 99, "result": {}}) == null, "a response from the client is not answered")

	r = req(p, "tools/list")
	var names: Array = r.result.tools.map(func(t): return t.name)
	check(names.size() == 6 and "read_note" in names and "search_notes" in names, "tools/list: the six tools")
	var by_name: Dictionary = {}
	for t in r.result.tools:
		by_name[t.name] = t
		check(t.inputSchema.type == "object", "tool %s has an object inputSchema" % t.name)
	check(by_name.update_note.annotations.destructiveHint == true and by_name.delete_note.annotations.destructiveHint == true, "update_note + delete_note carry destructiveHint")
	check(by_name.read_note.annotations.readOnlyHint == true and by_name.create_note.annotations.destructiveHint == false, "read tools are readOnly; create is not destructive")
	check(by_name.update_note.inputSchema.required.has("hash") and by_name.delete_note.inputSchema.required.has("hash"), "update/delete require a hash in their schema")

	check(req(p, "nope/nothing").error.code == McpProtocol.METHOD_NOT_FOUND, "unknown method → -32601")
	check(req(p, "tools/call", {"name": "no_such_tool", "arguments": {}}).error.code == McpProtocol.INVALID_PARAMS, "unknown tool → -32602")
	check(req(p, "tools/call", {"name": "read_note", "arguments": "x"}).error.code == McpProtocol.INVALID_PARAMS, "non-object arguments → -32602")
	check(p.handle({"jsonrpc": "1.0", "id": 5, "method": "ping"}).error.code == McpProtocol.INVALID_REQUEST, "wrong jsonrpc version → -32600")
	check(p.handle({"jsonrpc": "2.0", "id": null, "method": "ping"}).error.code == McpProtocol.INVALID_REQUEST, "null id → -32600")
	check(p.handle([{"jsonrpc": "2.0", "id": 1, "method": "ping"}]).error.code == McpProtocol.INVALID_REQUEST, "batch → -32600")
	var pe: Dictionary = JSON.parse_string(p.handle_line("{not json"))
	check(pe.error.code == McpProtocol.PARSE_ERROR and pe.id == null, "bad JSON → -32700 with id null")
	check(p.handle_line("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}") == "", "handle_line: notification → empty string")
	var tool_err: Dictionary = call_tool(p, "read_note", {"path": "../../etc/passwd.tres"})
	check(tool_err.get("isError") == true and err_code(tool_err) == "invalid_path", "tool failure is an isError result, not a protocol error")


# ── Tools ───────────────────────────────────────────────────────────────────

func test_tools(V: String) -> void:
	var tools: RefCounted = VaultTools.new(V)
	var p: RefCounted = McpProtocol.new(tools)
	req(p, "initialize", {"protocolVersion": "2025-06-18"})

	# list_notes
	var lst: Dictionary = data(call_tool(p, "list_notes", {}))
	check(lst.count > 0 and lst.count == VaultStore.note_list.size(), "list_notes: every note the app sees (%d)" % lst.get("count", -1))
	check(lst.notes.all(func(n): return str(n.path).ends_with(".tres") and not str(n.path).begins_with("/")), "list_notes: vault-relative .tres paths")

	# create_note
	var c: Dictionary = call_tool(p, "create_note", {"title": "MCP Probe", "markdown": "# Probe\nalpha bravo ✓\n", "tags": ["#mcp", "probe"], "folder": "Agent/Inbox"})
	var cd: Dictionary = data(c)
	check(not c.isError and cd.path == "Agent/Inbox/note_mcp_probe.tres" and FileAccess.file_exists(V + cd.path), "create_note: writes note_<title>.tres in a new folder")
	check(cd.hash == FileAccess.get_sha256(V + cd.path) and cd.hash.length() == 64, "create_note: returns the SHA-256 of the file")
	var again: Dictionary = call_tool(p, "create_note", {"title": "MCP Probe", "markdown": "other", "folder": "Agent/Inbox"})
	check(err_code(again) == "exists" and FileAccess.get_sha256(V + cd.path) == cd.hash, "create_note: refuses when the file exists, file untouched")
	check(err_code(call_tool(p, "create_note", {"title": "  "})) == "invalid_arguments", "create_note: empty title refused")
	check(err_code(call_tool(p, "create_note", {"title": "X", "folder": ".ontomeme"})) == "invalid_path", "create_note: hidden folder refused")
	check(err_code(call_tool(p, "create_note", {"title": "X", "folder": "../outside"})) == "invalid_path", "create_note: folder outside the vault refused")
	check(DirAccess.get_files_at(V + ".ontomeme/tmp").size() == 0, "atomic write leaves no temp files")

	# read_note
	var rd: Dictionary = data(call_tool(p, "read_note", {"path": cd.path}))
	check(rd.title == "MCP Probe" and rd.markdown == "# Probe\nalpha bravo ✓\n" and rd.tags == ["mcp", "probe"], "read_note: title, markdown, tags (leading # stripped)")
	check(rd.hash == cd.hash and rd.folder == "Agent/Inbox", "read_note: same hash as create, folder")
	var raw: Dictionary = data(call_tool(p, "read_note", {"path": cd.path, "raw": true}))
	check(str(raw.get("raw", "")).begins_with("[gd_resource") and str(raw.raw).contains("ContentLayer"), "read_note raw: the .tres text")
	check(err_code(call_tool(p, "read_note", {"path": "nope/missing.tres"})) == "not_found", "read_note: missing → not_found")
	check(err_code(call_tool(p, "read_note", {"path": "/etc/passwd"})) == "invalid_path", "read_note: absolute path refused")
	check(err_code(call_tool(p, "read_note", {"path": ".trash/x.tres"})) == "invalid_path", "read_note: hidden folder refused")

	# update_note
	check(err_code(call_tool(p, "update_note", {"path": cd.path, "markdown": "x"})) == "invalid_arguments", "update_note: no hash → refused")
	var u: Dictionary = call_tool(p, "update_note", {"path": cd.path, "hash": rd.hash, "markdown": "charlie delta", "tags": ["mcp", "edited"]})
	var ud: Dictionary = data(u)
	check(not u.isError and ud.hash != rd.hash and ud.hash == FileAccess.get_sha256(V + cd.path), "update_note: writes, returns the new hash")
	var rd2: Dictionary = data(call_tool(p, "read_note", {"path": cd.path}))
	check(rd2.markdown == "charlie delta" and rd2.title == "MCP Probe" and rd2.tags == ["mcp", "edited"], "update_note: body + tags replaced, title kept")
	var stale: Dictionary = call_tool(p, "update_note", {"path": cd.path, "hash": rd.hash, "markdown": "LOST UPDATE"})
	check(err_code(stale) == "conflict" and data(stale).error.current_hash == ud.hash, "update_note: stale hash → conflict with the current hash")
	check(data(call_tool(p, "read_note", {"path": cd.path})).markdown == "charlie delta", "update_note: refused write left the file alone")

	# Someone else (the app, a sync tool) edits the file → our hash is stale.
	var outside: ContentLayer = ResourceLoader.load(V + cd.path, "", ResourceLoader.CACHE_MODE_IGNORE)
	outside.raw_text = "edited outside"
	ResourceSaver.save(outside, V + cd.path)
	check(err_code(call_tool(p, "update_note", {"path": cd.path, "hash": ud.hash, "markdown": "mine"})) == "conflict", "update_note: outside edit → conflict")
	var fresh: Dictionary = data(call_tool(p, "read_note", {"path": cd.path}))
	check(fresh.markdown == "edited outside", "read_note after outside edit sees it")
	var ren: Dictionary = data(call_tool(p, "update_note", {"path": cd.path, "hash": fresh.hash, "title": "MCP Probe Renamed"}))
	check(ren.path == cd.path and ren.title == "MCP Probe Renamed", "update_note: title change keeps the file")

	# search_notes
	var s1: Dictionary = data(call_tool(p, "search_notes", {"query": "EDITED OUTSIDE"}))
	check(s1.total == 1 and s1.notes[0].path == cd.path and s1.notes[0].matched == "content" and str(s1.notes[0].snippet).contains("edited outside"), "search_notes: content match, case-insensitive, with snippet")
	var s2: Dictionary = data(call_tool(p, "search_notes", {"title": "probe renamed"}))
	check(s2.total == 1 and s2.notes[0].path == cd.path, "search_notes: title match")
	var s3: Dictionary = data(call_tool(p, "search_notes", {"tag": "#Edited"}))
	check(s3.total == 1 and s3.notes[0].path == cd.path, "search_notes: tag match (# and case ignored)")
	var tut: Dictionary = data(call_tool(p, "search_notes", {"tag": "tutorial", "limit": 2}))
	check(tut.total > 2 and tut.count == 2 and tut.notes.size() == 2, "search_notes: tag over seeded notes, limit honoured")
	var both: Dictionary = data(call_tool(p, "search_notes", {"tag": "tutorial", "query": "edited outside"}))
	check(both.total == 0, "search_notes: filters combine with AND")
	var inf: Dictionary = data(call_tool(p, "search_notes", {"folder": "Agent"}))
	check(inf.total == 1, "search_notes: folder scope")

	# delete_note → .trash
	check(err_code(call_tool(p, "delete_note", {"path": cd.path, "hash": rd.hash})) == "conflict" and FileAccess.file_exists(V + cd.path), "delete_note: stale hash → conflict, file kept")
	check(err_code(call_tool(p, "delete_note", {"path": cd.path})) == "invalid_arguments", "delete_note: no hash → refused")
	var del: Dictionary = data(call_tool(p, "delete_note", {"path": cd.path, "hash": ren.hash}))
	check(not FileAccess.file_exists(V + cd.path) and del.trashed_to == ".trash/" + cd.path and FileAccess.file_exists(V + del.trashed_to), "delete_note: moved to .trash/<path>")
	check(FileAccess.get_sha256(V + del.trashed_to) == ren.hash, "delete_note: trashed file is byte-identical")
	check(data(call_tool(p, "search_notes", {"query": "edited outside"})).total == 0, "trashed note no longer listed or searched")
	# A second note with the same path deleted → earlier trashed copy kept.
	var c2: Dictionary = data(call_tool(p, "create_note", {"title": "MCP Probe", "folder": "Agent/Inbox"}))
	var del2: Dictionary = data(call_tool(p, "delete_note", {"path": c2.path, "hash": c2.hash}))
	check(del2.trashed_to != del.trashed_to and FileAccess.file_exists(V + del2.trashed_to) and FileAccess.file_exists(V + del.trashed_to), "delete_note: never overwrites inside the trash")
	check(err_code(call_tool(p, "delete_note", {"path": c2.path, "hash": c2.hash})) == "not_found", "delete_note: already gone → not_found")

	# on_change hook (how an in-app host would learn of writes)
	var seen: Array = []
	tools.on_change = func(action: String, rel: String): seen.append(action + ":" + rel)
	var c3: Dictionary = data(call_tool(p, "create_note", {"title": "Hook"}))
	check(seen == ["create:note_hook.tres"], "on_change called after a write")
	tools.on_change = Callable()
	call_tool(p, "delete_note", {"path": c3.path, "hash": c3.hash})


# ── The app reads what the server writes ────────────────────────────────────

func test_app_compat(V: String) -> void:
	var p: RefCounted = McpProtocol.new(VaultTools.new(V))
	req(p, "initialize", {"protocolVersion": "2025-06-18"})
	var c: Dictionary = data(call_tool(p, "create_note", {"title": "Seen By App", "markdown": "from the server", "tags": ["x"]}))
	VaultStore.refresh_note_list()
	var i: int = VaultStore.get_note_index("Seen By App")
	var n: ContentLayer = VaultStore.note_list[i] if i >= 0 else null
	check(n != null and n.raw_text == "from the server" and n.tags == ["x"] and n.resource_path == V + c.path, "VaultStore loads a server-created note")
	check(TresValidator.validate(V + c.path).valid, "TresValidator accepts a server-written note")
	data(call_tool(p, "update_note", {"path": c.path, "hash": c.hash, "markdown": "updated by server"}))
	# The app reloads a file whose mtime moved (1 s resolution, so a same-second
	# update may need the next poll); force that path instead of sleeping.
	VaultStore._mtimes[V + c.path] = 0
	VaultStore.refresh_note_list()
	i = VaultStore.get_note_index("Seen By App")
	check(i >= 0 and VaultStore.note_list[i].raw_text == "updated by server", "VaultStore sees a server update after a rescan")
	var rd: Dictionary = data(call_tool(p, "read_note", {"path": c.path}))
	call_tool(p, "delete_note", {"path": c.path, "hash": rd.hash})
	VaultStore.refresh_note_list()
	check(VaultStore.get_note_index("Seen By App") == -1, "VaultStore drops a trashed note")


# ── End to end: the stdio server as a subprocess ────────────────────────────

func test_stdio_e2e() -> void:
	var dir: String = ProjectSettings.globalize_path("user://test-vault-mcp-e2e/")
	TestVault.remove_tree(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var args: PackedStringArray = ["--headless", "--no-header", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://mcp/stdio_server.gd", "--", "--vault=" + dir]
	var proc: Dictionary = OS.execute_with_pipe(OS.get_executable_path(), args, false)
	check(not proc.is_empty(), "stdio: server process started")
	if proc.is_empty():
		return
	var io: FileAccess = proc.stdio
	var msgs: Array = [
		{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}}},
		{"jsonrpc": "2.0", "method": "notifications/initialized"},
		{"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
		{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "create_note", "arguments": {"title": "Over Stdio", "markdown": "line one\nline two ✓ \"quoted\""}}},
		{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "read_note", "arguments": {"path": "note_over_stdio.tres"}}},
	]
	for m in msgs:
		io.store_string(JSON.stringify(m) + "\n")
	io.flush()
	var raw := PackedByteArray()
	var lines: Array[String] = []
	var deadline: int = Time.get_ticks_msec() + 20000
	while lines.size() < 4 and Time.get_ticks_msec() < deadline:
		var chunk: PackedByteArray = io.get_buffer(65536)
		if chunk.is_empty():
			await create_timer(0.05).timeout
			continue
		raw.append_array(chunk)
		var nl: int = raw.find(10)
		while nl >= 0:
			lines.append(raw.slice(0, nl).get_string_from_utf8())
			raw = raw.slice(nl + 1)
			nl = raw.find(10)
	# Close stdin → the server sees EOF and exits by itself.
	io.close()
	var exit_deadline: int = Time.get_ticks_msec() + 5000
	while OS.is_process_running(proc.pid) and Time.get_ticks_msec() < exit_deadline:
		await create_timer(0.05).timeout
	var exited: bool = not OS.is_process_running(proc.pid)
	if not exited:
		OS.kill(proc.pid)
	var err_text: String = ""
	if proc.stderr is FileAccess:
		err_text = (proc.stderr as FileAccess).get_buffer(65536).get_string_from_utf8()
		(proc.stderr as FileAccess).close()

	check(lines.size() == 4, "stdio: 4 replies for 4 requests (+1 notification), got %d" % lines.size())
	var parsed: Array = []
	var strict: bool = lines.size() > 0
	for l in lines:
		var j := JSON.new()
		if j.parse(l) != OK or not (j.data is Dictionary) or j.data.get("jsonrpc") != "2.0":
			strict = false
			print("      not a JSON-RPC line: ", l.c_escape().left(200))
		else:
			parsed.append(j.data)
	check(strict and raw.is_empty(), "stdio: every stdout line is a JSON-RPC message (no banner, no logs)")
	if parsed.size() == 4:
		check(int(parsed[0].id) == 1 and parsed[0].result.protocolVersion == "2025-06-18", "stdio: initialize")
		check(int(parsed[1].id) == 2 and parsed[1].result.tools.size() == 6, "stdio: tools/list")
		check(int(parsed[2].id) == 3 and parsed[2].result.isError == false and FileAccess.file_exists(dir + "note_over_stdio.tres"), "stdio: tools/call create_note wrote the file")
		check(int(parsed[3].id) == 4 and parsed[3].result.structuredContent.markdown == "line one\nline two ✓ \"quoted\"", "stdio: read_note round-trips newlines, quotes, UTF-8")
	check(exited, "stdio: server exits on stdin EOF")
	check(err_text.contains("[ontomeme-mcp] serving vault"), "stdio: logs go to stderr")
	TestVault.remove_tree(dir)
