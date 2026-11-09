extends SceneTree
## Renaming a note renames its file (VaultStore.rename_note), keeps the
## conflict guard working on the renamed file, and refuses a title another
## note already has.
##   headless:  godot --headless --path . -s res://tests/rename_test.gd

const TestVault = preload("res://tests/test_vault.gd")

var fails: int = 0
var app: Control
var V: String


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## Note files (names) directly in the vault folder `rel`.
func files_in(rel: String) -> PackedStringArray:
	return DirAccess.get_files_at(V + rel)


func notes_titled(title: String) -> Array:
	return VaultStore.note_list.filter(func(n: ContentLayer) -> bool: return n.title == title)


## Push a key press and release through the viewport (to a focused dialog
## when one is open, as a real key would).
func key(keycode: Key, unicode: int = 0) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = keycode
		e.unicode = unicode
		e.pressed = pressed
		get_root().push_input(e)
	await frames(2)


func type_text(text: String) -> void:
	for ch in text:
		await key(OS.find_keycode_from_string(ch.to_upper()), ch.unicode_at(0))


## A real mouse press and release at the centre of `c`.
func click(c: Control, button: MouseButton = MOUSE_BUTTON_LEFT, double: bool = false) -> void:
	await click_at(c.get_global_rect().get_center(), button, double)


## A real mouse press and release at `pos` (whatever row is there now).
func click_at(pos: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT, double: bool = false) -> void:
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = button
		e.pressed = pressed
		e.double_click = double and pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	await frames(2)


func row(note: ContentLayer) -> Button:
	return app._note_buttons.get(note)


## The note whose sidebar row is at `pos` now (null: none).
func note_at(pos: Vector2) -> ContentLayer:
	for note in app._note_buttons:
		if app._note_buttons[note].get_global_rect().has_point(pos):
			return note
	return null


func prompt_open() -> bool:
	return app._prompt.visible


## Rename the open note the way a user does: type in the title field, commit.
func retitle(title: String) -> void:
	app.title_edit.text = title
	app._commit_title()
	await frames(2)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_rename.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_rename.json"   # never touch real progress
	ProgressStore.reset()
	V = TestVault.open("rename", false)
	VaultStore.create_folder("Bio")
	var anchor: ContentLayer = VaultStore.create_note("Cells", "Bio")
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)

	await rename_renames_the_file(anchor)
	await outside_edit_after_rename_is_a_conflict()
	await duplicate_title_is_refused()
	await rename_over_an_outside_edit()
	await taken_file_name_gets_a_suffix()
	store_api()
	await sidebar_rename()
	await double_click_on_moved_rows()

	app.queue_free()
	await frames(2)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	TestVault.remove_tree(V)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


# ── gap-rename-note-file ────────────────────────────────────────────────────

## + New in Bio makes note_untitled.tres; titling it renames the file.
func rename_renames_the_file(anchor: ContentLayer) -> void:
	app._open_note(anchor)
	app._on_new_note_pressed()
	await frames(2)
	var old_path: String = app.current_note.resource_path
	check(old_path.get_file().begins_with("note_untitled") and VaultStore.folder_of(app.current_note) == "Bio",
		"+ New makes an untitled file in Bio (%s)" % old_path.substr(V.length()))
	await retitle("Photosynthesis")
	var path: String = app.current_note.resource_path
	check(path == V + "Bio/note_photosynthesis.tres" and FileAccess.file_exists(path),
		"titling it renames the file to Bio/note_photosynthesis.tres (%s)" % path.substr(V.length()))
	check(not FileAccess.file_exists(old_path) and not Array(files_in("Bio")).any(func(f: String) -> bool: return f.begins_with("note_untitled")),
		"…and no note_untitled*.tres is left (%s)" % ", ".join(files_in("Bio")))
	check(VaultStore.last_conflict_copy == null, "…with no conflict copy")
	check(VaultStore._hashes.has(path) and not VaultStore._hashes.has(old_path) and VaultStore._mtimes.has(path) and not VaultStore._mtimes.has(old_path),
		"the remembered hash and mtime moved to the new path")
	check(notes_titled("Photosynthesis").size() == 1 and notes_titled("Photosynthesis")[0] == app.current_note,
		"note_list has one note titled Photosynthesis, the open one")
	check(app._note_buttons.has(app.current_note) and app._note_buttons[app.current_note].text == "Photosynthesis",
		"the sidebar row reads Photosynthesis")
	check(app.status_label.text == "Renamed to Photosynthesis", "the status says so (%s)" % app.status_label.text)
	app.check_disk_changes()
	await frames(2)
	check(app.status_label.text == "Renamed to Photosynthesis", "the watcher doesn't take the app's own rename for an outside change")
	# A save after the rename writes the renamed file, not a new one
	app.raw_text_layer.text = "Light reactions make ATP."
	app._on_raw_text_changed()
	app._flush_pending_save()
	await frames(2)
	check(files_in("Bio").size() == 2 and FileAccess.get_file_as_string(path).contains("Light reactions"),
		"the next save writes note_photosynthesis.tres (%s)" % ", ".join(files_in("Bio")))


