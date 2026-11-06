class_name N64ObjectExtract
extends RefCounted
## Object photos on a plain (usually white) background: finds the object, crops it and
## lines it up for its use, before the normal N64 conversion.
##  - DOOR: crops to the panel (hardware poking past the edges is cut off) and mirrors it
##    if needed so the hinges sit on the image's LEFT edge (Door panels hinge on their -X
##    edge, which is where u = 0 goes). Background showing through the door (glass panes,
##    screens, gate bars) becomes dark glass, or transparent (Holes.CUT_OUT).
##  - WINDOW: crops to the frame; background outside it becomes transparent (white glass
##    inside the frame stays).
##  - PROP: crops to the object; background becomes transparent (cut-out).

enum Kind { NONE, DOOR, WINDOW, PROP }
## Door: what background seen through the door turns into.
enum Holes { GLASS, CUT_OUT }
const HOLES_NAMES := ["Dark glass", "Cut out (see-through)"]
const KIND_NAMES := ["None", "Door", "Window", "Prop"]
const KIND_CATEGORIES := ["", "doors", "windows", "props"]
const KIND_KEYWORDS := [[], ["door", "gate", "hatch"], ["window", "shutter", "pane"], []]

## Longest side of the working mask (finding the object doesn't need full resolution).
const MASK_SIZE := 512
## Colour distance from the background still counted as background (JPEG noise, shadows).
const BG_TOLERANCE := 0.08
## A row / column belongs to a door panel when this fraction of its span is object.
const PANEL_COVERAGE := 0.6
## Longest side of the extracted image.
const WORK_SIZE := 1024
## Background seen through an object must match the background this closely (tighter
## than BG_TOLERANCE, so white paint isn't taken for a hole)...
const HOLE_TOLERANCE := 0.07
## ...and cover at least this fraction of the panel as one region.
const HOLE_MIN_AREA := 0.004
## Doors with more of their panel open than this are gates / screens: cut out.
const CUT_OUT_FRACTION := 0.65
## Glass colour, top and bottom of a pane (OoT style dark windows).
## Handle search: relative contrast between mirror-twin pixels / against the row.
const KNOB_MIRROR_CONTRAST := 0.45
const KNOB_CONTRAST := 0.4
const GLASS_TOP := Color(0.32, 0.38, 0.45)
const GLASS_BOTTOM := Color(0.13, 0.16, 0.2)


## Looks at a photo: {background (bool), kind, mirror, hinge_confidence, aspect (of the
## extracted object)}. `background` is false when the edges aren't one plain colour.
## `force_kind` >= 0 skips guessing the kind.
static func analyse(img: Image, file_name := "", force_kind := -1) -> Dictionary:
	var out := {background = false, kind = Kind.NONE, mirror = false, hinge_confidence = 0.0, hinge_by = "",
		aspect = 1.0, holes = Holes.GLASS, hole_fraction = 0.0}
	var m := _Mask.new(img)
	if not m.ok:
		return out
	out.background = true
	var kind := Kind.NONE
	var toks := N64TextureConverter.tokens(file_name)
	for k in [Kind.DOOR, Kind.WINDOW]:
		for t in toks:
			for kw: String in KIND_KEYWORDS[k]:
				if t.begins_with(kw):
					kind = k
	if force_kind >= 0:
		kind = force_kind as Kind
	elif kind == Kind.NONE:
		# A solid, upright rectangle reads as a door; anything else as a cut-out prop.
		var panel := m.panel_rect()
		var fill := m.fill(panel)
		var aspect := float(panel.size.x) / panel.size.y
		kind = Kind.DOOR if fill > 0.9 and aspect > 0.3 and aspect < 0.8 else Kind.PROP
	out.kind = kind
	var rect := m.panel_rect() if kind == Kind.DOOR else m.bounds
	out.aspect = float(rect.size.x) / rect.size.y * m.pixel_aspect()
	if kind == Kind.DOOR:
		var h := hinge_side(img, m, rect)
		out.mirror = h.side > 0
		out.hinge_confidence = h.confidence
		out.hinge_by = h.by
		out.hole_fraction = m.hole_fraction(rect)
		out.holes = Holes.CUT_OUT if out.hole_fraction > CUT_OUT_FRACTION else Holes.GLASS
	return out


