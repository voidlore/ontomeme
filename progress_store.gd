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
## Why progress.json couldn't be read when it was loaded ("" if it could):
## the status bar shows it. Its bytes were kept beside it, or, if it couldn't
## be opened at all, nothing is saved over it.
static var last_error: String = ""
static var _data: Dictionary = {}
static var _loaded_from: String = ""
static var _disk_hash: String = ""   # the file's SHA-256 as this process last read or wrote it

## The sidebar asks every row's status on every rebuild, so what that costs
## is kept between calls:
## - the questions answered wrong, by the lowercase learn: title they point
##   at (missed_for). Built from _data on first use; dropped whenever _data
##   changes or is reloaded (_drop_missed).
## - quiz_count per note text: it depends on the text alone. Cleared by
##   invalidate() (a vault opens) and when it grows past QUIZ_COUNTS_MAX.
static var _missed: Dictionary = {}
static var _missed_built: bool = false
static var _quiz_counts: Dictionary = {}
const QUIZ_COUNTS_MAX: int = 4096

## The results of notes in the trash, by the trashed file's path: copied by
## note_trashed (VaultStore.trash_note), given back by note_restored. While a
## note is in the trash its title is free, so another note may take its keys.
static var _kept: Dictionary = {}


static func path() -> String:
	if file_override != "":
		return file_override
	return path_in(VaultStore.vault_path)


## Where the vault at `vault` keeps its quiz progress (the MCP server reads it).
static func path_in(vault: String) -> String:
	return VaultStore.data_dir_of(vault).path_join("progress.json")


## The file's top level: an object whose quizzes and questions, where
## present, are objects too.
static func _valid(v: Variant) -> bool:
	if not v is Dictionary:
		return false
	for k in ["quizzes", "questions"]:
		if (v as Dictionary).has(k) and not v[k] is Dictionary:
			return false
	return true


static func _load() -> void:
	var p: String = path()
	if _loaded_from == p:
		return
	_loaded_from = p
	_drop_missed()
	_disk_hash = _file_hash()   # before reading: a write in between shows as a change
	var file: Dictionary = JourneyStore.load_json_file(p, "quiz progress", _valid)
	last_error = file.error
	_data = _shaped(file.data)


## {quizzes, questions} from what the file held (null: nothing).
static func _shaped(data: Variant) -> Dictionary:
	var out: Dictionary = {"quizzes": {}, "questions": {}}
	if data != null:
		for k in ["quizzes", "questions"]:
			if (data as Dictionary).has(k):
				out[k] = data[k]
	return out


## The progress file at `p`, read without writing anything and without
## touching the app's own copy (the MCP server reads it): {state, data}.
## state as in JourneyStore.read_json_file; data is {quizzes, questions},
## both empty unless state is "ok".
static func read_progress(p: String) -> Dictionary:
	var file: Dictionary = JourneyStore.read_json_file(p, _valid)
	return {"state": file.state, "data": _shaped(file.data)}


## last_error, loading the file first if it isn't loaded yet.
static func load_error() -> String:
	_load()
	return last_error


static func _save() -> Error:
	var err: Error = JourneyStore.write_atomically(path(), JSON.stringify(_data, "\t"))
	if err == OK:
		_disk_hash = _file_hash()
	return err


## Forget the in-memory copy (next read reloads from disk). Not "reload":
## on a class_name that would call Script.reload() and wipe static vars.
static func invalidate() -> void:
	_loaded_from = ""
	_drop_missed()
	_quiz_counts.clear()


static func _drop_missed() -> void:
	_missed.clear()
	_missed_built = false


## True when another process (the MCP server renaming a note, a sync tool)
## rewrote progress.json since this one last read or wrote it.
static func changed_on_disk() -> bool:
	return _loaded_from != "" and _loaded_from == path() and _file_hash() != _disk_hash


## Read the file again if changed_on_disk(); true when it did. The app's
## disk poll calls it to show the new marks; every write calls it first, so
## a write never puts back what another process changed.
static func reload_if_changed() -> bool:
	if not changed_on_disk():
		return false
	invalidate()
	_load()
	return true


static func _file_hash() -> String:
	return FileAccess.get_sha256(path()) if FileAccess.file_exists(path()) else ""


static func reset() -> void:
	_load()
	_data = {"quizzes": {}, "questions": {}}
	_kept.clear()   # a restore after a reset brings no results back
	_drop_missed()
	_save()


