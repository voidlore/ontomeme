extends SceneTree
## Screenshot a note the way a reader sees it (needs a display + GPU).
##
##   godot --path . -s res://scripts/snapshot_note.gd -- "<note title>" <out_dir> [--vault=DIR] [--answer]
##
## Saves <out_dir>/<slug>_00_top.png (top of the note in Read view), then one
## PNG per 3D block (<slug>_NN_<preset>.png) scrolled into view, after the
## scene has had a second to settle. With --answer, quizzes are also clicked
## through (correct answer each time) and the results board is captured, and
## each flashcard deck's first card is flipped — proves they are playable.
## Exit code 1 if the note is missing or a 3D block failed to build.

var out: String = ""
var app: Control


func _init() -> void:
	var pos: Array = []
	var answer: bool = false
	for a in OS.get_cmdline_user_args():
		if a == "--answer":
			answer = true
		elif not a.begins_with("--"):
			pos.append(a)
	if pos.size() < 2:
		printerr("usage: godot --path . -s res://scripts/snapshot_note.gd -- \"<note title>\" <out_dir> [--vault=DIR] [--answer]")
		quit(2)
		return
	var title: String = pos[0]
	out = pos[1]
	DirAccess.make_dir_recursive_absolute(out)
	DisplayServer.window_set_size(Vector2i(1280, 860))
	# Never log screenshot runs into the real progress / journey files
	ProgressStore.file_override = "user://snapshot_progress.json"
	JourneyStore.file_override = "user://snapshot_journey.json"
	for i in range(3):
		await process_frame
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await process_frame
	app.open_note_by_title(title)
	if app.current_note == null or app.current_note.title.strip_edges().to_lower() != title.strip_edges().to_lower():
		printerr("no note titled '%s'" % title)
		quit(1)
		return
	app._switch_layer("visual")
	for i in range(10):
		await process_frame
	var slug: String = title.to_lower().replace(" ", "_").replace(":", "").replace("/", "_")
	var scroll: ScrollContainer = app.doc_scroll
	scroll.scroll_vertical = 0
	await _save(slug + "_00_top")
	var n: int = 0
	var bad: int = 0
	for c in app.visual_layer.get_children():
		if not (c is NoteScene3D):
			continue
		n += 1
		var card: NoteScene3D = c
		scroll.scroll_vertical = int(card.position.y) - 30
		await create_timer(1.2).timeout
		var name: String = "%s_%02d_%s" % [slug, n, card.preset]
		await _save(name)
		if card.preset == "quiz" and card._quiz.is_empty():
			print("WARN  block %d: quiz has no valid questions" % n)
			bad += 1
		if not answer:
			continue
		if card.preset == "quiz" and not card._quiz.is_empty():
			for qi in range(card._quiz.size()):
				card._activate(_tile(card, "answer:%d" % card._quiz[qi].correct))
				await create_timer(0.25).timeout
				card._activate(_tile(card, "results" if qi == card._quiz.size() - 1 else "next"))
				await create_timer(0.2).timeout
			await _save(name + "_results")
		elif card.preset == "flashcards" and not card._cards.is_empty():
			card._activate(_tile(card, "flip"))
			await create_timer(0.6).timeout
			await _save(name + "_flipped")
			card.restart()
	print("3D blocks: %d" % n)
	for f in [ProgressStore.file_override, JourneyStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	quit(1 if bad > 0 else 0)


func _tile(card: NoteScene3D, action: String) -> int:
	for i in range(card._tiles.size()):
		if str(card._tiles[i].action) == action:
			return i
	return -1


func _save(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		print("(headless: no image for %s)" % name)
		return
	await create_timer(0.3).timeout
	var path: String = out.path_join(name + ".png")
	get_root().get_texture().get_image().save_png(path)
	print("saved ", path)
