class_name ClimbState
extends ActorState
## Shared by the climbing states (LocoClimb walls, LocoHang ledges, LocoCeiling, LocoLeap,
## LocoPullUp): probes against the level, the actor's capsule, grip use, and the names of
## the sibling states they hand over to. Walls and ceilings hold only where painted
## Climbable; ledges are any top edge with a wall under it, unless painted No ledge grab.

## Grip used per second holding still / moving (the actor's Grip; 0 = free).
@export var grip_still := 0.0
@export var grip_moving := 0.0
## Steepest overhang still climbed as a wall, degrees past vertical.
@export_range(0.0, 80.0) var max_overhang := 30.0
## Ceilings: faces tilted at most this far from flat (between this and max_overhang
## nothing can be held).
@export_range(0.0, 80.0) var max_ceiling_tilt := 30.0
@export var climb_state: StringName = &"Climb"
@export var hang_state: StringName = &"Hang"
@export var ceiling_state: StringName = &"Ceiling"
@export var leap_state: StringName = &"Leap"
@export var pull_up_state: StringName = &"ClimbUp"
@export var fall_state: StringName = &"Fall"
@export var land_state: StringName = &"Idle"
## Seconds after letting go before the actor can grab again (not straight back on).
@export var regrab_delay := 0.4

## Climbing gait. A stride moves the body `stride` metres timed with the limbs (ClimbRig
## moves them on the same schedule), so the body only travels when the limbs have holds.
## Two styles:
##   Hanging (vines, SotC; the default): the hands lead, alternating (measured from SotC at
##   60 fps, ~1 s a stride): the lead hand reaches up, the other joins it a moment later,
##   then the arms pull the body up with one knee kicking high (the other leg following,
##   long), and a short hold before the next reach with the other hand.
##   Down, the feet lower first, then the body, then the hands. Sideways and hanging from
##   ledges / ceilings, the lead hand goes, the body swings over, the trail hand follows.
##   Planted (`planted`: rock and brick, a climbing-reel style): the feet lead, the body
##   pushes up off them, then the hands.
## Windows are fractions of a stride: hands / feet [lead, trail], body [[from, to, share of
## the stride]]: one push, done before the stride ends so the body settles once (a second
## small push reads as a springy bounce).
## The hanging style's windows are in ClimbTuning (Timing up / down / side, Hang timing).
const GAITS_PLANTED := {
	&"up": {hands = [[0.42, 0.72], [0.66, 0.96]], feet = [[0.0, 0.25], [0.3, 0.55]], body = [[0.12, 0.62, 1.0]]},
	&"down": {hands = [[0.0, 0.3], [0.25, 0.55]], feet = [[0.45, 0.7], [0.7, 0.96]], body = [[0.12, 0.62, 1.0]]},
	&"side": {hands = [[0.0, 0.3], [0.62, 0.92]], feet = [[0.15, 0.4], [0.48, 0.72]], body = [[0.2, 0.75, 1.0]]},
	&"hang": {hands = [[0.0, 0.38], [0.55, 0.95]], feet = [[0.1, 0.4], [0.55, 0.85]], body = [[0.2, 0.7, 1.0]]},
}
## Planted-feet style instead of hanging (see the gaits above).
@export var planted := false

## The climbing animation's numbers (ClimbTuning: climb_tuning.tres, live-reloaded).
var tune: ClimbTuning:
	get:
		return ClimbTuning.shared()

## Metres the body moves per stride (ClimbTuning.stride). No more than a seated foot's leg
## can follow: the lead foot seats just under the hip and must still reach it once the body
## has risen.
var stride: float:
	get:
		return tune.stride

## Current stride: kind ("" = still), 0..1 through it, which side leads (+1 right), the
## direction (wall space: x right, y up).
var gait_kind := &""
var gait_phase := 0.0
var gait_lead := 1
var gait_want := Vector2.ZERO
var _strides := 0

## Hands reach this far above the body's centre, feet this far below (limb checks).
const HAND_REACH := 0.85
const FOOT_REACH := 0.75

## Gap between the capsule and what it holds.
const MARGIN := 0.04
## Where the body's centre line sits off the wall it climbs (hugging it; the knees turn out
## to the sides, see ClimbRig), and how far it hangs below the capsule's centre. The
## capsule itself stays further out.
const WALL_HIP := 0.14
const BODY_DROP := 0.05
## Planted: the torso pitches in towards the wall (radians), head between the arms.
const PITCH_IN := 0.12
## Hanging (SotC) the body hangs back from the hands instead: ClimbTuning wall_hip,
## lean_back; weight shift, hip lag and the ledge hang there too.
## Hands above the actor's origin, arms up (hanging from a ledge or ceiling).
const HANDS := 1.85
## Stick turned less than this (cos ~25°) still counts as the same direction.
const HOLD_DOT := 0.9

