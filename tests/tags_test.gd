extends SceneTree
## Tags, part 1: per-note tag storage and the TagBar in the editor.
## A tag added in the TagBar survives save and reload of the note's own
## .tres (no central index) — the second boot of the app re-reads it from
## disk. Tags are stored lowercase, deduped, and removed via their chip's ×.
## Then the TAGS sidebar filter (cleared when its tag is gone), the chips'
## filter-or-remove split, the TagInput's autocomplete, each tag's colour
## dot, the TAGS section folding away (remembered in the vault's ui.json)
## and its tag-list filter field.
##   headless:  godot --headless --path . -s res://tests/tags_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const UiScale = preload("res://ui_scale.gd")

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func boot() -> Control:
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	return app


## Find a tag's row button in the sidebar by its "#tag" label. Rows are HBoxes
## whose first child is the tag Button.
func sidebar_row(app: Control, tag: String) -> Button:
	for row in app.tag_sidebar_list.get_children():
		var btn = row.get_child(0)
		if btn is Button and (btn as Button).text == "#" + tag:
			return btn
	return null


## A TagBar chip's two parts: the '#tag' body (filters the notes by the tag)
## and the × (removes the tag from the note).
func chip_body(app: Control, i: int) -> Button:
	return app.tag_chips.get_child(i).find_child("Body", true, false) as Button


func chip_remove(app: Control, i: int) -> Button:
	return app.tag_chips.get_child(i).find_child("Remove", true, false) as Button


## Scroll a control into view in the nearest ScrollContainer holding it (the
## TagBar sits above the body's DocScroll, so it may have none), then click
## it for real.
func click_in_view(c: Control) -> void:
	var up: Node = c.get_parent()
	while up != null and not up is ScrollContainer:
		up = up.get_parent()
	if up != null:
		(up as ScrollContainer).ensure_control_visible(c)
		await frames(2)
	check(c.get_global_rect().end.x <= get_root().get_visible_rect().end.x, "%s is inside the window" % c.name)
	await click(c)


## A real mouse click (motion, press, release through the root viewport).
func click(c: Control) -> void:
	await click_at(c.get_global_rect().get_center())


