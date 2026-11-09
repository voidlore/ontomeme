extends SceneTree
## Rename, merge or remove a tag across the vault from the TAGS section.
## A real right-click on a TAGS row opens its menu; "Rename or merge tag…"
## rewrites the tag on every note that carries it (a note that already has
## the new name keeps it once), "Remove from all notes…" takes it off them
## all. Each note goes through VaultStore.save_note, so a reload from disk
## shows the same tags and the next edit is no spurious conflict copy.
##   headless:  godot --headless --path . -s res://tests/tag_rename_test.gd

const TestVault = preload("res://tests/test_vault.gd")

## [title, folder, tags]: three notes tagged #bugg (one in a subfolder), one
## carrying both #bugg and #bug, and one that neither touches (the only
## #misc note).
const SEEDS: Array = [
	["Bug One", "", ["bugg"]],
	["Bug Two", "Sub", ["bugg", "ui"]],
	["Bug Three", "", ["bugg"]],
	["Bug Four", "", ["bugg", "bug"]],
	["Other", "", ["ui", "misc"]],
]
const BUGGED: Array = ["Bug One", "Bug Two", "Bug Three", "Bug Four"]

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func boot() -> Control:
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	return app


func note(title: String) -> ContentLayer:
	var idx: int = VaultStore.get_note_index(title)
	return VaultStore.note_list[idx] if idx >= 0 else null


## The TAGS row for `tag`: [its Button, its count Label], or [] if none.
func tag_row(app: Control, tag: String) -> Array:
	for row in app.tag_sidebar_list.get_children():
		if row.is_queued_for_deletion():
			continue
		var btn = row.get_child(0)
		if btn is Button and (btn as Button).text == "#" + tag:
			return [btn, row.get_child(1)]
	return []


func row_count(app: Control, tag: String) -> int:
	var row: Array = tag_row(app, tag)
	return int((row[1] as Label).text.strip_edges()) if not row.is_empty() else -1


## A real right-click on a TAGS row (motion, then the right button pressed
## through the root viewport), as a user makes it.
func right_click_row(app: Control, tag: String) -> void:
	var btn: Button = tag_row(app, tag)[0]
	var scroll: ScrollContainer = app.tag_sidebar_list.get_parent()
	scroll.ensure_control_visible(btn)
	await frames(2)
	var pos: Vector2 = btn.get_global_rect().get_center()
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_RIGHT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	await frames(2)


## The items the context menu shows, as [id, text] pairs.
func menu_items(app: Control) -> Array:
	var out: Array = []
	var menu: PopupMenu = app._ctx_menu
	for i in range(menu.item_count):
		if not menu.is_item_separator(i):
			out.append([menu.get_item_id(i), menu.get_item_text(i)])
	return out


## Press a dialog's OK button: it hides, then emits `confirmed`.
func press_ok(dlg: AcceptDialog) -> void:
	dlg.get_ok_button().pressed.emit()
	await frames(3)


