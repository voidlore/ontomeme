extends SceneTree
## A save that fails (a read-only file or folder, a full disk, a sync tool's
## lock, Windows Controlled Folder Access) says so in the status bar, keeps the
## words in the editor and tries again; it never says "Saved". A new note that
## can't be written is not opened as a phantom.
##   headless:  godot --headless --path . -s res://tests/save_failure_test.gd
## The read-only cases use chmod, so they run on Linux and macOS only.

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")
const VAULT_NAME: String = "save-failure"

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func chmod(mode: String, path: String) -> void:
	OS.execute("chmod", [mode, path])


## Type `words` at the end of the open note, the way a keystroke does.
func type_words(app: Control, words: String) -> void:
	app.raw_text_layer.text += words
	app.raw_text_layer.text_changed.emit()


## True when the OS refuses a new file in `dir` (root ignores permissions).
func write_protected(dir: String) -> bool:
	var probe: String = dir.path_join("probe.tmp")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return true
	f.close()
	DirAccess.remove_absolute(probe)
	return false


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_save_failure.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_save_failure.json"   # never touch real progress
	ProgressStore.reset()
	var old: String = ProjectSettings.globalize_path("user://test-vault-%s/" % VAULT_NAME)
	if DirAccess.dir_exists_absolute(old) and OS.get_name() in ["Linux", "macOS"]:
		OS.execute("chmod", ["-R", "u+w", old])   # a run that died mid-test left folders read-only
	var V: String = TestVault.open(VAULT_NAME, false)
	await frames(2)

	check(VaultStore.save_note(null) != OK, "save_note(null) returns an error")
	var ok_note: ContentLayer = VaultStore.create_note("Fine")
	ok_note.raw_text = "saved"
	check(VaultStore.save_note(ok_note) == OK and VaultStore.last_save_error == "", "a good save returns OK and clears last_save_error")
	test_editor_note_held()

	if OS.get_name() in ["Linux", "macOS"]:
		await test_read_only(V)
	else:
		print("SKIP  read-only cases (chmod) on " + OS.get_name())

	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	TestVault.remove_tree(V)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


