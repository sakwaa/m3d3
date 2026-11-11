extends Node
## Saves the textures listed in TEXS (comma separated res paths) as PNGs into OUT.


func _ready() -> void:
	for p in OS.get_environment("TEXS").split(","):
		var t: Texture2D = load(p)
		var img := t.get_image()
		if img.is_compressed():
			img.decompress()
		img.resize(128, 128, Image.INTERPOLATE_NEAREST)
		img.save_png(OS.get_environment("OUT") + "/" + p.get_file().get_basename() + ".png")
	get_tree().quit()
