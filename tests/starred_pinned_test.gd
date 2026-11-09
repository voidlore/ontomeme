extends SceneTree
## Starred & pinned at the store level, headless, every check through the
## real VaultStore API in throwaway vaults (never the user's, never
## user://vaults.json). A star or a pin is a timestamp string on the note's
## own .tres (empty = off), so the flag and its sort key are one field.
## Fields: a fresh note has both ""; an old-format .tres (no starred_at /
## pinned_at lines, as every pre-change note is saved) loads with both "";
## a star survives save and a reload from disk.
## Store: a live reload drops fields an outside edit removed; pinned notes
## lead the note list, newest pin first; set_starred/set_pinned toggle without
## touching `modified` and take an outside edit first instead of a conflict copy,
## but refuse (and the watcher keeps the file) when the outside version does
## not load, as with git conflict markers, or when it would drop words the
## note's failed save couldn't write; a conflict copy carries no flags.
## Icons: star and pin, outline (off) and filled (on).
## Persistence (plan step 8): flags and the pinned-first order hold over two
## reloads and a fresh read of every file; a rename, move_note and
## move_folder keep them; delete_note drops the note; a vault switch and back
## keeps them, re-read from disk; an MCP update_note keeps them on disk.
##   headless:  godot --headless --path . -s res://tests/starred_pinned_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")

var fails: int = 0
var _vaults: Array[String] = []   # section vaults, removed at the end


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## A fresh, empty throwaway vault for one section (removed at the end).
func section_vault(name: String) -> String:
	var v: String = TestVault.open("starred_pinned_" + name, false)
	_vaults.append(v)
	return v


func write_file(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## Rewrite a note's .tres the way another program would when it clears
## `fields`: their lines go, exactly as Godot omits a default-valued field.
func strip_fields_on_disk(path: String, fields: Array) -> void:
	var kept: PackedStringArray = []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var drop: bool = false
		for field in fields:
			drop = drop or line.begins_with(field + " = ")
		if not drop:
			kept.append(line)
	write_file(path, "\n".join(kept))


## A saved note with a chosen `modified` (the list's date sort key).
func note_modified_at(title: String, modified: String) -> ContentLayer:
	var n: ContentLayer = VaultStore.create_note(title)
	n.modified = modified
	VaultStore.save_note(n, false)
	return n


func pin_at(n: ContentLayer, when: String) -> void:
	n.pinned_at = when
	VaultStore.save_note(n, false)


## Another program rewrites the note's file: `from` becomes `to` on disk.
func outside_edit(path: String, from: String, to: String) -> void:
	var text: String = FileAccess.get_file_as_string(path)
	check(text.contains(from), "(outside edit finds \"%s\" on disk)" % from)
	write_file(path, text.replace(from, to))


## A git merge left the note's file half merged: their tags_label merged
## cleanly, raw_text "mine" / "theirs" sits between conflict markers.
func merge_conflict_on_disk(path: String) -> void:
	outside_edit(path, "tags_label = \"base\"", "tags_label = \"their label\"")
	outside_edit(path, "raw_text = \"mine\"\n",
		"<<<<<<< HEAD\nraw_text = \"mine\"\n=======\nraw_text = \"theirs\"\n>>>>>>> theirs\n")


## The note list in the store's order, as titles.
func titles() -> Array[String]:
	var out: Array[String] = []
	for n in VaultStore.note_list:
		out.append(n.title)
	return out


## The note as its file says now, read past the resource cache, the way a
## new launch reads it.
func disk_note(path: String) -> ContentLayer:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as ContentLayer


## The listed note titled `title`, or null.
func listed(title: String) -> ContentLayer:
	var i: int = VaultStore.get_note_index(title)
	return VaultStore.note_list[i] if i >= 0 else null


## True when `n` carries exactly these flags in memory and in its file.
func flags_kept(n: ContentLayer, starred_at: String, pinned_at: String) -> bool:
	var d: ContentLayer = disk_note(n.resource_path) if n != null else null
	return n != null and d != null and n.starred_at == starred_at and n.pinned_at == pinned_at \
		and d.starred_at == starred_at and d.pinned_at == pinned_at


## Titles of the listed notes with `field` set.
func flagged(field: StringName) -> Array[String]:
	var out: Array[String] = []
	for n in VaultStore.note_list:
		if str(n.get(field)) != "":
			out.append(n.title)
	return out


## user://vaults.json as bytes ("" when there is none), to prove a test left
## the recent-vaults list alone.
func vaults_json() -> String:
	return FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_starred.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_starred.json"   # never touch real progress
	ProgressStore.reset()

	TestVault.open("starred_pinned", false)   # empty throwaway vault, never the user's
	await frames(3)
	var V: String = VaultStore.vault_path

	# ── A fresh note starts unstarred and unpinned ──
	var fresh: ContentLayer = ContentLayer.new()
	check(fresh.starred_at == "" and fresh.pinned_at == "",
		"fresh ContentLayer() has starred_at and pinned_at both \"\"")

	# ── An old-format .tres (no starred_at/pinned_at lines) loads unstarred ──
	# Exactly how a note saved before this change looks: Godot omits the
	# default-valued props, so loading it must fall back to "".
	var old_path: String = V + "note_old_format.tres"
	var of := FileAccess.open(old_path, FileAccess.WRITE)
	of.store_string(
		"[gd_resource type=\"Resource\" script_class=\"ContentLayer\" format=3]\n\n"
		+ "[ext_resource type=\"Script\" path=\"res://ContentLayer.gd\" id=\"1_old\"]\n\n"
		+ "[resource]\n"
		+ "script = ExtResource(\"1_old\")\n"
		+ "title = \"Old Format Note\"\n"
		+ "created = \"2020-01-01T00:00:00\"\n"
		+ "modified = \"2020-01-01T00:00:00\"\n"
		+ "raw_text = \"Saved before the starred/pinned fields existed.\"\n"
	)
	of.close()
	VaultStore.refresh_note_list()
	var oi: int = VaultStore.get_note_index("Old Format Note")
	var old: ContentLayer = VaultStore.note_list[oi] if oi >= 0 else null
	check(old != null and old.starred_at == "" and old.pinned_at == "",
		"old-format .tres (no starred_at/pinned_at) loads with both \"\" (%s | %s)"
		% [old.starred_at if old else "null", old.pinned_at if old else "null"])

	# ── A star survives save and reload ──
	var n: ContentLayer = VaultStore.create_note("Star Me")
	n.raw_text = "A note worth starring."
	var mod_before: String = n.modified
	n.starred_at = Time.get_datetime_string_from_system()
	VaultStore.save_note(n, false)   # a toggle keeps `modified` as set
	check(n.starred_at != "", "setting starred_at turns the star on")
	check(n.modified == mod_before, "starring + saving does not bump modified (%s)" % n.modified)

	# The bytes on disk carry the field — a fresh launch re-reads from here.
	var disk: String = FileAccess.get_file_as_string(n.resource_path)
	check(disk.contains("starred_at"), "the on-disk .tres carries starred_at")
	check(not disk.contains("pinned_at"), "an unstarred field is omitted, not written")

	# A reload re-reads the file from disk. CACHE_MODE_REPLACE empties the
	# resource cache for the load (a fresh process always does); CACHE_MODE_REUSE
	# would hand back the in-memory object and prove nothing.
	var reread: Resource = ResourceLoader.load(n.resource_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	var star_reloaded: ContentLayer = reread as ContentLayer
	check(star_reloaded != null and star_reloaded.starred_at != "",
		"star survives save + reload from disk (%s)" % (star_reloaded.starred_at if star_reloaded else "null"))
	check(star_reloaded != null and star_reloaded.pinned_at == "",
		"reloaded note is still unpinned (pinned_at \"\")")

	test_reload_drops_removed_fields()
	test_pinned_sort_first()
	test_toggle_api()
	test_toggle_after_outside_edit()
	test_toggle_on_unreadable_outside_edit()
	if OS.get_name() in ["Linux", "macOS"]:
		test_toggle_on_read_only_file()
		test_toggle_keeps_unsaved_words()
	else:
		print("SKIP  read-only toggle (chmod) on " + OS.get_name())
	test_conflict_copy_unflagged()
	test_star_pin_icons()
	test_persist_reload_twice()
	test_persist_rename()
	test_persist_move()
	test_persist_delete()
	test_persist_vault_switch()
	test_persist_mcp_update()
	test_mcp_reports_flags()

	# Cleanup: drop the throwaway vaults and the journey/progress test files.
	TestVault.remove_tree(V)
	for v in _vaults:
		TestVault.remove_tree(v)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(JourneyStore.file_override))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ProgressStore.file_override))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


