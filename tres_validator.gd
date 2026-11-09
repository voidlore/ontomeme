class_name TresValidator
extends Node

## TresValidator — format validation for Godot .tres resource files.
##
## Pure helper (no Godot node deps) used by VaultStore to validate notes
## as they are loaded from the vault. Supports per-file and vault-wide
## validation with auto-fix capability.
##
## Usage:
##     var result := TresValidator.validate(path)
##     var report := TresValidator.validate_vault(path)


## Validation result codes.
enum ValidationResult {
	VALID,
	MISSING_FIELD,
	INVALID_TYPE,
	CORRUPTED_FILE,
	UNKNOWN_RESOURCE,
}

## The one script a note may reference.
const CONTENT_LAYER_SCRIPT: String = "res://ContentLayer.gd"

## Section tags Godot's text resource loader acts on.
const _TAGS: Array[String] = ["gd_resource", "gd_scene", "ext_resource", "sub_resource", "resource", "node", "connection", "editable"]

## Attributes an [ext_resource] for ContentLayer.gd may carry.
const _EXT_ATTRS: Array[String] = ["type", "uid", "path", "id"]

## Files beside a note that make ResourceLoader read another file in its
## place, from wherever their `path=` points: "<note>.remap" always, and
## "<note>.import" when Godot's own parser rejects the note. Godot writes
## neither for a note in a vault.
const _REDIRECTS: Array[String] = [".remap", ".import"]

static var _control_re: RegEx = RegEx.create_from_string("[\\x01-\\x1f]")
## Where a tag Godot's loader acts on (_TAGS) starts, in the text outside
## strings; any other "[" (a value such as Array[String]) is passed over.
static var _tag_start_re: RegEx = RegEx.create_from_string("\\[ *(?:gd_resource|gd_scene|ext_resource|sub_resource|resource|node|connection|editable)(?![A-Za-z0-9_])")
## Read at an offset (\G) in the text outside strings, where every whitespace
## or control character is a space; possessive (*+, ++), so a long run is read
## once, never re-scanned. A tag's "[" and name:
static var _tag_name_re: RegEx = RegEx.create_from_string("\\G\\[ *([A-Za-z_][A-Za-z0-9_]*+)")
## …one ` name = value` field, the value a "<n>" string (n indexes the
## literals) or digits, followed by a space or the closing "]":
static var _tag_field_re: RegEx = RegEx.create_from_string("\\G *([A-Za-z_][A-Za-z0-9_]*+) *= *(?:\"(\\d++)\"|(\\d++))(?=[ \\]])")
## …and the tag's closing "]".
static var _tag_close_re: RegEx = RegEx.create_from_string("\\G *\\]")
## A character Godot could read differently from its raw text in a field's
## string: anything but printable ASCII, and the backslash of an escape.
static var _field_char_re: RegEx = RegEx.create_from_string("[^\\x20-\\x5b\\x5d-\\x7e]")
static var _script_line_re: RegEx = RegEx.create_from_string("script\\s*=\\s*ExtResource\\(\\s*\"(\\d+)\"\\s*\\)")


