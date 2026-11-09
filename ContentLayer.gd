extends Resource
class_name ContentLayer

@export var title: String = ""
@export var created: String = ""
@export var modified: String = ""
@export var tags: Array[String] = []
## Nothing reads it. It stays because dropping it gains nothing: Godot leaves
## the default "" out of the file, and a note that does hold a label would
## keep it anyway, as a field this build does not know (_extra).
@export var tags_label: String = ""

## When the note was starred/pinned (ISO, like created/modified). Empty = off.
## Each is both the flag and its sort key, so a plain string compare sorts them.
@export var starred_at: String = ""
@export var pinned_at: String = ""

## A conflict copy's original: the vault-relative path of the note
## ("Sub/note_alpha.tres") whose outside edit this copy's words met
## (VaultStore._save_conflict_copy). Empty on every other note. The app finds
## the original by it first, by the copy's title second
## (VaultStore.conflict_original), and offers to settle the two.
@export var conflict_of: String = ""

@export_subgroup("Content")
@export var raw_text: String = ""
@export var structure: Dictionary = {}

## Fields of the note file this build does not know, name -> value: ones a
## newer Ontomeme added, or an older one had. Godot hands each to _set as it
## loads the file, and saves each one _get_property_list lists, so a save here
## writes them back unchanged instead of stripping them. Filled only by
## _set: a file's own `_extra = ...` line is ignored.
var _extra: Dictionary = {}:
	set(_value):
		pass

## Property names Resource and Object handle themselves (filled on first use).
static var _engine_names: Dictionary = {}


## Forget the kept fields before Godot reloads this note in place from its
## changed file (VaultStore._load_note_file, CACHE_MODE_REPLACE: Godot calls
## this on the cached object, then _set for each field the file names).
## Godot leaves a default value out of the file, so a newer build that
## clears a field just drops its line; a field kept from the old file would
## come back on the next save.
func _reset_state() -> void:
	_extra.clear()


## Keep a field this build does not know. Returns false for a name Godot
## handles (resource_name, script, metadata/...), which Godot then sets.
func _set(property: StringName, value: Variant) -> bool:
	if not _is_unknown_field(property):
		return false
	_extra[String(property)] = value
	return true


func _get(property: StringName) -> Variant:
	return _extra.get(String(property))


## Each kept field, as a stored script field like the exports: saved and
## duplicated, never shown in an inspector. The return type must be
## Array[Dictionary]: Godot 4.7 logs an error for an untyped Array.
func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = []
	for name: String in _extra:
		props.append({"name": name, "type": typeof(_extra[name]), "usage": PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_SCRIPT_VARIABLE})
	return props


## A plain field name that neither Resource nor Object owns. Exported
## fields never get here: Godot sets a script's own fields directly.
static func _is_unknown_field(property: String) -> bool:
	if _engine_names.is_empty():
		_engine_names["script"] = true
		for p: Dictionary in ClassDB.class_get_property_list("Resource"):
			_engine_names[p.name] = true
	return property.is_valid_ascii_identifier() and not _engine_names.has(property)