## The object cut out of `img` for `kind`, mirrored left-right if asked.
static func extract(img: Image, kind: Kind, mirror: bool, holes := Holes.GLASS) -> Image:
	if kind == Kind.NONE:
		return img
	var m := _Mask.new(img)
	if not m.ok:
		return img
	var rect := m.panel_rect() if kind == Kind.DOOR else m.bounds
	var src_rect := m.to_source(rect, img.get_size())
	var out := img.get_region(src_rect)
	out.convert(Image.FORMAT_RGBA8)
	# Plenty for the converter (it works at 4x the N64 size, at most 1024 px).
	var k := minf(1.0, float(WORK_SIZE) / maxi(out.get_width(), out.get_height()))
	if k < 1.0:
		out.resize(maxi(int(out.get_width() * k), 1), maxi(int(out.get_height() * k), 1), Image.INTERPOLATE_LANCZOS)
	# Background left inside the crop (chipped corners, gaps): transparent, then for doors
	# filled from the neighbouring wood so the panel stays solid.
	var alpha := m.alpha_region(rect, out.get_size())
	var hole := m.alpha_region(rect, out.get_size(), true) if kind == Kind.DOOR else null
	for y in out.get_height():
		for x in out.get_width():
			var c := out.get_pixel(x, y)
			c.a = alpha.get_pixel(x, y).r
			if hole and hole.get_pixel(x, y).r > 0.3:
				c.a = 0.0
			out.set_pixel(x, y, c)
	if kind == Kind.DOOR:
		_bleed(out)
		var h := float(out.get_height())
		for y in out.get_height():
			for x in out.get_width():
				var c := out.get_pixel(x, y)
				if hole.get_pixel(x, y).r > 0.3:
					if holes == Holes.CUT_OUT:
						c.a = 0.0  # colour stays bled from the frame (no halos)
					else:
						c = _glass(x, y / h, out.get_width())
				else:
					c.a = 1.0
				out.set_pixel(x, y, c)
	if mirror:
		out.flip_x()
	return out


## Dark glass: darker towards the bottom, with a faint diagonal sheen.
static func _glass(x: int, v: float, width: int) -> Color:
	var c := GLASS_TOP.lerp(GLASS_BOTTOM, v)
	var d := fposmod(float(x) / width * 0.6 + v * 1.4, 1.0)
	return c.lightened(0.12 * clampf(1.0 - absf(d - 0.3) / 0.06, 0.0, 1.0))


## Which edge the hinges are on: -1 left, +1 right, with how sure (0..1) and what gave it
## away. Strap hinges are long dark bands running in from the hinge edge (the latch side
## has at most a small lock); doors without them are read by their handle / knob, which
## sits on the latch side.
static func hinge_side(img: Image, m: _Mask, rect: Rect2i) -> Dictionary:
	var straps := _strap_side(img, m, rect)
	if straps.confidence >= 0.8:
		return straps
	var knob := _knob_side(img, m, rect)
	if knob.confidence > straps.confidence:
		return knob
	return straps


