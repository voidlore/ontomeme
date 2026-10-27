extends SceneTree
## Folders mirrored on disk + vault switching, in a throwaway vault.
##   headless:  godot --headless --path . -s res://tests/folders_test.gd
##   + images:  godot --path . -s res://tests/folders_test.gd -- <out_dir>

var fails: int = 0
var out: String = ""
var app: Control
var V: String
var V2: String

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
	await create_timer(0.8).timeout
	get_root().get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("saved ", name)

func note(title: String) -> ContentLayer:
	var i: int = VaultStore.get_note_index(title)
	return VaultStore.note_list[i] if i >= 0 else null

func row_texts() -> Array:
	return app.note_list_container.get_children().map(func(b): return b.text.strip_edges())

func click(ctrl: Control) -> void:
	var pos: Vector2 = ctrl.get_global_rect().get_center()
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

func write_note_file(path: String, title: String, text: String) -> void:
	var n := ContentLayer.new()
	n.title = title
	n.raw_text = text
	n.created = Time.get_datetime_string_from_system()
	n.modified = n.created
	ResourceSaver.save(n, path)

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	DisplayServer.window_set_size(Vector2i(1280, 820))
	JourneyStore.file_override = "user://test_journey_folders.json"
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	V = ProjectSettings.globalize_path("user://folders-test-vault/")
	V2 = ProjectSettings.globalize_path("user://folders-test-vault-2/")
	for d in [V, V2]:
		OS.execute("rm", ["-rf", d])
		DirAccess.make_dir_recursive_absolute(d)
	await frames(2)
	VaultStore.open_vault(V, false)
	var a: ContentLayer = VaultStore.create_note("Alpha")
	a.raw_text = "Top-level note. See [[Wave Basics]]."
	VaultStore.save_note(a)

	# ── Store: folders are real directories ──
	var phys: String = VaultStore.create_folder("Physics")
	var waves: String = VaultStore.create_folder("Waves", phys)
	check(phys == "Physics" and waves == "Physics/Waves" and DirAccess.dir_exists_absolute(V + "Physics/Waves"), "create_folder makes real nested directories")
	check(VaultStore.create_folder("Physics") == "Physics 2", "duplicate folder names get a number")
	DirAccess.remove_absolute(V + "Physics 2")
	var w: ContentLayer = VaultStore.create_note("Wave Basics", waves)
	w.raw_text = "Waves carry energy."
	VaultStore.save_note(w)
	check(w.resource_path.begins_with(V + "Physics/Waves/") and VaultStore.folder_of(w) == "Physics/Waves", "create_note(title, folder) saves inside the folder")
	check(VaultStore.move_note(a, "Physics") and FileAccess.file_exists(a.resource_path) and VaultStore.folder_of(a) == "Physics", "move_note moves the file on disk")
	check(DirAccess.get_files_at(V).size() == 0, "nothing left behind at the top level")
	VaultStore.move_note(a, "")
	var before: ContentLayer = w
	var nr: String = VaultStore.rename_folder("Physics", "Science")
	check(nr == "Science" and DirAccess.dir_exists_absolute(V + "Science/Waves") and not DirAccess.dir_exists_absolute(V + "Physics"), "rename_folder renames on disk")
	check(note("Wave Basics") == before and before.resource_path == V + "Science/Waves/" + before.resource_path.get_file(), "notes inside keep their identity and follow the folder")
	check(VaultStore.move_folder("Science", "Science/Waves/Science") == "", "can't move a folder into itself")
	DirAccess.make_dir_recursive_absolute(V + ".ontomeme")
	DirAccess.make_dir_recursive_absolute(V + "models")
	VaultStore.refresh_note_list()
	check(not VaultStore.folders.has(".ontomeme") and not VaultStore.folders.has("models"), "hidden + models folders are not note folders")

	# ── UI ──
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	check(get_root().get_window().title == "Ontomeme" and app._vault_btn.text.strip_edges() == "folders-test-vault", "window is Ontomeme; vault button shows the vault name")
	var rows: Array = row_texts()
	check(rows == ["Science", "Waves", "Wave Basics", "Alpha"], "sidebar: folders, nested folder, its note, then top-level notes %s" % str(rows))
	var waves_btn: Button = app._folder_buttons.get("Science/Waves")
	var wave_btn: Button = app._note_buttons.get(w)
	check(waves_btn != null and wave_btn != null and wave_btn.get_theme_stylebox("normal").content_margin_left > waves_btn.get_theme_stylebox("normal").content_margin_left, "nested rows are indented deeper")
	await click(app._note_buttons[w])
	check(app.current_note == w and app.breadcrumb.text == "folders-test-vault  /  Science  /  Waves  /  Wave Basics", "breadcrumb shows the folder path")
	await click(app._folder_buttons["Science"])
	check(row_texts() == ["Science", "Alpha"], "clicking a folder collapses it")
	check(FileAccess.get_file_as_string(VaultStore.data_dir().path_join("ui.json")).contains("Science"), "collapsed state is saved in the vault")
	await click(app._folder_buttons["Science"])
	check(row_texts().size() == 4, "clicking again expands it")

	# Drag and drop (the same callbacks Godot's drag forwarding calls)
	check(not app._can_drop({"type": "folder", "rel": "Science"}, "Science/Waves"), "drop rules: no folder into its own child")
	check(app._can_drop({"type": "note", "note": a}, "Science/Waves") and not app._can_drop({"type": "note", "note": a}, ""), "drop rules: note can move, but not to where it already is")
	app._drop({"type": "note", "note": a}, "Science/Waves")
	await frames(2)
	check(VaultStore.folder_of(a) == "Science/Waves" and row_texts() == ["Science", "Waves", "Alpha", "Wave Basics"], "dropping a note on a folder moves it %s" % str(row_texts()))
	app._drop({"type": "folder", "rel": "Science/Waves"}, "")
	await frames(2)
	check(DirAccess.dir_exists_absolute(V + "Waves") and VaultStore.folder_of(w) == "Waves", "dropping a folder on the NOTES header moves it to the top level")

	# Right-click menu → New note here
	var waves_row: Button = app._folder_buttons["Waves"]
	var rc := InputEventMouseButton.new()
	rc.button_index = MOUSE_BUTTON_RIGHT
	rc.pressed = true
	rc.position = waves_row.get_global_rect().get_center()
	rc.global_position = rc.position
	get_root().push_input(rc)
	await frames(2)
	check(app._ctx_menu.visible and app._ctx_menu.get_item_text(0) == "New note here", "right-clicking a folder opens its menu")
	app._ctx_menu.id_pressed.emit(0)
	app._ctx_menu.hide()
	await frames(2)
	check(VaultStore.folder_of(app.current_note) == "Waves" and app.current_mode == "raw", "New note here creates the note inside the folder")
	app._on_delete_note_pressed()
	await frames(2)
	await shot("f1_sidebar")

	# ── Outside changes mirror in ──
	DirAccess.make_dir_recursive_absolute(V + "Chemistry")
	write_note_file(V + "Chemistry/note_atoms.tres", "Atoms", "Everything is made of atoms.")
	app.check_disk_changes()
	await frames(2)
	check(VaultStore.folders.has("Chemistry") and note("Atoms") != null and app._folder_buttons.has("Chemistry"), "a folder + note made in the file manager appear")
	await click(app._note_buttons[note("Atoms")])
	app._switch_layer("visual")
	await frames(2)
	await create_timer(1.1).timeout   # mtime resolution is 1s
	write_note_file(note("Atoms").resource_path, "Atoms", "Edited outside: atoms have a nucleus.")
	app.check_disk_changes()
	await frames(3)
	check(app.current_note.raw_text.contains("nucleus") and app.raw_text_layer.text.contains("nucleus"), "an outside edit to the open note shows up")
	OS.execute("mv", [V + "Chemistry", V + "Chem"])
	app.check_disk_changes()
	await frames(3)
	check(app._folder_buttons.has("Chem") and not app._folder_buttons.has("Chemistry") and app.current_note != null and app.current_note.title == "Atoms", "folder renamed outside: sidebar follows, note stays open")
	OS.execute("rm", ["-rf", V + "Chem"])
	app.check_disk_changes()
	await frames(3)
	check(note("Atoms") == null and app.current_note != null and app.current_note.title != "Atoms", "folder deleted outside: its notes go, another note opens")

	app.delete_folder("Waves")
	await frames(2)
	check(not DirAccess.dir_exists_absolute(V + "Waves") and note("Wave Basics") == null, "delete folder moves it (and its notes) to the trash")

	# ── Vaults ──
	write_note_file(V2 + "note_other.tres", "Other Vault Note", "Hello from vault two.")
	app.switch_vault(V2)
	await frames(3)
	check(VaultStore.vault_path == V2 and app.current_note != null and app.current_note.title == "Other Vault Note" and app._vault_btn.text.strip_edges() == "folders-test-vault-2", "switch_vault opens the other folder")
	check(VaultRegistry.recent()[0] == V2, "switched vault goes to the top of the recent list")
	app._show_vault_menu()
	await frames(1)
	check(app._vault_menu.item_count >= 4 and app._vault_menu.get_item_text(app._vault_menu.item_count - 2) == "Open folder as vault…", "vault menu lists recent vaults + Open folder")
	app._vault_menu.hide()
	await shot("f2_vault_menu")
	app.switch_vault(V)
	await frames(2)
	check(VaultStore.vault_path == V and app._vault_btn.text.strip_edges() == "folders-test-vault" and note("Other Vault Note") == null, "switch back")

	# Restore the real vault list
	if registry_backup != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	for d in [V, V2]:
		OS.execute("rm", ["-rf", d])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(JourneyStore.file_override))
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)
