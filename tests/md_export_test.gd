extends SceneTree
## MdExport.to_markdown: front-matter, wikilink rewrite, code-skip, dangling
## links — pure converter, no scene. Fixture notes in a throwaway vault.
##   headless:  godot --headless --path . -s res://tests/md_export_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")

var fails: int = 0


## Collects the engine errors logged while it is added (OS.add_logger), so a
## check can show that a failure export_note handles printed no "ERROR:" line.
class ErrorCatcher extends Logger:
	var errors: PackedStringArray = []
	var _lock := Mutex.new()

	func _log_error(_function: String, _file: String, _line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		_lock.lock()
		errors.append(rationale if rationale != "" else code)
		_lock.unlock()


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


## Fail with the first differing line shown, for a readable diff.
func check_md(actual: String, expected: String, what: String) -> void:
	if actual == expected:
		check(true, what)
		return
	check(false, what)
	var a: PackedStringArray = actual.split("\n")
	var b: PackedStringArray = expected.split("\n")
	for i in range(max(a.size(), b.size())):
		var la: String = a[i] if i < a.size() else "<missing>"
		var lb: String = b[i] if i < b.size() else "<missing>"
		if la != lb:
			print("      line %d:\n        got      %s\n        expected %s" % [i + 1, la, lb])
			break


## The production link map for an export file in `from_folder`.
func links_from(from_folder: String) -> Dictionary:
	return MdExport.link_map(VaultStore.note_list, VaultStore.vault_path, from_folder)


## Markdown of an unsaved note in `folder` whose body is `body`.
func convert_in(folder: String, body: String) -> String:
	var n := ContentLayer.new()
	n.title = "Probe"
	n.raw_text = body
	return MdExport.to_markdown(n, links_from(folder))


func frames(n: int = 2) -> void:
	for i in range(n):
		await process_frame


## Write `text` to the absolute `path`, creating its folder.
func write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## Names of the .md files directly in `dir`, sorted.
func md_files(dir: String) -> PackedStringArray:
	var names: PackedStringArray = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".md"):
			names.append(f)
	names.sort()
	return names


## Every .md file at or below `dir`, absolute paths, sorted.
func md_under(dir: String) -> PackedStringArray:
	var found: PackedStringArray = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".md"):
			found.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		found.append_array(md_under(dir.path_join(d)))
	found.sort()
	return found


## The lines of an exported file that the converter rewrites: outside fenced
## blocks, with `code spans` blanked (the renderer's rules, written out
## again here so the check does not trust the code it checks).
func prose_lines(text: String) -> PackedStringArray:
	var code_rx := RegEx.create_from_string("`[^`]+`")
	var lines: PackedStringArray = []
	var fence: int = 0   # backticks of the open fence, 0 outside one
	for line in text.split("\n"):
		var s: String = line.strip_edges()
		var ticks: int = 0
		while ticks < s.length() and s[ticks] == "`":
			ticks += 1
		if ticks < 3:
			ticks = 0
		if fence > 0:
			if ticks >= fence and s.substr(ticks).strip_edges() == "":
				fence = 0
		elif ticks > 0:
			fence = ticks
		else:
			lines.append(code_rx.sub(line, "", true))
	return lines


## SHA-256 of every note file in the open vault, by path.
func tres_hashes() -> Dictionary:
	var h: Dictionary = {}
	for n in VaultStore.note_list:
		h[n.resource_path] = FileAccess.get_sha256(n.resource_path)
	return h


