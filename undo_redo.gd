class_name UndoRedoEngine
extends Node

## UndoRedoEngine — the app's history of note text: Ctrl+Z outside the
## editor and the palette's Undo, Ctrl+Y / Ctrl+Shift+Z and Redo.
##
## note.gd pushes a step before it saves a user's edit to a note: the text
## as last saved, and the text being saved. undo() writes the newest step's
## earlier text back into its note and the note's file; redo() takes it
## forward again. A step applies only while its note still holds the text
## the step left there: text that came from outside the app (an outside
## edit the watcher reloaded, a save that met one and became a conflict
## copy) is never undone over.
##
## A step holds the note object it was taken of, never its path
## or title: renaming or moving the note keeps the object (take_over_path),
## so the snapshot follows it, and a snapshot applies only while its note is
## in VaultStore.note_list. It never lands on another note with the same
## title, on a new note at a path its note left, or in another vault (note.gd
## also clears the history when it switches vaults). Inside the editor
## Ctrl+Z is the TextEdit's own undo, never this one.
##
## Usage:
##     UndoRedoEngine.push_snapshot(note, new_text)   # before saving `new_text` to `note`
##     var note := UndoRedoEngine.undo()    # the note it changed, or null
##     var again := UndoRedoEngine.redo()

## Maximum undo history depth (configurable, default 50).
static var max_depth: int = 50

## Steps, newest last: {note, raw_text, expect, at}. `note` is the
## ContentLayer itself (held, so ResourceLoader's cache hands the same object
## back on a rescan); `raw_text` is the text the step puts back, `expect` the
## text the note must hold for that; `at` (from tick()) orders them against
## note.gd's other undoable action, a deleted note.
static var _undo_stack: Array[Dictionary] = []
static var _redo_stack: Array[Dictionary] = []
static var _clock: int = 0

## What the save_note() of the last undo() or redo() returned: OK, or the
## error that left the text only in memory (VaultStore.last_save_error says why).
static var last_save_result: Error = OK


## A new stamp, later than every snapshot so far. note.gd stamps a deleted
## note with it, so Ctrl+Z can tell whether the delete or an edit came last.
static func tick() -> int:
	_clock += 1
	return _clock


## Remember `note`'s text now, before `new_text` (by default the same text:
## a title or tag change) is saved to it. A new change clears the redo
## history.
static func push_snapshot(note: ContentLayer, new_text: Variant = null) -> void:
	if note == null:
		return
	_push(_undo_stack, note, note.raw_text, note.raw_text if new_text == null else str(new_text))
	_redo_stack.clear()


## Undo one step: the newest one that applies (see _applies) puts its text
## back into the note and saves it (VaultStore.save_note; the result is in
## last_save_result), and the text it replaces goes onto the redo history.
## Returns that note, or null when nothing is left to undo.
static func undo() -> ContentLayer:
	return _step(_undo_stack, _redo_stack)


## Redo one step: undo() in the other direction.
static func redo() -> ContentLayer:
	return _step(_redo_stack, _undo_stack)


## The stamp (see tick()) of the snapshot the next undo() would apply, or -1.
static func next_undo_at() -> int:
	for i in range(_undo_stack.size() - 1, -1, -1):
		var s: Dictionary = _undo_stack[i]
		if _applies(s):
			return int(s.at)
	return -1


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

static func _push(stack: Array[Dictionary], note: ContentLayer, text: String, expect: String) -> void:
	stack.append({"note": note, "raw_text": text, "expect": expect, "at": tick()})
	while stack.size() > max_depth:
		stack.pop_front()


## Pop steps off `from` until one applies; the ones popped on the way are
## dropped (so one step always changes something, and never over text from
## outside). The step's text goes into the note and its file, and the text
## it replaces onto `to`, expecting the step's text.
static func _step(from: Array[Dictionary], to: Array[Dictionary]) -> ContentLayer:
	while not from.is_empty():
		var s: Dictionary = from.pop_back()
		if not _applies(s):
			continue
		var note: ContentLayer = _find(s)
		_push(to, note, note.raw_text, s.raw_text)
		note.raw_text = s.raw_text
		last_save_result = VaultStore.save_note(note)
		return note
	return null


## True when step `s` has its note (see _find), the note still holds the
## text the step left there (not an outside edit, nor a later change that
## isn't undone yet), and the step would change it.
static func _applies(s: Dictionary) -> bool:
	var note: ContentLayer = _find(s)
	return note != null and note.raw_text == s.expect and s.raw_text != s.expect


## The note snapshot `s` was taken of, while it is in the open vault's
## note_list (wherever its file moved); null when it was deleted, moved out
## of the vault's sight, or belongs to another vault.
static func _find(s: Dictionary) -> ContentLayer:
	var note: ContentLayer = s.note
	return note if VaultStore.note_list.has(note) else null
