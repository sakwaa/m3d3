@tool
class_name GradePalette
extends GradeFilter
## Palette: the texture's colours redrawn with a palette's (a Lospec palette, or any .hex /
## .gpl / .png), the way a pixel artist would rather than colour by colour:
##  - Ramp (default): per texture, the palette colours whose hue is the texture's, dark to
##    light; each texel takes the one at its lightness. Grass can only become the palette's
##    greens, never a stray red.
##  - Fit: the texture reduced to a few main colours, each matched to the palette (hue
##    first); every texel takes its main colour's match, so variation stays coherent.
##  - Nearest: each colour on its own to the closest palette colour (scatters on photos).
##  - Keep lightness: nearest by hue / colour, the texel keeps its own lightness.
##  - Hue shift: the whole texture turned round the colour wheel to one palette colour's
##    hue (the picked one; else the palette colour nearest the texture's hue). Lightness,
##    detail and its own small hue variations stay; Chroma match moves its colourfulness
##    towards the palette colour's.
## Picked colours (click the swatch): only those are used (Ramp: they are the ramp).
## Exact colours off (default): the palette gives hue and colour, each texel keeps its own
## lightness (between ramp colours it blends): clean palette colours without flattening the
## texture into one or two flat colours. On: only the palette's exact colours (pixel art).
## Matching is in OKLab / OKLCh (by eye); hue counts most.

enum Match { NEAREST, KEEP_LIGHTNESS, RAMP, FIT, HUE_SHIFT }

@export_file("*.hex", "*.gpl", "*.png") var palette_path := ""
@export var match_mode := Match.RAMP
## Ramp: how far from the texture's hue a palette colour may be (degrees); widens by itself
## when too few colours qualify.
@export_range(10.0, 120.0, 1.0, "suffix:°") var hue_range := 35.0
## Ramp: the texture's darkest..lightest mapped onto the ramp's (off: each texel keeps its
## own lightness as closely as the ramp allows: values set in grey survive).
@export var stretch := false
## Fit: how many main colours.
@export_range(2, 12) var colours := 4
## Hue shift: 0 = the texture keeps its colourfulness, 1 = takes the palette colour's.
@export_range(0.0, 1.0, 0.01) var chroma_match := 0.3
## Hue shift: 1 = the texture's own hue variation kept, 0 = every texel exactly the
## target's hue (multicoloured shingles, mottled grass become one hue).
@export_range(0.0, 1.0, 0.01) var hue_variation := 1.0
## Only the palette's exact colours (off: palette hue / colour, the texel's own lightness).
@export var exact_colours := false
## Mixes neighbouring palette colours in a fixed 4x4 pattern where a texel falls between
## (exact colours).
@export_range(0.0, 1.0, 0.01) var dither := 0.0
## Palette colours (indices) the texture may use; empty = chosen automatically.
@export var picked := PackedInt32Array()

