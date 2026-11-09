extends SceneTree
## Note file and folder names that work on every system: a long title gets a
## file name short enough for ext4, APFS and NTFS (255 bytes) and still keeps
## its full title; a folder name Windows can't hold ("CON", "Notes.") is made
## portable, by the app and by the MCP tools alike. A title with letters
## outside a-z (Japanese, Greek, Cyrillic, also beside Latin letters or
## digits: "Godot入門", "Глава 1") gets a file of its own, and no MCP note
## lands in the hidden models/ folder.
##   godot --headless --path . -s res://tests/names_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func data(result: Dictionary) -> Dictionary:
	return result.get("structuredContent", {})


func err_code(result: Dictionary) -> String:
	return str(data(result).get("error", {}).get("code", ""))


## Pairs of distinct titles whose letters outside a-z the file name can't
## keep; the Latin letters and digits they share would give them one stem.
const MIXED_PAIRS: Array = [
	["Godot入門", "Godot応用"],
	["第2章 量子", "第2章 波"],
	["第1章", "第1節"],
	["Глава 1", "Раздел 1"],
	["量子 force", "波 force"],
	["2026年1月17日", "2026年11月7日"],
	["Ελλάδα 2", "Κύμα 2"],
	["Résumé", "Rèsumè"],
]


## A title of `length` characters, words separated by spaces, ending in `last`.
func long_title(length: int, last: String) -> String:
	var t: String = ""
	while t.length() < length - last.length() - 1:
		t += "Quantum field theory of nearly everything "
	return t.left(length - last.length() - 1).strip_edges() + " " + last


func _init() -> void:
	ProgressStore.file_override = "user://test_progress_names.json"   # never touch real progress
	JourneyStore.file_override = "user://test_journey_names.json"     # never touch the real journey
	var V: String = TestVault.open("names", false)
	test_long_title_note(V)
	test_long_titles_differing_at_the_end(V)
	test_filename_stem_is_short_and_pure()
	test_folder_names(V)
	test_clean_name_rules()
	test_app_non_latin_and_untitled(V)
	test_mixed_titles_stems(V)
	TestVault.remove_tree(V)
	var M: String = TestVault.open("names-mcp", false)
	test_mcp_non_latin_titles(M)
	test_mcp_mixed_titles(M)
	test_mcp_long_title(M)
	test_mcp_folder_names(M)
	test_mcp_refuses_asset_folder(M)
	TestVault.remove_tree(M)
	for f in [ProgressStore.file_override, JourneyStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)


