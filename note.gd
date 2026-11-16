extends Control
## Main scene controller for Ontomeme — wires the UI to VaultStore and LayerEngine.
##
## Layout and look live in note.tscn + AppTheme; this script only holds
## behaviour. Nodes are reached through scene-unique names (%Name), so the
## tree can be rearranged in the editor without breaking any paths.

const READABLE_WIDTH: float = 760.0
const TAG_CHIP_CHARS: int = 30   # a longer tag's chip shows this many, then "…"
const TAG_ROWS_MAX_HEIGHT: float = 132.0   # the TAGS rows scroll past this
const TAG_SUGGEST_MAX: int = 8   # the TagInput's autocomplete lists at most this many tags
const TAG_SUGGEST_WIDTH: float = 260.0   # ...in a card at most this wide
const TAG_DOT_SIZE: int = 12   # the coloured dot on a tag's chip and TAGS row (AppTheme.tag_color)
const TAG_LIST_FILTER_MIN: int = 8   # a vault with more tags than this gets a field filtering the TAGS rows
const EXCERPT_LEAD: int = 16   # a search result's excerpt starts at most this many characters before the match
const AUTO_SAVE_DELAY: float = 0.8
const SAVE_RETRY_DELAY: float = 5.0   # after a failed save, try again this much later
const MODE_NAMES: Dictionary = {"raw": "Edit", "structured": "Outline", "visual": "Read", "graph": "Graph", "journey": "Journey"}
const APP_NAME: String = "Ontomeme"
const WATCH_INTERVAL: float = 1.5
const UiScale = preload("res://ui_scale.gd")
const StarterContent = preload("res://starter_content.gd")
const Licences = preload("res://licences.gd")
const VaultLock = preload("res://vault_lock.gd")
const ABOUT_WIDTH: int = 560   # the About box; its paths wrap inside it
const NavHistory = preload("res://nav_history.gd")
const FIRST_NOTE: String = "Start Here: Tutorials"   # opened on first run
## The sidebar's sections above the folders, top to bottom: id -> the note
## field it lists (newest first). Header "Pinned (N)", rows "PinnedRow".
const SECTIONS: Dictionary = {"pinned": &"pinned_at", "starred": &"starred_at"}
const LINK_SUGGEST_MAX: int = 8        # titles in the [[ link list
const LINK_SUGGEST_WIDTH: float = 300.0

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
@onready var star_btn: Button = %StarButton
@onready var pin_btn: Button = %PinButton
@onready var export_md_btn: Button = %ExportMDButton
@onready var content_panel: PanelContainer = %ContentPanel
@onready var empty_state_panel: CenterContainer = %EmptyStatePanel
@onready var empty_new_btn: Button = %EmptyNewButton
@onready var note_content: MarginContainer = %NoteContent
@onready var title_edit: LineEdit = %TitleEdit
@onready var tag_bar: VBoxContainer = %TagBar
@onready var tag_input: LineEdit = %TagInput
@onready var tag_add_btn: Button = %TagAddButton
@onready var tag_chips: HFlowContainer = %TagChips
@onready var tag_suggest: PanelContainer = %TagSuggest
@onready var tag_suggest_list: ItemList = %TagSuggestList
@onready var note_meta: Label = %NoteMeta
@onready var tag_sidebar: VBoxContainer = %TagSidebar
@onready var tag_sidebar_toggle: Button = %TagSidebarLabel   # the TAGS header: folds the section
@onready var tag_sidebar_clear: Button = %TagSidebarClear
@onready var tag_sidebar_filter: LineEdit = %TagSidebarFilter
@onready var tag_sidebar_scroll: ScrollContainer = %TagSidebarScroll
@onready var tag_sidebar_list: VBoxContainer = %TagSidebarList
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
var _editing: bool = false   # the open note has an edit the autosave hasn't tried to write yet
var _loading: bool = false
var _theme_pref: String = UiScale.load_theme()   # "dark", "light" or "system"
var _is_dark_mode: bool = UiScale.is_dark(_theme_pref)
var _palette_colors: Dictionary = {}
var _auto_save_timer: Timer = null
## Notes whose last save failed (read-only folder, full disk, a sync lock).
## Each ContentLayer still holds the user's words; they are retried on
## _retry_timer, on every flush, on close and on focus-out, whichever note is
## open, until they save. Leaving such a note keeps it here.
var _unsaved: Array[ContentLayer] = []
var _save_error: String = ""   # why the latest of them failed (VaultStore.last_save_error)
var _retry_timer: Timer = null
## A vault switch held because words were at risk: its path and the warning
## it showed (_words_at_risk). Only that same switch, while that same risk
## stands, goes ahead the second time; a save that leaves nothing unsaved
## clears it, so later words at risk hold the switch again.
var _switch_anyway: String = ""
## Notes Delete moved to <vault>/.trash this session, newest last:
## {trash_rel, original_rel, title, at[, unsaved][, folder]}, and the notes a
## folder's Move to trash took without words they couldn't save (`folder`,
## _keep_folder_note_words). Ctrl+Z outside the editor
## and the palette's "Restore last deleted note" put the newest one back;
## `at` (UndoRedoEngine.tick()) says whether that delete came after the last
## edit. `unsaved` holds the fields of a note whose save had failed (its
## file lacks them), which a restore puts back (_note_fields). Those are the
## only copy of the words: a vault switch waits for them like for _unsaved,
## and an entry holding them is never dropped without them.
var _trashed: Array[Dictionary] = []
## Renames whose save failed (_rename_current), by note: {from: the title
## the note had, order: note_list then}. The note keeps its old file and
## everything that named it keeps the old title until a save of it works;
## then _finish_rename gives it its file and runs the cascade.
var _pending_renames: Dictionary = {}
## What the app last put in the title field (_show_title) or committed from
## it. The field differs from it only when the user typed a new title, so a
## title changed outside the app is never "committed" back over the file.
var _title_shown: String = ""
## The bar above a conflict copy's text (_build_conflict_bar): which note it
## was saved against, and the ways to settle the two.
var _conflict_bar: PanelContainer = null
var _conflict_label: Label = null
var _conflict_use_btn: Button = null
var _conflict_keep_btn: Button = null
var _conflict_compare_btn: Button = null
var _compare_dialog: AcceptDialog = null
var _compare_text: RichTextLabel = null
var _note_group: ButtonGroup = ButtonGroup.new()
var _layer_group: ButtonGroup = ButtonGroup.new()
var _visible_notes: Array[ContentLayer] = []
## How many times _refresh_note_list rebuilt the sidebar (tests count the
## rebuilds an autosave must not cause).
var refresh_count: int = 0
## The open note's title, folder and tags as the sidebar was last built with
## them (_row_key): while they stay so, an autosave updates its row alone.
var _listed_key: String = ""
var _active_tag_filter: String = ""   # the sidebar's tag filter ("" = no filter)
var _tag_filter_applied_from_search: bool = false   # search text owns the filter
var _search_tags: Array[String] = []   # the "#…" tokens in the search box, normalized, while it owns the filter
var _search_hits: Dictionary = {}      # ContentLayer -> its VaultStore.search hit, while words are searched
var _tag_suggest_clicked: bool = false   # a click took a suggestion; see _swallow_tag_suggest_double_click
var _tags_collapsed: bool = false   # the TAGS section folded away (ui.json "tags_collapsed")

# Command palette
var _palette_overlay: ColorRect = null
var _palette_panel: PanelContainer = null
var _palette_search: LineEdit = null
var _palette_list: ItemList = null
var _palette_items: Array[Dictionary] = []
var _palette_selected_index: int = 0
var _palette_hits: Dictionary = {}     # note file path -> its VaultStore.search hit, for "open:<path>"
var _palette_visible: bool = false
var _scene_overlay: ColorRect = null

# Image viewer and image menu (Read view: click or right-click an image)
const IMAGE_MAX_ZOOM: float = 2.0   # the viewer enlarges a small image at most this much
## Pictures the app can't show (ImageEmbeds.EXTS are the ones it can): a drop
## of one gets the image import's "Not a supported image" line, not the
## "left out" count of other files.
const IMAGE_LIKE_EXTS: Array[String] = ["gif", "bmp", "svg", "tif", "tiff", "heic", "heif", "avif", "ico"]
const IMAGE_VIEWER_PAD: int = 14    # px between the viewer's panel edge and its picture
const IMAGE_VIEW: int = 0           # image menu ids
const IMAGE_SHOW: int = 1
const IMAGE_REMOVE: int = 2
var _image_overlay: ColorRect = null
var _viewer_picture: TextureRect = null
var _image_menu: PopupMenu = null
var _image_menu_info: Dictionary = {}

# Folders, vaults, journey
var _note_buttons: Dictionary = {}     # ContentLayer -> Button
var _folder_buttons: Dictionary = {}   # rel path -> Button
var _collapsed: Dictionary = {}        # rel path -> true
var _section_rows: Array[Button] = []  # Pinned / Starred rows; meta "note" = their note
var _sections_collapsed: Dictionary = {}   # section id ("pinned", "starred") -> true
var journey_panel: JourneyPanel = null
var _vault_btn: Button = null
var _vault_menu: PopupMenu = null
var _vault_dialog: FileDialog = null
var _ctx_menu: PopupMenu = null
var _move_menu: PopupMenu = null
var _ctx_target: Dictionary = {}       # {"type": "note"/"folder"/"root"/"unreadable", ...}
var _move_targets: Array[String] = []
var _unreadable_row: Button = null     # "N unreadable files", under the note list
var _prompt: ConfirmationDialog = null
var _prompt_edit: LineEdit = null
var _prompt_cb: Callable
var _prompt_answering: bool = false   # _on_prompt_confirmed is running the prompt's callback
## Backspace on a sidebar row deletes (after asking) only on a Mac, whose
## Backspace key is labelled Delete. Elsewhere it is a text key, and a row
## keeps the keyboard after a click, after Enter and after Down from search,
## so a Backspace aimed at the note or the search box must do nothing there.
var backspace_deletes_rows: bool = OS.has_feature("macos")
var _watch_timer: Timer = null
var _last_sig: String = ""
## Refreshes the heartbeat of this window's lock on the vault (VaultLock.hold_vault_lock).
var _lock_timer: Timer = null
## Open while the vault being opened is open in another window too
## (_ask_vault_in_use); null otherwise.
var _in_use_dialog: ConfirmationDialog = null
## Open while a close waits because words would be lost (_hold_close_if_at_risk).
var _quit_dialog: ConfirmationDialog = null

# Back / Forward through opened notes
var _nav: NavHistory = NavHistory.new()
var _navigating: bool = false   # set while Back / Forward opens a note, so it isn't pushed

# [[ link autocomplete in the editor
var _link_open_re: RegEx = RegEx.create_from_string("\\[\\[([^\\]|#]*)$")   # an unclosed [[ before the caret
var _link_popup: PanelContainer = null
var _link_list: ItemList = null
var _link_line: int = -1     # the editor line the list belongs to
var _link_start: int = -1    # column where the typed part of the title starts (after "[[")
var _link_clicked: bool = false   # a click took a suggestion; see _swallow_link_double_click


func _ready() -> void:
	_undo_engine = get_node_or_null("/root/UndoRedoEngine")
	if DisplayServer.get_name() != "headless":
		UiScale.apply(get_window(), true)
		get_window().dpi_changed.connect(func() -> void: UiScale.apply(get_window()))
	else:
		get_window().min_size = UiScale.BASE_MIN_SIZE   # headless: the window *is* its minimum size
	get_window().files_dropped.connect(_on_files_dropped)
	DisplayServer.set_system_theme_change_callback(_on_system_theme_changed)
	palette_btn.icon = Icons.get_icon("command")
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
	search_box.gui_input.connect(_on_search_gui_input)

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
	# Star and pin: icon-only toggles; _update_star_pin_buttons keeps their
	# pressed state and outline / filled icon in step with the open note
	star_btn.icon = Icons.get_icon("star")
	pin_btn.icon = Icons.get_icon("pin")
	star_btn.pressed.connect(_toggle_star)
	pin_btn.pressed.connect(_toggle_pin)
	export_md_btn.icon = Icons.get_icon("download", 16)
	export_md_btn.pressed.connect(_on_export_md_pressed)

	# Document
	title_edit.text_submitted.connect(func(_t: String) -> void: raw_text_layer.grab_focus())
	title_edit.focus_exited.connect(_commit_title)
	title_edit.text_submitted.connect(func(_t: String) -> void: _commit_title())
	raw_text_layer.text_changed.connect(_on_raw_text_changed)
	raw_text_layer.text_changed.connect(_update_link_popup)
	raw_text_layer.caret_changed.connect(_on_editor_caret_changed)
	raw_text_layer.gui_input.connect(_on_editor_gui_input)
	raw_text_layer.focus_exited.connect(_close_link_popup)
	raw_text_layer.draw.connect(_place_link_popup)   # the caret's draw position is fresh after a draw

	# TagBar: type a tag, press Enter (or the add button) to tag the open note;
	# a chip's #tag filters the notes by it, its × removes the tag
	tag_input.text_submitted.connect(_on_tag_submitted)
	tag_add_btn.pressed.connect(_add_tag_from_input)
	tag_add_btn.icon = Icons.get_icon("tag", 14)
	# Autocomplete: the vault's matching tags in a card under the TagInput.
	# The card never takes the focus, so typing carries on in the TagInput.
	tag_input.text_changed.connect(_update_tag_suggestions)
	tag_input.gui_input.connect(_on_tag_input_gui_input)
	tag_input.focus_exited.connect(_hide_tag_suggestions)
	tag_suggest_list.item_clicked.connect(_on_tag_suggestion_clicked)
	tag_suggest.resized.connect(_place_tag_suggestions)
	tag_input.resized.connect(_place_tag_suggestions)   # the window or the sidebar moved it

	# Sidebar tag filter (part 2): the rows are built in _build_tag_sidebar,
	# the × in the section header clears the filter, the header itself folds
	# the section away, and a field narrows the rows when there are many
	var trash_button: Button = %TrashButton
	trash_button.icon = Icons.get_icon("trash", 14)
	trash_button.pressed.connect(_show_trash_panel)
	tag_sidebar_clear.icon = Icons.get_icon("close", 10)
	tag_sidebar_clear.pressed.connect(_clear_tag_filter)
	tag_sidebar_toggle.pressed.connect(_toggle_tags_collapsed)
	tag_sidebar_filter.text_changed.connect(func(_t: String) -> void: _build_tag_sidebar())
	graph_layer.node_clicked.connect(_on_graph_node_clicked)
	content_panel.resized.connect(_update_readable_width)

	import_dialog.dir_selected.connect(_on_import_dir_selected)

	_auto_save_timer = Timer.new()
	_auto_save_timer.one_shot = true
	_auto_save_timer.wait_time = AUTO_SAVE_DELAY
	_auto_save_timer.timeout.connect(_do_auto_save)
	add_child(_auto_save_timer)
	_retry_timer = Timer.new()
	_retry_timer.one_shot = true
	_retry_timer.wait_time = SAVE_RETRY_DELAY
	_retry_timer.timeout.connect(_retry_unsaved)
	add_child(_retry_timer)

	LayerEngine.set_node_refs(raw_text_layer, structured_layer, visual_layer)
	LayerEngine.set_mode("raw")

	_create_palette()
	_create_link_popup()
	_build_vault_ui()
	_build_conflict_bar()
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
	_open_startup_note()
	_update_readable_width()
	var unreadable: String = _learning_files_warning()
	if VaultStore.startup_warning != "":
		_update_status(VaultStore.startup_warning)
	elif unreadable != "":
		_update_status(unreadable)
	elif VaultStore.first_run:
		_update_status("Welcome to Ontomeme  ·  start with the tutorials  ·  Ctrl+P commands")
	else:
		_update_status("Ready  ·  Ctrl+P commands  ·  Ctrl+N new note")
	print("[Ontomeme] " + diagnostics())   # lands in user://logs/godot.log
	if OS.has_feature("template") and DisplayServer.get_name() == "headless":
		# An exported build run headless (the first-run smoke test) has no
		# pointer, yet Godot can open this label's tooltip; one still open at
		# quit logs "disconnect a nonexistent connection" errors.
		status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lock_timer = Timer.new()
	_lock_timer.wait_time = VaultLock.LOCK_HEARTBEAT_SEC
	_lock_timer.timeout.connect(VaultLock.refresh_vault_lock)
	add_child(_lock_timer)
	_lock_timer.start()
	_hold_vault_at_start()
	_name_buttons_for_a11y(self)
	get_tree().node_added.connect(_on_node_added_for_a11y)


# ── Session ─────────────────────────────────────────────────────────────────

## On launch: the tutorials on a first run; otherwise the note and the view
## that were open when the app closed (ui.json's last_note / last_mode); a
## note that is gone falls back to the newest note, an unknown view to Edit.
func _open_startup_note() -> void:
	if VaultStore.first_run and VaultStore.get_note_index(FIRST_NOTE) >= 0:
		open_note_by_title(FIRST_NOTE)
		_switch_layer("visual")
		return
	var ui: Dictionary = _read_ui_json()   # read before _open_note saves over it
	_open_last_or_newest(ui)
	var mode: String = str(ui.get("last_mode", ""))
	if layer_buttons.has(mode) and mode != current_mode:
		_switch_layer(mode)


## Open the vault's last open note (from `ui`, its ui.json), else its newest
## note, else the empty state. `keep_graph`: Graph view stays (_open_note).
func _open_last_or_newest(ui: Dictionary, keep_graph: bool = false) -> void:
	var rel: String = str(ui.get("last_note", ""))
	var last: ContentLayer = _note_at_path(VaultStore.vault_path + rel) if rel != "" else null
	if last != null:
		_open_note(last, keep_graph)
	elif VaultStore.note_list.size() > 0:
		_open_note(VaultStore.note_list[0], keep_graph)
	else:
		_show_empty_state()


## Remember the open note (vault-relative) and view in ui.json, for the next
## launch. Called whenever either changes, or the note's file moves.
func _save_session() -> void:
	_save_ui({"last_note": _vault_rel_path(current_note), "last_mode": current_mode})


## "Folder/note.tres" for a note in the open vault; "" for none.
static func _vault_rel_path(note: ContentLayer) -> String:
	if note == null or not note.resource_path.begins_with(VaultStore.vault_path):
		return ""
	return note.resource_path.substr(VaultStore.vault_path.length())


# ── Layout ──────────────────────────────────────────────────────────────────

func _update_readable_width() -> void:
	# Center the document in a readable column (Obsidian's "readable line length")
	var side: int = int(max(40.0, (_editor_width() - READABLE_WIDTH) / 2.0))
	note_content.add_theme_constant_override("margin_left", side)
	note_content.add_theme_constant_override("margin_right", side)


## The width the editor is given: from the content panel's left edge to the
## window's right edge. Not content_panel.size.x alone, which grows with its
## children's minimum size: margins derived from it widened the panel they
## were derived from, a runaway layout (a 4-tag note crashed at 820 px).
func _editor_width() -> float:
	var to_window_edge: float = get_viewport_rect().size.x - content_panel.global_position.x
	return min(content_panel.size.x, to_window_edge)


func _show_empty_state() -> void:
	current_note = null
	VaultStore.editor_note = null
	breadcrumb.text = _vault_name()
	note_meta.text = ""
	word_count_label.text = ""
	delete_btn.disabled = true
	_update_star_pin_buttons()
	_update_tag_bar()
	_update_conflict_bar()
	graph_layer.visible = current_mode == "graph"
	note_content.visible = false
	empty_state_panel.visible = current_mode not in ["graph", "journey"]


# ── Theme ───────────────────────────────────────────────────────────────────

func _apply_theme(is_dark: bool) -> void:
	theme = AppTheme.build(is_dark)
	_palette_colors = AppTheme.palette(is_dark)
	if theme_btn != null:
		theme_btn.text = ""
		theme_btn.icon = Icons.get_icon("moon" if is_dark else "sun")
		theme_btn.tooltip_text = "Switch to the light theme" if is_dark else "Switch to the dark theme"
		theme_btn.accessibility_description = theme_btn.tooltip_text
	if _palette_overlay != null:
		_palette_overlay.color = _palette_colors.dim
	if is_inside_tree() and current_mode in ["structured", "visual"]:
		LayerEngine.set_mode(current_mode)
	if graph_layer != null:
		graph_layer.dark_mode = is_dark
		graph_layer.queue_redraw()
	_update_star_pin_buttons()   # their "on" tint is the theme's accent


## The sun / moon button: dark ⇄ light. While following the system it
## switches to the opposite of what the system shows now.
func _toggle_theme() -> void:
	_set_theme_pref("light" if _is_dark_mode else "dark")


## Remember the choice ("dark", "light" or "system") and repaint.
func _set_theme_pref(pref: String) -> void:
	UiScale.set_theme(pref)
	_theme_pref = UiScale.theme
	_is_dark_mode = UiScale.is_dark(_theme_pref)
	_apply_theme(_is_dark_mode)
	_build_tag_chips()   # the tag dots take this theme's tag palette
	_build_tag_sidebar()
	var look: String = "dark" if _is_dark_mode else "light"
	_update_status("Theme: follows the system (%s)" % look if _theme_pref == "system" else "Theme: " + look)


func _on_system_theme_changed() -> void:
	if _theme_pref == "system" and UiScale.is_dark("system") != _is_dark_mode:
		_is_dark_mode = not _is_dark_mode
		_apply_theme(_is_dark_mode)


# ── Note list ───────────────────────────────────────────────────────────────

func _refresh_note_list() -> void:
	"""Rebuild the sidebar: folders (real directories) with their notes, or a
	flat list of matches while words are searched. A tag filter — set by
	clicking a row in the TAGS section, or "#…" tokens typed in the search
	box — narrows either to the notes carrying it."""
	refresh_count += 1
	_listed_key = _row_key(current_note)
	var was_focused: Dictionary = _focused_row()   # a rebuild must not drop the keyboard
	for child in note_list_container.get_children():
		note_list_container.remove_child(child)
		child.queue_free()
	_visible_notes.clear()
	_note_buttons.clear()
	_folder_buttons.clear()
	_section_rows.clear()
	_search_hits.clear()
	var query: Dictionary = _parse_search(search_box.text)
	_apply_search_tags(query.tags)
	_drop_stale_tag_filter()
	var words: String = query.words
	if words != "":
		for hit in VaultStore.search(words):
			_add_search_result_row(hit)
	else:
		var by_folder: Dictionary = {}
		for note in VaultStore.note_list:
			if not _note_matches_tag_filter(note):
				continue
			var f: String = VaultStore.folder_of(note)
			if not by_folder.has(f):
				by_folder[f] = []
			by_folder[f].append(note)
		_add_star_pin_sections()
		_add_folder_contents("", 0, by_folder)
	var total: int = VaultStore.note_list.size()
	note_count_label.text = str(total) if words == "" and _active_tag_filter == "" else "%d / %d" % [_visible_notes.size(), total]
	_build_tag_sidebar()
	_update_unreadable_row()
	_add_sidebar_empty_state(words)
	_link_row_focus()
	_refocus_row(was_focused)


## Split the search box's text into its "#…" tokens (normalized tags, any
## empty one dropped) and its plain words: "#tutorial quiz" ->
## {tags: ["tutorial"], words: "quiz"}.
func _parse_search(text: String) -> Dictionary:
	var tags: Array[String] = []
	var words: PackedStringArray = []
	for token in text.strip_edges().replace("\t", " ").split(" ", false):
		if not token.begins_with("#"):
			words.append(token)
			continue
		var tag: String = TagOps.normalize(token)
		if tag != "" and not tag in tags:
			tags.append(tag)
	return {"tags": tags, "words": " ".join(words)}


## "#…" tokens in the search box own the tag filter: every one must start a
## tag of the note (a live prefix while the user types). With none, erasing
## a "#…" search clears the filter it set, while a filter set by a TAGS row
## or a chip stays: it combines with typed words and survives an empty box.
func _apply_search_tags(tags: Array[String]) -> void:
	if not tags.is_empty():
		_search_tags = tags
		_active_tag_filter = tags[0]
		_tag_filter_applied_from_search = true
	elif _tag_filter_applied_from_search:
		_search_tags = []
		_active_tag_filter = ""
		_tag_filter_applied_from_search = false


# ── Sidebar empty states ────────────────────────────────────────────────────

## Why the sidebar lists no notes, given the plain words searched for:
## "search" (nothing matches them), "filtered" (notes match them, but the
## tag filter hides those), "vault" (no notes at all), "tag" (no note
## carries the filter's tag) or "" (there are rows to show).
func _sidebar_empty_kind(words: String) -> String:
	if words != "" and _visible_notes.is_empty():
		if _active_tag_filter != "" and not VaultStore.search(words).is_empty():
			return "filtered"
		return "search"
	if VaultStore.note_list.is_empty():
		return "vault"
	if _active_tag_filter != "" and not VaultStore.note_list.any(_note_matches_tag_filter):
		return "tag"
	return ""


## Under the rows, a hint (SidebarEmpty) that says why the list is empty
## and offers the way on: a new note, a note named after the search, or
## clearing the search or the tag filter.
func _add_sidebar_empty_state(words: String) -> void:
	var kind: String = _sidebar_empty_kind(words)
	if kind == "":
		return
	var hint := VBoxContainer.new()
	hint.name = "SidebarEmpty"
	hint.focus_mode = Control.FOCUS_NONE
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_constant_override("separation", 2)
	match kind:
		"search":
			_add_empty_label(hint, "No notes match \u201c%s\u201d" % words)
			_add_empty_action(hint, "Create \u201c%s\u201d" % words, "Create a note titled \u201c%s\u201d" % words,
				_create_note_from_search.bind(words))
			_add_empty_action(hint, "Clear search", "Clear the search", _clear_search)
		"filtered":   # no Create: a note of that name may exist, outside the filter
			_add_empty_label(hint, "No notes tagged #%s match \u201c%s\u201d" % [_active_tag_filter, words])
			_add_empty_action(hint, "Clear filter", "Clear the tag filter", _clear_tag_filter)
		"vault":
			_add_empty_label(hint, "No notes yet")
			_add_empty_action(hint, "+ New note (Ctrl+N)", "New note", _on_new_note_pressed)
		"tag":
			_add_empty_label(hint, "No notes tagged #%s" % _active_tag_filter)
			_add_empty_action(hint, "Clear filter", "Clear the tag filter", _clear_tag_filter)
	note_list_container.add_child(hint)


