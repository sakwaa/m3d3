@tool
class_name StrokeAlphabet
extends Resource
## A shorthand-style script (after Pitman): each word is one joined outline. Every consonant
## is a stroke drawn on from where the last one ended; vowels are dots, dashes or little
## angles beside the stroke they follow (or the one they come before, starting a word);
## voiced consonants are their partner's stroke drawn longer (voiced_length). Words that
## sound alike carry a spelling mark: a line under the word with tally ticks counting which
## one. Tooling only: the text is baked into textures; this resource and the typed English
## never ship.
##
## Edit the shapes here (units: 1 = a stroke's length, +x right, +y down): `strokes` maps a
## sound to its polylines from the pen at (0, 0) — 2 points: a straight line, 3: a curve
## (start, bend, end) — and the pen goes on from the last point. Anything that draws with
## it rebuilds when this changes.

## Sound -> Array of PackedVector2Array.
@export var strokes := {}:
	set(v):
		strokes = v
		emit_changed()
## Voiced sound -> the voiceless sound whose stroke it uses (drawn voiced_length long).
@export var voiced := {}:
	set(v):
		voiced = v
		emit_changed()
## Vowel -> [place (0 start / 1 middle / 2 end of the stroke), mark ("dot", "dash", "v",
## "^", "<"), heavy (bool)].
@export var vowels := {}:
	set(v):
		vowels = v
		emit_changed()

@export_group("Sizes")
## How far vowel marks sit from their stroke (in stroke lengths).
@export_range(0.1, 1.0, 0.01) var vowel_offset := 0.45:
	set(v):
		vowel_offset = v
		emit_changed()
## Voiced strokes are this many times as long as their voiceless partner (d is a long t).
@export_range(1.1, 2.5, 0.05) var voiced_length := 1.4:
	set(v):
		voiced_length = v
		emit_changed()
## Words with at least this many strokes are split at syllables into outlines of fewer.
@export_range(2, 10, 1) var max_strokes := 4:
	set(v):
		max_strokes = v
		emit_changed()
## Pixel sizes on a 64 pixel wide banner (doubled on a 128 wide one, so every banner
## matches): line width, bold line width (heavy dashes), dot, heavy dot (diameters).
## Every line and dot of a kind is exactly this size.
@export var pixel_sizes := Vector4i(2, 3, 4, 5):
	set(v):
		pixel_sizes = v
		emit_changed()
## Length of a dash (in stroke lengths).
@export_range(0.05, 1.0, 0.01) var dash_length := 0.5:
	set(v):
		dash_length = v
		emit_changed()
## Width of the glide marks (v ^ <) (in stroke lengths).
@export_range(0.05, 1.0, 0.01) var mark_size := 0.34:
	set(v):
		mark_size = v
		emit_changed()
## Long words (max_strokes or more): lift the pen between syllables, so the word is a row
## of short outlines instead of one long one.
@export var split_syllables := true:
	set(v):
		split_syllables = v
		emit_changed()
## Gap between words / lines (pixels at a 12 px stroke; scales with it).
@export_range(0, 16, 1) var word_gap := 3:
	set(v):
		word_gap = v
		emit_changed()


## Changes whenever anything drawn with this alphabet would look different.
func content_key() -> int:
	return hash([strokes, voiced, vowels, vowel_offset, voiced_length, max_strokes, word_gap, pixel_sizes, dash_length,
		mark_size, split_syllables])


## Pixel sizes at banner `scale` (1: 64 wide, 2: 128 wide): {line, bold, dot, heavy_dot}.
func sizes(scale: int) -> Dictionary:
	var k := maxi(1, scale)
	return {line = pixel_sizes.x * k, bold = pixel_sizes.y * k, dot = pixel_sizes.z * k, heavy_dot = pixel_sizes.w * k}


# --- Outlines ----------------------------------------------------------------------------

