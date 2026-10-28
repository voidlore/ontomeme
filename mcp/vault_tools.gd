extends RefCounted
## The MCP tools over one Ontomeme vault: list, read, create, update, delete
## and search notes. No I/O besides the vault files, no UI, no stdio, so the
## same object can sit behind the headless stdio server or inside the app.
##   var tools := VaultTools.new("/path/to/vault")
##   tools.call_tool("read_note", {"path": "Physics/note_waves.tres"})
##
## Notes are ContentLayer .tres files written with ResourceSaver, so the app
## loads them exactly like its own. A note's id is its path inside the vault.
##
## Safety rules:
## - read_note returns `hash` = SHA-256 of the file bytes on disk.
## - update_note / delete_note need that hash and refuse (isError, code
##   "conflict") when the file changed since it was read.
## - create_note refuses when the file already exists.
## - Writes go to a temp file in <vault>/.ontomeme/tmp/ and are renamed over
##   the note, so nobody reads a half-written note.
## - delete_note moves the file into <vault>/.trash/; nothing is hard-deleted.

const TRASH_DIR: String = ".trash"
const TMP_DIR: String = ".ontomeme/tmp"
const SNIPPET_CHARS: int = 160

## Absolute vault path, always ending in "/".
var vault: String
## Called with (action: String, rel_path: String) after every write, so a
## host (the app) can refresh its view. Optional.
var on_change: Callable = Callable()


func _init(vault_path: String) -> void:
	vault = ProjectSettings.globalize_path(vault_path).simplify_path().trim_suffix("/") + "/"


# ---------------------------------------------------------------------------
# Tool catalog
# ---------------------------------------------------------------------------

