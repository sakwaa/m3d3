@tool
extends RefCounted
## The build's coarse ground collision: the ground's collision triangles simplified on their
## own (the drawn ground keeps every vertex for its lighting), by collapsing vertices into a
## neighbour while every point removed so far stays within TOLERANCE metres (vertically) of
## the new surface. Works on the walkable part as a height field: vertices on the edge of the
## ground (holes under houses, the level's rim, where one Surface meets another) or touching
## a steep triangle stay put, so the collision still meets walls, steps and the other
## Surfaces exactly.

## Project setting: metres the ground's collision may stray from the drawn ground.
const TOLERANCE_SETTING := "n64/build/ground_collision_tolerance"
const TOLERANCE := 0.04
## Triangles flatter than this (normal.y) count as height field.
const WALKABLE := 0.25


static func tolerance() -> float:
	return float(ProjectSettings.get_setting(TOLERANCE_SETTING, TOLERANCE))


## `soup`: triangles (3 points each). Returns the simplified triangles.
static func simplify(soup: PackedVector3Array, eps := tolerance()) -> PackedVector3Array:
	if eps <= 0.0 or soup.size() < 6:
		return soup
	# Weld (1 mm).
	var pos := PackedVector3Array()
	var weld := {}
	var tris: Array[Vector3i] = []
	for t in range(0, soup.size() - 2, 3):
		var ids := Vector3i.ZERO
		for k in 3:
			var p := soup[t + k]
			var key := Vector3i((p * 1000.0).round())
			if not weld.has(key):
				weld[key] = pos.size()
				pos.append(p)
			ids[k] = weld[key]
		if ids.x != ids.y and ids.y != ids.z and ids.x != ids.z:
			tris.append(ids)
	# Merged polygons leave T-junctions (a neighbour's vertex on an edge): split those
	# triangles there, so the ground is one connected surface again.
	var split := _split_t_junctions(pos, tris)
	pos = split.pos
	tris = split.tris
	var alive: Array[bool] = []
	alive.resize(tris.size())
	alive.fill(true)
	var witnesses := []  # per triangle: points removed under it (PackedVector3Array)
	# Seeded with each triangle's centre and edge midpoints, so a collapse that cuts across a
	# ridge or a dip between the vertices shows up too.
	for t in tris.size():
		var a := pos[tris[t].x]
		var b := pos[tris[t].y]
		var c := pos[tris[t].z]
		witnesses.append(PackedVector3Array([(a + b + c) / 3.0, (a + b) * 0.5, (b + c) * 0.5, (c + a) * 0.5]))
	var around := []  # vertex -> Array of triangle indices
	around.resize(pos.size())
	for v in pos.size():
		around[v] = []
	var edges := {}  # Vector2i(min, max) -> use count
	for t in tris.size():
		var tri := tris[t]
		for k in 3:
			around[tri[k]].append(t)
			var a := tri[k]
			var b := tri[(k + 1) % 3]
			var e := Vector2i(mini(a, b), maxi(a, b))
			edges[e] = edges.get(e, 0) + 1
	# Fixed: touching a steep triangle or a non-manifold edge, or a corner of the ground's edge
	# (holes under houses, the level's rim, where one Surface meets another). A vertex in a
	# straight run of edge may only slide along it (`slide`: its two neighbours on the edge).
	var locked: Array[bool] = []
	locked.resize(pos.size())
	locked.fill(false)
	var border := {}  # vertex -> neighbours along the ground's edge
	for e: Vector2i in edges:
		if edges[e] > 2:
			locked[e.x] = true
			locked[e.y] = true
		elif edges[e] == 1:
			border.get_or_add(e.x, []).append(e.y)
			border.get_or_add(e.y, []).append(e.x)
	var slide := {}
	for v: int in border:
		var nb: Array = border[v]
		var straight := nb.size() == 2 and _seg_dist(pos[v], pos[nb[0]], pos[nb[1]]) < 1e-3 \
			and (pos[nb[0]] - pos[v]).dot(pos[nb[1]] - pos[v]) < 0.0
		if straight:
			slide[v] = nb
		else:
			locked[v] = true
	for t in tris.size():
		if absf(_normal(pos, tris[t]).y) < WALKABLE:
			for k in 3:
				locked[tris[t][k]] = true
	# Collapse passes until nothing more goes.
	var changed := true
	while changed:
		changed = false
		for u in pos.size():
			if locked[u] or around[u].is_empty():
				continue
			var ring := {}
			if slide.has(u):
				for v: int in slide[u]:
					ring[v] = true
			else:
				for t: int in around[u]:
					for k in 3:
						if tris[t][k] != u:
							ring[tris[t][k]] = true
			var best := -1
			var best_err := INF
			for v: int in ring:
				if not _link_ok(tris, around, u, v, 1 if slide.has(u) else 2):
					continue
				var err := _collapse_error(pos, tris, witnesses, around[u], u, v, eps)
				if err < best_err:
					best_err = err
					best = v
			if best < 0:
				continue
			_collapse(pos, tris, alive, witnesses, around, u, best)
			if slide.has(u):
				# The other neighbour along the edge now meets `best`.
				for w: int in slide[u]:
					if w != best and slide.has(w):
						slide[w][slide[w].find(u)] = best
					if w != best and slide.has(best):
						slide[best][slide[best].find(u)] = w
				slide.erase(u)
			changed = true
	var out := PackedVector3Array()
	for t in tris.size():
		if alive[t]:
			for k in 3:
				out.append(pos[tris[t][k]])
	return out


