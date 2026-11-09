extends SceneTree
## CONTRIBUTING.md against the tests it describes: the test it names as the
## example of keeping tests off your own notes follows that pattern in its
## _init (both store file_overrides pointed at user://test_* files, then a
## TestVault opened, all before the first await, and the overrides cleared
## again at the end), and macOS and Windows get the run_all.sh command that
## works there.
##   headless:  godot --headless --path . -s res://tests/contributing_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const CONTRIBUTING: String = "res://CONTRIBUTING.md"

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


## `line` without its trailing comment (a # outside a string).
func code_of(line: String) -> String:
	var quote: String = ""
	var i: int = 0
	while i < line.length():
		var ch: String = line[i]
		if quote != "":
			if ch == "\\":
				i += 1
			elif ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "#":
			return line.substr(0, i)
		i += 1
	return line


## The code lines of `func _init` in a GDScript file, comments stripped.
func init_body(path: String) -> PackedStringArray:
	var body: PackedStringArray = []
	var inside: bool = false
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if line.begins_with("func _init("):
			inside = true
		elif inside:
			if line != "" and not line.begins_with("\t") and not line.begins_with(" "):
				break
			body.append(code_of(line))
	return body


## The index of the first line matching `pattern`, or -1.
func first_match(lines: PackedStringArray, pattern: String) -> int:
	var re := RegEx.create_from_string(pattern)
	for i in lines.size():
		if re.search(lines[i]) != null:
			return i
	return -1


## The example test CONTRIBUTING names really follows the pattern it shows.
func check_example(text: String) -> void:
	var named: RegExMatch = RegEx.create_from_string("`(tests/\\w+_test\\.gd)` follows this pattern").search(text)
	check(named != null, "CONTRIBUTING.md names a test that follows the keep-off-your-notes pattern")
	if named == null:
		return
	var example: String = "res://" + named.get_string(1)
	var body: PackedStringArray = init_body(example)
	check(FileAccess.file_exists(example) and body.size() > 0, "…%s exists and has an _init" % example)
	var first_await: int = first_match(body, "\\bawait\\b")
	if first_await < 0:
		first_await = body.size()
	var opened: int = first_match(body, "\\bTestVault\\.(open|hold)\\(")
	check(opened >= 0 and opened < first_await, "…it opens a TestVault before its first await (line %d of _init, await at %d), so the app never opens the startup vault" % [opened, first_await])
	for store in ["ProgressStore", "JourneyStore"]:
		var set_at: int = first_match(body, "\\b%s\\.file_override\\s*=\\s*\"user://test_" % store)
		check(set_at >= 0 and set_at < first_await and (opened < 0 or set_at < opened), "…it points %s.file_override at a user://test_ file before it opens the vault" % store)
		var cleared: int = first_match(body, "\\b%s\\.file_override\\s*=\\s*\"\"" % store)
		check(cleared > set_at, "…and clears %s.file_override again at the end" % store)


## Each command line in a fenced block, with the prose since the previous
## fence or heading: {"line": ..., "before": ...}.
func fenced_commands(text: String) -> Array:
	var commands: Array = []
	var fenced: bool = false
	var prose: String = ""
	var before: String = ""
	for line in text.split("\n"):
		if line.begins_with("```"):
			fenced = not fenced
			if fenced:
				before = prose
			prose = ""
		elif fenced:
			commands.append({"line": line.strip_edges(), "before": before})
		elif line.begins_with("#"):
			prose = ""
		else:
			prose += line + "\n"
	return commands


## On macOS and Windows Godot ignores the XDG folders run_all.sh's sandbox
## sets, so the runner finds the user's real Documents/Ontomeme and stops
## before the first test unless RUN_ALL_NO_SANDBOX=1 is set: CONTRIBUTING
## gives them that command, not the Linux one.
func check_run_all_per_os(text: String) -> void:
	var re := RegEx.create_from_string("^RUN_ALL_NO_SANDBOX=1 GODOT=\\S+ tests/run_all\\.sh$")
	var for_mac_windows: bool = false
	for c in fenced_commands(text):
		if re.search(c.line) != null and c.before.contains("macOS") and c.before.contains("Windows"):
			for_mac_windows = true
	check(for_mac_windows, "CONTRIBUTING.md gives macOS and Windows the command 'RUN_ALL_NO_SANDBOX=1 GODOT=... tests/run_all.sh'")
	# Every RUN_ALL_* switch the runner reads is one CONTRIBUTING names.
	var runner: String = FileAccess.get_file_as_string("res://tests/run_all.sh")
	for m in RegEx.create_from_string("\\$\\{(RUN_ALL_\\w+)").search_all(runner):
		check(text.contains(m.get_string(1)), "…and names %s, which tests/run_all.sh reads" % m.get_string(1))


func _init() -> void:
	# Nothing here awaits, but the VaultStore autoload still opens the startup
	# vault once _init returns unless one is open.
	var vault: String = TestVault.open("contributing", false)
	var text: String = FileAccess.get_file_as_string(CONTRIBUTING)
	check(text != "", "CONTRIBUTING.md is there")
	check_example(text)
	check_run_all_per_os(text)
	TestVault.remove_tree(vault)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
