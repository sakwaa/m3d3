class_name LevelLighting
extends RefCounted
## Bakes N64-style vertex lighting into LevelBrush.corner_lighting (one colour per face
## corner): ambient sky/ground light x ambient occlusion, plus DirectionalLight3D and
## OmniLight3D nodes from the scene with ray-traced shadows. Corner normals are smoothed
## only across faces within SMOOTH_ANGLE, so boxes keep hard edges and cylinders shade
## smoothly. Lights whose Bake Mode is Disabled are skipped.

const SMOOTH_ANGLE := 50.0
const BIAS := 0.03
## Vertex AO is read this far in from a vertex, towards the middle of the faces that meet
## there (at most 40% of the way): exactly at a corner it sits in the contact shadow of
## whatever touches it (a beam, a sill, the eaves) and one dark value would spread over the
## whole big face it bounds. A vertex in the middle of a flat area stays put.
const AO_INSET := 0.0


## Every occluder triangle in a private physics space: shadow / AO rays use the physics
## engine's BVH instead of testing triangles one by one (thousands of times faster on big
## terrain). Freed with the last reference (the bake's occluder list).
class Occluders extends RefCounted:
	var space: RID
	var body: RID
	var shape: RID
	var state: PhysicsDirectSpaceState3D
	var query := PhysicsRayQueryParameters3D.new()

	func _init(tris: PackedVector3Array) -> void:
		space = PhysicsServer3D.space_create()
		PhysicsServer3D.space_set_active(space, true)
		shape = PhysicsServer3D.concave_polygon_shape_create()
		PhysicsServer3D.shape_set_data(shape, {faces = tris, backface_collision = true})
		body = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_add_shape(body, shape)
		PhysicsServer3D.body_set_space(body, space)
		state = PhysicsServer3D.space_get_direct_state(space)
		query.hit_back_faces = true
		query.hit_from_inside = true

	func blocked(from: Vector3, to: Vector3) -> bool:
		query.from = from
		query.to = to
		return not state.intersect_ray(query).is_empty()

	## First hit from `from` towards `to`: {position, normal} or {}.
	func cast(from: Vector3, to: Vector3) -> Dictionary:
		query.from = from
		query.to = to
		return state.intersect_ray(query)

	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE:
			PhysicsServer3D.free_rid(body)
			PhysicsServer3D.free_rid(shape)
			PhysicsServer3D.free_rid(space)


## Occluders for a level's visible brushes (world space), for surface queries.
static func level_occluders(root: LevelRoot) -> Occluders:
	var all := PackedVector3Array()
	for o in _triangle_lists([root]):
		all.append_array(o.tris)
	return Occluders.new(all) if not all.is_empty() else null


## Light3D nodes under `node` that should contribute.
static func gather_lights(node: Node) -> Array[Light3D]:
	var out: Array[Light3D] = []
	_collect_lights(node, out)
	return out


## Plain descriptions of light nodes: {type: "sun" | "omni", dir / pos, color (Vector3,
## energy applied), range, yaw}. The first DirectionalLight3D counts as the sun.
static func describe(lights: Array) -> Array:
	var out := []
	for light: Light3D in lights:
		var col := Vector3(light.light_color.r, light.light_color.g, light.light_color.b) * light.light_energy
		if light is DirectionalLight3D:
			out.append({type = "sun", dir = light.global_basis.z.normalized(), color = col, yaw = light.global_rotation.y})
		elif light is OmniLight3D:
			out.append({type = "omni", pos = light.global_position, color = col, range = (light as OmniLight3D).omni_range})
	return out


