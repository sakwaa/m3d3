@tool
class_name GroundPile
extends RefCounted
## Ground piled up a little against what stands on it: the ground's vertices near a house's
## plinth or a solid block rise by up to `height` at its foot, easing off over `width`
## metres (smoothstep), so the ground slants up to the walls instead of meeting them flat,
## like soil and dust gathered at the foot. Ground: GRID brushes, only vertices of faces
## wearing one of the given textures (grass, dirt; any when none given). Each vertex takes
## the highest rise any structure asks; under a structure it rises fully (hidden there, so
## the slope starts right at the wall). Kept apart (LevelBrush.pile_offsets): clear() takes
## it off again; apply() expects it off (GroundFinish clears first).


## Raises the ground in `data`. Returns the vertices moved.
static func apply(data: LevelData, height := 0.06, width := 1.5, textures: Array = []) -> int:
	var feet := []  # [inverse transform, half extents XZ, base y (world)]
	for b: LevelBrush in data.brushes:
		if b == null:
			continue
		if b.is_house():
			var h := b.house
			feet.append([b.transform.affine_inverse(), Vector2(h.width * 0.5 + h.foundation_lip, h.depth * 0.5 + h.foundation_lip), b.transform.origin.y])
		elif BuildCull._is_solid_box(b) and b.shape != BrushShapes.Shape.GRID:
			var box: AABB = b.local_aabb()
			var c := box.get_center()
			var xf := b.transform * Transform3D(Basis(), Vector3(c.x, box.position.y, c.z))
			feet.append([xf.affine_inverse(), Vector2(box.size.x * 0.5, box.size.z * 0.5), xf.origin.y])
	if feet.is_empty():
		return 0
	var wanted := GroundEdgeBlend._palette_all(data, textures)
	var moved := 0
	for b: LevelBrush in data.brushes:
		if b == null or b.shape != BrushShapes.Shape.GRID or b.is_prop():
			continue
		var ground := {}  # vertices of faces wearing a ground texture
		for f in b.get_face_count():
			if textures.is_empty() or wanted.has(b.get_face_texture(f)):
				for v in b.get_face_vertex_ids(f):
					ground[v] = true
		var verts := b.vertices.duplicate()
		var offsets := PackedFloat32Array()
		offsets.resize(verts.size())
		var up := b.transform.basis.inverse() * Vector3.UP
		var changed := false
		for i in verts.size():
			if not ground.has(i):
				continue
			var w := b.transform * verts[i]
			var rise := 0.0
			for f in feet:
				if absf(w.y - (f[2] as float)) > 0.6:
					continue
				var q: Vector3 = (f[0] as Transform3D) * w
				var half: Vector2 = f[1]
				var d := Vector2(maxf(absf(q.x) - half.x, 0.0), maxf(absf(q.z) - half.y, 0.0)).length()
				if d >= width:
					continue
				rise = maxf(rise, height * (1.0 - smoothstep(0.0, width, d)))
			if rise > 0.0005:
				# (Offsets are along the brush's local up, in its own units.)
				var local := up * rise
				verts[i] += local
				offsets[i] = local.length()
				changed = true
				moved += 1
		if changed:
			b.pile_base = b.vertices.duplicate()
			b.pile_offsets = offsets
			b.vertices = verts
	return moved


## Takes the piling off `data`'s ground (where the brush still has the vertices it was
## piled with; a ground rebuilt since keeps its shape and just forgets the offsets).
static func clear(data: LevelData) -> void:
	for b: LevelBrush in data.brushes:
		if b == null or b.pile_offsets.is_empty():
			continue
		if b.pile_offsets.size() == b.vertices.size():
			var verts := b.vertices.duplicate()
			var up := (b.transform.basis.inverse() * Vector3.UP).normalized()
			var exact := b.pile_base.size() == verts.size()
			for i in verts.size():
				if b.pile_offsets[i] == 0.0:
					continue
				var lowered := verts[i] - up * b.pile_offsets[i]
				# Where it was piled to: back exactly where it stood; moved since: just lowered.
				verts[i] = b.pile_base[i] if exact and lowered.is_equal_approx(b.pile_base[i]) else lowered
			b.pile_offsets = PackedFloat32Array()
			b.pile_base = PackedVector3Array()
			b.vertices = verts
		else:
			push_warning("Ground finish: %s was rebuilt since it was piled; its piling stays in its shape." % b.tag)
			b.pile_offsets = PackedFloat32Array()
			b.pile_base = PackedVector3Array()
