extends RefCounted
## What a brand-new vault starts with: the tutorials (+ their Learning Journey),
## the Godot Fundamentals course and the memetics course. Written once, when the app first creates the
## default vault, so a new user never meets an empty window.

const Tutorials = preload("res://tutorials_content.gd")
const NoteImporter = preload("res://note_importer.gd")
const GodotCourse = preload("res://godot_course_content.gd")
const COURSE_DIR: String = "res://ontomeme-notes"
const COURSE_FOLDER: String = "Memetics"


const MARKER: String = ".ontomeme/starter-seeded"


## True when the default vault is missing, or exists with no notes and was
## never seeded (an earlier launch created the folder but was interrupted,
## e.g. while macOS asked for access to Documents). A folder the app can't
## list is not empty, just unreadable: never a first run, nothing is seeded.
static func is_first_run(vault: String, default_vault: String) -> bool:
	if VaultRegistry.normalize(vault) != VaultRegistry.normalize(default_vault):
		return false
	if not DirAccess.dir_exists_absolute(vault):
		return true
	if DirAccess.open(vault) == null:
		return false
	return not FileAccess.file_exists(vault.path_join(MARKER)) and not _has_notes(vault)


static func _has_notes(dir: String) -> bool:
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() == "tres":
			return true
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with(".") and _has_notes(dir.path_join(d)):
			return true
	return false


## Seed the open vault (first run, or the palette's "Add the tutorials and
## starter course" in any vault). Each course matches only its own notes, in
## its own folder (Tutorials, Godot, Memetics): a note of the user's that
## shares a lesson's title, and a models/rocket.glb already there, are left
## as they are. Returns the number of notes the vault now holds.
static func seed_vault() -> int:
	Tutorials.seed_vault()
	GodotCourse.seed_vault("Godot")
	if DirAccess.dir_exists_absolute(COURSE_DIR):
		var importer := NoteImporter.new()
		importer.scope_to_folder = true   # never a same-titled note of the user's
		importer.import_dir(COURSE_DIR, COURSE_FOLDER)
	VaultStore.refresh_note_list()
	DirAccess.make_dir_recursive_absolute(VaultStore.vault_path.path_join(MARKER.get_base_dir()))
	# Fold the courses so the Tutorials folder is in view (unless the vault
	# already has folds of its own; ui.json's other keys are kept)
	var ui_path: String = VaultStore.data_dir().path_join("ui.json")
	var ui: Variant = JSON.parse_string(FileAccess.get_file_as_string(ui_path)) if FileAccess.file_exists(ui_path) else {}
	if not ui is Dictionary:
		ui = {}
	if not (ui as Dictionary).has("collapsed"):
		ui["collapsed"] = ["Godot", COURSE_FOLDER]
		var u := FileAccess.open(ui_path, FileAccess.WRITE)
		if u != null:
			u.store_string(JSON.stringify(ui, "\t"))
	var f := FileAccess.open(VaultStore.vault_path.path_join(MARKER), FileAccess.WRITE)
	if f != null:
		f.store_string(Time.get_datetime_string_from_system() + "\n")
	return VaultStore.note_list.size()
