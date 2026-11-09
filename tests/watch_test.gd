extends SceneTree
## Disk watcher: the open app sees a note changed outside it (Claude over MCP,
## a sync tool) even when two writes land in the same second with the same
## size, and an untouched vault never looks changed (no false refresh).
##   headless:  godot --headless --path . -s res://tests/watch_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")

var fails: int = 0
var V: String = ""
var tools: RefCounted = null


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## Sleep until just past the next whole second, so the writes that follow share
## one mtime second (mtimes are whole seconds).
func next_second() -> void:
	var t: float = Time.get_unix_time_from_system()
	OS.delay_msec(int((floorf(t) + 1.0 - t) * 1000.0) + 20)


## Sleep until a file with this mtime is no longer fresh (VaultStore stops
## hashing it on every poll).
func until_settled(mtime: int) -> void:
	var wait: float = mtime + VaultStore.FRESH_SECS + 0.2 - Time.get_unix_time_from_system()
	if wait > 0.0:
		OS.delay_msec(int(wait * 1000.0))


func stat(rel: String) -> Array:
	return [FileAccess.get_modified_time(V + rel), FileAccess.get_size(V + rel)]


func note_at(rel: String) -> ContentLayer:
	for n in VaultStore.note_list:
		if n.resource_path == V + rel:
			return n
	return null


func note_text(rel: String) -> String:
	var n: ContentLayer = note_at(rel)
	return n.raw_text if n != null else "<missing>"


func mcp_create(title: String, body: String) -> Dictionary:
	return tools.call_tool("create_note", {"title": title, "markdown": body}).get("structuredContent", {})


func mcp_update(c: Dictionary, body: String) -> Dictionary:
	return tools.call_tool("update_note", {"path": c.path, "hash": c.hash, "markdown": body}).get("structuredContent", {})


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_watch.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_watch.json"   # never touch real progress
	ProgressStore.reset()
	V = TestVault.open("watch")
	tools = VaultTools.new(V)
	await frames(2)

	test_untouched_vault()
	test_same_second_store()
	test_settled_late_poll()
	await test_same_second_app()

	TestVault.remove_tree(V)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


## (c) and (d): no false refresh, and the 1.5 s poll stays cheap.
func test_untouched_vault() -> void:
	# Right after seeding every note is fresh, so this is the costliest call.
	var t0: int = Time.get_ticks_usec()
	var s1: String = VaultStore.disk_signature()
	var fresh_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	var s2: String = VaultStore.disk_signature()
	check(s1 == s2, "an untouched vault gives the same signature on two calls")
	check(VaultStore.note_list.size() > 10, "(the seeded vault has %d notes)" % VaultStore.note_list.size())
	check(fresh_ms < 50.0, "disk_signature() on the seeded vault, every note fresh, takes < 50 ms (%.1f ms)" % fresh_ms)
	t0 = Time.get_ticks_usec()
	VaultStore.disk_signature()
	var warm_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	check(warm_ms < 50.0, "…and a repeat call takes < 50 ms (%.1f ms)" % warm_ms)


## (a): create then update in one second, same size: the signature moves and a
## rescan loads the new text. The test holds the note, as the open app does, so
## ResourceLoader's cache would hand back the old object.
func test_same_second_store() -> void:
	next_second()
	var c: Dictionary = mcp_create("Same Second", "v1")
	var before: String = VaultStore.disk_signature()
	VaultStore.refresh_note_list()
	var held: ContentLayer = note_at(c.path)
	check(held != null and held.raw_text == "v1", "(the store loaded v1)")
	var st1: Array = stat(c.path)
	mcp_update(c, "v2")
	var st2: Array = stat(c.path)
	check(st1 == st2, "(both MCP writes share one mtime second and size: %s, %s)" % [st1, st2])
	check(VaultStore.disk_signature() != before, "disk_signature() changes after a same-second, same-size update_note")
	VaultStore.refresh_note_list()
	check(note_text(c.path) == "v2" and held.raw_text == "v2", "a rescan reloads the held note in place with the new body (%s)" % note_text(c.path))


## A poll inside the write's second, the same-second rewrite, and the next poll
## only after the file stopped being fresh: still seen. A file leaving the
## fresh window does not change the signature by itself.
func test_settled_late_poll() -> void:
	next_second()
	var c: Dictionary = mcp_create("Late Poll", "v1")
	var before: String = VaultStore.disk_signature()
	VaultStore.refresh_note_list()
	var held: ContentLayer = note_at(c.path)
	var st1: Array = stat(c.path)
	mcp_update(c, "v2")
	check(st1 == stat(c.path), "(the late-poll writes share one mtime second and size)")
	until_settled(st1[0])
	var after: String = VaultStore.disk_signature()
	check(after != before, "a same-second update is seen by a poll after the file stopped being fresh")
	VaultStore.refresh_note_list()
	check(held != null and held.raw_text == "v2", "…and the rescan then reloads it (%s)" % (held.raw_text if held else "none"))
	check(VaultStore.disk_signature() == after, "a settled vault keeps its signature")

	var d: Dictionary = mcp_create("Goes Stale", "fresh")
	var fresh_sig: String = VaultStore.disk_signature()
	until_settled(stat(d.path)[0])
	check(VaultStore.disk_signature() == fresh_sig, "a note leaving the fresh window does not change the signature (no false refresh)")


## (b): the open app shows Claude's second write.
func test_same_second_app() -> void:
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.check_disk_changes()   # absorb the app's own startup save
	var ok: bool = false
	for attempt in range(3):   # a slow machine can cross a second boundary; retry
		var title: String = "Open In App %d" % attempt
		next_second()
		var c: Dictionary = mcp_create(title, "v1")
		var st1: Array = stat(c.path)
		app.check_disk_changes()
		app.open_note_by_title(title)
		check(app.current_note != null and app.current_note.title == title and app.raw_text_layer.text == "v1", "(the app opened the new note with v1)")
		mcp_update(c, "v2")
		if stat(c.path) != st1:
			print("      (attempt %d crossed a second boundary; retrying)" % attempt)
			continue
		check(app._auto_save_timer.is_stopped(), "(no autosave pending, so the watcher polls)")
		app.check_disk_changes()
		await frames(2)
		check(app.raw_text_layer.text == "v2", "the open note shows a same-second, same-size MCP update after check_disk_changes() (%s)" % app.raw_text_layer.text)
		ok = true
		break
	check(ok, "(a same-second app run happened)")
	app.status_label.text = "quiet"
	app.check_disk_changes()
	check(app.status_label.text == "quiet", "an untouched vault does not refresh the app (%s)" % app.status_label.text)
	app.queue_free()
	await frames(2)
