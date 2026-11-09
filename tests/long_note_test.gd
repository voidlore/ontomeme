extends SceneTree
## Read view on a long note. A 3000-paragraph note shows its first screenful
## in the first frame (under 150 ms headless) and builds the rest over the
## next frames, none over 50 ms. Plain paragraphs merge into a few
## RichTextLabels: at least 5x fewer controls than one row per source line,
## the same spacing, and [[links]] and web links in them still open on a
## real click. Read view isn't rebuilt while the text is unchanged; a build
## paused in Edit carries on in Read; a heading far down can be looked up
## (Outline's Shift+click) before the build gets there, and a real
## Shift+click on it in Outline, or Journey's Launch of a quiz at the end of
## a long note, scrolls Read view to it; Outline is unchanged. A book of
## long plain paragraphs (each its own row) keeps the same 150 ms / 50 ms,
## the first time Read view shows after the app starts and later.
##   godot --headless --path . -s res://tests/long_note_test.gd

const TestVault = preload("res://tests/test_vault.gd")

const PARAGRAPHS: int = 3000
const PER_PART: int = 100   # a "## Part N" heading every 100 paragraphs
const QUIZ_PARAGRAPHS: int = 1000   # "Long Quiz": this many, then a quiz
const BOOK_PARAGRAPHS: int = 120    # "Book": this many plain paragraphs
const BOOK_WORDS: int = 1800        # of this many words (~10000 characters)
const WORDS: PackedStringArray = ["the", "river", "carried", "a", "small", "boat", "past", "old", "stone",
	"walls", "and", "quiet", "fields", "where", "nobody", "had", "walked", "for", "many", "years"]
const QUIZ: String = "```3d\npreset: quiz\nq: Two plus two?\na: 3\na*: 4\na: 5\n```"
const FIRST_FRAME_MS: float = 150.0
const FRAME_MS: float = 50.0
const SHORT_LINKS: String = """First paragraph, plain text.

[[Beta]] opens the Beta note.

[A web page](https://example.com/page) opens in the browser.

The last paragraph,
on two lines."""

var fails: int = 0
var app: Control


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func long_text(paragraphs: int = PARAGRAPHS) -> String:
	var parts: PackedStringArray = []
	for i in range(paragraphs):
		if i % PER_PART == 0:
			parts.append("## Part %d" % (i / PER_PART + 1))
		var p: String = "Paragraph %d says something about the topic at hand, with enough words to wrap once or twice across the column." % i
		if i % 7 == 0:
			p += " See [[Beta]] and **this bold bit**."
		parts.append(p)
	return "\n\n".join(parts)


## Paragraphs of BOOK_WORDS plain words, numbered, a blank line apart: a
## book chapter or an imported note. Each is past MERGE_MAX_CHARS, so each
## is a row of its own.
func book_text() -> String:
	var parts: PackedStringArray = []
	for i in range(BOOK_PARAGRAPHS):
		var w: PackedStringArray = ["Chapter", str(i)]
		for j in range(BOOK_WORDS):
			w.append(WORDS[(i * 7 + j * 3) % WORDS.size()])
		parts.append(" ".join(w) + ".")
	return "\n\n".join(parts)


## Controls Read view used to build for `text`: a row per source line (text,
## or a spacer for a blank line) and a spacer above each heading.
func rows_one_per_line(text: String) -> int:
	var lines: PackedStringArray = text.split("\n")
	return lines.size() + Array(lines).filter(func(l: String) -> bool: return l.begins_with("#")).size()


func count_controls(root: Node) -> int:
	var n: int = 0
	for c in root.get_children():
		n += 1 + count_controls(c)
	return n


func visual_rows() -> Array:
	return LayerEngine._visual_vbox.get_children()


func merged_labels() -> Array:
	return visual_rows().filter(func(c: Node) -> bool: return c is RichTextLabel and c.has_meta("merged_lines"))


func shown_text() -> String:
	var parts: PackedStringArray = []
	for c in visual_rows():
		if c is Label or c is RichTextLabel:
			parts.append(c.text)
	return "\n".join(parts)


## Open `title` in Edit, then switch to Read and time the first frame. The
## build may go on afterwards.
func read_first_frame(title: String) -> float:
	app.open_note_by_title(title)
	if app.current_mode != "raw":
		app._switch_layer("raw")
	await frames(3)
	var t0: int = Time.get_ticks_usec()
	app._switch_layer("visual")
	await process_frame
	return (Time.get_ticks_usec() - t0) / 1000.0


