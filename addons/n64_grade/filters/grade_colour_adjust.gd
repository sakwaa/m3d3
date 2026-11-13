@tool
class_name GradeColourAdjust
extends GradeFilter
## The Paint panel's Colour adjust as a filter (its settings move here from the panel):
## hue / saturation / brightness / contrast / temperature / tint / midtones, colorize, start
## from grey. Same maths as the paint shader's colour_adjust().

@export var adjust: ColourAdjust = ColourAdjust.new()


func title() -> String:
	return "Colour adjust"


func apply(c: Color, _i: int) -> Color:
	var a := adjust
	if a == null:
		return c
	var s := Vector3(c.r, c.g, c.b)
	var l := s.dot(LUMA)
	if a.from_grey:
		var lo := Vector3(a.shadow.r, a.shadow.g, a.shadow.b)
		var hi := Vector3(a.colorize.r, a.colorize.g, a.colorize.b)
		s = Vector3(l, l, l).lerp(lo.lerp(hi, l), a.colorize_amount)
	elif a.colorize_amount > 0.0:
		var col := Vector3(a.colorize.r, a.colorize.g, a.colorize.b)
		s = s.lerp(col * (l / maxf(col.dot(LUMA), 0.05)), a.colorize_amount)
	if a.hue != 0.0:
		var y := s.dot(LUMA)
		var i := 0.596 * s.x - 0.274 * s.y - 0.322 * s.z
		var q := 0.211 * s.x - 0.523 * s.y + 0.312 * s.z
		var h := deg_to_rad(a.hue)
		var i2 := i * cos(h) - q * sin(h)
		var q2 := i * sin(h) + q * cos(h)
		s = Vector3(y + 0.956 * i2 + 0.621 * q2, y - 0.272 * i2 - 0.647 * q2, y - 1.106 * i2 + 1.703 * q2)
	l = s.dot(LUMA)
	s = Vector3(l, l, l).lerp(s, a.saturation)
	s *= Vector3(1.0 + a.temperature * 0.12, 1.0 - a.tint * 0.1, 1.0 - a.temperature * 0.12)
	s = (s - Vector3(0.5, 0.5, 0.5)) * a.contrast + Vector3(0.5, 0.5, 0.5)
	s *= a.brightness
	var g := 1.0 / maxf(a.gamma, 0.05)
	return Color(pow(maxf(s.x, 0.0), g), pow(maxf(s.y, 0.0), g), pow(maxf(s.z, 0.0), g))