# ── A live reload drops fields an outside edit removed ──
# Godot leaves default-valued fields out of a .tres, so an outside unstar,
# unpin or "remove the last tag" deletes the line. The reload must clear them
# on the object the app holds, or the next save writes the old star back.
func test_reload_drops_removed_fields() -> void:
	var V: String = section_vault("reload")
	var n: ContentLayer = VaultStore.create_note("Reload Me")
	n.starred_at = "2026-01-01T00:00:01"
	n.pinned_at = "2026-01-01T00:00:02"
	n.tags = ["a"]
	n.raw_text = "body"
	VaultStore.save_note(n, false)
	var keep: ContentLayer = VaultStore.create_note("Left Alone")
	keep.starred_at = "2026-01-01T00:00:03"
	keep.pinned_at = "2026-01-01T00:00:04"
	keep.tags = ["b"]
	VaultStore.save_note(keep, false)
	check(FileAccess.get_file_as_string(n.resource_path).contains("starred_at"), "(setup: the star is on disk)")

	OS.delay_msec(1200)   # mtimes are per second: the outside edit must land in a new second
	strip_fields_on_disk(n.resource_path, ["starred_at", "pinned_at", "tags"])
	VaultStore.refresh_note_list()
	var i: int = VaultStore.get_note_index("Reload Me")
	check(i >= 0 and VaultStore.note_list[i] == n, "reload keeps the same note object")
	check(n.starred_at == "", "an outside unstar is seen on reload (starred_at \"%s\")" % n.starred_at)
	check(n.pinned_at == "", "an outside unpin is seen on reload (pinned_at \"%s\")" % n.pinned_at)
	check(n.tags.is_empty(), "removing every tag outside is seen on reload (%s)" % [n.tags])
	check(n.raw_text == "body" and n.title == "Reload Me", "fields the file still has are kept")

	var k: int = VaultStore.get_note_index("Left Alone")
	check(k >= 0 and VaultStore.note_list[k] == keep, "an unchanged note keeps the same object")
	check(keep.starred_at == "2026-01-01T00:00:03" and keep.pinned_at == "2026-01-01T00:00:04"
		and keep.tags == ["b"], "…and all its fields")

	VaultStore.save_note(n)
	var disk: String = FileAccess.get_file_as_string(n.resource_path)
	check(VaultStore.last_conflict_copy == null, "saving after the reload is not a conflict")
	check(not disk.contains("starred_at") and not disk.contains("pinned_at") and not disk.contains("tags = "),
		"the next save writes no stale star, pin or tags back")


