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
	var hang_from := -1  # points from here on hang free (a strand dropped off an overhang)


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
		var fan := deg_to_rad(float(cfg.fan))
		if target != null and fan < TAU - 0.01:
			# (one source: all set off towards the target, spread over the fan)
			d = _flat((target as Vector3) - start, n, d).rotated(n, rng.randf_range(-0.5, 0.5) * fan)
		else:
			if target != null:
				d = d.lerp(((target as Vector3) - start).normalized(), rng.randf_range(0.0, 0.5))
			d = _flat(d, n, Vector3(cos(a), 0, sin(a))).rotated(n, rng.randf_range(-0.8, 0.8))
		var length: float = cfg.length * rng.randf_range(1.0 - cfg.length_jitter, 1.0)
		queue.append([hit.position, n, d, length, float(cfg.thickness), 0, 0.0])
	# (bundle: the turns every tendril shares, by distance travelled - they flow together)
	var noise := FastNoiseLite.new()
	noise.seed = int(cfg.seed)
	noise.frequency = 0.35
	while not queue.is_empty() and out.size() < 400:
		var q: Array = queue.pop_front()
		var t := _crawl_one(cfg, q, target, grid, rng, queue, noise)
		if t.points.size() >= 2:
			out.append(t)
	return out


static func _crawl_one(cfg: Dictionary, q: Array, target: Variant, grid: TriGrid, rng: RandomNumberGenerator, queue: Array,
		noise: FastNoiseLite) -> Tendril:
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
	var arrived := Vector3.ZERO  # (where it reached the target, and how far it had come)
	var arrived_at := 0.0
	var turn := 0.0  # (the turn rate wanders, not the heading: sweeping curves, not jitter)
	while travelled < end:
		# Steer: wander, seek the target (wander more round it once there: wrapping), climb.
		var wander := deg_to_rad(cfg.wander)
		var spreading := false
		if target != null:
			var to: Vector3 = (target as Vector3) - p
			var near: bool = to.length() < cfg.target_radius
			if near and not wrapped:
				arrived = p
				arrived_at = travelled
			wrapped = wrapped or near
			# Cascade: first on across the target (to its far side from where this one came
			# in, cascade_spread metres), then down.
			spreading = wrapped and cfg.cascade and travelled - arrived_at < float(cfg.cascade_spread)
			if spreading:
				to = (target as Vector3) * 2.0 - arrived - p
			var tan := to - n * to.dot(n)
			# (sprawling at first, then more and more drawn in)
			var pull: float = cfg.seek * clampf((travelled - float(q[6])) / maxf(length * 0.35, 0.1), 0.15, 1.0)
			if tan.length() > 0.05:
				d = d.slerp(tan.normalized(), pull * (0.35 if wrapped and not spreading else 1.0)).normalized()
			if wrapped and not spreading:
				wander *= 1.6
		turn = clampf(turn + rng.randf_range(-1.0, 1.0) * wander * 0.7, -wander, wander)
		var shared := noise.get_noise_1d(travelled) * wander * 1.6
		d = d.rotated(n, lerpf(turn, shared, float(cfg.bundle)))
		# (up walls, or with a negative climb drooping down them; cascade: once at the target,
		# down - they climb to it, then pour down over it)
		var climb: float = cfg.climb
		if wrapped and cfg.cascade:
			climb = 0.0 if spreading else -maxf(absf(climb), 0.5)
		if climb != 0.0 and absf(n.y) < 0.75:
			var upw := (Vector3.UP - n * n.y).normalized() * signf(climb)
			d = d.slerp(upw, absf(climb) * 0.5).normalized()
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
				# Over an overhang (the face round the edge faces down: a doorway's top, a
				# ledge) or off into nothing: maybe hang down from it as a free strand.
				var overhang: bool = hit.is_empty() or (hit.normal as Vector3).y < -0.5
				if overhang and cfg.hang > 0.0 and rng.randf() < cfg.hang:
					_dangle(t, p + n * r + d * step * 0.3, n, travelled + step * 0.3, end, cfg, grid, rng)
					break
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


