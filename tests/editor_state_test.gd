extends SceneTree
## What the window shows follows the vault: Graph view switched to another
## vault draws that vault's graph. A title typed into the focused title
## field is never dropped when the open note is replaced without the field
## losing focus (Ctrl+N, a Read view [[link]], the disk watcher). The app's
## own vault change right after another program edited the open note never
## hides that edit from the watcher.
##   headless:  godot --headless --path . -s res://tests/editor_state_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VAULT_NAME: String = "editor-state"

var fails: int = 0
var app: Control
var V: String = ""


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## A note `title` holding `body`, saved, with a fixed `modified` so the
## newest-first order is known.
func make_note(title: String, body: String, modified: String = "") -> ContentLayer:
	var n: ContentLayer = VaultStore.create_note(title)
	n.raw_text = body
	if modified != "":
		n.modified = modified
	VaultStore.save_note(n, modified == "")
	return n


## Press and release `code` with real key events.
func key(code: Key, mods: Dictionary = {}) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.ctrl_pressed = mods.get("ctrl", false)
		e.shift_pressed = mods.get("shift", false)
		e.pressed = pressed
		get_root().push_input(e)
	await frames(2)


## Type `s` with real key events into whatever has the keyboard.
func type_text(s: String) -> void:
	for ch in s:
		var e := InputEventKey.new()
		e.pressed = true
		e.unicode = ch.unicode_at(0)
		e.keycode = KEY_SPACE if ch == " " else OS.find_keycode_from_string(ch.to_upper())
		get_root().push_input(e)
		await process_frame
	await frames(1)


func titles() -> Array[String]:
	var out: Array[String] = []
	for n in VaultStore.note_list:
		out.append(n.title)
	out.sort()
	return out


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_editor_state.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_editor_state.json"   # never touch real progress
	ProgressStore.reset()
	TestVault.open(VAULT_NAME + "-other", false)   # another vault, with one note
	VaultStore.create_note("Lone")
	V = TestVault.open(VAULT_NAME, false)
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	make_note("Alpha", "Links to [[Beta]].", "2026-01-02T10:00:00")
	make_note("Beta", "Plain.", "2026-01-01T10:00:00")
	VaultStore.refresh_note_list()
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)

	await graph_follows_vault_switch()
	await typed_title_kept()
	await own_change_shows_outside_edit("create_folder")
	await own_change_shows_outside_edit("move_note_to")
	await own_change_shows_outside_edit("new_note")

	if VaultStore.vault_path != V:
		app.switch_vault(V)
	app.queue_free()
	await frames(2)
	if registry_backup != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	TestVault.remove_tree(V)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


## Switching vaults from Graph view stays in Graph view and draws the new
## vault's graph: an empty vault's is empty (it used to keep showing the old
## vault's nodes, which opened nothing), and a vault with notes no longer
## drops to Edit view.
func graph_follows_vault_switch() -> void:
	app._switch_layer("graph")
	await frames(3)
	check(app._graph_nodes.size() == 2, "(Graph view shows this vault's two notes)")
	var empty: String = ProjectSettings.globalize_path("user://test-vault-%s-empty/" % VAULT_NAME)
	var other: String = ProjectSettings.globalize_path("user://test-vault-%s-other/" % VAULT_NAME)
	TestVault.remove_tree(empty)
	DirAccess.make_dir_recursive_absolute(empty)
	app.switch_vault(empty)
	await frames(3)
	check(VaultStore.vault_path == empty and app.current_mode == "graph" and app.graph_layer.visible, "a switch to an empty vault stays in Graph view")
	check(app._graph_nodes.is_empty() and app.graph_layer._nodes.is_empty(), "…and shows no node of the vault left (%s)" % [app._graph_nodes.keys()])
	app.switch_vault(other)
	await frames(3)
	check(app.current_mode == "graph" and app.graph_layer.visible, "a switch to a vault with notes stays in Graph view (%s)" % app.current_mode)
	check(app._graph_nodes.keys() == [other + "note_lone.tres"], "…and draws that vault's notes (%s)" % [app._graph_nodes.keys()])
	app.switch_vault(V)
	await frames(3)
	check(app.current_mode == "graph" and app._graph_nodes.size() == 2 and app._graph_nodes.keys().all(func(k: String) -> bool: return k.begins_with(V)), "…and back, this vault's graph again")
	app._switch_layer("raw")
	for p in [empty, other]:
		TestVault.remove_tree(p)


