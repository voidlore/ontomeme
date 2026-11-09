extends RefCounted
## Interface scale: the screen's own scale (2× on a Retina Mac, 1.25×/1.5× on
## a Windows laptop) times the user's zoom (Ctrl+= / Ctrl+- / Ctrl+0). Without
## it the app draws at 1× and looks tiny on high-resolution screens.
## The zoom is remembered per computer in user://display.json, beside the
## theme: "dark", "light" or "system" (follow the OS).

const ZOOM_STEPS: Array[float] = [0.75, 0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]
const BASE_MIN_SIZE := Vector2i(820, 520)
const BASE_SIZE := Vector2i(1280, 720)
const THEMES: Array[String] = ["dark", "light", "system"]

## Tests point this at a throwaway file so they never touch the real setting.
static var file_override: String = ""

static var zoom: float = 1.0
static var theme: String = "dark"
static var _loaded: bool = false


static func _file() -> String:
	return file_override if file_override != "" else "user://display.json"


## The screen's scale, rounded to a quarter: macOS and Wayland report it
## directly, Windows and X11 only as DPI (96 = 1×).
static func screen_scale(screen: int = -1) -> float:
	if screen < 0:
		screen = DisplayServer.window_get_current_screen()
	var s: float = DisplayServer.screen_get_scale(screen)
	if is_equal_approx(s, 1.0) and OS.get_name() in ["Windows", "Linux", "FreeBSD"]:
		var dpi: int = DisplayServer.screen_get_dpi(screen)
		if dpi > 0:
			s = dpi / 96.0
	return clampf(snappedf(s, 0.25), 1.0, 4.0)


## display.json as a Dictionary ({} when missing or unreadable).
static func _read() -> Dictionary:
	if not FileAccess.file_exists(_file()):
		return {}
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(_file()))
	return v if v is Dictionary else {}


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var v: Dictionary = _read()
	zoom = 1.0
	if v.get("zoom") is float or v.get("zoom") is int:
		zoom = clampf(float(v.zoom), ZOOM_STEPS[0], ZOOM_STEPS[-1])
	theme = str(v.get("theme", "dark"))
	if theme not in THEMES:
		theme = "dark"


## Write both settings, keeping any other keys already in the file.
static func _save() -> void:
	var v: Dictionary = _read()
	v["zoom"] = zoom
	v["theme"] = theme
	var f := FileAccess.open(_file(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(v))


static func load_zoom() -> float:
	_load()
	return zoom


static func set_zoom(z: float) -> void:
	_load()
	zoom = clampf(z, ZOOM_STEPS[0], ZOOM_STEPS[-1])
	_save()


## The saved theme choice: "dark" (the default), "light" or "system".
static func load_theme() -> String:
	_load()
	return theme


static func set_theme(choice: String) -> void:
	_load()
	theme = choice if choice in THEMES else "dark"
	_save()


## Whether a theme choice means a dark window. "system" asks the OS, and is
## dark where the OS can't say (headless, or no dark-mode support).
static func is_dark(choice: String) -> bool:
	if choice == "system":
		return DisplayServer.is_dark_mode() if DisplayServer.is_dark_mode_supported() else true
	return choice != "light"


## The next zoom step up (dir = 1) or down (dir = -1) from the current one.
static func step_zoom(dir: int) -> float:
	var cur: float = load_zoom()
	if dir > 0:
		for z in ZOOM_STEPS:
			if z > cur + 0.001:
				return z
		return ZOOM_STEPS[-1]
	for i in range(ZOOM_STEPS.size() - 1, -1, -1):
		if ZOOM_STEPS[i] < cur - 0.001:
			return ZOOM_STEPS[i]
	return ZOOM_STEPS[0]


static func factor() -> float:
	return screen_scale() * load_zoom()


## Scale `window`'s content. With `fit_window`, also size the window for the
## screen's scale (first launch draws a 1280×720 window at 1× otherwise).
static func apply(window: Window, fit_window: bool = false) -> void:
	var f: float = factor()
	window.content_scale_factor = f
	var s: float = screen_scale()
	var usable_size := Vector2(DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()).size)
	# The layout needs BASE_MIN_SIZE logical pixels; never ask for more than the screen
	window.min_size = Vector2i((Vector2(BASE_MIN_SIZE) * f).min(usable_size * 0.95))
	if fit_window and window.mode == Window.MODE_WINDOWED and not is_equal_approx(s, 1.0):
		var usable: Rect2i = DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
		var size := Vector2i((Vector2(BASE_SIZE) * s).min(Vector2(usable.size) * 0.9))
		window.size = size
		window.position = usable.position + (usable.size - size) / 2