## One word's outline (white on transparent, hard N64 pixels) for its sounds, `px` pixels a
## stroke (line and dot sizes for banner `scale`), with `spell`'s mark after it. Every
## stroke starts on a whole pixel and every
## mark is placed on one, so a sound looks the same wherever it's written.
func outline(sounds: PackedStringArray, spell: int, px: float, scale := 1) -> Image:
	var z := sizes(scale)
	var parts := []  # {lines, w} or {dots, d}
	var stroke_lines := []  # every stroke's polylines (marks keep clear of them)
	var marks := []  # [vowel, a, b, side]: placed once all the strokes are down
	var pen := Vector2.ZERO
	var last := []  # the last stroke's [start, end]
	var circle := []  # the last circle's [left, right] (a word that's only a circle: is, as)
	var pending := []  # vowels waiting for a stroke (a word starting with a vowel)
	for s in sounds:
		if vowels.has(s):
			if last.is_empty():
				pending.append(s)
			else:
				marks.append([s, last[0], last[1], 1.0])
			continue
		var base: String = voiced.get(s, s)
		var lines := _moved(strokes.get(base, []), pen, px * (voiced_length if voiced.has(s) else 1.0))
		if lines.is_empty():
			continue
		parts.append({lines = lines, w = z.line})
		stroke_lines.append_array(lines)
		var a := pen
		var b: Vector2 = (lines[-1][-1] as Vector2).round()
		if a.distance_to(b) > px * 0.2:
			for v in pending:
				marks.append([v, a, b, -1.0])
			pending.clear()
			last = [a, b]
		else:  # a circle (s) doesn't carry vowels unless it's all there is
			var lo := Vector2(INF, INF)
			var hi := -lo
			for l in lines:
				for q in l:
					lo = lo.min(q)
					hi = hi.max(q)
			var mid := (lo.y + hi.y) * 0.5
			circle = [Vector2(lo.x, mid).round(), Vector2(hi.x, mid).round()]
		pen = b
	for v in pending:
		if not circle.is_empty():
			marks.append([v, circle[0], circle[1], -1.0])  # above the circle
		else:  # no stroke at all (a, I): beside an invisible one
			marks.append([v, Vector2.ZERO, Vector2(0, px), 1.0])
	for m in marks:
		parts.append(_vowel(m[0], m[1], m[2], m[3], px, z, stroke_lines))
	# Spelling mark: an underline beneath the whole word with tally ticks hanging from it.
	var mark_h: int = 0 if spell == 0 else _tally_height(z)
	var lo := Vector2(INF, INF)
	var hi := -lo
	for p in parts:
		var pts: Array = p.get("dots", [])
		for l in p.get("lines", []):
			pts.append_array(Array(l))
		var pad: float = p.get("d", p.get("w", 1)) * 0.5 + 1.0
		for q in pts:
			lo = lo.min(q - Vector2(pad, pad))
			hi = hi.max(q + Vector2(pad, pad))
	if parts.is_empty():
		lo = Vector2.ZERO
		hi = Vector2.ZERO
	var off := Vector2i(-lo.floor()) + Vector2i(1, 1)
	var word_h := maxi(ceili(hi.y) + off.y + 1, 8)
	var word_w := ceili(hi.x) + off.x + 1
	if spell > 0:
		word_w = maxi(word_w, _tally_width(spell, z) + 2)
	var img := Image.create(word_w, word_h + mark_h, false, Image.FORMAT_RGBA8)
	for p in parts:
		if p.has("dots"):
			for c in p.dots:
				_dot(img, c + Vector2(off), p.d)
		else:
			_raster(img, p.lines, p.w, Vector2(off))
	if spell > 0:
		_tally(img, Rect2i(1, word_h, img.get_width() - 2, mark_h), spell, z)
	return img


## The spelling mark (which of the words sounding alike this is): a line under the word,
## `spell` short ticks hanging from it (every fifth longer, like a tally), drawn in `rect`
## (its top: the gap above the line). Nothing else in the script is a line under a word.
static func _tally(img: Image, rect: Rect2i, spell: int, z: Dictionary) -> void:
	var gap: int = z.line + 1
	var y: int = rect.position.y + gap
	var x0 := rect.position.x
	var x1 := rect.end.x - 1
	_raster(img, [PackedVector2Array([Vector2(x0, y), Vector2(x1, y)])], z.line)
	var step: int = z.line * 2 + 1
	var tick: int = z.dot
	var x: int = x0 + z.line
	for i in spell:
		var long := (i + 1) % 5 == 0
		_raster(img, [PackedVector2Array([Vector2(x, y), Vector2(x, y + (tick + z.line if long else tick))])], z.line)
		x += step


static func _tally_height(z: Dictionary) -> int:
	return z.line + 1 + z.dot + z.line * 2 + 2


static func _tally_width(spell: int, z: Dictionary) -> int:
	return z.line * 2 + spell * (z.line * 2 + 1)


