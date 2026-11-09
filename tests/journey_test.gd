extends SceneTree
## Learning Journey: topics → objectives → demonstrations → logged scores,
## flashcards, Launch, and the tab's UI (real mouse clicks).
##   headless:  godot --headless --path . -s res://tests/journey_test.gd
##   + images:  godot --path . -s res://tests/journey_test.gd -- <out_dir>

const TestVault = preload("res://tests/test_vault.gd")
var fails: int = 0
var out: String = ""
var app: Control
const T1: String = "Tutorial 1: Writing Notes"
const T7: String = "Tutorial 7: Learning Objectives"

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1

func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame

func shot(name: String) -> void:
	if out == "" or DisplayServer.get_name() == "headless":
		return
	await create_timer(1.0).timeout
	get_root().get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("saved ", name)

func click_at(pos: Vector2) -> void:
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
	await frames(3)

func click(ctrl: Control) -> void:
	await click_at(ctrl.get_global_rect().get_center())

func click_tile(card: NoteScene3D, i: int) -> void:
	var scroll: ScrollContainer = app.doc_scroll
	var pos: Vector2 = card._container.get_global_transform_with_canvas() * card.tile_screen_position(i)
	if not scroll.get_global_rect().grow(-4).has_point(pos):
		scroll.scroll_vertical += int(pos.y - scroll.get_global_rect().get_center().y)
		await frames(2)
		pos = card._container.get_global_transform_with_canvas() * card.tile_screen_position(i)
	await click_at(pos)

func tile(card: NoteScene3D, action: String) -> int:
	for i in range(card._tiles.size()):
		if str(card._tiles[i].action) == action:
			return i
	return -1

func find(root: Node, name: String) -> Node:
	return root.find_child(name, true, false)

func select_tree(id: String) -> void:
	var it: TreeItem = app.journey_panel.tree.get_root()
	var stack: Array = [it]
	while not stack.is_empty():
		var cur: TreeItem = stack.pop_back()
		if cur.get_metadata(0) is Dictionary and cur.get_metadata(0).id == id:
			app.journey_panel.tree.scroll_to_item(cur)
			await frames(1)
			var r: Rect2 = app.journey_panel.tree.get_item_area_rect(cur)
			await click_at(app.journey_panel.tree.get_global_transform() * (r.position + r.size / 2.0))
			return
		stack.append_array(cur.get_children())

## Files in `dir` whose names match `pattern` (String.match: * and ?).
func files_like(dir: String, pattern: String) -> PackedStringArray:
	var found: PackedStringArray = []
	for f in DirAccess.get_files_at(dir):
		if f.match(pattern):
			found.append(f)
	return found

func empty_dir(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))

func write_text(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()

## Probe5: a journey.json cut off mid-write used to read as empty, and the
## next change replaced it, losing every topic. Now its bytes are kept
## beside it first, and saves never leave half a file.
func check_unreadable_file_kept(jp: JourneyPanel) -> void:
	const DIR: String = "user://test-journey-unreadable"
	const TRUNCATED: String = '{"topics": [{"id": "t1", "name": "Mine", "objectives": []}, {"id": "t2", "na'
	var before: String = JourneyStore.file_override
	empty_dir(DIR)
	JourneyStore.file_override = DIR.path_join("journey.json")
	write_text(JourneyStore.file_override, TRUNCATED)
	JourneyStore.invalidate()
	jp.refresh()
	await frames(2)
	var banner: Node = find(jp, "JourneyFileWarning")
	JourneyStore.add_topic("New")
	var kept: PackedStringArray = files_like(DIR, "journey.unreadable-*.json")
	check(kept.size() == 1 and FileAccess.get_file_as_string(DIR.path_join(kept[0])) == TRUNCATED, "a truncated journey.json is kept, byte for byte, as journey.unreadable-<stamp>.json before the next save (%s)" % [kept])
	check(kept.size() == 1 and JourneyStore.last_error == "Your journey file couldn't be read; it was kept as %s." % kept[0], "last_error names the copy (%s)" % JourneyStore.last_error)
	check(banner != null and (banner.get_child(0) as Label).text == JourneyStore.last_error, "the Journey tab shows it in a banner")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(JourneyStore.file_override))
	check(saved is Dictionary and saved.topics.size() == 1 and saved.topics[0].name == "New", "the next save writes a whole new journey.json")
	check(files_like(DIR, "*.tmp").is_empty(), "no .tmp file is left after a save")

	# The same broken bytes read twice are kept once; other broken bytes get their own copy
	write_text(JourneyStore.file_override, TRUNCATED)
	for i in range(2):
		JourneyStore.invalidate()
		JourneyStore.topics()
	check(files_like(DIR, "journey.unreadable-*.json").size() == 1, "reading the same unreadable file again doesn't copy it again")
	write_text(JourneyStore.file_override, '{"topics": "none"}')
	JourneyStore.invalidate()
	check(JourneyStore.topics().is_empty() and files_like(DIR, "journey.unreadable-*.json").size() == 2, "a file of the wrong shape ({\"topics\": \"none\"}) is kept too")
	JourneyStore.save()
	JourneyStore.invalidate()
	jp.refresh()
	await frames(2)
	check(JourneyStore.last_error == "" and find(jp, "JourneyFileWarning") == null, "a readable file clears the error and the banner")

	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	DirAccess.remove_absolute(DIR)
	JourneyStore.file_override = before
	JourneyStore.invalidate()

