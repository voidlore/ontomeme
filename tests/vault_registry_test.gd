extends SceneTree
## VaultRegistry: the default vault is an absolute folder in Documents, even
## on Linux without xdg-user-dir on PATH, where Godot finds no Documents
## folder. A relative "Ontomeme/" would sit beside whichever folder the app
## ran from: the new version of an update, extracted to a new folder, would
## start an empty vault, and deleting the old folder would delete the notes.
##   headless:  godot --headless --path . -s res://tests/vault_registry_test.gd

const TestVault = preload("res://tests/test_vault.gd")

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func _init() -> void:
	TestVault.hold()   # no await here, but the autoload must never open the real vault

	var vault: String = VaultRegistry.normalize(VaultRegistry.default_vault())
	check(vault.is_absolute_path() and vault.trim_suffix("/").get_file() == "Ontomeme", "the default vault is an absolute Ontomeme folder (%s)" % vault)

	if OS.has_feature("linuxbsd"):
		# An empty folder as PATH: Godot can't run xdg-user-dir, as on a
		# minimal or window-manager-only install.
		var tmp: String = ProjectSettings.globalize_path("user://test-registry-xdg")
		TestVault.remove_tree(tmp)
		DirAccess.make_dir_recursive_absolute(tmp.path_join("bin"))
		DirAccess.make_dir_recursive_absolute(tmp.path_join("config"))
		var home: String = OS.get_environment("HOME")
		var saved: Dictionary = {}
		for k in ["PATH", "XDG_CONFIG_HOME"]:
			saved[k] = OS.get_environment(k)
		OS.set_environment("PATH", tmp.path_join("bin"))
		OS.set_environment("XDG_CONFIG_HOME", tmp.path_join("config"))
		var dirs: String = tmp.path_join("config/user-dirs.dirs")

		vault = VaultRegistry.default_vault()
		check(vault == home.path_join("Documents/Ontomeme"), "without xdg-user-dir or user-dirs.dirs the vault is ~/Documents/Ontomeme (%s)" % vault)
		check(VaultRegistry.normalize(vault).is_absolute_path(), "…an absolute path, not one beside the executable (%s)" % VaultRegistry.normalize(vault))

		var f := FileAccess.open(dirs, FileAccess.WRITE)
		f.store_string("# written by xdg-user-dirs-update\nXDG_DESKTOP_DIR=\"$HOME/Desktop\"\nXDG_DOCUMENTS_DIR=\"$HOME/Papers\"\n")
		f.close()
		vault = VaultRegistry.default_vault()
		check(vault == home.path_join("Papers/Ontomeme"), "…user-dirs.dirs names Documents as xdg-user-dir would: $HOME/Papers (%s)" % vault)

		f = FileAccess.open(dirs, FileAccess.WRITE)
		f.store_string("XDG_DOCUMENTS_DIR=\"%s\"\n" % tmp.path_join("docs"))
		f.close()
		vault = VaultRegistry.default_vault()
		check(vault == tmp.path_join("docs/Ontomeme"), "…or an absolute folder (%s)" % vault)

		for k in saved:
			OS.set_environment(k, saved[k])
		TestVault.remove_tree(tmp)

	TestVault.remove_tree(ProjectSettings.globalize_path("user://test-vault-hold/"))
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