## A strand hanging from `from` (off the overhang the tendril reached): nearly straight down,
## drifting a little, up to hang_length (some shorter) or what's left of the tendril, or until
## it touches something.
static func _dangle(t: Tendril, from: Vector3, n: Vector3, travelled: float, end: float, cfg: Dictionary,
		grid: TriGrid, rng: RandomNumberGenerator) -> void:
	var length := minf(end - travelled, float(cfg.hang_length) * rng.randf_range(0.45, 1.0))
	if length < 0.3:
		return
	t.hang_from = t.points.size()
	var p := from
	var s: float = float(cfg.step) * 0.8
	var drift := Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0)) * 0.1
	var gone := 0.0
	t.points.append(p)
	t.normals.append(n)
	t.dist.append(travelled)
	while gone < length:
		var dir := (Vector3.DOWN + drift + Vector3(rng.randf_range(-0.07, 0.07), 0.0, rng.randf_range(-0.07, 0.07))).normalized()
		var q := p + dir * s
		if not grid.ray(p, q + dir * t.radius).is_empty():
			break  # (resting on something below)
		gone += s
		p = q
		t.points.append(p)
		t.normals.append(n)
		t.dist.append(travelled + gone)


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
	var uv2 := PackedVector2Array()
	var index := PackedInt32Array()
	## (UV2 for the next vertices: hanging strand number + 1 and how far down it, 0..1)
	var cur_uv2 := Vector2.ZERO

	func add(v: Vector3, n: Vector3, uv: Vector2, col: Color, from: Vector3, t: float) -> int:
		verts.append(v)
		normals.append(n)
		uvs.append(uv)
		colors.append(col)
		custom.append_array([from.x, from.y, from.z, t])
		uv2.append(cur_uv2)
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
		a[Mesh.ARRAY_TEX_UV2] = uv2
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
	var cards := Buf.new()
	var moss := Buf.new()
	var sides := int(cfg.sides)
	var sun := (basis_inv * SUN).normalized()
	var open_back: bool = cfg.open_back
	var sink := 1.0 - cos(PI / sides)  # (lowered so the face down rests on the surface)
	# Ground tents: on floors (surface facing up at least this much) the ring is turned so a
	# corner points up, sunk to its middle, and only the faces above ground are drawn (4
	# sides: an upside-down V, two faces).
	var tent_up: float = cfg.tent_up if cfg.ground_tent else 2.0
	var tent_sink: float = cfg.tent_sink
	var tent_width: float = cfg.tent_width
	# Base fill / detail top: where a vine runs under another (higher in the pecking order:
	# trunks over branches, thicker over thinner), that stretch is a flat strip on the
	# surface (one face); the vine on top stays 3D. `fill_share` of the thinnest tendrils are
	# flat all along (a cheap fill under the detail).
	var keeps: Array[PackedInt32Array] = []
	for t in tendrils:
		keeps.append(_kept(t, deg_to_rad(cfg.stem_bend)))
	var flats := _covered(tendrils, keeps, cfg) if cfg.flat_under else []
	var order := range(tendrils.size())
	order.sort_custom(func(x, y): return _rank(tendrils[x]) < _rank(tendrils[y]))
	var fill_n := int(float(cfg.fill_share) * tendrils.size())
	var all_flat := {}
	for q in fill_n:
		all_flat[order[order.size() - 1 - q]] = true  # (the lowest ranked)
	# Intermixed: the lowest-ranked card_share of the tendrils (branches before trunks,
	# thinner before thicker) are vine cards under the 3D ones.
	var card_set := {}
	var card_n := tendrils.size() if cfg.cards else int(roundf(float(cfg.card_share) * tendrils.size()))
	for q in card_n:
		card_set[order[order.size() - 1 - q]] = true
	# Hanging strands (at most 64): their top, their rest tip and length - WorldVines swings
	# them (a pendulum each); their vertices carry UV2 = (strand + 1, how far down 0..1).
	var strands := []
	var strand_of := {}
	for ti in tendrils.size():
		var ht := tendrils[ti]
		if ht.hang_from >= 0 and strands.size() < 64:
			var last := ht.points.size() - 1
			strand_of[ti] = strands.size()
			strands.append([inv * ht.points[ht.hang_from], inv * ht.points[last], maxf(ht.dist[last] - ht.dist[ht.hang_from], 0.05)])
	for ti in tendrils.size():
		var t := tendrils[ti]
		var keep := keeps[ti]
		var n := keep.size()
		var st: int = strand_of.get(ti, -1)
		var tip_len := t.dist[t.dist.size() - 1] - t.dist[0]
		var circ := TAU * t.radius
		# Each ring's frame and size.
		var rings := []
		for j in n:
			var i: int = keep[j]
			var i_next: int = keep[mini(j + 1, n - 1)]
			var i_prev: int = keep[maxi(j - 1, 0)]
			var along := basis_inv * (t.points[i_next] - t.points[i_prev])
			along = along.normalized() if along.length() > 0.0001 else Vector3.FORWARD
			var surf := (basis_inv * t.normals[i]).normalized()
			var up := surf - along * surf.dot(along)
			up = up.normalized() if up.length() > 0.001 else _perp(along)
			# (full thickness until the last taper_length, then down to `tip`, a blunt end)
			var tl: float = maxf(float(cfg.taper_length), 0.01)
			var k := clampf((t.dist[i] - (t.dist[t.dist.size() - 1] - tl)) / tl, 0.0, 1.0)
			var r := t.radius * lerpf(1.0, cfg.tip, k) * (1.0 + 0.12 * sin(t.dist[i] * 9.0))  # (a little knotty)
			if j == n - 1:
				r *= 0.75
			var free := t.hang_from >= 0 and i >= t.hang_from
			# (hanging: how far down the strand, 0 at its top .. 1 at its end: its swing weight)
			var sway := clampf((t.dist[i] - t.dist[t.hang_from]) / (strands[st][2] as float), 0.0, 1.0) if free and st >= 0 else 0.0
			rings.append({i = i, along = along, surf = surf, up = up, side = along.cross(up), r = r,
				on = inv * t.points[i] if free else inv * t.points[i] - surf * t.radius,
				tent = not free and t.normals[i].y >= tent_up, free = free, w = 0.0, sw = sway, st = st if free else -1,
				v = t.dist[i] / maxf(circ * cfg.stem_tile, 0.01), g = t.dist[i] / total})
		var card_w := float(cfg.card_width) * t.radius / float(cfg.thickness)
		# (cards lifted a little more the higher their vine ranks, so overlaps don't flicker)
		var card_lift := 0.012 + 0.016 * (1.0 - order.find(ti) / maxf(order.size(), 1.0))
		# (each strip its own: a start in the pattern, mirrored or not, its own repeat length and
		# a width that swells and narrows - card_variation)
		var cr := RandomNumberGenerator.new()
		cr.seed = int(cfg.seed) * 131 + ti * 7919
		var cv: float = cfg.card_variation
		var vary := [cr.randf() * cv, cv > 0.0 and cr.randf() < 0.5, 1.0 + cr.randf_range(-0.25, 0.3) * cv, cr.randf() * TAU, cv]
		if float(cfg.moss_width) > 0.0:
			_moss_band(moss, rings, inv * t.points[0], cfg, rank_lift(order, ti))
		if card_set.has(ti):
			# A vine card: the whole vine one strip, stem and leaves in its texture.
			_card_strip(cards, rings, 0, n - 1, inv * t.points[0], sun, card_w, card_lift, float(cfg.card_width), vary)
			continue
		# Segments flat (under another vine, or a fill tendril) or 3D, in runs.
		var flat := PackedByteArray()
		flat.resize(maxi(n - 1, 0))
		for j in n - 1:
			flat[j] = 1 if not (rings[j] as Dictionary).free and (all_flat.has(ti) or (not flats.is_empty() and flats[ti][j] == 1)) else 0
		var j0 := 0
		while j0 < n - 1:
			var j1 := j0
			while j1 + 1 < n - 1 and flat[j1 + 1] == flat[j0]:
				j1 += 1
			if flat[j0] == 1 and cfg.fill_cards:
				# (covered: a stretch of vine card - it still shows leaves under the 3D one)
				_card_strip(cards, rings, j0, j1 + 1, inv * t.points[(rings[maxi(j0 - 1, 0)] as Dictionary).i], sun,
					card_w, card_lift, float(cfg.card_width), vary)
			elif flat[j0] == 1:
				_strip(stems, rings, j0, j1 + 1, inv * t.points[(rings[maxi(j0 - 1, 0)] as Dictionary).i], sun)
			else:
				_tube(stems, rings, j0, j1 + 1, inv * t.points[(rings[maxi(j0 - 1, 0)] as Dictionary).i], sides,
					open_back, sink, tent_sink, tent_width, sun)
			j0 = j1 + 1
	# Leaves last, the vines on top first: where leaf_cap is full the ones under get none.
	var cap := {}
	for ti in order:
		_leaves_on(cfg, tendrils[ti], inv, total, sun, rng, leaves, cap,
			float(cfg.card_leaf_density) if card_set.has(ti) else float(cfg.leaf_density), strand_of.get(ti, -1),
			strands[strand_of[ti]][2] if strand_of.has(ti) else 1.0)
	# Surfaces by name (stems / leaves / cards; empty ones left out): WorldVines puts each
	# one's material on by name.
	var mesh := ArrayMesh.new()
	for part in [["stems", stems], ["leaves", leaves], ["cards", cards], ["moss", moss]]:
		var b: Buf = part[1]
		if not b.verts.is_empty():
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, b.arrays(), [], {}, FORMAT)
			mesh.surface_set_name(mesh.get_surface_count() - 1, part[0])
	stems.cur_uv2 = Vector2.ZERO
	mesh.set_meta(&"strands", strands)
	return mesh


