extends Node
## The app's main scene: decides what this launch is.
##   ontomeme                                          the note window (note.tscn)
##   ontomeme --headless -- --mcp-stdio [--vault=<dir>] the MCP server on stdin/stdout
## Release export templates ignore -s, so this switch is how a shipped build
## serves MCP. Scenes and scripts are load()ed, not preloaded, so MCP mode
## never loads note.gd and the window never loads the server.

const MCP_STDIO: String = "--mcp-stdio"


## True when this launch should serve MCP over stdio instead of opening the
## window. Also accepted before the `--`, where Godot keeps unknown arguments.
static func mcp_stdio_requested() -> bool:
	return MCP_STDIO in OS.get_cmdline_user_args() or MCP_STDIO in OS.get_cmdline_args()


func _ready() -> void:
	if mcp_stdio_requested():
		var args: PackedStringArray = OS.get_cmdline_user_args() + OS.get_cmdline_args()
		load("res://mcp/serve.gd").start(get_tree(), args)
	else:
		get_tree().change_scene_to_file.call_deferred("res://note.tscn")