## Movement wanted this frame: x right, y up (wall space); zero = holding still.
var _want := Vector2.ZERO
var _want_move := Vector3.ZERO  # `move` (world) when _want was read (no-stick drivers)
var _want_stick := Vector2.ZERO  # the stick when _want was read
var _side := 1.0  # which way stick-right goes along the wall (+1: the wall's right)
var _radius := 0.35
var _half := 0.45  # half the capsule's straight part
var _center := 0.8  # capsule centre above the actor's origin
var _entry_move := Vector3.ZERO  # the stick when handed over from another hold (see handed_back)
var _glide_t := 1.0  # place() glide: 0..1, 1 = done
var _glide_time := 0.2
var _glide_from := Vector3.ZERO
var _glide_to := Vector3.ZERO
var _glide_face_from := Vector3.FORWARD
var _glide_face_to := Vector3.FORWARD
var _glide_bulge := Vector3.ZERO


func _init() -> void:
	can_turn = false


## Grip used per second right now (Grip polls it).
func grip_cost() -> float:
	return grip_moving if _want != Vector2.ZERO else grip_still


## How the body leans while holding on: [tilt (radians about its right axis, + = top
## back), pivot height above the origin, shift (world)]. Upright by default.
func body_lean() -> Array:
	return [0.0, _center, Vector3.ZERO]


## Leaning with a slanted wall (normal `n`): the body lies parallel to it, pivoting at the
## capsule's centre and shifted in to the wall's distance (the upright capsule keeps its
## end, not its middle, against the wall).
func wall_lean(n: Vector3) -> Array:
	var ny := clampf(n.y, -1.0, 1.0)
	if planted:
		return [-asin(ny) - PITCH_IN, _center, -flat(n) * (gap(n) - WALL_HIP) - up_of(n) * BODY_DROP, 0.0]
	# Hanging from the hands: the body leans back off the wall, feet nearer it than the chest.
	return [-asin(ny) + tune.lean_back, _center, -flat(n) * (gap(n) - tune.wall_hip) - up_of(n) * tune.body_drop, 0.0]


## The weight shifting over to the side that leads a stride (hips across, torso rolling
## up on that side), moving across during the push and staying there between strides.
## [shift (world), roll].
func weight_shift(n: Vector3) -> Array:
	var side := float(gait_lead)
	var w := side
	if gait_kind != &"":
		w = lerpf(-side, side, smoothstep(0.1, 0.6, gait_phase))
	var k := 1.0 if planted else 0.55  # hanging from the hands, the body shifts less
	return [right_of(n) * w * tune.shift * k, w * tune.roll * k]


## For the climb rig: what the hands and feet hold. {mode: &"wall" / &"ledge" /
## &"ceiling" / &"pull" / &"leap", normal: Vector3, edge: float (ledge height)...}.
func limb_pose() -> Dictionary:
	return {}


## Notes the stick as this state takes over from another hold (wall <-> ceiling).
func note_entry() -> void:
	_entry_move = actor.intent.move.normalized() if actor.intent.move.length() > 0.3 else Vector3.ZERO


## Whether the stick is still held the way it was at the handover: then the hold it came
## from isn't taken again (no flip-flopping between a wall and the ceiling above it).
func handed_back() -> bool:
	return _entry_move != Vector3.ZERO and actor.intent.move.length() > 0.3 \
		and actor.intent.move.normalized().dot(_entry_move) > HOLD_DOT


## Starts a stride (`kind`: up / down / side / hang) the way of `want`. Up and down
## alternate the leading side; sideways the side moved towards leads.
func gait_start(kind: StringName, want: Vector2) -> void:
	gait_kind = kind
	gait_phase = 0.0
	gait_want = want
	if kind == &"side" or kind == &"hang":
		gait_lead = 1 if want.x >= 0.0 else -1
	else:
		_strides += 1
		gait_lead = 1 if _strides % 2 == 0 else -1


func gaits() -> Dictionary:
	return GAITS_PLANTED if planted else tune.gait_table()


## How much of the stride the body has covered at `phase` (0..1). Hanging, the pull starts
## slow and quickens (an arm pull), easing to a stop.
func gait_progress(kind: StringName, phase: float) -> float:
	var p := 0.0
	for w in gaits()[kind].body:
		var e := smoothstep(w[0], w[1], phase)
		p += w[2] * (e if planted else pow(e, 1.5))
	return p