## Leaves along a tendril: alternating sides, on short stalks, lifted off the surface, the
## younger (smaller) towards its tip, a few bunched at the tip.
static func _leaves_on(cfg: Dictionary, t: Tendril, inv: Transform3D, total: float, sun: Vector3,
		rng: RandomNumberGenerator, buf: Buf, cap: Dictionary, density: float, strand := -1, strand_len := 1.0) -> void:
	var cap_n: int = int(cfg.leaf_cap)
	var cell: float = maxf(float(cfg.leaf_cap_cell), 0.05)
	var n := t.points.size()
	var len := t.dist[n - 1] - t.dist[0]
	var count := int(len * density)
	var side := 1.0
	var scatter: float = float(cfg.leaf_scatter)
	# Where they go: spread along the stem, but with leaf_scatter some gathered into clumps
	# (a clump's leaves within ~15 cm of its middle) and gaps between.
	var spots := PackedFloat32Array()
	var clump_at := -1.0
	var clump_left := 0
	for j in count:
		if clump_left > 0:
			spots.append(clampf(clump_at + rng.randf_range(-0.15, 0.15), 0.0, len))
			clump_left -= 1
		elif rng.randf() < scatter:
			clump_at = rng.randf() * len
			clump_left = rng.randi_range(1, 3)
			spots.append(clump_at)
		else:
			spots.append(rng.randf() * len)
	spots.append(len * rng.randf_range(0.9, 1.0))
	spots.append(len * rng.randf_range(0.9, 1.0))
	# (hanging strands: hang_leaves times the leaves along their hanging stretch)
	if strand >= 0:
		var h0 := t.dist[t.hang_from] - t.dist[0]
		for e in int((len - h0) * density * maxf(float(cfg.hang_leaves) - 1.0, 0.0)):
			spots.append(rng.randf_range(h0, len))
	var bare: float = float(cfg.bare_start)
	var ramp: float = maxf(float(cfg.bare_ramp), 0.01)
	for j in spots.size():
		var at := t.dist[0] + spots[j]
		# (bare near the source: none for bare_start metres, then fading in over bare_ramp)
		if bare > 0.0 and rng.randf() > clampf((at - bare) / ramp, 0.0, 1.0):
			continue
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
		var hanging := strand >= 0 and i >= t.hang_from
		if hanging:
			age = 1.0  # (full-size leaves right to a hanging strand's end)
		# (some smaller, some bigger: leaf_jitter either way, a squared spread so most stay near)
		var jit: float = cfg.leaf_jitter
		var sz := rng.randf_range(-1.0, 1.0)
		var size: float = cfg.leaf_size * (1.0 + jit * sz * absf(sz) * (0.6 if sz > 0.0 else 1.0)) * lerpf(0.6, 1.0, age)
		# The leaf points out to the side and forwards, tipped up off the surface (with
		# leaf_scatter: turned and tipped further, some back over the stem).
		if rng.randf() < scatter * 0.25:
			side = -side  # (now and then two on one side)
		var lean := deg_to_rad(rng.randf_range(20.0 - 30.0 * scatter, 60.0 + 25.0 * scatter))
		var dir := (across * side).rotated(surf, side * lean * 0.6)
		dir = dir.rotated(dir.cross(surf).normalized(), -deg_to_rad(cfg.leaf_lift) * rng.randf_range(0.4, 1.2 + scatter))
		dir = dir.normalized()
		var width := dir.cross(surf).normalized()
		if width.length() < 0.5:
			width = along
		# (a little roll about its own length; mirrored half the time)
		width = width.rotated(dir, rng.randf_range(-0.5, 0.5) * scatter)
		if rng.randf() < 0.5:
			width = -width
		var reach := t.radius * (0.8 + rng.randf_range(0.0, 2.5) * scatter)
		var base := p + across * side * reach + surf * t.radius * 0.3
		if cap_n > 0 and not hanging:
			# (already as many leaves here as the cap allows: the ones on top got there first)
			var key := Vector3i((base / cell).floor())
			var had: int = cap.get(key, 0)
			if had >= cap_n:
				continue
			cap[key] = had + 1
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
			# One triangle round the leaf or sprig (cfg.leaf_tri: its corners in texture space,
			# reaching past the texture where it must - the shader cuts that away). A texture
			# point (u, v) sits at base + across (u - 0.5) + out (1 - v), in leaf sizes.
			var ids := []
			# (on a hanging strand: swung with it, no flutter of their own)
			buf.cur_uv2 = Vector2(strand + 1, clampf((at - t.dist[t.hang_from]) / strand_len, 0.0, 1.0)) if hanging else Vector2.ZERO
			for uv: Vector2 in cfg.leaf_tri:
				var q := base + w * (uv.x - 0.5) + dir * size * (1.0 - uv.y)
				var c := tint
				c.a = 0.0 if hanging else clampf(1.0 - uv.y, 0.0, 1.0)
				ids.append(buf.add(inv * q, ln, uv, c, b, grow_t))
			buf.tri(ids[0], ids[2], ids[1])
			buf.cur_uv2 = Vector2.ZERO
		else:
			w *= 0.5
			var q := [base - w, base + w, base + w + dir * size, base - w + dir * size]
			var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
			var ids := []
			for v in 4:
				ids.append(buf.add(inv * (q[v] as Vector3), ln, uvs[v], tint if v < 2 else tip_col, b, grow_t))
			buf.tri(ids[0], ids[2], ids[1])
			buf.tri(ids[0], ids[3], ids[2])