func _add_empty_label(hint: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.theme_type_variation = &"MutedLabel"
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var pad := StyleBoxEmpty.new()   # lines up with the buttons' text below
	pad.content_margin_left = 8
	pad.content_margin_right = 8
	pad.content_margin_top = 8
	pad.content_margin_bottom = 2
	label.add_theme_stylebox_override("normal", pad)
	hint.add_child(label)


## A FlatButton that trims a long label (the full text is its tooltip), so a
## long search never widens the sidebar.
func _add_empty_action(hint: VBoxContainer, text: String, name_for_a11y: String, action: Callable) -> void:
	var btn := Button.new()
	btn.theme_type_variation = &"FlatButton"
	btn.text = text
	btn.tooltip_text = text
	btn.accessibility_name = name_for_a11y
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.clip_text = true
	btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.pressed.connect(action)
	hint.add_child(btn)


## The no-match hint's Create: a note titled with the search, at the top
## level, open in Edit view. A title another note has (ignoring case, as a
## rename refuses it) opens that note instead: links, progress and the
## Journey find notes by title. A file that can't be written says so.
func _create_note_from_search(title: String) -> void:
	_flush_pending_save()
	if not VaultStore.shared_title(title):
		for n in VaultStore.note_list:
			if n.title.strip_edges().to_lower() == title.strip_edges().to_lower():
				search_box.text = ""
				_refresh_note_list()
				_open_note(n)
				_update_status("\u201c%s\u201d already exists" % _display_title(n))
				return
	var held: ContentLayer = current_note
	var note: ContentLayer = VaultStore.create_note(title)
	if note == null:
		_report_create_failed("\u201c%s\u201d" % title)
		return
	_take_own_change(held)
	search_box.text = ""
	_refresh_note_list()
	_open_note(note)
	if current_mode != "raw":
		_switch_layer("raw")
	raw_text_layer.grab_focus()
	_update_status("Created \u201c%s\u201d" % title)


func _clear_search() -> void:
	search_box.text = ""
	_refresh_note_list()
	search_box.grab_focus()


## True when the note passes the active tag filter: an exact tag when a row
## in the TAGS section set it, a prefix of one of its tags for each "#…"
## token in the search box. The filter is normalized (TagOps), and so is
## each stored tag before the compare: "Physics" matches #physics.
func _note_matches_tag_filter(note: ContentLayer) -> bool:
	if _tag_filter_applied_from_search:
		return _search_tags.all(func(want: String) -> bool: return TagOps.has_prefix(note, want))
	return _active_tag_filter == "" or TagOps.has(note, _active_tag_filter)


## True while `tag` filters the list, so its TAGS row and chip show pressed:
## the row or chip filter, or any whole tag typed after a '#' in the search.
func _is_filtering_by(tag: String) -> bool:
	return tag == _active_tag_filter or (_tag_filter_applied_from_search and tag in _search_tags)


## A row-set filter whose tag is on no note any more (taken off its last
## note, the note deleted, an outside or MCP edit) would leave an empty list
## with the TAGS section, and its ×, hidden: drop it. A "#…" search keeps
## its filter, since the search box shows it and clears it.
func _drop_stale_tag_filter() -> void:
	if _active_tag_filter == "" or _tag_filter_applied_from_search:
		return
	if not VaultStore.note_list.any(func(n: ContentLayer) -> bool: return TagOps.has(n, _active_tag_filter)):
		_active_tag_filter = ""


## Under a tag filter a folder with no matching note (in it or below it) is
## left out, subtree and all, so the list shows only where the matches are.
func _tag_filter_hides_folder(match_count: int) -> bool:
	return _active_tag_filter != "" and match_count == 0


## Subfolders first (alphabetical), then the folder's notes (newest first).
func _add_folder_contents(rel: String, depth: int, by_folder: Dictionary) -> void:
	for f in VaultStore.folders:
		if f.get_base_dir() == rel:
			var count: int = _count_notes(f, by_folder)
			if _tag_filter_hides_folder(count):
				continue
			note_list_container.add_child(_make_folder_item(f, depth, count))
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
	if not _note_matches_tag_filter(note):
		return
	_visible_notes.append(note)
	var btn: Button = _make_note_item(note)
	_indent(btn, &"NoteItem", depth, 22 if depth > 0 else 0)
	_note_buttons[note] = btn
	note_list_container.add_child(btn)


## A search result (VaultStore.search, best first): the note's usual row, so
## clicks, drag and the context menu work as ever, with the faint excerpt of
## its first matching line under the title. Pressing it opens the note at
## the match. The tag filter applies here too.
func _add_search_result_row(hit: Dictionary) -> void:
	var note: ContentLayer = hit.note
	_add_note_row(note, 0)
	if not _note_buttons.has(note):
		return
	_search_hits[note] = hit
	var btn: Button = _note_buttons[note]
	btn.pressed.connect(_reveal_search_hit.bind(hit))   # runs after _open_note, connected first
	if hit.excerpt != "":
		btn.theme_type_variation = &"SearchResultItem"
		btn.add_child(_make_excerpt_label(btn, _short_excerpt(hit)))


## A hit's excerpt starting at most EXCERPT_LEAD characters before the
## match, so the matched word shows in a narrow row before the "…".
func _short_excerpt(hit: Dictionary) -> String:
	var at: int = str(hit.excerpt).to_lower().find(hit.word)
	if at <= EXCERPT_LEAD:
		return hit.excerpt
	return VaultStore.excerpt(hit.excerpt, at, str(hit.word).length(), EXCERPT_LEAD, str(hit.excerpt).length())


## The excerpt line, laid in the room the SearchResultItem style leaves
## under the title, inset like the title. Clicks go through to the row.
func _make_excerpt_label(row: Button, text: String) -> Label:
	var box: StyleBox = row.get_theme_stylebox("normal")
	var label := Label.new()
	label.name = "Excerpt"
	label.theme_type_variation = &"FaintLabel"
	label.text = text
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	label.offset_left = box.content_margin_left
	label.offset_right = -box.content_margin_right
	label.offset_bottom = -box.content_margin_top   # the title's top margin, mirrored below
	label.offset_top = label.offset_bottom - AppTheme.EXCERPT_HEIGHT
	return label


## Put the note just opened from a search result on its match: the caret on
## the matched word (Edit view shows it; the other views keep it for Edit),
## and in Read or Outline view the first rendered line holding the word
## scrolled into sight. A title-only match (line -1) leaves the note as is.
func _reveal_search_hit(hit: Dictionary) -> void:
	if current_note != hit.note or int(hit.line) < 0:
		return
	raw_text_layer.set_caret_line(hit.line)
	raw_text_layer.set_caret_column(hit.col)
	raw_text_layer.center_viewport_to_caret.call_deferred()
	if doc_scroll.visible:
		await _scroll_doc_to_word(hit.note, hit.word, int(hit.line))


## Scroll the Read or Outline view so the first rendered line holding `word`
## sits near its top, once the note's lines have their size. A long note's
## Read view still being built is built through source line `source_line`
## first (LayerEngine.finish_visual), and in a label that merges several
## paragraphs the scroll goes to the word's own line (_word_offset).
func _scroll_doc_to_word(note: ContentLayer, word: String, source_line: int = -1) -> void:
	if current_mode == "visual":
		LayerEngine.finish_visual(source_line)
	await get_tree().process_frame
	await get_tree().process_frame
	if current_note != note or not doc_scroll.visible:
		return
	var line: Control = _first_line_holding(visual_layer if current_mode == "visual" else structured_layer, word)
	if line != null:
		var below_top: float = line.get_global_rect().position.y + _word_offset(line, word) - doc_scroll.get_global_rect().position.y
		doc_scroll.scroll_vertical += int(below_top - 24.0)   # a little of what comes before stays in view


## How far below the top of `row` the first line showing `word` (lowercase)
## starts: 0 for a Label, the wrapped line's offset in a RichTextLabel (a
## Read view label can hold many paragraphs).
static func _word_offset(row: Control, word: String) -> float:
	var rtl := row as RichTextLabel
	if rtl == null:
		return 0.0
	var at: int = rtl.get_parsed_text().to_lower().find(word)
	var l: int = rtl.get_character_line(at) if at >= 0 else -1
	return rtl.get_line_offset(l) if l >= 0 else 0.0


## The first Label or RichTextLabel under `root` whose shown text holds
## `word` (lowercase), or null.
func _first_line_holding(root: Node, word: String) -> Control:
	for c in root.find_children("*", "Control", true, false):
		var text: String = ""
		if c is Label:
			text = (c as Label).text
		elif c is RichTextLabel:
			text = (c as RichTextLabel).get_parsed_text()
		if text.to_lower().contains(word):
			return c
	return null


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
	btn.accessibility_name = "Folder %s, %d note%s, %s" % [rel.get_file(), count, "" if count == 1 else "s", "collapsed" if _collapsed.has(rel) else "expanded"]
	btn.add_theme_color_override("font_color", _palette_colors.get("text", Color.WHITE))
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		btn.add_theme_color_override(state, _palette_colors.get("text_faint", Color.GRAY))
	btn.add_theme_font_size_override("font_size", 13)
	_indent(btn, &"NoteItem", depth)
	btn.pressed.connect(_toggle_folder.bind(rel))
	var target: Dictionary = {"type": "folder", "rel": rel}
	btn.set_meta(&"sidebar_row", target)   # for the keyboard (_sidebar_rows)
	btn.gui_input.connect(_on_row_gui_input.bind(target))
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


# ── Pinned and Starred sections (above the folders) ─────────────────────────

## A collapsible "Pinned (N)" and then "Starred (N)" section above the
## folders, listing the flagged notes that pass the tag filter, newest flag
## first; N counts the rows shown, and a section with none has no header.
## A note keeps its folder row too, so section rows stay out of
## _note_buttons (one row per note), _note_group (it lets one row be
## pressed, and both of a note's rows must be) and _visible_notes (the
## "x / y" count, search-submit). _section_rows tracks them instead.
func _add_star_pin_sections() -> void:
	for section in SECTIONS:
		var notes: Array[ContentLayer] = _section_notes(SECTIONS[section])
		if notes.is_empty():
			continue
		note_list_container.add_child(_make_section_header(section, notes.size()))
		if _sections_collapsed.has(section):
			continue
		for note in notes:
			# readable names: PinnedRow, PinnedRow2… (not @Button@123)
			note_list_container.add_child(_make_section_row(note, section), true)


## The notes with `field` set that pass the tag filter, newest first; a
## same-second tie falls back to modified, as the note list does.
func _section_notes(field: StringName) -> Array[ContentLayer]:
	var notes: Array[ContentLayer] = []
	for note in VaultStore.note_list:
		if str(note.get(field)) != "" and _note_matches_tag_filter(note):
			notes.append(note)
	notes.sort_custom(func(a: ContentLayer, b: ContentLayer) -> bool:
		var at: String = a.get(field)
		var bt: String = b.get(field)
		if at != bt:
			return at > bt
		if a.modified != b.modified:
			return a.modified > b.modified
		return a.resource_path < b.resource_path)
	return notes


## A section header, styled like a folder row: chevron, "Pinned (3)".
func _make_section_header(section: String, count: int) -> Button:
	var btn := Button.new()
	btn.name = section.capitalize() + "Header"
	btn.theme_type_variation = &"NoteItem"
	btn.text = "%s (%d)" % [section.capitalize(), count]
	btn.icon = Icons.get_icon("chevron_right" if _sections_collapsed.has(section) else "chevron_down")
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.clip_text = true
	btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.tooltip_text = "%s notes, newest first  ·  click to %s" % [
		section.capitalize(), "expand" if _sections_collapsed.has(section) else "collapse"]
	btn.add_theme_color_override("font_color", _palette_colors.get("text", Color.WHITE))
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		btn.add_theme_color_override(state, _palette_colors.get("text_faint", Color.GRAY))
	btn.add_theme_font_size_override("font_size", 13)
	btn.pressed.connect(_toggle_section.bind(section))
	return btn


## A note's row in a section, one level in. It opens that note object (never
## a title lookup: two notes may share a title) and has the note's
## right-click menu, but is no drag source: the folder row moves notes.
func _make_section_row(note: ContentLayer, section: String) -> Button:
	var btn: Button = _make_note_button(note)
	btn.name = section.capitalize() + "Row"
	btn.set_meta(&"note", note)
	_indent(btn, &"NoteItem", 1, 22)
	_section_rows.append(btn)
	return btn


func _toggle_section(section: String) -> void:
	if _sections_collapsed.has(section):
		_sections_collapsed.erase(section)
	else:
		_sections_collapsed[section] = true
	_save_collapsed()
	_refresh_note_list()


func _make_note_item(note: ContentLayer) -> Button:
	var btn: Button = _make_note_button(note, _note_group)
	btn.set_drag_forwarding(
		func(_p: Vector2) -> Variant: return _start_drag({"type": "note", "note": note}, _display_title(note)),
		func(_p: Vector2, data: Variant) -> bool: return _can_drop(data, VaultStore.folder_of(note)),
		func(_p: Vector2, data: Variant) -> void: _drop(data, VaultStore.folder_of(note)))
	return btn


## A sidebar row that opens `note`: its title, quiz-status icon and
## right-click menu. Pressed while the note is open.
func _make_note_button(note: ContentLayer, group: ButtonGroup = null) -> Button:
	var btn := Button.new()
	btn.theme_type_variation = &"NoteItem"
	btn.toggle_mode = true
	btn.button_group = group
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
	var target: Dictionary = {"type": "note", "note": note}
	btn.set_meta(&"sidebar_row", target)   # for the keyboard (_sidebar_rows)
	btn.gui_input.connect(_on_row_gui_input.bind(target))
	return btn


## ✓ = every quiz in the note passed; ● = missed a question about it.
func _apply_status_icon(btn: Button, note: ContentLayer) -> void:
	var preview: String = note.raw_text.strip_edges().replace("\n", " ")
	var tip: String = preview.substr(0, 140) if preview != "" else "Empty note"
	var folder: String = VaultStore.folder_of(note)
	if folder != "":
		tip = folder + "/\n\n" + tip
	var status: String = ProgressStore.note_status(note)
	match status:
		"done":
			btn.icon = ProgressStore.icon("done")
			btn.tooltip_text = "✓ Complete — every quiz passed\n\n" + tip
		"review":
			btn.icon = ProgressStore.icon("review")
			btn.tooltip_text = "● Worth a review — you missed a question about this note\n\n" + tip
		_:
			btn.icon = null
			btn.tooltip_text = tip
	_name_note_row(btn, note, status)


## A note row reads as its title, plus its quiz status when it has one.
func _name_note_row(btn: Button, note: ContentLayer, status: String = "") -> void:
	var said: Dictionary = {"done": ", complete", "review": ", worth a review"}
	btn.accessibility_name = _display_title(note) + str(said.get(status, ""))
	var folder: String = VaultStore.folder_of(note)
	btn.accessibility_description = "In " + folder if folder != "" else ""


## Called by quiz cards whenever an answer or result is saved.
func on_progress_changed() -> void:
	LayerEngine.mark_visual_stale()   # link marks and the review banner change
	for note in _note_buttons:
		_apply_status_icon(_note_buttons[note], note)
	for btn in _section_rows:
		_apply_status_icon(btn, btn.get_meta(&"note"))


func _sync_list_selection() -> void:
	for note in _note_buttons:
		var btn: Button = _note_buttons[note]
		btn.set_pressed_no_signal(note == current_note)
		btn.text = _display_title(note)
		_name_note_row(btn, note, ProgressStore.note_status(note))
	for btn in _section_rows:
		var note: ContentLayer = btn.get_meta(&"note")
		btn.set_pressed_no_signal(note == current_note)
		btn.text = _display_title(note)
		_name_note_row(btn, note, ProgressStore.note_status(note))


func _display_title(note: ContentLayer) -> String:
	var t: String = note.title.strip_edges()
	return "Untitled" if t == "" or t == "untitled" else t


func _on_search_changed(_text: String) -> void:
	_refresh_note_list()


## Enter in the search box opens the top result, at its match.
func _on_search_submitted(_text: String) -> void:
	if _visible_notes.is_empty():
		return
	var note: ContentLayer = _visible_notes[0]
	_open_note(note)
	raw_text_layer.grab_focus()
	if _search_hits.has(note):
		_reveal_search_hit(_search_hits[note])


# ── Keyboard in the sidebar ─────────────────────────────────────────────────
# Ctrl+Shift+E (Cmd on a Mac) puts the keyboard on the note list. On a row:
# Up / Down move between the folder and note rows, Enter opens a note (or
# folds a folder), Right expands a folder, Left folds it or goes up to the
# parent folder, Delete (Backspace on a Mac) asks, then deletes the note or
# trashes the folder, F2 renames, Shift+F10 or the Menu key opens the row's
# menu, Escape goes back to the note. Down in the search box moves into the
# results.

## The folder and note rows of the sidebar, top to bottom.
func _sidebar_rows() -> Array[Button]:
	var rows: Array[Button] = []
	for c in note_list_container.get_children():
		if c is Button and c.has_meta(&"sidebar_row") and not c.is_queued_for_deletion():
			rows.append(c)
	return rows


## Up / Down walk the rows only: each row's neighbours are the rows above and
## below it, and the two ends point at themselves, so the focus never wanders
## into the TAGS section, the search box or the toolbar.
func _link_row_focus() -> void:
	var rows: Array[Button] = _sidebar_rows()
	for i in range(rows.size()):
		rows[i].focus_neighbor_top = rows[i].get_path_to(rows[maxi(i - 1, 0)])
		rows[i].focus_neighbor_bottom = rows[i].get_path_to(rows[mini(i + 1, rows.size() - 1)])


## The row that has the keyboard: its target and its place in the list ({}
## when no row has it).
func _focused_row() -> Dictionary:
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus == null or focus.get_parent() != note_list_container or not focus.has_meta(&"sidebar_row"):
		return {}
	return {"target": focus.get_meta(&"sidebar_row"), "index": _sidebar_rows().find(focus)}


## After a rebuild, the keyboard goes back to the same row (a folder by its
## path, a note by itself), or to the row now in its place when it is gone.
func _refocus_row(was: Dictionary) -> void:
	if was.is_empty():
		return
	var rows: Array[Button] = _sidebar_rows()
	var row: Button = _row_for(was.target)
	if row == null and not rows.is_empty():
		row = rows[clampi(int(was.index), 0, rows.size() - 1)]
	if row != null:
		row.grab_focus()


func _row_for(target: Dictionary) -> Button:
	if target.get("type") == "folder":
		return _folder_buttons.get(target.rel)
	return _note_buttons.get(target.get("note"))


## Ctrl+Shift+E: the open note's row, or the first row when the note is
## folded away or filtered out.
func _focus_note_list() -> void:
	var rows: Array[Button] = _sidebar_rows()
	if rows.is_empty():
		_update_status("The note list is empty")
		return
	var row: Button = _note_buttons.get(current_note, rows[0])
	row.grab_focus()


## Down in the search box: into the results, on the first one (Enter there
## opens it; Enter in the box itself still opens the first match).
func _on_search_gui_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.keycode != KEY_DOWN or _cmd(k) or k.alt_pressed or k.shift_pressed:
		return
	var rows: Array[Button] = _sidebar_rows()
	if not rows.is_empty():
		rows[0].grab_focus()
		search_box.accept_event()


## A key on a focused row. True when the key was the row's to handle.
func _on_row_key(k: InputEventKey, target: Dictionary) -> bool:
	if _cmd(k) or k.alt_pressed:
		return false   # Ctrl+N, Alt+Left and the like belong to the whole app
	if k.shift_pressed:
		if k.keycode != KEY_F10:
			return false
		if not k.echo:
			_show_ctx(target, _row_for(target))
		return true
	if k.keycode == KEY_F2 and target.type == "note":
		# F2 on a note is the app's one Rename prompt (gap-sidebar-rename, in
		# _unhandled_input), which renames the open note: open this row's note
		# and leave the key to it.
		if not k.echo and target.note != current_note:
			_open_note(target.note)
		return false
	var keys: Array[Key] = [KEY_ENTER, KEY_KP_ENTER, KEY_LEFT, KEY_RIGHT, KEY_DELETE, KEY_F2, KEY_MENU, KEY_ESCAPE]
	if backspace_deletes_rows:
		keys.append(KEY_BACKSPACE)
	if k.keycode not in keys:
		return false
	if k.echo and k.keycode not in [KEY_LEFT, KEY_RIGHT]:
		return true   # a held Delete or Enter acts once
	var folder: bool = target.type == "folder"
	match k.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			if folder:
				_toggle_folder(target.rel)
			else:
				var hit: Dictionary = _search_hits.get(target.note, {})
				_open_note(target.note)
				if not hit.is_empty():
					_reveal_search_hit(hit)   # a search result opens at its match, as a click does (the row's pressed never fires here)
		KEY_RIGHT:
			if folder:
				_expand_or_enter(target.rel)
		KEY_LEFT:
			_fold_or_go_up(target)
		KEY_DELETE, KEY_BACKSPACE:
			if folder:
				_run_row_menu(target, 4)   # "Move to trash…", which asks first
			else:
				_confirm_delete_note(target.note)
		KEY_F2:
			_run_row_menu(target, 2)   # a folder's "Rename…" (a note's F2 returned above)
		KEY_MENU:
			_show_ctx(target, _row_for(target))
		KEY_ESCAPE:
			_leave_note_list()
	return true


## Right on a folder: expand it; on an expanded one, go to its first row.
func _expand_or_enter(rel: String) -> void:
	if _collapsed.has(rel):
		_toggle_folder(rel)
		return
	var rows: Array[Button] = _sidebar_rows()
	var i: int = rows.find(_folder_buttons.get(rel))
	if i >= 0 and i + 1 < rows.size() and _row_parent(rows[i + 1].get_meta(&"sidebar_row")) == rel:
		rows[i + 1].grab_focus()


## Left: fold an expanded folder; otherwise go up to the parent folder's row.
func _fold_or_go_up(target: Dictionary) -> void:
	if target.type == "folder" and not _collapsed.has(target.rel):
		_toggle_folder(target.rel)
		return
	var parent: Button = _folder_buttons.get(_row_parent(target))
	if parent != null:
		parent.grab_focus()


## The folder a row sits in ("" = the top level).
func _row_parent(target: Dictionary) -> String:
	if target.get("type") == "folder":
		return str(target.rel).get_base_dir()
	return VaultStore.folder_of(target.get("note"))


## Delete on a note row: one key press never deletes a note on its own. A
## question names the note; its Delete button does what the row menu's
## "Delete note" does, and Escape keeps the note.
func _confirm_delete_note(note: ContentLayer) -> void:
	var path: String = note.resource_path
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = "Delete the note “%s”?" % _display_title(note)
	dlg.ok_button_text = "Delete"
	add_child(dlg)
	dlg.confirmed.connect(func() -> void:
		var live: ContentLayer = _note_at_path(path)   # the list may have reloaded meanwhile
		if live != null:
			_run_row_menu({"type": "note", "note": live}, 13))
	dlg.visibility_changed.connect(func() -> void:
		if not dlg.visible:
			dlg.queue_free())
	dlg.popup_centered()


## Do what the row's right-click menu entry `id` does.
func _run_row_menu(target: Dictionary, id: int) -> void:
	_ctx_target = target
	_on_ctx_menu(id)


## Escape: back to the editor in Edit view; in the other views the list just
## lets go of the keyboard.
func _leave_note_list() -> void:
	if raw_text_layer.is_visible_in_tree():
		raw_text_layer.grab_focus()
	else:
		var focus: Control = get_viewport().gui_get_focus_owner()
		if focus != null:
			focus.release_focus()


# ── Opening / editing notes ─────────────────────────────────────────────────

## `keep_graph`: the disk watcher (or a rename that rewrote the note's own
## links) reloads the open note behind an open graph, which must not leave it
## for the editor the way a user's pick does.
func _open_note(note: ContentLayer, keep_graph: bool = false) -> void:
	if note == null:
		return
	if current_note != null and current_note != note:
		_flush_pending_save()
		# A title typed into the field, which still has the keyboard: a Read
		# view [[link]] or a graph node takes no focus, so focus_exited never
		# committed it, and _show_title below would drop it
		_commit_typed_title()
	_close_link_popup()
	current_note = note
	_listed_key = _row_key(note)   # only the open note is edited, so the rows show it as it is
	VaultStore.editor_note = note   # rescans leave its text to the editor; the watcher reloads it
	if not _navigating:
		_nav.push(note.resource_path)
	_loading = true
	_show_title(note)
	LayerEngine.set_note(note)
	raw_text_layer.text = note.raw_text
	raw_text_layer.clear_undo_history()
	_loading = false
	breadcrumb.text = _crumb(note)
	note_meta.text = _format_meta(note)
	delete_btn.disabled = false
	_update_star_pin_buttons()
	_update_tag_bar()
	_update_conflict_bar()
	_update_word_count()
	_sync_list_selection()
	if current_mode == "graph":
		if not keep_graph:
			_switch_layer("raw")
	elif current_mode == "journey":
		_switch_layer("visual")
	else:
		empty_state_panel.visible = false
		note_content.visible = true
	_save_session()
	_update_status(_with_unsaved("Opened " + _display_title(note)))


func _format_meta(note: ContentLayer) -> String:
	var parts: PackedStringArray = []
	if note.modified != "":
		parts.append("Edited " + note.modified.replace("T", "  "))
	var tags: Array[String] = TagOps.normalize_list(note.tags)
	if tags.size() > 0:
		parts.append("#" + " #".join(tags))
	return "   ·   ".join(parts)


# ── Tags (part 1: per-note storage + the TagBar below the title) ────────────

func _update_tag_bar() -> void:
	_hide_tag_suggestions()
	if current_note == null:
		tag_bar.visible = false
		return
	tag_bar.visible = true
	_build_tag_chips()


func _build_tag_chips() -> void:
	for c in tag_chips.get_children():
		c.queue_free()
	var tags: Array[String] = TagOps.normalize_list(current_note.tags) if current_note != null else []
	for tag in tags:
		tag_chips.add_child(_make_tag_chip(tag))
	tag_chips.visible = tags.size() > 0


## One pill per tag with two targets: the "#tag" body toggles the sidebar
## filter by the tag (pressed while it is the filter), the × removes the tag
## from the note. The pill's look comes from the TagChip / TagChipActive
## variations; _sync_tag_chips keeps it on the active filter.
func _make_tag_chip(tag: String) -> PanelContainer:
	var body := Button.new()
	body.name = "Body"
	body.theme_type_variation = &"TagChipBody"
	body.toggle_mode = true
	body.text = "#" + _chip_label(tag)
	body.tooltip_text = "Show only the notes tagged #%s — press again to clear" % tag
	body.accessibility_name = "Filter by tag #" + tag
	body.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_show_tag_dot(body, tag)
	body.pressed.connect(_on_tag_chip_clicked.bind(tag))
	var remove := Button.new()
	remove.name = "Remove"
	remove.theme_type_variation = &"TagChipRemove"
	remove.icon = Icons.get_icon("close", 10)
	remove.tooltip_text = "Remove #" + tag
	remove.accessibility_name = "Remove tag #" + tag
	remove.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	remove.pressed.connect(_remove_tag.bind(tag))
	var parts := HBoxContainer.new()
	parts.add_theme_constant_override("separation", 0)
	parts.add_child(body)
	parts.add_child(remove)
	var chip := PanelContainer.new()
	chip.name = "TagChip"
	chip.set_meta(&"tag", tag)
	chip.add_child(parts)
	_show_chip_filter_state(chip)
	return chip


## Press the chip whose tag is the active filter, release the others. Runs
## on every note-list rebuild (via _build_tag_sidebar), so the chips follow a
## filter set anywhere: a chip, a TAGS row, its ×, a vault switch.
func _sync_tag_chips() -> void:
	for chip in tag_chips.get_children():
		if chip.has_meta(&"tag"):
			_show_chip_filter_state(chip)


func _show_chip_filter_state(chip: PanelContainer) -> void:
	var active: bool = _is_filtering_by(str(chip.get_meta(&"tag")))
	chip.theme_type_variation = &"TagChipActive" if active else &"TagChip"
	(chip.find_child("Body", true, false) as Button).set_pressed_no_signal(active)


## `btn` (a chip's body, a TAGS row) shows `tag`'s colour as a dot before
## its text, the same in every button state. A code-drawn icon, not a glyph:
## the fonts lack most symbols. Rebuilt on a theme flip (_toggle_theme).
func _show_tag_dot(btn: Button, tag: String) -> void:
	btn.icon = Icons.get_icon("dot", TAG_DOT_SIZE)
	var color: Color = AppTheme.tag_color(tag, _is_dark_mode)
	for state in [&"icon_normal_color", &"icon_hover_color", &"icon_pressed_color",
			&"icon_hover_pressed_color", &"icon_focus_color", &"icon_disabled_color"]:
		btn.add_theme_color_override(state, color)


## A chip shows at most TAG_CHIP_CHARS of its tag, so one long tag cannot
## force the editor wider; the tooltip carries the whole tag.
func _chip_label(tag: String) -> String:
	return tag if tag.length() <= TAG_CHIP_CHARS else tag.left(TAG_CHIP_CHARS) + "…"


func _on_tag_submitted(_text: String) -> void:
	_add_tag_from_input()


func _add_tag_from_input() -> void:
	if current_note == null:
		tag_input.text = ""
		return
	var tag: String = TagOps.normalize(tag_input.text)
	tag_input.text = ""
	_hide_tag_suggestions()
	if tag == "":
		return
	_add_tag(tag)


## Normalize (TagOps), dedup against the stored tags by their normalized
## form (a "Physics" note gets no second "physics"), append, rebuild the
## chips and the meta line. Persistence rides the regular save path (the
## tags @export on the note's own .tres — no central index). A tag change
## marks the note dirty and starts the auto-save, like a body edit, so the
## tag lands on disk even when the body is untouched.
func _add_tag(raw: String) -> void:
	var tag: String = TagOps.normalize(raw)
	if current_note == null or tag == "" or TagOps.has(current_note, tag):
		return
	_save_note_state()
	current_note.tags.append(tag)
	_build_tag_chips()
	note_meta.text = _format_meta(current_note)
	_editing = true
	_auto_save_timer.start()
	_update_status("Tagged # %s" % tag)


## Remove every stored spelling of `tag` ("Physics" and "physics" alike).
func _remove_tag(tag: String) -> void:
	if current_note == null or not TagOps.has(current_note, tag):
		return
	_save_note_state()
	var keep: Array[String] = []
	for t in current_note.tags:
		if TagOps.normalize(t) != TagOps.normalize(tag):
			keep.append(t)
	current_note.tags = keep
	_build_tag_chips()
	note_meta.text = _format_meta(current_note)
	_editing = true
	_auto_save_timer.start()
	_update_status("Untagged # %s" % tag)


## A chip's body toggles the sidebar filter by its tag; the tags stay put.
func _on_tag_chip_clicked(tag: String) -> void:
	_set_tag_filter("" if tag == _active_tag_filter else tag)


# ── Tags: autocomplete in the TagInput ──────────────────────────────────────

## The vault's tags starting with `text` (normalized, so a leading '#' and the
## case do not matter), minus the open note's own, most used first, then by
## name; at most TAG_SUGGEST_MAX.
func _tag_suggestions_for(text: String) -> Array:
	var prefix: String = TagOps.normalize(text)
	if prefix == "" or current_note == null:
		return []
	var counts: Dictionary = TagOps.counts(VaultStore.note_list)
	var found: Array = counts.keys().filter(func(tag: String) -> bool:
		return tag.begins_with(prefix) and not TagOps.has(current_note, tag))
	TagOps.sort_by_use(found, counts)
	return found.slice(0, TAG_SUGGEST_MAX)


## Refill the suggestion card for the TagInput's text, or hide it when the
## text is empty or nothing matches. Nothing starts highlighted, so Enter
## still adds exactly what was typed.
func _update_tag_suggestions(text: String) -> void:
	var tags: Array = _tag_suggestions_for(text)
	if tags.is_empty():
		_hide_tag_suggestions()
		return
	tag_suggest_list.clear()
	for tag in tags:
		var i: int = tag_suggest_list.add_item("#" + _chip_label(tag))
		tag_suggest_list.set_item_metadata(i, tag)
		tag_suggest_list.set_item_tooltip(i, "#" + tag)
	tag_suggest_list.deselect_all()
	# The ItemList's auto_height minimum is still the old list's until its
	# next draw, and a sized Control never shrinks back to a smaller minimum:
	# measure the new rows now, so the card fits them (and the flip-above
	# check in _place_tag_suggestions sees the real height).
	tag_suggest_list.force_update_list_size()
	tag_suggest.size = Vector2(minf(tag_input.size.x, TAG_SUGGEST_WIDTH), 0.0)   # the rows' height
	tag_suggest.visible = true
	_place_tag_suggestions()


func _hide_tag_suggestions() -> void:
	if tag_suggest != null:
		tag_suggest.visible = false


## Put the card (top_level, so it floats over the editor) under the TagInput,
## or above it when the window has no room below, and inside the window.
func _place_tag_suggestions() -> void:
	if not tag_suggest.visible:
		return
	var anchor: Rect2 = tag_input.get_global_rect()
	var window: Rect2 = get_viewport_rect()
	var card: Vector2 = tag_suggest.size
	var pos := Vector2(anchor.position.x, anchor.end.y + 2.0)
	if pos.y + card.y > window.end.y:
		pos.y = anchor.position.y - card.y - 2.0
	pos.x = clampf(pos.x, window.position.x, maxf(window.position.x, window.end.x - card.x))
	pos.y = maxf(pos.y, window.position.y)
	tag_suggest.global_position = pos


## Keys on the TagInput while the card shows: Down/Up move the highlight,
## Enter or Tab take the highlighted tag, Esc closes the card. Enter with
## nothing highlighted goes on to the LineEdit, which adds the typed text;
## Tab with nothing highlighted moves the focus on as usual.
func _on_tag_input_gui_input(event: InputEvent) -> void:
	if not tag_suggest.visible or not (event is InputEventKey and event.pressed):
		return
	var k: InputEventKey = event as InputEventKey
	match k.keycode:
		KEY_DOWN:
			_move_tag_suggestion(1)
		KEY_UP:
			_move_tag_suggestion(-1)
		KEY_ENTER, KEY_KP_ENTER, KEY_TAB:
			var picked: PackedInt32Array = tag_suggest_list.get_selected_items()
			if picked.is_empty() or k.echo:
				return
			_accept_tag_suggestion(picked[0])
		KEY_ESCAPE:
			_hide_tag_suggestions()
		_:
			return
	tag_input.accept_event()


## Move the highlight by `step`. Up from the first row clears it (Enter then
## adds the typed text); Up with none highlighted goes to the last row.
func _move_tag_suggestion(step: int) -> void:
	var count: int = tag_suggest_list.item_count
	var picked: PackedInt32Array = tag_suggest_list.get_selected_items()
	var current: int = picked[0] if not picked.is_empty() else -1
	var next: int = count - 1 if current == -1 and step < 0 else mini(current + step, count - 1)
	if next < 0:
		tag_suggest_list.deselect_all()
	else:
		tag_suggest_list.select(next)
		tag_suggest_list.ensure_current_is_visible()


func _on_tag_suggestion_clicked(index: int, _at: Vector2, button: int) -> void:
	if button == MOUSE_BUTTON_LEFT:
		_accept_tag_suggestion(index)
		_tag_suggest_clicked = true


## A click takes a suggestion on its press, and that press hides the card.
## The card lies over the TagChips row and the note body, so the second
## press of a double-click on the row would land on what was under it: a
## chip's × (dropping that tag), its body (filtering) or the body text.
## Swallow that press; the next left press clears the flag either way. A
## swallowed press gives no mouse focus, so its release goes nowhere.
func _swallow_tag_suggest_double_click(mb: InputEventMouseButton) -> void:
	if not _tag_suggest_clicked or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_tag_suggest_clicked = false
	if mb.double_click:
		get_viewport().set_input_as_handled()


## Tag the note with a suggestion; the TagInput empties and keeps the focus
## for the next tag.
func _accept_tag_suggestion(index: int) -> void:
	var tag: String = str(tag_suggest_list.get_item_metadata(index))
	tag_input.text = ""
	_hide_tag_suggestions()
	_add_tag(tag)


# ── Tags, part 2: the sidebar-wide filter (the TAGS section) ───────────────

## Set the active tag filter. An empty string clears it. Called by a TAGS-row
## press and by the section header's ×; a "#…" prefix typed in the search box
## sets it through _refresh_note_list instead (see _tag_filter_applied_from_search).
func _set_tag_filter(tag: String) -> void:
	_active_tag_filter = tag
	_tag_filter_applied_from_search = false
	_refresh_note_list()


## The header's ×: clear the tag filter, whoever set it. When "#…" tokens in
## the search box own it, they go too (the words stay), or the next rebuild
## would set it again from them.
func _clear_tag_filter() -> void:
	if _tag_filter_applied_from_search:
		search_box.text = _parse_search(search_box.text).words
	_set_tag_filter("")


## The TAGS header folds the section to its header, or unfolds it; the
## vault's ui.json remembers which.
func _toggle_tags_collapsed() -> void:
	_tags_collapsed = not _tags_collapsed
	_save_ui({"tags_collapsed": _tags_collapsed})
	_build_tag_sidebar()


## One row per tag across the vault, count = how many notes carry it, most
## used first. The row matching the active filter is pressed (toggle_mode) so
## a second press — or the × — clears it. Rebuilt on every note-list rebuild,
## so counts and the active state track saves live. Folded, the section is
## its header alone; with many tags, a field narrows the rows.
func _build_tag_sidebar() -> void:
	if tag_sidebar_list == null:
		return
	var counts: Dictionary = TagOps.counts(VaultStore.note_list)
	for c in tag_sidebar_list.get_children():
		c.queue_free()
	tag_sidebar.visible = counts.size() > 0   # no tags in the vault: the section hides
	_show_tag_section_header()
	_show_tag_list_filter(counts.size())
	tag_sidebar_scroll.visible = not _tags_collapsed
	var rows: Array[Control] = []
	if not _tags_collapsed:
		var needle: String = TagOps.normalize(tag_sidebar_filter.text)
		var sorted: Array = counts.keys().filter(func(tag: String) -> bool: return needle == "" or tag.contains(needle))
		TagOps.sort_by_use(sorted, counts)
		for tag in sorted:
			rows.append(_make_tag_sidebar_row(tag, int(counts[tag])))
			tag_sidebar_list.add_child(rows.back())
	_fit_tag_rows_height(rows)
	_sync_tag_chips()


## The header: a chevron for the fold, and the × while a filter is active.
## Folded, no row shows which tag filters, so the × carries it: "#tag ×".
func _show_tag_section_header() -> void:
	tag_sidebar_toggle.icon = Icons.get_icon("chevron_right" if _tags_collapsed else "chevron_down", 12)
	tag_sidebar_toggle.tooltip_text = "Show the tags" if _tags_collapsed else "Fold the tags away"
	var filtering: bool = _active_tag_filter != ""
	var named: bool = filtering and _tags_collapsed
	tag_sidebar_clear.visible = filtering
	tag_sidebar_clear.text = "#" + _chip_label(_active_tag_filter) if named else ""
	tag_sidebar_clear.tooltip_text = "Clear the tag filter #%s" % _active_tag_filter if filtering else ""
	# Named, it shares the header with TAGS (and trims a long tag); bare, it
	# is just the ×
	tag_sidebar_clear.size_flags_horizontal = Control.SIZE_EXPAND_FILL if named else Control.SIZE_SHRINK_END


## The field over the rows shows, unfolded, when the vault has more than
## TAG_LIST_FILTER_MIN tags. Hidden, it is emptied: a filter nobody can see
## must not narrow the rows.
func _show_tag_list_filter(tag_count: int) -> void:
	var wanted: bool = tag_count > TAG_LIST_FILTER_MIN
	if not wanted and tag_sidebar_filter.text != "":
		tag_sidebar_filter.text = ""
	tag_sidebar_filter.visible = wanted and not _tags_collapsed


## Give the TAGS rows' ScrollContainer the rows' height, at most
## TAG_ROWS_MAX_HEIGHT. A ScrollContainer asks for no height of its own, so
## without this the section showed its header and no rows. Counts only the
## new rows: the old ones are queued for deletion but still children.
func _fit_tag_rows_height(rows: Array[Control]) -> void:
	var sep: int = tag_sidebar_list.get_theme_constant("separation")
	var height: float = 0.0
	for row in rows:
		height += row.get_combined_minimum_size().y
	height += sep * max(rows.size() - 1, 0)
	(tag_sidebar_list.get_parent() as Control).custom_minimum_size.y = min(height, TAG_ROWS_MAX_HEIGHT)


func _make_tag_sidebar_row(tag: String, count: int) -> HBoxContainer:
	var btn := Button.new()
	btn.theme_type_variation = &"TagSidebarItem"
	btn.toggle_mode = true
	btn.button_pressed = _is_filtering_by(tag)
	btn.text = "#%s" % tag
	btn.tooltip_text = "Show only the %d note%s tagged #%s — press again to clear" % [count, "" if count == 1 else "s", tag]
	btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS   # a long tag cannot widen the sidebar
	btn.clip_text = true
	btn.accessibility_name = "Tag #%s, %d note%s" % [tag, count, "" if count == 1 else "s"]
	btn.accessibility_description = "Shows only the notes with this tag; press again to show all"
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_show_tag_dot(btn, tag)
	btn.pressed.connect(func() -> void:
		_set_tag_filter("" if tag == _active_tag_filter else tag))
	btn.gui_input.connect(_on_row_gui_input.bind({"type": "tag", "tag": tag}))   # right-click: rename / remove
	var count_label := Label.new()
	count_label.text = "  " + str(count)
	count_label.add_theme_color_override("font_color", _palette_colors.get("text_faint", Color.GRAY))
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(btn)
	row.add_child(count_label)
	return row


# ── Tags: rename, merge or remove one across the vault (TAGS right-click) ──

## "Rename or merge tag…": ask for the new name, prefilled with the tag. A
## name another tag already has merges the two.
func _rename_tag_prompt(tag: String) -> void:
	_ask("Rename or merge #%s" % tag, tag, "Rename", func(new_name: String) -> void:
		if TagOps.normalize(new_name) == "":
			_update_status("A tag needs a name. “Remove from all notes…” takes #%s off every note." % tag)
			return
		_rename_tag_everywhere(tag, new_name))


## "Remove from all notes…": confirm first, naming how many notes lose it.
func _confirm_remove_tag(tag: String) -> void:
	var count: int = int(TagOps.counts(VaultStore.note_list).get(tag, 0))
	var dlg := ConfirmationDialog.new()
	dlg.name = "RemoveTagDialog"
	dlg.title = "Remove #%s" % tag
	dlg.dialog_text = "Remove #%s from %s? The notes stay; only the tag goes." % [tag, _note_count_text(count)]
	dlg.ok_button_text = "Remove tag"
	add_child(dlg)
	dlg.confirmed.connect(func() -> void: _rename_tag_everywhere(tag, ""))
	dlg.visibility_changed.connect(func() -> void:
		if not dlg.visible:
			dlg.queue_free())
	dlg.popup_centered()


## Rename `from` to `to` on every note carrying it (TagOps.rename: a merge
## where a note already has `to`, a removal when `to` is empty). Pending
## typing is saved and outside edits are read in first, so each note is
## rewritten from what is on disk; every write goes through save_note with
## stamp = false, which keeps the conflict hashes right and the notes'
## order in the list. A note changed on disk in the same second (the
## watcher cannot see that) keeps the outside version and ours becomes a
## conflict copy; when it is the open note, the editor moves to the copy,
## as an autosave's conflict does. A note whose save fails keeps the new
## tag in memory and is retried with the other unsaved notes (_track_save);
## the status line names it. A TAGS-row filter on `from` follows to `to`
## (or clears). Returns how many notes changed.
func _rename_tag_everywhere(from: String, to: String) -> int:
	var old: String = TagOps.normalize(from)
	var new: String = TagOps.normalize(to)
	if old == "" or old == new:
		return 0
	_flush_pending_save()
	check_disk_changes()
	var changed: int = 0
	var copies: int = 0
	var open_copy: ContentLayer = null   # the open note's conflict copy, if it got one
	for note in VaultStore.note_list.duplicate():   # save_note rebuilds note_list
		if not TagOps.rename(note, old, new):
			continue
		changed += 1
		# A save that fails (read-only file or folder, full disk) keeps the
		# new tag in memory and joins _unsaved, retried like a failed autosave.
		if not _track_save(note, VaultStore.save_note(note, false) == OK):
			continue
		if VaultStore.last_conflict_copy != null:   # changed on disk in the same second
			copies += 1
			if note == current_note:
				open_copy = VaultStore.last_conflict_copy
			VaultStore.last_conflict_copy = null
	if _active_tag_filter == old and not _tag_filter_applied_from_search:
		_active_tag_filter = new
	if open_copy != null:
		# save_note reloaded the open note to the outside version; the editor
		# still holds ours, which is the copy's text. Left there, the next
		# keystroke would save it over the outside edit.
		_show_conflict_copy(open_copy)
	elif current_note != null:
		_build_tag_chips()
		note_meta.text = _format_meta(current_note)
	var status: String = ("Removed #%s from %s" % [old, _note_count_text(changed)]) if new == "" \
		else ("Renamed #%s → #%s in %s" % [old, new, _note_count_text(changed)])
	if copies > 0:
		status += " (%s changed on disk meanwhile: kept, with ours as a conflict copy%s)" % [_note_count_text(copies),
			"" if open_copy == null else "; \u201c%s\u201d is open now" % open_copy.title]
	_after_vault_op(_with_unsaved(status))
	return changed


static func _note_count_text(n: int) -> String:
	return "%d note%s" % [n, "" if n == 1 else "s"]


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


# ── [[ link autocomplete in Edit view ───────────────────────────────────────

## The suggestion list: top_level, so it floats over the editor at the caret,
## and never focusable, so the typing stays in the editor.
func _create_link_popup() -> void:
	_link_popup = PanelContainer.new()
	_link_popup.name = "LinkComplete"
	_link_popup.theme_type_variation = &"PalettePanel"
	_link_popup.top_level = true
	_link_popup.visible = false
	_link_list = ItemList.new()
	_link_list.name = "LinkCompleteList"
	_link_list.focus_mode = Control.FOCUS_NONE
	_link_list.auto_height = true
	_link_list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_link_list.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_link_list.accessibility_name = "Link suggestions"
	_link_list.item_clicked.connect(_on_link_suggestion_clicked)
	_link_popup.add_child(_link_list)
	add_child(_link_popup)


## Note titles for a [[link]]: those starting with `partial` first, then those
## containing it (case-insensitive, natural order, each title once), at most
## LINK_SUGGEST_MAX.
func _link_suggestions(partial: String) -> Array[String]:
	var want: String = partial.strip_edges().to_lower()
	var starts: Array[String] = []
	var contains: Array[String] = []
	var seen: Dictionary = {}
	for note in VaultStore.note_list:
		var title: String = note.title.strip_edges()
		var key: String = title.to_lower()
		if key == "" or key == "untitled" or seen.has(key):
			continue
		seen[key] = true
		if key.begins_with(want):
			starts.append(title)
		elif key.contains(want):
			contains.append(title)
	var natural := func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0
	starts.sort_custom(natural)
	contains.sort_custom(natural)
	starts.append_array(contains)
	if starts.size() > LINK_SUGGEST_MAX:
		starts.resize(LINK_SUGGEST_MAX)
	return starts


## After an edit: an unclosed "[[partial" just before the caret shows the
## titles matching it, first one highlighted; anything else hides the list.
func _update_link_popup() -> void:
	if _loading or current_note == null or not raw_text_layer.has_focus() or not raw_text_layer.is_visible_in_tree():
		_close_link_popup()
		return
	var line: int = raw_text_layer.get_caret_line()
	var before: String = raw_text_layer.get_line(line).substr(0, raw_text_layer.get_caret_column())
	var m: RegExMatch = _link_open_re.search(before)
	var titles: Array[String] = []
	if m != null:
		titles = _link_suggestions(m.get_string(1))
	if titles.is_empty():
		_close_link_popup()
		return
	_link_line = line
	_link_start = m.get_start(1)
	_link_list.clear()
	for title in titles:
		var i: int = _link_list.add_item(title)
		_link_list.set_item_tooltip(i, title)
	_link_list.select(0)
	# auto_height measures the new rows only on the next draw; measure now so
	# the card is sized (and placed) for them.
	_link_list.force_update_list_size()
	_link_popup.size = Vector2(minf(LINK_SUGGEST_WIDTH, raw_text_layer.size.x), 0.0)
	_link_popup.visible = true
	_place_link_popup()


func _close_link_popup() -> void:
	if _link_popup != null:
		_link_popup.visible = false
	_link_line = -1


## Under the caret, or above it when the window has no room below; always
## inside the window.
func _place_link_popup() -> void:
	if _link_popup == null or not _link_popup.visible:
		return
	var caret: Vector2 = raw_text_layer.get_global_rect().position + raw_text_layer.get_caret_draw_pos()
	var window: Rect2 = get_viewport_rect()
	var card: Vector2 = _link_popup.size
	var pos := Vector2(caret.x, caret.y + 4.0)
	if pos.y + card.y > window.end.y:
		pos.y = caret.y - raw_text_layer.get_line_height() - card.y - 4.0
	pos.x = clampf(pos.x, window.position.x, maxf(window.position.x, window.end.x - card.x))
	pos.y = maxf(pos.y, window.position.y)
	_link_popup.global_position = pos


## Leaving the line closes the list; moving along it re-reads the title typed.
func _on_editor_caret_changed() -> void:
	if _link_popup == null or not _link_popup.visible:
		return
	if raw_text_layer.get_caret_line() != _link_line:
		_close_link_popup()
	else:
		_update_link_popup()


## While the list shows (and only then): Up/Down move the highlight, Enter
## or Tab take it, Esc closes the list. Every other key goes to the editor.
func _on_editor_gui_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if _link_popup == null or not _link_popup.visible or k == null or not k.pressed or _cmd(k) or k.alt_pressed:
		return
	match k.keycode:
		KEY_DOWN:
			_move_link_selection(1)
		KEY_UP:
			_move_link_selection(-1)
		KEY_ENTER, KEY_KP_ENTER, KEY_TAB:
			_accept_link_suggestion(_selected_link_suggestion())
		KEY_ESCAPE:
			_close_link_popup()
		_:
			return
	raw_text_layer.accept_event()


func _move_link_selection(step: int) -> void:
	var next: int = clampi(_selected_link_suggestion() + step, 0, _link_list.item_count - 1)
	_link_list.select(next)
	_link_list.ensure_current_is_visible()


func _selected_link_suggestion() -> int:
	var picked: PackedInt32Array = _link_list.get_selected_items()
	return picked[0] if not picked.is_empty() else 0


func _on_link_suggestion_clicked(index: int, _at: Vector2, button: int) -> void:
	if button == MOUSE_BUTTON_LEFT:
		_accept_link_suggestion(index)
		_link_clicked = true


## The list floats over the text, so a double-click's second press on a row
## would land on the editor below and select a word there. Swallow it; the
## next left press clears the flag either way.
func _swallow_link_double_click(mb: InputEventMouseButton) -> void:
	if not _link_clicked or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_link_clicked = false
	if mb.double_click:
		get_viewport().set_input_as_handled()


## Replace the typed part of the title with the whole title and close the
## link ("]]", unless the text already closes it). One undo step.
func _accept_link_suggestion(index: int) -> void:
	if index < 0 or index >= _link_list.item_count or _link_line < 0:
		_close_link_popup()
		return
	var title: String = _link_list.get_item_text(index)
	var line: int = _link_line
	var start: int = _link_start
	var col: int = raw_text_layer.get_caret_column()
	_close_link_popup()
	var closed: bool = raw_text_layer.get_line(line).substr(col).begins_with("]]")
	raw_text_layer.begin_complex_operation()
	if col > start:
		raw_text_layer.remove_text(line, start, line, col)
	raw_text_layer.set_caret_line(line)
	raw_text_layer.set_caret_column(start)
	raw_text_layer.insert_text_at_caret(title if closed else title + "]]")
	if closed:
		raw_text_layer.set_caret_column(start + title.length() + 2)
	raw_text_layer.end_complex_operation()
	raw_text_layer.grab_focus()


## Rename the open note to what the user typed in the title field (Enter,
## leaving the field, close, focus-out). An untouched field commits nothing,
## even when the note was renamed outside the app since it was shown: that
## title is the file's now, and writing the old one back would revert it.
## A refused title (a duplicate) puts the field back to the note's title.
func _commit_title() -> void:
	if current_note == null or title_edit.text == _title_shown:
		return
	_title_shown = title_edit.text   # what the field says now is the user's title
	if not _rename_current(title_edit.text):
		_show_title(current_note)


## Rename the open note to `new_title` (blank = "untitled"): its title and,
## through VaultStore.rename_note, its file; then RenameCascade moves the
## [[links]], quiz learn:/next: lines, Journey and progress that named it. A
## refused title changes nothing, the status line says why, and false comes back.
## A save that fails keeps the new title in memory and retries it (_unsaved).
func _rename_current(new_title: String) -> bool:
	new_title = new_title.strip_edges()
	if new_title == "":
		new_title = "untitled"
	if current_note == null or new_title == current_note.title:
		return true
	_save_note_state()
	_sync_raw_text()   # a pending body edit rides along, so a conflict copy holds it too
	_normalize_tags(current_note)
	var old_path: String = current_note.resource_path
	# A rename still waiting for its save started from the title links name
	var pending: Dictionary = _pending_renames.get(current_note, {})
	var old_title: String = pending.get("from", current_note.title)
	var order: Array = pending.get("order", VaultStore.note_list.duplicate())   # what links resolved over: the save below makes this note the newest
	var refused: String = VaultStore.rename_note(current_note, new_title)
	if refused != "":
		_update_status(refused)
		return false
	if current_note.resource_path != old_path:   # the file took the new title: Back / Forward and the session follow it
		_nav.remap(old_path, current_note.resource_path)
		_save_session()
	_pending_renames.erase(current_note)
	if not _track_save(current_note, VaultStore.last_save_error == ""):
		# The new title stays in memory and is retried; the file and what
		# names the note follow once a save works (_finish_rename)
		_pending_renames[current_note] = {"from": old_title, "order": order}
		return true
	_take_own_change(current_note)   # the app's own rename is no outside change
	if _open_conflict_copy():
		return true
	var cascade: Dictionary = RenameCascade.apply(old_title, current_note.title, current_note, order)
	VaultStore.last_conflict_copy = null   # a linking note's conflict copy is reported, not opened
	_take_own_change(current_note)   # nor are the links it rewrote
	if cascade.changed.has(current_note):
		_reload_current_note()   # its own [[links]] to itself changed
	_show_title(current_note)
	_refresh_note_list()
	breadcrumb.text = _crumb(current_note)
	_rerender_read_view()   # its chips' activity keys hold the title
	if current_mode == "graph":
		_refresh_graph()   # the sidebar's Rename: a new title and file under the graph
	_update_conflict_bar()   # renamed away from "(conflict copy)", it is a note of its own
	_update_status("Renamed to " + _display_title(current_note) + RenameCascade.summary(cascade))
	return true


## Show the open note's text again after something other than the editor
## changed it, in the view that was showing. A rename finished by a retry
## (_finish_rename) does this while the user may be typing, so the editor's
## caret and scroll stay where they were, and so does a title typed but not
## yet committed (the field still has the keyboard).
func _reload_current_note() -> void:
	var note: ContentLayer = current_note
	var typed: String = title_edit.text
	var typing: bool = typed != _title_shown
	var title_caret: int = title_edit.caret_column
	var line: int = raw_text_layer.get_caret_line()
	var column: int = raw_text_layer.get_caret_column()
	var scroll: float = raw_text_layer.scroll_vertical
	current_note = null
	_open_note(note, current_mode == "graph")
	line = clampi(line, 0, raw_text_layer.get_line_count() - 1)
	raw_text_layer.set_caret_line(line)
	raw_text_layer.set_caret_column(clampi(column, 0, raw_text_layer.get_line(line).length()))
	raw_text_layer.scroll_vertical = scroll
	if typing:
		title_edit.text = typed
		title_edit.caret_column = title_caret
	if current_mode in ["structured", "visual"]:
		_switch_layer(current_mode)


## What the title field shows for `note`: empty for an untitled one.
func _title_field_text(note: ContentLayer) -> String:
	return "" if _display_title(note) == "Untitled" else note.title


## Write what is pending now: every note whose earlier save failed, then the
## open note's edit (also when `force`, for Ctrl+S), whose result the status
## bar ends with. Called before anything replaces the open note, and on close
## and focus-out. Driven by the dirty state (_editing, _unsaved), not only by
## the timer, so nothing that stops the timer can drop an edit. Returns
## true when a save here met an outside edit: the words went to a conflict
## copy and the status says so, which a caller about to act on the note
## (Ctrl+Z) leaves in front of the user instead.
func _flush_pending_save(force: bool = false) -> bool:
	if _auto_save_timer == null:
		return false
	var pending: bool = current_note != null and (force or _editing or not _auto_save_timer.is_stopped())
	var conflict: bool = _retry_unsaved(current_note if pending else null)
	if pending:
		_auto_save_timer.stop()
		conflict = _do_auto_save() or conflict
	return conflict


## Save everything the editor holds but hasn't written: pending typing, and a
## title typed but not yet committed. The title field commits only on focus
## out or Enter, and a right-click on a sidebar row leaves focus in it, so
## the row menu's items run with the typed title still unsaved; reopening
## the note then would put the old title back and drop the typed one.
func _save_pending_edits() -> void:
	_flush_pending_save()
	_commit_title()


## Save the open note's edit (the autosave timer, a flush). True when it met
## an outside edit and the conflict copy is now open.
func _do_auto_save() -> bool:
	if current_note == null:
		return false
	_save_note_state()
	_sync_raw_text()
	_normalize_tags(current_note)
	_editing = false
	if not _save_or_keep(current_note):
		return false
	if _open_conflict_copy():
		return true
	note_meta.text = _format_meta(current_note)
	_show_saved_row(current_note)
	_update_status(_with_unsaved("Saved"))
	return false


## After an autosave of the open note: while its title, folder and tags are
## what the sidebar was built with, only its row changes (_update_note_row),
## because rebuilding every row is a visible hitch in a big vault on each
## pause in typing. A rename, a move or a tag (the TAGS counts and filter
## show it) rebuilds the list, as does a search, whose matches the edit may
## change.
func _show_saved_row(note: ContentLayer) -> void:
	if _row_key(note) != _listed_key or not _update_note_row(note):
		_refresh_note_list()


## What the sidebar shows of `note` beyond its own row: its title, folder and tags.
func _row_key(note: ContentLayer) -> String:
	if note == null:
		return ""
	return "%s\n%s\n%s" % [note.title, VaultStore.folder_of(note), ",".join(note.tags)]


## Show a saved edit of `note` in its sidebar row alone: its text, its status
## icon and tooltip (an added quiz can make it ✓), and its place among its
## folder's rows when the save moved it in note_list. Its row in Pinned or
## Starred shows the same. False when the list must be rebuilt instead: a
## search is shown.
func _update_note_row(note: ContentLayer) -> bool:
	if search_box.text.strip_edges() != "":
		return false
	for row in _section_rows:
		if row.get_meta(&"note") == note:
			row.text = _display_title(note)
			_apply_status_icon(row, note)
	var btn: Button = _note_buttons.get(note)
	if btn == null:
		return true   # no row shows it: its folder is collapsed, or a tag filter hides it
	btn.text = _display_title(note)
	_apply_status_icon(btn, note)
	_move_row_into_order(note)
	return true


## Put the rows of `note`'s folder back in note_list's order (newest first)
## after a save moved `note` there. A folder's note rows sit together, after
## its subfolders, so they swap among the places they already hold.
func _move_row_into_order(note: ContentLayer) -> void:
	var folder: String = VaultStore.folder_of(note)
	var rows: Array[Button] = []
	for n in VaultStore.note_list:
		if _note_buttons.has(n) and VaultStore.folder_of(n) == folder:
			rows.append(_note_buttons[n])
	var places: Array[int] = []
	for btn in rows:
		places.append(btn.get_index())
	places.sort()
	var moved: bool = false
	for i in range(rows.size()):
		if rows[i].get_index() != places[i]:
			note_list_container.move_child(rows[i], places[i])
			moved = true
	if moved:   # _visible_notes lists the rows top to bottom
		var note_of: Dictionary = {}
		for n in _note_buttons:
			note_of[_note_buttons[n]] = n
		_visible_notes.clear()
		for child in note_list_container.get_children():
			if note_of.has(child):
				_visible_notes.append(note_of[child])
		_link_row_focus()   # Up / Down follow the rows' new order


## Save `note`. When save_note() fails (read-only file or folder, full disk,
## a sync tool's lock) the note joins _unsaved: its words stay in memory (and
## in the editor while it is open), the status bar says why, and the retry
## timer runs. The list is not refreshed: nothing changed on disk. Returns
## true when the note was written (or kept as a conflict copy).
func _save_or_keep(note: ContentLayer) -> bool:
	return _track_save(note, VaultStore.save_note(note) == OK)


## After a save of `note` that `saved` or not (failed: VaultStore.last_save_error
## says why): it leaves _unsaved, or joins it with the retry timer running.
## Returns `saved`.
func _track_save(note: ContentLayer, saved: bool) -> bool:
	if saved:
		_unsaved.erase(note)
		if _unsaved.is_empty():
			_retry_timer.stop()
			_switch_anyway = ""   # words at risk later hold a switch again
		if _pending_renames.has(note):
			_finish_rename(note)
		return true
	_save_error = VaultStore.last_save_error
	if not note in _unsaved:
		_unsaved.append(note)
	_retry_timer.start(SAVE_RETRY_DELAY)
	_update_status(_unsaved_message())
	return false


## A rename whose save failed was saved now, by a retry or the next edit:
## the new title is in the note's old file. Do what the rename would have
## done: give the file the title's name (VaultStore.move_to_title_file) and
## move the [[links]], quiz lines, Journey and progress keys that named the
## old title (RenameCascade). A save that became a conflict copy kept the
## outside version under its old title instead, so nothing is renamed.
func _finish_rename(note: ContentLayer) -> void:
	var r: Dictionary = _pending_renames[note]
	_pending_renames.erase(note)
	if VaultStore.last_conflict_copy != null or note.title == r.from:
		return
	var old_path: String = note.resource_path
	VaultStore.move_to_title_file(note)
	if note.resource_path != old_path:
		_nav.remap(old_path, note.resource_path)
		_save_session()
	# The open note may be another one, linking to the old title: words typed
	# into it join it first, so the cascade rewrites them with the rest and
	# the editor can show the result (else its next save writes the old
	# [[link]] back). When `note` is the open one the caller synced it.
	if current_note != null and current_note != note and raw_text_layer.text != current_note.raw_text:
		_save_note_state()
		_sync_raw_text()
	var cascade: Dictionary = RenameCascade.apply(r.from, note.title, note, r.order)
	VaultStore.last_conflict_copy = null   # a linking note's conflict copy is reported, not opened
	_take_own_change(current_note)   # the app's own rename and link rewrites
	if current_note != null and cascade.changed.has(current_note):
		_reload_current_note()   # its [[links]] changed: the renamed note's own, or the open note's to it
	if note == current_note:
		breadcrumb.text = _crumb(note)
	_refresh_note_list()


## Try every note in _unsaved again (the retry timer, a flush, close,
## focus-out), except `skip`, which the caller has just tried. The open note
## takes the editor's text first. A note that saves leaves the list; if an
## outside edit made it a conflict copy, the open note switches to the copy
## and a note in the background just says so; true then.
func _retry_unsaved(skip: ContentLayer = null) -> bool:
	if _unsaved.is_empty():
		return false
	var saved: PackedStringArray = []
	var conflict: String = ""
	for note in _unsaved.duplicate():
		if note == skip:
			continue
		if note == current_note:
			_sync_raw_text()
		if not _save_or_keep(note):
			continue
		if note == current_note:
			if _open_conflict_copy():
				conflict = status_label.text
				continue
			note_meta.text = _format_meta(note)
		elif VaultStore.last_conflict_copy != null:
			conflict = "“%s” changed on disk while it waited to be saved. Your version is saved as “%s”." % [_display_title(note), VaultStore.last_conflict_copy.title]
			VaultStore.last_conflict_copy = null
		saved.append("“%s”" % _display_title(note))
	if saved.is_empty() and conflict == "":
		return false
	_refresh_note_list()
	if not _unsaved.is_empty():
		_update_status(_unsaved_message())
	elif conflict != "":
		_update_status(conflict)
	else:
		_update_status("Saved " + ", ".join(saved))
	return conflict != ""


## "Couldn't save “A”: <why>. …", naming every note still in _unsaved.
func _unsaved_message() -> String:
	var titles: PackedStringArray = []
	for note in _unsaved:
		titles.append("“%s”" % _display_title(note))
	var kept: String = "Your text is still here." if current_note in _unsaved else "Its text is kept and retried."
	return "Couldn't save %s: %s. %s" % [", ".join(titles), _save_error, kept]


## What a vault switch would lose, "" if nothing: the notes in _unsaved
## (_unsaved_message), and the deleted notes whose words only their _trashed
## entry holds (a restore brings them back; the switch would drop them).
func _words_at_risk() -> String:
	var parts: PackedStringArray = []
	if not _unsaved.is_empty():
		parts.append(_unsaved_message())
	var held: PackedStringArray = []
	for t in _trashed:
		if t.has("unsaved"):
			held.append("“%s”" % t.title)
	if held.size() == 1:
		parts.append("%s is in the trash without the words it couldn't save; Ctrl+Z restores it with them." % held[0])
	elif held.size() > 1:
		parts.append("%s are in the trash without the words they couldn't save; Ctrl+Z restores them with those words." % ", ".join(held))
	return " ".join(parts)


## `msg`, plus the unsaved-notes warning while any note is unsaved, so a note
## that couldn't be saved stays visible after opening or saving another one.
func _with_unsaved(msg: String) -> String:
	return msg if _unsaved.is_empty() else msg + ". " + _unsaved_message()


## Drop the unsaved edits of notes that are being deleted (`prefix`: the
## deleted note's path, or a deleted folder's path ending in "/").
func _forget_unsaved(prefix: String) -> void:
	for note in _unsaved.duplicate():
		if note.resource_path == prefix or (prefix.ends_with("/") and note.resource_path.begins_with(prefix)):
			_unsaved.erase(note)
	if _unsaved.is_empty():
		_retry_timer.stop()


## create_note() couldn't write the file: say why instead of opening a note
## that isn't on disk.
func _report_create_failed(what: String) -> void:
	_update_status("Couldn't create %s: %s." % [what, VaultStore.last_save_error])


## save_note() kept an outside edit and saved ours as a conflict copy: open
## the copy so the user's words stay in front of them, and say what happened.
func _open_conflict_copy() -> bool:
	var copy: ContentLayer = VaultStore.last_conflict_copy
	if copy == null:
		return false
	VaultStore.last_conflict_copy = null
	var original: String = _display_title(current_note)
	var happened: String = "changed on disk" if FileAccess.file_exists(current_note.resource_path) else "was renamed or deleted on disk"
	_show_conflict_copy(copy)
	_update_status("\u201c%s\u201d %s while you were editing. Your version is saved as \u201c%s\u201d." % [original, happened, copy.title])
	return true


## Put a conflict copy in the editor in place of the note it was split from
## (save_note reloaded that note to the outside version), in the same view.
func _show_conflict_copy(copy: ContentLayer) -> void:
	var mode: String = current_mode
	current_note = null
	_refresh_note_list()
	_open_note(copy)
	if mode != current_mode or mode in ["structured", "visual"]:
		_switch_layer(mode)


## Tags written by the importer, MCP or an older app ("Physics") are stored
## normalized the next time the app saves the note; files are never
## rewritten just to normalize them.
func _normalize_tags(note: ContentLayer) -> void:
	var tags: Array[String] = TagOps.normalize_list(note.tags)
	if tags != note.tags:
		note.tags = tags


# \u2500\u2500 Conflict copies: settle one with its original \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500

## Past this many line pairs, Compare shows the differing middle of two notes
## as all of one's lines, then all of the other's (line_diff).
const DIFF_MAX_CELLS: int = 250000


## Build the conflict bar, hidden, right above the note's views, so Edit,
## Outline and Read all show it: "Saved during a conflict with \u201cX\u201d", then
## [Use this version] [Keep \u201cX\u201d] [Compare]. _update_conflict_bar shows it.
func _build_conflict_bar() -> void:
	_conflict_bar = PanelContainer.new()
	_conflict_bar.name = "ConflictBar"
	_conflict_bar.theme_type_variation = &"ReviewBanner"
	_conflict_bar.visible = false
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_conflict_bar.add_child(box)
	_conflict_label = Label.new()
	_conflict_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_conflict_label)
	var buttons := HFlowContainer.new()
	buttons.add_theme_constant_override("h_separation", 8)
	buttons.add_theme_constant_override("v_separation", 6)
	box.add_child(buttons)
	_conflict_use_btn = _conflict_button(buttons, "ConflictUseButton", &"AccentButton", _use_conflict_copy)
	_conflict_use_btn.text = "Use this version"
	_conflict_keep_btn = _conflict_button(buttons, "ConflictKeepButton", &"", _keep_conflict_original)
	_conflict_keep_btn.text = "Keep the original"   # named after the note once a copy shows (_update_conflict_bar)
	_conflict_compare_btn = _conflict_button(buttons, "ConflictCompareButton", &"", _compare_conflict_copy)
	_conflict_compare_btn.text = "Compare"
	var layers: Control = raw_text_layer.get_parent()   # LayerStack, under the title, tags and meta line
	layers.get_parent().add_child(_conflict_bar)
	layers.get_parent().move_child(_conflict_bar, layers.get_index())


