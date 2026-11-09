extends RefCounted
## The MCP tools over one Ontomeme vault: list, read, create, update, delete,
## move and search notes, list the vault's tags, read the learner's quiz
## progress and Learning Journey, plus get_note_guide (the markup reference,
## shipped in mcp/note_guide.md). No I/O besides the vault files, no UI, no
## stdio, so the same object can sit behind the headless stdio server or
## inside the app.
##   var tools := VaultTools.new("/path/to/vault")
##   tools.call_tool("read_note", {"path": "Physics/note_waves.tres"})
##
## A note is either a ContentLayer .tres file (written with ResourceSaver, so
## the app loads it exactly like its own) or a plain .txt file of raw text
## (its body is the file; there are no title, tags or structure fields). The
## app itself is .tres-only and never lists .txt notes, but the server reads,
## creates, edits, trashes and searches both formats. A note's id is its path
## inside the vault.
##
## Safety rules:
## - read_note returns `hash` = SHA-256 of the file bytes on disk.
## - update_note / delete_note / move_note need that hash and refuse (isError,
##   code "conflict") when the file changed since it was read.
## - A new title in update_note follows the app's rename rules: a title
##   another note has is refused ("exists"), the file is renamed for it, and
##   RenameCascade rewrites the other notes' [[links]] and quiz learn:/next:
##   lines and moves the Journey and progress keys. Each of those other
##   writes passes the hash gate: a note changed since the rename read it is
##   left as it is and listed in `warnings`. "Untitled" names no one note, so
##   a rename to or from it moves no links or keys (RenameCascade).
## - create_note refuses when the file already exists.
## - create_note and update_note return `warnings`: what NoteLint (the checks
##   behind scripts/lint_notes.gd) finds in the body as written, checked
##   against this vault. They never refuse a write.
## - update_note edits .tres fields (title, body, tags) and the body of a
##   .txt; on a .txt file title/tags changes are refused ("invalid_arguments").
## - A .txt is edited only when its bytes are UTF-8 (a UTF-8 BOM is kept).
##   Any other encoding is read best-effort (editable false) and update_note
##   refuses it ("not_utf8"): writing back a lossy decoding would destroy the
##   characters it could not decode.
## - Writes go to a temp file in <vault>/.ontomeme/tmp/ and are renamed over
##   the note, so nobody reads a half-written note. A temp file that did not
##   get written in full (disk full, quota) is removed and the call fails
##   ("write_failed") with the note unchanged.
## - A U+FEFF (byte-order mark, how a "UTF-8 with BOM" file starts) at the
##   start of a .tres note's title, body or a tag is dropped (_no_bom): Godot's
##   text resource loader drops it there, so the saved note would not read
##   back as written. A .txt note's BOM is likewise not part of its text.
## - delete_note moves the file into <vault>/.trash/; nothing is hard-deleted.
## - move_note renames the file into another folder (never over an existing
##   file), so its bytes, and with them every field, are unchanged.
## - list_notes and search_notes return pages (`limit`, then `next_cursor` to
##   pass back as `cursor`), newest modified first with the path as the
##   tiebreak. A cursor names the last note of its page, not a position, so a
##   note created or trashed between pages never shifts the rest.
## - Every note is also a read-only MCP resource, ontomeme://note/<path>
##   (list_resources, resource_templates, read_resource: McpProtocol routes
##   resources/* here when they exist). A URI's path passes the same
##   _clean_note_path check as a tool's.
## - update_note and delete_note ask the user first when the client can show
##   an MCP elicitation prompt and confirm_writes is on (the default): the
##   call answers later ({"pending": true}, see McpProtocol), and only an
##   "accept" with confirm ticked writes, after the hash is checked again (the
##   note may have changed while the user decided). Anything else is
##   "declined"; no answer (timeout, a client error) is "not_confirmed".
##   Without the capability, or with confirm_writes off, they write at once
##   and the client's own approval (destructiveHint) is the only prompt.
## - The app keeps no hash inside the note files (VaultStore._hashes is
##   in-memory), so a server write never invalidates an embedded baseline:
##   the app re-hashes the file on save and compares with that record.
## - A .tres that carries code is never loaded: read_note and update_note
##   refuse it ("unsafe_note"), list_notes and search_notes leave it out.
## - No path leaves the vault through a symbolic link (or junction): one
##   that does, or that leads into a hidden folder, is refused
##   ("invalid_path"), and list_notes and search_notes follow no folder link
##   and leave out a note file linked elsewhere (_safe_rel, _scan). That
##   holds for the file create_note writes and for the .trash folder
##   delete_note moves a note into (_trash_refusal).
## - Tags are normalized the way the app shows them (TagOps): written tags
##   are stored normalized, and a `tag` search compares normalized forms.
## - get_progress and get_journey only read <vault>/.ontomeme/progress.json
##   and journey.json: never write, create, repair or copy them.

## Only for McpProtocol.to_json: the text of a result is valid JSON.
const McpProtocol = preload("res://mcp/protocol.gd")
const TRASH_DIR: String = ".trash"
const TMP_DIR: String = VaultStore.TMP_DIR
const SNIPPET_CHARS: int = 160
## list_notes / search_notes page size: `limit` defaults to this...
const PAGE_DEFAULT: int = 100
## ...and is capped at this, so one result stays small enough for a client.
const PAGE_MAX: int = 500
## A note's MCP resource URI is this + its vault path, percent-encoded ("/"
## as %2F): ontomeme://note/Physics%2Fnote_waves.tres.
const NOTE_URI: String = "ontomeme://note/"
const NOTE_MIME: String = "text/markdown"
## How a server turns confirm_writes off (confirm_writes_setting): this user
## argument (after "--") with off / false / no / 0, or this environment
## variable set to one of those.
const CONFIRM_FLAG: String = "--confirm-writes="
const CONFIRM_ENV: String = "ONTOMEME_MCP_CONFIRM"
const OFF_WORDS: Array[String] = ["off", "false", "no", "0"]
## An update prompt shows at most this many removed, then added, lines...
const PROMPT_LINES: int = 3
## ...each cut to this many characters.
const PROMPT_LINE_CHARS: int = 100
## The vault's Learning Journey (JourneyStore's file), for objective: checks.
const JOURNEY_FILE: String = ".ontomeme/journey.json"
const UTF8_BOM: PackedByteArray = [0xEF, 0xBB, 0xBF]
## The byte-order mark as text: never kept at the start of a .tres field.
const BOM_CHAR: String = "\uFEFF"
## read_note's `warning` on a .txt file whose bytes are not UTF-8.
const NOT_UTF8_WARNING: String = "This file is not UTF-8 text (see encoding), so markdown is only a best-effort reading of it and update_note refuses it with not_utf8; the original bytes stay as they are. Convert it to UTF-8 outside the server to edit it here. move_note and delete_note still work on it."

## The markup guide get_note_guide returns: a byte-for-byte copy of
## skills/ontomeme-notes/references/markup.md (mcp_test fails if they drift).
## Read through res:// so it also loads from an exported PCK (mcp/* is packed).
const GUIDE_PATH: String = "res://mcp/note_guide.md"
## get_note_guide topics → the guide sections each one returns, in order.
## Each entry is [heading prefix, whole]: the first heading whose words (after
## the #s, lowercase) start with the prefix; `whole` keeps its subsections,
## otherwise only the text before its first subheading.
const GUIDE_TOPICS: Dictionary = {
	"3d": [["3d blocks", true]],
	"quiz": [["3d blocks", false], ["quiz", true], ["`objective:`", true]],
	"flashcards": [["3d blocks", false], ["flashcards", true], ["`objective:`", true]],
	"links": [["text", true]],
}

## Absolute vault path, always ending in "/".
var vault: String
## Called with (action: String, rel_path: String) after every write, so a
## host (the app) can refresh its view. Optional. action is "create",
## "update", "delete" or "move" (rel_path is then the new path).
var on_change: Callable = Callable()
## Ask the user (MCP elicitation) before update_note and delete_note change a
## note, when the client can show the prompt. The stdio server sets it from
## confirm_writes_setting.
var confirm_writes: bool = true
## The McpProtocol serving these tools (attach_protocol). Weak: it holds us.
var _protocol: WeakRef = null


func _init(vault_path: String) -> void:
	vault = ProjectSettings.globalize_path(vault_path).simplify_path().trim_suffix("/") + "/"


## McpProtocol hook: the protocol to send elicitation requests through.
func attach_protocol(proto: Object) -> void:
	_protocol = weakref(proto)


## McpProtocol hook: the confirmation mode, stated in the initialize
## instructions so the client's model knows whether a write may be declined.
func instructions_for(client_capabilities: Dictionary) -> String:
	if not confirm_writes:
		return "Confirmations are off (--confirm-writes=off or ONTOMEME_MCP_CONFIRM=0): update_note and delete_note change notes without Ontomeme asking the user; your client may still ask for approval."
	if client_capabilities.has("elicitation"):
		return "Confirmations are on: before update_note or delete_note changes a note, Ontomeme asks the user through your client (an elicitation prompt summarising the change). If they decline, the call fails with code declined and the note is unchanged; don't retry it unless the user asks."
	return "Confirmations are on, but this client can't show Ontomeme's prompts (no elicitation capability), so update_note and delete_note rely on the client's own approval of destructive tools."


## Whether update_note and delete_note should ask the user, from the server's
## user arguments and the ONTOMEME_MCP_CONFIRM value: on, unless
## --confirm-writes= or (without the flag) the variable says off, false, no or
## 0. The flag wins over the variable, and its last copy wins; any other value
## keeps confirmations on.
static func confirm_writes_setting(user_args: PackedStringArray, env_value: String) -> bool:
	var setting: String = env_value
	for a in user_args:
		if a.begins_with(CONFIRM_FLAG):
			setting = a.substr(CONFIRM_FLAG.length())
	return not (setting.strip_edges().to_lower() in OFF_WORDS)


