class_name Icons
extends RefCounted
## Small UI icons drawn in code (anti-aliased line segments), so they never
## depend on which glyphs a font has. White; tint with icon colour overrides.

static var _cache: Dictionary = {}


static func get_icon(name: String, size: int = 16) -> Texture2D:
	var key: String = "%s@%d" % [name, size]
	if _cache.has(key):
		return _cache[key]
	var segs: Array = []   # [Vector2 a, Vector2 b] in a 16x16 design grid
	var width: float = 1.5
	match name:
		"chevron_right":
			segs = [[Vector2(6, 4), Vector2(10, 8)], [Vector2(10, 8), Vector2(6, 12)]]
		"chevron_down":
			segs = [[Vector2(4, 6), Vector2(8, 10)], [Vector2(8, 10), Vector2(12, 6)]]
		"folder":
			segs = _folder()
		"folder_plus":
			segs = _folder() + [[Vector2(8, 7.5), Vector2(8, 11.5)], [Vector2(6, 9.5), Vector2(10, 9.5)]]
		"vault":
			# Three stacked "pages"
			segs = [[Vector2(3, 4), Vector2(13, 4)], [Vector2(3, 8), Vector2(13, 8)], [Vector2(3, 12), Vector2(13, 12)]]
			width = 1.8
		"play":
			segs = [[Vector2(5, 3.5), Vector2(5, 12.5)], [Vector2(5, 3.5), Vector2(12, 8)], [Vector2(12, 8), Vector2(5, 12.5)]]
		"close":
			segs = [[Vector2(4.5, 4.5), Vector2(11.5, 11.5)], [Vector2(11.5, 4.5), Vector2(4.5, 11.5)]]
		"plus":
			segs = [[Vector2(8, 3.5), Vector2(8, 12.5)], [Vector2(3.5, 8), Vector2(12.5, 8)]]
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var k: float = size / 16.0
	for y in range(size):
		for x in range(size):
			var p := Vector2(x + 0.5, y + 0.5) / k
			var d: float = 99.0
			for s in segs:
				d = minf(d, _seg_dist(p, s[0], s[1]))
			var a: float = clampf((width * 0.5 - d) * k + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_cache[key] = ImageTexture.create_from_image(img)
	return _cache[key]


static func _folder() -> Array:
	return [
		[Vector2(2, 4), Vector2(6, 4)], [Vector2(6, 4), Vector2(7.5, 5.5)], [Vector2(7.5, 5.5), Vector2(14, 5.5)],
		[Vector2(14, 5.5), Vector2(14, 13)], [Vector2(14, 13), Vector2(2, 13)], [Vector2(2, 13), Vector2(2, 4)],
	]


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var t: float = clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
	return p.distance_to(a + ab * t)
