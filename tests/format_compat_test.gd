extends SceneTree
## Note files from other versions of Ontomeme. The note format is carried
## forward from v0.1.0, and later versions add fields (tags, starred_at,
## pinned_at, more to come). A build that does not know a field must keep it:
## ContentLayer holds every unknown field it reads and writes it back, so a
## save on an older build (a second machine, a downgrade, an older MCP server)
## never strips what a newer one wrote. And a note an older build wrote
## loads and saves here without an error.
##   godot --headless --path . -s res://tests/format_compat_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")

## A note exactly as v0.1.0-rc2 wrote it: title, dates, body and structure.
const RC2_NOTE: String = """[gd_resource type="Resource" script_class="ContentLayer" format=3]

[ext_resource type="Script" path="res://ContentLayer.gd" id="1_rc2"]

[resource]
script = ExtResource("1_rc2")
title = "Written by rc2"
created = "2026-10-20T09:15:00"
modified = "2026-10-21T10:00:00"
raw_text = "# From rc2
A body with **bold**, a \\"quote\\" and a tick ✓."
structure = {}
"""

## A note a newer build wrote: both timestamps and a field no build knows yet.
const FUTURE_NOTE: String = """[gd_resource type="Resource" script_class="ContentLayer" format=3]

[ext_resource type="Script" path="res://ContentLayer.gd" id="1_future"]

[resource]
script = ExtResource("1_future")
title = "From the future"
created = "2027-01-01T08:00:00"
modified = "2027-01-02T09:00:00"
tags = Array[String](["later"])
starred_at = "2027-01-02T03:04:05"
pinned_at = "2027-01-02T03:04:06"
raw_text = "Written by a newer build."
future_field = {
"k": 1
}
"""

const FUTURE_VALUE: Dictionary = {"k": 1}

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


## Every error Godot or a script logs while it is added (OS.add_logger).
class ErrorLog extends Logger:
	var lines: PackedStringArray = []
	var _mutex := Mutex.new()

	func _log_error(_function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, _error_type: int, _script_backtrace: Array[ScriptBacktrace]) -> void:
		_mutex.lock()
		lines.append("%s %s (%s:%d)" % [code, rationale, file, line])
		_mutex.unlock()

	func _log_message(message: String, error: bool) -> void:
		if error:
			_mutex.lock()
			lines.append(message.strip_edges())
			_mutex.unlock()


func _init() -> void:
	ProgressStore.file_override = "user://test_progress_format_compat.json"   # never touch real progress
	JourneyStore.file_override = "user://test_journey_format_compat.json"     # never touch the real journey
	var V: String = TestVault.open("format-compat", false)
	test_rc2_note(V)
	test_future_note_saved_by_the_app(V)
	test_future_note_through_mcp(V)
	test_future_note_conflict_copy(V)
	test_removed_field_stays_removed(V)
	test_removed_field_after_conflict(V)
	test_future_note_validates(V)
	test_known_names_stay_with_godot()
	TestVault.remove_tree(V)
	for f in [ProgressStore.file_override, JourneyStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)


func write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## The note as stored in `path`, read fresh from disk (not the cached object).
func from_disk(path: String) -> ContentLayer:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as ContentLayer


## Whether the file at `path` still holds future_field, once, with its value.
func keeps_future_field(path: String) -> bool:
	var text: String = FileAccess.get_file_as_string(path)
	var n: ContentLayer = from_disk(path)
	return text.count("future_field = ") == 1 and n != null and n.get("future_field") == FUTURE_VALUE


func open_note(V: String, file: String, text: String) -> ContentLayer:
	write_text(V + file, text)
	VaultStore.open_vault(V, false)
	var i: int = VaultStore.note_list.find_custom(func(n): return n.resource_path == V + file)
	return VaultStore.load_note(i)


func test_rc2_note(V: String) -> void:
	var errors := ErrorLog.new()
	OS.add_logger(errors)
	var note: ContentLayer = open_note(V, "note_written_by_rc2.tres", RC2_NOTE)
	check(note != null and note.title == "Written by rc2", "an rc2 note loads through VaultStore")
	if note == null:
		OS.remove_logger(errors)
		return
	note.raw_text += "\nEdited here."
	VaultStore.save_note(note)
	check(VaultStore.last_conflict_copy == null, "…saves through save_note, in place")
	VaultStore.open_vault(V, false)
	var again: ContentLayer = from_disk(V + "note_written_by_rc2.tres")
	check(again != null and again.title == "Written by rc2" and again.created == "2026-10-20T09:15:00",
			"…and reloads with its title and created date (%s, %s)" % [again.title if again else "", again.created if again else ""])
	check(again != null and again.raw_text == "# From rc2\nA body with **bold**, a \"quote\" and a tick ✓.\nEdited here.", "…and its body")
	OS.remove_logger(errors)
	check(errors.lines.is_empty(), "no error logged while loading and saving it (%s)" % "; ".join(errors.lines))


