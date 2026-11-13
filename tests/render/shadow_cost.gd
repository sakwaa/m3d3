extends Node3D
## Projected-shadow cost: a zone with the player (and its NPCs), the main view's render time
## against the silhouette viewports' (RenderingServer measured CPU / GPU ms per frame), with
## shadows on, then off (NOSHADOW=1 for off only).
##   ZONE=res://... PLAYER=x,y,z CAM=x,y,z LOOK=x,y,z godot --path . tests/render/shadow_cost.tscn


func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(zone)
	var pp := OS.get_environment("PLAYER").split(",")
	var player: Node3D = (load("res://player/player.tscn") as PackedScene).instantiate()
	player.set(&"scripted", true)
	add_child(player)
	player.global_position = Vector3(float(pp[0]), float(pp[1]), float(pp[2]))
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = _v(OS.get_environment("CAM"))
	cam.look_at(_v(OS.get_environment("LOOK")))
	for i in 30:
		await RenderingServer.frame_post_draw
	for c in get_tree().root.find_children("*", "Camera3D", true, false):
		if c != cam and c.get_viewport() == get_viewport():
			c.current = false
	cam.make_current()
	await _measure("shadows on")
	for s in get_tree().root.find_children("*", "Node3D", true, false):
		if s is ProjectedShadow:
			s.set_process(false)
			for slot in s.get("_slots"):
				s.call(&"_hide", slot)
	await _measure("shadows off")
	get_tree().quit()


func _measure(label: String) -> void:
	var main := get_viewport().get_viewport_rid()
	var subs: Array[SubViewport] = []
	for v in get_tree().root.find_children("*", "SubViewport", true, false):
		subs.append(v)
	RenderingServer.viewport_set_measure_render_time(main, true)
	for v in subs:
		RenderingServer.viewport_set_measure_render_time(v.get_viewport_rid(), true)
	for i in 10:
		await RenderingServer.frame_post_draw
	var frames := 120
	var mc := 0.0
	var mg := 0.0
	var sc := 0.0
	var sg := 0.0
	var live := 0
	var t0 := Time.get_ticks_usec()
	for i in frames:
		await RenderingServer.frame_post_draw
		mc += RenderingServer.viewport_get_measured_render_time_cpu(main)
		mg += RenderingServer.viewport_get_measured_render_time_gpu(main)
		for v in subs:
			if v.render_target_update_mode != SubViewport.UPDATE_DISABLED:
				live += 1
			sc += RenderingServer.viewport_get_measured_render_time_cpu(v.get_viewport_rid())
			sg += RenderingServer.viewport_get_measured_render_time_gpu(v.get_viewport_rid())
	var frame_ms := (Time.get_ticks_usec() - t0) / 1000.0 / frames
	var casters := get_tree().root.find_children("*", "Node3D", true, false).filter(func(n): return n is ProjectedShadow).size()
	print("%-12s frame %.2f ms | main cpu %.2f gpu %.2f | %d silhouette viewports (%d casters, %.1f updating/frame) cpu %.2f gpu %.2f | render cpu total %.2f ms (RenderingServer)" % [
		label, frame_ms, mc / frames, mg / frames, subs.size(), casters, float(live) / frames, sc / frames, sg / frames,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])


func _v(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))
