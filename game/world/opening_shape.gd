class_name OpeningShape
extends RefCounted
## The outline of a door / passage opening (local x across, centred; y up from the floor):
## a flat top, a round arch (a half circle, or half an ellipse when its rise isn't half the
## width) or a pointed (gothic) arch of two arcs meeting at the apex. `height` is the whole
## opening's; the arch takes the top `rise` of it (0 = the usual: half the width round,
## an equilateral arch pointed). Shared by the level tools (cutting, lining, trim) and the
## Door's panel.

enum Top { FLAT, ROUND, POINTED }

## Arch segments (whole arch): enough to read as curved, few enough for the N64.
const SEGMENTS := 10


## The arch's rise for these settings (0 when flat), never above the opening's height.
static func rise_of(width: float, height: float, top: int, arch_rise: float) -> float:
	if top == Top.FLAT:
		return 0.0
	var r := arch_rise
	if r <= 0.0:
		r = width * 0.5 if top == Top.ROUND else width * sqrt(3.0) * 0.5
	return clampf(r, 0.05, height)


## Points along the arch from its left springing to its right one (left to right), pushed
## `offset` outward (the trim's outer edge). Empty when flat.
static func arch_points(width: float, height: float, top: int, arch_rise: float, offset := 0.0) -> PackedVector2Array:
	var out := PackedVector2Array()
	if top == Top.FLAT:
		return out
	var rise := rise_of(width, height, top, arch_rise)
	var spring := height - rise
	var hw := width * 0.5
	if top == Top.ROUND:
		for i in SEGMENTS + 1:
			var a := PI * (1.0 - float(i) / SEGMENTS)
			out.append(Vector2((hw + offset) * cos(a), spring + (rise + offset) * sin(a)))
		return out
	# Pointed: the left arc is centred at (c, spring), through (-hw, spring) and the apex.
	var c := (rise * rise - hw * hw) / width
	var radius := c + hw + offset
	var half := SEGMENTS / 2
	var apex_a := acos(clampf(-c / radius, -1.0, 1.0))  # where the arc reaches x = 0
	for i in half + 1:
		var a := lerpf(PI, apex_a, float(i) / half)
		out.append(Vector2(c + radius * cos(a), spring + radius * sin(a)))
	for i in range(half - 1, -1, -1):
		var p := out[i]
		out.append(Vector2(-p.x, p.y))
	return out


## The whole opening (counter-clockwise from the bottom left): jambs, arch or flat top.
static func outline(width: float, height: float, top: int, arch_rise: float) -> PackedVector2Array:
	var hw := width * 0.5
	var out := PackedVector2Array([Vector2(hw, 0.0)])
	if top == Top.FLAT:
		out.append_array([Vector2(hw, height), Vector2(-hw, height)])
	else:
		var arch := arch_points(width, height, top, arch_rise)
		arch.reverse()  # right springing to left
		out.append_array(arch)
	out.append(Vector2(-hw, 0.0))
	return out


## Height of the springing line (where the jambs end and the arch begins).
static func spring_of(width: float, height: float, top: int, arch_rise: float) -> float:
	return height - rise_of(width, height, top, arch_rise)
