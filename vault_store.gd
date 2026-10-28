class_name VaultStore
extends Node

const TresValidatorScript = preload("res://tres_validator.gd")
const StarterContent = preload("res://starter_content.gd")

## VaultStore — persistent note storage engine.
##
## A Node-based singleton (autoload) with static methods for vault access.
## Manages vault directory creation, note file CRUD, listing, and search.
##
## Usage:
##     VaultStore.save_note(note)
##     var note := VaultStore.load_note(0)

## Absolute path of the open vault, always ending in "/".
static var vault_path: String = ""

## Cached list of all notes, sorted by modified date descending.
static var note_list: Array[ContentLayer] = []

## Every subfolder of the vault, relative ("Physics/Waves"), sorted.
## Hidden folders (".ontomeme") and the root "models" asset folder are skipped.
static var folders: Array[String] = []

## Last-seen modification time per note file, to spot outside edits.
static var _mtimes: Dictionary = {}

## SHA-256 of each note file as the app last read or wrote it. A save that
## finds different bytes on disk would overwrite an outside edit.
static var _hashes: Dictionary = {}

## Set by save_note() when it kept an outside edit and wrote the in-memory
## version as this new note instead; null otherwise.
static var last_conflict_copy: ContentLayer = null

const ASSET_DIRS: Array[String] = ["models"]

## True when this launch created the default vault and filled it with the
## starter notes (the app then opens the tutorials).
static var first_run: bool = false

## A startup problem worth telling the user about ("" if none).
static var startup_warning: String = ""


func _ready() -> void:
	# A vault opened before the autoload is ready (a test's throwaway vault)
	# wins; otherwise the startup vault would silently replace it.
	if vault_path == "":
		open_startup_vault(VaultRegistry.startup_vault(), VaultRegistry.default_vault(), not _cmdline_vault())


## Open `path`; seed it if it is the default vault being created for the first
## time; fall back to `fallback_dir` if `path` cannot be created.
static func open_startup_vault(path: String, default_vault: String, remember: bool,
		fallback_dir: String = OS.get_user_data_dir().path_join("vault")) -> void:
	first_run = StarterContent.is_first_run(path, default_vault)
	startup_warning = ""
	open_vault(path, remember)
	if not DirAccess.dir_exists_absolute(vault_path):
		startup_warning = "Couldn't create your notes folder at %s, so notes are kept in %s instead." % [path, fallback_dir]
		push_warning(startup_warning)
		first_run = not DirAccess.dir_exists_absolute(fallback_dir)
		open_vault(fallback_dir, remember)
	if first_run:
		StarterContent.seed_vault()


static func _cmdline_vault() -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--vault="):
			return true
	return false


## Switch to the vault at `path` (created if missing).
static func open_vault(path: String, remember: bool = true) -> void:
	vault_path = VaultRegistry.normalize(path)
	_create_vault()
	_migrate_hidden_dir()
	_mtimes.clear()
	_hashes.clear()
	note_list.clear()
	if remember:
		VaultRegistry.remember(vault_path)
	ProgressStore.invalidate()
	JourneyStore.invalidate()
	refresh_note_list()


## Vault-local app data (progress, journey) lives in <vault>/.ontomeme.
static func data_dir() -> String:
	return vault_path.path_join(".ontomeme")


static func _migrate_hidden_dir() -> void:
	var old: String = vault_path.path_join(".senedril")
	if DirAccess.dir_exists_absolute(old) and not DirAccess.dir_exists_absolute(data_dir()):
		DirAccess.rename_absolute(old, data_dir())


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

## Create the vault directory if it does not exist.
static func _create_vault() -> void:
	if not DirAccess.dir_exists_absolute(vault_path):
		DirAccess.make_dir_recursive_absolute(vault_path)


## File stem for a note title: "My Note!" → "note_my_note". Pure (no vault
## state), so the MCP tools name files exactly the way the app does.
static func filename_stem(title: String) -> String:
	var base: String = title.replace(" ", "_").to_lower().strip_edges()
	# Keep filenames portable: only letters, digits, _ and -
	var clean: String = ""
	for ch in base:
		clean += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-" else ""
	base = clean if clean != "" else "untitled"
	if not base.begins_with("note_"):
		base = "note_" + base
	return base


## Generate a unique filename (relative to the vault) for a new note.
static func _unique_filename(title: String, folder: String = "") -> String:
	var base: String = filename_stem(title)
	var prefix: String = (folder.trim_suffix("/") + "/") if folder != "" else ""
	var stem: String = base
	var i: int = 1
	while _file_exists(prefix + stem + ".tres"):
		stem = base + "_" + str(i)
		i += 1
	return prefix + stem + ".tres"


