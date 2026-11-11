class_name LocoCeiling
extends ClimbState
## Hanging from a Climbable ceiling (faces within max_ceiling_tilt of flat): moves hand over hand
## in 8 directions (the stick, camera-relative), onto climbable walls it runs into, or
## round its outer edge to hang from it (LocoHang); only climbable faces hold, so the
## paint's edge stops it. "interact" or an empty grip drops.
## Caught from the air (reaching up) or climbing up a wall into it.

## Ceiling normal where the actor hangs (mostly down).
var normal := Vector3.DOWN
var _grab := {}
var _dir := Vector3.ZERO  # world, snapped to 8 directions around the facing
var _stride_dir := Vector3.ZERO  # the current stride's
var _hand := 1.0


## Catches a climbable ceiling overhead from the air. True if hanging now.
func try_hang() -> bool:
	if not can_grab():
		return false
	read_capsule()
	var hit := ray(actor.global_position + Vector3.UP * 1.0, Vector3.UP, HANDS - 1.0 + 0.35)
	if not holds_ceiling(hit) or not fits(_origin(hit)):
		return false
	return grab_at(hit)


## Hangs from the ceiling at `hit` (a holds_ceiling() ray hit) from another state.
func grab_at(hit: Dictionary) -> bool:
	read_capsule()
	if not fits(_origin(hit)):
		return false
	_grab = hit
	return go(name)


func enter(_previous: ActorState) -> void:
	read_capsule()
	actor.velocity = Vector3.ZERO
	_want = Vector2.ZERO
	_dir = Vector3.ZERO
	_entry_move = Vector3.ZERO
	gait_kind = &""
	actor.let_go_deliberate = false
	if not _grab.is_empty():
		_attach(_grab)
		_grab = {}


func update(_delta: float) -> void:
	if actor.intent.take(&"interact"):
		let_go(Vector3.ZERO, true)
		return
	if grip_out():
		let_go()
		return
	var m := flat(actor.intent.move)
	if actor.intent.move.length() < 0.3:
		_dir = Vector3.ZERO
	else:
		# 8 directions around where the actor faces.
		var a := snappedf(actor.facing.signed_angle_to(m, Vector3.UP), PI / 4.0)
		_dir = actor.facing.rotated(Vector3.UP, a).normalized()
	_want = Vector2(0.0, 1.0) if _dir != Vector3.ZERO else Vector2.ZERO  # moving (grip use)
	retarget_stride(_dir.is_equal_approx(_stride_dir))


func limb_pose() -> Dictionary:
	var moving := _stride_dir if gait_kind != &"" else Vector3.ZERO
	return gait_pose({mode = &"ceiling", normal = normal, moving = moving}, moving)


func move_actor(delta: float) -> bool:
	actor.velocity = Vector3.ZERO
	if glide(delta):
		return true
	var origin := actor.global_position
	if gait_kind == &"":
		if _dir == Vector3.ZERO:
			var hold := ray(origin + Vector3.UP * 1.0, Vector3.UP, HANDS - 1.0 + 0.35)
			if holds_ceiling(hold):
				_attach(hold)
			else:
				let_go()
			return true
		# Hand over hand: the hands take turns leading.
		_stride_dir = _dir
		_hand = -_hand
		gait_start(&"hang", Vector2(_hand, 0.0))
	var step := gait_step(delta, tune.ceiling_speed)
	if step <= 0.0:
		return true
	var dir := _stride_dir
	var was := origin
	_stride_move(origin, dir, step)
	end_stride_if_stuck(was, step)
	return true


func _stride_move(origin: Vector3, dir: Vector3, step: float) -> void:
	# A wall ahead: onto it if it's climbable (low enough to fit under the ceiling), else stop.
	var ahead := ray(origin + Vector3.UP * (HANDS - 0.5), dir, step + _radius + MARGIN)
	if not ahead.is_empty():
		var climb := sibling(climb_state) as LocoClimb
		var h := HANDS - 0.5
		while climb and holds_wall(ahead) and h > 0.3 and not handed_back():
			if fits(wall_origin(ahead)):
				if climb.grab_at(ahead):
					climb.note_entry()
				break
			h -= 0.25
			ahead = ray(origin + Vector3.UP * h, dir, step + _radius + MARGIN + 0.2)
		return
	var o2 := origin + dir * step
	var hit := ray(o2 + Vector3.UP * 1.0, Vector3.UP, HANDS - 1.0 + 0.35)
	if holds_ceiling(hit):
		_attach(hit)
	elif hit.is_empty():
		# Off the ceiling's edge: swing round onto the edge and hang from it (then pull up).
		var hang := sibling(hang_state) as LocoHang
		var outside := o2 + dir * (_radius + 0.5)
		var ledge := find_ledge(outside, -dir, HANDS, HANDS + 1.3)
		if hang and not ledge.is_empty():
			hang.hang_at(ledge)
	return


func _origin(hit: Dictionary) -> Vector3:
	return hit.position - Vector3.UP * HANDS


func _attach(hit: Dictionary) -> void:
	var origin := _origin(hit)
	if not fits(origin):
		return
	normal = hit.normal
	place(origin, actor.facing, actor.facing, actor.facing)
