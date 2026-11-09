extends SceneTree
## Renaming a note follows it everywhere it was named (RenameCascade): other
## notes' [[links]], quiz learn:/review:/next: lines, Journey demo and log
## keys, and quiz progress. Code spans and plain fences keep the old title.
##   headless:  godot --headless --path . -s res://tests/rename_cascade_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")

const PHOTO_TEXT: String = "Plants make sugar from light.\n\n## Light\n\nSee [[Photosynthesis#Light]] above.\n\n```3d\npreset: quiz\nq: What do plants make?\na: Salt\na*: Sugar\nlearn: Photosynthesis\n```\n"
const QUIZ: String = "```3d\npreset: quiz\nq: Q?\na*: Yes\na: No\n```\n"
const LEAF_TEXT: String = "Leaves do [[Photosynthesis|ps]].\nWrite a link as `[[Photosynthesis]]` in code.\nAlso [[photosynthesis#Light|light]], [[Photosynthesis Extra]] and [[Respiration]].\n\n```3d\npreset: quiz\nq: Where is sugar made?\na: Roots\na*: Leaves\nlearn: Photosynthesis\nq: Again?\na*: Yes\na: No\nreview: [[Photosynthesis]]\n```\n\n```\nlearn: Photosynthesis\n[[Photosynthesis]] in a plain fence\n```\n\nNext: [[Photosynthesis]]\n"

var fails: int = 0
var app: Control
var V: String


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## A saved note titled `title` with `text` and a chosen `modified` (the
## sidebar and WikiLinks order notes by it, newest first).
func make_note(title: String, text: String, modified: String = "") -> ContentLayer:
	var note: ContentLayer = VaultStore.create_note(title)
	note.raw_text = text
	if modified != "":
		note.modified = modified
	VaultStore.save_note(note, modified == "")
	return note


## The note's text as its file holds it now.
func on_disk(note: ContentLayer) -> String:
	var n: ContentLayer = ResourceLoader.load(note.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	return n.raw_text if n != null else ""


func titled(title: String) -> Array:
	return VaultStore.note_list.filter(func(n: ContentLayer) -> bool: return n.title.strip_edges().to_lower() == title.to_lower())


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_rename_cascade.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_rename_cascade.json"   # never touch real progress
	ProgressStore.reset()
	V = TestVault.open("rename-cascade", false)
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)

	await rename_in_the_app()
	await untitled_names_no_note()
	await duplicate_titles_from_before()
	await backtick_title_in_the_app()
	rewrite_rules()
	store_keys()
	conflict_stops_the_rewrites()
	if OS.get_name() in ["Linux", "macOS", "FreeBSD"]:
		unsaved_link_note_is_left()
	else:
		print("SKIP  a linking note in a read-only folder (chmod) on " + OS.get_name())
	mcp_title_change()
	mcp_title_taken()
	mcp_note_changed_mid_cascade()
	mcp_untitled()
	mcp_backtick_title()
	mcp_case_only_rename()
	await mcp_rename_while_the_app_is_open()

	app.queue_free()
	await frames(2)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	TestVault.remove_tree(V)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


# ── gap-rename-cascade: the acceptance, through the title field ─────────────

func rename_in_the_app() -> void:
	var photo: ContentLayer = make_note("Photosynthesis", PHOTO_TEXT)
	var leaf: ContentLayer = make_note("Leaf", LEAF_TEXT, "2020-01-01T00:00:00")
	var topic: Dictionary = JourneyStore.add_topic("Plants")
	var obj: Dictionary = JourneyStore.add_objective(topic.id, "Explain photosynthesis")
	JourneyStore.add_demo(obj.id, "Photosynthesis#quiz0")
	JourneyStore.add_demo(obj.id, "Leaf#quiz0")
	check(JourneyStore.log_score("Photosynthesis#quiz0", 1, 1) == 1 and obj.log.size() == 1, "setup: the Journey logs one score for Photosynthesis#quiz0")
	ProgressStore.record_answer("Photosynthesis", 0, 0, "What do plants make?", true, "Photosynthesis")
	ProgressStore.record_result("Photosynthesis", 0, 1, 1)
	check(ProgressStore.status("Photosynthesis") == "done", "setup: Photosynthesis is done (its quiz passed)")
	var count: int = VaultStore.note_list.size()

	app._open_note(photo)
	app._switch_layer("raw")
	await frames(2)
	app.title_edit.text = "Light reactions"
	app._commit_title()
	await frames(2)

	check(photo.title == "Light reactions" and photo.resource_path == V + "note_light_reactions.tres", "the note and its file are renamed (%s)" % photo.resource_path.get_file())
	check(leaf.raw_text.contains("[[Light reactions|ps]]"), "[[Photosynthesis|ps]] becomes [[Light reactions|ps]]")
	check(leaf.raw_text.contains("`[[Photosynthesis]]`"), "the code span `[[Photosynthesis]]` is left as it is")
	check(leaf.raw_text.contains("[[Light reactions#Light|light]]"), "[[photosynthesis#Light|light]] keeps its heading and alias")
	check(leaf.raw_text.contains("[[Photosynthesis Extra]]") and leaf.raw_text.contains("[[Respiration]]"), "links to other titles are untouched, even one that starts with the old title")
	check(leaf.raw_text.contains("learn: Light reactions\n"), "the quiz says learn: Light reactions")
	check(leaf.raw_text.contains("review: [[Light reactions]]"), "review: [[Photosynthesis]] keeps its brackets")
	check(leaf.raw_text.contains("```\nlearn: Photosynthesis\n[[Photosynthesis]] in a plain fence"), "a plain ``` fence is left as it is")
	check(leaf.raw_text.contains("Next: [[Light reactions]]"), "the Next: [[link]] follows")
	check(on_disk(leaf) == leaf.raw_text, "Leaf's file holds the rewritten text")
	check(leaf.modified == "2020-01-01T00:00:00", "Leaf keeps its modified date: the user didn't edit it (%s)" % leaf.modified)
	check(photo.raw_text.contains("See [[Light reactions#Light]] above.") and photo.raw_text.contains("learn: Light reactions"), "the renamed note's links to itself follow too")
	check(app.raw_text_layer.text == photo.raw_text, "…and the editor shows that text, so the next autosave keeps it")

	var demo_keys: Array = obj.demos.map(func(d: Dictionary) -> String: return d.activity)
	check(demo_keys == ["Light reactions#quiz0", "Leaf#quiz0"], "the demo key is Light reactions#quiz0; Leaf's is untouched (%s)" % str(demo_keys))
	check(obj.log.size() == 1 and obj.log[0].activity == "Light reactions#quiz0", "the log entry is kept, under the new key")
	JourneyStore.invalidate()
	var saved: Dictionary = JourneyStore.find_objective(obj.id)
	check(not saved.is_empty() and saved.demos[0].activity == "Light reactions#quiz0" and saved.log.size() == 1, "…and saved to journey.json")
	check(JourneyStore.summary(saved).latest.has("Light reactions#quiz0"), "the objective's summary finds the score under the new key")

	ProgressStore.invalidate()
	check(ProgressStore.status("Light reactions") == "done", "ProgressStore.status('Light reactions') == 'done' (%s)" % ProgressStore.status("Light reactions"))
	check(ProgressStore.status("Photosynthesis") == "" and not ProgressStore._data.quizzes.has("photosynthesis#0"), "nothing is left under the old title")
	var answer: Dictionary = ProgressStore._data.questions.get("light reactions#0#0", {})
	check(answer.get("from") == "Light reactions" and answer.get("learn") == "Light reactions", "the answer's key, from and learn follow (%s)" % str(answer))

	check(app.status_label.text == "Renamed to Light reactions · updated 7 links in 2 notes", "the status counts links and notes (%s)" % app.status_label.text)
	check(WikiLinks.backlinks(photo).has(leaf), "Leaf links to the renamed note again")

	# Following each link (what a click does) opens it and creates nothing
	for span in WikiLinks.spans(leaf.raw_text):
		if str(span.target).to_lower().begins_with("light"):
			app.open_note_by_title(str(span.text), true)
			check(app.current_note == photo, "clicking [[%s]] opens Light reactions" % span.text)
	check(titled("Photosynthesis").is_empty() and not FileAccess.file_exists(V + "note_photosynthesis.tres"), "no note named Photosynthesis exists afterwards")
	check(VaultStore.note_list.size() == count, "no note was created (%d notes)" % VaultStore.note_list.size())