## Whether the .tres at `path` can be loaded without running code. Godot runs
## a script's _init and static initialisers while it loads a resource, and a
## .tres can carry one: a [sub_resource type="GDScript"], an [ext_resource]
## or Resource("...") naming any script file, an Object(...) value, or a
## script as the main resource. So the file is read as bytes and checked
## before ResourceLoader ever parses it.
##
## Text inside "..." strings (backslash escapes honoured) is ignored, so a note
## body may mention [sub_resource or Object( freely. Outside strings a file may
## hold only its [gd_resource ...] header (main type a Resource, not a Script),
## at most one [ext_resource type="Script" ... path="res://ContentLayer.gd" ...],
## one [resource] section and `script = ExtResource("<that id>")`. A tag's
## fields are read token by token, as Godot reads them (_read_tag), and must
## each be `name = "<plain string>"` or `name = <digits>`. Anything else that
## could load code is refused, and so are a NUL byte, a `;` comment or a `'`
## outside strings, which could make Godot read the text differently from
## this scan.
##
## A note with a ".remap" or ".import" file beside it is refused too: Godot
## would load the file that names, which this scan never reads.
## Returns {"safe": bool, "reason": String} (reason is "" when safe).
static func check_text_safe(path: String) -> Dictionary:
	for ext in _REDIRECTS:
		if FileAccess.file_exists(path + ext):
			return _unsafe("a %s file beside it would make Godot load another file" % ext)
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return _unsafe("it is empty or unreadable")
	if bytes.has(0):
		return _unsafe("it holds binary data")
	# One char per byte, the way Godot's parser reads a .tres; a UTF-8 BOM,
	# which Godot accepts, is skipped.
	var text: String = bytes.get_string_from_ascii().trim_prefix("\u00ef\u00bb\u00bf")
	var literals: PackedStringArray = []
	var outside: String = _outside_strings(text, literals)
	if outside == "":
		return _unsafe("a string never ends")
	# Godot skips control characters between tokens, as it does spaces.
	outside = _control_re.sub(outside, " ", true)
	if outside.contains(";") or outside.contains("'"):
		return _unsafe("a comment or a ' outside a string")
	if outside.contains("sub_resource"):
		return _unsafe("an embedded [sub_resource]")
	return _check_sections(outside, literals)


## `text` with every "..." string replaced by "<n>", its index in `literals`,
## where the string's raw contents go. "" when a string never closes.
static func _outside_strings(text: String, literals: PackedStringArray) -> String:
	var parts: PackedStringArray = []
	var at: int = 0
	while true:
		var open: int = text.find("\"", at)
		if open < 0:
			break
		var close: int = _closing_quote(text, open)
		if close < 0:
			return ""
		parts.append(text.substr(at, open - at))
		parts.append("\"%d\"" % literals.size())
		literals.append(text.substr(open + 1, close - open - 1))
		at = close + 1
	parts.append(text.substr(at))
	return "".join(parts)


## Index of the quote closing the string opened at `open`, or -1. A quote
## after an odd run of backslashes is escaped and does not close it.
static func _closing_quote(text: String, open: int) -> int:
	var at: int = open + 1
	while true:
		var q: int = text.find("\"", at)
		if q < 0:
			return -1
		var slashes: int = 0
		while text.unicode_at(q - 1 - slashes) == 92:   # backslash
			slashes += 1
		if slashes % 2 == 0:
			return q
		at = q + 1
	return -1


## The section rules of check_text_safe, on the text outside strings, where
## every whitespace or control character is a space. The file must start
## with its [gd_resource] header; after it only the tags Godot acts on are
## read (_tag_start_re), and each may appear once, so the scan takes time in
## proportion to the file's length.
static func _check_sections(outside: String, literals: PackedStringArray) -> Dictionary:
	var ext_id: String = ""
	var seen: Dictionary = {}
	var at: int = outside.find("[")
	if at < 0 or outside.substr(0, at).strip_edges() != "":
		return _unsafe("it does not start with a [gd_resource] header")
	while at >= 0:
		var tag: Dictionary = _read_tag(outside, at, literals)
		if tag.has("error"):
			return _unsafe(tag.error)
		var name: String = tag.name
		if seen.is_empty() and name != "gd_resource":
			return _unsafe("it does not start with a [gd_resource] header")
		var next: RegExMatch = _tag_start_re.search(outside, tag.end)
		at = next.get_start() if next != null else -1
		if name not in ["gd_resource", "ext_resource", "resource"]:
			return _unsafe("a [%s] section" % name)
		if seen.has(name):
			return _unsafe("more than one [%s] section" % name)
		seen[name] = true
		var fields: Dictionary = tag.fields
		if name == "gd_resource" and not _is_plain_resource_type(str(fields.get("type", ""))):
			return _unsafe("its main resource is not a plain resource (type \"%s\")" % str(fields.get("type", "")))
		if name == "ext_resource":
			if not _is_content_layer_ext(fields):
				return _unsafe("an [ext_resource] other than %s" % CONTENT_LAYER_SCRIPT)
			ext_id = str(fields.id)
	if outside.count("ext_resource") != (1 if ext_id != "" else 0):
		return _unsafe("an [ext_resource] the scan cannot read")
	outside = _without_script_line(outside, literals, ext_id)
	if outside.contains("Object") or outside.contains("Resource"):
		return _unsafe("an Object or Resource value outside a string")
	return {"safe": true, "reason": ""}


