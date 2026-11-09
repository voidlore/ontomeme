class_name LayerEngine
extends Node
## LayerEngine — multi-mode note rendering (raw, structured, visual, graph).
##
## A self-contained rendering engine. Owns all parsing, layout, and rendering
## of ContentLayer notes. Expects node references wired via set_node_refs().
##
## Usage:
##     LayerEngine.set_note(note)
##     LayerEngine.set_mode("structured")
##     var content := LayerEngine.get_rendered_content("structured")
##     LayerEngine.render_graph(nodes, edges, canvas)

const MODE_RAW: String = "raw"
const MODE_STRUCTURED: String = "structured"
const MODE_VISUAL: String = "visual"

## Tallest a Read-view image grows, in px; a taller one scales down to fit.
const MAX_IMAGE_HEIGHT: float = 480.0
## Largest Outline thumbnail, in px; a smaller image keeps its own size.
const THUMB_SIZE: Vector2 = Vector2(128, 64)
## Read-view lists: px per nesting level, and the column the marker (•, 12.
## or a checkbox) hangs in, so wrapped lines line up under the item's text.
const LIST_INDENT: float = 24.0
const LIST_MARKER_W: float = 30.0
const LIST_MAX_DEPTH: int = 8
## Link schemes a click hands to the OS (browser, mail app). Any other
## [text](url) stays as written, unlinked: no javascript:, file: or app links.
const WEB_SCHEMES: Array[String] = ["http://", "https://", "mailto:"]
## Body text size in Read view (AppTheme BodyLabel / RichTextLabel).
const BODY_FONT_SIZE: int = 15
## A table cell's text wraps past this width; a table wider than the page
## scrolls sideways.
const TABLE_CELL_MAX_W: float = 260.0

static var current_mode: String = MODE_RAW
static var current_note: ContentLayer = null

# Render layer references (set by note.gd via set_node_refs)
static var _raw_label: TextEdit = null
static var _structured_vbox: VBoxContainer = null
static var _visual_vbox: VBoxContainer = null

## What _open_link hands a web or mail link to (OS.shell_open). Tests swap
## in a recorder to check which clicks reach the OS.
static var _os_open: Callable = Callable(OS, "shell_open")

# Cached rendering data
static var _render_data: Dictionary = {}
## The vault's title index (WikiLinks.title_index) for the Read view build
## in progress: _render_visual builds it once for every link and the
## "Linked from" list, and the build lets it go when it ends (_finish_build,
## _drop_build). Outside a build it is not ready.
static var _titles: Dictionary = {}
static var _titles_ready: bool = false
static var _rx_cache: Dictionary = {}   # pattern -> compiled RegEx

# Graph color palette
static var _graph_color_palette: Array[Color] = [
	Color(0.9, 0.5, 0.15),  # accent/orange
	Color(0.2, 0.7, 0.5),   # teal
	Color(0.5, 0.3, 0.8),   # purple
	Color(0.8, 0.3, 0.3),   # red
	Color(0.3, 0.6, 0.9),   # blue
	Color(0.7, 0.7, 0.2),   # yellow
	Color(0.9, 0.3, 0.7),   # pink
	Color(0.4, 0.8, 0.4),   # green
]


func _ready() -> void:
	pass


static func set_node_refs(raw: TextEdit, structured: VBoxContainer, visual: VBoxContainer) -> void:
	"""Called by note.gd to wire up the three render layers."""
	_raw_label = raw
	_structured_vbox = structured
	_visual_vbox = visual
	_drop_build()   # a new window: nothing in it is built yet


static func set_mode(mode: String) -> void:
	"""Switch rendering mode."""
	current_mode = mode
	_show_layer(mode)
	_render_current_mode()


static func set_note(note: ContentLayer, render: bool = true) -> void:
	"""Set the note content for rendering, re-rendering immediately in current mode
	(unless `render` is false: a mode switch renders the new mode itself)."""
	current_note = note
	if note != null:
		_render_data = _parse_structure(note.raw_text)
	if render:
		_render_current_mode()


static func get_rendered_content(mode: String) -> String:
	"""Return the rendered content as a formatted string for the given mode."""
	if current_note == null:
		return ""
	match mode:
		MODE_RAW:
			return current_note.raw_text
		MODE_STRUCTURED:
			return _get_structured_content()
		MODE_VISUAL:
			return _get_visual_content()
	return ""


static func render_graph(graph_nodes: Dictionary, graph_edges: Array, canvas: Control, canvas_size: Vector2) -> void:
	"""Draw a force-directed graph on the given canvas."""
	if canvas == null or graph_nodes.is_empty():
		return
	canvas.clear()
	_layout_nodes(graph_nodes, graph_edges, canvas_size)
	# Draw edges first (behind nodes)
	for edge in graph_edges:
		var from_key: String = str(edge.from)
		var to_key: String = str(edge.to)
		if not graph_nodes.has(from_key) or not graph_nodes.has(to_key):
			continue
		var from_node: Dictionary = graph_nodes[from_key]
		var to_node: Dictionary = graph_nodes[to_key]
		if from_node.is_empty() or to_node.is_empty():
			continue
		canvas.add_line(from_node.pos, to_node.pos, Color(0.3, 0.3, 0.35, 0.6), 1.5)
	# Draw nodes
	for key in graph_nodes:
		var node: Dictionary = graph_nodes[key]
		if node.is_empty():
			continue
		var pos: Vector2 = node.pos
		var sz: Vector2 = node.size
		var title: String = node.title
		# Node rectangle (rounded fill)
		canvas.add_rect(Rect2(pos, sz), node.color, 2.0, true)
		# Stroke outline
		canvas.add_rect(Rect2(pos, sz), Color(0.95, 0.95, 0.95, 0.3), 0.5, false)
		# Node title
		canvas.add_string(title, pos + Vector2(8, sz.y / 2.0 + 6),
			Color(0.95, 0.95, 0.95, 1.0), 14.0, HORIZONTAL_ALIGNMENT_LEFT, -1, 0)
		# Connection count badge (top-right)
		var conn_count: int = node.connections.size()
		if conn_count > 0:
			canvas.add_circle(pos + Vector2(sz.x - 14, 14), 10, node.color.darkened(0.3), true)
			canvas.add_string(str(conn_count), pos + Vector2(sz.x - 14, 14),
				Color(1.0, 1.0, 1.0, 1.0), 10.0, HORIZONTAL_ALIGNMENT_CENTER, -1, 0)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


static func _show_layer(mode: String) -> void:
	if mode == "":
		return
	# Hide all layers
	if _raw_label != null:
		_raw_label.visible = false
	if _structured_vbox != null:
		_structured_vbox.visible = false
	if _visual_vbox != null:
		_visual_vbox.visible = false
	# Show the active layer
	match mode:
		MODE_RAW:
			if _raw_label != null:
				_raw_label.visible = true
		MODE_STRUCTURED:
			if _structured_vbox != null:
				_structured_vbox.visible = true
		MODE_VISUAL:
			if _visual_vbox != null:
				_visual_vbox.visible = true


static func _render_current_mode() -> void:
	if current_note == null:
		return
	match current_mode:
		MODE_RAW:
			_render_raw()
		MODE_STRUCTURED:
			_render_structured()
		MODE_VISUAL:
			_render_visual()


static func _render_raw() -> void:
	if _raw_label == null or current_note == null:
		return
	if _raw_label.text != current_note.raw_text:
		_raw_label.text = current_note.raw_text


static func _label(text: String, variation: StringName, wrap: bool = true) -> Label:
	# Typography comes from the app Theme (AppTheme) via type variations, so
	# rendered notes follow dark/light mode with no hardcoded colours here.
	var label := Label.new()
	label.text = text
	label.theme_type_variation = variation
	if wrap:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


static func _accent() -> Color:
	var scene: Node = _visual_vbox
	while scene != null and not ("_palette_colors" in scene):
		scene = scene.get_parent()
	if scene != null and scene._palette_colors.has("accent"):
		return scene._palette_colors.accent
	return Color("d97757")


static func _linked_paragraph(line: String) -> RichTextLabel:
	# [[Wikilinks]] become accent-coloured, clickable links (Obsidian style).
	var targets: Array[String] = []
	return _linked_rich(_rich_bbcode(line, targets), targets)


## A Markdown line as BBCode: `code spans` stay literal, the rest gets links
## and emphasis (_web_links_and_md). Each [[link]] appends the title it opens
## to `targets` (see _links_and_md): pass one array per row, and build the
## row with _linked_rich.
static func _rich_bbcode(line: String, targets: Array[String]) -> String:
	var accent: Color = _accent()
	var out: String = ""
	var last: int = 0
	for m in _rx("`([^`]+)`").search_all(line):
		out += _web_links_and_md(line.substr(last, m.get_start() - last), accent, targets)
		out += "[code]" + m.get_string(1).replace("[", "[lb]") + "[/code]"
		last = m.get_end()
	return out + _web_links_and_md(line.substr(last), accent, targets)


