extends Node
## Texture info (TEXS=res paths, comma separated): size, world size (metres per repeat), and
## the project's texel density.


func _ready() -> void:
	print("texels per metre: ", N64Texture.texels_per_metre())
	for p in OS.get_environment("TEXS").split(","):
		var t: Texture2D = load(p)
		print("%s %dx%d world_size %s" % [p.get_file(), t.get_width(), t.get_height(), t.get("world_size")])
	get_tree().quit()
