extends SceneTree
## Closing the window (Alt+F4, Cmd+Q, the close button) or switching to another
## app right after typing, inside the 0.8 s autosave delay, saves the words
## first. Before, note.gd handled only FOCUS_IN and the last edit was lost.
##   headless:  godot --headless --path . -s res://tests/close_flush_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")
const NOTE: String = "Tutorial 1: Writing Notes"

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func on_disk(note: ContentLayer) -> String:
	return FileAccess.get_file_as_string(note.resource_path)


## Type `words` at the end of the open note, the way a keystroke does.
func type_words(app: Control, words: String) -> void:
	app.raw_text_layer.text += words
	app.raw_text_layer.text_changed.emit()


## Type, then send `what` before the autosave timer fires: the words must be
## on disk when the notification returns.
func type_then_notify(app: Control, what: int, label: String) -> void:
	var words: String = "\nTyped just before %s." % label
	type_words(app, words)
	check(not app._auto_save_timer.is_stopped(), "%s: the autosave is still pending after typing" % label)
	check(not on_disk(app.current_note).contains(words), "%s: …so the words are not on disk yet" % label)
	get_root().propagate_notification(what)
	check(on_disk(app.current_note).contains(words), "%s: the words are on disk when the notification returns" % label)
	check(app._auto_save_timer.is_stopped(), "%s: nothing is left pending" % label)
	check(app.status_label.text == "Saved", "%s: the status bar says Saved (%s)" % [label, app.status_label.text])
	await frames(2)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_close_flush.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_close_flush.json"   # never touch real progress
	ProgressStore.reset()
	TestVault.open("close-flush")
	await frames(2)

	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.open_note_by_title(NOTE)
	app._switch_layer("raw")
	await frames(2)
	check(app.current_note != null and app.current_note.title == NOTE, "opened \"%s\"" % NOTE)

	# Nothing pending: closing writes nothing (no spurious rename or re-save)
	var before: String = FileAccess.get_sha256(app.current_note.resource_path)
	get_root().propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check(FileAccess.get_sha256(app.current_note.resource_path) == before and app.current_note.title == NOTE, "a close with nothing pending leaves the file as it is")

	await type_then_notify(app, Node.NOTIFICATION_WM_CLOSE_REQUEST, "closing the window")
	await type_then_notify(app, Node.NOTIFICATION_APPLICATION_FOCUS_OUT, "switching to another app")

	# A title typed but not yet committed (no Enter, no focus change) plus body
	# text, then the window closes: both land in the note's file, which the
	# rename gives the new title's name (VaultStore.rename_note).
	var note: ContentLayer = app.current_note
	var path: String = note.resource_path
	app.title_edit.text = "Writing Notes, renamed before quitting"
	type_words(app, "\nAnd a last line.")
	get_root().propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	var renamed: String = path.get_base_dir().path_join(VaultStore.filename_stem("Writing Notes, renamed before quitting") + ".tres")
	var text: String = FileAccess.get_file_as_string(renamed)
	check(text.contains("Writing Notes, renamed before quitting"), "a pending title edit is saved on close")
	check(text.contains("And a last line."), "…together with the pending body text")
	check(app.current_note == note and note.resource_path == renamed and not FileAccess.file_exists(path) and note.title == "Writing Notes, renamed before quitting",
		"…as a rename of the same note, its file renamed with it, not a new note (%s)" % note.resource_path.get_file())
	check(VaultStore.get_note_index(NOTE) < 0, "…and the old title is gone from the note list")

	# The same on focus-out: a title typed in the field is committed.
	app.title_edit.text = "Writing Notes, renamed on focus-out"
	get_root().propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	path = app.current_note.resource_path
	check(path.get_file() == VaultStore.filename_stem("Writing Notes, renamed on focus-out") + ".tres" and FileAccess.get_file_as_string(path).contains("Writing Notes, renamed on focus-out"),
		"a pending title edit is saved when the app loses focus (%s)" % path.get_file())

	# The file changed outside the app while a title and body edit were
	# pending: the close keeps the outside version and writes both edits as a
	# conflict copy before the handler returns.
	var outside: String = FileAccess.get_file_as_string(path).replace("And a last line.", "Edited in another program.")
	var out := FileAccess.open(path, FileAccess.WRITE)
	out.store_string(outside)
	out.close()
	app.title_edit.text = "Writing Notes, renamed during a conflict"
	type_words(app, "\nWords typed during the conflict.")
	get_root().propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	var copy: ContentLayer = app.current_note
	check(FileAccess.get_file_as_string(path).contains("Edited in another program.") and not FileAccess.get_file_as_string(path).contains("Words typed during the conflict."), "conflict on close: the outside edit is kept")
	check(copy != null and copy.resource_path != path and copy.title.begins_with("Writing Notes, renamed during a conflict (conflict copy"), "…the editor holds the conflict copy (%s)" % (copy.title if copy else "none"))
	check(copy != null and FileAccess.get_file_as_string(copy.resource_path).contains("Words typed during the conflict."), "…which is on disk with the typed words when the handler returns")
	check(app.raw_text_layer.text.contains("Words typed during the conflict."), "…and they are still on screen")

	# Deleting another folder doesn't drop a pending edit: the close still
	# saves it. (delete_folder used to stop the autosave timer for any
	# folder, and the close flush only looked at that timer.)
	VaultStore.create_folder("Unrelated Folder")
	type_words(app, "\nTyped just before deleting another folder.")
	app.delete_folder("Unrelated Folder")
	check(not DirAccess.dir_exists_absolute(VaultStore.vault_path + "Unrelated Folder"), "(the other folder is deleted)")
	get_root().propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check(on_disk(app.current_note).contains("Typed just before deleting another folder."), "a pending edit survives deleting an unrelated folder and is saved on close")

	await test_outside_rename_kept(app)

	app.queue_free()
	await frames(2)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


