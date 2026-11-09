extends SceneTree
## Objective chips in Read view: under a quiz or flashcard deck whose block
## names an objective, a chip says which objective it feeds (and opens it in
## the Journey), or offers to create one the Journey doesn't have yet.
##   headless:  godot --headless --path . -s res://tests/objective_chip_test.gd
##   + images:  godot --path . -s res://tests/objective_chip_test.gd -- <out_dir>

const TestVault = preload("res://tests/test_vault.gd")
const LESSON: String = "Shape Lesson"
const CARDS: String = "Solid Cards"
const MYSTERY: String = "Mystery Quiz"
const MOVER: String = "Shapes Lesson"
const STAYER: String = "Circles Lesson"
const RENAMED: String = "Triangle Lesson"
const LONG_NAME: String = "Explain, in your own words and with a drawing, why every face of a regular polyhedron is the same regular polygon"
var fails: int = 0
var out: String = ""
var app: Control


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


## Scroll a Read-view control into view, then click its middle.
func click(ctrl: Control) -> void:
	app.doc_scroll.ensure_control_visible(ctrl)
	await frames(2)
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


func open(title: String) -> void:
	app.open_note_by_title(title)
	app._switch_layer("visual")
	await frames(6)


## The objective chip rows in Read view, in note order.
func chips() -> Array:
	return app.visual_layer.get_children().filter(func(c): return c.has_meta("objective_chip"))


## Every bit of text a chip row shows (labels and buttons).
func chip_text(row: Control) -> String:
	var parts: PackedStringArray = []
	for c in row.find_children("*", "", true, false):
		if c is Label or c is Button:
			parts.append(c.text)
	return " ".join(parts)


func chip_button(row: Control, name: String) -> Button:
	return row.find_child(name, true, false) as Button


func make_note(title: String, folder: String, text: String) -> void:
	var note: ContentLayer = VaultStore.create_note(title, folder)
	note.raw_text = text
	VaultStore.save_note(note)


func quiz_block(objective: String, extra: String = "") -> String:
	return "```3d\npreset: quiz\n%sq: Which one is round?\na*: A sphere\na: A cube\n```\n" % (("objective: %s\n" % objective) if objective != "" else "") + extra


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	JourneyStore.file_override = "user://test_journey_chip.json"
	JourneyStore.reset()   # an empty Journey
	ProgressStore.file_override = "user://test_progress_chip.json"
	ProgressStore.reset()
	TestVault.open("chip", false)
	make_note(LESSON, "", "# Shapes\n\n" + quiz_block("Name shapes") + "\nA quiz with no objective:\n\n" + quiz_block(""))
	make_note(CARDS, "Geometry", "# Solids\n\n```3d\npreset: flashcards\nobjective: Name solids\nq: Six square faces?\na: A cube\n```\n")
	make_note(MYSTERY, "", quiz_block("Nobody has this one") + "\n" + quiz_block(LONG_NAME))
	make_note(MOVER, "", quiz_block("Name moved shapes"))
	make_note(STAYER, "", quiz_block("Name circles"))
	make_note(RENAMED, "", quiz_block("Name triangles"))
	VaultStore.refresh_note_list()

	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(3)

	await check_create_chip()
	await check_feeds_chip_opens_journey()
	await check_folder_topic()
	await check_unknown_objective_status()
	await check_outside_journey_change()
	await check_topic_after_move()
	await check_topic_while_open()
	await check_activity_after_rename()

	app.queue_free()
	await frames(2)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	TestVault.remove_tree(VaultStore.vault_path)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)


