extends Node
# Climb phases test: leap, ledge hang, ceiling, grip, fall damage.
var p: Actor
var t := 0.0
var phase := -1
var log_t := 0.0
var steps := []  # [until_time, move, label, press]
const C := Surface.CLIMBABLE

func box(pos: Vector3, size: Vector3, surface: int) -> void:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new(); sh.size = size
	cs.shape = sh; cs.set_meta(Surface.META, surface)
	b.add_child(cs); b.position = pos
	add_child(b)

func _ready() -> void:
	box(Vector3(0, -0.5, 0), Vector3(200, 1, 200), 0)
	# Leap up: climbable 0-3, plain 3-4.2, climbable 4.2-8 (face z=0.5).
	box(Vector3(32, 1.5, 0), Vector3(4, 3, 1), C)
	box(Vector3(32, 3.6, 0), Vector3(4, 1.2, 1), 0)
	box(Vector3(32, 6.1, 0), Vector3(4, 3.8, 1), C)
	# Leap sideways: climbable x44-47, plain 47-48.4, climbable 48.4-52.
	box(Vector3(45.5, 3, 0), Vector3(3, 6, 1), C)
	box(Vector3(47.7, 3, 0), Vector3(1.4, 6, 1), 0)
	box(Vector3(50.2, 3, 0), Vector3(3.6, 6, 1), C)
	# Ledge block (plain): top 2.6, front face z=1.
	box(Vector3(24, 1.3, 0), Vector3(4, 2.6, 2), 0)
	# Ceiling slab (climbable) y 3.5-4 over z 7..13, climbable wall at its far end (face z=13).
	box(Vector3(40, 3.75, 10), Vector3(6, 0.5, 6), C)
	box(Vector3(40, 2, 13.5), Vector3(6, 4, 1), C)
	# Vines up to a bare wall with a ledge: climbable 0-3, plain 3-4 (top 4).
	box(Vector3(70, 1.5, 0), Vector3(4, 3, 1), C)
	box(Vector3(70, 3.5, 0), Vector3(4, 1, 1), 0)
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.scripted = true
	var F := Vector3(0, 0, -1)
	match OS.get_environment("CLIMB_TEST"):
		"leap":
			p.global_position = Vector3(32, 0, 3)
			steps = [[2.6, F, "climb to the plain band"], [2.62, F, "leap up", &"jump"], [4.0, Vector3.ZERO, "hold"], [5.0, F, "climb on"]]
		"leapside":
			p.global_position = Vector3(46, 0, 3)
			steps = [[1.5, F, "grab+up"], [2.6, Vector3(1, 0, 0), "right to the gap"], [3.0, Vector3(1, 0, 0), "leap right", &"jump"], [4.0, Vector3.ZERO, "hold"]]
		"back":
			p.global_position = Vector3(46, 0, 3)
			steps = [[1.8, F, "grab+up"], [2.3, Vector3(0, 0, 1), "back jump", &"jump"], [3.5, Vector3.ZERO, "air"]]
		"ledge":
			p.global_position = Vector3(24, 0, 2.6)
			steps = [[0.25, F, "run"], [0.27, F, "jump", &"jump"], [1.4, Vector3.ZERO, "catch"], [4.5, Vector3(1, 0, 0), "shimmy right + corner"], [5.0, Vector3.ZERO, "hold"], [5.02, Vector3.ZERO, "pull up", &"jump"], [6.5, Vector3.ZERO, "on top"]]
		"ceiling":
			p.global_position = Vector3(40, 0, 9)
			steps = [[0.1, Vector3.ZERO, "stand"], [0.12, Vector3.ZERO, "jump", &"jump"], [1.2, Vector3.ZERO, "catch ceiling"], [5.0, Vector3(0, 0, 1), "hang forward into wall"], [6.0, Vector3.ZERO, "hold"]]
		"attack":
			p.global_position = Vector3(46, 0, 3)
			p.debug_log = true
			steps = [[1.0, F, "grab"], [1.02, F, "attack", &"attack"], [1.5, F, "climbing"], [1.52, F, "attack again", &"attack"], [2.0, F, "guard held", &"guardon"], [3.0, F, "climb more"], [3.02, Vector3(0, 0, 1), "down, attack", &"attack"], [5.0, Vector3(0, 0, 1), "down to ground"], [6.0, Vector3.ZERO, "rest"]]
		"catch":
			# On top of the 6 m vine wall (x 44..52 climbable, top 6), walk off its front edge
			# facing away: should catch the vines on the way down.
			p.global_position = Vector3(46, 6.05, -0.2)
			p.facing = Vector3(0, 0, 1)
			steps = [[0.55, Vector3(0, 0, 0.45), "walk off the edge, facing away"], [3.0, Vector3.ZERO, "caught?"]]
		"letgo":
			p.global_position = Vector3(46, 0, 3)
			steps = [[2.0, F, "grab+up"], [2.02, Vector3.ZERO, "let go (deliberate)", &"interact"], [3.5, Vector3.ZERO, "falls to the ground?"]]
		"grip":
			p.global_position = Vector3(46, 0, 3)
			steps = [[1.2, F, "grab"], [1.22, Vector3.ZERO, "low grip", &"lowgrip"], [6.0, Vector3.ZERO, "hold till empty"], [8.0, Vector3.ZERO, "refill on ground"]]
		"fall":
			p.global_position = Vector3(10, 14, 10)
			steps = [[3.0, Vector3.ZERO, "drop 14m"]]
		"vineledge":
			p.global_position = Vector3(70, 0, 3)
			steps = [[3.0, F, "climb to bare wall"], [4.5, F, "hang + pull up"], [5.0, Vector3.ZERO, "hold"]]

func _physics_process(delta: float) -> void:
	t += delta
	while phase + 1 <= steps.size() and (phase < 0 or t > steps[phase][0]):
		phase += 1
		if phase < steps.size():
			print("--- ", steps[phase][2])
			if steps[phase].size() > 3:
				match steps[phase][3]:
					&"lowgrip": p.grip.value = 2.0
					&"guardon": p.intent.hold(&"guard", true)
					var b: p.intent.press(b)
	if phase >= steps.size():
		get_tree().quit()
		return
	p.intent.move = steps[phase][1]
	if OS.get_environment("FEET") != "" and p.state_of(&"Locomotion").name == &"Climb":
		var rig = p.find_children("*", "ClimbRig", true, false)[0]
		var sk: Skeleton3D = rig.get_skeleton()
		var fl: Vector3 = rig._solved[2]
		var fr: Vector3 = rig._solved[3]
		print("F %.2f plantL %.3f boneL %.3f  plantR %.3f boneR %.3f  movL %s movR %s" % [t, rig._plant[2].y, fl.y, rig._plant[3].y, fr.y, rig._moving[2], rig._moving[3]])
	log_t += delta
	if log_t >= 0.2:
		log_t = 0.0
		print("%.1f %s/%s pos=(%.2f,%.2f,%.2f) f=(%.2f,%.2f) grip=%.1f hp=%d" % [t, p.state_of(&"Locomotion").name, p.state_of(&"Action").name, p.global_position.x, p.global_position.y, p.global_position.z, p.facing.x, p.facing.z, p.grip.value, p.health])
