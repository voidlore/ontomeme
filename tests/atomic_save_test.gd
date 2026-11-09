extends SceneTree
## Notes are saved atomically, as the MCP server already did: ResourceSaver
## writes a temp file in <vault>/.ontomeme/tmp, which is renamed over the note.
## A crash, power cut or full disk mid-write can't truncate a note, and a
## reader (MCP read_note, a sync tool) never sees half a file.
##   headless:  godot --headless --path . -s res://tests/atomic_save_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")
const DAY: int = 24 * 60 * 60

var fails: int = 0
var V: String = ""


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func tmp_dir() -> String:
	return V.path_join(VaultStore.TMP_DIR)


func tmp_files() -> PackedStringArray:
	return DirAccess.get_files_at(tmp_dir()) if DirAccess.dir_exists_absolute(tmp_dir()) else PackedStringArray()


func reload(note: ContentLayer) -> ContentLayer:
	return ResourceLoader.load(note.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE) as ContentLayer


func load_file(path: String) -> ContentLayer:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as ContentLayer


## Set `path`'s modification time `secs` seconds back (touch has minutes).
func age(path: String, secs: int) -> void:
	var t: int = int(Time.get_unix_time_from_system()) - secs + Time.get_time_zone_from_system().bias * 60
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(t)
	OS.execute("touch", ["-t", "%04d%02d%02d%02d%02d" % [d.year, d.month, d.day, d.hour, d.minute], path])


func write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_atomic.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_atomic.json"   # never touch real progress
	ProgressStore.reset()
	V = TestVault.open("atomic-save", false)
	await process_frame

	test_save_note()
	test_hidden_from_scans()
	test_conflict_copy()
	test_no_temp_possible()
	test_failed_rename()
	test_links_and_permissions()
	test_text_and_mcp()
	test_windows_failed_rename()
	test_stale_temp_cleanup()

	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	TestVault.remove_tree(V)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


func test_save_note() -> void:
	var n: ContentLayer = VaultStore.create_note("Atomic")
	check(n != null and FileAccess.file_exists(n.resource_path), "create_note writes the note")
	n.raw_text = "first version"
	check(VaultStore.save_note(n) == OK, "save_note returns OK")
	check(DirAccess.dir_exists_absolute(tmp_dir()) and tmp_files().is_empty(), "after save_note, .ontomeme/tmp exists and is empty")
	check(reload(n) != null and reload(n).raw_text == "first version", "the note reloads from disk with the new text")
	n.raw_text = "second version"
	check(VaultStore.save_note(n) == OK and reload(n).raw_text == "second version" and tmp_files().is_empty(), "a save over an existing note replaces it and leaves no temp file")
	check(VaultStore._hashes.get(n.resource_path, "") == FileAccess.get_sha256(n.resource_path), "the remembered hash is the renamed file's")


## .ontomeme (and a temp file left in it) stays out of the sidebar, the disk
## watcher's signature and the MCP scans.
func test_hidden_from_scans() -> void:
	var n: ContentLayer = VaultStore.note_list[VaultStore.get_note_index("Atomic")]
	var stray: String = tmp_dir().path_join("1-1.tres")
	DirAccess.copy_absolute(n.resource_path, stray)
	VaultStore.refresh_note_list()
	var listed: bool = false
	for note in VaultStore.note_list:
		listed = listed or note.resource_path.contains("/.ontomeme/")
	check(not listed and not ".ontomeme" in VaultStore.folders and not ".ontomeme/tmp" in VaultStore.folders, "a temp .tres is not in the note list or the folders")
	check(not VaultStore.disk_signature().contains(".ontomeme"), "…nor in the disk watcher's signature")
	var mcp: Dictionary = VaultTools.new(V).call_tool("list_notes", {}).structuredContent
	var in_mcp: bool = mcp.folders.any(func(f): return str(f).begins_with(".ontomeme")) or mcp.notes.any(func(x): return str(x.path).contains(".ontomeme"))
	check(not in_mcp, "…nor in MCP list_notes")
	DirAccess.remove_absolute(stray)