func test_read_only(V: String) -> void:
	VaultStore.create_folder("Locked")
	var n: ContentLayer = VaultStore.create_note("Locked Note", "Locked")
	n.raw_text = "Safe on disk."
	VaultStore.save_note(n)
	var file: String = n.resource_path
	var dir: String = file.get_base_dir()

	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.open_note_by_title("Locked Note")
	app._switch_layer("raw")
	await frames(2)
	check(app.current_note == n, "opened the note in Locked/")

	chmod("444", file)
	chmod("555", dir)
	if not write_protected(dir):
		print("SKIP  read-only cases: this user can write to a read-only folder (root?)")
		chmod("755", dir)
		chmod("644", file)
		app.queue_free()
		await frames(2)
		return
	var before: String = FileAccess.get_sha256(file)

	# ── Autosave into a read-only file and folder ──
	type_words(app, "\nTyped while the file was read-only.")
	app._flush_pending_save()
	var status: String = app.status_label.text
	check(status.begins_with("Couldn't save “Locked Note”: "), "the status bar says the save failed (%s)" % status)
	check(status.ends_with("Your text is still here."), "…and that the text is still here")
	check(VaultStore.last_save_error != "" and status.contains(VaultStore.last_save_error), "…with the reason (%s)" % VaultStore.last_save_error)
	check(FileAccess.get_sha256(file) == before, "the file on disk is unchanged")
	check(app.raw_text_layer.text.contains("Typed while the file was read-only."), "the words are still in the editor")
	check(app._unsaved.has(n), "the note is kept as unsaved")
	check(not app._retry_timer.is_stopped() and app._retry_timer.wait_time > app.AUTO_SAVE_DELAY, "a retry is scheduled, on a longer timer (%.1f s)" % app._retry_timer.wait_time)

	app._flush_pending_save()
	check(app.status_label.text.begins_with("Couldn't save"), "a flush retries at once, and still never says Saved")

	# ── Store level ──
	check(VaultStore.save_note(n) != OK and VaultStore.last_save_error.contains(file.get_file()), "VaultStore.save_note returns the error; last_save_error names the file")
	var count: int = VaultStore.note_list.size()
	check(VaultStore.create_note("Cannot Exist", "Locked") == null, "create_note in a read-only folder returns null")
	check(not FileAccess.file_exists(dir.path_join("note_cannot_exist.tres")) and VaultStore.note_list.size() == count and VaultStore.get_note_index("Cannot Exist") < 0, "…and leaves no file and no list entry behind")

	# ── New note in a read-only folder: a message, not a phantom ──
	app._on_new_note_pressed()
	check(app.status_label.text.begins_with("Couldn't create a new note: "), "New note in a read-only folder says so (%s)" % app.status_label.text)
	check(app.current_note == n and VaultStore.note_list.size() == count, "…and keeps the open note instead of opening a phantom")

	# ── Rename that can't be saved ──
	app.title_edit.text = "Locked Renamed"
	app._commit_title()
	check(app.status_label.text.begins_with("Couldn't save “Locked Renamed”: "), "a rename that can't be saved says so (%s)" % app.status_label.text)
	check(FileAccess.get_sha256(file) == before, "…the file is unchanged")
	check(app._unsaved.has(n) and not app._retry_timer.is_stopped(), "…and the rename is retried with the next save")

	# ── [[link]] to a missing note while the vault folder is read-only ──
	chmod("555", V)
	app.open_note_by_title("Linked But Missing", true)
	chmod("755", V)
	check(app.status_label.text.begins_with("Couldn't create “Linked But Missing”: "), "a [[link]] that can't create its note says so (%s)" % app.status_label.text)
	check(app.current_note == n and VaultStore.get_note_index("Linked But Missing") < 0, "…and opens no phantom")
	check(not FileAccess.file_exists(V.path_join("note_linked_but_missing.tres")), "…and writes no file")

	# ── Writable again: the next edit saves everything typed meanwhile ──
	chmod("755", dir)
	chmod("644", file)
	type_words(app, "\nTyped after the folder was writable again.")
	app._flush_pending_save()
	check(app.status_label.text == "Saved", "after the permissions are back, the next save says Saved (%s)" % app.status_label.text)
	var text: String = FileAccess.get_file_as_string(n.resource_path)
	check(text.contains("Typed while the file was read-only.") and text.contains("Typed after the folder was writable again."), "…and the text typed during the failure is on disk")
	check(text.contains("Locked Renamed"), "…and so is the rename")
	check(n.resource_path.get_file() == "note_locked_renamed.tres" and not FileAccess.file_exists(file), "…whose file now takes the title's name, as a rename that saved at once does (%s)" % n.resource_path.get_file())
	check(app._unsaved.is_empty() and app._retry_timer.is_stopped() and app._auto_save_timer.is_stopped(), "…and no retry is left pending")
	app.queue_free()
	await frames(2)

	await test_leave_unsaved_note(V)
	test_unsaved_survives_rescan()
	for how in ["focus-out", "retry timer", "idle", "watcher"]:
		await test_outside_edit_while_another_is_unsaved(how)
	await test_read_only_file()

	# ── A conflict copy that can't be written is an error too ──
	VaultStore.create_folder("Locked2")
	var c: ContentLayer = VaultStore.create_note("Conflicted", "Locked2")
	c.raw_text = "app version 1"
	VaultStore.save_note(c)
	var c_file: String = c.resource_path
	var outside: String = FileAccess.get_file_as_string(c_file).replace("app version 1", "outside version")
	var f := FileAccess.open(c_file, FileAccess.WRITE)
	f.store_string(outside)
	f.close()
	chmod("555", c_file.get_base_dir())
	c.raw_text = "app version 2"
	var err: Error = VaultStore.save_note(c)
	chmod("755", c_file.get_base_dir())
	check(err != OK and VaultStore.last_conflict_copy == null, "save_note returns an error when the conflict copy can't be written")
	check(FileAccess.get_file_as_string(c_file).contains("outside version") and c.raw_text == "app version 2", "…the outside edit stays on disk and the app's text stays in memory")
	check(VaultStore.save_note(c) == OK and VaultStore.last_conflict_copy != null and VaultStore.last_conflict_copy.raw_text == "app version 2", "…and the retry writes the conflict copy")


