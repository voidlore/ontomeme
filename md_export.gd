class_name MdExport
extends RefCounted
## Markdown export for notes (md_export). Phase 2 of the plan is the pure
## converter below; phase 3, `export_note`, writes one note's .md into the
## vault's exports/ folder, which `prepare_out_dir` marks so VaultStore
## never lists it; phase 5, `export_vault` and `export_folder`, write many;
## phase 6, `set_output_root`, picks another folder per vault, saved in
## <vault>/.ontomeme/export.json and read back by `output_root`.
##
## `to_markdown(note, title_to_path)` turns a ContentLayer into a standalone
## .md file: YAML front-matter (title, created, modified, tags) plus the raw
## text with every resolvable [[wikilink]] rewritten as a relative Markdown
## link. It keeps the renderer's rules:
##   - `code spans` and fenced blocks (including ```3d) pass through untouched,
##     so [[x]] inside code is never rewritten (layer_engine's code-skip).
##   - [[T]] -> [T](t.md), [[T|a]] -> [a](t.md), resolving T by title
##     case-insensitively, as open_note_by_title does (note.gd).
##   - a link whose target title is absent from the map stays literal
##     [[T]] / [[T|a]]: it shows the link was dangling and round-trips
##     into Obsidian.
##
## Front-matter tags are quoted per entry so tags containing `,` `:` `#`
## `]` cannot produce invalid YAML (both bugs of the rolled-back 25ce5ed).
##
## `title_to_path` maps lower-cased note titles to the link target as it must
## be written *inside this note's export file*. `link_map()` builds it: each
## note exports to its vault folder + its real .tres file stem + ".md"
## (`export_rel_path`), and links are relative to the exporting file's
## folder with every path segment percent-encoded (`relative_link`):
## "note_wave.md" in the same folder, "../note_wave.md" one folder up,
## "New%20folder/note_x.md". to_markdown itself takes no vault state, so it
## runs headless.

const _WIKI_RX: String = "\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]"
const _CODE_RX: String = "`([^`]+)`"

## The default export folder, inside the vault.
const EXPORT_DIR: String = "exports"
## The vault's export setting, in VaultStore.data_dir() (<vault>/.ontomeme):
## {"out_dir": "<folder>"}, absolute, or relative to the vault when inside it.
const SETTINGS_FILE: String = "export.json"
## The file that marks a folder as an export folder. VaultStore skips any
## folder holding it (at any depth), so exports never show up as a notes
## folder in the sidebar or wake the disk watcher.
const MARKER: String = ".ontomeme-export"
const _MARKER_TEXT: String = "Ontomeme writes Markdown exports here. This file keeps the folder out of the note list; delete it to show the folder again.\n"
## How many files and folders the check for notes in a would-be export
## folder reads before it gives up and refuses the folder (ERR_TIMEOUT). It
## runs on the main thread when a folder is picked and before the first
## export into it, so this bounds how long either can freeze the app
## (/usr/share was refused in 22 ms, warm cache) whatever the folder holds:
## a huge tree or a symlink loop.
const SCAN_LIMIT: int = 10000

## Why the last export_note() failed, or the last note an export_vault() /
## export_folder() could not write; "" when nothing failed.
static var last_error: String = ""


## Write `note` as Markdown to <out_root>/<its vault folder>/<stem>.md and
## return that absolute path, or "" with last_error set. `out_root` ""
## means output_root(). A second export overwrites the file;
## `timestamped` writes <stem>-YYYYMMDD-HHMMSS.md beside it instead. The
## note is only read: its .tres file is never written.
static func export_note(note: ContentLayer, out_root: String = "", timestamped: bool = false) -> String:
	last_error = ""
	if note == null:
		return _fail("There is no note to export")
	var root: String = _out_root(out_root)
	if not _prepare_root(root):
		return ""
	var links: Dictionary = link_map(VaultStore.note_list, VaultStore.vault_path, VaultStore.folder_of(note))
	return _write_note(note, root, links, timestamped)


