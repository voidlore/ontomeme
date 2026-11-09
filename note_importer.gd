extends RefCounted
## Imports a folder of Markdown files into the open vault: one note per .md,
## sub-directories as folders, front matter for tags, Journey topics and
## objectives. Used by scripts/import_notes.gd and the first-run starter vault.
## See scripts/import_notes.gd for the file format.

var dry: bool = false
## Match a note only inside the folder it is imported into, and never replace
## a model the vault already has. The starter courses set it, so a note of
## the user's that shares a lesson's title is left where it is, untouched.
## Off (scripts/import_notes.gd): upsert by title anywhere in the vault.
var scope_to_folder: bool = false
## false (scripts/import_notes.gd, first run): a note with the same title is
## rewritten in place (scope_to_folder says which one), so re-running an
## import updates it. true (the app's imports): a title already taken gets
## "<title> (2)", "(3)"… and nothing is replaced; a note the vault already
## has (VaultStore.import_title) is skipped.
var rename_clashes: bool = false
var count: int = 0
## With rename_clashes: notes given a numbered title, and notes skipped
## because the vault already had them.
var renamed: int = 0
var same: int = 0
var _files: Array = []   # [path, folder]
var _imported: Array[ContentLayer] = []


## Import every .md under `src` (a filesystem or res:// path), into the vault
## folder `into` ("" = the vault root). Returns the number of notes imported
## (or that would be, when `dry`).
func import_dir(src: String, into: String = "") -> int:
	src = src.simplify_path()
	VaultStore.refresh_note_list()
	_copy_models(src.path_join("models"))
	_copy_images(src.path_join(ImageEmbeds.DIR), VaultStore.vault_path.path_join(ImageEmbeds.DIR))
	_walk(src, into)
	return import_queued()


## Import the .md files `paths` into the vault folder `into` ("" = the vault
## root), as import_dir imports a folder's. Returns how many were imported.
func import_files(paths: PackedStringArray, into: String = "") -> int:
	for p in paths:
		queue(p, into)
	return import_queued()


## Add the .md file `path` to the next import_queued(), into vault `folder`.
func queue(path: String, folder: String) -> void:
	_files.append([path, folder])


## Import the queued files: all their front matter first (topics and
## objectives, so one file can use an objective another defines), then the
## notes and their demonstrations. Returns how many notes were imported (or
## would be, when `dry`).
func import_queued() -> int:
	VaultStore.refresh_note_list()
	var docs: Array = []
	for f in _files:
		docs.append(_parse(f[0], f[1]))
	_files.clear()
	for d in docs:   # pass 1: topics + objectives
		_define_objectives(d.topic, d.objectives)
	for d in docs:   # pass 2: notes + demonstrations
		_import_doc(d)
	_order_sidebar()
	return count


## The notes this importer wrote, in import order.
func imported_notes() -> Array[ContentLayer]:
	return _imported


func _walk(dir: String, rel: String) -> void:
	var files: PackedStringArray = DirAccess.get_files_at(dir)
	files.sort()
	for f in files:
		if f.get_extension().to_lower() == "md" and not f.begins_with("_"):
			_files.append([dir.path_join(f), rel])
	var dirs: PackedStringArray = DirAccess.get_directories_at(dir)
	dirs.sort()
	for d in dirs:
		if d.begins_with(".") or d in VaultStore.ASSET_DIRS:   # models/, images/: files, not notes
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
			var lines: PackedStringArray = text.substr(4, end - 4).split("\n")
			for n in range(lines.size()):
				var line: String = lines[n]
				var i: int = line.find(":")
				if i <= 0 or _is_list_item(line):   # "  - a" lines belong to the key above
					continue
				var key: String = line.substr(0, i).strip_edges().to_lower()
				var val: String = line.substr(i + 1).strip_edges()
				if key == "title":
					# Unquote before the empty test: `title: ""` and `title: ''`
					# are template placeholders and keep the file-name title,
					# like a bare `title:` (notes are matched by title).
					var t: String = _yaml_scalar(val).strip_edges()
					if t != "":
						title = t
				elif key == "topic":
					topic = val
				elif key == "objective":
					var bits: PackedStringArray = val.split("|")
					var goal: String = bits[1].strip_edges().to_lower() if bits.size() > 1 else "learning"
					objectives.append([bits[0].strip_edges(), goal if goal in JourneyStore.GOALS else "learning",
						bits[2].strip_edges() if bits.size() > 2 else ""])
				elif key == "tags":
					tags = TagOps.normalize_list(_yaml_list(val) if val != "" else _yaml_block_list(lines, n + 1))
			text = text.substr(end + 4).lstrip("\n")
	text = text.strip_edges(false, true) + "\n"
	return {"title": title, "text": text, "tags": tags, "topic": topic, "objectives": objectives, "folder": folder}


# ── Front-matter values (the YAML forms md_export and Obsidian write) ───────

## A `key: value` list: the YAML flow form `[a, "b c", 'd']` (md_export
## writes this), or the legacy comma form `a, b c`. Items are unquoted.
static func _yaml_list(val: String) -> Array[String]:
	var inner: String = val
	if val.begins_with("[") and val.ends_with("]"):
		inner = val.substr(1, val.length() - 2)
	var out: Array[String] = []
	for item in _split_outside_quotes(inner):
		if item.strip_edges() != "":
			out.append(_yaml_scalar(item))
	return out


