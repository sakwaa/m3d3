@tool
class_name GradeBalance
extends GradeFilter
## Colour balance: push the shadows, midtones and highlights towards a colour each (grey =
## no change). E.g. cool shadows, warm highlights.

@export var shadows := Color(0.5, 0.5, 0.5)
@export var midtones := Color(0.5, 0.5, 0.5)
@export var highlights := Color(0.5, 0.5, 0.5)
## How far the colours push.
@export_range(0.0, 1.0, 0.01) var strength := 0.4


func title() -> String:
	return "Colour balance"


func apply(c: Color, _i: int) -> Color:
	var l := luma(c)
	var ws := clampf(1.0 - l * 2.0, 0.0, 1.0)
	var wh := clampf(l * 2.0 - 1.0, 0.0, 1.0)
	var wm := 1.0 - ws - wh
	var off := Vector3.ZERO
	for pair in [[shadows, ws], [midtones, wm], [highlights, wh]]:
		var k: Color = pair[0]
		off += Vector3(k.r - 0.5, k.g - 0.5, k.b - 0.5) * pair[1]
	off *= strength
	var o := Color(c.r + off.x, c.g + off.y, c.b + off.z)
	# (keep the lightness: balance moves colour, not value)
	return GradeFilter._set_lum(o, l)
