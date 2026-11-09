extends SceneTree
## The --mcp-stdio boot switch: the app's own entry (boot.tscn, the main scene)
## serves MCP over stdio when asked, the way a shipped build must (release
## templates ignore -s), and opens the window otherwise.
## Each server run is a subprocess with no -s and no --no-header, in throwaway
## XDG config/data/documents dirs, so it never sees the user's vaults.
##   godot --headless --path . -s res://tests/mcp_boot_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const McpProtocol = preload("res://mcp/protocol.gd")
const McpServe = preload("res://mcp/serve.gd")
const DesktopConfig = preload("res://mcp/desktop_config.gd")
const ReadmeTest = preload("res://tests/readme_mcp_test.gd")

var fails: int = 0
var root_dir: String = ""


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_mcp_boot.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_mcp_boot.json"   # never touch real progress
	ProgressStore.reset()
	root_dir = ProjectSettings.globalize_path("user://test-mcp-boot/")
	TestVault.remove_tree(root_dir)

	test_project_settings()
	test_no_shell_or_network()
	test_client_log()
	await test_gui_path()
	await test_boot_switch_e2e()
	await test_last_used_vault()
	await test_env_vault()
	await test_no_vault()
	await test_missing_vault_flag()
	test_desktop_config()
	await test_desktop_config_runs()

	TestVault.remove_tree(root_dir)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


# ── Helpers ─────────────────────────────────────────────────────────────────

## A throwaway "machine": XDG config, data and documents dirs under one folder.
## Returns its path; the app's user:// there is <home>data/godot/app_userdata/Ontomeme/.
func make_home(name: String) -> String:
	var home: String = root_dir.path_join(name) + "/"
	for d in ["config", "data", "docs"]:
		DirAccess.make_dir_recursive_absolute(home + d)
	var f := FileAccess.open(home + "config/user-dirs.dirs", FileAccess.WRITE)
	f.store_string("XDG_DOCUMENTS_DIR=\"%sdocs\"\n" % home)
	f.close()
	return home


func user_dir(home: String) -> String:
	return home + "data/godot/app_userdata/" + str(ProjectSettings.get_setting("application/config/name")) + "/"


func make_vault(name: String) -> String:
	var v: String = root_dir.path_join("vaults").path_join(name) + "/"
	DirAccess.make_dir_recursive_absolute(v)
	return v


func msg_init(id: int = 1) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "boot-e2e", "version": "1"}}}


func msg_call(id: int, tool: String, args: Dictionary) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": tool, "arguments": args}}


## Start the app the way an MCP client does: `<godot> --headless --path <res>
## -- <user_args>`, with `env` set for the child only ("" unsets a variable).
func spawn(user_args: Array, env: Dictionary) -> Dictionary:
	var args: PackedStringArray = ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--"]
	args.append_array(PackedStringArray(user_args))
	return spawn_command(OS.get_executable_path(), args, env)


## Start `command` with `args` and `env` set for the child only.
func spawn_command(command: String, args: PackedStringArray, env: Dictionary) -> Dictionary:
	var saved: Dictionary = {}
	for k in env:
		saved[k] = OS.get_environment(k) if OS.has_environment(k) else null
		if str(env[k]) == "":
			OS.unset_environment(k)
		else:
			OS.set_environment(k, str(env[k]))
	var proc: Dictionary = OS.execute_with_pipe(command, args, false)
	for k in saved:
		if saved[k] == null:
			OS.unset_environment(k)
		else:
			OS.set_environment(k, saved[k])
	return proc


func home_env(home: String, ontomeme_vault: String = "") -> Dictionary:
	return {"XDG_CONFIG_HOME": home + "config", "XDG_DATA_HOME": home + "data", "ONTOMEME_VAULT": ontomeme_vault}


