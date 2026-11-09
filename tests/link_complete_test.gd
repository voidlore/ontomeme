extends SceneTree
## [[ link autocomplete in Edit view: typing "[[" and part of a title shows
## matching note titles under the caret; Up/Down pick one, Enter or Tab (or
## a click) writes "Title]]", Esc closes the list without inserting, typing
## "]" or leaving the line closes it, and Enter works as usual while the
## list is hidden.
##   headless:  godot --headless --path . -s res://tests/link_complete_test.gd

const TestVault = preload("res://tests/test_vault.gd")

var fails: int = 0
var app: Control
var editor: TextEdit


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func popup() -> Control:
	return app.find_child("LinkComplete", true, false)


func popup_list() -> ItemList:
	return app.find_child("LinkCompleteList", true, false)


func popup_open() -> bool:
	var p: Control = popup()
	return p != null and p.visible


func items() -> Array[String]:
	var out: Array[String] = []
	var list: ItemList = popup_list()
	if list != null:
		for i in range(list.item_count):
			out.append(list.get_item_text(i))
	return out


## Type characters into the focused editor as real key presses.
func type_text(s: String) -> void:
	for ch in s:
		var code: int = ch.unicode_at(0)
		var e := InputEventKey.new()
		e.pressed = true
		e.unicode = code
		e.shift_pressed = ch != ch.to_lower()
		if ch.to_lower() >= "a" and ch.to_lower() <= "z":
			e.keycode = KEY_A + (ch.to_lower().unicode_at(0) - "a".unicode_at(0)) as Key
		elif ch == " ":
			e.keycode = KEY_SPACE
		elif ch == "[":
			e.keycode = KEY_BRACKETLEFT
		elif ch == "]":
			e.keycode = KEY_BRACKETRIGHT
		get_root().push_input(e)
		await process_frame
	await frames(2)


func key(code: Key) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.pressed = pressed
		get_root().push_input(e)
	await frames(2)


func click(ctrl_rect: Rect2) -> void:
	var pos: Vector2 = ctrl_rect.get_center()
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


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_linkcomplete.json"
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_linkcomplete.json"
	ProgressStore.reset()
	TestVault.open("linkcomplete")

	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app._on_new_note_pressed()
	await frames(2)
	editor = app.raw_text_layer
	editor.grab_focus()
	await frames(1)
	check(editor.has_focus() and app.current_mode == "raw", "a new note is open in Edit view with the editor focused")

	# ── "See [[Tut" lists the tutorials ──
	await type_text("See [[Tut")
	check(editor.text == "See [[Tut", "the keys typed 'See [[Tut' (%s)" % editor.text)
	check(popup_open(), "typing [[Tut shows the link suggestions")
	var titles: Array[String] = items()
	check(titles.size() >= 2 and titles.size() <= 8, "it lists between 2 and 8 titles (%d)" % titles.size())
	check(titles.size() > 0 and titles[0].begins_with("Tutorial"), "the first suggestion starts with 'Tutorial' (%s)" % [titles])
	var prefix_done: bool = false
	var order_ok: bool = true
	for t in titles:
		var is_prefix: bool = t.to_lower().begins_with("tut")
		if not is_prefix:
			prefix_done = true
		elif prefix_done:
			order_ok = false
		order_ok = order_ok and t.to_lower().contains("tut")
	check(order_ok, "prefix matches come first, then titles containing 'tut' (%s)" % [titles])
	check(editor.has_focus(), "the list doesn't take the focus from the editor")
	var vp: Rect2 = app.get_viewport_rect()
	check(popup().get_global_rect().end.x <= vp.end.x + 0.5 and popup().get_global_rect().position.x >= 0, "the list sits inside the window (%s in %s)" % [popup().get_global_rect(), vp])
	var layout: Control = app.get_node("AppLayout")
	check(layout.get_combined_minimum_size().x <= 820, "the headless 820px window still fits (%d px)" % int(layout.get_combined_minimum_size().x))

	# ── Down, then Enter, takes the second title ──
	var second: String = titles[1] if titles.size() > 1 else "?"
	await key(KEY_DOWN)
	check(popup_list().get_selected_items() == PackedInt32Array([1]), "Down highlights the second title")
	check(editor.get_caret_line() == 0, "Down moved the highlight, not the caret")
	await key(KEY_ENTER)
	check(editor.text == "See [[" + second + "]]", "Enter writes the second title and closes the link (%s)" % editor.text)
	check(not popup_open(), "the list is hidden after Enter")
	check(editor.get_caret_column() == editor.get_line(0).length(), "the caret sits after the ]]")

	# ── Esc closes without inserting; then Enter is a plain newline ──
	await type_text(" and [[Tut")
	check(popup_open(), "a new [[Tut shows the list again")
	await key(KEY_ESCAPE)
	check(not popup_open(), "Esc hides the list")
	check(editor.text == "See [[" + second + "]] and [[Tut", "Esc leaves the text as typed (%s)" % editor.text)
	await key(KEY_ENTER)
	check(editor.get_line_count() == 2 and editor.get_line(0).ends_with("[[Tut") and editor.get_line(1) == "", "a later Enter inserts a newline as usual (%s)" % editor.text.c_escape())
	check(not popup_open(), "…and the list stays hidden")

	# ── Typing ] closes it ──
	await type_text("[[Tu")
	check(popup_open(), "[[Tu on the new line shows the list")
	await type_text("]")
	check(not popup_open() and editor.get_line(1) == "[[Tu]", "typing ] closes it and is typed (%s)" % editor.get_line(1))

	# ── Leaving the line closes it ──
	await key(KEY_ENTER)
	await type_text("[[Tu")
	check(popup_open(), "[[Tu shows the list")
	editor.set_caret_line(0)
	await frames(2)
	check(not popup_open(), "moving the caret off the line closes it")

	# ── Tab takes the highlighted (first) title ──
	editor.set_caret_line(2)
	editor.set_caret_column(editor.get_line(2).length())
	await frames(1)
	await type_text("t")
	check(popup_open(), "typing on resumes the list")
	var first: String = items()[0] if items().size() > 0 else "?"
	await key(KEY_TAB)
	check(editor.get_line(2) == "[[" + first + "]]" and not popup_open(), "Tab writes the first title (%s)" % editor.get_line(2))

	# ── A click on a suggestion takes it ──
	await key(KEY_ENTER)
	await type_text("[[Start")
	check(popup_open() and items().size() > 0 and items()[0].begins_with("Start"), "[[Start lists 'Start Here…' (%s)" % [items()])
	var pick: String = items()[0] if items().size() > 0 else "?"
	var row: Rect2 = popup_list().get_item_rect(0)
	row.position += popup_list().get_global_rect().position
	await click(row)
	check(editor.get_line(3) == "[[" + pick + "]]" and not popup_open(), "clicking a suggestion writes it (%s)" % editor.get_line(3))
	check(editor.has_focus(), "the editor keeps the focus after the click")

	# ── No match, no list; Enter while hidden is never swallowed ──
	await key(KEY_ENTER)
	await type_text("[[zzqqxx")
	check(not popup_open(), "a partial title nothing matches shows no list")
	var lines: int = editor.get_line_count()
	await key(KEY_ENTER)
	check(editor.get_line_count() == lines + 1, "Enter inserts a newline")

	# ── Opening another note closes it ──
	await type_text("[[Tut")
	check(popup_open(), "the list shows again")
	app.open_note_by_title("Tutorial 1: Writing Notes")
	await frames(2)
	check(not popup_open(), "opening another note closes the list")

	app.queue_free()
	await frames(2)
	for p in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
