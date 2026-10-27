extends Control
## Main scene controller for Ontomeme — wires the UI to VaultStore and LayerEngine.
##
## Layout and look live in note.tscn + AppTheme; this script only holds
## behaviour. Nodes are reached through scene-unique names (%Name), so the
## tree can be rearranged in the editor without breaking any paths.

const READABLE_WIDTH: float = 760.0
const AUTO_SAVE_DELAY: float = 0.8
const MODE_NAMES: Dictionary = {"raw": "Edit", "structured": "Outline", "visual": "Read", "graph": "Graph", "journey": "Journey"}
const APP_NAME: String = "Ontomeme"
const WATCH_INTERVAL: float = 1.5

@onready var background: Panel = %Background
@onready var search_box: LineEdit = %SearchBox
@onready var note_list_container: VBoxContainer = %NoteList
@onready var note_count_label: Label = %NoteCount
@onready var new_note_btn: Button = %NewNoteButton
@onready var palette_btn: Button = %PaletteButton
@onready var import_btn: Button = %ImportButton
@onready var export_btn: Button = %ExportButton
@onready var theme_btn: Button = %ThemeButton
@onready var breadcrumb: Label = %Breadcrumb
@onready var delete_btn: Button = %DeleteButton
@onready var content_panel: PanelContainer = %ContentPanel
@onready var empty_state_panel: CenterContainer = %EmptyStatePanel
@onready var empty_new_btn: Button = %EmptyNewButton
@onready var note_content: MarginContainer = %NoteContent
@onready var title_edit: LineEdit = %TitleEdit
@onready var note_meta: Label = %NoteMeta
@onready var raw_text_layer: TextEdit = %RawTextLayer
@onready var doc_scroll: ScrollContainer = %DocScroll
@onready var structured_layer: VBoxContainer = %StructuredLayer
@onready var visual_layer: VBoxContainer = %VisualLayer
@onready var graph_layer: Control = %GraphLayer
@onready var status_label: Label = %StatusLabel
@onready var word_count_label: Label = %WordCount
@onready var mode_label: Label = %ModeLabel
@onready var import_dialog: FileDialog = %ImportFileDialog
@onready var layer_buttons: Dictionary = {
	"raw": %BtnRaw, "structured": %BtnStructured, "visual": %BtnVisual, "graph": %BtnGraph,
}

var _undo_engine: Node = null
var current_mode: String = "raw"
var current_note: ContentLayer = null
var _editing: bool = false
var _loading: bool = false
var _is_dark_mode: bool = true
var _palette_colors: Dictionary = {}
var _auto_save_timer: Timer = null
var _note_group: ButtonGroup = ButtonGroup.new()
var _layer_group: ButtonGroup = ButtonGroup.new()
var _visible_notes: Array[ContentLayer] = []

# Command palette
var _palette_overlay: ColorRect = null
var _palette_panel: PanelContainer = null
var _palette_search: LineEdit = null
var _palette_list: ItemList = null
var _palette_items: Array[Dictionary] = []
var _palette_selected_index: int = 0
var _palette_visible: bool = false
var _scene_overlay: ColorRect = null

# Folders, vaults, journey
var _note_buttons: Dictionary = {}     # ContentLayer -> Button
var _folder_buttons: Dictionary = {}   # rel path -> Button
var _collapsed: Dictionary = {}        # rel path -> true
var journey_panel: JourneyPanel = null
var _vault_btn: Button = null
var _vault_menu: PopupMenu = null
var _vault_dialog: FileDialog = null
var _ctx_menu: PopupMenu = null
var _move_menu: PopupMenu = null
var _ctx_target: Dictionary = {}       # {"type": "note"/"folder"/"root", ...}
var _move_targets: Array[String] = []
var _prompt: ConfirmationDialog = null
var _prompt_edit: LineEdit = null
var _prompt_cb: Callable
var _watch_timer: Timer = null
var _last_sig: String = ""


func _ready() -> void:
	_undo_engine = get_node_or_null("/root/UndoRedoEngine")
	get_window().min_size = Vector2i(820, 520)
	get_window().files_dropped.connect(_on_files_dropped)
	_apply_theme(_is_dark_mode)

	# Sidebar
	new_note_btn.pressed.connect(_on_new_note_pressed)
	empty_new_btn.pressed.connect(_on_new_note_pressed)
	palette_btn.pressed.connect(_open_palette)
	import_btn.pressed.connect(_on_import_vault_pressed)
	export_btn.pressed.connect(_on_export_vault_pressed)
	theme_btn.pressed.connect(_toggle_theme)
	search_box.text_changed.connect(_on_search_changed)
	search_box.text_submitted.connect(_on_search_submitted)

	# Toolbar: one ButtonGroup makes the toggles a segmented control.
	# The Journey tab is a copy of the Graph button.
	var jbtn: Button = (layer_buttons.graph as Button).duplicate()
	jbtn.name = "BtnJourney"
	jbtn.text = "Journey"
	jbtn.tooltip_text = "Learning Journey: topics, objectives, scores (Ctrl+5)"
	(layer_buttons.graph as Button).add_sibling(jbtn)
	layer_buttons["journey"] = jbtn
	for mode in layer_buttons:
		var btn: Button = layer_buttons[mode]
		btn.button_group = _layer_group
		btn.pressed.connect(_switch_layer.bind(mode))
	delete_btn.pressed.connect(_on_delete_note_pressed)

	# Document
	title_edit.text_submitted.connect(func(_t: String) -> void: raw_text_layer.grab_focus())
	title_edit.focus_exited.connect(_commit_title)
	title_edit.text_submitted.connect(func(_t: String) -> void: _commit_title())
	raw_text_layer.text_changed.connect(_on_raw_text_changed)
	graph_layer.node_clicked.connect(_on_graph_node_clicked)
	content_panel.resized.connect(_update_readable_width)

	import_dialog.dir_selected.connect(_on_import_dir_selected)

	_auto_save_timer = Timer.new()
	_auto_save_timer.one_shot = true
	_auto_save_timer.wait_time = AUTO_SAVE_DELAY
	_auto_save_timer.timeout.connect(_do_auto_save)
	add_child(_auto_save_timer)

	LayerEngine.set_node_refs(raw_text_layer, structured_layer, visual_layer)
	LayerEngine.set_mode("raw")

	_create_palette()
	_build_vault_ui()
	_build_journey()
	_load_collapsed()
	if VaultStore.note_list.is_empty():
		VaultStore.refresh_note_list()
	_refresh_note_list()
	_last_sig = VaultStore.disk_signature()
	_watch_timer = Timer.new()
	_watch_timer.wait_time = WATCH_INTERVAL
	_watch_timer.timeout.connect(check_disk_changes)
	add_child(_watch_timer)
	_watch_timer.start()
	if VaultStore.note_list.size() > 0:
		_open_note(VaultStore.note_list[0])
	else:
		_show_empty_state()
	_update_readable_width()
	_update_status("Ready  ·  Ctrl+P commands  ·  Ctrl+N new note")


# ── Layout ──────────────────────────────────────────────────────────────────

func _update_readable_width() -> void:
	# Center the document in a readable column (Obsidian's "readable line length")
	var side: int = int(max(40.0, (content_panel.size.x - READABLE_WIDTH) / 2.0))
	note_content.add_theme_constant_override("margin_left", side)
	note_content.add_theme_constant_override("margin_right", side)


func _show_empty_state() -> void:
	current_note = null
	breadcrumb.text = _vault_name()
	note_meta.text = ""
	word_count_label.text = ""
	delete_btn.disabled = true
	graph_layer.visible = current_mode == "graph"
	note_content.visible = false
	empty_state_panel.visible = current_mode not in ["graph", "journey"]


# ── Theme ───────────────────────────────────────────────────────────────────

