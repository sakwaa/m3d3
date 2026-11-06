@tool
class_name CameraZone
extends Node3D
## A camera setting for part of a zone (OoT-style): while the player is inside the box
## (`size`, centred on the node; highest `priority` wins), or standing on floor faces painted
## with this zone's camera_id (Surface layer > Camera; beats any box), the player camera
## switches to `mode`, blending over `blend_time`:
##  - FOLLOW: behind the player at a set distance / pitch (dungeon camera); the mouse
##    still turns it unless `lock_turn`.
##  - FIXED: from the View camera (child "View"; select it and tick Preview in the editor
##    to see the shot), turning to keep the player in frame if `track_player`.
##  - PARALLEL: View's angle, sliding along with the player (corridors, side views).
##  - FRAME_POINT: behind the player, facing View's position, keeping both in frame (boss
##    arenas: put View at the arena centre).
## Outside every zone the free orbit camera applies.

enum Mode { FOLLOW, FIXED, PARALLEL, FRAME_POINT }

const GROUP := &"camera_zones"

@export var mode := Mode.FIXED:
	set(value):
		mode = value
		_update_gizmo()
## Metres (x, y, z) of the box that switches to this camera. Zero: only painted floors do.
@export var size := Vector3(8, 4, 8):
	set(value):
		size = value
		_update_gizmo()
## Painted floors refer to the zone by this id (1 – 255; unique in the zone, assigned
## automatically when 0).
@export_range(0, 255) var camera_id := 0
## Overlapping boxes: the highest wins.
@export var priority := 0
## Seconds to blend into this camera.
@export_range(0.0, 3.0, 0.05) var blend_time := 0.6
@export_group("Follow / Frame point")
## Metres from the player.
@export_range(1.0, 30.0, 0.1) var distance := 6.0
## Degrees looking down.
@export_range(-30.0, 80.0, 1.0) var pitch := 25.0
## FOLLOW: the mouse can't turn the camera; it swings behind the player instead.
@export var lock_turn := false
@export_group("Fixed / Parallel")
## FIXED: turn to keep the player in frame (off: exactly the View camera's angle).
@export var track_player := true
## PARALLEL: metres from the player along View's backward axis (0 = View's own distance).
@export_range(0.0, 40.0, 0.1) var parallel_distance := 0.0
@export_group("")
## Field of view (0 = keep the player camera's).
@export_range(0.0, 120.0, 1.0) var fov := 0.0

var _gizmo: MeshInstance3D


func _enter_tree() -> void:
	add_to_group(GROUP)
	if Engine.is_editor_hint():
		_ensure_view.call_deferred()
		_update_gizmo.call_deferred()


## The View camera (anchor of FIXED / PARALLEL / FRAME_POINT).
func view() -> Camera3D:
	return get_node_or_null(^"View") as Camera3D


func contains(point: Vector3) -> bool:
	if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		return false
	var p := global_transform.affine_inverse() * point
	return absf(p.x) <= size.x * 0.5 and absf(p.y) <= size.y * 0.5 and absf(p.z) <= size.z * 0.5


## Camera transform for a player at `target` (the pivot it looks at), whose camera turn
## (yaw, radians) is `yaw`.
func shot(target: Vector3, yaw: float) -> Transform3D:
	var v := view()
	var anchor := v.global_transform if v else global_transform
	match mode:
		Mode.FOLLOW:
			var b := Basis.from_euler(Vector3(-deg_to_rad(pitch), yaw, 0.0))
			return Transform3D(b, target + b.z * distance)
		Mode.FIXED:
			if track_player and anchor.origin.distance_to(target) > 0.01:
				return Transform3D(_look(target - anchor.origin), anchor.origin)
			return anchor
		Mode.PARALLEL:
			var back := anchor.basis.z.normalized()
			var d := parallel_distance if parallel_distance > 0.0 else _anchor_distance(anchor, target)
			return Transform3D(anchor.basis.orthonormalized(), target + back * d)
		Mode.FRAME_POINT:
			var away := target - anchor.origin
			away.y = 0.0
			away = away.normalized() if away.length() > 0.01 else Vector3.BACK
			var pos := target + away * distance + Vector3.UP * distance * tan(deg_to_rad(pitch))
			var look := target.lerp(anchor.origin, 0.35)
			return Transform3D(_look(look - pos), pos)
	return anchor


## A basis looking along `dir` (straight down too).
static func _look(dir: Vector3) -> Basis:
	var up := Vector3.UP if absf(dir.normalized().y) < 0.999 else Vector3.FORWARD
	return Basis.looking_at(dir, up)


## Distance from View to the player along View's look axis (PARALLEL keeps it).
func _anchor_distance(anchor: Transform3D, target: Vector3) -> float:
	return maxf((target - anchor.origin).dot(-anchor.basis.z.normalized()), 1.0)


# --- Editor -------------------------------------------------------------------------------

func _ensure_view() -> void:
	if not is_inside_tree():
		return
	if camera_id == 0:
		var used := {}
		for z in get_tree().get_nodes_in_group(GROUP):
			if z != self and z.owner == owner:
				used[z.camera_id] = true
		camera_id = 1
		while used.has(camera_id) and camera_id < 255:
			camera_id += 1
	if view() == null and owner:
		var cam := Camera3D.new()
		cam.name = "View"
		cam.position = Vector3(0, size.y * 0.5 + 3.0, size.z * 0.5 + 4.0)
		cam.rotation_degrees.x = -30.0
		add_child(cam)
		cam.owner = owner


## Editor-only box outline (orange), never saved.
func _update_gizmo() -> void:
	if Engine.is_editor_hint() and is_inside_tree():
		_gizmo = BoxGizmo.draw(self, _gizmo, size, Color(1.0, 0.6, 0.15))
