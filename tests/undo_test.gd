extends SceneTree
## The app's Undo / Redo (Ctrl+Z outside the editor, Ctrl+Y or Ctrl+Shift+Z,
## the palette) really puts the earlier text back, in the editor, in the
## Read view and on disk; inside the editor Ctrl+Z is the TextEdit's own
## undo only. A deleted note that came after the last edit is restored first.
##   headless:  godot --headless --path . -s res://tests/undo_test.gd

const TestVault = preload("res://tests/test_vault.gd")

var fails: int = 0
var app: Control = null
var V: String = ""


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## Press and release Ctrl+`key` (Ctrl+Shift+`key` with `shift`).
func press_ctrl(key: Key, shift: bool = false) -> void:
	for pressed in [true, false]:
		var k := InputEventKey.new()
		k.keycode = key
		k.ctrl_pressed = true
		k.shift_pressed = shift
		k.pressed = pressed
		get_root().push_input(k)
	await frames(2)


## Replace the open note's text the way typing does, and let the autosave run.
func type_and_save(text: String) -> void:
	app.raw_text_layer.text = text
	app.raw_text_layer.text_changed.emit()
	app._flush_pending_save()
	await frames(1)


func on_disk(note: ContentLayer) -> String:
	return FileAccess.get_file_as_string(note.resource_path)


## The text the Read view shows.
func read_view_text() -> String:
	var parts: PackedStringArray = []
	for c in app.visual_layer.get_children():
		if c is RichTextLabel or c is Label:
			parts.append(c.text)
	return "\n".join(parts)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_undo.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_undo.json"   # never touch real progress
	ProgressStore.reset()
	V = TestVault.open("undo", false)
	UndoRedoEngine.clear()
	var n: ContentLayer = VaultStore.create_note("Undo Me")
	VaultStore.create_note("Other Note")
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.open_note_by_title("Undo Me")
	await frames(2)

	# ── Undo / redo restore the text, in the view and on disk ──
	await type_and_save("version one")
	await type_and_save("version two")
	check(on_disk(n).contains("version two"), "(version two is saved)")
	app._switch_layer("visual")
	await frames(2)
	app._undo()
	await frames(2)
	check(app.raw_text_layer.text == "version one" and n.raw_text == "version one", "undo puts \"version one\" back in the editor (%s)" % app.raw_text_layer.text)
	check(on_disk(n).contains("version one") and not on_disk(n).contains("version two"), "…and on disk")
	check(read_view_text().contains("version one") and not read_view_text().contains("version two"), "…and the Read view shows it")
	check(app.current_mode == "visual" and VaultStore.last_conflict_copy == null, "…without leaving the Read view or making a conflict copy")
	app._redo()
	await frames(2)
	check(app.raw_text_layer.text == "version two" and on_disk(n).contains("version two"), "redo brings back \"version two\", in the editor and on disk")
	check(read_view_text().contains("version two"), "…and in the Read view")

	# ── Renaming the title keeps the history ──
	app._switch_layer("raw")
	app.title_edit.text = "Undo Me Renamed"
	app._commit_title()
	await frames(1)
	check(n.title == "Undo Me Renamed", "(the note is renamed)")
	app._undo()
	await frames(2)
	check(app.raw_text_layer.text == "version one" and on_disk(n).contains("version one"), "undo after renaming the title still restores the earlier text (%s)" % app.raw_text_layer.text)
	check(n.title == "Undo Me Renamed" and app.current_note == n, "…on the renamed note")
	app._redo()
	await frames(2)

	# ── Undo shows the note it changed ──
	app.open_note_by_title("Other Note")
	await frames(2)
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(app.current_note == n and app.raw_text_layer.text == "version one", "Ctrl+Z outside the editor undoes the last edit and opens its note (%s)" % (app.current_note.title if app.current_note else "none"))
	get_root().gui_release_focus()
	await press_ctrl(KEY_Y)
	check(app.raw_text_layer.text == "version two" and on_disk(n).contains("version two"), "Ctrl+Y outside the editor redoes it")
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z, true)
	check(app.raw_text_layer.text == "version two", "Ctrl+Shift+Z still redoes")

	# ── In the editor, Ctrl+Z is the TextEdit's undo only ──
	app._switch_layer("raw")
	var editor: TextEdit = app.raw_text_layer
	editor.grab_focus()
	editor.set_caret_line(editor.get_line_count() - 1)
	editor.set_caret_column(editor.get_line(editor.get_line_count() - 1).length())
	for words in [" first step", " second step"]:
		editor.begin_complex_operation()
		editor.insert_text_at_caret(words)
		editor.end_complex_operation()
	await frames(1)
	var depth: int = UndoRedoEngine.get_undo_depth()
	check(depth > 0 and editor.text == "version two first step second step", "(the app has history; the editor has two steps of its own)")
	await press_ctrl(KEY_Z)
	check(editor.text == "version two first step", "Ctrl+Z in the editor undoes one TextEdit step (%s)" % editor.text)
	check(UndoRedoEngine.get_undo_depth() == depth and on_disk(n).contains("version two") and not on_disk(n).contains("version one"), "…and not the app's history too")
	app._flush_pending_save()
	editor.release_focus()

	# ── Undo skips a step that wouldn't change anything ──
	await type_and_save("version three")
	await type_and_save("version three")
	UndoRedoEngine.push_snapshot(n)   # e.g. a rename: same text
	app._undo()
	await frames(1)
	check(app.raw_text_layer.text == "version two first step", "one undo always changes the text (%s)" % app.raw_text_layer.text)

	# ── A delete newer than the last edit is undone first ──
	await type_and_save("before the delete")
	var other: ContentLayer = VaultStore.note_list[VaultStore.get_note_index("Other Note")]
	app._open_note(other)
	app._on_delete_note_pressed()
	await frames(2)
	check(VaultStore.get_note_index("Other Note") < 0, "(Other Note is deleted)")
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(VaultStore.get_note_index("Other Note") >= 0 and app.current_note != null and app.current_note.title == "Other Note", "Ctrl+Z after a delete restores the deleted note first")
	check(on_disk(n).contains("before the delete"), "…and leaves the earlier edit alone")
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(not on_disk(n).contains("before the delete") and app.current_note == n, "the next Ctrl+Z undoes the edit before it")

	# ── An edit newer than the delete is undone first ──
	other = VaultStore.note_list[VaultStore.get_note_index("Other Note")]
	app._open_note(other)
	app._on_delete_note_pressed()
	await frames(2)
	app._open_note(n)
	await type_and_save("after the delete")
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(not on_disk(n).contains("after the delete") and VaultStore.get_note_index("Other Note") < 0, "an edit after a delete is undone before the delete")
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(VaultStore.get_note_index("Other Note") >= 0, "…and the next Ctrl+Z restores the deleted note")

	await history_follows_its_note()
	await outside_edits_are_never_undone_over()
	await history_stays_in_its_vault()

	app.queue_free()
	await frames(2)
	UndoRedoEngine.clear()
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


