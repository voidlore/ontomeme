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
## and optionally, for read-only MCP resources (advertised and routed only
## when it has all three):
##   list_resources(cursor: String) -> Dictionary   # {resources, nextCursor?}
##   resource_templates() -> Array                  # MCP ResourceTemplates
##   read_resource(uri: String) -> Dictionary       # {contents}
## The resource methods report a failure as {error: {code, message}};
## RESOURCE_ERRORS maps the code to the JSON-RPC error sent back.
## Two more optional hooks:
##   attach_protocol(proto)                       # called once, from _init
##   instructions_for(client_capabilities) -> String   # appended to instructions
##
## Requests from the server to the client (MCP elicitation, for one): a tool
## (or anyone holding the protocol) calls send_request(); the message goes out
## through the `outgoing` signal, and the client's response, fed to handle()
## like any message, reaches the callback. A tool that has to wait for one
## returns {"pending": true} from call_tool, keeps current_call_id, and later
## answers with complete(id, result), which also goes out through `outgoing`.
## handle() and handle_line() still return every immediate reply; `outgoing`
## carries only what is sent later or on the server's own initiative. The
## transport calls tick(now_ms) so an unanswered request times out.

## 2025-11-25 adds no server MUST this server misses: its changes are HTTP
## auth, optional icons and tasks, client features (elicitation, sampling),
## SHOULDs on tool names, and JSON Schema 2020-12 as the default dialect,
## which our schemas already are. 2026-07-28 is not listed: it drops
## initialize and requires server/discover and a version on every request.
const LATEST_VERSION: String = "2025-11-25"
## Versions this server can speak; the client's is accepted when it is listed.
const SUPPORTED_VERSIONS: Array[String] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

const PARSE_ERROR: int = -32700
const INVALID_REQUEST: int = -32600
const METHOD_NOT_FOUND: int = -32601
const INVALID_PARAMS: int = -32602
const INTERNAL_ERROR: int = -32603
## Not in the MCP spec; the same code LSP uses for "request before initialize".
const NOT_INITIALIZED: int = -32002
## What a send_request callback gets when the client never answers (the code
## the MCP SDKs use for a request timeout).
const REQUEST_TIMEOUT: int = -32001
## The MCP spec's code for resources/read of a resource that doesn't exist.
## The same number as NOT_INITIALIZED; the message tells them apart.
const RESOURCE_NOT_FOUND: int = -32002
## A resource failure's code (from the tools object) → its JSON-RPC error.
## Any other code is an INTERNAL_ERROR.
const RESOURCE_ERRORS: Dictionary = {
	"invalid_uri": INVALID_PARAMS,
	"invalid_arguments": INVALID_PARAMS,
	"not_found": RESOURCE_NOT_FOUND,
}

## Emitted for every message the server sends on its own: a request to the
## client, a deferred tools/call result, a notifications/cancelled. The
## transport writes each one out, in emission order.
signal outgoing(message: Dictionary)

var tools: Object
var server_name: String = "ontomeme"
var server_version: String = "0.1.0"
var instructions: String = "Tools for reading and editing the notes in an Ontomeme vault. " + \
		"Notes are addressed by their path inside the vault. read_note returns a hash; " + \
		"pass it to update_note or delete_note, which refuse if the note changed since. " + \
		"Notes use Ontomeme's own markup: call get_note_guide before writing quizzes, flashcards or 3D scenes (```3d blocks)."

## Set once the client's `initialize` request has been answered.
var initialized: bool = false
## Set when the client sends `notifications/initialized`.
var client_ready: bool = false
var protocol_version: String = ""
var client_info: Dictionary = {}
var client_capabilities: Dictionary = {}
## How long a request to the client waits for its response (a person may be
## answering a prompt) before its callback gets a REQUEST_TIMEOUT error.
var request_timeout_ms: int = 120000
## The id of the tools/call whose call_tool is running, else null. A tool that
## answers later keeps it for complete().
var current_call_id: Variant = null
## The protocolVersion the client's `initialize` asked for; it differs from
## `protocol_version` when this server doesn't speak it.
var requested_version: String = ""

## Finds what to_json has to rewrite (compiled on first use).
static var _loose_json: RegEx = null

var _sent_requests: int = 0
## Requests sent to the client and not answered yet:
## id → {on_reply: Callable, deadline: int (ms), for_call: the tools/call id it was sent for, or null}.
var _requests: Dictionary = {}
## tools/call requests still owed a response (running, or deferred) → true.
var _calls: Dictionary = {}

## Emitted as `initialize` is answered, with the version the client asked
## for, the one answered, and the client's clientInfo and capabilities as
## sent. This class does no I/O: a host logs it (mcp/serve.gd, to stderr).
signal client_initialized(requested: String, negotiated: String, info: Dictionary, capabilities: Dictionary)


func _init(p_tools: Object = null) -> void:
	tools = p_tools
	if tools != null and tools.has_method("attach_protocol"):
		tools.attach_protocol(self)