## The save fails, then the user opens another note, makes a new one, tries
## another vault, and only later does the folder become writable. The failed
## note's words follow it: retried on the timer and on close, never replaced
## by a "Saved" for another note, and on disk once the folder is writable.
## (Before, the retry timer saved whichever note was open by then, the status
## said "Saved", and the first note's words were lost on quit.)
func test_leave_unsaved_note(V: String) -> void:
	VaultStore.create_folder("Away")
	var a: ContentLayer = VaultStore.create_note("Away Note", "Away")
	a.raw_text = "Away, on disk."
	VaultStore.save_note(a)
	var b: ContentLayer = VaultStore.create_note("Elsewhere")
	b.raw_text = "Elsewhere, on disk."
	VaultStore.save_note(b)
	var a_file: String = a.resource_path
	var a_dir: String = a_file.get_base_dir()
	var b_sha: String = FileAccess.get_sha256(b.resource_path)
	var b_modified: String = b.modified
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""

	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.open_note_by_title("Away Note")
	app._switch_layer("raw")
	await frames(2)
	chmod("555", a_dir)
	type_words(app, "\nWords typed before leaving the note.")
	app._flush_pending_save()
	check(app.status_label.text.begins_with("Couldn't save “Away Note”: "), "leave: the save fails first (%s)" % app.status_label.text)

	# A sidebar click (or a [[link]]) opens another note
	app.open_note_by_title("Elsewhere")
	await frames(2)
	var status: String = app.status_label.text
	check(app.current_note == b, "leave: the other note opens")
	check(status.begins_with("Opened Elsewhere. Couldn't save “Away Note”: "), "leave: the status still says the first note isn't saved (%s)" % status)
	check(app._unsaved.has(a) and not app._unsaved.has(b), "leave: the failed note is kept as unsaved, the open one isn't")
	check(app._auto_save_timer.is_stopped() and not app._retry_timer.is_stopped(), "leave: no autosave of the other note is pending; the retry is")

	# The retry fires while the folder is still read-only (a second later, so
	# a wrong re-save of the open note would change its `modified`)
	OS.delay_msec(1100)
	app._retry_timer.timeout.emit()
	check(app.status_label.text.begins_with("Couldn't save “Away Note”: "), "retry: still says Couldn't save, not Saved (%s)" % app.status_label.text)
	check(FileAccess.get_sha256(b.resource_path) == b_sha and b.modified == b_modified, "retry: the open note is not re-saved (no edit, modified unchanged)")
	check(app._unsaved.has(a) and not app._retry_timer.is_stopped(), "retry: the failed note is retried again later")

	# Editing and saving the open note: "Saved", but the warning stays
	type_words(app, "\nAn edit to the open note.")
	app._flush_pending_save()
	check(app.status_label.text.begins_with("Saved. Couldn't save “Away Note”: "), "saving another note still names the unsaved one (%s)" % app.status_label.text)
	check(FileAccess.get_file_as_string(b.resource_path).contains("An edit to the open note."), "…and the open note's edit is on disk")

	# Another vault: held, so the retry can't write into the wrong vault
	var V2: String = ProjectSettings.globalize_path("user://test-vault-save-failure-2/")
	DirAccess.make_dir_recursive_absolute(V2)
	app.switch_vault(V2)
	check(VaultStore.vault_path == V and app._unsaved.has(a), "a vault switch waits while a note can't be saved")
	check(app.status_label.text.begins_with("Didn't switch vaults. Couldn't save “Away Note”: ") and app.status_label.text.ends_with("Switch again to leave it unsaved."), "…and says why (%s)" % app.status_label.text)
	TestVault.remove_tree(V2)

	# The folder becomes writable again (a sync lock released); the app closes
	chmod("755", a_dir)
	get_root().propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check(FileAccess.get_file_as_string(a_file).contains("Words typed before leaving the note."), "close: the failed note's words are on disk, though another note was open")
	check(app._unsaved.is_empty() and app._retry_timer.is_stopped(), "close: nothing is left unsaved")
	check(app.status_label.text == "Saved “Away Note”", "close: the status names the note that saved (%s)" % app.status_label.text)

	# Reopening the note shows the saved words
	app.open_note_by_title("Away Note")
	check(app.raw_text_layer.text.contains("Words typed before leaving the note.") and app.status_label.text == "Opened Away Note", "reopened: the words are there and nothing is pending")
	app.queue_free()
	await frames(2)
	if registry_backup != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()