func _conflict_button(parent: Control, node_name: String, variation: StringName, action: Callable) -> Button:
	var btn := Button.new()
	btn.name = node_name
	btn.theme_type_variation = variation
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.pressed.connect(action)
	parent.add_child(btn)
	return btn


## Show the conflict bar while the open note is a conflict copy whose original
## is in the vault (VaultStore.conflict_original), naming that original.
func _update_conflict_bar() -> void:
	if _conflict_bar == null:
		return
	var original: ContentLayer = VaultStore.conflict_original(current_note)
	_conflict_bar.visible = original != null
	if original == null:
		return
	var name: String = _display_title(original)
	_conflict_label.text = "Saved during a conflict with \u201c%s\u201d" % name
	_conflict_keep_btn.text = "Keep \u201c%s\u201d" % _clip(name, 32)
	_conflict_use_btn.tooltip_text = "Put this copy's text and tags into \u201c%s\u201d, move this copy to the trash and open \u201c%s\u201d" % [name, name]
	_conflict_keep_btn.tooltip_text = "Leave \u201c%s\u201d as it is and move this copy to the trash (Ctrl+Z brings it back)" % name
	_conflict_compare_btn.tooltip_text = "Show the lines that differ between \u201c%s\u201d and this copy" % name


## `s`, cut to `n` characters with "\u2026" when longer (a title on a button).
static func _clip(s: String, n: int) -> String:
	return s if s.length() <= n else s.left(n - 1) + "\u2026"


