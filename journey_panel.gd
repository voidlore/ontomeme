class_name JourneyPanel
extends HSplitContainer
## The Learning Journey tab: topics and their learning objectives on the
## left (a Tree), the selected one's editor on the right.
##
## Objective editor: name, description, competency goal (Fluent / Learning /
## Forget), demonstrations (a quiz or flashcard deck + how its score is
## logged, with Launch), and the history of logged scores with a trend chart.

var app: Node
var tree: Tree
var _editor: VBoxContainer
var _editor_margin: MarginContainer
var _sel_type: String = ""   # "topic" | "objective" | ""
var _sel_id: String = ""
var _building: bool = false


func _init(owner_app: Node) -> void:
	app = owner_app
	name = "JourneyPanel"


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	# ── Left: topics & objectives ──
	var left := PanelContainer.new()
	left.theme_type_variation = &"SidebarPanel"
	left.custom_minimum_size = Vector2(180, 0)
	add_child(left)
	# The tree takes ~28% of the panel (180–280 px): roomy on a normal
	# window, still fitting the 820 px minimum window.
	resized.connect(func() -> void:
		var want: float = clampf(size.x * 0.28, 180.0, 280.0)
		if absf(left.custom_minimum_size.x - want) > 1.0:
			left.custom_minimum_size.x = want)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 10)
	left.add_child(lv)
	var head := HBoxContainer.new()
	lv.add_child(head)
	var title := Label.new()
	title.text = "LEARNING JOURNEY"
	title.theme_type_variation = &"SectionLabel"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(title)
	var add_topic := _flat_button("Topic", "New topic", Icons.get_icon("plus"))
	add_topic.name = "AddTopic"
	add_topic.pressed.connect(_on_add_topic)
	head.add_child(add_topic)

	tree = Tree.new()
	tree.name = "JourneyTree"
	tree.hide_root = true
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.select_mode = Tree.SELECT_ROW
	tree.add_theme_constant_override("item_margin", 14)
	tree.add_theme_constant_override("v_separation", 6)
	tree.add_theme_constant_override("draw_relationship_lines", 0)
	tree.add_theme_constant_override("draw_guides", 0)
	tree.item_selected.connect(_on_tree_selected)
	lv.add_child(tree)

	var hint := Label.new()
	hint.text = "Topics hold learning objectives. Each objective lists ways to show you know it, and logs every score."
	hint.theme_type_variation = &"FaintLabel"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lv.add_child(hint)

	# ── Right: editor ──
	var scroll := ScrollContainer.new()
	scroll.name = "JourneyScroll"
	# AUTO, not DISABLED: at the minimum window size the editor scrolls
	# sideways instead of pushing the whole app wider than the window.
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	_editor_margin = MarginContainer.new()
	_editor_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_editor_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_editor_margin.add_theme_constant_override("margin_top", 28)
	_editor_margin.add_theme_constant_override("margin_bottom", 40)
	scroll.add_child(_editor_margin)
	_editor = VBoxContainer.new()
	_editor.name = "JourneyEditor"
	_editor.add_theme_constant_override("separation", 12)
	_editor_margin.add_child(_editor)
	scroll.resized.connect(func() -> void:
		var side: int = int(maxf(20.0, (scroll.size.x - 720.0) / 2.0))
		_editor_margin.add_theme_constant_override("margin_left", side)
		_editor_margin.add_theme_constant_override("margin_right", side))
	refresh()


# ── Public ──────────────────────────────────────────────────────────────────

func refresh() -> void:
	if tree == null:
		return
	if _sel_type == "topic" and JourneyStore.find_topic(_sel_id).is_empty():
		_sel_type = ""
	if _sel_type == "objective" and JourneyStore.find_objective(_sel_id).is_empty():
		_sel_type = ""
	if _sel_type == "" and not JourneyStore.topics().is_empty():
		var t: Dictionary = JourneyStore.topics()[0]
		_sel_type = "topic"
		_sel_id = t.id
	_rebuild_tree()
	_rebuild_editor()


func select(type: String, id: String) -> void:
	_sel_type = type
	_sel_id = id
	refresh()


# ── Tree ────────────────────────────────────────────────────────────────────

