extends SceneTree
## The sidebar and search work from the keyboard alone, with real key events
## (get_root().push_input): Ctrl+Shift+E puts the focus on the open note's
## row, Up / Down walk the rows (never into the TAGS section or the toolbar),
## Enter opens, Right / Left expand, fold and go up a folder, Delete asks and
## then trashes the note (Backspace only on a Mac; a stray Backspace after a
## click, Enter or Down from search deletes nothing), F2 renames, Shift+F10
## or the Menu key opens the row's menu,
## Escape goes back to the editor, and Down in the search box enters the
## results.
##   headless:  godot --headless --path . -s res://tests/keyboard_nav_test.gd

const TestVault = preload("res://tests/test_vault.gd")

var fails: int = 0
var app: Control


## Records the keys no control took (an app-wide shortcut's turn), and takes
## none of them.
class UnhandledKeys extends Node:
	var seen: Array[Key] = []

	func _unhandled_input(event: InputEvent) -> void:
		var k := event as InputEventKey
		if k != null and k.pressed:
			seen.append(k.keycode)


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## A note with a fixed `modified`, so the sidebar's newest-first order is known.
func make_note(title: String, modified: String, body: String = "", tags: Array[String] = []) -> ContentLayer:
	var n: ContentLayer = VaultStore.create_note(title)
	n.raw_text = body
	n.modified = modified
	n.tags = tags
	VaultStore.save_note(n, false)
	return n


## Press and release `code` with real key events.
func key(code: Key, mods: Dictionary = {}) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.ctrl_pressed = mods.get("ctrl", false)
		e.meta_pressed = mods.get("meta", false)
		e.shift_pressed = mods.get("shift", false)
		e.alt_pressed = mods.get("alt", false)
		e.pressed = pressed
		get_root().push_input(e)
	await frames(2)


func type_text(s: String) -> void:
	for ch in s:
		var e := InputEventKey.new()
		e.pressed = true
		e.unicode = ch.unicode_at(0)
		e.keycode = KEY_SPACE if ch == " " else OS.find_keycode_from_string(ch.to_upper())
		get_root().push_input(e)
		await process_frame
	await frames(1)


## A real left click in the middle of `c`.
func click(c: Control) -> void:
	var pos: Vector2 = c.get_global_rect().get_center()
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	await frames(2)


## The open yes/no question whose text contains `what` ("" = any), or null.
func asking(what: String) -> ConfirmationDialog:
	for c in app.get_children():
		# (what == "" is spelled out: Godot's "…".contains("") is false)
		if c is ConfirmationDialog and c != app._prompt and c.visible and (what == "" or c.dialog_text.contains(what)):
			return c
	return null


func focused() -> Control:
	return get_root().gui_get_focus_owner()


func row_of(n: ContentLayer) -> Button:
	return app._note_buttons.get(n)


func current() -> String:
	return app.current_note.title if app.current_note != null else "<none>"