## Before settling the open conflict copy: its pending edit is saved (if that
## meets an outside edit, a newer copy opens and nothing is settled), and its
## original is looked up again. Null when there is nothing to settle.
func _conflict_target() -> ContentLayer:
	var copy: ContentLayer = current_note
	if copy == null or _flush_pending_save() or current_note != copy:
		return null
	var original: ContentLayer = VaultStore.conflict_original(copy)
	if original == null:
		_update_conflict_bar()
		_update_status("The note \u201c%s\u201d was saved against is no longer in the vault" % _display_title(copy))
	return original


## "Use this version": the copy's text and tags replace its original's
## (VaultStore.take_conflict_copy; one Ctrl+Z step, like an edit), the copy
## goes to the trash (Ctrl+Z, or "Restore last deleted note", brings it back)
## and the original opens. Had the original changed on disk again meanwhile,
## that newer version is kept as well: the words become a new conflict copy
## against it, which opens instead, and the old copy (same words) goes. A
## failed save changes nothing and says why.
func _use_conflict_copy() -> void:
	var copy: ContentLayer = current_note
	var original: ContentLayer = _conflict_target()
	if original == null:
		return
	var name: String = _display_title(original)
	if _undo_engine != null:
		_undo_engine.call("push_snapshot", original, copy.raw_text)
	if VaultStore.take_conflict_copy(original, copy) != OK:
		_update_status(_with_unsaved("Couldn't save \u201c%s\u201d: %s. Nothing changed; this copy stays." % [name, VaultStore.last_save_error]))
		return
	var newer: ContentLayer = VaultStore.last_conflict_copy
	VaultStore.last_conflict_copy = null
	var trashed: bool = not _trash_note(copy).is_empty()
	_show_after_trash(newer if newer != null else original)
	var msg: String = "\u201c%s\u201d now has this version; the conflict copy is in the trash  \u00b7  Ctrl+Z restores it" % name
	if newer != null:
		msg = "\u201c%s\u201d changed on disk again, so this version is now \u201c%s\u201d, next to the newer \u201c%s\u201d; the older copy is in the trash" % [name, newer.title, name]
	if not trashed:
		msg = "\u201c%s\u201d now has this version, but the conflict copy couldn't be moved to the trash" % name
	_update_status(_with_unsaved(msg))


## "Keep \u201cX\u201d": the original stays as it is, the copy goes to the trash
## (Ctrl+Z brings it back) and the original opens.
func _keep_conflict_original() -> void:
	var copy: ContentLayer = current_note
	var original: ContentLayer = _conflict_target()
	if original == null:
		return
	if _trash_note(copy).is_empty():
		_update_status(_with_unsaved("Couldn't move \u201c%s\u201d to the trash" % _display_title(copy)))
		return
	_show_after_trash(original)
	_update_status(_with_unsaved("Kept \u201c%s\u201d; the conflict copy is in the trash  \u00b7  Ctrl+Z restores it" % _display_title(original)))


## "Compare": the original's lines and this copy's in a dialog, "- " for a
## line only the original has, "+ " for one only the copy has (line_diff).
func _compare_conflict_copy() -> void:
	var original: ContentLayer = VaultStore.conflict_original(current_note)
	if original == null:
		_update_conflict_bar()
		return
	_sync_raw_text()
	if _compare_dialog == null:
		_compare_dialog = AcceptDialog.new()
		_compare_dialog.name = "CompareDialog"
		_compare_dialog.ok_button_text = "Close"
		_compare_text = RichTextLabel.new()
		_compare_text.bbcode_enabled = true
		_compare_text.selection_enabled = true
		_compare_text.custom_minimum_size = Vector2(600, 340)
		_compare_dialog.add_child(_compare_text)
		add_child(_compare_dialog)
	var name: String = _display_title(original)
	_compare_dialog.title = "Compare with \u201c%s\u201d" % _clip(name, 40)
	var bb: String = "[color=#e06c6c]- only in \u201c%s\u201d[/color]      [color=#3ddc84]+ only in this copy[/color]\n\n" % name.replace("[", "[lb]")
	for line in line_diff(original.raw_text, current_note.raw_text):
		var shown: String = "[code]%s[/code]" % line.replace("[", "[lb]")
		match line.left(1):
			"-":
				bb += "[color=#e06c6c]%s[/color]\n" % shown
			"+":
				bb += "[color=#3ddc84]%s[/color]\n" % shown
			_:
				bb += shown + "\n"
	_compare_text.text = bb
	_compare_dialog.popup_centered()


## The lines of `a` and `b` in order, each starting "  " (in both), "- " (only
## in `a`) or "+ " (only in `b`): a longest-common-subsequence line diff of
## what lies between their common first and last lines. Past DIFF_MAX_CELLS
## pairs, that middle is all of `a`'s lines, then all of `b`'s.
static func line_diff(a: String, b: String) -> PackedStringArray:
	var x: PackedStringArray = a.split("\n")
	var y: PackedStringArray = b.split("\n")
	var head: int = 0
	while head < x.size() and head < y.size() and x[head] == y[head]:
		head += 1
	var tail: int = 0
	while tail < x.size() - head and tail < y.size() - head and x[x.size() - 1 - tail] == y[y.size() - 1 - tail]:
		tail += 1
	var out: PackedStringArray = []
	for i in range(head):
		out.append("  " + x[i])
	out.append_array(_diff_middle(x.slice(head, x.size() - tail), y.slice(head, y.size() - tail)))
	for i in range(x.size() - tail, x.size()):
		out.append("  " + x[i])
	return out


static func _diff_middle(x: PackedStringArray, y: PackedStringArray) -> PackedStringArray:
	var out: PackedStringArray = []
	var n: int = x.size()
	var m: int = y.size()
	if n * m > DIFF_MAX_CELLS:
		for line in x:
			out.append("- " + line)
		for line in y:
			out.append("+ " + line)
		return out
	# lcs[i * w + j]: how many lines x[i..] and y[j..] have in common, in order
	var w: int = m + 1
	var lcs := PackedInt32Array()
	lcs.resize((n + 1) * w)
	lcs.fill(0)
	for i in range(n - 1, -1, -1):
		for j in range(m - 1, -1, -1):
			lcs[i * w + j] = lcs[(i + 1) * w + j + 1] + 1 if x[i] == y[j] else maxi(lcs[(i + 1) * w + j], lcs[i * w + j + 1])
	var i: int = 0
	var j: int = 0
	while i < n and j < m:
		if x[i] == y[j]:
			out.append("  " + x[i])
			i += 1
			j += 1
		elif lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]:
			out.append("- " + x[i])
			i += 1
		else:
			out.append("+ " + y[j])
			j += 1
	for k in range(i, n):
		out.append("- " + x[k])
	for k in range(j, m):
		out.append("+ " + y[k])
	return out


func _sync_raw_text() -> void:
	if current_note != null and raw_text_layer != null:
		current_note.raw_text = raw_text_layer.text


## Before saving an edit to the open note: its text as last saved, and the
## editor's text about to replace it, become a step of the app's history.
func _save_note_state() -> void:
	if current_note == null or _undo_engine == null:
		return
	_undo_engine.call("push_snapshot", current_note, raw_text_layer.text)


func _on_save_note_pressed() -> void:
	if current_note == null:
		_update_status("No note to save")
		return
	_flush_pending_save(true)


func _on_new_note_pressed() -> void:
	if not _commit_typed_title():   # Ctrl+N from the title field: its title first
		return   # it met an outside edit: the conflict copy is open, and says so
	_flush_pending_save()
	var held: ContentLayer = current_note
	var folder: String = VaultStore.folder_of(current_note) if current_note != null else ""
	var note: ContentLayer = VaultStore.create_note("untitled", folder)
	if note == null:
		_report_create_failed("a new note")
		return
	_take_own_change(held)
	search_box.text = ""
	_refresh_note_list()
	_open_note(note)
	if current_mode != "raw":
		_switch_layer("raw")
	title_edit.grab_focus()
	_update_status(_with_unsaved("New note"))


## Delete the open note: its file moves to <vault>/.trash
## (VaultStore.trash_note) and Ctrl+Z or "Restore last deleted note" brings
## it back, so there is no confirmation. A pending edit is saved first, so
## the trashed file holds the last words; if that save meets an outside edit,
## the conflict copy opens instead and nothing is deleted. A note whose save
## failed (read-only file, full disk) goes to the trash without the words it
## couldn't save: they stay with the delete, the status says so, and a
## restore puts them back and tries the save again.
func _on_delete_note_pressed() -> void:
	if current_note == null:
		return
	var note: ContentLayer = current_note
	_flush_pending_save()
	if current_note != note:
		return   # the words went to a conflict copy, now open: the user decides again
	var title: String = _display_title(note)
	var deleted: Dictionary = _trash_note(note)
	if deleted.is_empty():
		_update_status(_with_unsaved("Couldn't move “%s” to the trash" % title))
		return
	_show_after_trash(null)
	var what: String = "Moved “%s” to the trash without the words it couldn't save  ·  Ctrl+Z restores it with them" if deleted.has("unsaved") else "Moved “%s” to the trash  ·  Ctrl+Z to restore"
	_update_status(_with_unsaved(what % title))


## Move `note`'s file to the vault's trash (VaultStore.trash_note) and push
## it on _trashed, for Ctrl+Z and "Restore last deleted note". A note whose
## save failed leaves _unsaved, and its entry keeps the words its file lacks
## (`unsaved`). Returns the entry, or {} when the file couldn't be moved
## (then nothing changed).
func _trash_note(note: ContentLayer) -> Dictionary:
	var title: String = _display_title(note)
	var original_rel: String = note.resource_path.substr(VaultStore.vault_path.length())
	var trash_rel: String = VaultStore.trash_note(note)
	if trash_rel == "":
		return {}
	var deleted: Dictionary = {"trash_rel": trash_rel, "original_rel": original_rel, "title": title, "at": UndoRedoEngine.tick()}
	if note in _unsaved:   # its file in the trash lacks these words: they wait here for a restore
		deleted.unsaved = _note_fields(note)
		_unsaved.erase(note)
		if _unsaved.is_empty():
			_retry_timer.stop()
	_trashed.append(deleted)
	return deleted


## After the open note went to the trash: the list without it, and `next`
## open (the newest note when null; the empty state in an empty vault). A text
## field holding the keyboard lets go, so the Ctrl+Z the status offers reaches
## the app: the editor, which keeps it after the context menu's Delete (a
## right-click moves no focus), would take it as its own undo.
func _show_after_trash(next: ContentLayer) -> void:
	_take_own_change(current_note)
	current_note = null
	_refresh_note_list()
	if next == null and VaultStore.note_list.size() > 0:
		next = VaultStore.note_list[0]
	if next != null:
		_open_note(next)
	else:
		_show_empty_state()
	_let_go_of_keyboard()


## A text field holding the keyboard lets go, so a Ctrl+Z the status offers
## (a delete's restore) reaches the app's _unhandled_input instead of the
## field's own undo, which would undo typing in the open note.
func _let_go_of_keyboard() -> void:
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is TextEdit or focus is LineEdit:
		focus.release_focus()