## The tag whose "[" is at `at` in `outside` (check_text_safe's text outside
## strings): {name, fields, end}, `end` just past its "]". Only a tag Godot's
## loader acts on (_TAGS) has its fields read; for any other "[" (a value
## such as Array[String]) `fields` is {} and `end` is just past its name.
## Godot reads a tag token by token: it splits `format=3type="GDScript"` into
## two fields and reads on past the "]" of a value such as `uid=[]`, and the
## last of two equal names wins. So every field must be `name = "<string>"`
## or `name = <digits>`, followed by a space or the closing "]"; the string
## holds printable ASCII only, without escapes, so its raw text is what Godot
## reads; and no name repeats. A tag that is anything else gives {error}.
static func _read_tag(outside: String, at: int, literals: PackedStringArray) -> Dictionary:
	var m: RegExMatch = _tag_name_re.search(outside, at)
	if m == null:
		return {"name": "", "fields": {}, "end": at + 1}
	var name: String = m.get_string(1)
	if not name in _TAGS:
		return {"name": name, "fields": {}, "end": m.get_end()}
	var fields: Dictionary = {}
	var pos: int = m.get_end()
	while true:
		var close: RegExMatch = _tag_close_re.search(outside, pos)
		if close != null:
			return {"name": name, "fields": fields, "end": close.get_end()}
		var f: RegExMatch = _tag_field_re.search(outside, pos)
		if f == null:
			return {"error": "a [%s] tag the scan cannot read" % name}
		var key: String = f.get_string(1)
		if fields.has(key):
			return {"error": "a repeated attribute in [%s]" % name}
		var value: String = literals[f.get_string(2).to_int()] if f.get_string(2) != "" else f.get_string(3)
		if _field_char_re.search(value) != null:
			return {"error": "an escape or a non-ASCII character in a [%s] attribute" % name}
		fields[key] = value
		pos = f.get_end()
	return {}


## The fields of the [gd_resource] header `text` starts with, read the way
## check_text_safe reads them (_read_tag); {} when it starts with anything
## else, or its header is not plain fields. `text` may be just the file's
## first bytes: only its header is read.
static func header_fields(text: String) -> Dictionary:
	text = text.trim_prefix("\ufeff").trim_prefix("\u00ef\u00bb\u00bf")
	var end: int = header_end(text)
	if end < 0:
		return {}
	var literals: PackedStringArray = []
	var outside: String = _control_re.sub(_outside_strings(text.substr(0, end), literals), " ", true)
	var at: int = outside.find("[")
	if at < 0 or outside.substr(0, at).strip_edges() != "":
		return {}
	var tag: Dictionary = _read_tag(outside, at, literals)
	return tag.fields if tag.get("name", "") == "gd_resource" and tag.get("end", -1) == outside.length() else {}


## Index just past the first "]" outside a string in `text` (the end of the
## header tag a .tres starts with), or -1.
static func header_end(text: String) -> int:
	var at: int = 0
	var close: int = text.find("]")
	while close >= 0:
		var quote: int = text.find("\"", at)
		if quote < 0 or quote > close:
			return close + 1
		var string_end: int = _closing_quote(text, quote)
		if string_end < 0:
			return -1
		at = string_end + 1
		if close < at:
			close = text.find("]", at)
	return -1


