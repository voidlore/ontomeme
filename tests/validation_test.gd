extends SceneTree
## Files ending in .tres that can't be read as notes (garbage, a note cut off
## mid-write): the sidebar lists them in a warning row at its bottom instead
## of dropping them silently, a scan reads each one only once until it
## changes, and moving them to <vault>/.corrupted is offered, never done on
## its own. A file that changed since the scan read it (a sync tool that
## finished writing it within the same second) is read again, not moved.
## A Godot project's own resources are not listed.
##   godot --headless --path . -s res://tests/validation_test.gd

const TestVault = preload("res://tests/test_vault.gd")

## A note cut off by a sync tool mid-write: a note header, then a tag list
## that never ends. It passes the code check and fails to parse.
const CUT_OFF_NOTE: String = "[gd_resource type=\"Resource\" script_class=\"ContentLayer\" format=3]\n\n[ext_resource type=\"Script\" path=\"res://ContentLayer.gd\" id=\"1_content_layer\"]\n\n[resource]\nscript = ExtResource(\"1_content_layer\")\ntitle = \"Cut off\"\ntags = Array[String]([\"a\", \n"
## A note cut off right after its [resource] tag: it loads, as a plain
## Resource, and can't be repaired (it has its ext_resource but no script line).
const CUT_AFTER_TAG: String = "[gd_resource type=\"Resource\" script_class=\"ContentLayer\" format=3]\n\n[ext_resource type=\"Script\" path=\"res://ContentLayer.gd\" id=\"1_content_layer\"]\n\n[resource]\n"
const GARBAGE: String = "this is not a resource, just some bytes\n"
const CORRUPTED_PATH: String = ".corrupted/"

var fails: int = 0
var app: Control
var V: String


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


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


func write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## Wait past the 1 s mtime resolution, so the next write is a change.
func next_second() -> void:
	await create_timer(1.1).timeout


func sorted(a: Array) -> Array:
	var b: Array = a.duplicate()
	b.sort()
	return b


## A whole note titled `title`: CUT_AFTER_TAG is how it looks while a sync
## tool has written only its start.
func whole_note(title: String) -> String:
	return CUT_AFTER_TAG + "script = ExtResource(\"1_content_layer\")\ntitle = \"%s\"\nraw_text = \"Whole.\"\n" % title


## Wait for the start of a second, so the writes that follow land within
## one second and keep the same mtime (it has a 1 s resolution).
func start_of_second() -> void:
	var t: float = Time.get_unix_time_from_system()
	if t - floorf(t) > 0.2:
		await create_timer(1.02 - (t - floorf(t))).timeout


func row() -> Button:
	return app._unreadable_row


func row_shows(count_text: String) -> bool:
	return row() != null and row().visible and row().text.contains(count_text)


func _init() -> void:
	ProgressStore.file_override = "user://test_progress_validation.json"   # never touch real progress
	JourneyStore.file_override = "user://test_journey_validation.json"     # never touch the real journey
	V = TestVault.open("validation", false)
	await frames(2)
	VaultStore.create_note("A real note")
	write_text(V + "garbage.tres", GARBAGE)
	var reads_before: int = VaultStore.unreadable_reads
	VaultStore.refresh_note_list()
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(3)

	test_garbage_listed(reads_before)
	test_foreign_resources_not_listed()
	await test_rewritten_as_note_is_listed()
	await test_quarantine_from_the_sidebar()
	test_cut_off_note_read_once()
	test_quarantine_keeps_earlier_copies()
	await test_quarantine_leaves_a_finished_note()
	await test_quarantine_checks_the_bytes()
	test_quarantine_of_a_deleted_file()
	await test_changed_and_still_cut_off()

	app.queue_free()
	await frames(2)
	TestVault.remove_tree(V)
	for f in [ProgressStore.file_override, JourneyStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)


func test_garbage_listed(reads_before: int) -> void:
	check(VaultStore.unreadable == ["garbage.tres"], "garbage.tres is listed as unreadable (%s)" % [VaultStore.unreadable])
	check(VaultStore.get_note_count() == 1, "the garbage is not a note; the real note is listed")
	check(row_shows("1 unreadable"), "the sidebar shows a row '1 unreadable file' (%s)" % (row().text if row() != null else "no row"))
	var sidebar: Node = app.get_node("AppLayout/Body/Sidebar/SidebarVBox")
	check(row() != null and row().get_parent() == sidebar and row().get_index() > app.note_list_container.get_parent().get_index(),
			"the row sits at the bottom of the sidebar, below the note list")
	check(VaultStore.unreadable_reads == reads_before + 1, "the first scan read the garbage once")
	VaultStore.refresh_note_list()
	VaultStore.refresh_note_list()
	app.check_disk_changes()
	check(VaultStore.unreadable_reads == reads_before + 1, "later scans do not read the unchanged garbage again (reads %d)" % (VaultStore.unreadable_reads - reads_before))
	check(VaultStore.unreadable == ["garbage.tres"], "the unchanged garbage stays listed")
	check(FileAccess.file_exists(V + "garbage.tres") and not DirAccess.dir_exists_absolute(V + ".corrupted"),
			"nothing is moved on its own")