func _rebuild_tree() -> void:
	_building = true
	tree.clear()
	var root: TreeItem = tree.create_item()
	for t in JourneyStore.topics():
		var ti: TreeItem = tree.create_item(root)
		ti.set_text(0, str(t.name) if str(t.name) != "" else "Untitled topic")
		ti.set_metadata(0, {"type": "topic", "id": t.id})
		ti.set_icon(0, Icons.get_icon("folder"))
		ti.set_icon_modulate(0, _col("text_muted"))
		ti.set_custom_font_size(0, 14)
		if _sel_type == "topic" and _sel_id == t.id:
			ti.select(0)
		for o in t.objectives:
			var oi: TreeItem = tree.create_item(ti)
			oi.set_text(0, str(o.name) if str(o.name) != "" else "Untitled objective")
			oi.set_metadata(0, {"type": "objective", "id": o.id})
			var s: Dictionary = JourneyStore.summary(o)
			if o.goal == "forget":
				oi.set_custom_color(0, _col("text_faint"))
			elif s.met:
				oi.set_icon(0, ProgressStore.icon("done"))
			elif s.attempts > 0:
				oi.set_icon(0, ProgressStore.icon("review"))
			oi.set_tooltip_text(0, "%s  ·  goal: %s" % [o.name, JourneyStore.GOAL_NAMES.get(o.goal, o.goal)])
			if _sel_type == "objective" and _sel_id == o.id:
				oi.select(0)
	_building = false


func _on_tree_selected() -> void:
	if _building:
		return
	var it: TreeItem = tree.get_selected()
	if it == null:
		return
	var m: Dictionary = it.get_metadata(0)
	_sel_type = m.type
	_sel_id = m.id
	_rebuild_editor()


func _update_selected_text(text: String) -> void:
	var it: TreeItem = tree.get_selected()
	if it != null:
		it.set_text(0, text)


# ── Editor ──────────────────────────────────────────────────────────────────

func _clear_editor() -> void:
	for c in _editor.get_children():
		_editor.remove_child(c)
		c.queue_free()


func _rebuild_editor() -> void:
	_clear_editor()
	if _sel_type == "objective":
		_build_objective_editor(JourneyStore.find_objective(_sel_id))
	elif _sel_type == "topic":
		_build_topic_editor(JourneyStore.find_topic(_sel_id))
	else:
		_build_empty()


func _build_empty() -> void:
	_editor.add_child(_spacer(60))
	var h := Label.new()
	h.text = "Your learning journey"
	h.theme_type_variation = &"H1Label"
	_editor.add_child(h)
	_editor.add_child(_body("Start with a topic — something you want to learn, like “Colour theory” or “Godot basics”. Inside it, write learning objectives: the specific things you want to be able to do. Then attach quizzes or flashcards from your notes as ways to prove it. Every time you finish one, the score is logged here."))
	var b := _accent_button("Create your first topic")
	b.name = "CreateFirstTopic"
	b.pressed.connect(_on_add_topic)
	var row := HBoxContainer.new()
	row.add_child(b)
	_editor.add_child(row)


func _build_topic_editor(t: Dictionary) -> void:
	_editor.add_child(_faint("TOPIC"))
	var name_edit := _title_edit(t.name, "Topic name")
	name_edit.name = "TopicName"
	name_edit.text_changed.connect(func(v: String) -> void:
		t.name = v
		JourneyStore.save()
		_update_selected_text(v if v != "" else "Untitled topic"))
	_editor.add_child(name_edit)
	var desc := _desc_edit(t.description, "What is this topic about? Why do you want to learn it?")
	desc.text_changed.connect(func() -> void:
		t.description = desc.text
		JourneyStore.save())
	_editor.add_child(desc)

	_editor.add_child(_spacer(6))
	_editor.add_child(_section("Learning objectives"))
	if t.objectives.is_empty():
		_editor.add_child(_body("No objectives yet. A good objective starts with a verb: “Name the three primary colours”, “Build a 3D scene with shapes”."))
	for o in t.objectives:
		var s: Dictionary = JourneyStore.summary(o)
		var b := Button.new()
		b.theme_type_variation = &"NoteItem"
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.clip_text = true
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.text = "%s      %s  ·  %s" % [o.name if str(o.name) != "" else "Untitled objective", JourneyStore.GOAL_NAMES.get(o.goal, o.goal), _status_text(o, s)]
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		if s.met and o.goal != "forget":
			b.icon = ProgressStore.icon("done")
		b.pressed.connect(select.bind("objective", o.id))
		_editor.add_child(b)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var add := _accent_button("Add objective")
	add.name = "AddObjective"
	add.pressed.connect(_on_add_objective.bind(t.id))
	row.add_child(add)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var del := Button.new()
	del.theme_type_variation = &"DangerButton"
	del.text = "Delete topic"
	del.pressed.connect(_confirm.bind("Delete the topic “%s” and its %d objectives (with their history)?" % [t.name, t.objectives.size()], func() -> void:
		JourneyStore.remove_topic(t.id)
		_sel_type = ""
		refresh()))
	row.add_child(del)
	_editor.add_child(_spacer(4))
	_editor.add_child(row)