func test_conflict_copy() -> void:
	var n: ContentLayer = VaultStore.create_note("Conflicted Atomic")
	n.raw_text = "app text"
	VaultStore.save_note(n)
	write_text(n.resource_path, FileAccess.get_file_as_string(n.resource_path).replace("app text", "outside text"))
	n.raw_text = "app text, typed meanwhile"
	check(VaultStore.save_note(n) == OK and VaultStore.last_conflict_copy != null, "an outside edit still makes a conflict copy")
	var copy: ContentLayer = VaultStore.last_conflict_copy
	check(copy != null and reload(copy).raw_text == "app text, typed meanwhile" and tmp_files().is_empty(), "…written through the temp folder, which is left empty")
	check(FileAccess.get_file_as_string(n.resource_path).contains("outside text"), "…and the outside version is kept")


## <vault>/.ontomeme replaced by a plain file: no temp file can be created, so
## the save fails before anything touches the note.
func test_no_temp_possible() -> void:
	var n: ContentLayer = VaultStore.note_list[VaultStore.get_note_index("Atomic")]
	var data: String = V.path_join(".ontomeme")
	TestVault.remove_tree(data)
	write_text(data, "not a folder")
	print("EXPECT-ERROR: Could not create directory: '%s'" % tmp_dir())   # for tests/run_all.sh
	var before: String = FileAccess.get_sha256(n.resource_path)
	n.raw_text = "never written"
	var err: Error = VaultStore.save_note(n)
	check(err != OK and VaultStore.last_save_error != "", "save_note fails when no temp file can be made (%s)" % VaultStore.last_save_error)
	check(FileAccess.get_sha256(n.resource_path) == before, "…and the note's SHA-256 on disk is unchanged")
	check(VaultStore.create_note("No Temp") == null and not FileAccess.file_exists(V.path_join("note_no_temp.tres")), "create_note returns null and writes nothing")
	var tools: RefCounted = VaultTools.new(V)
	var rel: String = n.resource_path.substr(V.length())
	var upd: Dictionary = tools.call_tool("update_note", {"path": rel, "hash": before, "markdown": "from MCP"})
	check(upd.isError and upd.structuredContent.error.code == "write_failed" and FileAccess.get_sha256(n.resource_path) == before, "MCP update_note fails the same way and leaves the note as it was")
	DirAccess.remove_absolute(data)
	check(VaultStore.save_note(n) == OK and reload(n).raw_text == "never written" and tmp_files().is_empty(), "with .ontomeme a folder again, the retry saves (no spurious conflict)")


## The temp file is written but can't be renamed into a read-only folder: it
## is removed again, and the note is untouched.
func test_failed_rename() -> void:
	if not OS.get_name() in ["Linux", "macOS"]:
		print("SKIP  failed rename (needs chmod)")
		return
	VaultStore.create_folder("ReadOnly")
	var n: ContentLayer = VaultStore.create_note("In A Read-Only Folder", "ReadOnly")
	var before: String = FileAccess.get_sha256(n.resource_path)
	OS.execute("chmod", ["555", n.resource_path.get_base_dir()])
	n.raw_text = "can't land"
	var err: Error = VaultStore.save_note(n)
	OS.execute("chmod", ["755", n.resource_path.get_base_dir()])
	if err == OK:
		print("SKIP  failed rename: this user can write to a read-only folder (root?)")
		return
	check(err == ERR_FILE_CANT_WRITE and VaultStore.last_save_error.begins_with("Can't write file"), "a rename into a read-only folder fails as \"Can't write file\" (%s)" % VaultStore.last_save_error)
	check(tmp_files().is_empty(), "…and its temp file is removed")
	check(FileAccess.get_sha256(n.resource_path) == before, "…and the note is untouched")


func mode_of(path: String) -> int:
	return FileAccess.get_unix_permissions(path)


func is_link(path: String) -> bool:
	return DirAccess.open(path.get_base_dir()).is_link(path)


