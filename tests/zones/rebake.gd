extends Node
## Re-bakes a level file as it is (LevelBaker, the editor's bake) and saves it.
##   LEVEL=res://..._level.res godot --headless --path . tests/zones/rebake.tscn   (editor closed)


func _ready() -> void:
	var path := OS.get_environment("LEVEL")
	var data: LevelData = load(path)
	var uid := ResourceLoader.get_resource_uid(path)
	var res := LevelBaker.bake(data, true)
	data.baked_mesh = res.mesh
	data.baked_chunks = res.chunks
	data.set_baked_collision(res)
	var err := ResourceSaver.save(data, path, ResourceSaver.FLAG_COMPRESS)
	if uid != ResourceUID.INVALID_ID:
		ResourceSaver.set_uid(path, uid)
	print("rebaked %s: %s, %d tris (hidden ground %d, walls %d)" % [path.get_file(), error_string(err), res.stats.baked_tris,
		res.stats.hidden_ground_faces, res.stats.hidden_wall_faces])
	get_tree().quit()
