extends SceneTree
func _m1(img: Image) -> PackedByteArray:
	var o := img.get_mipmap_offset(1)
	return img.get_data().slice(o, o + 32 * 32 * 4)
func _init() -> void:
	var t: N64Texture = load("res://textures/roof/shingles_3.res")
	var src := Image.load_from_file(t.source_path)
	var r := N64TextureConverter.convert(src, t.get_settings())
	var want := _m1(r.mips)
	var copy := t.duplicate() as N64Texture
	copy.set_image(Image.create(1, 1, false, Image.FORMAT_RGBA8))
	copy.set_image(r.mips)
	print("duplicate keeps: ", _m1(copy.get_image()) == want)
	var out := OS.get_environment("OUT") + "/probe.res"
	ResourceSaver.save(copy, out)
	var back: Texture2D = ResourceLoader.load(out, "", ResourceLoader.CACHE_MODE_IGNORE)
	print("saved + reloaded keeps: ", _m1(back.get_image()) == want)
	quit()