## Parse one JSON text, handle it, and return the reply as JSON ("" for none).
func handle_line(text: String) -> String:
	if text.strip_edges() == "":
		return ""
	var json := JSON.new()
	if json.parse(text) != OK:
		return to_json(error_response(null, PARSE_ERROR, "Parse error: " + json.get_error_message()))
	var reply: Variant = handle(json.data)
	return "" if reply == null else to_json(reply)


## JSON.stringify, made valid JSON. Godot writes U+000B as "\v" and leaves
## the other control characters it has no short escape for (U+0001 to
## U+0007, U+000E to U+001F, ESC among them) as raw bytes. JSON has neither,
## and strict parsers (Python's json, JSON.parse in the MCP SDKs) reject the
## whole message: one title with a vertical tab pasted from PowerPoint lost
## the whole list_notes page. Those become \u00XX escapes.
static func to_json(value: Variant) -> String:
	var text: String = JSON.stringify(value)
	if _loose_json == null:
		_loose_json = RegEx.create_from_string("[\\x01-\\x1f]|\\\\v")
	if _loose_json.search(text) == null:
		return text
	for c in range(1, 0x20):
		text = text.replace(char(c), "\\u%04x" % c)
	# Every backslash JSON.stringify writes starts an escape, and a literal
	# one is written "\\": split those pairs off first, so a backslash
	# followed by the letter v stays as it is.
	var parts: PackedStringArray = text.split("\\\\")
	for i in parts.size():
		parts[i] = parts[i].replace("\\v", "\\u000b")
	return "\\\\".join(parts)


## Handle one parsed JSON-RPC message. Returns the response Dictionary, or
## null when nothing must be sent (notifications, and responses from the client).
func handle(message: Variant) -> Variant:
	if message is Array:
		# JSON-RPC batching was removed from MCP in 2025-06-18.
		return error_response(null, INVALID_REQUEST, "Batch requests are not supported")
	if not (message is Dictionary):
		return error_response(null, INVALID_REQUEST, "Message must be a JSON object")
	var msg: Dictionary = message
	if not msg.has("method") and (msg.has("result") or msg.has("error")):
		# A response to a request we sent: route it, never answer it.
		_on_response(msg)
		return null
	var has_id: bool = msg.has("id")
	var id: Variant = _norm_id(msg.get("id")) if has_id else null
	if has_id and not (id is String or id is int):
		return error_response(null, INVALID_REQUEST, "id must be a string or an integer")
	if str(msg.get("jsonrpc", "")) != "2.0":
		return error_response(id, INVALID_REQUEST, "jsonrpc must be \"2.0\"") if has_id else null
	if not msg.has("method"):
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


func _on_notification(method: String, params: Dictionary) -> void:
	match method:
		"notifications/initialized":
			client_ready = true
		"notifications/cancelled":
			_cancel_call(_norm_id(params.get("requestId")))
		_:
			pass


func _request(id: Variant, method: String, params: Dictionary) -> Variant:
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
		"resources/list", "resources/templates/list", "resources/read":
			if has_resources():
				return _resources_request(id, method, params)
	return error_response(id, METHOD_NOT_FOUND, "Method not found: " + method)


## True when the tools object also serves notes as resources.
func has_resources() -> bool:
	return tools != null and tools.has_method("list_resources") and tools.has_method("resource_templates") and tools.has_method("read_resource")


func _initialize(id: Variant, params: Dictionary) -> Dictionary:
	var requested: Variant = params.get("protocolVersion")
	if not (requested is String):
		return error_response(id, INVALID_PARAMS, "initialize needs a protocolVersion string")
	# Accept the client's version if we speak it; otherwise offer our latest
	# and let the client decide whether to disconnect.
	requested_version = requested
	protocol_version = requested if requested in SUPPORTED_VERSIONS else LATEST_VERSION
	client_info = params.get("clientInfo", {}) if params.get("clientInfo") is Dictionary else {}
	client_capabilities = params.get("capabilities", {}) if params.get("capabilities") is Dictionary else {}
	initialized = true
	var capabilities: Dictionary = {"tools": {"listChanged": false}}
	if has_resources():
		capabilities["resources"] = {"listChanged": false}
	var result: Dictionary = {
		"protocolVersion": protocol_version,
		"capabilities": capabilities,
		"serverInfo": {"name": server_name, "version": server_version},
	}
	var text: String = instructions
	if tools != null and tools.has_method("instructions_for"):
		text = (text + " " + str(tools.instructions_for(client_capabilities))).strip_edges()
	if text != "":
		result["instructions"] = text
	client_initialized.emit(requested_version, protocol_version, client_info, client_capabilities)
	return result_response(id, result)


## tools/call → its response, or null when the tool returned {"pending": true}
## (it answers later through complete()) or the client cancelled the call
## while it ran.
func _tools_call(id: Variant, params: Dictionary) -> Variant:
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
	_calls[id] = true
	var outer: Variant = current_call_id
	current_call_id = id
	var result: Variant = tools.call_tool(name, args)
	current_call_id = outer
	if is_pending(result):
		# Stays owed until complete() or a cancel (either may already have come).
		return null
	if not _calls.has(id):
		return null   # cancelled while it ran: no response
	_calls.erase(id)
	if not (result is Dictionary):
		return error_response(id, INTERNAL_ERROR, "Tool returned no result: " + str(name))
	return result_response(id, result)