## Write every note in the open vault, as export_note would, to
## <out_root>/<its folder>/<stem>.md. Returns {"written": int, "failed":
## Array[String] (the titles not written; last_error says why the last one
## failed), "out": the export root}. Files from earlier exports are never
## deleted, even when their note is gone.
static func export_vault(out_root: String = "") -> Dictionary:
	return _export_notes(VaultStore.note_list, out_root)


## export_vault for the notes in the vault folder `rel` and its subfolders
## ("" = the whole vault). Links to notes outside it are still written as
## relative paths into the same export tree, so they resolve once those
## notes are exported too.
static func export_folder(rel: String, out_root: String = "") -> Dictionary:
	var picked: Array[ContentLayer] = []
	for n in VaultStore.note_list:
		if _is_within(VaultStore.folder_of(n), rel):
			picked.append(n)
	return _export_notes(picked, out_root)


## True if the vault folder `folder` is `rel` or lies below it.
static func _is_within(folder: String, rel: String) -> bool:
	return rel == "" or folder == rel or folder.begins_with(rel + "/")


## Write `notes` under the export root; one link map per source folder.
static func _export_notes(notes: Array[ContentLayer], out_root: String) -> Dictionary:
	last_error = ""
	var root: String = _out_root(out_root)
	var failed: Array[String] = []
	var written: int = 0
	if not notes.is_empty() and not _prepare_root(root):
		for n in notes:
			failed.append(n.title)
		return {"written": 0, "failed": failed, "out": root}
	var maps: Dictionary = {}   # vault folder -> link map for files exported there
	for n in notes:
		var folder: String = VaultStore.folder_of(n)
		if not maps.has(folder):
			maps[folder] = link_map(VaultStore.note_list, VaultStore.vault_path, folder)
		if _write_note(n, root, maps[folder], false) != "":
			written += 1
		else:
			failed.append(n.title)
	return {"written": written, "failed": failed, "out": root}


## The export root: `out_root`, or output_root() when it is "".
static func _out_root(out_root: String) -> String:
	return out_root if out_root != "" else output_root()


## prepare_out_dir(root) unless root is the vault, around it or in its
## .ontomeme; a refusal is reported through last_error.
static func _prepare_root(root: String) -> bool:
	var err: Error = ERR_INVALID_PARAMETER if _vault_refusal(root) != "" else prepare_out_dir(root)
	return _report_root(root, err) == OK


## Say through last_error why `root` can't take exports, for an error from
## _root_error or prepare_out_dir; returns `err`.
static func _report_root(root: String, err: Error) -> Error:
	if err == OK:
		return OK
	var why: String = _vault_refusal(root)
	if why != "":
		_fail(why + ", so exports won't be written there")
	elif err == ERR_ALREADY_IN_USE:
		_fail("%s already holds notes, so exports won't be written there" % root)
	elif err == ERR_TIMEOUT:
		_fail("%s holds more than %d files and folders, too many to check for notes, so exports won't be written there; pick an empty or new folder" % [root, SCAN_LIMIT])
	else:
		_dir_fail("export folder", root, err)
	return err


# ── The export folder setting (plan phase 6) ────────────────────────────────

## The folder the open vault's exports go to, absolute: the one
## set_output_root saved in <vault>/.ontomeme/export.json, or
## <vault>/exports when none is saved (or the file can't be read).
static func output_root() -> String:
	var saved: Variant = _read_settings().get("out_dir")
	if saved is String and (saved as String).strip_edges() != "":
		return _resolve(saved)
	return default_root()


## <vault>/exports, the export folder until set_output_root picks another.
static func default_root() -> String:
	return VaultStore.vault_path.path_join(EXPORT_DIR)


