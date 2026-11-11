@tool
class_name BrushCleanup
extends RefCounted
## "Clean up": rebuilds a brush's faces without the clutter cuts leave behind. Faces that
## touch, lie in one plane and match (texture, UV, surface, overlay set, bake mode, and a
## painted colour that's the same at every corner) merge into one polygon, then each is cut
## back into a grid on world lines `cell` apart, so vertex lighting / AO still have
## vertices to shade with. A cut that would leave a strip thinner than a quarter cell is
## skipped. Painted masks are resampled onto the new faces from the old ones; neighbouring
## faces gain the new border vertices (no T-junctions). Lighting / AO need baking again.

const MIN_PIECE := 0.25  # of a cell: thinnest strip a cut may leave


## Cleans `faces` (indices) of `b` in place. `regrid_single` off (the build): faces nothing
## merged into stay whole (a building's wall isn't cut into cells). Returns {before, after}
## (face counts) or {error}.
static func clean_up(b: LevelBrush, faces: Array[int], cell: float, density: float, regrid_single := true) -> Dictionary:
	if b.is_fence() or b.is_rope() or b.is_passage() or b.is_door():
		return {error = "generated brushes (fences, ropes, passages, doors) rebuild themselves"}
	if not b.corner_uvs.is_empty():
		return {error = "faces with exact UVs (set pieces) can't be merged"}
	cell = maxf(cell, 0.1)
	var verts := b.vertices
	var polys := b.get_faces()
	var before := polys.size()
	var chosen := {}
	for f in faces:
		if f < polys.size():
			chosen[f] = true
	if chosen.is_empty():
		return {error = "nothing selected"}

	# 1. Merge: matching coplanar faces become one polygon.
	var compat := []
	for f in polys.size():
		if not chosen.has(f):
			compat.append(["keep", f])
			continue
		compat.append([b.get_face_texture(f), b.get_face_uv(f), b.get_face_surface(f), b.get_face_layer_set(f),
			b.face_bake[f] if f < b.face_bake.size() else 0, _tone(b, f), b.get_face_lod(f)])
	var merged := BrushOps.merge_coplanar(verts, polys, compat)

	# 2. Grid: each merged polygon cut on world lines `cell` apart (in its planar UV, the
	# space masks use), as pieces of the polygon itself (concave ones too).
	var out_verts := verts.duplicate()
	var out_faces: Array[PackedInt32Array] = []
	var parent := PackedInt32Array()  # out face -> merged face
	var by_pos := {}  # snapped position -> new vertex
	var fresh := {}  # new vertex -> the merged face it was made for
	for m in merged.faces.size():
		var poly: PackedInt32Array = merged.faces[m]
		var members: Array = merged.members[m]
		if not chosen.has(members[0]) or (not regrid_single and members.size() == 1):
			out_faces.append(poly)
			parent.append(m)
			continue
		var pts := PackedVector3Array()
		for i in poly:
			pts.append(verts[i])
		var n := PolyUtil.newell_normal(pts)
		if n == Vector3.ZERO:
			out_faces.append(poly)
			parent.append(m)
			continue
		var d := n.dot(pts[0])
		var flat := PackedVector2Array()
		for p in pts:
			flat.append(PolyUtil.planar_uv(p, n))
		for piece in _grid_pieces(flat, cell):
			var ids := PackedInt32Array()
			for uv in piece:
				var at := -1
				for k in flat.size():
					if flat[k].distance_squared_to(uv) < 1e-8:
						at = poly[k]
						break
				if at < 0:
					var p := PolyUtil.planar_unproject(uv, n, d)
					var key := Vector3i((p * 1000.0).round())
					at = by_pos.get(key, -1)
					if at < 0:
						at = out_verts.size()
						out_verts.append(p)
						by_pos[key] = at
						fresh[at] = m
				if ids.is_empty() or ids[-1] != at:
					ids.append(at)
			if ids.size() > 1 and ids[0] == ids[-1]:
				ids.remove_at(ids.size() - 1)
			if ids.size() < 3:
				continue
			# Same winding as the polygon it came from.
			var piece_pts := PackedVector3Array()
			for i in ids:
				piece_pts.append(out_verts[i])
			if PolyUtil.newell_normal(piece_pts).dot(n) < 0.0:
				ids.reverse()
			out_faces.append(ids)
			parent.append(m)

	# 3. Stitch: new vertices lying on another face's edge join that edge.
	_stitch(out_verts, out_faces, fresh.keys(), cell)

	# 4. Drop unused vertices; new ones take their colour from the face they were made for.
	var packed := BrushOps.compact(out_verts, out_faces)
	var sources: Array[PackedInt32Array] = []
	for v in packed.vertex_map:
		if v < verts.size():
			sources.append(PackedInt32Array([v]))
		else:
			sources.append(PackedInt32Array([merged.faces[fresh[v]][0]]))

	# Per face: the old face it continues (texture, UV, ...), and old outlines for masks.
	var map := PackedInt32Array()
	for m in parent:
		map.append(merged.members[m][0])
	var old_masks := {}
	for key: Vector2i in b.face_masks:
		old_masks[key] = b.face_masks[key]
	var old_flat := {}
	var old_rect := {}
	for f in polys.size():
		if b.face_has_mask(f):
			var fn := b.get_face_normal(f)
			var fp := PackedVector2Array()
			for p in b.get_face_points(f):
				fp.append(PolyUtil.planar_uv(p, fn))
			old_flat[f] = fp
			old_rect[f] = b.get_face_planar_rect(f)
	var old_bake := b.face_bake.duplicate()
	var unchanged := {}  # out face -> old face, where the face is exactly as it was
	for i in packed.faces.size():
		var members: Array = merged.members[parent[i]]
		if members.size() == 1 and out_faces[i] == polys[members[0]]:
			unchanged[i] = members[0]

	b.vertices = packed.verts
	b.set_faces(packed.faces)
	b.remap_faces(map, false)
	b.blend_vertex_colors(sources)
	if not old_bake.is_empty():
		var bake := PackedByteArray()
		for old in map:
			bake.append(old_bake[old] if old < old_bake.size() else 0)
		b.face_bake = bake
	b.corner_lighting = PackedColorArray()
	b.corner_lighting_keys = [] as Array[PackedColorArray]
	b.face_masks = _masks(b, packed.faces.size(), parent, merged.members, unchanged, old_masks, old_flat, old_rect,
		density)
	b.hand_edited = true
	return {before = before, after = packed.faces.size()}


