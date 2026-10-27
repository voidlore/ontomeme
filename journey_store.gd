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
static var _data: Dictionary = {}
static var _loaded_from: String = ""


static func path() -> String:
	return file_override if file_override != "" else VaultStore.data_dir().path_join("journey.json")


static func invalidate() -> void:
	_loaded_from = ""


static func _load() -> void:
	if _loaded_from == path():
		return
	_loaded_from = path()
	_data = {"topics": []}
	if FileAccess.file_exists(path()):
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path()))
		if v is Dictionary and (v as Dictionary).get("topics") is Array:
			_data = v


static func save() -> void:
	_load()
	DirAccess.make_dir_recursive_absolute(path().get_base_dir())
	var f := FileAccess.open(path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_data, "\t"))


static func reset() -> void:
	_load()
	_data = {"topics": []}
	save()


static func _new_id() -> String:
	return "%x%04x" % [Time.get_unix_time_from_system() * 1000, randi() % 0xffff]


# ── Topics & objectives ─────────────────────────────────────────────────────

static func topics() -> Array:
	_load()
	return _data.topics


static func add_topic(name: String, description: String = "") -> Dictionary:
	var t: Dictionary = {"id": _new_id(), "name": name, "description": description, "objectives": []}
	topics().append(t)
	save()
	return t


static func remove_topic(id: String) -> void:
	_data.topics = topics().filter(func(t): return t.id != id)
	save()


static func find_topic(id: String) -> Dictionary:
	for t in topics():
		if t.id == id:
			return t
	return {}


static func add_objective(topic_id: String, name: String, description: String = "", goal: String = "learning") -> Dictionary:
	var t: Dictionary = find_topic(topic_id)
	if t.is_empty():
		return {}
	var o: Dictionary = {"id": _new_id(), "name": name, "description": description, "goal": goal, "demos": [], "log": []}
	t.objectives.append(o)
	save()
	return o


static func remove_objective(id: String) -> void:
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


# ── Demonstrations ──────────────────────────────────────────────────────────

static func add_demo(objective_id: String, activity: String, output: String = "percent") -> Dictionary:
	var o: Dictionary = find_objective(objective_id)
	if o.is_empty():
		return {}
	for d in o.demos:
		if d.activity == activity:
			return d
	var d: Dictionary = {"id": _new_id(), "activity": activity, "output": output}
	o.demos.append(d)
	save()
	return d


static func remove_demo(objective_id: String, demo_id: String) -> void:
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


## Latest entry per demo, and whether that meets the objective's goal.
static func summary(o: Dictionary) -> Dictionary:
	var latest: Dictionary = {}
	for e in o.log:
		latest[e.activity] = e
	var best: float = -1.0
	for e in o.log:
		best = maxf(best, normalized(e))
	var need: float = 0.9 if o.goal == "fluent" else ProgressStore.PASS_RATIO - 0.0001
	var met: bool = not o.demos.is_empty()
	for d in o.demos:
		if not latest.has(d.activity) or normalized(latest[d.activity]) < need:
			met = false
	return {"attempts": o.log.size(), "best": best, "met": met, "latest": latest}


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