## Rewrite `file` in place the way a sync tool does, swapping `from` for `to`.
func rewrite_outside(file: String, from: String, to: String) -> void:
	var text: String = FileAccess.get_file_as_string(file).replace(from, to)
	var f := FileAccess.open(file, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## The editor's note (VaultStore.editor_note) isn't reloaded under the editor
## by a rescan when its file changes on disk. The change stays pending, also
## across several rescans, until the watcher's refresh_note_list(true); a
## save before that keeps the outside edit and writes ours as a conflict copy.
func test_editor_note_held() -> void:
	var n: ContentLayer = VaultStore.create_note("Held Open")
	n.raw_text = "Held, version 1."
	VaultStore.save_note(n)
	var file: String = n.resource_path
	VaultStore.editor_note = n
	OS.delay_msec(1100)   # mtimes have one-second resolution
	rewrite_outside(file, "Held, version 1.", "Held, version 2 from Claude.")
	check(VaultStore.create_note("Held Elsewhere") != null, "held: another note saves (and rescans the vault)")
	VaultStore.refresh_note_list()
	check(n.raw_text == "Held, version 1.", "held: a rescan leaves the editor's note alone")
	VaultStore.refresh_note_list(true)
	check(n.raw_text == "Held, version 2 from Claude.", "held: …the watcher's rescan loads the outside edit, though other rescans came first")
	OS.delay_msec(1100)
	rewrite_outside(file, "Held, version 2 from Claude.", "Held, version 3 from Claude.")
	VaultStore.refresh_note_list()
	n.raw_text = "Held, the editor's text."
	check(VaultStore.save_note(n) == OK and VaultStore.last_conflict_copy != null, "held: a save before the watcher runs makes a conflict copy")
	check(FileAccess.get_file_as_string(file).contains("Held, version 3 from Claude.") and VaultStore.last_conflict_copy.raw_text == "Held, the editor's text.", "…keeping the outside edit in the file and the editor's text in the copy")
	VaultStore.editor_note = null


## Claude (MCP update_note) changes the open note on disk while another
## note waits to be saved. The waiting note's retry saves, and its save
## rescans the vault. Claude's edit must survive: the user typing in the open
## note when the window loses focus ("focus-out") or when the retry timer
## fires ("retry timer"), or typing only after the retry ("idle"), gets a
## conflict copy, never "Saved" over Claude's text; and the watcher, which
## no longer waits for the other note, shows the edit first ("watcher").
## (Before, the rescan reloaded the open note under the editor and took the
## new file's hash, so the editor's older text overwrote Claude's edit.)
func test_outside_edit_while_another_is_unsaved(how: String) -> void:
	var folder: String = VaultStore.create_folder("Waiting " + how)
	var a: ContentLayer = VaultStore.create_note("Waiting " + how, folder)
	a.raw_text = "Waiting, on disk."
	VaultStore.save_note(a)
	var b: ContentLayer = VaultStore.create_note("Open " + how)
	b.raw_text = "Open note, before Claude."
	VaultStore.save_note(b)
	var a_dir: String = a.resource_path.get_base_dir()
	var b_file: String = b.resource_path
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.open_note_by_title("Waiting " + how)
	app._switch_layer("raw")
	await frames(2)
	chmod("555", a_dir)
	type_words(app, "\nWords waiting to be saved.")
	app._flush_pending_save()
	app.open_note_by_title("Open " + how)
	await frames(2)
	check(app._unsaved.has(a) and app.current_note == b, "%s: one note waits to be saved, another is open" % how)

	OS.delay_msec(1100)   # mtimes have one-second resolution
	var tools: RefCounted = VaultTools.new(VaultStore.vault_path)
	var rel: String = b_file.trim_prefix(VaultStore.vault_path)
	var h: String = tools.call_tool("read_note", {"path": rel}).structuredContent.hash
	var r: Dictionary = tools.call_tool("update_note", {"path": rel, "hash": h, "markdown": "Claude's edit."})
	check(not r.get("isError", false), "%s: Claude edits the open note on disk" % how)

	var typed: String = "\nThe user's words, %s." % how
	match how:
		"focus-out":
			type_words(app, typed)
			chmod("755", a_dir)
			get_root().propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
		"retry timer":
			type_words(app, typed)
			chmod("755", a_dir)
			app._retry_timer.timeout.emit()
			app._auto_save_timer.stop()
			app._auto_save_timer.timeout.emit()
		"idle":
			chmod("755", a_dir)
			app._retry_timer.timeout.emit()
			type_words(app, typed)
			app._flush_pending_save()
		"watcher":
			app.check_disk_changes()
			check(app.raw_text_layer.text.contains("Claude's edit.") and not app.raw_text_layer.text.contains("before Claude"), "watcher: the editor shows Claude's edit though another note waits to be saved (%s)" % app.raw_text_layer.text)
			check(app.status_label.text.contains("Couldn't save “Waiting watcher”"), "watcher: …and the status still names the waiting note (%s)" % app.status_label.text)
			type_words(app, typed)
			chmod("755", a_dir)
			get_root().propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)

	var on_disk: String = FileAccess.get_file_as_string(b_file)
	check(FileAccess.get_file_as_string(a.resource_path).contains("Words waiting to be saved."), "%s: the waiting note's words are on disk" % how)
	if how == "watcher":
		check(on_disk.contains("Claude's edit.") and on_disk.contains(typed.strip_edges()), "watcher: the user typed into Claude's version, and both are on disk")
	else:
		check(on_disk.contains("Claude's edit.") and not on_disk.contains(typed.strip_edges()), "%s: Claude's edit stays in the file, not overwritten (%s)" % [how, on_disk.get_slice("raw_text", 1).left(80)])
		var copy_has_words: bool = false
		for n in VaultStore.note_list:
			if n.title.begins_with("Open %s (conflict copy" % how) and FileAccess.get_file_as_string(n.resource_path).contains(typed.strip_edges()):
				copy_has_words = true
		check(copy_has_words, "%s: …and the user's words are in a conflict copy" % how)
		check(app.status_label.text.contains("conflict copy"), "%s: …and the status says so (%s)" % [how, app.status_label.text])
	app.queue_free()
	await frames(2)
	check(VaultStore.editor_note == null, "%s: a closed editor lets go of its note" % how)