# ── Pinned notes lead the list, newest pin first ──
# Then the rest by modified, newest first; starring does not reorder.
func test_pinned_sort_first() -> void:
	section_vault("sort")
	var a: ContentLayer = note_modified_at("Sort A", "2026-02-01T00:00:01")
	var b: ContentLayer = note_modified_at("Sort B", "2026-02-01T00:00:02")
	var c: ContentLayer = note_modified_at("Sort C", "2026-02-01T00:00:03")
	var d: ContentLayer = note_modified_at("Sort D", "2026-02-01T00:00:04")
	VaultStore.refresh_note_list()
	check(titles() == ["Sort D", "Sort C", "Sort B", "Sort A"], "no pins: newest modified first (%s)" % [titles()])

	pin_at(a, "2026-01-01T00:00:01")
	pin_at(b, "2026-01-01T00:00:02")
	VaultStore.refresh_note_list()
	check(titles() == ["Sort B", "Sort A", "Sort D", "Sort C"],
		"pinned first, newest pin on top, then the rest by modified (%s)" % [titles()])

	c.starred_at = "2026-01-01T00:00:09"
	VaultStore.save_note(c, false)
	VaultStore.refresh_note_list()
	check(titles() == ["Sort B", "Sort A", "Sort D", "Sort C"], "a star does not reorder the list (%s)" % [titles()])

	pin_at(b, "")
	VaultStore.refresh_note_list()
	check(titles() == ["Sort A", "Sort D", "Sort C", "Sort B"],
		"an unpinned note goes back to its modified place (%s)" % [titles()])

	pin_at(c, "2026-01-01T00:00:05")
	pin_at(d, "2026-01-01T00:00:05")
	VaultStore.refresh_note_list()
	check(titles() == ["Sort D", "Sort C", "Sort A", "Sort B"],
		"a same-second pin tie falls back to modified (%s)" % [titles()])


# ── set_starred / set_pinned: one store call per toggle ──
# `modified` never moves (a toggle must not jump the note in the date sort),
# turning on a flag that is already on keeps its timestamp, and off writes
# no line at all.
func test_toggle_api() -> void:
	var V: String = section_vault("toggle")
	var n: ContentLayer = note_modified_at("Toggle Me", "2026-03-01T00:00:00")
	check(not VaultStore.set_starred(null, true), "set_starred(null) returns false")
	check(not VaultStore.set_starred(ContentLayer.new(), true), "a note with no file returns false")
	var stray: ContentLayer = ContentLayer.new()
	stray.take_over_path(ProjectSettings.globalize_path("user://not-a-vault/note_stray.tres"))
	check(not VaultStore.set_pinned(stray, true) and stray.pinned_at == "" and not FileAccess.file_exists(stray.resource_path),
		"a note outside the vault returns false and writes nothing")

	for field in ["starred_at", "pinned_at"]:
		var setter: Callable = VaultStore.set_starred if field == "starred_at" else VaultStore.set_pinned
		check(setter.call(n, true), "%s on returns true" % field)
		var disk: String = FileAccess.get_file_as_string(n.resource_path)
		check(n.get(field) != "" and disk.contains(field + " = "), "%s on: set in memory and on disk" % field)
		check(n.modified == "2026-03-01T00:00:00" and disk.contains("modified = \"2026-03-01T00:00:00\""),
			"%s on: modified unchanged in memory and on disk (%s)" % [field, n.modified])
		check(VaultStore.last_conflict_copy == null, "%s on: no conflict copy" % field)

		n.set(field, "2020-01-01T00:00:00")   # an older stamp, so a re-stamp would show
		VaultStore.save_note(n, false)
		check(setter.call(n, true) and n.get(field) == "2020-01-01T00:00:00"
			and FileAccess.get_file_as_string(n.resource_path).contains("2020-01-01T00:00:00"),
			"%s on again keeps its timestamp (%s)" % [field, n.get(field)])

		check(setter.call(n, false), "%s off returns true" % field)
		disk = FileAccess.get_file_as_string(n.resource_path)
		check(n.get(field) == "" and not disk.contains(field), "%s off: no %s line on disk" % [field, field])
		check(n.modified == "2026-03-01T00:00:00" and disk.contains("modified = \"2026-03-01T00:00:00\""),
			"%s off: modified unchanged" % field)
		check(setter.call(n, false) and n.get(field) == "", "%s off again stays off" % field)


