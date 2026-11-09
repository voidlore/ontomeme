extends SceneTree
## MCP get_progress and get_journey: read-only views of the vault's quiz
## results and Learning Journey. They read <vault>/.ontomeme/progress.json
## and journey.json and never write, create or copy anything.
##   godot --headless --path . -s res://tests/mcp_learning_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const McpProtocol = preload("res://mcp/protocol.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")
const QUIZ_NOTE: String = "Shapes Quiz"

var fails: int = 0
var V: String = ""
var tools: RefCounted


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func data(result: Dictionary) -> Dictionary:
	return result.get("structuredContent", {})


func err_code(result: Dictionary) -> String:
	return str(data(result).get("error", {}).get("code", "")) if result.get("isError", false) else ""


func write_text(p: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## Every file under `dir`, hidden ones too, with its SHA-256: what a
## read-only tool must leave exactly as it was.
func snapshot(dir: String, rel: String = "", out: Dictionary = {}) -> Dictionary:
	var d := DirAccess.open(dir.path_join(rel))
	if d == null:
		return out
	d.include_hidden = true
	for sub in d.get_directories():
		out[rel.path_join(sub) + "/"] = ""
		snapshot(dir, rel.path_join(sub), out)
	for f in d.get_files():
		out[rel.path_join(f)] = FileAccess.get_sha256(dir.path_join(rel).path_join(f))
	return out


func _init() -> void:
	# No file_override: the stores write into the throwaway vault's .ontomeme,
	# the same files the tools read.
	ProgressStore.file_override = ""
	JourneyStore.file_override = ""
	V = TestVault.open("mcp-learning", false)
	var progress: String = V.path_join(".ontomeme/progress.json")
	var journey: String = V.path_join(".ontomeme/journey.json")
	if ProgressStore.path() != progress or JourneyStore.path() != journey:
		print("FAIL  the stores point into the test vault (%s, %s); stopping before anything writes" % [ProgressStore.path(), JourneyStore.path()])
		quit(1)
		return
	tools = VaultTools.new(V)
	test_catalog()
	test_missing_files()
	test_progress(progress)
	test_journey(journey)
	test_unreadable(progress, journey)
	test_unopenable(progress)
	ProgressStore.invalidate()
	JourneyStore.invalidate()
	TestVault.remove_tree(V)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)


