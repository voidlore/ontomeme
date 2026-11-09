extends SceneTree
## Diagnostics for bug reports: one "[Ontomeme] " line in godot.log at
## startup (version, OS, the vault and what came up in it, where the data and
## the log live, scale, renderer), About → Copy diagnostics, the log path in
## the About box, the palette's "Open log folder", and the bug-report
## template and the README's "Reporting a problem" that send users to them
## and to godot.log.
##   headless:  godot --headless --path . -s res://tests/diagnostics_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const Note = preload("res://note.gd")
const PREFIX: String = "[Ontomeme] "
const BUG_TEMPLATE: String = "res://.github/ISSUE_TEMPLATE/bug_report.md"
const README: String = "res://README.md"

var fails: int = 0


## Collects what the app prints, so the test can count the startup line.
class PrintCatcher extends Logger:
	var lines: PackedStringArray = []
	var _mutex := Mutex.new()

	func _log_message(message: String, _error: bool) -> void:
		_mutex.lock()
		lines.append(message)
		_mutex.unlock()

	func starting_with(prefix: String) -> PackedStringArray:
		_mutex.lock()
		var hits: PackedStringArray = []
		for l in lines:
			if l.begins_with(prefix):
				hits.append(l)
		_mutex.unlock()
		return hits


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


## Where the bug-report template tells a user to find godot.log on each OS,
## built from the app's name and log path (Godot's default user dir: "godot"
## under ~/.local/share on Linux, "Godot" on macOS and Windows).
func template_log_paths() -> Dictionary:
	var log_rel: String = str(ProjectSettings.get_setting("debug/file_logging/log_path")).trim_prefix("user://")
	var rel: String = "app_userdata/%s/%s" % [ProjectSettings.get_setting("application/config/name"), log_rel]
	return {
		"Linux": "~/.local/share/godot/" + rel,
		"macOS": "~/Library/Application Support/Godot/" + rel,
		"Windows": "%APPDATA%\\Godot\\" + rel.replace("/", "\\"),
	}


## The log path a user's desktop gets, where XDG_DATA_HOME is unset
## (run_all.sh and sandboxes set it). Godot reads it on every call.
func default_log_path() -> String:
	var had: bool = OS.has_environment("XDG_DATA_HOME")
	var saved: String = OS.get_environment("XDG_DATA_HOME")
	OS.unset_environment("XDG_DATA_HOME")
	var path: String = Note.log_path()
	if had:
		OS.set_environment("XDG_DATA_HOME", saved)
	return path


## A template path with ~ or %APPDATA% filled in for this computer.
func expand_home(path: String) -> String:
	if path.begins_with("~/"):
		return OS.get_environment("HOME") + path.substr(1)
	return path.replace("%APPDATA%", OS.get_environment("APPDATA")).replace("\\", "/")


## The bug-report template names the app's own words and its real log paths.
func check_bug_template() -> void:
	var text: String = FileAccess.get_file_as_string(BUG_TEMPLATE)
	check(text.begins_with("---\nname: Bug report\n") and text.contains("\nlabels: bug\n"), "the bug-report template has its front matter (%s)" % BUG_TEMPLATE)
	for words in ["About Ontomeme", "Copy diagnostics", "Open log folder", "Paste Copy diagnostics here"]:
		check(text.contains(words), "…it says '%s', as the app does" % words)
	check(ProjectSettings.get_setting_with_override("debug/file_logging/enable_file_logging"), "file logging is on on desktop, so godot.log exists to attach")
	var paths: Dictionary = template_log_paths()
	for os_name in paths:
		check(text.contains(paths[os_name]), "…it gives the %s log path %s" % [os_name, paths[os_name]])
	var here: String = OS.get_name()
	if paths.has(here):
		var actual: String = default_log_path()
		print("log path with XDG_DATA_HOME unset: " + actual)
		check(actual == expand_home(paths[here]), "…and on this %s the log is there (%s)" % [here, actual])