## Handle / knob / lock: small, strongly contrasting blobs near one edge around mid
## height. Long vertical features (mouldings, stiles, frames) don't count.
static func _knob_side(img: Image, m: _Mask, rect: Rect2i) -> Dictionary:
	var src := img.get_region(m.to_source(rect, img.get_size()))
	var h := 256
	src.resize(maxi(int(float(h) * src.get_width() / src.get_height() * m.pixel_aspect()), 32), h, Image.INTERPOLATE_BILINEAR)
	src.convert(Image.FORMAT_RGBA8)
	var w := src.get_width()
	var y0 := int(h * 0.38)
	var y1 := int(h * 0.68)
	# Typical door colour around each height: median of the row.
	var row_med := PackedColorArray()
	for y in range(y0, y1):
		var lums: Array = []
		for x in w:
			lums.append(src.get_pixel(x, y))
		lums.sort_custom(func(a: Color, b: Color): return a.get_luminance() < b.get_luminance())
		row_med.append(lums[lums.size() / 2])
	# Doors are near mirror-symmetric (panels, mouldings, frames, glass); hardware isn't.
	# Compare each pixel with its mirror twin: where they differ, the one further from the
	# row's typical colour is a hit on its side. Then take the densest small window, as a
	# knob / handle is one compact blob while wear and grain are spread out.
	var score := [0.0, 0.0]
	var bh := y1 - y0
	var xa := int(w * 0.03)
	var xb := int(w * 0.4)
	var bw := xb - xa
	var win := Vector2i(maxi(int(w * 0.12), 3), maxi(int(h * 0.1), 3))
	var hits := [PackedInt32Array(), PackedInt32Array()]
	for side in 2:
		hits[side].resize(bw * bh)
	for y in range(y0, y1):
		var med := row_med[y - y0]
		for x in range(xa, xb):
			var cl := src.get_pixel(x, y)
			var cr := src.get_pixel(w - 1 - x, y)
			# Contrast relative to brightness, so dull brass on dark wood still counts.
			if _rel(cl, cr) < KNOB_MIRROR_CONTRAST:
				continue
			var dl := _rel(cl, med) if _Mask._dist(cl, m.bg) >= BG_TOLERANCE else 0.0
			var dr := _rel(cr, med) if _Mask._dist(cr, m.bg) >= BG_TOLERANCE else 0.0
			if maxf(dl, dr) < KNOB_CONTRAST:
				continue
			# Index by distance from the door's edge, same for both sides.
			hits[0 if dl > dr else 1][(y - y0) * bw + x - xa] = 1
	for side in 2:
		var hit: PackedInt32Array = hits[side]
		# Summed-area table for the window search.
		var sat := PackedInt32Array()
		sat.resize((bw + 1) * (bh + 1))
		for y in bh:
			for x in bw:
				sat[(y + 1) * (bw + 1) + x + 1] = hit[y * bw + x] + sat[y * (bw + 1) + x + 1] + sat[(y + 1) * (bw + 1) + x] - sat[y * (bw + 1) + x]
		var best := 0
		for y in range(0, bh - win.y + 1):
			for x in range(0, bw - win.x + 1):
				var n := sat[(y + win.y) * (bw + 1) + x + win.x] - sat[y * (bw + 1) + x + win.x] - sat[(y + win.y) * (bw + 1) + x] + sat[y * (bw + 1) + x]
				best = maxi(best, n)
		score[side] = float(best)
	var total: float = score[0] + score[1]
	if total < 6.0:
		return {side = -1, confidence = 0.0, by = "nothing found"}
	# Knob on the right = hinges on the left.
	var side := -1 if score[1] >= score[0] else 1
	return {side = side, confidence = absf(score[1] - score[0]) / total * 0.9, by = "handle"}


## Colour difference relative to how bright the pair is.
static func _rel(a: Color, b: Color) -> float:
	return _Mask._dist(a, b) / (0.15 + maxf(a.get_luminance(), b.get_luminance()))


static func _strap_side(img: Image, m: _Mask, rect: Rect2i) -> Dictionary:
	var src := img.get_region(m.to_source(rect, img.get_size()))
	src.resize(maxi(int(256.0 * src.get_width() / src.get_height()), 32), 256, Image.INTERPOLATE_BILINEAR)
	var w := src.get_width()
	# "Dark" relative to the panel itself (works on dark wood too).
	var lum := PackedFloat32Array()
	lum.resize(w * src.get_height())
	var sorted := PackedFloat32Array()
	for y in src.get_height():
		for x in w:
			lum[y * w + x] = src.get_pixel(x, y).get_luminance()
	sorted = lum.duplicate()
	sorted.sort()
	var dark := sorted[int(sorted.size() * 0.5)] * 0.45
	var edge := int(w * 0.12)
	var score := [0.0, 0.0]  # left, right
	for y in src.get_height():
		# Longest dark run starting near each edge.
		for side in 2:
			var run := 0
			var started := false
			for i in w:
				var x := i if side == 0 else w - 1 - i
				var d := lum[y * w + x] < dark
				if not started:
					if d and i <= edge:
						started = true
						run = 1
					elif i > edge:
						break
				elif d or (i + 1 < w and lum[y * w + (x + (1 if side == 0 else -1))] < dark):
					run += 1  # one-pixel gaps (rivets, highlights) don't end a strap
				else:
					break
			# Only long bands are straps; frames, edge shadows and locks are short.
			if run >= w * 0.25:
				score[side] += float(run)
	var total: float = score[0] + score[1]
	if total < w * 0.25 * src.get_height() * 0.03:
		return {side = -1, confidence = 0.0, by = "straps"}
	var side := -1 if score[0] >= score[1] else 1
	return {side = side, confidence = absf(score[1] - score[0]) / total, by = "straps"}


