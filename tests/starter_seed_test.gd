extends SceneTree
## "Add the tutorials and starter course" (StarterContent.seed_vault) writes
## only the courses' own notes, in their own folders (Tutorials, Godot,
## Memetics). A note of the user's that shares a lesson's title, their own
## "Introduction" and their models/rocket.glb stay byte for byte as they
## were, and running it twice adds nothing.
##   headless:  godot --headless --path . -s res://tests/starter_seed_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const StarterContent = preload("res://starter_content.gd")
const Tutorials = preload("res://tutorials_content.gd")
const GodotCourse = preload("res://godot_course_content.gd")
const NoteImporter = preload("res://note_importer.gd")

const WELCOME_LINK: String = "[[Start Here: Tutorials]]"

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func _init() -> void:
	# The vault is open before anything awaits, so the VaultStore autoload
	# never opens the real one.
	JourneyStore.file_override = "user://test_journey_starter_seed.json"   # never touch the real journey
	ProgressStore.file_override = "user://test_progress_starter_seed.json"   # never touch real progress
	var vault: String = TestVault.open("starter-seed", false)
	JourneyStore.reset()
	ProgressStore.reset()

	# The user's own notes, filed where the user put them
	var mine: Dictionary = {}   # path -> raw_text
	for row in [
		["Signals", "MY OWN signals notes", ""],                      # a Godot lesson's title
		["Introduction", "intro", ""],                                # the old welcome note's title
		["Tutorial 1: Writing Notes", "my own tutorial notes", ""],   # a tutorial's title
		["History of Memetics", "my memetics reading list", ""],      # a Memetics lesson's title
		["Signals", "signals, filed elsewhere", "Physics"],           # the same title in another folder
	]:
		var n: ContentLayer = VaultStore.create_note(row[0], row[2])
		n.raw_text = row[1]
		VaultStore.save_note(n)
		mine[n.resource_path] = row[1]
	DirAccess.make_dir_recursive_absolute(vault.path_join("models"))
	var rocket: String = vault.path_join("models/rocket.glb")
	FileAccess.open(rocket, FileAccess.WRITE).store_string("mine")
	var hashes: Dictionary = {}   # path -> SHA-256
	for p in mine.keys() + [rocket]:
		hashes[p] = FileAccess.get_sha256(p)

	# find_note matches a title only in the given folder
	check(VaultStore.find_note("Signals", "") != null and VaultStore.find_note("Signals", "").raw_text == "MY OWN signals notes", "find_note finds the top-level Signals")
	check(VaultStore.find_note("Signals", "Physics/") != null and VaultStore.folder_of(VaultStore.find_note("Signals", "Physics/")) == "Physics", "…and the one in Physics (a trailing / is fine)")
	check(VaultStore.find_note("Signals", "Godot") == null, "…and none in Godot yet")

	StarterContent.seed_vault()
	untouched(mine, hashes, "after seeding")
	var signals: ContentLayer = VaultStore.find_note("Signals", "Godot")
	check(signals != null and signals.raw_text == GodotCourse.NOTES["Signals"], "the course's Signals is created in Godot/ with the course text")
	var t1: ContentLayer = VaultStore.find_note(Tutorials.T1, Tutorials.FOLDER)
	check(t1 != null and t1.raw_text == Tutorials.NOTES[1][1], "Tutorial 1 is created in Tutorials/ with the tutorial text")
	check(VaultStore.find_note("History of Memetics", StarterContent.COURSE_FOLDER) != null, "History of Memetics is created in Memetics/")
	var n_notes: int = VaultStore.note_list.size()

	# Running it again rewrites the course in place: nothing is duplicated
	StarterContent.seed_vault()
	untouched(mine, hashes, "after seeding twice")
	check(VaultStore.note_list.size() == n_notes, "seeding twice adds no notes (%d, then %d)" % [n_notes, VaultStore.note_list.size()])
	check(count("Signals", "Godot") == 1 and count("Signals", "") == 1 and count("Signals", "Physics") == 1, "one Signals in Godot/, the user's two left where they were")
	var twice: Array[String] = []
	for row in Tutorials.NOTES:
		if count(row[0], Tutorials.FOLDER) != 1:
			twice.append("%s x%d" % [row[0], count(row[0], Tutorials.FOLDER)])
	for title in GodotCourse.NOTES:
		if count(title, "Godot") != 1:
			twice.append("%s x%d" % [title, count(title, "Godot")])
	for n in VaultStore.note_list:
		if VaultStore.folder_of(n) == StarterContent.COURSE_FOLDER and count(n.title, StarterContent.COURSE_FOLDER) != 1:
			twice.append("%s x%d" % [n.title, count(n.title, StarterContent.COURSE_FOLDER)])
	check(twice.is_empty() and count("History of Memetics", StarterContent.COURSE_FOLDER) == 1, "every course note exists once, in its own folder %s" % [twice])
	check(VaultStore.note_list.all(func(n: ContentLayer) -> bool: return not n.title.contains("conflict copy")), "no conflict copies")

	check_tutorial_intro()
	check_importer_modes()

	TestVault.remove_tree(vault)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