## `tris` with every vertex that lies inside one of their edges made a corner (the triangle
## fanned out from the corner opposite that edge).
static func _split_t_junctions(pos: PackedVector3Array, tris: Array[Vector3i]) -> Dictionary:
	const CELL := 1.0
	var grid := {}
	for v in pos.size():
		var c := Vector2i(floori(pos[v].x / CELL), floori(pos[v].z / CELL))
		var list: PackedInt32Array = grid.get(c, PackedInt32Array())
		list.append(v)
		grid[c] = list
	var out: Array[Vector3i] = []
	for tri in tris:
		var corners: Array[int] = [tri.x]
		for k in 3:
			var a := tri[k]
			var b := tri[(k + 1) % 3]
			var pa := pos[a]
			var pb := pos[b]
			var ab := pb - pa
			var len2 := ab.length_squared()
			var on := []  # [t along the edge, vertex]
			var lo := Vector2i(floori(minf(pa.x, pb.x) / CELL), floori(minf(pa.z, pb.z) / CELL))
			var hi := Vector2i(floori(maxf(pa.x, pb.x) / CELL), floori(maxf(pa.z, pb.z) / CELL))
			for cx in range(lo.x, hi.x + 1):
				for cz in range(lo.y, hi.y + 1):
					for v: int in grid.get(Vector2i(cx, cz), PackedInt32Array()):
						if v == a or v == b:
							continue
						var t := (pos[v] - pa).dot(ab) / len2
						if t <= 1e-4 or t >= 1.0 - 1e-4:
							continue
						if (pa + ab * t).distance_squared_to(pos[v]) < 1e-6:
							on.append([t, v])
			on.sort_custom(func(x, y): return x[0] < y[0])
			for e in on:
				corners.append(e[1])
			if k < 2:
				corners.append(tri[k + 1])
		if corners.size() == 3:
			out.append(tri)
			continue
		# Fan from a corner whose two edges hold no extra points (only its opposite edge was
		# split); failing that, from a new vertex in the middle (the collapses remove it again).
		var start := -1
		for i in corners.size():
			var n := corners.size()
			if _is_corner(tri, corners[i]) and _is_corner(tri, corners[(i - 1 + n) % n]) and _is_corner(tri, corners[(i + 1) % n]):
				start = i
				break
		if start >= 0:
			for i in range(1, corners.size() - 1):
				var f := Vector3i(corners[start], corners[(start + i) % corners.size()], corners[(start + i + 1) % corners.size()])
				if absf(_area_xz(pos[f.x], pos[f.y], pos[f.z])) > 1e-6:
					out.append(f)
		else:
			var mid := pos.size()
			pos.append((pos[tri.x] + pos[tri.y] + pos[tri.z]) / 3.0)
			for i in corners.size():
				out.append(Vector3i(mid, corners[i], corners[(i + 1) % corners.size()]))
	return {pos = pos, tris = out}


static func _seg_dist(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-12), 0.0, 1.0)
	return (a + ab * t).distance_to(p)


static func _is_corner(tri: Vector3i, v: int) -> bool:
	return v == tri.x or v == tri.y or v == tri.z


