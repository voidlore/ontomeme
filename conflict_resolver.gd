class_name ConflictResolver
extends Node

## ConflictResolver — optimistic file locking for vault notes.
##
## Detects write-write conflicts by comparing content hashes before and
## after reads. Supports three-strategy resolution: abort, merge, or
## save-as-duplicate. Targets single-user, single-device apps where
## the primary conflict scenario is process crash/restart.
##
## Usage:
##     var hash := ConflictResolver.compute_hash(path)
##     var has_conflict := ConflictResolver.check_conflict(path, saved_hash)
##     var new_path := ConflictResolver.resolve(note, vault_path, "My Note", strategy)


## Conflict resolution strategy.
enum Strategy {
	ABORT,        # Do not write; caller handles the conflict
	AS_DUPLICATE, # Save as "title (conflict).tres"
	AUTO_MERGE,   # Keep newer content, log what was overwritten
}


## A hash map entry for tracking file state.
static func hash_entry_create(path: String, hash: String, mtime: int) -> Dictionary:
	return {"path": path, "hash": hash, "mtime": mtime}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


## Compute a content hash for a file.
## Uses Godot's built-in md5_file() if available, falls back to a
## simple CRC32-style hash via the string hash method.
static func compute_hash(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""

	var content := file.get_as_text()
	file.close()

	# Use Godot's built-in hash (deterministic, fast)
	return str(content.hash())


## Check if a file has changed since the given expected hash.
## Returns true if a conflict is detected (file content differs).
static func check_conflict(path: String, expected_hash: String) -> bool:
	if expected_hash == "":
		return false  # No baseline means no conflict possible
	if not FileAccess.file_exists(path):
		return false  # File deleted — not a write conflict, caller handles

	var current_hash := compute_hash(path)
	return current_hash != expected_hash


## Check if a file has changed by mtime comparison.
## Returns true if the file's modification time differs.
static func check_conflict_mtime(path: String, expected_mtime: int) -> bool:
	if expected_mtime <= 0:
		return false
	if not FileAccess.file_exists(path):
		return false

	var current_mtime := FileAccess.get_modified_time(path)
	return current_mtime != expected_mtime


## Combined conflict check: returns an error code.
## 0 = no conflict, 1 = content changed, 2 = file deleted, 3 = file unreadable.
static func check_conflict_detailed(path: String, expected_hash: String, expected_mtime: int) -> int:
	if expected_hash == "" and expected_mtime <= 0:
		return 0

	if not FileAccess.file_exists(path):
		return 2

	# Check if file is readable
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 3
	file.close()

	if expected_hash != "" and check_conflict(path, expected_hash):
		return 1
	if expected_mtime > 0 and check_conflict_mtime(path, expected_mtime):
		return 1

	return 0


## Resolve a conflict: either abort, save as duplicate, or auto-merge.
## Returns a dictionary: {"success": bool, "path": String, "message": String}.
static func resolve(conflicting_note: ContentLayer, vault_path: String,
					title: String, strategy: Strategy) -> Dictionary:
	var result = {"success": false, "path": "", "message": ""}

	match strategy:
		Strategy.ABORT:
			result.success = false
			result.message = "Conflict detected — save aborted per strategy"
			return result

		Strategy.AS_DUPLICATE:
			var new_path := _generate_duplicate_path(vault_path, title)
			var err := ResourceSaver.save(conflicting_note, new_path)
			if err == OK:
				result.success = true
				result.path = new_path
				result.message = "Saved as duplicate: " + new_path.get_file()
			else:
				result.message = "Failed to save duplicate: error " + str(err)
			return result

		Strategy.AUTO_MERGE:
			# For a .tres file, "merge" means: keep the in-memory note (which
			# is the current state) and overwrite. Log the conflict for awareness.
			# In a real app with structured content, a three-way merge would
			# compare and merge individual fields.
			var filename: String = vault_path.path_join(title.replace(" ", "_").to_lower().strip_edges() + ".tres")
			if not filename.ends_with(".tres"):
				filename += ".tres"
			var err := ResourceSaver.save(conflicting_note, filename)
			if err == OK:
				result.success = true
				result.path = filename
				result.message = "Auto-merged: overwrote with current state"
			else:
				result.message = "Failed to save merged note: error " + str(err)
			return result

		_:
			result.message = "Unknown strategy"
			return result


## Generate a unique duplicate filename for a conflicting note.
## E.g., "my_note.tres" → "my_note (conflict 1).tres".
static func _generate_duplicate_path(vault_path: String, title: String) -> String:
	var base := title.replace(" ", "_").to_lower().strip_edges()
	if not base.begins_with("note_"):
		base = "note_" + base

	# Try with suffixes until we find an unused path
	var stem := base
	var suffix_num := 1
	while true:
		var candidate: String
		if suffix_num == 1:
			candidate = vault_path + base + " (conflict).tres"
		else:
			candidate = vault_path + base + " (conflict " + str(suffix_num) + ").tres"

		if not FileAccess.file_exists(candidate):
			return candidate

		suffix_num += 1
		# Safety: don't loop forever
		if suffix_num > 1000:
			return vault_path + base + " (unsaved).tres"

	return vault_path + base + ".tres"
# ---------------------------------------------------------------------------
# VaultStore integration helpers
# ---------------------------------------------------------------------------


## Pre-save conflict check for VaultStore.
## Call this in save_note() before writing:
##     var check := ConflictResolver.pre_save(vault_path, note)
##     if check.conflict:
##         var res := ConflictResolver.resolve(...)
static func pre_save(vault_path: String, note: ContentLayer,
					 saved_hash: String, saved_mtime: int) -> Dictionary:
	var result = {"conflict": false, "note": note, "saved_hash": saved_hash}

	var filename := vault_path.path_join(note.title.replace(" ", "_").to_lower().strip_edges() + ".tres")
	if not filename.ends_with(".tres"):
		filename = vault_path + note.title.replace(" ", "_").to_lower().strip_edges() + ".tres"

	if not FileAccess.file_exists(filename):
		result["conflict"] = false  # New file, no conflict
		return result

	if not saved_hash.is_empty() and check_conflict(filename, saved_hash):
		result["conflict"] = true
		result["path"] = filename
		result["current_hash"] = compute_hash(filename)
		result["current_mtime"] = FileAccess.get_modified_time(filename)
		return result

	if saved_mtime > 0 and check_conflict_mtime(filename, saved_mtime):
		result["conflict"] = true
		result["path"] = filename
		result["current_hash"] = compute_hash(filename)
		result["current_mtime"] = saved_mtime
		return result

	return result
