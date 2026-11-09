extends SceneTree
## images/ is the vault's picture folder, an asset folder like models/: the
## sidebar, the disk watcher and the MCP list leave a root images/ out (and
## any .tres in it: the app never stores notes there), while a nested
## "Physics/images" stays an ordinary note folder. The Markdown importer copies
## <src>/images/ into <vault>/images/ (not on a dry run) and does not read it
## for notes; lint_notes warns about a ref whose file is in neither images/
## folder, and about web, data:, outside-the-vault and unsupported targets.
##   godot --headless --path . -s res://tests/image_vault_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const McpProtocol = preload("res://mcp/protocol.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")
const NoteImporter = preload("res://note_importer.gd")

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func save_image(path: String, colour: Color) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(colour)
	img.save_png(path)


func write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _init() -> void:
	ProgressStore.file_override = "user://test_progress_image_vault.json"   # never touch real progress
	ProgressStore.reset()
	JourneyStore.file_override = "user://test_journey_image_vault.json"     # never touch the real journey
	JourneyStore.reset()

	var V: String = TestVault.open("image_vault", false)
	check_asset_folder(V)
	check_mcp_list(V)
	check_importer()
	check_lint(V)

	for f in [ProgressStore.file_override, JourneyStore.file_override]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	print("\nRESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(0 if fails == 0 else 1)


## The sidebar's folders, the watcher's signature and the note list.
func check_asset_folder(V: String) -> void:
	save_image(V.path_join("images/x.png"), Color.RED)
	DirAccess.make_dir_recursive_absolute(V.path_join("images/diagrams"))
	DirAccess.make_dir_recursive_absolute(V.path_join("Physics/images"))
	VaultStore.create_note("Waves", "Physics/images")
	VaultStore.create_note("Top Note")
	# A note file someone put in images/ by hand (the app never writes one there)
	var stray: ContentLayer = VaultStore.create_note("Stray")
	DirAccess.rename_absolute(stray.resource_path, V.path_join("images/note_stray.tres"))
	VaultStore.refresh_note_list()

	check("images" not in VaultStore.folders, "a root images/ is not a sidebar folder (%s)" % [VaultStore.folders])
	check(not VaultStore.folders.any(func(f: String) -> bool: return f.begins_with("images/")), "nor are its subfolders")
	check("Physics/images" in VaultStore.folders, "a nested Physics/images stays a note folder")
	check(VaultStore.get_note_index("Waves") >= 0, "a note in Physics/images is listed")
	check(VaultStore.get_note_index("Top Note") >= 0, "a root note is listed")
	check(VaultStore.get_note_index("Stray") == -1,
		"a .tres inside the root images/ is not listed: images/ is an asset folder, like models/")
	var sig: String = VaultStore.disk_signature()
	check(not sig.contains("images/x.png") and not sig.split("\n").has("images/"),
		"the disk watcher's signature leaves images/ out, so adding a picture is no vault change")
	var before: String = VaultStore.disk_signature()
	save_image(V.path_join("images/y.png"), Color.BLUE)
	check(VaultStore.disk_signature() == before, "a new file in images/ leaves the signature as it was")


func check_mcp_list(V: String) -> void:
	var p: RefCounted = McpProtocol.new(VaultTools.new(V))
	p.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
	var r: Variant = p.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
		"params": {"name": "list_notes", "arguments": {}}})
	var listed: Dictionary = r.result.get("structuredContent", {}) if r is Dictionary and r.has("result") else {}
	var folders: Array = listed.get("folders", [])
	var paths: Array = listed.get("notes", []).map(func(n: Dictionary) -> String: return str(n.path))
	check(not listed.is_empty() and "images" not in folders, "MCP list_notes lists no images folder (%s)" % [folders])
	check(not paths.any(func(x: String) -> bool: return x.begins_with("images/")), "MCP list_notes lists no note under images/")
	check("Physics/images" in folders and paths.has("Physics/images/note_waves.tres"),
		"MCP list_notes keeps the nested Physics/images folder and its note")