## Send `msgs`, read until `want` reply lines (20 s at most), optionally sit
## idle `idle_secs` measuring CPU, then close stdin and wait for the exit.
func session(proc: Dictionary, msgs: Array, want: int, idle_secs: float = 0.0) -> Dictionary:
	var out: Dictionary = {"lines": [], "tail": PackedByteArray(), "stderr": "", "exited": false, "code": -1, "cpu_pct": -1.0}
	if proc.is_empty():
		return out
	var io: FileAccess = proc.stdio
	for m in msgs:
		io.store_string(JSON.stringify(m) + "\n")
	io.flush()
	var raw := PackedByteArray()
	var lines: Array[String] = []
	var deadline: int = Time.get_ticks_msec() + 20000
	while lines.size() < want and Time.get_ticks_msec() < deadline and OS.is_process_running(proc.pid):
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
	if idle_secs > 0.0 and OS.is_process_running(proc.pid):
		await create_timer(0.5).timeout   # let startup work finish
		var t0: float = cpu_secs(proc.pid)
		var w0: int = Time.get_ticks_msec()
		await create_timer(idle_secs).timeout
		var t1: float = cpu_secs(proc.pid)
		if t0 >= 0.0 and t1 >= 0.0:
			out.cpu_pct = 100.0 * (t1 - t0) / ((Time.get_ticks_msec() - w0) / 1000.0)
	raw.append_array(io.get_buffer(65536))   # anything printed after the replies
	io.close()   # stdin EOF: the server quits by itself
	var exit_deadline: int = Time.get_ticks_msec() + 10000
	while OS.is_process_running(proc.pid) and Time.get_ticks_msec() < exit_deadline:
		await create_timer(0.05).timeout
	out.exited = not OS.is_process_running(proc.pid)
	if out.exited:
		out.code = OS.get_process_exit_code(proc.pid)
	else:
		OS.kill(proc.pid)
	if proc.stderr is FileAccess:
		out.stderr = (proc.stderr as FileAccess).get_buffer(1 << 20).get_string_from_utf8()
		(proc.stderr as FileAccess).close()
	out.lines = lines
	out.tail = raw
	return out


## User + system CPU seconds of a process, from /proc (Linux); -1 elsewhere.
func cpu_secs(pid: int) -> float:
	var path: String = "/proc/%d/stat" % pid
	if not FileAccess.file_exists(path):
		return -1.0
	var f := FileAccess.open(path, FileAccess.READ)   # /proc files report length 0: read a line
	var s: String = f.get_line() if f != null else ""
	var fields: PackedStringArray = s.substr(s.rfind(")") + 2).split(" ")
	if fields.size() < 13:
		return -1.0
	return (fields[11].to_int() + fields[12].to_int()) / float(clock_ticks())


func clock_ticks() -> int:
	var out: Array = []
	if OS.execute("getconf", ["CLK_TCK"], out) == 0 and out.size() > 0 and str(out[0]).strip_edges().to_int() > 0:
		return str(out[0]).strip_edges().to_int()
	return 100


## Parsed replies, or [] when any stdout line is not a JSON-RPC 2.0 message.
func parse_replies(res: Dictionary) -> Array:
	var parsed: Array = []
	for l in res.lines:
		var j := JSON.new()
		if j.parse(l) != OK or not (j.data is Dictionary) or j.data.get("jsonrpc") != "2.0":
			print("      not a JSON-RPC line: ", str(l).c_escape().left(200))
			return []
		parsed.append(j.data)
	return parsed if (res.tail as PackedByteArray).is_empty() else []


## Every file and folder in `dir`, hidden ones included, relative to it.
func tree_of(dir: String, rel: String = "") -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir.path_join(rel))
	if d == null:
		return out
	d.include_hidden = true
	for sub in d.get_directories():
		var r: String = rel.path_join(sub) if rel != "" else sub
		out.append(r + "/")
		out.append_array(tree_of(dir, r))
	for f in d.get_files():
		out.append(rel.path_join(f) if rel != "" else f)
	out.sort()
	return out


