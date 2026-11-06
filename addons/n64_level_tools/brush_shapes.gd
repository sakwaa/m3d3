class_name BrushShapes
extends RefCounted
## Primitive generators. Every shape sits on y = 0 with its footprint centred on the origin,
## so placing a brush on a surface puts its base on that surface.

enum Shape { BLOCK, WALL, PLANE, GRID, RAMP, STAIRS, CYLINDER, PYRAMID }

const NAMES := ["Block", "Wall", "Plane", "Grid", "Ramp", "Stairs", "Cylinder", "Pyramid"]
const DEFAULT_SIZES := [
	Vector3(2, 2, 2),
	Vector3(4, 3, 0.5),
	Vector3(4, 0, 4),
	Vector3(8, 0, 8),
	Vector3(2, 1, 4),
	Vector3(2, 2, 4),
	Vector3(2, 2, 2),
	Vector3(2, 2, 2),
]
const DEFAULT_SEGMENTS := [1, 1, 1, 8, 1, 8, 8, 1]


## Collects polygons, welding vertices that share a position so edits keep shapes closed.
class Builder:
	var verts := PackedVector3Array()
	var indices := PackedInt32Array()
	var counts := PackedInt32Array()
	var _lookup := {}

	func vert(p: Vector3) -> int:
		var key := Vector3i((p * 10000.0).round())
		if _lookup.has(key):
			return _lookup[key]
		verts.append(p)
		_lookup[key] = verts.size() - 1
		return verts.size() - 1

	## Adds a polygon, flipping it if needed so its normal faces `outward`.
	func face(pts: Array, outward: Vector3) -> void:
		var poly := PackedVector3Array(pts)
		if PolyUtil.newell_normal(poly).dot(outward) < 0.0:
			poly.reverse()
		for p in poly:
			indices.append(vert(p))
		counts.append(poly.size())


static func shape_name(shape: int) -> String:
	return NAMES[shape]


static func default_size(shape: int) -> Vector3:
	return DEFAULT_SIZES[shape]


static func default_segments(shape: int) -> int:
	return DEFAULT_SEGMENTS[shape]


static func build(shape: Shape, size: Vector3, segments: int) -> Builder:
	var b := Builder.new()
	var hx := size.x * 0.5
	var hz := size.z * 0.5
	segments = maxi(segments, 1)
	match shape:
		Shape.BLOCK, Shape.WALL:
			_box(b, Vector3(-hx, 0, -hz), Vector3(hx, size.y, hz))
		Shape.PLANE:
			_grid(b, hx, hz, 1)
		Shape.GRID:
			_grid(b, hx, hz, segments)
		Shape.RAMP:
			_ramp(b, hx, hz, size.y)
		Shape.STAIRS:
			_stairs(b, hx, hz, size.y, segments)
		Shape.CYLINDER:
			_cylinder(b, hx, hz, size.y, maxi(segments, 3))
		Shape.PYRAMID:
			_pyramid(b, hx, hz, size.y)
	return b


## Collision proxy for stairs: slope from the front-bottom edge up to the last step's
## nosing, then flat to the back. Visual steps sit at most one riser above it.
static func build_stairs_ramp(size: Vector3, segments: int) -> Builder:
	var b := Builder.new()
	var n := maxi(segments, 1)
	var hx := size.x * 0.5
	var front := size.z * 0.5
	var back := -front
	var h := size.y
	var top := front - (n - 1) * (size.z / n) if n > 1 else back
	b.face([Vector3(-hx, 0, front), Vector3(-hx, h, top), Vector3(-hx, h, back), Vector3(-hx, 0, back)], Vector3.LEFT)
	b.face([Vector3(hx, 0, front), Vector3(hx, h, top), Vector3(hx, h, back), Vector3(hx, 0, back)], Vector3.RIGHT)
	b.face([Vector3(-hx, 0, front), Vector3(hx, 0, front), Vector3(hx, h, top), Vector3(-hx, h, top)], Vector3(0, 1, 1))
	if top > back:
		b.face([Vector3(-hx, h, top), Vector3(hx, h, top), Vector3(hx, h, back), Vector3(-hx, h, back)], Vector3.UP)
	b.face([Vector3(-hx, 0, back), Vector3(hx, 0, back), Vector3(hx, h, back), Vector3(-hx, h, back)], Vector3.FORWARD)
	b.face([Vector3(-hx, 0, back), Vector3(hx, 0, back), Vector3(hx, 0, front), Vector3(-hx, 0, front)], Vector3.DOWN)
	return b


