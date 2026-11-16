extends SceneTree
## Words only the app holds (a note whose save failed, a deleted note whose
## _trashed entry keeps what its file lacks) are never dropped without a
## warning: a vault switch held once over some words holds again over new
## ones.
##   headless:  godot --headless --path . -s res://tests/held_words_test.gd
## The read-only cases use chmod, so they run on Linux and macOS only.

const TestVault = preload("res://tests/test_vault.gd")
const VAULT_NAME: String = "held-words"

var fails: int = 0
var app: Control
var V: String = ""


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func chmod(mode: String, path: String) -> void:
	OS.execute("chmod", [mode, path])


## Open `n` in Edit view and type `words` at the end of it, the way a keystroke does.
func type_into(n: ContentLayer, words: String) -> void:
	app._open_note(n)
	app._switch_layer("raw")
	app.raw_text_layer.text += words
	app.raw_text_layer.text_changed.emit()


## A real left click on `ctrl` inside the dialog window `win`.
func click_in(win: Window, ctrl: Control) -> void:
	var pos: Vector2 = Vector2(win.position) + ctrl.get_global_rect().get_center()
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


## A real key press of `code` (with Ctrl when `ctrl`), through the viewport
## to whatever holds the keyboard, or to the app's _unhandled_input.
func press(code: Key, ctrl: bool = false) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.ctrl_pressed = ctrl
		e.pressed = pressed
		get_root().push_input(e)
	await frames(2)


## A note `title` in `folder` holding `body`, saved.
func make_note(title: String, body: String, folder: String = "") -> ContentLayer:
	var n: ContentLayer = VaultStore.create_note(title, folder)
	n.raw_text = body
	VaultStore.save_note(n)
	return n


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_held_words.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_held_words.json"   # never touch real progress
	ProgressStore.reset()
	var old: String = ProjectSettings.globalize_path("user://test-vault-%s/" % VAULT_NAME)
	if DirAccess.dir_exists_absolute(old) and OS.get_name() in ["Linux", "macOS"]:
		OS.execute("chmod", ["-R", "u+w", old])   # a run that died mid-test left files read-only
	V = TestVault.open(VAULT_NAME, false)
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	make_note("Anchor", "Always here.")
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)

	if OS.get_name() in ["Linux", "macOS"]:
		await switch_holds_again()
		await folder_move_fails()
		await folder_delete_keeps_words()
		await folder_delete_ctrl_z_from_editor()
		await close_waits_for_words()
		await rename_retried()
		await rename_retried_linker_open(false)
		await rename_retried_linker_open(true)
	else:
		print("SKIP  read-only cases (chmod) on " + OS.get_name())
	await open_vault_picked_again()

	if VaultStore.vault_path != V:
		app.switch_vault(V)
	app.queue_free()
	await frames(2)
	if registry_backup != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	OS.execute("chmod", ["-R", "u+w", V])
	TestVault.remove_tree(V)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


## A switch held over X's words, X then restored and saved, and later Y's
## words at risk: the same switch holds again instead of leaving at once
## (it used to remember the path alone, so it went through and dropped Y).
func switch_holds_again() -> void:
	var V2: String = ProjectSettings.globalize_path("user://test-vault-%s-2/" % VAULT_NAME)
	TestVault.remove_tree(V2)
	DirAccess.make_dir_recursive_absolute(V2)
	var x: ContentLayer = make_note("Ex", "x saved")
	var y: ContentLayer = make_note("Why", "y saved")
	await frames(1)

	chmod("444", x.resource_path)
	type_into(x, " + X WORDS")
	app._flush_pending_save()
	app._on_delete_note_pressed()
	check(app._trashed.size() == 1 and app._trashed.back().has("unsaved"), "(Ex couldn't be saved and was deleted: its delete holds its words)")
	app.switch_vault(V2)
	check(VaultStore.vault_path == V and app.status_label.text.begins_with("Didn't switch vaults."), "a vault switch holds while Ex's words are at risk (%s)" % app.status_label.text)
	app._restore_last_trashed()
	chmod("644", x.resource_path)
	app._flush_pending_save()
	check(app._words_at_risk() == "" and FileAccess.get_file_as_string(x.resource_path).contains("X WORDS"), "(Ex restored and saved: nothing at risk)")

	chmod("444", y.resource_path)
	type_into(y, " + Y WORDS")
	app._flush_pending_save()
	app._on_delete_note_pressed()
	check(app._trashed.size() == 1 and app._trashed.back().title == "Why" and app._trashed.back().has("unsaved"), "(Why couldn't be saved and was deleted)")
	app.switch_vault(V2)
	check(VaultStore.vault_path == V, "the same switch over Why's words holds again, not at once")
	check(app._trashed.size() == 1 and app._trashed.back().title == "Why", "…and keeps Why's delete for Ctrl+Z (%d)" % app._trashed.size())
	check(app.status_label.text.begins_with("Didn't switch vaults.") and app.status_label.text.contains("“Why”"), "…and says why (%s)" % app.status_label.text)
	app.switch_vault(V2)
	check(VaultStore.vault_path == V2, "switching again over the same words goes ahead")
	app.switch_vault(V)
	await frames(2)
	TestVault.remove_tree(V2)


