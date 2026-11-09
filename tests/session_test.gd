extends SceneTree
## Session restore: the app reopens the note and the view that were open when
## it closed (last_note / last_mode in <vault>/.ontomeme/ui.json, beside the
## sidebar's folds), follows that note when it moves, falls back to the newest
## note when it is gone, and never drops the other keys of ui.json.
##   headless:  godot --headless --path . -s res://tests/session_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const StarterContent = preload("res://starter_content.gd")

var fails: int = 0
var app: Control


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## A note with a fixed `modified`, so the sidebar's newest-first order is known.
func make_note(title: String, modified: String, folder: String = "") -> ContentLayer:
	var n: ContentLayer = VaultStore.create_note(title, folder)
	n.raw_text = title + " body"
	n.modified = modified
	VaultStore.save_note(n, false)
	return n


## Start the app the way a launch does: a fresh note.tscn on the open vault.
func launch() -> void:
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)


## Close it (free the main scene), as quitting does.
func quit_app() -> void:
	app.queue_free()
	app = null
	await frames(2)


func ui_json() -> Dictionary:
	var p: String = VaultStore.data_dir().path_join("ui.json")
	var json := JSON.new()
	if not FileAccess.file_exists(p) or json.parse(FileAccess.get_file_as_string(p)) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


func write_ui_json(ui: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(VaultStore.data_dir())
	var f := FileAccess.open(VaultStore.data_dir().path_join("ui.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(ui, "\t"))
	f.close()


func current() -> String:
	return app.current_note.title if app.current_note != null else "<none>"


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_session.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_session.json"   # never touch real progress
	ProgressStore.reset()
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""

	TestVault.open("session", false)
	VaultStore.create_folder("Course")
	VaultStore.create_folder("Archive")
	var a: ContentLayer = make_note("Alpha", "2026-01-01T10:00:00")
	var b: ContentLayer = make_note("Beta", "2026-01-02T10:00:00", "Course")
	var c: ContentLayer = make_note("Gamma", "2026-01-03T10:00:00")
	make_note("Old File", "2025-12-01T10:00:00", "Archive")
	VaultStore.refresh_note_list()
	# State other features keep in ui.json: it must survive every save below
	write_ui_json({"collapsed": ["Archive"], "sections_collapsed": ["pinned"], "tags_collapsed": true})

	# ── First launch without a session: today's fallback, the newest note ──
	await launch()
	check(app.current_note == c and app.current_mode == "raw", "with no session yet the newest note opens in Edit view (%s, %s)" % [current(), app.current_mode])
	check(app._collapsed.has("Archive"), "(the folds still load from ui.json)")

	# ── Open Beta (not the newest) in Read, close, launch again ──
	app._open_note(b)
	app._switch_layer("visual")
	await frames(2)
	var ui: Dictionary = ui_json()
	check(str(ui.get("last_note", "")) == "Course/" + b.resource_path.get_file() and str(ui.get("last_mode", "")) == "visual",
		"ui.json records the open note (vault-relative) and the view (%s, %s)" % [ui.get("last_note"), ui.get("last_mode")])
	check(ui.get("collapsed") == ["Archive"] and ui.get("sections_collapsed") == ["pinned"] and ui.get("tags_collapsed") == true,
		"…and keeps collapsed, sections_collapsed and tags_collapsed (%s)" % [ui])
	await quit_app()
	check(VaultStore.note_list[0] != b, "(Beta is still not the newest note)")
	await launch()
	check(app.current_note == b, "the next launch reopens Beta (%s)" % current())
	check(app.current_mode == "visual" and LayerEngine.current_mode == "visual", "…in Read view (%s, %s)" % [app.current_mode, LayerEngine.current_mode])
	check(app.note_content.visible and not app.empty_state_panel.visible and app.visual_layer.get_child_count() > 0, "…rendered")
	check(app._note_buttons.has(b) and (app._note_buttons[b] as Button).button_pressed, "…with Beta's sidebar row selected")
	check((app.layer_buttons.visual as Button).button_pressed, "…and the Read button pressed")

	# ── A folder toggle keeps the session, a session save keeps the folds ──
	app._toggle_folder("Course")
	ui = ui_json()
	check(str(ui.get("last_note", "")).ends_with(b.resource_path.get_file()) and (ui.get("collapsed") as Array).has("Course") and ui.get("tags_collapsed") == true,
		"folding a folder keeps last_note and the other keys (%s)" % [ui])
	app._toggle_folder("Course")

	# ── Graph and Journey are restored too ──
	app._switch_layer("graph")
	await frames(2)
	await quit_app()
	await launch()
	await frames(2)
	check(app.current_note == b and app.current_mode == "graph" and app.graph_layer.visible, "Graph view is restored, Beta still current (%s, %s)" % [current(), app.current_mode])
	app._switch_layer("journey")
	await frames(2)
	await quit_app()
	await launch()
	check(app.current_note == b and app.current_mode == "journey" and app.journey_panel.visible, "Journey is restored, Beta still current (%s, %s)" % [current(), app.current_mode])
	app._switch_layer("structured")
	await quit_app()
	await launch()
	check(app.current_mode == "structured" and LayerEngine.current_mode == "structured", "Outline view is restored (%s)" % app.current_mode)

	# ── The open note moves: the session follows it ──
	check(app.rename_folder("Course", "Lessons") == "Lessons", "(Beta's folder is renamed to Lessons)")
	check(str(ui_json().get("last_note", "")) == "Lessons/" + b.resource_path.get_file(), "renaming the open note's folder updates last_note (%s)" % ui_json().get("last_note"))
	check(app.move_note_to(b, ""), "(Beta moves to the top level)")
	check(str(ui_json().get("last_note", "")) == b.resource_path.get_file(), "moving the open note updates last_note (%s)" % ui_json().get("last_note"))
	await quit_app()
	await launch()
	check(app.current_note == b, "after a move the next launch still reopens Beta (%s)" % current())
	app._switch_layer("visual")

	# ── Beta is deleted between launches: the newest note opens instead ──
	await quit_app()
	VaultStore.delete_note(VaultStore.note_list.find(b))
	await launch()
	check(app.current_note == VaultStore.note_list[0] and app.current_note == c, "with Beta gone the newest note opens (%s)" % current())
	check(app.current_mode == "visual", "…in the view that was open (%s)" % app.current_mode)
	await quit_app()

	# ── A broken or foreign session is ignored ──
	write_ui_json({"collapsed": ["Archive"], "last_note": "../elsewhere/secret.tres", "last_mode": "bogus"})
	await launch()
	check(app.current_note == c and app.current_mode == "raw", "a last_note outside the vault and an unknown view fall back (%s, %s)" % [current(), app.current_mode])
	await quit_app()
	var bad := FileAccess.open(VaultStore.data_dir().path_join("ui.json"), FileAccess.WRITE)
	bad.store_string("{ not json")
	bad.close()
	await launch()
	check(app.current_note == c and app.current_mode == "raw", "an unreadable ui.json falls back (%s, %s)" % [current(), app.current_mode])
	app._open_note(a)
	check(str(ui_json().get("last_note", "")) == a.resource_path.get_file(), "…and the next save writes a good one")
	await quit_app()

	# ── Each vault keeps its own session: switching back reopens its note ──
	var v1: String = VaultStore.vault_path
	var v2: String = ProjectSettings.globalize_path("user://test-vault-session-2/")
	TestVault.remove_tree(v2)
	DirAccess.make_dir_recursive_absolute(v2)
	await launch()
	check(app.current_note == a, "(back in vault one on Alpha)")
	app.switch_vault(v2)
	var x: ContentLayer = make_note("Older", "2026-02-01T10:00:00")
	make_note("Newer", "2026-02-02T10:00:00")
	VaultStore.refresh_note_list()
	app._refresh_note_list()
	app._open_note(x)
	app.switch_vault(v1)
	await frames(1)
	check(app.current_note == a, "switching back to vault one reopens its last note, Alpha (%s)" % current())
	app.switch_vault(v2)
	await frames(1)
	check(current() == "Older", "…and vault two reopens Older, not its newest note (%s)" % current())
	app.switch_vault(v1)
	await quit_app()
	TestVault.remove_tree(v2)

	# ── The starter courses still fold in a vault that has only a session ──
	var v3: String = TestVault.open("session-starter", false)
	write_ui_json({"last_note": "x.tres", "last_mode": "visual"})
	StarterContent.seed_vault()
	ui = ui_json()
	check(ui.get("collapsed") is Array and (ui.collapsed as Array).has("Godot") and (ui.collapsed as Array).has(StarterContent.COURSE_FOLDER),
		"Add the tutorials folds the courses when ui.json holds only a session (%s)" % [ui.get("collapsed")])
	check(str(ui.get("last_note", "")) == "x.tres", "…and keeps the session")
	write_ui_json({"collapsed": ["Tutorials"]})
	StarterContent.seed_vault()
	check(ui_json().get("collapsed") == ["Tutorials"], "…but never overrides folds the user already has")
	TestVault.remove_tree(v3)

	if registry_backup != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	for p in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
