extends SceneTree
## A brand-new user, end to end: the first launch seeds the default vault and
## opens Start Here: Tutorials; the user opens Tutorial 1 from the sidebar and
## from Start Here's own link, answers its quiz, sees the pass and the ✓, and
## a relaunch keeps the ✓ without seeding anything again.
## Every click is real input: mouse motion, then press and release through
## the viewport. Before each one the test checks that the control under the
## mouse is the one it means to click, so a click that would miss fails the
## test instead of passing it.
##   headless:  godot --headless --path . -s res://tests/first_user_e2e_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const Tutorials = preload("res://tutorials_content.gd")

var fails: int = 0
var app: Control


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func _init() -> void:
	TestVault.hold()   # before any await, or the autoload opens the real vault
	JourneyStore.file_override = "user://test_journey_first_user.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_first_user.json"   # never touch real progress
	ProgressStore.reset()
	DisplayServer.window_set_size(Vector2i(1280, 860))
	# Stands in for ~/Documents/Ontomeme, which a test must never create
	var fake_default: String = ProjectSettings.globalize_path("user://test-vault-first-user/")
	TestVault.remove_tree(fake_default)

	# 1. First launch: the default vault is created and seeded, and the app
	#    opens on Start Here in the Read view
	VaultStore.open_startup_vault(fake_default, fake_default, false)
	check(VaultStore.first_run, "the first launch is a first run")
	await launch()
	check(open_title() == Tutorials.START and app.current_mode == "visual",
			"the app opens %s in Read view (%s, %s)" % [Tutorials.START, open_title(), app.current_mode])

	# 2. Tutorial 1 from its sidebar row, then from Start Here's link (the
	#    way the page itself sends a new user)
	await click_row(row(Tutorials.T1), "Tutorial 1's sidebar row")
	check(open_title() == Tutorials.T1 and app.current_mode == "visual", "the sidebar row opens Tutorial 1 in Read view (%s)" % open_title())
	await click_row(row(Tutorials.START), "Start Here's sidebar row")
	check(open_title() == Tutorials.START, "the sidebar row opens Start Here again (%s)" % open_title())
	var link: Array = await find_link(Tutorials.T1)
	check(not link.is_empty(), "Start Here shows a link to Tutorial 1 (the mouse turns into a pointing hand over it)")
	if not link.is_empty():
		await click_at(link[0], link[1], "Start Here's link to Tutorial 1")
	check(open_title() == Tutorials.T1 and app.current_mode == "visual", "the link opens Tutorial 1 in Read view (%s)" % open_title())

	# 3. Scroll the quiz into view
	var quizzes: Array = app.visual_layer.find_children("*", "NoteScene3D", true, false).filter(func(c: NoteScene3D) -> bool: return c.preset == "quiz")
	check(open_title() == Tutorials.T1 and quizzes.size() == 1, "Tutorial 1 ends with one quiz (%d)" % quizzes.size())
	if open_title() == Tutorials.T1 and quizzes.size() == 1:
		var quiz: NoteScene3D = quizzes[0]
		app.doc_scroll.ensure_control_visible(quiz)
		await frames(3)
		check(app.doc_scroll.get_global_rect().intersects(quiz.get_global_rect()), "the quiz card is scrolled into view")

		# 4. Answer every question right, then see the results
		var total: int = quiz._quiz.size()
		for qi in range(total):
			await click_tile(quiz, tile(quiz, "answer:%d" % quiz._quiz[qi].correct), "the right answer to question %d" % (qi + 1))
			await click_tile(quiz, tile(quiz, "results" if qi == total - 1 else "next"), "results" if qi == total - 1 else "Next question")

		# 5. A pass on screen, in the progress file and in the sidebar
		var head: Array = quiz._quiz_root.find_children("*", "Label3D", true, false).map(func(l: Label3D) -> String: return l.text)
		check(total > 0 and quiz._score == total and head.has("PASSED  ✓") and head.has("%d / %d" % [total, total]),
				"the results screen shows a pass (%d / %d, %s)" % [quiz._score, total, head])
		check(ProgressStore.status(Tutorials.T1) == "done", "ProgressStore records Tutorial 1 as passed (%s)" % ProgressStore.status(Tutorials.T1))
		check(row_shows_done(Tutorials.T1), "Tutorial 1's sidebar row shows the ✓")

	# 6. Relaunch: the ✓ is still there and nothing is seeded again
	app.queue_free()
	await frames(3)
	var files: Dictionary = note_files(fake_default)
	VaultStore.open_startup_vault(fake_default, fake_default, false)   # what the autoload does at launch
	await launch()
	check(not VaultStore.first_run and note_files(fake_default) == files, "the relaunch is not a first run and rewrites no note (%d files)" % files.size())
	check(row_shows_done(Tutorials.T1), "after the relaunch Tutorial 1's row still shows the ✓")
	app.queue_free()
	await frames(2)

	TestVault.remove_tree(fake_default)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


