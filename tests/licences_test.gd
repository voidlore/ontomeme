extends SceneTree
## About → Licences: the notices that must ship with the app (Ontomeme's MIT
## licence, the fonts' SIL OFL, the Godot Engine's licence and third-party
## notices) are in licences_text(), and a real click on the About box's
## Licences button opens them in a dialog that fits the minimum window.
##   headless:  godot --headless --path . -s res://tests/licences_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const Licences = preload("res://licences.gd")
const MAX_WIDTH: float = 820.0   # the headless window is the 820×520 minimum

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func click(c: Control) -> void:
	var pos: Vector2 = c.get_global_rect().get_center()
	if c.get_viewport() is Window and (c.get_viewport() as Window).is_embedded():
		pos += Vector2((c.get_viewport() as Window).position)
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


## Dialog buttons are internal children, which find_child does not see.
func find_named(root: Node, node_name: String) -> Node:
	for c in root.get_children(true):
		if c.name == node_name:
			return c
		var hit: Node = find_named(c, node_name)
		if hit != null:
			return hit
	return null


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_licences.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_licences.json"   # never touch real progress
	ProgressStore.reset()
	# Before the first await: while the test waits, the VaultStore autoload
	# opens the startup vault (the user's real one) unless a vault is open.
	var vault: String = TestVault.open("licences")
	await frames(2)
	check(VaultStore.vault_path.begins_with(ProjectSettings.globalize_path("user://test-vault-")), "after the first frames a test vault is still open, not the startup vault (%s)" % VaultStore.vault_path)

	# The text
	check(Licences.ONTOMEME_LICENSE == FileAccess.get_file_as_string("res://LICENSE"), "the MIT text in licences.gd matches LICENSE (no drift)")
	var text: String = Licences.licences_text()
	for needle in ["MIT License", "Joseph Sailor Usher", "SIL OPEN FONT LICENSE", "Godot Engine"]:
		check(text.contains(needle), "the licences text contains '%s'" % needle)
	check(text.contains("Copyright 2016 The Inter Project Authors") and text.contains("Renzhi Li"), "…with the fonts' copyright lines from fonts/OFL.txt")
	check(text.contains(Engine.get_license_text().strip_edges()), "…the Godot Engine licence")
	var components: Array = Engine.get_copyright_info()
	var last: Dictionary = components[-1]
	check(components.size() > 1 and text.contains(str(last.name)) and text.contains(str(last.parts[0].copyright[0])), "…every engine component with its copyright lines (%d components)" % components.size())
	check(text.contains("Apache License") and Engine.get_license_info().has("Apache-2.0"), "…and the full texts of those components' licences")

	# The About box and its Licences button, clicked with real input events
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(6)
	app._execute_command("about")
	await frames(3)
	var about: AcceptDialog = app.get_node_or_null("AboutDialog")
	check(about != null and about.visible, "the palette's About command opens the About box")
	var btn: Button = find_named(about, "LicencesButton") if about != null else null
	check(btn != null and btn.text == "Licences" and btn.is_visible_in_tree(), "the About box has a Licences button")
	if btn != null:
		await click(btn)
	await frames(3)
	var dlg: AcceptDialog = about.get_node_or_null("LicencesDialog") if about != null else null
	check(dlg != null and dlg.visible, "clicking Licences opens the Licences dialog")
	if dlg != null:
		var box: TextEdit = dlg.get_node_or_null("LicencesText")
		check(box != null and box.text == text and not box.editable, "…holding the licences text, read-only")
		check(dlg.get_contents_minimum_size().x <= MAX_WIDTH and dlg.size.x <= MAX_WIDTH, "…and fits the minimum window (min %.0f, size %d <= %d)" % [dlg.get_contents_minimum_size().x, dlg.size.x, MAX_WIDTH])
		check(dlg.size.y <= get_root().size.y, "…in height too (%d <= %d)" % [dlg.size.y, get_root().size.y])
		await click(dlg.get_ok_button())
		await frames(2)
		check(not is_instance_valid(dlg) or not dlg.visible, "Close shuts the Licences dialog")
	check(is_instance_valid(about) and about.visible, "…and leaves the About box open")

	app.queue_free()
	await frames(2)
	TestVault.remove_tree(vault)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
