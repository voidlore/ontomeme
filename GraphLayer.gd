extends Control
class_name GraphLayer
## GraphLayer — Obsidian-style note graph.
##
## Notes are dots sized by link count, labelled underneath; wikilinks are
## thin edges. A small force simulation settles the layout and keeps running
## while a node is dragged. Colours come from the AppTheme palette, so
## dark/light mode just work.
##
## Mouse: hover highlights a node and its neighbours, drag moves a node,
## drag empty space pans, wheel zooms toward the cursor, double-click opens.
##
## A node's key is its note's resource_path, never its place in
## VaultStore.note_list: the disk watcher re-sorts that list while the graph
## is open, and a key must keep naming the same note. The open note
## (current_key) wears an accent ring. The filter box at the top-left dims
## every note whose title lacks its text (Escape clears it); the Local toggle
## draws only the open note and the notes it links with, either way.

signal node_clicked(note_key: String)
signal node_hovered(note_key: String)   # "" when the mouse leaves every node

const REPULSION: float = 9000.0
const SPRING: float = 0.04
const SPRING_LENGTH: float = 140.0
const GRAVITY: float = 0.012
const DAMPING: float = 0.82
const SETTLE_FRAMES: int = 240

var dark_mode: bool = true            # set by note.gd on theme change

## The open note's key (its path): drawn with a ring, and the centre of Local.
var current_key: String = "":
	set(value):
		current_key = value
		if local:
			_resettle()
		queue_redraw()

## Draw only current_key and its depth-1 neighbours (links in and out).
var local: bool = false:
	set(value):
		local = value
		if local_toggle != null:
			local_toggle.set_pressed_no_signal(value)
		_resettle()

var filter_edit: LineEdit = null      # the filter box (top-left)
var local_toggle: Button = null       # the Local toggle beside it

var _nodes: Dictionary = {}           # key -> {pos, vel, title, degree}
var _edges: Array[Dictionary] = []    # [{from, to}]
var _pan: Vector2 = Vector2.ZERO
var _zoom: float = 1.0
var _hovered: String = ""
var _dragging: String = ""
var _panning: bool = false
var _sim_frames: int = 0
var _filter: String = ""              # lower-cased filter text


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	resized.connect(queue_redraw)
	set_process(false)
	_build_overlay()


## The filter box and the Local toggle, in a row at the top-left.
func _build_overlay() -> void:
	var row := HBoxContainer.new()
	row.name = "GraphTools"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE   # gaps between them still pan
	row.position = Vector2(12, 12)
	row.add_theme_constant_override("separation", 6)
	add_child(row)
	filter_edit = LineEdit.new()
	filter_edit.name = "GraphFilter"
	filter_edit.theme_type_variation = &"SearchEdit"
	filter_edit.placeholder_text = "Filter notes…"
	filter_edit.custom_minimum_size = Vector2(200, 0)
	filter_edit.clear_button_enabled = true
	filter_edit.text_changed.connect(_on_filter_changed)
	filter_edit.gui_input.connect(_on_filter_input)
	row.add_child(filter_edit)
	local_toggle = Button.new()
	local_toggle.name = "GraphLocal"
	local_toggle.text = "Local"
	local_toggle.theme_type_variation = &"SegmentButton"   # on = lifted onto a card, like the view switcher
	local_toggle.toggle_mode = true
	local_toggle.focus_mode = Control.FOCUS_NONE
	local_toggle.tooltip_text = "Show only the open note and the notes it links with"
	local_toggle.toggled.connect(func(on: bool) -> void: local = on)
	row.add_child(local_toggle)


## Called by note.gd. `nodes` is keyed by note path ({title}); `edges` is
## [{from, to}] between those keys. Nodes already shown keep their place.
func set_graph_data(nodes: Dictionary, edges: Array[Dictionary]) -> void:
	var old: Dictionary = _nodes
	_nodes = {}
	_edges = edges.duplicate()
	var keys: Array = nodes.keys()
	for i in range(keys.size()):
		var key: String = str(keys[i])
		var src: Dictionary = nodes[keys[i]]
		var pos: Vector2
		if old.has(key):
			pos = old[key].pos
		else:
			# Golden-angle spiral start: even spread, deterministic
			var r: float = 40.0 + 26.0 * sqrt(float(i))
			var a: float = float(i) * 2.39996
			pos = Vector2(cos(a), sin(a)) * r
		_nodes[key] = {"pos": pos, "vel": Vector2.ZERO, "title": str(src.get("title", "")), "degree": 0}
	for e in _edges:
		for end in ["from", "to"]:
			var k: String = str(e[end])
			if _nodes.has(k):
				_nodes[k].degree += 1
	if not _nodes.has(_hovered):
		_hovered = ""
	if not _nodes.has(_dragging):
		_dragging = ""
	if old.is_empty():
		_pan = Vector2.ZERO
		_zoom = 1.0
	# Pre-settle so the first frame already looks calm, then animate the rest
	for i in range(120):
		_step()
	_sim_frames = SETTLE_FRAMES
	set_process(true)
	queue_redraw()


