class_name N64Stick
extends RefCounted
## The N64 controller's analog stick, for a modern stick (and keys): its feel as OoT / MM
## read it (project setting n64/input/stick_gate, on by default):
##  - Octagonal gate: the stick rides an octagon with notches at the 8 directions - full tilt
##    reaches 1 at a notch and a little less between them (cos 22.5 deg), and near a notch it
##    slides into it (exact cardinals and diagonals are easy to hold).
##  - Per-axis dead zone (each axis on its own, as the games read it): small sideways drift
##    while pushing forward is dropped, so straight lines stay straight.
##  - Coarse: ~80 steps a side (the stick's counter), so speed comes in small steps.
##  - Full speed before the rim (OoT clamps the reading at 60 of ~80): `full_at` of the
##    travel is already full.

const SETTING := "n64/input/stick_gate"
## Each axis's dead zone (share of full travel: OoT ~7 of 80).
const AXIS_DEAD := 0.09
## Degrees either side of a notch that slide into it.
const NOTCH := 7.0
## Travel (after the gate) that's already full speed.
const FULL_AT := 0.8
## Steps a side.
const STEPS := 80.0


static func enabled() -> bool:
	return bool(ProjectSettings.get_setting(SETTING, true))


## The stick from four actions, shaped like an N64 stick (or Godot's usual round dead zone
## when the setting is off). Keys pass through the same shaping.
static func read(neg_x: StringName, pos_x: StringName, neg_y: StringName, pos_y: StringName, deadzone := 0.2) -> Vector2:
	if not enabled():
		return Input.get_vector(neg_x, pos_x, neg_y, pos_y, deadzone)
	return shape(Input.get_vector(neg_x, pos_x, neg_y, pos_y, 0.0001))


## A raw stick reading (-1..1 each axis, round travel) as the N64 game would see it.
static func shape(v: Vector2) -> Vector2:
	if v == Vector2.ZERO:
		return v
	# Octagonal gate: the travel in this direction (1 at a notch, cos 22.5 deg between).
	var a := atan2(v.y, v.x)
	var step := PI / 4.0
	var k := roundf(a / step)
	var off := a - k * step
	# Near a notch the stick slides in.
	if absf(off) < deg_to_rad(NOTCH):
		off *= absf(off) / deg_to_rad(NOTCH)
		a = k * step + off
	var gate := cos(PI / 8.0) / cos(absf(fposmod(a + PI / 8.0, step) - PI / 8.0))
	var r := minf(v.length(), gate)
	v = Vector2(cos(a), sin(a)) * r
	# Per-axis dead zone, the rest rescaled.
	var out := Vector2.ZERO
	for i in 2:
		var x := v[i]
		out[i] = signf(x) * maxf(absf(x) - AXIS_DEAD, 0.0) / (1.0 - AXIS_DEAD)
	if out == Vector2.ZERO:
		return out
	# Full before the rim, then the counter's steps.
	out = out / FULL_AT
	out = (out * STEPS).round() / STEPS
	return out.limit_length(1.0)
