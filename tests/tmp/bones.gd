extends Node
func _ready() -> void:
	var p: Node = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	var sk: Skeleton3D = p.find_children("*", "Skeleton3D", true, false)[0]
	var names := []
	for i in sk.get_bone_count():
		names.append("%d:%s<-%d" % [i, sk.get_bone_name(i), sk.get_bone_parent(i)])
	print("[bones] ", names)
	for b in ["hand_R", "hand_L", "upper_arm_R", "upper_arm_L", "head", "chest", "prop_R", "prop_L"]:
		var i := sk.find_bone(b)
		if i >= 0:
			print("[bones] ", b, " rest ", sk.get_bone_global_rest(i).origin)
	for c in p.find_children("*", "BoneAttachment3D", true, false):
		print("[bones] attach ", c.name, " bone ", c.bone_name, " kids ", c.get_children().map(func(k): return k.name))
	get_tree().quit()