## Export All and Export folder over the seeded test vault (tutorials and
## the Godot course): every note gets its twin, every link written resolves
## on disk, and the vault itself is never touched.
func check_export_vault() -> void:
	var V: String = TestVault.open("md-export-all")
	var out: String = V.path_join(MdExport.EXPORT_DIR)
	check("Godot" in VaultStore.folders and "Tutorials" in VaultStore.folders,
		"fixture: the seeded vault, %d notes in Godot/, Tutorials/ and the top level" % VaultStore.note_list.size())
	# The seeded notes link only within their folder. Two more link across
	# folders, one from a folder whose name needs percent-encoding, so the
	# on-disk check covers ../ and %20 as well.
	var map := VaultStore.create_note("Map", VaultStore.create_folder("Deep", VaultStore.create_folder("New folder")))
	map.raw_text = "Start at [[Start Here: Tutorials]], then [[Nodes and Scenes|the nodes]] and [[Quiz: Ontomeme]]."
	VaultStore.save_note(map)
	var index := VaultStore.create_note("Index")
	index.raw_text = "Everything is on the [[Map]]."
	VaultStore.save_note(index)
	# A second "New folder" is "New folder 2": a sibling whose name starts
	# with the first one's, which Export folder on "New folder" leaves out.
	var sibling: String = VaultStore.create_folder("New folder")
	VaultStore.create_note("Neighbour", sibling)
	VaultStore.refresh_note_list()
	var count: int = VaultStore.note_list.size()
	var titles: Dictionary = {}
	for n in VaultStore.note_list:
		titles[n.title.strip_edges().to_lower()] = true
	var sig: String = VaultStore.disk_signature()
	var hashes: Dictionary = tres_hashes()

	var r: Dictionary = MdExport.export_vault()
	check(r.written == count and (r.failed as Array).is_empty() and r.out == out,
		"export_vault() writes every note (%d of %d, failed %s)" % [r.written, count, str(r.failed)])
	var missing: PackedStringArray = []
	for n in VaultStore.note_list:
		if not FileAccess.file_exists(out.path_join(MdExport.export_rel_path(n, V))):
			missing.append(MdExport.export_rel_path(n, V))
	check(missing.is_empty(), "every note has its twin at exports/<export_rel_path> %s" % str(missing))
	var files: PackedStringArray = md_under(out)
	check(files.size() == count, "exports/ holds exactly one .md per note (%d)" % files.size())

	# Every link the export wrote resolves to a file on disk; every [[T]]
	# left literal names a title the vault does not have.
	var link_rx := RegEx.create_from_string("\\]\\(([^()\\s]+\\.md)\\)")
	var wiki_rx := RegEx.create_from_string("\\[\\[([^\\]|]+)(?:\\|[^\\]]+)?\\]\\]")
	var links: int = 0
	var cross: int = 0
	var broken: PackedStringArray = []
	var kept: PackedStringArray = []
	for f in files:
		for line in prose_lines(FileAccess.get_file_as_string(f)):
			for m in link_rx.search_all(line):
				links += 1
				if m.get_string(1).begins_with("../"):
					cross += 1
				if not FileAccess.file_exists(f.get_base_dir().path_join(m.get_string(1).uri_decode()).simplify_path()):
					broken.append("%s -> %s" % [f.trim_prefix(out), m.get_string(1)])
			for m in wiki_rx.search_all(line):
				if titles.has(m.get_string(1).strip_edges().to_lower()):
					kept.append("%s: %s" % [f.trim_prefix(out), m.get_string()])
	check(links > 0 and cross > 0, "fixture: the export has links to check (%d, %d across folders)" % [links, cross])
	check(broken.is_empty(), "every .md link target outside code exists on disk %s" % str(broken))
	check(kept.is_empty(), "every [[link]] left outside code names a title the vault lacks %s" % str(kept))

	check(VaultStore.disk_signature() == sig, "exporting the vault leaves disk_signature unchanged")
	VaultStore.refresh_note_list()
	check(not (MdExport.EXPORT_DIR in VaultStore.folders) and VaultStore.note_list.size() == count,
		"after a refresh, exports is no folder and the note list is unchanged")
	check(tres_hashes() == hashes, "every .tres keeps its SHA-256")

	# ── Export folder: only that folder's notes ──
	TestVault.remove_tree(out)
	var tutorials: PackedStringArray = []
	for n in VaultStore.note_list:
		if VaultStore.folder_of(n) == "Tutorials":
			tutorials.append(out.path_join(MdExport.export_rel_path(n, V)))
	tutorials.sort()
	r = MdExport.export_folder("Tutorials")
	check(r.written == tutorials.size() and (r.failed as Array).is_empty(),
		"export_folder(\"Tutorials\") writes its %d notes" % tutorials.size())
	check(md_under(out) == tutorials, "... and only those (%d files under exports/)" % md_under(out).size())
	write_text(out.path_join("Tutorials/note_stale.md"), "from an earlier export\n")
	MdExport.export_folder("Tutorials")
	check(FileAccess.file_exists(out.path_join("Tutorials/note_stale.md")), "an export never deletes older .md files")

	# A parent folder takes its subfolders: "New folder" holds no note of
	# its own, only Deep/Map. Its sibling "New folder 2" is not below it,
	# though its name starts with "New folder".
	check(sibling == "New folder 2" and VaultStore.folder_of(map) == "New folder/Deep",
		"fixture: Map in New folder/Deep, a sibling folder \"%s\"" % sibling)
	TestVault.remove_tree(out)
	r = MdExport.export_folder("New folder")
	check(r.written == 1 and (r.failed as Array).is_empty(),
		"export_folder(\"New folder\") writes the note in its subfolder Deep (%d written)" % r.written)
	check(md_under(out) == PackedStringArray([out.path_join("New folder/Deep/note_map.md")]),
		"... exactly exports/New folder/Deep/note_map.md, nothing from \"New folder 2\" %s" % str(md_under(out)))
	TestVault.remove_tree(out)
	r = MdExport.export_folder(sibling)
	check(r.written == 1 and md_under(out) == PackedStringArray([out.path_join("New folder 2/note_neighbour.md")]),
		"export_folder(\"New folder 2\") writes only its own note %s" % str(md_under(out)))

	check(MdExport.export_folder("Nowhere").written == 0 and MdExport.last_error == "", "a folder without notes writes nothing")
	r = MdExport.export_folder("")
	check(r.written == count, "export_folder(\"\") is the whole vault")

	# An export root that is a folder of notes is refused for every note
	r = MdExport.export_vault(V + "Tutorials")
	check(r.written == 0 and (r.failed as Array).size() == count and MdExport.last_error.contains("already holds notes")
			and not FileAccess.file_exists(V + "Tutorials/" + MdExport.MARKER),
		"export_vault into a notes folder writes nothing and lists every note as failed")
	check(tres_hashes() == hashes, "the folder exports left every .tres alone too")
	TestVault.remove_tree(V)


## SHA-256 of each file directly in user:// (vaults.json, display.json…),
## by name: where an app-wide setting would be written.
func user_root_files() -> Dictionary:
	var h: Dictionary = {}
	for f in DirAccess.get_files_at("user://"):
		h[f] = FileAccess.get_sha256("user://" + f)
	return h