# ── "untitled" names no one note: a rename to or from it moves nothing ─────

## The progress and Journey files' bytes.
func store_files() -> String:
	return FileAccess.get_file_as_string(ProgressStore.path()) + "\n" + FileAccess.get_file_as_string(JourneyStore.path())


func untitled_names_no_note() -> void:
	ProgressStore.reset()
	JourneyStore.reset()
	var draft: ContentLayer = make_note("untitled", "An older draft.\n\n" + QUIZ, "2021-01-01T00:00:00")
	var physics: ContentLayer = make_note("Physics", "Forces.\n\n" + QUIZ, "2021-06-01T00:00:00")
	var linker: ContentLayer = make_note("Linker", "See [[untitled]] and [[Physics]].", "2020-06-01T00:00:00")
	var linker_text: String = linker.raw_text
	ProgressStore.record_result("untitled", 0, 1, 1)   # the draft's quiz: passed
	ProgressStore.record_result("Physics", 0, 0, 1)    # Physics': failed
	var o: Dictionary = JourneyStore.add_objective(JourneyStore.add_topic("Drafts").id, "Finish the draft")
	JourneyStore.add_demo(o.id, "untitled#quiz0")
	JourneyStore.add_demo(o.id, "Physics#quiz0")
	JourneyStore.log_score("untitled#quiz0", 1, 1)
	var stores: String = store_files()

	# A new note starts untitled; the user names it
	app._on_new_note_pressed()
	await frames(2)
	var fresh: ContentLayer = app.current_note
	check(fresh != draft and fresh.title == "untitled", "setup: a new note starts untitled, beside an older untitled draft")
	app.title_edit.text = "Chemistry"
	app._commit_title()
	await frames(2)
	check(fresh.title == "Chemistry" and draft.title == "untitled", "the new note is named Chemistry")
	check(app.status_label.text == "Renamed to Chemistry", "naming an untitled note updates nothing else (%s)" % app.status_label.text)
	check(linker.raw_text == linker_text and on_disk(linker) == linker_text, "[[untitled]] in another note is left as it is (%s)" % linker.raw_text.c_escape())
	check(store_files() == stores, "the draft's quiz result, Journey demo and log stay under untitled: progress and journey files unchanged")
	ProgressStore.invalidate()
	JourneyStore.invalidate()
	check(ProgressStore.quiz_passed("untitled", 0) and not ProgressStore._data.quizzes.has("chemistry#0"), "untitled#0 is still passed; Chemistry took no result (%s)" % str(ProgressStore._data.quizzes.keys()))
	var demos: Array = JourneyStore.find_objective(o.id).demos.map(func(d: Dictionary) -> String: return d.activity)
	check(demos == ["untitled#quiz0", "Physics#quiz0"], "the Journey demos keep their keys (%s)" % str(demos))

	# Clearing a title makes the note untitled: its links and keys stay put
	app._open_note(physics)
	await frames(2)
	app.title_edit.text = ""
	app._commit_title()
	await frames(2)
	check(physics.title == "untitled" and app.title_edit.text == "", "clearing Physics' title makes it untitled")
	check(linker.raw_text == linker_text and on_disk(linker) == linker_text, "[[Physics]] is not rewritten to [[untitled]], which opens another note (%s)" % linker.raw_text.c_escape())
	check(app.status_label.text == "Renamed to Untitled · a [[link]] can't name an untitled note, so links to “Physics” were left as they are", "the status says the links were left and why (%s)" % app.status_label.text)
	check(store_files() == stores, "progress and Journey unchanged: the draft's passed untitled#0 is not overwritten by Physics' failed result")
	ProgressStore.invalidate()
	check(ProgressStore.quiz_passed("untitled", 0) and ProgressStore._data.quizzes.get("physics#0", {}).get("passed") == false, "untitled#0 stays passed and physics#0 stays failed")

	# Named again, it is found by what named it before
	app.title_edit.text = "Physics"
	app._commit_title()
	await frames(2)
	check(physics.title == "Physics" and app.status_label.text == "Renamed to Physics", "named Physics again, nothing else is updated (%s)" % app.status_label.text)
	check(WikiLinks.resolve("Physics") == physics and store_files() == stores, "[[Physics]] reaches it again and its progress and Journey keys were there all along")


# ── Two notes with one title (from before renames refused that) ─────────────