## What `note` holds in memory (title, text, tags…: its script's fields),
## copied, to put back later with `note.set(field, value)`.
func _note_fields(note: ContentLayer) -> Dictionary:
	var fields: Dictionary = {}
	for p in note.get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var v: Variant = note.get(p.name)
			fields[p.name] = v.duplicate(true) if v is Array or v is Dictionary else v
	return fields


## Put the note the last Delete trashed back where it was (beside it, if a
## new note took its file name since) and open it. False if there was none
## or it couldn't come back. A note deleted with words its save couldn't
## write never loses them here: when its file left the trash (the user
## emptied it), the note is written anew from those words
## (VaultStore.recreate_note), and when that fails too, or the file can't
## move back, its entry stays for another try.
func _restore_last_trashed() -> bool:
	if _trashed.is_empty():
		_update_status("No deleted note to restore")
		return false
	var t: Dictionary = _trashed.back()
	var held: ContentLayer = current_note   # the editor's note through the restore's rescan
	var words: Dictionary = t.get("unsaved", {})
	# A note a folder took to the trash (_keep_folder_note_words) is written
	# again from its words: its trash_rel only names a free slot, and a file
	# another delete put there since is not its own
	var folder_note: bool = t.has("folder")
	var in_trash: bool = not folder_note and FileAccess.file_exists(VaultStore.vault_path + t.trash_rel)
	var note: ContentLayer = null if folder_note else VaultStore.restore_from_trash(t.trash_rel, t.original_rel)
	var retitle_unsaved: bool = note != null and VaultStore.last_save_error != ""   # the free title it came back with
	var rebuilt: bool = false
	if note == null and not in_trash and not words.is_empty():
		note = VaultStore.recreate_note(t.trash_rel, t.original_rel, words)
		rebuilt = note != null
	if note == null:
		var why: String = ("it is still in %s" % t.trash_rel) if in_trash else ("its folder is in the trash" if folder_note else ("it is no longer in %s" % VaultStore.TRASH_DIR))
		if words.is_empty():   # nothing but its file, which is where it was
			_trashed.pop_back()
			_update_status("Couldn't restore “%s”: %s" % [t.title, why])
		elif not in_trash:
			_update_status("Couldn't restore “%s”: %s, and writing it again failed: %s. Its words are kept; restore again to retry." % [t.title, why, VaultStore.last_save_error])
		else:
			_update_status("Couldn't restore “%s”: %s. Its words are kept; restore again to retry." % [t.title, why])
		return false
	_trashed.pop_back()
	if not rebuilt:
		for field in words:   # what its save couldn't write before the delete
			note.set(field, words[field])
		note.title = VaultStore.free_title(note.title, note)   # those words' title may be another note's now
	_collapsed.erase(VaultStore.folder_of(note))
	_refresh_note_list()
	_open_note(note)
	# Saved again; a failure keeps them unsaved and retried, as before the delete
	var conflict: bool = not rebuilt and (retitle_unsaved or not words.is_empty()) and _save_or_keep(note) and _open_conflict_copy()
	_take_own_change(held)
	var title: String = _display_title(note)
	var as_title: String = "" if title == t.title else " as “%s” (another note is “%s” now)" % [title, t.title]
	if rebuilt and folder_note:
		_update_status(_with_unsaved("Restored “%s”%s from the words the app kept; the rest of its folder stays in the trash" % [t.title, as_title]))
	elif rebuilt:
		_update_status(_with_unsaved("Restored “%s”%s from the words the app kept: its file was no longer in %s" % [t.title, as_title, VaultStore.TRASH_DIR]))
	elif not conflict:
		_update_status(_with_unsaved("Restored “%s”%s" % [t.title, as_title]))
	return true


