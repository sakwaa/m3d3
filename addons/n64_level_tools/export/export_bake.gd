@tool
extends RefCounted
## Final bake at export: re-lights and re-bakes every level of a scene with its current
## settings (lighting mode, bake strength, contrast, AO, Static / Dynamic lights), the
## same way the editor's Bake Lighting + Bake buttons do. Works on a copy of each level's
## data, so the project files are never touched; only the exported scene gets the result.

const GRADE_BAKE := "res://addons/n64_grade/grade_bake.gd"
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
		BuildProgress.where = "%s · %s" % [scene_path.get_file().get_basename(), root.name] if roots.size() > 1 else scene_path.get_file().get_basename()
		var stats := _bake_level(root, occluders, lights)
		out.baked += 1
		if report:
			out.levels.append(BuildReport.level(root, scene, scene_path, edited[root], stats, Time.get_ticks_msec() - t))
	BuildProgress.where = scene_path.get_file().get_basename()
	BuildProgress.step("door and passage AO")
	_bake_dressing_ao(scene, roots, occluders)
	BuildProgress.where = ""
	holder.remove_child(scene)
	return out


## Returns the bake's stats.
static func _bake_level(root: LevelRoot, occluders: Array, lights: Array) -> Dictionary:
	var data := root.data
	var mode := data.lighting_mode
	for brush in data.brushes:
		if brush:
			brush.set_block_signals(true)
	var times := {}  # step -> ms (printed at the end)
	# The Grade's painted AO, before the build reshapes the brushes (found again by position).
	var grade_ao: Dictionary = load(GRADE_BAKE).capture(data) if data.grade and ResourceLoader.exists(GRADE_BAKE) else {}
	var t := Time.get_ticks_msec()
	BuildProgress.step("hidden faces")
	# Hidden faces out first (ground under buildings, walls against a neighbour).
	var culled := BuildCull.cull(data)
	times.cull = Time.get_ticks_msec() - t
	# Blender's limited dissolve (BlenderDissolve), before lighting: the merged faces get lit.
	# It replaces the lighting grid below (which would cut them up again).
	var dissolved := {}
	t = Time.get_ticks_msec()
	if BlenderDissolve.enabled():
		BuildProgress.step("Blender dissolve")
		dissolved = BlenderDissolve.dissolve(data)
		if dissolved.has("error"):
			push_warning("[Build] %s: %s (built without it)" % [root.name, dissolved.error])
	times.dissolve = Time.get_ticks_msec() - t
	# The build's own Clean Up (before lighting: the new vertices get lit), on the copy.
	var grid := float(ProjectSettings.get_setting(LIGHT_GRID, 4.0))
	if grid > 0.0 and not dissolved.has("after"):
		BuildProgress.step("lighting grid")
		for brush in data.brushes:
			if brush and brush.blend_file == "":
				# Far stand-ins are seen from afar only: no lighting grid for them.
				var all: Array[int] = []
				for f in brush.get_face_count():
					if not brush.get_face_lod(f) in [LevelBrush.LOD_FAR, LevelBrush.LOD_DETAIL_FAR]:
						all.append(f)
				BrushCleanup.clean_up(brush, all, grid, data.mask_density, false)
	t = Time.get_ticks_msec()
	# Vertex AO, if the level uses it (Bake AO).
	if data.brushes.any(func(b): return b and not b.vertex_ao.is_empty()):
		BuildProgress.step("vertex AO")
		var samples := maxi(data.light_ao_samples, 16)
		LevelLighting.ao_memo_on = true
		var errors := {}
		var ao := LevelLighting.bake_vertex_ao(root, occluders, data.light_ao_strength, data.light_ao_radius, samples, {}, errors)
		# Where the vertices can't follow the AO (under eaves, round windows), more of them:
		# the faces it misses most are cut there and those brushes baked again (as N64
		# artists cut triangles along baked shadows).
		for round_i in AO_REFINE_ROUNDS:
			var cut := {}
			for brush: LevelBrush in errors:
				if _refine_ao_faces(brush, errors[brush]):
					cut[brush] = true
			if cut.is_empty():
				break
			errors = {}
			var redone := LevelLighting.bake_vertex_ao(root, occluders, data.light_ao_strength, data.light_ao_radius, samples,
				cut, errors)
			for brush in redone:
				ao[brush] = redone[brush]
		LevelLighting.ao_memo_on = false
		LevelLighting._share_vertex_ao(root, ao)
		for brush in ao:
			brush.vertex_ao = ao[brush]
	times.ao = Time.get_ticks_msec() - t
	t = Time.get_ticks_msec()
	# Lighting, as Bake Lighting does it for this mode.
	BuildProgress.step("lighting")
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
	times.lighting = Time.get_ticks_msec() - t
	# The zone's Grade (n64_grade addon, if there): vertex layers into the colours and light
	# keys, texture layers into graded texture copies, before the meshes are made.
	t = Time.get_ticks_msec()
	var grade_stats := {}
	if data.grade and ResourceLoader.exists(GRADE_BAKE):
		BuildProgress.step("grade")
		grade_stats = load(GRADE_BAKE).apply(data, grade_ao)
	times.grade = Time.get_ticks_msec() - t
	for brush in data.brushes:
		if brush:
			brush.set_block_signals(false)
	t = Time.get_ticks_msec()
	# Geometry + materials (bake strength, contrast etc. go into the materials here), with
	# the build's simplification (BuildSimplify).
	var result := LevelBaker.bake(data, root.merge_coplanar, true)
	times.bake = Time.get_ticks_msec() - t
	print("[Build] %s: %s ms%s" % [root.name, times, " (dissolve: %d brushes cached)" % dissolved.cached if dissolved.has("cached") else ""])
	data.set_block_signals(true)
	data.baked_mesh = result.mesh
	data.baked_chunks = result.chunks
	data.set_baked_collision(result)
	data.bake_hash = root.compute_hash()
	data.set_block_signals(false)
	result.stats.merge(grade_stats)
	result.stats.dissolve_from = dissolved.get("before", 0)
	result.stats.dissolve_to = dissolved.get("after", 0)
	result.stats.hidden_ground_faces = culled.ground
	result.stats.hidden_wall_faces = culled.walls
	return result.stats


