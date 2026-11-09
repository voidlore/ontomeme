extends SceneTree
## ImageEmbeds: parse a standalone `![alt](target)` line, list the refs in a
## note outside its fences, tell whether a note names a file anywhere (the
## check before Remove from note trashes it), resolve a target inside the
## vault, and load the file as a cached texture. Pure module, no scene; fixture files live in a
## throwaway vault.
##   headless:  godot --headless --path . -s res://tests/image_embeds_test.gd

const TestVault = preload("res://tests/test_vault.gd")

var fails: int = 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


## A 40x20 (or w x h) image, a different colour per format so a mix-up shows.
func make_image(w: int, h: int, colour: Color) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(colour)
	return img


func write_bytes(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func size_of(tex: Texture2D) -> Vector2:
	return tex.get_size() if tex != null else Vector2(-1, -1)


func _init() -> void:
	JourneyStore.file_override = "user://test_journey_image_embeds.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_image_embeds.json"   # never touch real progress
	ProgressStore.reset()
	var V: String = TestVault.open("image_embeds", false)

	check_parse_line()
	check_ref_line()
	check_refs_in()
	check_resolve(V)
	check_refers_to(V)
	await check_load_texture(V)

	print("\nRESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(0 if fails == 0 else 1)


func check_parse_line() -> void:
	# [line, expected {alt, target, title} or {} for "not an image line"]
	var cases: Array = [
		["![a red square](images/red.png)", {"alt": "a red square", "target": "images/red.png", "title": ""}],
		["   ![a red square](images/red.png)  ", {"alt": "a red square", "target": "images/red.png", "title": ""}],
		["![chart](images/chart.png \"Sales by month\")", {"alt": "chart", "target": "images/chart.png", "title": "Sales by month"}],
		["![](images/bare.png)", {"alt": "", "target": "images/bare.png", "title": ""}],
		["![x](red.png)", {"alt": "x", "target": "red.png", "title": ""}],
		["![x](images/my%20pic.png)", {"alt": "x", "target": "images/my pic.png", "title": ""}],
		["![x](<images/my pic.png>)", {"alt": "x", "target": "images/my pic.png", "title": ""}],
		["![x](images/photo(1).png)", {"alt": "x", "target": "images/photo(1).png", "title": ""}],
		# '+' is a literal character in a path, not a form-encoded space
		["![x](images/c++.png)", {"alt": "x", "target": "images/c++.png", "title": ""}],
		["![a](a+b.png)", {"alt": "a", "target": "a+b.png", "title": ""}],
		["![a](<a+b.png>)", {"alt": "a", "target": "a+b.png", "title": ""}],
		["![a](images/1%2B1.png)", {"alt": "a", "target": "images/1+1.png", "title": ""}],
		["![a](images/a+b%20c.png)", {"alt": "a", "target": "images/a+b c.png", "title": ""}],
		["See ![x](images/x.png) here", {}],
		["![x](images/x.png) and more", {}],
		["![a](images/a.png) ![b](images/b.png)", {}],
		["[img=x]<data:image/png;base64,iVBORw0KGgo=>", {}],
		["[x](images/x.png)", {}],
		["![x](images/x.png", {}],
		["![x]()", {}],
		["", {}],
	]
	for c in cases:
		var got: Dictionary = ImageEmbeds.parse_line(c[0])
		check(got == c[1], "parse_line %s -> %s (got %s)" % [JSON.stringify(c[0]), c[1], got])


## ref_line writes what parse_line reads back, whatever the file is called.
func check_ref_line() -> void:
	# [alt, target, expected line]
	var cases: Array = [
		["Red", "images/red.png", "![Red](images/red.png)"],
		["My Photo", "images/my photo.png", "![My Photo](<images/my photo.png>)"],
		["Photo", "images/photo(1).png", "![Photo](images/photo(1).png)"],
		["Odd", "images/a)b.png", "![Odd](<images/a)b.png>)"],
		["Full", "images/100%.png", "![Full](images/100%25.png)"],
		["Lit", "images/a%20b.png", "![Lit](images/a%2520b.png)"],
		["Angles", "images/x<y>.png", "![Angles](images/x%3Cy%3E.png)"],
		["C", "images/c++.png", "![C](images/c++.png)"],
		["[Boxed] alt\nsplit", "images/über.png", "![Boxed alt split](images/über.png)"],
	]
	for c in cases:
		var line: String = ImageEmbeds.ref_line(c[0], c[1])
		var back: Dictionary = ImageEmbeds.parse_line(line)
		check(line == c[2], "ref_line(%s, %s) -> %s (got %s)" % [JSON.stringify(c[0]), JSON.stringify(c[1]), c[2], line])
		check(back.get("target") == c[1], "parse_line reads %s back as %s (got %s)" % [line, JSON.stringify(c[1]), back])


func check_refs_in() -> void:
	var text: String = "\n".join([
		"# Images",                              # 0
		"![one](images/1.png)",                  # 1
		"```",                                   # 2
		"![fenced](images/f.png)",               # 3
		"```",                                   # 4
		"````md",                                # 5
		"```",                                   # 6  a shorter fence does not close ````
		"![quad](images/q.png)",                 # 7
		"```",                                   # 8
		"````",                                  # 9
		"text ![mid](images/m.png) text",        # 10
		"  ![two](2.png \"t\")",                 # 11
		"```",                                   # 12 never closed: the rest is code
		"![open](images/o.png)",                 # 13
	])
	var refs: Array[Dictionary] = ImageEmbeds.refs_in(text)
	var seen: Array = refs.map(func(r: Dictionary) -> Array: return [r.get("line"), r.get("alt"), r.get("target")])
	check(seen == [[1, "one", "images/1.png"], [11, "two", "2.png"]],
		"refs_in lists standalone refs with their line, skipping ``` and ```` fences and mid-sentence refs (%s)" % [seen])
	check(refs.size() == 2 and refs[1].get("title") == "t", "refs_in keeps the title (%s)" % [refs])
	check(ImageEmbeds.refs_in("").is_empty(), "refs_in on an empty note is empty")


func check_resolve(V: String) -> void:
	var inside := func(rel: String) -> String: return V.path_join(rel).simplify_path()
	# [target, expected absolute path, or "" when it must not load]
	var cases: Array = [
		["x.png", inside.call("images/x.png")],
		["images/x.png", inside.call("images/x.png")],
		["Folder/x.png", inside.call("Folder/x.png")],
		["images/sub/../x.jpg", inside.call("images/x.jpg")],
		["./images/x.webp", inside.call("images/x.webp")],
		["X.JPEG", inside.call("images/X.JPEG")],
		["../x.png", ""],
		["images/../../x.png", ""],
		["/etc/a.png", ""],
		["~/a.png", ""],
		["https://a/b.png", ""],
		["http://a/b.png", ""],
		["file:///tmp/a.png", ""],
		["data:image/png;base64,iVBORw0KGgo=", ""],
		["C:/pics/a.png", ""],
		["x.gif", ""],
		["x.svg", ""],
		["images/x", ""],
		["", ""],
	]
	for c in cases:
		var got: String = ImageEmbeds.resolve(c[0], V)
		check(got == c[1], "resolve %s -> %s (got %s)" % [JSON.stringify(c[0]), JSON.stringify(c[1]), JSON.stringify(got)])
	# is_remote tells a URL (the Read view's "Web images" line) from a path
	for c in [["https://a/b.png", true], ["data:image/png;base64,AA", true], ["file:///a.png", true],
			["images/x.png", false], ["C:/pics/a.png", false], ["x.png", false]]:
		check(ImageEmbeds.is_remote(c[0]) == c[1], "is_remote %s -> %s" % [JSON.stringify(c[0]), c[1]])
	# The vault path may come with or without its trailing slash
	check(ImageEmbeds.resolve("x.png", V.trim_suffix("/")) == inside.call("images/x.png"),
		"resolve works with a vault path that has no trailing slash")


## refers_to answers "does this note still use the file?" before Remove from
## note trashes it, so it must see every way a note can name the file, not
## only a standalone image line: a list item's image once went uncounted and
## its file went to the trash.
func check_refers_to(V: String) -> void:
	var red: String = ImageEmbeds.resolve("images/red.png", V)
	var spaced: String = ImageEmbeds.resolve("images/my pic.png", V)
	# [note text, file, expected]
	var cases: Array = [
		["![Red](images/red.png)", red, true],
		["- ![Red in a list](images/red.png)", red, true],
		["1. ![x](<images/red.png>)", red, true],
		["> ![quoted](images/red.png \"title\")", red, true],
		["Text with ![red](images/red.png) inline.", red, true],
		["| ![r](red.png) | a bare name in a table |", red, true],
		["See [the picture](./images/red.png).", red, true],
		["![x](images/RED.PNG)", red, true],
		["![[red.png]]", red, true],
		["Inline ![[images/red.png|200]] wiki embed", red, true],
		["![pic][r]\n\n[r]: images/red.png", red, true],
		["[r]: <images/red.png> \"t\"", red, true],
		["<img src=\"images/red.png\" width=\"20\">", red, true],
		["```md\n![fenced](images/red.png)\n```", red, true],
		["- ![x](my%20pic.png)", spaced, true],
		["- ![x](<images/my pic.png>)", spaced, true],
		["- ![x](images/my pic.png)", spaced, true],
		["![[my pic.png]]", spaced, true],
		["![x](images/blue.png)", red, false],
		["The file images/red.png, named in prose", red, false],
		["![x](https://example.com/images/red.png)", red, false],
		["![x](images/red.png.bak)", red, false],
		["![x](other/red.png)", red, false],
		["![x](../images/red.png)", red, false],
		["", red, false],
		["![Red](images/red.png)", "", false],
	]
	for c in cases:
		var got: bool = ImageEmbeds.refers_to(c[0], c[1], V)
		check(got == c[2], "refers_to %s, %s -> %s" % [JSON.stringify(c[0]), str(c[1]).get_file(), c[2]])


func check_load_texture(V: String) -> void:
	var dir: String = V.path_join(ImageEmbeds.DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	make_image(40, 20, Color.RED).save_png(dir.path_join("red.png"))
	make_image(40, 20, Color.GREEN).save_jpg(dir.path_join("green.jpg"))
	make_image(40, 20, Color.BLUE).save_webp(dir.path_join("blue.webp"))
	for name in ["red.png", "green.jpg", "blue.webp"]:
		var tex: Texture2D = ImageEmbeds.load_texture(ImageEmbeds.resolve(name, V))
		check(size_of(tex) == Vector2(40, 20), "load_texture %s loads at 40x20 (%s)" % [name, size_of(tex)])

	# A JPEG saved under a .png name still loads: the bytes pick the decoder
	make_image(40, 20, Color.YELLOW).save_jpg(dir.path_join("renamed.png"))
	check(size_of(ImageEmbeds.load_texture(dir.path_join("renamed.png"))) == Vector2(40, 20),
		"a jpg named .png loads by its content")

	# A '+' in the file name survives parse -> resolve -> load (C++.png, a+b.png)
	make_image(40, 20, Color.ORANGE).save_png(dir.path_join("a+b.png"))
	for line in ["![a](images/a+b.png)", "![a](a+b.png)", "![a](<a+b.png>)"]:
		var ref: Dictionary = ImageEmbeds.parse_line(line)
		var plus_tex: Texture2D = ImageEmbeds.load_texture(ImageEmbeds.resolve(str(ref.get("target", "")), V))
		check(size_of(plus_tex) == Vector2(40, 20), "%s loads images/a+b.png (%s)" % [line, size_of(plus_tex)])

	check(ImageEmbeds.load_texture(dir.path_join("missing.png")) == null, "a missing file gives null")
	check(ImageEmbeds.load_texture("") == null, "an empty path (an unresolvable target) gives null")
	write_bytes(dir.path_join("junk.png"), "this is not an image".to_utf8_buffer())
	check(ImageEmbeds.load_texture(dir.path_join("junk.png")) == null, "a file of garbage bytes gives null")
	# A real PNG signature with nothing decodable after it (the engine's png
	# decoder logs "ERROR: … ERR_FILE_CORRUPT" here; that is the expected path)
	var truncated: PackedByteArray = FileAccess.get_file_as_bytes(dir.path_join("red.png")).slice(0, 24)
	write_bytes(dir.path_join("truncated.png"), truncated)
	# for tests/run_all.sh: the png decoder's lines on the truncated file
	print("EXPECT-ERROR: Condition \"!success\" is true. Returning: ERR_FILE_CORRUPT")
	print("EXPECT-ERROR: Condition \"err\" is true. Returning: Ref<Image>()")
	print("EXPECT-ERROR: Condition \"image.is_null()\" is true. Returning: ERR_PARSE_ERROR")
	check(ImageEmbeds.load_texture(dir.path_join("truncated.png")) == null, "a truncated png gives null")

	# Cache: the same object until the file changes on disk
	var path: String = dir.path_join("red.png")
	var first: Texture2D = ImageEmbeds.load_texture(path)
	check(first != null and ImageEmbeds.load_texture(path) == first, "a second load returns the cached texture")
	await create_timer(1.2).timeout   # mtime has 1 s resolution
	make_image(30, 10, Color.RED).save_png(path)
	var fresh: Texture2D = ImageEmbeds.load_texture(path)
	check(fresh != null and fresh != first and size_of(fresh) == Vector2(30, 10),
		"after the file is rewritten the new texture loads at its new size (%s)" % size_of(fresh))
	check(ImageEmbeds.load_texture(path) == fresh, "and is cached in turn")
	DirAccess.remove_absolute(path)
	check(ImageEmbeds.load_texture(path) == null, "a cached file deleted from disk gives null")