## Frames until the Read-view build is done: [count, slowest ms].
func finish_build() -> Array:
	var n: int = 0
	var worst: float = 0.0
	var last: int = Time.get_ticks_usec()
	while LayerEngine.is_building() and n < 5000:
		await process_frame
		var now: int = Time.get_ticks_usec()
		worst = maxf(worst, (now - last) / 1000.0)
		last = now
		n += 1
	return [n, worst]


func move_mouse(pos: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)


func push_left(pos: Vector2, pressed: bool, shift: bool = false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.shift_pressed = shift
	e.position = pos
	e.global_position = pos
	get_root().push_input(e)


## A real click a few px into paragraph `p` of a merged label.
func click_paragraph(rtl: RichTextLabel, p: int) -> void:
	app.doc_scroll.ensure_control_visible(rtl)
	await frames(2)
	var pos: Vector2 = rtl.get_global_rect().position + Vector2(10, rtl.get_paragraph_offset(p) + 9)
	move_mouse(pos)
	await process_frame
	push_left(pos, true)
	push_left(pos, false)
	await frames(3)


func _init() -> void:
	ProgressStore.file_override = "user://test_progress_long_note.json"   # never touch real progress
	ProgressStore.reset()
	JourneyStore.file_override = "user://test_journey_long_note.json"     # never touch the real journey
	JourneyStore.reset()
	TestVault.open("long_note", false)
	for pair in [["Long", long_text()], ["Beta", "# Beta\n\nThe linked note."], ["Short Links", SHORT_LINKS],
			["Long Quiz", long_text(QUIZ_PARAGRAPHS) + "\n\n" + QUIZ], ["Book", book_text()]]:
		var n: ContentLayer = VaultStore.create_note(pair[0])
		n.raw_text = pair[1]
		VaultStore.save_note(n)
	VaultStore.refresh_note_list()

	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)

	await check_book()   # first: Read view hasn't been laid out yet
	await check_long_build()
	await check_leave_stale()
	await check_unchanged_and_edit()
	await check_pause_in_edit()
	await check_heading_lookup()
	await check_outline()
	await check_outline_jump()
	await check_launch_at_end()
	await check_merged_links()
	check_merged_spacing()

	print("\nRESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(0 if fails == 0 else 1)


func check_long_build() -> void:
	var first_ms: float = await read_first_frame("Long")
	check(first_ms <= FIRST_FRAME_MS, "the first frame of Read view on %d paragraphs takes at most %d ms (%.1f ms)" % [PARAGRAPHS, FIRST_FRAME_MS, first_ms])
	var built_h: float = LayerEngine._visual_vbox.get_combined_minimum_size().y
	check(built_h >= app.doc_scroll.size.y, "the first frame fills the view (%.0f px built, %.0f px shown)" % [built_h, app.doc_scroll.size.y])
	check(LayerEngine.is_building() and not shown_text().contains("Paragraph %d " % (PARAGRAPHS - 1)), "the rest isn't built yet")
	var done: Array = await finish_build()
	check(not LayerEngine.is_building() and done[0] > 1, "the rest builds over %d more frames" % done[0])
	check(done[1] <= FRAME_MS, "no frame of the build takes over %d ms (slowest %.1f ms)" % [FRAME_MS, done[1]])
	var text: String = shown_text()
	check(text.contains("Paragraph 0 ") and text.contains("Paragraph %d " % (PARAGRAPHS - 1)), "every paragraph is there, first to last")
	var parts: Array = visual_rows().filter(func(c: Node) -> bool: return c is Label and (c as Label).text.begins_with("Part "))
	check(parts.size() == PARAGRAPHS / PER_PART, "every heading is there (%d)" % parts.size())
	var old_rows: int = rows_one_per_line(app.current_note.raw_text)
	var now: int = count_controls(LayerEngine._visual_vbox)
	check(now * 5 <= old_rows, "at least 5x fewer controls than a row per line (%d vs %d, %.1fx)" % [now, old_rows, float(old_rows) / now])
	check(merged_labels().size() > 0 and int(merged_labels()[0].get_meta("merged_lines")) > 1, "plain paragraphs merge into RichTextLabels")
	await frames(2)
	var narrow: Array = merged_labels().filter(func(r: RichTextLabel) -> bool: return not is_equal_approx(r.size.x, LayerEngine._visual_vbox.size.x) or r.size.y > 2000.0)
	check(narrow.is_empty(), "every merged label is laid out across the column (%d are not)" % narrow.size())
	var linked: Array = merged_labels().filter(func(r: RichTextLabel) -> bool: return LayerEngine.link_targets(r).has("Beta"))
	check(linked.size() > 0 and linked[0].meta_clicked.get_connections().size() > 0, "merged labels keep their [[links]] and listen for clicks")


## A book of long plain paragraphs, shown in Read view for the first time
## since the app started, when the column has never been laid out (0 px
## wide), then again. Each paragraph row joins Read view empty and gets its
## text once it has a real width, so no paragraph is wrapped at 1 px first;
## the first frame builds no more than a screenful or two of such text.
## (Before, a Label row got its text up front, the first frame built 100
## paragraphs whatever their length, and it took a second.)
func check_book() -> void:
	check(LayerEngine._visual_vbox.size.x == 0.0, "Read view hasn't been laid out yet (%.0f px wide)" % LayerEngine._visual_vbox.size.x)
	var joined: Array[String] = []   # each text row's text as it joins Read view
	var watch: Callable = func(n: Node) -> void:
		if n is Label or n is RichTextLabel:
			joined.append(n.text)
	LayerEngine._visual_vbox.child_entered_tree.connect(watch)
	for pass_no in [1, 2]:
		joined.clear()
		app.open_note_by_title("Book")
		if app.current_mode != "raw":
			app._switch_layer("raw")
		await frames(3)
		LayerEngine.mark_visual_stale()
		var t0: int = Time.get_ticks_usec()
		app._switch_layer("visual")
		var rows: Array = visual_rows().filter(func(c: Node) -> bool: return c is Label and c.text.begins_with("Chapter "))
		var unsized: Array = rows.filter(func(c: Label) -> bool: return c.size.x < 100.0)
		await process_frame
		var first_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
		var when: String = "the first time" if pass_no == 1 else "again"
		check(rows.size() > 0 and unsized.is_empty(), "%s, each paragraph row built has a real width before Read view lays it out (%d of %d don't)" % [when, unsized.size(), rows.size()])
		check(first_ms <= FIRST_FRAME_MS, "%s, the first frame of Read view on %d paragraphs of %d words takes at most %d ms (%.1f ms)" % [when, BOOK_PARAGRAPHS, BOOK_WORDS, FIRST_FRAME_MS, first_ms])
		var built_h: float = LayerEngine._visual_vbox.get_combined_minimum_size().y
		check(built_h >= app.doc_scroll.size.y and LayerEngine.is_building(), "it fills the view (%.0f px built, %.0f px shown) and builds the rest later" % [built_h, app.doc_scroll.size.y])
		var done: Array = await finish_build()
		check(not LayerEngine.is_building() and done[1] <= FRAME_MS, "no frame of the build takes over %d ms (%d frames, slowest %.1f ms)" % [FRAME_MS, done[0], done[1]])
		var shown: Array = visual_rows().filter(func(c: Node) -> bool: return c is Label and c.text.begins_with("Chapter "))
		check(shown.size() == BOOK_PARAGRAPHS, "every paragraph is there, a row each (%d)" % shown.size())
		var early: Array = joined.filter(func(t: String) -> bool: return t != "")
		check(joined.size() >= BOOK_PARAGRAPHS and early.is_empty(), "every paragraph row joined Read view before its text went in (%d of %d had it already)" % [early.size(), joined.size()])
	LayerEngine._visual_vbox.child_entered_tree.disconnect(watch)


## A quiz answer marks Read view stale. Leaving it for Edit must not
## rebuild it on the way out (that cost a second before); coming back does.
func check_leave_stale() -> void:
	var first: RichTextLabel = merged_labels()[0]
	LayerEngine.mark_visual_stale()
	var t0: int = Time.get_ticks_usec()
	app._switch_layer("raw")
	await process_frame
	# (The editor's own first layout of 6000 lines takes ~100 ms here, once.)
	var ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	check(is_instance_valid(first) and first.get_parent() == LayerEngine._visual_vbox,
		"leaving a stale Read view for Edit doesn't rebuild it (Edit in %.1f ms)" % ms)
	app._switch_layer("visual")
	await process_frame
	check(not is_instance_valid(first) or first.get_parent() == null, "coming back to it rebuilds it")
	await finish_build()


func check_unchanged_and_edit() -> void:
	var first: RichTextLabel = merged_labels()[0]
	app._switch_layer("raw")
	await frames(2)
	var t0: int = Time.get_ticks_usec()
	app._switch_layer("visual")
	await process_frame
	var back_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	check(is_instance_valid(first) and first.get_parent() == LayerEngine._visual_vbox, "Edit then Read again with the text unchanged keeps the built view")
	check(not LayerEngine.is_building() and back_ms <= FIRST_FRAME_MS, "and shows it at once (%.1f ms)" % back_ms)

	app._switch_layer("raw")
	await frames(2)
	app.raw_text_layer.set_caret_line(app.raw_text_layer.get_line_count() - 1)
	app.raw_text_layer.set_caret_column(app.raw_text_layer.get_line(app.raw_text_layer.get_line_count() - 1).length())
	app.raw_text_layer.insert_text_at_caret("\n\nOne more paragraph at the end.")
	await frames(2)
	app._switch_layer("visual")
	await process_frame
	check(not is_instance_valid(first) or first.get_parent() == null, "changed text rebuilds Read view")
	await finish_build()
	check(shown_text().contains("One more paragraph at the end."), "and the new paragraph shows")


func check_pause_in_edit() -> void:
	var full: int = LayerEngine._visual_vbox.get_child_count()
	LayerEngine.mark_visual_stale()   # as a quiz answer does: rebuild on the next render
	app._switch_layer("visual")
	await process_frame
	check(LayerEngine.is_building(), "a stale view rebuilds")
	app._switch_layer("raw")
	await process_frame
	var paused: int = LayerEngine._visual_vbox.get_child_count()
	await frames(10)
	check(LayerEngine.is_building() and LayerEngine._visual_vbox.get_child_count() == paused, "in Edit the build waits (%d rows)" % paused)
	app._switch_layer("visual")
	var done: Array = await finish_build()
	check(not LayerEngine.is_building() and LayerEngine._visual_vbox.get_child_count() == full,
		"back in Read it carries on to the same view (%d rows, %d frames, slowest %.1f ms)" % [LayerEngine._visual_vbox.get_child_count(), done[0], done[1]])


func check_heading_lookup() -> void:
	var lines: PackedStringArray = app.current_note.raw_text.split("\n")
	var last_part: int = -1
	for i in range(lines.size()):
		if lines[i].begins_with("## Part "):
			last_part = i
	LayerEngine.mark_visual_stale()
	app._switch_layer("visual")
	check(LayerEngine.is_building(), "the long note is building again")
	var row: Control = LayerEngine.visual_row_for_line(last_part)
	check(row is Label and (row as Label).text == lines[last_part].substr(3), "the last heading's row is found before the build reaches it (%s)" % [row])
	await finish_build()


func check_outline() -> void:
	app._switch_layer("structured")
	await frames(2)
	var rows: Array = app.structured_layer.find_children("*", "Label", true, false).filter(func(c: Node) -> bool: return c.has_meta("source_line"))
	check(rows.size() == PARAGRAPHS / PER_PART, "Outline lists every heading as before (%d)" % rows.size())


## How far below the top of Read view `c` sits, in px (24 when a jump put
## it there).
func view_offset(c: Control) -> float:
	return c.global_position.y - app.doc_scroll.global_position.y


## A real Shift+click on the last heading in Outline while Read view is
## still to be built: Read view opens with that heading near the top. (The
## heading's position was once read before its rows were laid out, which
## left the view at the top of the note; and with nothing built below the
## heading, it could only scroll to the bottom edge.)
func check_outline_jump() -> void:
	LayerEngine.mark_visual_stale()   # Read view rebuilds from the top on the way in
	app._switch_layer("structured")
	await frames(2)
	var rows: Array = app.structured_layer.find_children("*", "Label", true, false).filter(func(c: Node) -> bool: return c.has_meta("source_line"))
	var row: Label = rows[rows.size() - 1]
	var line: int = int(row.get_meta("source_line"))
	var text: String = app.current_note.raw_text.split("\n")[line].substr(3)   # "## Part N"
	app.doc_scroll.ensure_control_visible(row)
	await frames(2)
	var pos: Vector2 = row.get_global_rect().get_center()
	move_mouse(pos)
	await process_frame
	push_left(pos, true, true)
	push_left(pos, false, true)
	await frames(4)
	check(app.current_mode == "visual", "Shift+click on the last heading in Outline opens Read (%s)" % app.current_mode)
	var heading: Control = null
	for c in visual_rows():
		if c is Control and int(c.get_meta("source_line", -1)) == line:
			heading = c
	var top: float = view_offset(heading) if heading != null else -1.0
	check(heading is Label and (heading as Label).text == text and top >= 0.0 and top <= 60.0,
		"Read view is scrolled to that heading: %s sits %.0f px below the top (scroll %d)" % [text, top, app.doc_scroll.scroll_vertical])
	await finish_build()
	check(heading != null and is_equal_approx(view_offset(heading), top), "and stays there while the rest builds")


## Journey's Launch of a quiz at the end of a long note: the build is
## finished on the spot, and Read view scrolls to the quiz card.
func check_launch_at_end() -> void:
	app._switch_layer("raw")
	await frames(2)
	var card: Control = await app.launch_activity(JourneyStore.activity_key("Long Quiz", "quiz", 0))
	check(card != null and app.current_note.title == "Long Quiz", "Launch finds the quiz at the end of a %d-paragraph note" % QUIZ_PARAGRAPHS)
	if card == null:
		return
	await frames(3)
	var top: float = view_offset(card)
	check(top >= 0.0 and top <= 60.0 and app.doc_scroll.get_global_rect().intersects(card.get_global_rect()),
		"Read view is scrolled to the quiz card: it sits %.0f px below the top (scroll %d, card at %.0f)" % [top, app.doc_scroll.scroll_vertical, card.position.y])
	await finish_build()


func check_merged_links() -> void:
	var to_os: Array = []
	var real_open: Callable = LayerEngine._os_open
	LayerEngine._os_open = func(url: String) -> Error:
		to_os.append(url)
		return OK
	await read_first_frame("Short Links")
	await frames(2)
	var merged: Array = merged_labels()
	check(merged.size() == 1 and visual_rows().filter(func(c: Node) -> bool: return c is Label or c is RichTextLabel).size() == 1,
		"four short paragraphs show as one merged label (%d)" % merged.size())
	if merged.size() != 1:
		LayerEngine._os_open = real_open
		return
	await click_paragraph(merged[0], 1)
	check(app.current_note.title == "Beta", "a real click on [[Beta]] inside the merged label opens Beta (%s)" % app.current_note.title)
	check(to_os.is_empty(), "and doesn't reach the OS")
	await read_first_frame("Short Links")
	await frames(2)
	await click_paragraph(merged_labels()[0], 2)
	check(to_os == ["https://example.com/page"], "a real click on a web link inside it goes to the OS (%s)" % [to_os])
	check(app.current_note.title == "Short Links", "and opens no note")
	LayerEngine._os_open = real_open


## Paragraphs in a merged label sit as far apart as one-line rows with a
## blank line between them did (row, separation, spacer, separation), and
## the lines of one paragraph as far apart as rows with no blank line.
func check_merged_spacing() -> void:
	var rtl: RichTextLabel = merged_labels()[0] if merged_labels().size() == 1 else null
	if rtl == null:
		check(false, "the merged label is there to measure")
		return
	var sep: int = LayerEngine._visual_vbox.get_theme_constant("separation")
	var row_h: float = LayerEngine._line_height()   # a one-line row's height
	var apart: float = rtl.get_paragraph_offset(1) - rtl.get_paragraph_offset(0)
	check(is_equal_approx(apart, row_h + 3 * sep), "paragraphs are %.0f px apart, as rows with a blank line between were (%.0f)" % [apart, row_h + 3 * sep])
	# The last paragraph has two lines: [br] keeps them one row and a separation apart
	var last: float = rtl.get_content_height() - rtl.get_paragraph_offset(3)
	var want: float = 2 * (row_h + sep) + LayerEngine.PARAGRAPH_GAP
	check(rtl.get_paragraph_count() == 4 and is_equal_approx(last, want),
		"a paragraph's two lines stay one paragraph, a row and a separation apart (%.0f px, want %.0f)" % [last, want])
	check(is_equal_approx(rtl.size.x, LayerEngine._visual_vbox.size.x), "the merged label spans the column")