## The hips trailing the move by a few frames (they follow the hands, not with them).
func hip_trail(dir: Vector3) -> Vector3:
	if gait_kind == &"":
		return Vector3.ZERO
	var behind := gait_progress(gait_kind, gait_phase) - gait_progress(gait_kind, maxf(gait_phase - tune.hip_lag, 0.0))
	return -dir * stride * behind


## Holding still: a slow breath (rise and fall) and a slight sway. [shift (world), roll].
func breathe() -> Array:
	var t := Time.get_ticks_msec() * 0.001
	return [Vector3.UP * 0.012 * sin(t * TAU * 0.3), 0.02 * sin(t * TAU * 0.15)]


## Advances the stride at `speed` (m/s on average); returns how far the body moves this
## frame. The stride ends (gait_kind "") when done.
func gait_step(delta: float, speed: float) -> float:
	if gait_kind == &"":
		return 0.0
	var before := gait_progress(gait_kind, gait_phase)
	gait_phase = minf(gait_phase + delta * speed / stride, 1.0)
	var moved := (gait_progress(gait_kind, gait_phase) - before) * stride
	if gait_phase >= 1.0:
		gait_kind = &""
	return moved


## Drops a stride the stick no longer wants, if the body hasn't started moving yet (only the
## first limb was reaching): a change of mind isn't stuck finishing the old stride.
func retarget_stride(still_wanted: bool) -> void:
	if gait_kind != &"" and not still_wanted and gait_progress(gait_kind, gait_phase) <= 0.0:
		gait_kind = &""


## Ends the stride if it went nowhere (blocked): the next one follows the stick afresh.
func end_stride_if_stuck(was: Vector3, step: float) -> void:
	if step < 0.002:
		return  # the start of a push barely moves: not stuck
	if machine.current == self and not gliding() and actor.global_position.distance_to(was) < step * 0.25:
		gait_kind = &""


## The stride for the climb rig: where the body will be when it ends.
func gait_pose(pose: Dictionary, dir: Vector3) -> Dictionary:
	pose[&"gait"] = gait_kind
	pose[&"phase"] = gait_phase
	pose[&"lead"] = gait_lead
	pose[&"sched"] = gaits().get(gait_kind, {})
	pose[&"planted"] = planted
	var left := 1.0 - gait_progress(gait_kind, gait_phase) if gait_kind != &"" else 0.0
	pose[&"end"] = actor.global_position + dir * stride * left
	return pose


## Lets go of whatever is held and falls (pushed by `push`). `deliberate` (the player let
## go, dropped or jumped off): falling, it only grabs again where the stick pushes.
func let_go(push := Vector3.ZERO, deliberate := false) -> void:
	_glide_t = 1.0
	gait_kind = &""
	actor.velocity = push
	actor.let_go_time = now()
	actor.let_go_deliberate = deliberate
	go(fall_state)


static func now() -> float:
	return Time.get_ticks_msec() * 0.001


## Not just let go, and grip left.
func can_grab() -> bool:
	if now() - actor.let_go_time < regrab_delay:
		return false
	return actor.grip == null or actor.grip.can_grab()


func grip_out() -> bool:
	return actor.grip != null and actor.grip.is_empty()


func sibling(state: StringName) -> ActorState:
	return machine.states.get(state) if state != &"" else null


# --- Stick ----------------------------------------------------------------------------------

## Reads the stick into `_want` against a wall with normal `n`, snapped to 8 directions:
## stick up climbs up, stick left / right goes along the wall whatever the camera's angle
## (only which way is "right" follows the view, for a camera round the far side). A held
## direction keeps its meaning (around corners). Drivers without a stick (AI, scripts) use
## `move` instead: pushing into the wall = up.
func _read_stick(n: Vector3) -> void:
	var st := actor.intent.stick
	var m := actor.intent.move
	if st.length() < 0.3 and m.length() >= 0.3:
		if _want != Vector2.ZERO and m.normalized().dot(_want_move) > HOLD_DOT:
			return
		var v := Vector2(m.dot(right_of(n)), m.dot(flat(-n)))
		_set_want(v)
		_want_move = m.normalized()
		_want_stick = Vector2.ZERO
		return
	if st.length() < 0.3:
		_want = Vector2.ZERO
		return
	if _want != Vector2.ZERO and st.normalized().dot(_want_stick) > HOLD_DOT:
		return
	var side := actor.intent.view_right.dot(right_of(n))
	if absf(side) > 0.25:
		_side = signf(side)  # (near edge-on keeps the last side, no flicker)
	_set_want(Vector2(st.x * _side, st.y))
	_want_stick = st.normalized()
	_want_move = Vector3.ZERO


