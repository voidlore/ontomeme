class_name VaultStore
extends Node

const TresValidatorScript = preload("res://tres_validator.gd")
const StarterContent = preload("res://starter_content.gd")
const StartupLog = preload("res://startup_log.gd")
const Boot = preload("res://boot.gd")
const NoteImporter = preload("res://note_importer.gd")

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

## Cached list of all notes: pinned first (newest pin on top), then by
## modified date descending (see _sort_by_modified).
static var note_list: Array[ContentLayer] = []

## How many times refresh_note_list() rescanned the vault (tests count the
## rescans a save must not cause).
static var refresh_count: int = 0

## Every subfolder of the vault, relative ("Physics/Waves"), sorted.
## Hidden folders (".ontomeme") and the root asset folders (ASSET_DIRS) are skipped.
static var folders: Array[String] = []

## Last-seen modification time and size per note file, to spot outside edits.
static var _mtimes: Dictionary = {}
static var _sizes: Dictionary = {}

## SHA-256 of each note file as the app last read or wrote it. A save that
## finds different bytes on disk would overwrite an outside edit.
static var _hashes: Dictionary = {}

## When each _hashes entry was taken or last confirmed (Unix time), to tell
## whether it covers every write in its file's mtime second (_unsettled).
static var _hashed_at: Dictionary = {}

## Seconds after a file's mtime during which another write can land without
## moving the mtime (whole seconds; two on FAT drives) or, often, the size:
## Claude's create_note then update_note in one second. Until a hash taken
## after this window confirms them, such files are compared by their bytes.
const FRESH_SECS: int = 2

## disk_signature()'s memory of the files it hashed:
## path -> [mtime, size, sha256, hashed_at].
static var _sig_hashes: Dictionary = {}

## Set by save_note() when it kept an outside edit and wrote the in-memory
## version as this new note instead; null otherwise.
static var last_conflict_copy: ContentLayer = null

## Why the last save_note() failed: error_string(err) and the file, e.g.
## "Can't open (/…/note_x.tres)"; "" after a save that worked.
static var last_save_error: String = ""

## Note files whose last save_note() failed: the app's ContentLayer holds
## newer words than the file. A rescan doesn't reload such a note over those
## words when its file changes on disk; the next save_note() then sees the
## outside edit (the hash differs) and writes the words as a conflict copy.
static var _unsaved_paths: Dictionary = {}

## The note open in the editor (note.gd sets it). The editor holds its own
## copy of the text, so a rescan (any other note's save or retry, a folder
## operation) doesn't reload this note in place when its file changes on
## disk: that would take the new file's hash while the editor still shows
## the old text, and the next save would write it over the outside edit.
## The change stays pending; only the watcher's refresh_note_list(true)
## loads it (note.gd then shows it), and a save before that finds the
## outside edit and writes the editor's text as a conflict copy.
static var editor_note: ContentLayer = null

## Root folders that hold files notes point at, not notes: 3D models and
## pictures (image_embeds). No scan lists them or a .tres inside them.
const ASSET_DIRS: Array[String] = ["models", "images"]

## What each root asset folder holds, for messages (asset_refusal,
## hidden_notes_warning): "the vault's picture folder".
const ASSET_KINDS: Dictionary = {"models": "3D model", "images": "picture"}

## Why the last create_folder, move_folder (rename_folder) or move_note
## refused its target ("" if it did not): the target lay in a root asset
## folder (asset_refusal). The app shows it in the status line.
static var last_refusal: String = ""

## Saves are atomic (atomic_save): a temp file here, inside the vault, then a
## rename over the note. Hidden, so the sidebar, the watcher and MCP skip it.
const TMP_DIR: String = ".ontomeme/tmp"
## A temp file older than this was left by a crash; open_vault removes it
## (unless it is the only copy of its note: then it is put back).
const TMP_MAX_AGE_SEC: int = 24 * 60 * 60
## open_vault leaves younger temp files alone: another process (the MCP
## server writes through the same folder) may be in the middle of a save.
const TMP_SETTLE_SEC: int = 10
## A temp file name carries the note's path (see _new_tmp_path) only while
## the name stays under 200 characters (names stop at 255 bytes) and the
## whole path under 240 (Windows paths may stop at 260).
const TMP_NAME_MAX: int = 200
const TMP_PATH_MAX: int = 240

## Tests only: stands in for DirAccess.rename_absolute(from, to) -> Error in
## atomic saves, to act out how Windows renames (see _move_tmp_into_place).
static var rename_hook: Callable = Callable()

## Deleted notes go here (trash_note), and deleted folders when the system
## trash refuses them; hidden, so scans, the watcher and MCP skip it. The
## same folder and layout as the MCP server's delete_note
## (mcp/vault_tools.gd TRASH_DIR): one trash holds what both deleted.
const TRASH_DIR: String = ".trash"

## Tests only: stands in for OS.move_to_trash(path) -> Error in delete_folder.
static var system_trash_hook: Callable = Callable()

## Longest title slug in a note's file name (filename_stem).
const MAX_SLUG_CHARS: int = 80

## Longest folder name _clean_name makes, in characters and in UTF-8 bytes:
## a Japanese or Greek name takes two or three bytes a character, and ext4,
## APFS and NTFS allow 255 (create_folder may still add " 2").
const MAX_NAME_CHARS: int = 100
const MAX_NAME_BYTES: int = 240

## A name Windows keeps for a device, which no file or folder there may
## have, with or without an extension ("aux.txt"): _clean_name adds "_".
static var _reserved_name_re: RegEx = RegEx.create_from_string("(?i)^(?:CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³])$")
## Dots and spaces at either end of a name: a leading dot hides a folder, and
## Windows drops trailing ones, so "Notes." would not be found there.
static var _edge_dots_re: RegEx = RegEx.create_from_string("^[\\s.]+|[\\s.]+$")
## Control characters, which Windows does not allow in a name.
static var _control_char_re: RegEx = RegEx.create_from_string("[\\x00-\\x1f\\x7f]")
## A letter, combining mark or digit outside ASCII (Japanese, Greek,
## Cyrillic, an accented Latin letter), which a note's file name drops
## (_slug). Punctuation outside ASCII ("’", "—") does not count.
static var _non_ascii_word_re: RegEx = RegEx.create_from_string("(?![\\x00-\\x7f])[\\p{L}\\p{M}\\p{N}]")

## How many folder levels below the vault a scan enters (a folder 32 levels
## down is still scanned): a backstop for any link chain _should_descend
## does not catch.
const MAX_SCAN_DEPTH: int = 32

## Most symbolic links _real_path follows for one path, as on Linux.
const MAX_LINK_HOPS: int = 40

## True on Windows, where read_link gives a link's final path, a network
## share is a root of its own and paths compare without case (_link_text,
## _path_root, _same_path). A test sets it to check those rules elsewhere.
static var _windows: bool = OS.get_name() == "Windows"

## True on macOS, where the can't-read warning says how to allow Documents
## and bring the notes kept meanwhile along (_fall_back_unreadable). A test
## sets it to check that text elsewhere.
static var _mac: bool = OS.get_name() == "macOS"

## True when this launch created the default vault and filled it with the
## starter notes (the app then opens the tutorials).
static var first_run: bool = false

## A startup problem worth telling the user about ("" if none).
static var startup_warning: String = ""

## The fallback folder whose notes this launch said the open vault lacks
## (_left_in_fallback, _kept_in_fallback), as normalized; "" if none. The
## sidebar's ↓ Import opens there (note.gd), the folder to bring them in
## from. Cleared by opening a vault and by importing that folder.
static var kept_in_fallback: String = ""

## The file in a fallback vault's data folder (data_dir_of) that says which
## vault it stands in for and which note files it held when it began:
## {"for": that vault, "notes": {path relative to the fallback: SHA-256}}.
## Written by _begin_stand_in, read by _kept_in_fallback, removed when the
## fallback is opened as the user's vault (open_vault).
const STAND_IN_FILE: String = "stand-in.json"

## The program a release folder holds (export_presets.cfg's export paths).
## A vault in a folder that holds one is inside the folder README.md's
## update steps delete (program_folder_warning).
const PROGRAM_FILES: Array[String] = ["Ontomeme.x86_64", "Ontomeme.exe"]

## Note files the last scan refused to load because they carry code
## (TresValidator.check_text_safe), as absolute paths. See unsafe_warning().
static var unsafe_files: Array[String] = []

## Files ending in .tres that the last scan could not read as notes, relative
## to the vault: no resource header at all (garbage, an empty file), or a
## note that does not load (cut off by a sync tool mid-write, broken by
## hand). The sidebar lists them and offers quarantine(); nothing is moved on
## its own. A Godot project's own resources and the files that carry code
## (unsafe_files) are not listed here.
static var unreadable: Array[String] = []

## Each unreadable file's _stamp when a scan last read it, by absolute path.
## Until the stamp changes the file is listed again without being read, so a
## broken note's parse errors are not logged on every refresh (every save
## refreshes). A stamp of "" matches no file: it is read afresh.
static var _bad_stamps: Dictionary = {}

## Each unreadable file's SHA-256 when a scan last read it, by absolute path.
## quarantine() moves a file only while it still has these bytes: a sync tool
## can finish writing a note within the second the scan saw it half-written,
## at a size the stamp does not tell apart, and the list stays stale.
static var _bad_hashes: Dictionary = {}

## How many times a scan has read a file and found it unreadable. Tests
## watch it to see that an unchanged file is not read again.
static var unreadable_reads: int = 0

## Hidden folder of the vault (no scan enters it) where quarantine() keeps
## the unreadable files the user moved aside.
const CORRUPTED_DIR: String = ".corrupted"

## Paths already logged as skipped, so each is logged once per session.
static var _skip_logged: Dictionary = {}

## What a scriptless note's [resource] section looks like (_is_scriptless_note).
## The indent before a name is spaces and tabs only ([^\S\r\n]): with \s
## a match tried at each line start ran on through all the blank lines after
## it, so a file of blank lines took time in the square of its length.
static var _script_line_re: RegEx = RegEx.create_from_string("(?m)^[^\\S\\r\\n]*script\\s*=")
static var _note_field_re: RegEx = RegEx.create_from_string("(?m)^[^\\S\\r\\n]*(?:title|raw_text)\\s*=")


func _ready() -> void:
	# A vault opened before the autoload is ready (a test's throwaway vault)
	# wins; otherwise the startup vault would silently replace it. With
	# --mcp-stdio the server picks its vault (mcp/serve.gd) and nothing may
	# be opened, seeded, remembered or printed to stdout.
	if vault_path == "" and not Boot.mcp_stdio_requested():
		open_launch_vault()


## The vault a launch opens (open_launch_vault): VaultRegistry.startup_vault(),
## except that the last vault is kept when it only looks missing because a
## folder above it can't be listed (_unlistable_ancestor: a denied ~/Documents
## holding ~/Documents/MyNotes). startup_vault() would pass it over for the default
## vault, the fallback would then remember that one as last, and once access
## is granted the next launch would seed it and leave the user's notes hidden.
static func startup_path() -> String:
	if not _cmdline_vault():
		var last: String = VaultRegistry._read().last
		if last != "" and not DirAccess.dir_exists_absolute(last) and _unlistable_ancestor(last) != "":
			return VaultRegistry.normalize(last)
	return VaultRegistry.startup_vault()


## What a launch opens: the vault an older build remembered as a relative
## path, found again (adopt_relative_vaults), else startup_path(). Then
## warns about a vault the update steps would delete, or one that can't be
## found.
static func open_launch_vault(here: String = _working_folder(), parents: Array[String] = _release_parents()) -> void:
	var remember: bool = not _cmdline_vault()
	var lost: String = adopt_relative_vaults(here, parents) if remember else ""
	var path: String = startup_path()
	var why: String = launch_reason(path)   # before the open remembers it as last
	open_startup_vault(path, VaultRegistry.default_vault(), remember)
	for w in [program_folder_warning(), lost]:
		if w != "":
			push_warning(w)
			startup_warning = w if startup_warning == "" else w + "  ·  " + startup_warning
	log_startup(path, why)


## Why a launch chose `path`, for the startup log.
static func launch_reason(path: String) -> String:
	if _cmdline_vault():
		return "--vault"
	var p: String = VaultRegistry.normalize(path)
	var last: String = VaultRegistry._read().last
	if last != "" and VaultRegistry.normalize(last) == p:
		return "remembered"
	if p == VaultRegistry.normalize(VaultRegistry.legacy_vault()):
		return "legacy notes folder"
	return "default"


## Write this launch's lines to the startup log (startup_log.gd).
static func log_startup(path: String, why: String) -> void:
	var marker: bool = FileAccess.file_exists(vault_path.path_join(StarterContent.MARKER))
	StartupLog.record(path, why, vault_path, first_run, marker, note_list.size(), startup_warning)


## Earlier builds (the v0.1.0 rcs among them) found no Documents folder on
## Linux without xdg-user-dir and kept the default vault at the relative
## path "Ontomeme/": in the folder the app ran from, mostly the one it was
## extracted to, and user://vaults.json still says so. startup_vault()
## looks for it in this launch's folder only, so after an update to a new
## folder it would open a new vault in Documents, and deleting the old
## folder would delete the notes. Each relative entry found again
## (_find_relative_vault) is stored as an absolute path in its place; for
## one that can't be found this returns a warning (and the entry stays, so
## each launch warns again).
static func adopt_relative_vaults(here: String, parents: Array[String]) -> String:
	var stored: Dictionary = VaultRegistry._read()
	var last: String = stored.last
	var relative: Array[String] = []
	for p in [last] + stored.recent:
		var rel: String = VaultRegistry.normalize(str(p))
		if str(p) != "" and rel.is_relative_path() and not relative.has(rel):
			relative.append(rel)
	var lost: Array[String] = []
	for rel in relative:
		var found: Array[String] = _find_relative_vault(rel, here, parents)
		if found.is_empty():
			lost.append(rel.trim_suffix("/"))
			continue
		var was_last: bool = VaultRegistry.normalize(last) == rel
		VaultRegistry.forget(rel)
		found.sort_custom(func(a: String, b: String) -> bool: return FileAccess.get_modified_time(a) < FileAccess.get_modified_time(b))
		for v in found:
			VaultRegistry.remember(v)   # the newest last: it becomes `last`
		if was_last:
			last = found.back()
		elif last != "":
			VaultRegistry.remember(last)   # `last` stays what it was
	if lost.is_empty():
		return ""
	return "Don't delete the folder of the Ontomeme you used before: your notes are in a folder named %s inside it, which this version can't find. Open that with Open folder as vault…" % " or ".join(lost)


## Where the relative vault `rel` is now, absolute: in `here` (the folder
## this launch runs from, where the old build would open it), else in each
## folder inside `parents` that holds the program (an old release folder
## beside the new one), plus a vault of that name the user has opened by
## hand since (not the default vault, which a launch creates).
static func _find_relative_vault(rel: String, here: String, parents: Array[String]) -> Array[String]:
	var found: Array[String] = []
	if here != "" and DirAccess.dir_exists_absolute(here.path_join(rel)):
		found.append(VaultRegistry.normalize(here.path_join(rel)))
		return found
	for parent in parents:
		var listing := DirAccess.open(parent)
		if listing == null:
			continue
		for d in listing.get_directories():
			var v: String = VaultRegistry.normalize(parent.path_join(d).path_join(rel))
			if _holds_program(parent.path_join(d)) and DirAccess.dir_exists_absolute(v) and not found.has(v):
				found.append(v)
	var default: String = VaultRegistry.normalize(VaultRegistry.default_vault())
	for v in VaultRegistry.recent():
		if v.is_absolute_path() and v != default and VaultRegistry.display_name(v) == VaultRegistry.display_name(rel) and not found.has(v):
			found.append(v)
	return found


## Known vaults (the open one and the recent list) that sit in a folder
## holding the program, as an earlier build's relative vault did:
## a warning naming that folder, which the update steps delete, or "".
static func program_folder_warning() -> String:
	var vaults: Array[String] = VaultRegistry.recent()
	if vault_path != "" and not vaults.has(vault_path):
		vaults.push_front(vault_path)
	var parts: Array[String] = []
	for v in vaults:
		var folder: String = v.trim_suffix("/").get_base_dir()
		if _holds_program(folder):
			parts.append("Don't delete %s: your notes are in its %s folder. Quit Ontomeme, move that folder somewhere safe such as Documents, then open it with Open folder as vault…" % [
					folder, VaultRegistry.display_name(v)])
	return "  ·  ".join(parts)


static func _holds_program(folder: String) -> bool:
	for f in PROGRAM_FILES:
		if FileAccess.file_exists(folder.path_join(f)):
			return true
	return false


