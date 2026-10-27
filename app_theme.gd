class_name AppTheme
extends RefCounted
## AppTheme — builds the whole app's look as one Godot Theme resource.
##
## Every Control in the scene inherits from the root's `theme`, so nodes
## carry no colour/stylebox overrides of their own: they only name a
## `theme_type_variation` (SidebarPanel, NoteItem, SegmentButton, ...)
## and this file decides what that looks like. Dark and light mode are just
## two palettes fed through the same builder.

const FONT_SANS: FontFile = preload("res://fonts/AdwaitaSans-Regular.ttf")
const FONT_MONO: FontFile = preload("res://fonts/AdwaitaMono-Regular.ttf")


static func palette(dark: bool) -> Dictionary:
	if dark:
		return {
			"bg": Color("1e1e21"),         # editor canvas
			"sidebar": Color("18181b"),    # sidebar / status bar
			"surface": Color("1e1e21"),    # toolbar
			"elevated": Color("2a2a2e"),   # inputs, popups, cards
			"border": Color(1, 1, 1, 0.07),
			"border_strong": Color(1, 1, 1, 0.12),
			"hover": Color(1, 1, 1, 0.05),
			"active": Color(1, 1, 1, 0.09),
			"text": Color("dcdcde"),
			"text_muted": Color("9a9aa2"),
			"text_faint": Color("62626a"),
			"accent": Color("d97757"),     # warm clay
			"accent_text": Color("1a1a1a"),
			"danger": Color("e5534b"),
			"dim": Color(0, 0, 0, 0.5),
			"shadow": Color(0, 0, 0, 0.45),
			"h2": Color("e8b48a"),
			"h3": Color("c9c9ce"),
		}
	return {
		"bg": Color("ffffff"),
		"sidebar": Color("f5f5f4"),
		"surface": Color("ffffff"),
		"elevated": Color("ffffff"),
		"border": Color(0, 0, 0, 0.08),
		"border_strong": Color(0, 0, 0, 0.14),
		"hover": Color(0, 0, 0, 0.045),
		"active": Color(0, 0, 0, 0.08),
		"text": Color("1f1f23"),
		"text_muted": Color("6b6b73"),
		"text_faint": Color("a3a3aa"),
		"accent": Color("c2603e"),
		"accent_text": Color("ffffff"),
		"danger": Color("cf3b33"),
		"dim": Color(0, 0, 0, 0.25),
		"shadow": Color(0, 0, 0, 0.18),
		"h2": Color("a5532f"),
		"h3": Color("3a3a40"),
	}


# ── StyleBox helpers ────────────────────────────────────────────────────────

static func _box(bg: Color, radius: int = 0, mx: int = 0, my: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	for i in range(4):
		sb.set_corner_radius(i, radius)
	sb.content_margin_left = mx
	sb.content_margin_right = mx
	sb.content_margin_top = my
	sb.content_margin_bottom = my
	sb.anti_aliasing = true
	return sb


static func _border(sb: StyleBoxFlat, color: Color, l: int, t: int, r: int, b: int) -> StyleBoxFlat:
	sb.border_color = color
	sb.border_width_left = l
	sb.border_width_top = t
	sb.border_width_right = r
	sb.border_width_bottom = b
	return sb


static func _empty(mx: int = 0, my: int = 0) -> StyleBoxEmpty:
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = mx
	sb.content_margin_right = mx
	sb.content_margin_top = my
	sb.content_margin_bottom = my
	return sb


static func _weight(w: float) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = FONT_SANS
	fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): w}
	return fv


static func _variation(t: Theme, name: String, base: String) -> void:
	t.set_type_variation(name, base)


static func _button_styles(t: Theme, type: String, normal: StyleBox, hover: StyleBox, pressed: StyleBox, disabled: StyleBox = null) -> void:
	t.set_stylebox("normal", type, normal)
	t.set_stylebox("hover", type, hover)
	t.set_stylebox("pressed", type, pressed)
	t.set_stylebox("hover_pressed", type, pressed)
	t.set_stylebox("disabled", type, disabled if disabled != null else normal)
	t.set_stylebox("focus", type, StyleBoxEmpty.new())


