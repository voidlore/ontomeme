extends SceneTree
## The full-window image viewer and an image's right-click menu in Read view.
## A real click on an image opens a dim overlay showing the same texture,
## fitted to the window but never enlarged past 2x, with its caption; Esc, a
## backdrop click or Close shuts it. A right click offers View image, Show in
## file manager and Remove from note. Remove from note deletes the ref line
## through the editor and saves; the file stays while another note names it
## anywhere (a list item, a paragraph), and goes to the trash when no note
## does. Ctrl+Z in Read view puts the
## line back; in Outline it steps the same history, but in Graph and Journey,
## where the note isn't on screen, Ctrl+Z and Ctrl+Shift+Z leave it alone.
##   headless:  godot --headless --path . -s res://tests/image_viewer_test.gd
##   + images:  godot --path . -s res://tests/image_viewer_test.gd -- <out_dir>

const TestVault = preload("res://tests/test_vault.gd")
const NoteScript = preload("res://note.gd")

const NOTE_A: String = """# Gallery

Intro text.

![Red dot](images/red.png)

Between the pictures.

![Blue bar](images/blue.png)

The end."""
const NOTE_B: String = "# Also red\n\n![Red again](red.png)\n"   # a bare name: the same file

var fails: int = 0
var out: String = ""
var V: String = ""
var app: Control


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func shot(name: String) -> void:
	if out == "" or DisplayServer.get_name() == "headless":
		return
	await create_timer(0.8).timeout
	get_root().get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("saved ", out.path_join(name + ".png"))


func save_image(path: String, w: int, h: int, colour: Color) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(colour)
	img.save_png(path)


func find_all(root: Node, type: String) -> Array:
	var found: Array = []
	for c in root.get_children():
		if c.is_class(type):
			found.append(c)
		found.append_array(find_all(c, type))
	return found


## The Read-view image whose ref targets `target`, or null.
func image_rect(target: String) -> TextureRect:
	for r in find_all(LayerEngine._visual_vbox, "TextureRect"):
		if r.has_meta("image_ref") and str(r.get_meta("image_ref").target) == target:
			return r
	return null


func move_mouse(pos: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)


