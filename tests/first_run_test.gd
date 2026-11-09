extends SceneTree
## First run: a new default vault is seeded with the tutorials and the memetics
## course and the app opens on the tutorials; an existing vault is left alone;
## an uncreatable vault falls back with a readable message; and after the Mac
## "Don't Allow", README.md's ways back to Documents work, with or without an
## Ontomeme folder already there.
##   headless:  godot --headless --path . -s res://tests/first_run_test.gd
##   + images:  godot --path . -s res://tests/first_run_test.gd -- <out_dir>

const TestVault = preload("res://tests/test_vault.gd")
const StarterContent = preload("res://starter_content.gd")
const McpServe = preload("res://mcp/serve.gd")
const OWNER_RWX: int = FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_EXECUTE_OWNER

var fails: int = 0
var out: String = ""


## Records the "ERROR:" lines the engine logs while it is added
## (OS.add_logger), so the test can check that its EXPECT-ERROR text matches
## what this OS logs. Warnings are left out, as tests/run_all.sh leaves them.
class ErrorLog extends Logger:
	var messages: Array[String] = []

	func _log_error(_function: String, _file: String, _line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_ERROR:
			messages.append(rationale if rationale != "" else code)

	func _log_message(_message: String, _error: bool) -> void:
		pass


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## The Mac "Don't Allow" case, as README.md and the status bar tell it.
## macOS refusing the app Documents makes Documents/Ontomeme look missing
## (check_unreadable_parent): a launch keeps notes in `fallback` while
## Documents/Ontomeme stays the last vault, so each launch tries it again and
## the MCP server looks for it, not for the fallback. The status bar says so
## and, on a Mac, to move the notes before opening the app again: once access
## is allowed, the next launch makes a new, seeded Documents/Ontomeme without
## the notes written in the fallback, and says they are still in the
## fallback, which the vault menu opens. The MCP server serves whichever of
## them the app last opened. The README's way back (allow, quit, rename the
## fallback to Ontomeme and move it into Documents, with no launch in
## between) brings the next launch, and the server, to those notes. A test
## never touches the real Documents, so a folder chmod 000 stands in for it.
## Restores user://vaults.json.
func check_fallback_way_back(fallback: String) -> void:
	var documents: String = ProjectSettings.globalize_path("user://test-first-run-documents")
	var vault: String = documents.path_join(VaultRegistry.default_vault().get_file()) + "/"
	if DirAccess.dir_exists_absolute(documents):
		FileAccess.set_unix_permissions(documents, OWNER_RWX)   # a run that died midway left it locked
	TestVault.remove_tree(documents)
	TestVault.remove_tree(fallback)
	DirAccess.make_dir_recursive_absolute(documents)
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	FileAccess.set_unix_permissions(documents, 0)
	if DirAccess.open(documents) != null:
		print("SKIP  the Mac Don't Allow way back (chmod 000 doesn't stop this user, e.g. root)")
	else:
		# Don't Allow, then a launch as _ready does it (remember = true). On a
		# Mac the last vault and the default vault are both Documents/Ontomeme.
		var was_mac: bool = VaultStore._mac
		VaultStore._mac = true   # the warning a Mac shows, on any OS
		VaultStore.open_startup_vault(vault, vault, true, fallback)
		VaultStore._mac = was_mac
		VaultStore.create_note("Written after Don't Allow")
		var said: String = VaultStore.startup_warning
		check(VaultStore.vault_path == VaultRegistry.normalize(fallback) and said.contains("can't read"),
				"after Don't Allow the notes are kept in the fallback, with a warning (%s)" % VaultStore.vault_path)
		var kept: int = said.find("Notes are kept in %s for now." % fallback)
		var allow: int = said.find("quit Ontomeme, turn on System Settings › Privacy & Security › Files and Folders › Ontomeme › Documents Folder")
		var move_first: int = said.find("before you open Ontomeme again, rename %s to %s and move it into %s, unless a folder of that name is already there."
				% [VaultRegistry.display_name(fallback), vault.trim_suffix("/").get_file(), documents])
		check(kept >= 0 and allow > kept and move_first > allow,
				"…on a Mac it says where the notes are, then to allow Documents and move them there before Ontomeme opens again (%s)" % said)
		check(VaultRegistry._read().last == vault, "…Documents/%s stays the last vault, so each launch tries it again (%s)" % [vault.trim_suffix("/").get_file(), VaultRegistry._read().last])
		# The stand-in can't be seen, so a launch now looks at the next
		# candidate (VaultRegistry.startup_vault); on a Mac that is
		# Documents/Ontomeme again. Never created by a test, it is missing.
		var looks_at: String = VaultRegistry.startup_vault()
		var pick: Dictionary = McpServe.resolve_vault(PackedStringArray())
		var served: String = str(pick.get("path", ""))
		check(served != VaultRegistry.normalize(fallback)
				and (served == looks_at if DirAccess.dir_exists_absolute(looks_at) else pick.has("error")),
				"…the MCP server doesn't serve the fallback the app has open: it looks where a launch looks (%s) and finds no vault while there is none (%s)" % [looks_at, pick])

		# Access allowed, and Ontomeme opened before the notes were moved
		FileAccess.set_unix_permissions(documents, OWNER_RWX)
		VaultStore.open_startup_vault(vault, vault, true, fallback)
		check(VaultStore.vault_path == vault and VaultStore.first_run
				and VaultStore.get_note_index("Start Here: Tutorials") >= 0 and VaultStore.get_note_index("Written after Don't Allow") < 0,
				"once access is allowed the next launch makes a new %s with only the starter notes (%s, first run %s)" % [vault, VaultStore.vault_path, VaultStore.first_run])
		var fallback_name: String = VaultRegistry.display_name(fallback)
		var left: String = VaultStore.startup_warning
		check(left == "Notes kept in %s while Ontomeme couldn't reach this folder are still there, not in this new one: click the folder name at the top of the sidebar and choose %s to open them (%s)."
				% [fallback_name, fallback_name, fallback.trim_suffix("/")],
				"…and says the notes are still in the fallback, and how to open them (%s)" % left)
		var menu_at: int = VaultRegistry.recent().find(VaultRegistry.normalize(fallback))
		check(menu_at >= 0, "…which stays in the recent vaults (%s)" % [VaultRegistry.recent()])
		check(str(McpServe.resolve_vault(PackedStringArray()).get("path", "")) == vault,
				"…and the MCP server serves the new %s, without the notes in the fallback (%s)" % [vault, McpServe.resolve_vault(PackedStringArray())])
		# What the user sees: that warning in the status bar, not the welcome
		# (all of it on hover), and the vault menu's entry for the fallback.
		var app: Control = load("res://note.tscn").instantiate()
		get_root().add_child(app)
		await frames(4)
		check(app.status_label.text == left and app.status_label.tooltip_text == left
				and app.status_label.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS and app.status_label.mouse_filter != Control.MOUSE_FILTER_IGNORE,
				"…in the status bar, cut short with … and all of it on hover (%s)" % app.status_label.text)
		app._show_vault_menu()
		await frames(2)
		var item: int = app._vault_menu.get_item_index(menu_at)
		check(item >= 0 and app._vault_menu.get_item_text(item) == fallback_name, "…the folder name at the top of the sidebar lists %s (%s)" % [fallback_name, app._vault_menu.get_item_text(item) if item >= 0 else "-"])
		app._vault_menu.hide()
		app._on_vault_menu(menu_at)
		await frames(2)
		check(VaultStore.vault_path == VaultRegistry.normalize(fallback) and VaultStore.get_note_index("Written after Don't Allow") >= 0,
				"…and choosing it opens the notes written after Don't Allow (%s)" % VaultStore.vault_path)
		check(str(McpServe.resolve_vault(PackedStringArray()).get("path", "")) == VaultRegistry.normalize(fallback),
				"…after which the MCP server serves the fallback, the vault the app last opened (%s)" % [McpServe.resolve_vault(PackedStringArray())])
		app.queue_free()
		await frames(2)

		# Back to before that launch and that pick, then README steps 2-5
		TestVault.remove_tree(vault)
		VaultRegistry.remember(vault)
		DirAccess.rename_absolute(fallback.trim_suffix("/"), vault.trim_suffix("/"))
		check(VaultRegistry.startup_vault() == vault, "…moved there first, the next launch opens Documents/%s (%s)" % [vault.trim_suffix("/").get_file(), VaultRegistry.startup_vault()])
		VaultStore.open_startup_vault(VaultRegistry.startup_vault(), vault, true, fallback)
		check(not VaultStore.first_run and VaultStore.startup_warning == "", "…where the moved vault is not a first run and brings no warning")
		check(VaultStore.get_note_index("Written after Don't Allow") >= 0 and VaultStore.get_note_index("Start Here: Tutorials") >= 0, "…and has the notes written in the fallback")
		check(str(McpServe.resolve_vault(PackedStringArray()).get("path", "")) == vault, "…which the MCP server serves too (%s)" % [McpServe.resolve_vault(PackedStringArray())])
	FileAccess.set_unix_permissions(documents, OWNER_RWX)
	if registry_backup != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	TestVault.remove_tree(documents)
	TestVault.remove_tree(fallback)


## The Mac "Don't Allow" case when Documents/Ontomeme is already there: the
## user turns Documents Folder off, or macOS asks again after an update (the
## builds are unsigned) and they click Don't Allow. The app can't see the
## folder, so the Mac warning gives both ways back: move the fallback into
## Documents, or, when a folder of that name is there, never onto it but
## import from it. A fallback standing in for a vault the app has opened
## before gets no starter notes, which an import would bring back. Once
## access is allowed, a launch opens the user's vault, which lacks the notes
## written in the fallback: it says how many are still there and how to bring
## them in (↓ Import opens on the fallback), counting only notes written or
## changed since the fallback began standing in that the vault has no copy
## of. After the import, or once the user has opened the fallback, it says
## nothing more. A folder chmod 000 stands in for Documents. Restores
## user://vaults.json.
func check_dont_allow_existing_vault(fallback: String) -> void:
	var documents: String = ProjectSettings.globalize_path("user://test-first-run-documents-own")
	var vault: String = documents.path_join(VaultRegistry.default_vault().get_file()) + "/"
	var kept: String = fallback.trim_suffix("/")
	if DirAccess.dir_exists_absolute(documents):
		FileAccess.set_unix_permissions(documents, OWNER_RWX)   # a run that died midway left it locked
	TestVault.remove_tree(documents)
	TestVault.remove_tree(fallback)
	DirAccess.make_dir_recursive_absolute(documents)
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	# The user's vault, made by an earlier launch with access allowed; they
	# wrote a note, edited a tutorial and deleted another.
	VaultStore.open_startup_vault(vault, vault, true, fallback)
	VaultStore.create_note("Old note")
	var t1: ContentLayer = VaultStore.note_list[VaultStore.get_note_index("Tutorial 1: Writing Notes")]
	t1.raw_text += "\nMy own edit."
	VaultStore.save_note(t1)
	DirAccess.remove_absolute(VaultStore.note_list[VaultStore.get_note_index("Tutorial 7: Learning Objectives")].resource_path)
	VaultStore.refresh_note_list()
	var own: int = VaultStore.note_list.size()
	FileAccess.set_unix_permissions(documents, 0)
	if DirAccess.open(documents) != null:
		print("SKIP  Don't Allow with Documents/Ontomeme already there (chmod 000 doesn't stop this user, e.g. root)")
	else:
		var was_mac: bool = VaultStore._mac
		VaultStore._mac = true   # the warning a Mac shows, on any OS
		VaultStore.open_startup_vault(VaultStore.startup_path(), vault, true, fallback)
		VaultStore._mac = was_mac
		var said: String = VaultStore.startup_warning
		check(VaultStore.vault_path == VaultRegistry.normalize(fallback) and said.contains("can't read"),
				"Don't Allow with Documents/%s already there keeps notes in the fallback (%s)" % [vault.trim_suffix("/").get_file(), VaultStore.vault_path])
		var move: int = said.find("unless a folder of that name is already there.")
		var import: int = said.find("If one is, don't replace it: open Ontomeme and click ↓ Import at the bottom of the sidebar to bring them in from %s." % kept)
		check(move >= 0 and import > move, "…on a Mac it says what to do when a folder of that name is there: import from the fallback, never replace it (%s)" % said)
		check(VaultStore.note_list.is_empty() and not VaultStore.first_run,
				"…and a fallback standing in for a vault the app has opened gets no starter notes (%d notes)" % VaultStore.note_list.size())
		VaultStore.create_note("Written after Don't Allow")
		# Another launch, still refused: what this one writes counts too
		VaultStore.open_startup_vault(VaultStore.startup_path(), vault, true, fallback)
		var later: ContentLayer = VaultStore.create_note("Written on the next launch")
		later.raw_text = "Kept for later.\n"
		VaultStore.save_note(later)

		# Access allowed again: the next launch opens the user's vault
		FileAccess.set_unix_permissions(documents, OWNER_RWX)
		VaultStore.open_startup_vault(VaultStore.startup_path(), vault, true, fallback)
		check(VaultStore.vault_path == vault and not VaultStore.first_run and VaultStore.note_list.size() == own
				and VaultStore.get_note_index("Written after Don't Allow") < 0,
				"once access is allowed the next launch opens the user's %s, without the notes written in the fallback (%s, %d notes)" % [vault, VaultStore.vault_path, VaultStore.note_list.size()])
		var left: String = VaultStore.startup_warning
		var expected: String = "2 notes written in %s while Ontomeme couldn't reach this folder are still there, not here: click ↓ Import at the bottom of the sidebar and import %s to bring them in." % [
				VaultRegistry.display_name(fallback), kept]
		check(left == expected, "…and says how many are still in the fallback and how to bring them in (%s)" % left)
		check(VaultStore.kept_in_fallback == VaultRegistry.normalize(fallback), "…which ↓ Import opens on (%s)" % VaultStore.kept_in_fallback)
		var app: Control = load("res://note.tscn").instantiate()
		get_root().add_child(app)
		await frames(4)
		check(app.status_label.text == left and app.status_label.tooltip_text == left, "…in the status bar (%s)" % app.status_label.text)
		check(app.import_btn.is_visible_in_tree() and " ".join(app.import_btn.text.split(" ", false)) == "↓ Import",
				"…naming the sidebar's ↓ Import button (%s)" % app.import_btn.text)
		app._on_import_vault_pressed()
		await frames(2)
		check(VaultRegistry.normalize(app.import_dialog.current_dir) == VaultRegistry.normalize(fallback),
				"↓ Import opens on the fallback (%s)" % app.import_dialog.current_dir)
		app.import_dialog.hide()
		var r: Dictionary = app._on_import_dir_selected(app.import_dialog.current_dir)
		await frames(2)
		check(r.ok and r.notes == 2 and VaultStore.get_note_index("Written after Don't Allow") >= 0 and VaultStore.get_note_index("Written on the next launch") >= 0,
				"…and importing it brings in the notes written there (%s)" % [r])
		check(VaultStore.note_list.size() == own + 2 and VaultStore.get_note_index("Tutorial 7: Learning Objectives") < 0
				and VaultStore.get_note_index("Tutorial 1: Writing Notes (2)") < 0,
				"…and no starter note the user edited or deleted (%d notes)" % VaultStore.note_list.size())
		check(VaultStore.kept_in_fallback == "", "…after which ↓ Import opens where it used to (%s)" % VaultStore.kept_in_fallback)
		app.queue_free()
		await frames(2)
		VaultStore.open_startup_vault(VaultStore.startup_path(), vault, true, fallback)
		check(VaultStore.vault_path == vault and VaultStore.startup_warning == "" and VaultStore.kept_in_fallback == "",
				"…and the launch after the import says nothing more (%s)" % VaultStore.startup_warning)

		# Refused once more: the notes already brought in don't count again,
		# a new one does until the user opens the fallback.
		FileAccess.set_unix_permissions(documents, 0)
		VaultStore.open_startup_vault(VaultStore.startup_path(), vault, true, fallback)
		var third: ContentLayer = VaultStore.create_note("Written the third time")
		FileAccess.set_unix_permissions(documents, OWNER_RWX)
		check(VaultStore.vault_path == VaultRegistry.normalize(fallback) and third != null, "refused again, notes go to the fallback (%s)" % VaultStore.vault_path)
		VaultStore.open_startup_vault(VaultStore.startup_path(), vault, true, fallback)
		check(VaultStore.startup_warning == "1 note written in %s while Ontomeme couldn't reach this folder is still there, not here: click ↓ Import at the bottom of the sidebar and import %s to bring it in." % [
				VaultRegistry.display_name(fallback), kept],
				"…and the next launch counts only the note not brought in yet (%s)" % VaultStore.startup_warning)
		VaultStore.open_vault(fallback)   # as choosing it from the vault menu does
		check(VaultStore.get_note_index("Written the third time") >= 0, "…which choosing the fallback shows")
		VaultStore.open_startup_vault(vault, vault, true, fallback)
		check(VaultStore.vault_path == vault and VaultStore.startup_warning == "",
				"…after which a launch of the user's vault says nothing more (%s)" % VaultStore.startup_warning)
	FileAccess.set_unix_permissions(documents, OWNER_RWX)
	if registry_backup != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	TestVault.remove_tree(documents)
	TestVault.remove_tree(fallback)


## README.md says what check_fallback_way_back and
## check_dont_allow_existing_vault show: in its Mac section, and for Claude
## Desktop. Whitespace is folded so line wrapping doesn't matter.
func check_readme_dont_allow() -> void:
	var readme: String = FileAccess.get_file_as_string("res://README.md")
	var start: int = readme.find("\n### Mac\n")
	var stop: int = readme.find("\n### ", start + 1)
	var spaces: RegEx = RegEx.create_from_string("\\s+")
	var mac: String = spaces.sub(readme.substr(start, stop - start), " ", true)
	var mcp_at: int = readme.find("\n## Use with Claude Desktop (MCP)\n")
	var mcp: String = spaces.sub(readme.substr(mcp_at, readme.find("\n## ", mcp_at + 1) - mcp_at), " ", true)
	var folder: String = "vault"   # VaultStore.open_startup_vault's fallback_dir: <user data>/vault
	var vault_name: String = VaultRegistry.default_vault().get_file()
	check(FileAccess.get_file_as_string("res://vault_store.gd").contains('OS.get_user_data_dir().path_join("%s")' % folder), "the fallback vault is the folder '%s' in the user data folder" % folder)
	var data_dir: String = "~/Library/Application Support/Godot/app_userdata/%s" % ProjectSettings.get_setting("application/config/name")
	check(start >= 0 and mac.contains("**Don't Allow**") and mac.contains("folder called **%s**" % folder) and mac.contains("`%s`" % data_dir), "README.md (Mac): after Don't Allow the notes are in **%s** in %s" % [folder, data_dir])
	check(not mac.contains("keeps opening that folder") and mac.contains("Each time it opens, it tries **Documents** again: once you allow access, it makes a new **%s** folder there with only the starter notes, and the notes you wrote stay behind in **%s**." % [vault_name, folder]),
			"…each launch tries Documents again, and once access is allowed makes a new %s there without the notes in %s" % [vault_name, folder])
	check(mac.contains("in order, without opening Ontomeme in between:") and mac.contains("**Files & Folders** and turn on **Documents Folder**") and mac.contains("Quit Ontomeme.") and mac.contains("Rename the folder **%s** to **%s**, then drag it onto **Documents**" % [folder, vault_name]),
			"…and the way back, with no launch in between: allow Documents, quit, rename it to %s and move it into Documents" % vault_name)
	check(mac.contains("If Ontomeme already made a new **%s** folder in **Documents**, your notes are still in **%s**: click the folder name at the top of Ontomeme's sidebar and choose **%s**" % [vault_name, folder, folder]),
			"…and if a launch already made the new folder, how to open the notes in %s" % folder)
	check(mac.contains("If **Documents** already has an **%s** folder, don't replace it: see below." % vault_name)
			and mac.contains("Your **%s** folder may already be in **Documents** when your Mac refuses access: you turned off **Documents Folder** (see step 1), or your Mac asked again after an update and you clicked **Don't Allow**." % vault_name)
			and mac.contains("Ontomeme opens your **%s** folder without them. The bar at the bottom of its window then says how many are still in **%s**. Don't drag **%s** onto your **%s** folder, which would replace it." % [vault_name, folder, folder, vault_name])
			and mac.contains("click **↓ Import** at the bottom of its sidebar, and click **Import** in the window that opens on **%s**." % folder),
			"…and when Documents already has an %s folder (check_dont_allow_existing_vault): never replace it, import %s instead" % [vault_name, folder])
	check(mcp_at >= 0 and not mcp.contains("Claude finds no vault until")
			and mcp.contains("Claude works in the vault the app last opened, except the **%s** folder a Mac keeps your notes in after **Don't Allow** (see [Mac](#mac)): Claude keeps looking for the **%s** folder in **Documents**, as Ontomeme does each time it opens, and finds no vault while there is none." % [folder, vault_name])
			and mcp.contains("Once you choose **%s** at the top of Ontomeme's sidebar, it is the vault the app last opened, and Claude works there too." % folder),
			"README.md (Claude Desktop): after Don't Allow, Claude looks for Documents/%s, not %s, until %s is chosen in the vault menu" % [vault_name, folder, folder])


func _init() -> void:
	TestVault.hold()   # before any await, or the autoload opens the real vault
	JourneyStore.file_override = "user://test_journey_first_run.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_first_run.json"   # never touch real progress
	ProgressStore.reset()
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	DisplayServer.window_set_size(Vector2i(1280, 860))
	await frames(2)

	# Stands in for ~/Documents/Ontomeme, which a test must never create
	var fake_default: String = ProjectSettings.globalize_path("user://test-vault-first-run/")
	var fallback: String = ProjectSettings.globalize_path("user://test-vault-first-run-fallback/")
	TestVault.remove_tree(fake_default)
	TestVault.remove_tree(fallback)

	check(StarterContent.is_first_run(fake_default, fake_default), "missing default vault = first run")
	check(not StarterContent.is_first_run(fake_default, fake_default + "other/"), "another vault is never a first run")

	# First launch: create and seed
	VaultStore.open_startup_vault(fake_default, fake_default, false)
	var n: int = VaultStore.note_list.size()
	check(VaultStore.first_run and VaultStore.startup_warning == "", "first launch is a first run, no warning")
	check(VaultStore.get_note_index("Start Here: Tutorials") >= 0 and VaultStore.get_note_index("Tutorial 7: Learning Objectives") >= 0, "tutorials are seeded")
	check(VaultStore.get_note_index("History of Memetics") >= 0 and VaultStore.get_note_index("The Memetics Debate") >= 0, "memetics course is seeded")
	check(VaultStore.get_note_index("Nodes and Scenes") >= 0 and VaultStore.get_note_index("Quiz: Godot Fundamentals") >= 0, "Godot Fundamentals course is seeded")
	check(VaultStore.get_note_index("Quiz: Ontomeme") < 0, "the app-internals quiz (test-only) is not shipped")
	check(VaultStore.folders.has("Tutorials") and VaultStore.folders.has("Memetics") and VaultStore.folders.has("Godot"), "filed in Tutorials, Godot and Memetics folders (%s)" % [VaultStore.folders])
	check(VaultStore.folder_of(VaultStore.note_list[VaultStore.get_note_index("Signals")]) == "Godot", "Godot lessons are in the Godot folder")
	var godot_order: Array = VaultStore.note_list.filter(func(n): return VaultStore.folder_of(n) == "Godot").map(func(n): return n.title)
	check(godot_order == ["Nodes and Scenes", "Signals", "Shaders", "Containers and Layout", "Quiz: Godot Fundamentals"], "Godot lessons are listed in teaching order (%s)" % [godot_order])
	check(VaultStore.folder_of(VaultStore.note_list[VaultStore.get_note_index("History of Memetics")]) == "Memetics", "memetics lessons are in the Memetics folder")
	check(FileAccess.file_exists(fake_default.path_join("models/rocket.glb")), "sample rocket.glb is written")
	check(not JourneyStore.topics().is_empty(), "the Learning Journey has a starter topic")

	# Seeding goes through save_note, so editing a seeded note is not a conflict
	var t1: ContentLayer = VaultStore.note_list[VaultStore.get_note_index("Tutorial 1: Writing Notes")]
	t1.raw_text += "\nMy first edit."
	VaultStore.save_note(t1)
	check(VaultStore.last_conflict_copy == null, "editing a seeded tutorial right after first run is not a conflict")

	# The app opens on the tutorials
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(6)
	check(app.current_note != null and app.current_note.title == "Start Here: Tutorials", "first run opens Start Here: Tutorials (%s)" % (app.current_note.title if app.current_note else "none"))
	check(LayerEngine.current_mode == "visual", "…in the Read view (%s)" % LayerEngine.current_mode)
	check(app._collapsed.has("Godot") and app._collapsed.has("Memetics") and not app._collapsed.has("Tutorials"), "the courses start folded, Tutorials open")
	check(app.status_label.text.begins_with("Welcome"), "status bar welcomes the user (%s)" % app.status_label.text)
	if out != "" and DisplayServer.get_name() != "headless":
		await create_timer(1.5).timeout
		get_root().get_texture().get_image().save_png(out.path_join("first_run.png"))
		print("saved first_run")
	app._execute_command("about")
	await frames(2)
	var about: AcceptDialog = null
	for c in app.get_children():
		if c is AcceptDialog and c.title == "About Ontomeme":
			about = c
	check(about != null and about.dialog_text.contains(VaultStore.vault_path), "About shows the version and the notes folder")
	app.queue_free()
	await frames(2)

	# Second launch: the vault exists, nothing is re-seeded
	VaultStore.open_startup_vault(fake_default, fake_default, false)
	check(not VaultStore.first_run and VaultStore.note_list.size() == n, "second launch is not a first run and adds nothing (%d notes)" % VaultStore.note_list.size())

	# A seeded vault the user emptied stays empty (the marker remembers)
	check(FileAccess.file_exists(fake_default.path_join(StarterContent.MARKER)), "seeding leaves a marker")

	# An earlier launch made the folder but was interrupted: still a first run
	TestVault.remove_tree(fake_default)
	DirAccess.make_dir_recursive_absolute(fake_default.path_join(".ontomeme"))
	check(StarterContent.is_first_run(fake_default, fake_default), "an empty, never-seeded default vault is a first run")
	VaultStore.open_startup_vault(fake_default, fake_default, false)
	check(VaultStore.first_run and VaultStore.get_note_index("Start Here: Tutorials") >= 0, "…and gets seeded")
	for nt in VaultStore.note_list.duplicate():
		DirAccess.remove_absolute(nt.resource_path)
	check(not StarterContent.is_first_run(fake_default, fake_default), "a seeded vault the user emptied is not re-seeded")

	# Palette: add the starter content to any vault
	var other: String = TestVault.open("first-run-other", false)
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app._execute_command("add_starter")
	await frames(4)
	check(VaultStore.get_note_index("Start Here: Tutorials") >= 0 and VaultStore.get_note_index("History of Memetics") >= 0, "\"Add the tutorials and starter course\" fills an empty vault")
	check(app.current_note != null and app.current_note.title == "Start Here: Tutorials", "…and opens Start Here")
	app.queue_free()
	await frames(2)
	TestVault.remove_tree(other)

	# A vault folder that cannot be created falls back, and says so. A file
	# stands where its parent folder should be, so on every OS each folder
	# above it exists and the one the engine can't create, and names in its
	# error, is the vault itself. (Under a missing root folder such as /proc on
	# macOS, the error names that root instead.)
	var blocker: String = ProjectSettings.globalize_path("user://test-first-run-blocker")
	var uncreatable: String = blocker.path_join("Ontomeme")
	FileAccess.open(blocker, FileAccess.WRITE).store_string("a file, not a folder\n")
	var expected := "Could not create directory: '%s'" % uncreatable
	print("EXPECT-ERROR: " + expected)   # for tests/run_all.sh
	var errors := ErrorLog.new()
	OS.add_logger(errors)
	VaultStore.open_startup_vault(uncreatable + "/", uncreatable + "/", false, fallback)
	OS.remove_logger(errors)
	check(not errors.messages.is_empty() and errors.messages.all(func(m: String) -> bool: return m.contains(expected)),
			"the engine logs only the error the test expects (%s)" % [errors.messages])
	check(VaultStore.vault_path == VaultRegistry.normalize(fallback), "uncreatable vault falls back (%s)" % VaultStore.vault_path)
	check(VaultStore.startup_warning.contains("Couldn't create"), "…with a readable warning")
	check(VaultStore.first_run and VaultStore.get_note_index("Start Here: Tutorials") >= 0, "…and the fallback vault is seeded")

	if OS.get_name() == "Windows":
		print("SKIP  unreadable vault folder (chmod has no effect on Windows)")
	else:
		await check_unreadable_vault(fallback)
		check_unreadable_parent(fallback)
		check_unreadable_parent_own_vault(fallback)
		await check_fallback_way_back(fallback)
		await check_dont_allow_existing_vault(fallback)

	check_readme_dont_allow()

	TestVault.remove_tree(fake_default)
	TestVault.remove_tree(fallback)
	DirAccess.remove_absolute(blocker)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


## A vault folder that exists but can't be listed (macOS refused the app
## access to Documents, or chmod 000) is not an empty first run: nothing is
## seeded into it, the user is told, and notes are kept in `fallback`.
func check_unreadable_vault(fallback: String) -> void:
	var parent: String = ProjectSettings.globalize_path("user://test-first-run-locked")
	var locked: String = parent.path_join("Ontomeme") + "/"
	if DirAccess.dir_exists_absolute(locked):
		FileAccess.set_unix_permissions(locked, OWNER_RWX)   # a run that died midway left it locked
	TestVault.remove_tree(parent)
	TestVault.remove_tree(fallback)
	DirAccess.make_dir_recursive_absolute(locked)
	var mine := ContentLayer.new()
	mine.title = "Mine"
	mine.raw_text = "My own note.\n"
	var note_path: String = locked.path_join("note_mine.tres")
	ResourceSaver.save(mine, note_path)
	var before: String = FileAccess.get_sha256(note_path)
	# A real launch remembers vaults in user://vaults.json; keep the user's.
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	FileAccess.set_unix_permissions(locked, 0)
	var was_locked: bool = DirAccess.open(locked) == null
	if not was_locked:
		print("SKIP  unreadable vault folder (chmod 000 doesn't stop this user, e.g. root)")
	else:
		check(not StarterContent.is_first_run(locked, locked), "a vault folder that can't be read is not a first run")
		VaultStore.open_startup_vault(locked, locked, false, fallback)
		check(VaultStore.startup_warning.contains("can't read"), "…the startup warning says it can't read it (%s)" % VaultStore.startup_warning)
		check(VaultStore.vault_path == VaultRegistry.normalize(fallback), "…and notes are kept in the fallback (%s)" % VaultStore.vault_path)
		var app: Control = load("res://note.tscn").instantiate()
		get_root().add_child(app)
		await frames(4)
		check(app.status_label.text.contains("can't read") and not app.status_label.text.begins_with("Welcome"),
				"the status bar shows the warning, not the welcome (%s)" % app.status_label.text)
		var shown: Rect2 = app.status_label.get_global_rect()
		check(app.status_label.clip_text and shown.end.x <= get_root().size.x, "…clipped inside the window (%s)" % shown)
		app.queue_free()
		await frames(2)

		# As _ready does it (remember = true): the fallback must not become
		# the last vault, or the launch after the user grants access would
		# open it without a word and their notes would stay hidden.
		VaultStore.open_startup_vault(locked, locked, true, fallback)
		check(VaultStore.vault_path == VaultRegistry.normalize(fallback) and VaultRegistry.startup_vault() == locked,
				"a real launch keeps the unreadable folder as the vault to open next (%s)" % VaultRegistry.startup_vault())
		var recent: Array[String] = VaultRegistry.recent()
		check(recent.size() >= 2 and recent[0] == locked and recent[1] == VaultRegistry.normalize(fallback),
				"…and lists the fallback among the recent vaults, after it (%s)" % [recent])
		VaultStore.open_startup_vault(VaultRegistry.startup_vault(), locked, true, fallback)
		check(VaultStore.startup_warning.contains("can't read") and VaultStore.vault_path == VaultRegistry.normalize(fallback),
				"the next launch, still locked, tries it again and warns again (%s)" % VaultStore.startup_warning)
	FileAccess.set_unix_permissions(locked, OWNER_RWX)
	check(FileAccess.get_sha256(note_path) == before and _entries(locked) == ["note_mine.tres"],
			"…and nothing in the unreadable folder changed (%s)" % [_entries(locked)])
	if was_locked:
		# The user granted access: the next launch opens their own notes.
		VaultStore.open_startup_vault(VaultRegistry.startup_vault(), locked, true, fallback)
		check(VaultStore.vault_path == locked and VaultStore.startup_warning == "" and not VaultStore.first_run
				and VaultStore.get_note_index("Mine") >= 0,
				"once access is granted the next launch opens the user's folder, with their notes (%s, %s)" % [VaultStore.vault_path, VaultStore.startup_warning])
	if registry_backup != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	TestVault.remove_tree(parent)
	TestVault.remove_tree(fallback)


## The folder the vault is in can't be listed (how macOS refusing the app
## access to Documents shows up): the vault inside can't even be seen, so it
## looks missing. That is the can't-read case, not "couldn't create": nothing
## is created there, the user's folder stays the vault to open next, and the
## warning says which folder can't be opened.
func check_unreadable_parent(fallback: String) -> void:
	var parent: String = ProjectSettings.globalize_path("user://test-first-run-locked-parent")
	var vault: String = parent.path_join("Ontomeme") + "/"
	if DirAccess.dir_exists_absolute(parent):
		FileAccess.set_unix_permissions(parent, OWNER_RWX)   # a run that died midway left it locked
	TestVault.remove_tree(parent)
	TestVault.remove_tree(fallback)
	DirAccess.make_dir_recursive_absolute(vault)
	var mine := ContentLayer.new()
	mine.title = "Mine"
	mine.raw_text = "My own note.\n"
	var note_path: String = vault.path_join("note_mine.tres")
	ResourceSaver.save(mine, note_path)
	var before: String = FileAccess.get_sha256(note_path)
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	FileAccess.set_unix_permissions(parent, 0)
	var was_locked: bool = DirAccess.open(parent) == null
	if not was_locked:
		print("SKIP  vault in an unreadable folder (chmod 000 doesn't stop this user, e.g. root)")
	else:
		check(not DirAccess.dir_exists_absolute(vault), "a vault inside a folder that can't be listed looks missing")
		# As _ready does it, without --vault (remember = true).
		var errors := ErrorLog.new()
		OS.add_logger(errors)
		VaultStore.open_startup_vault(vault, vault, true, fallback)
		OS.remove_logger(errors)
		check(errors.messages.is_empty(), "…nothing tries to create it there (%s)" % [errors.messages])
		check(VaultStore.startup_warning.contains("can't read") and VaultStore.startup_warning.contains(parent)
				and not VaultStore.startup_warning.contains("Couldn't create"),
				"…the warning says it can't read it and names the folder that can't be opened (%s)" % VaultStore.startup_warning)
		check(VaultStore.vault_path == VaultRegistry.normalize(fallback), "…notes are kept in the fallback (%s)" % VaultStore.vault_path)
		check(VaultRegistry._read().last == vault, "…and the user's folder stays the last vault (%s)" % VaultRegistry._read().last)
		check(VaultRegistry.recent().has(VaultRegistry.normalize(fallback)), "…the fallback joins the recent vaults (%s)" % [VaultRegistry.recent()])
		var deeper: String = parent.path_join("Notes/Ontomeme") + "/"
		VaultStore.open_startup_vault(deeper, vault, false, fallback)
		check(VaultStore.startup_warning.contains("can't read") and VaultStore.startup_warning.contains(parent),
				"a vault further down in that folder is the same case (%s)" % VaultStore.startup_warning)
	FileAccess.set_unix_permissions(parent, OWNER_RWX)
	check(FileAccess.get_sha256(note_path) == before and _entries(parent) == ["Ontomeme"] and _entries(vault) == ["note_mine.tres"],
			"…and nothing in the unreadable folder changed (%s, %s)" % [_entries(parent), _entries(vault)])
	if was_locked:
		# The user granted access: the next launch opens their own notes.
		check(VaultRegistry.startup_vault() == vault, "once access is granted the user's folder is the startup vault (%s)" % VaultRegistry.startup_vault())
		VaultStore.open_startup_vault(VaultRegistry.startup_vault(), vault, true, fallback)
		check(VaultStore.vault_path == vault and VaultStore.startup_warning == "" and not VaultStore.first_run
				and VaultStore.get_note_index("Mine") >= 0,
				"…and the next launch opens it, with their notes (%s, %s)" % [VaultStore.vault_path, VaultStore.startup_warning])
	if registry_backup != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	TestVault.remove_tree(parent)
	TestVault.remove_tree(fallback)


## The same with the user's own vault, not the default one (~/Documents/MyNotes
## in a denied ~/Documents), and the vault chosen as _ready chooses it
## (VaultStore.startup_path, no --vault). VaultRegistry.startup_vault() alone
## takes a last vault it can't see for gone and picks the default vault: the
## fallback then remembered that as last and named it in the warning, and
## once access was granted the next launch seeded the default vault while
## the user's notes stayed hidden.
func check_unreadable_parent_own_vault(fallback: String) -> void:
	var parent: String = ProjectSettings.globalize_path("user://test-first-run-locked-own")
	var vault: String = parent.path_join("MyNotes") + "/"
	if DirAccess.dir_exists_absolute(parent):
		FileAccess.set_unix_permissions(parent, OWNER_RWX)   # a run that died midway left it locked
	TestVault.remove_tree(parent)
	TestVault.remove_tree(fallback)
	DirAccess.make_dir_recursive_absolute(vault)
	var mine := ContentLayer.new()
	mine.title = "Mine"
	mine.raw_text = "My own note.\n"
	ResourceSaver.save(mine, vault.path_join("note_mine.tres"))
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	VaultRegistry.remember(vault)   # the vault the user last opened
	var default_existed: bool = DirAccess.dir_exists_absolute(VaultRegistry.default_vault())
	FileAccess.set_unix_permissions(parent, 0)
	var was_locked: bool = DirAccess.open(parent) == null
	if not was_locked:
		print("SKIP  own vault in an unreadable folder (chmod 000 doesn't stop this user, e.g. root)")
	else:
		var path: String = VaultStore.startup_path()
		check(path == vault, "a launch still picks the user's last vault inside a folder that can't be listed (%s)" % path)
		if path == vault:   # never the real default vault, which no test may create
			VaultStore.open_startup_vault(path, VaultRegistry.default_vault(), true, fallback)
			check(VaultStore.vault_path == VaultRegistry.normalize(fallback) and VaultStore.startup_warning.contains("can't read your notes folder at " + vault),
					"…falls back and the warning names the user's folder (%s)" % VaultStore.startup_warning)
			check(VaultRegistry._read().last == vault, "…which stays the last vault (%s)" % VaultRegistry._read().last)
		check(DirAccess.dir_exists_absolute(VaultRegistry.default_vault()) == default_existed, "…and the default vault is not created")
	FileAccess.set_unix_permissions(parent, OWNER_RWX)
	if was_locked:
		# The user granted access: the next launch opens their own notes.
		var path: String = VaultStore.startup_path()
		check(path == vault, "once access is granted the user's folder is the startup vault (%s)" % path)
		if path == vault:
			VaultStore.open_startup_vault(path, VaultRegistry.default_vault(), true, fallback)
			check(VaultStore.vault_path == vault and VaultStore.startup_warning == "" and not VaultStore.first_run
					and VaultStore.get_note_index("Mine") >= 0,
					"…and the next launch opens it, with their notes (%s, %s)" % [VaultStore.vault_path, VaultStore.startup_warning])
	if registry_backup != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry_backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	TestVault.remove_tree(parent)
	TestVault.remove_tree(fallback)


## Every file and folder directly in `dir`, hidden ones too.
func _entries(dir: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.include_hidden = true
	out.append_array(d.get_directories())
	out.append_array(d.get_files())
	return out
