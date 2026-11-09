extends SceneTree
## TagOps: the one tag normalization (pure, no vault, no scene), each tag's
## stable colour slot and the tag palettes' contrast, its rename rule, and the Markdown importer's front matter going through it:
## the comma form, the YAML flow and block lists, quoted titles, md_export's
## output read back, and a vault-level export -> import round trip in
## throwaway vaults. Then the MCP tools' tags: normalized writes, the `tag`
## search, and list_tags.
##   headless:  godot --headless --path . -s res://tests/tag_ops_test.gd

const NoteImporter = preload("res://note_importer.gd")
const TestVault = preload("res://tests/test_vault.gd")
const McpProtocol = preload("res://mcp/protocol.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")
const TMP_DIR: String = "user://test-tag-ops/"

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func note_with(tags: Array) -> ContentLayer:
	var n := ContentLayer.new()
	n.tags.assign(tags)
	return n


## Write `text` to a .md under TMP_DIR and parse it the way import_dir does.
func parse_md(file: String, text: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))
	var path: String = ProjectSettings.globalize_path(TMP_DIR + file)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return NoteImporter.new()._parse(path, "")


func check_normalize() -> void:
	check(TagOps.normalize("#ProJect ") == "project", "normalize('#ProJect ') == 'project'")
	check(TagOps.normalize("Cultural  Evolution") == "cultural-evolution",
		"normalize('Cultural  Evolution') == 'cultural-evolution' (%s)" % TagOps.normalize("Cultural  Evolution"))
	check(TagOps.normalize("##") == "", "normalize('##') == ''")
	check(TagOps.normalize("") == "" and TagOps.normalize("   ") == "", "blank input normalizes to ''")
	check(TagOps.normalize("  ## Tab\tand\nNewline ") == "tab-and-newline",
		"leading #s and spaces go, every whitespace run is one '-' (%s)" % TagOps.normalize("  ## Tab\tand\nNewline "))
	check(TagOps.normalize("c#") == "c#", "only leading #s are dropped (%s)" % TagOps.normalize("c#"))
	check(TagOps.normalize(TagOps.normalize("#Cultural Evolution")) == "cultural-evolution",
		"normalize is idempotent")


## A tag's colour slot is FNV-1a over its normalized UTF-8 bytes: pinned, so
## a change of hash (String.hash() is free to change between versions)
## would show here, and spread over the palette.
func check_color_index() -> void:
	var i: int = TagOps.color_index("project", 8)
	check(i == 6, "color_index('project', 8) == 6 (FNV-1a 4106060478 %% 8) (%d)" % i)
	check(TagOps.color_index("#Project ", 8) == i, "color_index normalizes: '#Project ' takes project's slot")
	check(TagOps.color_index("project", 1) == 0 and TagOps.color_index("project", 0) == 0,
		"one slot or none gives 0")
	var seen: Dictionary = {}
	for tag in ["project", "tutorial", "physics", "godot", "quiz", "memetics", "alpha", "beta"]:
		var k: int = TagOps.color_index(tag, 8)
		check(k >= 0 and k < 8, "color_index('%s', 8) is a slot 0..7 (%d)" % [tag, k])
		seen[k] = true
	check(seen.size() >= 4, "8 sample tags hit at least 4 distinct colours (%s)" % [seen.keys()])
	check(AppTheme.tag_color("project", true) == AppTheme.tag_palette(true)[i]
		and AppTheme.tag_color("project", false) == AppTheme.tag_palette(false)[i],
		"AppTheme.tag_color picks the tag's slot in either theme's palette")


## WCAG 2 relative luminance of an sRGB colour.
func wcag_luminance(c: Color) -> float:
	var lin: Array[float] = []
	for v in [c.r, c.g, c.b]:
		lin.append(v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4))
	return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


func contrast_ratio(a: Color, b: Color) -> float:
	var la: float = wcag_luminance(a)
	var lb: float = wcag_luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


