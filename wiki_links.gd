class_name WikiLinks
extends RefCounted
## WikiLinks — the one parser and resolver for [[links]].
##
## Read view links (layer_engine._links_and_md), link clicks
## (note.gd open_note_by_title), the 2D graph (note.gd _build_graph), the 3D
## vault graph (note_scene3d._build_graph) and the "Linked from" list all go
## through here, so they agree on what a link is and where it points.
##
## Syntax: [[Title]], [[Title|shown text]], [[Title#Heading]] and
## [[Title#Heading|shown text]]. "\|" separates the shown text too: inside a
## table a bare "|" splits the cell, so Obsidian writes [[Title\|shown text]]
## there (Read view's table cells read it as "|"). Nothing inside a fenced
## block or a `code span` is a link. A fence opens on a line starting with 3+
## backticks and closes on a line of at least as many (the renderer's rule,
## layer_engine._fence_ticks), so a ```` block can show ``` examples.
##
## Resolution is exact and case-insensitive, never fuzzy or partial. A link
## names the note whose whole title is its text; failing that, the text minus
## its "#heading" (titles may contain '#', e.g. "C# Tips"). With duplicate
## titles the first in VaultStore.note_list wins, the order
## open_note_by_title has always scanned.
##
## Not adopted yet: md_export.gd keeps its own [[link]] regex (it belongs to
## the md_export area). It should take its links from spans() and resolve()
## so [[Note#Heading]] exports to Note's file instead of staying literal.

const _LINK_RX: String = "\\[\\[((?:[^\\]|\\\\]|\\\\(?!\\|))+)(?:\\\\?\\|([^\\]]+))?\\]\\]"
const _CODE_RX: String = "`([^`]+)`"

static var _link_rx: RegEx = null
static var _code_rx: RegEx = null

## How many times title_index() has walked the vault. Tests read it: a Read
## view render must build the index once, not once per link.
static var index_builds: int = 0