## AO refinement: rounds of cuts, the miss (0..1 of AO) that earns a face one, and the
## smallest piece a cut may leave (metres).
const AO_REFINE_ROUNDS := 0  # (off: +19.5k triangles on the market at 3; see build-pipeline notes)
const AO_REFINE_ERROR := 0.1
const AO_REFINE_MIN := 0.4
## Most cuts a brush takes a round (its worst faces first).
const AO_REFINE_CUTS := 8


## Cuts `brush`'s faces whose fitted AO misses its readings by more than AO_REFINE_ERROR
## (`errors`: {face: [miss, brush-space point]}), each straight across its longer way
## through its worst point, the cut running on through every face in the same plane (no
## half-cut edges: a seam). Returns whether anything was cut.
static func _refine_ao_faces(brush: LevelBrush, errors: Dictionary) -> bool:
	if brush.blend_file != "":
		return false
	var planes := []  # [cut normal, cut d, face normal, face d]
	var worst := errors.keys().filter(func(f): return errors[f][0] >= AO_REFINE_ERROR and f < brush.get_face_count())
	worst.sort_custom(func(a, b): return errors[a][0] > errors[b][0])
	for f: int in worst:
		if planes.size() >= AO_REFINE_CUTS:
			break
		var n := brush.get_face_normal(f)
		# Upright faces only (walls): the ground and roofs have the vertices they need.
		if absf((brush.transform.basis * n).normalized().y) > 0.3:
			continue
		var pts := brush.get_face_points(f)
		var u := (pts[1] - pts[0]).normalized()
		var v := n.cross(u).normalized()
		var axis := u
		var lo := INF
		var hi := -INF
		var lo_v := INF
		var hi_v := -INF
		for p in pts:
			lo = minf(lo, p.dot(u))
			hi = maxf(hi, p.dot(u))
			lo_v = minf(lo_v, p.dot(v))
			hi_v = maxf(hi_v, p.dot(v))
		if hi_v - lo_v > hi - lo:
			axis = v
			lo = lo_v
			hi = hi_v
		if hi - lo < AO_REFINE_MIN * 2.0:
			continue
		var at := clampf((errors[f][1] as Vector3).dot(axis), lo + AO_REFINE_MIN, hi - AO_REFINE_MIN)
		planes.append([axis, at, n, n.dot(pts[0])])
	if planes.is_empty():
		return false
	var verts := brush.vertices
	var faces := brush.get_faces()
	var map := PackedInt32Array()
	var rects := {}
	for f in faces.size():
		map.append(f)
		rects[f] = brush.get_face_planar_rect(f)
	var sources: Array[PackedInt32Array] = []
	for i in verts.size():
		sources.append(PackedInt32Array([i]))
	for pl in planes:
		var fn: Vector3 = pl[2]
		var fd: float = pl[3]
		var only := {}
		for f in faces.size():
			var poly := faces[f]
			if poly.size() < 3:
				continue
			var a := verts[poly[0]]
			var nf := (verts[poly[1]] - a).cross(verts[poly[2]] - a).normalized()
			if nf.dot(fn) > 0.999 and absf(fn.dot(a) - fd) < 0.001:
				only[f] = true
		var res := BrushOps.cut_plane(verts, faces, pl[0], pl[1], only)
		if res.faces.size() == faces.size():
			continue
		verts = res.verts
		faces = res.faces
		for pair in res.new_vertices:
			var both := PackedInt32Array(sources[pair.x])
			both.append_array(sources[pair.y])
			sources.append(both)
		var nm := PackedInt32Array()
		for f in res.map.size():
			nm.append(map[res.map[f]])
		map = nm
	if faces.size() == brush.get_face_count():
		return false
	brush.vertices = verts
	brush.set_faces(faces)
	brush.remap_faces(map)
	brush.blend_vertex_colors(sources)
	var parents := {}
	for f in map.size():
		parents[f] = rects[map[f]]
	brush.crop_child_masks(parents)
	return true


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
