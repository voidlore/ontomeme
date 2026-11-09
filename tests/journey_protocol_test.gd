extends SceneTree
## The learning-objectives protocol, v1 (skills/ontomeme-notes/references/
## objectives-protocol.md): journey.json carries "version": 1, and a file an
## agent or a person wrote by hand loads without script errors. Broken
## entries are dropped one by one, bad goals become "learning", missing ids
## are filled in, and keys the app doesn't know survive a save.
##   headless:  godot --headless --path . -s res://tests/journey_protocol_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const DIR: String = "user://test-journey-protocol"

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func empty_dir(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))


func write_json(p: String, data: Variant) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t", false))
	f.close()


func ids_of(list: Array) -> Array:
	return list.map(func(e): return e.id)


## One good topic, and around it every kind of mistake a hand or an agent
## makes. `x_agent` keys stand for whatever a newer writer adds.
func hand_written() -> Dictionary:
	return {
		"x_agent": {"by": "an agent", "run": 7},
		"topics": [
			{"id": "t1", "name": "Colour", "description": "Paint, not light.", "x_agent": "topic note", "objectives": [
				{"id": "o1", "name": "Mix secondary colours", "description": "", "goal": "fluent", "x_agent": true,
					"demos": [
						{"id": "d1", "activity": "Colour Lesson#quiz0", "output": "percent"},
						{"id": "d2", "output": "percent"},                                    # no activity: dropped
						{"id": "d3", "activity": "Colour Lesson#cards0", "output": "grade"},  # unknown output: dropped
						{"activity": "Colour Lesson#quiz1"},                                  # no id, no output: filled in
					],
					"log": [
						{"date": "2026-11-01T10:00:00", "activity": "Colour Lesson#quiz0", "score": 3, "max": 3, "output": "percent", "value": 100, "x_agent": 1},
						{"date": "2026-11-02T10:00:00", "activity": "Colour Lesson#quiz0", "score": "ten", "max": 3, "output": "percent", "value": 100},  # dropped
						{"activity": "Colour Lesson#quiz0", "score": 2, "max": 3, "value": 67},   # no date, no output: filled in
					]},
				{"id": "o2", "name": "Name the hues", "goal": "expert", "demos": [], "log": []},   # goal -> learning
				{"name": "No id yet", "description": 42},                                           # id, goal, demos, log filled in; description ""
				{"id": "o1", "name": "Copied id", "goal": "forget"},                                # repeated id: replaced
				{"id": "o5", "description": "no name"},                                             # dropped
				{"id": "o6", "name": "Bad log", "log": "none"},                                     # dropped
				"not an objective",                                                                 # dropped
			]},
			{"id": "t2", "objectives": []},                          # no name: dropped
			{"id": "t3", "name": "Broken", "objectives": "none"},    # objectives not a list: dropped
			{"name": "Fresh"},                                       # id and objectives filled in
			7,                                                       # dropped
		],
	}


