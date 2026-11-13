@tool
class_name GradeNoise
extends GradeFilter
## Grain: a fixed random light / dark per texel (the same every bake).

@export_range(0.0, 0.3, 0.005) var amount := 0.04
## Grain in colour (each channel its own) instead of grey.
@export var colour := false
@export var seed := 1


func title() -> String:
	return "Noise"


func per_pixel() -> bool:
	return true


func apply(c: Color, i: int) -> Color:
	var n := _hash(i * 3 + seed * 7919) * 2.0 - 1.0
	if not colour:
		return Color(c.r + n * amount, c.g + n * amount, c.b + n * amount)
	return Color(c.r + n * amount, c.g + (_hash(i * 3 + 1 + seed * 7919) * 2.0 - 1.0) * amount,
		c.b + (_hash(i * 3 + 2 + seed * 7919) * 2.0 - 1.0) * amount)


static func _hash(x: int) -> float:
	x = ((x >> 16) ^ x) * 0x45d9f3b
	x = ((x >> 16) ^ x) * 0x45d9f3b
	x = (x >> 16) ^ x
	return float(x & 0xFFFF) / 65535.0
