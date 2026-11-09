extends SceneTree
## Read view renders the common Markdown blocks: YAML front matter (a muted
## key/value box), > quotes (one panel per run of lines), ---/***/___ rules,
## numbered, nested and task lists with hanging markers, H4–H6, and
## [text](url) / bare URL links (http, https and mailto only). Every seeded
## note still renders one 3D card per ```3d block.
##   headless:  godot --headless --path . -s res://tests/markdown_render_test.gd
##   + images:  godot --path . -s res://tests/markdown_render_test.gd -- <out_dir>

const TestVault = preload("res://tests/test_vault.gd")
const Seed3D = preload("res://tests/seed_3d_demo.gd")

const BLOCKS: String = """---
title: Every Block
tags:
  - markdown
  - test
---
# Every block
Intro with a [site](https://example.com) and https://example.org/path. Then a [bad](javascript:alert(1)) link and [a file](notes.md).
> A quote line with **bold** and [[Linked Note]]
> and a second line
---
1. First step
2) Second step
10. Tenth step
- parent bullet
  - nested child
    - grandchild with a [[Linked Note]] link
- back to the top level
- [ ] open task
- [x] done task
* [X] starred done task
#### Small four
##### Small five
###### Small six
***
___
Mail [me](mailto:me@example.com) or see (https://example.net/a_(b)).
- - -
* * *
Plain closing line."""

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


## Every descendant of `root` that is an instance of `type` (a class name).
func find_all(root: Node, type: String) -> Array:
	var found: Array = []
	for c in root.get_children():
		if c.is_class(type):
			found.append(c)
		found.append_array(find_all(c, type))
	return found


func texts(root: Node) -> Array:
	var t: Array = []
	for l in find_all(root, "Label") + find_all(root, "RichTextLabel"):
		t.append(l.text)
	return t


## The Read-view row (a direct child of the visual layer) whose text is or
## contains `text`.
func row_with(text: String) -> Control:
	for c in LayerEngine._visual_vbox.get_children():
		if (c is Label or c is RichTextLabel) and c.text.contains(text):
			return c
	return null


func marker_of(row: Control) -> Control:
	return row.get_node_or_null("ListMarker") if row != null else null


func text_indent(row: Control) -> float:
	return row.get_theme_stylebox("normal").content_margin_left if row != null else -1.0


func open_note(title: String, text: String) -> void:
	var n: ContentLayer = VaultStore.create_note(title)
	n.raw_text = text
	VaultStore.save_note(n)
	app._refresh_note_list()
	app.open_note_by_title(title)
	await frames(2)
	app._switch_layer("visual")
	await frames(4)


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	if out != "":
		DisplayServer.window_set_size(Vector2i(1280, 900))
	JourneyStore.file_override = "user://test_journey_markdown_render.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_markdown_render.json"   # never touch real progress
	ProgressStore.reset()
	TestVault.open("markdown_render")   # tutorials + course, never the user's vault
	var demo: ContentLayer = VaultStore.create_note("3D Scenes")
	demo.raw_text = Seed3D.BODY
	VaultStore.save_note(demo)
	VaultStore.refresh_note_list()

	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)

	check_web_link_rule()
	await open_note("Every Block", BLOCKS)
	check_no_raw_markers()
	check_front_matter()
	check_quote()
	check_rules()
	check_lists()
	check_headings()
	check_links()
	check_layout()
	await shot("markdown_blocks")
	check_outline_parse()
	await check_link_clicks()
	await check_web_link_quotes()
	await check_tables()
	await check_table_code_cells()
	await check_wide_table()
	await check_not_front_matter()
	await check_scene_cards_unchanged()

	print("\nRESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(0 if fails == 0 else 1)


func check_web_link_rule() -> void:
	check(LayerEngine.is_web_link("https://example.com") and LayerEngine.is_web_link("HTTP://x.org")
		and LayerEngine.is_web_link("mailto:me@example.com"), "http, https and mailto links open in the OS")
	for bad in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "notes.md", "https://", "ftp://x.org"]:
		check(not LayerEngine.is_web_link(bad), "'%s' is not a web link" % bad)


