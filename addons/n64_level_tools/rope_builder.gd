@tool
extends RefCounted
## Builds a rope brush's geometry (RopeStyle) from its points: each section between
## neighbouring points hangs `sag` metres at its middle (a parabola), cut into as few
## straight pieces as keep each bend under the style's max_bend, drawn as a cutout ribbon
## (two crossed when the style says so) with the texture repeated along it in whole repeats
## (LevelBrush.corner_uvs).

## Geometry rule version: ropes built by an older one are rebuilt when their level opens.
const BUILD := 2


## {vertices, faces, corner_uvs, textures (per face), bake (per face: 1 visual only)}, or
## {} when there's nothing to build. `points`: brush-local, in order; `open_sections`:
## sections (between points i and i + 1) left out. `tex`: palette index of the style's
## texture; `tile`: its metres per repeat (the shader divides UVs by it); `aspect`: width / height.
## `hangs`: what hangs from it, [{position, direction (hang_points()), drop (cord length, in
## the rope's texture), card: {} or {tex, tile, aspect, size, crossed}}, ...]; a card hangs
## from the bottom of its cord with its texture fitted once, in the rope's plane (and across
## it when crossed).
static func build_data(points: PackedVector3Array, open_sections: PackedInt32Array, style: RopeStyle, tex: int,
		tile := 1.0, aspect := 1.0, sag := 0.0, hangs := []) -> Dictionary:
	if points.size() < 2 or style == null or tex < 0:
		return {}
	var out := {vertices = PackedVector3Array(), faces = [] as Array[PackedInt32Array], corner_uvs = PackedVector2Array(),
		textures = PackedInt32Array(), bake = PackedByteArray()}
	var half := style.width * 0.5
	var repeat_len := maxf(style.width * aspect, 0.01)
	var v_size := tile / maxf(aspect, 0.001)
	for i in points.size() - 1:
		if i in open_sections:
			continue
		# The points hold the rope's top edge (it hangs from them, tucked against what it's
		# tied to), so its middle runs half its width lower.
		var curve := section_curve(points[i] + Vector3.DOWN * half, points[i + 1] + Vector3.DOWN * half, sag, style.segment_length, style.max_bend)
		# Distance along the curve at each point: the texture follows it, not the chord.
		var along := PackedFloat32Array([0.0])
		for k in range(1, curve.size()):
			along.append(along[k - 1] + curve[k].distance_to(curve[k - 1]))
		var length := along[along.size() - 1]
		if length < 1e-4:
			continue
		var reps := maxf(1.0, roundf(length / repeat_len))
		# Across the ribbons: flat = sideways across the section, level; upright = square to
		# the curve in its vertical plane (stays perpendicular as the rope dips).
		var d := points[i + 1] - points[i]
		var side := Vector3(-d.z, 0.0, d.x).normalized() if Vector2(d.x, d.z).length() > 1e-4 else Vector3.RIGHT
		for k in curve.size() - 1:
			var p0 := curve[k]
			var p1 := curve[k + 1]
			var u0 := along[k] / length * reps * tile
			var u1 := along[k + 1] / length * reps * tile
			var up0 := _upright(curve, k, side) * half
			var up1 := _upright(curve, k + 1, side) * half
			_quad(out, tex, p0 + up0, p1 + up1, p1 - up1, p0 - up0, u0, u1, v_size)
			if style.crossed:
				_quad(out, tex, p0 + side * half, p1 + side * half, p1 - side * half, p0 - side * half, u0, u1, v_size)
	for h in hangs:
		var top: Vector3 = h.position
		var d: Vector3 = h.direction
		var across := Vector3(-d.z, 0.0, d.x)
		var drop: float = h.get("drop", 0.0)
		if drop > 0.0:
			var reps := maxf(1.0, roundf(drop / repeat_len))
			var bottom := top + Vector3.DOWN * drop
			for w: Vector3 in [d, across]:
				var o := w * half
				_quad(out, tex, top + o, bottom + o, bottom - o, top - o, 0.0, reps * tile, v_size)
			top = bottom
		var card: Dictionary = h.get("card", {})
		if card.is_empty() or card.tex < 0:
			continue
		var size: Vector2 = card.size
		var cu: float = card.tile
		var cv: float = card.tile / maxf(card.aspect, 0.001)
		var bottom := top + Vector3.DOWN * size.y
		for w: Vector3 in ([d, across] if card.crossed else [d]):
			var o := w * size.x * 0.5
			# Card UVs run 0 .. cu across, 0 .. cv down: the whole texture once.
			var i: int = out.vertices.size()
			out.vertices.append_array([top - o, top + o, bottom + o, bottom - o])
			out.faces.append(PackedInt32Array([i, i + 1, i + 2, i + 3]))
			out.corner_uvs.append_array([Vector2(0.0, 0.0), Vector2(cu, 0.0), Vector2(cu, cv), Vector2(0.0, cv)])
			out.textures.append(card.tex)
			out.bake.append(1)
	return out if not out.faces.is_empty() else {}