func _init() -> void:
	empty_dir(DIR)
	JourneyStore.file_override = DIR.path_join("journey.json")
	ProgressStore.file_override = DIR.path_join("progress.json")
	TestVault.open("journey-protocol", false)   # never touch the user's vault

	# ── A hand-written file loads, sanitized ──
	write_json(JourneyStore.file_override, hand_written())
	var original: String = FileAccess.get_file_as_string(JourneyStore.file_override)
	JourneyStore.invalidate()
	var topics: Array = JourneyStore.topics()
	check(topics.map(func(t): return t.name) == ["Colour", "Fresh"], "only the topics without a name or with a broken objectives list are dropped (%s)" % [topics.map(func(t): return t.name)])
	var colour: Dictionary = JourneyStore.find_topic("t1")
	check(colour.get("objectives", []).map(func(o): return o.name) == ["Mix secondary colours", "Name the hues", "No id yet", "Copied id"], "objectives without a name or with a broken log, and non-objects, are dropped; the rest stay")
	var good: Dictionary = JourneyStore.find_objective("o1")
	check(good.get("name") == "Mix secondary colours" and good.goal == "fluent", "the good objective survives as written")
	check(good.demos.size() == 2 and good.demos[0].id == "d1" and good.demos[1].activity == "Colour Lesson#quiz1", "the demo with no activity and the one with an unknown output are dropped")
	check(good.demos[1].get("output") == "percent" and str(good.demos[1].get("id", "")) != "", "a demo without an output scores as percent and gets an id")
	check(good.log.size() == 2 and good.log.all(func(e): return e.score is float or e.score is int), "the log entry with score 'ten' is dropped")
	check(good.log[1].get("date") == "" and good.log[1].get("output") == "percent", "a log entry without a date or output gets \"\" and percent")
	check(JourneyStore.find_objective("o2").get("goal") == "learning", "goal 'expert' becomes 'learning'")
	var no_id: Dictionary = colour.objectives[2]
	check(no_id.id is String and no_id.id != "" and no_id.goal == "learning" and no_id.demos == [] and no_id.log == [] and no_id.description == "", "an objective without id, goal, demos or log gets them; a description that isn't text becomes \"\"")
	var copied: Dictionary = colour.objectives[3]
	var all_ids: Array = ids_of(topics) + ids_of(colour.objectives) + ids_of(good.demos)
	check(copied.id != "o1" and copied.goal == "forget", "a repeated id is replaced by a new one")
	check(all_ids.size() == all_ids.filter(func(i): return all_ids.count(i) == 1).size(), "every topic, objective and demo id is unique")
	var fresh: Dictionary = topics[1]
	check(fresh.id is String and fresh.id != "" and fresh.objectives == [] and fresh.description == "", "a topic without an id or objectives gets them")

	# ── The rest of the store works over it ──
	var s: Dictionary = JourneyStore.summary(good)
	check(s.attempts == 2 and not s.met, "summary() reads the sanitized log (2 attempts, quiz1 never tried)")
	check(JourneyStore.log_score("Colour Lesson#quiz1", 3, 3) == 1 and not JourneyStore.summary(good).met, "a new score logs on the filled-in demo (quiz0's latest, 67%, is still short of Fluent)")
	check(JourneyStore.log_score("Colour Lesson#quiz0", 3, 3) == 1 and JourneyStore.summary(good).met, "3 / 3 on quiz0 too meets the Fluent goal")
	check(JourneyStore.add_objective("t1", "Odd goal", "", "expert").goal == "learning" and JourneyStore.add_demo("o2", "Colour Lesson#quiz0", "grade").output == "percent", "add_objective and add_demo don't write values outside the protocol")

	# ── What was dropped is kept in a copy, and the user is told ──
	var kept: PackedStringArray = []
	for f in DirAccess.get_files_at(DIR):
		if f.match("journey.unreadable-*.json"):
			kept.append(f)
	check(kept.size() == 1 and FileAccess.get_file_as_string(DIR.path_join(kept[0])) == original, "the original file, broken entries and all, is kept as journey.unreadable-<stamp>.json")
	check(kept.size() == 1 and JourneyStore.last_error.contains(kept[0]) and JourneyStore.last_error.contains("11 broken entries"), "last_error counts the broken entries and names the copy (%s)" % JourneyStore.last_error)

	# ── Save: version 1 first, unknown keys kept ──
	JourneyStore.save()
	var text: String = FileAccess.get_file_as_string(JourneyStore.file_override)
	var saved: Variant = JSON.parse_string(text)
	check(saved is Dictionary and saved.get("version") == 1.0, "a saved file has version == 1")
	check(text.begins_with("{\n\t\"version\": 1,"), "version is the first key in the file")
	check(saved.get("x_agent") == {"by": "an agent", "run": 7.0}, "the top-level unknown key 'x_agent' is still there after save()")
	var t1: Dictionary = saved.topics[0]
	check(t1.get("x_agent") == "topic note" and t1.objectives[0].get("x_agent") == true and t1.objectives[0].log[0].get("x_agent") == 1.0, "unknown keys on topics, objectives and log entries survive too")
	JourneyStore.invalidate()
	check(JourneyStore.topics().size() == 2 and JourneyStore.last_error == "", "the saved file reloads clean: nothing more to drop, no error")
	check(Array(DirAccess.get_files_at(DIR)).filter(func(f): return f.match("journey.unreadable-*.json")).size() == 1, "and no second copy is made")

	# ── A new, empty journey is version 1 too ──
	JourneyStore.reset()
	saved = JSON.parse_string(FileAccess.get_file_as_string(JourneyStore.file_override))
	check(saved == {"version": 1.0, "topics": []}, "reset() writes {version: 1, topics: []} (%s)" % [saved])

	empty_dir(DIR)
	DirAccess.remove_absolute(DIR)
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	JourneyStore.invalidate()
	ProgressStore.invalidate()
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)
