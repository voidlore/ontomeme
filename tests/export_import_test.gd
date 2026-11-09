extends SceneTree
## Vault export and import, without the UI.
##   godot --headless --path . -s res://tests/export_import_test.gd
## Part 1: VaultStore.export_to copies the whole vault (Journey, progress,
## ui.json, subfolders, models) into a new dated folder, leaves out the
## trash, never replaces an earlier export and never copies into itself.
## Part 2: on Windows every reparse point is a "link" to DirAccess, OneDrive's
## cloud placeholders included; the export still copies those (they resolve
## to themselves) and leaves out only folders that link elsewhere.
## Part 3: VaultStore.import_vault brings an export (or any folder of notes)
## into another vault: every note in its folder, models, images, .md files
## through NoteImporter. Nothing is replaced: a taken title gets " (2)", a
## note already there is skipped, and a .tres that isn't a note (or could run
## code) is never loaded.
## Part 4: the imported folder's .ontomeme/journey.json merges into the
## Learning Journey: topics and objectives by name, demos by activity, new
## log entries only, following notes the import renamed.
## Part 5: a vault's Markdown export (exports/, marked .ontomeme-export, which
## no scan lists) travels in its vault export, and is never imported as notes:
## not into a fresh vault, nor back into the vault itself.
## Part 6: a note whose file was deleted outside the app (Claude's
## delete_note) imports from a backup as itself, at its free file name, not
## as a conflict copy of the deleted file.

const TestVault = preload("res://tests/test_vault.gd")
const VaultTools = preload("res://mcp/vault_tools.gd")
## What evil.tres's script would write if an import ever loaded it.
const PWNED: String = "user://test-import-pwned"
var fails: int = 0


## DirAccessWindows as it sees a vault in a OneDrive-backed Documents: every
## folder is a reparse point (is_link), and read_link gives the folder's
## final path: itself for a placeholder, the target for a symlink. With
## `real_root` set, `root` is reached through a junction to there.
class WindowsProbe:
	var root: String
	var real_root: String

	func _init(vault_root: String, junction_to: String = "") -> void:
		root = vault_root.trim_suffix("/")
		real_root = junction_to

	func is_link(p: String) -> bool:
		return DirAccess.dir_exists_absolute(p)

	func read_link(p: String) -> String:
		var d := DirAccess.open(p.get_base_dir())
		if d != null and d.is_link(p):
			var t: String = d.read_link(p)
			return t if t.is_absolute_path() else p.get_base_dir().path_join(t).simplify_path()
		if real_root != "" and (p == root or p.begins_with(root + "/")):
			return real_root + p.substr(root.length())
		return p


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


## A note file the way Godot writes one.
func write_note(path: String, title: String, text: String, tags: Array = []) -> void:
	var quoted: PackedStringArray = PackedStringArray(tags.map(func(t): return JSON.stringify(t)))
	write(path, ("[gd_resource type=\"Resource\" script_class=\"ContentLayer\" format=3]\n\n"
		+ "[ext_resource type=\"Script\" path=\"res://ContentLayer.gd\" id=\"1_cl\"]\n\n"
		+ "[resource]\nscript = ExtResource(\"1_cl\")\ntitle = %s\ncreated = \"2026-01-02T03:04:05\"\n"
		+ "modified = \"2026-01-02T03:04:05\"\ntags = Array[String]([%s])\nraw_text = %s\n")
		% [JSON.stringify(title), ", ".join(quoted), JSON.stringify(text)])


## An import result without its list of note objects, for the log.
func shown(r: Dictionary) -> Dictionary:
	var out: Dictionary = r.duplicate()
	out.imported = r.imported.map(func(n: ContentLayer) -> String: return n.title)
	return out


func note_titled(title: String) -> ContentLayer:
	var i: int = VaultStore.get_note_index(title)
	return VaultStore.note_list[i] if i >= 0 else null


## Every file under `root`, hidden ones too, relative and sorted.
func tree(root: String, rel: String = "") -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(root.path_join(rel))
	if dir == null:
		return out
	dir.include_hidden = true
	for d in dir.get_directories():
		if not dir.is_link(d):
			out.append_array(tree(root, rel.path_join(d)))
	for f in dir.get_files():
		out.append(rel.path_join(f))
	out.sort()
	return out


