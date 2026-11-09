extends SceneTree
## The sidebar shows what the vault holds after the app's own changes that
## don't rebuild it: an autosave that moves a row keeps Up / Down in the
## rows' order, and updates the note's Pinned / Starred row too; a folded
## folder stays folded when a parent is renamed or it is moved, and the
## courses "Add the tutorials and starter course" folds show folded. Enter
## on a search result row opens the note at its match, as a click does. The
## no-match hint's Create never makes a second note of a title, and says
## when it couldn't create one.
##   headless:  godot --headless --path . -s res://tests/sidebar_sync_test.gd

const TestVault = preload("res://tests/test_vault.gd")

var fails: int = 0
var app: Control


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## A note with a fixed `modified`, so the sidebar's newest-first order is known.
func make_note(title: String, modified: String, body: String = "", folder: String = "") -> ContentLayer:
	var n: ContentLayer = VaultStore.create_note(title, folder)
	n.raw_text = body
	n.modified = modified
	VaultStore.save_note(n, false)
	return n


## Press and release `code` with real key events.
func key(code: Key, mods: Dictionary = {}) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.ctrl_pressed = mods.get("ctrl", false)
		e.shift_pressed = mods.get("shift", false)
		e.pressed = pressed
		get_root().push_input(e)
	await frames(2)


## Open `n` in Edit view, type `words` at its end and let the autosave run.
func edit_and_save(n: ContentLayer, words: String) -> void:
	app._open_note(n)
	app._switch_layer("raw")
	app.raw_text_layer.text += words
	app.raw_text_layer.text_changed.emit()
	app._flush_pending_save()


## A real left click in the middle of `c`.
func click(c: Control) -> void:
	var pos: Vector2 = c.get_global_rect().get_center()
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	await frames(2)


func row_titles() -> Array[String]:
	var out: Array[String] = []
	for row in app._sidebar_rows():
		out.append(row.text)
	return out


func focused_name() -> String:
	var f: Control = get_root().gui_get_focus_owner()
	if f == null:
		return "<nothing>"
	return (f as Button).text if f is Button else str(f.name)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_sidebar_sync.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_sidebar_sync.json"   # never touch real progress
	ProgressStore.reset()
	var V: String = TestVault.open("sidebar-sync", false)
	make_note("Xray", "2026-01-03T10:00:00", "x")
	make_note("Yankee", "2026-01-02T10:00:00", "y")
	make_note("Zulu", "2026-01-01T10:00:00", "z")
	VaultStore.refresh_note_list()
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)

	await keys_follow_moved_row()
	await section_row_follows_save()
	await folds_follow_folders()
	await enter_opens_at_match()
	await create_from_search_checks()
	await starter_folds_show()   # last: it seeds the courses into the vault

	app.queue_free()
	await frames(2)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	TestVault.remove_tree(V)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


func note_named(title: String) -> ContentLayer:
	var i: int = VaultStore.get_note_index(title)
	return VaultStore.note_list[i] if i >= 0 else null


## An autosave moves the saved note's row to the top without a rebuild:
## Up / Down then walk the rows as shown, not as they were.
func keys_follow_moved_row() -> void:
	var rebuilt: int = app.refresh_count
	await edit_and_save(note_named("Zulu"), " more")
	check(row_titles() == ["Zulu", "Xray", "Yankee"] and app.refresh_count == rebuilt, "(the autosave moved Zulu's row to the top, no rebuild: %s)" % [row_titles()])
	app.raw_text_layer.grab_focus()
	await key(KEY_E, {"ctrl": true, "shift": true})
	check(focused_name() == "Zulu", "(Ctrl+Shift+E is on Zulu's row)")
	await key(KEY_DOWN)
	check(focused_name() == "Xray", "Down from the moved row goes to the row now below it (%s)" % focused_name())
	await key(KEY_DOWN)
	check(focused_name() == "Yankee", "…and Down again to the last row (%s)" % focused_name())
	await key(KEY_DOWN)
	check(focused_name() == "Yankee", "…where Down stays (%s)" % focused_name())
	await key(KEY_UP)
	await key(KEY_UP)
	await key(KEY_UP)
	check(focused_name() == "Zulu", "Up walks back to the top row and stays there (%s)" % focused_name())
	await key(KEY_ESCAPE)


