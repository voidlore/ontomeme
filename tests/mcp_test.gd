extends SceneTree
## MCP server core: protocol lifecycle, every vault tool, hash-conflict
## refusals, trash on delete, and an end-to-end stdio run in a subprocess.
##   godot --headless --path . -s res://tests/mcp_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const McpProtocol = preload("res://mcp/protocol.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")
const StdioTransport = preload("res://mcp/stdio_transport.gd")
## Every tool the server offers, sorted.
const TOOL_NAMES: Array = ["create_note", "delete_note", "get_journey", "get_note_guide", "get_progress", "list_notes", "list_tags", "move_note", "read_note", "search_notes", "update_note"]
const MARKUP_MD: String = "res://skills/ontomeme-notes/references/markup.md"

## A small course that trips every lint check: scripts/lint_notes.gd's report
## on it, captured before the checks moved into note_lint.gd (LINT_CLI_EXPECTED).
const LINT_FIXTURE: Dictionary = {
	"Broken_One.md": """---
title: Broken One
objective: Defined Here | something
---
Intro with [[Missing Link]] and [[Second Note|alias]] and [[ second note ]].

```3d nebula
cube: red
```

```3d
preset: quiz
a: before any question
q: Only one answer?
a*: yes
learn: Nowhere Note
q: Two right?
a*: one
a*: two
q: Five answers?
a: 1
a: 2
a*: 3
a: 4
a: 5
review: Second Note
q: No right one?
a: x
a: y
objective: Defined Here
```

```3d quiz
next: Not A Note
objective: Unknown Objective
q: ok?
a*: yes
a: no
```

````
```3d
cube red
```
````

```3d flashcards
q: front one
a: back one
q: front two
q: front three
a: back three
```

```3d cards
caption: no cards here
```

```3d shapes
caption: empty
```

```3d
cube: notacolour, at 1 0 0, size 2
sphere: blue, label Ball, spin
model: missing.glb
model: here.glb
cube red
```

```3d quiz
```
""",
	"Sub/Second_Note.md": """# Second

Link back to [[Broken One]] and a [[Ghost]].

```3d
preset: galaxy
next: Broken One
```

```python
print("unclosed
""",
	"_skipped.md": """[[Not Linted]]
""",
	"models/here.glb": "glTF",
}
## Its stdout after the banner: %s = the known presets, then the vault path.
const LINT_CLI_EXPECTED: Array = [
		"WARN   Broken One:2  link to a note that doesn't exist: [[Missing Link]]",
		"ERROR  Broken One:4  unknown preset 'nebula' (known: %s)",
		"ERROR  Broken One:8  'a:' before the first q:",
		"ERROR  Broken One:8  question 'Only one answer?' needs at least 2 answers (it will be dropped)",
		"ERROR  Broken One:8  learn: points at a missing note 'Nowhere Note'",
		"ERROR  Broken One:8  question 'Two right?' needs exactly one a*: (has 2)",
		"WARN   Broken One:8  question 'Five answers?' has 5 answers; 3–4 fit the board best",
		"ERROR  Broken One:8  question 'No right one?' needs exactly one a*: (has 0)",
		"ERROR  Broken One:30  next: points at a missing note 'Not A Note'",
		"WARN   Broken One:30  objective: 'Unknown Objective' isn't in this vault's journey yet (scores won't log until it exists)",
		"ERROR  Broken One:44  3 flashcard q: lines but only 2 have an a: right after",
		"ERROR  Broken One:52  flashcards block has no complete q:/a: cards",
		"WARN   Broken One:56  shapes block with no objects (add lines like  cube: red)",
		"ERROR  Broken One:60  model file not found: %s/models/missing.glb (put it in the vault's models/ folder)",
		"ERROR  Broken One:60  'cube red' is missing its colon — scene lines are  cube: …  (only quiz answers drop it)",
		"WARN   Broken One:60  'notacolour' isn't a colour the app knows (use a name like red or #ff8800)",
		"ERROR  Broken One:68  quiz block has no questions",
		"WARN   Second Note:3  link to a note that doesn't exist: [[Ghost]]",
		"ERROR  Second Note:10  ``` fence is never closed (the rest of the note renders as code)",
		"2 notes checked: 13 errors, 6 warnings",
]

var fails: int = 0
var _next_id: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func req(proto: RefCounted, method: String, params: Variant = null) -> Variant:
	_next_id += 1
	var m: Dictionary = {"jsonrpc": "2.0", "id": _next_id, "method": method}
	if params != null:
		m["params"] = params
	return proto.handle(m)


## tools/call → the CallToolResult (or {} if the call failed at protocol level).
func call_tool(proto: RefCounted, name: String, args: Dictionary) -> Dictionary:
	var r: Variant = req(proto, "tools/call", {"name": name, "arguments": args})
	return r.result if r is Dictionary and r.has("result") else {}


func data(result: Dictionary) -> Dictionary:
	return result.get("structuredContent", {})


func err_code(result: Dictionary) -> String:
	return str(data(result).get("error", {}).get("code", "")) if result.get("isError", false) else ""


func _init() -> void:
	ProgressStore.file_override = "user://test_progress_mcp.json"   # never touch real progress
	JourneyStore.file_override = "user://test_journey_mcp.json"     # never touch the real journey
	var V: String = TestVault.open("mcp")
	test_protocol(V)
	test_server_requests()
	test_tools(V)
	test_elicitation(V)
	test_text_notes(V)
	test_resources(V)
	test_move_note(V)
	test_bom_fields(V)
	test_export_folder(V)
	test_search_nulls(V)
	test_pagination()
	test_lint_on_write(V)
	test_lint_cli()
	test_note_guide(V)
	test_app_compat(V)
	test_control_chars()
	await test_stdio_e2e()
	await test_stdio_elicitation()
	await test_stdio_control_chars()
	await test_short_write()
	await test_short_write_small()
	for f in [ProgressStore.file_override, JourneyStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	TestVault.remove_tree(V)
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)


# ── Protocol ────────────────────────────────────────────────────────────────

func test_protocol(V: String) -> void:
	var p: RefCounted = McpProtocol.new(VaultTools.new(V))
	var r: Variant = req(p, "tools/list")
	check(r.error.code == McpProtocol.NOT_INITIALIZED, "tools/list before initialize is refused")
	r = req(p, "ping")
	check(r.has("result") and r.result.is_empty(), "ping works before initialize")

	r = req(p, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}})
	check(r.result.protocolVersion == "2025-06-18", "initialize: 2025-06-18 accepted")
	check(r.result.capabilities.has("tools") and r.result.serverInfo.name == "ontomeme", "initialize: tools capability + serverInfo")
	check(str(r.result.get("instructions", "")).contains("get_note_guide"), "initialize: the instructions point to get_note_guide")
	check(r.result.capabilities.get("resources") == {"listChanged": false}, "initialize: advertises resources (listChanged false)")
	check(r.id is int and r.id == _next_id, "integer id echoed as an integer")
	check(JSON.stringify(r).contains("\"id\":%d," % _next_id), "integer id serialised without .0")
	var older: Variant = McpProtocol.new(null).handle({"jsonrpc": "2.0", "id": "a", "method": "initialize", "params": {"protocolVersion": "2025-03-26"}})
	check(older.id == "a" and older.result.protocolVersion == "2025-03-26", "initialize: a supported older version is accepted")
	var unknown: Variant = McpProtocol.new(null).handle({"jsonrpc": "2.0", "id": 9, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}})
	check(unknown.result.protocolVersion == McpProtocol.LATEST_VERSION, "initialize: unknown version → server offers its latest")
	var newest: Variant = McpProtocol.new(null).handle({"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}})
	check(newest.result.protocolVersion == "2025-11-25" and McpProtocol.LATEST_VERSION == "2025-11-25", "initialize: 2025-11-25 (what Claude Code 2.1.319 asks for) is accepted, echoed back, and the latest")
	for v in ["2025-06-18", "2025-03-26", "2024-11-05"]:
		check(McpProtocol.new(null).handle({"jsonrpc": "2.0", "id": 3, "method": "initialize", "params": {"protocolVersion": v}}).result.protocolVersion == v, "initialize: older %s still accepted" % v)
	var stateless: Variant = McpProtocol.new(null).handle({"jsonrpc": "2.0", "id": 4, "method": "initialize", "params": {"protocolVersion": "2026-07-28"}})
	check(stateless.result.protocolVersion == McpProtocol.LATEST_VERSION, "initialize: 2026-07-28 (stateless, needs server/discover) is not claimed")
	var probe: Variant = McpProtocol.new(null).handle({"jsonrpc": "2.0", "id": 5, "method": "server/discover", "params": {}})
	check(probe.has("error") and not (int(probe.error.code) <= -32020 and int(probe.error.code) >= -32099), "server/discover gets a legacy error, so a dual-era client falls back to initialize (%d)" % probe.error.code)
	check(McpProtocol.new(null).handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}).error.code == McpProtocol.INVALID_PARAMS, "initialize without protocolVersion → -32602")
	# A tools object without the resource methods: no capability, no routes.
	var bare: RefCounted = McpProtocol.new(null)
	var bare_init: Variant = req(bare, "initialize", {"protocolVersion": "2025-06-18"})
	check(not bare_init.result.capabilities.has("resources") and req(bare, "resources/list").error.code == McpProtocol.METHOD_NOT_FOUND, "no resource methods → no resources capability, resources/list → -32601")

	check(p.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}) == null and p.client_ready, "notifications/initialized: no reply, client marked ready")
	check(p.handle({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 1}}) == null, "other notifications: no reply")
	check(p.handle({"jsonrpc": "2.0", "id": 99, "result": {}}) == null, "a response from the client is not answered")

	r = req(p, "tools/list")
	var names: Array = r.result.tools.map(func(t): return t.name)
	names.sort()
	check(names == TOOL_NAMES, "tools/list: the %d tools %s" % [TOOL_NAMES.size(), names])
	var by_name: Dictionary = {}
	for t in r.result.tools:
		by_name[t.name] = t
		check(t.inputSchema.type == "object", "tool %s has an object inputSchema" % t.name)
	check(by_name.update_note.annotations.destructiveHint == true and by_name.delete_note.annotations.destructiveHint == true, "update_note + delete_note carry destructiveHint")
	check(by_name.read_note.annotations.readOnlyHint == true and by_name.create_note.annotations.destructiveHint == false, "read tools are readOnly; create is not destructive")
	check(by_name.update_note.inputSchema.required.has("hash") and by_name.delete_note.inputSchema.required.has("hash"), "update/delete require a hash in their schema")

	check(req(p, "nope/nothing").error.code == McpProtocol.METHOD_NOT_FOUND, "unknown method → -32601")
	check(req(p, "tools/call", {"name": "no_such_tool", "arguments": {}}).error.code == McpProtocol.INVALID_PARAMS, "unknown tool → -32602")
	check(req(p, "tools/call", {"name": "read_note", "arguments": "x"}).error.code == McpProtocol.INVALID_PARAMS, "non-object arguments → -32602")
	check(p.handle({"jsonrpc": "1.0", "id": 5, "method": "ping"}).error.code == McpProtocol.INVALID_REQUEST, "wrong jsonrpc version → -32600")
	check(p.handle({"jsonrpc": "2.0", "id": null, "method": "ping"}).error.code == McpProtocol.INVALID_REQUEST, "null id → -32600")
	check(p.handle([{"jsonrpc": "2.0", "id": 1, "method": "ping"}]).error.code == McpProtocol.INVALID_REQUEST, "batch → -32600")
	var pe: Dictionary = JSON.parse_string(p.handle_line("{not json"))
	check(pe.error.code == McpProtocol.PARSE_ERROR and pe.id == null, "bad JSON → -32700 with id null")
	check(p.handle_line("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}") == "", "handle_line: notification → empty string")
	var tool_err: Dictionary = call_tool(p, "read_note", {"path": "../../etc/passwd.tres"})
	check(tool_err.get("isError") == true and err_code(tool_err) == "invalid_path", "tool failure is an isError result, not a protocol error")


# ── Requests from the server to the client ──────────────────────────────────

## A tools object whose "ask" tool asks the client (a "test/ask" request) and
## answers its tools/call later with whatever came back, the way an
## elicitation does; "now" answers at once.
class AskTool extends RefCounted:
	var proto_ref: WeakRef
	## Every response the "ask" callbacks got, in order.
	var replies: Array = []

	func attach_protocol(p: Object) -> void:
		proto_ref = weakref(p)

	func list_tools() -> Array:
		return [{"name": "ask", "inputSchema": {"type": "object"}}, {"name": "now", "inputSchema": {"type": "object"}}]

	func has_tool(name: String) -> bool:
		return name in ["ask", "now"]

	func call_tool(name: String, args: Dictionary) -> Dictionary:
		if name == "now":
			return {"content": [{"type": "text", "text": "now"}], "isError": false}
		var p: Object = proto_ref.get_ref()
		var call_id: Variant = p.current_call_id
		p.send_request("test/ask", {"q": args.get("q", "")}, func(reply: Dictionary) -> void:
			replies.append(reply)
			var q: Object = proto_ref.get_ref()
			q.complete(call_id, {"content": [{"type": "text", "text": JSON.stringify(reply)}], "structuredContent": reply, "isError": reply.has("error")}))
		return {"pending": true}


## The messages in `sent` whose id is `id` (typed: 41 is not "41").
func _sent_with_id(sent: Array, id: Variant) -> Array:
	return sent.filter(func(m: Dictionary) -> bool: return typeof(m.get("id")) == typeof(id) and m.get("id") == id)


func _client_reply(p: RefCounted, id: String, body: Dictionary) -> String:
	var m: Dictionary = {"jsonrpc": "2.0", "id": id}
	m.merge(body)
	return p.handle_line(JSON.stringify(m))


func _ask_line(id: int, q: String) -> String:
	return JSON.stringify({"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": "ask", "arguments": {"q": q}}})