## A vowel's mark beside the stroke from `a` to `b` (pixels), on `side` (+1 after the
## stroke, -1 before it): {dots, d} or {lines, w}. Placed on a whole pixel, with whole-pixel
## sizes from `z` (sizes()), so every dot / dash of a kind is the same.
func _vowel(v: String, a: Vector2, b: Vector2, side: float, px: float, z: Dictionary, avoid := []) -> Dictionary:
	var spec: Array = vowels[v]
	var heavy: bool = spec.size() > 2 and spec[2]
	var t: float = [0.15, 0.5, 0.85][clampi(spec[0], 0, 2)]
	var d := (b - a).normalized() if a.distance_to(b) > 0.01 else Vector2.DOWN
	var nrm := Vector2(-d.y, d.x) * side
	var at := (a.lerp(b, t) + nrm * px * vowel_offset).round()
	var s := roundf(px * mark_size * 0.5)
	# Keep clear of every stroke: step outward until there's a gap of two pixels.
	var reach: float = maxf(s, maxf(px * dash_length * 0.5, z.heavy_dot * 0.5))
	var clear: float = reach + z.line + 2.0
	for i in 8:
		var near := INF
		for l in avoid:
			for k in l.size() - 1:
				near = minf(near, at.distance_to(Geometry2D.get_closest_point_to_segment(at, l[k], l[k + 1])))
		if near >= clear:
			break
		at = (at + nrm * 2.0).round()
	match spec[1]:
		"dash":
			var half := (nrm * px * dash_length * 0.5).round()
			return {lines = [PackedVector2Array([at - half, at + half])], w = z.bold if heavy else z.line}
		"v": return {lines = [PackedVector2Array([at + Vector2(-s, -s), at, at + Vector2(s, -s)])], w = z.line}
		"^": return {lines = [PackedVector2Array([at + Vector2(-s, s), at, at + Vector2(s, s)])], w = z.line}
		"<": return {lines = [PackedVector2Array([at + Vector2(s, -s), at, at + Vector2(s, s)])], w = z.line}
	return {dots = [at], d = z.heavy_dot if heavy else z.dot}


## Polylines (units; 3 points = a circular arc through them: start, a point on it, end)
## placed at `at`, `k` pixels a unit. With `k` 1 they're already in pixels (and arcs
## already traced): moved only.
static func _moved(lines: Array, at: Vector2, k: float) -> Array:
	var out := []
	for l in lines:
		var pts := PackedVector2Array(l)
		if pts.size() == 3 and k != 1.0:
			pts = _arc(pts[0], pts[1], pts[2], maxi(12, ceili(k * 1.5)))
		var moved := PackedVector2Array()
		for p in pts:
			moved.append(at + p * k)
		out.append(moved)
	return out


## Points along the circle through `a`, `m` and `b`, from `a` to `b` by way of `m` (a
## straight line when they're in a row).
static func _arc(a: Vector2, m: Vector2, b: Vector2, steps: int) -> PackedVector2Array:
	var d := 2.0 * (a.x * (m.y - b.y) + m.x * (b.y - a.y) + b.x * (a.y - m.y))
	if absf(d) < 1e-6:
		return PackedVector2Array([a, b])
	var aa := a.length_squared()
	var mm := m.length_squared()
	var bb := b.length_squared()
	var c := Vector2(aa * (m.y - b.y) + mm * (b.y - a.y) + bb * (a.y - m.y),
		aa * (b.x - m.x) + mm * (a.x - b.x) + bb * (m.x - a.x)) / d
	var r := a.distance_to(c)
	var a0 := (a - c).angle()
	var am := wrapf((m - c).angle() - a0, -PI, PI)
	var ab := wrapf((b - c).angle() - a0, -PI, PI)
	# Sweep from a to b the way that passes m.
	var sweep := ab
	if (am > 0.0) != (ab > 0.0) or absf(am) > absf(ab):
		sweep = ab - TAU * signf(ab) if ab != 0.0 else TAU * signf(am)
	var out := PackedVector2Array()
	for i in steps + 1:
		var t := a0 + sweep * float(i) / steps
		out.append(c + Vector2(cos(t), sin(t)) * r)
	return out