## A pinned note whose quizzes were all passed gets a new quiz: the autosave
## updates its folder row (the ✓ goes) and its Pinned row the same, not
## leaving that one with the ✓ and the old tooltip until a rebuild.
func section_row_follows_save() -> void:
	const QUIZ: String = "```3d\npreset: quiz\nq: Q?\na*: Yes\na: No\n```\n"
	VaultStore.create_folder("Sub")
	var quizzy: ContentLayer = make_note("Quizzy", "2026-01-04T10:00:00", "Intro.\n\n" + QUIZ, "Sub")
	VaultStore.refresh_note_list()
	app._refresh_note_list()
	app._open_note(quizzy)
	app._toggle_pin()
	ProgressStore.record_result("Quizzy", 0, 1, 1)
	app.on_progress_changed()
	var pinned: Button = null
	for row in app._section_rows:
		if row.get_meta(&"note") == quizzy:
			pinned = row
	check(pinned != null and pinned.icon != null and app._note_buttons[quizzy].icon != null, "(Quizzy is pinned and done: both rows show the ✓)")
	var rebuilt: int = app.refresh_count
	await edit_and_save(quizzy, "\nMore.\n\n" + QUIZ)
	check(app.refresh_count == rebuilt and is_instance_valid(pinned), "(the autosave updated the rows in place)")
	check(app._note_buttons[quizzy].icon == null, "(the folder row lost its ✓: a quiz isn't passed yet)")
	check(pinned.icon == null and not pinned.tooltip_text.contains("Complete"), "…and so did the Pinned row (%s)" % pinned.tooltip_text.get_slice("\n", 0))
	check(pinned.tooltip_text.contains("More."), "…whose tooltip shows the saved text")


func folder_titles() -> Array[String]:
	var out: Array[String] = []
	for rel in app._folder_buttons:
		out.append(rel)
	return out


func ui_folds() -> Array:
	var ui: Variant = JSON.parse_string(FileAccess.get_file_as_string(VaultStore.data_dir().path_join("ui.json")))
	var folds: Array = (ui as Dictionary).get("collapsed", []) if ui is Dictionary else []
	folds.sort()
	return folds


## Folds are kept by folder path: a renamed parent and a moved folder take
## their subfolders' folds along, and a folder that went to the trash
## leaves none behind for a new folder at its old path.
func folds_follow_folders() -> void:
	VaultStore.create_folder("Outer")
	VaultStore.create_folder("Inner", "Outer")
	var inside: ContentLayer = make_note("Inside Inner", "2026-01-05T10:00:00", "deep", "Outer/Inner")
	app._refresh_note_list()
	app._toggle_folder("Outer/Inner")
	check(not app._note_buttons.has(inside), "(Outer/Inner is folded)")
	app.rename_folder("Outer", "Renamed")
	check(app._collapsed.has("Renamed/Inner") and not app._collapsed.has("Outer/Inner"), "renaming the parent keeps the subfolder folded (%s)" % [app._collapsed.keys()])
	check(not app._note_buttons.has(inside) and ui_folds() == ["Renamed/Inner"], "…in the sidebar and in ui.json (%s)" % [ui_folds()])
	VaultStore.create_folder("Dest")
	app.move_folder_to("Renamed/Inner", "Dest")
	check(app._collapsed.has("Dest/Inner") and not app._collapsed.has("Renamed/Inner"), "a moved folder stays folded (%s)" % [app._collapsed.keys()])
	check(not app._note_buttons.has(inside) and ui_folds() == ["Dest/Inner"], "…in the sidebar and in ui.json (%s)" % [ui_folds()])
	app.create_folder("Inner", "Renamed")
	app.create_folder("Inner", "Outer")
	check(not app._collapsed.has("Renamed/Inner") and not app._collapsed.has("Outer/Inner"), "new folders at a folded folder's old paths start open (%s)" % [app._collapsed.keys()])
	VaultStore.system_trash_hook = func(_p: String) -> Error: return FAILED
	app.delete_folder("Dest")
	VaultStore.system_trash_hook = Callable()
	check(ui_folds().is_empty(), "a folder moved to the trash leaves no fold behind (%s)" % [ui_folds()])


## The palette's "Add the tutorials and starter course" in a vault with no
## folds yet folds the courses in ui.json (StarterContent.seed_vault): the
## sidebar shows them folded, and the next fold keeps them.
func starter_folds_show() -> void:
	var ui_path: String = VaultStore.data_dir().path_join("ui.json")
	var f := FileAccess.open(ui_path, FileAccess.WRITE)   # a vault where no folder was ever folded
	f.store_string(JSON.stringify({"last_mode": "raw"}))
	f.close()
	app._load_collapsed()
	app._execute_command("add_starter")
	await frames(2)
	check(app._collapsed.has("Godot") and app._collapsed.has("Memetics"), "the seeded courses show folded in the sidebar (%s)" % [app._collapsed.keys()])
	var godot_row: bool = false
	for n in app._note_buttons:
		if VaultStore.folder_of(n) in ["Godot", "Memetics"]:
			godot_row = true
	check(not godot_row and app._folder_buttons.has("Tutorials"), "…with none of their lessons listed, Tutorials open")
	app._toggle_folder("Tutorials")
	check(ui_folds() == ["Godot", "Memetics", "Tutorials"], "the next fold keeps the courses' folds in ui.json (%s)" % [ui_folds()])