## Move to trash on a folder that can't be moved (here its trash can't take
## it): the folder stays, and so does all the app holds for its notes. The
## open note's pending edit still saves, and a note whose save failed is
## still unsaved and at risk, not forgotten under a "Moved" status.
func folder_move_fails() -> void:
	VaultStore.create_folder("Stuck")
	var locked: ContentLayer = make_note("Stuck Locked", "locked saved", "Stuck")
	var open: ContentLayer = make_note("Stuck Open", "open saved", "Stuck")
	var trash: String = V + VaultStore.TRASH_DIR
	DirAccess.make_dir_recursive_absolute(trash)
	chmod("555", trash)   # .trash can't take the folder
	chmod("444", locked.resource_path)
	type_into(locked, " + LOCKED WORDS")
	app._flush_pending_save()
	check(app._unsaved.has(locked), "(Stuck Locked couldn't be saved)")
	type_into(open, " + PENDING WORDS")
	app.delete_folder("Stuck")
	check(DirAccess.dir_exists_absolute(V + "Stuck"), "(the folder couldn't be moved)")
	check(app.status_label.text.begins_with("Couldn't move the folder “Stuck” to the trash"), "a folder that can't be moved says so, not Moved (%s)" % app.status_label.text)
	check(app.current_note == open and app.raw_text_layer.text == "open saved + PENDING WORDS", "…keeps its open note in the editor")
	check(app._unsaved.has(locked) and app._words_at_risk().contains("Stuck Locked"), "…and keeps the unsaved note unsaved, at risk and retried")
	app._flush_pending_save()
	check(FileAccess.get_file_as_string(open.resource_path).contains("PENDING WORDS"), "the open note's pending edit still saves")
	chmod("755", trash)
	chmod("644", locked.resource_path)
	app._flush_pending_save()
	check(FileAccess.get_file_as_string(locked.resource_path).contains("LOCKED WORDS") and app._unsaved.is_empty(), "the unsaved note's words reach the disk once it is writable")


## Move to trash on a folder holding a note whose save failed: the trashed
## file lacks its words, so the delete keeps them as a note Delete does
## (status, _words_at_risk, Ctrl+Z writes the note again with them). The
## open note's pending edit is saved first, so its trashed file has it.
func folder_delete_keeps_words() -> void:
	VaultStore.create_folder("Box")
	var boxed: ContentLayer = make_note("Boxed", "boxed saved", "Box")
	var open: ContentLayer = make_note("Boxed Open", "open saved", "Box")
	var boxed_path: String = boxed.resource_path
	chmod("444", boxed_path)
	type_into(boxed, " + BOXED WORDS")
	app._flush_pending_save()
	check(app._unsaved.has(boxed), "(Boxed couldn't be saved)")
	type_into(open, " + OPEN PENDING")
	app.raw_text_layer.grab_focus()   # typing there: the editor has the keyboard
	app.delete_folder("Box")
	var trashed_open: String = V + VaultStore.TRASH_DIR.path_join("Box").path_join(open.resource_path.get_file())
	check(not DirAccess.dir_exists_absolute(V + "Box"), "(the folder went to the trash)")
	check(FileAccess.get_file_as_string(trashed_open).contains("OPEN PENDING"), "the open note's pending edit was saved before its folder went to the trash")
	check(app.status_label.text.contains("without the words “Boxed” couldn't save") and app.status_label.text.contains("Ctrl+Z restores it with them"), "the status says Boxed went without its unsaved words (%s)" % app.status_label.text)
	check(app._words_at_risk().contains("“Boxed”"), "…a vault switch would wait for them (%s)" % app._words_at_risk())
	check(not app._trashed.is_empty() and app._trashed.back().title == "Boxed" and str(app._trashed.back().get("unsaved", {}).get("raw_text", "")).contains("BOXED WORDS"), "…the delete keeps them")
	# Another delete (the MCP server's delete_note) puts a file of its own at
	# the free trash path the entry names: the restore must not take it
	var slot: String = V + str(app._trashed.back().trash_rel) if not app._trashed.is_empty() else ""
	var decoy: String = FileAccess.get_file_as_string(trashed_open).replace("Boxed Open", "Decoy")
	if slot != "":
		var f := FileAccess.open(slot, FileAccess.WRITE)
		f.store_string(decoy)
		f.close()
	var focus: Control = get_root().gui_get_focus_owner()
	check(not focus is TextEdit and not focus is LineEdit, "…and no text field keeps the keyboard, so the Ctrl+Z it offers reaches the app (%s)" % focus)
	await press(KEY_Z, true)
	check(app.current_note == boxed and app.raw_text_layer.text == "boxed saved + BOXED WORDS", "Ctrl+Z brings Boxed back with its words, the same note object (%s)" % app.raw_text_layer.text)
	check(boxed.resource_path == boxed_path and FileAccess.get_file_as_string(boxed_path).contains("BOXED WORDS"), "…written again in its place (%s)" % boxed.resource_path)
	check(app._trashed.is_empty() and app._unsaved.is_empty() and app._words_at_risk() == "", "…with nothing left at risk")
	check(app.status_label.text.begins_with("Restored “Boxed”"), "…and says so (%s)" % app.status_label.text)
	check(slot != "" and FileAccess.get_file_as_string(slot) == decoy, "…leaving another deleted note's file at its trash path where it was")


