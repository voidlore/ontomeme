extends SceneTree
## Starred & pinned in the window, clicked with real mouse input:
## the top bar's Star and Pin buttons (Ctrl+S stays save-only), the
## sidebar's collapsible Pinned (N) / Starred (N) sections above the folders,
## star / pin from the command palette and a note's right-click menu, and
## Ctrl+Z after typing in a starred, pinned note leaving both flags on, and
## a star leaving the words a failed save couldn't write where they are.
##   headless:  godot --headless --path . -s res://tests/starred_pinned_ui_test.gd
##   + images:  xvfb-run godot --path . -s res://tests/starred_pinned_ui_test.gd -- <out_dir>
## Never use tests/ui_snapshots.gd for these shots: it opens the startup vault.

const TestVault = preload("res://tests/test_vault.gd")
const OLD_STAMP: String = "2001-02-03T04:05:06"

var fails: int = 0
var out: String = ""
var app: Control
var _vaults: Array[String] = []   # removed at the end


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## A screenshot into the out dir, when there is one and a display.
func shot(name: String) -> void:
	if out == "" or DisplayServer.get_name() == "headless":
		return
	await create_timer(0.8).timeout
	get_root().get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("saved ", name)


## A real click: move there, then press and release the button (left unless
## told otherwise).
func click(ctrl: Control, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var pos: Vector2 = ctrl.get_global_rect().get_center()
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	await process_frame
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = button
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	await frames(3)


## Ctrl+<key> (or Cmd+<key> with `meta`), pressed and released.
func press_shortcut(keycode: Key, meta: bool = false) -> void:
	for pressed in [true, false]:
		var k := InputEventKey.new()
		k.keycode = keycode
		k.ctrl_pressed = not meta
		k.meta_pressed = meta
		k.pressed = pressed
		get_root().push_input(k)
	await frames(2)


func boot() -> Control:
	var a: Control = load("res://note.tscn").instantiate()
	get_root().add_child(a)
	await frames(4)
	return a


func close_app() -> void:
	if app != null:
		app.queue_free()
		app = null
	await frames(2)


## The note as its file says now, read past the resource cache.
func disk_note(path: String) -> ContentLayer:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as ContentLayer


func open_vault(name: String, seed: bool) -> String:
	var v: String = TestVault.open("starred_pinned_ui" + name, seed)
	_vaults.append(v)
	return v


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	if out != "":
		DirAccess.make_dir_recursive_absolute(out)
	JourneyStore.file_override = "user://test_journey_starred_pinned_ui.json"   # never the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_starred_pinned_ui.json"   # never real progress
	ProgressStore.reset()

	await titlebar_buttons()
	await close_app()
	await sidebar_sections()
	await close_app()
	await palette_and_menu()
	await close_app()
	await typed_title_then_menu()
	await close_app()
	await undo_keeps_flags()
	await close_app()
	if OS.get_name() in ["Linux", "macOS"]:
		await unsaved_words_kept()
	else:
		print("SKIP  unsaved words and a star (chmod) on " + OS.get_name())

	await close_app()
	for v in _vaults:
		TestVault.remove_tree(v)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)


# ── The top bar's Star and Pin ──────────────────────────────────────────────