## Notes whose files the app moved or renamed while shown (`moved`: old key
## -> new key): their nodes take the new keys, so the set_graph_data that
## follows finds them and leaves them where they were.
func rekey(moved: Dictionary) -> void:
	if moved.is_empty():
		return
	var out: Dictionary = {}
	for key in _nodes:
		out[str(moved.get(key, key))] = _nodes[key]
	_nodes = out
	_hovered = str(moved.get(_hovered, _hovered))
	_dragging = str(moved.get(_dragging, _dragging))


## True when `key`'s title contains the filter text (any case), or there is
## no filter. Notes that don't match are drawn dimmed, with their edges.
func matches(key: String) -> bool:
	if not _nodes.has(key):
		return false
	return _filter == "" or _title(key).to_lower().contains(_filter)


## The keys drawn now: every node, or with Local on, current_key and its
## neighbours (none when the open note isn't in the graph).
func drawn_keys() -> Array[String]:
	var out: Array[String] = []
	if not local:
		out.assign(_nodes.keys())
		return out
	if not _nodes.has(current_key):
		return out
	out.append(current_key)
	for k in _neighbours(current_key):
		if _nodes.has(k):
			out.append(k)
	return out


func _title(key: String) -> String:
	var t: String = _nodes[key].title
	return t if t != "" else "Untitled"


func _on_filter_changed(text: String) -> void:
	_filter = text.strip_edges().to_lower()
	queue_redraw()


## Empty the filter box: every note is drawn at full strength again.
func clear_filter() -> void:
	filter_edit.text = ""
	_on_filter_changed("")


func _on_filter_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		clear_filter()
		filter_edit.release_focus()
		filter_edit.accept_event()


## Run the layout again (the drawn set changed).
func _resettle() -> void:
	_sim_frames = SETTLE_FRAMES
	set_process(not _nodes.is_empty())
	queue_redraw()


# ── Simulation ──────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if _sim_frames <= 0 and _dragging == "":
		set_process(false)
		return
	_sim_frames -= 1
	_step()
	queue_redraw()


## One tick of the layout over the drawn nodes (Local settles on its own).
func _step() -> void:
	var keys: Array[String] = drawn_keys()
	var forces: Dictionary = {}
	for k in keys:
		forces[k] = -_nodes[k].pos * GRAVITY
	for i in range(keys.size()):
		for j in range(i + 1, keys.size()):
			var d: Vector2 = _nodes[keys[i]].pos - _nodes[keys[j]].pos
			if d.length_squared() < 0.01:
				d = Vector2(randf() - 0.5, randf() - 0.5)
			var f: Vector2 = d.normalized() * (REPULSION / maxf(d.length_squared(), 100.0))
			forces[keys[i]] += f
			forces[keys[j]] -= f
	for e in _edges:
		var a: String = str(e.from)
		var b: String = str(e.to)
		if a == b or not (forces.has(a) and forces.has(b)):
			continue
		var d: Vector2 = _nodes[b].pos - _nodes[a].pos
		var f: Vector2 = d.normalized() * (d.length() - SPRING_LENGTH) * SPRING
		forces[a] += f
		forces[b] -= f
	for k in keys:
		if k == _dragging:
			_nodes[k].vel = Vector2.ZERO
			continue
		_nodes[k].vel = (_nodes[k].vel + forces[k]) * DAMPING
		_nodes[k].pos += (_nodes[k].vel as Vector2).limit_length(30.0)


# ── Drawing ─────────────────────────────────────────────────────────────────

func _to_screen(p: Vector2) -> Vector2:
	return size / 2.0 + _pan + p * _zoom


func _to_world(s: Vector2) -> Vector2:
	return (s - size / 2.0 - _pan) / _zoom


func _radius(key: String) -> float:
	return (5.0 + minf(float(_nodes[key].degree), 8.0) * 1.6) * clampf(_zoom, 0.6, 1.6)


