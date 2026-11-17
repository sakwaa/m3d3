extends Node3D
## Coverage IDs check: two actors overlapping at nearly the same depth, a crate 10 cm in
## front of a wall, 6 m away. EDGE=1: the coverage debug view (partly covered pixels red).
##   OUT=dir [EDGE=1] godot --path . tests/render/coverage_ids.tscn

const ACTOR := preload("res://addons/n64_runtime/shaders/n64_actor.gdshader")
const TEXTURED := preload("res://addons/n64_runtime/shaders/n64_textured.gdshader")
var _f := 0


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.25, 0.27, 0.33)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.75)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	add_child(sun)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.2, 6)
	cam.fov = 35
	add_child(cam)
	cam.look_at(Vector3(0, 1.0, 0))
	for i in 2:
		var m := ShaderMaterial.new()
		m.shader = ACTOR
		m.set_shader_parameter(&"albedo_color", [Color(0.85, 0.45, 0.3), Color(0.35, 0.55, 0.85)][i])
		var s := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.5
		sm.height = 1.0
		s.mesh = sm
		s.material_override = m
		s.position = Vector3(-1.3 + i * 0.6, 1.2, -i * 0.1)
		add_child(s)
	for k in 2:
		var m := ShaderMaterial.new()
		m.shader = TEXTURED
		m.set_shader_parameter(&"albedo_texture", load(["res://textures/brick/brick_1.res", "res://textures/wood/wood_1.res"][k]))
		var b := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(2.2, 2.0, 0.2) if k == 0 else Vector3(0.8, 0.8, 0.8)
		b.mesh = bm
		b.material_override = m
		b.position = Vector3(1.4, 1.0, -0.6) if k == 0 else Vector3(1.4, 0.8, -0.0)
		add_child(b)
	if OS.get_environment("EDGE") != "":
		(load("res://game/video_out.tres") as Resource).set(&"edge_show", true)


func _process(_d: float) -> void:
	_f += 1
	if _f == 12:
		get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/shot.png")
		get_tree().quit()
