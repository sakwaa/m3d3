extends SceneTree
## Saves a texture's mip levels side by side (each blown up to level 0's size) as OUT/<name>_<TAG>.png.
func _init() -> void:
	for p in OS.get_environment("TEX").split(","):
		var t: Texture2D = load(p)
		var img := t.get_image()
		img.convert(Image.FORMAT_RGBA8)
		var w := img.get_width()
		var h := img.get_height()
		var n := mini(img.get_mipmap_count(), 4)
		var sheet := Image.create(w * 4 * (n + 1), h * 4, false, Image.FORMAT_RGBA8)
		for m in n + 1:
			var lw := maxi(w >> m, 1)
			var lh := maxi(h >> m, 1)
			var off := img.get_mipmap_offset(m)
			var lv := Image.create_from_data(lw, lh, false, Image.FORMAT_RGBA8, img.get_data().slice(off, off + lw * lh * 4))
			lv.resize(w * 4, h * 4, Image.INTERPOLATE_NEAREST)
			sheet.blit_rect(lv, Rect2i(0, 0, w * 4, h * 4), Vector2i(m * w * 4, 0))
		sheet.save_png(OS.get_environment("OUT") + "/" + p.get_file().get_basename() + "_" + OS.get_environment("TAG") + ".png")
	quit()