## A vine card: the whole run one strip lying on the surface (hanging: facing out from it),
## `width` wide, the card texture tiling along it (a tile per `tile` metres), lifted `lift`
## (a little more for vines higher in the pecking order, so overlaps don't flicker).
## `vary`: [start in the pattern (tiles), mirrored, repeat length scale, swell phase, amount].
static func _card_strip(buf: Buf, rings: Array, j0: int, j1: int, from: Vector3, sun: Vector3, width: float,
		lift: float, tile: float, vary: Array = [0.0, false, 1.0, 0.0, 0.0]) -> void:
	var phase: float = vary[0]
	var mirror: bool = vary[1]
	tile *= float(vary[2])
	var swell_at: float = vary[3]
	var swell: float = 0.3 * float(vary[4])
	var base := buf.verts.size()
	var prev_c := from
	for j in range(j0, j1 + 1):
		var g: Dictionary = rings[j]
		var surf: Vector3 = g.surf
		var p: Vector3 = g.on if g.free else g.on + surf * lift
		var light := 0.55 + 0.45 * maxf(surf.dot(sun), 0.0)
		# (wider and narrower along it: its leaves bigger and smaller)
		var wj := width * (1.0 + swell * sin(float(g.g) * 40.0 + swell_at) * sin(float(g.g) * 17.0 + swell_at * 2.0))
		for e in 2:
			var s := -0.5 if e == 0 else 0.5
			var u := float(e) if not mirror else 1.0 - float(e)
			buf.cur_uv2 = Vector2(g.st + 1, g.sw) if g.st >= 0 else Vector2.ZERO
			buf.add(p + (g.side as Vector3) * wj * s, surf, Vector2(u, 0.0), Color(light, light, light, g.w), prev_c, g.g)
		prev_c = p
	# (v along: metres travelled over the tile length)
	var along := 0.0
	var count := j1 - j0 + 1
	for j in count:
		if j > 0:
			along += (buf.verts[base + j * 2] - buf.verts[base + (j - 1) * 2]).length()
		buf.uvs[base + j * 2].y = phase + along / maxf(tile, 0.01)
		buf.uvs[base + j * 2 + 1].y = phase + along / maxf(tile, 0.01)
	for j in count - 1:
		var a := base + j * 2
		buf.tri(a, a + 2, a + 1)
		buf.tri(a + 1, a + 2, a + 3)