func check_no_raw_markers() -> void:
	var raw: Array = []
	for t in texts(LayerEngine._visual_vbox):
		for prefix in ["> ", ">", "---", "***", "___", "[ ]", "[x]", "[X]", "####", "1. ", "2) ", "- ", "* "]:
			if str(t).begins_with(prefix) and str(t) != "•":
				raw.append(t)
	check(raw.is_empty(), "no Label or RichTextLabel starts with a raw Markdown marker (> --- *** [ ] #### 1. -) %s" % [raw])


func check_front_matter() -> void:
	var boxes: Array = LayerEngine._visual_vbox.get_children().filter(func(c) -> bool: return c is PanelContainer and c.theme_type_variation == &"FrontMatterPanel")
	check(boxes.size() == 1, "the leading --- block renders as one FrontMatterPanel (%d)" % boxes.size())
	if boxes.is_empty():
		return
	var grid: GridContainer = find_all(boxes[0], "GridContainer")[0]
	var cells: Array = grid.get_children().map(func(l) -> String: return (l as Label).text)
	check(grid.columns == 2 and cells == ["title", "Every Block", "tags", "markdown, test"],
		"front matter shows key / value pairs, a YAML list joined with commas (%s)" % [cells])
	check((grid.get_child(1) as Label).theme_type_variation == &"MutedLabel", "front matter values are muted")
	check(row_with("Every block") is Label and (row_with("Every block") as Label).theme_type_variation == &"H1Label",
		"the body after the box renders as usual")


func check_quote() -> void:
	var quotes: Array = LayerEngine._visual_vbox.get_children().filter(func(c) -> bool: return c is PanelContainer and c.theme_type_variation == &"QuotePanel")
	check(quotes.size() == 1, "two consecutive > lines merge into one QuotePanel (%d)" % quotes.size())
	if quotes.is_empty():
		return
	var rich: Array = find_all(quotes[0], "RichTextLabel")
	var bb: String = (rich[0] as RichTextLabel).text if rich.size() == 1 else ""
	check(bb.contains("[b]bold[/b]") and bb.contains("[url=0]") and LayerEngine.link_targets(rich[0]) == ["Linked Note"] and bb.contains("\nand a second line"),
		"the quote keeps emphasis, [[links]] and both lines (%s)" % bb)
	var sb: StyleBox = (quotes[0] as PanelContainer).get_theme_stylebox("panel")
	check(sb is StyleBoxFlat and (sb as StyleBoxFlat).border_width_left >= 2 and (sb as StyleBoxFlat).border_width_right == 0,
		"the quote panel has a left accent border")


func check_rules() -> void:
	var seps: Array = LayerEngine._visual_vbox.get_children().filter(func(c) -> bool: return c is HSeparator)
	check(seps.size() == 5, "---, ***, ___, - - - and * * * render as HSeparators, the front matter's --- do not (%d)" % seps.size())


func check_lists() -> void:
	for want in [["First step", "1."], ["Second step", "2)"], ["Tenth step", "10."], ["parent bullet", "•"]]:
		var marker: Label = marker_of(row_with(want[0])) as Label
		check(marker != null and marker.text == want[1], "'%s' hangs the marker '%s' (%s)" % [want[0], want[1], marker.text if marker != null else "none"])
	var parent: Control = row_with("parent bullet")
	var child: Control = row_with("nested child")
	var grand: Control = row_with("grandchild")
	var top: Control = row_with("back to the top level")
	check(child != null and grand != null and parent != null, "the nested items render")
	if child == null or grand == null or parent == null or top == null:
		return
	check(text_indent(child) > text_indent(parent) and text_indent(grand) > text_indent(child),
		"a nested bullet's indent is greater than its parent's (%s < %s < %s)" % [text_indent(parent), text_indent(child), text_indent(grand)])
	check(marker_of(child).position.x > marker_of(parent).position.x, "the nested bullet's marker moves right too")
	check(int(child.get_meta("list_depth")) == 1 and int(grand.get_meta("list_depth")) == 2 and int(top.get_meta("list_depth")) == 0,
		"depths 0 / 1 / 2, and a shallower item closes the levels")
	check(grand is RichTextLabel and (grand as RichTextLabel).text.contains("[url=0]") and LayerEngine.link_targets(grand) == ["Linked Note"], "a nested item keeps its [[link]]")
	check(text_indent(parent) >= marker_of(parent).position.x + marker_of(parent).size.x,
		"the marker hangs left of the text (hanging indent)")
	# Task items: a drawn, read-only checkbox, ticked for [x] / [X]
	var open: Control = row_with("open task")
	var done: Control = row_with("done task")
	var starred: Control = row_with("starred done task")
	check(marker_of(open) is TextureRect and (marker_of(open) as TextureRect).texture == Icons.get_icon("check_box", 16),
		"- [ ] shows an empty checkbox icon")
	check(marker_of(done) is TextureRect and (marker_of(done) as TextureRect).texture == Icons.get_icon("check_box_on", 16)
		and marker_of(starred) is TextureRect and (marker_of(starred) as TextureRect).texture == Icons.get_icon("check_box_on", 16),
		"- [x] and * [X] show a ticked checkbox icon")
	check(marker_of(done) != null and marker_of(done).mouse_filter == Control.MOUSE_FILTER_IGNORE and not (marker_of(done) is BaseButton),
		"checkboxes are read-only")