## A note whose save failed is not reloaded over its unsaved words when its
## file changes on disk and something else rescans the vault (any other
## note's save does). The retry then keeps both: the outside edit in the
## file, the user's words as a conflict copy.
func test_unsaved_survives_rescan() -> void:
	VaultStore.create_folder("Synced")
	var n: ContentLayer = VaultStore.create_note("Synced Note", "Synced")
	n.raw_text = "Synced, version 1."
	VaultStore.save_note(n)
	var file: String = n.resource_path
	chmod("555", file.get_base_dir())
	n.raw_text = "Synced, the user's unsaved words."
	check(VaultStore.save_note(n) != OK, "rescan: the save fails (read-only folder)")
	OS.delay_msec(1100)   # mtimes have one-second resolution
	var outside: String = FileAccess.get_file_as_string(file).replace("Synced, version 1.", "Synced, version 2 from another device.")
	var f := FileAccess.open(file, FileAccess.WRITE)   # a sync tool rewrites the file in place
	f.store_string(outside)
	f.close()
	var other: ContentLayer = VaultStore.create_note("Unrelated Save")
	check(other != null, "rescan: another note saves (and rescans the vault)")
	VaultStore.refresh_note_list()
	check(n.raw_text == "Synced, the user's unsaved words.", "rescan: the unsaved note keeps its words in memory")
	chmod("755", file.get_base_dir())
	check(VaultStore.save_note(n) == OK and VaultStore.last_conflict_copy != null, "rescan: the retry saves, as a conflict copy")
	var copy: ContentLayer = VaultStore.last_conflict_copy
	check(copy != null and FileAccess.get_file_as_string(copy.resource_path).contains("Synced, the user's unsaved words."), "…the copy holds the user's words")
	check(FileAccess.get_file_as_string(file).contains("Synced, version 2 from another device."), "…and the outside edit stays in the file")


## A note the user made read-only (chmod 444) in a writable folder: the save
## is refused and says so. (Atomic saves rename over the file, which a
## read-only file doesn't prevent; before this was checked, the save quietly
## replaced the file with a writable one.)
func test_read_only_file() -> void:
	var n: ContentLayer = VaultStore.create_note("Read Only File")
	n.raw_text = "Locked by the user."
	VaultStore.save_note(n)
	var file: String = n.resource_path
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.open_note_by_title("Read Only File")
	app._switch_layer("raw")
	await frames(2)
	chmod("444", file)
	var before: String = FileAccess.get_sha256(file)
	type_words(app, "\nTyped into a read-only note.")
	app._flush_pending_save()
	check(app.status_label.text.begins_with("Couldn't save “Read Only File”: Can't write file"), "a read-only note in a writable folder says it can't be saved (%s)" % app.status_label.text)
	check(FileAccess.get_sha256(file) == before and FileAccess.get_unix_permissions(file) == 292, "…and stays as it was, mode 444")
	chmod("644", file)
	app._flush_pending_save()
	check(FileAccess.get_file_as_string(file).contains("Typed into a read-only note.") and app.status_label.text == "Saved “Read Only File”", "…and once writable, the retry saves it (%s)" % app.status_label.text)
	app.queue_free()
	await frames(2)
