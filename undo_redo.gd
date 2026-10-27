class_name UndoRedoEngine
extends Node

## UndoRedoEngine — command-based undo/redo for note editing.
##
## A singleton Node with static methods for undo/redo operations.
## Snapshots note titles before each state change; restores by title lookup.
##
## Usage:
##     UndoRedoEngine.max_depth = 100
##     UndoRedoEngine.push_snapshot(note)
##     var old := UndoRedoEngine.undo()
##     var restored := UndoRedoEngine.redo()
##

## Maximum undo history depth (configurable, default 50).
static var max_depth: int = 50

## Snapshot data for a single note.
## Tracks title -> raw_text at snapshot time.
static var _undo_stack: Array[Dictionary] = []
static var _redo_stack: Array[Dictionary] = []

## The currently active note (set by note.gd before each edit).
static var _current_note_title: String = ""

## Set the title of the note currently being edited.
## Must be called before push_snapshot.
static func set_current_note(title: String) -> void:
	_current_note_title = title


## Push a snapshot of the current note state.
## Records the title and raw_text so undo can restore it.
static func push_snapshot(note: ContentLayer) -> void:
	if note == null:
		return
	_current_note_title = note.title
	var snapshot: Dictionary = {
		"title": note.title,
		"raw_text": note.raw_text
	}
	# Push to undo stack
	_undo_stack.append(snapshot)
	# Prune if over max depth
	while _undo_stack.size() > max_depth:
		_undo_stack.pop_front()
	# Clear redo stack on new change
	_redo_stack.clear()


## Undo one step. Restores the previous state by loading the snapshot and
## setting _undo_result to the restored ContentLayer.
## Returns the restored ContentLayer, or null if nothing to undo.
static func undo() -> ContentLayer:
	if _undo_stack.is_empty():
		return null
	var snapshot: Dictionary = _undo_stack.pop_back()
	# Push current state to redo if there is a current note
	if _current_note_title != "" and _undo_stack.is_empty():
		var current_note: ContentLayer = _load_by_title(_current_note_title)
		if current_note != null:
			_redo_stack.append({
				"title": current_note.title,
				"raw_text": current_note.raw_text
			})
	# Load and restore the snapshot
	var restored: ContentLayer = _load_by_title(snapshot["title"])
	if restored != null:
		_current_note_title = snapshot["title"]
		return restored
	# If note not found, create fresh from snapshot
	var fresh: ContentLayer = ContentLayer.new()
	fresh.title = snapshot["title"]
	fresh.raw_text = snapshot["raw_text"]
	fresh.tags = []
	fresh.structure = {}
	fresh.created = Time.get_datetime_string_from_system()
	fresh.modified = fresh.created
	_current_note_title = fresh.title
	return fresh


## Redo one step. Restores the state that was undone.
## Returns the re-done ContentLayer, or null if nothing to redo.
static func redo() -> ContentLayer:
	if _redo_stack.is_empty():
		return null
	var snapshot: Dictionary = _redo_stack.pop_back()
	# Push current state to undo
	if _current_note_title != "":
		var current_note: ContentLayer = _load_by_title(_current_note_title)
		if current_note != null:
			_undo_stack.append({
				"title": current_note.title,
				"raw_text": current_note.raw_text
			})
	var restored: ContentLayer = _load_by_title(snapshot["title"])
	if restored != null:
		_current_note_title = snapshot["title"]
		return restored
	var fresh: ContentLayer = ContentLayer.new()
	fresh.title = snapshot["title"]
	fresh.raw_text = snapshot["raw_text"]
	fresh.tags = []
	fresh.structure = {}
	fresh.created = Time.get_datetime_string_from_system()
	fresh.modified = fresh.created
	_current_note_title = fresh.title
	return fresh


## Can undo be called?
static func can_undo() -> bool:
	return not _undo_stack.is_empty()


## Can redo be called?
static func can_redo() -> bool:
	return not _redo_stack.is_empty()


## Clear all undo/redo history.
static func clear() -> void:
	_undo_stack.clear()
	_redo_stack.clear()


## Get the current undo depth.
static func get_undo_depth() -> int:
	return _undo_stack.size()


## Get the current redo depth.
static func get_redo_depth() -> int:
	return _redo_stack.size()


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

## Load a ContentLayer by title from the VaultStore.
static func _load_by_title(title: String) -> ContentLayer:
	if title.is_empty():
		return null
	var idx := VaultStore.get_note_index(title)
	if idx < 0:
		return null
	return VaultStore.load_note(idx)