## A Resource class Godot itself provides, and not a Script (whose source
## would be compiled, and its static initialisers run, while loading).
static func _is_plain_resource_type(type: String) -> bool:
	return ClassDB.class_exists(type) and ClassDB.is_parent_class(type, "Resource") \
			and not ClassDB.is_parent_class(type, "Script")


## The [ext_resource] a ContentLayer note carries. Godot resolves a known uid
## before the path, so a uid must not name another file.
static func _is_content_layer_ext(attrs: Dictionary) -> bool:
	for name in attrs:
		if not name in _EXT_ATTRS:
			return false
	if attrs.get("type") != "Script" or attrs.get("path") != CONTENT_LAYER_SCRIPT or str(attrs.get("id", "")) == "":
		return false
	if attrs.has("uid"):
		var uid: int = ResourceUID.text_to_id(attrs.uid)
		if uid != ResourceUID.INVALID_ID and ResourceUID.has_id(uid) and ResourceUID.get_id_path(uid) != CONTENT_LAYER_SCRIPT:
			return false
	return true


## `outside` with its one `script = ExtResource("<ext_id>")` blanked out;
## unchanged when there is no such line, or more than one.
static func _without_script_line(outside: String, literals: PackedStringArray, ext_id: String) -> String:
	var lines: Array[RegExMatch] = _script_line_re.search_all(outside)
	if ext_id == "" or lines.size() != 1 or literals[lines[0].get_string(1).to_int()] != ext_id:
		return outside
	var m: RegExMatch = lines[0]
	return outside.substr(0, m.get_start()) + " ".repeat(m.get_end() - m.get_start()) + outside.substr(m.get_end())


static func _unsafe(reason: String) -> Dictionary:
	return {"safe": false, "reason": reason}


## Validate a single .tres file.
## Returns a dictionary: {"valid": bool, "errors": Array[String], "note": ContentLayer}.
## A file that would run code (check_text_safe) is never loaded.
static func validate(path: String) -> Dictionary:
	var result = {"valid": true, "errors": [], "note": null, "fixed": false}

	# Check file exists and readable
	if not FileAccess.file_exists(path):
		result.valid = false
		result.errors.append("FILE_NOT_FOUND: " + path)
		return result

	# A cached note is handed back without reading the file again.
	if not ResourceLoader.has_cached(path):
		var safety: Dictionary = check_text_safe(path)
		if not safety.safe:
			result.valid = false
			result.errors.append("UNSAFE_FILE: " + safety.reason)
			return result

	# Load the resource
	var resource: Resource = ResourceLoader.load(path)
	if resource == null:
		result.valid = false
		result.errors.append("CORRUPTED_FILE: could not load resource")
		return result

	# Check it's a ContentLayer
	if not resource is ContentLayer:
		result.valid = false
		result.errors.append("UNKNOWN_RESOURCE: expected ContentLayer, got " + resource.get_class())
		return result

	# Validate required fields
	var errors := _check_fields(resource)
	if not errors.is_empty():
		result.valid = false
		result.errors.append_array(errors)
		# Try auto-fix
		var fixed := _auto_fix(resource)
		if fixed:
			result["fixed"] = true
			# Re-validate after fix
			errors = _check_fields(resource)
			if errors.is_empty():
				result.valid = true
				result.errors = []

	result["note"] = resource
	return result