static func rank_lift(order: Array, ti: int) -> float:
	return 0.004 + 0.004 * (1.0 - order.find(ti) / maxf(order.size(), 1.0))


## Moss under a vine: a band moss_width wide along its stretch on surfaces (not hanging), in
## three strips across (alpha 0 at both edges, 1 down the middle), fading in from the roots and
## out at the tip; texture in metres (moss_tile a repeat), so bands blend into one patch.
static func _moss_band(buf: Buf, rings: Array, from: Vector3, cfg: Dictionary, lift: float) -> void:
	var w: float = cfg.moss_width
	var tile := maxf(float(cfg.moss_tile), 0.1)
	var runs := []
	var cur := []
	for j in rings.size():
		var g: Dictionary = rings[j]
		if g.free:
			if cur.size() > 1:
				runs.append(cur)
			cur = []
		else:
			cur.append(j)
	if cur.size() > 1:
		runs.append(cur)
	for run in runs:
		var base := buf.verts.size()
		var prev_c := from
		var along := 0.0
		var total := 0.0
		for q in range(1, run.size()):
			total += ((rings[run[q]] as Dictionary).on - (rings[run[q - 1]] as Dictionary).on).length()
		for q in run.size():
			var g: Dictionary = rings[run[q]]
			if q > 0:
				along += ((g.on as Vector3) - ((rings[run[q - 1]] as Dictionary).on as Vector3)).length()
			var surf: Vector3 = g.surf
			var p: Vector3 = (g.on as Vector3) + surf * lift
			# (thin at the tip and right at the roots, widest between; a slow wobble)
			var ends: float = smoothstep(0.0, 0.6, along) * smoothstep(0.0, 1.2, total - along)
			var ww: float = w * (0.55 + 0.45 * ends) * (1.0 + 0.25 * sin(along * 2.3 + float(run[0])))
			for e in 3:
				var s := float(e) - 1.0
				var vpos := p + (g.side as Vector3) * ww * 0.5 * s
				var a: float = (1.0 - absf(s)) * ends
				# (UVs from the surface position, so overlapping bands' moss lines up)
				var uv := Vector2(vpos.x + vpos.y * 0.7, vpos.z - vpos.y * 0.7) / tile
				buf.add(vpos, surf, uv, Color(1, 1, 1, a), prev_c, g.g)
			prev_c = p
		for q in run.size() - 1:
			var a: int = base + q * 3
			for e in 2:
				buf.tri(a + e, a + 3 + e, a + e + 1)
				buf.tri(a + e + 1, a + 3 + e, a + 4 + e)


