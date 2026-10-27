extends SceneTree
## Tutorial series test: content integrity + every new feature it teaches.
##   headless:  godot --headless --path . -s res://tests/tutorial_test.gd -- [fox.glb]
##   + images:  godot --path . -s res://tests/tutorial_test.gd -- [fox.glb] <out_dir>

const TestVault = preload("res://tests/test_vault.gd")
var fails: int = 0
var out: String = ""
var app: Control

const TUTORIALS: Array[String] = [
	"Start Here: Tutorials", "Tutorial 1: Writing Notes", "Tutorial 2: Linking Notes",
	"Tutorial 3: Your First 3D Scene", "Tutorial 4: Shapes and Colors",
	"Tutorial 5: Making a Quiz", "Tutorial 6: Importing 3D Models", "Tutorial 7: Learning Objectives",
]

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1

func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame

func shot(name: String, card: Control = null) -> void:
	if out == "" or DisplayServer.get_name() == "headless":
		return
	if card != null:
		app.doc_scroll.scroll_vertical = int(card.position.y) - 30
	await create_timer(1.0).timeout
	get_root().get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("saved ", name)

func cards() -> Array:
	return app.visual_layer.get_children().filter(func(c): return c is NoteScene3D)

func open(title: String) -> void:
	app.open_note_by_title(title)
	app._switch_layer("visual")
	await frames(6)

func has_mesh(n: Node) -> bool:
	return not n.find_children("*", "MeshInstance3D", true, false).is_empty()

func click_tile(card: NoteScene3D, i: int) -> void:
	var scroll: ScrollContainer = app.doc_scroll
	var pos: Vector2 = card._container.get_global_transform_with_canvas() * card.tile_screen_position(i)
	if not scroll.get_global_rect().grow(-4).has_point(pos):
		scroll.scroll_vertical += int(pos.y - scroll.get_global_rect().get_center().y)
		await frames(2)
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
	await frames(3)

