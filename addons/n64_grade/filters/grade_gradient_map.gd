@tool
class_name GradeGradientMap
extends GradeFilter
## Gradient map: each pixel's lightness picks a colour from the gradient (left = darks,
## right = lights). On Soft light it lays temperature bands over the values without
## changing them much; on Normal / Colour it recolours outright.

@export var gradient: Gradient = _default_gradient()
## Perceptual (OKLab): picks by perceived lightness (even to the eye) and blends between
## stops in OKLab (no muddy grey between blue and orange). Off: the old weighted-RGB value
## and RGB blending, kept for grades made with it. New filters start on.
@export var perceptual := false
## Spread the gradient over each texture's own lightness range (its 2-98%), so a texture
## that only spans a few values still meets every stop (a stepped ramp's bands). Textures
## only (baked light is unaffected).
@export var stretch := false

var _lo := 0.0
var _hi := 1.0


func _init() -> void:
	blend = Blend.SOFT_LIGHT


func title() -> String:
	return "Gradient map"


func apply(c: Color, _i: int) -> Color:
	if gradient == null:
		return c
	var t := ok_l(c) if perceptual else luma(c)
	if _hi > _lo + 0.001 and (_lo > 0.0 or _hi < 1.0):
		t = clampf((t - _lo) / (_hi - _lo), 0.0, 1.0)
	if not perceptual:
		return gradient.sample(t)
	return sample_oklab(gradient, t)


func needs_image() -> bool:
	return stretch


## Stretch: a copy knowing the texture's lightness range.
func for_image(img: Image) -> GradeFilter:
	if not stretch or img == null:
		return self
	var f := GradeGradientMap.new()
	f.gradient = gradient
	f.perceptual = perceptual
	f.stretch = stretch
	f.blend = blend
	f.opacity = opacity
	f.enabled = enabled
	var src := img
	if src.is_compressed():
		src = src.duplicate()
		src.decompress()
	var vals := PackedFloat32Array()
	var step := maxi(1, int(sqrt(float(src.get_width() * src.get_height()) / 4096.0)))
	for y in range(0, src.get_height(), step):
		for x in range(0, src.get_width(), step):
			var c := src.get_pixel(x, y)
			if c.a > 0.5:
				vals.append(ok_l(c) if perceptual else luma(c))
	if vals.size() > 8:
		vals.sort()
		f._lo = vals[int(vals.size() * 0.02)]
		f._hi = vals[int(vals.size() * 0.98)]
	return f


## `g` at `t`, blending between stops in OKLab (thread-safe: reads only). Honours Constant.
static func sample_oklab(g: Gradient, t: float) -> Color:
	var n := g.get_point_count()
	if n == 0:
		return Color.BLACK
	var off := g.offsets
	var col := g.colors
	# (Gradient keeps its points sorted.)
	if t <= off[0]:
		return col[0]
	if t >= off[n - 1]:
		return col[n - 1]
	var i := 0
	while i < n - 2 and t > off[i + 1]:
		i += 1
	if g.interpolation_mode == Gradient.GRADIENT_INTERPOLATE_CONSTANT:
		return col[i]
	var k := (t - off[i]) / maxf(off[i + 1] - off[i], 0.00001)
	var a := GradePalette.oklab(col[i])
	var b := GradePalette.oklab(col[i + 1])
	return GradePalette.from_oklab(a.lerp(b, k), lerpf(col[i].a, col[i + 1].a, k))


## A colour ramp (Acerola's harmonious palettes, in OKLab): `steps` colours evenly spaced
## in perceived lightness from `l_dark` to `l_light`, all of `base`'s hue, the darks turned
## `temperature` degrees towards blue and the lights towards yellow (cool shadows, warm
## lights; negative: the other way), colourfulness from `chroma_dark` to `chroma_light`
## (a little more in the mids). `stepped`: flat bands (value groups); else smooth.
static func ramp(base: Color, steps: int, temperature: float, chroma_dark: float, chroma_light: float,
		l_dark := 0.2, l_light := 0.94, stepped := true) -> Gradient:
	var lab := GradePalette.oklab(base)
	var h := atan2(lab.z, lab.y)
	var g := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	steps = maxi(steps, 2)
	for i in steps:
		var t := float(i) / (steps - 1)
		var l := lerpf(l_dark, l_light, t)
		var c := lerpf(chroma_dark, chroma_light, t) * (1.0 + 0.25 * sin(PI * t))
		# Darks towards blue (OKLab hue ~265°), lights towards yellow (~100°).
		var amount := deg_to_rad(absf(temperature)) * absf(t - 0.5) * 2.0
		var cool := deg_to_rad(265.0)
		var warm := deg_to_rad(100.0)
		var hh := _turn_towards(h, (cool if temperature >= 0.0 else warm) if t < 0.5 else (warm if temperature >= 0.0 else cool), amount)
		colors.append(GradePalette.from_oklab_fit(Vector3(l, c * cos(hh), c * sin(hh))))
		offsets.append(float(i) / steps if stepped else t)
	g.offsets = offsets
	g.colors = colors
	g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT if stepped else Gradient.GRADIENT_INTERPOLATE_LINEAR
	return g


## Angle `a` turned towards `target` by up to `amount` (radians, the short way).
static func _turn_towards(a: float, target: float, amount: float) -> float:
	var d := wrapf(target - a, -PI, PI)
	return a + clampf(d, -amount, amount)


## A gradient read from a picture (a reference: another game's screenshot, a painting):
## its pixels sorted into `stops` bands of lightness, each band's average colour (OKLab)
## placed at the band's lightness. On Colour / Soft light, textures take the picture's
## colour at each value: its darks' hue, its mids', its lights'.
static func from_image(img: Image, stops := 7, perceptual := false) -> Gradient:
	if img == null or img.is_empty():
		return null
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var step := maxi(1, int(sqrt(float(img.get_width() * img.get_height()) / 30000.0)))
	var px := []
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var c := img.get_pixel(x, y)
			if c.a > 0.5:
				px.append([ok_l(c) if perceptual else luma(c), c])
	if px.size() < 50:
		return null
	px.sort_custom(func(a, b): return a[0] < b[0])
	# Bands of equal pixel count (each value range as the picture uses it), 2% trimmed.
	var lo := int(px.size() * 0.02)
	var hi := int(px.size() * 0.98)
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for b in stops:
		var a := lo + (hi - lo) * b / stops
		var e := lo + (hi - lo) * (b + 1) / stops
		if e <= a:
			continue
		var lab := Vector3.ZERO
		var l := 0.0
		for i in range(a, e):
			lab += GradePalette.oklab(px[i][1])
			l += px[i][0]
		lab /= float(e - a)
		l /= float(e - a)
		if not offsets.is_empty() and l <= offsets[-1] + 0.005:
			continue
		offsets.append(l)
		colors.append(GradePalette.from_oklab(lab))
	if offsets.size() < 2:
		return null
	var g := Gradient.new()
	g.offsets = offsets
	g.colors = colors
	return g


static func _default_gradient() -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	g.colors = PackedColorArray([Color(0.16, 0.13, 0.32), Color(0.62, 0.46, 0.38), Color(1.0, 0.9, 0.62)])
	return g
