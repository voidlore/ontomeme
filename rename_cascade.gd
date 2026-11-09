class_name RenameCascade
extends RefCounted
## RenameCascade — what follows a note's new title, so nothing that named the
## old one is left pointing at nothing.
##
## After the note itself is renamed (VaultStore.rename_note in the app, the
## MCP update_note), run() over the vault's notes:
##   1. [[links]] that resolved to the note (WikiLinks, with the note under
##      its old title) get the new title; "#heading" and "|alias" stay, and
##      `code spans` and fenced blocks are never touched.
##   2. learn: / review: / see: / next: lines inside quiz and flashcard
##      blocks that name the note (bare or [[ ]]) get the new title.
##   3. Each changed note is written by the caller's `write` (the app saves
##      through VaultStore.save_note; MCP passes its hash gate).
##   4. Journey demo and log keys ("<old>#quiz0") move to the new title.
##   5. Progress keys ("<old lower>#0") and learn / from fields move too.
## apply() is the app's run(): VaultStore.note_list and save_note, stopping
## at the first note whose save turns into a conflict copy or fails.
##
## A title with "]", "|" or "`" can't be named by a [[link]], so [[links]] are
## left as they are for it (a warning says so); learn: / next: lines, which
## read their value whole, the Journey and progress still follow (lines_follow).
## "untitled" (VaultStore.shared_title) names no one note: any number of notes
## have it and every new note starts with it. Naming an untitled note moves
## nothing, since [[untitled]], "untitled#0" and "untitled#quiz0" may be any
## untitled note's; clearing a title moves nothing either (a warning says the
## links were left), since the keys would land on other untitled notes' and
## a link to "untitled" would open whichever untitled note comes first.

## Keys of quiz / flashcard block lines whose value names a note.
const NOTE_KEYS: Array[String] = ["learn", "review", "see", "next"]


## The app's cascade, after VaultStore.rename_note(renamed, new_title)
## succeeded. Notes are saved with save_note (their `modified` kept: the
## user didn't edit them). A save that keeps an outside edit and writes ours
## as a conflict copy stops the note rewrites there, as does a save that
## fails (the note is left as it was); the report's warning says which note
## and copy, or why. Returns run()'s report.
## `order` is VaultStore.note_list as it stood before the rename. A link goes
## to the first note with its title in that order (newest first), and the
## rename's save made the note the newest: in a vault with two notes of one
## title (from before renames refused that), links to the other one would
## look like links to this one. Without `order`, note_list's order is used.
static func apply(old_title: String, new_title: String, renamed: ContentLayer = null, order: Array = []) -> Dictionary:
	if renamed == null:
		var i: int = VaultStore.get_note_index(new_title)
		renamed = VaultStore.note_list[i] if i >= 0 else null
	var notes: Array = VaultStore.note_list.duplicate()
	if not order.is_empty():
		var at: Dictionary = {}
		for i in order.size():
			at[order[i]] = i
		notes.sort_custom(func(a: ContentLayer, b: ContentLayer) -> bool:
			return int(at.get(a, order.size())) < int(at.get(b, order.size())))
	return run(notes, renamed, old_title, new_title,
			func(note: ContentLayer, text: String) -> String: return _save_in_vault(note, text, old_title), true)


## The cascade over `notes` (every note of the vault, `renamed` among them,
## already carrying its new title, in the order links resolved over before
## the rename: newest first). `write.call(note, new_text) -> String`
## stores one rewritten note: "" when written, else why not, which becomes a
## warning; with `stop_on_warning` no further note is rewritten after one.
## The Journey and progress keys move either way, unless `move_keys` is false
## (the stores hold another vault's), the new title is "untitled", or another
## note still has the old title. Renaming an untitled note does nothing here.
## Report: {links, notes, changed: Array[ContentLayer], warnings:
## [{note, message}], stopped, journey, progress} (changed: notes written).
static func run(notes: Array, renamed: ContentLayer, old_title: String, new_title: String,
		write: Callable, stop_on_warning: bool = false, move_keys: bool = true) -> Dictionary:
	var report: Dictionary = {"links": 0, "notes": 0, "changed": [],
			"warnings": [], "stopped": false, "journey": 0, "progress": 0}
	new_title = new_title.strip_edges()
	if renamed == null or old_title.strip_edges() == "" or new_title == "" or old_title == new_title:
		return report
	if VaultStore.shared_title(old_title):   # what named "untitled" wasn't this note's alone
		return report
	var index: Dictionary = index_before(notes, renamed, old_title)
	var links: bool = links_follow(old_title, new_title)
	var lines: bool = lines_follow(old_title, new_title)
	var left: int = 0
	for note in notes:
		# Rewritten just before its write: a note the vault reloaded meanwhile
		# (an outside edit it noticed) is rewritten as reloaded.
		var r: Dictionary = rewrite(note.raw_text, renamed, new_title, index, links, lines)
		left += int(r.left)
		if r.links == 0:
			continue
		var why: String = write.call(note, r.text)
		if why != "":
			report.warnings.append({"note": note, "message": why})
			if stop_on_warning:
				report.stopped = true
				break
			continue
		report.links += r.links
		report.notes += 1
		report.changed.append(note)
	if left > 0:
		report.warnings.append({"note": null, "message": _left_message(old_title, new_title)})
	# Keys stay when they'd land on "untitled#0" (another note's, maybe), and
	# when another note still has the old title (two had it, from before
	# renames refused that): they name that note as much as this one.
	if move_keys and not VaultStore.shared_title(new_title) and VaultStore.title_holder_in(notes, old_title, renamed) == null:
		report.journey = JourneyStore.rename_note_keys(old_title, new_title)
		report.progress = ProgressStore.rename_note_keys(old_title, new_title)
	return report


