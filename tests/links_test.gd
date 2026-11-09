extends SceneTree
## [[Links]]: the one WikiLinks parser and resolver, and what uses it (Read
## view links, link clicks, the 2D and 3D graphs).
##   headless:  godot --headless --path . -s res://tests/links_test.gd

const TestVault = preload("res://tests/test_vault.gd")

var fails: int = 0
var app: Control


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func make(title: String, body: String, folder: String = "") -> ContentLayer:
	var note: ContentLayer = VaultStore.create_note(title, folder)
	note.raw_text = body
	VaultStore.save_note(note)
	return note


func drop(note: ContentLayer) -> void:
	VaultStore.delete_note(VaultStore.note_list.find(note))


func targets(text: String) -> Array:
	return WikiLinks.spans(text).map(func(s: Dictionary) -> String: return s.target)


func titles(notes: Array[ContentLayer]) -> Array:
	return notes.map(func(n: ContentLayer) -> String: return n.title)


func title_of(note: ContentLayer) -> String:
	return note.title if note != null else "<null>"


## Read view rows (RichTextLabel BBCode) that contain `needle`.
func rows_with(needle: String) -> Array:
	return app.visual_layer.get_children().filter(func(c): return c is RichTextLabel and c.text.contains(needle))


## Read view rows with a link that opens `title`.
func rows_linking(title: String) -> Array:
	return app.visual_layer.get_children().filter(func(c): return c is RichTextLabel and LayerEngine.link_targets(c).has(title))


func open(note: ContentLayer) -> void:
	app._open_note(note)
	app._switch_layer("visual")
	await frames(3)


## Texts of the Read view's "LINKED FROM" section labels.
func section_labels() -> Array:
	return app.visual_layer.get_children().filter(func(n): return n is Label and n.text.begins_with("LINKED FROM")).map(func(n): return n.text)


## The "Linked from" row that reads `shown` ("Title", or "Title   Folder"
## with its folder crumb), or null.
func backlink_row(shown: String) -> RichTextLabel:
	var after_label: bool = false
	for n in app.visual_layer.get_children():
		if n is Label and n.text.begins_with("LINKED FROM"):
			after_label = true
		elif after_label and n is RichTextLabel and n.get_parsed_text() == shown:
			return n
	return null


## The first Read view row whose shown text is exactly `parsed`, or null.
func body_row(parsed: String) -> RichTextLabel:
	for n in app.visual_layer.get_children():
		if n is RichTextLabel and n.get_parsed_text() == parsed:
			return n
	return null


## Real mouse input on the first point of `rtl` that is over a link: along
## its middle line first, then down the whole row.
func click_meta(rtl: RichTextLabel) -> void:
	app.doc_scroll.ensure_control_visible(rtl)
	await frames(2)
	var local := Vector2(-1, -1)
	var ys: Array = [rtl.size.y / 2.0]
	ys.append_array(range(2, int(rtl.size.y), 4))
	for y in ys:
		for x in range(0, int(rtl.size.x), 2):
			var p := Vector2(x, y)
			if rtl.get_cursor_shape(p) == Control.CURSOR_POINTING_HAND:
				local = p + Vector2(2, 0)
				break
		if local.x >= 0:
			break
	check(local.x >= 0, "(the row has a link under the mouse somewhere)")
	var pos: Vector2 = rtl.get_global_transform_with_canvas() * local
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	get_root().push_input(m)
	await process_frame
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		get_root().push_input(e)
	await frames(3)