## The Trash: everything deleted from this vault, newest first, each with a
## Restore button. It reads .trash each time, so it spans launches.
func _show_trash_panel() -> void:
	var dlg := AcceptDialog.new()
	dlg.name = "TrashDialog"
	dlg.title = "Trash"
	dlg.ok_button_text = "Close"
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(540, 320)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var rows := VBoxContainer.new()
	rows.name = "TrashRows"
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 8)
	scroll.add_child(rows)
	dlg.add_child(scroll)
	var entries: Array[Dictionary] = VaultStore.trash_entries()
	if entries.is_empty():
		var empty := Label.new()
		empty.name = "TrashEmpty"
		empty.text = "Nothing here. Notes and folders you delete wait here until you restore them."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rows.add_child(empty)
	for entry in entries:
		rows.add_child(_trash_row(dlg, entry))
	dlg.add_button("Show in file manager", true, "show_folder")
	dlg.custom_action.connect(func(action: StringName) -> void:
		if action == &"show_folder":
			_show_trash_folder())
	dlg.visibility_changed.connect(func() -> void:
		if not dlg.visible:
			dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


## One line of the Trash: what it is, where it was, when it went, and Restore.
func _trash_row(dlg: AcceptDialog, entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var icon := TextureRect.new()
	icon.texture = Icons.get_icon("folder" if entry.folder else "file", 16)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(icon)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	var title := Label.new()
	title.text = str(entry.title)
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	text.add_child(title)
	var detail := Label.new()
	detail.text = _trash_row_detail(entry)
	detail.modulate.a = 0.65
	detail.clip_text = true
	detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	text.add_child(detail)
	row.add_child(text)
	var restore := Button.new()
	restore.text = "Restore"
	restore.tooltip_text = "Put “%s” back" % entry.title
	restore.pressed.connect(func() -> void:
		dlg.hide()
		_restore_trash_entry(entry))
	row.add_child(restore)
	return row


func _trash_row_detail(entry: Dictionary) -> String:
	var parent: String = str(entry.original_rel).get_base_dir()
	var parts: PackedStringArray = ["From " + (parent if parent != "" else "the top level")]
	if entry.folder:
		parts.append("1 note" if entry.notes == 1 else "%d notes" % entry.notes)
	if entry.deleted > 0:
		var bias: int = int(Time.get_time_zone_from_system().get("bias", 0)) * 60
		var at: Dictionary = Time.get_datetime_dict_from_unix_time(entry.deleted + bias)
		var months: PackedStringArray = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
		parts.append("Deleted %s %d, %d:%02d" % [months[at.month - 1], at.day, at.hour, at.minute])
	return "  ·  ".join(parts)


## Restore one Trash line. A note goes through the same path as Ctrl+Z, so a
## note deleted this session gets back any words its file couldn't hold.
func _restore_trash_entry(entry: Dictionary) -> void:
	if entry.folder:
		var rel: String = VaultStore.restore_folder_from_trash(entry.trash_rel, entry.original_rel)
		if rel == "":
			_update_status(_with_unsaved("Couldn't restore the folder “%s”: it is no longer in the trash or can't be moved" % entry.title))
			return
		_collapsed.erase(rel)
		_after_vault_op(_with_unsaved("Restored folder “%s”" % rel))
		return
	var kept: Dictionary = {}
	for t in _trashed:
		if t.trash_rel == entry.trash_rel and not t.has("folder"):
			kept = t
			break
	if kept.is_empty():
		kept = {"trash_rel": entry.trash_rel, "original_rel": entry.original_rel, "title": entry.title, "at": UndoRedoEngine.tick()}
	else:
		_trashed.erase(kept)
	_trashed.append(kept)
	_restore_last_trashed()


## Open <vault>/.trash in the file manager (made first, so an empty trash opens too).
func _show_trash_folder() -> void:
	var dir: String = VaultStore.vault_path.path_join(VaultStore.TRASH_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	OS.shell_open(dir)


## Ctrl+Z outside the editor and the palette's Undo: undo whatever came
## last, a deleted note (restored) or an edit (_undo). A pending edit is saved
## first, so it counts as the latest; if that save met an outside edit, its
## conflict copy is what this press shows, and nothing is undone.
func _undo_last_change() -> void:
	if _flush_pending_save():
		return
	var edit_at: int = UndoRedoEngine.next_undo_at()
	if not _trashed.is_empty() and int(_trashed.back().at) > edit_at:
		_restore_last_trashed()
	elif not _undo() and not _trashed.is_empty():
		_restore_last_trashed()


## Step the app's text history back (UndoRedoEngine.undo): the text a note
## had before its last saved edit goes back into the note and its file, and
## the note shows it in the current view. False if there was nothing to undo.
func _undo() -> bool:
	return _step_history(true)


## Redo what _undo undid (Ctrl+Y, Ctrl+Shift+Z).
func _redo() -> bool:
	return _step_history(false)


func _step_history(back: bool) -> bool:
	if _undo_engine == null:
		return false
	if _flush_pending_save():   # typed words become a step first, so undo starts from them
		return true   # they met an outside edit: the conflict copy is this press's news
	var note: ContentLayer = _undo_engine.call("undo" if back else "redo")
	if note == null:
		_update_status("Nothing to undo" if back else "Nothing to redo")
		return false
	var saved: bool = _track_save(note, UndoRedoEngine.last_save_result == OK)
	if note != current_note:
		_open_note(note)   # an undo shows the note it changed
	if saved and _open_conflict_copy():
		return true   # the file changed outside: kept, and the step's text is the copy
	_show_history_step()
	var what: String = "Undid the last change to “%s”  ·  Ctrl+Y to redo" if back else "Redid the change to “%s”"
	_update_status(_unsaved_message() if not saved else _with_unsaved(what % _display_title(note)))
	return true


## After an undo or redo changed the open note's text: put it in the editor
## and re-render a Read or Outline view.
func _show_history_step() -> void:
	_loading = true
	raw_text_layer.text = current_note.raw_text
	raw_text_layer.clear_undo_history()   # this step belongs to the app's history
	_loading = false
	note_meta.text = _format_meta(current_note)
	_update_word_count()
	_refresh_note_list()
	if current_mode in ["structured", "visual"]:
		_switch_layer(current_mode)


## Open a note by title, case-insensitively, the way a [[link]] resolves
## (WikiLinks.resolve): "Note#Heading" opens Note. Clicked [[links]] pass
## create_missing = true, so a link to a note that doesn't exist yet creates
## it (Obsidian behaviour), named by the base title without "#heading".
func open_note_by_title(title: String, create_missing: bool = false) -> void:
	var found: ContentLayer = WikiLinks.resolve(title)
	if found != null:
		_open_note(found)
		return
	var base: String = WikiLinks.base_title(title)
	if not create_missing or base == "":
		_update_status("No note named “%s”" % title)
		return
	_flush_pending_save()
	var created: ContentLayer = VaultStore.create_note(base)
	if created == null:
		_report_create_failed("“%s”" % base)
		return
	search_box.text = ""
	_refresh_note_list()
	_open_note(created)
	_switch_layer("raw")
	raw_text_layer.grab_focus()
	_update_status(_with_unsaved("Created “%s” — it didn't exist yet" % base))


## Open this very note (a "Linked from" row knows the note it shows, so
## notes that share a title each open their own). A note the vault has
## reloaded since the row was drawn is found again by its file; one that is
## gone opens nothing.
func open_note(note: ContentLayer) -> void:
	var found: ContentLayer = note if VaultStore.note_list.has(note) else null
	if found == null and note != null:
		found = _note_at_path(note.resource_path)
	if found == null:
		_update_status("That note is no longer in the vault")
		return
	_open_note(found)


## Open the note in the file at `path` (a graph node's key, a palette row's
## "open:<path>"). Both carry a path, not a place in VaultStore.note_list,
## because the disk watcher re-sorts that list while they are on screen. A
## path no note has any more opens nothing.
func open_note_at_path(path: String) -> void:
	var found: ContentLayer = _note_at_path(path)
	if found == null:
		_update_status("That note is no longer in the vault")
		return
	_open_note(found)


## The note loaded from `path`, or null.
static func _note_at_path(path: String) -> ContentLayer:
	if path == "":
		return null
	for n in VaultStore.note_list:
		if n.resource_path == path:
			return n
	return null



## Outline's heading rows: a click edits the open note with the caret at the
## start of source `line`, centred in the editor; Shift+click (`read`) shows
## Read view scrolled so that heading sits near the top.
func jump_to_line(line: int, read: bool = false) -> void:
	if current_note == null:
		return
	if read:
		_switch_layer("visual")
		await get_tree().process_frame   # let the rendered note lay out first
		await get_tree().process_frame
		var heading: Control = LayerEngine.visual_row_for_line(line)
		if heading != null and current_mode == "visual":
			await _scroll_read_to(heading)
		return
	_switch_layer("raw")
	raw_text_layer.set_caret_line(clampi(line, 0, raw_text_layer.get_line_count() - 1))
	raw_text_layer.set_caret_column(0)
	raw_text_layer.center_viewport_to_caret()
	# The editor was hidden: centre again once it has its laid-out size
	await get_tree().process_frame
	if current_mode == "raw":
		raw_text_layer.center_viewport_to_caret()


## Scroll Read view so `row` sits 24 px below the top. A row a long note's
## build has only just added (LayerEngine.finish_visual) has no position
## until its container lays it out, and the scroll range is still the old
## content's height, so this waits a frame for that layout first.
func _scroll_read_to(row: Control) -> void:
	await get_tree().process_frame
	if not is_instance_valid(row) or not row.is_inside_tree() or current_mode != "visual":
		return
	var content: Control = doc_scroll.get_child(0)
	doc_scroll.scroll_vertical = int(row.global_position.y - content.global_position.y) - 24


# ── Back / Forward ──────────────────────────────────────────────────────────

## Back to the note opened before this one (Alt+Left, a mouse's back button).
## Notes deleted since are skipped.
func go_back() -> void:
	if _commit_typed_title():
		_navigate(_nav.back(_note_exists_at), "Back to", "Nothing to go back to")


## Forward again after going back (Alt+Right, a mouse's forward button).
func go_forward() -> void:
	if _commit_typed_title():
		_navigate(_nav.forward(_note_exists_at), "Forward to", "Nothing to go forward to")


## The nav keys, the mouse's side buttons, Ctrl+N, a Read view [[link]] and
## a graph node don't move focus, so a title typed into the focused field
## hasn't been committed yet (a sidebar click commits it through
## focus_exited). Commit it before leaving the note (_open_note); a
## field still showing what _open_note put there is left alone, and so is an
## unfocused one: nobody is typing there, focus_exited already committed
## what was typed, and a field that only lags an outside rename must not
## write the old title back. Returns false when the rename hit an outside
## edit and its conflict copy is now open, so Back / Forward stop there and
## the user sees what happened.
func _commit_typed_title() -> bool:
	if current_note == null or not title_edit.has_focus() or title_edit.text == _title_shown:
		return true
	var note: ContentLayer = current_note
	_commit_title()
	return current_note == note


func _navigate(path: String, verb: String, nowhere: String) -> void:
	var note: ContentLayer = _note_at_path(path)
	if note == null:
		_update_status(nowhere)
		return
	_navigating = true
	_open_note(note)
	_navigating = false
	_update_status("%s \u201c%s\u201d" % [verb, _display_title(note)])


func _note_exists_at(path: String) -> bool:
	return _note_at_path(path) != null


## -1 for Back, 1 for Forward, 0 for any other event. Alt+Left / Alt+Right,
## Ctrl+[ / Ctrl+] (Cmd on a Mac), and the mouse's side buttons. On a Mac,
## Alt+arrows inside a text field keep moving by words.
func _nav_direction(event: InputEvent) -> int:
	var mb := event as InputEventMouseButton
	if mb != null:
		if not mb.pressed or mb.button_index not in [MOUSE_BUTTON_XBUTTON1, MOUSE_BUTTON_XBUTTON2]:
			return 0
		return -1 if mb.button_index == MOUSE_BUTTON_XBUTTON1 else 1
	var k := event as InputEventKey
	if k == null or not k.pressed or k.shift_pressed:
		return 0
	if k.alt_pressed and not _cmd(k) and k.keycode in [KEY_LEFT, KEY_RIGHT] and _alt_arrows_navigate():
		return -1 if k.keycode == KEY_LEFT else 1
	if _cmd(k) and not k.alt_pressed and k.keycode in [KEY_BRACKETLEFT, KEY_BRACKETRIGHT]:
		return -1 if k.keycode == KEY_BRACKETLEFT else 1
	return 0


func _alt_arrows_navigate() -> bool:
	var focus: Control = get_viewport().gui_get_focus_owner()
	return not OS.has_feature("macos") or not (focus is TextEdit or focus is LineEdit)


## The palette's hint for Go back (-1) / Go forward (1).
static func _nav_hint(dir: int) -> String:
	if OS.has_feature("macos"):
		return "Cmd+[" if dir < 0 else "Cmd+]"
	return "Alt+Left" if dir < 0 else "Alt+Right"


func _update_status(msg: String) -> void:
	if status_label != null:
		status_label.text = msg
		status_label.tooltip_text = msg   # the bar cuts a long message short (…): hovering shows all of it


## After a vault scan: name the files it skipped because they contain code
## (VaultStore.unsafe_warning), else show `msg`; either way followed by the
## notes whose save failed (_with_unsaved).
func _update_status_after_scan(msg: String) -> void:
	var skipped: String = VaultStore.unsafe_warning()
	_update_status(_with_unsaved(skipped if skipped != "" else msg))


# ── Star and pin ────────────────────────────────────────────────────────────

## Star or unstar the open note (the top bar's star, the palette).
func _toggle_star() -> void:
	_toggle_open_note_flag(&"starred_at")


## Pin or unpin the open note (the top bar's pin, the palette).
func _toggle_pin() -> void:
	_toggle_open_note_flag(&"pinned_at")


## Flip a flag on the open note. Pending typing, tag edits and a typed
## title are saved first, so they land with a real `modified` stamp (the
## flag itself never bumps it); if that save wrote a conflict copy, the copy
## is current_note now and takes the flag.
func _toggle_open_note_flag(field: StringName) -> void:
	if current_note == null:
		_update_star_pin_buttons()
		_update_status("No note open")
		return
	_save_pending_edits()
	var status: String = _toggle_note_flag(current_note, field)
	_show_reloaded_current_note()
	_update_star_pin_buttons()
	_update_status(status)


## Flip `field` (starred_at / pinned_at) on any note and refresh the sidebar;
## returns the status line saying what happened. The open note stays open.
## Flagging another note saves only that note (no rescan), so an outside
## edit of the open note is still unread: the watcher's pass runs here,
## which skips the app's own save (VaultStore.changed_outside) and shows that
## edit before the user types over a stale copy. Callers flush pending edits
## first, so the pass may reload the open note, and call
## _show_reloaded_current_note after.
func _toggle_note_flag(note: ContentLayer, field: StringName) -> String:
	var on: bool = str(note.get(field)) == ""
	var ok: bool = VaultStore.set_starred(note, on) if field == &"starred_at" else VaultStore.set_pinned(note, on)
	var status: String = _flag_status(note, field, on, ok)
	_refresh_note_list()
	check_disk_changes()
	return status


func _flag_status(note: ContentLayer, field: StringName, on: bool, ok: bool) -> String:
	var title: String = _display_title(note)
	if not ok:
		var verb: String = ("star" if on else "unstar") if field == &"starred_at" else ("pin" if on else "unpin")
		if VaultStore.last_save_error != "":   # the write failed (read-only file, full disk)
			return "Couldn't %s “%s”: %s" % [verb, title, VaultStore.last_save_error]
		return "Couldn't %s “%s”: its file changed on disk and doesn't load as a note" % [verb, title]
	if field == &"starred_at":
		return ("Starred “%s”" if on else "Unstarred “%s”") % title
	return ("Pinned “%s” to the top" if on else "Unpinned “%s”") % title


## set_starred / set_pinned read an outside edit of the note into the same
## object before flagging it, and their save's rescan does the same for the
## open note when another note is flagged. Show that version: the editor's
## stale text would otherwise be autosaved over it on the next keystroke.
func _show_reloaded_current_note() -> void:
	if current_note == null:
		return
	var shown_title: String = "" if _display_title(current_note) == "Untitled" else current_note.title
	if current_note.raw_text == raw_text_layer.text and shown_title == title_edit.text:
		return
	var note: ContentLayer = current_note
	_open_note(note)
	if current_mode in ["structured", "visual"]:
		_switch_layer(current_mode)


## The top bar's star and pin follow the open note: pressed and filled (in
## the accent colour) when on, outline when off, disabled with no note open.
func _update_star_pin_buttons() -> void:
	if star_btn == null or pin_btn == null:
		return
	var starred: bool = current_note != null and current_note.starred_at != ""
	var pinned: bool = current_note != null and current_note.pinned_at != ""
	_set_flag_button(star_btn, starred, "star",
		"Starred — click to unstar" if starred else "Star this note (shows under Starred)")
	_set_flag_button(pin_btn, pinned, "pin",
		"Pinned to the top — click to unpin" if pinned else "Pin this note to the top of the list")


func _set_flag_button(btn: Button, on: bool, icon: String, tip: String) -> void:
	btn.disabled = current_note == null
	btn.set_pressed_no_signal(on)
	btn.icon = Icons.get_icon(icon + "_filled" if on else icon)
	btn.tooltip_text = tip
	var accent: Color = _palette_colors.get("accent", Color.WHITE)
	for state in ["icon_pressed_color", "icon_hover_pressed_color"]:
		btn.add_theme_color_override(state, accent)


# ── Layers ──────────────────────────────────────────────────────────────────

func _switch_layer(mode: String) -> void:
	if not layer_buttons.has(mode):
		return
	_sync_raw_text()
	_close_link_popup()
	current_mode = mode
	_save_session()
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
		# The hint goes up now, not after the await below: a status the caller
		# sets after this call (a conflict copy's notice) must stay, not be
		# replaced a frame later.
		_update_status("Graph  ·  drag to move, scroll to zoom, double-click to open")
		# The graph lays nodes out inside its current size, which is 0x0 until
		# the container has sized it — so feed it data after the next layout.
		await get_tree().process_frame
		if current_mode == "graph":
			_show_graph_data()
		return
	graph_layer.visible = false
	note_content.visible = current_note != null
	empty_state_panel.visible = current_note == null
	doc_scroll.visible = mode != "raw"
	if current_note != null:
		LayerEngine.set_note(current_note, false)   # set_mode renders; not the mode being left
	LayerEngine.set_mode(mode)
	if mode == "raw":
		raw_text_layer.grab_focus()
	_update_status(MODE_NAMES[mode] + " view")


# ── Input ───────────────────────────────────────────────────────────────────

## Shortcuts say Ctrl; on a Mac, Cmd works the same.
static func _cmd(k: InputEventWithModifiers) -> bool:
	return k.ctrl_pressed or k.meta_pressed


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k: InputEventKey = event as InputEventKey
	if k.keycode == KEY_F2 and not _cmd(k) and _f2_renames_from(get_viewport().gui_get_focus_owner()):
		_rename_note_prompt(current_note)
		get_viewport().set_input_as_handled()
		return
	if not _cmd(k):
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
		KEY_Z, KEY_Y:
			# In the editor, Ctrl+Z / Ctrl+Y are the TextEdit's own undo, never also this one
			if raw_text_layer.has_focus():
				handled = false
			elif current_mode in ["graph", "journey"]:
				# No note's text is on screen there: a key press must not
				# change one unseen (the palette's Undo and Redo still do)
				_update_status("Undo and redo work in Edit, Outline and Read view")
			elif k.keycode == KEY_Y or k.shift_pressed:
				_redo()
			else:
				_undo_last_change()
		_:
			handled = false
	if handled:
		get_viewport().set_input_as_handled()


## F2 renames the open note while a sidebar row, the editor or the Read /
## Outline view has focus, or nothing has (a renamed row was rebuilt); never
## while typing in another field such as search or the title itself.
func _f2_renames_from(focus: Control) -> bool:
	if current_note == null or current_mode in ["graph", "journey"]:
		return false
	return focus == null or focus == raw_text_layer or note_list_container.is_ancestor_of(focus) or doc_scroll.is_ancestor_of(focus)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_swallow_tag_suggest_double_click(event as InputEventMouseButton)
		_swallow_link_double_click(event as InputEventMouseButton)
	# Back / Forward work over the editor too, so they live here
	var nav: int = 0 if _palette_visible else _nav_direction(event)
	if nav != 0:
		if nav < 0:
			go_back()
		else:
			go_forward()
		get_viewport().set_input_as_handled()
		return
	# Palette keys must win over focused text fields, so they live in _input
	if not (event is InputEventKey and event.pressed):
		return
	var k: InputEventKey = event as InputEventKey
	if _scene_overlay != null and k.keycode == KEY_ESCAPE:
		close_scene_overlay()
		get_viewport().set_input_as_handled()
		return
	if _image_overlay != null and k.keycode == KEY_ESCAPE:
		close_image_viewer()
		get_viewport().set_input_as_handled()
		return
	if _cmd(k) and k.keycode in [KEY_EQUAL, KEY_PLUS, KEY_KP_ADD, KEY_MINUS, KEY_KP_SUBTRACT, KEY_0, KEY_KP_0]:
		# Zoom works from anywhere, even inside the editor
		_execute_command("zoom_in" if k.keycode in [KEY_EQUAL, KEY_PLUS, KEY_KP_ADD] else "zoom_out" if k.keycode in [KEY_MINUS, KEY_KP_SUBTRACT] else "zoom_reset")
		get_viewport().set_input_as_handled()
	elif _cmd(k) and k.keycode == KEY_P:
		if _palette_visible:
			_close_palette()
		else:
			_open_palette()
		get_viewport().set_input_as_handled()
	elif _cmd(k) and k.shift_pressed and k.keycode == KEY_E and not k.echo:
		# Works from the editor and the title field too
		if _palette_visible:
			_close_palette()
		_focus_note_list()
		get_viewport().set_input_as_handled()
	elif _cmd(k) and k.keycode == KEY_N and raw_text_layer.has_focus():
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

## Opens on the folder a launch said holds notes this vault lacks (the
## fallback kept while macOS refused Documents, VaultStore.kept_in_fallback),
## so Import brings them in; else on Downloads.
func _on_import_vault_pressed() -> void:
	import_dialog.title = "Choose a folder of notes to import"
	var kept: String = VaultStore.kept_in_fallback
	import_dialog.current_dir = kept.trim_suffix("/") if kept != "" and DirAccess.dir_exists_absolute(kept) else _get_download_path()
	import_dialog.popup_centered(Vector2i(720, 480))


## "Import notes from a folder…": every note under `src` (another vault, an
## export, a course of .md files) comes in with its folders, models, images
## and Learning Journey (VaultStore.import_vault). Returns its result.
func _on_import_dir_selected(src: String) -> Dictionary:
	_flush_pending_save()   # a title the import checks against is the one on screen
	var r: Dictionary = _run_import(PackedStringArray([src]), "")
	_update_status(import_summary(r))
	return r


## VaultStore.import_paths(paths, into), then show what it brought in: the
## sidebar and the Journey tab. Its rescan reloads the open note in place
## when the note changed on disk, and takes the new file's hash. An outside
## edit the watcher hadn't seen yet would then never reach the editor, and
## the next save would overwrite it with no conflict copy. So the disk is
## marked as seen only when it held no unseen change before the import;
## otherwise the watcher's check runs now and reopens the note.
func _run_import(paths: PackedStringArray, into: String) -> Dictionary:
	var seen: bool = VaultStore.disk_signature() == _last_sig
	var r: Dictionary = VaultStore.import_paths(paths, into)
	if seen:
		_last_sig = VaultStore.disk_signature()
	else:
		check_disk_changes()
	_refresh_note_list()
	if current_mode == "journey":
		journey_panel.refresh()
	return r


## One status line for an import result (VaultStore.import_paths).
static func import_summary(r: Dictionary) -> String:
	var parts: PackedStringArray = []
	var errors: Array = r.get("errors", [])
	if not errors.is_empty():
		parts.append("Couldn't import " + ", ".join(PackedStringArray(errors)))
	var notes: int = int(r.get("notes", 0)) + int(r.get("md", 0))
	if notes > 0 or errors.is_empty():
		var line: String = _count(notes, "note")
		if int(r.get("md", 0)) > 0:
			line += " (%d from Markdown)" % int(r.md)
		parts.append("Imported " + line)
	if int(r.get("folders", 0)) > 0:
		parts.append(_count(r.folders, "new folder"))
	if int(r.get("renamed", 0)) > 0:
		parts.append("%d renamed: %s title was taken" % [int(r.renamed), "its" if int(r.renamed) == 1 else "their"])
	if int(r.get("same", 0)) > 0:
		parts.append("%s already here" % _count(r.same, "note"))
	if int(r.get("invalid", 0)) > 0:
		parts.append("%s that %s left out" % [_count(r.invalid, "file"), "isn't a note" if int(r.invalid) == 1 else "aren't notes"])
	var assets: PackedStringArray = []
	if int(r.get("models", 0)) > 0:
		assets.append(_count(r.models, "model file"))
	if int(r.get("images", 0)) > 0:
		assets.append(_count(r.images, "image"))
	if not assets.is_empty():
		parts.append(" and ".join(assets))
	var clashes: int = int(r.get("model_conflicts", 0)) + int(r.get("image_conflicts", 0))
	if clashes > 0:
		parts.append("%s left out: the vault has a different file by %s name" % [_count(clashes, "model or image", "models or images"), "that" if clashes == 1 else "each"])
	if int(r.get("failed", 0)) > 0:
		parts.append("%s couldn't be written" % _count(r.failed, "file"))
	var links: Array = r.get("links", [])
	if not links.is_empty():
		parts.append("left out %s that link elsewhere: %s" % [_count(links.size(), "folder"), ", ".join(PackedStringArray(links))])
	var journey: Dictionary = r.get("journey", {})
	var added: PackedStringArray = []
	for k in [["topics", "topic"], ["objectives", "objective"], ["demos", "demonstration"], ["logs", "score"]]:
		if int(journey.get(k[0], 0)) > 0:
			added.append(_count(journey[k[0]], k[1]))
	if not added.is_empty():
		parts.append("Learning Journey: added " + ", ".join(added))
	return "  \u00b7  ".join(parts)


## "1 note", "3 notes".
static func _count(n: int, one: String, many: String = "") -> String:
	return "%d %s" % [n, one if n == 1 else (many if many != "" else one + "s")]


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
		{"label": "Star / unstar note", "hint": "", "action": "star"},
		{"label": "Pin / unpin note", "hint": "", "action": "pin"},
		{"label": "Edit view", "hint": "Ctrl+1", "action": "mode:raw"},
		{"label": "Outline view", "hint": "Ctrl+2", "action": "mode:structured"},
		{"label": "Reading view", "hint": "Ctrl+3", "action": "mode:visual"},
		{"label": "Graph view", "hint": "Ctrl+4", "action": "mode:graph"},
		{"label": "Learning Journey", "hint": "Ctrl+5", "action": "mode:journey"},
		{"label": "Go back", "hint": _nav_hint(-1), "action": "nav_back"},
		{"label": "Go forward", "hint": _nav_hint(1), "action": "nav_forward"},
		{"label": "Go to the note list: arrows, Enter, F2, Delete, Shift+F10, Esc", "hint": "Ctrl+Shift+E", "action": "focus_list"},
		{"label": "New folder", "hint": "", "action": "new_folder"},
		{"label": "Open vault folder… (or create one)", "hint": "vault", "action": "open_vault"},
		{"label": "Show vault in file manager", "hint": "vault", "action": "reveal_vault"},
		{"label": "Open log folder", "hint": "support", "action": "open_log"},
		{"label": "Toggle light / dark theme", "hint": "", "action": "theme"},
		{"label": "Follow system theme (light / dark)", "hint": "", "action": "theme_system"},
		{"label": "Undo", "hint": "Ctrl+Z", "action": "undo"},
		{"label": "Redo", "hint": "Ctrl+Y", "action": "redo"},
		{"label": "Delete current note", "hint": "", "action": "delete_note"},
		{"label": "Restore last deleted note", "hint": "Ctrl+Z", "action": "restore_trash"},
		{"label": "Open Trash", "hint": "", "action": "trash_panel"},
		{"label": "Show trash folder", "hint": "", "action": "show_trash"},
		{"label": "Import notes from a folder…", "hint": "", "action": "import"},
		{"label": "Insert 3D scene: Galaxy", "hint": "3d", "action": "insert3d:galaxy"},
		{"label": "Insert 3D scene: Torus knot", "hint": "3d", "action": "insert3d:knot"},
		{"label": "Insert 3D scene: Terrain flyover", "hint": "3d", "action": "insert3d:terrain"},
		{"label": "Insert 3D scene: Wave field", "hint": "3d", "action": "insert3d:waves"},
		{"label": "Insert 3D scene: Atom", "hint": "3d", "action": "insert3d:atom"},
		{"label": "Insert 3D scene: Vault graph", "hint": "3d", "action": "insert3d:graph"},
		{"label": "Insert quiz (3D, multiple choice)", "hint": "quiz", "action": "insert3d:quiz"},
		{"label": "Insert flashcards", "hint": "cards", "action": "insert3d:flashcards"},
		{"label": "Insert shapes scene", "hint": "3d", "action": "insert3d:shapes"},
		{"label": "Insert image… (.png, .jpg, .webp)", "hint": "image", "action": "import_image"},
		{"label": "Import 3D model… (.glb, .gltf, .fbx)", "hint": "3d", "action": "import_model"},
		{"label": "Reset quiz progress", "hint": "", "action": "reset_progress"},
		{"label": "Export vault", "hint": "", "action": "export"},
		{"label": "Export note as Markdown", "hint": "", "action": "export_md"},
		{"label": "Export all notes as Markdown", "hint": "", "action": "export_md_all"},
		{"label": "Set Markdown export folder…", "hint": "", "action": "export_md_folder"},
		{"label": "Reset Markdown export folder", "hint": "", "action": "export_md_folder_reset"},
		{"label": "Add the tutorials and starter course", "hint": "", "action": "add_starter"},
		{"label": "Zoom in (Ctrl+=)", "hint": "", "action": "zoom_in"},
		{"label": "Zoom out (Ctrl+-)", "hint": "", "action": "zoom_out"},
		{"label": "Actual size (Ctrl+0)", "hint": "", "action": "zoom_reset"},
		{"label": "Connect Claude Desktop…", "hint": "", "action": "connect_claude"},
		{"label": "About Ontomeme", "hint": "", "action": "about"},
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
	# Notes: the sidebar's search (every word in the title or body, best
	# first), each with its excerpt; opening one lands on the match. A row
	# names the note's file, not its index: the disk watcher re-sorts
	# VaultStore.note_list while the palette is open.
	_palette_hits.clear()
	for hit in VaultStore.search(f):
		var path: String = (hit.note as ContentLayer).resource_path
		_palette_hits[path] = hit
		_add_palette_row("◇  " + _display_title(hit.note), _short_excerpt(hit) if hit.excerpt != "" else "note", "open:" + path)
	_palette_selected_index = 0
	_highlight_palette_item()


func _add_palette_row(label: String, hint: String, action: String) -> void:
	var text: String = label if hint == "" else label + "    " + hint
	_palette_list.add_item(text)
	_palette_items.append({"label": label, "action": action})


func _open_palette() -> void:
	_close_link_popup()
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
	# Save now (forced): TextEdit emits text_changed deferred, so no autosave
	# is pending yet, and once Read view has synced the text it never starts.
	_flush_pending_save(true)
	_switch_layer("visual")
	_update_status(status)


# ── Image import ────────────────────────────────────────────────────────────

## A file bigger than this asks "Add it anyway?" before it is copied.
static var large_image_bytes: int = 5 * 1024 * 1024

var _image_dialog: FileDialog = null
var _large_image_prompt: ConfirmationDialog = null
var _large_images: PackedStringArray = []   # waiting for a yes or no; [0] is being asked


func _open_image_dialog() -> void:
	if _image_dialog == null:
		_image_dialog = FileDialog.new()
		_image_dialog.name = "ImageDialog"
		_image_dialog.title = "Insert an image"
		_image_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_image_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_image_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
		_image_dialog.ok_button_text = "Insert"
		_image_dialog.size = Vector2i(760, 500)
		_image_dialog.current_dir = _pictures_dir()
		_image_dialog.file_selected.connect(func(path: String) -> void: import_image_file(path))
		add_child(_image_dialog)
	_image_dialog.popup_centered()


## The user's Pictures folder, or their home folder when there is none.
static func _pictures_dir() -> String:
	var pictures: String = OS.get_system_dir(OS.SYSTEM_DIR_PICTURES)
	if pictures != "" and DirAccess.dir_exists_absolute(pictures):
		return pictures
	return OS.get_environment("USERPROFILE" if OS.get_name() == "Windows" else "HOME")


## Copy an image into <vault>/images/ and insert `![Caption](images/<name>)`
## at the caret; Read view then shows it. An image already in images/ is
## used where it is, and a file there with the same name and bytes is reused,
## so dropping a picture twice stores it once. A file over large_image_bytes
## asks first and comes back here with `force` on a yes. Returns the stored
## path under images/, or "" when nothing was inserted.
func import_image_file(path: String, force: bool = false) -> String:
	if path.get_extension().to_lower() not in ImageEmbeds.EXTS:
		_update_status("Not a supported image (png, jpg, webp): " + path.get_file())
		return ""
	var size: int = _file_size(path)
	if size < 0:
		_update_status("Image not found: " + path)
		return ""
	if size > large_image_bytes and not force:
		_ask_large_image(path)
		return ""
	var stored: String = _store_image(path)
	if stored == "":
		_update_status("Couldn't copy %s into the vault's images folder" % path.get_file())
		return ""
	var caption: String = path.get_file().get_basename().replace("_", " ").replace("-", " ").capitalize()
	_insert_block(ImageEmbeds.ref_line(caption, ImageEmbeds.DIR.path_join(stored)), "Inserted image: images/" + stored)
	return stored


## Where `path` is kept under <vault>/images/, relative to it: the file
## itself when it is already in there, a file of the same name and SHA-256,
## or a new copy named <stem>.<ext>, <stem>_1.<ext>, <stem>_2.<ext>…
## "" when the copy fails.
func _store_image(path: String) -> String:
	var dir: String = VaultStore.vault_path.path_join(ImageEmbeds.DIR)
	var inside: String = _path_under(path, dir)
	if inside != "":
		return inside
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		return ""
	var sha: String = FileAccess.get_sha256(path)
	var stem: String = path.get_file().get_basename()
	var fname: String = path.get_file()
	var i: int = 0
	while FileAccess.file_exists(dir.path_join(fname)) or DirAccess.dir_exists_absolute(dir.path_join(fname)):
		if FileAccess.file_exists(dir.path_join(fname)) and FileAccess.get_sha256(dir.path_join(fname)) == sha:
			return fname
		i += 1
		fname = "%s_%d.%s" % [stem, i, path.get_extension()]
	return fname if DirAccess.copy_absolute(path, dir.path_join(fname)) == OK else ""


## `path` relative to the folder `dir` when it lies inside it, else "".
static func _path_under(path: String, dir: String) -> String:
	var prefix: String = dir.simplify_path().trim_suffix("/") + "/"
	var p: String = path.simplify_path()
	return p.substr(prefix.length()) if p.begins_with(prefix) else ""


## Size of a file in bytes, or -1 when it can't be opened.
static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f != null else -1


## "6.2 MB" or "350 KB".
static func _size_text(bytes: int) -> String:
	if bytes >= 1024 * 1024:
		return "%.1f MB" % (bytes / 1048576.0)
	return "%d KB" % ceili(bytes / 1024.0)


## Queue a large image for "Add it anyway?". One prompt at a time: a drop
## of several large files asks about each in turn.
func _ask_large_image(path: String) -> void:
	if path in _large_images:
		return
	_large_images.append(path)
	if _large_images.size() == 1:
		_show_large_image_prompt()


func _show_large_image_prompt() -> void:
	if _large_images.is_empty():
		return
	if _large_image_prompt == null:
		_large_image_prompt = ConfirmationDialog.new()
		_large_image_prompt.name = "LargeImagePrompt"
		_large_image_prompt.title = "Large image"
		_large_image_prompt.ok_button_text = "Add it"
		_large_image_prompt.confirmed.connect(_on_large_image_answer.bind(true))
		_large_image_prompt.canceled.connect(_on_large_image_answer.bind(false))
		add_child(_large_image_prompt)
	var path: String = _large_images[0]
	_large_image_prompt.dialog_text = "This image is %s. Add it anyway?\n%s is copied into the vault's images folder." \
		% [_size_text(_file_size(path)), path.get_file()]
	_large_image_prompt.popup_centered()


func _on_large_image_answer(add: bool) -> void:
	if _large_images.is_empty():
		return
	var path: String = _large_images[0]
	_large_images.remove_at(0)
	if add:
		import_image_file(path, true)
	else:
		_update_status("Left out " + path.get_file())
	_show_large_image_prompt.call_deferred()


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
		_model_dialog.current_dir = _get_download_path()
		_model_dialog.file_selected.connect(func(path: String) -> void: import_model_file(path))
		add_child(_model_dialog)
	_model_dialog.popup_centered()


## Files dropped on the window. A 3D model goes into the open note as a
## ```3d block (import_model_file), and a png, jpg or webp picture as an
## image line (import_image_file: copied into images/; a large one asks
## first, and the question is then the news). Folders, .tres notes and .md
## files are imported into the open note's folder (VaultStore.import_paths:
## a folder's notes keep their subfolders, its Journey merges), and the first
## imported note opens. Another kind of picture (a .gif) only gets the
## image import's status line. One status line covers it all.
func _on_files_dropped(files: PackedStringArray) -> void:
	_flush_pending_save()
	var into: String = VaultStore.folder_of(current_note)
	var notes: PackedStringArray = []
	var said: PackedStringArray = []
	var other: int = 0
	for f in files:
		var ext: String = f.get_extension().to_lower()
		if ext in NoteScene3D.MODEL_EXTS:
			import_model_file(f)
			said.append(status_label.text)   # what the model import reported
		elif ext in ["md", "tres"] or DirAccess.dir_exists_absolute(f):
			notes.append(f)
		elif ext in ImageEmbeds.EXTS or ext in IMAGE_LIKE_EXTS:
			import_image_file(f)
			if f not in _large_images:   # else the "Add it anyway?" dialog says it
				said.append(status_label.text)   # what the image import reported
		else:
			other += 1
	if not notes.is_empty():
		var r: Dictionary = _run_import(notes, into)
		if not r.imported.is_empty():
			_open_note(r.imported[0])
			if current_mode in ["structured", "visual"]:
				_switch_layer(current_mode)
		said.append(import_summary(r))
	if other > 0:
		said.append("%s left out: not notes, folders, images or 3D models" % _count(other, "file"))
	if not said.is_empty():
		_update_status("  \u00b7  ".join(said))


## Copy a model into <vault>/models/ and insert a ```3d block that shows it.
## A .glb or .fbx is one file in models/. A .gltf gets its own folder,
## models/<stem>[_n]/, with the buffers and images it points at, so two
## models that share a sidecar name (Blender's untitled.bin) never clash.
## A model already in models/ is used where it is. Returns its path under
## models/, or "" when nothing was imported.
func import_model_file(path: String) -> String:
	var ext: String = path.get_extension().to_lower()
	if ext not in NoteScene3D.MODEL_EXTS or not FileAccess.file_exists(path):
		_update_status("Not a 3D model: " + path.get_file())
		return ""
	var models: String = VaultStore.vault_path.path_join("models")
	var r: Dictionary = {"stored": _path_in_models(path, models), "left_out": PackedStringArray(), "missing": PackedStringArray()}
	if r.stored == "":
		r = _copy_gltf_model(path, models) if ext == "gltf" else _copy_model_file(path, models)
	var stored: String = r.stored
	if stored == "":
		_update_status("Couldn't import " + path.get_file())
		return ""
	var label: String = stored.get_base_dir().get_file() if ext == "gltf" and stored.contains("/") else stored.get_file().get_basename()
	var caption: String = label.replace("_", " ").replace("-", " ").capitalize()
	_insert_block("```3d\nmodel: %s, spin\ncaption: %s\n```" % [stored, caption], _import_status(stored, r.left_out, r.missing))
	return stored


## "Imported 3D model: <path>", plus any sidecars left out or not found.
func _import_status(stored: String, left_out: PackedStringArray, missing: PackedStringArray) -> String:
	var notes: PackedStringArray = []
	if not left_out.is_empty():
		notes.append("left out %d unsafe path%s: %s" % [left_out.size(), "" if left_out.size() == 1 else "s", ", ".join(left_out)])
	if not missing.is_empty():
		notes.append("%d file%s not found: %s" % [missing.size(), "" if missing.size() == 1 else "s", ", ".join(missing)])
	return "Imported 3D model: " + stored + (" (%s)" % "; ".join(notes) if not notes.is_empty() else "")


## `path` relative to models/ when it is already inside it, else "".
static func _path_in_models(path: String, models: String) -> String:
	var p: String = path.simplify_path()
	var prefix: String = models.simplify_path().trim_suffix("/") + "/"
	return p.substr(prefix.length()) if p.begins_with(prefix) else ""


## `stem` + `ext`, or "<stem>_1<ext>", "<stem>_2<ext>"… while `dir` has it.
static func _free_name(dir: String, stem: String, ext: String) -> String:
	var name: String = stem + ext
	var i: int = 1
	while FileAccess.file_exists(dir.path_join(name)) or DirAccess.dir_exists_absolute(dir.path_join(name)):
		name = "%s_%d%s" % [stem, i, ext]
		i += 1
	return name


## A .glb or .fbx: one file in models/ (no sidecars).
func _copy_model_file(path: String, models: String) -> Dictionary:
	var fname: String = _free_name(models, path.get_file().get_basename(), "." + path.get_extension())
	var written: Array[String] = []
	var ok: bool = DirAccess.make_dir_recursive_absolute(models) == OK and _copy_tracked(path, models.path_join(fname), written)
	if not ok:
		_discard_import(written)
	return {"stored": fname if ok else "", "left_out": PackedStringArray(), "missing": PackedStringArray()}


## A .gltf: a new folder models/<stem>[_n]/ with the .gltf and every buffer
## and image it points at by relative uri. A uri that could leave that folder
## is left out and a missing file is reported; a failed copy removes what
## this import wrote and returns stored "".
func _copy_gltf_model(path: String, models: String) -> Dictionary:
	var folder_name: String = _free_name(models, path.get_file().get_basename(), "")
	var folder: String = models.path_join(folder_name)
	var left_out: PackedStringArray = []
	var missing: PackedStringArray = []
	var written: Array[String] = []
	var ok: bool = DirAccess.make_dir_recursive_absolute(folder) == OK and _copy_tracked(path, folder.path_join(path.get_file()), written)
	for uri in (_gltf_uris(path) if ok else PackedStringArray()):
		var dest: String = _sidecar_dest(folder, uri)
		if dest == "":
			left_out.append(uri)
			continue
		var src: String = path.get_base_dir().path_join(dest.substr(folder.simplify_path().length() + 1))
		if not FileAccess.file_exists(src):
			missing.append(uri)
		elif DirAccess.make_dir_recursive_absolute(dest.get_base_dir()) != OK or not _copy_tracked(src, dest, written):
			ok = false
			break
	if not ok:
		_discard_import(written, folder)
	return {"stored": folder_name.path_join(path.get_file()) if ok else "", "left_out": left_out, "missing": missing}


## The buffer and image uris of a .gltf that name files (not data: uris).
static func _gltf_uris(gltf_path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(gltf_path))
	if not json is Dictionary:
		return out
	for section in ["buffers", "images"]:
		var entries: Variant = (json as Dictionary).get(section, [])
		for entry in (entries if entries is Array else []):
			var uri: String = str(entry.get("uri", "")) if entry is Dictionary else ""
			if uri != "" and not uri.begins_with("data:") and uri not in out:
				out.append(uri)
	return out


## Where a .gltf sidecar `uri` goes inside the model's `folder`, or "" when
## it could land elsewhere: absolute, a drive letter or scheme ("C:", "file:"),
## a ".." segment, or anything that doesn't simplify to a path under `folder`.
## Decoded the way Godot's glTF loader decodes it.
static func _sidecar_dest(folder: String, uri: String) -> String:
	var rel: String = uri.uri_decode().replace("\\", "/")
	if rel == "" or rel.is_absolute_path() or rel.contains(":") or ".." in rel.split("/"):
		return ""
	var dest: String = folder.path_join(rel).simplify_path()
	return dest if dest.begins_with(folder.simplify_path().trim_suffix("/") + "/") else ""


## Copy one file, noting `dst` first so a failed import can remove it.
static func _copy_tracked(src: String, dst: String, written: Array[String]) -> bool:
	written.append(dst)
	return DirAccess.copy_absolute(src, dst) == OK


## Undo a failed import: remove the files it wrote (all had new names) and,
## deepest first, the folders it made for them: `new_dir` ("" = none) and
## the subfolders inside it. Only empty folders are removed.
static func _discard_import(written: Array[String], new_dir: String = "") -> void:
	var dirs: Array[String] = []
	if new_dir != "":
		dirs.append(new_dir)
	for f in written:
		DirAccess.remove_absolute(f)
		var d: String = f.get_base_dir()
		while new_dir != "" and d.length() > new_dir.length() and d not in dirs:
			dirs.append(d)
			d = d.get_base_dir()
	dirs.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())
	for d in dirs:
		if DirAccess.get_files_at(d).is_empty() and DirAccess.get_directories_at(d).is_empty():
			DirAccess.remove_absolute(d)


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


# ── Image viewer and image menu ─────────────────────────────────────────────

## Full-window view of a Read-view image (LayerEngine._make_image_clickable,
## `info` = {path, target, alt, line}): the picture as large as the window
## allows with its aspect kept, at most IMAGE_MAX_ZOOM times its own size,
## over a dim backdrop, with its caption and a Close button. Esc, Close or a
## click on the backdrop closes it.
func show_image_viewer(info: Dictionary) -> void:
	var tex: Texture2D = ImageEmbeds.load_texture(str(info.get("path", "")))
	if tex == null:
		_update_status("Image not found: " + str(info.get("target", "")))
		return
	close_image_viewer()
	_image_overlay = ColorRect.new()
	_image_overlay.name = "ImageViewer"
	_image_overlay.color = Color(0, 0, 0, 0.8)
	_image_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_image_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_image_overlay.gui_input.connect(_on_image_overlay_input)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_PASS   # backdrop clicks reach the overlay
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PalettePanel"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP     # clicks on the picture don't close it
	var pad := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, IMAGE_VIEWER_PAD)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_viewer_picture = TextureRect.new()
	_viewer_picture.name = "ViewerImage"
	_viewer_picture.texture = tex
	_viewer_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_viewer_picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	box.add_child(_viewer_picture)
	box.add_child(_image_viewer_footer(info))
	pad.add_child(box)
	panel.add_child(pad)
	center.add_child(panel)
	_image_overlay.add_child(center)
	add_child(_image_overlay)
	_image_overlay.resized.connect(_fit_viewer_picture)
	_fit_viewer_picture()


## The viewer's bottom row: the caption (alt text, else the target),
## trimmed with … when long, and the Close button.
func _image_viewer_footer(info: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var caption := Label.new()
	caption.name = "ViewerCaption"
	var alt: String = str(info.get("alt", ""))
	caption.text = alt if alt != "" else str(info.get("target", ""))
	caption.tooltip_text = caption.text
	caption.theme_type_variation = &"MutedLabel"
	caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	caption.clip_text = true
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(caption)
	var close := Button.new()
	close.name = "ViewerClose"
	close.text = "Close  esc"
	close.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close.pressed.connect(close_image_viewer)
	row.add_child(close)
	return row


## Size the viewer for the window: the picture gets the room left inside
## a 40 px margin, the panel's padding and the caption row (fit_image); the
## caption gets its own width when the window has room for it, so a small
## picture still shows its caption whole.
func _fit_viewer_picture() -> void:
	if _image_overlay == null or _viewer_picture == null:
		return
	var box: Control = _viewer_picture.get_parent()
	var panel: Control = box.get_parent().get_parent()
	var chrome: Vector2 = panel.get_theme_stylebox("panel").get_minimum_size() + Vector2.ONE * 2 * IMAGE_VIEWER_PAD
	var footer: HBoxContainer = box.get_child(1)
	var caption: Label = footer.get_node("ViewerCaption")
	var close: Button = footer.get_node("ViewerClose")
	var room: Vector2 = _image_overlay.size - Vector2(80, 80) - chrome
	var text_w: float = caption.get_theme_font("font").get_string_size(caption.text, HORIZONTAL_ALIGNMENT_LEFT, -1, caption.get_theme_font_size("font_size")).x
	caption.custom_minimum_size.x = clampf(ceilf(text_w), 0.0, maxf(0.0, room.x - close.get_combined_minimum_size().x - footer.get_theme_constant("separation")))
	room.y -= footer.get_combined_minimum_size().y + box.get_theme_constant("separation")
	_viewer_picture.custom_minimum_size = fit_image(_viewer_picture.texture.get_size(), room)


## How big to show an image `native` px in `room`: as large as fits with its
## aspect kept, never over `max_zoom` times its own size, at least 1x1 px.
static func fit_image(native: Vector2, room: Vector2, max_zoom: float = IMAGE_MAX_ZOOM) -> Vector2:
	if native.x <= 0.0 or native.y <= 0.0:
		return Vector2.ONE
	var scale: float = minf(max_zoom, minf(room.x / native.x, room.y / native.y))
	return Vector2(maxf(1.0, floorf(native.x * scale)), maxf(1.0, floorf(native.y * scale)))


func close_image_viewer() -> void:
	if _image_overlay != null:
		_image_overlay.queue_free()
		_image_overlay = null
		_viewer_picture = null


func _on_image_overlay_input(event: InputEvent) -> void:
	# A click on the dim backdrop (outside the panel) closes the viewer
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		close_image_viewer()
		get_viewport().set_input_as_handled()


## A Read-view image's right-click menu: View image, Show in file manager,
## Remove from note.
func show_image_menu(info: Dictionary) -> void:
	if _image_menu == null:
		_image_menu = PopupMenu.new()
		_image_menu.name = "ImageMenu"
		_image_menu.id_pressed.connect(_on_image_menu)
		add_child(_image_menu)
	_image_menu_info = info
	_image_menu.clear()
	_image_menu.add_item("View image", IMAGE_VIEW)
	_image_menu.add_item("Show in file manager", IMAGE_SHOW)
	_image_menu.add_separator()
	_image_menu.add_item("Remove from note", IMAGE_REMOVE)
	_image_menu.popup(Rect2i(Vector2i(get_window().position) + Vector2i(get_global_mouse_position()), Vector2i.ZERO))


func _on_image_menu(id: int) -> void:
	var info: Dictionary = _image_menu_info
	match id:
		IMAGE_VIEW: show_image_viewer(info)
		IMAGE_SHOW: OS.shell_show_in_file_manager(str(info.get("path", "")))
		IMAGE_REMOVE: remove_image_from_note(info)


## Remove from note: the image's line is deleted through the editor, so
## Ctrl+Z puts it back, and the note is saved. Then the file goes to the OS
## trash unless a note still names it anywhere (notes_showing_image); then
## it stays, and the status says how many notes use it.
func remove_image_from_note(info: Dictionary) -> void:
	if current_note == null:
		return
	var target: String = str(info.get("target", ""))
	var line: int = _image_ref_line(int(info.get("line", -1)), target)
	if line < 0:
		_update_status("That image isn't in the note any more")
		return
	_remove_editor_line(line)
	_flush_pending_save(true)   # saved now: a step of the app's history, so Ctrl+Z puts it back
	_update_word_count()
	if current_mode in ["structured", "visual"]:
		LayerEngine.set_note(current_note)
	var path: String = str(info.get("path", ""))
	var shown: String = _path_under(path, VaultStore.vault_path)
	if shown == "":
		shown = path.get_file()
	var users: int = notes_showing_image(path)
	if users > 0:
		_update_status("Removed the image from the note  ·  %s is still used by %d note%s" % [shown, users, "" if users == 1 else "s"])
	elif not FileAccess.file_exists(path):
		_update_status("Removed the image from the note")
	elif OS.move_to_trash(path) == OK:
		_update_status("Removed the image from the note and moved %s to the trash  ·  Ctrl+Z puts the line back" % shown)
	else:
		_update_status("Removed the image from the note  ·  couldn't move %s to the trash, so it stays" % shown)


## The editor line that holds the image ref to `target`: `line` when it
## still does, else the first such line, or -1 when the note has none.
func _image_ref_line(line: int, target: String) -> int:
	if line >= 0 and line < raw_text_layer.get_line_count() \
			and str(ImageEmbeds.parse_line(raw_text_layer.get_line(line)).get("target", "")) == target:
		return line
	for ref in ImageEmbeds.refs_in(raw_text_layer.text):
		if ref.target == target:
			return int(ref.line)
	return -1


## Delete editor line `line` as one undo step. A blank line beside it goes
## too when it would otherwise leave two blank lines in a row (an inserted
## image sits between blank lines), or a blank line at either end.
func _remove_editor_line(line: int) -> void:
	var te: TextEdit = raw_text_layer
	var last: int = te.get_line_count() - 1
	var from: int = line
	var to: int = line
	var blank_above: bool = line > 0 and te.get_line(line - 1).strip_edges() == ""
	var blank_below: bool = line < last and te.get_line(line + 1).strip_edges() == ""
	if blank_above and (blank_below or line == last):
		from -= 1
	elif line == 0 and blank_below:
		to += 1
	te.begin_complex_operation()
	if to < last:
		te.remove_text(from, 0, to + 1, 0)
	elif from > 0:
		te.remove_text(from - 1, te.get_line(from - 1).length(), to, te.get_line(to).length())
	else:
		te.remove_text(0, 0, to, te.get_line(to).length())
	te.end_complex_operation()


## How many notes still use the image file at `path` (an absolute path):
## notes that name it anywhere (ImageEmbeds.refers_to), not only on an image
## line of its own. A list item, a paragraph, a link or a wiki embed counts
## too, so Remove from note never trashes a file another note still shows.
static func notes_showing_image(path: String) -> int:
	var n: int = 0
	for note in VaultStore.note_list:
		if ImageEmbeds.refers_to(note.raw_text, path, VaultStore.vault_path):
			n += 1
	return n


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
	elif action == "import_image":
		_open_image_dialog()
	elif action.begins_with("vault:"):
		switch_vault(action.substr(6))
	elif action == "open_vault":
		_open_vault_dialog()
	elif action == "reveal_vault":
		OS.shell_open(VaultStore.vault_path)
	elif action == "open_log":
		_open_log_folder()
	elif action == "about":
		_show_about()
	elif action == "connect_claude":
		preload("res://mcp/desktop_config.gd").open_dialog(self, VaultStore.vault_path)
	elif action == "add_starter":
		_flush_pending_save()
		StarterContent.seed_vault()
		_load_collapsed()   # the seed folds the courses in ui.json when the vault had no folds
		_refresh_note_list()
		open_note_by_title(FIRST_NOTE)
		_switch_layer("visual")
		_update_status("Added the tutorials and the Memetics course")
	elif action in ["zoom_in", "zoom_out", "zoom_reset"]:
		UiScale.set_zoom(1.0 if action == "zoom_reset" else UiScale.step_zoom(1 if action == "zoom_in" else -1))
		if DisplayServer.get_name() != "headless":
			UiScale.apply(get_window())
		_update_status("Zoom %d%%" % roundi(UiScale.zoom * 100))
	elif action == "new_folder":
		_new_folder_prompt("")
	elif action.begins_with("insert3d:"):
		_insert_3d(action.substr(9))
	elif action.begins_with("open:"):
		var path: String = action.substr(5)
		open_note_at_path(path)
		if _palette_hits.has(path) and current_note != null and current_note.resource_path == path:
			_reveal_search_hit(_palette_hits[path])
	else:
		match action:
			"new_note": _on_new_note_pressed()
			"nav_back": go_back()
			"nav_forward": go_forward()
			"focus_list": _focus_note_list()
			"save_note": _on_save_note_pressed()
			"star": _toggle_star()
			"pin": _toggle_pin()
			"theme": _toggle_theme()
			"theme_system": _set_theme_pref("system")
			"undo": _undo_last_change()
			"redo": _redo()
			"delete_note": _on_delete_note_pressed()
			"restore_trash": _restore_last_trashed()
			"show_trash": _show_trash_folder()
			"trash_panel": _show_trash_panel()
			"import": _on_import_vault_pressed()
			"export": _on_export_vault_pressed()
			"export_md": _on_export_md_pressed()
			"export_md_all": _export_all_md()
			"export_md_folder": _open_md_folder_dialog()
			"export_md_folder_reset": _reset_md_folder()


# ── Markdown export (MdExport) ──────────────────────────────────────────────

## The top bar's Export button and the palette's "Export note as Markdown":
## the open note, with any typing not yet autosaved, to
## <export folder>/<folder>/<stem>.md (MdExport.output_root(), exports/ by
## default).
func _on_export_md_pressed() -> void:
	_flush_pending_save()
	if current_note == null:
		_update_status("No note open to export")
		return
	_export_note_md(current_note)


## Write `note` as Markdown (saving pending typing first, so the file holds
## what the editor shows) and say where it went or why it could not.
func _export_note_md(note: ContentLayer) -> void:
	_flush_pending_save()
	var path: String = MdExport.export_note(note)
	if path == "":
		_update_status("Export failed: " + MdExport.last_error)
	else:
		_update_status("Exported to " + _vault_rel(path))


## Palette "Export all notes as Markdown" and the sidebar's "Export all as
## Markdown": every note, each to <export folder>/<folder>/<stem>.md.
func _export_all_md() -> void:
	_flush_pending_save()
	_report_md_batch(MdExport.export_vault(), "")


## A folder's "Export folder as Markdown": the notes in `rel` and below.
func _export_folder_md(rel: String) -> void:
	_flush_pending_save()
	_report_md_batch(MdExport.export_folder(rel), rel)


## "Exported N notes to exports/<folder>/" (+ "; M failed"), from an
## MdExport.export_vault / export_folder result.
func _report_md_batch(r: Dictionary, folder: String) -> void:
	var written: int = r.written
	var failed: int = (r.failed as Array).size()
	if written == 0 and failed == 0:
		_update_status("No notes to export")
	elif written == 0:
		_update_status("Export failed: " + MdExport.last_error)
	else:
		var root: String = r.out
		var dest: String = _vault_rel(root if folder == "" else root.path_join(folder)) + "/"
		var msg: String = "Exported %d note%s to %s" % [written, "" if written == 1 else "s", dest]
		_update_status(msg + ("; %d failed" % failed if failed > 0 else ""))


## `path` relative to the open vault ("exports/Physics/note_x.md"), or as
## it is when it lies outside the vault.
func _vault_rel(path: String) -> String:
	return path.trim_prefix(VaultStore.vault_path)


var _md_folder_dialog: FileDialog = null


## Palette "Set Markdown export folder…": pick the folder this vault's
## Markdown exports go to, starting from the one they go to now.
func _open_md_folder_dialog() -> void:
	if _md_folder_dialog == null:
		_md_folder_dialog = FileDialog.new()
		_md_folder_dialog.name = "MdFolderDialog"
		_md_folder_dialog.title = "Choose the folder this vault's Markdown exports go to"
		_md_folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_md_folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_md_folder_dialog.dir_selected.connect(_set_md_folder)
		add_child(_md_folder_dialog)
	var root: String = MdExport.output_root()
	_md_folder_dialog.current_dir = root if DirAccess.dir_exists_absolute(root) else VaultStore.vault_path
	_md_folder_dialog.popup_centered(Vector2i(760, 500))


## Save `path` as the vault's export folder and say where exports go now, or
## why it was refused.
func _set_md_folder(path: String) -> void:
	if MdExport.set_output_root(path) == OK:
		_update_status("Markdown exports go to " + _md_folder_label())
	else:
		_update_status("Export folder not changed: " + MdExport.last_error)


## Palette "Reset Markdown export folder": back to the vault's exports/.
func _reset_md_folder() -> void:
	if MdExport.clear_output_root() == OK:
		_update_status("Markdown exports go to " + _md_folder_label())
	else:
		_update_status("Couldn't reset the export folder: " + MdExport.last_error)


## The active export folder as the status shows it: "exports/" or another
## folder in the vault, else its absolute path; always ending in "/".
func _md_folder_label() -> String:
	return _vault_rel(MdExport.output_root()) + "/"


## Tests point exports (and the model dialog) here instead of Downloads.
static var download_dir_override: String = ""


## Export the vault: a plain copy of its folder, with the Journey and
## progress, in a new dated folder in Downloads (VaultStore.export_to).
## Never replaces an earlier export. `open_after` = false keeps tests from
## opening a file manager. Returns export_to's result.
func _on_export_vault_pressed(open_after: bool = true) -> Dictionary:
	_flush_pending_save()   # the export carries the edit being typed
	var r: Dictionary = VaultStore.export_to(_get_download_path())
	if not r.ok:
		_update_status("Export failed: " + str(r.error))
		return r
	if open_after:
		OS.shell_show_in_file_manager(r.dest)
	var status: String = "Exported %d files to %s" % [r.files, r.dest]
	var links: Array = r.get("links", [])
	if not links.is_empty():
		var what: String = "a folder that links" if links.size() == 1 else "%d folders that link" % links.size()
		status += "; left out %s elsewhere: %s" % [what, ", ".join(links)]
	_update_status(status)
	return r


## The user's Downloads folder, wherever the OS keeps it (a moved Windows
## Downloads, a non-English XDG one), else the app's data folder. Never
## built from HOME, which Windows doesn't set.
static func _get_download_path() -> String:
	if download_dir_override != "":
		return download_dir_override
	var dl: String = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	return dl if dl != "" else OS.get_user_data_dir()


## Graph View — backlinks between notes

# Graph data, keyed by each note's resource_path (the disk watcher re-sorts
# VaultStore.note_list, so an index would name another note after a refresh):
# path -> {note, title, connections: [paths], color}
var _graph_nodes: Dictionary = {}
var _graph_edges: Array[Dictionary] = []  # [{from: path, to: path}]
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
	"""One node per note (a lone note too), keyed by its file; one edge per
	[[link]] WikiLinks resolves (exact titles only, nothing inside code)."""
	var notes: Array[ContentLayer] = VaultStore.note_list
	var titles: Dictionary = WikiLinks.title_index()
	for i in range(notes.size()):
		var note: ContentLayer = notes[i]
		var key: String = note.resource_path
		_graph_nodes[key] = {
			"note": note,
			"title": note.title.strip_edges(),
			"connections": [],
			"color": _graph_color_palette[i % _graph_color_palette.size()],
		}
		for target in WikiLinks.outgoing(note, titles):
			_graph_nodes[key]["connections"].append(target.resource_path)
			_graph_edges.append({"from": key, "to": target.resource_path})


## Hand the built data and the open note to the graph (it keeps the places
## of the nodes it already shows).
func _show_graph_data() -> void:
	graph_layer.current_key = current_note.resource_path if current_note != null else ""
	graph_layer.set_graph_data(_graph_nodes, _graph_edges)


## The vault changed while the graph is open, on disk or by the app's own
## move or rename (which set _last_sig, so the disk watcher never sees them):
## draw it again. A note the app moved is the same object at a new path, so
## its node takes the new key first and keeps its place.
func _refresh_graph() -> void:
	var moved: Dictionary = {}   # old key -> new key
	for key in _graph_nodes:
		var path: String = (_graph_nodes[key].note as ContentLayer).resource_path
		if path != "" and path != key:   # "": a reload took its file over
			moved[key] = path
	_build_graph_data()
	graph_layer.rekey(moved)
	_show_graph_data()


func _on_graph_node_clicked(note_key: String) -> void:
	"""Open the note whose node was double-clicked: the note it was drawn for
	while the vault still holds it (the app may have moved its file since),
	else the note now in that file, wherever the disk watcher sorted it."""
	var drawn: Variant = (_graph_nodes.get(note_key, {}) as Dictionary).get("note")
	if drawn is ContentLayer and VaultStore.note_list.has(drawn):
		_open_note(drawn)
	else:
		open_note_at_path(note_key)



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
	get_window().title = APP_NAME
	# Vault switcher, first in the header row beside the palette / new-note buttons
	_vault_btn = Button.new()
	_vault_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vault_btn.name = "VaultButton"
	_vault_btn.theme_type_variation = &"FlatButton"
	_vault_btn.icon = Icons.get_icon("vault", 14)
	_vault_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_vault_btn.clip_text = true
	_vault_btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_vault_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_vault_btn.pressed.connect(_show_vault_menu)
	header.add_child(_vault_btn)
	header.move_child(_vault_btn, 0)
	_vault_menu = PopupMenu.new()
	_vault_menu.name = "VaultMenu"
	_vault_menu.id_pressed.connect(_on_vault_menu)
	add_child(_vault_menu)
	_vault_dialog = FileDialog.new()
	_vault_dialog.name = "VaultDialog"
	_vault_dialog.title = "Open a folder as a vault (use “Create Folder” for a new one)"
	_vault_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_vault_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_vault_dialog.dir_selected.connect(_pick_vault)
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
		nf.accessibility_name = "New folder"
		nf.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		nf.pressed.connect(func() -> void: _new_folder_prompt(""))
		notes_header.get_node("NotesTitle").add_sibling(nf)
		# Dropping on the header moves a note/folder to the top level
		(notes_header as Control).set_drag_forwarding(Callable(),
			func(_p: Vector2, data: Variant) -> bool: return _can_drop(data, ""),
			func(_p: Vector2, data: Variant) -> void: _drop(data, ""))
	var scroll: Control = note_list_container.get_parent()
	(scroll as ScrollContainer).follow_focus = true   # a row reached by the keyboard scrolls into view
	scroll.set_drag_forwarding(Callable(),
		func(_p: Vector2, data: Variant) -> bool: return _can_drop(data, ""),
		func(_p: Vector2, data: Variant) -> void: _drop(data, ""))
	scroll.gui_input.connect(_on_row_gui_input.bind({"type": "root"}))
	_unreadable_row = _make_unreadable_row()
	scroll.add_sibling(_unreadable_row)

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
	_prompt.dialog_hide_on_ok = false   # _on_prompt_confirmed hides it, unless the answer is refused
	_prompt_edit.keep_editing_on_text_submit = true   # …and then Enter must leave the text editable
	_prompt.confirmed.connect(_on_prompt_confirmed)
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
			_pick_vault(recent[id])


## A vault picked in the vault menu or the Open folder dialog. The one
## already open (its checked item, its folder picked again) is no switch:
## reopening it would drop what Ctrl+Z restores, the undo history and
## Back / Forward, as the palette, which never lists it, knows.
func _pick_vault(path: String) -> void:
	if VaultRegistry.normalize(path) == VaultStore.vault_path:
		_update_status(_with_unsaved("Already in " + _vault_name()))
		return
	switch_vault(path)


func _open_vault_dialog() -> void:
	_vault_dialog.current_dir = VaultStore.vault_path.get_base_dir().get_base_dir()
	_vault_dialog.popup_centered(Vector2i(760, 500))


## Open another folder as the vault. A note that still can't be saved holds
## the switch (its retries would write into the new vault, and its words
## would be lost), and so does a deleted note whose _trashed entry holds
## such words (the switch clears _trashed): the status bar says so
## (_words_at_risk), and choosing the same vault again, while the same
## words are at risk, switches anyway (_switch_anyway).
## A vault another window of the app has open asks first (Cancel, or Open
## anyway: _ask_vault_in_use).
func switch_vault(path: String) -> void:
	_flush_pending_save()
	var at_risk: String = _words_at_risk()
	if at_risk != "" and path + "\n" + at_risk != _switch_anyway:
		_switch_anyway = path + "\n" + at_risk
		_update_status("Didn't switch vaults. %s Switch again to leave it unsaved." % at_risk)
		return
	_switch_anyway = ""
	if not VaultLock.vault_lock_holder(path).is_empty():
		_ask_vault_in_use(VaultRegistry.normalize(path), "Cancel", _switch_vault_now.bind(path),
			func() -> void: _update_status("Stayed in " + _vault_name()))
		return
	_switch_vault_now(path)


## switch_vault once nothing holds it back: leave this vault (its lock too)
## and open the one at `path`, taking its lock.
func _switch_vault_now(path: String) -> void:
	_flush_pending_save()
	_unsaved.clear()
	_retry_timer.stop()
	_editing = false
	_trashed.clear()   # their paths are in the vault being left
	_pending_renames.clear()   # so are those notes
	UndoRedoEngine.clear()   # so are the notes its steps belong to
	VaultStore.open_vault(path)
	VaultLock.hold_vault_lock()   # lets go of the vault left
	current_note = null
	_nav.clear()   # the history is this vault's notes
	search_box.text = ""
	tag_sidebar_filter.text = ""
	_active_tag_filter = ""   # the old vault's tag filter would hide the new vault's notes
	_tag_filter_applied_from_search = false
	_load_collapsed()
	_refresh_note_list()
	_update_vault_button()
	_last_sig = VaultStore.disk_signature()
	var in_graph: bool = current_mode == "graph"
	_open_last_or_newest(_read_ui_json(), in_graph)   # where this vault was left; the view stays
	if in_graph:
		_build_graph_data()   # this vault's notes: the graph showed the last one's
		_show_graph_data()
	if current_mode == "journey":
		_switch_layer("journey")
	var unreadable: String = _learning_files_warning()
	var hidden: String = VaultStore.hidden_notes_warning()   # notes in images/ from before it held pictures
	_update_status_after_scan((unreadable if unreadable != "" else "Opened vault " + _vault_name())
		+ (("  ·  " + hidden) if hidden != "" else ""))


## Why this vault's journey or quiz progress file couldn't be read ("" if
## both could). Loads them now, so a broken one is kept aside and reported
## when the vault opens, not at the first score.
func _learning_files_warning() -> String:
	var e: String = JourneyStore.load_error()
	return e if e != "" else ProgressStore.load_error()


# ── Mirroring the disk ──────────────────────────────────────────────────────

func _exit_tree() -> void:
	if VaultStore.editor_note == current_note:
		VaultStore.editor_note = null   # no editor holds its text any more
	VaultLock.release_vault_lock()   # the window closes (a quit frees the tree too)


# ── One window per vault ────────────────────────────────────────────────────

## At startup: take the vault's lock, unless another window of the app holds
## it (VaultLock.vault_lock_holder; a lock a crash left is taken over
## without asking). Then ask: Quit, or Open anyway.
func _hold_vault_at_start() -> void:
	if VaultLock.vault_lock_holder(VaultStore.vault_path).is_empty():
		VaultLock.hold_vault_lock()
		return
	_ask_vault_in_use(VaultStore.vault_path, "Quit", func() -> void: VaultLock.hold_vault_lock(), _quit)


## Say that the vault at `vault` is open in another window, and why that
## matters. "Open anyway" runs `open_anyway`; the other button, `cancel_text`,
## and closing the dialog run `cancel`.
func _ask_vault_in_use(vault: String, cancel_text: String, open_anyway: Callable, cancel: Callable) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.name = "VaultInUseDialog"
	dlg.title = "Vault already open"
	dlg.dialog_text = "Ontomeme already has this vault open in another window.\n\n%s\n\nTwo windows saving the same notes turn each other's edits into conflict copies. Switch to that window, or open the vault here anyway." % vault
	dlg.dialog_autowrap = true
	dlg.min_size = Vector2i(460, 0)
	dlg.ok_button_text = "Open anyway"
	dlg.cancel_button_text = cancel_text
	dlg.confirmed.connect(open_anyway)
	dlg.canceled.connect(cancel)
	dlg.visibility_changed.connect(func() -> void:
		if not dlg.visible:
			if _in_use_dialog == dlg:
				_in_use_dialog = null
			dlg.queue_free())
	add_child(dlg)
	_in_use_dialog = dlg
	dlg.popup_centered()


## Quit without opening the vault: anything typed meanwhile is saved first,
## and no lock of another window is touched.
func _quit() -> void:
	_save_before_leaving()
	get_tree().quit()


func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_APPLICATION_FOCUS_OUT]:
		NoteScene3D.app_focused = what == NOTIFICATION_APPLICATION_FOCUS_IN   # 3D cards pause in the background
	match what:
		NOTIFICATION_APPLICATION_FOCUS_IN:
			if is_inside_tree() and _watch_timer != null:
				check_disk_changes()
		NOTIFICATION_WM_CLOSE_REQUEST:
			_save_before_leaving()
			_hold_close_if_at_risk()
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			_save_before_leaving()


## The window is closing (close button, Alt+F4, Cmd+Q) or the user switched to
## another app: write a pending title and body edit now instead of when the
## autosave timer fires, which a quit would never reach. Synchronous, so a
## close goes ahead after the save (or the conflict copy) is on disk, unless
## words are still at risk (_hold_close_if_at_risk).
func _save_before_leaving() -> void:
	if not is_node_ready():
		return
	if current_note != null and title_edit.text != _title_shown:   # a title the user typed
		_commit_title()
	_flush_pending_save()   # also retries notes whose save failed, open or not


## A close request, after _save_before_leaving: words that are still only in
## this process (_words_at_risk: a save that failed again just now, a deleted
## note's kept words) would go with it. Then the quit waits (auto_accept_quit
## off, so the engine doesn't close the window) and a question says what
## would be lost: Quit anyway, or Keep open to save or restore them first.
## With nothing at risk the close goes ahead as ever.
func _hold_close_if_at_risk() -> void:
	var at_risk: String = _words_at_risk()
	get_tree().set_auto_accept_quit(at_risk == "")
	if at_risk == "" or _quit_dialog != null:
		return
	var dlg := ConfirmationDialog.new()
	dlg.name = "QuitWithUnsavedDialog"
	dlg.title = "Words not saved"
	dlg.dialog_text = "%s\n\nIf you quit now, those words are lost." % at_risk
	dlg.dialog_autowrap = true
	dlg.min_size = Vector2i(460, 0)
	dlg.ok_button_text = "Quit anyway"
	dlg.cancel_button_text = "Keep open"
	dlg.confirmed.connect(func() -> void: get_tree().quit())
	dlg.canceled.connect(func() -> void: _update_status("Didn't quit. " + _words_at_risk()))
	dlg.visibility_changed.connect(func() -> void:
		if not dlg.visible:
			if _quit_dialog == dlg:
				_quit_dialog = null
			dlg.queue_free())
	add_child(dlg)
	_quit_dialog = dlg
	dlg.popup_centered()


## Put `note`'s title in the title field ("" for an untitled one), so an
## untouched field never reads as a rename.
func _show_title(note: ContentLayer) -> void:
	_title_shown = _title_field_text(note)
	title_edit.text = _title_shown


## Rescan when files or folders changed outside the app (file manager, git…).
func check_disk_changes() -> void:
	_check_store_changes()   # touches no editor, so not held back while typing
	# Not while an edit is pending or the open note couldn't be saved:
	# reopening would replace the unsaved words with the file's. Another
	# note's failed save doesn't hold it: VaultStore never reloads that one
	# (_unsaved_paths), and the open note should show an outside edit before
	# the user types into an old version of it.
	if _editing or current_note in _unsaved or (_auto_save_timer != null and not _auto_save_timer.is_stopped()) or (_prompt != null and _prompt.visible and not _prompt_answering):
		return
	var sig: String = VaultStore.disk_signature()
	if sig == _last_sig:
		return
	var outside: bool = VaultStore.changed_outside(_last_sig, sig)
	_last_sig = sig
	if not outside:
		# Only the app's own saves: note_list and their rows already show them
		# (an autosave updates its row, other saves rebuild the list)
		if current_mode == "journey":
			journey_panel.refresh()   # an undo there changed a note's text
		return
	var cur_path: String = current_note.resource_path if current_note != null else ""
	var cur_title: String = current_note.title if current_note != null else ""
	var listed: Dictionary = {}   # the files listed before the rescan
	for note in VaultStore.note_list:
		listed[note.resource_path] = true
	VaultStore.refresh_note_list(true)   # also the open note: no edit is pending, and it is reopened below
	_refresh_note_list()
	var found: ContentLayer = null
	for note in VaultStore.note_list:
		if note.resource_path == cur_path:
			found = note
			break
	if found == null and cur_title != "":
		var idx: int = VaultStore.get_note_index(cur_title)
		found = VaultStore.note_list[idx] if idx >= 0 else null
	if found == null and cur_path != "" and not FileAccess.file_exists(cur_path):
		found = _renamed_outside(current_note, listed)
	if found != null and cur_path != "" and found.resource_path != cur_path:
		_nav.remap(cur_path, found.resource_path)   # Back / Forward follow the note to its new file
	var in_graph: bool = current_mode == "graph"
	if found != null:
		if found != current_note or found.raw_text != raw_text_layer.text:
			var typed: String = title_edit.text   # a title typed but not committed (the field still has the keyboard)
			var typing: bool = typed != _title_shown
			var caret: int = title_edit.caret_column
			current_note = null
			_open_note(found, in_graph)
			if typing:   # it still waits for Enter or focus-out, now over the outside version
				title_edit.text = typed
				title_edit.caret_column = caret
			if current_mode in ["structured", "visual"]:
				_switch_layer(current_mode)
		else:
			breadcrumb.text = _crumb(found)
			if title_edit.text == _title_shown:   # renamed outside the app (Claude, a sync tool), nothing typed here
				_show_title(found)
	elif cur_path != "":
		if VaultStore.note_list.size() > 0:
			current_note = null
			_open_note(VaultStore.note_list[0], in_graph)
		else:
			_show_empty_state()
	if in_graph:
		_refresh_graph()
	if current_mode == "journey":
		journey_panel.refresh()
	# An outside star or pin on the open note keeps the same object and body,
	# so the note is not reopened above; bring the top bar in step here.
	_update_star_pin_buttons()
	_update_status_after_scan("Vault changed on disk — refreshed")


## The note an outside rename took `note`'s file to (the MCP server's
## update_note renames a note's file with its title), so the editor follows
## it: the one note in a file `listed` (the files before the rescan) lacked
## that was created when `note` was. null when none, or several, match.
func _renamed_outside(note: ContentLayer, listed: Dictionary) -> ContentLayer:
	if note == null or note.created == "":
		return null
	var hit: ContentLayer = null
	for n in VaultStore.note_list:
		if not listed.has(n.resource_path) and n.created == note.created:
			if hit != null:
				return null
			hit = n
	return hit


## After the app's own change to the vault (a new note or folder, a move, a
## rename, a delete, a restore): the watcher takes the disk as it is now, so
## that change is not reported as one from outside. Not while `held`, the
## note the editor held through that change's rescan (VaultStore.editor_note),
## has a change from another program the rescan left pending
## (VaultStore.change_pending): only the watcher's pass shows it
## (refresh_note_list(true)), and taking the disk as seen would hide it until
## a keystroke turned the stale text into a conflict copy.
func _take_own_change(held: ContentLayer) -> void:
	if not VaultStore.change_pending(held):
		_last_sig = VaultStore.disk_signature()


## progress.json or journey.json rewritten by another process (the MCP
## server's update_note moves their keys when it renames a note): read them
## again and show it, so the sidebar's ✓ / ● marks and the Journey tab match
## the files. (Their writes re-read a changed file first, too.) The Journey
## tab is rebuilt when it shows, since its editors hold the old entries, and
## Read view's "Feeds objective" chips take the new objectives' status.
func _check_store_changes() -> void:
	if ProgressStore.reload_if_changed():
		on_progress_changed()
	if JourneyStore.reload_if_changed():
		if current_mode == "journey" and journey_panel != null:
			journey_panel.refresh()
		LayerEngine.refresh_objective_chips()


func _after_vault_op(status: String) -> void:
	_take_own_change(current_note)
	_save_session()   # a move or a folder rename may have moved the open note's file
	_refresh_note_list()
	if current_note != null and current_mode != "journey":
		breadcrumb.text = _crumb(current_note)
	_rerender_read_view()   # a move changed the open note's folder, or a backlink's
	if current_mode == "graph":
		_refresh_graph()   # a move gave its notes new paths, the graph's keys
	_update_status(status)


## Render Read view again while it is showing, after something other than
## an open or a view switch changed what it is built from: the open note's
## title or folder (its objective chips' activity and topic) or a backlink's.
## Its key (LayerEngine._visual_key_of) leaves it as it is when nothing did.
func _rerender_read_view() -> void:
	if current_note != null and current_mode == "visual" and is_inside_tree():
		LayerEngine.set_mode(current_mode)


## Version (from project.godot), where the notes and the log live, a Copy
## diagnostics button for bug reports, and a Licences button for the notices
## that ship with the app.
func _show_about() -> void:
	var dlg := AcceptDialog.new()
	dlg.name = "AboutDialog"
	dlg.title = "About " + APP_NAME
	dlg.dialog_text = "%s %s\n\nYour notes are in:\n%s\n\nThe log is at:\n%s" % [APP_NAME, app_version(), VaultStore.vault_path, log_path()]
	dlg.get_label().autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # long paths wrap, not widen the box
	dlg.min_size = Vector2i(ABOUT_WIDTH, 0)
	var copy_btn: Button = dlg.add_button("Copy diagnostics")
	copy_btn.name = "CopyDiagnosticsButton"
	copy_btn.pressed.connect(_copy_diagnostics.bind(copy_btn))
	var licences_btn: Button = dlg.add_button("Licences")
	licences_btn.name = "LicencesButton"
	licences_btn.pressed.connect(_show_licences.bind(dlg))
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


func _copy_diagnostics(btn: Button) -> void:
	DisplayServer.clipboard_set(diagnostics())
	btn.text = "Copied"
	_update_status("Copied diagnostics  ·  paste them into your bug report")


## Ontomeme's MIT licence, the fonts' OFL and the Godot Engine notices in a
## read-only text box. A child of the About box, so it stacks above it.
func _show_licences(parent: Window) -> AcceptDialog:
	var dlg := AcceptDialog.new()
	dlg.name = "LicencesDialog"
	dlg.title = "Licences"
	dlg.ok_button_text = "Close"
	var text := TextEdit.new()
	text.name = "LicencesText"
	text.text = Licences.licences_text()
	text.editable = false
	text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	text.custom_minimum_size = Vector2(720, 380)   # fits the 820×520 minimum window
	dlg.add_child(text)
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	parent.add_child(dlg)
	dlg.popup_centered()
	return dlg


static func app_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "dev"))


