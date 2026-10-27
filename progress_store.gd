class_name ProgressStore
extends RefCounted
## Quiz progress for the vault, saved to <vault>/.ontomeme/progress.json so
## it travels with the notes.
##
## - questions: the latest answer to every quiz question (right/wrong) and
##   the note its learn: line points at. A wrong latest answer marks that
##   note "needs review"; answering it right later clears the mark.
## - quizzes: best score per quiz. A note whose quizzes are all passed is
##   "done".

const PASS_RATIO: float = 2.0 / 3.0

static var file_override: String = ""   # tests point this elsewhere
static var _data: Dictionary = {}
static var _loaded_from: String = ""


static func path() -> String:
	if file_override != "":
		return file_override
	return VaultStore.data_dir().path_join("progress.json")


static func _load() -> void:
	var p: String = path()
	if _loaded_from == p:
		return
	_loaded_from = p
	_data = {"quizzes": {}, "questions": {}}
	if FileAccess.file_exists(p):
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if v is Dictionary:
			for k in ["quizzes", "questions"]:
				if (v as Dictionary).get(k) is Dictionary:
					_data[k] = v[k]


static func _save() -> void:
	DirAccess.make_dir_recursive_absolute(path().get_base_dir())
	var f := FileAccess.open(path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_data, "\t"))


## Forget the in-memory copy (next read reloads from disk). Not "reload":
## on a class_name that would call Script.reload() and wipe static vars.
static func invalidate() -> void:
	_loaded_from = ""


static func reset() -> void:
	_load()
	_data = {"quizzes": {}, "questions": {}}
	_save()


static func _key(note_title: String, quiz_index: int) -> String:
	return "%s#%d" % [note_title.strip_edges().to_lower(), quiz_index]


static func passes(score: int, total: int) -> bool:
	return total > 0 and float(score) >= float(total) * PASS_RATIO - 0.0001


static func pass_mark(total: int) -> int:
	return ceili(total * PASS_RATIO - 0.0001)


static func record_answer(note_title: String, quiz_index: int, qi: int, question: String, right: bool, learn: String) -> void:
	if note_title == "":
		return
	_load()
	_data.questions[_key(note_title, quiz_index) + "#" + str(qi)] = {
		"right": right, "learn": learn, "q": question, "from": note_title,
	}
	_save()


static func record_result(note_title: String, quiz_index: int, score: int, total: int) -> void:
	if note_title == "":
		return
	_load()
	var k: String = _key(note_title, quiz_index)
	var prev: Dictionary = _data.quizzes.get(k, {})
	var best: int = maxi(int(prev.get("best", 0)), score)
	_data.quizzes[k] = {"best": best, "total": total, "passed": passes(best, total), "last": score}
	_save()


static func quiz_passed(note_title: String, quiz_index: int) -> bool:
	_load()
	return bool(_data.quizzes.get(_key(note_title, quiz_index), {}).get("passed", false))


## How many quiz blocks a note has, counted exactly as Read view renders them.
static func quiz_count(text: String) -> int:
	return JourneyStore.scene_blocks(text).filter(func(b): return JourneyStore.activity_kind(b.params) == "quiz").size()


static func _find_note(title: String) -> ContentLayer:
	var want: String = title.strip_edges().to_lower()
	for note in VaultStore.note_list:
		if note.title.strip_edges().to_lower() == want:
			return note
	return null


## Questions whose latest answer was wrong and whose learn: is this note.
static func missed_for(note_title: String) -> Array[Dictionary]:
	_load()
	var want: String = note_title.strip_edges().to_lower()
	var out: Array[Dictionary] = []
	for k in _data.questions:
		var r: Dictionary = _data.questions[k]
		if not bool(r.get("right", true)) and str(r.get("learn", "")).strip_edges().to_lower() == want:
			out.append(r)
	return out


## "review" (missed a question about it), "done" (all its quizzes passed),
## or "" — for a note given by title.
static func status(note_title: String) -> String:
	if not missed_for(note_title).is_empty():
		return "review"
	var note: ContentLayer = _find_note(note_title)
	if note == null:
		return ""
	var n: int = quiz_count(note.raw_text)
	if n == 0:
		return ""
	for i in range(n):
		if not quiz_passed(note.title, i):
			return ""
	return "done"


# ── Little status icons (drawn, so they don't depend on font glyphs) ────────

static var _icons: Dictionary = {}


static func icon(kind: String) -> Texture2D:
	if _icons.has(kind):
		return _icons[kind]
	var sz: int = 16
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var col: Color = Color("3ddc84") if kind == "done" else Color("f0a040")
	for y in range(sz):
		for x in range(sz):
			var p := Vector2(x + 0.5, y + 0.5)
			var a: float
			if kind == "done":
				# Two strokes of a check mark, anti-aliased by distance
				var d: float = minf(_seg_dist(p, Vector2(3.0, 8.5), Vector2(6.5, 12.0)), _seg_dist(p, Vector2(6.5, 12.0), Vector2(13.0, 4.0)))
				a = clampf(2.1 - d, 0.0, 1.0)
			else:
				a = clampf(4.2 - p.distance_to(Vector2(8, 8)), 0.0, 1.0)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
	_icons[kind] = ImageTexture.create_from_image(img)
	return _icons[kind]


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var t: float = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)
