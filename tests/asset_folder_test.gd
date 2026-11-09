extends SceneTree
## A root images/ or models/ holds pictures and 3D models, and no list shows a
## note inside one (VaultStore.ASSET_DIRS), so nothing may put a note there.
## VaultStore.create_folder, rename_folder, move_folder and move_note refuse a
## target inside one and say why in last_refusal; create_note keeps the note
## at the top level instead; the app's folder commands and sidebar drops show
## that reason in the status line; the MCP refuses the folder. A nested
## Physics/images is an ordinary folder. A vault that already has notes in a
## root images/ (from before it was the picture folder) says so when it opens.
## Windows and macOS ignore case, so "Images" is images/ there: every spelling
## of an asset folder's name is refused, on every system, except a folder by
## exactly that name already on disk, which the lists show (a user's own
## "Images"); the hidden-notes warning counts exactly what the lists leave out.
## This file passes on Linux and on a case-insensitive filesystem alike.
##   godot --headless --path . -s res://tests/asset_folder_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const McpProtocol = preload("res://mcp/protocol.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")

var fails: int = 0
var V: String = ""
var app: Control


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func note(title: String) -> ContentLayer:
	var i: int = VaultStore.get_note_index(title)
	return VaultStore.note_list[i] if i >= 0 else null


func save_image(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	img.save_png(path)


func write_note_file(path: String, title: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var n := ContentLayer.new()
	n.title = title
	n.raw_text = "Written before images/ was the picture folder."
	n.created = Time.get_datetime_string_from_system()
	n.modified = n.created
	ResourceSaver.save(n, path)


func status() -> String:
	return app.status_label.text


func _init() -> void:
	ProgressStore.file_override = "user://test_progress_asset_folder.json"   # never touch real progress
	ProgressStore.reset()
	JourneyStore.file_override = "user://test_journey_asset_folder.json"     # never touch the real journey
	JourneyStore.reset()
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""

	V = TestVault.open("asset_folder", false)
	check_store()
	check_mcp()
	check_case()
	check_own_images_folder()
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	await check_app()
	await check_hidden_notes()

	app.queue_free()
	await frames(2)
	if registry_backup != "":   # switch_vault remembers the vault: put the list back
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	for f in [ProgressStore.file_override, JourneyStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	print("\nRESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(0 if fails == 0 else 1)


## VaultStore: no folder or note goes into a root images/ or models/.
func check_store() -> void:
	check(VaultStore.create_folder("images") == "" and not DirAccess.dir_exists_absolute(V + "images"),
		"create_folder('images') at the top level is refused and makes nothing")
	check(VaultStore.last_refusal.contains("images") and VaultStore.last_refusal.contains("picture folder"),
		"…and last_refusal says why (%s)" % VaultStore.last_refusal)
	check(VaultStore.create_folder(" .images ") == "", "a name that cleans to 'images' is refused too")
	check(VaultStore.create_folder("models") == "" and VaultStore.last_refusal.contains("3D model folder"),
		"create_folder('models') is refused (%s)" % VaultStore.last_refusal)
	save_image(V + "images/x.png")   # the picture folder exists now
	check(VaultStore.create_folder("images") == "" and "images 2" not in VaultStore.folders and not DirAccess.dir_exists_absolute(V + "images 2"),
		"with images/ on disk, create_folder('images') is still refused, not numbered")
	check(VaultStore.create_folder("Sub", "images") == "" and not DirAccess.dir_exists_absolute(V + "images/Sub"),
		"no folder is made inside images/ either")
	var physics: String = VaultStore.create_folder("Physics")
	var nested: String = VaultStore.create_folder("images", physics)
	check(nested == "Physics/images" and VaultStore.last_refusal == "" and "Physics/images" in VaultStore.folders,
		"a nested Physics/images is an ordinary folder")

	var pics: String = VaultStore.create_folder("Pictures")
	var trip: ContentLayer = VaultStore.create_note("Trip notes", pics)
	check(VaultStore.rename_folder("Pictures", "images") == "" and VaultStore.last_refusal.contains("picture folder"),
		"rename_folder(<folder>, 'images') at the top level is refused")
	check("Pictures" in VaultStore.folders and note("Trip notes") == trip and VaultStore.folder_of(trip) == "Pictures",
		"…the folder and its note stay where they were, listed")
	check(VaultStore.rename_folder("Pictures", "Photos") == "Photos" and VaultStore.last_refusal == "",
		"another name still renames (and clears last_refusal)")
	check(VaultStore.move_folder("Physics/images", "images") == "" and DirAccess.dir_exists_absolute(V + "Physics/images")
		and "Physics/images" in VaultStore.folders, "move_folder of Physics/images to the top level is refused")
	check(VaultStore.move_folder("Photos", "images/Photos") == "" and "Photos" in VaultStore.folders,
		"move_folder into images/ is refused")
	check(not VaultStore.move_note(trip, "images") and VaultStore.folder_of(trip) == "Photos" and note("Trip notes") == trip,
		"move_note(note, 'images') is refused; the note stays listed in its folder")
	check(VaultStore.last_refusal.contains("picture folder"), "…and says why")
	check(not VaultStore.move_note(trip, "models/sub") and VaultStore.folder_of(trip) == "Photos", "move_note into models/sub is refused")
	check(VaultStore.move_note(trip, "Physics/images") and VaultStore.folder_of(trip) == "Physics/images",
		"move_note into the nested Physics/images works")
	var agent: ContentLayer = VaultStore.create_note("Agent note", "images")
	check(VaultStore.folder_of(agent) == "" and not agent.resource_path.contains("/images/") and note("Agent note") == agent,
		"create_note(title, 'images') keeps the note at the top level, listed (%s)" % agent.resource_path)
	check(DirAccess.get_files_at(V + "images") == PackedStringArray(["x.png"]), "images/ still holds only the picture")


## An initialized MCP server on `vault`, for mcp_call.
func mcp_for(vault: String) -> RefCounted:
	var p: RefCounted = McpProtocol.new(VaultTools.new(vault))
	p.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
	return p


## One tools/call through `p`; its result ({} if none).
func mcp_call(p: RefCounted, name: String, args: Dictionary) -> Dictionary:
	var r: Variant = p.handle({"jsonrpc": "2.0", "id": 10, "method": "tools/call",
		"params": {"name": name, "arguments": args}})
	return r.result if r is Dictionary and r.has("result") else {}


## The error code of an MCP tool result, "" when it succeeded.
func err_code(r: Dictionary) -> String:
	return str(r.get("structuredContent", {}).get("error", {}).get("code", "")) if r.get("isError", false) else ""


## True when the filesystem under `dir` ignores case (Windows, macOS; Linux
## does not): a folder made as "casetest" answers to "CASETEST".
func folds_case(dir: String) -> bool:
	DirAccess.make_dir_recursive_absolute(dir + "casetest")
	var folds: bool = DirAccess.dir_exists_absolute(dir + "CASETEST")
	DirAccess.remove_absolute(dir + "casetest")
	return folds


## Note files under `dir`, hidden folders aside: listed or not.
func tres_count(dir: String) -> int:
	var n: int = 0
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			n += tres_count(dir.path_join(d))
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".tres"):
			n += 1
	return n


## MCP: the asset folders are no folder for create_note, list_notes or search_notes.
func check_mcp() -> void:
	var p: RefCounted = mcp_for(V)
	for folder in ["images", "images/", " images ", "models", "images/Sub"]:
		var r: Dictionary = mcp_call(p, "create_note", {"title": "Figure index", "folder": folder})
		check(err_code(r) == "invalid_path", "MCP create_note in folder '%s' → invalid_path" % folder)
	check(not FileAccess.file_exists(V + "images/note_figure_index.tres") and not FileAccess.file_exists(V + "models/note_figure_index.tres"),
		"…and writes no note file there")
	check(err_code(mcp_call(p, "list_notes", {"folder": "images"})) == "invalid_path", "MCP list_notes in images → invalid_path")
	check(err_code(mcp_call(p, "search_notes", {"query": "x", "folder": "images"})) == "invalid_path", "MCP search_notes in images → invalid_path")
	var ok: Dictionary = mcp_call(p, "create_note", {"title": "Figure index", "folder": "Physics/images"})
	check(not ok.get("isError", true) and str(ok.structuredContent.path) == "Physics/images/note_figure_index.tres",
		"MCP create_note in the nested Physics/images works")
	VaultStore.refresh_note_list()


## Windows and macOS ignore case, so there "Images" opens images/ and a note
## put in Images/ lands in the picture folder, where no list shows it. So no
## system puts a note or folder into any spelling of images/ or models/
## (Windows also drops trailing dots and spaces), not even Linux, where
## "Images" would be a folder of its own: a vault made there opens the same
## on the other two. Here images/ holds a picture and no "Images" is on disk.
func check_case() -> void:
	var roots: PackedStringArray = DirAccess.get_directories_at(V)
	for name in ["Images", "IMAGES", "Models", "Images "]:
		check(VaultStore.create_folder(name) == "" and VaultStore.last_refusal.contains("on Windows and macOS"),
			"create_folder('%s') is refused (%s)" % [name, VaultStore.last_refusal])
	# A new folder's name loses its trailing dots first (_clean_name, as
	# Windows drops them), so "images." is refused as images/ itself
	check(VaultStore.create_folder("images.") == "" and VaultStore.last_refusal == "“images” is the vault's picture folder, so it can't hold notes",
		"create_folder('images.') is refused (%s)" % VaultStore.last_refusal)
	check(VaultStore.create_folder("Sub", "Images") == "" and VaultStore.last_refusal.contains("picture folder"),
		"no folder is made inside Images/ either")
	check(VaultStore.rename_folder("Photos", "Images") == "" and "Photos" in VaultStore.folders,
		"rename_folder(<folder>, 'Images') is refused")
	check(VaultStore.move_folder("Photos", "MODELS/Photos") == "" and "Photos" in VaultStore.folders
		and VaultStore.last_refusal.contains("3D model folder (models/)"), "move_folder into MODELS/ is refused (%s)" % VaultStore.last_refusal)
	var trip: ContentLayer = note("Trip notes")
	var was: String = VaultStore.folder_of(trip)
	check(not VaultStore.move_note(trip, "Images") and VaultStore.folder_of(trip) == was and note("Trip notes") == trip,
		"move_note(note, 'Images') is refused; the note stays listed in %s" % was)
	check(VaultStore.last_refusal == "“Images” is the vault's picture folder (images/) on Windows and macOS, so it can't hold notes",
		"…and says why: %s" % VaultStore.last_refusal)
	check(not VaultStore.move_note(trip, "iMaGeS/Sub") and VaultStore.folder_of(trip) == was, "move_note into iMaGeS/Sub is refused")
	var n: ContentLayer = VaultStore.create_note("Case note", "Images")
	check(VaultStore.folder_of(n) == "" and note("Case note") == n,
		"create_note(title, 'Images') keeps the note at the top level, listed (%s)" % n.resource_path)

	var p: RefCounted = mcp_for(V)
	for folder in ["Images", "IMAGES/", " Images ", "Images/Sub", "Models", "MODELS/x", "images."]:
		var r: Dictionary = mcp_call(p, "create_note", {"title": "Case figure", "folder": folder})
		check(err_code(r) == "invalid_path", "MCP create_note in folder '%s' → invalid_path (%s)" % [folder, r.get("structuredContent", {})])
	check(err_code(mcp_call(p, "list_notes", {"folder": "Images"})) == "invalid_path", "MCP list_notes in Images → invalid_path")
	check(err_code(mcp_call(p, "search_notes", {"query": "x", "folder": "MODELS"})) == "invalid_path", "MCP search_notes in MODELS → invalid_path")
	check(err_code(mcp_call(p, "read_note", {"path": "Images/note_case_figure.tres"})) == "invalid_path", "MCP read_note under Images/ → invalid_path")
	check(DirAccess.get_directories_at(V) == roots, "no new root folder (%s)" % [DirAccess.get_directories_at(V)])
	check(DirAccess.get_files_at(V + "images") == PackedStringArray(["x.png"]), "images/ still holds only the picture (%s)" % [DirAccess.get_files_at(V + "images")])


## A user's own root folder named exactly "Images" (not images/) is listed on
## every system, so it is no asset folder: no hidden-notes warning, and the
## app and the MCP still put notes in it. On Windows and macOS a picture saved
## to images/ lands in it too; on Linux images/ is a folder of its own, and a
## note there is the one hidden. Either way the warning counts exactly the
## notes the lists leave out.
func check_own_images_folder() -> void:
	var v2: String = ProjectSettings.globalize_path("user://test-vault-asset_folder_case/")
	TestVault.remove_tree(v2)
	write_note_file(v2 + "Images/note_gallery.tres", "Gallery")
	write_note_file(v2 + "note_loose.tres", "Loose")
	var folds: bool = folds_case(v2)
	print("       (this filesystem %s case)" % ("ignores" if folds else "keeps"))
	VaultStore.open_vault(v2, false)
	check("Images" in VaultStore.folders and VaultStore.folder_of(note("Gallery")) == "Images", "a root Images/ folder of notes is listed")
	check(VaultStore.notes_in_asset_dirs().is_empty() and VaultStore.hidden_notes_warning() == "",
		"…and gets no hidden-notes warning (%s)" % VaultStore.hidden_notes_warning())
	save_image(v2 + "images/photo.png")   # what inserting a picture does
	VaultStore.refresh_note_list()
	check(VaultStore.folder_of(note("Gallery")) == "Images" and VaultStore.hidden_notes_warning() == "",
		"with a picture saved to images/, Gallery stays listed and unwarned (%s)" % VaultStore.hidden_notes_warning())
	var loose: ContentLayer = note("Loose")
	check(VaultStore.move_note(loose, "Images") and VaultStore.folder_of(loose) == "Images" and note("Loose") == loose
		and VaultStore.last_refusal == "", "move_note into the listed Images/ works")
	check(VaultStore.create_folder("Trips", "Images") == "Images/Trips" and "Images/Trips" in VaultStore.folders,
		"create_folder inside the listed Images/ works")

	var p: RefCounted = mcp_for(v2)
	var listed: Dictionary = mcp_call(p, "list_notes", {"folder": "Images"})
	check(err_code(listed) == "" and int(listed.structuredContent.count) == 2, "MCP list_notes in Images lists its 2 notes (%s)" % [listed.get("structuredContent", {})])
	check(err_code(mcp_call(p, "read_note", {"path": "Images/note_gallery.tres"})) == "", "MCP read_note of Images/note_gallery.tres works")
	var made: Dictionary = mcp_call(p, "create_note", {"title": "Sketch", "folder": "Images"})
	check(err_code(made) == "" and str(made.structuredContent.path) == "Images/note_sketch.tres", "MCP create_note in Images works (%s)" % [made.get("structuredContent", {})])
	var all: Dictionary = mcp_call(p, "list_notes", {})
	check(all.structuredContent.notes.any(func(x): return x.path == "Images/note_sketch.tres"), "…and list_notes shows the note it made")
	VaultStore.refresh_note_list()
	check(note("Sketch") != null, "…and so does the app")
	check(err_code(mcp_call(p, "create_note", {"title": "Other", "folder": "IMAGES"})) == "invalid_path",
		"another spelling, IMAGES, is still refused")

	write_note_file(v2 + "images/note_old.tres", "Old")   # Linux: hidden in images/; Windows, macOS: in Images/, listed
	VaultStore.refresh_note_list()
	var hidden: Array[String] = VaultStore.notes_in_asset_dirs()
	check(hidden == ([] as Array[String] if folds else ["images/note_old.tres"] as Array[String]) and (note("Old") != null) == folds,
		"a note written to images/ is %s (%s)" % ["listed in Images/, no warning" if folds else "hidden and warned about", hidden])
	check(hidden.size() == tres_count(v2) - VaultStore.note_list.size(),
		"the warning counts exactly the notes the lists leave out (%d of %d)" % [hidden.size(), tres_count(v2)])
	VaultStore.open_vault(V, false)
	TestVault.remove_tree(v2)


## The app's folder commands and sidebar drops show VaultStore's reason.
func check_app() -> void:
	check(app.create_folder("images") == "" and "images" not in VaultStore.folders, "app.create_folder('images') is refused")
	check(status().contains("Couldn't create the folder") and status().contains("picture folder"), "…the status says why (%s)" % status())
	check(app.rename_folder("Photos", "images") == "" and "Photos" in VaultStore.folders, "app.rename_folder(<folder>, 'images') is refused")
	check(status().contains("Couldn't rename") and status().contains("picture folder"), "…the status says why (%s)" % status())
	check(app.create_folder("Images") == "" and "Images" not in VaultStore.folders, "app.create_folder('Images') is refused")
	check(status().contains("picture folder (images/) on Windows and macOS"), "…the status says why (%s)" % status())
	check(app.rename_folder("Photos", "MODELS") == "" and "Photos" in VaultStore.folders, "app.rename_folder(<folder>, 'MODELS') is refused")
	check(status().contains("Couldn't rename") and status().contains("3D model folder (models/)"), "…the status says why (%s)" % status())
	app._drop({"type": "folder", "rel": "Physics/images"}, "")
	await frames(2)
	check(DirAccess.dir_exists_absolute(V + "Physics/images") and "Physics/images" in VaultStore.folders and app._folder_buttons.has("Physics/images"),
		"dropping Physics/images on the top level leaves it where it is")
	check(status().contains("Couldn't move the folder") and status().contains("picture folder"), "…the status says why (%s)" % status())
	var trip: ContentLayer = note("Trip notes")
	check(not app.move_note_to(trip, "images") and note("Trip notes") == trip and app._note_buttons.has(trip),
		"app.move_note_to(note, 'images') is refused; the note stays in the sidebar")
	check(status().contains("Couldn't move") and status().contains("picture folder"), "…the status says why (%s)" % status())


## Notes already inside a root images/ (a vault from before images/ was the
## picture folder): hidden, but the app says how many and how to see them.
func check_hidden_notes() -> void:
	check(VaultStore.notes_in_asset_dirs().is_empty() and VaultStore.hidden_notes_warning() == "",
		"a picture in images/ and a note in Physics/images are no hidden note")
	var old: String = ProjectSettings.globalize_path("user://test-vault-asset_folder_old/")
	TestVault.remove_tree(old)
	write_note_file(old + "note_kept.tres", "Kept")
	write_note_file(old + "images/note_photo_notes.tres", "Photo notes")
	save_image(old + "images/photo.png")

	VaultStore.open_startup_vault(old, ProjectSettings.globalize_path("user://test-vault-asset_folder_default/"), false)
	check(VaultStore.vault_path == old and note("Kept") != null and note("Photo notes") == null, "a root images/ note is not listed")
	check(VaultStore.notes_in_asset_dirs() == ["images/note_photo_notes.tres"], "notes_in_asset_dirs finds it (%s)" % [VaultStore.notes_in_asset_dirs()])
	var w: String = VaultStore.hidden_notes_warning()
	check(w == "1 note in images/ is hidden: images/ is the vault's picture folder. Move it to another folder to see it.", "the warning: %s" % w)
	check(VaultStore.startup_warning == w, "opening it at startup puts the warning in startup_warning")

	write_note_file(old + "images/trips/note_rome.tres", "Rome")
	write_note_file(old + "models/note_mesh_notes.tres", "Mesh notes")
	check(VaultStore.hidden_notes_warning() == "3 notes in images/ and models/ are hidden: those are the vault's picture and 3D model folders. Move them to another folder to see them.",
		"three notes in both folders, one in a subfolder: %s" % VaultStore.hidden_notes_warning())

	app.switch_vault(old)
	await frames(3)
	check(status().begins_with("Opened vault") and status().contains("3 notes in images/ and models/ are hidden"),
		"switching to that vault puts the warning in the status line (%s)" % status())
	app.switch_vault(V)
	await frames(3)
	check(status() == "Opened vault " + VaultRegistry.display_name(V), "a vault with none says just 'Opened vault' (%s)" % status())
	TestVault.remove_tree(old)
