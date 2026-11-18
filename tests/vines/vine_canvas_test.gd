extends "res://tests/vines/vine_doorway.gd"
## VineCanvas (vines grown by a compute shader into a texture over the wall) on the doorway
## wall: the 3D vines removed, a canvas on the wall's front face, seeded low on the left,
## seeking over the doorway, hanging strands into it. Prints the grow time; OUT=dir +
## GROW_FRAMES=n records it growing in and shrinking (canvas_####.png); LIVE=1 grows it live
## at live_speed instead (the compute steps per frame) and records that.
##   godot --path . --resolution 1280x720 tests/vines/vine_canvas_test.tscn

var canvas: VineCanvas


func _run() -> void:
	for v in patches:
		v.queue_free()
	patches.clear()
	for i in 4:
		await get_tree().process_frame
	canvas = VineCanvas.new()
	canvas.size = Vector2(10.6, 4.3)
	canvas.seeds = PackedVector2Array([Vector2(-4.4, -2.05)])
	canvas.tendrils = 28
	canvas.target = Vector2(0.0, 1.45)
	canvas.length = 10.0
	canvas.steps = 600
	if OS.get_environment("LIVE") != "":
		canvas.live_speed = 1.2
	canvas.position = Vector3(0, 2.15, 0.25)
	add_child(canvas)
	await canvas.ready_to_show
	cam.make_current()
	# Cost: frame times (vsync off) of plain frames vs frames that also run the steps.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var plain := await _frame_ms(func(): pass, 20)
	var full := await _frame_ms(func(): RenderingServer.call_on_render_thread(canvas._run.bind(600)), 6)
	var one := await _frame_ms(func(): RenderingServer.call_on_render_thread(canvas._run.bind(1)), 20)
	print("CANVAS %dx%d texels: frame %.2f ms plain, %.2f ms + 600 steps (whole grow), %.2f ms + 1 step (live)" % [canvas._px.x, canvas._px.y, plain, full, one])
	for c in get_tree().root.find_children("*", "CanvasLayer", true, false):
		c.visible = false
	cam.look_at_from_position(Vector3(2.6, 2.2, 7.0), Vector3(-1.4, 1.8, 0.2))
	var n := int(OS.get_environment("GROW_FRAMES")) if OS.get_environment("GROW_FRAMES") != "" else 120
	var frames := []
	if canvas.live_speed > 0.0:
		for f in n * 2:
			frames.append(-1.0)
	else:
		for f in n:
			frames.append(smoothstep(0.0, 1.0, float(f) / n))
		for f in n / 4:
			frames.append(1.0)
		for f in n:
			frames.append(1.0 - smoothstep(0.0, 1.0, float(f) / n))
	for f in frames.size():
		if frames[f] >= 0.0:
			canvas.grown = frames[f]
		await RenderingServer.frame_post_draw
		if out != "":
			var img := get_viewport().get_texture().get_image()
			img.resize(1280, int(1280.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_BILINEAR)
			img.save_png(out + "/canvas_%04d.png" % f)
	print("CANVAS done: %d frames" % frames.size())


## Median frame time (ms) of `n` frames each doing `work` first (RenderingServer synced).
func _frame_ms(work: Callable, n: int) -> float:
	var ts := []
	for i in n:
		work.call()
		RenderingServer.force_sync()
		var t0 := Time.get_ticks_usec()
		RenderingServer.force_draw(false)
		RenderingServer.force_sync()
		ts.append((Time.get_ticks_usec() - t0) / 1000.0)
	ts.sort()
	await get_tree().process_frame
	return ts[ts.size() / 2]
	get_tree().quit()
