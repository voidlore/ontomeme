extends SceneTree
## Inserting an image: a png dropped on the window (app._on_files_dropped) is
## copied into <vault>/images/ and `![Caption](images/<name>)` goes in at the
## caret, saved to disk and shown in Read view. The same file again is not
## copied twice; another file with the same name becomes <stem>_1; a file
## already in images/ is used where it is; a .gif copies nothing and says
## why. Over NoteScript.large_image_bytes a dialog asks first, one file at a
## time. The palette's "Insert image…" opens a FileDialog that does the same.
##   godot --headless --path . -s res://tests/image_insert_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const NoteScript = preload("res://note.gd")

const PALETTE_LABEL: String = "Insert image… (.png, .jpg, .webp)"

var fails: int = 0
var V: String = ""
var src: String = ""   # a folder outside the vault, like ~/Pictures


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func save_image(path: String, colour: Color, w: int = 8) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var img := Image.create(w, 8, false, Image.FORMAT_RGBA8)
	img.fill(colour)
	img.save_png(path)


func find_all(root: Node, type: String) -> Array:
	var found: Array = []
	for c in root.get_children():
		if c.is_class(type):
			found.append(c)
		found.append_array(find_all(c, type))
	return found


func images_in_vault() -> PackedStringArray:
	var files: PackedStringArray = DirAccess.get_files_at(V.path_join("images"))
	files.sort()
	return files


func on_disk(note: ContentLayer) -> String:
	return FileAccess.get_file_as_string(note.resource_path)


func drop(app: Control, path: String) -> void:
	app._on_files_dropped(PackedStringArray([path]))
	await frames(4)


