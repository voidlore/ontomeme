class_name JourneyStore
extends RefCounted
## The Learning Journey: what the learner wants to know and the evidence that
## they know it. Saved per vault in <vault>/.ontomeme/journey.json, so a
## vault's objectives travel (and can be shared) with its notes.
##
##   Topic        name, description, objectives[]
##   Objective    name, description, goal (fluent | learning | forget),
##                demos[] (ways to demonstrate it), log[] (history)
##   Demo         activity (a quiz / flashcard deck in a note), score output
##   Log entry    date, activity, score, max, output, value
##
## Activities (quiz cards, flashcard decks) report a score when finished;
## every objective with a demo pointing at that activity logs it.
##
## The file format is the learning-objectives protocol, version 1:
## skills/ontomeme-notes/references/objectives-protocol.md. Whatever wrote the
## file, _load passes it through sanitize(), so the app only ever sees
## entries of the right shape.

## The protocol version this app writes, first in journey.json.
const VERSION: int = 1
const GOALS: Array[String] = ["fluent", "learning", "forget"]
const GOAL_NAMES: Dictionary = {"fluent": "Fluent", "learning": "Learning", "forget": "Forget"}
const GOAL_HELP: Dictionary = {
	"fluent": "Know it cold: aim for 90%+ on every demonstration.",
	"learning": "Working on it: aim to pass (two thirds) on every demonstration.",
	"forget": "Not a goal any more: scores still log, nothing to aim for.",
}
const OUTPUTS: Array[String] = ["percent", "correct", "pass"]
const OUTPUT_NAMES: Dictionary = {"percent": "Score as %", "correct": "Correct answers", "pass": "Pass / fail"}
const KIND_NAMES: Dictionary = {"quiz": "Quiz", "cards": "Flashcards"}

static var file_override: String = ""
## Why the journey file couldn't be read when it was loaded ("" if it could):
## the Journey tab and the status bar show it. Its bytes were kept beside it,
## or, if it couldn't be opened at all, nothing is saved over it.
static var last_error: String = ""
static var _data: Dictionary = {}
static var _loaded_from: String = ""
static var _disk_hash: String = ""   # the file's SHA-256 as this process last read or wrote it
## Paths load_json_file found but couldn't read: write_atomically won't
## replace them, since what they hold was never seen. Reading one again (the
## vault reopens) lifts that.
static var _unread: Dictionary = {}
## The Journey entries of notes in the trash, by the trashed file's path:
## noted by note_trashed (VaultStore.trash_note), put under the title the
## note comes back with by note_restored. While a note is in the trash its
## title is free, so another note may take it (title_taken then moves the
## entries off it, as rename_note_keys trades them away). {title: the title
## they are keyed by now, demos: {demo id: true}, logs: {_trashed_log_id: true}}
static var _in_trash: Dictionary = {}


static func path() -> String:
	return file_override if file_override != "" else path_in(VaultStore.vault_path)


## Where the vault at `vault` keeps its journey (the MCP server reads it).
static func path_in(vault: String) -> String:
	return VaultStore.data_dir_of(vault).path_join("journey.json")


static func invalidate() -> void:
	_loaded_from = ""


## True when another process (the MCP server renaming a note, a sync tool)
## rewrote journey.json since this one last read or wrote it.
static func changed_on_disk() -> bool:
	return _loaded_from != "" and _loaded_from == path() and _file_hash() != _disk_hash


## Read the file again if changed_on_disk(); true when it did. The app's
## disk poll calls it (and refreshes the Journey tab, whose editors hold the
## old dictionaries); the mutators that find what they change by id or key
## call it first, so their save never puts back what another process changed.
static func reload_if_changed() -> bool:
	if not changed_on_disk():
		return false
	invalidate()
	_load()
	return true


static func _file_hash() -> String:
	return FileAccess.get_sha256(path()) if FileAccess.file_exists(path()) else ""


static func _load() -> void:
	if _loaded_from == path():
		return
	_loaded_from = path()
	_disk_hash = _file_hash()   # before reading: a write in between shows as a change
	_data = _empty()
	var file: Dictionary = load_json_file(path(), "journey", _is_journey)
	last_error = file.error
	if file.data == null:
		return
	var clean: Dictionary = sanitize(file.data)
	_data = clean.data
	if clean.broken > 0:   # saving drops them, so keep the file as it was
		var kept: String = keep_unreadable(path())
		last_error = "Your journey file had %d broken entr%s, fixed or left out; %s" % [
			clean.broken, "y" if clean.broken == 1 else "ies",
			("the original was kept as %s." % kept) if kept != "" else "a copy of the original couldn't be made."]


## The shape load_json_file and merge_from accept: {"topics": [...], …}.
static func _is_journey(v: Variant) -> bool:
	return v is Dictionary and (v as Dictionary).get("topics") is Array