## New corner_lighting per brush of `target`: {LevelBrush: PackedColorArray}.
## `occluders`: LevelRoots whose geometry casts shadows / occlusion (usually all in scene).
## `lights`: Light3D nodes, or describe() output. `ambient`: optional [sky, ground].
## `ao_cache` (brush -> AO per corner): filled on the first call, reused after (Baked Timed
## lights the same geometry once per key; AO doesn't change between keys). `occluders` may
## be a list prepared by _occluder_list (reused across keys).
static func bake(target: LevelRoot, occluders: Array, lights: Array, ambient := [], ao_cache = null) -> Dictionary:
	var data := target.data
	if not lights.is_empty() and lights[0] is Light3D:
		lights = describe(lights)
	lights = _lift_suns(lights, data.light_min_sun_elevation)
	var sky: Color = ambient[0] if ambient.size() == 2 else data.light_sky
	var ground: Color = ambient[1] if ambient.size() == 2 else data.light_ground
	var occ := occluders if _is_prepared(occluders) else _occluder_list(occluders)
	var samples := _hemisphere(data.light_ao_samples)
	var smooth := cos(deg_to_rad(SMOOTH_ANGLE))
	var out := {}
	for brush in data.brushes:
		if brush == null:
			continue
		brush.ensure_geometry()
		var xf := target.brush_global_transform(brush)
		var nb := xf.basis.inverse().transposed()
		var vfaces := brush.get_vertex_faces()
		var colors := PackedColorArray()
		colors.resize(brush.face_indices.size())
		var ao_list: PackedFloat32Array = ao_cache.get(brush, PackedFloat32Array()) if ao_cache is Dictionary else PackedFloat32Array()
		var ao_known := ao_list.size() == brush.face_indices.size()
		if not ao_known:
			ao_list.resize(brush.face_indices.size())
		# With baked vertex AO the shader darkens by it already: the ambient here stays open
		# (occluding it as well squared the AO, near black under the contrast curve).
		var own_ao := brush.vertex_ao.is_empty()
		for f in brush.get_face_count():
			var nf := brush.get_face_normal(f)
			var ids := brush.get_face_vertex_ids(f)
			var start := brush.get_face_start(f)
			for k in ids.size():
				var vi := ids[k]
				var ns := Vector3.ZERO
				for g in vfaces[vi]:
					var ng := brush.get_face_normal(g)
					if ng.dot(nf) >= smooth:
						ns += ng
				var n := (nb * (ns if ns != Vector3.ZERO else nf)).normalized()
				var ao := 1.0
				if own_ao:
					ao = ao_list[start + k] if ao_known else _ambient_occlusion(xf * brush.vertices[vi] + n * BIAS, n, data, occ, samples)
				ao_list[start + k] = ao
				colors[start + k] = _light_point(xf * brush.vertices[vi], n, data, sky, ground, lights, occ, ao)
		out[brush] = colors
		if ao_cache is Dictionary:
			ao_cache[brush] = ao_list
	_share_corner_lighting(target, out)
	return out


## Corners of different brushes at the same spot with the same smoothed normal (e.g. a
## passage floor meeting the room floor) share their averaged lighting: no seam.
static func _share_corner_lighting(target: LevelRoot, lit: Dictionary) -> void:
	var smooth := cos(deg_to_rad(SMOOTH_ANGLE))
	var groups := {}
	for brush: LevelBrush in lit:
		var xf := target.brush_global_transform(brush)
		var nb := xf.basis.inverse().transposed()
		for f in brush.get_face_count():
			var start := brush.get_face_start(f)
			var corners := brush.get_corner_normals(f, SMOOTH_ANGLE)
			var ids := brush.get_face_vertex_ids(f)
			for k in ids.size():
				var n := (nb * corners[k]).normalized()
				var key: Array = [((xf * brush.vertices[ids[k]]) / 0.002).round(), (n / 0.1).round()]
				if not groups.has(key):
					groups[key] = []
				groups[key].append([brush, start + k])
	for key in groups:
		var g: Array = groups[key]
		if g.size() < 2:
			continue
		var brushes := {}
		var sum := Color(0, 0, 0, 0)
		for e in g:
			brushes[e[0]] = true
			sum += lit[e[0]][e[1]]
		if brushes.size() < 2:
			continue
		var avg := sum / float(g.size())
		for e in g:
			var arr: PackedColorArray = lit[e[0]]
			arr[e[1]] = avg
			lit[e[0]] = arr


