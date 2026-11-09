extends SceneTree
## Ontomeme MCP server over stdio, development entry (editor builds only):
##   godot --headless --path . -s res://mcp/stdio_server.gd -- --vault=<dir>
## Shipped builds ignore -s; they serve with `-- --mcp-stdio` through the
## app's boot scene (boot.gd). Both go through mcp/serve.gd, which picks the
## vault (--vault=, ONTOMEME_VAULT, else the vault the app last used).
## update_note and delete_note ask the user first (MCP elicitation, when the
## client supports it) unless -- --confirm-writes=off or ONTOMEME_MCP_CONFIRM=0.
##
## stdout carries protocol bytes only; logs go to stderr. The project turns
## the engine banner off (application/run/print_header), and `--quiet` must
## NOT be used (it silences print(), which writes the replies).

const McpServe = preload("res://mcp/serve.gd")


func _init() -> void:
	McpServe.start(self, OS.get_cmdline_user_args())
