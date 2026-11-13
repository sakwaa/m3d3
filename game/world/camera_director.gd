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
## Z-targeting (the player's TargetLock, outside fixed zones) takes over the view, after MM
## (references/targeting/mm_z_camera_decomp.md): a hostile lock frames player and enemy
## (Battle1), a friendly lock the player and whoever they face (KeepOn1), Z with nothing
## swings behind the player's facing and holds (Parallel1). Letting go hands back to the
## orbit from wherever the view is.
##
## Movement after a camera cut: while the stick stays held, input keeps the direction it
## had before the cut (so the player doesn't suddenly turn); releasing it re-maps to the
## new view, like OoT.

## Free orbit distance multiplier while the player climbs.
const CLIMB_PULL_BACK := 1.4

enum Z { NONE, BATTLE, FOLLOW, PARALLEL }
## MM metres per unit, frames per second.
const U := 0.04
const FPS := 20.0
## Per mode (MM camera data, in its units): look-at height over the feet, distance near /
## far, off-axis limit near / far (degrees: the target may sit this far off the line behind
## the player), eye pitch near / far and its clamp, FOV near / far.
const Z_DATA := {
	Z.BATTLE: {at = 29.4, near = 150.0, far = 250.0, off_near = 65.0, off_far = 15.0, pitch_near = -5.0, pitch_far = 20.0,
		fov_near = 55.0, fov_far = 52.0, clamp = 60.0},
	Z.FOLLOW: {at = 29.4, near = 180.0, far = 200.0, off_near = 42.0, off_far = 22.0, pitch_near = -5.0, pitch_far = 10.0,
		fov_near = 45.0, fov_far = 45.0, clamp = 70.0},
}
## Seconds: blending into a lock (7 frames), Parallel's swing behind (6 frames).
const Z_ENTRY := 0.35
const Z_SWING := 0.3

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
var _z := Z.NONE
var _z_target: Targetable
var _z_yaw := 0.0  # direction from the look-at point to the eye
var _z_pitch := 0.0
var _z_dist := 6.0
var _z_t := 1.0  # entry blend / Parallel swing, 0..1
var _z_from := Transform3D()
var _z_swing_from := 0.0


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
## Z-targeting, the player's facing (towards the target: sideways circles it, MM).
func input_basis(moving: bool) -> Basis:
	if _z != Z.NONE:
		_held_basis = null
		return Basis(Vector3.UP, atan2(-player.facing.x, -player.facing.z))
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
	if _z_update(delta):
		return
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


# --- Z-targeting ----------------------------------------------------------------------------

## A per-MM-frame rate `f` as this frame's weight.
static func _rate(f: float, delta: float) -> float:
	return 1.0 - pow(1.0 - f, delta * FPS)


func _z_mode() -> int:
	var lock: TargetLock = player.lock if "lock" in player else null
	if lock == null or (active and active.mode != CameraZone.Mode.FOLLOW) or player.has_tag(&"climbing"):
		return Z.NONE
	if lock.active():
		return Z.BATTLE if lock.hostile() else Z.FOLLOW
	if lock.parallel or lock.forced:
		return Z.PARALLEL
	return Z.NONE


## Z-targeting has the view (letterboxed).
func z_targeting() -> bool:
	return _z != Z.NONE