static func _box(b: Builder, lo: Vector3, hi: Vector3) -> void:
	b.face([Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)], Vector3.UP)
	b.face([Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z)], Vector3.DOWN)
	b.face([Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, lo.y, hi.z)], Vector3.RIGHT)
	b.face([Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, lo.y, hi.z)], Vector3.LEFT)
	b.face([Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)], Vector3.BACK)
	b.face([Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z)], Vector3.FORWARD)


static func _grid(b: Builder, hx: float, hz: float, n: int) -> void:
	for ix in n:
		for iz in n:
			var x0 := lerpf(-hx, hx, float(ix) / n)
			var x1 := lerpf(-hx, hx, float(ix + 1) / n)
			var z0 := lerpf(-hz, hz, float(iz) / n)
			var z1 := lerpf(-hz, hz, float(iz + 1) / n)
			b.face([Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1)], Vector3.UP)


## Wedge rising toward -Z (the back) to height h.
static func _ramp(b: Builder, hx: float, hz: float, h: float) -> void:
	var b0 := Vector3(-hx, 0, -hz)
	var b1 := Vector3(hx, 0, -hz)
	var b2 := Vector3(hx, 0, hz)
	var b3 := Vector3(-hx, 0, hz)
	var t0 := Vector3(-hx, h, -hz)
	var t1 := Vector3(hx, h, -hz)
	b.face([b0, b1, b2, b3], Vector3.DOWN)
	b.face([b0, b1, t1, t0], Vector3.FORWARD)
	b.face([t0, t1, b2, b3], Vector3(0, 1, 1))
	b.face([b0, t0, b3], Vector3.LEFT)
	b.face([b1, t1, b2], Vector3.RIGHT)


## Staircase of n steps rising toward -Z.
static func _stairs(b: Builder, hx: float, hz: float, h: float, n: int) -> void:
	var depth := (hz * 2.0) / n
	var rise := h / n
	var front := hz
	var back := -hz
	var profile_l := [Vector3(-hx, 0, front)]
	var profile_r := [Vector3(hx, 0, front)]
	for i in n:
		var z := front - i * depth
		var y0 := i * rise
		var y1 := (i + 1) * rise
		b.face([Vector3(-hx, y0, z), Vector3(hx, y0, z), Vector3(hx, y1, z), Vector3(-hx, y1, z)], Vector3.BACK)
		b.face([Vector3(-hx, y1, z), Vector3(hx, y1, z), Vector3(hx, y1, z - depth), Vector3(-hx, y1, z - depth)], Vector3.UP)
		for side in [[profile_l, -hx], [profile_r, hx]]:
			side[0].append(Vector3(side[1], y1, z))
			side[0].append(Vector3(side[1], y1, z - depth))
	profile_l.append(Vector3(-hx, 0, back))
	profile_r.append(Vector3(hx, 0, back))
	b.face(profile_l, Vector3.LEFT)
	b.face(profile_r, Vector3.RIGHT)
	b.face([Vector3(-hx, 0, back), Vector3(hx, 0, back), Vector3(hx, h, back), Vector3(-hx, h, back)], Vector3.FORWARD)
	b.face([Vector3(-hx, 0, back), Vector3(hx, 0, back), Vector3(hx, 0, front), Vector3(-hx, 0, front)], Vector3.DOWN)


static func _cylinder(b: Builder, rx: float, rz: float, h: float, n: int) -> void:
	var ring: Array[Vector3] = []
	for i in n:
		var a := TAU * i / n + PI / n
		ring.append(Vector3(cos(a) * rx, 0, sin(a) * rz))
	var top := []
	var bottom := []
	for p in ring:
		top.append(p + Vector3(0, h, 0))
		bottom.append(p)
	b.face(top, Vector3.UP)
	b.face(bottom, Vector3.DOWN)
	for i in n:
		var p0 := ring[i]
		var p1 := ring[(i + 1) % n]
		var up := Vector3(0, h, 0)
		b.face([p0, p1, p1 + up, p0 + up], (p0 + p1) * 0.5)


static func _pyramid(b: Builder, hx: float, hz: float, h: float) -> void:
	var base := [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)]
	var apex := Vector3(0, h, 0)
	var centre := Vector3(0, h * 0.25, 0)
	b.face(base, Vector3.DOWN)
	for i in 4:
		var p0: Vector3 = base[i]
		var p1: Vector3 = base[(i + 1) % 4]
		b.face([p0, p1, apex], (p0 + p1 + apex) / 3.0 - centre)
