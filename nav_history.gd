extends RefCounted
## Back / Forward through the notes the user opened, browser style.
## Entries are note resource_paths (a note's file), so they survive the
## vault reloading its ContentLayer objects.
##   const NavHistory = preload("res://nav_history.gd")
##   var nav := NavHistory.new()
##   nav.push(note.resource_path)          # on every open
##   var path: String = nav.back(exists)   # "" when there is nowhere to go

var current: String = ""
var _back: Array[String] = []      # oldest first; the newest is popped first
var _forward: Array[String] = []


## The user opened `path`. Opening the note already shown is not a step;
## opening any other one drops the forward stack, as a browser does.
func push(path: String) -> void:
	if path == "" or path == current:
		return
	if current != "":
		_back.append(current)
	current = path
	_forward.clear()


## Step back to the newest earlier note that still exists and return its
## path ("" when there is none; the history is then unchanged apart from
## dropping the notes that are gone). `exists` takes a path and returns a
## bool; by default a path exists while its file does.
func back(exists: Callable = Callable()) -> String:
	return _step(_back, _forward, exists)


## The mirror of back(): return to a note left by stepping back.
func forward(exists: Callable = Callable()) -> String:
	return _step(_forward, _back, exists)


func can_go_back() -> bool:
	return not _back.is_empty()


func can_go_forward() -> bool:
	return not _forward.is_empty()


## A new vault: nothing before or after the note now open.
func clear() -> void:
	current = ""
	_back.clear()
	_forward.clear()


## A note or a folder moved on disk: `old` -> `new` in every entry, for the
## note's own path and for each path inside a moved folder (`old` without a
## trailing slash).
func remap(old: String, new: String) -> void:
	current = _remapped(current, old, new)
	for stack in [_back, _forward]:
		for i in range(stack.size()):
			stack[i] = _remapped(stack[i], old, new)


static func _remapped(path: String, old: String, new: String) -> String:
	if path == old:
		return new
	if path.begins_with(old + "/"):
		return new + path.substr(old.length())
	return path


## Pop `from` until a path that exists; the note we leave goes onto `to`.
func _step(from: Array[String], to: Array[String], exists: Callable) -> String:
	while not from.is_empty():
		var path: String = from.pop_back()
		if path == current or not _exists(path, exists):
			continue
		if current != "":
			to.append(current)
		current = path
		return path
	return ""


static func _exists(path: String, exists: Callable) -> bool:
	return bool(exists.call(path)) if exists.is_valid() else FileAccess.file_exists(path)