## Every tag colour stands out at 3:1 (WCAG non-text contrast) against the
## theme's editor background (the chips) and sidebar (the TAGS rows).
func check_tag_palette_contrast() -> void:
	for dark in [true, false]:
		var theme_name: String = "dark" if dark else "light"
		var colors: Array[Color] = AppTheme.tag_palette(dark)
		check(colors.size() == 8, "the %s tag palette has 8 colours (%d)" % [theme_name, colors.size()])
		var p: Dictionary = AppTheme.palette(dark)
		for c in colors:
			for bg in ["bg", "sidebar"]:
				var ratio: float = contrast_ratio(c, p[bg])
				check(ratio >= 3.0, "%s tag colour #%s vs %s #%s: %.2f:1 >= 3:1" % [
					theme_name, c.to_html(false), bg, (p[bg] as Color).to_html(false), ratio])
	check(AppTheme.tag_palette(true) != AppTheme.tag_palette(false), "the two themes have their own tag palettes")


func check_lists() -> void:
	var l: Array[String] = TagOps.normalize_list(["A", "a", "#b"])
	check(l == ["a", "b"], "normalize_list(['A','a','#b']) == ['a','b'] (%s)" % [l])
	l = TagOps.normalize_list(["Zed", "", "##", "alpha", "ZED"])
	check(l == ["zed", "alpha"], "normalize_list drops empties and keeps first-seen order (%s)" % [l])
	var c: Dictionary = TagOps.counts([note_with(["Physics"]), note_with(["physics", "x"])])
	check(c == {"physics": 2, "x": 1}, "counts over [['Physics'],['physics','x']] == {physics: 2, x: 1} (%s)" % c)
	c = TagOps.counts([note_with(["Physics", "physics"])])
	check(c == {"physics": 1}, "a note carrying two spellings counts once (%s)" % c)
	c = TagOps.counts([["A"], {"tags": ["a", "B"]}])
	check(c == {"a": 2, "b": 1}, "counts takes tag arrays and dictionaries too (%s)" % c)
	check(TagOps.has(note_with(["Physics"]), "#physics"), "has: a 'Physics' note has #physics")
	check(TagOps.has(note_with(["Cultural Evolution"]), "cultural-evolution"), "has: 'Cultural Evolution' is cultural-evolution")
	check(not TagOps.has(note_with(["physics"]), "phys"), "has: a prefix is not the tag")
	check(not TagOps.has(note_with(["physics"]), "##"), "has: an empty tag matches nothing")
	check(TagOps.has_prefix(note_with(["Physics"]), "#PHYS"), "has_prefix: '#PHYS' starts a 'Physics' tag")
	check(TagOps.has_prefix(note_with(["Cultural Evolution"]), "cultural-ev"), "has_prefix: compares normalized forms")
	check(not TagOps.has_prefix(note_with(["physics"]), "hys"), "has_prefix: only the start of a tag")
	check(not TagOps.has_prefix(note_with(["physics"]), "#"), "has_prefix: an empty prefix matches nothing")