## The "out_dir" saved in export.json at `settings`, or "" if none.
func saved_out_dir(settings: String) -> String:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(settings)) if FileAccess.file_exists(settings) else null
	return str((v as Dictionary).get("out_dir", "")) if v is Dictionary else ""


## Plan phase 6: each vault has its own export folder, saved in
## <vault>/.ontomeme/export.json; export_note, export_vault and
## export_folder default to it; the vault, folders around it, .ontomeme and
## folders of notes are refused.
func check_output_root() -> void:
	var V: String = TestVault.open("md-export-out", false)
	var wave := VaultStore.create_note("Wave", VaultStore.create_folder("Physics"))
	wave.raw_text = "See [[Top]]."
	VaultStore.save_note(wave)
	VaultStore.create_note("Top")
	VaultStore.refresh_note_list()
	var settings: String = V.path_join(".ontomeme").path_join(MdExport.SETTINGS_FILE)
	var default: String = V.path_join(MdExport.EXPORT_DIR)
	var abs_out: String = ProjectSettings.globalize_path("user://test-md-export-out")
	TestVault.remove_tree(abs_out)
	var user_files: Dictionary = user_root_files()
	check(MdExport.output_root() == default and not FileAccess.file_exists(settings),
		"with nothing saved, output_root() is <vault>/exports")

	# ── An absolute folder outside the vault ──
	check(MdExport.set_output_root(abs_out) == OK and MdExport.last_error == "", "set_output_root(<absolute folder>) is OK")
	check(saved_out_dir(settings) == abs_out, "... saved as out_dir in <vault>/.ontomeme/export.json")
	check(MdExport.output_root() == abs_out and not DirAccess.dir_exists_absolute(abs_out),
		"output_root() returns it; nothing is created before an export")
	var written: String = MdExport.export_note(wave)
	check(written == abs_out.path_join("Physics/note_wave.md") and FileAccess.file_exists(written),
		"export_note writes <set folder>/Physics/note_wave.md")
	check(not DirAccess.dir_exists_absolute(default), "... and nothing appears under V/exports")
	TestVault.remove_tree(abs_out)
	var r: Dictionary = MdExport.export_vault()
	check(r.out == abs_out and r.written == 2 and md_under(abs_out).size() == 2, "export_vault() defaults to the set folder")
	r = MdExport.export_folder("Physics")
	check(r.out == abs_out and r.written == 1, "export_folder() defaults to it too")
	check(not DirAccess.dir_exists_absolute(default), "still nothing under V/exports")

	# ── Saved per vault ──
	VaultStore.open_vault(V, false)
	check(MdExport.output_root() == abs_out, "after open_vault(V) again, output_root() still returns the set folder (from export.json)")
	var W: String = TestVault.open("md-export-out-other", false)
	check(MdExport.output_root() == W.path_join(MdExport.EXPORT_DIR), "another vault keeps its own default, <W>/exports")
	TestVault.remove_tree(W)
	VaultStore.open_vault(V, false)

	# ── A folder in the vault, given relative to it ──
	check(MdExport.set_output_root("out/md") == OK and MdExport.output_root() == V + "out/md",
		"set_output_root(\"out/md\") resolves against the vault: output_root() is V/out/md")
	written = MdExport.export_note(wave)
	check(written == V + "out/md/Physics/note_wave.md" and FileAccess.file_exists(written), "export_note writes V/out/md/Physics/note_wave.md")
	VaultStore.refresh_note_list()
	check(not ("out/md" in VaultStore.folders) and not ("out/md/Physics" in VaultStore.folders) and VaultStore.note_list.size() == 2,
		"\"out/md\" is not in VaultStore.folders (marker skip), the note list is unchanged")
	check(MdExport.set_output_root(V + "out/md") == OK and saved_out_dir(settings) == "out/md",
		"an absolute folder inside the vault is saved relative to it, so the setting moves with the vault")
	check(MdExport.set_output_root("../" + abs_out.get_file()) == OK and saved_out_dir(settings) == abs_out
			and MdExport.output_root() == abs_out,
		"a relative path that leaves the vault is saved as the absolute folder")
	MdExport.set_output_root("out/md")

	# ── Refused: the vault, folders around it, .ontomeme, notes, a file ──
	write_text(V + "blocker.txt", "a regular file\n")
	var saved: String = FileAccess.get_file_as_string(settings)
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	var refused: Dictionary = {}   # what -> [error, last_error]
	for p in [V, V.trim_suffix("/"), "", ".", "Physics/..", V.trim_suffix("/").get_base_dir(), "/",
			".ontomeme", V + ".ontomeme/exports", "Physics", V + "blocker.txt/out"]:
		var err: Error = MdExport.set_output_root(p)
		refused[p] = [err, MdExport.last_error]
	OS.remove_logger(catcher)
	check(refused[V][0] == ERR_INVALID_PARAMETER and refused[V][1].contains("is the vault itself"),
		"set_output_root(V) is refused with an error (%s)" % refused[V][1])
	check(refused[V.trim_suffix("/")][0] == ERR_INVALID_PARAMETER and refused[""][0] == ERR_INVALID_PARAMETER
			and refused["."][0] == ERR_INVALID_PARAMETER and refused["Physics/.."][0] == ERR_INVALID_PARAMETER,
		"... also without the trailing /, and as \"\", \".\" and \"Physics/..\"")
	check(refused[V.trim_suffix("/").get_base_dir()][0] == ERR_INVALID_PARAMETER and refused["/"][0] == ERR_INVALID_PARAMETER
			and refused["/"][1].contains("holds the vault"),
		"a folder the vault lies in is refused")
	check(refused[".ontomeme"][0] == ERR_INVALID_PARAMETER and refused[V + ".ontomeme/exports"][0] == ERR_INVALID_PARAMETER
			and refused[".ontomeme"][1].contains(".ontomeme folder"),
		"the vault's .ontomeme and anything inside it are refused")
	check(refused["Physics"][0] == ERR_ALREADY_IN_USE and refused["Physics"][1].contains("already holds notes"),
		"a folder of notes without the marker is refused (ERR_ALREADY_IN_USE)")
	check(refused[V + "blocker.txt/out"][0] == ERR_FILE_BAD_PATH and refused[V + "blocker.txt/out"][1].contains("blocker.txt is a file"),
		"a folder under a regular file is refused (ERR_FILE_BAD_PATH)")
	check(FileAccess.get_file_as_string(settings) == saved and MdExport.output_root() == V + "out/md",
		"a refused folder leaves the saved one as it was")
	check(catcher.errors.is_empty() and not FileAccess.file_exists(V + MdExport.MARKER)
			and not FileAccess.file_exists(V + "Physics/" + MdExport.MARKER),
		"refusing writes no marker and logs no engine ERROR line")
	DirAccess.remove_absolute(V + "blocker.txt")

	# ── Folders slow to check for notes: symlink loops, huge trees ──
	check_scan_bounds(V, wave)
	MdExport.set_output_root("out/md")

	# ── A hand-edited or broken export.json ──
	write_text(settings, JSON.stringify({"out_dir": V}))
	check(MdExport.export_note(wave) == "" and MdExport.last_error.contains("is the vault itself")
			and not FileAccess.file_exists(V + "Physics/note_wave.md") and not FileAccess.file_exists(V + MdExport.MARKER),
		"export_note refuses a saved out_dir that names the vault, writing nothing")
	write_text(settings, "{ not json")
	check(MdExport.output_root() == default, "an unreadable export.json falls back to <vault>/exports")
	check(MdExport.set_output_root(abs_out) == OK and saved_out_dir(settings) == abs_out, "set_output_root replaces an unreadable export.json")

	# ── Clear ──
	check(MdExport.clear_output_root() == OK and MdExport.output_root() == default and not FileAccess.file_exists(settings),
		"clear_output_root() brings exports back to V/exports and removes export.json")
	written = MdExport.export_note(wave)
	check(written == default.path_join("Physics/note_wave.md") and FileAccess.file_exists(written), "export_note writes V/exports/Physics/note_wave.md again")
	check(MdExport.clear_output_root() == OK and MdExport.last_error == "", "clearing with nothing saved is OK")

	check(user_root_files() == user_files, "setting and clearing the export folder changed no file in user://")
	check(not FileAccess.get_file_as_string("res://md_export.gd").contains("user://"), "md_export.gd names no user:// path")
	TestVault.remove_tree(abs_out)
	TestVault.remove_tree(V)


