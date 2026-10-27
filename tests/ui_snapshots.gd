extends SceneTree
## Visual snapshot harness (needs a display, not --headless):
##   godot --path . -s res://tests/ui_snapshots.gd -- <out_dir>
## Drives the app through every view and saves a PNG of each, rendered
## by Godot itself — no OS mouse/keyboard injection needed.

func shot(app: Control, out: String, name: String) -> void:
	for i in range(8):
		await process_frame
	var img: Image = get_root().get_texture().get_image()
	img.save_png(out.path_join(name + ".png"))
	print("saved ", name)

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else OS.get_user_data_dir()
	DisplayServer.window_set_size(Vector2i(1280, 760))
	for i in range(3):
		await process_frame
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await shot(app, out, "1_edit")
	app._switch_layer("visual")
	await shot(app, out, "2_read")
	app._switch_layer("structured")
	await shot(app, out, "3_outline")
	app._switch_layer("graph")
	await shot(app, out, "4_graph")
	app._switch_layer("raw")
	app._open_palette()
	app._palette_search.text = "n"
	app._on_palette_search_changed("n")
	await shot(app, out, "5_palette")
	app._close_palette()
	app._toggle_theme()
	await shot(app, out, "6_light")
	app._switch_layer("visual")
	await shot(app, out, "7_light_read")
	quit()
