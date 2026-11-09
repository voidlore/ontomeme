extends SceneTree
## Dropping files on the window imports them: .md files (with their front
## matter), folders of notes and single .tres notes go into the open note's
## folder and the first one opens; a 3D model still goes into the open note
## as a ```3d block. One status line counts it all. Also "Import notes from
## a folder…" (_on_import_dir_selected) through the app, and an outside edit
## of the open note that the import's rescan reloads before the watcher sees it.
##   godot --headless --path . -s res://tests/drop_import_test.gd

const TestVault = preload("res://tests/test_vault.gd")
var fails: int = 0
var app: Control
var src: String = ""
var vault: String = ""


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


## A note file the way Godot writes one.
func write_note(path: String, title: String, text: String) -> void:
	write(path, ("[gd_resource type=\"Resource\" script_class=\"ContentLayer\" format=3]\n\n"
		+ "[ext_resource type=\"Script\" path=\"res://ContentLayer.gd\" id=\"1_cl\"]\n\n"
		+ "[resource]\nscript = ExtResource(\"1_cl\")\ntitle = %s\ncreated = \"2026-01-02T03:04:05\"\n"
		+ "modified = \"2026-01-02T03:04:05\"\nraw_text = %s\n") % [JSON.stringify(title), JSON.stringify(text)])


## A real .glb (one box), so showing the inserted block logs no errors.
func glb_bytes() -> PackedByteArray:
	var root := Node3D.new()
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	root.add_child(box)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(root, state)
	var bytes: PackedByteArray = doc.generate_buffer(state)
	root.free()
	return bytes


func note_titled(title: String) -> ContentLayer:
	var i: int = VaultStore.get_note_index(title)
	return VaultStore.note_list[i] if i >= 0 else null


func status() -> String:
	return str(app.status_label.text)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_drop_import.json"   # never touch the real journey
	ProgressStore.file_override = "user://test_progress_drop_import.json"
	JourneyStore.reset()
	ProgressStore.reset()
	src = ProjectSettings.globalize_path("user://test-drop-import-src")
	TestVault.remove_tree(src)
	vault = TestVault.open("drop_import", false)
	var host: ContentLayer = VaultStore.create_note("Host", "Lessons")
	host.raw_text = "The open note."
	VaultStore.save_note(host)
	await frames(1)
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(3)
	app._open_note(host)
	await frames(1)

	await drop_markdown_folder_and_model(host)
	await drop_single_note_and_other()
	await drop_again_and_from_the_vault()
	await import_from_the_dialog()
	await outside_edit_during_import()

	TestVault.remove_tree(src)
	for s in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(s))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)


func drop_markdown_folder_and_model(host: ContentLayer) -> void:
	write(src.path_join("a.md"), "---\ntags: x, y\ntopic: Drops\nobjective: Catch a drop | learning\n---\n# A\n\nDropped in.\n")
	write_note(src.path_join("folder/bee.tres"), "Bee", "a bee")
	write_note(src.path_join("folder/Sub/sea.tres"), "Sea", "the sea")
	write_note(src.path_join("folder/.hidden/no.tres"), "Hidden", "not imported")
	write(src.path_join("model.glb"), "")
	FileAccess.open(src.path_join("model.glb"), FileAccess.WRITE).store_buffer(glb_bytes())
	app._on_files_dropped(PackedStringArray([src.path_join("a.md"), src.path_join("folder"), src.path_join("model.glb")]))
	await frames(2)
	var a: ContentLayer = note_titled("a")
	check(a != null and Array(a.tags) == ["x", "y"] and VaultStore.folder_of(a) == "Lessons", "a.md becomes a note tagged x, y in the open note's folder")
	check(not JourneyStore.find_objective_by_name("Catch a drop").is_empty(), "a.md's front matter creates its objective")
	var bee: ContentLayer = note_titled("Bee")
	var sea: ContentLayer = note_titled("Sea")
	check(bee != null and VaultStore.folder_of(bee) == "Lessons" and sea != null and VaultStore.folder_of(sea) == "Lessons/Sub", "the folder's notes appear under the current folder, subfolders kept")
	check(note_titled("Hidden") == null, "a dot-folder inside it is skipped")
	check(host.raw_text.contains("```3d") and host.raw_text.contains("model: model.glb"), "the model still inserts a ```3d block into the open note")
	check(FileAccess.file_exists(vault.path_join("models/model.glb")), "the model is copied into models/")
	check(app.current_note in [a, bee, sea], "the first imported note opens (%s)" % (app.current_note.title if app.current_note else "none"))
	var line: String = status()
	check(line.contains("Imported 3D model: model.glb") and line.contains("Imported 3 notes (1 from Markdown)") and line.contains("1 new folder"), "the status counts the model, the notes and the folder (%s)" % line)
	check(app.note_list_container.get_child_count() > 0 and app._last_sig == VaultStore.disk_signature(), "the sidebar is refreshed and the disk watcher already knows the new files")


