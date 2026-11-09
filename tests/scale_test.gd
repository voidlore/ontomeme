extends SceneTree
## Autosave stays cheap in a big vault (1000 notes in 20 folders): saving a
## note that is already listed never rescans the vault
## (VaultStore.refresh_count), and the app's autosave updates that note's
## sidebar row alone (no _refresh_note_list, app.refresh_count) while the
## list stays in the order a rebuild gives. The disk watcher's next tick
## takes that save as the app's own (no rescan, no rebuild, the status still
## "Saved") but still picks up what another program wrote meanwhile, to
## another note or to the saved one. Timings are printed; only a
## generous budget is asserted, so a slow CI machine doesn't fail it.
##   headless:  godot --headless --path . -s res://tests/scale_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const NOTES: int = 1000
const FOLDERS: int = 20
const AUTOSAVE_BUDGET_MS: float = 100.0

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func ms_since(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0


## NOTES notes, NOTES / FOLDERS in each folder, written with ResourceSaver
## (save_note would rescan after each new note), a minute apart: "Note 0000"
## is the oldest, "Note 0999" the newest, and note i sits in folder i % FOLDERS.
func generate(V: String) -> void:
	for f in range(FOLDERS):
		DirAccess.make_dir_recursive_absolute(V + folder_name(f))
	for i in range(NOTES):
		var n := ContentLayer.new()
		n.title = "Note %04d" % i
		n.raw_text = "# Note %d\n\nSome words for note %d." % [i, i]
		n.created = "2026-01-01T%02d:%02d:00" % [i / 60, i % 60]
		n.modified = n.created
		ResourceSaver.save(n, V + folder_name(i % FOLDERS) + "/note_%04d.tres" % i)


func folder_name(f: int) -> String:
	return "Folder %02d" % f


func note_titled(title: String) -> ContentLayer:
	var i: int = VaultStore.get_note_index(title)
	return VaultStore.note_list[i] if i >= 0 else null


func is_sorted(list: Array[ContentLayer]) -> bool:
	for i in range(list.size() - 1):
		if VaultStore._sort_by_modified(list[i + 1], list[i]):
			return false
	return true


## The sidebar as it stands, top to bottom: folder rows by name, note rows by title.
func sidebar_order(app: Control) -> PackedStringArray:
	var note_of: Dictionary = {}
	for n in app._note_buttons:
		note_of[app._note_buttons[n]] = n
	var out: PackedStringArray = []
	for child in app.note_list_container.get_children():
		out.append(note_of[child].title if note_of.has(child) else str(child.name))
	return out


## The titles of the note rows of `folder`, top to bottom.
func folder_rows(app: Control, folder: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var note_of: Dictionary = {}
	for n in app._note_buttons:
		note_of[app._note_buttons[n]] = n
	for child in app.note_list_container.get_children():
		if note_of.has(child) and VaultStore.folder_of(note_of[child]) == folder:
			out.append(note_of[child].title)
	return out


func type_words(app: Control, words: String) -> void:
	app.raw_text_layer.text += words
	app.raw_text_layer.text_changed.emit()


## Wait until the clock is past the second of every file's mtime in `paths`,
## so a write from now on gives it a new one (mtimes are per second).
func past_mtimes(paths: Array) -> void:
	var newest: int = 0
	for p in paths:
		newest = maxi(newest, FileAccess.get_modified_time(p))
	while int(Time.get_unix_time_from_system()) <= newest:
		await create_timer(0.05).timeout


## Change a note's file the way another program would (not through VaultStore).
func edit_outside(path: String, old: String, new: String) -> void:
	var text: String = FileAccess.get_file_as_string(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text.replace(old, new))
	f.close()


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_scale.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_scale.json"   # never touch real progress
	ProgressStore.reset()
	var V: String = TestVault.open("scale", false)
	await frames(2)
	var t0: int = Time.get_ticks_usec()
	generate(V)
	print("      generated %d notes in %.0f ms" % [NOTES, ms_since(t0)])
	t0 = Time.get_ticks_usec()
	VaultStore.refresh_note_list()
	print("      VaultStore.refresh_note_list: %.1f ms" % ms_since(t0))
	check(VaultStore.note_list.size() == NOTES and VaultStore.folders.size() == FOLDERS, "the vault lists %d notes in %d folders (%d, %d)" % [NOTES, FOLDERS, VaultStore.note_list.size(), VaultStore.folders.size()])

	store_saves()
	await app_autosave(V)

	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	TestVault.remove_tree(V)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


# ── VaultStore.save_note on a listed note: no rescan ───────────────────────

func store_saves() -> void:
	var n: ContentLayer = note_titled("Note 0007")
	var rc: int = VaultStore.refresh_count
	n.raw_text += "\nAn edit."
	var t0: int = Time.get_ticks_usec()
	var err: Error = VaultStore.save_note(n)
	print("      VaultStore.save_note (listed note): %.1f ms" % ms_since(t0))
	check(err == OK and VaultStore.refresh_count == rc, "save_note on a note already listed doesn't rescan the vault (refresh_count %d -> %d)" % [rc, VaultStore.refresh_count])
	check(VaultStore.note_list.size() == NOTES and VaultStore.note_list[0] == n, "…it moves to the top of note_list, now the newest (%s)" % VaultStore.note_list[0].title)
	check(is_sorted(VaultStore.note_list) and VaultStore.folders.size() == FOLDERS, "…which stays sorted, folders and all")
	n.raw_text += " Again."
	check(VaultStore.save_note(n) == OK and VaultStore.last_conflict_copy == null and VaultStore.refresh_count == rc, "the next save finds the hash it took in place: no conflict copy, no rescan")
	check(FileAccess.get_file_as_string(n.resource_path).contains("An edit. Again."), "…and the file holds the edit")

	var fresh: ContentLayer = VaultStore.create_note("Fresh", folder_name(3))
	check(fresh != null and VaultStore.refresh_count > rc and VaultStore.note_list.has(fresh), "creating a note still rescans (refresh_count %d)" % VaultStore.refresh_count)
	rc = VaultStore.refresh_count
	check(VaultStore.delete_note(VaultStore.note_list.find(fresh)) and VaultStore.refresh_count > rc and not VaultStore.note_list.has(fresh), "…and so does deleting one")

	# Folder 08 deleted outside the app, its notes still listed. The save
	# finds its file gone, which it takes for a rename or delete outside
	# (links-names): the words become a conflict copy, at the top level since
	# the folder is gone too, and the vault is rescanned to list it.
	var gone: ContentLayer = note_titled("Note 0008")
	var dir: String = gone.resource_path.get_base_dir()
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
	rc = VaultStore.refresh_count
	gone.raw_text += "\nSaved after its folder was deleted outside the app."
	var saved: Error = VaultStore.save_note(gone)
	var copy: ContentLayer = VaultStore.last_conflict_copy
	check(saved == OK and VaultStore.refresh_count > rc and copy != null and VaultStore.note_list.has(copy) and VaultStore.folder_of(copy) == ""
		and not VaultStore.folders.has(folder_name(8)), "a save whose file and folder were deleted outside rescans, and lists its words as a conflict copy at the top level")

	# A file renamed outside keeps the vault's file count and its mtime: the
	# watcher's changed_outside still sees another file in that place
	var sig: String = VaultStore.disk_signature()
	var p: String = note_titled("Note 0009").resource_path
	var q: String = p.get_base_dir().path_join("note_0009b.tres")
	DirAccess.rename_absolute(p, q)
	check(VaultStore.changed_outside(sig, VaultStore.disk_signature()), "a note file renamed outside the app is news to the watcher")
	DirAccess.rename_absolute(q, p)
	check(not VaultStore.changed_outside(sig, VaultStore.disk_signature()), "…and nothing is once it's back")


# ── The app's autosave: one row changes, the list isn't rebuilt ────────────

func app_autosave(V: String) -> void:
	var t0: int = Time.get_ticks_usec()
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	print("      app start with %d notes: %.0f ms" % [VaultStore.note_list.size(), ms_since(t0)])
	await frames(3)
	t0 = Time.get_ticks_usec()
	app._refresh_note_list()
	print("      app._refresh_note_list (every row): %.1f ms" % ms_since(t0))

	var folder: String = folder_name(10)
	var m: ContentLayer = note_titled("Note 0010")   # the oldest note of Folder 10: its last row
	app._open_note(m)
	await frames(2)
	var rows: PackedStringArray = folder_rows(app, folder)
	check(rows.size() == NOTES / FOLDERS and rows[rows.size() - 1] == m.title, "(Note 0010 is the last row of %s)" % folder)
	var other: ContentLayer = note_titled("Note 0011")
	await past_mtimes([m.resource_path, other.resource_path])   # so the save below gives m's file a new mtime
	var btn: Button = app._note_buttons.get(m)
	var rc_app: int = app.refresh_count
	var rc: int = VaultStore.refresh_count
	type_words(app, "\nTyped in a big vault.")
	t0 = Time.get_ticks_usec()
	app._on_save_note_pressed()
	var dt: float = ms_since(t0)
	print("      autosave path (_on_save_note_pressed): %.1f ms" % dt)
	check(FileAccess.get_file_as_string(m.resource_path).contains("Typed in a big vault."), "Ctrl+S after an edit saves it")
	check(app.refresh_count == rc_app, "…without rebuilding the sidebar (_refresh_note_list ran %d times)" % (app.refresh_count - rc_app))
	check(VaultStore.refresh_count == rc, "…or rescanning the vault")
	check(app._note_buttons.get(m) == btn and is_instance_valid(btn), "…so the note keeps its row")
	check(folder_rows(app, folder)[0] == m.title, "…which moved to the top of %s, the newest there" % folder)
	var shown: PackedStringArray = sidebar_order(app)
	app._refresh_note_list()
	check(shown == sidebar_order(app), "…and the sidebar is in the order a full rebuild gives")
	check(dt < AUTOSAVE_BUDGET_MS, "the autosave path takes %.1f ms (budget %d ms)" % [dt, int(AUTOSAVE_BUDGET_MS)])

	# The watcher's next tick (every WATCH_INTERVAL) finds the new mtime that
	# save gave the file: the app's own write, already in note_list and its row
	rc_app = app.refresh_count
	check(VaultStore.disk_signature() != app._last_sig, "(the save gave the note's file a new mtime)")
	t0 = Time.get_ticks_usec()
	app.check_disk_changes()
	print("      watcher tick after the autosave: %.1f ms" % ms_since(t0))
	check(app.refresh_count == rc_app and VaultStore.refresh_count == rc, "the watcher's next tick takes the save as the app's own write: no rescan (%d), no rebuild (%d)" % [VaultStore.refresh_count - rc, app.refresh_count - rc_app])
	check(app.status_label.text == "Saved", "…and the status still says Saved (%s)" % app.status_label.text)

	# What another program writes is still news to it
	type_words(app, "\nTyped while another program wrote.")
	edit_outside(other.resource_path, "Some words for note 11.", "Edited outside the app.")
	app._on_save_note_pressed()
	app.check_disk_changes()
	check(VaultStore.refresh_count == rc + 1 and app.refresh_count == rc_app + 1 and other.raw_text.contains("Edited outside the app."), "an outside edit to another note, made while the user typed, is picked up by the tick after the save")
	check(app.status_label.text == "Vault changed on disk — refreshed", "…and the status says so (%s)" % app.status_label.text)
	await past_mtimes([m.resource_path])
	edit_outside(m.resource_path, "Typed while another program wrote.", "Rewritten by another program.")
	app.check_disk_changes()
	check(app.current_note == m and m.raw_text.contains("Rewritten by another program.") and app.raw_text_layer.text == m.raw_text, "…and so is one to the note the app just saved, a second later: the editor shows it")

	# The row's status icon follows the edit: a quiz (already passed) added
	ProgressStore.record_result(m.title, 0, 1, 1)
	rc_app = app.refresh_count
	btn = app._note_buttons.get(m)
	check(btn.icon == null, "(no ✓ before the note has a quiz)")
	type_words(app, "\n\n" + NoteScene3D.template("quiz"))
	app._do_auto_save()
	check(btn.icon == ProgressStore.icon("done") and app.refresh_count == rc_app, "an edit that adds a passed quiz shows ✓ on the row, still without a rebuild")
	ProgressStore.record_answer(m.title, 0, 0, "Q?", false, m.title)
	check(ProgressStore.note_status(m) == "review", "a missed question is seen at once (the cache drops it on record_answer)")
	ProgressStore.record_answer(m.title, 0, 0, "Q?", true, m.title)
	check(ProgressStore.note_status(m) == "done" and ProgressStore.status(m.title) == "done", "…and answering it right clears it")

	# What other rows or the TAGS section show still rebuilds the list
	app.title_edit.text = "Note 0010 renamed"
	app._commit_title()
	check(app.refresh_count > rc_app and app._note_buttons.get(m).text == "Note 0010 renamed", "a rename rebuilds the list")
	rc_app = app.refresh_count
	app._add_tag("bigvault")
	app._on_save_note_pressed()
	var tags_listed: bool = app.tag_sidebar_list.get_children().any(func(row): return row.get_child(0).text == "#bigvault")
	check(app.refresh_count > rc_app and tags_listed, "a tag change rebuilds it, so the TAGS section counts the new tag")
	rc_app = app.refresh_count
	app.search_box.text = "Note 001"
	app.search_box.text_changed.emit(app.search_box.text)
	rc_app = app.refresh_count
	type_words(app, "\nSearched.")
	app._on_save_note_pressed()
	check(app.refresh_count > rc_app, "while a search is shown, a save rebuilds it (the edit may change the matches)")
	app.search_box.text = ""
	app.search_box.text_changed.emit("")
	app.queue_free()
	await frames(2)