## Ctrl+F, a word, Down into the results, Enter: the note opens with the
## caret on the match, as a click on the row and Enter in the search box do.
## Enter on the row used to open it at line 0 (the row's key handler marks
## the press handled, so the row's pressed, which reveals the match, never
## fired).
func enter_opens_at_match() -> void:
	make_note("Haystack", "2026-01-06T10:00:00", "first line\nsecond line\nthe needle is here")
	app._switch_layer("raw")
	await key(KEY_F, {"ctrl": true})
	for ch in "needle":
		var e := InputEventKey.new()
		e.pressed = true
		e.unicode = ch.unicode_at(0)
		e.keycode = OS.find_keycode_from_string(ch.to_upper())
		get_root().push_input(e)
		await process_frame
	await frames(2)
	check(app.search_box.text == "needle" and app._visible_notes.size() == 1, "(searching needle lists Haystack: %s)" % app.search_box.text)
	await key(KEY_DOWN)
	check(focused_name() == "Haystack", "(Down puts the keyboard on the result row)")
	await key(KEY_ENTER)
	check(app.current_note != null and app.current_note.title == "Haystack", "Enter on the result row opens the note")
	check(app.raw_text_layer.get_caret_line() == 2 and app.raw_text_layer.get_caret_column() == 4, "…with the caret on the match (line %d, column %d)" % [app.raw_text_layer.get_caret_line(), app.raw_text_layer.get_caret_column()])
	app.search_box.text = ""
	app._refresh_note_list()


## The sidebar's no-match hint (SidebarEmpty), its label texts and its buttons.
func empty_hint() -> Dictionary:
	var out: Dictionary = {"labels": [], "buttons": {}}
	for c in app.note_list_container.get_children():
		if c.name == "SidebarEmpty" and not c.is_queued_for_deletion():
			for k in c.get_children():
				if k is Label:
					out.labels.append(k.text)
				elif k is Button:
					out.buttons[k.text] = k
	return out


func count_titled(title: String) -> int:
	return VaultStore.note_list.filter(func(n: ContentLayer) -> bool: return n.title == title).size()


## Under a tag filter, a search for a note the filter hides says so and
## offers to clear the filter, not to create a second note of that title
## (links, progress and the Journey find notes by title). And a Create
## whose file can't be written says so instead of "Created".
func create_from_search_checks() -> void:
	var alpha: ContentLayer = make_note("Alphabet", "2026-01-07T10:00:00", "untagged")
	var waves: ContentLayer = make_note("Waves", "2026-01-08T10:00:00", "tagged")
	waves.tags = ["physics"]
	VaultStore.save_note(waves, false)
	app._refresh_note_list()
	app._set_tag_filter("physics")
	app.search_box.text = "Alphabet"
	app._refresh_note_list()
	var hint: Dictionary = empty_hint()
	check(hint.labels.size() > 0 and str(hint.labels[0]).begins_with("No notes tagged #physics match “Alphabet”"), "a search the tag filter hides says so (%s)" % [hint.labels])
	check(not hint.buttons.keys().any(func(t: String) -> bool: return t.begins_with("Create")) and hint.buttons.has("Clear filter"), "…offering Clear filter, not Create (%s)" % [hint.buttons.keys()])
	app._create_note_from_search("alphabet")
	check(count_titled("Alphabet") == 1 and count_titled("alphabet") == 0 and app.current_note == alpha, "Create with a title another note has opens that note, makes no second one")
	check(app.status_label.text == "“Alphabet” already exists", "…and says so (%s)" % app.status_label.text)
	app._clear_tag_filter()

	if not OS.get_name() in ["Linux", "macOS"]:
		print("SKIP  a Create that can't write its file (chmod) on " + OS.get_name())
		return
	app.search_box.text = "Brandnew"
	app._refresh_note_list()
	hint = empty_hint()
	check(hint.buttons.has("Create “Brandnew”"), "(a search nothing matches offers Create)")
	OS.execute("chmod", ["555", VaultStore.vault_path])
	if hint.buttons.has("Create “Brandnew”"):
		var btn: Button = hint.buttons["Create “Brandnew”"]
		(app.note_list_container.get_parent() as ScrollContainer).ensure_control_visible(btn)
		await frames(1)
		await click(btn)
	OS.execute("chmod", ["755", VaultStore.vault_path])
	check(count_titled("Brandnew") == 0, "(the note couldn't be written)")
	check(app.status_label.text.begins_with("Couldn't create “Brandnew”: "), "a Create that can't write its file says so, not Created (%s)" % app.status_label.text)
	app.search_box.text = ""
	app._refresh_note_list()
