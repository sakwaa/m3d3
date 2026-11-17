extends SceneTree
func _init() -> void:
	for p in ["res://zones/town1/town1_level.res", "res://zones/town1/town_1_market_square_level.res", "res://zones/town1/town_1_hillside_level.res", "res://zones/town1/house_outside_town_level.res"]:
		var d: LevelData = load(p)
		var i := 0
		for b in d.brushes:
			if b and b.is_passage():
				print(p, " #", i, " pos ", b.transform.origin, " fwd ", -b.transform.basis.z, " size ", b.passage.get(&"width"), "x", b.passage.get(&"height"), " depth ", b.passage.get(&"depth"))
			i += 1
	quit()
