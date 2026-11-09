extends SceneTree
## Deleting is undoable: a deleted note moves to <vault>/.trash (the layout
## the MCP server's delete_note uses) and comes back with Ctrl+Z or the
## palette's "Restore last deleted note"; a folder the system trash refuses
## goes to .trash too. No file is ever removed.
##   headless:  godot --headless --path . -s res://tests/trash_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")

var fails: int = 0
var V: String = ""


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## Click `ctrl` with real mouse events, as a user does.
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


## Press and release Ctrl+`key` (Ctrl+Shift+`key` with `shift`).
func press_ctrl(key: Key, shift: bool = false) -> void:
	for pressed in [true, false]:
		var k := InputEventKey.new()
		k.keycode = key
		k.ctrl_pressed = true
		k.shift_pressed = shift
		k.pressed = pressed
		get_root().push_input(k)
	await frames(2)


## Right-click `ctrl` with a real mouse event (a right-click moves no focus).
func right_click(ctrl: Control) -> void:
	var pos: Vector2 = ctrl.get_global_rect().get_center()
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	await process_frame
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_RIGHT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	await frames(2)


func make_note(title: String, folder: String, text: String) -> ContentLayer:
	var n: ContentLayer = VaultStore.create_note(title, folder)
	n.raw_text = text
	VaultStore.save_note(n)
	return n


func trash_files(sub: String) -> PackedStringArray:
	return DirAccess.get_files_at(V + VaultStore.TRASH_DIR.path_join(sub))


func listed(path: String) -> bool:
	return VaultStore.note_list.any(func(n): return n.resource_path == path)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_trash.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_trash.json"   # never touch real progress
	ProgressStore.reset()
	V = TestVault.open("trash", false)
	await frames(2)

	store_delete_note()
	store_restore()
	store_restore_taken_title()
	store_new_note_takes_trashed_title()
	store_outside_note_takes_trashed_title()
	store_delete_folder()
	await ui_delete_and_restore()

	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	TestVault.remove_tree(V)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


# ── VaultStore.delete_note → .trash ─────────────────────────────────────────

func store_delete_note() -> void:
	VaultStore.create_folder("Sub")
	var a: ContentLayer = make_note("Alpha", "Sub", "first alpha")
	var path: String = a.resource_path
	var rel: String = path.substr(V.length())
	var sha: String = FileAccess.get_sha256(path)
	check(rel == "Sub/note_alpha.tres", "(Alpha is at %s)" % rel)
	check(VaultStore.delete_note(VaultStore.note_list.find(a)), "delete_note reports success")
	check(not FileAccess.file_exists(path), "the note's file is gone from its folder")
	check(FileAccess.file_exists(V + ".trash/" + rel), "…and is in .trash/%s" % rel)
	check(FileAccess.get_sha256(V + ".trash/" + rel) == sha, "…byte for byte (same SHA-256)")
	check(VaultStore.get_note_index("Alpha") < 0 and not listed(path), "the note leaves note_list")
	var sig: String = VaultStore.disk_signature()
	check(not sig.contains(".trash") and not sig.contains("note_alpha"), "the trash is not in the disk signature")
	check(not VaultStore.folders.has(".trash") and not VaultStore.folders.any(func(f): return str(f).begins_with(".")), "…nor among the folders")
	check(not VaultStore._hashes.has(path) and not VaultStore._mtimes.has(path), "the app forgets the deleted file")

	# A second note at the same path: both copies stay in the trash
	var a2: ContentLayer = make_note("Alpha", "Sub", "second alpha")
	check(a2.resource_path == path, "(a new Alpha takes the same path)")
	check(VaultStore.delete_note(VaultStore.note_list.find(a2)), "(the second Alpha is deleted)")
	var files: PackedStringArray = trash_files("Sub")
	var stamped: Array = Array(files).filter(func(f): return str(f).begins_with("note_alpha (deleted ") and str(f).ends_with(").tres"))
	check(files.size() == 2 and files.has("note_alpha.tres") and stamped.size() == 1, "two deletes of one path keep both copies %s" % str(files))
	check(FileAccess.get_file_as_string(V + ".trash/Sub/note_alpha.tres").contains("first alpha"), "…the first copy is untouched")
	check(stamped.size() == 1 and FileAccess.get_file_as_string(V + ".trash/Sub/" + stamped[0]).contains("second alpha"), "…and the second gets the \"(deleted …)\" suffix")

	# The MCP server trashes into the same folder with the same naming
	var a3: ContentLayer = make_note("Alpha", "Sub", "third alpha, deleted by Claude")
	var tools: RefCounted = VaultTools.new(V)
	var read: Dictionary = tools.call_tool("read_note", {"path": rel})
	var del: Dictionary = tools.call_tool("delete_note", {"path": rel, "hash": read.structuredContent.hash})
	check(not del.get("isError", false) and trash_files("Sub").size() == 3, "an MCP delete lands beside the app's in the same trash %s" % str(trash_files("Sub")))
	check(not FileAccess.file_exists(a3.resource_path), "(the MCP-deleted note is gone)")
	VaultStore.refresh_note_list()


# ── VaultStore.restore_from_trash ───────────────────────────────────────────

