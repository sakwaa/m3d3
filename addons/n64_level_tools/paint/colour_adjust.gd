@tool
class_name ColourAdjust
extends Resource
## A live colour adjustment of a base texture as a level shows it (LevelData.base_adjusts:
## every face of that texture in the zone; TextureLook.adjust: a variant on some faces).
## Applied in the paint shader after the texture's own tint, so editing it updates the
## viewport at once and nothing about the texture file changes. Baked levels carry it too.

## Hue turn (degrees).
@export_range(-180.0, 180.0, 1.0, "suffix:°") var hue := 0.0
@export_range(0.0, 2.0, 0.01) var saturation := 1.0
## Brightness (multiplier).
@export_range(0.0, 2.0, 0.01) var brightness := 1.0
@export_range(0.5, 1.5, 0.01) var contrast := 1.0
## Warmer (+) / cooler (-).
@export_range(-1.0, 1.0, 0.01) var temperature := 0.0
## Magenta (+) / green (-).
@export_range(-1.0, 1.0, 0.01) var tint := 0.0
## Midtones lighter (> 1) / darker (< 1).
@export_range(0.5, 2.0, 0.01) var gamma := 1.0
## Start from grey: the texture keeps only its brightness, coloured by a ramp from `shadow`
## (its darks) to `colorize` (its lights), mixed in by colorize_amount (1 = all of it):
## colour each texture yourself. Off: colorize tints the texture's own colours.
@export var from_grey := false
@export var shadow := Color(0.18, 0.14, 0.12)
## Colorize: the texture's brightness in this colour, mixed in by `colorize_amount`.
@export var colorize := Color(0.6, 0.5, 0.35)
@export_range(0.0, 1.0, 0.01) var colorize_amount := 0.0

const FIELDS := [&"hue", &"saturation", &"brightness", &"contrast", &"temperature", &"tint", &"gamma", &"colorize", &"colorize_amount", &"from_grey", &"shadow"]


func is_identity() -> bool:
	return is_zero_approx(hue) and is_equal_approx(saturation, 1.0) and is_equal_approx(brightness, 1.0) \
		and is_equal_approx(contrast, 1.0) and is_zero_approx(temperature) and is_zero_approx(tint) \
		and is_equal_approx(gamma, 1.0) and is_zero_approx(colorize_amount) and not from_grey


func to_dict() -> Dictionary:
	var d := {}
	for f in FIELDS:
		d[f] = get(f)
	return d


static func from_dict(d: Dictionary) -> ColourAdjust:
	var a := ColourAdjust.new()
	for f in FIELDS:
		if d.has(f):
			a.set(f, d[f])
	return a


## Shader parameters (base_adj0..3; all zero = off).
static func params(a: ColourAdjust) -> Array:
	if a == null or a.is_identity():
		return [Vector4.ZERO, Vector4.ZERO, Vector4.ZERO, Vector4.ZERO]
	var c := a.colorize
	var d := a.shadow
	return [Vector4(deg_to_rad(a.hue), a.saturation, a.brightness, a.contrast),
		Vector4(a.temperature, a.tint, a.gamma, 2.0 if a.from_grey else 1.0),
		Vector4(c.r, c.g, c.b, a.colorize_amount),
		Vector4(d.r, d.g, d.b, 0.0)]
