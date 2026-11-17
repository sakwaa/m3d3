@tool
class_name CrackClose
extends RefCounted
## Closes T-junction cracks in a bake: where a vertex of one baked surface lies on the middle
## of another triangle's edge (neighbouring brushes, cells or materials cut differently), the
## GPU draws the two edges slightly apart and a hairline of sky shows through. Each such
## triangle is split: its outline gains those points and it's re-filled as a fan round its
## middle (a new vertex, so no slivers), with every vertex attribute (normal, UVs, colour,
## lighting keys) interpolated. Points only come from surfaces drawn at the same time: near
## and far stand-ins don't split each other.

const ON_EDGE := 0.002  # metres a point may sit off an edge and still be on it
const CELL := 1.0
## Off: the bake skips the pass (tests trace where cracks come from).
static var enabled := true
## Walls too (not just the ground): costs many more triangles for cracks rarely seen.
static var walls := false
## Boxes (level space) where walls are split as well: round passage and door openings, where
## the carve's and the trim's cuts meet the corridor's edges and a crack shows the sky
## behind a thin wall as sparkles along the opening.
static var wall_zones: Array[AABB] = []


## `entries`: [[surface arrays, visibility range (Vector2: begin, end)], ...], edited in place.
## Returns how many triangles were split.
static func close(entries: Array) -> int:
	if not enabled:
		return 0
	var near := _points(entries, func(r: Vector2): return r.x <= 0.0)
	var far := _points(entries, func(r: Vector2): return r.y <= 0.0)
	var split := 0
	for e in entries:
		var r: Vector2 = e[1]
		var grid: Dictionary = far if r.x > 0.0 else near
		if r == Vector2.ZERO:
			split += _close_surface(e[0], far)
		split += _close_surface(e[0], grid)
	return split


