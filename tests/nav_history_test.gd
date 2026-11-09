extends SceneTree
## Back / Forward through opened notes: Alt+Left / Alt+Right (Cmd+[ / ] on a
## Mac), the mouse's side buttons and the palette step through the notes the
## user opened, skip notes deleted since, follow a note that moved into a
## folder, and start over in another vault.
##   headless:  godot --headless --path . -s res://tests/nav_history_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const NavHistory = preload("res://nav_history.gd")

var fails: int = 0
var app: Control


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func make_note(title: String, body: String = "") -> ContentLayer:
	var n: ContentLayer = VaultStore.create_note(title)
	n.raw_text = body
	VaultStore.save_note(n)
	return n


func current() -> String:
	return app.current_note.title if app.current_note != null else "<none>"


func click(ctrl: Control) -> void:
	var scroll: ScrollContainer = app.note_list_container.get_parent()
	scroll.ensure_control_visible(ctrl)
	await frames(1)
	var pos: Vector2 = ctrl.get_global_rect().get_center()
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


func key(code: Key, alt: bool = false, ctrl: bool = false) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.alt_pressed = alt
		e.ctrl_pressed = ctrl
		e.pressed = pressed
		get_root().push_input(e)
	await frames(2)


func mouse_side_button(button: MouseButton) -> void:
	var pos: Vector2 = app.raw_text_layer.get_global_rect().get_center()
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = button
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	await frames(2)


## Select the title field's text and type `s` over it with real key events,
## leaving the field focused (the title commits only when it loses focus).
func type_title(s: String) -> void:
	app.title_edit.grab_focus()
	await frames(1)
	app.title_edit.select_all()
	for ch in s:
		var e := InputEventKey.new()
		e.pressed = true
		e.unicode = ch.unicode_at(0)
		e.keycode = KEY_SPACE if ch == " " else OS.find_keycode_from_string(ch.to_upper())
		get_root().push_input(e)
		await process_frame
	await frames(1)


## Rename `n` on disk the way MCP update_note or a sync tool would (title
## only, body untouched), then let the disk watcher pick it up.
func outside_rename(n: ContentLayer, from: String, to: String) -> void:
	OS.delay_msec(1100)   # mtime resolution is ~1 s
	var disk: String = FileAccess.get_file_as_string(n.resource_path)
	check(disk.contains("title = \"%s\"" % from), "(%s's file holds title %s)" % [to, from])
	var f := FileAccess.open(n.resource_path, FileAccess.WRITE)
	f.store_string(disk.replace("title = \"%s\"" % from, "title = \"%s\"" % to))
	f.close()
	app.check_disk_changes()
	await frames(1)


