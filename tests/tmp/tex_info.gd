extends SceneTree
func _init() -> void:
	for p in OS.get_environment("TEX").split(","):
		var t = load(p)
		print("%s size %s fmt %s lod_mode %s world_size %s zoom %s src %s" % [p.get_file(), t.texture_size, t.format, t.lod_mode, t.world_size, t.zoom, t.source_path])
	quit()
