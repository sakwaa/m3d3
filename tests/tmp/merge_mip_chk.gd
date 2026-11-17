extends SceneTree
func _init() -> void:
	var MM = load("res://addons/n64_level_tools/material_merge.gd")
	var zone: Node = (load("res://zones/town1/town_1_market_square.tscn") as PackedScene).instantiate()
	for lr in zone.find_children("*", "", true, false):
		var data = lr.get(&"data")
		if data == null or data.get(&"textures") == null:
			continue
		for t in data.get(&"textures"):
			if t == null:
				continue
			var img: Image = t.get_image()
			var expect := Image.create_empty(img.get_width(), img.get_height(), img.has_mipmaps(), Image.FORMAT_RGBA8).get_data().size()
			var c := img.duplicate() as Image
			c.convert(Image.FORMAT_RGBA8)
			if c.get_data().size() != expect:
				print("BAD source %s %s mips %d data %d expect %d" % [t.resource_path.get_file(), img.get_size(), img.get_mipmap_count(), c.get_data().size(), expect])
			var out: Image = MM._at_size_keep_mips(img, 64)
			if out == null or out.is_empty():
				print("EMPTY merge layer for ", t.resource_path.get_file(), " ", img.get_size())
	quit()