## Places the view while Z-targeting; false when not.
func _z_update(delta: float) -> bool:
	var mode := _z_mode()
	var lock: TargetLock = player.lock if "lock" in player else null
	var tgt: Targetable = lock.target if mode == Z.BATTLE or mode == Z.FOLLOW else null
	if mode != _z or tgt != _z_target:
		var was := _z
		_z = mode
		_z_target = tgt
		var off := view.global_position - player.global_position
		if mode == Z.NONE:
			# Back to the orbit from where the view is: the rig takes the view's yaw, pitch and
			# distance (then eases to its own), and the view blends onto it.
			yaw.global_rotation.y = _view_yaw_basis().get_euler().y
			pitch.rotation.x = clampf(-asin(clampf(off.normalized().y, -1.0, 1.0)), -1.2, 0.4)
			arm.spring_length = clampf(view.global_position.distance_to(yaw.global_position), 1.0, maxf(_z_dist, 1.0))
			_from = view.global_transform
			_blend = 0.0
			_blend_time = 0.5
			return false
		_z_from = view.global_transform
		_z_t = 0.0
		if was == Z.NONE:
			_z_dist = minf(off.length(), 300.0 * U)
			_z_pitch = asin(clampf(off.normalized().y, -1.0, 1.0))
		_z_yaw = atan2(off.x, off.z)
		_z_swing_from = _z_yaw
		if tgt:
			_z_yaw = _behind_line(tgt)  # entry: straight behind the player on the line to it
	if mode == Z.NONE:
		return false
	var p := player.global_position
	var at: Vector3
	var fov: float
	if mode == Z.PARALLEL:
		# Swing behind the facing in 6 frames (2/(t+1) of what's left each frame: an ease-out),
		# level, then hold there.
		var f: Vector3 = lock.parallel_facing if lock.parallel else player.facing
		var want := atan2(-f.x, -f.z)
		_z_t = minf(_z_t + delta / Z_SWING, 1.0)
		_z_yaw = lerp_angle(_z_swing_from, want, 1.0 - (1.0 - _z_t) * (1.0 - _z_t))
		_z_pitch = lerpf(_z_pitch, 0.0, _rate(0.2, delta))
		_z_dist = lerpf(_z_dist, 170.8 * U, _rate(0.2, delta))
		at = p + Vector3.UP * 44.0 * U
		fov = 45.0
	else:
		var d: Dictionary = Z_DATA[mode]
		var r := p.distance_to(tgt.origin())
		var reach := minf(tgt.release_range(), 800.0 * U)
		var ratio := clampf(r / maxf(reach, 0.01), 0.0, 1.0)
		at = p + Vector3.UP * float(d.at) * U
		# Leaning towards the target: most at mid range, none adjacent or at the edge (Battle1);
		# friendly, most at ~5 m (KeepOn1).
		var lean: float
		if mode == Z.BATTLE:
			lean = 0.4 * r * (1.0 - ratio)
		else:
			var ru := r / U
			lean = (0.9 * ru - 0.7 * ru * ru / 200.0 if ru <= 200.0 else 40.0) * U
		var to := tgt.global_position - at
		if to.length() > 0.01:
			at += to.normalized() * clampf(lean, 0.0, to.length())
		_z_dist = lerpf(_z_dist, lerpf(d.near, d.far, ratio) * U, _rate(0.5, delta))
		# The target stays within the off-axis limit of the line behind the player: side-on
		# up close, nearly behind at range; the further out, the faster it turns.
		var line := _behind_line(tgt)
		var limit := deg_to_rad(lerpf(d.off_near, d.off_far, ratio))
		var off_line := wrapf(_z_yaw - line, -PI, PI)
		if absf(off_line) > limit:
			var over := absf(off_line) - limit
			_z_yaw = lerp_angle(_z_yaw, line + signf(off_line) * limit, _rate(clampf(0.1 + over, 0.1, 0.6), delta))
		# Pitch: higher further off, lower for a target above.
		var up_to := rad_to_deg(atan2(to.y, maxf(Vector2(to.x, to.z).length(), 0.01)))
		var want_pitch := lerpf(d.pitch_near, d.pitch_far, ratio) - up_to * (0.5 + 0.5 * ratio)
		_z_pitch = lerpf(_z_pitch, deg_to_rad(clampf(want_pitch, -d.clamp, d.clamp)), _rate(1.0 / 9.0, delta))
		fov = lerpf(d.fov_near, d.fov_far, ratio)
		_z_t = minf(_z_t + delta / Z_ENTRY, 1.0)
	var dir := Vector3(sin(_z_yaw) * cos(_z_pitch), sin(_z_pitch), cos(_z_yaw) * cos(_z_pitch))
	var eye := at + dir * _z_dist
	var hit := _cam_ray(at, eye)
	if not hit.is_empty():
		eye = (hit.position as Vector3) - dir * 0.2  # (pulled in off a wall behind)
	var xf := Transform3D(Basis.looking_at(at - eye, Vector3.UP), eye)
	if mode != Z.PARALLEL and _z_t < 1.0:
		xf = _z_from.interpolate_with(xf, smoothstep(0.0, 1.0, _z_t))
	view.global_transform = xf
	view.fov = lerpf(view.fov, fov, _rate(0.2, delta))
	# The orbit rig turns along: movement stays relative to the view.
	yaw.global_rotation.y = _z_yaw
	return true


## The camera direction (look-at point to eye) straight behind the player on the line to `t`.
func _behind_line(t: Targetable) -> float:
	var to := t.global_position - player.global_position
	return atan2(-to.x, -to.z)


func _cam_ray(a: Vector3, b: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	var exclude: Array[RID] = []
	for n in get_tree().get_nodes_in_group(&"actors"):
		if n is CollisionObject3D:
			exclude.append((n as CollisionObject3D).get_rid())
	q.exclude = exclude
	return player.get_world_3d().direct_space_state.intersect_ray(q)