const BAYER := [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

var _cols := PackedColorArray()
var _labs: Array[Vector3] = []
var _loaded := ""
# Per texture (for_image copies): the ramp, dark to light ([L, Color]); or the fit.
var _ramp: Array = []
var _fit_centres: Array[Vector3] = []
var _fit_cols := PackedColorArray()
var _lrange := Vector2(0.0, 1.0)
# Hue shift (per texture): the texture's mean hue, the target's (radians), chroma scale.
var _mean_h := 0.0
var _target_h := 0.0
var _cscale := 1.0
var _shift_ready := false


func title() -> String:
	return "Palette" + ((": " + palette_path.get_file().get_basename()) if palette_path != "" else "")


func _validate_property(p: Dictionary) -> void:
	super(p)
	if (p.name == "hue_range" or p.name == "stretch") and match_mode != Match.RAMP:
		p.usage = PROPERTY_USAGE_STORAGE
	elif p.name == "colours" and match_mode != Match.FIT:
		p.usage = PROPERTY_USAGE_STORAGE
	elif p.name == "dither" and (not exact_colours or match_mode == Match.HUE_SHIFT):
		p.usage = PROPERTY_USAGE_STORAGE
	elif p.name == "exact_colours" and match_mode == Match.HUE_SHIFT:
		p.usage = PROPERTY_USAGE_STORAGE
	elif (p.name == "chroma_match" or p.name == "hue_variation") and match_mode != Match.HUE_SHIFT:
		p.usage = PROPERTY_USAGE_STORAGE


func _set(prop: StringName, _v: Variant) -> bool:
	if prop == &"match_mode" or prop == &"exact_colours":
		notify_property_list_changed.call_deferred()
	return false


func prepare() -> void:
	if palette_path != _loaded:
		_loaded = palette_path
		_cols = GradePalettes.load_colours(palette_path)
		_labs.clear()
		for c in _cols:
			_labs.append(oklab(c))


func per_pixel() -> bool:
	return dither > 0.0 and exact_colours and match_mode != Match.HUE_SHIFT


func needs_image() -> bool:
	return match_mode == Match.RAMP or match_mode == Match.FIT or match_mode == Match.HUE_SHIFT


## The colours in use: the picked ones, else all. [[index, lab]]
func _pool() -> Array:
	var out := []
	for i in _cols.size():
		if picked.is_empty() or i in picked:
			out.append([i, _labs[i]])
	return out


func for_image(img: Image) -> GradeFilter:
	var f := GradePalette.new()
	# (plain assignments: set() would go through _set and its deferred refresh)
	f.palette_path = palette_path
	f.match_mode = match_mode
	f.hue_range = hue_range
	f.stretch = stretch
	f.colours = colours
	f.dither = dither
	f.exact_colours = exact_colours
	f.picked = picked
	f.chroma_match = chroma_match
	f.hue_variation = hue_variation
	f.enabled = enabled
	f.opacity = opacity
	f.blend = blend
	f._cols = _cols
	f._labs = _labs
	f._loaded = _loaded
	if _cols.is_empty():
		return f
	var samples := _samples(img)
	if samples.is_empty():
		return f
	if match_mode == Match.HUE_SHIFT:
		_make_shift(f, samples)
	elif match_mode == Match.RAMP:
		f._ramp = _make_ramp(samples)
		var ls := samples.map(func(v): return v.x)
		ls.sort()
		f._lrange = Vector2(ls[ls.size() / 20], ls[ls.size() * 19 / 20])
	else:
		_make_fit(f, samples)
	return f


## OKLab of the texture's opaque texels (top mip, at most ~4096).
func _samples(img: Image) -> Array:
	var out := []
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(1, int(sqrt(float(w * h) / 4096.0)))
	for y in range(0, h, step):
		for x in range(0, w, step):
			var c := img.get_pixel(x, y)
			if c.a > 0.5:
				out.append(oklab(c))
	return out


## Palette colours of the texture's hue, dark to light, one per lightness step.
func _make_ramp(samples: Array) -> Array:
	var pool := _pool()
	var cands := []
	if not picked.is_empty():
		cands = pool
	else:
		var mean := Vector3.ZERO
		for sm in samples:
			mean += sm
		mean /= samples.size()
		# The palette colours nearest the texture's colour by hue and colourfulness (not
		# lightness: the ramp should span light and dark), best first.
		var scored := []
		for e in pool:
			var q: Vector3 = e[1]
			scored.append([_perceptual(Vector3(0.0, mean.y, mean.z), Vector3(0.0, q.y, q.z)), e])
		scored.sort_custom(func(x, y): return x[0] < y[0])
		var limit: float = scored[0][0] * 4.0 + 0.0015 * (hue_range / 35.0)
		for sc in scored:
			if cands.size() >= 8 or (sc[0] > limit and cands.size() >= 3):
				break
			cands.append(sc[1])
	cands.sort_custom(func(x, y): return x[1].x < y[1].x)
	# One colour per lightness step (close lightness = the same rung).
	var ramp := []
	for e in cands:
		if not ramp.is_empty() and absf(e[1].x - ramp[-1][0]) < 0.035:
			continue
		ramp.append([e[1].x, _cols[e[0]]])
	return ramp


## Hue shift: the turn from the texture's average hue to the target colour's, and how much
## to scale colourfulness (chroma_match of the way to the target's).
func _make_shift(f: GradePalette, samples: Array) -> void:
	var a := 0.0
	var b := 0.0
	var chroma := 0.0
	for sm in samples:
		a += sm.y
		b += sm.z
		chroma += Vector2(sm.y, sm.z).length()
	chroma /= samples.size()
	var hue := atan2(b, a)
	var target := _shift_target(hue, chroma)
	if target.is_empty():
		return
	var tq: Vector3 = target[1]
	f._mean_h = hue
	f._target_h = atan2(tq.z, tq.y)
	var tc := Vector2(tq.y, tq.z).length()
	f._cscale = lerpf(1.0, tc / maxf(chroma, 0.005), chroma_match)
	f._shift_ready = true


## The colour to shift to: among the picked (or all), the nearest to `hue` by hue alone
## (greys left out unless the texture is grey itself, or nothing else is there).
func _shift_target(hue: float, chroma: float) -> Array:
	var best := []
	var bd := INF
	for e in _pool():
		var q: Vector3 = e[1]
		var qc := Vector2(q.y, q.z).length()
		var d: float
		if chroma < 0.02:
			d = qc
		elif qc < 0.03 and picked.size() != 1:
			continue
		else:
			d = absf(angle_difference(hue, atan2(q.z, q.y)))
		if d < bd:
			bd = d
			best = e
	if best.is_empty() and not _pool().is_empty():
		best = _pool()[0]
	return best


## Main colours of the texture (k-means in OKLab), each matched to the palette by hue first.
func _make_fit(f: GradePalette, samples: Array) -> void:
	var k := mini(colours, samples.size())
	var sorted := samples.duplicate()
	sorted.sort_custom(func(x, y): return x.x < y.x)
	var centres: Array[Vector3] = []
	for i in k:
		centres.append(sorted[int((i + 0.5) / k * sorted.size())])
	for _it in 8:
		var sums: Array[Vector3] = []
		var counts := PackedInt32Array()
		sums.resize(k)
		counts.resize(k)
		for i in k:
			sums[i] = Vector3.ZERO
		for s in samples:
			var bi := _nearest_centre(centres, s)
			sums[bi] += s
			counts[bi] += 1
		for i in k:
			if counts[i] > 0:
				centres[i] = sums[i] / counts[i]
	var pool := _pool()
	var cols := PackedColorArray()
	for c in centres:
		var best := 0
		var bd := INF
		for e in pool:
			var d := _perceptual(c, e[1])
			if d < bd:
				bd = d
				best = e[0]
		cols.append(_cols[best])
	f._fit_centres = centres
	f._fit_cols = cols


static func _nearest_centre(centres: Array[Vector3], s: Vector3) -> int:
	var bi := 0
	var bd := INF
	for i in centres.size():
		var d := s.distance_squared_to(centres[i])
		if d < bd:
			bd = d
			bi = i
	return bi


## Colour distance weighting hue most, then colourfulness, then lightness (OKLCh).
static func _perceptual(p: Vector3, q: Vector3) -> float:
	var c1 := Vector2(p.y, p.z).length()
	var c2 := Vector2(q.y, q.z).length()
	var dh2 := maxf((p.y - q.y) ** 2 + (p.z - q.z) ** 2 - (c1 - c2) ** 2, 0.0)
	return 0.6 * (p.x - q.x) ** 2 + (c1 - c2) ** 2 + 4.0 * dh2


func _threshold(xy: Vector2i) -> float:
	if dither <= 0.0:
		return 0.5
	var t: float = (BAYER[(xy.y & 3) * 4 + (xy.x & 3)] + 0.5) / 16.0
	return lerpf(0.5, t, dither)


func apply_xy(c: Color, _i: int, xy: Vector2i) -> Color:
	if _cols.is_empty():
		return c
	var lab := oklab(c)
	if match_mode == Match.HUE_SHIFT:
		var mean_h := _mean_h
		var target_h := _target_h
		var cs := _cscale
		if not _shift_ready:
			# (no texture analysed, e.g. vertex colours: this colour's own nearest target)
			var h := atan2(lab.z, lab.y)
			var ch := Vector2(lab.y, lab.z).length()
			var t := _shift_target(h, ch)
			if t.is_empty() or ch < 0.002:
				return c
			mean_h = h
			target_h = atan2(t[1].z, t[1].y)
			cs = lerpf(1.0, Vector2(t[1].y, t[1].z).length() / maxf(ch, 0.005), chroma_match)
		var own_c := Vector2(lab.y, lab.z).length()
		var h2 := target_h + angle_difference(mean_h, atan2(lab.z, lab.y)) * hue_variation
		var ab := Vector2(cos(h2), sin(h2)) * own_c * cs
		return from_oklab(Vector3(lab.x, ab.x, ab.y), c.a)
	if match_mode == Match.RAMP and not _ramp.is_empty():
		var l := lab.x
		if stretch and _lrange.y > _lrange.x:
			l = lerpf(_ramp[0][0], _ramp[-1][0], clampf((l - _lrange.x) / (_lrange.y - _lrange.x), 0.0, 1.0))
		var lo: Array = _ramp[0]
		var hi: Array = _ramp[0]
		var t := 0.0
		if l >= _ramp[-1][0]:
			lo = _ramp[-1]
			hi = _ramp[-1]
		elif l > _ramp[0][0]:
			for i in range(1, _ramp.size()):
				if l <= _ramp[i][0]:
					lo = _ramp[i - 1]
					hi = _ramp[i]
					t = (l - lo[0]) / maxf(hi[0] - lo[0], 0.0001)
					break
		if exact_colours:
			return hi[1] if t > _threshold(xy) else lo[1]
		# Palette hue / colour (blended between the two rungs), the texel's own lightness.
		var a := oklab(lo[1]).lerp(oklab(hi[1]), t)
		return from_oklab(Vector3(l, a.y, a.z), c.a)
	if match_mode == Match.FIT and not _fit_centres.is_empty():
		var bi := 0
		var b2 := 0
		var d1 := INF
		var d2 := INF
		for i in _fit_centres.size():
			var d := lab.distance_squared_to(_fit_centres[i])
			if d < d1:
				d2 = d1
				b2 = bi
				d1 = d
				bi = i
			elif d < d2:
				d2 = d
				b2 = i
		if exact_colours and dither > 0.0 and d2 < INF:
			# (between two main colours: the pattern decides, weighted by closeness)
			var t := sqrt(d1) / maxf(sqrt(d1) + sqrt(d2), 0.0001)
			return _fit_cols[b2] if t > _threshold(xy) else _fit_cols[bi]
		if exact_colours:
			return _fit_cols[bi]
		var q := oklab(_fit_cols[bi])
		return from_oklab(Vector3(lab.x, q.y, q.z), c.a)
	# Nearest / keep lightness (also Ramp / Fit where no texture was analysed: vertex colours).
	var best := 0
	var bd := INF
	for e in _pool():
		var d: float = lab.distance_squared_to(e[1]) if match_mode == Match.NEAREST else _perceptual(lab, e[1])
		if d < bd:
			bd = d
			best = e[0]
	var out := _cols[best]
	if match_mode == Match.KEEP_LIGHTNESS:
		out = GradeFilter._set_lum(out, luma(c))
	return out


## Display colour of an OKLab value (clamped into range).
static func from_oklab(v: Vector3, alpha := 1.0) -> Color:
	return oklab_linear(v, alpha).clamp().linear_to_srgb()


## Linear RGB of an OKLab value (unclamped: outside 0..1 = outside the display's gamut).
static func oklab_linear(v: Vector3, alpha := 1.0) -> Color:
	var l_ := v.x + 0.3963377774 * v.y + 0.2158037573 * v.z
	var m_ := v.x - 0.1055613458 * v.y - 0.0638541728 * v.z
	var s_ := v.x - 0.0894841775 * v.y - 1.2914855480 * v.z
	var l := l_ * l_ * l_
	var m := m_ * m_ * m_
	var s := s_ * s_ * s_
	return Color(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s, alpha)


## Display colour of an OKLab value, brought into gamut by lowering its colourfulness (hue
## and lightness kept), not by clipping channels (which shifts hue: blues to purple...).
static func from_oklab_fit(v: Vector3, alpha := 1.0) -> Color:
	var lin := oklab_linear(v, alpha)
	if _in_gamut(lin):
		return lin.linear_to_srgb()
	var lo := 0.0
	var hi := 1.0
	for i in 12:
		var k := (lo + hi) * 0.5
		if _in_gamut(oklab_linear(Vector3(v.x, v.y * k, v.z * k), alpha)):
			lo = k
		else:
			hi = k
	return from_oklab(Vector3(v.x, v.y * lo, v.z * lo), alpha)


static func _in_gamut(c: Color) -> bool:
	const E := 0.0005
	return c.r >= -E and c.g >= -E and c.b >= -E and c.r <= 1.0 + E and c.g <= 1.0 + E and c.b <= 1.0 + E


## OKLab of a display colour.
static func oklab(c: Color) -> Vector3:
	var l := c.srgb_to_linear()
	var a := 0.4122214708 * l.r + 0.5363325363 * l.g + 0.0514459929 * l.b
	var b := 0.2119034982 * l.r + 0.6806995451 * l.g + 0.1073969566 * l.b
	var s := 0.0883024619 * l.r + 0.2817188376 * l.g + 0.6299787005 * l.b
	a = pow(maxf(a, 0.0), 1.0 / 3.0)
	b = pow(maxf(b, 0.0), 1.0 / 3.0)
	s = pow(maxf(s, 0.0), 1.0 / 3.0)
	return Vector3(0.2104542553 * a + 0.7936177850 * b - 0.0040720468 * s,
		1.9779984951 * a - 2.4285922050 * b + 0.4505937099 * s,
		0.0259040371 * a + 0.7827717662 * b - 0.8086757660 * s)