## The folder menu's Move to trash…, confirmed with a click on the dialog's
## OK, while another note open outside the folder has the keyboard: the
## status offers Ctrl+Z, and a real Ctrl+Z restores the kept words. The
## editor kept the keyboard through the menu and the dialog, so it took
## that Ctrl+Z as its own undo: it undid the typing in the open note (then
## autosaved) and the folder's note stayed in the trash.
func folder_delete_ctrl_z_from_editor() -> void:
	VaultStore.create_folder("Crate")
	var crated: ContentLayer = make_note("Crated", "crated saved", "Crate")
	var elsewhere: ContentLayer = make_note("Elsewhere", "elsewhere text")
	chmod("444", crated.resource_path)
	type_into(crated, " + CRATED WORDS")
	app._flush_pending_save()
	check(app._unsaved.has(crated), "(Crated couldn't be saved)")
	type_into(elsewhere, " typed")
	app.raw_text_layer.grab_focus()
	app._flush_pending_save()
	await frames(2)
	app._ctx_target = {"type": "folder", "rel": "Crate"}
	app._on_ctx_menu(4)
	await frames(3)
	var dlg: ConfirmationDialog = null
	for c in app.get_children():
		if c is ConfirmationDialog and c.visible:
			dlg = c
	check(dlg != null, "(the folder menu asks before moving Crate to the trash)")
	if dlg != null:
		await click_in(dlg, dlg.get_ok_button())
	check(app.status_label.text.contains("without the words “Crated” couldn't save  ·  Ctrl+Z restores it with them"), "menu: the status offers Ctrl+Z for Crated's words (%s)" % app.status_label.text)
	var focus: Control = get_root().gui_get_focus_owner()
	check(not focus is TextEdit and not focus is LineEdit, "menu: …and the editor lets go of the keyboard (%s)" % focus)
	await press(KEY_Z, true)
	check(app.current_note == crated and app.raw_text_layer.text == "crated saved + CRATED WORDS", "menu: a real Ctrl+Z restores Crated with its words (%s)" % app.raw_text_layer.text)
	app._flush_pending_save()   # an editor undo would be autosaved
	check(elsewhere.raw_text == "elsewhere text typed" and FileAccess.get_file_as_string(elsewhere.resource_path).contains("elsewhere text typed"), "menu: …and leaves the typing in the other note alone (%s)" % elsewhere.raw_text)
	check(app._trashed.is_empty() and app._words_at_risk() == "", "menu: …with nothing left at risk")


## Send `what` to `node` and down its tree, but not into a child Window,
## the way the engine sends a window's close request
## (Window::_propagate_window_notification). Node.propagate_notification
## would reach the app's own dialogs too, and a dialog cancels itself on it.
func notify_window(node: Node, what: int) -> void:
	node.notification(what)
	for child in node.get_children():
		if not child is Window:
			notify_window(child, what)


## Close the window the way the engine does: the notification, then the root
## window's close_requested (SceneTree quits on it unless auto_accept_quit
## is off). It is sent only once the app has turned that off, so a missing
## guard fails here instead of ending the test.
func send_close() -> void:
	notify_window(get_root(), Node.NOTIFICATION_WM_CLOSE_REQUEST)
	if not auto_accept_quit:
		get_root().close_requested.emit()
	await frames(2)