## Every [[link]] in a note's text, skipping fenced blocks and `code spans`.
## Each span: {target, heading, alias, text, start, end}. `target` is the
## title part (before '#'), `heading` the part after '#', `alias` the shown
## text after '|' ("" when absent), `text` the whole part before '|'.
## start/end are offsets of "[[" and just past "]]" in `text`.
## Resolve a span with resolve(span.text), not span.target, so a title that
## contains '#' still resolves.
static func spans(text: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not text.contains("[["):
		return out
	var in_code: bool = false
	var fence_len: int = 0
	var offset: int = 0
	for line in text.split("\n"):
		var s: String = line.strip_edges()
		var ticks: int = fence_ticks(s)
		if in_code:
			if ticks >= fence_len and s.substr(ticks).strip_edges() == "":
				in_code = false
		elif ticks > 0:
			in_code = true
			fence_len = ticks
		elif line.contains("[["):
			out.append_array(_line_spans(line, offset))
		offset += line.length() + 1
	return out


## The [[links]] in `text` taken literally: no fence or code-span skipping.
## For callers that have already split code out (the Read view renders one
## code-free piece of a line at a time). `offset` shifts start/end.
static func link_spans(text: String, offset: int = 0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not text.contains("[["):
		return out
	for m in _link_regex().search_all(text):
		var inner: String = m.get_string(1).strip_edges()
		var cut: int = inner.find("#")
		out.append({
			"target": inner if cut < 0 else inner.substr(0, cut).strip_edges(),
			"heading": "" if cut < 0 else inner.substr(cut + 1).strip_edges(),
			"alias": m.get_string(2).strip_edges(),
			"text": inner,
			"start": offset + m.get_start(),
			"end": offset + m.get_end(),
		})
	return out


## Number of leading backticks if the stripped line `s` opens or closes a
## fence (>= 3), else 0. The same rule as layer_engine._fence_ticks.
static func fence_ticks(s: String) -> int:
	var n: int = 0
	while n < s.length() and s[n] == "`":
		n += 1
	return n if n >= 3 else 0


## Lower-cased, trimmed title -> the first note with that title, over
## VaultStore.note_list. Build it once and pass it to resolve()/outgoing()
## when resolving many links (the graphs, the Read view, backlinks).
static func title_index() -> Dictionary:
	index_builds += 1
	var index: Dictionary = {}
	for note in VaultStore.note_list:
		var key: String = _key(note.title)
		if key != "" and not index.has(key):
			index[key] = note
	return index


## The note a link names, or null. `target` may carry "|alias" and
## "#heading". Exact, case-insensitive title match: the whole text first,
## then without the alias, then without each "#…" suffix (longest first).
static func resolve(target: String, index: Dictionary = {}) -> ContentLayer:
	var titles: Dictionary = index if not index.is_empty() else title_index()
	for candidate in _candidates(target):
		var key: String = _key(candidate)
		if key != "" and titles.has(key):
			return titles[key]
	return null


## The leading part of `target` that resolve() matched to a title, without
## trailing spaces: "Photosynthesis #Light" -> "Photosynthesis"; "" when the
## link names no note. RenameCascade swaps exactly this part for a new title.
static func matched_title(target: String, index: Dictionary = {}) -> String:
	var titles: Dictionary = index if not index.is_empty() else title_index()
	for candidate in _candidates(target):
		var key: String = _key(candidate)
		if key != "" and titles.has(key):
			return candidate.strip_edges(false, true)
	return ""


## The title part of a link: "Note#Heading|shown" -> "Note". What a click
## on a link to a missing note creates.
static func base_title(target: String) -> String:
	return target.get_slice("|", 0).get_slice("#", 0).strip_edges()


## The title a link opens: the note it resolves to, else its base title.
static func link_title(span: Dictionary, index: Dictionary = {}) -> String:
	var note: ContentLayer = resolve(str(span.text), index)
	return note.title if note != null else str(span.target)


## The notes `note` links to, once each, in order of first mention.
## Links to itself are left out.
static func outgoing(note: ContentLayer, index: Dictionary = {}) -> Array[ContentLayer]:
	var out: Array[ContentLayer] = []
	if note == null:
		return out
	var found: Array[Dictionary] = spans(note.raw_text)
	if found.is_empty():
		return out
	var titles: Dictionary = index if not index.is_empty() else title_index()
	for span in found:
		var to: ContentLayer = resolve(str(span.text), titles)
		if to != null and to != note and not out.has(to):
			out.append(to)
	return out


## The notes that link to `note`, in VaultStore.note_list order. One pass
## over the vault picks the notes whose text mentions the title at all (and
## builds the title index, unless `index` brings one); only those are parsed.
static func backlinks(note: ContentLayer, index: Dictionary = {}) -> Array[ContentLayer]:
	var out: Array[ContentLayer] = []
	var want: String = _key(note.title) if note != null else ""
	if want == "":
		return out
	var build: bool = index.is_empty()
	var titles: Dictionary = {} if build else index
	var maybe: Array[ContentLayer] = []
	for n in VaultStore.note_list:
		if build:
			var key: String = _key(n.title)
			if key != "" and not titles.has(key):
				titles[key] = n
		if n != note and n.raw_text.contains("[[") and n.raw_text.to_lower().contains(want):
			maybe.append(n)
	for n in maybe:
		if outgoing(n, titles).has(note):
			out.append(n)
	return out


# ── Internals ───────────────────────────────────────────────────────────────

## One line outside fences: links in the pieces between `code spans`.
static func _line_spans(line: String, offset: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var last: int = 0
	for m in _code_regex().search_all(line):
		out.append_array(link_spans(line.substr(last, m.get_start() - last), offset + last))
		last = m.get_end()
	out.append_array(link_spans(line.substr(last), offset + last))
	return out


## The titles a link text may name, most specific first:
## "C# Tips#Intro|x" -> ["C# Tips#Intro|x", "C# Tips#Intro", "C# Tips", "C"].
static func _candidates(target: String) -> PackedStringArray:
	var out: PackedStringArray = [target]
	var name: String = target.get_slice("|", 0)
	if name != target:
		out.append(name)
	var cut: int = name.rfind("#")
	while cut >= 0:
		name = name.substr(0, cut)
		out.append(name)
		cut = name.rfind("#")
	return out


static func _key(title: String) -> String:
	return title.strip_edges().to_lower()


static func _link_regex() -> RegEx:
	if _link_rx == null:
		_link_rx = RegEx.create_from_string(_LINK_RX)
	return _link_rx


static func _code_regex() -> RegEx:
	if _code_rx == null:
		_code_rx = RegEx.create_from_string(_CODE_RX)
	return _code_rx
