extends Node
# Chain render (MM picks): three neutral cuts (the same cut, swung back, then the third),
# stick right (the other way), locked + forward (stab stepping in). OUT=dir saves every frame.
var p: Actor
var t := 0.0
var frame := 0
var steps := [[0.4, "attack"], [0.82, "attack"], [1.24, "attack"], [2.1, "right"], [2.15, "attack"], [2.5, "stopmove"], [3.1, "lock"], [3.4, "forward"], [3.45, "attack"], [3.8, "stopmove"], [4.6, "end"]]

func _ready() -> void:
	var floor := StaticBody3D.new(); var cs := CollisionShape3D.new(); var sh := BoxShape3D.new(); sh.size = Vector3(40, 1, 40)
	cs.shape = sh; floor.add_child(cs); floor.position.y = -0.5; add_child(floor)
	var fm := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = sh.size; fm.mesh = bm; floor.add_child(fm)
	var fmat := StandardMaterial3D.new(); fmat.albedo_color = Color(0.4, 0.45, 0.35); fm.material_override = fmat
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.22, 0.25, 0.3)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.environment = e; add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 30, 0); add_child(sun)
	if OS.get_environment("JUICE") == "0":
		for k in Combat.juice: Combat.juice[k] = false
	var d := CombatDummy.new(); d.position = Vector3(0, 0.1, -1.7); d.respawn = 0.6; d.profile = EnemyProfile.new()
	d.profile.max_health = 99
	add_child(d)
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.facing = Vector3(0, 0, -1)

func _physics_process(delta: float) -> void:
	t += delta
	while not steps.is_empty() and t >= steps[0][0]:
		var s: String = steps.pop_front()[1]
		match s:
			"attack":
				var ev := InputEventAction.new(); ev.action = &"attack"; ev.pressed = true; Input.parse_input_event(ev)
				Input.action_press(&"attack")
				get_tree().create_timer(0.05).timeout.connect(func(): Input.action_release(&"attack"))
			"lock": Input.action_press(&"target")
			"right": Input.action_press(&"move_right")
			"forward": Input.action_press(&"move_forward")
			"stopmove":
				for a in [&"move_right", &"move_forward"]: Input.action_release(a)
			"end": get_tree().quit()
	if OS.get_environment("DEBUG") != "":
		var a = p.state_of(&"Action")
		var tr = p.get_node_or_null("SwordTrail")
		if a is AttackState:
			print("%.2f %s p=%.2f w=%s swing=%s samples=%d" % [t, a.name, a.progress(), a.windows, p._swing_trail(), tr._samples.size() if tr else -1])
	var out := OS.get_environment("OUT")
	if out != "":
		frame += 1
		get_viewport().get_texture().get_image().save_png("%s/f_%04d.png" % [out, frame])