## Every user file is byte-identical at its old path, and the note loaded
## from it still holds the user's text.
func untouched(mine: Dictionary, hashes: Dictionary, when: String) -> void:
	var changed: Array[String] = []
	for p in hashes:
		if FileAccess.get_sha256(p) != hashes[p]:
			changed.append(p.trim_prefix(VaultStore.vault_path))
	for p in mine:
		var n: ContentLayer = note_at(p)
		if n == null or n.raw_text != mine[p]:
			changed.append("%s (in memory)" % p.trim_prefix(VaultStore.vault_path))
	check(changed.is_empty(), "%s: the user's notes and rocket.glb are untouched %s" % [when, changed])


## The welcome link goes only into an Introduction of the tutorials' own: one
## in the Tutorials folder or tagged "tutorial", never the user's.
func check_tutorial_intro() -> void:
	var ours: ContentLayer = VaultStore.create_note("Introduction", Tutorials.FOLDER)
	ours.raw_text = "Welcome."
	VaultStore.save_note(ours)
	var tagged: ContentLayer = VaultStore.create_note("Introduction", "Old")
	tagged.raw_text = "Welcome too."
	tagged.tags.assign(["tutorial"])
	VaultStore.save_note(tagged)
	Tutorials.seed_vault(false)
	check(ours.raw_text.begins_with("New here? Start with " + WELCOME_LINK) and ours.raw_text.ends_with("Welcome."), "an Introduction in Tutorials/ gets the welcome link")
	check(tagged.raw_text.begins_with("New here?"), "…and so does one tagged 'tutorial'")
	check(not VaultStore.find_note("Introduction", "").raw_text.contains(WELCOME_LINK), "…but not the user's own Introduction")
	Tutorials.seed_vault(false)
	check(ours.raw_text.count(WELCOME_LINK) == 1, "…and only once")


## NoteImporter upserts by title anywhere (scripts/import_notes.gd moves the
## note into the new folder); scope_to_folder matches only inside it.
func check_importer_modes() -> void:
	var src: String = ProjectSettings.globalize_path("user://test-starter-seed-src/")
	TestVault.remove_tree(src)
	for title in ["scoped me", "upsert me"]:
		var dir: String = src.path_join(title.get_slice(" ", 0))
		DirAccess.make_dir_recursive_absolute(dir.path_join("Moved"))
		FileAccess.open(dir.path_join("Moved/%s.md" % title.replace(" ", "_")), FileAccess.WRITE).store_string("imported text\n")
	var users: Array[ContentLayer] = []
	for title in ["scoped me", "upsert me"]:
		var n: ContentLayer = VaultStore.create_note(title)
		n.raw_text = "the user's text"
		VaultStore.save_note(n)
		users.append(n)
	var scoped := NoteImporter.new()
	scoped.scope_to_folder = true
	scoped.import_dir(src.path_join("scoped"))
	check(users[0].raw_text == "the user's text" and VaultStore.folder_of(users[0]) == "" and count("scoped me", "Moved") == 1,
			"scope_to_folder: a same-titled note elsewhere is left alone, the import goes into its folder")
	NoteImporter.new().import_dir(src.path_join("upsert"))
	check(users[1].raw_text == "imported text\n" and VaultStore.folder_of(users[1]) == "Moved" and count("upsert me", "Moved") == 1,
			"default import (import_notes.gd) still upserts by title and moves the note")
	TestVault.remove_tree(src)


func note_at(path: String) -> ContentLayer:
	for n in VaultStore.note_list:
		if n.resource_path == path:
			return n
	return null


func count(title: String, folder: String) -> int:
	return VaultStore.note_list.filter(func(n: ContentLayer) -> bool: return n.title == title and VaultStore.folder_of(n) == folder).size()