## A RichTextLabel showing BBCode `bb` whose [url] links open (_open_link):
## [url=i] the note targets[i] (made by _links_and_md), or creates it when no
## note has that title; a web or mail [url] in the OS.
static func _linked_rich(bb: String, targets: Array[String]) -> RichTextLabel:
	var rtl := _rich_row(bb)
	rtl.set_meta(&"link_targets", targets)
	rtl.meta_clicked.connect(func(meta: Variant) -> void: _open_link(rtl, meta, targets))
	return rtl


## A Read view row of BBCode `bb` built by _links_and_md (see _linked_rich).
static func _link_row(bb: String, targets: Array[String]) -> RichTextLabel:
	return _linked_rich(bb, targets)


## The titles the [[links]] in a Read view row open, in the order they show
## (empty for a row without links). Tests read it.
static func link_targets(row: Node) -> Array[String]:
	var out: Array[String] = []
	if row != null and row.has_meta(&"link_targets"):
		out.assign(row.get_meta(&"link_targets"))
	return out


## A wrapping, auto-height RichTextLabel showing BBCode `bb`.
static func _rich_row(bb: String) -> RichTextLabel:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.scroll_active = false
	rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rtl.mouse_default_cursor_shape = Control.CURSOR_ARROW
	rtl.text = bb
	return rtl


## The main window (note.gd) above `node`, which opens notes; null outside it.
static func _app_of(node: Node) -> Node:
	while node != null and not node.has_method("open_note_by_title"):
		node = node.get_parent()
	return node


## A clicked [url] in a row whose [[links]] open `targets`: an index is a
## [[link]] (the note targets[i]); a web or mail link opens in the OS. A
## title is never the meta itself: titles are free text, and a '"' or ']'
## in a [url=title] tag broke it.
static func _open_link(from: Node, meta: Variant, targets: Array[String]) -> void:
	var href: String = str(meta)
	if href.is_valid_int():
		var i: int = int(href)
		var app: Node = _app_of(from)
		if app != null and i >= 0 and i < targets.size():
			app.open_note_by_title(targets[i], true)
		return
	if is_web_link(href):
		_os_open.call(href)


## True for a link Read view may hand to the OS: http, https or mailto with
## something after the scheme. javascript:, file:, data: and the rest are not.
static func is_web_link(href: String) -> bool:
	var h: String = href.strip_edges().to_lower()
	for scheme in WEB_SCHEMES:
		if h.begins_with(scheme) and h.length() > scheme.length():
			return true
	return false


## [text](url) and bare http(s) URLs as accent [url] links, the rest through
## _links_and_md ([[links]], emphasis, appending to `targets`). [[links]] and
## ![images](…) are left whole for _links_and_md; a [text](url) whose scheme
## isn't a web one (is_web_link) stays as written.
static func _web_links_and_md(text: String, accent: Color, targets: Array[String]) -> String:
	var out: String = ""
	var plain: String = ""   # text not yet passed through _links_and_md
	var last: int = 0
	for m in _rx(_WEB_LINK_RX).search_all(text):
		plain += text.substr(last, m.get_start() - last)
		last = m.get_end()
		var url: String = m.get_string(3) if m.get_string(3) != "" else m.get_string(4)
		var tail: String = ""
		if m.get_string(4) != "":
			tail = _url_tail(url)
			url = url.left(url.length() - tail.length())
		if m.get_string(1) != "" or not is_web_link(url) or url.contains("[") or url.contains("]"):
			plain += m.get_string(0)
			continue
		var shown: String = _inline_md(m.get_string(2)) if m.get_string(3) != "" else url.replace("[", "[lb]")
		out += _links_and_md(plain, accent, targets)
		# BBCode reads ' and " in a tag as quotes: "Ohm's_law" ended the tag
		# and hid the link (and the rest of a merged label showed raw BBCode)
		out += "[url=%s][color=#%s]%s[/color][/url]" % [url.replace("'", "%27").replace("\"", "%22"), accent.to_html(false), shown]
		plain = tail
	return out + _links_and_md(plain + text.substr(last), accent, targets)


## Group 1: a [[link]] or an ![image](…), kept for _links_and_md. Groups 2
## and 3: [text](url), the url allowing one level of (parentheses). Group 4:
## a bare http(s) URL, ' and " included ("/wiki/Ohm's_law"; a quote around
## the URL is left to _url_tail).
const _WEB_LINK_RX: String = "(\\[\\[[^\\]]*\\]\\]|!\\[[^\\[\\]]*\\]\\([^)\\s]*\\))" \
	+ "|\\[([^\\[\\]]+)\\]\\(((?:[^()\\s]|\\([^()\\s]*\\))+)\\)" \
	+ "|(https?://[^\\s<>\\[\\]`*]+)"


## Punctuation that ends a sentence rather than a bare URL: trailing . , ; :
## ! ? quotes, and a ) with no ( to close inside the URL.
static func _url_tail(url: String) -> String:
	var end: int = url.length()
	while end > 0:
		var c: String = url[end - 1]
		if c in [".", ",", ";", ":", "!", "?", "'", "\""]:
			end -= 1
		elif c == ")" and url.left(end).count("(") < url.left(end).count(")"):
			end -= 1
		else:
			break
	return url.substr(end)


## A RegEx for `pattern`, compiled once per run.
static func _rx(pattern: String) -> RegEx:
	if not _rx_cache.has(pattern):
		var rx := RegEx.new()
		rx.compile(pattern)
		_rx_cache[pattern] = rx
	return _rx_cache[pattern]


## [[Links]] in a code-free piece of text, parsed by WikiLinks. Each link
## appends the title it opens (the resolved note's, else the base title
## without "#heading") to `targets`, and its url meta is only that index:
## titles are free text, and a '"' in a [url=title] tag ended or unquoted it
## (the link vanished, or a click created a junk note). Pass one `targets`
## per row and build the row with _linked_rich. The shown text is the alias
## or the whole link text.
static func _links_and_md(text: String, accent: Color, targets: Array[String]) -> String:
	var spans: Array[Dictionary] = WikiLinks.link_spans(text)
	var titles: Dictionary = _link_titles() if not spans.is_empty() else {}
	var out: String = ""
	var last: int = 0
	for span in spans:
		out += _inline_md(text.substr(last, int(span.start) - last))
		var shown: String = str(span.alias) if str(span.alias) != "" else str(span.text)
		out += _note_link(WikiLinks.link_title(span, titles), shown, accent, targets)
		last = int(span.end)
	return out + _inline_md(text.substr(last))


## A link to the note titled `target` as BBCode: its progress mark, then
## `shown` (escaped) as an accent [url] whose meta is the index `target` gets
## in `targets` (appended here). For a title already known (the review
## banner's quiz note), call it directly: "[[%s]]" % title parses back wrong
## for a title with "[", "]" or "|".
static func _note_link(target: String, shown: String, accent: Color, targets: Array[String]) -> String:
	var mark: String = ""
	match ProgressStore.status(target):
		"done": mark = "[color=#3ddc84]✓[/color] "
		"review": mark = "[color=#f0a040]●[/color] "
	targets.append(target)
	return "%s[url=%d][color=#%s]%s[/color][/url]" % [mark, targets.size() - 1, accent.to_html(false), shown.replace("[", "[lb]")]


## The title index links resolve against: the current render's, built once
## per _render_visual; a fresh one outside a render.
static func _link_titles() -> Dictionary:
	return _titles if _titles_ready else WikiLinks.title_index()


## Escape BBCode, then render **bold**, *italic* and `code` spans.
static func _inline_md(text: String) -> String:
	var t: String = text.replace("[", "[lb]")
	var rx := RegEx.new()
	rx.compile("`([^`]+)`")
	t = rx.sub(t, "[code]$1[/code]", true)
	rx.compile("\\*\\*([^*]+)\\*\\*")
	t = rx.sub(t, "[b]$1[/b]", true)
	rx.compile("(?<![\\w*])\\*([^*\\s][^*]*)\\*(?![\\w*])")
	t = rx.sub(t, "[i]$1[/i]", true)
	return t


static func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size.y = h
	return c


