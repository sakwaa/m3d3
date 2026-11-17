extends Node
func _ready() -> void:
	var zone: Node = (load("res://zones/town1/town_1_market_square.tscn") as PackedScene).instantiate()
	add_child(zone)
	await get_tree().process_frame
	await get_tree().process_frame
	var mr: MeshInstance3D = zone.get_node("Mountains")
	var kids := mr.get_children(true)
	var ridges: MeshInstance3D = kids.filter(func(k): return k is MeshInstance3D)[0]
	var c0: Color = ridges.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR][0]
	mr.set(&"foot_color", Color(1, 0, 0))
	mr.set(&"rock_color", Color(1, 0, 0))
	await get_tree().process_frame
	var c1: Color = ridges.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR][0]
	var mesh_before = ridges.mesh
	mr.set(&"blend_amount", 0.3)
	await get_tree().process_frame
	print("[mc] own mesh %s, ridges tris %d, colour before %s after %s, blend change rebuilt mesh: %s" % [mr.mesh, ridges.mesh.get_faces().size() / 3, c0, c1, ridges.mesh != mesh_before])
	get_tree().quit()
