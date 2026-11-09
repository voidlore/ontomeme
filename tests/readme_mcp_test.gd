extends SceneTree
## The README's Claude Desktop setup works as written: every ```json block
## under "## Use with Claude Desktop (MCP)" parses, names Ontomeme as the
## "ontomeme" MCP server with --headless and --mcp-stdio, and its args start
## the server (here on the editor binary, plus --path and a temp --vault),
## which answers initialize and exits 0 on stdin EOF.
## And what that section and mcp/README.md promise about safety holds: each
## promise found in their prose has a probe here, run on the real VaultTools,
## and every bullet under "### What Claude can do" must state one of them.
## Every --flag the section tells users to pass is one the app reads.
##   godot --headless --path . -s res://tests/readme_mcp_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")

const HEADING: String = "## Use with Claude Desktop (MCP)"
const CAN_DO: String = "### What Claude can do"
## The docs whose prose is held to PROMISES: [path, heading ("" = whole file)].
const DOCS: Array = [["res://README.md", HEADING], ["res://mcp/README.md", ""]]

## What the MCP docs may promise about safety. A promise is stated when one
## sentence of DOCS matches `says`; then its `probe` (a method below taking a
## scratch dir, returning "" when the promise holds, else what broke it) must
## hold. `gap: true` marks a sentence that states a known gap, which must
## still be one: it holds while the probe fails.
const PROMISES: Array[Dictionary] = [
	{"name": "a path can't climb out of the vault, be absolute, or lead into a hidden folder",
		"says": "(?i)(\\.\\./|`\\.\\.`|\\bclimbs? out\\b|\\babsolute paths?\\b|\\bhidden folders?\\b).*\\brefused\\b", "probe": "probe_path_escape"},
	{"name": "nothing outside the vault can be reached, symbolic links included",
		"says": "(?i)(\\boutside\\b|\\bsymbolic links?\\b|\\bsymlinks?\\b).*\\b(refused|blocked|can't|cannot)\\b", "probe": "probe_symlinks"},
	{"name": "symbolic links in the vault are followed (a known gap)",
		"says": "(?i)\\bsymbolic links?\\b.*\\bfollowed\\b|\\bfollows? symbolic links?\\b", "probe": "probe_symlinks", "gap": true},
	{"name": "edits and deletes ask you first",
		"says": "(?i)\\bapproval\\b|\\basks? you before\\b", "probe": "probe_destructive_hints"},
	{"name": "deletes go to .trash and are never erased",
		"says": "(?i)\\bgo(es)? to (the )?`?\\.trash|\\b(never|nothing is) erased\\b", "probe": "probe_trash"},
	{"name": "a change based on an old read is refused",
		"says": "(?i)\\b(old|stale) read\\b|\\bchanged (after|since) .*\\bread\\b", "probe": "probe_stale_hash"},
	{"name": "a note file can't bring code that runs",
		"says": "(?i)\\bembedded code\\b|\\bcode from notes\\b|\\bscripts? in notes\\b", "probe": "probe_note_code"},
	{"name": "the server can't run programs or reach the network",
		"says": "(?i)\\bno shell\\b|\\bno network\\b|\\brun programs\\b|\\bopen connections\\b", "probe": "probe_note_code"},
	{"name": "Ontomeme asks you itself before an edit or delete (MCP elicitation)",
		"says": "(?i)\\bconfirmation prompts?\\b|--confirm-writes|\\belicit", "probe": "probe_elicitation"},
]
## Command-line flags the docs may name that the engine, not our code, reads.
const ENGINE_FLAGS: Array[String] = ["--headless", "--path", "--no-header", "--log-file"]
## The build each OS's snippet must point at, by the end of its command.
const COMMANDS: Array[String] = ["Ontomeme.app/Contents/MacOS/Ontomeme", "\\Ontomeme.exe", "-linux-x86_64.AppImage"]
const REPLY_TIMEOUT_MS: int = 15000

