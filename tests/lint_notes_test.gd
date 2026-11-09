extends SceneTree
## scripts/lint_notes.gd reads a front-matter title the way NoteImporter
## does: a "double-" or 'single-quoted' title (YAML needs quotes around
## "Lesson 2: Mixing"; md_export quotes every title) is unquoted, and a blank
## one keeps the file name. Otherwise lint fails [[links]] and learn:/next:
## lines to notes that import_notes.gd imports cleanly, and fails a Markdown
## export of the app's own vault.
##   godot --headless --path . -s res://tests/lint_notes_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const NoteImporter = preload("res://note_importer.gd")
const TMP_DIR: String = "user://test-lint-notes/"

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## Run scripts/lint_notes.gd -- <src> --vault=<vault> ("" src: lint the
## vault). Returns [exit code, its WARN/ERROR lines, the whole output].
func lint(src: String, vault: String) -> Array:
	var args: PackedStringArray = ["--headless", "--no-header", "--path", ProjectSettings.globalize_path("res://"),
		"-s", "res://scripts/lint_notes.gd", "--"]
	if src != "":
		args.append(src)
	args.append("--vault=" + vault)
	var output: Array = []
	var code: int = OS.execute(OS.get_executable_path(), args, output, true)
	var text: String = "\n".join(output)
	var found: PackedStringArray = []
	for line in text.split("\n"):
		if line.begins_with("WARN") or line.begins_with("ERROR"):
			found.append(line)
	print("      lint printed:\n        " + "\n        ".join(text.strip_edges().split("\n")))
	return [code, found, text]


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_lint_notes.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_lint_notes.json"
	ProgressStore.reset()
	var root: String = ProjectSettings.globalize_path(TMP_DIR)
	TestVault.remove_tree(root)
	var src: String = root.path_join("src")
	var empty: String = root.path_join("empty-vault")
	DirAccess.make_dir_recursive_absolute(empty)

	write_text(src.path_join("lesson2.md"), "---\ntitle: \"Lesson 2: Mixing\"\n---\nMix things. See [[Nowhere Yet]].\n")
	write_text(src.path_join("single.md"), "---\ntitle: 'It''s Here'\n---\nA single-quoted title.\n")
	write_text(src.path_join("Template_Note.md"), "---\ntitle: \"\"\n---\nA placeholder title.\n")
	write_text(src.path_join("quiz_hub.md"), "\n".join([
		"---",
		"title: Quiz Hub",
		"---",
		"See [[Lesson 2: Mixing]], [[It's Here]] and [[Template Note]].",
		"",
		"```3d quiz",
		"q: Which one?",
		"a*: this",
		"a: that",
		"learn: Lesson 2: Mixing",
		"next: It's Here",
		"```",
		"",
	]))

	# 1. The source folder: links and learn:/next: to quoted titles resolve.
	var r: Array = lint(src, empty)
	var found: PackedStringArray = r[1]
	check(r[0] == 0, "quoted titles: lint exits 0 (exit %d)" % r[0])
	check(not r[2].contains("missing note") and not r[2].contains("[[Lesson 2: Mixing]]")
			and not r[2].contains("[[It's Here]]") and not r[2].contains("[[Template Note]]"),
			"links, learn: and next: to quoted and placeholder titles resolve")
	check(found.size() == 1 and found[0].begins_with("WARN   Lesson 2: Mixing:") and found[0].contains("[[Nowhere Yet]]"),
			"the one real problem is reported under the unquoted title (%s)" % [found])
	check(r[2].contains("4 notes checked: 0 errors, 1 warning"), "4 notes checked: 0 errors, 1 warning")

	# 2. Import the folder, export the vault as Markdown (every title quoted),
	# and lint the export: nothing points at a missing note.
	var vault: String = TestVault.open("lint-notes", false)
	check(NoteImporter.new().import_dir(src) == 4, "the source folder imports as 4 notes")
	var out: String = root.path_join("export")
	var exported: Dictionary = MdExport.export_vault(out)
	check(exported.written == 4 and exported.failed.is_empty(), "export_vault writes 4 notes (%d, failed %s)" % [exported.written, exported.failed])
	check(FileAccess.get_file_as_string(out.path_join("note_lesson_2_mixing.md")).contains("title: \"Lesson 2: Mixing\""),
			"the export quotes the title: title: \"Lesson 2: Mixing\"")
	r = lint(out, empty)
	check(r[0] == 0, "the Markdown export lints with exit 0 (exit %d)" % r[0])
	check(not r[2].contains("ERROR") and not r[2].contains("missing note") and not r[2].contains("\"Quiz Hub\""),
			"no learn:/next: error and no quoted title in the export's report")

	TestVault.remove_tree(vault)
	TestVault.remove_tree(root)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