## Open `note` in the editor, as a sidebar click does.
func open(note: ContentLayer) -> void:
	app._refresh_note_list()
	app._open_note(note)
	await frames(1)


## Rewrite `file` the way a sync tool or another editor does, swapping `from` for `to`.
func rewrite_outside(file: String, from: String, to: String) -> void:
	var text: String = FileAccess.get_file_as_string(file).replace(from, to)
	var f := FileAccess.open(file, FileAccess.WRITE)
	f.store_string(text)
	f.close()


# ── A step belongs to the note it was taken of ──────────────────────────────

## Moving a note keeps its history; another note with the same title, or a
## new note at the path a deleted one left free, never gets it.
func history_follows_its_note() -> void:
	UndoRedoEngine.clear()
	var a: ContentLayer = VaultStore.create_note("untitled")
	var b: ContentLayer = VaultStore.create_note("untitled")
	b.raw_text = "BETA precious words"
	VaultStore.save_note(b)
	await open(a)
	await type_and_save("alpha one")
	await type_and_save("alpha two")
	VaultStore.create_folder("F")
	check(app.move_note_to(a, "F") and VaultStore.folder_of(a) == "F", "(A, titled untitled, is moved to F)")
	b.modified = "2999-01-01T00:00:00"   # B, also untitled, is the newest note with that title
	VaultStore.save_note(b, false)
	app._refresh_note_list()
	var b_file: String = on_disk(b)
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(on_disk(a).contains("alpha one") and not on_disk(a).contains("alpha two") and a.raw_text == "alpha one", "Ctrl+Z after moving a note undoes its edit at its new path (%s)" % a.raw_text)
	check(on_disk(b) == b_file and b.raw_text == "BETA precious words", "…and never writes into another note with the same title (%s)" % b.raw_text)
	check(app.current_note == a, "…and opens the moved note (%s)" % (app.current_note.resource_path.get_file() if app.current_note else "none"))

	# A new note takes the path of a deleted one: the deleted note's history isn't its
	UndoRedoEngine.clear()
	var c: ContentLayer = VaultStore.create_note("Path Reuse")
	await open(c)
	await type_and_save("old words one")
	await type_and_save("old words two")
	var c_path: String = c.resource_path
	app._on_delete_note_pressed()
	await frames(1)
	var c2: ContentLayer = VaultStore.create_note("Path Reuse")
	c2.raw_text = "a new note, its own words"
	VaultStore.save_note(c2)
	check(c2.resource_path == c_path and c2 != c, "(a new note takes the deleted note's path)")
	await open(c2)
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(app.current_note == c and c.resource_path != c_path and on_disk(c).contains("old words two"), "(Ctrl+Z restores the deleted note beside its old path, which the new note has)")
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(on_disk(c).contains("old words one") and c.raw_text == "old words one", "the next Ctrl+Z undoes the restored note's last edit (%s)" % c.raw_text)
	check(on_disk(c2).contains("a new note, its own words") and c2.raw_text == "a new note, its own words", "…and never writes it into the new note at its old path (%s)" % c2.raw_text)


