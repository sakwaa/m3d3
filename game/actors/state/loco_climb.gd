class_name LocoClimb
extends ClimbState
## Climbing a wall painted Climbable (vines, Surface.CLIMBABLE): the actor sticks to it and
## moves across it in 8 directions (pushing into the wall = up, so the stick works from
## any camera), wraps around outer and inner corners, onto slopes, overhangs and
## climbable ceilings, pulls itself up at the top (or hangs from a bare ledge above the
## vines) and steps off at the bottom. Only climbable faces hold it: the edge of the paint
## is the edge of the climb, and the limbs find it first (hands going up, feet going down).
## It moves in strides (see ClimbState GAITS): the body pushes off the limbs' holds rather
## than gliding. "jump" leaps (LocoLeap), "interact" or an empty grip lets go.
##
## Ground and air states grab holds through try_grab() / try_catch() (LocoGround / LocoAir
## climb_state).

## How far ahead a ground / air state looks for a wall to grab.
const REACH := 0.6
## How much higher a grab from the ground lands (a hop onto the wall).
const MOUNT_HOP := 0.5

## Wall normal (out of the wall) where the actor holds on.
var normal := Vector3.BACK
var _grab := {}
var _mount := false


## Grabs a hold ahead along `dir` (horizontal): a climbable wall; in the air also a ledge
## (LocoHang) or a climbable ceiling overhead (LocoCeiling). True if now holding on.
func try_grab(dir: Vector3, in_air := false) -> bool:
	if not can_grab():
		return false
	read_capsule()
	dir = flat(dir)
	var origin := actor.global_position
	if dir != Vector3.ZERO:
		# Feet to head: an overhang meets the head first, a wall leaning back the feet.
		for h in [_center, _center + 0.6, 0.3]:
			var hit := ray(origin + Vector3.UP * h, dir, _radius + REACH)
			if holds_wall(hit) and hit.normal.dot(dir) < -0.3 and fits(wall_origin(hit)):
				return grab_at(hit, not in_air)
	if not in_air:
		return false
	var hang := sibling(hang_state) as LocoHang
	if hang and dir != Vector3.ZERO and hang.try_hang(dir):
		return true
	var ceiling := sibling(ceiling_state) as LocoCeiling
	return ceiling != null and ceiling.try_hang()


## In the air: catches a hold in reach. Falling, any climbable wall round about (not one
## the stick pushes away from) - unless the player let go on purpose, then only where the
## stick pushes. Otherwise ahead along the stick or the facing.
func try_catch() -> bool:
	var m := flat(actor.intent.move) if actor.intent.move.length() > 0.3 else Vector3.ZERO
	var dirs: Array[Vector3] = []
	if m != Vector3.ZERO:
		dirs.append(m)
	if not actor.let_go_deliberate:
		dirs.append(actor.facing)
		if actor.velocity.y < 0.0:
			for k in 8:
				dirs.append(Vector3.FORWARD.rotated(Vector3.UP, k * PI / 4.0))
	for d in dirs:
		if m != Vector3.ZERO and d.dot(m) < -0.3:
			continue  # pushing away from it: let them fall
		if try_grab(d, true):
			return true
	return false


## Holds the wall at `hit` (a holds_wall() ray hit) from another state. `mount`: from the
## ground, hopping up onto it (hands reaching high, landing a little higher up).
func grab_at(hit: Dictionary, mount := false) -> bool:
	read_capsule()
	_grab = hit
	_mount = mount
	return go(name)


func enter(_previous: ActorState) -> void:
	read_capsule()
	actor.velocity = Vector3.ZERO
	_want = Vector2.ZERO
	_entry_move = Vector3.ZERO
	gait_kind = &""
	actor.let_go_deliberate = false
	if not _grab.is_empty():
		normal = -actor.facing  # glide in from facing the way it came
		var hit := _grab
		if _mount:
			var n: Vector3 = hit.normal
			var higher := ray(hit.position + up_of(n) * MOUNT_HOP + n * 0.3, -n, 0.6)
			if holds_wall(higher) and fits(wall_origin(higher)):
				hit = higher
		_attach(hit)
		if _mount and gliding():
			_glide_time = maxf(_glide_time, 0.3)
			_glide_bulge = normal * 0.12  # a little hop out and up
		_grab = {}