func _apply_theme(is_dark: bool) -> void:
	theme = AppTheme.build(is_dark)
	_palette_colors = AppTheme.palette(is_dark)
	if theme_btn != null:
		theme_btn.text = "☾" if is_dark else "☀"
	if _palette_overlay != null:
		_palette_overlay.color = _palette_colors.dim
	if is_inside_tree() and current_mode in ["structured", "visual"]:
		LayerEngine.set_mode(current_mode)
	if graph_layer != null:
		graph_layer.dark_mode = is_dark
		graph_layer.queue_redraw()


func _toggle_theme() -> void:
	_is_dark_mode = not _is_dark_mode
	_apply_theme(_is_dark_mode)
	_update_status("Theme: " + ("dark" if _is_dark_mode else "light"))


# ── Note list ───────────────────────────────────────────────────────────────

func _refresh_note_list() -> void:
	"""Rebuild the sidebar: folders (real directories) with their notes, or a
	flat list of matches while searching."""
	for child in note_list_container.get_children():
		note_list_container.remove_child(child)
		child.queue_free()
	_visible_notes.clear()
	_note_buttons.clear()
	_folder_buttons.clear()
	var filter: String = search_box.text.strip_edges().to_lower()
	if filter != "":
		for note in VaultStore.note_list:
			if note.title.to_lower().contains(filter) or note.raw_text.to_lower().contains(filter):
				_add_note_row(note, 0)
	else:
		var by_folder: Dictionary = {}
		for note in VaultStore.note_list:
			var f: String = VaultStore.folder_of(note)
			if not by_folder.has(f):
				by_folder[f] = []
			by_folder[f].append(note)
		_add_folder_contents("", 0, by_folder)
	var total: int = VaultStore.note_list.size()
	note_count_label.text = str(total) if filter == "" else "%d / %d" % [_visible_notes.size(), total]


## Subfolders first (alphabetical), then the folder's notes (newest first).
func _add_folder_contents(rel: String, depth: int, by_folder: Dictionary) -> void:
	for f in VaultStore.folders:
		if f.get_base_dir() == rel:
			note_list_container.add_child(_make_folder_item(f, depth, _count_notes(f, by_folder)))
			if not _collapsed.has(f):
				_add_folder_contents(f, depth + 1, by_folder)
	for note in by_folder.get(rel, []):
		_add_note_row(note, depth)


func _count_notes(rel: String, by_folder: Dictionary) -> int:
	var n: int = 0
	for f in by_folder:
		if f == rel or str(f).begins_with(rel + "/"):
			n += by_folder[f].size()
	return n


func _add_note_row(note: ContentLayer, depth: int) -> void:
	_visible_notes.append(note)
	var btn: Button = _make_note_item(note)
	_indent(btn, &"NoteItem", depth, 22 if depth > 0 else 0)
	_note_buttons[note] = btn
	note_list_container.add_child(btn)


## Indent a sidebar row by giving it copies of its styleboxes with a bigger
## left margin (Buttons have no indent property of their own).
func _indent(btn: Button, variation: StringName, depth: int, extra: int = 0) -> void:
	var px: int = depth * 14 + extra
	if px == 0:
		return
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		var sb: StyleBox = btn.get_theme_stylebox(state, variation)
		if sb == null:
			continue
		var c: StyleBox = sb.duplicate()
		c.content_margin_left = maxf(sb.content_margin_left, 0.0) + px
		btn.add_theme_stylebox_override(state, c)


func _make_folder_item(rel: String, depth: int, count: int) -> Button:
	var btn := Button.new()
	btn.name = "Folder_" + rel.replace("/", "_")
	btn.theme_type_variation = &"NoteItem"
	btn.text = rel.get_file()
	btn.icon = Icons.get_icon("chevron_right" if _collapsed.has(rel) else "chevron_down")
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.clip_text = true
	btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.tooltip_text = "%s  ·  %d note%s\nDrag notes here to move them · right-click for more" % [rel, count, "" if count == 1 else "s"]
	btn.add_theme_color_override("font_color", _palette_colors.get("text", Color.WHITE))
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		btn.add_theme_color_override(state, _palette_colors.get("text_faint", Color.GRAY))
	btn.add_theme_font_size_override("font_size", 13)
	_indent(btn, &"NoteItem", depth)
	btn.pressed.connect(_toggle_folder.bind(rel))
	btn.gui_input.connect(_on_row_gui_input.bind({"type": "folder", "rel": rel}))
	btn.set_drag_forwarding(
		func(_p: Vector2) -> Variant: return _start_drag({"type": "folder", "rel": rel}, rel.get_file()),
		func(_p: Vector2, data: Variant) -> bool: return _can_drop(data, rel),
		func(_p: Vector2, data: Variant) -> void: _drop(data, rel))
	_folder_buttons[rel] = btn
	return btn


func _toggle_folder(rel: String) -> void:
	if _collapsed.has(rel):
		_collapsed.erase(rel)
	else:
		_collapsed[rel] = true
	_save_collapsed()
	_refresh_note_list()


func _make_note_item(note: ContentLayer) -> Button:
	var btn := Button.new()
	btn.theme_type_variation = &"NoteItem"
	btn.toggle_mode = true
	btn.button_group = _note_group
	btn.button_pressed = note == current_note
	btn.text = _display_title(note)
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	btn.clip_text = true
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.pressed.connect(_open_note.bind(note))
	btn.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		btn.add_theme_color_override(state, Color.WHITE)   # keep the icon's own colour
	_apply_status_icon(btn, note)
	btn.gui_input.connect(_on_row_gui_input.bind({"type": "note", "note": note}))
	btn.set_drag_forwarding(
		func(_p: Vector2) -> Variant: return _start_drag({"type": "note", "note": note}, _display_title(note)),
		func(_p: Vector2, data: Variant) -> bool: return _can_drop(data, VaultStore.folder_of(note)),
		func(_p: Vector2, data: Variant) -> void: _drop(data, VaultStore.folder_of(note)))
	return btn


## ✓ = every quiz in the note passed; ● = missed a question about it.
func _apply_status_icon(btn: Button, note: ContentLayer) -> void:
	var preview: String = note.raw_text.strip_edges().replace("\n", " ")
	var tip: String = preview.substr(0, 140) if preview != "" else "Empty note"
	var folder: String = VaultStore.folder_of(note)
	if folder != "":
		tip = folder + "/\n\n" + tip
	match ProgressStore.status(note.title):
		"done":
			btn.icon = ProgressStore.icon("done")
			btn.tooltip_text = "✓ Complete — every quiz passed\n\n" + tip
		"review":
			btn.icon = ProgressStore.icon("review")
			btn.tooltip_text = "● Worth a review — you missed a question about this note\n\n" + tip
		_:
			btn.icon = null
			btn.tooltip_text = tip


## Called by quiz cards whenever an answer or result is saved.
func on_progress_changed() -> void:
	for note in _note_buttons:
		_apply_status_icon(_note_buttons[note], note)


func _sync_list_selection() -> void:
	for note in _note_buttons:
		var btn: Button = _note_buttons[note]
		btn.set_pressed_no_signal(note == current_note)
		btn.text = _display_title(note)


func _display_title(note: ContentLayer) -> String:
	var t: String = note.title.strip_edges()
	return "Untitled" if t == "" or t == "untitled" else t


func _on_search_changed(_text: String) -> void:
	_refresh_note_list()


func _on_search_submitted(_text: String) -> void:
	if _visible_notes.size() > 0:
		_open_note(_visible_notes[0])
		raw_text_layer.grab_focus()


# ── Opening / editing notes ─────────────────────────────────────────────────