func _neighbours(key: String) -> Dictionary:
	var out: Dictionary = {}
	if key == "":
		return out
	for e in _edges:
		if str(e.from) == key:
			out[str(e.to)] = true
		elif str(e.to) == key:
			out[str(e.from)] = true
	return out


func _draw() -> void:
	var c: Dictionary = AppTheme.palette(dark_mode)
	var font: Font = get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), c.bg)

	var shown: Dictionary = {}
	for k in drawn_keys():
		shown[k] = true
	if shown.is_empty():
		var msg: String = "No notes to graph yet." if _nodes.is_empty() else "Open a note to see the notes it links with."
		var w: float = font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		draw_string(font, size / 2.0 - Vector2(w / 2.0, 0), msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, c.text_muted)
		return

	var near: Dictionary = _neighbours(_hovered)
	var focus: bool = _hovered != ""

	var links: int = 0
	for e in _edges:
		var a: String = str(e.from)
		var b: String = str(e.to)
		if a == b or not (shown.has(a) and shown.has(b)):
			continue
		links += 1
		var faded: bool = not (matches(a) and matches(b))
		var lit: bool = focus and not faded and (a == _hovered or b == _hovered)
		var col: Color = c.accent if lit else Color(c.text, 0.07 if (focus or faded) else 0.2)
		draw_line(_to_screen(_nodes[a].pos), _to_screen(_nodes[b].pos), col, 1.6 if lit else 1.0, true)

	var label_size: int = int(clampf(12.0 * sqrt(_zoom), 10.0, 16.0))
	var matching: int = 0
	for key in shown:
		var node: Dictionary = _nodes[key]
		var p: Vector2 = _to_screen(node.pos)
		var r: float = _radius(key)
		var is_hover: bool = key == _hovered
		var filtered_out: bool = not matches(key)
		var is_near: bool = near.has(key) and not filtered_out
		var dim: bool = filtered_out or (focus and not is_hover and not is_near)
		if not filtered_out:
			matching += 1
		var dot: Color = Color(c.text_muted, 0.3 if dim else 0.9)
		if is_hover:
			dot = c.accent
			draw_circle(p, r + 6.0, Color(c.accent, 0.18), true, -1.0, true)
		elif is_near:
			dot = Color(c.accent, 0.7)
		draw_circle(p, r, dot, true, -1.0, true)
		if key == current_key:
			draw_arc(p, r + 4.0, 0.0, TAU, 40, c.accent, 2.0, true)

		var title: String = _title(key)
		var tw: float = font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size).x
		var text_col: Color = c.text if (is_hover or is_near) else Color(c.text_muted, 0.3 if dim else 1.0)
		draw_string(font, p + Vector2(-tw / 2.0, r + 4.0 + label_size), title, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, text_col)

	var hint: String = "%d notes  ·  %d links" % [shown.size(), links]
	if _filter != "":
		hint += "  ·  %d match" % matching
	draw_string(font, Vector2(16, size.y - 14), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, c.text_faint)


# ── Input ───────────────────────────────────────────────────────────────────

func _hit(screen_pos: Vector2) -> String:
	var best: String = ""
	var best_d: float = INF
	for key in drawn_keys():
		var d: float = _to_screen(_nodes[key].pos).distance_to(screen_pos)
		if d <= _radius(key) + 6.0 and d < best_d:
			best = key
			best_d = d
	return best


func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE and _filter != "":
		clear_filter()
		accept_event()
	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed and mb.double_click:
					var hit: String = _hit(mb.position)
					_dragging = ""
					if hit != "":
						node_clicked.emit(hit)
				elif mb.pressed:
					_dragging = _hit(mb.position)
					_panning = _dragging == ""
					if _dragging != "":
						set_process(true)
				else:
					if _dragging != "":
						_sim_frames = 90
					_dragging = ""
					_panning = false
				accept_event()
			MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
				accept_event()
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					var before: Vector2 = _to_world(mb.position)
					var factor: float = 1.12 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12
					_zoom = clampf(_zoom * factor, 0.25, 4.0)
					_pan += mb.position - _to_screen(before)   # zoom toward the cursor
					queue_redraw()
				accept_event()
	elif event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		if _dragging != "":
			_nodes[_dragging].pos = _to_world(mm.position)
			queue_redraw()
		elif _panning:
			_pan += mm.relative
			queue_redraw()
		else:
			var hit: String = _hit(mm.position)
			if hit != _hovered:
				_hovered = hit
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hit != "" else Control.CURSOR_ARROW
				node_hovered.emit(hit)
				queue_redraw()