func _init() -> void:
	ProgressStore.file_override = "user://test_progress_image_insert.json"   # never touch real progress
	ProgressStore.reset()
	JourneyStore.file_override = "user://test_journey_image_insert.json"     # never touch the real journey
	JourneyStore.reset()
	V = TestVault.open("image_insert", false)
	src = ProjectSettings.globalize_path("user://test-image-insert-src/")
	TestVault.remove_tree(src)
	save_image(src.path_join("red.png"), Color.RED)
	save_image(src.path_join("other/red.png"), Color.BLUE)
	save_image(src.path_join("my photo (1).png"), Color.ORANGE)
	save_image(src.path_join("green.png"), Color.GREEN)
	save_image(src.path_join("big.png"), Color.PURPLE, 64)
	save_image(src.path_join("huge.png"), Color.BROWN, 64)
	var gif := FileAccess.open(src.path_join("anim.gif"), FileAccess.WRITE)
	gif.store_string("GIF89a")
	gif.close()
	var n: ContentLayer = VaultStore.create_note("Pictures")
	n.raw_text = "# Pictures\nSome text."
	VaultStore.save_note(n)

	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.open_note_by_title("Pictures")
	await frames(2)

	await check_drop(app)
	await check_reuse_and_rename(app)
	await check_unsupported(app)
	await check_large(app)
	await check_palette(app)

	TestVault.remove_tree(src)
	print("\nRESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(0 if fails == 0 else 1)


func check_drop(app: Control) -> void:
	# Caret at the end of the heading: the image goes in between
	app._switch_layer("raw")
	await frames(2)
	app.raw_text_layer.set_caret_line(0)
	app.raw_text_layer.set_caret_column(app.raw_text_layer.get_line(0).length())
	await drop(app, src.path_join("red.png"))
	var copied: String = V.path_join("images/red.png")
	check(FileAccess.file_exists(copied) and FileAccess.get_sha256(copied) == FileAccess.get_sha256(src.path_join("red.png")),
		"dropping red.png from outside the vault copies it to <vault>/images/red.png")
	var text: String = app.current_note.raw_text
	check(text.contains("![Red](images/red.png)"), "the note gets ![Red](images/red.png) (%s)" % JSON.stringify(text))
	check(text.find("![Red](images/red.png)") > text.find("# Pictures") and text.find("![Red](images/red.png)") < text.find("Some text."),
		"the ref goes in at the caret, between the heading and the text")
	check(on_disk(app.current_note).contains("![Red](images/red.png)"), "the note's .tres on disk holds the ref (saved, not just in the editor)")
	check(app.current_mode == "visual", "Read view shows after the insert")
	var rects: Array = find_all(LayerEngine._visual_vbox, "TextureRect")
	check(rects.size() == 1 and (rects[0] as TextureRect).texture != null, "Read view shows one TextureRect with the picture (%d)" % rects.size())
	check(app.status_label.text == "Inserted image: images/red.png", "the status says what was inserted (%s)" % app.status_label.text)


func check_reuse_and_rename(app: Control) -> void:
	await drop(app, src.path_join("red.png"))
	check(images_in_vault() == PackedStringArray(["red.png"]), "dropping the same file again copies nothing new (%s)" % [images_in_vault()])
	check(app.current_note.raw_text.count("![Red](images/red.png)") == 2, "and inserts a second ref to the same file")
	check(find_all(LayerEngine._visual_vbox, "TextureRect").size() == 2, "Read view now shows two pictures")

	await drop(app, src.path_join("other/red.png"))
	check(images_in_vault() == PackedStringArray(["red.png", "red_1.png"]), "a different file named red.png becomes red_1.png (%s)" % [images_in_vault()])
	check(FileAccess.get_sha256(V.path_join("images/red_1.png")) == FileAccess.get_sha256(src.path_join("other/red.png")), "red_1.png holds the second file")
	check(app.current_note.raw_text.contains("![Red](images/red_1.png)"), "and the ref names red_1.png")
	await drop(app, src.path_join("other/red.png"))
	check(images_in_vault().size() == 2, "dropping that file again reuses red_1.png, no red_2.png (%s)" % [images_in_vault()])

	await drop(app, V.path_join("images/red.png"))
	check(images_in_vault().size() == 2 and app.current_note.raw_text.count("![Red](images/red.png)") == 3,
		"a file already in images/ is used where it is, not copied")

	await drop(app, src.path_join("my photo (1).png"))
	var refs: Array[Dictionary] = ImageEmbeds.refs_in(app.current_note.raw_text)
	check(refs.size() > 0 and refs[-1].target == "images/my photo (1).png", "a name with spaces and parentheses makes a ref that reads back (%s)" % [refs[-1] if refs.size() > 0 else {}])
	check(find_all(LayerEngine._visual_vbox, "TextureRect").size() == refs.size(), "every inserted ref shows a picture (%d refs)" % refs.size())


func check_unsupported(app: Control) -> void:
	var before_text: String = app.current_note.raw_text
	var before_files: PackedStringArray = images_in_vault()
	await drop(app, src.path_join("anim.gif"))
	check(images_in_vault() == before_files, "dropping a .gif copies nothing")
	check(app.current_note.raw_text == before_text, "and inserts nothing")
	check(app.status_label.text == "Not a supported image (png, jpg, webp): anim.gif", "the status says it is not supported (%s)" % app.status_label.text)


func check_large(app: Control) -> void:
	var limit: int = NoteScript.large_image_bytes
	check(limit == 5 * 1024 * 1024, "the default limit is 5 MB")
	NoteScript.large_image_bytes = 10
	var before_text: String = app.current_note.raw_text
	await drop(app, src.path_join("big.png"))
	var prompt: ConfirmationDialog = app._large_image_prompt
	check(not FileAccess.file_exists(V.path_join("images/big.png")), "over the limit, nothing is copied yet")
	check(app.current_note.raw_text == before_text, "and nothing is inserted yet")
	check(prompt != null and prompt.visible and prompt.dialog_text.begins_with("This image is ") and prompt.dialog_text.contains("Add it anyway?"),
		"a dialog asks 'This image is N. Add it anyway?' (%s)" % (prompt.dialog_text if prompt != null else "no dialog"))
	if prompt == null:
		NoteScript.large_image_bytes = limit
		return
	prompt.get_ok_button().pressed.emit()   # confirmed fires
	await frames(4)
	check(FileAccess.file_exists(V.path_join("images/big.png")), "after the dialog's confirmed signal the file is copied")
	check(app.current_note.raw_text.contains("![Big](images/big.png)"), "and the ref is inserted")
	check(not prompt.visible, "and the dialog is closed")

	# Two at once: asked one at a time; No leaves the second out
	app._on_files_dropped(PackedStringArray([src.path_join("green.png"), src.path_join("huge.png")]))
	await frames(4)
	check(prompt.visible and prompt.dialog_text.contains("green.png"), "two large files: the first is asked about")
	prompt.get_cancel_button().pressed.emit()
	await frames(4)
	check(not FileAccess.file_exists(V.path_join("images/green.png")) and app.status_label.text == "Left out green.png", "No leaves it out")
	check(prompt.visible and prompt.dialog_text.contains("huge.png"), "then the second is asked about")
	prompt.get_ok_button().pressed.emit()
	await frames(4)
	check(FileAccess.file_exists(V.path_join("images/huge.png")) and not prompt.visible, "Yes adds it and the dialog closes")
	NoteScript.large_image_bytes = limit


func check_palette(app: Control) -> void:
	app._open_palette()
	await frames(2)
	var labels: Array = app._palette_items.map(func(it: Dictionary) -> String: return str(it.label).trim_prefix("›  "))
	check(PALETTE_LABEL in labels, "the palette lists '%s'" % PALETTE_LABEL)
	var i: int = labels.find(PALETTE_LABEL)
	check(i >= 0 and app._palette_items[i].action == "import_image", "its action is import_image")
	app._execute_command("import_image")
	await frames(2)
	var dlg: FileDialog = app._image_dialog
	check(dlg != null and dlg.visible, "import_image opens a FileDialog")
	if dlg == null:
		return
	check(typeof(dlg.filters) == TYPE_PACKED_STRING_ARRAY and dlg.filters == PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"]),
		"its filters are a PackedStringArray of png, jpg, jpeg, webp (%s)" % [dlg.filters])
	check(dlg.access == FileDialog.ACCESS_FILESYSTEM and dlg.file_mode == FileDialog.FILE_MODE_OPEN_FILE, "it opens one file from the file system")
	check(app.get_node("AppLayout").get_combined_minimum_size().x <= 820, "the layout still fits the 820-px window")
	dlg.file_selected.emit(src.path_join("green.png"))
	dlg.hide()
	await frames(4)
	check(FileAccess.file_exists(V.path_join("images/green.png")) and app.current_note.raw_text.contains("![Green](images/green.png)"),
		"choosing a file in it copies and inserts the image")
