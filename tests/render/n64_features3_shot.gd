extends Node3D
## Render check, third set: heat haze over a fire spot in front of a wall (#4), Lens of Truth
## with a hidden and a false box (#5; LENS=0 off), a sign swapping picture by distance (#6),
## an energy shield round a box (#7).  OUT=<dir> godot --path . tests/render/n64_features3_shot.tscn

const TEXTURED := preload("res://addons/n64_runtime/shaders/n64_textured.gdshader")
var _frames := 0


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.22, 0.24, 0.3)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.75)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	add_child(sun)
	RenderingServer.global_shader_parameter_set(&"n64_ambient_light", Color(1, 1, 1))
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.6, 6.5)
	cam.fov = 55
	add_child(cam)
	cam.look_at(Vector3(0, 1.0, 0))
	var wall_tex: Texture2D = load("res://textures/brick/brick_1.res")
	# Back wall (for the haze to bend) and floor.
	_box(Vector3(0, 1.5, -1.5), Vector3(9, 3, 0.2), wall_tex, Vector2(6, 2))
	_box(Vector3(0, -0.05, 0.5), Vector3(9, 0.1, 5), load("res://textures/rock/cobblestone_square.res"), Vector2(6, 3))
	# 4: heat haze over a "fire" (an orange box) on the left.
	_box(Vector3(-3, 0.15, -0.6), Vector3(0.5, 0.3, 0.5), null, Vector2.ONE, Color(1.0, 0.45, 0.1))
	var haze := HeatHaze.new()
	haze.width = 1.2
	haze.height = 2.0
	haze.position = Vector3(-3, 0.3, -0.6)
	add_child(haze)
	# 5: lens boxes in the middle (left hidden, right false).
	var hidden := _box(Vector3(-0.6, 0.5, 0), Vector3(0.8, 0.8, 0.8), null, Vector2.ONE, Color(0.4, 0.9, 0.5))
	var fake := _box(Vector3(0.6, 0.5, 0), Vector3(0.8, 0.8, 0.8), null, Vector2.ONE, Color(0.9, 0.4, 0.5))
	LensOfTruth.mark(hidden, LensOfTruth.Mode.HIDDEN)
	LensOfTruth.mark(fake, LensOfTruth.Mode.FALSE)
	if OS.get_environment("LENS") != "0":
		LensOfTruth.set_on(get_tree(), true)
	# 6: two signs, near and far: the picture changes with distance.
	for i in 2:
		var m := ShaderMaterial.new()
		m.shader = TEXTURED
		m.set_shader_parameter(&"albedo_texture", load("res://textures/doors/red_flush_number.res"))
		m.set_shader_parameter(&"swap_texture", load("res://textures/doors/blue_six_panel.res"))
		m.set_shader_parameter(&"use_swap", true)
		m.set_shader_parameter(&"swap_lod", Vector2(0.6, 1.4))
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(0.9, 1.2)
		q.mesh = qm
		q.material_override = m
		# (the second sign tiny: few pixels per texel, a higher mip level, as if far away)
		q.position = Vector3(1.9, 1.7, -1.3) if i == 0 else Vector3(2.6, 1.9, -1.3)
		q.scale = Vector3.ONE if i == 0 else Vector3.ONE * 0.22
		add_child(q)
	if OS.get_environment("RDP") != "":
		# RDP=1: dissolve (box at 0.45), prim fog (box at 0.6), glass pane, cloud card - in front.
		var d := _box(Vector3(-2.2, 0.45, 1.8), Vector3(0.8, 0.9, 0.8), load("res://textures/wood/wood_1.res"), Vector2.ONE)
		d.set_instance_shader_parameter(&"dissolve", 0.45)
		var f := _box(Vector3(-1.0, 0.45, 1.8), Vector3(0.8, 0.9, 0.8), load("res://textures/wood/wood_1.res"), Vector2.ONE)
		f.set_instance_shader_parameter(&"prim_fog", 0.6)
		RenderingServer.global_shader_parameter_set(&"n64_fog_color", Color(0.55, 0.6, 0.75))
		for k in 2:
			var q := MeshInstance3D.new()
			var qm := QuadMesh.new()
			qm.size = Vector2(1.1, 1.2)
			q.mesh = qm
			q.material_override = load("res://game/materials/translucent_%s.tres" % ["glass", "cloud"][k])
			q.position = Vector3(0.6 + k * 1.3, 0.7, 2.0)
			add_child(q)
	# 7: shield round a box on the right.
	_box(Vector3(3.3, 0.4, -0.4), Vector3(0.5, 0.8, 0.5), null, Vector2.ONE, Color(0.8, 0.8, 0.8))
	var s := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.75
	sm.height = 1.5
	s.mesh = sm
	s.material_override = load("res://game/materials/shield.tres")
	s.position = Vector3(3.3, 0.45, -0.4)
	add_child(s)


func _box(pos: Vector3, size: Vector3, tex: Texture2D, rep: Vector2, col := Color.WHITE) -> MeshInstance3D:
	var m := ShaderMaterial.new()
	m.shader = TEXTURED
	m.set_shader_parameter(&"albedo_color", col)
	m.set_shader_parameter(&"has_texture", tex != null)
	if tex:
		m.set_shader_parameter(&"albedo_texture", tex)
		m.set_shader_parameter(&"uv_scale", rep)
	var b := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	b.mesh = bm
	b.material_override = m
	b.position = pos
	add_child(b)
	return b


func _process(_d: float) -> void:
	_frames += 1
	if _frames == 30:
		get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/shot.png")
		get_tree().quit()