func titlebar_buttons() -> void:
	open_vault("", true)
	app = await boot()
	var star: Button = app.get_node("%StarButton")
	var pin: Button = app.get_node("%PinButton")
	check(app.current_note != null, "a note is open on launch")
	check(star.icon != null and pin.icon != null and star.text == "" and pin.text == "", "star and pin are icon-only buttons")
	var tb: HBoxContainer = app.get_node("AppLayout/Body/Editor/TopBar/TopBarHBox")
	var delete_at: int = app.delete_btn.get_index()
	check(star.get_parent() == tb and pin.get_parent() == tb and star.get_index() < delete_at and pin.get_index() < delete_at,
		"star and pin sit in the top bar before Delete")
	var note: ContentLayer = app.current_note
	var path: String = note.resource_path
	var modified: String = note.modified

	# ── Star on, star off ──
	await click(star)
	check(note.starred_at != "", "clicking the star stars the open note (%s)" % note.starred_at)
	check(star.button_pressed, "the star shows pressed")
	check(star.icon == Icons.get_icon("star_filled"), "the starred icon is the filled star")
	var on_disk: ContentLayer = disk_note(path)
	check(on_disk != null and on_disk.starred_at == note.starred_at, "the star is in the note's .tres on disk")
	check(note.modified == modified and on_disk != null and on_disk.modified == modified, "starring leaves `modified` as it was")
	check(app.status_label.text.contains("Starred"), "the status says Starred (%s)" % app.status_label.text)
	app.check_disk_changes()
	check(app.status_label.text.contains("Starred"), "the watcher does not report our own save as an outside change (%s)" % app.status_label.text)
	await shot("topbar_starred")
	await click(star)
	check(note.starred_at == "" and not star.button_pressed, "a second click unstars and releases the button")
	check(star.icon == Icons.get_icon("star"), "the unstarred icon is the outline star")
	on_disk = disk_note(path)
	check(on_disk != null and on_disk.starred_at == "" and not FileAccess.get_file_as_string(path).contains("starred_at"), "the unstar is on disk")
	check(app.status_label.text.contains("Unstarred"), "the status says Unstarred (%s)" % app.status_label.text)

	# ── Pin on, pin off ──
	await click(pin)
	check(note.pinned_at != "" and pin.button_pressed, "clicking the pin pins the open note and shows pressed")
	check(pin.icon == Icons.get_icon("pin_filled"), "the pinned icon is the filled pin")
	on_disk = disk_note(path)
	check(on_disk != null and on_disk.pinned_at == note.pinned_at and on_disk.modified == modified, "the pin is on disk, `modified` unchanged")
	check(app.status_label.text.contains("Pinned"), "the status says Pinned (%s)" % app.status_label.text)
	check(VaultStore.note_list[0] == note, "the pinned note leads the note list")
	app.check_disk_changes()
	check(app.status_label.text.contains("Pinned"), "the watcher leaves the Pinned status (%s)" % app.status_label.text)
	await shot("topbar_pinned")
	await click(pin)
	check(note.pinned_at == "" and not pin.button_pressed, "a second click unpins and releases the button")
	on_disk = disk_note(path)
	check(on_disk != null and on_disk.pinned_at == "", "the unpin is on disk")
	check(app.status_label.text.contains("Unpinned"), "the status says Unpinned (%s)" % app.status_label.text)

	# ── Ctrl+S and Cmd+S only save ──
	await click(star)
	for meta in [false, true]:
		var key_name: String = "Cmd+S" if meta else "Ctrl+S"
		note.modified = OLD_STAMP
		VaultStore.save_note(note, false)
		var starred_at: String = note.starred_at
		await press_shortcut(KEY_S, meta)
		check(note.starred_at == starred_at and star.button_pressed, "%s on a starred note keeps it starred" % key_name)
		on_disk = disk_note(path)
		check(note.modified != OLD_STAMP and on_disk != null and on_disk.modified == note.modified and on_disk.starred_at == starred_at,
			"%s saved the note, star and all (modified %s)" % [key_name, note.modified])
	await click(star)

	# ── Typing, then a star click: the typing lands first ──
	note.modified = OLD_STAMP
	VaultStore.save_note(note, false)
	app.raw_text_layer.text = "typed just before starring"
	app.raw_text_layer.text_changed.emit()
	check(not app._auto_save_timer.is_stopped(), "typing starts the autosave timer")
	await click(star)
	on_disk = disk_note(path)
	check(on_disk != null and on_disk.raw_text == "typed just before starring" and on_disk.starred_at != "",
		"the star click saved the typed body and the star")
	check(on_disk != null and on_disk.modified != OLD_STAMP, "the typed body landed with a real modified stamp")
	check(app._auto_save_timer.is_stopped(), "nothing is left pending")
	await click(star)

	# ── An outside edit of the open note, then a star click ──
	app._watch_timer.stop()   # the click, not the watcher, must meet the edit
	var outside: ContentLayer = disk_note(path)
	outside.raw_text = "written by another program"
	ResourceSaver.save(outside, path)
	await click(star)
	check(note.raw_text == "written by another program" and note.starred_at != "", "the star applies to the outside version")
	check(app.raw_text_layer.text == "written by another program", "the editor shows the outside version, not its stale text")
	on_disk = disk_note(path)
	check(on_disk != null and on_disk.raw_text == "written by another program" and on_disk.starred_at != "", "the outside body is on disk with the star")
	app._watch_timer.start()
	await click(star)

	# ── It fits the minimum window ──
	# Headless already is 820x520. With a display, shrink to it first: the
	# readable-width margins grow with the window and inflate the minimum.
	get_root().size = Vector2i(820, 520)
	await frames(4)
	var min_w: float = app.get_node("AppLayout").get_combined_minimum_size().x
	check(min_w <= 820.0, "the app's minimum width fits 820 px (%d)" % min_w)
	var root_rect := Rect2(Vector2.ZERO, Vector2(get_root().size))
	check(root_rect.encloses(star.get_global_rect()) and root_rect.encloses(pin.get_global_rect()),
		"both buttons lie inside the window (%s, %s in %s)" % [star.get_global_rect(), pin.get_global_rect(), root_rect])
	await shot("topbar_820")

	# ── The empty state has nothing to star ──
	await close_app()
	open_vault("_empty", false)
	app = await boot()
	check(app.current_note == null, "an empty vault opens nothing")
	check(app.star_btn.disabled and app.pin_btn.disabled, "the star and pin are disabled with no note open")
	app._toggle_star()
	check(VaultStore.note_list.is_empty() and app.status_label.text == "No note open", "a toggle with nothing open says so")