func test_server_requests() -> void:
	var tool := AskTool.new()
	var p: RefCounted = McpProtocol.new(tool)
	var sent: Array = []
	p.outgoing.connect(func(m: Dictionary) -> void: sent.append(m))
	req(p, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}})
	check(tool.proto_ref != null and tool.proto_ref.get_ref() == p, "server requests: attach_protocol hands the tools object its protocol")

	# A request out; the client's result back → the tools/call response.
	check(p.handle_line(_ask_line(41, "colour?")) == "", "server requests: a deferred tools/call has no immediate reply")
	var out: Dictionary = sent[0] if sent.size() == 1 else {}
	check(out.get("jsonrpc") == "2.0" and out.get("method") == "test/ask" and out.get("params") == {"q": "colour?"}, "server requests: outgoing carries the request (%s)" % [out])
	check(out.get("id") is String and out.get("id") == "s-1", "server requests: its id is a string (s-1), apart from the client's ids")
	check(p.is_call_pending(41) and p.is_request_pending("s-1"), "server requests: the call and the request are both waiting")
	check(_client_reply(p, "s-1", {"result": {"answer": "blue"}}) == "", "server requests: the client's response gets no reply of its own")
	var done: Array = _sent_with_id(sent, 41)
	check(done.size() == 1 and done[0].result.structuredContent.get("result") == {"answer": "blue"} and done[0].result.isError == false,
			"server requests: feeding the client's result yields the tools/call response with the original id (%s)" % [done])
	check(JSON.stringify(done[0] if done.size() > 0 else {}).contains("\"id\":41,"), "server requests: the deferred response's integer id is serialised without .0")
	check(not p.is_call_pending(41) and not p.is_request_pending("s-1") and tool.replies.size() == 1, "server requests: answered once, nothing left waiting")

	# An error response from the client reaches the callback.
	sent.clear()
	p.handle_line(_ask_line(42, "error?"))
	var id2: String = str(sent[0].get("id")) if sent.size() > 0 else ""
	check(id2 == "s-2", "server requests: the next request gets the next id (%s)" % id2)
	_client_reply(p, id2, {"error": {"code": McpProtocol.METHOD_NOT_FOUND, "message": "no such method"}})
	var last: Dictionary = tool.replies.back() if tool.replies.size() == 2 else {}
	check(last.get("id") == id2 and last.has("error") and last.error.code == McpProtocol.METHOD_NOT_FOUND and last.error.message == "no such method",
			"server requests: an error response from the client reaches the callback (%s)" % [last])
	done = _sent_with_id(sent, 42)
	check(done.size() == 1 and done[0].result.isError == true, "server requests: and the call is answered with it")

	# No answer → a timeout error, and the client is told the request is off.
	sent.clear()
	p.handle_line(_ask_line(43, "anyone?"))
	var id3: String = str(sent[0].get("id")) if sent.size() > 0 else ""
	p.tick(Time.get_ticks_msec())
	check(tool.replies.size() == 2 and p.is_request_pending(id3), "server requests: still waiting before the timeout")
	p.tick(Time.get_ticks_msec() + p.request_timeout_ms + 1)
	last = tool.replies.back() if tool.replies.size() == 3 else {}
	check(last.has("error") and last.error.code == McpProtocol.REQUEST_TIMEOUT and last.get("id") == id3, "server requests: a timeout reaches the callback as a REQUEST_TIMEOUT error (%s)" % [last])
	check(p.request_timeout_ms == 120000, "server requests: the timeout defaults to 120 s")
	var told: Array = sent.filter(func(m: Dictionary) -> bool: return m.get("method") == "notifications/cancelled" and m.params.get("requestId") == id3)
	check(told.size() == 1 and _sent_with_id(sent, 43).size() == 1, "server requests: the timed-out request is cancelled at the client, and the call answered")
	_client_reply(p, id3, {"result": {"answer": "too late"}})
	check(tool.replies.size() == 3 and _sent_with_id(sent, 43).size() == 1, "server requests: a response after the timeout is ignored")

	# Responses this server is not waiting for are ignored.
	sent.clear()
	check(p.handle({"jsonrpc": "2.0", "id": "s-999", "result": {}}) == null and p.handle({"jsonrpc": "2.0", "id": 12345, "result": {}}) == null,
			"server requests: a response to an unknown id gets no reply")
	check(p.handle({"jsonrpc": "2.0", "id": null, "error": {"code": McpProtocol.PARSE_ERROR, "message": "bad"}}) == null, "server requests: an error response with a null id gets no reply")
	check(sent.is_empty() and tool.replies.size() == 3, "server requests: and reaches no callback")

	# A cancelled call: no response, and its request is withdrawn.
	p.handle_line(_ask_line(44, "cancel me"))
	var id4: String = str(sent[0].get("id")) if sent.size() > 0 else ""
	check(p.handle({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 44, "reason": "stop"}}) == null, "server requests: notifications/cancelled gets no reply")
	check(not p.is_call_pending(44) and not p.is_request_pending(id4), "server requests: the cancelled call and its request are dropped")
	told = sent.filter(func(m: Dictionary) -> bool: return m.get("method") == "notifications/cancelled" and m.params.get("requestId") == id4)
	check(told.size() == 1, "server requests: the client is told the call's request is cancelled")
	_client_reply(p, id4, {"result": {"answer": "late"}})
	check(tool.replies.size() == 3, "server requests: the cancelled call's request never reaches its callback")
	check(p.complete(44, {"content": [], "isError": false}) == false, "server requests: complete() on a cancelled call is refused")
	check(_sent_with_id(sent, 44).is_empty(), "server requests: a cancelled call produces no response")
	check(p.complete(41, {"content": [], "isError": false}) == false and _sent_with_id(sent, 41).is_empty(), "server requests: a call is answered once only")

	# A client that answers inside `outgoing`, before send_request returns.
	var quick_tool := AskTool.new()
	var quick: RefCounted = McpProtocol.new(quick_tool)
	var quick_sent: Array = []
	# The handler holds `quick`, so it is disconnected below (or both leak).
	var answer_at_once: Callable = func(m: Dictionary) -> void:
		quick_sent.append(m)
		if m.get("method") == "test/ask":
			quick.handle({"jsonrpc": "2.0", "id": m.id, "result": {"answer": "at once"}})
	quick.outgoing.connect(answer_at_once)
	req(quick, "initialize", {"protocolVersion": "2025-06-18"})
	check(quick.handle_line(_ask_line(7, "now?")) == "", "server requests: a call answered during send_request has no immediate reply")
	var quick_done: Array = _sent_with_id(quick_sent, 7)
	check(quick_done.size() == 1 and quick_done[0].result.structuredContent.result == {"answer": "at once"} and not quick.is_call_pending(7),
			"server requests: and is answered once through outgoing (%s)" % [quick_done])
	quick.outgoing.disconnect(answer_at_once)

	# Tools that answer at once are unchanged.
	sent.clear()
	var now: Variant = p.handle({"jsonrpc": "2.0", "id": 45, "method": "tools/call", "params": {"name": "now", "arguments": {}}})
	check(now is Dictionary and now.get("id") == 45 and now.result.content[0].text == "now" and sent.is_empty() and not p.is_call_pending(45),
			"server requests: an immediate tool still answers from handle(), nothing on outgoing")

	# The stdio transport writes what the protocol emits.
	var t: Node = StdioTransport.new()
	t.protocol = p
	check(p.outgoing.is_connected(t._send), "server requests: the stdio transport listens to outgoing")
	t.protocol = null
	check(not p.outgoing.is_connected(t._send), "server requests: and lets go of a protocol it no longer serves")
	t.free()


# ── Confirmations: elicitation before update_note / delete_note ─────────────

## The schema every confirmation asks for: one required boolean.
func _confirm_schema(label: String) -> Dictionary:
	return {"type": "object", "properties": {"confirm": {"type": "boolean", "title": label}}, "required": ["confirm"]}


## A protocol on `tools` for a client declaring `caps`; what the server sends
## on its own lands in `sent`.
func _confirm_session(tools: RefCounted, caps: Dictionary, sent: Array) -> RefCounted:
	var p: RefCounted = McpProtocol.new(tools)
	p.outgoing.connect(func(m: Dictionary) -> void: sent.append(m))
	req(p, "initialize", {"protocolVersion": "2025-06-18", "capabilities": caps})
	return p


func _asks(sent: Array) -> Array:
	return sent.filter(func(m: Dictionary) -> bool: return m.get("method") == "elicitation/create")


## tools/call `name` with `args` → {reply: handle()'s immediate reply, id,
## ask: the elicitation it sent ({} if none)}.
func _start_call(p: RefCounted, sent: Array, name: String, args: Dictionary) -> Dictionary:
	var before: int = _asks(sent).size()
	var reply: Variant = req(p, "tools/call", {"name": name, "arguments": args})
	var asks: Array = _asks(sent)
	return {"reply": reply, "id": _next_id, "ask": asks.back() if asks.size() > before else {}}


## Answer `call`'s elicitation with `body` ({result: …} or {error: …}) → the
## tools/call result it settles ({} if none came).
func _answer(p: RefCounted, sent: Array, call: Dictionary, body: Dictionary) -> Dictionary:
	_client_reply(p, str(call.ask.get("id", "")), body)
	var done: Array = _sent_with_id(sent, call.id)
	return done[0].result if done.size() == 1 else {}


func _accept(confirm: Variant = true) -> Dictionary:
	return {"result": {"action": "accept", "content": {"confirm": confirm}}}


func _new_tres(tools: RefCounted, title: String, body: String, tags: Array = []) -> Dictionary:
	return data(tools.call_tool("create_note", {"title": title, "markdown": body, "tags": tags, "folder": "Elicit"}))


func _edit_outside(path: String, body: String) -> void:
	var n: ContentLayer = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	n.raw_text = body
	ResourceSaver.save(n, path)


func test_elicitation(V: String) -> void:
	var tools: RefCounted = VaultTools.new(V)
	var sent: Array = []
	var p: RefCounted = _confirm_session(tools, {"elicitation": {}}, sent)
	var init: Dictionary = req(p, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {"elicitation": {}}}).result
	check(str(init.get("instructions", "")).contains("Confirmations are on: before update_note or delete_note"), "confirm: initialize states the mode (on, with elicitation)")

	# delete_note, accepted: the prompt, then the trash.
	var d: Dictionary = _new_tres(tools, "Elicit Delete", "to be trashed")
	var call: Dictionary = _start_call(p, sent, "delete_note", {"path": d.path, "hash": d.hash})
	check(call.reply == null, "confirm delete: no immediate reply while the user decides")
	check(call.ask.get("id") is String and call.ask.get("params", {}).get("message") == "Move \"Elicit Delete\" (Elicit/note_elicit_delete.tres) to the trash?",
			"confirm delete: elicitation/create names the note and its path (%s)" % [call.ask.get("params", {}).get("message")])
	check(call.ask.get("params", {}).get("requestedSchema") == _confirm_schema("Move to trash"), "confirm delete: asks for one required boolean, confirm (\"Move to trash\")")
	check(FileAccess.get_sha256(V + d.path) == d.hash, "confirm delete: the note is untouched while waiting")
	var r: Dictionary = _answer(p, sent, call, _accept())
	check(r.get("isError") == false and not FileAccess.file_exists(V + d.path) and FileAccess.file_exists(V + str(data(r).get("trashed_to", "?"))),
			"confirm delete: accept + confirm → moved to the trash (%s)" % [data(r)])

	# delete_note, not accepted: declined, the note stays.
	for answer in [["decline", {"result": {"action": "decline"}}], ["cancel", {"result": {"action": "cancel"}}], ["accept, confirm false", _accept(false)], ["accept, no content", {"result": {"action": "accept"}}]]:
		var k: Dictionary = _new_tres(tools, "Elicit Keep", "stays")
		call = _start_call(p, sent, "delete_note", {"path": k.path, "hash": k.hash})
		r = _answer(p, sent, call, answer[1])
		check(err_code(r) == "declined" and FileAccess.get_sha256(V + k.path) == k.hash, "confirm delete: %s → declined, the note untouched (%s)" % [answer[0], err_code(r)])
		tools.call_tool("delete_note", {"path": k.path, "hash": k.hash})   # outside a tools/call: no prompt

	# Edited between the prompt and the answer → conflict, nothing trashed.
	var c: Dictionary = _new_tres(tools, "Elicit Race", "before")
	call = _start_call(p, sent, "delete_note", {"path": c.path, "hash": c.hash})
	_edit_outside(V + c.path, "edited while the user decided")
	r = _answer(p, sent, call, _accept())
	check(err_code(r) == "conflict" and FileAccess.file_exists(V + c.path) and data(call_tool(p, "read_note", {"path": c.path})).markdown == "edited while the user decided",
			"confirm delete: a note edited before the answer → conflict, the edit kept (%s)" % err_code(r))
	var c_hash: String = FileAccess.get_sha256(V + c.path)

	# update_note: the prompt summarises the change.
	var u: Dictionary = _new_tres(tools, "Elicit Update", "line one\nline two\nline three\n", ["a", "b"])
	var edit: Dictionary = {"path": u.path, "hash": u.hash, "title": "Elicit Updated", "markdown": "line one\nline 2\nline three\nline four\n", "tags": ["b", "c"]}
	call = _start_call(p, sent, "update_note", edit)
	var msg: String = str(call.ask.get("params", {}).get("message", ""))
	var want: Array = ["Save this change to \"Elicit Update\" (Elicit/note_elicit_update.tres)?", "Title: \"Elicit Update\" → \"Elicit Updated\"",
			"Body: +2 / -1 lines", "- line two", "+ line 2", "+ line four", "Tags: +c, -a"]
	check(want.all(func(w: String) -> bool: return msg.split("\n").has(w)), "confirm update: the prompt has the title change, +N/-M lines, the changed lines and the tags:\n%s" % msg)
	check(call.ask.get("params", {}).get("requestedSchema") == _confirm_schema("Save the change"), "confirm update: asks for one required boolean, confirm")
	check(call.reply == null and FileAccess.get_sha256(V + u.path) == u.hash, "confirm update: no reply and no write while the user decides")
	r = _answer(p, sent, call, _accept())
	# The new title renames the file the way the app does (links-names).
	var moved: String = str(data(r).get("path", ""))
	check(moved == "Elicit/note_elicit_updated.tres" and data(r).get("renamed_from") == u.path and not FileAccess.file_exists(V + u.path),
			"confirm update: accept → the title change renames the file (%s)" % moved)
	u.path = moved
	var back: Dictionary = data(call_tool(p, "read_note", {"path": u.path}))
	check(r.get("isError") == false and back.title == "Elicit Updated" and back.markdown == edit.markdown and back.tags == ["b", "c"] and data(r).hash == back.hash,
			"confirm update: accept → written, with the new hash (%s)" % [data(r)])
	for answer in [["decline", {"result": {"action": "decline"}}], ["cancel", {"result": {"action": "cancel"}}], ["accept, confirm false", _accept(false)]]:
		call = _start_call(p, sent, "update_note", {"path": u.path, "hash": back.hash, "markdown": "NOT WANTED"})
		r = _answer(p, sent, call, answer[1])
		check(err_code(r) == "declined" and FileAccess.get_sha256(V + u.path) == back.hash, "confirm update: %s → declined, the note untouched (%s)" % [answer[0], err_code(r)])
	call = _start_call(p, sent, "update_note", {"path": u.path, "hash": back.hash, "markdown": "mine"})
	_edit_outside(V + u.path, "theirs")
	r = _answer(p, sent, call, _accept())
	check(err_code(r) == "conflict" and data(call_tool(p, "read_note", {"path": u.path})).markdown == "theirs", "confirm update: a note edited before the answer → conflict, the edit kept (%s)" % err_code(r))

	# A .txt note: its stem is the title; only the body changes.
	var t: Dictionary = data(tools.call_tool("create_note", {"title": "Elicit Plain", "markdown": "same\nold\n", "format": "text", "folder": "Elicit"}))
	call = _start_call(p, sent, "update_note", {"path": t.path, "hash": t.hash, "markdown": "same\nnew\n"})
	msg = str(call.ask.get("params", {}).get("message", ""))
	check(msg.begins_with("Save this change to \"note_elicit_plain\" (Elicit/note_elicit_plain.txt)?") and msg.contains("Body: +1 / -1 lines") and not msg.contains("Title:") and not msg.contains("Tags:"),
			"confirm update .txt: body lines only:\n%s" % msg)
	r = _answer(p, sent, call, _accept())
	check(r.get("isError") == false and FileAccess.get_file_as_string(V + t.path) == "same\nnew\n", "confirm update .txt: accept → written")

	# Refusals come at once: nobody is asked about a change that can't happen.
	var before: int = _asks(sent).size()
	check(err_code(call_tool(p, "update_note", {"path": u.path, "hash": u.hash, "markdown": "x"})) == "conflict", "confirm: a stale hash is refused at once")
	check(err_code(call_tool(p, "update_note", {"path": u.path, "hash": FileAccess.get_sha256(V + u.path), "title": " "})) == "invalid_arguments", "confirm: an empty title is refused at once")
	check(err_code(call_tool(p, "delete_note", {"path": "Elicit/none.tres", "hash": "abc"})) == "not_found", "confirm: a missing note is refused at once")
	check(_asks(sent).size() == before, "confirm: and none of them asks the user")

	# No answer: a client error or a timeout → not_confirmed, the note stays.
	call = _start_call(p, sent, "delete_note", {"path": c.path, "hash": c_hash})
	r = _answer(p, sent, call, {"error": {"code": McpProtocol.INTERNAL_ERROR, "message": "the prompt failed"}})
	check(err_code(r) == "not_confirmed" and FileAccess.get_sha256(V + c.path) == c_hash, "confirm: an error from the client → not_confirmed, the note untouched (%s)" % err_code(r))
	call = _start_call(p, sent, "delete_note", {"path": c.path, "hash": c_hash})
	p.tick(Time.get_ticks_msec() + p.request_timeout_ms + 1)
	var timed: Array = _sent_with_id(sent, call.id)
	check(timed.size() == 1 and err_code(timed[0].result) == "not_confirmed" and FileAccess.get_sha256(V + c.path) == c_hash, "confirm: no answer in time → not_confirmed, the note untouched")

	# The client cancels the call: no response, and a late accept writes nothing.
	call = _start_call(p, sent, "delete_note", {"path": c.path, "hash": c_hash})
	p.handle({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": call.id}})
	r = _answer(p, sent, call, _accept())
	check(r.is_empty() and FileAccess.get_sha256(V + c.path) == c_hash, "confirm: a cancelled call answers nothing and trashes nothing")

	# A client without elicitation: the old behaviour, nothing sent.
	var plain_sent: Array = []
	var plain: RefCounted = _confirm_session(tools, {}, plain_sent)
	var pinit: Dictionary = req(plain, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}}).result
	check(str(pinit.get("instructions", "")).contains("can't show Ontomeme's prompts"), "confirm: initialize states the mode (no elicitation)")
	var pd: Dictionary = _new_tres(tools, "Elicit Plain Client", "body")
	var pu: Dictionary = data(call_tool(plain, "update_note", {"path": pd.path, "hash": pd.hash, "markdown": "edited"}))
	var pdel: Dictionary = call_tool(plain, "delete_note", {"path": pd.path, "hash": pu.get("hash", "")})
	check(pu.get("hash", "") != "" and pdel.get("isError") == false and not FileAccess.file_exists(V + pd.path) and plain_sent.is_empty(),
			"confirm: a client without elicitation gets the old behaviour (immediate results, no outgoing request)")

	# The toggle off: an elicitation client is not asked.
	var off_tools: RefCounted = VaultTools.new(V)
	off_tools.confirm_writes = false
	var off_sent: Array = []
	var off: RefCounted = _confirm_session(off_tools, {"elicitation": {}}, off_sent)
	var oinit: Dictionary = req(off, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {"elicitation": {}}}).result
	check(str(oinit.get("instructions", "")).contains("Confirmations are off"), "confirm: initialize states the mode (off)")
	var od: Dictionary = _new_tres(off_tools, "Elicit Off", "body")
	var ou: Dictionary = data(call_tool(off, "update_note", {"path": od.path, "hash": od.hash, "markdown": "edited"}))
	var odel: Dictionary = call_tool(off, "delete_note", {"path": od.path, "hash": ou.get("hash", "")})
	check(ou.get("hash", "") != "" and odel.get("isError") == false and not FileAccess.file_exists(V + od.path) and off_sent.is_empty(),
			"confirm: with the toggle off nobody is asked")

	# The toggle: --confirm-writes= wins over ONTOMEME_MCP_CONFIRM; on by default.
	var cases: Array = [
		[[], "", true], [["--vault=/x"], "1", true], [["--confirm-writes=off"], "", false], [[], "0", false],
		[[], "off", false], [["--confirm-writes=OFF"], "", false], [["--confirm-writes=false"], "", false],
		[["--confirm-writes=on"], "0", true], [["--confirm-writes=maybe"], "", true], [["--confirm-writes=off", "--confirm-writes=on"], "", true],
	]
	for k in cases:
		check(VaultTools.confirm_writes_setting(PackedStringArray(k[0]), k[1]) == k[2], "confirm toggle: %s with ONTOMEME_MCP_CONFIRM=%s → %s" % [k[0], k[1], "on" if k[2] else "off"])

	# Line counting for the prompt.
	var lc: Dictionary = VaultTools.line_changes("a\nb\nc\nd\ne", "a\nB\nc\nd\nE")
	check(lc.added == 2 and lc.removed == 2 and Array(lc.shown) == ["- b", "- e", "+ B", "+ E"], "line_changes: edits in the middle and at the end (%s)" % [lc])
	lc = VaultTools.line_changes("x\ny\nz", "z\nx\ny")
	check(lc.added == 0 and lc.removed == 0, "line_changes: a moved line is neither added nor removed")
	lc = VaultTools.line_changes("", "1\n2\n3\n4\n5")
	check(lc.added == 5 and lc.removed == 0 and Array(lc.shown) == ["+ 1", "+ 2", "+ 3", "  (2 more added)"], "line_changes: from empty, the first lines and a count of the rest (%s)" % [lc])
	lc = VaultTools.line_changes("keep", "keep\n" + "w".repeat(300))
	check(lc.added == 1 and (lc.shown[0] as String).length() == 2 + VaultTools.PROMPT_LINE_CHARS and (lc.shown[0] as String).ends_with("…"), "line_changes: a long line is cut")
	TestVault.remove_tree(V + "Elicit")
	TestVault.remove_tree(V + ".trash/Elicit")


