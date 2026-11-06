@tool
class_name RoomPortal
extends Area3D
## Doorway trigger between two Rooms. Keep it outside the Rooms (directly under the
## Zone) so it never unloads. While the player stands in it both rooms are active;
## on leaving, the side decides the room: local -Z is room_a, local +Z (arrow) is room_b.

## Room on the local -Z side.
@export var room_a: Room:
	set(value):
		room_a = value
		update_configuration_warnings()
## Room on the local +Z side (the arrow points into it).
@export var room_b: Room:
	set(value):
		room_b = value
		update_configuration_warnings()
## Trigger box; the origin sits at the bottom centre like brushes.
@export var size := Vector3(2, 3, 1):
	set(value):
		size = value
		_rebuild()
## Keep geometry of the room across this portal loaded so it shows through the door.
@export var preload_neighbors := true

var _shape: CollisionShape3D
var _preview: MeshInstance3D


func _ready() -> void:
	monitorable = false
	_rebuild()


func room_on_side(world_position: Vector3) -> Room:
	return room_b if to_local(world_position).z >= 0.0 else room_a


func _rebuild() -> void:
	if not is_inside_tree():
		return
	if _shape == null:
		_shape = CollisionShape3D.new()
		add_child(_shape, false, INTERNAL_MODE_BACK)
	var box := BoxShape3D.new()
	box.size = size
	_shape.shape = box
	_shape.position.y = size.y * 0.5
	if _preview:
		_preview.queue_free()
	_preview = WorldPreview.box(self, size, Color(0.3, 0.6, 1.0), 1)


func _get_configuration_warnings() -> PackedStringArray:
	if room_a == null or room_b == null:
		return ["Assign room_a (-Z side) and room_b (+Z side, the arrow)."]
	return []
