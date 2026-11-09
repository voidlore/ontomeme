extends SceneTree
## A note file must never run code when Ontomeme opens it. A .tres can embed
## a GDScript ([sub_resource], an Object(...) value, a script as the main
## resource) or point at one ([ext_resource], Resource("...")), and Godot runs
## that script's _init or static initialisers while it loads the file.
## TresValidator.check_text_safe reads the text first; VaultStore, the MCP
## tools and TresValidator.validate never load a file that fails it.
##   godot --headless --path . -s res://tests/tres_safety_test.gd

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")
const StarterContent = preload("res://starter_content.gd")

## Each crafted note writes its marker file if its code ever runs.
const VARIANTS: Array[String] = ["sub_init", "sub_static", "ext_script", "object", "resource_path", "main_script", "comment_trick", "control_char", "smuggle_array_uid", "smuggle_number_uid", "smuggle_header", "remap", "import"]
## The variants that hide a field from a scanner that does not read a tag the
## way Godot does (crafted() has the files).
const SMUGGLED: Array[String] = ["note_smuggle_array.tres", "note_smuggle_number.tres", "note_smuggle_header.tres"]
const SCAN_FILE: String = "user://test-tres-safety-scan.tres"

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func _init() -> void:
	ProgressStore.file_override = "user://test_progress_tres_safety.json"   # never touch real progress
	JourneyStore.file_override = "user://test_journey_tres_safety.json"     # never touch the real journey
	_remove_markers()
	test_smuggled_variants_are_real()
	_remove_markers()
	test_scanner()
	test_header()
	var V: String = TestVault.open("tres-safety", false)
	test_vault_skips_code(V)
	test_note_mentioning_code_loads(V)
	test_mcp_refuses_code(V)
	test_validate_refuses_code(V)
	await test_status_bar(V)
	TestVault.remove_tree(V)
	test_seeded_vault_loads_every_note()
	_remove_markers()
	for f in [ProgressStore.file_override, JourneyStore.file_override, SCAN_FILE]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)


# ── Crafted notes ───────────────────────────────────────────────────────────

func marker(variant: String) -> String:
	return "user://test-pwned.txt" if variant == "sub_init" else "user://test-pwned-%s.txt" % variant


func any_marker() -> bool:
	for v in VARIANTS:
		if FileAccess.file_exists(marker(v)):
			print("      code ran: ", v)
			return true
	return false


func _remove_markers() -> void:
	for v in VARIANTS:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(marker(v)))


## GDScript that writes `variant`'s marker from _init, or from a static
## initialiser (runs as soon as the script is compiled, without an instance).
func pwn_source(variant: String, static_init: bool) -> String:
	var write: String = "FileAccess.open(\"%s\", FileAccess.WRITE).store_string(\"pwned\")" % marker(variant)
	if static_init:
		return "extends Resource\nstatic var _x = _go()\nstatic func _go():\n\t%s\n\treturn 1\n" % write
	return "extends Resource\nfunc _init():\n\t%s\n" % write


## `s` as a .tres string literal, escaped the way Godot writes one.
func lit(s: String) -> String:
	return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""


const NOTE_HEAD: String = "[gd_resource type=\"Resource\" script_class=\"ContentLayer\" load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"res://ContentLayer.gd\" id=\"1_cl\"]\n\n[resource]\nscript = ExtResource(\"1_cl\")\n"


