extends Node

const ExportBake := preload("res://addons/n64_level_tools/export/export_bake.gd")
## Runs the Build & Play / export bake (ExportBake: cull, Blender dissolve, relight, bake)
## on a copy of a zone and saves the result to OUT (a .res, for LEVEL_OVERRIDE renders);
## the zone's own files are never touched. Prints the build's stats.
##   ZONE=res://...tscn OUT=/abs/path.res [DISSOLVE=0] [STEPS=/abs/steps.txt] [LIGHT_GRID=m] [NO_AO=1] [MERGE=0] [REPORT=label] godot --path . tests/zones/build_bake.tscn  (a window: the AO bake renders)


func _ready() -> void:
	# LOD=m / GROUND_LOD=m: try other LOD distances (this run only).
	if OS.get_environment("LOD") != "":
		ProjectSettings.set_setting(LevelRoot.LOD_SETTING, float(OS.get_environment("LOD")))
	if OS.get_environment("CHUNK") != "":
		ProjectSettings.set_setting(LevelBaker.CHUNK_SETTING, float(OS.get_environment("CHUNK")))
	if OS.get_environment("LOD_CELL") != "":
		ProjectSettings.set_setting(LevelBaker.LOD_CELL_SETTING, float(OS.get_environment("LOD_CELL")))
	if OS.get_environment("GROUND_LOD") != "":
		ProjectSettings.set_setting(GroundLOD.SETTING, float(OS.get_environment("GROUND_LOD")))
	if OS.get_environment("UNSEEN") != "":
		ProjectSettings.set_setting(UnseenCull.SETTING, OS.get_environment("UNSEEN") == "1")
	if OS.get_environment("STEPS") != "":
		# STEPS=/abs/path.txt: each build step and when it began (BuildProgress), for timing.
		BuildProgress.to_file(OS.get_environment("STEPS"))
	if OS.get_environment("CACHE") != "":
		# CACHE=1: the step caches on, as in Build & Play.
		preload("res://addons/n64_level_tools/export/build_cache.gd").active = true
	if OS.get_environment("DISSOLVE") == "0":
		ProjectSettings.set_setting(BlenderDissolve.SETTING, false)
	var path := OS.get_environment("ZONE")
	var scene: Node = (load(path) as PackedScene).instantiate()
	if OS.get_environment("LEVEL_IN") != "":
		# LEVEL_IN=path.res: the zone's level data swapped for another (a test copy).
		var lr: Node = scene.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
		lr.set(&"data", ResourceLoader.load(OS.get_environment("LEVEL_IN"), "", ResourceLoader.CACHE_MODE_IGNORE))
	if OS.get_environment("GRADE_VARIANT") != "":
		# GRADE_VARIANT=saved|ok|ramps: the zone's grade as tests/zones/colour_compare.gd varies it.
		var lr: Node = scene.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
		var d: LevelData = lr.get(&"data")
		d.grade = preload("res://tests/zones/colour_compare.gd").variant_grade(d.grade as ZoneGrade, OS.get_environment("GRADE_VARIANT"))
	if OS.get_environment("LIGHT_GRID") != "":
		# LIGHT_GRID=metres: the build's lighting grid (0 = the edited geometry, no extra cuts).
		ProjectSettings.set_setting(ExportBake.LIGHT_GRID, float(OS.get_environment("LIGHT_GRID")))
	if OS.get_environment("MERGE") == "0":
		# MERGE=0: no material merge (every surface keeps its own material).
		ProjectSettings.set_setting(MaterialMerge.SETTING, false)
	if OS.get_environment("NO_AO") != "":
		# NO_AO=1: the level's baked vertex AO left out (the lighting then shades its corners
		# with its own AO instead: not AO-free).
		for lr in scene.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot):
			lr.data = lr.data.duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL)
			for b in lr.data.brushes:
				if b:
					b.vertex_ao = PackedFloat32Array()
	var t := Time.get_ticks_msec()
	var out: Dictionary = ExportBake.bake_scene(scene, self, path, true)
	print("built in %.1f s: %s" % [(Time.get_ticks_msec() - t) / 1000.0, out.failed])
	for lv in out.levels:
		var st: Dictionary = lv.get("build", lv.get("stats", lv.get("bake", lv)))
		print("build tris %s (editor %s) | dissolve %s -> %s | simplify faces %s -> %s | hidden ground %s" % [st.get("tris", st.get("baked_tris")),
			(lv.get("editor", {}) as Dictionary).get("tris"), st.get("dissolve_from"), st.get("dissolve_to"),
			st.get("faces_before_simplify", st.get("simplified_from")), st.get("faces_after_simplify", st.get("simplified_to")), st.get("hidden_ground_faces")])
		print("material merge: surfaces %s -> %s" % [st.get("merged_surfaces_from"), st.get("merged_surfaces_to")])
		if st.has("unseen"):
			print("unseen: ", st.unseen)
		if st.has("room_vis"):
			print("rooms: %s in %d ms" % [st.room_vis, st.room_vis_ms])
	if OS.get_environment("REPORT") != "":
		# REPORT=label: the build report (build_reports/<stamp>_<label>/summary.md, report.json).
		print("report: ", ExportBake.BuildReport.write(out.levels, OS.get_environment("REPORT"), "build_bake"))
	var root: LevelRoot = scene.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	var data := root.data
	var err := ResourceSaver.save(data, OS.get_environment("OUT"), ResourceSaver.FLAG_COMPRESS)
	print("saved ", error_string(err))
	get_tree().quit()