static func _render_structured() -> void:
	if _structured_vbox == null or current_note == null:
		return
	_clear_structured_vbox()
	var structure: Dictionary = _render_data
	var headings: Array = structure.get("headings", [])
	var lists: Array = structure.get("lists", [])
	var blocks: Array = structure.get("code_blocks", [])
	var images: Array = structure.get("images", [])
	if not headings.is_empty():
		_structured_vbox.add_child(_label("OUTLINE", &"SectionLabel", false))
		for heading in headings:
			var level: int = int(heading["level"])
			var row := _label(heading["text"], [&"H2Label", &"H2Label", &"H3Label", &"BodyLabel"][clampi(level, 1, 3)])
			row.add_theme_constant_override("line_spacing", 2)
			_make_jump_row(row, int(heading["line"]))
			var indent := MarginContainer.new()
			indent.add_theme_constant_override("margin_left", (level - 1) * 20)
			indent.add_child(row)
			_structured_vbox.add_child(indent)
	if not lists.is_empty():
		_structured_vbox.add_child(_spacer(8))
		_structured_vbox.add_child(_label("LIST ITEMS", &"SectionLabel", false))
		for item in lists:
			_structured_vbox.add_child(_label(str(item["marker"]) + "  " + str(item["text"]), &"BulletLabel"))
	if not blocks.is_empty():
		_structured_vbox.add_child(_spacer(8))
		_structured_vbox.add_child(_label("CODE", &"SectionLabel", false))
		for cb in blocks:
			var code_edit := CodeEdit.new()
			code_edit.text = cb["text"]
			code_edit.editable = false
			code_edit.scroll_fit_content_height = true
			code_edit.custom_minimum_size.y = 60
			_structured_vbox.add_child(code_edit)
	if not images.is_empty():
		_structured_vbox.add_child(_spacer(8))
		_structured_vbox.add_child(_label("IMAGES (%d)" % images.size(), &"SectionLabel", false))
		for ref in images:
			_structured_vbox.add_child(_image_row(ref))
	if headings.is_empty() and lists.is_empty() and blocks.is_empty() and images.is_empty():
		_structured_vbox.add_child(_label("No headings, lists or code blocks yet.", &"MutedLabel"))
		_structured_vbox.add_child(_label("Start a line with # for a heading or - for a list item.", &"FaintLabel"))