## The crafted file text for each variant, keyed by file name.
func crafted(V: String) -> Dictionary:
	return {
		"note_evil.tres": "[gd_resource type=\"Resource\" script_class=\"ContentLayer\" load_steps=2 format=3]\n\n[sub_resource type=\"GDScript\" id=\"1_evil\"]\nscript/source = %s\n\n[resource]\nscript = SubResource(\"1_evil\")\ntitle = \"Evil\"\n" % lit(pwn_source("sub_init", false)),
		"note_static.tres": "[gd_resource type=\"Resource\" format=3]\n\n[sub_resource type=\"GDScript\" id=\"1\"]\nscript/source = %s\n\n[resource]\ntitle = \"Evil static\"\n" % lit(pwn_source("sub_static", true)),
		"note_ext.tres": "[gd_resource type=\"Resource\" script_class=\"ContentLayer\" load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=%s id=\"1\"]\n\n[resource]\nscript = ExtResource(\"1\")\ntitle = \"Evil ext\"\n" % lit(V + "evil_ext.gd"),
		"note_object.tres": NOTE_HEAD + "title = \"Evil object\"\nstructure = {\"x\": Object(GDScript,\"script/source\":%s)}\n" % lit(pwn_source("object", true)),
		"note_respath.tres": NOTE_HEAD + "title = \"Evil resource path\"\nstructure = {\"x\": Resource(%s)}\n" % lit(V + "evil_res.gd"),
		"note_main.tres": "[gd_resource type=\"GDScript\" format=3]\n\n[resource]\nscript/source = %s\n" % lit(pwn_source("main_script", true)),
		# A `;` comment hides a quote from a scanner that only tracks strings.
		"note_comment.tres": "[gd_resource type=\"Resource\" format=3]\n; \"\n[sub_resource type=\"GDScript\" id=\"1\"]\nscript/source = %s\n; \"\n[resource]\ntitle = \"Evil comment\"\n" % lit(pwn_source("comment_trick", true)),
		# Godot skips control characters between "[" and the tag name.
		"note_ctrl.tres": "[gd_resource type=\"Resource\" format=3]\n[\u0001sub_resource type=\"GDScript\" id=\"1\"]\nscript/source = %s\n[resource]\ntitle = \"Evil control\"\n" % lit(pwn_source("control_char", true)),
		# Godot reads on past the "]" of `uid=[]`, and the last `path` wins. A
		# relative path is the note's own folder: no need to know the vault.
		"note_smuggle_array.tres": NOTE_HEAD.replace("id=\"1_cl\"]", "id=\"1_cl\" uid=[] path=\"evil_array_uid.gd\"]") + "title = \"Evil array uid\"\n",
		# Godot splits `1path` into the number 1 and the name `path`.
		"note_smuggle_number.tres": NOTE_HEAD.replace("id=\"1_cl\"]", "id=\"1_cl\" uid=1path=\"evil_number_uid.gd\"]") + "title = \"Evil number uid\"\n",
		# …and `format=3type="GDScript"` into format=3 and a second type.
		"note_smuggle_header.tres": "[gd_resource type=\"Resource\" format=3type=\"GDScript\"]\n\n[resource]\nscript/source = %s\n" % lit(pwn_source("smuggle_header", true)),
	}


func write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## A payload .tres in a hidden folder, which no scan reads.
func hidden_payload(V: String, variant: String) -> String:
	return V + ".cache/evil_%s.tres" % variant


## Notes whose text is clean, beside a file that makes ResourceLoader load
## a hidden payload instead (the redirect files are written by write_crafted).
## "<note>.remap" is always followed. "<note>.import" is followed when
## Godot's parser rejects the note, as it does this one (`raw_text =` with
## no value): loading it unchecked prints a Parse Error, so it has no
## positive control here, but a probe saw it run its payload.
func redirected(_V: String) -> Dictionary:
	return {
		"note_remap.tres": NOTE_HEAD + "title = \"Evil remap\"\n",
		"note_import.tres": "[gd_resource type=\"Resource\" format=3]\n\n[resource]\ntitle = \"Evil import\"\nraw_text = \n",
	}