func check_headings() -> void:
	for t in ["Small four", "Small five", "Small six"]:
		var l: Control = row_with(t)
		check(l is Label and (l as Label).text == t and (l as Label).theme_type_variation == &"H3Label", "'%s' (H4–H6) renders with H3Label" % t)


func check_links() -> void:
	var rich: Array = find_all(LayerEngine._visual_vbox, "RichTextLabel").map(func(r) -> String: return (r as RichTextLabel).text)
	var all: String = "\n".join(rich)
	check(all.contains("[url=https://example.com]"), "[site](https://example.com) becomes [url=https://example.com]")
	check(all.contains("[url=https://example.org/path]") and not all.contains("[url=https://example.org/path.]"),
		"a bare URL is linked, without the sentence's full stop")
	check(all.contains("[url=mailto:me@example.com]"), "a mailto: link is linked")
	check(all.contains("[url=https://example.net/a_(b)]"), "a bare URL keeps its own (parentheses) but not the sentence's")
	check(not all.contains("[url=javascript") and all.contains("javascript:alert(1)"),
		"a javascript: link is not wrapped in [url] and stays as written")
	check(not all.contains("[url=notes.md]") and all.contains("(notes.md)"), "a relative [a file](notes.md) link stays text")
	var intro: RichTextLabel = row_with("example.com") as RichTextLabel
	check(intro != null and intro.meta_clicked.get_connections().size() > 0, "link rows listen for clicks")
	# A [[link]] in a list row still opens its note
	var grand: RichTextLabel = row_with("grandchild") as RichTextLabel
	if grand != null:
		grand.meta_clicked.emit("0")   # a [[link]]'s url meta is its index in the row (link_targets)
	check(app.current_note != null and app.current_note.title == "Linked Note", "clicking a [[link]] in a nested item opens (creates) the note")
	app.open_note_by_title("Every Block")
	app._switch_layer("visual")


## The [url] metas in a row's BBCode, in order: what a click emits (a web
## link's URL, or a [[link]]'s index in LayerEngine.link_targets).
func url_metas(row: Control) -> Array:
	var metas: Array = []
	if row is RichTextLabel:
		var rx := RegEx.create_from_string("\\[url=([^\\]]+)\\]")
		for m in rx.search_all((row as RichTextLabel).text):
			metas.append(m.get_string(1))
	return metas


