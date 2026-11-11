@tool
class_name BuildCull
extends RefCounted
## The build's hidden-face removal (Build & Play, export), on the build's copy of the level:
##  - ground under buildings: upward faces of plain brushes lying wholly under a house's
##    plinth or under a solid box brush standing on them (a raised square laid on the
##    ground grid);
##  - walls pressed against a neighbour: a house's outside wall faces with another house's
##    walls right behind them (a terrace).
## Neither can ever be seen or walked on. Faces only partly covered are kept.

## How far apart touching walls may stand. Only flush walls: two walls with a crack between
## them both stay (culling both opened the crack to the sky). Side by side houses join into a
## terrace when they're built (HouseTerrace), so this is left with what that doesn't join.
const GAP := 0.02


## Removes the hidden faces from `data`'s brushes. Returns {ground, walls} (faces removed).
static func cull(data: LevelData) -> Dictionary:
	var houses := []  # [brush, inverse transform, half extents with lip, plinth top (local y)]
	var boxes := []  # solid box brushes: [inverse transform, local AABB]
	for b: LevelBrush in data.brushes:
		if b == null:
			continue
		if b.is_house():
			var h := b.house
			houses.append([b, b.transform.affine_inverse(), Vector2(h.width * 0.5 + h.foundation_lip, h.depth * 0.5 + h.foundation_lip),
				h.foundation, Vector2(h.width * 0.5, h.depth * 0.5), h.wall_height()])
		elif _is_solid_box(b):
			boxes.append([b, b.transform.affine_inverse(), b.local_aabb()])
	var out := {ground = 0, walls = 0}
	for b: LevelBrush in data.brushes:
		if b == null or b.blend_file != "" or b.is_fence() or b.is_rope() or b.opening_spec() != null:
			continue
		var hidden: Array[int] = []
		for f in b.get_face_count():
			var n := (b.transform.basis * b.get_face_normal(f)).normalized()
			var pts := PackedVector3Array()
			for p in b.get_face_points(f):
				pts.append(b.transform * p)
			if b.is_house():
				if absf(n.y) < 0.3 and _against_neighbour(b, pts, n, houses):
					hidden.append(f)
					out.walls += 1
			elif n.y > 0.7 and _under_cover(b, pts, houses, boxes):
				hidden.append(f)
				out.ground += 1
		if not hidden.is_empty():
			_delete(b, hidden)
	return out


## A plain 6-sided box (shape BLOCK, not hand cut) that's drawn: solid, so what's under it
## is hidden. (A prop's box is only for picking it; a collision-only box isn't seen.)
static func _is_solid_box(b: LevelBrush) -> bool:
	return not b.is_house() and b.opening_spec() == null and not b.is_fence() and not b.is_rope() \
		and not b.is_prop() and b.bake_mode != LevelBrush.BakeMode.COLLISION_ONLY \
		and b.get_face_count() <= 12 and b.local_aabb().size.y > 0.2 and b.shape == BrushShapes.Shape.BLOCK


## Every corner of the face inside a house's plinth footprint (at or below its top), or
## inside a solid box's footprint and at or below its bottom.
static func _under_cover(b: LevelBrush, pts: PackedVector3Array, houses: Array, boxes: Array) -> bool:
	for h in houses:
		if h[0] == b:
			continue
		var inv: Transform3D = h[1]
		var reach: Vector2 = h[2]
		var ok := true
		for p in pts:
			var q := inv * p
			if absf(q.x) > reach.x + 0.01 or absf(q.z) > reach.y + 0.01 or q.y > h[3] + 0.01:
				ok = false
				break
		if ok:
			return true
	for bx in boxes:
		if bx[0] == b:
			continue
		var inv: Transform3D = bx[1]
		var box: AABB = bx[2]
		var ok := true
		for p in pts:
			var q := inv * p
			if q.x < box.position.x - 0.01 or q.x > box.end.x + 0.01 or q.z < box.position.z - 0.01 or q.z > box.end.z + 0.01 \
					or q.y > box.position.y + 0.05:
				ok = false
				break
		if ok:
			return true
	return false


## A wall face of house `b` with another house's wall volume right in front of it (within
## GAP), over the whole face.
static func _against_neighbour(b: LevelBrush, pts: PackedVector3Array, n: Vector3, houses: Array) -> bool:
	var probe := pts.duplicate()
	var c := Vector3.ZERO
	for p in pts:
		c += p
	probe.append(c / pts.size())
	for h in houses:
		if h[0] == b:
			continue
		var inv: Transform3D = h[1]
		var half: Vector2 = h[4]
		var ok := true
		for p in probe:
			# Pull corners in a little (shared edges) and step out of the wall into the gap.
			var q := inv * (p + (c / pts.size() - p) * 0.02 + n * GAP)
			if absf(q.x) > half.x + 0.01 or absf(q.z) > half.y + 0.01 or q.y < h[3] - 0.01 or q.y > h[5] + 0.01:
				ok = false
				break
		if ok:
			return true
	return false


static func _delete(b: LevelBrush, faces: Array[int]) -> void:
	var r := BrushOps.delete_faces(b.vertices, b.get_faces(), faces)
	var corners := b.full_corner_colors() if b.has_corner_colors() else PackedColorArray()
	var light := b.corner_lighting
	var keys := b.corner_lighting_keys.duplicate()
	var old_faces := b.get_faces()
	# Corner data of the kept faces, in order.
	var keep_corner := PackedInt32Array()
	for nf in r.map.size():
		var old: int = r.map[nf]
		var start := b.get_face_start(old)
		for k in old_faces[old].size():
			keep_corner.append(start + k)
	var masks := {}
	for nf in r.map.size():
		for layer in LevelData.MAX_LAYERS:
			var m := b.get_face_mask(r.map[nf], layer)
			if m:
				masks[Vector2i(nf, layer)] = m
	var bake := b.face_bake.duplicate()
	var old_ao := b.vertex_ao.duplicate()
	var old_vc := b.vertex_colors.duplicate()
	var pick := func(src: PackedColorArray) -> PackedColorArray:
		var out := PackedColorArray()
		for i in keep_corner:
			out.append(src[i] if i < src.size() else Color.WHITE)
		return out
	b.vertices = r.verts
	b.set_faces(r.faces)
	b.remap_faces(r.map, false)
	b.face_masks = masks
	if not bake.is_empty():
		var nb := PackedByteArray()
		for old in r.map:
			nb.append(bake[old] if old < bake.size() else 0)
		b.face_bake = nb
	if not corners.is_empty():
		b.corner_colors = pick.call(corners)
	if light.size() == old_faces.reduce(func(a, f): return a + f.size(), 0):
		b.corner_lighting = pick.call(light)
	if not keys.is_empty():
		var nk: Array[PackedColorArray] = []
		for k: PackedColorArray in keys:
			nk.append(pick.call(k))
		b.corner_lighting_keys = nk
	# Per-vertex data follows the kept vertices.
	var vmap: PackedInt32Array = r.vertex_map
	if not old_ao.is_empty():
		var ao := PackedFloat32Array()
		for old in vmap:
			ao.append(old_ao[old] if old < old_ao.size() else 1.0)
		b.vertex_ao = ao
	if not old_vc.is_empty():
		var vc := PackedColorArray()
		for old in vmap:
			vc.append(old_vc[old] if old < old_vc.size() else Color.WHITE)
		b.vertex_colors = vc
