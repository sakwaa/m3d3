@tool
class_name HouseTerrace
extends RefCounted
## Houses standing side by side, a side wall (left / right) flush against a neighbour's,
## build as one terrace: on a joined side the plinth has no lip and a gable roof no
## overhang, and the party wall (wall, gable, plinth, verge, collision) is cut down to what
## the neighbour doesn't cover: where the house is taller, deeper or stepped forward / back
## it still shows, everything else goes. No doubled walls, no crack between them. Each
## house stays its own brush (own size, roof, shop, doors, lights).

## How far apart two side walls may stand and still join (metres).
const JOIN_GAP := 0.02
## Least length the two walls must share along the ground to join.
const MIN_OVERLAP := 0.25


## {left: [pieces], right: [pieces]} for house brush `b` among `houses` (house brushes): on
## each joined side, what its neighbours there cover, as convex polygons (PackedVector2Array
## of house-local (z, y) on that side's plane, counter-clockwise). {} when nothing joins.
static func joins(b: LevelBrush, houses: Array) -> Dictionary:
	var out := {}
	if not _upright(b.transform):
		return out
	var h := b.house
	var hw := h.width * 0.5
	var hd := h.depth * 0.5
	var inv := b.transform.affine_inverse()
	for o: LevelBrush in houses:
		if o == null or o == b or not o.is_house() or not _upright(o.transform):
			continue
		var oh := o.house
		var rel := inv * o.transform  # o's local -> b's local
		for s in [-1.0, 1.0]:
			for t in [-1.0, 1.0]:
				# o's side wall faces back at b's, in the same plane.
				if (rel.basis * Vector3(t, 0, 0)).normalized().x * s > -0.999:
					continue
				var p := rel * Vector3(t * oh.width * 0.5, 0, 0)
				if absf(p.x - s * hw) > JOIN_GAP:
					continue
				var za := (rel * Vector3(t * oh.width * 0.5, 0, -oh.depth * 0.5)).z
				var zb := (rel * Vector3(t * oh.width * 0.5, 0, oh.depth * 0.5)).z
				if minf(hd, maxf(za, zb)) - maxf(-hd, minf(za, zb)) < MIN_OVERLAP:
					continue
				# Their walls must share some height too.
				if minf(h.wall_height(), p.y + oh.wall_height()) - maxf(h.foundation, p.y + oh.foundation) < 0.1:
					continue
				var side := "right" if s > 0.0 else "left"
				if not out.has(side):
					out[side] = []
				for piece in profile(oh, t):
					var q := PackedVector2Array()
					for v: Vector3 in piece:
						var w := rel * v
						q.append(Vector2(w.z, w.y))
					out[side].append(_ccw(q))
	return out


## House `h`'s outline at its side end (t: -1 left, 1 right), as it covers a neighbour's
## party wall: convex pieces of house-local points on that end's plane (plinth, walls,
## gable and, for a gable roof, the roof slab's two slopes).
static func profile(h: HouseSpec, t: float) -> Array:
	var x := t * h.width * 0.5
	var hd := h.depth * 0.5
	var f := h.foundation
	var top := h.wall_height()
	var at := func(z: float, y: float) -> Vector3:
		return Vector3(x, y, z)
	var out := []
	if f > 0.0 or h.foundation_sink > 0.0:
		var lz := hd + h.foundation_lip
		out.append([at.call(-lz, -h.foundation_sink), at.call(lz, -h.foundation_sink), at.call(lz, f), at.call(-lz, f)])
	out.append([at.call(-hd, f), at.call(hd, f), at.call(hd, top), at.call(-hd, top)])
	if h.roof == HouseSpec.Roof.GABLE:
		var tan_p := tan(deg_to_rad(h.roof_pitch))
		var lift := h.roof_thickness / cos(deg_to_rad(h.roof_pitch))
		var o := h.overhang
		var ridge := top + hd * tan_p
		var eave := top - o * tan_p
		out.append([at.call(-hd, top), at.call(hd, top), at.call(0.0, ridge)])
		for sg in [-1.0, 1.0]:
			out.append([at.call(sg * (hd + o), eave), at.call(0.0, ridge), at.call(0.0, ridge + lift), at.call(sg * (hd + o), eave + lift)])
	return out