func _open_note(note: ContentLayer) -> void:
	if note == null:
		return
	if current_note != null and current_note != note:
		_flush_pending_save()
	current_note = note
	_loading = true
	title_edit.text = "" if _display_title(note) == "Untitled" else note.title
	LayerEngine.set_note(note)
	raw_text_layer.text = note.raw_text
	raw_text_layer.clear_undo_history()
	_loading = false
	breadcrumb.text = _crumb(note)
	note_meta.text = _format_meta(note)
	delete_btn.disabled = false
	_update_word_count()
	_sync_list_selection()
	if current_mode == "graph":
		_switch_layer("raw")
	elif current_mode == "journey":
		_switch_layer("visual")
	else:
		empty_state_panel.visible = false
		note_content.visible = true
	if _undo_engine != null:
		_undo_engine.call("set_current_note", note.title)
	_update_status("Opened " + _display_title(note))


func _format_meta(note: ContentLayer) -> String:
	var parts: PackedStringArray = []
	if note.modified != "":
		parts.append("Edited " + note.modified.replace("T", "  "))
	if note.tags.size() > 0:
		parts.append("#" + " #".join(note.tags))
	return "   ·   ".join(parts)


func _on_raw_text_changed() -> void:
	if _loading or current_note == null or raw_text_layer.text == current_note.raw_text:
		return
	_editing = true
	_update_word_count()
	_auto_save_timer.start()
	_update_status("Editing…")


func _update_word_count() -> void:
	var text: String = raw_text_layer.text
	var words: int = 0
	for w in text.split(" ", false):
		for part in w.split("\n", false):
			if part.strip_edges() != "":
				words += 1
	word_count_label.text = "%d words  ·  %d chars" % [words, text.length()]


func _commit_title() -> void:
	if current_note == null:
		return
	var new_title: String = title_edit.text.strip_edges()
	if new_title == "":
		new_title = "untitled"
	if new_title == current_note.title:
		return
	_save_note_state()
	current_note.title = new_title
	VaultStore.save_note(current_note)
	_refresh_note_list()
	breadcrumb.text = _crumb(current_note)
	_update_status("Renamed to " + _display_title(current_note))


func _flush_pending_save() -> void:
	if _auto_save_timer != null and not _auto_save_timer.is_stopped():
		_auto_save_timer.stop()
		_do_auto_save()


func _do_auto_save() -> void:
	if current_note == null:
		return
	_save_note_state()
	_sync_raw_text()
	VaultStore.save_note(current_note)
	_editing = false
	note_meta.text = _format_meta(current_note)
	_refresh_note_list()
	_update_status("Saved")


func _sync_raw_text() -> void:
	if current_note != null and raw_text_layer != null:
		current_note.raw_text = raw_text_layer.text


func _save_note_state() -> void:
	if current_note == null or _undo_engine == null:
		return
	_undo_engine.call("set_current_note", current_note.title)
	_undo_engine.call("push_snapshot", current_note)


func _on_save_note_pressed() -> void:
	if current_note == null:
		_update_status("No note to save")
		return
	_auto_save_timer.stop()
	_do_auto_save()


func _on_new_note_pressed() -> void:
	_flush_pending_save()
	var folder: String = VaultStore.folder_of(current_note) if current_note != null else ""
	var note: ContentLayer = VaultStore.create_note("untitled", folder)
	_last_sig = VaultStore.disk_signature()
	search_box.text = ""
	_refresh_note_list()
	_open_note(note)
	if current_mode != "raw":
		_switch_layer("raw")
	title_edit.grab_focus()
	_update_status("New note")


func _on_delete_note_pressed() -> void:
	if current_note == null:
		return
	var title: String = _display_title(current_note)
	var index: int = VaultStore.note_list.find(current_note)
	_auto_save_timer.stop()
	if index >= 0:
		VaultStore.delete_note(index)
	current_note = null
	_refresh_note_list()
	if VaultStore.note_list.size() > 0:
		_open_note(VaultStore.note_list[0])
	else:
		_show_empty_state()
	_update_status("Deleted " + title)


func _undo() -> void:
	if current_note == null or _undo_engine == null or not _undo_engine.call("can_undo"):
		return
	var restored: ContentLayer = _undo_engine.call("undo")
	if restored != null:
		_reopen_by_title(restored.title)


func _redo() -> void:
	if current_note == null or _undo_engine == null or not _undo_engine.call("can_redo"):
		return
	var restored: ContentLayer = _undo_engine.call("redo")
	if restored != null:
		_reopen_by_title(restored.title)


## Open a note by title, case-insensitively (used by [[wikilink]] clicks).
## Open a note by title. Clicked [[links]] pass create_missing = true, so a
## link to a note that doesn't exist yet creates it (Obsidian behaviour).
func open_note_by_title(title: String, create_missing: bool = false) -> void:
	var want: String = title.strip_edges().to_lower()
	for note in VaultStore.note_list:
		if note.title.strip_edges().to_lower() == want:
			_open_note(note)
			return
	if not create_missing or want == "":
		_update_status("No note named “%s”" % title)
		return
	_flush_pending_save()
	var created: ContentLayer = VaultStore.create_note(title.strip_edges())
	search_box.text = ""
	_refresh_note_list()
	_open_note(created)
	_switch_layer("raw")
	raw_text_layer.grab_focus()
	_update_status("Created “%s” — it didn't exist yet" % title.strip_edges())


func _reopen_by_title(title: String) -> void:
	var idx: int = VaultStore.get_note_index(title)
	if idx >= 0:
		_open_note(VaultStore.note_list[idx])


func _update_status(msg: String) -> void:
	if status_label != null:
		status_label.text = msg


# ── Layers ──────────────────────────────────────────────────────────────────

func _switch_layer(mode: String) -> void:
	if not layer_buttons.has(mode):
		return
	_sync_raw_text()
	current_mode = mode
	for m in layer_buttons:
		(layer_buttons[m] as Button).set_pressed_no_signal(m == mode)
	mode_label.text = MODE_NAMES[mode]
	if journey_panel != null:
		journey_panel.visible = mode == "journey"
	if mode == "journey":
		empty_state_panel.visible = false
		note_content.visible = false
		graph_layer.visible = false
		breadcrumb.text = _vault_name() + "  /  Learning Journey"
		journey_panel.refresh()
		_update_status("Learning Journey  ·  topics → objectives → demonstrations")
		return
	if current_note != null:
		breadcrumb.text = _crumb(current_note)
	if mode == "graph":
		_build_graph_data()
		empty_state_panel.visible = false
		note_content.visible = false
		graph_layer.visible = true
		# The graph lays nodes out inside its current size, which is 0x0 until
		# the container has sized it — so feed it data after the next layout.
		await get_tree().process_frame
		if current_mode == "graph":
			graph_layer.set_graph_data(_graph_nodes, _graph_edges)
		_update_status("Graph  ·  drag to move, scroll to zoom, double-click to open")
		return
	graph_layer.visible = false
	note_content.visible = current_note != null
	empty_state_panel.visible = current_note == null
	doc_scroll.visible = mode != "raw"
	if current_note != null:
		LayerEngine.set_note(current_note)
	LayerEngine.set_mode(mode)
	if mode == "raw":
		raw_text_layer.grab_focus()
	_update_status(MODE_NAMES[mode] + " view")


