extends Node
## Grass wading check: the player in a zone's carpet; prints the carpet top under them and
## the GrassWake's state.  ZONE=res://... AT=x,z godot --headless --path . tests/trees/wake_check.tscn


func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(zone)
	var at := OS.get_environment("AT").split(",")
	var player: Node3D = (load("res://player/player.tscn") as PackedScene).instantiate()
	player.set(&"scripted", true)
	add_child(player)
	player.global_position = Vector3(float(at[0]), 0.0, float(at[1]))
	for i in 60:
		await get_tree().process_frame
	var wake := player.get_node_or_null("GrassWake")
	print("fields: %d, top under player: %.3f, player y %.3f" % [GrassField._fields.size(), GrassField.top_at(player.global_position + Vector3.UP * 0.05), player.global_position.y])
	if wake:
		print("wake visible %s at %s, amount %.2f" % [wake.visible, wake.global_position, wake.get(&"_amount")])
	else:
		print("no GrassWake on the player")
	get_tree().quit()