# ── Tools ───────────────────────────────────────────────────────────────────

func test_tools(V: String) -> void:
	var tools: RefCounted = VaultTools.new(V)
	var p: RefCounted = McpProtocol.new(tools)
	req(p, "initialize", {"protocolVersion": "2025-06-18"})

	# list_notes
	var lst: Dictionary = data(call_tool(p, "list_notes", {}))
	check(lst.count > 0 and lst.count == VaultStore.note_list.size(), "list_notes: every note the app sees (%d)" % lst.get("count", -1))
	check(lst.notes.all(func(n): return str(n.path).ends_with(".tres") and not str(n.path).begins_with("/")), "list_notes: vault-relative .tres paths")
	check(lst.notes.all(func(n): return n.format == "tres"), "list_notes: every entry is a .tres until a .txt is added")

	# create_note
	var c: Dictionary = call_tool(p, "create_note", {"title": "MCP Probe", "markdown": "# Probe\nalpha bravo ✓\n", "tags": ["#mcp", "probe"], "folder": "Agent/Inbox"})
	var cd: Dictionary = data(c)
	check(not c.isError and cd.path == "Agent/Inbox/note_mcp_probe.tres" and FileAccess.file_exists(V + cd.path), "create_note: writes note_<title>.tres in a new folder")
	check(cd.hash == FileAccess.get_sha256(V + cd.path) and cd.hash.length() == 64, "create_note: returns the SHA-256 of the file")
	var again: Dictionary = call_tool(p, "create_note", {"title": "MCP Probe", "markdown": "other", "folder": "Agent/Inbox"})
	check(err_code(again) == "exists" and FileAccess.get_sha256(V + cd.path) == cd.hash, "create_note: refuses when the file exists, file untouched")
	check(err_code(call_tool(p, "create_note", {"title": "  "})) == "invalid_arguments", "create_note: empty title refused")
	check(err_code(call_tool(p, "create_note", {"title": "X", "folder": ".ontomeme"})) == "invalid_path", "create_note: hidden folder refused")
	check(err_code(call_tool(p, "create_note", {"title": "X", "folder": "../outside"})) == "invalid_path", "create_note: folder outside the vault refused")
	check(DirAccess.get_files_at(V + ".ontomeme/tmp").size() == 0, "atomic write leaves no temp files")

	# read_note
	var rd: Dictionary = data(call_tool(p, "read_note", {"path": cd.path}))
	check(rd.title == "MCP Probe" and rd.markdown == "# Probe\nalpha bravo ✓\n" and rd.tags == ["mcp", "probe"], "read_note: title, markdown, tags (leading # stripped)")
	check(rd.hash == cd.hash and rd.folder == "Agent/Inbox", "read_note: same hash as create, folder")
	var raw: Dictionary = data(call_tool(p, "read_note", {"path": cd.path, "raw": true}))
	check(str(raw.get("raw", "")).begins_with("[gd_resource") and str(raw.raw).contains("ContentLayer"), "read_note raw: the .tres text")
	check(err_code(call_tool(p, "read_note", {"path": "nope/missing.tres"})) == "not_found", "read_note: missing → not_found")
	check(err_code(call_tool(p, "read_note", {"path": "/etc/passwd"})) == "invalid_path", "read_note: absolute path refused")
	check(err_code(call_tool(p, "read_note", {"path": ".trash/x.tres"})) == "invalid_path", "read_note: hidden folder refused")

	# update_note
	check(err_code(call_tool(p, "update_note", {"path": cd.path, "markdown": "x"})) == "invalid_arguments", "update_note: no hash → refused")
	var u: Dictionary = call_tool(p, "update_note", {"path": cd.path, "hash": rd.hash, "markdown": "charlie delta", "tags": ["mcp", "edited"]})
	var ud: Dictionary = data(u)
	check(not u.isError and ud.hash != rd.hash and ud.hash == FileAccess.get_sha256(V + cd.path), "update_note: writes, returns the new hash")
	var rd2: Dictionary = data(call_tool(p, "read_note", {"path": cd.path}))
	check(rd2.markdown == "charlie delta" and rd2.title == "MCP Probe" and rd2.tags == ["mcp", "edited"], "update_note: body + tags replaced, title kept")
	var stale: Dictionary = call_tool(p, "update_note", {"path": cd.path, "hash": rd.hash, "markdown": "LOST UPDATE"})
	check(err_code(stale) == "conflict" and data(stale).error.current_hash == ud.hash, "update_note: stale hash → conflict with the current hash")
	check(data(call_tool(p, "read_note", {"path": cd.path})).markdown == "charlie delta", "update_note: refused write left the file alone")

	# Someone else (the app, a sync tool) edits the file → our hash is stale.
	var outside: ContentLayer = ResourceLoader.load(V + cd.path, "", ResourceLoader.CACHE_MODE_IGNORE)
	outside.raw_text = "edited outside"
	ResourceSaver.save(outside, V + cd.path)
	check(err_code(call_tool(p, "update_note", {"path": cd.path, "hash": ud.hash, "markdown": "mine"})) == "conflict", "update_note: outside edit → conflict")
	var fresh: Dictionary = data(call_tool(p, "read_note", {"path": cd.path}))
	check(fresh.markdown == "edited outside", "read_note after outside edit sees it")
	var ren: Dictionary = data(call_tool(p, "update_note", {"path": cd.path, "hash": fresh.hash, "title": "MCP Probe Renamed"}))
	var probe: String = "Agent/Inbox/note_mcp_probe_renamed.tres"
	check(ren.path == probe and ren.renamed_from == cd.path and ren.title == "MCP Probe Renamed" and not FileAccess.file_exists(V + cd.path) and ren.hash == FileAccess.get_sha256(V + probe),
		"update_note: a title change renames the file the way the app does")

	# search_notes
	var s1: Dictionary = data(call_tool(p, "search_notes", {"query": "EDITED OUTSIDE"}))
	check(s1.total == 1 and s1.notes[0].path == probe and s1.notes[0].matched == "content" and str(s1.notes[0].snippet).contains("edited outside"), "search_notes: content match, case-insensitive, with snippet")
	var s2: Dictionary = data(call_tool(p, "search_notes", {"title": "probe renamed"}))
	check(s2.total == 1 and s2.notes[0].path == probe, "search_notes: title match")
	var s3: Dictionary = data(call_tool(p, "search_notes", {"tag": "#Edited"}))
	check(s3.total == 1 and s3.notes[0].path == probe, "search_notes: tag match (# and case ignored)")
	var tut: Dictionary = data(call_tool(p, "search_notes", {"tag": "tutorial", "limit": 2}))
	check(tut.total > 2 and tut.count == 2 and tut.notes.size() == 2, "search_notes: tag over seeded notes, limit honoured")
	var both: Dictionary = data(call_tool(p, "search_notes", {"tag": "tutorial", "query": "edited outside"}))
	check(both.total == 0, "search_notes: filters combine with AND")
	var inf: Dictionary = data(call_tool(p, "search_notes", {"folder": "Agent"}))
	check(inf.total == 1, "search_notes: folder scope")

	# delete_note → .trash
	check(err_code(call_tool(p, "delete_note", {"path": probe, "hash": rd.hash})) == "conflict" and FileAccess.file_exists(V + probe), "delete_note: stale hash → conflict, file kept")
	check(err_code(call_tool(p, "delete_note", {"path": probe})) == "invalid_arguments", "delete_note: no hash → refused")
	var del: Dictionary = data(call_tool(p, "delete_note", {"path": probe, "hash": ren.hash}))
	check(not FileAccess.file_exists(V + probe) and del.trashed_to == ".trash/" + probe and FileAccess.file_exists(V + del.trashed_to), "delete_note: moved to .trash/<path>")
	check(FileAccess.get_sha256(V + del.trashed_to) == ren.hash, "delete_note: trashed file is byte-identical")
	check(data(call_tool(p, "search_notes", {"query": "edited outside"})).total == 0, "trashed note no longer listed or searched")
	# A second note with the same path deleted → earlier trashed copy kept.
	var c2: Dictionary = data(call_tool(p, "create_note", {"title": "MCP Probe Renamed", "folder": "Agent/Inbox"}))
	var del2: Dictionary = data(call_tool(p, "delete_note", {"path": c2.path, "hash": c2.hash}))
	check(del2.trashed_to != del.trashed_to and FileAccess.file_exists(V + del2.trashed_to) and FileAccess.file_exists(V + del.trashed_to), "delete_note: never overwrites inside the trash")
	# The stamped collision name keeps the note's extension after the paren
	# (".tres"), not the dropped-dot form "…(deleted 2026-11-07T19-00-00tres)".
	check(del2.trashed_to.contains(" (deleted ") and del2.trashed_to.ends_with(".tres"), "delete_note: collision name keeps the extension (ends in \".tres\")")
	# Numbered collision: occupy the primary and " 2" slot for this second and
	# the next, so the delete below must fall on the " 3" name whichever
	# second it lands in — and that name must keep the ".tres" too.
	var d_next: Dictionary = Time.get_datetime_dict_from_system()
	d_next.second += 1
	if d_next.second == 60:
		d_next.second = 0
		d_next.minute += 1
	if d_next.minute == 60:
		d_next.minute = 0
		d_next.hour += 1
	if d_next.hour == 24:
		d_next.hour = 0
		d_next.day += 1
	var s_next: String = "%04d-%02d-%02dT%02d-%02d-%02d" % [d_next.year, d_next.month, d_next.day, d_next.hour, d_next.minute, d_next.second]
	for s in [Time.get_datetime_string_from_system().replace(":", "-"), s_next]:
		for suf in ["", " 2"]:
			var pre: String = V + ".trash/Agent/Inbox/note_mcp_probe_renamed (deleted " + s + suf + ").tres"
			if not FileAccess.file_exists(pre):
				FileAccess.open(pre, FileAccess.WRITE).close()
	var c4r: Dictionary = call_tool(p, "create_note", {"title": "MCP Probe Renamed", "folder": "Agent/Inbox"})
	var c4: Dictionary = data(c4r)
	var del4r: Dictionary = call_tool(p, "delete_note", {"path": c4.path, "hash": c4.hash})
	var del4: Dictionary = data(del4r)
	check(not c4r.get("isError", false) and not del4r.get("isError", false) and del4.trashed_to.begins_with(".trash/Agent/Inbox/note_mcp_probe_renamed (deleted ") and del4.trashed_to.ends_with(" 3).tres") and FileAccess.file_exists(V + del4.trashed_to), "delete_note: numbered collision (\" 3)\") keeps the extension too")
	check(err_code(call_tool(p, "delete_note", {"path": c2.path, "hash": c2.hash})) == "not_found", "delete_note: already gone → not_found")

	# on_change hook (how an in-app host would learn of writes)
	var seen: Array = []
	tools.on_change = func(action: String, rel: String): seen.append(action + ":" + rel)
	var c3: Dictionary = data(call_tool(p, "create_note", {"title": "Hook"}))
	check(seen == ["create:note_hook.tres"], "on_change called after a write")
	tools.on_change = Callable()
	call_tool(p, "delete_note", {"path": c3.path, "hash": c3.hash})


# ── Raw .txt notes: the plain-text half of the vault ───────────────────────