static func _key(note_title: String, quiz_index: int) -> String:
	return "%s#%d" % [note_title.strip_edges().to_lower(), quiz_index]


## A quizzes key ("<title, lowercased>#<quiz>") or questions key
## ("…#<quiz>#<question>") taken apart: {note, quiz, question} (question -1
## for a quizzes key), or {} if it isn't one. The title may hold "#".
static func parse_key(key: String, is_question: bool) -> Dictionary:
	var parts: PackedStringArray = key.rsplit("#", true, 2 if is_question else 1)
	if parts.size() != (3 if is_question else 2) or not parts[1].is_valid_int() or (is_question and not parts[2].is_valid_int()):
		return {}
	return {"note": parts[0], "quiz": int(parts[1]), "question": int(parts[2]) if is_question else -1}


static func passes(score: int, total: int) -> bool:
	return total > 0 and float(score) >= float(total) * PASS_RATIO - 0.0001


static func pass_mark(total: int) -> int:
	return ceili(total * PASS_RATIO - 0.0001)


static func record_answer(note_title: String, quiz_index: int, qi: int, question: String, right: bool, learn: String) -> void:
	if note_title == "":
		return
	reload_if_changed()
	_load()
	_data.questions[_key(note_title, quiz_index) + "#" + str(qi)] = {
		"right": right, "learn": learn, "q": question, "from": note_title,
	}
	_drop_missed()
	_save()


static func record_result(note_title: String, quiz_index: int, score: int, total: int) -> void:
	if note_title == "":
		return
	reload_if_changed()
	_load()
	var k: String = _key(note_title, quiz_index)
	var prev: Dictionary = _data.quizzes.get(k, {})
	var best: int = maxi(int(prev.get("best", 0)), score)
	_data.quizzes[k] = {"best": best, "total": total, "passed": passes(best, total), "last": score}
	_drop_missed()
	_save()


## A note was renamed (RenameCascade): move its quiz results and answers to
## the new title's keys, and point learn: / from fields that named it at the
## new title, so its ✓ and ● marks follow it. Returns how many entries changed.
## Nothing moves to or from "untitled" (VaultStore.shared_title): its keys may
## be any untitled note's, and moving onto them would overwrite another's.
## Results already under the new title are a note's that left the vault (a
## title another note has is refused): they are never written over (_move_keys).
static func rename_note_keys(old_title: String, new_title: String) -> int:
	reload_if_changed()
	_load()
	var old_key: String = old_title.strip_edges().to_lower()
	var new_key: String = new_title.strip_edges().to_lower()
	if old_key == "" or new_title.strip_edges() == "":
		return 0
	if VaultStore.shared_title(old_title) or VaultStore.shared_title(new_title):
		return 0
	var changed: int = 0
	if new_key != old_key:
		changed += _move_keys(_data.quizzes, old_key, new_key, 1)
		changed += _move_keys(_data.questions, old_key, new_key, 2)
	for k in _data.questions:
		var r: Dictionary = _data.questions[k]
		for field in ["learn", "from"]:
			var v: String = str(r.get(field, ""))
			if v.strip_edges().to_lower() == old_key and v != new_title.strip_edges():
				r[field] = new_title.strip_edges()
				changed += 1
	if changed > 0:
		_drop_missed()   # the missed questions are kept by their learn: title
		_save()
	return changed


## Re-key the entries of `table` whose key is "<old_key>" plus `ints`
## "#<number>" parts (quizzes: "title#0", questions: "title#0#2") to
## "<new_key>…". Entries already under "<new_key>…" (a note's in the trash,
## whose title is free there) trade places with them, taking the old keys the
## renamed note just left: nothing is written over. Returns how many moved.
static func _move_keys(table: Dictionary, old_key: String, new_key: String, ints: int) -> int:
	var moved: Dictionary = {}
	for k in table.keys():
		var head: String = _title_part(str(k), ints)
		if head == old_key or head == new_key:
			moved[(new_key if head == old_key else old_key) + str(k).substr(head.length())] = table[k]
			table.erase(k)
	table.merge(moved)
	return moved.size()


