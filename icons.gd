class_name Icons
extends RefCounted
## Small UI icons drawn in code (anti-aliased line segments, optionally a
## filled polygon), so they never depend on which glyphs a font has. White;
## tint with icon colour overrides.

static var _cache: Dictionary = {}


static func get_icon(name: String, size: int = 16) -> Texture2D:
	var key: String = "%s@%d" % [name, size]
	if _cache.has(key):
		return _cache[key]
	var segs: Array = []   # [Vector2 a, Vector2 b] in a 16x16 design grid
	var width: float = 1.5
	var fill := PackedVector2Array()   # a polygon drawn solid, same grid
	match name:
		"check_box":
			segs = _square()
		"check_box_on":
			segs = _square() + [[Vector2(5.4, 8.2), Vector2(7.3, 10.2)], [Vector2(7.3, 10.2), Vector2(10.8, 5.9)]]
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
		"download":
			# An arrow down into an open tray (Export as Markdown). Centred on
			# x = 7.5 so the shaft lands on pixel centres at 16 px
			segs = [
				[Vector2(7.5, 2.5), Vector2(7.5, 10)],
				[Vector2(4, 6.5), Vector2(7.5, 10)], [Vector2(7.5, 10), Vector2(11, 6.5)],
				[Vector2(2.5, 10.5), Vector2(2.5, 13.5)], [Vector2(2.5, 13.5), Vector2(12.5, 13.5)],
				[Vector2(12.5, 13.5), Vector2(12.5, 10.5)],
			]
		"dot":
			# A filled disc (a zero-length segment as wide as the disc): a tag's colour
			segs = [[Vector2(8, 8), Vector2(8, 8)]]
			width = 9.0
		"tag":
			# A label: rounded banner with a punched hole at the left
			segs = [
				[Vector2(2.5, 4), Vector2(6.5, 4)], [Vector2(6.5, 4), Vector2(13, 8)],
				[Vector2(13, 8), Vector2(6.5, 12)], [Vector2(6.5, 12), Vector2(2.5, 12)],
				[Vector2(2.5, 12), Vector2(2.5, 4)],
				[Vector2(4.5, 6.2), Vector2(5.2, 6.9)], [Vector2(5.2, 6.9), Vector2(4.5, 7.6)],
			]
		"warning":
			# A triangle with an exclamation mark
			segs = [
				[Vector2(8, 2.5), Vector2(14, 13)], [Vector2(14, 13), Vector2(2, 13)], [Vector2(2, 13), Vector2(8, 2.5)],
				[Vector2(8, 6.3), Vector2(8, 9)], [Vector2(8, 11), Vector2(8, 11.1)],
			]
		"star", "star_filled":
			# Outline = off, filled = on (starred)
			segs = _outline(_star())
			width = 1.25
			if name == "star_filled":
				fill = _star()
		"pin", "pin_filled":
			# A pushpin: cap, head flaring to a crossbar, needle. Filled head = pinned
			segs = _outline(_pin_head()) + [[Vector2(4, 2.5), Vector2(11, 2.5)], [Vector2(7.5, 9.5), Vector2(7.5, 14.5)]]
			width = 1.25
			if name == "pin_filled":
				fill = _pin_head()
		"moon":
			segs = _crescent()
		"sun":
			# A disc outline with eight short rays
			segs = _arc(Vector2(8, 8), 3.0, 0.0, TAU, 16)
			for i in range(8):
				var dir := Vector2.from_angle(i * TAU / 8.0)
				segs.append([Vector2(8, 8) + dir * 5.0, Vector2(8, 8) + dir * 6.6])
		"command":
			# The Mac command key (⌘): a # whose four ends curl into loops
			segs = [
				[Vector2(6, 4), Vector2(6, 12)], [Vector2(10, 4), Vector2(10, 12)],
				[Vector2(4, 6), Vector2(12, 6)], [Vector2(4, 10), Vector2(12, 10)],
			]
			for c in [Vector2(4, 4), Vector2(12, 4), Vector2(4, 12), Vector2(12, 12)]:
				# Leave out the quarter of each loop that faces the middle
				var inward: float = (Vector2(8, 8) - c).angle()
				segs += _arc(c, 2.0, inward + PI / 4.0, inward + PI / 4.0 + PI * 1.5, 9)
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var k: float = size / 16.0
	for y in range(size):
		for x in range(size):
			var p := Vector2(x + 0.5, y + 0.5) / k
			var a: float = 1.0
			if fill.is_empty() or not Geometry2D.is_point_in_polygon(p, fill):
				var d: float = 99.0
				for s in segs:
					d = minf(d, _seg_dist(p, s[0], s[1]))
				a = clampf((width * 0.5 - d) * k + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_cache[key] = ImageTexture.create_from_image(img)
	return _cache[key]


static func _folder() -> Array:
	return [
		[Vector2(2, 4), Vector2(6, 4)], [Vector2(6, 4), Vector2(7.5, 5.5)], [Vector2(7.5, 5.5), Vector2(14, 5.5)],
		[Vector2(14, 5.5), Vector2(14, 13)], [Vector2(14, 13), Vector2(2, 13)], [Vector2(2, 13), Vector2(2, 4)],
	]


## A five-point star, top point up, centred at (8, 8.4): outer radius 6.5,
## inner 2.7.
static func _star() -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(10):
		var r: float = 6.5 if i % 2 == 0 else 2.7
		var ang: float = -PI / 2.0 + i * PI / 5.0
		pts.append(Vector2(8, 8.4) + Vector2(cos(ang), sin(ang)) * r)
	return pts


## A pushpin's head: a narrow body under the cap, flaring to the crossbar.
## Centred on x = 7.5 so its verticals land on pixel centres at 16 px.
static func _pin_head() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(5.5, 2.5), Vector2(9.5, 2.5), Vector2(9.5, 6.5),
		Vector2(12, 9.5), Vector2(3, 9.5), Vector2(5.5, 6.5),
	])


## The closed outline of `poly` as segments.
static func _outline(poly: PackedVector2Array) -> Array:
	var segs: Array = []
	for i in range(poly.size()):
		segs.append([poly[i], poly[(i + 1) % poly.size()]])
	return segs


## A checkbox outline (Read-view task items).
static func _square() -> Array:
	return [
		[Vector2(3, 3), Vector2(13, 3)], [Vector2(13, 3), Vector2(13, 13)],
		[Vector2(13, 13), Vector2(3, 13)], [Vector2(3, 13), Vector2(3, 3)],
	]


## Line segments along a circle from angle a0 to a1 (radians, y down).
static func _arc(center: Vector2, radius: float, a0: float, a1: float, steps: int) -> Array:
	var segs: Array = []
	for i in range(steps):
		var p: Vector2 = center + Vector2.from_angle(lerpf(a0, a1, float(i) / steps)) * radius
		var q: Vector2 = center + Vector2.from_angle(lerpf(a0, a1, float(i + 1) / steps)) * radius
		segs.append([p, q])
	return segs


## A crescent moon: the part of one circle a second, offset circle leaves.
static func _crescent() -> Array:
	var outer := Vector2(8, 8)
	var inner := Vector2(10.6, 5.6)
	var r: float = 5.5
	var segs: Array = []
	for s in _arc(outer, r, 0.0, TAU, 32):
		if ((s[0] + s[1]) * 0.5).distance_to(inner) > r:
			segs.append(s)
	for s in _arc(inner, r, 0.0, TAU, 32):
		if ((s[0] + s[1]) * 0.5).distance_to(outer) < r:
			segs.append(s)
	return segs


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var t: float = clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
	return p.distance_to(a + ab * t)