## Clicks reach the OS (LayerEngine._os_open) only for http, https and mailto
## links. A [[link]] can name any target: javascript:, file:, data: or a
## Windows path is a note title to open, never handed to the OS.
func check_link_clicks() -> void:
	var to_os: Array = []
	var real_open: Callable = LayerEngine._os_open
	check(real_open == Callable(OS, "shell_open") and real_open.is_valid(), "web links go to OS.shell_open outside tests")
	LayerEngine._os_open = func(url: String) -> Error:
		to_os.append(url)
		return OK
	app.open_note_by_title("Every Block")
	app._switch_layer("visual")
	await frames(4)
	var want: Array = ["https://example.com", "https://example.org/path", "mailto:me@example.com", "https://example.net/a_(b)"]
	for row in [row_with("example.com"), row_with("mailto:me@example.com")]:
		for meta in url_metas(row):
			(row as RichTextLabel).meta_clicked.emit(meta)
	check(to_os == want, "clicking http, https and mailto links hands each to the OS (%s)" % [to_os])
	check(app.current_note != null and app.current_note.title == "Every Block", "a web link click opens no note")

	var odd: Array = ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "C:\\Windows\\System32\\calc.exe"]
	var body: String = "\n".join(odd.map(func(t: String) -> String: return "Go [[%s]] now." % t))
	await open_note("Odd Targets", body)
	for target in odd:
		app.open_note_by_title("Odd Targets")
		app._switch_layer("visual")
		await frames(4)
		# The four lines are one paragraph, so one merged label holds all four
		# links; each one's url meta is its index in the row's link_targets
		var rows: Array = find_all(LayerEngine._visual_vbox, "RichTextLabel").filter(func(r) -> bool: return LayerEngine.link_targets(r).has(target))
		var row: RichTextLabel = rows[0] if rows.size() > 0 else null
		var meta: String = str(LayerEngine.link_targets(row).find(target)) if row != null else ""
		var metas: Array = url_metas(row)
		check(metas.has(meta), "[[%s]] renders as a [url] link (%s)" % [target, metas])
		if row == null or not metas.has(meta):
			continue
		to_os.clear()
		row.meta_clicked.emit(meta)
		await frames(1)
		check(to_os.is_empty(), "clicking [[%s]] does not reach the OS (%s)" % [target, to_os])
		check(app.current_note != null and app.current_note.title == target, "clicking [[%s]] opens it as a note title" % target)
	LayerEngine._os_open = real_open


## A ' or " in a web link's URL: Godot's BBCode reads them as quotes inside
## a [url=…] tag, so the link text vanished ("Ohm's law"), a merged label
## showed the paragraphs after it as raw BBCode with dead [[links]], and a
## bare URL was cut at the apostrophe (a click opened /wiki/Ohm).
func check_web_link_quotes() -> void:
	var to_os: Array = []
	var real_open: Callable = LayerEngine._os_open
	LayerEngine._os_open = func(url: String) -> Error:
		to_os.append(url)
		return OK
	await open_note("Quote Links", "\n\n".join([
		"See [Ohm's law](https://en.wikipedia.org/wiki/Ohm's_law) and [[Linked Note]] here.",
		"Para two [Hooke](https://en.wikipedia.org/wiki/Hooke's_law) here.",
		"Para three [[Linked Note]].",
		"Odd [x](https://example.com/a\"b) then **bold**.",
		"Bare https://en.wikipedia.org/wiki/Schrödinger's_cat and 'https://example.com/q' too.",
	]))
	var rows: Array = find_all(LayerEngine._visual_vbox, "RichTextLabel")
	var shown: String = "\n".join(rows.map(func(r) -> String: return (r as RichTextLabel).get_parsed_text()))
	for want in ["See Ohm's law and Linked Note here.", "Para two Hooke here.", "Para three Linked Note.", "Odd x then bold.",
			"Bare https://en.wikipedia.org/wiki/Schrödinger's_cat and 'https://example.com/q' too."]:
		check(shown.contains(want), "Read view shows '%s' (%s)" % [want, shown])
	check(not shown.contains("[url") and not shown.contains("[color") and not shown.contains("[b]"), "and no raw BBCode")
	var metas: Array = []
	var notes: Array = []
	for r in rows:
		metas.append_array(url_metas(r).filter(func(m: String) -> bool: return not m.is_valid_int()))
		notes.append_array(LayerEngine.link_targets(r))
	check(notes == ["Linked Note", "Linked Note"], "both [[links]] still link (%s)" % [notes])
	for r in rows:
		for meta in url_metas(r):
			if not str(meta).is_valid_int():
				(r as RichTextLabel).meta_clicked.emit(meta)
	await frames(1)
	var want_os: Array = ["https://en.wikipedia.org/wiki/Ohm%27s_law", "https://en.wikipedia.org/wiki/Hooke%27s_law",
		"https://example.com/a%22b", "https://en.wikipedia.org/wiki/Schrödinger%27s_cat", "https://example.com/q"]
	check(to_os == want_os, "each web link hands its whole URL to the OS, ' and \" as %%27 and %%22 (%s)" % [to_os])
	LayerEngine._os_open = real_open