## rename(): the one tag-rewrite rule behind "Rename or merge tag…" and
## "Remove from all notes…" in the TAGS section.
func check_rename() -> void:
	var n: ContentLayer = note_with(["a", "bugg", "c"])
	check(TagOps.rename(n, "bugg", "bug") and n.tags == ["a", "bug", "c"],
		"rename replaces the tag in its place (%s)" % [n.tags])
	n = note_with(["bugg", "bug"])
	check(TagOps.rename(n, "bugg", "bug") and n.tags == ["bug"],
		"renaming onto a tag the note has merges them, no duplicate (%s)" % [n.tags])
	n = note_with(["bug", "x", "Bugg"])
	check(TagOps.rename(n, "bugg", "bug") and n.tags == ["bug", "x"],
		"a merge keeps the tag already there, in its place (%s)" % [n.tags])
	n = note_with(["Bugg", "Physics"])
	check(TagOps.rename(n, "#BUGG", "Bug Fix") and n.tags == ["bug-fix", "Physics"],
		"both sides compare normalized, the new tag is stored normalized, other tags are left as written (%s)" % [n.tags])
	n = note_with(["a", "bug", "c"])
	check(TagOps.rename(n, "bug", "") and n.tags == ["a", "c"],
		"an empty new name removes the tag (%s)" % [n.tags])
	n = note_with(["a"])
	check(not TagOps.rename(n, "bug", "x") and n.tags == ["a"], "a note without the tag is left alone (%s)" % [n.tags])
	n = note_with(["Bug"])
	check(not TagOps.rename(n, "bug", "#BUG") and n.tags == ["Bug"],
		"renaming a tag to itself changes nothing (%s)" % [n.tags])
	check(not TagOps.rename(note_with(["a"]), "##", "x"), "an empty old name matches nothing")
	var d: Dictionary = {"tags": ["bugg"]}
	check(TagOps.rename(d, "bugg", "bug") and d.tags == ["bug"], "rename works on a Dictionary note (%s)" % [d.tags])
	var arr: Array = ["bugg", "z"]
	check(TagOps.rename(arr, "bugg", "z") and arr == ["z"], "and on a tag Array, in place (%s)" % [arr])


func check_importer_comma_form() -> void:
	var d: Dictionary = parse_md("comma.md", "---\ntitle: Comma Tags\ntags: Physics, Cultural Evolution\n---\nBody.\n")
	check(d.tags == ["physics", "cultural-evolution"],
		"the importer normalizes 'tags: Physics, Cultural Evolution' (%s)" % [d.tags])


## What md_export writes (`title: "RT"`, `tags: ["alpha", "beta gamma"]`)
## comes back as the same title and the normalized tags.
func check_importer_reads_md_export() -> void:
	var note := ContentLayer.new()
	note.title = "RT"
	note.tags.assign(["alpha", "beta gamma", 'say "hi"'])
	note.raw_text = "Round trip body.\n"
	var d: Dictionary = parse_md("rt.md", MdExport.to_markdown(note, {}))
	check(d.title == "RT", "md_export's quoted title reads back unquoted (%s)" % d.title)
	check(d.tags == ["alpha", "beta-gamma", 'say-"hi"'],
		"md_export's flow-list tags read back normalized (%s)" % [d.tags])
	check(d.text == note.raw_text, "the body reads back unchanged")


func check_importer_yaml_forms() -> void:
	var d: Dictionary = parse_md("block.md",
		"---\ntitle: Block\ntags:\n  - Physics\n  - Waves\ntopic: Optics\n---\nBody.\n")
	check(d.tags == ["physics", "waves"], "a YAML block list gives ['physics','waves'] (%s)" % [d.tags])
	check(d.topic == "Optics", "the key after a block list still reads (%s)" % d.topic)

	d = parse_md("legacy.md", "---\ntags: memetics, history, cultural evolution\n---\nBody.\n")
	check(d.tags == ["memetics", "history", "cultural-evolution"],
		"the legacy comma form gives ['memetics','history','cultural-evolution'] (%s)" % [d.tags])

	d = parse_md("flow.md", "---\ntags: ['it''s', \"x, y\", plain, \"back\\\\slash\", \"#Hash\"]\n---\nBody.\n")
	check(d.tags == ["it's", "x,-y", "plain", "back\\slash", "hash"],
		"flow items: single quotes, a quoted comma, a plain item, an escaped backslash, a '#' (%s)" % [d.tags])

	d = parse_md("apostrophe.md", "---\ntags: don't, panic\n---\nBody.\n")
	check(d.tags == ["don't", "panic"], "an apostrophe inside a plain item opens no quote (%s)" % [d.tags])

	d = parse_md("empty.md", "---\ntitle: Empty\ntags: []\n---\nBody.\n")
	check(d.tags.is_empty(), "'tags: []' gives no tags (%s)" % [d.tags])

	d = parse_md("dash.md", "---\ntags:\n- Unindented\n-\n---\nBody.\n")
	check(d.tags == ["unindented"], "an unindented block list reads, an empty item is skipped (%s)" % [d.tags])

	d = parse_md("title1.md", "---\ntitle: \"Say \\\"hi\\\"\"\n---\nBody.\n")
	check(d.title == 'Say "hi"', "a double-quoted title unescapes its quotes (%s)" % d.title)
	d = parse_md("title2.md", "---\ntitle: 'It''s RT'\n---\nBody.\n")
	check(d.title == "It's RT", "a single-quoted title is unquoted (%s)" % d.title)
	d = parse_md("title3.md", "---\ntitle: Plain \"inner\" words\n---\nBody.\n")
	check(d.title == 'Plain "inner" words', "a plain title keeps its inner quotes (%s)" % d.title)


