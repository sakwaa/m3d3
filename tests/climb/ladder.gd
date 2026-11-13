extends Node
# Ladder test: a deck 3 m up (face at z=0, top y=3) with a ladder up its front, top rung
# level with the deck. CLIMB_TEST: up (walk in, climb, top out), down (walk off the deck
# over the ladder's top, climb down, step off), letgo, jump. Windowed with SHOTS=t1,t2..
# and OUT=dir: screenshots (FRAMES=1: every other physics frame instead, for a GIF) (CAMSIDE / CAMBACK = side / MM's behind view, else 3/4).
var p: Actor
var cam: Camera3D
var shots := []
var shot_i := 0
var t := 0.0
var phase := 0
var log_t := 0.0
var steps := []  # [until_time, move, label]

func box(pos: Vector3, size: Vector3) -> void:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new(); sh.size = size
	cs.shape = sh
	b.add_child(cs); b.position = pos
	add_child(b)
	var mi := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = size; mi.mesh = bm
	var m := StandardMaterial3D.new(); m.albedo_color = Color(0.6, 0.58, 0.55)
	mi.material_override = m; b.add_child(mi)

func _ready() -> void:
	box(Vector3(0, -0.5, 0), Vector3(40, 1, 40))
	box(Vector3(0, 1.5, -2), Vector3(4, 3, 4))  # deck: face z=0, top y=3
	var lad := Ladder.new()
	lad.position = Vector3(0, 0, 0.04)
	lad.height = 3.0
	add_child(lad)
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.scripted = true
	var st := OS.get_environment("SHOTS")
	if st != "" or OS.get_environment("FRAMES") != "":
		for x in st.split(","): shots.append(float(x))
		var env := WorldEnvironment.new(); var e := Environment.new()
		e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.5, 0.6, 0.75)
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.6, 0.6, 0.65)
		env.environment = e; add_child(env)
		var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 30, 0); add_child(sun)
		cam = Camera3D.new(); cam.fov = 50; add_child(cam)
	match OS.get_environment("CLIMB_TEST"):
		"up":
			p.global_position = Vector3(0, 0, 2)
			steps = [[9.0, Vector3(0, 0, -1), "walk in, climb up, top out"], [10.0, Vector3.ZERO, "stop"]]
		"down":
			p.global_position = Vector3(0, 3, -1.2)
			p.facing = Vector3(0, 0, 1)
			steps = [[0.5, Vector3.ZERO, "settle"], [9.0, Vector3(0, 0, 1), "walk off the top, climb down, step off"], [10.0, Vector3.ZERO, "stop"]]
		"updown":
			p.global_position = Vector3(0, 0, 2)
			steps = [[2.95, Vector3(0, 0, -1), "walk in, climb up, top out"], [3.5, Vector3.ZERO, "stand"],
				[6.5, Vector3(0, 0, 1), "turn, over the top, climb down, step off"], [6.7, Vector3(0, 0, 1), "walk away"], [7.4, Vector3.ZERO, "stop"]]
		"letgo":
			p.global_position = Vector3(0, 0, 2)
			steps = [[1.5, Vector3(0, 0, -1), "climb"], [1.6, Vector3.ZERO, "letgo"], [5.0, Vector3.ZERO, "fall"]]
		"jump":
			p.global_position = Vector3(0, 0, 2)
			steps = [[1.5, Vector3(0, 0, -1), "climb"], [1.6, Vector3.ZERO, "jumpnow"], [5.0, Vector3.ZERO, "fall"]]

func _physics_process(delta: float) -> void:
	t += delta
	while phase < steps.size() and t > steps[phase][0]:
		phase += 1
		if phase < steps.size():
			print("--- ", steps[phase][2])
			if steps[phase][2] == "jumpnow":
				p.intent.press(&"jump")
			if steps[phase][2] == "letgo":
				p.intent.press(&"interact")
	if phase >= steps.size():
		get_tree().quit()
		return
	p.intent.move = steps[phase][1]
	if cam:
		cam.make_current()
		var o := p.global_position
		cam.global_position = o + Vector3(1.8, 1.4, 2.6)
		if OS.get_environment("CAMSIDE") != "":
			cam.global_position = o + Vector3(3.2, 1.0, 0.0)
		if OS.get_environment("CAMBACK") != "":
			cam.global_position = o + Vector3(0.3, 1.6, 3.4)
		cam.look_at(o + Vector3.UP * 1.1)
		if OS.get_environment("CAMFIXED") != "":  # the whole ladder and the deck's edge
			cam.global_position = Vector3(4.2, 2.6, 5.2)
			cam.look_at(Vector3(0, 1.7, -0.4))
	if cam and OS.get_environment("FRAMES") != "":
		shot_i += 1
		if shot_i % 2 == 0:
			get_viewport().get_texture().get_image().save_png("%s/f_%04d.png" % [OS.get_environment("OUT"), shot_i / 2])
	elif shot_i < shots.size() and t >= shots[shot_i]:
		get_viewport().get_texture().get_image().save_png("%s/ladder_%s_%d.png" % [OS.get_environment("OUT"), OS.get_environment("CLIMB_TEST"), shot_i])
		shot_i += 1
	log_t += delta
	if log_t >= 0.2:
		log_t = 0.0
		var s := p.state_of(&"Locomotion")
		var extra := ""
		if s is LocoLadder:
			var l := s as LocoLadder
			extra = " rung=%d limbs y=[%.2f %.2f | %.2f %.2f]" % [l._b, l._limbs[0].y, l._limbs[1].y, l._limbs[2].y, l._limbs[3].y]
		print("%.1f %s pos=(%.2f,%.2f,%.2f) facing=(%.2f,%.2f)%s" % [t, s.name, p.global_position.x, p.global_position.y, p.global_position.z, p.facing.x, p.facing.z, extra])
