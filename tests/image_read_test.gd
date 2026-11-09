extends SceneTree
## Images in Read view: a line that is exactly `![alt](target)` shows the file
## from <vault>/images/ as a TextureRect with its caption; a missing file or a
## web URL shows a muted line instead; a ref in a fence or mid-sentence stays
## text; a 4000-px-wide image shrinks to the column instead of widening it.
## Outline lists the refs under IMAGES (N) with thumbnails at most 64 px high.
## Resizing the window across the height where DocScroll's scrollbar appears
## settles, with no scrollbar on/off loop.
##   headless:  godot --headless --path . -s res://tests/image_read_test.gd
##   + images:  godot --path . -s res://tests/image_read_test.gd -- <out_dir>

const TestVault = preload("res://tests/test_vault.gd")

const NOTE_TEXT: String = """# Pictures
![a red square](images/red.png)

![](wide.png)
![gone](images/missing.png)
```
![fenced](images/red.png)
```
See ![mid](images/red.png) inline.
![web](https://example.com/a.png)
![anim](images/spin.gif)
![junk](images/junk.png)
The end."""

var fails: int = 0
var out: String = ""


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if not cond:
		fails += 1


func frames(n: int = 3) -> void:
	for i in range(n):
		await process_frame


func shot(name: String) -> void:
	if out == "" or DisplayServer.get_name() == "headless":
		return
	await create_timer(0.8).timeout
	get_root().get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("saved ", out.path_join(name + ".png"))


func save_image(path: String, w: int, h: int, colour: Color) -> void:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(colour)
	img.save_png(path)


## Every descendant of `root` that is an instance of `type` (a class name).
func find_all(root: Node, type: String) -> Array:
	var found: Array = []
	for c in root.get_children():
		if c.is_class(type):
			found.append(c)
		found.append_array(find_all(c, type))
	return found


func label_texts(root: Node) -> Array:
	var texts: Array = []
	for l in find_all(root, "Label") + find_all(root, "RichTextLabel"):
		texts.append(l.text)
	return texts


func muted_label(root: Node, text: String) -> Label:
	for l in find_all(root, "Label"):
		if (l as Label).text == text and (l as Label).theme_type_variation == &"MutedLabel":
			return l
	return null


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else ""
	if out != "":
		DisplayServer.window_set_size(Vector2i(1280, 820))
	JourneyStore.file_override = "user://test_journey_image_read.json"   # never touch the real journey
	JourneyStore.reset()
	ProgressStore.file_override = "user://test_progress_image_read.json"   # never touch real progress
	ProgressStore.reset()
	var V: String = TestVault.open("image_read", false)
	DirAccess.make_dir_recursive_absolute(V.path_join("images"))
	save_image(V.path_join("images/red.png"), 8, 8, Color.RED)
	save_image(V.path_join("images/wide.png"), 4000, 40, Color.STEEL_BLUE)
	save_image(V.path_join("images/tall.png"), 60, 2000, Color.SEA_GREEN)
	var junk := FileAccess.open(V.path_join("images/junk.png"), FileAccess.WRITE)
	junk.store_string("not an image")
	junk.close()
	var n: ContentLayer = VaultStore.create_note("Image Note")
	n.raw_text = NOTE_TEXT
	VaultStore.save_note(n)

	var app: Control = load("res://note.tscn").instantiate()
	get_root().add_child(app)
	await frames(4)
	app.open_note_by_title("Image Note")
	await frames(2)
	app._switch_layer("visual")
	await frames(4)

	await check_read_view(app, V)
	await shot("image_read")

	# Read -> Outline -> Read rebuilds cleanly (run_all.sh fails on any SCRIPT ERROR)
	app._switch_layer("structured")
	await frames(3)
	app._switch_layer("visual")
	await frames(3)
	check(find_all(LayerEngine._visual_vbox, "TextureRect").size() == 2,
		"Read -> Outline -> Read shows the same 2 images")

	# A tall image stops at LayerEngine.MAX_IMAGE_HEIGHT
	var tall: ContentLayer = VaultStore.create_note("Tall Image")
	tall.raw_text = "![tall](images/tall.png)"
	VaultStore.save_note(tall)
	app._refresh_note_list()
	app.open_note_by_title("Tall Image")
	await frames(4)
	var tall_rects: Array = find_all(LayerEngine._visual_vbox, "TextureRect")
	check(tall_rects.size() == 1 and is_equal_approx((tall_rects[0] as TextureRect).size.y, LayerEngine.MAX_IMAGE_HEIGHT),
		"a 60x2000 image is capped at %d px high (%s)" % [LayerEngine.MAX_IMAGE_HEIGHT, (tall_rects[0] as TextureRect).size if tall_rects.size() > 0 else "none"])

	await check_outline(app)
	await check_outside_vault(app, V)
	await check_resize_sweep(app, V)

	print("\nRESULT: %s (%d failures)" % ["ALL PASS" if fails == 0 else "FAILED", fails])
	quit(0 if fails == 0 else 1)


