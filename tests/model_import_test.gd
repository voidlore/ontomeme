extends SceneTree
## 3D model import: each .gltf gets its own folder in models/ with its
## sidecars, no sidecar path may leave that folder, and a failed copy
## inserts nothing.
##   godot --headless --path . -s res://tests/model_import_test.gd

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


## A real 1x1 PNG, so rendering the imported model logs no decode errors.
func png_bytes() -> PackedByteArray:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.ORANGE)
	return img.save_png_to_buffer()


## A minimal .gltf whose one buffer is `bin_uri`, plus optional image uris.
func write_gltf(path: String, bin_uri: String, images: Array = []) -> void:
	var doc: Dictionary = {"asset": {"version": "2.0"}, "buffers": [{"uri": bin_uri, "byteLength": 4}]}
	if not images.is_empty():
		doc["images"] = images.map(func(u): return {"uri": u})
	write(path, JSON.stringify(doc, "\t"))


## What the buffer of an imported .gltf reads, resolved the way a glTF
## loader does: its uri relative to the stored .gltf.
func buffer_of(stored: String) -> String:
	var gltf: String = NoteScene3D.model_path(stored)
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(gltf))
	if not doc is Dictionary or (doc as Dictionary).get("buffers", []).is_empty():
		return "<no gltf at %s>" % gltf
	var uri: String = str(doc.buffers[0].uri).uri_decode()
	return FileAccess.get_file_as_string(gltf.get_base_dir().path_join(uri))


## Files under `root` (hidden ones too), relative.
func tree(root: String, rel: String = "") -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(root.path_join(rel))
	if dir == null:
		return out
	dir.include_hidden = true
	for d in dir.get_directories():
		out.append_array(tree(root, rel.path_join(d)))
	for f in dir.get_files():
		out.append(rel.path_join(f))
	return out


func blocks() -> int:
	return app.current_note.raw_text.count("```3d") if app.current_note != null else 0


## chmod 000; false when this process can read it anyway (root).
func lock(path: String) -> bool:
	FileAccess.set_unix_permissions(path, 0)
	return FileAccess.open(path, FileAccess.READ) == null


func unlock(path: String) -> void:
	FileAccess.set_unix_permissions(path, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_model_import.json"   # never touch the real journey
	ProgressStore.file_override = "user://test_progress_model_import.json"
	JourneyStore.reset()
	ProgressStore.reset()
	src = ProjectSettings.globalize_path("user://test-model-import-src")
	for p in ["u/broken.glb", "u/locked.gltf", "u2/model.bin"]:
		unlock(src.path_join(p))   # a crashed run left them locked
	TestVault.remove_tree(src)
	vault = TestVault.open("model_import", false)
	var outside: String = vault.path_join("../escaped.txt").simplify_path()
	DirAccess.remove_absolute(outside)   # left by a run before the fix
	await frames(1)
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(3)

	for section in [shared_sidecar_names, subfolders_and_data_uris, missing_sidecar, escaping_uris.bind(outside), unreadable_sources, single_file_models, uri_checks]:
		app._on_new_note_pressed()   # a fresh note per section: each import re-renders only its own blocks
		await frames(2)
		section.call()
		await frames(2)

	TestVault.remove_tree(src)
	DirAccess.remove_absolute(outside)
	for s in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(s))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)