## An empty or blank quoted title (`title: ""`, `title: ''`, the placeholders
## Hugo, Jekyll and Astro templates carry) falls back to the file name the
## way a bare `title:` does; a quoted title is trimmed like a plain one.
func check_importer_empty_titles() -> void:
	for t in ["title:", "title: \"\"", "title: ''", "title: \"   \"", "title: '  '"]:
		var d: Dictionary = parse_md("Template_Note.md", "---\n%s\n---\nBody.\n" % t)
		check(d.title == "Template Note", "'%s' falls back to the file name (%s)" % [t, d.title])
	var spaced: Dictionary = parse_md("spaced.md", "---\ntitle: \"  Spaced Out  \"\n---\nBody.\n")
	check(spaced.title == "Spaced Out", "a quoted title is trimmed ('%s')" % spaced.title)


## Two files with placeholder titles import as two notes named after their
## files, each keeping its own body, and the vault reopens with both. (The
## importer matches notes by title, so an empty title once sent both files
## into one note and the second body replaced the first.)
func check_import_empty_titles() -> void:
	var src: String = ProjectSettings.globalize_path(TMP_DIR + "placeholders")
	DirAccess.make_dir_recursive_absolute(src)
	var files: Array = [   # [file, title line, title it imports as, body]
		["Template_One.md", "title: \"\"", "Template One", "Body one\n"],
		["Template_Two.md", "title: ''", "Template Two", "Body two\n"],
	]
	for f in files:
		var fa := FileAccess.open(src.path_join(f[0]), FileAccess.WRITE)
		fa.store_string("---\n%s\n---\n%s" % [f[1], f[3]])
		fa.close()
	var vault: String = TestVault.open("tag-ops-titles", false)
	var imported: int = NoteImporter.new().import_dir(src)
	check(imported == 2, "both placeholder-titled files import (%d)" % imported)
	for reopen in [false, true]:
		if reopen:
			VaultStore.open_vault(vault, false)
		var when: String = "after reopening" if reopen else "after the import"
		check(VaultStore.note_list.size() == 2,
			"two placeholder titles give two notes %s (%d)" % [when, VaultStore.note_list.size()])
		for f in files:
			var idx: int = VaultStore.get_note_index(f[2])
			var n: ContentLayer = VaultStore.note_list[idx] if idx >= 0 else null
			check(n != null and n.raw_text == f[3],
				"'%s' is its own note with '%s' %s" % [f[2], f[3].strip_edges(), when])
	TestVault.remove_tree(vault)