## An objective the Journey doesn't have: the chip offers Create, and a real
## click makes it, with this quiz as its demonstration.
func check_create_chip() -> void:
	await open(LESSON)
	var rows: Array = chips()
	check(rows.size() == 1, "one chip: only the quiz that names an objective gets one (%d)" % rows.size())
	if rows.is_empty():
		return
	var row: Control = rows[0]
	check(chip_text(row).contains("Name shapes") and chip_text(row).contains("isn't in your Journey yet") and chip_text(row).contains("Create"),
		"with an empty Journey the chip says so and offers Create (%s)" % chip_text(row))
	var card: Node = row.get_parent().get_child(row.get_index() - 1)
	check(card is NoteScene3D and card.preset == "quiz", "the chip sits right under its quiz card")
	await shot("chip1_create")
	var create: Button = chip_button(row, "CreateObjective")
	check(create != null, "the chip has a Create button")
	if create == null:
		return
	await click(create)
	var o: Dictionary = JourneyStore.find_objective_by_name("Name shapes")
	check(not o.is_empty(), "clicking Create makes the objective 'Name shapes'")
	if o.is_empty():
		return
	check(o.goal == "learning", "with goal Learning (%s)" % o.goal)
	check(o.demos.size() == 1 and o.demos[0].activity == LESSON + "#quiz0", "and one demonstration: this quiz, %s#quiz0 (%s)" % [LESSON, o.demos.map(func(d): return d.activity)])
	check(JourneyStore.topic_of(o.id).get("name", "") == "From notes", "a note at the top level puts it under the topic 'From notes' (%s)" % JourneyStore.topic_of(o.id).get("name", ""))
	check(JourneyStore.log_score(LESSON + "#quiz0", 3, 3) == 1, "log_score('%s#quiz0', 3, 3) now logs on 1 objective" % LESSON)
	JourneyStore.invalidate()
	check(not JourneyStore.find_objective_by_name("Name shapes").is_empty(), "the new objective is saved in journey.json")


## Once the objective exists, the chip reads "Feeds objective", shows its
## status icon, and a click opens it in the Journey tab.
func check_feeds_chip_opens_journey() -> void:
	await open(LESSON)
	var rows: Array = chips()
	if rows.is_empty():
		check(false, "the chip is still there after Create")
		return
	var row: Control = rows[0]
	var feeds: Button = chip_button(row, "ObjectiveChip")
	check(feeds != null and feeds.text.contains("Feeds objective") and feeds.text.contains("Name shapes"), "the chip now reads 'Feeds objective: Name shapes' (%s)" % chip_text(row))
	if feeds == null:
		return
	check(feeds.icon == ProgressStore.icon("done"), "and shows the objective's status icon (met: the done check)")
	await shot("chip2_feeds")
	var o: Dictionary = JourneyStore.find_objective_by_name("Name shapes")
	await click(feeds)
	await frames(2)
	var jp: JourneyPanel = app.journey_panel
	check(app.current_mode == "journey" and jp.visible, "clicking it opens the Journey tab (mode %s)" % app.current_mode)
	check(jp._sel_type == "objective" and jp._sel_id == o.id, "with that objective selected")
	var it: TreeItem = jp.tree.get_selected()
	check(it != null and it.get_metadata(0).id == o.id, "and highlighted in the tree")
	var name_edit: LineEdit = jp.find_child("ObjectiveName", true, false)
	check(name_edit != null and name_edit.text == "Name shapes", "its editor is open")
	await shot("chip3_journey")


## A deck in a folder: Create files the objective under a topic named after
## the folder, and links the deck (a cards key).
func check_folder_topic() -> void:
	await open(CARDS)
	var rows: Array = chips()
	var create: Button = chip_button(rows[0], "CreateObjective") if rows.size() == 1 else null
	check(create != null, "a flashcard deck naming a missing objective gets a Create chip too")
	if create == null:
		return
	await click(create)
	var o: Dictionary = JourneyStore.find_objective_by_name("Name solids")
	check(not o.is_empty() and JourneyStore.topic_of(o.id).get("name", "") == "Geometry", "a note in Geometry/ files it under the topic 'Geometry'")
	check(not o.is_empty() and o.demos.size() == 1 and o.demos[0].activity == CARDS + "#cards0", "linked to the deck, %s#cards0" % CARDS)
	check(chip_button(chips()[0], "ObjectiveChip") != null, "and the chip turns into 'Feeds objective' without leaving Read view")