func store_restore() -> void:
	var b: ContentLayer = make_note("Bravo", "", "bravo words")
	var path: String = b.resource_path
	var rel: String = path.substr(V.length())
	var sha: String = FileAccess.get_sha256(path)
	var trash_rel: String = VaultStore.trash_note(b)
	check(trash_rel == ".trash/" + rel and not FileAccess.file_exists(path), "trash_note returns the trash path (%s)" % trash_rel)
	var back: ContentLayer = VaultStore.restore_from_trash(trash_rel, rel)
	check(back != null and back.resource_path == path and back.raw_text == "bravo words", "restore_from_trash puts the note back at its path")
	check(listed(path) and FileAccess.get_sha256(path) == sha and not FileAccess.file_exists(V + trash_rel), "…in note_list, byte for byte, and out of the trash")
	back.raw_text = "bravo, edited after the restore"
	check(VaultStore.save_note(back) == OK and VaultStore.last_conflict_copy == null, "…and it saves in place (no conflict copy)")

	trash_rel = VaultStore.trash_note(back)
	var taken: ContentLayer = make_note("Bravo", "", "a new bravo")
	check(taken.resource_path == path, "(a new Bravo took the old path)")
	var beside: ContentLayer = VaultStore.restore_from_trash(trash_rel, rel)
	check(beside != null and beside.resource_path == V + "note_bravo_1.tres" and beside.raw_text == "bravo, edited after the restore", "a restore whose path is taken lands beside it (%s)" % (beside.resource_path.get_file() if beside else "null"))
	check(FileAccess.get_file_as_string(path).contains("a new bravo"), "…and leaves the new note alone")
	check(VaultStore.restore_from_trash(trash_rel, rel) == null, "restoring a file no longer in the trash returns null")
	check(VaultStore.restore_from_trash("note_bravo.tres", "x.tres") == null, "only files in .trash are restored")

	# Written anew (its file left the trash) at a path whose file was deleted
	# outside the app since: the hash that file left behind is not this note's
	var f: ContentLayer = make_note("Foxtrot", "", "foxtrot words")
	var f_rel: String = f.resource_path.substr(V.length())
	var f_trash: String = VaultStore.trash_note(f)
	DirAccess.remove_absolute(V + f_trash)   # the user empties the trash
	var other: ContentLayer = make_note("Foxtrot", "", "another foxtrot")
	check(other.resource_path == V + f_rel, "(a new Foxtrot took the old path)")
	DirAccess.remove_absolute(other.resource_path)   # deleted outside: a file manager, a sync tool
	VaultStore.refresh_note_list(true)   # the watcher's rescan
	var again: ContentLayer = VaultStore.recreate_note(f_trash, f_rel, {"title": "Foxtrot", "raw_text": "foxtrot's kept words"})
	check(again != null and again.resource_path == V + f_rel and again.title == "Foxtrot"
		and FileAccess.get_file_as_string(V + f_rel).contains("foxtrot's kept words"),
		"recreate_note where a file was deleted outside writes the note at that path (%s)" % (again.resource_path.get_file() if again else "null"))
	check(VaultStore.get_note_index("Foxtrot (conflict copy)") < 0, "…not as a conflict copy of the deleted file")


## Notes listed with `title`, ignoring case.
func titled(title: String) -> Array:
	return VaultStore.note_list.filter(func(n: ContentLayer) -> bool: return n.title.strip_edges().to_lower() == title.to_lower())