## import_dir copies <src>/images/ into the vault and keeps the note's ref.
func check_importer() -> void:
	var V: String = TestVault.open("image_vault_import", false)
	var src: String = ProjectSettings.globalize_path("user://test-image-vault-src/")
	TestVault.remove_tree(src)
	write_text(src.path_join("a.md"), "# A\n![a](images/a.png)\n")
	save_image(src.path_join("images/a.png"), Color.GREEN)
	save_image(src.path_join("images/diagrams/d.png"), Color.YELLOW)
	write_text(src.path_join("images/readme.md"), "not a lesson\n")
	write_text(src.path_join("images/anim.gif"), "GIF89a")

	var dry := NoteImporter.new()
	dry.dry = true
	check(dry.import_dir(src) == 1, "a dry run counts one note (images/readme.md is not one)")
	check(not FileAccess.file_exists(V.path_join("images/a.png")), "a dry run copies no image")

	var importer := NoteImporter.new()
	check(importer.import_dir(src) == 1, "the import makes one note")
	var copied: String = V.path_join("images/a.png")
	check(FileAccess.file_exists(copied) and FileAccess.get_sha256(copied) == FileAccess.get_sha256(src.path_join("images/a.png")),
		"<src>/images/a.png is copied to <vault>/images/a.png")
	check(FileAccess.file_exists(V.path_join("images/diagrams/d.png")), "a subfolder of images/ comes along")
	check(not FileAccess.file_exists(V.path_join("images/anim.gif")) and not FileAccess.file_exists(V.path_join("images/readme.md")),
		"only png, jpg and webp files are copied")
	var i: int = VaultStore.get_note_index("a")
	check(i >= 0 and VaultStore.note_list[i].raw_text.contains("![a](images/a.png)"), "the note keeps its ref")
	check(i >= 0 and ImageEmbeds.load_texture(ImageEmbeds.resolve("images/a.png", V)) != null, "and the ref resolves to a picture in the vault")
	check(VaultStore.get_note_index("readme") == -1 and "images" not in VaultStore.folders, "no note or folder comes from images/")

	# Re-running refreshes a picture the course changed
	save_image(src.path_join("images/a.png"), Color.PURPLE)
	NoteImporter.new().import_dir(src)
	check(FileAccess.get_sha256(copied) == FileAccess.get_sha256(src.path_join("images/a.png")), "re-importing updates a changed picture")
	TestVault.remove_tree(src)


## Run scripts/lint_notes.gd on a source folder and read what it prints.
func check_lint(V: String) -> void:
	var src: String = ProjectSettings.globalize_path("user://test-image-vault-lint/")
	TestVault.remove_tree(src)
	save_image(src.path_join("images/here.png"), Color.GREEN)
	write_text(src.path_join("pics.md"), "\n".join([
		"---",
		"title: Pics",
		"---",
		"![in the source](images/here.png)",
		"![in the vault](images/x.png)",
		"![bare name](x.png)",
		"![gone](images/missing.png)",
		"![web](https://example.com/a.png)",
		"![inline](data:image/png;base64,iVBORw0KGgo)",
		"![outside](../secret.png)",
		"![anim](images/spin.gif)",
		"```",
		"![fenced](images/fenced.png)",
		"```",
		"",
	]))
	var output: Array = []
	var args: PackedStringArray = ["--headless", "--no-header", "--path", ProjectSettings.globalize_path("res://"),
		"-s", "res://scripts/lint_notes.gd", "--", src, "--vault=" + V]
	var code: int = OS.execute(OS.get_executable_path(), args, output, true)
	var text: String = "\n".join(output)
	var warns: PackedStringArray = []
	for line in text.split("\n"):
		if line.begins_with("WARN") or line.begins_with("ERROR"):
			warns.append(line)
	print("      lint printed:\n        " + "\n        ".join(warns))
	check(code == 0, "image warnings are warnings, not errors (exit %d)" % code)
	check(text.contains("image not found: images/missing.png"), "a missing file prints 'image not found: images/missing.png'")
	check(warns.size() == 5, "five image warnings, one per bad ref (%d)" % warns.size())
	check(text.contains("https://example.com/a.png") and text.contains("web"), "a web URL is warned about")
	check(text.contains("data:"), "a data: URI is warned about")
	check(text.contains("../secret.png") and text.contains("outside the vault"), "a path leaving the vault is warned about")
	check(text.contains("images/spin.gif") and text.contains("png, jpg or webp"), "a .gif is warned about")
	var warned: String = "\n".join(warns)
	check(not warned.contains("here.png") and not warned.contains("x.png"), "files in <src>/images or <vault>/images pass")
	check(not warned.contains("fenced.png"), "a ref inside a fence is not checked")
	TestVault.remove_tree(src)