## The YAML block form: `tags:` with an empty value, then one `  - item`
## line per entry, starting at lines[from]. Stops at the first other line.
static func _yaml_block_list(lines: PackedStringArray, from: int) -> Array[String]:
	var out: Array[String] = []
	for n in range(from, lines.size()):
		if lines[n].strip_edges() == "":
			continue
		if not _is_list_item(lines[n]):
			break
		var item: String = lines[n].strip_edges().substr(1)
		if item.strip_edges() != "":
			out.append(_yaml_scalar(item))
	return out


static func _is_list_item(line: String) -> bool:
	var s: String = line.strip_edges()
	return s == "-" or s.begins_with("- ")


## Split on commas that sit outside "double" and 'single' quotes. A quote
## opens only at the start of an item (YAML), so the legacy `don't, panic`
## stays two items. Escapes are kept for _yaml_scalar to undo: \" inside
## double quotes, '' inside single quotes.
static func _split_outside_quotes(s: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var cur: String = ""
	var quote: String = ""
	var i: int = 0
	while i < s.length():
		var c: String = s[i]
		if quote == "\"" and c == "\\" and i + 1 < s.length():
			cur += c + s[i + 1]
			i += 2
			continue
		if quote == "'" and c == "'" and s.substr(i + 1, 1) == "'":
			cur += "''"
			i += 2
			continue
		if quote != "":
			if c == quote:
				quote = ""
		elif (c == "\"" or c == "'") and cur.strip_edges() == "":
			quote = c
		elif c == ",":
			out.append(cur)
			cur = ""
			i += 1
			continue
		cur += c
		i += 1
	out.append(cur)
	return out


## One YAML scalar: a "double-quoted" value loses its quotes and has \" and
## \\ unescaped (the way MdExport._quote escapes them); a 'single-quoted'
## one has '' turned back into '; a plain one is only trimmed.
static func _yaml_scalar(raw: String) -> String:
	var s: String = raw.strip_edges()
	if s.length() >= 2 and s.begins_with("'") and s.ends_with("'"):
		return s.substr(1, s.length() - 2).replace("''", "'")
	if not (s.length() >= 2 and s.begins_with("\"") and s.ends_with("\"")):
		return s
	var out: String = ""
	var i: int = 1
	while i < s.length() - 1:
		if s[i] == "\\" and i + 1 < s.length() - 1 and s[i + 1] in ["\"", "\\"]:
			i += 1
		out += s[i]
		i += 1
	return out


func _import_doc(d: Dictionary) -> void:
	var title: String = d.title
	var text: String = d.text
	var folder: String = d.folder
	var tags: Array[String] = d.tags
	var note: ContentLayer = null
	if rename_clashes:
		var place: Dictionary = VaultStore.import_title(title, text, tags)
		if place.twin != null:
			print("same    %s" % place.title)
			same += 1
			return
		if place.title != title:
			renamed += 1
			title = place.title
	else:
		note = _existing_note(title, folder)
	var verb: String = "update" if note != null else "create"
	print("%-6s  %s%s" % [verb, (folder + "/") if folder != "" else "", title])
	count += 1
	if dry:
		return
	if folder != "":
		DirAccess.make_dir_recursive_absolute(VaultStore.vault_path + folder)
	if note == null:
		note = VaultStore.create_note(title, folder)
	note.raw_text = text
	if not tags.is_empty():
		note.tags.assign(tags)
	VaultStore.save_note(note)
	if VaultStore.folder_of(note) != folder:
		VaultStore.move_note(note, folder)
	_imported.append(note)
	_link_demos(title, text)


## The note this document updates: the one titled `title` in `folder` when
## scope_to_folder, else the first one with that title anywhere (upsert).
func _existing_note(title: String, folder: String) -> ContentLayer:
	if scope_to_folder:
		return VaultStore.find_note(title, folder)
	var idx: int = VaultStore.get_note_index(title)
	return VaultStore.note_list[idx] if idx >= 0 else null


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
		VaultStore.save_note(note, false)


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
		if scope_to_folder and FileAccess.file_exists(dest.path_join(f)):
			continue   # the vault's own copy may be the user's
		if f.get_extension().to_lower() in NoteScene3D.MODEL_EXTS or f.get_extension().to_lower() == "bin" or f.get_extension().to_lower() in ["png", "jpg", "jpeg"]:
			print("model   ", f)
			if not dry:
				DirAccess.copy_absolute(dir.path_join(f), dest.path_join(f))


## Copy the pictures in <src>/images/ (and its subfolders) to <vault>/images/,
## so a course's `![alt](images/x.png)` lines show after the import. Only
## png, jpg and webp, the formats Read view loads. A file already there with
## the same bytes is left alone; a changed one is replaced, the way a
## re-imported note is updated. Prints a line for each file it copies or
## skips; a dry run copies none.
func _copy_images(dir: String, dest: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	var rel: String = dest.substr(VaultStore.vault_path.length())
	for f in DirAccess.get_files_at(dir):
		var from: String = dir.path_join(f)
		var to: String = dest.path_join(f)
		if f.get_extension().to_lower() not in ImageEmbeds.EXTS:
			print("skip    %s (the app shows png, jpg and webp)" % rel.path_join(f))
		elif not FileAccess.file_exists(to) or FileAccess.get_sha256(to) != FileAccess.get_sha256(from):
			print("image   ", rel.path_join(f))
			if not dry:
				DirAccess.make_dir_recursive_absolute(dest)
				DirAccess.copy_absolute(from, to)
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			_copy_images(dir.path_join(d), dest.path_join(d))