## One line for bug reports: version, OS, the vault and what came up in it,
## where the app data and the log live, scale and renderer. Printed once at
## startup ("[Ontomeme] …", so godot.log has it) and copied by About → Copy
## diagnostics.
static func diagnostics() -> String:
	var vault: String = VaultStore.vault_path
	var os_name: String = "%s %s" % [OS.get_name(), OS.get_version()]
	if OS.get_version_alias() != OS.get_version():
		os_name += " (%s)" % OS.get_version_alias()
	var fields: PackedStringArray = [
		"%s %s" % [APP_NAME, app_version()],
		"os=" + os_name,
		"locale=" + OS.get_locale(),
		"vault=" + vault,
		"vault_exists=%s" % (vault != "" and DirAccess.dir_exists_absolute(vault)),
		"notes=%d" % VaultStore.note_list.size(),
		"folders=%d" % VaultStore.folders.size(),
		"first_run=%s" % VaultStore.first_run,
		"warning=" + (VaultStore.startup_warning if VaultStore.startup_warning != "" else "none"),
		"user_data=" + OS.get_user_data_dir(),
		"log=" + log_path(),
		"screen_scale=%s zoom=%s" % [UiScale.screen_scale(), UiScale.load_zoom()],
		"renderer=%s %s" % [RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_current_rendering_method()],
	]
	return " | ".join(fields).replace("\n", " ")


