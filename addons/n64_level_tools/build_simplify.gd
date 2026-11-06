@tool
class_name BuildSimplify
extends RefCounted
## The build's geometry pass (Build & Play, export): a copy of the level whose brushes keep
## only the vertices their shape or their vertex data needs. Neighbouring faces in one plane
## that match (texture, UV, surface, overlay set, bake mode) merge when every corner of both
## (painted colour, AO, baked lighting, every lighting key) lies on one linear blend across
## the merged face, within `tolerance`: the merged face shades the same as its parts did, so
## shadow edges and colour changes keep their vertices and flat stretches lose theirs.
## Merges stay inside the baker's chunk cells (LevelBaker.CHUNK_SIZE, by face centre, on the
## same grid), so chunks stay compact for culling. Painted masks move onto the merged faces
## at full density. The level being edited is never changed.

static var tolerance := 2.0 / 255.0
const MAX_MASK := 1024


## A copy of `data` with every brush simplified (brushes with exact UVs, such as fences,
## ropes and set pieces, are kept as they are). Returns {data, before, after} (face counts).
static func optimized_copy(data: LevelData) -> Dictionary:
	var copy: LevelData = data.duplicate()
	var brushes: Array[LevelBrush] = []
	var origin := _grid_origin(data)
	var before := 0
	var after := 0
	for b: LevelBrush in data.brushes:
		if b == null:
			brushes.append(null)
			continue
		var c: LevelBrush = b.duplicate()
		before += c.get_face_count()
		if not c.has_corner_uvs() and c.blend_file == "":
			simplify(c, origin, data.mask_density)
		after += c.get_face_count()
		brushes.append(c)
	copy.brushes = brushes
	return {data = copy, before = before, after = after}


## The baker's chunk grid corner (LevelBaker._assign_cells): the level's bounds.
static func _grid_origin(data: LevelData) -> Vector3:
	var box := AABB()
	var first := true
	for b: LevelBrush in data.brushes:
		if b == null:
			continue
		for v in b.vertices:
			var p := b.transform * v
			if first:
				box = AABB(p, Vector3.ZERO)
				first = false
			else:
				box = box.expand(p)
	return box.position


## Merges `b`'s faces in place (see the class notes). `origin`: the chunk grid's corner.
static func simplify(b: LevelBrush, origin: Vector3, density: float) -> void:
	var verts := b.vertices
	var polys := b.get_faces()
	var n_faces := polys.size()
	if n_faces < 2:
		return
	var keys := b.corner_lighting_keys
	var lit := b.corner_lighting.size() == b.face_indices.size()
	var corners := b.has_corner_colors()
	# Per face: what must match, its plane, and its corners' samples (planar UV + values).
	var compat := []
	var samples := []
	var normals := []
	for f in n_faces:
		var pts := b.get_face_points(f)
		var n := PolyUtil.newell_normal(pts)
		normals.append(n)
		var centre := Vector3.ZERO
		for p in pts:
			centre += b.transform * p
		centre /= pts.size()
		var cell := Vector2i(floori((centre.x - origin.x) / LevelBaker.CHUNK_SIZE),
			floori((centre.z - origin.z) / LevelBaker.CHUNK_SIZE))
		compat.append([b.get_surface_key(f), b.get_face_texture(f), b.get_face_uv(f), b.get_face_surface(f),
			b.get_face_layer_set(f), b.face_bake[f] if f < b.face_bake.size() else 0, cell,
			BrushOps._plane_key(verts, polys[f])])
		var list := []
		var start := b.get_face_start(f)
		for k in polys[f].size():
			var v := polys[f][k]
			list.append([PolyUtil.planar_uv(verts[v], n), _values(b, start + k, v, lit, keys)])
		samples.append(list)

	# Greedy merging, as BrushOps.merge_coplanar, with the shading check.
	var faces: Array = []
	faces.append_array(polys)
	var members := []
	for f in n_faces:
		members.append([f])
	var owner := {}
	var usage := {}
	for f in n_faces:
		BrushOps._register(faces[f], f, owner, usage, 1)
	var queue := range(n_faces)
	while not queue.is_empty():
		var i: int = queue.pop_back()
		if faces[i] == null:
			continue
		var p: PackedInt32Array = faces[i]
		for k in p.size():
			var j: int = owner.get(Vector2i(p[(k + 1) % p.size()], p[k]), -1)
			if j < 0 or j == i or faces[j] == null or compat[j] != compat[i]:
				continue
			var together: Array = samples[i] + samples[j]
			if not _linear(together):
				continue
			var merged := BrushOps._try_merge(p, faces[j], usage)
			if merged.is_empty():
				continue
			BrushOps._register(p, i, owner, usage, -1)
			BrushOps._register(faces[j], j, owner, usage, -1)
			faces[i] = merged
			faces[j] = null
			members[i].append_array(members[j])
			samples[i] = together
			BrushOps._register(merged, i, owner, usage, 1)
			queue.append(i)
			break

	var out_faces: Array[PackedInt32Array] = []
	var map := PackedInt32Array()
	var parent := PackedInt32Array()
	var out_members := []
	for f in faces.size():
		if faces[f] == null:
			continue
		out_faces.append(BrushOps._drop_collinear(verts, faces[f], usage))
		map.append(members[f][0])
		parent.append(out_members.size())
		out_members.append(members[f])
	if out_faces.size() == n_faces:
		return

	# Corner data for the new faces: each corner from a part that has that vertex.
	var old_corner := {}  # Vector2i(face, vertex) -> corner index
	for f in n_faces:
		var start := b.get_face_start(f)
		for k in polys[f].size():
			old_corner[Vector2i(f, polys[f][k])] = start + k
	var picks := PackedInt32Array()  # per new corner: the old corner it copies
	for i in out_faces.size():
		for v in out_faces[i]:
			var at := -1
			for f: int in out_members[i]:
				at = old_corner.get(Vector2i(f, v), -1)
				if at >= 0:
					break
			picks.append(at)
	var old_colors := b.full_corner_colors() if corners else PackedColorArray()
	var old_light := b.corner_lighting
	var old_keys := keys.duplicate()

	# Masks, before the faces change.
	var old_masks := {}
	for key: Vector2i in b.face_masks:
		old_masks[key] = b.face_masks[key]
	var old_flat := {}
	var old_rect := {}
	for f in n_faces:
		if b.face_has_mask(f):
			var fp := PackedVector2Array()
			for p in b.get_face_points(f):
				fp.append(PolyUtil.planar_uv(p, normals[f]))
			old_flat[f] = fp
			old_rect[f] = b.get_face_planar_rect(f)
	var unchanged := {}
	for i in out_faces.size():
		if out_members[i].size() == 1:
			unchanged[i] = out_members[i][0]
	var old_bake := b.face_bake.duplicate()

	b.set_faces(out_faces)
	b.remap_faces(map, false)
	if not old_bake.is_empty():
		var bake := PackedByteArray()
		for old in map:
			bake.append(old_bake[old] if old < old_bake.size() else 0)
		b.face_bake = bake
	var pick := func(src: PackedColorArray) -> PackedColorArray:
		var out := PackedColorArray()
		for c in picks:
			out.append(src[c] if c >= 0 and c < src.size() else Color.WHITE)
		return out
	if corners:
		b.corner_colors = pick.call(old_colors)
	if lit:
		b.corner_lighting = pick.call(old_light)
	if not old_keys.is_empty():
		var nk: Array[PackedColorArray] = []
		for k: PackedColorArray in old_keys:
			nk.append(pick.call(k))
		b.corner_lighting_keys = nk
	b.face_masks = BrushCleanup._masks(b, out_faces.size(), parent, out_members, unchanged, old_masks, old_flat, old_rect,
		density, MAX_MASK)


