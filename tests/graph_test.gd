extends SceneTree
## The 2D graph (GraphLayer in note.tscn): nodes keyed by each note's file,
## not its place in VaultStore.note_list (which the disk watcher re-sorts), a
## live rebuild when the vault changes on disk, a ring on the open note, the
## text filter and the Local view.
##   headless:  godot --headless --path . -s res://tests/graph_test.gd

const TestVault = preload("res://tests/test_vault.gd")

var fails: int = 0
var app: Control
var graph: GraphLayer


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


## A note saved with a chosen `modified`, so the sidebar order is known.
func make(title: String, body: String, modified: String) -> ContentLayer:
	var note: ContentLayer = VaultStore.create_note(title)
	note.raw_text = body
	note.modified = modified
	VaultStore.save_note(note, false)
	return note


## Another program rewrites a note's file (Claude via MCP, a sync tool).
func outside_edit(path: String, from: String, to: String) -> void:
	var text: String = FileAccess.get_file_as_string(path)
	check(text.contains(from), "(outside edit finds \"%s\" on disk)" % from)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text.replace(from, to))
	f.close()


func note_titled(title: String) -> ContentLayer:
	var idx: int = VaultStore.get_note_index(title)
	return VaultStore.note_list[idx] if idx >= 0 else null


func sorted(a: Array) -> Array:
	var out: Array = a.duplicate()
	out.sort()
	return out


func titles_of(keys: Array) -> Array:
	return sorted(keys.map(func(k: String) -> String: return str(graph._nodes[k].title)))


## The graph's key for the node titled `title` (what a double-click on it
## sends), or "".
func key_titled(title: String) -> String:
	for k in graph._nodes:
		if graph._nodes[k].title == title:
			return k
	return ""


func has_edge(from: ContentLayer, to: ContentLayer) -> bool:
	return graph._edges.any(func(e: Dictionary) -> bool: return e.from == from.resource_path and e.to == to.resource_path)


## Real mouse input: move to `pos` (global), then press and release there.
func click_at(pos: Vector2, double: bool = false) -> void:
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.double_click = double and pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	await frames(2)


func click(c: Control) -> void:
	await click_at(c.get_global_rect().get_center())


## Key events, as a keyboard sends them, to whatever has focus.
func type_keys(text: String) -> void:
	for ch in text:
		var e := InputEventKey.new()
		e.keycode = OS.find_keycode_from_string(ch.to_upper())
		e.unicode = ch.unicode_at(0)
		e.pressed = true
		get_root().push_input(e)
		var up: InputEventKey = e.duplicate()
		up.pressed = false
		get_root().push_input(up)
	await frames(2)


