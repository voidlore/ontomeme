extends SceneTree
## End-to-end quiz test with real mouse clicks on the 3D answer tiles.
##   headless:  godot --headless --path . -s res://tests/quiz_test.gd
##   + images:  godot --path . -s res://tests/quiz_test.gd -- <out_dir>

var fails: int = 0
var out: String = ""

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1

func shot(name: String) -> void:
	if out == "" or DisplayServer.get_name() == "headless":
		return
	await create_timer(0.9).timeout
	get_root().get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("saved ", name)

## Click a quiz tile through the whole GUI stack: window -> container -> ray pick.
func click_tile(card: NoteScene3D, i: int) -> void:
	# Scroll the note so the tile is inside the visible scroll area first
	var scroll: ScrollContainer = card.get_parent().get_parent().get_parent() as ScrollContainer
	var pos: Vector2 = card._container.get_global_transform_with_canvas() * card.tile_screen_position(i)
	if scroll != null and not scroll.get_global_rect().grow(-4).has_point(pos):
		scroll.scroll_vertical += int(pos.y - scroll.get_global_rect().get_center().y)
		for k in range(2):
			await process_frame
		pos = card._container.get_global_transform_with_canvas() * card.tile_screen_position(i)
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	await process_frame
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	for k in range(3):
		await process_frame

func find_card(app: Control) -> NoteScene3D:
	for c in app.visual_layer.get_children():
		if c is NoteScene3D and c.preset == "quiz":
			return c
	return null

func tile_index(card: NoteScene3D, action: String) -> int:
	for i in range(card._tiles.size()):
		if card._tiles[i].action == action:
			return i
	return -1

func _init() -> void:
	JourneyStore.file_override = "user://test_journey_quiz.json"   # never touch the real journey
	JourneyStore.reset()
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	ProgressStore.file_override = "user://test_progress_quiz.json"   # never touch real progress
	ProgressStore.reset()
	DisplayServer.window_set_size(Vector2i(1280, 820))

	# Parser
	var qs := NoteScene3D.parse_quiz(PackedStringArray([
		"q: Two plus two?", "a: 3", "a*: 4", "a: 5", "why: arithmetic", "learn: [[Maths]]",
		"q: broken, no correct answer", "a: x", "a: y",
	]))
	check(qs.size() == 1, "parser keeps valid questions only (%d)" % qs.size())
	check(qs[0].correct == 1 and qs[0].learn == "Maths" and qs[0].choices.size() == 3, "parser reads a*, learn [[link]], choices")

	for i in range(3):
		await process_frame
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await process_frame
	app.open_note_by_title("Quiz: Godot Fundamentals")
	check(app.current_note != null and app.current_note.title == "Quiz: Godot Fundamentals", "quiz note exists in the vault")
	app._switch_layer("visual")
	for i in range(10):
		await process_frame
	var card := find_card(app)
	check(card != null, "Read view renders the quiz as a 3D card")
	if card == null:
		quit(1)
		return
	app.doc_scroll.scroll_vertical = int(card.position.y) - 20
	await process_frame
	check(card._quiz.size() == 8, "quiz has 8 questions (%d)" % card._quiz.size())
	check(tile_index(card, "answer:0") >= 0 and card._tiles.size() == 4, "4 answer tiles shown")
	await shot("quiz_1_question")

	# Hover lifts the tile
	var local: Vector2 = card.tile_screen_position(0)
	var hm := InputEventMouseMotion.new()
	hm.position = card._container.get_global_transform_with_canvas() * local
	hm.global_position = hm.position
	get_root().push_input(hm)
	await process_frame
	check(card._hover_tile == 0, "hovering a tile highlights it")

	# Q1 wrong: pick A (correct is B)
	var q0: Dictionary = card._quiz[0]
	var wrong: int = (q0.correct + 1) % q0.choices.size()
	await click_tile(card, wrong)
	check(card._answered and card._score == 0, "clicking a wrong tile registers a wrong answer")
	check(card._feedback.text.begins_with("Not quite"), "feedback says it was wrong: '%s'" % card._feedback.text.left(40))
	var review: int = tile_index(card, "open:Nodes and Scenes")
	check(review >= 0, "a Review tile links to the explaining note")
	check(tile_index(card, "next") >= 0, "a Next tile appears")
	await shot("quiz_2_wrong")

	# Q2 right
	await click_tile(card, tile_index(card, "next"))
	check(card._qi == 1 and not card._answered, "Next advances to question 2")
	await click_tile(card, card._quiz[1].correct)
	check(card._score == 1 and card._feedback.text.begins_with("Correct"), "clicking the right tile scores it")
	check(tile_index(card, "open:Nodes and Scenes") == -1, "no Review tile after a right answer")
	await create_timer(0.15).timeout
	await shot("quiz_3_right")

	# Finish the rest quickly (alternate right/wrong) to reach results
	for qi in range(2, card._quiz.size()):
		await click_tile(card, tile_index(card, "next"))
		var q: Dictionary = card._quiz[qi]
		await click_tile(card, q.correct if qi % 2 == 0 else (q.correct + 1) % q.choices.size())
	await click_tile(card, tile_index(card, "results"))
	check(card._missed.size() >= 2, "results remember missed notes: %s" % str(card._missed))
	check(tile_index(card, "retry") >= 0, "results offer Try again")
	await shot("quiz_4_results")

	# Review tile opens the note that explains the missed idea
	var target: String = card._missed[0]
	await click_tile(card, tile_index(card, "open:" + target))
	for i in range(3):
		await process_frame
	check(app.current_note != null and app.current_note.title == target, "Review tile opened '%s'" % target)
	await shot("quiz_5_review_note")

	# Inline one-question check inside an explainer note
	app.open_note_by_title("Signals")
	app._switch_layer("visual")
	for i in range(5):
		await process_frame
	var mini := find_card(app)
	check(mini != null and mini._quiz.size() == 1, "explainer note 'Signals' has an inline quiz")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(ProgressStore.file_override))
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)