## VaultStore.trash_note moved the note titled `note_title` to `trash_path`:
## copy its results for note_restored. They stay in the file too, under its
## title, for a restore by hand from the trash folder.
static func note_trashed(trash_path: String, note_title: String) -> void:
	var key: String = note_title.strip_edges().to_lower()
	if key == "" or VaultStore.shared_title(note_title):   # untitled#0 may be any untitled note's
		return
	reload_if_changed()
	_load()
	var kept: Dictionary = {"quizzes": {}, "questions": {}}
	var any: bool = false
	for table in kept:
		for k in _data[table]:
			if _title_part(str(k), 1 if table == "quizzes" else 2) == key:
				var r: Variant = _data[table][k]
				kept[table][str(k).substr(key.length())] = r.duplicate(true) if r is Dictionary else r
				any = true
	if any:
		_kept[trash_path] = kept


## The note trashed to `trash_path` is back, titled `note_title` (another
## title than its own when a note took that while it was in the trash:
## VaultStore.restore_from_trash). The results note_trashed copied go under
## that title, each where it has none: nothing there is written over.
## Returns how many came back.
static func note_restored(trash_path: String, note_title: String) -> int:
	var kept: Dictionary = _kept.get(trash_path, {})
	_kept.erase(trash_path)
	var key: String = note_title.strip_edges().to_lower()
	if kept.is_empty() or key == "" or VaultStore.shared_title(note_title):
		return 0
	reload_if_changed()
	_load()
	var added: int = 0
	for table in kept:
		for rest in kept[table]:
			if _data[table].has(key + rest):
				continue
			var r: Variant = kept[table][rest]
			if r is Dictionary and r.has("from"):
				r.from = note_title.strip_edges()   # answered in this note
			_data[table][key + rest] = r
			added += 1
	if added > 0:
		_drop_missed()
		_save()
	return added


## The title part of a quizzes key (`ints` 1: "title#0") or questions key
## (`ints` 2: "title#0#2"); "" when `key` isn't one.
static func _title_part(key: String, ints: int) -> String:
	var head: String = key
	for i in range(ints):
		var cut: int = head.rfind("#")
		head = head.substr(0, cut) if cut >= 0 and head.substr(cut + 1).is_valid_int() else ""
	return head


static func quiz_passed(note_title: String, quiz_index: int) -> bool:
	_load()
	return bool(_data.quizzes.get(_key(note_title, quiz_index), {}).get("passed", false))


## How many quiz blocks a note has, counted exactly as Read view renders them.
static func quiz_count(text: String) -> int:
	if _quiz_counts.has(text):
		return _quiz_counts[text]
	if _quiz_counts.size() >= QUIZ_COUNTS_MAX:
		_quiz_counts.clear()   # texts edited away pile up; start over
	var n: int = JourneyStore.scene_blocks(text).filter(func(b): return JourneyStore.activity_kind(b.params) == "quiz").size()
	_quiz_counts[text] = n
	return n


static func _find_note(title: String) -> ContentLayer:
	var want: String = title.strip_edges().to_lower()
	for note in VaultStore.note_list:
		if note.title.strip_edges().to_lower() == want:
			return note
	return null


## Questions whose latest answer was wrong and whose learn: is this note.
static func missed_for(note_title: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.assign(_missed_index().get(note_title.strip_edges().to_lower(), []))
	return out


## _missed, built from _data when it was dropped: every question whose latest
## answer was wrong, in the order answered, under its learn: title.
static func _missed_index() -> Dictionary:
	_load()
	if _missed_built:
		return _missed
	for k in _data.questions:
		var r: Dictionary = _data.questions[k]
		if not bool(r.get("right", true)):
			var learn: String = str(r.get("learn", "")).strip_edges().to_lower()
			if not _missed.has(learn):
				_missed[learn] = []
			_missed[learn].append(r)
	_missed_built = true
	return _missed


## "review" (missed a question about it), "done" (all its quizzes passed),
## or "" — for a note given by title.
static func status(note_title: String) -> String:
	if _missed_index().has(note_title.strip_edges().to_lower()):
		return "review"
	return _quiz_status(_find_note(note_title))


## status() of `note` itself, without looking it up by title among all the
## notes: what the sidebar asks for each row.
static func note_status(note: ContentLayer) -> String:
	if note == null:
		return ""
	if _missed_index().has(note.title.strip_edges().to_lower()):
		return "review"
	return _quiz_status(note)


## "done" when `note` has quizzes and every one is passed, else "".
static func _quiz_status(note: ContentLayer) -> String:
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