## Finishing an activity whose objective: isn't in the Journey says so, and
## a long objective name doesn't widen the window.
func check_unknown_objective_status() -> void:
	await open(MYSTERY)
	check(app.get_node("AppLayout").get_combined_minimum_size().x <= 820.0, "a chip with a long objective name fits the minimum window width (%d px)" % int(app.get_node("AppLayout").get_combined_minimum_size().x))
	var card: NoteScene3D = null
	for c in app.visual_layer.get_children():
		if c is NoteScene3D and c.preset == "quiz":
			card = c
			break
	var q: Dictionary = card._quiz[0]
	await click_tile(card, q.correct)
	await click_tile(card, tile(card, "results"))
	check(app.status_label.text.contains("“Nobody has this one” isn't in your Journey yet"), "finishing it, the status bar says its objective isn't in the Journey (%s)" % app.status_label.text)
	check(JourneyStore.find_objective_by_name("Nobody has this one").is_empty(), "and nothing was created behind the learner's back")
	await shot("chip4_unknown_status")


## Another process (the MCP server, a sync tool) adds the objective a chip
## names: the disk watcher's reload turns that chip into "Feeds objective"
## without the note being opened again.
func check_outside_journey_change() -> void:
	var p: String = ProjectSettings.globalize_path(JourneyStore.path())
	var data: Dictionary = JourneyStore.read_journey(p).data
	data.topics.append({"id": "outside-t", "name": "Outside", "description": "", "objectives": [
		{"id": "outside-o", "name": "Nobody has this one", "description": "", "goal": "learning", "demos": [], "log": []}]})
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t", false))
	f.close()
	app.check_disk_changes()
	await frames(2)
	var rows: Array = chips()
	var row: Control = rows[0] if rows.size() > 0 else null
	check(row != null and chip_button(row, "ObjectiveChip") != null and chip_text(row).contains("Nobody has this one"),
		"an objective another process adds to journey.json turns its chip into 'Feeds objective' (%s)" % (chip_text(row) if row != null else "no chip"))


## A note moved to another folder: Read view used to keep the chip it had
## built (its key had no folder in it), so Create filed the objective under
## the old folder's topic.
func check_topic_after_move() -> void:
	await open(MOVER)
	var rows: Array = chips()
	check(rows.size() == 1 and rows[0].get_meta("objective_chip").topic == "From notes", "a top-level note's chip files under 'From notes'")
	var note: ContentLayer = app.current_note
	check(app.move_note_to(note, "Geometry") and VaultStore.folder_of(note) == "Geometry", "the note moves to Geometry/")
	app._switch_layer("raw")
	await frames(2)
	app._open_note(note)
	app._switch_layer("visual")
	await frames(6)
	rows = chips()
	var create: Button = chip_button(rows[0], "CreateObjective") if rows.size() == 1 else null
	check(rows.size() == 1 and rows[0].get_meta("objective_chip").topic == "Geometry", "opened again, its chip files under 'Geometry' (%s)"
		% (rows[0].get_meta("objective_chip").topic if rows.size() == 1 else "no chip"))
	check(create != null and create.tooltip_text.contains("under the topic “Geometry”"), "Create's tooltip names Geometry (%s)" % (create.tooltip_text if create != null else "no Create"))
	if create == null:
		return
	await click(create)
	var o: Dictionary = JourneyStore.find_objective_by_name("Name moved shapes")
	check(not o.is_empty() and JourneyStore.topic_of(o.id).get("name", "") == "Geometry", "Create files it under 'Geometry' (%s)"
		% (JourneyStore.topic_of(o.id).get("name", "") if not o.is_empty() else "not created"))


