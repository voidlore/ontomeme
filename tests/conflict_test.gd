extends SceneTree
## Conflicts: when a note's file changed on disk since the app read it (a sync
## tool, another editor, Claude via MCP), saving keeps the outside version and
## writes the app's version as "<title> (conflict copy)". Nothing is lost.
##   headless:  godot --headless --path . -s res://tests/conflict_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## Click `ctrl` with real mouse events, as a user does.
func click(ctrl: Control) -> void:
	var pos: Vector2 = ctrl.get_global_rect().get_center()
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	await process_frame
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	await frames(3)


## True when `ctrl` is shown and lies inside the window, so a click reaches it.
func on_screen(ctrl: Control) -> bool:
	return ctrl != null and ctrl.is_visible_in_tree() and get_root().get_visible_rect().encloses(ctrl.get_global_rect())


## Type in the app's editor and let the autosave run: when the file changed
## on disk meanwhile, the conflict copy opens.
func type_and_autosave(app: Control, text: String) -> void:
	app.raw_text_layer.text = text
	app.raw_text_layer.text_changed.emit()
	app._do_auto_save()
	await frames(2)


## Another program rewrites the note's file: same .tres, new body text.
func outside_edit(note: ContentLayer, from: String, to: String) -> void:
	var path: String = note.resource_path
	var text: String = FileAccess.get_file_as_string(path)
	check(text.contains(from), "(outside edit finds \"%s\" on disk)" % from)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text.replace(from, to))
	f.close()


func body_on_disk(note_path: String) -> String:
	return FileAccess.get_file_as_string(note_path)


## Save `note` with `text`; true when it saved in place (no conflict copy)
## and the file now holds `text`.
func save_clean(note: ContentLayer, text: String) -> bool:
	note.raw_text = text
	var err: Error = VaultStore.save_note(note)
	return err == OK and VaultStore.last_conflict_copy == null and body_on_disk(note.resource_path).contains(text)