## A face's painted colour when every corner has it (merge key), else something unique.
static func _tone(b: LevelBrush, f: int) -> Variant:
	var start := b.get_face_start(f)
	var first := b.get_corner_color(start, b.face_indices[start])
	for k in range(1, b.face_counts[f]):
		if not b.get_corner_color(start + k, b.face_indices[start + k]).is_equal_approx(first):
			return ["own", f]
	return first.to_html()


## `flat` (a simple polygon, planar UV) cut on lines at multiples of `cell`: the pieces.
## Lines nearer than MIN_PIECE of a cell to the polygon's extent are skipped.
static func _grid_pieces(flat: PackedVector2Array, cell: float) -> Array[PackedVector2Array]:
	var lo := flat[0]
	var hi := flat[0]
	for p in flat:
		lo = lo.min(p)
		hi = hi.max(p)
	var margin := cell * MIN_PIECE
	var xs := _cuts(lo.x, hi.x, cell, margin)
	var ys := _cuts(lo.y, hi.y, cell, margin)
	if xs.size() == 2 and ys.size() == 2:
		return [flat] as Array[PackedVector2Array]
	var out: Array[PackedVector2Array] = []
	for i in xs.size() - 1:
		for j in ys.size() - 1:
			var rect := PackedVector2Array([Vector2(xs[i], ys[j]), Vector2(xs[i + 1], ys[j]),
				Vector2(xs[i + 1], ys[j + 1]), Vector2(xs[i], ys[j + 1])])
			for piece in Geometry2D.intersect_polygons(flat, rect):
				if piece.size() >= 3 and absf(_area(piece)) > 1e-6:
					out.append(piece)
	return out


## Cut positions from `lo` to `hi` (both ends included; the outer ones a hair outside so
## the polygon's own border stays its own).
static func _cuts(lo: float, hi: float, cell: float, margin: float) -> PackedFloat32Array:
	var out := PackedFloat32Array([lo - 1.0])
	var k := ceili((lo + margin) / cell)
	while k * cell <= hi - margin:
		out.append(k * cell)
		k += 1
	out.append(hi + 1.0)
	return out


static func _area(pts: PackedVector2Array) -> float:
	var a := 0.0
	for i in pts.size():
		a += pts[i].cross(pts[(i + 1) % pts.size()])
	return a * 0.5