func test_text_notes(V: String) -> void:
	var tools: RefCounted = VaultTools.new(V)
	var p: RefCounted = McpProtocol.new(tools)
	req(p, "initialize", {"protocolVersion": "2025-06-18"})
	# Baseline before this test adds anything: the server lists the same
	# .tres notes the app does (the earlier tests trashed all they created).
	var base: Dictionary = data(call_tool(p, "list_notes", {}))
	check(base.count == VaultStore.note_list.size(), "list_notes: baseline equals the app's %d notes" % VaultStore.note_list.size())

	# create_note format=text
	var c: Dictionary = call_tool(p, "create_note", {"title": "Field Notes", "markdown": "raw body one\ntomato tomato ✓\n", "tags": ["ignored"], "format": "text", "folder": "Agent"})
	var cd: Dictionary = data(c)
	check(not c.isError and cd.path == "Agent/note_field_notes.txt" and FileAccess.file_exists(V + cd.path), "create_note text: writes note_<title>.txt in the folder")
	check(FileAccess.get_file_as_string(V + cd.path) == "raw body one\ntomato tomato ✓\n", "create_note text: file bytes are exactly the markdown")
	check(cd.hash == FileAccess.get_sha256(V + cd.path) and cd.format == "text", "create_note text: returns the SHA-256 of the file")
	var dup: Dictionary = call_tool(p, "create_note", {"title": "Field Notes", "markdown": "other", "folder": "Agent", "format": "text"})
	check(err_code(dup) == "exists" and FileAccess.get_sha256(V + cd.path) == cd.hash, "create_note text: refuses when the .txt exists, file untouched")

	# list_notes now includes the .txt entry
	var lst: Dictionary = data(call_tool(p, "list_notes", {}))
	var txts: Array = lst.notes.filter(func(n): return str(n.format) == "text")
	check(lst.count == base.count + 1 and txts.size() == 1 and txts[0].path == cd.path, "list_notes: the .txt note appears, count is baseline + 1")
	var lst2: Dictionary = data(call_tool(p, "list_notes", {"folder": "Agent"}))
	check(lst2.count == 1 and lst2.notes[0].path == cd.path, "list_notes: folder scope finds the .txt")

	# Same title, different format → different file, no clash either way.
	var ct: Dictionary = call_tool(p, "create_note", {"title": "Field Notes", "markdown": "twin .tres body", "folder": "Agent"})
	check(not ct.isError and data(ct).path == "Agent/note_field_notes.tres", "create_note: .tres and .txt of the same title coexist")
	var dup_tres: Dictionary = call_tool(p, "create_note", {"title": "Field Notes", "markdown": "x", "folder": "Agent"})
	check(err_code(dup_tres) == "exists" and err_code(call_tool(p, "create_note", {"title": "Field Notes", "markdown": "x", "folder": "Agent", "format": "text"})) == "exists", "create_note: each existing file refused separately")
	var lst3: Dictionary = data(call_tool(p, "list_notes", {"folder": "Agent"}))
	check(lst3.count == 2 and lst3.notes.any(func(n): return str(n.path) == "Agent/note_field_notes.tres") and lst3.notes.any(func(n): return str(n.path) == cd.path), "list_notes: folder scope lists both .tres and .txt")

	# read_note on a .txt
	var rd: Dictionary = data(call_tool(p, "read_note", {"path": cd.path}))
	check(rd.format == "text" and rd.title == "note_field_notes" and rd.markdown == "raw body one\ntomato tomato ✓\n", "read_note text: format text, title = file stem, body = file bytes")
	check(rd.tags == [] and rd.created == "" and rd.modified == "" and rd.folder == "Agent", "read_note text: no tags or dates for a raw file")
	check(rd.hash == cd.hash and rd.hash.length() == 64, "read_note text: SHA-256 to pass to update/delete")
	check(err_code(call_tool(p, "read_note", {"path": cd.path, "raw": true})) == "" and "raw" not in rd, "read_note text: raw flag is a no-op, no .tres text")
	check(rd.get("encoding") == "utf-8" and rd.get("editable") == true and not rd.has("warning"), "read_note text: a UTF-8 file is editable, encoding utf-8, no warning")

	# update_note on a .txt: body only
	var u: Dictionary = call_tool(p, "update_note", {"path": cd.path, "hash": rd.hash, "markdown": "raw body two\n"})
	var ud: Dictionary = data(u)
	check(not u.isError and ud.hash != rd.hash and FileAccess.get_file_as_string(V + cd.path) == "raw body two\n", "update_note text: body replaced in place, new hash")
	check(err_code(call_tool(p, "update_note", {"path": cd.path, "hash": rd.hash, "markdown": "LOST UPDATE"})) == "conflict", "update_note text: stale hash → conflict")
	check(err_code(call_tool(p, "update_note", {"path": cd.path, "hash": ud.hash, "title": "New Name"})) == "invalid_arguments", "update_note text: title refused")
	check(err_code(call_tool(p, "update_note", {"path": cd.path, "hash": ud.hash, "tags": ["x"]})) == "invalid_arguments", "update_note text: tags refused")
	check(err_code(call_tool(p, "update_note", {"path": cd.path, "hash": ud.hash, "title": "N", "markdown": "both"})) == "invalid_arguments", "update_note text: title+markdown refused (the markdown is not written)")
	check(FileAccess.get_file_as_string(V + cd.path) == "raw body two\n", "update_note text: refused fields left the file alone")

	# update/delete without a hash
	check(err_code(call_tool(p, "update_note", {"path": cd.path, "markdown": "x"})) == "invalid_arguments", "update_note text: no hash → refused")
	check(err_code(call_tool(p, "delete_note", {"path": cd.path})) == "invalid_arguments", "delete_note text: no hash → refused")

	# search_notes: content and title reach the .txt; tags never do
	var sq: Dictionary = data(call_tool(p, "search_notes", {"query": "RAW BODY TWO"}))
	check(sq.total == 1 and sq.notes[0].path == cd.path and sq.notes[0].matched == "content", "search_notes text: content match in the .txt body")
	var sm: Dictionary = data(call_tool(p, "search_notes", {"query": "note_field_notes"}))
	check(sm.total == 1 and sm.notes[0].path == cd.path and sm.notes[0].matched == "title", "search_notes text: title match is the file stem")
	var st: Dictionary = data(call_tool(p, "search_notes", {"title": "field notes"}))
	check(st.total == 1 and st.notes[0].path == "Agent/note_field_notes.tres", "search_notes: title search finds the .tres title, not the .txt stem")
	var sg: Dictionary = data(call_tool(p, "search_notes", {"tag": "ignored"}))
	check(sg.total == 0, "search_notes text: tags never match a raw .txt")
	# Outside edit → conflict on delete too.
	var body: String = "someone else's words"
	var f: FileAccess = FileAccess.open(V + cd.path, FileAccess.WRITE)
	f.store_string(body); f.close()
	check(err_code(call_tool(p, "delete_note", {"path": cd.path, "hash": ud.hash})) == "conflict" and FileAccess.file_exists(V + cd.path), "delete_note text: outside edit → conflict, file kept")
	var fresh: Dictionary = data(call_tool(p, "read_note", {"path": cd.path}))
	check(fresh.markdown == body, "read_note text: sees the outside edit")

	# delete_note on a .txt → .trash
	var del: Dictionary = data(call_tool(p, "delete_note", {"path": cd.path, "hash": fresh.hash}))
	check(not FileAccess.file_exists(V + cd.path) and del.trashed_to == ".trash/" + cd.path and FileAccess.file_exists(V + del.trashed_to), "delete_note text: moved to .trash/<path>")
	check(FileAccess.get_sha256(V + del.trashed_to) == fresh.hash, "delete_note text: trashed file is byte-identical")
	check(data(call_tool(p, "list_notes", {})).notes.all(func(n): return str(n.path) != cd.path), "list_notes: the .txt is gone after trashing")
	# A second .txt trashed onto the same name gets the stamped collision name,
	# and that name keeps ".txt" (not the ".tres" the trash code once assumed).
	var c2: Dictionary = data(call_tool(p, "create_note", {"title": "Field Notes", "markdown": "second body\n", "format": "text", "folder": "Agent"}))
	var del2r: Dictionary = call_tool(p, "delete_note", {"path": c2.get("path", ""), "hash": c2.get("hash", "")})
	var del2: Dictionary = data(del2r)
	var t2: String = str(del2.get("trashed_to", ""))
	check(not del2r.get("isError", true) and t2.begins_with(".trash/Agent/note_field_notes (deleted ") and t2.ends_with(").txt"), "delete_note text: a trash collision keeps .txt (%s)" % t2)
	check(t2 != "" and FileAccess.get_file_as_string(V + t2) == "second body\n" and FileAccess.get_sha256(V + del.trashed_to) == fresh.hash, "delete_note text: both trashed .txt copies are there, each with its own bytes")

	test_text_encodings(V, p)

	# The app never sees .txt files (its list is .tres-only)
	VaultStore.refresh_note_list()
	check(VaultStore.note_list.all(func(n): return str(n.resource_path).ends_with(".tres")), "VaultStore: .txt files are invisible to the app")
	# Clean up the twin .tres so later tests see only seeded notes.
	call_tool(p, "delete_note", {"path": "Agent/note_field_notes.tres", "hash": data(call_tool(p, "read_note", {"path": "Agent/note_field_notes.tres"})).hash})
	check(not FileAccess.file_exists(V + "Agent/note_field_notes.tres"), "test cleanup: the .twin .tres trashed")


## .txt files that are not UTF-8 are read best-effort and never rewritten: a
## lossy decoding written back would destroy what it could not decode, behind
## a hash that still matched. A UTF-8 BOM is fine, and kept.
func test_text_encodings(V: String, p: RefCounted) -> void:
	check(data(call_tool(p, "read_note", {"path": "Agent/note_field_notes.tres"})).get("editable") == true, "read_note tres: editable true")
	var le: PackedByteArray = "Meeting notes\r\nbuy milk café\r\n".to_utf16_buffer()
	var be := PackedByteArray()
	for i in range(0, le.size(), 2):
		be.append(le[i + 1])
		be.append(le[i])
	var cases: Array = [
		# path, bytes, encoding, what read_note's markdown must hold
		# UTF-16LE with a BOM: Windows PowerShell 5.1 `>` and Notepad "Unicode".
		["Agent/ps.txt", PackedByteArray([0xFF, 0xFE]) + le, "utf-16", "Meeting notes\r\nbuy milk café\r\n"],
		["Agent/ps_be.txt", PackedByteArray([0xFE, 0xFF]) + be, "utf-16", "Meeting notes\r\nbuy milk café\r\n"],
		# Latin-1 / CP-1252 "café\r\n" and a NUL byte: no BOM, no real decoding.
		["Agent/latin.txt", PackedByteArray([0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A]), "unknown", "caf"],
		["Agent/nul.txt", PackedByteArray([0x61, 0x00, 0x62, 0x0A]), "unknown", "a"],
	]
	for cs in cases:
		var path: String = cs[0]
		var bytes: PackedByteArray = cs[1]
		var w: FileAccess = FileAccess.open(V + path, FileAccess.WRITE)
		w.store_buffer(bytes)
		w.close()
		var rr: Dictionary = call_tool(p, "read_note", {"path": path})
		var r: Dictionary = data(rr)
		check(not rr.get("isError", true) and r.get("editable") == false and r.get("encoding") == cs[2] and str(r.get("warning", "")).contains("not UTF-8"), "read_note %s: editable false, encoding %s, a warning" % [path, cs[2]])
		check(str(r.get("markdown", "")).begins_with(cs[3]) and r.get("hash") == FileAccess.get_sha256(V + path), "read_note %s: best-effort markdown, hash of the bytes" % path)
		# The reviewer's repro: append to what was read and send it back.
		var up: Dictionary = call_tool(p, "update_note", {"path": path, "hash": r.get("hash", ""), "markdown": str(r.get("markdown", "")) + "\nadded by claude"})
		check(err_code(up) == "not_utf8" and data(up).error.get("encoding") == cs[2], "update_note %s: refused with not_utf8" % path)
		check(FileAccess.get_file_as_bytes(V + path) == bytes, "update_note %s: the original bytes are untouched" % path)
	# A UTF-16 file is searchable by its decoded text.
	var sm: Dictionary = data(call_tool(p, "search_notes", {"query": "BUY MILK", "folder": "Agent"}))
	var found: Array = sm.notes.map(func(n): return n.path)
	found.sort()
	check(found == ["Agent/ps.txt", "Agent/ps_be.txt"] and str(sm.notes[0].get("snippet", "")).contains("buy milk"), "search_notes: finds text inside UTF-16 .txt files (%s)" % [found])
	# move and delete work on any bytes and keep them.
	var mr: Dictionary = data(call_tool(p, "read_note", {"path": "Agent/ps.txt"}))
	var mv: Dictionary = data(call_tool(p, "move_note", {"path": "Agent/ps.txt", "hash": mr.hash, "folder": "Agent/Win"}))
	check(mv.get("path") == "Agent/Win/ps.txt" and mv.get("hash") == mr.hash, "move_note: a UTF-16 .txt moves byte-identical")
	for path in ["Agent/Win/ps.txt", "Agent/ps_be.txt", "Agent/latin.txt", "Agent/nul.txt"]:
		var h: String = FileAccess.get_sha256(V + path)
		var dl: Dictionary = data(call_tool(p, "delete_note", {"path": path, "hash": h}))
		check(FileAccess.get_sha256(V + str(dl.get("trashed_to", "?"))) == h and not FileAccess.file_exists(V + path), "delete_note %s: trashed byte-identical" % path)
	DirAccess.remove_absolute(V + "Agent/Win")

	# UTF-8 with a BOM: editable; the BOM is not in markdown and survives an edit.
	var bom: PackedByteArray = PackedByteArray([0xEF, 0xBB, 0xBF])
	var w8: FileAccess = FileAccess.open(V + "Agent/bom.txt", FileAccess.WRITE)
	w8.store_buffer(bom + "café one\n".to_utf8_buffer())
	w8.close()
	var b1: Dictionary = data(call_tool(p, "read_note", {"path": "Agent/bom.txt"}))
	check(b1.get("editable") == true and b1.get("encoding") == "utf-8-bom" and b1.get("markdown") == "café one\n", "read_note: a UTF-8 BOM file is editable, BOM not in markdown")
	var bu: Dictionary = call_tool(p, "update_note", {"path": "Agent/bom.txt", "hash": b1.get("hash", ""), "markdown": "café two\n"})
	check(not bu.get("isError", true) and FileAccess.get_file_as_bytes(V + "Agent/bom.txt") == bom + "café two\n".to_utf8_buffer() and data(bu).get("hash") == FileAccess.get_sha256(V + "Agent/bom.txt"), "update_note: a UTF-8 BOM file keeps its BOM")
	call_tool(p, "delete_note", {"path": "Agent/bom.txt", "hash": FileAccess.get_sha256(V + "Agent/bom.txt")})
	check(not FileAccess.file_exists(V + "Agent/bom.txt"), "test cleanup: the encoding probes trashed")


# ── Resources: every note, read-only, as ontomeme://note/<path> ─────────────

## Every resource of a resources/list walk (following nextCursor).
func _all_resources(p: RefCounted) -> Array:
	var out: Array = []
	var params: Dictionary = {}
	for i in 50:
		var r: Variant = req(p, "resources/list", params)
		if not (r is Dictionary and r.has("result")):
			break
		out.append_array(r.result.resources)
		if not r.result.has("nextCursor"):
			break
		params = {"cursor": r.result.nextCursor}
	return out


func test_resources(V: String) -> void:
	var p: RefCounted = McpProtocol.new(VaultTools.new(V))
	check(req(p, "resources/list").error.code == McpProtocol.NOT_INITIALIZED, "resources/list before initialize is refused")
	req(p, "initialize", {"protocolVersion": "2025-06-18"})
	# A .txt, and a note in a folder whose name needs escaping (space, +).
	var odd: Dictionary = data(call_tool(p, "create_note", {"title": "Plus Side", "markdown": "# C++\nbody of the odd one\n", "folder": "C++ Notes/Week 1"}))
	var txt: Dictionary = data(call_tool(p, "create_note", {"title": "Raw Res", "markdown": "plain *text* body\n", "format": "text"}))

	var tpl: Variant = req(p, "resources/templates/list")
	check(tpl.result.resourceTemplates.size() == 1 and tpl.result.resourceTemplates[0].uriTemplate == "ontomeme://note/{path}" and tpl.result.resourceTemplates[0].mimeType == "text/markdown", "resources/templates/list: ontomeme://note/{path}")

	# resources/list covers exactly what list_notes lists.
	var res: Array = _all_resources(p)
	var listed: Array = data(call_tool(p, "list_notes", {"limit": 500})).notes
	var by_path: Dictionary = {}
	for n in listed:
		by_path[n.path] = n
	var res_paths: Array = res.map(func(r): return VaultTools._uri_path(r.uri))
	var list_paths: Array = by_path.keys()
	res_paths.sort()
	list_paths.sort()
	check(res.size() > 0 and res_paths == list_paths and odd.get("path") in res_paths and txt.get("path") in res_paths, "resources/list: every note list_notes returns (%d), .tres and .txt" % res.size())
	check(res.all(func(r): return str(r.uri).begins_with("ontomeme://note/") and not str(r.uri).trim_prefix("ontomeme://note/").contains("/") and r.mimeType == "text/markdown"), "resources/list: ontomeme://note/<encoded path> URIs (no raw /), text/markdown")
	check(res.all(func(r): return by_path.has(VaultTools._uri_path(r.uri)) and r.name == by_path[VaultTools._uri_path(r.uri)].title), "resources/list: each name is the note's title")
	check(VaultTools.note_uri(odd.get("path", "")) == "ontomeme://note/C%2B%2B%20Notes%2FWeek%201%2Fnote_plus_side.tres", "note_uri: space, + and / percent-encoded")

	# resources/read of every listed URI returns its body.
	var all_match: bool = true
	for r in res:
		var rd: Variant = req(p, "resources/read", {"uri": r.uri})
		var want: String = data(call_tool(p, "read_note", {"path": VaultTools._uri_path(r.uri)})).markdown
		if not (rd is Dictionary and rd.has("result") and rd.result.contents.size() == 1 and rd.result.contents[0].text == want
				and rd.result.contents[0].uri == r.uri and rd.result.contents[0].mimeType == "text/markdown"):
			all_match = false
			print("      resources/read mismatch: ", r.uri)
	check(all_match, "resources/read: every listed URI returns the note's Markdown body (%d)" % res.size())
	var raw_form: Variant = req(p, "resources/read", {"uri": "ontomeme://note/C++ Notes/Week 1/note_plus_side.tres"})
	check(raw_form.has("result") and raw_form.result.contents[0].text == "# C++\nbody of the odd one\n", "resources/read: an unescaped path works too, and + stays +")
	var lower: Variant = req(p, "resources/read", {"uri": "ontomeme://note/C%2b%2b%20Notes%2fWeek%201%2fnote_plus_side.tres"})
	check(lower.has("result") and lower.result.contents[0].text == "# C++\nbody of the odd one\n", "resources/read: lowercase %-escapes decode")
	var tr: Variant = req(p, "resources/read", {"uri": VaultTools.note_uri(txt.get("path", ""))})
	check(tr.has("result") and tr.result.contents[0].text == "plain *text* body\n", "resources/read: a .txt note's body")
	check(FileAccess.get_sha256(V + odd.get("path", "")) == odd.get("hash"), "resources/read: read-only, the file is unchanged")

	# Traversal and other bad URIs: -32602, nothing read.
	for bad in ["ontomeme://note/..%2Fx.tres", "ontomeme://note/../x.tres", "ontomeme://note/%2E%2E%2Fx.tres",
			"ontomeme://note/%2Fetc%2Fpasswd.tres", "ontomeme://note/.trash%2Fx.tres", "ontomeme://note/models%2Fm.tres",
			"ontomeme://note/C%2B%2B%20Notes%2F..%2F..%2Fx.tres", "ontomeme://note/bad%zz.tres", "ontomeme://note/half%2",
			"ontomeme://note/note_x.md", "ontomeme://note/", "file:///etc/passwd", "ontomeme://note/a%00b.tres"]:
		var br: Variant = req(p, "resources/read", {"uri": bad})
		check(br.has("error") and br.error.code == McpProtocol.INVALID_PARAMS, "resources/read %s → -32602" % bad)
	check(req(p, "resources/read", {}).error.code == McpProtocol.INVALID_PARAMS, "resources/read without a uri → -32602")
	var missing: Variant = req(p, "resources/read", {"uri": "ontomeme://note/Nowhere%2Fnote_gone.tres"})
	check(missing.has("error") and missing.error.code == McpProtocol.RESOURCE_NOT_FOUND and missing.error.data.uri == "ontomeme://note/Nowhere%2Fnote_gone.tres", "resources/read of a missing note → -32002 with the uri")
	check(req(p, "resources/list", {"cursor": "not a cursor!"}).error.code == McpProtocol.INVALID_PARAMS and req(p, "resources/list", {"cursor": 5}).error.code == McpProtocol.INVALID_PARAMS, "resources/list: a bad cursor → -32602")

	# The tools are unchanged next to the resources.
	var names: Array = req(p, "tools/list").result.tools.map(func(t): return t.name)
	names.sort()
	check(names == TOOL_NAMES, "tools/list: the same tools with resources on")
	call_tool(p, "delete_note", {"path": odd.get("path", ""), "hash": odd.get("hash", "")})
	call_tool(p, "delete_note", {"path": txt.get("path", ""), "hash": txt.get("hash", "")})
	DirAccess.remove_absolute(V + "C++ Notes/Week 1")
	DirAccess.remove_absolute(V + "C++ Notes")
	check(not FileAccess.file_exists(V + odd.get("path", "?")) and not FileAccess.file_exists(V + txt.get("path", "?")), "test cleanup: the resource probes trashed")


