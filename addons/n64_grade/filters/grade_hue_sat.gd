@tool
class_name GradeHueSat
extends GradeFilter
## Hue turn, saturation and lightness.

@export_range(-180.0, 180.0, 1.0, "suffix:°") var hue := 0.0
@export_range(0.0, 2.0, 0.01) var saturation := 1.0
## Towards black (-) / white (+).
@export_range(-1.0, 1.0, 0.01) var lightness := 0.0
## Perceptual (OKLab): a hue turn changes only the hue (not how light it looks) and
## saturation scales every hue evenly. Off: the old HSV maths (blues darken, reds and
## blues jump), kept for grades made with it. New filters start on.
@export var perceptual := false


func title() -> String:
	return "Hue / saturation"


func apply(c: Color, _i: int) -> Color:
	if perceptual:
		var lab := GradePalette.oklab(c)
		var ab := Vector2(lab.y, lab.z).rotated(deg_to_rad(hue)) * saturation
		var l := lab.x
		if lightness > 0.0:
			l = lerpf(l, 1.0, lightness)
			ab *= 1.0 - lightness
		elif lightness < 0.0:
			l = lerpf(l, 0.0, -lightness)
			ab *= 1.0 + lightness
		return GradePalette.from_oklab_fit(Vector3(l, ab.x, ab.y))
	var h := fposmod(c.h + hue / 360.0, 1.0)
	var o := Color.from_hsv(h, clampf(c.s * saturation, 0.0, 1.0), c.v)
	if lightness > 0.0:
		o = o.lerp(Color.WHITE, lightness)
	elif lightness < 0.0:
		o = o.lerp(Color.BLACK, -lightness)
	return o
