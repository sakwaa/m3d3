@tool
class_name NpcSpot
extends Marker3D
## A place an NPC stays on its schedule (ScheduleEntry STAY): where they stand, facing
## the marker's -Z (the blue arrow). Schedules find it by `spot_id` in its zone.

const GROUP := &"npc_spots"

@export var spot_id := &"":
	set(value):
		spot_id = value
		_update_preview()

var _label: Label3D


func _enter_tree() -> void:
	add_to_group(GROUP)
	if spot_id == &"":
		spot_id = StringName(name.to_snake_case())
	_update_preview()


## Prop brush pick box (PropSpec): a person-sized block where they stand.
func prop_bounds() -> AABB:
	return AABB(Vector3(-0.3, 0.0, -0.3), Vector3(0.6, 1.7, 0.6))


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
		_label.modulate = Color(0.6, 1.0, 0.6)
		_label.position.y = 2.0
		add_child(_label, false, INTERNAL_MODE_BACK)
		var mark := WorldPreview.box(self, Vector3(0.6, 1.7, 0.6), Color(0.4, 0.9, 0.4), -1)
		if mark:
			mark.position.y = 0.85
	_label.text = "spot: %s" % spot_id