# ── Input ───────────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k: InputEventKey = event as InputEventKey
	if not k.ctrl_pressed:
		return
	var handled: bool = true
	match k.keycode:
		KEY_N:
			_on_new_note_pressed()
		KEY_S:
			_on_save_note_pressed()
		KEY_F:
			search_box.grab_focus()
			search_box.select_all()
		KEY_1:
			_switch_layer("raw")
		KEY_2:
			_switch_layer("structured")
		KEY_3:
			_switch_layer("visual")
		KEY_4:
			_switch_layer("graph")
		KEY_5:
			_switch_layer("journey")
		KEY_Z:
			if k.shift_pressed:
				_redo()
			else:
				_undo()
		_:
			handled = false
	if handled:
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	# Palette keys must win over focused text fields, so they live in _input
	if not (event is InputEventKey and event.pressed):
		return
	var k: InputEventKey = event as InputEventKey
	if _scene_overlay != null and k.keycode == KEY_ESCAPE:
		close_scene_overlay()
		get_viewport().set_input_as_handled()
		return
	if k.ctrl_pressed and k.keycode == KEY_P:
		if _palette_visible:
			_close_palette()
		else:
			_open_palette()
		get_viewport().set_input_as_handled()
	elif k.ctrl_pressed and k.keycode == KEY_N and raw_text_layer.has_focus():
		# TextEdit would swallow Ctrl+N before _unhandled_input sees it
		_on_new_note_pressed()
		get_viewport().set_input_as_handled()
	elif _palette_visible:
		match k.keycode:
			KEY_ESCAPE:
				_close_palette()
				get_viewport().set_input_as_handled()
			KEY_UP:
				_move_palette_selection(-1)
				get_viewport().set_input_as_handled()
			KEY_DOWN:
				_move_palette_selection(1)
				get_viewport().set_input_as_handled()
			KEY_ENTER, KEY_KP_ENTER:
				_run_selected_palette_item()
				get_viewport().set_input_as_handled()


# ── Import ──────────────────────────────────────────────────────────────────

func _on_import_vault_pressed() -> void:
	import_dialog.current_dir = _get_download_path()
	import_dialog.popup_centered(Vector2i(720, 480))


func _on_import_dir_selected(src_vault: String) -> void:
	"""Copy every .tres note from the chosen folder into the vault (skipping duplicates)."""
	var src_dir := DirAccess.open(src_vault)
	if src_dir == null:
		_update_status("Cannot open " + src_vault)
		return
	var actual_dst: String = ProjectSettings.globalize_path(VaultStore.vault_path)
	var import_count: int = 0
	var skip_count: int = 0
	src_dir.list_dir_begin()
	var file_name: String = src_dir.get_next()
	while file_name != "":
		if file_name.ends_with(".tres") and not src_dir.current_is_dir():
			var src_path: String = src_vault.path_join(file_name)
			var title: String = _parse_note_title_from_file(src_path)
			if VaultStore.get_note_index(title) >= 0 or FileAccess.file_exists(actual_dst.path_join(file_name)):
				skip_count += 1
			elif DirAccess.copy_absolute(src_path, actual_dst.path_join(file_name)) == OK:
				import_count += 1
		file_name = src_dir.get_next()
	VaultStore.refresh_note_list()
	_refresh_note_list()
	var msg: String = "Imported %d notes" % import_count
	if skip_count > 0:
		msg += ", skipped %d duplicates" % skip_count
	_update_status(msg)


# ── Command palette ─────────────────────────────────────────────────────────

func _create_palette() -> void:
	"""Build the Ctrl+P palette: a dimmed overlay holding a floating panel."""
	_palette_overlay = ColorRect.new()
	_palette_overlay.name = "CommandPaletteOverlay"
	_palette_overlay.color = _palette_colors.dim
	_palette_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_palette_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_palette_overlay.visible = false
	_palette_overlay.gui_input.connect(_on_palette_overlay_input)
	add_child(_palette_overlay)

	_palette_panel = PanelContainer.new()
	_palette_panel.name = "CommandPalettePanel"
	_palette_panel.theme_type_variation = &"PalettePanel"
	_palette_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_palette_panel.custom_minimum_size = Vector2(600, 0)
	_palette_panel.offset_left = -300
	_palette_panel.offset_right = 300
	_palette_panel.offset_top = 96
	_palette_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_palette_overlay.add_child(_palette_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	_palette_panel.add_child(vbox)

	_palette_search = LineEdit.new()
	_palette_search.theme_type_variation = &"PaletteSearch"
	_palette_search.placeholder_text = "Type a command or search notes…"
	_palette_search.text_changed.connect(_on_palette_search_changed)
	vbox.add_child(_palette_search)

	_palette_list = ItemList.new()
	_palette_list.custom_minimum_size = Vector2(0, 300)
	_palette_list.focus_mode = Control.FOCUS_NONE
	_palette_list.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_palette_list.item_clicked.connect(_on_palette_item_clicked)
	vbox.add_child(_palette_list)

	var footer := PanelContainer.new()
	footer.theme_type_variation = &"PaletteFooter"
	var hint := Label.new()
	hint.theme_type_variation = &"FaintLabel"
	hint.text = "↑↓  navigate      ↵  open      esc  close"
	footer.add_child(hint)
	vbox.add_child(footer)


func _build_palette_items(filter_text: String = "") -> void:
	var commands: Array[Dictionary] = [
		{"label": "New note", "hint": "Ctrl+N", "action": "new_note"},
		{"label": "Save note", "hint": "Ctrl+S", "action": "save_note"},
		{"label": "Edit view", "hint": "Ctrl+1", "action": "mode:raw"},
		{"label": "Outline view", "hint": "Ctrl+2", "action": "mode:structured"},
		{"label": "Reading view", "hint": "Ctrl+3", "action": "mode:visual"},
		{"label": "Graph view", "hint": "Ctrl+4", "action": "mode:graph"},
		{"label": "Learning Journey", "hint": "Ctrl+5", "action": "mode:journey"},
		{"label": "New folder", "hint": "", "action": "new_folder"},
		{"label": "Open vault folder… (or create one)", "hint": "vault", "action": "open_vault"},
		{"label": "Show vault in file manager", "hint": "vault", "action": "reveal_vault"},
		{"label": "Toggle light / dark theme", "hint": "", "action": "theme"},
		{"label": "Undo", "hint": "Ctrl+Z", "action": "undo"},
		{"label": "Redo", "hint": "Ctrl+Shift+Z", "action": "redo"},
		{"label": "Delete current note", "hint": "", "action": "delete_note"},
		{"label": "Import vault…", "hint": "", "action": "import"},
		{"label": "Insert 3D scene: Galaxy", "hint": "3d", "action": "insert3d:galaxy"},
		{"label": "Insert 3D scene: Torus knot", "hint": "3d", "action": "insert3d:knot"},
		{"label": "Insert 3D scene: Terrain flyover", "hint": "3d", "action": "insert3d:terrain"},
		{"label": "Insert 3D scene: Wave field", "hint": "3d", "action": "insert3d:waves"},
		{"label": "Insert 3D scene: Atom", "hint": "3d", "action": "insert3d:atom"},
		{"label": "Insert 3D scene: Vault graph", "hint": "3d", "action": "insert3d:graph"},
		{"label": "Insert quiz (3D, multiple choice)", "hint": "quiz", "action": "insert3d:quiz"},
		{"label": "Insert flashcards", "hint": "cards", "action": "insert3d:flashcards"},
		{"label": "Insert shapes scene", "hint": "3d", "action": "insert3d:shapes"},
		{"label": "Import 3D model… (.glb, .gltf, .fbx)", "hint": "3d", "action": "import_model"},
		{"label": "Reset quiz progress", "hint": "", "action": "reset_progress"},
		{"label": "Export vault", "hint": "", "action": "export"},
	]
	for v in VaultRegistry.recent():
		if v != VaultStore.vault_path:
			commands.append({"label": "Switch vault: " + VaultRegistry.display_name(v), "hint": "vault", "action": "vault:" + v})
	var f: String = filter_text.strip_edges().to_lower()
	_palette_items.clear()
	_palette_list.clear()
	for c in commands:
		if f == "" or c.label.to_lower().contains(f):
			_add_palette_row("›  " + c.label, c.hint, c.action)
	for note in VaultStore.note_list:
		var title: String = _display_title(note)
		if f == "" or title.to_lower().contains(f):
			_add_palette_row("◇  " + title, "note", "open:" + str(VaultStore.note_list.find(note)))
	_palette_selected_index = 0
	_highlight_palette_item()


func _add_palette_row(label: String, hint: String, action: String) -> void:
	var text: String = label if hint == "" else label + "    " + hint
	_palette_list.add_item(text)
	_palette_items.append({"label": label, "action": action})


func _open_palette() -> void:
	_palette_visible = true
	_palette_overlay.visible = true
	_palette_search.text = ""
	_build_palette_items("")
	_palette_search.grab_focus()


func _close_palette() -> void:
	_palette_visible = false
	_palette_overlay.visible = false
	_palette_search.release_focus()


func _on_palette_search_changed(new_text: String) -> void:
	_build_palette_items(new_text)


func _move_palette_selection(delta: int) -> void:
	if _palette_items.is_empty():
		return
	_palette_selected_index = clampi(_palette_selected_index + delta, 0, _palette_items.size() - 1)
	_highlight_palette_item()


func _highlight_palette_item() -> void:
	_palette_list.deselect_all()
	if _palette_selected_index >= 0 and _palette_selected_index < _palette_items.size():
		_palette_list.select(_palette_selected_index)
		_palette_list.ensure_current_is_visible()


func _run_selected_palette_item() -> void:
	if _palette_selected_index >= 0 and _palette_selected_index < _palette_items.size():
		_execute_command(_palette_items[_palette_selected_index].action)


func _on_palette_item_clicked(index: int, _pos: Vector2, mouse_button: int) -> void:
	if mouse_button == MOUSE_BUTTON_LEFT and index < _palette_items.size():
		_palette_selected_index = index
		_execute_command(_palette_items[index].action)


## Insert a ```3d block into the current note, then show it in Read view.
func _insert_3d(preset: String) -> void:
	_insert_block(NoteScene3D.template(preset), "Inserted 3D scene: " + NoteScene3D.PRESETS.get(preset, preset))


func _insert_block(block: String, status: String) -> void:
	if current_note == null:
		_on_new_note_pressed()
	if current_mode != "raw":
		_switch_layer("raw")
	if raw_text_layer.get_caret_line() == 0 and raw_text_layer.get_caret_column() == 0 and raw_text_layer.text != "":
		var last: int = raw_text_layer.get_line_count() - 1
		raw_text_layer.set_caret_line(last)
		raw_text_layer.set_caret_column(raw_text_layer.get_line(last).length())
	raw_text_layer.insert_text_at_caret("\n\n" + block + "\n")
	_flush_pending_save()
	_switch_layer("visual")
	_update_status(status)


# ── 3D model import ─────────────────────────────────────────────────────────

var _model_dialog: FileDialog = null


func _open_model_dialog() -> void:
	if _model_dialog == null:
		_model_dialog = FileDialog.new()
		_model_dialog.title = "Import a 3D model"
		_model_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_model_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_model_dialog.filters = PackedStringArray(["*.glb, *.gltf ; glTF models", "*.fbx ; FBX models"])
		_model_dialog.ok_button_text = "Import"
		_model_dialog.size = Vector2i(760, 500)
		_model_dialog.current_dir = OS.get_environment("HOME")
		_model_dialog.file_selected.connect(func(path: String) -> void: import_model_file(path))
		add_child(_model_dialog)
	_model_dialog.popup_centered()


func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if f.get_extension().to_lower() in NoteScene3D.MODEL_EXTS:
			import_model_file(f)


## Copy a model into <vault>/models/ (plus a .gltf's .bin/texture files)
## and insert a ```3d block that shows it. Returns the stored file name.
func import_model_file(path: String) -> String:
	var ext: String = path.get_extension().to_lower()
	if ext not in NoteScene3D.MODEL_EXTS or not FileAccess.file_exists(path):
		_update_status("Not a 3D model: " + path.get_file())
		return ""
	var dest_dir: String = VaultStore.vault_path.path_join("models")
	DirAccess.make_dir_recursive_absolute(dest_dir)
	var fname: String = path.get_file()
	if path.get_base_dir().simplify_path() != dest_dir.simplify_path():
		var stem: String = fname.get_basename()
		var i: int = 1
		while FileAccess.file_exists(dest_dir.path_join(fname)):
			fname = "%s_%d.%s" % [stem, i, ext]
			i += 1
		DirAccess.copy_absolute(path, dest_dir.path_join(fname))
		if ext == "gltf":
			_copy_gltf_sidecars(path, dest_dir)
	var caption: String = fname.get_basename().replace("_", " ").replace("-", " ").capitalize()
	_insert_block("```3d\nmodel: %s, spin\ncaption: %s\n```" % [fname, caption], "Imported 3D model: " + fname)
	return fname


## A .gltf points at sibling files (buffers, images) by relative URI.
func _copy_gltf_sidecars(gltf_path: String, dest_dir: String) -> void:
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(gltf_path))
	if not json is Dictionary:
		return
	for section in ["buffers", "images"]:
		for entry in json.get(section, []):
			var uri: String = str(entry.get("uri", ""))
			if uri == "" or uri.begins_with("data:"):
				continue
			var src: String = gltf_path.get_base_dir().path_join(uri.uri_decode())
			var dst: String = dest_dir.path_join(uri.uri_decode())
			DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
			if FileAccess.file_exists(src):
				DirAccess.copy_absolute(src, dst)


