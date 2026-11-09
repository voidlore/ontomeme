extends SceneTree
## Earlier builds on Linux without xdg-user-dir kept the default vault at the
## relative path "Ontomeme/": inside the folder the app ran from, mostly the
## release folder it was extracted to, and user://vaults.json says
## "Ontomeme/". After an update extracted to a new folder, a launch finds
## that vault again (VaultStore.open_launch_vault), stores it as an absolute
## path, opens it, and warns not to delete the old folder; it warns too when
## it can't find it. Restores user://vaults.json.
##   headless:  godot --headless --path . -s res://tests/relative_vault_test.gd

const TestVault = preload("res://tests/test_vault.gd")

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func stored() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(VaultRegistry.FILE))


func store(d: Dictionary) -> void:
	var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "\t"))
	f.close()


## What an earlier build left: last and recent "Ontomeme/".
func store_relative() -> void:
	store({"recent": ["Ontomeme/"], "last": "Ontomeme/"})


func has_relative(d: Dictionary) -> bool:
	return str(d.last).is_relative_path() or (d.recent as Array).any(func(p): return str(p).is_relative_path())


## A release folder: the program, and (with a note) the vault an earlier
## build made beside it.
func release(folder: String, note: String = "") -> String:
	DirAccess.make_dir_recursive_absolute(folder)
	FileAccess.open(folder.path_join("Ontomeme.x86_64"), FileAccess.WRITE).store_string("program")
	var vault: String = folder.path_join("Ontomeme/")
	if note != "":
		DirAccess.make_dir_recursive_absolute(vault)
		VaultStore.open_vault(vault, false)
		VaultStore.create_note(note)
	return vault