## Faces of HouseBuilder output `faces` lying in a joined side's plane, cut down to what the
## neighbours there leave showing (each kept piece a face like the one it came from).
static func cut_faces(faces: Array, hw: float, joins: Dictionary) -> Array:
	if joins.is_empty():
		return faces
	var out := []
	for f: Dictionary in faces:
		var side := ""
		for s in [-1.0, 1.0]:
			var name := "right" if s > 0.0 else "left"
			if joins.has(name) and not f.has("uv") and absf((f.normal as Vector3).x - s) < 0.01 and _on_plane(f.pts, s * hw):
				side = name
		if side == "":
			out.append(f)
			continue
		var poly := PackedVector2Array()
		for p: Vector3 in f.pts:
			poly.append(Vector2(p.z, p.y))
		var x: float = (f.pts[0] as Vector3).x
		for part in cut(_ccw(poly), joins[side]):
			var g := f.duplicate()
			var pts := []
			for q: Vector2 in part:
				pts.append(Vector3(x, q.y, q.x))
			# Wound to the face's normal again (the plane's (z, y) flips it on one side).
			if _newell(pts).dot(f.normal) < 0.0:
				pts.reverse()
			g.pts = pts
			out.append(g)
	return out


## Convex polygon `poly` minus every convex piece of `pieces` (all counter-clockwise): the
## convex parts left.
static func cut(poly: PackedVector2Array, pieces: Array) -> Array:
	var parts := [poly]
	for c: PackedVector2Array in pieces:
		var next := []
		for p: PackedVector2Array in parts:
			next.append_array(_minus(p, c))
		parts = next
		if parts.is_empty():
			break
	return parts


const AREA_EPS := 1e-4


static func _minus(p: PackedVector2Array, c: PackedVector2Array) -> Array:
	var out := []
	var rest := p
	for i in c.size():
		var a := c[i]
		var e := c[(i + 1) % c.size()] - a
		var outside := _clip(rest, a, e, -1.0)
		if absf(_area(outside)) > AREA_EPS:
			out.append(outside)
		rest = _clip(rest, a, e, 1.0)
		if absf(_area(rest)) <= AREA_EPS:
			return out
	return out  # (what's left lies inside c: gone)


## The part of `p` on one side of the line through `a` along `e` (keep 1: its left, -1: its
## right).
static func _clip(p: PackedVector2Array, a: Vector2, e: Vector2, keep: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := p.size()
	for i in n:
		var u := p[i]
		var v := p[(i + 1) % n]
		var du := keep * e.cross(u - a)
		var dv := keep * e.cross(v - a)
		if du >= 0.0:
			out.append(u)
		if (du >= 0.0) != (dv >= 0.0):
			out.append(u.lerp(v, du / (du - dv)))
	return out


static func _area(p: PackedVector2Array) -> float:
	var s := 0.0
	for i in p.size():
		s += p[i].cross(p[(i + 1) % p.size()])
	return s * 0.5


static func _ccw(p: PackedVector2Array) -> PackedVector2Array:
	if _area(p) < 0.0:
		p.reverse()
	return p


static func _on_plane(pts: Array, x: float) -> bool:
	for p: Vector3 in pts:
		if absf(p.x - x) > 0.005:
			return false
	return true


## Only turned about the vertical (houses always are).
static func _upright(xf: Transform3D) -> bool:
	return xf.basis.y.normalized().dot(Vector3.UP) > 0.999


static func _newell(pts: Array) -> Vector3:
	var n := Vector3.ZERO
	for i in pts.size():
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[(i + 1) % pts.size()]
		n += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
	return n
