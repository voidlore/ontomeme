extends SceneTree
## Theme: the sun/moon button is a drawn icon (no font glyph), the choice
## (dark, light or follow the system) is remembered in display.json beside the
## zoom, every sidebar / top-bar button's text is drawable by the UI font, and
## an icon button focused from the keyboard keeps its icon visible.
##   headless:  godot --headless --path . -s res://tests/theme_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const UiScale = preload("res://ui_scale.gd")

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func saved() -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(UiScale.file_override))
	return v if v is Dictionary else {}


## A fresh window, as on the next launch: forget what UiScale cached, so the
## theme is read back from the file.
func launch() -> Control:
	UiScale._loaded = false
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(3)
	return app


func close(app: Control) -> void:
	app.queue_free()
	await frames(2)


## Characters in sidebar / top-bar button labels the UI font has no glyph for.
func missing_glyphs(app: Control) -> Array[String]:
	var font: Font = app.theme.default_font
	var missing: Array[String] = []
	for root in [app.get_node("%Sidebar"), app.get_node("%TopBar")]:
		for b in root.find_children("*", "Button", true, false):
			var text: String = (b as Button).text
			for i in range(text.length()):
				if not font.has_char(text.unicode_at(i)):
					missing.append("%s: '%s' (U+%04X)" % [b.name, text[i], text.unicode_at(i)])
	return missing


func check_buttons(app: Control, what: String) -> void:
	var btn: Button = app.get_node("%ThemeButton")
	check(btn.text == "" and btn.icon != null, "%s: ThemeButton is an icon with no text ('%s')" % [what, btn.text])
	var pal: Button = app.get_node("%PaletteButton")
	check(pal.text == "" and pal.icon != null, "%s: PaletteButton is an icon with no text ('%s')" % [what, pal.text])
	var missing: Array[String] = missing_glyphs(app)
	check(missing.is_empty(), "%s: the font draws every sidebar / top-bar button label %s" % [what, missing])
	# Tab focus draws the icon in icon_focus_color. Left unset it is Godot's
	# white, and the sun / command icon vanishes on the light sidebar.
	var bg: Color = app._palette_colors.sidebar
	for b in [btn, pal]:
		var focus: Color = (b as Button).get_theme_color("icon_focus_color")
		check(focus == (b as Button).get_theme_color("icon_normal_color"),
			"%s: a keyboard-focused %s draws its icon as when unfocused (%s)" % [what, b.name, focus])
		check(absf(focus.get_luminance() - bg.get_luminance()) > 0.3,
			"%s: a keyboard-focused %s icon stands out from the sidebar (icon %.2f, sidebar %.2f)" % [what, b.name, focus.get_luminance(), bg.get_luminance()])


## Every button type in the theme that colours its icon sets the icon colour
## for each state itself, so none falls back to Godot's default white.
func check_icon_states(dark: bool) -> void:
	var t: Theme = AppTheme.build(dark)
	var bad: Array[String] = []
	for type in t.get_type_list():
		if not t.has_color("icon_normal_color", type):
			continue
		for state in ["icon_focus_color", "icon_hover_pressed_color", "icon_disabled_color"]:
			if not t.has_color(state, type):
				bad.append("%s.%s" % [type, state])
		if t.has_color("icon_focus_color", type) and t.get_color("icon_focus_color", type) != t.get_color("font_focus_color", type):
			bad.append("%s.icon_focus_color != font_focus_color" % type)
	check(bad.is_empty(), "%s theme: every button type sets its icon focus / hover-pressed / disabled colours %s" % ["dark" if dark else "light", bad])