## A 3D run of rings j0..j1: a tube (flat back down) or, on the ground, a sunk tent.
static func _tube(buf: Buf, rings: Array, j0: int, j1: int, from: Vector3, sides: int, open_back: bool,
		sink: float, tent_sink: float, tent_width: float, sun: Vector3) -> void:
	var base := buf.verts.size()
	var prev_c := from
	for j in range(j0, j1 + 1):
		var g: Dictionary = rings[j]
		var r: float = g.r
		var surf: Vector3 = g.surf
		var tent: bool = g.tent
		if tent:
			r *= tent_width
		# (the centre: tents with their middle at the surface less tent_sink, tubes resting on
		# it, hanging strands where they hang)
		var p: Vector3 = g.on if g.free else g.on + surf * (-r * tent_sink if tent else r * (1.0 - sink))
		var start := PI * 0.5 if tent else -PI * 0.5 + PI / sides
		for e in sides + 1:
			var ang := start + TAU * e / sides
			var nrm: Vector3 = g.side * cos(ang) + g.up * sin(ang)
			var light := 0.5 + 0.5 * maxf(nrm.dot(sun), 0.0)
			light *= lerpf(0.55, 1.0, clampf(nrm.dot(surf) * 0.5 + 0.5, 0.0, 1.0))  # (dark where it meets the surface)
			buf.cur_uv2 = Vector2(g.st + 1, g.sw) if g.st >= 0 else Vector2.ZERO
			buf.add(p + nrm * r, nrm, Vector2(float(e) / sides, g.v), Color(light, light, light, g.w), prev_c, g.g)
		prev_c = p
	for j in range(j1 - j0):
		var tent: bool = rings[j0 + j].tent
		var free: bool = rings[j0 + j].free and rings[j0 + j + 1].free
		for e in sides:
			if not free and (tent or open_back):
				# (a face whose middle points down into the surface is never seen)
				var mid := (PI * 0.5 if tent else -PI * 0.5 + PI / sides) + TAU * (e + 0.5) / sides
				if (tent and sin(mid) < 0.01) or (not tent and sin(mid) < -0.99):
					continue
			var a := base + j * (sides + 1) + e
			var b := a + sides + 1
			buf.tri(a, b, a + 1)
			buf.tri(a + 1, b, b + 1)


