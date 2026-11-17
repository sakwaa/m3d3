extends Node
func _ready() -> void:
	var zone: Node = (load("res://zones/town1/town_1_market_square.tscn") as PackedScene).instantiate()
	add_child(zone)
	await get_tree().process_frame
	for n in get_tree().root.find_children("*", "", true, false):
		if n is DarknessVolume or (n.get_script() and String(n.get_script().resource_path).ends_with("passage.gd")):
			print("[pf] ", n.get_class(), " ", n.name, " at ", (n as Node3D).global_position, " fwd ", -(n as Node3D).global_basis.z)
	get_tree().quit()
