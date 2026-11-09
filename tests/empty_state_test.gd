extends SceneTree
## The sidebar explains itself when it has nothing to list: an empty vault
## offers a new note, a search nothing matches offers to create that note or
## clear the search, and a tag no note carries offers to clear the filter.
##   headless:  godot --headless --path . -s res://tests/empty_state_test.gd

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


## The hint block, if the sidebar shows one (a freed one doesn't count).
func block() -> Control:
	for c in app.note_list_container.get_children():
		if c.name == "SidebarEmpty" and not c.is_queued_for_deletion():
			return c
	return null


func block_text() -> String:
	var b: Control = block()
	if b == null:
		return ""
	var parts: PackedStringArray = []
	for l in b.find_children("*", "Label", true, false):
		parts.append((l as Label).text)
	return " | ".join(parts)


func block_button(starts: String) -> Button:
	var b: Control = block()
	if b == null:
		return null
	for btn in b.find_children("*", "Button", true, false):
		if (btn as Button).text.begins_with(starts):
			return btn
	return null


func click(ctrl: Control) -> void:
	var scroll: ScrollContainer = app.note_list_container.get_parent()
	scroll.ensure_control_visible(ctrl)
	await frames(1)
	var pos: Vector2 = ctrl.get_global_rect().get_center()
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
	await frames(3)


## Type into the focused field as real key presses.
func type_text(s: String) -> void:
	for ch in s:
		var e := InputEventKey.new()
		e.pressed = true
		e.unicode = ch.unicode_at(0)
		if ch >= "a" and ch <= "z":
			e.keycode = KEY_A + (ch.unicode_at(0) - "a".unicode_at(0)) as Key
		get_root().push_input(e)
		await process_frame
	await frames(2)


func backspace(n: int) -> void:
	for i in range(n):
		var e := InputEventKey.new()
		e.pressed = true
		e.keycode = KEY_BACKSPACE
		get_root().push_input(e)
		await process_frame
	await frames(2)


func check_buttons_named(where: String) -> void:
	var b: Control = block()
	var bad: Array[String] = []
	for btn in (b.find_children("*", "Button", true, false) if b != null else []):
		if (btn as Button).accessibility_name.strip_edges() == "":
			bad.append((btn as Button).text)
	check(b != null and bad.is_empty(), "%s: every button in the hint has an accessibility_name %s" % [where, bad])


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_empty_state.json"
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_empty_state.json"
	ProgressStore.reset()
	TestVault.open("empty-state", false)

	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)

	# ── (a) An empty vault ──
	check(VaultStore.note_list.is_empty(), "the vault starts empty")
	check(block() != null, "an empty vault's sidebar shows a SidebarEmpty block")
	check(block_text().contains("No notes yet"), "it says 'No notes yet' (%s)" % block_text())
	check(block() != null and block().focus_mode == Control.FOCUS_NONE, "the block itself takes no focus")
	var new_btn: Button = block_button("+ New note")
	check(new_btn != null and new_btn.is_visible_in_tree(), "it has a visible '+ New note (Ctrl+N)' button")
	check(new_btn != null and new_btn.theme_type_variation == &"FlatButton", "…a FlatButton")
	check_buttons_named("empty vault")
	if new_btn != null:
		await click(new_btn)
	check(VaultStore.note_list.size() == 1 and app.current_note != null, "a real click on it creates a note (%d notes)" % VaultStore.note_list.size())
	check(block() == null, "with a note in the vault the hint is gone")

	# ── (b) A search nothing matches ──
	app.search_box.grab_focus()
	await type_text("zzqq")
	check(app.search_box.text == "zzqq", "the keys typed 'zzqq' into the search box (%s)" % app.search_box.text)
	check(block() != null and block_text().contains("No notes match"), "a search with no match says 'No notes match' (%s)" % block_text())
	check(block_text().contains("zzqq"), "…and names the search")
	check_buttons_named("no match")
	var create: Button = block_button("Create")
	check(create != null and create.text == "Create “zzqq”", "it offers 'Create “zzqq”' (%s)" % (create.text if create else "missing"))
	check(block_button("Clear search") != null, "and 'Clear search'")
	app._switch_layer("visual")   # Create must land in Edit view from anywhere
	await frames(2)
	if create != null:
		await click(create)
	check(app.current_note != null and app.current_note.title == "zzqq", "Create makes a note titled zzqq and opens it (%s)" % (app.current_note.title if app.current_note else "none"))
	check(app.current_mode == "raw", "…in Edit view (%s)" % app.current_mode)
	check(VaultStore.note_list.size() == 2 and app.search_box.text == "" and block() == null, "the search is cleared and the new note is listed")

	# ── Clearing the search removes the hint ──
	app.search_box.grab_focus()
	await type_text("nomatchhere")
	check(block() != null, "another search with no match shows the hint")
	await backspace("nomatchhere".length())
	check(app.search_box.text == "" and block() == null, "erasing the search removes SidebarEmpty")
	app.search_box.grab_focus()
	await type_text("nomatchhere")
	var clear: Button = block_button("Clear search")
	if clear != null:
		await click(clear)
	check(app.search_box.text == "" and block() == null and app._visible_notes.size() == 2, "a click on 'Clear search' empties the box and the hint goes")

	# ── A long search keeps the sidebar its width ──
	app.search_box.text = "a search for something nobody wrote down anywhere zzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
	app._refresh_note_list()
	await frames(2)
	var layout: Control = app.get_node("AppLayout")
	check(block() != null and layout.get_combined_minimum_size().x <= 820, "a long query's hint fits the 820px window (%d px)" % int(layout.get_combined_minimum_size().x))
	app.search_box.text = ""
	app._refresh_note_list()
	await frames(1)

	# ── (c) A tag no note carries ──
	app.search_box.grab_focus()
	await type_text("#nosuchtag")
	check(block() != null and block_text().contains("No notes tagged #nosuchtag"), "a tag filter with no match says 'No notes tagged #nosuchtag' (%s)" % block_text())
	check(block_button("Create") == null, "…and offers no Create")
	check_buttons_named("tag filter")
	var clear_filter: Button = block_button("Clear filter")
	check(clear_filter != null, "it offers 'Clear filter'")
	if clear_filter != null:
		await click(clear_filter)
	check(app._active_tag_filter == "" and app.search_box.text == "" and block() == null and app._visible_notes.size() == 2, "'Clear filter' clears the filter and its search (%s)" % app.search_box.text)

	# ── A vault with notes and nothing filtered shows no hint ──
	check(block() == null, "an unfiltered vault with notes has no hint")

	app.queue_free()
	await frames(2)
	for p in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