# A toggle on a note changed on disk takes the outside edit first (reload,
# then apply), so it never writes a "(conflict copy)".
func test_toggle_after_outside_edit() -> void:
	section_vault("toggle_outside")
	var n: ContentLayer = VaultStore.create_note("Outside Then Star")
	n.raw_text = "app body"
	VaultStore.save_note(n, false)
	var count: int = VaultStore.get_note_count()
	OS.delay_msec(1200)   # mtimes are per second: the outside edit must land in a new second
	outside_edit(n.resource_path, "raw_text = \"app body\"", "raw_text = \"outside body\"")
	check(VaultStore.set_starred(n, true), "starring a note changed on disk returns true")
	check(VaultStore.last_conflict_copy == null, "…writes no conflict copy")
	check(VaultStore.get_note_count() == count, "…keeps the note count (%d)" % VaultStore.get_note_count())
	var copies: bool = false
	for t in titles():
		copies = copies or t.contains("(conflict copy")
	check(not copies, "…and no \"(conflict copy)\" title appears (%s)" % [titles()])
	check(n.raw_text == "outside body", "…the note now shows the outside body (%s)" % n.raw_text)
	var disk: String = FileAccess.get_file_as_string(n.resource_path)
	check(disk.contains("outside body") and disk.contains("starred_at"), "…and the file has both the outside body and the star")

	# Starred outside too: the outside star (and its stamp) wins, nothing is written.
	var stamp: String = n.starred_at
	outside_edit(n.resource_path, "starred_at = \"%s\"" % stamp, "starred_at = \"2019-01-01T00:00:00\"")
	outside_edit(n.resource_path, "outside body", "outside again")
	check(VaultStore.set_starred(n, true) and VaultStore.last_conflict_copy == null,
		"starring a note starred outside writes no conflict copy")
	check(n.starred_at == "2019-01-01T00:00:00" and n.raw_text == "outside again",
		"…and takes the outside star and body (%s | %s)" % [n.starred_at, n.raw_text])


# An outside version that does not load (a git merge left conflict markers in
# it) is never overwritten: a toggle changes nothing and returns false, and the
# watcher's reload does not count the file as read, so the next save writes a
# conflict copy. Godot's in-place reload of such a file used to set the fields
# before the bad line and report success; the toggle then saved over "theirs".
func test_toggle_on_unreadable_outside_edit() -> void:
	section_vault("toggle_unreadable")
	var n: ContentLayer = VaultStore.create_note("Merge Conflict")
	var w: ContentLayer = VaultStore.create_note("Merge Watched")
	for note in [n, w]:
		note.raw_text = "mine"
		note.tags_label = "base"
		VaultStore.save_note(note, false)
	OS.delay_msec(1200)   # mtimes are per second: the outside edit must land in a new second
	merge_conflict_on_disk(n.resource_path)
	merge_conflict_on_disk(w.resource_path)
	var conflicted: String = FileAccess.get_file_as_string(n.resource_path)
	var w_conflicted: String = FileAccess.get_file_as_string(w.resource_path)

	# Loading the conflicted file prints Godot's "Parse Error" lines, which
	# run_all.sh rightly fails on for scripts; keep these deliberate ones out.
	Engine.print_error_messages = false
	check(not VaultStore.set_starred(n, true), "starring a note whose file does not load returns false")
	check(FileAccess.get_file_as_string(n.resource_path) == conflicted, "…and leaves the conflicted file byte for byte")
	check(n.starred_at == "" and n.raw_text == "mine" and n.tags_label == "base",
		"…and the app's copy as it was, no field half-read (%s | %s | %s)" % [n.starred_at, n.raw_text, n.tags_label])
	check(not VaultStore.set_pinned(n, true) and n.pinned_at == ""
		and FileAccess.get_file_as_string(n.resource_path) == conflicted, "pinning it returns false and writes nothing")

	# The 1.5 s disk watcher (refresh_note_list) is the first to see `w` change.
	VaultStore.refresh_note_list()
	var i: int = VaultStore.get_note_index("Merge Watched")
	check(i >= 0 and VaultStore.note_list[i] == w and w.raw_text == "mine" and w.tags_label == "base",
		"the watcher's reload keeps the app's copy listed, no field half-read (%s)" % w.tags_label)
	w.raw_text = "mine, edited"
	VaultStore.save_note(w)
	var copy: ContentLayer = VaultStore.last_conflict_copy
	Engine.print_error_messages = true
	check(FileAccess.get_file_as_string(w.resource_path) == w_conflicted,
		"a save after that reload does not overwrite the conflicted file")
	check(copy != null and copy.raw_text == "mine, edited" and copy.tags_label == "base",
		"…it writes the app's version as a conflict copy (%s)" % (copy.raw_text if copy else "null"))

	# The merge is resolved outside: the next toggle reads it and applies.
	write_file(n.resource_path, conflicted.replace("<<<<<<< HEAD\nraw_text = \"mine\"\n=======\n", "").replace(">>>>>>> theirs\n", ""))
	check(VaultStore.set_starred(n, true), "once the file loads again, starring returns true")
	var disk: String = FileAccess.get_file_as_string(n.resource_path)
	check(n.raw_text == "theirs" and n.tags_label == "their label" and n.starred_at != "",
		"…on the resolved version (%s | %s)" % [n.raw_text, n.tags_label])
	check(disk.contains("raw_text = \"theirs\"") and disk.contains("starred_at") and not disk.contains("<<<<<<<"),
		"…and the file has their body and the star")