## Check if a file exists in the vault (path relative to the vault).
static func _file_exists(filename: String) -> bool:
	return FileAccess.file_exists(vault_path + filename)


static func _is_skipped_dir(rel: String, name: String) -> bool:
	return name.begins_with(".") or (rel == "" and name in ASSET_DIRS)


## Refresh the note list by scanning the vault folder and its subfolders.
static func refresh_note_list() -> void:
	note_list.clear()
	folders.clear()
	_scan("")
	folders.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	# Sort by modified date descending (most recent first)
	note_list.sort_custom(_sort_by_modified)


static func _scan(rel: String) -> void:
	var dir := DirAccess.open(vault_path + rel)
	if dir == null:
		return
	for d in dir.get_directories():
		if not _is_skipped_dir(rel, d):
			var sub: String = rel.path_join(d) if rel != "" else d
			folders.append(sub)
			_scan(sub)
	for f in dir.get_files():
		if f.ends_with(".tres"):
			var path: String = vault_path + (rel.path_join(f) if rel != "" else f)
			var mtime: int = FileAccess.get_modified_time(path)
			var changed: bool = _mtimes.has(path) and _mtimes[path] != mtime
			_mtimes[path] = mtime
			var note: ContentLayer = _load_note_file(path, changed)
			if note != null:
				note_list.append(note)


## Cheap fingerprint of the vault on disk: every folder and note file with
## its modification time. When it changes, something outside the app (a file
## manager, git, a sync tool) touched the vault.
static func disk_signature() -> String:
	var parts: PackedStringArray = []
	_sig("", parts)
	return "\n".join(parts)


static func _sig(rel: String, parts: PackedStringArray) -> void:
	var dir := DirAccess.open(vault_path + rel)
	if dir == null:
		return
	for d in dir.get_directories():
		if not _is_skipped_dir(rel, d):
			var sub: String = rel.path_join(d) if rel != "" else d
			parts.append(sub + "/")
			_sig(sub, parts)
	for f in dir.get_files():
		if f.ends_with(".tres"):
			var p: String = rel.path_join(f) if rel != "" else f
			parts.append("%s %d" % [p, FileAccess.get_modified_time(vault_path + p)])


## Folder of a note, relative to the vault ("" = top level).
static func folder_of(note: ContentLayer) -> String:
	if note == null or not note.resource_path.begins_with(vault_path):
		return ""
	return note.resource_path.substr(vault_path.length()).get_base_dir()


## Sort notes by modified timestamp descending.
static func _sort_by_modified(a: ContentLayer, b: ContentLayer) -> bool:
	return a.modified > b.modified


## Hand-written notes sometimes lack the `script = ...` line, so Godot
## loads them as a bare Resource and every field is dropped. Insert the
## ContentLayer script reference into the file so it loads properly.
static func _repair_scriptless_note(path: String) -> bool:
	var text: String = FileAccess.get_file_as_string(path)
	if text == "" or text.contains("script = ") or not text.contains("[resource]"):
		return false
	var header_end: int = text.find("]")
	if not text.begins_with("[gd_resource") or header_end < 0:
		return false
	var fixed: String = "[gd_resource type=\"Resource\" script_class=\"ContentLayer\" format=3]\n\n"
	fixed += "[ext_resource type=\"Script\" path=\"res://ContentLayer.gd\" id=\"1_content_layer\"]"
	fixed += text.substr(header_end + 1).replace("[resource]\n", "[resource]\nscript = ExtResource(\"1_content_layer\")\n")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(fixed)
	f.close()
	print("[VaultStore] Repaired note without script reference: ", path.get_file())
	return true