## The rename must keep what a plain write kept: a symlinked note stays a
## link and its target gets the edit; a read-only note is refused, not
## replaced; the file's permissions carry over.
func test_links_and_permissions() -> void:
	if not OS.get_name() in ["Linux", "macOS"]:
		print("SKIP  links and permissions (needs ln and chmod)")
		return
	# A note linked in from another folder, by a relative symlink
	var outside: String = V.get_base_dir().get_base_dir().path_join("test-atomic-outside")
	TestVault.remove_tree(outside)
	DirAccess.make_dir_recursive_absolute(outside)
	var seed: ContentLayer = VaultStore.create_note("Linked")
	seed.raw_text = "linked, version 1"
	VaultStore.save_note(seed)
	var link: String = seed.resource_path
	var real: String = outside.path_join(link.get_file())
	DirAccess.rename_absolute(link, real)
	OS.execute("ln", ["-s", "../test-atomic-outside/" + link.get_file(), link])
	VaultStore.open_vault(V, false)
	var n: ContentLayer = VaultStore.note_list[VaultStore.get_note_index("Linked")]
	check(is_link(link) and n.raw_text == "linked, version 1", "(a note file that is a relative symlink to another folder)")
	n.raw_text = "linked, version 2"
	check(VaultStore.save_note(n) == OK, "saving a symlinked note works")
	check(is_link(link), "…the note stays a symlink")
	check(FileAccess.get_file_as_string(real).contains("linked, version 2"), "…and the file it points to gets the edit")
	n.raw_text = "linked, version 3"
	check(VaultStore.save_note(n) == OK and VaultStore.last_conflict_copy == null and FileAccess.get_file_as_string(real).contains("linked, version 3"), "…and the next save is no conflict")
	check(tmp_files().is_empty(), "…and leaves no temp file")

	# The same with the target on another file system (/tmp is often tmpfs):
	# the rename has to copy
	if DirAccess.dir_exists_absolute("/tmp"):
		var far: String = "/tmp/ontomeme-atomic-test-%d.tres" % randi()
		var far_note: ContentLayer = VaultStore.create_note("Linked Far")
		var far_link: String = far_note.resource_path
		DirAccess.copy_absolute(far_link, far)
		DirAccess.remove_absolute(far_link)
		OS.execute("ln", ["-s", far, far_link])
		VaultStore.open_vault(V, false)
		far_note = VaultStore.note_list[VaultStore.get_note_index("Linked Far")]
		far_note.raw_text = "saved across file systems"
		check(VaultStore.save_note(far_note) == OK and is_link(far_link) and FileAccess.get_file_as_string(far).contains("saved across file systems"), "a note linked to another file system saves through the link")
		DirAccess.remove_absolute(far_link)
		DirAccess.remove_absolute(far)

	# Permissions carry over
	var p: ContentLayer = VaultStore.create_note("Private")
	OS.execute("chmod", ["600", p.resource_path])
	p.raw_text = "private words"
	check(VaultStore.save_note(p) == OK and mode_of(p.resource_path) == 384, "a note with mode 600 keeps it after a save (%o)" % mode_of(p.resource_path))

	# A note the user made read-only is refused, not replaced
	var ro: ContentLayer = VaultStore.create_note("Read Only")
	ro.raw_text = "locked text"
	VaultStore.save_note(ro)
	OS.execute("chmod", ["444", ro.resource_path])
	var before: String = FileAccess.get_sha256(ro.resource_path)
	ro.raw_text = "must not land"
	var err: Error = VaultStore.save_note(ro)
	if err == OK and mode_of(ro.resource_path) != 292:
		check(false, "a read-only (444) note is refused, not replaced by a writable copy")
	elif FileAccess.open(ro.resource_path, FileAccess.READ_WRITE) != null:
		print("SKIP  read-only note: this user can write to a 444 file (root?)")
	else:
		check(err == ERR_FILE_CANT_WRITE and VaultStore.last_save_error.begins_with("Can't write file"), "a read-only (444) note is refused (%s)" % VaultStore.last_save_error)
		check(FileAccess.get_sha256(ro.resource_path) == before and mode_of(ro.resource_path) == 292, "…it stays as it was, mode 444")
		check(tmp_files().is_empty(), "…and no temp file is left")
		var tools: RefCounted = VaultTools.new(V)
		var rel: String = ro.resource_path.substr(V.length())
		var upd: Dictionary = tools.call_tool("update_note", {"path": rel, "hash": before, "markdown": "from MCP"})
		check(upd.isError and upd.structuredContent.error.code == "write_failed" and FileAccess.get_sha256(ro.resource_path) == before, "MCP update_note refuses it the same way")
	OS.execute("chmod", ["644", ro.resource_path])
	TestVault.remove_tree(outside)