## The folder this process runs from: where a relative path points.
static func _working_folder() -> String:
	var d := DirAccess.open(".")
	return d.get_current_dir() if d != null else ""


## Where an old release folder may sit beside the new one (release_parents),
## for this launch.
static func _release_parents() -> Array[String]:
	var appimage: String = OS.get_environment("APPIMAGE")
	var downloads: Array[String] = []
	if appimage != "":
		downloads = _downloads_folders()   # asks xdg-user-dir: only when it is needed
	return release_parents(OS.get_executable_path(), _working_folder(), appimage, downloads)


## Where an old release folder may sit beside the new one: the folders that
## hold the program's folder (`exe`'s) and the working folder (`here`).
## A Linux AppImage (`appimage`, the APPIMAGE variable its runtime sets: the
## .AppImage file) runs from a temporary mount, /tmp/.mount_*/usr/bin, which
## no old folder sits beside. The .tar.gz it replaces was extracted to a
## folder of its own, mostly in Downloads, and run from there; the AppImage
## is a single file, in Downloads or a folder of the user's choosing
## (README.md: Applications). So for an AppImage: the folder holding the
## .AppImage file, the working folder itself (the runtime doesn't change it,
## so it is where the AppImage was started) and `downloads`.
static func release_parents(exe: String, here: String, appimage: String = "", downloads: Array[String] = []) -> Array[String]:
	var out: Array[String] = []
	var folders: Array[String] = [here]
	if appimage == "":
		folders.push_front(exe.get_base_dir())
	for dir in folders:
		var up: String = dir.get_base_dir()
		if up != "" and up != dir and not out.has(up):
			out.append(up)
	if appimage != "":
		var dirs: Array[String] = [appimage.get_base_dir(), here]
		dirs.append_array(downloads)
		for dir in dirs:
			if dir.is_absolute_path() and not out.has(dir):
				out.append(dir)
	return out


## The Downloads folders, where a release was mostly downloaded and extracted:
## the one xdg-user-dir names and ~/Downloads. Without xdg-user-dir on PATH
## Godot says "" or "."; without a user-dirs.dirs, xdg-user-dir says the home
## folder, while ~/Downloads may well be there.
static func _downloads_folders() -> Array[String]:
	var out: Array[String] = []
	var home: String = OS.get_environment("HOME")
	for d in [OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS), home.path_join("Downloads") if home != "" else ""]:
		if str(d).is_absolute_path() and DirAccess.dir_exists_absolute(d) and not out.has(d):
			out.append(d)
	return out


## Open `path`; seed it if it is the default vault being created for the first
## time; fall back to `fallback_dir` if `path` cannot be created or read.
static func open_startup_vault(path: String, default_vault: String, remember: bool,
		fallback_dir: String = OS.get_user_data_dir().path_join("vault")) -> void:
	first_run = StarterContent.is_first_run(path, default_vault)
	startup_warning = ""
	var stood_in: bool = false   # the fallback opened in place of `path`, unreadable
	var hidden_by: String = _unlistable_ancestor(path)
	if hidden_by != "":
		# Nothing is created there: the vault may well exist, out of sight.
		_fall_back_unreadable(path, "it is inside %s, which can't be opened" % hidden_by, fallback_dir, remember)
		stood_in = true
	else:
		open_vault(path, remember)
		if not DirAccess.dir_exists_absolute(vault_path):
			startup_warning = "Couldn't create your notes folder at %s, so notes are kept in %s instead." % [path, fallback_dir]
			push_warning(startup_warning)
			first_run = StarterContent.is_first_run(fallback_dir, fallback_dir)
			open_vault(fallback_dir, remember)
		else:
			var problem: String = access_problem(vault_path)
			if problem != "":
				_fall_back_unreadable(path, problem, fallback_dir, remember)
				stood_in = true
			else:
				startup_warning = _left_in_fallback(fallback_dir) if first_run else _kept_in_fallback(fallback_dir)
				if startup_warning != "":
					kept_in_fallback = VaultRegistry.normalize(fallback_dir)
	var hidden: String = hidden_notes_warning()
	if hidden != "":
		startup_warning = hidden if startup_warning == "" else startup_warning + "  ·  " + hidden
	if first_run:
		StarterContent.seed_vault()
	if stood_in and remember:
		_begin_stand_in(path)
	var unsafe: String = unsafe_warning()
	if unsafe != "":
		startup_warning = unsafe if startup_warning == "" else startup_warning + "  ·  " + unsafe


## The folder `path` can't be seen because a folder above it can't be listed
## (macOS refused the app access to Documents, or its permissions are 000):
## that folder, or "" when `path` exists or its nearest existing folder can
## be listed. A vault in such a folder looks missing although it may hold the
## user's notes, so it is the can't-read case, not a folder to create.
static func _unlistable_ancestor(path: String) -> String:
	var dir: String = VaultRegistry.normalize(path).trim_suffix("/")
	if DirAccess.dir_exists_absolute(dir):
		return ""
	while not DirAccess.dir_exists_absolute(dir):
		var up: String = dir.get_base_dir()
		if up == dir or up == "":
			return ""
		dir = up
	return dir if DirAccess.open(dir) == null else ""


## The user's vault folder `path` can't be read (`problem` says why): an
## empty window would look like data loss, so say why and keep notes in
## `fallback_dir`. `path` stays the last vault, so each launch tries it again
## (and warns again while it is still unreadable) and opens it once access is
## granted; remembering the fallback as last would hide the user's notes for
## good. The fallback joins the recent vaults, so notes kept there stay
## reachable.
## On a Mac the warning also says how to allow Documents, and to move the
## notes there before opening the app again: a launch that can read it but
## finds no folder at `path` makes a new one with only the starter notes
## (_left_in_fallback). Never onto a folder already there, which may be the
## user's own vault, out of the app's sight (macOS asked again after an
## update, or Documents Folder was turned off): then the next launch opens
## that vault and says how to import the notes kept meanwhile
## (_kept_in_fallback).
## A new fallback is seeded with the starter notes only when the app has
## never opened `path` (_known_vault): a first launch after Don't Allow. A
## user whose vault it stands in for has them there already, and an import
## of the fallback would bring back the ones they edited or deleted.
static func _fall_back_unreadable(path: String, problem: String, fallback_dir: String, remember: bool) -> void:
	startup_warning = "Ontomeme can't read your notes folder at %s (%s). Notes are kept in %s for now." % [path, problem, fallback_dir]
	if _mac:
		var folder: String = VaultRegistry.normalize(path).trim_suffix("/")
		startup_warning += (" To move them there: quit Ontomeme, turn on System Settings › Privacy & Security › Files and Folders › Ontomeme › Documents Folder,"
				+ " then, before you open Ontomeme again, rename %s to %s and move it into %s, unless a folder of that name is already there."
				+ " If one is, don't replace it: open Ontomeme and click ↓ Import at the bottom of the sidebar to bring them in from %s.") % [
				VaultRegistry.display_name(fallback_dir), folder.get_file(), folder.get_base_dir(), VaultRegistry.normalize(fallback_dir).trim_suffix("/")]
	push_warning(startup_warning)
	first_run = StarterContent.is_first_run(fallback_dir, fallback_dir) and not _known_vault(path)
	open_vault(fallback_dir, false)
	if remember:
		VaultRegistry.remember(fallback_dir)
		VaultRegistry.remember(path)   # last again, and first in the recent list


## This launch made a new default vault (first_run, seeded with the starter
## notes only) while an earlier one kept notes in `fallback_dir`, which is
## still among the recent vaults: after macOS Don't Allow, access was granted
## before the notes were moved to Documents. They are still in the fallback,
## so say so and how to open them; "" when there is no such fallback.
static func _left_in_fallback(fallback_dir: String) -> String:
	var fallback: String = VaultRegistry.normalize(fallback_dir)
	if fallback == vault_path or not VaultRegistry.recent().has(fallback):
		return ""
	var shown: String = VaultRegistry.display_name(fallback)
	return "Notes kept in %s while Ontomeme couldn't reach this folder are still there, not in this new one: click the folder name at the top of the sidebar and choose %s to open them (%s)." % [
			shown, shown, fallback.trim_suffix("/")]


## This launch opened a vault that was already there while `fallback_dir`
## stands in for it (_begin_stand_in): macOS refused Documents with the
## user's vault in it, and notes were written in the fallback meanwhile.
## When some notes there, written or changed since it began standing in,
## have no copy in this vault (_kept_notes), say how many and how to import
## them; "" otherwise. So it says nothing more once they are imported, or
## once the user has opened the fallback (open_vault forgets the stand-in).
static func _kept_in_fallback(fallback_dir: String) -> String:
	var fallback: String = VaultRegistry.normalize(fallback_dir)
	if fallback == vault_path:
		return ""
	var n: int = _kept_notes(fallback).size()
	if n == 0:
		return ""
	return "%s written in %s while Ontomeme couldn't reach this folder %s still there, not here: click ↓ Import at the bottom of the sidebar and import %s to bring %s in." % [
			"1 note" if n == 1 else "%d notes" % n, VaultRegistry.display_name(fallback),
			"is" if n == 1 else "are", fallback.trim_suffix("/"), "it" if n == 1 else "them"]


## The note files in the fallback vault `fallback` (absolute, normalized)
## that the open vault lacks, when `fallback` stands in for it
## (STAND_IN_FILE): each written or changed since the stand-in began, that
## loads as a note (an import would take it) and has no copy here, the same
## title or a numbered one with the same text and tags (import_title).
static func _kept_notes(fallback: String) -> Array[String]:
	var out: Array[String] = []
	var file: String = data_dir_of(fallback).path_join(STAND_IN_FILE)
	if not FileAccess.file_exists(file):
		return out
	var stand_in: Variant = JSON.parse_string(FileAccess.get_file_as_string(file))
	if not (stand_in is Dictionary and (stand_in as Dictionary).get("notes") is Dictionary
			and VaultRegistry.normalize(str(stand_in.get("for", ""))) == vault_path):
		return out
	var before: Dictionary = stand_in.notes
	for rel in _note_files(fallback):
		var path: String = fallback + rel
		if str(before.get(rel, "")) == FileAccess.get_sha256(path):
			continue
		var note: ContentLayer = _load_foreign_note(path)
		if note != null and import_title(note.title, note.raw_text, note.tags).twin == null:
			out.append(path)
	return out


## The fallback (the open vault) began standing in for `path`, which can't
## be read: note in its STAND_IN_FILE which note files it holds now, so a
## later launch that opens `path` can tell the notes written since
## (_kept_in_fallback). A file already standing in for `path` is kept: each
## launch while access is refused adds to the same notes.
static func _begin_stand_in(path: String) -> void:
	var file: String = data_dir().path_join(STAND_IN_FILE)
	var target: String = VaultRegistry.normalize(path)
	if FileAccess.file_exists(file):
		var was: Variant = JSON.parse_string(FileAccess.get_file_as_string(file))
		if was is Dictionary and (was as Dictionary).get("notes") is Dictionary and VaultRegistry.normalize(str(was.get("for", ""))) == target:
			return
	var notes: Dictionary = {}
	for rel in _note_files(vault_path):
		notes[rel] = FileAccess.get_sha256(vault_path + rel)
	DirAccess.make_dir_recursive_absolute(data_dir())
	atomic_write_text(JSON.stringify({"for": target, "notes": notes}, "\t"), file)


## The .tres files in the vault folder `root` (absolute, ending in "/"),
## relative to it: in each folder a scan of it enters (_should_descend),
## without following a link.
static func _note_files(root: String, rel: String = "", visited: Dictionary = {}) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(root + rel)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.get_extension().to_lower() == "tres":
			out.append(_join(rel, f))
	for d in dir.get_directories():
		if _should_descend(root, rel, d, visited, false):
			out.append_array(_note_files(root, _join(rel, d), visited))
	return out


## Whether the app has opened the vault at `path` before: it is in
## user://vaults.json, which keeps it while it can't be seen.
static func _known_vault(path: String) -> bool:
	var p: String = VaultRegistry.normalize(path)
	var stored: Dictionary = VaultRegistry._read()
	for v in [stored.last] + stored.recent:
		if str(v) != "" and VaultRegistry.normalize(str(v)) == p:
			return true
	return false


## Why the app can't use the existing folder `dir` ("" = it can list it and
## write in it). Writes and removes <dir>/.ontomeme/.write-test to find out.
## (Godot reports any failure to open a folder as "invalid parameter", so
## the error code would tell the user nothing.)
static func access_problem(dir: String) -> String:
	if DirAccess.open(dir) == null:
		return "its contents can't be listed"
	var data: String = dir.path_join(".ontomeme")
	if not DirAccess.dir_exists_absolute(data) and DirAccess.make_dir_absolute(data) != OK:
		return "nothing can be written in it"
	var probe: String = data.path_join(".write-test")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return "nothing can be written in it"
	f.close()
	DirAccess.remove_absolute(probe)
	return ""


static func _cmdline_vault() -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--vault="):
			return true
	return false


## Switch to the vault at `path` (created if missing). Opened as the user's
## vault (`remember`), a fallback no longer stands in for another
## (STAND_IN_FILE): its notes are in view.
static func open_vault(path: String, remember: bool = true) -> void:
	vault_path = VaultRegistry.normalize(path)
	kept_in_fallback = ""
	_create_vault()
	if remember and FileAccess.file_exists(data_dir().path_join(STAND_IN_FILE)):
		DirAccess.remove_absolute(data_dir().path_join(STAND_IN_FILE))
	_migrate_hidden_dir()
	_recover_tmp_files()
	_mtimes.clear()
	_sizes.clear()
	_hashes.clear()
	_unsaved_paths.clear()
	editor_note = null
	_bad_stamps.clear()
	_bad_hashes.clear()
	_hashed_at.clear()
	_sig_hashes.clear()
	note_list.clear()
	if remember:
		VaultRegistry.remember(vault_path)
	ProgressStore.invalidate()
	JourneyStore.invalidate()
	refresh_note_list()


## Vault-local app data (progress, journey) lives in <vault>/.ontomeme.
static func data_dir() -> String:
	return data_dir_of(vault_path)


## The data folder of the vault at `vault` (which needn't be the open one).
static func data_dir_of(vault: String) -> String:
	return vault.path_join(".ontomeme")


static func _migrate_hidden_dir() -> void:
	var old: String = vault_path.path_join(".senedril")
	if DirAccess.dir_exists_absolute(old) and not DirAccess.dir_exists_absolute(data_dir()):
		DirAccess.rename_absolute(old, data_dir())


## Deal with temp files in .ontomeme/tmp that a save never finished (a
## crash, or a failed rename on Windows; see _move_tmp_into_place), newest
## first:
## - one whose note file is missing and that holds a whole note is the only
##   copy of that note: it is moved back into place;
## - any other one older than a day is removed: its note on disk is whole.
## Files younger than TMP_SETTLE_SEC are left alone.
static func _recover_tmp_files() -> void:
	var dir: String = vault_path.path_join(TMP_DIR)
	if not DirAccess.dir_exists_absolute(dir):
		return
	var now: int = int(Time.get_unix_time_from_system())
	var files: Array = Array(DirAccess.get_files_at(dir))
	files.sort()
	files.reverse()   # names start with a millisecond stamp: newest first
	for f in files:
		var tmp: String = dir.path_join(f)
		var age: int = now - FileAccess.get_modified_time(tmp)
		if age < TMP_SETTLE_SEC:
			continue
		var rel: String = _tmp_target(f)
		if rel != "":
			var target: String = _resolve_links(vault_path + rel)
			if not FileAccess.file_exists(target) and _whole_note(tmp):
				DirAccess.make_dir_recursive_absolute(target.get_base_dir())
				if DirAccess.rename_absolute(tmp, target) == OK:
					push_warning("[VaultStore] Restored %s from a save that didn't finish" % rel)
					continue
		if age > TMP_MAX_AGE_SEC:
			DirAccess.remove_absolute(tmp)


## The vault-relative note path a temp file's name carries, or "" (an older
## or overlong name, or anything that isn't a plain path inside the vault).
static func _tmp_target(name: String) -> String:
	var parts: PackedStringArray = name.split("-", true, 2)
	if parts.size() < 3 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return ""
	var rel: String = parts[2].uri_decode()
	if rel == "" or rel.is_absolute_path() or rel.begins_with(".") or rel.contains("\\") or rel.contains(":") or ".." in rel.split("/"):
		return ""
	return rel if rel.get_extension() in ["tres", "txt"] else ""


## True when the temp file at `path` holds a whole note: a .tres that loads
## as a ContentLayer (checked for its [resource] section first, so a file cut
## off early isn't even parsed), or any non-empty text file.
static func _whole_note(path: String) -> bool:
	var text: String = FileAccess.get_file_as_string(path)
	if path.get_extension() != "tres":
		return text != ""
	return text.contains("\n[resource]\n") and ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) is ContentLayer


