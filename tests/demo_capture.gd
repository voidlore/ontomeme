extends SceneTree
## Demo capture harness for the README (needs a display, not --headless):
##   DEMO_OUT=<dir> godot --path . -s res://tests/demo_capture.gd -- --vault=<dir>
## Opens the "3D Scenes" showcase note in Read mode and tours the first three
## cards (galaxy, knot, terrain), saving:
##   - demo.png  a hero still of the first card
##   - demo_f###.png  a continuous frame sequence for the short demo clip
## Rendered by Godot itself, so no OS mouse/keyboard injection is needed.

const FPS := 24
const PER_CARD_SECONDS := 2.5

func _init() -> void:
	var out := OS.get_environment("DEMO_OUT")
	if out == "":
		out = OS.get_user_data_dir()
	DisplayServer.window_set_size(Vector2i(1280, 760))
	for i in range(3):
		await process_frame

	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await process_frame
	app.open_note_by_title("3D Scenes")
	app._switch_layer("visual")

	var cards: Array = []
	for c in app.visual_layer.get_children():
		if c is NoteScene3D:
			cards.append(c)
	print("cards: ", cards.size())
	if cards.is_empty():
		print("no 3D cards found; aborting")
		quit()
		await create_timer(3.0).timeout

	var scroll: ScrollContainer = app.doc_scroll
	# Hero still on the first card, fully in view.
	scroll.scroll_vertical = int(cards[0].position.y) - 40
	await create_timer(2.0).timeout
	get_root().get_texture().get_image().save_png(out.path_join("demo.png"))
	print("saved hero demo.png")

	# Frame sequence that tours the first three cards; each card keeps
	# autorotating while we hold on it, then we scroll to the next.
	var per: int = int(FPS * PER_CARD_SECONDS)
	var shown := mini(cards.size(), 3)
	var n := 0
	for c in range(shown):
		scroll.scroll_vertical = int(cards[c].position.y) - 40
		for i in range(per):
			await process_frame
			get_root().get_texture().get_image().save_png(
				out.path_join("demo_f%03d.png" % n))
			n += 1
		print("captured card %d (%s)" % [c, str(cards[c].preset)])
	print("saved %d frames" % n)
	quit()