func push_button(pos: Vector2, button: MouseButton, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	get_root().push_input(e)


## A real click at `pos`: move there, press, release.
func click_at(pos: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	move_mouse(pos)
	await process_frame
	push_button(pos, button, true)
	push_button(pos, button, false)
	await frames(3)


## A real click on a Read-view control, scrolled into view first.
func click(c: Control, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	app.doc_scroll.ensure_control_visible(c)
	await frames(2)
	await click_at(c.get_global_rect().get_center(), button)


func press_key(key: Key, ctrl: bool = false, shift: bool = false) -> void:
	var e := InputEventKey.new()
	e.keycode = key
	e.ctrl_pressed = ctrl
	e.shift_pressed = shift
	e.pressed = true
	get_root().push_input(e)
	var up: InputEventKey = e.duplicate()
	up.pressed = false
	get_root().push_input(up)
	await frames(3)


func on_disk(note: ContentLayer) -> String:
	return FileAccess.get_file_as_string(note.resource_path)


func note_named(title: String) -> ContentLayer:
	var i: int = VaultStore.get_note_index(title)
	return VaultStore.note_list[i] if i >= 0 else null


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	if out != "":
		DisplayServer.window_set_size(Vector2i(1280, 860))
	ProgressStore.file_override = "user://test_progress_image_viewer.json"   # never touch real progress
	ProgressStore.reset()
	JourneyStore.file_override = "user://test_journey_image_viewer.json"     # never touch the real journey
	JourneyStore.reset()
	V = TestVault.open("image_viewer", false)
	save_image(V.path_join("images/red.png"), 40, 20, Color.RED)
	save_image(V.path_join("images/blue.png"), 2400, 300, Color.BLUE)
	for pair in [["Gallery", NOTE_A], ["Also red", NOTE_B]]:
		var n: ContentLayer = VaultStore.create_note(pair[0])
		n.raw_text = pair[1]
		VaultStore.save_note(n)
	VaultStore.refresh_note_list()

	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.open_note_by_title("Gallery")
	await frames(2)
	app._switch_layer("visual")
	await frames(4)

	check_fit_rule()
	await check_click_opens_viewer()
	await check_closing()
	await check_menu()
	await check_remove_shared()
	await check_remove_last_and_undo()
	await check_undo_only_where_shown()
	await check_remove_keeps_inline_users()

	print("\nRESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(0 if fails == 0 else 1)


func check_fit_rule() -> void:
	check(NoteScript.fit_image(Vector2(40, 20), Vector2(700, 400)) == Vector2(80, 40), "a small image is enlarged at most 2x (40x20 -> 80x40)")
	check(NoteScript.fit_image(Vector2(2400, 300), Vector2(700, 400)) == Vector2(700, 87), "a wide image shrinks to the room's width, aspect kept")
	check(NoteScript.fit_image(Vector2(300, 2400), Vector2(700, 400)) == Vector2(50, 400), "a tall image shrinks to the room's height, aspect kept")
	check(NoteScript.fit_image(Vector2(500, 200), Vector2(700, 400)) == Vector2(700, 280), "a mid-size image grows to fill the room, under 2x")


func check_click_opens_viewer() -> void:
	var red: TextureRect = image_rect("images/red.png")
	check(red != null and red.mouse_filter == Control.MOUSE_FILTER_STOP and red.mouse_default_cursor_shape == Control.CURSOR_POINTING_HAND,
		"a Read-view image takes the mouse with a pointing-hand cursor")
	if red == null:
		return
	await click(red)
	var overlay: ColorRect = app._image_overlay
	check(overlay != null and overlay.is_inside_tree() and overlay.visible, "a click on the image opens the full-window viewer")
	if overlay == null:
		return
	check(overlay.size == app.size, "the viewer covers the whole window (%s vs %s)" % [overlay.size, app.size])
	var pic: TextureRect = overlay.find_child("ViewerImage", true, false)
	check(pic != null and pic.texture == red.texture, "the viewer's TextureRect shows the same texture")
	check(pic != null and pic.custom_minimum_size == Vector2(80, 40), "a 40x20 image shows at most 2x: 80x40 (%s)" % [pic.custom_minimum_size if pic != null else Vector2.ZERO])
	var caption: Label = overlay.find_child("ViewerCaption", true, false)
	check(caption != null and caption.text == "Red dot", "the viewer shows the alt text as its caption")
	await frames(2)
	var whole: float = caption.get_theme_font("font").get_string_size(caption.text, HORIZONTAL_ALIGNMENT_LEFT, -1, caption.get_theme_font_size("font_size")).x
	check(caption.size.x >= whole, "a small picture's caption still shows whole (%.0f px for %.0f)" % [caption.size.x, whole])
	var inner: Rect2 = (pic.get_parent().get_parent().get_parent() as Control).get_global_rect().grow(-float(app.IMAGE_VIEWER_PAD) + 0.5)
	check(inner.encloses(pic.get_global_rect()), "the picture sits inside the panel's padding")
	await shot("viewer_small")
	await click_at(pic.get_global_rect().get_center())
	check(app._image_overlay != null, "a click on the picture itself leaves the viewer open")


func check_closing() -> void:
	await press_key(KEY_ESCAPE)
	check(app._image_overlay == null, "Esc closes the viewer")

	var blue: TextureRect = image_rect("images/blue.png")
	await click(blue)
	var overlay: ColorRect = app._image_overlay
	check(overlay != null, "the wide image opens too")
	if overlay == null:
		return
	var pic: TextureRect = overlay.find_child("ViewerImage", true, false)
	await frames(2)
	var panel_rect: Rect2 = (pic.get_parent().get_parent() as Control).get_global_rect()
	check(Rect2(Vector2.ZERO, overlay.size).encloses(panel_rect) and pic.custom_minimum_size.x < 2400.0,
		"a 2400 px image is shrunk so the viewer fits the window (%s in %s)" % [panel_rect, overlay.size])
	check(is_equal_approx(pic.custom_minimum_size.x / pic.custom_minimum_size.y, 8.0) or absf(pic.custom_minimum_size.x / pic.custom_minimum_size.y - 8.0) < 0.2,
		"and keeps its 8:1 aspect (%s)" % [pic.custom_minimum_size])
	await shot("viewer_wide")
	await click_at(Vector2(8, 8))
	check(app._image_overlay == null, "a click on the dim backdrop closes the viewer")

	await click(blue)
	var close: Button = app._image_overlay.find_child("ViewerClose", true, false) if app._image_overlay != null else null
	check(close != null, "the viewer has a Close button")
	if close != null:
		await click_at(close.get_global_rect().get_center())
	check(app._image_overlay == null, "Close closes the viewer")


func check_menu() -> void:
	var red: TextureRect = image_rect("images/red.png")
	await click(red, MOUSE_BUTTON_RIGHT)
	var menu: PopupMenu = app._image_menu
	check(menu != null and menu.visible, "a right click on an image opens its menu")
	if menu == null:
		return
	var items: Array = []
	for i in range(menu.item_count):
		if not menu.is_item_separator(i):
			items.append(menu.get_item_text(i))
	check(items == ["View image", "Show in file manager", "Remove from note"], "the menu offers View image, Show in file manager, Remove from note (%s)" % [items])
	check(app._image_overlay == null, "a right click doesn't open the viewer")
	menu.id_pressed.emit(app.IMAGE_VIEW)
	menu.hide()
	await frames(2)
	var pic: TextureRect = app._image_overlay.find_child("ViewerImage", true, false) if app._image_overlay != null else null
	check(pic != null and pic.texture == red.texture, "View image opens the viewer on that image")
	app.close_image_viewer()
	await frames(2)


func check_remove_shared() -> void:
	var a: ContentLayer = app.current_note
	await click(image_rect("images/red.png"), MOUSE_BUTTON_RIGHT)
	app._image_menu.id_pressed.emit(app.IMAGE_REMOVE)
	app._image_menu.hide()
	await frames(3)
	check(not a.raw_text.contains("red.png"), "Remove from note takes the ref out of note A")
	check(not on_disk(a).contains("red.png"), "and saves note A")
	check(not a.raw_text.contains("\n\n\n"), "without leaving two blank lines in a row (%s)" % JSON.stringify(a.raw_text))
	check(FileAccess.file_exists(V.path_join("images/red.png")), "note B still shows red.png, so the file stays in images/")
	check(app.status_label.text.contains("still used by 1 note"), "the status says the file is still used (%s)" % app.status_label.text)
	check(image_rect("images/red.png") == null and image_rect("images/blue.png") != null, "Read view no longer shows the removed image")
	check(note_named("Also red").raw_text == NOTE_B, "note B is untouched")


func check_remove_last_and_undo() -> void:
	var a: ContentLayer = app.current_note
	var before: String = a.raw_text
	await click(image_rect("images/blue.png"), MOUSE_BUTTON_RIGHT)
	app._image_menu.id_pressed.emit(app.IMAGE_REMOVE)
	app._image_menu.hide()
	await frames(3)
	check(not a.raw_text.contains("blue.png") and not on_disk(a).contains("blue.png"), "Remove from note takes out the only ref to blue.png and saves")
	check(not FileAccess.file_exists(V.path_join("images/blue.png")), "no note shows blue.png any more, so it leaves images/ (moved to the trash)")
	check(app.status_label.text.contains("trash"), "the status says it went to the trash (%s)" % app.status_label.text)
	check(app.current_mode == "visual", "Read view stays open")

	await press_key(KEY_Z, true)
	check(a.raw_text == before, "Ctrl+Z in Read view puts the line back (%s)" % JSON.stringify(a.raw_text))
	check(on_disk(a).contains("![Blue bar](images/blue.png)"), "and saves it")
	var shown: bool = false
	for l in find_all(LayerEngine._visual_vbox, "Label"):
		if (l as Label).text == "Image not found: images/blue.png":
			shown = true
	check(shown, "Read view shows the ref again (its file is in the trash: Image not found)")
	await press_key(KEY_Z, true)
	check(a.raw_text == NOTE_A, "a second Ctrl+Z puts back the red image removed before it")
	check(image_rect("images/red.png") != null, "and Read view shows it again")


## Ctrl+Z and Ctrl+Shift+Z step the editor's history only where the note's
## text is on screen (Read, Outline). In Graph and Journey a real key press
## must leave the note's text and its file alone: it once reverted the last
## edit unseen and saved it.
func check_undo_only_where_shown() -> void:
	var a: ContentLayer = app.current_note
	await press_key(KEY_Z, true, true)
	check(not a.raw_text.contains("red.png") and not on_disk(a).contains("red.png"), "Ctrl+Shift+Z in Read view redoes Remove from note and saves")
	app._switch_layer("structured")
	await frames(3)
	app.get_viewport().gui_release_focus()
	await press_key(KEY_Z, true)
	check(a.raw_text == NOTE_A and on_disk(a).contains("![Red dot](images/red.png)"), "Ctrl+Z in Outline undoes it too, and saves")
	for mode in ["graph", "journey"]:
		app._switch_layer("raw")
		await frames(2)
		var te: TextEdit = app.raw_text_layer
		te.set_caret_line(te.get_line_count() - 1)
		te.set_caret_column(te.get_line(te.get_line_count() - 1).length())
		te.insert_text_at_caret(" Typed before %s." % mode)
		app._on_save_note_pressed()
		var text: String = a.raw_text
		var disk: String = on_disk(a)
		check(text.ends_with(" Typed before %s." % mode) and te.has_undo(), "an edit typed in Edit is saved, with undo history")
		app._switch_layer(mode)
		await frames(3)
		app.get_viewport().gui_release_focus()
		await press_key(KEY_Z, true)
		check(a.raw_text == text and on_disk(a) == disk, "Ctrl+Z in %s leaves the note's text and file alone (%s)" % [mode, JSON.stringify(a.raw_text.right(30))])
		await press_key(KEY_Z, true, true)
		check(a.raw_text == text and on_disk(a) == disk, "and so does Ctrl+Shift+Z")


## The file stays while another note uses it anywhere, not only on an image
## line of its own: a list item's image and one inside a paragraph once
## counted as no use at all, so Remove from note trashed the file under them.
func check_remove_keeps_inline_users() -> void:
	save_image(V.path_join("images/green.png"), 30, 30, Color.GREEN)
	const PICS: String = "# Pics\n\n![Green](images/green.png)\n\nEnd."
	const LISTY: String = "# Listy\n\n- ![Green in a list](images/green.png)\n"
	const PROSE: String = "# Prose\n\nA small ![green](green.png) square in a sentence.\n"
	for pair in [["Pics", PICS], ["Listy", LISTY], ["Prose", PROSE]]:
		var n: ContentLayer = VaultStore.create_note(pair[0])
		n.raw_text = pair[1]
		VaultStore.save_note(n)
	app._flush_pending_save()
	VaultStore.refresh_note_list()
	app._refresh_note_list()
	app.open_note_by_title("Pics")
	app._switch_layer("visual")
	await frames(4)
	var pics: ContentLayer = app.current_note
	await click(image_rect("images/green.png"), MOUSE_BUTTON_RIGHT)
	app._image_menu.id_pressed.emit(app.IMAGE_REMOVE)
	app._image_menu.hide()
	await frames(3)
	check(pics.title == "Pics" and not pics.raw_text.contains("green.png") and not on_disk(pics).contains("green.png"),
		"Remove from note takes the only standalone ref to green.png out of Pics and saves")
	check(FileAccess.file_exists(V.path_join("images/green.png")),
		"Listy (a list item) and Prose (mid-sentence) still use green.png, so the file stays in images/")
	check(app.status_label.text.contains("still used by 2 notes"), "the status counts both (%s)" % app.status_label.text)
	check(note_named("Listy").raw_text == LISTY and note_named("Prose").raw_text == PROSE, "and leaves their text alone")