## Calls that run programs, reach the network or run code built at runtime.
## None may sit in a script the MCP server process loads.
const FORBIDDEN_API: String = "\\bOS\\.(execute|execute_with_pipe|create_process|create_instance|shell_open|shell_show_in_file_manager|kill)\\b|\\b(HTTPRequest|HTTPClient|StreamPeerTCP|StreamPeerTLS|TCPServer|UDPServer|PacketPeerUDP|PacketPeerDTLS|DTLSServer|WebSocketPeer|WebSocketMultiplayerPeer|WebRTC\\w*|ENet\\w*|JavaScriptBridge)\\b|\\bIP\\.|\\b(Expression|GDScript)\\.new\\b|\\.source_code\\b"


## Every script an MCP-mode process loads: the autoloads, boot.gd, and what
## they reach through "res://….gd" strings (preload/load) and class_name
## identifiers, to a fixpoint. Scenes are not followed: MCP mode loads none
## (boot.gd load()s note.tscn only on the window path, see test_gui_path).
func server_scripts() -> Array[String]:
	var by_class: Dictionary = {}
	for path in project_scripts("res://"):
		var m: RegExMatch = RegEx.create_from_string("(?m)^class_name\\s+(\\w+)").search(FileAccess.get_file_as_string(path))
		if m != null:
			by_class[m.get_string(1)] = path
	var todo: Array[String] = ["res://boot.gd"]
	for prop in ProjectSettings.get_property_list():
		if str(prop.name).begins_with("autoload/"):
			todo.append(str(ProjectSettings.get_setting(prop.name)).trim_prefix("*"))
	var refs := RegEx.create_from_string("\"(res://[^\"]+\\.gd)\"")
	var words := RegEx.create_from_string("\\b[A-Z]\\w+\\b")
	var seen: Array[String] = []
	while not todo.is_empty():
		var path: String = todo.pop_back()
		if path in seen or not FileAccess.file_exists(path):
			continue
		seen.append(path)
		var text: String = FileAccess.get_file_as_string(path)
		for m in refs.search_all(text):
			todo.append(m.get_string(1))
		for m in words.search_all(text):
			if by_class.has(m.get_string()):
				todo.append(by_class[m.get_string()])
	seen.sort()
	return seen


## The app's own scripts (not tests, dev scripts or the editor cache).
func project_scripts(dir: String) -> Array[String]:
	var out: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if not (d in ["tests", "scripts", "skills", "addons", "build"]) and not d.begins_with("."):
			out.append_array(project_scripts(dir.path_join(d)))
	return out


## "<file>:<line>: <code>" for each forbidden call in `path` (comment lines skipped).
func forbidden_calls(path: String) -> Array[String]:
	var out: Array[String] = []
	var re := RegEx.create_from_string(FORBIDDEN_API)
	var lines: PackedStringArray = FileAccess.get_file_as_string(path).split("\n")
	for i in lines.size():
		if not lines[i].strip_edges().begins_with("#") and re.search(lines[i]) != null:
			out.append("%s:%d: %s" % [path.get_file(), i + 1, lines[i].strip_edges()])
	return out


# ── Tests ───────────────────────────────────────────────────────────────────

func test_project_settings() -> void:
	check(str(ProjectSettings.get_setting("application/run/main_scene")) == "res://boot.tscn", "the main scene is boot.tscn")
	check(ProjectSettings.get_setting("application/run/print_header", true) == false, "print_header is off, so no engine banner reaches stdout")
	# Release builds default to false and then hold every reply in the stdout
	# buffer until exit; the editor (debug) defaults to true and can't show it.
	# scripts/check_mcp_release.sh proves it on a real export.
	check(ProjectSettings.get_setting("application/run/flush_stdout_on_print", false) == true, "flush_stdout_on_print is on, so a release build sends each reply at once")