func test_text_and_mcp() -> void:
	var txt: String = V.path_join("plain.txt")
	check(VaultStore.atomic_write_text("plain words", txt) == OK and FileAccess.get_file_as_string(txt) == "plain words", "atomic_write_text writes a text file")
	check(VaultStore.atomic_write_text("new words", txt) == OK and FileAccess.get_file_as_string(txt) == "new words" and tmp_files().is_empty(), "…replaces an existing one and leaves no temp file")
	DirAccess.remove_absolute(txt)

	var tools: RefCounted = VaultTools.new(V)
	var made: Dictionary = tools.call_tool("create_note", {"title": "From Claude", "markdown": "hello"})
	check(not made.isError and tmp_files().is_empty(), "MCP create_note writes through VaultStore.atomic_save")
	var again: Dictionary = tools.call_tool("create_note", {"title": "From Claude"})
	check(again.isError and again.structuredContent.error.code == "exists", "…and still refuses to overwrite an existing note")
	var rel: String = made.structuredContent.path
	var upd: Dictionary = tools.call_tool("update_note", {"path": rel, "hash": made.structuredContent.hash, "markdown": "hello again"})
	check(not upd.isError and tools.call_tool("read_note", {"path": rel}).structuredContent.markdown == "hello again" and tmp_files().is_empty(), "MCP update_note too")


