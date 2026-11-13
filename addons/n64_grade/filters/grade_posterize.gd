@tool
class_name GradePosterize
extends GradeFilter
## Fewer levels per channel (flat, banded colour).

@export_range(2, 32) var levels := 6


func title() -> String:
	return "Posterize"


func apply(c: Color, _i: int) -> Color:
	var n := float(levels - 1)
	return Color(roundf(c.r * n) / n, roundf(c.g * n) / n, roundf(c.b * n) / n)