# ── The sidebar's Pinned and Starred sections ───────────────────────────────

## Children of the note list whose name contains `part` ("PinnedRow", …).
func rows_named(part: String) -> Array:
	return app.note_list_container.get_children().filter(func(c: Node) -> bool: return String(c.name).contains(part))


## The notes a section's rows open, top to bottom.
func row_notes(part: String) -> Array:
	return rows_named(part).map(func(c: Node) -> ContentLayer: return c.get_meta(&"note"))


func header(section: String) -> Button:
	var found: Array = rows_named(section + "Header")
	return found[0] if found.size() > 0 else null


func index_of_first(part: String) -> int:
	var found: Array = rows_named(part)
	return found[0].get_index() if found.size() > 0 else -1


func row_for(part: String, note: ContentLayer) -> Button:
	for row in rows_named(part):
		if row.get_meta(&"note") == note:
			return row
	return null


func titles(notes: Array) -> Array:
	return notes.map(func(n: ContentLayer) -> String: return n.title + " in " + VaultStore.folder_of(n))


func ui_json() -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(VaultStore.data_dir().path_join("ui.json")))
	return v if v is Dictionary else {}


## A note with `field` set to `stamp` (explicit, so the order is known).
func flag(note: ContentLayer, field: StringName, stamp: String) -> void:
	note.set(field, stamp)
	VaultStore.save_note(note, false)


