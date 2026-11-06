@tool
class_name NpcPath
extends Path3D
## A route NPCs walk on their schedules (ScheduleEntry WALK). Draw it with the Path3D
## tools in the 3D viewport (select it, then add / move points), and "Snap to ground"
## drops every point onto the level below. Schedules find it by `path_id` in its zone.
## NPCs walk the horizontal line between points; the ground sets their height.

const GROUP := &"npc_paths"

@export var path_id := &"":
	set(value):
		path_id = value
		_update_label()
@export_tool_button("Snap to ground", "Path3D") var snap_button := snap_to_ground

var _label: Label3D


func _enter_tree() -> void:
	add_to_group(GROUP)
	if path_id == &"":
		path_id = StringName(name.to_snake_case())
	if curve == null:
		curve = Curve3D.new()
	_update_label()


func length() -> float:
	return curve.get_baked_length() if curve else 0.0


## World point `distance` metres along the path (clamped), and the direction there.
func sample(distance: float) -> Dictionary:
	var len := length()
	if len <= 0.0:
		var first := curve.get_point_position(0) if curve and curve.point_count > 0 else Vector3.ZERO
		return {position = global_transform * first, direction = -global_basis.z}
	var d := clampf(distance, 0.0, len)
	var a := curve.sample_baked(d)
	var ahead := curve.sample_baked(minf(d + 0.25, len))
	var behind := curve.sample_baked(maxf(d - 0.25, 0.0))
	var dir := global_transform.basis * ((ahead - a) if ahead.distance_to(a) > 0.01 else (a - behind))
	dir.y = 0.0
	return {position = global_transform * a, direction = dir.normalized() if dir.length() > 0.001 else -global_basis.z}


## Drops each point onto whatever is below it (editor; needs the level's collision).
func snap_to_ground() -> void:
	if curve == null or not is_inside_tree():
		return
	var space := get_world_3d().direct_space_state
	# Looked up by name: EditorInterface doesn't exist in exported games.
	var editor := Engine.get_singleton(&"EditorInterface") if Engine.is_editor_hint() else null
	var ur = editor.get_editor_undo_redo() if editor else null
	var before := curve.duplicate()
	var after: Curve3D = curve.duplicate()
	for i in after.point_count:
		var p := global_transform * after.get_point_position(i)
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 3.0, p + Vector3.DOWN * 50.0)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			after.set_point_position(i, global_transform.affine_inverse() * (hit.position + Vector3.UP * 0.05))
	if ur:
		ur.create_action("Snap NPC path to ground")
		ur.add_do_property(self, &"curve", after)
		ur.add_undo_property(self, &"curve", before)
		ur.commit_action()
	else:
		curve = after


func _update_label() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if _label == null:
		_label = Label3D.new()
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.no_depth_test = true
		_label.fixed_size = true
		_label.pixel_size = 0.0015
		_label.font_size = 24
		_label.modulate = Color(0.55, 0.8, 1.0)
		add_child(_label, false, INTERNAL_MODE_BACK)
	_label.text = "path: %s" % path_id
	_label.position = (curve.get_point_position(0) if curve and curve.point_count > 0 else Vector3.ZERO) + Vector3.UP * 1.2
