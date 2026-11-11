extends Node
# Landing keeps momentum unless the fall hurts: runs off a jump / a 3 m drop / a 10 m drop
# holding the stick, printing horizontal speed just before and after touchdown.
# Run: godot --headless --path . tests/move/landing.tscn
func box(pos: Vector3, size: Vector3) -> void:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	b.add_child(cs)
	b.position = pos
	add_child(b)


var _dips := []


func _ready() -> void:
	box(Vector3(0, -0.5, 0), Vector3(200, 1, 200))
	box(Vector3(30, 1.5, 0), Vector3(10, 3, 10))
	box(Vector3(60, 5, 0), Vector3(10, 10, 10))
	var p: Actor = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.scripted = true
	# The landing dip, measured after it's applied: hips and lowest foot above the actor's feet.
	var dip: LandDip = p.find_children("*", "LandDip", true, false)[0]
	var sk: Skeleton3D = dip.get_skeleton()
	dip.modification_processed.connect(func():
		if p.land_dip() > 0.0:
			var hips: Vector3 = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(&"hips")).origin
			var fl: Vector3 = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(&"foot_L")).origin
			var fr: Vector3 = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(&"foot_R")).origin
			_dips.append("%.3f/%.3f" % [hips.y - p.global_position.y, minf(fl.y, fr.y) - p.global_position.y]))
	for c in [["jump on flat", Vector3(0, 0, 0), true], ["run off 3 m", Vector3(30, 3, 2), false], ["run off 10 m", Vector3(60, 10, 2), false]]:
		p.global_position = c[1]
		p.velocity = Vector3.ZERO
		p.intent.move = Vector3.ZERO
		for i in 30:
			await get_tree().physics_frame
		p.intent.move = Vector3(0, 0, -1)
		for i in 20:
			await get_tree().physics_frame
		if c[2]:
			p.intent.press(&"jump")
		var before := 0.0
		var after := []
		var left := false
		var landed := -1
		var states := ""
		for i in 240:
			await get_tree().physics_frame
			var hs := Vector2(p.velocity.x, p.velocity.z).length()
			left = left or not p.is_on_floor()
			if left and landed < 0:
				if p.is_on_floor():
					landed = i
				else:
					before = hs
			elif landed >= 0:
				after.append("%.1f" % hs)
				var s := String(p.state_of(&"Locomotion").name)
				if not states.ends_with(s):
					states += " " + s
				if after.size() >= 12:
					break
		print("  dip hips/foot above ground (m): ", " ".join(_dips.slice(0, 16)))
		_dips.clear()
		print("%-13s speed before %.1f, after landing (12 frames): %s  states:%s" % [c[0], before, " ".join(after), states])
	get_tree().quit()
