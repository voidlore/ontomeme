extends SceneTree
## Ontomeme MCP server over stdio (editor builds / development):
##   godot --headless --no-header --path . -s res://mcp/stdio_server.gd -- --vault=<dir>
## The vault can also come from the ONTOMEME_VAULT environment variable.
##
## stdout carries protocol bytes only; logs go to stderr. `--no-header` is
## required (otherwise the engine banner lands on stdout) and `--quiet` must
## NOT be used (it silences print(), which writes the replies).
## Official release export templates ignore `-s`, so a shipped build needs
## its own entry point that hosts mcp/stdio_transport.gd (see mcp/README.md).

const McpProtocol = preload("res://mcp/protocol.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")
const StdioTransport = preload("res://mcp/stdio_transport.gd")


func _init() -> void:
	var vault: String = ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--vault="):
			vault = a.substr(8)
	if vault == "":
		vault = OS.get_environment("ONTOMEME_VAULT")
	# Keep the VaultStore autoload from opening (and scanning, and printing
	# about) the startup vault: it only opens one when none is set.
	VaultStore.vault_path = vault if vault != "" else "-"
	if vault == "":
		printerr("[ontomeme-mcp] no vault: pass -- --vault=<dir> or set ONTOMEME_VAULT")
		quit(2)
		return
	var tools: RefCounted = VaultTools.new(vault)
	if not DirAccess.dir_exists_absolute(tools.vault):
		printerr("[ontomeme-mcp] vault folder does not exist: ", tools.vault)
		quit(2)
		return
	var proto: RefCounted = McpProtocol.new(tools)
	proto.server_version = str(ProjectSettings.get_setting("application/config/version", "0.1.0"))
	Engine.max_fps = 60   # the loop only polls a queue; don't spin a core
	var transport: Node = StdioTransport.new()
	transport.protocol = proto
	get_root().add_child.call_deferred(transport)
	printerr("[ontomeme-mcp] serving vault ", tools.vault)