# A star or pin whose save fails (a read-only file, a full disk) is put back:
# the toggle returns false, says why in last_save_error, and the note holds
# nothing its file lacks, so no star shows that a restart would lose.
func test_toggle_on_read_only_file() -> void:
	section_vault("toggle_read_only")
	var n: ContentLayer = VaultStore.create_note("Locked Flag")
	var path: String = n.resource_path
	OS.execute("chmod", ["444", path])
	var before: String = FileAccess.get_file_as_string(path)
	check(not VaultStore.set_starred(n, true) and VaultStore.last_save_error != "",
		"starring a read-only note returns false and says why (%s)" % VaultStore.last_save_error)
	check(n.starred_at == "" and FileAccess.get_file_as_string(path) == before,
		"…the star is put back and the file is unchanged")
	check(not VaultStore._unsaved_paths.has(path), "…and the note is not held as unsaved")
	check(not VaultStore.set_pinned(n, true) and n.pinned_at == "", "pinning it fails the same way")
	OS.execute("chmod", ["644", path])
	check(VaultStore.set_starred(n, true) and VaultStore.last_save_error == "" and n.starred_at != ""
		and FileAccess.get_file_as_string(path).contains("starred_at"), "once writable, starring saves the star")


# A note whose save failed holds words its file lacks (_unsaved_paths): its
# folder went read-only (chmod 555), so no conflict copy can be written there
# either, while the file itself can still be rewritten in place by another
# program. A star or pin must not load that outside version over the words:
# it changes nothing and says why. Once the folder is writable the next save
# keeps both, the outside version in the file and the words as a conflict copy.
func test_toggle_keeps_unsaved_words() -> void:
	var v: String = section_vault("toggle_unsaved")
	VaultStore.create_folder("Shared")
	var n: ContentLayer = VaultStore.create_note("Field Notes", "Shared")
	n.raw_text = "base"
	VaultStore.save_note(n, false)
	var path: String = n.resource_path
	OS.execute("chmod", ["555", v + "Shared"])
	n.raw_text = "base + THE USER'S PARAGRAPH"
	check(VaultStore.save_note(n) != OK and VaultStore._unsaved_paths.has(path),
		"(the save fails in the read-only folder: the words are only in memory)")
	OS.delay_msec(1200)   # mtimes are per second: the outside edit must land in a new second
	outside_edit(path, "raw_text = \"base\"", "raw_text = \"base + a line from the sync tool\"")
	var outside: String = FileAccess.get_file_as_string(path)
	for field: StringName in [&"starred_at", &"pinned_at"]:
		var ok: bool = VaultStore.set_starred(n, true) if field == &"starred_at" else VaultStore.set_pinned(n, true)
		check(not ok and VaultStore.last_save_error != "",
			"%s on unsaved words whose file changed outside returns false and says why (%s)" % [field, VaultStore.last_save_error])
		check(n.raw_text == "base + THE USER'S PARAGRAPH" and str(n.get(field)) == "",
			"…and the note keeps the words, unflagged (%s)" % n.raw_text)
		check(FileAccess.get_file_as_string(path) == outside and VaultStore._unsaved_paths.has(path),
			"…the outside version is untouched and the words still wait to be saved")
	OS.execute("chmod", ["755", v + "Shared"])
	var saved: Error = VaultStore.save_note(n)
	var copy: ContentLayer = VaultStore.last_conflict_copy
	check(saved == OK and copy != null and copy.raw_text == "base + THE USER'S PARAGRAPH"
		and FileAccess.get_file_as_string(copy.resource_path).contains("THE USER'S PARAGRAPH"),
		"once the folder is writable, the save keeps the words as a conflict copy")
	check(n.raw_text == "base + a line from the sync tool" and FileAccess.get_file_as_string(path) == outside,
		"…beside the outside version (%s)" % n.raw_text)
	check(VaultStore.set_starred(n, true) and n.starred_at != "", "…which then takes the star")


# A conflict copy is the app's words, not a second starred or pinned row.
func test_conflict_copy_unflagged() -> void:
	section_vault("conflict")
	var n: ContentLayer = VaultStore.create_note("Conflicted")
	n.raw_text = "mine"
	VaultStore.save_note(n)
	VaultStore.set_starred(n, true)
	VaultStore.set_pinned(n, true)
	outside_edit(n.resource_path, "raw_text = \"mine\"", "raw_text = \"theirs\"")
	n.raw_text = "mine, edited"
	VaultStore.save_note(n)
	var copy: ContentLayer = VaultStore.last_conflict_copy
	check(copy != null, "an outside edit under an unsaved change makes a conflict copy")
	check(copy != null and copy.starred_at == "" and copy.pinned_at == "",
		"the conflict copy is neither starred nor pinned (%s | %s)" % [copy.starred_at if copy else "null", copy.pinned_at if copy else "null"])
	var copy_disk: String = FileAccess.get_file_as_string(copy.resource_path) if copy else ""
	check(copy != null and not copy_disk.contains("starred_at") and not copy_disk.contains("pinned_at"), "…on disk too")
	check(n.starred_at != "" and n.pinned_at != "" and n.raw_text == "theirs", "the original keeps its star and pin with the outside body")


# ── Star and pin icons: outline for off, filled for on ──
func alpha_sum(tex: Texture2D) -> float:
	var img: Image = tex.get_image()
	var total: float = 0.0
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			total += img.get_pixel(x, y).a
	return total


