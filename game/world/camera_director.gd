class_name CameraDirector
extends Node
## The player's camera: which shot applies and the blend between shots. In priority order:
##  1. the CameraZone whose camera_id is painted on the floor under the player (kept while
##     jumping);
##  2. the highest-priority CameraZone box containing the player's camera pivot;
##  3. the free orbit (the player's yaw / pitch / spring arm rig).
## FOLLOW zones steer the orbit rig (distance, pitch); the others place the view directly.
## The real camera (`view`) is top-level and follows the chosen shot.
##
## Movement after a camera cut: while the stick stays held, input keeps the direction it
## had before the cut (so the player doesn't suddenly turn); releasing it re-maps to the
## new view, like OoT.

## Free orbit distance multiplier while the player climbs.
const CLIMB_PULL_BACK := 1.4

var player: Actor
var yaw: Node3D
var pitch: Node3D
var arm: SpringArm3D
var orbit: Camera3D
var view: Camera3D
## The zone in charge (null = free orbit).
var active: CameraZone
## A cutscene places the view itself meanwhile (resume() blends back afterwards).
var override := false

var _floor_id := 0
var _from := Transform3D()
var _blend := 1.0
var _blend_time := 0.5
var _base_length := 5.0
var _base_pitch := 0.0
var _base_fov := 60.0
var _held_basis: Variant = null


func _init(p_player: Actor, p_yaw: Node3D, p_pitch: Node3D, p_arm: SpringArm3D, p_orbit: Camera3D, p_view: Camera3D) -> void:
	player = p_player
	yaw = p_yaw
	pitch = p_pitch
	arm = p_arm
	orbit = p_orbit
	view = p_view
	_base_length = arm.spring_length
	_base_pitch = pitch.rotation.x
	_base_fov = view.fov
	name = "CameraDirector"


func _ready() -> void:
	process_priority = 100  # after the player moved
	view.global_transform = orbit.global_transform
	_from = view.global_transform


## Free mouse turning (yaw) applies.
func allows_turn() -> bool:
	return active == null or (active.mode == CameraZone.Mode.FOLLOW and not active.lock_turn)


## Free mouse pitch applies.
func allows_pitch() -> bool:
	return active == null


## Basis movement input is relative to (only its yaw matters). `moving`: the stick is held.
func input_basis(moving: bool) -> Basis:
	var b := yaw.global_basis if active == null or active.mode == CameraZone.Mode.FOLLOW else _view_yaw_basis()
	if not moving:
		_held_basis = null
		return b
	if _held_basis == null:
		_held_basis = b
	return _held_basis


func _view_yaw_basis() -> Basis:
	var fwd := -view.global_basis.z
	fwd.y = 0.0
	if fwd.length() < 0.1:
		fwd = view.global_basis.y  # looking straight down: screen up is forward
		fwd.y = 0.0
	return Basis(Vector3.UP, atan2(-fwd.x, -fwd.z)) if fwd.length() > 0.001 else yaw.global_basis


## After a cutscene: blend from wherever the view is back to the gameplay camera.
func resume(blend := 0.6) -> void:
	override = false
	_from = view.global_transform
	_blend = 0.0
	_blend_time = blend


func _process(delta: float) -> void:
	if override:
		return
	if player.is_on_floor() and not player.has_tag(&"climbing"):
		_floor_id = Surface.camera_id(player.floor_surface)
	var zone := _pick()
	if zone != active:
		var leaving := active
		_from = view.global_transform
		_blend = 0.0
		_blend_time = zone.blend_time if zone else (leaving.blend_time if leaving else 0.5)
		active = zone
		if (zone == null or zone.mode == CameraZone.Mode.FOLLOW) and leaving and leaving.mode != CameraZone.Mode.FOLLOW:
			# Back to the orbit: start it looking the way the view did.
			yaw.global_rotation.y = _view_yaw_basis().get_euler().y
	var k := clampf(6.0 * delta, 0.0, 1.0)
	var target: Transform3D
	if active == null or active.mode == CameraZone.Mode.FOLLOW:
		var want_len := active.distance if active else _base_length
		if player.has_tag(&"climbing"):
			want_len *= CLIMB_PULL_BACK  # see more of the wall
		arm.spring_length = lerpf(arm.spring_length, want_len, k)
		if active:
			pitch.rotation.x = lerp_angle(pitch.rotation.x, -deg_to_rad(active.pitch), k)
			if active.lock_turn and Vector2(player.velocity.x, player.velocity.z).length() > 0.5:
				yaw.rotation.y = lerp_angle(yaw.rotation.y, atan2(-player.facing.x, -player.facing.z), clampf(2.5 * delta, 0.0, 1.0))
		target = orbit.global_transform
	else:
		target = active.shot(yaw.global_position, yaw.global_rotation.y)
	var want_fov := active.fov if active and active.fov > 0.0 else _base_fov
	view.fov = lerpf(view.fov, want_fov, k)
	_blend = minf(_blend + delta / maxf(_blend_time, 0.001), 1.0)
	view.global_transform = _from.interpolate_with(target, smoothstep(0.0, 1.0, _blend)) if _blend < 1.0 else target


func _pick() -> CameraZone:
	var zones := get_tree().get_nodes_in_group(CameraZone.GROUP)
	if _floor_id > 0:
		for z: CameraZone in zones:
			if z.camera_id == _floor_id:
				return z
	var best: CameraZone = null
	var at := yaw.global_position
	for z: CameraZone in zones:
		if z.contains(at) and (best == null or z.priority > best.priority):
			best = z
	return best