## Where things hang along the rope: [{position (on the rope, brush-local), direction
## (along the section, level)}, ...], on the same pieces build_data draws. `placement`
## (RopeHang.Placement): about `spacing` apart along each section (whole gaps per section,
## half a gap from its ends, shifted by `offset` of a gap), one at each section's middle, or
## at the points between sections. `lower`: how far the rope's middle runs below its points
## (half the style's width).
static func hang_points(points: PackedVector3Array, open_sections: PackedInt32Array, sag: float, segment_length: float,
		placement: int, spacing: float, offset := 0.0, lower := 0.0, max_bend := 0.0) -> Array:
	var out := []
	var dir_of := func(i: int) -> Vector3:
		var d := points[i + 1] - points[i]
		return Vector3(d.x, 0.0, d.z).normalized() if Vector2(d.x, d.z).length() > 1e-4 else Vector3.RIGHT
	if placement == RopeHang.Placement.POINTS:
		for i in range(1, points.size() - 1):
			if (i - 1) in open_sections and i in open_sections:
				continue
			var d: Vector3 = (dir_of.call(i - 1) + dir_of.call(i)).normalized()
			out.append({position = points[i] + Vector3.DOWN * lower, direction = d if d.length_squared() > 0.5 else dir_of.call(i)})
		return out
	for i in points.size() - 1:
		if i in open_sections:
			continue
		var curve := section_curve(points[i] + Vector3.DOWN * lower, points[i + 1] + Vector3.DOWN * lower, sag, segment_length, max_bend)
		var along := PackedFloat32Array([0.0])
		for k in range(1, curve.size()):
			along.append(along[k - 1] + curve[k].distance_to(curve[k - 1]))
		var length := along[along.size() - 1]
		if length < 1e-3:
			continue
		var spots := PackedFloat32Array()
		if placement == RopeHang.Placement.SECTION_MIDDLE:
			spots.append(0.5)
		else:
			var count := maxi(1, roundi(length / maxf(spacing, 0.05)))
			for j in count:
				spots.append(fposmod((j + 0.5 + offset) / count, 1.0))
			spots.sort()
		var k := 0
		for f in spots:
			var s := f * length
			while k < curve.size() - 2 and along[k + 1] < s:
				k += 1
			var t := (s - along[k]) / maxf(along[k + 1] - along[k], 1e-6)
			out.append({position = curve[k].lerp(curve[k + 1], t), direction = dir_of.call(i)})
	return out


## Points along the section from `a` to `b` hanging `sag` at the middle: pieces about
## `segment_length` long, or fewer when that's more than keeps each bend under `max_bend`
## degrees (at least 2 when it sags).
static func section_curve(a: Vector3, b: Vector3, sag: float, segment_length: float, max_bend := 0.0) -> PackedVector3Array:
	var length := a.distance_to(b)
	var pieces := 1 if sag <= 0.0 else clampi(ceili(length / maxf(segment_length, 0.05)), 2, 32)
	if sag > 0.0 and max_bend > 0.0:
		# The parabola's slope runs from (rise - 4 sag) / run to (rise + 4 sag) / run.
		var run := maxf(Vector2(b.x - a.x, b.z - a.z).length(), 1e-3)
		var rise := b.y - a.y
		var bend := rad_to_deg(atan((rise + 4.0 * sag) / run) - atan((rise - 4.0 * sag) / run))
		pieces = clampi(mini(pieces, ceili(bend / max_bend)), 2, 32)
	var out := PackedVector3Array()
	for k in pieces + 1:
		var t := float(k) / pieces
		out.append(a.lerp(b, t) + Vector3.DOWN * sag * 4.0 * t * (1.0 - t))
	return out


## Unit vector square to the curve at point `k`, in the plane of the curve and `side`'s normal.
static func _upright(curve: PackedVector3Array, k: int, side: Vector3) -> Vector3:
	var t := curve[mini(k + 1, curve.size() - 1)] - curve[maxi(k - 1, 0)]
	var n := side.cross(t).normalized()
	if n.length_squared() < 0.5:
		return Vector3.UP
	return n if n.y >= 0.0 else -n


## Quad top-left, top-right, bottom-right, bottom-left with the texture running along the
## top edge from u0 to u1 (metres, as the shader reads them), its height across.
static func _quad(out: Dictionary, tex: int, tl: Vector3, tr: Vector3, br: Vector3, bl: Vector3, u0: float, u1: float,
		v_size: float) -> void:
	var i: int = out.vertices.size()
	out.vertices.append_array([tl, tr, br, bl])
	out.faces.append(PackedInt32Array([i, i + 1, i + 2, i + 3]))
	out.corner_uvs.append_array([Vector2(u0, 0.0), Vector2(u1, 0.0), Vector2(u1, v_size), Vector2(u0, v_size)])
	out.textures.append(tex)
	out.bake.append(1)