## TestVault.remove_tree, except that a symlinked folder is unlinked, never
## entered: these fixtures link back to their own folder and into the vault.
func remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	for d in dir.get_directories():
		if dir.is_link(path.path_join(d)):
			DirAccess.remove_absolute(path.path_join(d))
		else:
			remove_dir(path.path_join(d))
	for f in dir.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


## Picking an export folder checks it for notes on the main thread, in
## set_output_root and again before the first export into it, so that check
## must end fast whatever the folder holds. Review of batch 3: a folder with
## two links back to itself never returned (the walk followed every link
## down to depth 32, about 2^33 calls), and /usr/share froze the app for
## 2.6 s. If the unbounded walk comes back, this hangs on the loop and
## run_all.sh's timeout fails the test.
func check_scan_bounds(V: String, wave: ContentLayer) -> void:
	var base: String = ProjectSettings.globalize_path("user://test-md-export-scan")
	remove_dir(base)
	var wave_file: String = wave.resource_path
	var wave_sha: String = FileAccess.get_sha256(wave_file)

	# A loop: links to itself (relative, ../loop, and absolute) and, from a subfolder,
	# to its parent. And a folder whose only notes are behind a link.
	var loop: String = base.path_join("loop")
	var linked: String = base.path_join("linked")
	DirAccess.make_dir_recursive_absolute(loop.path_join("sub"))
	DirAccess.make_dir_recursive_absolute(linked)
	var d := DirAccess.open(loop)
	var links_made: bool = d.create_link("../loop", "self") == OK and d.create_link(loop, "again") == OK \
			and d.create_link("..", "sub/up") == OK \
			and DirAccess.open(linked).create_link(wave_file.get_base_dir(), "notes") == OK
	check(links_made or OS.get_name() == "Windows", "fixture: symlinks made (Windows needs Developer Mode for them)")
	if links_made:
		var t0: int = Time.get_ticks_msec()
		var err: Error = MdExport.set_output_root(loop)
		check(err == OK and MdExport.output_root() == loop,
			"a folder with links back to itself and its parent is accepted, in %d ms (it hung before)" % (Time.get_ticks_msec() - t0))
		var out_file: String = MdExport.export_note(wave)
		check(out_file == loop.path_join("Physics/note_wave.md") and FileAccess.file_exists(out_file)
				and FileAccess.file_exists(loop.path_join(MdExport.MARKER)),
			"... and the first export, which checks it again, writes the note and the marker there")
		check(MdExport.set_output_root(linked) == ERR_ALREADY_IN_USE and MdExport.last_error.contains("already holds notes")
				and MdExport.output_root() == loop and not FileAccess.file_exists(linked.path_join(MdExport.MARKER)),
			"a folder whose only notes sit behind a symlink is refused (links are followed, once each)")

	# A folder with more entries than the check reads: refused, not walked.
	var big: String = base.path_join("big")
	DirAccess.make_dir_recursive_absolute(big)
	for i in range(MdExport.SCAN_LIMIT + 1):
		FileAccess.open(big.path_join("f%05d.txt" % i), FileAccess.WRITE).close()
	var before: String = MdExport.output_root()
	var t1: int = Time.get_ticks_msec()
	var big_err: Error = MdExport.set_output_root(big)
	var big_ms: int = Time.get_ticks_msec() - t1
	check(big_err == ERR_TIMEOUT and MdExport.last_error.contains("too many to check for notes")
			and MdExport.output_root() == before,
		"a folder of %d entries (over SCAN_LIMIT) is refused with ERR_TIMEOUT in %d ms, saving nothing (%s)"
			% [MdExport.SCAN_LIMIT + 1, big_ms, MdExport.last_error])
	check(MdExport.prepare_out_dir(big) == ERR_TIMEOUT and MdExport.export_note(wave, big) == ""
			and MdExport.last_error.contains("too many to check for notes")
			and not FileAccess.file_exists(big.path_join(MdExport.MARKER)) and not DirAccess.dir_exists_absolute(big.path_join("Physics")),
		"... and an export into it is refused too, writing no marker and no note")
	DirAccess.remove_absolute(big.path_join("f00000.txt"))
	check(MdExport.set_output_root(big) == OK and MdExport.output_root() == big,
		"with exactly SCAN_LIMIT entries and no notes, the same folder is accepted")

	MdExport.set_output_root(before)
	remove_dir(base)
	check(not DirAccess.dir_exists_absolute(base) and FileAccess.get_sha256(wave_file) == wave_sha,
		"the fixtures are gone and the note behind the link is untouched")