## Save `path` (absolute, or relative to the vault) as the open vault's
## export folder; nothing is created until the next export. A folder inside
## the vault is stored relative to it, so the setting moves with the vault.
## Refuses with last_error set, saving nothing: ERR_INVALID_PARAMETER for
## the vault itself, a folder around it, or anything in its .ontomeme;
## ERR_ALREADY_IN_USE for a folder that holds notes and is not marked as an
## export folder; ERR_TIMEOUT for an unmarked folder too big to check for
## notes (over SCAN_LIMIT files and folders); ERR_FILE_BAD_PATH when a
## regular file stands in the way.
static func set_output_root(path: String) -> Error:
	last_error = ""
	var abs_dir: String = _resolve(path)
	var err: Error = _report_root(abs_dir, _root_error(abs_dir))
	if err != OK:
		return err
	var settings: Dictionary = _read_settings()
	settings["out_dir"] = _stored_form(abs_dir)
	return _write_settings(settings)


## Forget the open vault's export folder: exports go to <vault>/exports again.
static func clear_output_root() -> Error:
	last_error = ""
	var settings: Dictionary = _read_settings()
	if not settings.has("out_dir"):
		return OK
	settings.erase("out_dir")
	return _write_settings(settings)


## Why `abs_dir` can't take the open vault's exports, without writing
## anything: what set_output_root and an export would refuse it for.
static func _root_error(abs_dir: String) -> Error:
	return ERR_INVALID_PARAMETER if _vault_refusal(abs_dir) != "" else _dir_refusal(abs_dir)


## Why `abs_dir` can never be the open vault's export folder, or "": it is
## the vault, a folder the vault lies in, or inside the vault's .ontomeme.
static func _vault_refusal(abs_dir: String) -> String:
	var d: String = _as_dir(abs_dir)
	var vault: String = _as_dir(VaultStore.vault_path)
	if d == vault:
		return "%s is the vault itself" % abs_dir
	if vault.begins_with(d):
		return "%s holds the vault" % abs_dir
	if d.begins_with(_as_dir(VaultStore.data_dir())):
		return "%s is in the vault's .ontomeme folder" % abs_dir
	return ""


## `path` simplified and ending in "/", so folders compare by prefix.
static func _as_dir(path: String) -> String:
	return path.simplify_path().trim_suffix("/") + "/"


## `path` as an absolute folder without a trailing "/": a relative path is
## taken from the vault's root.
static func _resolve(path: String) -> String:
	var p: String = ProjectSettings.globalize_path(path.strip_edges())
	if not p.is_absolute_path():
		p = VaultStore.vault_path.path_join(p)
	return p.simplify_path()


## How export.json stores `abs_dir`: relative to the vault when inside it.
static func _stored_form(abs_dir: String) -> String:
	var vault: String = _as_dir(VaultStore.vault_path)
	return abs_dir.substr(vault.length()) if abs_dir.begins_with(vault) else abs_dir


static func _settings_path() -> String:
	return VaultStore.data_dir().path_join(SETTINGS_FILE)


## export.json as a Dictionary; {} when it is missing or not a JSON object.
static func _read_settings() -> Dictionary:
	var p: String = _settings_path()
	if not FileAccess.file_exists(p):
		return {}
	var json := JSON.new()   # JSON.parse_string would log an ERROR line for a broken file
	if json.parse(FileAccess.get_file_as_string(p)) != OK or not (json.data is Dictionary):
		return {}
	return json.data


## Write `settings` to export.json, or remove the file when they are empty.
static func _write_settings(settings: Dictionary) -> Error:
	var p: String = _settings_path()
	if settings.is_empty():
		return DirAccess.remove_absolute(p) if FileAccess.file_exists(p) else OK
	var err: Error = DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	if err != OK:
		_fail("Couldn't create %s (%s)" % [p.get_base_dir(), error_string(err)])
		return err
	if _write_text(p, JSON.stringify(settings, "\t") + "\n") == "":
		return ERR_FILE_CANT_WRITE
	return OK


