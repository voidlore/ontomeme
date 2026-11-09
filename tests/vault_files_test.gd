extends SceneTree
## Files in a vault that are not Ontomeme notes. A folder holding a Godot
## project has materials, themes and the project's own resources as .tres
## files: the app lists none of them and never rewrites one. A hand-written
## note that only lacks its script line is still repaired, and one without a
## title gets one from its file name (in memory; the file is not rewritten).
## Symbolic links never make a scan list a note twice or run without end,
## and never let the MCP tools out of the vault.
##   godot --headless --path . -s res://tests/vault_files_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func _init() -> void:
	ProgressStore.file_override = "user://test_progress_vault_files.json"   # never touch real progress
	JourneyStore.file_override = "user://test_journey_vault_files.json"     # never touch the real journey
	var V: String = TestVault.open("vault-files", false)
	test_foreign_resources_untouched(V)
	test_scriptless_note_repaired(V)
	test_untitled_note_gets_a_title(V)
	test_blank_lines_scan_in_linear_time(V)
	TestVault.remove_tree(V)
	test_symbolic_links()
	for f in [ProgressStore.file_override, JourneyStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)


func write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func listed_paths() -> Array:
	return VaultStore.note_list.map(func(n): return n.resource_path)


## The files a Godot project keeps beside its scenes, keyed by vault path.
func write_foreign(V: String) -> Array[String]:
	DirAccess.make_dir_recursive_absolute(V + "assets")
	var red := StandardMaterial3D.new()
	red.albedo_color = Color.RED
	ResourceSaver.save(red, V + "assets/red.tres")
	ResourceSaver.save(Theme.new(), V + "theme.tres")
	# A theme with a style box: a [sub_resource], but not code.
	var styled := Theme.new()
	var box := StyleBoxFlat.new()
	box.bg_color = Color.BLUE
	styled.set_stylebox("panel", "Panel", box)
	ResourceSaver.save(styled, V + "assets/styled_theme.tres")
	# The project's own resource class, and a plain Resource with no note fields.
	write_text(V + "assets/item.tres", "[gd_resource type=\"Resource\" script_class=\"Item\" load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"res://item.gd\" id=\"1_item\"]\n\n[resource]\nscript = ExtResource(\"1_item\")\nname = \"Sword\"\n")
	write_text(V + "assets/settings.tres", "[gd_resource type=\"Resource\" format=3]\n\n[resource]\nresource_name = \"settings\"\n")
	return ["assets/red.tres", "theme.tres", "assets/styled_theme.tres", "assets/item.tres", "assets/settings.tres"]


func test_foreign_resources_untouched(V: String) -> void:
	VaultStore.create_note("A real note")
	var files: Array[String] = write_foreign(V)
	var hashes: Dictionary = {}
	for f in files:
		hashes[f] = FileAccess.get_sha256(V + f)
	VaultStore.open_vault(V, false)
	for f in files:
		check(FileAccess.get_sha256(V + f) == hashes[f], "%s is not rewritten" % f)
		check(not listed_paths().has(V + f), "%s is not listed as a note" % f)
	check(FileAccess.get_file_as_string(V + "assets/red.tres").begins_with("[gd_resource type=\"StandardMaterial3D\""), "the material still opens as a material")
	check(VaultStore.get_note_count() == 1 and VaultStore.get_note_index("A real note") >= 0, "the vault lists only its real note")
	check(VaultStore.unsafe_files.is_empty() and VaultStore.unsafe_warning() == "", "foreign files are not reported as code (%s)" % VaultStore.unsafe_warning())
	VaultStore.refresh_note_list()
	var unchanged: bool = true
	for f in files:
		unchanged = unchanged and FileAccess.get_sha256(V + f) == hashes[f]
	check(unchanged and VaultStore.get_note_count() == 1, "a rescan leaves them alone too")

	var tools: RefCounted = VaultTools.new(V)
	for f in ["assets/red.tres", "assets/styled_theme.tres"]:
		var r: Dictionary = tools.call_tool("read_note", {"path": f})
		check(r.get("isError", false) and str(r.structuredContent.error.code) == "not_a_note", "MCP read_note on %s: not_a_note (%s)" % [f, r.structuredContent.get("error", {}).get("code", "")])
	var listed: Array = tools.call_tool("list_notes", {}).structuredContent.notes.map(func(n): return n.path)
	check(listed == ["note_a_real_note.tres"], "MCP list_notes lists only the real note (%s)" % [listed])


func test_scriptless_note_repaired(V: String) -> void:
	var path: String = V + "note_hand_written.tres"
	write_text(path, "[gd_resource type=\"Resource\" format=3]\n\n[resource]\ntitle = \"Hand written\"\nraw_text = \"Written without the script line; [resource]\nstays in the body.\"\n")
	VaultStore.refresh_note_list()
	var i: int = VaultStore.get_note_index("Hand written")
	check(i >= 0, "a scriptless hand-written note is repaired and loads with its title")
	check(i >= 0 and VaultStore.load_note(i).raw_text == "Written without the script line; [resource]\nstays in the body.", "its body is untouched by the repair")
	var text: String = FileAccess.get_file_as_string(path)
	check(text.contains("script = ExtResource(") and text.count("script = ") == 1, "the file gains exactly one script line")


## A note from another tool, or written by hand, without a title line. The
## validator names it after its file ("note_blank.tres" -> "Blank") in memory
## only. It used to read a `file_path` property ContentLayer doesn't have:
## a SCRIPT ERROR on every scan, and the note stayed untitled.
func test_untitled_note_gets_a_title(V: String) -> void:
	var path: String = V + "note_blank.tres"
	write_text(path, "[gd_resource type=\"Resource\" script_class=\"ContentLayer\" load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"res://ContentLayer.gd\" id=\"1_cl\"]\n\n[resource]\nscript = ExtResource(\"1_cl\")\nraw_text = \"A note with no title line.\"\n")
	var before: String = FileAccess.get_sha256(path)
	VaultStore.open_vault(V, false)
	var i: int = VaultStore.get_note_index("Blank")
	check(i >= 0, "a note without a title line is titled after its file: Blank")
	check(i >= 0 and VaultStore.load_note(i).raw_text == "A note with no title line.", "…with its body")
	check(FileAccess.get_sha256(path) == before, "…and its file is not rewritten")
	var n := ContentLayer.new()
	n.resource_path = V + "Physics/note_wave_speed.tres"
	n.tags = ["kept"] as Array[String]
	var r: Dictionary = TresValidator.validate_note(n)
	check(not r.valid, "(validate_note sees the missing title)")
	check(TresValidator._generate_title_from_path("") == "Untitled Note" and TresValidator._generate_title_from_path("/v/note_.tres") == "Untitled Note", "a path with no name left gives \"Untitled Note\"")
	check(TresValidator._auto_fix(n) and n.title == "Wave Speed" and n.tags == (["kept"] as Array[String]), "_auto_fix titles it \"Wave Speed\" and keeps its tags (%s, %s)" % [n.title, n.tags])


## The scriptless-note check looks for a `script =` and a `title =` or
## `raw_text =` line. Its line-start patterns used \s for the indent, which
## also matches newlines: from every line start a match ran on through all
## the blank lines after it. A file of blank lines and no such line (a
## plain Resource, never repaired, so every scan met it again) froze each
## scan for seconds (200 000 blank lines: 12 s per open or rescan).
func test_blank_lines_scan_in_linear_time(V: String) -> void:
	var head: String = "[gd_resource type=\"Resource\" format=3]\n\n[resource]\n"
	var pad: String = head + "\n".repeat(200000) + "resource_name = \"x\"\n"
	var t0: int = Time.get_ticks_msec()
	var scriptless: bool = VaultStore._is_scriptless_note(pad)
	var ms: int = Time.get_ticks_msec() - t0
	check(not scriptless and ms < 1000, "200 000 blank lines are read in linear time (%d ms)" % ms)
	check(VaultStore._is_scriptless_note(head + "\t  title = \"Indented\"\n"), "an indented title line still counts")
	check(VaultStore._is_scriptless_note(head + "\r\ntitle = \"CRLF\"\r\n"), "…and a title line after a CRLF")
	check(not VaultStore._is_scriptless_note(head + "title = \"x\"\n  script = null\n"), "an indented script line still counts as one")
	var path: String = V + "note_pad.tres"
	write_text(path, pad)
	var before: String = FileAccess.get_sha256(path)
	t0 = Time.get_ticks_msec()
	VaultStore.open_vault(V, false)
	VaultStore.refresh_note_list()
	ms = Time.get_ticks_msec() - t0
	check(ms < 2000, "opening and rescanning a vault holding it takes %d ms" % ms)
	check(FileAccess.get_sha256(path) == before and not listed_paths().has(path), "it is left untouched and not listed")
	DirAccess.remove_absolute(path)


# ── Symbolic links ─────────────────────────────────────────────────────────
# Skipped on Windows, where making a link needs admin rights. Each vault here
# is its own folder, removed by remove_links_tree: TestVault.remove_tree
# would follow the links.

## A note file's text, titled `title`.
func note_text(title: String) -> String:
	return "[gd_resource type=\"Resource\" script_class=\"ContentLayer\" format=3]\n\n[ext_resource type=\"Script\" path=\"res://ContentLayer.gd\" id=\"1_cl\"]\n\n[resource]\nscript = ExtResource(\"1_cl\")\ntitle = \"%s\"\nraw_text = \"Body.\"\n" % title


## An empty folder user://<name>/, emptied of what an earlier run left.
func fresh_dir(name: String) -> String:
	var path: String = ProjectSettings.globalize_path("user://%s/" % name)
	remove_links_tree(path)
	DirAccess.make_dir_recursive_absolute(path)
	return path


## Remove `path` and all in it; a link is removed itself, never followed.
func remove_links_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	for d in dir.get_directories():
		if dir.is_link(d):
			DirAccess.remove_absolute(path.path_join(d))
		else:
			remove_links_tree(path.path_join(d))
	for f in dir.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


## Make `link_path` (absolute) a symbolic link to `target`, as written:
## relative to the link's folder, or absolute. With ln, as in the bug
## reports: DirAccess.create_link can't make `a -> .`.
func link(target: String, link_path: String) -> bool:
	return OS.execute("ln", ["-s", target, link_path]) == 0


func titles() -> Array:
	return VaultStore.note_list.map(func(n): return n.title)


func test_symbolic_links() -> void:
	if OS.get_name() == "Windows":
		print("SKIP  symbolic link tests (making a link on Windows needs admin rights)")
		return
	var outside: String = fresh_dir("test-links-outside")
	write_text(outside + "note_outside.tres", note_text("Outside note"))
	test_link_back_up()
	test_links_to_the_vault_itself()
	test_link_out_of_the_vault(outside)
	test_depth_cap()
	test_remove_folder_with_links(outside)
	test_move_folder_with_links(outside)
	test_mcp_stays_in_the_vault(outside)
	test_windows_network_link()
	remove_links_tree(outside)


## `sub/up -> ..` leads back to the vault: each note was listed 41 times
## and each folder 81 (path length was the only limit).
func test_link_back_up() -> void:
	var L: String = fresh_dir("test-vault-link-up")
	write_text(L + "note_only.tres", note_text("Only note"))
	DirAccess.make_dir_recursive_absolute(L + "sub")
	check(link("..", L + "sub/up"), "(made sub/up -> ..)")
	VaultStore.open_vault(L, false)
	check(VaultStore.note_list.size() == 1, "sub/up -> ..: the note is listed once (%d)" % VaultStore.note_list.size())
	check(VaultStore.folders == (["sub"] as Array[String]), "…and the folders are just sub (%d: %s)" % [VaultStore.folders.size(), VaultStore.folders.slice(0, 3)])
	check(not VaultStore.disk_signature().contains("up/"), "disk_signature leaves the link out too")
	var listed: Dictionary = VaultTools.new(L).call_tool("list_notes", {}).structuredContent
	check(listed.get("count") == 1 and listed.get("folders") == ["sub"], "MCP list_notes lists it once (%s, %s)" % [listed.get("count"), str(listed.get("folders", [])).left(80)])
	remove_links_tree(L)


## `a -> .` and `b -> .`: the paths double at each level, and opening the
## vault did not finish in 25 s.
func test_links_to_the_vault_itself() -> void:
	var L: String = fresh_dir("test-vault-link-self")
	write_text(L + "note_only.tres", note_text("Only note"))
	check(link(".", L + "a") and link(".", L + "b"), "(made a -> . and b -> .)")
	var t0: int = Time.get_ticks_msec()
	VaultStore.open_vault(L, false)
	var ms: int = Time.get_ticks_msec() - t0
	check(ms < 2000 and VaultStore.note_list.size() == 1 and VaultStore.folders.is_empty(), "a -> . and b -> .: the vault opens in %d ms with its one note (%d)" % [ms, VaultStore.note_list.size()])
	t0 = Time.get_ticks_msec()
	var sig: String = VaultStore.disk_signature()
	var count: int = VaultTools.new(L).call_tool("list_notes", {}).structuredContent.get("count", -1)
	ms = Time.get_ticks_msec() - t0
	check(ms < 2000 and sig.split("\n").size() == 1 and count == 1, "…disk_signature and MCP list_notes return in %d ms, once each (%d)" % [ms, count])
	remove_links_tree(L)


## A link to a folder outside the vault still works, once. Inside that
## folder, a link back to itself or up to its parent is not followed.
func test_link_out_of_the_vault(outside: String) -> void:
	var L: String = fresh_dir("test-vault-link-out")
	write_text(L + "note_inside.tres", note_text("Inside note"))
	check(link(outside.trim_suffix("/"), L + "ext") and link(outside.trim_suffix("/"), L + "ext_again"), "(made ext and ext_again -> the outside folder)")
	check(link(".", outside + "self") and link("..", outside + "parent"), "(made self -> . and parent -> .. in it)")
	VaultStore.open_vault(L, false)
	check(titles().count("Outside note") == 1, "a note in a linked outside folder is listed, once (%s)" % [titles()])
	check(VaultStore.get_note_index("Inside note") >= 0 and VaultStore.note_list.size() == 2, "…beside the vault's own")
	check(VaultStore.folders == (["ext"] as Array[String]), "…under ext; its self and parent links are not followed (%s)" % [VaultStore.folders.slice(0, 4)])
	for d in ["self", "parent"]:
		DirAccess.remove_absolute(outside + d)
	remove_links_tree(L)


## Folders below 32 levels are not scanned, a backstop for link chains.
func test_depth_cap() -> void:
	var L: String = fresh_dir("test-vault-deep")
	var rel: String = ""
	for i in 33:
		rel = rel.path_join("d%d" % (i + 1)) if rel != "" else "d1"
		DirAccess.make_dir_recursive_absolute(L + rel)
		write_text(L + rel + "/note_level_%d.tres" % (i + 1), note_text("Level %d" % (i + 1)))
	VaultStore.open_vault(L, false)
	check(VaultStore.get_note_index("Level 32") >= 0 and VaultStore.get_note_index("Level 33") < 0, "a note 32 folders down is listed, one 33 down is not")
	remove_links_tree(L)


## Deleting a folder without the system trash (delete_folder's fallback to
## the vault's .trash) moves a link inside it as a link, never what the link
## leads to: a link out once emptied the folder it led to, and `up -> ..`
## walked the vault again.
func test_remove_folder_with_links(outside: String) -> void:
	var L: String = fresh_dir("test-vault-link-remove")
	write_text(L + "note_kept.tres", note_text("Kept"))
	DirAccess.make_dir_recursive_absolute(L + "doomed")
	write_text(L + "doomed/note_doomed.tres", note_text("Doomed"))
	check(link("..", L + "doomed/up") and link(outside.trim_suffix("/"), L + "doomed/ext") and link(outside.trim_suffix("/"), L + "ext_folder"), "(made doomed/up, doomed/ext and ext_folder)")
	VaultStore.open_vault(L, false)
	VaultStore.system_trash_hook = func(_p: String) -> Error: return FAILED
	check(VaultStore.delete_folder("doomed") and not DirAccess.dir_exists_absolute(L + "doomed"), "a folder holding links is removed")
	check(FileAccess.file_exists(L + ".trash/doomed/note_doomed.tres"), "…into the vault's .trash")
	check(FileAccess.file_exists(L + "note_kept.tres"), "…and the rest of the vault stays")
	check(FileAccess.file_exists(outside + "note_outside.tres"), "…and so does the outside folder a link inside it led to")
	check(VaultStore.delete_folder("ext_folder") and FileAccess.file_exists(outside + "note_outside.tres"), "removing a linked folder removes the link, not the folder it leads to")
	VaultStore.system_trash_hook = Callable()
	remove_links_tree(L)


## Moving a folder that holds links (move_folder, whose _files_under carries
## each file's hash and mtime to its new path) walks no link back into the
## vault: `a -> .` plus `b -> .` never finished. A link out of the vault is
## still followed, as the scan follows it, so its notes keep their hashes.
func test_move_folder_with_links(outside: String) -> void:
	var L: String = fresh_dir("test-vault-link-move")
	DirAccess.make_dir_recursive_absolute(L + "Box")
	write_text(L + "Box/note_boxed.tres", note_text("Boxed"))
	check(link(".", L + "Box/a") and link(".", L + "Box/b") and link("..", L + "Box/up") and link(outside.trim_suffix("/"), L + "Box/ext"), "(made Box/a, Box/b, Box/up and Box/ext)")
	VaultStore.open_vault(L, false)
	check(VaultStore.move_folder("Box", "Moved") == "Moved", "a folder holding links back into the vault moves")
	var i: int = VaultStore.get_note_index("Boxed")
	check(i >= 0 and VaultStore.note_list[i].resource_path == L + "Moved/note_boxed.tres", "…its note is listed at its new path")
	check(VaultStore._hashes.has(L + "Moved/note_boxed.tres") and not VaultStore._hashes.has(L + "Box/note_boxed.tres"), "…and its hash moved with it")
	check(VaultStore._hashes.has(L + "Moved/ext/note_outside.tres") and not VaultStore._hashes.has(L + "Box/ext/note_outside.tres"), "…as did the hash of a note behind the link out of the vault")
	var under: PackedStringArray = VaultStore._files_under(L + "Moved/")
	check(not Array(under).any(func(f): return str(f).begins_with("a/") or str(f).begins_with("b/") or str(f).begins_with("up/")), "_files_under walks no link back into the vault (%s)" % [Array(under).slice(0, 4)])
	remove_links_tree(L)


## The MCP tools never leave the vault through a link: their client is an
## LLM that text in an imported note can steer. A path through a link out
## of the vault (`out`, a note file linked out) or into a hidden folder is
## refused with invalid_path, and list_notes and search_notes leave such
## links out. A link to an ordinary folder inside the vault may be read
## through. (The app itself still follows `out`: the user made it.)
## A planted or left-over link where a new note's file would go (one that
## leads nowhere yet: create_note's "file exists" check passed it), or in
## .trash where delete_note puts the note, wrote the new note outside or
## moved the user's note out of the vault.
func test_mcp_stays_in_the_vault(outside: String) -> void:
	var L: String = fresh_dir("test-vault-mcp-links")
	var trash_out: String = fresh_dir("test-links-outside-trash")
	write_text(L + "note_inside.tres", note_text("Inside note"))
	DirAccess.make_dir_recursive_absolute(L + "Physics")
	write_text(L + "Physics/note_waves.tres", note_text("Waves"))
	DirAccess.make_dir_recursive_absolute(L + ".ontomeme")
	DirAccess.make_dir_recursive_absolute(L + ".trash")
	check(link(outside.trim_suffix("/"), L + "out") and link(outside + "note_outside.tres", L + "note_leak.tres")
			and link(".ontomeme", L + "hid") and link("Physics", L + "alias") and link(".", L + "loop"), "(made out, note_leak.tres, hid, alias and loop)")
	check(link(outside + "note_escape.tres", L + "Physics/note_escape.tres") and link(outside + "note_escape.txt", L + "Physics/note_escape.txt")
			and link(trash_out.trim_suffix("/"), L + ".trash/Physics"), "(made Physics/note_escape.tres and .txt -> missing files outside, .trash/Physics -> a folder outside)")
	var tools: RefCounted = VaultTools.new(L)
	var outside_hash: String = FileAccess.get_sha256(outside + "note_outside.tres")
	var waves_hash: String = FileAccess.get_sha256(L + "Physics/note_waves.tres")
	var calls: Array = [
		["read_note", {"path": "out/note_outside.tres"}],
		["update_note", {"path": "out/note_outside.tres", "hash": outside_hash, "markdown": "overwritten"}],
		["delete_note", {"path": "out/note_outside.tres", "hash": outside_hash}],
		["create_note", {"title": "Escaped", "folder": "out"}],
		["create_note", {"title": "Escaped", "folder": "out/deeper"}],
		["list_notes", {"folder": "out"}],
		["search_notes", {"folder": "out", "query": "Body"}],
		["read_note", {"path": "note_leak.tres"}],
		["update_note", {"path": "note_leak.tres", "hash": outside_hash, "markdown": "overwritten"}],
		["create_note", {"title": "Hidden", "folder": "hid"}],
		["read_note", {"path": "loop/../out/note_outside.tres"}],
		["create_note", {"title": "Escape", "markdown": "written outside", "folder": "Physics"}],
		["create_note", {"title": "Escape", "markdown": "written outside", "folder": "Physics", "format": "text"}],
		["delete_note", {"path": "Physics/note_waves.tres", "hash": waves_hash}],
	]
	var not_refused: PackedStringArray = []
	for c in calls:
		var r: Dictionary = tools.call_tool(c[0], c[1])
		var code: String = str(r.structuredContent.get("error", {}).get("code", "ok"))
		if code != "invalid_path":
			not_refused.append("%s %s: %s" % [c[0], c[1].get("path", c[1].get("folder")), code])
	check(not_refused.is_empty(), "MCP refuses each path through a link out of the vault or into a hidden folder with invalid_path (%s)" % "; ".join(not_refused))
	check(FileAccess.get_sha256(outside + "note_outside.tres") == outside_hash and DirAccess.get_files_at(outside) == PackedStringArray(["note_outside.tres"])
			and DirAccess.get_directories_at(outside).is_empty(), "…and writes nothing outside (%s)" % [DirAccess.get_files_at(outside)])
	check(DirAccess.get_files_at(L + ".ontomeme").is_empty(), "…nor in the hidden folder")
	check(DirAccess.get_files_at(trash_out).is_empty() and FileAccess.get_sha256(L + "Physics/note_waves.tres") == waves_hash,
			"…and moves no note out through a link in .trash (%s)" % [DirAccess.get_files_at(trash_out)])
	var t0: int = Time.get_ticks_msec()
	var listed: Dictionary = tools.call_tool("list_notes", {}).structuredContent
	var ms: int = Time.get_ticks_msec() - t0
	var paths: Array = listed.get("notes", []).map(func(n): return n.path)
	paths.sort()
	check(paths == ["Physics/note_waves.tres", "note_inside.tres"] and listed.get("folders") == ["Physics"], "list_notes lists nothing through the links (%s, %s)" % [paths, listed.get("folders")])
	check(ms < 2000, "…and returns in %d ms with loop -> . in the vault" % ms)
	var found: int = tools.call_tool("search_notes", {"query": "Body"}).structuredContent.get("total", -1)
	check(found == 2, "search_notes finds only the vault's own notes (%d)" % found)
	var through: Dictionary = tools.call_tool("read_note", {"path": "alias/note_waves.tres"})
	check(not through.isError and through.structuredContent.get("title") == "Waves", "a link to a folder inside the vault can be read through")
	VaultStore.open_vault(L, false)
	check(VaultStore.get_note_index("Outside note") >= 0, "the app still lists the note in the folder the user linked")
	for f in ["note_escape.tres", "note_escape.txt"]:
		DirAccess.remove_absolute(outside + f)
		DirAccess.remove_absolute(L + "Physics/" + f)
	remove_links_tree(L)
	remove_links_tree(trash_out)


## On Windows read_link gives a link to a network share, or to a mapped
## drive, as "UNC/server/share/...". Taken as a path relative to the link,
## it put the share inside the vault: the MCP tools read and wrote it, and
## the app's scan stopped listing it. Checked here with VaultStore._windows
## set, through a link that reads back the way Windows reports one.
func test_windows_network_link() -> void:
	var was_windows: bool = VaultStore._windows
	VaultStore._windows = true
	check(VaultStore._link_text("UNC/nas/team/sub") == "//nas/team/sub" and VaultStore._link_text("\\\\?\\UNC\\nas\\team") == "//nas/team",
			"Windows: read_link's UNC/server/share/... is the network path //server/share/... (%s)" % VaultStore._link_text("UNC/nas/team/sub"))
	check(VaultStore._link_text("C:\\Users\\me") == "C:/Users/me" and VaultStore._link_text("Users/me") == "",
			"…a drive path is kept, and an answer with no root can't be read (\"\")")
	check(VaultStore._path_root("//nas/team/sub") == "//nas/team/" and VaultStore._path_root("//nas/team") == "//nas/team/" and VaultStore._path_root("//nas") == "",
			"…and //server/share/ is a root (%s)" % VaultStore._path_root("//nas/team/sub"))
	var L: String = fresh_dir("test-vault-network-link")
	write_text(L + "note_inside.tres", note_text("Inside note"))
	check(link("UNC/nas/team", L + "Team"), "(made Team -> UNC/nas/team)")
	check(VaultStore._real_rel(L, "Team/note_x.tres") == null, "a path through a link to a network share leads out of the vault (%s)" % [VaultStore._real_rel(L, "Team/note_x.tres")])
	var tools: RefCounted = VaultTools.new(L)
	var not_refused: PackedStringArray = []
	for c in [["read_note", {"path": "Team/note_x.tres"}], ["update_note", {"path": "Team/note_x.tres", "hash": "x", "markdown": "overwritten"}],
			["create_note", {"title": "Escaped", "folder": "Team"}], ["list_notes", {"folder": "Team"}]]:
		var code: String = str(tools.call_tool(c[0], c[1]).structuredContent.get("error", {}).get("code", "ok"))
		if code != "invalid_path":
			not_refused.append("%s: %s" % [c[0], code])
	check(not_refused.is_empty(), "…so MCP refuses it with invalid_path (%s)" % "; ".join(not_refused))
	check(VaultStore._should_descend(L, "", "Team", {}), "…and the app follows it, like any link out of the vault")
	VaultStore._windows = false
	check(VaultStore._link_text("UNC/nas/team") == "UNC/nas/team" and VaultStore._path_root("//nas/team/sub") == "/", "elsewhere UNC/... is a relative link and //x is under /")
	VaultStore._windows = was_windows
	DirAccess.remove_absolute(L + "Team")
	remove_links_tree(L)
