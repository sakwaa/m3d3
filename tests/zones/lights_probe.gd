extends Node
## StringLights nodes in a zone (ZONE, LEVEL_OVERRIDE): count, bulbs, glow, world position.


func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	if OS.get_environment("LEVEL_OVERRIDE") != "":
		var lr: Node = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
		lr.set(&"data", ResourceLoader.load(OS.get_environment("LEVEL_OVERRIDE"), "", ResourceLoader.CACHE_MODE_IGNORE))
	add_child(zone)
	for i in 5:
		await get_tree().process_frame
	var lr: LevelRoot = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	print("rope nodes: ", lr._rope_nodes.size())
	for n in zone.find_children("*", "Node3D", true, false):
		if n.get_script() == preload("res://game/world/props/string_lights.gd"):
			print("%s bulbs %d first %s glow %s mesh %s" % [n.get_path(), n.bulbs.size(), n.to_global(n.bulbs[0]) if n.bulbs.size() else null, n._glow, n._mesh.mesh != null if n._mesh else "none"])
	get_tree().quit()