func _build_objective_editor(o: Dictionary) -> void:
	var t: Dictionary = JourneyStore.topic_of(o.id)
	var crumb := LinkButton.new()
	crumb.text = (str(t.get("name", "")) if str(t.get("name", "")) != "" else "Untitled topic") + "  ›  OBJECTIVE"
	crumb.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	crumb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	crumb.add_theme_color_override("font_color", _col("text_faint"))
	crumb.add_theme_font_size_override("font_size", 12)
	crumb.pressed.connect(select.bind("topic", t.get("id", "")))
	_editor.add_child(crumb)

	var name_edit := _title_edit(o.name, "What do you want to be able to do?")
	name_edit.name = "ObjectiveName"
	name_edit.text_changed.connect(func(v: String) -> void:
		o.name = v
		JourneyStore.save()
		_update_selected_text(v if v != "" else "Untitled objective"))
	_editor.add_child(name_edit)
	var desc := _desc_edit(o.description, "Describe it: what does knowing this look like?")
	desc.name = "ObjectiveDescription"
	desc.text_changed.connect(func() -> void:
		o.description = desc.text
		JourneyStore.save())
	_editor.add_child(desc)

	# Competency goal
	var goal_row := HBoxContainer.new()
	goal_row.add_theme_constant_override("separation", 12)
	var gl := Label.new()
	gl.text = "Competency goal"
	gl.theme_type_variation = &"MutedLabel"
	goal_row.add_child(gl)
	var goal := OptionButton.new()
	goal.name = "GoalOption"
	goal.fit_to_longest_item = false
	for g in JourneyStore.GOALS:
		goal.add_item(JourneyStore.GOAL_NAMES[g])
	goal.selected = maxi(JourneyStore.GOALS.find(o.goal), 0)
	goal_row.add_child(goal)
	_editor.add_child(goal_row)
	var goal_help := Label.new()
	goal_help.text = JourneyStore.GOAL_HELP.get(o.goal, "")
	goal_help.theme_type_variation = &"FaintLabel"
	goal_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_editor.add_child(goal_help)
	goal.item_selected.connect(func(i: int) -> void:
		o.goal = JourneyStore.GOALS[i]
		JourneyStore.save()
		refresh())

	# Status card
	var s: Dictionary = JourneyStore.summary(o)
	var card := PanelContainer.new()
	card.theme_type_variation = &"CardPanel"
	var status := RichTextLabel.new()
	status.name = "ObjectiveStatus"
	status.bbcode_enabled = true
	status.fit_content = true
	status.scroll_active = false
	var dot: String = "[color=#3ddc84]✓[/color]" if s.met else ("[color=#f0a040]●[/color]" if s.attempts > 0 else "[color=#6c6c76]○[/color]")
	if o.goal == "forget":
		dot = "[color=#6c6c76]○[/color]"
	status.text = "%s  [b]%s[/b]      [color=#8a8a96]%d attempt%s%s[/color]" % [
		dot, _status_text(o, s), s.attempts, "" if s.attempts == 1 else "s",
		("  ·  best %d%%" % int(round(s.best * 100.0))) if s.best >= 0.0 else ""]
	card.add_child(status)
	_editor.add_child(card)

	# Demonstrations
	_editor.add_child(_spacer(6))
	_editor.add_child(_section("Demonstrations"))
	_editor.add_child(_faint_wrap("Ways to show you know this. Launch one; when it finishes, the score it reports is logged below with the date."))
	var demos_box := VBoxContainer.new()
	demos_box.name = "Demos"
	demos_box.add_theme_constant_override("separation", 6)
	_editor.add_child(demos_box)
	for d in o.demos:
		demos_box.add_child(_demo_row(o, d, s.latest.get(d.activity, {})))
	if o.demos.is_empty():
		demos_box.add_child(_body("None yet — add a quiz or flashcard deck from your notes."))
	var add_demo := MenuButton.new()
	add_demo.name = "AddDemo"
	add_demo.text = "  Add demonstration"
	add_demo.icon = Icons.get_icon("plus")
	add_demo.flat = false
	add_demo.theme_type_variation = &"FlatButton"
	add_demo.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var popup: PopupMenu = add_demo.get_popup()
	var used: Array = o.demos.map(func(d): return d.activity)
	var acts: Array[Dictionary] = JourneyStore.activities()
	var keys: Array[String] = []
	for a in acts:
		if a.key in used:
			continue
		popup.add_item("%s   ·   %s  ›  %s" % [JourneyStore.KIND_NAMES[a.kind], a.note, a.caption])
		keys.append(a.key)
	if keys.is_empty():
		popup.add_item("No more quizzes or flashcards in this vault")
		popup.set_item_disabled(0, true)
	popup.id_pressed.connect(func(i: int) -> void:
		if i < keys.size():
			JourneyStore.add_demo(o.id, keys[i], "percent")
			refresh())
	var add_row := HBoxContainer.new()
	add_row.add_child(add_demo)
	_editor.add_child(add_row)

	# History
	_editor.add_child(_spacer(6))
	_editor.add_child(_section("History"))
	if o.log.is_empty():
		_editor.add_child(_body("Nothing logged yet. Launch a demonstration above."))
	else:
		var chart := TrendChart.new()
		chart.entries = o.log
		chart.goal = 0.9 if o.goal == "fluent" else (ProgressStore.PASS_RATIO if o.goal == "learning" else -1.0)
		chart.accent = _col("accent")
		chart.grid = _col("border")
		chart.text_color = _col("text_faint")
		_editor.add_child(chart)
		var hist := VBoxContainer.new()
		hist.name = "History"
		hist.add_theme_constant_override("separation", 2)
		_editor.add_child(hist)
		var shown: int = 0
		for i in range(o.log.size() - 1, -1, -1):
			var e: Dictionary = o.log[i]
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 14)
			var date := Label.new()
			date.text = str(e.date).replace("T", "  ").substr(0, 17)
			date.theme_type_variation = &"FaintLabel"
			date.custom_minimum_size = Vector2(130, 0)
			row.add_child(date)
			var what := Label.new()
			what.text = JourneyStore.activity_label(e.activity)
			what.theme_type_variation = &"MutedLabel"
			what.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			what.clip_text = true
			what.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			row.add_child(what)
			var val := Label.new()
			val.text = JourneyStore.format_value(e)
			val.add_theme_color_override("font_color", Color("3ddc84") if JourneyStore.normalized(e) >= ProgressStore.PASS_RATIO - 0.0001 else Color("f0a040"))
			row.add_child(val)
			hist.add_child(row)
			shown += 1
			if shown >= 25:
				break

	_editor.add_child(_spacer(10))
	var foot := HBoxContainer.new()
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(sp)
	var del := Button.new()
	del.theme_type_variation = &"DangerButton"
	del.text = "Delete objective"
	del.pressed.connect(_confirm.bind("Delete the objective “%s” and its history?" % o.name, func() -> void:
		var tid: String = JourneyStore.topic_of(o.id).get("id", "")
		JourneyStore.remove_objective(o.id)
		select("topic", tid)))
	foot.add_child(del)
	_editor.add_child(foot)