## Write `note`'s Markdown, its links from `links`, to root/<export_rel_path>
## (or the timestamped name beside it); the path, or "" with last_error.
static func _write_note(note: ContentLayer, root: String, links: Dictionary, timestamped: bool) -> String:
	var target: String = root.path_join(export_rel_path(note, VaultStore.vault_path))
	if timestamped:
		target = "%s-%s.md" % [target.get_basename(), _timestamp()]
	var err: Error = _make_dir(target.get_base_dir())
	if err != OK:
		return _dir_fail("folder", target.get_base_dir(), err)
	return _write_text(target, to_markdown(note, links))


## Write `text` to `path` (replacing it); the path, or "" with last_error.
static func _write_text(path: String, text: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _fail("Couldn't write %s (%s)" % [path, error_string(FileAccess.get_open_error())])
	var ok: bool = f.store_string(text)
	f.close()
	if not ok:
		return _fail("Couldn't write all of %s" % path)
	return path


static func _fail(message: String) -> String:
	last_error = message
	return ""


## Fail because the `what` at `abs_dir` could not be made; names the file in
## the way when that was the reason.
static func _dir_fail(what: String, abs_dir: String, err: Error) -> String:
	if err == ERR_FILE_BAD_PATH:
		return _fail("Couldn't create the %s %s: %s is a file" % [what, abs_dir, _file_in_path(abs_dir)])
	return _fail("Couldn't create the %s %s (%s)" % [what, abs_dir, error_string(err)])


## make_dir_recursive_absolute, except that a regular file at or above
## `abs_dir` returns ERR_FILE_BAD_PATH without asking the engine, which would
## log an "ERROR: Could not create directory" line for a failure that
## export_note already reports through last_error.
static func _make_dir(abs_dir: String) -> Error:
	if _file_in_path(abs_dir) != "":
		return ERR_FILE_BAD_PATH
	return DirAccess.make_dir_recursive_absolute(abs_dir)


## The regular file that stands where `abs_dir` or one of its parents would
## be a folder, or "" when its nearest existing ancestor is a folder.
static func _file_in_path(abs_dir: String) -> String:
	var p: String = abs_dir.simplify_path()
	while not DirAccess.dir_exists_absolute(p):
		if FileAccess.file_exists(p):
			return p
		var up: String = p.get_base_dir()
		if up == "" or up == p:
			return ""
		p = up
	return ""


## Local time as YYYYMMDD-HHMMSS, for timestamped export names.
static func _timestamp() -> String:
	var t: Dictionary = Time.get_datetime_dict_from_system()
	return "%04d%02d%02d-%02d%02d%02d" % [t.year, t.month, t.day, t.hour, t.minute, t.second]


## Make `abs_dir` an export folder: create it and write the MARKER into it.
## Refuses with ERR_ALREADY_IN_USE, writing nothing, when the folder already
## exists without the marker and holds notes (.tres, at any depth): a user's
## own "exports" notes folder must never vanish from the sidebar.
## ERR_TIMEOUT, writing nothing, when that folder is too big to check
## (_notes_check). ERR_FILE_BAD_PATH, creating nothing, when a regular file
## stands at or above `abs_dir`.
static func prepare_out_dir(abs_dir: String) -> Error:
	var marker: String = abs_dir.path_join(MARKER)
	if FileAccess.file_exists(marker):
		return OK
	var err: Error = _dir_refusal(abs_dir)
	if err == OK and not DirAccess.dir_exists_absolute(abs_dir):
		err = _make_dir(abs_dir)
	if err != OK:
		return err
	var f := FileAccess.open(marker, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(_MARKER_TEXT)
	f.close()
	return OK


## What prepare_out_dir would refuse `abs_dir` for, checked without writing:
## ERR_ALREADY_IN_USE for an unmarked folder of notes, ERR_TIMEOUT for one
## too big to check, ERR_FILE_BAD_PATH for a regular file at or above it,
## else OK.
static func _dir_refusal(abs_dir: String) -> Error:
	if FileAccess.file_exists(abs_dir.path_join(MARKER)):
		return OK
	if DirAccess.dir_exists_absolute(abs_dir):
		return _notes_check(abs_dir)
	return ERR_FILE_BAD_PATH if _file_in_path(abs_dir) != "" else OK


## Whether the folder `abs_dir` holds notes: ERR_ALREADY_IN_USE when it or a
## visible folder under it holds a .tres file, OK when none does, and
## ERR_TIMEOUT once it has read SCAN_LIMIT files and folders without an
## answer. That limit is what keeps the walk bounded. Symlinked folders are
## followed, so notes behind a link still count, but each folder only once,
## so a link back to its own folder or a parent does not loop.
static func _notes_check(abs_dir: String) -> Error:
	var todo: Array[String] = [abs_dir]
	var seen: Dictionary = {abs_dir.simplify_path(): true}   # folders queued, by path and by link target
	var read: int = 0
	while not todo.is_empty():
		var path: String = todo.pop_back()
		var dir := DirAccess.open(path)
		if dir == null:
			continue
		if dir.list_dir_begin() != OK:   # hidden entries (.ontomeme, .git…) are skipped, as VaultStore skips them
			continue
		var name: String = dir.get_next()
		while name != "":
			read += 1
			if read > SCAN_LIMIT:
				dir.list_dir_end()
				return ERR_TIMEOUT
			if dir.current_is_dir():
				var sub: String = path.path_join(name)
				var real: String = _link_target(dir, sub)
				# Seen by where it points or by the path it is opened at: a
				# relative link inside a followed one resolves against the latter.
				if not seen.has(real) and not seen.has(sub.simplify_path()):
					seen[real] = true
					seen[sub.simplify_path()] = true
					todo.append(sub)
			elif name.ends_with(".tres"):
				dir.list_dir_end()
				return ERR_ALREADY_IN_USE
			name = dir.get_next()
		dir.list_dir_end()
	return OK


## The folder `sub`, which `dir` lists, names: its link target when it is a
## symlink (a relative one taken from `sub`'s folder), else `sub`; simplified,
## so _notes_check can tell a link back to a folder it has queued.
static func _link_target(dir: DirAccess, sub: String) -> String:
	if not dir.is_link(sub):
		return sub.simplify_path()
	var target: String = dir.read_link(sub)
	if target == "":
		return sub.simplify_path()
	if target.is_relative_path():
		target = sub.get_base_dir().path_join(target)
	return target.simplify_path()


## Where `note` exports to, relative to the export root: its folder in the
## vault at `vault_path` plus its .tres file's stem, "Physics/note_sine.md".
## The stem is the real file name, which a rename keeps; it is never derived
## from the title.
static func export_rel_path(note: ContentLayer, vault_path: String) -> String:
	var root: String = vault_path if vault_path.ends_with("/") else vault_path + "/"
	var path: String = note.resource_path
	var rel: String = path.substr(root.length()) if path.begins_with(root) else path.get_file()
	if rel.get_file() == "":
		return "untitled.md"   # a note never saved has no file to name it
	return rel.get_basename() + ".md"


## The link written inside an export file in `from_folder` (vault-relative,
## "" = top level) to the export file at `to_rel_md` (vault-relative too):
## "../" up to the shared folder, then the rest of the path with each
## segment uri-encoded ("New folder" -> New%20folder).
static func relative_link(from_folder: String, to_rel_md: String) -> String:
	var from: PackedStringArray = from_folder.split("/", false)
	var to: PackedStringArray = to_rel_md.split("/", false)
	var shared: int = 0
	# The last `to` segment is the file, never a shared folder.
	while shared < mini(from.size(), to.size() - 1) and from[shared] == to[shared]:
		shared += 1
	var parts: PackedStringArray = []
	for i in range(from.size() - shared):
		parts.append("..")
	for segment in to.slice(shared):
		parts.append(segment.uri_encode())
	return "/".join(parts)


## lower(title) -> link target for every note in `notes`, as written inside
## an export file in `from_folder`: the map to_markdown takes. When several
## notes share a title the first in `notes` wins; pass VaultStore.note_list
## (newest first, the order open_note_by_title scans) so an exported link
## points where clicking it in the app would go.
static func link_map(notes: Array[ContentLayer], vault_path: String, from_folder: String) -> Dictionary:
	var m: Dictionary = {}
	for n in notes:
		var key: String = n.title.strip_edges().to_lower()
		if key != "" and not m.has(key):
			m[key] = relative_link(from_folder, export_rel_path(n, vault_path))
	return m


## The .md text of `note`, front-matter plus converted body, ending with one
## trailing newline. `title_to_path`: lower(title) -> link target string.
static func to_markdown(note: ContentLayer, title_to_path: Dictionary) -> String:
	var in_code: bool = false
	var fence_len: int = 0
	var body: String = ""
	for line in note.raw_text.split("\n"):
		var s: String = line.strip_edges()
		var ticks: int = _fence_ticks(s)
		if in_code:
			# Pass the whole fence through, opener and closer lines included.
			body += line + "\n"
			if ticks >= fence_len and s.substr(ticks).strip_edges() == "":
				in_code = false
			continue
		if ticks > 0:
			body += line + "\n"
			in_code = true
			fence_len = ticks
			continue
		body += _convert_line(line, title_to_path) + "\n"
	return _front_matter(note) + "\n\n" + body.trim_suffix("\n") + "\n"


## One line outside a fence: `code` spans pass through, the rest gets its
## [[wikilinks]] converted (same split order as the renderer).
static func _convert_line(line: String, title_to_path: Dictionary) -> String:
	var code_rx := RegEx.new()
	code_rx.compile(_CODE_RX)
	var out: String = ""
	var last: int = 0
	for m in code_rx.search_all(line):
		out += _convert_links(line.substr(last, m.get_start() - last), title_to_path)
		out += line.substr(m.get_start(), m.get_end() - m.get_start())
		last = m.get_end()
	return out + _convert_links(line.substr(last), title_to_path)


## Rewrite resolvable [[wikilinks]] in `text`; dangling ones stay literal.
static func _convert_links(text: String, title_to_path: Dictionary) -> String:
	var re := RegEx.new()
	re.compile(_WIKI_RX)
	var out: String = ""
	var last: int = 0
	for m in re.search_all(text):
		out += text.substr(last, m.get_start() - last)
		var target: String = m.get_string(1).strip_edges()
		var shown: String = m.get_string(2).strip_edges() if m.get_string(2) != "" else target
		if title_to_path.has(target.to_lower()):
			out += "[%s](%s)" % [shown, title_to_path[target.to_lower()]]
		else:
			out += m.get_string()   # dangling: keep exactly what was written
		last = m.get_end()
	return out + text.substr(last)


## Leading backticks if `s` opens/closes a fence (>= 3), else 0 — the
## renderer's fence rule (layer_engine.gd _fence_ticks).
static func _fence_ticks(s: String) -> int:
	var n: int = 0
	while n < s.length() and s[n] == "`":
		n += 1
	return n if n >= 3 else 0


static func _front_matter(note: ContentLayer) -> String:
	var fm: String = "---\n"
	fm += "title: %s\n" % _quote(note.title)
	fm += "created: %s\n" % _quote(note.created)
	fm += "modified: %s\n" % _quote(note.modified)
	if note.tags.is_empty():
		fm += "tags: []\n"
	else:
		fm += "tags: [%s]\n" % ", ".join(note.tags.map(func(t: String) -> String: return _quote(t)))
	return fm + "---"


## A YAML double-quoted scalar: backslash and quote escaped.
static func _quote(s: String) -> String:
	return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
