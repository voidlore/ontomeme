class_name NoteLint
extends RefCounted
## NoteLint — the note checks behind scripts/lint_notes.gd and the MCP
## server's write warnings: what the app would drop, break or render wrong in
## one note's Markdown. It ships with the app (it sits outside scripts/ and
## tests/), so the MCP server can use it in an exported build.
##
##   var found := NoteLint.lint("My Note", text, func(t): return titles.has(t))
##   # → [{level: "error", line: 12, message: "learn: points at a missing note 'X'"}, ...]
##
## level "error": the app would silently drop or break something (unknown
##   preset, quiz question without 2+ answers or without exactly one a*,
##   flashcard q: without a:, q:/a: before any preset, a model file that
##   doesn't exist, learn:/next: pointing at a note that doesn't exist, an
##   unclosed ``` fence).
## level "warning": probably a mistake ([[link]] to a missing note, which the
##   app creates on click; links read as WikiLinks reads them, so
##   [[Title#Heading]] names Title and a [[link]] in a `code span` is none;
##   objective: naming no objective in the journey; a 3D
##   block with nothing to show; a colour word it doesn't know; a
##   [text](target) link Read view won't open, not http, https or mailto; an
##   image line Read view shows as text instead of the picture: its file is
##   missing, or it names a web or data: URL, a path outside the vault or a
##   format other than png, jpg and webp).
##
## `line` is 1-based in `text`; a problem inside a ```3d block is reported on
## the block's opening fence line.
##
## Fences close the way layer_engine and JourneyStore.scene_blocks close them:
## only on a line of at least as many backticks and nothing else. All three
## must agree, or activity indices drift.

const ERROR: String = "error"
const WARNING: String = "warning"

## [text](target), not ![image](…) nor [[link]]: Read view opens only a web
## target (LayerEngine.is_web_link) and shows the rest as typed.
const _MD_LINK_RX: String = "(?<![!\\[])\\[([^\\[\\]]+)\\]\\(((?:[^()\\s]|\\([^()\\s]*\\))+)\\)"


## Every problem in one note, in reading order, as {level, line, message}.
##
## title_exists(title_lowercase) -> bool says whether a note of that title
## exists (it gets the target of a [[link]], learn: or next:, trimmed and
## lowercased, then that target minus each "#heading" as WikiLinks.resolve
## tries them); the note itself, `title`, always counts as existing.
## `hooks` optionally replaces how the vault is looked up (each a Callable):
##   model_path(file) -> String    where a `model:` line's file is looked for
##       and reported (default NoteScene3D.model_path: the open vault's models/)
##   model_exists(file) -> bool    (default: a file is at model_path(file))
##   objective_exists(name) -> bool    (default: the open journey has an
##       objective of that name, JourneyStore.find_objective_by_name)
##   vault -> String    the vault an image line's path resolves in (default
##       VaultStore.vault_path, the open vault)
##   image_exists(rel) -> bool    whether the image `rel` (relative to that
##       vault, e.g. "images/a.png") is there (default: a file at vault/rel)
static func lint(title: String, text: String, title_exists: Callable, hooks: Dictionary = {}) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var exists: Callable = func(t: String) -> bool:
		var want: String = t.trim_prefix("[[").trim_suffix("]]")
		var me: String = title.strip_edges().to_lower()
		var cut: int = want.length()
		while cut >= 0:
			want = want.substr(0, cut)
			var key: String = want.strip_edges().to_lower()
			if key != "" and (key == me or title_exists.call(key)):
				return true
			cut = want.rfind("#")
		return false
	var lines: PackedStringArray = text.split("\n")
	var md_link_rx := RegEx.new()
	md_link_rx.compile(_MD_LINK_RX)
	var code_span_rx := RegEx.new()
	code_span_rx.compile("`[^`]*`")
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
					_lint_block(out, start + 1, fence_info, block, exists, hooks)
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
		# The line is outside a fence, so WikiLinks.spans only skips its code spans.
		for span in WikiLinks.spans(lines[i]):
			if not exists.call(str(span.text)):
				_add(out, WARNING, i + 1, "link to a note that doesn't exist: [[%s]]" % span.text)
		for m in md_link_rx.search_all(code_span_rx.sub(lines[i], "", true)):
			if not LayerEngine.is_web_link(m.get_string(2)):
				_add(out, WARNING, i + 1, "[%s](%s) shows as plain text: link notes with [[ ]], web pages with http(s):// or mailto:" % [m.get_string(1), m.get_string(2)])
		# A line that is exactly one image (ImageEmbeds.parse_line, the
		# renderer's own rule; the fences above are refs_in's too).
		var image: Dictionary = ImageEmbeds.parse_line(lines[i])
		if not image.is_empty():
			var problem: String = _image_problem(str(image.target), hooks)
			if problem != "":
				_add(out, WARNING, i + 1, problem)
	if in_code:
		_add(out, ERROR, start + 1, "``` fence is never closed (the rest of the note renders as code)")
	return out


static func _add(out: Array[Dictionary], level: String, line: int, message: String) -> void:
	out.append({"level": level, "line": line, "message": message})