func drop_single_note_and_other() -> void:
	write_note(src.path_join("single.tres"), "Single", "one note file")
	write(src.path_join("readme.txt"), "not a note")
	var folder: String = VaultStore.folder_of(app.current_note)
	app._on_files_dropped(PackedStringArray([src.path_join("single.tres"), src.path_join("readme.txt")]))
	await frames(2)
	var single: ContentLayer = note_titled("Single")
	check(single != null and VaultStore.folder_of(single) == folder and app.current_note == single, "a dropped .tres is imported into the open note's folder and opens")
	check(status().contains("Imported 1 note") and status().contains("1 file left out"), "the status counts it and the file it left out (%s)" % status())


func drop_again_and_from_the_vault() -> void:
	var count: int = VaultStore.note_list.size()
	app._on_files_dropped(PackedStringArray([src.path_join("a.md"), src.path_join("folder")]))
	await frames(2)
	check(VaultStore.note_list.size() == count and note_titled("a (2)") == null and status().contains("3 notes already here"), "dropping the same files again adds nothing (%s)" % status())
	write_note(src.path_join("other/bee.tres"), "bee", "another bee")
	app._on_files_dropped(PackedStringArray([src.path_join("other")]))
	await frames(2)
	check(note_titled("bee (2)") != null and status().contains("1 renamed"), "a different note with a taken title comes in as '<title> (2)' (%s)" % status())
	count = VaultStore.note_list.size()
	app._on_files_dropped(PackedStringArray([vault.path_join("Lessons")]))
	await frames(2)
	check(VaultStore.note_list.size() == count and status().contains("is already in this vault"), "a folder of the vault itself is refused (%s)" % status())


func import_from_the_dialog() -> void:
	var exp: String = src.path_join("exported")
	write_note(exp.path_join("note_top.tres"), "Top", "top")
	write_note(exp.path_join("Physics/note_waves.tres"), "Waves", "waves")
	write(exp.path_join("assets/red.tres"), "[gd_resource type=\"StandardMaterial3D\" format=3]\n\n[resource]\nalbedo_color = Color(1, 0, 0, 1)\n")
	var r: Dictionary = app._on_import_dir_selected(exp)
	await frames(2)
	var top: ContentLayer = note_titled("Top")
	var waves: ContentLayer = note_titled("Waves")
	check(top != null and VaultStore.folder_of(top) == "" and waves != null and VaultStore.folder_of(waves) == "Physics", "Import notes from a folder… brings notes into the vault's top, in their folders")
	check(not FileAccess.file_exists(vault.path_join("assets/red.tres")) and r.invalid == 1, "a .tres that isn't a note is left out")
	check(status().begins_with("Imported 2 notes") and status().contains("1 file that isn't a note"), "it shows a one-line summary (%s)" % status())


## An outside edit of the open note lands after the watcher's last poll, then
## an import runs: its rescan reloads the note under the editor (and takes its
## hash), so the import must leave the edit for the watcher, not mark the disk
## as seen. The editor then shows the edit, and the next save keeps it.
func outside_edit_during_import() -> void:
	write_note(src.path_join("fresh/note_fresh.tres"), "Fresh", "fresh")
	app._watch_timer.stop()
	for how in ["dialog", "drop"]:
		var note: ContentLayer = VaultStore.create_note("Open " + how)
		note.raw_text = "original"
		VaultStore.save_note(note)
		app._refresh_note_list()
		app._open_note(note)
		app.check_disk_changes()   # the watcher has seen everything so far
		await create_timer(1.2).timeout   # mtimes are per second
		write_note(note.resource_path, note.title, "OUTSIDE EDIT")
		if how == "dialog":
			app._on_import_dir_selected(src.path_join("fresh"))
		else:   # all of it already here, so nothing new opens
			app._on_files_dropped(PackedStringArray([src.path_join("fresh")]))
		await frames(2)
		app.check_disk_changes()
		check(app.current_note != null and app.current_note.title == note.title and app.raw_text_layer.text == "OUTSIDE EDIT", "%s: the editor shows the outside edit after the import (%s)" % [how, app.raw_text_layer.text])
		app.raw_text_layer.text += " + typed"
		app._do_auto_save()
		var kept: bool = FileAccess.get_file_as_string(note.resource_path).contains("OUTSIDE EDIT")
		var copy: bool = VaultStore.get_note_index(note.title + " (conflict copy)") >= 0
		check(kept or copy, "%s: the next save keeps the outside edit (in place: %s, conflict copy: %s)" % [how, kept, copy])
	app._watch_timer.start()
