extends SceneTree
## Conflicts: when a note's file changed on disk since the app read it (a sync
## tool, another editor, Claude via MCP), saving keeps the outside version and
## writes the app's version as "<title> (conflict copy)". Nothing is lost.
##   headless:  godot --headless --path . -s res://tests/conflict_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## Another program rewrites the note's file: same .tres, new body text.
func outside_edit(note: ContentLayer, from: String, to: String) -> void:
	var path: String = note.resource_path
	var text: String = FileAccess.get_file_as_string(path)
	check(text.contains(from), "(outside edit finds \"%s\" on disk)" % from)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text.replace(from, to))
	f.close()


func body_on_disk(note_path: String) -> String:
	return FileAccess.get_file_as_string(note_path)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_conflict.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_conflict.json"   # never touch real progress
	ProgressStore.reset()
	var V: String = TestVault.open("conflict", false)
	await frames(2)

	# ── Store ──
	VaultStore.create_folder("Sub")
	var a: ContentLayer = VaultStore.create_note("Alpha", "Sub")
	a.raw_text = "first draft"
	VaultStore.save_note(a)
	var a_path: String = a.resource_path
	a.raw_text = "second draft"
	VaultStore.save_note(a)
	check(VaultStore.last_conflict_copy == null and body_on_disk(a_path).contains("second draft"), "the app's own saves never conflict")

	outside_edit(a, "second draft", "edited elsewhere")
	a.raw_text = "my unsaved words"
	VaultStore.save_note(a)
	var copy: ContentLayer = VaultStore.last_conflict_copy
	check(body_on_disk(a_path).contains("edited elsewhere") and not body_on_disk(a_path).contains("my unsaved words"), "an outside edit is not overwritten")
	check(copy != null and copy.title == "Alpha (conflict copy)" and copy.raw_text == "my unsaved words", "the app's version becomes \"Alpha (conflict copy)\"")
	check(copy != null and FileAccess.file_exists(copy.resource_path) and VaultStore.folder_of(copy) == "Sub", "…saved next to the original, in Sub/ (%s)" % (copy.resource_path.get_file() if copy else ""))
	check(copy != null and copy.resource_path.get_file() == "note_alpha_conflict_copy.tres", "…with a portable file name")
	check(a.raw_text == "edited elsewhere", "the open note now shows the outside version (%s)" % a.raw_text)

	a.raw_text = "edited elsewhere, then by me"
	VaultStore.save_note(a)
	check(VaultStore.last_conflict_copy == null and body_on_disk(a_path).contains("then by me"), "after a conflict, the next save works normally")

	outside_edit(a, "then by me", "elsewhere again")
	a.raw_text = "mine again"
	VaultStore.save_note(a)
	check(VaultStore.last_conflict_copy != null and VaultStore.last_conflict_copy.title == "Alpha (conflict copy 2)", "a second conflict gets a new copy, not an overwrite")

	# An edit the disk watcher already reloaded is not a conflict
	OS.delay_msec(1100)   # mtimes are per second: the edit must land in a new second to be seen
	outside_edit(a, "elsewhere again", "seen by the watcher")
	VaultStore.refresh_note_list()
	a.raw_text = a.raw_text + " + mine"
	VaultStore.save_note(a)
	check(VaultStore.last_conflict_copy == null and body_on_disk(a_path).contains("seen by the watcher + mine"), "an outside edit the app reloaded is saved over normally")

	# Claude via MCP edits a note the app has open
	var b: ContentLayer = VaultStore.create_note("Beta")
	b.raw_text = "app text"
	VaultStore.save_note(b)
	var tools: RefCounted = VaultTools.new(V)
	var rel: String = b.resource_path.substr(V.length())
	var read: Dictionary = tools.call_tool("read_note", {"path": rel})
	var upd: Dictionary = tools.call_tool("update_note", {"path": rel, "hash": read.structuredContent.hash, "markdown": "claude text"})
	check(not upd.get("isError", false), "MCP update_note succeeds")
	b.raw_text = "app text, typed while Claude wrote"
	VaultStore.save_note(b)
	check(body_on_disk(b.resource_path).contains("claude text") and VaultStore.last_conflict_copy != null and VaultStore.last_conflict_copy.raw_text == "app text, typed while Claude wrote", "Claude's MCP edit survives; the app's typing is a conflict copy")

	# ── UI: typing while the file changes, then autosave ──
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.open_note_by_title("Alpha")
	await frames(2)
	outside_edit(app.current_note, "seen by the watcher + mine", "changed in Dropbox")
	app.raw_text_layer.text = "typed in the app"
	app._do_auto_save()
	await frames(2)
	check(app.current_note != null and app.current_note.title.begins_with("Alpha (conflict copy"), "the editor switches to the conflict copy (%s)" % (app.current_note.title if app.current_note else "none"))
	check(app.raw_text_layer.text == "typed in the app", "…so the typed words stay on screen")
	check(app.status_label.text.contains("changed on disk"), "…and the status bar says what happened (%s)" % app.status_label.text)
	check(body_on_disk(a_path).contains("changed in Dropbox"), "…while the outside version is kept")
	app.queue_free()
	await frames(2)

	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