func test_future_note_saved_by_the_app(V: String) -> void:
	var errors := ErrorLog.new()
	OS.add_logger(errors)
	var path: String = V + "note_from_the_future.tres"
	var note: ContentLayer = open_note(V, "note_from_the_future.tres", FUTURE_NOTE)
	check(note != null and note.title == "From the future", "a note from a newer build loads")
	if note == null:
		OS.remove_logger(errors)
		return
	check(note.get("future_field") == FUTURE_VALUE, "its unknown field is read (%s)" % [note.get("future_field")])
	note.raw_text = "Edited by this build."
	VaultStore.save_note(note)
	check(keeps_future_field(path), "save_note keeps the unknown field on disk, with its value")
	var disk: ContentLayer = from_disk(path)
	check(disk.starred_at == "2027-01-02T03:04:05" and disk.pinned_at == "2027-01-02T03:04:06", "…and both timestamps")
	check(disk.raw_text == "Edited by this build." and disk.tags == (["later"] as Array[String]), "…with the edit and the tags")
	note.raw_text = "Edited twice."
	VaultStore.save_note(note)
	check(keeps_future_field(path), "a second save writes it once, not twice")
	VaultStore.open_vault(V, false)
	var reopened: ContentLayer = VaultStore.load_note(VaultStore.get_note_index("From the future"))
	check(reopened != null and reopened.get("future_field") == FUTURE_VALUE, "a reopened vault still has it")
	OS.remove_logger(errors)
	check(errors.lines.is_empty(), "no error while loading and saving it (%s)" % "; ".join(errors.lines))


func test_future_note_through_mcp(V: String) -> void:
	write_text(V + "note_mcp_future.tres", FUTURE_NOTE.replace("From the future", "Future via MCP"))
	var tools: RefCounted = VaultTools.new(V)
	var read: Dictionary = tools.call_tool("read_note", {"path": "note_mcp_future.tres"})
	check(not read.isError, "MCP read_note reads it")
	var upd: Dictionary = tools.call_tool("update_note", {"path": "note_mcp_future.tres", "hash": read.structuredContent.get("hash", ""), "markdown": "Edited over MCP."})
	check(not upd.isError, "MCP update_note with the hash from read_note writes it")
	check(keeps_future_field(V + "note_mcp_future.tres"), "…and keeps the unknown field")
	var disk: ContentLayer = from_disk(V + "note_mcp_future.tres")
	check(disk.raw_text == "Edited over MCP." and disk.starred_at != "" and disk.pinned_at != "", "…and the timestamps, with the new body")


## The file changes on disk while the app has the note open: the app's
## version becomes a conflict copy, which keeps the unknown field too.
func test_future_note_conflict_copy(V: String) -> void:
	var path: String = V + "note_conflicted_future.tres"
	var note: ContentLayer = open_note(V, "note_conflicted_future.tres", FUTURE_NOTE.replace("From the future", "Conflicted future"))
	if note == null:
		check(false, "the conflicted note loads")
		return
	write_text(path, FileAccess.get_file_as_string(path).replace("Written by a newer build.", "Edited elsewhere."))
	note.raw_text = "Edited here."
	VaultStore.save_note(note)
	var copy: ContentLayer = VaultStore.last_conflict_copy
	check(copy != null and copy.resource_path != path, "an outside edit makes a conflict copy")
	if copy == null:
		return
	check(copy.get("future_field") == FUTURE_VALUE, "the copy in memory has the unknown field")
	check(keeps_future_field(copy.resource_path), "…and so does its file")
	check(keeps_future_field(path) and from_disk(path).raw_text == "Edited elsewhere.", "the outside version keeps it as well")


## FUTURE_NOTE without its future_field line: how a newer build writes the
## note once it clears that field (Godot leaves a default value out).
func without_future_field(text: String) -> String:
	return text.replace("future_field = {\n\"k\": 1\n}\n", "")