## An Outline heading row that jumps to its source line: a click edits the
## note there (note.gd jump_to_line), Shift+click reads it scrolled there.
## The row keeps its Label look; it only takes the mouse.
static func _make_jump_row(row: Control, line: int) -> void:
	row.set_meta("source_line", line)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	row.tooltip_text = "Click to edit here  ·  Shift+click to read here"
	row.gui_input.connect(func(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		# Act on release over the row, like a button
		if mb == null or mb.button_index != MOUSE_BUTTON_LEFT or mb.pressed \
				or not Rect2(Vector2.ZERO, row.size).has_point(mb.position):
			return
		row.accept_event()
		var app: Node = _app_of(row)
		if app != null and app.has_method("jump_to_line"):
			app.jump_to_line(line, mb.shift_pressed))


## Read view builds a long note over several frames, so the window never
## freezes: the first call builds at least FIRST_BUILD_LINES source lines
## (every tutorial and course note is shorter, so they show whole at once),
## or fewer once they hold FIRST_BUILD_CHARS characters of paragraph text
## (more than a screenful: a book's long paragraphs), and goes on until
## FIRST_BUILD_USEC of work; each later frame adds up to
## CHUNK_BUILD_USEC more until the note is done. Paragraph text is laid out
## after the build, later in the frame, so it counts TEXT_COST_USEC per
## character (generous: measured headless, a 3000-paragraph note's first
## frame took ~40 ms and the next 34 frames under 10 ms each).
const FIRST_BUILD_LINES: int = 200
const FIRST_BUILD_CHARS: int = 20000
const FIRST_BUILD_USEC: int = 30000
const CHUNK_BUILD_USEC: int = 20000
const TEXT_COST_USEC: float = 2.0
## Plain paragraphs in a row merge into one RichTextLabel of about this many
## characters (fewer controls to build and lay out). A run of paragraphs
## splits at a blank line past MERGE_MAX_CHARS, and at any line past
## MERGE_HARD_MAX_CHARS (one huge paragraph).
const MERGE_MAX_CHARS: int = 2000
const MERGE_HARD_MAX_CHARS: int = 8000
## Space between paragraphs in a merged label (its paragraph_separation):
## what a blank line's spacer and the VisualLayer separation around it make
## between separate rows.
const PARAGRAPH_GAP: int = 12


## Where a Read-view build stands: the note's lines, the next line to do,
## an open fence, the open list levels, and plain paragraphs waiting to be
## merged into one label (_add_paragraph_line, _flush_paragraphs).
class VisualBuild extends RefCounted:
	var note: ContentLayer = null
	var lines: PackedStringArray = []
	var empty: bool = false             # the note has no text at all
	var i: int = 0
	var fence_len: int = 0              # backticks of the open fence; 0 = prose
	var fence_info: String = ""
	var code_lines: Array[String] = []
	var list_indents: Array[int] = []   # leading spaces of each open list level
	var para_bb: String = ""            # BBCode of the waiting paragraphs
	var para_targets: Array[String] = []   # what their [[links]] open (_linked_rich)
	var para_first: String = ""         # the first waiting line, as written
	var para_lines: int = 0             # text lines waiting
	var para_chars: int = 0
	var blanks: int = 0                 # blank lines after the last waiting line
	var cost: float = 0.0               # usec of text layout queued (TEXT_COST_USEC)


## The build in progress, or null when Read view is complete.
static var _build: VisualBuild = null
static var _chunk_queued: bool = false
## What the shown Read view was built from (_visual_key_of); rendering the
## same again keeps it. "" = rebuild on the next render.
static var _visual_key: String = ""


## The notes the Read view being built lists under "LINKED FROM"
## (_add_backlinks), found once per render with its title index.
static var _backlinks: Array[ContentLayer] = []


## Read view of current_note. Skipped when nothing it is built from has
## changed since the last render (a paused build carries on instead); its
## objective chips are redrawn from the Journey either way.
static func _render_visual() -> void:
	if _visual_vbox == null or current_note == null:
		return
	var titles: Dictionary = WikiLinks.title_index()   # one walk of the vault per render
	var from: Array[ContentLayer] = WikiLinks.backlinks(current_note, titles)
	var key: String = _visual_key_of(current_note, from)
	if key == _visual_key:
		if _build != null:
			_queue_chunk()   # paused while Read view was hidden
		refresh_objective_chips()   # not in the key: they read the Journey as it is now
		return
	_visual_key = key
	_build = null
	_clear_visual_vbox()
	_quiz_counter = 0
	_cards_counter = 0
	_titles = titles
	_titles_ready = true
	_backlinks = from
	_add_review_banner()
	var b := VisualBuild.new()
	b.note = current_note
	b.lines = current_note.raw_text.split("\n")
	b.empty = current_note.raw_text.strip_edges() == ""
	b.i = _front_matter_end(b.lines)
	if b.i > 0:
		_emit_front_matter(b.lines, b.i)
	_build = b
	_build_chunk(FIRST_BUILD_USEC, FIRST_BUILD_LINES, true, FIRST_BUILD_CHARS * TEXT_COST_USEC)


## Mark Read view out of date, so the next render rebuilds it even though
## the note's text is the same: quiz progress changed (link marks, the
## review banner). The view on screen stays as it is until then.
static func mark_visual_stale() -> void:
	_visual_key = ""


## Build the rest of a Read view still being built, now: through source
## line `through_line`, or to the end (-1). For callers that look a row
## up (visual_row_for_line, Journey's launch_activity).
static func finish_visual(through_line: int = -1) -> void:
	if _build == null:
		return
	if _build.note != current_note or not is_instance_valid(_visual_vbox):
		_drop_build()
		return
	var lines: int = _build.lines.size() if through_line < 0 else through_line + 1 - _build.i
	_build_chunk(-1, maxi(lines, 0), false)


## True while a long note's Read view is still being built.
static func is_building() -> bool:
	return _build != null


## Everything a Read view is built from: the vault, the note, its folder (an
## objective chip's topic), its text, its images' file times, the theme
## colours baked into links and checkboxes, and the notes linking here
## (`from`, its LINKED FROM rows: each one's title and folder). (Quiz
## progress marks it stale instead: mark_visual_stale.)
static func _visual_key_of(note: ContentLayer, from: Array[ContentLayer] = []) -> String:
	var parts: PackedStringArray = [VaultStore.vault_path, str(note.get_instance_id()), note.title, VaultStore.folder_of(note),
		_accent().to_html(), _muted_colour().to_html(), _palette_color("text_faint", Color("8a8a93")).to_html()]
	for n in from:
		parts.append("%d %s %s" % [n.get_instance_id(), n.title, VaultStore.folder_of(n)])
	if note.raw_text.contains("!["):
		for ref in ImageEmbeds.refs_in(note.raw_text):
			var path: String = ImageEmbeds.resolve(ref.target, VaultStore.vault_path)
			parts.append(str(FileAccess.get_modified_time(path)) if path != "" and FileAccess.file_exists(path) else "-")
	parts.append(note.raw_text)
	return "\n".join(parts)


## Build from where the build stands: at least `min_lines` source lines
## (fewer once `min_cost` usec of text is queued), then on while under
## `budget_usec` of work (-1: just those lines). Then finish, or carry on
## next frame (`queue`).
static func _build_chunk(budget_usec: int, min_lines: int = 0, queue: bool = true, min_cost: float = INF) -> void:
	var b: VisualBuild = _build
	if b == null:
		return
	var t0: int = Time.get_ticks_usec()
	var stop_at: int = b.i + min_lines
	b.cost = 0.0
	while b.i < b.lines.size():
		if (b.i >= stop_at or b.cost >= min_cost) \
				and (budget_usec < 0 or Time.get_ticks_usec() - t0 + int(b.cost) >= budget_usec):
			break
		_build_next(b)
	if b.i >= b.lines.size():
		_build = null
		_finish_build(b)
	elif queue:
		_queue_chunk()


## Build the next chunk on the next frame.
static func _queue_chunk() -> void:
	if _chunk_queued or _build == null:
		return
	if not _visual_vbox.is_inside_tree():
		_build_chunk(-1, _build.lines.size())   # no frames to spread it over
		return
	_chunk_queued = true
	_visual_vbox.get_tree().process_frame.connect(func() -> void:
		_chunk_queued = false
		_on_build_frame(), CONNECT_ONE_SHOT)


static func _on_build_frame() -> void:
	if _build == null:
		return
	if not is_instance_valid(_visual_vbox) or _build.note != current_note:
		_drop_build()
	elif _visual_vbox.is_visible_in_tree():
		_build_chunk(CHUNK_BUILD_USEC)
	# else Read view is hidden: the build waits, and the next render with
	# the same note resumes it (_render_visual)


## Forget a build that can't go on (another note, a freed view); the
## half-built view rebuilds on the next render.
static func _drop_build() -> void:
	_build = null
	_visual_key = ""
	_titles = {}
	_titles_ready = false
	_backlinks = []


## The end of the note: waiting paragraphs, a fence still open (still
## typing: show what's there), or the empty-note line.
static func _finish_build(b: VisualBuild) -> void:
	_flush_paragraphs(b)
	if b.fence_len > 0:
		_emit_fenced(b.fence_info, PackedStringArray(b.code_lines))
	if b.empty:
		_visual_vbox.add_child(_label("This note is empty.", &"MutedLabel"))
	_add_backlinks()
	_titles = {}
	_titles_ready = false
	_backlinks = []


## Build the next block: one line, or a whole table or quote.
static func _build_next(b: VisualBuild) -> void:
	var lines: PackedStringArray = b.lines
	var i: int = b.i
	var line: String = lines[i]
	var s: String = line.strip_edges()
	var ticks: int = _fence_ticks(s)
	b.i += 1
	if b.fence_len > 0:
		# A fence closes on a line of at least as many backticks, so a
		# ```` block can show ``` examples literally.
		if ticks >= b.fence_len and s.substr(ticks).strip_edges() == "":
			_emit_fenced(b.fence_info, PackedStringArray(b.code_lines))
			b.code_lines.clear()
			b.fence_len = 0
		else:
			b.code_lines.append(line)
		return
	if ticks > 0:
		_flush_paragraphs(b)
		b.fence_len = ticks
		b.fence_info = s.substr(ticks).strip_edges()
		return
	var item: Dictionary = _list_item(line)
	if item.is_empty() and s != "":
		b.list_indents.clear()   # any other block ends the list
	var image_ref: Dictionary = ImageEmbeds.parse_line(s)
	var table: bool = image_ref.is_empty() and _is_table_start(lines, i)
	var level: int = _heading_level(line)
	var rule: bool = _is_rule(s)
	if image_ref.is_empty() and not table and level == 0 and not rule \
			and not s.begins_with(">") and item.is_empty():
		_add_paragraph_line(b, line)   # text, or a blank line
		return
	_flush_paragraphs(b)
	if not image_ref.is_empty():
		_emit_image(image_ref, i)
	elif table:
		b.i = _emit_table(lines, i)
	elif level > 0:
		_emit_heading(line, level, i)
	elif rule:
		_visual_vbox.add_child(HSeparator.new())
	elif s.begins_with(">"):
		b.i = _emit_quote(lines, i)
	else:
		_emit_list_item(item, _list_depth(b.list_indents, int(item.indent)))


## A paragraph's text line or a blank line. Text lines wait in `b` with the
## single blank lines between them; two blank lines in a row, or a run past
## MERGE_MAX_CHARS at a blank line, sends the waiting ones out first. A
## blank line with nothing waiting is a spacer, as it always was.
static func _add_paragraph_line(b: VisualBuild, line: String) -> void:
	if line.strip_edges() == "":
		if b.para_lines == 0:
			_visual_vbox.add_child(_spacer(6))
		else:
			b.blanks += 1
		return
	if b.para_lines > 0 and (b.blanks >= 2 or (b.blanks == 1 and b.para_chars >= MERGE_MAX_CHARS)
			or b.para_chars >= MERGE_HARD_MAX_CHARS):
		_flush_paragraphs(b)
	var bb: String = _rich_bbcode(line, b.para_targets) if _needs_rich(line) else line.replace("[", "[lb]")
	if b.para_lines == 0:
		b.para_first = line
		b.para_bb = bb
	else:
		# [br] breaks the line inside a paragraph; \n starts the next one
		b.para_bb += ("\n" if b.blanks > 0 else "[br]") + bb
	b.para_lines += 1
	b.para_chars += line.length()
	b.blanks = 0


## Send out the waiting paragraph lines: one line alone as it always
## rendered (a Label, or a RichTextLabel for links and emphasis), several
## as one merged RichTextLabel ("merged_lines" meta: how many), where [br]
## breaks the lines of a paragraph and PARAGRAPH_GAP parts paragraphs, as
## separate rows looked. Links in it open like any other. Then the blank
## lines after them, less the one a merged label's paragraph gap stands in
## for.
static func _flush_paragraphs(b: VisualBuild) -> void:
	if b.para_lines == 0:
		return
	var spacers: int = b.blanks
	if b.para_lines == 1 and not _needs_rich(b.para_first):
		_add_label_row(b.para_first)
	elif b.para_lines == 1:
		_add_rich_row(b.para_bb, b.para_targets)
	else:
		_add_rich_row(b.para_bb, b.para_targets, b.para_lines)
		spacers -= mini(spacers, 1)
	for k in range(spacers):
		_visual_vbox.add_child(_spacer(6))
	b.cost += b.para_chars * TEXT_COST_USEC
	b.para_bb = ""
	b.para_targets = []   # a new array: the row just added keeps the old one
	b.para_first = ""
	b.para_lines = 0
	b.para_chars = 0
	b.blanks = 0


## A Read-view row of BBCode `bb` whose links open (_linked_rich). The
## text goes in once the label is in the tree and as wide as the column: a
## new label is 1 px wide, and wrapping its text at that width first (a
## column of single letters, tens of thousands of px tall) cost more than
## the real layout (measured headless).
static func _add_rich_row(bb: String, targets: Array[String], merged_lines: int = 0) -> RichTextLabel:
	var rtl: RichTextLabel = _linked_rich("", targets)
	if merged_lines > 0:
		rtl.add_theme_constant_override("paragraph_separation", PARAGRAPH_GAP)
		rtl.set_meta("merged_lines", merged_lines)
	_visual_vbox.add_child(rtl)
	_size_new_row(rtl)
	rtl.text = bb
	return rtl


## Give a row just added to Read view a real width before its text goes
## in: the column's, or, while the column has never been laid out (Read
## view hidden since the app started: 0 px wide), the window's. Any real
## width does; what costs is wrapping at 1 px. The VBox sets the exact
## width before the frame is drawn.
static func _size_new_row(row: Control) -> void:
	var w: float = _visual_vbox.size.x
	if w <= 0.0 and _visual_vbox.is_inside_tree():
		w = _visual_vbox.get_viewport_rect().size.x
	if w > 0.0:
		row.size = Vector2(w, 0.0)


## A Read-view row of plain `text` (a BodyLabel), put in the same way as
## _add_rich_row and for the same reason: given its text before it joins
## the tree, a Label wraps it at 1 px wide first, which for a paragraph of
## a few thousand characters cost ~5 ms (half a second for a book's first
## 100 paragraphs, measured headless).
static func _add_label_row(text: String) -> Label:
	var label: Label = _label("", &"BodyLabel")
	_visual_vbox.add_child(label)
	_size_new_row(label)
	label.text = text
	return label


## A line that needs a RichTextLabel: links, emphasis or code spans.
static func _needs_rich(line: String) -> bool:
	if line.contains("[[") or line.contains("*") or line.contains("`"):
		return true
	for m in _rx(_WEB_LINK_RX).search_all(line):
		if m.get_string(1) == "":
			return true
	return false


## 1–6 for a `#`…`######` heading line (the #s at the start, then a space),
## else 0.
static func _heading_level(line: String) -> int:
	var n: int = 0
	while n < line.length() and n < 7 and line[n] == "#":
		n += 1
	return n if n >= 1 and n <= 6 and line.length() > n and line[n] == " " else 0


## H1 / H2 / H3, and H4–H6 as H3, with the space above it Read view always
## had. `line_no` (the source line) lets Outline's Shift+click find it.
static func _emit_heading(line: String, level: int, line_no: int) -> void:
	var variation: StringName = [&"H1Label", &"H2Label", &"H3Label"][mini(level, 3) - 1]
	_visual_vbox.add_child(_spacer([6, 8, 4][mini(level, 3) - 1]))
	var label: Label = _label(line.substr(level + 1).strip_edges(), variation)
	label.set_meta("source_line", line_no)
	_visual_vbox.add_child(label)


## The Read-view row a source line rendered as (a heading), or null. A
## long note still being built is built through that line first, then as
## far past it as a first build goes (FIRST_BUILD_LINES lines, fewer when
## they hold FIRST_BUILD_CHARS of text: a view's worth), so there is room
## below for the row to scroll to the top of the view.
static func visual_row_for_line(line_no: int) -> Control:
	if _visual_vbox == null:
		return null
	finish_visual(line_no)
	if _build != null:
		_build_chunk(-1, FIRST_BUILD_LINES, false, FIRST_BUILD_CHARS * TEXT_COST_USEC)
	for c in _visual_vbox.get_children():
		if c is Control and int(c.get_meta("source_line", -1)) == line_no:
			return c
	return null


## `---`, `***` or `___` (three or more, spaces allowed between) alone on a line.
static func _is_rule(s: String) -> bool:
	return _rx("^([-*_])(\\s*\\1){2,}$").search(s) != null


## Consecutive `>` lines from `start` as one quote panel; returns the line
## after them. Nested `>>` markers fold into the one panel.
static func _emit_quote(lines: PackedStringArray, start: int) -> int:
	var parts: PackedStringArray = []
	var targets: Array[String] = []
	var i: int = start
	while i < lines.size() and lines[i].strip_edges().begins_with(">"):
		var body: String = lines[i].strip_edges()
		while body.begins_with(">"):
			body = body.substr(1).strip_edges()
		parts.append(_rich_bbcode(body, targets))
		i += 1
	var panel := PanelContainer.new()
	panel.name = "Quote"
	panel.theme_type_variation = &"QuotePanel"
	panel.add_child(_linked_rich("\n".join(parts), targets))
	_visual_vbox.add_child(panel, true)   # Quote, Quote2, …
	return i


## A pipe table starts at line `i`: it starts with `|`, and the next line is
## a |---|:-:| row with one cell per header cell.
static func _is_table_start(lines: PackedStringArray, i: int) -> bool:
	if i + 1 >= lines.size() or not lines[i].strip_edges().begins_with("|"):
		return false
	var aligns: Array[int] = _table_aligns(lines[i + 1])
	return not aligns.is_empty() and aligns.size() == _table_cells(lines[i]).size()


## A pipe table from `start` (header, |---| row, then every row starting
## with `|`): a GridContainer of cells on a CardPanel, inside a sideways
## ScrollContainer so a wide table scrolls instead of widening the page.
## Returns the line after the table.
static func _emit_table(lines: PackedStringArray, start: int) -> int:
	var aligns: Array[int] = _table_aligns(lines[start + 1])
	var grid := GridContainer.new()
	grid.columns = aligns.size()
	grid.add_theme_constant_override("h_separation", 20)
	grid.add_theme_constant_override("v_separation", 8)
	var rows: Array[PackedStringArray] = [_table_cells(lines[start])]
	var i: int = start + 2
	while i < lines.size() and lines[i].strip_edges().begins_with("|"):
		rows.append(_table_cells(lines[i]))
		i += 1
	for r in range(rows.size()):
		for c in range(aligns.size()):   # short rows pad, extra cells drop (as GitHub)
			grid.add_child(_table_cell(rows[r][c] if c < rows[r].size() else "", aligns[c], r == 0))
	var card := PanelContainer.new()
	card.theme_type_variation = &"CardPanel"
	card.add_child(grid)
	var scroll := ScrollContainer.new()
	scroll.name = "Table"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED   # as tall as the table
	scroll.gui_input.connect(func(event: InputEvent) -> void: _wheel_scrolls_page(scroll, event))
	scroll.add_child(card)
	_visual_vbox.add_child(scroll, true)   # Table, Table2, …
	return i


## One cell: links and emphasis as in a paragraph, bold in the header row,
## aligned as its column's |:-:| says. Short text stays on one line; text
## wider than TABLE_CELL_MAX_W wraps at that width.
static func _table_cell(text: String, align: int, header: bool) -> RichTextLabel:
	var targets: Array[String] = []
	var bb: String = _rich_bbcode(text, targets)
	if header:
		bb = "[b]%s[/b]" % bb
	match align:
		HORIZONTAL_ALIGNMENT_CENTER:
			bb = "[center]%s[/center]" % bb
		HORIZONTAL_ALIGNMENT_RIGHT:
			bb = "[right]%s[/right]" % bb
	var cell: RichTextLabel = _linked_rich(bb, targets)
	cell.size_flags_horizontal = Control.SIZE_FILL
	if _text_width(text) > TABLE_CELL_MAX_W:
		cell.custom_minimum_size.x = TABLE_CELL_MAX_W
	else:
		cell.autowrap_mode = TextServer.AUTOWRAP_OFF
	return cell


## A table row's cells, trimmed: the outer pipes go, `\|` is a literal pipe,
## and the pipe in a [[Note|shown text]] link doesn't split the cell. A "[["
## in a `code span` is code, not a link, so it holds no cell open.
static func _table_cells(line: String) -> PackedStringArray:
	var s: String = line.strip_edges().trim_prefix("|")
	if s.ends_with("|") and not s.ends_with("\\|"):
		s = s.left(-1)
	var cells: PackedStringArray = []
	var cell: String = ""
	var in_link: bool = false
	var code_end: int = -1   # the closing backtick of the `code span` k is in
	var k: int = 0
	while k < s.length():
		if s[k] == "\\" and k + 1 < s.length() and s[k + 1] == "|":
			cell += "|"
			k += 2
			continue
		if s[k] == "`" and k > code_end:
			var close: int = s.find("`", k + 1)
			if close > k + 1:   # a code span as _rich_bbcode finds one: `([^`]+)`
				code_end = close
		if k > code_end and s.substr(k, 2) in ["[[", "]]"]:
			in_link = s.substr(k, 2) == "[["
			cell += s.substr(k, 2)
			k += 2
			continue
		if s[k] == "|" and not in_link:
			cells.append(cell.strip_edges())
			cell = ""
			code_end = -1   # a cell renders on its own: no code span runs on into the next
		else:
			cell += s[k]
		k += 1
	cells.append(cell.strip_edges())
	return cells


## The columns' alignments from a |---|:--|:-:|--:| row, or [] if `line`
## isn't one.
static func _table_aligns(line: String) -> Array[int]:
	var aligns: Array[int] = []
	if not line.contains("|"):
		return aligns
	for c in _table_cells(line):
		if _rx("^:?-+:?$").search(c) == null:
			aligns.clear()
			return aligns
		if c.begins_with(":") and c.ends_with(":"):
			aligns.append(HORIZONTAL_ALIGNMENT_CENTER)
		elif c.ends_with(":"):
			aligns.append(HORIZONTAL_ALIGNMENT_RIGHT)
		else:
			aligns.append(HORIZONTAL_ALIGNMENT_LEFT)
	return aligns


## The wheel over a table scrolls the page like everywhere else in Read
## view; Shift+wheel or a sideways wheel scrolls the table. (A ScrollContainer
## with no vertical bar would turn the plain wheel sideways and keep it.)
static func _wheel_scrolls_page(table: ScrollContainer, event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.shift_pressed \
			or mb.button_index not in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		return
	var page: Node = table.get_parent()
	while page != null and not page is ScrollContainer:
		page = page.get_parent()
	if page == null:
		return
	var bar: VScrollBar = (page as ScrollContainer).get_v_scroll_bar()
	var step: float = bar.page / 8.0 * (mb.factor if mb.factor > 0.0 else 1.0)
	bar.value += -step if mb.button_index == MOUSE_BUTTON_WHEEL_UP else step
	table.accept_event()


## A list line: {indent (leading spaces, a tab = 4), kind ("bullet",
## "number" or "task"), marker ("3." / "3)" for numbers), checked, text}.
## Bullets are `- ` or `* `; tasks are `- [ ] ` / `- [x] `. {} otherwise.
static func _list_item(line: String) -> Dictionary:
	var m: RegExMatch = _rx("^([ \\t]*)([-*]|\\d{1,9}[.)])[ \\t]+(.*)$").search(line)
	if m == null or _is_rule(line.strip_edges()):
		return {}
	var item: Dictionary = {
		"indent": m.get_string(1).replace("\t", "    ").length(),
		"kind": "bullet" if m.get_string(2) in ["-", "*"] else "number",
		"marker": m.get_string(2),
		"checked": false,
		"text": m.get_string(3).strip_edges(),
	}
	var task: RegExMatch = _rx("^\\[([ xX])\\](?:[ \\t]+(.*))?$").search(item.text)
	if item.kind == "bullet" and task != null:
		item.kind = "task"
		item.checked = task.get_string(1) != " "
		item.text = task.get_string(2).strip_edges()
	return item


## Nesting depth of a list item indented `indent` spaces, given the open
## levels' indents (updated): deeper than the last level opens a new one,
## shallower closes levels down to the one it fits. Works for 2- or 4-space
## nesting alike.
static func _list_depth(indents: Array[int], indent: int) -> int:
	while not indents.is_empty() and indent < indents[-1]:
		indents.pop_back()
	if indents.is_empty() or indent > indents[-1]:
		indents.append(indent)
	return mini(indents.size() - 1, LIST_MAX_DEPTH)


## One list item: the text indented by its depth, its marker (•, the number
## as typed, or a read-only checkbox) hanging in the column before it, so
## wrapped lines line up under the text.
static func _emit_list_item(item: Dictionary, depth: int) -> void:
	var text: String = item.text
	var row: Control = _linked_paragraph(text) if _needs_rich(text) else _label(text, &"BulletLabel")
	var x: float = depth * LIST_INDENT
	var marker_w: float = LIST_MARKER_W
	var marker: Control
	if item.kind == "task":
		marker = _checkbox(bool(item.checked))
		marker.position = Vector2(x + marker_w - 24.0, (_line_height() - marker.size.y) / 2.0)
	else:
		var shown: String = "•" if item.kind == "bullet" else str(item.marker)
		var label: Label = _label(shown, &"BulletLabel", false)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		marker_w = maxf(marker_w, _text_width(shown) + 10.0)
		label.position = Vector2(x, 0)
		label.size = Vector2(marker_w - 8.0, _line_height())
		marker = label
	marker.name = "ListMarker"
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var margin := StyleBoxEmpty.new()
	margin.content_margin_left = x + marker_w
	row.add_theme_stylebox_override("normal", margin)
	row.set_meta("list_depth", depth)
	row.add_child(marker)
	_visual_vbox.add_child(row)


## A read-only checkbox, ticked or not, in the muted text colour.
static func _checkbox(checked: bool) -> TextureRect:
	var box := TextureRect.new()
	box.texture = Icons.get_icon("check_box_on" if checked else "check_box", 16)
	box.size = Vector2(16, 16)
	box.self_modulate = _muted_colour()
	box.tooltip_text = "Done" if checked else "To do"
	return box


## The theme's muted text colour (checkboxes).
static func _muted_colour() -> Color:
	if _visual_vbox != null and _visual_vbox.is_inside_tree():
		return _visual_vbox.get_theme_color("font_color", &"MutedLabel")
	return Color("9a9aa2")


## Height of one line of Read-view body text.
static func _line_height() -> float:
	return AppTheme.FONT_SANS.get_height(BODY_FONT_SIZE)


static func _text_width(text: String) -> float:
	return AppTheme.FONT_SANS.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, BODY_FONT_SIZE).x


## Index of the line after a YAML front matter block that opens the note
## (`---`, `key: value` lines, `---`), or 0 when the note doesn't open with
## one. A `---` rule followed by prose is not front matter.
static func _front_matter_end(lines: PackedStringArray) -> int:
	if lines.is_empty() or lines[0].strip_edges() != "---":
		return 0
	var keys: int = 0
	for j in range(1, lines.size()):
		var raw: String = lines[j]
		var s: String = raw.strip_edges()
		if s == "---" or s == "...":
			return j + 1 if keys > 0 else 0
		if s == "" or s.begins_with("#") or raw.begins_with(" ") or raw.begins_with("\t") or s.begins_with("- "):
			continue   # blank, comment, or a value continued from the key above
		if _rx("^[A-Za-z_][\\w .-]*:(\\s|$)").search(s) == null:
			return 0
		keys += 1
	return 0


## The front matter (lines 1 .. end-2) as a muted key / value box.
static func _emit_front_matter(lines: PackedStringArray, end: int) -> void:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 2)
	for pair in _front_matter_pairs(lines, end):
		var key: Label = _label(pair[0], &"FaintLabel", false)
		key.size_flags_horizontal = Control.SIZE_FILL   # keys hug their text; values take the rest
		grid.add_child(key)
		grid.add_child(_label(pair[1], &"MutedLabel"))
	var panel := PanelContainer.new()
	panel.name = "FrontMatter"
	panel.theme_type_variation = &"FrontMatterPanel"
	panel.add_child(grid)
	_visual_vbox.add_child(panel)
	_visual_vbox.add_child(_spacer(4))


