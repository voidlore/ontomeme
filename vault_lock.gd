extends RefCounted
## One window per vault: <vault>/.ontomeme/app.lock
##
## Only the app's window loads this (note.gd preloads it): it runs a program
## (`kill -0`, `tasklist`) to tell whether another window's process still
## lives, and nothing an MCP server loads may (tests/mcp_boot_test.gd).
##   const VaultLock = preload("res://vault_lock.gd")

## The app's window that has a vault open says so in <vault>/.ontomeme/app.lock,
## JSON {pid, instance, started, heartbeat} (unix seconds), so a second window
## opened on the same vault (another double-click, the Dock and a shortcut)
## can warn instead of autosaving over the first one's notes, where every
## edit in one would become a conflict copy in the other. note.gd takes it
## (hold_vault_lock), refreshes the heartbeat every LOCK_HEARTBEAT_SEC
## (refresh_vault_lock) and removes it when the window goes
## (release_vault_lock). The MCP server, a second writer by design, never
## reads or writes it.
const LOCK_FILE: String = "app.lock"
const LOCK_HEARTBEAT_SEC: float = 10.0
## A lock whose heartbeat is this old, or whose process is gone, was left by
## a crash or a kill: it is taken over without asking.
const LOCK_STALE_SEC: int = 30

## This process's mark in the locks it writes (_instance_mark), so its own
## lock never reads as another window's (a vault left and opened again).
static var _lock_instance: String = ""
## The vault whose lock this window holds ("" when none), and since when.
static var _lock_vault: String = ""
static var _lock_started: int = 0


## <vault>/.ontomeme/app.lock
static func lock_path(vault: String) -> String:
	return VaultRegistry.normalize(vault).path_join(".ontomeme").path_join(LOCK_FILE)


## The lock another live window of the app holds on `vault`: its fields
## {pid, instance, started, heartbeat}, or {} when there is none, it is this
## window's own, or it is stale (its process is gone, or its heartbeat is
## LOCK_STALE_SEC old). Writes nothing.
static func vault_lock_holder(vault: String) -> Dictionary:
	if _serving_mcp():
		return {}
	var lock: Dictionary = _read_lock(vault)
	if lock.is_empty() or str(lock.get("instance", "")) == _instance_mark():
		return {}
	var age: float = Time.get_unix_time_from_system() - float(lock.get("heartbeat", 0))
	if absf(age) >= LOCK_STALE_SEC or not process_alive(int(lock.get("pid", 0))):
		return {}
	return lock


## Write this window's lock on `vault` (the open one by default), over any
## other (the caller asked or found it stale), and let go of the lock it
## held on another vault. Returns the write's error.
static func hold_vault_lock(vault: String = "") -> Error:
	if _serving_mcp():
		return OK
	vault = VaultRegistry.normalize(vault if vault != "" else VaultStore.vault_path)
	if _lock_vault != "" and _lock_vault != vault:
		release_vault_lock()
	if _lock_vault != vault:
		_lock_vault = vault
		_lock_started = int(Time.get_unix_time_from_system())
	return _write_lock()


## The heartbeat (note.gd's timer): write this window's lock again with the
## time now. Left alone while another live window holds the vault (it chose
## "Open anyway" there); ours goes back once that one lets go.
static func refresh_vault_lock() -> void:
	if _lock_vault == "" or _serving_mcp() or not vault_lock_holder(_lock_vault).is_empty():
		return
	_write_lock()


## Remove this window's lock (the window closes, or opens another vault),
## never another window's.
static func release_vault_lock() -> void:
	if _lock_vault == "":
		return
	if str(_read_lock(_lock_vault).get("instance", "")) == _instance_mark():
		DirAccess.remove_absolute(lock_path(_lock_vault))
	_lock_vault = ""


## True when process `pid` runs on this machine. OS.is_process_running knows
## only the app's own child processes (and logs an error for any other), so
## Linux looks in /proc, Windows asks tasklist, macOS and the BSDs `kill -0`.
## When none can say, true: the heartbeat's age alone decides then.
static func process_alive(pid: int) -> bool:
	if pid <= 0:
		return false
	if pid == OS.get_process_id():
		return true
	if DirAccess.dir_exists_absolute("/proc/self"):
		return DirAccess.dir_exists_absolute("/proc/%d" % pid)
	var out: Array = []
	if OS.get_name() == "Windows":
		if OS.execute("tasklist", ["/FI", "PID eq %d" % pid, "/NH", "/FO", "CSV"], out) != 0:
			return true
		return tasklist_lists(out, pid)
	return OS.execute("kill", ["-0", str(pid)], out) == 0


## True when `out`, the output OS.execute collected from
## `tasklist /FI "PID eq <pid>" /NH /FO CSV`, lists process `pid`: a CSV row
## ("ontomeme.exe","1234","Console","1",…) whose second column is `pid`.
## Read as the text itself: str() of the Array quotes and escapes each line,
## so its PID never matched and every other window's lock looked stale.
static func tasklist_lists(out: Array, pid: int) -> bool:
	for line in "".join(out).split("\n", false):
		var cols: PackedStringArray = line.strip_edges().split("\",\"")
		if cols.size() > 1 and cols[1] == str(pid):
			return true
	return false


static func _instance_mark() -> String:
	if _lock_instance == "":
		_lock_instance = "%d-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec(), randi()]
	return _lock_instance


## The lock file on `vault`, parsed; {} when missing or unreadable.
static func _read_lock(vault: String) -> Dictionary:
	var path: String = lock_path(vault)
	if not FileAccess.file_exists(path):
		return {}
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Dictionary else {}


## Write this window's lock on _lock_vault, heartbeat now. Atomic, so another
## window never reads half of it.
static func _write_lock() -> Error:
	var now: int = int(Time.get_unix_time_from_system())
	var lock: Dictionary = {"pid": OS.get_process_id(), "instance": _instance_mark(), "started": _lock_started, "heartbeat": now}
	DirAccess.make_dir_recursive_absolute(lock_path(_lock_vault).get_base_dir())
	return VaultStore.atomic_write_text(JSON.stringify(lock, "\t"), lock_path(_lock_vault), _lock_vault)


## True in a process serving MCP (`-- --mcp-stdio`): it never reads or writes
## the lock, whatever calls this.
static func _serving_mcp() -> bool:
	return OS.get_cmdline_user_args().has("--mcp-stdio")