## Whether [[links]] to `old_title` can follow the note to `new_title`: not
## when either is "untitled" (it names no one note), nor when the new title
## has "]", "|" or "`" (see linkable).
static func links_follow(old_title: String, new_title: String) -> bool:
	return linkable(new_title) and not VaultStore.shared_title(old_title) and not VaultStore.shared_title(new_title)


## Whether learn: / review: / see: / next: lines in quiz and flashcard blocks
## that name `old_title` can follow the note to `new_title`. The quiz card
## (NoteScene3D) and ProgressStore read such a value whole, trimming only a
## leading "[[" and a trailing "]]", with no code spans and no "|" alias: any
## title but "untitled" (see links_follow), except one that starts with "[[" or
## ends with "]]", which that trim would cut.
static func lines_follow(old_title: String, new_title: String) -> bool:
	new_title = new_title.strip_edges()
	return not VaultStore.shared_title(old_title) and not VaultStore.shared_title(new_title) \
			and not new_title.begins_with("[[") and not new_title.ends_with("]]")


## Lower-cased title -> note, as WikiLinks.title_index() builds it, but with
## `renamed` under `old_title`: what every link resolved to before the rename.
static func index_before(notes: Array, renamed: ContentLayer, old_title: String) -> Dictionary:
	var index: Dictionary = {}
	for note in notes:
		var key: String = (old_title if note == renamed else note.title).strip_edges().to_lower()
		if key != "" and not index.has(key):
			index[key] = note
	return index


## `text` with every reference to `renamed` (by `index`, see index_before)
## swapped for `new_title`: [[links]] outside code (unless `links` is false:
## see links_follow), and NOTE_KEYS lines in quiz and flashcard blocks (unless
## `lines` is false: see lines_follow). {text, links, left} (links =
## references rewritten, left = references held back by `links` / `lines`).
static func rewrite(text: String, renamed: ContentLayer, new_title: String, index: Dictionary,
		links: bool = true, lines: bool = true) -> Dictionary:
	var count: int = 0
	var left: int = 0
	var spans: Array[Dictionary] = WikiLinks.spans(text)
	for i in range(spans.size() - 1, -1, -1):   # from the end, so earlier offsets hold
		var span: Dictionary = spans[i]
		var title: String = _named_title(str(span.text), renamed, index)
		if title == "":
			continue
		if not links:
			left += 1
			continue
		var at: int = _skip_space(text, int(span.start) + 2)
		text = text.substr(0, at) + new_title + text.substr(at + title.length())
		count += 1
	var block: Dictionary = _rewrite_block_lines(text, renamed, new_title, index, lines)
	return {"text": block.text, "links": count + int(block.links), "left": left + int(block.left)}


## The status-line tail for a report: " · updated 3 links in 2 notes", then
## the first warning, if any. "" when nothing needed changing.
static func summary(report: Dictionary) -> String:
	var out: String = ""
	if int(report.get("links", 0)) > 0:
		var links: int = report.links
		var notes: int = report.notes
		out = " · updated %d link%s in %d note%s" % [links, "" if links == 1 else "s", notes, "" if notes == 1 else "s"]
	var warnings: Array = report.get("warnings", [])
	if not warnings.is_empty():
		out += " · " + str(warnings[0].message)
	return out