## No script the MCP process loads can run a program, open a connection or
## build code at runtime. (The README can't promise "no shell, no network"
## from this alone: a note file's own script would run in the same process.
## readme_mcp_test probes that before the promise may be stated.)
func test_no_shell_or_network() -> void:
	var scripts: Array[String] = server_scripts()
	var core: Array[String] = ["res://boot.gd", "res://mcp/serve.gd", "res://mcp/protocol.gd", "res://mcp/vault_tools.gd", "res://mcp/stdio_transport.gd", "res://vault_store.gd", "res://ContentLayer.gd"]
	check(core.all(func(p: String) -> bool: return p in scripts), "the scan reaches the server's scripts (%d scripts)" % scripts.size())
	check(not ("res://note.gd" in scripts), "…and not the window's note.gd, which MCP mode never loads")
	check(not forbidden_calls("res://note.gd").is_empty(), "(the scan does find OS.shell_open in note.gd, so it can see one)")
	var found: Array[String] = []
	for path in scripts:
		found.append_array(forbidden_calls(path))
	check(found.is_empty(), "no script the MCP server loads can run a program, reach the network or build code %s" % [found])


## The protocol core reports each initialize (it does no I/O itself), and
## serve.gd turns it into one stderr line.
func test_client_log() -> void:
	var p: RefCounted = McpProtocol.new(null)
	var seen: Array = []
	p.client_initialized.connect(func(requested: String, negotiated: String, info: Dictionary, caps: Dictionary) -> void:
		seen.append([requested, negotiated, info, caps]))
	var info: Dictionary = {"name": "claude-code", "title": "Claude Code", "version": "2.1.319", "icons": [{"src": "data:image/png;base64,AAAA"}]}
	p.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "1999-01-01", "capabilities": {"roots": {}, "elicitation": {}}, "clientInfo": info}})
	check(seen.size() == 1 and seen[0][0] == "1999-01-01" and seen[0][1] == McpProtocol.LATEST_VERSION and seen[0][2] == info, "protocol: client_initialized carries the requested version, the answered one and clientInfo")
	check(p.requested_version == "1999-01-01" and p.protocol_version == McpProtocol.LATEST_VERSION, "protocol: requested_version is kept beside protocol_version")
	var line: String = McpServe.client_line("1999-01-01", McpProtocol.LATEST_VERSION, info, {"roots": {}, "elicitation": {}})
	check(line == "client requested protocol 1999-01-01, answered %s (the requested one isn't supported); clientInfo {\"name\":\"claude-code\",\"title\":\"Claude Code\",\"version\":\"2.1.319\"}; capabilities: elicitation, roots" % McpProtocol.LATEST_VERSION,
			"serve: the log line names both versions, clientInfo without icons, sorted capabilities (%s)" % line)
	var odd: String = McpServe.client_line("2025\nfake line", "2025-06-18", {"name": "x".repeat(400)}, {})
	check(not odd.contains("\n") and odd.length() < 480 and odd.ends_with("capabilities: none"), "serve: client strings can't break the line or flood stderr (%d chars)" % odd.length())


## Without --mcp-stdio the boot scene hands over to the note window.
func test_gui_path() -> void:
	TestVault.open("mcp-boot-gui")
	var boot: Node = load("res://boot.tscn").instantiate()
	get_root().add_child(boot)
	current_scene = boot
	await frames(6)
	var scene: Node = current_scene
	check(scene != null and scene.scene_file_path == "res://note.tscn", "boot.tscn without --mcp-stdio switches to note.tscn (%s)" % (scene.scene_file_path if scene else "none"))
	check(not is_instance_valid(boot) or not boot.is_inside_tree(), "…and leaves the tree")
	check(scene != null and scene.get("current_note") != null, "…which opens a note as usual")
	if scene != null:
		scene.queue_free()
	current_scene = null
	await frames(2)
	TestVault.remove_tree(ProjectSettings.globalize_path("user://test-vault-mcp-boot-gui/"))