# ── move_note: refile a note without losing anything ────────────────────────

func test_move_note(V: String) -> void:
	var tools: RefCounted = VaultTools.new(V)
	var p: RefCounted = McpProtocol.new(tools)
	req(p, "initialize", {"protocolVersion": "2025-06-18"})
	var tool: Dictionary = {}
	for t in req(p, "tools/list").result.tools:
		if t.name == "move_note":
			tool = t
	check(not tool.is_empty() and tool.annotations.readOnlyHint == false and tool.annotations.destructiveHint == false and tool.annotations.idempotentHint == false, "move_note: listed; not read-only, destructive or idempotent")
	check(not tool.is_empty() and tool.inputSchema.required == ["path", "hash", "folder"], "move_note: path, hash and folder are required")

	# A starred note the app already knows in Agent/Inbox.
	var c: Dictionary = data(call_tool(p, "create_note", {"title": "Mover", "markdown": "moving body\n", "tags": ["m"], "folder": "Agent/Inbox"}))
	var star: ContentLayer = ResourceLoader.load(V + c.path, "", ResourceLoader.CACHE_MODE_IGNORE) as ContentLayer
	star.starred_at = "2026-11-07T10:00:00"
	ResourceSaver.save(star, V + c.path)
	var before: Dictionary = data(call_tool(p, "read_note", {"path": c.path}))
	VaultStore.refresh_note_list()
	var known: Array = VaultStore.note_list.filter(func(x): return x.title == "Mover")
	check(known.size() == 1 and VaultStore.folder_of(known[0]) == "Agent/Inbox", "move_note setup: the app lists Mover under Agent/Inbox")

	# Refusals leave the note (and the target folder) alone.
	check(err_code(call_tool(p, "move_note", {"path": c.path, "hash": c.hash, "folder": "Moved/Deep"})) == "conflict", "move_note: stale hash → conflict")
	check(err_code(call_tool(p, "move_note", {"path": c.path, "folder": "Moved/Deep"})) == "invalid_arguments", "move_note: no hash → invalid_arguments")
	check(err_code(call_tool(p, "move_note", {"path": c.path, "hash": before.hash})) == "invalid_arguments", "move_note: no folder → invalid_arguments")
	for bad in [".trash", "models", "models/sub", ".ontomeme/tmp", "Moved/.hidden", "../outside", "/tmp"]:
		check(err_code(call_tool(p, "move_note", {"path": c.path, "hash": before.hash, "folder": bad})) == "invalid_path", "move_note: folder %s → invalid_path" % bad)
	check(err_code(call_tool(p, "move_note", {"path": "nope/note_missing.tres", "hash": before.hash, "folder": "Moved"})) == "not_found", "move_note: missing note → not_found")
	check(FileAccess.get_sha256(V + c.path) == before.hash and not DirAccess.dir_exists_absolute(V + "Moved"), "move_note: refusals change nothing (note in place, no folder made)")
	# The asset folder is no place for a note anywhere else either.
	check(err_code(call_tool(p, "create_note", {"title": "X", "folder": "models"})) == "invalid_path" and err_code(call_tool(p, "list_notes", {"folder": "models"})) == "invalid_path", "create_note / list_notes: the models asset folder → invalid_path")

	# The move: into a folder that doesn't exist yet.
	var changes: Array = []
	tools.on_change = func(action: String, rel: String): changes.append([action, rel])
	var mv: Dictionary = call_tool(p, "move_note", {"path": c.path, "hash": before.hash, "folder": "Moved/Deep"})
	var md: Dictionary = data(mv)
	check(not mv.isError and md.path == "Moved/Deep/note_mover.tres" and md.from == c.path and md.moved == true, "move_note: returns the new path")
	check(FileAccess.file_exists(V + md.path) and not FileAccess.file_exists(V + c.path), "move_note: the file is at the new path, not the old one")
	check(md.hash == before.hash and FileAccess.get_sha256(V + md.path) == before.hash, "move_note: same bytes, same hash")
	check(not FileAccess.file_exists(V + ".trash/" + c.path), "move_note: no copy left in the trash")
	check(changes == [["move", md.path]], "move_note: on_change hears (move, new path)")
	var after: Dictionary = data(call_tool(p, "read_note", {"path": md.path}))
	check(after.created == before.created and after.created != "" and after.get("starred_at") == before.get("starred_at"), "move_note: read_note at the new path has the same created and starred_at")
	check(after.markdown == before.markdown and after.tags == before.tags and after.title == "Mover" and after.folder == "Moved/Deep", "move_note: body, tags and title kept")
	var moved: ContentLayer = ResourceLoader.load(V + md.path, "", ResourceLoader.CACHE_MODE_IGNORE) as ContentLayer
	check(moved != null and moved.starred_at == "2026-11-07T10:00:00", "move_note: starred_at survives on disk")
	check(err_code(call_tool(p, "update_note", {"path": c.path, "hash": before.hash, "markdown": "x"})) == "not_found", "move_note: the old path is gone for later edits")

	# The app follows the move after a rescan.
	VaultStore.refresh_note_list()
	var seen: Array = VaultStore.note_list.filter(func(x): return x.title == "Mover")
	check(seen.size() == 1 and VaultStore.folder_of(seen[0]) == "Moved/Deep" and seen[0].resource_path == V + md.path and "Moved/Deep" in VaultStore.folders, "VaultStore: lists the note under the new folder")
	check(not VaultStore.note_list.any(func(x): return x.resource_path == V + c.path), "VaultStore: and not under the old one")

	# An existing file at the target → exists; both notes untouched.
	var twin: Dictionary = data(call_tool(p, "create_note", {"title": "Mover", "markdown": "twin", "folder": "Agent/Inbox"}))
	var ex: Dictionary = call_tool(p, "move_note", {"path": twin.path, "hash": twin.hash, "folder": "Moved/Deep"})
	check(err_code(ex) == "exists" and data(ex).error.path == md.path, "move_note: existing target → exists (with its path)")
	check(FileAccess.get_sha256(V + twin.path) == twin.hash and FileAccess.get_sha256(V + md.path) == before.hash, "move_note: exists leaves both files alone")

	# Same folder → nothing to do; "" → top level; a .txt moves too.
	var same: Dictionary = call_tool(p, "move_note", {"path": md.path, "hash": md.hash, "folder": "Moved/Deep/"})
	check(not same.isError and data(same).moved == false and data(same).path == md.path and FileAccess.file_exists(V + md.path), "move_note: already in that folder → moved false, nothing changes")
	var top: Dictionary = data(call_tool(p, "move_note", {"path": md.path, "hash": md.hash, "folder": ""}))
	check(top.get("path") == "note_mover.tres" and FileAccess.file_exists(V + "note_mover.tres"), "move_note: folder \"\" → top level")
	var txt: Dictionary = data(call_tool(p, "create_note", {"title": "Loose", "markdown": "plain\n", "format": "text", "folder": "Agent"}))
	var tm: Dictionary = data(call_tool(p, "move_note", {"path": txt.path, "hash": txt.hash, "folder": "Moved"}))
	check(tm.get("path") == "Moved/note_loose.txt" and tm.get("hash") == txt.hash and FileAccess.get_file_as_string(V + "Moved/note_loose.txt") == "plain\n", "move_note: a .txt note moves byte-identical")

	tools.on_change = Callable()
	for done in [[top.path, top.hash], [twin.path, twin.hash], [tm.path, tm.hash]]:
		call_tool(p, "delete_note", {"path": done[0], "hash": done[1]})
	VaultStore.refresh_note_list()
	check(not VaultStore.note_list.any(func(x): return x.title == "Mover"), "test cleanup: the move notes trashed")


# ── A leading U+FEFF (Windows "UTF-8 with BOM") in a .tres field ────────────

## A file saved as UTF-8 with BOM starts with U+FEFF, and an agent importing
## one passes it on. Godot's text resource loader drops a U+FEFF at the start
## of a string, so a .tres field that kept one never read back as saved
## (VaultStore.saved_matches) and every such create_note and update_note
## failed with write_failed, blaming the disk. The BOM is not part of the
## text, as _read_text already treats it for a .txt note.
func test_bom_fields(V: String) -> void:
	var tools: RefCounted = VaultTools.new(V)
	var bom: String = char(0xFEFF)
	var c: Dictionary = tools.call_tool("create_note", {"title": bom + "Imported", "markdown": bom + "# Heading\nbody", "tags": [bom + "imported", bom + bom + "#Twice"], "folder": "Bom"})
	check(not c.isError and data(c).get("path") == "Bom/note_imported.tres", "create_note: a title, body and tags starting with U+FEFF are written (%s)" % c.content[0].text)
	var rd: Dictionary = data(tools.call_tool("read_note", {"path": "Bom/note_imported.tres"}))
	check(rd.get("title") == "Imported" and rd.get("markdown") == "# Heading\nbody" and rd.get("tags") == ["imported", "twice"], "…without the BOM (%s)" % str([rd.get("title"), rd.get("markdown"), rd.get("tags")]).c_escape())
	var u: Dictionary = tools.call_tool("update_note", {"path": "Bom/note_imported.tres", "hash": rd.get("hash", ""), "markdown": bom + "# New", "tags": [bom + "fresh"]})
	var rd2: Dictionary = data(tools.call_tool("read_note", {"path": "Bom/note_imported.tres"}))
	check(not u.isError and rd2.get("markdown") == "# New" and rd2.get("tags") == ["fresh"], "update_note: a body and tags starting with U+FEFF are written without it (%s)" % u.content[0].text)
	var ren: Dictionary = tools.call_tool("update_note", {"path": "Bom/note_imported.tres", "hash": rd2.get("hash", ""), "title": bom + "Imported Again", "markdown": bom + "renamed"})
	check(not ren.isError and data(ren).get("title") == "Imported Again" and data(ren).get("path") == "Bom/note_imported_again.tres"
			and data(tools.call_tool("read_note", {"path": "Bom/note_imported_again.tres"})).get("markdown") == "renamed", "update_note: a new title starting with U+FEFF renames the note without it (%s)" % ren.content[0].text)
	check(err_code(tools.call_tool("create_note", {"title": bom + " "})) == "invalid_arguments", "create_note: a title of only a BOM is empty")
	check(tools._write_error("x.tres", ERR_FILE_CANT_WRITE).contains("did not read back"), "write_failed also says the saved file may not have read back the same (%s)" % tools._write_error("x.tres", ERR_FILE_CANT_WRITE))
	check(DirAccess.get_files_at(V + ".ontomeme/tmp").size() == 0, "…and no temp file is left")
	TestVault.remove_tree(V + "Bom")


# ── Markdown export folders: no place for a note ───────────────────────────

## Every scan, the MCP's and the app's, skips a folder holding MdExport.MARKER
## (exports/, at any depth), so a note created or moved into one dropped out
## of list_notes, search_notes, list_tags, the rename checks and the
## sidebar. create_note and move_note refuse it, as they refuse models/.
func test_export_folder(V: String) -> void:
	var tools: RefCounted = VaultTools.new(V)
	for dir in ["exports", "Projects/out"]:
		DirAccess.make_dir_recursive_absolute(V + dir)
		FileAccess.open(V + dir + "/" + MdExport.MARKER, FileAccess.WRITE).close()
	for folder in ["exports", "exports/Physics", "Projects/out", "Projects/out/deeper"]:
		var r: Dictionary = tools.call_tool("create_note", {"title": "Plan", "markdown": "important plan", "folder": folder})
		check(err_code(r) == "invalid_path", "create_note: export folder %s → invalid_path (%s)" % [folder, r.content[0].text])
	var c: Dictionary = data(tools.call_tool("create_note", {"title": "Export Mover", "markdown": "moving"}))
	for folder in ["exports", "Projects/out/deeper"]:
		check(err_code(tools.call_tool("move_note", {"path": c.path, "hash": c.hash, "folder": folder})) == "invalid_path", "move_note: export folder %s → invalid_path" % folder)
	check(FileAccess.get_sha256(V + c.path) == c.hash and DirAccess.get_files_at(V + "exports").is_empty() and DirAccess.get_directories_at(V + "exports").is_empty()
			and DirAccess.get_files_at(V + "Projects/out").is_empty() and DirAccess.get_directories_at(V + "Projects/out").is_empty(), "…nothing is written there and the note stays where it was")
	tools.call_tool("delete_note", {"path": c.path, "hash": c.hash})
	TestVault.remove_tree(V + "exports")
	TestVault.remove_tree(V + "Projects")


