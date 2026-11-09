extends SceneTree
## Idle CPU: the app runs in low-processor mode, so an idle window stops
## redrawing; animated 3D cards keep it drawing only while the app is in
## front. Timers (autosave) still run.
##   headless:      godot --headless --path . -s res://tests/idle_test.gd
##   with frames:   xvfb-run -a godot --path . --rendering-driver opengl3 \
##                    --rendering-method gl_compatibility -s res://tests/idle_test.gd
## Headless draws nothing, so the frame counts are measured only with a display.

const TestVault = preload("res://tests/test_vault.gd")
const UiScale = preload("res://ui_scale.gd")
const WINDOW_SECONDS: float = 4.0

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func wait(seconds: float) -> void:
	await create_timer(seconds).timeout


## Frames the window actually drew over WINDOW_SECONDS.
func frames_drawn() -> int:
	var start: int = Engine.get_frames_drawn()
	await wait(WINDOW_SECONDS)
	return Engine.get_frames_drawn() - start


func make_note(title: String, text: String) -> void:
	var n: ContentLayer = VaultStore.create_note(title)
	n.raw_text = text
	VaultStore.save_note(n)


func _init() -> void:
	UiScale.file_override = "user://test_display_idle.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UiScale.file_override))
	UiScale._loaded = false
	JourneyStore.file_override = "user://test_journey_idle.json"
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_idle.json"
	ProgressStore.reset()
	TestVault.open("idle", false)
	make_note("Plain", "# Plain\n\nJust words. No scenes, nothing that moves.\n\n- one\n- two\n")
	make_note("Spinning", "# Spinning\n\n```3d\ncube: red\nsphere: blue\ncone: yellow\ncaption: Spinning shapes\nheight: 180\n```\n")
	VaultStore.refresh_note_list()
	await frames(2)

	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(3)
	check(OS.low_processor_usage_mode, "low-processor mode is on after boot")
	check(bool(ProjectSettings.get_setting("application/run/low_processor_mode")), "project.godot sets application/run/low_processor_mode")

	# Timers still fire in low-processor mode: the autosave lands on disk
	app.open_note_by_title("Plain")
	app._switch_layer("raw")
	await frames(2)
	app.raw_text_layer.text += "\nSaved by the timer."
	app.raw_text_layer.text_changed.emit()
	await wait(app._auto_save_timer.wait_time + 0.6)
	var on_disk: String = FileAccess.get_file_as_string(app.current_note.resource_path)
	check(on_disk.contains("Saved by the timer."), "the autosave timer still saves in low-processor mode")

	if DisplayServer.get_name() == "headless":
		print("SKIP  frame counts need a display (run under xvfb-run, see the header)")
	else:
		# A plain note in Read view: nothing changes, so nothing is drawn
		app.open_note_by_title("Plain")
		app._switch_layer("visual")
		get_root().gui_release_focus()
		await wait(1.0)
		var idle: int = await frames_drawn()
		check(idle < 30, "an idle plain note in Read view draws < 30 frames in %ds (%d)" % [WINDOW_SECONDS, idle])

		# The editor's blinking caret still redraws, and only for the blinks
		app._switch_layer("raw")
		app.raw_text_layer.grab_focus()
		await wait(1.0)
		var blinking: int = await frames_drawn()
		check(blinking > 2 and blinking < 30, "Edit view: the caret blink redraws a few frames, < 30 in %ds (%d)" % [WINDOW_SECONDS, blinking])
		get_root().gui_release_focus()

		# A visible animated 3D card keeps drawing… Software GL (llvmpipe under
		# Xvfb, on a busy machine) renders a full-width card at ~25 fps, so the
		# card is short, in the minimum-size window, without MSAA and glow:
		# the count measures pausing, not the renderer's speed.
		get_root().size = UiScale.BASE_MIN_SIZE
		app.open_note_by_title("Spinning")
		app._switch_layer("visual")
		await frames(2)
		var card: NoteScene3D = null
		for c in app.visual_layer.get_children():
			if c is NoteScene3D:
				card = c
		check(card != null, "the note shows its 3D card")
		if card == null:
			quit(1)
			return
		card._viewport.msaa_3d = Viewport.MSAA_DISABLED
		card._env.glow_enabled = false
		await wait(1.0)
		check(card._viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "the card is on screen and rendering")
		var animated: int = await frames_drawn()
		check(animated > 100, "a visible animated card keeps drawing: > 100 frames in %ds (%d)" % [WINDOW_SECONDS, animated])

		# …until the app goes to the background
		get_root().propagate_notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
		await wait(0.5)
		check(card._viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "focus out: the card stops rendering")
		var background: int = await frames_drawn()
		check(background < 30, "focus out: < 30 frames in %ds (%d)" % [WINDOW_SECONDS, background])

		# Back in front, it animates again
		get_root().propagate_notification(NOTIFICATION_APPLICATION_FOCUS_IN)
		await wait(0.5)
		var back: int = await frames_drawn()
		check(back > 100, "focus in: the card animates again (%d frames)" % back)

	app.queue_free()
	await frames(2)
	for p in [UiScale.file_override, JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	UiScale.file_override = ""
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
