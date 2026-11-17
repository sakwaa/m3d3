extends Node
func _ready() -> void:
	for nm in ["jacaranda", "silk_tree", "sycamore"]:
		var t: Texture2D = load("res://textures/plants/leaves_%s_solid.res" % nm)
		var o: Texture2D = load("res://textures/plants/leaves_%s.res" % nm)
		var a := o.get_image()
		if a.is_compressed(): a.decompress()
		a.convert(Image.FORMAT_RGBA8)
		var b := t.get_image()
		b.clear_mipmaps()
		print("[sd] ", nm, " ", a.get_size())
		a.resize(256, 256, Image.INTERPOLATE_NEAREST)
		b.resize(256, 256, Image.INTERPOLATE_NEAREST)
		a.save_png(OS.get_environment("OUT") + "/%s_leaf.png" % nm)
		b.save_png(OS.get_environment("OUT") + "/%s_solid.png" % nm)
	get_tree().quit()