# ---------------------------------------------------------------------------
# Atomic writes
# ---------------------------------------------------------------------------

## Save `res` to `abs_path` without ever leaving half a file there:
## ResourceSaver writes a temp file in <vault>/.ontomeme/tmp, which is then
## renamed over the target (replacing an existing file, on Windows too). On
## a failure the error is returned and the temp file is removed, so the
## target is as it was; except when a Windows rename deleted the target and
## then failed: the temp file is then its only copy and is kept for
## open_vault to put back (_move_tmp_into_place). `vault` is the vault
## holding `abs_path` (default: the open one); the temp file sits there so
## the rename stays on one volume.
## The rename must not change what a plain write would have kept:
## - a note that is a symlink (to a git repo, another folder) is followed, so
##   the file it points to gets the new version and the link stays a link;
## - a file the user made read-only (chmod 444, the read-only attribute) is
##   refused with ERR_FILE_CANT_WRITE, where a rename would replace it;
## - the file's permissions (say 600) carry over to the new version.
## A temp file that didn't get written in full (disk full, quota, a network
## share) is never renamed over the note: ResourceSaver checks for an error
## before it closes the file, so a small note whose buffered bytes fail at
## close comes back OK as a truncated file. The temp file is read back
## (saved_matches) and a short one fails with ERR_FILE_CANT_WRITE.
static func atomic_save(res: Resource, abs_path: String, vault: String = "") -> Error:
	var target: String = _resolve_links(abs_path)
	if not _writable(target):
		return ERR_FILE_CANT_WRITE
	var tmp: String = _new_tmp_path(vault, abs_path)
	if tmp == "":
		return ERR_CANT_CREATE
	var written: Error = ResourceSaver.save(res, tmp)
	if written == OK and not saved_matches(res, tmp):
		written = ERR_FILE_CANT_WRITE
	return _move_tmp_into_place(tmp, target, written)


## atomic_save for a plain-text file (the MCP server's .txt notes, the
## app.lock), as UTF-8, after a BOM when `bom`. The temp file is read back
## before the rename, so a write that failed partway (caught only when the
## buffer is flushed) never replaces the file.
static func atomic_write_text(text: String, abs_path: String, vault: String = "", bom: bool = false) -> Error:
	var target: String = _resolve_links(abs_path)
	if not _writable(target):
		return ERR_FILE_CANT_WRITE
	var tmp: String = _new_tmp_path(vault, abs_path)
	if tmp == "":
		return ERR_CANT_CREATE
	var bytes: PackedByteArray = text.to_utf8_buffer()
	if bom:
		bytes = PackedByteArray([0xEF, 0xBB, 0xBF]) + bytes
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	var stored: bool = f.store_buffer(bytes)
	f.flush()
	var err: Error = f.get_error()
	f.close()
	if err == OK and (not stored or FileAccess.get_file_as_bytes(tmp) != bytes):
		err = ERR_FILE_CANT_WRITE
	return _move_tmp_into_place(tmp, target, err)


## True when the .tres at `path` loads as a resource whose every saved
## property equals res's. Compared through var_to_str, the text the saver
## itself writes, so floats in a dictionary compare as written. A file cut
## off at a line boundary still parses, with the properties after the cut at
## their defaults: this comparison catches that.
static func saved_matches(res: Resource, path: String) -> bool:
	var back: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if back == null:
		return false
	for p: Dictionary in res.get_property_list():
		if not (int(p.usage) & PROPERTY_USAGE_STORAGE) or p.name == "script":
			continue
		if var_to_str(back.get(p.name)) != var_to_str(res.get(p.name)):
			return false
	return true


## The file `path` really names: `path` itself, or for a symlink the file at
## the end of the chain (a relative link counts from the link's folder).
static func _resolve_links(path: String) -> String:
	for i in range(16):   # a loop of links stops here
		var dir := DirAccess.open(path.get_base_dir())
		if dir == null or not dir.is_link(path):
			return path
		var to: String = dir.read_link(path)
		if to == "":
			return path
		path = to if to.is_absolute_path() else path.get_base_dir().path_join(to).simplify_path()
	return path