## Closing the window while a save has failed again, or a deleted note keeps
## words its file lacks, asks first (Quit anyway / Keep open) instead of
## quitting with them; with nothing at risk the close goes ahead.
func close_waits_for_words() -> void:
	var n: ContentLayer = make_note("Closing", "closing saved")
	chmod("444", n.resource_path)
	type_into(n, " + CLOSING WORDS")
	app._flush_pending_save()
	check(app._unsaved.has(n), "(Closing couldn't be saved)")
	await send_close()
	var dlg: ConfirmationDialog = app.get("_quit_dialog")
	check(not auto_accept_quit and dlg != null and dlg.visible, "a close while a save still fails waits and asks")
	check(dlg != null and dlg.dialog_text.contains("Couldn't save “Closing”") and dlg.ok_button_text == "Quit anyway" and dlg.cancel_button_text == "Keep open", "…saying which words a quit would lose")
	if dlg != null:
		await click_in(dlg, dlg.get_cancel_button())
	check(app.get("_quit_dialog") == null and app.status_label.text.begins_with("Didn't quit."), "Keep open keeps the window, and the status says why (%s)" % app.status_label.text)
	check(app._unsaved.has(n) and app.raw_text_layer.text.contains("CLOSING WORDS"), "…with the words still there")

	app._on_delete_note_pressed()
	check(not app._trashed.is_empty() and app._trashed.back().has("unsaved"), "(Closing deleted: only its delete holds the words)")
	await send_close()
	dlg = app.get("_quit_dialog")
	check(dlg != null and dlg.dialog_text.contains("“Closing” is in the trash without the words"), "a close while a deleted note keeps unsaved words asks too")
	if dlg != null:
		await click_in(dlg, dlg.get_cancel_button())

	app._restore_last_trashed()
	chmod("644", n.resource_path)
	app._flush_pending_save()
	check(app._words_at_risk() == "", "(restored and saved: nothing at risk)")
	notify_window(get_root(), Node.NOTIFICATION_WM_CLOSE_REQUEST)   # not close_requested: that would end the test
	await frames(2)
	check(auto_accept_quit and app.get("_quit_dialog") == null, "with nothing at risk a close goes ahead, asking nothing")


## A rename whose save fails keeps the new title in memory and retries it.
## Once the retry saves, the rename finishes: the file takes the title's
## name and the links, progress and Journey keys that named the old title
## follow (they stayed behind, and a [[link]] click made a new empty note).
## A second rename meanwhile cascades from the title links still name.
func rename_retried() -> void:
	var old: ContentLayer = make_note("Elder", "elder text")
	var linker: ContentLayer = make_note("Pointer", "See [[Elder]] here.")
	ProgressStore.record_result("Elder", 0, 1, 1)
	var old_file: String = old.resource_path
	app._open_note(old)
	chmod("444", old_file)
	app.title_edit.text = "Younger"
	app._commit_title()
	check(app._unsaved.has(old) and app.status_label.text.begins_with("Couldn't save “Younger”"), "(the rename couldn't be saved: %s)" % app.status_label.text)
	chmod("644", old_file)
	app._retry_timer.timeout.emit()
	var new_file: String = V + "note_younger.tres"
	check(app._unsaved.is_empty() and old.title == "Younger", "(the retry saved the new title)")
	check(old.resource_path == new_file and FileAccess.file_exists(new_file) and not FileAccess.file_exists(old_file), "…and the file took the title's name (%s)" % old.resource_path.get_file())
	check(linker.raw_text == "See [[Younger]] here." and FileAccess.get_file_as_string(linker.resource_path).contains("[[Younger]]"), "…and the link to it follows (%s)" % linker.raw_text)
	check(ProgressStore.quiz_passed("Younger", 0) and not ProgressStore.quiz_passed("Elder", 0), "…and so does its quiz progress")

	# Renamed twice, the first save failing: links move from the title they name
	chmod("444", new_file)
	app.title_edit.text = "Youngest"
	app._commit_title()
	check(app._unsaved.has(old), "(a second rename couldn't be saved either)")
	chmod("644", new_file)
	app.title_edit.text = "Newest"
	app._commit_title()
	check(old.title == "Newest" and old.resource_path == V + "note_newest.tres" and app._unsaved.is_empty(), "a rename after it saves, under the latest title (%s)" % old.resource_path.get_file())
	check(linker.raw_text == "See [[Newest]] here.", "…and moves the links from the title they named (%s)" % linker.raw_text)


