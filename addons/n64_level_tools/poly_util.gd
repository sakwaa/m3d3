class_name PolyUtil
extends RefCounted
## Polygon helpers shared by brushes and the baker.
## Polygons are stored counter-clockwise when viewed from the front (right-hand normal).


## Newell's method: robust normal for any (even slightly non-planar) polygon.
static func newell_normal(pts: PackedVector3Array) -> Vector3:
	var n := Vector3.ZERO
	var c := pts.size()
	for i in c:
		var a := pts[i]
		var b := pts[(i + 1) % c]
		n.x += (a.y - b.y) * (a.z + b.z)
		n.y += (a.z - b.z) * (a.x + b.x)
		n.z += (a.x - b.x) * (a.y + b.y)
	if n.length_squared() < 1e-12:
		return Vector3.ZERO
	return n.normalized()


## Ear-clipping triangulation. Returns a flat list of indices into `pts`,
## each triangle wound counter-clockwise around `normal`.
static func triangulate(pts: PackedVector3Array, normal: Vector3) -> PackedInt32Array:
	var out := PackedInt32Array()
	var c := pts.size()
	if c < 3:
		return out

	# Project onto the plane most aligned with the normal.
	var ax := normal.abs()
	var p2 := PackedVector2Array()
	p2.resize(c)
	for i in c:
		var p := pts[i]
		if ax.x >= ax.y and ax.x >= ax.z:
			p2[i] = Vector2(p.y, p.z)
		elif ax.y >= ax.z:
			p2[i] = Vector2(p.z, p.x)
		else:
			p2[i] = Vector2(p.x, p.y)

	var ring: Array[int] = []
	for i in c:
		ring.append(i)
	if _signed_area(p2, ring) < 0.0:
		ring.reverse()

	var guard := 0
	while ring.size() > 3 and guard < c * c:
		guard += 1
		var clipped := false
		var rc := ring.size()
		for i in rc:
			var ia := ring[(i + rc - 1) % rc]
			var ib := ring[i]
			var ic := ring[(i + 1) % rc]
			if _cross(p2[ia], p2[ib], p2[ic]) <= 1e-12:
				continue
			var blocked := false
			for j in ring:
				if j != ia and j != ib and j != ic and _point_in_tri(p2[j], p2[ia], p2[ib], p2[ic]):
					blocked = true
					break
			if blocked:
				continue
			_push_tri(out, ia, ib, ic)
			ring.remove_at(i)
			clipped = true
			break
		if not clipped:
			break

	# Whatever is left (the final triangle, or a degenerate remainder) is fanned.
	for i in range(1, ring.size() - 1):
		_push_tri(out, ring[0], ring[i], ring[i + 1])
	# Ear clipping fans: long slivers from one corner across corners in line. Same
	# triangles, better shapes - unless the fan's flat (zero-area) triangles were real ones
	# after flipping: the bake drops flat ones, so they're free.
	if c > 3:
		var flipped := delaunay_flips(p2, out)
		if _solid_count(pts, flipped) <= _solid_count(pts, out):
			out = flipped

	# The 2D projection may mirror the polygon; restore 3D winding.
	for t in range(0, out.size(), 3):
		var tn := (pts[out[t + 1]] - pts[out[t]]).cross(pts[out[t + 2]] - pts[out[t]])
		if tn.dot(normal) < 0.0:
			var tmp := out[t + 1]
			out[t + 1] = out[t + 2]
			out[t + 2] = tmp
	return out


## Default box-projected UVs: 1 UV unit = 1 metre, textures stay upright on walls.
static func planar_uv(p: Vector3, n: Vector3) -> Vector2:
	var a := n.abs()
	if a.y >= a.x and a.y >= a.z:
		return Vector2(p.x, p.z)
	if a.x >= a.z:
		return Vector2(-p.z * signf(n.x), -p.y)
	return Vector2(p.x * signf(n.z), -p.y)


## Inverse of planar_uv: the point on plane (n · p = d) whose planar UV is `uv`.
static func planar_unproject(uv: Vector2, n: Vector3, d: float) -> Vector3:
	var a := n.abs()
	if a.y >= a.x and a.y >= a.z:
		return Vector3(uv.x, (d - n.x * uv.x - n.z * uv.y) / n.y, uv.y)
	if a.x >= a.z:
		var z := -uv.x * signf(n.x)
		var y := -uv.y
		return Vector3((d - n.y * y - n.z * z) / n.x, y, z)
	var x := uv.x * signf(n.z)
	var y := -uv.y
	return Vector3(x, y, (d - n.x * x - n.y * y) / n.z)


