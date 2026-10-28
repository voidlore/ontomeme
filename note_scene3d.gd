class_name NoteScene3D
extends PanelContainer
## NoteScene3D — a live, interactive 3D scene embedded in a note.
##
## A note opts in with a fenced block tagged `3d`:
##
##     ```3d
##     preset: galaxy
##     color: #d97757
##     caption: Hello, universe
##     ```
##
## Read view turns the block into one of these cards: a SubViewport with
## its own World3D, an orbit camera and a WorldEnvironment (AgX tonemapping,
## HDR glow, fog). Everything is built from Godot's own pieces — MultiMesh,
## SurfaceTool, ImmediateMesh, Label3D, NoiseTexture2D and small spatial
## shaders — so no assets ship with the app.
##
## Mouse: drag to orbit, Ctrl+wheel to zoom (plain wheel keeps scrolling the
## note), double-click a node in the vault graph to open that note.

signal closed

const PRESETS: Dictionary = {
	"galaxy": "Spiral galaxy",
	"knot": "Torus knot",
	"terrain": "Terrain flyover",
	"waves": "Wave field",
	"atom": "Atom",
	"graph": "Vault graph",
	"quiz": "Quiz",
	"shapes": "Shapes",
	"flashcards": "Flashcards",
}
## Primitive shapes a note can place with "cube: red" lines (+ synonyms).
const SHAPES: Dictionary = {
	"cube": "cube", "box": "cube", "sphere": "sphere", "ball": "sphere",
	"cylinder": "cylinder", "cone": "cone", "pyramid": "pyramid",
	"torus": "torus", "donut": "torus", "ring": "torus", "capsule": "capsule",
	"prism": "prism", "triangle": "prism",
}
## Friendly, saturated named colours (Godot's own "green" is a harsh lime).
const COLORS: Dictionary = {
	"red": Color("e5484d"), "blue": Color("3e7bfa"), "yellow": Color("f5c400"),
	"green": Color("2fb36d"), "orange": Color("f08c2e"), "purple": Color("8e5cf0"),
	"pink": Color("f06fb4"), "cyan": Color("2ec5d3"), "white": Color("f2f2f2"),
	"black": Color("1e1e22"), "gray": Color("8a8a92"), "grey": Color("8a8a92"),
	"brown": Color("8b5a3c"), "gold": Color("e0a526"),
}
const MODEL_EXTS: Array[String] = ["glb", "gltf", "fbx"]
const QUIZ_GREEN: Color = Color("3ddc84")
const QUIZ_RED: Color = Color("ff5c5c")
const QUIZ_TILE: Color = Color("8fa2ff")
const STAGE_BG: Color = Color("0b0b0f")

# Additive star sprites. Instance colour alpha carries the sprite size, and
# the quad is billboarded in the vertex shader so one MultiMesh draws them all.
const SHADER_STARS: String = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;
uniform float energy = 2.4;
void vertex() {
	vec3 center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 world = center + (right * VERTEX.x + up * VERTEX.y) * COLOR.a;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}