var fails: int = 0
var root_dir: String = ""


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func _init() -> void:
	TestVault.hold()   # before any await, or the autoload opens the real vault
	root_dir = ProjectSettings.globalize_path("user://test-readme-mcp/")
	TestVault.remove_tree(root_dir)
	var section: String = readme_section(FileAccess.get_file_as_string("res://README.md"), HEADING)
	check(section != "", "README.md has a \"%s\" section" % HEADING)
	var blocks: Array[String] = json_blocks(section)
	check(blocks.size() == COMMANDS.size(), "…with one ```json snippet per OS (%d)" % blocks.size())
	var commands: Array[String] = []
	for i in blocks.size():
		var entry: Dictionary = await check_block(i, blocks[i])
		commands.append(str(entry.get("command", "")))
	for want in COMMANDS:
		check(commands.any(func(c: String) -> bool: return c.ends_with(want)), "a snippet's command ends with %s" % want)
	test_promises(section)
	test_flags(section)
	TestVault.remove_tree(root_dir)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


# ── Reading the README ──────────────────────────────────────────────────────

## The text under `heading`, up to the next "## " heading ("" if missing).
static func readme_section(md: String, heading: String) -> String:
	var lines: PackedStringArray = md.split("\n")
	var start: int = lines.find(heading)
	if start < 0:
		return ""
	var out: PackedStringArray = []
	for i in range(start + 1, lines.size()):
		if lines[i].begins_with("## "):
			break
		out.append(lines[i])
	return "\n".join(out)


## The bodies of the ```json fenced blocks in `md`.
static func json_blocks(md: String) -> Array[String]:
	var out: Array[String] = []
	var body: PackedStringArray = []
	var inside: bool = false
	for line in md.split("\n"):
		if not inside and line.strip_edges() == "```json":
			inside = true
			body.clear()
		elif inside and line.strip_edges() == "```":
			inside = false
			out.append("\n".join(body))
		elif inside:
			body.append(line)
	return out


# ── One snippet ─────────────────────────────────────────────────────────────

## Parse snippet `i`, check its shape and run its args. Returns its
## mcpServers.ontomeme entry ({} if it doesn't parse).
func check_block(i: int, text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	var servers: Variant = parsed.get("mcpServers") if parsed is Dictionary else null
	var entry: Variant = servers.get("ontomeme") if servers is Dictionary else null
	check(entry is Dictionary, "snippet %d parses as JSON with mcpServers.ontomeme" % i)
	if not (entry is Dictionary):
		return {}
	var args: Variant = entry.get("args")
	var ok_args: bool = args is Array and (args as Array).all(func(a: Variant) -> bool: return a is String)
	check(entry.get("command") is String and str(entry.command).is_absolute_path(), "snippet %d: command is an absolute path (%s)" % [i, entry.get("command")])
	check(ok_args and "--headless" in args and "--mcp-stdio" in args, "snippet %d: args contain --headless and --mcp-stdio %s" % [i, args])
	if ok_args:
		var dash: int = (args as Array).find("--")
		check(dash >= 0 and (args as Array).find("--headless") < dash and (args as Array).find("--mcp-stdio") > dash, "snippet %d: --headless goes to the engine, --mcp-stdio after the --" % i)
		await check_round_trip(i, PackedStringArray(args))
	return entry


## Start the editor binary with the snippet's args (plus --path res:// and a
## temp vault, in throwaway XDG dirs) and do an initialize round trip.
func check_round_trip(i: int, args: PackedStringArray) -> void:
	var home: String = root_dir.path_join("home-%d" % i) + "/"
	var vault: String = root_dir.path_join("vault-%d" % i) + "/"
	for d in [home + "config", home + "data", vault]:
		DirAccess.make_dir_recursive_absolute(d)
	var proc: Dictionary = spawn(run_args(args, vault), {"XDG_CONFIG_HOME": home + "config", "XDG_DATA_HOME": home + "data"})
	check(not proc.is_empty(), "snippet %d: the server started" % i)
	if proc.is_empty():
		return
	var io: FileAccess = proc.stdio
	io.store_string(JSON.stringify({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "readme-test", "version": "1"}}}) + "\n")
	io.flush()
	var line: String = await read_line(proc)
	var reply: Variant = JSON.parse_string(line)
	var result: Variant = reply.get("result") if reply is Dictionary else null
	check(result is Dictionary and result.get("protocolVersion") == "2025-06-18", "snippet %d: initialize round trip (%s)" % [i, line.left(120)])
	check(result is Dictionary and str(result.get("instructions", "")).contains(vault.trim_suffix("/")), "snippet %d: …serving the --vault it was given" % i)
	io.close()   # stdin EOF: the server quits by itself
	var deadline: int = Time.get_ticks_msec() + 10000
	while OS.is_process_running(proc.pid) and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	var exited: bool = not OS.is_process_running(proc.pid)
	if not exited:
		OS.kill(proc.pid)
	check(exited and OS.get_process_exit_code(proc.pid) == 0, "snippet %d: exits 0 on stdin EOF" % i)
	if proc.stderr is FileAccess:
		(proc.stderr as FileAccess).close()