## last_error, loading the file first if it isn't loaded yet.
static func load_error() -> String:
	_load()
	return last_error


static func save() -> Error:
	_load()
	var err: Error = write_atomically(path(), JSON.stringify(_data, "\t", false))   # unsorted: version stays first
	if err == OK:
		_disk_hash = _file_hash()
	return err


static func reset() -> void:
	_load()
	_data = _empty()
	_in_trash.clear()   # a restore after a reset finds none of its entries
	save()


static func _empty() -> Dictionary:
	return {"version": VERSION, "topics": []}


static func _new_id() -> String:
	return "%x%04x" % [Time.get_unix_time_from_system() * 1000, randi() % 0xffff]


# ── Sanitizing: what the app can rely on, whoever wrote the file ────────────

## Journey data as the app can use it: every topic, objective, demo and log
## entry has the fields, types and values the app reads (the protocol's
## rules). A broken entry is dropped, and nothing around it; a goal outside
## GOALS becomes "learning"; missing or repeated ids get new ones; unknown
## keys stay. Returns {data, broken}: data with "version" first, broken =
## how many entries were dropped or values replaced.
static func sanitize(data: Dictionary) -> Dictionary:
	var ctx: Dictionary = {"ids": {}, "broken": 0}
	var out: Dictionary = {"version": VERSION}
	for k in data:
		if k != "version":
			out[k] = data[k]
	out.topics = _kept(data.get("topics", []), _sane_topic, ctx)
	return {"data": out, "broken": ctx.broken}


## The entries of `list` that `fix` accepts (repairing them in place); the
## rest are counted in ctx.broken.
static func _kept(list: Array, fix: Callable, ctx: Dictionary) -> Array:
	var keep: Array = []
	for e in list:
		if e is Dictionary and fix.call(e, ctx):
			keep.append(e)
		else:
			ctx.broken += 1
	return keep


## A topic needs a string name; objectives, if there, must be a list.
static func _sane_topic(t: Dictionary, ctx: Dictionary) -> bool:
	if not (t.get("name") is String and t.get("objectives", []) is Array):
		return false
	_sane_id(t, ctx)
	_sane_text(t, "description", ctx)
	t.objectives = _kept(t.get("objectives", []), _sane_objective, ctx)
	return true


## An objective needs a string name; demos and log, if there, must be lists.
static func _sane_objective(o: Dictionary, ctx: Dictionary) -> bool:
	if not (o.get("name") is String and o.get("demos", []) is Array and o.get("log", []) is Array):
		return false
	_sane_id(o, ctx)
	_sane_text(o, "description", ctx)
	if not _one_of(o.get("goal"), GOALS):
		if o.has("goal"):
			ctx.broken += 1
		o.goal = "learning"
	o.demos = _kept(o.get("demos", []), _sane_demo, ctx)
	o.log = _kept(o.get("log", []), _sane_log_entry, ctx)
	return true


## A demo needs a string activity and an output in OUTPUTS (missing = percent).
static func _sane_demo(d: Dictionary, ctx: Dictionary) -> bool:
	if not (d.get("activity") is String and _one_of(d.get("output", "percent"), OUTPUTS)):
		return false
	_sane_id(d, ctx)
	d.output = d.get("output", "percent")
	return true


## A log entry needs a string activity, numbers for score, max and value, and
## an output in OUTPUTS (missing = percent).
static func _sane_log_entry(e: Dictionary, ctx: Dictionary) -> bool:
	for k in ["score", "max", "value"]:
		if not (e.get(k) is float or e.get(k) is int):
			return false
	if not (e.get("activity") is String and _one_of(e.get("output", "percent"), OUTPUTS)):
		return false
	e.output = e.get("output", "percent")
	_sane_text(e, "date", ctx)
	return true


## A non-empty string id no other entry has; any other id is replaced.
static func _sane_id(e: Dictionary, ctx: Dictionary) -> void:
	var id: Variant = e.get("id")
	while (not (id is String and id != "")) or ctx.ids.has(id):
		id = _new_id()
	e.id = id
	ctx.ids[id] = true


## Free text: missing or null becomes "", and so does anything else that
## isn't text (counted as broken).
static func _sane_text(e: Dictionary, key: String, ctx: Dictionary) -> void:
	var v: Variant = e.get(key)
	if v is String:
		return
	if v != null:
		ctx.broken += 1
	e[key] = ""


## `v` is one of `allowed` (a typed Array's has() errors on other types).
static func _one_of(v: Variant, allowed: Array[String]) -> bool:
	return v is String and allowed.has(v)


# ── The file on disk (ProgressStore reads and writes through these too) ─────

