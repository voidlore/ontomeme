extends SceneTree
## UI click test: pushes real InputEventMouseButton events through the
## viewport, so GUI hit-testing / mouse_filter blocking is exercised.

const UiScale = preload("res://ui_scale.gd")

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

## A note file written by another program (sync, git, Claude via MCP).
func outside_note(vault: String, title: String, modified: String) -> void:
	var note := ContentLayer.new()
	note.title = title
	note.raw_text = "Written elsewhere."
	note.created = modified
	note.modified = modified
	ResourceSaver.save(note, vault.path_join(title.to_lower() + ".tres"))


func note_titled(title: String) -> ContentLayer:
	var idx: int = VaultStore.get_note_index(title)
	return VaultStore.note_list[idx] if idx >= 0 else null


## A palette row and a graph node keep naming the note they showed after an
## outside edit re-sorts VaultStore.note_list under them, instead of whatever
## note then sits at the old index.
func stale_index_checks(vault: String) -> void:
	var alpha: ContentLayer = note_titled("Alpha")
	var beta: ContentLayer = note_titled("Beta")
	alpha.modified = "2026-01-01T10:00:00"   # a known order: Beta, then Alpha
	VaultStore.save_note(alpha, false)
	beta.modified = "2026-01-01T11:00:00"
	VaultStore.save_note(beta, false)
	app.check_disk_changes()
	app._open_note(note_titled("Alpha"))
	app._open_palette()
	app._palette_search.text = "Beta"
	app._on_palette_search_changed("Beta")
	await process_frame
	# The palette lists notes through the sidebar's search, title and body:
	# Alpha's body links to [[Beta]], so it is listed too, after the title hit.
	check(app._palette_items.size() >= 1 and str(app._palette_items[0].label).ends_with("Beta"),
		"palette filtered to 'Beta' shows Beta's row first (%s)" % [app._palette_items.map(func(i: Dictionary) -> String: return str(i.label))])
	var before: int = VaultStore.get_note_index("Beta")
	await create_timer(1.1).timeout   # mtime is per second
	outside_note(vault, "Cedar", "2026-02-01T09:00:00")
	app.check_disk_changes()
	await process_frame
	check(VaultStore.get_note_index("Beta") != before, "(Cedar, written outside, sorts first: Beta moved from index %d to %d)" % [before, VaultStore.get_note_index("Beta")])
	app._run_selected_palette_item()
	await process_frame
	check(app.current_note != null and app.current_note.title == "Beta", "Enter on the palette's Beta row still opens Beta (%s)" % (app.current_note.title if app.current_note else "none"))
	app._open_palette()
	app._on_palette_search_changed("Cedar")
	await process_frame
	DirAccess.remove_absolute(vault.path_join("cedar.tres"))   # deleted outside
	app.check_disk_changes()
	app._run_selected_palette_item()
	await process_frame
	check(app.current_note != null and app.current_note.title == "Beta" and note_titled("Cedar") == null, "a row whose file was deleted outside opens nothing (%s)" % (app.current_note.title if app.current_note else "none"))

	app._open_note(note_titled("Alpha"))
	app._build_graph_data()
	var key: String = note_titled("Beta").resource_path
	check(app._graph_nodes.has(key) and app._graph_nodes[key].title == "Beta", "the graph keys Beta's node by its file")
	before = VaultStore.get_note_index("Beta")
	await create_timer(1.1).timeout
	outside_note(vault, "Dogwood", "2026-03-01T09:00:00")
	app.check_disk_changes()
	app._build_graph_data()
	check(VaultStore.get_note_index("Beta") != before, "(Dogwood sorts first: Beta moved from index %d to %d)" % [before, VaultStore.get_note_index("Beta")])
	app._on_graph_node_clicked(key)
	await process_frame
	check(app.current_note != null and app.current_note.title == "Beta", "Beta's graph node still opens Beta (%s)" % (app.current_note.title if app.current_note else "none"))