func test_foreign_resources_not_listed() -> void:
	DirAccess.make_dir_recursive_absolute(V + "assets")
	ResourceSaver.save(StandardMaterial3D.new(), V + "assets/red.tres")
	write_text(V + "assets/settings.tres", "[gd_resource type=\"Resource\" format=3]\n\n[resource]\nresource_name = \"settings\"\n")
	VaultStore.refresh_note_list()
	check(VaultStore.unreadable == ["garbage.tres"], "a Godot project's material and plain resource are not listed as unreadable (%s)" % [VaultStore.unreadable])
	DirAccess.remove_absolute(V + "assets/red.tres")
	DirAccess.remove_absolute(V + "assets/settings.tres")
	DirAccess.remove_absolute(V + "assets")


func test_rewritten_as_note_is_listed() -> void:
	await next_second()
	var n := ContentLayer.new()
	n.title = "Was garbage"
	n.raw_text = "Readable now."
	n.created = Time.get_datetime_string_from_system()
	n.modified = n.created
	ResourceSaver.save(n, V + "garbage.tres")
	app.check_disk_changes()
	check(VaultStore.get_note_index("Was garbage") >= 0, "garbage.tres rewritten as a note is listed as a note")
	check(VaultStore.unreadable.is_empty(), "and the unreadable list is empty (%s)" % [VaultStore.unreadable])
	check(row() == null or not row().visible, "the warning row is gone")


func test_quarantine_from_the_sidebar() -> void:
	await next_second()
	write_text(V + "garbage.tres", GARBAGE)
	app.check_disk_changes()
	check(VaultStore.unreadable == ["garbage.tres"] and VaultStore.get_note_index("Was garbage") < 0,
			"a note turned to garbage on disk leaves the list and is listed as unreadable")
	check(row_shows("1 unreadable"), "the row is back")
	await click(row())
	var menu: PopupMenu = app._ctx_menu
	check(menu.visible and menu.get_item_index(40) >= 0 and menu.get_item_index(41) >= 0
			and menu.get_item_text(menu.get_item_index(40)) == "Show in file manager"
			and menu.get_item_text(menu.get_item_index(41)) == "Move to .corrupted",
			"clicking the row opens a menu: Show in file manager, Move to .corrupted")
	menu.id_pressed.emit(41)
	menu.hide()
	await frames(2)
	check(FileAccess.file_exists(V + ".corrupted/garbage.tres") and not FileAccess.file_exists(V + "garbage.tres"),
			"Move to .corrupted moves garbage.tres to .corrupted/garbage.tres")
	check(FileAccess.get_file_as_string(V + ".corrupted/garbage.tres") == GARBAGE, "the moved file keeps its bytes")
	check(VaultStore.unreadable.is_empty() and (row() == null or not row().visible), "the row disappears")
	check(VaultStore.get_note_count() == 1 and not VaultStore.folders.has(".corrupted"), ".corrupted is hidden like the other dot folders")


func test_cut_off_note_read_once() -> void:
	write_text(V + "Physics/note_cut.tres", CUT_OFF_NOTE)
	write_text(V + "Physics/note_cut_after_tag.tres", CUT_AFTER_TAG)
	write_text(V + "garbage.tres", GARBAGE)
	var reads_before: int = VaultStore.unreadable_reads
	# Reading the cut-off note prints Godot's "Parse Error" lines, which
	# run_all.sh rightly fails on for scripts; keep this deliberate one out.
	# The next scan runs unmuted: it must not parse the note again.
	Engine.print_error_messages = false
	app.check_disk_changes()
	Engine.print_error_messages = true
	check(sorted(VaultStore.unreadable) == ["Physics/note_cut.tres", "Physics/note_cut_after_tag.tres", "garbage.tres"],
			"notes cut off mid-write are listed with their folder (%s)" % [VaultStore.unreadable])
	check(row_shows("3 unreadable files"), "the row counts all three files")
	check(VaultStore.unreadable_reads == reads_before + 3, "each file was read once")
	VaultStore.refresh_note_list()
	check(VaultStore.unreadable_reads == reads_before + 3, "the cut-off notes are not parsed again on the next scan")


func test_quarantine_keeps_earlier_copies() -> void:
	check(VaultStore.quarantine("Physics/note_cut.tres") and FileAccess.file_exists(V + ".corrupted/Physics/note_cut.tres"),
			"quarantine keeps the file's folder inside .corrupted")
	check(VaultStore.quarantine("Physics/note_cut_after_tag.tres") and not FileAccess.file_exists(V + "Physics/note_cut_after_tag.tres"),
			"the note cut after its [resource] tag is moved too")
	check(VaultStore.quarantine("garbage.tres") and FileAccess.file_exists(V + ".corrupted/garbage 2.tres")
			and FileAccess.get_file_as_string(V + ".corrupted/garbage.tres") == GARBAGE,
			"a second garbage.tres goes to .corrupted/garbage 2.tres; the first stays")
	check(VaultStore.unreadable.is_empty(), "quarantined files leave the unreadable list")
	var real: String = VaultStore.note_list[0].resource_path.trim_prefix(V)
	check(not VaultStore.quarantine(real) and FileAccess.file_exists(V + real), "quarantine refuses a file that is not listed as unreadable")
	check(not VaultStore.quarantine("garbage.tres"), "quarantine of a file already moved returns false")


