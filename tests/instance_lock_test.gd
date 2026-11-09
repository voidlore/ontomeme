extends SceneTree
## One window per vault: the app's window holds <vault>/.ontomeme/app.lock
## (its PID, when it took the vault, a heartbeat every 10 s) and removes it
## when it closes. Opening a vault another live window holds asks first
## (Quit or Open anyway at startup, Cancel or Open anyway for a switch); a
## lock a crash left (its process gone, or its heartbeat 30 s old) is taken
## over without asking. The MCP server never touches it (mcp_test checks).
##   headless:  godot --headless --path . -s res://tests/instance_lock_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultLock = preload("res://vault_lock.gd")
const OTHER: String = "another-window"   # the instance mark of a lock this test writes

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func lock_file(vault: String) -> String:
	return vault.path_join(".ontomeme/app.lock")


func read_lock(vault: String) -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(lock_file(vault)))
	return v if v is Dictionary else {}


## Write a lock the way another window of the app would: process `pid`, its
## heartbeat `age` seconds old.
func write_lock(vault: String, pid: int, age: int) -> void:
	var now: int = int(Time.get_unix_time_from_system())
	DirAccess.make_dir_recursive_absolute(vault.path_join(".ontomeme"))
	var f := FileAccess.open(lock_file(vault), FileAccess.WRITE)
	f.store_string(JSON.stringify({"pid": pid, "instance": OTHER, "started": now - age - 60, "heartbeat": now - age}))
	f.close()


## True when the lock on `vault` is this process's own, with a fresh heartbeat.
func ours(vault: String) -> bool:
	var lock: Dictionary = read_lock(vault)
	var age: float = Time.get_unix_time_from_system() - float(lock.get("heartbeat", 0))
	return int(lock.get("pid", 0)) == OS.get_process_id() and str(lock.get("instance", OTHER)) != OTHER and age < 5.0


## The PID of a process that ran and exited: no process has it now.
func dead_pid() -> int:
	var pid: int = OS.create_process(OS.get_executable_path(), ["--headless", "--version"])
	var deadline: int = Time.get_ticks_msec() + 10000
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	return pid


## Click `ctrl` inside the dialog window `win` with real mouse events.
func click_in(win: Window, ctrl: Control) -> void:
	var pos: Vector2 = Vector2(win.position) + ctrl.get_global_rect().get_center()
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	await process_frame
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	await frames(3)


func start_app() -> Control:
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	return app


## Close the window the way the user does: the close request (the app saves
## what is pending), then the window goes (quit frees the tree).
func close_app(app: Control) -> void:
	get_root().propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	app.queue_free()
	await frames(2)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_lock.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_lock.json"   # never touch real progress
	ProgressStore.reset()
	var registry: String = FileAccess.get_file_as_string(VaultRegistry.FILE) if FileAccess.file_exists(VaultRegistry.FILE) else ""   # switch_vault remembers vaults
	var V: String = TestVault.open("lock", false)
	var W: String = ProjectSettings.globalize_path("user://test-vault-lock-2/")
	TestVault.remove_tree(W)
	DirAccess.make_dir_recursive_absolute(W)
	await frames(2)

	await store_checks(V)
	await app_checks(V, W)

	TestVault.remove_tree(W)
	# Restore the vault list; an empty file would make every later
	# VaultRegistry read log a JSON parse ERROR.
	if registry != "":
		var f := FileAccess.open(VaultRegistry.FILE, FileAccess.WRITE)
		f.store_string(registry)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VaultRegistry.FILE))
	for p in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)


# ── VaultStore: who holds a vault ──────────────────────────────────────────

