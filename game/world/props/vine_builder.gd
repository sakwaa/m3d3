class_name VineBuilder
extends RefCounted
## Grows creeping vines over whatever is around them (WorldVines): thick ropey tendrils that
## crawl along surfaces from their roots - over the ground, up walls, round edges, over
## objects - wandering, seeking a target if there is one and wrapping round it once there,
## branching now and then, with leaves along them on short stalks.
## The crawl reads triangles (TriGrid: the visible meshes nearby, gathered by WorldVines), not
## physics, so it works in the editor before the level is baked and the same in game. Same
## settings, seed and surroundings: the same vines.
## The mesh: two surfaces, stems (0) and leaves (1). Lighting baked into the vertex colours
## like the trees; vertex alpha = wind weight (leaf tips). CUSTOM0 = growth (n64_vine): xyz
## the point a vertex grows out of, w when it's reached (0 roots .. 1 last tip).

const SUN := Vector3(-0.45, 0.8, 0.4)
## One-triangle leaves: the triangle round the leaf texture (measured from vine_leaf: apex
## this far above the texture's top, half as wide as the texture at its foot, times this).
const LEAF_APEX := 0.07
const LEAF_HALF := 0.8


## Triangles bucketed in a grid of cells, for short rays.
class TriGrid:
	var cell := 1.0
	var tris := PackedVector3Array()  # 3 per triangle
	var cells := {}  # Vector3i -> PackedInt32Array of triangle numbers

	func add_faces(faces: PackedVector3Array, xf: Transform3D, region: AABB) -> void:
		for i in range(0, faces.size() - 2, 3):
			var a := xf * faces[i]
			var b := xf * faces[i + 1]
			var c := xf * faces[i + 2]
			var box := AABB(a, Vector3.ZERO).expand(b).expand(c)
			if not box.grow(0.01).intersects(region):
				continue
			if (b - a).cross(c - a).length_squared() < 1e-10:
				continue
			var t := tris.size() / 3
			tris.append_array([a, b, c])
			box = box.intersection(region.grow(cell))
			var lo := Vector3i((box.position / cell).floor())
			var hi := Vector3i((box.end / cell).floor())
			for x in range(lo.x, hi.x + 1):
				for y in range(lo.y, hi.y + 1):
					for z in range(lo.z, hi.z + 1):
						var k := Vector3i(x, y, z)
						if not cells.has(k):
							cells[k] = PackedInt32Array()
						cells[k].append(t)

	func count() -> int:
		return tris.size() / 3

	## The nearest hit along from -> to: {position, normal (facing `from`), front (the face's
	## outside was hit: false = from inside something)}, or {}.
	func ray(from: Vector3, to: Vector3) -> Dictionary:
		var box := AABB(from, Vector3.ZERO).expand(to)
		var lo := Vector3i((box.position / cell).floor())
		var hi := Vector3i((box.end / cell).floor())
		var seen := {}
		var best := {}
		var best_d := INF
		var dir := to - from
		for x in range(lo.x, hi.x + 1):
			for y in range(lo.y, hi.y + 1):
				for z in range(lo.z, hi.z + 1):
					var list: PackedInt32Array = cells.get(Vector3i(x, y, z), PackedInt32Array())
					for t in list:
						if seen.has(t):
							continue
						seen[t] = true
						var a := tris[t * 3]
						var b := tris[t * 3 + 1]
						var c := tris[t * 3 + 2]
						var hit = Geometry3D.segment_intersects_triangle(from, to, a, b, c)
						if hit == null:
							continue
						var d := from.distance_squared_to(hit)
						if d < best_d:
							best_d = d
							var n := (c - a).cross(b - a).normalized()  # (Godot: clockwise = front)
							var front := n.dot(dir) < 0.0
							if not front:
								n = -n
							best = {position = hit, normal = n, front = front}
		return best


