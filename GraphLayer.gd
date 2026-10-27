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

signal node_clicked(note_index: int)
signal node_hovered(note_index: int)

const REPULSION: float = 9000.0
const SPRING: float = 0.04
const SPRING_LENGTH: float = 140.0
const GRAVITY: float = 0.012
const DAMPING: float = 0.82
const SETTLE_FRAMES: int = 240

var dark_mode: bool = true            # set by note.gd on theme change

var _nodes: Dictionary = {}           # key -> {pos, vel, title, degree}
var _edges: Array[Dictionary] = []    # [{from, to}]
var _pan: Vector2 = Vector2.ZERO
var _zoom: float = 1.0
var _hovered: String = ""
var _dragging: String = ""
var _panning: bool = false
var _sim_frames: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	resized.connect(queue_redraw)
	set_process(false)


## Called by note.gd. `nodes` is keyed by str(note_index); `edges` is [{from, to}].
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
	if old.is_empty():
		_pan = Vector2.ZERO
		_zoom = 1.0
	# Pre-settle so the first frame already looks calm, then animate the rest
	for i in range(120):
		_step()
	_sim_frames = SETTLE_FRAMES
	set_process(true)
	queue_redraw()


# ── Simulation ──────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if _sim_frames <= 0 and _dragging == "":
		set_process(false)
		return
	_sim_frames -= 1
	_step()
	queue_redraw()


func _step() -> void:
	var keys: Array = _nodes.keys()
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
		if a == b or not (_nodes.has(a) and _nodes.has(b)):
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

	if _nodes.is_empty():
		var msg: String = "No notes to graph yet."
		var w: float = font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		draw_string(font, size / 2.0 - Vector2(w / 2.0, 0), msg, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, c.text_muted)
		return

	var near: Dictionary = _neighbours(_hovered)
	var focus: bool = _hovered != ""

	for e in _edges:
		var a: String = str(e.from)
		var b: String = str(e.to)
		if a == b or not (_nodes.has(a) and _nodes.has(b)):
			continue
		var lit: bool = focus and (a == _hovered or b == _hovered)
		var col: Color = c.accent if lit else Color(c.text, 0.07 if focus else 0.2)
		draw_line(_to_screen(_nodes[a].pos), _to_screen(_nodes[b].pos), col, 1.6 if lit else 1.0, true)

	var label_size: int = int(clampf(12.0 * sqrt(_zoom), 10.0, 16.0))
	for key in _nodes:
		var node: Dictionary = _nodes[key]
		var p: Vector2 = _to_screen(node.pos)
		var r: float = _radius(key)
		var is_hover: bool = key == _hovered
		var is_near: bool = near.has(key)
		var dim: bool = focus and not is_hover and not is_near
		var dot: Color = Color(c.text_muted, 0.3 if dim else 0.9)
		if is_hover:
			dot = c.accent
			draw_circle(p, r + 6.0, Color(c.accent, 0.18), true, -1.0, true)
		elif is_near:
			dot = Color(c.accent, 0.7)
		draw_circle(p, r, dot, true, -1.0, true)

		var title: String = node.title if node.title != "" else "Untitled"
		var tw: float = font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size).x
		var text_col: Color = c.text if (is_hover or is_near) else Color(c.text_muted, 0.3 if dim else 1.0)
		draw_string(font, p + Vector2(-tw / 2.0, r + 4.0 + label_size), title, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, text_col)

	var hint: String = "%d notes  ·  %d links" % [_nodes.size(), _edges.size()]
	draw_string(font, Vector2(16, size.y - 14), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, c.text_faint)


# ── Input ───────────────────────────────────────────────────────────────────

func _hit(screen_pos: Vector2) -> String:
	var best: String = ""
	var best_d: float = INF
	for key in _nodes:
		var d: float = _to_screen(_nodes[key].pos).distance_to(screen_pos)
		if d <= _radius(key) + 6.0 and d < best_d:
			best = key
			best_d = d
	return best


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed and mb.double_click:
					var hit: String = _hit(mb.position)
					_dragging = ""
					if hit != "":
						node_clicked.emit(int(hit))
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
				node_hovered.emit(int(hit) if hit != "" else -1)
				queue_redraw()