## Edge u-v collapses cleanly: u and v share exactly the two neighbours across it (else the
## collapse would pinch the surface).
static func _link_ok(tris: Array[Vector3i], around: Array, u: int, v: int, want: int) -> bool:
	var nu := {}
	for t: int in around[u]:
		for k in 3:
			nu[tris[t][k]] = true
	var shared := 0
	var seen := {}
	for t: int in around[v]:
		for k in 3:
			var w := tris[t][k]
			if w != u and w != v and nu.has(w) and not seen.has(w):
				seen[w] = true
				shared += 1
	return shared == want


static func _normal(pos: PackedVector3Array, tri: Vector3i) -> Vector3:
	return (pos[tri.y] - pos[tri.x]).cross(pos[tri.z] - pos[tri.x]).normalized()


## Signed area of the triangle seen from above.
static func _area_xz(a: Vector3, b: Vector3, c: Vector3) -> float:
	return (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x)


## The worst vertical miss of `u`'s removed points once `u` is moved onto `v`, or INF when
## the collapse folds a triangle over or strays more than `eps`.
static func _collapse_error(pos: PackedVector3Array, tris: Array[Vector3i], witnesses: Array, fan: Array,
		u: int, v: int, eps: float) -> float:
	var after: Array[Vector3i] = []
	for t: int in fan:
		var tri := tris[t]
		if tri.x == v or tri.y == v or tri.z == v:
			continue  # collapses away
		var moved := Vector3i(v if tri.x == u else tri.x, v if tri.y == u else tri.y, v if tri.z == u else tri.z)
		var before := _area_xz(pos[tri.x], pos[tri.y], pos[tri.z])
		var now := _area_xz(pos[moved.x], pos[moved.y], pos[moved.z])
		# Same way round seen from above, and not a sliver.
		if signf(now) != signf(before) or absf(now) < 1e-4 or absf(_normal(pos, moved).y) < WALKABLE:
			return INF
		after.append(moved)
	var points := PackedVector3Array([pos[u]])
	for t: int in fan:
		points.append_array(witnesses[t])
	var worst := 0.0
	for p in points:
		var d := _height_miss(pos, after, p)
		if d > eps:
			return INF
		worst = maxf(worst, d)
	return worst


## Vertical distance from `p` to the triangle under it (INF: none).
static func _height_miss(pos: PackedVector3Array, tris: Array[Vector3i], p: Vector3) -> float:
	for tri in tris:
		var a := pos[tri.x]
		var b := pos[tri.y]
		var c := pos[tri.z]
		var area := _area_xz(a, b, c)
		var w0 := _area_xz(b, c, p) / area
		var w1 := _area_xz(c, a, p) / area
		var w2 := 1.0 - w0 - w1
		if w0 >= -1e-4 and w1 >= -1e-4 and w2 >= -1e-4:
			return absf(a.y * w0 + b.y * w1 + c.y * w2 - p.y)
	return INF


static func _collapse(pos: PackedVector3Array, tris: Array[Vector3i], alive: Array[bool], witnesses: Array, around: Array,
		u: int, v: int) -> void:
	var fan: Array = around[u].duplicate()
	var points := PackedVector3Array([pos[u]])
	var kept: Array[int] = []
	for t: int in fan:
		points.append_array(witnesses[t])
		witnesses[t] = PackedVector3Array()
		var tri := tris[t]
		if tri.x == v or tri.y == v or tri.z == v:
			alive[t] = false
			for k in 3:
				var w := tri[k]
				if w != u:
					around[w].erase(t)
			continue
		tris[t] = Vector3i(v if tri.x == u else tri.x, v if tri.y == u else tri.y, v if tri.z == u else tri.z)
		around[v].append(t)
		kept.append(t)
	around[u] = []
	# The removed points go to the triangle now under them.
	for p in points:
		for t in kept:
			var tri := tris[t]
			var a := pos[tri.x]
			var b := pos[tri.y]
			var c := pos[tri.z]
			var area := _area_xz(a, b, c)
			var w0 := _area_xz(b, c, p) / area
			var w1 := _area_xz(c, a, p) / area
			if w0 >= -1e-4 and w1 >= -1e-4 and 1.0 - w0 - w1 >= -1e-4:
				var wl: PackedVector3Array = witnesses[t]
				wl.append(p)
				witnesses[t] = wl
				break