func focused_name() -> String:
	var f: Control = focused()
	if f == null:
		return "<nothing>"
	return (f as Button).text if f is Button else str(f.name)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_keynav.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_keynav.json"   # never touch real progress
	ProgressStore.reset()

	var vault: String = TestVault.open("keynav", false)
	var t_alpha: ContentLayer = make_note("Tutorial Alpha", "2026-01-06T10:00:00", "The first lesson.", ["lesson"])
	var t_beta: ContentLayer = make_note("Tutorial Beta", "2026-01-05T10:00:00", "The second lesson.", ["lesson"])
	var gamma: ContentLayer = make_note("Gamma Notes", "2026-01-04T10:00:00", "Plain notes.")
	var delta: ContentLayer = make_note("Delta Notes", "2026-01-03T10:00:00", "More notes.")
	var eps: ContentLayer = make_note("Epsilon Notes", "2026-01-02T10:00:00", "Old notes.")
	var zeta: ContentLayer = make_note("Zeta Notes", "2026-01-01T10:00:00", "Oldest notes.")
	VaultStore.refresh_note_list()

	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	check(app.current_note == t_alpha and app.tag_sidebar.visible, "(the newest note is open; the TAGS section shows above the list)")

	# ── Ctrl+Shift+E from the editor focuses the open note's row ──
	app.raw_text_layer.grab_focus()
	await frames(1)
	await key(KEY_E, {"ctrl": true, "shift": true})
	check(focused() == row_of(t_alpha), "Ctrl+Shift+E focuses the open note's row (%s)" % focused_name())
	check(current() == "Tutorial Alpha" and app.raw_text_layer.text == "The first lesson.", "…and types nothing into the note")

	# ── Down twice, Enter: the third visible note opens ──
	await key(KEY_DOWN)
	await key(KEY_DOWN)
	check(focused() == row_of(app._visible_notes[2]), "Down twice moves to the third row (%s)" % focused_name())
	await key(KEY_ENTER)
	check(app.current_note == app._visible_notes[2] and current() == "Gamma Notes", "Enter opens the third visible note (%s)" % current())
	check(focused() == row_of(gamma), "…and the keyboard stays on its row")

	# ── Up / Down stay on the rows at both ends ──
	for i in range(8):
		await key(KEY_UP)
	check(focused() == app._sidebar_rows()[0], "Up at the first row stays there, not in TAGS or the toolbar (%s)" % focused_name())
	for i in range(10):
		await key(KEY_DOWN)
	check(focused() == app._sidebar_rows()[-1] and focused() == row_of(zeta), "Down at the last row stays there (%s)" % focused_name())

	# ── Escape goes back to the editor ──
	await key(KEY_ESCAPE)
	check(focused() == app.raw_text_layer, "Escape from a row focuses the editor (%s)" % focused_name())

	# ── Cmd+Shift+E (a Mac) works the same ──
	await key(KEY_E, {"meta": true, "shift": true})
	check(focused() == row_of(gamma), "Cmd+Shift+E focuses the open note's row (%s)" % focused_name())

	# ── A rebuilt list keeps the keyboard on the same row ──
	await key(KEY_DOWN)
	app._refresh_note_list()
	await frames(1)
	check(focused() == row_of(delta), "a rebuild of the list keeps the focus on Delta's new row (%s)" % focused_name())

	# ── Folders: Left goes up to the folder, Left again folds it ──
	app.create_folder("Box")
	check(app.move_note_to(delta, "Box"), "(Delta Notes moves into Box)")
	app._open_note(delta)
	await key(KEY_E, {"ctrl": true, "shift": true})
	check(focused() == row_of(delta), "(Delta's row inside Box has the focus)")
	await key(KEY_LEFT)
	check(focused() == app._folder_buttons.get("Box"), "Left on a note inside a folder focuses the folder row (%s)" % focused_name())
	await key(KEY_LEFT)
	check(app._collapsed.has("Box"), "Left again folds the folder")
	check(focused() == app._folder_buttons.get("Box") and row_of(delta) == null, "…and the focus stays on its row (%s)" % focused_name())
	await key(KEY_RIGHT)
	check(not app._collapsed.has("Box") and focused() == app._folder_buttons.get("Box"), "Right expands it again (%s)" % focused_name())
	await key(KEY_RIGHT)
	check(focused() == row_of(delta), "Right on an expanded folder goes to its first row (%s)" % focused_name())
	await key(KEY_UP)
	await key(KEY_ENTER)
	check(app._collapsed.has("Box") and focused() == app._folder_buttons.get("Box"), "Enter on a folder row folds it")
	await key(KEY_ENTER)
	check(not app._collapsed.has("Box"), "…and Enter again unfolds it")

	# ── F2 renames: a folder's prompt, a note's title field ──
	await key(KEY_F2)
	check(app._prompt.visible and app._prompt.title == "Rename folder" and app._prompt_edit.text == "Box", "F2 on a folder row asks for its new name (%s)" % app._prompt.title)
	app._prompt.hide()
	await frames(1)
	app._folder_buttons.get("Box").grab_focus()
	await key(KEY_DOWN)
	await key(KEY_DOWN)
	check(focused() == row_of(t_alpha) and app.current_note == delta, "(Tutorial Alpha's row has the focus; Delta Notes is open)")
	# F2 on a note is the app's shared Rename prompt (gap-sidebar-rename, from
	# links-names), which renames the open note from _unhandled_input. The row
	# opens its own note and must leave the key to it, not take it.
	var probe := UnhandledKeys.new()
	get_root().add_child(probe)
	var shared_rename: bool = app.has_method("_rename_note_prompt")
	await key(KEY_F2)
	check(app.current_note == t_alpha, "F2 on a note row opens that row's note, so the rename is its own (%s)" % current())
	check(probe.seen.has(KEY_F2) or (shared_rename and app._prompt.visible), "…and leaves F2 to the app's shared Rename prompt instead of taking it")
	if shared_rename:
		check(app._prompt.visible and app._prompt.title == "Rename note" and app._prompt_edit.text == "Tutorial Alpha", "…which asks for the new title (%s)" % app._prompt.title)
		app._prompt.hide()
		await frames(1)
	else:
		check(focused() == row_of(t_alpha) and focused() != app.title_edit, "…and the keyboard stays on the row (%s)" % focused_name())
	probe.queue_free()

	# ── Shift+F10 and the Menu key open the row's menu ──
	await key(KEY_E, {"ctrl": true, "shift": true})
	await key(KEY_F10, {"shift": true})
	check(app._ctx_menu.visible and app._ctx_target.get("note") == t_alpha, "Shift+F10 opens the focused note's menu")
	check(app._ctx_menu.get_focused_item() == 0, "…with its first entry highlighted for the arrows")
	app._ctx_menu.hide()
	await frames(1)
	app._folder_buttons.get("Box").grab_focus()
	await key(KEY_MENU)
	check(app._ctx_menu.visible and app._ctx_target.get("rel") == "Box", "the Menu key opens the focused folder's menu")
	app._ctx_menu.hide()
	await frames(1)

	# ── A row keeps the keyboard after a click, after Enter, after Down from
	# search: a stray Backspace there (meant for the note or the search box)
	# must not delete anything ──
	app.backspace_deletes_rows = false   # Windows and Linux: Backspace is a text key
	var eps_path: String = eps.resource_path
	app.search_box.text = ""
	app._refresh_note_list()
	(app.note_list_container.get_parent() as ScrollContainer).ensure_control_visible(row_of(eps))
	await frames(1)
	await click(row_of(eps))
	check(app.current_note == eps and focused() == row_of(eps), "(a click on Epsilon's row opens it; its row keeps the keyboard)")
	await key(KEY_BACKSPACE)
	check(VaultStore.note_list.has(eps) and FileAccess.file_exists(eps_path) and asking("") == null, "Backspace after a click on a row deletes nothing and asks nothing")
	await key(KEY_F, {"ctrl": true})
	await type_text("Epsilon")
	await key(KEY_DOWN)
	check(focused() == row_of(eps), "(Down from the search box focuses the match)")
	await key(KEY_BACKSPACE)
	check(VaultStore.note_list.has(eps) and FileAccess.file_exists(eps_path) and asking("") == null, "Backspace after Down from the search box deletes nothing")
	app.search_box.text = ""
	app._refresh_note_list()
	app._open_note(zeta)
	await key(KEY_E, {"ctrl": true, "shift": true})
	await key(KEY_UP)
	await key(KEY_ENTER)
	check(app.current_note == eps and app.raw_text_layer.is_visible_in_tree() and focused() == row_of(eps), "(Enter on Epsilon's row opens it in Edit view, the row keeps the keyboard)")
	await key(KEY_BACKSPACE)
	check(VaultStore.note_list.has(eps) and FileAccess.file_exists(eps_path) and asking("") == null, "Backspace after Enter opened a note deletes nothing")
	app._folder_buttons.get("Box").grab_focus()
	await key(KEY_BACKSPACE)
	check(asking("") == null and VaultStore.folders.has("Box"), "Backspace on a folder row asks nothing")

	# ── Delete asks before it removes the focused note ──
	var trash_supported: bool = (load("res://vault_store.gd") as Script).get_script_method_list().any(func(m: Dictionary) -> bool: return m.name == "trash_note")
	var eps_rel: String = eps.resource_path.substr(VaultStore.vault_path.length())
	row_of(eps).grab_focus()
	await frames(1)
	await key(KEY_DELETE)
	var asked: ConfirmationDialog = asking("“Epsilon Notes”")
	check(asked != null and VaultStore.note_list.has(eps) and FileAccess.file_exists(eps_path), "Delete on a note row asks first and deletes nothing yet")
	await key(KEY_ESCAPE)
	check(asking("") == null and VaultStore.note_list.has(eps) and FileAccess.file_exists(eps_path), "Escape closes the question and keeps the note")
	check(focused() == row_of(eps), "…and the keyboard is back on its row (%s)" % focused_name())
	await key(KEY_DELETE)
	check(asking("“Epsilon Notes”") != null, "(Delete asks again)")
	await key(KEY_ENTER)
	await frames(2)
	check(asking("") == null and not VaultStore.note_list.has(eps) and not FileAccess.file_exists(vault.path_join(eps_rel)), "Enter on the question removes that note from the vault")
	if trash_supported:
		check(FileAccess.file_exists(vault.path_join(".trash").path_join(eps_rel)), "…into .trash")
	check(focused() == row_of(zeta), "…and the row now in its place has the focus (%s)" % focused_name())

	# ── On a Mac the Backspace key is labelled Delete: it asks too ──
	app.backspace_deletes_rows = true
	await key(KEY_BACKSPACE)
	asked = asking("“Zeta Notes”")
	check(asked != null and VaultStore.note_list.has(zeta), "Backspace on a Mac asks before deleting the focused note")
	await key(KEY_ENTER)
	await frames(2)
	check(not VaultStore.note_list.has(zeta), "…and deletes it once confirmed")
	check(focused() != null and focused().get_parent() == app.note_list_container, "…and the keyboard is still on a row (%s)" % focused_name())
	app.backspace_deletes_rows = false
	app._folder_buttons.get("Box").grab_focus()
	await key(KEY_DELETE)
	asked = asking("“Box”")
	check(asked != null and VaultStore.folders.has("Box"), "Delete on a folder row asks first and moves nothing yet")
	if asked != null:
		asked.hide()
		await frames(1)

	# ── The search box: Down enters the results, Enter opens one ──
	app._open_note(gamma)
	await key(KEY_F, {"ctrl": true})
	check(focused() == app.search_box, "(Ctrl+F focuses the search box)")
	await type_text("Tutorial")
	check(app._visible_notes.size() == 2 and app._visible_notes[0] == t_alpha, "(typing Tutorial lists the two tutorials, %d)" % app._visible_notes.size())
	await key(KEY_DOWN)
	check(focused() == row_of(t_alpha), "Down in the search box focuses the first result (%s)" % focused_name())
	await key(KEY_ENTER)
	check(app.current_note == t_alpha, "Enter opens the first match (%s)" % current())
	await key(KEY_DOWN)
	await key(KEY_ENTER)
	check(app.current_note == t_beta, "Down, Enter opens the second match (%s)" % current())
	app.search_box.grab_focus()
	await key(KEY_ENTER)
	check(app.current_note == t_alpha and focused() == app.raw_text_layer, "Enter in the search box itself still opens the first match")
	app.search_box.text = ""
	app._refresh_note_list()

	# ── The palette lists the key ──
	app._build_palette_items("note list")
	var listed: bool = false
	for item in app._palette_items:
		if str(item.action) == "focus_list":
			listed = true
	check(listed, "the palette lists the note-list keys with Ctrl+Shift+E")
	app._execute_command("focus_list")
	await frames(1)
	check(focused() == row_of(t_alpha), "…and runs it (%s)" % focused_name())

	app.queue_free()
	await frames(2)
	TestVault.remove_tree(vault)
	for p in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
