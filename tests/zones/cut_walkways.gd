extends Node
## Straight-edged dirt walkways for the market square (references/zones/market_square_green.json):
## cuts the ground brush exactly along every walkway's edges (rectangles; circles as
## octagons), retextures the cut faces (mud inside a walkway, green outside), relights the
## level (timed keys and rain light, as Bake Lighting does) and bakes. The walkways then
## merge into a few clean shapes instead of strips stair-stepped along the ground's grid.
##   godot --headless --path . tests/zones/cut_walkways.tscn   (editor closed)

const SCENE := "res://zones/town1/town_1_market_square.tscn"
const LEVEL := "res://zones/town1/town_1_market_square_level.res"
const PLAN := "res://references/zones/market_square_green.json"
const MUD := "res://textures/ground/mud.res"
const EPS := 0.001


func _ready() -> void:
	var plan: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PLAN))
	var zone: Node = (load(SCENE) as PackedScene).instantiate()
	add_child(zone)
	await get_tree().process_frame
	var root: LevelRoot = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	var data: LevelData = root.data
	var uid := ResourceLoader.get_resource_uid(LEVEL)
	var mud := -1
	for i in data.textures.size():
		if data.textures[i] and data.textures[i].resource_path == MUD:
			mud = i
	var green := data.textures.find(load(plan.green_texture))
	# The ground: the brush with the most upward faces.
	var ground: LevelBrush
	for b in data.brushes:
		if b and b.shape == BrushShapes.Shape.GRID and (ground == null or b.get_face_count() > ground.get_face_count()):
			ground = b
	print("ground brush: %d faces" % ground.get_face_count())
	var to_local := ground.transform.affine_inverse()
	# Cutting planes (level space): each walkway's edges, each only through the faces it touches.
	var cuts := []  # [normal, d, Rect2 (x, z bounds of the faces to cut)]
	for r: Array in plan.dirt_rects:
		var box := Rect2(r[0], r[1], r[2] - r[0], r[3] - r[1])
		cuts.append([Vector3.RIGHT, float(r[0]), box])
		cuts.append([Vector3.RIGHT, float(r[2]), box])
		cuts.append([Vector3.BACK, float(r[1]), box])
		cuts.append([Vector3.BACK, float(r[3]), box])
	for c: Array in plan.dirt_circles:
		var centre := Vector2(c[0], c[1])
		var rad: float = c[2]
		var box := Rect2(centre - Vector2.ONE * rad, Vector2.ONE * rad * 2.0)
		for k in 8:
			var a := TAU * k / 8.0
			var n := Vector3(cos(a), 0.0, sin(a))
			cuts.append([n, n.dot(Vector3(centre.x, 0.0, centre.y)) + rad, box])
	var verts := ground.vertices
	var faces := ground.get_faces()
	var rects := {}
	for f in faces.size():
		rects[f] = ground.get_face_planar_rect(f)
	var map := PackedInt32Array()
	for f in faces.size():
		map.append(f)
	var sources: Array[PackedInt32Array] = []
	for i in verts.size():
		sources.append(PackedInt32Array([i]))
	for cut in cuts:
		var box: Rect2 = (cut[2] as Rect2).grow(0.01)
		var only := {}
		for f in faces.size():
			var t := ground.get_face_texture(map[f])
			if t != mud and t != green:
				continue
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for v in faces[f]:
				var w := ground.transform * verts[v]
				lo = lo.min(Vector2(w.x, w.z))
				hi = hi.max(Vector2(w.x, w.z))
			if Rect2(lo, hi - lo).intersects(box, true):
				only[f] = true
		if only.is_empty():
			continue
		var nl: Vector3 = (to_local.basis * cut[0]).normalized()
		var dl: float = nl.dot(to_local * (cut[0] * cut[1]))
		var res := BrushOps.cut_plane(verts, faces, nl, dl, only)
		verts = res.verts
		faces = res.faces
		for pair in res.new_vertices:
			var src := PackedInt32Array(sources[pair.x])
			src.append_array(sources[pair.y])
			sources.append(src)
		var nm := PackedInt32Array()
		for f in res.map.size():
			nm.append(map[res.map[f]])
		map = nm
	ground.hand_edited = true
	ground.vertices = verts
	ground.set_faces(faces)
	ground.remap_faces(map)
	ground.blend_vertex_colors(sources)
	var parents := {}
	for f in map.size():
		parents[f] = rects[map[f]]
	ground.crop_child_masks(parents)
	# Retexture: mud inside a walkway, green outside (only faces that were one or the other).
	var ft := ground.face_textures.duplicate()
	var to_mud := 0
	var to_green := 0
	for f in ground.get_face_count():
		var t := ground.get_face_texture(f)
		if t != mud and t != green:
			continue
		var c := Vector3.ZERO
		var ids: PackedInt32Array = ground.get_faces()[f]
		for i in ids:
			c += ground.transform * ground.vertices[i]
		c /= ids.size()
		var want := mud if _dirt(plan, c.x, c.z) else green
		if want != t:
			if want == mud:
				to_mud += 1
			else:
				to_green += 1
		ft[f] = want
	ground.face_textures = ft
	print("ground now %d faces (%d to dirt, %d to green)" % [ground.get_face_count(), to_mud, to_green])
	# Relight, as Bake Lighting does it.
	var lights := LevelLighting.gather_lights(zone)
	var occluders: Array = [root] + LevelLighting.dressing_occluders(zone)
	LevelLighting.bake_rain_light(root, occluders, lights)
	var schedule := LightingSchedule.load_project()
	if LevelData.mode_is_timed(data.lighting_mode) and schedule:
		var baked_lights := lights
		if LevelData.mode_is_hybrid(data.lighting_mode):
			baked_lights = lights.filter(func(l: Light3D): return l.light_bake_mode == Light3D.BAKE_STATIC)
		var keyed := LevelLighting.bake_keys(root, occluders, baked_lights, schedule)
		for brush in keyed:
			var arr: Array[PackedColorArray] = []
			arr.assign(keyed[brush])
			brush.corner_lighting_keys = arr
		print("relit %d brushes" % keyed.size())
	var res := LevelBaker.bake(data, root.merge_coplanar)
	data.baked_mesh = res.mesh
	data.baked_chunks = res.chunks
	data.set_baked_collision(res)
	var err := ResourceSaver.save(data, LEVEL, ResourceSaver.FLAG_COMPRESS)
	if uid != ResourceUID.INVALID_ID:
		ResourceSaver.set_uid(LEVEL, uid)
	print("saved: %s, %d baked tris" % [error_string(err), res.stats.baked_tris])
	get_tree().quit()


func _dirt(plan: Dictionary, x: float, z: float) -> bool:
	for r: Array in plan.dirt_rects:
		if x >= r[0] - EPS and x <= r[2] + EPS and z >= r[1] - EPS and z <= r[3] + EPS:
			return true
	for c: Array in plan.dirt_circles:
		# The octagon the circle was cut as.
		var inside := true
		for k in 8:
			var a := TAU * k / 8.0
			if Vector2(cos(a), sin(a)).dot(Vector2(x - c[0], z - c[1])) > float(c[2]) + EPS:
				inside = false
				break
		if inside:
			return true
	return false
