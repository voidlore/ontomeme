extends RefCounted
## What a brand-new vault starts with: the tutorials (+ their Learning Journey)
## and the memetics course. Written once, when the app first creates the
## default vault, so a new user never meets an empty window.

const Tutorials = preload("res://tutorials_content.gd")
const NoteImporter = preload("res://note_importer.gd")
const COURSE_DIR: String = "res://ontomeme-notes"
const COURSE_FOLDER: String = "Memetics"


## True when the app is about to create the default vault for the first time.
static func is_first_run(vault: String, default_vault: String) -> bool:
	return VaultRegistry.normalize(vault) == VaultRegistry.normalize(default_vault) \
		and not DirAccess.dir_exists_absolute(vault)


## Seed the open vault. Returns the number of notes it now holds.
static func seed_vault() -> int:
	Tutorials.seed_vault()
	if DirAccess.dir_exists_absolute(COURSE_DIR):
		NoteImporter.new().import_dir(COURSE_DIR, COURSE_FOLDER)
	VaultStore.refresh_note_list()
	return VaultStore.note_list.size()