## Triangles of `tris` with area (LevelBaker drops the rest).
static func _solid_count(pts: PackedVector3Array, tris: PackedInt32Array) -> int:
	var n := 0
	for t in range(0, tris.size(), 3):
		if (pts[tris[t + 1]] - pts[tris[t]]).cross(pts[tris[t + 2]] - pts[tris[t]]).length_squared() >= 1e-10:
			n += 1
	return n


static func _push_tri(out: PackedInt32Array, a: int, b: int, c: int) -> void:
	out.append(a)
	out.append(b)
	out.append(c)


static func _signed_area(p2: PackedVector2Array, ring: Array[int]) -> float:
	var area := 0.0
	for i in ring.size():
		var a := p2[ring[i]]
		var b := p2[ring[(i + 1) % ring.size()]]
		area += a.x * b.y - b.x * a.y
	return area * 0.5


static func _cross(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b - a).cross(c - a)


static func _point_in_tri(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	return _cross(a, b, p) >= 0.0 and _cross(b, c, p) >= 0.0 and _cross(c, a, p) >= 0.0


## Improves a triangulation of `pts` (index triples) in place by flipping interior edges
## (Lawson): where two triangles form a convex quad and the edge's opposite angles sum past
## 180°, the other diagonal is taken. Same outline, same points, no long slivers (ear
## clipping fans whole sides from one corner).
static func delaunay_flips(pts: PackedVector2Array, tri: PackedInt32Array) -> PackedInt32Array:
	var t := tri.duplicate()
	var n := t.size() / 3
	for _pass in 8:
		var edges := {}  # Vector2i(lo, hi) -> [triangle, ...]
		for i in n:
			for k in 3:
				var a := t[i * 3 + k]
				var b := t[i * 3 + (k + 1) % 3]
				var e := Vector2i(mini(a, b), maxi(a, b))
				if not edges.has(e):
					edges[e] = []
				edges[e].append(i)
		var flipped := 0
		var touched := {}
		for e: Vector2i in edges:
			var tris: Array = edges[e]
			if tris.size() != 2 or touched.has(tris[0]) or touched.has(tris[1]):
				continue
			var c := _third(t, tris[0], e)
			var d := _third(t, tris[1], e)
			if c < 0 or d < 0 or c == d:
				continue
			var pa := pts[e.x]
			var pb := pts[e.y]
			var pc := pts[c]
			var pd := pts[d]
			# Convex quad a-c-b-d (the new diagonal c-d must cross a-b).
			if signf((pd - pc).cross(pa - pc)) == signf((pd - pc).cross(pb - pc)):
				continue
			if signf((pb - pa).cross(pc - pa)) == signf((pb - pa).cross(pd - pa)):
				continue
			var ang_c := (pa - pc).angle_to(pb - pc)
			var ang_d := (pa - pd).angle_to(pb - pd)
			if absf(ang_c) + absf(ang_d) <= PI + 1e-4:
				continue
			# Keep each triangle's winding as the original's.
			var w := signf((pts[t[tris[0] * 3 + 1]] - pts[t[tris[0] * 3]]).cross(pts[t[tris[0] * 3 + 2]] - pts[t[tris[0] * 3]]))
			var t0 := [c, d, e.x]
			var t1 := [d, c, e.y]
			for nt in [t0, t1]:
				if signf((pts[nt[1]] - pts[nt[0]]).cross(pts[nt[2]] - pts[nt[0]])) != w:
					var tmp: int = nt[1]
					nt[1] = nt[2]
					nt[2] = tmp
			for k in 3:
				t[tris[0] * 3 + k] = t0[k]
				t[tris[1] * 3 + k] = t1[k]
			touched[tris[0]] = true
			touched[tris[1]] = true
			flipped += 1
		if flipped == 0:
			break
	return t


static func _third(t: PackedInt32Array, i: int, e: Vector2i) -> int:
	for k in 3:
		var v := t[i * 3 + k]
		if v != e.x and v != e.y:
			return v
	return -1