void fragment() {
	float d = length(UV - 0.5) * 2.0;
	float a = smoothstep(1.0, 0.0, d);
	ALBEDO = COLOR.rgb * energy * a * a;
}
"""

# Scrolling noise heightmap with glowing grid lines that brighten on peaks.
const SHADER_TERRAIN: String = """
shader_type spatial;
uniform sampler2D noise_tex : repeat_enable, filter_linear_mipmap;
uniform float height = 2.2;
uniform float speed = 0.02;
uniform vec3 low_color : source_color;
uniform vec3 high_color : source_color;
uniform vec3 line_color : source_color;
varying float h;
varying vec2 tuv;
float sample_h(vec2 uv) {
	return smoothstep(0.32, 0.92, textureLod(noise_tex, uv, 0.0).r);
}
void vertex() {
	tuv = UV * 0.6 + vec2(0.0, -TIME * speed);
	h = sample_h(tuv);
	VERTEX.y += h * height;
	float e = 0.004;
	float hx = sample_h(tuv + vec2(e, 0.0));
	float hz = sample_h(tuv + vec2(0.0, e));
	float step_world = e * 16.0 / 0.6;
	NORMAL = normalize(vec3((h - hx) * height, step_world, (h - hz) * height));
}
void fragment() {
	vec2 g = tuv * 70.0;
	vec2 grid = abs(fract(g - 0.5) - 0.5) / fwidth(g);
	float line = 1.0 - min(min(grid.x, grid.y), 1.0);
	ALBEDO = mix(low_color, high_color, h);
	ROUGHNESS = 0.75;
	EMISSION = line_color * line * (0.35 + 3.0 * h * h);
}
"""

# Banded "synthwave" sun.
const SHADER_SUN: String = """
shader_type spatial;
render_mode unshaded, fog_disabled;
uniform vec3 top : source_color;
uniform vec3 bottom : source_color;
uniform float radius = 2.6;
varying vec3 lp;
void vertex() { lp = VERTEX; }
void fragment() {
	float t = clamp(lp.y / radius * 0.5 + 0.5, 0.0, 1.0);
	float band = fract(lp.y * 2.4 + TIME * 0.25);
	if (t < 0.5 && band < (0.5 - t) * 1.2) { discard; }
	ALBEDO = mix(bottom, top, t) * 2.0;
}
"""

# Instanced bars: each bar's height follows two interfering waves.
const SHADER_WAVES: String = """
shader_type spatial;
uniform vec3 color_a : source_color;
uniform vec3 color_b : source_color;
uniform float speed = 1.0;
varying float k;
void vertex() {
	vec2 p = MODEL_MATRIX[3].xz;
	float t = TIME * speed;
	float ring = sin(length(p) * 1.5 - t * 2.2) * 0.5 + 0.5;
	float cross_w = sin(p.x * 0.9 + t * 1.3) * sin(p.y * 0.7 - t) * 0.5 + 0.5;
	k = mix(ring, cross_w, 0.35);
	VERTEX.y = VERTEX.y > 0.0 ? 0.12 + k * 1.7 : 0.0;
}
void fragment() {
	vec3 c = mix(color_a, color_b, k);
	ALBEDO = c;
	METALLIC = 0.35;
	ROUGHNESS = 0.3;
	EMISSION = c * pow(k, 6.0) * 3.0;
}
"""

# Fresnel glow for the atom's nucleus particles.
const SHADER_FRESNEL: String = """
shader_type spatial;
render_mode unshaded;
uniform vec3 tint : source_color;
void fragment() {
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	ALBEDO = tint * (0.45 + f * 3.5);
}
"""

# Confetti pieces: plain particle colour (HDR values would tonemap toward white).
const SHADER_CONFETTI: String = """
shader_type spatial;
render_mode unshaded, cull_disabled;
void fragment() {
	ALBEDO = COLOR.rgb;
}
"""

# Studio floor: dark, with a grid that fades out with distance.
const SHADER_FLOOR: String = """
shader_type spatial;
varying vec3 wp;
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 g = wp.xz;
	vec2 grid = abs(fract(g - 0.5) - 0.5) / fwidth(g);
	float line = 1.0 - min(min(grid.x, grid.y), 1.0);
	float fade = exp(-length(wp.xz) * 0.12);
	ALBEDO = vec3(0.075, 0.078, 0.095) + vec3(0.22, 0.23, 0.3) * line * fade;
	ROUGHNESS = 0.55;
	SPECULAR = 0.3;
}
"""

static var _shader_cache: Dictionary = {}

var params: Dictionary = {}
var expanded: bool = false
var preset: String = "galaxy"

var _height: float = 340.0
var _container: SubViewportContainer
var _viewport: SubViewport
var _camera: Camera3D
var _env: Environment
var _content: Node3D
var _scroll_clip: Control = null
var _target: Vector3 = Vector3.ZERO
var _yaw: float = 0.6
var _pitch: float = -0.45
var _distance: float = 9.0
var _autorotate: bool = true
var _dragging: bool = false
var _idle: float = 10.0
var _time: float = 0.0
var _updaters: Array[Callable] = []
var _graph_nodes: Array[Dictionary] = []
var _hovered: int = -1
var _objects_spec: Array[Dictionary] = []
var _objects: Array[Dictionary] = []
var _hover_obj: int = -1
var _fit_radius: float = 1.0
var _fit_height: float = 1.0
var _user_zoomed: bool = false


func _init(p: Dictionary = {}, height: float = 340.0, is_expanded: bool = false) -> void:
	params = p.duplicate()
	_height = height
	expanded = is_expanded
	_objects_spec = parse_objects(params.get("_lines", PackedStringArray()))
	var fallback: String = "shapes" if not _objects_spec.is_empty() else "galaxy"
	preset = str(params.get("preset", fallback)).strip_edges().to_lower()
	if preset == "cards":
		preset = "flashcards"
	if not PRESETS.has(preset):
		preset = fallback


## Parse a ```3d block: the fence info ("3d galaxy") plus "key: value" lines.
static func parse_block(info: String, lines: PackedStringArray) -> Dictionary:
	var p: Dictionary = {}
	var words: PackedStringArray = info.split(" ", false)
	if words.size() > 1:
		p["preset"] = words[1].to_lower()
	for line in lines:
		var i: int = line.find(":")
		if i > 0:
			p[line.substr(0, i).strip_edges().to_lower()] = line.substr(i + 1).strip_edges()
	p["_lines"] = lines.duplicate()   # raw lines, for repeated keys (quiz q:/a:)
	return p


static func is_scene_fence(info: String) -> bool:
	var lang: String = info.strip_edges().split(" ", false)[0].to_lower() if info.strip_edges() != "" else ""
	return lang == "3d" or lang == "scene3d"


static func from_block(info: String, lines: PackedStringArray) -> NoteScene3D:
	var p: Dictionary = parse_block(info, lines)
	var h: float = clampf(float(p.get("height", "340")), 180.0, 900.0)
	return NoteScene3D.new(p, h)


static func template(preset_name: String) -> String:
	if preset_name == "shapes":
		return "```3d\ncube: red\nsphere: blue\ncone: yellow\ncaption: My shapes\n```"
	if preset_name == "quiz":
		return "```3d\npreset: quiz\ncaption: Check yourself\nq: Your question?\na: A wrong answer\na*: The right answer (marked with *)\na: Another wrong answer\na: One more wrong answer\nwhy: One line on why it's right.\nlearn: Note That Explains It\n```"
	if preset_name == "flashcards":
		return "```3d\npreset: flashcards\ncaption: My flashcards\nq: Front of the card (the question)\na: Back of the card (the answer)\nq: Second card\na: Its answer\n```"
	return "```3d\npreset: %s\ncaption: %s\n```" % [preset_name, PRESETS.get(preset_name, "")]


# ── Card UI ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	theme_type_variation = &"SceneCard"
	clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW   # rounded corners clip the 3D
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if expanded:
		size_flags_vertical = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	add_child(vbox)

	_container = SubViewportContainer.new()
	_container.stretch = true
	_container.custom_minimum_size = Vector2(0, 0 if expanded else _height)
	_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_container.mouse_default_cursor_shape = Control.CURSOR_DRAG
	_container.gui_input.connect(_on_input)
	vbox.add_child(_container)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_container.add_child(_viewport)

	var footer := MarginContainer.new()
	footer.add_theme_constant_override("margin_left", 14)
	footer.add_theme_constant_override("margin_right", 8)
	footer.add_theme_constant_override("margin_top", 6)
	footer.add_theme_constant_override("margin_bottom", 6)
	vbox.add_child(footer)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	footer.add_child(row)

	var caption := Label.new()
	caption.text = "◆  " + str(params.get("caption", PRESETS[preset]))
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.clip_text = true
	caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	caption.add_theme_color_override("font_color", Color("c8c8d0"))
	caption.add_theme_font_size_override("font_size", 12)
	row.add_child(caption)

	var hint := Label.new()
	hint.text = "drag to orbit  ·  %sscroll to zoom" % ("" if expanded else "ctrl+")
	if preset == "graph":
		hint.text += "  ·  double-click to open"
	elif preset == "quiz":
		hint.text = "click an answer"
	elif preset == "flashcards":
		hint.text = "click the card to flip it"
	elif not _objects_spec.is_empty():
		hint.text += "  ·  hover a shape"
	hint.add_theme_color_override("font_color", Color("6c6c76"))
	hint.add_theme_font_size_override("font_size", 11)
	row.add_child(hint)

	var btn := Button.new()
	btn.theme_type_variation = &"StageButton"
	btn.text = "Close  esc" if expanded else "Expand"
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.pressed.connect(_on_expand_pressed)
	row.add_child(btn)

	_build_stage()


func _on_expand_pressed() -> void:
	if expanded:
		closed.emit()
		return
	var n: Node = self
	while n != null and not n.has_method("show_scene_overlay"):
		n = n.get_parent()
	if n != null:
		n.show_scene_overlay(params)


# ── Stage ───────────────────────────────────────────────────────────────────

func _build_stage() -> void:
	_env = _make_env()
	var we := WorldEnvironment.new()
	we.environment = _env
	_viewport.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.85, 0.7, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	_viewport.add_child(sun)

	_content = Node3D.new()
	_viewport.add_child(_content)
	_camera = Camera3D.new()
	_camera.fov = 48.0
	_camera.far = 200.0
	_viewport.add_child(_camera)
	_camera.current = true

	match preset:
		"galaxy": _build_galaxy()
		"knot": _build_knot()
		"terrain": _build_terrain()
		"waves": _build_waves()
		"atom": _build_atom()
		"graph": _build_graph()
		"quiz": _build_quiz()
		"flashcards": _build_flashcards()
		"shapes": _build_shapes()
	if preset not in ["shapes", "quiz", "flashcards"] and not _objects_spec.is_empty():
		_place_objects(false)   # shapes can float in any scene
	if params.has("autorotate"):
		_autorotate = str(params.autorotate).to_lower() in ["true", "yes", "on", "1"]
	_update_camera()


func _make_env() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = STAGE_BG
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("2b3150")
	sky_mat.sky_horizon_color = Color("6a5a58")
	sky_mat.ground_horizon_color = Color("3a2e2c")
	sky_mat.ground_bottom_color = Color("0b0b0f")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.55
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.glow_enabled = true
	env.glow_intensity = 0.85
	env.glow_bloom = 0.06
	env.glow_hdr_threshold = 1.0
	return env


func _speed() -> float:
	return clampf(float(params.get("speed", "1")), 0.0, 10.0)


func _color(key: String, fallback: Color) -> Color:
	var v: String = str(params.get(key, "")).strip_edges()
	return fallback if v == "" else Color.from_string(v, fallback)


static func _shader(code: String) -> Shader:
	if not _shader_cache.has(code):
		var s := Shader.new()
		s.code = code
		_shader_cache[code] = s
	return _shader_cache[code]


func _emissive(color: Color, energy: float, metallic: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	m.metallic = metallic
	m.roughness = 0.35
	return m


func _sphere(radius: float, mat: Material, segments: int = 24) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = segments
	mesh.rings = segments / 2
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	return mi


## Background stars on a shell around the scene.
func _add_starfield(count: int, r_min: float, r_max: float, seed_value: int = 11) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var mm := _star_multimesh(count)
	for i in range(count):
		var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var tint: Color = Color("aab4ff").lerp(Color("ffd9b0"), rng.randf())
		var b: float = rng.randf_range(0.15, 0.55)
		mm.set_instance_transform(i, Transform3D(Basis(), dir * rng.randf_range(r_min, r_max)))
		mm.set_instance_color(i, Color(tint.r * b, tint.g * b, tint.b * b, rng.randf_range(1.5, 3.5)))
	_viewport.add_child(_star_instance(mm))


func _star_multimesh(count: int) -> MultiMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.09, 0.09)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = count
	return mm


func _star_instance(mm: MultiMesh) -> MultiMeshInstance3D:
	var mat := ShaderMaterial.new()
	mat.shader = _shader(SHADER_STARS)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.custom_aabb = AABB(Vector3(-60, -60, -60), Vector3(120, 120, 120))
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi


# ── Presets ─────────────────────────────────────────────────────────────────

func _build_galaxy() -> void:
	var inner: Color = _color("color", Color("ffb37a"))
	var outer: Color = _color("color2", Color("6c8cff"))
	var nebula: Color = Color("ff6fae")
	var arms: int = clampi(int(params.get("arms", "4")), 1, 12)
	var count: int = clampi(int(params.get("stars", "16000")), 500, 60000)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var mm := _star_multimesh(count + 1)
	var radius: float = 4.2
	for i in range(count):
		var kind: float = rng.randf()
		var pos: Vector3
		var col: Color
		var size: float
		if kind < 0.16:
			# Bulge: warm, dense, slightly flattened ball in the middle
			pos = Vector3(rng.randfn(), rng.randfn() * 0.55, rng.randfn()) * 0.45
			col = Color(1.0, 0.92, 0.8).lerp(inner, rng.randf() * 0.6) * rng.randf_range(0.35, 0.9)
			size = rng.randf_range(0.3, 0.9)
		elif kind < 0.34:
			# Disk: dim stars between the arms
			var r: float = sqrt(rng.randf()) * radius
			var ang: float = rng.randf() * TAU
			pos = Vector3(cos(ang) * r, rng.randfn(0.0, 0.06), sin(ang) * r)
			col = outer.lerp(Color.WHITE, 0.5) * rng.randf_range(0.12, 0.35)
			size = rng.randf_range(0.25, 0.6)
		else:
			# Arms: logarithmic-ish spiral, tighter the further out
			var t: float = pow(rng.randf(), 0.75)
			var r: float = 0.35 + t * radius
			var lateral: float = rng.randfn(0.0, 0.16 + 0.1 * t)
			var ang: float = float(i % arms) * TAU / arms + r * 1.45 + lateral / maxf(r, 0.5)
			pos = Vector3(cos(ang) * r, rng.randfn(0.0, 0.05 + 0.08 * (1.0 - t)), sin(ang) * r)
			col = inner.lerp(outer, clampf(t * 1.4, 0.0, 1.0))
			if rng.randf() < 0.06:
				col = nebula   # star-forming knots along the arms
				size = rng.randf_range(0.8, 1.6)
			else:
				size = rng.randf_range(0.25, 0.85)
			col = col * rng.randf_range(0.35, 1.0)
		mm.set_instance_transform(i, Transform3D(Basis(), pos))
		mm.set_instance_color(i, Color(col.r, col.g, col.b, size))
	# Core glow: one huge, soft sprite in the middle
	mm.set_instance_transform(count, Transform3D())
	mm.set_instance_color(count, Color(inner.r * 0.35, inner.g * 0.28, inner.b * 0.22, 26.0))
	var galaxy := _star_instance(mm)
	(galaxy.material_override as ShaderMaterial).set_shader_parameter("energy", 2.0)
	_content.add_child(galaxy)
	_add_starfield(1400, 25.0, 45.0)
	_distance = 8.8
	_pitch = -0.75
	_updaters.append(func(d: float) -> void: _content.rotate_y(-d * 0.07 * _speed()))


static func _knot_point(p: int, q: int, big_r: float, small_r: float, t: float) -> Vector3:
	var rr: float = big_r + small_r * cos(q * t)
	return Vector3(rr * cos(p * t), small_r * sin(q * t), rr * sin(p * t))


## Tube mesh swept along a (p, q) torus knot with SurfaceTool. The tube frame
## uses the offset from the torus core circle, which is periodic, so the tube
## closes without a twist seam.
static func _torus_knot_mesh(p: int, q: int, big_r: float, small_r: float, tube: float, seg: int = 480, sides: int = 28) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(seg + 1):
		var t: float = TAU * float(i) / float(seg)
		var pt: Vector3 = _knot_point(p, q, big_r, small_r, t)
		var tangent: Vector3 = (_knot_point(p, q, big_r, small_r, t + 0.001) - _knot_point(p, q, big_r, small_r, t - 0.001)).normalized()
		var core := Vector3(cos(p * t), 0.0, sin(p * t)) * big_r
		var n: Vector3 = pt - core
		n = (n - tangent * n.dot(tangent)).normalized()
		var b: Vector3 = tangent.cross(n)
		for j in range(sides + 1):
			var a: float = TAU * float(j) / float(sides)
			var dir: Vector3 = n * cos(a) + b * sin(a)
			st.set_normal(dir)
			st.set_uv(Vector2(float(i) / seg, float(j) / sides))
			st.add_vertex(pt + dir * tube)
	var row: int = sides + 1
	for i in range(seg):
		for j in range(sides):
			var a0: int = i * row + j
			var b0: int = a0 + row
			st.add_index(a0)
			st.add_index(b0)
			st.add_index(a0 + 1)
			st.add_index(a0 + 1)
			st.add_index(b0)
			st.add_index(b0 + 1)
	return st.commit()


func _build_knot() -> void:
	var c1: Color = _color("color", Color("d97757"))
	var c2: Color = _color("color2", Color("6c8cff"))
	var p: int = clampi(int(params.get("p", "2")), 1, 9)
	var q: int = clampi(int(params.get("q", "3")), 1, 9)
	var mesh_i := MeshInstance3D.new()
	mesh_i.mesh = _torus_knot_mesh(p, q, 1.5, 0.7, 0.24)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c1
	mat.metallic = 0.9
	mat.roughness = 0.2
	mat.rim_enabled = true
	mat.rim = 0.35
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_i.material_override = mat
	_content.add_child(mesh_i)

	# Glowing beads riding along the knot
	var beads: Array[MeshInstance3D] = []
	var bead_mat := _emissive(c2, 7.0)
	for i in range(16):
		var bead := _sphere(0.07, bead_mat, 12)
		_content.add_child(bead)
		beads.append(bead)
	_updaters.append(func(d: float) -> void:
		_content.rotate_y(d * 0.18 * _speed())
		_content.rotation.x = sin(_time * 0.3) * 0.25
		for i in range(beads.size()):
			var t: float = fmod(float(i) / beads.size() + _time * 0.035 * _speed(), 1.0) * TAU
			var pt: Vector3 = _knot_point(p, q, 1.5, 0.7, t)
			var core := Vector3(cos(p * t), 0.0, sin(p * t)) * 1.5
			beads[i].position = pt + (pt - core).normalized() * 0.27)

	for spec in [[c1, Vector3(3, 2, 3)], [c2, Vector3(-3, -1.5, -2.5)]]:
		var light := OmniLight3D.new()
		light.light_color = spec[0]
		light.light_energy = 4.0
		light.omni_range = 10.0
		light.position = spec[1]
		_viewport.add_child(light)
	_add_starfield(900, 20.0, 40.0)
	_distance = 7.5
	_pitch = -0.35


func _build_terrain() -> void:
	var c1: Color = _color("color", Color("ff5fa2"))
	var c2: Color = _color("color2", Color("3b2b6e"))
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.004
	noise.fractal_octaves = 5
	noise.seed = int(params.get("seed", "3"))
	var tex := NoiseTexture2D.new()
	tex.width = 512
	tex.height = 512
	tex.seamless = true
	tex.noise = noise
	var mat := ShaderMaterial.new()
	mat.shader = _shader(SHADER_TERRAIN)
	mat.set_shader_parameter("noise_tex", tex)
	mat.set_shader_parameter("height", 2.4)
	mat.set_shader_parameter("speed", 0.015 * _speed())
	mat.set_shader_parameter("low_color", Color("120e22"))
	mat.set_shader_parameter("high_color", c2)
	mat.set_shader_parameter("line_color", c1)
	var plane := PlaneMesh.new()
	plane.size = Vector2(16, 16)
	plane.subdivide_width = 220
	plane.subdivide_depth = 220
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = mat
	mi.custom_aabb = AABB(Vector3(-8, -1, -8), Vector3(16, 6, 16))
	_content.add_child(mi)

	var sun_mat := ShaderMaterial.new()
	sun_mat.shader = _shader(SHADER_SUN)
	sun_mat.set_shader_parameter("top", Color("ffd27a"))
	sun_mat.set_shader_parameter("bottom", c1)
	sun_mat.set_shader_parameter("radius", 2.6)
	var sun := _sphere(2.6, sun_mat, 48)
	sun.position = Vector3(0, 1.4, -11)
	_content.add_child(sun)

	_env.fog_enabled = true
	_env.fog_light_color = Color("1c1230")
	_env.fog_density = 0.06
	_env.fog_sky_affect = 0.0
	_env.background_color = Color("120c1e")
	_add_starfield(600, 30.0, 50.0)
	_target = Vector3(0, 0.6, 0)
	_distance = 6.8
	_pitch = -0.22
	_yaw = 0.0
	_autorotate = false


func _build_waves() -> void:
	var c1: Color = _color("color", Color("3a7bff"))
	var c2: Color = _color("color2", Color("ff9a5c"))
	var n: int = 44
	var spacing: float = 0.2
	var box := BoxMesh.new()
	box.size = Vector3(0.16, 1.0, 0.16)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = n * n
	for x in range(n):
		for z in range(n):
			var pos := Vector3((x - n / 2.0) * spacing, 0.0, (z - n / 2.0) * spacing)
			mm.set_instance_transform(x * n + z, Transform3D(Basis(), pos))
	var mat := ShaderMaterial.new()
	mat.shader = _shader(SHADER_WAVES)
	mat.set_shader_parameter("color_a", c1)
	mat.set_shader_parameter("color_b", c2)
	mat.set_shader_parameter("speed", _speed())
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.custom_aabb = AABB(Vector3(-5, -1, -5), Vector3(10, 4, 10))
	_content.add_child(mmi)
	_target = Vector3(0, 0.4, 0)
	_distance = 9.5
	_pitch = -0.55


func _build_atom() -> void:
	var c1: Color = _color("color", Color("6cc4ff"))
	var c2: Color = _color("color2", Color("d97757"))
	# Nucleus: particles on a Fibonacci sphere, alternating colours
	var nucleus := Node3D.new()
	_content.add_child(nucleus)
	var count: int = 18
	for i in range(count):
		var y: float = 1.0 - 2.0 * (float(i) + 0.5) / count
		var r: float = sqrt(1.0 - y * y)
		var a: float = float(i) * 2.39996
		var mat := ShaderMaterial.new()
		mat.shader = _shader(SHADER_FRESNEL)
		mat.set_shader_parameter("tint", c2 if i % 2 == 0 else Color("e8e8f0"))
		var ball := _sphere(0.2, mat, 20)
		ball.position = Vector3(cos(a) * r, y, sin(a) * r) * 0.3
		nucleus.add_child(ball)

	# Three tilted orbitals, each with an electron
	var ring_mat := _emissive(c1, 2.2)
	var electrons: Array[MeshInstance3D] = []
	var bases: Array[Basis] = []
	for k in range(3):
		var basis := Basis.from_euler(Vector3(1.1, k * TAU / 3.0, 0.0))
		var torus := TorusMesh.new()
		torus.inner_radius = 2.0
		torus.outer_radius = 2.035
		torus.rings = 96
		var ring := MeshInstance3D.new()
		ring.mesh = torus
		ring.material_override = ring_mat
		ring.basis = basis
		_content.add_child(ring)
		var e := _sphere(0.09, _emissive(Color(1.0, 1.0, 1.0).lerp(c1, 0.4), 9.0), 16)
		_content.add_child(e)
		electrons.append(e)
		bases.append(basis)
	_updaters.append(func(d: float) -> void:
		nucleus.rotate_y(d * 0.4)
		nucleus.rotate_x(d * 0.23)
		_content.rotate_y(d * 0.08 * _speed())
		for k in range(electrons.size()):
			var a: float = _time * (1.6 + k * 0.35) * _speed() + k * 2.0
			electrons[k].position = bases[k] * (Vector3(cos(a), 0.0, sin(a)) * 2.0175))
	_add_starfield(1200, 18.0, 40.0)
	_distance = 8.0
	_pitch = -0.3


## The vault itself, as a 3D force-directed graph of [[wikilinks]].
func _build_graph() -> void:
	var accent: Color = _color("color", Color("d97757"))
	var base_col: Color = _color("color2", Color("8fa2ff"))
	var notes: Array = VaultStore.note_list
	var index_of: Dictionary = {}
	for i in range(notes.size()):
		index_of[notes[i].title.strip_edges().to_lower()] = i
	var re := RegEx.new()
	re.compile("\\[\\[([^\\]|]+)(?:\\|[^\\]]+)?\\]\\]")
	var edges: Array[Vector2i] = []
	var degree: Array[int] = []
	degree.resize(notes.size())
	degree.fill(0)
	for i in range(notes.size()):
		for m in re.search_all(notes[i].raw_text):
			var j: int = index_of.get(m.get_string(1).strip_edges().to_lower(), -1)
			if j >= 0 and j != i and not edges.has(Vector2i(j, i)) and not edges.has(Vector2i(i, j)):
				edges.append(Vector2i(i, j))
				degree[i] += 1
				degree[j] += 1

	# Small 3D force simulation, run up front
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var pos: Array[Vector3] = []
	for i in range(notes.size()):
		pos.append(Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized() * 2.0)
	for _iter in range(300):
		var force: Array[Vector3] = []
		for i in range(pos.size()):
			force.append(-pos[i] * 0.02)
		for i in range(pos.size()):
			for j in range(i + 1, pos.size()):
				var d: Vector3 = pos[i] - pos[j]
				var f: Vector3 = d.normalized() * (1.2 / maxf(d.length_squared(), 0.05))
				force[i] += f
				force[j] -= f
		for e in edges:
			var d: Vector3 = pos[e.y] - pos[e.x]
			var f: Vector3 = d.normalized() * (d.length() - 1.6) * 0.08
			force[e.x] += f
			force[e.y] -= f
		for i in range(pos.size()):
			pos[i] += force[i].limit_length(0.3)

	var current: ContentLayer = LayerEngine.current_note
	for i in range(notes.size()):
		var is_current: bool = notes[i] == current
		var col: Color = accent if is_current else base_col
		var radius: float = 0.11 + 0.035 * minf(degree[i], 6)
		var ball := _sphere(radius, _emissive(col, 3.0 if is_current else 1.4), 20)
		ball.position = pos[i]
		_content.add_child(ball)
		var label := Label3D.new()
		var title: String = notes[i].title.strip_edges()
		label.text = title if title != "" and title != "untitled" else "Untitled"
		label.font = AppTheme.FONT_SANS
		label.font_size = 48
		label.pixel_size = 0.005
		label.outline_size = 10
		label.outline_modulate = Color(0, 0, 0, 0.7)
		label.modulate = Color("d8d8e0")
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.position = pos[i] + Vector3(0, radius + 0.2, 0)
		_content.add_child(label)
		_graph_nodes.append({"title": notes[i].title, "ball": ball, "label": label})

	if not edges.is_empty():
		var line_mat := StandardMaterial3D.new()
		line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		line_mat.vertex_color_use_as_albedo = true
		line_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		var im := ImmediateMesh.new()
		im.surface_begin(Mesh.PRIMITIVE_LINES, line_mat)
		for e in edges:
			im.surface_set_color(Color(base_col, 1.0) * 0.6)
			im.surface_add_vertex(pos[e.x])
			im.surface_set_color(Color(base_col, 1.0) * 0.6)
			im.surface_add_vertex(pos[e.y])
		im.surface_end()
		var lines := MeshInstance3D.new()
		lines.mesh = im
		_content.add_child(lines)

	_add_starfield(1000, 20.0, 40.0)
	var extent: float = 2.0
	for p in pos:
		extent = maxf(extent, p.length())
	_distance = extent * 2.0 + 1.2
	_pitch = -0.35


# ── Camera & input ──────────────────────────────────────────────────────────

func _update_camera() -> void:
	if _camera == null or not _camera.is_inside_tree():
		return
	var b := Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	_camera.position = _target + b * Vector3(0, 0, _distance)
	_camera.look_at(_target, Vector3.UP)


func _process(delta: float) -> void:
	if _viewport == null:
		return
	# Only render while the card is actually on screen
	var shown: bool = is_visible_in_tree() and _on_screen()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if shown else SubViewport.UPDATE_DISABLED
	if not shown:
		return
	_time += delta
	_idle += delta
	if _autorotate and not _dragging and _idle > 2.5:
		_yaw += delta * 0.1
		_update_camera()
	for u in _updaters:
		u.call(delta)


func _on_screen() -> bool:
	if _scroll_clip == null:
		var n: Node = get_parent()
		while n != null and not (n is ScrollContainer):
			n = n.get_parent()
		_scroll_clip = n as Control if n != null else get_viewport().get_parent() as Control
	var area: Rect2 = _scroll_clip.get_global_rect() if _scroll_clip != null else get_viewport_rect()
	return area.intersects(get_global_rect())


func _on_input(event: InputEvent) -> void:
	if preset in ["quiz", "flashcards"]:
		_quiz_input(event)
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and mb.double_click:
				_on_double_click(mb.position)
			_dragging = mb.pressed and not mb.double_click
			_idle = 0.0
			_container.accept_event()
		elif mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and (mb.ctrl_pressed or mb.meta_pressed or expanded):
			if mb.pressed:
				var factor: float = 0.9 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.1
				_distance = clampf(_distance * factor, 1.5, 60.0)
				_user_zoomed = true
				_idle = 0.0
				_update_camera()
			_container.accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging:
			_yaw -= mm.relative.x * 0.008
			_pitch = clampf(_pitch - mm.relative.y * 0.008, -1.45, 1.45)
			_idle = 0.0
			_update_camera()
		elif not _graph_nodes.is_empty():
			_set_hovered(_pick(mm.position))
		elif not _objects.is_empty():
			_set_hover_obj(_pick_object(mm.position))


func _pick(screen: Vector2) -> int:
	var best: int = -1
	var best_d: float = 22.0
	for i in range(_graph_nodes.size()):
		var world: Vector3 = (_graph_nodes[i].ball as Node3D).global_position
		if _camera.is_position_behind(world):
			continue
		var d: float = _camera.unproject_position(world).distance_to(screen)
		if d < best_d:
			best = i
			best_d = d
	return best


func _set_hovered(i: int) -> void:
	if i == _hovered:
		return
	if _hovered >= 0:
		_graph_nodes[_hovered].ball.scale = Vector3.ONE
		_graph_nodes[_hovered].label.modulate = Color("d8d8e0")
	_hovered = i
	if i >= 0:
		_graph_nodes[i].ball.scale = Vector3.ONE * 1.5
		_graph_nodes[i].label.modulate = _color("color", Color("d97757")).lightened(0.25)
	_container.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if i >= 0 else Control.CURSOR_DRAG


func _on_double_click(screen: Vector2) -> void:
	if _graph_nodes.is_empty():
		return
	var i: int = _pick(screen)
	if i < 0:
		return
	var n: Node = self
	while n != null and not n.has_method("open_note_by_title"):
		n = n.get_parent()
	if n != null:
		# Deferred: opening a note re-renders Read view, which frees this card
		n.call_deferred("open_note_by_title", str(_graph_nodes[i].title))
		if expanded:
			closed.emit()


# ── Quiz ────────────────────────────────────────────────────────────────────
#
#     ```3d
#     preset: quiz
#     q: Which node draws a 3D world inside a 2D UI?
#     a: CanvasLayer
#     a*: SubViewport          <- the * marks the right answer
#     a: Control
#     a: Node2D
#     why: A SubViewport renders its own World3D into a texture.
#     learn: Nodes and Scenes  <- note opened by the Review tile
#     q: ...next question...
#     ```
#
# Answers are 3D tiles picked with a camera ray (no physics needed). After
# a wrong answer a "Review" tile opens the note that explains the idea; the
# results screen lists every note worth revisiting.

var _quiz: Array[Dictionary] = []
var _qi: int = 0
var _score: int = 0
var _missed: Array[String] = []
var _answered: bool = false
var _quiz_root: Node3D
var _tiles: Array[Dictionary] = []
var _hover_tile: int = -1
var _mouse_ndc: Vector2 = Vector2.ZERO
var _feedback: Label3D
var _quiz_spinners: Array[Node3D] = []


static func parse_quiz(lines: PackedStringArray) -> Array[Dictionary]:
	var qs: Array[Dictionary] = []
	for raw in lines:
		var line: String = str(raw).strip_edges()
		var i: int = line.find(":")
		if i <= 0:
			continue
		var key: String = line.substr(0, i).strip_edges().to_lower()
		var val: String = line.substr(i + 1).strip_edges()
		if key in ["q", "question"]:
			qs.append({"q": val, "choices": [], "correct": -1, "learn": "", "why": "", "show": ""})
		elif qs.is_empty():
			continue
		elif key in ["a", "a*", "*a"]:
			if key != "a":
				qs[-1].correct = qs[-1].choices.size()
			qs[-1].choices.append(val)
		elif key in ["learn", "review", "see"]:
			qs[-1].learn = val.trim_prefix("[[").trim_suffix("]]").strip_edges()
		elif key in ["why", "explain"]:
			qs[-1].why = val
		elif key == "show":
			qs[-1].show = val
	return qs.filter(func(q: Dictionary) -> bool: return q.choices.size() >= 2 and q.correct >= 0)


func _label3d(text: String, size: int, color: Color, width_units: float = 0.0, bold: bool = false) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = AppTheme._weight(650) if bold else AppTheme.FONT_SANS
	l.font_size = size
	l.pixel_size = 0.006
	l.modulate = color
	l.outline_size = 0
	l.double_sided = false
	if width_units > 0.0:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.width = width_units / l.pixel_size
	return l


func _build_quiz() -> void:
	_quiz = parse_quiz(params.get("_lines", PackedStringArray()))
	_build_board()
	if _quiz.is_empty():
		_quiz_root.add_child(_label3d("Add questions to this block:\nq: question   a: wrong   a*: right   learn: Note", 44, Color("c8c8d0"), 9.0))
		return
	_show_question()


## The shared stage for quizzes and flashcards: starfield, slow rings, a
## light, and _quiz_root for the tiles.
func _build_board() -> void:
	_autorotate = false
	_distance = 7.4
	_pitch = 0.0
	_yaw = 0.0
	_env.background_color = Color("0c0d14")
	_env.glow_intensity = 1.0
	_add_starfield(900, 16.0, 40.0)

	# Slow decorative rings behind the board
	var ring_mat := _emissive(_color("color", Color("d97757")), 1.4)
	for k in range(3):
		var torus := TorusMesh.new()
		torus.inner_radius = 3.6 + k * 1.3
		torus.outer_radius = torus.inner_radius + 0.025
		torus.rings = 128
		var ring := MeshInstance3D.new()
		ring.mesh = torus
		ring.material_override = ring_mat
		ring.position = Vector3(0, 0, -4.5)
		ring.rotation = Vector3(PI / 2.0 + 0.25 * (k - 1), 0.2 * k, 0)
		_content.add_child(ring)
		_updaters.append(func(d: float) -> void: ring.rotate_object_local(Vector3.UP, d * (0.12 + 0.07 * k) * (1 if k % 2 == 0 else -1)))

	var key := DirectionalLight3D.new()
	key.rotation = Vector3(-0.3, -0.4, 0)
	key.light_energy = 0.6
	_viewport.add_child(key)

	_quiz_root = Node3D.new()
	_content.add_child(_quiz_root)
	_updaters.append(_quiz_tick)


func _quiz_tick(d: float) -> void:
	# Camera leans gently toward the mouse; tiles bob a little.
	# Back the camera off until the whole board (±4.8 x ±3.1 units) fits,
	# whatever the card's aspect ratio.
	var sz: Vector2 = _container.size
	if sz.x > 1.0 and sz.y > 1.0:
		var half_fov: float = tan(deg_to_rad(_camera.fov) / 2.0)
		var need: float = maxf(3.15 / half_fov, 4.8 / (half_fov * sz.x / sz.y))
		_distance = lerpf(_distance, need + 0.2, minf(d * 6.0, 1.0)) if _time > 0.1 else need + 0.2
	_yaw = lerpf(_yaw, -_mouse_ndc.x * 0.07, minf(d * 4.0, 1.0))
	_pitch = lerpf(_pitch, _mouse_ndc.y * 0.05, minf(d * 4.0, 1.0))
	_update_camera()
	for i in range(_tiles.size()):
		var t: Dictionary = _tiles[i]
		if is_instance_valid(t.root):
			t.root.position.y = t.base.y + sin(_time * 1.3 + i * 1.7) * 0.025
	for sp in _quiz_spinners:
		if is_instance_valid(sp):
			sp.rotate_y(d * 0.6)


func _clear_quiz() -> void:
	for c in _quiz_root.get_children():
		c.queue_free()
	_tiles.clear()
	_quiz_spinners.clear()
	_hover_tile = -1
	_feedback = null


func _make_tile(text: String, pos: Vector3, size: Vector3, glow: Color, action: String, letter: String = "") -> Dictionary:
	var root := Node3D.new()
	root.position = pos
	_quiz_root.add_child(root)

	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color("191a24")
	body_mat.metallic = 0.5
	body_mat.roughness = 0.3
	body_mat.emission_enabled = true
	body_mat.emission = glow
	body_mat.emission_energy_multiplier = 0.06
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	body.mesh = box
	body.material_override = body_mat
	root.add_child(body)

	# Glowing frame: a slightly larger, thinner box just behind the tile
	var frame_mat := _emissive(glow, 0.5)
	var frame := MeshInstance3D.new()
	var fbox := BoxMesh.new()
	fbox.size = Vector3(size.x + 0.07, size.y + 0.07, size.z * 0.5)
	frame.mesh = fbox
	frame.material_override = frame_mat
	frame.position.z = -size.z * 0.3
	root.add_child(frame)

	var z: float = size.z / 2.0 + 0.012
	var text_left: float = -size.x / 2.0 + 0.3
	if letter != "":
		var badge := _label3d(letter, 46, glow.lightened(0.2), 0.0, true)
		badge.position = Vector3(-size.x / 2.0 + 0.32, 0, z)
		root.add_child(badge)
		text_left = -size.x / 2.0 + 0.62
	var label := _label3d(text, 38, Color("e6e6ee"), size.x - (0.95 if letter != "" else 0.5))
	if letter != "":
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		label.position = Vector3(text_left, 0, z)   # left-aligned Label3D pivots at its left edge
	else:
		label.position = Vector3(0, 0, z)
	root.add_child(label)

	var tile: Dictionary = {
		"root": root, "half": Vector3(size.x, size.y, size.z) / 2.0 + Vector3(0.035, 0.035, 0.0),
		"action": action, "body": body_mat, "frame": frame_mat, "label": label,
		"base": pos, "glow": glow, "enabled": true,
	}
	_tiles.append(tile)
	# Pop in
	root.scale = Vector3.ONE * 0.85
	var tw := root.create_tween()
	tw.tween_property(root, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT).set_delay(0.04 * _tiles.size())
	return tile


func _show_question() -> void:
	_clear_quiz()
	_answered = false
	var q: Dictionary = _quiz[_qi]
	var letters: Array[String] = ["A", "B", "C", "D", "E", "F"]
	var n: int = mini(q.choices.size(), 6)
	var objs: Array[Dictionary] = []
	for i in range(n):
		objs.append(answer_object(q.choices[i]))
	var all_objects: bool = objs.all(func(o: Dictionary) -> bool: return not o.is_empty())
	var prop: Dictionary = {}
	if q.show != "":
		prop = answer_object(q.show)
		if prop.is_empty():
			var words: PackedStringArray = q.show.split(" ", false)
			prop = parse_object(words[0], " ".join(words.slice(1))) if words.size() > 0 and SHAPES.has(words[0].to_lower()) else {}

	var progress := _label3d("QUESTION %d OF %d" % [_qi + 1, _quiz.size()], 30, Color("8a8a96"), 0.0, true)
	progress.position = Vector3(0, 2.55, 0)
	_quiz_root.add_child(progress)
	var question := _label3d(q.q, 58, Color("f2f2f6"), 9.4, true)
	question.position = Vector3(0, 1.75, 0)
	_quiz_root.add_child(question)

	if all_objects:
		# Clickable 3D shapes on pedestals, in a row
		var gap: float = minf(2.3, 9.2 / n)
		for i in range(n):
			_make_object_tile(objs[i], Vector3((i - (n - 1) / 2.0) * gap, -0.1, 0), letters[i], "answer:%d" % i)
	elif not prop.is_empty():
		# A shape to look at on the left, text answers stacked on the right
		var holder := Node3D.new()
		holder.position = Vector3(-3.0, 0.0, 0.2)
		_quiz_root.add_child(holder)
		var thing: Node3D = _make_object(prop, 1.7)
		holder.add_child(thing)
		var spinner: Node3D = thing.get_meta("spinner")
		_quiz_spinners.append(spinner)
		var pedestal := _pedestal(QUIZ_TILE)
		pedestal.position = Vector3(0, -1.0, 0)
		holder.add_child(pedestal)
		for i in range(n):
			var col: int = i % 2
			var row: int = i / 2
			_make_tile(q.choices[i], Vector3(0.0 + col * 3.0, 0.45 - row * 1.05, 0), Vector3(2.8, 0.82, 0.16), QUIZ_TILE, "answer:%d" % i, letters[i])
	else:
		var rows: int = ceili(n / 2.0)
		for i in range(n):
			var col: int = i % 2
			var row: int = i / 2
			var x: float = -2.3 + col * 4.6 if n > 1 else 0.0
			var y: float = 0.45 - row * (1.05 if rows <= 2 else 0.85)
			_make_tile(q.choices[i], Vector3(x, y, 0), Vector3(4.3, 0.82 if rows <= 2 else 0.7, 0.16), QUIZ_TILE, "answer:%d" % i, letters[i])

	_feedback = _label3d("", 40, Color("c8c8d0"), 9.6)
	_feedback.position = Vector3(0, -1.75, 0.1)
	_quiz_root.add_child(_feedback)


func _pedestal(glow: Color) -> Node3D:
	var root := Node3D.new()
	var disc := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.7
	cyl.bottom_radius = 0.78
	cyl.height = 0.16
	cyl.radial_segments = 48
	disc.mesh = cyl
	var body := StandardMaterial3D.new()
	body.albedo_color = Color("191a24")
	body.metallic = 0.5
	body.roughness = 0.3
	body.emission_enabled = true
	body.emission = glow
	body.emission_energy_multiplier = 0.06
	disc.material_override = body
	root.add_child(disc)
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.76
	torus.outer_radius = 0.8
	torus.rings = 64
	ring.mesh = torus
	var frame := _emissive(glow, 0.5)
	ring.material_override = frame
	ring.position.y = 0.08
	root.add_child(ring)
	root.set_meta("body", body)
	root.set_meta("frame", frame)
	return root


## A quiz answer that is a 3D object: shape on a glowing pedestal + letter.
func _make_object_tile(o: Dictionary, pos: Vector3, letter: String, action: String) -> Dictionary:
	var root := Node3D.new()
	root.position = pos
	_quiz_root.add_child(root)
	var pedestal := _pedestal(QUIZ_TILE)
	pedestal.position.y = -0.62
	root.add_child(pedestal)
	var thing: Node3D = _make_object(o, 1.05)
	thing.position.y = 0.05
	root.add_child(thing)
	_quiz_spinners.append(thing.get_meta("spinner"))
	var badge := _label3d(letter, 46, QUIZ_TILE.lightened(0.2), 0.0, true)
	badge.position = Vector3(0, -0.98, 0.5)
	root.add_child(badge)
	var tile: Dictionary = {
		"root": root, "half": Vector3(0.85, 1.0, 0.85), "action": action,
		"body": pedestal.get_meta("body"), "frame": pedestal.get_meta("frame"),
		"label": badge, "base": pos, "glow": QUIZ_TILE, "enabled": true,
	}
	_tiles.append(tile)
	root.scale = Vector3.ONE * 0.85
	var tw := root.create_tween()
	tw.tween_property(root, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT).set_delay(0.04 * _tiles.size())
	return tile


func _answer(choice: int) -> void:
	if _answered or _qi >= _quiz.size():
		return
	_answered = true
	var q: Dictionary = _quiz[_qi]
	var right: bool = choice == q.correct
	var letters: Array[String] = ["A", "B", "C", "D", "E", "F"]
	for t in _tiles:
		t.enabled = false
		_tile_glow(t, 0.25, 0.04)
	ProgressStore.record_answer(str(params.get("_note", "")), int(params.get("_quiz_index", 0)), _qi, q.q, right, q.learn)
	_notify_progress()
	var correct_tile: Dictionary = _tiles[q.correct]
	_tint_tile(correct_tile, QUIZ_GREEN, 3.0)
	var pop: Tween = (correct_tile.root as Node3D).create_tween()
	pop.tween_property(correct_tile.root, "scale", Vector3.ONE * 1.07, 0.12)
	pop.tween_property(correct_tile.root, "scale", Vector3.ONE, 0.2)
	if right:
		_score += 1
		_confetti(correct_tile.root.position + Vector3(0, 0, 0.3))
		_feedback.text = "Correct!" + ("  " + q.why if q.why != "" else "")
		_feedback.modulate = QUIZ_GREEN.lightened(0.3)
	else:
		var chosen: Dictionary = _tiles[choice]
		_tint_tile(chosen, QUIZ_RED, 2.2)
		_shake(chosen.root)
		var right_obj: Dictionary = answer_object(q.choices[q.correct])
		var right_name: String = letters[q.correct] + (" (" + right_obj.name + ")" if not right_obj.is_empty() else "")
		_feedback.text = "Not quite — the answer is %s.%s" % [right_name, ("  " + q.why if q.why != "" else "")]
		_feedback.modulate = Color("ffb0a8")
		if q.learn != "" and not _missed.has(q.learn):
			_missed.append(q.learn)

	var last: bool = _qi == _quiz.size() - 1
	var next_text: String = "See results  ›" if last else "Next question  ›"
	var accent: Color = _color("color", Color("d97757"))
	if not right and q.learn != "":
		_make_tile("Review:  " + q.learn, Vector3(-2.05, -2.6, 0), Vector3(5.0, 0.6, 0.14), accent, "open:" + q.learn)
		_make_tile(next_text, Vector3(2.75, -2.6, 0), Vector3(2.9, 0.6, 0.14), QUIZ_TILE, "results" if last else "next")
	else:
		_make_tile(next_text, Vector3(0, -2.6, 0), Vector3(3.4, 0.6, 0.14), QUIZ_TILE, "results" if last else "next")


func _show_results() -> void:
	_clear_quiz()
	var total: int = _quiz.size()
	var perfect: bool = _score == total
	var passed: bool = ProgressStore.passes(_score, total)
	var note_title: String = str(params.get("_note", ""))
	ProgressStore.record_result(note_title, int(params.get("_quiz_index", 0)), _score, total)
	_report_score("quiz", int(params.get("_quiz_index", 0)), _score, total)
	_notify_progress()
	var accent: Color = _color("color", Color("d97757"))
	var head := _label3d("PASSED  ✓" if passed else "YOUR SCORE", 30, QUIZ_GREEN if passed else Color("8a8a96"), 0.0, true)
	head.position = Vector3(0, 2.5, 0)
	_quiz_root.add_child(head)
	var big := _label3d("%d / %d" % [_score, total], 190, QUIZ_GREEN if passed else accent, 0.0, true)
	big.position = Vector3(0, 1.45, 0)
	_quiz_root.add_child(big)
	var msg: String
	if perfect:
		msg = "Perfect — you know this material."
	elif passed:
		msg = "Passed! Worth a second look:"
	else:
		msg = "Get %d right to pass. Review these, then try again:" % ProgressStore.pass_mark(total)
	var sub := _label3d(msg, 44, Color("d8d8e0"), 9.0)
	sub.position = Vector3(0, 0.35, 0)
	_quiz_root.add_child(sub)
	var shown: int = mini(_missed.size(), 4)
	for i in range(shown):
		var x: float = (i % 2) * 4.2 - (2.1 if shown > 1 else 0.0)
		var y: float = -0.55 - (i / 2) * 0.8
		_make_tile("Review:  " + _missed[i], Vector3(x, y, 0), Vector3(3.9, 0.6, 0.14), accent, "open:" + _missed[i])
	var next_note: String = next_lesson() if passed else ""
	if next_note != "":
		_make_tile("Try again", Vector3(-3.0, -2.4, 0), Vector3(2.2, 0.6, 0.14), QUIZ_TILE, "retry")
		_make_tile("Next:  " + next_note + "  ›", Vector3(1.35, -2.4, 0), Vector3(6.1, 0.6, 0.14), QUIZ_GREEN, "open:" + next_note)
	else:
		_make_tile("Try again", Vector3(0, -2.4, 0), Vector3(2.8, 0.6, 0.14), QUIZ_TILE, "retry")
	if perfect:
		_confetti(Vector3(0, 1.4, 0.4), 160)


## Where "Next" goes after a pass: the block's next: setting, else the
## note's own "Next: [[...]]" line — but only from the note's last quiz.
func next_lesson() -> String:
	if params.has("next"):
		return str(params.next).trim_prefix("[[").trim_suffix("]]").strip_edges()
	var note_title: String = str(params.get("_note", ""))
	var note: ContentLayer = ProgressStore._find_note(note_title) if note_title != "" else null
	if note == null:
		return ""
	if int(params.get("_quiz_index", 0)) != ProgressStore.quiz_count(note.raw_text) - 1:
		return ""
	var rx := RegEx.new()
	rx.compile("(?m)^\\s*Next:\\s*\\[\\[([^\\]|]+)")
	var m := rx.search(note.raw_text)
	return m.get_string(1).strip_edges() if m != null else ""


## Start the quiz / deck over from the first question.
func restart() -> void:
	if preset == "quiz" and not _quiz.is_empty():
		_qi = 0
		_score = 0
		_missed.clear()
		_show_question()
	elif preset == "flashcards" and not _cards.is_empty():
		_ci = 0
		_score = 0
		_show_card()


## Tell the app (Learning Journey) this activity finished with a score.
func _report_score(kind: String, index: int, score: int, total: int) -> void:
	var note_title: String = str(params.get("_note", ""))
	if note_title == "":
		return
	var key: String = JourneyStore.activity_key(note_title, kind, index)
	var logged: int = JourneyStore.log_score(key, score, total, str(params.get("objective", "")))
	var n: Node = self
	while n != null and not n.has_method("on_activity_score"):
		n = n.get_parent()
	if n != null:
		n.on_activity_score(key, score, total, logged)


func _notify_progress() -> void:
	var n: Node = self
	while n != null and not n.has_method("on_progress_changed"):
		n = n.get_parent()
	if n != null:
		n.on_progress_changed()


func _activate(i: int) -> void:
	var action: String = _tiles[i].action
	if action.begins_with("answer:"):
		_answer(int(action.substr(7)))
	elif action == "next":
		_qi += 1
		_show_question()
	elif action == "results":
		_show_results()
	elif action == "retry":
		restart()
	elif action == "flip":
		_flip_card()
	elif action == "got" or action == "miss":
		_grade_card(action == "got")
	elif action.begins_with("open:"):
		var n: Node = self
		while n != null and not n.has_method("open_note_by_title"):
			n = n.get_parent()
		if n != null:
			n.call_deferred("open_note_by_title", action.substr(5))
			if expanded:
				closed.emit()


func _tint_tile(t: Dictionary, color: Color, energy: float) -> void:
	t.frame.emission = color
	t.frame.albedo_color = color
	t.frame.emission_energy_multiplier = energy
	t.body.emission = color
	t.body.emission_energy_multiplier = 0.18


func _tile_glow(t: Dictionary, frame_energy: float, body_energy: float) -> void:
	t.frame.emission_energy_multiplier = frame_energy
	t.body.emission_energy_multiplier = body_energy


func _shake(node: Node3D) -> void:
	var x0: float = node.position.x
	var tw := node.create_tween()
	for k in range(6):
		tw.tween_property(node, "position:x", x0 + (0.09 if k % 2 == 0 else -0.09) * (1.0 - k / 6.0), 0.05)
	tw.tween_property(node, "position:x", x0, 0.05)


func _confetti(at: Vector3, amount: int = 90) -> void:
	var p := CPUParticles3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.07, 0.11)
	var mat := ShaderMaterial.new()
	mat.shader = _shader(SHADER_CONFETTI)
	quad.material = mat
	p.mesh = quad
	p.amount = amount
	p.one_shot = true
	p.explosiveness = 0.95
	p.lifetime = 1.8
	p.direction = Vector3(0, 1, 0.3)
	p.spread = 70.0
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 5.5
	p.gravity = Vector3(0, -7.0, 0)
	p.angular_velocity_min = -540.0
	p.angular_velocity_max = 540.0
	p.particle_flag_rotate_y = true
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.25, 0.5, 0.75, 1.0])
	ramp.colors = PackedColorArray([Color("ffd166"), Color("3ddc84"), Color("6c8cff"), Color("ff5fa2"), Color("d97757")])
	p.color_initial_ramp = ramp
	p.position = at
	_quiz_root.add_child(p)
	p.emitting = true
	get_tree().create_timer(p.lifetime + 0.5).timeout.connect(p.queue_free)


static func _ray_box(o: Vector3, d: Vector3, h: Vector3) -> float:
	var tmin: float = -INF
	var tmax: float = INF
	for a in range(3):
		if absf(d[a]) < 1e-6:
			if o[a] < -h[a] or o[a] > h[a]:
				return -1.0
		else:
			var t1: float = (-h[a] - o[a]) / d[a]
			var t2: float = (h[a] - o[a]) / d[a]
			tmin = maxf(tmin, minf(t1, t2))
			tmax = minf(tmax, maxf(t1, t2))
	if tmax < maxf(tmin, 0.0):
		return -1.0
	return maxf(tmin, 0.0)


## Which enabled tile is under this viewport position? (-1 = none)
func _pick_tile(screen: Vector2) -> int:
	var origin: Vector3 = _camera.project_ray_origin(screen)
	var dir: Vector3 = _camera.project_ray_normal(screen)
	var best: int = -1
	var best_t: float = INF
	for i in range(_tiles.size()):
		var t: Dictionary = _tiles[i]
		if not t.enabled or not is_instance_valid(t.root):
			continue
		var inv: Transform3D = (t.root as Node3D).global_transform.affine_inverse()
		var hit: float = _ray_box(inv * origin, inv.basis * dir, t.half)
		if hit >= 0.0 and hit < best_t:
			best = i
			best_t = hit
	return best


## Screen position of a tile's centre (used by tests and keyboard focus).
func tile_screen_position(i: int) -> Vector2:
	return _camera.unproject_position((_tiles[i].root as Node3D).global_position)


func _set_hover_tile(i: int) -> void:
	if i == _hover_tile:
		return
	if _hover_tile >= 0 and _hover_tile < _tiles.size() and _tiles[_hover_tile].enabled:
		var old: Dictionary = _tiles[_hover_tile]
		_tile_glow(old, 0.5, 0.06)
		old.root.create_tween().tween_property(old.root, "position:z", old.base.z, 0.15)
	_hover_tile = i
	if i >= 0:
		var t: Dictionary = _tiles[i]
		_tile_glow(t, 2.6, 0.22)
		t.root.create_tween().tween_property(t.root, "position:z", t.base.z + 0.18, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_container.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if i >= 0 else Control.CURSOR_ARROW


func _quiz_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var pos: Vector2 = (event as InputEventMouseMotion).position
		var sz: Vector2 = _container.size
		if sz.x > 0 and sz.y > 0:
			_mouse_ndc = Vector2(pos.x / sz.x * 2.0 - 1.0, pos.y / sz.y * 2.0 - 1.0)
		_set_hover_tile(_pick_tile(pos))
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			var i: int = _pick_tile(mb.position)
			if i >= 0:
				_hover_tile = -1
				_activate(i)
			_container.accept_event()


# ── Flashcards ──────────────────────────────────────────────────────────────
#
#     ```3d
#     preset: flashcards
#     caption: Colour mixing
#     q: Red + yellow make…      (front)
#     a: Orange                  (back)
#     ```
#
# Click the card to flip it, then say honestly whether you knew it. The
# number you knew is the deck's score (reported to the Learning Journey).

var _cards: Array[Dictionary] = []
var _ci: int = 0
var _card_tile: Dictionary = {}
var _card_back: bool = false


static func parse_cards(lines: PackedStringArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var front: String = ""
	for line in lines:
		var s: String = line.strip_edges()
		if s.begins_with("q:"):
			front = s.substr(2).strip_edges()
		elif s.begins_with("a:") and front != "":
			out.append({"front": front, "back": s.substr(2).strip_edges()})
			front = ""
	return out


func _build_flashcards() -> void:
	_cards = parse_cards(params.get("_lines", PackedStringArray()))
	_build_board()
	if _cards.is_empty():
		_quiz_root.add_child(_label3d("Add cards to this block:\nq: front of the card   a: back of the card", 44, Color("c8c8d0"), 9.0))
		return
	_show_card()


func _show_card() -> void:
	_clear_quiz()
	_card_back = false
	var accent: Color = _color("color", Color("d97757"))
	var count := _label3d("CARD %d OF %d" % [_ci + 1, _cards.size()], 26, Color("8a8a96"), 0.0, true)
	count.position = Vector3(0, 2.65, 0)
	_quiz_root.add_child(count)
	_card_tile = _make_tile(_cards[_ci].front, Vector3(0, 0.85, 0), Vector3(7.4, 2.9, 0.18), QUIZ_TILE, "flip")
	_card_tile.label.font_size = 64
	_card_tile.label.width = 6.6 / _card_tile.label.pixel_size
	_feedback = _label3d("Think of the answer, then click the card to flip it.", 36, Color("9a9aa4"), 9.0)
	_feedback.position = Vector3(0, -1.2, 0)
	_quiz_root.add_child(_feedback)


func _flip_card() -> void:
	if _card_back or _card_tile.is_empty():
		return
	_card_back = true
	_card_tile.enabled = false
	var root: Node3D = _card_tile.root
	var tw := root.create_tween()
	tw.tween_property(root, "rotation:x", PI / 2.0, 0.14).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void:
		_card_tile.label.text = _cards[_ci].back
		_card_tile.label.modulate = Color("ffe6a8")
		_tint_tile(_card_tile, _color("color", Color("d97757")), 0.9))
	tw.tween_property(root, "rotation:x", 0.0, 0.16).set_ease(Tween.EASE_OUT)
	if _feedback != null:
		_feedback.text = "Did you know it?"
	_make_tile("✗   Not yet", Vector3(-2.1, -2.0, 0), Vector3(3.4, 0.62, 0.14), QUIZ_RED, "miss")
	_make_tile("✓   I knew it", Vector3(2.1, -2.0, 0), Vector3(3.4, 0.62, 0.14), QUIZ_GREEN, "got")


func _grade_card(knew: bool) -> void:
	if knew:
		_score += 1
	_ci += 1
	if _ci < _cards.size():
		_show_card()
	else:
		_show_card_results()


func _show_card_results() -> void:
	_clear_quiz()
	var total: int = _cards.size()
	var good: bool = ProgressStore.passes(_score, total)
	var head := _label3d("DECK DONE", 30, QUIZ_GREEN if good else Color("8a8a96"), 0.0, true)
	head.position = Vector3(0, 2.4, 0)
	_quiz_root.add_child(head)
	var big := _label3d("%d / %d" % [_score, total], 190, QUIZ_GREEN if good else _color("color", Color("d97757")), 0.0, true)
	big.position = Vector3(0, 1.3, 0)
	_quiz_root.add_child(big)
	var sub := _label3d("cards you knew" + ("  —  nice!" if _score == total else ""), 44, Color("d8d8e0"), 9.0)
	sub.position = Vector3(0, 0.1, 0)
	_quiz_root.add_child(sub)
	_make_tile("Go again", Vector3(0, -1.6, 0), Vector3(2.8, 0.62, 0.14), QUIZ_TILE, "retry")
	_report_score("cards", int(params.get("_cards_index", 0)), _score, total)
	if _score == total:
		_confetti(Vector3(0, 1.3, 0.4), 120)


# ── Objects: primitives and imported models ─────────────────────────────────
#
#     ```3d
#     cube: red
#     sphere: blue, at 2 0 0, size 1.5
#     cone: #ff8800, spin
#     model: rocket.glb, size 2, label My rocket
#     ```
#
# One object per line: the shape (or "model") before the colon, then comma-
# separated parts — a colour (name or #hex), "at x y z", "size n", "spin",
# "label text". Objects without "at" line up left to right.


## Turn "red" / "#ff8800" / "Red" into a colour; ok=false when it isn't one.
static func color_from(text: String) -> Dictionary:
	var t: String = text.strip_edges().to_lower()
	if COLORS.has(t):
		return {"ok": true, "color": COLORS[t]}
	if t.begins_with("#") and Color.html_is_valid(t):
		return {"ok": true, "color": Color.html(t)}
	return {"ok": false, "color": Color("d8d8dc")}


static func parse_object(kind: String, value: String) -> Dictionary:
	var k: String = kind.strip_edges().to_lower()
	var o: Dictionary = {"kind": SHAPES.get(k, "model"), "color": Color("d8d8dc"), "has_color": false,
		"at": null, "size": 1.0, "spin": 0.0, "label": "", "file": ""}
	if o.kind == "model":
		o.size = 2.0   # models are usually tall/irregular; give them room
	var parts: PackedStringArray = value.split(",")
	for i in range(parts.size()):
		var part: String = parts[i].strip_edges()
		var words: PackedStringArray = part.split(" ", false)
		if words.is_empty():
			continue
		var w0: String = words[0].to_lower()
		if i == 0 and o.kind == "model":
			o.file = part
		elif w0 == "at" and words.size() >= 3:
			o.at = Vector3(float(words[1]), float(words[2]) if words.size() > 3 else 0.0, float(words[3]) if words.size() > 3 else float(words[2]))
		elif w0 == "size" and words.size() >= 2:
			o.size = clampf(float(words[1]), 0.1, 20.0)
		elif w0 == "spin":
			o.spin = float(words[1]) if words.size() > 1 else 1.0
		elif w0 == "label":
			o.label = part.substr(5).strip_edges()
		else:
			var c: Dictionary = color_from(part)
			if c.ok:
				o.color = c.color
				o.has_color = true
	var colour_name: String = ""
	for n in COLORS:
		if COLORS[n] == o.color and o.has_color:
			colour_name = n
			break
	o["name"] = o.label if o.label != "" else ((colour_name + " " if colour_name != "" else "") + (o.file.get_file().get_basename() if o.kind == "model" else o.kind))
	return o


static func parse_objects(lines: PackedStringArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw in lines:
		var line: String = str(raw).strip_edges()
		var i: int = line.find(":")
		if i <= 0:
			continue
		var key: String = line.substr(0, i).strip_edges().to_lower()
		if SHAPES.has(key) or key == "model":
			out.append(parse_object(key, line.substr(i + 1)))
	return out


## "red cube", "cube red", "blue sphere" or "model rocket.glb" -> an object;
## anything else (plain text answers like "Red" or "Cube") -> {}.
static func answer_object(text: String) -> Dictionary:
	var t: String = text.strip_edges()
	if t.to_lower().begins_with("model "):
		return parse_object("model", t.substr(6))
	var words: PackedStringArray = t.to_lower().split(" ", false)
	if words.size() != 2:
		return {}
	for pair in [[words[0], words[1]], [words[1], words[0]]]:
		if SHAPES.has(pair[1]) and color_from(pair[0]).ok:
			return parse_object(pair[1], pair[0])
	return {}


static func _primitive_mesh(kind: String) -> Mesh:
	match kind:
		"sphere":
			var m := SphereMesh.new()
			m.radius = 0.5
			m.height = 1.0
			m.radial_segments = 48
			m.rings = 24
			return m
		"cylinder", "cone", "pyramid":
			var m := CylinderMesh.new()
			m.height = 1.0
			m.top_radius = 0.0 if kind != "cylinder" else 0.5
			m.bottom_radius = 0.5 if kind != "pyramid" else 0.7071
			m.radial_segments = 4 if kind == "pyramid" else 48
			return m
		"torus":
			var m := TorusMesh.new()
			m.inner_radius = 0.28
			m.outer_radius = 0.5
			m.rings = 48
			m.ring_segments = 24
			return m
		"capsule":
			var m := CapsuleMesh.new()
			m.radius = 0.3
			m.height = 1.0
			return m
		"prism":
			var m := PrismMesh.new()
			m.size = Vector3(1, 1, 0.6)
			return m
	var b := BoxMesh.new()
	b.size = Vector3.ONE * 0.85
	return b


static func _shape_material(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.38
	m.metallic = 0.05
	m.clearcoat_enabled = true
	m.clearcoat = 0.6
	m.clearcoat_roughness = 0.25
	m.rim_enabled = true
	m.rim = 0.25
	return m


## Path of a model: bare names live in the vault's models/ folder.
static func model_path(file: String) -> String:
	var f: String = file.strip_edges()
	if f.begins_with("~/"):
		return OS.get_environment("HOME").path_join(f.substr(2))
	if f.is_absolute_path():
		return f
	return VaultStore.vault_path.path_join("models").path_join(f)


static func load_model(file: String) -> Node3D:
	var path: String = model_path(file)
	if not FileAccess.file_exists(path):
		return null
	var ext: String = path.get_extension().to_lower()
	var doc: Object = null
	if ext == "fbx" and ClassDB.class_exists("FBXDocument"):
		doc = ClassDB.instantiate("FBXDocument")
	elif ext in ["glb", "gltf"]:
		doc = GLTFDocument.new()
	if doc == null:
		return null
	var state: Object = ClassDB.instantiate("FBXState") if ext == "fbx" else GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		return null
	return doc.generate_scene(state) as Node3D


static func _subtree_aabb(node: Node, xform: Transform3D, acc: Array) -> void:
	var t: Transform3D = xform
	if node is Node3D:
		t = xform * (node as Node3D).transform
	if node is VisualInstance3D:
		var box: AABB = t * (node as VisualInstance3D).get_aabb()
		acc[0] = box if acc[0] == null else (acc[0] as AABB).merge(box)
	for c in node.get_children():
		_subtree_aabb(c, t, acc)


## Build one object, scaled to fit a cube of `fit` units, centred on origin.
func _make_object(o: Dictionary, fit: float) -> Node3D:
	var holder := Node3D.new()
	var spinner := Node3D.new()
	holder.add_child(spinner)
	holder.set_meta("spinner", spinner)
	if o.kind == "model":
		var model: Node3D = load_model(o.file)
		if model == null:
			var box := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3.ONE * fit * 0.8
			box.mesh = bm
			var wire := StandardMaterial3D.new()
			wire.albedo_color = Color(1, 0.4, 0.4, 0.25)
			wire.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			box.material_override = wire
			spinner.add_child(box)
			var msg := _label3d("Model not found:\n" + o.file, 32, Color("ff9a90"), fit * 1.6)
			msg.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			msg.no_depth_test = true
			holder.add_child(msg)
			return holder
		var acc: Array = [null]
		_subtree_aabb(model, Transform3D(), acc)
		var box_aabb: AABB = acc[0] if acc[0] != null else AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
		var k: float = fit / maxf(box_aabb.get_longest_axis_size(), 0.001)
		model.scale = Vector3.ONE * k
		model.position = -box_aabb.get_center() * k
		if o.has_color:
			for mi in model.find_children("*", "MeshInstance3D", true, false):
				(mi as MeshInstance3D).material_override = _shape_material(o.color)
		spinner.add_child(model)
		# Play the model's first animation, looping, if it has one
		for ap in model.find_children("*", "AnimationPlayer", true, false):
			var player := ap as AnimationPlayer
			var names: PackedStringArray = player.get_animation_list()
			if not names.is_empty():
				player.get_animation(names[0]).loop_mode = Animation.LOOP_LINEAR
				player.ready.connect(func() -> void: player.play(names[0]), CONNECT_ONE_SHOT)
			break
		return holder
	var mi := MeshInstance3D.new()
	mi.mesh = _primitive_mesh(o.kind)
	mi.material_override = _shape_material(o.color)
	mi.scale = Vector3.ONE * fit
	if o.kind == "torus":
		mi.rotation.x = PI / 2.0   # stand the ring up so it reads as a ring
	spinner.add_child(mi)
	return holder


func _build_shapes() -> void:
	# Studio backdrop: dark gradient sky, floor fog fades into its horizon
	var horizon := Color("23252f")
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("0d0e13")
	sky_mat.sky_horizon_color = horizon
	sky_mat.ground_horizon_color = horizon
	sky_mat.ground_bottom_color = horizon
	sky_mat.sky_curve = 0.25
	_env.sky.sky_material = sky_mat
	_env.background_mode = Environment.BG_SKY
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color("b8bfd8")
	_env.ambient_light_energy = 0.45
	_env.fog_enabled = true
	_env.fog_light_color = horizon
	_env.fog_density = 0.045
	_env.fog_sky_affect = 0.0
	# Soft studio floor with a fading grid
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(60, 60)
	var floor_mat := ShaderMaterial.new()
	floor_mat.shader = _shader(SHADER_FLOOR)
	var floor_mi := MeshInstance3D.new()
	floor_mi.mesh = floor_mesh
	floor_mi.material_override = floor_mat
	_content.add_child(floor_mi)
	var fill := OmniLight3D.new()
	fill.position = Vector3(-4, 3.5, 4)
	fill.light_energy = 1.2
	fill.omni_range = 14.0
	fill.light_color = Color("c9d4ff")
	_viewport.add_child(fill)
	if _objects_spec.is_empty():
		var tip := _label3d("Add shapes, one per line:  cube: red", 40, Color("9a9aa4"), 0.0)
		tip.position = Vector3(0, 0.8, 0)
		_content.add_child(tip)
	_place_objects(true)


func _place_objects(on_ground: bool) -> void:
	var auto: Array[Dictionary] = _objects_spec.filter(func(o: Dictionary) -> bool: return o.at == null)
	var gap: float = 1.6
	var x0: float = -(auto.size() - 1) * gap / 2.0
	var auto_i: int = 0
	var lo := Vector3(INF, 0, INF)
	var hi := Vector3(-INF, 0, -INF)
	for o in _objects_spec:
		var size: float = o.size
		var node: Node3D = _make_object(o, size)
		var pos: Vector3
		if o.at == null:
			pos = Vector3(x0 + auto_i * gap, 0, 0)
			auto_i += 1
		else:
			pos = o.at
		if on_ground:
			pos.y += size / 2.0
		node.position = pos
		_content.add_child(node)
		lo = Vector3(minf(lo.x, pos.x - size), 0, minf(lo.z, pos.z - size))
		hi = Vector3(maxf(hi.x, pos.x + size), maxf(hi.y, pos.y + size), maxf(hi.z, pos.z + size))
		var label := _label3d(o.name, 30, Color("e6e6ee"), 0.0, true)
		label.fixed_size = true   # same on-screen size however far the camera is
		label.pixel_size = 0.0011
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.outline_size = 12
		label.outline_modulate = Color(0, 0, 0, 0.75)
		label.position = pos + Vector3(0, size * 0.5 + 0.35, 0)
		label.visible = str(params.get("labels", "")).to_lower() in ["on", "true", "yes", "1"]
		_content.add_child(label)
		var spinner: Node3D = node.get_meta("spinner")
		var rate: float = o.spin
		if rate != 0.0:
			_updaters.append(func(d: float) -> void: spinner.rotate_y(d * 0.9 * rate * _speed()))
		_objects.append({"root": node, "half": Vector3.ONE * size * 0.55, "label": label, "always": label.visible, "base_y": pos.y})
	if on_ground and not _objects_spec.is_empty():
		var center: Vector3 = (lo + hi) / 2.0
		_target = Vector3(center.x, hi.y * 0.4, center.z)
		_fit_radius = Vector2(hi.x - lo.x, hi.z - lo.z).length() / 2.0
		_fit_height = hi.y
		_pitch = -0.38
		_yaw = 0.3
		_updaters.append(_fit_shapes)


## Pull the camera in until the shapes fill the card, for its aspect ratio.
## Stops once the user zooms by hand.
func _fit_shapes(d: float) -> void:
	var sz: Vector2 = _container.size
	if _user_zoomed or sz.x < 2.0 or sz.y < 2.0:
		return
	var t: float = tan(deg_to_rad(_camera.fov) / 2.0)
	var need_w: float = _fit_radius / (t * sz.x / sz.y)
	var need_h: float = (_fit_height * 0.75 + 0.3) / t
	var need: float = maxf(maxf(need_w, need_h) + _fit_radius * 0.55, 2.6)
	_distance = need if _time < 0.05 else lerpf(_distance, need, minf(d * 6.0, 1.0))
	_update_camera()


func _pick_object(screen: Vector2) -> int:
	var origin: Vector3 = _camera.project_ray_origin(screen)
	var dir: Vector3 = _camera.project_ray_normal(screen)
	var best: int = -1
	var best_t: float = INF
	for i in range(_objects.size()):
		var inv: Transform3D = (_objects[i].root as Node3D).global_transform.affine_inverse()
		var hit: float = _ray_box(inv * origin, inv.basis * dir, _objects[i].half)
		if hit >= 0.0 and hit < best_t:
			best = i
			best_t = hit
	return best


func _set_hover_obj(i: int) -> void:
	if i == _hover_obj:
		return
	if _hover_obj >= 0:
		var old: Dictionary = _objects[_hover_obj]
		old.label.visible = old.always
		old.root.create_tween().tween_property(old.root, "position:y", old.base_y, 0.15)
	_hover_obj = i
	if i >= 0:
		var o: Dictionary = _objects[i]
		o.label.visible = true
		o.root.create_tween().tween_property(o.root, "position:y", o.base_y + 0.15, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_container.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if i >= 0 else Control.CURSOR_DRAG
