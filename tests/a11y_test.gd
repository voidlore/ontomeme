extends SceneTree
## Accessibility: every button whose visible text says nothing (an icon, "+",
## "×", one character) has an accessibility_name for screen readers, sidebar
## rows are named after their note / folder, and rows other code adds later
## are named automatically.
##   headless:  godot --headless --path . -s res://tests/a11y_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const UiScale = preload("res://ui_scale.gd")
const NOTE: String = "Tutorial 1: Writing Notes"

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## Every BaseButton under `node`, internal children included, skipping
## FileDialog internals (the engine's own dialog, not the app's).
func buttons(node: Node, out: Array[BaseButton] = []) -> Array[BaseButton]:
	if node is FileDialog:
		return out
	if node is BaseButton:
		out.append(node)
	for c in node.get_children(true):
		buttons(c, out)
	return out


## Buttons showing at most one character that have no accessible name.
func unnamed(app: Node) -> Array[String]:
	var bad: Array[String] = []
	for b in buttons(app):
		var text: String = str(b.get("text")) if b.get("text") != null else ""
		if text.strip_edges().length() <= 1 and b.accessibility_name.strip_edges() == "":
			bad.append("%s ('%s')" % [app.get_path_to(b), text])
	return bad


func check_all_named(app: Node, where: String) -> void:
	var bad: Array[String] = unnamed(app)
	check(bad.is_empty(), "%s: every icon / one-character button has an accessibility_name %s" % [where, bad])


func _init() -> void:
	UiScale.file_override = "user://test_display_a11y.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UiScale.file_override))
	UiScale._loaded = false
	JourneyStore.file_override = "user://test_journey_a11y.json"
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_a11y.json"
	ProgressStore.reset()
	TestVault.open("a11y")
	var note: ContentLayer = VaultStore.note_list[VaultStore.get_note_index(NOTE)]
	note.tags.append("basics")
	note.tags.append("x")
	VaultStore.save_note(note)
	var topic: Dictionary = JourneyStore.add_topic("Writing")
	var obj: Dictionary = JourneyStore.add_objective(topic.id, "Write and link notes")
	JourneyStore.add_demo(obj.id, JourneyStore.activity_key(NOTE, "quiz", 0))
	await frames(2)

	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(3)
	app.open_note_by_title(NOTE)
	await frames(3)

	# ── The main window, Edit view, a tagged note open, tag filter on ──
	app._set_tag_filter("basics")
	app._set_tag_filter("")
	app.get_node("%TagSidebarClear").visible = true
	await frames(2)
	check(app.tag_chips.get_child_count() == note.tags.size(), "the note shows its %d tag chips" % note.tags.size())
	check_all_named(app, "Edit view")
	for id in ["%PaletteButton", "%NewNoteButton", "%ThemeButton", "%TagSidebarClear"]:
		var b: BaseButton = app.get_node(id)
		check(b.accessibility_name != "", "%s is named '%s'" % [id, b.accessibility_name])
	var nf: BaseButton = app.find_child("NewFolderButton", true, false)
	check(nf != null and nf.accessibility_name == "New folder", "the New folder button is named (%s)" % (nf.accessibility_name if nf else "missing"))
	# A chip is a pill of two buttons (the tags lane): its body filters by the
	# tag, its × removes the tag. Each says what pressing it does.
	for chip in app.tag_chips.get_children():
		var tag: String = str(chip.get_meta(&"tag", ""))
		var body: Button = chip.find_child("Body", true, false)
		var remove: Button = chip.find_child("Remove", true, false)
		check(body != null and body.accessibility_name.contains("#" + tag), "tag chip '#%s' body says what pressing it does: '%s'" % [tag, body.accessibility_name if body else "missing"])
		check(remove != null and remove.accessibility_name.begins_with("Remove tag") and remove.accessibility_name.contains("#" + tag), "tag chip '#%s' × says what pressing it does: '%s'" % [tag, remove.accessibility_name if remove else "missing"])

	# ── Sidebar rows ──
	check(app._note_buttons.size() > 5, "the sidebar lists the vault's notes (%d)" % app._note_buttons.size())
	var bad_rows: Array[String] = []
	for n in app._note_buttons:
		var row: Button = app._note_buttons[n]
		if not row.accessibility_name.contains(app._display_title(n)):
			bad_rows.append("%s -> '%s'" % [n.title, row.accessibility_name])
	check(bad_rows.is_empty(), "every sidebar note row's accessibility_name contains its title %s" % [bad_rows])
	check(not app._folder_buttons.is_empty(), "the sidebar shows folders")
	for rel in app._folder_buttons:
		var fb: Button = app._folder_buttons[rel]
		var ok: bool = fb.accessibility_name.contains(str(rel).get_file()) and fb.accessibility_name.contains("note")
		check(ok, "folder row '%s' is named with its count: '%s'" % [rel, fb.accessibility_name])
		break
	for i in range(ProgressStore.quiz_count(note.raw_text)):
		ProgressStore.record_result(NOTE, i, 1, 1)
	app.on_progress_changed()
	var done_row: Button = app._note_buttons[note]
	check(done_row.accessibility_name.contains(NOTE) and done_row.accessibility_name.contains("complete"), "a finished note's row says so: '%s'" % done_row.accessibility_name)

	# ── A row that other code adds later is named automatically ──
	var later := Button.new()
	later.icon = Icons.get_icon("plus")
	later.tooltip_text = "Pin this note\nKeeps it at the top of the list"
	app.note_list_container.add_child(later)
	var later_x := Button.new()
	later_x.text = "×"
	later_x.tooltip_text = "Dismiss"
	app.note_list_container.add_child(later_x)
	await frames(2)
	check(later.accessibility_name == "Pin this note" and later.accessibility_description == "Keeps it at the top of the list", "a button added later takes its name from its tooltip ('%s' / '%s')" % [later.accessibility_name, later.accessibility_description])
	check(later_x.accessibility_name == "Dismiss", "…a one-character button too ('%s')" % later_x.accessibility_name)
	later.queue_free()
	later_x.queue_free()
	await frames(1)

	# ── Read view with a 3D card ──
	app._switch_layer("visual")
	await frames(4)
	var cards: int = 0
	for c in app.visual_layer.get_children():
		if c is NoteScene3D:
			cards += 1
	check(cards > 0, "Read view shows a 3D card (%d)" % cards)
	check_all_named(app, "Read view")

	# ── Journey: an objective with a demonstration (icon-only Remove) ──
	app._switch_layer("journey")
	app.journey_panel.select("objective", obj.id)
	await frames(3)
	var rm_named: bool = false
	for b in buttons(app.journey_panel):
		if b is Button and (b as Button).text == "" and (b as Button).icon != null:
			rm_named = b.accessibility_name.contains("Remove")
	check(rm_named, "the Journey's icon-only Remove button is named")
	check_all_named(app, "Journey")

	app.queue_free()
	await frames(2)
	for p in [UiScale.file_override, JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	UiScale.file_override = ""
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