## The shipped way: `godot --headless --path <res> -- --mcp-stdio --vault=<dir>`.
func test_boot_switch_e2e() -> void:
	var home: String = make_home("e2e")
	var vault: String = make_vault("e2e")
	var proc: Dictionary = spawn(["--mcp-stdio", "--vault=" + vault], home_env(home))
	check(not proc.is_empty(), "boot: server process started (no -s, no --no-header)")
	var msgs: Array = [
		msg_init(),
		{"jsonrpc": "2.0", "method": "notifications/initialized"},
		{"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
		msg_call(3, "create_note", {"title": "Over Boot", "markdown": "booted ✓ \"quoted\"\nline two"}),
		msg_call(4, "read_note", {"path": "note_over_boot.tres"}),
	]
	var res: Dictionary = await session(proc, msgs, 4, 5.0)
	check(res.lines.size() == 4, "boot: 4 replies for 4 requests (+1 notification), got %d" % res.lines.size())
	var r: Array = parse_replies(res)
	check(r.size() == 4, "boot: every stdout line is a JSON-RPC message (no banner, no logs)")
	if r.size() == 4:
		check(int(r[0].id) == 1 and r[0].result.protocolVersion == "2025-06-18", "boot: initialize")
		check(str(r[0].result.get("instructions", "")).contains(vault.trim_suffix("/")), "boot: initialize instructions name the vault")
		check(int(r[1].id) == 2 and r[1].result.tools.size() >= 6, "boot: tools/list (%d tools)" % r[1].result.tools.size())
		check(int(r[2].id) == 3 and r[2].result.isError == false and FileAccess.file_exists(vault + "note_over_boot.tres"), "boot: create_note wrote the note")
		check(int(r[3].id) == 4 and r[3].result.structuredContent.markdown == "booted ✓ \"quoted\"\nline two", "boot: read_note round-trips it")
	check(res.stderr.contains("[ontomeme-mcp] serving vault " + vault.trim_suffix("/")), "boot: stderr logs the vault it serves")
	check(res.stderr.contains("[ontomeme-mcp] client requested protocol 2025-06-18, answered 2025-06-18; clientInfo {\"name\":\"boot-e2e\",\"version\":\"1\"}; capabilities: none"),
			"boot: stderr logs the client's requested protocol version and clientInfo")
	if res.cpu_pct >= 0.0:
		check(res.cpu_pct < 2.0, "boot: idle CPU over 5 s is under 2%% (%.2f%%)" % res.cpu_pct)
	else:
		print("SKIP  boot: idle CPU (no /proc on this OS)")
	check(res.exited and res.code == 0, "boot: exits with code 0 on stdin EOF (exited %s, code %d)" % [res.exited, res.code])
	var files: Array[String] = tree_of(vault)
	check(files == [".ontomeme/", ".ontomeme/tmp/", "note_over_boot.tres"], "boot: the vault holds only the requested note (+ .ontomeme/tmp) %s" % [files])
	check(not FileAccess.file_exists(user_dir(home) + "vaults.json"), "boot: MCP mode writes no user://vaults.json")
	check(not FileAccess.file_exists(user_dir(home) + "display.json"), "boot: MCP mode writes no user://display.json")
	check(not DirAccess.dir_exists_absolute(home + "docs/Ontomeme"), "boot: MCP mode creates no ~/Documents/Ontomeme")


## No --vault and no ONTOMEME_VAULT: the vault the app last used is served,
## and user://vaults.json is only read.
func test_last_used_vault() -> void:
	var home: String = make_home("last-used")
	var vault: String = make_vault("last-used")
	DirAccess.make_dir_recursive_absolute(user_dir(home))
	var registry: String = JSON.stringify({"recent": [vault], "last": vault}, "\t")
	var f := FileAccess.open(user_dir(home) + "vaults.json", FileAccess.WRITE)
	f.store_string(registry)
	f.close()
	var proc: Dictionary = spawn(["--mcp-stdio"], home_env(home))
	var res: Dictionary = await session(proc, [msg_init(), msg_call(2, "create_note", {"title": "From Last Used", "markdown": "x"})], 2)
	var r: Array = parse_replies(res)
	check(r.size() == 2 and r[1].result.isError == false and FileAccess.file_exists(vault + "note_from_last_used.tres"), "last used: the vault named in vaults.json is served")
	check(res.stderr.contains("serving vault " + vault.trim_suffix("/")) and res.stderr.contains("last used"), "last used: stderr says which vault and why")
	check(res.exited and res.code == 0, "last used: exit code 0 on stdin EOF (%d)" % res.code)
	check(FileAccess.get_file_as_string(user_dir(home) + "vaults.json") == registry, "last used: vaults.json is unchanged")
	check(not FileAccess.file_exists(user_dir(home) + "display.json"), "last used: no user://display.json")
	check(tree_of(vault) == [".ontomeme/", ".ontomeme/tmp/", "note_from_last_used.tres"], "last used: only the requested write in the vault %s" % [tree_of(vault)])


## ONTOMEME_VAULT wins over the last-used vault.
func test_env_vault() -> void:
	var home: String = make_home("env")
	var last: String = make_vault("env-last")
	var vault: String = make_vault("env")
	DirAccess.make_dir_recursive_absolute(user_dir(home))
	var f := FileAccess.open(user_dir(home) + "vaults.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"recent": [last], "last": last}))
	f.close()
	var proc: Dictionary = spawn(["--mcp-stdio"], home_env(home, vault))
	var res: Dictionary = await session(proc, [msg_init(), msg_call(2, "create_note", {"title": "From Env", "markdown": "x"})], 2)
	check(FileAccess.file_exists(vault + "note_from_env.tres") and not FileAccess.file_exists(last + "note_from_env.tres"), "env: ONTOMEME_VAULT is served before the last-used vault")
	check(res.exited and res.code == 0, "env: exit code 0 (%d)" % res.code)


## Nothing names a vault and ~/Documents/Ontomeme does not exist: refuse,
## and create nothing.
func test_no_vault() -> void:
	var home: String = make_home("none")
	var proc: Dictionary = spawn(["--mcp-stdio"], home_env(home))
	var res: Dictionary = await session(proc, [msg_init()], 1)
	check(res.exited and res.code == 2, "no vault: exit code 2 (exited %s, code %d)" % [res.exited, res.code])
	check(res.stderr.contains("[ontomeme-mcp]") and res.stderr.contains("no vault"), "no vault: stderr says why (%s)" % res.stderr.strip_edges().right(160).c_escape())
	check(res.lines.is_empty() and (res.tail as PackedByteArray).is_empty(), "no vault: nothing on stdout")
	check(not DirAccess.dir_exists_absolute(home + "docs/Ontomeme"), "no vault: <XDG_DOCUMENTS_DIR>/Ontomeme is not created")
	check(not FileAccess.file_exists(user_dir(home) + "vaults.json"), "no vault: no user://vaults.json")


## An explicit --vault that does not exist is refused, never created.
func test_missing_vault_flag() -> void:
	var home: String = make_home("missing")
	var vault: String = root_dir.path_join("vaults/does-not-exist/")
	var proc: Dictionary = spawn(["--mcp-stdio", "--vault=" + vault], home_env(home))
	var res: Dictionary = await session(proc, [msg_init()], 1)
	check(res.exited and res.code == 2, "missing --vault: exit code 2 (%d)" % res.code)
	check(res.stderr.contains("does not exist"), "missing --vault: stderr says why")
	check(not DirAccess.dir_exists_absolute(vault), "missing --vault: the folder is not created")
	check(not DirAccess.dir_exists_absolute(home + "docs/Ontomeme"), "missing --vault: no ~/Documents/Ontomeme either")


## The palette's "Connect Claude Desktop…" snippet (mcp/desktop_config.gd)
## for each OS: valid JSON, Windows backslashes intact, the boot-switch args,
## and the same text as the README's snippet for the same path.
func test_desktop_config() -> void:
	var mac: String = "/Applications/Ontomeme.app/Contents/MacOS/Ontomeme"
	var win: String = "C:\\Users\\Zoë\\Downloads\\Ontomeme-windows-x86_64\\Ontomeme.exe"
	var linux: String = "/home/you/Ontomeme-linux/Ontomeme.x86_64"
	for c in [[mac, "macOS"], [win, "Windows"], [linux, "Linux"]]:
		var text: String = DesktopConfig.snippet(c[0], c[1])
		var parsed: Variant = JSON.parse_string(text)
		var e: Dictionary = parsed.mcpServers.ontomeme if parsed is Dictionary and parsed.get("mcpServers") is Dictionary else {}
		check(e.get("command") == c[0] and e.get("args") == ["--headless", "--log-file", "user://logs/mcp.log", "--", "--mcp-stdio"], "desktop config %s: parses, command round-trips, args --headless --log-file user://logs/mcp.log -- --mcp-stdio" % c[1])
	var w: Dictionary = JSON.parse_string(DesktopConfig.snippet(win, "Windows", "C:/Users/Zoë/Documents/My Notes/")).mcpServers.ontomeme
	check(w.command == win and w.args[-1] == "--vault=C:\\Users\\Zoë\\Documents\\My Notes", "desktop config Windows: backslashes round-trip, Godot's / paths become \\ (%s)" % w.args[-1])
	check(DesktopConfig.snippet(win, "Windows").contains("\"C:\\\\Users\\\\Zoë"), "desktop config Windows: the file text writes every \\ twice")
	check(JSON.parse_string(DesktopConfig.snippet("C:/Program Files/Ontomeme/Ontomeme.exe", "Windows")).mcpServers.ontomeme.command == "C:\\Program Files\\Ontomeme\\Ontomeme.exe", "desktop config Windows: OS.get_executable_path()'s / become \\")
	var dev: Dictionary = JSON.parse_string(DesktopConfig.snippet(linux, "Linux", "/home/you/Notes/", "/src/ontomeme/")).mcpServers.ontomeme
	check(dev.args == ["--headless", "--log-file", "user://logs/mcp.log", "--path", "/src/ontomeme", "--", "--mcp-stdio", "--vault=/home/you/Notes"], "desktop config: --path before --, --vault after --mcp-stdio, no trailing / (%s)" % [dev.args])
	var odd: String = "/tmp/a \"quoted\" dir/Ontomeme"
	check(JSON.parse_string(DesktopConfig.snippet(odd, "Linux")).mcpServers.ontomeme.command == odd, "desktop config: quotes in a path round-trip")
	check(DesktopConfig.native_path("C:/", "Windows") == "C:\\" and DesktopConfig.native_path("/", "Linux") == "/", "desktop config: a root keeps its separator")
	# A Linux AppImage runs from a temporary mount (or extraction folder):
	# the entry must start the .AppImage file, which outlives it.
	var appimage: String = "/home/you/Applications/Ontomeme-0.1.0-linux-x86_64.AppImage"
	check(DesktopConfig.launcher("/tmp/.mount_OntomeAbC123/usr/bin/Ontomeme", appimage) == [appimage],
			"desktop config AppImage: the command is the .AppImage file, not the mount it runs from")
	check(DesktopConfig.launcher("/tmp/appimage_extracted_0123456789abcdef/usr/bin/Ontomeme", appimage) == [appimage, "--appimage-extract-and-run"],
			"…started with --appimage-extract-and-run (no FUSE), the entry passes that too")
	check(DesktopConfig.launcher(linux, "") == [linux], "desktop config: outside an AppImage, its own executable")
	var extracted: Dictionary = JSON.parse_string(DesktopConfig.snippet(appimage, "Linux", "", "", ["--appimage-extract-and-run"] as Array[String])).mcpServers.ontomeme
	check(extracted.command == appimage and extracted.args == ["--appimage-extract-and-run", "--headless", "--log-file", "user://logs/mcp.log", "--", "--mcp-stdio"],
			"…first, where the AppImage runtime reads it (%s)" % [extracted.args])
	check(DesktopConfig.config_path_hint("macOS") == "~/Library/Application Support/Claude/claude_desktop_config.json"
			and DesktopConfig.config_path_hint("Windows") == "%APPDATA%\\Claude\\claude_desktop_config.json"
			and DesktopConfig.config_path_hint("Linux").contains("Mac and Windows"), "desktop config: where Claude's config file lives, per OS")
	var readme: Array[String] = ReadmeTest.json_blocks(ReadmeTest.readme_section(FileAccess.get_file_as_string("res://README.md"), ReadmeTest.HEADING))
	var same: int = 0
	for block in readme:
		var e: Variant = JSON.parse_string(block)
		if e is Dictionary and e.get("mcpServers") is Dictionary and e.mcpServers.get("ontomeme") is Dictionary:
			var cmd: String = str(e.mcpServers.ontomeme.get("command", ""))
			var os_name: String = "Windows" if cmd.contains("\\") else "macOS" if cmd.contains(".app/") else "Linux"
			if DesktopConfig.snippet(cmd, os_name) == block.strip_edges():
				same += 1
	check(readme.size() == 3 and same == readme.size(), "desktop config: the same text as each of the README's %d snippets for its path (%d match)" % [readme.size(), same])


## The snippet the dialog shows for this install (the editor binary, so with
## --path) starts a server that answers initialize on the open vault. Godot
## copies all a process prints into its log file, and the server prints
## every reply, notes' text included: that must not land in godot.log, the
## app's log a bug report asks for, nor push the app's own log out of it.
func test_desktop_config_runs() -> void:
	var home: String = make_home("desktop-config")
	var vault: String = make_vault("desktop-config")
	var parsed: Variant = JSON.parse_string(DesktopConfig.for_this_app(vault))
	var e: Dictionary = parsed.mcpServers.ontomeme
	check(e.command == OS.get_executable_path() and e.args == ["--headless", "--log-file", "user://logs/mcp.log", "--path", ProjectSettings.globalize_path("res://").trim_suffix("/"), "--", "--mcp-stdio", "--vault=" + vault.trim_suffix("/")],
			"for_this_app: this executable, its own log file, --path on an editor build, the vault (%s)" % [e.args])
	var logs: String = user_dir(home) + "logs/"
	DirAccess.make_dir_recursive_absolute(logs)
	var app_log: String = "[Ontomeme] the app's own log, as the app left it\n"
	var f := FileAccess.open(logs + "godot.log", FileAccess.WRITE)
	f.store_string(app_log)
	f.close()
	var secret: String = "Words from a private note"
	var proc: Dictionary = spawn_command(e.command, PackedStringArray(e.args), home_env(home))
	var res: Dictionary = await session(proc, [msg_init(), msg_call(2, "create_note", {"title": "From The Dialog", "markdown": secret}), msg_call(3, "read_note", {"path": "note_from_the_dialog.tres"})], 3)
	var r: Array = parse_replies(res)
	check(r.size() == 3 and r[1].result.isError == false and FileAccess.file_exists(vault + "note_from_the_dialog.tres") and r[2].result.structuredContent.markdown == secret,
			"for_this_app: its command and args serve the vault over stdio")
	check(res.exited and res.code == 0, "for_this_app: exit code 0 on stdin EOF (%d)" % res.code)
	check(FileAccess.get_file_as_string(logs + "godot.log") == app_log, "for_this_app: the app's godot.log is left as it was: no replies, no note text, not rotated (%s)"
			% FileAccess.get_file_as_string(logs + "godot.log").left(120).c_escape())
	var files: PackedStringArray = DirAccess.get_files_at(logs)
	check(Array(files) == ["godot.log", "mcp.log"], "for_this_app: the server logs to user://logs/mcp.log, beside the app's log %s" % [files])
	check(FileAccess.get_file_as_string(logs + "mcp.log").contains("[ontomeme-mcp] serving vault"), "for_this_app: …which holds the server's log")