## Ambient occlusion per vertex for vertex colours ("dirty vertex colours"): 1 = open,
## darker where geometry within `radius` blocks the hemisphere. Normals are fully smoothed,
## so a vertex in an inside corner looks along the corner's bisector and darkens.
## Returns {LevelBrush: PackedFloat32Array (per vertex)}.
## Windows and doors (their frames, sills, reveals) don't occlude other surfaces: a frame a
## few centimetres deep would darken the wall round it in a box the wall's few vertices
## can't round off (a dark column under every window). They take AO themselves.
## In Build & Play (BuildCache.active) each brush's result is kept, keyed on the brush and
## every occluder within `radius` of it: an edit re-bakes only the brushes near it.
## `only`: just these brushes (all if empty). `errors`: filled with {brush: {face: [miss,
## point]}}, how far each face's fitted shading misses its readings (AOSubdivide).
static func bake_vertex_ao(target: LevelRoot, occluders: Array, strength: float, radius: float, sample_count := 24,
		only := {}, errors := {}) -> Dictionary:
	var occ_all := _occluder_list(occluders)
	var occ_walls := _occluder_list(occluders.filter(func(o): return o is LevelRoot), true)
	var samples := _hemisphere(sample_count)
	var cache := preload("res://addons/n64_level_tools/export/build_cache.gd")
	var near_all := _triangle_lists(occluders) if cache.active else []
	var near_walls := _triangle_lists(occluders.filter(func(o): return o is LevelRoot), true) if cache.active else []
	var setup := [cache.pipeline_hash(), strength, radius, sample_count, AO_FIT_DENSITY, AO_FIT_PRIOR] if cache.active else []
	var out := {}
	for brush in target.data.brushes:
		if brush == null or (not only.is_empty() and not only.has(brush)):
			continue
		brush.ensure_geometry()
		var xf := target.brush_global_transform(brush)
		var nb := xf.basis.inverse().transposed()
		var key := 0
		if cache.active:
			var box := xf * brush.local_aabb()
			var near := []
			for e: Dictionary in (near_all if brush.window or brush.door else near_walls):
				if (e.aabb as AABB).intersects(box.grow(radius)):
					near.append(hash(e.tris))
			near.sort()
			key = cache.key([setup, xf, brush.vertices, brush.face_indices, brush.face_counts, brush.face_lod, brush.face_bake,
				brush.window != null or brush.door != null, near])
			var kept = cache.read("ao_fit", key)
			if kept is Array and kept.size() == 2 and kept[0] is PackedFloat32Array and kept[0].size() == brush.vertices.size():
				out[brush] = kept[0]
				errors[brush] = kept[1]
				continue
		var vn := brush.get_vertex_normals()
		var inset := _ao_inset_points(brush)
		var occ: Array = occ_all if brush.window or brush.door else occ_walls
		var ao := PackedFloat32Array()
		ao.resize(brush.vertices.size())
		for i in brush.vertices.size():
			var n := (nb * vn[i]).normalized()
			if n == Vector3.ZERO:
				ao[i] = 1.0
				continue
			var origin := xf * inset[i] + n * BIAS
			var t1 := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
			var t2 := n.cross(t1)
			var blocked := 0
			for smp in samples:
				if _occluded(origin, origin + (t1 * smp.x + t2 * smp.y + n * smp.z) * radius, occ):
					blocked += 1
			ao[i] = 1.0 - strength * float(blocked) / samples.size()
		var err := {}
		if AO_FIT_DENSITY > 0.0:
			var fit := _fit_vertex_ao(brush, xf, nb, ao, occ, _hemisphere(maxi(sample_count / 2, 8)), strength, radius)
			ao = fit.ao
			err = fit.err
		out[brush] = ao
		errors[brush] = err
		if cache.active:
			cache.write("ao_fit", key, [ao, err])
	if only.is_empty():
		_share_vertex_ao(target, out)
	return out


## Least-squares vertex baking (after Kavan et al. 2011): AO read densely over each drawn
## face (AO_FIT_DENSITY samples a metre, at least six per triangle), then the vertex values
## whose blend across the triangles best matches those readings. A vertex's own reading
## (`prior`) only pulls gently (AO_FIT_PRIOR), so a corner pressed against a beam or a
## sill takes the value that suits its whole face, not its contact shadow; vertices only far
## stand-ins use keep it. The dense readings take half the rays (they average out anyway).
## Returns the fitted values (0..1).
const AO_FIT_DENSITY := 0.0
const AO_FIT_PRIOR := 0.02
const AO_FIT_PASSES := 80


## AO readings by spot while a build refines its faces (ExportBake turns it on and off).
static var ao_memo_on := false:
	set(v):
		ao_memo_on = v
		_ao_memo.clear()
static var _ao_memo := {}