## A flat run of rings j0..j1: one face lying on the surface (the base fill), in the shade
## of what's on top of it.
static func _strip(buf: Buf, rings: Array, j0: int, j1: int, from: Vector3, sun: Vector3) -> void:
	var base := buf.verts.size()
	var prev_c := from
	for j in range(j0, j1 + 1):
		var g: Dictionary = rings[j]
		var surf: Vector3 = g.surf
		var p: Vector3 = g.on + surf * 0.012
		var light := (0.5 + 0.5 * maxf(surf.dot(sun), 0.0)) * 0.72
		for e in 2:
			var s := -1.0 if e == 0 else 1.0
			buf.add(p + (g.side as Vector3) * g.r * s, surf, Vector2(float(e), g.v), Color(light, light, light, 0.0), prev_c, g.g)
		prev_c = p
	for j in range(j1 - j0):
		var a := base + j * 2
		buf.tri(a, a + 2, a + 1)
		buf.tri(a + 1, a + 2, a + 3)


## Pecking order (lower = on top): trunks before branches, thicker before thinner.
static func _rank(t: Tendril) -> float:
	return t.depth * 10.0 - t.radius


## Per tendril, per segment (between kept rings): 1 where a vine ranked above it crosses or
## lies along it (within their radii), else 0.
static func _covered(tendrils: Array[Tendril], keeps: Array[PackedInt32Array], cfg: Dictionary) -> Array:
	var cell := 0.5
	var grid := {}  # Vector3i -> [[tendril, a, b, r]]
	for ti in tendrils.size():
		var t := tendrils[ti]
		var keep := keeps[ti]
		for j in keep.size() - 1:
			var a := t.points[keep[j]]
			var b := t.points[keep[j + 1]]
			var lo := Vector3i(((a.min(b) - Vector3.ONE * 0.2) / cell).floor())
			var hi := Vector3i(((a.max(b) + Vector3.ONE * 0.2) / cell).floor())
			for x in range(lo.x, hi.x + 1):
				for y in range(lo.y, hi.y + 1):
					for z in range(lo.z, hi.z + 1):
						var key := Vector3i(x, y, z)
						if not grid.has(key):
							grid[key] = []
						grid[key].append([ti, a, b, t.radius])
	var out := []
	for ti in tendrils.size():
		var t := tendrils[ti]
		var keep := keeps[ti]
		var rank := _rank(t)
		var f := PackedByteArray()
		f.resize(maxi(keep.size() - 1, 0))
		for j in keep.size() - 1:
			var a := t.points[keep[j]]
			var b := t.points[keep[j + 1]]
			var under := false
			for q in [a, (a + b) * 0.5, b]:
				var key := Vector3i(((q as Vector3) / cell).floor())
				for e in grid.get(key, []):
					var o: int = e[0]
					if o == ti or (_rank(tendrils[o]) > rank or (_rank(tendrils[o]) == rank and o > ti)):
						continue
					var cp := Geometry3D.get_closest_point_to_segment(q, e[1], e[2])
					if cp.distance_to(q) < (t.radius + float(e[3])) * 0.9:
						under = true
						break
				if under:
					break
			f[j] = 1 if under else 0
		out.append(f)
	return out


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
