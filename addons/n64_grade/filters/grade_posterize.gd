@tool
class_name GradePosterize
extends GradeFilter
## Fewer levels per channel (flat, banded colour).

@export_range(2, 32) var levels := 6
## Perceptual: steps the lightness only (OKLab L, even to the eye), keeping each colour's
## hue and colourfulness (value groups in colour). Off: each RGB channel stepped on its own
## (hues shift between steps). New filters start on.
@export var perceptual := false


func title() -> String:
	return "Posterize"


func apply(c: Color, _i: int) -> Color:
	var n := float(levels - 1)
	if perceptual:
		var lab := GradePalette.oklab(c)
		var l := roundf(lab.x * n) / n
		var k := l / maxf(lab.x, 0.001) if lab.x > 0.001 else 0.0
		return GradePalette.from_oklab_fit(Vector3(l, lab.y * minf(k, 1.5), lab.z * minf(k, 1.5)))
	return Color(roundf(c.r * n) / n, roundf(c.g * n) / n, roundf(c.b * n) / n)
