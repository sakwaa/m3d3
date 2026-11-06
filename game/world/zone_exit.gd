@tool
class_name ZoneExit
extends Area3D
## Waypoint to another zone: touching it shows the loading screen and moves the player
## to `target_spawn` in `target_zone`.

## Ignore the player for this long after arriving, so a spawn overlapping an exit
## doesn't bounce them straight back.
const ARRIVAL_GRACE_MSEC := 500

@export_file("*.tscn") var target_zone := "":
	set(value):
		target_zone = value
		update_configuration_warnings()
@export var target_spawn: StringName = &"default"
@export var size := Vector3(2, 3, 1):
	set(value):
		size = value
		_rebuild()

var _shape: CollisionShape3D
var _preview: MeshInstance3D


func _ready() -> void:
	monitorable = false
	_rebuild()
	if not Engine.is_editor_hint():
		body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	var manager := get_node_or_null(^"/root/ZoneManager")
	if manager == null or not body.is_in_group(&"player") or target_zone.is_empty():
		return
	if Time.get_ticks_msec() - manager.arrived_msec < ARRIVAL_GRACE_MSEC:
		return
	manager.travel(target_zone, target_spawn)


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
	_preview = WorldPreview.box(self, size, Color(1.0, 0.55, 0.15))


func _get_configuration_warnings() -> PackedStringArray:
	return ["Set target_zone."] if target_zone.is_empty() else []