## The title commits on Enter or focus-out. Ctrl+N, a [[link]] in Read view
## (a RichTextLabel takes no focus) and the watcher reopening the note after
## an outside edit replaced the note while the field kept the keyboard, and
## the typed title was gone.
func typed_title_kept() -> void:
	# Ctrl+N, type a title, Ctrl+N again
	app._open_note(app._note_at_path(V + "note_alpha.tres"))
	app._switch_layer("raw")
	await key(KEY_N, {"ctrl": true})
	var first: ContentLayer = app.current_note
	check(app.title_edit.has_focus() and first.title == "untitled", "(Ctrl+N made a note and put the keyboard in its title)")
	await type_text("Shopping")
	await key(KEY_N, {"ctrl": true})
	check(app.current_note != first and first.title == "Shopping", "Ctrl+N from the title field keeps the title typed there (%s)" % first.title)
	check(FileAccess.get_file_as_string(first.resource_path).contains("Shopping"), "…on disk")

	# A [[link]] in Read view
	var alpha: ContentLayer = app._note_at_path(V + "note_alpha.tres")
	app._open_note(alpha)
	app._switch_layer("visual")
	app.title_edit.grab_focus()
	app.title_edit.text = "Alpha Linked"
	await frames(1)
	app.open_note_by_title("Beta", true)   # what a click on [[Beta]] runs; the focus stays in the title field
	check(app.current_note != null and app.current_note.title == "Beta", "(the link opened Beta)")
	check(alpha.title == "Alpha Linked", "a Read view link keeps the title typed for the note left (%s)" % alpha.title)
	app._switch_layer("raw")

	# The watcher reopens the note after an outside edit of its body
	var beta: ContentLayer = app.current_note
	app.title_edit.grab_focus()
	app.title_edit.text = "Beta Typed"
	app.title_edit.caret_column = 4
	await create_timer(1.1).timeout   # a later mtime second than the app's last write
	var raw: String = FileAccess.get_file_as_string(beta.resource_path)
	var f := FileAccess.open(beta.resource_path, FileAccess.WRITE)
	f.store_string(raw.replace("Plain.", "Plain, and a line from outside."))
	f.close()
	app.check_disk_changes()
	check(app.raw_text_layer.text.contains("a line from outside"), "(the watcher showed the outside edit)")
	check(app.title_edit.text == "Beta Typed" and app.title_edit.caret_column == 4, "…and left the typed title in the field, caret and all (%s)" % app.title_edit.text)
	get_root().gui_release_focus()
	await frames(1)
	check(beta.title == "Beta Typed" and beta.raw_text.contains("a line from outside"), "leaving the field renames the note, keeping the outside edit (%s)" % beta.title)
	check(not titles().any(func(t: String) -> bool: return t.contains("conflict copy")), "…with no conflict copy (%s)" % [titles()])


## Another program rewrites the open note (Claude's update_note, a sync
## tool), and within the watcher's 1.5 s the user makes a folder, moves
## another note or presses Ctrl+N. That change's rescan leaves the open
## note's outside edit pending for the watcher, which then shows it: the
## change used to take the disk as seen (_last_sig), so the editor kept the
## old text and the next keystroke made a spurious conflict copy.
func own_change_shows_outside_edit(op: String) -> void:
	var n: ContentLayer = make_note("Watched " + op, "old text of " + op)
	var other: ContentLayer = make_note("Bystander " + op, "bystander")
	app._open_note(n)
	app._switch_layer("raw")
	await create_timer(1.1).timeout   # a later mtime second than the app's own write
	var raw: String = FileAccess.get_file_as_string(n.resource_path)
	var f := FileAccess.open(n.resource_path, FileAccess.WRITE)
	f.store_string(raw.replace("old text of", "NEW TEXT FROM OUTSIDE for"))
	f.close()
	match op:
		"create_folder":
			app.create_folder("Fresh " + str(Time.get_ticks_msec()))
		"move_note_to":
			app.create_folder("Dest")
			app.move_note_to(other, "Dest")
		"new_note":
			app._on_new_note_pressed()
	for i in range(3):
		app.check_disk_changes()
	if op == "new_note":
		check(n.raw_text.begins_with("NEW TEXT FROM OUTSIDE"), "after Ctrl+N the note left shows its outside edit (%s)" % n.raw_text)
		app._open_note(n)
	check(app.current_note == n and app.raw_text_layer.text.begins_with("NEW TEXT FROM OUTSIDE"), "%s right after an outside edit: the editor shows the edit (%s)" % [op, app.raw_text_layer.text])
	app.raw_text_layer.text += " + typed"
	app.raw_text_layer.text_changed.emit()
	app._flush_pending_save()
	check(app.current_note == n and app.status_label.text == "Saved" and FileAccess.get_file_as_string(n.resource_path).contains("NEW TEXT FROM OUTSIDE"), "…and typing saves over it, no conflict copy (%s)" % app.status_label.text)
