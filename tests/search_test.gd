extends SceneTree
## Search: every word must match (anywhere, in any order), each match comes
## with an excerpt of its first matching line, title matches rank first, and
## opening a result puts the caret on the match (Edit view) or scrolls the
## Read view to it. VaultStore.search, the sidebar's result rows, the palette.
##   headless:  godot --headless --path . -s res://tests/search_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const FAR_LINE: String = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor marmoset incididunt ut labore et dolore magna aliqua, ut enim ad minim veniam, quis nostrud."

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


## `n` lines that match no query below.
func filler(n: int) -> String:
	var lines: PackedStringArray = []
	for i in range(n):
		lines.append("Filler line %d says nothing much." % i)
	return "\n".join(lines)


func make(title: String, text: String) -> ContentLayer:
	var note: ContentLayer = VaultStore.create_note(title)
	note.raw_text = text
	VaultStore.save_note(note)
	return note


func titles(hits: Array) -> Array:
	return hits.map(func(h: Dictionary) -> String: return h.note.title)


func hit_for(hits: Array, title: String) -> Dictionary:
	for h in hits:
		if h.note.title == title:
			return h
	return {}


## A real key press and release, delivered to the focused control.
func key(code: Key) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = pressed
		get_root().push_input(e)
	await frames(2)


## Type `text` into the focused control with real key events.
func type_keys(text: String) -> void:
	for ch in text:
		for pressed in [true, false]:
			var e := InputEventKey.new()
			e.keycode = OS.find_keycode_from_string(ch.to_upper()) if ch != " " else KEY_SPACE
			e.unicode = ch.unicode_at(0)
			e.pressed = pressed
			get_root().push_input(e)
	await frames(2)