## Full-window view of a 3D scene (the card's Expand button).
func show_scene_overlay(params: Dictionary) -> void:
	close_scene_overlay()
	_scene_overlay = ColorRect.new()
	_scene_overlay.color = Color(0, 0, 0, 0.6)
	_scene_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scene_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 40)
	var card := NoteScene3D.new(params, 0.0, true)
	card.closed.connect(close_scene_overlay)
	margin.add_child(card)
	_scene_overlay.add_child(margin)
	add_child(_scene_overlay)


func close_scene_overlay() -> void:
	if _scene_overlay != null:
		_scene_overlay.queue_free()
		_scene_overlay = null


func _on_palette_overlay_input(event: InputEvent) -> void:
	# A click on the dimmed backdrop (outside the panel) closes the palette
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_close_palette()


func _execute_command(action: String) -> void:
	_close_palette()
	if action.begins_with("mode:"):
		_switch_layer(action.substr(5))
	elif action == "reset_progress":
		ProgressStore.reset()
		on_progress_changed()
		if current_note != null and current_mode == "visual":
			_switch_layer("visual")
		_update_status("Quiz progress reset")
	elif action == "import_model":
		_open_model_dialog()
	elif action.begins_with("vault:"):
		switch_vault(action.substr(6))
	elif action == "open_vault":
		_open_vault_dialog()
	elif action == "reveal_vault":
		OS.shell_open(VaultStore.vault_path)
	elif action == "new_folder":
		_new_folder_prompt("")
	elif action.begins_with("insert3d:"):
		_insert_3d(action.substr(9))
	elif action.begins_with("open:"):
		var idx: int = int(action.substr(5))
		if idx >= 0 and idx < VaultStore.note_list.size():
			_open_note(VaultStore.note_list[idx])
	else:
		match action:
			"new_note": _on_new_note_pressed()
			"save_note": _on_save_note_pressed()
			"theme": _toggle_theme()
			"undo": _undo()
			"redo": _redo()
			"delete_note": _on_delete_note_pressed()
			"import": _on_import_vault_pressed()
			"export": _on_export_vault_pressed()


## Export the entire vault as a .zip file (saved to the OS Downloads directory).
func _on_export_vault_pressed() -> void:
	"""Copy the vault directory to the OS Downloads folder."""
	var vault_dir := VaultStore.vault_path
	var actual_vault := ProjectSettings.globalize_path(vault_dir)

	if not DirAccess.dir_exists_absolute(actual_vault):
		_update_status("Vault directory not found")
		return

	# Copy vault to Downloads
	var download_path := _get_download_path()
	var dest_dir := download_path + "/" + _vault_name().to_lower().replace(" ", "-") + "-export"

	# Remove previous export if it exists
	if DirAccess.dir_exists_absolute(dest_dir):
		_dir_delete_recursive(dest_dir)

	# Copy the vault recursively (DirAccess doesn't have copy_recursive in GD4)
	var copy_err := _dir_copy_recursive(actual_vault, dest_dir)
	if copy_err != OK:
		_update_status("Export failed: " + str(copy_err))
		return

	# Open file manager at Downloads
	OS.shell_open(download_path)
	_update_status("Exported vault to " + dest_dir)