## Blender's default export (untitled.gltf + untitled.bin) imported twice:
## the second must not overwrite the first's buffer.
func shared_sidecar_names() -> void:
	write_gltf(src.path_join("m1/untitled.gltf"), "untitled.bin")
	write(src.path_join("m1/untitled.bin"), "AAAA")
	write_gltf(src.path_join("m2/untitled.gltf"), "untitled.bin")
	write(src.path_join("m2/untitled.bin"), "BBBB")
	var s1: String = app.import_model_file(src.path_join("m1/untitled.gltf"))
	var s2: String = app.import_model_file(src.path_join("m2/untitled.gltf"))
	check(buffer_of(s1) == "AAAA", "the first model's buffer still reads AAAA (%s: %s)" % [s1, buffer_of(s1)])
	check(buffer_of(s2) == "BBBB", "the second model's buffer reads BBBB (%s: %s)" % [s2, buffer_of(s2)])
	check(s1 == "untitled/untitled.gltf" and s2 == "untitled_1/untitled.gltf", "each .gltf gets its own folder: models/<stem>[_n]/ (%s, %s)" % [s1, s2])
	var text: String = app.current_note.raw_text
	check(text.contains("model: untitled/untitled.gltf, spin") and text.contains("model: untitled_1/untitled.gltf, spin"), "the inserted blocks point into those folders")
	check(not FileAccess.file_exists(vault.path_join("models/untitled.bin")), "no sidecar lands flat in models/")
	# A model already in models/ is used where it is, not copied again
	var again: String = app.import_model_file(NoteScene3D.model_path(s1))
	check(again == s1 and not DirAccess.dir_exists_absolute(vault.path_join("models/untitled_2")), "re-importing a model already in models/ reuses it (%s)" % again)


func subfolders_and_data_uris() -> void:
	var png: PackedByteArray = png_bytes()
	write_gltf(src.path_join("m3/robot.gltf"), "robot.bin", ["textures/skin%20tone.png", "data:image/png;base64," + Marshalls.raw_to_base64(png)])
	write(src.path_join("m3/robot.bin"), "CCCC")
	write(src.path_join("m3/textures/skin tone.png"), "")
	FileAccess.open(src.path_join("m3/textures/skin tone.png"), FileAccess.WRITE).store_buffer(png)
	var s: String = app.import_model_file(src.path_join("m3/robot.gltf"))
	check(s == "robot/robot.gltf" and buffer_of(s) == "CCCC", "robot.gltf is stored with its buffer (%s)" % s)
	check(FileAccess.get_file_as_bytes(vault.path_join("models/robot/textures/skin tone.png")) == png, "a texture in a subfolder (uri-encoded) keeps its relative path")
	check(str(app.status_label.text).begins_with("Imported") and not str(app.status_label.text).contains("left out"), "a clean import says Imported (%s)" % app.status_label.text)


## A sidecar that isn't there: reported, and the model is still imported.
func missing_sidecar() -> void:
	write_gltf(src.path_join("m4/lamp.gltf"), "lamp.bin", ["lamp.png"])
	write(src.path_join("m4/lamp.bin"), "DDDD")
	print("EXPECT-ERROR: Can't open file from path '%s'" % vault.path_join("models/lamp/lamp.png"))   # for tests/run_all.sh: rendering it
	var s: String = app.import_model_file(src.path_join("m4/lamp.gltf"))
	var status: String = app.status_label.text
	check(s == "lamp/lamp.gltf" and buffer_of(s) == "DDDD" and status.contains("1 file not found: lamp.png"), "a missing sidecar is reported and the model still imports (%s)" % status)


## A crafted .gltf whose uris point outside its folder writes nothing there.
func escaping_uris(outside: String) -> void:
	write(src.path_join("deep/escaped.txt"), "escaped")
	write_gltf(src.path_join("deep/a/b/evil.gltf"), "../../escaped.txt",
		["/etc/hostname", "C:/Windows/win.ini", "file:///etc/hostname", "http://example.com/x.png", "..\\..\\escaped.txt", "ok/../../escaped.txt"])
	var before: int = blocks()
	# for tests/run_all.sh: rendering the inserted block can't find its buffer
	print("EXPECT-ERROR: glTF: Binary file not found: " + vault.path_join("models/evil/../../escaped.txt"))
	print("EXPECT-ERROR: Condition \"err != OK\" is true. Returning: ERR_PARSE_ERROR")
	print("EXPECT-ERROR: Condition \"err != OK\" is true. Returning: err")
	var s: String = app.import_model_file(src.path_join("deep/a/b/evil.gltf"))
	var status: String = app.status_label.text
	check(not FileAccess.file_exists(outside), "<vault>/../escaped.txt is not created")
	var strays: PackedStringArray = []
	for f in tree(vault):
		if not (f.begins_with("models/") or f.begins_with(".ontomeme/") or f.ends_with(".tres")):
			strays.append(f)
	check(strays.is_empty(), "no file is written outside <vault>/models/ (%s)" % ", ".join(strays))
	var in_models: PackedStringArray = tree(vault.path_join("models/evil"))
	check(s == "evil/evil.gltf" and in_models == PackedStringArray(["evil.gltf"]), "only evil.gltf itself is copied (%s)" % ", ".join(in_models))
	check(status.contains("escaped.txt") and status.contains("left out"), "the status reports the skipped paths (%s)" % status)
	check(blocks() == before + 1, "the model is still inserted")