func sidebar_sections() -> void:
	open_vault("_sections", false)
	VaultStore.create_folder("A")
	VaultStore.create_folder("B")
	var same_a: ContentLayer = VaultStore.create_note("Same", "A")
	var same_b: ContentLayer = VaultStore.create_note("Same", "B")
	var a_two: ContentLayer = VaultStore.create_note("A two", "A")
	var b_two: ContentLayer = VaultStore.create_note("B two", "B")
	var tops: Array[ContentLayer] = []
	for i in range(1, 5):
		tops.append(VaultStore.create_note("Top %d" % i))
	check(VaultStore.note_list.size() == 8 and same_a.resource_path != same_b.resource_path, "8 notes, two titled Same in A and B")
	flag(tops[0], &"pinned_at", "2026-01-01T10:00:01")
	flag(a_two, &"pinned_at", "2026-01-01T10:00:03")
	flag(tops[2], &"pinned_at", "2026-01-01T10:00:02")
	flag(same_a, &"starred_at", "2026-01-02T10:00:05")
	flag(same_b, &"starred_at", "2026-01-02T10:00:04")
	flag(tops[1], &"starred_at", "2026-01-02T10:00:01")
	flag(b_two, &"starred_at", "2026-01-02T10:00:03")
	flag(tops[3], &"starred_at", "2026-01-02T10:00:02")
	app = await boot()
	app._refresh_note_list()
	await frames(2)

	# ── Headers, counts, order ──
	var pinned_h: Button = header("Pinned")
	var starred_h: Button = header("Starred")
	check(pinned_h != null and pinned_h.text == "Pinned (3)", "the Pinned header reads Pinned (3) (%s)" % (pinned_h.text if pinned_h else "none"))
	check(starred_h != null and starred_h.text == "Starred (5)", "the Starred header reads Starred (5) (%s)" % (starred_h.text if starred_h else "none"))
	var first_folder: int = index_of_first("Folder_")
	check(pinned_h != null and starred_h != null and pinned_h.get_index() == 0 and pinned_h.get_index() < starred_h.get_index()
		and starred_h.get_index() < first_folder, "Pinned, then Starred, both above the first folder row")
	check(row_notes("PinnedRow") == [a_two, tops[2], tops[0]], "pinned rows run newest pin first %s" % str(titles(row_notes("PinnedRow"))))
	check(row_notes("StarredRow") == [same_a, same_b, b_two, tops[3], tops[1]], "starred rows run newest star first %s" % str(titles(row_notes("StarredRow"))))
	check(rows_named("PinnedRow").all(func(r: Node) -> bool: return r.get_index() > pinned_h.get_index() and r.get_index() < starred_h.get_index()),
		"the pinned rows sit under their header")
	check(pinned_h.icon == Icons.get_icon("chevron_down"), "an open section shows the down chevron")
	check(app._note_buttons.size() == 8 and app._visible_notes.size() == 8, "each note still has one folder row (%d), counted once (%d)" % [app._note_buttons.size(), app._visible_notes.size()])
	check(rows_named("StarredRow").all(func(r: Node) -> bool: return (r as Button).button_group == null), "section rows are outside the folder rows' ButtonGroup")
	await shot("sidebar_sections")

	# ── No pins, no Pinned header ──
	for n in [tops[0], a_two, tops[2]]:
		VaultStore.set_pinned(n, false)
	app._refresh_note_list()
	check(header("Pinned") == null and rows_named("PinnedRow").is_empty(), "with nothing pinned there is no Pinned header")
	check(header("Starred") != null and header("Starred").get_index() == 0, "Starred moves to the top")

	# ── A section row opens its note by object, even with a twin title ──
	var row_b: Button = row_for("StarredRow", same_b)
	var scroll: ScrollContainer = app.note_list_container.get_parent()
	scroll.ensure_control_visible(row_b)
	await frames(2)
	await click(row_b)
	check(app.current_note == same_b and app.current_note.resource_path == same_b.resource_path,
		"clicking the Starred row for B's Same opens B's (%s)" % (app.current_note.resource_path if app.current_note else "none"))
	check(row_b.button_pressed and app._note_buttons[same_b].button_pressed, "the section row and the folder row both show pressed")
	check(not row_for("StarredRow", same_a).button_pressed and not app._note_buttons[same_a].button_pressed, "A's Same rows are not pressed")
	check(app.note_count_label.text == "8", "the note count ignores the section rows (%s)" % app.note_count_label.text)

	# ── Section rows follow the selection (_sync_list_selection) ──
	# No ButtonGroup ties a section row to the others, so only the sync
	# releases the old note's rows and presses the new one's.
	var row_a: Button = row_for("StarredRow", same_a)
	var folder_a: Button = app._note_buttons[same_a]
	scroll.ensure_control_visible(folder_a)
	await frames(2)
	await click(folder_a)
	check(app.current_note == same_a, "clicking A's Same in folder A opens it")
	check(not row_b.button_pressed and not app._note_buttons[same_b].button_pressed,
		"B's Same rows are released, its Starred row too")
	check(row_a.button_pressed and folder_a.button_pressed, "A's Same rows show pressed, its Starred row too")
	app._open_note(tops[3])
	check(not row_a.button_pressed and row_for("StarredRow", tops[3]).button_pressed,
		"opening another note moves the pressed Starred row with it")
	app._open_note(same_a)
	app._refresh_note_list()   # the rows are built afresh, the open note's pressed
	row_a = row_for("StarredRow", same_a)
	row_b = row_for("StarredRow", same_b)
	folder_a = app._note_buttons[same_a]
	check(row_a.button_pressed, "a rebuilt list shows the open note's Starred row pressed")
	scroll.ensure_control_visible(row_a)
	await frames(2)
	await click(row_a)
	check(app.current_note == same_a and row_a.button_pressed and folder_a.button_pressed,
		"clicking the open note's Starred row again leaves it pressed")
	await click(row_b)
	check(app.current_note == same_b, "and the Starred row for B's Same opens it again")

	var rc := InputEventMouseButton.new()
	rc.button_index = MOUSE_BUTTON_RIGHT
	rc.pressed = true
	rc.position = row_for("StarredRow", same_a).get_global_rect().get_center()
	rc.global_position = rc.position
	get_root().push_input(rc)
	await frames(2)
	check(app._ctx_menu.visible and app._ctx_target.get("note") == same_a, "right-clicking a section row opens that note's menu")
	app._ctx_menu.hide()
	await frames(1)

	# ── Collapsing a section is remembered, apart from folders ──
	app._toggle_folder("A")
	var ui: Dictionary = ui_json()
	ui["other_feature"] = "kept"
	var f := FileAccess.open(VaultStore.data_dir().path_join("ui.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(ui))
	f.close()
	await click(header("Starred"))
	check(header("Starred") != null and rows_named("StarredRow").is_empty(), "clicking the Starred header hides its rows")
	check(header("Starred").text == "Starred (5)" and header("Starred").icon == Icons.get_icon("chevron_right"), "the collapsed header keeps its count, chevron right")
	ui = ui_json()
	check(ui.get("sections_collapsed") == ["starred"], "ui.json has sections_collapsed: [starred] (%s)" % str(ui.get("sections_collapsed")))
	check(ui.get("collapsed") == ["A"], "the folder collapsed list is unchanged (%s)" % str(ui.get("collapsed")))
	check(ui.get("other_feature") == "kept", "other keys in ui.json survive the save")
	await close_app()
	app = await boot()
	check(header("Starred") != null and rows_named("StarredRow").is_empty(), "a fresh window keeps Starred collapsed")
	check(app._collapsed.has("A"), "and folder A collapsed")
	await click(header("Starred"))
	check(rows_named("StarredRow").size() == 5 and ui_json().get("sections_collapsed") == [], "a second click opens it again")
	app._toggle_folder("A")

	# ── The tag filter narrows the sections; a text search hides them ──
	for n: ContentLayer in [tops[1], b_two]:
		n.tags.append("x")
		VaultStore.save_note(n, false)
	VaultStore.set_pinned(tops[0], true)
	app._set_tag_filter("x")
	check(header("Starred") != null and header("Starred").text == "Starred (2)" and row_notes("StarredRow") == [b_two, tops[1]],
		"filtering by #x lists only the starred notes tagged x %s" % str(titles(row_notes("StarredRow"))))
	check(header("Pinned") == null, "the pinned note without #x leaves no Pinned header")
	app._set_tag_filter("")
	check(header("Pinned") != null and header("Pinned").text == "Pinned (1)", "clearing the filter brings Pinned (1) back")
	app.search_box.text = "abc"
	app._refresh_note_list()
	check(header("Pinned") == null and header("Starred") == null and rows_named("Row").is_empty(), "a text search shows no sections")
	app.search_box.text = ""
	app._refresh_note_list()
	check(header("Starred") != null, "clearing the search brings them back")

	# ── Still fits the minimum window ──
	get_root().size = Vector2i(820, 520)
	await frames(4)
	var min_w: float = app.get_node("AppLayout").get_combined_minimum_size().x
	check(min_w <= 820.0, "with sections, the minimum width fits 820 px (%d)" % min_w)
	await shot("sidebar_sections_820")


# ── Star and pin from the palette and the right-click menu ──────────────────

## The context menu's text for `id` after showing it for `note`.
func ctx_item(note: ContentLayer, id: int) -> String:
	app._show_ctx({"type": "note", "note": note})
	var text: String = app._ctx_menu.get_item_text(app._ctx_menu.get_item_index(id))
	app._ctx_menu.hide()
	return text


func palette_actions(filter: String) -> Array:
	app._open_palette()
	app._palette_search.text = filter
	app._on_palette_search_changed(filter)
	return app._palette_items.map(func(item: Dictionary) -> String: return item.action)


func palette_and_menu() -> void:
	open_vault("_menu", false)
	var y: ContentLayer = VaultStore.create_note("Note Y")
	var x: ContentLayer = VaultStore.create_note("Note X")
	x.raw_text = "the open note"
	x.modified = OLD_STAMP
	VaultStore.save_note(x, false)
	app = await boot()
	app._open_note(x)
	await frames(2)

	# ── The palette ──
	app._execute_command("star")
	check(x.starred_at != "" and app.star_btn.button_pressed, "the palette's 'star' stars the open note")
	app._execute_command("star")
	check(x.starred_at == "" and not app.star_btn.button_pressed, "and a second run unstars it")
	app._execute_command("pin")
	check(x.pinned_at != "" and app.pin_btn.button_pressed, "the palette's 'pin' pins the open note")
	app._execute_command("pin")
	check(x.pinned_at == "", "and a second run unpins it")
	check(palette_actions("star").has("star"), "the palette filtered by 'star' lists Star / unstar note")
	var actions: Array = palette_actions("pin")
	check(actions.has("pin"), "the palette filtered by 'pin' lists Pin / unpin note")
	app._palette_selected_index = actions.find("pin")
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	get_root().push_input(enter)
	await frames(2)
	check(x.pinned_at != "" and not app._palette_visible, "Enter on Pin / unpin note in the palette pins the note")
	app._execute_command("pin")

	# ── The right-click menu on another note ──
	check(ctx_item(y, 14) == "Star" and ctx_item(y, 15) == "Pin to top", "an unflagged note's menu offers Star and Pin to top")
	app._show_ctx({"type": "note", "note": y})
	app._on_ctx_menu(14)
	app._ctx_menu.hide()
	check(y.starred_at != "" and disk_note(y.resource_path).starred_at == y.starred_at, "the menu's Star stars that note, on disk")
	check(app.current_note == x and x.starred_at == "" and x.modified == OLD_STAMP and app.raw_text_layer.text == "the open note",
		"the open note stays open and unchanged")
	check(not app.star_btn.button_pressed, "the top bar still shows the open note's (unstarred) state")
	check(header("Starred") != null and row_notes("StarredRow") == [y], "the sidebar lists Y under Starred")
	check(app.status_label.text.contains("Starred") and app.status_label.text.contains("Note Y"), "the status names Y (%s)" % app.status_label.text)
	check(ctx_item(y, 14) == "Unstar", "a starred note's menu reads Unstar")
	app._show_ctx({"type": "note", "note": y})
	app._on_ctx_menu(15)
	app._ctx_menu.hide()
	check(y.pinned_at != "" and VaultStore.note_list[0] == y and app.current_note == x, "the menu's Pin to top pins Y, X stays open")
	check(ctx_item(y, 15) == "Unpin", "a pinned note's menu reads Unpin")
	for id in [14, 15]:
		app._show_ctx({"type": "note", "note": y})
		app._on_ctx_menu(id)
		app._ctx_menu.hide()
	check(y.starred_at == "" and y.pinned_at == "" and header("Starred") == null and header("Pinned") == null, "Unstar and Unpin clear Y and its sections")
	app._last_sig = ""
	app.check_disk_changes()
	check(app.current_note == x and app.raw_text_layer.text == "the open note", "a watcher pass afterwards keeps X open as it was")

	# ── The right-click menu on the open note saves pending typing first ──
	app.raw_text_layer.text = "typed, then starred from the menu"
	app.raw_text_layer.text_changed.emit()
	app._show_ctx({"type": "note", "note": x})
	app._on_ctx_menu(14)
	app._ctx_menu.hide()
	var on_disk: ContentLayer = disk_note(x.resource_path)
	check(on_disk.raw_text == "typed, then starred from the menu" and on_disk.starred_at != "" and on_disk.modified != OLD_STAMP,
		"Star on the open note's menu saves the typing, then stars it")
	check(app.star_btn.button_pressed, "the top bar follows a menu star on the open note")

	# ── An outside edit of the open note, then the menu flags another note ──
	# Flagging Y saves Y; that save rescans the vault and reads X's changed
	# file into X in place, at its new hash. The editor's stale text must not
	# be autosaved over it. The watcher is off: the menu must meet the edit.
	app._watch_timer.stop()
	await create_timer(1.1).timeout   # mtime is per second: the rescan must see X change
	var outside: ContentLayer = disk_note(x.resource_path)
	outside.raw_text = "outside edit, nothing typed"
	ResourceSaver.save(outside, x.resource_path)
	app._show_ctx({"type": "note", "note": y})
	app._on_ctx_menu(14)
	app._ctx_menu.hide()
	check(y.starred_at != "", "the menu's Star stars Y while X changed on disk")
	check(app.current_note == x and app.raw_text_layer.text == "outside edit, nothing typed",
		"the editor shows X's outside edit, not its stale text (%s)" % app.raw_text_layer.text)
	app.raw_text_layer.text += "!"
	app.raw_text_layer.text_changed.emit()
	app._flush_pending_save()
	on_disk = disk_note(x.resource_path)
	check(on_disk.raw_text == "outside edit, nothing typed!", "typing afterwards builds on the outside edit (%s)" % on_disk.raw_text)
	check(conflict_copies().is_empty(), "no conflict copy was needed")

	# ── … and with typing still waiting for its autosave ──
	await create_timer(1.1).timeout
	app.raw_text_layer.text = "typed before the outside edit"
	app.raw_text_layer.text_changed.emit()
	outside = disk_note(x.resource_path)
	outside.raw_text = "outside edit, typing pending"
	ResourceSaver.save(outside, x.resource_path)
	app._show_ctx({"type": "note", "note": y})
	app._on_ctx_menu(14)
	app._ctx_menu.hide()
	app._flush_pending_save()   # whatever is still pending lands now
	check(y.starred_at == "", "the menu's Unstar unstars Y")
	on_disk = disk_note(x.resource_path)
	check(on_disk.raw_text == "outside edit, typing pending", "X's outside edit stays on disk (%s)" % on_disk.raw_text)
	var copies: Array = conflict_copies()
	check(copies.size() == 1 and copies[0].raw_text == "typed before the outside edit",
		"the typing is kept as a conflict copy (%d copies)" % copies.size())
	check(copies.has(app.current_note) and app.raw_text_layer.text == "typed before the outside edit",
		"the editor shows the conflict copy with the typing")
	app._watch_timer.start()


func conflict_copies() -> Array:
	return VaultStore.note_list.filter(func(n: ContentLayer) -> bool: return n.title.contains("(conflict copy"))


# ── A typed title, then the menu's Star / Pin ───────────────────────────────
# The title field saves on focus out or Enter. A right-click on a sidebar row
# leaves focus in it, so the menu's item runs before the typed title is
# saved: it must save it, not put the old title back.

func typed_title_then_menu() -> void:
	open_vault("_title", false)
	var y: ContentLayer = VaultStore.create_note("Note Y")
	var x: ContentLayer = VaultStore.create_note("Note X")
	app = await boot()
	app._open_note(x)
	await frames(2)
	var scroll: ScrollContainer = app.note_list_container.get_parent()
	# [the note right-clicked, the menu item, the flag it flips, which menu]
	var cases: Array = [
		[y, 14, &"starred_at", "Star on another note's menu"],
		[y, 15, &"pinned_at", "Pin on another note's menu"],
		[x, 14, &"starred_at", "Star on the open note's menu"],
		[x, 15, &"pinned_at", "Pin on the open note's menu"],
	]
	for i in range(cases.size()):
		var target: ContentLayer = cases[i][0]
		var id: int = cases[i][1]
		var field: StringName = cases[i][2]
		var what: String = cases[i][3]
		var was_on: bool = str(target.get(field)) != ""
		var body: String = "body typed for case %d" % (i + 1)
		var renamed: String = "Renamed X %d" % (i + 1)
		# Typing in the body (autosave pending), then in the title.
		app.raw_text_layer.grab_focus()
		app.raw_text_layer.text = body
		app.raw_text_layer.text_changed.emit()
		app.title_edit.grab_focus()
		await frames(1)
		app.title_edit.text = renamed
		var row: Button = app._note_buttons[target]
		scroll.ensure_control_visible(row)
		await frames(2)
		await click(row, MOUSE_BUTTON_RIGHT)
		check(app._ctx_menu.visible and app._ctx_target.get("note") == target and app.title_edit.has_focus(),
			"%s: the right-click opens the menu, focus stays in the title field" % what)
		app._ctx_menu.id_pressed.emit(id)
		app._ctx_menu.hide()
		await frames(2)
		check((str(target.get(field)) != "") != was_on, "%s flips %s on %s" % [what, field, target.title])
		check(app.current_note == x and app.title_edit.text == renamed,
			"%s: the title field keeps the typed title (%s)" % [what, app.title_edit.text])
		var on_disk: ContentLayer = disk_note(x.resource_path)
		check(x.title == renamed and on_disk != null and on_disk.title == renamed and on_disk.raw_text == body,
			"%s: the typed title and body are saved (%s, %s)" % [what, x.title, on_disk.title if on_disk else "none"])
		check(app.raw_text_layer.text == body and app.raw_text_layer.has_undo(), "%s: the body keeps its text and undo history" % what)
		app.title_edit.release_focus()
		await frames(1)
		check(x.title == renamed and disk_note(x.resource_path).title == renamed, "%s: leaving the title field keeps the new title" % what)
	check(conflict_copies().is_empty(), "no conflict copy was needed")


# ── Undo leaves the star and pin alone ──────────────────────────────────────
# The editor's own Ctrl+Z undoes typing, and the app's Ctrl+Z (focus outside
# the editor) goes through undo_redo.gd, which snapshots only a note's title
# and raw_text. Neither may take a star or a pin away.

## Type `text` into the focused control, one real key press per character.
func type_text(text: String) -> void:
	for ch in text:
		for pressed in [true, false]:
			var k := InputEventKey.new()
			k.keycode = OS.find_keycode_from_string(ch.to_upper())
			k.unicode = ch.unicode_at(0)
			k.pressed = pressed
			get_root().push_input(k)
	await frames(2)


func undo_keeps_flags() -> void:
	open_vault("_undo", false)
	var x: ContentLayer = VaultStore.create_note("Undo Me")
	x.raw_text = "before"
	VaultStore.save_note(x, false)
	app = await boot()
	app._open_note(x)
	await frames(2)
	await click(app.star_btn)
	await click(app.pin_btn)
	var star: String = x.starred_at
	var pin: String = x.pinned_at
	check(star != "" and pin != "", "(setup: the open note is starred and pinned by clicks)")

	# ── The editor's Ctrl+Z ──
	var editor: TextEdit = app.raw_text_layer
	editor.grab_focus()
	editor.set_caret_line(editor.get_line_count() - 1)
	editor.set_caret_column(editor.get_line(editor.get_line_count() - 1).length())
	await type_text("abc")
	check(editor.text == "beforeabc" and not app._auto_save_timer.is_stopped(), "typing into the starred note starts an autosave (%s)" % editor.text)
	app._flush_pending_save()
	check(disk_note(x.resource_path).raw_text == "beforeabc", "(the typing is saved)")
	await press_shortcut(KEY_Z)
	check(editor.text == "before", "Ctrl+Z in the editor undoes the typing (%s)" % editor.text)
	check(x.starred_at == star and x.pinned_at == pin, "…and the note keeps its star and pin")
	check(app.star_btn.button_pressed and app.pin_btn.button_pressed, "…and the top bar still shows both on")
	app._flush_pending_save()
	var on_disk: ContentLayer = disk_note(x.resource_path)
	check(on_disk.raw_text == "before" and on_disk.starred_at == star and on_disk.pinned_at == pin,
		"the undone body is saved with the star and pin (%s | %s | %s)" % [on_disk.raw_text, on_disk.starred_at, on_disk.pinned_at])

	# ── The app's Ctrl+Z (undo_redo.gd) ──
	editor.release_focus()
	await frames(1)
	check(UndoRedoEngine.can_undo(), "(the saves left app undo history)")
	var depth: int = UndoRedoEngine.get_undo_depth()
	await press_shortcut(KEY_Z)
	check(UndoRedoEngine.get_undo_depth() == depth - 1, "Ctrl+Z outside the editor runs the app's undo")
	check(app.current_note == x and x.starred_at == star and x.pinned_at == pin, "…and the reopened note keeps its star and pin")
	check(app.star_btn.button_pressed and app.pin_btn.button_pressed, "…with both buttons still on")
	app._flush_pending_save()
	on_disk = disk_note(x.resource_path)
	check(on_disk.starred_at == star and on_disk.pinned_at == pin, "…and on disk")
	check(conflict_copies().is_empty(), "no conflict copy was needed")


# ── A star never drops words a save couldn't write ──────────────────────────
# The note's save failed (its folder went read-only, chmod 555: its file
# stays writable, but no new file can be renamed in) and another program
# then rewrote its file in place. The flush a star runs first can't write a
# conflict copy there either, so the words are only in the note and the
# editor. The top bar's star and another note's menu leave them there, and
# the save once the folder is writable keeps them as a conflict copy.

func unsaved_words_kept() -> void:
	var v: String = open_vault("_unsaved", false)
	VaultStore.create_folder("Shared")
	var n: ContentLayer = VaultStore.create_note("Field notes", "Shared")
	n.raw_text = "base"
	VaultStore.save_note(n, false)
	var other: ContentLayer = VaultStore.create_note("Other")
	var path: String = n.resource_path
	app = await boot()
	for i in range(2):
		var how: String = ["The top bar's star", "Star on another note's menu"][i]
		var para: String = "\nTHE USER'S PARAGRAPH %d" % (i + 1)
		app._open_note(n)
		await frames(2)
		OS.execute("chmod", ["555", v + "Shared"])
		app.raw_text_layer.text += para
		app.raw_text_layer.text_changed.emit()
		app._flush_pending_save()
		check(app._unsaved.has(n) and VaultStore._unsaved_paths.has(path), "(%s: the save fails, the words wait in the note)" % how)
		OS.delay_msec(1100)   # mtimes are per second: the outside edit must land in a new second
		var text: String = FileAccess.get_file_as_string(path)
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(text.replace("raw_text = \"", "raw_text = \"a line from the sync tool %d\n" % (i + 1)))
		f.close()
		var outside: String = FileAccess.get_file_as_string(path)
		if i == 0:
			app._toggle_star()
		else:
			app._open_note(other)
			await frames(2)
			app._toggle_flag_from_menu(n, &"starred_at")
		await frames(2)
		check(n.raw_text.ends_with(para) and n.starred_at == "", "%s keeps the unsaved words in the note (%s)" % [how, n.raw_text.c_escape()])
		check(app.current_note != n or app.raw_text_layer.text.ends_with(para), "…and in the editor")
		check(app.status_label.text.begins_with("Couldn't star “Field notes”"), "…and says it couldn't star it (%s)" % app.status_label.text)
		check(FileAccess.get_file_as_string(path) == outside, "…leaving the outside version on disk")
		OS.execute("chmod", ["755", v + "Shared"])
		app._flush_pending_save()
		await frames(2)
		var kept: Array = conflict_copies().filter(func(c: ContentLayer) -> bool:
			return c.raw_text.ends_with(para) and FileAccess.get_file_as_string(c.resource_path).contains(para.strip_edges()))
		check(kept.size() == 1 and not app._unsaved.has(n), "once the folder is writable the words are saved as a conflict copy (%d)" % kept.size())
		check(n.raw_text.begins_with("a line from the sync tool %d" % (i + 1)) and FileAccess.get_file_as_string(path) == outside,
			"…beside the outside version (%s)" % n.raw_text.c_escape())
