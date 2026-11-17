extends SceneTree
func _init() -> void:
	var out := OS.get_environment("OUT")
	for n in ["textures/concrete/stucco_3", "textures/roof/shingles_3"]:
		var t: Texture2D = load("res://" + n + ".res")
		var img := t.get_image()
		img.clear_mipmaps()
		img.convert(Image.FORMAT_RGBA8)
		img.save_png(out + "/" + n.get_file() + "_base.png")
		var h: Texture2D = t.get(&"detail_texture")
		var hi := h.get_image()
		hi.clear_mipmaps()
		hi.convert(Image.FORMAT_RGBA8)
		hi.save_png(out + "/" + n.get_file() + "_hi.png")
		print(n, " ", img.get_size(), " ", hi.get_size(), " src ", t.get(&"source_path"), " zoom ", t.get(&"zoom"), " auto ", t.get(&"zoom_auto"), " world ", t.get(&"world_size"))
	quit()
