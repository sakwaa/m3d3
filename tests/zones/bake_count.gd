extends Node
## Baked triangle count of a level file (LEVEL=path; a bake, not saved).
##   LEVEL=res://..._level.res godot --headless --path . tests/zones/bake_count.tscn


func _ready() -> void:
	var path := OS.get_environment("LEVEL")
	var data: LevelData = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var res := LevelBaker.bake(data, true)
	print("%s: %d baked tris" % [path.get_file(), res.stats.baked_tris])
	get_tree().quit()
