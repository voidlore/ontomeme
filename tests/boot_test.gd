extends SceneTree
## Boot: every app script compiles, and the main window builds its sidebar
## against an empty vault and a seeded one. The gate for "the app won't start".
##   headless:  godot --headless --path . -s res://tests/boot_test.gd

const TestVault = preload("res://tests/test_vault.gd")

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func boot() -> Control:
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	return app


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_boot.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_boot.json"   # never touch real progress
	ProgressStore.reset()

	# Every script in the project root and scripts/ parses and type-checks
	var broken: Array[String] = []
	for dir in ["res://", "res://scripts/"]:
		for f in DirAccess.get_files_at(dir):
			if f.get_extension() == "gd":
				var s: Script = load(dir.path_join(f))
				if s == null or not s.can_instantiate():
					broken.append(f)
	check(broken.is_empty(), "every app script compiles %s" % [broken])

	# Empty vault: the window builds and offers the empty state
	TestVault.open("boot-empty", false)
	var app: Control = await boot()
	check(app.is_node_ready() and app.note_list_container != null, "main window is ready on an empty vault")
	check(VaultStore.note_list.is_empty() and app.note_count_label.text == "0", "empty vault shows 0 notes (%s)" % app.note_count_label.text)
	check(app.empty_state_panel.visible, "empty vault shows the empty state")
	app.queue_free()
	await frames(2)

	# Seeded vault: folders and notes reach the sidebar, a note opens and renders
	TestVault.open("boot-seeded")
	app = await boot()
	var n: int = VaultStore.note_list.size()
	check(n > 10 and app.note_count_label.text == str(n), "sidebar counts the seeded notes (%s of %d)" % [app.note_count_label.text, n])
	check(app._folder_buttons.has("Tutorials"), "the Tutorials folder is in the sidebar")
	check(not app._note_buttons.is_empty(), "note rows are built")
	app.open_note_by_title("Tutorial 1: Writing Notes")
	app._switch_layer("visual")
	await frames(6)
	check(app.current_note != null and app.current_note.title == "Tutorial 1: Writing Notes", "a note opens")
	check(app.visual_layer.get_child_count() > 0, "Read view renders the note (%d nodes)" % app.visual_layer.get_child_count())
	app.queue_free()
	await frames(2)

	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