## Claude (MCP update_note) or a sync tool renames the open note, then the
## user switches apps, closes the window or clicks in and out of the title
## field without typing: the outside title stays. Before, focus-out compared
## the field with the reloaded note and wrote the old title back
## ("Renamed to <old title>"), with no conflict copy since the hash matched.
## update_note renames the note's file with its title (links-names), so the
## old file must not be written again either, and the watcher follows the
## note to its new file.
func test_outside_rename_kept(app: Control) -> void:
	var pinned: ContentLayer = VaultStore.create_note("Pinned Elsewhere")
	VaultStore.set_pinned(pinned, true)   # leads note_list, so the watcher can't just open the first note
	var n: ContentLayer = VaultStore.create_note("Title From The App")
	n.raw_text = "A note Claude will rename."
	VaultStore.save_note(n)
	app._refresh_note_list()
	app.open_note_by_title("Title From The App")
	await frames(2)
	var path: String = n.resource_path
	var tools: RefCounted = VaultTools.new(VaultStore.vault_path)
	var rel: String = path.substr(VaultStore.vault_path.length())

	# Renamed outside, and the app loses focus before its watcher has looked
	OS.delay_msec(1100)   # mtimes have one-second resolution
	var h: String = tools.call_tool("read_note", {"path": rel}).structuredContent.hash
	var r: Dictionary = tools.call_tool("update_note", {"path": rel, "hash": h, "title": "Title From Claude"})
	var new_rel: String = str(r.get("structuredContent", {}).get("path", ""))
	var moved: String = VaultStore.vault_path + new_rel
	check(not r.isError and new_rel != rel and FileAccess.get_file_as_string(moved).contains("Title From Claude") and not FileAccess.file_exists(path),
		"outside rename: MCP update_note renames the open note and its file (%s)" % new_rel)
	get_root().propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(FileAccess.get_file_as_string(moved).contains("Title From Claude") and not FileAccess.get_file_as_string(moved).contains("Title From The App") and not FileAccess.file_exists(path),
		"outside rename, then focus-out before the watcher ran: the outside title stays, and the old file isn't written again")

	# The watcher (or focus-in) picks it up: the editor follows the note to
	# its new file, and the title field shows the new title
	app.check_disk_changes()
	await frames(2)
	n = app.current_note
	check(n != null and n.title == "Title From Claude" and n.resource_path == moved, "outside rename: the open note has the new title, in its new file (%s)" % (n.resource_path.get_file() if n else "none"))
	check(app.title_edit.text == "Title From Claude", "outside rename: the title field shows it (%s)" % app.title_edit.text)
	path = moved
	rel = new_rel

	# Focus-out, leaving the title field untouched, and closing write nothing back
	var sha: String = FileAccess.get_sha256(path)
	get_root().propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	app.title_edit.focus_exited.emit()
	get_root().propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check(FileAccess.get_sha256(path) == sha and FileAccess.get_file_as_string(path).contains("Title From Claude"), "outside rename: focus-out, leaving the field and close keep the file as it is")
	check(not app.status_label.text.begins_with("Renamed to"), "outside rename: no rename is reported (%s)" % app.status_label.text)

	# Retitled outside again, this time inside its file (a sync tool or
	# another editor; update_note would rename the file too). A rescan before
	# the watcher looked (any other save runs one) leaves the open note to
	# the editor; even reloaded in place before the field is refreshed (the
	# watcher's VaultStore half), leaving the untouched field still writes
	# nothing
	OS.delay_msec(1100)
	var retitled: ContentLayer = n.duplicate()
	retitled.title = "Title From Claude, Again"
	ResourceSaver.save(retitled, path)
	VaultStore.refresh_note_list()
	check(n.title == "Title From Claude", "outside rename: a rescan doesn't reload the open note under the editor")
	VaultStore.refresh_note_list(true)
	check(n.title == "Title From Claude, Again" and app.title_edit.text == "Title From Claude", "(the note is reloaded; the field is not refreshed yet)")
	app.title_edit.focus_exited.emit()
	app.title_edit.text_submitted.emit(app.title_edit.text)
	get_root().propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(FileAccess.get_file_as_string(path).contains("Title From Claude, Again"), "outside rename after a rescan: leaving or submitting the untouched field doesn't revert it")

	# A title the user did type is still committed on focus-out (and names the file)
	app.check_disk_changes()
	await frames(2)
	app.title_edit.text = "Title Typed By The User"
	get_root().propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	path = app.current_note.resource_path
	check(FileAccess.get_file_as_string(path).contains("Title Typed By The User"), "a title the user typed is still saved on focus-out (%s)" % path.get_file())
