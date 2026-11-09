extends SceneTree
## The startup log: each launch says which vault was chosen and why, whether
## the starter notes were seeded, and what went wrong; the log is rotated;
## and it never prints, so --mcp-stdio's stdout stays protocol-only.
##   headless:  godot --headless --path . -s res://tests/startup_log_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const StartupLog = preload("res://startup_log.gd")

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func log_text() -> String:
	return FileAccess.get_file_as_string(StartupLog.FILE) if FileAccess.file_exists(StartupLog.FILE) else ""


func clear_log() -> void:
	for f in [StartupLog.FILE, StartupLog.BACKUP]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))


func _init() -> void:
	TestVault.hold()
	JourneyStore.file_override = "user://test-startup-log-journey.json"
	ProgressStore.file_override = "user://test-startup-log-progress.json"
	var kept_log: String = log_text()
	var kept_registry: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""
	clear_log()
	var vault: String = ProjectSettings.globalize_path("user://test-startup-log-vault")
	var fallback: String = ProjectSettings.globalize_path("user://test-startup-log-fallback")
	var blocker: String = ProjectSettings.globalize_path("user://test-startup-log-blocker")
	for d in [vault, fallback]:
		TestVault.remove_tree(d)

	# An empty vault: a first run seeds it.
	VaultStore.open_startup_vault(vault, vault, false, fallback)
	VaultStore.log_startup(vault, "default")
	var t: String = log_text()
	check(t.contains("launch: Ontomeme"), "a launch is logged")
	check(t.contains("vault chosen: %s (why: default)" % vault), "the log names the vault chosen and why")
	check(t.contains("starter seed: ran; marker present"), "an empty vault logs the seed and its marker")
	check(not t.contains("notes: 0"), "the seeded notes are counted")
	check(not t.contains("fell back"), "no fallback is claimed")

	# The same vault again: already seeded.
	clear_log()
	VaultStore.open_startup_vault(vault, vault, false, fallback)
	VaultStore.log_startup(vault, "default")
	t = log_text()
	check(t.contains("starter seed: skipped (not a first run); marker present"), "a seeded vault logs the seed as skipped")

	# Why a vault was chosen.
	VaultRegistry.remember(vault)
	check(VaultStore.launch_reason(vault) == "remembered", "the last vault is 'remembered'")
	check(VaultStore.launch_reason(fallback) == "default", "any other vault is 'default'")

	# A vault that can't be created: the fallback and the warning are logged.
	clear_log()
	var b: FileAccess = FileAccess.open(blocker, FileAccess.WRITE)
	b.store_string("a file where a folder is wanted")
	b.close()
	var uncreatable: String = blocker.path_join("Ontomeme") + "/"
	print("EXPECT-ERROR: Could not create directory")
	VaultStore.open_startup_vault(uncreatable, uncreatable, false, fallback)
	VaultStore.log_startup(uncreatable, "default")
	t = log_text()
	check(t.contains("fell back to the app data folder"), "a fallback is logged")
	check(t.contains("  warning: Couldn't create"), "the warning is logged")

	# Rotation at about 1 MB, keeping one old log.
	clear_log()
	var big: FileAccess = FileAccess.open(StartupLog.FILE, FileAccess.WRITE)
	big.store_string("x".repeat(StartupLog.MAX_BYTES))
	big.close()
	StartupLog.append(["after rotation"])
	check(FileAccess.file_exists(StartupLog.BACKUP), "a full log is moved aside")
	check(log_text() == "after rotation\n", "the new log starts empty")

	var source: String = FileAccess.get_file_as_string("res://startup_log.gd")
	check(not source.contains("print"), "the log never prints: stdout stays protocol-only")

	clear_log()
	if kept_log != "":
		StartupLog.append([kept_log.trim_suffix("\n")])
	if kept_registry != "":
		var r: FileAccess = FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		r.store_string(kept_registry)
		r.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	for d in [vault, fallback]:
		TestVault.remove_tree(d)
	DirAccess.remove_absolute(blocker)
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	TestVault.remove_tree(ProjectSettings.globalize_path("user://test-vault-hold/"))
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