func duplicate_titles_from_before() -> void:
	ProgressStore.reset()
	JourneyStore.reset()
	var a: ContentLayer = make_note("Osmosis", "A: the one links reach.\n\n" + QUIZ, "2025-01-01T00:00:00")
	var b: ContentLayer = make_note("Osmosis", "B: an old draft.", "2020-01-01T00:00:00")
	var cell: ContentLayer = make_note("Cell", "Water moves by [[Osmosis]].", "2019-01-01T00:00:00")
	ProgressStore.record_result("Osmosis", 0, 1, 1)
	var o: Dictionary = JourneyStore.add_objective(JourneyStore.add_topic("Cells").id, "Explain osmosis")
	JourneyStore.add_demo(o.id, "Osmosis#quiz0")
	var stores: String = store_files()
	check(titled("Osmosis").size() == 2 and WikiLinks.resolve("Osmosis") == a, "setup: two notes are titled Osmosis and [[Osmosis]] reaches the newer one, A")

	# Renaming the older one, B: its save makes it the newest note, but the
	# links went to A before the rename and still do
	app._open_note(b)
	await frames(2)
	app.title_edit.text = "Old draft"
	app._commit_title()
	await frames(2)
	check(b.title == "Old draft" and VaultStore.note_list.find(b) < VaultStore.note_list.find(a), "B is renamed (and now sorts before A: its save stamped it)")
	check(cell.raw_text == "Water moves by [[Osmosis]]." and on_disk(cell) == cell.raw_text and WikiLinks.resolve("Osmosis") == a, "Cell's [[Osmosis]], a link to A, is left pointing at A (%s)" % cell.raw_text)
	check(app.status_label.text == "Renamed to Old draft", "no link is counted as updated (%s)" % app.status_label.text)
	check(store_files() == stores, "osmosis#0 and Osmosis#quiz0 stay with A, which still has the title")

	# A, now the only Osmosis, takes its links and keys along
	app._open_note(a)
	await frames(2)
	app.title_edit.text = "Water osmosis"
	app._commit_title()
	await frames(2)
	check(cell.raw_text == "Water moves by [[Water osmosis]]." and app.status_label.text == "Renamed to Water osmosis · updated 1 link in 1 note", "renaming A updates Cell's link (%s)" % app.status_label.text)
	ProgressStore.invalidate()
	JourneyStore.invalidate()
	check(ProgressStore.quiz_passed("Water osmosis", 0) and JourneyStore.find_objective(o.id).demos[0].activity == "Water osmosis#quiz0", "…and its progress and Journey demo")


# ── A title with a `code span` can't be a link target ───────────────────────

## WikiLinks and the Read view cut `code spans` out of a line before they
## look for [[links]], so [[Using `git` well]] would be plain text: the
## links stay as they were, and the status line says so. Quiz learn: and
## next: lines read their value whole (NoteScene3D trims only the [[ ]]),
## so they still follow the note, as its progress keys do.
func backtick_title_in_the_app() -> void:
	ProgressStore.reset()
	JourneyStore.reset()
	var git: ContentLayer = make_note("Git", "about git\n\n```3d\npreset: quiz\nq: Q?\na*: Yes\na: No\nlearn: Git\n```\n", "2018-01-01T00:00:00")
	var hub: ContentLayer = make_note("Hub", "See [[Git]] now and [[Git|the tool]].", "2018-01-01T00:00:00")
	var lesson: ContentLayer = make_note("Lesson", "Intro.\n\n```3d\npreset: quiz\nq: Which tool?\na*: git\na: svn\nlearn: Git\nnext: [[Git]]\n```\n", "2018-01-01T00:00:00")
	var hub_text: String = hub.raw_text
	ProgressStore.record_answer("Lesson", 0, 0, "Which tool?", false, "Git")
	check(WikiLinks.backlinks(git).has(hub) and ProgressStore.missed_for("Git").size() == 1, "setup: Hub links to Git, and a missed Lesson question sends the learner to Git")
	app._open_note(git)
	await frames(2)
	app.title_edit.text = "Using `git` well"
	app._commit_title()
	await frames(2)
	check(git.title == "Using `git` well", "the note is renamed (%s)" % git.title)
	check(hub.raw_text == hub_text and on_disk(hub) == hub_text, "Hub's links are left as they are, not turned into plain text (%s)" % hub.raw_text)
	check(lesson.raw_text.contains("learn: Using `git` well\nnext: [[Using `git` well]]\n") and on_disk(lesson) == lesson.raw_text,
		"Lesson's quiz learn: and next: lines follow the note (%s)" % lesson.raw_text.c_escape())
	check(git.raw_text.contains("learn: Using `git` well\n") and on_disk(git) == git.raw_text, "…and so does the renamed note's own quiz (%s)" % git.raw_text.c_escape())
	check(quiz_learn(lesson) == git.title and ProgressStore._find_note(quiz_learn(lesson)) == git, "the quiz card's learn: finds the renamed note (%s)" % quiz_learn(lesson))
	check(quiz_next(lesson) == git.title, "…and its Next tile opens it (%s)" % quiz_next(lesson))
	check(ProgressStore.missed_for(quiz_learn(lesson)).size() == 1, "the stored missed answer and the quiz's learn: still agree, so the renamed note is flagged for review")
	check(app.status_label.text == "Renamed to Using `git` well · updated 3 links in 2 notes · a [[link]] can't name a title with ], | or `, so [[links]] to “Git” were left as they are",
		"the status counts the quiz lines and says the [[links]] were left and why (%s)" % app.status_label.text)

	# Named Git again, the quiz lines come back and the links reach it again
	app.title_edit.text = "Git"
	app._commit_title()
	await frames(2)
	check(git.title == "Git" and lesson.raw_text.contains("learn: Git\nnext: [[Git]]\n") and git.raw_text.contains("learn: Git\n"), "renamed back to Git, the quiz lines follow (%s)" % lesson.raw_text.c_escape())
	check(hub.raw_text == hub_text and WikiLinks.backlinks(git).has(hub), "…and Hub's untouched links reach it again")
	check(app.status_label.text == "Renamed to Git · updated 3 links in 2 notes", "the status counts the quiz lines only (%s)" % app.status_label.text)


## The first quiz block of `note`, as NoteScene3D reads it.
func quiz_block(note: ContentLayer) -> NoteScene3D:
	var lines: PackedStringArray = note.raw_text.split("\n")
	var start: int = lines.find("```3d")
	var end: int = lines.find("```", start + 1)
	return NoteScene3D.from_block("3d", lines.slice(start + 1, end))


## The learn: of the first question of `note`'s first quiz, as the quiz card reads it.
func quiz_learn(note: ContentLayer) -> String:
	var block: NoteScene3D = quiz_block(note)
	var qs: Array[Dictionary] = NoteScene3D.parse_quiz(block.params.get("_lines", PackedStringArray()))
	block.free()
	return str(qs[0].learn) if not qs.is_empty() else ""


## Where the Next tile of `note`'s first quiz goes.
func quiz_next(note: ContentLayer) -> String:
	var block: NoteScene3D = quiz_block(note)
	var next: String = block.next_lesson()
	block.free()
	return next


# ── Which references follow, as RenameCascade.rewrite sees them ─────────────

