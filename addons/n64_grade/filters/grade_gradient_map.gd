@tool
class_name GradeGradientMap
extends GradeFilter
## Gradient map: each pixel's lightness picks a colour from the gradient (left = darks,
## right = lights). On Soft light it lays temperature bands over the values without
## changing them much; on Normal / Colour it recolours outright.

@export var gradient: Gradient = _default_gradient()


func _init() -> void:
	blend = Blend.SOFT_LIGHT


func title() -> String:
	return "Gradient map"


func apply(c: Color, _i: int) -> Color:
	return gradient.sample(luma(c)) if gradient else c


## A gradient read from a picture (a reference: another game's screenshot, a painting):
## its pixels sorted into `stops` bands of lightness, each band's average colour (OKLab)
## placed at the band's lightness. On Colour / Soft light, textures take the picture's
## colour at each value: its darks' hue, its mids', its lights'.
static func from_image(img: Image, stops := 7) -> Gradient:
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
				px.append([luma(c), c])
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
