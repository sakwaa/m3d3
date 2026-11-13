@tool
class_name ChunkSplit
extends RefCounted
## Cuts the bake's always-drawn polygons along the chunk grid. Each polygon goes in the chunk
## of its middle, and the Blender dissolve leaves faces tens of metres long (a perimeter wall,
## a long roof): uncut, one chunk's mesh would reach across the level and the engine, which
## culls whole meshes, would draw it from everywhere. Ground and distance-swapped polygons
## are cut elsewhere (GroundLOD.split_to_cells; LOD bands go by brush), exact-UV polygons
## (set pieces, fences) stay whole. Cut points sit exactly on the cut edge (a neighbour
## sharing that edge and crossing the same line gets the same point) and their corner data
## is blended along it.

const SNAP := 0.002


static func split(polys: Array[Dictionary], sources: Array[Dictionary], grid: Dictionary) -> Array[Dictionary]:
	var origin: Vector3 = grid.origin
	var size: Vector2 = grid.size
	var out: Array[Dictionary] = []
	for poly in polys:
		var src: Dictionary = sources[poly.src]
		if poly.get("lod", LevelBrush.LOD_ALWAYS) != LevelBrush.LOD_ALWAYS or not (poly.exact_uvs as PackedVector2Array).is_empty() \
				or GroundLOD.is_ground(poly, src):
			out.append(poly)
			continue
		var pts := GroundLOD.world_pts(poly, src)
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for p in pts:
			lo = lo.min(Vector2(p.x, p.z))
			hi = hi.max(Vector2(p.x, p.z))
		var c0 := Vector2i(floori((lo.x - origin.x + SNAP) / size.x), floori((lo.y - origin.z + SNAP) / size.y))
		var c1 := Vector2i(floori((hi.x - origin.x - SNAP) / size.x), floori((hi.y - origin.z - SNAP) / size.y))
		if c0.x >= c1.x and c0.y >= c1.y:
			out.append(poly)
			continue
		out.append_array(_cut(poly, src, pts, origin, size, c0, c1))
	return out


## `poly`'s pieces, one per chunk cell it crosses.
static func _cut(poly: Dictionary, src: Dictionary, pts: PackedVector3Array, origin: Vector3, size: Vector2,
		c0: Vector2i, c1: Vector2i) -> Array[Dictionary]:
	var n: Vector3 = (poly.normal as Vector3).normalized()
	var u := (Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).cross(n).normalized()
	var v := n.cross(u)
	var p0 := pts[0]
	var outline := PackedVector2Array()
	for p in pts:
		outline.append(Vector2((p - p0).dot(u), (p - p0).dot(v)))
	var area := GroundLOD._area(outline)
	var blo := Vector2(INF, INF)
	var bhi := Vector2(-INF, -INF)
	for q in outline:
		blo = blo.min(q)
		bhi = bhi.max(q)
	blo -= Vector2.ONE
	bhi += Vector2.ONE
	var inv: Transform3D = src.xf.affine_inverse()
	var verts: PackedVector3Array = src.verts
	var out: Array[Dictionary] = []
	for cx in range(c0.x, c1.x + 1):
		for cz in range(c0.y, c1.y + 1):
			var x0 := origin.x + cx * size.x
			var z0 := origin.z + cz * size.y
			# The cell's column on the polygon's plane: a box clipped by its four sides.
			var region := PackedVector2Array([blo, Vector2(bhi.x, blo.y), bhi, Vector2(blo.x, bhi.y)])
			for side in [[Vector3(1, 0, 0), x0], [Vector3(-1, 0, 0), -(x0 + size.x)], [Vector3(0, 0, 1), z0], [Vector3(0, 0, -1), -(z0 + size.y)]]:
				region = _clip_half(region, side[0], side[1], p0, u, v)
				if region.size() < 3:
					break
			if region.size() < 3:
				continue
			for raw: PackedVector2Array in Geometry2D.intersect_polygons(outline, region):
				if raw.size() < 3 or absf(GroundLOD._area(raw)) < 0.01:
					continue
				var piece := _exact(raw, outline)
				if signf(GroundLOD._area(piece)) != signf(area):
					piece.reverse()
				var np := poly.duplicate()
				var npts := PackedVector3Array()
				var ids := PackedInt32Array()
				var cc := PackedColorArray()
				var kcs := []
				for s in poly.key_colors.size():
					kcs.append(PackedColorArray())
				for q in piece:
					var w := _edge_weights(outline, pts, q, x0, z0, size)
					var p: Vector3
					if w.is_empty():
						w = GroundLOD._weights(outline, q)
						p = p0 + u * q.x + v * q.y
					else:
						p = Vector3.ZERO
						for i in w:
							p += pts[i] * w[i]
					npts.append(p)
					ids.append(verts.size())
					verts.append(inv * p)
					cc.append(GroundLOD._blend(poly.corner_colors, w))
					for s in poly.key_colors.size():
						kcs[s].append(GroundLOD._blend(poly.key_colors[s], w))
				np.pts = npts
				np.ids = ids
				np.corner_colors = cc
				np.key_colors = kcs
				np.cell = Vector2i(cx, cz)
				out.append(np)
	src.verts = verts
	return out