## The snippet's args for the editor binary: --path res:// before the --, and
## the temp vault instead of any --vault= after it.
static func run_args(args: PackedStringArray, vault: String) -> PackedStringArray:
	var dash: int = args.find("--")
	var out: PackedStringArray = args.slice(0, dash)
	out.append_array(["--path", ProjectSettings.globalize_path("res://"), "--"])
	for a in args.slice(dash + 1):
		if not a.begins_with("--vault="):
			out.append(a)
	out.append("--vault=" + vault)
	return out


## OS.execute_with_pipe with `env` set for the child only.
func spawn(args: PackedStringArray, env: Dictionary) -> Dictionary:
	var saved: Dictionary = {}
	for k in env:
		saved[k] = OS.get_environment(k) if OS.has_environment(k) else null
		OS.set_environment(k, env[k])
	var had_vault: bool = OS.has_environment("ONTOMEME_VAULT")
	var env_vault: String = OS.get_environment("ONTOMEME_VAULT")
	OS.unset_environment("ONTOMEME_VAULT")
	var proc: Dictionary = OS.execute_with_pipe(OS.get_executable_path(), args, false)
	for k in saved:
		if saved[k] == null:
			OS.unset_environment(k)
		else:
			OS.set_environment(k, saved[k])
	if had_vault:
		OS.set_environment("ONTOMEME_VAULT", env_vault)
	return proc


## The first stdout line, or "" after REPLY_TIMEOUT_MS.
func read_line(proc: Dictionary) -> String:
	var raw := PackedByteArray()
	var deadline: int = Time.get_ticks_msec() + REPLY_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline and OS.is_process_running(proc.pid):
		raw.append_array((proc.stdio as FileAccess).get_buffer(65536))
		var nl: int = raw.find(10)
		if nl >= 0:
			return raw.slice(0, nl).get_string_from_utf8()
		await create_timer(0.05).timeout
	return ""


# ── What the docs promise ───────────────────────────────────────────────────

## Each promise the docs state holds, and each "What Claude can do" bullet
## states one. A promise nobody states is only reported (its probe still
## runs, so the report says whether it could be stated).
func test_promises(section: String) -> void:
	var said: Array = []   # per PROMISES entry: the "<doc>: <sentence>" lines stating it
	for p in PROMISES:
		said.append([])
	for doc in DOCS:
		var md: String = FileAccess.get_file_as_string(doc[0])
		if doc[1] != "":
			md = readme_section(md, doc[1])
		check(md != "", "%s has prose to check" % doc[0])
		for s in sentences(md):
			for i in PROMISES.size():
				if RegEx.create_from_string(PROMISES[i].says).search(s) != null:
					said[i].append("%s: \"%s\"" % [str(doc[0]).trim_prefix("res://"), s])
	var results: Dictionary = {}   # probe name -> "" or what broke it
	for i in PROMISES.size():
		var p: Dictionary = PROMISES[i]
		if not results.has(p.probe):
			var dir: String = root_dir.path_join("probe-" + p.probe) + "/"
			TestVault.remove_tree(dir)
			DirAccess.make_dir_recursive_absolute(dir)
			results[p.probe] = str(call(p.probe, dir))
			TestVault.remove_tree(dir)
		var broken: String = results[p.probe]
		var holds: bool = (broken != "") if p.get("gap", false) else (broken == "")
		var why: String = ("the gap is closed now" if p.get("gap", false) else broken) if not holds else "holds"
		if said[i].is_empty():
			print("info  not promised: %s (%s)" % [p.name, why])
		else:
			check(holds, "the docs promise %s: %s %s" % [p.name, why, said[i]])
	var bullets: Array[String] = can_do_bullets(section)
	check(bullets.size() >= 3, "\"%s\" lists what Claude can do (%d bullets)" % [CAN_DO, bullets.size()])
	for b in bullets:
		var states: bool = false
		for s in sentences(b):
			for p in PROMISES:
				states = states or RegEx.create_from_string(p.says).search(s) != null
		check(states, "the bullet \"%s\" states a promise this test probes" % b.left(60))