## The retry (`typing` false) or a flush after typing finishes a rename
## while another note is open, one linking to the old title: the editor
## shows its rewritten link, with the words typed there kept, so its next
## save doesn't write the old [[link]] back over the rewrite (left dangling,
## a click on it made a new empty note). A retry while the user types keeps
## the editor's caret and a title typed but not yet committed.
func rename_retried_linker_open(typing: bool) -> void:
	var how: String = "typing" if typing else "retry"
	var renamed: ContentLayer = make_note("Elder " + how, "elder text")
	var linker: ContentLayer = make_note("Pointer " + how, "See [[Elder %s]] here." % how)
	var old_file: String = renamed.resource_path
	app._open_note(renamed)
	chmod("444", old_file)
	app.title_edit.text = "Younger " + how
	app._commit_title()
	check(app._unsaved.has(renamed), "%s: (the rename couldn't be saved)" % how)
	app._open_note(linker)
	app._switch_layer("raw")
	chmod("644", old_file)
	var rewritten: String = "See [[Younger %s]] here." % how
	if typing:
		app.raw_text_layer.text += " More."
		app.raw_text_layer.text_changed.emit()
		app._flush_pending_save()   # retries the renamed note first, then saves the typing
		check(app.raw_text_layer.text == rewritten + " More.", "typing: the editor shows the rewritten link with the words typed (%s)" % app.raw_text_layer.text)
	else:
		app.raw_text_layer.set_caret_column(7)
		app.title_edit.text = "Pointer renamed by hand"   # typed, not committed
		app._retry_timer.timeout.emit()
		check(app.raw_text_layer.text == rewritten, "retry: the open note that links to it shows the rewritten link (%s)" % app.raw_text_layer.text)
		check(app.raw_text_layer.get_caret_line() == 0 and app.raw_text_layer.get_caret_column() == 7, "retry: …the caret stays where it was (%d:%d)" % [app.raw_text_layer.get_caret_line(), app.raw_text_layer.get_caret_column()])
		check(app.title_edit.text == "Pointer renamed by hand", "retry: …and so does the title typed but not committed (%s)" % app.title_edit.text)
		app.title_edit.text = app._title_shown
		app.raw_text_layer.text += " More."
		app.raw_text_layer.text_changed.emit()
		app._flush_pending_save()
	var on_disk: String = FileAccess.get_file_as_string(linker.resource_path)
	check(renamed.title == "Younger " + how and app._unsaved.is_empty(), "%s: (the rename saved)" % how)
	check(linker.raw_text == rewritten + " More." and on_disk.contains("[[Younger %s]] here. More." % how) and not on_disk.contains("[[Elder %s]]" % how), "%s: the open note's next save keeps the rewritten link and the typed words (%s)" % [how, linker.raw_text])
	check(app.status_label.text == "Saved", "%s: …and says Saved (%s)" % [how, app.status_label.text])


## The vault menu lists the open vault as a checked item, and the Open
## folder dialog can pick its folder: either is no switch. It used to reopen
## the vault, clearing what Ctrl+Z restores, the undo history and Back /
## Forward.
func open_vault_picked_again() -> void:
	VaultRegistry.remember(V)
	var gone: ContentLayer = make_note("Gone Soon", "gone text")
	app._open_note(gone)
	app._on_delete_note_pressed()
	check(app._trashed.size() == 1 and app._trashed.back().title == "Gone Soon", "(Gone Soon deleted: Ctrl+Z would restore it)")
	app._show_vault_menu()
	var checked: int = -1
	for i in range(app._vault_menu.item_count):
		if app._vault_menu.is_item_checked(i):
			checked = app._vault_menu.get_item_id(i)
	app._vault_menu.hide()
	check(checked >= 0, "(the vault menu lists the open vault, checked)")
	app._vault_menu.id_pressed.emit(checked)
	check(app._trashed.size() == 1, "picking the open vault in the menu keeps the deleted note for Ctrl+Z (%d)" % app._trashed.size())
	check(app.status_label.text.begins_with("Already in "), "…and says it is open already (%s)" % app.status_label.text)
	app._vault_dialog.dir_selected.emit(V)
	check(app._trashed.size() == 1 and app.status_label.text.begins_with("Already in "), "so does picking its folder in Open folder as vault…")
	get_root().gui_release_focus()
	app._undo_last_change()
	check(app.current_note == gone and app._trashed.is_empty(), "…and Ctrl+Z still restores it (%s)" % app.status_label.text)