## True unless `path` exists and can't be opened for writing (read-only file,
## another program's lock). Opening READ_WRITE neither truncates nor touches it.
static func _writable(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return true
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		return false
	f.close()
	return true


## A new temp file path for saving `abs_path`, "" if the temp folder can't
## be made: <vault>/.ontomeme/tmp/<stamp>-<rand>-<note path in the vault,
## uri-encoded>, so open_vault knows where a left-over one belongs. It ends
## in the note's extension, which picks ResourceSaver's format. An overlong
## path, or one outside the vault, gives <stamp>-<rand>.<ext>.
static func _new_tmp_path(vault: String, abs_path: String) -> String:
	var root: String = vault if vault != "" else vault_path
	var dir: String = root.path_join(TMP_DIR)
	if not DirAccess.dir_exists_absolute(dir) and DirAccess.make_dir_recursive_absolute(dir) != OK:
		return ""
	var name: String = "%d-%d" % [int(Time.get_unix_time_from_system() * 1000.0), randi()]
	var rel: String = abs_path.substr(root.length()).uri_encode() if abs_path.begins_with(root) else ""
	var full: String = dir.path_join(name + "-" + rel)
	if rel != "" and rel.length() <= TMP_NAME_MAX and full.length() <= TMP_PATH_MAX:
		return full
	return dir.path_join(name + "." + abs_path.get_extension())


static func _rename(from: String, to: String) -> Error:
	if rename_hook.is_valid():
		return rename_hook.call(from, to)
	return DirAccess.rename_absolute(from, to)


## Rename the written temp file over `abs_path`, with the permissions of the
## file it replaces; remove it instead when writing it failed (`written` !=
## OK) or the rename does.
## Windows is the exception: Godot's rename there deletes an existing target
## (DeleteFileW) before moving the new file in (MoveFileW). If the move then
## fails (a sync client or a virus scanner holding the fresh temp file), the
## old version is gone and the temp file is the only copy of the note. It is
## moved once more, now that nothing is in its way, and if that fails too it
## is kept: open_vault moves it back into place (_recover_tmp_files).
static func _move_tmp_into_place(tmp: String, abs_path: String, written: Error) -> Error:
	if written != OK:
		_remove_tmp(tmp)
		return written
	var existed: bool = FileAccess.file_exists(abs_path)
	if existed and OS.get_name() != "Windows":
		var mode: int = FileAccess.get_unix_permissions(abs_path)
		if mode != 0:
			FileAccess.set_unix_permissions(tmp, mode)
	if _rename(tmp, abs_path) == OK:
		return OK
	if existed and not FileAccess.file_exists(abs_path) and FileAccess.file_exists(tmp):
		if _rename(tmp, abs_path) == OK:
			return OK
		push_warning("[VaultStore] %s was replaced but its new version couldn't be moved in; kept as %s until the next start" % [abs_path, tmp])
		return ERR_FILE_CANT_WRITE
	_remove_tmp(tmp)
	return ERR_FILE_CANT_WRITE   # rename only says FAILED; "Can't write file" tells the user more


static func _remove_tmp(tmp: String) -> void:
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

## Create the vault directory if it does not exist.
static func _create_vault() -> void:
	if not DirAccess.dir_exists_absolute(vault_path):
		DirAccess.make_dir_recursive_absolute(vault_path)


## File stem for a note title: "My Note!" → "note_my_note". Pure (no vault
## state), so the MCP tools name files exactly the way the app does. A slug
## longer than MAX_SLUG_CHARS is cut and ends in "_" and 8 hex digits of the
## title's SHA-256, so two long titles that differ only near their end get
## two files, and the file name stays far below the 255-byte limit of ext4,
## APFS and NTFS (a 360-character title made a name ResourceSaver could not
## write, so the note never reached the disk).
## A title with no letter or digit a-z, 0-9 (Japanese, Greek, Cyrillic) is
## "note_u" and those 8 hex digits: each such title gets a file of its own,
## where all of them were note_untitled, and MCP create_note refused the
## second as already there. A title that has such letters beside Latin ones
## or digits ("Godot入門", "Глава 1") keeps its slug and also ends in "_" and
## the hash, since the slug alone ("note_godot", "note__1") is shared with
## other titles: MCP create_note refused the second as `exists`, and an
## agent told to update the note there would have overwritten another one.
## A title of ASCII letters and digits is named without the hash, as before.
## A blank title is "note_untitled".
static func filename_stem(title: String) -> String:
	var base: String = _slug(title)
	if base.replace("_", "").replace("-", "") == "":
		base = "untitled" if title.strip_edges() == "" else "u" + _title_hash(title)
	elif base.length() > MAX_SLUG_CHARS or _non_ascii_word_re.search(title) != null:
		base = base.left(MAX_SLUG_CHARS - 9).rstrip("_-") + "_" + _title_hash(title)
	if not base.begins_with("note_"):
		base = "note_" + base
	return base


## A title as it goes into a file name: lower case, a space as "_", and only
## a-z, 0-9, _ and - kept, so the name is the same on every system.
static func _slug(title: String) -> String:
	var base: String = title.replace(" ", "_").to_lower().strip_edges()
	var clean: String = ""
	for ch in base:
		clean += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-" else ""
	return clean


## The first 8 hex digits of the SHA-256 of `title` without its outer spaces.
static func _title_hash(title: String) -> String:
	return title.strip_edges().sha256_text().left(8)


## Generate a unique filename (relative to the vault) for a new note: the
## title's stem, or stem_1, stem_2… when that file is taken. `own_path` (an
## absolute path) counts as free: it is the file of the note being named.
static func _unique_filename(title: String, folder: String = "", own_path: String = "") -> String:
	var base: String = filename_stem(title)
	var prefix: String = (folder.trim_suffix("/") + "/") if folder != "" else ""
	var stem: String = base
	var i: int = 1
	while _file_exists(prefix + stem + ".tres") and vault_path + prefix + stem + ".tres" != own_path:
		stem = base + "_" + str(i)
		i += 1
	return prefix + stem + ".tres"


## Check if a file exists in the vault (path relative to the vault).
static func _file_exists(filename: String) -> bool:
	return FileAccess.file_exists(vault_path + filename)


## True for a folder the scans leave out: hidden (".ontomeme", ".trash"), a
## root asset folder (ASSET_DIRS: "models", "images"), or a Markdown export folder, which carries
## MdExport.MARKER at any depth. `name` is a subfolder of `rel`; `root` is
## the vault both are relative to ("" = the open vault).
static func _is_skipped_dir(rel: String, name: String, root: String = "") -> bool:
	if name.begins_with(".") or (rel == "" and name in ASSET_DIRS):
		return true
	var sub: String = rel.path_join(name) if rel != "" else name
	return FileAccess.file_exists((root if root != "" else vault_path).path_join(sub).path_join(MdExport.MARKER))


## Whether a scan of the vault at `root` (absolute, ending in "/") goes from
## its folder `rel` into the subfolder `name`. Every scan of the vault asks
## this: the app's (_scan, _sig) and the MCP tools' (VaultTools._scan).
##
## Never into a skipped folder (_is_skipped_dir), nor below MAX_SCAN_DEPTH.
## A symbolic link (or Windows junction) is followed only when
## `follow_outside` is true, and only to a folder outside the vault that
## holds neither the vault nor `rel`, and that this scan has not entered
## through a link already (`visited`, real paths, filled here). A link into
## the vault is not followed: its folder is scanned where it really is, and
## following it would list each note twice, or without end when it leads
## back up (`sub/up -> ..` listed every note 41 times; `a -> .` plus
## `b -> .` never finished).
static func _should_descend(root: String, rel: String, name: String, visited: Dictionary, follow_outside: bool = true) -> bool:
	if _is_skipped_dir(rel, name, root) or _depth(rel) >= MAX_SCAN_DEPTH:
		return false
	var here: String = root.path_join(rel)
	if not _is_link(here.path_join(name)):
		return true
	var real_here: String = _real_path(here)
	var target: String = _real_path(here.path_join(name))
	if real_here == "" or target == "":
		return false
	if _same_path(target, real_here.path_join(name)):
		return true   # a Windows reparse point under a junction that is no link itself (_link_target)
	var real_root: String = _real_path(root)
	if not follow_outside or real_root == "":
		return false
	if _is_within(target, real_root) or _is_within(real_root, target) or _is_within(real_here, target):
		return false
	for seen: String in visited:
		if _is_within(target, seen):
			return false
	visited[target] = true
	return true


## Where the path `rel` inside the vault at `root` really leads, relative to
## the vault ("" for the vault itself), or null when a symbolic link (or
## junction) on the way leads out of it. Each part of `rel` is checked with
## is_link: without a link on the way `rel` is its own answer; with one, the
## whole path is resolved (_real_path) and must stay in the vault, which is
## resolved the same way. `rel` must hold no "." or ".." part.
static func _real_rel(root: String, rel: String) -> Variant:
	var dir := DirAccess.open(root)
	if dir == null:
		return null
	var at: String = root.trim_suffix("/")
	for part in rel.split("/", false):
		at = at.path_join(part)
		if _link_target(dir, at) != null:
			var real: String = _real_path(root.path_join(rel))
			var real_root: String = _real_path(root)
			if real == "" or real_root == "" or not _is_within(real, real_root):
				return null
			return real.substr(real_root.trim_suffix("/").length() + 1)
	return rel


## Folder levels below the vault: "" is 0, "Physics/Waves" is 2.
static func _depth(rel: String) -> int:
	return 0 if rel == "" else rel.count("/") + 1


## Whether the absolute `path` is a symbolic link or a Windows junction.
static func _is_link(path: String) -> bool:
	var dir := DirAccess.open(path.get_base_dir())
	return dir != null and _link_target(dir, path) != null


## Where the link at the absolute `path` leads, as stored (relative to its
## folder, or absolute); "" when it can't be read; null when `path` is no
## link. `dir` is any open DirAccess. On Windows is_link is true for every
## reparse point and read_link gives the final path, so a OneDrive or
## deduplicated folder, which leads to itself, is no link.
static func _link_target(dir: DirAccess, path: String) -> Variant:
	if not dir.is_link(path):
		return null
	var target: String = _link_text(dir.read_link(path))
	return null if _same_path(target, path) else target


## read_link's answer `raw` as a path with "/". On Windows it is the link's
## final path with only its "\\?\" prefix taken off: "C:\..." on a drive,
## "UNC\server\share\..." on a network share or a mapped drive, which
## becomes "//server/share/...". Any other answer there has no root and is
## "" (can't be read), never a path relative to the link: "UNC/..." taken
## that way put a network share inside the vault, so the MCP tools reached
## it and the app's scan stopped listing it.
static func _link_text(raw: String) -> String:
	var target: String = raw.replace("\\", "/").trim_prefix("//?/")
	if not _windows:
		return target
	if target.left(4).to_upper() == "UNC/":
		target = "/" + target.substr(3)
	return target if _path_root(target) != "" else ""


## Whether `path` is the folder `dir` or lies inside it (both absolute).
static func _is_within(path: String, dir: String) -> bool:
	var inside: String = dir.trim_suffix("/") + "/"
	return _same_path((path.trim_suffix("/") + "/").left(inside.length()), inside)


## Two absolute paths name the same place: compared without case on
## Windows, where read_link gives a path in the case stored on disk.
static func _same_path(a: String, b: String) -> bool:
	return a.nocasecmp_to(b) == 0 if _windows else a == b


## The absolute `path` with each symbolic link in it resolved, the way
## realpath(3) does, so two paths to one folder compare equal. Parts that do
## not exist are kept as written. "" when it passes more than MAX_LINK_HOPS
## links (a loop), a link can't be read, or `path` is not absolute.
static func _real_path(path: String) -> String:
	path = path.replace("\\", "/")
	var real: String = _path_root(path)
	var dir := DirAccess.open(real) if real != "" else null
	if dir == null:
		return ""
	var todo: PackedStringArray = _parts_reversed(path.substr(real.length()))
	var hops: int = 0
	while not todo.is_empty():
		var part: String = todo[-1]
		todo.remove_at(todo.size() - 1)
		if part == "..":
			real = real.get_base_dir()
		elif part != ".":
			var next: String = real.path_join(part)
			var target: Variant = _link_target(dir, next)
			if target == null:
				real = next
				continue
			hops += 1
			if hops > MAX_LINK_HOPS or target == "":
				return ""
			var target_root: String = _path_root(target)
			if target_root != "":
				real = target_root   # an absolute link starts over from there
			todo.append_array(_parts_reversed((target as String).substr(target_root.length())))
	return real


## "/", the Windows drive ("C:/") or, on Windows, the network share
## ("//server/share/") that `path` starts with; "" if relative, or a "//"
## path on Windows that names no share.
static func _path_root(path: String) -> String:
	if _windows and path.begins_with("//"):
		var share: PackedStringArray = path.substr(2).split("/")
		if share.size() < 2 or share[0] == "" or share[1] == "":
			return ""
		return "//%s/%s/" % [share[0], share[1]]
	if path.begins_with("/"):
		return "/"
	if path.length() >= 3 and path[1] == ":" and path[2] == "/":
		return path.left(3)
	return ""


## The parts of `path` between slashes, last first (a stack for _real_path).
static func _parts_reversed(path: String) -> PackedStringArray:
	var parts: PackedStringArray = path.split("/", false)
	parts.reverse()
	return parts


## Why the vault folder `rel` can't hold notes ("" if it can): it is, or is
## inside, a root asset folder (images/, models/). A note there would drop
## out of every list, the app's and the MCP's, so nothing puts one there.
static func asset_refusal(rel: String) -> String:
	var top: String = rel.trim_prefix("/").get_slice("/", 0)
	var dir: String = asset_dir_named(vault_path, top)
	if dir == "":
		return ""
	var kind: String = ASSET_KINDS.get(dir, "asset")
	if top == dir:
		return "“%s” is the vault's %s folder, so it can't hold notes" % [top, kind]
	return "“%s” is the vault's %s folder (%s/) on Windows and macOS, so it can't hold notes" % [top, kind, dir]


## The root asset folder (an ASSET_DIRS name) that a folder `top` at the root
## of `vault` is, or "" for an ordinary folder. Windows and macOS ignore case
## (Windows also drops trailing dots and spaces), so there "Images" opens
## images/, and a note written to Images/ lands in the picture folder that
## no list shows. Any spelling that folds to an asset folder's name counts,
## on every system, so a vault made on Linux opens the same elsewhere; the
## one exception is a folder by exactly that name already on disk: the lists
## show it (_is_skipped_dir goes by the real name), so its notes are seen.
## Static and given the vault, so the MCP (mcp/vault_tools.gd) asks it too.
static func asset_dir_named(vault: String, top: String) -> String:
	var dir: String = top.rstrip(" .").to_lower()
	if dir not in ASSET_DIRS:
		return ""
	if top != dir:
		var root := DirAccess.open(vault)
		if root != null and top in root.get_directories():
			return ""   # Linux: its own folder beside images/; Windows, macOS: the real name, listed
	return dir


## Note files inside a root asset folder, relative to the vault, sorted:
## exactly the ones no list shows. A vault from before images/ was the
## picture folder can hold some: a user's own top-level "images" folder of
## notes. The root's folders are taken by their real names, as the lists
## take them, because on Windows and macOS opening "images" by name would
## also open a user's own "Images", which the lists show.
static func notes_in_asset_dirs() -> Array[String]:
	var out: Array[String] = []
	var root := DirAccess.open(vault_path)
	if root == null:
		return out
	for d in root.get_directories():
		if d in ASSET_DIRS:   # exactly the names _is_skipped_dir hides (not a Markdown export folder)
			_collect_notes(d, out, 0)
	out.sort()
	return out


static func _collect_notes(rel: String, out: Array[String], depth: int) -> void:
	var dir := DirAccess.open(vault_path + rel)
	if dir == null or depth > 16:
		return
	for d in dir.get_directories():
		if not d.begins_with(".") and not dir.is_link(vault_path + rel.path_join(d)):
			_collect_notes(rel.path_join(d), out, depth + 1)
	for f in dir.get_files():
		if f.ends_with(".tres"):
			out.append(rel.path_join(f))


## The status-line warning for notes_in_asset_dirs() ("" if there are none):
## how many, where, and that moving them out shows them again. The app shows
## it when it opens a vault.
static func hidden_notes_warning() -> String:
	var files: Array[String] = notes_in_asset_dirs()
	if files.is_empty():
		return ""
	var dirs: PackedStringArray = []
	var kinds: PackedStringArray = []
	for f in files:
		var top: String = f.get_slice("/", 0)
		if not dirs.has(top + "/"):
			dirs.append(top + "/")
			kinds.append(ASSET_KINDS.get(top, "asset"))
	var n: int = files.size()
	var where: String = " and ".join(dirs)
	var what: String = ("%s is the vault's %s folder" % [where, kinds[0]]) if dirs.size() == 1 \
		else "those are the vault's %s folders" % " and ".join(kinds)
	var it: String = "it" if n == 1 else "them"
	return "%d note%s in %s %s hidden: %s. Move %s to another folder to see %s." % [
		n, "" if n == 1 else "s", where, "is" if n == 1 else "are", what, it, it]


## Refresh the note list by scanning the vault folder and its subfolders.
## A note changed on disk is reloaded in place, except one whose words the
## app holds: a failed save (_unsaved_paths), or the editor's note unless
## `reload_editor_note` (the watcher, which then shows the new text).
## A note listed with a title a note in the trash had, which it didn't have
## before (written outside the app: the MCP server, a sync tool), never takes
## over that note's Learning Journey objectives (JourneyStore.notes_listed).
static func refresh_note_list(reload_editor_note: bool = false) -> void:
	refresh_count += 1
	var was: Dictionary = {}   # path → title, before this scan
	for note in note_list:
		was[note.resource_path] = note.title
	note_list.clear()
	folders.clear()
	unsafe_files.clear()
	unreadable.clear()
	_scan("", reload_editor_note)
	folders.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	# Pinned first (newest pin on top), then modified descending
	note_list.sort_custom(_sort_by_modified)
	JourneyStore.notes_listed(note_list, was)


static func _scan(rel: String, reload_editor_note: bool, visited: Dictionary = {}) -> void:
	var dir := DirAccess.open(vault_path + rel)
	if dir == null:
		return
	for d in dir.get_directories():
		if _should_descend(vault_path, rel, d, visited):
			var sub: String = rel.path_join(d) if rel != "" else d
			folders.append(sub)
			_scan(sub, reload_editor_note, visited)
	for f in dir.get_files():
		if f.ends_with(".tres"):
			var path: String = vault_path + (rel.path_join(f) if rel != "" else f)
			var changed: bool = _changed_on_disk(path)
			if changed and _holds_words(path, reload_editor_note):
				changed = false   # keep the app's words; the change stays pending (its stat and hash time not updated)
			else:
				_remember_stat(path)
				if changed:
					# Taken in: a reload below takes the new hash. A file that
					# does not load keeps the old one (see _load_note_file) and
					# is not compared by its bytes again once it settles.
					_hashed_at[path] = Time.get_unix_time_from_system()
			var note: ContentLayer = _load_note_file(path, changed)
			if note != null:
				note_list.append(note)


## True when the app holds words for the note file at `path` that a reload
## from disk would replace: a failed save, or the editor's note (see
## editor_note) unless the caller reloads it on purpose.
static func _holds_words(path: String, reload_editor_note: bool) -> bool:
	if _unsaved_paths.has(path):
		return true
	return not reload_editor_note and editor_note != null and editor_note.resource_path == path


## True when a hash taken at `hashed_at` may miss a write to a file with this
## mtime: the write could still land in the mtime's second (see FRESH_SECS).
static func _unsettled(mtime: int, hashed_at: float) -> bool:
	return hashed_at < mtime + FRESH_SECS


## True when a note file is not what the app last loaded or saved: another
## mtime or size, or, while its hash is unsettled, other bytes. Records only
## a hash confirmed unchanged (_hashed_at): the caller records the file's
## mtime and size once it takes a change in (_scan leaves a change to a note
## whose words the app holds pending).
static func _changed_on_disk(path: String) -> bool:
	if not _mtimes.has(path):
		return false
	var mtime: int = FileAccess.get_modified_time(path)
	var size: int = _size_of(path)
	if _mtimes[path] != mtime or _sizes.get(path, size) != size:
		return true
	if size < 0 or not _hashes.has(path) or not _unsettled(mtime, _hashed_at.get(path, 0.0)):
		return false
	if FileAccess.get_sha256(path) != _hashes[path]:
		return true
	_hashed_at[path] = Time.get_unix_time_from_system()
	return false


## True when `note`'s file changed on disk since the app last loaded or
## wrote it, and that change is not taken in yet: a rescan leaves it
## pending while the editor holds the note (editor_note) or its save failed.
static func change_pending(note: ContentLayer) -> bool:
	return note != null and note.resource_path.begins_with(vault_path) and _changed_on_disk(note.resource_path)


## Remember a note file's mtime and size as the app now sees them.
static func _remember_stat(path: String) -> void:
	_mtimes[path] = FileAccess.get_modified_time(path)
	_sizes[path] = _size_of(path)


## The size of the file at `path`, or -1 when it can't be opened (a link to
## nothing, no read permission). Unlike FileAccess.get_size it logs no error
## for those, which every poll of the disk watcher would repeat.
static func _size_of(path: String) -> int:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f != null else -1


## Remember the bytes of a note file the app just loaded or wrote.
static func _remember_hash(path: String) -> void:
	_hashes[path] = FileAccess.get_sha256(path)
	_hashed_at[path] = Time.get_unix_time_from_system()


## Cheap fingerprint of the vault on disk: every folder and note file with
## its modification time and size, plus the SHA-256 of files written within
## FRESH_SECS of their mtime. When it changes, something outside the app (a
## file manager, git, a sync tool, Claude) touched the vault.
static func disk_signature() -> String:
	var parts: PackedStringArray = []
	var hashed: Dictionary = {}
	_sig("", parts, hashed, Time.get_unix_time_from_system())
	_sig_hashes = hashed
	return "\n".join(parts)


## True when the vault on disk (`sig`, a disk_signature()) differs from
## `old_sig` in a way the app hasn't taken in: a folder or note file came or
## went, or a note file's mtime or size isn't the one VaultStore last loaded
## or wrote it with (_mtimes, _sizes), or its line carries a hash of bytes
## the app did not load or write (_hashes: a same-second, same-size write).
## The app's own saves change their files' lines too, but note_list already
## holds them, and rescanning a big vault after each one is a typing hitch
## on every pause.
static func changed_outside(old_sig: String, sig: String) -> bool:
	if sig == old_sig:
		return false
	var was: PackedStringArray = old_sig.split("\n")
	var now: PackedStringArray = sig.split("\n")
	if was.size() != now.size():
		return true
	for i in range(now.size()):
		if now[i] == was[i]:
			continue
		var line: Array = _sig_fields(now[i])
		var old: Array = _sig_fields(was[i])
		if line.is_empty() or old.is_empty() or old[0] != line[0]:
			return true   # another folder or file in this place
		var path: String = vault_path + line[0]
		if int(_mtimes.get(path, -1)) != line[1] or int(_sizes.get(path, -1)) != line[2]:
			return true
		if line[3] != "" and line[3] != _hashes.get(path, ""):
			return true
	return false


## A disk_signature() note line's fields: [rel, mtime, size, SHA-256 or ""]
## (see _sig_line); [] for a folder's line. The rel may hold spaces, and ends
## in ".tres", which no field after it holds.
static func _sig_fields(line: String) -> Array:
	var cut: int = line.rfind(".tres ")
	if line.ends_with("/") or cut < 0:
		return []
	var rest: PackedStringArray = line.substr(cut + 6).split(" ")
	return [line.left(cut + 5), rest[0].to_int(), rest[1].to_int() if rest.size() > 1 else -1, rest[2] if rest.size() > 2 else ""]


static func _sig(rel: String, parts: PackedStringArray, hashed: Dictionary, now: float, visited: Dictionary = {}) -> void:
	var dir := DirAccess.open(vault_path + rel)
	if dir == null:
		return
	for d in dir.get_directories():
		if _should_descend(vault_path, rel, d, visited):
			var sub: String = rel.path_join(d) if rel != "" else d
			parts.append(sub + "/")
			_sig(sub, parts, hashed, now, visited)
	for f in dir.get_files():
		if f.ends_with(".tres"):
			parts.append(_sig_line(rel.path_join(f) if rel != "" else f, hashed, now))


## One note file's line: "<rel> <mtime> <size>", plus its SHA-256 once it was
## seen fresh. The hash stays in the line after the file settles (no false
## change when it leaves the fresh window) and is taken once more after that,
## so a same-second rewrite is caught however late the next poll comes.
static func _sig_line(rel: String, hashed: Dictionary, now: float) -> String:
	var path: String = vault_path + rel
	var mtime: int = FileAccess.get_modified_time(path)
	var size: int = _size_of(path)
	var line: String = "%s %d %d" % [rel, mtime, size]
	if size < 0:
		return line   # can't be read, so no bytes to hash
	var last: Array = _sig_hashes.get(path, [])
	var same: bool = last.size() == 4 and last[0] == mtime and last[1] == size
	if same and not _unsettled(mtime, last[3]):
		hashed[path] = last
		return line + " " + last[2]
	if not same and not _unsettled(mtime, now):
		return line   # first seen after its mtime second: mtime and size suffice
	var entry: Array = [mtime, size, FileAccess.get_sha256(path), now]
	hashed[path] = entry
	return line + " " + entry[2]


## Folder of a note, relative to the vault ("" = top level).
static func folder_of(note: ContentLayer) -> String:
	if note == null or not note.resource_path.begins_with(vault_path):
		return ""
	return note.resource_path.substr(vault_path.length()).get_base_dir()


## The note list order: pinned notes first, newest pin on top; then the rest
## by modified, newest first. A same-second pin tie falls back to modified.
## Strict (never true both ways), as sort_custom needs. Stars do not reorder.
static func _sort_by_modified(a: ContentLayer, b: ContentLayer) -> bool:
	var a_pinned: bool = a.pinned_at != ""
	if a_pinned != (b.pinned_at != ""):
		return a_pinned
	if a.pinned_at != b.pinned_at:
		return a.pinned_at > b.pinned_at
	return a.modified > b.modified


## Hand-written notes sometimes lack the `script = ...` line, so Godot
## loads them as a bare Resource and every field is dropped. Insert the
## ContentLayer script reference into the file so it loads properly.
## Only a real note is rewritten (_is_scriptless_note); any other .tres, such
## as a Godot project's material or theme, is left as it is.
static func _repair_scriptless_note(path: String) -> bool:
	var text: String = FileAccess.get_file_as_string(path)
	if not _is_scriptless_note(text):
		return false
	var header_end: int = TresValidatorScript.header_end(text)
	var section_end: int = text.find("[resource]", header_end) + "[resource]".length()
	var fixed: String = "[gd_resource type=\"Resource\" script_class=\"ContentLayer\" format=3]\n\n"
	fixed += "[ext_resource type=\"Script\" path=\"res://ContentLayer.gd\" id=\"1_content_layer\"]"
	fixed += text.substr(header_end, section_end - header_end)
	fixed += "\nscript = ExtResource(\"1_content_layer\")" + text.substr(section_end)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(fixed)
	f.close()
	print("[VaultStore] Repaired note without script reference: ", path.get_file())
	return true


## Whether `text` starts like a note file: [gd_resource type="Resource"],
## with no script class or script_class="ContentLayer". A Godot project's
## materials, themes and own resources name another type or class. The
## header is read the way Godot and check_text_safe read it
## (TresValidator.header_fields), so a second type hidden in it, such as
## `format=3type="GDScript"`, is not taken for a note.
static func _has_note_header(text: String) -> bool:
	var fields: Dictionary = TresValidatorScript.header_fields(text)
	return fields.get("type", "") == "Resource" and fields.get("script_class", "ContentLayer") == "ContentLayer"


## A note written by hand without its script line: a note header, no script
## or other resource referenced, and a [resource] section with a title or
## raw_text line. Only such a file is repaired.
static func _is_scriptless_note(text: String) -> bool:
	if not _has_note_header(text) or text.contains("[ext_resource") or _script_line_re.search(text) != null:
		return false
	return _has_note_fields(text)


## Whether the [resource] section of `text` has a title or raw_text line.
static func _has_note_fields(text: String) -> bool:
	var section: int = text.find("[resource]")
	return section >= 0 and _note_field_re.search(text, section) != null


## Whether `text`, a file that did not load as a note, was meant to be one:
## its header names ContentLayer, or it has a note's fields. A Godot
## project's plain Resource has neither, and is not listed as unreadable.
static func _meant_as_note(text: String) -> bool:
	return TresValidatorScript.header_fields(text).get("script_class", "") == "ContentLayer" or _has_note_fields(text)


## The first bytes of a file, enough for its header line.
static func _read_head(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_buffer(512).get_string_from_ascii() if f != null else ""


## Whether ResourceLoader may read `path`. A cached, unchanged note is handed
## back without reading the file. Any other file must start like a note
## (_has_note_header; a Godot project's own .tres is skipped quietly, never
## loaded or changed) and carry no code (TresValidator.check_text_safe): one
## that does is never parsed, so its code never runs, and it is listed in
## unsafe_files. A file with no resource header at all is listed in
## unreadable, and so is one a scan found unreadable and that has not changed
## since (it is not read again).
static func _may_load(path: String, changed_on_disk: bool) -> bool:
	if not FileAccess.file_exists(path) or _still_unreadable(path):
		return false
	if not changed_on_disk and ResourceLoader.has_cached(path):
		return true
	var head: String = _read_head(path)
	if not _has_note_header(head):
		if TresValidatorScript.header_fields(head).is_empty():
			_mark_unreadable(path, "it is not a resource file")
		else:
			_log_skip(path, "not an Ontomeme note")
		return false
	var check: Dictionary = TresValidatorScript.check_text_safe(path)
	if check.safe:
		return true
	unsafe_files.append(path)
	_log_skip(path, "it contains code: " + check.reason)
	return false


## Log why `path` was skipped, once per path per session.
static func _log_skip(path: String, why: String) -> void:
	if not _skip_logged.has(path):
		_skip_logged[path] = true
		print("[VaultStore] Skipped %s: %s" % [path, why])


## A file's modification time and size, as "mtime:size". The size catches
## a sync tool that finishes writing within the second it started.
static func _stamp(path: String) -> String:
	return "%d:%d" % [FileAccess.get_modified_time(path), FileAccess.get_size(path)]


## List `path` (absolute) as unreadable, and remember its stamp so the next
## scans do not read it again while it stays the same, and its bytes'
## SHA-256 for quarantine().
static func _mark_unreadable(path: String, why: String) -> void:
	unreadable_reads += 1
	_bad_stamps[path] = _stamp(path)
	_bad_hashes[path] = FileAccess.get_sha256(path)
	_list_unreadable(path)
	_log_skip(path, why)


## True when a scan found `path` unreadable and it has not changed since: it
## is listed again without being read. A changed file is forgotten, to be
## read afresh.
static func _still_unreadable(path: String) -> bool:
	if not _bad_stamps.has(path):
		return false
	if _bad_stamps[path] != _stamp(path):
		_bad_stamps.erase(path)
		_bad_hashes.erase(path)
		return false
	_list_unreadable(path)
	return true


static func _list_unreadable(path: String) -> void:
	var rel: String = path.trim_prefix(vault_path)
	if not unreadable.has(rel):
		unreadable.append(rel)


## Move the unreadable file `rel` (as listed in unreadable) to
## <vault>/.corrupted/<rel>, where no scan looks, so it leaves the sidebar
## and nothing is lost; an earlier file of that name there is kept ("<name>
## 2.tres"). Only the user does this (the sidebar's "Move to .corrupted"),
## never a scan: a file a sync tool is still writing reads as unreadable for
## a moment. The list can be stale (the disk watcher sees mtimes, to the
## second), so a file whose bytes are no longer those the scan found
## unreadable is not moved: the vault is scanned again and it is read afresh
## (_reread). Returns false when `rel` is not listed, has changed or is gone,
## or the move fails.
static func quarantine(rel: String) -> bool:
	if not unreadable.has(rel):
		return false
	var from: String = vault_path + rel
	if not FileAccess.file_exists(from) or FileAccess.get_sha256(from) != _bad_hashes.get(from, ""):
		_reread(from)
		refresh_note_list()
		return false
	var dest: String = _free_path(vault_path.path_join(CORRUPTED_DIR).path_join(rel))
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	if DirAccess.rename_absolute(from, dest) != OK:
		return false
	print("[VaultStore] Moved unreadable %s to %s" % [rel, dest.trim_prefix(vault_path)])
	unreadable.erase(rel)
	_bad_stamps.erase(from)
	_bad_hashes.erase(from)
	return true


## Make the next scan read the unreadable file `path` (absolute) afresh,
## although its stamp may not have changed: its stamp becomes "", which
## matches no file (_still_unreadable).
static func _reread(path: String) -> void:
	_bad_stamps[path] = ""
	_bad_hashes.erase(path)
	unreadable.erase(path.trim_prefix(vault_path))


## Skip `path`, which loaded as a resource other than a note and could not
## be repaired: listed as unreadable if it was meant as a note
## (_meant_as_note), passed over quietly if it is a Godot project's own.
static func _skip_other_resource(path: String) -> void:
	if _meant_as_note(FileAccess.get_file_as_string(path)):
		_mark_unreadable(path, "it does not load as a note")
	else:
		_log_skip(path, "not an Ontomeme note")


## `path`, or "<name> 2.<ext>", "<name> 3.<ext>"… if a file is there.
static func _free_path(path: String) -> String:
	var free: String = path
	var i: int = 2
	while FileAccess.file_exists(free) or DirAccess.dir_exists_absolute(free):
		free = "%s %d.%s" % [path.get_basename(), i, path.get_extension()]
		i += 1
	return free


## "Skipped <file>: it contains code" for the files the last scan refused,
## or "" when there were none. The app shows it in its status bar.
static func unsafe_warning() -> String:
	if unsafe_files.is_empty():
		return ""
	var names: PackedStringArray = []
	for p in unsafe_files:
		names.append(p.trim_prefix(vault_path))
	if names.size() == 1:
		return "Skipped %s: it contains code" % names[0]
	var shown: String = ", ".join(names.slice(0, 3))
	if names.size() > 3:
		shown += " and %d more" % (names.size() - 3)
	return "Skipped %d files that contain code: %s" % [names.size(), shown]


## Load a single .tres file into a ContentLayer resource, or null. A file
## that is not a note, or that carries code, is never loaded (see _may_load);
## one that loads as something else is left untouched unless it is a
## scriptless note (_repair_scriptless_note). A note that does not load is
## listed in unreadable (_mark_unreadable).
## Validates the file with TresValidator; auto-fixes if possible.
## `changed_on_disk` reloads the cached object in place and makes it match
## the file exactly (see _match_file); only changed files pay for that.
## A changed file that does not load as a note (a git merge left conflict
## markers in it, a sync tool is half way through writing it) is not read at
## all: the app's copy is returned as it was and its hash stays the old
## one, so the next save keeps that file and writes a conflict copy instead
## of overwriting it. With no copy held, it is read as a new file would be
## and listed in unreadable.
static func _load_note_file(path: String, changed_on_disk: bool = false) -> ContentLayer:
	if not _may_load(path, changed_on_disk):
		return null
	var fresh: ContentLayer = null
	if changed_on_disk:
		# Parse the new bytes on their own first: a REPLACE load of a file
		# that does not parse still sets every field before the bad line on
		# the cached note and reports nothing.
		fresh = _load_uncached(path)
		if fresh == null:
			var held: ContentLayer = ResourceLoader.get_cached_ref(path) as ContentLayer
			if held != null:
				print("[VaultStore] Changed on disk but does not load as a note; kept the app's copy: ", path)
				return held
			# No copy of the app's (it was unreadable before too): load it
			# below as a new file, which lists it as unreadable.
	var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE if changed_on_disk else ResourceLoader.CACHE_MODE_REUSE)
	if loaded != null and not (loaded is ContentLayer):
		if not _repair_scriptless_note(path):
			_skip_other_resource(path)
			return null
		loaded = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	var resource: ContentLayer = loaded as ContentLayer
	if resource == null:
		_mark_unreadable(path, "it does not load as a note")
		return null
	if fresh != null:
		_match_file(resource, fresh)
	if changed_on_disk or not _hashes.has(path):
		_remember_hash(path)
	# Validate and auto-fix if needed
	var result: Dictionary = TresValidatorScript.validate(path)
	if result.valid:
		return resource
	# Auto-fix was attempted; return the (possibly fixed) resource
	print("[VaultStore] Validation errors for ", path, ": ", result.errors)
	return resource


## The note in `path` as a new object, outside the resource cache (null if
## the file does not load as a note). Repairs a missing script line first.
static func _load_uncached(path: String) -> ContentLayer:
	var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if loaded != null and not (loaded is ContentLayer) and _repair_scriptless_note(path):
		loaded = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	return loaded as ContentLayer


## Make the cached `note` match its file exactly after an outside change.
## Godot leaves default-valued properties out of a .tres, and an in-place
## CACHE_MODE_REPLACE reload only sets the properties the file names, so a
## field an outside edit removed (an unstar, an unpin, the last tag, an
## emptied body) kept its old value and the next save wrote it back. `fresh`
## (a CACHE_MODE_IGNORE load of the same file) has the defaults; copy its
## stored script fields over.
static func _match_file(note: ContentLayer, fresh: ContentLayer) -> void:
	var stored: int = PROPERTY_USAGE_SCRIPT_VARIABLE | PROPERTY_USAGE_STORAGE
	for prop in fresh.get_property_list():
		if prop.usage & stored == stored:
			var value: Variant = fresh.get(prop.name)
			if value is Array or value is Dictionary:
				value = value.duplicate(true)   # typed Array[String] stays typed
			note.set(prop.name, value)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Create a new note with a title. Saves it and returns the created ContentLayer,
## or null when it can't be written (read-only folder, full disk…; the reason
## is in last_save_error), so nobody opens a note that isn't on disk.
## A `folder` in a root asset folder (asset_refusal) puts it at the top level.
## A title a note in the trash had is free, but its Journey entries move off it
## (JourneyStore.title_taken), as on rename_note.
static func create_note(title: String = "untitled", folder: String = "") -> ContentLayer:
	if asset_refusal(folder) != "":
		folder = ""   # images/, models/: listed nowhere there, so the top level
	var filename: String = _unique_filename(title, folder)
	var note: ContentLayer = ContentLayer.new()
	note.title = title
	note.raw_text = ""
	note.tags = []
	note.structure = {}
	var created := Time.get_datetime_string_from_system()
	note.created = created
	note.modified = created
	_forget(vault_path + filename)   # a file once there (deleted outside) was another note's
	note.take_over_path(vault_path + filename)
	if save_note(note) != OK:
		return null
	note_list.append(note)
	JourneyStore.title_taken(title)   # a trashed note's objectives never take its scores
	refresh_note_list()
	return note


## Save a note resource to its .tres file.
## A note keeps the file it was loaded from / first saved to (resource_path);
## only brand-new notes get a fresh unique filename. (Previously every save
## generated a new unique name, so each save wrote another duplicate file.)
## `stamp` = false keeps note.modified as set (seeders use it to order notes).
## Returns OK, or the error with last_save_error saying why; nothing on disk
## changes then. OK also covers an outside edit kept as last_conflict_copy.
## A note already in note_list (every edit) only moves to its new place in
## it (_resort): a rescan reloads and validates every file, a visible hitch
## in a big vault on each autosave. A new note, or one whose folder had to
## be made again, rescans so note_list and folders list it.
static func save_note(note: ContentLayer, stamp: bool = true) -> Error:
	last_save_error = ""
	last_conflict_copy = null
	if note == null:
		return _save_failed(ERR_INVALID_PARAMETER, "no note")
	var path: String = note.resource_path
	var fresh: bool = path.is_empty() or not path.begins_with(vault_path)
	if fresh:
		path = vault_path + _unique_filename(note.title)
	# The file changed since the app last read or wrote it (a sync tool,
	# another editor, Claude): keep that version, save ours as a copy. A file
	# that is gone was renamed or deleted outside (the MCP server's
	# update_note renames a note's file with its title): writing it again
	# would bring the note back under its old title beside the renamed one,
	# so ours is a copy then too. Not after the app's own failed save of it
	# (_unsaved_paths): a rename on Windows deletes the file before it moves
	# the new version in, so that failure may be what took the file, and
	# writing the words back is the retry (atomic_save).
	var gone: bool = not FileAccess.file_exists(path)
	if not fresh and _hashes.has(path) and ((gone and not _unsaved_paths.has(path)) or (not gone and FileAccess.get_sha256(path) != _hashes[path])):
		return _note_unsaved(path, _save_conflict_copy(note, path))
	if stamp:
		note.modified = Time.get_datetime_string_from_system()
	var listed: bool = path == note.resource_path and note_list.has(note) and DirAccess.dir_exists_absolute(path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())   # a note created in a new folder
	var err := atomic_save(note, path)
	if err != OK:
		return _note_unsaved(path, _save_failed(err, path))
	_unsaved_paths.erase(path)
	_remember_stat(path)
	_remember_hash(path)
	# Bind the note to its file so the next save overwrites it and
	# ResourceLoader's cache hands back this same object on refresh.
	note.take_over_path(path)
	if listed:
		_resort(note)
	else:
		refresh_note_list()
	return OK


## Move `note` to its place in note_list after its sort key changed (a save
## stamped `modified`). The other notes are still in order, so one pass finds
## the place, by the same order refresh_note_list sorts with.
static func _resort(note: ContentLayer) -> void:
	note_list.erase(note)
	var i: int = 0
	while i < note_list.size() and not _sort_by_modified(note, note_list[i]):
		i += 1
	note_list.insert(i, note)


## Track whether the note at `path` holds words its file lacks
## (_unsaved_paths) after a save that returned `err`; returns `err`.
static func _note_unsaved(path: String, err: Error) -> Error:
	if err == OK:
		_unsaved_paths.erase(path)
	else:
		_unsaved_paths[path] = true
	return err


## Record why a save failed (shown to the user by note.gd) and return `err`.
static func _save_failed(err: Error, path: String) -> Error:
	last_save_error = "%s (%s)" % [error_string(err), path]
	push_warning("[VaultStore] Save failed: " + last_save_error)
	return err


## Write `note` (the app's version) as a new "<title> (conflict copy)" note
## in the same folder, and reload the original from disk so it shows the
## outside edit. Nothing on disk is overwritten. When the file is gone
## (renamed or deleted outside), nothing is reloaded and nothing written at
## its path; the copy goes to the top level if its folder is gone too.
## If the copy can't be written, returns the error and leaves `note` (the
## user's text) as it is in memory.
static func _save_conflict_copy(note: ContentLayer, path: String) -> Error:
	var copy: ContentLayer = note.duplicate()
	var title: String = note.title + " (conflict copy)"
	var n: int = 2
	while get_note_index(title) >= 0:
		title = "%s (conflict copy %d)" % [note.title, n]
		n += 1
	copy.title = title
	copy.modified = Time.get_datetime_string_from_system()
	copy.conflict_of = path.substr(vault_path.length())   # its original, should the titles drift apart
	copy.starred_at = ""   # never a second starred or pinned row
	copy.pinned_at = ""
	var folder: String = folder_of(note)
	if not DirAccess.dir_exists_absolute(vault_path + folder):
		folder = ""
	var copy_path: String = vault_path + _unique_filename(title, folder)
	var err := atomic_save(copy, copy_path)
	if err != OK:
		return _save_failed(err, copy_path)
	copy.take_over_path(copy_path)
	_remember_stat(copy_path)
	_remember_hash(copy_path)
	var gone: bool = not FileAccess.file_exists(path)
	if not gone:
		_remember_stat(path)
		_load_note_file(path, true)   # updates `note` in place to the disk version, if it loads
	last_conflict_copy = copy
	if gone:
		push_warning("%s was renamed or deleted on disk while open; saved the app's version as \"%s\"" % [path.get_file(), title])
	else:
		push_warning("%s changed on disk while open; kept it and saved the app's version as \"%s\"" % [path.get_file(), title])
	refresh_note_list()
	return OK


static var _conflict_title: RegEx = null


## The title a conflict copy's title names: "Alpha" for "Alpha (conflict
## copy)" or "Alpha (conflict copy 3)"; "" for any other title.
static func conflict_copy_base(title: String) -> String:
	if _conflict_title == null:
		_conflict_title = RegEx.create_from_string("^(.+) \\(conflict copy(?: \\d+)?\\)$")
	var m: RegExMatch = _conflict_title.search(title)
	return m.get_string(1) if m != null else ""


## The note `copy` was saved as a conflict copy of, or null when `copy` is
## none (its title doesn't say "(conflict copy[ n])", so a copy the user
## renamed is a note of its own) or its original is gone. The note at
## copy.conflict_of wins, even renamed since; a copy from before that field,
## or one whose original was moved, finds it by title, in its own folder first.
static func conflict_original(copy: ContentLayer) -> ContentLayer:
	if copy == null:
		return null
	var base: String = conflict_copy_base(copy.title)
	if base == "":
		return null
	if copy.conflict_of != "":
		for n in note_list:
			if n != copy and n.resource_path == vault_path + copy.conflict_of:
				return n
	var elsewhere: ContentLayer = null
	for n in note_list:
		if n != copy and n.title == base:
			if folder_of(n) == folder_of(copy):
				return n
			if elsewhere == null:
				elsewhere = n
	return elsewhere


## Save `note` with `text` as its body, or leave it as it was: on an error
## the note keeps its old text, in memory and on disk, last_save_error says
## why, and it is marked unsaved only if it was before. For writes nobody
## typed (a rename's link rewrites, RenameCascade): nothing would retry them,
## so they must not sit in memory alone.
static func save_text_or_keep(note: ContentLayer, text: String, stamp: bool = true) -> Error:
	var before: String = note.raw_text
	var was_unsaved: bool = _unsaved_paths.has(note.resource_path)
	note.raw_text = text
	var err: Error = save_note(note, stamp)
	if err != OK:
		note.raw_text = before
		if not was_unsaved:
			_unsaved_paths.erase(note.resource_path)   # its file holds what it holds again
	return err


## Settle a conflict in favour of the copy's words: `original` takes `copy`'s
## text and tags and is saved through save_note, so an outside edit to it since
## is still kept (its file stays; the words become a new conflict copy against
## it, last_conflict_copy). On an error `original` is as it was, in memory
## and on disk, and last_save_error says why. Trashing `copy` is the caller's.
static func take_conflict_copy(original: ContentLayer, copy: ContentLayer) -> Error:
	var text: String = original.raw_text
	var tags: Array[String] = original.tags.duplicate()
	var was_unsaved: bool = _unsaved_paths.has(original.resource_path)
	original.raw_text = copy.raw_text
	original.tags = copy.tags.duplicate()
	var err: Error = save_note(original)
	if err != OK:
		original.raw_text = text
		original.tags = tags
		if not was_unsaved:
			_unsaved_paths.erase(original.resource_path)   # its file holds what it holds again
	return err


## Load a note by its index in the (sorted) note list.
static func load_note(index: int) -> ContentLayer:
	if index < 0 or index >= note_list.size():
		return null
	return note_list[index]


## Delete the note at `index` in note_list: its file goes to the vault's
## trash (trash_note) and can be put back (restore_from_trash); no file is
## ever removed. A note whose file is already gone just leaves the list.
## Returns false when nothing was deleted.
static func delete_note(index: int) -> bool:
	if index < 0 or index >= note_list.size():
		return false
	var note: ContentLayer = note_list[index]
	if FileAccess.file_exists(note.resource_path):
		return trash_note(note) != ""
	_forget(note.resource_path)
	note_list.remove_at(index)
	refresh_note_list()
	return true


# ---------------------------------------------------------------------------
# Trash: <vault>/.trash, laid out like the vault
# ---------------------------------------------------------------------------

## Move `note`'s file to <vault>/.trash/<its path in the vault>. A file
## already trashed there is kept: the newer one becomes "<stem> (deleted
## <stamp>[ n]).tres" (_trash_dest). The note leaves note_list and what the
## app remembers about the file goes (_forget); the object follows its file
## (take_over_path), so a later file at the old path never loads as it.
## Its quiz results are copied for its restore (ProgressStore.note_trashed),
## and its Journey entries noted (JourneyStore.note_trashed): its title is
## free while it is in the trash, and another note may take it (the entries
## then move off it: JourneyStore.title_taken).
## Returns the trash path inside the vault (".trash/Physics/note_waves.tres"),
## or "" when the note has no file in the vault or the move failed.
static func trash_note(note: ContentLayer) -> String:
	if note == null or not note.resource_path.begins_with(vault_path) or not FileAccess.file_exists(note.resource_path):
		return ""
	var path: String = note.resource_path
	var dest_rel: String = _trash_dest(path.substr(vault_path.length()), false)
	DirAccess.make_dir_recursive_absolute((vault_path + dest_rel).get_base_dir())
	if DirAccess.rename_absolute(path, vault_path + dest_rel) != OK:
		return ""
	ProgressStore.note_trashed(vault_path + dest_rel, note.title)
	JourneyStore.note_trashed(vault_path + dest_rel, note.title)
	_forget(path)
	note.take_over_path(vault_path + dest_rel)
	note_list.erase(note)
	refresh_note_list()
	return dest_rel


## Undo trash_note: move the file at `trash_rel` (as trash_note returned it)
## back to `original_rel`, or beside it ("<stem>_1.tres", …) when another
## note took that path since. Returns the restored note, loaded fresh from
## the file and in note_list, or null when the file is no longer in the
## trash or can't be moved. The object that followed the file into the
## trash comes back with it while anything still holds it (the app's undo
## history does), so what refers to that note finds it again.
## A note whose title another note took meanwhile (renamed to it while this
## one was in the trash) comes back as "<title> (2)", "(3)"… (free_title),
## saved so: [[links]], progress and the Journey find notes by title. That
## save can fail like any: last_save_error says why ("" otherwise) and the
## note stays unsaved for the caller to retry. Its quiz results and Journey
## entries come back under the title it has (ProgressStore.note_restored,
## JourneyStore.note_restored).
static func restore_from_trash(trash_rel: String, original_rel: String) -> ContentLayer:
	last_save_error = ""
	if not trash_rel.begins_with(TRASH_DIR + "/") or not FileAccess.file_exists(vault_path + trash_rel):
		return null
	if not _note_rel_ok(original_rel):
		return null
	var dest: String = vault_path + _free_rel(original_rel)
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	var trashed: Resource = ResourceLoader.get_cached_ref(vault_path + trash_rel) if ResourceLoader.has_cached(vault_path + trash_rel) else null
	if DirAccess.rename_absolute(vault_path + trash_rel, dest) != OK:
		return null
	_forget(dest)
	if trashed is ContentLayer:
		trashed.take_over_path(dest)
	_load_note_file(dest, true)   # the object at this path (that one, or a stale one) takes the file's text
	refresh_note_list()
	for note in note_list:
		if note.resource_path == dest:
			var title: String = free_title(note.title, note)
			if title != note.title:
				note.title = title
				save_note(note, false)
			ProgressStore.note_restored(vault_path + trash_rel, note.title)
			JourneyStore.note_restored(vault_path + trash_rel, note.title)
			return note
	return null


## The note trash_note moved to `trash_rel`, whose file is no longer in the
## trash (the user emptied it), written anew from `fields`, its script fields
## as the app still holds them (title, raw_text, tags…: note.gd keeps them for
## a note deleted with words its save couldn't write). It goes where
## restore_from_trash would put it: `original_rel`, or beside it when that is
## taken, under a title no other note has (free_title), with its quiz results
## and Journey entries (ProgressStore / JourneyStore.note_restored). The object that went into the trash is
## reused while anything still holds it (the app's undo history), so what
## refers to that note finds it again. Returns the note, saved and in
## note_list, or null when `original_rel` is not a note path in the vault or
## the file can't be written (last_save_error says why; nothing is left
## behind, and the object stays where it was for another try).
static func recreate_note(trash_rel: String, original_rel: String, fields: Dictionary) -> ContentLayer:
	if not trash_rel.begins_with(TRASH_DIR + "/") or not _note_rel_ok(original_rel):
		_save_failed(ERR_INVALID_PARAMETER, original_rel)
		return null
	var trash_path: String = vault_path + trash_rel
	var trashed: Resource = ResourceLoader.get_cached_ref(trash_path) if ResourceLoader.has_cached(trash_path) else null
	var note: ContentLayer = trashed if trashed is ContentLayer else ContentLayer.new()
	for field in fields:
		note.set(field, fields[field])
	note.title = free_title(note.title, note)
	var dest: String = vault_path + _free_rel(original_rel)
	_forget(dest)   # a file once there (deleted outside) was another note's
	note.take_over_path(dest)
	if save_note(note) != OK:
		_unsaved_paths.erase(dest)   # no file there holds older words
		note.take_over_path(trash_path)
		return null
	for n in note_list:
		if n.resource_path == dest:
			ProgressStore.note_restored(trash_path, n.title)
			JourneyStore.note_restored(trash_path, n.title)
			return n
	return null


## True when `rel` names a file inside the vault outside its hidden folders
## (not "", not absolute, no "..", not starting with a dot).
static func _note_rel_ok(rel: String) -> bool:
	return rel != "" and not rel.begins_with(".") and not rel.is_absolute_path() and not (".." in rel.split("/"))


## Where the file or folder at `rel` goes in the trash: .trash/<rel>; when
## that is taken, "<.trash/rel, minus .tres> (deleted <stamp>).tres", then
## "… <stamp> 2).tres" and so on: exactly how mcp/vault_tools.gd:delete_note
## names it. A folder gets the same suffix without the extension.
static func _trash_dest(rel: String, is_folder: bool) -> String:
	var dest_rel: String = TRASH_DIR.path_join(rel)
	if not _taken(dest_rel):
		return dest_rel
	var stamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	var base: String = (dest_rel if is_folder else dest_rel.get_basename()) + " (deleted " + stamp
	var ext: String = "" if is_folder else ".tres"
	dest_rel = base + ")" + ext
	var i: int = 2
	while _taken(dest_rel):
		dest_rel = "%s %d)%s" % [base, i, ext]
		i += 1
	return dest_rel


## A path in the trash, free now, for the note file at `rel`: where
## trash_note would put it. note.gd keeps a deleted folder's unsaved note
## there (its object takes the path), for recreate_note to write it again.
static func trash_slot(rel: String) -> String:
	return _trash_dest(rel, false)


## True when a file or folder exists at `rel` in the vault.
static func _taken(rel: String) -> bool:
	return FileAccess.file_exists(vault_path + rel) or DirAccess.dir_exists_absolute(vault_path + rel)


## `rel`, or when a file is already there "<rel minus extension>_<n>.<ext>"
## with the first free n (the numbering _unique_filename uses).
static func _free_rel(rel: String) -> String:
	if not _taken(rel):
		return rel
	var i: int = 1
	while _taken("%s_%d.%s" % [rel.get_basename(), i, rel.get_extension()]):
		i += 1
	return "%s_%d.%s" % [rel.get_basename(), i, rel.get_extension()]


## Get the count of notes in the vault.
static func get_note_count() -> int:
	return note_list.size()


## Characters a search excerpt keeps on each side of the matched word.
const EXCERPT_RADIUS: int = 40
## One title word outweighs any number of body hits in a search score.
const TITLE_WEIGHT: int = 1000


## Search the notes by text: every word of `query` must appear in the note's
## title or body, ignoring case, anywhere and in any order ("quiz godot"
## finds a note with "quiz" on one line and "godot" on another). One hit per
## matching note, best first (see match_note), equal scores in note_list
## order (newest first); each hit also carries `index`, the note's place in
## note_list. A query with no words matches every note. "#tag" tokens are not
## read here: the sidebar splits them off and filters by tag first (note.gd).
static func search(query: String) -> Array[Dictionary]:
	var words: PackedStringArray = search_words(query)
	var hits: Array[Dictionary] = []
	for i in range(note_list.size()):
		var hit: Dictionary = match_note(note_list[i], words)
		if not hit.is_empty():
			hit["index"] = i
			hits.append(hit)
	hits.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.score > b.score or (a.score == b.score and a.index < b.index))
	return hits


