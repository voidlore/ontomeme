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

var dry: bool = false
var count: int = 0
var _files: Array = []   # [path, folder]
var _imported: Array[ContentLayer] = []


func _init() -> void:
	var src: String = ""
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
	src = src.simplify_path()
	await process_frame
	VaultStore.refresh_note_list()
	print("vault: ", VaultStore.vault_path, "   (dry run)" if dry else "")
	_copy_models(src.path_join("models"))
	_walk(src, "")
	var docs: Array = []
	for f in _files:
		docs.append(_parse(f[0], f[1]))
	for d in docs:   # pass 1: topics + objectives
		_define_objectives(d.topic, d.objectives)
	for d in docs:   # pass 2: notes + demonstrations
		_import_doc(d)
	_order_sidebar()
	print("imported %d note%s" % [count, "" if count == 1 else "s"])
	quit(0 if count > 0 else 1)


func _walk(dir: String, rel: String) -> void:
	var files: PackedStringArray = DirAccess.get_files_at(dir)
	files.sort()
	for f in files:
		if f.get_extension().to_lower() == "md" and not f.begins_with("_"):
			_files.append([dir.path_join(f), rel])
	var dirs: PackedStringArray = DirAccess.get_directories_at(dir)
	dirs.sort()
	for d in dirs:
		if d.begins_with(".") or d == "models":
			continue
		_walk(dir.path_join(d), rel.path_join(d) if rel != "" else d)


func _parse(path: String, folder: String) -> Dictionary:
	var text: String = FileAccess.get_file_as_string(path).replace("\r\n", "\n")
	var title: String = path.get_file().get_basename().replace("_", " ").strip_edges()
	var tags: Array[String] = []
	var topic: String = ""
	var objectives: Array = []   # [name, goal, description]
	if text.begins_with("---\n"):
		var end: int = text.find("\n---", 4)
		if end > 0:
			for line in text.substr(4, end - 4).split("\n"):
				var i: int = line.find(":")
				if i <= 0:
					continue
				var key: String = line.substr(0, i).strip_edges().to_lower()
				var val: String = line.substr(i + 1).strip_edges()
				if key == "title" and val != "":
					title = val
				elif key == "topic":
					topic = val
				elif key == "objective":
					var bits: PackedStringArray = val.split("|")
					var goal: String = bits[1].strip_edges().to_lower() if bits.size() > 1 else "learning"
					objectives.append([bits[0].strip_edges(), goal if goal in JourneyStore.GOALS else "learning",
						bits[2].strip_edges() if bits.size() > 2 else ""])
				elif key == "tags":
					for t in val.split(",", false):
						if t.strip_edges() != "":
							tags.append(t.strip_edges())
			text = text.substr(end + 4).lstrip("\n")
	text = text.strip_edges(false, true) + "\n"
	return {"title": title, "text": text, "tags": tags, "topic": topic, "objectives": objectives, "folder": folder}


func _import_doc(d: Dictionary) -> void:
	var title: String = d.title
	var text: String = d.text
	var folder: String = d.folder
	var tags: Array[String] = d.tags
	var idx: int = VaultStore.get_note_index(title)
	var verb: String = "update" if idx >= 0 else "create"
	print("%-6s  %s%s" % [verb, (folder + "/") if folder != "" else "", title])
	count += 1
	if dry:
		return
	if folder != "":
		DirAccess.make_dir_recursive_absolute(VaultStore.vault_path + folder)
	var note: ContentLayer = VaultStore.note_list[idx] if idx >= 0 else VaultStore.create_note(title, folder)
	note.raw_text = text
	if not tags.is_empty():
		note.tags.assign(tags)
	VaultStore.save_note(note)
	if VaultStore.folder_of(note) != folder:
		VaultStore.move_note(note, folder)
	_imported.append(note)
	_link_demos(title, text)


## First file on top: the sidebar sorts by modified, newest first.
func _order_sidebar() -> void:
	if dry:
		return
	# Local time, like every other timestamp the app writes
	var now: int = Time.get_unix_time_from_datetime_string(Time.get_datetime_string_from_system())
	var n: int = _imported.size()
	for i in range(n):
		var note: ContentLayer = _imported[i]
		note.modified = Time.get_datetime_string_from_unix_time(now + (n - i))
		ResourceSaver.save(note, note.resource_path)


func _define_objectives(topic: String, objectives: Array) -> void:
	if dry:
		for o in objectives:
			print("goal    %s  (%s)" % [o[0], o[1]])
		return
	if not objectives.is_empty():
		var t: Dictionary = {}
		for x in JourneyStore.topics():
			if str(x.name).to_lower() == (topic if topic != "" else "Imported").to_lower():
				t = x
		if t.is_empty():
			t = JourneyStore.add_topic(topic if topic != "" else "Imported")
			print("topic   ", t.name)
		for o in objectives:
			if JourneyStore.find_objective_by_name(o[0]).is_empty():
				JourneyStore.add_objective(t.id, o[0], o[2], o[1])
				print("goal    %s  (%s)" % [o[0], o[1]])


func _link_demos(title: String, text: String) -> void:
	var counts: Dictionary = {"quiz": 0, "cards": 0}
	for b in JourneyStore.scene_blocks(text):
		var kind: String = JourneyStore.activity_kind(b.params)
		if kind == "":
			continue
		var key: String = JourneyStore.activity_key(title, kind, counts[kind])
		counts[kind] += 1
		var name: String = str(b.params.get("objective", "")).strip_edges()
		if name == "":
			continue
		var o: Dictionary = JourneyStore.find_objective_by_name(name)
		if o.is_empty():
			print("WARN    no objective named '%s' (define it with an objective: front-matter line)" % name)
			continue
		JourneyStore.add_demo(o.id, key, "percent")
		print("demo    %s  →  %s" % [key, name])


func _copy_models(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	var dest: String = VaultStore.vault_path.path_join("models")
	if not dry:
		DirAccess.make_dir_recursive_absolute(dest)
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() in NoteScene3D.MODEL_EXTS or f.get_extension().to_lower() == "bin" or f.get_extension().to_lower() in ["png", "jpg", "jpeg"]:
			print("model   ", f)
			if not dry:
				DirAccess.copy_absolute(dir.path_join(f), dest.path_join(f))