## Read the JSON file at `p`: {data, error}. data is what it holds when
## `valid` accepts it, else null (a missing or blank file is simply empty).
## A file that doesn't parse or has the wrong shape is kept beside itself
## (keep_unreadable) before anything can overwrite it, and error says so,
## naming it "your <what> file". A file that can't be opened at all (no
## permission, or held by a sync tool or antivirus) can't be copied either:
## it stays as it is, and write_atomically won't replace it. With no file at
## `p` but a <name>.tmp beside it (a save that removed `p` and then couldn't
## rename over it), the .tmp is put back as `p` and read.
static func load_json_file(p: String, what: String, valid: Callable) -> Dictionary:
	_unread.erase(p)
	var tmp: String = _tmp_path(p)
	if not FileAccess.file_exists(p) and FileAccess.file_exists(tmp) and DirAccess.rename_absolute(tmp, p) != OK:
		_unread[p] = true   # the next save would write over the .tmp, the only copy
		return {"data": null, "error": "Your %s file was left as %s by a save that didn't finish, and it couldn't be put back, so the app shows it empty and saves nothing over it. Close whatever has it open (a sync tool or antivirus), then reopen the vault." % [what, tmp.get_file()]}
	var file: Dictionary = read_json_file(p, valid)
	match file.state:
		"ok", "missing":
			return {"data": file.data, "error": ""}
		"cant_open":
			_unread[p] = true
			return {"data": null, "error": "Your %s file couldn't be opened, so the app shows it empty and saves nothing over it. Close whatever has it open (a sync tool or antivirus), then reopen the vault." % what}
	var kept: String = keep_unreadable(p)
	if kept == "":
		return {"data": null, "error": "Your %s file couldn't be read, and a copy of it couldn't be made." % what}
	return {"data": null, "error": "Your %s file couldn't be read; it was kept as %s." % [what, kept]}


## The JSON file at `p`, read without writing anything (no .tmp put back,
## no unreadable copy kept), for readers that mustn't change a vault (the
## MCP server): {state, data}. state is "ok" (data is what `valid`
## accepted), "missing" (no file, or a blank one), "cant_open" (it couldn't
## be opened or read through) or "unreadable" (it doesn't parse, or `valid`
## refuses it); data is null unless "ok". With no file at `p` but a
## <name>.tmp beside it (a save that didn't finish), the .tmp is read.
static func read_json_file(p: String, valid: Callable) -> Dictionary:
	if not FileAccess.file_exists(p) and FileAccess.file_exists(_tmp_path(p)):
		p = _tmp_path(p)
	if not FileAccess.file_exists(p):
		return {"state": "missing", "data": null}
	var bytes: Variant = _read_all(p)
	if bytes == null:
		return {"state": "cant_open", "data": null}
	var text: String = (bytes as PackedByteArray).get_string_from_utf8()
	if text.strip_edges() == "":
		return {"state": "missing", "data": null}
	var json := JSON.new()   # not JSON.parse_string: that logs an engine error per broken file
	if json.parse(text) == OK and valid.call(json.data):
		return {"state": "ok", "data": json.data}
	return {"state": "unreadable", "data": null}


## The journey file at `p` as the app would load it, without writing
## anything (read_json_file) and without touching the app's own copy:
## {state, data, broken}. data has been through sanitize(), and is an empty
## journey unless state is "ok"; broken is sanitize()'s count.
static func read_journey(p: String) -> Dictionary:
	var file: Dictionary = read_json_file(p, _is_journey)
	if file.state != "ok":
		return {"state": file.state, "data": _empty(), "broken": 0}
	var clean: Dictionary = sanitize(file.data)
	return {"state": "ok", "data": clean.data, "broken": clean.broken}


## Where write_atomically writes before renaming over `p`: <name>.tmp.
static func _tmp_path(p: String) -> String:
	return p.get_basename() + ".tmp"


## Every byte of the file at `p`, or null if it can't be opened or read
## through. (FileAccess.get_file_as_string gives "" then, the same as for an
## empty file.)
static func _read_all(p: String) -> Variant:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return null
	var n: int = f.get_length()
	var bytes: PackedByteArray = f.get_buffer(n)
	f.close()
	return bytes if bytes.size() == n else null