## Inserts each of `candidates` into every face edge it lies on (spatial hash `cell`).
static func _stitch(verts: PackedVector3Array, faces: Array[PackedInt32Array], candidates: Array, cell: float) -> void:
	if candidates.is_empty():
		return
	var grid := {}
	for c: int in candidates:
		var key := Vector3i((verts[c] / cell).floor())
		if not grid.has(key):
			grid[key] = []
		grid[key].append(c)
	for f in faces.size():
		var poly := faces[f]
		var out := PackedInt32Array()
		var grew := false
		for k in poly.size():
			var a := poly[k]
			var bb := poly[(k + 1) % poly.size()]
			out.append(a)
			var pa := verts[a]
			var ab := verts[bb] - pa
			var len2 := ab.length_squared()
			if len2 < 1e-10:
				continue
			var lo := Vector3i((pa.min(verts[bb]) / cell).floor()) - Vector3i.ONE
			var hi := Vector3i((pa.max(verts[bb]) / cell).floor()) + Vector3i.ONE
			var hits := []
			for x in range(lo.x, hi.x + 1):
				for y in range(lo.y, hi.y + 1):
					for z in range(lo.z, hi.z + 1):
						for c: int in grid.get(Vector3i(x, y, z), []):
							if c == a or c == bb or c in poly:
								continue
							var t := (verts[c] - pa).dot(ab) / len2
							if t <= 1e-4 or t >= 1.0 - 1e-4:
								continue
							if (pa + ab * t).distance_squared_to(verts[c]) > 1e-6:
								continue
							hits.append([t, c])
			if hits.is_empty():
				continue
			hits.sort_custom(func(p, q): return p[0] < q[0])
			for h in hits:
				out.append(h[1])
			grew = true
		if grew:
			faces[f] = out


## Masks for the new faces: kept as they were on unchanged faces, else resampled from the
## old faces each new face was made from (whichever covers each texel), at most `max_px`
## a side.
static func _masks(b: LevelBrush, count: int, parent: PackedInt32Array, members: Array, unchanged: Dictionary,
		old_masks: Dictionary, old_flat: Dictionary, old_rect: Dictionary, density: float, max_px := 256) -> Dictionary:
	var out := {}
	if old_masks.is_empty():
		return out
	for i in count:
		if unchanged.has(i):
			for layer in LevelData.MAX_LAYERS:
				var img: Image = old_masks.get(Vector2i(unchanged[i], layer))
				if img:
					out[Vector2i(i, layer)] = img
			continue
		var rect := b.get_face_planar_rect(i)
		# The old faces under this one, and the layers they paint.
		var under := []
		var layers := {}
		for f: int in members[parent[i]]:
			if old_flat.has(f) and (old_rect[f] as Rect2).grow(1e-3).intersects(rect):
				under.append(f)
				for layer in LevelData.MAX_LAYERS:
					if old_masks.has(Vector2i(f, layer)):
						layers[layer] = true
		if layers.is_empty():
			continue
		var size := Vector2i(clampi(ceili(rect.size.x * density), 4, max_px), clampi(ceili(rect.size.y * density), 4, max_px))
		var imgs := {}
		for layer: int in layers:
			imgs[layer] = Image.create(size.x, size.y, false, Image.FORMAT_L8)
		# Each old face fills the texels over its own bounds (only those: a merged face can
		# have hundreds of parts); a rectangular one needs no inside test.
		var texel := rect.size / Vector2(size)
		for f: int in under:
			var orect: Rect2 = old_rect[f]
			var srcs := []
			for layer: int in layers:
				srcs.append([layer, old_masks.get(Vector2i(f, layer))])
			var lo := ((orect.position - rect.position) / texel).floor()
			var hi := ((orect.end - rect.position) / texel).ceil()
			var square := _is_rect(old_flat[f], orect)
			for y in range(maxi(int(lo.y), 0), mini(int(hi.y), size.y)):
				for x in range(maxi(int(lo.x), 0), mini(int(hi.x), size.x)):
					var uv := rect.position + (Vector2(x, y) + Vector2(0.5, 0.5)) * texel
					if not orect.has_point(uv) or (not square and not Geometry2D.is_point_in_polygon(uv, old_flat[f])):
						continue
					for pair in srcs:
						var src: Image = pair[1]
						if src:
							var t := ((uv - orect.position) / orect.size.max(Vector2(0.0001, 0.0001)) * Vector2(src.get_size())).floor()
							imgs[pair[0]].set_pixel(x, y, src.get_pixel(clampi(int(t.x), 0, src.get_width() - 1),
								clampi(int(t.y), 0, src.get_height() - 1)))
		for layer: int in imgs:
			out[Vector2i(i, layer)] = imgs[layer]
	return out


## Whether polygon `pts` is exactly the rectangle `r` (its corners, maybe more on its sides).
static func _is_rect(pts: PackedVector2Array, r: Rect2) -> bool:
	for p in pts:
		var on_x := absf(p.x - r.position.x) < 1e-4 or absf(p.x - r.end.x) < 1e-4
		var on_y := absf(p.y - r.position.y) < 1e-4 or absf(p.y - r.end.y) < 1e-4
		if not (on_x or on_y):
			return false
	var area := 0.0
	for i in pts.size():
		area += pts[i].cross(pts[(i + 1) % pts.size()])
	return absf(absf(area) * 0.5 - r.get_area()) < 1e-4