## A search query's words, lowercase: "Quiz  Godot" -> ["quiz", "godot"].
static func search_words(query: String) -> PackedStringArray:
	return query.to_lower().replace("\t", " ").replace("\n", " ").split(" ", false)


## One note against `words` (lowercase, as search_words gives them): {} unless
## each word is in its title or its body, else
##   {note, line, col, word, excerpt, score}
## line/col: the first body line holding a word (0-based, as TextEdit counts)
## and the leftmost word's column on it; word: that word; excerpt: that line
## cut around it (excerpt()). A match on the title alone has line and col -1,
## word and excerpt "". score: TITLE_WEIGHT per word in the title, plus the
## number of times the words occur in the body. Pure (no vault state).
static func match_note(note: ContentLayer, words: PackedStringArray) -> Dictionary:
	var title: String = note.title.to_lower()
	var body: String = note.raw_text.to_lower()
	var title_words: int = 0
	var body_hits: int = 0
	for w in words:
		var n: int = body.count(w)
		if title.contains(w):
			title_words += 1
		elif n == 0:
			return {}
		body_hits += n
	var hit: Dictionary = {"note": note, "line": -1, "col": -1, "word": "", "excerpt": "",
		"score": title_words * TITLE_WEIGHT + mini(body_hits, TITLE_WEIGHT - 1)}
	hit.merge(_first_match(note.raw_text, words), true)
	return hit


