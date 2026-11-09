extends SceneTree
## Check Ontomeme notes the way the app will read them.
##
##   godot --headless --path . -s res://scripts/lint_notes.gd -- [<src_dir>] [--vault=DIR]
##
## With <src_dir>: lints those .md files (front matter "title:" or the file
## name gives the title), resolving links against the vault + the files.
## Without it: lints every note in the vault.
##
## ERROR (exit 1) — the app would silently drop or break something:
##   unknown preset, quiz question without 2+ answers or without exactly one
##   a*, flashcard q: without a:, q:/a: before any preset, a model file that
##   doesn't exist, learn:/next: pointing at a note that doesn't exist,
##   an unclosed ``` fence.
## WARN — probably a mistake: [[link]] to a missing note (the app creates it
##   on click), objective: that names no objective in the journey, a 3D
##   block with nothing to show, a colour word it doesn't know, a
##   [text](target) link Read view won't open (not http, https or mailto),
##   an image line whose file is in neither <src_dir>/images/ nor the vault's
##   images/, or that names a web or data: URL, a path outside the vault or
##   a format other than png, jpg and webp (Read view shows no picture).
##
## The checks themselves live in note_lint.gd (NoteLint), which ships with
## the app so the MCP server can warn about the same problems on a write.
## This script only finds the notes, says what exists, and prints.

const NoteImporter = preload("res://note_importer.gd")

var errors: int = 0
var warnings: int = 0
var titles: Dictionary = {}   # lower-case title -> true
var src_models: String = ""   # <src_dir>/models, about to be imported
var src_dir: String = ""      # <src_dir>; its images/ is about to be imported
var src_objectives: Dictionary = {}   # objective names defined in front matter


func _init() -> void:
	var src: String = ""
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			src = a
	await process_frame
	VaultStore.refresh_note_list()
	var notes: Array = []   # [title, text]
	for n in VaultStore.note_list:
		titles[n.title.strip_edges().to_lower()] = true
	if src != "":
		src_models = src.path_join("models")
		src_dir = src
		for f in _md_files(src):
			var parsed: Array = _read_md(f)
			titles[parsed[0].to_lower()] = true
			notes.append(parsed)
	else:
		for n in VaultStore.note_list:
			notes.append([n.title, n.raw_text])
	var hooks: Dictionary = {"model_exists": _model_exists, "objective_exists": _objective_exists, "image_exists": _image_exists}
	for n in notes:
		for found in NoteLint.lint(n[0], n[1], func(t: String) -> bool: return titles.has(t), hooks):
			if found.level == NoteLint.ERROR:
				_err(n[0], found.line, found.message)
			else:
				_warn(n[0], found.line, found.message)
	print("%d note%s checked: %d error%s, %d warning%s" % [notes.size(), "" if notes.size() == 1 else "s",
		errors, "" if errors == 1 else "s", warnings, "" if warnings == 1 else "s"])
	quit(1 if errors > 0 else 0)


func _md_files(dir: String) -> Array:
	var out: Array = []
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() == "md" and not f.begins_with("_"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with(".") and d not in VaultStore.ASSET_DIRS:   # models/, images/
			out.append_array(_md_files(dir.path_join(d)))
	return out


func _read_md(path: String) -> Array:
	var text: String = FileAccess.get_file_as_string(path).replace("\r\n", "\n")
	var title: String = path.get_file().get_basename().replace("_", " ").strip_edges()
	if text.begins_with("---\n"):
		var end: int = text.find("\n---", 4)
		if end > 0:
			for line in text.substr(4, end - 4).split("\n"):
				if line.strip_edges().to_lower().begins_with("title:"):
					# As NoteImporter._parse reads it: unquoted (`title: "A: B"`,
					# what md_export writes), and a blank one keeps the file name.
					var t: String = NoteImporter._yaml_scalar(line.substr(line.find(":") + 1)).strip_edges()
					if t != "":
						title = t
				elif line.strip_edges().to_lower().begins_with("objective:"):
					src_objectives[line.substr(line.find(":") + 1).split("|")[0].strip_edges().to_lower()] = true
			text = text.substr(end + 4)
	return [title, text]


func _err(title: String, line: int, msg: String) -> void:
	errors += 1
	print("ERROR  %s:%d  %s" % [title, line, msg])


func _warn(title: String, line: int, msg: String) -> void:
	warnings += 1
	print("WARN   %s:%d  %s" % [title, line, msg])


## A model is there if the vault has it, or <src_dir>/models (about to be
## imported with the notes) does.
func _model_exists(file: String) -> bool:
	return FileAccess.file_exists(NoteScene3D.model_path(file)) \
			or (src_models != "" and FileAccess.file_exists(src_models.path_join(file)))


## An objective is there if the vault's journey has it, or a front matter
## line of the notes being linted defines it.
func _objective_exists(name: String) -> bool:
	return not JourneyStore.find_objective_by_name(name).is_empty() \
			or src_objectives.has(name.strip_edges().to_lower())


## An image is there if the vault has it, or <src_dir>/images/ (about to be
## imported with the notes) does. `rel` is relative to the vault.
func _image_exists(rel: String) -> bool:
	return FileAccess.file_exists(VaultStore.vault_path.path_join(rel)) \
			or (src_dir != "" and rel.begins_with(ImageEmbeds.DIR + "/") and FileAccess.file_exists(src_dir.path_join(rel)))
