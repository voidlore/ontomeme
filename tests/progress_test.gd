extends SceneTree
## Progress tracking: ✓ / ● marks, review banner, Next lesson, persistence.
##   headless:  godot --headless --path . -s res://tests/progress_test.gd
##   + images:  godot --path . -s res://tests/progress_test.gd -- <out_dir>

const TestVault = preload("res://tests/test_vault.gd")
var fails: int = 0
var out: String = ""
var app: Control
const T1: String = "Tutorial 1: Writing Notes"
const T2: String = "Tutorial 2: Linking Notes"
const START: String = "Start Here: Tutorials"
const TEST_FILE: String = "user://test_progress.json"

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1

func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame

func shot(name: String, y: int = -1) -> void:
	if out == "" or DisplayServer.get_name() == "headless":
		return
	if y >= 0:
		app.doc_scroll.scroll_vertical = y
	await create_timer(1.0).timeout
	get_root().get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("saved ", name)

func open(title: String) -> void:
	app.open_note_by_title(title)
	app._switch_layer("visual")
	await frames(6)

func quiz_cards() -> Array:
	return app.visual_layer.get_children().filter(func(c): return c is NoteScene3D and c.preset == "quiz")

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

func tile(card: NoteScene3D, prefix: String) -> int:
	for i in range(card._tiles.size()):
		if str(card._tiles[i].action).begins_with(prefix):
			return i
	return -1

## Play a whole quiz: answers[i] true = pick the right answer.
func play(card: NoteScene3D, answers: Array) -> void:
	for qi in range(card._quiz.size()):
		var q: Dictionary = card._quiz[qi]
		await click_tile(card, q.correct if answers[qi] else (q.correct + 1) % q.choices.size())
		await click_tile(card, tile(card, "results" if qi == card._quiz.size() - 1 else "next"))

func sidebar_icon(title: String) -> Texture2D:
	for note in app._note_buttons:
		if note.title == title:
			return (app._note_buttons[note] as Button).icon
	return null

func link_line(title: String) -> String:
	for c in app.visual_layer.get_children():
		if c is RichTextLabel and LayerEngine.link_targets(c).has(title):
			return c.text
	return ""

## Files in `dir` whose names match `pattern` (String.match: * and ?).
func files_like(dir: String, pattern: String) -> PackedStringArray:
	var found: PackedStringArray = []
	for f in DirAccess.get_files_at(dir):
		if f.match(pattern):
			found.append(f)
	return found

func write_text(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()

## A progress.json cut off mid-write used to read as empty, and the next
## answer replaced it, losing every quiz score. Now its bytes are kept
## beside it first, and saves never leave half a file.
func check_unreadable_file_kept() -> void:
	const DIR: String = "user://test-progress-unreadable"
	const TRUNCATED: String = '{"quizzes": {"tutorial 1: writing notes#0": {"best": 3, "total": 3, "passed": true, "last": 3}}, "questions": {"tutorial 1: writing notes#0#0": {"right": tr'
	DirAccess.make_dir_recursive_absolute(DIR)
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	var before: String = ProgressStore.file_override
	ProgressStore.file_override = DIR.path_join("progress.json")
	write_text(ProgressStore.file_override, TRUNCATED)
	ProgressStore.invalidate()
	ProgressStore.record_answer(T1, 0, 1, "Which word is bold?", true, T1)
	var kept: PackedStringArray = files_like(DIR, "progress.unreadable-*.json")
	check(kept.size() == 1 and FileAccess.get_file_as_string(DIR.path_join(kept[0])) == TRUNCATED, "a truncated progress.json is kept, byte for byte, as progress.unreadable-<stamp>.json before the next answer is saved (%s)" % [kept])
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(ProgressStore.file_override))
	check(saved is Dictionary and saved.questions.size() == 1, "the next save writes a whole new progress.json")
	check(files_like(DIR, "*.tmp").is_empty(), "no .tmp file is left after a save")
	write_text(ProgressStore.file_override, '{"quizzes": [], "questions": {}}')
	ProgressStore.invalidate()
	check(not ProgressStore.quiz_passed(T1, 0) and files_like(DIR, "progress.unreadable-*.json").size() == 2, "a file of the wrong shape (quizzes: []) is kept too")

	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	DirAccess.remove_absolute(DIR)
	ProgressStore.file_override = before
	ProgressStore.invalidate()

