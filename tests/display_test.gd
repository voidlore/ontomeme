extends SceneTree
## Display: the UI scales by screen scale × zoom, zoom steps and persists, and
## shortcuts answer to Cmd (Mac) as well as Ctrl.
##   headless:  godot --headless --path . -s res://tests/display_test.gd

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


func key(code: Key, meta: bool) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.pressed = pressed
		e.meta_pressed = meta
		e.ctrl_pressed = not meta
		get_root().push_input(e)
	await frames(2)


func _init() -> void:
	UiScale.file_override = "user://test_display.json"   # never touch the real zoom
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UiScale.file_override))
	UiScale._loaded = false
	JourneyStore.file_override = "user://test_journey_display.json"
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_display.json"
	ProgressStore.reset()
	TestVault.open("display")
	await frames(2)

	# ── Scale and zoom ──
	check(UiScale.load_zoom() == 1.0, "zoom starts at 100%")
	check(UiScale.screen_scale() >= 1.0 and fmod(UiScale.screen_scale() * 4.0, 1.0) == 0.0, "screen scale is a quarter step ≥ 1 (%s)" % UiScale.screen_scale())
	check(UiScale.step_zoom(1) == 1.15 and UiScale.step_zoom(-1) == 0.85, "zoom steps 85% / 115% around 100%")
	UiScale.set_zoom(1.5)
	UiScale._loaded = false
	check(UiScale.load_zoom() == 1.5, "zoom is remembered")
	UiScale.set_zoom(9.0)
	check(UiScale.zoom == UiScale.ZOOM_STEPS[-1], "zoom is clamped (%s)" % UiScale.zoom)
	UiScale.set_zoom(1.0)

	var w := Window.new()
	get_root().add_child(w)
	UiScale.set_zoom(1.3)
	UiScale.apply(w)
	check(is_equal_approx(w.content_scale_factor, UiScale.screen_scale() * 1.3), "apply(): content scale = screen scale × zoom (%s)" % w.content_scale_factor)
	w.queue_free()
	UiScale.set_zoom(1.0)

	# ── App: zoom commands and Cmd shortcuts ──
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	await key(KEY_EQUAL, true)
	check(is_equal_approx(UiScale.zoom, 1.15) and app.status_label.text == "Zoom 115%", "Cmd+= zooms in (%s)" % app.status_label.text)
	await key(KEY_MINUS, false)
	await key(KEY_MINUS, false)
	check(is_equal_approx(UiScale.zoom, 0.85), "Ctrl+- zooms out (%s)" % UiScale.zoom)
	await key(KEY_0, true)
	check(UiScale.zoom == 1.0, "Cmd+0 resets to 100%")
	await key(KEY_P, true)
	check(app._palette_visible, "Cmd+P opens the palette")
	await key(KEY_P, true)
	check(not app._palette_visible, "Cmd+P closes it again")
	var n_before: int = VaultStore.note_list.size()
	await key(KEY_N, true)
	check(VaultStore.note_list.size() == n_before + 1, "Cmd+N makes a new note")
	app.queue_free()
	await frames(2)

	for f in [UiScale.file_override, JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	UiScale.file_override = ""
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
