@tool
class_name SpawnPoint
extends Marker3D
## Where the player appears when entering a zone. The player faces this node's -Z
## (the arrow). ZoneExits target spawns by `spawn_id`.

@export var spawn_id: StringName = &"default"
## Room the player starts in (optional; falls back to the Zone's start_room).
@export var room: Room


func get_spawn_transform() -> Transform3D:
	return global_transform


func get_room() -> Room:
	return room


func _ready() -> void:
	if Engine.is_editor_hint():
		add_child(WorldPreview.arrow(Color(0.35, 1.0, 0.45), -1, Vector3(0, 0.05, 0)), false, INTERNAL_MODE_BACK)
