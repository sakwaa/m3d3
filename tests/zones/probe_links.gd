extends Node
## Prints a level's passages (spawn id, target) and its neighbour backdrop.
##   LEVEL=res://..._level.res godot --headless --path . tests/zones/probe_links.tscn


func _ready() -> void:
	var d: LevelData = load(OS.get_environment("LEVEL"))
	for b in d.brushes:
		if b and b.is_passage():
			print("passage %s at %s -> %s @ %s" % [b.passage.spawn_id, b.transform.origin, b.passage.target_zone, b.passage.target_spawn])
	print("backdrop mesh: %s  ring: %s  info: %s" % [d.backdrop_mesh, d.backdrop_ring, d.backdrop_ring_info])
	if d.backdrop_mesh:
		print("backdrop aabb: ", d.backdrop_mesh.get_aabb(), " surfaces ", d.backdrop_mesh.get_surface_count())
	get_tree().quit()
