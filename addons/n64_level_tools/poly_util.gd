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