func check_layout() -> void:
	var layout_min: Vector2 = app.get_node("AppLayout").get_combined_minimum_size()
	check(layout_min.x <= 820, "the blocks fit the 820-px window (%s)" % layout_min)


func check_outline_parse() -> void:
	var s: Dictionary = LayerEngine._parse_structure(BLOCKS)
	var levels: Array = s.headings.map(func(h) -> int: return int(h.level))
	check(levels == [1, 4, 5, 6], "Outline lists H1 and H4–H6, not the front matter (%s)" % [levels])
	var fenced: Dictionary = LayerEngine._parse_structure("# Real\n````\n```\n# Not a heading\n```\n````\n## Also real")
	check(fenced.headings.map(func(h) -> String: return h.text) == ["Real", "Also real"] and fenced.code_blocks.size() == 1,
		"a ```` block with ``` lines inside hides its headings from Outline, as Read view does")
	var items: Array = s.lists.map(func(i) -> String: return "%s %s" % [i.marker, i.text])
	check(items.has("1. First step") and items.has("• nested child") and items.has("• open task"), "Outline lists numbered, nested and task items (%s)" % [items])


const TABLE: String = """# Tables
| Shape | Sides | Link |
|:------|:-----:|-----:|
| Triangle | 3 | [[Linked Note]] |
| Square \\| box | **4** | [site](https://example.com) |

| not a table, no rule under it |
```
| fenced | table |
|---|---|
```
| Extra | cells |
|---|---|
| one | two | dropped |
| short |
| [[Linked Note|the note]] | x |
| A long cell that says a great deal more than fits on one short line of a table | y |"""


func tables() -> Array:
	return LayerEngine._visual_vbox.get_children().filter(func(c) -> bool: return c is ScrollContainer and c.name.begins_with("Table"))


func grid_of(table: Node) -> GridContainer:
	var grids: Array = find_all(table, "GridContainer")
	return grids[0] if grids.size() == 1 else null


func cell_texts(grid: GridContainer) -> Array:
	return grid.get_children().map(func(c) -> String: return (c as RichTextLabel).text)