static func _fit_vertex_ao(brush: LevelBrush, xf: Transform3D, nb: Basis, prior: PackedFloat32Array, occ: Array,
		samples: PackedVector3Array, strength: float, radius: float) -> Dictionary:
	# Vertices at the same spot are one unknown (faces split apart by the build's cuts keep
	# their own copies; solved apart they'd differ and draw a seam).
	var group := PackedInt32Array()
	group.resize(brush.vertices.size())
	var at := {}
	for i in brush.vertices.size():
		var key := (brush.vertices[i] / 0.001).round()
		if not at.has(key):
			at[key] = at.size()
		group[i] = at[key]
	var nv := at.size()
	var ata: Array[Dictionary] = []  # per vertex: other vertex -> sum of weight products
	ata.resize(nv)
	for i in nv:
		ata[i] = {}
	var diag := PackedFloat32Array()
	diag.resize(nv)
	var rhs := PackedFloat32Array()
	rhs.resize(nv)
	var readings := []  # [face, groups, weights, value, brush-space point]
	for f in brush.get_face_count():
		if not brush.face_visual(f) or brush.get_face_lod(f) in [LevelBrush.LOD_FAR, LevelBrush.LOD_DETAIL_FAR]:
			continue
		var ids := brush.get_face_vertex_ids(f)
		var pts := PackedVector3Array()
		for vi in ids:
			pts.append(brush.vertices[vi])
		var nl := brush.get_face_normal(f)
		var n := (nb * nl).normalized()
		if n == Vector3.ZERO:
			continue
		var t1 := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
		var t2 := n.cross(t1)
		var order := PolyUtil.triangulate(pts, nl)
		for t in range(0, order.size(), 3):
			var pa: Vector3 = brush.vertices[ids[order[t]]]
			var pb: Vector3 = brush.vertices[ids[order[t + 1]]]
			var pc: Vector3 = brush.vertices[ids[order[t + 2]]]
			var tv := [group[ids[order[t]]], group[ids[order[t + 1]]], group[ids[order[t + 2]]]]
			var area := (xf.basis * (pb - pa)).cross(xf.basis * (pc - pa)).length() * 0.5
			# k rows of samples: k (k + 1) / 2 points, about area x density^2 of them.
			var k := clampi(ceili(sqrt(2.0 * area * AO_FIT_DENSITY * AO_FIT_DENSITY)), 3, 16)
			for i in k:
				for j in k - i:
					var u := (i + 1.0 / 3.0) / k
					var v := (j + 1.0 / 3.0) / k
					var w := PackedFloat32Array([1.0 - u - v, u, v])
					var origin: Vector3 = xf * (pa * w[0] + pb * w[1] + pc * w[2]) + n * BIAS
					# (Readings kept by spot and normal while a build refines: faces left
					# uncut read the same spots again.)
					var mkey := [(origin / 0.001).round(), (n / 0.01).round(), occ.size()]
					var val: float = _ao_memo.get(mkey, -1.0)
					if val < 0.0:
						var blocked := 0
						for smp in samples:
							if _occluded(origin, origin + (t1 * smp.x + t2 * smp.y + n * smp.z) * radius, occ):
								blocked += 1
						val = 1.0 - strength * float(blocked) / samples.size()
						if ao_memo_on:
							_ao_memo[mkey] = val
					readings.append([f, tv, w, val, pa * w[0] + pb * w[1] + pc * w[2]])
					for a in 3:
						var va: int = tv[a]
						rhs[va] += w[a] * val
						for b in 3:
							var vb: int = tv[b]
							if va == vb:
								diag[va] += w[a] * w[b]
							else:
								ata[va][vb] = ata[va].get(vb, 0.0) + w[a] * w[b]
	# Gauss-Seidel on (AtA + prior) x = Atb + prior x0 (a spot's prior: its vertices' mean).
	var x0 := PackedFloat32Array()
	x0.resize(nv)
	var count := PackedInt32Array()
	count.resize(nv)
	for i in brush.vertices.size():
		x0[group[i]] += prior[i]
		count[group[i]] += 1
	for g in nv:
		x0[g] /= maxi(count[g], 1)
	var x := x0.duplicate()
	for i in nv:
		diag[i] += AO_FIT_PRIOR
		rhs[i] += AO_FIT_PRIOR * x0[i]
	for pass_i in AO_FIT_PASSES:
		for i in nv:
			var sum := rhs[i]
			var row: Dictionary = ata[i]
			for j in row:
				sum -= row[j] * x[j]
			x[i] = sum / diag[i]
	var out := PackedFloat32Array()
	out.resize(brush.vertices.size())
	for i in out.size():
		out[i] = clampf(x[group[i]], 0.0, 1.0)
	# How far the fitted shading misses each face's readings (the worst one, and where).
	var err := {}  # face -> [miss, brush-space point]
	for r in readings:
		var tv: Array = r[1]
		var w: PackedFloat32Array = r[2]
		var miss := absf(clampf(x[tv[0]], 0.0, 1.0) * w[0] + clampf(x[tv[1]], 0.0, 1.0) * w[1] + clampf(x[tv[2]], 0.0, 1.0) * w[2] - r[3])
		if miss > err.get(r[0], [-1.0])[0]:
			err[r[0]] = [miss, r[4]]
	return {ao = out, err = err}


