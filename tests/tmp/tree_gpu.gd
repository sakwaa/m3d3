extends Node3D
## GPU time at a view: everything vs trees hidden vs tree leaves only swapped to opaque.
func _ready() -> void:
	var zone: Node = (load("res://zones/town1/house_outside_town.tscn") as PackedScene).instantiate()
	add_child(zone)
	var cam := Camera3D.new()
	cam.fov = 70.0
	add_child(cam)
	cam.position = Vector3(-5.7, 1.6, 36.7)
	cam.look_at(cam.position + Vector3(0, -0.1, -1))
	cam.make_current()
	GameState.set_time(15.0)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	print("[gpu] window ", DisplayServer.window_get_size())
	await _wait(30)
	for c in find_children("*", "Camera3D", true, false):
		if c != cam:
			c.current = false
	cam.make_current()
	var trees := get_tree().root.find_children("*", "", true, false).filter(func(n): return n is WorldTree)
	for rep in 2:
		print("[gpu] all:      %.3f ms" % await _measure(vp))
		for t in trees:
			t.visible = false
		print("[gpu] no trees: %.3f ms" % await _measure(vp))
		for t in trees:
			t.visible = true
	get_tree().quit()

func _wait(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _measure(vp: RID) -> float:
	await _wait(20)
	var t0 := Time.get_ticks_usec()
	for i in 300:
		await get_tree().process_frame
	return (Time.get_ticks_usec() - t0) / 300.0 / 1000.0