func _init() -> void:
	TestVault.hold()   # no await here, but the autoload must never open the real vault
	var registry_backup: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	var tmp: String = ProjectSettings.globalize_path("user://test-relative-vault")
	TestVault.remove_tree(tmp)
	var downloads: String = tmp.path_join("Downloads")
	var rc1: String = downloads.path_join("Ontomeme-0.1.0-rc1-linux")
	var update: String = downloads.path_join("Ontomeme-0.1.0-linux")
	var default: String = VaultRegistry.normalize(VaultRegistry.default_vault())
	var default_existed: bool = DirAccess.dir_exists_absolute(default)   # tests/run_all.sh: never

	# The issue's case: the new version extracted beside the old one and run
	# from its own folder.
	var old: String = VaultRegistry.normalize(release(rc1, "Written in rc1"))
	release(update)
	store_relative()
	VaultStore.open_launch_vault(update, [downloads] as Array[String])
	check(VaultStore.vault_path == old and VaultStore.get_note_index("Written in rc1") >= 0,
			"an update in a new folder opens the old vault beside the old program, with its notes (%s)" % VaultStore.vault_path)
	check(not VaultStore.first_run and DirAccess.dir_exists_absolute(default) == default_existed, "…not a new seeded vault in Documents")
	check(stored().last == old and not has_relative(stored()), "…and remembers it as an absolute path (%s)" % JSON.stringify(stored()))
	check(VaultStore.startup_warning.begins_with("Don't delete %s: your notes are in its Ontomeme folder" % rc1),
			"…and warns not to delete the old folder (%s)" % VaultStore.startup_warning)
	VaultStore.startup_warning = ""
	VaultStore.open_launch_vault(update, [downloads] as Array[String])
	check(VaultStore.vault_path == old and VaultStore.startup_warning.begins_with("Don't delete " + rc1),
			"the next launch opens it again and warns again (%s)" % VaultStore.startup_warning)

	# What the warning says to do: move it somewhere safe and open it there.
	var safe: String = VaultRegistry.normalize(tmp.path_join("Safe/Ontomeme"))
	DirAccess.make_dir_recursive_absolute(tmp.path_join("Safe"))
	check(DirAccess.rename_absolute(old, safe) == OK, "(moved the vault out of the old folder)")
	VaultStore.open_vault(safe)   # Open folder as vault…
	VaultStore.open_launch_vault(update, [downloads] as Array[String])
	check(VaultStore.vault_path == safe and VaultStore.startup_warning == "" and VaultStore.get_note_index("Written in rc1") >= 0,
			"once moved and opened, a launch opens it with no warning (%s, '%s')" % [VaultStore.vault_path, VaultStore.startup_warning])

	# The new version run from the old folder (extracted over it): the vault
	# is found where it is, but stays relative no more.
	TestVault.remove_tree(tmp)
	old = VaultRegistry.normalize(release(rc1, "Written in rc1"))
	store_relative()
	VaultStore.open_launch_vault(rc1, [] as Array[String])
	check(VaultStore.vault_path == old and stored().last == old and not has_relative(stored()),
			"run from the old folder, it opens the vault there and remembers it as an absolute path (%s)" % JSON.stringify(stored()))
	check(VaultStore.startup_warning.begins_with("Don't delete " + rc1), "…and warns the same way (%s)" % VaultStore.startup_warning)

	# Run from a folder without the program (a terminal in the home folder):
	# no update deletes it, so no warning.
	TestVault.remove_tree(tmp)
	var home: String = tmp.path_join("home")
	var at_home: String = VaultRegistry.normalize(home.path_join("Ontomeme"))
	DirAccess.make_dir_recursive_absolute(at_home)
	store_relative()
	VaultStore.open_launch_vault(home, [] as Array[String])
	check(VaultStore.vault_path == at_home and stored().last == at_home and VaultStore.startup_warning == "",
			"a relative vault in a folder without the program is remembered as absolute, with no warning (%s, '%s')" % [VaultStore.vault_path, VaultStore.startup_warning])

	# Two old release folders, each with a vault (rc1 updated to rc2 the
	# same way): both are kept, the newer one opens, both are named.
	TestVault.remove_tree(tmp)
	var rc2: String = downloads.path_join("Ontomeme-0.1.0-rc2-linux")
	old = VaultRegistry.normalize(release(rc1, "Written in rc1"))
	OS.delay_msec(1100)   # folder times are per second
	var newer: String = VaultRegistry.normalize(release(rc2, "Written in rc2"))
	release(update)
	store_relative()
	VaultStore.open_launch_vault(update, [downloads] as Array[String])
	check(VaultStore.vault_path == newer and VaultRegistry.recent() == ([newer, old] as Array[String]),
			"with two old vaults the newer opens and both are in the recent list (%s)" % [VaultRegistry.recent()])
	check(VaultStore.startup_warning.contains("Don't delete " + rc1) and VaultStore.startup_warning.contains("Don't delete " + rc2),
			"…and the warning names both old folders (%s)" % VaultStore.startup_warning)

	# The update is a Linux AppImage: one file the user keeps where they like
	# (README.md: an Applications folder), run from a temporary mount
	# (/tmp/.mount_*/usr/bin) and started from anywhere. The old release
	# folder in Downloads is found all the same (VaultStore.release_parents).
	TestVault.remove_tree(tmp)
	old = VaultRegistry.normalize(release(rc1, "Written in rc1"))
	var home_dir: String = tmp.path_join("home")
	var apps: String = home_dir.path_join("Applications")
	DirAccess.make_dir_recursive_absolute(apps)
	var appimage: String = apps.path_join("Ontomeme-0.1.0-linux-x86_64.AppImage")
	FileAccess.open(appimage, FileAccess.WRITE).store_string("program")
	var mount_exe: String = "/tmp/.mount_OntomeAbC123/usr/bin/Ontomeme"
	check(not VaultStore.release_parents(mount_exe, home_dir).has(downloads),
			"(without the AppImage's own folders, the program's and the working folder's parents miss Downloads)")
	store_relative()
	VaultStore.startup_warning = ""
	VaultStore.open_launch_vault(home_dir, VaultStore.release_parents(mount_exe, home_dir, appimage, [downloads] as Array[String]))
	check(VaultStore.vault_path == old and VaultStore.get_note_index("Written in rc1") >= 0 and not VaultStore.first_run,
			"an AppImage in Applications, started from the home folder, opens the old vault in Downloads (%s)" % VaultStore.vault_path)
	check(stored().last == old and not has_relative(stored()) and VaultStore.startup_warning.begins_with("Don't delete " + rc1),
			"…remembers it as an absolute path and warns not to delete the old folder (%s, '%s')" % [JSON.stringify(stored()), VaultStore.startup_warning])
	var in_downloads: String = downloads.path_join("Ontomeme-0.1.0-linux-x86_64.AppImage")
	FileAccess.open(in_downloads, FileAccess.WRITE).store_string("program")
	store_relative()
	VaultStore.open_launch_vault(downloads, VaultStore.release_parents(mount_exe, downloads, in_downloads))
	check(VaultStore.vault_path == old and stored().last == old,
			"an AppImage left in Downloads and started there finds it beside itself, with no Downloads folder known (%s)" % VaultStore.vault_path)

	# The old folder is somewhere this version doesn't look. Opening the
	# default vault is left out: a test never creates it.
	TestVault.remove_tree(tmp)
	old = VaultRegistry.normalize(release(tmp.path_join("elsewhere/Ontomeme-0.1.0-rc1-linux"), "Written in rc1"))
	release(update)
	store_relative()
	var lost: String = VaultStore.adopt_relative_vaults(update, [downloads] as Array[String])
	check(lost.begins_with("Don't delete the folder of the Ontomeme you used before: your notes are in a folder named Ontomeme inside it"),
			"an old vault it can't find gets a warning (%s)" % lost)
	check(VaultRegistry.startup_vault() == default and stored().last == "Ontomeme/",
			"…the launch opens Documents, and the entry stays, so the next launch warns again (%s)" % JSON.stringify(stored()))
	VaultStore.open_vault(old)   # Open folder as vault…, as the warning says
	lost = VaultStore.adopt_relative_vaults(update, [downloads] as Array[String])
	check(lost == "" and stored().last == old and not has_relative(stored()),
			"once opened by hand, that vault stands for the old entry: no more warning (%s)" % JSON.stringify(stored()))
	check(VaultStore.program_folder_warning().begins_with("Don't delete " + old.trim_suffix("/").get_base_dir()),
			"…and the warning to move it out of the old folder takes over (%s)" % VaultStore.program_folder_warning())

	check(DirAccess.dir_exists_absolute(default) == default_existed, "no step created the default vault")
	VaultStore.startup_warning = ""
	TestVault.remove_tree(tmp)
	if registry_backup == "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	else:
		FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE).store_string(registry_backup)
	TestVault.remove_tree(ProjectSettings.globalize_path("user://test-vault-hold/"))
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