## A move or a folder rename made while the note's Read view is on screen
## (the sidebar drag, the context menu's Move to and Rename folder): Read
## view used to keep the chip it had built until the note was opened again,
## so Create filed the objective under the old folder's topic.
func check_topic_while_open() -> void:
	await open(STAYER)
	var note: ContentLayer = app.current_note
	var rows: Array = chips()
	check(rows.size() == 1 and rows[0].get_meta("objective_chip").topic == "From notes", "a top-level note's chip files under 'From notes'")
	check(app.move_note_to(note, "Shapes") and VaultStore.folder_of(note) == "Shapes", "the open note moves to Shapes/ with Read view on screen")
	await frames(8)
	check(app.current_mode == "visual" and app.current_note == note, "Read view still shows it (mode %s)" % app.current_mode)
	rows = chips()
	var create: Button = chip_button(rows[0], "CreateObjective") if rows.size() == 1 else null
	check(rows.size() == 1 and rows[0].get_meta("objective_chip").topic == "Shapes", "without opening it again, its chip files under 'Shapes' (%s)"
		% (rows[0].get_meta("objective_chip").topic if rows.size() == 1 else "no chip"))
	check(create != null and create.tooltip_text.contains("under the topic “Shapes”"), "Create's tooltip names Shapes (%s)" % (create.tooltip_text if create != null else "no Create"))
	check(app.rename_folder("Shapes", "Circles") == "Circles" and VaultStore.folder_of(note) == "Circles", "its folder is renamed to Circles")
	await frames(8)
	rows = chips()
	create = chip_button(rows[0], "CreateObjective") if rows.size() == 1 else null
	check(rows.size() == 1 and rows[0].get_meta("objective_chip").topic == "Circles", "after the folder rename its chip files under 'Circles' (%s)"
		% (rows[0].get_meta("objective_chip").topic if rows.size() == 1 else "no chip"))
	if create == null:
		check(false, "the chip still offers Create")
		return
	await click(create)
	var o: Dictionary = JourneyStore.find_objective_by_name("Name circles")
	check(not o.is_empty() and JourneyStore.topic_of(o.id).get("name", "") == "Circles", "Create files it under 'Circles' (%s)"
		% (JourneyStore.topic_of(o.id).get("name", "") if not o.is_empty() else "not created"))


## The open note renamed with Read view on screen (F2, the sidebar's
## Rename): the chip's activity key is the note's title, so it must follow,
## or Create links the objective to a quiz that no longer exists and the
## quiz's scores never reach it.
func check_activity_after_rename() -> void:
	await open(RENAMED)
	var rows: Array = chips()
	check(rows.size() == 1 and rows[0].get_meta("objective_chip").activity == RENAMED + "#quiz0", "the chip's activity is %s#quiz0" % RENAMED)
	check(app._rename_current("Triangle Basics") and app.current_note.title == "Triangle Basics", "the open note is renamed to Triangle Basics with Read view on screen")
	await frames(8)
	check(app.current_mode == "visual", "Read view still shows it (mode %s)" % app.current_mode)
	rows = chips()
	check(rows.size() == 1 and rows[0].get_meta("objective_chip").activity == "Triangle Basics#quiz0", "without opening it again, its chip's activity is Triangle Basics#quiz0 (%s)"
		% (rows[0].get_meta("objective_chip").activity if rows.size() == 1 else "no chip"))
	var create: Button = chip_button(rows[0], "CreateObjective") if rows.size() == 1 else null
	if create == null:
		check(false, "the chip still offers Create")
		return
	await click(create)
	var o: Dictionary = JourneyStore.find_objective_by_name("Name triangles")
	check(not o.is_empty() and o.demos.size() == 1 and o.demos[0].activity == "Triangle Basics#quiz0", "Create links the renamed quiz, Triangle Basics#quiz0 (%s)"
		% (o.demos.map(func(d): return d.activity) if not o.is_empty() else "not created"))
	check(JourneyStore.log_score("Triangle Basics#quiz0", 3, 3) == 1, "and its score reaches the objective")