## The bullets under CAN_DO in `section`, each joined into one line.
static func can_do_bullets(section: String) -> Array[String]:
	var out: Array[String] = []
	var inside: bool = false
	var cur: String = ""
	for line in section.split("\n"):
		if line.begins_with("#"):
			inside = line.strip_edges() == CAN_DO
		elif inside and line.begins_with("- "):
			if cur != "":
				out.append(cur)
			cur = line.substr(2).strip_edges()
		elif inside and cur != "" and line.begins_with(" ") and line.strip_edges() != "":
			cur += " " + line.strip_edges()
		elif cur != "":
			out.append(cur)
			cur = ""
	if cur != "":
		out.append(cur)
	return out


## The prose of `md` as sentences: fenced code dropped; headings, list items,
## table rows and blank lines end a sentence; lines of one paragraph joined.
static func sentences(md: String) -> PackedStringArray:
	var chunks: PackedStringArray = []
	var cur: PackedStringArray = []
	var fenced: bool = false
	var item := RegEx.create_from_string("^([-*]|\\d+\\.)\\s")
	for raw in md.split("\n"):
		var line: String = raw.strip_edges()
		if line.begins_with("```"):
			fenced = not fenced
			continue
		if fenced:
			continue
		if line == "" or line.begins_with("#") or line.begins_with("|") or item.search(line) != null:
			chunks.append(" ".join(cur))
			cur.clear()
		if line != "":
			cur.append(line)
	chunks.append(" ".join(cur))
	var out: PackedStringArray = []
	var stop := RegEx.create_from_string("(?<=[.!?])\\s+")
	for c in chunks:
		for s in stop.sub(c, "\n", true).split("\n", false):
			out.append(s)
	return out


## Each --flag in `section` is an engine flag or one the server's code reads
## (a "--flag" string literal in boot.gd or mcp/*.gd). Godot ignores a user
## argument nobody reads, so a documented flag that isn't would do nothing.
func test_flags(section: String) -> void:
	var code_text: String = FileAccess.get_file_as_string("res://boot.gd")
	for f in DirAccess.get_files_at("res://mcp"):
		if f.ends_with(".gd"):
			code_text += FileAccess.get_file_as_string("res://mcp".path_join(f))
	var flags: Array[String] = []
	for m in RegEx.create_from_string("(?<![\\w-])--[a-z][a-z0-9-]*=?").search_all(section):
		if not (m.get_string() in flags):
			flags.append(m.get_string())
	check(flags.has("--mcp-stdio"), "the section names its flags (%s)" % [flags])
	for flag in flags:
		var read: bool = flag in ENGINE_FLAGS or code_text.contains("\"" + flag)
		check(read, "the README's %s is a flag the app reads" % flag)


# ── Probes: "" when the promise holds, else what broke it ───────────────────

func probe_path_escape(dir: String) -> String:
	var vault: String = dir + "vault/"
	DirAccess.make_dir_recursive_absolute(vault + ".trash")
	write_note(dir + "note_outside.tres", "Outside", "not in the vault")
	write_note(vault + ".trash/note_x.tres", "Trashed", "in a hidden folder")
	var tools: RefCounted = VaultTools.new(vault)
	var gaps: Array[String] = []
	for path in ["../note_outside.tres", "../../etc/passwd.tres", dir + "note_outside.tres", ".trash/note_x.tres", ".ontomeme/note_x.tres"]:
		if code(tools.call_tool("read_note", {"path": path})) != "invalid_path":
			gaps.append("read_note %s was not refused" % path)
	for folder in ["..", "../elsewhere", "/tmp", ".trash", ".ontomeme"]:
		if code(tools.call_tool("create_note", {"title": "Escaped", "folder": folder})) != "invalid_path":
			gaps.append("create_note in %s was not refused" % folder)
	if listed(tools).any(func(p: String) -> bool: return p.contains(".trash")):
		gaps.append("list_notes lists the hidden .trash")
	return "; ".join(gaps)