func _init() -> void:
	TestVault.hold()   # before any await, or the autoload opens the real vault
	await frames()
	JourneyStore.file_override = "user://test_journey_md_export.json"
	ProgressStore.file_override = "user://test_progress_md_export.json"
	ProgressStore.reset()
	JourneyStore.reset()

	# ── Throwaway vault ──
	var V: String = ProjectSettings.globalize_path("user://test-vault-md-export/")
	TestVault.remove_tree(V)
	DirAccess.make_dir_recursive_absolute(V)
	VaultStore.open_vault(V, false)
	VaultStore.create_folder("Physics")

	# The rule-exercising note, in Physics/
	var wave := VaultStore.create_note("Wave Basics", "Physics")
	wave.raw_text = \
		"# Wave Basics\n" \
		+ "\n" \
		+ "Intro with **bold**, *italic* and `inline [[Nope]] code`.\n" \
		+ "\n" \
		+ "Same folder: [[Sine]] and [[Superposition|stack]]. Lowercase [[sine]] too.\n" \
		+ "Cross folder up: [[Start Here]].\n" \
		+ "Dangling: [[Missing Note]] and [[Missing|gone]].\n" \
		+ "\n" \
		+ "```\n" \
		+ "# not a heading\n" \
		+ "[[Inside Fence]] stays\n" \
		+ "```\n" \
		+ "\n" \
		+ "```3d\n" \
		+ "preset: quiz\n" \
		+ "q: Which wave is right?\n" \
		+ "a: [[Sine]]\n" \
		+ "```\n" \
		+ "\n" \
		+ "model: robot.glb"
	wave.tags = ["waves", "physics", "tag with, comma"]
	wave.created = "2026-01-02T03:04:05"
	wave.modified = "2026-01-02T03:05:06"
	VaultStore.save_note(wave, false)

	var start := VaultStore.create_note("Start Here")
	start.raw_text = "Welcome.\n\nDeep link: [[Wave Basics|the waves]].\nNo tags here."
	start.created = "2026-01-01T00:00:00"
	start.modified = "2026-01-01T00:00:01"
	VaultStore.save_note(start, false)

	var sine := VaultStore.create_note("Sine", "Physics")
	sine.raw_text = "y = sin(x)\n\nSee [[Wave Basics]]."
	sine.created = "2026-01-03T00:00:00"
	sine.modified = "2026-01-03T00:00:00"
	VaultStore.save_note(sine, false)

	var superpos := VaultStore.create_note("Superposition", "Physics")
	superpos.raw_text = "Two waves."
	superpos.tags = ["waves"]
	superpos.created = "2026-01-04T00:00:00"
	superpos.modified = "2026-01-04T00:00:00"
	VaultStore.save_note(superpos, false)

	# The .tres names the export stems (plan: stem + .md, same subfolder)
	check(VaultStore.folder_of(wave) == "Physics" and wave.resource_path == V + "Physics/note_wave_basics.tres",
		"fixture lands at Physics/note_wave_basics.tres")
	check(start.resource_path == V + "note_start_here.tres", "top-level fixture at note_start_here.tres")

	# ── Pure converter: diff every fixture against expected .md text ──
	var map: Dictionary = links_from("Physics")
	var wave_md: String = \
		"---\n" \
		+ "title: \"Wave Basics\"\n" \
		+ "created: \"2026-01-02T03:04:05\"\n" \
		+ "modified: \"2026-01-02T03:05:06\"\n" \
		+ "tags: [\"waves\", \"physics\", \"tag with, comma\"]\n" \
		+ "---\n" \
		+ "\n" \
		+ "# Wave Basics\n" \
		+ "\n" \
		+ "Intro with **bold**, *italic* and `inline [[Nope]] code`.\n" \
		+ "\n" \
		+ "Same folder: [Sine](note_sine.md) and [stack](note_superposition.md). Lowercase [sine](note_sine.md) too.\n" \
		+ "Cross folder up: [Start Here](../note_start_here.md).\n" \
		+ "Dangling: [[Missing Note]] and [[Missing|gone]].\n" \
		+ "\n" \
		+ "```\n" \
		+ "# not a heading\n" \
		+ "[[Inside Fence]] stays\n" \
		+ "```\n" \
		+ "\n" \
		+ "```3d\n" \
		+ "preset: quiz\n" \
		+ "q: Which wave is right?\n" \
		+ "a: [[Sine]]\n" \
		+ "```\n" \
		+ "\n" \
		+ "model: robot.glb\n"
	check_md(MdExport.to_markdown(wave, map), wave_md,
		"Wave Basics converts: headings/bold/italic pass, links resolve same/cross/lowercase, dangling + code stay literal, fences pass")

	check_md(MdExport.to_markdown(start, links_from("")), \
		"---\n" \
		+ "title: \"Start Here\"\n" \
		+ "created: \"2026-01-01T00:00:00\"\n" \
		+ "modified: \"2026-01-01T00:00:01\"\n" \
		+ "tags: []\n" \
		+ "---\n" \
		+ "\n" \
		+ "Welcome.\n" \
		+ "\n" \
		+ "Deep link: [the waves](Physics/note_wave_basics.md).\n" \
		+ "No tags here.\n", "Start Here converts: no tags -> tags: [], link into a subfolder is Physics/...")

	check_md(MdExport.to_markdown(sine, links_from("Physics")), \
		"---\n" \
		+ "title: \"Sine\"\n" \
		+ "created: \"2026-01-03T00:00:00\"\n" \
		+ "modified: \"2026-01-03T00:00:00\"\n" \
		+ "tags: []\n" \
		+ "---\n" \
		+ "\n" \
		+ "y = sin(x)\n" \
		+ "\n" \
		+ "See [Wave Basics](note_wave_basics.md).\n", "Sine converts: same-folder link uses the plain stem")

	check_md(MdExport.to_markdown(superpos, links_from("Physics")), \
		"---\n" \
		+ "title: \"Superposition\"\n" \
		+ "created: \"2026-01-04T00:00:00\"\n" \
		+ "modified: \"2026-01-04T00:00:00\"\n" \
		+ "tags: [\"waves\"]\n" \
		+ "---\n" \
		+ "\n" \
		+ "Two waves.\n", "Superposition converts: single quoted tag, plain body")

	# Spot-check the rules that the diff could miss in a long note
	var md: String = MdExport.to_markdown(wave, map)
	check(not md.contains("](../note_missing"), "dangling targets are never invented")
	check(md.contains("[[Missing|gone]]"), "dangling alias link keeps its alias, literally")
	check(md.contains("a: [[Sine]]") and not md.contains("a: [Sine]("),
		"links inside a ```3d block are never rewritten")

	# ── The export folder stays out of the sidebar and the disk watcher ──
	var out: String = V + MdExport.EXPORT_DIR
	var notes_before: int = VaultStore.note_list.size()
	var sig_before: String = VaultStore.disk_signature()
	check(MdExport.prepare_out_dir(out) == OK, "prepare_out_dir creates <vault>/exports")
	check(FileAccess.file_exists(out.path_join(MdExport.MARKER)), "prepare_out_dir writes the .ontomeme-export marker")
	write_text(out.path_join("Physics/x.md"), "# x\n")
	VaultStore.refresh_note_list()
	check(not ("exports" in VaultStore.folders) and not ("exports/Physics" in VaultStore.folders),
		"a marked exports/ (and its subfolders) is not a sidebar folder")
	check(VaultStore.note_list.size() == notes_before, "the note list is unchanged by an export folder")
	check(VaultStore.disk_signature() == sig_before, "disk_signature is unchanged, so the watcher does not fire")
	check(MdExport.prepare_out_dir(out) == OK, "prepare_out_dir on an already marked folder is OK")
	# The MCP tools scan their own vault, not the app's open one: the marker
	# is looked for under the vault being scanned (_should_descend's root)
	write_text(out.path_join("Physics/stray.txt"), "not a note\n")
	var open_vault: String = VaultStore.vault_path
	VaultStore.vault_path = ProjectSettings.globalize_path("user://test-vault-md-export-elsewhere/")
	var mcp_paths: Array = []
	for entry: Dictionary in VaultTools.new(V).call_tool("list_notes", {}).structuredContent.get("notes", []):
		mcp_paths.append(str(entry.get("path", "")))
	var descends: bool = VaultStore._should_descend(V, "", MdExport.EXPORT_DIR, {}, false)
	VaultStore.vault_path = open_vault
	check(not descends and not ("exports/Physics/stray.txt" in mcp_paths) and not mcp_paths.is_empty(),
		"VaultTools leaves out a marked folder of its vault while the app has another open (%s)" % [mcp_paths])

	check(MdExport.prepare_out_dir(V + "Physics/out") == OK, "prepare_out_dir marks a nested folder")
	VaultStore.refresh_note_list()
	check("Physics" in VaultStore.folders and not ("Physics/out" in VaultStore.folders),
		"a marked folder at Physics/out is hidden too, its parent is not")
	check(VaultStore.disk_signature() == sig_before, "a nested marked folder leaves disk_signature unchanged")
	TestVault.remove_tree(out)
	TestVault.remove_tree(V + "Physics/out")

	# ── export_note writes one note to exports/<folder>/<stem>.md ──
	check(not DirAccess.dir_exists_absolute(out), "exports/ does not exist before the first export")
	var wave_sha: String = FileAccess.get_sha256(wave.resource_path)
	var count_before: int = VaultStore.note_list.size()
	var written: String = MdExport.export_note(wave)
	check(written == V + "exports/Physics/note_wave_basics.md" and MdExport.last_error == "",
		"export_note(wave) returns V/exports/Physics/note_wave_basics.md")
	check(FileAccess.get_file_as_bytes(written) == wave_md.to_utf8_buffer(),
		"the exported bytes equal the expected Wave Basics text")
	check_md(FileAccess.get_file_as_string(written), wave_md, "the exported text reads as expected")
	check(FileAccess.file_exists(out.path_join(MdExport.MARKER)), "the first export created exports/ with its marker")
	var first_bytes: PackedByteArray = FileAccess.get_file_as_bytes(written)
	check(MdExport.export_note(wave) == written and FileAccess.get_file_as_bytes(written) == first_bytes,
		"a second export overwrites the same file with identical bytes")
	check(md_files(out + "/Physics") == PackedStringArray(["note_wave_basics.md"]), "exactly one .md in exports/Physics")
	var stamped: String = MdExport.export_note(wave, "", true)
	check(RegEx.create_from_string("^note_wave_basics-\\d{8}-\\d{6}\\.md$").search(stamped.get_file()) != null
			and stamped.get_base_dir() == written.get_base_dir(),
		"timestamped=true writes note_wave_basics-YYYYMMDD-HHMMSS.md beside it")
	check(FileAccess.get_file_as_bytes(stamped) == first_bytes, "the timestamped file holds the same Markdown")
	check(FileAccess.get_file_as_bytes(written) == first_bytes, "the timestamped export leaves the first file unchanged")
	check(FileAccess.get_sha256(wave.resource_path) == wave_sha, "exporting never rewrites the note's .tres")
	check(VaultStore.last_conflict_copy == null, "exporting makes no conflict copy")
	VaultStore.refresh_note_list()
	check(VaultStore.note_list.size() == count_before, "exporting adds no notes")
	# A regular file in the way: reported through last_error, and no engine
	# "ERROR:" line, which run_all.sh would count as a failure.
	write_text(V + "blocker.txt", "a regular file\n")
	write_text(V + "out-b/Physics", "a file where the note's folder would go\n")
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	var prep_blocked: Error = MdExport.prepare_out_dir(V + "blocker.txt/exports")
	var blocked: String = MdExport.export_note(wave, V + "blocker.txt/exports")
	var blocked_error: String = MdExport.last_error
	var deep_blocked: String = MdExport.export_note(wave, V + "blocker.txt/a/b")
	var at_file: String = MdExport.export_note(wave, V + "blocker.txt")
	var sub_blocked: String = MdExport.export_note(wave, V + "out-b")
	var sub_error: String = MdExport.last_error
	OS.remove_logger(catcher)
	check(prep_blocked == ERR_FILE_BAD_PATH, "prepare_out_dir under a regular file is ERR_FILE_BAD_PATH")
	check(blocked == "" and blocked_error.contains("blocker.txt is a file"),
		"an out_root under a regular file returns \"\" with last_error naming the file")
	check(deep_blocked == "" and at_file == "", "... two folders below the file, and at the file itself, too")
	check(sub_blocked == "" and sub_error.contains("out-b/Physics is a file")
			and FileAccess.get_file_as_string(V + "out-b/Physics").begins_with("a file"),
		"a file where the note's folder goes returns \"\" with last_error and stays as it was")
	check(catcher.errors.is_empty(), "a file in the way logs no engine ERROR line")
	if not catcher.errors.is_empty():
		print("      logged: %s" % "\n      logged: ".join(catcher.errors))
	check(MdExport.export_note(wave) != "" and MdExport.last_error == "", "a later success clears last_error")
	DirAccess.remove_absolute(V + "blocker.txt")
	TestVault.remove_tree(V + "out-b")
	TestVault.remove_tree(out)

	# ── A user's own "exports" note folder is never hidden ──
	var plans := VaultStore.create_note("Export Plans", "exports")
	check(plans.resource_path == out.path_join("note_export_plans.tres"), "user note lands in exports/")
	check(MdExport.prepare_out_dir(out) == ERR_ALREADY_IN_USE,
		"prepare_out_dir refuses an existing unmarked folder that holds notes")
	check(not FileAccess.file_exists(out.path_join(MdExport.MARKER)), "the refused folder gets no marker")
	check(MdExport.export_note(wave) == "" and MdExport.last_error != ""
			and not FileAccess.file_exists(out.path_join("Physics/note_wave_basics.md")),
		"export_note refuses to write into the user's notes folder")
	VaultStore.refresh_note_list()
	check("exports" in VaultStore.folders, "the user's exports folder stays in the sidebar")
	check(VaultStore.get_note_index("Export Plans") >= 0, "the user's note in exports/ stays in the note list")
	write_text(V + "Archive/Old/note_kept.tres", FileAccess.get_file_as_string(plans.resource_path))
	check(MdExport.prepare_out_dir(V + "Archive") == ERR_ALREADY_IN_USE
			and not FileAccess.file_exists(V + "Archive/" + MdExport.MARKER),
		"a folder whose notes sit only in a subfolder is refused too")
	TestVault.remove_tree(out)
	TestVault.remove_tree(V + "Archive")
	VaultStore.refresh_note_list()

	# ── Production link map: real stems, relative paths, encoded segments ──
	# (renames the fixtures, so it runs after every check that needs them)
	# A note whose title is not its file's name: an app rename now renames
	# the file too (links-names), but notes retitled before that, or by a sync
	# tool or an older app, keep their old file name.
	sine.title = "Sine Wave"
	check(VaultStore.save_note(sine) == OK, "retitle Sine -> Sine Wave, keeping its file (as an older app did)")
	check(sine.resource_path == V + "Physics/note_sine.tres", "the renamed note is still note_sine.tres")
	check(convert_in("Physics", "See [[Sine Wave]].").contains("[Sine Wave](note_sine.md)"),
		"a link to a renamed note uses its real file stem: [[Sine Wave]] -> (note_sine.md)")
	check(MdExport.export_rel_path(sine, V) == "Physics/note_sine.md", "export_rel_path = folder + .tres stem + .md")
	check(MdExport.export_rel_path(start, V) == "note_start_here.md", "export_rel_path of a top-level note has no folder")

	check(VaultStore.create_folder("New folder") == "New folder", "fixture folder with a space")
	VaultStore.create_note("X", "New folder")
	check(links_from("").get("x", "") == "New%20folder/note_x.md",
		"a note in \"New folder\" linked from the top level -> New%20folder/note_x.md")
	check(links_from("Physics").get("x", "") == "../New%20folder/note_x.md",
		"... and from Physics -> ../New%20folder/note_x.md")
	check(convert_in("", "[[X]]").contains("[X](New%20folder/note_x.md)"), "the converted link is percent-encoded")

	VaultStore.create_note("Y", "C")
	check(links_from("A/B").get("y", "") == "../../C/note_y.md", "nested: from A/B to C -> ../../C/note_y.md")
	check(MdExport.relative_link("A/B", "A/B/note_y.md") == "note_y.md"
			and MdExport.relative_link("A/B", "A/note_y.md") == "../note_y.md"
			and MdExport.relative_link("A", "A/B/note_y.md") == "B/note_y.md",
		"relative_link: same folder, one up, one down")
	check(MdExport.relative_link("Physics", "Notes (old)/Café/note_z.md") == "../Notes%20%28old%29/Caf%C3%A9/note_z.md",
		"relative_link percent-encodes parentheses and non-ASCII per segment")

	# Two notes titled "Dup": the link goes where open_note_by_title goes,
	# the first match in note_list (newest modified first).
	var dup_old := VaultStore.create_note("Dup", "Physics")
	dup_old.modified = "2026-02-01T00:00:00"
	VaultStore.save_note(dup_old, false)
	var dup_new := VaultStore.create_note("Dup", "C")
	dup_new.modified = "2026-03-01T00:00:00"
	VaultStore.save_note(dup_new, false)
	var first_dup: ContentLayer = null
	for n in VaultStore.note_list:
		if n.title.strip_edges().to_lower() == "dup":
			first_dup = n
			break
	check(first_dup == dup_new, "fixture: the newer Dup comes first in note_list")
	check(links_from("Physics").get("dup", "") == "../C/note_dup.md",
		"[[Dup]] from Physics resolves to the first Dup in note_list (C/note_dup.md)")
	var reversed: Array[ContentLayer] = VaultStore.note_list.duplicate()
	reversed.reverse()
	check(MdExport.link_map(reversed, V, "Physics").get("dup", "") == "note_dup.md",
		"link_map takes the first note in the order it is given")
	check(not FileAccess.get_file_as_string("res://md_export.gd").contains("filename_stem"),
		"md_export.gd never derives a stem from the title (no filename_stem)")

	# ── Export All and Export folder, over the seeded vault ──
	check_export_vault()

	# ── A per-vault export folder ──
	check_output_root()

	# ── Tidy up ──
	TestVault.remove_tree(V)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(JourneyStore.file_override))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ProgressStore.file_override))
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)