class Tendril:
	var points := PackedVector3Array()  # stem centre line (world)
	var normals := PackedVector3Array()  # the surface's normal under each point
	var dist := PackedFloat32Array()  # distance from the roots (growth order)
	var radius := 0.05
	var depth := 0


## Grows the vines. `cfg`: the WorldVines settings (see there); `origin`: the roots' middle
## (world, the node's transform); `target`: world point to seek (or null). Returns the
## tendrils (world space).
static func crawl(cfg: Dictionary, origin: Transform3D, target: Variant, grid: TriGrid) -> Array[Tendril]:
	var rng := RandomNumberGenerator.new()
	rng.seed = cfg.seed
	var out: Array[Tendril] = []
	var queue := []  # [p, n, d, length, radius, depth, start_dist]
	var up := origin.basis.y.normalized()
	for i in int(cfg.count):
		var a := TAU * (i + rng.randf_range(-0.3, 0.3)) / maxf(cfg.count, 1)
		# (a root inside something - a wall's footprint - is put somewhere else)
		var off := Vector3.ZERO
		var hit := {}
		for tries in 6:
			off = (origin.basis.x.normalized() * cos(a) + origin.basis.z.normalized() * sin(a)) * cfg.spread * sqrt(rng.randf())
			hit = grid.ray(origin.origin + off + up * 1.0, origin.origin + off - up * 3.0)
			if not hit.is_empty() and hit.front:
				break
			hit = {}
			a += rng.randf_range(-1.0, 1.0)
		if hit.is_empty():
			continue
		var start: Vector3 = hit.position
		var n: Vector3 = hit.normal
		var d: Vector3 = off.normalized() if off.length() > 0.01 else Vector3(cos(a), 0, sin(a))
		if target != null:
			d = d.lerp(((target as Vector3) - start).normalized(), rng.randf_range(0.0, 0.5))
		d = _flat(d, n, Vector3(cos(a), 0, sin(a))).rotated(n, rng.randf_range(-0.8, 0.8))
		var length: float = cfg.length * rng.randf_range(1.0 - cfg.length_jitter, 1.0)
		queue.append([hit.position, n, d, length, float(cfg.thickness), 0, 0.0])
	while not queue.is_empty() and out.size() < 400:
		var q: Array = queue.pop_front()
		var t := _crawl_one(cfg, q, target, grid, rng, queue)
		if t.points.size() >= 2:
			out.append(t)
	return out


