extends Node
func _ready() -> void:
	var d: LevelData = ResourceLoader.load("res://zones/town1/town_1_market_square_level.res", "", ResourceLoader.CACHE_MODE_IGNORE)
	for i in d.textures.size():
		var t: Texture2D = d.textures[i]
		if t == null:
			continue
		var p := t.resource_path
		if p.contains("::") or p.get_file() in ["157_green_grass.res", "mud.res", "cement_3.res", "53_old_bricks.res", "stone_3.res"]:
			var img := t.get_image()
			if img == null:
				print(i, " ", p, " ", t.get_class(), " (no image) ", t.get_property_list().filter(func(q): return q.usage & PROPERTY_USAGE_SCRIPT_VARIABLE).map(func(q): return [q.name, t.get(q.name)]))
				continue
			if img.is_compressed(): img.decompress()
			img.save_png(OS.get_environment("SP") + "/tex_%d.png" % i)
			print(i, " ", p, " ", t.get_class(), " ", t.get("source") if "source" in t else "", " ", img.get_size())
	get_tree().quit()