## Spreads colour from opaque pixels into transparent ones (no white halos when the
## converter averages or the alpha is dropped).
static func _bleed(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var todo: Array[Vector2i] = []
	for y in h:
		for x in w:
			if img.get_pixel(x, y).a <= 0.5:
				todo.append(Vector2i(x, y))
	while not todo.is_empty():
		var filled := {}
		var left: Array[Vector2i] = []
		for p in todo:
			var sum := Color(0, 0, 0, 0)
			var n := 0
			for o: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var q := p + o
				if q.x >= 0 and q.y >= 0 and q.x < w and q.y < h:
					var c := img.get_pixel(q.x, q.y)
					if c.a > 0.5:
						sum += c
						n += 1
			if n > 0:
				filled[p] = sum / n
			else:
				left.append(p)
		if filled.is_empty():
			break
		for p: Vector2i in filled:
			var c: Color = filled[p]
			c.a = 0.75  # counts as filled from now on, still marked as not original
			img.set_pixelv(p, c)
		todo = left


## Object mask of a downscaled copy: background = border-connected pixels close to the
## border's colour.
class _Mask:
	var ok := false
	var size := Vector2i.ZERO
	var mask := PackedByteArray()  # 1 = object
	var holes := PackedByteArray()  # 1 = background seen through the object
	var bounds := Rect2i()
	var _scale := Vector2.ONE  # source px per mask px
	var bg := Color.WHITE

	func _init(img: Image) -> void:
		var small := img.duplicate() as Image
		if small.is_compressed():
			small.decompress()
		small.convert(Image.FORMAT_RGBA8)
		var k := float(N64ObjectExtract.MASK_SIZE) / maxi(img.get_width(), img.get_height())
		size = Vector2i(maxi(int(img.get_width() * k), 8), maxi(int(img.get_height() * k), 8))
		small.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
		_scale = Vector2(img.get_size()) / Vector2(size)
		# Background colour: median of the border; must be fairly uniform.
		var border: Array[Color] = []
		for x in size.x:
			border.append(small.get_pixel(x, 0))
			border.append(small.get_pixel(x, size.y - 1))
		for y in size.y:
			border.append(small.get_pixel(0, y))
			border.append(small.get_pixel(size.x - 1, y))
		var lums: Array = border.map(func(c: Color): return c.get_luminance())
		lums.sort()
		var med: float = lums[lums.size() / 2]
		for c in border:
			if absf(c.get_luminance() - med) < 0.01:
				bg = c
				break
		var near := 0
		for c in border:
			if _dist(c, bg) < N64ObjectExtract.BG_TOLERANCE:
				near += 1
		if near < border.size() * 0.8:
			return  # not a plain background
		# Flood fill from the border.
		mask.resize(size.x * size.y)
		mask.fill(1)
		var stack := PackedInt32Array()
		for x in size.x:
			stack.append(x)
			stack.append((size.y - 1) * size.x + x)
		for y in size.y:
			stack.append(y * size.x)
			stack.append(y * size.x + size.x - 1)
		while not stack.is_empty():
			var i := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			if mask[i] == 0:
				continue
			var x := i % size.x
			var y := i / size.x
			var c := small.get_pixel(x, y)
			if _dist(c, bg) >= N64ObjectExtract.BG_TOLERANCE and c.a > 0.1:
				continue
			mask[i] = 0
			if x > 0: stack.append(i - 1)
			if x < size.x - 1: stack.append(i + 1)
			if y > 0: stack.append(i - size.x)
			if y < size.y - 1: stack.append(i + size.x)
		var lo := size
		var hi := Vector2i(-1, -1)
		for y in size.y:
			for x in size.x:
				if mask[y * size.x + x]:
					lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
					hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
		if hi.x < lo.x:
			return
		bounds = Rect2i(lo, hi - lo + Vector2i.ONE)
		ok = true
		_find_holes(small, bg)

	## Enclosed regions of (almost exactly) background colour big enough to be openings.
	func _find_holes(small: Image, bg: Color) -> void:
		holes.resize(size.x * size.y)
		holes.fill(0)
		var seen := PackedByteArray()
		seen.resize(size.x * size.y)
		var min_px := int(bounds.get_area() * N64ObjectExtract.HOLE_MIN_AREA)
		for start in size.x * size.y:
			if seen[start] or not mask[start] or _dist(small.get_pixel(start % size.x, start / size.x), bg) >= N64ObjectExtract.HOLE_TOLERANCE:
				continue
			var region := PackedInt32Array()
			var stack := PackedInt32Array([start])
			seen[start] = 1
			while not stack.is_empty():
				var i := stack[stack.size() - 1]
				stack.resize(stack.size() - 1)
				region.append(i)
				var x := i % size.x
				var y := i / size.x
				for j in [i - 1 if x > 0 else -1, i + 1 if x < size.x - 1 else -1, i - size.x if y > 0 else -1, i + size.x if y < size.y - 1 else -1]:
					if j >= 0 and not seen[j] and mask[j] and _dist(small.get_pixel(j % size.x, j / size.x), bg) < N64ObjectExtract.HOLE_TOLERANCE:
						seen[j] = 1
						stack.append(j)
			if region.size() >= min_px:
				for i in region:
					holes[i] = 1

	## Holes within crop `r`: the enclosed ones, plus background inside the crop that
	## reaches the outside (gaps between gate bars open at the top) when it is big enough
	## not to be a chipped corner.
	func holes_in(r: Rect2i) -> PackedByteArray:
		var out := holes.duplicate()
		var seen := PackedByteArray()
		seen.resize(size.x * size.y)
		var min_px := int(r.get_area() * N64ObjectExtract.HOLE_MIN_AREA * 4.0)
		for sy in range(r.position.y, r.end.y):
			for sx in range(r.position.x, r.end.x):
				var start := sy * size.x + sx
				if seen[start] or mask[start]:
					continue
				var region := PackedInt32Array()
				var stack := PackedInt32Array([start])
				seen[start] = 1
				while not stack.is_empty():
					var i := stack[stack.size() - 1]
					stack.resize(stack.size() - 1)
					region.append(i)
					var x := i % size.x
					var y := i / size.x
					for o in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
						var q: Vector2i = Vector2i(x, y) + o
						if r.has_point(q):
							var j := q.y * size.x + q.x
							if not seen[j] and not mask[j]:
								seen[j] = 1
								stack.append(j)
				if region.size() >= min_px:
					for i in region:
						out[i] = 1
		return out

	func hole_fraction(r: Rect2i) -> float:
		var h := holes_in(r)
		var count := 0
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				count += h[y * size.x + x]
		return float(count) / maxi(r.get_area(), 1)

	static func _dist(a: Color, b: Color) -> float:
		return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()

	func pixel_aspect() -> float:
		return _scale.x / _scale.y

	## The solid body: longest runs of columns / rows mostly covered by the object (cuts
	## off handles, hinge pins, latches poking past the edges).
	func panel_rect() -> Rect2i:
		var cols := _runs(true)
		var rows := _runs(false)
		return Rect2i(cols.x, rows.x, cols.y - cols.x, rows.y - rows.x)

	func _runs(columns: bool) -> Vector2i:
		var n := size.x if columns else size.y
		var span := bounds.size.y if columns else bounds.size.x
		var best := Vector2i(bounds.position.x, bounds.end.x) if columns else Vector2i(bounds.position.y, bounds.end.y)
		var best_len := 0
		var start := -1
		for i in n + 1:
			var full := false
			if i < n:
				var count := 0
				for j in span:
					var x := i if columns else bounds.position.x + j
					var y := bounds.position.y + j if columns else i
					count += mask[y * size.x + x]
				full = count >= span * N64ObjectExtract.PANEL_COVERAGE
			if full and start < 0:
				start = i
			elif not full and start >= 0:
				if i - start > best_len:
					best_len = i - start
					best = Vector2i(start, i)
				start = -1
		return best

	func fill(r: Rect2i) -> float:
		var count := 0
		for y in range(r.position.y, r.end.y):
			for x in range(r.position.x, r.end.x):
				count += mask[y * size.x + x]
		return float(count) / maxi(r.get_area(), 1)

	## Mask rect in source pixels (rounded inwards a little so no background edge shows).
	func to_source(r: Rect2i, source_size: Vector2i) -> Rect2i:
		var p := Vector2i((Vector2(r.position) + Vector2(0.5, 0.5)) * _scale)
		var e := Vector2i((Vector2(r.end) - Vector2(0.5, 0.5)) * _scale)
		p = p.clamp(Vector2i.ZERO, source_size - Vector2i.ONE)
		e = e.clamp(p + Vector2i.ONE, source_size)
		return Rect2i(p, e - p)

	## Mask (or the holes) of `r` as a greyscale image of `out_size` (smooth edges).
	func alpha_region(r: Rect2i, out_size: Vector2i, of_holes := false) -> Image:
		var img := Image.create(r.size.x, r.size.y, false, Image.FORMAT_L8)
		var src := holes_in(r) if of_holes else mask
		for y in r.size.y:
			for x in r.size.x:
				img.set_pixel(x, y, Color.WHITE if src[(r.position.y + y) * size.x + r.position.x + x] else Color.BLACK)
		img.resize(out_size.x, out_size.y, Image.INTERPOLATE_BILINEAR)
		return img