## Draws polylines (pixel coordinates, + `off`) into `img`: each line traced pixel by pixel
## (Bresenham) and stamped with a `w` pixel brush, so every line of a width looks the same
## at any angle. Hard N64 pixels.
static func _raster(img: Image, lines: Array, w: int, off := Vector2.ZERO) -> void:
	var brush := _brush(w)
	for l in lines:
		var pts := PackedVector2Array(l)
		if pts.size() == 1:
			_dot(img, pts[0] + off, w + 2)
			continue
		for k in pts.size() - 1:
			var p0 := Vector2i((pts[k] + off).round())
			var p1 := Vector2i((pts[k + 1] + off).round())
			var dx := absi(p1.x - p0.x)
			var dy := -absi(p1.y - p0.y)
			var sx := 1 if p0.x < p1.x else -1
			var sy := 1 if p0.y < p1.y else -1
			var err := dx + dy
			var q := p0
			while true:
				for o in brush:
					_put(img, q + o)
				if q == p1:
					break
				var e2 := 2 * err
				if e2 >= dy:
					err += dy
					q.x += sx
				if e2 <= dx:
					err += dx
					q.y += sy


## A `d` pixel round dot centred on `c` (its shape is the same wherever it lands).
static func _dot(img: Image, c: Vector2, d: int) -> void:
	var tl := Vector2i((c - Vector2(d, d) * 0.5).round())
	var r := d * 0.5
	for y in d:
		for x in d:
			if Vector2(x + 0.5 - r, y + 0.5 - r).length_squared() <= r * r + 0.3:
				_put(img, tl + Vector2i(x, y))


## Pixel offsets of a `w` wide brush (square, corners off from 3 up: round-ish).
static func _brush(w: int) -> Array:
	var out := []
	var from := -(w - 1) / 2
	for y in range(from, from + w):
		for x in range(from, from + w):
			if w >= 3 and (x == from or x == from + w - 1) and (y == from or y == from + w - 1):
				continue
			out.append(Vector2i(x, y))
	return out


static func _put(img: Image, p: Vector2i) -> void:
	if p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height():
		img.set_pixel(p.x, p.y, Color.WHITE)


# --- Banners -----------------------------------------------------------------------------

const PUNCT := {
	".": [[Vector2(0, -1.75), Vector2(1.25, -1.25), Vector2(1.75, 0), Vector2(1.25, 1.25), Vector2(0, 1.75),
		Vector2(-1.25, 1.25), Vector2(-1.75, 0), Vector2(-1.25, -1.25), Vector2(0, -1.75)]],
	",": [[Vector2(0.5, -1.5), Vector2(-1, 2)]],
	"?": [[Vector2(-1.5, -2), Vector2(0, -3), Vector2(1.5, -2), Vector2(0, 0), Vector2(0, 1)], [Vector2(0, 3)]],
	"!": [[Vector2(0, -3), Vector2(0, 1)], [Vector2(0, 3)]],
	"-": [[Vector2(-2, -0.75), Vector2(2, -0.75)], [Vector2(-2, 0.75), Vector2(2, 0.75)]],
	"--": [[Vector2(-4, 0), Vector2(4, 0)]],
}