## Copy the file at `p`, which couldn't be read, to
## <name>.unreadable-<YYYYMMDD-HHMMSS>.json beside it. Returns the copy's
## file name ("" if it couldn't be written). A copy with the same bytes is
## reused, so reading one broken file again doesn't copy it again.
static func keep_unreadable(p: String) -> String:
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(p)
	var dir: String = p.get_base_dir()
	var prefix: String = p.get_file().get_basename() + ".unreadable-"
	for other in DirAccess.get_files_at(dir):
		if other.begins_with(prefix) and other.ends_with(".json") and FileAccess.get_file_as_bytes(dir.path_join(other)) == bytes:
			return other
	var d: Dictionary = Time.get_datetime_dict_from_system()
	var stamp: String = "%04d%02d%02d-%02d%02d%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second]
	var name: String = prefix + stamp + ".json"
	var n: int = 2
	while FileAccess.file_exists(dir.path_join(name)):   # another broken file this second
		name = "%s%s-%d.json" % [prefix, stamp, n]
		n += 1
	var f := FileAccess.open(dir.path_join(name), FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(bytes)
	var err: Error = f.get_error()
	f.close()
	return name if err == OK else ""


## Write `text` to `p` so that a crash never leaves half a file: into
## <name>.tmp beside it, then renamed over `p`. Where a rename won't replace
## an existing file (Windows), `p` is removed first. On failure `p` keeps its
## old bytes and the .tmp file is removed, unless `p` is already gone: then
## the .tmp file is the only copy left, and stays (load_json_file puts it
## back). A `p` that load_json_file couldn't read is left alone
## (ERR_FILE_CANT_READ).
static func write_atomically(p: String, text: String) -> Error:
	if _unread.has(p):
		return ERR_FILE_CANT_READ
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var tmp: String = _tmp_path(p)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	var err: Error = f.get_error()
	f.close()
	if err == OK:
		err = DirAccess.rename_absolute(tmp, p)
		if err != OK and FileAccess.file_exists(p) and DirAccess.remove_absolute(p) == OK:
			err = DirAccess.rename_absolute(tmp, p)
	if err != OK and FileAccess.file_exists(tmp) and FileAccess.file_exists(p):
		DirAccess.remove_absolute(tmp)
	return err


# ── Merging another vault's journey (Import) ────────────────────────────────

## Merge the journey file at `src` (another vault's, being imported) into
## this one. Topics match by name and objectives by name within their topic,
## both without case; one missing here is added with new ids. Demos join by
## activity, and log entries not already here (same date, activity and
## score) are added. `renames` maps the titles of notes the import renamed
## ("X" → "X (2)"), so their demos and log entries follow them. `src` is read
## through sanitize() and never written. Returns how many {topics,
## objectives, demos, logs} were added, and error: "" or why nothing was.
static func merge_from(src: String, renames: Dictionary = {}) -> Dictionary:
	var added: Dictionary = {"topics": 0, "objectives": 0, "demos": 0, "logs": 0, "error": ""}
	var bytes: Variant = _read_all(src)
	var json := JSON.new()
	if bytes == null or json.parse((bytes as PackedByteArray).get_string_from_utf8()) != OK or not _is_journey(json.data):
		added.error = "the Learning Journey in %s couldn't be read" % src.get_base_dir().get_base_dir().get_file()
		return added
	reload_if_changed()
	_load()
	var ids: Dictionary = _ids_in_use()
	for t in sanitize(json.data).data.topics:
		var topic: Dictionary = _named(topics(), t.name)
		if topic.is_empty():
			topic = _adopted(t, ids, ["objectives"])
			topics().append(topic)
			added.topics += 1
		for o in t.objectives:
			_follow_renames(o, renames)
			var objective: Dictionary = _named(topic.objectives, o.name)
			if objective.is_empty():
				objective = _adopted(o, ids, ["demos", "log"])
				topic.objectives.append(objective)
				added.objectives += 1
			added.demos += _merge_demos(objective, o.demos, ids)
			added.logs += _merge_log(objective, o.log)
	if added.topics + added.objectives + added.demos + added.logs > 0:
		var err: Error = save()
		if err != OK:
			added.error = "the Learning Journey couldn't be saved (%s)" % error_string(err)
	return added


## The first entry of `list` named `name`, without case or outer spaces.
static func _named(list: Array, name: String) -> Dictionary:
	var want: String = name.strip_edges().to_lower()
	for e in list:
		if str(e.name).strip_edges().to_lower() == want:
			return e
	return {}


## A copy of the incoming `entry` to add here: a new id, and `lists` empty
## (the merge fills them, so nothing is added twice).
static func _adopted(entry: Dictionary, ids: Dictionary, lists: Array) -> Dictionary:
	var copy: Dictionary = entry.duplicate(true)
	copy.id = _fresh_id(ids)
	for k in lists:
		copy[k] = []
	return copy


## Point the incoming objective's demos and log entries at renamed notes.
static func _follow_renames(o: Dictionary, renames: Dictionary) -> void:
	if renames.is_empty():
		return
	for e in o.demos + o.log:
		var k: Dictionary = parse_key(e.activity)
		if not k.is_empty() and renames.has(k.note):
			e.activity = activity_key(renames[k.note], k.kind, k.index)


## Add the incoming `demos` whose activity `objective` has no demo for.
static func _merge_demos(objective: Dictionary, demos: Array, ids: Dictionary) -> int:
	var n: int = 0
	for d in demos:
		if objective.demos.all(func(mine: Dictionary) -> bool: return mine.activity != d.activity):
			var copy: Dictionary = d.duplicate(true)
			copy.id = _fresh_id(ids)
			objective.demos.append(copy)
			n += 1
	return n


## Add the incoming log entries `objective` doesn't have yet (same date,
## activity and score), keeping the log in date order.
static func _merge_log(objective: Dictionary, log: Array) -> int:
	var seen: Dictionary = {}
	for e in objective.log:
		seen[_log_identity(e)] = true
	var n: int = 0
	for e in log:
		if not seen.has(_log_identity(e)):
			seen[_log_identity(e)] = true
			objective.log.append(e.duplicate(true))
			n += 1
	if n > 0:
		objective.log.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.date) < str(b.date))
	return n


