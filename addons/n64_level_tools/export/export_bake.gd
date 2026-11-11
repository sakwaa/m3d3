@tool
extends RefCounted
## Final bake at export: re-lights and re-bakes every level of a scene with its current
## settings (lighting mode, bake strength, contrast, AO, Static / Dynamic lights), the
## same way the editor's Bake Lighting + Bake buttons do. Works on a copy of each level's
## data, so the project files are never touched; only the exported scene gets the result.

## Project setting: run the final bake on export (off = ship the last editor bake).
const SETTING := "n64/export/bake_on_export"
## Project setting: metres between the build's lighting vertices (the private Clean Up the
## build runs before lighting; 0 = keep the editor's geometry).
const LIGHT_GRID := "n64/build/light_grid"
const BuildReport := preload("res://addons/n64_level_tools/export/build_report.gd")


static func enabled() -> bool:
	return bool(ProjectSettings.get_setting(SETTING, true))


## Bakes the LevelRoots in `scene` (an instance being exported, outside the tree).
## `holder`: a node in the editor's tree to host the scene while baking (lights, levels
## and doors need real world transforms). `report`: also measure each built level
## (BuildReport.level) into `levels`. Returns {baked: int, failed: Array[String], levels}.
static func bake_scene(scene: Node, holder: Node, scene_path: String, report := false) -> Dictionary:
	var roots: Array = scene.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)
	if scene is LevelRoot:
		roots.push_front(scene)
	var out := {baked = 0, failed = [], levels = []}
	var edited := {}  # root -> the level as edited (for the report)
	if roots.is_empty():
		return out
	# Private copies: the editor's open levels and the files on disk stay as they are (brushes
	# saved as their own files too: the build reshapes them).
	for root: LevelRoot in roots:
		if root.data:
			edited[root] = root.data
			root.data = root.data.duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL)
			var own: Array[LevelBrush] = []
			for b: LevelBrush in root.data.brushes:
				own.append(b.duplicate() if b and b.resource_path.get_extension() != "" and not b.resource_path.contains("::") else b)
			root.data.brushes = own
	holder.add_child(scene)
	# Door / passage trim is built by the nodes themselves; make sure it's current.
	for node in scene.find_children("*", "Node3D", true, false):
		if node.get(&"dressing") != null and node.has_method(&"_rebuild"):
			node.call(&"_rebuild")
	var lights := LevelLighting.gather_lights(scene)
	var occluders: Array = roots + LevelLighting.dressing_occluders(scene)
	for root: LevelRoot in roots:
		var data := root.data
		if data == null or data.brushes.is_empty():
			continue
		var not_ready := LevelBaker.not_ready_reason(data)
		if not not_ready.is_empty():
			out.failed.append("%s in %s (%s)" % [root.name, scene_path, not_ready])
			continue
		var t := Time.get_ticks_msec()
		var stats := _bake_level(root, occluders, lights)
		out.baked += 1
		if report:
			out.levels.append(BuildReport.level(root, scene, scene_path, edited[root], stats, Time.get_ticks_msec() - t))
	_bake_dressing_ao(scene, roots, occluders)
	holder.remove_child(scene)
	return out


## Returns the bake's stats.
static func _bake_level(root: LevelRoot, occluders: Array, lights: Array) -> Dictionary:
	var data := root.data
	var mode := data.lighting_mode
	for brush in data.brushes:
		if brush:
			brush.set_block_signals(true)
	# Hidden faces out first (ground under buildings, walls against a neighbour).
	var culled := BuildCull.cull(data)
	# Blender's limited dissolve (BlenderDissolve), before lighting: the merged faces get lit.
	# It replaces the lighting grid below (which would cut them up again).
	var dissolved := {}
	if BlenderDissolve.enabled():
		dissolved = BlenderDissolve.dissolve(data)
		if dissolved.has("error"):
			push_warning("[Build] %s: %s (built without it)" % [root.name, dissolved.error])
	# The build's own Clean Up (before lighting: the new vertices get lit), on the copy.
	var grid := float(ProjectSettings.get_setting(LIGHT_GRID, 4.0))
	if grid > 0.0 and not dissolved.has("after"):
		for brush in data.brushes:
			if brush and brush.blend_file == "":
				# Far stand-ins are seen from afar only: no lighting grid for them.
				var all: Array[int] = []
				for f in brush.get_face_count():
					if not brush.get_face_lod(f) in [LevelBrush.LOD_FAR, LevelBrush.LOD_DETAIL_FAR]:
						all.append(f)
				BrushCleanup.clean_up(brush, all, grid, data.mask_density, false)
	# Vertex AO, if the level uses it (Bake AO).
	if data.brushes.any(func(b): return b and not b.vertex_ao.is_empty()):
		var ao := LevelLighting.bake_vertex_ao(root, occluders, data.light_ao_strength, data.light_ao_radius,
			maxi(data.light_ao_samples, 16))
		for brush in ao:
			brush.vertex_ao = ao[brush]
	# Lighting, as Bake Lighting does it for this mode.
	var baked_lights := lights
	if LevelData.mode_is_hybrid(mode):
		baked_lights = lights.filter(func(l: Light3D): return l.light_bake_mode == Light3D.BAKE_STATIC)
	if LevelData.mode_is_timed(mode):
		var schedule := LightingSchedule.load_project()
		if schedule:
			var keyed := LevelLighting.bake_keys(root, occluders, baked_lights, schedule)
			for brush in keyed:
				var arr: Array[PackedColorArray] = []
				arr.assign(keyed[brush])
				brush.corner_lighting_keys = arr
	elif mode != LevelData.LightingMode.DYNAMIC:
		var lit := LevelLighting.bake(root, occluders, baked_lights)
		for brush in lit:
			brush.corner_lighting = lit[brush]
	LevelLighting.bake_rain_light(root, occluders, lights)
	for brush in data.brushes:
		if brush:
			brush.set_block_signals(false)
	# Geometry + materials (bake strength, contrast etc. go into the materials here), with
	# the build's simplification (BuildSimplify).
	var result := LevelBaker.bake(data, root.merge_coplanar, true)
	data.set_block_signals(true)
	data.baked_mesh = result.mesh
	data.baked_chunks = result.chunks
	data.set_baked_collision(result)
	data.bake_hash = root.compute_hash()
	data.set_block_signals(false)
	result.stats.dissolve_from = dissolved.get("before", 0)
	result.stats.dissolve_to = dissolved.get("after", 0)
	result.stats.hidden_ground_faces = culled.ground
	result.stats.hidden_wall_faces = culled.walls
	return result.stats


## Door / passage trim AO, where it was baked before (same as Bake AO in the editor).
static func _bake_dressing_ao(scene: Node, roots: Array, occluders: Array) -> void:
	if roots.is_empty() or roots[0].data == null:
		return
	var d: LevelData = roots[0].data
	for node in LevelLighting.dressed_nodes(scene):
		var current: PackedFloat32Array = node.get(&"dressing_ao")
		if current.is_empty():
			continue
		var mi: MeshInstance3D = node.get(&"_dressing")
		var arrays := mi.mesh.surface_get_arrays(0)
		var pts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var wp := PackedVector3Array()
		var wn := PackedVector3Array()
		for i in pts.size():
			wp.append(mi.global_transform * pts[i])
			wn.append(mi.global_basis * nrm[i])
		node.set(&"dressing_ao", LevelLighting.bake_points_ao(wp, wn, occluders, d.light_ao_strength,
			d.light_ao_radius, maxi(d.light_ao_samples, 16)))
		node.set(&"dressing_ao_key", node.call(&"dressing_shape_key"))