func _init() -> void:
	preload("res://tests/test_vault.gd").hold()   # before any await, or the autoload opens the real vault
	JourneyStore.file_override = "user://test_journey_ui.json"   # never touch the real journey
	JourneyStore.reset()
	UiScale.file_override = "user://test_display_ui.json"   # the theme click must not change the real setting
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UiScale.file_override))
	var vault := "user://ui-test-vault/"
	var abs := ProjectSettings.globalize_path(vault)
	preload("res://tests/test_vault.gd").remove_tree(abs)   # in-process, not rm: the test needs nothing on PATH
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
	var link: RichTextLabel = null   # the body's "See [[Beta]]." (a LINKED FROM row follows it)
	for c in app.visual_layer.get_children():
		if c is RichTextLabel and link == null:
			link = c
	check(link != null and LayerEngine.link_targets(link) == ["Beta"] and link.text.contains("[url=0]"), "Read view renders [[Beta]] as a link")
	if link != null:
		link.meta_clicked.emit("0")   # the url meta is the link's index in the row
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
	await test_connect_claude(abs)

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

	await stale_index_checks(abs)

	DirAccess.remove_absolute(ProjectSettings.globalize_path(UiScale.file_override))
	UiScale.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	preload("res://tests/test_vault.gd").remove_tree(abs)
	quit(1 if fails else 0)


# ── Palette → "Connect Claude Desktop…" ─────────────────────────────────────

## Type in the palette, click the row, read the dialog, click Copy and Close:
## every step a real input event.
func test_connect_claude(vault: String) -> void:
	const DesktopConfig = preload("res://mcp/desktop_config.gd")
	await click(app.get_node("%PaletteButton"))
	await type_text("claude desktop")
	check(app._palette_items.size() == 1 and app._palette_items[0].action == "connect_claude", "typing 'claude desktop' leaves one palette row: Connect Claude Desktop…")
	var list: ItemList = app._palette_list
	await click_at(list.get_global_transform() * list.get_item_rect(0).get_center())
	await process_frame
	var dlg: AcceptDialog = app.get_node_or_null(DesktopConfig.DIALOG_NAME)
	check(not app._palette_visible and dlg != null and dlg.visible, "clicking the row closes the palette and opens the Connect Claude Desktop dialog")
	if dlg == null:
		return
	var want: String = DesktopConfig.for_this_app(VaultStore.vault_path)
	check(dialog_text(dlg).contains(want), "the dialog shows the config snippet for this install")
	var entry: Dictionary = JSON.parse_string(want).mcpServers.ontomeme
	check(entry.command == OS.get_executable_path() and ("--vault=" + vault.trim_suffix("/")) in entry.args, "…which starts this executable on the open vault (%s)" % [entry.args])
	var content: Control = dlg.get_node("Content")
	check(content.get_combined_minimum_size().x <= 820 and dlg.get_contents_minimum_size().x <= 820 and Rect2(Vector2(), Vector2(get_root().size)).encloses(Rect2(dlg.position, dlg.size)),
			"the dialog fits the 820x520 window (content %d wide, dialog %s at %s)" % [content.get_combined_minimum_size().x, dlg.size, dlg.position])
	var copy: Button = null
	for b in dlg.get_ok_button().get_parent().get_children():
		if b is Button and b.text == "Copy":
			copy = b
	check(copy != null, "the dialog has a Copy button")
	if copy != null:
		await click_at(Vector2(dlg.position) + copy.get_global_rect().get_center())
		check(copy.text == "Copied", "clicking Copy copies the snippet (the button says Copied)")
	await click_at(Vector2(dlg.position) + dlg.get_ok_button().get_global_rect().get_center())
	await process_frame
	check(not is_instance_valid(dlg), "Close closes and frees the dialog")


func click_at(pos: Vector2) -> void:
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


## Key presses with their characters, into whatever has focus.
func type_text(text: String) -> void:
	for i in text.length():
		for pressed in [true, false]:
			var k := InputEventKey.new()
			k.unicode = text.unicode_at(i)
			k.keycode = OS.find_keycode_from_string(text[i].to_upper()) if text[i] != " " else KEY_SPACE
			k.pressed = pressed
			get_root().push_input(k)
	await process_frame


## Every text the dialog shows: its own text, labels and text boxes.
func dialog_text(dlg: AcceptDialog) -> String:
	var out: String = dlg.dialog_text
	for n in dlg.find_children("*", "", true, false):
		if n is Label or n is TextEdit:
			out += "\n" + n.text
	return out
