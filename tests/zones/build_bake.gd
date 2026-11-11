extends Node

const ExportBake := preload("res://addons/n64_level_tools/export/export_bake.gd")
## Runs the Build & Play / export bake (ExportBake: cull, Blender dissolve, relight, bake)
## on a copy of a zone and saves the result to OUT (a .res, for LEVEL_OVERRIDE renders);
## the zone's own files are never touched. Prints the build's stats.
##   ZONE=res://...tscn OUT=/abs/path.res [DISSOLVE=0] godot --path . tests/zones/build_bake.tscn  (a window: the AO bake renders)


func _ready() -> void:
	if OS.get_environment("DISSOLVE") == "0":
		ProjectSettings.set_setting(BlenderDissolve.SETTING, false)
	var path := OS.get_environment("ZONE")
	var scene: Node = (load(path) as PackedScene).instantiate()
	var t := Time.get_ticks_msec()
	var out: Dictionary = ExportBake.bake_scene(scene, self, path, true)
	print("built in %.1f s: %s" % [(Time.get_ticks_msec() - t) / 1000.0, out.failed])
	for lv in out.levels:
		var st: Dictionary = lv.get("stats", lv.get("bake", lv))
		if not st.has("baked_tris"):
			print("report keys: ", lv.keys())
		print("baked tris %s | dissolve %s -> %s | simplify faces %s -> %s | hidden ground %s" % [st.get("baked_tris"), st.get("dissolve_from"), st.get("dissolve_to"),
			st.get("simplified_from"), st.get("simplified_to"), st.get("hidden_ground_faces")])
	var root: LevelRoot = scene.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	var data := root.data
	var err := ResourceSaver.save(data, OS.get_environment("OUT"), ResourceSaver.FLAG_COMPRESS)
	print("saved ", error_string(err))
	get_tree().quit()
