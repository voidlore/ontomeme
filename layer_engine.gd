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

static var current_mode: String = MODE_RAW
static var current_note: ContentLayer = null

# Render layer references (set by note.gd via set_node_refs)
static var _raw_label: TextEdit = null
static var _structured_vbox: VBoxContainer = null
static var _visual_vbox: VBoxContainer = null

# Cached rendering data
static var _render_data: Dictionary = {}

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


static func set_mode(mode: String) -> void:
	"""Switch rendering mode."""
	current_mode = mode
	_show_layer(mode)
	_render_current_mode()


static func set_note(note: ContentLayer) -> void:
	"""Set the note content for rendering, re-rendering immediately in current mode."""
	current_note = note
	if note != null:
		_render_data = _parse_structure(note.raw_text)
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
	var accent: Color = _accent()
	var out: String = ""
	# `code spans` stay literal: split them out before links/emphasis
	var code_rx := RegEx.new()
	code_rx.compile("`([^`]+)`")
	var last: int = 0
	for m in code_rx.search_all(line):
		out += _links_and_md(line.substr(last, m.get_start() - last), accent)
		out += "[code]" + m.get_string(1).replace("[", "[lb]") + "[/code]"
		last = m.get_end()
	out += _links_and_md(line.substr(last), accent)
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.scroll_active = false
	rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rtl.mouse_default_cursor_shape = Control.CURSOR_ARROW
	rtl.text = out
	rtl.meta_clicked.connect(func(meta: Variant) -> void:
		var n: Node = rtl
		while n != null and not n.has_method("open_note_by_title"):
			n = n.get_parent()
		if n != null:
			n.open_note_by_title(str(meta), true))
	return rtl


static func _links_and_md(text: String, accent: Color) -> String:
	var re := RegEx.new()
	re.compile("\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]")
	var out: String = ""
	var last: int = 0
	for m in re.search_all(text):
		out += _inline_md(text.substr(last, m.get_start() - last))
		var target: String = m.get_string(1).strip_edges()
		var shown: String = m.get_string(2).strip_edges() if m.get_string(2) != "" else target
		var mark: String = ""
		match ProgressStore.status(target):
			"done": mark = "[color=#3ddc84]✓[/color] "
			"review": mark = "[color=#f0a040]●[/color] "
		out += "%s[url=%s][color=#%s]%s[/color][/url]" % [mark, target, accent.to_html(false), shown]
		last = m.get_end()
	return out + _inline_md(text.substr(last))


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
	if not headings.is_empty():
		_structured_vbox.add_child(_label("OUTLINE", &"SectionLabel", false))
		for heading in headings:
			var level: int = int(heading["level"])
			var row := _label(heading["text"], [&"H2Label", &"H2Label", &"H3Label", &"BodyLabel"][clampi(level, 1, 3)])
			row.add_theme_constant_override("line_spacing", 2)
			var indent := MarginContainer.new()
			indent.add_theme_constant_override("margin_left", (level - 1) * 20)
			indent.add_child(row)
			_structured_vbox.add_child(indent)
	if not lists.is_empty():
		_structured_vbox.add_child(_spacer(8))
		_structured_vbox.add_child(_label("LIST ITEMS", &"SectionLabel", false))
		for item in lists:
			_structured_vbox.add_child(_label("•  " + str(item["text"]), &"BulletLabel"))
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
	if headings.is_empty() and lists.is_empty() and blocks.is_empty():
		_structured_vbox.add_child(_label("No headings, lists or code blocks yet.", &"MutedLabel"))
		_structured_vbox.add_child(_label("Start a line with # for a heading or - for a list item.", &"FaintLabel"))