## Vault-level round trip: export a fixture vault with md-export's own
## MdExport.export_vault (one .md per note in its folder), import that folder
## into a fresh vault, and get the same titles, folders, tags (normalized)
## and bodies back for link-free notes.
func check_vault_round_trip() -> void:
	var fixtures: Array = [   # [title, folder, tags, raw_text]
		["Plain Note", "", [], "One line.\n"],
		["Tagged Note", "", ["physics", "cultural-evolution"], "Two\nlines.\n"],
		['Quoted "Title"', "Sub", ['say-"hi"', "back\\slash", "a,-b"], "Body text.\n\n- a list\n"],
		["Colon: Title", "Sub/Deeper", ["x"], "# Heading\n\nText with `code` and --- dashes.\n"],
	]
	TestVault.open("tag-ops-src", false)
	for f in fixtures:
		var n: ContentLayer = VaultStore.create_note(f[0], f[1])
		n.tags.assign(f[2])
		n.raw_text = f[3]
		VaultStore.save_note(n)
	var out: String = ProjectSettings.globalize_path(TMP_DIR + "export")
	TestVault.remove_tree(out)
	var exported: Dictionary = MdExport.export_vault(out)
	check(exported.written == fixtures.size() and exported.failed.is_empty(),
		"export_vault writes every fixture note (%d, failed %s: %s)" % [exported.written, exported.failed, MdExport.last_error])
	TestVault.open("tag-ops-dst", false)
	NoteImporter.new().import_dir(out)
	check(VaultStore.note_list.size() == fixtures.size(),
		"the import gives one note per exported note (%d)" % VaultStore.note_list.size())
	for f in fixtures:
		var idx: int = VaultStore.get_note_index(f[0])
		var n: ContentLayer = VaultStore.note_list[idx] if idx >= 0 else null
		check(n != null, "'%s' comes back with its title" % f[0])
		if n == null:
			continue
		check(VaultStore.folder_of(n) == f[1], "'%s' comes back in '%s' (%s)" % [f[0], f[1], VaultStore.folder_of(n)])
		check(n.tags == TagOps.normalize_list(f[2]), "'%s' keeps its tags (%s)" % [f[0], n.tags])
		check(n.raw_text == f[3], "'%s' keeps its body" % f[0])
	TestVault.remove_tree(ProjectSettings.globalize_path("user://test-vault-tag-ops-src/"))
	TestVault.remove_tree(ProjectSettings.globalize_path("user://test-vault-tag-ops-dst/"))


## A tools/call through the MCP protocol, as a client sends it: the
## CallToolResult's structuredContent ({} when the call failed outright).
func mcp(proto: RefCounted, tool: String, args: Dictionary) -> Dictionary:
	var r: Variant = proto.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}})
	return r.result.get("structuredContent", {}) if r is Dictionary and r.has("result") else {}


## list_tags' rows as {tag: count}, in the order it returns them.
func tag_rows(result: Dictionary) -> Array:
	return Array(result.get("tags", [])).map(func(row: Dictionary) -> Array: return [row.tag, row.count])