## A 3x3 pipe table: a GridContainer of 3 columns and 9 cells in a CardPanel,
## bold header, :--: alignment, links in cells; a fenced table stays code.
func check_tables() -> void:
	await open_note("Table Note", TABLE)
	var found: Array = tables()
	check(found.size() == 2, "two pipe tables render (the fenced one and the '|' line without a rule do not) (%d)" % found.size())
	if found.size() != 2:
		return
	var grid: GridContainer = grid_of(found[0])
	check(grid != null and grid.columns == 3 and grid.get_child_count() == 9, "the 3x3 table is a GridContainer with 3 columns and 9 cells (%s)"
		% ("%d columns, %d cells" % [grid.columns, grid.get_child_count()] if grid != null else "no grid"))
	if grid == null or grid.get_child_count() != 9:
		return
	check(grid.get_parent() is PanelContainer and (grid.get_parent() as PanelContainer).theme_type_variation == &"CardPanel",
		"the grid sits on a CardPanel")
	var cells: Array = cell_texts(grid)
	check(str(cells[0]).contains("[b]Shape[/b]") and str(cells[2]).contains("[b]Link[/b]") and not str(cells[3]).contains("[b]"),
		"header cells are bold, body cells are not")
	check(str(cells[1]).begins_with("[center]") and str(cells[5]).begins_with("[right]") and not str(cells[3]).begins_with("["),
		":-: centres a column, --: right-aligns it, :-- stays left")
	check(str(cells[5]).contains("[url=0]") and LayerEngine.link_targets(grid.get_child(5)) == ["Linked Note"], "a cell holding [[Linked Note]] has a [url] link (%s)" % cells[5])
	check(str(cells[6]) == "Square | box" and str(cells[7]).contains("[b]4[/b]") and str(cells[8]).contains("[url=https://example.com]"),
		"\\| is a literal pipe; emphasis and web links work in cells (%s)" % [cells.slice(6, 9)])
	var link_cell: RichTextLabel = grid.get_child(5)
	link_cell.meta_clicked.emit("0")
	check(app.current_note != null and app.current_note.title == "Linked Note", "clicking a [[link]] in a cell opens the note")
	app.open_note_by_title("Table Note")
	app._switch_layer("visual")
	await frames(4)
	found = tables()
	check(row_with("not a table, no rule under it") != null, "a '|' line with no |---| row under it stays text")
	var codes: Array = find_all(LayerEngine._visual_vbox, "CodeEdit").filter(func(c) -> bool: return (c as CodeEdit).text.contains("| fenced | table |"))
	check(codes.size() == 1, "a table inside ``` stays code")
	var extra: GridContainer = grid_of(found[1]) if found.size() == 2 else null
	var extra_cells: Array = cell_texts(extra) if extra != null else []
	check(extra != null and extra.columns == 2 and extra_cells.slice(0, 6) == ["[b]Extra[/b]", "[b]cells[/b]", "one", "two", "short", ""],
		"rows pad short and drop extra cells to the header's columns (%s)" % [extra_cells])
	check(extra_cells.size() == 10 and str(extra_cells[6]).contains("[url=0]") and LayerEngine.link_targets(extra.get_child(6)) == ["Linked Note"] and str(extra_cells[6]).contains("the note") and extra_cells[7] == "x",
		"the pipe in a [[Note|shown text]] cell does not split the cell (%s)" % [extra_cells.slice(6, 8)])
	if extra != null and extra.get_child_count() == 10:
		var long_cell: RichTextLabel = extra.get_child(8)
		var short_cell: RichTextLabel = extra.get_child(2)
		check(long_cell.autowrap_mode != TextServer.AUTOWRAP_OFF and is_equal_approx(long_cell.size.x, LayerEngine.TABLE_CELL_MAX_W)
			and long_cell.get_line_count() > 1, "a long cell wraps at %d px instead of widening the table (%s, %d lines)" % [LayerEngine.TABLE_CELL_MAX_W, long_cell.size, long_cell.get_line_count()])
		check(short_cell.autowrap_mode == TextServer.AUTOWRAP_OFF and short_cell.get_line_count() == 1, "a short cell stays on one line")
	await shot("markdown_table")


## A `[[` in a code span opens no link (Read view and WikiLinks show it as
## code), so the "|" after it still splits the row: "| `[[` | opens |" was
## one cell "`[[` | opens" and an empty one.
func check_table_code_cells() -> void:
	var cells: Array = Array(LayerEngine._table_cells("| `[[` | opens a link |"))
	check(cells == ["`[[`", "opens a link"], "a code span's [[ doesn't hold the cell open (%s)" % [cells])
	cells = Array(LayerEngine._table_cells("| `[[x` | [[Note|shown]] | z |"))
	check(cells == ["`[[x`", "[[Note|shown]]", "z"], "…and a real [[Note|shown]] after it still keeps its pipe (%s)" % [cells])
	await open_note("Code Table", "| A | B |\n|---|---|\n| `[[` | opens |\n| x | y |")
	var found: Array = tables()
	var grid: GridContainer = grid_of(found[0]) if found.size() == 1 else null
	var texts_now: Array = cell_texts(grid) if grid != null else []
	check(texts_now == ["[b]A[/b]", "[b]B[/b]", "[code][lb][lb][/code]", "opens", "x", "y"], "the row renders as two cells (%s)" % [texts_now])


