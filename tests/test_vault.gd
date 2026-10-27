extends RefCounted
## A throwaway vault for tests, so they never read or write the user's notes
## and pass the same on a fresh machine (CI) as on a developer's.
##   const TestVault = preload("res://tests/test_vault.gd")
##   TestVault.open("progress")   # call after setting the store file_overrides

const SeedTutorials = preload("res://tests/seed_tutorials.gd")
const SeedQuizNotes = preload("res://tests/seed_quiz_notes.gd")


## Wipe and open user://test-vault-<name>/ (not remembered in the recent-vaults
## list), seeded with the tutorials and the Godot course. Returns its path.
static func open(name: String, seed: bool = true) -> String:
	var path: String = ProjectSettings.globalize_path("user://test-vault-%s/" % name)
	remove_tree(path)
	DirAccess.make_dir_recursive_absolute(path)
	VaultStore.open_vault(path, false)
	if seed:
		SeedTutorials.seed_vault(false)   # no starter journey: tests own the journey file
		SeedQuizNotes.seed_vault()
		VaultStore.refresh_note_list()
	return path


static func remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		remove_tree(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