## A client that fills every optional field sends a JSON null for a filter
## it doesn't use. str(null) is "<null>", so search_notes filtered on that
## text and found nothing. A null filter is no filter, as a null folder is.
func test_search_nulls(V: String) -> void:
	var p: RefCounted = McpProtocol.new(VaultTools.new(V))
	req(p, "initialize", {"protocolVersion": "2025-06-18"})
	var c: Dictionary = data(call_tool(p, "create_note", {"title": "Null Probe", "markdown": "about nullwaves", "tags": ["nullprobe"]}))
	for args in [{"query": "nullwaves"}, {"query": "nullwaves", "tag": null}, {"query": "nullwaves", "title": null},
			{"query": null, "tag": "nullprobe"}, {"query": null, "title": null, "tag": "nullprobe", "folder": null}]:
		var line: String = JSON.stringify({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_notes", "arguments": args}})
		var r: Dictionary = JSON.parse_string(p.handle_line(line)).get("result", {})
		check(not r.get("isError", true) and data(r).get("total") == 1, "search_notes %s finds the note (%s)" % [JSON.stringify(args), data(r).get("total")])
	call_tool(p, "delete_note", {"path": c.path, "hash": c.hash})


# ── Paging: list_notes and search_notes over a big vault ────────────────────

## A vault of 450 notes: 440 .tres in 9 folders, their `modified` dates
## shared by ~16 notes each (so the path tiebreak matters), every 15th with
## "zebracorn" in its body (30 matches), and 10 .txt notes (no dates).
## → the vault path; the paths go into `paths_out`.
func _seed_page_vault(paths_out: Array) -> String:
	var dir: String = ProjectSettings.globalize_path("user://test-vault-mcp-pages/")
	TestVault.remove_tree(dir)
	for i in 440:
		var folder: String = "Shelf %d" % (i % 9)
		DirAccess.make_dir_recursive_absolute(dir + folder)
		var n := ContentLayer.new()
		n.title = "Page Note %03d" % i
		n.raw_text = "note %d of the paging vault\n%s" % [i, "a zebracorn lives here\n" if i % 15 == 0 else ""]
		n.tags = ["paging"]
		n.structure = {}
		n.created = "2026-10-%02dT09:00:00" % (1 + i % 28)
		n.modified = "2026-10-%02dT12:00:00" % (1 + i % 28)
		var rel: String = folder + "/note_page_note_%03d.tres" % i
		ResourceSaver.save(n, dir + rel)
		paths_out.append(rel)
	for i in 10:
		var rel: String = "Loose/plain_%02d.txt" % i
		DirAccess.make_dir_recursive_absolute(dir + "Loose")
		var f: FileAccess = FileAccess.open(dir + rel, FileAccess.WRITE)
		f.store_string("plain text %d\n" % i)
		f.close()
		paths_out.append(rel)
	return dir


## Call `tool` through handle_line, as a client would see it. → [the
## CallToolResult, the JSON-RPC line's size in bytes].
func _paged_call(p: RefCounted, tool: String, args: Dictionary) -> Array:
	_next_id += 1
	var line: String = p.handle_line(JSON.stringify({"jsonrpc": "2.0", "id": _next_id, "method": "tools/call", "params": {"name": tool, "arguments": args}}))
	var reply: Variant = JSON.parse_string(line)
	var result: Dictionary = reply.result if reply is Dictionary and reply.has("result") else {}
	return [result, line.to_utf8_buffer().size()]


## Follow next_cursor from `args` to the last page. → {paths (in order),
## pages (each page's note count), biggest (largest line), folders_on (page
## numbers that carried `folders`), errors}.
func _walk_pages(p: RefCounted, tool: String, args: Dictionary) -> Dictionary:
	var walk: Dictionary = {"paths": [], "pages": [], "biggest": 0, "folders_on": [], "errors": 0}
	var a: Dictionary = args.duplicate()
	while walk.pages.size() < 50:
		var res: Array = _paged_call(p, tool, a)
		var r: Dictionary = res[0]
		if r.get("isError", true):
			walk.errors += 1
			break
		var d: Dictionary = data(r)
		walk.pages.append(d.notes.size())
		walk.biggest = maxi(walk.biggest, res[1])
		if d.has("folders"):
			walk.folders_on.append(walk.pages.size())
		for n in d.notes:
			walk.paths.append(n.path)
		if not d.has("next_cursor"):
			break
		a["cursor"] = d.next_cursor
	return walk


func test_pagination() -> void:
	var seeded: Array = []
	var dir: String = _seed_page_vault(seeded)
	var tools: RefCounted = VaultTools.new(dir)
	var p: RefCounted = McpProtocol.new(tools)
	req(p, "initialize", {"protocolVersion": "2025-06-18"})
	for t in req(p, "tools/list").result.tools:
		if t.name in ["list_notes", "search_notes"]:
			check(t.inputSchema.properties.has("cursor") and t.inputSchema.properties.limit.maximum == 500, "%s: schema has limit (max 500) and cursor" % t.name)

	# The first page: 100 notes, the folder tree, a cursor.
	var first: Array = _paged_call(p, "list_notes", {})
	var fd: Dictionary = data(first[0])
	check(fd.get("notes", []).size() == 100 and fd.get("count") == 100 and fd.get("total") == 450 and fd.has("next_cursor"), "list_notes: no limit → 100 of 450 notes and a next_cursor")
	check(fd.get("folders", []).size() == 10 and "Loose" in fd.get("folders", []), "list_notes: the first page lists the folders")

	# Following the cursors: every path exactly once, in order, small pages.
	var walk: Dictionary = _walk_pages(p, "list_notes", {})
	var got: Array = walk.paths.duplicate()
	got.sort()
	var want: Array = seeded.duplicate()
	want.sort()
	check(walk.errors == 0 and walk.pages == [100, 100, 100, 100, 50], "list_notes: 5 pages of 100,100,100,100,50 (%s)" % [walk.pages])
	check(got == want, "list_notes: the cursors return all 450 paths exactly once (%d returned)" % walk.paths.size())
	check(walk.folders_on == [1], "list_notes: only the first page carries the folder tree (%s)" % [walk.folders_on])
	check(walk.biggest < 65536, "list_notes: every page's JSON-RPC line is under 64 KB (largest %d bytes)" % walk.biggest)
	var in_order: bool = true
	var dated: Dictionary = {}
	for n in data(tools.list_notes({"limit": 500})).notes:
		dated[n.path] = n.modified
	for i in range(1, walk.paths.size()):
		var a: Array = [dated[walk.paths[i - 1]], walk.paths[i - 1]]
		var b: Array = [dated[walk.paths[i]], walk.paths[i]]
		if a[0] < b[0] or (a[0] == b[0] and a[1] >= b[1]):
			in_order = false
	check(in_order and walk.paths[-1].ends_with(".txt"), "list_notes: newest modified first, path A→Z among equal dates, undated .txt last")

	# Pages stay stable when the vault changes between calls: a new note
	# (newest of all) and the trashed cursor note shift nothing.
	var p1: Dictionary = data(_paged_call(p, "list_notes", {"limit": 120})[0])
	var cursor_note: String = p1.notes[-1].path
	var added: Dictionary = data(call_tool(p, "create_note", {"title": "Late Arrival", "folder": "Shelf 0"}))
	call_tool(p, "delete_note", {"path": cursor_note, "hash": FileAccess.get_sha256(dir + cursor_note)})
	var rest: Dictionary = _walk_pages(p, "list_notes", {"limit": 120, "cursor": p1.next_cursor})
	var both: Array = p1.notes.map(func(n): return n.path) + rest.paths
	both.sort()
	check(rest.errors == 0 and both == want and not rest.paths.has(added.get("path")), "list_notes: a note added and the cursor's note trashed mid-walk shift no page (%d + %d)" % [p1.notes.size(), rest.paths.size()])
	call_tool(p, "delete_note", {"path": added.get("path", ""), "hash": added.get("hash", "")})

	# search_notes: 30 matches, 10 a page, 3 calls.
	var sw: Dictionary = _walk_pages(p, "search_notes", {"query": "zebracorn", "limit": 10})
	var unique: Dictionary = {}
	for path in sw.paths:
		unique[path] = true
	check(sw.errors == 0 and sw.pages == [10, 10, 10] and unique.size() == 30, "search_notes: limit 10 pages through 30 matches in 3 calls (%s)" % [sw.pages])
	var s1: Dictionary = data(call_tool(p, "search_notes", {"query": "zebracorn", "limit": 10}))
	check(s1.get("total") == 30 and s1.get("count") == 10 and not s1.has("folders"), "search_notes: total counts every match, count this page")
	check(data(call_tool(p, "search_notes", {"tag": "paging"})).get("count") == 100, "search_notes: default limit is 100")

	# Limits are clamped; cursors that don't decode are refused.
	var big: Dictionary = data(call_tool(p, "list_notes", {"limit": 5000}))
	check(big.get("count") == 449 and big.get("total") == 449 and not big.has("next_cursor") and tools._page_args({"limit": 5000}).get("limit") == 500, "list_notes: limit over 500 → 500 (the 449 left in one page)")
	check(data(call_tool(p, "list_notes", {"limit": 0})).get("count") == 1, "list_notes: limit under 1 → 1")
	check(err_code(call_tool(p, "list_notes", {"limit": "ten"})) == "invalid_arguments", "list_notes: a non-number limit → invalid_arguments")
	var bad_cursors: Array = [
		"not a cursor!",
		Marshalls.utf8_to_base64("hello"),   # base64, but not JSON
		Marshalls.utf8_to_base64("{\"v\":1}"),   # JSON, but no key
		Marshalls.utf8_to_base64("[1,2]"),
		17,
	]
	for bad in bad_cursors:
		for tool in ["list_notes", "search_notes"]:
			var r: Dictionary = call_tool(p, tool, {"cursor": bad, "query": "zebracorn"} if tool == "search_notes" else {"cursor": bad})
			check(r.get("isError") == true and err_code(r) == "invalid_arguments", "%s: cursor %s → isError invalid_arguments" % [tool, JSON.stringify(bad)])
	check(VaultTools.decode_cursor(fd.get("next_cursor", "")).get("path") == fd.notes[-1].path, "decode_cursor: a real cursor names its page's last note")
	# resources/list pages the same way (nextCursor), over every note.
	var first_res: Variant = req(p, "resources/list")
	var res_uris: Array = _all_resources(p).map(func(r): return r.uri)
	var listed_uris: Array = data(tools.list_notes({"limit": 500})).notes.map(func(n): return VaultTools.note_uri(n.path))
	check(first_res.result.resources.size() == 100 and first_res.result.has("nextCursor") and res_uris == listed_uris, "resources/list: 100 a page with nextCursor, all %d notes in list order" % res_uris.size())
	TestVault.remove_tree(dir)


# ── Lint warnings on write: NoteLint, shared with scripts/lint_notes.gd ─────

## The warnings of a create/update result.
func warnings_of(result: Dictionary) -> Array:
	return data(result).get("warnings", ["<no warnings key>"])


func test_lint_on_write(V: String) -> void:
	var p: RefCounted = McpProtocol.new(VaultTools.new(V))
	req(p, "initialize", {"protocolVersion": "2025-06-18"})
	# A quiz whose learn: names a missing note (line 3), then a ```3d block
	# that is never closed (line 10).
	var bad_body: String = "# Lint probe\n\n```3d quiz\nq: Which is round?\na*: sphere\na: cube\nlearn: No Such Note\n```\n\n```3d\ncube: red\n"
	var c: Dictionary = call_tool(p, "create_note", {"title": "Lint Probe", "markdown": bad_body, "folder": "Agent"})
	var w: Array = warnings_of(c)
	check(not c.get("isError", true) and FileAccess.file_exists(V + "Agent/note_lint_probe.tres"), "create_note: a note with markup problems is still written")
	check(w.size() == 2, "create_note: 2 warnings for a bad learn: and an unclosed fence (%s)" % [w])
	if w.size() == 2:
		check(w[0].level == "error" and w[0].line == 3 and str(w[0].message).contains("learn: points at a missing note 'No Such Note'"), "warning 1: learn: to a missing note, on the quiz's line 3")
		check(w[1].level == "error" and w[1].line == 10 and str(w[1].message).contains("fence is never closed"), "warning 2: the unclosed ``` fence, on line 10")
	check(str(c.content[0].text).contains("\"warnings\""), "create_note: the warnings are in the text content too")

	# A clean note: links to other notes (any case), to itself, a valid quiz,
	# a ``` fence of four backticks holding a ```3d line that is not a block.
	var clean: String = "See [[tutorial 1: writing notes]] and [[Lint Clean|this note]].\n\n```3d quiz\nq: Two plus two?\na: 3\na*: 4\nlearn: Tutorial 2: Linking Notes\n```\n\n````\n```3d nebula\n[[Not A Link]]\n```\n````\n"
	var cc: Dictionary = call_tool(p, "create_note", {"title": "Lint Clean", "markdown": clean, "folder": "Agent"})
	check(not cc.get("isError", true) and data(cc).get("warnings") == [], "create_note: a clean note → warnings: [] (%s)" % [data(cc).get("warnings")])

	# update_note: warnings for the saved body; the edit is never refused.
	var cd: Dictionary = data(c)
	var fixed: Dictionary = call_tool(p, "update_note", {"path": cd.path, "hash": cd.hash, "markdown": "# Lint probe\n\n```3d\ncube: red\n```\n"})
	check(not fixed.get("isError", true) and warnings_of(fixed) == [], "update_note: fixing the body → warnings: []")
	var linked: Dictionary = call_tool(p, "update_note", {"path": cd.path, "hash": data(fixed).get("hash", ""), "markdown": "intro\nsee [[Nowhere At All]]\n"})
	var lw: Array = warnings_of(linked)
	check(not linked.get("isError", true) and lw.size() == 1 and lw[0].level == "warning" and lw[0].line == 2 and str(lw[0].message).contains("[[Nowhere At All]]"), "update_note: a [[link]] to a missing note → 1 warning, line 2 (%s)" % [lw])
	check(data(call_tool(p, "read_note", {"path": cd.path})).markdown == "intro\nsee [[Nowhere At All]]\n", "update_note: the body with a warning was saved")
	var renamed: Dictionary = call_tool(p, "update_note", {"path": cd.path, "hash": data(linked).get("hash", ""), "title": "Nowhere At All"})
	check(warnings_of(renamed) == [], "update_note: a title change re-lints the body (the link now names the note itself)")

	# Links as WikiLinks reads them: [[Title#Heading]] names Title (also a
	# title with '#' in it, and the note itself), and a [[link]] in a code
	# span is no link. A missing note behind a heading still warns.
	var photo: Dictionary = call_tool(p, "create_note", {"title": "Lint Photosynthesis", "markdown": "# Light reactions\ntext\n", "folder": "Agent"})
	var csharp: Dictionary = call_tool(p, "create_note", {"title": "Lint C# Tips", "markdown": "# Intro\n", "folder": "Agent"})
	var bio_body: String = "See [[Lint Photosynthesis#Light reactions]] and [[Lint Photosynthesis#Dark reactions|the Calvin cycle]].\nWrite links as `[[Note Title]]`.\n[[Lint C# Tips#Intro]], [[Lint Biology#Top]], `code` then [[Lint Ghost#Intro]].\n"
	var bio: Dictionary = call_tool(p, "create_note", {"title": "Lint Biology", "markdown": bio_body, "folder": "Agent"})
	var bw: Array = warnings_of(bio)
	check(warnings_of(photo) == [] and bw.size() == 1 and bw[0].level == "warning" and bw[0].line == 3 and str(bw[0].message) == "link to a note that doesn't exist: [[Lint Ghost#Intro]]",
			"create_note: [[Title#Heading]] links resolve to Title and a code span's [[link]] is skipped; only the missing note warns (%s)" % [bw])

	# The vault's own models/ folder and journey.
	DirAccess.make_dir_recursive_absolute(V + "models")
	FileAccess.open(V + "models/lint_here.glb", FileAccess.WRITE).close()
	var jf: FileAccess = FileAccess.open(V + VaultTools.JOURNEY_FILE, FileAccess.WRITE)
	jf.store_string(JSON.stringify({"topics": [{"name": "T", "objectives": [{"id": "x", "name": "Know Lint"}]}]}))
	jf.close()
	var scene: String = "```3d\nmodel: lint_here.glb\nmodel: lint_gone.glb\n```\n\n```3d quiz\nobjective: know lint\nq: a?\na*: y\na: n\n```\n\n```3d quiz\nobjective: Unheard Of\nq: b?\na*: y\na: n\n```\n"
	var sc: Dictionary = call_tool(p, "create_note", {"title": "Lint Scene", "markdown": scene, "folder": "Agent"})
	var sw: Array = warnings_of(sc)
	check(sw.size() == 2 and sw[0].line == 1 and str(sw[0].message).contains(V + "models/lint_gone.glb") and sw[1].level == "warning" and sw[1].line == 13 and str(sw[1].message).contains("'Unheard Of'"),
			"create_note: model: and objective: checked against this vault's models/ and journey (%s)" % [sw])

	# A .txt note is linted too (its title is the file stem).
	var tx: Dictionary = call_tool(p, "create_note", {"title": "Lint Text", "markdown": "[[note_lint_text]]\n```\nunclosed\n", "format": "text", "folder": "Agent"})
	var tw: Array = warnings_of(tx)
	check(tw.size() == 1 and tw[0].line == 2 and str(tw[0].message).contains("never closed"), "create_note text: warnings too (%s)" % [tw])
	var tu: Dictionary = call_tool(p, "update_note", {"path": data(tx).get("path", ""), "hash": data(tx).get("hash", ""), "markdown": "closed now\n"})
	check(not tu.get("isError", true) and warnings_of(tu) == [], "update_note text: warnings: [] once clean")

	# Read view's own rules (moved from scripts/lint_notes.gd into NoteLint):
	# an image line whose file this vault lacks, a [text](target) it won't
	# open. A file in images/, a web link and a code span pass.
	DirAccess.make_dir_recursive_absolute(V + "images")
	Image.create(2, 2, false, Image.FORMAT_RGBA8).save_png(V + "images/lint_here.png")
	var pics: String = "![here](images/lint_here.png)\n![gone](images/lint_gone.png)\nSee [the notes](notes.md) or [the site](https://example.com).\n`[x](y.md)` is code.\n"
	var pc: Dictionary = call_tool(p, "create_note", {"title": "Lint Pics", "markdown": pics, "folder": "Agent"})
	var pw: Array = warnings_of(pc)
	check(pw.size() == 2 and pw[0].level == "warning" and pw[0].line == 2 and str(pw[0].message).contains("image not found: images/lint_gone.png")
			and pw[1].level == "warning" and pw[1].line == 3 and str(pw[1].message).contains("[the notes](notes.md) shows as plain text"),
			"create_note: image lines checked against this vault's images/, and a [text](notes.md) link warned (%s)" % [pw])

	for done in [renamed, cc, sc, tu, pc, photo, csharp, bio]:
		var dd: Dictionary = data(done)
		call_tool(p, "delete_note", {"path": dd.get("path", ""), "hash": dd.get("hash", "")})
	DirAccess.remove_absolute(V + "images/lint_here.png")
	DirAccess.remove_absolute(V + "images")
	DirAccess.remove_absolute(V + "models/lint_here.glb")
	DirAccess.remove_absolute(V + VaultTools.JOURNEY_FILE)
	VaultStore.refresh_note_list()
	check(not VaultStore.note_list.any(func(x): return str(x.title).begins_with("Lint ") or x.title == "Nowhere At All"), "test cleanup: the lint probes trashed")


## scripts/lint_notes.gd is now a thin CLI over NoteLint: its report on
## LINT_FIXTURE must stay what it printed before the move, line for line.
func test_lint_cli() -> void:
	var src: String = ProjectSettings.globalize_path("user://test-lint-cli-src/")
	var vault: String = ProjectSettings.globalize_path("user://test-lint-cli-vault")
	TestVault.remove_tree(src)
	TestVault.remove_tree(vault + "/")
	DirAccess.make_dir_recursive_absolute(vault)
	for rel in LINT_FIXTURE:
		DirAccess.make_dir_recursive_absolute(src.path_join(rel).get_base_dir())
		var f: FileAccess = FileAccess.open(src.path_join(rel), FileAccess.WRITE)
		f.store_string(LINT_FIXTURE[rel])
		f.close()
	var out: Array = []
	var code: int = OS.execute(OS.get_executable_path(), ["--headless", "--no-header", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://scripts/lint_notes.gd", "--", src.trim_suffix("/"), "--vault=" + vault], out)
	var got: Array = Array(str(out[0] if out.size() > 0 else "").strip_edges().split("\n"))
	var known: String = ", ".join(NoteScene3D.PRESETS.keys())
	var want: Array = LINT_CLI_EXPECTED.map(func(l: String) -> String:
		return l % known if l.contains("unknown preset") else (l % vault if l.contains("model file not found") else l))
	check(code == 1 and got == want, "lint_notes.gd: the same report as before the move into NoteLint (exit %d, %d lines)" % [code, got.size()])
	if got != want:
		for i in maxi(got.size(), want.size()):
			var g: String = got[i] if i < got.size() else "<none>"
			var x: String = want[i] if i < want.size() else "<none>"
			if g != x:
				print("      line %d: got  %s\n               want %s" % [i + 1, g, x])
	TestVault.remove_tree(src)
	TestVault.remove_tree(vault + "/")


# ── get_note_guide: the markup reference, shipped with the server ──────────

func test_note_guide(V: String) -> void:
	# The shipped guide is markup.md, byte for byte. If this fails, someone
	# edited one without the other: copy markup.md over mcp/note_guide.md.
	var shipped: PackedByteArray = FileAccess.get_file_as_bytes(VaultTools.GUIDE_PATH)
	check(not shipped.is_empty() and shipped == FileAccess.get_file_as_bytes(MARKUP_MD), "mcp/note_guide.md is identical to skills/ontomeme-notes/references/markup.md (re-copy it)")
	# Both are published, and .publish/check.sh refuses a dead link in them: a
	# backticked example like `notes.md` counts as one (scripts/check_md_links.sh).
	if OS.get_name() == "Windows" or OS.execute("bash", ["-c", "exit 0"]) != 0:
		print("SKIP  note guide links: needs bash")
	else:
		var out: Array = []
		var code: int = OS.execute("bash", [ProjectSettings.globalize_path("res://scripts/check_md_links.sh"), ProjectSettings.globalize_path("res://"),
			MARKUP_MD.trim_prefix("res://"), VaultTools.GUIDE_PATH.trim_prefix("res://")], out, true)
		check(code == 0, "markup.md and mcp/note_guide.md pass scripts/check_md_links.sh (%s)" % "".join(out).strip_edges().replace("\n", "; "))
	var markup: String = FileAccess.get_file_as_string(MARKUP_MD)

	var p: RefCounted = McpProtocol.new(VaultTools.new(V))
	req(p, "initialize", {"protocolVersion": "2025-06-18"})
	var by_name: Dictionary = {}
	for t in req(p, "tools/list").result.tools:
		by_name[t.name] = t
	var tool: Dictionary = by_name.get("get_note_guide", {})
	check(not tool.is_empty() and tool.annotations.readOnlyHint == true, "tools/list: get_note_guide is there, readOnlyHint true")
	check(not tool.is_empty() and tool.inputSchema.properties.topic.enum == ["3d", "quiz", "flashcards", "links"] and not tool.inputSchema.has("required"), "get_note_guide: optional topic 3d / quiz / flashcards / links")
	for n in ["create_note", "update_note"]:
		check(str(by_name[n].inputSchema.properties.markdown.description).contains("```3d"), "%s: markdown description mentions ```3d blocks" % n)

	# The whole guide, as Markdown text (not JSON) the model reads directly.
	var r: Dictionary = call_tool(p, "get_note_guide", {})
	var text: String = r.content[0].text if r.get("content", []).size() > 0 else ""
	check(r.get("isError") == false and text == markup, "get_note_guide: the full guide as the result text")
	check(text.contains("```3d") and text.contains("q:") and text.contains("learn:") and text.contains("[["), "get_note_guide: teaches ```3d, q:, learn: and [[links]]")
	check(data(r).guide == text and data(r).topic == "", "get_note_guide: structuredContent carries the same text")

	# One topic: just its sections, each found by its heading.
	var parts: Dictionary = {}
	for topic in VaultTools.GUIDE_TOPICS:
		var tr: Dictionary = call_tool(p, "get_note_guide", {"topic": topic})
		var tt: String = tr.content[0].text
		parts[topic] = tt
		var heads: Array = VaultTools._guide_headings(tt.split("\n")).map(func(h): return h.text)
		var all_found: bool = true
		for want in VaultTools.GUIDE_TOPICS[topic]:
			if not heads.any(func(h): return (h as String).begins_with(want[0])):
				all_found = false
		check(tr.isError == false and all_found and tt.length() < text.length(), "get_note_guide %s: every section heading found, shorter than the guide" % topic)
	check(parts["3d"].contains("```3d") and parts["3d"].contains("### Object lines") and not parts["3d"].contains("## Journey data"), "topic 3d: the 3D blocks section, presets and object lines")
	check(parts.quiz.contains("```3d") and parts.quiz.contains("a*:") and parts.quiz.contains("learn:") and parts.quiz.contains("objective:") and not parts.quiz.contains("### Flashcards") and not parts.quiz.contains("### Keys for every preset"), "topic quiz: fence intro, quiz keys and objective, not flashcards")
	check(parts.flashcards.contains("### Flashcards") and parts.flashcards.contains("```3d") and not parts.flashcards.contains("### Quiz"), "topic flashcards: fence intro and flashcards, not the quiz")
	check(parts.links.contains("[[Note Title]]") and not parts.links.contains("## 3D blocks"), "topic links: the text markup and [[links]], nothing about 3D")
	check(call_tool(p, "get_note_guide", {"topic": " Quiz "}).content[0].text == parts.quiz, "get_note_guide: topic is trimmed and case-insensitive")
	check(err_code(call_tool(p, "get_note_guide", {"topic": "tables"})) == "invalid_arguments", "get_note_guide: unknown topic → invalid_arguments")
	check(err_code(call_tool(p, "get_note_guide", {"topic": 3})) == "invalid_arguments", "get_note_guide: non-string topic → invalid_arguments")
	var gone: Dictionary = VaultTools.new(V + "no-such-vault/").call_tool("get_note_guide", {})
	check(gone.isError == false and gone.content[0].text == markup, "get_note_guide: works even without a vault")
	# Headings inside a code fence are not sections (```` fences included).
	var fenced: String = VaultTools.guide_topic("## Text\nbody\n````\n```\n# not a heading\n```\n````\n## 3D blocks\n3d body\n", "links")
	check(fenced.contains("# not a heading") and not fenced.contains("3d body"), "guide_topic: a # line inside a fence is not a heading")


# ── The app reads what the server writes ────────────────────────────────────

func test_app_compat(V: String) -> void:
	var p: RefCounted = McpProtocol.new(VaultTools.new(V))
	req(p, "initialize", {"protocolVersion": "2025-06-18"})
	var c: Dictionary = data(call_tool(p, "create_note", {"title": "Seen By App", "markdown": "from the server", "tags": ["x"]}))
	VaultStore.refresh_note_list()
	var i: int = VaultStore.get_note_index("Seen By App")
	var n: ContentLayer = VaultStore.note_list[i] if i >= 0 else null
	check(n != null and n.raw_text == "from the server" and n.tags == ["x"] and n.resource_path == V + c.path, "VaultStore loads a server-created note")
	check(TresValidator.validate(V + c.path).valid, "TresValidator accepts a server-written note")
	data(call_tool(p, "update_note", {"path": c.path, "hash": c.hash, "markdown": "updated by server"}))
	# The app reloads a file whose mtime moved (1 s resolution, so a same-second
	# update may need the next poll); force that path instead of sleeping.
	VaultStore._mtimes[V + c.path] = 0
	VaultStore.refresh_note_list()
	i = VaultStore.get_note_index("Seen By App")
	check(i >= 0 and VaultStore.note_list[i].raw_text == "updated by server", "VaultStore sees a server update after a rescan")
	var rd: Dictionary = data(call_tool(p, "read_note", {"path": c.path}))
	call_tool(p, "delete_note", {"path": c.path, "hash": rd.hash})
	VaultStore.refresh_note_list()
	check(VaultStore.get_note_index("Seen By App") == -1, "VaultStore drops a trashed note")


# ── Control characters: every message stays valid JSON ─────────────────────

## True when `text` is JSON a strict parser (Python's json, JSON.parse in the
## MCP SDKs) accepts. Godot's own parser refuses "\v" but takes raw control
## characters, so those are looked for here.
func strict_json(text: String) -> bool:
	return JSON.new().parse(text) == OK and RegEx.create_from_string("[\\x00-\\x1f]").search(text) == null


## Every reply line `p` gives for `msg`, checked strict (and the JSON text of
## a tool result inside it), parsed back; {} when it is not.
func strict_reply(p: RefCounted, msg: Dictionary, what: String) -> Dictionary:
	var line: String = p.handle_line(McpProtocol.to_json(msg))   # as a client sends it: \u000b, not \v
	var ok: bool = strict_json(line)
	var reply: Variant = JSON.parse_string(line) if ok else null
	var content: Variant = reply.get("result", {}).get("content") if reply is Dictionary and reply.get("result") is Dictionary else null
	if content is Array and not content.is_empty() and content[0].get("type") == "text" and reply.result.has("structuredContent"):
		ok = ok and strict_json(str(content[0].text))
	check(ok, "control chars: %s is valid JSON (%s)" % [what, line.c_escape().left(160)])
	return reply if ok and reply is Dictionary else {}


## A vertical tab (how PowerPoint and Word paste a soft line break) or an
## ANSI colour escape (pasted terminal output) in one note: the replies that
## carry it, and every other note on the same page, are valid JSON, and the
## characters round-trip.
func test_control_chars() -> void:
	var vt: String = char(11)
	var esc: String = char(27)
	var lit: String = "a backslash then v: \\v, then \\" + vt
	check(McpProtocol.to_json({"t": "\\v"}) == "{\"t\":\"\\\\v\"}", "to_json: a backslash followed by the letter v is left as it is")
	check(McpProtocol.to_json({"t": "\\" + vt}) == "{\"t\":\"\\\\\\u000b\"}", "to_json: a backslash then a vertical tab is \\\\ then \\u000b")
	var plain: Dictionary = {"t": "line\nnext\ttab \"q\" ✓ \\ " + char(127)}
	check(McpProtocol.to_json(plain) == JSON.stringify(plain), "to_json: text without control characters is JSON.stringify's, byte for byte")
	var every: String = lit
	for c in range(1, 0x20):
		every += char(c)
	var every_json: String = McpProtocol.to_json({"t": every, every: [every]})
	check(strict_json(every_json) and JSON.parse_string(every_json) == {"t": every, every: [every]}, "to_json: U+0001 to U+001F in keys and values are valid JSON and parse back")

	var dir: String = ProjectSettings.globalize_path("user://test-vault-mcp-control/")
	TestVault.remove_tree(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var p: RefCounted = McpProtocol.new(VaultTools.new(dir))
	req(p, "initialize", {"protocolVersion": "2025-06-18"})
	var slide: String = "Slide title" + vt + "second line"
	var body: String = "a" + vt + "b\n" + esc + "[31mred" + esc + "[0m " + char(1) + char(31) + " " + lit
	var tool: Callable = func(id: int, name: String, args: Dictionary) -> Dictionary:
		return {"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": name, "arguments": args}}
	strict_reply(p, tool.call(1, "create_note", {"title": "Plain 0", "markdown": "x"}), "create_note (plain)")
	var made: Dictionary = strict_reply(p, tool.call(2, "create_note", {"title": slide, "markdown": "from PowerPoint"}), "create_note with a vertical tab in the title")
	check(made.get("result", {}).get("isError") == false, "control chars: that note is created")
	strict_reply(p, tool.call(3, "create_note", {"title": "Terminal Paste", "markdown": body}), "create_note with ESC, U+0001, U+001F and a vertical tab in the body")
	var listed: Dictionary = strict_reply(p, tool.call(4, "list_notes", {}), "the list_notes page")
	var titles: Array = listed.result.structuredContent.notes.map(func(n: Dictionary) -> String: return str(n.get("title"))) if listed.has("result") else []
	check(slide in titles and "Plain 0" in titles, "control chars: list_notes lists the vertical-tab title as written, beside the others (%s)" % [titles.size()])
	var res: Dictionary = strict_reply(p, {"jsonrpc": "2.0", "id": 5, "method": "resources/list"}, "the resources/list page")
	check(res.has("result") and res.result.resources.size() == 3, "control chars: resources/list lists all three notes")
	var read: Dictionary = strict_reply(p, tool.call(6, "read_note", {"path": "note_terminal_paste.tres"}), "read_note of that body")
	check(read.has("result") and read.result.structuredContent.markdown == body, "control chars: read_note round-trips the body exactly")
	var found: Dictionary = strict_reply(p, tool.call(7, "search_notes", {"query": "red"}), "search_notes' snippet of it")
	check(found.has("result") and found.result.structuredContent.notes.size() == 1, "control chars: search_notes finds it")
	var rr: Dictionary = strict_reply(p, {"jsonrpc": "2.0", "id": 8, "method": "resources/read", "params": {"uri": VaultTools.note_uri("note_terminal_paste.tres")}}, "resources/read of it")
	check(rr.has("result") and rr.result.contents[0].text == body, "control chars: resources/read round-trips the body exactly")
	TestVault.remove_tree(dir)


# ── End to end: the stdio server as a subprocess ────────────────────────────

## Start `exe args` with pipes, send `msgs` as JSON lines, collect stdout lines
## until `want` arrived (or 20 s), close stdin and wait for the exit.
## → {started, lines, rest (bytes after the last newline), exited, stderr}.
func _stdio_session(exe: String, args: PackedStringArray, msgs: Array, want: int) -> Dictionary:
	var out: Dictionary = {"started": false, "lines": [], "rest": PackedByteArray(), "exited": false, "stderr": ""}
	var proc: Dictionary = OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return out
	out.started = true
	var io: FileAccess = proc.stdio
	# The pipes are non-blocking: a write the pipe has no room for fails
	# whole. Chunks of at most PIPE_BUF (4096) bytes go in all or nothing, so
	# retry each until the server has read enough to make room.
	var payload: PackedByteArray = PackedByteArray()
	for m in msgs:
		payload.append_array((McpProtocol.to_json(m) + "\n").to_utf8_buffer())
	var at: int = 0
	var send_deadline: int = Time.get_ticks_msec() + 20000
	while at < payload.size() and Time.get_ticks_msec() < send_deadline:
		var piece: PackedByteArray = payload.slice(at, at + 4096)
		if io.store_buffer(piece):
			at += piece.size()
		else:
			await create_timer(0.01).timeout
	io.flush()
	var raw := PackedByteArray()
	var lines: Array[String] = []
	var deadline: int = Time.get_ticks_msec() + 20000
	while lines.size() < want and Time.get_ticks_msec() < deadline:
		var chunk: PackedByteArray = io.get_buffer(65536)
		if chunk.is_empty():
			await create_timer(0.05).timeout
			continue
		raw.append_array(chunk)
		var nl: int = raw.find(10)
		while nl >= 0:
			lines.append(raw.slice(0, nl).get_string_from_utf8())
			raw = raw.slice(nl + 1)
			nl = raw.find(10)
	# Close stdin → the server sees EOF and exits by itself.
	io.close()
	var exit_deadline: int = Time.get_ticks_msec() + 5000
	while OS.is_process_running(proc.pid) and Time.get_ticks_msec() < exit_deadline:
		await create_timer(0.05).timeout
	out.exited = not OS.is_process_running(proc.pid)
	if not out.exited:
		OS.kill(proc.pid)
	if proc.stderr is FileAccess:
		out.stderr = (proc.stderr as FileAccess).get_buffer(65536).get_string_from_utf8()
		(proc.stderr as FileAccess).close()
	out.lines = lines
	out.rest = raw
	return out


## The arguments that run the stdio server on `vault`.
func _server_args(vault: String) -> PackedStringArray:
	return ["--headless", "--no-header", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://mcp/stdio_server.gd", "--", "--vault=" + vault]


func test_stdio_e2e() -> void:
	var dir: String = ProjectSettings.globalize_path("user://test-vault-mcp-e2e/")
	TestVault.remove_tree(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var msgs: Array = [
		{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}}},
		{"jsonrpc": "2.0", "method": "notifications/initialized"},
		{"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
		{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "create_note", "arguments": {"title": "Over Stdio", "markdown": "line one\nline two ✓ \"quoted\""}}},
		{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "read_note", "arguments": {"path": "note_over_stdio.tres"}}},
		{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "get_note_guide", "arguments": {}}},
	]
	var run: Dictionary = await _stdio_session(OS.get_executable_path(), _server_args(dir), msgs, 5)
	check(run.started, "stdio: server process started")
	if not run.started:
		return
	var lines: Array = run.lines
	check(lines.size() == 5, "stdio: 5 replies for 5 requests (+1 notification), got %d" % lines.size())
	var parsed: Array = []
	var strict: bool = lines.size() > 0
	for l in lines:
		var j := JSON.new()
		if j.parse(l) != OK or not (j.data is Dictionary) or j.data.get("jsonrpc") != "2.0":
			strict = false
			print("      not a JSON-RPC line: ", (l as String).c_escape().left(200))
		else:
			parsed.append(j.data)
	check(strict and (run.rest as PackedByteArray).is_empty(), "stdio: every stdout line is a JSON-RPC message (no banner, no logs)")
	if parsed.size() == 5:
		check(int(parsed[0].id) == 1 and parsed[0].result.protocolVersion == "2025-06-18", "stdio: initialize")
		check(int(parsed[1].id) == 2 and parsed[1].result.tools.size() == TOOL_NAMES.size(), "stdio: tools/list")
		check(int(parsed[2].id) == 3 and parsed[2].result.isError == false and FileAccess.file_exists(dir + "note_over_stdio.tres"), "stdio: tools/call create_note wrote the file")
		check(int(parsed[3].id) == 4 and parsed[3].result.structuredContent.markdown == "line one\nline two ✓ \"quoted\"", "stdio: read_note round-trips newlines, quotes, UTF-8")
		check(int(parsed[4].id) == 5 and parsed[4].result.content[0].text == FileAccess.get_file_as_string(MARKUP_MD), "stdio: get_note_guide returns the full guide from res://")
	check(run.exited, "stdio: server exits on stdin EOF")
	check(str(run.stderr).contains("[ontomeme-mcp] serving vault"), "stdio: logs go to stderr")
	check(str(run.stderr).contains("[ontomeme-mcp] client requested protocol 2025-06-18, answered 2025-06-18; clientInfo {\"name\":\"e2e\",\"version\":\"1\"}"), "stdio: stderr logs the client's requested protocol version and clientInfo")
	check(not FileAccess.file_exists(dir + ".ontomeme/app.lock"), "stdio: the server leaves no app.lock (only the app's window holds one)")
	TestVault.remove_tree(dir)


## Elicitation over real stdio: the request is a line of its own, between the
## replies, and the answer the client writes back settles the tools/call.
## Then the same server with --confirm-writes=off asks nothing.
func test_stdio_elicitation() -> void:
	var dir: String = ProjectSettings.globalize_path("user://test-vault-mcp-elicit/")
	TestVault.remove_tree(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	for f in ["gone.txt", "kept.txt"]:
		var w: FileAccess = FileAccess.open(dir + f, FileAccess.WRITE)
		w.store_string("note " + f + "\n")
		w.close()
	var gone_hash: String = FileAccess.get_sha256(dir + "gone.txt")
	var kept_hash: String = FileAccess.get_sha256(dir + "kept.txt")
	var init: Dictionary = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {"elicitation": {}}}}
	var msgs: Array = [
		init,
		{"jsonrpc": "2.0", "method": "notifications/initialized"},
		{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "delete_note", "arguments": {"path": "gone.txt", "hash": gone_hash}}},
		{"jsonrpc": "2.0", "id": "s-1", "result": {"action": "accept", "content": {"confirm": true}}},
		{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "update_note", "arguments": {"path": "kept.txt", "hash": kept_hash, "markdown": "replaced"}}},
		{"jsonrpc": "2.0", "id": "s-2", "result": {"action": "decline"}},
	]
	var run: Dictionary = await _stdio_session(OS.get_executable_path(), _server_args(dir), msgs, 5)
	var got: Array = []
	for l in run.lines:
		got.append(JSON.parse_string(l))
	var shape: Array = got.map(func(m: Variant) -> String:
		if not (m is Dictionary):
			return "?"
		return str(m.method) if m.has("method") else str(int(m.id)) if m.get("id") is float else str(m.get("id")))
	check(shape == ["1", "elicitation/create", "2", "elicitation/create", "3"], "stdio confirm: initialize, a request, its call's response, a request, its call's response, in order (%s)" % [shape])
	if shape.size() == 5:
		check(str(got[0].result.get("instructions", "")).contains("Confirmations are on"), "stdio confirm: initialize states the mode")
		check(got[1].id == "s-1" and str(got[1].params.message).contains("gone.txt") and got[3].id == "s-2", "stdio confirm: each request is a line of its own with its string id")
		check(got[2].result.isError == false and not FileAccess.file_exists(dir + "gone.txt") and FileAccess.file_exists(dir + ".trash/gone.txt"), "stdio confirm: accepted → trashed")
		check(got[4].result.structuredContent.error.code == "declined" and FileAccess.get_sha256(dir + "kept.txt") == kept_hash, "stdio confirm: declined → untouched")
	check(str(run.stderr).contains("[ontomeme-mcp] confirmations on"), "stdio confirm: the server logs the mode")

	var off_args: PackedStringArray = _server_args(dir)
	off_args.append("--confirm-writes=off")
	var off_run: Dictionary = await _stdio_session(OS.get_executable_path(), off_args, [
		init,
		{"jsonrpc": "2.0", "method": "notifications/initialized"},
		{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "delete_note", "arguments": {"path": "kept.txt", "hash": kept_hash}}},
	], 2)
	var off_got: Array = []
	for l in off_run.lines:
		off_got.append(JSON.parse_string(l))
	check(off_got.size() == 2 and str(off_got[0].result.get("instructions", "")).contains("Confirmations are off") and off_got[1].get("id") == 2.0 and off_got[1].result.isError == false
			and not FileAccess.file_exists(dir + "kept.txt"), "stdio confirm: --confirm-writes=off → the call answers at once, nothing asked (%s)" % [off_run.lines])
	check(str(off_run.stderr).contains("[ontomeme-mcp] confirmations off"), "stdio confirm: the server logs the mode (off)")
	TestVault.remove_tree(dir)


