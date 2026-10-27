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


## Validate a single .tres file.
## Returns a dictionary: {"valid": bool, "errors": Array[String], "note": ContentLayer}.
static func validate(path: String) -> Dictionary:
	var result = {"valid": true, "errors": [], "note": null, "fixed": false}

	# Check file exists and readable
	if not FileAccess.file_exists(path):
		result.valid = false
		result.errors.append("FILE_NOT_FOUND: " + path)
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


## Check required fields on a ContentLayer resource.
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
		resource.title = _generate_title_from_path(resource.file_path)
		fixed = true

	if resource.get("raw_text") == null:
		resource.raw_text = ""
		fixed = true

	if resource.get("structure") == null:
		resource.structure = {}
		fixed = true

	if resource.get("tags") == null:
		resource.tags = PackedStringArray([])
		fixed = true

	if resource.get("created") == null or resource.get("created") == "":
		resource.created = Time.get_datetime_string_from_system()
		fixed = true

	if resource.get("modified") == null or resource.get("modified") == "":
		resource.modified = Time.get_datetime_string_from_system()
		fixed = true

	return fixed


## Generate a default title from a .tres file path.
static func _generate_title_from_path(path: String) -> String:
	var filename := path.get_file()
	if filename.ends_with(".tres"):
		filename = filename.trim_suffix(".tres")
	# Replace underscores with spaces and humanize
	filename = filename.replace("_", " ")
	# Capitalize words
	var words := filename.split(" ")
	for i in range(words.size()):
		if words[i].length() > 0:
			words[i] = words[i][0].to_upper() + words[i].substr(1)
	return " ".join(words) if words.size() > 0 else "Untitled Note"


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
