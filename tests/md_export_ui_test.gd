extends SceneTree
## Markdown export from the UI: the top bar's Export button (a real click),
## the palette commands and the sidebar's right-click items (a note, a
## folder, the vault), in a throwaway vault seeded with the tutorials and the
## Godot course.
##   headless:  godot --headless --path . -s res://tests/md_export_ui_test.gd
##   + images:  godot --path . -s res://tests/md_export_ui_test.gd -- <out_dir>

const TestVault = preload("res://tests/test_vault.gd")

var fails: int = 0
var out: String = ""
var app: Control
var V: String


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func shot(name: String) -> void:
	if out == "" or DisplayServer.get_name() == "headless":
		return
	await create_timer(0.8).timeout
	get_root().get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("saved ", name)


## A real click: mouse motion, then press and release, through the viewport.
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


## Type `text` as key presses into whatever has focus.
func type_text(text: String) -> void:
	for i in range(text.length()):
		for pressed in [true, false]:
			var k := InputEventKey.new()
			k.pressed = pressed
			k.unicode = text.unicode_at(i)
			k.keycode = OS.find_keycode_from_string(text[i].to_upper()) if text[i] != " " else KEY_SPACE
			get_root().push_input(k)
	await process_frame


## Where `n` exports to by default: V/exports/<folder>/<stem>.md.
func export_path(n: ContentLayer) -> String:
	return V.path_join(MdExport.EXPORT_DIR).path_join(MdExport.export_rel_path(n, V))


## Every .md file at or below `dir`, absolute paths, sorted.
func md_under(dir: String) -> PackedStringArray:
	var found: PackedStringArray = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".md"):
			found.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		found.append_array(md_under(dir.path_join(d)))
	found.sort()
	return found


## The first note in note_list whose folder is (or is not) top level.
func first_note(in_folder: bool) -> ContentLayer:
	for n in VaultStore.note_list:
		if (VaultStore.folder_of(n) != "") == in_folder:
			return n
	return null


## Default export paths of the notes in vault folder `rel`, sorted.
func folder_exports(rel: String) -> PackedStringArray:
	var paths: PackedStringArray = []
	for n in VaultStore.note_list:
		if VaultStore.folder_of(n) == rel:
			paths.append(export_path(n))
	paths.sort()
	return paths


## The text of the context-menu item `id` as _show_ctx(target) builds it.
func ctx_item(target: Dictionary, id: int) -> String:
	app._show_ctx(target)
	var idx: int = app._ctx_menu.get_item_index(id)
	app._ctx_menu.hide()
	return app._ctx_menu.get_item_text(idx) if idx >= 0 else ""