## Where each vertex's AO is read (brush space, AO_INSET): moved towards the average of
## the middles of the faces using it.
static func _ao_inset_points(brush: LevelBrush) -> PackedVector3Array:
	var out := brush.vertices.duplicate()
	var mids := PackedVector3Array()
	for f in brush.get_face_count():
		var c := Vector3.ZERO
		var ids := brush.get_face_vertex_ids(f)
		for vi in ids:
			c += brush.vertices[vi]
		mids.append(c / maxf(ids.size(), 1))
	var vfaces := brush.get_vertex_faces()
	for i in out.size():
		if i >= vfaces.size() or vfaces[i].is_empty():
			continue
		var pull := Vector3.ZERO
		for f in vfaces[i]:
			pull += mids[f] - brush.vertices[i]
		pull /= vfaces[i].size()
		out[i] = brush.vertices[i] + pull.limit_length(minf(AO_INSET, pull.length() * 0.4))
	return out


## Brushes meeting edge to edge (a room floor and a passage floor) each bake their own
## vertices; where vertices of different brushes coincide, give them the averaged value
## so no seam shows along the join.
static func _share_vertex_ao(target: LevelRoot, ao: Dictionary) -> void:
	var groups := {}
	for brush: LevelBrush in ao:
		var xf := target.brush_global_transform(brush)
		for i in brush.vertices.size():
			var key := ((xf * brush.vertices[i]) / 0.002).round()
			if not groups.has(key):
				groups[key] = []
			groups[key].append([brush, i])
	for key in groups:
		var g: Array = groups[key]
		if g.size() < 2:
			continue
		var brushes := {}
		var sum := 0.0
		for e in g:
			brushes[e[0]] = true
			sum += ao[e[0]][e[1]]
		if brushes.size() < 2:
			continue
		var avg := sum / g.size()
		for e in g:
			var arr: PackedFloat32Array = ao[e[0]]
			arr[e[1]] = avg
			ao[e[0]] = arr


## One pass per key of the project LightingSchedule (sun direction from the key's hour,
## sun colour/energy, ambient, local-light multiplier). Returns {LevelBrush: Array of
## PackedColorArray (one per key, in slot order)}.
static func bake_keys(target: LevelRoot, occluders: Array, lights: Array, schedule: LightingSchedule) -> Dictionary:
	var base := describe(lights)
	var out := {}
	var occ := _occluder_list(occluders)
	var ao_cache := {}
	for key in schedule.sorted_keys():
		var keyed := []
		var sun_done := false
		for l in base:
			var d: Dictionary = l.duplicate()
			if d.type == "sun" and not sun_done:
				sun_done = true
				d.dir = LightingSchedule.sun_direction(key.hour, d.yaw)
				d.color = Vector3(key.sun_color.r, key.sun_color.g, key.sun_color.b) * key.sun_energy
			elif d.type == "omni":
				d.color = d.color * key.local_lights
			keyed.append(d)
		var lit := bake(target, occ, keyed, [key.sky, key.ground], ao_cache)
		for brush in lit:
			if not out.has(brush):
				out[brush] = []
			out[brush].append(lit[brush])
	return out


## Metres between the rain light grid's points, and the most points it may have.
const RAIN_CELL := 1.0
const RAIN_MAX_POINTS := 160000