## A conflict copy knows its original by path (conflict_of, in its file),
## and by its title when it is a copy from before that field.
func conflict_copy_keys(V: String, a: ContentLayer, copy: ContentLayer) -> void:
	if copy == null:
		check(false, "(no conflict copy to inspect)")
		return
	var a_rel: String = a.resource_path.substr(V.length())
	check(copy.conflict_of == a_rel, "the copy remembers its original's path (conflict_of = \"%s\")" % copy.conflict_of)
	var on_disk: Resource = ResourceLoader.load(copy.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	check(on_disk is ContentLayer and on_disk.conflict_of == a_rel, "…in its file too")
	check(VaultStore.conflict_original(copy) == a, "conflict_original finds Alpha from the copy")
	check(VaultStore.conflict_original(a) == null, "…and Alpha itself is no conflict copy")
	check(VaultStore.conflict_copy_base("Alpha (conflict copy)") == "Alpha" and VaultStore.conflict_copy_base("Alpha (conflict copy 12)") == "Alpha", "the title pattern is \"<title> (conflict copy[ n])\"")
	check(VaultStore.conflict_copy_base("Alpha") == "" and VaultStore.conflict_copy_base("Alpha (conflict copy) notes") == "", "…and nothing else matches it")
	a.title = "Alpha renamed"
	VaultStore.save_note(a)
	check(VaultStore.conflict_original(copy) == a, "an original renamed since is still found, by its path")
	a.title = "Alpha"
	VaultStore.save_note(a)
	var top: ContentLayer = VaultStore.create_note("Alpha")
	var old: ContentLayer = VaultStore.create_note("Alpha (conflict copy 9)", "Sub")
	check(old.conflict_of == "" and VaultStore.conflict_original(old) == a, "a copy without conflict_of finds its original by title, in its own folder first")
	var NoteScript: GDScript = load("res://note.gd")
	check(NoteScript.line_diff("a\nb\nc", "a\nx\nc") == PackedStringArray(["  a", "- b", "+ x", "  c"]), "line_diff marks a changed line - then +, between common lines")
	check(NoteScript.line_diff("one\ntwo", "zero\none\ntwo\nthree") == PackedStringArray(["+ zero", "  one", "  two", "+ three"]), "…and lines only one side has")
	check(NoteScript.line_diff("same", "same") == PackedStringArray(["  same"]), "…and nothing for equal texts")
	var lone: ContentLayer = VaultStore.create_note("Nobody (conflict copy)")
	check(VaultStore.conflict_original(lone) == null, "a copy whose original is gone has none")
	for n in [top, old, lone]:
		VaultStore.delete_note(VaultStore.note_list.find(n))


## The bar a conflict copy shows: "Use this version" puts the copy's words in
## the original and trashes the copy, "Keep" trashes the copy alone, and
## "Compare" shows the lines that differ. Clicked with real input.
func conflict_bar_actions(app: Control, V: String, a_path: String) -> void:
	var copy: ContentLayer = app.current_note
	check(app._conflict_bar != null and on_screen(app._conflict_bar), "the conflict copy shows the conflict bar")
	check(app._conflict_label.text == "Saved during a conflict with “Alpha”", "…saying \"%s\"" % (app._conflict_label.text if app._conflict_label else ""))
	check(on_screen(app._conflict_use_btn) and app._conflict_use_btn.text == "Use this version", "…with a \"Use this version\" button")
	check(on_screen(app._conflict_keep_btn) and app._conflict_keep_btn.text == "Keep “Alpha”", "…a \"Keep “Alpha”\" button (%s)" % app._conflict_keep_btn.text)
	check(on_screen(app._conflict_compare_btn) and app._conflict_compare_btn.text == "Compare", "…and \"Compare\"")
	app._switch_layer("visual")
	await frames(2)
	check(on_screen(app._conflict_bar), "the bar shows in Read view too")

	await click(app._conflict_compare_btn)
	var diff: String = app._compare_text.get_parsed_text() if app._compare_text != null else ""
	check(app._compare_dialog != null and app._compare_dialog.visible, "Compare opens a dialog")
	var theirs: String = VaultStore.conflict_original(copy).raw_text
	check(diff.contains("- " + theirs + "\n") and diff.contains("+ typed in the app\n"), "…with Alpha's lines as - and the copy's as + (%s)" % diff.c_escape())
	app._compare_dialog.hide()
	await frames(2)

	var copy_path: String = copy.resource_path
	var copy_rel: String = copy_path.substr(V.length())
	await click(app._conflict_use_btn)
	check(body_on_disk(a_path).contains("typed in the app") and not body_on_disk(a_path).contains("changed in Dropbox"), "Use this version puts the copy's text in Alpha, on disk")
	check(not FileAccess.file_exists(copy_path) and FileAccess.file_exists(V + ".trash/" + copy_rel), "…moves the copy to .trash/%s" % copy_rel)
	check(VaultStore.note_list.find(copy) < 0, "…so it leaves the note list")
	check(app.current_note != null and app.current_note.resource_path == a_path and app.raw_text_layer.text == "typed in the app", "…and opens Alpha with that text (%s)" % (app.current_note.title if app.current_note else "none"))
	check(not app._conflict_bar.visible, "Alpha itself shows no conflict bar")
	var a: ContentLayer = app.current_note
	a.raw_text = "typed in the app"
	check(VaultStore.save_note(a) == OK and VaultStore.last_conflict_copy == null, "Alpha saves normally afterwards (its hash was updated)")

	# Keep: a new conflict, then the original wins
	outside_edit(a, "typed in the app", "changed in Dropbox again")
	await type_and_autosave(app, "typed once more")
	copy = app.current_note
	check(copy != null and copy.title.begins_with("Alpha (conflict copy") and on_screen(app._conflict_keep_btn), "(a second conflict opens a copy with the bar: %s)" % (copy.title if copy else "none"))
	var sha: String = FileAccess.get_sha256(a_path)
	copy_path = copy.resource_path
	copy_rel = copy_path.substr(V.length())
	await click(app._conflict_keep_btn)
	check(FileAccess.get_sha256(a_path) == sha and body_on_disk(a_path).contains("changed in Dropbox again"), "Keep leaves Alpha unchanged on disk")
	check(not FileAccess.file_exists(copy_path) and FileAccess.file_exists(V + ".trash/" + copy_rel), "…and moves the copy to .trash/%s" % copy_rel)
	check(app.current_note != null and app.current_note.resource_path == a_path and app.raw_text_layer.text == "changed in Dropbox again", "…and opens Alpha")
	check(app._restore_last_trashed() and FileAccess.file_exists(copy_path) and app.current_note == copy, "the kept-away copy comes back like any deleted note")
	check(on_screen(app._conflict_bar), "…with its bar")


## Moving or renaming takes the file's remembered hash along: a note moved
## away, edited and moved back must not look changed on disk.
func moves_keep_hashes() -> void:
	var m: ContentLayer = VaultStore.create_note("Mover")
	var home: String = m.resource_path
	check(save_clean(m, "body one"), "(Mover saved at the top level)")
	check(VaultStore.move_note(m, "X"), "(Mover moved to X)")
	check(save_clean(m, "body two"), "a note moved to a folder saves in place")
	check(VaultStore.move_note(m, ""), "(Mover moved back)")
	check(m.resource_path == home and save_clean(m, "body three"), "…and moved back, saves in place again, no conflict copy (%s)" % (VaultStore.last_conflict_copy.title if VaultStore.last_conflict_copy else "none"))
	check(VaultStore.get_note_index("Mover (conflict copy)") < 0 and body_on_disk(home).contains("body three"), "…so no \"Mover (conflict copy)\" exists and the disk has the last edit")

	VaultStore.create_folder("F")
	var fm: ContentLayer = VaultStore.create_note("Folder Mover", "F")
	check(save_clean(fm, "folder one"), "(Folder Mover saved in F)")
	check(VaultStore.rename_folder("F", "G") == "G" and VaultStore.folder_of(fm) == "G", "(F renamed to G)")
	check(save_clean(fm, "folder two"), "a note in a renamed folder saves in place")
	check(VaultStore.rename_folder("G", "F") == "F" and VaultStore.folder_of(fm) == "F", "(G renamed back to F)")
	check(save_clean(fm, "folder three"), "…and after renaming back, no conflict copy (%s)" % (VaultStore.last_conflict_copy.title if VaultStore.last_conflict_copy else "none"))
	check(VaultStore.get_note_index("Folder Mover (conflict copy)") < 0, "…so no \"Folder Mover (conflict copy)\" exists")

	# Regression guard: the hash moved with the file, so an outside edit to
	# the moved file is still caught.
	check(VaultStore.move_note(m, "Y"), "(Mover moved to Y)")
	outside_edit(m, "body three", "edited in Y elsewhere")
	m.raw_text = "typed after the move"
	VaultStore.save_note(m)
	check(VaultStore.last_conflict_copy != null and VaultStore.last_conflict_copy.raw_text == "typed after the move" and body_on_disk(m.resource_path).contains("edited in Y elsewhere"), "after a move, an outside edit to the moved file is still kept (conflict copy)")
	check(VaultStore.rename_folder("F", "H") == "H", "(F renamed to H)")
	outside_edit(fm, "folder three", "edited in H elsewhere")
	fm.raw_text = "typed after the rename"
	VaultStore.save_note(fm)
	check(VaultStore.last_conflict_copy != null and body_on_disk(fm.resource_path).contains("edited in H elsewhere"), "after a folder rename, an outside edit inside it is still kept (conflict copy)")

	# A deleted file takes its bookkeeping with it.
	var m_path: String = m.resource_path
	check(VaultStore.delete_note(VaultStore.note_list.find(m)) and not VaultStore._hashes.has(m_path) and not VaultStore._mtimes.has(m_path), "delete_note forgets the file's hash and mtime")
	var h_prefix: String = VaultStore.vault_path + "H/"
	check(VaultStore.delete_folder("H"), "(folder H deleted)")
	var left: Array = VaultStore._hashes.keys().filter(func(p): return str(p).begins_with(h_prefix)) + VaultStore._mtimes.keys().filter(func(p): return str(p).begins_with(h_prefix))
	check(left.is_empty(), "delete_folder forgets every file under it %s" % str(left))


## A note's file renamed or deleted outside while the app holds the note: a
## save must not write it again at the old path (a renamed note would come
## back under its old title beside the new one). The app's own deletes and
## moves must not look like that.
func gone_files(V: String, tools: RefCounted) -> void:
	# Renamed outside: Claude's update_note renames the file with the title
	var g: ContentLayer = VaultStore.create_note("Golf")
	g.raw_text = "golf v1"
	VaultStore.save_note(g)
	var g_path: String = g.resource_path
	var rel: String = g_path.substr(V.length())
	var h: String = tools.call_tool("read_note", {"path": rel}).structuredContent.hash
	var r: Dictionary = tools.call_tool("update_note", {"path": rel, "hash": h, "title": "Golf Prime"})
	check(not r.get("isError", false) and not FileAccess.file_exists(g_path), "MCP update_note renames Golf's file to %s" % str(r.structuredContent.get("path")))
	g.raw_text = "golf, typed before the poll"
	VaultStore.save_note(g)
	var copy: ContentLayer = VaultStore.last_conflict_copy
	check(not FileAccess.file_exists(g_path), "a save does not write a renamed note's old file again")
	check(copy != null and copy.title == "Golf (conflict copy)" and copy.raw_text == "golf, typed before the poll" and FileAccess.file_exists(copy.resource_path), "…the app's version is saved as \"Golf (conflict copy)\"")
	check(VaultStore.get_note_index("Golf") < 0 and VaultStore.get_note_index("Golf Prime") >= 0, "…and the vault has Golf Prime and no Golf")

	# Deleted outside, with its folder
	VaultStore.create_folder("Hotel Folder")
	var d: ContentLayer = VaultStore.create_note("India", "Hotel Folder")
	d.raw_text = "india v1"
	VaultStore.save_note(d)
	var d_path: String = d.resource_path
	DirAccess.remove_absolute(d_path)
	DirAccess.remove_absolute(V + "Hotel Folder")
	d.raw_text = "india, typed after the delete"
	VaultStore.save_note(d)
	copy = VaultStore.last_conflict_copy
	check(not FileAccess.file_exists(d_path) and not DirAccess.dir_exists_absolute(V + "Hotel Folder"), "a save does not bring back a file, or its folder, deleted outside")
	check(copy != null and copy.raw_text == "india, typed after the delete" and copy.resource_path == V + "note_india_conflict_copy.tres", "…the typing is kept as a copy at the top level (%s)" % (copy.resource_path.substr(V.length()) if copy else "none"))

	# The app's own deletes, moves and new notes are not taken for gone files
	var j: ContentLayer = VaultStore.create_note("Juliett")
	var j_path: String = j.resource_path
	DirAccess.remove_absolute(j_path)   # deleted outside, then the poll ran
	VaultStore.refresh_note_list()
	var j2: ContentLayer = VaultStore.create_note("Juliett")
	check(j2.resource_path == j_path and VaultStore.last_conflict_copy == null and FileAccess.file_exists(j_path), "a new note in the file name of one deleted outside saves normally")
	VaultStore.create_folder("Kilo Folder")
	var k: ContentLayer = VaultStore.create_note("Kilo", "Kilo Folder")
	k.raw_text = "the first Kilo"
	VaultStore.save_note(k)
	var k_path: String = k.resource_path
	VaultStore.delete_note(VaultStore.note_list.find(k))
	var k2: ContentLayer = VaultStore.create_note("Kilo")
	k2.raw_text = "the second Kilo"
	VaultStore.save_note(k2)
	VaultStore.move_note(k2, "Kilo Folder")
	k2.raw_text = "the second Kilo, edited after the move"
	VaultStore.save_note(k2)
	check(k2.resource_path == k_path and VaultStore.last_conflict_copy == null and body_on_disk(k_path).contains("edited after the move"), "a note moved into the file name of one the app deleted saves normally")
	var nr: String = VaultStore.rename_folder("Kilo Folder", "Lima Folder")
	k2.raw_text = "after the folder rename"
	VaultStore.save_note(k2)
	check(nr == "Lima Folder" and VaultStore.last_conflict_copy == null and body_on_disk(V + "Lima Folder/note_kilo.tres").contains("after the folder rename") and not FileAccess.file_exists(k_path), "a note in a folder the app renamed saves normally, in the renamed folder")


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_conflict.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_conflict.json"   # never touch real progress
	ProgressStore.reset()
	var V: String = TestVault.open("conflict", false)
	await frames(2)

	# ── Store ──
	VaultStore.create_folder("Sub")
	var a: ContentLayer = VaultStore.create_note("Alpha", "Sub")
	a.raw_text = "first draft"
	VaultStore.save_note(a)
	var a_path: String = a.resource_path
	a.raw_text = "second draft"
	VaultStore.save_note(a)
	check(VaultStore.last_conflict_copy == null and body_on_disk(a_path).contains("second draft"), "the app's own saves never conflict")

	outside_edit(a, "second draft", "edited elsewhere")
	a.raw_text = "my unsaved words"
	VaultStore.save_note(a)
	var copy: ContentLayer = VaultStore.last_conflict_copy
	check(body_on_disk(a_path).contains("edited elsewhere") and not body_on_disk(a_path).contains("my unsaved words"), "an outside edit is not overwritten")
	check(copy != null and copy.title == "Alpha (conflict copy)" and copy.raw_text == "my unsaved words", "the app's version becomes \"Alpha (conflict copy)\"")
	check(copy != null and FileAccess.file_exists(copy.resource_path) and VaultStore.folder_of(copy) == "Sub", "…saved next to the original, in Sub/ (%s)" % (copy.resource_path.get_file() if copy else ""))
	check(copy != null and copy.resource_path.get_file() == "note_alpha_conflict_copy.tres", "…with a portable file name")
	check(a.raw_text == "edited elsewhere", "the open note now shows the outside version (%s)" % a.raw_text)
	conflict_copy_keys(V, a, copy)

	a.raw_text = "edited elsewhere, then by me"
	VaultStore.save_note(a)
	check(VaultStore.last_conflict_copy == null and body_on_disk(a_path).contains("then by me"), "after a conflict, the next save works normally")

	outside_edit(a, "then by me", "elsewhere again")
	a.raw_text = "mine again"
	VaultStore.save_note(a)
	check(VaultStore.last_conflict_copy != null and VaultStore.last_conflict_copy.title == "Alpha (conflict copy 2)", "a second conflict gets a new copy, not an overwrite")

	# An edit the disk watcher already reloaded is not a conflict
	OS.delay_msec(1100)   # mtimes are per second: the edit must land in a new second to be seen
	outside_edit(a, "elsewhere again", "seen by the watcher")
	VaultStore.refresh_note_list()
	a.raw_text = a.raw_text + " + mine"
	VaultStore.save_note(a)
	check(VaultStore.last_conflict_copy == null and body_on_disk(a_path).contains("seen by the watcher + mine"), "an outside edit the app reloaded is saved over normally")

	# Claude via MCP edits a note the app has open
	var b: ContentLayer = VaultStore.create_note("Beta")
	b.raw_text = "app text"
	VaultStore.save_note(b)
	var tools: RefCounted = VaultTools.new(V)
	var rel: String = b.resource_path.substr(V.length())
	var read: Dictionary = tools.call_tool("read_note", {"path": rel})
	var upd: Dictionary = tools.call_tool("update_note", {"path": rel, "hash": read.structuredContent.hash, "markdown": "claude text"})
	check(not upd.get("isError", false), "MCP update_note succeeds")
	b.raw_text = "app text, typed while Claude wrote"
	VaultStore.save_note(b)
	check(body_on_disk(b.resource_path).contains("claude text") and VaultStore.last_conflict_copy != null and VaultStore.last_conflict_copy.raw_text == "app text, typed while Claude wrote", "Claude's MCP edit survives; the app's typing is a conflict copy")

	moves_keep_hashes()
	gone_files(V, tools)

	# ── UI: typing while the file changes, then autosave ──
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.open_note_by_title("Alpha")
	await frames(2)
	outside_edit(app.current_note, "seen by the watcher + mine", "changed in Dropbox")
	app.raw_text_layer.text = "typed in the app"
	app._do_auto_save()
	await frames(2)
	check(app.current_note != null and app.current_note.title.begins_with("Alpha (conflict copy"), "the editor switches to the conflict copy (%s)" % (app.current_note.title if app.current_note else "none"))
	check(app.raw_text_layer.text == "typed in the app", "…so the typed words stay on screen")
	check(app.status_label.text.contains("changed on disk"), "…and the status bar says what happened (%s)" % app.status_label.text)
	check(body_on_disk(a_path).contains("changed in Dropbox"), "…while the outside version is kept")
	await conflict_bar_actions(app, V, a_path)

	# ── UI: the same from the Graph view: typing still waits for its autosave
	# when the user switches to the graph (the watcher skips its poll while
	# it waits), and the autosave then meets an outside edit. The graph stays,
	# with the copy behind it, and its hint (put up by _switch_layer, which
	# awaits a frame) does not replace the conflict notice ──
	app._watch_timer.paused = true
	app.open_note_by_title("Beta")
	await frames(2)
	app._switch_layer("raw")
	app.raw_text_layer.text = "typed, then off to the graph"
	app._on_raw_text_changed()
	app._switch_layer("graph")
	await frames(2)
	check(not app._auto_save_timer.is_stopped(), "(the autosave is still pending in the Graph view)")
	outside_edit(app.current_note, "claude text", "changed by an agent")
	app._flush_pending_save()
	await frames(3)
	check(app.current_mode == "graph" and app.graph_layer.visible, "in the Graph view, the graph stays open (%s)" % app.current_mode)
	check(app.current_note != null and app.current_note.title.begins_with("Beta (conflict copy")
		and app.current_note.raw_text == "typed, then off to the graph",
		"…with the conflict copy behind it (%s)" % (app.current_note.title if app.current_note else "none"))
	check(app.status_label.text.contains("changed on disk while you were editing") and app.status_label.text.contains("Beta (conflict copy"),
		"…and three frames on the status bar still says what happened, not the graph's hint (%s)" % app.status_label.text)
	check(body_on_disk(b.resource_path).contains("changed by an agent"), "…while the outside version is kept")
	app._watch_timer.paused = false

	# Claude renames the open note over MCP while the user types: the file
	# moves, the autosave must not write the old title back to the old path
	var hotel: ContentLayer = VaultStore.create_note("Hotel")
	hotel.raw_text = "Hotel v1"
	VaultStore.save_note(hotel)
	var hotel_rel: String = hotel.resource_path.substr(V.length())
	app._refresh_note_list()
	app._open_note(hotel)
	app._switch_layer("raw")
	await frames(2)
	app.raw_text_layer.text = "Hotel v1 plus my new paragraph"
	app._on_raw_text_changed()
	check(not app._auto_save_timer.is_stopped(), "(an autosave is pending)")
	var h: String = tools.call_tool("read_note", {"path": hotel_rel}).structuredContent.hash
	var ren: Dictionary = tools.call_tool("update_note", {"path": hotel_rel, "hash": h, "title": "Hotel Prime"}).structuredContent
	check(ren.get("path") == "note_hotel_prime.tres", "MCP update_note renames Hotel to Hotel Prime (%s)" % str(ren))
	app._auto_save_timer.stop()
	app._do_auto_save()
	await frames(2)
	check(not FileAccess.file_exists(V + hotel_rel), "the autosave does not write the old file back (%s)" % hotel_rel)
	check(app.current_note != null and app.current_note.title == "Hotel (conflict copy)" and app.raw_text_layer.text == "Hotel v1 plus my new paragraph", "…it saves the typing as \"Hotel (conflict copy)\" and shows it (%s)" % (app.current_note.title if app.current_note else "none"))
	check(app.status_label.text.contains("“Hotel” was renamed or deleted on disk") and app.status_label.text.contains("Hotel (conflict copy)"), "…and the status bar says so (%s)" % app.status_label.text)
	app._last_sig = ""
	app.check_disk_changes()
	var hotels: Array = VaultStore.note_list.filter(func(x: ContentLayer) -> bool: return x.title.begins_with("Hotel")).map(func(x: ContentLayer) -> String: return "%s=%s" % [x.title, x.raw_text])
	hotels.sort()
	check(hotels == ["Hotel (conflict copy)=Hotel v1 plus my new paragraph", "Hotel Prime=Hotel v1"], "the vault holds Hotel Prime and the copy, and no second \"Hotel\" (%s)" % str(hotels))
	app.queue_free()
	await frames(2)

	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