func test_catalog() -> void:
	var p: RefCounted = McpProtocol.new(tools)
	p.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
	var r: Variant = p.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
	var by_name: Dictionary = {}
	for t in r.result.tools:
		by_name[t.name] = t
	for name in ["get_progress", "get_journey"]:
		check(by_name.has(name) and by_name[name].annotations.readOnlyHint == true and by_name[name].inputSchema.type == "object", "tools/list: %s, readOnlyHint" % name)
	var called: Variant = p.handle({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_journey", "arguments": {}}})
	check(called is Dictionary and called.has("result") and called.result.isError == false, "tools/call reaches get_journey")


## No progress or journey file yet: empty results, and nothing appears.
func test_missing_files() -> void:
	var before: Dictionary = snapshot(V)
	var gp: Dictionary = tools.call_tool("get_progress", {})
	check(gp.isError == false and data(gp).notes == [] and data(gp).count == 0, "get_progress with no progress file: no notes")
	var gj: Dictionary = tools.call_tool("get_journey", {})
	check(gj.isError == false and data(gj).version == JourneyStore.VERSION and data(gj).topics == [], "get_journey with no journey file: version 1, no topics")
	check(snapshot(V) == before, "and no file or folder was created in the vault")


func test_progress(progress: String) -> void:
	var note: ContentLayer = VaultStore.create_note(QUIZ_NOTE, "Geometry")
	note.raw_text = "```3d\npreset: quiz\nq: Which one is round?\na*: A sphere\na: A cube\nq: Which has six faces?\na*: A cube\na: A cone\nlearn: Solids\nq: Which has no corners?\na*: A sphere\na: A cube\n```\n"
	VaultStore.save_note(note)
	var path: String = note.resource_path.trim_prefix(V)
	ProgressStore.record_answer(QUIZ_NOTE, 0, 0, "Which one is round?", true, "")
	ProgressStore.record_answer(QUIZ_NOTE, 0, 1, "Which has six faces?", false, "Solids")
	ProgressStore.record_answer(QUIZ_NOTE, 0, 2, "Which has no corners?", true, "")
	ProgressStore.record_result(QUIZ_NOTE, 0, 2, 3)
	ProgressStore.record_answer("Gone Note", 1, 0, "Still here?", false, "Gone Note")
	ProgressStore.record_result("Gone Note", 1, 0, 1)
	var bytes: String = FileAccess.get_sha256(progress)

	var r: Dictionary = data(tools.call_tool("get_progress", {}))
	check(r.get("count") == 2 and r.notes.size() == 2, "get_progress: both notes with results (%s)" % r.get("count"))
	var shapes: Dictionary = {}
	var gone: Dictionary = {}
	for n in r.get("notes", []):
		if n.note == QUIZ_NOTE:
			shapes = n
		elif str(n.note).to_lower() == "gone note":
			gone = n
	check(shapes.get("path", "") == path, "a note in the vault comes with its title and path (%s)" % shapes.get("path", ""))
	var q: Array = shapes.get("quizzes", [])
	check(q.size() == 1 and q[0].quiz == 0 and q[0].passed == true and q[0].score == 2 and q[0].total == 3, "its quiz 0: passed, 2 of 3 (%s)" % [q])
	var missed: Array = shapes.get("missed", [])
	check(missed.size() == 1 and missed[0].q == "Which has six faces?" and missed[0].learn == "Solids" and missed[0].quiz == 0 and missed[0].question == 1,
		"the missed question, with its learn: target Solids (%s)" % [missed])
	check(not gone.is_empty() and gone.path == "" and gone.quizzes[0].quiz == 1 and gone.quizzes[0].passed == false, "results for a note no longer in the vault still show, with no path")

	var one: Dictionary = data(tools.call_tool("get_progress", {"note": "  shapes QUIZ "}))
	check(one.get("count") == 1 and one.notes[0].note == QUIZ_NOTE, "note: a title (any case) narrows it to that note")
	one = data(tools.call_tool("get_progress", {"note": path}))
	check(one.get("count") == 1 and one.notes[0].note == QUIZ_NOTE, "note: a path from list_notes works too")
	check(err_code(tools.call_tool("get_progress", {"note": "Nowhere/note_x.tres"})) == "not_found", "a path to no note: not_found")
	check(err_code(tools.call_tool("get_progress", {"note": "../outside.tres"})) == "invalid_path", "a path outside the vault: invalid_path")
	check(err_code(tools.call_tool("get_progress", {"note": 5})) == "invalid_arguments", "a note that isn't text: invalid_arguments")
	check(FileAccess.get_sha256(progress) == bytes, "progress.json is unchanged by reading it")

	# Hand-edited values of the wrong type read as nothing, never as a script error
	write_text(progress, '{"quizzes": {"odd#0": {"best": "two", "total": null, "passed": "yes"}, "no index": {}}, "questions": {"odd#0#x": {"right": false}, "odd#0#1": {"right": "no", "q": 5}}}')
	r = data(tools.call_tool("get_progress", {}))
	var odd: Array = r.get("notes", [])
	check(odd.size() == 1 and odd[0].note == "odd" and odd[0].quizzes == [{"quiz": 0, "passed": false, "score": 0, "last": 0, "total": 0}] and odd[0].missed.is_empty(),
		"scores that aren't numbers read as 0, a passed or right that isn't true/false as not, keys without numbers are skipped (%s)" % [odd])


func test_journey(journey: String) -> void:
	JourneyStore.invalidate()
	var cached: int = JourneyStore.topics().size()   # the app's copy, loaded now (the file is still missing)
	# Written by hand, as another tool would: no version, a demo with a bad output
	const FILE: String = '{"topics": [{"id": "t1", "name": "Geometry", "x_agent": "keep me", "objectives": [' \
		+ '{"id": "o1", "name": "Name shapes", "goal": "learning", "demos": [{"id": "d1", "activity": "Shapes Quiz#quiz0", "output": "percent"}],' \
		+ ' "log": [{"date": "2026-11-07T10:00:00", "activity": "Shapes Quiz#quiz0", "score": 2, "max": 3, "output": "percent", "value": 67}]},' \
		+ '{"id": "o2", "name": "Name solids", "goal": "fluent", "demos": [{"id": "d2", "activity": "Shapes Quiz#quiz0", "output": "bogus"}, {"id": "d3", "activity": "Solid Cards#cards0"}], "log": []}' \
		+ ']}]}'
	write_text(journey, FILE)
	var r: Dictionary = data(tools.call_tool("get_journey", {}))
	var topics: Array = r.get("topics", [])
	check(r.get("version") == 1 and topics.size() == 1 and topics[0].name == "Geometry", "get_journey: version 1 and the one topic")
	var objectives: Array = topics[0].objectives if topics.size() == 1 else []
	check(objectives.map(func(o): return o.name) == ["Name shapes", "Name solids"], "both objectives (%s)" % [objectives.map(func(o): return o.name)])
	if objectives.size() == 2:
		var shapes: Dictionary = objectives[0]
		var solids: Dictionary = objectives[1]
		check(shapes.met == true and shapes.demos[0].done == true and shapes.demos[0].attempts == 1 and shapes.log.size() == 1, "Name shapes: 67% meets its Learning goal, its quiz done (1 attempt), its log kept")
		check(solids.met == false and solids.goal == "fluent" and solids.demos.size() == 1 and solids.demos[0].activity == "Solid Cards#cards0" and solids.demos[0].done == false and solids.demos[0].latest == null,
			"Name solids: a broken demo left out as the app would, the deck not done yet")
	check(topics.size() == 1 and topics[0].get("x_agent") == "keep me", "unknown keys come through")
	check(r.get("broken_entries") == 1, "and it says one broken entry was left out (%s)" % r.get("broken_entries"))
	check(FileAccess.get_file_as_string(journey) == FILE, "journey.json is unchanged (no version added, nothing dropped)")
	check(JourneyStore.topics().size() == cached, "the app's in-memory journey wasn't reloaded or changed")
	var kept: Array = Array(DirAccess.get_files_at(journey.get_base_dir())).filter(func(f): return f.contains(".unreadable-"))
	check(kept.is_empty(), "no unreadable copy was made of it")

	# A save that removed journey.json but couldn't rename journey.tmp over it
	var tmp: String = journey.get_basename() + ".tmp"
	DirAccess.rename_absolute(journey, tmp)
	r = data(tools.call_tool("get_journey", {}))
	check(r.get("topics", []).size() == 1 and not FileAccess.file_exists(journey) and FileAccess.get_file_as_string(tmp) == FILE,
		"with only journey.tmp left, get_journey reads it and leaves it where it is")
	DirAccess.rename_absolute(tmp, journey)


## Files that don't parse: isError "unreadable", and their bytes untouched.
func test_unreadable(progress: String, journey: String) -> void:
	const BAD_PROGRESS: String = '{"quizzes": {"shapes quiz#0": {"best": 2, "tot'
	const BAD_JOURNEY: String = '{"topics": "not a list"}'
	write_text(progress, BAD_PROGRESS)
	write_text(journey, BAD_JOURNEY)
	var before: Dictionary = snapshot(V)
	var gp: Dictionary = tools.call_tool("get_progress", {})
	check(gp.isError == true and err_code(gp) == "unreadable", "get_progress on a cut-off progress.json: isError, code unreadable (%s)" % err_code(gp))
	var gj: Dictionary = tools.call_tool("get_journey", {})
	check(gj.isError == true and err_code(gj) == "unreadable", "get_journey on a journey.json of the wrong shape: isError, code unreadable (%s)" % err_code(gj))
	check(str(data(gj).error.get("path", "")) == ".ontomeme/journey.json", "the error names the file")
	check(FileAccess.get_file_as_string(progress) == BAD_PROGRESS and FileAccess.get_file_as_string(journey) == BAD_JOURNEY, "both files keep their bytes")
	check(snapshot(V) == before, "and no copy, .tmp or other file appeared")


## A progress.json that can't be opened at all: unreadable too, left alone.
func test_unopenable(progress: String) -> void:
	write_text(progress, '{"quizzes": {}}')
	FileAccess.set_unix_permissions(progress, 0)
	if FileAccess.open(progress, FileAccess.READ) != null:   # root, or no Unix permissions
		print("SKIP  an unopenable progress.json: chmod 000 doesn't stop this user reading it")
	else:
		var gp: Dictionary = tools.call_tool("get_progress", {})
		check(err_code(gp) == "unreadable" and str(data(gp).error.message).contains("couldn't be opened"), "a progress.json that can't be opened: unreadable, and says so")
	FileAccess.set_unix_permissions(progress, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
