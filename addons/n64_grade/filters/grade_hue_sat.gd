@tool
class_name GradeHueSat
extends GradeFilter
## Hue turn, saturation and lightness.

@export_range(-180.0, 180.0, 1.0, "suffix:°") var hue := 0.0
@export_range(0.0, 2.0, 0.01) var saturation := 1.0
## Towards black (-) / white (+).
@export_range(-1.0, 1.0, 0.01) var lightness := 0.0


func title() -> String:
	return "Hue / saturation"


func apply(c: Color, _i: int) -> Color:
	var h := fposmod(c.h + hue / 360.0, 1.0)
	var o := Color.from_hsv(h, clampf(c.s * saturation, 0.0, 1.0), c.v)
	if lightness > 0.0:
		o = o.lerp(Color.WHITE, lightness)
	elif lightness < 0.0:
		o = o.lerp(Color.BLACK, -lightness)
	return o
