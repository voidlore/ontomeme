class_name ImageEmbeds
extends RefCounted
## Image refs in notes (image_embeds, phase 1 of the plan): one parser and
## resolver that the renderer, importer, linter and md_export share.
##
## A note shows an image with a standard Markdown line that is exactly one
## image, `![alt](images/x.png)` or `![alt](images/x.png "title")`. Image
## files live in <vault>/images/; a bare name (`x.png`) resolves there, any
## other target is relative to the vault. Nothing outside the vault loads:
## no URLs, no data: URIs, no absolute or ~ paths, no `..` escapes. Only
## png, jpg/jpeg and webp (Godot has no runtime GIF loader).
##
## Static only, no UI and no vault state, so it runs headless.

const EXTS: Array[String] = ["png", "jpg", "jpeg", "webp"]
const DIR := "images"

## `![alt](target)`, `![alt](<target with spaces>)`, optional "title". A
## bare target may hold one level of balanced parentheses: `photo(1).png`.
const _REF_RX: String = "^!\\[([^\\]]*)\\]\\(\\s*(?:<([^>]+)>|((?:[^\\s()<>]|\\([^\\s()<>]*\\))+))(?:\\s+\"([^\"]*)\")?\\s*\\)$"
## `http:`, `https:`, `data:`, `file:` …: a URL scheme (two or more
## characters, so a drive letter like `C:` is not one).
const _SCHEME_RX: String = "^[A-Za-z][A-Za-z0-9+.\\-]+:"

## Every way a note's text may name a file, for targets_anywhere(): a link or
## image destination anywhere on a line, in `<…>`, bare (one level of
## balanced parentheses) or loose (spaces and all, up to the `)`); a
## reference definition `[id]: target`; a wiki link or embed `[[target|…]]`;
## an HTML `src="target"`.
const _ANY_RX: Array[String] = [
	"\\]\\(\\s*<([^>\\n]+)>",
	"\\]\\(\\s*((?:[^\\s()<>]|\\([^\\s()<>]*\\))+)",
	"\\]\\(([^()\\n]+)\\)",
	"(?m)^[ \\t]*\\[[^\\]\\n]+\\]:[ \\t]*(?:<([^>\\n]+)>|(\\S+))",
	"\\[\\[([^\\]|#\\n]+)",
	"(?i)\\bsrc\\s*=\\s*(?:\"([^\"\\n]*)\"|'([^'\\n]*)')",
]

## abs path -> [mtime, Texture2D or null]
static var _cache: Dictionary = {}
## _ANY_RX compiled once
static var _any_rx: Array[RegEx] = []


## {alt, target, title} when `line` (edges stripped) is exactly one image
## ref, else {}. `target` has its %XX escapes decoded (`my%20pic.png` ->
## `my pic.png`) and keeps a `+` as written (`c++.png`): a Markdown path is
## not a form query, so String.uri_decode(), which reads `+` as a space, is
## the wrong decoder here.
static func parse_line(line: String) -> Dictionary:
	var s: String = line.strip_edges()
	if not s.begins_with("!["):
		return {}
	var rx := RegEx.new()
	rx.compile(_REF_RX)
	var m: RegExMatch = rx.search(s)
	if m == null:
		return {}
	var target: String = m.get_string(2) if m.get_string(2) != "" else m.get_string(3)
	return {"alt": m.get_string(1).strip_edges(), "target": target.uri_file_decode(), "title": m.get_string(4)}


## The Markdown line that shows `target` with caption `alt`, written so
## parse_line() gives the same alt and target back: `[`, `]` and line breaks
## leave the alt; `%`, `<` and `>` in the target are %XX-escaped; a target
## with spaces or parentheses a bare link can't hold goes in `<…>`.
static func ref_line(alt: String, target: String) -> String:
	var a: String = alt.replace("[", "").replace("]", "").replace("\r", " ").replace("\n", " ").strip_edges()
	var t: String = target.replace("%", "%25").replace("<", "%3C").replace(">", "%3E")
	var bare := RegEx.new()
	bare.compile("^(?:[^\\s()<>]|\\([^\\s()<>]*\\))+$")
	if bare.search(t) == null:
		t = "<" + t + ">"
	return "![%s](%s)" % [a, t]


## Every standalone image ref outside fenced blocks, in note order, each
## {alt, target, title, line} with `line` the 0-based line index. Fences follow
## the renderer's rule (layer_engine.gd _render_visual): a fence closes only on
## a line of at least as many backticks, and an unclosed fence runs to the end.
static func refs_in(raw_text: String) -> Array[Dictionary]:
	var refs: Array[Dictionary] = []
	var in_code: bool = false
	var fence_len: int = 0
	var lines: PackedStringArray = raw_text.split("\n")
	for i in range(lines.size()):
		var s: String = lines[i].strip_edges()
		var ticks: int = _fence_ticks(s)
		if in_code:
			if ticks >= fence_len and s.substr(ticks).strip_edges() == "":
				in_code = false
			continue
		if ticks > 0:
			in_code = true
			fence_len = ticks
			continue
		var ref: Dictionary = parse_line(s)
		if not ref.is_empty():
			ref["line"] = i
			refs.append(ref)
	return refs