## The first line of `text` holding one of `words`, at the leftmost of them:
## {line, col, word, excerpt}; {} when no line holds any.
static func _first_match(text: String, words: PackedStringArray) -> Dictionary:
	if words.is_empty():
		return {}
	var lines: PackedStringArray = text.split("\n")
	for i in range(lines.size()):
		var lower: String = lines[i].to_lower()
		var col: int = -1
		var word: String = ""
		for w in words:
			var at: int = lower.find(w)
			if at >= 0 and (col < 0 or at < col):
				col = at
				word = w
		if col >= 0:
			return {"line": i, "col": col, "word": word, "excerpt": excerpt(lines[i], col, word.length())}
	return {}


## `line` cut to at most `before` characters before the `length` characters
## at `col` and `after` characters after them, on whole words, with "…" where
## it was cut; tabs become spaces and the ends are trimmed.
static func excerpt(line: String, col: int, length: int,
		before: int = EXCERPT_RADIUS, after: int = EXCERPT_RADIUS) -> String:
	var from: int = maxi(0, col - before)
	var to: int = mini(line.length(), col + length + after)
	if from > 0 and line[from - 1] != " ":   # the cut falls inside a word: drop it
		var space: int = line.find(" ", from)
		if space >= 0 and space < col:
			from = space + 1
	if to < line.length() and line[to] != " ":
		var space: int = line.rfind(" ", to)
		if space >= col + length:
			to = space
	var cut: String = line.substr(from, to - from).replace("\t", " ").strip_edges()
	return ("…" if from > 0 else "") + cut + ("…" if to < line.length() else "")


## List all notes as an array of ContentLayer resources.
static func list_notes() -> Array[ContentLayer]:
	return note_list


## Get the zero-based index of a note by its title; -1 if not found.
static func get_note_index(title: String) -> int:
	for i in range(note_list.size()):
		if note_list[i].title == title:
			return i
	return -1


## The note titled `title` filed in `folder` ("" = the top level), or null.
## The starter courses match their notes with it, so seeding only ever
## updates a course's own notes, never a note of the user's that shares a
## lesson's title somewhere else in the vault.
static func find_note(title: String, folder: String) -> ContentLayer:
	folder = folder.trim_suffix("/")
	for note in note_list:
		if note.title == title and folder_of(note) == folder:
			return note
	return null


## Rename the note titled `old_title` (see rename_note). False when no note
## has that title or the new one is refused.
static func update_title(old_title: String, new_title: String) -> bool:
	var i: int = get_note_index(old_title)
	return i >= 0 and rename_note(note_list[i], new_title) == ""


## Retitle `note` and rename its file to match: "Light reactions" becomes
## note_light_reactions.tres in the same folder (_1, _2… when another file has
## that name). Returns "" or, when the title is refused, why (for the status
## line). A title another note already has is refused, ignoring case and
## outer spaces, because [[links]], progress and the Journey find notes by
## title; "untitled" may repeat. A blank title means "untitled".
## A note in the trash keeps its title free, but not its Learning Journey
## objectives: JourneyStore.title_taken moves its entries off the title first.
## The note is saved in place first, so an outside edit to its file is caught
## there: save_note() keeps it, writes ours as last_conflict_copy, and the
## file is not renamed.
static func rename_note(note: ContentLayer, new_title: String) -> String:
	if note == null:
		return "No note to rename"
	new_title = new_title.strip_edges()
	if new_title == "":
		new_title = "untitled"
	if new_title == note.title:
		return ""
	var holder: ContentLayer = _title_holder(new_title, note)
	if holder != null:
		return "A note named “%s” already exists" % holder.title
	note.title = new_title
	JourneyStore.title_taken(new_title)   # a trashed note's title is free, its objectives are not
	# A failed save leaves the note in _unsaved_paths for note.gd to retry; its
	# file keeps its name until a rename that saves.
	if save_note(note) == OK and last_conflict_copy == null:
		_move_to_title_file(note)
	return ""


## Another note (not `self_note`) titled `title`, ignoring case and outer
## spaces; null when there is none or the title is "untitled".
static func _title_holder(title: String, self_note: ContentLayer) -> ContentLayer:
	return title_holder_in(note_list, title, self_note)