## Line segments in a 3D graph card: 0 when it drew no edge.
func graph_lines(card: NoteScene3D) -> int:
	return card._content.get_children().filter(func(c): return c is MeshInstance3D and c.mesh is ImmediateMesh).size()


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_links.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_links.json"
	ProgressStore.reset()
	var vault: String = TestVault.open("links", false)

	# ── spans(): links outside fences and code spans only ──
	var text: String = "a [[X|y]] b `[[Z]]`\n```\n[[W]]\n```\n"
	var found: Array[Dictionary] = WikiLinks.spans(text)
	check(found.size() == 1 and found[0].target == "X" and found[0].alias == "y", "spans: only X (alias y), not a code span's or a fence's link (%s)" % [found])
	if found.size() == 1:
		check(text.substr(found[0].start, found[0].end - found[0].start) == "[[X|y]]", "spans: start/end cover \"[[X|y]]\"")
	var deep: Array[Dictionary] = WikiLinks.spans("x\n[[A#Part two|shown]] [[B]]")
	check(deep.size() == 2 and deep[0].target == "A" and deep[0].heading == "Part two" and deep[0].alias == "shown" and deep[0].text == "A#Part two", "spans: [[A#Part two|shown]] -> target A, heading, alias, text")
	check(deep.size() == 2 and "x\n[[A#Part two|shown]] [[B]]".substr(deep[1].start, deep[1].end - deep[1].start) == "[[B]]", "spans: offsets count earlier lines")
	check(targets("````\n```\n[[In]]\n```\n````\n[[Out]]") == ["Out"], "spans: a ```` fence holds ``` lines; links after it count")
	check(targets("```\n[[In]]\n````\n[[Out]]") == ["Out"], "spans: a fence closes on at least as many backticks")
	check(targets("```\n[[In]]\n``` not a closer\n[[Still in]]") == [], "spans: a closer line holds only backticks; an unclosed fence hides the rest")
	check(targets("  ```3d\n[[In]]\n  ```\n[[Out]]") == ["Out"], "spans: indented fences count, like the renderer's")
	check(targets("`[[a]]` [[b]] ``x`` [[c]]") == ["b", "c"], "spans: code spans are skipped, the links between them kept")
	var agree: bool = true
	for s in ["```", "````3d", "``", "` ``", "``````", "x```", "```  "]:
		agree = agree and WikiLinks.fence_ticks(s) == LayerEngine._fence_ticks(s)
	check(agree, "fence_ticks agrees with LayerEngine._fence_ticks")

	# ── resolve(): exact, case-insensitive, never partial ──
	var start: ContentLayer = make("Start Here", "# Start Here\n\n## Intro\nWelcome.\n")
	var painting: ContentLayer = make("Painting", "Painting is an [[Art]].\n\n```\nSee [[Start Here]] (only an example)\n```\n")
	check(WikiLinks.resolve("Art") == null, "resolve('Art') is null with only 'Start Here' and 'Painting'")
	check(WikiLinks.resolve("start here#Intro") == start, "resolve('start here#Intro') -> 'Start Here'")
	check(WikiLinks.resolve("Start") == null and WikiLinks.resolve("Start Here and more") == null, "resolve: no partial matches either way")
	check(WikiLinks.resolve("  START HERE |the start") == start, "resolve strips '|alias' and spaces, ignores case")
	check(WikiLinks.resolve("") == null and WikiLinks.resolve("#Intro") == null, "resolve('') and resolve('#Intro') are null")
	var sharp: ContentLayer = make("C# Tips", "")
	check(WikiLinks.resolve("C# Tips") == sharp and WikiLinks.resolve("c# tips#Setup") == sharp, "a title with '#' resolves whole, and with a #heading")
	check(WikiLinks.base_title("Note#Heading|shown") == "Note", "base_title strips '#heading' and '|alias'")

	# ── outgoing() / backlinks() ──
	var hub: ContentLayer = make("Hub", "[[Painting]] [[painting|again]] [[Hub]] [[Start Here#Intro]]\n`[[C# Tips]]`\n[[Nowhere]]")
	check(titles(WikiLinks.outgoing(hub)) == ["Painting", "Start Here"], "outgoing: resolved, deduplicated, no self link, nothing in code (%s)" % [titles(WikiLinks.outgoing(hub))])
	check(WikiLinks.outgoing(painting).is_empty(), "outgoing: [[Art]] and a fenced link give nothing")
	check(titles(WikiLinks.backlinks(start)) == ["Hub"], "backlinks(Start Here) == [Hub], not Painting's fenced link (%s)" % [titles(WikiLinks.backlinks(start))])
	check(WikiLinks.backlinks(hub).is_empty(), "backlinks: a note's link to itself does not count")
	drop(hub)
	drop(sharp)

	app = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(6)

	# ── The 2D graph: exact matches only, nothing inside code ──
	app._build_graph_data()
	check(app._graph_edges.size() == 0, "2D graph: [[Art]] and a fenced [[Start Here]] draw no edge (%d edges)" % app._graph_edges.size())

	# ── The 3D vault graph agrees ──
	var card := NoteScene3D.new({"preset": "graph"}, 200.0)
	app.visual_layer.add_child(card)
	await frames(1)
	check(card._graph_nodes.size() == 2 and graph_lines(card) == 0, "3D graph: 2 notes, no edge")
	card.queue_free()

	# ── Clicking [[Note#Heading]] opens Note, never creates "Note#Heading" ──
	var before: int = VaultStore.note_list.size()
	app.open_note_by_title("Start Here#Intro", true)
	await frames(2)
	check(title_of(app.current_note) == "Start Here", "open_note_by_title('Start Here#Intro', true) opens 'Start Here'")
	check(VaultStore.note_list.size() == before, "…and creates no note (%d -> %d)" % [before, VaultStore.note_list.size()])
	app.open_note_by_title("Missing Note#Part", true)
	await frames(2)
	check(title_of(app.current_note) == "Missing Note" and WikiLinks.resolve("Missing Note#Part") == app.current_note, "a link to a missing Note#Part creates 'Missing Note'")
	drop(app.current_note)

	# ── Read view: each link opens the title it resolves to ──
	painting.raw_text = "[[Start Here#Intro]] and [[start here#Intro|the intro]], then [[Art]]. `[[Code]]`\n\n\n[[Art|x [b]]"   # two blank lines: two rows
	VaultStore.save_note(painting)
	app.open_note_by_title("Painting")
	app._switch_layer("visual")
	await frames(3)
	var row: Array = rows_linking("Start Here")
	check(row.size() == 1 and row[0].text.contains("]Start Here#Intro[/color]") and row[0].text.contains("]the intro[/color]"), "Read view: [[Start Here#Intro]] -> meta 'Start Here', shown as written or by alias")
	check(row.size() == 1 and LayerEngine.link_targets(row[0]) == ["Start Here", "Start Here", "Art"] and row[0].text.contains("[code][lb][lb]Code]][/code]"), "Read view: a dangling link keeps its base title; a code span stays code (%s)" % [LayerEngine.link_targets(row[0]) if row.size() == 1 else []])
	check(rows_with("]x [lb]b[/color]").size() == 1, "Read view: '[' in a link's shown text is escaped")
	app.get_node("%BtnGraph").pressed.emit()
	await frames(2)
	check(app._graph_edges.size() == 1 and app._graph_edges[0] == {"from": painting.resource_path, "to": start.resource_path}, "2D graph: a real [[Start Here#Intro]] draws Painting -> Start Here")
	card = NoteScene3D.new({"preset": "graph"}, 200.0)
	app.visual_layer.add_child(card)
	await frames(1)
	check(graph_lines(card) == 1, "3D graph: the same link draws an edge")
	card.queue_free()

	# ── "Linked from" at the end of Read view ──
	var sub: String = VaultStore.create_folder("Sub")
	var a: ContentLayer = make("A", "# A\n\nNothing links out from here.\n")
	make("B", "See [[A]] for more.\n", sub)
	var c: ContentLayer = make("C", "Only an example:\n```\n[[A]]\n```\n")
	await open(a)
	var heads: Array = section_labels()
	check(heads == ["LINKED FROM (1)"], "Read view of A: a 'LINKED FROM (1)' label (%s)" % [heads])
	var link: RichTextLabel = backlink_row("B   Sub")
	check(link != null, "…and a row 'B   Sub'")
	check(link != null and link.text.contains("[color=#%s]Sub[/color]" % app._palette_colors.text_faint.to_html(false)), "…shown with its folder crumb in faint text")
	if link != null:
		await click_meta(link)
	check(title_of(app.current_note) == "B", "a real click on that link opens B (%s)" % title_of(app.current_note))
	await open(c)
	check(section_labels().is_empty(), "a note nothing links to has no LINKED FROM label")
	await open(start)
	check(section_labels() == ["LINKED FROM (1)"] and backlink_row("Painting") != null, "Start Here is linked from Painting ([[Start Here#Intro]])")

	# ── A "Linked from" row opens the very note it shows ──
	# Titles are free text: a ']' or quotes once broke the row's [url=title]
	# tag, so a click created a junk note named by the cut-off title. Notes
	# that share a title ("untitled", "Daily" in two folders) all opened the
	# first one.
	var odd: Array[ContentLayer] = []
	for t in ["Notes [draft]", "Week [3]", "x]y", "Array[int] tips", "[WIP] Plan", "\"Quoted\""]:
		odd.append(make(t, "See [[A]].\n"))
	var daily_one: ContentLayer = make("Daily", "[[A]]", VaultStore.create_folder("One"))
	var daily_two: ContentLayer = make("Daily", "[[A]]", VaultStore.create_folder("Two"))
	var bare: ContentLayer = make("untitled", "No links here.")
	var linking: ContentLayer = make("untitled", "Back to [[A]].")
	var count: int = VaultStore.note_list.size()
	for note in odd:
		await open(a)
		var odd_row: RichTextLabel = backlink_row(note.title)
		check(odd_row != null, "LINKED FROM shows '%s' as written" % note.title)
		if odd_row != null:
			await click_meta(odd_row)
		check(app.current_note == note, "a real click on '%s' opens it (%s)" % [note.title, title_of(app.current_note)])
	check(VaultStore.note_list.size() == count, "…and no click creates a note (%d -> %d)" % [count, VaultStore.note_list.size()])
	for pair in [["Daily   Two", daily_two], ["Daily   One", daily_one], ["Untitled", linking]]:
		await open(a)
		var same_row: RichTextLabel = backlink_row(pair[0])
		check(same_row != null, "LINKED FROM has a row '%s'" % pair[0])
		if same_row != null:
			await click_meta(same_row)
		check(app.current_note == pair[1], "a real click on '%s' opens that very note, not another with its title (%s)" % [pair[0], VaultStore.folder_of(app.current_note)])
	check(app.current_note != bare, "the untitled note without links is not the one opened")
	var ghost := ContentLayer.new()   # the same file, as a reload would give it
	ghost.set_path_cache(daily_two.resource_path)
	app.open_note(ghost)
	check(app.current_note == daily_two, "open_note finds a reloaded note again by its file")
	drop(bare)
	app.open_note(bare)
	check(app.current_note == daily_two, "open_note on a deleted note opens nothing")

	# ── A body [[link]] opens the note it names, whatever its title ──
	# Its url meta was the title itself. Godot unquotes a [url=…] value and
	# looks for the closing ']' outside quotes, so [[5" floppy]] lost its text
	# (and the line up to the next quote) and could not be clicked, and
	# [["Quoted"]] opened a junk note 'Quoted'. The review banner's links too.
	var quoted: Array[ContentLayer] = []
	for t in ["5\" floppy", "\"Quoted\"", "Say \"hi\"", "a=\"1\" b", "Notes [draft"]:
		quoted.append(make(t, "Nothing links out from here.\n"))
	var q_lines: PackedStringArray = []
	for note in quoted:
		q_lines.append("See [[%s]] here." % note.title)
	q_lines.append("Try [[\"quoted\"|the \"quoted\" one]] too.")
	q_lines.append("Then [[Ghost \"x\"#Part]] after.")
	var q_hub: ContentLayer = make("Quote hub", "\n\n\n".join(q_lines))   # two blank lines: a row each
	count = VaultStore.note_list.size()
	for note in quoted:
		await open(q_hub)
		var q_row: RichTextLabel = body_row("See %s here." % note.title)
		check(q_row != null, "Read view shows 'See %s here.' with its link intact" % note.title)
		if q_row != null:
			await click_meta(q_row)
		check(app.current_note == note, "a real click on [[%s]] opens it (%s)" % [note.title, title_of(app.current_note)])
	await open(q_hub)
	var alias_row: RichTextLabel = body_row("Try the \"quoted\" one too.")
	check(alias_row != null, "an alias with quotes shows as written")
	if alias_row != null:
		await click_meta(alias_row)
	check(app.current_note == quoted[1], "a real click on [[\"quoted\"|…]] opens '\"Quoted\"' (%s)" % title_of(app.current_note))
	check(VaultStore.note_list.size() == count, "…and no click on a link to a real note creates one (%d -> %d)" % [count, VaultStore.note_list.size()])
	await open(q_hub)
	var ghost_row: RichTextLabel = body_row("Then Ghost \"x\"#Part after.")
	check(ghost_row != null, "a dangling link with a quote shows as written")
	if ghost_row != null:
		await click_meta(ghost_row)
	check(title_of(app.current_note) == "Ghost \"x\"" and VaultStore.note_list.size() == count + 1, "a real click on [[Ghost \"x\"#Part]] creates 'Ghost \"x\"' (%s)" % title_of(app.current_note))
	if title_of(app.current_note) == "Ghost \"x\"":
		drop(app.current_note)
	ProgressStore.record_answer(quoted[0].title, 0, 0, "What fits?", false, "A")
	await open(a)
	var banners: Array = app.visual_layer.get_children().filter(func(n): return n is PanelContainer and n.theme_type_variation == &"ReviewBanner")
	var banner: RichTextLabel = banners[0].get_child(0) if banners.size() == 1 else null
	check(banner != null and banner.get_parsed_text().contains("“What fits?”  in 5\" floppy\n"), "the review banner names '5\" floppy' as written (%s)" % [banner.get_parsed_text() if banner != null else "<no banner>"])
	if banner != null:
		await click_meta(banner)
	check(app.current_note == quoted[0], "a real click on the banner's link opens '5\" floppy' (%s)" % title_of(app.current_note))
	# The banner named the quiz's note as "[[<title>]]" and parsed that again:
	# "Week [3]" opened a junk note "Week [3", "Pros | cons" read "in cons"
	# and its click made "Pros", "Notes]x" showed as raw text.
	var from_notes: Array[ContentLayer] = []
	for t in ["Week [3]", "Pros | cons", "Notes]x"]:
		var have: ContentLayer = WikiLinks.resolve(t)
		from_notes.append(have if have != null and have.title == t else make(t, "A quiz lives here.\n"))
	count = VaultStore.note_list.size()
	for note in from_notes:
		ProgressStore.reset()
		ProgressStore.record_answer(note.title, 0, 0, "Why?", false, "A")
		app.on_progress_changed()
		await open(a)
		banners = app.visual_layer.get_children().filter(func(n): return n is PanelContainer and n.theme_type_variation == &"ReviewBanner")
		banner = banners[0].get_child(0) if banners.size() == 1 else null
		check(banner != null and banner.get_parsed_text().contains("“Why?”  in %s\n" % note.title), "the review banner names '%s' as written (%s)" % [note.title, banner.get_parsed_text() if banner != null else "<no banner>"])
		if banner != null:
			await click_meta(banner)
		check(app.current_note == note, "a real click on the banner's link opens '%s' (%s)" % [note.title, title_of(app.current_note)])
	check(VaultStore.note_list.size() == count, "…and no banner click creates a note (%d -> %d)" % [count, VaultStore.note_list.size()])
	ProgressStore.reset()
	for note in quoted:
		drop(note)
	drop(q_hub)

	# ── [[Note\|shown]]: Obsidian's alias inside a table cell ──
	# Read view's cells read "\|" as "|", so the cell opened Photosynthesis,
	# but WikiLinks took "Photosynthesis\" for the title: no LINKED FROM row,
	# no graph edge, and a rename left the link behind (a click then created
	# a new, empty "Photosynthesis").
	var photo: ContentLayer = make("Photosynthesis", "Light into sugar.\n")
	var t_hub: ContentLayer = make("Table hub", "| Topic | Read |\n|---|---|\n| Light | [[Photosynthesis\\|the light page]] |\n")
	var t_spans: Array[Dictionary] = WikiLinks.spans(t_hub.raw_text)
	check(t_spans.size() == 1 and t_spans[0].target == "Photosynthesis" and t_spans[0].alias == "the light page", "spans: [[Photosynthesis\\|the light page]] names Photosynthesis, shown 'the light page' (%s)" % [t_spans])
	check(titles(WikiLinks.backlinks(photo)) == ["Table hub"] and titles(WikiLinks.outgoing(t_hub)) == ["Photosynthesis"], "backlinks and outgoing agree with it")
	var t_lint: Array[Dictionary] = NoteLint.lint(t_hub.title, t_hub.raw_text, func(t: String) -> bool: return WikiLinks.resolve(t) != null)
	check(t_lint.is_empty(), "and lint finds no link to a missing note in it (%s)" % [t_lint])
	app._build_graph_data()
	check(app._graph_edges.has({"from": t_hub.resource_path, "to": photo.resource_path}), "2D graph: Table hub -> Photosynthesis")
	await open(photo)
	check(backlink_row("Table hub") != null, "Photosynthesis lists Table hub under LINKED FROM")
	count = VaultStore.note_list.size()
	check(app._rename_current("Photosynthesis Basics"), "rename Photosynthesis to 'Photosynthesis Basics'")
	check(t_hub.raw_text.contains("| [[Photosynthesis Basics\\|the light page]] |"), "the rename rewrites the table's link, keeping \\| and the alias (%s)" % t_hub.raw_text)
	await open(t_hub)
	var t_cells: Array = app.visual_layer.find_children("*", "RichTextLabel", true, false).filter(func(r): return not LayerEngine.link_targets(r).is_empty())
	check(t_cells.size() == 1 and LayerEngine.link_targets(t_cells[0]) == ["Photosynthesis Basics"] and t_cells[0].get_parsed_text() == "the light page", "the cell shows 'the light page' and opens 'Photosynthesis Basics'")
	if t_cells.size() == 1:
		await click_meta(t_cells[0])
	check(app.current_note == photo and VaultStore.note_list.size() == count, "a real click on it opens the renamed note and creates none (%s, %d -> %d)" % [title_of(app.current_note), count, VaultStore.note_list.size()])
	drop(t_hub)
	drop(photo)

	# ── One title index per Read view render ──
	# Each link piece between code spans used to build its own index (a walk
	# of the whole vault): a 300-line hub of links in a 2000-note vault took
	# 0.76 s to open.
	var hub_lines: PackedStringArray = []
	for i in range(40):
		hub_lines.append("- see [[A]] and `code` then [[Daily|x]] [[Nowhere %d]]" % i)
	var big: ContentLayer = make("Big hub", "\n".join(hub_lines))
	await open(big)
	var builds: int = WikiLinks.index_builds
	LayerEngine._render_visual()
	check(WikiLinks.index_builds - builds == 1, "a render of 80 link pieces builds the title index once (%d)" % [WikiLinks.index_builds - builds])
	check(rows_linking("A").size() == 40 and rows_linking("Daily").size() == 40, "…and every link still resolves")
	check(section_labels().is_empty() and LayerEngine._titles_ready == false, "…and the index is let go after the render")

	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	app.queue_free()
	await frames(2)
	TestVault.remove_tree(vault)
	quit(1 if fails else 0)