## Encoded `items` (GlyphText.encode) drawn into `img` inside `area`: a word's outline per
## line, top to bottom, centred both ways, columns right to left; `px` pixels a stroke.
## Returns {fits}.
func draw(img: Image, items: Array, area: Rect2i, ink: Color, px: float) -> Dictionary:
	var scale := maxi(1, img.get_width() / 64)
	var gap := maxi(1, roundi(word_gap * px / 12.0))
	var pieces := []  # {image, newline}
	for it in items:
		if it.has("line"):
			pieces.append({image = null, newline = true})
		elif it.has("punct"):
			var k := roundf(maxf(1.0, px / 10.0))
			var side := ceili(9 * k)
			var p := Image.create(side, side, false, Image.FORMAT_RGBA8)
			_raster(p, _moved(PUNCT.get(it.punct, []), Vector2(side, side) * 0.5, k), sizes(scale).line)
			var used := p.get_used_rect()
			if used.has_area():
				p = p.get_region(used)  # just the mark, so it sits close
			var join := maxi(2, roundi(px * 0.3))
			if it.punct != "--" and not pieces.is_empty() and pieces[-1].image \
					and pieces[-1].image.get_width() + join + p.get_width() <= area.size.x:
				pieces[-1].image = _beside(pieces[-1].image, p, join)
			else:
				pieces.append({image = p, newline = false})  # a dash: a line of its own
		else:
			pieces.append({image = word_image(it, px, scale, area.size.x), newline = false})
	var cols := [[]]
	var h := 0
	for piece in pieces:
		if piece.newline:
			if not cols[-1].is_empty():
				cols.append([])
				h = 0
			continue
		var ph: int = piece.image.get_height()
		if h + ph > area.size.y and not cols[-1].is_empty():
			cols.append([])
			h = 0
		cols[-1].append(piece.image)
		h += ph + gap
	var widths := []
	var total := 0
	for col in cols:
		var w := 0
		for im in col:
			w = maxi(w, im.get_width())
		widths.append(w)
		total += w + gap
	total -= gap
	var fits := total <= area.size.x
	for col in cols:
		for im in col:
			if im.get_height() > area.size.y:
				fits = false
	var tallest := 0
	for col in cols:
		var ch := -gap
		for im in col:
			ch += im.get_height() + gap
		tallest = maxi(tallest, ch)
	var top: int = area.position.y + maxi(0, (area.size.y - tallest) / 2)  # centred on the cloth
	var x := area.position.x + (area.size.x + total) / 2
	for c in cols.size():
		x -= widths[c]
		var y := top
		for im: Image in cols[c]:
			var ox: int = x + (widths[c] - im.get_width()) / 2
			for py in im.get_height():
				for pxx in im.get_width():
					var at := Vector2i(ox + pxx, y + py)
					var cover := im.get_pixel(pxx, py).a
					if cover > 0.0 and Rect2i(Vector2i.ZERO, img.get_size()).has_point(at):
						var under := img.get_pixel(at.x, at.y)
						var mixed := under.lerp(ink, cover)
						mixed.a = under.a
						img.set_pixel(at.x, at.y, mixed)
			y += im.get_height() + gap
		x -= gap
	return {fits = fits}


## A word (GlyphText item) as joined outlines: one, or one per syllable (split_syllables,
## a small gap between them, centred on each other), its spelling mark under them all.
func word_image(it: Dictionary, px: float, scale: int, max_w := 1 << 20) -> Image:
	var sounds := _sounds(it)
	var whole := outline(sounds, it.spell, px, scale)
	if not split_syllables or it.blocks.size() < 2 or (_strokes_in(sounds) < max_strokes and whole.get_width() <= max_w):
		return whole
	var z := sizes(scale)
	# Syllables (a vowel-less block stays with the one before), then joined back up while
	# the outline stays under max_strokes.
	var syllables := []
	for b in it.blocks:
		var part := PackedStringArray(b.onset)
		if b.vowel != "":
			part.append(b.vowel)
		part.append_array(PackedStringArray(b.coda))
		if b.vowel == "" and not syllables.is_empty():
			syllables[-1].append_array(part)
		else:
			syllables.append(part)
	var chunks := [PackedStringArray()]
	for syl in syllables:
		if not chunks[-1].is_empty() and _strokes_in(chunks[-1]) + _strokes_in(syl) >= max_strokes:
			chunks.append(PackedStringArray())
		chunks[-1].append_array(syl)
	var parts: Array[Image] = []
	for c in chunks:
		parts.append(outline(c, 0, px, scale))
	# Pieces side by side, wrapping onto another line when they'd be wider than max_w.
	var gap := maxi(2, roundi(px * 0.15))
	var lines := [[]]
	var lw := 0
	for p in parts:
		if not lines[-1].is_empty() and lw + gap + p.get_width() > max_w:
			lines.append([])
			lw = 0
		lw += (gap if not lines[-1].is_empty() else 0) + p.get_width()
		lines[-1].append(p)
	var w := 0
	var h := 0
	var line_h := []
	for line in lines:
		var lwid := -gap
		var lh := 0
		for p in line:
			lwid += p.get_width() + gap
			lh = maxi(lh, p.get_height())
		w = maxi(w, lwid)
		line_h.append(lh)
		h += lh + gap
	h -= gap
	var mark_h: int = 0 if it.spell == 0 else _tally_height(z)
	if it.spell > 0:
		w = maxi(w, _tally_width(it.spell, z) + 2)
	var img := Image.create(w, h + mark_h, false, Image.FORMAT_RGBA8)
	var y := 0
	for i in lines.size():
		var x := 0
		for p in lines[i]:
			img.blend_rect(p, Rect2i(Vector2i.ZERO, p.get_size()), Vector2i(x, y + (line_h[i] - p.get_height()) / 2))
			x += p.get_width() + gap
		y += line_h[i] + gap
	if it.spell > 0:
		_tally(img, Rect2i(1, h, w - 2, mark_h), it.spell, z)
	return img