## [key, value] pairs of a front matter block; indented or `- ` lines join
## the value above with commas, and one pair of surrounding quotes goes.
static func _front_matter_pairs(lines: PackedStringArray, end: int) -> Array:
	var pairs: Array = []
	for j in range(1, end - 1):
		var raw: String = lines[j]
		var s: String = raw.strip_edges()
		if s == "" or s.begins_with("#"):
			continue
		var value: String
		if raw.begins_with(" ") or raw.begins_with("\t") or s.begins_with("- "):
			if pairs.is_empty():
				continue
			value = _unquote(s.trim_prefix("- ").strip_edges())
			pairs[-1][1] = value if pairs[-1][1] == "" else pairs[-1][1] + ", " + value
			continue
		var k: int = s.find(":")
		pairs.append([s.substr(0, k).strip_edges(), _unquote(s.substr(k + 1).strip_edges())])
	return pairs


static func _unquote(v: String) -> String:
	if v.length() >= 2 and ((v.begins_with("\"") and v.ends_with("\"")) or (v.begins_with("'") and v.ends_with("'"))):
		return v.substr(1, v.length() - 2)
	return v


static var _quiz_counter: int = 0
static var _cards_counter: int = 0


## "Worth a review" banner on notes the learner missed quiz questions about.
static func _add_review_banner() -> void:
	var missed: Array[Dictionary] = ProgressStore.missed_for(current_note.title)
	if missed.is_empty():
		return
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"ReviewBanner"
	# Build BBCode directly: user text is escaped by _links_and_md, and the
	# quiz's note is linked by its title (_note_link), never as "[[title]]"
	var accent: Color = _accent()
	var targets: Array[String] = []
	var bb: String = "[color=#f0a040]●[/color]  [b]Worth a review[/b] — you missed:"
	for i in range(mini(missed.size(), 3)):
		var r: Dictionary = missed[i]
		var from: String = str(r.get("from", ""))
		bb += "\n•   " + _links_and_md("“%s”" % str(r.get("q", "")).replace("*", ""), accent, targets)
		if from.strip_edges() != "" and from.strip_edges().to_lower() != current_note.title.strip_edges().to_lower():
			bb += "  in " + _note_link(from, from.strip_edges(), accent, targets)
	bb += "\n[color=#9a9aa4]Read on, then retake the quiz — the mark clears when you get it right.[/color]"
	panel.add_child(_link_row(bb, targets))
	_visual_vbox.add_child(panel)
	_visual_vbox.add_child(_spacer(6))