func _resources_request(id: Variant, method: String, params: Dictionary) -> Dictionary:
	if method == "resources/templates/list":
		return result_response(id, {"resourceTemplates": tools.resource_templates()})
	var r: Variant
	var uri: Variant = null
	if method == "resources/list":
		var cursor: Variant = params.get("cursor", "")
		if cursor == null:
			cursor = ""
		if not (cursor is String):
			return error_response(id, INVALID_PARAMS, "cursor must be a string")
		r = tools.list_resources(cursor)
	else:
		uri = params.get("uri")
		if not (uri is String) or uri == "":
			return error_response(id, INVALID_PARAMS, "resources/read needs a uri string")
		r = tools.read_resource(uri)
	if not (r is Dictionary):
		return error_response(id, INTERNAL_ERROR, "No result for " + method)
	if r.has("error"):
		var e: Dictionary = r.error if r.error is Dictionary else {}
		return error_response(id, RESOURCE_ERRORS.get(e.get("code"), INTERNAL_ERROR), str(e.get("message", "Resource error")),
				{"uri": uri} if uri != null else null)
	return result_response(id, r)


# ---------------------------------------------------------------------------
# Requests to the client, and tools/call results sent later
# ---------------------------------------------------------------------------

## Send `method` to the client as a request (through `outgoing`). `on_reply`
## is called once with the client's response message ({id, result} or
## {id, error: {code, message}}), or with a REQUEST_TIMEOUT error after
## request_timeout_ms. Ids are "s-1", "s-2"... (strings) so they never collide
## with the client's. Sent while a tools/call runs, the request belongs to
## that call: cancelling the call drops it (the client is told, and
## `on_reply` is never called). Returns the id.
func send_request(method: String, params: Dictionary, on_reply: Callable) -> String:
	_sent_requests += 1
	var id: String = "s-%d" % _sent_requests
	# Recorded before the message goes out: a client may answer at once.
	_requests[id] = {"on_reply": on_reply, "deadline": Time.get_ticks_msec() + request_timeout_ms, "for_call": current_call_id}
	outgoing.emit({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
	return id


## Send the result of a tools/call whose tool returned {"pending": true}.
## False, and nothing sent, when that call is not owed a response (answered
## already, or cancelled by the client).
func complete(request_id: Variant, result: Dictionary) -> bool:
	if not _calls.has(request_id):
		return false
	_calls.erase(request_id)
	outgoing.emit(result_response(request_id, result))
	return true


## True when a tool's result says it will answer later through complete().
static func is_pending(result: Variant) -> bool:
	return result is Dictionary and result.get("pending") is bool and result.pending


## True while the tools/call `request_id` is owed a response.
func is_call_pending(request_id: Variant) -> bool:
	return _calls.has(request_id)


## True while a request this server sent is waiting for the client.
func is_request_pending(id: String) -> bool:
	return _requests.has(id)


## Time out every request still unanswered at `now_ms` (Time.get_ticks_msec()):
## the client is told it is cancelled and its callback gets a REQUEST_TIMEOUT
## error. The transport calls this every frame.
func tick(now_ms: int) -> void:
	for id: String in _requests.keys():
		if not _requests.has(id) or int(_requests[id].deadline) > now_ms:
			continue   # answered by an earlier callback, or still in time
		var pending: Dictionary = _requests[id]
		_requests.erase(id)
		_send_cancelled(id, "timed out")
		_reply_to(pending, error_response(id, REQUEST_TIMEOUT, "The client did not answer within %.0f s" % (request_timeout_ms / 1000.0)))


## A response from the client: to its request's callback, once. A response to
## an id this server is not waiting on (unknown, answered, timed out,
## cancelled) is dropped.
func _on_response(msg: Dictionary) -> void:
	var id: Variant = msg.get("id")
	if not (id is String) or not _requests.has(id):
		return
	var pending: Dictionary = _requests[id]
	_requests.erase(id)
	var reply: Dictionary = {"jsonrpc": "2.0", "id": id}
	if msg.has("error"):
		var e: Variant = msg.error
		reply["error"] = e if e is Dictionary else {"code": INTERNAL_ERROR, "message": str(e)}
	else:
		reply["result"] = msg.get("result")
	_reply_to(pending, reply)


static func _reply_to(pending: Dictionary, reply: Dictionary) -> void:
	var on_reply: Callable = pending.on_reply
	if on_reply.is_valid():
		on_reply.call(reply)


## notifications/cancelled for a tools/call: no response will be sent, and
## the requests it sent are withdrawn.
func _cancel_call(call_id: Variant) -> void:
	if not (call_id is String or call_id is int) or not _calls.has(call_id):
		return
	_calls.erase(call_id)
	for id: String in _requests.keys():
		var owner: Variant = _requests[id].for_call
		if typeof(owner) == typeof(call_id) and owner == call_id:
			_requests.erase(id)
			_send_cancelled(id, "the tools/call it was for was cancelled")


func _send_cancelled(id: String, reason: String) -> void:
	outgoing.emit({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": id, "reason": reason}})


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