## Check required fields on a ContentLayer resource. A field this build does
## not know (one a newer Ontomeme wrote, ContentLayer._extra) is not checked:
## the note keeps it as it was read.
static func _check_fields(resource: ContentLayer) -> Array[String]:
	var errors: Array[String] = []

	var title_val = resource.get("title")
	if title_val == null or title_val == "":
		errors.append("MISSING_FIELD: title")
	elif title_val is not String:
		errors.append("INVALID_TYPE: title should be String, got " + str(typeof(title_val)))

	var raw_val = resource.get("raw_text")
	# An empty body is a valid (new) note: Godot omits default-valued
	# properties from .tres files, so "" simply never appears on disk.
	if raw_val == null:
		errors.append("MISSING_FIELD: raw_text")
	elif raw_val is not String:
		errors.append("INVALID_TYPE: raw_text should be String, got " + str(typeof(raw_val)))

	var struct_val = resource.get("structure")
	if struct_val == null:
		errors.append("MISSING_FIELD: structure")
	elif struct_val is not Dictionary:
		errors.append("INVALID_TYPE: structure should be Dictionary, got " + str(typeof(struct_val)))

	var tags_val = resource.get("tags")
	if tags_val == null:
		errors.append("MISSING_FIELD: tags")
	elif tags_val is not Array:
		errors.append("INVALID_TYPE: tags should be Array, got " + str(typeof(tags_val)))

	if resource.get("created") == null:
		errors.append("MISSING_FIELD: created")

	if resource.get("modified") == null:
		errors.append("MISSING_FIELD: modified")

	return errors


## Attempt to auto-fix a ContentLayer with missing or invalid fields.
## Returns true if any fix was applied.
static func _auto_fix(resource: ContentLayer) -> bool:
	var fixed = false

	if resource.get("title") == null or resource.get("title") == "":
		resource.title = _generate_title_from_path(resource.resource_path)
		fixed = true

	if resource.get("raw_text") == null:
		resource.raw_text = ""
		fixed = true

	if resource.get("structure") == null:
		resource.structure = {}
		fixed = true

	if resource.get("tags") == null:
		resource.tags = [] as Array[String]
		fixed = true

	if resource.get("created") == null or resource.get("created") == "":
		resource.created = Time.get_datetime_string_from_system()
		fixed = true

	if resource.get("modified") == null or resource.get("modified") == "":
		resource.modified = Time.get_datetime_string_from_system()
		fixed = true

	return fixed


## Generate a default title from a .tres file path:
## "Physics/note_wave_speed.tres" -> "Wave Speed".
static func _generate_title_from_path(path: String) -> String:
	var filename := path.get_file()
	if filename.ends_with(".tres"):
		filename = filename.trim_suffix(".tres")
	# The app names note files "note_<title>"
	filename = filename.trim_prefix("note_")
	# Replace underscores with spaces and humanize
	filename = filename.replace("_", " ")
	# Capitalize words
	var words := filename.split(" ")
	for i in range(words.size()):
		if words[i].length() > 0:
			words[i] = words[i][0].to_upper() + words[i].substr(1)
	var title: String = " ".join(words).strip_edges()
	return title if title != "" else "Untitled Note"


## Validate all .tres files in a vault directory.
## Returns a report dictionary.
static func validate_vault(vault_path: String) -> Dictionary:
	var all_valid := true
	var valid_count := 0
	var invalid_count := 0
	var errors := []
	var fixed_count := 0

	if not DirAccess.dir_exists_absolute(vault_path):
		return {"valid": false, "errors": ["Vault directory not found: " + vault_path]}

	var dir := DirAccess.open(vault_path)
	if dir == null:
		return {"valid": false, "errors": ["Cannot open vault directory"]}

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".tres"):
			var path := vault_path.path_join(file_name)
			var result := validate(path)
			if result.valid:
				valid_count += 1
			else:
				all_valid = false
				invalid_count += 1
				var err_entry := {"file": file_name, "errors": result.errors}
				if result.get("fixed", false):
					err_entry["fixed"] = true
					fixed_count += 1
				errors.append(err_entry)
		file_name = dir.get_next()

	return {
		"valid": all_valid,
		"total": valid_count + invalid_count,
		"valid_count": valid_count,
		"invalid_count": invalid_count,
		"fixed_count": fixed_count,
		"errors": errors,
	}


## Validate a note resource in memory without touching the filesystem.
## Useful after programmatic modifications before saving.
static func validate_note(note: ContentLayer) -> Dictionary:
	var result = {"valid": true, "errors": []}
	if note == null:
		result.valid = false
		result.errors.append("null note")
		return result

	var errors := _check_fields(note)
	if not errors.is_empty():
		result.valid = false
		result.errors = errors

	return result
