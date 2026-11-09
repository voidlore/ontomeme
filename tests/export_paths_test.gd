extends SceneTree
## Export never deletes an earlier export, and paths don't rely on HOME
## (unset on Windows).
##   godot --headless --path . -s res://tests/export_paths_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const NoteScript = preload("res://note.gd")
var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_export_paths.json"   # never touch the real journey
	ProgressStore.file_override = "user://test_progress_export_paths.json"
	JourneyStore.reset()
	ProgressStore.reset()
	var dl: String = ProjectSettings.globalize_path("user://test-export-paths-downloads")
	var outside: String = ProjectSettings.globalize_path("user://test-export-paths-outside")
	var link_path: String = ProjectSettings.globalize_path("user://test-vault-export_paths/Linked")
	DirAccess.remove_absolute(link_path)   # unlink a link a crashed run left, before wiping the vault
	TestVault.remove_tree(dl)
	TestVault.remove_tree(outside)
	DirAccess.make_dir_recursive_absolute(dl)
	DirAccess.make_dir_recursive_absolute(outside)
	var vault: String = TestVault.open("export_paths", false)
	var linked: Error = DirAccess.open(vault).create_link(outside, vault.path_join("Linked"))
	var note: ContentLayer = VaultStore.create_note("Paths Note")
	note.raw_text = "exported twice"
	VaultStore.save_note(note)
	await frames(1)
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(3)

	# ── Export: Downloads comes from the OS, and an earlier export survives ──
	check(NoteScript.download_dir_override == "", "download_dir_override is empty by default")
	var sys_dl: String = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	check(app._get_download_path() == (sys_dl if sys_dl != "" else OS.get_user_data_dir()), "Downloads is the OS's Downloads folder (%s)" % app._get_download_path())
	NoteScript.download_dir_override = dl
	check(app._get_download_path() == dl, "download_dir_override points exports at a temp folder")
	var r1: Dictionary = app._on_export_vault_pressed(false)
	var first: String = str(r1.get("dest", ""))
	check(r1.get("ok", false) and DirAccess.dir_exists_absolute(first) and first.get_base_dir().simplify_path() == dl.simplify_path(), "the first export is a new folder in Downloads (%s)" % first)
	check(first.get_file().begins_with("test-vault-export_paths-export-" + Time.get_date_string_from_system()), "it is named <vault>-export-<date>")
	check(str(app.status_label.text).contains(first), "the status names the export folder")
	if linked == OK:
		check(str(app.status_label.text).ends_with("; left out a folder that links elsewhere: Linked"), "the status names the linked folder it left out (%s)" % app.status_label.text)
	else:
		print("SKIP  linked folder in the status (create_link failed: %d)" % linked)
	var mine: String = first.path_join("opened as a vault.txt")
	var f := FileAccess.open(mine, FileAccess.WRITE)
	f.store_string("the user's own file")
	f = null
	var r2: Dictionary = app._on_export_vault_pressed(false)
	var second: String = str(r2.get("dest", ""))
	check(r2.get("ok", false) and second != first and DirAccess.dir_exists_absolute(second), "a second export goes to a new folder (%s)" % second)
	check(DirAccess.dir_exists_absolute(first) and FileAccess.get_file_as_string(mine) == "the user's own file", "the first export and the file written into it survive")
	check(FileAccess.file_exists(first.path_join(note.resource_path.get_file())) and FileAccess.file_exists(second.path_join(note.resource_path.get_file())), "both exports hold the note")

	# ── The model dialog opens in Downloads, not the exe folder ──
	app._open_model_dialog()
	await frames(2)
	check(app._model_dialog != null and app._model_dialog.current_dir.simplify_path() == dl.simplify_path(), "the model import dialog opens in Downloads (%s)" % (app._model_dialog.current_dir if app._model_dialog else "none"))
	app._model_dialog.hide()

	# ── "~/" model paths: HOME, else USERPROFILE ──
	var home: String = OS.get_environment("HOME")
	var profile: String = OS.get_environment("USERPROFILE")
	var fake_profile: String = ProjectSettings.globalize_path("user://test-profile")
	OS.set_environment("HOME", "")
	OS.set_environment("USERPROFILE", fake_profile)
	var p: String = NoteScene3D.model_path("~/a.glb")
	check(p.simplify_path() == fake_profile.path_join("a.glb").simplify_path(), "with HOME unset, ~/a.glb is under USERPROFILE (%s)" % p)
	OS.set_environment("HOME", fake_profile.path_join("home"))
	check(NoteScene3D.model_path("~/a.glb") == fake_profile.path_join("home/a.glb"), "with HOME set, ~/a.glb is under HOME")
	OS.set_environment("HOME", home)
	if profile == "":
		OS.unset_environment("USERPROFILE")
	else:
		OS.set_environment("USERPROFILE", profile)
	check(OS.get_environment("HOME") == home and OS.get_environment("USERPROFILE") == profile, "HOME and USERPROFILE are restored")

	NoteScript.download_dir_override = ""
	DirAccess.remove_absolute(link_path)
	TestVault.remove_tree(dl)
	TestVault.remove_tree(outside)
	for s in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(s))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)