## The light rain catches in the air around `target`'s lamps (omni lights): a grid of
## points every RAIN_CELL metres over the lamps' reach, each the lamps' light there with
## shadows (rain under a roof or behind a wall from a lamp stays dark). Stored on the level
## (LevelData.rain_light_*) for its RainCover to publish (n64_rain_light.gdshaderinc).
## Baked Timed levels keep each key's lamp strength (local_lights) to scale it by the hour.
static func bake_rain_light(target: LevelRoot, occluders: Array, lights: Array) -> void:
	var data := target.data
	if not lights.is_empty() and lights[0] is Light3D:
		lights = describe(lights)
	var lamps := lights.filter(func(l: Dictionary): return l.type == "omni" and l.color != Vector3.ZERO and l.range > 0.0)
	data.rain_light_image = null
	if lamps.is_empty():
		return
	var to_level := target.global_transform.affine_inverse()
	var box := AABB()
	for i in lamps.size():
		var l: Dictionary = lamps[i]
		var lb := AABB(to_level * l.pos - Vector3.ONE * l.range, Vector3.ONE * l.range * 2.0)
		box = lb if i == 0 else box.merge(lb)
	var cell := RAIN_CELL
	while (floori(box.size.x / cell) + 1) * (floori(box.size.y / cell) + 1) * (floori(box.size.z / cell) + 1) > RAIN_MAX_POINTS:
		cell *= 1.25
	var nx := floori(box.size.x / cell) + 1
	var ny := floori(box.size.y / cell) + 1
	var nz := floori(box.size.z / cell) + 1
	var occ := occluders if _is_prepared(occluders) else _occluder_list(occluders)
	var light := PackedVector3Array()
	light.resize(nx * ny * nz)
	var from_level := target.global_transform
	for l: Dictionary in lamps:
		var lp: Vector3 = to_level * l.pos
		var r: float = l.range
		var i0 := maxi(0, floori((lp.x - r - box.position.x) / cell))
		var i1 := mini(nx - 1, ceili((lp.x + r - box.position.x) / cell))
		var j0 := maxi(0, floori((lp.y - r - box.position.y) / cell))
		var j1 := mini(ny - 1, ceili((lp.y + r - box.position.y) / cell))
		var k0 := maxi(0, floori((lp.z - r - box.position.z) / cell))
		var k1 := mini(nz - 1, ceili((lp.z + r - box.position.z) / cell))
		for j in range(j0, j1 + 1):
			for k in range(k0, k1 + 1):
				for i in range(i0, i1 + 1):
					var p := box.position + Vector3(i, j, k) * cell
					var dist := p.distance_to(lp)
					if dist >= r:
						continue
					var atten := pow(1.0 - dist / r, 2.0)
					if atten < 0.004:
						continue
					var wp := from_level * p
					var wl: Vector3 = l.pos
					if dist > 0.1 and _occluded(wp, wl - (wl - wp).normalized() * 0.05, occ):
						continue
					light[(j * nz + k) * nx + i] += l.color * atten
	# RGBA8, light / 2 (lamps brighter than 1 still fit); one XZ layer per height, stacked.
	var img := Image.create(nx, nz * ny, false, Image.FORMAT_RGBA8)
	for j in ny:
		for k in nz:
			for i in nx:
				var c := light[(j * nz + k) * nx + i] * 0.5
				img.set_pixel(i, j * nz + k, Color(minf(c.x, 1.0), minf(c.y, 1.0), minf(c.z, 1.0), 1.0))
	var keys := Vector4.ONE
	if LevelData.mode_is_timed(data.lighting_mode):
		var schedule := LightingSchedule.load_project()
		if schedule:
			var sk := schedule.sorted_keys()
			for i in mini(sk.size(), 4):
				keys[i] = sk[i].local_lights
	data.rain_light_image = img
	data.rain_light_origin = box.position
	data.rain_light_cell = cell
	data.rain_light_layers = ny
	data.rain_light_keys = keys


