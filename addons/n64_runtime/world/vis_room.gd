@tool
class_name VisRoom
extends Node3D
## A room of a level for drawing (OoT-style): a box (`size`, the origin at its bottom
## centre). Build & Play cuts the level's baked meshes by room and works out which meshes
## can be seen from inside each (RoomVis); in game only those are drawn while the camera is
## in it. Placed as a prop brush (PropSpec ROOM). Nothing in it resets: actors and NPCs
## carry on whatever room they're in.

@export var room_id := &"":
	set(value):
		room_id = value
		_update_preview()
@export var size := Vector3(20, 12, 20):
	set(value):
		size = value
		_update_preview()

var _label: Label3D


func _enter_tree() -> void:
	if room_id == &"":
		room_id = StringName(name.to_snake_case())
	_update_preview()


## Prop brush pick box (PropSpec): the room's box.
func prop_bounds() -> AABB:
	return AABB(Vector3(-size.x * 0.5, 0.0, -size.z * 0.5), size)


func _update_preview() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if _label == null:
		_label = Label3D.new()
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.no_depth_test = true
		_label.fixed_size = true
		_label.pixel_size = 0.0015
		_label.font_size = 24
		_label.modulate = Color(0.7, 0.8, 1.0)
		add_child(_label, false, INTERNAL_MODE_BACK)
	_label.text = "room: %s" % room_id
	_label.position.y = size.y
