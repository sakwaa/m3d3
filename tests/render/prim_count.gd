extends Node3D
## What the profiler's triangle count (RENDER_TOTAL_PRIMITIVES_IN_FRAME) counts: one known
## mesh (SphereMesh, its triangles counted) in view, then the same mesh behind the camera.
##   godot --path . [--rendering-method mobile|gl_compatibility] tests/render/prim_count.tscn


func _ready() -> void:
	var m := SphereMesh.new()
	m.radial_segments = 64
	m.rings = 32
	var tris: int = (m.get_mesh_arrays()[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	var mi := MeshInstance3D.new()
	mi.mesh = m
	add_child(mi)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 0, 4)
	cam.make_current()
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = OS.get_environment("SHADOW") != ""
	add_child(sun)
	for i in 10:
		await RenderingServer.frame_post_draw
	var seen := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	mi.position = Vector3(0, 0, 10)  # behind the camera
	for i in 10:
		await RenderingServer.frame_post_draw
	var hidden := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	print("%s prepass %s shadow %s | mesh %d tris | counted in view %d, behind camera %d" % [
		RenderingServer.get_current_rendering_method(), ProjectSettings.get_setting("rendering/driver/depth_prepass/enable"),
		sun.shadow_enabled, tris, seen, hidden])
	get_tree().quit()