## Load a single .tres file into a ContentLayer resource.
## Validates the file with TresValidator; auto-fixes if possible.
static func _load_note_file(path: String, changed_on_disk: bool = false) -> ContentLayer:
	if not FileAccess.file_exists(path):
		return null
	var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE if changed_on_disk else ResourceLoader.CACHE_MODE_REUSE)
	if loaded != null and not (loaded is ContentLayer) and _repair_scriptless_note(path):
		loaded = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	var resource: ContentLayer = loaded as ContentLayer
	if resource == null:
		print("[VaultStore] Failed to load resource: ", path)
		return null
	if changed_on_disk or not _hashes.has(path):
		_hashes[path] = FileAccess.get_sha256(path)
	# Validate and auto-fix if needed
	var result: Dictionary = TresValidatorScript.validate(path)
	if result.valid:
		return resource
	# Auto-fix was attempted; return the (possibly fixed) resource
	print("[VaultStore] Validation errors for ", path, ": ", result.errors)
	return resource


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Create a new note with a title. Saves it and returns the created ContentLayer.
static func create_note(title: String = "untitled", folder: String = "") -> ContentLayer:
	var filename: String = _unique_filename(title, folder)
	var note: ContentLayer = ContentLayer.new()
	note.title = title
	note.raw_text = ""
	note.tags = []
	note.structure = {}
	var created := Time.get_datetime_string_from_system()
	note.created = created
	note.modified = created
	note.take_over_path(vault_path + filename)
	save_note(note)
	note_list.append(note)
	refresh_note_list()
	return note


## Save a note resource to its .tres file.
## A note keeps the file it was loaded from / first saved to (resource_path);
## only brand-new notes get a fresh unique filename. (Previously every save
## generated a new unique name, so each save wrote another duplicate file.)
## `stamp` = false keeps note.modified as set (seeders use it to order notes).
static func save_note(note: ContentLayer, stamp: bool = true) -> void:
	if note == null:
		return
	var path: String = note.resource_path
	if path.is_empty() or not path.begins_with(vault_path):
		path = vault_path + _unique_filename(note.title)
	last_conflict_copy = null
	# The file changed since the app last read or wrote it (a sync tool,
	# another editor, Claude): keep that version, save ours as a copy.
	if FileAccess.file_exists(path) and _hashes.has(path) and FileAccess.get_sha256(path) != _hashes[path]:
		_save_conflict_copy(note, path)
		return
	if stamp:
		note.modified = Time.get_datetime_string_from_system()
	var err := ResourceSaver.save(note, path)
	if err == OK:
		_mtimes[path] = FileAccess.get_modified_time(path)
		_hashes[path] = FileAccess.get_sha256(path)
		# Bind the note to its file so the next save overwrites it and
		# ResourceLoader's cache hands back this same object on refresh.
		note.take_over_path(path)
		refresh_note_list()
	else:
		print("[VaultStore] Save failed (", err, "): ", path)


## Write `note` (the app's version) as a new "<title> (conflict copy)" note
## in the same folder, and reload the original from disk so it shows the
## outside edit. Nothing on disk is overwritten.
static func _save_conflict_copy(note: ContentLayer, path: String) -> void:
	var copy: ContentLayer = note.duplicate()
	var title: String = note.title + " (conflict copy)"
	var n: int = 2
	while get_note_index(title) >= 0:
		title = "%s (conflict copy %d)" % [note.title, n]
		n += 1
	copy.title = title
	copy.modified = Time.get_datetime_string_from_system()
	var copy_path: String = vault_path + _unique_filename(title, folder_of(note))
	if ResourceSaver.save(copy, copy_path) != OK:
		push_error("Could not save a conflict copy of %s; the file on disk was left as it is" % path.get_file())
		return
	copy.take_over_path(copy_path)
	_mtimes[copy_path] = FileAccess.get_modified_time(copy_path)
	_hashes[copy_path] = FileAccess.get_sha256(copy_path)
	_mtimes[path] = FileAccess.get_modified_time(path)
	_load_note_file(path, true)   # updates `note` in place to the disk version
	last_conflict_copy = copy
	push_warning("%s changed on disk while open; kept it and saved the app's version as \"%s\"" % [path.get_file(), title])
	refresh_note_list()


## Load a note by its index in the (sorted) note list.
static func load_note(index: int) -> ContentLayer:
	if index < 0 or index >= note_list.size():
		return null
	return note_list[index]


## Delete a note at the given index. Returns true on success.
static func delete_note(index: int) -> bool:
	if index < 0 or index >= note_list.size():
		return false
	var note: ContentLayer = note_list[index]
	var path: String = note.resource_path
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	note_list.remove_at(index)
	refresh_note_list()
	return true


## Get the count of notes in the vault.
static func get_note_count() -> int:
	return note_list.size()


## Search notes by text (matches title or raw_text, case-insensitive).
## Returns an array of matching indices into note_list.
static func search(query: String) -> Array[int]:
	var results: Array[int] = []
	if query.is_empty():
		for i in range(note_list.size()):
			results.append(i)
		return results
	var lower_query: String = query.to_lower()
	for i in range(note_list.size()):
		var note: ContentLayer = note_list[i]
		if note.title.to_lower().contains(lower_query) or note.raw_text.to_lower().contains(lower_query):
			results.append(i)
	return results


