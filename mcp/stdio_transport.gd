extends Node
## stdio transport for the MCP protocol core: newline-delimited JSON-RPC on
## stdin/stdout. A Node, so any entry point can host it: the `-s` script
## (mcp/stdio_server.gd, editor builds) or a startup hook in the shipped app
## (release templates ignore `-s`; see mcp/README.md).
##   var t := StdioTransport.new(); t.protocol = proto; root.add_child(t)
##
## stdout must carry protocol bytes only: run Godot with `--no-header` (the
## engine banner goes to stdout otherwise) and never `--quiet` (it silences
## print(), which is how replies are written). Logs go to stderr.
##
## Every stdin read in Godot blocks, so a worker thread reads; messages are
## handled here on the main thread, one at a time. EOF on stdin quits the tree.

signal stdin_closed

var protocol: RefCounted
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
		# JSON.stringify escapes control characters, so a reply is one line.
		print(reply)


func _exit_tree() -> void:
	# A thread blocked in a stdin read can't be interrupted; only wait for it
	# when it has already finished.
	if _reader != null and _reader.is_started() and not _reader.is_alive():
		_reader.wait_to_finish()