## Every target `raw_text` may name a file with, wherever it stands: a link
## or image destination anywhere on a line (`](x.png)` in a list item, a
## table, a paragraph, a fence or a code span), a reference definition
## (`[id]: x.png`), a wiki link or embed (`[[x.png]]`, `![[x.png|200]]`) or
## an HTML `src="x.png"`. Each comes as written and, when it differs,
## %XX-decoded. Much wider than refs_in() on purpose: it answers "does any
## note still use this file?" before the file goes to the trash, where a
## missed use breaks another note's image and a spare hit only keeps a file.
static func targets_anywhere(raw_text: String) -> PackedStringArray:
	if _any_rx.is_empty():
		for p in _ANY_RX:
			var rx := RegEx.new()
			rx.compile(p)
			_any_rx.append(rx)
	var found := PackedStringArray()
	for rx in _any_rx:
		for m in rx.search_all(raw_text):
			for g in range(1, m.get_group_count() + 1):
				var t: String = m.get_string(g).strip_edges()
				if t == "":
					continue
				found.append(t)
				var decoded: String = t.uri_file_decode()
				if decoded != t:
					found.append(decoded)
	return found


## True when some target in `raw_text` (targets_anywhere) names the file at
## `abs_path`, an absolute path from resolve() inside `vault_path`. Case is
## ignored, as Windows and macOS ignore it: there `Images/Red.PNG` opens
## images/red.png.
static func refers_to(raw_text: String, abs_path: String, vault_path: String) -> bool:
	if abs_path == "":
		return false
	for t in targets_anywhere(raw_text):
		var p: String = resolve(t, vault_path)
		if p != "" and p.nocasecmp_to(abs_path) == 0:
			return true
	return false


## The absolute path a target names inside `vault_path`, or "" when it must
## not load: a scheme (http:, https:, file:, data:, a drive letter), an
## absolute or ~ path, a path that leaves the vault, or an extension not in
## EXTS. A bare name maps to <vault>/images/<name>.
static func resolve(target: String, vault_path: String) -> String:
	var t: String = target.strip_edges().replace("\\", "/")
	if t == "" or vault_path == "" or is_remote(t):
		return ""
	if t.begins_with("/") or t.begins_with("~") or t.is_absolute_path():   # C:/… too
		return ""
	if t.get_extension().to_lower() not in EXTS:
		return ""
	var rel: String = t if t.contains("/") else DIR.path_join(t)
	var vault: String = vault_path.simplify_path()
	var path: String = vault.path_join(rel).simplify_path()
	return path if path.begins_with(vault + "/") else ""


## True when `target` names a URL (`https:`, `data:`, `file:` …). The app
## is offline and never fetches one.
static func is_remote(target: String) -> bool:
	var rx := RegEx.new()
	rx.compile(_SCHEME_RX)
	return rx.search(target.strip_edges()) != null


## The image at `abs_path` as a texture, or null when the file is missing or
## does not decode. Cached per path and reloaded when the file's mtime changes.
static func load_texture(abs_path: String) -> Texture2D:
	if abs_path == "" or not FileAccess.file_exists(abs_path):
		_cache.erase(abs_path)
		return null
	var mtime: int = FileAccess.get_modified_time(abs_path)
	var hit: Array = _cache.get(abs_path, [])
	if not hit.is_empty() and hit[0] == mtime:
		return hit[1]
	var tex: Texture2D = null
	var img: Image = _decode(FileAccess.get_file_as_bytes(abs_path))
	if img != null:
		tex = ImageTexture.create_from_image(img)
	_cache[abs_path] = [mtime, tex]
	return tex


## Decode by content, not extension: the signature picks the decoder, so a
## jpg saved as .png still loads and garbage bytes never reach a decoder.
static func _decode(bytes: PackedByteArray) -> Image:
	var img := Image.new()
	var err: Error = FAILED
	if _starts_with(bytes, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]):
		err = img.load_png_from_buffer(bytes)
	elif _starts_with(bytes, [0xFF, 0xD8, 0xFF]):
		err = img.load_jpg_from_buffer(bytes)
	elif bytes.size() >= 12 and bytes.slice(0, 4).get_string_from_ascii() == "RIFF" \
			and bytes.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = img.load_webp_from_buffer(bytes)
	return img if err == OK and not img.is_empty() else null


static func _starts_with(bytes: PackedByteArray, magic: Array) -> bool:
	if bytes.size() < magic.size():
		return false
	for i in range(magic.size()):
		if bytes[i] != magic[i]:
			return false
	return true


## Leading backticks if `s` opens/closes a fence (>= 3), else 0 — the
## renderer's fence rule (layer_engine.gd _fence_ticks).
static func _fence_ticks(s: String) -> int:
	var n: int = 0
	while n < s.length() and s[n] == "`":
		n += 1
	return n if n >= 3 else 0
