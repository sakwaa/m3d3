extends SceneTree
func _init() -> void:
	var t: N64Texture = load("res://textures/roof/shingles_3.res")
	var have := t.get_image()
	var src := Image.load_from_file(t.source_path)
	var r := N64TextureConverter.convert(src, t.get_settings())
	var want: Image = r.mips
	var o := have.get_mipmap_offset(1)
	var a := have.get_data().slice(o, o + 32 * 32 * 4)
	var b := want.get_data().slice(want.get_mipmap_offset(1), want.get_mipmap_offset(1) + 32 * 32 * 4)
	var lvl0_same := have.get_data().slice(0, 64 * 64 * 4) == want.get_data().slice(0, 64 * 64 * 4)
	print("stored fmt ", have.get_format(), " mips ", have.get_mipmap_count(), " | lvl0 same ", lvl0_same, " | mip1 same as new chain ", a == b)
	var box := Image.create_from_data(64, 64, false, Image.FORMAT_RGBA8, want.get_data().slice(0, 64 * 64 * 4))
	box.generate_mipmaps()
	var c := box.get_data().slice(box.get_mipmap_offset(1), box.get_mipmap_offset(1) + 32 * 32 * 4)
	print("new chain mip1 == plain box mip1: ", b == c, "  stored == box: ", a == c)
	quit()