func check_read_view(app: Control, V: String) -> void:
	var vbox: VBoxContainer = LayerEngine._visual_vbox
	var rects: Array = find_all(vbox, "TextureRect")
	check(rects.size() == 2, "exactly 2 TextureRects in Read view (%d)" % rects.size())
	if rects.size() != 2:
		return
	var red: TextureRect = rects[0]
	var wide: TextureRect = rects[1]
	check(red.texture != null and red.texture.get_size() == Vector2(8, 8), "the first image is red.png at 8x8")
	check(wide.texture != null and wide.texture.get_size() == Vector2(4000, 40), "the second is wide.png at 4000x40 (a bare name resolves under images/)")
	check(red.get_parent().name.begins_with("ImageEmbed") and red.get_parent() is VBoxContainer, "each image sits in an ImageEmbed VBoxContainer")
	check(str(red.get_meta("image_path", "")) == ImageEmbeds.resolve("images/red.png", V), "image_path meta holds the absolute file path")
	check(red.tooltip_text == "images/red.png" and wide.tooltip_text == "wide.png", "the tooltip is the target as written")

	# Small images are not upscaled; wide ones shrink to the column
	check(is_equal_approx(red.size.y, 8.0), "the 8x8 image is 8 px high, not upscaled (%s)" % red.size)
	check(wide.size.y <= 40.0 and wide.size.x <= vbox.size.x + 0.5, "the 4000-px image shrinks into the column (%s in %s)" % [wide.size, vbox.size])
	var layout_min: Vector2 = app.get_node("AppLayout").get_combined_minimum_size()
	check(layout_min.x <= 820, "the layout still fits the 820-px window (%s)" % layout_min)
	check(not app.doc_scroll.get_h_scroll_bar().visible, "no horizontal scrollbar on DocScroll")

	# Caption under the captioned image only
	var red_caption: Array = find_all(red.get_parent(), "Label")
	check(red_caption.size() == 1 and (red_caption[0] as Label).text == "a red square"
		and (red_caption[0] as Label).theme_type_variation == &"MutedLabel", "the caption reads 'a red square'")
	check(find_all(wide.get_parent(), "Label").is_empty(), "an image with no alt has no caption")

	# Fallback lines
	check(muted_label(vbox, "Image not found: images/missing.png") != null, "a missing file shows 'Image not found: images/missing.png'")
	check(muted_label(vbox, "Web images are not loaded: https://example.com/a.png") != null, "a URL shows 'Web images are not loaded: …'")
	check(muted_label(vbox, "Not a supported image (png, jpg, webp): images/spin.gif") != null, "a .gif says it is not a supported image")
	check(muted_label(vbox, "Image could not be read: images/junk.png") != null, "a file that does not decode says it could not be read")

	# A fenced ref is code; a mid-sentence ref is text
	var codes: Array = find_all(vbox, "CodeEdit").filter(func(c) -> bool: return (c as CodeEdit).text.contains("![fenced](images/red.png)"))
	check(codes.size() == 1, "the ref inside ``` shows in the CodeEdit")
	check(label_texts(vbox).has("See ![mid](images/red.png) inline."), "the mid-sentence ref stays text")
	check(label_texts(vbox).has("The end."), "text after the images still renders")

	var plain: String = LayerEngine.get_rendered_content("visual")
	check(plain.contains("[image: a red square]"), "the visual text content writes [image: alt]")


## An image file that exists but sits outside the vault (an absolute path,
## or ../) is never loaded: Read view and Outline say so, as NoteLint does,
## instead of "Image not found".
func check_outside_vault(app: Control, V: String) -> void:
	var outside: String = V.path_join("../outside-image-read.png").simplify_path()
	save_image(outside, 8, 8, Color.RED)
	var refs: Array = ["../outside-image-read.png", outside]
	await open_in(app, "Outside Images", "\n\n".join(refs.map(func(t: String) -> String: return "![out](%s)" % t)), "visual")
	for t in refs:
		check(muted_label(LayerEngine._visual_vbox, "Images outside the vault are not loaded: " + t) != null, "Read view says why %s isn't shown (%s)" % [t, label_texts(LayerEngine._visual_vbox)])
	app._switch_layer("structured")
	await frames(4)
	for t in refs:
		check(muted_label(LayerEngine._structured_vbox, "Images outside the vault are not loaded: " + t) != null, "and so does its Outline row")
	DirAccess.remove_absolute(outside)


func open_in(app: Control, title: String, text: String, mode: String) -> void:
	var n: ContentLayer = VaultStore.create_note(title)
	n.raw_text = text
	VaultStore.save_note(n)
	app._refresh_note_list()
	app.open_note_by_title(title)
	await frames(2)
	app._switch_layer(mode)
	await frames(4)


func section_label(root: Node, prefix: String) -> Label:
	for l in find_all(root, "Label"):
		if (l as Label).text.begins_with(prefix) and (l as Label).theme_type_variation == &"SectionLabel":
			return l
	return null


