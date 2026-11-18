extends SceneTree
func _init() -> void:
	for p in ["res://textures/rock/stone_wall_rubble.res", "res://textures/rock/rock_cliff.res"]:
		var t = load(p)
		print("WS ", p.get_file(), " world_size ", t.get("world_size"), " size ", t.get_size())
	quit()
