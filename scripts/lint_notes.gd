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
##   block with nothing to show, a colour word it doesn't know.

var errors: int = 0
var warnings: int = 0
var titles: Dictionary = {}   # lower-case title -> true
var src_models: String = ""   # <src_dir>/models, about to be imported
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
		for f in _md_files(src):
			var parsed: Array = _read_md(f)
			titles[parsed[0].to_lower()] = true
			notes.append(parsed)
	else:
		for n in VaultStore.note_list:
			notes.append([n.title, n.raw_text])
	for n in notes:
		_lint(n[0], n[1])
	print("%d note%s checked: %d error%s, %d warning%s" % [notes.size(), "" if notes.size() == 1 else "s",
		errors, "" if errors == 1 else "s", warnings, "" if warnings == 1 else "s"])
	quit(1 if errors > 0 else 0)


func _md_files(dir: String) -> Array:
	var out: Array = []
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() == "md" and not f.begins_with("_"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with(".") and d != "models":
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
					title = line.substr(line.find(":") + 1).strip_edges()
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


func _exists(t: String) -> bool:
	return titles.has(t.trim_prefix("[[").trim_suffix("]]").strip_edges().to_lower())


func _lint(title: String, text: String) -> void:
	var lines: PackedStringArray = text.split("\n")
	var link_rx := RegEx.new()
	link_rx.compile("\\[\\[([^\\]|]+)(?:\\|[^\\]]+)?\\]\\]")
	var in_code: bool = false
	var fence_len: int = 0
	var fence_info: String = ""
	var start: int = 0
	var block: PackedStringArray = []
	for i in range(lines.size()):
		var s: String = lines[i].strip_edges()
		var ticks: int = 0
		while ticks < s.length() and s[ticks] == "`":
			ticks += 1
		if in_code:
			if ticks >= fence_len and s.substr(ticks).strip_edges() == "":
				if NoteScene3D.is_scene_fence(fence_info):
					_lint_block(title, start + 1, fence_info, block)
				in_code = false
				block.clear()
			else:
				block.append(lines[i])
			continue
		if ticks >= 3:
			in_code = true
			fence_len = ticks
			fence_info = s.substr(ticks).strip_edges()
			start = i
			continue
		for m in link_rx.search_all(lines[i]):
			if not _exists(m.get_string(1)):
				_warn(title, i + 1, "link to a note that doesn't exist: [[%s]]" % m.get_string(1).strip_edges())
	if in_code:
		_err(title, start + 1, "``` fence is never closed (the rest of the note renders as code)")


func _lint_block(title: String, line: int, info: String, lines: PackedStringArray) -> void:
	var p: Dictionary = NoteScene3D.parse_block(info, lines)
	var objs: Array[Dictionary] = NoteScene3D.parse_objects(lines)
	var preset: String = str(p.get("preset", "shapes" if not objs.is_empty() else "galaxy")).to_lower()
	if preset == "cards":
		preset = "flashcards"
	if not NoteScene3D.PRESETS.has(preset):
		_err(title, line, "unknown preset '%s' (known: %s)" % [preset, ", ".join(NoteScene3D.PRESETS.keys())])
		return
	for o in objs:
		if o.kind == "model" and not FileAccess.file_exists(NoteScene3D.model_path(o.file)) \
				and not (src_models != "" and FileAccess.file_exists(src_models.path_join(o.file))):
			_err(title, line, "model file not found: %s (put it in the vault's models/ folder)" % NoteScene3D.model_path(o.file))
	if preset != "quiz":
		for l in lines:
			var w: PackedStringArray = l.strip_edges().split(" ", false)
			if w.size() >= 2 and not w[0].ends_with(":") and (w[0].to_lower() == "model" or NoteScene3D.SHAPES.has(w[0].to_lower())):
				_err(title, line, "'%s' is missing its colon — scene lines are  %s: …  (only quiz answers drop it)" % [l.strip_edges(), w[0]])
	for k in ["next"]:
		if p.has(k) and not _exists(str(p[k])):
			_err(title, line, "%s: points at a missing note '%s'" % [k, p[k]])
	if p.has("objective") and JourneyStore.find_objective_by_name(str(p.objective)).is_empty() \
			and not src_objectives.has(str(p.objective).strip_edges().to_lower()):
		_warn(title, line, "objective: '%s' isn't in this vault's journey yet (scores won't log until it exists)" % p.objective)
	match preset:
		"quiz":
			_lint_quiz(title, line, lines)
		"flashcards":
			var fronts: int = 0
			for l in lines:
				if l.strip_edges().begins_with("q:"):
					fronts += 1
			var cards: int = NoteScene3D.parse_cards(lines).size()
			if cards == 0:
				_err(title, line, "flashcards block has no complete q:/a: cards")
			elif cards != fronts:
				_err(title, line, "%d flashcard q: lines but only %d have an a: right after" % [fronts, cards])
		"shapes":
			if objs.is_empty():
				_warn(title, line, "shapes block with no objects (add lines like  cube: red)")
			for l in lines:
				var i: int = l.find(":")
				if i <= 0:
					continue
				var key: String = l.substr(0, i).strip_edges().to_lower()
				if NoteScene3D.SHAPES.has(key):
					for part in l.substr(i + 1).split(","):
						var w: String = part.strip_edges().to_lower()
						if w == "" or w.begins_with("at ") or w.begins_with("size ") or w.begins_with("spin") or w.begins_with("label "):
							continue
						if not NoteScene3D.color_from(w).ok:
							_warn(title, line, "'%s' isn't a colour the app knows (use a name like red or #ff8800)" % w)


func _lint_quiz(title: String, line: int, lines: PackedStringArray) -> void:
	# Re-parse without the app's filter so dropped questions can be reported.
	var qs: Array = []
	for raw in lines:
		var s: String = str(raw).strip_edges()
		var i: int = s.find(":")
		if i <= 0:
			continue
		var key: String = s.substr(0, i).strip_edges().to_lower()
		var val: String = s.substr(i + 1).strip_edges()
		if key in ["q", "question"]:
			qs.append({"q": val, "n": 0, "right": 0, "learn": ""})
		elif qs.is_empty():
			if key in ["a", "a*", "*a", "learn", "why"]:
				_err(title, line, "'%s:' before the first q:" % key)
		elif key in ["a", "a*", "*a"]:
			qs[-1].n += 1
			if key != "a":
				qs[-1].right += 1
		elif key in ["learn", "review", "see"]:
			qs[-1].learn = val
	if qs.is_empty():
		_err(title, line, "quiz block has no questions")
	for q in qs:
		if q.n < 2:
			_err(title, line, "question '%s' needs at least 2 answers (it will be dropped)" % q.q)
		if q.right != 1:
			_err(title, line, "question '%s' needs exactly one a*: (has %d)" % [q.q, q.right])
		if q.n > 4:
			_warn(title, line, "question '%s' has %d answers; 3–4 fit the board best" % [q.q, q.n])
		if q.learn != "" and not _exists(q.learn):
			_err(title, line, "learn: points at a missing note '%s'" % q.learn)