func rewrite_rules() -> void:
	var c := ContentLayer.new()
	c.title = "D"   # renamed from "C"
	var tips := ContentLayer.new()
	tips.title = "C# Tips"
	var index: Dictionary = RenameCascade.index_before([tips, c], c, "C")
	var cases: Dictionary = {
		"[[C]]": "[[D]]",
		"[[ C ]]": "[[ D ]]",
		"[[C #Intro|x]]": "[[D #Intro|x]]",
		"[[C#Intro]] and [[C# Tips]]": "[[D#Intro]] and [[C# Tips]]",
		"[[C# Tips#Intro]]": "[[C# Tips#Intro]]",
		"`[[C]]` [[C]] `x`": "`[[C]]` [[D]] `x`",
		"```3d\npreset: quiz\nq: Q\na*: A\na: B\nlearn: C\r\nsee: [[ C#Part ]]\n```": "```3d\npreset: quiz\nq: Q\na*: A\na: B\nlearn: D\r\nsee: [[ D#Part ]]\n```",
		"```3d flashcards\nq: Front\na: Back\nnext: [[C]]\n```": "```3d flashcards\nq: Front\na: Back\nnext: [[D]]\n```",
		"```3d\ncube: red\nlearn: C\n```": "```3d\ncube: red\nlearn: C\n```",
		"````\n```3d\npreset: quiz\nlearn: C\n```\n[[C]]\n````": "````\n```3d\npreset: quiz\nlearn: C\n```\n[[C]]\n````",
		"```3d\npreset: quiz\nlearn: C\n": "```3d\npreset: quiz\nlearn: C\n",
	}
	for before in cases:
		var got: Dictionary = RenameCascade.rewrite(before, c, "D", index)
		check(got.text == cases[before], "rewrite %s -> %s (%s)" % [before.c_escape(), str(cases[before]).c_escape(), str(got.text).c_escape()])
	check(RenameCascade.rewrite("[[C]] and `[[C]]`", c, "D", index).links == 1, "rewrite counts the references it changed")

	# Duplicate titles: links went to the first note with the title
	var first := ContentLayer.new()
	first.title = "Dup"
	var second := ContentLayer.new()
	second.title = "Dup 2"   # renamed from "Dup"
	var dup_index: Dictionary = RenameCascade.index_before([first, second], second, "Dup")
	check(RenameCascade.rewrite("[[Dup]]", second, "Dup 2", dup_index).links == 0, "a link that resolved to another note with the same title stays")

	check(not RenameCascade.linkable("A|B") and not RenameCascade.linkable("A]") and RenameCascade.linkable("C# Tips"), "a title with ] or | can't be a link target")
	for t in ["Using `git` well", "A `b"]:
		check(not RenameCascade.linkable(t) and WikiLinks.spans("[[%s]] `x`" % t).size() != 1, "a title with a backtick can't be a link target either: `code spans` are cut out first (%s)" % t)
	var quiz_c: String = "See [[C]].\n\n```3d\npreset: quiz\nq: Q?\na*: Yes\na: No\nlearn: C\nnext: [[C]]\n```\n"
	for t in ["Using `c` well", "C|D", "C]"]:
		var kept: Dictionary = RenameCascade.rewrite(quiz_c, c, t, index, false)
		check(kept.text == quiz_c.replace("learn: C\nnext: [[C]]", "learn: %s\nnext: [[%s]]" % [t, t]) and kept.links == 2 and kept.left == 1,
			"with links held back, the [[link]] stays and is counted as left while learn:/next: lines follow (%s: %s)" % [t, str(kept).c_escape()])
		check(RenameCascade.lines_follow("C", t), "learn:/next: lines can name %s" % t)
	for t in ["C]]", "[[C"]:
		check(not RenameCascade.lines_follow("C", t), "a learn: line can't name %s: the quiz card trims [[ and ]] off its value" % t)
	check(not RenameCascade.lines_follow("untitled", "C") and not RenameCascade.lines_follow("C", "Untitled"), "learn:/next: lines don't follow a rename to or from untitled")
	var held: Dictionary = RenameCascade.rewrite(quiz_c, c, "C]]", index, false, false)
	check(held.text == quiz_c and held.links == 0 and held.left == 3, "with both held back nothing changes and every reference is left (%s)" % str(held).c_escape())
	var writes: Array = []
	var writer: Callable = func(n: ContentLayer, _t: String) -> String:
		writes.append(n)
		return ""
	c.title = "C|D"
	var report: Dictionary = RenameCascade.run([tips, c], c, "C", "C|D", writer)
	check(report.links == 0 and report.notes == 0 and report.warnings.size() == 0, "run() with no references writes nothing and warns about nothing")
	var linking := ContentLayer.new()
	linking.title = "Linking"
	linking.raw_text = "[[C]]"
	report = RenameCascade.run([linking, c], c, "C", "C|D", writer)
	check(writes.is_empty() and linking.raw_text == "[[C]]" and report.warnings.size() == 1 and str(report.warnings[0].message).contains("can't name"),
		"renaming to a title a link can't name leaves the links and says why")
	var quizzer := ContentLayer.new()
	quizzer.title = "Quizzer"
	quizzer.raw_text = quiz_c
	var texts: Dictionary = {}
	var keeper: Callable = func(n: ContentLayer, t: String) -> String:
		texts[n] = t
		return ""
	report = RenameCascade.run([quizzer, c], c, "C", "C|D", keeper)
	check(texts.keys() == [quizzer] and str(texts.get(quizzer, "")) == quiz_c.replace("learn: C\nnext: [[C]]", "learn: C|D\nnext: [[C|D]]") and report.links == 2 and report.notes == 1,
		"run() still writes the quiz lines when the [[links]] can't follow (%s)" % str(texts.values()).c_escape())
	check(report.warnings.size() == 1 and str(report.warnings[0].message) == "a [[link]] can't name a title with ], | or `, so [[links]] to “C” were left as they are",
		"…and warns that the [[links]] were left (%s)" % str(report.warnings))
	texts.clear()
	report = RenameCascade.run([quizzer, c], c, "C", "C]]", keeper)
	check(texts.is_empty() and report.warnings.size() == 1 and str(report.warnings[0].message).contains("references to “C” were left"),
		"a title neither a link nor a learn: line can name leaves everything and says so (%s)" % str(report.warnings))


# ── Journey and progress keys, exactly ──────────────────────────────────────