func unit_checks() -> void:
	var h := NavHistory.new()
	h.push("a")
	h.push("a")
	h.push("b")
	check(h.back() == "" and h.current == "b", "unit: a path whose file is gone is skipped (default exists = file on disk)")
	var all := func(_p: String) -> bool: return true
	h = NavHistory.new()
	for p in ["a", "a", "b", "c"]:
		h.push(p)
	check(h.back(all) == "b" and h.back(all) == "a" and h.back(all) == "", "unit: a repeat of the same path is one step (c -> b -> a, then nothing)")
	check(h.forward(all) == "b", "unit: forward returns to b")
	h.push("d")
	check(not h.can_go_forward() and h.back(all) == "b", "unit: opening another note drops the forward stack")
	h = NavHistory.new()
	for p in ["v/x.tres", "v/F/y.tres", "v/z.tres"]:
		h.push(p)
	h.remap("v/F", "v/G")
	h.remap("v/x.tres", "v/H/x.tres")
	check(h.back(all) == "v/G/y.tres" and h.back(all) == "v/H/x.tres", "unit: remap follows a moved folder and a moved note")
	h.clear()
	check(not h.can_go_back() and not h.can_go_forward() and h.current == "", "unit: clear empties the history")


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_nav.json"
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_nav.json"
	ProgressStore.reset()
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	unit_checks()

	TestVault.open("nav", false)
	var a: ContentLayer = make_note("Alpha", "# Alpha\n\nSee [[Beta]].")
	var b: ContentLayer = make_note("Beta", "Beta body")
	var c: ContentLayer = make_note("Gamma", "Gamma body")
	var d: ContentLayer = make_note("Delta", "Delta body")
	VaultStore.refresh_note_list()

	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)

	# ── A, then a [[Beta]] link, then a sidebar click on Gamma ──
	await click(app._note_buttons[a])
	check(current() == "Alpha", "a sidebar click opens Alpha (%s)" % current())
	app.open_note_by_title("Beta")   # what a [[Beta]] link click does
	await frames(2)
	check(current() == "Beta", "following [[Beta]] opens Beta (%s)" % current())
	await click(app._note_buttons[c])
	check(current() == "Gamma", "a sidebar click opens Gamma (%s)" % current())

	app.raw_text_layer.grab_focus()   # the keys work over the editor
	await frames(1)
	await key(KEY_LEFT, true)
	check(current() == "Beta", "Alt+Left goes back to Beta (%s)" % current())
	check(app.status_label.text.contains("Beta"), "the status names the note it went back to (%s)" % app.status_label.text)
	await key(KEY_LEFT, true)
	check(current() == "Alpha", "Alt+Left again goes back to Alpha (%s)" % current())
	await key(KEY_RIGHT, true)
	check(current() == "Beta", "Alt+Right goes forward to Beta (%s)" % current())
	await key(KEY_BRACKETRIGHT, false, true)
	check(current() == "Gamma", "Ctrl+] (Cmd+] on a Mac) goes forward to Gamma (%s)" % current())
	await key(KEY_RIGHT, true)
	check(current() == "Gamma" and app.status_label.text.contains("Nothing"), "Alt+Right at the newest note stays put and says so (%s)" % app.status_label.text)

	# ── Trash Beta (outside the editor, as MCP or a file manager would) ──
	VaultStore.delete_note(VaultStore.note_list.find(b))
	app._refresh_note_list()
	await frames(1)
	await key(KEY_LEFT, true)
	check(current() == "Alpha", "with Beta trashed, back from Gamma goes to Alpha (%s)" % current())

	# ── The mouse's side buttons ──
	await click(app._note_buttons[d])
	check(current() == "Delta", "a sidebar click opens Delta (%s)" % current())
	await mouse_side_button(MOUSE_BUTTON_XBUTTON1)
	check(current() == "Alpha", "mouse button 4 (XBUTTON1) goes back to Alpha (%s)" % current())
	await mouse_side_button(MOUSE_BUTTON_XBUTTON2)
	check(current() == "Delta", "mouse button 5 (XBUTTON2) goes forward to Delta (%s)" % current())

	# ── The palette ──
	app._open_palette()
	app._palette_search.text = "go back"
	app._on_palette_search_changed("go back")
	await frames(1)
	check(app._palette_items.size() >= 1 and str(app._palette_items[0].label).contains("Go back"), "the palette lists Go back")
	await key(KEY_ENTER)
	check(current() == "Alpha" and not app._palette_visible, "palette Go back returns to Alpha (%s)" % current())
	app._execute_command("nav_forward")
	await frames(1)
	check(current() == "Delta", "palette Go forward returns to Delta (%s)" % current())

	# ── A note moved into a folder stays in the history ──
	app.create_folder("Box")
	check(app.move_note_to(a, "Box"), "Alpha moves into Box")
	await key(KEY_LEFT, true)
	check(current() == "Alpha" and app.current_note == a, "back still reaches Alpha after it moved (%s)" % current())
	await key(KEY_RIGHT, true)
	check(current() == "Delta", "and forward to Delta again (%s)" % current())

	# ── A title typed but not yet committed survives Back / Forward ──
	# The title field commits on losing focus; the nav keys and the mouse's
	# side buttons don't move focus, so Back / Forward must commit it.
	await type_title("Delta Renamed")
	check(app.title_edit.has_focus() and app.title_edit.text == "Delta Renamed" and d.title == "Delta", "(typed Delta Renamed into the focused title field, not yet committed)")
	await mouse_side_button(MOUSE_BUTTON_XBUTTON1)
	check(current() == "Alpha", "mouse button 4 from a half-typed title goes back to Alpha (%s)" % current())
	check(d.title == "Delta Renamed", "…and Delta keeps the title typed into it (%s)" % d.title)
	check(FileAccess.get_file_as_string(d.resource_path).contains("Delta Renamed"), "…saved to Delta's file")
	await key(KEY_RIGHT, true)
	check(current() == "Delta Renamed" and app.title_edit.text == "Delta Renamed", "Alt+Right returns to the renamed note (%s)" % current())
	await type_title("Delta")
	await key(KEY_LEFT, true)
	check(current() == "Alpha" and d.title == "Delta", "Alt+Left from a half-typed title keeps it too (%s)" % d.title)
	await key(KEY_RIGHT, true)
	await type_title("Delta Again")
	await key(KEY_BRACKETLEFT, false, true)
	check(current() == "Alpha" and d.title == "Delta Again", "Ctrl+[ from a half-typed title keeps it too (%s)" % d.title)
	await key(KEY_RIGHT, true)
	await type_title("Delta")
	app._execute_command("nav_back")
	await frames(1)
	check(current() == "Alpha" and d.title == "Delta", "palette Go back keeps a half-typed title too (%s)" % d.title)
	app.raw_text_layer.grab_focus()
	await frames(1)

	# Back from a note whose title field nobody touched never renames or
	# saves it, even when the field shows "" for a note called "Untitled".
	var u: ContentLayer = make_note("Untitled", "capital U, from an import")
	app._refresh_note_list()
	app.open_note_by_title("Untitled")
	await frames(1)
	check(app.current_note == u and app.title_edit.text == "", "(the note called Untitled shows an empty title field)")
	var u_hash: String = FileAccess.get_sha256(u.resource_path)
	await key(KEY_LEFT, true)
	check(current() == "Alpha" and u.title == "Untitled" and FileAccess.get_sha256(u.resource_path) == u_hash, "Back leaves an untouched title alone: no rename, no save (%s)" % u.title)

	# The renamed note changed on disk meanwhile: the rename becomes a
	# conflict copy, which opens, and Back stops there so the user sees it.
	app.open_note_by_title("Gamma")
	await frames(1)
	await type_title("Gamma Mine")
	var g_disk: String = FileAccess.get_file_as_string(c.resource_path)
	var gf := FileAccess.open(c.resource_path, FileAccess.WRITE)
	gf.store_string(g_disk.replace("Gamma body", "Gamma body, edited in Dropbox"))
	gf.close()
	await mouse_side_button(MOUSE_BUTTON_XBUTTON1)
	check(current().begins_with("Gamma Mine (conflict copy"), "a rename that hit an outside edit opens the conflict copy instead of going back (%s)" % current())
	check(app.status_label.text.contains("changed on disk"), "…and the status bar says what happened (%s)" % app.status_label.text)
	check(FileAccess.get_file_as_string(c.resource_path).contains("edited in Dropbox"), "…while the outside version is kept")
	app.raw_text_layer.grab_focus()
	await frames(1)

	# An outside rename of the open note (title only, so the note reloads in
	# place) is not undone by Back / Forward or by the title field.
	app.check_disk_changes()   # settle the outside edit above first
	app.open_note_by_title("Alpha")
	app.open_note_by_title("Delta")
	app.raw_text_layer.grab_focus()
	await frames(1)
	await outside_rename(d, "Delta", "Delta Outside")
	check(app.current_note == d and d.title == "Delta Outside", "an outside rename reloads the open note in place (%s)" % current())
	check(app.title_edit.text == "Delta Outside", "…and the title field shows the new title (%s)" % app.title_edit.text)
	await key(KEY_LEFT, true)
	check(current() == "Alpha", "Alt+Left after an outside rename goes back to Alpha (%s)" % current())
	check(d.title == "Delta Outside" and FileAccess.get_file_as_string(d.resource_path).contains("Delta Outside"), "…and the outside title survives, not reverted to Delta (%s)" % d.title)
	await key(KEY_RIGHT, true)
	check(current() == "Delta Outside", "Alt+Right returns to the renamed note (%s)" % current())

	# The same with the title field focused but untouched: it follows the
	# outside title, and neither Back nor leaving the field writes it back.
	app.title_edit.grab_focus()
	await frames(1)
	await outside_rename(d, "Delta Outside", "Delta Synced")
	check(app.title_edit.has_focus() and app.title_edit.text == "Delta Synced", "a focused, untouched title field follows the outside rename (%s)" % app.title_edit.text)
	await mouse_side_button(MOUSE_BUTTON_XBUTTON1)
	check(current() == "Alpha" and d.title == "Delta Synced" and FileAccess.get_file_as_string(d.resource_path).contains("Delta Synced"), "mouse button 4 keeps the outside title (%s)" % d.title)
	app.raw_text_layer.grab_focus()
	await frames(1)

	# A title the user is typing is theirs: an outside rename arriving
	# meanwhile doesn't wipe it, and Back commits it.
	await key(KEY_RIGHT, true)
	await type_title("Delta Mine")
	await outside_rename(d, "Delta Synced", "Delta Theirs")
	check(app.title_edit.text == "Delta Mine", "a title being typed is not replaced by an outside rename (%s)" % app.title_edit.text)
	await key(KEY_LEFT, true)
	check(current() == "Alpha" and d.title == "Delta Mine", "…and Back commits the typed title (%s)" % d.title)
	app.raw_text_layer.grab_focus()
	await frames(1)

	# ── Another vault starts a fresh history ──
	var v2: String = ProjectSettings.globalize_path("user://test-vault-nav-2/")
	TestVault.remove_tree(v2)
	DirAccess.make_dir_recursive_absolute(v2)
	var other := ContentLayer.new()
	other.title = "Other Vault Note"
	other.raw_text = "Hello from vault two."
	ResourceSaver.save(other, v2 + "other_vault_note.tres")
	app.switch_vault(v2)
	await frames(2)
	check(current() == "Other Vault Note", "switch_vault opens the other vault's note (%s)" % current())
	check(not app._nav.can_go_back() and not app._nav.can_go_forward(), "switch_vault clears the history")
	await key(KEY_LEFT, true)
	check(current() == "Other Vault Note", "Alt+Left in the new vault stays on its note (%s)" % current())

	app.queue_free()
	await frames(2)
	if registry_backup != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	TestVault.remove_tree(v2)
	for p in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