## The hash moved with the file: an outside edit to the renamed file is kept.
func outside_edit_after_rename_is_a_conflict() -> void:
	var note: ContentLayer = app.current_note
	var path: String = note.resource_path
	var text: String = FileAccess.get_file_as_string(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text.replace("Light reactions", "Edited in another editor:"))
	f.close()
	app.raw_text_layer.text = "Typed in the app."
	app._on_raw_text_changed()
	app._flush_pending_save()
	await frames(2)
	check(FileAccess.get_file_as_string(path).contains("Edited in another editor"), "an outside edit to the renamed file is not overwritten")
	check(app.current_note != null and app.current_note.title == "Photosynthesis (conflict copy)" and app.current_note.raw_text == "Typed in the app.",
		"…the app's version becomes a conflict copy (%s)" % (app.current_note.title if app.current_note else "none"))


## A second note can't take a title another note has, in any case.
func duplicate_title_is_refused() -> void:
	app._on_new_note_pressed()
	await frames(2)
	await retitle("Light reactions")
	var second: ContentLayer = app.current_note
	var path: String = second.resource_path
	check(path.get_file() == "note_light_reactions.tres", "a second note becomes note_light_reactions.tres (%s)" % path.get_file())
	await retitle("photosynthesis ")
	check(second.title == "Light reactions" and second.resource_path == path, "renaming it to 'photosynthesis' is refused (%s)" % second.title)
	check(app.status_label.text.contains("already exists") and app.status_label.text.contains("Photosynthesis"),
		"…the status says a note with that name already exists (%s)" % app.status_label.text)
	check(app.title_edit.text == "Light reactions", "…and the title field goes back to the note's title (%s)" % app.title_edit.text)
	check(notes_titled("Photosynthesis").size() == 1, "…so there is still one Photosynthesis")
	var other_untitled: ContentLayer = VaultStore.create_note("untitled", "Bio")
	await retitle("Untitled")
	var untitled: Array = VaultStore.note_list.filter(func(n: ContentLayer) -> bool: return n.title.to_lower() == "untitled")
	check(second.title == "Untitled" and untitled.size() == 2, "'untitled' may repeat (%d untitled notes)" % untitled.size())
	VaultStore.delete_note(VaultStore.note_list.find(other_untitled))
	await retitle("Light Reactions")
	check(second.title == "Light Reactions" and second.resource_path.get_file() == "note_light_reactions.tres",
		"a note can be renamed back (%s)" % second.resource_path.get_file())


## A rename saves in place first: a file changed outside keeps its name and
## the outside version; the app's version (new title) is a conflict copy.
func rename_over_an_outside_edit() -> void:
	var note: ContentLayer = app.current_note
	var path: String = note.resource_path
	var text: String = FileAccess.get_file_as_string(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text.replace("Light Reactions", "Light-dependent reactions"))
	f.close()
	await retitle("Calvin cycle")
	check(FileAccess.file_exists(path) and note.title == "Light-dependent reactions" and note.resource_path == path,
		"renaming a note changed on disk keeps its file and the outside title (%s, %s)" % [note.title, note.resource_path.get_file()])
	check(app.current_note != null and app.current_note.title == "Calvin cycle (conflict copy)",
		"…and opens the app's version as a conflict copy (%s)" % (app.current_note.title if app.current_note else "none"))
	check(not FileAccess.file_exists(V + "Bio/note_calvin_cycle.tres"), "…without renaming anything to the new title")