## A journey.json the app can't open (no read permission here; on Windows, a
## sync tool or antivirus holding it) used to read as empty, and the next
## change renamed a new file over it: every topic gone, no message. Now
## nothing is saved over it until it has been read.
func check_unopenable_file_left_alone() -> void:
	const DIR: String = "user://test-journey-unopenable"
	const MINE: String = '{"version": 1, "topics": [{"id": "t1", "name": "Mine", "objectives": []}]}'
	var before: String = JourneyStore.file_override
	empty_dir(DIR)
	var p: String = DIR.path_join("journey.json")
	JourneyStore.file_override = p
	write_text(p, MINE)
	FileAccess.set_unix_permissions(p, 0)
	if FileAccess.open(p, FileAccess.READ) != null:   # root, or a system without Unix permissions
		print("SKIP  an unopenable journey.json: chmod 000 doesn't stop this user reading it")
	else:
		JourneyStore.invalidate()
		check(JourneyStore.topics().is_empty() and JourneyStore.last_error.begins_with("Your journey file couldn't be opened"), "a journey.json that can't be opened loads empty, and last_error says so (%s)" % JourneyStore.last_error)
		JourneyStore.add_topic("New")
		check(JourneyStore.save() == ERR_FILE_CANT_READ, "save() refuses to write over it (ERR_FILE_CANT_READ)")
		FileAccess.set_unix_permissions(p, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
		check(FileAccess.get_file_as_string(p) == MINE, "after add_topic, journey.json still holds its own bytes ('Mine' survives)")
		check(files_like(DIR, "*.tmp").is_empty() and files_like(DIR, "journey.unreadable-*.json").is_empty(), "no .tmp and no unreadable copy was made of it")
		JourneyStore.invalidate()   # what opening the vault again does
		check(JourneyStore.topics().size() == 1 and JourneyStore.topics()[0].name == "Mine" and JourneyStore.last_error == "", "once it can be read again, it loads and the error clears")
		JourneyStore.add_topic("New")
		var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		check(saved is Dictionary and saved.topics.size() == 2, "and saves go through again ('Mine' and 'New')")
	FileAccess.set_unix_permissions(p, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	empty_dir(DIR)
	DirAccess.remove_absolute(DIR)
	JourneyStore.file_override = before
	JourneyStore.invalidate()

## A save that removed journey.json and then couldn't rename journey.tmp over
## it (Windows, with antivirus or a sync tool holding the new file) leaves the
## .tmp as the only copy. Nothing read it back: the next run loaded an empty
## journey, and its next save emptied journey.tmp. Now it's put back first.
func check_leftover_tmp_put_back() -> void:
	const DIR: String = "user://test-journey-leftover-tmp"
	const HISTORY: String = '{"version": 1, "topics": [{"id": "t1", "name": "Two years of history", "objectives": []}]}'
	var before: String = JourneyStore.file_override
	empty_dir(DIR)
	var p: String = DIR.path_join("journey.json")
	var tmp: String = DIR.path_join("journey.tmp")
	JourneyStore.file_override = p
	write_text(tmp, HISTORY)
	JourneyStore.invalidate()
	check(JourneyStore.topics().size() == 1 and JourneyStore.topics()[0].name == "Two years of history" and JourneyStore.last_error == "", "with no journey.json, a journey.tmp beside it loads (%d topics, error '%s')" % [JourneyStore.topics().size(), JourneyStore.last_error])
	check(FileAccess.get_file_as_string(p) == HISTORY and not FileAccess.file_exists(tmp), "and is put back as journey.json, byte for byte")
	JourneyStore.add_topic("New")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	check(saved is Dictionary and saved.topics.map(func(t): return t.name) == ["Two years of history", "New"], "the next save keeps it and adds to it")

	# A .tmp cut off mid-write (the first save ever crashed) is kept aside like any unreadable file
	const CUT: String = '{"version": 1, "topics": [{"id": "t1", "na'
	empty_dir(DIR)
	write_text(tmp, CUT)
	JourneyStore.invalidate()
	var none: bool = JourneyStore.topics().is_empty()
	var kept: PackedStringArray = files_like(DIR, "journey.unreadable-*.json")
	check(none and kept.size() == 1 and FileAccess.get_file_as_string(DIR.path_join(kept[0])) == CUT, "a leftover journey.tmp that doesn't parse is kept as journey.unreadable-<stamp>.json (%s)" % [kept])

	# When it can't be put back (here the folder is read-only), nothing writes over it
	const RX: int = FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_EXECUTE_OWNER
	empty_dir(DIR)
	write_text(tmp, HISTORY)
	FileAccess.set_unix_permissions(DIR, RX)
	var probe := FileAccess.open(DIR.path_join("probe"), FileAccess.WRITE)
	if probe != null:   # root, or a system without Unix permissions
		probe.close()
		print("SKIP  a leftover journey.tmp that can't be put back: chmod 500 doesn't stop this user writing")
	else:
		JourneyStore.invalidate()
		check(JourneyStore.topics().is_empty() and JourneyStore.last_error.begins_with("Your journey file was left as journey.tmp"), "a journey.tmp that can't be renamed back sets last_error (%s)" % JourneyStore.last_error)
		JourneyStore.add_topic("New")
		check(FileAccess.get_file_as_string(tmp) == HISTORY and not FileAccess.file_exists(p), "and the next save leaves journey.tmp's bytes alone")
	FileAccess.set_unix_permissions(DIR, RX | FileAccess.UNIX_WRITE_OWNER)
	JourneyStore.invalidate()
	check(JourneyStore.topics().size() == 1 and FileAccess.file_exists(p) and JourneyStore.last_error == "", "once the folder can be written, it's put back and loads")

	empty_dir(DIR)
	DirAccess.remove_absolute(DIR)
	JourneyStore.file_override = before
	JourneyStore.invalidate()

## Saves write journey.tmp and rename it over journey.json, so a write that
## fails part way leaves journey.json as it was. Here journey.tmp can't be
## written (a folder has its name): the save fails and journey.json keeps
## its bytes, where a plain in-place write would replace them.
func check_save_goes_through_tmp() -> void:
	const DIR: String = "user://test-journey-atomic"
	const MINE: String = '{"version": 1, "topics": [{"id": "t1", "name": "Mine", "objectives": []}]}'
	var before: String = JourneyStore.file_override
	empty_dir(DIR)
	var p: String = DIR.path_join("journey.json")
	var tmp: String = DIR.path_join("journey.tmp")
	JourneyStore.file_override = p
	write_text(p, MINE)
	DirAccess.make_dir_absolute(tmp)
	JourneyStore.invalidate()
	JourneyStore.add_topic("New")
	check(JourneyStore.topics().size() == 2 and JourneyStore.save() != OK, "with journey.tmp unwritable, save() returns an error")
	check(FileAccess.get_file_as_string(p) == MINE, "and journey.json keeps its old bytes: the save never wrote it in place")
	DirAccess.remove_absolute(tmp)
	var saved: Variant = null
	if JourneyStore.save() == OK:
		saved = JSON.parse_string(FileAccess.get_file_as_string(p))
	check(saved is Dictionary and saved.topics.size() == 2 and files_like(DIR, "*.tmp").is_empty() and not DirAccess.dir_exists_absolute(tmp), "once journey.tmp can be written, save() writes both topics, and no .tmp is left")
	empty_dir(DIR)
	DirAccess.remove_absolute(DIR)
	JourneyStore.file_override = before
	JourneyStore.invalidate()

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	DisplayServer.window_set_size(Vector2i(1280, 860))
	JourneyStore.file_override = "user://test_journey_journey.json"
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_journey.json"
	ProgressStore.reset()
	TestVault.open("journey")   # never touch the user's vault

	# ── Store ──
	check(JourneyStore.parse_key("Tutorial 5: Making a Quiz#quiz2") == {"note": "Tutorial 5: Making a Quiz", "kind": "quiz", "index": 2}, "activity keys round-trip")
	check(JourneyStore.output_value("percent", 5, 7) == 71.0 and JourneyStore.output_value("correct", 5, 7) == 5.0 and JourneyStore.output_value("pass", 5, 7) == 1.0 and JourneyStore.output_value("pass", 4, 7) == 0.0, "score outputs: %, correct, pass/fail")
	await frames(2)
	var acts: Array[Dictionary] = JourneyStore.activities()
	var t5q: Array = acts.filter(func(a): return a.note == "Tutorial 5: Making a Quiz" and a.kind == "quiz")
	var t7c: Array = acts.filter(func(a): return a.note == T7 and a.kind == "cards")
	check(t5q.size() == 3 and t7c.size() == 1, "activities(): Tutorial 5's 3 quizzes and Tutorial 7's flashcards (``` examples ignored)")
	var topic: Dictionary = JourneyStore.add_topic("Colour theory")
	var obj: Dictionary = JourneyStore.add_objective(topic.id, "Write and link notes", "", "learning")
	JourneyStore.add_demo(obj.id, JourneyStore.activity_key(T1, "quiz", 0), "percent")
	check(JourneyStore.add_demo(obj.id, JourneyStore.activity_key(T1, "quiz", 0)).id == obj.demos[0].id and obj.demos.size() == 1, "adding the same demonstration twice is a no-op")
	var fluent: Dictionary = JourneyStore.add_objective(topic.id, "Name primary shapes and colors", "", "fluent")
	check(JourneyStore.log_score("Nowhere#quiz0", 1, 2) == 0, "scores from unlinked activities aren't logged")

	# ── UI: Journey tab ──
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(3)
	await click(app.layer_buttons.journey)
	await frames(2)
	var jp: JourneyPanel = app.journey_panel
	check(app.current_mode == "journey" and jp.visible and not app.note_content.visible, "the Journey button opens the Journey tab")
	check(jp.tree.get_root().get_child_count() == 1 and jp.tree.get_root().get_child(0).get_child_count() == 2, "tree shows the topic and its 2 objectives")
	await select_tree(obj.id)
	check(jp._sel_type == "objective" and jp._sel_id == obj.id, "clicking an objective in the tree selects it")
	var goal: OptionButton = find(jp, "GoalOption")
	check(goal != null and goal.get_item_text(goal.selected) == "Learning" and goal.item_count == 3, "goal picker: Fluent / Learning / Forget, showing Learning")
	var demos: Node = find(jp, "Demos")
	check(demos != null and demos.get_child_count() == 1, "one demonstration row")
	var launch: Button = find(demos, "Launch")
	await shot("j1_objective_empty")

	# Launch (real click) → plays the Tutorial 1 quiz → logged
	check(app.get_node("AppLayout").get_combined_minimum_size().x <= 820.0, "Journey layout fits the minimum window width (%d px)" % int(app.get_node("AppLayout").get_combined_minimum_size().x))
	(find(jp, "JourneyScroll") as ScrollContainer).ensure_control_visible(launch)
	await frames(2)
	await click(launch)
	await frames(4)
	check(app.current_mode == "visual" and app.current_note.title == T1, "Launch opens the note in Read view")
	var card: NoteScene3D = null
	for c in app.visual_layer.get_children():
		if c is NoteScene3D and c.preset == "quiz":
			card = c
	for qi in range(card._quiz.size()):
		var q: Dictionary = card._quiz[qi]
		await click_tile(card, q.correct if qi != 1 else (q.correct + 1) % q.choices.size())
		await click_tile(card, tile(card, "results" if qi == card._quiz.size() - 1 else "next"))
	check(obj.log.size() == 1 and int(obj.log[0].score) == 2 and int(obj.log[0].max) == 3 and float(obj.log[0].value) == 67.0, "finishing the quiz logs 2/3 = 67% on the objective")
	check(str(obj.log[0].date).length() >= 19 and app.status_label.text.begins_with("Logged 2 / 3 to 1 learning objective"), "log entry has the date; status bar confirms")
	check(JourneyStore.summary(obj).met, "67% meets a Learning goal (two thirds)")

	# Flashcards: objective: line auto-links + logs
	app.open_note_by_title(T7)
	app._switch_layer("visual")
	await frames(5)
	var deck: NoteScene3D = null
	for c in app.visual_layer.get_children():
		if c is NoteScene3D and c.preset == "flashcards":
			deck = c
	check(deck != null and deck._cards.size() == 6 and deck.params.get("objective") == "Name primary shapes and colors", "Tutorial 7's deck has 6 cards and an objective: line")
	app.doc_scroll.scroll_vertical = int(deck.position.y) - 20
	await frames(2)
	await shot("j2_card_front")
	await click_tile(deck, tile(deck, "flip"))
	await create_timer(0.45).timeout
	check(deck._card_back and deck._card_tile.label.text == "Red, yellow and blue" and tile(deck, "got") >= 0, "clicking the card flips it to the answer + shows Knew it / Not yet")
	await shot("j3_card_back")
	for i in range(6):
		if i > 0:
			await click_tile(deck, tile(deck, "flip"))
			await create_timer(0.35).timeout
		await click_tile(deck, tile(deck, "got" if i != 3 else "miss"))
	check(deck._score == 5 and deck._quiz_root.get_children().any(func(n): return n is Label3D and n.text == "5 / 6"), "deck results: 5 / 6 cards known")
	check(fluent.demos.size() == 1 and fluent.log.size() == 1 and float(fluent.log[0].value) == 83.0, "objective: line linked the deck and logged 83%")
	check(not JourneyStore.summary(fluent).met, "83% does not meet a Fluent goal (90%)")
	await shot("j4_deck_done")

	# Score output change → next log uses it
	fluent.demos[0].output = "correct"
	JourneyStore.save()
	await click_tile(deck, tile(deck, "retry"))
	for i in range(6):
		await click_tile(deck, tile(deck, "flip"))
		await create_timer(0.35).timeout
		await click_tile(deck, tile(deck, "got"))
	check(fluent.log.size() == 2 and JourneyStore.format_value(fluent.log[1]) == "6 / 6 correct", "score output 'Correct answers' logs '6 / 6 correct'")
	check(JourneyStore.summary(fluent).met, "6/6 meets Fluent")

	# Back to the Journey: history + chart for the fluent objective
	app._switch_layer("journey")
	await frames(2)
	await select_tree(fluent.id)
	await frames(2)
	var hist: Node = find(jp, "History")
	check(hist != null and hist.get_child_count() == 2 and find(jp, "TrendChart") != null, "history lists both attempts with a trend chart")
	var status: RichTextLabel = find(jp, "ObjectiveStatus")
	check(status != null and status.text.contains("Fluent") and status.text.contains("2 attempts"), "status card: Fluent, 2 attempts")
	await shot("j5_journey_history")

	# Editing in the UI saves
	var name_edit: LineEdit = find(jp, "ObjectiveName")
	name_edit.text = "Name the primary shapes and colours"
	name_edit.text_changed.emit(name_edit.text)
	goal = find(jp, "GoalOption")
	goal.select(2)
	goal.item_selected.emit(2)
	await frames(2)
	JourneyStore.invalidate()
	var reloaded: Dictionary = JourneyStore.find_objective(fluent.id)
	check(reloaded.name == "Name the primary shapes and colours" and reloaded.goal == "forget" and reloaded.log.size() == 2, "edits and history persist to journey.json")

	# Add demonstration menu offers vault activities
	await select_tree(obj.id)
	var add: MenuButton = find(jp, "AddDemo")
	check(add != null and add.get_popup().item_count == acts.size() - 1, "Add demonstration lists every other quiz / deck in the vault (%d)" % add.get_popup().item_count)
	add.get_popup().id_pressed.emit(0)
	await frames(2)
	check(JourneyStore.find_objective(obj.id).demos.size() == 2, "picking one adds it")

	# Topic view + new topic button
	await click(find(jp, "AddTopic"))   # header button, always in view
	await frames(2)
	check(JourneyStore.topics().size() == 2 and jp._sel_type == "topic", "+ Topic creates and selects a new topic")
	await shot("j6_new_topic")

	await check_unreadable_file_kept(jp)
	check_unopenable_file_left_alone()
	check_leftover_tmp_put_back()
	check_save_goes_through_tmp()

	DirAccess.remove_absolute(ProjectSettings.globalize_path(JourneyStore.file_override))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ProgressStore.file_override))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)