## Welded points (1 mm) of the surfaces whose range passes `want`, in a CELL grid, by the
## kind of triangle using them ({true: ground (facing up), false: the rest}): a ground edge
## only splits for ground points, a wall's for wall points (a wall's foot meeting the ground
## isn't a crack worth more triangles).
static func _points(entries: Array, want: Callable) -> Dictionary:
	var seen := {}
	var grids := {true: {}, false: {}}
	for e in entries:
		if not want.call(e[1]):
			continue
		var v: PackedVector3Array = e[0][Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = e[0][Mesh.ARRAY_INDEX]
		for t in range(0, idx.size(), 3):
			var up := _is_up(v[idx[t]], v[idx[t + 1]], v[idx[t + 2]])
			for k in 3:
				var p := v[idx[t + k]]
				var key := [up, Vector3i(roundi(p.x * 1000.0), roundi(p.y * 1000.0), roundi(p.z * 1000.0))]
				if seen.has(key):
					continue
				seen[key] = true
				grids[up].get_or_add(Vector3i(floori(p.x / CELL), floori(p.y / CELL), floori(p.z / CELL)), []).append(p)
	return grids


static func _is_up(a: Vector3, b: Vector3, c: Vector3) -> bool:
	var n := (b - a).cross(c - a)
	return n.length() > 1e-10 and absf(n.normalized().y) > 0.7  # (either winding)


## Splits the triangles of one surface's `arrays` that have points of `grid` on their edges.
static func _close_surface(arrays: Array, grids: Dictionary) -> int:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if idx.is_empty():
		return 0
	var out_idx := PackedInt32Array()
	var adds := []  # new vertices: [[vertex, weight], ...] (weights summing to 1)
	var count := 0
	var edge_cache := {}  # ground? -> Vector2i(a, b) -> fractions along a -> b
	for t in range(0, idx.size(), 3):
		var tri := [idx[t], idx[t + 1], idx[t + 2]]
		var up := _is_up(verts[tri[0]], verts[tri[1]], verts[tri[2]])
		var zoned := _in_zones(verts[tri[0]], verts[tri[1]], verts[tri[2]])
		if not up and not walls and not zoned:
			out_idx.append_array(PackedInt32Array(tri))
			continue
		var grid: Dictionary = grids[up]
		var cache: Dictionary = edge_cache.get_or_add(up, {})
		# Round an opening, ground and walls split for each other's points too (a corridor's
		# ceiling, facing down, meets the wall above the opening).
		var other: Dictionary = grids[not up]
		var other_cache: Dictionary = edge_cache.get_or_add(&"other_up" if up else &"other_wall", {})
		var ring := []  # [[vertex index or -1, [[vertex, weight]...]]] round the triangle
		var any := false
		for k in 3:
			var a: int = tri[k]
			var b: int = tri[(k + 1) % 3]
			ring.append([a, [[a, 1.0]]])
			var on := _on_edge(verts[a], verts[b], grid, cache, a, b)
			if zoned:
				var more := _on_edge(verts[a], verts[b], other, other_cache, a, b)
				if not more.is_empty():
					on = on + more
					on.sort()
					var kept := []
					var len := verts[a].distance_to(verts[b])
					for f in on:
						if kept.is_empty() or (f - kept[-1]) * len > 0.001:
							kept.append(f)
					on = kept
			for hit in on:
				ring.append([-1, [[a, 1.0 - hit], [b, hit]]])
				any = true
		if not any:
			out_idx.append_array(PackedInt32Array(tri))
			continue
		count += 1
		# Splits on one edge only (the usual): a fan from the opposite corner, one triangle more
		# per point, no new vertex in the middle.
		var split_edges := {}
		var e_at := -1
		for r in ring:
			if r[0] >= 0:
				e_at += 1
			else:
				split_edges[e_at] = true
		if split_edges.size() == 1:
			var e: int = split_edges.keys()[0]
			var apex: int = tri[(e + 2) % 3]
			var chain := []  # the split edge, corner to corner, with its points
			var on := false
			for r in ring + ring:
				if r[0] == tri[e]:
					on = true
					chain = [r[0]]
					continue
				if on:
					if r[0] >= 0:
						chain.append(r[0])
						break
					chain.append(verts.size() + adds.size())
					adds.append(r[1])
			for i in chain.size() - 1:
				out_idx.append_array(PackedInt32Array([apex, chain[i], chain[i + 1]]))
			continue
		# Splits on several edges: a fan round the middle (a new vertex at the centroid).
		var ids := []
		for r in ring:
			if r[0] >= 0:
				ids.append(r[0])
			else:
				ids.append(verts.size() + adds.size())
				adds.append(r[1])
		var mid := verts.size() + adds.size()
		adds.append([[tri[0], 1.0 / 3.0], [tri[1], 1.0 / 3.0], [tri[2], 1.0 / 3.0]])
		for i in ids.size():
			out_idx.append_array(PackedInt32Array([mid, ids[i], ids[(i + 1) % ids.size()]]))
	if count == 0:
		return 0
	_append_vertices(arrays, adds)
	arrays[Mesh.ARRAY_INDEX] = out_idx
	return count


static func _in_zones(a: Vector3, b: Vector3, c: Vector3) -> bool:
	if wall_zones.is_empty():
		return false
	var box := AABB(a, Vector3.ZERO).expand(b).expand(c)
	for z in wall_zones:
		if z.intersects(box):
			return true
	return false


## Fractions (0..1, sorted) along a -> b where points of `grid` sit on the edge.
static func _on_edge(a: Vector3, b: Vector3, grid: Dictionary, cache: Dictionary, ia: int, ib: int) -> Array:
	var key := Vector2i(ia, ib)
	if cache.has(key):
		return cache[key]
	var rev := Vector2i(ib, ia)
	if cache.has(rev):
		var r: Array = cache[rev].map(func(x): return 1.0 - x)
		r.reverse()
		cache[key] = r
		return r
	var out := []
	var d := b - a
	var len := d.length()
	if len > 0.01:
		var lo := Vector3i(floori(minf(a.x, b.x) / CELL), floori(minf(a.y, b.y) / CELL), floori(minf(a.z, b.z) / CELL))
		var hi := Vector3i(floori(maxf(a.x, b.x) / CELL), floori(maxf(a.y, b.y) / CELL), floori(maxf(a.z, b.z) / CELL))
		# (Long edges: walk the cells along the line, not the whole box.)
		var steps := maxi(ceili(len / (CELL * 0.5)), 1)
		var cells := {}
		for s in steps + 1:
			var p := a + d * (float(s) / steps)
			var c := Vector3i(floori(p.x / CELL), floori(p.y / CELL), floori(p.z / CELL))
			for dx in [-1, 0, 1]:
				for dy in [-1, 0, 1]:
					for dz in [-1, 0, 1]:
						var n: Vector3i = c + Vector3i(dx, dy, dz)
						if n.x >= lo.x - 1 and n.x <= hi.x + 1 and n.y >= lo.y - 1 and n.y <= hi.y + 1 and n.z >= lo.z - 1 and n.z <= hi.z + 1:
							cells[n] = true
		var dir := d / len
		for c in cells:
			for p: Vector3 in grid.get(c, []):
				var along := (p - a).dot(dir)
				if along <= ON_EDGE or along >= len - ON_EDGE:
					continue
				if (a + dir * along).distance_to(p) <= ON_EDGE:
					out.append(along / len)
		out.sort()
		# (Points 1 mm apart: one.)
		var kept := []
		for f in out:
			if kept.is_empty() or (f - kept[-1]) * len > 0.001:
				kept.append(f)
		out = kept
	cache[key] = out
	return out


## Appends vertices made as weighted mixes of existing ones to every vertex array.
static func _append_vertices(arrays: Array, adds: Array) -> void:
	for slot in Mesh.ARRAY_MAX:
		if slot == Mesh.ARRAY_INDEX or arrays[slot] == null:
			continue
		var a = arrays[slot]
		if a is PackedVector3Array:
			for w in adds:
				var v := Vector3.ZERO
				for p in w:
					v += a[p[0]] * p[1]
				a.append(v.normalized() if slot == Mesh.ARRAY_NORMAL and v.length() > 0.0 else v)
		elif a is PackedVector2Array:
			for w in adds:
				var v := Vector2.ZERO
				for p in w:
					v += a[p[0]] * p[1]
				a.append(v)
		elif a is PackedColorArray:
			for w in adds:
				var v := Color(0, 0, 0, 0)
				for p in w:
					v += a[p[0]] * p[1]
				a.append(v)
		elif a is PackedByteArray:
			# Custom channels: 4 bytes (RGBA8) per vertex.
			for w in adds:
				for ch in 4:
					var v := 0.0
					for p in w:
						v += a[p[0] * 4 + ch] * p[1]
					a.append(clampi(roundi(v), 0, 255))
		elif a is PackedFloat32Array:
			var n: int = a.size() / maxi((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() - adds.size(), 1)
			for w in adds:
				for ch in n:
					var v := 0.0
					for p in w:
						v += a[p[0] * n + ch] * p[1]
					a.append(v)
		arrays[slot] = a