## What a corner carries into the bake: painted colour, AO, baked light, each key's light.
static func _values(b: LevelBrush, corner: int, v: int, lit: bool, keys: Array[PackedColorArray]) -> PackedFloat32Array:
	var c := b.get_corner_color(corner, v)
	var out := PackedFloat32Array([c.r, c.g, c.b, b.get_vertex_ao(v)])
	if lit:
		var l := b.corner_lighting[corner]
		out.append_array([l.r, l.g, l.b])
	for k: PackedColorArray in keys:
		var l: Color = k[corner] if corner < k.size() else Color.WHITE
		out.append_array([l.r, l.g, l.b])
	return out


## Whether every sample's values are one linear blend over the plane (within TOLERANCE).
static func _linear(samples: Array) -> bool:
	var u0: Vector2 = samples[0][0]
	var f0: PackedFloat32Array = samples[0][1]
	# Two more corners spanning the plane: the farthest, then the farthest off that line.
	var a := 0
	var best := 0.0
	for s in samples.size():
		var d := (samples[s][0] as Vector2).distance_squared_to(u0)
		if d > best:
			best = d
			a = s
	var d1: Vector2 = samples[a][0] - u0
	var c := -1
	best = 0.0
	for s in samples.size():
		var area := absf(d1.cross((samples[s][0] as Vector2) - u0))
		if area > best:
			best = area
			c = s
	var channels := f0.size()
	var grad := []  # per channel: Vector2
	if c < 0 or best < 1e-6:
		# All on one line (or one point): values along it only.
		var len2 := d1.length_squared()
		for ch in channels:
			var g := Vector2.ZERO
			if len2 > 1e-10:
				g = d1 * ((samples[a][1][ch] - f0[ch]) / len2)
			grad.append(g)
	else:
		var d2: Vector2 = samples[c][0] - u0
		var det := d1.x * d2.y - d1.y * d2.x
		for ch in channels:
			var e1: float = samples[a][1][ch] - f0[ch]
			var e2: float = samples[c][1][ch] - f0[ch]
			grad.append(Vector2((e1 * d2.y - e2 * d1.y) / det, (d1.x * e2 - d2.x * e1) / det))
	for s in samples:
		var du: Vector2 = s[0] - u0
		var vals: PackedFloat32Array = s[1]
		for ch in channels:
			if absf(f0[ch] + (grad[ch] as Vector2).dot(du) - vals[ch]) > tolerance:
				return false
	return true