## A folder link and a file link from the vault to a folder beside it: no
## tool may list, read, change, delete or create anything there.
func probe_symlinks(dir: String) -> String:
	var vault: String = dir + "vault/"
	var outside: String = dir + "outside/"
	DirAccess.make_dir_recursive_absolute(vault)
	DirAccess.make_dir_recursive_absolute(outside)
	for name in ["note_secret", "note_gone", "note_file"]:
		write_note(outside + name + ".tres", "Secret " + name, "outside the vault")
	var d: DirAccess = DirAccess.open(dir)
	var err: int = d.create_link(outside.trim_suffix("/"), vault + "linked")
	if err == OK:
		err = d.create_link(outside + "note_file.tres", vault + "note_file.tres")
	if err != OK:
		return "could not make a symbolic link here (error %d), so nothing is proven" % err
	var before: String = tree_hashes(outside)
	var tools: RefCounted = VaultTools.new(vault)
	var gaps: Array[String] = []
	var seen: Array[String] = listed(tools).filter(func(p: String) -> bool: return p.begins_with("linked/") or p == "note_file.tres")
	if not seen.is_empty():
		gaps.append("list_notes lists %s" % [seen])
	var found: Dictionary = data(tools.call_tool("search_notes", {"query": "outside the vault"}))
	if int(found.get("total", 0)) > 0:
		gaps.append("search_notes finds %d notes outside" % int(found.total))
	for path in ["linked/note_secret.tres", "note_file.tres"]:
		if not tools.call_tool("read_note", {"path": path}).get("isError", false):
			gaps.append("read_note returns %s" % path)
	var r: Dictionary = tools.call_tool("update_note", {"path": "linked/note_secret.tres", "hash": FileAccess.get_sha256(outside + "note_secret.tres"), "markdown": "overwritten"})
	if not r.get("isError", false):
		gaps.append("update_note rewrites linked/note_secret.tres")
	r = tools.call_tool("delete_note", {"path": "linked/note_gone.tres", "hash": FileAccess.get_sha256(outside + "note_gone.tres")})
	if not r.get("isError", false):
		gaps.append("delete_note takes linked/note_gone.tres")
	r = tools.call_tool("create_note", {"title": "Escaped", "folder": "linked"})
	if not r.get("isError", false):
		gaps.append("create_note writes linked/%s" % data(r).get("path", "?").get_file())
	if tree_hashes(outside) != before:
		gaps.append("files outside the vault changed")
	# Unlink before anyone walks the tree, so a cleanup can't follow the links.
	DirAccess.remove_absolute(vault + "linked")
	DirAccess.remove_absolute(vault + "note_file.tres")
	return "; ".join(gaps)


func probe_destructive_hints(dir: String) -> String:
	var hints: Dictionary = {}
	for t in VaultTools.new(dir).list_tools():
		hints[t.name] = t.get("annotations", {})
	var gaps: Array[String] = []
	for name in ["create_note", "update_note", "delete_note"]:
		if hints.get(name, {}).get("readOnlyHint", true) != false:
			gaps.append("%s isn't marked as a write" % name)
	for name in ["update_note", "delete_note"]:
		if hints.get(name, {}).get("destructiveHint", false) != true:
			gaps.append("%s isn't marked destructive" % name)
	return "; ".join(gaps)


func probe_trash(dir: String) -> String:
	var tools: RefCounted = VaultTools.new(dir)
	var gaps: Array[String] = []
	var trashed: Array[String] = []
	for i in 2:
		var made: Dictionary = data(tools.call_tool("create_note", {"title": "Doomed", "markdown": "take %d" % i}))
		var r: Dictionary = data(tools.call_tool("delete_note", {"path": made.get("path", ""), "hash": made.get("hash", "")}))
		var to: String = str(r.get("trashed_to", ""))
		if FileAccess.file_exists(dir + "note_doomed.tres") or not to.begins_with(".trash/") or FileAccess.get_sha256(dir + to) != made.get("hash"):
			gaps.append("delete %d didn't move the note into .trash unchanged (%s)" % [i, r])
		trashed.append(to)
	if trashed[0] == trashed[1] or not FileAccess.file_exists(dir + trashed[0]):
		gaps.append("a second delete of the same name overwrote the first in .trash")
	return "; ".join(gaps)