func store_keys() -> void:
	ProgressStore.reset()
	ProgressStore.record_result("C", 0, 3, 3)
	ProgressStore.record_result("C# Tips", 0, 3, 3)
	ProgressStore.record_answer("C# Tips", 0, 1, "Which?", true, "C# Tips")
	ProgressStore.record_answer("Other", 0, 0, "Why?", false, "C")
	check(not ProgressStore.missed_for("C").is_empty(), "(progress: the missed question marks C, and the sidebar's cache holds it)")
	check(ProgressStore.rename_note_keys("C", "D") == 2, "progress: one quiz key and one learn field move")
	check(ProgressStore._data.quizzes.has("d#0") and not ProgressStore._data.quizzes.has("c#0"), "progress: c#0 becomes d#0")
	check(ProgressStore._data.quizzes.has("c# tips#0") and ProgressStore._data.questions.has("c# tips#0#1"), "progress: C# Tips' keys are not C's")
	check(not ProgressStore.missed_for("D").is_empty() and ProgressStore.missed_for("C").is_empty(), "progress: a missed question about C now marks D for review")
	check(ProgressStore.rename_note_keys("Nothing", "Else") == 0, "progress: renaming a title nothing names changes nothing")
	ProgressStore.record_result("untitled", 0, 1, 1)
	check(ProgressStore.rename_note_keys("untitled", "E") == 0 and ProgressStore.rename_note_keys("D", " Untitled ") == 0, "progress: nothing moves from or to untitled")
	check(ProgressStore.quiz_passed("untitled", 0) and ProgressStore._data.quizzes.has("d#0") and not ProgressStore._data.quizzes.has("e#0"), "progress: …untitled#0 and d#0 are where they were")
	# A deleted note's title is free while it is in the trash, but its results
	# are still under it: a note renamed to it never writes over them
	ProgressStore.reset()
	ProgressStore.record_result("Physics", 0, 3, 3)
	ProgressStore.record_answer("Physics", 0, 0, "Mass?", true, "Physics")
	ProgressStore.record_result("Draft", 0, 0, 3)
	ProgressStore.record_answer("Draft", 0, 0, "Draft?", false, "Draft")
	ProgressStore.record_answer("Draft", 0, 1, "More?", false, "Draft")
	check(ProgressStore.rename_note_keys("Draft", "Physics") == 9, "progress: renaming onto another note's keys trades them (5 entries move, 4 learn / from fields follow)")
	var physics: Dictionary = ProgressStore._data.quizzes.get("physics#0", {})
	var draft: Dictionary = ProgressStore._data.quizzes.get("draft#0", {})
	check(int(physics.get("best", -1)) == 0 and not ProgressStore.quiz_passed("Physics", 0), "progress: the renamed note's own result takes the title (%s)" % str(physics))
	check(int(draft.get("best", -1)) == 3 and ProgressStore.quiz_passed("Draft", 0), "progress: …and the deleted note's 3/3 pass is kept, under the title the renamed note left (%s)" % str(draft))
	var answers: Array = ProgressStore._data.questions.keys()
	answers.sort()
	check(answers == ["draft#0#0", "physics#0#0", "physics#0#1"], "progress: …and so are its answers (%s)" % str(answers))
	check(str(ProgressStore._data.questions.get("draft#0#0", {}).get("q", "")) == "Mass?" and str(ProgressStore._data.questions.get("physics#0#1", {}).get("from", "")) == "Physics",
		"progress: …the deleted note's answer under the old title, the renamed note's under the new one")

	JourneyStore.reset()
	var t: Dictionary = JourneyStore.add_topic("Lang")
	var o: Dictionary = JourneyStore.add_objective(t.id, "Know C")
	for key in ["C#quiz0", "C#cards1", "C# Tips#quiz0", "c#quiz2"]:
		JourneyStore.add_demo(o.id, key)
	JourneyStore.log_score("C#cards1", 2, 2)
	check(JourneyStore.rename_note_keys("C", "D") == 3, "journey: two demos and one log entry move")
	var keys: Array = o.demos.map(func(d: Dictionary) -> String: return d.activity)
	check(keys == ["D#quiz0", "D#cards1", "C# Tips#quiz0", "c#quiz2"], "journey: exact title only, kind and index kept (%s)" % str(keys))
	check(o.log[0].activity == "D#cards1", "journey: the log entry's key moves")
	check(JourneyStore.rename_note_keys("D", "D") == 0, "journey: an unchanged title moves nothing")
	JourneyStore.add_demo(o.id, "untitled#quiz0")
	check(JourneyStore.rename_note_keys("untitled", "E") == 0 and JourneyStore.rename_note_keys("D", "Untitled") == 0, "journey: nothing moves from or to untitled")
	keys = o.demos.map(func(d: Dictionary) -> String: return d.activity)
	check(keys == ["D#quiz0", "D#cards1", "C# Tips#quiz0", "c#quiz2", "untitled#quiz0"], "journey: …every key is where it was (%s)" % str(keys))
	# A deleted note's title is free while it is in the trash, but its demos
	# and scores still name it: a note renamed to it never takes them over
	JourneyStore.reset()
	t = JourneyStore.add_topic("Science")
	var mass: Dictionary = JourneyStore.add_objective(t.id, "Mass")
	var drafting: Dictionary = JourneyStore.add_objective(t.id, "Drafting")
	JourneyStore.add_demo(mass.id, "Physics#quiz0")
	JourneyStore.add_demo(drafting.id, "Draft#quiz0")
	JourneyStore.add_demo(drafting.id, "Draft#cards0")
	JourneyStore.log_score("Physics#quiz0", 3, 3)
	check(JourneyStore.rename_note_keys("Draft", "Physics") == 4, "journey: renaming onto another note's keys trades them (2 + 2 entries)")
	var mass_keys: Array = mass.demos.map(func(d: Dictionary) -> String: return d.activity) + mass.log.map(func(e: Dictionary) -> String: return e.activity)
	var drafting_keys: Array = drafting.demos.map(func(d: Dictionary) -> String: return d.activity)
	check(mass_keys == ["Draft#quiz0", "Draft#quiz0"] and drafting_keys == ["Physics#quiz0", "Physics#cards0"],
		"journey: …the renamed note's demos take the title, the deleted note's take the one it left (%s, %s)" % [mass_keys, drafting_keys])
	check(JourneyStore.log_score("Physics#quiz0", 0, 3) == 1 and mass.log.size() == 1 and drafting.log.size() == 1, "journey: …so the renamed note's score logs to its own objective only")


# ── A linking note changed on disk: kept, reported, and the rewrites stop ───

func conflict_stops_the_rewrites() -> void:
	var root: ContentLayer = make_note("Root", "The root.")
	var first: ContentLayer = make_note("First", "See [[Root]].", "2030-01-02T00:00:00")
	var second: ContentLayer = make_note("Second", "Also [[Root]].", "2030-01-01T00:00:00")
	ProgressStore.record_result("Root", 0, 1, 1)
	check(VaultStore.rename_note(root, "Root 2") == "" and VaultStore.last_conflict_copy == null, "setup: Root is renamed to Root 2")
	# Another program edits First after the rename's rescan, while the cascade
	# runs: no rescan reads it in before First's save, so only the hash can
	# see it. (Edited before the rename, the rescan of its file rename reads it
	# in: the watcher compares sizes and a fresh file's bytes.)
	var path: String = first.resource_path
	var edited: String = FileAccess.get_file_as_string(path).replace("See [[Root]].", "Edited elsewhere: [[Root]].")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(edited)
	f.close()
	var outside: String = FileAccess.get_file_as_string(path)
	var report: Dictionary = RenameCascade.apply("Root", "Root 2", root)
	check(report.stopped and report.warnings.size() == 1 and report.warnings[0].note == first, "the conflict on First stops the cascade and is reported")
	check(FileAccess.get_file_as_string(path) == outside and first.raw_text.contains("Edited elsewhere: [[Root]]"), "First keeps the outside edit, byte for byte")
	var copies: Array = titled("First (conflict copy)")
	check(copies.size() == 1 and copies[0].raw_text == "See [[Root 2]].", "the rewritten First is its conflict copy")
	check(str(report.warnings[0].message).contains("First (conflict copy)"), "the warning names the copy (%s)" % report.warnings[0].message)
	check(second.raw_text == "Also [[Root]]." and not report.changed.has(second), "notes after it are not rewritten")
	check(report.progress == 1 and ProgressStore.quiz_passed("Root 2", 0), "the renamed note's progress moves all the same")
	check(RenameCascade.summary(report).contains("changed on disk"), "the status tail carries the warning (%s)" % RenameCascade.summary(report))
	VaultStore.last_conflict_copy = null