## The title the note's file holds now.
func title_on_disk(note: ContentLayer) -> String:
	var n: ContentLayer = ResourceLoader.load(note.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	return n.title if n != null else ""


## The activities of objective `o`'s demos, and of its log entries.
func demo_keys(o: Dictionary) -> Array:
	return JourneyStore.find_objective(o.id).get("demos", []).map(func(d: Dictionary) -> String: return d.activity)


func log_keys(o: Dictionary) -> Array:
	return JourneyStore.find_objective(o.id).get("log", []).map(func(e: Dictionary) -> String: return e.activity)


## A trashed note's title is free: a note renamed to it takes it (and its
## progress and Journey keys, RenameCascade). The restore brings the trashed
## note back under a title of its own, with its own quiz results and its own
## Learning Journey objectives.
func store_restore_taken_title() -> void:
	ProgressStore.reset()
	JourneyStore.reset()
	var physics: ContentLayer = make_note("Physics", "", "physics words")
	var draft: ContentLayer = make_note("Draft", "", "draft words")
	ProgressStore.record_result("Physics", 0, 3, 3)
	ProgressStore.record_result("Draft", 0, 0, 3)
	var topic: Dictionary = JourneyStore.add_topic("Science")
	var mass: Dictionary = JourneyStore.add_objective(topic.id, "Mass")
	var drafting: Dictionary = JourneyStore.add_objective(topic.id, "Drafting")
	JourneyStore.add_demo(mass.id, "Physics#quiz0")
	JourneyStore.add_demo(drafting.id, "Draft#quiz0")
	JourneyStore.log_score("Physics#quiz0", 3, 3)
	JourneyStore.log_score("Draft#quiz0", 1, 3)
	check(JourneyStore.objective_status(JourneyStore.find_objective(mass.id)) == "done", "(Physics' 3/3 meets Mass)")
	var rel: String = physics.resource_path.substr(V.length())
	var trash_rel: String = VaultStore.trash_note(physics)
	check(VaultStore.rename_note(draft, "Physics") == "", "(Draft takes the trashed note's title)")
	RenameCascade.apply("Draft", "Physics", draft)
	check(demo_keys(mass) == ["Physics (2)#quiz0"] and demo_keys(drafting) == ["Physics#quiz0"],
		"a note renamed to a trashed note's title never takes over its objectives: Mass's demo waits under a title no note has, Drafting's takes Physics (%s, %s)" % [demo_keys(mass), demo_keys(drafting)])
	check(JourneyStore.log_score("Physics#quiz0", 0, 3) == 1 and JourneyStore.objective_status(JourneyStore.find_objective(mass.id)) == "done",
		"…so the renamed note's quiz logs to its own objective, and Mass stays done")
	var back: ContentLayer = VaultStore.restore_from_trash(trash_rel, rel)
	check(back != null and back.title == "Physics (2)" and back.raw_text == "physics words", "a restore whose title another note took meanwhile comes back as “Physics (2)” (%s)" % (back.title if back else "null"))
	check(titled("Physics").size() == 1 and titled("Physics (2)").size() == 1, "…so no two notes share a title")
	check(back != null and title_on_disk(back) == "Physics (2)" and VaultStore.last_save_error == "", "…and its file holds that title")
	check(ProgressStore.quiz_passed("Physics (2)", 0), "…with its own 3/3 pass")
	check(not ProgressStore.quiz_passed("Physics", 0) and int(ProgressStore._data.quizzes.get("physics#0", {}).get("best", -1)) == 0, "…and the note renamed to Physics keeps its own 0/3")
	check(demo_keys(mass) == ["Physics (2)#quiz0"] and log_keys(mass) == ["Physics (2)#quiz0"], "…and its Journey: Mass's demo and score follow it to “Physics (2)” (%s, %s)" % [demo_keys(mass), log_keys(mass)])
	check(demo_keys(drafting) == ["Physics#quiz0"] and log_keys(drafting) == ["Physics#quiz0", "Physics#quiz0"], "…while the renamed note keeps Drafting and its two scores (%s, %s)" % [demo_keys(drafting), log_keys(drafting)])
	check(JourneyStore.objective_status(JourneyStore.find_objective(mass.id)) == "done" and JourneyStore.log_score("Physics (2)#quiz0", 3, 3) == 1,
		"…so Mass is still done, and the restored note's quiz logs to it")
	check(JourneyStore.log_score("Physics#quiz0", 0, 3) == 1 and JourneyStore.objective_status(JourneyStore.find_objective(mass.id)) == "done",
		"…and the renamed note's quiz to Drafting only")

	# Its file left the trash: written anew from the words the app kept, under a free title too
	var trash_again: String = VaultStore.trash_note(back)
	check(VaultStore.rename_note(draft, "Physics (2)") == "", "(the renamed note takes “Physics (2)” too)")
	RenameCascade.apply("Physics", "Physics (2)", draft)
	DirAccess.remove_absolute(V + trash_again)
	var rebuilt: ContentLayer = VaultStore.recreate_note(trash_again, rel, {"title": "Physics (2)", "raw_text": "physics words, kept"})
	check(rebuilt != null and rebuilt.title == "Physics (2) (2)" and title_on_disk(rebuilt) == "Physics (2) (2)" and titled("Physics (2)").size() == 1, "recreate_note under a taken title writes it as “Physics (2) (2)” (%s)" % (rebuilt.title if rebuilt else "null"))
	check(ProgressStore.quiz_passed("Physics (2) (2)", 0), "…with its results")
	check(demo_keys(mass) == ["Physics (2) (2)#quiz0"] and log_keys(mass) == ["Physics (2) (2)#quiz0", "Physics (2) (2)#quiz0"] and demo_keys(drafting) == ["Physics (2)#quiz0"],
		"…and its Journey entries, the renamed note keeping its own (%s, %s)" % [demo_keys(mass), demo_keys(drafting)])
	for n in [rebuilt, draft]:
		VaultStore.trash_note(n)
	JourneyStore.reset()


func status(o: Dictionary) -> String:
	return JourneyStore.objective_status(JourneyStore.find_objective(o.id))


## A trashed note's title taken some other way than renaming a titled note
## to it, which no rename trade covers: Ctrl+N's untitled note named so, a
## note created with it (a dead [[link]]'s Create, an import), another
## trashed note restored under it. That note never logs to the trashed
## note's objectives, and the restore still finds them.
func store_new_note_takes_trashed_title() -> void:
	JourneyStore.reset()
	var topic: Dictionary = JourneyStore.add_topic("Science")
	var mass: Dictionary = JourneyStore.add_objective(topic.id, "Mass")
	var physics: ContentLayer = make_note("Physics", "", "physics words")
	JourneyStore.add_demo(mass.id, "Physics#quiz0")
	JourneyStore.log_score("Physics#quiz0", 3, 3)
	var rel: String = physics.resource_path.substr(V.length())
	var trash_rel: String = VaultStore.trash_note(physics)
	# Ctrl+N, then the title typed (note.gd's _rename_current)
	var fresh: ContentLayer = VaultStore.create_note()
	check(VaultStore.rename_note(fresh, "Physics") == "", "(a new untitled note is named Physics)")
	RenameCascade.apply("untitled", "Physics", fresh)
	check(JourneyStore.log_score("Physics#quiz0", 0, 3) == 0 and status(mass) == "done",
		"an untitled note named like a trashed note never logs to its objectives: Mass stays done (%s, %s)" % [status(mass), log_keys(mass)])
	var back: ContentLayer = VaultStore.restore_from_trash(trash_rel, rel)
	check(back != null and back.title == "Physics (2)" and demo_keys(mass) == ["Physics (2)#quiz0"] and log_keys(mass) == ["Physics (2)#quiz0"],
		"…and the restore as “Physics (2)” finds them, with no score of the new note's among them (%s, %s)" % [demo_keys(mass), log_keys(mass)])
	check(JourneyStore.log_score("Physics (2)#quiz0", 3, 3) == 1 and JourneyStore.log_score("Physics#quiz0", 0, 3) == 0, "…so the restored note logs to Mass and the new one doesn't")

	# A note created with the title: a dead [[link]]'s Create, an import
	var trash_again: String = VaultStore.trash_note(back)
	var created: ContentLayer = VaultStore.create_note("Physics (2)")
	check(created != null and JourneyStore.log_score("Physics (2)#quiz0", 0, 3) == 0 and status(mass) == "done",
		"a note created with a trashed note's title never logs to its objectives either (%s, %s)" % [status(mass), log_keys(mass)])
	back = VaultStore.restore_from_trash(trash_again, rel)
	check(back != null and back.title == "Physics (2) (2)" and demo_keys(mass) == ["Physics (2) (2)#quiz0"] and status(mass) == "done",
		"…and the restore as “Physics (2) (2)” finds them (%s)" % [demo_keys(mass)])
	for n in [back, created, fresh]:
		VaultStore.trash_note(n)

	# Another trashed note restored under the title: Atoms is deleted, Draft
	# renamed to Atoms and deleted too, and the first Atoms restored
	JourneyStore.reset()
	var bonds: Dictionary = JourneyStore.add_objective(JourneyStore.add_topic("Chemistry").id, "Bonds")
	var drafting: Dictionary = JourneyStore.add_objective(JourneyStore.add_topic("Writing").id, "Drafting")
	var atoms: ContentLayer = make_note("Atoms", "", "atoms words")
	var draft: ContentLayer = make_note("Draft", "", "draft words")
	JourneyStore.add_demo(bonds.id, "Atoms#quiz0")
	JourneyStore.add_demo(drafting.id, "Draft#quiz0")
	JourneyStore.log_score("Atoms#quiz0", 3, 3)
	JourneyStore.log_score("Draft#quiz0", 3, 3)
	var atoms_rel: String = atoms.resource_path.substr(V.length())
	var atoms_trash: String = VaultStore.trash_note(atoms)
	check(VaultStore.rename_note(draft, "Atoms") == "", "(Draft takes the trashed note's title)")
	RenameCascade.apply("Draft", "Atoms", draft)
	var draft_rel: String = draft.resource_path.substr(V.length())
	var draft_trash: String = VaultStore.trash_note(draft)
	var first: ContentLayer = VaultStore.restore_from_trash(atoms_trash, atoms_rel)
	check(first != null and first.title == "Atoms" and JourneyStore.log_score("Atoms#quiz0", 0, 3) == 1 and status(drafting) == "done",
		"a restored note that takes a trashed note's title logs to its own objective only: Drafting stays done (%s, %s)" % [demo_keys(drafting), log_keys(drafting)])
	var second: ContentLayer = VaultStore.restore_from_trash(draft_trash, draft_rel)
	check(second != null and second.title == "Atoms (2)" and demo_keys(drafting) == ["Atoms (2)#quiz0"] and log_keys(drafting) == ["Atoms (2)#quiz0"] and status(drafting) == "done",
		"…and the other, restored as “Atoms (2)”, finds Drafting and its score (%s, %s)" % [demo_keys(drafting), log_keys(drafting)])
	for n in [first, second]:
		VaultStore.trash_note(n)
	JourneyStore.reset()


## Objective Mass, done by Physics' 3/3, with Physics in the trash:
## {mass, rel (where Physics was), trash_rel}.
func trashed_physics() -> Dictionary:
	JourneyStore.reset()
	var mass: Dictionary = JourneyStore.add_objective(JourneyStore.add_topic("Science").id, "Mass")
	var physics: ContentLayer = make_note("Physics", "", "physics words")
	JourneyStore.add_demo(mass.id, "Physics#quiz0")
	JourneyStore.log_score("Physics#quiz0", 3, 3)
	var rel: String = physics.resource_path.substr(V.length())
	return {"mass": mass, "rel": rel, "trash_rel": VaultStore.trash_note(physics)}


## A trashed note's title taken by a note that never passes through
## create_note: a .tres import (Import vault…, an imported folder, a dropped
## .tres: _import_tres), and a note the MCP server writes in its own process,
## which the app lists on its next rescan. Neither logs to the trashed note's
## objectives, and the restore finds them with no stray score. The trashed
## file moved back by hand is that note, though, and so is a note that had
## the title before: both keep its objectives.
func store_outside_note_takes_trashed_title() -> void:
	var ext: String = ProjectSettings.globalize_path("user://trash-test-import")
	DirAccess.make_dir_recursive_absolute(ext)
	var foreign := ContentLayer.new()
	foreign.title = "Physics"
	foreign.raw_text = "imported physics words"
	foreign.tags = []
	foreign.structure = {}
	ResourceSaver.save(foreign, ext.path_join("note_physics.tres"))

	var s: Dictionary = trashed_physics()
	var r: Dictionary = VaultStore.import_paths(PackedStringArray([ext.path_join("note_physics.tres")]))
	var imported: ContentLayer = r.imported[0] if r.imported.size() == 1 else null
	check(r.notes == 1 and imported != null and imported.title == "Physics", "(a .tres note titled Physics is imported as Physics)")
	check(JourneyStore.log_score("Physics#quiz0", 0, 3) == 0 and status(s.mass) == "done",
		"an imported .tres note with a trashed note's title never logs to its objectives: Mass stays done (%s, %s)" % [status(s.mass), log_keys(s.mass)])
	var back: ContentLayer = VaultStore.restore_from_trash(s.trash_rel, s.rel)
	check(back != null and back.title == "Physics (2)" and demo_keys(s.mass) == ["Physics (2)#quiz0"] and log_keys(s.mass) == ["Physics (2)#quiz0"],
		"…and the restore as “Physics (2)” finds them with no score of the imported note's (%s, %s)" % [demo_keys(s.mass), log_keys(s.mass)])
	for n in [back, imported]:
		VaultStore.trash_note(n)

	# The MCP server's create_note: another process, which knows nothing of
	# the app's trash; the app lists the note on its next rescan
	s = trashed_physics()
	var made: Dictionary = VaultTools.new(V).call_tool("create_note", {"title": "Physics", "markdown": "made by Claude"})
	VaultStore.refresh_note_list(true)
	check(not made.get("isError", true) and titled("Physics").size() == 1, "(the MCP server writes a note titled Physics, and a rescan lists it)")
	check(JourneyStore.log_score("Physics#quiz0", 0, 3) == 0 and status(s.mass) == "done",
		"a note the MCP server makes with a trashed note's title never logs to its objectives: Mass stays done (%s, %s)" % [status(s.mass), log_keys(s.mass)])
	var mcp_note: ContentLayer = titled("Physics")[0] if titled("Physics").size() == 1 else null
	back = VaultStore.restore_from_trash(s.trash_rel, s.rel)
	check(back != null and back.title == "Physics (2)" and demo_keys(s.mass) == ["Physics (2)#quiz0"] and log_keys(s.mass) == ["Physics (2)#quiz0"],
		"…and the restore as “Physics (2)” finds them with no score of the MCP note's (%s, %s)" % [demo_keys(s.mass), log_keys(s.mass)])
	for n in [back, mcp_note]:
		VaultStore.trash_note(n)

	# The trashed file moved back by hand (a file manager): that note itself
	s = trashed_physics()
	check(DirAccess.rename_absolute(V + s.trash_rel, V + s.rel) == OK, "(Physics' file is moved back out of the trash by hand)")
	VaultStore.refresh_note_list(true)
	check(titled("Physics").size() == 1 and demo_keys(s.mass) == ["Physics#quiz0"] and JourneyStore.log_score("Physics#quiz0", 3, 3) == 1,
		"a trashed note moved back by hand keeps its objectives: Mass's demo stays Physics' and its quiz logs to it (%s)" % [demo_keys(s.mass)])
	for n in titled("Physics"):
		VaultStore.trash_note(n)

	# Two notes titled Physics (one written outside the app): trashing one
	# leaves the other its objectives, as before
	JourneyStore.reset()
	var mass: Dictionary = JourneyStore.add_objective(JourneyStore.add_topic("Science").id, "Mass")
	var physics: ContentLayer = make_note("Physics", "", "physics words")
	var twin := ContentLayer.new()
	twin.title = "Physics"
	twin.raw_text = "the same title, written outside the app"
	ResourceSaver.save(twin, V + "note_physics_twin.tres")
	VaultStore.refresh_note_list(true)
	JourneyStore.add_demo(mass.id, "Physics#quiz0")
	JourneyStore.log_score("Physics#quiz0", 3, 3)
	check(titled("Physics").size() == 2, "(two notes are titled Physics)")
	VaultStore.trash_note(physics)
	check(demo_keys(mass) == ["Physics#quiz0"] and JourneyStore.log_score("Physics#quiz0", 3, 3) == 1,
		"trashing one of two notes titled Physics leaves Mass to the one listed with it before (%s)" % [demo_keys(mass)])
	for n in titled("Physics"):
		VaultStore.trash_note(n)
	TestVault.remove_tree(ext)
	JourneyStore.reset()


# ── VaultStore.delete_folder: the vault's .trash when the system trash fails ─

func store_delete_folder() -> void:
	VaultStore.create_folder("Old")
	VaultStore.create_folder("Inner", "Old")
	make_note("Old One", "Old", "old one")
	make_note("Old Two", "Old/Inner", "old two")
	var att := FileAccess.open(V + "Old/attachment.txt", FileAccess.WRITE)
	att.store_string("not a note")
	att.close()
	var before: Dictionary = {}
	for f in VaultStore._files_under(V + "Old/"):
		before[f] = FileAccess.get_sha256(V + "Old/" + f)
	var asked: Array = []
	VaultStore.system_trash_hook = func(p: String) -> Error:
		asked.append(p)
		return FAILED
	check(VaultStore.delete_folder("Old"), "delete_folder succeeds when the system trash fails")
	check(asked == [V + "Old"], "…after trying the system trash first")
	check(not DirAccess.dir_exists_absolute(V + "Old") and DirAccess.dir_exists_absolute(V + ".trash/Old"), "…by moving the folder to .trash/Old")
	var kept: bool = before.size() == 3
	for f in before:
		kept = kept and FileAccess.get_sha256(V + ".trash/Old/" + f) == before[f]
	check(kept, "…with every file in it, unchanged %s" % str(before.keys()))
	check(VaultStore.get_note_index("Old One") < 0 and VaultStore.get_note_index("Old Two") < 0 and not VaultStore.folders.has("Old"), "…and its notes leave the list")

	VaultStore.create_folder("Old")
	make_note("Old Three", "Old", "old three")
	check(VaultStore.delete_folder("Old"), "(a second folder Old is deleted)")
	var gone: Array = Array(DirAccess.get_directories_at(V + ".trash")).filter(func(d): return str(d).begins_with("Old (deleted "))
	check(gone.size() == 1 and FileAccess.file_exists(V + ".trash/" + gone[0] + "/note_old_three.tres") and DirAccess.dir_exists_absolute(V + ".trash/Old/Inner"), "a second folder of that name gets a \"(deleted …)\" suffix; the first stays")

	# Neither trash takes it (the system trash fails, .trash is read-only):
	# the folder stays, nothing is removed, and delete_folder says so.
	VaultStore.create_folder("Stuck")
	make_note("Stuck Note", "Stuck", "stuck words")
	if OS.get_name() in ["Linux", "macOS"]:
		OS.execute("chmod", ["555", V + ".trash"])
		check(not VaultStore.delete_folder("Stuck"), "delete_folder returns false when no trash takes the folder")
		check(FileAccess.get_file_as_string(V + "Stuck/note_stuck_note.tres").contains("stuck words") and VaultStore.get_note_index("Stuck Note") >= 0, "…and the folder and its note stay")
		OS.execute("chmod", ["755", V + ".trash"])
	VaultStore.system_trash_hook = Callable()


# ── UI: Delete button, restore from the palette and with Ctrl+Z ─────────────

func ui_delete_and_restore() -> void:
	var c: ContentLayer = make_note("Charlie", "", "charlie words")
	var c_path: String = c.resource_path
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.open_note_by_title("Charlie")
	await frames(2)
	check(app.current_note == c and app._note_buttons.has(c), "(Charlie is open, with a sidebar row)")

	var delete_btn: Button = app.get_node("%DeleteButton")
	await click(delete_btn)
	check(not FileAccess.file_exists(c_path) and FileAccess.file_exists(V + ".trash/note_charlie.tres"), "clicking Delete moves the note's file to .trash")
	check(not app._note_buttons.keys().any(func(n): return n.title == "Charlie"), "…removes its row from the sidebar")
	check(app.status_label.text.contains("trash"), "…and the status says where it went (%s)" % app.status_label.text)
	check(app.current_note == null or app.current_note.title != "Charlie", "…and another note (or the empty state) shows")
	check(get_root().find_children("*", "ConfirmationDialog", true, false).filter(func(d): return d.visible).is_empty(), "…without a confirmation dialog")

	app._execute_command("restore_trash")
	await frames(2)
	check(FileAccess.file_exists(c_path) and not FileAccess.file_exists(V + ".trash/note_charlie.tres"), "\"Restore last deleted note\" puts the file back at its original path")
	check(app.current_note != null and app.current_note.resource_path == c_path and app.raw_text_layer.text == "charlie words", "…and opens it")
	check(app._note_buttons.keys().any(func(n): return n.title == "Charlie"), "…with its sidebar row back")

	# A pending edit is saved before the delete, so a restore brings it back
	app.raw_text_layer.text = "charlie words, typed just before Delete"
	app.raw_text_layer.text_changed.emit()
	await click(delete_btn)
	check(FileAccess.get_file_as_string(V + ".trash/note_charlie.tres").contains("typed just before Delete"), "an edit typed just before Delete goes to the trash with the note")
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(app.current_note != null and app.current_note.resource_path == c_path and app.raw_text_layer.text.contains("typed just before Delete"), "Ctrl+Z outside the editor restores the deleted note, last words included")
	check(app.status_label.text.contains("Restored"), "…and says so (%s)" % app.status_label.text)

	app._execute_command("restore_trash")
	await frames(1)
	check(app.status_label.text.contains("No deleted note"), "with nothing left to restore, the palette command says so")

	app._build_palette_items("")
	var labels: Array = app._palette_items.map(func(i): return str(i.label))
	check(labels.any(func(l): return l.contains("Restore last deleted note")) and labels.any(func(l): return l.contains("Show trash folder")), "the palette offers Restore last deleted note and Show trash folder %s" % str(labels))

	await ui_context_menu_delete(app)
	await ui_restore_taken_title(app)
	if OS.get_name() in ["Linux", "macOS"]:
		await ui_delete_unsaved(app)
		await ui_held_words_kept(app)

	app.queue_free()
	await frames(2)


## The context menu's "Delete note", right after typing in the editor: the
## status promises Ctrl+Z, so the very next Ctrl+Z restores the note (the
## editor, whose undo would swallow it, has let go of the keyboard).
func ui_context_menu_delete(app: Control) -> void:
	var delta: ContentLayer = make_note("Delta", "", "delta words")
	var echo: ContentLayer = make_note("Echo", "", "echo words")
	var echo_path: String = echo.resource_path
	app._refresh_note_list()
	app._open_note(delta)
	app._switch_layer("raw")   # the editor has the keyboard, as while typing
	await frames(2)
	check(app.raw_text_layer.has_focus(), "(Delta is open and the editor has focus)")
	await right_click(app._note_buttons[echo])
	check(app._ctx_target.get("note") == echo and app.raw_text_layer.has_focus(), "(right-clicking Echo's row opens its menu; the editor keeps focus)")
	app._ctx_menu.id_pressed.emit(13)
	app._ctx_menu.hide()
	await frames(2)
	check(not FileAccess.file_exists(echo_path) and FileAccess.file_exists(V + ".trash/note_echo.tres"), "the context menu's Delete note moves the note to .trash")
	check(app.status_label.text.contains("Ctrl+Z to restore"), "…and the status offers Ctrl+Z (%s)" % app.status_label.text)
	await press_ctrl(KEY_Z)   # no click elsewhere first
	var focus: Control = get_root().gui_get_focus_owner()
	check(FileAccess.file_exists(echo_path) and app.current_note != null and app.current_note.resource_path == echo_path, "the next Ctrl+Z restores it (focus: %s, status: %s)" % [focus.name if focus else "none", app.status_label.text])


## Delete Chemistry, rename Lab to Chemistry, then "Restore last deleted
## note": the deleted note comes back as "Chemistry (2)" with its own quiz
## pass, and the renamed note keeps its own result.
func ui_restore_taken_title(app: Control) -> void:
	ProgressStore.reset()
	var chem: ContentLayer = make_note("Chemistry", "", "chemistry words")
	var lab: ContentLayer = make_note("Lab", "", "lab words")
	ProgressStore.record_result("Chemistry", 0, 2, 2)
	ProgressStore.record_result("Lab", 0, 0, 2)
	JourneyStore.reset()
	var reactions: Dictionary = JourneyStore.add_objective(JourneyStore.add_topic("Science").id, "Reactions")
	JourneyStore.add_demo(reactions.id, "Chemistry#quiz0")
	JourneyStore.log_score("Chemistry#quiz0", 2, 2)
	app._refresh_note_list()
	app._open_note(chem)
	await frames(2)
	await click(app.get_node("%DeleteButton"))
	check(VaultStore.note_list.find(chem) < 0, "(Chemistry is deleted)")
	app._open_note(lab)
	await frames(2)
	check(app._rename_current("Chemistry") and lab.title == "Chemistry", "(Lab is renamed to the deleted note's title)")
	app._execute_command("restore_trash")
	await frames(2)
	var back: ContentLayer = app.current_note
	check(back != null and back.title == "Chemistry (2)" and app.raw_text_layer.text == "chemistry words", "restoring a deleted note whose title another note took opens it as “Chemistry (2)” (%s)" % (back.title if back else "null"))
	check(titled("Chemistry").size() == 1 and titled("Chemistry (2)").size() == 1, "…so no two notes share a title")
	check(ProgressStore.quiz_passed("Chemistry (2)", 0) and not ProgressStore.quiz_passed("Chemistry", 0), "…it has its own 2/2 pass, and the renamed note its own 0/2")
	check(demo_keys(reactions) == ["Chemistry (2)#quiz0"] and JourneyStore.objective_status(JourneyStore.find_objective(reactions.id)) == "done",
		"…its Journey objective follows it, still done (%s)" % [demo_keys(reactions)])
	check(app.status_label.text.contains("Chemistry (2)"), "…and the status says which title it came back with (%s)" % app.status_label.text)
	for n in [back, lab]:
		if n != null:
			VaultStore.trash_note(n)
	JourneyStore.reset()
	app._refresh_note_list()


## A note whose save failed (read-only file) is deleted: the trash holds the
## file as last saved, and a restore brings back the words that file lacks.
func ui_delete_unsaved(app: Control) -> void:
	var locked: ContentLayer = make_note("Locked", "", "old saved words")
	var path: String = locked.resource_path
	app._refresh_note_list()
	app._open_note(locked)
	app._switch_layer("raw")
	await frames(1)
	OS.execute("chmod", ["444", path])
	app.raw_text_layer.text = "old saved words + AN HOUR OF NEW WORK"
	app.raw_text_layer.text_changed.emit()
	app._flush_pending_save()
	check(app.status_label.text.begins_with("Couldn't save “Locked”") and app._unsaved.has(locked), "(the save of Locked fails: %s)" % app.status_label.text)

	app._on_delete_note_pressed()
	await frames(2)
	check(not FileAccess.file_exists(path) and FileAccess.get_file_as_string(V + ".trash/note_locked.tres").contains("old saved words"), "a note whose save failed still moves to the trash")
	check(app.status_label.text.contains("couldn't save") and app.status_label.text.contains("Ctrl+Z"), "…and the status says the trash file lacks the words, and Ctrl+Z brings them back (%s)" % app.status_label.text)
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(FileAccess.file_exists(path) and app.current_note != null and app.current_note.resource_path == path, "Ctrl+Z restores the note")
	check(app.raw_text_layer.text == "old saved words + AN HOUR OF NEW WORK" and app.current_note.raw_text == app.raw_text_layer.text, "…with the words it couldn't save (%s)" % app.raw_text_layer.text)
	check(app._unsaved.has(app.current_note) and app.status_label.text.contains("Couldn't save “Locked”"), "…still waiting to be saved, and saying so (%s)" % app.status_label.text)
	OS.execute("chmod", ["644", path])
	app._flush_pending_save()
	check(FileAccess.get_file_as_string(path).contains("AN HOUR OF NEW WORK") and app._unsaved.is_empty(), "once the file is writable again the words reach the disk")


## Open a new note `title` in `folder` holding `saved`, make its file
## read-only, type `typed` after it (the save fails) and press Delete.
## Returns {note, path (where it was), trash (its file now), failed}.
func delete_unsaved(app: Control, title: String, folder: String, saved: String, typed: String) -> Dictionary:
	var n: ContentLayer = make_note(title, folder, saved)
	var path: String = n.resource_path
	app._refresh_note_list()
	app._open_note(n)
	app._switch_layer("raw")
	await frames(1)
	OS.execute("chmod", ["444", path])
	app.raw_text_layer.text = saved + typed
	app.raw_text_layer.text_changed.emit()
	app._flush_pending_save()
	var failed: bool = app._unsaved.has(n)
	app._on_delete_note_pressed()
	await frames(2)
	var trash: String = V + str(app._trashed.back().trash_rel) if not app._trashed.is_empty() else ""
	return {"note": n, "path": path, "trash": trash, "failed": failed and not FileAccess.file_exists(path)}


## After that delete, the words its save couldn't write live only in the
## delete's entry. A vault switch, which forgets the deletes, waits for them
## as it waits for an unsaved note; a restore whose file has left the trash
## (the user emptied it) writes the note again from them; and a restore that
## can't do even that keeps them for another try. They are never dropped.
func ui_held_words_kept(app: Control) -> void:
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	var V2: String = ProjectSettings.globalize_path("user://test-vault-trash-2/")
	TestVault.remove_tree(V2)
	DirAccess.make_dir_recursive_absolute(V2)

	# The vault switch waits
	var d1: Dictionary = await delete_unsaved(app, "Held", "", "held saved words", " + AN HOUR OF NEW WORK")
	check(d1.failed and app._unsaved.is_empty() and app._trashed.back().has("unsaved"), "(Held's save failed and it was deleted: only the delete holds its new words)")
	app.switch_vault(V2)
	await frames(2)
	check(VaultStore.vault_path == V and app._trashed.size() > 0 and app._trashed.back().title == "Held", "a vault switch waits while a deleted note's unsaved words wait for a restore")
	check(app.status_label.text.begins_with("Didn't switch vaults.") and app.status_label.text.contains("“Held” is in the trash without the words it couldn't save"), "…and says why (%s)" % app.status_label.text)
	if VaultStore.vault_path != V:
		app.switch_vault(V)   # the switch went through: come back for the rest
		await frames(2)
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(app.current_note == d1.note and app.raw_text_layer.text == "held saved words + AN HOUR OF NEW WORK", "…so Ctrl+Z still restores the note with them (%s)" % app.raw_text_layer.text)
	OS.execute("chmod", ["644", d1.path])
	app._flush_pending_save()
	check(FileAccess.get_file_as_string(d1.path).contains("AN HOUR OF NEW WORK") and app._unsaved.is_empty(), "(…and they reach the disk once the file is writable)")

	# The trash was emptied: the note is written again from the kept words
	var d2: Dictionary = await delete_unsaved(app, "Held Two", "", "two saved words", " + TWO'S NEW WORK")
	check(d2.failed and FileAccess.file_exists(d2.trash), "(Held Two's save failed and its file went to the trash)")
	DirAccess.remove_absolute(d2.trash)   # the user empties the trash
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	check(FileAccess.get_file_as_string(d2.path).contains("TWO'S NEW WORK"), "a restore whose file left the trash writes the note again, with the words it couldn't save")
	check(app.current_note == d2.note and app.current_note.resource_path == d2.path and app.raw_text_layer.text == "two saved words + TWO'S NEW WORK", "…opens it, the same note object (its undo history follows it)")
	check(app._note_buttons.has(d2.note) and app._trashed.size() == 0 and app._unsaved.is_empty(), "…in the sidebar, with nothing left to restore or save")
	check(app.status_label.text.begins_with("Restored “Held Two”") and app.status_label.text.contains("no longer in"), "…and says how (%s)" % app.status_label.text)
	app.raw_text_layer.text = "two saved words + TWO'S NEW WORK, edited again"
	app.raw_text_layer.text_changed.emit()
	app._flush_pending_save()
	check(VaultStore.last_conflict_copy == null and FileAccess.get_file_as_string(d2.path).contains("edited again"), "…and its next edit saves in place (no conflict copy)")

	# Nor can it be written there (a read-only folder): the words stay for another try
	VaultStore.create_folder("Shut")
	var d3: Dictionary = await delete_unsaved(app, "Held Three", "Shut", "three saved words", " + THREE'S NEW WORK")
	check(d3.failed and FileAccess.file_exists(d3.trash), "(Held Three's save failed and its file went to the trash)")
	DirAccess.remove_absolute(d3.trash)
	OS.execute("chmod", ["555", V + "Shut"])
	get_root().gui_release_focus()
	await press_ctrl(KEY_Z)
	var kept: bool = not app._trashed.is_empty() and app._trashed.back().title == "Held Three" and str(app._trashed.back().get("unsaved", {}).get("raw_text", "")).contains("THREE'S NEW WORK")
	check(not FileAccess.file_exists(d3.path) and kept, "a restore that can't write the note again keeps its words")
	check(app.status_label.text.begins_with("Couldn't restore “Held Three”") and app.status_label.text.contains("words are kept"), "…and says so (%s)" % app.status_label.text)
	check(DirAccess.get_files_at(V + VaultStore.TMP_DIR).is_empty(), "…leaving no temp file behind")
	OS.execute("chmod", ["755", V + "Shut"])
	await press_ctrl(KEY_Z)
	check(FileAccess.get_file_as_string(d3.path).contains("THREE'S NEW WORK") and app.current_note == d3.note and app._trashed.is_empty(), "restoring again once the folder is writable brings it back with its words")

	# Its file is in the trash but can't move back (its folder went read-only): kept the same way
	var d4: Dictionary = await delete_unsaved(app, "Held Four", "Shut", "four saved words", " + FOUR'S NEW WORK")
	check(d4.failed and FileAccess.file_exists(d4.trash), "(Held Four's save failed and its file went to the trash)")
	OS.execute("chmod", ["555", V + "Shut"])
	app._execute_command("restore_trash")
	kept = not app._trashed.is_empty() and app._trashed.back().title == "Held Four" and str(app._trashed.back().get("unsaved", {}).get("raw_text", "")).contains("FOUR'S NEW WORK")
	check(not FileAccess.file_exists(d4.path) and FileAccess.file_exists(d4.trash) and kept, "a restore that can't move the file back keeps the words with it")
	check(app.status_label.text.begins_with("Couldn't restore “Held Four”: it is still in .trash/") and app.status_label.text.contains("words are kept"), "…and says where it is (%s)" % app.status_label.text)
	OS.execute("chmod", ["755", V + "Shut"])
	app._execute_command("restore_trash")
	check(app.current_note == d4.note and app.raw_text_layer.text == "four saved words + FOUR'S NEW WORK" and app._trashed.is_empty(), "restoring again brings it back with them")
	OS.execute("chmod", ["644", d4.path])
	app._flush_pending_save()
	check(FileAccess.get_file_as_string(d4.path).contains("FOUR'S NEW WORK") and app._unsaved.is_empty(), "(…and they reach the disk)")
	check(VaultStore.recreate_note(".trash/nowhere.tres", "../outside.tres", {"title": "Odd"}) == null and VaultStore.last_save_error != "", "recreate_note writes nothing outside the vault, and says why")

	if VaultStore.vault_path != V:
		app.switch_vault(V)
	if registry_backup != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	TestVault.remove_tree(V2)