func _init() -> void:
	# The stores write into the throwaway vault's own .ontomeme/, which is
	# exactly what an export has to carry.
	JourneyStore.file_override = ""
	ProgressStore.file_override = ""
	var outside: String = ProjectSettings.globalize_path("user://test-export-outside")
	var dl: String = ProjectSettings.globalize_path("user://test-export-downloads")
	var link_path: String = ProjectSettings.globalize_path("user://test-vault-export/Linked")
	DirAccess.remove_absolute(link_path)   # unlink a link a crashed run left, before wiping the vault
	TestVault.remove_tree(outside)
	TestVault.remove_tree(dl)
	var vault: String = TestVault.open("export", false)
	await process_frame
	part1_export(vault, outside, dl)
	part2_windows_links(vault, dl)
	VaultStore.link_probe = null
	var clash: String = ProjectSettings.globalize_path("user://test-import-clash")
	var foreign: String = ProjectSettings.globalize_path("user://test-import-foreign")
	TestVault.remove_tree(clash)
	TestVault.remove_tree(foreign)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PWNED))
	part3_import(dl, clash, foreign)
	TestVault.remove_tree(clash)
	TestVault.remove_tree(foreign)
	part4_journey_merge(dl)
	part5_markdown_export(dl)
	part6_import_after_outside_delete(dl)
	DirAccess.remove_absolute(link_path)
	TestVault.remove_tree(outside)
	TestVault.remove_tree(dl)
	JourneyStore.invalidate()
	ProgressStore.invalidate()
	print("RESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(1 if fails else 0)


func part1_export(vault: String, outside: String, dl: String) -> void:
	# A vault with everything an export must carry, and some it must not
	var topic: Dictionary = JourneyStore.add_topic("Export Topic", "travels with the vault")
	JourneyStore.add_objective(topic.id, "Copy the journey")
	ProgressStore.record_result("Top Note", 0, 3, 3)
	var top: ContentLayer = VaultStore.create_note("Top Note")
	top.raw_text = "top"
	VaultStore.save_note(top)
	var sub: ContentLayer = VaultStore.create_note("Sub Note", "Sub")
	sub.raw_text = "in a folder"
	VaultStore.save_note(sub)
	var sub_file: String = sub.resource_path.get_file()
	write(vault.path_join(".ontomeme/ui.json"), "{\"sidebar\": 240}")
	write(vault.path_join("models/x.glb"), "glTF-bytes")
	write(vault.path_join(".trash/old.tres"), "deleted note")
	write(vault.path_join(".corrupted/bad.tres"), "quarantined")
	write(vault.path_join(".ontomeme/tmp/scratch.json"), "{}")
	write(vault.path_join("Sub/.DS_Store"), "finder")
	write(outside.path_join("secret.txt"), "not in the vault")
	var linked: Error = DirAccess.open(vault).create_link(outside, vault.path_join("Linked"))
	check(FileAccess.file_exists(vault.path_join(".ontomeme/journey.json")) and FileAccess.file_exists(vault.path_join(".ontomeme/progress.json")), "the test vault has a journey and progress in .ontomeme/")

	var r: Dictionary = VaultStore.export_to(dl)
	var dest: String = str(r.get("dest", ""))
	var name: String = "test-vault-export-export-" + Time.get_date_string_from_system()
	check(r.get("ok", false) and dest.simplify_path() == dl.path_join(name).simplify_path(), "export_to makes <vault>-export-<date> in the destination (%s)" % dest)
	var got: PackedStringArray = tree(dest)
	print("      exported: ", ", ".join(got))
	check(int(r.get("files", -1)) == got.size(), "export_to reports how many files it copied (%s of %d)" % [r.get("files"), got.size()])
	check(FileAccess.get_sha256(dest.path_join(".ontomeme/journey.json")) == FileAccess.get_sha256(vault.path_join(".ontomeme/journey.json")), ".ontomeme/journey.json is byte-identical")
	check(FileAccess.get_file_as_string(dest.path_join(".ontomeme/journey.json")).contains("Export Topic"), "the exported journey has the topic")
	check(FileAccess.file_exists(dest.path_join(".ontomeme/progress.json")) and FileAccess.get_file_as_string(dest.path_join(".ontomeme/progress.json")).contains("top note#0"), ".ontomeme/progress.json is exported with its entry")
	check(FileAccess.file_exists(dest.path_join(".ontomeme/ui.json")), ".ontomeme/ui.json is exported")
	check(FileAccess.file_exists(dest.path_join("Sub").path_join(sub_file)) and FileAccess.file_exists(dest.path_join(top.resource_path.get_file())), "notes at the top and in Sub/ are exported")
	check(FileAccess.get_file_as_string(dest.path_join("models/x.glb")) == "glTF-bytes", "models/x.glb is exported")
	check(not DirAccess.dir_exists_absolute(dest.path_join(".trash")), "no .trash in the export")
	check(not DirAccess.dir_exists_absolute(dest.path_join(".corrupted")), "no .corrupted in the export")
	check(not DirAccess.dir_exists_absolute(dest.path_join(".ontomeme/tmp")), "no .ontomeme/tmp in the export")
	check(not FileAccess.file_exists(dest.path_join("Sub/.DS_Store")), "no .DS_Store in the export")
	if linked == OK:
		check(not DirAccess.dir_exists_absolute(dest.path_join("Linked")) and not FileAccess.file_exists(dest.path_join("Linked/secret.txt")), "a symlinked folder is skipped")
		check(r.get("links", []) == ["Linked"], "export_to names the symlinked folder it left out (%s)" % [r.get("links")])
	else:
		print("SKIP  symlinked folder (create_link failed: %d)" % linked)

	# Same day, again: a second folder, and the first is left as it was
	var first_before: PackedStringArray = tree(dest)
	var first_sums: Dictionary = {}
	for f in first_before:
		first_sums[f] = FileAccess.get_sha256(dest.path_join(f))
	write(dest.path_join("my edit.txt"), "the user changed the first export")
	top.raw_text = "top, edited after the first export"
	VaultStore.save_note(top)
	var r2: Dictionary = VaultStore.export_to(dl)
	var dest2: String = str(r2.get("dest", ""))
	check(r2.get("ok", false) and dest2.simplify_path() == dl.path_join(name + " 2").simplify_path(), "a second export the same day goes to '<name> 2' (%s)" % dest2)
	var unchanged: bool = FileAccess.get_file_as_string(dest.path_join("my edit.txt")) == "the user changed the first export"
	for f in first_sums:
		unchanged = unchanged and FileAccess.get_sha256(dest.path_join(f)) == first_sums[f]
	check(unchanged and tree(dest).size() == first_before.size() + 1, "the first export's files are unchanged")
	check(FileAccess.get_file_as_string(dest2.path_join(top.resource_path.get_file())).contains("edited after"), "the second export has the newer note")
	var r3: Dictionary = VaultStore.export_to(dl)
	check(r3.get("ok", false) and str(r3.get("dest")).simplify_path() == dl.path_join(name + " 3").simplify_path(), "a third goes to '<name> 3'")

	# Never into itself: a destination inside the vault is refused
	var before: PackedStringArray = tree(vault)
	var inside: Dictionary = VaultStore.export_to(vault.path_join("Exports"))
	check(not inside.get("ok", true) and str(inside.get("error", "")) != "", "a destination inside the vault is refused (%s)" % inside.get("error", ""))
	check(not DirAccess.dir_exists_absolute(vault.path_join("Exports")) and tree(vault) == before, "a refused export creates nothing")
	var self_r: Dictionary = VaultStore.export_to(vault)
	check(not self_r.get("ok", true), "the vault folder itself is refused as a destination")


func part2_windows_links(vault: String, dl: String) -> void:
	# What read_link gives on Windows (final path, "\\?\" and backslashes on
	# its error path, UNC\server for a share) against the folder's own path
	var od: String = "C:/Users/Ann/OneDrive/Documents/Ontomeme"
	var own: Array[String] = [od + "/.ontomeme"]
	check(not VaultStore._resolves_elsewhere(od + "/.ontomeme", own), "a OneDrive placeholder resolves to itself: not a link")
	check(not VaultStore._resolves_elsewhere("\\\\?\\C:\\Users\\ann\\OneDrive\\Documents\\Ontomeme\\.ontomeme\\", own), "the same path with \\\\?\\, backslashes, other case and a trailing slash: not a link")
	own = ["//nas/home/Ontomeme/Sub"]
	check(not VaultStore._resolves_elsewhere("UNC/nas/home/Ontomeme/Sub", own), "a placeholder on a share (UNC/nas/...) resolves to itself: not a link")
	own = [od + "/Notes"]
	check(VaultStore._resolves_elsewhere("D:/Elsewhere/Notes", own), "a junction to another folder is a link")
	check(VaultStore._resolves_elsewhere(od, own), "a junction back to the vault itself is a link")
	own = ["C:/Users/Ann/Documents/Ontomeme/.ontomeme", "D:/Docs/Ontomeme/.ontomeme"]
	check(not VaultStore._resolves_elsewhere("D:/Docs/Ontomeme/.ontomeme", own), "Documents behind a junction: a folder under the resolved vault is not a link")
	own = ["/home/ann/vault/Linked"]
	check(VaultStore._resolves_elsewhere("/home/ann/outside", own) and VaultStore._resolves_elsewhere("../outside", own) and VaultStore._resolves_elsewhere("", own), "a symlink (absolute, relative or unreadable target) is a link")
	check(VaultStore._resolves_elsewhere("/home/ann/vault/linked", own), "POSIX paths keep their case")

	# The whole export through Windows' eyes: every folder is a reparse point
	var normal: Dictionary = VaultStore.export_to(dl)
	VaultStore.link_probe = WindowsProbe.new(vault)
	var r: Dictionary = VaultStore.export_to(dl)
	var dest: String = str(r.get("dest", ""))
	check(r.get("ok", false) and int(r.get("files", -1)) == int(normal.get("files", -2)) and int(r.get("files", 0)) > 0, "with every folder a placeholder, the export copies as many files (%s of %s)" % [r.get("files"), normal.get("files")])
	check(FileAccess.get_sha256(dest.path_join(".ontomeme/journey.json")) == FileAccess.get_sha256(vault.path_join(".ontomeme/journey.json")) and FileAccess.file_exists(dest.path_join(".ontomeme/progress.json")), "placeholder .ontomeme/: the journey and progress are exported")
	check(FileAccess.file_exists(dest.path_join("models/x.glb")) and DirAccess.get_files_at(dest.path_join("Sub")).size() > 0, "placeholder models/ and Sub/ are exported")
	var linked: bool = DirAccess.open(vault).is_link("Linked")
	if linked:
		check(not DirAccess.dir_exists_absolute(dest.path_join("Linked")) and r.get("links", []) == ["Linked"], "the real symlink is still left out and named (%s)" % [r.get("links")])
	else:
		check(r.get("links", ["?"]).is_empty(), "no folder is named as a link")

	# The vault reached through a junction (Documents moved to D:)
	VaultStore.link_probe = WindowsProbe.new(vault, "D:/Docs/Ontomeme")
	var j: Dictionary = VaultStore.export_to(dl)
	var jdest: String = str(j.get("dest", ""))
	check(j.get("ok", false) and int(j.get("files", -1)) == int(normal.get("files", -2)) and FileAccess.file_exists(jdest.path_join(".ontomeme/journey.json")), "through a junctioned Documents, every placeholder folder is exported (%s files)" % [j.get("files")])
	check(j.get("links", []) == (["Linked"] if linked else []), "and only the real symlink is left out (%s)" % [j.get("links")])
	VaultStore.link_probe = null


func part3_import(dl: String, clash: String, foreign: String) -> void:
	# A seeded vault with notes in nested folders, an empty folder, models
	# (a glTF in its own folder) and an image, exported
	var src_vault: String = TestVault.open("import-src")
	var waves: ContentLayer = VaultStore.create_note("Waves", "Physics/Sound")
	waves.raw_text = "a wave"
	waves.tags.assign(["physics"])
	waves.modified = "2026-02-03T04:05:06"
	VaultStore.save_note(waves, false)
	DirAccess.make_dir_recursive_absolute(src_vault.path_join("Empty/Deeper"))
	write(src_vault.path_join("models/x.glb"), "glb-bytes")
	write(src_vault.path_join("models/robot/robot.gltf"), "{}")
	write(src_vault.path_join("models/robot/robot.bin"), "BIN")
	write(src_vault.path_join("images/pic.png"), "PNG")
	VaultStore.refresh_note_list()
	var count: int = VaultStore.note_list.size()
	var folders: Array[String] = VaultStore.folders.duplicate()
	var note_folders: Array = folders.filter(func(f: String) -> bool: return f.get_slice("/", 0) not in VaultStore.ASSET_DIRS)
	var model_files: int = tree(src_vault.path_join("models")).size()
	var exported: Dictionary = VaultStore.export_to(dl)
	check(exported.ok and count > 10, "the seeded source vault is exported (%d notes)" % count)

	# Into an empty vault: everything arrives, in its folder
	var dst: String = TestVault.open("import-dst", false)
	var r: Dictionary = VaultStore.import_vault(str(exported.dest))
	print("      ", shown(r))
	check(r.ok and r.notes == count and VaultStore.note_list.size() == count, "every note is imported (%d of %d, %d in the vault)" % [r.notes, count, VaultStore.note_list.size()])
	check(VaultStore.folders == folders, "the vault has the source's folders, empty ones too (%s)" % [VaultStore.folders])
	check(r.folders == note_folders.size(), "import_vault counts the folders it made (%d)" % r.folders)
	var w: ContentLayer = note_titled("Waves")
	check(w != null and VaultStore.folder_of(w) == "Physics/Sound" and w.raw_text == "a wave" and Array(w.tags) == ["physics"] and w.modified == "2026-02-03T04:05:06", "a note keeps its folder, text, tags and dates")
	check(FileAccess.get_file_as_string(dst.path_join("models/x.glb")) == "glb-bytes" and FileAccess.get_file_as_string(dst.path_join("models/robot/robot.bin")) == "BIN" and FileAccess.file_exists(dst.path_join("models/robot/robot.gltf")), "models/ arrives, a glTF's folder too")
	check(FileAccess.get_file_as_string(dst.path_join("images/pic.png")) == "PNG" and r.images == 1, "images/ arrives")
	check(r.models == model_files and r.renamed == 0 and r.same == 0 and r.invalid == 0 and r.failed == 0, "nothing renamed, skipped or refused")

	# The same export again adds nothing
	var again: Dictionary = VaultStore.import_vault(str(exported.dest))
	check(again.ok and again.notes == 0 and again.same == count and VaultStore.note_list.size() == count, "importing it again adds no note: %d already here" % again.same)
	check(again.models == 0 and again.model_conflicts == 0 and again.image_conflicts == 0, "the same models and images are no conflict")

	# Imported notes carry their hashes: an edit saves in place
	w.raw_text = "edited here"
	VaultStore.save_note(w)
	check(VaultStore.last_conflict_copy == null and FileAccess.get_file_as_string(w.resource_path).contains("edited here"), "editing an imported note saves it, no conflict copy")

	# A folder that clashes: a taken title, a model by a taken name, Markdown
	write_note(clash.path_join("Physics/Sound/waves.tres"), "WAVES", "another wave")
	write_note(clash.path_join("code.tres"), "Code Sample", "[ext_resource type=\"Script\" path=\"res://x.gd\" id=\"9\"]\n[sub_resource type=\"GDScript\" id=\"1\"]\nObject(Node) ; it's only text")
	write(clash.path_join("garbage.tres"), "this is not a resource at all")
	write(clash.path_join("Course/a.md"), "---\ntags: x\ntopic: T\nobjective: O | learning\n---\n# A\n\nFirst lesson.\n")
	write(clash.path_join("Course/_draft.md"), "not yet")
	write(clash.path_join("models/x.glb"), "other glb bytes")
	write(clash.path_join("models/new.glb"), "new")
	var c: Dictionary = VaultStore.import_vault(clash)
	print("      ", shown(c))
	var copy: ContentLayer = note_titled("WAVES (2)")
	check(copy != null and copy.raw_text == "another wave" and VaultStore.folder_of(copy) == "Physics/Sound", "a title already taken (without case) imports as '<title> (2)', in its folder")
	check(c.renamed == 1 and note_titled("Waves").raw_text == "edited here", "the summary has renamed == 1, and the note there is unchanged")
	var code: ContentLayer = note_titled("Code Sample")
	check(code != null and code.raw_text.contains("[sub_resource"), "a note whose text mentions [sub_resource] or Object( is still a note")
	check(c.invalid == 1 and c.notes == 2, "a garbage .tres counts as invalid == 1 (%d), the notes import (%d)" % [c.invalid, c.notes])
	var a: ContentLayer = note_titled("a")
	check(c.md == 1 and a != null and Array(a.tags) == ["x"] and VaultStore.folder_of(a) == "Course", "a.md imports as a note tagged x in Course/ (md = %d)" % c.md)
	var o: Dictionary = JourneyStore.find_objective_by_name("O")
	check(not o.is_empty() and str(JourneyStore.topic_of(o.id).get("name", "")) == "T", "a.md's front matter creates objective O under topic T")
	check(note_titled("_draft") == null and note_titled("draft") == null, "a _draft.md is skipped")
	check(c.model_conflicts == 1 and c.models == 1 and FileAccess.get_file_as_string(dst.path_join("models/x.glb")) == "glb-bytes" and FileAccess.get_file_as_string(dst.path_join("models/new.glb")) == "new", "a model by a taken name is left out and counted; a new one is copied")
	var summary: String = load("res://note.gd").import_summary(c)
	check(summary.contains("Imported 3 notes (1 from Markdown)") and summary.contains("1 renamed") and summary.contains("1 file that isn't a note"), "the status line sums it up (%s)" % summary)

	# Files that would run code, or aren't notes, are never loaded
	write(foreign.path_join("evil.tres"), "[gd_resource type=\"Resource\" format=3]\n\n[sub_resource type=\"GDScript\" id=\"1\"]\nscript/source = \"extends Resource\nfunc _init():\n\tFileAccess.open(\\\"%s\\\", FileAccess.WRITE).store_string(\\\"ran\\\")\n\"\n\n[resource]\nscript = SubResource(\"1\")\ntitle = \"Evil\"\n" % PWNED)
	write(foreign.path_join("other_script.tres"), "[gd_resource type=\"Resource\" script_class=\"ContentLayer\" format=3]\n\n[ext_resource type=\"Script\" path=\"res://tests/pwn.gd\" id=\"1\"]\n\n[resource]\nscript = ExtResource(\"1\")\ntitle = \"Other\"\n")
	write(foreign.path_join("same_line.tres"), "[gd_resource type=\"Resource\" script_class=\"ContentLayer\" format=3]\n\n[ext_resource type=\"Script\" path=\"res://ContentLayer.gd\" id=\"1\"]\n\n[resource]\nscript = ExtResource(\"1\") [ext_resource type=\"Script\" path=\"res://tests/pwn.gd\" id=\"2\"]\ntitle = \"Sneaky\"\n")
	write(foreign.path_join("material.tres"), "[gd_resource type=\"StandardMaterial3D\" format=3]\n\n[resource]\nalbedo_color = Color(1, 0, 0, 1)\n")
	write_note(foreign.path_join("redirected.tres"), "Redirected", "x")
	write(foreign.path_join("redirected.tres.remap"), "[remap]\npath=\"res://tests/pwn.gd\"\n")
	var before: int = VaultStore.note_list.size()
	var f: Dictionary = VaultStore.import_vault(foreign)
	check(f.invalid == 5 and f.notes == 0 and VaultStore.note_list.size() == before, "a GDScript sub-resource, another script, a second [ext_resource] on a line, a material and a .remap are refused (%d of 5)" % f.invalid)
	check(not FileAccess.file_exists(PWNED), "no code from an imported file ran")

	# The same in the root images/ and models/, whose pictures and models are
	# copied byte for byte: only those file types, never a .tres or an
	# .import. Where the vault reads notes (images/ while it isn't in
	# ASSET_DIRS), a note there imports like any other: checked, and renamed
	# when its title is taken.
	var shared: String = foreign.path_join("Shared")
	var evil: String = FileAccess.get_file_as_string(foreign.path_join("evil.tres"))
	write(shared.path_join("images/evil.tres"), evil)
	write(shared.path_join("models/evil.tres"), evil)
	write(shared.path_join("models/robot/evil.tres"), evil)
	write(shared.path_join("models/robot/tex.png.import"), "[remap]\npath=\"res://tests/pwn.gd\"\n")
	write_note(shared.path_join("images/note_code_sample.tres"), "Code Sample", "a different sample")
	write(shared.path_join("images/pic2.png"), "PNG2")
	write(shared.path_join("models/robot/tex.png"), "TEX")
	var s: Dictionary = VaultStore.import_vault(shared)
	print("      ", shown(s))
	check(not FileAccess.file_exists(PWNED), "no code ran from a .tres in images/ or models/")
	var copied: Array = ["images/evil.tres", "models/evil.tres", "models/robot/evil.tres", "models/robot/tex.png.import"].filter(func(p: String) -> bool: return FileAccess.file_exists(dst.path_join(p)))
	check(copied.is_empty(), "none of them, nor an .import file, is copied into the vault (%s)" % [copied])
	check(s.images == 1 and s.models == 1 and FileAccess.get_file_as_string(dst.path_join("images/pic2.png")) == "PNG2" and FileAccess.get_file_as_string(dst.path_join("models/robot/tex.png")) == "TEX", "the picture and the model's texture are copied, and only they count (%d images, %d models)" % [s.images, s.models])
	var sample: ContentLayer = note_titled("Code Sample (2)")
	var samples: int = VaultStore.note_list.filter(func(n: ContentLayer) -> bool: return n.title.strip_edges().to_lower() == "code sample").size()
	if "images" not in VaultStore.ASSET_DIRS:
		check(sample != null and sample.raw_text == "a different sample" and VaultStore.folder_of(sample) == "images" and samples == 1 and s.renamed == 1 and s.notes == 1, "a note in images/ (a notes folder) imports as 'Code Sample (2)', never a second 'Code Sample' (%d)" % samples)
		check(s.invalid == 3, "the three .tres that aren't notes count as invalid (%d)" % s.invalid)
	else:
		check(sample == null and samples == 1 and s.notes == 0 and s.invalid == 4, "no note comes in from images/, an asset folder; its .tres count as invalid (%d)" % s.invalid)

	# Inside the vault, or holding it: refused
	var inside: Dictionary = VaultStore.import_vault(dst.path_join("Physics"))
	var holding: Dictionary = VaultStore.import_vault(dst.get_base_dir().get_base_dir())
	check(not inside.ok and not holding.ok and inside.notes == 0 and holding.notes == 0, "a folder in the vault, or one holding it, is refused (%s; %s)" % [inside.errors, holding.errors])


func objective_named(topic: Dictionary, name: String) -> Dictionary:
	for o in topic.get("objectives", []):
		if o.name == name:
			return o
	return {}


func topics_named(name: String) -> Array:
	return JourneyStore.topics().filter(func(t: Dictionary) -> bool: return str(t.name).to_lower() == name.to_lower())


func part4_journey_merge(dl: String) -> void:
	# The source: topic T, objective O shown by Quiz Note's quiz, 2 scores
	TestVault.open("journey-src", false)
	var quiz: ContentLayer = VaultStore.create_note("Quiz Note")
	quiz.raw_text = "```3d\npreset: quiz\nquestion: 1 + 1?\nanswers: 2*, 3\n```\n"
	VaultStore.save_note(quiz)
	var key: String = JourneyStore.activity_key("Quiz Note", "quiz", 0)
	var t: Dictionary = JourneyStore.add_topic("T", "from the source")
	var o: Dictionary = JourneyStore.add_objective(t.id, "O", "the source's objective", "fluent")
	JourneyStore.add_demo(o.id, key)
	JourneyStore.log_score(key, 2, 3)
	JourneyStore.log_score(key, 3, 3)
	JourneyStore.add_objective(JourneyStore.add_topic("Second").id, "S")
	var exported: Dictionary = VaultStore.export_to(dl)

	# This vault: its own Quiz Note, topic T with objective P on that quiz
	TestVault.open("journey-dst", false)
	var mine: ContentLayer = VaultStore.create_note("Quiz Note")
	mine.raw_text = "my own quiz note"
	VaultStore.save_note(mine)
	var dt: Dictionary = JourneyStore.add_topic("T")
	var p: Dictionary = JourneyStore.add_objective(dt.id, "P")
	JourneyStore.add_demo(p.id, key)
	JourneyStore.add_topic("second")
	var r: Dictionary = VaultStore.import_vault(str(exported.dest))
	print("      journey: ", r.journey, "  renames: ", r.renames)
	check(r.ok and r.journey == {"topics": 0, "objectives": 2, "demos": 1, "logs": 2}, "the merge adds objectives O and S, O's demo and its 2 scores, no topic (%s)" % [r.journey])
	check(topics_named("T").size() == 1 and topics_named("Second").size() == 1, "no duplicate topics (T, and Second matched to 'second' without case)")
	var topic: Dictionary = topics_named("T")[0]
	var names: Array = topic.objectives.map(func(x: Dictionary) -> String: return x.name)
	names.sort()
	check(names == ["O", "P"], "T has objectives O and P (%s)" % [names])
	var got: Dictionary = objective_named(topic, "O")
	check(got.get("goal") == "fluent" and got.get("description") == "the source's objective" and got.get("id") != o.id, "O keeps its goal and description, under a new id")
	check(got.get("log", []).size() == 2, "O has its 2 scores (%d)" % got.get("log", []).size())
	var renamed_key: String = JourneyStore.activity_key("Quiz Note (2)", "quiz", 0)
	check(note_titled("Quiz Note (2)") != null and r.renames.get("Quiz Note") == "Quiz Note (2)", "the source's Quiz Note was imported as 'Quiz Note (2)'")
	check(got.get("demos", []).size() == 1 and got.demos[0].activity == renamed_key and got.log.all(func(e: Dictionary) -> bool: return e.activity == renamed_key), "O's demo and scores follow it to %s" % renamed_key)
	check(objective_named(topic, "P").demos[0].activity == key, "P still points at this vault's own Quiz Note")
	JourneyStore.invalidate()
	check(objective_named(topics_named("T")[0], "O").get("log", []).size() == 2 and JourneyStore.load_error() == "", "the merged journey is saved and reads back")

	# The same export again: nothing new
	var again: Dictionary = VaultStore.import_vault(str(exported.dest))
	var o2: Dictionary = objective_named(topics_named("T")[0], "O")
	check(again.ok and again.journey == {"topics": 0, "objectives": 0, "demos": 0, "logs": 0} and o2.log.size() == 2 and o2.demos.size() == 1, "importing it twice adds no duplicate logs or demos (%s)" % [again.journey])
	check(topics_named("T")[0].objectives.size() == 2 and note_titled("Quiz Note (3)") == null, "and no objective or note copy")

	# A journey file that can't be read: the notes still come in, it says so
	var broken: String = str(exported.dest).path_join(".ontomeme/journey.json")
	write(broken, "{ not json")
	write_note(str(exported.dest).path_join("late.tres"), "Late Note", "after")
	var b: Dictionary = VaultStore.import_vault(str(exported.dest))
	check(not b.ok and b.notes == 1 and str(b.errors).contains("Learning Journey"), "an unreadable journey is reported and the notes still import (%s)" % [b.errors])
	var beside: PackedStringArray = DirAccess.get_files_at(broken.get_base_dir())
	check(FileAccess.get_file_as_string(broken) == "{ not json" and not ",".join(beside).contains("unreadable"), "the source's journey file is left as it was, with no copy beside it (%s)" % [beside])


func part5_markdown_export(dl: String) -> void:
	var a: String = TestVault.open("import-mdexport-a", false)
	var alpha: ContentLayer = VaultStore.create_note("Alpha")
	alpha.raw_text = "see [[Beta]]"
	VaultStore.save_note(alpha)
	VaultStore.create_note("Beta")
	var md: Dictionary = MdExport.export_vault()
	var marked: String = a.path_join("exports").path_join(MdExport.MARKER)
	check(md.written == 2 and FileAccess.file_exists(marked), "(the vault's Markdown export wrote 2 files into its marked exports/: %s)" % [md])
	var exported: Dictionary = VaultStore.export_to(dl)
	check(exported.ok and FileAccess.file_exists(str(exported.dest).path_join("exports").path_join(MdExport.MARKER)),
		"(the vault export carries exports/ and its marker)")

	# Into a fresh vault: each note once, nothing from the Markdown copies
	var b: String = TestVault.open("import-mdexport-b", false)
	var r: Dictionary = VaultStore.import_vault(str(exported.dest))
	print("      ", shown(r))
	var titles: Array = VaultStore.note_list.map(func(n: ContentLayer) -> String: return n.title)
	titles.sort()
	check(r.ok and r.notes == 2 and r.md == 0 and r.renamed == 0 and titles == ["Alpha", "Beta"],
		"an export with a Markdown export in it imports each note once, none again from the .md copies (%s)" % [titles])
	check(not DirAccess.dir_exists_absolute(b.path_join("exports")) and r.folders == 0, "…and makes no exports folder in the vault")
	var b_md: Dictionary = MdExport.export_vault()
	check(b_md.written == 2 and b_md.failed.is_empty(), "…so the new vault's own Markdown export works (%s)" % MdExport.last_error)

	# Back into the vault it came from: nothing new, nothing hidden in exports/
	VaultStore.open_vault(a, false)
	var back: Dictionary = VaultStore.import_vault(str(exported.dest))
	print("      ", shown(back))
	var hidden: Array = Array(tree(a.path_join("exports"))).filter(func(p: String) -> bool: return p.ends_with(".tres"))
	check(back.ok and back.notes == 0 and back.md == 0 and back.same == 2 and back.imported.is_empty() and VaultStore.note_list.size() == 2,
		"imported into its own vault, the export adds nothing (%d notes)" % VaultStore.note_list.size())
	check(hidden.is_empty(), "…and writes no note into the marked export folder, where the note list would never show it (%s)" % [hidden])
	TestVault.remove_tree(a)
	TestVault.remove_tree(b)


func part6_import_after_outside_delete(dl: String) -> void:
	var v: String = TestVault.open("import-stale", false)
	var alpha: ContentLayer = VaultStore.create_note("Alpha")
	alpha.raw_text = "alpha words"
	VaultStore.save_note(alpha)
	var backup: String = dl.path_join("stale-backup")
	DirAccess.make_dir_recursive_absolute(backup)
	DirAccess.copy_absolute(alpha.resource_path, backup.path_join("note_alpha.tres"))
	var tools: RefCounted = VaultTools.new(v)
	var read: Dictionary = tools.call_tool("read_note", {"path": "note_alpha.tres"})
	var del: Dictionary = tools.call_tool("delete_note", {"path": "note_alpha.tres", "hash": read.structuredContent.hash})
	VaultStore.refresh_note_list(true)   # the watcher's rescan
	check(not del.get("isError", false) and VaultStore.note_list.is_empty(), "(Claude deleted Alpha: the vault lists no note)")
	var r: Dictionary = VaultStore.import_vault(backup)
	print("      ", shown(r))
	var back: ContentLayer = note_titled("Alpha")
	check(r.ok and r.notes == 1 and r.failed == 0 and back != null and back.resource_path == v + "note_alpha.tres" and back.raw_text == "alpha words",
		"a backup of a note deleted outside imports as itself, at its file name (%s)" % [shown(r).imported])
	check(VaultStore.note_list.size() == 1 and note_titled("Alpha (conflict copy)") == null, "…not as a conflict copy of the deleted file")
	if back != null:
		back.raw_text = "edited after the import"
		check(VaultStore.save_note(back) == OK and VaultStore.last_conflict_copy == null
			and FileAccess.get_file_as_string(back.resource_path).contains("edited after the import"), "…and its next edit saves in place")
	TestVault.remove_tree(v)