## Copy failures: "Couldn't import <file>", nothing inserted, nothing left behind.
func unreadable_sources() -> void:
	write(src.path_join("u/broken.glb"), "glb")
	write_gltf(src.path_join("u/locked.gltf"), "locked.bin")
	write(src.path_join("u/locked.bin"), "DDDD")
	write_gltf(src.path_join("u2/model.gltf"), "model.bin")
	write(src.path_join("u2/model.bin"), "EEEE")
	var cases: Array = [["u/broken.glb", "u/broken.glb", "broken.glb"], ["u/locked.gltf", "u/locked.gltf", "locked"], ["u2/model.gltf", "u2/model.bin", "model"]]
	for c in cases:
		if not lock(src.path_join(c[1])):
			print("SKIP  unreadable %s (this user can read a chmod 000 file)" % c[1])
			unlock(src.path_join(c[1]))
			continue
		var before: int = blocks()
		print("EXPECT-ERROR: Failed to open '%s'" % src.path_join(c[1]))   # for tests/run_all.sh: the copy
		var s: String = app.import_model_file(src.path_join(c[0]))
		var status: String = app.status_label.text
		check(s == "" and status.begins_with("Couldn't import"), "unreadable %s: returns '' and says \"%s\"" % [c[1], status])
		check(blocks() == before, "unreadable %s: no ```3d block is inserted" % c[1])
		check(not FileAccess.file_exists(vault.path_join("models").path_join(c[2])) and not DirAccess.dir_exists_absolute(vault.path_join("models").path_join(c[2])), "unreadable %s: nothing is left in models/" % c[1])
		unlock(src.path_join(c[1]))


## .glb and .fbx stay single files in models/.
func single_file_models() -> void:
	write(src.path_join("g/ship.glb"), "glb")
	print("EXPECT-ERROR: glTF: Error parsing .gltf JSON data: Expected 'true', 'false', or 'null', got 'glb'")   # for tests/run_all.sh: rendering it
	var s1: String = app.import_model_file(src.path_join("g/ship.glb"))
	var s2: String = app.import_model_file(src.path_join("g/ship.glb"))
	check(s1 == "ship.glb" and s2 == "ship_1.glb" and FileAccess.file_exists(vault.path_join("models/ship_1.glb")), ".glb files stay single files in models/ (%s, %s)" % [s1, s2])


func uri_checks() -> void:
	var folder: String = vault.path_join("models/x")
	for bad in ["../a.bin", "a/../../b.bin", "/etc/passwd", "C:/x.bin", "c:x.bin", "file:///x", "https://x/y.png", "..\\a.bin", "%2E%2E/a.bin", ""]:
		check(app._sidecar_dest(folder, bad) == "", "unsafe sidecar uri refused: '%s'" % bad)
	check(app._sidecar_dest(folder, "a.bin") == folder.path_join("a.bin"), "a plain sidecar stays in the model's folder")
	check(app._sidecar_dest(folder, "tex/a%20b.png") == folder.path_join("tex/a b.png"), "a uri-encoded subpath is decoded under the model's folder")
	check(app._sidecar_dest(folder, "./tex/a.png") == folder.path_join("tex/a.png"), "./ is allowed")
