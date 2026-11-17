extends SceneTree
func _m1(img: Image) -> PackedByteArray:
	var o := img.get_mipmap_offset(1)
	return img.get_data().slice(o, o + 32 * 32 * 4)
func _init() -> void:
	var t: N64Texture = load("res://textures/roof/shingles_3.res")
	var src := Image.load_from_file(t.source_path)
	var r := N64TextureConverter.convert(src, t.get_settings())
	var want := _m1(r.mips)
	for p in t.get_property_list():
		if not (p.usage & PROPERTY_USAGE_STORAGE) or p.name in ["script", "resource_path", "resource_name", "resource_local_to_scene", "image"]:
			continue
		var f := N64Texture.new()
		f.set(p.name, t.get(p.name))
		f.set_image(r.mips)
		if _m1(f.get_image()) != want:
			print("breaks: ", p.name, " = ", t.get(p.name))
	var g := N64Texture.new()
	g.set_image(t.get_image())
	g.set_image(r.mips)
	print("after old image first: ", _m1(g.get_image()) == want)
	quit()