static func _lint_block(out: Array[Dictionary], line: int, info: String, lines: PackedStringArray, exists: Callable, hooks: Dictionary) -> void:
	var p: Dictionary = NoteScene3D.parse_block(info, lines)
	var objs: Array[Dictionary] = NoteScene3D.parse_objects(lines)
	var preset: String = str(p.get("preset", "shapes" if not objs.is_empty() else "galaxy")).to_lower()
	if preset == "cards":
		preset = "flashcards"
	if not NoteScene3D.PRESETS.has(preset):
		_add(out, ERROR, line, "unknown preset '%s' (known: %s)" % [preset, ", ".join(NoteScene3D.PRESETS.keys())])
		return
	for o in objs:
		if o.kind == "model" and not _model_exists(o.file, hooks):
			_add(out, ERROR, line, "model file not found: %s (put it in the vault's models/ folder)" % _model_path(o.file, hooks))
	if preset != "quiz":
		for l in lines:
			var w: PackedStringArray = l.strip_edges().split(" ", false)
			if w.size() >= 2 and not w[0].ends_with(":") and (w[0].to_lower() == "model" or NoteScene3D.SHAPES.has(w[0].to_lower())):
				_add(out, ERROR, line, "'%s' is missing its colon — scene lines are  %s: …  (only quiz answers drop it)" % [l.strip_edges(), w[0]])
	for k in ["next"]:
		if p.has(k) and not exists.call(str(p[k])):
			_add(out, ERROR, line, "%s: points at a missing note '%s'" % [k, p[k]])
	if p.has("objective") and not _objective_exists(str(p.objective), hooks):
		_add(out, WARNING, line, "objective: '%s' isn't in this vault's journey yet (scores won't log until it exists)" % p.objective)
	match preset:
		"quiz":
			_lint_quiz(out, line, lines, exists)
		"flashcards":
			var fronts: int = 0
			for l in lines:
				if l.strip_edges().begins_with("q:"):
					fronts += 1
			var cards: int = NoteScene3D.parse_cards(lines).size()
			if cards == 0:
				_add(out, ERROR, line, "flashcards block has no complete q:/a: cards")
			elif cards != fronts:
				_add(out, ERROR, line, "%d flashcard q: lines but only %d have an a: right after" % [fronts, cards])
		"shapes":
			if objs.is_empty():
				_add(out, WARNING, line, "shapes block with no objects (add lines like  cube: red)")
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
							_add(out, WARNING, line, "'%s' isn't a colour the app knows (use a name like red or #ff8800)" % w)


static func _lint_quiz(out: Array[Dictionary], line: int, lines: PackedStringArray, exists: Callable) -> void:
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
				_add(out, ERROR, line, "'%s:' before the first q:" % key)
		elif key in ["a", "a*", "*a"]:
			qs[-1].n += 1
			if key != "a":
				qs[-1].right += 1
		elif key in ["learn", "review", "see"]:
			qs[-1].learn = val
	if qs.is_empty():
		_add(out, ERROR, line, "quiz block has no questions")
	for q in qs:
		if q.n < 2:
			_add(out, ERROR, line, "question '%s' needs at least 2 answers (it will be dropped)" % q.q)
		if q.right != 1:
			_add(out, ERROR, line, "question '%s' needs exactly one a*: (has %d)" % [q.q, q.right])
		if q.n > 4:
			_add(out, WARNING, line, "question '%s' has %d answers; 3–4 fit the board best" % [q.q, q.n])
		if q.learn != "" and not exists.call(q.learn):
			_add(out, ERROR, line, "learn: points at a missing note '%s'" % q.learn)


static func _model_path(file: String, hooks: Dictionary) -> String:
	var custom: Variant = hooks.get("model_path")
	return custom.call(file) if custom is Callable and (custom as Callable).is_valid() else NoteScene3D.model_path(file)


static func _model_exists(file: String, hooks: Dictionary) -> bool:
	var custom: Variant = hooks.get("model_exists")
	if custom is Callable and (custom as Callable).is_valid():
		return custom.call(file)
	return FileAccess.file_exists(_model_path(file, hooks))


## Why Read view would show the image line naming `target` as text instead
## of the picture, or "" when its file is there.
static func _image_problem(target: String, hooks: Dictionary) -> String:
	var shown: String = target if target.length() <= 60 else target.left(57) + "…"
	if target.strip_edges().to_lower().begins_with("data:"):
		return "image %s is a data: URI, which the app doesn't show (save it as a file in images/)" % shown
	if ImageEmbeds.is_remote(target):
		return "image %s is a web link; the app never downloads images (save it in images/)" % shown
	if target.get_extension().to_lower() not in ImageEmbeds.EXTS:
		return "image %s is not png, jpg or webp, so the app can't show it" % shown
	var custom_vault: Variant = hooks.get("vault")
	var vault: String = custom_vault if custom_vault is String else VaultStore.vault_path
	var path: String = ImageEmbeds.resolve(target, vault)
	if path == "":
		return "image %s is outside the vault; the app only shows files inside it (copy it into images/)" % shown
	var rel: String = path.substr(vault.simplify_path().length() + 1)
	var custom: Variant = hooks.get("image_exists")
	var there: bool = custom.call(rel) if custom is Callable and (custom as Callable).is_valid() else FileAccess.file_exists(path)
	return "" if there else "image not found: %s (put the file in images/)" % target


static func _objective_exists(name: String, hooks: Dictionary) -> bool:
	var custom: Variant = hooks.get("objective_exists")
	if custom is Callable and (custom as Callable).is_valid():
		return custom.call(name)
	return not JourneyStore.find_objective_by_name(name).is_empty()