func test_long_title_note(V: String) -> void:
	var title: String = long_title(360, "alpha")
	check(title.length() == 360, "the title has 360 characters")
	var note: ContentLayer = VaultStore.create_note(title)
	check(FileAccess.file_exists(note.resource_path), "a note with a 360-character title is written to disk (%s)" % note.resource_path.get_file())
	check(note.resource_path.get_file().length() <= 100, "its file name is short (%d characters)" % note.resource_path.get_file().length())
	VaultStore.refresh_note_list()
	var i: int = VaultStore.get_note_index(title)
	check(i >= 0 and VaultStore.note_list[i].resource_path == note.resource_path, "after a refresh it is listed")
	var on_disk: Resource = ResourceLoader.load(note.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	check(on_disk is ContentLayer and (on_disk as ContentLayer).title == title, "the file holds the full title")


func test_long_titles_differing_at_the_end(V: String) -> void:
	var a: ContentLayer = VaultStore.create_note(long_title(360, "first"))
	var b: ContentLayer = VaultStore.create_note(long_title(360, "second"))
	check(a.resource_path != b.resource_path and FileAccess.file_exists(a.resource_path) and FileAccess.file_exists(b.resource_path),
			"two 360-character titles differing only in their last word land in two files")
	check(VaultStore.get_note_index(a.title) >= 0 and VaultStore.get_note_index(b.title) >= 0, "both are listed")


func test_filename_stem_is_short_and_pure() -> void:
	var title: String = long_title(360, "alpha")
	var stem: String = VaultStore.filename_stem(title)
	check(stem.length() <= 5 + VaultStore.MAX_SLUG_CHARS, "a long title's stem is capped (%d characters)" % stem.length())
	check(stem == VaultStore.filename_stem(title), "the same title always gives the same stem")
	check(stem.begins_with("note_quantum_field_theory"), "the stem still starts with the title (%s)" % stem)
	check(VaultStore.filename_stem(long_title(360, "first")) != VaultStore.filename_stem(long_title(360, "second")),
			"long titles that differ only at the end get different stems")
	var cut: String = VaultStore.filename_stem("a" + "_".repeat(78) + "b".repeat(30))
	check(not cut.trim_suffix(cut.right(9)).ends_with("_") and not cut.trim_suffix(cut.right(9)).ends_with("-"),
			"a cut slug does not end in _ or - before its hash (%s)" % cut)
	check(VaultStore.filename_stem("My Note!") == "note_my_note" and VaultStore.filename_stem("untitled") == "note_untitled",
			"short titles are named as before")


func test_folder_names(V: String) -> void:
	var con: String = VaultStore.create_folder("CON")
	check(con != "" and con.to_upper() != "CON" and DirAccess.dir_exists_absolute(V + con), "create_folder('CON') makes a folder not named CON (%s)" % con)
	check(VaultStore.create_folder("Notes.") == "Notes" and DirAccess.dir_exists_absolute(V + "Notes"), "create_folder('Notes.') makes 'Notes'")
	check(VaultStore.create_folder("..notes") == "notes" and VaultStore.folders.has("notes"), "create_folder('..notes') makes a visible 'notes', not a hidden folder")
	check(VaultStore.create_folder("aux.txt", "Notes") == "Notes/aux_.txt", "a reserved name with an extension is made portable inside a folder")
	check(VaultStore.rename_folder("Notes", "prn") == "prn_" and DirAccess.dir_exists_absolute(V + "prn_"), "renaming a folder to PRN makes 'prn_'")
	var long_name: String = VaultStore.create_folder("Chapter ".repeat(30))
	check(long_name.length() <= VaultStore.MAX_NAME_CHARS and DirAccess.dir_exists_absolute(V + long_name), "a 240-character folder name is cut to %d (%d)" % [VaultStore.MAX_NAME_CHARS, long_name.length()])
	var cjk: String = VaultStore.create_folder("量子".repeat(60))
	check(cjk != "" and cjk.to_utf8_buffer().size() <= VaultStore.MAX_NAME_BYTES and DirAccess.dir_exists_absolute(V + cjk),
			"a 120-character Japanese folder name fits the 255-byte limit (%d bytes)" % cjk.to_utf8_buffer().size())


func test_clean_name_rules() -> void:
	var cases: Dictionary = {
		"Chapter 1.": "Chapter 1",
		"Chapter 1. . ": "Chapter 1",
		"...hidden": "hidden",
		". notes": "notes",
		"con": "con_",
		"Aux": "Aux_",
		"NUL.tar.gz": "NUL_.tar.gz",
		"com1": "com1_",
		"LPT9": "LPT9_",
		"COM¹": "COM¹_",
		"CONSOLE": "CONSOLE",
		"com10": "com10",
		"a:b*c?": "a-b-c-",
		"tab\there": "tab-here",
		"...": "",
	}
	for raw in cases:
		var got: String = VaultStore._clean_name(raw)
		check(got == cases[raw], "_clean_name(%s) == %s (got %s)" % [JSON.stringify(raw), JSON.stringify(cases[raw]), JSON.stringify(got)])
	var cut: String = VaultStore._clean_name("x".repeat(99) + " .y")
	check(cut == "x".repeat(99), "a name cut at %d characters loses the space and dot it then ends in (%s)" % [VaultStore.MAX_NAME_CHARS, JSON.stringify(cut.right(3))])


func test_mcp_long_title(M: String) -> void:
	var tools := VaultTools.new(M)
	var title: String = long_title(300, "omega")
	var r: Dictionary = tools.call_tool("create_note", {"title": title, "markdown": "Long."})
	check(not r.isError, "MCP create_note with a 300-character title succeeds (%s)" % data(r))
	var path: String = str(data(r).get("path", ""))
	check(path.get_file().get_basename() == VaultStore.filename_stem(title) and FileAccess.file_exists(M + path),
			"its file stem equals VaultStore.filename_stem(title)")
	var read: Dictionary = tools.call_tool("read_note", {"path": path})
	check(not read.isError and data(read).get("title") == title, "read_note gives back the full title")


func test_mcp_folder_names(M: String) -> void:
	var tools := VaultTools.new(M)
	var r: Dictionary = tools.call_tool("create_note", {"title": "In CON", "folder": "CON"})
	var path: String = str(data(r).get("path", ""))
	check(not r.isError and path.get_base_dir() == "CON_" and DirAccess.dir_exists_absolute(M + "CON_"), "MCP folder 'CON' becomes 'CON_' (%s)" % path)
	r = tools.call_tool("create_note", {"title": "In Notes", "folder": "Notes./Sub."})
	path = str(data(r).get("path", ""))
	check(not r.isError and path.get_base_dir() == "Notes/Sub", "MCP folder 'Notes./Sub.' becomes 'Notes/Sub' (%s)" % path)
	r = tools.call_tool("create_note", {"title": "Starred", "folder": "a*b"})
	check(not r.isError and str(data(r).get("path", "")).get_base_dir() == "a-b", "MCP folder 'a*b' becomes 'a-b' (%s)" % data(r).get("path", ""))
	check(err_code(tools.call_tool("create_note", {"title": "Hidden", "folder": "..notes"})) == "invalid_path", "MCP still refuses a hidden folder")
	if OS.get_name() == "Windows":
		return   # Windows can't hold a folder name ending in a dot
	# A folder made outside the app keeps its name: MCP finds it as it is.
	DirAccess.make_dir_recursive_absolute(M + "Odd.")
	r = tools.call_tool("create_note", {"title": "Odd one", "folder": "Odd."})
	check(not r.isError and str(data(r).get("path", "")).get_base_dir() == "Odd.", "MCP writes into an existing folder 'Odd.' as it is")
	var listed: Dictionary = tools.call_tool("list_notes", {"folder": "Odd."})
	check(not listed.isError and data(listed).get("count") == 1, "list_notes finds the existing folder 'Odd.'")


func test_app_non_latin_and_untitled(V: String) -> void:
	var untitled: ContentLayer = VaultStore.create_note("untitled")
	check(untitled.resource_path == V + "note_untitled.tres", "the app's New note still makes note_untitled.tres (%s)" % untitled.resource_path.get_file())
	var stem: String = VaultStore.filename_stem("量子")
	check(stem == "note_u" + "量子".sha256_text().left(8), "a title without Latin letters is named note_u<8 hex digits of its SHA-256> (%s)" % stem)
	check(VaultStore.filename_stem("波") != stem and VaultStore.filename_stem("Κύμα") != stem and VaultStore.filename_stem("Волна") != stem,
			"Japanese, Greek and Cyrillic titles get distinct stems")
	check(VaultStore.filename_stem(" 量子 ") == stem, "outer spaces do not change the stem")
	check(VaultStore.filename_stem("") == "note_untitled" and VaultStore.filename_stem("   ") == "note_untitled", "a blank title is note_untitled")
	check(VaultStore.filename_stem("量子 力学") != VaultStore.filename_stem("波 動"), "two-word titles without Latin letters get distinct stems too")
	var q: ContentLayer = VaultStore.create_note("量子")
	check(q.resource_path == V + stem + ".tres" and VaultStore.get_note_index("量子") >= 0, "the app writes the note 量子 to its own file")


func test_mixed_titles_stems(V: String) -> void:
	for pair in MIXED_PAIRS:
		var a: String = VaultStore.filename_stem(pair[0])
		var b: String = VaultStore.filename_stem(pair[1])
		check(a != b, "%s and %s get distinct stems (%s, %s)" % [pair[0], pair[1], a, b])
	var stem: String = VaultStore.filename_stem("Godot入門")
	check(stem == "note_godot_" + "Godot入門".sha256_text().left(8), "a title mixing Latin and other letters keeps its Latin part and adds the hash (%s)" % stem)
	check(VaultStore.filename_stem("第2章 量子") == "note_2_" + "第2章 量子".sha256_text().left(8), "a cut slug ending in _ loses it before the hash (%s)" % VaultStore.filename_stem("第2章 量子"))
	check(VaultStore.filename_stem("Bob’s notes — draft") == "note_bobs_notes__draft", "punctuation outside ASCII adds no hash: an ASCII-looking title is named as before")
	check(VaultStore.filename_stem("Godot 4 basics") == "note_godot_4_basics", "an ASCII title is named as before")
	var long_mixed: String = long_title(300, "量子")
	var long_stem: String = VaultStore.filename_stem(long_mixed)
	check(long_stem.length() <= 5 + VaultStore.MAX_SLUG_CHARS and long_stem.ends_with("_" + long_mixed.sha256_text().left(8)),
			"a long mixed title is cut once and ends in one hash (%s)" % long_stem)
	var a_note: ContentLayer = VaultStore.create_note("Godot入門")
	var b_note: ContentLayer = VaultStore.create_note("Godot応用")
	check(a_note.resource_path.get_file() == stem + ".tres" and b_note.resource_path.get_file() == VaultStore.filename_stem("Godot応用") + ".tres",
			"the app writes Godot入門 and Godot応用 to their own stems (%s, %s)" % [a_note.resource_path.get_file(), b_note.resource_path.get_file()])


func test_mcp_non_latin_titles(M: String) -> void:
	var tools := VaultTools.new(M)
	var quantum: Dictionary = tools.call_tool("create_note", {"title": "量子", "markdown": "Quantum."})
	var wave: Dictionary = tools.call_tool("create_note", {"title": "波", "markdown": "Wave."})
	check(not quantum.isError and not wave.isError, "MCP create_note('量子') and create_note('波') both succeed (%s, %s)" % [data(quantum), data(wave)])
	check(data(quantum).get("path", "") != data(wave).get("path", ""), "they get different paths")
	var titles: Array = data(tools.call_tool("list_notes", {})).get("notes", []).map(func(n): return n.title)
	check(titles.has("量子") and titles.has("波"), "list_notes returns both (%s)" % [titles])
	var again: Dictionary = tools.call_tool("create_note", {"title": "量子"})
	check(again.isError and err_code(again) == "exists", "create_note('量子') a second time is refused with exists, so a retry is safe")
	check(not tools.call_tool("create_note", {"title": "untitled"}).isError and not tools.call_tool("create_note", {"title": "Κύμα"}).isError,
			"an 'untitled' note does not block a Greek title")


## An agent told `exists` reads the note and updates it, so `exists` must
## mean this very title is already there, not another title that shares
## its Latin letters or digits.
func test_mcp_mixed_titles(M: String) -> void:
	var tools := VaultTools.new(M)
	for pair in MIXED_PAIRS:
		var a: Dictionary = tools.call_tool("create_note", {"title": pair[0], "markdown": "First."})
		var b: Dictionary = tools.call_tool("create_note", {"title": pair[1], "markdown": "Second."})
		check(not a.isError and not b.isError and data(a).get("path") != data(b).get("path"),
				"MCP create_note(%s) then create_note(%s) both succeed, in two files (%s, %s)" % [pair[0], pair[1], data(a), data(b)])
	var again: Dictionary = tools.call_tool("create_note", {"title": "Глава 1"})
	check(again.isError and err_code(again) == "exists", "create_note('Глава 1') a second time is refused with exists")
	var read: Dictionary = tools.call_tool("read_note", {"path": data(again).get("error", {}).get("path", "")})
	check(not read.isError and data(read).get("title") == "Глава 1", "and the path it names holds that very title")


func test_mcp_refuses_asset_folder(M: String) -> void:
	var tools := VaultTools.new(M)
	for folder in ["models", "models/", "./models", "models."]:
		var r: Dictionary = tools.call_tool("create_note", {"title": "Hidden", "folder": folder})
		check(r.isError and err_code(r) == "invalid_path", "create_note with folder %s is refused with invalid_path (%s)" % [JSON.stringify(folder), err_code(r)])
	check(not DirAccess.dir_exists_absolute(M + "models"), "no models/ folder was made")
	check(err_code(tools.call_tool("list_notes", {"folder": "models"})) == "invalid_path", "list_notes refuses folder models too")
	var sub: Dictionary = tools.call_tool("create_note", {"title": "Model notes", "folder": "Physics/models"})
	check(not sub.isError and str(data(sub).get("path", "")).begins_with("Physics/models/"), "a models folder below the top level is an ordinary folder")