## A file named for the title but held by an unrelated note (an older note
## whose title changed before renames moved files) gets a _1 sibling.
func taken_file_name_gets_a_suffix() -> void:
	var older := ContentLayer.new()
	older.title = "Green pigment"
	older.created = Time.get_datetime_string_from_system()
	older.modified = older.created
	ResourceSaver.save(older, V + "Bio/note_chlorophyll.tres")
	VaultStore.refresh_note_list()
	app._refresh_note_list()
	await frames(1)
	app._on_new_note_pressed()
	await frames(2)
	await retitle("Chlorophyll")
	check(app.current_note.title == "Chlorophyll" and app.current_note.resource_path == V + "Bio/note_chlorophyll_1.tres",
		"renaming to a stem another note's file has gives note_chlorophyll_1.tres (%s)" % app.current_note.resource_path.get_file())
	check(FileAccess.get_file_as_string(V + "Bio/note_chlorophyll.tres").contains("Green pigment"), "…and leaves that note's file alone")
	await retitle("chlorophyll")
	check(app.current_note.resource_path == V + "Bio/note_chlorophyll_1.tres", "a case-only rename keeps the file (%s)" % app.current_note.resource_path.get_file())


func store_api() -> void:
	var a: ContentLayer = VaultStore.create_note("Store Alpha")
	check(VaultStore.rename_note(a, "Store Beta") == "" and a.resource_path == V + "note_store_beta.tres", "VaultStore.rename_note renames a top-level note's file")
	check(VaultStore.rename_note(a, "  ") == "" and a.title == "untitled" and a.resource_path.get_file().begins_with("note_untitled"), "a blank title means untitled")
	check(VaultStore.update_title("untitled", "Store Gamma") and a.title == "Store Gamma" and a.resource_path == V + "note_store_gamma.tres", "update_title delegates to rename_note")
	check(not VaultStore.update_title("Store Gamma", "PHOTOSYNTHESIS") and a.title == "Store Gamma", "update_title refuses a duplicate")
	check(not VaultStore.update_title("No such note", "Anything"), "update_title of a missing note is false")


# ── gap-sidebar-rename ──────────────────────────────────────────────────────