## `region` (plane coords) where world `axis` · p >= `d`, p = p0 + u x + v y.
static func _clip_half(region: PackedVector2Array, axis: Vector3, d: float, p0: Vector3, u: Vector3, v: Vector3) -> PackedVector2Array:
	var a := Vector2(axis.dot(u), axis.dot(v))
	var b := axis.dot(p0) - d
	if a.length() < 1e-6:
		return region if b >= -SNAP else PackedVector2Array()
	var out := PackedVector2Array()
	for i in region.size():
		var p := region[i]
		var q := region[(i + 1) % region.size()]
		var fp := a.dot(p) + b
		var fq := a.dot(q) + b
		if fp >= 0.0:
			out.append(p)
		if (fp >= 0.0) != (fq >= 0.0):
			out.append(p.lerp(q, fp / (fp - fq)))
	return out


## The clipper's piece made exact: corners near the outline's back on them, outline corners
## lying on a piece edge back in (the clipper rounds and drops in-line corners).
static func _exact(raw: PackedVector2Array, outline: PackedVector2Array) -> PackedVector2Array:
	var fixed := PackedVector2Array()
	for q in raw:
		for o in outline:
			if o.distance_to(q) < SNAP:
				q = o
				break
		if fixed.is_empty() or fixed[-1].distance_to(q) > 1e-6:
			fixed.append(q)
	if fixed.size() > 1 and fixed[0].distance_to(fixed[-1]) <= 1e-6:
		fixed.remove_at(fixed.size() - 1)
	var out := PackedVector2Array()
	for i in fixed.size():
		var a := fixed[i]
		var c := fixed[(i + 1) % fixed.size()]
		out.append(a)
		var len := a.distance_to(c)
		if len < SNAP:
			continue
		var dir := (c - a) / len
		var on := []
		for o in outline:
			var t := (o - a).dot(dir)
			if t > SNAP * 0.5 and t < len - SNAP * 0.5 and (a + dir * t).distance_to(o) < SNAP * 0.5:
				on.append([t, o])
		on.sort_custom(func(x, y): return x[0] < y[0])
		for e in on:
			if out[-1].distance_to(e[1]) > 1e-6:
				out.append(e[1])
	return out


## Weights for a piece corner on the outline: its corner, or the ends of its edge with the
## fraction from where the edge (in world space) crosses the nearest cell line, so both faces
## sharing the edge cut it at the same point. Empty if inside.
static func _edge_weights(outline: PackedVector2Array, pts: PackedVector3Array, q: Vector2, x0: float, z0: float,
		size: Vector2) -> Dictionary:
	for i in outline.size():
		if outline[i].distance_to(q) < 1e-5:
			return {i: 1.0}
	for i in outline.size():
		var j := (i + 1) % outline.size()
		var d := outline[j] - outline[i]
		var l2 := d.length_squared()
		if l2 < 1e-12:
			continue
		var t := (q - outline[i]).dot(d) / l2
		if t <= 0.0 or t >= 1.0 or (outline[i] + d * t).distance_to(q) > 1e-3:
			continue
		var a := pts[i]
		var c := pts[j]
		var p := a.lerp(c, t)
		var best := INF
		for line in [[0, x0], [0, x0 + size.x], [2, z0], [2, z0 + size.y]]:
			var k: int = line[0]
			var den := c[k] - a[k]
			if absf(den) < 1e-6 or absf(p[k] - line[1]) > SNAP or absf(p[k] - line[1]) >= best:
				continue
			best = absf(p[k] - line[1])
			# Ends in a fixed order: the same edge seen from either face gives the same point.
			if a < c:
				t = (line[1] - a[k]) / den
			else:
				t = 1.0 - (line[1] - c[k]) / (a[k] - c[k])
		return {i: 1.0 - t, j: t}
	return {}
