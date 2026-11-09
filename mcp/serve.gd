extends RefCounted
## Starts the Ontomeme MCP server over stdio on a SceneTree. Both entry points
## call it: the app's boot scene (`ontomeme --headless -- --mcp-stdio`, how a
## shipped build serves, since release templates ignore -s) and the
## development script (`-s res://mcp/stdio_server.gd`).
##   const McpServe = preload("res://mcp/serve.gd")
##   McpServe.start(get_tree(), OS.get_cmdline_user_args())
##
## stdout carries protocol bytes only: every log here goes to stderr.

const McpProtocol = preload("res://mcp/protocol.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")
const StdioTransport = preload("res://mcp/stdio_transport.gd")

const LOG: String = "[ontomeme-mcp] "
## Exit code when there is no vault to serve.
const NO_VAULT: int = 2
## The transport only polls a queue between messages: don't spin a core
## (an idle server measured 0.2% of one).
const MAX_FPS: int = 60


## Serve the vault the arguments (or the environment) name. Returns 0 while
## serving; otherwise logs why, asks `tree` to quit with that code and
## returns it.
static func start(tree: SceneTree, user_args: PackedStringArray) -> int:
	# Keep the VaultStore autoload from opening (scanning, seeding, printing
	# about) a startup vault under -s: it opens one only when none is set.
	VaultStore.vault_path = "-"
	var pick: Dictionary = resolve_vault(user_args)
	if pick.has("error"):
		printerr(LOG, pick.error)
		tree.quit(NO_VAULT)
		return NO_VAULT
	var tools: RefCounted = VaultTools.new(pick.path)
	VaultStore.vault_path = tools.vault
	tools.confirm_writes = VaultTools.confirm_writes_setting(user_args, OS.get_environment(VaultTools.CONFIRM_ENV))
	var proto: RefCounted = McpProtocol.new(tools)
	proto.server_version = str(ProjectSettings.get_setting("application/config/version", "0.1.0"))
	proto.instructions += " This server serves the Ontomeme vault at %s." % tools.vault.trim_suffix("/")
	proto.client_initialized.connect(func(requested: String, negotiated: String, info: Dictionary, caps: Dictionary) -> void:
		printerr(LOG, client_line(requested, negotiated, info, caps)))
	Engine.max_fps = MAX_FPS
	if DisplayServer.get_name() != "headless":
		printerr(LOG, "tip: add --headless before -- so no window opens; serving anyway")
	var transport: Node = StdioTransport.new()
	transport.protocol = proto
	tree.root.add_child.call_deferred(transport)
	printerr(LOG, "serving vault ", tools.vault.trim_suffix("/"), " (", pick.from, ")")
	printerr(LOG, "confirmations ", "on (elicitation, when the client supports it)" if tools.confirm_writes else "off")
	return 0


## The stderr line for a client's `initialize`: the protocol version it asked
## for, the one answered, its clientInfo (as JSON, icons left out) and the
## names of its capabilities. Client strings are escaped and cut short.
static func client_line(requested: String, negotiated: String, info: Dictionary, caps: Dictionary) -> String:
	var line: String = "client requested protocol %s, answered %s" % [_clip(requested.c_escape(), 40), negotiated]
	if negotiated != requested:
		line += " (the requested one isn't supported)"
	var shown: Dictionary = info.duplicate()
	shown.erase("icons")
	line += "; clientInfo " + _clip(JSON.stringify(shown, "", false), 300)
	var names: Array = caps.keys().map(func(k: Variant) -> String: return _clip(str(k).c_escape(), 40))
	names.sort()
	return line + "; capabilities: " + (", ".join(names) if not names.is_empty() else "none")


static func _clip(text: String, n: int) -> String:
	return text if text.length() <= n else text.left(n) + "…"


## The vault to serve: --vault=<dir>, else ONTOMEME_VAULT, else the vault the
## app last used (VaultRegistry only reads user://vaults.json), else
## ~/Documents/Ontomeme, and only if that folder exists. Never creates or
## seeds a vault. {"path", "from"} or {"error"}.
static func resolve_vault(user_args: PackedStringArray) -> Dictionary:
	for a in user_args:
		if a.begins_with("--vault="):
			return _existing(a.substr(8), "--vault")
	var env: String = OS.get_environment("ONTOMEME_VAULT")
	if env != "":
		return _existing(env, "ONTOMEME_VAULT")
	var last: String = VaultRegistry.startup_vault()
	if DirAccess.dir_exists_absolute(last):
		return {"path": last, "from": _startup_source(last)}
	return {"error": "no vault: pass -- --vault=<dir>, set ONTOMEME_VAULT, or open Ontomeme once so it has a notes folder (%s does not exist)" % last.trim_suffix("/")}


static func _existing(path: String, from: String) -> Dictionary:
	var full: String = ProjectSettings.globalize_path(path)
	if path == "" or not DirAccess.dir_exists_absolute(full):
		return {"error": "vault folder does not exist: %s (from %s)" % [full, from]}
	return {"path": full, "from": from}


static func _startup_source(path: String) -> String:
	if path == VaultRegistry.normalize(VaultRegistry.default_vault()):
		return "the default vault"
	if path == VaultRegistry.normalize(VaultRegistry.legacy_vault()):
		return "the notes folder of an older Ontomeme"
	return "the vault the app last used"