## Ambient occlusion at `origin` (already lifted off the surface) facing `n`.
static func _ambient_occlusion(origin: Vector3, n: Vector3, data: LevelData, occ: Array, samples: PackedVector3Array) -> float:
	if data.light_ao_strength <= 0.0 or samples.is_empty():
		return 1.0
	var t1 := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var t2 := n.cross(t1)
	var blocked := 0
	for s in samples:
		var d := t1 * s.x + t2 * s.y + n * s.z
		if _occluded(origin, origin + d * data.light_ao_radius, occ):
			blocked += 1
	return 1.0 - data.light_ao_strength * float(blocked) / samples.size()


static func _light_point(p: Vector3, n: Vector3, data: LevelData, sky: Color, ground: Color, lights: Array,
		occ: Array, ao: float) -> Color:
	var origin := p + n * BIAS
	var amb := ground.lerp(sky, n.y * 0.5 + 0.5)
	var c := Vector3(amb.r, amb.g, amb.b) * ao
	for light in lights:
		var col: Vector3 = light.color
		if col == Vector3.ZERO:
			continue
		if light.type == "sun":
			var to_light: Vector3 = light.dir
			var ndl := n.dot(to_light)
			if ndl <= 0.0:
				continue
			if data.light_shadows and _occluded(origin, origin + to_light * 200.0, occ):
				continue
			c += col * ndl
		else:
			var d: Vector3 = light.pos - p
			var dist := d.length()
			if dist >= light.range or dist < 0.0001:
				continue
			var to_light := d / dist
			var ndl := n.dot(to_light)
			if ndl <= 0.0:
				continue
			if data.light_shadows and _occluded(origin, light.pos - to_light * 0.05, occ):
				continue
			var atten := pow(1.0 - dist / light.range, 2.0)
			c += col * ndl * atten
	c *= data.light_intensity
	return Color(clampf(c.x, 0.0, 1.0), clampf(c.y, 0.0, 1.0), clampf(c.z, 0.0, 1.0))


## Copies of `lights` with any sun lower than `min_deg` raised to it (same heading).
static func _lift_suns(lights: Array, min_deg: float) -> Array:
	if min_deg <= 0.0:
		return lights
	var min_y := sin(deg_to_rad(min_deg))
	var out := []
	for l: Dictionary in lights:
		var dir: Vector3 = l.get("dir", Vector3.UP)
		var flat := Vector3(dir.x, 0.0, dir.z)
		if l.type == "sun" and dir.y < min_y and flat.length_squared() > 1e-6:
			l = l.duplicate()
			l.dir = flat.normalized() * cos(deg_to_rad(min_deg)) + Vector3.UP * min_y
		out.append(l)
	return out


## World-space triangles of every visible brush, grouped per brush with an AABB.
## Occluders: LevelRoots, or {tris: PackedVector3Array (world)} for extra geometry such
## as door / passage dressing (see dressing_occluders()).
static func _occluder_list(roots: Array, skip_openings := false) -> Array:
	var occ := _triangle_lists(roots, skip_openings)
	var all := PackedVector3Array()
	for o in occ:
		all.append_array(o.tris)
	if all.is_empty():
		return occ
	var fast := Occluders.new(all)
	# Sanity check: a ray straight through the first triangle must hit.
	var c := (all[0] + all[1] + all[2]) / 3.0
	var n := (all[1] - all[0]).cross(all[2] - all[0]).normalized()
	if n != Vector3.ZERO and fast.blocked(c + n * 0.5, c - n * 0.5):
		return [{occluders = fast}]
	push_warning("LevelLighting: physics ray queries unavailable; using the slow exact test.")
	return occ


static func _is_prepared(occ: Array) -> bool:
	return not occ.is_empty() and occ[0] is Dictionary and (occ[0].has("occluders") or occ[0].has("aabb"))


## World-space triangles per occluder (with AABBs) for the exact fallback test.
static func _triangle_lists(roots: Array, skip_openings := false) -> Array:
	var occ := []
	for entry in roots:
		if entry is Dictionary:
			var tris: PackedVector3Array = entry.tris
			if tris.is_empty():
				continue
			var box := AABB(tris[0], Vector3.ZERO)
			for v in tris:
				box = box.expand(v)
			occ.append({aabb = box.grow(0.01), tris = tris})
			continue
		var root := entry as LevelRoot
		if root == null or root.data == null:
			continue
		for brush in root.data.brushes:
			# Cutout brushes (fences) are mostly holes: they don't cast baked shadows.
			if brush == null or brush.bake_mode == LevelBrush.BakeMode.COLLISION_ONLY or brush.cutout:
				continue
			if skip_openings and (brush.window or brush.door):
				continue
			brush.ensure_geometry()
			var xf := root.brush_global_transform(brush)
			var tris := PackedVector3Array()
			var box := AABB()
			var first := true
			for v in brush.get_occluder_triangle_positions():
				var w := xf * v
				tris.append(w)
				box = AABB(w, Vector3.ZERO) if first else box.expand(w)
				first = false
			if not tris.is_empty():
				occ.append({aabb = box.grow(0.01), tris = tris})
	return occ