func _dir_delete_recursive(path: String) -> void:
	"""Recursively delete a directory."""
	var dir := DirAccess.open(path)
	if dir == null:
		DirAccess.remove_absolute(path)
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := path + "/" + name
		if dir.current_is_dir():
			_dir_delete_recursive(full)
		else:
			dir.remove(full)
		name = dir.get_next()
	DirAccess.remove_absolute(path)


func _dir_copy_recursive(src: String, dst: String) -> Error:
	"""Recursively copy a directory. Returns OK on success."""
	DirAccess.make_dir_recursive_absolute(dst)
	var dir := DirAccess.open(src)
	if dir == null:
		return ERR_CANT_CONNECT

	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var src_full := src + "/" + name
		var dst_full := dst + "/" + name
		if dir.current_is_dir():
			var err := _dir_copy_recursive(src_full, dst_full)
			if err != OK:
				return err
		else:
			var err := DirAccess.copy_absolute(src_full, dst_full)
			if err != OK:
				return err
		name = dir.get_next()
	return OK


func _parse_note_title_from_file(file_path: String) -> String:
	"""Read the first line of a .tres file to extract a note title."""
	if not FileAccess.file_exists(file_path):
		return file_path.get_file().replace(".tres", "")

	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return file_path.get_file().replace(".tres", "")

	var first_line := f.get_line()
	f.close()

	# Look for 'title = "Some Note"' pattern
	if first_line.begins_with("title ="):
		var parts := first_line.split("=", false)
		if parts.size() >= 2:
			var val := parts[1].strip_edges()
			# Remove surrounding quotes
			if val.begins_with('"') and val.ends_with('"'):
				val = val.substr(1, val.length() - 2)
			return val

	# Fallback: use filename without .tres extension
	return file_path.get_file().replace(".tres", "")


func _get_download_path() -> String:
	"""Get the user's OS Downloads directory."""
	var home := OS.get_user_data_dir()
	# Common download paths
	if OS.has_feature("windows"):
		var app_data := OS.get_environment("USERPROFILE")
		if app_data != "":
			return app_data + "/Downloads"
	elif OS.has_feature("macos"):
		var user := OS.get_environment("HOME")
		if user != "":
			return user + "/Downloads"
	else:
		# Linux: XDG_DOWNLOAD_DIR or fallback
		var xdg := OS.get_environment("XDG_DOWNLOAD_DIR")
		if xdg != "" and DirAccess.dir_exists_absolute(xdg):
			return xdg
	var user := OS.get_environment("HOME")
	return user + "/Downloads" if user != "" else "."


## Graph View — backlinks between notes

# Graph rendering state
var _graph_nodes: Dictionary = {}  # key: note_index, value: {pos, size, note, connections, color}
var _graph_edges: Array[Dictionary] = []  # list of {from, to}
var _graph_color_palette: Array[Color] = [
	Color(0.9, 0.5, 0.15),  # accent/orange
	Color(0.2, 0.7, 0.5),   # teal
	Color(0.5, 0.3, 0.8),   # purple
	Color(0.8, 0.3, 0.3),   # red
	Color(0.3, 0.6, 0.9),   # blue
	Color(0.7, 0.7, 0.2),   # yellow
	Color(0.9, 0.3, 0.7),   # pink
	Color(0.4, 0.8, 0.4),   # green
]


func _build_graph_data() -> void:
	"""Build graph nodes and edges from all notes."""
	if graph_layer == null:
		return
	# Clear previous layout
	_graph_nodes.clear()
	_graph_edges.clear()
	# Build graph from all notes
	_build_graph()


func _build_graph() -> void:
	"""Scan all notes for wikilinks [[...]] and HTML anchors <a href=\"...\">."""
	var notes: Array[ContentLayer]
	notes = VaultStore.note_list
	if notes.size() < 2:
		return

	# Build a lookup: title -> index
	var title_to_idx: Dictionary = {}
	for i in range(notes.size()):
		var t := notes[i].title.strip_edges().to_lower()
		if t != "" and t != "untitled":
			title_to_idx[t] = i

	# For each note, find outgoing links
	for i in range(notes.size()):
		var note: ContentLayer = notes[i]
		var content: String = note.raw_text
		var key := str(i)

		# Store node with connection info
		_graph_nodes[key] = {
			"pos": Vector2.ZERO,
			"size": Vector2(0, 0),
			"note": note,
			"title": note.title.strip_edges(),
			"connections": [],
			"color": _graph_color_palette[i % _graph_color_palette.size()],
		}

		# Find wikilinks: [[...]]
		var wikilink_re := RegEx.new()
		wikilink_re.compile("\\[\\[([^\\]]+)\\]\\]")
		var wikilink_matches := wikilink_re.search_all(content)
		for m in wikilink_matches:
			var target_name := m.strings[1].strip_edges().to_lower()
			var target_idx := _resolve_target(target_name, title_to_idx)
			if target_idx >= 0 and target_idx != i:
				var target_key := str(target_idx)
				if not _graph_nodes[key]["connections"].has(target_key):
					_graph_nodes[key]["connections"].append(target_key)
					_graph_edges.append({"from": i, "to": target_idx})

		# Find HTML anchor references: <a href="...">
		var anchor_re := RegEx.new()
		anchor_re.compile(r"<a\\s+href=[\"']([^\"'>]+)[\"']")
		var anchor_matches := anchor_re.search_all(content)
		for m in anchor_matches:
			var href := m.strings[1]
			# Normalize: strip .html, ./, leading /
			href = href.trim_prefix("./").trim_prefix("/")
			# Remove .html extension
			if href.ends_with(".html"):
				href = href.trim_suffix(".html")
			var target_idx := _resolve_target(href, title_to_idx)
			if target_idx >= 0 and target_idx != i:
				var target_key := str(target_idx)
				if not _graph_nodes[key]["connections"].has(target_key):
					_graph_nodes[key]["connections"].append(target_key)
					_graph_edges.append({"from": i, "to": target_idx})


func _resolve_target(name: String, title_map: Dictionary) -> int:
	"""Resolve a target name to a note index using title match."""
	if title_map.has(name):
		return title_map[name]
	# Try partial title match
	for k in title_map:
		if k.contains(name) or name.contains(k):
			return title_map[k]
	return -1


func _on_graph_node_clicked(note_idx: int) -> void:
	"""Open the selected note when its graph node is double-clicked."""
	if note_idx < 0 or note_idx >= VaultStore.note_list.size():
		return
	_open_note(VaultStore.note_list[note_idx])



# ── Vaults (VS Code-style: any folder can be a vault) ───────────────────────

func _vault_name() -> String:
	return VaultRegistry.display_name(VaultStore.vault_path)


## "Vault  /  Folder  /  Sub  /  Title"
func _crumb(note: ContentLayer) -> String:
	var parts: PackedStringArray = [_vault_name()]
	var folder: String = VaultStore.folder_of(note)
	if folder != "":
		parts.append_array(folder.split("/"))
	parts.append(_display_title(note))
	return "  /  ".join(parts)


