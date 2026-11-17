extends Node3D
func _ready() -> void:
	for z in ["town_1_hillside", "house_outside_town", "town_1_market_square"]:
		var d: LevelData = load("res://zones/town1/%s_level.res" % z)
		var trees := 0
		var species := {}
		for b in d.brushes:
			if b and b.is_prop() and b.prop.kind == PropSpec.Kind.TREE:
				trees += 1
				var s = b.prop.settings.get(&"species")
				species[s.resource_path if s else "?"] = species.get(s.resource_path if s else "?", 0) + 1
		print("[tree] %s: %d tree brushes %s; scatter sets %d" % [z, trees, species, d.scatter.size()])
		for s in d.scatter:
			print("[tree]    scatter ", s.resource_path, " ", s.get_property_list().filter(func(p): return p.usage & PROPERTY_USAGE_STORAGE).map(func(p): return p.name).slice(0, 12))
	get_tree().quit()
