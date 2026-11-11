extends Node
# Jump slash lands its chop on contact whatever the height: flat, off a 3 m ledge, up onto
# a 1 m step. Prints when JumpSlashLand starts relative to touchdown (target ~0.13 s before).
# Run: godot --headless --path . tests/combat/jump_slash.tscn
var p: Actor


func box(pos: Vector3, size: Vector3) -> void:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	b.add_child(cs)
	b.position = pos
	add_child(b)


func _ready() -> void:
	box(Vector3(0, -0.5, 0), Vector3(60, 1, 60))
	box(Vector3(20, 1.5, 0), Vector3(4, 3, 40))   # ledge top 3 m, edge at x 18 (jump towards -x)
	box(Vector3(-20, 0.5, -3), Vector3(10, 1, 4)) # 1 m step, front face at z -1
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.scripted = true
	for c in [["flat", Vector3(0, 0, 0), Vector3.FORWARD], ["off 3 m ledge", Vector3(18.5, 3, 0), Vector3.LEFT],
			["up 1 m step", Vector3(-20, 0, 0.6), Vector3.FORWARD]]:
		p.global_position = c[1]
		p.velocity = Vector3.ZERO
		p.facing = c[2]
		for i in 150:  # until the last swing is over
			await get_tree().physics_frame
			if i > 30 and p.state_of(&"Action").name == &"Ready":
				break
		p.intent.press(&"jump_attack")
		var t := 0.0
		var t_land_state := -1.0
		var left := false
		var air := false
		for i in 240:
			await get_tree().physics_frame
			t += 1.0 / Engine.physics_ticks_per_second
			var st: StringName = p.state_of(&"Action").name
			if st == &"JumpSlash":
				air = true
			if t_land_state < 0.0 and st == &"JumpSlashLand":
				t_land_state = t
			left = left or not p.is_on_floor()
			if left and p.is_on_floor():
				break
		print("%-14s air state %s, airtime %.2f s, chop started %.2f s before touchdown" % [c[0], air, t, t - t_land_state])
	get_tree().quit()
