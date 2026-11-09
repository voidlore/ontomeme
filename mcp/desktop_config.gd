extends RefCounted
## The Claude Desktop config entry that starts this Ontomeme install as an MCP
## server, and the dialog the palette's "Connect Claude Desktop…" opens with
## it (note.gd). The JSON is built with JSON.stringify, so the backslashes of
## a Windows path come out escaped, the step people get wrong by hand.
## Nothing here writes Claude's config file: the user pastes the entry.
##   const DesktopConfig = preload("res://mcp/desktop_config.gd")
##   DesktopConfig.snippet("C:\\Apps\\Ontomeme\\Ontomeme.exe", "Windows")
##   DesktopConfig.open_dialog(parent, VaultStore.vault_path)

const SERVER_NAME: String = "ontomeme"
## Engine flags that give the server a log of its own. Godot copies all a
## process prints into its log file, and the server prints every reply
## (notes' text included): without them that is user://logs/godot.log, the
## app's own log a bug report asks for, and each start pushed the app's log
## out of it (Godot keeps 5). A --log-file is replaced each start.
const LOG_ARGS: Array[String] = ["--log-file", "user://logs/mcp.log"]
const DIALOG_NAME: String = "ConnectClaudeDialog"
## Wide enough for the steps; long paths wrap instead of widening the
## dialog past the 820 px minimum window.
const CONTENT_WIDTH: float = 600.0


## {"mcpServers": {"ontomeme": …}} as JSON for the app at `exe_path` on
## `os_name` (OS.get_name(): "macOS", "Windows", "Linux"…), laid out like the
## README's snippets (args on one line), LOG_ARGS included. `vault` adds
## --vault=<vault>; `project` adds --path <project> before "--", which a
## source checkout run with the editor binary needs; `lead` goes first, before
## the engine's flags (launcher()). Every string goes through JSON.stringify.
static func snippet(exe_path: String, os_name: String, vault: String = "", project: String = "",
		lead: Array[String] = []) -> String:
	var e: Dictionary = entry(exe_path, os_name, vault, project, lead)
	var args: PackedStringArray = []
	for a in e.args:
		args.append(JSON.stringify(a))
	return "{\n  \"mcpServers\": {\n    %s: {\n      \"command\": %s,\n      \"args\": [%s]\n    }\n  }\n}" % [
			JSON.stringify(SERVER_NAME), JSON.stringify(e.command), ", ".join(args)]


## The "ontomeme" entry: {"command", "args"}.
static func entry(exe_path: String, os_name: String, vault: String = "", project: String = "",
		lead: Array[String] = []) -> Dictionary:
	var args: Array[String] = lead.duplicate()
	args.append("--headless")
	args.append_array(LOG_ARGS)
	if project != "":
		args.append_array(["--path", native_path(project, os_name)])
	args.append_array(["--", "--mcp-stdio"])
	if vault != "":
		args.append("--vault=" + native_path(vault, os_name))
	return {"command": native_path(exe_path, os_name), "args": args}


## The snippet for this running app: what starts it (launcher()), and on an
## editor build (the godot binary running this checkout) the project's --path.
static func for_this_app(vault: String) -> String:
	var project: String = ProjectSettings.globalize_path("res://") if OS.has_feature("editor") else ""
	var run: Array[String] = launcher(OS.get_executable_path(), OS.get_environment("APPIMAGE"))
	return snippet(run[0], OS.get_name(), vault, project, run.slice(1))


## What starts this install, as [command, args that go first]: its own
## executable, except in a Linux AppImage. There the executable sits in the
## AppImage's temporary mount (/tmp/.mount_*) or extraction folder
## (/tmp/appimage_extracted_*), gone or replaced once the app quits, so the
## command is the .AppImage file itself: `appimage`, the APPIMAGE variable
## its runtime sets, which hands the args on to the app. Started with
## --appimage-extract-and-run (no FUSE: README.md's Linux steps), it needs
## that again, as the first arg: the runtime only reads the first "--" arg.
static func launcher(exe_path: String, appimage: String) -> Array[String]:
	if appimage == "":
		return [exe_path]
	if exe_path.contains("/appimage_extracted_"):
		return [appimage, "--appimage-extract-and-run"]
	return [appimage]


## Godot hands out "/" paths everywhere; Windows users and Claude's own docs
## write "\". A trailing separator is dropped (but not from a root).
static func native_path(path: String, os_name: String) -> String:
	var p: String = path
	if p.length() > 1 and (p.ends_with("/") or p.ends_with("\\")) and not p.ends_with(":/") and not p.ends_with(":\\"):
		p = p.left(-1)
	return p.replace("/", "\\") if os_name == "Windows" else p


## Where Claude Desktop keeps its config file on `os_name`.
static func config_path_hint(os_name: String) -> String:
	match os_name:
		"macOS":
			return "~/Library/Application Support/Claude/claude_desktop_config.json"
		"Windows":
			return "%APPDATA%\\Claude\\claude_desktop_config.json"
	return "your MCP client's config file (Claude Desktop is made for Mac and Windows; other clients that read this format take the same entry)"


## What to do with the snippet, in the user's words.
static func steps(os_name: String, vault: String) -> String:
	var name: String = vault.trim_suffix("/").get_file()
	var intro: String = "Claude can work with the notes in \"%s\" once Claude Desktop knows how to start Ontomeme.\n\n" % name
	if not (os_name in ["macOS", "Windows"]):
		return intro + "Paste the entry below into " + config_path_hint(os_name) + ". If it already lists servers under \"mcpServers\", add the \"ontomeme\" part next to them."
	return intro + "1. In Claude Desktop, open Settings > Developer > Edit Config. This opens " + config_path_hint(os_name) + ".\n" + \
			"2. Paste the entry below. If the file already lists servers under \"mcpServers\", add the \"ontomeme\" part next to them.\n" + \
			"3. Quit Claude Desktop completely and start it again."


## Build the dialog for `vault` (steps, the snippet, Copy and Close), add it
## to `parent` and show it. It frees itself when closed.
static func open_dialog(parent: Node, vault: String) -> AcceptDialog:
	var dlg: AcceptDialog = make_dialog(OS.get_name(), vault, for_this_app(vault))
	parent.add_child(dlg)
	dlg.popup_centered()
	return dlg


static func make_dialog(os_name: String, vault: String, text: String) -> AcceptDialog:
	var dlg := AcceptDialog.new()
	dlg.name = DIALOG_NAME
	dlg.title = "Connect Claude Desktop"
	dlg.ok_button_text = "Close"
	var box := VBoxContainer.new()
	box.name = "Content"
	box.custom_minimum_size = Vector2(CONTENT_WIDTH, 0)
	box.add_theme_constant_override("separation", 12)
	var info := Label.new()
	info.name = "Steps"
	info.text = steps(os_name, vault)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size = Vector2(CONTENT_WIDTH, 0)   # a wrapping label needs its width up front, or the dialog grows tall
	box.add_child(info)
	var code := CodeEdit.new()
	code.name = "Snippet"
	code.text = text
	code.editable = false
	code.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	code.custom_minimum_size = Vector2(CONTENT_WIDTH, 250)
	box.add_child(code)
	dlg.add_child(box)
	var copy: Button = dlg.add_button("Copy", false, "copy")
	copy.name = "CopyButton"
	dlg.custom_action.connect(func(action: StringName) -> void:
		if action == &"copy":
			DisplayServer.clipboard_set(text)
			copy.text = "Copied")
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	return dlg