## A field removed on disk is gone from the note the app holds once it
## reloads the changed file in place (refresh_note_list, CACHE_MODE_REPLACE),
## so the next save does not write it back. The kept field stayed in
## ContentLayer._extra and came back on every save.
func test_removed_field_stays_removed(V: String) -> void:
	var path: String = V + "note_field_removed.tres"
	var text: String = FUTURE_NOTE.replace("From the future", "Field removed")
	var note: ContentLayer = open_note(V, "note_field_removed.tres", text)
	if note == null:
		check(false, "the note whose field is removed loads")
		return
	check(note.get("future_field") == FUTURE_VALUE, "(the note has future_field before)")
	OS.delay_msec(1100)   # mtimes are per second: the edit must land in a new second to be seen
	write_text(path, without_future_field(text).replace("Written by a newer build.", "Field cleared elsewhere."))
	check(not FileAccess.get_file_as_string(path).contains("future_field"), "(the file no longer holds it)")
	VaultStore.refresh_note_list()
	var again: ContentLayer = VaultStore.load_note(VaultStore.get_note_index("Field removed"))
	check(again == note and note.raw_text == "Field cleared elsewhere.", "(the app reloaded the same object in place)")
	var stored: Array = note.get_property_list().map(func(p): return p.name)
	check(note.get("future_field") == null and not stored.has("future_field"), "a field removed on disk is gone from the reloaded note (%s)" % [note.get("future_field")])
	note.raw_text = "Edited after the reload."
	VaultStore.save_note(note)
	check(VaultStore.last_conflict_copy == null and not FileAccess.get_file_as_string(path).contains("future_field"), "…and the next save does not write it back")
	check(from_disk(path).raw_text == "Edited after the reload.", "…while it saves the edit")


## The same through a conflict copy: the file changes on disk (losing the
## field) while the app has the note open. The copy keeps the app's version,
## field and all; the note reloaded from disk has no field, and saving it
## again does not bring the field back into the outside version.
func test_removed_field_after_conflict(V: String) -> void:
	var path: String = V + "note_field_removed_conflict.tres"
	var text: String = FUTURE_NOTE.replace("From the future", "Field removed in a conflict")
	var note: ContentLayer = open_note(V, "note_field_removed_conflict.tres", text)
	if note == null:
		check(false, "the note whose field is removed in a conflict loads")
		return
	write_text(path, without_future_field(text).replace("Written by a newer build.", "Field cleared elsewhere."))
	note.raw_text = "Edited here."
	VaultStore.save_note(note)
	var copy: ContentLayer = VaultStore.last_conflict_copy
	check(copy != null and keeps_future_field(copy.resource_path), "the conflict copy keeps the app's version, with the field")
	check(note.raw_text == "Field cleared elsewhere." and note.get("future_field") == null, "the note reloaded from disk has no field (%s)" % [note.get("future_field")])
	note.raw_text = "Edited after the conflict."
	VaultStore.save_note(note)
	check(not FileAccess.get_file_as_string(path).contains("future_field") and from_disk(path).raw_text == "Edited after the conflict.", "…and saving it does not write the field back")


func test_future_note_validates(V: String) -> void:
	write_text(V + "note_validated_future.tres", FUTURE_NOTE)
	var r: Dictionary = TresValidator.validate(V + "note_validated_future.tres")
	check(r.valid and r.errors.is_empty(), "TresValidator.validate reports no errors (%s)" % [r.errors])
	check(TresValidator.check_text_safe(V + "note_validated_future.tres").safe, "…and check_text_safe passes it")


## Names Godot handles itself are never taken for a note field: the
## resource's name, its script and its metadata.
func test_known_names_stay_with_godot() -> void:
	var n := ContentLayer.new()
	n.resource_name = "named"
	n.set_meta("kept_meta", 3)
	n.set("brand_new", "x")
	check(n.resource_name == "named" and n.get_meta("kept_meta") == 3, "resource_name and metadata go to Godot")
	check(n.get_script() == ContentLayer and n.get("brand_new") == "x", "the script stays, an unknown field is kept")
	var listed: Array = n.get_property_list().filter(func(p): return p.usage & PROPERTY_USAGE_STORAGE).map(func(p): return p.name)
	check(listed.count("brand_new") == 1 and listed.count("title") == 1 and listed.count("resource_name") == 1, "each stored field is listed once (%s)" % [listed])
	var copy: ContentLayer = n.duplicate()
	check(copy.get("brand_new") == "x" and copy.resource_name == "named", "duplicate() copies it")
	n.set("brand_new", "y")
	check(copy.get("brand_new") == "x", "…as its own value")
	n.set("_extra", {"title": "smuggled"})
	check(n.title == "" and n.get_property_list().filter(func(p): return p.name == "title").size() == 1, "a file's own \"_extra\" line can't add or shadow a field")