func _strokes_in(sounds: PackedStringArray) -> int:
	var n := 0
	for x in sounds:
		if not vowels.has(x):
			n += 1
	return n


static func _sounds(it: Dictionary) -> PackedStringArray:
	var s := PackedStringArray()
	for b in it.blocks:
		s.append_array(PackedStringArray(b.onset))
		if b.vowel != "":
			s.append(b.vowel)
		s.append_array(PackedStringArray(b.coda))
	return s


## `b` placed `join` pixels after `a` (bottoms aligned).
static func _beside(a: Image, b: Image, join := 1) -> Image:
	var out := Image.create(a.get_width() + b.get_width() + join, maxi(a.get_height(), b.get_height()), false, Image.FORMAT_RGBA8)
	out.blit_rect(a, Rect2i(Vector2i.ZERO, a.get_size()), Vector2i(0, out.get_height() - a.get_height()))
	out.blit_rect(b, Rect2i(Vector2i.ZERO, b.get_size()), Vector2i(a.get_width() + join, out.get_height() - b.get_height()))
	# (blit keeps each part's coverage)
	return out


# --- The first draft --------------------------------------------------------------------

## The Pitman-style draft, on a regular grid of angles: straight strokes for stops (p \ at
## 60°, t |, ch / at 60°, k —), the same directions curved (circular arcs) for hissing
## sounds (f, th, sh), a small circle for s, flat arcs for m / n, an upward arc for l, an
## upstroke at 30° for r, hooked downstrokes for w / y, h a shallow 30° downstroke.
static func pitman_draft() -> StrokeAlphabet:
	var a := StrokeAlphabet.new()
	var line := func(x: float, y: float) -> PackedVector2Array: return PackedVector2Array([Vector2.ZERO, Vector2(x, y)])
	# An arc from the pen to (x, y), bowed `sag` stroke lengths to the left of its chord
	# (negative: to the right).
	var bow := func(x: float, y: float, sag: float, from := Vector2.ZERO) -> PackedVector2Array:
		var e := Vector2(x, y)
		var chord := e - from
		var left := Vector2(chord.y, -chord.x).normalized()
		return PackedVector2Array([from, (from + e) * 0.5 + left * sag, e])
	var c60 := cos(PI / 3.0)
	var s60 := sin(PI / 3.0)
	var r := 0.2  # s circle radius (big enough to stay a circle in pixels)
	var hook := 0.2  # w / y hook radius
	a.strokes = {
		"P": [line.call(c60, s60)],
		"T": [line.call(0, 1)],
		"CH": [line.call(-c60, s60)],
		"K": [line.call(1, 0)],
		"F": [bow.call(c60, s60, 0.16)],
		"TH": [bow.call(0, 1, 0.18)],
		"SH": [bow.call(-c60, s60, -0.16)],
		"S": [PackedVector2Array([Vector2.ZERO, Vector2(r, -r), Vector2(2 * r, 0)]),
			PackedVector2Array([Vector2(2 * r, 0), Vector2(r, r), Vector2.ZERO])],
		"M": [bow.call(1, 0, -0.18)],
		"N": [bow.call(1, 0, 0.18)],
		"L": [bow.call(c60, -s60, 0.16)],
		"R": [line.call(s60, -c60)],
		"W": [PackedVector2Array([Vector2(2 * hook, 0), Vector2(hook, -hook), Vector2.ZERO]), line.call(0, 0.85)],
		"Y": [PackedVector2Array([Vector2(-2 * hook, 0), Vector2(-hook, -hook), Vector2.ZERO]), line.call(0, 0.85)],
		"HH": [line.call(s60, c60)],  # a shallow downstroke (30°): the one direction left
	}
	a.voiced = {"B": "P", "D": "T", "G": "K", "V": "F", "DH": "TH", "Z": "S", "ZH": "SH", "JH": "CH", "NG": "N"}
	a.vowels = {"AA": [0, "dot", true], "AE": [0, "dot", false], "EY": [1, "dot", true], "EH": [1, "dot", false],
		"IY": [2, "dot", true], "IH": [2, "dot", false], "AO": [0, "dash", true], "OW": [1, "dash", true],
		"AH": [1, "dash", false], "UW": [2, "dash", true], "UH": [2, "dash", false], "ER": [1, "dash", false],
		"AY": [0, "v", false], "AW": [2, "^", false], "OY": [0, "<", false]}
	return a