# ---------------------------------------------------------------------------
# Tool catalog
# ---------------------------------------------------------------------------

func list_tools() -> Array:
	var path_prop: Dictionary = {"type": "string", "description": "Note path inside the vault, as returned by list_notes, e.g. \"Physics/note_waves.tres\"."}
	var hash_prop: Dictionary = {"type": "string", "description": "The hash returned by read_note (or by the last create/update). The call is refused if the note changed since."}
	var tags_prop: Dictionary = {"type": "array", "items": {"type": "string"}, "description": "Tags, stored the way the app shows them: lowercase, no leading #, spaces as '-' (\"Foo Bar\" is foo-bar). Reuse the vault's tags from list_tags."}
	var limit_prop: Dictionary = {"type": "integer", "minimum": 1, "maximum": PAGE_MAX, "description": "Notes per page (default %d, at most %d)." % [PAGE_DEFAULT, PAGE_MAX]}
	var cursor_prop: Dictionary = {"type": "string", "description": "The next_cursor of the previous page, to get the page after it (with the same other arguments). Leave out for the first page."}
	return [
		{
			"name": "list_notes",
			"title": "List notes",
			"description": "List the notes in the vault (path, title, folder, tags, dates, starred_at, pinned_at), newest modified first, one page at a time: when more remain the result has next_cursor; pass it back as cursor for the next page. starred_at / pinned_at say when the user starred or pinned the note in the app (\"\" = not). The first page also lists the vault's folders. Optionally only one folder and its subfolders.",
			"inputSchema": {"type": "object", "properties": {
				"folder": {"type": "string", "description": "Folder inside the vault, e.g. \"Physics\". Empty = whole vault."},
				"limit": limit_prop,
				"cursor": cursor_prop,
			}},
			"annotations": {"readOnlyHint": true, "openWorldHint": false},
		},
		{
			"name": "read_note",
			"title": "Read a note",
			"description": "Read one note (a .tres note or a raw .txt file): title, tags, dates, starred_at and pinned_at (when the user starred or pinned it in the app, \"\" = not; all empty for .txt), its body, its format, and a hash to pass to update_note or delete_note. .txt files have no raw .tres text. A .txt that is not UTF-8 (e.g. UTF-16 from Windows) comes back with editable false, its encoding and a warning: its markdown is a best-effort reading and update_note refuses it.",
			"inputSchema": {"type": "object", "properties": {
				"path": path_prop,
				"raw": {"type": "boolean", "description": "Also return the .tres file text exactly as stored."},
			}, "required": ["path"]},
			"annotations": {"readOnlyHint": true, "openWorldHint": false},
		},
		{
			"name": "create_note",
			"title": "Create a note",
			"description": "Create a new note named after the title the way the app names it: by default a ContentLayer .tres (\"note_<title>.tres\") the app loads like its own, or with format \"text\" a plain .txt file whose bytes are exactly your Markdown. The app is .tres-only and never lists .txt notes. Tags are ignored for format \"text\". Refuses if the file already exists. The result's warnings lists what the app would render wrong (an unclosed ``` fence, a broken quiz, a link or learn: to a missing note...), each {level, line, message}: the note is written anyway, so fix them with update_note.",
			"inputSchema": {"type": "object", "properties": {
				"title": {"type": "string"},
				"markdown": {"type": "string", "description": "Note body in Markdown. It may contain ```3d blocks (3D scenes, quizzes, flashcards) and [[Note Title]] links: see get_note_guide."},
				"tags": tags_prop,
				"folder": {"type": "string", "description": "Folder inside the vault (created if missing). Empty = top level."},
				"format": {"type": "string", "enum": ["tres", "text"], "description": "\"tres\" (default) or \"text\" for a raw .txt file."},
			}, "required": ["title"]},
			"annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false},
		},
		{
			"name": "update_note",
			"title": "Update a note",
			"description": "Edit a note. A .tres note: replace its title, Markdown body and/or tags (fields left out stay as they are). A .txt file: only its body (the file is raw text; title or tags are refused), and only when it is UTF-8 (otherwise not_utf8). Needs the hash from read_note; refuses with a conflict if the note changed since. A new title renames the note the way the app does: refused with exists if another note has that title; otherwise the file is renamed (the result's path is the new one), [[links]] and quiz learn:/next: lines in other notes follow, as do the Journey and quiz progress. `changed` lists the other notes rewritten; a note that changed while the rename ran is left alone and listed in `warnings`. Ontomeme may first ask the user to confirm (see the initialize instructions); if they don't, the call fails with declined and nothing changes. Like create_note, the result's warnings lists markup problems in the saved body (the edit is made anyway).",
			"inputSchema": {"type": "object", "properties": {
				"path": path_prop,
				"hash": hash_prop,
				"title": {"type": "string"},
				"markdown": {"type": "string", "description": "The full new body (replaces the old one). It may contain ```3d blocks (3D scenes, quizzes, flashcards) and [[Note Title]] links: see get_note_guide."},
				"tags": tags_prop,
			}, "required": ["path", "hash"]},
			"annotations": {"readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false},
		},
		{
			"name": "delete_note",
			"title": "Delete a note",
			"description": "Move a note (a .tres or a .txt) to the vault's .trash folder (it can be restored from there). Needs the hash from read_note; refuses with a conflict if the note changed since. Ontomeme may first ask the user to confirm (see the initialize instructions); if they don't, the call fails with declined and nothing changes.",
			"inputSchema": {"type": "object", "properties": {
				"path": path_prop,
				"hash": hash_prop,
			}, "required": ["path", "hash"]},
			"annotations": {"readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false},
		},
		{
			"name": "move_note",
			"title": "Move a note",
			"description": "Move a note (a .tres or a .txt) into another folder. The file keeps its name and its bytes, so the created date, stars, pins and tags all stay; the folder is created if missing. Needs the hash from read_note; refuses with a conflict if the note changed since, and with exists if the folder already holds a file of that name. Returns the new path and hash. If the user is typing in that note in the app, its autosave can recreate it at the old path (two copies, the newest typing in the old folder): move notes nobody is editing, and check list_notes afterwards.",
			"inputSchema": {"type": "object", "properties": {
				"path": path_prop,
				"hash": hash_prop,
				"folder": {"type": "string", "description": "Target folder inside the vault, e.g. \"Physics/Waves\" (created if missing). \"\" = top level."},
			}, "required": ["path", "hash", "folder"]},
			"annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false},
		},
		{
			"name": "search_notes",
			"title": "Search notes",
			"description": "Find notes. `query` matches title or body text; `title` matches the title only; `tag` matches a tag exactly, compared the way the app shows tags (\"#Foo Bar\" is foo-bar). All are case-insensitive and combine with AND. Newest modified first, one page at a time: when more matches remain the result has next_cursor; pass it back as cursor (with the same filters) for the next page. `total` counts every match.",
			"inputSchema": {"type": "object", "properties": {
				"query": {"type": "string"},
				"title": {"type": "string"},
				"tag": {"type": "string"},
				"folder": {"type": "string"},
				"limit": limit_prop,
				"cursor": cursor_prop,
			}},
			"annotations": {"readOnlyHint": true, "openWorldHint": false},
		},
		{
			"name": "get_note_guide",
			"title": "Ontomeme markup guide",
			"description": "How to write Ontomeme notes: the Markdown it renders, [[Note Title]] links, ```3d blocks (3D scenes: presets and object lines), quizzes (q:/a*:/why:/learn:) and flashcards. Read it before writing a quiz, flashcards or a 3D scene. `topic` returns just that part.",
			"inputSchema": {"type": "object", "properties": {
				"topic": {"type": "string", "enum": GUIDE_TOPICS.keys(), "description": "Only one part: \"3d\" (3D blocks, every preset), \"quiz\", \"flashcards\" or \"links\" (text markup and [[links]]). Empty = the whole guide."},
			}},
			"annotations": {"readOnlyHint": true, "openWorldHint": false},
		},
		{
			"name": "list_tags",
			"title": "List tags",
			"description": "List the vault's tags with how many notes carry each, most used first, then by name. Tags come normalized the way the app shows them (lowercase, no #, spaces as '-'): reuse them when tagging instead of inventing near-duplicates. Optionally only one folder and its subfolders; trashed notes are not counted.",
			"inputSchema": {"type": "object", "properties": {
				"folder": {"type": "string", "description": "Folder inside the vault, e.g. \"Physics\". Empty = whole vault."},
			}},
			"annotations": {"readOnlyHint": true, "openWorldHint": false},
		},
		{
			"name": "get_progress",
			"title": "Quiz progress",
			"description": "The learner's quiz results, per note: each quiz's best score (`score`), latest score (`last`), `total` and whether it is `passed` (two thirds right), and the questions whose latest answer was wrong (`missed`), each with its `learn` target: the note to review. Quizzes are numbered from 0 in note order. Read-only.",
			"inputSchema": {"type": "object", "properties": {
				"note": {"type": "string", "description": "Only this note: its title (any case) or its path as list_notes gives it. Empty = every note with results."},
			}},
			"annotations": {"readOnlyHint": true, "openWorldHint": false},
		},
		{
			"name": "get_journey",
			"title": "Learning Journey",
			"description": "The Learning Journey: topics → learning objectives (`goal` fluent / learning / forget, and whether it is `met`) → demonstrations, the quizzes and flashcard decks that show each one (`activity` is \"<note title>#quiz<i>\" or \"<note title>#cards<i>\", counted from 0 in note order), each with `done` (its latest score meets the goal), `attempts` and its `latest` log entry; and every logged score (`log`). The shape is journey.json's (learning-objectives protocol, `version` 1) with those status fields added. Read-only.",
			"inputSchema": {"type": "object", "properties": {}},
			"annotations": {"readOnlyHint": true, "openWorldHint": false},
		},
	]


func has_tool(name: String) -> bool:
	return name in ["list_notes", "read_note", "create_note", "update_note", "delete_note", "move_note", "search_notes", "get_note_guide", "list_tags", "get_progress", "get_journey"]


## Run a tool. Always returns an MCP CallToolResult; failures come back with
## isError = true and a structured {error: {code, message}} body.
func call_tool(name: String, args: Dictionary) -> Dictionary:
	if name == "get_note_guide":
		return get_note_guide(args)  # ships with the app: needs no vault
	if not DirAccess.dir_exists_absolute(vault):
		return _fail("no_vault", "Vault folder does not exist: " + vault)
	var r: Dictionary
	match name:
		"list_notes": r = list_notes(args)
		"read_note": r = read_note(args)
		"create_note": r = create_note(args)
		"update_note": r = update_note(args)
		"delete_note": r = delete_note(args)
		"move_note": r = move_note(args)
		"search_notes": r = search_notes(args)
		"list_tags": r = list_tags(args)
		"get_progress": r = get_progress(args)
		"get_journey": r = get_journey(args)
		_: return _fail("unknown_tool", "Unknown tool: " + name)
	return r


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

func list_notes(args: Dictionary) -> Dictionary:
	var folder: Variant = _clean_folder(args.get("folder", ""))
	if folder == null:
		return _fail("invalid_path", "Bad folder: " + str(args.get("folder")))
	var page: Dictionary = _page_args(args)
	if page.has("error"):
		return page.error
	var folders: Array = []
	var out: Dictionary = _page(_entries(folder, folders), page)
	if page.after.is_empty():
		out["folders"] = folders   # the tree once, on the first page
	return _ok(out)


func read_note(args: Dictionary) -> Dictionary:
	var rel: Variant = _clean_note_path(args.get("path"))
	if rel == null:
		return _fail("invalid_path", "Bad note path: " + str(args.get("path")))
	if not FileAccess.file_exists(vault + rel):
		return _fail("not_found", "No note at " + rel)
	if rel.ends_with(".txt"):
		# A raw text file has no fields; the app never lists or edits it.
		var t: Dictionary = _read_text(rel)
		var txt: Dictionary = {
			"path": rel, "format": "text",
			"title": rel.get_file().trim_suffix(".txt"),
			"folder": rel.get_base_dir(), "tags": [], "created": "", "modified": "",
			"starred_at": "", "pinned_at": "",
			"markdown": t.text, "encoding": t.encoding, "editable": t.editable,
			"hash": file_hash(rel),
		}
		if not t.editable:
			txt["warning"] = NOT_UTF8_WARNING
		return _ok(txt)
	var n: ContentLayer = _load(rel)
	if n == null:
		return _not_a_note(rel)
	var out: Dictionary = _summary(rel, n)
	out["format"] = "tres"
	out["markdown"] = n.raw_text
	out["editable"] = true
	out["hash"] = file_hash(rel)
	if args.get("raw", false) == true:
		out["raw"] = FileAccess.get_file_as_string(vault + rel)
	return _ok(out)


func create_note(args: Dictionary) -> Dictionary:
	var title: Variant = args.get("title")
	if not (title is String) or _title_arg(title) == "":
		return _fail("invalid_arguments", "create_note needs a non-empty title")
	var folder: Variant = _clean_folder(args.get("folder", ""))
	if folder == null:
		return _fail("invalid_path", "Bad folder: " + str(args.get("folder")))
	var bad: String = _check_fields(args)
	if bad != "":
		return _fail("invalid_arguments", bad)
	var fmt: String = str(args.get("format", "tres"))
	if fmt != "tres" and fmt != "text":
		return _fail("invalid_arguments", "format must be \"tres\" or \"text\"")
	var stem: String = VaultStore.filename_stem(_no_bom(title))
	var file: String = stem + ".txt" if fmt == "text" else stem + ".tres"
	var rel: String = (folder as String).path_join(file) if folder != "" else file
	# A link at rel that leads nowhere yet passes file_exists, and the save
	# would follow it (VaultStore._resolve_links): out of the vault, maybe.
	if not _safe_rel(rel):
		return _fail("invalid_path", "Bad note path: " + rel + " (a link there leads out of the vault or into a hidden folder)", {"path": rel})
	if FileAccess.file_exists(vault + rel):
		return _fail("exists", "A note file already exists at " + rel + "; read it and use update_note, or pick another title", {"path": rel})
	if folder != "":
		DirAccess.make_dir_recursive_absolute(vault + folder)
	var err: String
	if fmt == "text":
		err = _atomic_write_text(str(args.get("markdown", "")), rel, true)
		if err != "":
			return _fail("write_failed", err)
		_changed("create", rel)
		return _ok({"path": rel, "format": "text", "title": stem.trim_suffix(".txt"), "hash": file_hash(rel),
				"warnings": lint_warnings(stem, str(args.get("markdown", "")))})
	var n := ContentLayer.new()
	n.title = _title_arg(title)
	n.raw_text = _no_bom(str(args.get("markdown", "")))
	n.tags = _tags(args.get("tags", []))
	n.structure = {}
	n.created = Time.get_datetime_string_from_system()
	n.modified = n.created
	err = _atomic_save(n, rel, true)
	if err != "":
		return _fail("write_failed", err)
	_changed("create", rel)
	return _ok({"path": rel, "format": "tres", "title": n.title, "hash": file_hash(rel), "warnings": lint_warnings(n.title, n.raw_text)})


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
	var refusal: Dictionary = _update_refusal(rel, args)
	if not refusal.is_empty():
		return refusal
	var old: Dictionary = _fields(rel)
	var new: Dictionary = {
		"title": _title_arg(args.title) if args.has("title") else old.title,
		"markdown": (_no_bom(str(args.markdown)) if rel.ends_with(".tres") else str(args.markdown)) if args.has("markdown") else old.markdown,
		"tags": Array(_tags(args.tags)) if args.has("tags") else old.tags,
	}
	return _confirmed(rel, args.hash, update_prompt(rel, old, new), "Save the change", _write_update.bind(rel, args))


## Why update_note can't make this edit, as the refusal to return, or {}.
func _update_refusal(rel: String, args: Dictionary) -> Dictionary:
	if rel.ends_with(".tres"):
		var n: ContentLayer = _load(rel)
		if n == null:
			return _not_a_note(rel)
		if not args.has("title"):
			return {}
		var title: String = _title_arg(args.title)
		if title == "":
			return _fail("invalid_arguments", "title cannot be empty")
		# A taken title is refused before anyone is asked to confirm.
		return _title_refusal(_scan_notes(rel, n), n, title) if title != n.title else {}
	# A .txt file is raw text: only its body can change.
	if args.has("title") or args.has("tags"):
		return _fail("invalid_arguments", "A .txt note has no title or tags: only markdown can be edited")
	if not args.has("markdown"):
		return _fail("invalid_arguments", "A .txt note can only be edited through markdown (it has no title or tags)")
	# The hash matched, so these are the bytes the client read. If they are
	# not UTF-8, what it read was a lossy decoding: writing that back would
	# replace the original characters for good.
	var cur: Dictionary = _read_text(rel)
	if not cur.editable:
		return _fail("not_utf8", rel + " is not UTF-8 text (" + cur.encoding + "), so update_note leaves it as it is: rewriting it from the decoded text would lose characters. Convert the file to UTF-8 outside the server first.",
				{"path": rel, "encoding": cur.encoding})
	return {}


## update_note's write, once _update_refusal passed and the hash matched.
func _write_update(rel: String, args: Dictionary) -> Dictionary:
	if not rel.ends_with(".tres"):
		var bom: bool = _read_text(rel).encoding == "utf-8-bom"
		var err: String = _atomic_write_text(str(args.markdown), rel, false, bom)
		if err != "":
			return _fail("write_failed", err)
		_changed("update", rel)
		return _ok({"path": rel, "format": "text", "hash": file_hash(rel), "warnings": lint_warnings(rel.get_file().trim_suffix(".txt"), str(args.markdown))})
	var n: ContentLayer = _load(rel)
	if n == null:
		return _not_a_note(rel)
	if args.has("title"):
		var title: String = _title_arg(args.title)
		if title != n.title:
			return _update_renaming(rel, n, title, args)
	if args.has("markdown"):
		n.raw_text = _no_bom(str(args.markdown))
	if args.has("tags"):
		n.tags = _tags(args.tags)
	n.modified = Time.get_datetime_string_from_system()
	var err: String = _atomic_save(n, rel, false)
	if err != "":
		return _fail("write_failed", err)
	_changed("update", rel)
	return _ok({"path": rel, "format": "tres", "title": n.title, "hash": file_hash(rel), "warnings": lint_warnings(n.title, n.raw_text)})


## update_note's refusal ("exists") when a note in `scan` (_scan_notes) other
## than `n` has `title`, by VaultStore's rule (title_holder_in); {} otherwise.
func _title_refusal(scan: Dictionary, n: ContentLayer, title: String) -> Dictionary:
	var holder: ContentLayer = VaultStore.title_holder_in(scan.notes, title, n)
	if holder == null:
		return {}
	var at: String = scan.rels[holder]
	return _fail("exists", "A note named \u201c%s\u201d already exists (%s); pick another title" % [holder.title, at], {"path": at})


## update_note with a new title, by the app's rules (VaultStore.rename_note +
## RenameCascade). Nothing is written when the title is taken. The note is
## saved, then its file renamed; then the cascade rewrites the other notes,
## each only if its file still has the bytes this rename scanned.
func _update_renaming(rel: String, n: ContentLayer, new_title: String, args: Dictionary) -> Dictionary:
	var scan: Dictionary = _scan_notes(rel, n)
	var taken: Dictionary = _title_refusal(scan, n, new_title)   # again: the vault may have changed while the user confirmed
	if not taken.is_empty():
		return taken
	var old_title: String = n.title
	n.title = new_title
	if args.has("markdown"):
		n.raw_text = _no_bom(str(args.markdown))
	if args.has("tags"):
		n.tags = _tags(args.tags)
	# Its references to itself, as run() rewrites the other notes': [[links]]
	# and quiz lines each where they can follow (run() warns of those left).
	var links: bool = RenameCascade.links_follow(old_title, new_title)
	var lines: bool = RenameCascade.lines_follow(old_title, new_title)
	if links or lines:
		n.raw_text = RenameCascade.rewrite(n.raw_text, n, new_title, RenameCascade.index_before(scan.notes, n, old_title), links, lines).text
	n.modified = Time.get_datetime_string_from_system()
	var err: String = _atomic_save(n, rel, false)
	if err != "":
		return _fail("write_failed", err)
	var warnings: Array = []
	var new_rel: String = _title_file(rel, new_title)
	if new_rel != rel and DirAccess.rename_absolute(vault + rel, vault + new_rel) != OK:
		warnings.append(_warning(rel, "Couldn't rename %s to %s; the note keeps its old file name" % [rel, new_rel]))
		new_rel = rel
	scan.rels[n] = new_rel
	_changed("rename" if new_rel != rel else "update", new_rel)

	var changed: Array = []
	var write: Callable = func(note: ContentLayer, text: String) -> String:
		if note == n:
			# Its own links were rewritten before its save. A case-only rename
			# finds them again, but its hash is no longer the scanned one.
			return ""
		var path: String = scan.rels[note]
		if file_hash(path) != scan.hashes[note]:
			return "%s changed while the rename ran, so its references to \u201c%s\u201d were left as they are; read it and update them" % [path, old_title]
		note.raw_text = text
		var why: String = _atomic_save(note, path, false)
		if why != "":
			return why
		changed.append(path)
		_changed("update", path)
		return ""
	var own_stores: bool = _stores_are_this_vaults()
	if own_stores:
		# The server is its own process: read the files the app may have
		# written since this process last did, so nothing of the app's is lost.
		ProgressStore.invalidate()
		JourneyStore.invalidate()
	else:
		warnings.append(_warning("", "Journey and progress keys were not moved: this process's stores belong to another vault"))
	var report: Dictionary = RenameCascade.run(scan.notes, n, old_title, new_title, write, false, own_stores)
	for w in report.warnings:
		warnings.append(_warning(scan.rels.get(w.note, ""), str(w.message)))
	return _ok({"path": new_rel, "renamed_from": rel, "format": "tres", "title": n.title, "hash": file_hash(new_rel), "changed": changed, "warnings": lint_warnings(n.title, n.raw_text) + warnings})


func delete_note(args: Dictionary) -> Dictionary:
	var rel: Variant = _clean_note_path(args.get("path"))
	if rel == null:
		return _fail("invalid_path", "Bad note path: " + str(args.get("path")))
	var gate: Dictionary = _hash_gate(rel, args.get("hash"))
	if not gate.is_empty():
		return gate
	var refusal: Dictionary = _trash_refusal(rel)
	if not refusal.is_empty():
		return refusal
	return _confirmed(rel, args.hash, delete_prompt(rel, _fields(rel).title), "Move to trash", _trash.bind(rel))


## delete_note's refusal ("invalid_path") when the trash folder the note at
## `rel` goes to (.trash/<its folder>) leads out of .trash through a link,
## out of the vault maybe; {} otherwise.
func _trash_refusal(rel: String) -> Dictionary:
	var dir: String = TRASH_DIR.path_join(rel).get_base_dir()
	var real: Variant = VaultStore._real_rel(vault, dir)
	if real is String and ((real as String) + "/").begins_with(TRASH_DIR + "/"):
		return {}
	return _fail("invalid_path", "%s leads out of the vault's trash through a link, so %s was not moved there; nothing was changed" % [dir, rel], {"path": rel})


## delete_note's move into the trash, once the hash matched.
func _trash(rel: String) -> Dictionary:
	var refusal: Dictionary = _trash_refusal(rel)   # again: links may have changed while the user confirmed
	if not refusal.is_empty():
		return refusal
	var dest_rel: String = TRASH_DIR.path_join(rel)
	if FileAccess.file_exists(vault + dest_rel):
		# Keep the earlier trashed copy too: never overwrite inside the trash.
		var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
		var ext: String = "." + rel.get_extension().to_lower()
		var base: String = TRASH_DIR.path_join(rel).get_basename() + " (deleted " + stamp
		dest_rel = base + ")" + ext
		var i: int = 2
		while FileAccess.file_exists(vault + dest_rel):
			dest_rel = "%s %d)" % [base, i] + ext
			i += 1
	DirAccess.make_dir_recursive_absolute(vault + dest_rel.get_base_dir())
	if DirAccess.rename_absolute(vault + rel, vault + dest_rel) != OK:
		return _fail("write_failed", "Could not move " + rel + " to the trash")
	_changed("delete", rel)
	return _ok({"path": rel, "trashed_to": dest_rel})


## Move a note's file into another folder with one rename (atomic on one
## filesystem), so every field in it survives. The app sees the move through
## its disk poll; an autosave of that note pending meanwhile finds its file
## gone and saves the typing as a conflict copy instead of writing the old
## path again (VaultStore.save_note). See mcp/README.md, "Working alongside
## the open app".
func move_note(args: Dictionary) -> Dictionary:
	var rel: Variant = _clean_note_path(args.get("path"))
	if rel == null:
		return _fail("invalid_path", "Bad note path: " + str(args.get("path")))
	if not (args.get("folder") is String):
		return _fail("invalid_arguments", "move_note needs a folder (\"\" = top level)")
	var folder: Variant = _clean_folder(args.folder)
	if folder == null:
		return _fail("invalid_path", "Bad folder: " + str(args.folder))
	var gate: Dictionary = _hash_gate(rel, args.get("hash"))
	if not gate.is_empty():
		return gate
	var file: String = (rel as String).get_file()
	var dest_rel: String = (folder as String).path_join(file) if folder != "" else file
	if dest_rel == rel:
		return _ok({"path": rel, "from": rel, "hash": args.hash, "moved": false})
	if FileAccess.file_exists(vault + dest_rel):
		return _fail("exists", "A file named " + file + " is already in " + (folder if folder != "" else "the top level") + "; rename one of them first", {"path": dest_rel})
	if folder != "":
		DirAccess.make_dir_recursive_absolute(vault + folder)
	if DirAccess.rename_absolute(vault + rel, vault + dest_rel) != OK:
		return _fail("write_failed", "Could not move " + rel + " to " + dest_rel)
	_changed("move", dest_rel)
	return _ok({"path": dest_rel, "from": rel, "hash": file_hash(dest_rel), "moved": true})


func search_notes(args: Dictionary) -> Dictionary:
	var folder: Variant = _clean_folder(args.get("folder", ""))
	if folder == null:
		return _fail("invalid_path", "Bad folder: " + str(args.get("folder")))
	var q: String = _filter(args, "query").to_lower()
	var tq: String = _filter(args, "title").to_lower()
	var tag: String = TagOps.normalize(_filter(args, "tag"))
	var page: Dictionary = _page_args(args)
	if page.has("error"):
		return page.error
	var hits: Array = []
	for rel in _scan(folder, []):
		if (rel as String).ends_with(".txt"):
			# A raw .txt has no tags: a tag search never matches one.
			if tag != "":
				continue
			var body: String = _read_text(rel).text
			var stem_l: String = rel.get_file().trim_suffix(".txt").to_lower()
			if tq != "" and not stem_l.contains(tq):
				continue
			var hit: Dictionary = _text_summary(rel)
			if q != "":
				var at: int = body.to_lower().find(q)
				if not stem_l.contains(q) and at < 0:
					continue
				hit["matched"] = "title" if stem_l.contains(q) else "content"
				if at >= 0:
					var from: int = maxi(0, at - SNIPPET_CHARS / 2)
					hit["snippet"] = body.substr(from, SNIPPET_CHARS).replace("\n", " ")
			hits.append(hit)
			continue
		var n: ContentLayer = _load(rel)
		if n == null:
			continue
		var title_l: String = n.title.to_lower()
		if tq != "" and not title_l.contains(tq):
			continue
		if tag != "" and not TagOps.has(n, tag):
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
	return _ok(_page(hits, page))


## A search_notes filter's text, trimmed: "" when it is absent or null (a
## client that fills every optional field sends null for one it doesn't
## use; str(null) is "<null>", which no note matches).
static func _filter(args: Dictionary, key: String) -> String:
	var v: Variant = args.get(key)
	return "" if v == null else str(v).strip_edges()


## The markup guide (or one topic of it). The result's text is the Markdown
## itself, not JSON, so the client's model reads it as written.
func get_note_guide(args: Dictionary) -> Dictionary:
	var t: Variant = args.get("topic", "")
	if t != null and not (t is String):
		return _fail("invalid_arguments", "topic must be a string")
	var topic: String = "" if t == null else (t as String).strip_edges().to_lower()
	if topic != "" and not GUIDE_TOPICS.has(topic):
		return _fail("invalid_arguments", "topic must be one of: " + ", ".join(PackedStringArray(GUIDE_TOPICS.keys())))
	var guide: String = FileAccess.get_file_as_string(GUIDE_PATH)
	if guide == "":
		return _fail("no_guide", "The markup guide is missing from this build (" + GUIDE_PATH + ")")
	var text: String = guide if topic == "" else guide_topic(guide, topic)
	return _ok_text(text, {"topic": topic, "topics": GUIDE_TOPICS.keys(), "guide": text})


## The sections of `guide` that make up `topic` (see GUIDE_TOPICS), joined by
## a blank line. A section whose heading is missing is left out.
static func guide_topic(guide: String, topic: String) -> String:
	var lines: PackedStringArray = guide.split("\n")
	var heads: Array = _guide_headings(lines)
	var parts: PackedStringArray = []
	for want in GUIDE_TOPICS.get(topic, []):
		var part: String = _guide_section(lines, heads, want[0], want[1])
		if part != "":
			parts.append(part)
	return "\n\n".join(parts) + "\n"


## One section: from the first heading starting with `prefix` to the next
## heading at its level or above (`whole`), or to the very next heading.
static func _guide_section(lines: PackedStringArray, heads: Array, prefix: String, whole: bool) -> String:
	for k in heads.size():
		var h: Dictionary = heads[k]
		if not (h.text as String).begins_with(prefix):
			continue
		var end: int = lines.size()
		for j in range(k + 1, heads.size()):
			if not whole or heads[j].level <= h.level:
				end = heads[j].line
				break
		return "\n".join(lines.slice(h.line, end)).strip_edges()
	return ""


## The guide's Markdown headings outside code fences, as
## {line, level, text} with `text` lowercased. Fences close the way
## layer_engine closes them: a line of at least as many backticks.
static func _guide_headings(lines: PackedStringArray) -> Array:
	var out: Array = []
	var fence: int = 0
	for i in lines.size():
		var s: String = lines[i].strip_edges()
		var ticks: int = 0
		while ticks < s.length() and s[ticks] == "`":
			ticks += 1
		if fence > 0:
			if ticks >= fence and s.substr(ticks).strip_edges() == "":
				fence = 0
			continue
		if ticks >= 3:
			fence = ticks
			continue
		var line: String = lines[i]
		var level: int = line.length() - line.lstrip("#").length()
		if level > 0 and line.substr(level).begins_with(" "):
			out.append({"line": i, "level": level, "text": line.substr(level).strip_edges().to_lower()})
	return out


# ---------------------------------------------------------------------------
# Confirmations: asking the user (MCP elicitation) before a destructive write
# ---------------------------------------------------------------------------

## Run `apply` (the write → its CallToolResult) once the user confirms, or
## right away when there is nobody to ask (_asker). When it asks, the result
## is {"pending": true} and the protocol answers the tools/call with what
## _after_answer returns, unless the client cancelled the call meanwhile:
## then nothing is written.
func _confirmed(rel: String, expected_hash: String, message: String, label: String, apply: Callable) -> Dictionary:
	var proto: Object = _asker()
	if proto == null:
		return apply.call()
	var call_id: Variant = proto.current_call_id
	var ref: WeakRef = _protocol
	proto.send_request("elicitation/create", confirm_request(message, label), func(reply: Dictionary) -> void:
		var p: Object = ref.get_ref()
		if p != null and p.is_call_pending(call_id):
			p.complete(call_id, _after_answer(reply, rel, expected_hash, apply)))
	return {"pending": true}


## The protocol to ask the user through, or null when this call writes
## without asking: confirm_writes off, no protocol, not inside a tools/call
## (the app calling the tools itself), or a client without elicitation.
func _asker() -> Object:
	if not confirm_writes or _protocol == null:
		return null
	var proto: Object = _protocol.get_ref()
	if proto == null or proto.current_call_id == null or not (proto.client_capabilities as Dictionary).has("elicitation"):
		return null
	return proto


## What the client's answer to a confirmation leads to: the write, after the
## hash is checked again (the note may have changed while the user decided),
## or the refusal ("declined", or "not_confirmed" when no answer came).
func _after_answer(reply: Dictionary, rel: String, expected_hash: String, apply: Callable) -> Dictionary:
	if reply.has("error"):
		var e: Dictionary = reply.error if reply.error is Dictionary else {}
		return _fail("not_confirmed", "Ontomeme could not get the user's confirmation (%s), so %s was not changed." % [str(e.get("message", "no answer")), rel], {"path": rel})
	var answer: Dictionary = reply.result if reply.get("result") is Dictionary else {}
	var action: String = str(answer.get("action", ""))
	var content: Dictionary = answer.content if answer.get("content") is Dictionary else {}
	if action != "accept" or not (content.get("confirm") is bool and content.confirm):
		var why: String = {"decline": "The user declined", "cancel": "The user dismissed the prompt", "accept": "The user did not tick the confirmation"}.get(action, "The client answered without a decision")
		return _fail("declined", "%s, so %s was not changed. Don't retry unless the user asks." % [why, rel], {"path": rel, "action": action})
	var gate: Dictionary = _hash_gate(rel, expected_hash)
	if not gate.is_empty():
		return gate
	return apply.call()


## elicitation/create params: `message`, and one required boolean, confirm,
## labelled `label`.
static func confirm_request(message: String, label: String) -> Dictionary:
	return {
		"message": message,
		"requestedSchema": {
			"type": "object",
			"properties": {"confirm": {"type": "boolean", "title": label}},
			"required": ["confirm"],
		},
	}


static func delete_prompt(rel: String, title: String) -> String:
	return "Move \"%s\" (%s) to the trash?" % [title, rel]


## The update_note prompt: what changes from `old` to `new` (each {title,
## markdown, tags}): the title, the body as +N / -M lines with the first
## changed lines, and the tags added (+) and removed (-).
static func update_prompt(rel: String, old: Dictionary, new: Dictionary) -> String:
	var out: PackedStringArray = ["Save this change to \"%s\" (%s)?" % [old.title, rel]]
	if new.title != old.title:
		out.append("Title: \"%s\" → \"%s\"" % [old.title, new.title])
	var body: Dictionary = line_changes(old.markdown, new.markdown)
	if body.added > 0 or body.removed > 0:
		out.append("Body: +%d / -%d lines" % [body.added, body.removed])
		out.append_array(body.shown)
	elif new.markdown != old.markdown:
		out.append("Body: lines moved, none added or removed")
	else:
		out.append("Body: unchanged")
	var tags: PackedStringArray = []
	for t in new.tags:
		if not (t in old.tags):
			tags.append("+" + str(t))
	for t in old.tags:
		if not (t in new.tags):
			tags.append("-" + str(t))
	if not tags.is_empty():
		out.append("Tags: " + ", ".join(tags))
	return "\n".join(out)


## How `new_text` differs from `old_text` by lines: {added, removed, shown}.
## The lines both share at the start and at the end are skipped; in between,
## each copy of a line in one side matches one copy in the other, so an edit
## counts only the lines it touched and a moved line counts as neither.
## `shown`: the first PROMPT_LINES removed lines ("- "), then the first added
## ones ("+ "), each cut to PROMPT_LINE_CHARS, with a count of any more.
static func line_changes(old_text: String, new_text: String) -> Dictionary:
	var a: PackedStringArray = PackedStringArray() if old_text == "" else old_text.split("\n")
	var b: PackedStringArray = PackedStringArray() if new_text == "" else new_text.split("\n")
	var start: int = 0
	while start < a.size() and start < b.size() and a[start] == b[start]:
		start += 1
	var end_a: int = a.size()
	var end_b: int = b.size()
	while end_a > start and end_b > start and a[end_a - 1] == b[end_b - 1]:
		end_a -= 1
		end_b -= 1
	var removed: PackedStringArray = _unmatched(a.slice(start, end_a), b.slice(start, end_b))
	var added: PackedStringArray = _unmatched(b.slice(start, end_b), a.slice(start, end_a))
	var shown: PackedStringArray = []
	for side in [["- ", removed, "removed"], ["+ ", added, "added"]]:
		var lines: PackedStringArray = side[1]
		for l in lines.slice(0, PROMPT_LINES):
			shown.append(side[0] + (l if l.length() <= PROMPT_LINE_CHARS else l.left(PROMPT_LINE_CHARS - 1) + "…"))
		if lines.size() > PROMPT_LINES:
			shown.append("  (%d more %s)" % [lines.size() - PROMPT_LINES, side[2]])
	return {"added": added.size(), "removed": removed.size(), "shown": shown}


## The lines of `lines`, in order, left over once each line of `other` has
## matched one equal line.
static func _unmatched(lines: PackedStringArray, other: PackedStringArray) -> PackedStringArray:
	var left: Dictionary = {}
	for l in other:
		left[l] = int(left.get(l, 0)) + 1
	var out: PackedStringArray = []
	for l in lines:
		if int(left.get(l, 0)) > 0:
			left[l] -= 1
		else:
			out.append(l)
	return out


# ---------------------------------------------------------------------------
# Resources: every note, read-only, as ontomeme://note/<path>
# ---------------------------------------------------------------------------
# Failures come back as {error: {code, message}}; McpProtocol turns the code
# into a JSON-RPC error (invalid_* → -32602, not_found → -32002).

## One page of resources (the notes list_notes lists, in its order) as
## {resources, nextCursor?}. `cursor` is a nextCursor from an earlier page.
func list_resources(cursor: String = "") -> Dictionary:
	if not DirAccess.dir_exists_absolute(vault):
		return _resource_error("no_vault", "Vault folder does not exist: " + vault)
	var page: Dictionary = _page_args({"cursor": cursor})
	if page.has("error"):
		return _resource_error("invalid_arguments", page.error.structuredContent.error.message)
	var listed: Dictionary = _page(_entries("", []), page)
	var out: Dictionary = {"resources": listed.notes.map(_resource)}
	if listed.has("next_cursor"):
		out["nextCursor"] = listed.next_cursor
	return out


func resource_templates() -> Array:
	return [{
		"uriTemplate": NOTE_URI + "{path}",
		"name": "note",
		"title": "Ontomeme note",
		"description": "A note's Markdown body, by its path inside the vault as list_notes returns it, percent-encoded (\"/\" as %2F): " + note_uri("Physics/note_waves.tres") + ". Read-only: edit notes with the tools.",
		"mimeType": NOTE_MIME,
	}]


## The Markdown body of the note `uri` names, as {contents: [{uri, mimeType,
## text}]}. The raw .tres text stays a tool's job (read_note raw: true).
func read_resource(uri: String) -> Dictionary:
	var path: Variant = _uri_path(uri)
	var rel: Variant = _clean_note_path(path) if path != null else null
	if rel == null:
		return _resource_error("invalid_uri", "Not a note URI of this vault (" + NOTE_URI + "<percent-encoded path>): " + uri)
	if not DirAccess.dir_exists_absolute(vault):
		return _resource_error("no_vault", "Vault folder does not exist: " + vault)
	if not FileAccess.file_exists(vault + rel):
		return _resource_error("not_found", "No note at " + rel)
	var body: String
	if rel.ends_with(".txt"):
		body = _read_text(rel).text
	else:
		var n: ContentLayer = _load(rel)
		if n == null:
			return _resource_error("not_found", rel + " is not an Ontomeme note")
		body = n.raw_text
	return {"contents": [{"uri": uri, "mimeType": NOTE_MIME, "text": body}]}


## The resource URI of the note at `rel`.
static func note_uri(rel: String) -> String:
	return NOTE_URI + rel.uri_encode()


## The path a note URI carries, percent-decoded, or null when `uri` is not
## NOTE_URI + a path or has a malformed %-escape. Strict RFC 3986 decoding,
## not String.uri_decode (which turns "+" into a space and drops a "%" before
## lowercase hex).
static func _uri_path(uri: String) -> Variant:
	if not uri.begins_with(NOTE_URI):
		return null
	var parts: PackedStringArray = uri.substr(NOTE_URI.length()).split("%")
	var bytes: PackedByteArray = parts[0].to_utf8_buffer()
	for k in range(1, parts.size()):
		var esc: String = parts[k].left(2)
		if esc.length() < 2 or not (_is_hex_digit(esc[0]) and _is_hex_digit(esc[1])):
			return null
		bytes.append(esc.hex_to_int())
		bytes.append_array(parts[k].substr(2).to_utf8_buffer())
	var path: String = bytes.get_string_from_utf8()
	return path if path.to_utf8_buffer() == bytes else null


static func _is_hex_digit(c: String) -> bool:
	return "0123456789abcdefABCDEF".contains(c)


## The resources/list entry for a list entry.
func _resource(entry: Dictionary) -> Dictionary:
	return {"uri": note_uri(entry.path), "name": entry.title, "description": entry.path, "mimeType": NOTE_MIME}


static func _resource_error(code: String, message: String) -> Dictionary:
	return {"error": {"code": code, "message": message}}


## The vault's tags, normalized as the app shows them, each with how many
## notes under `folder` carry it: {tags: [{tag, count}], total}, most used
## first, then by name (TagOps.sort_by_use, the TAGS sidebar's order).
## Only .tres notes carry tags; _scan skips .trash and the hidden folders.
func list_tags(args: Dictionary) -> Dictionary:
	var folder: Variant = _clean_folder(args.get("folder", ""))
	if folder == null:
		return _fail("invalid_path", "Bad folder: " + str(args.get("folder")))
	var notes: Array = []
	for rel in _scan(folder, []):
		var n: ContentLayer = _load(rel) if (rel as String).ends_with(".tres") else null
		if n != null:
			notes.append(n)
	var counts: Dictionary = TagOps.counts(notes)
	var names: Array = counts.keys()
	TagOps.sort_by_use(names, counts)
	var tags: Array = names.map(func(t: String) -> Dictionary: return {"tag": t, "count": int(counts[t])})
	return _ok({"tags": tags, "total": tags.size()})


# ---------------------------------------------------------------------------
# Learning: quiz progress and the Learning Journey (read-only)
# ---------------------------------------------------------------------------

## Quiz results per note, from the vault's progress.json, read without
## writing anything (ProgressStore.read_progress): [{note, path, quizzes:
## [{quiz, passed, score (best), last, total}], missed: [{quiz, question, q,
## learn}]}]. A note no longer in the vault keeps its results, with path "".
func get_progress(args: Dictionary) -> Dictionary:
	var want: Variant = _progress_note(args.get("note"))
	if want is Dictionary:
		return want   # refused
	var p: String = ProgressStore.path_in(vault)
	var file: Dictionary = ProgressStore.read_progress(p)
	if file.state in ["unreadable", "cant_open"]:
		return _unreadable(file.state, p, "quiz progress")
	var notes: Dictionary = {}   # lowercased title → its entry
	for k in file.data.quizzes:
		var key: Dictionary = ProgressStore.parse_key(str(k), false)
		var r: Variant = file.data.quizzes[k]
		if not key.is_empty() and r is Dictionary and (want == "" or key.note == want):
			_progress_entry(notes, key.note).quizzes.append({
				"quiz": key.quiz, "passed": r.get("passed") is bool and r.passed, "score": _count(r.get("best")),
				"last": _count(r.get("last", r.get("best"))), "total": _count(r.get("total")),
			})
	for k in file.data.questions:
		var key: Dictionary = ProgressStore.parse_key(str(k), true)
		var r: Variant = file.data.questions[k]
		if key.is_empty() or not r is Dictionary or (want != "" and key.note != want):
			continue
		var entry: Dictionary = _progress_entry(notes, key.note)
		if r.get("from") is String and str(r.from).strip_edges() != "":
			entry["note"] = str(r.from).strip_edges()   # the title as written, not lowercased
		if r.get("right") is bool and not r.right:
			entry.missed.append({"quiz": key.quiz, "question": key.question, "q": str(r.get("q", "")), "learn": str(r.get("learn", ""))})
	var in_vault: Dictionary = _notes_by_title() if not notes.is_empty() else {}
	for lower in notes:
		var entry: Dictionary = notes[lower]
		var found: Dictionary = in_vault.get(lower, {})
		entry["note"] = found.get("title", entry.note)
		entry["path"] = found.get("path", "")
		entry.quizzes.sort_custom(func(a, b): return a.quiz < b.quiz)
		entry.missed.sort_custom(func(a, b): return a.quiz < b.quiz or (a.quiz == b.quiz and a.question < b.question))
	var out: Array = notes.values()
	out.sort_custom(func(a, b): return str(a.note).naturalnocasecmp_to(str(b.note)) < 0)
	return _ok({"notes": out, "count": out.size()})


## The Learning Journey from the vault's journey.json, read without writing
## anything (JourneyStore.read_journey): the protocol's shape, sanitized as
## the app reads it, with each objective's and demo's status added. When
## the sanitize pass left entries out, broken_entries says how many.
func get_journey(_args: Dictionary) -> Dictionary:
	var p: String = JourneyStore.path_in(vault)
	var file: Dictionary = JourneyStore.read_journey(p)
	if file.state in ["unreadable", "cant_open"]:
		return _unreadable(file.state, p, "Learning Journey")
	var out: Dictionary = file.data
	for t in out.topics:
		for o in t.objectives:
			_add_status(o)
	if file.broken > 0:
		out["broken_entries"] = file.broken
	return _ok(out)


## What the Journey tab shows about objective `o`, added to it: met (its
## goal is reached: never for Forget, which has none), attempts, best (0..1,
## null before any score); and on each demo: done (its latest score meets
## the goal), attempts, latest (its latest log entry, or null).
static func _add_status(o: Dictionary) -> void:
	var s: Dictionary = JourneyStore.summary(o)
	var aims: bool = o.goal != "forget"
	o["met"] = aims and s.met
	o["attempts"] = s.attempts
	o["best"] = s.best if s.best >= 0.0 else null
	for d in o.demos:
		d["done"] = aims and s.done[d.activity]
		d["attempts"] = o.log.filter(func(e: Dictionary) -> bool: return e.activity == d.activity).size()
		d["latest"] = s.latest.get(d.activity)


## The note get_progress narrows to: "" (every note), its lowercased title,
## or the refusal to return.
func _progress_note(v: Variant) -> Variant:
	if v == null:
		return ""
	if not v is String:
		return _fail("invalid_arguments", "note must be a note's title or its path")
	var s: String = (v as String).strip_edges()
	if not s.to_lower().ends_with(".tres"):
		return s.to_lower()
	var rel: Variant = _clean_note_path(s)
	if rel == null:
		return _fail("invalid_path", "Bad note path: " + s)
	var n: ContentLayer = _load(rel)
	if n == null:
		return _fail("not_found", "No note at " + rel)
	return n.title.strip_edges().to_lower()


## A score or count from the progress file (0 if it isn't a number).
static func _count(v: Variant) -> int:
	return int(v) if v is int or v is float else 0


## The entry for the note titled `lower` (lowercased), made if missing.
static func _progress_entry(notes: Dictionary, lower: String) -> Dictionary:
	if not notes.has(lower):
		notes[lower] = {"note": lower, "path": "", "quizzes": [], "missed": []}
	return notes[lower]


## Every note in the vault: lowercased, trimmed title → {title, path}.
func _notes_by_title() -> Dictionary:
	var out: Dictionary = {}
	for rel in _scan("", []):
		var n: ContentLayer = _load(rel)
		if n != null:
			out[n.title.strip_edges().to_lower()] = {"title": n.title, "path": rel}
	return out


## A progress or journey file that couldn't be read: refused, and left as
## it is (the app keeps a copy of a broken one aside when it opens the vault).
func _unreadable(state: String, p: String, what: String) -> Dictionary:
	var rel: String = p.trim_prefix(vault)
	var why: String = "couldn't be opened (a sync tool or antivirus may be holding it)" if state == "cant_open" else "couldn't be read: it isn't JSON of the expected shape"
	return _fail("unreadable", "The vault's %s file %s %s. Nothing was changed." % [what, rel, why], {"path": rel})


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## What NoteLint finds in a note body, as [{level, line, message}], checked
## against this vault: [[links]], learn: and next: against its .tres titles
## (the notes the app can link to), model: files against its models/ folder,
## image lines against its images/, objective: against its journey. Each is
## looked up only when the body needs it, and read fresh: the app may have
## changed them since.
func lint_warnings(title: String, markdown: String) -> Array:
	var cache: Dictionary = {}
	var title_exists: Callable = func(t: String) -> bool:
		if not cache.has("titles"):
			cache["titles"] = _note_titles()
		return cache.titles.has(t)
	var objective_exists: Callable = func(name: String) -> bool:
		if not cache.has("objectives"):
			cache["objectives"] = _objective_names()
		return cache.objectives.has(name.strip_edges().to_lower())
	var out: Array = []
	out.append_array(NoteLint.lint(title, markdown, title_exists, {"model_path": _model_path, "objective_exists": objective_exists, "vault": vault}))
	return out


## Every .tres note title in the vault, trimmed and lowercased → true.
func _note_titles() -> Dictionary:
	var out: Dictionary = {}
	for rel in _scan("", []):
		if (rel as String).ends_with(".tres"):
			var n: ContentLayer = _load(rel)
			if n != null:
				out[n.title.strip_edges().to_lower()] = true
	return out


## Every objective name in the vault's journey, trimmed and lowercased → true
## (JourneyStore's format: {topics: [{objectives: [{name}]}]}). Read here,
## not through JourneyStore, which caches the journey of the app's open vault.
func _objective_names() -> Dictionary:
	var out: Dictionary = {}
	var json := JSON.new()
	if not FileAccess.file_exists(vault + JOURNEY_FILE) or json.parse(FileAccess.get_file_as_string(vault + JOURNEY_FILE)) != OK or not (json.data is Dictionary):
		return out
	var topics: Variant = json.data.get("topics")
	for t in (topics if topics is Array else []):
		var objectives: Variant = t.get("objectives") if t is Dictionary else null
		for o in (objectives if objectives is Array else []):
			if o is Dictionary and o.has("name"):
				out[str(o.name).strip_edges().to_lower()] = true
	return out


## Where a note's `model: <file>` is: NoteScene3D.model_path, except that a
## bare name is in this vault's models/ folder (not the app's open vault's).
func _model_path(file: String) -> String:
	var f: String = file.strip_edges()
	if f.begins_with("~/") or f.is_absolute_path():
		return NoteScene3D.model_path(f)
	return vault.path_join("models").path_join(f)


## SHA-256 (hex) of the note file's bytes; "" if it is missing.
func file_hash(rel: String) -> String:
	return FileAccess.get_sha256(vault + rel) if FileAccess.file_exists(vault + rel) else ""


## Every note in the vault, newest first like the app's note_list, with `n`
## standing in for the file at `rel`: {notes, rels: {note: path},
## hashes: {note: hash as scanned}}. Each hash is taken before its note is
## read, so a note that changes in between fails the later gate.
func _scan_notes(rel: String, n: ContentLayer) -> Dictionary:
	var notes: Array = []
	var rels: Dictionary = {}
	var hashes: Dictionary = {}
	for path in _scan("", []):
		var hash: String = file_hash(path)
		var note: ContentLayer = n if path == rel else _load(path)
		if note == null:
			continue
		notes.append(note)
		rels[note] = path
		hashes[note] = hash
	notes.sort_custom(func(a: ContentLayer, b: ContentLayer) -> bool: return a.modified > b.modified)
	return {"notes": notes, "rels": rels, "hashes": hashes}


## The path a note at `rel` gets for `title`, as the app names it
## (VaultStore._unique_filename): the title's stem in the same folder, then
## _1, _2… when another file has it. The note's own file counts as free.
func _title_file(rel: String, title: String) -> String:
	var folder: String = rel.get_base_dir()
	var stem: String = VaultStore.filename_stem(title)
	var name: String = stem + ".tres"
	var i: int = 1
	while true:
		var path: String = folder.path_join(name) if folder != "" else name
		if path == rel or not FileAccess.file_exists(vault + path):
			return path
		name = "%s_%d.tres" % [stem, i]
		i += 1
	return rel


## True when ProgressStore and JourneyStore read this vault's .ontomeme: the
## stdio server points VaultStore at the vault it serves, as the app does.
func _stores_are_this_vaults() -> bool:
	return ProjectSettings.globalize_path(VaultStore.vault_path).simplify_path().trim_suffix("/") + "/" == vault


func _warning(rel: String, message: String) -> Dictionary:
	return {"level": "warning", "path": rel, "message": message}


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


## list_notes / search_notes paging arguments as {limit, after}: `limit`
## clamped to 1..PAGE_MAX, `after` the {modified, path} key the cursor names
## ({} = first page). Or {error: <the refusal to return>}.
func _page_args(args: Dictionary) -> Dictionary:
	var lim: Variant = args.get("limit")
	if lim == null:
		lim = PAGE_DEFAULT
	if not (lim is int or lim is float) or not is_finite(float(lim)):
		return {"error": _fail("invalid_arguments", "limit must be a number from 1 to %d" % PAGE_MAX)}
	var cur: Variant = args.get("cursor")
	if cur == null:
		cur = ""
	if not (cur is String):
		return {"error": _fail("invalid_arguments", "cursor must be the next_cursor string of an earlier page")}
	var after: Dictionary = {}
	if cur != "":
		after = decode_cursor(cur)
		if after.is_empty():
			return {"error": _fail("invalid_arguments", "This cursor is not a next_cursor list_notes or search_notes returned; leave it out to start again from the first page")}
	return {"limit": int(clampf(float(lim), 1.0, PAGE_MAX)), "after": after}


## One page of list/search entries, sorted newest modified first with the path
## as the tiebreak: {notes, count (this page), total (every entry)}, plus
## next_cursor while more entries follow. The page starts right after the
## cursor's note (whether or not that note still exists).
func _page(entries: Array, page: Dictionary) -> Dictionary:
	entries.sort_custom(_sorts_before)
	var start: int = 0 if page.after.is_empty() else entries.bsearch_custom(page.after, _sorts_before, false)
	var end: int = mini(start + int(page.limit), entries.size())
	var out: Dictionary = {"notes": entries.slice(start, end), "count": end - start, "total": entries.size()}
	if end < entries.size():
		out["next_cursor"] = encode_cursor(entries[end - 1])
	return out


## The page order: newer `modified` first (a .txt note's "" sorts last), then
## path A→Z. Every path is unique, so the order is total and pages are stable.
func _sorts_before(a: Dictionary, b: Dictionary) -> bool:
	if a.modified != b.modified:
		return a.modified > b.modified
	return a.path < b.path


## The opaque cursor for the page after `entry`: its sort key as base64 JSON.
static func encode_cursor(entry: Dictionary) -> String:
	return Marshalls.utf8_to_base64(JSON.stringify({"v": 1, "modified": entry.modified, "path": entry.path}))


## The {modified, path} key inside a cursor, or {} when it is not one
## encode_cursor made. The text is checked before it is decoded: the engine's
## base64 and JSON helpers print errors on bad input.
static func decode_cursor(cursor: String) -> Dictionary:
	if cursor.length() % 4 != 0 or RegEx.create_from_string("^[A-Za-z0-9+/]+={0,2}$").search(cursor) == null:
		return {}
	var json := JSON.new()
	if json.parse(Marshalls.base64_to_raw(cursor).get_string_from_utf8()) != OK or not (json.data is Dictionary):
		return {}
	var d: Dictionary = json.data
	if not (d.get("v") is float and d.v == 1.0 and d.get("modified") is String and d.get("path") is String):
		return {}
	return {"modified": d.modified, "path": d.path}


## A .txt note's text as {text, encoding, editable}. encoding is "utf-8",
## "utf-8-bom" (the BOM is not part of text), "utf-16" (a BOM of either byte
## order: what Windows PowerShell 5.1's `>` and Notepad's "Unicode" write) or
## "unknown" (Latin-1, CP-1252, a NUL byte...). Only UTF-8 is editable: the
## bytes must decode and re-encode to themselves. Otherwise text is a
## best-effort reading (UTF-16 decoded by its BOM, anything else with U+FFFD
## in place of the bad bytes) that must never be written back.
func _read_text(rel: String) -> Dictionary:
	var b: PackedByteArray = FileAccess.get_file_as_bytes(vault + rel)
	# 0xFF and 0xFE never occur in UTF-8, so a UTF-16 BOM settles it up front.
	if b.size() >= 2 and ((b[0] == 0xFF and b[1] == 0xFE) or (b[0] == 0xFE and b[1] == 0xFF)):
		return {"text": b.get_string_from_utf16(), "encoding": "utf-16", "editable": false}
	var bom: bool = b.size() >= 3 and b.slice(0, 3) == UTF8_BOM
	var body: PackedByteArray = b.slice(3) if bom else b
	var text: String = body.get_string_from_utf8()
	if text.to_utf8_buffer() == body:
		return {"text": text, "encoding": "utf-8-bom" if bom else "utf-8", "editable": true}
	return {"text": text, "encoding": "unknown", "editable": false}


## Write raw text to <vault>/<rel> with VaultStore.atomic_write_text, the
## app's own temp file + rename, as UTF-8 (after a BOM when `bom`, so a file
## that had one keeps it). "" on success.
func _atomic_write_text(text: String, rel: String, must_not_exist: bool, bom: bool = false) -> String:
	if must_not_exist and FileAccess.file_exists(vault + rel):
		return rel + " appeared while writing; nothing was changed"
	return _write_error(rel, VaultStore.atomic_write_text(text, vault + rel, vault, bom))


## Write `n` to <vault>/<rel> with VaultStore.atomic_save, the app's own
## temp file + rename. "" on success.
func _atomic_save(n: ContentLayer, rel: String, must_not_exist: bool) -> String:
	if must_not_exist and FileAccess.file_exists(vault + rel):
		return rel + " appeared while writing; nothing was changed"
	return _write_error(rel, VaultStore.atomic_save(n, vault + rel, vault))


## The write_failed message for VaultStore's `err`, or "" for OK. A temp file
## that did not get written in full (disk full, quota) never replaces the
## note: VaultStore checks it and removes it first. ERR_FILE_CANT_WRITE is
## also its answer when the saved file did not read back the same.
func _write_error(rel: String, err: Error) -> String:
	if err == OK:
		return ""
	var why: String = "disk full, over quota or read-only?"
	if err == ERR_FILE_CANT_WRITE:
		why = "disk full, over quota or read-only, or the saved file did not read back the same as what was sent"
	return "Could not write %s: %s (error %d; %s); nothing was changed" % [rel, error_string(err), err, why]


## True when the .tres at `path` holds every saved property of `n`
## (VaultStore.saved_matches, the check atomic_save makes before its rename).
func _saved_matches(n: ContentLayer, path: String) -> bool:
	return VaultStore.saved_matches(n, path)


## Load a note fresh from disk (never a cached copy), or null. A file that
## does not start like a note (a Godot project's material or theme) or that
## carries code (TresValidator.check_text_safe) is never handed to the loader.
func _load(rel: String) -> ContentLayer:
	if not FileAccess.file_exists(vault + rel) or not _has_note_header(rel):
		return null
	if not TresValidator.check_text_safe(vault + rel).safe:
		return null
	return ResourceLoader.load(vault + rel, "", ResourceLoader.CACHE_MODE_IGNORE) as ContentLayer


## The list entry (_summary / _text_summary) of every note under `folder`,
## unsorted; the folders found go into `folders_out`.
func _entries(folder: String, folders_out: Array) -> Array:
	var out: Array = []
	for rel in _scan(folder, folders_out):
		if (rel as String).ends_with(".txt"):
			out.append(_text_summary(rel as String))
		else:
			var n: ContentLayer = _load(rel)
			if n != null:
				out.append(_summary(rel, n))
	return out


## A note's editable fields as {title, markdown, tags}: a .txt note's title
## is its file stem and it has no tags. A .tres that doesn't load has its file
## name as title and an empty body.
func _fields(rel: String) -> Dictionary:
	if rel.ends_with(".txt"):
		return {"title": rel.get_file().trim_suffix(".txt"), "markdown": _read_text(rel).text, "tags": []}
	var n: ContentLayer = _load(rel)
	if n == null:
		return {"title": rel.get_file(), "markdown": "", "tags": []}
	return {"title": n.title, "markdown": n.raw_text, "tags": Array(n.tags)}


func _has_note_header(rel: String) -> bool:
	return VaultStore._has_note_header(VaultStore._read_head(vault + rel))


## The refusal for a file _load returned null for: "unsafe_note" when a note
## carries code, "not_a_note" otherwise.
func _not_a_note(rel: String) -> Dictionary:
	var check: Dictionary = TresValidator.check_text_safe(vault + rel)
	if not check.safe and _has_note_header(rel):
		return _fail("unsafe_note", "%s is not opened: it contains code (%s)" % [rel, check.reason], {"path": rel})
	return _fail("not_a_note", rel + " is not an Ontomeme note")


## A note's entry in list_notes / search_notes, and the head of read_note.
## starred_at / pinned_at are the app's timestamps ("" = not starred/pinned).
func _summary(rel: String, n: ContentLayer) -> Dictionary:
	return {
		"path": rel,
		"format": "tres",
		"title": n.title,
		"folder": rel.get_base_dir(),
		"tags": Array(n.tags),
		"created": n.created,
		"modified": n.modified,
		"starred_at": n.starred_at,
		"pinned_at": n.pinned_at,
	}


## The list/search entry for a raw .txt note: no fields, so title is the file
## stem and the dates, starred_at and pinned_at are empty.
func _text_summary(rel: String) -> Dictionary:
	return {
		"path": rel,
		"format": "text",
		"title": rel.get_file().trim_suffix(".txt"),
		"folder": rel.get_base_dir(),
		"tags": [],
		"created": "",
		"modified": "",
		"starred_at": "",
		"pinned_at": "",
	}


## Relative paths of every note (.tres and .txt) under `folder`, entering
## the folders the app's scan enters (VaultStore._should_descend: no hidden
## folders such as .ontomeme and .trash, nor the root asset folder), except
## that no folder link is followed, even one the app follows out of the
## vault; a note file that is a link counts only when _safe_rel allows it.
## (The app just never sees the .txt files, being .tres-only.) Folder paths
## found are appended to `folders_out`.
func _scan(folder: String, folders_out: Array) -> Array:
	var out: Array = []
	var dir := DirAccess.open(vault + folder)
	if dir == null:
		return out
	for d in dir.get_directories():
		if not VaultStore._should_descend(vault, folder, d, {}, false):
			continue
		var sub: String = folder.path_join(d) if folder != "" else d
		folders_out.append(sub)
		out.append_array(_scan(sub, folders_out))
	for f in dir.get_files():
		var rel: String = folder.path_join(f) if folder != "" else f
		if (f.ends_with(".tres") or f.ends_with(".txt")) and (not dir.is_link(f) or _safe_rel(rel)):
			out.append(rel)
	return out


## A vault-relative folder ("" = root) or null if it escapes the vault or
## points into a hidden folder, a root asset folder (models/, images/) or a
## Markdown export folder (_skipped_by_scans), whose notes neither the app
## nor list_notes shows. A folder name not on disk
## yet is made portable the way the app names a new folder
## (_portable_folder), so "CON" becomes "CON_" and "Notes." becomes "Notes".
func _clean_folder(v: Variant) -> Variant:
	if v == null:
		return ""
	if not (v is String):
		return null
	var s: String = (v as String).strip_edges().replace("\\", "/").trim_prefix("./").trim_suffix("/")
	if s == "" or s == ".":
		return ""
	if not _safe_rel(s):
		return null
	var portable: Variant = _portable_folder(s)
	return portable if portable is String and _safe_rel(portable) and not _skipped_by_scans(portable) else null


## True when every scan (VaultStore._is_skipped_dir, as _scan asks it) leaves
## out the vault folder `s` or a folder above it: besides the hidden and
## asset folders _safe_rel_text refuses, a Markdown export folder, which
## holds MdExport.MARKER at any depth.
func _skipped_by_scans(s: String) -> bool:
	var parent: String = ""
	for part in s.split("/"):
		if VaultStore._is_skipped_dir(parent, part, vault):
			return true
		parent = parent.path_join(part) if parent != "" else part
	return false


## `s` with each folder name that is not on disk yet cleaned by the app's
## rule for a new folder's name (VaultStore._clean_name); a folder that
## exists keeps its name, so one made outside the app is still found as it
## is. null when a name cleans to nothing.
func _portable_folder(s: String) -> Variant:
	var out: String = ""
	for part in s.split("/"):
		var next: String = out.path_join(part) if out != "" else part
		if not DirAccess.dir_exists_absolute(vault + next):
			var clean: String = VaultStore._clean_name(part)
			if clean == "":
				return null
			next = out.path_join(clean) if out != "" else clean
		out = next
	return out


## A vault-relative note path (.tres or .txt), or null.
func _clean_note_path(v: Variant) -> Variant:
	if not (v is String):
		return null
	var s: String = (v as String).strip_edges().replace("\\", "/").trim_prefix("./")
	if not (s.ends_with(".tres") or s.ends_with(".txt")) or not _safe_rel(s):
		return null
	return s


## Whether the vault-relative path `s` stays inside the vault and out of its
## hidden folders and root asset folder: first as written (_safe_rel_text),
## then, when a symbolic link or junction is on the way, as the place it
## really leads (VaultStore._real_rel), checked by the same rules. A link
## out of the vault, or into .ontomeme or .trash, is refused.
func _safe_rel(s: String) -> bool:
	if not _safe_rel_text(s):
		return false
	var real: Variant = VaultStore._real_rel(vault, s)
	return real is String and (real == s or _safe_rel_text(real))


func _safe_rel_text(s: String) -> bool:
	if s.is_absolute_path() or s.begins_with("/") or s.contains(":") or s.contains("//"):
		return false
	var parts: PackedStringArray = s.split("/")
	for i in parts.size():
		var p: String = parts[i]
		if p == "" or p == "." or p == ".." or p.begins_with("."):
			return false
		if i == 0 and VaultStore.asset_dir_named(vault, p) != "":
			return false   # images/, models/ in any case: no list shows a note there
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


## Tags as the app stores them (TagOps.normalize_list): "#Foo Bar" and
## "foo bar" are one tag, foo-bar. A leading BOM goes (_no_bom), then the
## tag is normalized again ("\uFEFF#Foo" is foo).
func _tags(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if v is Array:
		out = TagOps.normalize_list(TagOps.normalize_list(v).map(_no_bom))
	return out


## `s` without the U+FEFF (BOM) characters it starts with: the text resource
## loader drops one at the start of a string, so a .tres field that kept it
## would not read back as saved (VaultStore.saved_matches) and the write
## would fail.
static func _no_bom(s: String) -> String:
	return s.lstrip(BOM_CHAR)


## A title argument as a .tres note stores it: trimmed, without a BOM.
static func _title_arg(v: Variant) -> String:
	return _no_bom(str(v).strip_edges()).strip_edges()


func _changed(action: String, rel: String) -> void:
	if on_change.is_valid():
		on_change.call(action, rel)


static func _ok(data: Dictionary) -> Dictionary:
	return {
		"content": [{"type": "text", "text": McpProtocol.to_json(data)}],
		"structuredContent": data,
		"isError": false,
	}


## Like _ok, but the text content is `text` itself (Markdown for the model to
## read) rather than the JSON of `data`.
static func _ok_text(text: String, data: Dictionary) -> Dictionary:
	return {
		"content": [{"type": "text", "text": text}],
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