func row_texts() -> Array:
	return app.note_list_container.get_children().map(func(b): return b.text.strip_edges())


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	JourneyStore.file_override = "user://test_journey_md_export_ui.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_md_export_ui.json"   # never touch real progress
	ProgressStore.reset()
	V = TestVault.open("md-export-ui")
	var exports: String = V.path_join(MdExport.EXPORT_DIR)

	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)

	# ── The button fits the minimum window ──
	var btn: Button = app.get_node("%ExportMDButton")
	var min_w: float = app.get_node("AppLayout").get_combined_minimum_size().x
	check(min_w <= 820, "the layout still fits the 820 px minimum window (%d px)" % min_w)
	check(btn.icon != null and btn.text == "" and btn.tooltip_text == "Export as Markdown",
		"the top bar's Export button is the download icon, tooltip \"Export as Markdown\"")
	check(btn.get_index() == app.delete_btn.get_index() - 1, "it sits just before Delete")
	check(get_root().get_visible_rect().encloses(btn.get_global_rect()), "it lies inside the window, so a click reaches it")

	# ── A real click on the button exports the open note ──
	var n: ContentLayer = first_note(true)
	check(n != null, "fixture: a note inside a folder (%s)" % (VaultStore.folder_of(n) if n != null else "none"))
	app._open_note(n)
	await frames(2)
	var tres_sha: String = FileAccess.get_sha256(n.resource_path)
	await click(btn)
	var path: String = export_path(n)
	check(FileAccess.file_exists(path), "clicking Export writes exports/%s" % MdExport.export_rel_path(n, V))
	check(app.status_label.text.begins_with("Exported"), "the status starts with \"Exported\" (%s)" % app.status_label.text)
	check(app.status_label.text == "Exported to exports/" + MdExport.export_rel_path(n, V), "... and names the file in the vault")
	check(FileAccess.get_file_as_string(path).begins_with("---\ntitle: \"%s\"" % n.title), "the file is the note's Markdown")
	check(FileAccess.get_sha256(n.resource_path) == tres_sha, "the click left the note's .tres untouched")
	await shot("md1_exported")

	# ── Typing, then clicking before the autosave, exports the typed text ──
	app._switch_layer("raw")
	await frames(1)
	app.raw_text_layer.grab_focus()
	app.raw_text_layer.set_caret_line(app.raw_text_layer.get_line_count() - 1)
	app.raw_text_layer.set_caret_column(app.raw_text_layer.get_line(app.raw_text_layer.get_line_count() - 1).length())
	await type_text(" Typed just now")
	check(app.raw_text_layer.text.ends_with(" Typed just now"), "the key presses reached the editor")
	check(not app._auto_save_timer.is_stopped() and not n.raw_text.contains("Typed just now"),
		"fixture: the typing is not saved yet (autosave pending)")
	await click(btn)
	check(FileAccess.get_file_as_string(path).contains("Typed just now"), "an immediate click exports the unsaved typing")
	check(n.raw_text.contains("Typed just now") and app._auto_save_timer.is_stopped(), "... because the click saved it first")

	# ── No note open: a status, no file ──
	app._show_empty_state()
	await frames(2)
	var files_before: PackedStringArray = md_under(exports)
	await click(btn)
	check(app.status_label.text == "No note open to export", "with no note open the click says so (%s)" % app.status_label.text)
	check(md_under(exports) == files_before, "... and writes no file")

	# ── Palette ──
	var p: ContentLayer = first_note(false)
	app._open_note(p)
	await frames(2)
	app._open_palette()
	app._on_palette_search_changed("markdown")
	var labels: Array = app._palette_items.map(func(i: Dictionary) -> String: return i.label)
	check(labels.has("›  Export note as Markdown"), "the palette lists \"Export note as Markdown\" for \"markdown\" %s" % str(labels))
	DirAccess.remove_absolute(export_path(p))
	app._execute_command("export_md")
	await frames(2)
	check(FileAccess.file_exists(export_path(p)) and not app._palette_visible,
		"_execute_command(\"export_md\") writes %s" % MdExport.export_rel_path(p, V))

	# ── Sidebar right-click on a note ──
	var m: ContentLayer = null
	for x in VaultStore.note_list:
		if x != n and x != p and VaultStore.folder_of(x) != "":
			m = x
			break
	app._show_ctx({"type": "note", "note": m})
	await frames(1)
	var idx: int = app._ctx_menu.get_item_index(17)
	check(idx >= 0 and app._ctx_menu.get_item_text(idx) == "Export as Markdown", "a note's right-click menu has \"Export as Markdown\" (id 17)")
	app._ctx_menu.hide()
	check(not FileAccess.file_exists(export_path(m)), "fixture: %s not exported yet" % m.title)
	app._ctx_target = {"type": "note", "note": m}
	app._on_ctx_menu(17)
	await frames(2)
	check(FileAccess.file_exists(export_path(m)) and app.current_note == p,
		"_on_ctx_menu(17) writes the right-clicked note's file and leaves the open note open")

	# ── The export folder never shows in the sidebar ──
	app.check_disk_changes()
	await frames(2)
	check(not VaultStore.folders.has(MdExport.EXPORT_DIR) and not app._folder_buttons.has(MdExport.EXPORT_DIR)
			and not row_texts().has(MdExport.EXPORT_DIR),
		"no \"exports\" folder in the sidebar after exporting")

	# ── Export all: palette and the sidebar's background menu ──
	var count: int = VaultStore.note_list.size()
	app._on_palette_search_changed("markdown")
	labels = app._palette_items.map(func(i: Dictionary) -> String: return i.label)
	check(labels.has("›  Export all notes as Markdown"), "the palette lists \"Export all notes as Markdown\"")
	TestVault.remove_tree(exports)
	app._execute_command("export_md_all")
	await frames(2)
	check(md_under(exports).size() == count, "_execute_command(\"export_md_all\") writes all %d notes" % count)
	check(app.status_label.text == "Exported %d notes to exports/" % count, "the status reports the count (%s)" % app.status_label.text)
	check(ctx_item({"type": "root"}, 23) == "Export all as Markdown", "the sidebar background menu has \"Export all as Markdown\" (id 23)")
	TestVault.remove_tree(exports)
	app._ctx_target = {"type": "root"}
	app._on_ctx_menu(23)
	await frames(2)
	check(md_under(exports).size() == count and app.status_label.text.begins_with("Exported %d notes" % count),
		"_on_ctx_menu(23) writes every note")

	# ── Export folder: the folder's menu ──
	check(ctx_item({"type": "folder", "rel": "Godot"}, 5) == "Export folder as Markdown", "a folder's menu has \"Export folder as Markdown\" (id 5)")
	TestVault.remove_tree(exports)
	var godot: PackedStringArray = folder_exports("Godot")
	app._ctx_target = {"type": "folder", "rel": "Godot"}
	app._on_ctx_menu(5)
	await frames(2)
	check(godot.size() > 0 and md_under(exports) == godot, "_on_ctx_menu(5) writes only that folder's %d notes" % godot.size())
	check(app.status_label.text == "Exported %d notes to exports/Godot/" % godot.size(), "... and says where (%s)" % app.status_label.text)

	# ── Some notes fail: a file stands where exports/Godot would go ──
	TestVault.remove_tree(exports)
	MdExport.prepare_out_dir(exports)
	var blocker := FileAccess.open(exports.path_join("Godot"), FileAccess.WRITE)
	blocker.store_string("in the way\n")
	blocker.close()
	app._execute_command("export_md_all")
	await frames(2)
	check(app.status_label.text == "Exported %d notes to exports/; %d failed" % [count - godot.size(), godot.size()],
		"a partial export reports the failures (%s)" % app.status_label.text)
	TestVault.remove_tree(exports)

	app.check_disk_changes()
	await frames(2)
	check(not VaultStore.folders.has(MdExport.EXPORT_DIR) and not row_texts().has(MdExport.EXPORT_DIR),
		"still no \"exports\" folder in the sidebar after Export all")

	# ── A user's own "exports" notes folder: nothing written, the reason shown ──
	VaultStore.create_note("Export Plans", MdExport.EXPORT_DIR)
	app._execute_command("export_md_all")
	await frames(2)
	check(app.status_label.text.begins_with("Export failed: ") and app.status_label.text.contains("already holds notes")
			and md_under(exports).is_empty(),
		"Export all into a notes folder writes nothing and says why")

	# ── Set Markdown export folder… / Reset Markdown export folder ──
	# That vault can export once it picks another folder for its exports.
	app._open_palette()
	app._on_palette_search_changed("export folder")
	labels = app._palette_items.map(func(i: Dictionary) -> String: return i.label)
	check(labels.has("›  Set Markdown export folder…") and labels.has("›  Reset Markdown export folder"),
		"the palette lists \"Set Markdown export folder…\" and \"Reset Markdown export folder\" %s" % str(labels))
	app._execute_command("export_md_folder")
	await frames(2)
	var dlg: FileDialog = app._md_folder_dialog
	check(dlg != null and dlg.visible and dlg.file_mode == FileDialog.FILE_MODE_OPEN_DIR and dlg.access == FileDialog.ACCESS_FILESYSTEM,
		"\"export_md_folder\" opens a folder picker (FILE_MODE_OPEN_DIR, ACCESS_FILESYSTEM)")
	var abs_out: String = ProjectSettings.globalize_path("user://test-md-export-ui-out")
	TestVault.remove_tree(abs_out)
	dlg.dir_selected.emit(abs_out)
	dlg.hide()
	check(MdExport.output_root() == abs_out and app.status_label.text == "Markdown exports go to %s/" % abs_out,
		"choosing a folder saves it and the status names it (%s)" % app.status_label.text)
	app._open_note(p)
	await frames(2)
	await click(btn)
	var outside: String = abs_out.path_join(MdExport.export_rel_path(p, V))
	check(FileAccess.file_exists(outside) and app.status_label.text == "Exported to " + outside,
		"the Export button then writes there, and the status shows the full path (%s)" % app.status_label.text)
	check(md_under(exports).is_empty(), "... and nothing in the vault's exports/ notes folder")

	dlg.dir_selected.emit(exports)
	check(MdExport.output_root() == abs_out and app.status_label.text.begins_with("Export folder not changed: ")
			and app.status_label.text.contains("already holds notes"),
		"choosing a folder of notes is refused and says why (%s)" % app.status_label.text)
	dlg.dir_selected.emit(V)
	check(MdExport.output_root() == abs_out and app.status_label.text.contains("is the vault itself"),
		"choosing the vault itself is refused (%s)" % app.status_label.text)

	dlg.dir_selected.emit(V + "Published")
	check(app.status_label.text == "Markdown exports go to Published/", "a folder in the vault shows vault-relative (%s)" % app.status_label.text)
	var all: int = VaultStore.note_list.size()   # now with "Export Plans" too
	app._execute_command("export_md_all")
	await frames(2)
	check(md_under(V + "Published").size() == all and app.status_label.text == "Exported %d notes to Published/" % all,
		"Export all writes every note to Published/ (%s)" % app.status_label.text)
	app.check_disk_changes()
	await frames(2)
	check(not VaultStore.folders.has("Published") and not row_texts().has("Published"),
		"the chosen export folder stays out of the sidebar")

	app._execute_command("export_md_folder_reset")
	check(MdExport.output_root() == exports and app.status_label.text == "Markdown exports go to exports/",
		"\"Reset Markdown export folder\" goes back to exports/ (%s)" % app.status_label.text)
	TestVault.remove_tree(abs_out)

	# ── Tidy up ──
	app.queue_free()
	await frames(2)
	TestVault.remove_tree(V)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(JourneyStore.file_override))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ProgressStore.file_override))
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)