## A title a [[link]] can name: "]" ends the link and "|" starts its alias,
## and a "`" may pair with another into a `code span`, which WikiLinks and the
## Read view cut out of a line before they look for links.
static func linkable(title: String) -> bool:
	return not title.contains("]") and not title.contains("|") and not title.contains("`")


# ── Internals ───────────────────────────────────────────────────────────────

## run()'s warning when references were held back (see links_follow and
## lines_follow).
static func _left_message(old_title: String, new_title: String) -> String:
	if VaultStore.shared_title(new_title):
		return "a [[link]] can't name an untitled note, so links to “%s” were left as they are" % old_title
	if lines_follow(old_title, new_title):   # only [[links]] were held back
		return "a [[link]] can't name a title with ], | or `, so [[links]] to “%s” were left as they are" % old_title
	return "a quiz's learn: or next: line can't name a title that starts with [[ or ends with ]], so references to “%s” were left as they are" % old_title


## The app's writer: save `note` with `text` through the vault's hash guard.
## A save that fails (read-only file or folder, full disk) leaves the note as
## it was, in memory and on disk, and says why: nothing would retry it.
static func _save_in_vault(note: ContentLayer, text: String, old_title: String) -> String:
	if VaultStore.save_text_or_keep(note, text, false) != OK:
		return "couldn't save “%s” (%s), so its links to “%s” were left as they are" % [note.title, VaultStore.last_save_error, old_title]
	var copy: ContentLayer = VaultStore.last_conflict_copy
	if copy == null:
		return ""
	return "“%s” changed on disk, so it was kept as it is and the updated links are in “%s”" % [note.title, copy.title]


## The part of a link or learn: value that names `renamed`, or "".
static func _named_title(target: String, renamed: ContentLayer, index: Dictionary) -> String:
	if WikiLinks.resolve(target, index) != renamed:
		return ""
	return WikiLinks.matched_title(target, index)


## learn:/review:/see:/next: lines in closed quiz and flashcard blocks,
## fences found the way JourneyStore.scene_blocks finds them. {text, links,
## left}: with `follow` false the lines are only counted, as left.
static func _rewrite_block_lines(text: String, renamed: ContentLayer, new_title: String, index: Dictionary,
		follow: bool = true) -> Dictionary:
	if not text.contains("```"):
		return {"text": text, "links": 0, "left": 0}
	var lines: PackedStringArray = text.split("\n")
	var count: int = 0
	var fence: int = 0
	var info: String = ""
	var body: Array[int] = []
	for i in lines.size():
		var s: String = lines[i].strip_edges()
		var ticks: int = WikiLinks.fence_ticks(s)
		if fence == 0:
			if ticks > 0:
				fence = ticks
				info = s.substr(ticks).strip_edges()
				body.clear()
		elif ticks >= fence and s.substr(ticks).strip_edges() == "":
			count += _rewrite_activity(lines, body, info, renamed, new_title, index, follow)
			fence = 0
		else:
			body.append(i)
	if not follow:
		return {"text": text, "links": 0, "left": count}
	return {"text": "\n".join(lines) if count > 0 else text, "links": count, "left": 0}


## One closed fence: if it is a quiz or flashcard block, rewrite its
## NOTE_KEYS lines (`body` = their line numbers in `lines`) in place, or with
## `follow` false only count them. Returns how many name `renamed`.
static func _rewrite_activity(lines: PackedStringArray, body: Array[int], info: String,
		renamed: ContentLayer, new_title: String, index: Dictionary, follow: bool = true) -> int:
	if not NoteScene3D.is_scene_fence(info):
		return 0
	var block: PackedStringArray = []
	for i in body:
		block.append(lines[i])
	if JourneyStore.activity_kind(NoteScene3D.parse_block(info, block)) == "":
		return 0
	var count: int = 0
	for i in body:
		var line: String = lines[i]
		var colon: int = line.find(":")
		if colon <= 0 or not NOTE_KEYS.has(line.substr(0, colon).strip_edges().to_lower()):
			continue
		var at: int = _skip_space(line, colon + 1)
		if line.substr(at).begins_with("[["):
			at = _skip_space(line, at + 2)
		var value: String = line.substr(at).strip_edges().trim_suffix("]]").strip_edges()
		var title: String = _named_title(value, renamed, index)
		if title != "":
			if follow:
				lines[i] = line.substr(0, at) + new_title + line.substr(at + title.length())
			count += 1
	return count


## The first index at or after `at` that isn't whitespace (strip_edges' idea
## of it: any character up to a space).
static func _skip_space(s: String, at: int) -> int:
	while at < s.length() and s.unicode_at(at) <= 32:
		at += 1
	return at