func test_star_pin_icons() -> void:
	for icon in ["star", "star_filled", "pin", "pin_filled"]:
		for size in [14, 16]:
			var tex: Texture2D = Icons.get_icon(icon, size)
			check(tex != null and tex.get_width() == size and tex.get_height() == size,
				"icon %s@%d is a %dx%d texture" % [icon, size, size, size])
	for size in [14, 16]:
		for pair in [["star", "star_filled"], ["pin", "pin_filled"]]:
			var outline: float = alpha_sum(Icons.get_icon(pair[0], size))
			var filled: float = alpha_sum(Icons.get_icon(pair[1], size))
			check(outline > 0.0 and filled > 1.3 * outline,
				"%s@%d is filled: %.1f vs outline %.1f (more than 1.3x)" % [pair[1], size, filled, outline])
	check(Icons.get_icon("star_filled", 16) == Icons.get_icon("star_filled", 16), "a second get_icon call returns the cached texture")


# ── Persistence (plan step 8) ───────────────────────────────────────────────
# The flags live in each note's own .tres, not in a list keyed by title, so
# they must hold wherever the legacy star broke: reloads, renames, moves,
# vault switches and edits made outside the app.

# Two of four notes starred and two pinned (one both): two reloads keep every
# flag and the pinned-first order, and reading each file fresh, as a new
# launch does, agrees.
func test_persist_reload_twice() -> void:
	section_vault("persist")
	var a: ContentLayer = note_modified_at("Persist A", "2026-04-01T00:00:01")
	var b: ContentLayer = note_modified_at("Persist B", "2026-04-01T00:00:02")
	var c: ContentLayer = note_modified_at("Persist C", "2026-04-01T00:00:03")
	var d: ContentLayer = note_modified_at("Persist D", "2026-04-01T00:00:04")
	check(VaultStore.set_starred(a, true) and VaultStore.set_starred(c, true), "(setup: A and C starred)")
	check(VaultStore.set_pinned(b, true) and VaultStore.set_pinned(c, true), "(setup: B and C pinned)")
	# C was pinned after B (or in the same second, and C is newer by modified):
	# either way C leads, then B, then the rest newest modified first.
	var order: Array[String] = ["Persist C", "Persist B", "Persist D", "Persist A"]
	var expect: Dictionary = {}
	for n: ContentLayer in [a, b, c, d]:
		expect[n.resource_path] = [n.starred_at, n.pinned_at]
	for round in [1, 2]:
		VaultStore.refresh_note_list()
		var same: bool = VaultStore.note_list.size() == 4
		for n: ContentLayer in VaultStore.note_list:
			var want: Array = expect.get(n.resource_path, ["?", "?"])
			same = same and n.starred_at == want[0] and n.pinned_at == want[1]
		check(same, "reload %d: every star and pin is kept (starred %s, pinned %s)" % [round, flagged(&"starred_at"), flagged(&"pinned_at")])
		check(titles() == order, "reload %d: pinned first, newest pin on top, then by modified (%s)" % [round, titles()])

	var fresh: Array[ContentLayer] = []
	var agree: bool = true
	for path: String in expect:
		var n: ContentLayer = disk_note(path)
		agree = agree and n != null and n.starred_at == expect[path][0] and n.pinned_at == expect[path][1]
		if n != null:
			fresh.append(n)
	check(agree, "a fresh read of each file (as a new launch does) has the same stars and pins")
	fresh.sort_custom(VaultStore._sort_by_modified)
	var fresh_titles: Array[String] = []
	for n in fresh:
		fresh_titles.append(n.title)
	check(fresh_titles == order, "…and sorts the same (%s)" % [fresh_titles])
	check(a.modified == "2026-04-01T00:00:01" and d.modified == "2026-04-01T00:00:04", "the toggles left `modified` alone")


# A rename is a title change saved to the same file: the star is in that
# file, so it stays (the legacy star was keyed by title and was lost).
func test_persist_rename() -> void:
	section_vault("rename")
	var n: ContentLayer = VaultStore.create_note("Before Rename")
	VaultStore.set_starred(n, true)
	VaultStore.set_pinned(n, true)
	var path: String = n.resource_path
	var star: String = n.starred_at
	var pin: String = n.pinned_at
	n.title = "After Rename"   # what the title field does on Enter
	VaultStore.save_note(n)
	VaultStore.refresh_note_list()
	check(listed("After Rename") == n and n.resource_path == path, "a renamed note keeps its file (%s)" % n.resource_path.get_file())
	check(listed("Before Rename") == null and VaultStore.note_list.size() == 1, "…and the old title is gone, no second note")
	check(flags_kept(n, star, pin), "…with its star and pin, in memory and on disk")
	check(disk_note(path).title == "After Rename", "…and the new title on disk")

	check(VaultStore.update_title("After Rename", "Renamed Twice"), "update_title renames it again")
	VaultStore.refresh_note_list()
	# update_title is VaultStore.rename_note (links-names): the file takes the
	# new title's name, and the star and pin, being in it, go along
	check(listed("Renamed Twice") == n and n.resource_path == path.get_base_dir().path_join("note_renamed_twice.tres") and not FileAccess.file_exists(path)
		and flags_kept(n, star, pin), "update_title renames the file, and the star and the pin go with it (%s)" % n.resource_path.get_file())