static func _crawl_one(cfg: Dictionary, q: Array, target: Variant, grid: TriGrid, rng: RandomNumberGenerator, queue: Array) -> Tendril:
	var p: Vector3 = q[0]
	var n: Vector3 = q[1]
	var d: Vector3 = q[2]
	var length: float = q[3]
	var t := Tendril.new()
	t.radius = q[4]
	t.depth = q[5]
	var travelled: float = q[6]
	var end := travelled + length
	var r := t.radius
	var step: float = cfg.step
	var lift := maxf(r * 1.6, 0.05)
	t.points.append(p + n * r)
	t.normals.append(n)
	t.dist.append(travelled)
	var stuck := 0
	var wrapped := false
	var turn := 0.0  # (the turn rate wanders, not the heading: sweeping curves, not jitter)
	while travelled < end:
		# Steer: wander, seek the target (wander more round it once there: wrapping), climb.
		var wander := deg_to_rad(cfg.wander)
		if target != null:
			var to: Vector3 = (target as Vector3) - p
			var near: bool = to.length() < cfg.target_radius
			wrapped = wrapped or near
			var tan := to - n * to.dot(n)
			# (sprawling at first, then more and more drawn in)
			var pull: float = cfg.seek * clampf((travelled - float(q[6])) / maxf(length * 0.35, 0.1), 0.15, 1.0)
			if tan.length() > 0.05:
				d = d.slerp(tan.normalized(), pull * (0.35 if wrapped else 1.0)).normalized()
			if wrapped:
				wander *= 1.6
		turn = clampf(turn + rng.randf_range(-1.0, 1.0) * wander * 0.7, -wander, wander)
		d = d.rotated(n, turn)
		if cfg.climb > 0.0 and absf(n.y) < 0.75:
			var upw := Vector3.UP - n * n.y
			d = d.slerp(upw.normalized(), cfg.climb * 0.5).normalized()
		d = _flat(d, n, d)
		var a := p + n * lift
		var np := Vector3.ZERO
		var nn := Vector3.ZERO
		var hit := grid.ray(a, a + d * step)
		if not hit.is_empty() and not hit.front:
			break  # (inside something)
		if not hit.is_empty():
			# A wall ahead: onto it, carrying on away from the surface we were on.
			np = hit.position
			nn = hit.normal
			d = _flat(n, nn, d)
		else:
			var b := a + d * step
			hit = grid.ray(b, b - n * (lift + step))
			if not hit.is_empty():
				np = hit.position
				nn = hit.normal
			else:
				# An edge: round it, back under onto the face below.
				var c := b - n * (lift + r * 2.0 + 0.08)
				hit = grid.ray(c, c - d * step * 1.6)
				if hit.is_empty():
					break  # (nothing to hold on to)
				np = hit.position
				nn = hit.normal
				# (a point on the edge first so the stem bends round it, not through it)
				var edge := p + d * (np - p).dot(d) + n * r
				t.points.append(edge)
				t.normals.append((n + nn).normalized())
				t.dist.append(travelled + p.distance_to(edge))
				d = _flat(-n, nn, d)
		var moved := np.distance_to(p)
		if moved < step * 0.2:
			stuck += 1
			if stuck > 3:
				break
			continue
		stuck = 0
		if hit.has("normal") and nn.dot(n) > 0.3:
			d = _flat(np - p, nn, d)
		travelled += moved
		p = np
		n = nn
		t.points.append(p + n * r)
		t.normals.append(n)
		t.dist.append(travelled)
		# A branch now and then (thinner, shorter, off to one side).
		if t.depth < int(cfg.branch_depth) and rng.randf() < cfg.branches * moved:
			var side := 1.0 if rng.randf() < 0.5 else -1.0
			var bd := d.rotated(n, side * rng.randf_range(0.5, 1.0))
			queue.append([p, n, bd, (end - travelled) * cfg.branch_length, r * 0.65, t.depth + 1, travelled])
	return t


## `v` flattened onto the plane of normal `n`, unit length (`fallback` if it has none).
static func _flat(v: Vector3, n: Vector3, fallback: Vector3) -> Vector3:
	var f := v - n * v.dot(n)
	if f.length() < 0.001:
		f = fallback - n * fallback.dot(n)
		if f.length() < 0.001:
			f = n.cross(Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.FORWARD)
	return f.normalized()


# --- Mesh -------------------------------------------------------------------------------------

class Buf:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var custom := PackedFloat32Array()
	var index := PackedInt32Array()

	func add(v: Vector3, n: Vector3, uv: Vector2, col: Color, from: Vector3, t: float) -> int:
		verts.append(v)
		normals.append(n)
		uvs.append(uv)
		colors.append(col)
		custom.append_array([from.x, from.y, from.z, t])
		return verts.size() - 1

	func tri(a: int, b: int, c: int) -> void:
		index.append_array([a, b, c])

	func arrays() -> Array:
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = verts
		a[Mesh.ARRAY_NORMAL] = normals
		a[Mesh.ARRAY_TEX_UV] = uvs
		a[Mesh.ARRAY_COLOR] = colors
		a[Mesh.ARRAY_CUSTOM0] = custom
		a[Mesh.ARRAY_INDEX] = index
		return a


const FORMAT := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT


