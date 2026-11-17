extends SceneTree
func _init() -> void:
	var n := 0
	var custom := 0
	for p in ["res://textures/brick/brick_old.res", "res://textures/rock/rock_cliff.res", "res://textures/ground/mud.res"]:
		pass
	var dir := "res://textures"
	var files := []
	for d in DirAccess.get_directories_at(dir):
		if d.begins_with("_") or d == "detail":
			continue
		for f in DirAccess.get_files_at(dir + "/" + d):
			if f.ends_with(".res"):
				files.append(dir + "/" + d + "/" + f)
	files.shuffle()
	for p in files.slice(0, 40):
		var t = load(p)
		if not (t is N64Texture) or t.get_script() != N64Texture or t.source_path == "":
			continue
		var img: Image = t.get_image().duplicate()
		img.convert(Image.FORMAT_RGBA8)
		if not img.has_mipmaps() or img.get_width() < 4:
			continue
		var l0 := Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, img.get_data().slice(0, img.get_width() * img.get_height() * 4))
		l0.generate_mipmaps()
		var o := img.get_mipmap_offset(1)
		var sz := maxi(img.get_width() >> 1, 1) * maxi(img.get_height() >> 1, 1) * 4
		n += 1
		if img.get_data().slice(o, o + sz) != l0.get_data().slice(l0.get_mipmap_offset(1), l0.get_mipmap_offset(1) + sz):
			custom += 1
	print("SPOT %d of %d sampled textures have N64-made levels" % [custom, n])
	quit()