# move_note and move_folder rename files on disk: the flags travel with them.
func test_persist_move() -> void:
	var V: String = section_vault("move")
	var n: ContentLayer = VaultStore.create_note("Moved Note")
	VaultStore.set_starred(n, true)
	VaultStore.set_pinned(n, true)
	var star: String = n.starred_at
	var pin: String = n.pinned_at
	var old_path: String = n.resource_path
	check(VaultStore.move_note(n, "Sub"), "move_note into Sub returns true")
	VaultStore.refresh_note_list()
	check(listed("Moved Note") == n and VaultStore.folder_of(n) == "Sub" and not FileAccess.file_exists(old_path),
		"the note now lives in Sub (%s)" % n.resource_path.substr(V.length()))
	check(flags_kept(n, star, pin), "move_note keeps the star and pin at the new path")

	var inside: ContentLayer = VaultStore.create_note("In The Box", "Box")
	VaultStore.set_pinned(inside, true)
	VaultStore.set_starred(inside, true)
	var in_star: String = inside.starred_at
	var in_pin: String = inside.pinned_at
	check(VaultStore.move_folder("Box", "Shelf/Box") == "Shelf/Box", "move_folder Box → Shelf/Box")
	VaultStore.refresh_note_list()
	check(listed("In The Box") == inside and VaultStore.folder_of(inside) == "Shelf/Box"
		and inside.resource_path == V + "Shelf/Box/" + inside.resource_path.get_file(), "the folder's note moved with it")
	check(flags_kept(inside, in_star, in_pin), "move_folder keeps its star and pin at the new path")
	check(VaultStore.note_list.size() == 2 and flagged(&"pinned_at").size() == 2, "both notes are still listed and pinned")

	# The moved files were never read at their new paths: a toggle there must
	# still just write, not mistake the move for an outside edit.
	check(VaultStore.set_starred(n, false) and VaultStore.last_conflict_copy == null and flags_kept(n, "", pin),
		"unstarring the moved note writes no conflict copy")
	check(VaultStore.set_pinned(inside, false) and VaultStore.last_conflict_copy == null and flags_kept(inside, in_star, ""),
		"unpinning the note in the moved folder writes no conflict copy")
	check(VaultStore.note_list.size() == 2, "…and no copy appears (%s)" % [titles()])


# delete_note removes the file, and the note leaves every list with it.
func test_persist_delete() -> void:
	section_vault("delete")
	var doomed: ContentLayer = VaultStore.create_note("Doomed")
	var kept: ContentLayer = VaultStore.create_note("Survivor")
	VaultStore.set_starred(doomed, true)
	VaultStore.set_pinned(doomed, true)
	VaultStore.set_starred(kept, true)
	var path: String = doomed.resource_path
	check(VaultStore.delete_note(VaultStore.note_list.find(doomed)), "delete_note on a starred, pinned note returns true")
	check(not VaultStore.note_list.has(doomed) and listed("Doomed") == null, "the deleted note is gone from note_list")
	check(not FileAccess.file_exists(path), "…and its file from disk")
	VaultStore.refresh_note_list()
	check(listed("Doomed") == null and flagged(&"pinned_at").is_empty() and flagged(&"starred_at") == ["Survivor"],
		"after a reload nothing pinned is left and only Survivor is starred (%s)" % [flagged(&"starred_at")])


# A vault switch reads the other vault's files; switching back reads this
# one's again, from disk. Neither switch is remembered in user://vaults.json.
func test_persist_vault_switch() -> void:
	var registry: String = vaults_json()
	var first: String = section_vault("switch_first")
	var n: ContentLayer = VaultStore.create_note("Starred Here")
	VaultStore.set_starred(n, true)
	VaultStore.set_pinned(n, true)
	var path: String = n.resource_path
	var star: String = n.starred_at
	var pin: String = n.pinned_at
	n = null   # let the cached object go, so switching back must read the file

	var second: String = TestVault.open("starred_pinned_switch_second", true)   # seeded, opened with remember = false
	_vaults.append(second)
	check(VaultStore.vault_path == second and VaultStore.note_list.size() > 0, "the second vault is open, with its own notes (%d)" % VaultStore.note_list.size())
	check(flagged(&"starred_at").is_empty() and flagged(&"pinned_at").is_empty(),
		"the second vault has no starred or pinned notes (%s | %s)" % [flagged(&"starred_at"), flagged(&"pinned_at")])
	check(not ResourceLoader.has_cached(path), "(the first vault's note is no longer held in memory)")

	VaultStore.open_vault(first, false)
	var back: ContentLayer = listed("Starred Here")
	check(VaultStore.vault_path == first and back != null and back.resource_path == path, "switching back lists the note again")
	check(flags_kept(back, star, pin), "…still starred and pinned, with the same stamps (%s | %s)"
		% [back.starred_at if back else "null", back.pinned_at if back else "null"])
	check(VaultStore.set_starred(back, false) and VaultStore.last_conflict_copy == null and flags_kept(back, "", pin),
		"a toggle after the switch writes no conflict copy")
	check(vaults_json() == registry, "the switches left user://vaults.json as it was")


