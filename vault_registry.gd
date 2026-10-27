class_name VaultRegistry
extends RefCounted
## Known vaults, VS Code "recent projects" style. A vault is any folder on
## disk; its notes are the .tres files inside it (subfolders included).
## The list lives in user://vaults.json: {"recent": [paths], "last": path}.

const FILE: String = "user://vaults.json"
const MAX_RECENT: int = 12


static func _read() -> Dictionary:
	var d: Dictionary = {"recent": [], "last": ""}
	if FileAccess.file_exists(FILE):
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(FILE))
		if v is Dictionary:
			if (v as Dictionary).get("recent") is Array:
				d.recent = v.recent
			d.last = str(v.get("last", ""))
	return d


static func _write(d: Dictionary) -> void:
	var f := FileAccess.open(FILE, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d, "\t"))


static func normalize(path: String) -> String:
	var p: String = ProjectSettings.globalize_path(path).simplify_path()
	return p.trim_suffix("/") + "/"


## Recent vaults that still exist, most recent first.
static func recent() -> Array[String]:
	var out: Array[String] = []
	for p in _read().recent:
		if DirAccess.dir_exists_absolute(str(p)):
			out.append(normalize(str(p)))
	return out


static func remember(path: String) -> void:
	var p: String = normalize(path)
	var d: Dictionary = _read()
	var list: Array = d.recent.filter(func(x): return normalize(str(x)) != p)
	list.push_front(p)
	d.recent = list.slice(0, MAX_RECENT)
	d.last = p
	_write(d)


static func forget(path: String) -> void:
	var p: String = normalize(path)
	var d: Dictionary = _read()
	d.recent = d.recent.filter(func(x): return normalize(str(x)) != p)
	if normalize(d.last) == p:
		d.last = ""
	_write(d)


static func display_name(path: String) -> String:
	return normalize(path).trim_suffix("/").get_file()


## Where notes lived before vaults existed (the app was called Senedril).
static func legacy_vault() -> String:
	return OS.get_data_dir().path_join("godot/app_userdata/Senedril/senedril-vault")


static func default_vault() -> String:
	return OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).path_join("Ontomeme")


## Which vault to open at launch: --vault=<path>, else the last one used,
## else the pre-vaults notes folder, else ~/Documents/Ontomeme.
static func startup_vault() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--vault="):
			return normalize(a.substr(8))
	var last: String = _read().last
	if last != "" and DirAccess.dir_exists_absolute(last):
		return normalize(last)
	if DirAccess.dir_exists_absolute(legacy_vault()):
		return normalize(legacy_vault())
	return normalize(default_vault())