## `title`, or when another note has it (_title_holder) "<title> (2)",
## "(3)"… (import_title's numbering): what a note back from the trash is
## called, so two notes never share a title.
static func free_title(title: String, self_note: ContentLayer) -> String:
	var free: String = title
	var i: int = 2
	while title.strip_edges() != "" and _title_holder(free, self_note) != null:
		free = "%s (%d)" % [title.strip_edges(), i]
		i += 1
	return free


## True for "untitled" (any case, outer spaces): what a note without a title
## is called. Any number of notes may have it, so it names none of them: a
## rename may take it, and RenameCascade moves no links, progress or Journey
## keys to or from it.
static func shared_title(title: String) -> bool:
	return title.strip_edges().to_lower() == "untitled"


## _title_holder's rule over any list of notes, so the MCP tools refuse the
## same duplicate titles in a vault they scanned themselves.
static func title_holder_in(notes: Array, title: String, self_note: ContentLayer) -> ContentLayer:
	var key: String = title.strip_edges().to_lower()
	if shared_title(title):
		return null
	for n in notes:
		if n == self_note or (n.resource_path != "" and n.resource_path == self_note.resource_path):
			continue
		if n.title.strip_edges().to_lower() == key:
			return n
	return null


## rename_note's second half, for a rename whose save failed: once a later
## save wrote the new title into the old file, give the file its name.
static func move_to_title_file(note: ContentLayer) -> void:
	_move_to_title_file(note)


## Give `note`'s file the name its title asks for (_unique_filename) in the
## same folder. A file already named for the title keeps its name. The file's
## remembered mtime and hash move with it, so an outside edit to the renamed
## file is still caught by the next save.
static func _move_to_title_file(note: ContentLayer) -> void:
	var old_path: String = note.resource_path
	if not old_path.begins_with(vault_path) or not FileAccess.file_exists(old_path):
		return
	var new_path: String = vault_path + _unique_filename(note.title, folder_of(note), old_path)
	if new_path == old_path:
		return
	if DirAccess.rename_absolute(old_path, new_path) != OK:
		push_warning("Couldn't rename %s to %s; the note keeps its old file name" % [old_path.get_file(), new_path.get_file()])
		return
	_rekey(old_path, new_path)
	note.take_over_path(new_path)
	refresh_note_list()


## Star (`on`) or unstar `note` and save it, without touching `modified`, so
## the note keeps its place in the date sort. False if `note` is not a note
## file in this vault. If its file changed on disk, the outside version is
## loaded first and the star applied to it (no conflict copy), so callers
## flush their own unsaved edits before toggling. False, with nothing changed
## in memory or on disk, if that outside version does not load (a git merge
## left conflict markers in it): starring must not overwrite it. Likewise
## when the note holds words its last save couldn't write (_unsaved_paths):
## loading the outside version would drop them.
static func set_starred(note: ContentLayer, on: bool) -> bool:
	return _set_flag(note, &"starred_at", on)


## Pin (`on`) or unpin `note`; same rules as set_starred. Pinned notes lead
## note_list, newest pin first.
static func set_pinned(note: ContentLayer, on: bool) -> bool:
	return _set_flag(note, &"pinned_at", on)


## Set a timestamp flag (`field` = starred_at / pinned_at) on or off. A flag
## that is already on keeps its timestamp, so the order it sorts by holds.
## A save that fails (read-only file, full disk) puts the flag back and
## returns false, with last_save_error saying why: no star shows that the
## file lacks.
static func _set_flag(note: ContentLayer, field: StringName, on: bool) -> bool:
	last_save_error = ""
	if note == null or note.resource_path.is_empty() or not note.resource_path.begins_with(vault_path):
		return false
	var path: String = note.resource_path
	last_conflict_copy = null
	# Changed outside the app (sync, git, Claude): reload, then apply.
	var reloaded: bool = FileAccess.file_exists(path) and _hashes.has(path) and FileAccess.get_sha256(path) != _hashes[path]
	if reloaded and _unsaved_paths.has(path):
		# Its last save failed, so the note holds words the file lacks, and
		# a reload would drop them. They wait for a save that can write
		# them (as a conflict copy beside the outside version).
		last_save_error = "its file changed on disk while your last edits to it are still unsaved"
		return false
	if reloaded:
		_remember_stat(path)
		# Updates `note` in place to the disk version. If the file did not
		# load, or loaded into another object, `note` is not the disk version:
		# saving it would overwrite the outside edit, so change nothing.
		if _load_note_file(path, true) != note or _hashes.get(path, "") != FileAccess.get_sha256(path):
			return false
	var current: String = note.get(field)
	if (current != "") == on:
		if reloaded:
			refresh_note_list()   # the disk version may sort differently
		return true
	var was_unsaved: bool = _unsaved_paths.has(path)
	note.set(field, Time.get_datetime_string_from_system() if on else "")
	if save_note(note, false) != OK:
		note.set(field, current)
		if not was_unsaved:
			_unsaved_paths.erase(path)   # the note holds nothing its file lacks
		return false
	return true


# ---------------------------------------------------------------------------
# Folders — real directories on disk
# ---------------------------------------------------------------------------

## A folder name that works on Linux, macOS and Windows alike: each of
## / \ : * ? " < > | and each control character becomes "-"; dots and spaces
## at its start (a hidden folder) and end (Windows drops them) go; a name
## Windows keeps for a device gets "_" ("CON" → "CON_", "aux.txt" →
## "aux_.txt"); and it is cut to MAX_NAME_CHARS characters and
## MAX_NAME_BYTES bytes. "" when nothing is left.
static func _clean_name(name: String) -> String:
	var n: String = name.strip_edges()
	for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		n = n.replace(bad, "-")
	n = _control_char_re.sub(n, "-", true)
	n = _not_reserved(_edge_dots_re.sub(n, "", true))
	return _edge_dots_re.sub(_cap_name(n), "", true)


## `n` with "_" after its part before the first dot when that part is a name
## Windows keeps for a device.
static func _not_reserved(n: String) -> String:
	var dot: int = n.find(".")
	var base: String = n if dot < 0 else n.left(dot)
	if _reserved_name_re.search(base.strip_edges(false, true)) == null:
		return n
	return base + "_" + n.substr(base.length())


## `n` cut to MAX_NAME_CHARS characters and MAX_NAME_BYTES bytes of UTF-8,
## between two characters.
static func _cap_name(n: String) -> String:
	n = n.left(MAX_NAME_CHARS)
	while n.to_utf8_buffer().size() > MAX_NAME_BYTES:
		n = n.left(-1)
	return n


## Create a folder (inside `parent`); returns its relative path, or "" on
## failure: also for a folder in a root asset folder, with last_refusal set.
static func create_folder(name: String, parent: String = "") -> String:
	var n: String = _clean_name(name)
	if n == "":
		n = "New folder"
	var base: String = parent.path_join(n) if parent != "" else n
	last_refusal = asset_refusal(base)
	if last_refusal != "":
		return ""
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
## their identity — open notes stay open. Returns the new path or "" (a
## target in a root asset folder sets last_refusal).
static func move_folder(rel: String, new_rel: String) -> String:
	new_rel = new_rel.trim_suffix("/")
	last_refusal = asset_refusal(new_rel)
	if last_refusal != "":
		return ""
	if rel == "" or new_rel == "" or new_rel == rel or (new_rel + "/").begins_with(rel + "/"):
		return ""
	if DirAccess.dir_exists_absolute(vault_path + new_rel) or not DirAccess.dir_exists_absolute(vault_path + rel):
		return ""
	DirAccess.make_dir_recursive_absolute(vault_path + new_rel.get_base_dir())
	if DirAccess.rename_absolute(vault_path + rel, vault_path + new_rel) != OK:
		return ""
	var old_prefix: String = vault_path + rel + "/"
	var new_prefix: String = vault_path + new_rel + "/"
	for f in _files_under(new_prefix):
		_rekey(old_prefix + f, new_prefix + f)
	_forget_under(old_prefix)   # files that vanished from disk before the move
	for note in note_list:
		if note.resource_path.begins_with(old_prefix):
			note.take_over_path(new_prefix + note.resource_path.substr(old_prefix.length()))
	refresh_note_list()
	return new_rel


static func rename_folder(rel: String, new_name: String) -> String:
	last_refusal = ""
	var n: String = _clean_name(new_name)
	if n == "":
		return ""
	var parent: String = rel.get_base_dir()
	return move_folder(rel, parent.path_join(n) if parent != "" else n)


## Move a folder (and everything in it) to the system trash, or when the
## system refuses (no trash there, another volume, a sandbox) to the vault's
## own .trash/<rel>. Nothing is ever removed: a folder that can't be moved
## either way stays, and false is returned.
static func delete_folder(rel: String) -> bool:
	if rel == "" or not DirAccess.dir_exists_absolute(vault_path + rel):
		return false
	var ok: bool = _move_to_system_trash(vault_path + rel) == OK
	if not ok:
		var dest_rel: String = _trash_dest(rel, true)
		DirAccess.make_dir_recursive_absolute((vault_path + dest_rel).get_base_dir())
		ok = DirAccess.rename_absolute(vault_path + rel, vault_path + dest_rel) == OK
	if ok:
		_forget_under(vault_path + rel + "/")
	refresh_note_list()
	return ok


static func _move_to_system_trash(path: String) -> Error:
	if system_trash_hook.is_valid():
		return system_trash_hook.call(path)
	return OS.move_to_trash(path)


## Move a note's file into `folder` ("" = top level). Keeps the same object.
## Refused (false, last_refusal set) for a folder in a root asset folder.
static func move_note(note: ContentLayer, folder: String) -> bool:
	last_refusal = asset_refusal(folder)
	if last_refusal != "":
		return false
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
	_rekey(note.resource_path, dest)
	note.take_over_path(dest)
	refresh_note_list()
	return true


# ---------------------------------------------------------------------------
# Per-file bookkeeping: follows a file that moves, goes with one that is deleted
# ---------------------------------------------------------------------------

## What the app remembers per note file, by absolute path.
static func _per_file() -> Array[Dictionary]:
	return [_mtimes, _sizes, _hashes, _hashed_at, _unsaved_paths]


## A file moved from `old_path` to `new_path` (move_note, move_folder): what
## the app remembers about it moves along. Its hash above all: left behind,
## a note moved away and back would meet its old hash at its old path, and
## the next save would call its own edit an outside one (a conflict copy).
## Its mtime and size move too (it is the same file, so a rescan sees no
## change), and a failed save stays pending at the new path.
static func _rekey(old_path: String, new_path: String) -> void:
	for d: Dictionary in _per_file():
		if d.has(old_path):
			d[new_path] = d[old_path]
			d.erase(old_path)


## The file at `path` left the vault (deleted, trashed): forget its mtime,
## size, hash and any failed save, so nothing stale meets a later file there.
static func _forget(path: String) -> void:
	for d: Dictionary in _per_file():
		d.erase(path)


## _forget every file whose path begins with `prefix` (a folder's path
## ending in "/").
static func _forget_under(prefix: String) -> void:
	for d: Dictionary in _per_file():
		for p in d.keys():
			if str(p).begins_with(prefix):
				d.erase(p)


## Every file under the folder `abs_dir` (hidden ones too), as paths
## relative to it ("note_a.tres", "Sub/note_b.tres"). A folder link is
## entered only where the vault scan enters one (_should_descend: out of the
## vault, once per place), so its files keep the paths the scan knows them
## by, and a link back into the vault (`up -> ..`, `a -> .`) is not walked
## again: `a -> .` plus `b -> .` never finished.
static func _files_under(abs_dir: String, visited: Dictionary = {}) -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return out
	dir.include_hidden = true
	for f in dir.get_files():
		out.append(f)
	var in_vault: bool = abs_dir.begins_with(vault_path)
	var rel: String = abs_dir.substr(vault_path.length()).trim_suffix("/") if in_vault else ""
	for d in dir.get_directories():
		var sub: String = abs_dir.path_join(d)
		if _is_link(sub) and not (in_vault and _should_descend(vault_path, rel, d, visited)):
			continue
		for f in _files_under(sub, visited):
			out.append(d.path_join(f))
	return out


# ---------------------------------------------------------------------------
# Export — a plain copy of the vault folder
# ---------------------------------------------------------------------------

## Names an export leaves out at any depth: the app's trash, files it
## quarantined, and Finder's litter.
const EXPORT_SKIP: Array[String] = [".trash", ".corrupted", ".DS_Store"]
## Scratch folders inside .ontomeme/ that an export leaves out.
const EXPORT_SKIP_DATA: Array[String] = ["tmp"]
## Tests stand in for another platform's links here: an object with
## DirAccess's is_link(path) and read_link(path), called with absolute paths.
## null = the real DirAccess.
static var link_probe: Object = null


## Folder name for an export made today: "<vault>-export-YYYY-MM-DD".
static func export_name() -> String:
	var slug: String = VaultRegistry.display_name(vault_path).to_lower().replace(" ", "-")
	return "%s-export-%s" % [slug, Time.get_date_string_from_system()]


## Copy the open vault into a new folder inside `dest_dir`:
## "<vault>-export-YYYY-MM-DD", or "… 2", "… 3" when that exists, so an
## earlier export is never replaced or deleted. The copy carries .ontomeme/
## (journey, progress, ui) and models/; it leaves out EXPORT_SKIP, .ontomeme/tmp
## and folders that link somewhere else (symlinks, junctions), and names
## those in `links`. A destination inside the vault is refused.
## Returns {ok, files (count copied), dest, error, links (vault-relative
## folders left out because they link elsewhere)}.
static func export_to(dest_dir: String) -> Dictionary:
	var src: String = vault_path
	var links: Array[String] = []
	if src == "" or not DirAccess.dir_exists_absolute(src):
		return {"ok": false, "files": 0, "dest": "", "error": "Vault folder not found", "links": links}
	var dest: String = _unique_dir(VaultRegistry.normalize(dest_dir).trim_suffix("/"), export_name())
	if _overlaps(dest, src):
		return {"ok": false, "files": 0, "dest": dest, "error": "Can't export a vault into itself (%s)" % dest_dir, "links": links}
	var copied: Array[String] = []
	var err: Error = _copy_tree(src.trim_suffix("/"), dest, "", copied, links)
	if err != OK:
		return {"ok": false, "files": copied.size(), "dest": dest, "error": "%s (error %d)" % [error_string(err), err], "links": links}
	return {"ok": true, "files": copied.size(), "dest": dest, "error": "", "links": links}


## `parent`/`name`, or "`name` 2", "`name` 3"… if that already exists.
static func _unique_dir(parent: String, name: String) -> String:
	var path: String = parent.path_join(name)
	var n: int = 2
	while DirAccess.dir_exists_absolute(path) or FileAccess.file_exists(path):
		path = parent.path_join("%s %d" % [name, n])
		n += 1
	return path


## True when one folder is (inside) the other. Compared without case, as
## Windows and macOS do, so the guard errs on the side of refusing.
static func _overlaps(a: String, b: String) -> bool:
	var pa: String = a.simplify_path().trim_suffix("/").to_lower() + "/"
	var pb: String = b.simplify_path().trim_suffix("/").to_lower() + "/"
	return pa.begins_with(pb) or pb.begins_with(pa)


static func _export_skips(rel_dir: String, name: String) -> bool:
	return name in EXPORT_SKIP or (rel_dir == ".ontomeme" and name in EXPORT_SKIP_DATA)


## Copy `src` into `dst` (rel = path under the vault), hidden entries
## included, appending each copied file to `copied` and each folder left
## out because it links elsewhere to `links`.
static func _copy_tree(src: String, dst: String, rel: String, copied: Array[String], links: Array[String]) -> Error:
	var dir := DirAccess.open(src)
	if dir == null:
		return DirAccess.get_open_error()
	dir.include_hidden = true
	var err: Error = DirAccess.make_dir_recursive_absolute(dst)
	if err != OK:
		return err
	for d in dir.get_directories():
		if _export_skips(rel, d):
			continue
		var sub_rel: String = rel.path_join(d) if rel != "" else d
		if _links_elsewhere(dir, src, d):
			links.append(sub_rel)
			continue
		err = _copy_tree(src.path_join(d), dst.path_join(d), sub_rel, copied, links)
		if err != OK:
			return err
	for f in dir.get_files():
		if _export_skips(rel, f):
			continue
		err = DirAccess.copy_absolute(src.path_join(f), dst.path_join(f))
		if err != OK:
			return err
		copied.append(rel.path_join(f) if rel != "" else f)
	return OK


