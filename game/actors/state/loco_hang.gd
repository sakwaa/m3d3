class_name LocoHang
extends ClimbState
## Hanging by the hands from a ledge: any walkable top edge with a wall under it, unless
## painted No ledge grab (vines not needed). Left / right shimmies along the edge and
## around outer and inner corners; pushing up (into the wall) or "jump" pulls up when
## there's room on top; pushing down (away) or "interact" drops; an empty grip lets go.
## Caught from the air, from the top of a vine climb, or by leaping.

## Hands this far below / above the edge still catch it from the air.
@export var catch_low := 1.2
@export var catch_high := 2.15

## Wall normal (flat, out of the wall) under the held edge.
var normal := Vector3.BACK
## Height of the held edge.
var edge_y := 0.0
var _grab := {}


## Catches a ledge ahead along `dir` from the air. True if hanging now.
func try_hang(dir: Vector3) -> bool:
	if not can_grab():
		return false
	read_capsule()
	var ledge := find_ledge(actor.global_position, dir, catch_low, catch_high)
	if ledge.is_empty() or not fits(ledge_origin(ledge)):
		return false
	return hang_at(ledge)


## Hangs from `ledge` (a find_ledge() result) from another state.
func hang_at(ledge: Dictionary) -> bool:
	read_capsule()
	if not fits(ledge_origin(ledge)):
		return false
	_grab = ledge
	return go(name)


func enter(_previous: ActorState) -> void:
	read_capsule()
	actor.velocity = Vector3.ZERO
	_want = Vector2.ZERO
	gait_kind = &""
	actor.let_go_deliberate = false
	if not _grab.is_empty():
		normal = -actor.facing  # glide in from facing the way it came
		_attach(_grab)
		_grab = {}


func update(_delta: float) -> void:
	if actor.intent.take(&"interact"):
		let_go(normal * 0.5, true)
		return
	if grip_out():
		let_go(normal * 0.5)
		return
	_read_stick(normal)
	var up := actor.intent.take(&"jump") or (_want.y > 0.5 and absf(_want.x) < 0.5 and time >= tune.hang_settle)
	if up:
		_pull_up()
		_want = Vector2.ZERO
		return
	if _want.y < -0.5 and absf(_want.x) < 0.5:
		let_go(normal * 0.5, true)
		return
	_want = Vector2(signf(_want.x), 0.0) if absf(_want.x) > 0.3 else Vector2.ZERO
	retarget_stride(signf(_want.x) == signf(gait_want.x) and _want != Vector2.ZERO)


func limb_pose() -> Dictionary:
	var moving := gait_want if gait_kind != &"" else Vector2.ZERO
	return gait_pose({mode = &"ledge", normal = normal, edge = edge_y, moving = moving, hip_out = tune.hang_hip_in, drop = 0.0},
		right_of(normal) * moving.x)


## Hangs close in against the wall (the capsule keeps the body further out than it looks)
## and swings from the hands as they move along: a pendulum when the legs hang free (a
## ledge over nothing), a smaller sway with the feet braced on a wall below.
func body_lean() -> Array:
	var o := actor.global_position
	var braced := not ray(o + Vector3.UP * 0.4, -normal, _radius + 0.5).is_empty()
	var swing := 0.0
	if gait_kind != &"":
		swing = float(gait_lead) * (tune.hang_swing_braced if braced else tune.hang_swing_free) * sin(PI * gait_phase)
	var lean := [0.0, HANDS, -normal * (_radius + MARGIN - tune.hang_hip_in) + hip_trail(right_of(normal) * gait_want.x), swing]
	if gait_kind == &"":
		var b := breathe()
		lean[2] += b[0]
		lean[3] += b[1]
	return lean


func _pull_up() -> void:
	var pull := sibling(pull_up_state) as LocoPullUp
	var edge := Vector3(actor.global_position.x, edge_y, actor.global_position.z) - normal * (_radius + MARGIN)
	var spot := pull_up_spot(edge + Vector3.UP * 0.01, -normal)
	if pull and spot != Vector3.INF:
		pull.start(spot)
		return
	# No room on top, but vines on the wall above the edge: climb on up them.
	var climb := sibling(climb_state) as LocoClimb
	var o := actor.global_position
	for h in [0.6, 0.9, 1.2]:  # high enough for the feet to clear the ledge
		var above := ray(Vector3(o.x, edge_y + h, o.z), -normal, _radius + 0.6)
		if climb and holds_wall(above) and fits(wall_origin(above)):
			climb.grab_at(above)
			return


func move_actor(delta: float) -> bool:
	actor.velocity = Vector3.ZERO
	if glide(delta):
		return true
	var origin := actor.global_position
	if gait_kind == &"":
		if _want == Vector2.ZERO:
			var hold := find_ledge(origin, -normal, HANDS - 0.3, HANDS + 0.3)
			if not hold.is_empty():
				_attach(hold)
			else:
				let_go()
			return true
		gait_start(&"hang", _want)  # lead hand reaches, the body swings after, then the other
	var dir := right_of(normal) * gait_want.x
	var step := gait_step(delta, tune.shimmy_speed)
	if step <= 0.0:
		return true
	_stride_move(origin, dir, step)
	end_stride_if_stuck(origin, step)
	return true


func _stride_move(origin: Vector3, dir: Vector3, step: float) -> void:
	# Inner corner: a wall ahead with a ledge on it at the same height.
	var ahead := ray(origin + Vector3.UP * (HANDS - 0.4), dir, step + _radius + MARGIN)
	if not ahead.is_empty():
		var turn := find_ledge(origin, -flat(ahead.normal), HANDS - 0.3, HANDS + 0.3)
		if not turn.is_empty() and turn.normal.dot(normal) < 0.9 and absf(turn.edge.y - edge_y) < 0.3:
			_attach(turn)
		return
	# Straight along the edge.
	var o2 := origin + dir * step
	var next := find_ledge(o2, -normal, HANDS - 0.3, HANDS + 0.3)
	if not next.is_empty() and absf(next.edge.y - edge_y) < 0.3:
		_attach(next)
		return
	# Off the end: around an outer corner (the side face turns towards `dir`).
	var around := o2 - normal * (_radius + 0.35) + dir * (_radius + MARGIN)
	var side := find_ledge(around, -dir, HANDS - 0.3, HANDS + 0.3)
	if not side.is_empty() and side.normal.dot(dir) > 0.7 and absf(side.edge.y - edge_y) < 0.3:
		_attach(side)
	return


func _attach(ledge: Dictionary) -> void:
	var origin := ledge_origin(ledge)
	if not fits(origin):
		return
	var was := normal
	normal = ledge.normal
	edge_y = ledge.edge.y
	place(origin, -normal, was, normal)