# ── Undo never writes over an outside edit ──────────────────────────────────

func outside_edits_are_never_undone_over() -> void:
	UndoRedoEngine.clear()
	var s: ContentLayer = VaultStore.create_note("Shared")
	await open(s)
	app._switch_layer("raw")
	await type_and_save("my v1")
	await type_and_save("my v2")
	var file: String = s.resource_path
	OS.delay_msec(1100)
	rewrite_outside(file, "my v2", "OUTSIDE v3 from the other laptop")
	app.raw_text_layer.text = "my v2 plus"
	app.raw_text_layer.text_changed.emit()   # typed: the autosave is pending
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	var i: int = VaultStore.get_note_index("Shared (conflict copy)")
	check(i >= 0 and VaultStore.note_list[i].raw_text == "my v2 plus", "Ctrl+Z with a pending edit that meets an outside edit saves the edit as a conflict copy")
	check(FileAccess.get_file_as_string(file).contains("OUTSIDE v3") and s.raw_text.contains("OUTSIDE v3"), "…and the same keypress doesn't undo over the outside edit (%s)" % s.raw_text)
	check(app.status_label.text.contains("changed on disk"), "…and the status says what happened (%s)" % app.status_label.text)
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(FileAccess.get_file_as_string(file).contains("OUTSIDE v3") and s.raw_text.contains("OUTSIDE v3"), "a later Ctrl+Z doesn't write the app's old text over it either (%s)" % s.raw_text)

	# An outside edit the watcher brought in is not undone over either
	UndoRedoEngine.clear()
	var w: ContentLayer = VaultStore.create_note("Watched")
	await open(w)
	await type_and_save("mine one")
	await type_and_save("mine two")
	OS.delay_msec(1100)
	rewrite_outside(w.resource_path, "mine two", "THEIRS from outside")
	app.check_disk_changes()
	await frames(1)
	check(app.current_note == w and app.raw_text_layer.text == "THEIRS from outside", "(the watcher shows the outside edit)")
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(on_disk(w).contains("THEIRS from outside") and w.raw_text == "THEIRS from outside", "Ctrl+Z doesn't write the app's earlier text over an outside edit the watcher reloaded (%s)" % w.raw_text)


# ── History stays in its vault ──────────────────────────────────────────────

func history_stays_in_its_vault() -> void:
	UndoRedoEngine.clear()
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	var V2: String = ProjectSettings.globalize_path("user://test-vault-undo-2/")
	TestVault.remove_tree(V2)
	DirAccess.make_dir_recursive_absolute(V2)
	app.switch_vault(V2)
	var theirs: ContentLayer = VaultStore.create_note("Ideas")
	theirs.raw_text = "vault two: my ideas from last month"
	VaultStore.save_note(theirs)
	var theirs_file: String = theirs.resource_path
	app.switch_vault(V)
	var ideas: ContentLayer = VaultStore.create_note("Ideas")
	await open(ideas)
	await type_and_save("vault one v1")
	await type_and_save("vault one v2")
	app.switch_vault(V2)
	await frames(2)
	check(VaultStore.vault_path == V2, "(switched to the second vault)")
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	var text: String = FileAccess.get_file_as_string(theirs_file)
	check(text.contains("vault two: my ideas") and not text.contains("vault one"), "Ctrl+Z after a vault switch never writes the old vault's history into a note of the same title")
	check(not app.status_label.text.contains("Undid"), "…nor says it undid something (%s)" % app.status_label.text)
	app._execute_command("undo")
	text = FileAccess.get_file_as_string(theirs_file)
	check(text.contains("vault two: my ideas") and not text.contains("vault one"), "…and neither does the palette's Undo")
	app.switch_vault(V)
	await frames(2)
	check(on_disk(ideas).contains("vault one v2"), "(the first vault's note is as it was)")
	if registry_backup != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	TestVault.remove_tree(V2)
