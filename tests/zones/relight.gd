extends Node
## Relights a zone's level as Bake Lighting does (vertex AO if the level uses it, timed keys
## or plain lighting, rain light), with its props built first so stalls, carts and trees
## shade the ground round them (headless, the level tools don't build them), then bakes and
## saves. Windowed (the lighting bake renders).
##   [OUT=/abs/copy.res: save there, not over the level] [GRADE=1: tests/zones/grade.gd]
##   [FINISH=1: put a ground finish on first (GroundFinish, textures from the level)]
##   SCENE=res://zones/....tscn tools/godot_run.sh --path . --resolution 640x360 tests/zones/relight.tscn   (editor closed)


func _ready() -> void:
	Engine.set_meta(&"n64_baking", true)  # (bake-only lights show: string lights)
	var grade := OS.get_environment("GRADE") != ""
	if grade:
		preload("res://tests/zones/grade.gd").apply_globals()
	var zone: Node = (load(OS.get_environment("SCENE")) as PackedScene).instantiate()
	if OS.get_environment("LEVEL_OVERRIDE") != "":
		# LEVEL_OVERRIDE=path.res: relight that level file in this zone (save with OUT).
		var lr: Node = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
		lr.set(&"data", ResourceLoader.load(OS.get_environment("LEVEL_OVERRIDE"), "", ResourceLoader.CACHE_MODE_IGNORE))
	add_child(zone)
	await get_tree().process_frame
	var root: LevelRoot = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	if grade:
		preload("res://tests/zones/grade.gd").apply_level(root.data)
		preload("res://tests/zones/grade.gd").apply_carpet(root.data)
	if OS.get_environment("FINISH") != "":
		# FINISH=1: the level gets a ground finish (textures from the level) put on first.
		if root.data.ground_finish == null:
			root.data.ground_finish = GroundFinish.new()
		root.data.ground_finish.fill_textures()
		if OS.get_environment("PILE") == "0":
			root.data.ground_finish.pile = false
		if OS.get_environment("PILE_ANY") != "":
			root.data.ground_finish.pile_any_ground = true
		for prop in ["pile_height", "pile_width"]:
			if OS.get_environment(prop.to_upper()) != "":
				root.data.ground_finish.set(prop, float(OS.get_environment(prop.to_upper())))
		print("ground finish: %s (grass %s, dirt %s)" % [root.data.ground_finish.apply(),
			root.data.ground_finish.grass_textures.map(func(t): return t.resource_path.get_file()),
			root.data.ground_finish.dirt_textures.map(func(t): return t.resource_path.get_file())])
	await relight(zone, root)
	if OS.get_environment("PROBE") != "":
		return
	var data := root.data
	var path := data.resource_path
	var out := OS.get_environment("OUT") if OS.get_environment("OUT") != "" else path
	var uid := ResourceLoader.get_resource_uid(path)
	var res := LevelBaker.bake(data, root.merge_coplanar)
	data.baked_mesh = res.mesh
	data.baked_chunks = res.chunks
	data.set_baked_collision(res)
	var err := ResourceSaver.save(data, out, ResourceSaver.FLAG_COMPRESS)
	if out == path and uid != ResourceUID.INVALID_ID:
		ResourceSaver.set_uid(path, uid)
	print("saved %s: %s, %d baked tris" % [out, error_string(err), res.stats.baked_tris])
	get_tree().quit()


## Relights `root` (in `zone`, in the tree) with its props as occluders (await it).
static func relight(zone: Node, root: LevelRoot) -> void:
	var data := root.data
	# In a game the props are built when the level loads and batched (PropBatch) into
	# merged meshes: those are the occluders (the editor's own gather finds the unbatched).
	root.make_prop_nodes_for_export(zone)
	root.make_rope_nodes_for_export(zone)  # (string lights: their bake lights)
	for i in 3:
		await zone.get_tree().process_frame
	var batched := []
	for holder in zone.find_children("PropBatch", "Node3D", true, false):
		var tris := PackedVector3Array()
		for mi in holder.get_children():
			if mi is MeshInstance3D and mi.mesh and mi.visibility_range_begin <= 0.0:
				for v in mi.mesh.get_faces():
					tris.append(mi.global_transform * v)
		if not tris.is_empty():
			batched.append({tris = tris})
	var n := 0
	for o in batched:
		n += o.tris.size() / 3
	print("batched prop triangles: %d" % n)
	if OS.get_environment("PROBE") != "":
		var pr := OS.get_environment("PROBE").split(",")
		var at := Vector3(float(pr[0]), float(pr[1]), float(pr[2]))
		var hit := LevelLighting._occluded(at, at + Vector3.UP * 30.0, LevelLighting._triangle_lists(batched))
		print("probe %s straight up: blocked by props %s" % [at, hit])
		zone.get_tree().quit()
		return
	var lights := LevelLighting.gather_lights(zone)
	print("bake lights: %d (omni %d)" % [lights.size(), lights.filter(func(l): return l is OmniLight3D).size()])
	var occluders: Array = [root] + LevelLighting.dressing_occluders(zone) + batched
	print("occluders: %d (props and dressing %d)" % [occluders.size(), occluders.size() - 1])
	if data.brushes.any(func(b): return b and not b.vertex_ao.is_empty()):
		var ao := LevelLighting.bake_vertex_ao(root, occluders, data.light_ao_strength, data.light_ao_radius,
			maxi(data.light_ao_samples, 16))
		for brush in ao:
			brush.vertex_ao = ao[brush]
		print("vertex AO: %d brushes" % ao.size())
	var baked_lights := lights
	if LevelData.mode_is_hybrid(data.lighting_mode):
		baked_lights = lights.filter(func(l: Light3D): return l.light_bake_mode == Light3D.BAKE_STATIC)
	if LevelData.mode_is_timed(data.lighting_mode):
		var schedule := LightingSchedule.load_project()
		if schedule:
			var keyed := LevelLighting.bake_keys(root, occluders, baked_lights, schedule)
			for brush in keyed:
				var arr: Array[PackedColorArray] = []
				arr.assign(keyed[brush])
				brush.corner_lighting_keys = arr
			print("relit %d brushes (timed)" % keyed.size())
	elif data.lighting_mode != LevelData.LightingMode.DYNAMIC:
		var lit := LevelLighting.bake(root, occluders, baked_lights)
		for brush in lit:
			brush.corner_lighting = lit[brush]
	LevelLighting.bake_rain_light(root, occluders, lights)