## "LINKED FROM (N)" after the body: one accent link per note whose [[links]]
## point here, with its folder in faint text. Hidden when nothing links here.
## A row opens the very note it shows (note.gd open_note), never a title
## lookup: titles are free text ("Week [3]" would break a [url=title] tag and
## the click would create a junk note) and may repeat ("untitled", "Daily"
## in two folders). Its url meta is only the row number. The notes are the
## ones _render_visual found (_backlinks).
static func _add_backlinks() -> void:
	var from: Array[ContentLayer] = _backlinks
	if from.is_empty():
		return
	_visual_vbox.add_child(_spacer(14))
	_visual_vbox.add_child(_label("LINKED FROM (%d)" % from.size(), &"SectionLabel", false))
	var accent: String = _accent().to_html(false)
	var faint: String = _palette_color("text_faint", Color("8a8a93")).to_html(false)
	for i in range(from.size()):
		var note: ContentLayer = from[i]
		var shown: String = note.title.strip_edges()
		if shown == "" or shown == "untitled":
			shown = "Untitled"
		var bb: String = "[url=%d][color=#%s]%s[/color][/url]" % [i, accent, shown.replace("[", "[lb]")]
		var folder: String = VaultStore.folder_of(note)
		if folder != "":
			bb += "   [color=#%s]%s[/color]" % [faint, folder.replace("/", "  /  ").replace("[", "[lb]")]
		var row := _rich_row(bb)
		row.meta_clicked.connect(func(_meta: Variant) -> void:
			var app: Node = _app_of(row)
			if app != null:
				app.open_note(note))
		_visual_vbox.add_child(row)


## A colour from the app's palette (AppTheme.palette, via the main scene),
## so the section follows dark/light mode; `fallback` outside the app.
static func _palette_color(key: String, fallback: Color) -> Color:
	var scene: Node = _visual_vbox
	while scene != null and not ("_palette_colors" in scene):
		scene = scene.get_parent()
	if scene != null and scene._palette_colors.has(key):
		return scene._palette_colors[key]
	return fallback


## Number of leading backticks if the line opens/closes a fence (>= 3), else 0.
static func _fence_ticks(s: String) -> int:
	var n: int = 0
	while n < s.length() and s[n] == "`":
		n += 1
	return n if n >= 3 else 0


static func _emit_fenced(info: String, lines: PackedStringArray) -> void:
	if NoteScene3D.is_scene_fence(info):
		_visual_vbox.add_child(_spacer(4))
		var card: NoteScene3D = NoteScene3D.from_block(info, lines)
		if card.preset == "quiz":
			# Identity for saved progress: which note, which quiz in it
			card.params["_note"] = current_note.title
			card.params["_quiz_index"] = _quiz_counter
			_quiz_counter += 1
		elif card.preset == "flashcards":
			card.params["_note"] = current_note.title
			card.params["_cards_index"] = _cards_counter
			_cards_counter += 1
		_visual_vbox.add_child(card)
		_add_objective_chip(card)
		_visual_vbox.add_child(_spacer(4))
		return
	var code_edit := CodeEdit.new()
	code_edit.text = "\n".join(lines)
	code_edit.editable = false
	code_edit.scroll_fit_content_height = true
	code_edit.context_menu_enabled = false
	_visual_vbox.add_child(code_edit)


