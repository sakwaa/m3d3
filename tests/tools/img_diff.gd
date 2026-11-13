extends Node
## Pixels that differ between two PNGs (any channel past 24/255). PAIRS=a1.png:b1.png,a2.png:b2.png
## Writes a mask next to each pair's first image (…_diff.png) when they differ.
##   PAIRS=... godot --headless --path . tests/tools/img_diff.tscn


func _ready() -> void:
	for pair in OS.get_environment("PAIRS").split(","):
		var ab := pair.split(":")
		var a := Image.load_from_file(ab[0])
		var b := Image.load_from_file(ab[1])
		var mask := Image.create(a.get_width(), a.get_height(), false, Image.FORMAT_L8)
		var n := 0
		for y in a.get_height():
			for x in a.get_width():
				var ca := a.get_pixel(x, y)
				var cb := b.get_pixel(x, y)
				if maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b))) > 24.0 / 255.0:
					n += 1
					mask.set_pixel(x, y, Color.WHITE)
		print("%s: %d of %d pixels differ" % [ab[0].get_base_dir().get_file(), n, a.get_width() * a.get_height()])
		if n > 0:
			mask.save_png(ab[0].get_basename() + "_diff.png")
	get_tree().quit()