## The README's "Reporting a problem" sends users to the same places as the
## template: Copy diagnostics, Open log folder and the three log paths. They
## hold only while project.godot keeps Godot's default user dir.
func check_readme() -> void:
	var text: String = FileAccess.get_file_as_string(README)
	check(text.contains("\n## Reporting a problem\n"), "README.md has a 'Reporting a problem' section")
	for words in ["About Ontomeme", "Copy diagnostics", "Open log folder"]:
		check(text.contains(words), "…it says '%s', as the app does" % words)
	var paths: Dictionary = template_log_paths()
	for os_name in paths:
		check(text.contains(paths[os_name]), "…it gives the %s log path %s" % [os_name, paths[os_name]])
	check(not ProjectSettings.get_setting("application/config/use_custom_user_dir", false), "project.godot sets no custom user dir, so the log is under Godot/app_userdata/%s" % ProjectSettings.get_setting("application/config/name"))


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_diagnostics.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_diagnostics.json"   # never touch real progress
	ProgressStore.reset()
	# Before the first await: while the test waits, the VaultStore autoload
	# opens the startup vault (the user's real one) unless a vault is open.
	var vault: String = TestVault.open("diagnostics")
	await frames(2)
	check(VaultStore.vault_path.begins_with(ProjectSettings.globalize_path("user://test-vault-")), "after the first frames a test vault is still open, not the startup vault (%s)" % VaultStore.vault_path)

	# The line itself
	var diag: String = Note.diagnostics()
	print("diagnostics: " + diag)
	check(diag.contains(Note.app_version()), "diagnostics names the version (%s)" % Note.app_version())
	check(diag.contains("vault=" + VaultStore.vault_path) and VaultStore.vault_path == vault, "…the vault path")
	check(diag.contains("vault_exists=true"), "…that the vault exists")
	check(VaultStore.note_list.size() > 0 and diag.contains("notes=%d " % VaultStore.note_list.size()), "…the note count, notes=%d" % VaultStore.note_list.size())
	check(diag.contains("folders=%d " % VaultStore.folders.size()), "…the folder count, folders=%d" % VaultStore.folders.size())
	check(diag.contains("first_run=%s " % VaultStore.first_run), "…first_run=%s" % VaultStore.first_run)
	check(diag.contains("warning=none "), "…and that there was no startup warning")
	check(diag.contains("os=" + OS.get_name()) and diag.contains("locale=" + OS.get_locale()), "…the OS and locale")
	check(diag.contains("user_data=" + OS.get_user_data_dir()) and diag.contains("log=" + Note.log_path()), "…where the app data and the log live")
	check(Note.log_path() == ProjectSettings.globalize_path("user://logs/godot.log") and Note.log_dir() == ProjectSettings.globalize_path("user://logs"), "the log is user://logs/godot.log (%s)" % Note.log_path())
	check(diag.contains("screen_scale=") and diag.contains("zoom=") and diag.contains("renderer=" + RenderingServer.get_current_rendering_driver_name()), "…the scale, zoom and renderer")
	check(not diag.contains("\n"), "diagnostics is one line, so godot.log holds it whole")

	VaultStore.startup_warning = "Couldn't create your notes folder at /x, so notes are kept in /y instead."
	check(Note.diagnostics().contains("warning=" + VaultStore.startup_warning), "a startup warning is in the line")
	VaultStore.startup_warning = ""

	# Startup prints it once, with the prefix, so it lands in godot.log
	var catcher := PrintCatcher.new()
	OS.add_logger(catcher)
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(6)
	OS.remove_logger(catcher)
	var lines: PackedStringArray = catcher.starting_with(PREFIX)
	check(lines.size() == 1, "starting the app prints exactly one '%s' line (%d)" % [PREFIX, lines.size()])
	check(lines.size() == 1 and lines[0].strip_edges() == PREFIX + Note.diagnostics(), "…and it is the diagnostics line")

	# The palette offers "Open log folder" (not run here: it would open a
	# file manager on the developer's desktop)
	app._open_palette()
	await frames(1)
	var labels: Array = app._palette_items.map(func(it: Dictionary) -> String: return str(it.label))
	var open_log: Array = app._palette_items.filter(func(it: Dictionary) -> bool: return str(it.label).ends_with("Open log folder"))
	check(open_log.size() == 1 and open_log[0].action == "open_log", "the palette lists 'Open log folder' once (%s)" % [labels.filter(func(l: String) -> bool: return l.contains("log"))])
	app._palette_search.text = "log folder"
	app._on_palette_search_changed("log folder")
	check(app._palette_items.size() >= 1 and str(app._palette_items[0].label).ends_with("Open log folder"), "…and typing 'log folder' finds it")
	app._close_palette()

	# About: the log path, and Copy diagnostics, clicked with real input
	app._execute_command("about")
	await frames(3)
	var about: AcceptDialog = app.get_node_or_null("AboutDialog")
	check(about != null and about.visible, "the About box opens")
	if about != null:
		check(about.dialog_text.contains(VaultStore.vault_path) and about.dialog_text.contains(Note.log_path()), "About shows the notes folder and the log path")
		var copy: Button = find_named(about, "CopyDiagnosticsButton")
		check(copy != null and copy.text == "Copy diagnostics" and copy.is_visible_in_tree(), "About has a 'Copy diagnostics' button")
		check(about.size.x <= get_root().size.x, "the About box fits the minimum window (%d <= %d)" % [about.size.x, get_root().size.x])
		if copy != null:
			await click(copy)
			check(copy.text == "Copied", "clicking it copies the diagnostics (button says '%s')" % copy.text)
			check(app.status_label.text.begins_with("Copied diagnostics"), "…and the status bar says so (%s)" % app.status_label.text)
			if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
				check(DisplayServer.clipboard_get() == Note.diagnostics(), "…onto the clipboard")
		check(about.visible, "…and the About box stays open")

	app.queue_free()
	await frames(2)
	TestVault.remove_tree(vault)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""

	check_bug_template()
	check_readme()
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