func _init() -> void:
	UiScale.file_override = "user://test_display_theme.json"   # never touch the real setting
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UiScale.file_override))
	UiScale._loaded = false
	JourneyStore.file_override = "user://test_journey_theme.json"
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_theme.json"
	ProgressStore.reset()
	TestVault.open("theme")
	await frames(2)

	# ── Icons ──
	for icon in ["moon", "sun", "command"]:
		var tex: Texture2D = Icons.get_icon(icon)
		var img: Image = tex.get_image() if tex != null else null
		var used: bool = false
		if img != null:
			for y in range(img.get_height()):
				for x in range(img.get_width()):
					used = used or img.get_pixel(x, y).a > 0.5
		check(used, "Icons draws '%s'" % icon)
	check(Icons.get_icon("moon").get_image().get_data() != Icons.get_icon("sun").get_image().get_data(), "moon and sun differ")
	check_icon_states(true)
	check_icon_states(false)

	# ── First launch: dark, nothing saved yet ──
	UiScale.set_zoom(1.15)   # the theme must not clobber the zoom (same file)
	var app: Control = await launch()
	check(app._is_dark_mode and app._theme_pref == "dark", "with nothing saved the app starts dark")
	check_buttons(app, "dark")
	var moon: Texture2D = app.get_node("%ThemeButton").icon

	# ── Toggle → light, remembered ──
	app._toggle_theme()
	await frames(2)
	check(saved().get("theme") == "light", "_toggle_theme() saves theme 'light' (%s)" % saved())
	check(is_equal_approx(float(saved().get("zoom", 0.0)), 1.15), "the zoom survives a theme change (%s)" % saved())
	check(not app._is_dark_mode, "the window turned light")
	check(app.get_node("%ThemeButton").icon != moon, "the button shows the sun in the light theme")
	check_buttons(app, "light")
	await close(app)

	UiScale._loaded = false   # the next launch reads the file again
	var fresh: Control = load("res://note.tscn").instantiate()
	check(fresh._is_dark_mode == false, "a freshly instanced note.tscn starts light, before its first frame")
	get_root().add_child(fresh)
	await frames(2)
	check(fresh._is_dark_mode == false and fresh._palette_colors == AppTheme.palette(false), "…and applies the light palette on start")
	UiScale.set_zoom(1.0)
	check(saved().get("theme") == "light", "changing the zoom keeps the saved theme (%s)" % saved())

	# ── Toggle cycles light → dark ──
	fresh._toggle_theme()
	check(fresh._is_dark_mode and saved().get("theme") == "dark", "toggling again goes back to dark (%s)" % saved())

	# ── Follow the system ──
	fresh._build_palette_items("system")
	var offered: bool = false
	for item in fresh._palette_items:
		offered = offered or str(item.action) == "theme_system"
	check(offered, "the palette offers 'Follow system theme'")
	fresh._execute_command("theme_system")
	await frames(2)
	check(saved().get("theme") == "system" and fresh._theme_pref == "system", "Follow system theme saves 'system' (%s)" % saved())
	var os_dark: bool = DisplayServer.is_dark_mode() if DisplayServer.is_dark_mode_supported() else true
	check(fresh._is_dark_mode == os_dark, "'system' follows the OS (dark when it can't tell, e.g. headless): %s" % fresh._is_dark_mode)
	check(UiScale.is_dark("system") == os_dark and UiScale.is_dark("dark") and not UiScale.is_dark("light"), "UiScale.is_dark resolves each choice")
	fresh._toggle_theme()
	check(fresh._is_dark_mode != os_dark and saved().get("theme") == ("light" if os_dark else "dark"), "toggling from 'system' switches to the other look (%s)" % saved())
	await close(fresh)

	# ── A bad value falls back to dark ──
	var f := FileAccess.open(UiScale.file_override, FileAccess.WRITE)
	f.store_string(JSON.stringify({"zoom": 1.0, "theme": "purple"}))
	f = null
	UiScale._loaded = false
	check(UiScale.load_theme() == "dark", "an unknown saved theme reads as dark")

	for p in [UiScale.file_override, JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	UiScale.file_override = ""
	UiScale._loaded = false
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