func _set_want(v: Vector2) -> void:
	var a := snappedf(v.angle(), PI / 4.0)
	_want = Vector2(cos(a), sin(a))


# --- Surfaces -------------------------------------------------------------------------------

func climbable(hit: Dictionary) -> bool:
	return not hit.is_empty() and Surface.has(Surface.of_ray(hit), Surface.CLIMBABLE)


## A climbable wall (steep, up to the overhang limit).
func holds_wall(hit: Dictionary) -> bool:
	if not climbable(hit):
		return false
	var ny: float = hit.normal.y
	return ny < cos(actor.floor_max_angle) and ny >= -sin(deg_to_rad(max_overhang + 0.5))  # (exactly the limit counts)


## Steep enough to climb (within the overhang limit), painted or not: the body can pass over
## bare wall while the hands and feet hold vines.
func is_wall(hit: Dictionary) -> bool:
	if hit.is_empty():
		return false
	var ny: float = hit.normal.y
	return ny < cos(actor.floor_max_angle) and ny >= -sin(deg_to_rad(max_overhang + 0.5))


## A climbable ceiling (within max_ceiling_tilt of flat).
func holds_ceiling(hit: Dictionary) -> bool:
	return climbable(hit) and hit.normal.y <= -cos(deg_to_rad(max_ceiling_tilt + 0.5))


func is_floor(hit: Dictionary) -> bool:
	return not hit.is_empty() and hit.normal.y >= cos(actor.floor_max_angle)


## A ledge in front along `dir` (horizontal) whose top is `low` .. `high` above `origin`:
## a walkable top with a steep wall under its edge, neither painted No ledge grab.
## {edge: point on the top edge, normal: the wall's (flat) normal, top: point on top} or {}.
func find_ledge(origin: Vector3, dir: Vector3, low: float, high: float) -> Dictionary:
	dir = flat(dir)
	if dir == Vector3.ZERO:
		return {}
	# From right overhead (a lip as deep as the climber's gap off the wall) out to reach.
	for d in [0.15, _radius + 0.15, _radius + 0.35, _radius + 0.6]:
		var top := ray(origin + dir * d + Vector3.UP * (high + 0.1), Vector3.DOWN, high - low + 0.1)
		if not is_floor(top) or Surface.has(Surface.of_ray(top), Surface.NO_LEDGE):
			continue
		var top_y: float = top.position.y
		# (From a little behind: the actor can stand right under a lip's face.)
		var back := Vector3(origin.x, top_y - 0.12, origin.z) - dir * 0.3
		var wall := ray(back, dir, d + 0.4)
		if wall.is_empty() or absf(wall.normal.y) > 0.5 or wall.normal.dot(dir) > -0.5:
			continue
		if Surface.has(Surface.of_ray(wall), Surface.NO_LEDGE):
			return {}
		# Open just above the edge (not a step up into more wall; a narrow lip is fine).
		var to_wall := Vector2(wall.position.x - back.x, wall.position.z - back.z).length()
		if not ray(Vector3(back.x, top_y + 0.15, back.z), dir, to_wall + 0.12).is_empty():
			continue
		var p: Vector3 = wall.position
		return {edge = Vector3(p.x, top_y, p.z), normal = flat(wall.normal), top = top.position}
	return {}


## The ground behind a top edge to stand on after pulling up (or Vector3.INF if none / no
## room): `edge` is on the edge, `into` points over the top.
func pull_up_spot(edge: Vector3, into: Vector3) -> Vector3:
	var spot := edge + flat(into) * (_radius + 0.15)
	var down := ray(spot + Vector3.UP * 1.2, Vector3.DOWN, 2.0)
	if not is_floor(down):
		return Vector3.INF
	# On a slope the capsule's round bottom would cut into it: a little above (it settles).
	var at: Vector3 = down.position + Vector3.UP * (_radius * (1.0 / down.normal.y - 1.0) + MARGIN)
	return at if fits(at) else Vector3.INF


# --- Placement ------------------------------------------------------------------------------

