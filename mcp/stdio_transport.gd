extends Node
## stdio transport for the MCP protocol core: newline-delimited JSON-RPC on
## stdin/stdout. A Node, so any entry point can host it: the `-s` script
## (mcp/stdio_server.gd, editor builds) or a startup hook in the shipped app
## (release templates ignore `-s`; see mcp/README.md).
##   var t := StdioTransport.new(); t.protocol = proto; root.add_child(t)
##
## stdout must carry protocol bytes only: run Godot with `--no-header` (the
## engine banner goes to stdout otherwise) and never `--quiet` (it silences
## print(), which is how replies are written). Logs go to stderr. Godot also
## copies both into its log file, and replies hold note text: launch with
## DesktopConfig.LOG_ARGS (`--log-file user://logs/mcp.log`) so they stay out
## of godot.log, the app's own log.
##
## Every stdin read in Godot blocks, so a worker thread reads; messages are
## handled here on the main thread, one at a time. EOF on stdin quits the tree.
## What the protocol sends on its own (its `outgoing` signal: requests to the
## client, results that came later) is written the same way, one line each,
## in the order it is emitted, and each frame calls the protocol's tick() so
## an unanswered request times out.

const McpProtocol = preload("res://mcp/protocol.gd")

signal stdin_closed

var protocol: RefCounted:
	set(p):
		if protocol != null and protocol.has_signal("outgoing") and protocol.outgoing.is_connected(_send):
			protocol.outgoing.disconnect(_send)
		protocol = p
		if protocol != null and protocol.has_signal("outgoing"):
			protocol.outgoing.connect(_send)
## Quit the SceneTree when stdin closes (the client went away).
var quit_on_eof: bool = true

var _reader: Thread
var _mutex := Mutex.new()
var _lines: Array[String] = []
var _eof: bool = false
var _done: bool = false


func _ready() -> void:
	_reader = Thread.new()
	_reader.start(_read_stdin)


func _read_stdin() -> void:
	# OS.read_buffer_from_stdin(n) behaves like fread: it blocks until n bytes
	# or EOF, so a 64 KiB read would sit on a short request forever. Reading
	# one byte at a time returns as soon as a byte arrives (about 1 MB per
	# 80 ms). OS.read_string_from_stdin is line-based but returns "" for both
	# a blank line and EOF, and splits long lines without saying so.
	# An empty buffer means EOF.
	var line := PackedByteArray()
	while true:
		var b: PackedByteArray = OS.read_buffer_from_stdin(1)
		if b.is_empty():
			break
		if b[0] == 10:
			_push(line.get_string_from_utf8())
			line.clear()
		else:
			line.append(b[0])
	if not line.is_empty():   # last message without a trailing newline
		_push(line.get_string_from_utf8())
	_mutex.lock()
	_eof = true
	_mutex.unlock()


func _push(line: String) -> void:
	_mutex.lock()
	_lines.append(line)
	_mutex.unlock()


func _process(_delta: float) -> void:
	if _done:
		return
	_mutex.lock()
	var lines: Array[String] = _lines.duplicate()
	_lines.clear()
	var eof: bool = _eof
	_mutex.unlock()
	for line in lines:
		_handle(line.strip_edges())
	if protocol != null and protocol.has_method("tick"):
		protocol.tick(Time.get_ticks_msec())
	if eof:
		_done = true
		_reader.wait_to_finish()
		stdin_closed.emit()
		if quit_on_eof:
			get_tree().quit(0)


func _handle(line: String) -> void:
	if line == "" or protocol == null:
		return
	var reply: String = protocol.handle_line(line)
	if reply != "":
		# McpProtocol.to_json escapes every control character, so a reply is
		# one line of valid JSON.
		print(reply)


## One message the protocol sent on its own, as one line. Written from the
## main thread only, so lines never interleave; emitted on another thread it
## waits for the next frame.
func _send(message: Dictionary) -> void:
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		_send.call_deferred(message)
		return
	print(McpProtocol.to_json(message))


func _exit_tree() -> void:
	# A thread blocked in a stdin read can't be interrupted; only wait for it
	# when it has already finished.
	if _reader != null and _reader.is_started() and not _reader.is_alive():
		_reader.wait_to_finish()