func click_at(pos: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	await frames(2)


## The TAGS rows are on screen and answer a real mouse click. The rows'
## ScrollContainer used to get no height at all (a ScrollContainer asks for
## none), so the section showed its header and no rows.
func check_tag_rows_clickable(app: Control) -> void:
	var scroll: ScrollContainer = app.tag_sidebar_list.get_parent()
	check(scroll.size.y > 0.0 and scroll.size.y <= 132.0, "the TAGS rows get a visible box (height %d)" % scroll.size.y)
	var btn: Button = sidebar_row(app, "alpha")
	scroll.ensure_control_visible(btn)
	await frames(2)
	check(scroll.get_global_rect().encloses(btn.get_global_rect()), "the #alpha row is inside that box")
	await click(btn)
	check(app._active_tag_filter == "alpha", "a real click on the #alpha row filters (%s)" % app._active_tag_filter)
	await click(sidebar_row(app, "alpha"))
	check(app._active_tag_filter == "", "a second real click clears it (%s)" % app._active_tag_filter)


## Under a tag filter the sidebar shows only the folders holding a match:
## the seeded Godot course carries no #tutorial, so its folder hides while
## Tutorials stays. Clearing the filter brings every folder back.
func check_folders_without_matches_hide(app: Control) -> void:
	app._set_tag_filter("tutorial")
	await frames(2)
	check(app._folder_buttons.has("Tutorials"), "the #tutorial filter keeps the Tutorials folder (%s)" % [app._folder_buttons.keys()])
	check(not app._folder_buttons.has("Godot"), "the #tutorial filter hides the Godot folder, which has no match (%s)" % [app._folder_buttons.keys()])
	app._set_tag_filter("")
	await frames(2)
	check(app._folder_buttons.has("Godot") and app._folder_buttons.has("Tutorials"),
		"with no filter every folder shows again (%s)" % [app._folder_buttons.keys()])

	app.search_box.text = "#tutorial"
	app._on_search_changed("#tutorial")
	await frames(2)
	check(app._folder_buttons.has("Tutorials") and not app._folder_buttons.has("Godot"),
		"a '#tutorial' search hides the Godot folder too (%s)" % [app._folder_buttons.keys()])
	app.search_box.text = ""
	app._on_search_changed("")
	await frames(2)


## A row filter whose tag is gone must not strand the user: switching to a
## vault without that tag, or taking the tag off its last note, clears the
## filter and the full list returns. Before the fix the list read "0 / 1"
## with the TAGS section (and its ×) hidden.
func check_stale_filter_clears(app: Control) -> String:
	var v2: String = ProjectSettings.globalize_path("user://test-vault-tags-2/")
	TestVault.remove_tree(v2)
	DirAccess.make_dir_recursive_absolute(v2)
	var plain := ContentLayer.new()
	plain.title = "Untagged Only"
	plain.raw_text = "No tags here."
	plain.created = Time.get_datetime_string_from_system()
	plain.modified = plain.created
	ResourceSaver.save(plain, v2.path_join("Untagged Only.tres"))

	sidebar_row(app, "alpha").pressed.emit()
	await frames(2)
	check(app._active_tag_filter == "alpha", "the #alpha row filters before the vault switch")
	app.switch_vault(v2)
	await frames(3)
	check(app._active_tag_filter == "", "switching vaults clears the tag filter (%s)" % app._active_tag_filter)
	check(app._visible_notes.size() == 1, "the other vault's one note shows (%d)" % app._visible_notes.size())
	check(app.note_count_label.text == "1", "the count reads '1', not '0 / 1' (%s)" % app.note_count_label.text)

	# The only tag in the vault leaves its last note while it is the filter
	await open_tagged(app, "Solo Note", ["solo"])
	sidebar_row(app, "solo").pressed.emit()
	await frames(2)
	check(app._active_tag_filter == "solo" and app._visible_notes.size() == 1,
		"the #solo row narrows the list to its note (%d)" % app._visible_notes.size())
	app._remove_tag("solo")
	app._flush_pending_save()
	await frames(2)
	check(app._active_tag_filter == "", "taking #solo off its last note clears the filter (%s)" % app._active_tag_filter)
	check(app._visible_notes.size() == 2 and app.note_count_label.text == "2",
		"the full list returns (%d notes, count %s)" % [app._visible_notes.size(), app.note_count_label.text])
	return v2


## Part 2c: a chip is one pill with two targets. Its '#tag' body toggles the
## sidebar filter and leaves the note's tags alone; its × removes the tag and
## leaves the filter alone. Before, the whole chip removed the tag, so a click
## meant to filter silently dropped it. Real clicks, as a user makes them.
func check_chip_filter_and_remove(app: Control) -> void:
	await open_tagged(app, "Chip Clicks", ["alpha", "chipped"])
	var chip: Control = app.tag_chips.get_child(0)
	check(chip is PanelContainer and chip.theme_type_variation == &"TagChip"
		and chip_body(app, 0) != null and chip_remove(app, 0) != null,
		"a chip is one TagChip pill holding a #tag body and a ×")
	check(chip_body(app, 0).text == "#alpha" and chip_remove(app, 0).tooltip_text == "Remove #alpha",
		"the body reads #alpha, the × says it removes #alpha (%s)" % chip_remove(app, 0).tooltip_text)

	await click_in_view(chip_body(app, 0))
	check(app._active_tag_filter == "alpha", "clicking the #alpha chip filters by it (%s)" % app._active_tag_filter)
	check(app.current_note.tags == ["alpha", "chipped"], "and leaves the note's tags alone (%s)" % [app.current_note.tags])
	var shown: Array = visible_titles(app)
	shown.sort()
	check(shown == ["Alpha One", "Chip Clicks"], "the list narrows to the #alpha notes (%s)" % [shown])
	check(chip_body(app, 0).button_pressed and app.tag_chips.get_child(0).theme_type_variation == &"TagChipActive",
		"the filtering chip shows pressed")
	check(sidebar_row(app, "alpha").button_pressed, "and so does its TAGS row")

	await click_in_view(chip_remove(app, 1))
	await frames(2)
	check(app.current_note.tags == ["alpha"], "clicking the #chipped × removes that tag (%s)" % [app.current_note.tags])
	check(app._active_tag_filter == "alpha", "and leaves the filter alone (%s)" % app._active_tag_filter)

	await click_in_view(chip_body(app, 0))
	check(app._active_tag_filter == "", "clicking the #alpha chip again clears the filter (%s)" % app._active_tag_filter)
	check(app.current_note.tags == ["alpha"], "still without touching the tags (%s)" % [app.current_note.tags])
	check(not chip_body(app, 0).button_pressed and app.tag_chips.get_child(0).theme_type_variation == &"TagChip",
		"the chip shows unpressed again")

	# The sidebar row sets the same filter, and the chip follows it
	sidebar_row(app, "alpha").pressed.emit()
	await frames(2)
	check(chip_body(app, 0).button_pressed, "a TAGS-row filter presses the matching chip")
	app.tag_sidebar_clear.pressed.emit()
	await frames(2)
	check(not chip_body(app, 0).button_pressed, "clearing it releases the chip")
	app._flush_pending_save()
	await frames(2)


## A real key press and release, delivered to the focused control.
func key(code: Key) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = pressed
		get_root().push_input(e)
	await frames(2)


## Type `text` into the TagInput as a user would see it land: the text, the
## caret at its end, and the LineEdit's text_changed.
func type_tag(app: Control, text: String) -> void:
	app.tag_input.text = text
	app.tag_input.caret_column = text.length()
	app.tag_input.text_changed.emit(text)
	await frames(2)


## The tags the suggestion list offers, top to bottom.
func suggestions(app: Control) -> Array:
	var out: Array = []
	for i in range(app.tag_suggest_list.item_count):
		out.append(app.tag_suggest_list.get_item_metadata(i))
	return out


## How far the suggestion card reaches below its last row: the panel's
## margins when the card fits its rows, more when it keeps an old height.
func card_slack(app: Control) -> float:
	var list: ItemList = app.tag_suggest_list
	var last: Rect2 = list.get_global_transform() * list.get_item_rect(list.item_count - 1)
	return app.tag_suggest.get_global_rect().end.y - last.end.y


func row_height(app: Control) -> float:
	return app.tag_suggest_list.get_item_rect(0).size.y


## Part 2d: autocomplete. Typing in the TagInput lists the vault's tags that
## start with it (a leading '#' and the case do not matter), most used first,
## leaving out the note's own. Down/Up/Enter/Tab/Esc and a click work on the
## list, and the list never takes the focus from the TagInput.
func check_autocomplete(app: Control) -> void:
	for spec in [["Proj One", ["project"]], ["Proj Two", ["project"]], ["Prog One", ["programming"]], ["Pers One", ["personal"]]]:
		var n: ContentLayer = VaultStore.create_note(spec[0])
		n.tags.assign(spec[1])
		VaultStore.save_note(n)
	await open_tagged(app, "Autocomplete Note", [])
	app.tag_input.grab_focus()
	await frames(2)

	await type_tag(app, "pro")
	check(app.tag_suggest.visible, "typing 'pro' opens the suggestions")
	check(suggestions(app) == ["project", "programming"], "they list #project (2 notes) before #programming (%s)" % [suggestions(app)])
	var box: Rect2 = app.tag_suggest.get_global_rect()
	check(box.end.x <= 820.0 and box.position.x >= 0.0, "the list stays inside the window (%s)" % box)
	check(box.position.y >= app.tag_input.get_global_rect().end.y, "the list opens under the TagInput (%s)" % box)
	check(app.tag_input.has_focus(), "the TagInput keeps the focus while the list shows")
	await key(KEY_ESCAPE)
	check(not app.tag_suggest.visible and app.tag_input.text == "pro", "Esc closes the list and keeps the typed text")

	await type_tag(app, "#PRO")
	check(app.tag_suggest.visible and suggestions(app) == ["project", "programming"], "'#PRO' suggests the same tags (%s)" % [suggestions(app)])
	await key(KEY_DOWN)
	await key(KEY_ENTER)
	check(app.current_note.tags == ["project"], "Down then Enter adds #project (%s)" % [app.current_note.tags])
	check(not app.tag_suggest.visible and app.tag_input.text == "", "and closes the list with the input empty ('%s')" % app.tag_input.text)

	await type_tag(app, "pro")
	check(suggestions(app) == ["programming"], "a tag already on the note is not suggested (%s)" % [suggestions(app)])
	var list: ItemList = app.tag_suggest_list
	await click_at(list.get_global_transform() * list.get_item_rect(0).get_center())
	check(app.current_note.tags == ["project", "programming"], "a real click on a suggestion adds it (%s)" % [app.current_note.tags])
	check(not app.tag_suggest.visible and app.tag_input.has_focus(), "the list closes and the TagInput keeps the focus")

	await type_tag(app, "pers")
	check(suggestions(app) == ["personal"], "'pers' suggests #personal (%s)" % [suggestions(app)])
	await key(KEY_ENTER)
	check("pers" in app.current_note.tags and not "personal" in app.current_note.tags,
		"Enter with nothing highlighted adds the typed text, as before (%s)" % [app.current_note.tags])
	check(not app.tag_suggest.visible, "and closes the list")

	await type_tag(app, "pe")
	await key(KEY_DOWN)
	await key(KEY_TAB)
	check("personal" in app.current_note.tags, "Down then Tab takes the highlighted tag (%s)" % [app.current_note.tags])
	check(app.tag_input.has_focus(), "Tab on a suggestion does not move the focus on")

	await type_tag(app, "zzz")
	check(not app.tag_suggest.visible, "no match, no list")
	var many: ContentLayer = VaultStore.create_note("Many Tags")
	many.tags.assign(range(10).map(func(i: int) -> String: return "many%d" % i))
	VaultStore.save_note(many)
	app.tag_input.text = "many"
	app.tag_input.text_changed.emit("many")
	var opened: float = app.tag_suggest.size.y   # what _place_tag_suggestions saw
	await frames(2)
	check(suggestions(app) == ["many0", "many1", "many2", "many3", "many4", "many5", "many6", "many7"],
		"at most 8 suggestions, ties by name (%s)" % [suggestions(app)])
	check(app.tag_suggest.get_global_rect().end.y <= get_root().get_visible_rect().end.y,
		"a full list stays inside the window too (%s)" % app.tag_suggest.get_global_rect())
	check(opened == app.tag_suggest.size.y and card_slack(app) < row_height(app),
		"the card has its rows' height as it opens (%d, then %d; %d px below the last row)" % [opened, app.tag_suggest.size.y, card_slack(app)])
	# Narrowing the match set shrinks the card. It used to keep the previous
	# list's height: an empty card over the body, catching clicks there.
	await type_tag(app, "many9")
	check(suggestions(app) == ["many9"], "'many9' narrows the list to #many9 (%s)" % [suggestions(app)])
	check(card_slack(app) < row_height(app),
		"and the card shrinks to its one row (%s, %d px below the row)" % [app.tag_suggest.get_global_rect(), card_slack(app)])
	await type_tag(app, "")
	check(not app.tag_suggest.visible, "an empty input, no list")

	var other: ContentLayer = VaultStore.create_note("Quiet Note")
	other.tags.assign(["quiet"])
	VaultStore.save_note(other)
	await type_tag(app, "qu")
	check(app.tag_suggest.visible, "'qu' suggests #quiet")
	app.title_edit.grab_focus()
	await frames(2)
	check(not app.tag_suggest.visible, "the list hides when the TagInput loses the focus")

	# The title field is untouched by all this: Enter there still commits
	app.title_edit.text = "Autocomplete Renamed"
	await key(KEY_ENTER)
	check(app.current_note.title == "Autocomplete Renamed", "Enter in the title still renames the note (%s)" % app.current_note.title)
	check(app.raw_text_layer.has_focus(), "and moves on to the body")
	app._flush_pending_save()
	await frames(2)


## A real double-click: two press/release pairs at one spot, the second
## press flagged double_click, as the OS flags it.
func double_click_at(pos: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	for second in [false, true]:
		for pressed in [true, false]:
			var e := InputEventMouseButton.new()
			e.button_index = MOUSE_BUTTON_LEFT
			e.pressed = pressed
			e.double_click = second and pressed
			e.position = pos
			e.global_position = pos
			get_root().push_input(e)
		await frames(2)


## The point of suggestion row 0 that lies over a chip's ×, and that chip's
## index (-1 and the row's centre when none does).
func row_over_chip_remove(app: Control) -> Array:
	var list: ItemList = app.tag_suggest_list
	var row: Rect2 = list.get_global_transform() * list.get_item_rect(0)
	for i in range(app.tag_chips.get_child_count()):
		var x: Rect2 = chip_remove(app, i).get_global_rect()
		if row.intersects(x):
			return [row.intersection(x).get_center(), i]
	return [row.get_center(), -1]


## A double-click on a suggestion takes it once and touches nothing else.
## The click takes the tag on its press, which hides the card, and the card
## lies over the TagChips row: the second press used to land on the chip
## under it, so double-clicking #project removed #gamma. Only that second
## press is swallowed; a later click on the chip still works.
func check_suggestion_double_click(app: Control) -> void:
	await open_tagged(app, "Double Click", ["alpha", "beta", "gamma"])
	app.tag_input.grab_focus()
	await frames(2)
	await type_tag(app, "pro")
	check(suggestions(app) == ["project", "programming"], "'pro' suggests #project first (%s)" % [suggestions(app)])
	var aim: Array = row_over_chip_remove(app)
	check(aim[1] >= 0, "the #project row lies over a chip's × (%s)" % [aim])
	var under: String = str(app.tag_chips.get_child(aim[1]).get_meta(&"tag")) if aim[1] >= 0 else ""
	await double_click_at(aim[0])
	check(app.current_note.tags == ["alpha", "beta", "gamma", "project"],
		"a double-click on #project adds it once and removes no tag (%s; aimed over #%s's ×)" % [app.current_note.tags, under])
	check(app._active_tag_filter == "", "and sets no tag filter (%s)" % app._active_tag_filter)
	check(not app.tag_suggest.visible and app.tag_input.has_focus(), "the list closes and the TagInput keeps the focus")

	await type_tag(app, "pro")
	check(suggestions(app) == ["programming"], "'pro' now suggests #programming (%s)" % [suggestions(app)])
	aim = row_over_chip_remove(app)
	await click_at(aim[0])
	check("programming" in app.current_note.tags, "a single click on it adds it (%s)" % [app.current_note.tags])
	if aim[1] >= 0:
		under = str(app.tag_chips.get_child(aim[1]).get_meta(&"tag"))
		await click_at(aim[0])
		check(not under in app.current_note.tags and app.current_note.tags.size() == 4,
			"a later, separate click there goes to #%s's × and removes it (%s)" % [under, app.current_note.tags])
	app._flush_pending_save()
	await frames(2)


func visible_titles(app: Control) -> Array:
	return app._visible_notes.map(func(n: ContentLayer) -> String: return n.title)


## Set the search box's text the way the tests above do (text, then the
## LineEdit's text_changed).
func search(app: Control, text: String) -> void:
	app.search_box.text = text
	app._on_search_changed(text)
	await frames(2)


## Type `text` into the focused search box with real key events, one
## character at a time, as a user does.
func type_keys(text: String) -> void:
	for ch in text:
		for pressed in [true, false]:
			var e := InputEventKey.new()
			e.keycode = OS.find_keycode_from_string(ch.to_upper()) if ch != " " else KEY_SPACE
			e.unicode = ch.unicode_at(0)
			e.pressed = pressed
			get_root().push_input(e)
	await frames(2)


func has_tag_starting(note: ContentLayer, prefix: String) -> bool:
	return note.tags.any(func(t: String) -> bool: return TagOps.normalize(t).begins_with(prefix))


func says(note: ContentLayer, word: String) -> bool:
	return note.title.to_lower().contains(word) or note.raw_text.to_lower().contains(word)


func sorted_titles(app: Control) -> Array:
	var titles: Array = visible_titles(app)
	titles.sort()
	return titles


## Batch 3: one search box for tags and words. '#tutorial quiz' is the tag
## #tutorial (a prefix, as a '#…' search always was) AND the word 'quiz' in
## the title or body. It used to be read as the one tag 'tutorial-quiz', which
## no note carries, so it found nothing. A TAGS-row filter now combines with
## typed words (it used to be wiped by the first letter typed), and
## '#alpha #beta' wants both tags.
func check_tags_and_words(app: Control) -> void:
	var total: int = VaultStore.note_list.size()
	await search(app, "#tutorial quiz")
	var found: Array = sorted_titles(app)
	check(found.has("Tutorial 5: Making a Quiz"), "'#tutorial quiz' finds 'Tutorial 5: Making a Quiz' (%s)" % [found])
	check(app._visible_notes.all(func(n: ContentLayer) -> bool: return has_tag_starting(n, "tutorial") and says(n, "quiz")),
		"every match carries a #tutorial… tag and says 'quiz' (%s)" % [found])
	check(found.size() < total, "and the tag narrows the list (%d of %d)" % [found.size(), total])
	check(app._folder_buttons.is_empty(), "with words the list is the flat matches, no folders (%s)" % [app._folder_buttons.keys()])
	check(app.note_count_label.text == "%d / %d" % [found.size(), total], "the count reads k / N (%s)" % app.note_count_label.text)
	await search(app, "#tutorial objective")
	var narrow: Array = sorted_titles(app)
	await search(app, "#tutorial")
	check(app._folder_buttons.has("Tutorials"), "with only a tag the folder tree shows (%s)" % [app._folder_buttons.keys()])
	check(narrow.size() > 0 and narrow.size() < app._visible_notes.size(),
		"a rarer word narrows the #tutorial notes ('objective': %d of %d)" % [narrow.size(), app._visible_notes.size()])
	await search(app, "")
	check(app._active_tag_filter == "" and app._visible_notes.size() == total, "an empty box shows every note again")

	# A row filter, then words typed with real keys: the same set, and the
	# row filter stays
	sidebar_row(app, "tutorial").pressed.emit()
	await frames(2)
	var tutorial_only: Array = sorted_titles(app)
	app.search_box.grab_focus()
	await type_keys("quiz")
	check(app.search_box.text == "quiz", "the keys land in the search box (%s)" % app.search_box.text)
	check(sorted_titles(app) == found, "the #tutorial row plus typed 'quiz' gives the same set (%s)" % [sorted_titles(app)])
	check(app._active_tag_filter == "tutorial", "and the row filter stays (%s)" % app._active_tag_filter)
	check(sidebar_row(app, "tutorial").button_pressed, "its row stays pressed")
	check(app.note_count_label.text == "%d / %d" % [found.size(), total], "the count reads k / N (%s)" % app.note_count_label.text)
	app.search_box.select_all()
	await type_keys("objective")
	check(sorted_titles(app) == narrow and app._active_tag_filter == "tutorial",
		"the row plus typed 'objective' gives the '#tutorial objective' set (%s)" % [sorted_titles(app)])
	await search(app, "")
	check(sorted_titles(app) == tutorial_only and app._active_tag_filter == "tutorial",
		"clearing the box restores the tutorial-only list (%d notes)" % app._visible_notes.size())
	app.tag_sidebar_clear.pressed.emit()
	await frames(2)

	# Two tags: both must be on the note
	var both: ContentLayer = VaultStore.create_note("Alpha And Beta")
	both.tags.assign(["alpha", "beta"])
	VaultStore.save_note(both)
	await search(app, "#alpha #beta")
	check(visible_titles(app) == ["Alpha And Beta"], "'#alpha #beta' shows only the note carrying both (%s)" % [visible_titles(app)])
	check(sidebar_row(app, "alpha").button_pressed and sidebar_row(app, "beta").button_pressed,
		"both tags' rows show pressed")
	await search(app, "#alpha #beta and")
	check(visible_titles(app) == ["Alpha And Beta"], "plus a word in its title it still shows (%s)" % [visible_titles(app)])
	await search(app, "#alpha #beta zzzz")
	check(app._visible_notes.is_empty(), "plus a word it lacks it does not (%s)" % [visible_titles(app)])
	await search(app, "")
	check(app._active_tag_filter == "" and app._visible_notes.size() == total + 1,
		"erasing the search clears the filter it set (%d)" % app._visible_notes.size())
	VaultStore.delete_note(VaultStore.get_note_index("Alpha And Beta"))
	app._refresh_note_list()
	await frames(2)


## The live TAGS rows whose label reads `text`, ignoring case.
func rows_reading(app: Control, text: String) -> Array:
	return app.tag_sidebar_list.get_children().filter(func(r: Node) -> bool:
		return not r.is_queued_for_deletion() and (r.get_child(0) as Button).text.to_lower() == text)


## Part 2b: one tag whatever its spelling (TagOps.normalize). A note written
## by the importer or MCP ("Physics") and one written by the app ("physics")
## share one TAGS row, its count, the '#' search and the row filter; the
## TagBar dedups against the stored spelling and stores normalized tags.
func check_one_tag_any_case(app: Control) -> void:
	var upper: ContentLayer = VaultStore.create_note("Physics Upper")
	upper.tags.assign(["Physics"])
	VaultStore.save_note(upper)
	var lower: ContentLayer = VaultStore.create_note("Physics Lower")
	lower.tags.assign(["physics"])
	VaultStore.save_note(lower)
	app._refresh_note_list()
	await frames(2)
	var rows: Array = rows_reading(app, "#physics")
	check(rows.size() == 1 and (rows[0].get_child(0) as Button).text == "#physics",
		"'Physics' and 'physics' share one '#physics' row (%d rows)" % rows.size())
	check(rows.size() == 1 and (rows[0].get_child(1) as Label).text.strip_edges() == "2",
		"the '#physics' row counts both notes (%s)" % ((rows[0].get_child(1) as Label).text if rows.size() > 0 else "no row"))

	var both: Array = ["Physics Lower", "Physics Upper"]
	for query in ["#physics", "#PHYS"]:
		app.search_box.text = query
		app._on_search_changed(query)
		await frames(2)
		var found: Array = visible_titles(app)
		found.sort()
		check(found == both, "a '%s' search shows both notes (%s)" % [query, found])
	app.search_box.text = ""
	app._on_search_changed("")
	await frames(2)

	sidebar_row(app, "physics").pressed.emit()
	await frames(2)
	var shown: Array = visible_titles(app)
	shown.sort()
	check(shown == both, "pressing the '#physics' row shows both notes (%s)" % [shown])
	app.tag_sidebar_clear.pressed.emit()
	await frames(2)

	# The TagBar on the 'Physics' note
	app.open_note_by_title("Physics Upper")
	await frames(2)
	app.tag_input.text = "PHYSICS"
	app._on_tag_submitted("PHYSICS")
	await frames(2)
	check(app.current_note.tags.size() == 1, "'PHYSICS' on the 'Physics' note adds no second tag (%s)" % [app.current_note.tags])
	app.tag_input.text = "Cultural Evolution"
	app._on_tag_submitted("Cultural Evolution")
	await frames(2)
	check("cultural-evolution" in app.current_note.tags,
		"'Cultural Evolution' is stored as 'cultural-evolution' (%s)" % [app.current_note.tags])
	check(app.tag_chips.get_child_count() == 2 and chip_body(app, 0).text == "#physics",
		"the chips read the normalized tags")
	app._flush_pending_save()
	await frames(2)
	check(app.current_note.tags == ["physics", "cultural-evolution"],
		"the app's next save stores the note's tags normalized (%s)" % [app.current_note.tags])
	var fresh: Resource = ResourceLoader.load(app.current_note.resource_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	check(fresh is ContentLayer and (fresh as ContentLayer).tags == ["physics", "cultural-evolution"],
		"the normalized tags are on disk (%s)" % [(fresh as ContentLayer).tags if fresh is ContentLayer else "no resource"])


## Save a new note carrying `tags`, open it, and let the layout settle.
func open_tagged(app: Control, title: String, tags: Array) -> void:
	var note: ContentLayer = VaultStore.create_note(title)
	note.tags.assign(tags)
	VaultStore.save_note(note)
	app._refresh_note_list()
	app.open_note_by_title(title)
	await frames(8)


## The editor's right edge in the root viewport (820 px wide headless).
func editor_right(app: Control) -> float:
	return app.content_panel.get_global_rect().end.x


## The colour of the dot a chip body or a TAGS row carries as its icon.
func dot_color(btn: Button) -> Color:
	return btn.get_theme_color(&"icon_normal_color") if btn != null and btn.icon != null else Color.TRANSPARENT


## Each tag has one colour (AppTheme.tag_color over TagOps.color_index): the
## dot on its chip and the dot before its TAGS row match, in every button
## state, and both take the other theme's palette when the theme flips.
## Expects the open note to carry #project.
func check_tag_colors(app: Control) -> void:
	var tag: String = "project"
	var dark: Color = AppTheme.tag_color(tag, true)
	var light: Color = AppTheme.tag_color(tag, false)
	check(app.tag_chips.get_child_count() > 0 and chip_body(app, 0).text == "#" + tag, "the open note's chip is #project")
	check(chip_body(app, 0).icon != null and sidebar_row(app, tag).icon != null,
		"the #project chip and its TAGS row carry a dot")
	check(dot_color(chip_body(app, 0)) == dark and dot_color(sidebar_row(app, tag)) == dark,
		"chip and row share #project's dark-theme colour (%s, %s, want %s)" % [
			dot_color(chip_body(app, 0)), dot_color(sidebar_row(app, tag)), dark])
	for state in [&"icon_hover_color", &"icon_pressed_color", &"icon_hover_pressed_color", &"icon_focus_color"]:
		check(chip_body(app, 0).get_theme_color(state) == dark and sidebar_row(app, tag).get_theme_color(state) == dark,
			"the dot keeps the tag's colour in %s" % state)
	check(dot_color(sidebar_row(app, "alpha")) == AppTheme.tag_color("alpha", true),
		"the #alpha row has alpha's own colour (%s)" % dot_color(sidebar_row(app, "alpha")))

	app._toggle_theme()
	await frames(2)   # the old chips and rows are queue_free'd by now
	check(light != dark, "#project's light colour differs from its dark one")
	check(dot_color(chip_body(app, 0)) == light and dot_color(sidebar_row(app, tag)) == light,
		"after the theme flips, chip and row take the light palette (%s, %s, want %s)" % [
			dot_color(chip_body(app, 0)), dot_color(sidebar_row(app, tag)), light])
	app._toggle_theme()
	await frames(2)
	check(dot_color(chip_body(app, 0)) == dark and dot_color(sidebar_row(app, tag)) == dark,
		"flipping back restores the dark colours")


## True when `btn` shows Icons' `name` icon, at whatever size.
func is_icon(btn: Button, name: String) -> bool:
	return btn.icon != null and btn.icon == Icons.get_icon(name, btn.icon.get_width())


## A file's SHA-256, or "missing" when there is none.
func sha_or_missing(path: String) -> String:
	return FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "missing"


## The open vault's .ontomeme/ui.json ({} when missing or not an object).
func ui_json() -> Dictionary:
	var p: String = VaultStore.data_dir().path_join("ui.json")
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else null
	return v if v is Dictionary else {}


func write_ui_json(ui: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(VaultStore.data_dir())   # no ui.json written yet
	var f := FileAccess.open(VaultStore.data_dir().path_join("ui.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(ui, "\t"))
	f.close()


## Keys other features keep in the same ui.json: starred-pinned's folded
## sections, app-shell-ux's open note and view. Neither the TAGS header nor
## the folders may drop or change them when they write their own key.
const FOREIGN_UI: Dictionary = {"sections_collapsed": ["pinned"], "last_note": "x.tres", "last_mode": "raw"}


## True when ui.json still holds every FOREIGN_UI key, unchanged.
func keeps_foreign_keys() -> bool:
	var ui: Dictionary = ui_json()
	return FOREIGN_UI.keys().all(func(k: String) -> bool: return ui.get(k) == FOREIGN_UI[k])


## The TAGS header folds the section away (a real click), the vault's
## ui.json remembers it beside the folded folders and other features' keys
## (each save keeps all the others), and a fresh boot on the same vault comes
## back folded. While folded, an active filter shows as '#tag ×' in the
## header, and that × clears it. Returns the app booted the second time.
func check_tags_collapse(app: Control) -> Control:
	var scroll: ScrollContainer = app.tag_sidebar_list.get_parent()
	check(app.tag_sidebar_toggle is Button and app.tag_sidebar_toggle.text == "TAGS",
		"the TAGS header is a button (%s)" % app.tag_sidebar_toggle)
	check(scroll.is_visible_in_tree(), "the TAGS rows show to begin with")
	# Other features' keys, read in as a boot reads ui.json (so a feature
	# that holds its key in memory writes back what is on disk)
	write_ui_json(ui_json().merged(FOREIGN_UI, true))
	app._load_collapsed()
	app._toggle_folder("Godot")
	await frames(2)
	check(ui_json().get("collapsed") == ["Godot"], "a folded folder lands in ui.json (%s)" % [ui_json()])
	check(keeps_foreign_keys(), "and the other features' keys stay in ui.json (%s)" % [ui_json()])

	await click(app.tag_sidebar_toggle)
	check(not scroll.is_visible_in_tree(), "a real click on the TAGS header hides the rows")
	check(is_icon(app.tag_sidebar_toggle, "chevron_right"), "the header's chevron points right while folded")
	check(ui_json().get("tags_collapsed") == true and ui_json().get("collapsed") == ["Godot"],
		"ui.json holds tags_collapsed and keeps the folded folder (%s)" % [ui_json()])
	check(keeps_foreign_keys(),
		"folding TAGS keeps sections_collapsed, last_note and last_mode in ui.json (%s)" % [ui_json()])
	app._toggle_folder("Tutorials")
	await frames(2)
	check(ui_json().get("tags_collapsed") == true and ui_json().get("collapsed") == ["Godot", "Tutorials"],
		"folding a folder keeps tags_collapsed in ui.json (%s)" % [ui_json()])
	check(keeps_foreign_keys(), "and keeps the other features' keys too (%s)" % [ui_json()])
	app._toggle_folder("Tutorials")
	await frames(2)
	# Out again before the reboot: a merged app would act on them at boot
	var ui: Dictionary = ui_json()
	for k in FOREIGN_UI:
		ui.erase(k)
	write_ui_json(ui)

	app.queue_free()
	await frames(2)
	app = await boot()
	scroll = app.tag_sidebar_list.get_parent()
	check(app.tag_sidebar.visible and not scroll.is_visible_in_tree(),
		"booted again on the same vault, the TAGS section is still folded")
	check(app._collapsed.has("Godot") and not app._collapsed.has("Tutorials"),
		"and the folded folder is still folded (%s)" % [app._collapsed.keys()])
	check(ui_json().get("collapsed") == ["Godot"], "ui.json still holds the folder 'collapsed' list (%s)" % [ui_json()])

	# Folded, with a filter set: the header names it and its × clears it
	app._set_tag_filter("alpha")
	await frames(2)
	var narrowed: int = app._visible_notes.size()
	check(app.tag_sidebar_clear.is_visible_in_tree() and app.tag_sidebar_clear.text == "#alpha",
		"folded with #alpha active, the header shows '#alpha ×' (%s)" % app.tag_sidebar_clear.text)
	check(app.tag_sidebar_clear.get_global_rect().end.x <= get_root().get_visible_rect().end.x,
		"the header's '#alpha ×' is inside the window")
	await click(app.tag_sidebar_clear)
	check(app._active_tag_filter == "" and app._visible_notes.size() > narrowed,
		"a real click on that × clears the filter (%s, %d notes)" % [app._active_tag_filter, app._visible_notes.size()])
	check(not app.tag_sidebar_clear.visible, "the × hides with the filter gone")
	# A "#…" search owns its filter: the × takes the "#…" tokens out of the
	# search box and keeps the words, or the next rebuild would set it again
	await search(app, "#alpha one")
	check(app.tag_sidebar_clear.visible and app.tag_sidebar_clear.text == "#alpha",
		"folded, a '#alpha one' search shows '#alpha ×' too (%s)" % app.tag_sidebar_clear.text)
	await click(app.tag_sidebar_clear)
	check(app._active_tag_filter == "" and app.search_box.text == "one",
		"its × drops '#alpha' from the search and keeps 'one' (%s, '%s')" % [app._active_tag_filter, app.search_box.text])
	await search(app, "")

	await click(app.tag_sidebar_toggle)
	check(scroll.is_visible_in_tree() and ui_json().get("tags_collapsed") == false,
		"a second click unfolds the rows and ui.json follows (%s)" % [ui_json()])
	check(is_icon(app.tag_sidebar_toggle, "chevron_down"), "the chevron points down again")
	app._set_tag_filter("alpha")
	await frames(2)
	check(app.tag_sidebar_clear.visible and app.tag_sidebar_clear.text == "",
		"unfolded, the pressed row names the filter and the header shows only ×")
	app._set_tag_filter("")
	app._toggle_folder("Godot")
	await frames(2)
	return app


## The rows' "#tag" texts, top to bottom.
func tag_row_names(app: Control) -> Array:
	return app.tag_sidebar_list.get_children().filter(func(r: Node) -> bool: return not r.is_queued_for_deletion()) \
		.map(func(r: Node) -> String: return (r.get_child(0) as Button).text)


## A vault with more than 8 tags gets a field above the TAGS rows that
## narrows them to the tags containing what is typed (normalized: '#Pro' is
## 'pro'); with fewer tags there is no field. In a vault of its own (`v3`,
## an empty directory), with exactly 3 tags first, then 10.
func check_tag_list_filter(app: Control, v3: String) -> void:
	app.switch_vault(v3)
	await frames(2)
	await open_tagged(app, "Three Tags", ["project", "alpha", "beta"])
	app._refresh_note_list()
	await frames(2)
	check(tag_row_names(app).size() == 3, "the vault lists 3 tags (%s)" % [tag_row_names(app)])
	check(not app.tag_sidebar_filter.visible, "with 3 tags the filter field is hidden")

	await open_tagged(app, "Seven More", ["prose", "approach", "gamma", "delta", "epsilon", "zeta", "eta"])
	app._refresh_note_list()
	await frames(2)
	check(tag_row_names(app).size() == 10, "the vault lists 10 tags (%s)" % [tag_row_names(app)])
	check(app.tag_sidebar_filter.is_visible_in_tree(), "with 10 tags the filter field shows")

	await click(app.tag_sidebar_filter)
	check(app.tag_sidebar_filter.has_focus(), "a click puts the cursor in the filter field")
	await type_keys("pro")
	check(app.tag_sidebar_filter.text == "pro", "typed 'pro' (%s)" % app.tag_sidebar_filter.text)
	var names: Array = tag_row_names(app)
	names.sort()
	check(names == ["#approach", "#project", "#prose"], "'pro' leaves only the rows containing it (%s)" % [names])
	var scroll: ScrollContainer = app.tag_sidebar_list.get_parent()
	check(scroll.custom_minimum_size.y < 3 * 40.0, "the rows' box shrinks to the 3 rows (%d)" % scroll.custom_minimum_size.y)

	app.tag_sidebar_filter.text = "#PRO"
	app.tag_sidebar_filter.text_changed.emit("#PRO")
	await frames(2)
	check(tag_row_names(app).size() == 3, "'#PRO' normalizes to 'pro' (%s)" % [tag_row_names(app)])
	app.tag_sidebar_filter.text = "zz"
	app.tag_sidebar_filter.text_changed.emit("zz")
	await frames(2)
	check(tag_row_names(app).is_empty() and app.tag_sidebar.visible and app.tag_sidebar_filter.visible,
		"no match: no rows, but the field stays to fix the typing")
	app.tag_sidebar_filter.text = ""
	app.tag_sidebar_filter.text_changed.emit("")
	await frames(2)
	check(tag_row_names(app).size() == 10, "an empty field lists every tag again (%d)" % tag_row_names(app).size())

	# Back under 9 tags: the field hides and drops its text, so no hidden
	# text can narrow the rows
	app.tag_sidebar_filter.text = "a"
	app.tag_sidebar_filter.text_changed.emit("a")
	await frames(2)
	var seven: ContentLayer = VaultStore.note_list[VaultStore.get_note_index("Seven More")]
	seven.tags.clear()
	VaultStore.save_note(seven)
	app._refresh_note_list()
	await frames(2)
	check(not app.tag_sidebar_filter.visible and app.tag_sidebar_filter.text == "" and tag_row_names(app).size() == 3,
		"back to 3 tags, the field hides, empty, and every row shows (%s)" % [tag_row_names(app)])


## Part 3: chips wrap onto new lines instead of widening the editor. Before
## the fix a 4-tag note at the 820 px minimum crashed Godot (a runaway
## layout: the side margins grew with the panel they widened).
func check_tag_layout(app: Control) -> void:
	var width: float = get_root().get_visible_rect().size.x
	check(width <= 820.0, "the headless root is the 820 px minimum (%d)" % width)

	await open_tagged(app, "Memetics Tags", ["memetics", "ontology", "culture", "evolution"])
	check(editor_right(app) <= 820.0,
		"a seeded Memetics tag set stays inside the window (right edge %d)" % editor_right(app))

	await open_tagged(app, "Four Tags", ["tagnumber0", "tagnumber1", "tagnumber2", "tagnumber3"])
	check(app.current_note.title == "Four Tags" and app.tag_chips.get_child_count() == 4,
		"a note with four tags opens (%d chips)" % app.tag_chips.get_child_count())
	check(editor_right(app) <= 820.0, "four tags stay inside the window (right edge %d)" % editor_right(app))

	var long_tag: String = "a-very-long-tag-".repeat(5)   # 80 chars
	var many: Array = [long_tag]
	for i in range(11):
		many.append("tagnumber%d" % i)
	await open_tagged(app, "Twelve Tags", many)
	check(editor_right(app) <= 820.0, "twelve tags stay inside the window (right edge %d)" % editor_right(app))
	var layout_min: float = (app.get_node("AppLayout") as Control).get_combined_minimum_size().x
	check(layout_min <= 820.0, "the long tag's sidebar row does not widen the app (min %d)" % layout_min)
	check(app.tag_bar.get_combined_minimum_size().x <= 760.0,
		"the tag bar asks for no more than the readable width (%d)" % app.tag_bar.get_combined_minimum_size().x)
	check(app.tag_chips.get_child_count() == 12, "one chip per tag (%d)" % app.tag_chips.get_child_count())
	var first: Control = app.tag_chips.get_child(0)
	var last: Control = app.tag_chips.get_child(app.tag_chips.get_child_count() - 1)
	check(last.position.y > first.position.y,
		"the chips wrap onto a new line (first y %d, last y %d)" % [first.position.y, last.position.y])
	var long_chip: Button = chip_body(app, 0)
	check(long_chip.text.length() <= 32 and long_chip.text.ends_with("…"),
		"a long tag's chip is shortened (%s)" % long_chip.text)
	check(long_chip.tooltip_text.contains(long_tag), "the chip's tooltip carries the full tag")
	check(chip_remove(app, 0).tooltip_text.contains(long_tag), "so does its ×'s tooltip")

	# Hardening: the side margins come from the width the editor is given,
	# so even a child wider than READABLE_WIDTH cannot feed back into them.
	var probe := Control.new()
	probe.custom_minimum_size = Vector2(900, 0)
	app.title_edit.add_sibling(probe)
	await frames(8)
	var settled: float = app.content_panel.size.x
	await frames(8)
	check(app.content_panel.size.x == settled and settled < 1100.0,
		"a too-wide child does not grow the margins frame after frame (%d, then %d)" % [settled, app.content_panel.size.x])
	probe.queue_free()
	await frames(8)
	check(editor_right(app) <= 820.0, "the editor returns to the window once it is gone (right edge %d)" % editor_right(app))


func _init() -> void:
	# The app's own theme and zoom file, shared with an installed Ontomeme:
	# check_tag_colors flips the theme twice, which must not reach it
	var real_display: String = UiScale._file()
	var real_display_sha: String = sha_or_missing(real_display)
	UiScale.file_override = "user://test_display_tags.json"   # starts dark, whatever the real setting
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UiScale.file_override))
	UiScale._loaded = false
	JourneyStore.file_override = "user://test_journey_tags.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_tags.json"   # never touch real progress
	ProgressStore.reset()
	TestVault.open("tags")

	# ── Part 1, in the editor ──
	var app: Control = await boot()
	app._on_new_note_pressed()
	await frames(2)
	check(app.current_note != null and app.current_note.tags.is_empty(), "a new note starts untagged")
	check(app.tag_bar.visible and not app.tag_chips.visible, "tag bar shows, chips stay hidden with no tags")

	app.title_edit.text = "Tag Survival Note"
	app._commit_title()
	await frames(2)

	app.tag_input.text = "#ProJect"
	app._on_tag_submitted("#ProJect")
	await frames(2)
	check(app.current_note.tags == ["project"], "Enter adds a lowercase tag (%s)" % app.current_note.tags)
	check(app.tag_chips.visible and app.tag_chips.get_child_count() == 1, "the tag shows as a chip")
	check(chip_body(app, 0).text == "#project", "chip reads #project")

	app.tag_input.text = "PROJECT"
	app._on_tag_submitted("PROJECT")
	await frames(2)
	check(app.current_note.tags == ["project"], "same tag, other case, dedupes (%s)" % app.current_note.tags)

	app.tag_input.text = "second"
	app._on_tag_submitted("second")
	await frames(2)   # dying chips are queue_free'd; by the next frame the list is [project, second]
	chip_remove(app, 1).pressed.emit()   # the second tag's × removes it
	await frames(2)
	check(app.current_note.tags == ["project"], "the chip's × removes the tag (%s)" % app.current_note.tags)
	check(app.note_meta.text.contains("#project"), "meta line shows the tag")

	# ── The tag survives save and reload ──
	app._flush_pending_save()
	await frames(2)
	var path: String = app.current_note.resource_path
	check(path != "" and FileAccess.file_exists(path), "the note has its own .tres (%s)" % path)
	var disk_file := FileAccess.open(path, FileAccess.READ)
	var disk: String = disk_file.get_as_text() if disk_file != null else ""
	check(disk.contains("project"), "the tag is in the note's own file, not a central index")
	var fresh: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	check(fresh is ContentLayer and (fresh as ContentLayer).tags == ["project"],
		"a tag survives a reload of the .tres from disk (%s)" % ((fresh as ContentLayer).tags if fresh is ContentLayer else "no resource"))
	app.queue_free()
	await frames(2)

	# Second boot: the app re-reads the vault and the tag comes back
	app = await boot()
	app.open_note_by_title("Tag Survival Note")
	await frames(3)
	check(app.current_note != null and app.current_note.tags == ["project"],
		"the tag is on the note after the app reloads the vault")
	check(app.tag_bar.visible and app.tag_chips.get_child_count() == 1
		and chip_body(app, 0).text == "#project",
		"the chip rebuilds from the reloaded note")

	# ── Part 2: the sidebar-wide tag filter ──
	# Seed two more notes, one per tag, then sync the app's sidebar.
	var alpha: ContentLayer = VaultStore.create_note("Alpha One")
	alpha.tags = ["alpha"]
	VaultStore.save_note(alpha)
	var beta: ContentLayer = VaultStore.create_note("Beta One")
	beta.tags = ["beta"]
	VaultStore.save_note(beta)
	app._refresh_note_list()
	await frames(2)
	var full_count: int = app._visible_notes.size()
	check(full_count >= 3, "vault has the seeded + new notes (%d)" % full_count)
	check(sidebar_row(app, "alpha") != null and sidebar_row(app, "beta") != null
		and sidebar_row(app, "project") != null, "the sidebar lists the tags (alpha, beta, project)")
	# Each row carries its count label ("  N"): one note per tag here.
	var alpha_row: HBoxContainer = app.tag_sidebar_list.get_children().filter(
		func(r) -> bool: return r.get_child(0) is Button and (r.get_child(0) as Button).text == "#alpha")[0]
	check((alpha_row.get_child(1) as Label).text.strip_edges() == "1",
		"the alpha row shows its count (%s)" % (alpha_row.get_child(1) as Label).text)

	# Select a tag: the note list narrows to the notes carrying it.
	sidebar_row(app, "alpha").pressed.emit()
	await frames(2)
	check(app._active_tag_filter == "alpha", "selecting a row sets the filter (%s)" % app._active_tag_filter)
	check(app._visible_notes.size() == 1 and app._visible_notes[0].title == "Alpha One",
		"the note list narrows to the tagged note (%d)" % app._visible_notes.size())
	check(sidebar_row(app, "alpha").button_pressed, "the selected row is highlighted")
	check(app.tag_sidebar_clear.visible, "the clear button shows while a filter is set")

	# Re-click the same row: the filter clears, the full list returns.
	sidebar_row(app, "alpha").pressed.emit()
	await frames(2)
	check(app._active_tag_filter == "", "re-clicking the row clears the filter")
	check(app._visible_notes.size() == full_count, "the full note list is restored (%d)" % app._visible_notes.size())
	check(not app.tag_sidebar_clear.visible, "the clear button hides with no filter")

	# Select #beta, then clear it with the section's × (clear restores it).
	sidebar_row(app, "beta").pressed.emit()
	await frames(2)
	check(app._visible_notes.size() == 1 and app._visible_notes[0].title == "Beta One",
		"#beta narrows to Beta One (%d)" % app._visible_notes.size())
	app.tag_sidebar_clear.pressed.emit()
	await frames(2)
	check(app._active_tag_filter == "" and app._visible_notes.size() == full_count,
		"the × clears the filter and restores the list (%d)" % app._visible_notes.size())

	# Search integration: a "#…" prefix in the search box is a tag filter.
	app.search_box.text = "#alpha"
	app._on_search_changed("#alpha")
	await frames(2)
	check(app._visible_notes.size() == 1 and app._visible_notes[0].title == "Alpha One",
		"a '#alpha' search narrows to Alpha One (%d)" % app._visible_notes.size())
	# Clearing the search box drops the search-set filter (a row-set one would
	# have survived an empty box).
	app.search_box.text = ""
	app._on_search_changed("")
	await frames(2)
	check(app._active_tag_filter == "" and app._visible_notes.size() == full_count,
		"clearing the '#' search restores the full list (%d)" % app._visible_notes.size())

	await check_tag_colors(app)
	await check_tags_and_words(app)
	await check_tag_rows_clickable(app)
	await check_folders_without_matches_hide(app)
	await check_one_tag_any_case(app)
	await check_tag_layout(app)
	await check_chip_filter_and_remove(app)
	app = await check_tags_collapse(app)

	# Last: these switch the app to a second vault, which goes on the recent
	# list, so the list is backed up and restored exactly
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	var v2: String = await check_stale_filter_clears(app)
	await check_autocomplete(app)
	await check_suggestion_double_click(app)
	# Never from a check's return value: a check that dies returns null, and
	# remove_tree("") would empty the working directory (the checkout)
	var v3: String = ProjectSettings.globalize_path("user://test-vault-tags-3/")
	TestVault.remove_tree(v3)
	DirAccess.make_dir_recursive_absolute(v3)
	await check_tag_list_filter(app, v3)
	if registry_backup != "":
		var reg := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		reg.store_string(registry_backup)
		reg.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	if v2 != "":
		TestVault.remove_tree(v2)
	TestVault.remove_tree(v3)

	check(sha_or_missing(real_display) == real_display_sha,
		"the real %s is untouched by the theme flips (%s, was %s)" % [real_display, sha_or_missing(real_display), real_display_sha])

	for f in [UiScale.file_override, JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	UiScale.file_override = ""
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