static func _button_colors(t: Theme, type: String, normal: Color, hover: Color, pressed: Color, disabled: Color) -> void:
	t.set_color("font_color", type, normal)
	t.set_color("font_hover_color", type, hover)
	t.set_color("font_pressed_color", type, pressed)
	t.set_color("font_hover_pressed_color", type, pressed)
	t.set_color("font_focus_color", type, normal)
	t.set_color("font_disabled_color", type, disabled)
	t.set_color("icon_normal_color", type, normal)
	t.set_color("icon_hover_color", type, hover)
	t.set_color("icon_pressed_color", type, pressed)


# ── Theme builder ───────────────────────────────────────────────────────────

static func build(dark: bool) -> Theme:
	var p: Dictionary = palette(dark)
	var t := Theme.new()
	var medium: FontVariation = _weight(500)
	var semibold: FontVariation = _weight(600)
	var bold: FontVariation = _weight(700)

	t.default_font = FONT_SANS
	t.default_font_size = 14

	# Panes — flat, square, hairline borders only (pro-app look)
	t.set_stylebox("panel", "Panel", _box(p.bg))
	t.set_stylebox("panel", "PanelContainer", _box(p.bg))

	_variation(t, "SidebarPanel", "PanelContainer")
	t.set_stylebox("panel", "SidebarPanel", _border(_box(p.sidebar, 0, 10, 12), p.border, 0, 0, 1, 0))

	_variation(t, "ToolbarPanel", "PanelContainer")
	t.set_stylebox("panel", "ToolbarPanel", _border(_box(p.surface, 0, 14, 7), p.border, 0, 0, 0, 1))

	_variation(t, "StatusPanel", "PanelContainer")
	t.set_stylebox("panel", "StatusPanel", _border(_box(p.sidebar, 0, 12, 4), p.border, 0, 1, 0, 0))

	_variation(t, "EditorPanel", "PanelContainer")
	t.set_stylebox("panel", "EditorPanel", _box(p.bg))

	_variation(t, "SegmentPanel", "PanelContainer")
	t.set_stylebox("panel", "SegmentPanel", _border(_box(p.sidebar, 7, 3, 3), p.border, 1, 1, 1, 1))

	_variation(t, "CardPanel", "PanelContainer")
	t.set_stylebox("panel", "CardPanel", _border(_box(p.elevated, 10, 16, 14), p.border, 1, 1, 1, 1))

	_variation(t, "ReviewBanner", "PanelContainer")
	t.set_stylebox("panel", "ReviewBanner", _border(_box(Color(0.94, 0.63, 0.25, 0.10 if dark else 0.14), 8, 16, 12), Color("f0a040"), 3, 0, 0, 0))

	_variation(t, "SceneCard", "PanelContainer")
	t.set_stylebox("panel", "SceneCard", _border(_box(Color("0b0b0f"), 12), Color(1, 1, 1, 0.08) if dark else Color(0, 0, 0, 0.12), 1, 1, 1, 1))

	_variation(t, "PalettePanel", "PanelContainer")
	var pal: StyleBoxFlat = _border(_box(p.elevated, 12), p.border_strong, 1, 1, 1, 1)
	pal.shadow_color = p.shadow
	pal.shadow_size = 28
	pal.shadow_offset = Vector2(0, 10)
	t.set_stylebox("panel", "PalettePanel", pal)

	_variation(t, "PaletteFooter", "PanelContainer")
	var foot: StyleBoxFlat = _border(_box(p.sidebar, 0, 16, 7), p.border, 0, 1, 0, 0)
	foot.set_corner_radius(CORNER_BOTTOM_LEFT, 12)
	foot.set_corner_radius(CORNER_BOTTOM_RIGHT, 12)
	t.set_stylebox("panel", "PaletteFooter", foot)

	# Buttons — default is a quiet bordered button
	t.set_font("font", "Button", medium)
	t.set_font_size("font_size", "Button", 13)
	t.set_constant("h_separation", "Button", 6)
	_button_styles(t, "Button",
		_border(_box(p.elevated, 6, 12, 6), p.border_strong, 1, 1, 1, 1),
		_border(_box(p.elevated.lightened(0.04) if dark else p.sidebar, 6, 12, 6), p.border_strong, 1, 1, 1, 1),
		_border(_box(p.active, 6, 12, 6), p.border_strong, 1, 1, 1, 1))
	_button_colors(t, "Button", p.text, p.text, p.text, p.text_faint)

	# Ghost button: no chrome until hovered (toolbar/sidebar icons)
	_variation(t, "FlatButton", "Button")
	_button_styles(t, "FlatButton", _empty(8, 5), _box(p.hover, 6, 8, 5), _box(p.active, 6, 8, 5))
	_button_colors(t, "FlatButton", p.text_muted, p.text, p.text, p.text_faint)

	# Buttons on the always-dark 3D stage, whatever the app theme
	_variation(t, "StageButton", "Button")
	_button_styles(t, "StageButton", _empty(10, 4), _box(Color(1, 1, 1, 0.08), 6, 10, 4), _box(Color(1, 1, 1, 0.14), 6, 10, 4))
	_button_colors(t, "StageButton", Color("9a9aa4"), Color("ffffff"), Color("ffffff"), Color("5a5a62"))
	t.set_font_size("font_size", "StageButton", 12)

	_variation(t, "DangerButton", "Button")
	_button_styles(t, "DangerButton", _empty(8, 5), _box(Color(p.danger, 0.12), 6, 8, 5), _box(Color(p.danger, 0.2), 6, 8, 5))
	_button_colors(t, "DangerButton", p.text_muted, p.danger, p.danger, p.text_faint)

	_variation(t, "AccentButton", "Button")
	_button_styles(t, "AccentButton", _box(p.accent, 7, 16, 8), _box(p.accent.lightened(0.08), 7, 16, 8), _box(p.accent.darkened(0.1), 7, 16, 8))
	_button_colors(t, "AccentButton", p.accent_text, p.accent_text, p.accent_text, p.text_faint)
	t.set_font("font", "AccentButton", semibold)

	# Sidebar note rows — toggle buttons in a ButtonGroup; pressed == selected
	_variation(t, "NoteItem", "Button")
	_button_styles(t, "NoteItem", _empty(10, 7), _box(p.hover, 6, 10, 7), _box(Color(p.accent, 0.16), 6, 10, 7))
	_button_colors(t, "NoteItem", p.text_muted, p.text, p.text, p.text_faint)
	t.set_font("font", "NoteItem", FONT_SANS)
	t.set_font_size("font_size", "NoteItem", 13)

	# Segmented layer switcher — pressed segment lifts onto a card
	_variation(t, "SegmentButton", "Button")
	var seg_on: StyleBoxFlat = _border(_box(p.elevated if dark else Color.WHITE, 5, 12, 4), p.border_strong, 1, 1, 1, 1)
	_button_styles(t, "SegmentButton", _empty(12, 4), _box(p.hover, 5, 12, 4), seg_on)
	_button_colors(t, "SegmentButton", p.text_muted, p.text, p.text, p.text_faint)
	t.set_font_size("font_size", "SegmentButton", 12)

	# Text inputs
	for type in ["LineEdit", "TextEdit"]:
		t.set_color("font_color", type, p.text)
		t.set_color("font_placeholder_color", type, p.text_faint)
		t.set_color("caret_color", type, p.accent)
		t.set_color("selection_color", type, Color(p.accent, 0.3))
		t.set_color("font_selected_color", type, p.text)
	t.set_stylebox("normal", "LineEdit", _border(_box(p.elevated, 6, 10, 6), p.border_strong, 1, 1, 1, 1))
	t.set_stylebox("focus", "LineEdit", _border(_box(Color(0, 0, 0, 0), 6, 10, 6), p.accent, 1, 1, 1, 1))
	t.set_stylebox("read_only", "LineEdit", _box(p.elevated, 6, 10, 6))
	t.set_color("clear_button_color", "LineEdit", p.text_faint)
	t.set_color("clear_button_color_pressed", "LineEdit", p.text)

	_variation(t, "SearchEdit", "LineEdit")
	t.set_stylebox("normal", "SearchEdit", _box(p.hover, 7, 10, 6))
	t.set_stylebox("focus", "SearchEdit", _border(_box(p.hover, 7, 10, 6), Color(p.accent, 0.7), 1, 1, 1, 1))
	t.set_font_size("font_size", "SearchEdit", 13)

	# Inline document title, Obsidian style: big, chromeless
	_variation(t, "TitleEdit", "LineEdit")
	t.set_stylebox("normal", "TitleEdit", _empty(0, 2))
	t.set_stylebox("focus", "TitleEdit", _empty(0, 2))
	t.set_font("font", "TitleEdit", bold)
	t.set_font_size("font_size", "TitleEdit", 30)

	_variation(t, "PaletteSearch", "LineEdit")
	var ps: StyleBoxFlat = _border(_box(Color(0, 0, 0, 0), 0, 18, 14), p.border, 0, 0, 0, 1)
	t.set_stylebox("normal", "PaletteSearch", ps)
	t.set_stylebox("focus", "PaletteSearch", ps)
	t.set_font_size("font_size", "PaletteSearch", 16)

	# Note body editor: chromeless, generous line height
	t.set_stylebox("normal", "TextEdit", _empty(0, 8))
	t.set_stylebox("focus", "TextEdit", _empty(0, 8))
	t.set_stylebox("read_only", "TextEdit", _empty(0, 8))
	t.set_color("background_color", "TextEdit", Color(0, 0, 0, 0))
	t.set_color("current_line_color", "TextEdit", Color(0, 0, 0, 0))
	t.set_constant("line_spacing", "TextEdit", 7)
	t.set_font_size("font_size", "TextEdit", 15)

	# Code blocks (structured view) — mono on a card
	t.set_font("font", "CodeEdit", FONT_MONO)
	t.set_font_size("font_size", "CodeEdit", 13)
	t.set_stylebox("normal", "CodeEdit", _border(_box(p.sidebar, 8, 14, 10), p.border, 1, 1, 1, 1))
	t.set_stylebox("read_only", "CodeEdit", _border(_box(p.sidebar, 8, 14, 10), p.border, 1, 1, 1, 1))
	t.set_stylebox("focus", "CodeEdit", StyleBoxEmpty.new())
	t.set_color("font_readonly_color", "CodeEdit", p.text)
	t.set_constant("line_spacing", "CodeEdit", 4)

	# Labels & typography scale
	t.set_color("font_color", "Label", p.text)
	_variation(t, "MutedLabel", "Label")
	t.set_color("font_color", "MutedLabel", p.text_muted)
	t.set_font_size("font_size", "MutedLabel", 12)
	_variation(t, "FaintLabel", "Label")
	t.set_color("font_color", "FaintLabel", p.text_faint)
	t.set_font_size("font_size", "FaintLabel", 11)
	_variation(t, "SectionLabel", "Label")
	t.set_color("font_color", "SectionLabel", p.text_faint)
	t.set_font("font", "SectionLabel", semibold)
	t.set_font_size("font_size", "SectionLabel", 11)
	_variation(t, "BrandLabel", "Label")
	t.set_font("font", "BrandLabel", semibold)
	t.set_font_size("font_size", "BrandLabel", 15)
	_variation(t, "AccentLabel", "Label")
	t.set_color("font_color", "AccentLabel", p.accent)
	t.set_font_size("font_size", "AccentLabel", 16)
	_variation(t, "HeadingLabel", "Label")
	t.set_font("font", "HeadingLabel", semibold)
	t.set_font_size("font_size", "HeadingLabel", 20)
	_variation(t, "H1Label", "Label")
	t.set_font("font", "H1Label", bold)
	t.set_font_size("font_size", "H1Label", 26)
	_variation(t, "H2Label", "Label")
	t.set_font("font", "H2Label", semibold)
	t.set_font_size("font_size", "H2Label", 20)
	t.set_color("font_color", "H2Label", p.h2)
	_variation(t, "H3Label", "Label")
	t.set_font("font", "H3Label", semibold)
	t.set_font_size("font_size", "H3Label", 16)
	t.set_color("font_color", "H3Label", p.h3)
	_variation(t, "BodyLabel", "Label")
	t.set_font_size("font_size", "BodyLabel", 15)
	t.set_constant("line_spacing", "BodyLabel", 6)
	_variation(t, "BulletLabel", "Label")
	t.set_font_size("font_size", "BulletLabel", 15)
	t.set_color("font_color", "BulletLabel", p.text)
	t.set_color("default_color", "RichTextLabel", p.text)
	t.set_font_size("normal_font_size", "RichTextLabel", 15)
	t.set_constant("line_separation", "RichTextLabel", 6)
	t.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())
	t.set_stylebox("focus", "RichTextLabel", StyleBoxEmpty.new())
	t.set_font("normal_font", "RichTextLabel", FONT_SANS)
	t.set_font("mono_font", "RichTextLabel", FONT_MONO)
	t.set_font("bold_font", "RichTextLabel", bold)
	t.set_font("italics_font", "RichTextLabel", preload("res://fonts/AdwaitaSans-Italic.ttf"))
	t.set_font_size("mono_font_size", "RichTextLabel", 14)
	t.set_color("font_outline_color", "RichTextLabel", Color(0, 0, 0, 0))

	# Separators
	var line: StyleBoxLine = StyleBoxLine.new()
	line.color = p.border
	line.thickness = 1
	t.set_stylebox("separator", "HSeparator", line)
	t.set_constant("separation", "HSeparator", 12)

	# Thin, rounded, auto-dim scrollbars
	for sb_type in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", sb_type, _empty(3, 3))
		t.set_stylebox("scroll_focus", sb_type, _empty(3, 3))
		t.set_stylebox("grabber", sb_type, _box(Color(p.text, 0.14), 4, 3, 3))
		t.set_stylebox("grabber_highlight", sb_type, _box(Color(p.text, 0.24), 4, 3, 3))
		t.set_stylebox("grabber_pressed", sb_type, _box(Color(p.text, 0.32), 4, 3, 3))
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	t.set_stylebox("focus", "ScrollContainer", StyleBoxEmpty.new())

	# Split container: invisible bar (the sidebar's own hairline is the divider)
	t.set_constant("separation", "HSplitContainer", 0)
	t.set_constant("minimum_grab_thickness", "HSplitContainer", 8)
	t.set_constant("autohide", "HSplitContainer", 1)
	t.set_icon("grabber", "HSplitContainer", ImageTexture.new())
	t.set_icon("h_grabber", "HSplitContainer", ImageTexture.new())

	# Command palette list
	t.set_stylebox("panel", "ItemList", _empty(8, 8))
	t.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())
	t.set_stylebox("cursor", "ItemList", StyleBoxEmpty.new())
	t.set_stylebox("cursor_unfocused", "ItemList", StyleBoxEmpty.new())
	t.set_stylebox("selected", "ItemList", _box(Color(p.accent, 0.16), 6))
	t.set_stylebox("selected_focus", "ItemList", _box(Color(p.accent, 0.16), 6))
	t.set_stylebox("hovered", "ItemList", _box(p.hover, 6))
	t.set_stylebox("hovered_selected", "ItemList", _box(Color(p.accent, 0.2), 6))
	t.set_stylebox("hovered_selected_focus", "ItemList", _box(Color(p.accent, 0.2), 6))
	t.set_color("font_color", "ItemList", p.text_muted)
	t.set_color("font_hovered_color", "ItemList", p.text)
	t.set_color("font_selected_color", "ItemList", p.text)
	t.set_color("font_hovered_selected_color", "ItemList", p.text)
	t.set_color("guide_color", "ItemList", Color(0, 0, 0, 0))
	t.set_constant("v_separation", "ItemList", 4)
	t.set_constant("h_separation", "ItemList", 10)
	t.set_constant("icon_margin", "ItemList", 8)
	t.set_font_size("font_size", "ItemList", 14)

	# Floating surfaces: tooltips, menus, dialogs
	var float_box: StyleBoxFlat = _border(_box(p.elevated, 8, 10, 6), p.border_strong, 1, 1, 1, 1)
	float_box.shadow_color = p.shadow
	float_box.shadow_size = 12
	float_box.shadow_offset = Vector2(0, 4)
	t.set_stylebox("panel", "TooltipPanel", float_box)
	t.set_color("font_color", "TooltipLabel", p.text)
	t.set_font_size("font_size", "TooltipLabel", 12)
	t.set_stylebox("panel", "PopupMenu", float_box)
	t.set_stylebox("hover", "PopupMenu", _box(p.hover, 5))
	t.set_color("font_color", "PopupMenu", p.text)
	t.set_color("font_hover_color", "PopupMenu", p.text)
	t.set_stylebox("panel", "PopupPanel", float_box)
	t.set_stylebox("panel", "AcceptDialog", _box(p.elevated, 0, 12, 12))
	var win: StyleBoxFlat = _border(_box(p.elevated, 10), p.border_strong, 1, 1, 1, 1)
	win.expand_margin_top = 30
	win.shadow_color = p.shadow
	win.shadow_size = 20
	t.set_stylebox("embedded_border", "Window", win)
	t.set_stylebox("embedded_unfocused_border", "Window", win)
	t.set_color("title_color", "Window", p.text)
	t.set_font("title_font", "Window", semibold)

	return t