## A sync tool caught mid-write: the scan sees the note cut after its
## [resource] tag, then the tool finishes the file within the same second, so
## the disk watcher (mtimes only) does not rescan and the row stays. "Move to
## .corrupted" must not move the finished note out of the vault.
func test_quarantine_leaves_a_finished_note() -> void:
	await start_of_second()
	write_text(V + "note_synced.tres", CUT_AFTER_TAG)
	app.check_disk_changes()
	check(VaultStore.unreadable == ["note_synced.tres"] and row_shows("1 unreadable"), "a note a sync tool is still writing is listed as unreadable")
	write_text(V + "note_synced.tres", whole_note("Synced"))
	await click(row())
	app._ctx_menu.id_pressed.emit(41)
	app._ctx_menu.hide()
	await frames(2)
	check(FileAccess.get_file_as_string(V + "note_synced.tres") == whole_note("Synced") and not FileAccess.file_exists(V + ".corrupted/note_synced.tres"),
			"Move to .corrupted leaves a note that was finished after the scan where it is")
	check(VaultStore.get_note_index("Synced") >= 0, "it is read again and listed as a note")
	check(VaultStore.unreadable.is_empty() and (row() == null or not row().visible), "the row disappears")
	check(app.status_label.text.contains("left 1 in place"), "the status line says the file was left in place (%s)" % app.status_label.text)


## The same within the store, where the rewrite also keeps the file's size,
## so even the scan's stamp (mtime and size) can't tell: quarantine compares
## the bytes.
func test_quarantine_checks_the_bytes() -> void:
	var rel: String = "note_same_size.tres"
	var whole: String = whole_note("Same size")
	var garbled: String = "#" + whole.substr(1)   # no resource header: unreadable
	var stamped: bool = false
	for attempt in 3:   # a slow machine may cross a second; try again
		await next_second()
		await start_of_second()
		write_text(V + rel, garbled)
		VaultStore.refresh_note_list()
		var stamp: String = VaultStore._stamp(V + rel)
		write_text(V + rel, whole)
		stamped = VaultStore._stamp(V + rel) == stamp
		if stamped:
			break
	check(stamped, "the rewrite keeps the file's mtime and size")
	VaultStore.refresh_note_list()
	check(VaultStore.unreadable.has(rel), "so a scan still lists it as unreadable (%s)" % [VaultStore.unreadable])
	check(not VaultStore.quarantine(rel), "quarantine refuses a file whose bytes changed since the scan read them")
	check(FileAccess.get_file_as_string(V + rel) == whole and not FileAccess.file_exists(V + CORRUPTED_PATH + rel), "the file stays where it is, whole")
	check(VaultStore.get_note_index("Same size") >= 0 and not VaultStore.unreadable.has(rel), "it is read again and listed as a note")


func test_quarantine_of_a_deleted_file() -> void:
	write_text(V + "gone.tres", GARBAGE)
	VaultStore.refresh_note_list()
	check(VaultStore.unreadable.has("gone.tres"), "gone.tres is listed as unreadable")
	DirAccess.remove_absolute(V + "gone.tres")
	check(not VaultStore.quarantine("gone.tres") and not VaultStore.unreadable.has("gone.tres"),
			"quarantine of a listed file deleted since the scan returns false and drops it from the list")


## A listed cut-off note that a sync tool rewrites, still cut off: the scan
## sees it changed and reads it again, and it stays listed. (No note object
## is held for it, so there is no copy of the app's to keep instead.)
func test_changed_and_still_cut_off() -> void:
	var rel: String = "note_flaky.tres"
	write_text(V + rel, CUT_OFF_NOTE)
	Engine.print_error_messages = false
	VaultStore.refresh_note_list()
	check(VaultStore.unreadable.has(rel), "a cut-off note is listed as unreadable (%s)" % [VaultStore.unreadable])
	await next_second()
	write_text(V + rel, CUT_OFF_NOTE.replace("Cut off", "Cut off again"))
	var reads_before: int = VaultStore.unreadable_reads
	VaultStore.refresh_note_list()
	Engine.print_error_messages = true
	check(VaultStore.unreadable.has(rel) and VaultStore.unreadable_reads == reads_before + 1,
			"rewritten and still cut off, it is read again and stays listed (%s)" % [VaultStore.unreadable])
	DirAccess.remove_absolute(V + rel)
	VaultStore.refresh_note_list()