func _build_vault_ui() -> void:
	var header: Node = get_node_or_null("AppLayout/Body/Sidebar/SidebarVBox/SidebarHeader")
	var brand: Label = header.get_node_or_null("Brand") if header != null else null
	if brand != null:
		brand.text = APP_NAME
	get_window().title = APP_NAME
	# Vault switcher, under the brand row
	_vault_btn = Button.new()
	_vault_btn.name = "VaultButton"
	_vault_btn.theme_type_variation = &"FlatButton"
	_vault_btn.icon = Icons.get_icon("vault", 14)
	_vault_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_vault_btn.clip_text = true
	_vault_btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_vault_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_vault_btn.pressed.connect(_show_vault_menu)
	header.add_sibling(_vault_btn)
	_vault_menu = PopupMenu.new()
	_vault_menu.name = "VaultMenu"
	_vault_menu.id_pressed.connect(_on_vault_menu)
	add_child(_vault_menu)
	_vault_dialog = FileDialog.new()
	_vault_dialog.name = "VaultDialog"
	_vault_dialog.title = "Open a folder as a vault (use “Create Folder” for a new one)"
	_vault_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_vault_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_vault_dialog.dir_selected.connect(switch_vault)
	add_child(_vault_dialog)
	_update_vault_button()

	# "New folder" button in the NOTES header
	var notes_header: Node = get_node_or_null("AppLayout/Body/Sidebar/SidebarVBox/NotesHeader")
	if notes_header != null:
		var nf := Button.new()
		nf.name = "NewFolderButton"
		nf.theme_type_variation = &"FlatButton"
		nf.icon = Icons.get_icon("folder_plus")
		nf.tooltip_text = "New folder"
		nf.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		nf.pressed.connect(func() -> void: _new_folder_prompt(""))
		notes_header.get_node("NotesTitle").add_sibling(nf)
		# Dropping on the header moves a note/folder to the top level
		(notes_header as Control).set_drag_forwarding(Callable(),
			func(_p: Vector2, data: Variant) -> bool: return _can_drop(data, ""),
			func(_p: Vector2, data: Variant) -> void: _drop(data, ""))
	var scroll: Control = note_list_container.get_parent()
	scroll.set_drag_forwarding(Callable(),
		func(_p: Vector2, data: Variant) -> bool: return _can_drop(data, ""),
		func(_p: Vector2, data: Variant) -> void: _drop(data, ""))
	scroll.gui_input.connect(_on_row_gui_input.bind({"type": "root"}))

	# Context menu + its "Move to" submenu, and a one-line prompt dialog
	_ctx_menu = PopupMenu.new()
	_ctx_menu.name = "SidebarMenu"
	_ctx_menu.id_pressed.connect(_on_ctx_menu)
	add_child(_ctx_menu)
	_move_menu = PopupMenu.new()
	_move_menu.name = "MoveMenu"
	_move_menu.id_pressed.connect(_on_move_menu)
	_ctx_menu.add_child(_move_menu)
	_prompt = ConfirmationDialog.new()
	_prompt.name = "PromptDialog"
	_prompt_edit = LineEdit.new()
	_prompt_edit.custom_minimum_size = Vector2(320, 0)
	_prompt.add_child(_prompt_edit)
	_prompt.register_text_enter(_prompt_edit)
	_prompt.confirmed.connect(func() -> void:
		if _prompt_cb.is_valid():
			_prompt_cb.call(_prompt_edit.text))
	add_child(_prompt)


func _update_vault_button() -> void:
	if _vault_btn != null:
		_vault_btn.text = " " + _vault_name()
		_vault_btn.tooltip_text = "Vault: %s\nClick to switch vaults or open another folder" % VaultStore.vault_path


func _show_vault_menu() -> void:
	_vault_menu.clear()
	var recent: Array[String] = VaultRegistry.recent()
	for i in range(recent.size()):
		_vault_menu.add_radio_check_item(VaultRegistry.display_name(recent[i]), i)
		_vault_menu.set_item_checked(i, recent[i] == VaultStore.vault_path)
		_vault_menu.set_item_tooltip(i, recent[i])
	_vault_menu.add_separator()
	_vault_menu.add_item("Open folder as vault…", 100)
	_vault_menu.add_item("Show vault in file manager", 101)
	var r: Rect2 = _vault_btn.get_global_rect()
	_vault_menu.popup(Rect2i(Vector2i(get_window().position) + Vector2i(r.position + Vector2(0, r.size.y)), Vector2i(int(r.size.x), 0)))


func _on_vault_menu(id: int) -> void:
	if id == 100:
		_open_vault_dialog()
	elif id == 101:
		OS.shell_open(VaultStore.vault_path)
	else:
		var recent: Array[String] = VaultRegistry.recent()
		if id < recent.size():
			switch_vault(recent[id])


func _open_vault_dialog() -> void:
	_vault_dialog.current_dir = VaultStore.vault_path.get_base_dir().get_base_dir()
	_vault_dialog.popup_centered(Vector2i(760, 500))


## Open another folder as the vault.
func switch_vault(path: String) -> void:
	_flush_pending_save()
	VaultStore.open_vault(path)
	current_note = null
	search_box.text = ""
	_load_collapsed()
	_refresh_note_list()
	_update_vault_button()
	_last_sig = VaultStore.disk_signature()
	if VaultStore.note_list.size() > 0:
		_open_note(VaultStore.note_list[0])
	else:
		_show_empty_state()
	if current_mode == "journey":
		_switch_layer("journey")
	_update_status("Opened vault " + _vault_name())


# ── Mirroring the disk ──────────────────────────────────────────────────────

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and is_inside_tree() and _watch_timer != null:
		check_disk_changes()


## Rescan when files or folders changed outside the app (file manager, git…).
func check_disk_changes() -> void:
	if (_auto_save_timer != null and not _auto_save_timer.is_stopped()) or (_prompt != null and _prompt.visible):
		return
	var sig: String = VaultStore.disk_signature()
	if sig == _last_sig:
		return
	_last_sig = sig
	var cur_path: String = current_note.resource_path if current_note != null else ""
	var cur_title: String = current_note.title if current_note != null else ""
	VaultStore.refresh_note_list()
	_refresh_note_list()
	var found: ContentLayer = null
	for note in VaultStore.note_list:
		if note.resource_path == cur_path:
			found = note
			break
	if found == null and cur_title != "":
		var idx: int = VaultStore.get_note_index(cur_title)
		found = VaultStore.note_list[idx] if idx >= 0 else null
	if found != null:
		if found != current_note or found.raw_text != raw_text_layer.text:
			current_note = null
			_open_note(found)
			if current_mode in ["structured", "visual"]:
				_switch_layer(current_mode)
		else:
			breadcrumb.text = _crumb(found)
	elif cur_path != "":
		if VaultStore.note_list.size() > 0:
			current_note = null
			_open_note(VaultStore.note_list[0])
		else:
			_show_empty_state()
	if current_mode == "journey":
		journey_panel.refresh()
	_update_status("Vault changed on disk — refreshed")


func _after_vault_op(status: String) -> void:
	_last_sig = VaultStore.disk_signature()
	_refresh_note_list()
	if current_note != null and current_mode != "journey":
		breadcrumb.text = _crumb(current_note)
	_update_status(status)


func _load_collapsed() -> void:
	_collapsed.clear()
	var p: String = VaultStore.data_dir().path_join("ui.json")
	if FileAccess.file_exists(p):
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if v is Dictionary and (v as Dictionary).get("collapsed") is Array:
			for rel in v.collapsed:
				_collapsed[str(rel)] = true