## Windows renames over a file by deleting it first (DeleteFileW) and then
## moving the new one in (MoveFileW); rename_hook acts that out. If the move
## fails after the delete (a sync client or a virus scanner holding the
## fresh temp file), the temp file is the only copy of the note: it must be
## kept, not removed with the error, and open_vault must put it back. Before,
## both copies were gone, and the MCP path had no copy in memory either.
func test_windows_failed_rename() -> void:
	if OS.get_name() == "Windows":
		print("SKIP  Windows rename recovery (needs touch to age a file)")
		return
	var n: ContentLayer = VaultStore.create_note("Windows Rename")
	n.raw_text = "version 1"
	VaultStore.save_note(n)
	var path: String = n.resource_path
	var moves: Array[int] = [0]
	var delete_then_fail: Callable = func(_from: String, to: String) -> Error:
		moves[0] += 1
		if FileAccess.file_exists(to):
			DirAccess.remove_absolute(to)
		return FAILED

	# The move fails once, right after the delete: it is tried again and lands
	var failed_once: Array[bool] = [false]
	VaultStore.rename_hook = func(from: String, to: String) -> Error:
		if not failed_once[0]:
			failed_once[0] = true
			return delete_then_fail.call(from, to)
		return DirAccess.rename_absolute(from, to)
	n.raw_text = "version 2"
	var err: Error = VaultStore.save_note(n)
	VaultStore.rename_hook = Callable()
	check(err == OK and load_file(path).raw_text == "version 2" and tmp_files().is_empty(), "a move that fails right after Windows deleted the note is tried again and lands")

	# The move keeps failing: the temp file, now the only copy, is kept
	VaultStore.rename_hook = delete_then_fail
	moves[0] = 0
	n.raw_text = "version 3, only in the temp file"
	err = VaultStore.save_note(n)
	VaultStore.rename_hook = Callable()
	var kept: PackedStringArray = tmp_files()
	check(err == ERR_FILE_CANT_WRITE and not FileAccess.file_exists(path), "(the move failed after the delete: the note file is gone, as on Windows)")
	check(moves[0] == 2, "…the move was tried once more")
	check(kept.size() == 1 and FileAccess.get_file_as_string(tmp_dir().path_join(kept[0])).contains("version 3, only in the temp file"), "…and the temp file, the only copy now, is kept (%s)" % ", ".join(kept))
	check(kept.size() == 1 and kept[0].ends_with("-" + path.get_file()), "…named after the note it belongs to")
	if kept.size() != 1:
		return
	# The app quits before a retry lands; the next start puts the note back
	VaultStore.open_vault(V, false)
	check(not FileAccess.file_exists(path) and tmp_files().size() == 1, "open_vault leaves a seconds-old temp file alone (another process may be mid-save)")
	age(tmp_dir().path_join(kept[0]), 120)
	VaultStore.open_vault(V, false)
	check(FileAccess.file_exists(path) and load_file(path).raw_text == "version 3, only in the temp file", "open_vault moves an older one back into place, with the words")
	check(tmp_files().is_empty() and VaultStore.get_note_index("Windows Rename") >= 0, "…the note is listed again and the temp folder is empty")

	# The app's retry lands first: the kept copy is older, never moved over it
	n = VaultStore.note_list[VaultStore.get_note_index("Windows Rename")]
	VaultStore.rename_hook = delete_then_fail
	n.raw_text = "version 4, kept"
	VaultStore.save_note(n)
	VaultStore.rename_hook = Callable()
	n.raw_text = "version 5, the retry"
	check(VaultStore.save_note(n) == OK and load_file(path).raw_text == "version 5, the retry", "the app's retry writes the missing note again")
	kept = tmp_files()
	if kept.size() == 1:
		age(tmp_dir().path_join(kept[0]), 120)
	VaultStore.open_vault(V, false)
	check(load_file(path).raw_text == "version 5, the retry" and tmp_files().size() == 1, "open_vault never moves a kept copy over a note that exists")
	if kept.size() == 1:
		age(tmp_dir().path_join(kept[0]), 2 * DAY)
	VaultStore.open_vault(V, false)
	check(tmp_files().is_empty(), "…and removes it once it is a day old")

	# MCP update_note, which has no copy in memory: the same
	var tools: RefCounted = VaultTools.new(V)
	var rel: String = path.substr(V.length())
	var h: String = tools.call_tool("read_note", {"path": rel}).structuredContent.hash
	VaultStore.rename_hook = delete_then_fail
	var upd: Dictionary = tools.call_tool("update_note", {"path": rel, "hash": h, "markdown": "from Claude, only in the temp file"})
	VaultStore.rename_hook = Callable()
	kept = tmp_files()
	check(upd.isError and not FileAccess.file_exists(path) and kept.size() == 1, "MCP update_note: the same failure keeps the temp file")
	if kept.size() == 1:
		age(tmp_dir().path_join(kept[0]), 120)
	VaultStore.open_vault(V, false)
	check(FileAccess.file_exists(path) and tools.call_tool("read_note", {"path": rel}).structuredContent.markdown == "from Claude, only in the temp file", "…and open_vault puts Claude's version back")

	# A temp file cut off early (a crash while a new note was being written)
	# is not restored as a note, and goes with the day-old cleanup
	var cut: String = tmp_dir().path_join("1000-1-note_never_finished.tres")
	write_text(cut, "[gd_resource type=\"Resource\" script_class=\"ContentLayer\" format=3]\n\n[ext_res")
	age(cut, 120)
	VaultStore.open_vault(V, false)
	check(not FileAccess.file_exists(V.path_join("note_never_finished.tres")) and FileAccess.file_exists(cut), "a temp file cut off before its [resource] section is not restored")
	age(cut, 2 * DAY)
	VaultStore.open_vault(V, false)
	check(not FileAccess.file_exists(cut), "…and is removed once a day old")


## open_vault removes temp files a crashed save left behind (older than a day)
## and keeps a fresh one, which may belong to a save still in progress.
func test_stale_temp_cleanup() -> void:
	if OS.get_name() == "Windows":
		print("SKIP  stale temp files (needs touch to age a file)")
		return
	DirAccess.make_dir_recursive_absolute(tmp_dir())
	var old: String = tmp_dir().path_join("100-1.tres")
	var fresh: String = tmp_dir().path_join("200-2.tres")
	write_text(old, "left by a crash")
	write_text(fresh, "a save in progress")
	age(old, 2 * DAY)
	check(FileAccess.get_modified_time(old) < int(Time.get_unix_time_from_system()) - DAY, "(the old temp file is dated two days ago)")
	VaultStore.open_vault(V, false)
	check(not FileAccess.file_exists(old), "open_vault removes a temp file dated two days ago")
	check(FileAccess.file_exists(fresh), "…and keeps a fresh one")
	DirAccess.remove_absolute(fresh)