## The mesh for `tendrils` (world space) in the space of `xf` (the node's): stems + leaves.
static func build_mesh(cfg: Dictionary, tendrils: Array[Tendril], xf: Transform3D) -> ArrayMesh:
	var inv := xf.affine_inverse()
	var basis_inv := inv.basis
	var total := 0.001
	for t in tendrils:
		total = maxf(total, t.dist[t.dist.size() - 1])
	var rng := RandomNumberGenerator.new()
	rng.seed = int(cfg.seed) * 7 + 3
	var stems := Buf.new()
	var leaves := Buf.new()
	var sides := int(cfg.sides)
	var sun := (basis_inv * SUN).normalized()
	var open_back: bool = cfg.open_back
	var skip := sides - 1 if open_back else -1  # (the face lying on the surface: never seen)
	var sink := 1.0 - cos(PI / sides)  # (lowered so that face rests on the surface)
	for t in tendrils:
		var keep := _kept(t, deg_to_rad(cfg.stem_bend))
		var n := keep.size()
		var base := stems.verts.size()
		var tip_len := t.dist[t.dist.size() - 1] - t.dist[0]
		var circ := TAU * t.radius
		var prev_c := inv * t.points[0]
		for j in n:
			var i: int = keep[j]
			var i_next: int = keep[mini(j + 1, n - 1)]
			var i_prev: int = keep[maxi(j - 1, 0)]
			var along := basis_inv * (t.points[i_next] - t.points[i_prev])
			along = along.normalized() if along.length() > 0.0001 else Vector3.FORWARD
			# The ring's frame from the surface under it: one face flat down on it.
			var surf := (basis_inv * t.normals[i]).normalized()
			var up := surf - along * surf.dot(along)
			up = up.normalized() if up.length() > 0.001 else _perp(along)
			var side := along.cross(up)
			var k := (t.dist[i] - t.dist[0]) / maxf(tip_len, 0.001)
			var r := t.radius * lerpf(1.0, cfg.tip, k) * (1.0 + 0.12 * sin(t.dist[i] * 9.0))  # (a little knotty)
			if j == n - 1:
				r *= 0.4
			var p := inv * t.points[i] - surf * r * sink
			var grow_t := t.dist[i] / total
			for e in sides + 1:
				var ang := -PI * 0.5 + PI / sides + TAU * e / sides
				var nrm := side * cos(ang) + up * sin(ang)
				var light := 0.5 + 0.5 * maxf(nrm.dot(sun), 0.0)
				light *= lerpf(0.55, 1.0, clampf(nrm.dot(surf) * 0.5 + 0.5, 0.0, 1.0))  # (dark where it meets the surface)
				stems.add(p + nrm * r, nrm, Vector2(float(e) / sides, t.dist[i] / maxf(circ * cfg.stem_tile, 0.01)),
					Color(light, light, light, 0.0), prev_c, grow_t)
			prev_c = p
		for j in n - 1:
			for e in sides:
				if e == skip:
					continue
				var a := base + j * (sides + 1) + e
				var b := a + sides + 1
				stems.tri(a, b, a + 1)
				stems.tri(a + 1, b, b + 1)
		_leaves_on(cfg, t, inv, total, sun, rng, leaves)
	var mesh := ArrayMesh.new()
	if not stems.verts.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, stems.arrays(), [], {}, FORMAT)
	if not leaves.verts.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, leaves.arrays(), [], {}, FORMAT)
	return mesh