# ── A linking note that can't be saved: left as it was, and reported ───────

## A note linking to the renamed one sits in a read-only folder, so its
## save fails (save-safety). The cascade leaves it as it was, in memory and
## on disk, rather than holding the new links in memory alone where nothing
## retries them, and says why.
func unsaved_link_note_is_left() -> void:
	var target: ContentLayer = make_note("Target", "The target.")
	VaultStore.create_folder("Locked")
	var locked: ContentLayer = VaultStore.create_note("Locked Linker", "Locked")
	locked.raw_text = "See [[Target]]."
	VaultStore.save_note(locked)
	var path: String = locked.resource_path
	var before: String = FileAccess.get_sha256(path)
	OS.execute("chmod", ["555", path.get_base_dir()])
	var probe := FileAccess.open(path.get_base_dir().path_join("probe.tmp"), FileAccess.WRITE)
	if probe != null:   # root ignores permissions
		probe.close()
		DirAccess.remove_absolute(path.get_base_dir().path_join("probe.tmp"))
		OS.execute("chmod", ["755", path.get_base_dir()])
		print("SKIP  a linking note in a read-only folder: this user can write to it (root?)")
		return
	check(VaultStore.rename_note(target, "Target 2") == "", "setup: Target is renamed to Target 2")
	var report: Dictionary = RenameCascade.apply("Target", "Target 2", target)
	var unchanged: bool = FileAccess.get_sha256(path) == before
	OS.execute("chmod", ["755", path.get_base_dir()])   # first, so a failed check never leaves it read-only
	check(report.warnings.size() == 1 and report.warnings[0].note == locked and str(report.warnings[0].message).begins_with("couldn't save “Locked Linker”"),
		"the note that couldn't be saved is reported (%s)" % [report.warnings.map(func(w: Dictionary) -> String: return str(w.message))])
	check(not report.changed.has(locked) and report.links == 0, "…and not counted as rewritten")
	check(unchanged and locked.raw_text == "See [[Target]].", "…its file and its text in memory are as they were (%s)" % locked.raw_text)
	check(not VaultStore._unsaved_paths.has(path) and VaultStore.last_conflict_copy == null, "…with nothing left unsaved and no conflict copy")
	check(RenameCascade.summary(report).contains("couldn't save"), "the status tail says so (%s)" % RenameCascade.summary(report))


# ── mcp-title-change-cascade: update_note with a new title ──────────────────

func mcp_call(tools: RefCounted, name: String, args: Dictionary) -> Dictionary:
	return tools.call_tool(name, args).get("structuredContent", {})


func mcp_create(tools: RefCounted, title: String, markdown: String) -> String:
	return str(mcp_call(tools, "create_note", {"title": title, "markdown": markdown}).get("path", ""))


func mcp_hash(tools: RefCounted, rel: String) -> String:
	return str(mcp_call(tools, "read_note", {"path": rel}).get("hash", ""))


## Every note file's hash plus the progress and Journey files' bytes.
func vault_state(tools: RefCounted) -> Dictionary:
	var state: Dictionary = {}
	for rel in tools._scan("", []):
		state[rel] = FileAccess.get_sha256(V + rel)
	for f in [ProgressStore.path(), JourneyStore.path()]:
		state[f] = FileAccess.get_file_as_string(f)
	return state


func mcp_title_change() -> void:
	var tools: RefCounted = VaultTools.new(V)
	var alpha: String = mcp_create(tools, "Alpha", "Alpha text.\n\n```3d\npreset: quiz\nq: Q?\na*: Yes\na: No\n```\n")
	var beta: String = mcp_create(tools, "Beta", "Beta links [[Alpha]] and [[Alpha#Part|part]], not `[[Alpha]]`.\n")
	ProgressStore.record_result("Alpha", 0, 1, 1)
	JourneyStore.reset()
	var o: Dictionary = JourneyStore.add_objective(JourneyStore.add_topic("Greek").id, "Know Alpha")
	JourneyStore.add_demo(o.id, "Alpha#quiz0")
	var r: Dictionary = mcp_call(tools, "update_note", {"path": alpha, "hash": mcp_hash(tools, alpha), "title": "Alpha Prime"})
	check(r.get("path") == "note_alpha_prime.tres" and r.get("renamed_from") == alpha and FileAccess.file_exists(V + "note_alpha_prime.tres") and not FileAccess.file_exists(V + alpha),
		"MCP: renaming Alpha to Alpha Prime renames its file (%s)" % str(r.get("path", r)))
	check(r.get("hash") == FileAccess.get_sha256(V + "note_alpha_prime.tres"), "MCP: the result's hash is the renamed file's")
	var beta_text: String = str(mcp_call(tools, "read_note", {"path": beta}).get("markdown", ""))
	check(beta_text == "Beta links [[Alpha Prime]] and [[Alpha Prime#Part|part]], not `[[Alpha]]`.\n", "MCP: [[Alpha]] in Beta becomes [[Alpha Prime]], the code span stays (%s)" % beta_text.c_escape())
	check(r.get("changed") == [beta] and r.get("warnings") == [], "MCP: changed lists Beta, no warnings (%s, %s)" % [str(r.get("changed")), str(r.get("warnings"))])
	check(ProgressStore.quiz_passed("Alpha Prime", 0) and not ProgressStore._data.quizzes.has("alpha#0"), "MCP: Alpha's progress entry moves to Alpha Prime")
	check(not o.is_empty() and JourneyStore.find_objective(o.id).demos[0].activity == "Alpha Prime#quiz0", "MCP: the Journey demo key follows")
	# A title whose file name another note's file has gets the next free one
	var golf: String = mcp_create(tools, "Golf", "")
	var g: Dictionary = mcp_call(tools, "update_note", {"path": golf, "hash": mcp_hash(tools, golf), "title": "Beta?"})
	check(g.get("path") == "note_beta_1.tres" and FileAccess.file_exists(V + beta), "MCP: a new title whose file name is taken gets _1, like the app (%s)" % str(g.get("path", g)))


