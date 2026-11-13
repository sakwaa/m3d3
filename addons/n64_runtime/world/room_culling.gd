class_name RoomCulling
extends Node3D
## Draws a level's baked meshes by room (OoT-style): each mesh the build split by room
## carries the rooms it can be seen from (meta "seen_from", RoomVis); while the camera is in
## a room only those show. A camera outside every room, and meshes without the meta, draw
## as usual. Rooms are boxes in the parent's (the level's) space. Only drawing changes:
## nothing is freed, nothing stops (NPCs keep to their schedules in any room).

const META := &"seen_from"

## [{id: StringName, xf: Transform3D (bottom centre), size: Vector3}, ...]
@export var rooms: Array = []

var _meshes: Array = []  # [[MeshInstance3D, PackedStringArray], ...]
var _inv: Array[Transform3D] = []
var _room := &"-"


func _ready() -> void:
	for r in rooms:
		_inv.append((r.xf as Transform3D).affine_inverse())
	var level := get_parent()
	if level == null:
		return
	for c in level.get_children(true):
		if c is MeshInstance3D and (c as MeshInstance3D).mesh and (c as MeshInstance3D).mesh.has_meta(META):
			_meshes.append([c, (c as MeshInstance3D).mesh.get_meta(META)])


## The room the camera is in (empty: none).
func current_room() -> StringName:
	return _room if _room != &"-" else &""


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _meshes.is_empty():
		return
	var level := get_parent() as Node3D
	var p := level.global_transform.affine_inverse() * cam.global_position if level else cam.global_position
	var id := &""
	for i in rooms.size():
		var l := _inv[i] * p
		var s: Vector3 = rooms[i].size
		if absf(l.x) <= s.x * 0.5 and absf(l.z) <= s.z * 0.5 and l.y >= -0.5 and l.y <= s.y:
			id = rooms[i].id
			break
	if id == _room:
		return
	_room = id
	for e in _meshes:
		(e[0] as MeshInstance3D).visible = id == &"" or (e[1] as PackedStringArray).has(String(id))
