extends Node
## Re-bakes a level file (LEVEL) to OUT (default: over LEVEL), with the grade test's texture scales (TEXWS) and
## carpet repeat (CARPET_TILE) applied in memory (tests/zones/grade.gd).


func _ready() -> void:
	var grade := preload("res://tests/zones/grade.gd")
	grade.apply_textures()
	var data: LevelData = ResourceLoader.load(OS.get_environment("LEVEL"), "", ResourceLoader.CACHE_MODE_IGNORE)
	grade.apply_carpet(data)
	var res := LevelBaker.bake(data, true)
	data.baked_mesh = res.mesh
	data.baked_chunks = res.chunks
	data.set_baked_collision(res)
	var path := OS.get_environment("LEVEL")
	var out := OS.get_environment("OUT") if OS.get_environment("OUT") != "" else path
	var uid := ResourceLoader.get_resource_uid(path)
	var err := ResourceSaver.save(data, out, ResourceSaver.FLAG_COMPRESS)
	if out == path and uid != ResourceUID.INVALID_ID:
		ResourceSaver.set_uid(path, uid)
	print("saved %s: %s" % [out, error_string(err)])
	get_tree().quit()