func _init() -> void:
	JourneyStore.file_override = "user://test_journey_tutorial.json"   # never touch the real journey
	JourneyStore.reset()
	var args := OS.get_cmdline_user_args()
	var fox: String = ""
	for a in args:
		if a.ends_with(".glb"):
			fox = a
		else:
			out = a
	ProgressStore.file_override = "user://test_progress_tutorial.json"   # never touch real progress
	ProgressStore.reset()
	TestVault.open("tutorial")   # never touch the user's vault
	DisplayServer.window_set_size(Vector2i(1280, 860))

	# ── Parsers ──
	var o := NoteScene3D.parse_object("sphere", "blue, at 2 0 1, size 1.5, spin, label Earth")
	check(o.kind == "sphere" and o.color == NoteScene3D.COLORS.blue and o.at == Vector3(2, 0, 1) and o.size == 1.5 and o.spin == 1.0 and o.name == "Earth", "parse_object reads colour/at/size/spin/label")
	check(NoteScene3D.parse_object("box", "#ff8800").kind == "cube", "synonym box -> cube, hex colour ok")
	check(NoteScene3D.answer_object("red cube").kind == "cube" and NoteScene3D.answer_object("cube red").kind == "cube", "answer 'red cube' / 'cube red' -> 3D object")
	check(NoteScene3D.answer_object("Red").is_empty() and NoteScene3D.answer_object("Cube").is_empty() and NoteScene3D.answer_object("a red cube please").is_empty(), "plain text answers stay text")
	check(NoteScene3D.answer_object("model rocket.glb").kind == "model", "answer 'model x.glb' -> model")

	await frames(3)
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(2)

	# ── Content integrity: all notes exist, links + learn: targets resolve ──
	var titles: Dictionary = {}
	for n in VaultStore.note_list:
		titles[n.title.strip_edges().to_lower()] = true
	var link_rx := RegEx.new()
	link_rx.compile("\\[\\[([^\\]|]+)(?:\\|[^\\]]+)?\\]\\]")
	var broken: Array[String] = []
	var bad_quiz: Array[String] = []
	var quiz_count: int = 0
	for t in TUTORIALS:
		var idx: int = VaultStore.get_note_index(t)
		check(idx >= 0, "note exists: " + t)
		if idx < 0:
			continue
		var text: String = VaultStore.note_list[idx].raw_text
		# links outside code (fenced ```` blocks and `spans` are examples)
		var prose: String = ""
		var fence: int = 0   # backtick count of the open fence, 0 = prose
		for line in text.split("\n"):
			var s: String = line.strip_edges()
			var ticks: int = 0
			while ticks < s.length() and s[ticks] == "`":
				ticks += 1
			if ticks >= 3:
				if fence == 0:
					fence = ticks
					continue
				elif ticks >= fence and s.substr(ticks).strip_edges() == "":
					fence = 0
					continue
			if fence == 0:
				var code_rx := RegEx.new()
				code_rx.compile("`[^`]*`")
				prose += code_rx.sub(line, "", true) + "\n"
		for m in link_rx.search_all(prose):
			if not titles.has(m.get_string(1).strip_edges().to_lower()):
				broken.append("%s -> %s" % [t, m.get_string(1)])
		# every live quiz: parses fully, learn: notes exist
		var blocks: PackedStringArray = text.split("```3d\npreset: quiz\n")
		for bi in range(1, blocks.size()):
			var body: String = blocks[bi].split("\n```")[0]
			var lines: PackedStringArray = body.split("\n")
			var qs := NoteScene3D.parse_quiz(lines)
			var q_lines: int = 0
			for l in lines:
				if l.begins_with("q:"):
					q_lines += 1
			quiz_count += 1
			if qs.size() != q_lines:
				bad_quiz.append("%s: %d of %d questions valid" % [t, qs.size(), q_lines])
			for q in qs:
				if q.learn != "" and not titles.has(q.learn.to_lower()):
					bad_quiz.append("%s: learn '%s' missing" % [t, q.learn])
	check(broken.is_empty(), "every [[link]] in the tutorials resolves %s" % str(broken))
	check(bad_quiz.is_empty() and quiz_count >= 7, "all %d tutorial quizzes parse; every learn: note exists %s" % [quiz_count, str(bad_quiz)])

	# ── Tutorial 1: markup examples render literally ──
	await open("Tutorial 1: Writing Notes")
	var code_boxes: Array = app.visual_layer.get_children().filter(func(c): return c is CodeEdit)
	check(code_boxes.size() == 2 and code_boxes[0].text.begins_with("# Big title"), "```` text blocks render as literal code (%d)" % code_boxes.size())
	var rich: Array = app.visual_layer.get_children().filter(func(c): return c is RichTextLabel and c.text.contains("[code]**bold**[/code]"))
	check(rich.size() == 1, "`**bold**` stays literal inside a code span")
	check(cards().size() == 1 and cards()[0].preset == "quiz", "Tutorial 1 ends with a quiz card")
	await shot("t1_top")

	# ── Tutorial 2: link to a missing note creates it ──
	var ghost: String = "Zz Test Ghost Note"
	app.open_note_by_title(ghost, true)
	await frames(3)
	check(app.current_note != null and app.current_note.title == ghost and app.current_mode == "raw", "clicking a link to a missing note creates + opens it")
	app._on_delete_note_pressed()
	await frames(2)
	for c in get_root().find_children("*", "ConfirmationDialog", true, false):
		if c.visible:
			c.confirmed.emit()
	await frames(2)
	await open("Tutorial 2: Linking Notes")
	var shown_rx: Array = app.visual_layer.get_children().filter(func(c): return c is RichTextLabel and c.text.contains("[url=Tutorial 1: Writing Notes]") and c.text.contains("the first tutorial"))
	check(shown_rx.size() >= 1, "[[Note|shown text]] renders the shown text as a link")

	# ── Tutorial 3: empty 3d block = galaxy ──
	await open("Tutorial 3: Your First 3D Scene")
	check(cards().size() == 3 and cards()[0].preset == "galaxy" and cards()[1].preset == "knot", "empty block -> galaxy; preset: knot -> knot")

	# ── Tutorial 4: shapes ──
	await open("Tutorial 4: Shapes and Colors")
	var c4: Array = cards()
	check(c4.size() == 4 and c4[0].preset == "shapes" and c4[0]._objects.size() == 3, "cube/sphere/cone block -> shapes scene with 3 objects")
	check(c4.size() == 4 and c4[1]._objects.size() == 8 and c4[1]._objects.all(func(x): return x.label.visible), "all 8 shapes, labels: on shows names")
	check(c4.size() == 4 and c4[2]._objects.size() == 6 and is_equal_approx(c4[2]._objects[3].root.position.z, 1.8), "'at x y z' places shapes")
	if c4.size() == 4:
		var shp: NoteScene3D = c4[0]
		app.doc_scroll.scroll_vertical = int(shp.position.y) - 20
		await frames(2)
		var world: Vector3 = (shp._objects[1].root as Node3D).global_position
		var local: Vector2 = shp._camera.unproject_position(world)
		var hm := InputEventMouseMotion.new()
		hm.position = shp._container.get_global_transform_with_canvas() * local
		hm.global_position = hm.position
		get_root().push_input(hm)
		await frames(2)
		check(shp._hover_obj == 1 and shp._objects[1].label.visible, "hovering a shape shows its name")
		await shot("t4_shapes", shp)
		await shot("t4_all_shapes", c4[1])
		await shot("t4_primaries", c4[2])

	# ── Tutorial 5: shape answers + show: ──
	await open("Tutorial 5: Making a Quiz")
	var c5: Array = cards().filter(func(c): return c._quiz.size() == 7)
	check(c5.size() == 1, "Tutorial 5 has the 7-question Shapes and Colors quiz")
	if c5.size() == 1:
		var qz: NoteScene3D = c5[0]
		check(qz._tiles.size() == 4 and qz._tiles.all(func(t): return t.body is StandardMaterial3D and has_mesh(t.root)), "Q1 answers are 3D shapes on pedestals")
		await shot("t5_q1_shapes", qz)
		await click_tile(qz, qz._quiz[0].correct)
		check(qz._score == 1, "clicking the blue sphere scores")
		await shot("t5_q1_right", qz)
		await click_tile(qz, qz._tiles.find(qz._tiles.filter(func(t): return t.action == "next")[0]))
		check(qz._qi == 1 and qz._quiz_spinners.size() == 1, "Q2 shows a 'show:' prop beside the question")
		await click_tile(qz, 0)
		check(qz._score == 1 and qz._feedback.text.begins_with("Not quite"), "wrong colour answer is marked wrong")
		await shot("t5_q2_wrong", qz)
		var rev: Array = qz._tiles.filter(func(t): return t.action == "open:Tutorial 4: Shapes and Colors")
		check(rev.size() == 1, "Review tile links back to Tutorial 4")
		if rev.size() == 1:
			await click_tile(qz, qz._tiles.find(rev[0]))
			await frames(3)
			check(app.current_note.title == "Tutorial 4: Shapes and Colors", "Review opens Tutorial 4")

	# ── Tutorial 6: model loading ──
	await open("Tutorial 6: Importing 3D Models")
	var c6: Array = cards()
	check(c6.size() == 3, "Tutorial 6 has rocket, mixed scene and quiz")
	if c6.size() == 3:
		var rk: NoteScene3D = c6[0]
		check(rk._objects.size() == 1 and has_mesh(rk._objects[0].root) and rk._objects[0].root.find_children("*", "Label3D", true, false).is_empty(), "rocket.glb loads as a real model")
		check(c6[1]._objects.size() == 3, "model + shapes mix in one scene")
		var mq: NoteScene3D = c6[2]
		check(mq._tiles.size() == 4 and has_mesh(mq._tiles[1].root), "quiz answer 'model rocket.glb' is the 3D rocket")
		await shot("t6_rocket", rk)
		await shot("t6_mixed", c6[1])
		await shot("t6_quiz", mq)
		await click_tile(mq, 1)
		check(mq._score == 1, "clicking the rocket answers correctly")

	# Missing model -> friendly placeholder
	var missing := NoteScene3D.new({"_lines": PackedStringArray(["model: nope.glb"])}, 200.0)
	app.visual_layer.add_child(missing)
	await frames(2)
	check(missing._objects.size() == 1 and not missing._objects[0].root.find_children("*", "Label3D", true, false).is_empty(), "missing model shows a 'Model not found' placeholder")
	missing.queue_free()

	# ── Import: palette path + drag-and-drop ──
	app._on_new_note_pressed()
	await frames(2)
	app.title_edit.text = "Zz Import Test"
	app.title_edit.text_submitted.emit(app.title_edit.text)
	await frames(2)
	var tmp: String = OS.get_user_data_dir().path_join("import_src")
	DirAccess.make_dir_recursive_absolute(tmp)
	DirAccess.copy_absolute(NoteScene3D.model_path("rocket.glb"), tmp.path_join("Test Ship.glb"))
	var stored: String = app.import_model_file(tmp.path_join("Test Ship.glb"))
	await frames(4)
	check(stored == "Test Ship.glb" and FileAccess.file_exists(NoteScene3D.model_path(stored)), "import copies the model into vault/models")
	check(app.current_note.raw_text.contains("model: Test Ship.glb, spin") and app.current_mode == "visual", "import inserts a model block and shows it")
	check(cards().size() == 1 and has_mesh(cards()[0]._objects[0].root), "imported model renders")
	if fox != "" and FileAccess.file_exists(fox):
		app._on_files_dropped(PackedStringArray([fox, "/tmp/readme.txt"]))
		await frames(6)
		var fc: Array = cards()
		check(fc.size() == 2 and app.current_note.raw_text.contains("model: Fox.glb"), "drag-and-drop imports Fox.glb (ignores .txt)")
		if fc.size() == 2:
			var players: Array = fc[1]._objects[0].root.find_children("*", "AnimationPlayer", true, false)
			check(players.size() == 1 and players[0].is_playing(), "Fox's animation plays automatically (%s)" % (players[0].current_animation if players.size() else "none"))
			await shot("t6_fox", fc[1])
		DirAccess.remove_absolute(NoteScene3D.model_path("Fox.glb"))
	DirAccess.remove_absolute(NoteScene3D.model_path(stored))
	DirAccess.remove_absolute(tmp.path_join("Test Ship.glb"))
	app._on_delete_note_pressed()
	await frames(2)
	for c in get_root().find_children("*", "ConfirmationDialog", true, false):
		if c.visible:
			c.confirmed.emit()
	await frames(2)
	VaultStore.refresh_note_list()
	check(VaultStore.get_note_index("Zz Import Test") < 0 and VaultStore.get_note_index(ghost) < 0, "test notes cleaned up")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(ProgressStore.file_override))
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)
