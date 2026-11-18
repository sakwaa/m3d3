extends Node
## The LightShaft and Ambience props: each made through PropSpec (kind + a few settings),
## added to the tree; checks the shaft built its mesh and each ambience sound made a looping
## 16-bit mono AudioStreamWAV of the loop's length. Prints PROPS PASS / FAIL.
##   godot --headless --path . tests/props/new_props_test.tscn
## SHOT=file.png (not headless, --resolution 960x540): renders a shaft over a dark floor in
## light fog instead, saves the frame and quits. TILT / LEN / INTENSITY override its settings.

var fails := 0


func _ready() -> void:
	if OS.get_environment("SHOT") != "":
		await _shot(OS.get_environment("SHOT"))
		get_tree().quit()
		return
	await _test_shaft()
	for s in 4:
		await _test_ambience(s)
	print("PROPS %s (%d fails)" % ["PASS" if fails == 0 else "FAIL", fails])
	get_tree().quit(1 if fails else 0)


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _spec(kind: String, settings: Dictionary) -> Node:
	var spec := PropSpec.new()
	spec.kind = PropSpec.Kind[kind]
	for k in settings:
		spec.set(k, settings[k])
	return spec.instantiate()


func _test_shaft() -> void:
	var n := _spec("LIGHT_SHAFT", {length = 30.0, tilt = 25.0, intensity = 0.4})
	add_child(n)
	for i in 3:
		await get_tree().process_frame
	_check(n.get_script().get_global_name() == &"LightShaft", "light shaft: script LightShaft")
	_check(is_equal_approx(n.length, 30.0) and is_equal_approx(n.tilt, 25.0), "light shaft: settings applied")
	var meshes := n.get_children(true).filter(func(c): return c is MeshInstance3D and c.has_meta(&"light_shaft_part"))
	_check(meshes.size() == 1, "light shaft: one mesh child (%d)" % meshes.size())
	if meshes.size() > 0:
		var m: Mesh = meshes[0].mesh
		var tris: int = m.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() / 3
		_check(tris > 0 and tris <= 24, "light shaft: %d tris" % tris)
		_check(meshes[0].material_override is ShaderMaterial, "light shaft: shader material")
		var foot: Vector3 = n.foot_offset(30.0, 25.0)
		_check(m.get_aabb().grow(0.1).has_point(foot), "light shaft: mesh reaches its foot %s" % foot)
	var b: AABB = n.prop_bounds()
	_check(b.size.y > 25.0, "light shaft: bounds %s" % b)
	n.queue_free()


func _test_ambience(s: int) -> void:
	var name_s: String = ["RAIN", "WATERFALL", "STREAM", "WIND"][s]
	# (rain plays only while it rains: the weather now says so)
	GameState.weather_now = {rain = 0.8, wind = 1.0} if s == 0 else {}
	var n := _spec("AMBIENCE", {sound = s, volume = 0.6, radius = 20.0})
	add_child(n)
	for i in 4:
		await get_tree().process_frame
	_check(n.get_script().get_global_name() == &"AmbientSound", "%s: script AmbientSound" % name_s)
	var players := n.get_children(true).filter(func(c): return c is AudioStreamPlayer or c is AudioStreamPlayer3D)
	_check(players.size() == 1, "%s: one player (%d)" % [name_s, players.size()])
	if players.is_empty():
		n.queue_free()
		return
	var p: Node = players[0]
	_check((p is AudioStreamPlayer) == (s == 0 or s == 3), "%s: %s" % [name_s, p.get_class()])
	_check(p.get(&"playing") and not p.get(&"stream_paused"), "%s: playing" % name_s)
	var w := p.get(&"stream") as AudioStreamWAV
	_check(w != null, "%s: AudioStreamWAV" % name_s)
	if w:
		var frames := w.data.size() / 2
		_check(w.format == AudioStreamWAV.FORMAT_16_BITS and not w.stereo and w.mix_rate == 22050, "%s: 16-bit mono 22050" % name_s)
		_check(w.loop_mode == AudioStreamWAV.LOOP_FORWARD and w.loop_end == frames and w.loop_begin == 0, "%s: loops forward 0..%d" % [name_s, frames])
		_check(frames == int(4.0 * 22050), "%s: %.2f s" % [name_s, frames / 22050.0])
		# Seam: the last sample runs into the first (no click).
		var a := w.data.decode_s16(w.data.size() - 2)
		var z := w.data.decode_s16(0)
		var rms := 0.0
		for i in range(0, w.data.size(), 2 * 50):
			rms += pow(w.data.decode_s16(i) / 32767.0, 2.0)
		rms = sqrt(rms / (frames / 50.0))
		_check(absf(a - z) / 32767.0 < 0.25, "%s: seam step %.3f (rms %.3f)" % [name_s, absf(a - z) / 32767.0, rms])
		_check(rms > 0.03, "%s: not silent (rms %.3f)" % [name_s, rms])
		_check(n.stream_for(s) == w, "%s: cached" % name_s)
	n.queue_free()


func _shot(path: String) -> void:
	RenderingServer.set_default_clear_color(Color(0.36, 0.39, 0.42))
	RenderingServer.global_shader_parameter_set(&"n64_fog", Vector4(15.0, 110.0, 1.0, 1.0))
	RenderingServer.global_shader_parameter_set(&"n64_fog_color", Color(0.36, 0.39, 0.42, 1.0))
	RenderingServer.global_shader_parameter_set(&"n64_fog_origin", Vector3(0, 2, 18))
	RenderingServer.global_shader_parameter_set(&"n64_ambient_light", Color.WHITE)
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(200, 200)
	floor.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.albedo_color = Color(0.16, 0.16, 0.15)
	floor.material_override = fm
	add_child(floor)
	# A couple of dark blocks (granite) for something to stand in front of.
	for x in [-14.0, 12.0]:
		var b := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(6, 24, 6)
		b.mesh = bm
		b.material_override = fm
		b.position = Vector3(x, 12, -30)
		add_child(b)
	var n := _spec("LIGHT_SHAFT", {})
	for k in ["tilt", "length", "intensity"]:
		var e := OS.get_environment(k.to_upper())
		if e != "":
			n.set(k, float(e))
	add_child(n)
	# (turned to lean across the view, the slant seen side on)
	n.rotation.y = deg_to_rad(float(OS.get_environment("YAW"))) if OS.get_environment("YAW") != "" else PI * 0.5
	n.position = Vector3(0, 0, -20) - n.basis * n.foot_offset(n.length, n.tilt)
	var cam := Camera3D.new()
	cam.fov = 60.0
	add_child(cam)
	cam.position = Vector3(0, 3, 18)
	cam.look_at(Vector3(0, 12, -20))
	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)