func _save_collapsed() -> void:
	DirAccess.make_dir_recursive_absolute(VaultStore.data_dir())
	var f := FileAccess.open(VaultStore.data_dir().path_join("ui.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"collapsed": _collapsed.keys()}, "\t"))


# ── Folder operations ───────────────────────────────────────────────────────

func _ask(title: String, initial: String, ok_text: String, cb: Callable) -> void:
	_prompt.title = title
	_prompt.ok_button_text = ok_text
	_prompt_edit.text = initial
	_prompt_cb = cb
	_prompt.popup_centered()
	_prompt_edit.grab_focus()
	_prompt_edit.select_all()


func _new_folder_prompt(parent: String) -> void:
	_ask("New folder" + (" in " + parent if parent != "" else ""), "New folder", "Create", func(name: String) -> void:
		create_folder(name, parent))


func create_folder(name: String, parent: String = "") -> String:
	var rel: String = VaultStore.create_folder(name, parent)
	if rel == "":
		_update_status("Couldn't create the folder")
		return ""
	_collapsed.erase(parent)
	_after_vault_op("Created folder " + rel)
	return rel


func rename_folder(rel: String, new_name: String) -> String:
	var was_collapsed: bool = _collapsed.has(rel)
	var nr: String = VaultStore.rename_folder(rel, new_name)
	if nr == "":
		_update_status("Couldn't rename — is that name taken?")
		return ""
	_collapsed.erase(rel)
	if was_collapsed:
		_collapsed[nr] = true
	_save_collapsed()
	_after_vault_op("Renamed folder to " + nr)
	return nr


func delete_folder(rel: String) -> void:
	var had_current: bool = current_note != null and (current_note.resource_path.begins_with(VaultStore.vault_path + rel + "/"))
	_auto_save_timer.stop()
	VaultStore.delete_folder(rel)
	if had_current:
		current_note = null
		if VaultStore.note_list.size() > 0:
			_open_note(VaultStore.note_list[0])
		else:
			_show_empty_state()
	_after_vault_op("Moved folder “%s” to the trash" % rel)


func move_note_to(note: ContentLayer, folder: String) -> bool:
	_flush_pending_save()
	if not VaultStore.move_note(note, folder):
		return false
	_collapsed.erase(folder)
	_after_vault_op("Moved “%s” to %s" % [_display_title(note), folder if folder != "" else "the top level"])
	return true


func move_folder_to(rel: String, dest: String) -> String:
	_flush_pending_save()
	var nr: String = VaultStore.move_folder(rel, dest.path_join(rel.get_file()) if dest != "" else rel.get_file())
	if nr != "":
		_after_vault_op("Moved folder to " + (dest if dest != "" else "the top level"))
	return nr


# ── Drag and drop in the sidebar ────────────────────────────────────────────

func _start_drag(data: Dictionary, label: String) -> Variant:
	var l := Label.new()
	l.text = "  " + label
	l.add_theme_color_override("font_color", _palette_colors.get("accent", Color.WHITE))
	set_drag_preview(l)
	return data


func _can_drop(data: Variant, dest: String) -> bool:
	if not (data is Dictionary):
		return false
	match str(data.get("type", "")):
		"note":
			return VaultStore.folder_of(data.note) != dest
		"folder":
			var rel: String = data.rel
			return dest != rel and not dest.begins_with(rel + "/") and rel.get_base_dir() != dest
	return false


func _drop(data: Variant, dest: String) -> void:
	if not _can_drop(data, dest):
		return
	if data.type == "note":
		move_note_to(data.note, dest)
	else:
		move_folder_to(data.rel, dest)


# ── Right-click menu ────────────────────────────────────────────────────────

func _on_row_gui_input(event: InputEvent, target: Dictionary) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_show_ctx(target)
		get_viewport().set_input_as_handled()


func _show_ctx(target: Dictionary) -> void:
	_ctx_target = target
	_ctx_menu.clear()
	match str(target.type):
		"folder":
			_ctx_menu.add_item("New note here", 0)
			_ctx_menu.add_item("New folder inside…", 1)
			_ctx_menu.add_item("Rename…", 2)
			_ctx_menu.add_item("Show in file manager", 3)
			_ctx_menu.add_separator()
			_ctx_menu.add_item("Move to trash…", 4)
		"note":
			_ctx_menu.add_item("Open", 10)
			_build_move_menu(VaultStore.folder_of(target.note))
			_ctx_menu.add_submenu_node_item("Move to", _move_menu, 11)
			_ctx_menu.add_item("Show in file manager", 12)
			_ctx_menu.add_separator()
			_ctx_menu.add_item("Delete note", 13)
		_:
			_ctx_menu.add_item("New note", 20)
			_ctx_menu.add_item("New folder…", 21)
			_ctx_menu.add_item("Show vault in file manager", 22)
	_ctx_menu.popup(Rect2i(Vector2i(get_window().position) + Vector2i(get_global_mouse_position()), Vector2i.ZERO))


func _build_move_menu(current_folder: String) -> void:
	_move_menu.clear()
	_move_targets.clear()
	for f in [""] + Array(VaultStore.folders):
		if f == current_folder:
			continue
		_move_menu.add_item("Top level" if f == "" else f, _move_targets.size())
		_move_targets.append(f)


func _on_move_menu(id: int) -> void:
	if id < _move_targets.size() and _ctx_target.get("type") == "note":
		move_note_to(_ctx_target.note, _move_targets[id])


func _on_ctx_menu(id: int) -> void:
	var t: Dictionary = _ctx_target
	match id:
		0:
			_flush_pending_save()
			var note: ContentLayer = VaultStore.create_note("untitled", t.rel)
			_collapsed.erase(t.rel)
			_after_vault_op("New note in " + t.rel)
			_open_note(note)
			_switch_layer("raw")
			title_edit.grab_focus()
		1: _new_folder_prompt(t.rel)
		2: _ask("Rename folder", t.rel.get_file(), "Rename", func(n: String) -> void: rename_folder(t.rel, n))
		3: OS.shell_open(VaultStore.vault_path + t.rel)
		4:
			var dlg := ConfirmationDialog.new()
			dlg.dialog_text = "Move the folder “%s” and everything in it to the trash?" % t.rel
			dlg.ok_button_text = "Move to trash"
			add_child(dlg)
			dlg.confirmed.connect(delete_folder.bind(t.rel))
			dlg.visibility_changed.connect(func() -> void:
				if not dlg.visible:
					dlg.queue_free())
			dlg.popup_centered()
		10: _open_note(t.note)
		12: OS.shell_open(t.note.resource_path.get_base_dir())
		13:
			_open_note(t.note)
			_on_delete_note_pressed()
		20: _on_new_note_pressed()
		21: _new_folder_prompt("")
		22: OS.shell_open(VaultStore.vault_path)


# ── Learning Journey ────────────────────────────────────────────────────────

func _build_journey() -> void:
	journey_panel = JourneyPanel.new(self)
	journey_panel.visible = false
	content_panel.add_child(journey_panel)


## A quiz / flashcard deck finished (called by NoteScene3D).
func on_activity_score(key: String, score: int, total: int, logged: int) -> void:
	if logged > 0:
		_update_status("Logged %d / %d to %d learning objective%s  ·  see Journey (Ctrl+5)" % [score, total, logged, "" if logged == 1 else "s"])
	else:
		_update_status("Scored %d / %d  ·  add it as a demonstration in Journey (Ctrl+5) to track it" % [score, total])


## Journey "Launch": open the note, scroll to the activity, start it over.
func launch_activity(key: String) -> NoteScene3D:
	var k: Dictionary = JourneyStore.parse_key(key)
	if k.is_empty():
		return null
	open_note_by_title(k.note)
	if current_note == null or current_note.title.strip_edges().to_lower() != str(k.note).strip_edges().to_lower():
		_update_status("Can't find the note “%s”" % k.note)
		return null
	_switch_layer("visual")
	await get_tree().process_frame
	await get_tree().process_frame
	var want_preset: String = "quiz" if k.kind == "quiz" else "flashcards"
	var index_key: String = "_quiz_index" if k.kind == "quiz" else "_cards_index"
	for c in visual_layer.get_children():
		if c is NoteScene3D and c.preset == want_preset and int(c.params.get(index_key, -1)) == int(k.index):
			doc_scroll.scroll_vertical = int(c.position.y) - 24
			c.restart()
			_update_status("Go!  Your score will be logged to the objectives that use this.")
			return c
	_update_status("That activity isn't in “%s” any more" % k.note)
	return null