func mcp_title_taken() -> void:
	var tools: RefCounted = VaultTools.new(V)
	var target: String = "note_alpha_prime.tres"
	var before: Dictionary = vault_state(tools)
	var r: Dictionary = tools.call_tool("update_note", {"path": target, "hash": mcp_hash(tools, target), "title": " beta ", "markdown": "lost"})
	check(r.get("isError", false) and str(r.structuredContent.error.code) == "exists" and r.structuredContent.error.get("path") == "note_beta.tres",
		"MCP: renaming to a title another note has (any case) returns exists, naming its path")
	check(vault_state(tools) == before, "MCP: …and writes nothing: every note, progress and the Journey are byte-identical")


func mcp_note_changed_mid_cascade() -> void:
	var tools: RefCounted = VaultTools.new(V)
	var delta: String = mcp_create(tools, "Delta", "Delta.")
	var echo: String = mcp_create(tools, "Echo", "Echo links [[Delta]].")
	var fox: String = mcp_create(tools, "Foxtrot", "Foxtrot links [[Delta]].")
	var edited: Array = []
	# Someone edits Echo right after the renamed note is written, before the
	# cascade reaches it.
	tools.on_change = func(action: String, _rel: String) -> void:
		if action != "rename" or not edited.is_empty():
			return
		var e: ContentLayer = ResourceLoader.load(V + echo, "", ResourceLoader.CACHE_MODE_IGNORE)
		e.raw_text = "Echo links [[Delta]], edited elsewhere."
		ResourceSaver.save(e, V + echo)
		edited.append(FileAccess.get_file_as_string(V + echo))
	var r: Dictionary = mcp_call(tools, "update_note", {"path": delta, "hash": mcp_hash(tools, delta), "title": "Delta Two"})
	tools.on_change = Callable()
	check(edited.size() == 1 and r.get("path") == "note_delta_two.tres", "MCP setup: Echo was edited while Delta became Delta Two")
	var warned: Array = r.get("warnings", []).filter(func(w: Dictionary) -> bool: return w.get("path") == echo)
	check(warned.size() == 1 and str(warned[0].message).contains("changed"), "MCP: the note changed mid-cascade is listed in warnings (%s)" % str(r.get("warnings")))
	check(not edited.is_empty() and FileAccess.get_file_as_string(V + echo) == edited[0], "MCP: …and left byte-identical")
	check(r.get("changed") == [fox] and str(mcp_call(tools, "read_note", {"path": fox}).get("markdown")) == "Foxtrot links [[Delta Two]].", "MCP: the other linking note is rewritten and listed in changed")


func mcp_untitled() -> void:
	var tools: RefCounted = VaultTools.new(V)
	var hotel: String = mcp_create(tools, "Hotel", "Hotel links [[Hotel]].\n\n" + QUIZ)
	var india: String = mcp_create(tools, "India", "India links [[Hotel]] and [[untitled]].")
	ProgressStore.record_result("Hotel", 0, 0, 1)
	ProgressStore.record_result("untitled", 0, 1, 1)
	var o: Dictionary = JourneyStore.add_objective(JourneyStore.add_topic("Hotels").id, "Know Hotel")
	JourneyStore.add_demo(o.id, "Hotel#quiz0")
	var stores: String = store_files()
	var r: Dictionary = mcp_call(tools, "update_note", {"path": hotel, "hash": mcp_hash(tools, hotel), "title": "Untitled"})
	var warned: Array = r.get("warnings", []).filter(func(w: Dictionary) -> bool: return str(w.message).contains("can't name an untitled note"))
	check(r.get("title") == "Untitled" and r.get("changed") == [] and warned.size() == 1, "MCP: renaming Hotel to Untitled rewrites no note and warns why (%s)" % str(r))
	check(str(mcp_call(tools, "read_note", {"path": india}).get("markdown")) == "India links [[Hotel]] and [[untitled]].", "MCP: …India's links are left as they are")
	check(str(mcp_call(tools, "read_note", {"path": r.get("path", "")}).get("markdown")).begins_with("Hotel links [[Hotel]]."), "MCP: …and so is the note's own link")
	check(store_files() == stores, "MCP: …progress and the Journey are unchanged (hotel#0 doesn't overwrite untitled#0)")
	var back: Dictionary = mcp_call(tools, "update_note", {"path": r.get("path", ""), "hash": mcp_hash(tools, r.get("path", "")), "title": "Hotel"})
	check(back.get("title") == "Hotel" and back.get("changed") == [] and back.get("warnings") == [], "MCP: renaming it from untitled back to Hotel rewrites nothing (%s)" % str(back))
	check(store_files() == stores and str(mcp_call(tools, "read_note", {"path": india}).get("markdown")).contains("[[untitled]]"), "MCP: …moves no untitled keys and leaves [[untitled]] alone")


func mcp_backtick_title() -> void:
	var tools: RefCounted = VaultTools.new(V)
	var quebec: String = mcp_create(tools, "Quebec", "Quebec links [[Quebec]].\n\n```3d\npreset: quiz\nq: Q?\na*: Yes\na: No\nlearn: Quebec\n```\n")
	var romeo: String = mcp_create(tools, "Romeo", "Romeo links [[Quebec]].\n\n```3d\npreset: quiz\nq: Q?\na*: Yes\na: No\nnext: Quebec\n```\n")
	var r: Dictionary = mcp_call(tools, "update_note", {"path": quebec, "hash": mcp_hash(tools, quebec), "title": "Quebec `q`"})
	check(r.get("title") == "Quebec `q`" and r.get("changed") == [romeo], "MCP: renaming Quebec to Quebec `q` rewrites Romeo (%s)" % str(r))
	var romeo_text: String = str(mcp_call(tools, "read_note", {"path": romeo}).get("markdown", ""))
	check(romeo_text == "Romeo links [[Quebec]].\n\n```3d\npreset: quiz\nq: Q?\na*: Yes\na: No\nnext: Quebec `q`\n```\n", "MCP: …its next: line follows and its [[link]] stays (%s)" % romeo_text.c_escape())
	var own: String = str(mcp_call(tools, "read_note", {"path": r.get("path", "")}).get("markdown", ""))
	check(own.begins_with("Quebec links [[Quebec]].") and own.contains("learn: Quebec `q`\n"), "MCP: the note's own quiz line follows, its own [[link]] stays (%s)" % own.c_escape())
	var warned: Array = r.get("warnings", []).filter(func(w: Dictionary) -> bool: return str(w.message).contains("[[links]] to “Quebec” were left"))
	check(warned.size() == 1, "MCP: …and the warnings say the [[links]] were left (%s)" % str(r.get("warnings")))


