extends RefCounted
## A few plain lines per launch in user://logs/ontomeme.log: which vault was
## chosen and why, whether the starter notes were seeded, and anything that
## went wrong. It answers "why did my vault come up empty?" from a file a user
## can send (palette: Open log folder). It only ever writes to the file:
## --mcp-stdio's stdout must stay protocol-only.

const FILE: String = "user://logs/ontomeme.log"
const BACKUP: String = FILE + ".1"
const MAX_BYTES: int = 1024 * 1024


## Append one launch. `path` is the vault chosen, `why` the reason for it
## (VaultStore.launch_reason), `opened` the vault that actually opened.
static func record(path: String, why: String, opened: String, seeded: bool, marker: bool, notes: int, warning: String) -> void:
	var fell_back: bool = VaultRegistry.normalize(path) != VaultRegistry.normalize(opened)
	var lines: Array[String] = [
		"%s launch: Ontomeme %s on %s" % [Time.get_datetime_string_from_system(), ProjectSettings.get_setting("application/config/version", "?"), OS.get_name()],
		"  vault chosen: %s (why: %s)" % [path, why],
		"  vault opened: %s%s" % [opened, " (fell back to the app data folder)" if fell_back else ""],
		"  starter seed: %s; marker %s" % ["ran" if seeded else "skipped (not a first run)", "present" if marker else "absent"],
		"  notes: %d" % notes,
	]
	if warning != "":
		lines.append("  warning: " + warning)
	append(lines)


## Add `lines` to the log, moving a log past MAX_BYTES aside first. A log that
## can't be written is dropped: it must never stop the app from starting.
static func append(lines: Array[String]) -> void:
	var dir: String = ProjectSettings.globalize_path(FILE.get_base_dir())
	DirAccess.make_dir_recursive_absolute(dir)
	_rotate()
	var f: FileAccess = FileAccess.open(FILE, FileAccess.READ_WRITE if FileAccess.file_exists(FILE) else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_string("\n".join(lines) + "\n")


static func _rotate() -> void:
	if not FileAccess.file_exists(FILE):
		return
	var f: FileAccess = FileAccess.open(FILE, FileAccess.READ)
	if f == null or f.get_length() < MAX_BYTES:
		return
	f.close()
	if FileAccess.file_exists(BACKUP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(BACKUP))
	DirAccess.rename_absolute(ProjectSettings.globalize_path(FILE), ProjectSettings.globalize_path(BACKUP))