# The MCP server's update_note loads the .tres, edits it and saves it whole,
# so the user's star and pin survive an assistant's edit; the app then takes
# that edit before its next toggle.
func test_persist_mcp_update() -> void:
	section_vault("mcp")
	var n: ContentLayer = VaultStore.create_note("Edited By Claude")
	n.raw_text = "before"
	VaultStore.save_note(n, false)
	VaultStore.set_starred(n, true)
	VaultStore.set_pinned(n, true)
	var star: String = n.starred_at
	var pin: String = n.pinned_at
	var tools: RefCounted = VaultTools.new(VaultStore.vault_path)
	var rel: String = n.resource_path.substr(VaultStore.vault_path.length())
	var read: Dictionary = tools.call_tool("read_note", {"path": rel})
	var upd: Dictionary = tools.call_tool("update_note", {"path": rel, "hash": read.structuredContent.get("hash", ""),
		"markdown": "after", "title": "Edited By Claude", "tags": ["mcp"]})
	check(not upd.isError, "MCP update_note on a starred, pinned note succeeds (%s)" % upd.content[0].text)
	var d: ContentLayer = disk_note(n.resource_path)
	check(d != null and d.raw_text == "after" and d.tags == ["mcp"], "…and writes the new body and tags")
	check(d != null and d.starred_at == star and d.pinned_at == pin, "…keeping starred_at and pinned_at on disk (%s | %s)"
		% [d.starred_at if d else "null", d.pinned_at if d else "null"])

	check(VaultStore.set_pinned(n, false) and VaultStore.last_conflict_copy == null, "unpinning in the app afterwards writes no conflict copy")
	d = disk_note(n.resource_path)
	check(n.raw_text == "after" and n.starred_at == star and n.pinned_at == "", "…the app's note has the MCP body and keeps its star")
	check(d.raw_text == "after" and d.tags == ["mcp"] and d.starred_at == star and d.pinned_at == "",
		"…and so does the file: the MCP edit, the star, no pin")


# ── MCP list_notes, read_note and search_notes report the flags ─────────────
# As strings, "" = off, so an assistant sees what the user starred or pinned.
func test_mcp_reports_flags() -> void:
	section_vault("mcp_fields")
	var starred: ContentLayer = VaultStore.create_note("MCP Starred")
	var pinned: ContentLayer = VaultStore.create_note("MCP Pinned")
	var plain: ContentLayer = VaultStore.create_note("MCP Plain")
	VaultStore.set_starred(starred, true)
	VaultStore.set_pinned(pinned, true)
	var tools: RefCounted = VaultTools.new(VaultStore.vault_path)
	var rel: Dictionary = {}
	for n: ContentLayer in [starred, pinned, plain]:
		rel[n] = n.resource_path.substr(VaultStore.vault_path.length())

	var by_path: Dictionary = {}
	for entry: Dictionary in tools.call_tool("list_notes", {}).structuredContent.get("notes", []):
		by_path[entry.path] = entry
	var s: Dictionary = by_path.get(rel[starred], {})
	var p: Dictionary = by_path.get(rel[pinned], {})
	var o: Dictionary = by_path.get(rel[plain], {})
	check(s.get("starred_at") == starred.starred_at and starred.starred_at != "" and s.get("pinned_at") == "",
		"list_notes: the starred note has its starred_at, pinned_at \"\" (%s | %s)" % [s.get("starred_at"), s.get("pinned_at")])
	check(p.get("pinned_at") == pinned.pinned_at and pinned.pinned_at != "" and p.get("starred_at") == "",
		"list_notes: the pinned note has its pinned_at, starred_at \"\" (%s | %s)" % [p.get("starred_at"), p.get("pinned_at")])
	check(o.get("starred_at") is String and o.get("pinned_at") is String and o.starred_at == "" and o.pinned_at == "",
		"list_notes: an unflagged note reports both as \"\" strings (%s | %s)" % [o.get("starred_at"), o.get("pinned_at")])

	var rd: Dictionary = tools.call_tool("read_note", {"path": rel[starred]}).structuredContent
	check(rd.get("starred_at") == starred.starred_at and rd.get("pinned_at") == "",
		"read_note: starred_at %s, pinned_at \"%s\"" % [rd.get("starred_at"), rd.get("pinned_at")])
	var hits: Array = tools.call_tool("search_notes", {"title": "mcp pinned"}).structuredContent.get("notes", [])
	check(hits.size() == 1 and hits[0].get("pinned_at") == pinned.pinned_at and hits[0].get("starred_at") == "",
		"search_notes: a hit carries pinned_at and starred_at")

	var upd: Dictionary = tools.call_tool("update_note", {"path": rel[starred], "hash": rd.get("hash", ""), "markdown": "edited over MCP"})
	var after: Dictionary = tools.call_tool("read_note", {"path": rel[starred]}).structuredContent
	check(not upd.isError and after.get("markdown") == "edited over MCP" and after.get("starred_at") == starred.starred_at,
		"read_note after update_note still reports the same starred_at (%s)" % after.get("starred_at"))
	check(disk_note(starred.resource_path).starred_at == starred.starred_at, "…and it is on disk")

	var described: Dictionary = {}
	for t: Dictionary in tools.list_tools():
		described[t.name] = str(t.description)
	for tool in ["list_notes", "read_note"]:
		check(described.get(tool, "").contains("starred_at") and described.get(tool, "").contains("pinned_at"),
			"the %s description mentions starred_at and pinned_at" % tool)