## A rename that changes only the case ("Juliet" to "JULIET"): the note's own
## [[Juliet#Top]] still resolves to it after its save, so the cascade came
## back to it and, its hash no longer the scanned one, warned that it
## "changed while the rename ran" though nothing else had touched it.
func mcp_case_only_rename() -> void:
	var tools: RefCounted = VaultTools.new(V)
	var juliet: String = mcp_create(tools, "Juliet", "See [[Juliet#Top]] and [[Oscar]].")
	var oscar: String = mcp_create(tools, "Oscar", "Link to [[juliet]].")
	var r: Dictionary = mcp_call(tools, "update_note", {"path": juliet, "hash": mcp_hash(tools, juliet), "title": "JULIET"})
	var warned: Array = r.get("warnings", []).filter(func(w: Dictionary) -> bool: return str(w.get("message")).contains("changed while the rename ran"))
	check(r.get("path") == juliet and r.get("title") == "JULIET" and r.get("changed") == [oscar] and warned.is_empty(),
		"MCP: a case-only rename (Juliet to JULIET) rewrites Oscar and warns of no change mid-rename (%s)" % str(r))
	check(str(mcp_call(tools, "read_note", {"path": juliet}).get("markdown")) == "See [[JULIET#Top]] and [[Oscar]]." and str(mcp_call(tools, "read_note", {"path": oscar}).get("markdown")) == "Link to [[JULIET]].",
		"MCP: …and both notes link to JULIET")


# ── An MCP rename while the app is open ─────────────────────────────────────
# The server runs in its own process (as Claude runs it beside the app), so
# the progress and Journey keys it moves land in the files, not in the app's
# stores.

var _server: Dictionary = {}
var _server_out := PackedByteArray()
var _server_id: int = 0


func server_request(method: String, params: Dictionary) -> Dictionary:
	_server_id += 1
	var io: FileAccess = _server.stdio
	io.store_string(JSON.stringify({"jsonrpc": "2.0", "id": _server_id, "method": method, "params": params}) + "\n")
	io.flush()
	var deadline: int = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		var nl: int = _server_out.find(10)
		if nl >= 0:
			var v: Variant = JSON.parse_string(_server_out.slice(0, nl).get_string_from_utf8())
			_server_out = _server_out.slice(nl + 1)
			if v is Dictionary and int(v.get("id", -1)) == _server_id:
				return v
			continue
		var chunk: PackedByteArray = io.get_buffer(65536)
		if chunk.is_empty():
			await create_timer(0.05).timeout
		else:
			_server_out.append_array(chunk)
	return {}


func server_rename(rel: String, title: String) -> Dictionary:
	var r: Dictionary = await server_request("tools/call", {"name": "update_note", "arguments": {"path": rel, "hash": FileAccess.get_sha256(V + rel), "title": title}})
	return r.get("result", {}).get("structuredContent", {})


func file_json(path: String) -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Dictionary else {}


func mcp_rename_while_the_app_is_open() -> void:
	# The app and the server share this throwaway vault's own .ontomeme files.
	var overrides: Array = [ProgressStore.file_override, JourneyStore.file_override]
	ProgressStore.file_override = ""
	JourneyStore.file_override = ""
	ProgressStore.reset()
	JourneyStore.reset()
	var kilo: ContentLayer = make_note("Kilo", "Kilo.\n\n" + QUIZ)
	ProgressStore.record_result("Kilo", 0, 1, 1)
	var o: Dictionary = JourneyStore.add_objective(JourneyStore.add_topic("Phonetic").id, "Know Kilo")
	JourneyStore.add_demo(o.id, "Kilo#quiz0")
	app._refresh_note_list()
	app._last_sig = VaultStore.disk_signature()
	check(ProgressStore.path() == V + ".ontomeme/progress.json" and ProgressStore.status("Kilo") == "done", "setup: the app has Kilo's passed quiz in memory (%s)" % ProgressStore.path())

	var args: PackedStringArray = ["--headless", "--no-header", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://mcp/stdio_server.gd", "--", "--vault=" + ProjectSettings.globalize_path(V)]
	_server = OS.execute_with_pipe(OS.get_executable_path(), args, false)
	var init: Dictionary = {} if _server.is_empty() else await server_request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "rename-test", "version": "1"}})
	check(init.has("result"), "the MCP server runs in its own process")
	if init.has("result"):
		(_server.stdio as FileAccess).store_string(JSON.stringify({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")

		# The app writes before its disk poll ran: it takes the server's moves first
		var r: Dictionary = await server_rename(kilo.resource_path.get_file(), "Lima")
		check(r.get("path") == "note_lima.tres" and file_json(ProgressStore.path()).get("quizzes", {}).has("lima#0"), "the server renames Kilo to Lima and moves kilo#0 to lima#0 in progress.json (%s)" % str(r))
		ProgressStore.record_result("Other", 0, 1, 1)
		var keys: Array = file_json(ProgressStore.path()).get("quizzes", {}).keys()
		keys.sort()
		check(keys == ["lima#0", "other#0"], "the app's next progress write keeps lima#0 and puts back no kilo#0 (%s)" % str(keys))
		check(JourneyStore.log_score("Lima#quiz0", 1, 1) == 1, "the app logs a score for Lima#quiz0: it reads the Journey the server rewrote")
		var saved: Dictionary = {}
		for t in file_json(JourneyStore.path()).get("topics", []):
			for ob in t.get("objectives", []):
				if ob.get("id") == o.id:
					saved = ob
		check(not saved.is_empty() and saved.demos[0].activity == "Lima#quiz0" and saved.log.size() == 1 and saved.log[0].activity == "Lima#quiz0", "…and journey.json keeps the server's Lima#quiz0 with that log entry (%s)" % str(saved.get("demos")))
		app.check_disk_changes()
		var i: int = VaultStore.get_note_index("Lima")
		check(i >= 0 and ProgressStore.status("Lima") == "done" and app._note_buttons.get(VaultStore.note_list[i]).icon == ProgressStore.icon("done"), "the sidebar shows Lima done")

		# Nothing written by the app in between: its poll reads the files again
		r = await server_rename("note_lima.tres", "Mike")
		check(r.get("path") == "note_mike.tres", "the server renames Lima to Mike (%s)" % str(r))
		app.check_disk_changes()
		i = VaultStore.get_note_index("Mike")
		check(i >= 0 and ProgressStore.status("Mike") == "done" and app._note_buttons.get(VaultStore.note_list[i]).icon == ProgressStore.icon("done"), "the app's poll shows Mike done")
		check(JourneyStore.find_objective(o.id).get("demos", [{}])[0].get("activity") == "Mike#quiz0", "…and its Journey has the demo as Mike#quiz0")

	if not _server.is_empty():
		(_server.stdio as FileAccess).close()
		var deadline: int = Time.get_ticks_msec() + 5000
		while OS.is_process_running(_server.pid) and Time.get_ticks_msec() < deadline:
			await create_timer(0.05).timeout
		if OS.is_process_running(_server.pid):
			OS.kill(_server.pid)
		if _server.stderr is FileAccess:
			(_server.stderr as FileAccess).close()
	ProgressStore.file_override = overrides[0]
	JourneyStore.file_override = overrides[1]