func store_checks(V: String) -> void:
	var me: int = OS.get_process_id()
	var dead: int = await dead_pid()
	check(VaultLock.process_alive(me), "process_alive: this process")
	check(not VaultLock.process_alive(dead), "process_alive: a process that exited (%d)" % dead)
	if OS.get_name() != "Windows":
		var sleeper: int = OS.create_process("sleep", ["30"])
		check(VaultLock.process_alive(sleeper), "process_alive: another live process (%d)" % sleeper)
		OS.kill(sleeper)
	# Windows asks tasklist; CI runs Linux, so read its answer here, as
	# OS.execute hands it over (one String in an Array, CSV, CRLF)
	var row: Array = ["\"ontomeme.exe\",\"4321\",\"Console\",\"1\",\"50,000 K\"\r\n"]
	check(VaultLock.tasklist_lists(row, 4321), "tasklist: the CSV row of process 4321 means it runs")
	check(not VaultLock.tasklist_lists(row, 432) and not VaultLock.tasklist_lists(row, 1), "…and is no answer for a PID that is only part of a column (432, 1)")
	check(not VaultLock.tasklist_lists(["INFO: No tasks are running which match the specified criteria.\r\n"], 4321), "…while tasklist's no-match line means it's gone")

	write_lock(V, me, 0)
	var before: String = FileAccess.get_file_as_string(lock_file(V))
	var holder: Dictionary = VaultLock.vault_lock_holder(V)
	check(not holder.is_empty() and int(holder.get("pid", 0)) == me, "a lock with a live PID (this test's) and a fresh heartbeat: the vault is in use")
	check(FileAccess.get_file_as_string(lock_file(V)) == before, "…and asking changes nothing")

	write_lock(V, dead, 0)
	check(VaultLock.vault_lock_holder(V).is_empty(), "a lock whose process is gone is stale")
	VaultLock.hold_vault_lock(V)
	check(ours(V), "…and is taken over")
	write_lock(V, me, 60)
	check(VaultLock.vault_lock_holder(V).is_empty(), "a lock with a 60 s old heartbeat is stale, though its PID lives")
	VaultLock.hold_vault_lock(V)
	check(ours(V) and VaultLock.vault_lock_holder(V).is_empty(), "…taken over too; this window's own lock is never \"in use\"")

	var lock: Dictionary = read_lock(V)
	lock.heartbeat = int(lock.heartbeat) - 20
	var f := FileAccess.open(lock_file(V), FileAccess.WRITE)
	f.store_string(JSON.stringify(lock))
	f.close()
	VaultLock.refresh_vault_lock()
	check(ours(V) and int(read_lock(V).started) == int(lock.started), "the heartbeat refreshes its own lock, keeping the start time")
	write_lock(V, me, 0)
	VaultLock.refresh_vault_lock()
	check(read_lock(V).get("instance") == OTHER, "…and leaves alone a lock another live window took (Open anyway there)")
	VaultLock.release_vault_lock()
	check(read_lock(V).get("instance") == OTHER, "releasing never removes another window's lock")
	VaultLock.hold_vault_lock(V)
	VaultLock.release_vault_lock()
	check(not FileAccess.file_exists(lock_file(V)), "releasing removes this window's own lock")
	VaultLock.refresh_vault_lock()
	check(not FileAccess.file_exists(lock_file(V)), "…and no heartbeat writes it again")


# ── The window: ask, take over, let go ─────────────────────────────────────

func app_checks(V: String, W: String) -> void:
	var me: int = OS.get_process_id()
	write_lock(V, me, 0)
	var before: String = FileAccess.get_file_as_string(lock_file(V))
	var app: Control = await start_app()
	var dlg: ConfirmationDialog = app._in_use_dialog
	check(dlg != null and dlg.visible and dlg.dialog_text.contains("Ontomeme already has this vault open in another window"), "opening a vault another live window holds asks first")
	check(dlg != null and dlg.get_ok_button().text == "Open anyway" and dlg.get_cancel_button().text == "Quit", "…with Quit and Open anyway")
	check(FileAccess.get_file_as_string(lock_file(V)) == before, "…and leaves the other window's lock as it is")
	if dlg != null:
		await click_in(dlg, dlg.get_ok_button())
	check(ours(V) and not is_instance_valid(app._in_use_dialog), "Open anyway takes the lock")
	check(app._lock_timer != null and not app._lock_timer.is_stopped() and is_equal_approx(app._lock_timer.wait_time, VaultLock.LOCK_HEARTBEAT_SEC), "a heartbeat timer runs every %d s" % int(VaultLock.LOCK_HEARTBEAT_SEC))
	await close_app(app)
	check(not FileAccess.file_exists(lock_file(V)), "the lock file is gone after the window closes")

	write_lock(V, await dead_pid(), 0)
	app = await start_app()
	check(app._in_use_dialog == null and ours(V), "a lock left by a process that is gone is taken over without asking")
	await close_app(app)
	write_lock(V, me, 60)
	app = await start_app()
	check(app._in_use_dialog == null and ours(V), "so is one whose heartbeat is 60 s old")

	# Switching to a vault another window holds
	write_lock(W, me, 0)
	app.switch_vault(W)
	await frames(2)
	dlg = app._in_use_dialog
	check(dlg != null and dlg.visible and dlg.get_cancel_button().text == "Cancel", "switching to a vault another window holds asks: Cancel or Open anyway")
	if dlg != null:
		await click_in(dlg, dlg.get_cancel_button())
	check(app._in_use_dialog == null and app.status_label.text.begins_with("Stayed in"), "Cancel closes the question (%s)" % app.status_label.text)
	check(VaultStore.vault_path == V and ours(V) and read_lock(W).get("instance") == OTHER, "…and stays in the vault, which keeps its lock")
	app.switch_vault(W)
	await frames(2)
	dlg = app._in_use_dialog
	if dlg != null:
		await click_in(dlg, dlg.get_ok_button())
	check(VaultStore.vault_path == W and ours(W) and not FileAccess.file_exists(lock_file(V)), "Open anyway switches: the new vault's lock is ours, the old one's is gone")
	app.switch_vault(V)
	await frames(2)
	check(app._in_use_dialog == null and VaultStore.vault_path == V and ours(V) and not FileAccess.file_exists(lock_file(W)), "a free vault switches without asking, and the lock moves with it")
	await close_app(app)
	check(not FileAccess.file_exists(lock_file(V)) and not FileAccess.file_exists(lock_file(W)), "closing leaves no lock in either vault")
