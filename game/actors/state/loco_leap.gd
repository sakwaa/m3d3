class_name LocoLeap
extends ClimbState
## A leap off a climbable wall (SotC): a wind-up still holding on (the stick can still aim),
## then a jump the way the stick points, in 8 directions (up when centred). The wind-up is
## set when it starts by how far the hold it aims at is: a quick shallow crouch for a short
## hop, the full deep one for a long leap (or a free jump).
## Aim assist lands it on the furthest climbable wall or ledge within reach along that
## direction (or a little either side), where the hands catch vines going up (the feet
## going down); with none it's a free jump, and the wall can be
## caught again on the way down. Straight down jumps backwards off the wall. Costs a chunk
## of grip.

## Wind-up time, crouch and flight shape: ClimbTuning Leap.
## Furthest a leap reaches across the wall (metres).
@export var reach := 2.2
## Closest a leap lands (shorter hops just climb).
@export var min_reach := 0.8
## Grip a leap costs.
@export var grip_cost_leap := 1.5
## Free jump speed (no hold in reach).
@export var free_speed := 5.0
## Backwards jump off the wall: speed away and up.
@export var back_out := 4.0
@export var back_up := 4.5

## Wall normal leapt from.
var normal := Vector3.BACK
var _flying := false
var _t := 0.0
var _flight := 0.4
var _from := Vector3.ZERO
var _to := Vector3.ZERO
var _land_wall := {}  # the hold reached: a wall hit...
var _land_ledge := {}  # ...or a find_ledge() result
var _dir := Vector3.ZERO
var _windup := 0.3  # this leap's wind-up (seconds) and crouch depth (share of the full one)
var _depth := 1.0


## Starts a leap off the wall with normal `n` (from LocoClimb).
func start(n: Vector3) -> bool:
	normal = n
	return go(name)


func enter(_previous: ActorState) -> void:
	read_capsule()
	actor.velocity = Vector3.ZERO
	_flying = false
	_t = 0.0
	_land_wall = {}
	_land_ledge = {}
	_want = Vector2.ZERO
	# How far the leap the stick aims at now goes sets the wind-up (fixed once started).
	_read_stick(normal)
	var plan := _plan(_want)
	var k := 1.0
	if plan.has(&"to"):
		k = clampf((actor.global_position.distance_to(plan.to) - min_reach) / maxf(reach - min_reach, 0.01), 0.0, 1.0)
	_windup = lerpf(tune.windup_short, tune.windup, k)
	_depth = lerpf(tune.crouch_short, 1.0, k)


func grip_cost() -> float:
	return 0.0 if _flying else grip_still


func limb_pose() -> Dictionary:
	if _flying:
		var pose := {mode = &"leap", normal = normal, dir = _dir, progress = clampf(_t / _flight, 0.0, 1.0)}
		# What the limbs reach for as it arrives (ClimbRig blends to that state's pose).
		if not _land_ledge.is_empty():
			pose[&"catch"] = {mode = &"ledge", normal = _land_ledge.normal, edge = _land_ledge.edge.y, moving = Vector2.ZERO}
		elif not _land_wall.is_empty():
			pose[&"catch"] = {mode = &"wall", normal = _land_wall.normal, hip_out = WALL_HIP, drop = BODY_DROP}
		return pose
	return {mode = &"wall", normal = normal, crouch = _crouch(), hip_out = WALL_HIP, drop = BODY_DROP}


## Winding up: 0..1 (times this leap's depth), easing into the crouch.
func _crouch() -> float:
	var c := clampf(time / _windup, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c) * _depth


## Winding up the body sinks onto the drawn-up feet and in to the wall.
func body_lean() -> Array:
	if _flying:
		return super.body_lean()
	var lean := wall_lean(normal)
	var c := _crouch()
	lean[2] += -up_of(normal) * tune.crouch_sink * c - flat(normal) * tune.crouch_in * c
	return lean


func update(_delta: float) -> void:
	if _flying:
		return
	_read_stick(normal)
	if time >= _windup:
		_launch()