## List all notes as an array of ContentLayer resources.
static func list_notes() -> Array[ContentLayer]:
	return note_list


## Get the zero-based index of a note by its title; -1 if not found.
static func get_note_index(title: String) -> int:
	for i in range(note_list.size()):
		if note_list[i].title == title:
			return i
	return -1


## Update a note's title (the file keeps its name and folder).
static func update_title(old_title: String, new_title: String) -> bool:
	for note in note_list:
		if note.title == old_title:
			note.title = new_title
			save_note(note)
			return true
	return false


# ---------------------------------------------------------------------------
# Folders — real directories on disk
# ---------------------------------------------------------------------------

static func _clean_name(name: String) -> String:
	var n: String = name.strip_edges()
	for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		n = n.replace(bad, "-")
	return n.trim_prefix(".")


## Create a folder (inside `parent`); returns its relative path, or "" on failure.
static func create_folder(name: String, parent: String = "") -> String:
	var n: String = _clean_name(name)
	if n == "":
		n = "New folder"
	var base: String = parent.path_join(n) if parent != "" else n
	var rel: String = base
	var i: int = 2
	while DirAccess.dir_exists_absolute(vault_path + rel):
		rel = "%s %d" % [base, i]
		i += 1
	if DirAccess.make_dir_recursive_absolute(vault_path + rel) != OK:
		return ""
	refresh_note_list()
	return rel


## Move a folder to `new_rel` (rename and/or re-parent). Notes inside keep
## their identity — open notes stay open. Returns the new path or "".
static func move_folder(rel: String, new_rel: String) -> String:
	new_rel = new_rel.trim_suffix("/")
	if rel == "" or new_rel == "" or new_rel == rel or (new_rel + "/").begins_with(rel + "/"):
		return ""
	if DirAccess.dir_exists_absolute(vault_path + new_rel) or not DirAccess.dir_exists_absolute(vault_path + rel):
		return ""
	DirAccess.make_dir_recursive_absolute(vault_path + new_rel.get_base_dir())
	if DirAccess.rename_absolute(vault_path + rel, vault_path + new_rel) != OK:
		return ""
	var old_prefix: String = vault_path + rel + "/"
	for note in note_list:
		if note.resource_path.begins_with(old_prefix):
			var np: String = vault_path + new_rel + "/" + note.resource_path.substr(old_prefix.length())
			_mtimes.erase(note.resource_path)
			note.take_over_path(np)
			_mtimes[np] = FileAccess.get_modified_time(np)
	refresh_note_list()
	return new_rel


static func rename_folder(rel: String, new_name: String) -> String:
	var n: String = _clean_name(new_name)
	if n == "":
		return ""
	var parent: String = rel.get_base_dir()
	return move_folder(rel, parent.path_join(n) if parent != "" else n)


## Move a folder (and everything in it) to the system trash.
static func delete_folder(rel: String) -> bool:
	if rel == "" or not DirAccess.dir_exists_absolute(vault_path + rel):
		return false
	var ok: bool = OS.move_to_trash(vault_path + rel) == OK
	if not ok:
		ok = _remove_recursive(vault_path + rel)
	refresh_note_list()
	return ok


static func _remove_recursive(path: String) -> bool:
	var dir := DirAccess.open(path)
	if dir == null:
		return false
	for d in dir.get_directories():
		_remove_recursive(path.path_join(d))
	for f in dir.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	return DirAccess.remove_absolute(path) == OK


## Move a note's file into `folder` ("" = top level). Keeps the same object.
static func move_note(note: ContentLayer, folder: String) -> bool:
	if note == null or folder_of(note) == folder or not FileAccess.file_exists(note.resource_path):
		return false
	DirAccess.make_dir_recursive_absolute(vault_path + folder)
	var file: String = note.resource_path.get_file()
	var dest_rel: String = folder.path_join(file) if folder != "" else file
	if _file_exists(dest_rel):
		dest_rel = _unique_filename(note.title, folder)
	var dest: String = vault_path + dest_rel
	if DirAccess.rename_absolute(note.resource_path, dest) != OK:
		return false
	_mtimes.erase(note.resource_path)
	note.take_over_path(dest)
	_mtimes[dest] = FileAccess.get_modified_time(dest)
	refresh_note_list()
	return true