## A progress.json the app can't open (no read permission here; on Windows,
## a sync tool or antivirus holding it) used to read as empty, and the next
## answer renamed a new file over it. Now nothing is saved over it until it
## has been read.
func check_unopenable_file_left_alone() -> void:
	const DIR: String = "user://test-progress-unopenable"
	const MINE: String = '{"quizzes": {"tutorial 1: writing notes#0": {"best": 3, "total": 3, "passed": true, "last": 3}}, "questions": {}}'
	DirAccess.make_dir_recursive_absolute(DIR)
	var before: String = ProgressStore.file_override
	var p: String = DIR.path_join("progress.json")
	ProgressStore.file_override = p
	write_text(p, MINE)
	FileAccess.set_unix_permissions(p, 0)
	if FileAccess.open(p, FileAccess.READ) != null:   # root, or a system without Unix permissions
		print("SKIP  an unopenable progress.json: chmod 000 doesn't stop this user reading it")
	else:
		ProgressStore.invalidate()
		check(ProgressStore.load_error().begins_with("Your quiz progress file couldn't be opened"), "a progress.json that can't be opened sets last_error (%s)" % ProgressStore.last_error)
		ProgressStore.record_answer(T1, 0, 1, "Which word is bold?", true, T1)
		FileAccess.set_unix_permissions(p, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
		check(FileAccess.get_file_as_string(p) == MINE and files_like(DIR, "*.tmp").is_empty(), "after an answer, progress.json still holds its own bytes, and no .tmp was made")
		ProgressStore.invalidate()
		check(ProgressStore.quiz_passed(T1, 0) and ProgressStore.last_error == "", "once it can be read again, the passed quiz is back and the error clears")
	FileAccess.set_unix_permissions(p, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	DirAccess.remove_absolute(DIR)
	ProgressStore.file_override = before
	ProgressStore.invalidate()

## A save that removed progress.json and then couldn't rename progress.tmp
## over it leaves the .tmp as the only copy; the next load puts it back
## instead of starting empty and writing over it.
func check_leftover_tmp_put_back() -> void:
	const DIR: String = "user://test-progress-leftover-tmp"
	const MINE: String = '{"quizzes": {"tutorial 1: writing notes#0": {"best": 3, "total": 3, "passed": true, "last": 3}}, "questions": {}}'
	DirAccess.make_dir_recursive_absolute(DIR)
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	var before: String = ProgressStore.file_override
	ProgressStore.file_override = DIR.path_join("progress.json")
	write_text(DIR.path_join("progress.tmp"), MINE)
	ProgressStore.invalidate()
	ProgressStore.record_answer(T1, 0, 1, "Which word is bold?", true, T1)
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(ProgressStore.file_override))
	check(ProgressStore.quiz_passed(T1, 0) and ProgressStore.last_error == "" and saved is Dictionary and saved.quizzes.size() == 1 and saved.questions.size() == 1 and files_like(DIR, "*.tmp").is_empty(), "with no progress.json, a progress.tmp beside it is put back: its passed quiz survives the next answer (%s)" % [saved])
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	DirAccess.remove_absolute(DIR)
	ProgressStore.file_override = before
	ProgressStore.invalidate()

## Saves write progress.tmp and rename it over progress.json. With
## progress.tmp unwritable (a folder has its name) an answer isn't saved, and
## progress.json keeps its bytes, where an in-place write would replace them.
func check_save_goes_through_tmp() -> void:
	const DIR: String = "user://test-progress-atomic"
	const MINE: String = '{"quizzes": {"tutorial 1: writing notes#0": {"best": 3, "total": 3, "passed": true, "last": 3}}, "questions": {}}'
	DirAccess.make_dir_recursive_absolute(DIR)
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	var before: String = ProgressStore.file_override
	ProgressStore.file_override = DIR.path_join("progress.json")
	var tmp: String = DIR.path_join("progress.tmp")
	write_text(ProgressStore.file_override, MINE)
	DirAccess.make_dir_absolute(tmp)
	ProgressStore.invalidate()
	ProgressStore.record_answer(T1, 0, 1, "Which word is bold?", true, T1)
	check(FileAccess.get_file_as_string(ProgressStore.file_override) == MINE, "with progress.tmp unwritable, an answer leaves progress.json's bytes as they were")
	DirAccess.remove_absolute(tmp)
	ProgressStore.record_answer(T1, 0, 2, "Which word is italic?", true, T1)
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(ProgressStore.file_override))
	check(saved is Dictionary and saved.questions.size() == 2 and files_like(DIR, "*.tmp").is_empty() and not DirAccess.dir_exists_absolute(tmp), "once it can be written, the next answer saves both, and no .tmp is left")
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	DirAccess.remove_absolute(DIR)
	ProgressStore.file_override = before
	ProgressStore.invalidate()