## The tags in a note's .tres, read from disk past the resource cache.
func disk_tags(title: String) -> Array:
	var n: ContentLayer = note(title)
	if n == null:
		return ["<missing>"]
	var fresh: Resource = ResourceLoader.load(n.resource_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	return Array((fresh as ContentLayer).tags) if fresh is ContentLayer else ["<unreadable>"]


func conflict_copies() -> Array:
	return VaultStore.note_list.filter(func(n: ContentLayer) -> bool: return n.title.contains("conflict copy"))


func seed_notes() -> Dictionary:
	var modified: Dictionary = {}
	for s in SEEDS:
		var n: ContentLayer = VaultStore.create_note(s[0], s[1])
		n.tags.assign(s[2])
		n.raw_text = "Body of %s.\n" % s[0]
		VaultStore.save_note(n)
		modified[s[0]] = n.modified
	return modified


## Write a new body for `title` the way another editor would (straight to its
## .tres, the app not told), a second after the app last wrote it so the
## mtime moves.
## Wait until the wall clock's second changes: a file written after this
## gets a later mtime than one written before it.
func next_second() -> void:
	var s: int = int(Time.get_unix_time_from_system())
	while int(Time.get_unix_time_from_system()) == s:
		await process_frame


func outside_edit(title: String, body: String) -> void:
	await create_timer(1.1).timeout
	var n: ContentLayer = note(title)
	var other: ContentLayer = n.duplicate()
	other.raw_text = body
	ResourceSaver.save(other, n.resource_path)


func check_rename(app: Control, modified: Dictionary) -> void:
	# An outside edit the watcher has not polled yet (it is paused), and
	# typing still waiting for its autosave in an open #bugg note: the rename
	# must save the one and read in the other, with no conflict copy.
	app._watch_timer.paused = true
	await outside_edit("Bug Three", "Edited outside the app.\n")
	app.open_note_by_title("Bug One")
	await frames(3)
	app.raw_text_layer.text = "Typed before the rename.\n"
	app._on_raw_text_changed()

	app._set_tag_filter("bugg")
	await frames(2)
	check(app._active_tag_filter == "bugg" and app._visible_notes.size() == 4,
		"the #bugg row filters the list to its 4 notes (%d)" % app._visible_notes.size())
	check(row_count(app, "bugg") == 4 and row_count(app, "bug") == 1, "the sidebar counts #bugg 4 and #bug 1")

	await right_click_row(app, "bugg")
	check(app._ctx_menu.visible, "a real right-click on the #bugg row opens the menu")
	check(menu_items(app) == [[30, "Rename or merge tag…"], [31, "Remove from all notes…"]],
		"the menu offers rename-or-merge and remove (%s)" % [menu_items(app)])
	check(app._ctx_target == {"type": "tag", "tag": "bugg"}, "the menu acts on #bugg (%s)" % app._ctx_target)
	app._ctx_menu.id_pressed.emit(30)
	app._ctx_menu.hide()
	await frames(2)
	check(app._prompt.visible and app._prompt_edit.text == "bugg",
		"'Rename or merge tag…' asks for the new name, prefilled with 'bugg' (%s)" % app._prompt_edit.text)
	app._prompt_edit.text = "Bug"
	check(not app._auto_save_timer.is_stopped() and note("Bug Three").raw_text == "Body of Bug Three.\n",
		"as OK is pressed, Bug One's typing is unsaved and the app has not seen Bug Three's outside edit")
	await press_ok(app._prompt)
	app._watch_timer.paused = false

	for title in BUGGED:
		var tags: Array = Array(note(title).tags)
		check(tags.count("bug") == 1 and not "bugg" in tags, "%s carries #bug once and no #bugg (%s)" % [title, tags])
		check(disk_tags(title) == tags, "%s's .tres reloads with the same tags (%s)" % [title, disk_tags(title)])
	check(Array(note("Bug Two").tags) == ["bug", "ui"], "the renamed tag keeps its place (%s)" % [note("Bug Two").tags])
	check(Array(note("Other").tags) == ["ui", "misc"] and note("Other").modified == modified["Other"], "a note without the tag is not rewritten")
	for title in ["Bug Two", "Bug Four"]:
		check(note(title).modified == modified[title], "%s keeps its modified time (%s)" % [title, note(title).modified])
	check(VaultStore.last_conflict_copy == null and conflict_copies().is_empty(),
		"no conflict copy (%s)" % [conflict_copies().map(func(n: ContentLayer) -> String: return n.title)])
	check(note("Bug One").raw_text == "Typed before the rename.\n", "the pending typing was saved first")
	check(note("Bug Three").raw_text == "Edited outside the app.\n", "the outside edit was read in, not overwritten")

	check(tag_row(app, "bugg").is_empty() and row_count(app, "bug") == 4,
		"the sidebar shows #bug with 4 notes and no #bugg (%d)" % row_count(app, "bug"))
	check(app._active_tag_filter == "bug" and app._visible_notes.size() == 4,
		"the #bugg filter follows to #bug (%s, %d notes)" % [app._active_tag_filter, app._visible_notes.size()])
	check((tag_row(app, "bug")[0] as Button).button_pressed, "and the #bug row shows pressed")
	check(app.current_note == note("Bug One") and app.tag_chips.get_child_count() == 1
		and app.tag_chips.get_child(0).find_child("Body", true, false).text == "#bug",
		"the open note's chip reads #bug")
	check(app.note_meta.text.contains("#bug") and not app.note_meta.text.contains("#bugg"), "and so does its meta line (%s)" % app.note_meta.text)
	check(app.status_label.text == "Renamed #bugg → #bug in 4 notes", "the status line says so (%s)" % app.status_label.text)

	# The next edit of a renamed note saves cleanly: the stored hash is the file's
	app.raw_text_layer.text = "Typed after the rename.\n"
	app._on_raw_text_changed()
	app._flush_pending_save()
	await frames(2)
	check(app.current_note == note("Bug One") and VaultStore.last_conflict_copy == null and conflict_copies().is_empty(),
		"the next edit of a renamed note is no conflict copy")


func check_blank_name(app: Control) -> void:
	await right_click_row(app, "ui")
	app._ctx_menu.id_pressed.emit(30)
	app._ctx_menu.hide()
	await frames(2)
	app._prompt_edit.text = " ## "
	await press_ok(app._prompt)
	check(Array(note("Other").tags) == ["ui", "misc"] and row_count(app, "ui") == 2,
		"a blank new name removes nothing (%s)" % [note("Other").tags])
	check(app.status_label.text.begins_with("A tag needs a name"), "and says why (%s)" % app.status_label.text)


func check_remove(app: Control) -> void:
	var before: int = VaultStore.note_list.size()
	await right_click_row(app, "bug")
	app._ctx_menu.id_pressed.emit(31)
	app._ctx_menu.hide()
	await frames(2)
	var dlg: ConfirmationDialog = app.find_child("RemoveTagDialog", false, false)
	check(dlg != null and dlg.visible, "'Remove from all notes…' asks first")
	if dlg == null:
		return
	check(dlg.dialog_text.contains("#bug") and dlg.dialog_text.contains("4 notes"),
		"the question names the tag and its 4 notes (%s)" % dlg.dialog_text)
	await press_ok(dlg)

	var carriers: Array = VaultStore.note_list.filter(func(n: ContentLayer) -> bool: return TagOps.has(n, "bug"))
	check(carriers.is_empty(), "no note carries #bug any more (%d)" % carriers.size())
	for title in BUGGED:
		check(not "bug" in disk_tags(title), "%s's .tres has no #bug (%s)" % [title, disk_tags(title)])
	check(Array(note("Bug Two").tags) == ["ui"], "other tags stay (%s)" % [note("Bug Two").tags])
	check(VaultStore.note_list.size() == before, "every note stays (%d)" % VaultStore.note_list.size())
	check(tag_row(app, "bug").is_empty() and row_count(app, "ui") == 2, "the #bug row is gone, #ui stays")
	check(app._active_tag_filter == "" and app._visible_notes.size() == before,
		"the #bug filter cleared and the full list shows (%d)" % app._visible_notes.size())
	check(app.tag_chips.get_child_count() == 0 or app.tag_chips.get_children().all(func(c: Node) -> bool: return c.is_queued_for_deletion()),
		"the open note's #bug chip is gone")
	check(app.status_label.text == "Removed #bug from 4 notes", "the status line says so (%s)" % app.status_label.text)
	check(VaultStore.last_conflict_copy == null and conflict_copies().is_empty(), "still no conflict copy")


## With no typing pending, no other save rescans the vault before the
## rename writes Other, the only #misc note: its outside edit must be read
## in, not saved over or split off into a conflict copy.
func check_outside_edit_then_rename(app: Control) -> void:
	app._flush_pending_save()
	app._watch_timer.paused = true
	await outside_edit("Other", "Other, edited outside.\n")
	check(note("Other").raw_text == "Body of Other.\n", "the app has not seen Other's outside edit yet")
	var n: int = app._rename_tag_everywhere("#Misc", "Odds and Ends")
	app._watch_timer.paused = false
	await frames(2)
	check(n == 1, "#misc -> #odds-and-ends rewrites its one note (%d)" % n)
	check(note("Other").raw_text == "Other, edited outside.\n" and disk_tags("Other") == ["ui", "odds-and-ends"],
		"Other keeps the outside edit and gets #odds-and-ends (%s)" % [disk_tags("Other")])
	check(VaultStore.last_conflict_copy == null and conflict_copies().is_empty(),
		"no conflict copy (%s)" % [conflict_copies().map(func(c: ContentLayer) -> String: return c.title)])
	check(app.status_label.text == "Renamed #misc → #odds-and-ends in 1 note", "the status line says so (%s)" % app.status_label.text)


## The body in a note's .tres, read from disk into a fresh object
## (CACHE_MODE_REPLACE would refresh the app's own note in place).
func disk_raw(title: String) -> String:
	var n: ContentLayer = note(title)
	if n == null:
		return "<missing>"
	var fresh: Resource = ResourceLoader.load(n.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	return (fresh as ContentLayer).raw_text if fresh is ContentLayer else "<unreadable>"


## The open note changed on disk in the same second as the app's last write
## (an MCP agent or a sync tool; FAT/exFAT keep 2 s mtimes), so the vault's
## signature did not move and the watcher saw nothing. The rename then saves
## the app's version of that note as a conflict copy, and save_note reloads
## the note itself to the outside version. The editor must move to the copy,
## as an autosave's conflict does: left on the original, it showed text the
## note no longer had, and the next keystroke saved it over the outside edit.
func check_open_note_changed_same_second(app: Control) -> void:
	app.open_note_by_title("Other")
	await frames(3)
	app._flush_pending_save()
	app._watch_timer.paused = true
	var ours: String = app.raw_text_layer.text
	var theirs: String = "Other, changed outside in the same second.\n"
	var other: ContentLayer = note("Other")
	var outside: ContentLayer = other.duplicate()
	outside.raw_text = theirs
	# The real clock may or may not cross a second between the app's last
	# write of Other and this one; cross it always, then make the vault's
	# signature and VaultStore's remembered mtime what a same-second write
	# leaves. With the mtime left stale, the rename's first save rescanned
	# the vault, read Other's outside edit in, and saved over it (1 run in 9).
	await next_second()
	ResourceSaver.save(outside, other.resource_path)
	VaultStore._mtimes[other.resource_path] = FileAccess.get_modified_time(other.resource_path)
	app._last_sig = VaultStore.disk_signature()   # no change for the watcher to see
	var n: int = app._rename_tag_everywhere("UI", "interface")
	await frames(2)
	check(n == 2, "#ui -> #interface rewrites Bug Two and Other (%d)" % n)
	check(note("Other").raw_text == theirs and disk_raw("Other") == theirs and disk_tags("Other") == ["ui", "odds-and-ends"],
		"Other keeps the outside edit, untouched (%s)" % [disk_tags("Other")])
	var copy: ContentLayer = note("Other (conflict copy)")
	check(copy != null and copy.raw_text == ours and Array(copy.tags) == ["interface", "odds-and-ends"],
		"the app's version, with #interface, is saved as \"Other (conflict copy)\"")
	check(Array(note("Bug Two").tags) == ["interface"] and disk_tags("Bug Two") == ["interface"], "Bug Two gets #interface")
	check(copy != null and app.current_note == copy, "the editor moves to the conflict copy (%s)" % app.current_note.title)
	check(app.raw_text_layer.text == app.current_note.raw_text, "and shows the open note's own text")
	check(app.tag_chips.get_child_count() == 2 and app.tag_chips.get_child(0).find_child("Body", true, false).text == "#interface",
		"its chips read #interface")
	check(app.status_label.text == "Renamed #ui → #interface in 2 notes (1 note changed on disk meanwhile: kept, with ours as a conflict copy; “Other (conflict copy)” is open now)",
		"the status line says which note is open now (%s)" % app.status_label.text)
	check(VaultStore.last_conflict_copy == null, "no conflict copy is left pending")

	# The next keystroke saves the copy, never the original over its outside edit.
	app.raw_text_layer.text = app.raw_text_layer.text + "One more line.\n"
	app._on_raw_text_changed()
	app._flush_pending_save()
	app._watch_timer.paused = false
	await frames(2)
	check(disk_raw("Other") == theirs, "a keystroke after the rename leaves Other's outside edit on disk (%s)" % disk_raw("Other").strip_edges())
	check(disk_raw("Other (conflict copy)") == ours + "One more line.\n", "the keystroke went to the copy")
	check(conflict_copies().size() == 1, "and made no second conflict copy (%d)" % conflict_copies().size())

	# The same from the Learning Journey view (the TAGS section stays in the
	# sidebar there): the editor behind it moves to the new copy, and the
	# view stays the Journey.
	app._switch_layer("journey")
	await frames(2)
	app._watch_timer.paused = true
	var open: ContentLayer = app.current_note
	var again: ContentLayer = open.duplicate()
	again.raw_text = "The copy, changed outside in the same second.\n"
	ResourceSaver.save(again, open.resource_path)
	app._last_sig = VaultStore.disk_signature()
	app._rename_tag_everywhere("interface", "iface")
	app._watch_timer.paused = false
	await frames(2)
	check(app.current_mode == "journey" and app.journey_panel.visible, "the Journey view stays open (%s)" % app.current_mode)
	check(app.current_note != open and app.current_note.title.contains("conflict copy") and TagOps.has(app.current_note, "iface")
		and app.raw_text_layer.text == app.current_note.raw_text,
		"and the note behind it is the new copy, its text in the editor (%s)" % app.current_note.title)
	check(open.raw_text == again.raw_text and disk_raw(open.title) == again.raw_text, "the outside edit of the open copy is kept")

	# And from the Graph view. Its _switch_layer sets data a frame later
	# (after an await), and it used to put its hint up then too, over the
	# rename's status, so the user never heard which note went to a copy.
	app._switch_layer("graph")
	await frames(2)
	app._watch_timer.paused = true
	open = app.current_note
	var third: ContentLayer = open.duplicate()
	third.raw_text = "Changed outside again, behind the graph.\n"
	ResourceSaver.save(third, open.resource_path)
	app._last_sig = VaultStore.disk_signature()
	var renamed: int = app._rename_tag_everywhere("iface", "face")
	app._watch_timer.paused = false
	await frames(3)
	var graph_copy: ContentLayer = app.current_note
	check(app.current_mode == "graph" and app.graph_layer.visible, "the Graph view stays open (%s)" % app.current_mode)
	check(graph_copy != open and graph_copy.title.contains("conflict copy") and TagOps.has(graph_copy, "face")
		and app.raw_text_layer.text == graph_copy.raw_text,
		"and the note behind it is the new copy, its text in the editor (%s)" % graph_copy.title)
	check(renamed == 2 and app.status_label.text == "Renamed #iface → #face in 2 notes (1 note changed on disk meanwhile: kept, with ours as a conflict copy; “%s” is open now)" % graph_copy.title,
		"three frames on, the status line still says which note is open now, not the graph's hint (%s)" % app.status_label.text)
	check(open.raw_text == third.raw_text and disk_raw(open.title) == third.raw_text, "the outside edit behind the graph is kept")


## True when the OS refuses a new file in `dir` (root ignores permissions).
func write_protected(dir: String) -> bool:
	var probe: String = dir.path_join("probe.tmp")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return true
	f.close()
	DirAccess.remove_absolute(probe)
	return false


## The tags in the .tres at `path`, read into a fresh object (disk_tags'
## CACHE_MODE_REPLACE would put the disk's tags back into the app's note).
func fresh_tags(path: String) -> Array:
	var fresh: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	return Array((fresh as ContentLayer).tags) if fresh is ContentLayer else ["<unreadable>"]


## A rename that can't save one of its notes (its folder is read-only, as
## save_failure_test makes one): that note keeps the new tag in memory and
## joins the unsaved notes with a retry pending, as a failed autosave does,
## and the status line names it; the other note is written at once. Once
## the folder is writable again, a flush writes it.
func check_rename_unsaved(app: Control) -> void:
	app._flush_pending_save()
	app._switch_layer("raw")
	await frames(2)
	for s in [["Locked Tagged", "LockedTags"], ["Free Tagged", ""]]:
		var made: ContentLayer = VaultStore.create_note(s[0], s[1])
		made.tags.assign(["held"])
		made.raw_text = "Body of %s.\n" % s[0]
		VaultStore.save_note(made)
	app._after_vault_op("seeded")
	var locked: ContentLayer = note("Locked Tagged")
	var writable: ContentLayer = note("Free Tagged")
	var dir: String = locked.resource_path.get_base_dir()
	OS.execute("chmod", ["555", dir])
	if not write_protected(dir):
		OS.execute("chmod", ["755", dir])
		print("SKIP  rename into a read-only folder: this user can write to it (root?)")
		return
	var before: String = FileAccess.get_sha256(locked.resource_path)
	var n: int = app._rename_tag_everywhere("held", "kept")
	var status: String = app.status_label.text
	var retrying: bool = app._unsaved.has(locked) and not app._retry_timer.is_stopped()
	var untouched: bool = FileAccess.get_sha256(locked.resource_path) == before
	OS.execute("chmod", ["755", dir])   # first, so a failed check never leaves the folder read-only
	check(n == 2, "#held -> #kept changes both notes (%d)" % n)
	check(status.begins_with("Renamed #held → #kept in 2 notes. Couldn't save “Locked Tagged”: ") and status.ends_with("Its text is kept and retried."),
		"the status line says which note couldn't be saved (%s)" % status)
	check(untouched and fresh_tags(locked.resource_path) == ["held"], "the read-only note's file is unchanged")
	check(Array(locked.tags) == ["kept"], "…while the note holds #kept in memory (%s)" % [locked.tags])
	check(retrying, "…and joins the unsaved notes, with a retry pending")
	check(fresh_tags(writable.resource_path) == ["kept"], "the writable note is saved with #kept")

	app._flush_pending_save()
	check(fresh_tags(locked.resource_path) == ["kept"], "once the folder is writable, a flush writes the rename (%s)" % [fresh_tags(locked.resource_path)])
	check(app._unsaved.is_empty() and app._retry_timer.is_stopped(), "…and nothing is left to retry")
	check(VaultStore.last_conflict_copy == null and not VaultStore.note_list.any(func(c: ContentLayer) -> bool: return c.title.begins_with("Locked Tagged (conflict copy")),
		"…with no conflict copy")


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_tag_rename.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_tag_rename.json"
	ProgressStore.reset()
	var vault: String = TestVault.open("tag-rename", false)
	var modified: Dictionary = seed_notes()
	var app: Control = await boot()
	await check_rename(app, modified)
	await check_blank_name(app)
	await check_remove(app)
	await check_outside_edit_then_rename(app)
	await check_open_note_changed_same_second(app)
	if OS.get_name() in ["Linux", "macOS", "FreeBSD"]:
		await check_rename_unsaved(app)
	else:
		print("SKIP  rename into a read-only folder (chmod) on " + OS.get_name())
	app.queue_free()
	await frames(2)
	TestVault.remove_tree(vault)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