## The same over real stdio, through both of the transport's writes: the
## replies, and what the protocol sends on its own (the confirmation prompt
## quoting the new text, the call's late result).
func test_stdio_control_chars() -> void:
	var dir: String = ProjectSettings.globalize_path("user://test-vault-mcp-control-stdio/")
	TestVault.remove_tree(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var w: FileAccess = FileAccess.open(dir + "kept.txt", FileAccess.WRITE)
	w.store_string("kept\n")
	w.close()
	var kept_hash: String = FileAccess.get_sha256(dir + "kept.txt")
	var vt: String = char(11)
	var esc: String = char(27)
	var slide: String = "Slide title" + vt + "second line"
	var msgs: Array = [
		{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {"elicitation": {}}}},
		{"jsonrpc": "2.0", "method": "notifications/initialized"},
		{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "create_note", "arguments": {"title": slide, "markdown": "from PowerPoint"}}},
		{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "list_notes", "arguments": {}}},
		{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "update_note", "arguments": {"path": "kept.txt", "hash": kept_hash, "markdown": "new" + vt + "line " + esc + "[1mbold"}}},
		{"jsonrpc": "2.0", "id": "s-1", "result": {"action": "decline"}},
	]
	var run: Dictionary = await _stdio_session(OS.get_executable_path(), _server_args(dir), msgs, 5)
	check(run.lines.size() == 5, "stdio control chars: 5 lines (3 replies, a prompt, a late result), got %d" % run.lines.size())
	var bad: Array = run.lines.filter(func(l: String) -> bool: return not strict_json(l))
	check(run.lines.size() == 5 and bad.is_empty(), "stdio control chars: every line is valid JSON %s" % [bad.map(func(l: String) -> String: return l.c_escape().left(120))])
	if bad.is_empty() and run.lines.size() == 5:
		var got: Array = run.lines.map(func(l: String) -> Variant: return JSON.parse_string(l))
		check(got[2].result.structuredContent.notes.any(func(n: Dictionary) -> bool: return n.get("title") == slide), "stdio control chars: list_notes carries the title as written")
		check(got[3].get("method") == "elicitation/create" and str(got[3].params.message).contains("line " + esc + "[1mbold"), "stdio control chars: the prompt quotes the new text as written")
		check(got[4].get("id") == 4.0 and got[4].result.structuredContent.error.code == "declined", "stdio control chars: the late result arrives (declined)")
	TestVault.remove_tree(dir)