func probe_stale_hash(dir: String) -> String:
	var claude: RefCounted = VaultTools.new(dir)
	var other: RefCounted = VaultTools.new(dir)   # the app, a sync tool: anyone else
	var made: Dictionary = data(claude.call_tool("create_note", {"title": "Shared", "markdown": "v1"}))
	var old: String = str(data(claude.call_tool("read_note", {"path": made.get("path", "")})).get("hash", ""))
	var now: String = str(data(other.call_tool("update_note", {"path": made.get("path", ""), "hash": old, "markdown": "v2 from someone else"})).get("hash", ""))
	var gaps: Array[String] = []
	if now == "" or now == old:
		return "the setup's own update failed"
	if code(claude.call_tool("update_note", {"path": made.path, "hash": old, "markdown": "v2 from Claude"})) != "conflict":
		gaps.append("update_note with an old hash wasn't refused")
	if code(claude.call_tool("delete_note", {"path": made.path, "hash": old})) != "conflict":
		gaps.append("delete_note with an old hash wasn't refused")
	if FileAccess.get_sha256(dir + made.path) != now:
		gaps.append("the other writer's version was replaced")
	return "; ".join(gaps)


## Note files that carry a script (embedded, or a .gd beside them): listing,
## searching or reading them must not run it.
func probe_note_code(dir: String) -> String:
	var marks: Dictionary = {"note_embedded.tres": dir + "ran-embedded", "note_linked.tres": dir + "ran-linked"}
	var payload: String = "extends Resource\n\nvar ran = _run()\n\nfunc _run():\n\tvar f = FileAccess.open(\"%s\", FileAccess.WRITE)\n\tf.store_string(\"ran\")\n\tf.close()\n\treturn 1\n"
	write_text(dir + "note_embedded.tres", "[gd_resource type=\"Resource\" load_steps=2 format=3]\n\n[sub_resource type=\"GDScript\" id=\"GDScript_1\"]\nscript/source = \"%s\"\n\n[resource]\nscript = SubResource(\"GDScript_1\")\n" % (payload % marks["note_embedded.tres"]).c_escape())
	write_text(dir + "payload.gd", payload % marks["note_linked.tres"])
	write_text(dir + "note_linked.tres", "[gd_resource type=\"Resource\" load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"payload.gd\" id=\"1\"]\n\n[resource]\nscript = ExtResource(\"1\")\n")
	var tools: RefCounted = VaultTools.new(dir)
	listed(tools)
	tools.call_tool("search_notes", {"query": "ran"})
	var gaps: Array[String] = []
	for note in marks:
		if not tools.call_tool("read_note", {"path": note}).get("isError", false):
			gaps.append("read_note returns %s" % note)
		if FileAccess.file_exists(marks[note]):
			gaps.append("the script in %s ran" % note)
	return "; ".join(gaps)


## The server asks the user itself (an MCP elicitation/create request)
## before a destructive call. Until that exists no doc may say it does.
func probe_elicitation(_dir: String) -> String:
	for f in DirAccess.get_files_at("res://mcp"):
		if f.ends_with(".gd") and FileAccess.get_file_as_string("res://mcp".path_join(f)).contains("\"elicitation/create\""):
			return ""
	return "no script in mcp/ sends an elicitation/create request"


# ── Probe helpers ───────────────────────────────────────────────────────────

func write_note(path: String, title: String, body: String) -> void:
	var n := ContentLayer.new()
	n.title = title
	n.raw_text = body
	n.created = "2026-01-01T00:00:00"
	n.modified = n.created
	ResourceSaver.save(n, path)


func write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## "<name>:<sha256>" of each file in `dir`, sorted.
func tree_hashes(dir: String) -> String:
	var out: PackedStringArray = []
	for f in DirAccess.get_files_at(dir):
		out.append("%s:%s" % [f, FileAccess.get_sha256(dir.path_join(f))])
	out.sort()
	return ",".join(out)


func listed(tools: RefCounted) -> Array[String]:
	var out: Array[String] = []
	for n in data(tools.call_tool("list_notes", {})).get("notes", []):
		out.append(str(n.get("path", "")))
	return out


static func data(result: Dictionary) -> Dictionary:
	return result.get("structuredContent", {})


static func code(result: Dictionary) -> String:
	return str(data(result).get("error", {}).get("code", "")) if result.get("isError", false) else ""