func update(_delta: float) -> void:
	if actor.intent.take(&"interact"):
		let_go(normal * 1.0, true)
		return
	if grip_out():
		let_go(normal * 1.0)
		return
	if actor.intent.take(&"jump"):
		var leap := sibling(leap_state) as LocoLeap
		if leap and leap.start(normal):
			return
	_read_stick(normal)
	retarget_stride(_want == gait_want)


func limb_pose() -> Dictionary:
	if _mount and gliding():
		return {mode = &"leap", normal = normal, dir = up_of(normal), progress = _glide_t}  # hopping on: hands up
	return gait_pose({mode = &"wall", normal = normal, moving = gait_want if gait_kind != &"" else Vector2.ZERO,
		hip_out = WALL_HIP, drop = BODY_DROP}, _dir_of(gait_want))


## Lies along the wall, hugging it; the weight shifts over the leading side each stride.
func body_lean() -> Array:
	var lean := wall_lean(normal)
	var ws := weight_shift(normal)
	lean[2] += ws[0] + hip_trail(_dir_of(gait_want))
	lean[3] = ws[1]
	if gait_kind == &"":
		var b := breathe()
		lean[2] += b[0]
		lean[3] += b[1]
	return lean


func _dir_of(w: Vector2) -> Vector3:
	return (right_of(normal) * w.x + up_of(normal) * w.y).normalized() if w != Vector2.ZERO else Vector3.ZERO


## Climb movement: the actor is placed against the wall each frame, not slid, a stride at a
## time.
func move_actor(delta: float) -> bool:
	actor.velocity = Vector3.ZERO
	if glide(delta):
		return true
	_mount = false
	var origin := actor.global_position
	var c := centre_of(origin)
	if gait_kind == &"":
		if _want == Vector2.ZERO:
			var hold := ray(c + normal * 0.3, -normal, gap(normal) + 0.6)
			if holds_wall(hold):
				_attach(hold)
			elif hold.is_empty():
				let_go()
			return true
		if not _start_stride():
			return true
	var up := gait_want.y > 0.3
	var dir := _dir_of(gait_want)
	var step := gait_step(delta, tune.climb_speed)
	if step <= 0.0:
		return true  # a limb is moving, the body waits for it
	_stride_move(c, dir, step, up)
	end_stride_if_stuck(origin, step)
	return true


## One frame of a stride: `step` metres the way of `dir` from centre `c`.
func _stride_move(c: Vector3, dir: Vector3, step: float, up: bool) -> void:
	var origin := actor.global_position
	# Reached the ground climbing down: stand.
	if gait_want.y < 0.0:
		var floor_hit := ray(origin + Vector3.UP * 0.1, Vector3.DOWN, 0.1 + step)
		if is_floor(floor_hit):
			go(land_state)
			return
	# Inner corner / ceiling ahead (going up, from as far as the head: it meets them first).
	var ahead := ray(c, dir, step + gap(normal) + (_half if up else 0.0))
	if not ahead.is_empty() and ahead.normal.dot(normal) < 0.9:
		if holds_wall(ahead):
			_attach(ahead)
		elif holds_ceiling(ahead) and not handed_back():
			var ceiling := sibling(ceiling_state) as LocoCeiling
			if ceiling and ceiling.grab_at(ahead):
				ceiling.note_entry()
		elif up:
			_try_ledge()
		return
	# Straight on across the wall.
	var c2 := c + dir * step
	var hit := ray(c2 + normal * 0.3, -normal, gap(normal) + 0.6)
	if not hit.is_empty():
		if holds_wall(hit) and not fits(wall_origin(hit)) and up:
			# Head against something: an overhang to climb onto, a climbable ceiling to hang
			# from, or a ledge to catch.
			var bump := blocker(wall_origin(hit))
			if holds_wall(bump) and bump.normal.dot(normal) < 0.95 and fits(wall_origin(bump)):
				_attach(bump)
				return
			_onto_ceiling()
			if machine.current == self:
				_try_ledge()
		elif holds_wall(hit) or (is_wall(hit) and hit.normal.dot(normal) > 0.9):
			_attach(hit)  # (bare wall under the body is fine: the stride checked the limbs)
		elif up and is_floor(hit):
			_step_onto(hit.position)  # the slope flattens out: walk on it
		elif up:
			_try_ledge()  # bare wall above the vines: a ledge in reach?
		return
	# Off the edge: wrap around the outer corner, or pull up over the top.
	var behind := c2 - normal * (gap(normal) + 0.1)
	var corner := ray(behind, -dir, gap(normal) + 0.3)
	if is_floor(corner) and up:
		_step_onto(corner.position)
	elif holds_wall(corner):
		_attach(corner)
	return


