extends RefCounted
## MCP protocol core: JSON-RPC 2.0 plus the MCP lifecycle, with no I/O.
##
## Transport-agnostic on purpose: the stdio server, an in-app server or a
## test all feed it parsed messages and send back whatever it returns.
##   var proto := McpProtocol.new(VaultTools.new(vault_dir))
##   var reply: Variant = proto.handle(message)   # Dictionary, or null for notifications
##   var line: String = proto.handle_line(text)   # "" when there is nothing to send
##
## `tools` is any object with
##   list_tools() -> Array            # MCP Tool definitions
##   has_tool(name: String) -> bool
##   call_tool(name: String, args: Dictionary) -> Dictionary   # a CallToolResult

const LATEST_VERSION: String = "2025-06-18"
## Versions this server can speak; the client's is accepted when it is listed.
const SUPPORTED_VERSIONS: Array[String] = ["2025-06-18", "2025-03-26", "2024-11-05"]

const PARSE_ERROR: int = -32700
const INVALID_REQUEST: int = -32600
const METHOD_NOT_FOUND: int = -32601
const INVALID_PARAMS: int = -32602
const INTERNAL_ERROR: int = -32603
## Not in the MCP spec; the same code LSP uses for "request before initialize".
const NOT_INITIALIZED: int = -32002

var tools: Object
var server_name: String = "ontomeme"
var server_version: String = "0.1.0"
var instructions: String = "Tools for reading and editing the notes in an Ontomeme vault. " + \
		"Notes are addressed by their path inside the vault. read_note returns a hash; " + \
		"pass it to update_note or delete_note, which refuse if the note changed since."

## Set once the client's `initialize` request has been answered.
var initialized: bool = false
## Set when the client sends `notifications/initialized`.
var client_ready: bool = false
var protocol_version: String = ""
var client_info: Dictionary = {}
var client_capabilities: Dictionary = {}


func _init(p_tools: Object = null) -> void:
	tools = p_tools


## Parse one JSON text, handle it, and return the reply as JSON ("" for none).
func handle_line(text: String) -> String:
	if text.strip_edges() == "":
		return ""
	var json := JSON.new()
	if json.parse(text) != OK:
		return JSON.stringify(error_response(null, PARSE_ERROR, "Parse error: " + json.get_error_message()))
	var reply: Variant = handle(json.data)
	return "" if reply == null else JSON.stringify(reply)


## Handle one parsed JSON-RPC message. Returns the response Dictionary, or
## null when nothing must be sent (notifications, and responses from the client).
func handle(message: Variant) -> Variant:
	if message is Array:
		# JSON-RPC batching was removed from MCP in 2025-06-18.
		return error_response(null, INVALID_REQUEST, "Batch requests are not supported")
	if not (message is Dictionary):
		return error_response(null, INVALID_REQUEST, "Message must be a JSON object")
	var msg: Dictionary = message
	var has_id: bool = msg.has("id")
	var id: Variant = _norm_id(msg.get("id")) if has_id else null
	if has_id and not (id is String or id is int):
		return error_response(null, INVALID_REQUEST, "id must be a string or an integer")
	if str(msg.get("jsonrpc", "")) != "2.0":
		return error_response(id, INVALID_REQUEST, "jsonrpc must be \"2.0\"") if has_id else null
	if not msg.has("method"):
		# A response to a request we sent (we send none yet): nothing to answer.
		if msg.has("result") or msg.has("error"):
			return null
		return error_response(id, INVALID_REQUEST, "Missing method")
	if not (msg.method is String):
		return error_response(id, INVALID_REQUEST, "method must be a string")
	var method: String = msg.method
	var params: Variant = msg.get("params", {})
	if params == null:
		params = {}
	if not (params is Dictionary):
		return error_response(id, INVALID_PARAMS, "params must be an object") if has_id else null
	if not has_id:
		_on_notification(method, params)
		return null
	return _request(id, method, params)


func _on_notification(method: String, _params: Dictionary) -> void:
	match method:
		"notifications/initialized":
			client_ready = true
		_:
			pass  # notifications/cancelled etc.: requests finish synchronously, nothing to cancel


func _request(id: Variant, method: String, params: Dictionary) -> Dictionary:
	match method:
		"initialize":
			return _initialize(id, params)
		"ping":
			return result_response(id, {})
	if not initialized:
		return error_response(id, NOT_INITIALIZED, "Server not initialized: send initialize first")
	match method:
		"tools/list":
			return result_response(id, {"tools": tools.list_tools() if tools != null else []})
		"tools/call":
			return _tools_call(id, params)
	return error_response(id, METHOD_NOT_FOUND, "Method not found: " + method)


func _initialize(id: Variant, params: Dictionary) -> Dictionary:
	var requested: Variant = params.get("protocolVersion")
	if not (requested is String):
		return error_response(id, INVALID_PARAMS, "initialize needs a protocolVersion string")
	# Accept the client's version if we speak it; otherwise offer our latest
	# and let the client decide whether to disconnect.
	protocol_version = requested if requested in SUPPORTED_VERSIONS else LATEST_VERSION
	client_info = params.get("clientInfo", {}) if params.get("clientInfo") is Dictionary else {}
	client_capabilities = params.get("capabilities", {}) if params.get("capabilities") is Dictionary else {}
	initialized = true
	var result: Dictionary = {
		"protocolVersion": protocol_version,
		"capabilities": {"tools": {"listChanged": false}},
		"serverInfo": {"name": server_name, "version": server_version},
	}
	if instructions != "":
		result["instructions"] = instructions
	return result_response(id, result)


func _tools_call(id: Variant, params: Dictionary) -> Dictionary:
	var name: Variant = params.get("name")
	if not (name is String) or name == "":
		return error_response(id, INVALID_PARAMS, "tools/call needs a tool name")
	if tools == null or not tools.has_tool(name):
		return error_response(id, INVALID_PARAMS, "Unknown tool: " + str(name))
	var args: Variant = params.get("arguments", {})
	if args == null:
		args = {}
	if not (args is Dictionary):
		return error_response(id, INVALID_PARAMS, "arguments must be an object")
	var result: Variant = tools.call_tool(name, args)
	if not (result is Dictionary):
		return error_response(id, INTERNAL_ERROR, "Tool returned no result: " + str(name))
	return result_response(id, result)


static func result_response(id: Variant, result: Dictionary) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result}


static func error_response(id: Variant, code: int, message: String, data: Variant = null) -> Dictionary:
	var err: Dictionary = {"code": code, "message": message}
	if data != null:
		err["data"] = data
	return {"jsonrpc": "2.0", "id": id, "error": err}


## Godot's JSON parser turns every number into a float; echo integer ids
## back as integers ("1", not "1.0").
static func _norm_id(id: Variant) -> Variant:
	if id is float and is_finite(id) and id == floorf(id) and absf(id) < 9.0e15:
		return int(id)
	return id