func _init() -> void:
	JourneyStore.file_override = "user://test_journey_progress.json"   # never touch the real journey
	JourneyStore.reset()
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	DisplayServer.window_set_size(Vector2i(1280, 860))
	ProgressStore.file_override = TEST_FILE
	ProgressStore.reset()
	TestVault.open("progress")   # never touch the user's vault

	check(ProgressStore.passes(2, 3) and not ProgressStore.passes(1, 3) and ProgressStore.pass_mark(7) == 5, "pass mark is two thirds (2/3, 5/7)")
	write_text(TEST_FILE, '{"quizzes": {"tutorial 1: writing notes#0": {"be')   # cut off mid-write
	ProgressStore.invalidate()
	await frames(3)
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(2)
	var kept: PackedStringArray = files_like("user://", "test_progress.unreadable-*.json")
	check(kept.size() == 1 and app.status_label.text == "Your quiz progress file couldn't be read; it was kept as %s." % kept[0], "on opening, the status bar says the progress file couldn't be read and names the copy (%s)" % app.status_label.text)
	var t5: int = VaultStore.get_note_index("Tutorial 5: Making a Quiz")
	check(ProgressStore.quiz_count(VaultStore.note_list[t5].raw_text) == 3, "quiz_count finds Tutorial 5's 3 quizzes (ignores ```` examples)")

	# Fresh: no marks
	check(ProgressStore.status(T1) == "" and sidebar_icon(T1) == null, "fresh progress: no marks")

	# Tutorial 1: miss Q1, get Q2 + Q3 -> passes (2/3) but Q1 flags review
	await open(T1)
	var c: NoteScene3D = quiz_cards()[0]
	check(c.params.get("_note") == T1 and c.params.get("_quiz_index") == 0, "quiz card knows its note and index")
	await play(c, [false, true, true])
	check(ProgressStore.quiz_passed(T1, 0), "2 of 3 passes the quiz")
	check(c._quiz_root.get_children().any(func(n): return n is Label3D and n.text.begins_with("PASSED")), "results say PASSED ✓")
	var nxt: int = tile(c, "open:" + T2)
	check(nxt >= 0, "passing shows a Next: Tutorial 2 tile")
	check(ProgressStore.status(T1) == "review", "missed question flags Tutorial 1 for review")
	check(sidebar_icon(T1) == ProgressStore.icon("review"), "sidebar shows ● on Tutorial 1 right away")
	await shot("p1_passed_next", int(c.position.y) - 20)

	# Next tile opens Tutorial 2
	await click_tile(c, nxt)
	await frames(3)
	check(app.current_note.title == T2, "Next tile opens Tutorial 2")

	# Review banner on Tutorial 1
	await open(T1)
	var banners: Array = app.visual_layer.get_children().filter(func(n): return n is PanelContainer and n.theme_type_variation == &"ReviewBanner")
	check(banners.size() == 1 and (banners[0].get_child(0) as RichTextLabel).text.contains("Which line makes a heading?"), "Tutorial 1 shows a review banner naming the missed question")
	await shot("p2_banner", 0)

	# Start Here: link marks
	await open(START)
	check(link_line(T1).contains("●"), "Start Here marks Tutorial 1 with ●")

	# Retake perfectly -> done
	await open(T1)
	c = quiz_cards()[0]
	await play(c, [true, true, true])
	check(ProgressStore.status(T1) == "done", "perfect retake -> Tutorial 1 done")
	check(sidebar_icon(T1) == ProgressStore.icon("done"), "sidebar shows ✓ on Tutorial 1")
	await open(START)
	check(link_line(T1).contains("✓"), "Start Here marks Tutorial 1 with ✓")
	await shot("p_done_start_here", 0)
	await open(T1)
	check(app.visual_layer.get_children().filter(func(n): return n is PanelContainer and n.theme_type_variation == &"ReviewBanner").is_empty(), "review banner gone after answering right")

	# Fail Tutorial 2: no Next, pass mark message
	await open(T2)
	c = quiz_cards()[0]
	await play(c, [true, false, false])
	check(not ProgressStore.quiz_passed(T2, 0) and tile(c, "open:Tutorial 3") == -1, "1 of 3 fails: no Next tile")
	check(c._quiz_root.get_children().any(func(n): return n is Label3D and n.text.begins_with("Get 2 right to pass")), "fail message gives the pass mark")
	check(ProgressStore.status("Tutorial 1: Writing Notes") == "review", "T2's question about bold re-flags Tutorial 1 (learn: across notes)")
	await shot("p3_failed", int(c.position.y) - 20)

	# Cross-note banner points at where it was asked
	await open(T1)
	var b2: Array = app.visual_layer.get_children().filter(func(n): return n is PanelContainer and n.theme_type_variation == &"ReviewBanner")
	check(b2.size() == 1 and LayerEngine.link_targets(b2[0].get_child(0)).has(T2), "banner links to the note where the question was asked")

	await open(START)
	await shot("p4_start_here", 0)

	# Persistence
	ProgressStore.invalidate()
	check(ProgressStore.quiz_passed(T1, 0) and not ProgressStore.quiz_passed(T2, 0) and FileAccess.file_exists(TEST_FILE), "progress survives a reload from disk (%s %s %s)" % [ProgressStore.quiz_passed(T1, 0), ProgressStore.quiz_passed(T2, 0), FileAccess.file_exists(TEST_FILE)])

	# Reset via palette command
	app._execute_command("reset_progress")
	await frames(3)
	check(ProgressStore.status(T1) == "" and sidebar_icon(T1) == null, "Reset quiz progress clears marks")

	check_unreadable_file_kept()
	check_unopenable_file_left_alone()
	check_leftover_tmp_put_back()
	check_save_goes_through_tmp()

	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_FILE))
	for f in files_like("user://", "test_progress.unreadable-*.json"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + f))
	ProgressStore.file_override = ""
	ProgressStore.invalidate()
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)