## What makes two log entries the same attempt.
static func _log_identity(e: Dictionary) -> String:
	return "%s|%s|%s" % [e.date, e.activity, float(e.score)]


static func _ids_in_use() -> Dictionary:
	var ids: Dictionary = {}
	for t in topics():
		ids[t.id] = true
		for o in t.objectives:
			ids[o.id] = true
			for d in o.demos:
				ids[d.id] = true
	return ids


## An id that isn't in `ids` (now added to it): ids made in the same
## millisecond differ only by a random 16 bits.
static func _fresh_id(ids: Dictionary) -> String:
	var id: String = _new_id()
	while ids.has(id):
		id = _new_id()
	ids[id] = true
	return id


# ── Topics & objectives ─────────────────────────────────────────────────────

static func topics() -> Array:
	_load()
	return _data.topics


static func add_topic(name: String, description: String = "") -> Dictionary:
	reload_if_changed()
	var t: Dictionary = {"id": _new_id(), "name": name, "description": description, "objectives": []}
	topics().append(t)
	save()
	return t


static func remove_topic(id: String) -> void:
	reload_if_changed()
	_data.topics = topics().filter(func(t): return t.id != id)
	save()


static func find_topic(id: String) -> Dictionary:
	for t in topics():
		if t.id == id:
			return t
	return {}


static func add_objective(topic_id: String, name: String, description: String = "", goal: String = "learning") -> Dictionary:
	reload_if_changed()
	var t: Dictionary = find_topic(topic_id)
	if t.is_empty():
		return {}
	var o: Dictionary = {"id": _new_id(), "name": name, "description": description,
		"goal": goal if GOALS.has(goal) else "learning", "demos": [], "log": []}
	t.objectives.append(o)
	save()
	return o


static func remove_objective(id: String) -> void:
	reload_if_changed()
	for t in topics():
		t.objectives = t.objectives.filter(func(o): return o.id != id)
	save()


static func find_objective(id: String) -> Dictionary:
	for t in topics():
		for o in t.objectives:
			if o.id == id:
				return o
	return {}


static func topic_of(objective_id: String) -> Dictionary:
	for t in topics():
		for o in t.objectives:
			if o.id == objective_id:
				return t
	return {}


static func find_objective_by_name(name: String) -> Dictionary:
	var want: String = name.strip_edges().to_lower()
	for t in topics():
		for o in t.objectives:
			if str(o.name).strip_edges().to_lower() == want:
				return o
	return {}


## The objective a block's "objective: <name>" line asks for, made on the
## spot (Read view's Create chip): a Learning objective under the topic
## named `topic_name` (made too if missing, matched without case), with
## `activity` as its demonstration. An objective of that name that exists
## already, in any topic, is used instead of making a second one.
static func create_linked_objective(name: String, topic_name: String, activity: String) -> Dictionary:
	reload_if_changed()
	var o: Dictionary = find_objective_by_name(name)
	if o.is_empty():
		var topic: Dictionary = _named(topics(), topic_name)
		if topic.is_empty():
			topic = add_topic(topic_name)
		o = add_objective(topic.id, name.strip_edges(), "", "learning")
	add_demo(o.id, activity)
	return o


# ── Demonstrations ──────────────────────────────────────────────────────────

static func add_demo(objective_id: String, activity: String, output: String = "percent") -> Dictionary:
	reload_if_changed()
	var o: Dictionary = find_objective(objective_id)
	if o.is_empty():
		return {}
	for d in o.demos:
		if d.activity == activity:
			return d
	var d: Dictionary = {"id": _new_id(), "activity": activity, "output": output if OUTPUTS.has(output) else "percent"}
	o.demos.append(d)
	save()
	return d


static func remove_demo(objective_id: String, demo_id: String) -> void:
	reload_if_changed()
	var o: Dictionary = find_objective(objective_id)
	if not o.is_empty():
		o.demos = o.demos.filter(func(d): return d.id != demo_id)
		save()


# ── Scores ──────────────────────────────────────────────────────────────────

static func output_value(output: String, score: int, total: int) -> float:
	match output:
		"correct": return float(score)
		"pass": return 1.0 if ProgressStore.passes(score, total) else 0.0
		_: return roundf(100.0 * score / maxf(total, 1))