func write_crafted(V: String) -> Dictionary:
	write_text(V + "evil_ext.gd", pwn_source("ext_script", true))
	write_text(V + "evil_res.gd", pwn_source("resource_path", true))
	write_text(V + "evil_array_uid.gd", pwn_source("smuggle_array_uid", true))
	write_text(V + "evil_number_uid.gd", pwn_source("smuggle_number_uid", true))
	DirAccess.make_dir_recursive_absolute(V + ".cache")
	for variant in ["remap", "import"]:
		write_text(hidden_payload(V, variant), "[gd_resource type=\"Resource\" format=3]\n\n[sub_resource type=\"GDScript\" id=\"1\"]\nscript/source = %s\n\n[resource]\nscript = SubResource(\"1\")\n" % lit(pwn_source(variant, true)))
	write_text(V + "note_remap.tres.remap", "[remap]\npath=%s\n" % lit(hidden_payload(V, "remap")))
	write_text(V + "note_import.tres.import", "[remap]\nimporter=\"x\"\ntype=\"Resource\"\npath=%s\n" % lit(hidden_payload(V, "import")))
	var files: Dictionary = crafted(V)
	files.merge(redirected(V))
	for name in files:
		write_text(V + name, files[name])
	return files


## A positive control: loaded straight through ResourceLoader, without the
## check, each smuggling variant does run its code. Were Godot to stop
## reading them that way, the tests below would pass for nothing.
func test_smuggled_variants_are_real() -> void:
	var D: String = ProjectSettings.globalize_path("user://test-tres-safety-direct/")
	TestVault.remove_tree(D)
	DirAccess.make_dir_recursive_absolute(D)
	write_crafted(D)
	var markers: Array[String] = ["smuggle_array_uid", "smuggle_number_uid", "smuggle_header"]
	for i in SMUGGLED.size():
		ResourceLoader.load(D + SMUGGLED[i], "", ResourceLoader.CACHE_MODE_IGNORE)
		check(FileAccess.file_exists(marker(markers[i])), "(control) %s runs its code when loaded unchecked" % SMUGGLED[i])
	ResourceLoader.load(D + "note_remap.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	check(FileAccess.file_exists(marker("remap")), "(control) note_remap.tres runs the file its .remap names when loaded unchecked")
	TestVault.remove_tree(D)


# ── The scanner ─────────────────────────────────────────────────────────────

func safe_text(text: String) -> bool:
	write_text(SCAN_FILE, text)
	return TresValidator.check_text_safe(ProjectSettings.globalize_path(SCAN_FILE)).safe


func test_scanner() -> void:
	var plain: String = NOTE_HEAD + "title = \"Plain\"\nraw_text = \"Hello\"\n"
	check(safe_text(plain), "a plain note is safe")
	check(safe_text("\ufeff" + plain), "a note saved with a UTF-8 BOM is safe (Godot loads it)")
	check(safe_text("[gd_resource type=\"Resource\" format=3]\n\n[resource]\ntitle = \"No script\"\n"), "a scriptless hand-written note is safe")
	check(safe_text(NOTE_HEAD + "raw_text = %s\n" % lit("[sub_resource type=\"GDScript\" id=\"1\"]\nObject(Resource, \"x\")\nscript = ExtResource(\"9\")\n; a comment ' quote")), "code-like text inside a string is just text")
	check(safe_text(NOTE_HEAD + "title = \"Typed\"\ntags = Array[String]([\"a\", \"b\"])\nstructure = {\n\"k\": [1, 2.5, Vector2(1, 2), Color(1, 0, 0, 1), &\"name\", null, true]\n}\n"), "typed arrays, dictionaries and value types are safe")
	var uid: String = ResourceUID.id_to_text(ResourceLoader.get_resource_uid("res://ContentLayer.gd"))
	check(safe_text(NOTE_HEAD.replace("type=\"Script\" ", "type=\"Script\" uid=\"%s\" " % uid) + "title = \"Uid\"\n"), "an ext_resource with ContentLayer.gd's own uid is safe")
	check(safe_text(NOTE_HEAD.replace("type=\"Script\" ", "type=\"Script\" uid=\"uid://notregistered1\" ") + "title = \"Unknown uid\"\n"), "an unknown uid is safe (Godot falls back to the path)")
	check(safe_text("[gd_resource type=\"StandardMaterial3D\" format=3]\n\n[resource]\nalbedo_color = Color(1, 0, 0, 1)\n"), "a code-free foreign resource is not code")

	var other_uid: String = ResourceUID.id_to_text(ResourceLoader.get_resource_uid("res://tres_validator.gd"))
	check(other_uid.begins_with("uid://"), "(tres_validator.gd has a uid: %s)" % other_uid)
	check(not safe_text(NOTE_HEAD.replace("type=\"Script\" ", "type=\"Script\" uid=\"%s\" " % other_uid) + "title = \"x\"\n"), "a uid naming another script is refused (Godot loads by uid first)")
	check(not safe_text(NOTE_HEAD.replace("res://ContentLayer.gd", "user://evil.gd")), "an ext_resource for another script is refused")
	check(not safe_text(NOTE_HEAD.replace("type=\"Script\"", "type=\"PackedScene\"")), "an ext_resource of another type is refused")
	check(not safe_text(NOTE_HEAD.replace("[resource]", "[ext_resource type=\"Script\" path=\"res://ContentLayer.gd\" id=\"2_cl\"]\n\n[resource]")), "a second ext_resource is refused")
	check(not safe_text(NOTE_HEAD.replace("path=\"res://ContentLayer.gd\"", "path=\"res://ContentLayer.gd\" path=\"user://evil.gd\"")), "a repeated attribute is refused")
	# Fields Godot reads but a regex over the tag would not.
	check(not safe_text(NOTE_HEAD.replace("id=\"1_cl\"]", "id=\"1_cl\" uid=[] path=\"evil.gd\"]")), "a field after a \"]\" inside a value (uid=[]) is refused")
	check(not safe_text(NOTE_HEAD.replace("id=\"1_cl\"]", "id=\"1_cl\" uid=1path=\"evil.gd\"]")), "a number glued to the next name (uid=1path=) is refused")
	check(not safe_text(NOTE_HEAD.replace("id=\"1_cl\"]", "id=\"1_cl\"path=\"evil.gd\"]")), "a string glued to the next name is refused")
	check(not safe_text("[gd_resource type=\"Resource\" format=3type=\"GDScript\"]\n\n[resource]\ntitle = \"x\"\n"), "a second type glued to format=3 in the header is refused")
	check(not safe_text(NOTE_HEAD.replace("[resource]", "[resource x=[1]]")), "a field that is neither a string nor a number is refused")
	check(not safe_text(NOTE_HEAD.replace("[resource]", "[resource.x]")), "a tag name Godot would extend (resource.x) is refused")
	var hidden_uid: String = "\\u0075" + other_uid.substr(1)   # "uid://…" with its "u" escaped
	check(not safe_text(NOTE_HEAD.replace("type=\"Script\" ", "type=\"Script\" uid=\"%s\" " % hidden_uid) + "title = \"x\"\n"), "a uid naming another script behind an escape is refused")
	write_text(SCAN_FILE, NOTE_HEAD.replace("type=\"Script\" ", "type=\"Script\" uid=\"uid://\u00e9\" ") + "title = \"x\"\n")
	var non_ascii: Dictionary = TresValidator.check_text_safe(ProjectSettings.globalize_path(SCAN_FILE))
	check(not non_ascii.safe and non_ascii.reason.contains("non-ASCII"), "a non-ASCII byte in a tag field is refused: %s" % non_ascii.reason)
	var long_name: String = "[gd_resource type=\"Resource\" format=3]\n\n[resource " + "a".repeat(200000) + " - b=1]\ntitle = \"x\"\n"
	var t0: int = Time.get_ticks_msec()
	var refused: bool = not safe_text(long_name)
	var ms: int = Time.get_ticks_msec() - t0
	check(refused and ms < 1000, "a 200 KB name in a tag is refused, read once and not once per character (%d ms)" % ms)
	var big_body: String = NOTE_HEAD + "title = \"Big\"\nraw_text = %s\n" % lit("word [x] \"q\" ".repeat(70000))
	t0 = Time.get_ticks_msec()
	var big_safe: bool = safe_text(big_body)
	ms = Time.get_ticks_msec() - t0
	check(big_safe and ms < 1000, "a 1 MB note body passes in time (%d ms)" % ms)
	check(not safe_text(NOTE_HEAD + "title = \"x\"\nraw_text = ExtResource(\"1_cl\")\n"), "ExtResource anywhere but the script line is refused")
	check(not safe_text(NOTE_HEAD.replace("ExtResource(\"1_cl\")", "ExtResource(\"2\")")), "a script line naming an undeclared id is refused")
	check(not safe_text(NOTE_HEAD + "title = \"a\\\\\"\n[sub_resource type=\"GDScript\" id=\"1\"]\n"), "an escaped backslash ends the string: the [sub_resource] after it is seen")
	check(not safe_text(NOTE_HEAD + "title = 'single'\n"), "a single quote outside a string is refused")
	check(not safe_text(NOTE_HEAD + "title = \"x\"\n; comment\n"), "a ; comment is refused")
	check(not safe_text(NOTE_HEAD + "title = \"x\nunterminated\n"), "an unterminated string is refused")
	check(not safe_text("[resource]\ntitle = \"No header\"\n"), "a file without a [gd_resource] header is refused")
	check(not safe_text("[gd_scene format=3]\n\n[node name=\"N\" type=\"Node\"]\n"), "a scene is refused")
	check(not safe_text("[gd_resource type=\"NoSuchClass\" format=3]\n\n[resource]\n"), "an unknown main type is refused")
	check(not safe_text(""), "an empty file is refused")
	var nul := FileAccess.open(SCAN_FILE, FileAccess.WRITE)
	nul.store_string(NOTE_HEAD)
	nul.store_8(0)
	nul.store_string("\n[sub_resource type=\"GDScript\" id=\"1\"]\n")
	nul.close()
	check(not TresValidator.check_text_safe(ProjectSettings.globalize_path(SCAN_FILE)).safe, "a NUL byte is refused")
	var plain_path: String = ProjectSettings.globalize_path(SCAN_FILE)
	write_text(SCAN_FILE, plain)
	for ext in [".remap", ".import"]:
		write_text(SCAN_FILE + ext, "[remap]\npath=\"/tmp/elsewhere.tres\"\n")
		var redirect: Dictionary = TresValidator.check_text_safe(plain_path)
		check(not redirect.safe and redirect.reason.contains(ext), "a plain note with a %s file beside it is refused: %s" % [ext, redirect.reason])
		DirAccess.remove_absolute(plain_path + ext)
	check(TresValidator.check_text_safe(plain_path).safe, "…and safe again once it is gone")
	var reason: String = TresValidator.check_text_safe("/no/such/file.tres").reason
	check(reason != "", "a missing file is refused with a reason (%s)" % reason)
	for name in crafted("/tmp/"):
		write_text(SCAN_FILE, crafted("/tmp/")[name])
		var r: Dictionary = TresValidator.check_text_safe(ProjectSettings.globalize_path(SCAN_FILE))
		check(not r.safe and r.reason != "", "%s is refused: %s" % [name, r.reason])
	check(not any_marker(), "checking a file never runs it")


## VaultStore._has_note_header reads the header the way Godot does, so a
## second type hidden in it does not pass for a note.
func test_header() -> void:
	check(VaultStore._has_note_header(NOTE_HEAD), "a note's header is a note header")
	check(VaultStore._has_note_header("\ufeff \n[gd_resource type=\"Resource\" format=3]\n[resource]\n"), "…with a BOM, leading space and no script class too")
	check(not VaultStore._has_note_header("[gd_resource type=\"Resource\" format=3type=\"GDScript\"]\n"), "type=\"Resource\" with a type glued to format=3 is not")
	check(not VaultStore._has_note_header("[gd_resource type=\"Resource\" format=3 type=\"Theme\"]\n"), "two types are not")
	check(not VaultStore._has_note_header("[gd_resource type=\"Resource\" script_class=\"Item\" format=3]\n"), "another script class is not")
	var header: String = "[gd_resource script_class=\"ContentLayer\" format=3 uid=\"a]\" type=\"Resource\"]"
	check(VaultStore._has_note_header(header + "\n"), "a \"]\" inside a string does not end the header early (its type comes after it)")
	check(TresValidator.header_end(header + "\n[resource]\n") == header.length(), "header_end skips a \"]\" inside a string")


# ── The app's vault ─────────────────────────────────────────────────────────

func test_vault_skips_code(V: String) -> void:
	var good: ContentLayer = VaultStore.create_note("Good note")
	var good_path: String = good.resource_path
	good = null
	var files: Dictionary = write_crafted(V)
	var hashes: Dictionary = {}
	for name in files:
		hashes[name] = FileAccess.get_sha256(V + name)
	VaultStore.open_vault(V, false)
	check(not any_marker(), "opening a vault with crafted notes runs none of their code")
	var titles: Array = VaultStore.note_list.map(func(n): return n.title)
	check(titles == ["Good note"], "only the real note is listed (got %s)" % [titles])
	var unchanged: bool = true
	for name in files:
		unchanged = unchanged and FileAccess.get_sha256(V + name) == hashes[name]
	check(unchanged, "no crafted file is rewritten (no 'repair' of a GDScript)")
	check(VaultStore.unsafe_files.has(V + "note_evil.tres"), "note_evil.tres is listed in VaultStore.unsafe_files")
	check(VaultStore.unsafe_files.has(V + "note_remap.tres") and VaultStore.unsafe_files.has(V + "note_import.tres"), "so are the notes a .remap or .import file redirects")
	var warning: String = VaultStore.unsafe_warning()
	check(warning.contains("contain") and warning.contains("code"), "the warning says the files contain code: " + warning)
	check(VaultStore.get_note_index("Good note") >= 0 and FileAccess.file_exists(good_path), "the vault still opens normally")

	VaultStore.refresh_note_list()
	check(not any_marker() and VaultStore.get_note_count() == 1, "a rescan (the disk watcher) skips them again")
	VaultStore.open_startup_vault(V, "/nonexistent/default-vault", false)
	check(VaultStore.startup_warning.begins_with("Skipped ") and VaultStore.startup_warning.contains("code"), "startup_warning names the skipped files: " + VaultStore.startup_warning)
	check(not any_marker(), "the startup path runs none of their code")
	# Only one unsafe file: the warning names it.
	for name in files:
		if name != "note_evil.tres":
			DirAccess.remove_absolute(V + name)
	VaultStore.refresh_note_list()
	check(VaultStore.unsafe_warning() == "Skipped note_evil.tres: it contains code", "one file: \"%s\"" % VaultStore.unsafe_warning())


func test_note_mentioning_code_loads(V: String) -> void:
	var body: String = "Godot writes [sub_resource type=\"GDScript\" id=\"1\"] and Object(Resource, \"x\") and ExtResource(\"1\").\n; not a comment\nA Windows path ends in a backslash: C:\\"
	var n: ContentLayer = VaultStore.create_note("Mentions code")
	n.raw_text = body
	VaultStore.save_note(n)
	var path: String = n.resource_path
	n = null
	check(TresValidator.check_text_safe(path).safe, "a saved note whose body mentions [sub_resource and Object(Resource is safe")
	VaultStore.open_vault(V, false)   # drops the cached notes: every file is read again
	var i: int = VaultStore.get_note_index("Mentions code")
	check(i >= 0 and VaultStore.load_note(i).raw_text == body, "it loads with its body intact")
	check(not VaultStore.unsafe_files.has(path), "it is not listed as unsafe")


func test_mcp_refuses_code(V: String) -> void:
	write_crafted(V)
	var tools: RefCounted = VaultTools.new(V)
	var r: Dictionary = tools.call_tool("read_note", {"path": "note_evil.tres"})
	check(r.get("isError", false), "MCP read_note on the crafted note is an error")
	check(str(r.structuredContent.error.code) == "unsafe_note", "its code is unsafe_note (got %s)" % r.structuredContent.error.code)
	r = tools.call_tool("read_note", {"path": "note_main.tres"})
	check(r.get("isError", false), "MCP read_note on a GDScript-typed file is an error")
	for name in SMUGGLED + ["note_remap.tres", "note_import.tres"]:
		r = tools.call_tool("read_note", {"path": name})
		check(r.get("isError", false) and not any_marker(), "MCP read_note on %s is an error and runs nothing" % name)
	check(str(tools.call_tool("read_note", {"path": "note_remap.tres"}).structuredContent.error.code) == "unsafe_note", "…note_remap.tres is an unsafe_note")
	var listed: Array = tools.call_tool("list_notes", {}).structuredContent.notes.map(func(n): return n.path)
	check(not listed.has("note_evil.tres") and not listed.has("note_remap.tres") and listed.has("note_mentions_code.tres"), "list_notes leaves the crafted notes out, keeps the real ones")
	var hits: Dictionary = tools.call_tool("search_notes", {"query": "evil"}).structuredContent
	check(hits.total == 0, "search_notes finds none of them")
	var h: String = tools.file_hash("note_evil.tres")
	r = tools.call_tool("update_note", {"path": "note_evil.tres", "hash": h, "markdown": "x"})
	check(r.get("isError", false) and FileAccess.get_sha256(V + "note_evil.tres") == h, "update_note refuses it and leaves the file alone")
	check(not any_marker(), "no MCP tool ran their code")


func test_validate_refuses_code(V: String) -> void:
	write_crafted(V)
	var r: Dictionary = TresValidator.validate(V + "note_evil.tres")
	check(not r.valid and str(r.errors).contains("UNSAFE"), "TresValidator.validate refuses it: %s" % [r.errors])
	for name in ["note_remap.tres", "note_import.tres"]:
		r = TresValidator.validate(V + name)
		check(not r.valid and str(r.errors).contains("UNSAFE") and not any_marker(), "TresValidator.validate refuses %s: %s" % [name, r.errors])
	var report: Dictionary = TresValidator.validate_vault(V)
	check(report.invalid_count >= 1 and not any_marker(), "validate_vault runs none of their code")


func test_status_bar(V: String) -> void:
	for name in crafted(V).keys() + redirected(V).keys():
		DirAccess.remove_absolute(V + name)
	VaultStore.refresh_note_list()
	VaultStore.startup_warning = ""
	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	for i in 4:
		await process_frame
	write_text(V + "note_evil.tres", crafted(V)["note_evil.tres"])   # a sync tool drops it in
	app.check_disk_changes()
	check(app.status_label.text == "Skipped note_evil.tres: it contains code", "the disk watcher's rescan names it in the status bar (%s)" % app.status_label.text)
	check(not any_marker() and VaultStore.get_note_index("Evil") < 0, "…without running it or listing it")
	app.queue_free()
	for i in 2:
		await process_frame


# ── No false positives ──────────────────────────────────────────────────────

## Every note file under `root`, the way VaultStore walks the vault.
func note_files(root: String, rel: String = "") -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(root + rel)
	for d in dir.get_directories():
		if not VaultStore._is_skipped_dir(rel, d):
			out.append_array(note_files(root, rel.path_join(d) if rel != "" else d))
	for f in dir.get_files():
		if f.ends_with(".tres"):
			out.append(root + (rel.path_join(f) if rel != "" else f))
	return out


## The first-run content (tutorials, Godot course, Memetics course): every
## note the app itself writes or imports must pass.
func test_seeded_vault_loads_every_note() -> void:
	var V: String = TestVault.open("tres-safety-seed", false)
	StarterContent.seed_vault()
	var files: Array[String] = note_files(V)
	var flagged: Array = files.filter(func(p): return not TresValidator.check_text_safe(p).safe)
	check(flagged.is_empty(), "every seeded note passes check_text_safe (flagged: %s)" % [flagged])
	var on_disk: int = files.size()
	VaultStore.open_vault(V, false)   # every file is read again, through the check
	check(on_disk >= 19 and VaultStore.get_note_count() == on_disk, "the tutorials and both courses all load (%d of %d)" % [VaultStore.get_note_count(), on_disk])
	check(VaultStore.unsafe_files.is_empty() and VaultStore.unsafe_warning() == "", "none of them is flagged as unsafe")
	TestVault.remove_tree(V)