func check_outline(app: Control) -> void:
	var vbox: VBoxContainer = LayerEngine._structured_vbox
	await open_in(app, "Outline Images", "\n".join([
		"# Gallery",
		"![a red square](images/red.png)",
		"![](wide.png)",
		"![gone](images/missing.png)",
		"```",
		"![fenced](images/red.png)",
		"```",
	]), "structured")
	var heading: Label = section_label(vbox, "IMAGES")
	check(heading != null and heading.text == "IMAGES (3)",
		"Outline shows 'IMAGES (3)' for 2 images and 1 missing ref (%s)" % (heading.text if heading != null else "none"))
	var thumbs: Array = find_all(vbox, "TextureRect")
	check(thumbs.size() == 2, "Outline has 2 thumbnails (%d)" % thumbs.size())
	for t in thumbs:
		var r: TextureRect = t
		check(r.size.y > 0.0 and r.size.y <= 64.0 and r.texture != null, "thumbnail %s is at most 64 px high (%s)" % [r.tooltip_text, r.size])
	if thumbs.size() == 2:
		check((thumbs[0] as TextureRect).size == Vector2(8, 8), "a small image is not enlarged into a thumbnail (%s)" % (thumbs[0] as TextureRect).size)
		var wide_size: Vector2 = (thumbs[1] as TextureRect).size
		check(wide_size.x == LayerEngine.THUMB_SIZE.x and wide_size.y >= 1.0 and wide_size.y <= 2.0,
			"the 4000x40 thumbnail shrinks to the thumbnail box width, keeping its aspect (%s)" % wide_size)
		check(str(thumbs[0].get_meta("image_path", "")).ends_with("images/red.png"), "a thumbnail carries image_path meta")
	var texts: Array = label_texts(vbox)
	check(texts.has("a red square") and texts.has("wide.png"), "each row names the image by alt, or by target with no alt")
	check(muted_label(vbox, "Image not found: images/missing.png") != null, "the missing ref has its own muted row")
	check(not texts.has("No headings, lists or code blocks yet."), "a note with images is not 'empty'")
	var layout_min: Vector2 = app.get_node("AppLayout").get_combined_minimum_size()
	check(layout_min.x <= 820, "Outline with thumbnails fits the 820-px window (%s)" % layout_min)
	await shot("image_outline")

	await open_in(app, "Only Image", "![a red square](images/red.png)", "structured")
	check(section_label(vbox, "IMAGES") != null and section_label(vbox, "IMAGES").text == "IMAGES (1)", "a note that is only an image lists it")
	check(not label_texts(vbox).has("No headings, lists or code blocks yet."), "and does not show the empty-outline hint")

	await open_in(app, "No Images", "# Plain\n- one item\nSee ![mid](images/red.png) inline.", "structured")
	check(section_label(vbox, "IMAGES") == null, "a note with no image lines shows no IMAGES label")
	check(find_all(vbox, "TextureRect").is_empty(), "and no thumbnails")


## An image's height follows its column width. If the column narrowed when
## DocScroll's scrollbar appeared, a note within one scrollbar width of the
## view's height would loop: too tall, the bar shows, the image shrinks, the
## note fits, the bar hides, the image grows... until Godot runs out of
## message queue and crashes (SIGSEGV). Sweep the window height 1 px at a time
## across the point where the bar appears, as a user dragging the window edge.
func check_resize_sweep(app: Control, V: String) -> void:
	save_image(V.path_join("images/photo.png"), 1600, 1200, Color.SANDY_BROWN)
	await open_in(app, "Trip", "# Trip\nWe went to the coast.\n![the beach](images/photo.png)", "visual")
	var ds: ScrollContainer = app.doc_scroll
	var vbar: VScrollBar = ds.get_v_scroll_bar()
	var rects: Array = find_all(LayerEngine._visual_vbox, "TextureRect")
	check(rects.size() == 1, "the photo note shows one image (%d)" % rects.size())
	if rects.size() != 1:
		return
	var rect: TextureRect = rects[0]
	var root0: Vector2i = get_root().size
	var content_h: float = (ds.get_child(0) as Control).get_combined_minimum_size().y
	var centre: int = root0.y + int(content_h - ds.size.y)
	var toggles: Array = [0]
	var on_toggle := func() -> void: toggles[0] += 1
	vbar.visibility_changed.connect(on_toggle)
	var widths: Dictionary = {}
	var bar_states: Dictionary = {}
	var loops: Array = []
	for h in range(maxi(root0.y, centre - 16), centre + 17):
		get_root().size = Vector2i(root0.x, h)
		await frames(3)
		toggles[0] = 0
		await frames(3)
		if toggles[0] > 0:
			loops.append(h)
		widths[rect.size.x] = true
		bar_states[vbar.visible] = true
	vbar.visibility_changed.disconnect(on_toggle)
	get_root().size = root0
	await frames(3)
	check(bar_states.size() == 2, "the sweep crosses the height where DocScroll's scrollbar appears (around root h=%d)" % centre)
	check(loops.is_empty(), "the scrollbar settles at every height, no on/off loop (looped at %s)" % [loops])
	check(widths.size() == 1, "the image keeps one width whether or not the scrollbar shows (%s)" % [widths.keys()])