func move_actor(delta: float) -> bool:
	actor.velocity = Vector3.ZERO
	if not _flying:
		return true  # winding up, holding on
	_t += delta
	var s := clampf(_t / _flight, 0.0, 1.0)
	var e := s * s * (3.0 - 2.0 * s) * 0.4 + s * 0.6  # quick off the wall, eases in
	var bulge := sin(PI * s)
	actor.global_position = _from.lerp(_to, e) + normal * bulge * tune.arc_out + Vector3.UP * bulge * tune.arc_up
	if s >= 1.0:
		_arrive()
	return true


func _launch() -> void:
	if actor.grip:
		actor.grip.spend(grip_cost_leap)
	var want := _want if _want != Vector2.ZERO else Vector2(0.0, 1.0)  # up the wall
	if want.y < -0.9:
		# Straight down: backwards off the wall.
		actor.facing = flat(normal)
		let_go(flat(normal) * back_out + Vector3.UP * back_up, true)
		return
	var plan := _plan(want)
	if plan.has(&"to"):
		_fly(plan.to, plan.wall, plan.ledge, plan.dir)
		return
	# Nothing in reach: a free jump that way (pushed off the wall a little).
	var dir := (right_of(normal) * want.x + up_of(normal) * want.y).normalized()
	let_go(dir * free_speed + flat(normal) * 1.0)


## Where a leap the way of `want` (wall space; zero = up) lands: {to (actor origin), wall
## (a wall hit) or ledge (a find_ledge() result), dir}, the furthest hold in reach; {} for
## none (a free jump) or straight down (a jump backwards off the wall).
func _plan(want: Vector2) -> Dictionary:
	if want == Vector2.ZERO:
		want = Vector2(0.0, 1.0)
	if want.y < -0.9:
		return {}
	var up := up_of(normal)
	var right := right_of(normal)
	var c := centre_of(actor.global_position)
	for spread in [0.0, PI / 8.0, -PI / 8.0]:
		var w := want.rotated(spread)
		var dir := (right * w.x + up * w.y).normalized()
		var s := reach
		while s >= min_reach:
			var c2 := c + dir * s
			var hit := ray(c2 + normal * 0.5, -normal, gap(normal) + 1.0)
			# What catches it: the hands leaping up, the feet down, the body sideways.
			var grip_at := c2
			if w.y > 0.3:
				grip_at = c2 + up * HAND_REACH
			elif w.y < -0.3:
				grip_at = c2 - up * FOOT_REACH
			var held := hit if grip_at == c2 else ray(grip_at + normal * 0.5, -normal, gap(normal) + 1.0)
			if is_wall(hit) and holds_wall(held) and _clear(c, c2) and fits(wall_origin(hit)):
				return {to = wall_origin(hit), wall = hit, ledge = {}, dir = dir}
			if w.y > 0.3:
				var ledge := find_ledge(c2 - Vector3.UP * _center, -normal, HANDS - 0.4, HANDS + 0.4)
				if not ledge.is_empty() and fits(ledge_origin(ledge)):
					return {to = ledge_origin(ledge), wall = {}, ledge = ledge, dir = dir}
			s -= 0.2
	return {}


## Nothing solid between two capsule centres (the path of the leap).
func _clear(a: Vector3, b: Vector3) -> bool:
	var off := normal * 0.15
	return ray(a + off, (b - a).normalized(), a.distance_to(b)).is_empty()


func _fly(to: Vector3, wall: Dictionary, ledge: Dictionary, dir: Vector3) -> void:
	_flying = true
	_t = 0.0
	_from = actor.global_position
	_to = to
	_land_wall = wall
	_land_ledge = ledge
	_dir = dir
	_flight = tune.flight_time + tune.flight_per_metre * _from.distance_to(_to)


func _arrive() -> void:
	if not _land_wall.is_empty():
		var climb := sibling(climb_state) as LocoClimb
		if climb and climb.grab_at(_land_wall):
			return
	elif not _land_ledge.is_empty():
		var hang := sibling(hang_state) as LocoHang
		if hang and hang.hang_at(_land_ledge):
			return
	let_go()