## Moves the actor to `origin` facing `to_facing`. Big moves (corners, a new hold) glide
## there over a moment, around the corner rather than through it; the climb states wait
## for it (glide()).
func place(origin: Vector3, to_facing: Vector3, n_from: Vector3, n_to: Vector3) -> void:
	var from := actor.global_position
	var turn := flat(n_from).angle_to(flat(n_to)) if flat(n_from) != Vector3.ZERO and flat(n_to) != Vector3.ZERO else n_from.angle_to(n_to)
	var dist := from.distance_to(origin)
	if turn < deg_to_rad(12.0) and dist < 0.15:
		_glide_t = 1.0
		actor.global_position = origin
		actor.facing = to_facing
		return
	_glide_from = from
	_glide_to = origin
	_glide_face_from = actor.facing
	_glide_face_to = to_facing
	_glide_t = 0.0
	_glide_time = clampf(0.1 + turn * 0.15 + dist * 0.15, 0.1, 0.4)
	# Outer corners: bow outwards so the body swings round the edge.
	_glide_bulge = Vector3.ZERO
	if n_from.dot(origin - from) < -0.01:
		var out := (n_from + n_to)
		if out.length() > 0.01:
			_glide_bulge = out.normalized() * gap(n_to) * (1.0 - cos(turn * 0.5)) * 1.5


## Advances a glide from place(); true while one is running (skip moving meanwhile).
func glide(delta: float) -> bool:
	if _glide_t >= 1.0:
		return false
	_glide_t = minf(_glide_t + delta / _glide_time, 1.0)
	var s := smoothstep(0.0, 1.0, _glide_t)
	actor.global_position = _glide_from.lerp(_glide_to, s) + _glide_bulge * sin(PI * s)
	var a := lerp_angle(atan2(_glide_face_from.x, _glide_face_from.z), atan2(_glide_face_to.x, _glide_face_to.z), s)
	actor.facing = Vector3(sin(a), 0.0, cos(a))
	return true


func gliding() -> bool:
	return _glide_t < 1.0


## Actor origin holding a wall at `hit`.
func wall_origin(hit: Dictionary) -> Vector3:
	var n: Vector3 = hit.normal
	return hit.position + n * gap(n) - Vector3.UP * _center


## Actor origin hanging from a ledge (find_ledge result).
func ledge_origin(ledge: Dictionary) -> Vector3:
	return ledge.edge + ledge.normal * (_radius + MARGIN) - Vector3.UP * HANDS


## Capsule centre to wall: an upright capsule on a slanted wall touches it with an end.
func gap(n: Vector3) -> float:
	return _radius + MARGIN + _half * absf(n.y)


static func flat(v: Vector3) -> Vector3:
	v.y = 0.0
	return v.normalized() if v.length() > 0.001 else Vector3.ZERO


## Right along a wall, for an actor facing into it.
static func right_of(n: Vector3) -> Vector3:
	return flat(-n).cross(Vector3.UP)


## Up along a wall (tilted with it).
static func up_of(n: Vector3) -> Vector3:
	return n.cross(right_of(n)).normalized()


func centre_of(origin: Vector3) -> Vector3:
	return origin + Vector3.UP * _center


func ray(from: Vector3, dir: Vector3, length: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * length, actor.collision_mask, [actor.get_rid()])
	return actor.get_world_3d().direct_space_state.intersect_ray(q)


## What the capsule would bump into with its origin at `origin`: a ray hit on it (from the
## capsule's centre, so Surface reads work), or {} if it fits.
func blocker(origin: Vector3) -> Dictionary:
	var shape := _capsule_node()
	if shape == null:
		return {}
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape.shape
	q.transform = Transform3D(Basis(), origin + shape.position)
	q.collision_mask = actor.collision_mask
	q.exclude = [actor.get_rid()]
	var rest := actor.get_world_3d().direct_space_state.get_rest_info(q)
	if rest.is_empty():
		return {}
	var from := origin + shape.position
	var to: Vector3 = rest.point - from
	return ray(from, to.normalized(), to.length() + 0.2) if to.length() > 0.001 else {}


## Whether the actor's capsule fits with its origin at `origin`.
func fits(origin: Vector3) -> bool:
	var shape := _capsule_node()
	if shape == null:
		return true
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape.shape
	q.transform = Transform3D(Basis(), origin + shape.position)
	q.collision_mask = actor.collision_mask
	q.exclude = [actor.get_rid()]
	return actor.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


func _capsule_node() -> CollisionShape3D:
	for child in actor.get_children():
		if child is CollisionShape3D and child.shape is CapsuleShape3D:
			return child
	return null


## Reads the actor's capsule size (call before probing).
func read_capsule() -> void:
	var node := _capsule_node()
	if node:
		var cap := node.shape as CapsuleShape3D
		_radius = cap.radius
		_half = maxf(cap.height * 0.5 - cap.radius, 0.0)
		_center = node.position.y
