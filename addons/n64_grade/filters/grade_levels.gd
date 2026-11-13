@tool
class_name GradeLevels
extends GradeFilter
## Levels: input black / white points, midtone gamma, output range (value shaping).

@export_range(0.0, 1.0, 0.01) var in_black := 0.0
@export_range(0.0, 1.0, 0.01) var in_white := 1.0
## Midtones: > 1 lighter, < 1 darker.
@export_range(0.2, 5.0, 0.01) var gamma := 1.0
@export_range(0.0, 1.0, 0.01) var out_black := 0.0
@export_range(0.0, 1.0, 0.01) var out_white := 1.0


func title() -> String:
	return "Levels"


func apply(c: Color, _i: int) -> Color:
	return Color(_ch(c.r), _ch(c.g), _ch(c.b))


func _ch(v: float) -> float:
	var t := clampf((v - in_black) / maxf(in_white - in_black, 0.001), 0.0, 1.0)
	t = pow(t, 1.0 / maxf(gamma, 0.01))
	return lerpf(out_black, out_white, t)