## A write that fails partway (disk full, quota, a network share) must be
## refused and leave the note alone, never rename a truncated temp file over
## it. Reproduced with a real short write: the stdio server runs under
## `ulimit -f 100` (102,400 bytes per file) with SIGXFSZ ignored, so writes
## past the limit fail with EFBIG, and is asked to write ~250 KB notes.
func test_short_write() -> void:
	if OS.get_name() == "Windows" or OS.execute("bash", ["-c", "exit 0"]) != 0:
		print("SKIP  short write: needs bash and ulimit")
		return
	var dir: String = ProjectSettings.globalize_path("user://test-vault-mcp-shortwrite/")
	TestVault.remove_tree(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var old_text: String = "a line of the note, kept whole\n".repeat(1700)   # 51,000 bytes: under the limit
	var w: FileAccess = FileAccess.open(dir + "big.txt", FileAccess.WRITE)
	w.store_string(old_text)
	w.close()
	var old_hash: String = FileAccess.get_sha256(dir + "big.txt")
	var huge: String = "x".repeat(200000)
	# A .tres the same size, as the baseline: ResourceSaver already refuses.
	var n := ContentLayer.new()
	n.title = "Big Tres"
	n.raw_text = old_text
	n.structure = {}
	ResourceSaver.save(n, dir + "note_big_tres.tres")
	var tres_hash: String = FileAccess.get_sha256(dir + "note_big_tres.tres")
	var msgs: Array = [
		{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
		{"jsonrpc": "2.0", "method": "notifications/initialized"},
		{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "update_note", "arguments": {"path": "big.txt", "hash": old_hash, "markdown": old_text + huge}}},
		{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "create_note", "arguments": {"title": "Huge", "markdown": huge, "format": "text"}}},
		{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "update_note", "arguments": {"path": "note_big_tres.tres", "hash": tres_hash, "markdown": old_text + huge}}},
	]
	var by_id: Dictionary = await _limited_session(dir, 100, msgs, 4)
	check(by_id.size() == 4, "short write: the size-limited server answered all 4 requests (%d)" % by_id.size())
	var upd: Dictionary = by_id.get(2, {})
	check(err_code(upd) == "write_failed", "short write: update_note on a .txt → write_failed, not success (%s)" % [upd.get("structuredContent", {})])
	check(FileAccess.get_sha256(dir + "big.txt") == old_hash, "short write: the .txt note keeps its old bytes (%d bytes on disk)" % FileAccess.get_file_as_bytes(dir + "big.txt").size())
	var cr: Dictionary = by_id.get(3, {})
	check(err_code(cr) == "write_failed" and not FileAccess.file_exists(dir + "note_huge.txt"), "short write: create_note text → write_failed, no truncated note left")
	var tr: Dictionary = by_id.get(4, {})
	check(err_code(tr) == "write_failed" and FileAccess.get_sha256(dir + "note_big_tres.tres") == tres_hash, "short write: update_note on a .tres → write_failed, note unchanged (as before)")
	var tmp_left: PackedStringArray = DirAccess.get_files_at(dir + ".ontomeme/tmp") if DirAccess.dir_exists_absolute(dir + ".ontomeme/tmp") else PackedStringArray()
	check(tmp_left.is_empty(), "short write: no temp files left behind (%s)" % [tmp_left])
	TestVault.remove_tree(dir)


## The same failure for a normal-sized note, the common case. Under
## `ulimit -f 1` (1,024 bytes) a 3,000-byte write still fits the stdio buffer,
## so store_buffer() returns true and flush() reports nothing: the error only
## happens when the buffer is written out, and only checking the temp file's
## contents catches it. That holds for .txt and for .tres (ResourceSaver
## returns OK and leaves a truncated file that no longer parses).
func test_short_write_small() -> void:
	if OS.get_name() == "Windows" or OS.execute("bash", ["-c", "exit 0"]) != 0:
		print("SKIP  small short write: needs bash and ulimit")
		return
	var dir: String = ProjectSettings.globalize_path("user://test-vault-mcp-shortwrite-small/")
	TestVault.remove_tree(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	for f in ["s.txt", "ok.txt"]:
		var w: FileAccess = FileAccess.open(dir + f, FileAccess.WRITE)
		w.store_string("a short note.\n")
		w.close()
	var s_hash: String = FileAccess.get_sha256(dir + "s.txt")
	var ok_hash: String = FileAccess.get_sha256(dir + "ok.txt")
	# Two small .tres notes (a few hundred bytes). ResourceSaver checks for an
	# error before it closes the file, so it misses this one too. The second
	# has tags and a structure with floats, so the write that fits proves the
	# check of the saved file accepts what it should.
	for t in [["Small Tres", "note_small_tres.tres", {}], ["Fit Tres", "note_fit_tres.tres", {"pos": [0.1, 2.5, -3.75], "n": 7}]]:
		var n := ContentLayer.new()
		n.title = t[0]
		n.raw_text = "a short note."
		n.tags = ["kept"]
		n.structure = t[2]
		n.created = "2026-11-07T10:00:00"
		n.modified = n.created
		ResourceSaver.save(n, dir + t[1])
	var tres_hash: String = FileAccess.get_sha256(dir + "note_small_tres.tres")
	var fit_hash: String = FileAccess.get_sha256(dir + "note_fit_tres.tres")
	var body: String = "y".repeat(3000)
	var msgs: Array = [
		{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
		{"jsonrpc": "2.0", "method": "notifications/initialized"},
		{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "update_note", "arguments": {"path": "s.txt", "hash": s_hash, "markdown": body}}},
		{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "create_note", "arguments": {"title": "Small Text", "markdown": body, "format": "text"}}},
		{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "update_note", "arguments": {"path": "ok.txt", "hash": ok_hash, "markdown": "fits under the limit\n"}}},
		{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "update_note", "arguments": {"path": "note_small_tres.tres", "hash": tres_hash, "markdown": body}}},
		{"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "create_note", "arguments": {"title": "Small New Tres", "markdown": body}}},
		{"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "update_note", "arguments": {"path": "note_fit_tres.tres", "hash": fit_hash, "markdown": "fits"}}},
	]
	var by_id: Dictionary = await _limited_session(dir, 1, msgs, 7)
	check(by_id.size() == 7, "small short write: the size-limited server answered all 7 requests (%d)" % by_id.size())
	var upd: Dictionary = by_id.get(2, {})
	check(err_code(upd) == "write_failed", "small short write: update_note on a .txt → write_failed, not success (%s)" % [upd.get("structuredContent", {})])
	check(FileAccess.get_sha256(dir + "s.txt") == s_hash, "small short write: the .txt note keeps its old bytes (%d bytes on disk)" % FileAccess.get_file_as_bytes(dir + "s.txt").size())
	var cr: Dictionary = by_id.get(3, {})
	check(err_code(cr) == "write_failed" and not FileAccess.file_exists(dir + "note_small_text.txt"), "small short write: create_note text → write_failed, no truncated note left (%s)" % [cr.get("structuredContent", {})])
	var fit: Dictionary = by_id.get(4, {})
	check(fit.get("isError", true) == false and FileAccess.get_file_as_string(dir + "ok.txt") == "fits under the limit\n", "small short write: a .txt write that fits the limit still succeeds")
	var tu: Dictionary = by_id.get(5, {})
	check(err_code(tu) == "write_failed", "small short write: update_note on a .tres → write_failed, not success (%s)" % [tu.get("structuredContent", {})])
	check(FileAccess.get_sha256(dir + "note_small_tres.tres") == tres_hash, "small short write: the .tres note keeps its old bytes (%d bytes on disk)" % FileAccess.get_file_as_bytes(dir + "note_small_tres.tres").size())
	var tc: Dictionary = by_id.get(6, {})
	check(err_code(tc) == "write_failed" and not FileAccess.file_exists(dir + "note_small_new_tres.tres"), "small short write: create_note .tres → write_failed, no truncated note left (%s)" % [tc.get("structuredContent", {})])
	var tf: Dictionary = by_id.get(7, {})
	var fitted: ContentLayer = ResourceLoader.load(dir + "note_fit_tres.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as ContentLayer
	check(tf.get("isError", true) == false and fitted != null and fitted.raw_text == "fits" and fitted.title == "Fit Tres"
			and Array(fitted.tags) == ["kept"] and fitted.structure == {"pos": [0.1, 2.5, -3.75], "n": 7},
			"small short write: a .tres write that fits the limit still succeeds, every field intact (%s)" % [tf.get("structuredContent", {})])
	var tmp_left: PackedStringArray = DirAccess.get_files_at(dir + ".ontomeme/tmp") if DirAccess.dir_exists_absolute(dir + ".ontomeme/tmp") else PackedStringArray()
	check(tmp_left.is_empty(), "small short write: no temp files left behind (%s)" % [tmp_left])
	# A .tres cut off at a line boundary still parses, with the properties
	# after the cut back at their defaults: the field comparison catches that.
	var whole := ContentLayer.new()
	whole.title = "Cut"
	whole.raw_text = "kept"
	whole.structure = {"pos": [0.5]}
	ResourceSaver.save(whole, dir + "cut.tres")
	var full_text: String = FileAccess.get_file_as_string(dir + "cut.tres")
	var tools: RefCounted = VaultTools.new(dir)
	check(tools._saved_matches(whole, dir + "cut.tres"), "saved check: a whole .tres matches its note")
	var cw: FileAccess = FileAccess.open(dir + "cut.tres", FileAccess.WRITE)
	cw.store_string(full_text.left(full_text.find("structure =")))
	cw.close()
	var cut_back: ContentLayer = ResourceLoader.load(dir + "cut.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as ContentLayer
	check(cut_back != null and cut_back.structure.is_empty() and not tools._saved_matches(whole, dir + "cut.tres"),
			"saved check: a .tres cut before its last property loads but does not match")
	TestVault.remove_tree(dir)


## Run the stdio server on `dir` under `ulimit -f <blocks>` (1,024-byte
## blocks) with SIGXFSZ ignored, so a write past the limit fails with EFBIG the
## way a full disk or a quota does. → each request's result by its id.
func _limited_session(dir: String, blocks: int, msgs: Array, want: int) -> Dictionary:
	var limited: PackedStringArray = ["-c", "trap '' XFSZ; ulimit -f %d; exec \"$0\" \"$@\"" % blocks, OS.get_executable_path()]
	limited.append_array(_server_args(dir))
	var run: Dictionary = await _stdio_session("bash", limited, msgs, want)
	var by_id: Dictionary = {}
	for l in run.lines:
		var j: Variant = JSON.parse_string(l)
		if j is Dictionary and j.has("id") and j.has("result"):
			by_id[int(j.id)] = j.result
	return by_id