func list_tools() -> Array:
	var path_prop: Dictionary = {"type": "string", "description": "Note path inside the vault, as returned by list_notes, e.g. \"Physics/note_waves.tres\"."}
	var hash_prop: Dictionary = {"type": "string", "description": "The hash returned by read_note (or by the last create/update). The call is refused if the note changed since."}
	var tags_prop: Dictionary = {"type": "array", "items": {"type": "string"}, "description": "Tags, without the leading #."}
	return [
		{
			"name": "list_notes",
			"title": "List notes",
			"description": "List the notes in the vault (path, title, folder, tags, dates) and its folders. Optionally only one folder and its subfolders.",
			"inputSchema": {"type": "object", "properties": {
				"folder": {"type": "string", "description": "Folder inside the vault, e.g. \"Physics\". Empty = whole vault."},
			}},
			"annotations": {"readOnlyHint": true, "openWorldHint": false},
		},
		{
			"name": "read_note",
			"title": "Read a note",
			"description": "Read one note: title, tags, dates, its Markdown body (with ```3d scene blocks as written) and a hash to pass to update_note or delete_note.",
			"inputSchema": {"type": "object", "properties": {
				"path": path_prop,
				"raw": {"type": "boolean", "description": "Also return the .tres file text exactly as stored."},
			}, "required": ["path"]},
			"annotations": {"readOnlyHint": true, "openWorldHint": false},
		},
		{
			"name": "create_note",
			"title": "Create a note",
			"description": "Create a new note. The file is named after the title the way the app names it (\"note_<title>.tres\"). Refuses if that file already exists.",
			"inputSchema": {"type": "object", "properties": {
				"title": {"type": "string"},
				"markdown": {"type": "string", "description": "Note body in Markdown."},
				"tags": tags_prop,
				"folder": {"type": "string", "description": "Folder inside the vault (created if missing). Empty = top level."},
			}, "required": ["title"]},
			"annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false},
		},
		{
			"name": "update_note",
			"title": "Update a note",
			"description": "Replace a note's title, Markdown body and/or tags (fields left out stay as they are). Needs the hash from read_note; refuses with a conflict if the note changed since.",
			"inputSchema": {"type": "object", "properties": {
				"path": path_prop,
				"hash": hash_prop,
				"title": {"type": "string"},
				"markdown": {"type": "string", "description": "The full new body (replaces the old one)."},
				"tags": tags_prop,
			}, "required": ["path", "hash"]},
			"annotations": {"readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false},
		},
		{
			"name": "delete_note",
			"title": "Delete a note",
			"description": "Move a note to the vault's .trash folder (it can be restored from there). Needs the hash from read_note; refuses with a conflict if the note changed since.",
			"inputSchema": {"type": "object", "properties": {
				"path": path_prop,
				"hash": hash_prop,
			}, "required": ["path", "hash"]},
			"annotations": {"readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false},
		},
		{
			"name": "search_notes",
			"title": "Search notes",
			"description": "Find notes. `query` matches title or body text; `title` matches the title only; `tag` matches a tag exactly. All are case-insensitive and combine with AND.",
			"inputSchema": {"type": "object", "properties": {
				"query": {"type": "string"},
				"title": {"type": "string"},
				"tag": {"type": "string"},
				"folder": {"type": "string"},
				"limit": {"type": "integer", "minimum": 1, "description": "Maximum results (default 50)."},
			}},
			"annotations": {"readOnlyHint": true, "openWorldHint": false},
		},
	]


func has_tool(name: String) -> bool:
	return name in ["list_notes", "read_note", "create_note", "update_note", "delete_note", "search_notes"]


## Run a tool. Always returns an MCP CallToolResult; failures come back with
## isError = true and a structured {error: {code, message}} body.
func call_tool(name: String, args: Dictionary) -> Dictionary:
	if not DirAccess.dir_exists_absolute(vault):
		return _fail("no_vault", "Vault folder does not exist: " + vault)
	var r: Dictionary
	match name:
		"list_notes": r = list_notes(args)
		"read_note": r = read_note(args)
		"create_note": r = create_note(args)
		"update_note": r = update_note(args)
		"delete_note": r = delete_note(args)
		"search_notes": r = search_notes(args)
		_: return _fail("unknown_tool", "Unknown tool: " + name)
	return r


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

func list_notes(args: Dictionary) -> Dictionary:
	var folder: Variant = _clean_folder(args.get("folder", ""))
	if folder == null:
		return _fail("invalid_path", "Bad folder: " + str(args.get("folder")))
	var notes: Array = []
	var folders: Array = []
	for rel in _scan(folder, folders):
		var n: ContentLayer = _load(rel)
		if n != null:
			notes.append(_summary(rel, n))
	notes.sort_custom(func(a, b): return a.modified > b.modified)
	return _ok({"notes": notes, "folders": folders, "count": notes.size()})


func read_note(args: Dictionary) -> Dictionary:
	var rel: Variant = _clean_note_path(args.get("path"))
	if rel == null:
		return _fail("invalid_path", "Bad note path: " + str(args.get("path")))
	if not FileAccess.file_exists(vault + rel):
		return _fail("not_found", "No note at " + rel)
	var n: ContentLayer = _load(rel)
	if n == null:
		return _fail("not_a_note", rel + " is not an Ontomeme note")
	var out: Dictionary = _summary(rel, n)
	out["markdown"] = n.raw_text
	out["hash"] = file_hash(rel)
	if args.get("raw", false) == true:
		out["raw"] = FileAccess.get_file_as_string(vault + rel)
	return _ok(out)


func create_note(args: Dictionary) -> Dictionary:
	var title: Variant = args.get("title")
	if not (title is String) or (title as String).strip_edges() == "":
		return _fail("invalid_arguments", "create_note needs a non-empty title")
	var folder: Variant = _clean_folder(args.get("folder", ""))
	if folder == null:
		return _fail("invalid_path", "Bad folder: " + str(args.get("folder")))
	var bad: String = _check_fields(args)
	if bad != "":
		return _fail("invalid_arguments", bad)
	var file: String = VaultStore.filename_stem(title) + ".tres"
	var rel: String = (folder as String).path_join(file) if folder != "" else file
	if FileAccess.file_exists(vault + rel):
		return _fail("exists", "A note file already exists at " + rel + "; read it and use update_note, or pick another title", {"path": rel})
	var n := ContentLayer.new()
	n.title = (title as String).strip_edges()
	n.raw_text = str(args.get("markdown", ""))
	n.tags = _tags(args.get("tags", []))
	n.structure = {}
	n.created = Time.get_datetime_string_from_system()
	n.modified = n.created
	if folder != "":
		DirAccess.make_dir_recursive_absolute(vault + folder)
	var err: String = _atomic_save(n, rel, true)
	if err != "":
		return _fail("write_failed", err)
	_changed("create", rel)
	return _ok({"path": rel, "title": n.title, "hash": file_hash(rel)})


func update_note(args: Dictionary) -> Dictionary:
	var rel: Variant = _clean_note_path(args.get("path"))
	if rel == null:
		return _fail("invalid_path", "Bad note path: " + str(args.get("path")))
	var bad: String = _check_fields(args)
	if bad != "":
		return _fail("invalid_arguments", bad)
	var gate: Dictionary = _hash_gate(rel, args.get("hash"))
	if not gate.is_empty():
		return gate
	var n: ContentLayer = _load(rel)
	if n == null:
		return _fail("not_a_note", rel + " is not an Ontomeme note")
	if args.has("title"):
		if str(args.title).strip_edges() == "":
			return _fail("invalid_arguments", "title cannot be empty")
		n.title = str(args.title).strip_edges()
	if args.has("markdown"):
		n.raw_text = str(args.markdown)
	if args.has("tags"):
		n.tags = _tags(args.tags)
	n.modified = Time.get_datetime_string_from_system()
	var err: String = _atomic_save(n, rel, false)
	if err != "":
		return _fail("write_failed", err)
	_changed("update", rel)
	return _ok({"path": rel, "title": n.title, "hash": file_hash(rel)})


func delete_note(args: Dictionary) -> Dictionary:
	var rel: Variant = _clean_note_path(args.get("path"))
	if rel == null:
		return _fail("invalid_path", "Bad note path: " + str(args.get("path")))
	var gate: Dictionary = _hash_gate(rel, args.get("hash"))
	if not gate.is_empty():
		return gate
	var dest_rel: String = TRASH_DIR.path_join(rel)
	if FileAccess.file_exists(vault + dest_rel):
		# Keep the earlier trashed copy too: never overwrite inside the trash.
		var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
		var base: String = TRASH_DIR.path_join(rel).get_basename() + " (deleted " + stamp
		dest_rel = base + ").tres"
		var i: int = 2
		while FileAccess.file_exists(vault + dest_rel):
			dest_rel = "%s %d).tres" % [base, i]
			i += 1
	DirAccess.make_dir_recursive_absolute(vault + dest_rel.get_base_dir())
	if DirAccess.rename_absolute(vault + rel, vault + dest_rel) != OK:
		return _fail("write_failed", "Could not move " + rel + " to the trash")
	_changed("delete", rel)
	return _ok({"path": rel, "trashed_to": dest_rel})


func search_notes(args: Dictionary) -> Dictionary:
	var folder: Variant = _clean_folder(args.get("folder", ""))
	if folder == null:
		return _fail("invalid_path", "Bad folder: " + str(args.get("folder")))
	var q: String = str(args.get("query", "")).strip_edges().to_lower()
	var tq: String = str(args.get("title", "")).strip_edges().to_lower()
	var tag: String = str(args.get("tag", "")).strip_edges().trim_prefix("#").to_lower()
	var limit: int = maxi(1, int(args.get("limit", 50)))
	var hits: Array = []
	for rel in _scan(folder, []):
		var n: ContentLayer = _load(rel)
		if n == null:
			continue
		var title_l: String = n.title.to_lower()
		if tq != "" and not title_l.contains(tq):
			continue
		if tag != "" and not n.tags.any(func(t): return str(t).trim_prefix("#").to_lower() == tag):
			continue
		var hit: Dictionary = _summary(rel, n)
		if q != "":
			var at: int = n.raw_text.to_lower().find(q)
			if not title_l.contains(q) and at < 0:
				continue
			hit["matched"] = "title" if title_l.contains(q) else "content"
			if at >= 0:
				var from: int = maxi(0, at - SNIPPET_CHARS / 2)
				hit["snippet"] = n.raw_text.substr(from, SNIPPET_CHARS).replace("\n", " ")
		hits.append(hit)
	hits.sort_custom(func(a, b): return a.modified > b.modified)
	var total: int = hits.size()
	return _ok({"notes": hits.slice(0, limit), "count": mini(total, limit), "total": total})


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## SHA-256 (hex) of the note file's bytes; "" if it is missing.
func file_hash(rel: String) -> String:
	return FileAccess.get_sha256(vault + rel) if FileAccess.file_exists(vault + rel) else ""


## Empty Dictionary when the note exists and matches `expected`; otherwise the
## refusal to return.
func _hash_gate(rel: String, expected: Variant) -> Dictionary:
	if not (expected is String) or expected == "":
		return _fail("invalid_arguments", "hash is required: call read_note first and pass its hash")
	if not FileAccess.file_exists(vault + rel):
		return _fail("not_found", "No note at " + rel + " (it may have been moved or deleted)")
	var current: String = file_hash(rel)
	if current != expected:
		return _fail("conflict", "The note changed since you read it. Read it again, re-apply your change, and retry with the new hash.",
				{"path": rel, "expected_hash": expected, "current_hash": current})
	return {}


## Write `n` to <vault>/<rel> via a temp file + rename. "" on success.
func _atomic_save(n: ContentLayer, rel: String, must_not_exist: bool) -> String:
	var tmp_dir: String = vault + TMP_DIR
	DirAccess.make_dir_recursive_absolute(tmp_dir)
	var tmp: String = tmp_dir.path_join("mcp-%d-%d.tres" % [Time.get_ticks_usec(), randi()])
	var err: int = ResourceSaver.save(n, tmp)
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return "Could not write a temp file (error %d)" % err
	if must_not_exist and FileAccess.file_exists(vault + rel):
		DirAccess.remove_absolute(tmp)
		return rel + " appeared while writing; nothing was changed"
	err = DirAccess.rename_absolute(tmp, vault + rel)
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return "Could not move the temp file into place (error %d)" % err
	return ""


## Load a note fresh from disk (never a cached copy), or null.
func _load(rel: String) -> ContentLayer:
	if not FileAccess.file_exists(vault + rel):
		return null
	return ResourceLoader.load(vault + rel, "", ResourceLoader.CACHE_MODE_IGNORE) as ContentLayer


func _summary(rel: String, n: ContentLayer) -> Dictionary:
	return {
		"path": rel,
		"title": n.title,
		"folder": rel.get_base_dir(),
		"tags": Array(n.tags),
		"created": n.created,
		"modified": n.modified,
	}


## Relative paths of every .tres note under `folder`, skipping hidden folders
## (.ontomeme, .trash) and the root asset folder, like the app does.
## Folder paths found are appended to `folders_out`.
func _scan(folder: String, folders_out: Array) -> Array:
	var out: Array = []
	var dir := DirAccess.open(vault + folder)
	if dir == null:
		return out
	for d in dir.get_directories():
		if VaultStore._is_skipped_dir(folder, d):
			continue
		var sub: String = folder.path_join(d) if folder != "" else d
		folders_out.append(sub)
		out.append_array(_scan(sub, folders_out))
	for f in dir.get_files():
		if f.ends_with(".tres"):
			out.append(folder.path_join(f) if folder != "" else f)
	return out


## A vault-relative folder ("" = root) or null if it escapes the vault or
## points into a hidden folder.
func _clean_folder(v: Variant) -> Variant:
	if v == null:
		return ""
	if not (v is String):
		return null
	var s: String = (v as String).strip_edges().replace("\\", "/").trim_prefix("./").trim_suffix("/")
	if s == "" or s == ".":
		return ""
	return s if _safe_rel(s) else null


## A vault-relative .tres path, or null.
func _clean_note_path(v: Variant) -> Variant:
	if not (v is String):
		return null
	var s: String = (v as String).strip_edges().replace("\\", "/").trim_prefix("./")
	if not s.ends_with(".tres") or not _safe_rel(s):
		return null
	return s


func _safe_rel(s: String) -> bool:
	if s.is_absolute_path() or s.begins_with("/") or s.contains(":") or s.contains("//"):
		return false
	var parts: PackedStringArray = s.split("/")
	for i in parts.size():
		var p: String = parts[i]
		if p == "" or p == "." or p == ".." or p.begins_with("."):
			return false
		if i == 0 and parts.size() > 1 and p in VaultStore.ASSET_DIRS:
			return false
	return (vault + s).simplify_path().begins_with(vault)


func _check_fields(args: Dictionary) -> String:
	if args.has("markdown") and not (args.markdown is String):
		return "markdown must be a string"
	if args.has("title") and not (args.title is String):
		return "title must be a string"
	if args.has("tags"):
		if not (args.tags is Array):
			return "tags must be an array of strings"
		for t in args.tags:
			if not (t is String):
				return "tags must be an array of strings"
	return ""


func _tags(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if v is Array:
		for t in v:
			var s: String = str(t).strip_edges().trim_prefix("#")
			if s != "" and not (s in out):
				out.append(s)
	return out


func _changed(action: String, rel: String) -> void:
	if on_change.is_valid():
		on_change.call(action, rel)


static func _ok(data: Dictionary) -> Dictionary:
	return {
		"content": [{"type": "text", "text": JSON.stringify(data)}],
		"structuredContent": data,
		"isError": false,
	}


static func _fail(code: String, message: String, extra: Dictionary = {}) -> Dictionary:
	var data: Dictionary = {"error": {"code": code, "message": message}}
	data.error.merge(extra)
	return {
		"content": [{"type": "text", "text": message}],
		"structuredContent": data,
		"isError": true,
	}
