extends SceneTree
## Import plain Markdown files into an Ontomeme vault.
##
##   godot --headless --path . -s res://scripts/import_notes.gd -- <src_dir> [--vault=DIR] [--dry-run]
##
## Every <src_dir>/**/*.md becomes one note. Sub-directories become vault
## folders (the vault mirrors the file system). Optional front matter:
##
##     ---
##     title: Tutorial 8: Gravity     (default: the file name, "_" -> " ")
##     tags: physics, beginner
##     topic: Physics                (Learning Journey topic, created if missing)
##     objective: Explain gravity | learning | Say why things fall.
##     ---
##
## "objective:" lines (repeatable: name | fluent/learning/forget | description)
## create objectives under the topic if they don't exist yet. Then every quiz /
## flashcard block whose own "objective: <name>" line names an objective is
## attached to it as a demonstration — the Journey is ready before anyone plays.
## Upsert by title: an existing note with the same title is rewritten in
## place (and moved to the new folder if needed), so re-running is safe.
## Sidebar order follows file names (the sidebar lists newest first, so notes
## are timestamped in reverse): prefix files 00_, 01_… to order a course.
## All front matter is read before any note is imported, so objectives
## defined in a hub note are found by lessons that sort before it.
## Files whose name starts with "_" are skipped (use them for drafts).
## Also copies <src_dir>/models/* into the vault's models/ folder.
## Prints one line per note; exit code 1 if nothing was imported.

const NoteImporter = preload("res://note_importer.gd")


func _init() -> void:
	var src: String = ""
	var dry: bool = false
	for a in OS.get_cmdline_user_args():
		if a == "--dry-run":
			dry = true
		elif a.begins_with("--vault="):
			pass   # VaultStore reads it itself
		elif src == "":
			src = a
	if src == "" or not DirAccess.dir_exists_absolute(src):
		printerr("usage: godot --headless --path . -s res://scripts/import_notes.gd -- <src_dir> [--vault=DIR] [--dry-run]")
		quit(2)
		return
	await process_frame
	print("vault: ", VaultStore.vault_path, "   (dry run)" if dry else "")
	var importer := NoteImporter.new()
	importer.dry = dry
	var count: int = importer.import_dir(src)
	print("imported %d note%s" % [count, "" if count == 1 else "s"])
	quit(0 if count > 0 else 1)
