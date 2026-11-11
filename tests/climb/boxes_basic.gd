extends Node
# Climb test: box wall 4x4x1 (climbable), floor, player driven by script.
var p: Actor
var t := 0.0
var phase := 0
var log_t := 0.0
var steps := []  # [until_time, move, label]

func box(pos: Vector3, size: Vector3, surface: int, tilt := 0.0) -> void:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new(); sh.size = size
	cs.shape = sh; cs.set_meta(Surface.META, surface)
	b.add_child(cs); b.position = pos; b.rotation.x = deg_to_rad(tilt)
	add_child(b)

func _ready() -> void:
	box(Vector3(0, -0.5, 0), Vector3(40, 1, 40), 0)
	box(Vector3(0, 2, 0), Vector3(4, 4, 1), Surface.CLIMBABLE)  # front face z=0.5, top y=4
	box(Vector3(8, 2, 0), Vector3(4, 4, 1), 0)  # plain wall
	box(Vector3(-2.5, 2, 2.5), Vector3(1, 4, 4), Surface.CLIMBABLE)  # inner corner: face x=-2
	box(Vector3(16, 2.5, 0), Vector3(4, 6, 1), Surface.CLIMBABLE, -20.0)  # overhang leaning out over +Z
	# Overhang: slab leaning out over -Z side... wedge via rotated box
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.scripted = true
	var test: String = OS.get_environment("CLIMB_TEST")
	match test:
		"up":
			p.global_position = Vector3(0.5, 0, 3)
			steps = [[6.0, Vector3(0, 0, -1), "walk in, climb up, pull up"], [7.0, Vector3.ZERO, "stop"]]
		"side":
			p.global_position = Vector3(1.0, 0, 3)
			steps = [[1.6, Vector3(0, 0, -1), "grab"], [2.2, Vector3(0, 0, -1), "up a bit"], [6.5, Vector3(1, 0, 0), "right around corner"], [7.5, Vector3(0, 0, 0), "hold"]]
		"down":
			p.global_position = Vector3(0, 0, 3)
			steps = [[1.6, Vector3(0, 0, -1), "grab+up"], [3.5, Vector3(0, 0, 1), "down to ground"], [6.0, Vector3(0, 0, 1), "walk away"]]
		"diag":
			p.global_position = Vector3(-1, 0, 3)
			steps = [[1.2, Vector3(0, 0, -1), "grab"], [2.2, Vector3(0.7, 0, -0.7), "diag up-right"], [2.6, Vector3.ZERO, "hold"], [4.1, Vector3.ZERO, "letgo"], [6.0, Vector3.ZERO, "fall"]]
		"inner":
			p.global_position = Vector3(-0.5, 0, 3)
			steps = [[1.6, Vector3(0, 0, -1), "grab"], [2.0, Vector3(0, 0, -1), "up"], [5.0, Vector3(-1, 0, 0), "left into inner corner"], [5.5, Vector3.ZERO, "hold"]]
		"over":
			p.global_position = Vector3(16, 0, 3)
			steps = [[1.0, Vector3(0, 0, -1), "walk in"], [6.0, Vector3(0, 0, -1), "up overhang"], [6.5, Vector3.ZERO, "hold"]]
		"jump":
			p.global_position = Vector3(0, 0, 4)
			steps = [[0.3, Vector3(0, 0, -1), "run"], [0.32, Vector3(0, 0, -1), "jumpnow"], [2.0, Vector3.ZERO, "air then hold"]]
		"plain":
			p.global_position = Vector3(8, 0, 3)
			steps = [[3.0, Vector3(0, 0, -1), "walk into plain wall"]]

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
	log_t += delta
	if log_t >= 0.2:
		log_t = 0.0
		print("%.1f %s pos=(%.2f,%.2f,%.2f) facing=(%.2f,%.2f)" % [t, p.state_of(&"Locomotion").name, p.global_position.x, p.global_position.y, p.global_position.z, p.facing.x, p.facing.z])
