extends Node3D
## Knee check: plays every animation of the player model frame by frame and flags any frame
## where a knee bends backwards (the shin swung forward of the thigh's line, seen from the
## side; the model faces -Z). Run after changing any clip.
##   godot --headless --path . tests/anim/knee_check.tscn   [TOL=8]  (degrees allowed)


func _ready() -> void:
	var tol := float(OS.get_environment("TOL")) if OS.get_environment("TOL") != "" else 8.0
	var model: Node = (load("res://characters/player_model.tscn") as PackedScene).instantiate()
	add_child(model)
	await get_tree().process_frame
	var ap: AnimationPlayer = model.find_children("*", "AnimationPlayer", true, false)[0]
	var sk: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
	var bad := 0
	for anim_name in ap.get_animation_list():
		var anim := ap.get_animation(anim_name)
		var worst := {}
		var t := 0.0
		while t <= anim.length + 0.0001:
			ap.play(anim_name)
			ap.seek(t, true)
			ap.advance(0)
			for side in ["L", "R"]:
				var hip := sk.get_bone_global_pose(sk.find_bone("thigh_" + side)).origin
				var knee := sk.get_bone_global_pose(sk.find_bone("shin_" + side)).origin
				var ankle := sk.get_bone_global_pose(sk.find_bone("foot_" + side)).origin
				# Forward angle from straight down (side view, -Z forward).
				var thigh := rad_to_deg(atan2(-(knee - hip).z, -(knee - hip).y))
				var shin := rad_to_deg(atan2(-(ankle - knee).z, -(ankle - knee).y))
				var over := shin - thigh  # > 0: the shin ahead of the thigh = knee bent backwards
				if over > tol and over > float(worst.get(side, [0.0])[0]):
					worst[side] = [over, t]
			t += 1.0 / 30.0
		for side in worst:
			bad += 1
			print("%-16s %s knee backwards by %4.0f deg at %.2f s" % [anim_name, side, worst[side][0], worst[side][1]])
	print("knee check: %d leg(s) with backwards knees" % bad)
	get_tree().quit()