## This run's log file (Godot writes it on desktop: user://logs/godot.log).
static func log_path() -> String:
	return ProjectSettings.globalize_path(str(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log")))


static func log_dir() -> String:
	return log_path().get_base_dir()


## Reveal the log folder in the file manager, so a user can attach godot.log
## to a bug report.
func _open_log_folder() -> void:
	var dir: String = log_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	if OS.shell_open(dir) == OK:
		_update_status("Opened the log folder  ·  attach ontomeme.log and godot.log to your report")
	else:
		_update_status("Can't open the log folder: " + dir)


## The vault's sidebar state lives in <vault>/.ontomeme/ui.json: the folded
## folders ("collapsed"), the folded sections ("sections_collapsed", a key
## of its own so a folder named "Pinned" cannot collide), the folded TAGS
## section ("tags_collapsed"), the session (last_note, last_mode) and other
## features' keys. Each writer sets only its own keys through _save_ui.
func _load_collapsed() -> void:
	_collapsed.clear()
	_sections_collapsed.clear()
	var ui: Dictionary = _read_ui_json()
	if ui.get("collapsed") is Array:
		for rel in ui.collapsed:
			_collapsed[str(rel)] = true
	if ui.get("sections_collapsed") is Array:
		for section in ui.sections_collapsed:
			if SECTIONS.has(str(section)):
				_sections_collapsed[str(section)] = true
	_tags_collapsed = ui.get("tags_collapsed", false) == true


## Write the collapsed folders and sections into ui.json, keeping every
## other key in it (other features keep their own state there).
func _save_collapsed() -> void:
	_save_ui({"collapsed": _collapsed.keys(), "sections_collapsed": _sections_collapsed.keys()})


func _ui_json_path() -> String:
	return VaultStore.data_dir().path_join("ui.json")


## ui.json as a Dictionary ({} when it is missing or not a JSON object).
func _read_ui_json() -> Dictionary:
	var p: String = _ui_json_path()
	if not FileAccess.file_exists(p):
		return {}
	var json := JSON.new()   # quiet on a broken file: it is rewritten on the next save
	if json.parse(FileAccess.get_file_as_string(p)) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


## Write `keys` into ui.json, keeping every other key in it.
func _save_ui(keys: Dictionary) -> void:
	var ui: Dictionary = _read_ui_json()
	ui.merge(keys, true)
	DirAccess.make_dir_recursive_absolute(VaultStore.data_dir())
	var f := FileAccess.open(_ui_json_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(ui, "\t"))


# ── Folder operations ───────────────────────────────────────────────────────

func _ask(title: String, initial: String, ok_text: String, cb: Callable) -> void:
	_prompt.title = title
	_prompt.ok_button_text = ok_text
	_prompt_edit.text = initial
	_prompt_cb = cb
	_prompt.popup_centered()
	_prompt_edit.grab_focus()
	_prompt_edit.select_all()


## OK or Enter in the prompt. A callback that returns false refused the text
## (a rename to a taken title; the status line says why): the prompt stays
## open with the text selected, to fix. Anything else closes it.
## While the answer is acted on the prompt counts as closed, as it did when OK
## hid it first (_prompt_answering): check_disk_changes waits for an open
## prompt, and a tag rename runs it to read outside edits in before it saves.
func _on_prompt_confirmed() -> void:
	_prompt_answering = true
	var answer: Variant = _prompt_cb.call(_prompt_edit.text) if _prompt_cb.is_valid() else null
	_prompt_answering = false
	if answer is bool and not answer:
		_prompt_edit.grab_focus()
		_prompt_edit.select_all()
	else:
		_prompt.hide()


## The Rename prompt for `note` (F2, a double-click on its row, its menu's
## "Rename…"). The note is opened first, so the rename is the open note's,
## like the title field's. Enter renames; Escape leaves the title as it is.
func _rename_note_prompt(note: ContentLayer) -> void:
	if note == null:
		return
	if note != current_note:
		_open_note(note)
	_ask("Rename note", _title_field_text(note), "Rename", func(title: String) -> bool:
		if note != current_note:
			return true   # another note was opened meanwhile: nothing to rename
		if not _rename_current(title):
			return false
		if get_viewport().gui_get_focus_owner() == null and _note_buttons.has(current_note):
			_note_buttons[current_note].grab_focus()   # its row was rebuilt; keep the keyboard in the sidebar
		return true)


func _new_folder_prompt(parent: String) -> void:
	_ask("New folder" + (" in " + parent if parent != "" else ""), "New folder", "Create", func(name: String) -> void:
		create_folder(name, parent))


func create_folder(name: String, parent: String = "") -> String:
	var rel: String = VaultStore.create_folder(name, parent)
	if rel == "":
		_update_status(_refused("Couldn't create the folder", "pick another name"))
		return ""
	_collapsed.erase(parent)
	_after_vault_op("Created folder " + rel)
	return rel


func rename_folder(rel: String, new_name: String) -> String:
	var nr: String = VaultStore.rename_folder(rel, new_name)
	if nr == "":
		_update_status(_refused("Couldn't rename", "pick another name") if VaultStore.last_refusal != "" else "Couldn't rename — is that name taken?")
		return ""
	_nav.remap(VaultStore.vault_path + rel, VaultStore.vault_path + nr)
	_move_folds(rel, nr)
	_after_vault_op("Renamed folder to " + nr)
	return nr


## The folder `old_rel` moved to `new_rel` (a rename, a move; "" when it
## went to the trash): the folds of it and of every folder inside it, keyed
## by path in _collapsed and ui.json, go with it, so a folded subfolder stays
## folded and no new folder that takes an old path comes up folded.
func _move_folds(old_rel: String, new_rel: String) -> void:
	var moved: Dictionary = {}
	for rel in _collapsed.keys():
		if rel == old_rel or str(rel).begins_with(old_rel + "/"):
			_collapsed.erase(rel)
			if new_rel != "":
				moved[new_rel + str(rel).substr(old_rel.length())] = true
	_collapsed.merge(moved, true)
	_save_collapsed()


## Move the folder `rel` and everything in it to the trash (the folder
## menu's "Move to trash…", once confirmed). A pending edit is saved first,
## so the trashed files hold the last words; if that save meets an outside
## edit in the folder, the conflict copy opens instead and nothing is moved.
## A note in it whose save failed goes without the words its file lacks:
## they go on _trashed like a deleted note's (_keep_folder_note_words), the
## status says so, and Ctrl+Z writes the note again with them. A folder that
## can't be moved (read-only, locked by another program) stays, and so does
## everything the app holds for its notes: the open note and its pending
## edit, and the words of a note whose save failed, still retried (_unsaved).
func delete_folder(rel: String) -> void:
	var prefix: String = VaultStore.vault_path + rel + "/"
	var had_current: bool = current_note != null and current_note.resource_path.begins_with(prefix)
	if _flush_pending_save() and had_current:
		return   # the open note's words went to a conflict copy, now open: the user decides again
	if not VaultStore.delete_folder(rel):
		_update_status(_with_unsaved("Couldn't move the folder “%s” to the trash: it may be read-only or in use" % rel))
		return
	var kept: PackedStringArray = []
	for note in _unsaved.duplicate():
		if note.resource_path.begins_with(prefix):
			kept.append("“%s”" % _keep_folder_note_words(note))
	_forget_unsaved(prefix)
	_move_folds(rel, "")
	if had_current:
		current_note = null
		if VaultStore.note_list.size() > 0:
			_open_note(VaultStore.note_list[0])
		else:
			_show_empty_state()
	var status: String = "Moved folder “%s” to the trash  ·  Trash in the sidebar restores it" % rel
	if kept.size() == 1:
		status += " without the words %s couldn't save  ·  Ctrl+Z restores it with them" % kept[0]
	elif kept.size() > 1:
		status += " without the words %s couldn't save  ·  Ctrl+Z restores them with those words" % ", ".join(kept)
	if not kept.is_empty():
		_let_go_of_keyboard()   # the menu's confirm leaves the editor the keyboard: the offered Ctrl+Z must reach the app
	_after_vault_op(_with_unsaved(status))


## `note`, in a folder delete_folder just moved to the trash, couldn't be
## saved: the trashed file lacks its words. Like _trash_note, a _trashed
## entry keeps them (`unsaved`) and leaves _unsaved. Its `trash_rel` is a
## free trash path (VaultStore.trash_slot) that the note object takes over,
## so a restore writes the note again from those words in that same object
## (VaultStore.recreate_note: its undo history follows it); `folder` makes
## the restore say where the rest went. Returns the note's title.
func _keep_folder_note_words(note: ContentLayer) -> String:
	var title: String = _display_title(note)
	var original_rel: String = note.resource_path.substr(VaultStore.vault_path.length())
	var trash_rel: String = VaultStore.trash_slot(original_rel)
	_trashed.append({"trash_rel": trash_rel, "original_rel": original_rel, "title": title,
		"at": UndoRedoEngine.tick(), "unsaved": _note_fields(note), "folder": true})
	note.take_over_path(VaultStore.vault_path + trash_rel)
	_unsaved.erase(note)
	if _unsaved.is_empty():
		_retry_timer.stop()
	return title


func move_note_to(note: ContentLayer, folder: String) -> bool:
	_flush_pending_save()
	var old_path: String = note.resource_path
	if not VaultStore.move_note(note, folder):
		if VaultStore.last_refusal != "":
			_update_status(_refused("Couldn't move the note", ""))
		return false
	_nav.remap(old_path, note.resource_path)
	_collapsed.erase(folder)
	_after_vault_op("Moved “%s” to %s" % [_display_title(note), folder if folder != "" else "the top level"])
	return true


func move_folder_to(rel: String, dest: String) -> String:
	_flush_pending_save()
	var nr: String = VaultStore.move_folder(rel, dest.path_join(rel.get_file()) if dest != "" else rel.get_file())
	if nr != "":
		_nav.remap(VaultStore.vault_path + rel, VaultStore.vault_path + nr)
		_move_folds(rel, nr)
		_after_vault_op("Moved folder to " + (dest if dest != "" else "the top level"))
	elif VaultStore.last_refusal != "":
		_update_status(_refused("Couldn't move the folder", "rename it first"))
	return nr


## "<what>: <why VaultStore refused>; <hint>", or just `what` when it gave no
## reason (a target in images/ or models/ is the one it explains).
func _refused(what: String, hint: String) -> String:
	if VaultStore.last_refusal == "":
		return what
	return "%s: %s%s" % [what, VaultStore.last_refusal, ("; " + hint) if hint != "" else ""]


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
	elif _is_double_click(event) and target.type == "note" and target.note == current_note:
		# The first click opened the note; the second renames it. That click
		# may have re-sorted the rows (it saved the note being edited, which
		# jumps to the top; or a watcher poll rebuilt them), putting another
		# note's row under the second press: that press stays a plain click.
		_rename_note_prompt(target.note)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and target.type in ["note", "folder"] and _on_row_key(event, target):
		# Only note and folder rows take the keys; TAGS and unreadable rows keep a Button's own
		get_viewport().set_input_as_handled()


static func _is_double_click(event: InputEvent) -> bool:
	var mb := event as InputEventMouseButton
	return mb != null and mb.pressed and mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT


## The row's menu at the mouse, or under `row` when a key opened it (the
## first entry is then highlighted, so arrows and Enter work at once).
func _show_ctx(target: Dictionary, row: Control = null) -> void:
	_ctx_target = target
	_ctx_menu.clear()
	match str(target.type):
		"folder":
			_ctx_menu.add_item("New note here", 0)
			_ctx_menu.add_item("New folder inside…", 1)
			_ctx_menu.add_item("Rename…", 2)
			_ctx_menu.add_item("Show in file manager", 3)
			_ctx_menu.add_item("Export folder as Markdown", 5)
			_ctx_menu.add_separator()
			_ctx_menu.add_item("Move to trash…", 4)
		"note":
			_ctx_menu.add_item("Open", 10)
			_ctx_menu.add_item("Unstar" if target.note.starred_at != "" else "Star", 14)
			_ctx_menu.add_item("Unpin" if target.note.pinned_at != "" else "Pin to top", 15)
			_build_move_menu(VaultStore.folder_of(target.note))
			_ctx_menu.add_submenu_node_item("Move to", _move_menu, 11)
			_ctx_menu.add_item("Rename…", 16)
			_ctx_menu.add_item("Show in file manager", 12)
			_ctx_menu.add_item("Export as Markdown", 17)
			_ctx_menu.add_separator()
			_ctx_menu.add_item("Delete note", 13)
		"unreadable":
			_ctx_menu.add_item("Show in file manager", 40)
			_ctx_menu.add_item("Move to .corrupted", 41)
			_ctx_menu.set_item_tooltip(_ctx_menu.get_item_index(41), "Move the unreadable files into the vault's hidden .corrupted folder; nothing is deleted")
		"tag":
			_ctx_menu.add_item("Rename or merge tag…", 30)
			_ctx_menu.add_item("Remove from all notes…", 31)
		_:
			_ctx_menu.add_item("New note", 20)
			_ctx_menu.add_item("New folder…", 21)
			_ctx_menu.add_item("Show vault in file manager", 22)
			_ctx_menu.add_item("Export all as Markdown", 23)
	var at: Vector2 = get_global_mouse_position()
	if row != null:
		at = row.get_global_rect().position + Vector2(16, row.size.y)
	_ctx_menu.popup(Rect2i(Vector2i(get_window().position) + Vector2i(at), Vector2i.ZERO))
	if row != null:
		_ctx_menu.set_focused_item(0)


## The note menu's Star / Pin. The open note goes through the top bar's
## toggle; any other note is flagged where it is, and the open note stays
## open. Either way pending typing and a typed title are saved first (an
## outside edit of the open note then gets a conflict copy, as on any save),
## and the open note is shown as it is now: flagging another note saves it,
## and that save's rescan reads an outside edit of the open note into it in
## place, at its new hash, so the editor's stale text would be autosaved
## over that edit.
func _toggle_flag_from_menu(note: ContentLayer, field: StringName) -> void:
	if note == current_note:
		_toggle_open_note_flag(field)
		return
	_save_pending_edits()
	var status: String = _toggle_note_flag(note, field)
	_show_reloaded_current_note()
	_update_star_pin_buttons()
	_update_status(status)


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
			if note == null:
				_report_create_failed("a new note in " + t.rel)
				return
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
		5: _export_folder_md(t.rel)
		10: _open_note(t.note)
		14: _toggle_flag_from_menu(t.note, &"starred_at")
		15: _toggle_flag_from_menu(t.note, &"pinned_at")
		12: OS.shell_open(t.note.resource_path.get_base_dir())
		16: _rename_note_prompt(t.note)
		13:
			_open_note(t.note)
			_on_delete_note_pressed()
		17: _export_note_md(t.note)
		20: _on_new_note_pressed()
		21: _new_folder_prompt("")
		22: OS.shell_open(VaultStore.vault_path)
		23: _export_all_md()
		30: _rename_tag_prompt(t.tag)
		31: _confirm_remove_tag(t.tag)
		40: OS.shell_open(_unreadable_folder())
		41: _quarantine_unreadable()


# ── Unreadable files ────────────────────────────────────────────────────────

## The warning row at the bottom of the sidebar, under the note list, for the
## .tres files the vault scan could not read as notes (VaultStore.unreadable).
## Hidden while there are none. A click or right-click opens its menu: show
## the files in the file manager, or move them to .corrupted.
func _make_unreadable_row() -> Button:
	var btn := Button.new()
	btn.name = "UnreadableRow"
	btn.theme_type_variation = &"NoteItem"
	btn.icon = Icons.get_icon("warning")
	btn.text = "Unreadable files"   # the count once there are any (_update_unreadable_row)
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.clip_text = true
	btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_size_override("font_size", 13)
	btn.visible = false
	btn.pressed.connect(func() -> void: _show_ctx({"type": "unreadable"}))
	btn.gui_input.connect(_on_row_gui_input.bind({"type": "unreadable"}))
	return btn


## Show the row with the count and names of the unreadable files, or hide it.
func _update_unreadable_row() -> void:
	var files: Array[String] = VaultStore.unreadable
	_unreadable_row.visible = not files.is_empty()
	if files.is_empty():
		return
	_unreadable_row.text = "%d unreadable file%s" % [files.size(), "" if files.size() == 1 else "s"]
	var names: PackedStringArray = PackedStringArray(files.slice(0, 8))
	if files.size() > 8:
		names.append("and %d more" % (files.size() - 8))
	_unreadable_row.tooltip_text = "These files end in .tres but can't be read as notes:\n%s\n\nClick to show them in the file manager, or to move them to the vault's hidden .corrupted folder (nothing is deleted)." % "\n".join(names)
	_unreadable_row.add_theme_color_override("font_color", _palette_colors.get("text_muted", Color.GRAY))
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		_unreadable_row.add_theme_color_override(state, _palette_colors.get("danger", Color.RED))


## The folder holding every unreadable file, or the vault when they are spread
## over several folders.
func _unreadable_folder() -> String:
	var folders: Dictionary = {}
	for rel in VaultStore.unreadable:
		folders[rel.get_base_dir()] = true
	return VaultStore.vault_path + (str(folders.keys()[0]) if folders.size() == 1 else "")


## Move every unreadable file to <vault>/.corrupted (VaultStore.quarantine).
## A file that changed since the scan read it (a sync tool finished it) is
## left in place and read again, so a finished note is never moved away.
func _quarantine_unreadable() -> void:
	var moved: int = 0
	var left: int = 0
	for rel in VaultStore.unreadable.duplicate():
		if VaultStore.quarantine(rel):
			moved += 1
		else:
			left += 1
	var status: String = "Moved %d unreadable file%s to .corrupted" % [moved, "" if moved == 1 else "s"]
	if left > 0:
		status += "  ·  left %d in place: changed on disk since the scan, or could not be moved" % left
	_after_vault_op(status)


# ── Accessibility ───────────────────────────────────────────────────────────

## Screen readers read a button's text. A button that shows at most one
## character ("+", "×", or only an icon) says nothing, so it takes its
## tooltip's first line as its accessibility_name (and the rest as the
## description). Explicit names set by the builders win.
static func _name_from_tooltip(btn: BaseButton) -> void:
	var text: Variant = btn.get("text")
	if btn.accessibility_name != "" or (text is String and (text as String).strip_edges().length() > 1):
		return
	var tip: PackedStringArray = btn.tooltip_text.strip_edges().split("\n", false, 1)
	if tip.is_empty():
		return
	btn.accessibility_name = tip[0].strip_edges()
	if tip.size() > 1 and btn.accessibility_description == "":
		btn.accessibility_description = tip[1].strip_edges()


## Name every button already under `node` (FileDialog internals are the
## engine's own and are left alone).
func _name_buttons_for_a11y(node: Node) -> void:
	if node is FileDialog:
		return
	if node is BaseButton:
		_name_from_tooltip(node)
	for c in node.get_children(true):
		_name_buttons_for_a11y(c)


## Buttons added later anywhere in the window (sidebar rows, chips, panels,
## including rows other code adds) are named the same way. Deferred, so a
## builder may set the tooltip after add_child.
func _on_node_added_for_a11y(node: Node) -> void:
	if node is BaseButton and is_ancestor_of(node):
		_name_added_button.call_deferred(node)


func _name_added_button(node: Variant) -> void:
	if not is_instance_valid(node) or not is_ancestor_of(node):
		return
	var p: Node = (node as Node).get_parent()
	while p != null and p != self:
		if p is FileDialog:
			return
		p = p.get_parent()
	_name_from_tooltip(node)


# ── Learning Journey ────────────────────────────────────────────────────────

func _build_journey() -> void:
	journey_panel = JourneyPanel.new(self)
	journey_panel.visible = false
	content_panel.add_child(journey_panel)


## A quiz / flashcard deck finished (called by NoteScene3D). `objective` is
## the name its block's objective: line gave ("" if none).
func on_activity_score(key: String, score: int, total: int, logged: int, objective: String = "") -> void:
	var status: String
	if logged > 0:
		status = "Logged %d / %d to %d learning objective%s  ·  see Journey (Ctrl+5)" % [score, total, logged, "" if logged == 1 else "s"]
	else:
		status = "Scored %d / %d" % [score, total]
	if objective.strip_edges() != "" and JourneyStore.find_objective_by_name(objective).is_empty():
		status += "  ·  “%s” isn't in your Journey yet: press Create under the %s to add it" % [objective.strip_edges(), "deck" if JourneyStore.parse_key(key).get("kind", "") == "cards" else "quiz"]
	elif logged == 0:
		status += "  ·  add it as a demonstration in Journey (Ctrl+5) to track it"
	_update_status(status)
	LayerEngine.refresh_objective_chips()   # their status icons


## Read view's "Feeds objective" chip: open that objective in the Journey.
func show_objective(id: String) -> void:
	_switch_layer("journey")
	journey_panel.select_objective(id)


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
	LayerEngine.finish_visual()   # a long note may still be building
	var want_preset: String = "quiz" if k.kind == "quiz" else "flashcards"
	var index_key: String = "_quiz_index" if k.kind == "quiz" else "_cards_index"
	for c in visual_layer.get_children():
		if c is NoteScene3D and c.preset == want_preset and int(c.params.get(index_key, -1)) == int(k.index):
			await _scroll_read_to(c)
			if not is_instance_valid(c):
				return null
			c.restart()
			_update_status("Go!  Your score will be logged to the objectives that use this.")
			return c
	_update_status("That activity isn't in “%s” any more" % k.note)
	return null
