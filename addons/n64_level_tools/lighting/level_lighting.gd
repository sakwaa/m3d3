class_name LevelLighting
extends RefCounted
## Bakes N64-style vertex lighting into LevelBrush.corner_lighting (one colour per face
## corner): ambient sky/ground light x ambient occlusion, plus DirectionalLight3D and
## OmniLight3D nodes from the scene with ray-traced shadows. Corner normals are smoothed
## only across faces within SMOOTH_ANGLE, so boxes keep hard edges and cylinders shade
## smoothly. Lights whose Bake Mode is Disabled are skipped.

const SMOOTH_ANGLE := 50.0
const BIAS := 0.03


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
				var ao := ao_list[start + k] if ao_known else _ambient_occlusion(xf * brush.vertices[vi] + n * BIAS, n, data, occ, samples)
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
static func bake_vertex_ao(target: LevelRoot, occluders: Array, strength: float, radius: float, sample_count := 24) -> Dictionary:
	var occ := _occluder_list(occluders)
	var samples := _hemisphere(sample_count)
	var out := {}
	for brush in target.data.brushes:
		if brush == null:
			continue
		brush.ensure_geometry()
		var xf := target.brush_global_transform(brush)
		var nb := xf.basis.inverse().transposed()
		var vn := brush.get_vertex_normals()
		var ao := PackedFloat32Array()
		ao.resize(brush.vertices.size())
		for i in brush.vertices.size():
			var n := (nb * vn[i]).normalized()
			if n == Vector3.ZERO:
				ao[i] = 1.0
				continue
			var origin := xf * brush.vertices[i] + n * BIAS
			var t1 := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
			var t2 := n.cross(t1)
			var blocked := 0
			for smp in samples:
				if _occluded(origin, origin + (t1 * smp.x + t2 * smp.y + n * smp.z) * radius, occ):
					blocked += 1
			ao[i] = 1.0 - strength * float(blocked) / samples.size()
		out[brush] = ao
	_share_vertex_ao(target, out)
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
static func _occluder_list(roots: Array) -> Array:
	var occ := _triangle_lists(roots)
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
static func _triangle_lists(roots: Array) -> Array:
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


## World triangles of every door / passage dressing under `scene_root` (built at runtime
## by the node, so not part of any LevelRoot), as extra occluders for the bakes.
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
