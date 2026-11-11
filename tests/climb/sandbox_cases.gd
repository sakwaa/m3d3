extends Node
var p: Actor
var t := 0.0
var phase := -1
var log_t := 0.0
var steps := []
func _ready() -> void:
	add_child(load("res://zones/debug/climb_sandbox/climb_sandbox.tscn").instantiate())
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.scripted = true
	p.debug_log = OS.get_environment("DBG") != ""
	var N := Vector3(0, 0, -1)
	var S := Vector3(0, 0, 1)
	match OS.get_environment("CLIMB_TEST"):
		"over30": p.global_position = Vector3(-10.2, 0, -3); steps = [[14.0, N, "into 30 overhang"]]
		"over40": p.global_position = Vector3(-6.8, 0, -3); steps = [[3.0, N, "into 40 overhang"]]
		"lean38": p.global_position = Vector3(9.8, 0, -2); steps = [[7.0, N, "up 38 lean-back"]]
		"flatten": p.global_position = Vector3(19, 0, -3); steps = [[9.0, N, "up the flattening climb"]]
		"noledge": p.global_position = Vector3(-34, 0, 20.6); steps = [[0.2, S, "run"], [0.22, S, "jump", &"jump"], [2.0, S, "no-ledge catch?"]]
		"ledgeok": p.global_position = Vector3(-30, 0, 20.6); steps = [[0.2, S, "run"], [0.22, S, "jump", &"jump"], [2.0, Vector3.ZERO, "catch"]]
		"lip": p.global_position = Vector3(8, 0, 20.4); steps = [[0.2, S, "run"], [0.22, S, "jump", &"jump"], [1.5, Vector3.ZERO, "catch lip"], [8.0, Vector3(1, 0, 0), "shimmy round corner"], [9.0, Vector3.ZERO, "hold"]]
		"ceilup": p.global_position = Vector3(26, 0, 26.6); steps = [[4.0, S, "climb inner wall up into ceiling"], [7.0, N, "hang back along ceiling"]]
		"ceil": p.global_position = Vector3(26, 0, 20.5); steps = [[0.5, S, "walk under"], [0.52, Vector3.ZERO, "jump", &"jump"], [1.5, Vector3.ZERO, "catch"], [6.0, S, "to far wall"], [9.0, N, "down the wall? no: back up into ceiling"]]
func _physics_process(delta: float) -> void:
	t += delta
	while phase + 1 <= steps.size() and (phase < 0 or t > steps[phase][0]):
		phase += 1
		if phase < steps.size():
			print("--- ", steps[phase][2])
			if steps[phase].size() > 3:
				p.intent.press(steps[phase][3])
	if phase >= steps.size():
		get_tree().quit()
		return
	p.intent.move = steps[phase][1]
	if t > 1.2 and t < 1.22:
		var sp := p.get_world_3d().direct_space_state
		for h in [0.3, 0.8, 1.4]:
			var o: Vector3 = p.global_position + Vector3.UP * h
			var hit := sp.intersect_ray(PhysicsRayQueryParameters3D.create(o, o + Vector3(0, 0, -1.5), p.collision_mask, [p.get_rid()]))
			var cl = p.machine(&"Locomotion").states[&"Climb"]
			cl.read_capsule()
			if not hit.is_empty():
				print("  holds ", cl.holds_wall(hit), " fits ", cl.fits(cl.wall_origin(hit)), " origin ", cl.wall_origin(hit), " cangrab ", cl.can_grab())
			print("ray h=", h, " ", hit.get("position"), " n=", hit.get("normal"), " surf=", Surface.describe(Surface.of_ray(hit)) if not hit.is_empty() else "")
	log_t += delta
	if log_t >= 0.5:
		log_t = 0.0
		print("%.1f %s pos=(%.2f,%.2f,%.2f) f=(%.2f,%.2f)" % [t, p.state_of(&"Locomotion").name, p.global_position.x, p.global_position.y, p.global_position.z, p.facing.x, p.facing.z])