## A 12-column table keeps the window within 820 px and scrolls sideways;
## the wheel over it still scrolls the page.
func check_wide_table() -> void:
	var head: PackedStringArray = []
	var rule: PackedStringArray = []
	var row: PackedStringArray = []
	for c in range(12):
		head.append("Column %d" % (c + 1))
		rule.append("---")
		row.append("value number %d" % (c + 1))
	var filler: String = "\n".join(range(40).map(func(n) -> String: return "Filler paragraph %d so the page scrolls." % n))
	var text: String = "# Wide\n%s\n| %s |\n| %s |\n| %s |\n| %s |\n%s" % [filler, " | ".join(head), " | ".join(rule), " | ".join(row), " | ".join(row), filler]
	await open_note("Wide Table", text)
	var found: Array = tables()
	check(found.size() == 1 and grid_of(found[0]) != null and grid_of(found[0]).columns == 12, "the 12-column table renders")
	if found.size() != 1:
		return
	var table: ScrollContainer = found[0]
	var layout_min: Vector2 = app.get_node("AppLayout").get_combined_minimum_size()
	check(layout_min.x <= 820, "the window's combined minimum width stays <= 820 with a 12-column table (%s)" % layout_min)
	check(table.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO, "the table scrolls sideways (AUTO)")
	var card: Control = table.get_child(0)
	check(card.size.x > table.size.x and table.get_h_scroll_bar().visible, "the table is wider than the page and shows its own scrollbar (%s in %s)" % [card.size, table.size])
	check(table.size.y >= card.size.y, "the scrollbar does not cover the last row")
	check(not app.doc_scroll.get_h_scroll_bar().visible, "the page itself never scrolls sideways")
	# The wheel over the table scrolls the page, not the table
	var ds: ScrollContainer = app.doc_scroll
	ds.scroll_vertical = 0
	await frames(2)
	ds.scroll_vertical = int(table.global_position.y - ds.global_position.y) - 40
	await frames(2)
	var before: int = ds.scroll_vertical
	var pos: Vector2 = grid_of(table).get_child(14).get_global_rect().get_center()
	check(ds.get_global_rect().has_point(pos), "a table cell is on screen to wheel over")
	wheel(pos, MOUSE_BUTTON_WHEEL_DOWN, false)
	await frames(3)
	check(ds.scroll_vertical > before and table.scroll_horizontal == 0, "the wheel over a table scrolls the page (%d -> %d), not the table (%d)" % [before, ds.scroll_vertical, table.scroll_horizontal])
	pos = grid_of(table).get_child(14).get_global_rect().get_center()
	wheel(pos, MOUSE_BUTTON_WHEEL_DOWN, true)
	await frames(3)
	check(table.scroll_horizontal > 0, "Shift+wheel scrolls the table sideways (%d)" % table.scroll_horizontal)
	await shot("markdown_wide_table")


func wheel(pos: Vector2, button: MouseButton, shift: bool) -> void:
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = button
		e.pressed = pressed
		e.shift_pressed = shift
		e.factor = 1.0
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)


## A note that opens with a rule and prose is not front matter.
func check_not_front_matter() -> void:
	await open_note("Rule First", "---\nJust prose after a rule.\n---\nMore.")
	var vbox: VBoxContainer = LayerEngine._visual_vbox
	check(vbox.get_children().filter(func(c) -> bool: return c is PanelContainer and c.theme_type_variation == &"FrontMatterPanel").is_empty()
		and vbox.get_children().filter(func(c) -> bool: return c is HSeparator).size() == 2,
		"--- then prose then --- is two rules, not front matter")


## The renderer and JourneyStore.scene_blocks agree on every seeded note, so
## tutorial_test and the scene3d snapshot see the same cards as before.
func check_scene_cards_unchanged() -> void:
	var bad: Array = []
	var total: int = 0
	for n in VaultStore.note_list.duplicate():
		app.open_note_by_title(n.title)
		app._switch_layer("visual")
		await frames(1)
		var cards: int = LayerEngine._visual_vbox.get_children().filter(func(c) -> bool: return c is NoteScene3D).size()
		var want: int = JourneyStore.scene_blocks(n.raw_text).size()
		total += cards
		if cards != want:
			bad.append("%s: %d cards, %d blocks" % [n.title, cards, want])
	check(bad.is_empty() and total > 10, "every seeded note renders one card per 3D block (%d cards) %s" % [total, bad])