## A line that is exactly one `![alt](target)`: the image across the column
## (never upscaled, at most MAX_IMAGE_HEIGHT high) with its alt text as a
## caption, or a muted line saying why it can't show. `line_no` is the ref's
## source line, for the image's Remove from note.
static func _emit_image(ref: Dictionary, line_no: int) -> void:
	var target: String = ref.target
	var path: String = ImageEmbeds.resolve(target, VaultStore.vault_path)
	var tex: Texture2D = ImageEmbeds.load_texture(path)
	if tex == null:
		_visual_vbox.add_child(_label(_image_problem(target, path), &"MutedLabel"))
		return
	var box := VBoxContainer.new()
	box.name = "ImageEmbed"
	box.add_theme_constant_override("separation", 4)
	var rect: TextureRect = _image_rect(tex, target, path)
	rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rect.resized.connect(func() -> void: _fit_image_height(rect))
	_make_image_clickable(rect, {"path": path, "target": target, "alt": str(ref.alt), "line": line_no})
	box.add_child(rect)
	if str(ref.alt) != "":
		var caption: Label = _label(ref.alt, &"MutedLabel")
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(caption)
	_visual_vbox.add_child(box)


## A Read-view image takes the mouse: a click opens it full-window (note.gd
## show_image_viewer), a right click opens its menu (show_image_menu). `info`
## is {path, target, alt, line}, kept as the rect's "image_ref" meta.
static func _make_image_clickable(rect: TextureRect, info: Dictionary) -> void:
	rect.mouse_filter = Control.MOUSE_FILTER_STOP
	rect.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	rect.set_meta("image_ref", info)
	rect.gui_input.connect(func(event: InputEvent) -> void:
		var mb := event as InputEventMouseButton
		var app: Node = _app_of(rect)
		if mb == null or app == null or not app.has_method("show_image_viewer"):
			return
		# Open on release over the image, like a button; the menu on press
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed \
				and Rect2(Vector2.ZERO, rect.size).has_point(mb.position):
			rect.accept_event()
			app.show_image_viewer(info)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			rect.accept_event()
			app.show_image_menu(info))


## A TextureRect for an image file, sized by its caller (IGNORE_SIZE: the
## texture never sets a minimum width, so a wide image can't widen the page).
static func _image_rect(tex: Texture2D, target: String, path: String) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.tooltip_text = target
	rect.set_meta("image_path", path)
	return rect


## One Outline row under IMAGES: a thumbnail no larger than THUMB_SIZE (never
## enlarged) beside the alt text and target; a ref that can't show gets the
## Read view's muted line in place of both.
static func _image_row(ref: Dictionary) -> Control:
	var target: String = ref.target
	var path: String = ImageEmbeds.resolve(target, VaultStore.vault_path)
	var tex: Texture2D = ImageEmbeds.load_texture(path)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var slot := CenterContainer.new()   # a fixed column keeps the names aligned
	slot.custom_minimum_size.x = THUMB_SIZE.x
	row.add_child(slot)
	if tex == null:
		row.add_child(_label(_image_problem(target, path), &"MutedLabel"))
		return row
	var thumb: TextureRect = _image_rect(tex, target, path)
	thumb.custom_minimum_size = _thumb_size(tex.get_size())
	slot.add_child(thumb)
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	names.add_theme_constant_override("separation", 0)
	var alt: String = str(ref.alt)
	names.add_child(_label(alt if alt != "" else target, &"BodyLabel"))
	if alt != "":
		names.add_child(_label(target, &"FaintLabel"))
	row.add_child(names)
	return row


## `native` scaled down to fit THUMB_SIZE with its aspect kept; never up.
static func _thumb_size(native: Vector2) -> Vector2:
	if native.x <= 0.0 or native.y <= 0.0:
		return Vector2.ONE
	var scale: float = minf(1.0, minf(THUMB_SIZE.x / native.x, THUMB_SIZE.y / native.y))
	return Vector2(maxf(1.0, roundf(native.x * scale)), maxf(1.0, roundf(native.y * scale)))


## Height for the column width: the native height, less when the width
## shrinks the image, and never over MAX_IMAGE_HEIGHT.
## Unlike wrapped text, an image gets SHORTER as the column narrows. So the
## column width must not depend on whether DocScroll's scrollbar shows, or a
## note within one scrollbar width of the view's height flips the bar on and
## off forever (message queue out of memory, then a crash). note.tscn keeps
## DocScroll on SCROLL_MODE_RESERVE for that; image_read_test sweeps it.
static func _fit_image_height(rect: TextureRect) -> void:
	var native: Vector2 = rect.texture.get_size() if rect.texture != null else Vector2.ZERO
	if native.x <= 0.0 or rect.size.x <= 0.0:
		return
	var h: float = ceilf(minf(minf(native.y, rect.size.x * native.y / native.x), MAX_IMAGE_HEIGHT))
	if rect.custom_minimum_size.y != h:
		rect.custom_minimum_size.y = h


## Why an image ref shows no picture, as the line the reader sees.
static func _image_problem(target: String, path: String) -> String:
	if ImageEmbeds.is_remote(target):
		var url: String = target if target.length() <= 80 else target.left(77) + "…"
		return "Web images are not loaded: " + url
	if target.get_extension().to_lower() not in ImageEmbeds.EXTS:
		return "Not a supported image (png, jpg, webp): " + target
	if path == "":   # ImageEmbeds.resolve refuses an absolute path or one leaving the vault
		return "Images outside the vault are not loaded: " + target
	if FileAccess.file_exists(path):
		return "Image could not be read: " + target
	return "Image not found: " + target


static func _clear_structured_vbox() -> void:
	if _structured_vbox == null:
		return
	for child in _structured_vbox.get_children():
		_structured_vbox.remove_child(child)
		child.queue_free()


static func _clear_visual_vbox() -> void:
	if _visual_vbox == null:
		return
	for child in _visual_vbox.get_children():
		_visual_vbox.remove_child(child)
		child.queue_free()


static func _parse_structure(text: String) -> Dictionary:
	"""Parse raw text into structural elements: headings, lists, code blocks."""
	var structure: Dictionary = {}
	var headings: Array = []
	var lists: Array = []
	var code_blocks: Array = []
	var lines: PackedStringArray = text.split("\n")
	var current_code_block: String = ""
	var fence_len: int = 0   # backticks of the open fence; 0 = prose
	for i in range(_front_matter_end(lines), lines.size()):
		var line: String = lines[i]
		var s: String = line.strip_edges()
		var ticks: int = _fence_ticks(s)
		# Fences close as in Read view: a ```` block can show ``` lines
		if fence_len > 0:
			if ticks >= fence_len and s.substr(ticks).strip_edges() == "":
				code_blocks.append({
					"text": current_code_block.strip_edges()
				})
				current_code_block = ""
				fence_len = 0
			else:
				current_code_block += line + "\n"
			continue
		if ticks > 0:
			fence_len = ticks
			continue
		var level: int = _heading_level(line)
		if level > 0:
			headings.append({
				"text": line.substr(level + 1).strip_edges(),
				"level": level,
				"line": i,   # the source line Outline's click jumps to
			})
			continue
		var item: Dictionary = _list_item(line)
		if not item.is_empty():
			lists.append({
				"text": item.text,
				"marker": str(item.marker) if item.kind == "number" else "•",
			})
	structure["headings"] = headings
	structure["lists"] = lists
	structure["code_blocks"] = code_blocks
	structure["images"] = ImageEmbeds.refs_in(text)
	return structure


static func _get_structured_content() -> String:
	"""Return a formatted string representation of the structured view."""
	if current_note == null:
		return ""
	var structure: Dictionary = _render_data
	var out: String = ""
	for heading in structure.get("headings", []):
		var indent: String = "#".repeat(heading["level"]) + " "
		out += indent + heading["text"] + "\n"
	for cb in structure.get("code_blocks", []):
		out += "```\n" + cb["text"] + "\n```\n"
	for item in structure.get("lists", []):
		out += "- " + item["text"] + "\n"
	for ref in structure.get("images", []):
		out += "![%s](%s)\n" % [ref.alt, ref.target]
	if structure.get("headings", []).size() == 0 and \
	   structure.get("lists", []).size() == 0 and \
	   structure.get("code_blocks", []).size() == 0 and \
	   structure.get("images", []).size() == 0:
		out = current_note.raw_text
	return out