## MCP writes go through TagOps (so an agent's 'Physics' is the app's
## #physics), search_notes' `tag` compares normalized forms, and list_tags
## hands an agent the vault's existing tags to reuse.
func check_mcp_tags() -> void:
	var vault: String = TestVault.open("tag-ops-mcp")
	var seeded: Dictionary = TagOps.counts(VaultStore.note_list)   # what the app's own store counts
	var tutorial_notes: int = int(seeded.get("tutorial", 0))
	var proto: RefCounted = McpProtocol.new(VaultTools.new(vault))
	proto.handle({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
	var listed: Variant = proto.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
	var tool: Array = listed.result.tools.filter(func(t: Dictionary) -> bool: return t.name == "list_tags")
	check(tool.size() == 1 and tool[0].annotations.readOnlyHint == true and tool[0].annotations.openWorldHint == false,
		"tools/list has list_tags, read-only (%s)" % [tool])
	check(tool.size() == 1 and tool[0].inputSchema.type == "object" and tool[0].inputSchema.properties.has("folder"),
		"list_tags takes an optional folder")

	var made: Dictionary = mcp(proto, "create_note", {"title": "Agent Note", "folder": "Agent", "tags": ["#Foo Bar", "foo bar", "X"]})
	var read: Dictionary = mcp(proto, "read_note", {"path": made.get("path", "")})
	check(read.get("tags") == ["foo-bar", "x"], "create_note stores ['#Foo Bar','foo bar','X'] as ['foo-bar','x'] (%s)" % [read.get("tags")])
	var upd: Dictionary = mcp(proto, "update_note", {"path": made.get("path", ""), "hash": read.get("hash", ""), "tags": ["Foo Bar", "  #Y  ", "##", "y"]})
	read = mcp(proto, "read_note", {"path": made.get("path", "")})
	check(upd.has("hash") and read.get("tags") == ["foo-bar", "y"], "update_note normalizes too, dropping empty and repeated tags (%s)" % [read.get("tags")])
	var found: Dictionary = mcp(proto, "search_notes", {"tag": "#FOO Bar"})
	check(found.get("total") == 1 and found.notes[0].path == made.path, "search_notes' tag '#FOO Bar' finds the #foo-bar note (%s)" % [found.get("total")])
	var physics := ContentLayer.new()   # written by an older app or by hand: not normalized
	physics.title = "Old Spelling"
	physics.tags.assign(["Cultural Evolution"])
	ResourceSaver.save(physics, vault.path_join("Agent/note_old_spelling.tres"))
	found = mcp(proto, "search_notes", {"tag": "cultural-evolution"})
	check(found.get("total") == 1, "search_notes' tag matches a stored 'Cultural Evolution' as cultural-evolution (%s)" % [found.get("total")])

	var doomed: Dictionary = mcp(proto, "create_note", {"title": "Trash Me", "tags": ["only-in-trash", "tutorial"]})
	mcp(proto, "delete_note", {"path": doomed.get("path", ""), "hash": doomed.get("hash", "")})
	check(FileAccess.file_exists(vault.path_join(".trash").path_join(doomed.get("path", "-"))), "the deleted note sits in .trash")

	var all: Dictionary = mcp(proto, "list_tags", {})
	var rows: Array = tag_rows(all)
	check(["tutorial", tutorial_notes] in rows and tutorial_notes > 1,
		"list_tags counts #tutorial on the %d seeded notes carrying it (%s)" % [tutorial_notes, rows])
	check(["foo-bar", 1] in rows and ["y", 1] in rows and ["cultural-evolution", 1] in rows,
		"and #foo-bar, #y and the old spelling's #cultural-evolution once each")
	check(not rows.any(func(r: Array) -> bool: return r[0] == "only-in-trash"), "a trashed note's tags are not counted")
	check(all.get("total") == rows.size() and rows.size() == seeded.size() + 3,
		"total is the number of tags: the seeded ones plus the 3 new (%s)" % [all.get("total")])
	var sorted: bool = true
	for i in range(1, rows.size()):
		var a: Array = rows[i - 1]
		var b: Array = rows[i]
		if a[1] < b[1] or (a[1] == b[1] and a[0] > b[0]):
			sorted = false
	check(sorted and not rows.is_empty() and rows[0][0] == "tutorial", "most used first, then by name (%s)" % [rows.slice(0, 4)])

	var agent: Dictionary = mcp(proto, "list_tags", {"folder": "Agent"})
	check(tag_rows(agent) == [["cultural-evolution", 1], ["foo-bar", 1], ["y", 1]] and agent.get("total") == 3,
		"folder 'Agent' counts only that folder's notes (%s)" % [tag_rows(agent)])
	var bad: Dictionary = mcp(proto, "list_tags", {"folder": "../outside"})
	check(bad.get("error", {}).get("code") == "invalid_path", "a folder outside the vault is refused (%s)" % [bad])
	TestVault.remove_tree(vault)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_tag_ops.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_tag_ops.json"
	ProgressStore.reset()
	check_normalize()
	check_color_index()
	check_tag_palette_contrast()
	check_lists()
	check_rename()
	check_importer_comma_form()
	check_importer_reads_md_export()
	check_importer_yaml_forms()
	check_importer_empty_titles()
	check_import_empty_titles()
	check_vault_round_trip()
	check_mcp_tags()
	TestVault.remove_tree(ProjectSettings.globalize_path(TMP_DIR))
	for f in [JourneyStore.file_override, ProgressStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
