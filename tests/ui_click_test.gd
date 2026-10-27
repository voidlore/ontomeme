extends SceneTree
## UI click test: pushes real InputEventMouseButton events through the
## viewport, so GUI hit-testing / mouse_filter blocking is exercised.

var app: Control
var fails: int = 0

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1

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
	await process_frame
	await process_frame

func _init() -> void:
	JourneyStore.file_override = "user://test_journey_ui.json"   # never touch the real journey
	JourneyStore.reset()
	var vault := "user://ui-test-vault/"
	var abs := ProjectSettings.globalize_path(vault)
	OS.execute("rm", ["-rf", abs])
	DirAccess.make_dir_recursive_absolute(abs)
	await process_frame
	VaultStore.open_vault(abs, false)
	var a: ContentLayer = VaultStore.create_note("Alpha")
	a.raw_text = "# Alpha\n\nSee [[Beta]].\n\n- one\n- two\n"
	VaultStore.save_note(a)
	var b: ContentLayer = VaultStore.create_note("Beta")
	b.raw_text = "## Beta heading\nlinks to [[Alpha]]"
	VaultStore.save_note(b)
	check(DirAccess.get_files_at(abs).size() == 2, "re-saving notes does not create duplicate files (%d files)" % DirAccess.get_files_at(abs).size())

	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	for i in range(6):
		await process_frame

	var sidebar: Control = app.get_node("%Sidebar")
	var editor: Control = app.get_node("AppLayout/Body/Editor")
	check(sidebar.get_global_rect().end.x <= editor.get_global_rect().position.x + 1, "sidebar and editor do not overlap (%s | %s)" % [sidebar.get_global_rect(), editor.get_global_rect()])
	check(app.note_list_container.get_child_count() == 2, "sidebar lists 2 notes")
	check(app.current_note != null, "a note is open on launch")

	await click(app.get_node("%BtnGraph"))
	check(app.graph_layer.visible and not app.note_content.visible and app.current_mode == "graph", "click Graph -> graph view")
	await click(app.get_node("%BtnVisual"))
	check(app.visual_layer.visible and app.doc_scroll.visible and not app.graph_layer.visible, "click Read -> reading view")
	check(app.visual_layer.get_child_count() > 0, "reading view rendered content (%d rows)" % app.visual_layer.get_child_count())
	var link: RichTextLabel = null
	for c in app.visual_layer.get_children():
		if c is RichTextLabel:
			link = c
	check(link != null and link.text.contains("[url=Beta]"), "Read view renders [[Beta]] as a link")
	if link != null:
		link.meta_clicked.emit("Beta")
		await process_frame
	check(app.current_note != null and app.current_note.title == "Beta", "clicking a wikilink opens that note")
	await click(app.get_node("%BtnStructured"))
	check(app.structured_layer.visible and app.current_mode == "structured", "click Outline -> outline view")
	await click(app.get_node("%BtnRaw"))
	check(app.raw_text_layer.visible and not app.doc_scroll.visible and app.current_mode == "raw", "click Edit -> editor")
	check(app.get_node("%BtnRaw").button_pressed and not app.get_node("%BtnGraph").button_pressed, "segmented control shows Edit as active")

	var second: Button = app.note_list_container.get_child(1)
	var target_title: String = second.text
	await click(second)
	check(app.current_note != null and app._display_title(app.current_note) == target_title, "click sidebar note -> opens '%s'" % target_title)
	check(second.button_pressed, "clicked note row is highlighted")

	await click(app.get_node("%NewNoteButton"))
	check(VaultStore.note_list.size() == 3, "click + -> new note created")

	await click(app.get_node("%PaletteButton"))
	check(app._palette_visible and app._palette_overlay.visible, "click palette button -> palette opens")
	# click the backdrop corner (outside the panel) closes it
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = app._palette_overlay.get_global_rect().end - Vector2(12, 12)
	e.global_position = e.position
	get_root().push_input(e)
	await process_frame
	check(not app._palette_visible, "click backdrop -> palette closes")

	app._open_palette()
	app._palette_search.text = "graph"
	app._on_palette_search_changed("graph")
	await process_frame
	check(app._palette_items.size() >= 1, "palette filters to 'graph' (%d)" % app._palette_items.size())
	var key := InputEventKey.new()
	key.keycode = KEY_ENTER
	key.pressed = true
	get_root().push_input(key)
	await process_frame
	check(app.current_mode == "graph" and not app._palette_visible, "Enter in palette runs 'Graph view'")

	# Editing + autosave writes the same file
	await click(app.get_node("%BtnRaw"))
	app.raw_text_layer.text = "edited body"
	app.raw_text_layer.text_changed.emit()
	await create_timer(1.2).timeout
	check(app.current_note.raw_text == "edited body", "typing autosaves into the note")
	check(DirAccess.get_files_at(abs).size() == 3, "autosave rewrote the same file (%d files)" % DirAccess.get_files_at(abs).size())

	# 3D scenes: palette insert -> Read view shows a live NoteScene3D card
	app._execute_command("insert3d:knot")
	for i in range(3):
		await process_frame
	check(app.current_note.raw_text.contains("```3d\npreset: knot"), "palette 'Insert 3D scene' writes a ```3d block")
	check(app.current_mode == "visual", "inserting a 3D scene switches to Read view")
	var cards: Array = app.visual_layer.get_children().filter(func(c): return c is NoteScene3D)
	check(cards.size() == 1 and cards[0].preset == "knot", "Read view renders the block as a 3D card")
	check(cards.size() == 1 and cards[0]._viewport.own_world_3d and cards[0]._camera != null, "3D card has its own world + camera")
	if cards.size() == 1:
		var card: NoteScene3D = cards[0]
		var yaw0: float = card._yaw
		var pos: Vector2 = card._container.get_global_rect().get_center()
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = pos
		press.global_position = pos
		get_root().push_input(press)
		var drag := InputEventMouseMotion.new()
		drag.position = pos + Vector2(60, 0)
		drag.global_position = drag.position
		drag.relative = Vector2(60, 0)
		drag.button_mask = MOUSE_BUTTON_MASK_LEFT
		get_root().push_input(drag)
		var release := press.duplicate()
		release.pressed = false
		get_root().push_input(release)
		await process_frame
		check(not is_equal_approx(card._yaw, yaw0), "mouse drag on the card orbits the camera")
		card._on_expand_pressed()
		await process_frame
		check(app._scene_overlay != null, "Expand opens the full-window 3D overlay")
		var esc := InputEventKey.new()
		esc.keycode = KEY_ESCAPE
		esc.pressed = true
		get_root().push_input(esc)
		await process_frame
		check(app._scene_overlay == null, "Esc closes the 3D overlay")
	for preset in NoteScene3D.PRESETS:
		var c := NoteScene3D.new({"preset": preset}, 200.0)
		app.visual_layer.add_child(c)
		await process_frame
		check(c._content.get_child_count() > 0, "preset '%s' builds a scene" % preset)
		c.queue_free()
	app._switch_layer("raw")

	await click(app.get_node("%ThemeButton"))
	check(not app._is_dark_mode, "click theme button -> light mode")

	await click(app.get_node("%DeleteButton"))
	check(VaultStore.note_list.size() == 2, "click Delete -> note removed")

	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	OS.execute("rm", ["-rf", abs])
	quit(1 if fails else 0)
