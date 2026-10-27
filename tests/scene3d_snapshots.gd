extends SceneTree
## Renders each ```3d card of the "3D Scenes" note to PNG (needs a display).
##   godot --path . -s res://tests/scene3d_snapshots.gd -- <out_dir>
func _init() -> void:
	var out: String = OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else OS.get_user_data_dir()
	DisplayServer.window_set_size(Vector2i(1280, 800))
	for i in range(3):
		await process_frame
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await process_frame
	app.open_note_by_title("3D Scenes")
	app._switch_layer("visual")
	for i in range(20):
		await process_frame
	var cards: Array = []
	for c in app.visual_layer.get_children():
		if c is NoteScene3D:
			cards.append(c)
	print("cards: ", cards.size())
	var scroll: ScrollContainer = app.doc_scroll
	for card in cards:
		scroll.scroll_vertical = int(card.position.y) - 40
		await create_timer(1.2).timeout
		var img: Image = get_root().get_texture().get_image()
		img.save_png(out.path_join("scene_%s.png" % card.preset))
		print("saved ", card.preset)
	# expanded overlay
	cards[0].get_child(0).get_child(1).get_child(0).get_child(2).pressed.emit()
	await create_timer(1.0).timeout
	get_root().get_texture().get_image().save_png(out.path_join("scene_expanded.png"))
	print("saved expanded, overlay=", app._scene_overlay != null)
	quit()
