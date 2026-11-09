extends SceneTree
## Outline jump: in Outline (Ctrl+2) a real mouse click on a heading row opens
## Edit with the caret on that heading's line, centred; Shift+click opens
## Read scrolled so the heading is on screen. A press that slides off the
## row before release does nothing, like a button.
##   headless:  godot --headless --path . -s res://tests/outline_test.gd
##   + images:  godot --path . -s res://tests/outline_test.gd -- <out_dir>

const TestVault = preload("res://tests/test_vault.gd")
const NOTE: String = "Tutorial 5: Making a Quiz"

var fails: int = 0
var out: String = ""
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


func push_mouse(pos: Vector2, pressed: bool, shift: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.shift_pressed = shift
	e.position = pos
	e.global_position = pos
	get_root().push_input(e)


func move_mouse(pos: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)


## A real click on `c`: scroll it into view, move there, press, release.
func click(c: Control, shift: bool = false) -> void:
	app.doc_scroll.ensure_control_visible(c)
	await frames(2)
	var pos: Vector2 = c.get_global_rect().get_center()
	move_mouse(pos)
	await process_frame
	push_mouse(pos, true, shift)
	push_mouse(pos, false, shift)
	await frames(4)


## Each heading's source line, from the note's own text: # lines outside
## ``` fences (a fence closes on as many backticks or more).
func heading_lines(text: String) -> Array[int]:
	var found: Array[int] = []
	var fence: int = 0
	var lines: PackedStringArray = text.split("\n")
	for i in range(lines.size()):
		var s: String = lines[i].strip_edges()
		var ticks: int = 0
		while ticks < s.length() and s[ticks] == "`":
			ticks += 1
		if ticks >= 3:
			if fence == 0:
				fence = ticks
			elif ticks >= fence and s.substr(ticks).strip_edges() == "":
				fence = 0
			continue
		if fence == 0 and RegEx.create_from_string("^#{1,6} ").search(lines[i]) != null:
			found.append(i)
	return found


## Outline's heading rows, top to bottom.
func outline_rows() -> Array:
	var rows: Array = []
	for c in app.structured_layer.find_children("*", "Label", true, false):
		if c.has_meta("source_line"):
			rows.append(c)
	return rows


func show_outline() -> void:
	app._switch_layer("structured")
	await frames(3)
	app.doc_scroll.scroll_vertical = 0
	await frames(2)


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	if out != "":
		DisplayServer.window_set_size(Vector2i(1280, 820))
	JourneyStore.file_override = "user://test_journey_outline.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_outline.json"   # never touch real progress
	ProgressStore.reset()
	TestVault.open("outline")   # tutorials + course, never the user's vault

	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.open_note_by_title(NOTE)
	await frames(2)
	check(app.current_note != null and app.current_note.title == NOTE, "the tutorial note is open")
	if app.current_note == null:
		quit(1)
		return
	var text: String = app.current_note.raw_text
	var want: Array[int] = heading_lines(text)
	await show_outline()
	var rows: Array = outline_rows()
	check(rows.size() == want.size() and want.size() >= 4, "Outline shows one clickable row per heading (%d rows, %d headings)" % [rows.size(), want.size()])
	if rows.size() < 4 or rows.size() != want.size():
		quit(1)
		return
	check((rows[2] as Label).mouse_filter == Control.MOUSE_FILTER_STOP
		and (rows[2] as Label).mouse_default_cursor_shape == Control.CURSOR_POINTING_HAND, "heading rows take the mouse with a pointing-hand cursor")
	check((rows[2] as Label).theme_type_variation in [&"H2Label", &"H3Label", &"BodyLabel"], "heading rows keep their Outline look")
	await shot("outline_rows")

	# Click the 3rd heading: Edit, caret on its line, centred
	var third: Label = rows[2]
	var line: int = want[2]
	check(text.split("\n")[line].ends_with(third.text), "the 3rd row is the 3rd heading, line %d: %s" % [line, third.text])
	await click(third)
	check(app.current_mode == "raw" and app.raw_text_layer.visible, "a click on the 3rd heading opens Edit (%s)" % app.current_mode)
	check(app.raw_text_layer.get_caret_line() == line and app.raw_text_layer.get_caret_column() == 0,
		"the caret is at the start of that heading's line in raw_text (%d, want %d)" % [app.raw_text_layer.get_caret_line(), line])
	check(app.raw_text_layer.has_focus(), "the editor has the keyboard focus")
	await frames(2)
	var first: int = app.raw_text_layer.get_first_visible_line()
	var last: int = app.raw_text_layer.get_last_full_visible_line()
	check(line >= first and line <= last, "the heading's line is on screen in the editor (lines %d..%d)" % [first, last])
	await shot("outline_jump_edit")

	# The last heading is far down: its line is centred, not at the edge
	await show_outline()
	rows = outline_rows()
	await click(rows[rows.size() - 1])
	await frames(2)
	var end_line: int = want[want.size() - 1]
	first = app.raw_text_layer.get_first_visible_line()
	last = app.raw_text_layer.get_last_full_visible_line()
	check(app.raw_text_layer.get_caret_line() == end_line and end_line >= first and end_line <= last,
		"the last heading's line %d is the caret line and on screen (lines %d..%d)" % [end_line, first, last])

	# Shift+click: Read view, scrolled to the heading
	for pick in [2, rows.size() - 1]:
		await show_outline()
		rows = outline_rows()
		var row: Label = rows[pick]
		var heading: String = row.text   # switching views rebuilds Outline, freeing the row
		await click(row, true)
		await frames(3)
		check(app.current_mode == "visual" and app.visual_layer.visible, "Shift+click on heading %d opens Read (%s)" % [pick + 1, app.current_mode])
		var label: Control = LayerEngine.visual_row_for_line(want[pick])
		check(label is Label and (label as Label).text == heading, "Read view has the heading '%s' for line %d" % [heading, want[pick]])
		if label != null:
			var view: Rect2 = app.doc_scroll.get_global_rect()
			check(view.encloses(label.get_global_rect()), "the heading label is inside DocScroll's visible rect (%s in %s, scroll %d)"
				% [label.get_global_rect(), view, app.doc_scroll.scroll_vertical])
		await shot("outline_jump_read_%d" % (pick + 1))
	check(app.doc_scroll.scroll_vertical > 0, "reaching the last heading scrolled Read view down")

	# A press that slides off the row before release does nothing
	await show_outline()
	rows = outline_rows()
	var start: Vector2 = (rows[1] as Control).get_global_rect().get_center()
	move_mouse(start)
	await process_frame
	push_mouse(start, true, false)
	move_mouse(start + Vector2(0, 400))
	push_mouse(start + Vector2(0, 400), false, false)
	await frames(3)
	check(app.current_mode == "structured", "pressing a row and releasing elsewhere stays in Outline (%s)" % app.current_mode)

	print("\nRESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(0 if fails == 0 else 1)