static func _get_visual_content() -> String:
	"""Return a string with visual-style annotations for each line."""
	if current_note == null:
		return ""
	var lines: PackedStringArray = current_note.raw_text.split("\n")
	var out: String = ""
	for line in lines:
		var image_ref: Dictionary = ImageEmbeds.parse_line(line)
		var level: int = _heading_level(line)
		var item: Dictionary = _list_item(line)
		if not image_ref.is_empty():
			out += "[image: %s]\n" % (image_ref.alt if image_ref.alt != "" else image_ref.target)
		elif level > 0:
			out += "[H%d] %s\n" % [level, line.substr(level + 1).strip_edges()]
		elif _is_rule(line.strip_edges()):
			out += "[RULE]\n"
		elif line.strip_edges().begins_with(">"):
			out += "[QUOTE] " + line.strip_edges().lstrip("> ").strip_edges() + "\n"
		elif not item.is_empty():
			out += "[LIST] " + str(item.text) + "\n"
		elif line.strip_edges() == "":
			out += "\n"
		else:
			out += "[BODY] " + line + "\n"
	return out


# ---------------------------------------------------------------------------
# Graph layout helpers
# ---------------------------------------------------------------------------


static func _layout_nodes(graph_nodes: Dictionary, graph_edges: Array, canvas_size: Vector2) -> void:
	"""Simple force-directed layout for graph nodes."""
	if graph_nodes.is_empty():
		return
	# Initialize positions and sizes
	var padding: float = 40.0
	var usable_w: float = canvas_size.x - padding * 2
	var usable_h: float = canvas_size.y - padding * 2
	var center_pos: Vector2 = Vector2(usable_w / 2.0 + padding, usable_h / 2.0 + padding)
	var node_ids: PackedStringArray = []
	for key in graph_nodes:
		node_ids.append(key)
		var node: Dictionary = graph_nodes[key]
		var title_len: int = node["title"].length()
		var w: float = maxf(80, title_len * 8 + 32)
		var h: float = 40.0
		node["size"] = Vector2(w, h)
		node["pos"] = Vector2(
			padding + randf() * usable_w,
			padding + randf() * usable_h
		)
		node["vel"] = Vector2.ZERO
	# Force-directed simulation: 20 iterations
	var iterations: int = 20
	for iter in range(iterations):
		var cooling: float = 1.0 - (iter / float(iterations))
		# Repulsive forces (every node pushes away from every other)
		for i_idx in range(node_ids.size()):
			var key_a: String = node_ids[i_idx]
			var node_a: Dictionary = graph_nodes[key_a]
			var force: Vector2 = Vector2.ZERO
			for j_idx in range(node_ids.size()):
				if i_idx == j_idx:
					continue
				var key_b: String = node_ids[j_idx]
				var node_b: Dictionary = graph_nodes[key_b]
				var diff: Vector2 = node_a.pos - node_b.pos
				var dist: float = maxf(diff.length(), 1.0)
				var min_dist: float = (node_a.size.length() + node_b.size.length()) * 0.5
				if dist < min_dist:
					force += diff.normalized() * (min_dist - dist) * 0.1
				if dist < 300:
					force += diff.normalized() / dist * 50
			node_a["vel"] += force * cooling * 0.5
		# Attractive forces (connected nodes pull together)
		for edge in graph_edges:
			var from_key: String = str(edge.from)
			var to_key: String = str(edge.to)
			if not graph_nodes.has(from_key) or not graph_nodes.has(to_key):
				continue
			var node_from: Dictionary = graph_nodes[from_key]
			var node_to: Dictionary = graph_nodes[to_key]
			var diff: Vector2 = node_to.pos - node_from.pos
			var dist: float = diff.length()
			var ideal_dist: float = 150.0
			if dist > ideal_dist:
				var pull: float = (dist - ideal_dist) * 0.01 * cooling
				var dir_vec: Vector2 = diff.normalized()
				node_from["vel"] += dir_vec * pull
				node_to["vel"] -= dir_vec * pull
		# Center gravity (keep nodes on screen)
		for key in node_ids:
			var node: Dictionary = graph_nodes[key]
			var to_center: Vector2 = center_pos - node.pos
			node["vel"] += to_center * 0.001 * cooling
		# Apply velocities with damping
		for key in node_ids:
			var node: Dictionary = graph_nodes[key]
			node["vel"] *= 0.8  # Damping
			var displacement: Vector2 = node["vel"] * cooling * 20.0
			node.pos += displacement
			# Clamp to canvas bounds
			var half_sz: Vector2 = node["size"] / 2.0
			node.pos.x = clampf(node.pos.x, padding + half_sz.x, canvas_size.x - padding - half_sz.x)
			node.pos.y = clampf(node.pos.y, padding + half_sz.y, canvas_size.y - padding - half_sz.y)
	# Center the whole layout
	if not graph_nodes.is_empty():
		var avg_pos: Vector2 = Vector2.ZERO
		var count: int = 0
		for key in node_ids:
			var node: Dictionary = graph_nodes[key]
			avg_pos += node.pos
			count += 1
		if count > 0:
			avg_pos /= float(count)
			var offset: Vector2 = center_pos - avg_pos
			for key in node_ids:
				graph_nodes[key]["pos"] += offset


# ── Objective chips: which learning objective a quiz or deck feeds ─────────

## Longest objective name a chip shows whole (the tooltip has all of it), so
## a long name never makes Read view wider than the window.
const CHIP_NAME_CHARS: int = 40


## Under a quiz or flashcard deck whose block has an "objective:" line: a
## chip row naming the objective it feeds, or, when the Journey has no
## objective of that name, offering to create it. The row remembers what it
## is for in its "objective_chip" meta: {name, activity, kind, topic}.
static func _add_objective_chip(card: NoteScene3D) -> void:
	var objective: String = str(card.params.get("objective", "")).strip_edges()
	var kind: String = {"quiz": "quiz", "flashcards": "cards"}.get(card.preset, "")
	if objective == "" or kind == "":
		return
	var index: int = int(card.params.get("_quiz_index" if kind == "quiz" else "_cards_index", 0))
	var folder: String = VaultStore.folder_of(current_note)
	var row := HFlowContainer.new()   # Create drops under the text in a narrow window
	row.add_theme_constant_override("h_separation", 6)
	row.set_meta("objective_chip", {
		"name": objective, "kind": kind,
		"activity": JourneyStore.activity_key(current_note.title, kind, index),
		"topic": folder.get_file() if folder != "" else "From notes",
	})
	_visual_vbox.add_child(row)
	_fill_objective_chip(row)


## Redraw every chip in Read view from the Journey as it is now: after a
## Create, or when a finished activity changed an objective's status.
static func refresh_objective_chips() -> void:
	if not is_instance_valid(_visual_vbox):   # also a window freed since (tests open several)
		return
	for c in _visual_vbox.get_children():
		if c.has_meta("objective_chip"):
			_fill_objective_chip(c)


static func _fill_objective_chip(row: HFlowContainer) -> void:
	for c in row.get_children():
		row.remove_child(c)
		c.queue_free()
	var chip: Dictionary = row.get_meta("objective_chip")
	var what: String = "quiz" if chip.kind == "quiz" else "deck"
	var o: Dictionary = JourneyStore.find_objective_by_name(chip.name)
	if not o.is_empty():
		var feeds: Button = _chip_button("Feeds objective: " + _chip_name(str(o.name)), "ObjectiveChip")
		var status: String = JourneyStore.objective_status(o)
		if status != "":
			feeds.icon = ProgressStore.icon(status)
		feeds.tooltip_text = "Finishing this %s logs its score to “%s”. Click to open it in the Learning Journey." % [what, o.name]
		feeds.pressed.connect(_open_objective.bind(row, str(o.id)))
		row.add_child(feeds)
		return
	var missing: Label = _label("“%s” isn't in your Journey yet —" % _chip_name(chip.name), &"MutedLabel", false)
	missing.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # Create right after it
	missing.tooltip_text = chip.name
	missing.mouse_filter = Control.MOUSE_FILTER_PASS   # so the tooltip shows
	row.add_child(missing)
	var create: Button = _chip_button("Create", "CreateObjective")
	create.icon = Icons.get_icon("plus")
	create.tooltip_text = "Add “%s” to your Journey under the topic “%s”, with this %s as a way to show it." % [chip.name, chip.topic, what]
	create.pressed.connect(_create_objective.bind(row))
	row.add_child(create)


static func _chip_button(text: String, node_name: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.theme_type_variation = &"TagButton"
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return b


static func _chip_name(objective: String) -> String:
	return objective if objective.length() <= CHIP_NAME_CHARS else objective.left(CHIP_NAME_CHARS - 1).strip_edges() + "…"


## Create: the objective, its topic if missing, and this activity as its
## demonstration; then every chip naming it reads "Feeds objective".
static func _create_objective(row: HFlowContainer) -> void:
	var chip: Dictionary = row.get_meta("objective_chip")
	JourneyStore.create_linked_objective(chip.name, chip.topic, chip.activity)
	refresh_objective_chips()


## A "Feeds objective" chip was clicked: the app (note.gd) opens the
## objective in the Journey tab.
static func _open_objective(row: Node, id: String) -> void:
	var n: Node = row
	while n != null and not n.has_method("show_objective"):
		n = n.get_parent()
	if n != null:
		n.show_objective(id)