## Whether folder `name` in `dir` (opened at `dir_path`) links somewhere
## else, so the export leaves it out. Windows' is_link is true for every
## reparse point, OneDrive's cloud placeholders included, and the default
## vault sits in Documents, which OneDrive often backs up. read_link there
## opens the folder and asks for its final path: a placeholder resolves to
## itself, a symlink or junction to its target. On Linux and macOS is_link
## means a symlink, and read_link gives its target.
static func _links_elsewhere(dir: DirAccess, dir_path: String, name: String) -> bool:
	var probe: Object = link_probe if link_probe != null else dir
	var path: String = dir_path.path_join(name)
	if not probe.call("is_link", path):
		return false
	var own: Array[String] = [path]
	var parent: String = probe.call("read_link", dir_path)   # the vault reached through a junction
	if parent != "":
		own.append(parent.path_join(name))
	return _resolves_elsewhere(probe.call("read_link", path), own)


## True unless `target` (what read_link gave for a folder) is one of `own`,
## the paths the folder has when it is no link at all. An empty or
## relative target (a Unix symlink) resolves elsewhere.
static func _resolves_elsewhere(target: String, own: Array[String]) -> bool:
	var key: String = _path_key(target)
	if not key.is_absolute_path():
		return true
	for o in own:
		if _path_key(o) == key:
			return false
	return true


## An absolute path in one comparable form: forward slashes, no "\\?\"
## prefix, "UNC/server" as "//server", simplified, no trailing slash, and
## without case when it is a Windows path (drive letter or //server).
static func _path_key(p: String) -> String:
	var s: String = p.replace("\\", "/").trim_prefix("//?/")
	if s.begins_with("UNC/"):
		s = "/" + s.substr(3)
	s = s.simplify_path().trim_suffix("/")
	if s.begins_with("//") or (s.length() > 1 and s[1] == ":"):
		s = s.to_lower()
	return s


# ---------------------------------------------------------------------------
# Import — notes from another vault, a folder or single files
# ---------------------------------------------------------------------------

## Root folders of an imported folder whose 3D models and pictures join the
## vault's folders of the same name, byte for byte: only the files with an
## extension listed for that folder (what the app shows from it). Nothing
## else in them is copied, above all no .tres, which can run code once
## something loads it, and no .import or .remap, which sends a load
## elsewhere. The vault reads notes in every folder but its ASSET_DIRS, so
## one of these that isn't in ASSET_DIRS (images/, until the app shows
## pictures) is also imported as a notes folder, through the same checks.
const IMPORT_ASSETS: Dictionary = {
	"models": ["glb", "gltf", "fbx", "bin", "png", "jpg", "jpeg", "webp", "ktx2"],
	"images": ["png", "jpg", "jpeg", "webp"],
}


## Import the notes in the folder `src` (another vault, an export, a course)
## into the vault folder `into` ("" = the top), or the one note file `src`.
## See import_paths for what it does and returns.
static func import_vault(src: String, into: String = "") -> Dictionary:
	return import_paths(PackedStringArray([src]), into)


## Import `paths` into the vault folder `into` ("" = the top). Each is:
##  - a folder: every .tres note under it keeps its subfolder under `into`
##    (each subfolder is created, empty ones too); its .md files go through
##    NoteImporter (front matter: tags, topic, objectives); dot-folders,
##    Markdown export folders below it (MdExport.MARKER), `_`-prefixed .md
##    drafts and folders that link elsewhere are skipped; the
##    models and pictures in its root models/ and images/ join the vault's
##    models/ and images/ (IMPORT_ASSETS: those file types only, never a
##    .tres; a .tres where the vault doesn't read notes counts as invalid);
##    its .ontomeme/journey.json merges into the Learning Journey
##    (JourneyStore.merge_from), following the notes it renamed.
##  - a .tres note or a .md file, imported into `into`.
## Nothing in the vault is replaced. A title already taken (without case)
## gets "<title> (2)", "(3)"…; a note the vault already has (that title or
## one of its numbered copies, with the same text and tags) is skipped; a
## model or image whose name is taken by other bytes is left out. A .tres
## that isn't a note, or that could run code, is never loaded. A path inside
## the vault, or holding it, is refused.
## Returns {ok, errors, notes (.tres), md, folders (created), renamed, same
## (already here), invalid, models, model_conflicts, images, image_conflicts,
## failed (couldn't be written), links, imported (the new notes, in order),
## renames (title → new title), journey (what merge_from added: {topics,
## objectives, demos, logs})}.
static func import_paths(paths: PackedStringArray, into: String = "") -> Dictionary:
	var r: Dictionary = {"ok": true, "errors": [], "notes": 0, "md": 0, "folders": 0,
		"renamed": 0, "same": 0, "invalid": 0, "models": 0, "model_conflicts": 0, "images": 0,
		"image_conflicts": 0, "failed": 0, "links": [], "imported": [], "renames": {},
		"journey": {"topics": 0, "objectives": 0, "demos": 0, "logs": 0}}
	var md: Array = []   # [path, vault folder]
	var journeys: Array[String] = []
	refresh_note_list()
	for p in paths:
		var path: String = ProjectSettings.globalize_path(p).simplify_path().trim_suffix("/")
		if _overlaps(path, vault_path):
			var inside: bool = (path.to_lower() + "/").begins_with(vault_path.to_lower())
			r.errors.append(("%s is already in this vault" if inside else "%s holds this vault") % path)
		elif DirAccess.dir_exists_absolute(path):
			if VaultRegistry.normalize(path) == kept_in_fallback:
				kept_in_fallback = ""   # ↓ Import no longer needs to open there
			_import_tree(path, "", into, r, md)
			if FileAccess.file_exists(JourneyStore.path_in(path)):
				journeys.append(JourneyStore.path_in(path))
		elif not FileAccess.file_exists(path):
			r.errors.append("%s not found" % path)
		elif path.get_extension().to_lower() == "tres":
			_import_tres(path, into, r)
		elif path.get_extension().to_lower() == "md":
			md.append([path, into])
		else:
			r.invalid += 1
	for j in journeys:   # after the notes: it follows their renames
		_merge_journey(j, r)
	_import_markdown(md, r)
	refresh_note_list()
	r.ok = r.errors.is_empty()
	return r


## One folder of an import: `rel` under the imported folder `src`, into the
## vault folder `into` (see import_paths). Markdown files are collected in
## `md` for one NoteImporter run. `kind` is the root asset folder `rel` is
## in ("models", "images"; "" = none): its models or pictures are copied to
## the vault's folder of that name (_import_asset), and its notes import
## only when the vault reads notes there (it isn't in ASSET_DIRS).
static func _import_tree(src: String, rel: String, into: String, r: Dictionary, md: Array, kind: String = "") -> void:
	var here: String = src.path_join(rel) if rel != "" else src
	var dir := DirAccess.open(here)
	if dir == null:
		r.errors.append("Can't open %s (%s)" % [here, error_string(DirAccess.get_open_error())])
		return
	var notes: bool = kind not in ASSET_DIRS
	var folder: String = _join(into, rel)
	var files: PackedStringArray = dir.get_files()
	files.sort()
	for f in files:
		var ext: String = f.get_extension().to_lower()
		if kind != "" and ext in IMPORT_ASSETS[kind]:
			_import_asset(here.path_join(f), vault_path.path_join(rel).path_join(f), kind, r)
		elif ext == "tres":
			if notes:
				_import_tres(here.path_join(f), folder, r)
			else:   # the vault would never show it, and loading it could run code
				r.invalid += 1
		elif ext == "md" and notes and not f.begins_with("_"):
			md.append([here.path_join(f), folder])
	var dirs: PackedStringArray = dir.get_directories()
	dirs.sort()
	for d in dirs:
		var sub: String = _join(rel, d)
		# A Markdown export folder (an export of a vault carries its
		# exports/) holds .md copies of the notes beside it, which no scan of
		# that vault lists: importing them would add each note again.
		if d.begins_with(".") or FileAccess.file_exists(here.path_join(d).path_join(MdExport.MARKER)):
			continue
		if _links_elsewhere(dir, here, d):
			r.links.append(sub)
			continue
		var sub_kind: String = d if rel == "" and IMPORT_ASSETS.has(d) else kind
		if sub_kind not in ASSET_DIRS and not DirAccess.dir_exists_absolute(vault_path + _join(into, sub)):
			if DirAccess.make_dir_recursive_absolute(vault_path + _join(into, sub)) == OK:
				r.folders += 1
		_import_tree(src, sub, into, r, md, sub_kind)


## "a/b" from "a" and "b"; either may be "".
static func _join(a: String, b: String) -> String:
	return a.path_join(b) if a != "" and b != "" else a + b


## Import the note file at `path` into the vault folder `folder` under a
## free title (import_title), keeping its file name when that is free, and
## everything else in it (dates, tags). Saved through save_note, so the
## next edit isn't taken for an outside change. A title a note in the trash
## had is free, but its Journey entries move off it (JourneyStore.title_taken).
static func _import_tres(path: String, folder: String, r: Dictionary) -> void:
	var note: ContentLayer = _load_foreign_note(path)
	if note == null:
		r.invalid += 1
		return
	var place: Dictionary = import_title(note.title, note.raw_text, note.tags)
	if place.title != note.title:
		r.renames[note.title.strip_edges()] = str(place.title).strip_edges()
	if place.twin != null:
		r.same += 1
		return
	if place.title != note.title:
		r.renamed += 1
		note.title = place.title
	var rel: String = _join(folder, path.get_file())
	if _file_exists(rel):
		rel = _unique_filename(note.title, folder)
	_forget(vault_path + rel)   # a file once there (deleted outside) was another note's
	note.take_over_path(vault_path + rel)
	save_note(note, false)
	if FileAccess.file_exists(vault_path + rel):
		r.notes += 1
		r.imported.append(note)
		# Before any imported journey merges: a trashed note's objectives
		# never take its scores, as for create_note's
		JourneyStore.title_taken(note.title)
	else:
		r.failed += 1


## Merge an imported folder's journey file `src` into the vault's, adding
## what it added to r.journey.
static func _merge_journey(src: String, r: Dictionary) -> void:
	var added: Dictionary = JourneyStore.merge_from(src, r.renames)
	if added.error != "":
		r.errors.append(added.error)
	for k in r.journey:
		r.journey[k] += added[k]


## The .md files of an import, through one NoteImporter run (so an objective
## defined in one file is found by the others), never replacing a note.
static func _import_markdown(md: Array, r: Dictionary) -> void:
	if md.is_empty():
		return
	var importer := NoteImporter.new()
	importer.rename_clashes = true
	for m in md:
		importer.queue(m[0], m[1])
	r.md += importer.import_queued()
	r.renamed += importer.renamed
	r.same += importer.same
	r.imported.append_array(importer.imported_notes())


## Where an imported note titled `title` goes: {title, twin}. twin is the
## note already in the vault that it duplicates (titled `title` or one of
## its "<title> (n)" copies, without case, with the same text and tags), so
## the import can skip it; title is then that note's title. Otherwise twin
## is null and title is `title`, or "<title> (2)", "(3)"… when a note
## already has it (without case).
static func import_title(title: String, raw_text: String, tags: Array) -> Dictionary:
	var want: String = title.strip_edges().to_lower()
	var taken: Dictionary = {}
	for n in note_list:
		var t: String = n.title.strip_edges().to_lower()
		taken[t] = true
		if (t == want or _numbered_copy_of(t, want)) and n.raw_text == raw_text and _same_tags(n.tags, tags):
			return {"title": n.title, "twin": n}
	var free: String = title
	var i: int = 2
	while taken.has(free.strip_edges().to_lower()):
		free = "%s (%d)" % [title.strip_edges(), i]
		i += 1
	return {"title": free, "twin": null}


## Whether `title` is "`base` (n)" (both lower case).
static func _numbered_copy_of(title: String, base: String) -> bool:
	if not (title.begins_with(base + " (") and title.ends_with(")")):
		return false
	return title.substr(base.length() + 2, title.length() - base.length() - 3).is_valid_int()


static func _same_tags(a: Array, b: Array) -> bool:
	var x: PackedStringArray = PackedStringArray(a)
	var y: PackedStringArray = PackedStringArray(b)
	x.sort()
	y.sort()
	return x == y


## The note in the file at `path` (outside the vault), loaded without the
## resource cache, or null when it isn't one or might run code
## (_importable_note). A note without a title is named after its file.
static func _load_foreign_note(path: String) -> ContentLayer:
	if not _importable_note(path):
		return null
	var note: ContentLayer = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as ContentLayer
	if note != null and note.title.strip_edges() == "":
		note.title = path.get_file().get_basename().trim_prefix("note_").replace("_", " ").strip_edges().capitalize()
	return note


## Whether an import may hand the .tres at `path` to ResourceLoader: it is a
## note file ([gd_resource type="Resource"], no script class or ContentLayer)
## whose sections are [gd_resource], at most one [ext_resource] (the Script
## res://ContentLayer.gd) and [resource], and which, outside its "..."
## strings, has no other Resource(...) or Object(...) value, comment, ' or
## NUL. A .tres from elsewhere can otherwise run code as it loads (a
## GDScript sub-resource, or any script it names), and text that isn't a
## resource never reaches Godot's parser, which would log a parse error.
## A .remap or .import file beside it would make Godot load another file.
static func _importable_note(path: String) -> bool:
	if FileAccess.file_exists(path + ".remap") or FileAccess.file_exists(path + ".import"):
		return false
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	if bytes.is_empty() or bytes.has(0):
		return false
	var literals: PackedStringArray = []
	var bare: String = _without_strings(bytes.get_string_from_utf8(), literals)
	if not bare.strip_edges().begins_with("[gd_resource") or bare.contains(";") or bare.contains("'"):
		return false
	if bare.contains("sub_resource") or bare.replace("ExtResource(", "").contains("Resource(") or bare.contains("Object("):
		return false
	var sections: Dictionary = {}
	for m in _section_re().search_all(bare):
		var tag: String = m.get_string(1)
		var attrs: Dictionary = {}
		for a in _attr_re().search_all(m.get_string(2)):
			attrs[a.get_string(1)] = literals[int(a.get_string(2))]
		sections[tag] = int(sections.get(tag, 0)) + 1
		if tag == "gd_resource" and (attrs.get("type", "") != "Resource" or attrs.get("script_class", "ContentLayer") != "ContentLayer"):
			return false
		if tag == "ext_resource" and (attrs.get("type", "") != "Script" or attrs.get("path", "") != "res://ContentLayer.gd"):
			return false
	return sections.get("gd_resource", 0) == 1 and sections.get("resource", 0) == 1 and sections.get("ext_resource", 0) <= 1


## `text` with each "..." string (backslash escapes honoured) replaced by
## "<n>", its index in `literals`, which gets the string's contents. "" when
## a string never ends.
static func _without_strings(text: String, literals: PackedStringArray) -> String:
	var parts: PackedStringArray = []
	var at: int = 0
	while true:
		var open: int = text.find("\"", at)
		if open < 0:
			break
		var close: int = open
		while true:
			close = text.find("\"", close + 1)
			if close < 0:
				return ""
			var slashes: int = 0
			while text[close - 1 - slashes] == "\\":
				slashes += 1
			if slashes % 2 == 0:
				break
		parts.append(text.substr(at, open - at))
		parts.append("\"%d\"" % literals.size())
		literals.append(text.substr(open + 1, close - open - 1))
		at = close + 1
	parts.append(text.substr(at))
	return "".join(parts)


static var _section_regex: RegEx = null
static var _attr_regex: RegEx = null


## The section tags a .tres may hold, wherever they are outside strings:
## [gd_resource attrs], [ext_resource attrs], [resource]. (Godot reads a
## tag after any value, not only at the start of a line; "sub_resource" is
## refused before this.)
static func _section_re() -> RegEx:
	if _section_regex == null:
		_section_regex = RegEx.create_from_string("\\[\\s*(gd_resource|ext_resource|resource)\\b([^\\]]*)\\]")
	return _section_regex


## One `name="<n>"` attribute of a tag whose strings are numbered.
static func _attr_re() -> RegEx:
	if _attr_regex == null:
		_attr_regex = RegEx.create_from_string("(\\w+)\\s*=\\s*\"(\\d+)\"")
	return _attr_regex


## Copy the model or picture `from` to `to` in the vault's asset folder
## `kind` (models/, images/; the caller checked its type, IMPORT_ASSETS),
## counted in r[kind]. A file already there with the same bytes is skipped;
## one whose name is taken by other bytes is left out and counted in
## r["<kind>_conflicts"] ("model_conflicts").
static func _import_asset(from: String, to: String, kind: String, r: Dictionary) -> void:
	if FileAccess.file_exists(to):
		if FileAccess.get_sha256(to) != FileAccess.get_sha256(from):
			r[kind.trim_suffix("s") + "_conflicts"] += 1
	elif DirAccess.make_dir_recursive_absolute(to.get_base_dir()) == OK and DirAccess.copy_absolute(from, to) == OK:
		r[kind] += 1
	else:
		r.failed += 1
