extends SceneTree
## First run: a new default vault is seeded with the tutorials and the memetics
## course and the app opens on the tutorials; an existing vault is left alone;
## an uncreatable vault falls back with a readable message.
##   headless:  godot --headless --path . -s res://tests/first_run_test.gd
##   + images:  godot --path . -s res://tests/first_run_test.gd -- <out_dir>

const TestVault = preload("res://tests/test_vault.gd")
const StarterContent = preload("res://starter_content.gd")

var fails: int = 0
var out: String = ""


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_first_run.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_first_run.json"   # never touch real progress
	ProgressStore.reset()
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	DisplayServer.window_set_size(Vector2i(1280, 860))
	await frames(2)

	# Stands in for ~/Documents/Ontomeme, which a test must never create
	var fake_default: String = ProjectSettings.globalize_path("user://test-vault-first-run/")
	var fallback: String = ProjectSettings.globalize_path("user://test-vault-first-run-fallback/")
	TestVault.remove_tree(fake_default)
	TestVault.remove_tree(fallback)

	check(StarterContent.is_first_run(fake_default, fake_default), "missing default vault = first run")
	check(not StarterContent.is_first_run(fake_default, fake_default + "other/"), "another vault is never a first run")

	# First launch: create and seed
	VaultStore.open_startup_vault(fake_default, fake_default, false)
	var n: int = VaultStore.note_list.size()
	check(VaultStore.first_run and VaultStore.startup_warning == "", "first launch is a first run, no warning")
	check(VaultStore.get_note_index("Start Here: Tutorials") >= 0 and VaultStore.get_note_index("Tutorial 7: Learning Objectives") >= 0, "tutorials are seeded")
	check(VaultStore.get_note_index("History of Memetics") >= 0 and VaultStore.get_note_index("The Memetics Debate") >= 0, "memetics course is seeded")
	check(VaultStore.get_note_index("Nodes and Scenes") >= 0 and VaultStore.get_note_index("Quiz: Godot Fundamentals") >= 0, "Godot Fundamentals course is seeded")
	check(VaultStore.get_note_index("Quiz: Ontomeme") < 0, "the app-internals quiz (test-only) is not shipped")
	check(VaultStore.folders.has("Tutorials") and VaultStore.folders.has("Memetics") and VaultStore.folders.has("Godot"), "filed in Tutorials, Godot and Memetics folders (%s)" % [VaultStore.folders])
	check(VaultStore.folder_of(VaultStore.note_list[VaultStore.get_note_index("Signals")]) == "Godot", "Godot lessons are in the Godot folder")
	var godot_order: Array = VaultStore.note_list.filter(func(n): return VaultStore.folder_of(n) == "Godot").map(func(n): return n.title)
	check(godot_order == ["Nodes and Scenes", "Signals", "Shaders", "Containers and Layout", "Quiz: Godot Fundamentals"], "Godot lessons are listed in teaching order (%s)" % [godot_order])
	check(VaultStore.folder_of(VaultStore.note_list[VaultStore.get_note_index("History of Memetics")]) == "Memetics", "memetics lessons are in the Memetics folder")
	check(FileAccess.file_exists(fake_default.path_join("models/rocket.glb")), "sample rocket.glb is written")
	check(not JourneyStore.topics().is_empty(), "the Learning Journey has a starter topic")

	# Seeding goes through save_note, so editing a seeded note is not a conflict
	var t1: ContentLayer = VaultStore.note_list[VaultStore.get_note_index("Tutorial 1: Writing Notes")]
	t1.raw_text += "\nMy first edit."
	VaultStore.save_note(t1)
	check(VaultStore.last_conflict_copy == null, "editing a seeded tutorial right after first run is not a conflict")

	# The app opens on the tutorials
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(6)
	check(app.current_note != null and app.current_note.title == "Start Here: Tutorials", "first run opens Start Here: Tutorials (%s)" % (app.current_note.title if app.current_note else "none"))
	check(LayerEngine.current_mode == "visual", "…in the Read view (%s)" % LayerEngine.current_mode)
	check(app._collapsed.has("Godot") and app._collapsed.has("Memetics") and not app._collapsed.has("Tutorials"), "the courses start folded, Tutorials open")
	check(app.status_label.text.begins_with("Welcome"), "status bar welcomes the user (%s)" % app.status_label.text)
	if out != "" and DisplayServer.get_name() != "headless":
		await create_timer(1.5).timeout
		get_root().get_texture().get_image().save_png(out.path_join("first_run.png"))
		print("saved first_run")
	app._execute_command("about")
	await frames(2)
	var about: AcceptDialog = null
	for c in app.get_children():
		if c is AcceptDialog and c.title == "About Ontomeme":
			about = c
	check(about != null and about.dialog_text.contains(VaultStore.vault_path), "About shows the version and the notes folder")
	app.queue_free()
	await frames(2)

	# Second launch: the vault exists, nothing is re-seeded
	VaultStore.open_startup_vault(fake_default, fake_default, false)
	check(not VaultStore.first_run and VaultStore.note_list.size() == n, "second launch is not a first run and adds nothing (%d notes)" % VaultStore.note_list.size())

	# A seeded vault the user emptied stays empty (the marker remembers)
	check(FileAccess.file_exists(fake_default.path_join(StarterContent.MARKER)), "seeding leaves a marker")

	# An earlier launch made the folder but was interrupted: still a first run
	TestVault.remove_tree(fake_default)
	DirAccess.make_dir_recursive_absolute(fake_default.path_join(".ontomeme"))
	check(StarterContent.is_first_run(fake_default, fake_default), "an empty, never-seeded default vault is a first run")
	VaultStore.open_startup_vault(fake_default, fake_default, false)
	check(VaultStore.first_run and VaultStore.get_note_index("Start Here: Tutorials") >= 0, "…and gets seeded")
	for nt in VaultStore.note_list.duplicate():
		DirAccess.remove_absolute(nt.resource_path)
	check(not StarterContent.is_first_run(fake_default, fake_default), "a seeded vault the user emptied is not re-seeded")

	# Palette: add the starter content to any vault
	var other: String = TestVault.open("first-run-other", false)
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app._execute_command("add_starter")
	await frames(4)
	check(VaultStore.get_note_index("Start Here: Tutorials") >= 0 and VaultStore.get_note_index("History of Memetics") >= 0, "\"Add the tutorials and starter course\" fills an empty vault")
	check(app.current_note != null and app.current_note.title == "Start Here: Tutorials", "…and opens Start Here")
	app.queue_free()
	await frames(2)
	TestVault.remove_tree(other)

	# A vault folder that cannot be created falls back, and says so
	VaultStore.open_startup_vault("/proc/ontomeme-cannot-exist/", "/proc/ontomeme-cannot-exist/", false, fallback)
	check(VaultStore.vault_path == VaultRegistry.normalize(fallback), "uncreatable vault falls back (%s)" % VaultStore.vault_path)
	check(VaultStore.startup_warning.contains("Couldn't create"), "…with a readable warning")
	check(VaultStore.first_run and VaultStore.get_note_index("Start Here: Tutorials") >= 0, "…and the fallback vault is seeded")

	TestVault.remove_tree(fake_default)
	TestVault.remove_tree(fallback)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