## A real mouse click (motion, press, release through the root viewport).
func click_at(pos: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = button
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	await frames(2)


## VaultStore.search on its own: the word AND, the hit's line, column and
## excerpt, and the ranking.
func check_store() -> void:
	make("Both Words", "Intro line.\nThis one has a quiz in it.\n" + filler(3) + "\nAnd Godot is here.")
	make("Only Quiz", "Just a quiz here.")
	make("Only Godot", "Godot, alone.")
	make("Godot Quiz Guide", "Nothing else to say.")
	var hits: Array = VaultStore.search("quiz godot")
	var found: Array = titles(hits)
	check("Both Words" in found, "'quiz godot' finds a note with the words on different lines (%s)" % [found])
	check(not "Only Quiz" in found and not "Only Godot" in found, "and not the notes with only one of them (%s)" % [found])
	var both: Dictionary = hit_for(hits, "Both Words")
	check(both.get("line") == 1 and both.get("col") == "This one has a quiz in it.".find("quiz"),
		"the hit is the first body line holding a word, at the word (line %s, col %s)" % [both.get("line"), both.get("col")])
	check(str(both.get("excerpt", "")).to_lower().contains("quiz"), "its excerpt holds the matched word (%s)" % both.get("excerpt"))
	check(found.size() == 2 and found[0] == "Godot Quiz Guide", "a title match ranks above a body-only match (%s)" % [found])
	check(int(hit_for(hits, "Godot Quiz Guide").score) > int(both.score), "its score is higher (%s > %s)" % [hit_for(hits, "Godot Quiz Guide").score, both.score])
	var title_only: Dictionary = hit_for(hits, "Godot Quiz Guide")
	check(title_only.line == -1 and title_only.excerpt == "", "a title-only match has no line and no excerpt (%s)" % [title_only])
	check(titles(VaultStore.search("  QUIZ   Godot ")) == found, "case and spacing do not matter")
	check(VaultStore.search("").size() == VaultStore.note_list.size(), "a query with no words matches every note")
	check(hits.all(func(h: Dictionary) -> bool: return VaultStore.note_list[h.index] == h.note), "each hit's index points into note_list")

	var long_line: String = "x".repeat(100) + " needle " + "y".repeat(100)
	make("Long Line", "first line\n" + long_line)
	var lh: Dictionary = hit_for(VaultStore.search("needle"), "Long Line")
	var ex: String = str(lh.get("excerpt", ""))
	check(ex.contains("needle") and ex.begins_with("…") and ex.ends_with("…"),
		"a long line's excerpt is cut around the match, with ellipses (%s)" % ex)
	check(ex.length() <= 40 + "needle".length() + 40 + 2, "to 40 characters each side (%d chars)" % ex.length())
	make("Far Match", FAR_LINE)
	var fe: String = str(hit_for(VaultStore.search("marmoset"), "Far Match").get("excerpt", ""))
	var inner: String = fe.trim_prefix("…").trim_suffix("…")
	check(fe.begins_with("…") and fe.ends_with("…") and inner.contains("marmoset") and FAR_LINE.contains(inner),
		"a cut excerpt is a piece of its line (%s)" % fe)
	check(Array(FAR_LINE.split(" ")).has(inner.split(" ")[0]) and Array(FAR_LINE.split(" ")).has(inner.split(" ")[-1]),
		"cut on whole words (%s)" % fe)

	make("One Hit", "a zebra")
	make("Many Hits", "zebra\nzebra zebra")
	check(titles(VaultStore.search("zebra")) == ["Many Hits", "One Hit"], "more hits rank higher (%s)" % [titles(VaultStore.search("zebra"))])


## The sidebar: result rows show an excerpt under the title, Enter in the
## search box opens the top result with the caret on the match, a click on a
## row in Read view scrolls to the match, a right-click still gives the menu.
func check_sidebar(app: Control, deep: ContentLayer, other: ContentLayer) -> void:
	app._switch_layer("raw")
	app._open_note(other)
	await frames(2)
	app.search_box.grab_focus()
	await type_keys("zebrafish lantern")
	check(app.search_box.text == "zebrafish lantern", "the keys land in the search box (%s)" % app.search_box.text)
	check(app._visible_notes == [deep], "the search finds the one note with both words (%s)" % [app._visible_notes.map(func(n): return n.title)])
	var btn: Button = app._note_buttons.get(deep)
	var ex: Label = btn.get_node_or_null("Excerpt") if btn != null else null
	check(ex != null and ex.text.contains("zebrafish"), "the result row shows an excerpt with the match (%s)" % (ex.text if ex != null else "none"))
	check(ex != null and btn.text == "Deep Match", "the row still reads the title (%s)" % btn.text)
	check(ex != null and btn.get_global_rect().encloses(ex.get_global_rect()), "the excerpt sits inside its row")
	check(ex != null and ex.get_global_rect().get_center().y > btn.get_global_rect().get_center().y, "under the title")
	check(ex != null and ex.mouse_filter == Control.MOUSE_FILTER_IGNORE, "and lets clicks through to the row")
	check(ex != null and ex.get_theme_color("font_color") != btn.get_theme_color("font_color"), "in a fainter colour than the title")

	await key(KEY_ENTER)
	check(app.current_note == deep and app.current_mode == "raw", "Enter opens the top result in Edit view (%s)" % app.current_note.title)
	check(app.raw_text_layer.get_caret_line() == 30, "with the caret on the match line (%d)" % app.raw_text_layer.get_caret_line())
	check(app.raw_text_layer.get_caret_column() == "The ".length(), "at the matched word (col %d)" % app.raw_text_layer.get_caret_column())
	await frames(3)
	check(app.raw_text_layer.get_first_visible_line() <= 30 and 30 <= app.raw_text_layer.get_last_full_visible_line(),
		"and the match line on screen (lines %d to %d)" % [app.raw_text_layer.get_first_visible_line(), app.raw_text_layer.get_last_full_visible_line()])
	check(app.raw_text_layer.has_focus(), "the editor has the focus")

	# Read view: a click on the row scrolls to the first label with the word
	app._open_note(other)
	app._switch_layer("visual")
	await frames(3)
	check(app.doc_scroll.scroll_vertical == 0, "the other note starts at the top")
	btn = app._note_buttons.get(deep)
	await click_at(btn.get_global_rect().get_center())
	await frames(4)
	check(app.current_note == deep and app.current_mode == "visual", "a click on the result opens it in Read view")
	# Read view merges plain paragraphs into one RichTextLabel, so the match
	# is a line inside a row: that line must be on screen
	var shown: Rect2 = Rect2()
	for c in app.visual_layer.get_children():
		if c is Label and (c as Label).text.contains("zebrafish"):
			shown = c.get_global_rect()
			break
		if c is RichTextLabel and (c as RichTextLabel).get_parsed_text().contains("zebrafish"):
			var rtl: RichTextLabel = c
			var l: int = rtl.get_character_line(rtl.get_parsed_text().find("zebrafish"))
			var top: float = rtl.get_line_offset(l)
			var bottom: float = rtl.get_line_offset(l + 1) if l + 1 < rtl.get_line_count() else rtl.size.y
			shown = Rect2(rtl.global_position + Vector2(0, top), Vector2(rtl.size.x, bottom - top))
			break
	check(shown.has_area() and app.doc_scroll.scroll_vertical > 0, "Read view scrolls down to the match (%d)" % app.doc_scroll.scroll_vertical)
	check(shown.has_area() and app.doc_scroll.get_global_rect().encloses(shown),
		"the line with 'zebrafish' is on screen (%s in %s)" % [shown, app.doc_scroll.get_global_rect()])

	# The row keeps its context menu, even on the excerpt
	btn = app._note_buttons.get(deep)
	ex = btn.get_node_or_null("Excerpt")
	await click_at(ex.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	check(app._ctx_target.get("note") == deep and app._ctx_menu.visible, "a right-click on the excerpt opens the note's menu")
	app._ctx_menu.hide()

	# A match deep in a long line: the row's excerpt starts near it, so the
	# word shows before the row's "…"
	app.search_box.text = "marmoset"
	app._on_search_changed("marmoset")
	await frames(2)
	ex = app._note_buttons[VaultStore.note_list[VaultStore.get_note_index("Far Match")]].get_node_or_null("Excerpt")
	var at: int = ex.text.find("marmoset") if ex != null else -1
	check(at >= 0 and at <= app.EXCERPT_LEAD + 1, "a long line's row excerpt starts near the match (%s)" % (ex.text if ex != null else "none"))
	app.search_box.text = ""
	app._on_search_changed("")
	await frames(2)
	check(app._note_buttons[deep].get_node_or_null("Excerpt") == null, "with no words the rows are plain again")


## The palette lists notes through the same search and opens at the match.
func check_palette(app: Control, deep: ContentLayer, other: ContentLayer) -> void:
	app._switch_layer("raw")
	app._open_note(other)
	await frames(2)
	app._open_palette()
	await frames(2)
	await type_keys("zebrafish lantern")
	var rows: Array = []
	for i in range(app._palette_list.item_count):
		rows.append(app._palette_list.get_item_text(i))
	check(rows.size() == 1 and str(rows[0]).contains("Deep Match") and str(rows[0]).contains("zebrafish"),
		"the palette finds the note by words on two lines and shows the excerpt (%s)" % [rows])
	await key(KEY_ENTER)
	check(app.current_note == deep and app.raw_text_layer.get_caret_line() == 30,
		"Enter opens it with the caret on the match (line %d)" % app.raw_text_layer.get_caret_line())
	app._open_palette()
	await frames(2)
	await type_keys("Deep Match")
	check(app._palette_items.size() >= 1 and str(app._palette_items[0].label).contains("Deep Match"),
		"a title search still lists the note (%s)" % [app._palette_items.map(func(r): return r.label)])
	await key(KEY_ESCAPE)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_search.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_search.json"   # never touch real progress
	ProgressStore.reset()
	TestVault.open("search", false)

	check_store()

	var deep: ContentLayer = make("Deep Match", filler(30) + "\nThe zebrafish swims here.\n" + filler(10) + "\nA paper lantern glows.\n" + filler(30))
	var other: ContentLayer = make("Some Other Note", "Nothing to find.")
	var app: Control = await boot()
	await check_sidebar(app, deep, other)
	await check_palette(app, deep, other)
	app.queue_free()
	await frames(2)

	TestVault.remove_tree(VaultStore.vault_path)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
