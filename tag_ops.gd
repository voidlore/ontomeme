class_name TagOps
extends RefCounted
## The one tag normalization, shared by the TagBar, the TAGS sidebar, the tag
## filter, the Markdown importer and the MCP tools, so "Physics", "physics"
## and "#physics" are one tag everywhere. Static and pure: no vault state,
## runs headless.
##
## Files on disk are not rewritten: comparisons normalize both sides, and a
## note is stored normalized the next time the app saves it. The one
## vault-wide rewrite is the user's own: rename() behind the TAGS section's
## "Rename or merge tag…" and "Remove from all notes…".
##
## The display rules (lowercase only, whitespace becomes '-') are still an
## open decision, so they live in normalize() alone: if the decision changes,
## this one function changes.

static var _whitespace: RegEx = null


## The canonical form of a tag: trimmed, leading '#'s dropped, lowercase,
## each run of whitespace turned into one '-'. "" when nothing is left.
static func normalize(s: String) -> String:
	var t: String = s.strip_edges().lstrip("#").strip_edges().to_lower()
	if _whitespace == null:
		_whitespace = RegEx.create_from_string("\\s+")
	return _whitespace.sub(t, "-", true)


## normalize() each tag, dropping empty ones and later duplicates; the first
## occurrence keeps its place.
static func normalize_list(tags: Array) -> Array[String]:
	var out: Array[String] = []
	for t in tags:
		var n: String = normalize(str(t))
		if n != "" and not n in out:
			out.append(n)
	return out


## Normalized tag -> how many notes carry it, each note counted once per tag
## (a note tagged both "Physics" and "physics" counts once). A note is a
## ContentLayer (anything with `tags`), a Dictionary with "tags", or the
## tag Array itself.
static func counts(notes: Array) -> Dictionary:
	var out: Dictionary = {}
	for note in notes:
		for t in normalize_list(_tags_of(note)):
			out[t] = int(out.get(t, 0)) + 1
	return out


## Sort `tags` (keys of a counts() result) in place: most used first, then
## by name. The TAGS rows, the TagInput's suggestions and MCP's list_tags
## all list tags in this order.
static func sort_by_use(tags: Array, counts: Dictionary) -> void:
	tags.sort_custom(func(a, b) -> bool:
		if int(counts[a]) != int(counts[b]):
			return int(counts[a]) > int(counts[b])
		return str(a) < str(b))


## True when `note` carries `tag`, comparing normalized forms.
static func has(note: Variant, tag: String) -> bool:
	var want: String = normalize(tag)
	if want == "":
		return false
	for t in _tags_of(note):
		if normalize(str(t)) == want:
			return true
	return false


## True when one of `note`'s tags starts with `prefix`, comparing normalized
## forms: what a "#…" search typed so far matches ("#phys" finds #physics).
static func has_prefix(note: Variant, prefix: String) -> bool:
	var want: String = normalize(prefix)
	if want == "":
		return false
	for t in _tags_of(note):
		if normalize(str(t)).begins_with(want):
			return true
	return false


## Rename `from` to `to` on one note, comparing normalized forms: the tag
## keeps its place and is stored normalized, a note that already carries
## `to` keeps it once (a merge), and an empty `to` removes the tag. The
## note's other tags keep their spelling. Changes `note` (a ContentLayer, a
## Dictionary with "tags", or a tag Array) in place; true when it changed.
## A PackedStringArray is a copy, so it is never changed.
static func rename(note: Variant, from: String, to: String) -> bool:
	var old: String = normalize(from)
	var new: String = normalize(to)
	if old == new or note is PackedStringArray or not has(note, old):
		return false
	var out: Array[String] = []
	var kept: Array[String] = []   # the normalized form of each tag in `out`
	for t in _tags_of(note):
		var tag: String = str(t)
		var n: String = normalize(tag)
		if n == old:
			tag = new
			n = new
		if n != "" and not n in kept:
			kept.append(n)
			out.append(tag)
	_set_tags(note, out)
	return true


## Which of `n` colours `tag` takes: 32-bit FNV-1a over the normalized
## tag's UTF-8 bytes, mod n. Not String.hash(), whose value may change
## between Godot versions and platforms: a tag keeps its colour everywhere,
## and "Physics" and "#physics" share one. 0 when n < 1.
static func color_index(tag: String, n: int) -> int:
	if n < 1:
		return 0
	var h: int = 2166136261   # the FNV-1a 32-bit offset basis
	for b in normalize(tag).to_utf8_buffer():
		h = ((h ^ b) * 16777619) & 0xFFFFFFFF   # the FNV prime; < 2^57, no int64 overflow
	return h % n


static func _tags_of(note: Variant) -> Array:
	if note is Array or note is PackedStringArray:
		return Array(note)
	if note is Dictionary:
		return Array(note.get("tags", []))
	if note is Object and "tags" in note:
		return Array(note.tags)
	return []


static func _set_tags(note: Variant, tags: Array[String]) -> void:
	if note is Array:
		(note as Array).assign(tags)
	elif note is Dictionary:
		note["tags"] = tags
	elif note is Object and "tags" in note:
		note.tags = tags
