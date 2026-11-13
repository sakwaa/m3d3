extends Node
# One swing from the side (SWING=name, default SlashVFin): every frame to OUT=dir. Run with --fixed-fps 60.
var p: Actor
var frame := 0

func _ready() -> void:
	var floor := StaticBody3D.new(); var cs := CollisionShape3D.new(); var sh := BoxShape3D.new(); sh.size = Vector3(40, 1, 40)
	cs.shape = sh; floor.add_child(cs); floor.position.y = -0.5; add_child(floor)
	var fm := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = sh.size; fm.mesh = bm; floor.add_child(fm)
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.5, 0.6, 0.75)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment = e; add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 30, 0); add_child(sun)
	Actor.show_debug = false
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.scripted = true
	var cam := Camera3D.new(); cam.fov = 40; add_child(cam)
	cam.global_position = Vector3(3.2, 1.3, -0.6)
	cam.look_at(Vector3(0, 1.0, -0.6))
	cam.make_current()
	for i in 30:
		await get_tree().physics_frame
	p._sheathe(false)
	var sw := OS.get_environment("SWING")
	p.machine(&"Action").request(StringName(sw if sw != "" else "SlashVFin"), true)
	for i in 50:
		await get_tree().physics_frame
		frame += 1
		get_viewport().get_texture().get_image().save_png("%s/f_%04d.png" % [OS.get_environment("OUT"), frame])
	get_tree().quit()