static func format_value(entry: Dictionary) -> String:
	match str(entry.get("output", "percent")):
		"correct": return "%d / %d correct" % [int(entry.score), int(entry.max)]
		"pass": return "Pass" if float(entry.value) >= 1.0 else "Fail"
		_: return "%d%%" % int(entry.value)


## 0..1 for charts, whatever the output type.
static func normalized(entry: Dictionary) -> float:
	match str(entry.get("output", "percent")):
		"correct": return float(entry.score) / maxf(float(entry.max), 1.0)
		"pass": return float(entry.value)
		_: return float(entry.value) / 100.0


## An activity finished. Log it on every objective that uses it as a demo
## (and on `also_objective`, linking it first — a block's "objective:" line).
## Returns how many objectives logged it.
static func log_score(activity: String, score: int, total: int, also_objective: String = "") -> int:
	reload_if_changed()
	_load()
	if also_objective.strip_edges() != "":
		var named: Dictionary = find_objective_by_name(also_objective)
		if not named.is_empty():
			add_demo(named.id, activity)
	var n: int = 0
	var now: String = Time.get_datetime_string_from_system()
	for t in topics():
		for o in t.objectives:
			for d in o.demos:
				if d.activity == activity:
					o.log.append({
						"date": now, "activity": activity, "score": score, "max": total,
						"output": d.output, "value": output_value(d.output, score, total),
					})
					n += 1
					break
	if n > 0:
		save()
	return n


## Latest entry per demo, and whether that meets the objective's goal:
## done = {activity: its latest entry meets it}, met = it has demos and
## every one is done.
static func summary(o: Dictionary) -> Dictionary:
	var latest: Dictionary = {}
	for e in o.log:
		latest[e.activity] = e
	var best: float = -1.0
	for e in o.log:
		best = maxf(best, normalized(e))
	var need: float = 0.9 if o.goal == "fluent" else ProgressStore.PASS_RATIO - 0.0001
	var done: Dictionary = {}
	var met: bool = not o.demos.is_empty()
	for d in o.demos:
		done[d.activity] = latest.has(d.activity) and normalized(latest[d.activity]) >= need
		met = met and done[d.activity]
	return {"attempts": o.log.size(), "best": best, "met": met, "latest": latest, "done": done}


## Which ProgressStore.icon an objective shows: "done" (its goal is met),
## "review" (tried, not met yet) or "" (not tried, or a Forget goal).
static func objective_status(o: Dictionary) -> String:
	if o.goal == "forget":
		return ""
	var s: Dictionary = summary(o)
	if s.met:
		return "done"
	return "review" if s.attempts > 0 else ""


# ── Activities found in the vault's notes ───────────────────────────────────