func _demo_row(o: Dictionary, d: Dictionary, latest: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"CardPanel"
	var lines := VBoxContainer.new()
	lines.add_theme_constant_override("separation", 8)
	panel.add_child(lines)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	lines.add_child(row)
	var k: Dictionary = JourneyStore.parse_key(d.activity)
	var badge := Label.new()
	badge.text = JourneyStore.KIND_NAMES.get(k.get("kind", ""), "Activity").to_upper()
	badge.theme_type_variation = &"AccentLabel"
	badge.add_theme_font_size_override("font_size", 11)
	row.add_child(badge)
	var link := LinkButton.new()
	link.text = JourneyStore.activity_label(d.activity)
	link.tooltip_text = "Open the note"
	link.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
	link.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	link.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	link.custom_minimum_size = Vector2(60, 0)
	link.add_theme_color_override("font_color", _col("text"))
	link.pressed.connect(func() -> void: app.open_note_by_title(str(k.get("note", ""))))
	row.add_child(link)
	var last := Label.new()
	last.text = ("Latest: " + JourneyStore.format_value(latest)) if not latest.is_empty() else "Not tried yet"
	last.theme_type_variation = &"MutedLabel"
	row.add_child(last)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	lines.add_child(row2)
	var out := OptionButton.new()
	out.name = "ScoreOutput"
	out.tooltip_text = "Score output: what gets logged when this finishes"
	out.fit_to_longest_item = false
	for key in JourneyStore.OUTPUTS:
		out.add_item(JourneyStore.OUTPUT_NAMES[key])
	out.selected = maxi(JourneyStore.OUTPUTS.find(d.output), 0)
	out.item_selected.connect(func(i: int) -> void:
		d.output = JourneyStore.OUTPUTS[i]
		JourneyStore.save())
	row2.add_child(out)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(sp)
	var rm := _flat_button("", "Remove this demonstration (history stays)", Icons.get_icon("close", 14))
	rm.pressed.connect(func() -> void:
		JourneyStore.remove_demo(o.id, d.id)
		refresh())
	row2.add_child(rm)
	var launch := _accent_button("Launch")
	launch.name = "Launch"
	launch.icon = Icons.get_icon("play", 14)
	launch.pressed.connect(func() -> void: app.launch_activity(d.activity))
	row2.add_child(launch)
	return panel


func _status_text(o: Dictionary, s: Dictionary) -> String:
	if o.goal == "forget":
		return "Not tracking"
	if o.demos.is_empty():
		return "No demonstrations yet"
	if s.met:
		return "Fluent" if o.goal == "fluent" else "On track"
	if s.attempts == 0:
		return "Not started"
	return "Keep practising"


# ── Actions ─────────────────────────────────────────────────────────────────

func _on_add_topic() -> void:
	var t: Dictionary = JourneyStore.add_topic("New topic")
	select("topic", t.id)
	_focus_title()


func _on_add_objective(topic_id: String) -> void:
	var o: Dictionary = JourneyStore.add_objective(topic_id, "New objective")
	select("objective", o.id)
	_focus_title()


func _focus_title() -> void:
	await get_tree().process_frame
	for c in _editor.get_children():
		if c is LineEdit:
			c.grab_focus()
			c.select_all()
			return


func _confirm(message: String, on_ok: Callable) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = message
	dlg.ok_button_text = "Delete"
	add_child(dlg)
	dlg.confirmed.connect(on_ok)
	dlg.visibility_changed.connect(func() -> void:
		if not dlg.visible:
			dlg.queue_free())
	dlg.popup_centered()


# ── Widgets ─────────────────────────────────────────────────────────────────

func _col(key: String) -> Color:
	return app._palette_colors.get(key, Color.WHITE) if app != null else Color.WHITE


func _flat_button(text: String, tip: String, icon: Texture2D = null) -> Button:
	var b := Button.new()
	b.theme_type_variation = &"FlatButton"
	b.text = text
	b.tooltip_text = tip
	b.icon = icon
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return b


func _accent_button(text: String) -> Button:
	var b := Button.new()
	b.theme_type_variation = &"AccentButton"
	b.text = text
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return b


func _title_edit(text: String, placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.theme_type_variation = &"TitleEdit"
	e.text = text
	e.placeholder_text = placeholder
	return e


func _desc_edit(text: String, placeholder: String) -> TextEdit:
	var e := TextEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	e.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	e.scroll_fit_content_height = true
	e.custom_minimum_size = Vector2(0, 64)
	return e


func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = &"H3Label"
	return l


func _faint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = &"FaintLabel"
	return l


func _faint_wrap(text: String) -> Label:
	var l := _faint(text)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _body(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = &"BodyLabel"
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


## Scores over time (0..1), with the objective's goal as a dashed line.
class TrendChart extends Control:
	var entries: Array = []
	var goal: float = -1.0
	var accent: Color = Color("d97757")
	var grid: Color = Color(1, 1, 1, 0.1)
	var text_color: Color = Color("6c6c76")

	func _init() -> void:
		custom_minimum_size = Vector2(0, 130)
		name = "TrendChart"

	func _draw() -> void:
		var pad := Vector2(34, 10)
		var w: float = size.x - pad.x - 8.0
		var h: float = size.y - pad.y * 2.0
		var font: Font = get_theme_default_font()
		for v in [0.0, 0.5, 1.0]:
			var y: float = pad.y + h * (1.0 - v)
			draw_line(Vector2(pad.x, y), Vector2(pad.x + w, y), grid, 1.0)
			draw_string(font, Vector2(0, y + 4), "%d%%" % int(v * 100), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, text_color)
		if goal >= 0.0:
			var gy: float = pad.y + h * (1.0 - goal)
			draw_dashed_line(Vector2(pad.x, gy), Vector2(pad.x + w, gy), Color("3ddc84", 0.7), 1.0, 5.0)
			draw_string(font, Vector2(pad.x + 6, gy - 4), "goal", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color("3ddc84", 0.8))
		var n: int = entries.size()
		if n == 0:
			return
		var pts: PackedVector2Array = []
		for i in range(n):
			var x: float = pad.x + (w * 0.5 if n == 1 else w * i / float(n - 1))
			pts.append(Vector2(x, pad.y + h * (1.0 - clampf(JourneyStore.normalized(entries[i]), 0.0, 1.0))))
		if n > 1:
			draw_polyline(pts, accent, 2.0, true)
		for p in pts:
			draw_circle(p, 4.0, accent)
			draw_circle(p, 2.0, Color("15151a"))