func press(code: Key) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	get_root().push_input(e)
	await frames(2)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_graph.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_graph.json"
	ProgressStore.reset()
	var vault: String = TestVault.open("graph", false)

	# ── One note graphs as one node ──
	var solo: ContentLayer = make("Solo", "Nothing links out.", "2026-01-01T09:00:00")
	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(6)
	graph = app.graph_layer
	app._switch_layer("graph")
	await frames(3)
	check(graph.drawn_keys() == [solo.resource_path], "a 1-note vault graphs 1 node (%s)" % [graph.drawn_keys()])
	check(graph.current_key == solo.resource_path, "current_key is the open note's path (%s)" % graph.current_key)

	# ── Notes made elsewhere appear while the graph stays open ──
	var hub: ContentLayer = make("Hub", "Start with [[Tutor Notes]].", "2026-01-01T10:00:00")
	var tutorial: ContentLayer = make("Tutorial One", "Back to [[Hub]].", "2026-01-01T11:00:00")
	var tutor: ContentLayer = make("Tutor Notes", "No links.", "2026-01-01T12:00:00")
	var statute: ContentLayer = make("Statute", "No links either.", "2026-01-01T13:00:00")
	var leaf: ContentLayer = make("Leaf", "Up to [[Hub]].", "2026-01-01T14:00:00")
	app.check_disk_changes()
	await frames(2)
	check(app.current_mode == "graph" and graph._nodes.size() == 6 and graph._edges.size() == 3, "check_disk_changes in graph mode rebuilds the graph: 6 nodes, 3 links (%d, %d)" % [graph._nodes.size(), graph._edges.size()])

	# ── A node is its note's file: an outside re-sort changes nothing ──
	app._open_note(tutorial)
	app._switch_layer("graph")
	await frames(3)
	check(graph.current_key == tutorial.resource_path, "current_key follows the open note (Tutorial One)")
	var hub_key: String = hub.resource_path
	check(graph._nodes.has(hub_key) and graph._nodes[hub_key].title == "Hub", "nodes are keyed by note path (%s)" % hub_key)
	check(has_edge(tutorial, hub) and has_edge(hub, tutor), "edges join note paths: Tutorial One -> Hub -> Tutor Notes")
	var old_index: int = VaultStore.note_list.find(hub)
	await create_timer(1.1).timeout   # mtime is per second
	outside_edit(solo.resource_path, "2026-01-01T09:00:00", "2026-02-01T09:00:00")
	outside_edit(solo.resource_path, "Nothing links out.", "Now cites [[Hub]].")
	app.check_disk_changes()
	await frames(2)
	solo = note_titled("Solo")
	check(VaultStore.note_list.find(note_titled("Hub")) != old_index, "(Solo edited outside went to the top: Hub moved from index %d to %d)" % [old_index, VaultStore.note_list.find(note_titled("Hub"))])
	check(has_edge(solo, hub), "…and the open graph was rebuilt: Solo -> Hub is drawn")
	check(app.current_mode == "graph" and graph.visible and graph.current_key == tutorial.resource_path, "…the graph stays open, still ringing Tutorial One")
	graph.node_clicked.emit(hub_key)
	await frames(2)
	check(app.current_note != null and app.current_note.title == "Hub" and app.current_note.resource_path == hub_key, "node_clicked(Hub's key) still opens Hub (%s)" % (app.current_note.title if app.current_note else "none"))
	graph.node_clicked.emit(vault + "no-such-note.tres")
	await frames(1)
	check(app.current_note.title == "Hub", "a key with no note behind it opens nothing")

	# ── An outside edit of the open note keeps the graph open ──
	app._switch_layer("graph")
	await frames(3)
	await create_timer(1.1).timeout
	outside_edit(hub_key, "Start with [[Tutor Notes]].", "Start with [[Tutor Notes]], then [[Leaf]].")
	app.check_disk_changes()
	await frames(2)
	hub = note_titled("Hub")
	check(app.current_mode == "graph" and graph.visible and not app.note_content.visible and graph.current_key == hub_key, "an outside edit of the open note leaves the graph open on it (%s)" % app.current_mode)
	check(app.current_note == hub and app.raw_text_layer.text.contains("[[Leaf]]") and has_edge(hub, leaf), "…with the new text loaded and Hub -> Leaf drawn")

	# ── The filter dims every note whose title lacks the text ──
	var filter: LineEdit = graph.filter_edit
	check(filter != null and filter.visible and filter.get_global_rect().position.x - graph.get_global_rect().position.x < 40.0, "a filter box sits at the graph's top-left")
	await click(filter)
	check(filter.has_focus(), "a click focuses the filter box")
	await type_keys("tut")
	check(filter.text == "tut", "key events type into it (%s)" % filter.text)
	var lit: Array = titles_of(graph._nodes.keys().filter(func(k: String) -> bool: return graph.matches(k)))
	check(lit == ["Statute", "Tutor Notes", "Tutorial One"], "typing 'tut' leaves only titles containing it un-dimmed (%s)" % [lit])
	check(not graph.matches(hub_key) and graph.drawn_keys().size() == 6, "…dims the others without hiding them")
	await press(KEY_ESCAPE)
	check(filter.text == "" and graph._nodes.keys().all(func(k: String) -> bool: return graph.matches(k)), "Escape clears the filter")
	app._switch_layer("graph")   # current note unchanged: still Hub
	await frames(3)

	# ── Local: the open note and its neighbours only ──
	var toggle: Button = graph.local_toggle
	await click(toggle)
	check(graph.local and toggle.button_pressed, "a click turns Local on")
	var want: Array = sorted([hub, tutor, leaf, tutorial, solo].map(func(n: ContentLayer) -> String: return n.resource_path))
	check(sorted(graph.drawn_keys()) == want, "Local draws Hub and its neighbours, links in and out (%s)" % [titles_of(graph.drawn_keys())])
	check(not graph.drawn_keys().has(statute.resource_path), "…and not Statute, which links to nothing")
	app._open_note(statute)
	app._switch_layer("graph")
	await frames(3)
	check(graph.drawn_keys() == [statute.resource_path], "Local around a note with no links draws it alone")
	await click(toggle)
	check(not graph.local and graph.drawn_keys().size() == 6, "a second click shows every note again")

	# ── A real double-click on a node opens its note ──
	graph._zoom = 0.5
	graph.queue_redraw()
	await frames(1)
	var spot: Vector2 = graph.get_global_transform_with_canvas() * graph._to_screen(graph._nodes[hub_key].pos)
	check(graph.get_global_rect().has_point(spot), "(Hub's node is on screen at %s)" % spot)
	await click_at(spot)
	await click_at(spot, true)
	check(app.current_note != null and app.current_note.resource_path == hub_key and app.current_mode == "raw", "double-clicking Hub's node opens Hub (%s)" % (app.current_note.title if app.current_note else "none"))

	# ── The app's own moves and renames redraw the open graph ──
	# Each one sets _last_sig, so the disk watcher never sees it: the graph
	# must hear of it itself, or its nodes keep the old paths and open nothing.
	app._open_note(hub)
	app._switch_layer("graph")
	await frames(3)
	check(app.create_folder("Archive") == "Archive", "(a folder to move notes into)")
	var leaf_old: String = leaf.resource_path
	graph._nodes[leaf_old].pos = Vector2(6000, 0)   # far off: a node that kept its place is easy to tell
	check(app.move_note_to(leaf, "Archive"), "(Move to: Leaf into Archive with the graph open)")
	app.check_disk_changes()
	check(app.current_mode == "graph" and not graph._nodes.has(leaf_old) and graph._nodes.has(leaf.resource_path), "a sidebar Move to re-keys Leaf's node to its new file (%s)" % leaf.resource_path.get_base_dir().get_file())
	check(has_edge(hub, leaf) and has_edge(leaf, hub), "…with its links still drawn")
	check(graph._nodes.has(leaf.resource_path) and graph._nodes[leaf.resource_path].pos.length() > 1000.0, "…and the node keeps its place")
	graph.node_clicked.emit(key_titled("Leaf"))
	await frames(2)
	check(app.current_note == leaf, "double-clicking the moved node opens Leaf (%s; %s)" % [app.current_note.title if app.current_note else "none", app.status_label.text])

	app._open_note(hub)
	app._switch_layer("graph")
	await frames(3)
	var leaf_in_archive: String = leaf.resource_path
	check(app.rename_folder("Archive", "Old Stuff") == "Old Stuff", "(folder Archive renamed to Old Stuff with the graph open)")
	check(not graph._nodes.has(leaf_in_archive) and graph._nodes.has(leaf.resource_path) and leaf.resource_path.contains("/Old Stuff/"), "a folder rename re-keys the nodes of the notes inside it")
	graph.node_clicked.emit(key_titled("Leaf"))
	await frames(2)
	check(app.current_note == leaf, "double-clicking a note in the renamed folder opens it (%s; %s)" % [app.current_note.title if app.current_note else "none", app.status_label.text])

	# The sidebar's Rename on the open note (F2, its menu) keeps the graph open.
	app._open_note(hub)
	app._switch_layer("graph")
	await frames(3)
	var hub_old: String = hub.resource_path
	app._rename_note_prompt(hub)
	await frames(1)
	app._prompt_edit.text = "Hub Renamed"
	app._on_prompt_confirmed()
	await frames(2)
	check(hub.title == "Hub Renamed" and hub.resource_path != hub_old, "(Hub renamed from the sidebar with the graph open)")
	check(app.current_mode == "graph" and graph.visible and not graph._nodes.has(hub_old) and graph._nodes.has(hub.resource_path), "renaming the open note re-keys its node to its new file")
	check(graph._nodes.has(hub.resource_path) and graph._nodes[hub.resource_path].title == "Hub Renamed" and graph.current_key == hub.resource_path, "…which shows the new title and still wears the ring")
	check(has_edge(tutorial, hub) and has_edge(solo, hub) and has_edge(hub, tutor), "…with the links the rename rewrote still drawn")
	graph.node_clicked.emit(key_titled("Hub Renamed"))
	await frames(2)
	check(app.current_note == hub and app.current_mode == "raw", "double-clicking the renamed node opens it (%s; %s)" % [app.current_note.title if app.current_note else "none", app.status_label.text])

	# A note that links to itself is reloaded after its rename: still in the graph.
	var mirror: ContentLayer = make("Mirror", "See [[Mirror]].", "2026-01-01T15:00:00")
	app.check_disk_changes()
	app._open_note(mirror)
	app._switch_layer("graph")
	await frames(3)
	app._rename_note_prompt(mirror)
	await frames(1)
	app._prompt_edit.text = "Looking Glass"
	app._on_prompt_confirmed()
	await frames(2)
	check(app.raw_text_layer.text.contains("[[Looking Glass]]"), "(Mirror's own link was rewritten: %s)" % app.raw_text_layer.text)
	check(app.current_mode == "graph" and graph.visible and graph.current_key == mirror.resource_path and graph._nodes[mirror.resource_path].title == "Looking Glass", "renaming a self-linking open note leaves the graph open on it (%s)" % app.current_mode)

	# A path changed under a graph that has not heard of it: the node opens
	# the note it was drawn for while the vault still holds that note.
	var stale_key: String = leaf.resource_path
	check(VaultStore.move_note(leaf, ""), "(Leaf moved by the store alone; the graph still has %s)" % stale_key.get_file())
	check(graph._nodes.has(stale_key) and not FileAccess.file_exists(stale_key), "(…so its node's key names no file)")
	graph.node_clicked.emit(stale_key)
	await frames(2)
	check(app.current_note == leaf, "double-clicking a node whose file moved opens the note it was drawn for (%s; %s)" % [app.current_note.title if app.current_note else "none", app.status_label.text])

	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	TestVault.remove_tree(vault)
	quit(1 if fails else 0)