## Start the app window, as a launch does.
func launch() -> void:
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(6)


func open_title() -> String:
	return app.current_note.title if app.current_note != null else ""


## The sidebar row of the note titled `title` (null if it isn't listed).
func row(title: String) -> Button:
	for note in app._note_buttons:
		if note.title == title:
			return app._note_buttons[note]
	return null


func row_shows_done(title: String) -> bool:
	var b: Button = row(title)
	return b != null and b.icon == ProgressStore.icon("done")


## Every note file in the vault and its SHA-256.
func note_files(dir: String) -> Dictionary:
	var out: Dictionary = {}
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".tres"):
			out[dir.path_join(f)] = FileAccess.get_sha256(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			out.merge(note_files(dir.path_join(d)))
	return out


func move_mouse(pos: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)


## A left click at `pos` on `target`: move the mouse there, check that
## `target` is the control under it, then press and release. A mouse that
## isn't over the target fails the test and doesn't click.
func click_at(target: Control, pos: Vector2, what: String) -> void:
	move_mouse(pos)
	await process_frame
	var over: Control = get_root().gui_get_hovered_control()
	check(target != null and over == target, "the mouse is over %s before the click (%s)" % [what, over.name if over != null else "nothing"])
	if target == null or over != target:
		return
	press_left(pos)
	await frames(4)


## Click the middle of a sidebar row, scrolled into view.
func click_row(target: Button, what: String) -> void:
	if target == null:
		check(false, "%s is listed" % what)
		return
	(app.note_list_container.get_parent() as ScrollContainer).ensure_control_visible(target)
	await frames(2)
	await click_at(target, target.get_global_rect().get_center(), what)


func press_left(pos: Vector2) -> void:
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)


## Where a link to `title` is in the open note: a label whose one link goes
## to `title`, scrolled into view, and the middle of the run of points where
## the mouse would turn into a pointing hand (RichTextLabel shows it only
## over a link). Returns [label, global position], or [] if there's none.
func find_link(title: String) -> Array:
	for rtl: RichTextLabel in app.visual_layer.find_children("*", "RichTextLabel", true, false):
		# A row's links carry indexes into its targets, not titles (layer_engine)
		var targets: Array[String] = LayerEngine.link_targets(rtl)
		if targets.size() != 1 or targets[0] != title:
			continue
		app.doc_scroll.ensure_control_visible(rtl)
		await frames(2)
		for y in range(2, int(rtl.size.y), 4):
			var run: Array[int] = []
			for x in range(0, int(rtl.size.x), 2):
				if rtl.get_cursor_shape(Vector2(x, y)) == Control.CURSOR_POINTING_HAND:
					run.append(x)
				elif not run.is_empty():
					break
			if not run.is_empty():
				return [rtl, rtl.get_global_rect().position + Vector2(run[run.size() / 2], y)]
	return []


## Index of the clickable tile with this action in the quiz (-1 if none).
func tile(quiz: NoteScene3D, action: String) -> int:
	for i in range(quiz._tiles.size()):
		if quiz._tiles[i].action == action and quiz._tiles[i].enabled:
			return i
	return -1


## Click tile `i` of `quiz` with real input (as tests/tutorial_test.gd does),
## scrolling it into view first. Before pressing, the 3D card must be the
## control under the mouse and the tile it picks there must be `i`.
func click_tile(quiz: NoteScene3D, i: int, what: String) -> void:
	if i < 0:
		check(false, "%s is on the quiz card" % what)
		return
	var scroll: ScrollContainer = app.doc_scroll
	var pos: Vector2 = quiz._container.get_global_transform_with_canvas() * quiz.tile_screen_position(i)
	if not scroll.get_global_rect().grow(-4).has_point(pos):
		scroll.scroll_vertical += int(pos.y - scroll.get_global_rect().get_center().y)
		await frames(2)
		pos = quiz._container.get_global_transform_with_canvas() * quiz.tile_screen_position(i)
	move_mouse(pos)
	await process_frame
	var over: Control = get_root().gui_get_hovered_control()
	var on_tile: bool = over == quiz._container and quiz._hover_tile == i
	check(on_tile, "the mouse is over %s before the click (%s, tile %d)" % [what, over.name if over != null else "nothing", quiz._hover_tile])
	if not on_tile:
		return
	press_left(pos)
	await frames(3)