## Starts a stride the way the stick points if the limbs have somewhere to go: going up the
## hands must reach vines (or the top, then it pulls up; a ledge, then it hangs), going
## down the feet must. False = staying put (or handed over to another state).
func _start_stride() -> bool:
	var w := _want
	var c := centre_of(actor.global_position)
	var dir := _dir_of(w)
	var up := up_of(normal)
	if w.y > 0.3:
		var hp := c + up * HAND_REACH + dir * 0.1  # the next hold just above the hands
		var hit := ray(hp + normal * 0.3, -normal, gap(normal) + 0.6)
		if hit.is_empty():
			# The hands are over the top: pull up if there's ground there.
			var top := ray(hp - normal * (gap(normal) + 0.1), -up, HAND_REACH + 0.3)
			# (Only a top below the reach counts: on an overhang the probe can start inside
			# the slab and find a face of it above.)
			if is_floor(top) and top.position.y <= hp.y + 0.02:
				_step_onto(top.position)
				return false
		elif not holds_wall(hit) and hit.normal.dot(normal) > 0.9:
			if is_floor(hit):
				_step_onto(hit.position)
			else:
				_try_ledge()  # the vines end above: a ledge in reach, or stay
			return false
	elif w.y < -0.3:
		var fp := c - up * FOOT_REACH + dir * 0.1
		var hit := ray(fp + normal * 0.3, -normal, gap(normal) + 0.6)
		if not hit.is_empty() and not holds_wall(hit) and not is_floor(hit) and hit.normal.dot(normal) > 0.9:
			return false  # the vines end below the feet
	else:
		# Sideways: the leading hand and foot both need vines to reach for.
		for p in [c + up * HAND_REACH * 0.8 + dir * stride, c - up * FOOT_REACH + dir * stride]:
			var hit := ray(p + normal * 0.3, -normal, gap(normal) + 0.6)
			if not hit.is_empty() and not holds_wall(hit) and hit.normal.dot(normal) > 0.9:
				return false
	var kind := &"side" if absf(w.y) < 0.3 else (&"up" if w.y > 0.0 else &"down")
	gait_start(kind, w)
	return true


## Up over the top (or onto a slope gentle enough to walk): pull up onto the ground at
## `edge`, else hang from a ledge if there is one.
func _step_onto(edge: Vector3) -> void:
	var spot := pull_up_spot(edge, -normal)
	var pull := sibling(pull_up_state) as LocoPullUp
	if spot != Vector3.INF and pull:
		pull.start(spot)
	else:
		_try_ledge()


func _onto_ceiling() -> void:
	if handed_back():
		return
	var ceiling := sibling(ceiling_state) as LocoCeiling
	var up := ray(actor.global_position + Vector3.UP * 1.0, Vector3.UP, HANDS)
	if ceiling and holds_ceiling(up) and ceiling.grab_at(up):
		ceiling.note_entry()


## Climbing up into the end of the vines: hang from a ledge within reach above.
func _try_ledge() -> void:
	var hang := sibling(hang_state) as LocoHang
	if hang == null:
		return
	var ledge := find_ledge(actor.global_position, -normal, HANDS - 0.5, HANDS + 0.25)
	if not ledge.is_empty():
		hang.hang_at(ledge)


## Holds on at a wall hit (if the capsule fits there).
func _attach(hit: Dictionary) -> void:
	var origin := wall_origin(hit)
	if not fits(origin):
		return
	var was := normal
	normal = hit.normal
	place(origin, flat(-normal), was, normal)