static func _render_visual() -> void:
	if _visual_vbox == null or current_note == null:
		return
	_clear_visual_vbox()
	_quiz_counter = 0
	_cards_counter = 0
	_add_review_banner()
	var in_code: bool = false
	var fence_info: String = ""
	var fence_len: int = 0
	var code_lines: PackedStringArray = []
	for line in current_note.raw_text.split("\n"):
		var s: String = line.strip_edges()
		var ticks: int = _fence_ticks(s)
		if in_code:
			# A fence closes on a line of at least as many backticks, so a
			# ```` block can show ``` examples literally.
			if ticks >= fence_len and s.substr(ticks).strip_edges() == "":
				_emit_fenced(fence_info, code_lines)
				code_lines.clear()
				in_code = false
			else:
				code_lines.append(line)
			continue
		if ticks > 0:
			in_code = true
			fence_len = ticks
			fence_info = s.substr(ticks).strip_edges()
			continue
		if line.begins_with("### "):
			_visual_vbox.add_child(_spacer(4))
			_visual_vbox.add_child(_label(line.substr(4).strip_edges(), &"H3Label"))
		elif line.begins_with("## "):
			_visual_vbox.add_child(_spacer(8))
			_visual_vbox.add_child(_label(line.substr(3).strip_edges(), &"H2Label"))
		elif line.begins_with("# "):
			_visual_vbox.add_child(_spacer(6))
			_visual_vbox.add_child(_label(line.substr(2).strip_edges(), &"H1Label"))
		elif s.begins_with("- ") or s.begins_with("* "):
			var item: String = s.substr(2).strip_edges()
			if item.contains("[[") or item.contains("*") or item.contains("`"):
				_visual_vbox.add_child(_linked_paragraph("•   " + item))
			else:
				_visual_vbox.add_child(_label("•   " + item, &"BulletLabel"))
		elif s == "":
			_visual_vbox.add_child(_spacer(6))
		elif line.contains("[[") or line.contains("**") or line.contains("`") or line.contains("*"):
			_visual_vbox.add_child(_linked_paragraph(line))
		else:
			_visual_vbox.add_child(_label(line, &"BodyLabel"))
	if in_code:
		_emit_fenced(fence_info, code_lines)   # still typing: show what's there
	if current_note.raw_text.strip_edges() == "":
		_visual_vbox.add_child(_label("This note is empty.", &"MutedLabel"))


static var _quiz_counter: int = 0
static var _cards_counter: int = 0


## "Worth a review" banner on notes the learner missed quiz questions about.
static func _add_review_banner() -> void:
	var missed: Array[Dictionary] = ProgressStore.missed_for(current_note.title)
	if missed.is_empty():
		return
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"ReviewBanner"
	# Build BBCode directly: user text is escaped by _links_and_md
	var accent: Color = _accent()
	var bb: String = "[color=#f0a040]●[/color]  [b]Worth a review[/b] — you missed:"
	for i in range(mini(missed.size(), 3)):
		var r: Dictionary = missed[i]
		var from: String = str(r.get("from", ""))
		var where: String = "" if from.strip_edges().to_lower() == current_note.title.strip_edges().to_lower() else "  in [[%s]]" % from
		bb += "\n•   " + _links_and_md("“%s”%s" % [str(r.get("q", "")).replace("*", ""), where], accent)
	bb += "\n[color=#9a9aa4]Read on, then retake the quiz — the mark clears when you get it right.[/color]"
	var body := _linked_paragraph("")
	body.text = bb
	panel.add_child(body)
	_visual_vbox.add_child(panel)
	_visual_vbox.add_child(_spacer(6))


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
		_visual_vbox.add_child(_spacer(4))
		return
	var code_edit := CodeEdit.new()
	code_edit.text = "\n".join(lines)
	code_edit.editable = false
	code_edit.scroll_fit_content_height = true
	code_edit.context_menu_enabled = false
	_visual_vbox.add_child(code_edit)


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
	var in_code_block: bool = false
	for line in lines:
		if line.begins_with("```"):
			if in_code_block:
				code_blocks.append({
					"text": current_code_block.strip_edges()
				})
				current_code_block = ""
				in_code_block = false
			else:
				in_code_block = true
			continue
		if in_code_block:
			current_code_block += line + "\n"
			continue
		if line.begins_with("# "):
			headings.append({
				"text": line.replace("# ", "").strip_edges(),
				"level": 1
			})
		elif line.begins_with("## "):
			headings.append({
				"text": line.replace("## ", "").strip_edges(),
				"level": 2
			})
		elif line.begins_with("### "):
			headings.append({
				"text": line.replace("### ", "").strip_edges(),
				"level": 3
			})
		elif line.strip_edges().begins_with("- "):
			lists.append({
				"text": line.strip_edges().lstrip("- ").strip_edges()
			})
	structure["headings"] = headings
	structure["lists"] = lists
	structure["code_blocks"] = code_blocks
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
	if structure.get("headings", []).size() == 0 and \
	   structure.get("lists", []).size() == 0 and \
	   structure.get("code_blocks", []).size() == 0:
		out = current_note.raw_text
	return out


static func _get_visual_content() -> String:
	"""Return a string with visual-style annotations for each line."""
	if current_note == null:
		return ""
	var lines: PackedStringArray = current_note.raw_text.split("\n")
	var out: String = ""
	for line in lines:
		if line.begins_with("# "):
			out += "[H1] " + line.replace("# ", "").strip_edges() + "\n"
		elif line.begins_with("## "):
			out += "[H2] " + line.replace("## ", "").strip_edges() + "\n"
		elif line.begins_with("### "):
			out += "[H3] " + line.replace("### ", "").strip_edges() + "\n"
		elif line.strip_edges().begins_with("- "):
			out += "[LIST] " + line.strip_edges().lstrip("- ").strip_edges() + "\n"
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