func sidebar_rename() -> void:
	var leaf: ContentLayer = VaultStore.create_note("Leaf")
	var stem: ContentLayer = VaultStore.create_note("Stem")
	app._refresh_note_list()
	await frames(2)

	# A plain click opens the note, no prompt
	await click(row(leaf))
	check(app.current_note == leaf and not prompt_open(), "a plain click on a row opens the note, no prompt")

	# Right-click: the menu has Rename… (id 16); choosing it opens the prompt
	await click(row(stem), MOUSE_BUTTON_RIGHT)
	var idx: int = app._ctx_menu.get_item_index(16)
	check(app._ctx_menu.visible and idx >= 0 and app._ctx_menu.get_item_text(idx) == "Rename…",
		"a right-click on a note row shows a menu with Rename… (id 16)")
	app._ctx_menu.set_focused_item(idx)
	await key(KEY_ENTER)
	check(not app._ctx_menu.visible and prompt_open() and app.current_note == stem and app._prompt_edit.text == "Stem",
		"choosing Rename… opens the note and a prompt with its title (%s)" % app._prompt_edit.text)
	await key(KEY_ESCAPE)
	check(not prompt_open() and stem.title == "Stem" and stem.resource_path == V + "note_stem.tres", "Escape closes it and leaves the title as it was")

	# F2 on a focused row: the prompt, its title selected
	await click(row(leaf))
	check(row(leaf).has_focus(), "(the clicked row has focus)")
	await key(KEY_F2)
	check(prompt_open() and app._prompt.title == "Rename note" and app._prompt_edit.text == "Leaf" and app._prompt_edit.get_selected_text() == "Leaf",
		"F2 on a sidebar row shows the Rename prompt with the title selected (%s)" % app._prompt_edit.get_selected_text())
	await type_text("Renamed")
	check(app._prompt_edit.text == "Renamed", "typing replaces the selected title (%s)" % app._prompt_edit.text)
	await key(KEY_ENTER)
	check(not prompt_open() and leaf.title == "Renamed", "Enter renames the note (%s)" % leaf.title)
	check(row(leaf) != null and row(leaf).text == "Renamed", "…the sidebar row reads Renamed")
	check(leaf.resource_path == V + "note_renamed.tres" and FileAccess.file_exists(leaf.resource_path) and not FileAccess.file_exists(V + "note_leaf.tres"),
		"…and the file is note_renamed.tres (%s)" % leaf.resource_path.get_file())
	check(app.title_edit.text == "Renamed" and app.status_label.text == "Renamed to Renamed", "…the title field and status follow (%s)" % app.status_label.text)
	check(row(leaf).has_focus(), "…and the keyboard stays on its (rebuilt) row")

	# F2 then Escape changes nothing
	await key(KEY_F2)
	check(prompt_open(), "F2 again opens the prompt")
	await type_text("Nope")
	await key(KEY_ESCAPE)
	check(not prompt_open() and leaf.title == "Renamed" and leaf.resource_path == V + "note_renamed.tres", "F2 then Escape leaves the title and file unchanged (%s)" % leaf.title)

	# A taken title: the status says so, the prompt stays open, text selected
	await key(KEY_F2)
	await type_text("stem")
	await key(KEY_ENTER)
	check(prompt_open() and app._prompt_edit.get_selected_text() == "stem", "a taken title keeps the prompt open with the text selected (%s)" % app._prompt_edit.get_selected_text())
	check(app.status_label.text.contains("already exists") and leaf.title == "Renamed", "…the status says it already exists (%s)" % app.status_label.text)
	await type_text("Petal")
	await key(KEY_ENTER)
	check(not prompt_open() and leaf.title == "Petal" and leaf.resource_path == V + "note_petal.tres", "…and a fixed title then renames (%s)" % leaf.title)

	# A double-click on a row opens the prompt for that note
	await click(row(stem))
	await click(row(stem), MOUSE_BUTTON_LEFT, true)
	check(prompt_open() and app.current_note == stem and app._prompt_edit.text == "Stem", "a double-click on a row opens the Rename prompt (%s)" % app._prompt_edit.text)
	await key(KEY_ESCAPE)
	check(not prompt_open() and stem.title == "Stem", "(Escape closes it)")

	# F2 in the editor; never in the search box
	app._switch_layer("raw")
	await frames(2)
	check(app.raw_text_layer.has_focus(), "(the editor has focus)")
	await key(KEY_F2)
	check(prompt_open() and app._prompt_edit.text == "Stem", "F2 in the editor opens the prompt for the open note")
	await key(KEY_ESCAPE)
	check(app.raw_text_layer.has_focus(), "…and Escape returns to the editor")
	app.search_box.grab_focus()
	await key(KEY_F2)
	check(not prompt_open(), "F2 in the search box does not rename")
	app.title_edit.grab_focus()
	await key(KEY_F2)
	check(not prompt_open(), "F2 in the title field does not rename")
	app.raw_text_layer.grab_focus()


