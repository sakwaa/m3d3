extends Node
func _ready() -> void:
	var d: LevelData = load("res://zones/town1/town_1_market_square_level.res")
	print("[tl] grade ", d.grade, " shared ", d.grade.shared if d.grade else null)
	if d.grade:
		for k in d.grade.stacks:
			print("[tl]  stack ", k if k is String else k.resource_path, " ", d.grade.stacks[k].map(func(f): return f.title()))
		if d.grade.shared:
			for k in d.grade.shared.stacks:
				print("[tl]  shared ", k if k is String else k.resource_path, " ", d.grade.shared.stacks[k].map(func(f): return f.title()))
	for t in d.textures:
		if t:
			print("[tl] tex ", t.resource_path, " group ", GradeLayers.group_of(t))
	get_tree().quit()