static func _occluded(from: Vector3, to: Vector3, occ: Array) -> bool:
	if not occ.is_empty() and occ[0].has("occluders"):
		return occ[0].occluders.blocked(from, to)
	for o in occ:
		var box: AABB = o.aabb
		if box.intersects_segment(from, to) == null:
			continue
		var tris: PackedVector3Array = o.tris
		for t in range(0, tris.size(), 3):
			if Geometry3D.segment_intersects_triangle(from, to, tris[t], tris[t + 1], tris[t + 2]) != null:
				return true
	return false


## World triangles of every door / passage dressing and prop (stalls, signs) under
## `scene_root` (built at runtime by the node, so not part of any LevelRoot), as extra
## occluders for the bakes.
static func dressing_occluders(scene_root: Node) -> Array:
	var out := []
	if scene_root == null:
		return out
	for node in dressed_nodes(scene_root):
		var mi: MeshInstance3D = node.get(&"_dressing")
		var tris := PackedVector3Array()
		for v in mi.mesh.get_faces():
			tris.append(mi.global_transform * v)
		out.append({tris = tris})
	# Props (stalls, carts, signs): their near meshes shade the ground and walls around them.
	if not scene_root.is_inside_tree():
		return out
	for parts in scene_root.get_tree().get_nodes_in_group(PropBatch.GROUP):
		if not scene_root.is_ancestor_of(parts):
			continue
		var tris := PackedVector3Array()
		for mi: MeshInstance3D in PropBatch.meshes_of(parts):
			if mi.visibility_range_begin > 0.0:
				continue  # far stand-ins
			for v in mi.mesh.get_faces():
				tris.append(mi.global_transform * v)
		if not tris.is_empty():
			out.append({tris = tris})
	return out


## Doors / passages with a built dressing mesh.
static func dressed_nodes(scene_root: Node) -> Array:
	var out := []
	for node in scene_root.find_children("*", "Node3D", true, false):
		var mi = node.get(&"_dressing")
		if mi is MeshInstance3D and mi.mesh and mi.mesh.get_surface_count() > 0:
			out.append(node)
	return out


## AO for arbitrary world points / normals (dressing vertices): 1 = open.
static func bake_points_ao(points: PackedVector3Array, normals: PackedVector3Array, occluders: Array,
		strength: float, radius: float, sample_count := 16) -> PackedFloat32Array:
	var occ := _occluder_list(occluders)
	var samples := _hemisphere(sample_count)
	var ao := PackedFloat32Array()
	ao.resize(points.size())
	for i in points.size():
		var n := normals[i].normalized()
		var origin := points[i] + n * BIAS
		var t1 := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
		var t2 := n.cross(t1)
		var blocked := 0
		for smp in samples:
			if _occluded(origin, origin + (t1 * smp.x + t2 * smp.y + n * smp.z) * radius, occ):
				blocked += 1
		ao[i] = 1.0 - strength * float(blocked) / samples.size()
	return ao


## Cosine-weighted hemisphere directions (z up), Fibonacci-spiral distributed.
static func _hemisphere(count: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in count:
		var u := (i + 0.5) / count
		var r := sqrt(u)
		var phi := i * 2.3999632
		out.append(Vector3(cos(phi) * r, sin(phi) * r, sqrt(1.0 - u)))
	return out


static func _collect_lights(node: Node, out: Array[Light3D]) -> void:
	if node is Light3D and (node is DirectionalLight3D or node is OmniLight3D):
		var light := node as Light3D
		if light.is_visible_in_tree() and light.light_bake_mode != Light3D.BAKE_DISABLED:
			out.append(light)
	for child in node.get_children():
		_collect_lights(child, out)