## Every scene block in a note's text: [{info, lines, params}], in order.
static func scene_blocks(text: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var fence: int = 0
	var info: String = ""
	var lines: PackedStringArray = []
	for line in text.split("\n"):
		var s: String = line.strip_edges()
		var ticks: int = 0
		while ticks < s.length() and s[ticks] == "`":
			ticks += 1
		if ticks < 3:
			ticks = 0
		if fence > 0:
			if ticks >= fence and s.substr(ticks).strip_edges() == "":
				if NoteScene3D.is_scene_fence(info):
					out.append({"info": info, "lines": lines.duplicate(), "params": NoteScene3D.parse_block(info, lines)})
				fence = 0
				lines.clear()
			else:
				lines.append(line)
		elif ticks > 0:
			fence = ticks
			info = s.substr(ticks).strip_edges()
	return out


static func activity_kind(params: Dictionary) -> String:
	match str(params.get("preset", "")).strip_edges().to_lower():
		"quiz": return "quiz"
		"flashcards", "cards": return "cards"
	return ""


static func activity_key(note_title: String, kind: String, index: int) -> String:
	return "%s#%s%d" % [note_title.strip_edges(), kind, index]


## {note, kind, index} from a key like "Tutorial 5: Making a Quiz#quiz2".
static func parse_key(key: String) -> Dictionary:
	var i: int = key.rfind("#")
	if i < 0:
		return {}
	var tail: String = key.substr(i + 1)
	for kind in ["quiz", "cards"]:
		if tail.begins_with(kind) and tail.substr(kind.length()).is_valid_int():
			return {"note": key.substr(0, i), "kind": kind, "index": int(tail.substr(kind.length()))}
	return {}


## A note was renamed (RenameCascade): every demo and log entry keyed
## "<old title>#quiz0" (or #cards…) now says "<new title>#quiz0", so the
## objective keeps its demonstrations and history. Entries already keyed
## "<new title>#…" are a note's that left the vault (a title another note has
## is refused), such as one in the trash: they take "<old title>#…" in trade,
## so the renamed note never takes over that note's objectives, and
## note_restored gives them back to it. (In the app VaultStore.rename_note has
## already moved a trashed note's entries off the new title: title_taken.)
## Returns how many changed.
## Nothing moves to or from "untitled" (VaultStore.shared_title): a key under
## it may be any untitled note's.
static func rename_note_keys(old_title: String, new_title: String) -> int:
	reload_if_changed()
	_load()
	var old_name: String = old_title.strip_edges()
	var new_name: String = new_title.strip_edges()
	if old_name == "" or new_name == "" or old_name == new_name:
		return 0
	if VaultStore.shared_title(old_title) or VaultStore.shared_title(new_title):
		return 0
	var changed: int = 0
	for t in topics():
		for o in t.get("objectives", []):
			for entries in [o.get("demos", []), o.get("log", [])]:
				for e in entries:
					var k: Dictionary = parse_key(str(e.get("activity", "")))
					var note: String = str(k.get("note", "")).strip_edges()
					if not k.is_empty() and (note == old_name or note == new_name):
						e.activity = activity_key(new_name if note == old_name else old_name, k.kind, k.index)
						changed += 1
	for kept in _in_trash.values():   # whose entries took which title
		if kept.title == old_name or kept.title == new_name:
			kept.title = new_name if kept.title == old_name else old_name
	if changed > 0:
		save()
	return changed


## VaultStore.trash_note moved the note titled `note_title` to `trash_path`:
## note which demos and log entries are its, for note_restored. They stay in
## journey.json as they are, for a restore by hand from the trash folder.
static func note_trashed(trash_path: String, note_title: String) -> void:
	var name: String = note_title.strip_edges()
	if name == "" or VaultStore.shared_title(note_title):   # untitled#quiz0 may be any untitled note's
		return
	reload_if_changed()
	_load()
	var kept: Dictionary = {"title": name, "demos": {}, "logs": {}}
	for t in topics():
		for o in t.objectives:
			for d in o.demos:
				if str(parse_key(str(d.activity)).get("note", "")).strip_edges() == name:
					kept.demos[str(d.id)] = true
			for e in o.log:
				if str(parse_key(str(e.activity)).get("note", "")).strip_edges() == name:
					kept.logs[_trashed_log_id(o, e)] = true
	if not (kept.demos.is_empty() and kept.logs.is_empty()):
		_in_trash[trash_path] = kept


## A note in the vault now has `note_title`: VaultStore.create_note and
## rename_note call this (Ctrl+N's untitled note named so, a dead link's
## Create, a Markdown import, any rename), VaultStore._import_tres (a .tres
## import), note_restored for a note back from the trash, and notes_listed
## for a note that came from outside the app. The demos and log entries of a
## note in the trash still keyed by that title (note_trashed) move to a title
## no note has (_parking_title), so the note that took it never logs to the
## trashed note's objectives; note_restored finds them there. A rename's
## trade (rename_note_keys) only covers renaming a titled note, and not one
## the MCP server makes. With `still_in_trash`, only a note whose file is
## still in the trash counts (notes_listed). Returns how many changed.
static func title_taken(note_title: String, still_in_trash: bool = false) -> int:
	var name: String = note_title.strip_edges()
	if _in_trash.is_empty() or name == "" or VaultStore.shared_title(note_title):
		return 0
	var changed: int = 0
	for trash_path in _in_trash:
		var kept: Dictionary = _in_trash[trash_path]
		if kept.title != name or not str(trash_path).begins_with(VaultStore.vault_path):   # another vault's trash
			continue
		if still_in_trash and not FileAccess.file_exists(trash_path):
			continue   # moved back by hand: the note listed with its title may be that one
		reload_if_changed()
		_load()
		var park: String = _parking_title(name)
		for t in topics():
			for o in t.objectives:
				for d in o.demos:
					var k: Dictionary = parse_key(str(d.activity))
					if not k.is_empty() and str(k.note).strip_edges() == name and kept.demos.has(str(d.id)):
						d.activity = activity_key(park, k.kind, k.index)
						changed += 1
				for e in o.log:
					var k: Dictionary = parse_key(str(e.activity))
					if not k.is_empty() and str(k.note).strip_edges() == name and kept.logs.has(_trashed_log_id(o, e)):
						e.activity = activity_key(park, k.kind, k.index)
						changed += 1
		kept.title = park
	if changed > 0:
		save()
	return changed


## VaultStore.refresh_note_list listed `notes`; `was` is {path: title} of the
## notes it listed before. A note listed with a trashed note's title it
## didn't have there before took that title outside the app: the MCP server
## (its own process, which knows nothing of the app's trash: _in_trash lives
## here), a sync tool, git. It never logs to the trashed note's objectives
## either (title_taken), while that note's file is still in the trash: one
## moved back by hand is that note, and keeps them. A note listed with the
## title before (two notes shared it) keeps them too. Returns how many changed.
static func notes_listed(notes: Array[ContentLayer], was: Dictionary) -> int:
	if _in_trash.is_empty():
		return 0
	var waiting: Dictionary = {}   # the titles trashed notes' entries are keyed by
	for kept in _in_trash.values():
		waiting[kept.title] = true
	var changed: int = 0
	for note in notes:
		var name: String = note.title.strip_edges()
		if waiting.has(name) and str(was.get(note.resource_path, "")).strip_edges() != name:
			changed += title_taken(note.title, true)
	return changed


## Where title_taken moves a trashed note's entries off `title`: "<title> (2)",
## "(3)"… (VaultStore.free_title's numbering), the first that no note in the
## vault has, no other trashed note's entries wait under and no entry names.
static func _parking_title(title: String) -> String:
	var used: Dictionary = {}
	for note in VaultStore.note_list:
		used[note.title.strip_edges().to_lower()] = true
	for kept in _in_trash.values():
		used[str(kept.title).to_lower()] = true
	for t in topics():
		for o in t.objectives:
			for entries in [o.demos, o.log]:
				for e in entries:
					used[str(parse_key(str(e.activity)).get("note", "")).strip_edges().to_lower()] = true
	var i: int = 2
	var park: String = "%s (2)" % title
	while used.has(park.to_lower()):
		i += 1
		park = "%s (%d)" % [title, i]
	return park


## The note trashed to `trash_path` is back, titled `note_title` (another
## title than its own when a note took that while it was in the trash:
## VaultStore.restore_from_trash). Its demos and log entries (note_trashed)
## take that title, wherever a rename traded them meanwhile, so its
## objectives log its scores again. Entries other notes made meanwhile stay
## theirs, and another trashed note's still keyed by that title move off it
## (title_taken). Returns how many of its own changed.
static func note_restored(trash_path: String, note_title: String) -> int:
	var kept: Dictionary = _in_trash.get(trash_path, {})
	_in_trash.erase(trash_path)
	title_taken(note_title)
	var name: String = note_title.strip_edges()
	if kept.is_empty() or name == "" or VaultStore.shared_title(note_title):
		return 0
	reload_if_changed()
	_load()
	var changed: int = 0
	for t in topics():
		for o in t.objectives:
			# Where its entries are now: its demos' titles (found by id), and
			# the title rename_note_keys followed
			var titles: Dictionary = {kept.title: true}
			for d in o.demos.duplicate():
				var k: Dictionary = parse_key(str(d.activity))
				if k.is_empty() or not kept.demos.has(str(d.id)):
					continue
				titles[str(k.note).strip_edges()] = true
				var key: String = activity_key(name, k.kind, k.index)
				if d.activity == key:
					continue
				if o.demos.any(func(other: Dictionary) -> bool: return other.activity == key):
					o.demos.erase(d)   # the objective has that demonstration already
				else:
					d.activity = key
				changed += 1
			for e in o.log:
				var k: Dictionary = parse_key(str(e.activity))
				if k.is_empty() or not titles.has(str(k.note).strip_edges()) or not kept.logs.has(_trashed_log_id(o, e)):
					continue
				var key: String = activity_key(name, k.kind, k.index)
				if e.activity != key:
					e.activity = key
					changed += 1
	if changed > 0:
		save()
	return changed


## A log entry of objective `o` as note_trashed knows it, without the note's
## title (a rename may change that): objective, date, score, max, activity kind and index.
static func _trashed_log_id(o: Dictionary, e: Dictionary) -> String:
	var k: Dictionary = parse_key(str(e.activity))
	return "%s|%s|%s|%s|%s%s" % [o.id, e.date, float(e.score), float(e.max), k.get("kind", ""), k.get("index", "")]


## All quizzes and flashcard decks in the vault.
static func activities() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for note in VaultStore.note_list:
		var counts: Dictionary = {"quiz": 0, "cards": 0}
		for b in scene_blocks(note.raw_text):
			var kind: String = activity_kind(b.params)
			if kind == "":
				continue
			var caption: String = str(b.params.get("caption", KIND_NAMES[kind]))
			out.append({
				"key": activity_key(note.title, kind, counts[kind]), "kind": kind,
				"note": note.title, "index": counts[kind], "caption": caption,
			})
			counts[kind] += 1
	out.sort_custom(func(a, b): return a.key.naturalnocasecmp_to(b.key) < 0)
	return out


## Human label for an activity key ("Tutorial 5 › Shapes and Colors quiz").
static func activity_label(key: String) -> String:
	for a in activities():
		if a.key == key:
			return "%s  ›  %s" % [a.note, a.caption]
	var k: Dictionary = parse_key(key)
	return "%s  ›  %s %d (missing)" % [k.get("note", key), KIND_NAMES.get(k.get("kind", ""), "Activity"), int(k.get("index", 0)) + 1]