## Leaves along a tendril: alternating sides, on short stalks, lifted off the surface, the
## younger (smaller) towards its tip, a few bunched at the tip.
static func _leaves_on(cfg: Dictionary, t: Tendril, inv: Transform3D, total: float, sun: Vector3,
		rng: RandomNumberGenerator, buf: Buf) -> void:
	var n := t.points.size()
	var len := t.dist[n - 1] - t.dist[0]
	var count := int(len * cfg.leaf_density)
	var side := 1.0
	for j in count + 2:
		var at := t.dist[0] + (rng.randf() * len if j < count else len * rng.randf_range(0.9, 1.0))
		var i := 0
		while i < n - 2 and t.dist[i + 1] < at:
			i += 1
		var k := clampf((at - t.dist[i]) / maxf(t.dist[i + 1] - t.dist[i], 0.0001), 0.0, 1.0)
		var p := t.points[i].lerp(t.points[i + 1], k)
		var surf := t.normals[i].slerp(t.normals[i + 1], k).normalized()
		var along := (t.points[i + 1] - t.points[i]).normalized()
		var across := along.cross(surf).normalized()
		side = -side
		var age := 1.0 - (at - t.dist[0]) / maxf(len, 0.001)  # (1 at the base, 0 at the tip)
		var size: float = cfg.leaf_size * rng.randf_range(1.0 - cfg.leaf_jitter, 1.0) * lerpf(0.6, 1.0, age)
		# The leaf points out to the side and forwards, tipped up off the surface.
		var lean := deg_to_rad(rng.randf_range(20.0, 60.0))
		var dir := (across * side).rotated(surf, side * lean * 0.6)
		dir = dir.rotated(dir.cross(surf).normalized(), -deg_to_rad(cfg.leaf_lift) * rng.randf_range(0.5, 1.2))
		dir = dir.normalized()
		var width := dir.cross(surf).normalized()
		if width.length() < 0.5:
			width = along
		var base := p + across * side * t.radius * 0.8 + surf * t.radius * 0.3
		var nrm := width.cross(dir).normalized()
		if nrm.dot(surf) < 0.0:
			nrm = -nrm
		var light := (0.55 + 0.45 * maxf(nrm.dot(SUN.normalized()), 0.0)) * rng.randf_range(0.82, 1.08)
		var tint: Color = Color(light, light, light, 0.0)
		var tip_col := Color(light, light, light, 1.0)
		var b := inv * base
		var grow_t := minf((at + 0.15) / total, 1.0)
		var ln := (inv.basis * nrm).normalized()
		var w := width * size
		if cfg.leaf_triangles:
			# One triangle round the leaf (its tip at the apex; outside the texture is cut away).
			var h: float = 1.0 + LEAF_APEX
			var q := [base - w * LEAF_HALF, base + w * LEAF_HALF, base + dir * size * h]
			var uvs := [Vector2(0.5 - LEAF_HALF, 1), Vector2(0.5 + LEAF_HALF, 1), Vector2(0.5, -LEAF_APEX)]
			var ids := []
			for v in 3:
				ids.append(buf.add(inv * (q[v] as Vector3), ln, uvs[v], tint if v < 2 else tip_col, b, grow_t))
			buf.tri(ids[0], ids[2], ids[1])
		else:
			w *= 0.5
			var q := [base - w, base + w, base + w + dir * size, base - w + dir * size]
			var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
			var ids := []
			for v in 4:
				ids.append(buf.add(inv * (q[v] as Vector3), ln, uvs[v], tint if v < 2 else tip_col, b, grow_t))
			buf.tri(ids[0], ids[2], ids[1])
			buf.tri(ids[0], ids[3], ids[2])


## The points a stem's rings go at: where it bends more than `bend` (radians) since the
## last ring, crosses onto another surface, or every couple of metres; always both ends.
## (The crawl's every point still places the leaves and times the growth.)
static func _kept(t: Tendril, bend: float) -> PackedInt32Array:
	var out := PackedInt32Array([0])
	var n := t.points.size()
	for i in range(1, n - 1):
		var last := out[out.size() - 1]
		var from := t.points[i] - t.points[last]
		var to := t.points[i + 1] - t.points[i]
		if from.angle_to(to) > bend or t.normals[i].angle_to(t.normals[last]) > 0.2 \
				or t.dist[i + 1] - t.dist[last] > 2.0:
			out.append(i)
	out.append(n - 1)
	return out


static func _perp(d: Vector3) -> Vector3:
	var o := Vector3.UP if absf(d.normalized().dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	return d.cross(o).normalized()


static func triangles(mesh: ArrayMesh) -> int:
	var c := 0
	for i in mesh.get_surface_count():
		c += (mesh.surface_get_arrays(i)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	return c
