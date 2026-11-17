extends Node
## WallPortal test: a small room (10 x 8 m) with a portal in the middle of its west and
## east walls, facing each other (an alcove behind each for the camera's arm), coloured
## pillars to read the tunnel by. Plays a scripted walk and saves every frame:
##   OUT=dir [SECONDS=16] godot --path . --resolution 1280x720 --fixed-fps 30 tests/portal/wall_test.tscn
## then: ffmpeg -framerate 30 -i dir/frames/%05d.png -pix_fmt yuv420p out.mp4
## Prints each portal's levels and the GPU time (main + portal views) once a second.

const SHADER := "res://addons/n64_runtime/shaders/n64_textured.gdshader"

var out := ""
var a: WallPortal
var b: WallPortal
var _frame := 0
var _t := 0.0
var _gpu_sum := 0.0
var _gpu_n := 0
var _mats := {}


func _ready() -> void:
	out = OS.get_environment("OUT")
	DirAccess.make_dir_recursive_absolute(out + "/frames")
	GameState.set_time(12.0)
	var zone := Zone.new()
	zone.name = "PortalRoom"
	zone.intro = false
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.3, 0.4, 0.6)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.85, 0.85, 0.85)
	zone.add_child(env)
	var floor_m := _mat("res://textures/rock/cobblestone_square.res", Color(0.8, 0.78, 0.72), Vector2(5, 4))
	var wall_m := _mat("res://textures/brick/brick_3.res", Color(0.85, 0.8, 0.75), Vector2(3, 1.5))
	var dark_m := _mat("res://textures/brick/brick_3.res", Color(0.35, 0.33, 0.32), Vector2(2, 1))
	# Room: floor, ceiling, north / south walls, west / east walls with a 2.4 x 3.2 m opening.
	_box(zone, Vector3(0, -0.25, 0), Vector3(10, 0.5, 8), floor_m)
	_box(zone, Vector3(0, 4.25, 0), Vector3(10, 0.5, 8), wall_m)
	_box(zone, Vector3(0, 2, -4.15), Vector3(10.6, 4, 0.3), wall_m)
	_box(zone, Vector3(0, 2, 4.15), Vector3(10.6, 4, 0.3), wall_m)
	for side in [-1.0, 1.0]:
		var x: float = side * 5.15
		_box(zone, Vector3(x, 2, -2.6), Vector3(0.3, 4, 2.8), wall_m)
		_box(zone, Vector3(x, 2, 2.6), Vector3(0.3, 4, 2.8), wall_m)
		_box(zone, Vector3(x, 3.6, 0), Vector3(0.3, 0.8, 2.4), wall_m)
		# Alcove behind (7 m deep, dark): room for the camera's arm.
		var ax: float = side * (5.3 + 3.5)
		_box(zone, Vector3(ax, -0.25, 0), Vector3(7, 0.5, 3.0), dark_m)
		_box(zone, Vector3(ax, 3.45, 0), Vector3(7, 0.3, 3.0), dark_m)
		_box(zone, Vector3(ax, 1.6, -1.35), Vector3(7, 3.2, 0.3), dark_m)
		_box(zone, Vector3(ax, 1.6, 1.35), Vector3(7, 3.2, 0.3), dark_m)
		_box(zone, Vector3(side * 12.45, 1.6, 0), Vector3(0.3, 3.2, 3.0), dark_m)
	# Pillars and crates to read depth by: warm near the west portal, cool near the east.
	var cols := [Color(0.9, 0.3, 0.25), Color(0.95, 0.75, 0.2), Color(0.3, 0.75, 0.35), Color(0.25, 0.45, 0.9)]
	var spots := [Vector3(-3, 0, -2.5), Vector3(-1, 0, 2.6), Vector3(1.2, 0, -2.6), Vector3(3, 0, 2.4)]
	for i in 4:
		_box(zone, spots[i] + Vector3(0, 1.5, 0), Vector3(0.6, 3.0, 0.6), _mat("res://textures/brick/brick_3.res", cols[i], Vector2(1, 2)))
	_box(zone, Vector3(-3.6, 0.4, 1.6), Vector3(0.8, 0.8, 0.8), _mat("res://textures/rock/cobblestone_square.res", Color(0.9, 0.5, 0.3), Vector2.ONE))
	_box(zone, Vector3(3.4, 0.4, -1.4), Vector3(0.8, 0.8, 0.8), _mat("res://textures/rock/cobblestone_square.res", Color(0.4, 0.6, 0.95), Vector2.ONE))
	a = WallPortal.new()
	a.name = "PortalWest"
	a.position = Vector3(-5.0, 0, 0)
	a.rotation.y = PI * 0.5
	b = WallPortal.new()
	b.name = "PortalEast"
	b.position = Vector3(5.0, 0, 0)
	b.rotation.y = -PI * 0.5
	zone.add_child(a)
	zone.add_child(b)
	a.pair = a.get_path_to(b) if a.is_inside_tree() else NodePath("../PortalEast")
	b.pair = NodePath("../PortalWest")
	a.pair = NodePath("../PortalEast")
	get_tree().root.add_child.call_deferred(zone)
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().current_scene = zone
	ZoneManager._adopt_current_scene(&"")
	var p := ZoneManager.player
	p.teleport(Transform3D(Basis.IDENTITY, Vector3(2.5, 0.05, 0.4)))
	p._yaw.rotation.y = PI * 0.5  # looking west, at the west portal
	p.facing = Vector3.LEFT
	if OS.get_environment("BENCH") != "":
		_bench()
		return
	_frame = 1