## A double-click renames the note its first click opened. That click can
## re-sort the sidebar (it saves the note being edited, which jumps to the
## top), and so can a watcher poll between the presses: the second press may
## then land on another note's row. That press is a plain click; it never
## renames the note that slid under the cursor.
func double_click_on_moved_rows() -> void:
	app._watch_timer.stop()   # the poll below is run by hand, between the presses
	if not app._collapsed.has("Bio"):
		await click(app._folder_buttons["Bio"])   # collapse Bio, so every row fits the window
	var n: Dictionary = {}
	var day: int = 4
	for t in ["Xnote", "Ynote", "Bnote", "Anote"]:
		var note: ContentLayer = VaultStore.create_note(t)
		note.modified = "2001-01-%02dT00:00:00" % day   # older than every other note: the bottom rows, in this order
		VaultStore.save_note(note, false)
		n[t] = note
		day -= 1
	app._last_sig = VaultStore.disk_signature()
	app._refresh_note_list()
	await frames(2)

	# Anote is open with an edit not yet saved; double-click Bnote's row
	await click(row(n.Anote))
	app.raw_text_layer.text = "Typed in Anote."
	app._on_raw_text_changed()
	check(app.current_note == n.Anote and not app._auto_save_timer.is_stopped(), "(Anote is open, its autosave pending)")
	var spot: Vector2 = row(n.Bnote).get_global_rect().get_center()
	await click_at(spot)
	var slid: ContentLayer = note_at(spot)
	check(app.current_note == n.Bnote and slid == n.Ynote,
		"(the first click opened Bnote and saved Anote, which jumped to the top: Ynote's row is under the cursor now: %s)" % (slid.title if slid else "none"))
	await click_at(spot, MOUSE_BUTTON_LEFT, true)
	check(not prompt_open(), "a double-click whose second press lands on another note's row opens no Rename prompt (%s)" % app._prompt_edit.text)
	check(app.current_note == n.Ynote, "…the second press is a plain click on that row (%s)" % app.current_note.title)
	check(n.Ynote.title == "Ynote" and n.Bnote.title == "Bnote" and FileAccess.file_exists(V + "note_ynote.tres") and FileAccess.file_exists(V + "note_bnote.tres"),
		"…and renames nothing")

	# Rows rebuilt between the presses, but the clicked note still under the
	# cursor: renames it. The first click's autosave only moves Ynote's row
	# (_show_saved_row); a rename, a tag or a shown search rebuilds them all,
	# so rebuild them here as one of those would.
	app.raw_text_layer.text = "Typed in Ynote."
	app._on_raw_text_changed()
	var b_row: Button = row(n.Bnote)
	spot = b_row.get_global_rect().get_center()
	await click_at(spot)
	app._refresh_note_list()
	await frames(2)
	check(row(n.Bnote) != b_row and note_at(spot) == n.Bnote, "(the rows were rebuilt; Bnote's new row is under the cursor)")
	await click_at(spot, MOUSE_BUTTON_LEFT, true)
	check(prompt_open() and app.current_note == n.Bnote and app._prompt_edit.text == "Bnote",
		"a double-click on the note the first click opened still shows its Rename prompt (%s)" % app._prompt_edit.text)
	await type_text("Bee")
	await key(KEY_ENTER)
	check(not prompt_open() and n.Bnote.title == "Bee" and n.Bnote.resource_path == V + "note_bee.tres" and n.Ynote.title == "Ynote",
		"…and Enter renames that note (%s)" % n.Bnote.title)

	# A watcher poll between the presses moves the rows: no rename either
	await click(row(n.Xnote))
	check(app.current_note == n.Xnote, "(Xnote is open)")
	spot = row(n.Xnote).get_global_rect().get_center()
	var outside := ContentLayer.new()
	outside.title = "Znote"
	outside.created = Time.get_datetime_string_from_system()
	outside.modified = outside.created
	ResourceSaver.save(outside, V + "note_znote.tres")   # another app adds a newer note
	app.check_disk_changes()
	await frames(2)
	slid = note_at(spot)
	check(slid != null and slid != app.current_note, "(the poll rebuilt the rows: %s is under the cursor now)" % (slid.title if slid else "none"))
	await click_at(spot, MOUSE_BUTTON_LEFT, true)
	check(not prompt_open() and app.current_note == slid and n.Xnote.title == "Xnote" and slid.title != "",
		"a double-click split by a watcher poll opens the row under it, no Rename prompt (%s)" % app.current_note.title)
	app._watch_timer.start()