## BENCH=1: frame time (back-to-back drawn frames, the GPU's pace) looking into the tunnel,
## with the portals drawing their levels and with them off; and depth 1 (no recursion).
func _bench() -> void:
	for i in 20:
		await get_tree().process_frame
	for cfg in [["portals depth 6", 6, true], ["portals depth 1", 1, true], ["portals off", 6, false]]:
		for portal in [a, b]:
			portal.max_depth = cfg[1]
			portal.set_process(cfg[2])
			if not cfg[2]:
				portal.chain.update(get_viewport().get_camera_3d(), Vector2i(8, 8), false)
		for i in 10:
			await get_tree().process_frame
		var t0 := Time.get_ticks_usec()
		var n := 60
		for i in n:
			RenderingServer.force_draw(false)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0 / n
		print("PORTAL bench %s: %.2f ms/frame (levels west %d east %d)" % [cfg[0], ms, a.chain.levels, b.chain.levels])
	get_tree().quit()


func _mat(tex: String, tint: Color, scale: Vector2) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(SHADER)
	m.set_shader_parameter(&"albedo_texture", load(tex))
	m.set_shader_parameter(&"has_texture", true)
	m.set_shader_parameter(&"albedo_color", tint)
	m.set_shader_parameter(&"uv_scale", scale)
	return m


func _box(parent: Node, at: Vector3, size: Vector3, mat: Material) -> void:
	var body := StaticBody3D.new()
	body.position = at
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	body.add_child(mi)
	parent.add_child(body)


## The walk (seconds): look into the tunnel, walk west through the west portal (out of the
## east one, still heading west), and through again; stop; turn round to the east portal;
## step up close to the west one and look into it.
func _script(p: Actor, t: float) -> void:
	p.scripted = true
	p.intent.clear()
	var yaw: Node3D = p.get(&"_yaw")
	var pitch: Node3D = p.get(&"_pitch")
	if t < 2.5:
		pitch.rotation.x = -0.2
	elif t < 10.5:
		p.intent.move = Vector3.LEFT * 0.45
	elif t < 13.5:
		yaw.rotation.y = PI * 0.5 + PI * smoothstep(10.5, 13.5, t)
	elif t < 16.5:
		yaw.rotation.y = PI * 1.5 - PI * smoothstep(13.5, 16.5, t)
		pitch.rotation.x = lerpf(-0.2, -0.05, smoothstep(13.5, 16.5, t))


func _process(delta: float) -> void:
	if _frame == 0:
		return
	_t += delta
	var p := ZoneManager.player as Actor
	_script(p, _t)
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	for portal in [a, b]:
		for vp in portal.chain.find_children("*", "SubViewport", true, false):
			RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid())
	if _frame > 5:
		_gpu_sum += gpu
		_gpu_n += 1
	if OS.get_environment("DEBUG_FRAMES") == "cam" and _frame >= 58 and _frame <= 80:
		await RenderingServer.frame_pre_draw
		var cam := get_viewport().get_camera_3d()
		var cp: Array = a._mat.get_shader_parameter(&"cam_pos")
		print("DBG f%d cam %s mat0 %s levels %d hidden %d" % [_frame, cam.global_position, cp[0] if cp else null, a._mat.get_shader_parameter(&"levels"), a._hidden])
	if OS.get_environment("DEBUG_FRAMES") != "" and _frame == int(OS.get_environment("DEBUG_FRAMES")):
		await RenderingServer.frame_post_draw
		var k := 0
		for vp in a.chain.find_children("*", "SubViewport", true, false):
			k += 1
			var im := (vp as SubViewport).get_texture().get_image()
			if im:
				im.save_png(out + "/lvl_f%d_%d.png" % [_frame, k])
			print("DBG f%d level %d size %s mode %d rect %s" % [_frame, k, vp.size, vp.render_target_update_mode, a._mat.get_shader_parameter(&"rects")[k]])
	if _frame % 30 == 0:
		var vo = RenderScale.video_out()
		print("PORTAL t=%.1f levels west %d east %d  player %s  counting %s px west %d east %d hidden %d/%d" % [_t, a.chain.levels, b.chain.levels, p.global_position, vo.call(&"counting"), vo.call(&"visible_pixels", a._id), vo.call(&"visible_pixels", b._id), a._hidden, b._hidden])
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.resize(1280, 720, Image.INTERPOLATE_BILINEAR)
	img.save_png(out + "/frames/%05d.png" % _frame)
	_frame += 1
	if _t > float(OS.get_environment("SECONDS") if OS.get_environment("SECONDS") != "" else "16"):
		print("PORTAL mean gpu %.2f ms over %d frames" % [_gpu_sum / maxf(_gpu_n, 1), _gpu_n])
		get_tree().quit()
