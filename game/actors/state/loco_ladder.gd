class_name LocoLadder
extends ClimbState
## Climbing a Ladder prop, MM-style: stick up / down climbs one rung a step, hand over hand.
## Every limb is on a real rung (ClimbRig "ladder" mode places them where this says): the
## feet on the rung the body stands on and the one above, the hands on the rung nearest
## ClimbTuning.ladder_reach above the feet and the one over it, the high hand on the
## opposite side to the high foot. A step up moves the low hand two rungs to the top
## (reaching first), then the body rises a rung while the opposite foot steps up two (the
## other hand and foot stay put): measured from Link on the Great Bay lab ladder, a rung
## every ~0.35 s. Down runs the other way round (the foot feels for the rung first).
## Walking or falling into a ladder's face gets on; walking off a floor over a ladder's top
## gets on backwards (LocoPullUp start_down); at the top it climbs off onto the floor behind
## (LocoPullUp, the MM top-out timing); at the bottom it steps off. "interact" lets go,
## "jump" hops off backwards.

## How far in front of a ladder's face (past the body's gap) a ground / air state grabs it.
const REACH := 0.45
## Getting on from the top: how far back from the top rung the actor may stand.
const TOP_REACH := 0.9

var ladder: Ladder
var _b := 0  # rung the low foot stands on
var _high := 1  # side whose hand holds the higher rung (+1 right); its foot is the low one
var _dir := 0  # stepping: +1 up, -1 down, 0 holding still
var _t := 0.0  # 0..1 through the step
var _from: Array[Vector3] = []
var _to: Array[Vector3] = []
var _y0 := 0.0  # body height (ladder space) at the step's start and end
var _y1 := 0.0
var _limbs: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _grab_ladder: Ladder
var _grab_rung := 0
var _mounting := 0.0  # getting on: 1 -> 0
var _off := false  # stepping off at the bottom (gliding down to the floor)


func _init() -> void:
	super()
	grip_still = 0.0
	grip_moving = 0.0


# --- Getting on -------------------------------------------------------------------------

## Not just let go (ladders take no grip).
func can_grab() -> bool:
	return now() - actor.let_go_time >= regrab_delay


## Grabs a ladder whose face is just ahead along `dir` (horizontal): true if now on it.
## Also from the top (`dir` over a ladder's top from the floor behind it, not in the air).
func try_mount(dir: Vector3, in_air := false) -> bool:
	if not can_grab():
		return false
	read_capsule()
	dir = flat(dir)
	if dir == Vector3.ZERO:
		return false
	var o := actor.global_position
	for node in Ladder.all(actor.get_tree()):
		var lad := node as Ladder
		var n := lad.normal()
		var l := lad.local_of(o)
		var top := lad.rung_height(lad.rung_count() - 1)
		if absf(l.x) > lad.width * 0.5 + 0.2:
			continue
		if dir.dot(-n) > 0.6 and l.z > 0.0 and l.z < tune.ladder_gap + REACH and l.y > -0.4 and l.y < top - 0.6:
			_grab_ladder = lad
			_grab_rung = mini(lad.rung_near(l.y), _last_body_rung(lad))
			return go(name)
		if not in_air and dir.dot(n) > 0.6 and l.z < 0.0 and l.z > -TOP_REACH and absf(l.y - top) < 0.35:
			var up := sibling(pull_up_state) as LocoPullUp
			if up == null:
				return false
			var b := _last_body_rung(lad)
			_grab_ladder = lad
			_grab_rung = b
			return up.start_down(_body_at(lad, b), name, tune.ladder_on_top_time, lad)
	return false


func enter(_previous: ActorState) -> void:
	read_capsule()
	actor.velocity = Vector3.ZERO
	actor.let_go_deliberate = false
	_want = Vector2.ZERO
	_dir = 0
	_off = false
	if _grab_ladder:
		ladder = _grab_ladder
		_b = _grab_rung
		_grab_ladder = null
	_high = 1
	_limbs = _spots(_b, _high)
	var at := _body_at(ladder, _b)
	_mounting = 1.0 if actor.global_position.distance_to(at) > 0.05 else 0.0
	place(at, -ladder.normal(), -actor.facing, ladder.normal())
	if gliding():
		_glide_time = maxf(_glide_time, tune.ladder_mount_time)


# --- Climbing ---------------------------------------------------------------------------

func update(_delta: float) -> void:
	if ladder == null or not is_instance_valid(ladder):
		let_go()
		return
	if _off:
		return
	if actor.intent.take(&"interact"):
		let_go(ladder.normal() * 0.6, true)
		return
	if actor.intent.take(&"jump"):
		let_go(ladder.normal() * 3.0 + Vector3.UP * 2.0, true)
		return
	_read_stick(ladder.normal())


func move_actor(delta: float) -> bool:
	if glide(delta):
		_mounting = maxf(_mounting - delta / tune.ladder_mount_time, 0.0)
		return true
	if _off:
		go(land_state)
		return true
	_mounting = 0.0
	if _dir == 0:
		var want := signf(_want.y) if absf(_want.y) > 0.5 else 0.0
		if want > 0.0:
			if _b + 1 <= _last_body_rung(ladder):
				_start_step(1)
			elif _top_out():
				return true
		elif want < 0.0:
			if _b > 0:
				_start_step(-1)
			elif _step_off():
				return true
	if _dir != 0:
		_t = minf(_t + delta / tune.ladder_step_time, 1.0)
		var up := _dir > 0
		var hand_w := tune.ladder_up_hand if up else tune.ladder_down_hand
		var foot_w := tune.ladder_up_foot if up else tune.ladder_down_foot
		var body_w := tune.ladder_up_body if up else tune.ladder_down_body
		var n := ladder.normal()
		for i in 4:
			var w := hand_w if i <= ClimbRig.HAND_R else foot_w
			var s := clampf((_t - w.x) / maxf(w.y - w.x, 0.01), 0.0, 1.0)
			var e := tune.eased(s, tune.hand_ease if i <= ClimbRig.HAND_R else tune.foot_ease)
			_limbs[i] = _from[i].lerp(_to[i], e) + n * sin(PI * s) * tune.ladder_arc * (1.0 if _from[i] != _to[i] else 0.0)
		var k := smoothstep(body_w.x, body_w.y, _t)
		actor.global_position = _ladder_point(ladder, lerpf(_y0, _y1, k))
		if _t >= 1.0:
			_b += _dir
			_high = -_high
			_dir = 0
			_limbs = _spots(_b, _high)
	actor.facing = -ladder.normal()
	actor.velocity = Vector3.ZERO
	return true


func _start_step(dir: int) -> void:
	_dir = dir
	_t = 0.0
	_from = _limbs.duplicate()
	_to = _spots(_b + dir, -_high)
	_y0 = _body_height(ladder, _b)
	_y1 = _body_height(ladder, _b + dir)


## At the top with floor behind it: climb off (the hands to the lip, the chest over, a knee
## on, stand). False if there's nothing to climb onto.
func _top_out() -> bool:
	var top := ladder.rung_point(ladder.rung_count() - 1)
	var spot := pull_up_spot(top, -ladder.normal())
	if spot == Vector3.INF:
		return false
	var up := sibling(pull_up_state) as LocoPullUp
	return up != null and up.start(spot, tune.ladder_top_time, ladder)


## At the bottom with floor just under the feet: step down onto it.
func _step_off() -> bool:
	var hit := ray(actor.global_position + Vector3.UP * 0.3, Vector3.DOWN, 0.9)
	if not is_floor(hit):
		return false
	_off = true
	place(hit.position, actor.facing, ladder.normal(), ladder.normal())
	_glide_time = 0.2
	return true


# --- Rungs ------------------------------------------------------------------------------

## Highest rung the low foot can stand on with a rung left for each hand.
static func _last_body_rung(lad: Ladder) -> int:
	var last := lad.rung_count() - 1
	var b := last
	while b > 0 and _hand_rung(lad, b) + 1 > last:
		b -= 1
	return b


## The low hand's rung with the low foot on rung `b`.
static func _hand_rung(lad: Ladder, b: int) -> int:
	return lad.rung_near(lad.rung_height(b) + ClimbTuning.shared().ladder_reach)


## Body height (ladder space) standing on rung `b`.
static func _body_height(lad: Ladder, b: int) -> float:
	return lad.rung_height(b) + lad.rung_radius


func _ladder_point(lad: Ladder, h: float) -> Vector3:
	return lad.global_transform * Vector3(0.0, h, 0.0) + lad.normal() * tune.ladder_gap


func _body_at(lad: Ladder, b: int) -> Vector3:
	return _ladder_point(lad, _body_height(lad, b))


## Where each limb holds with the low foot on rung `b` and side `high`'s hand on the higher
## rung (world): [hand L, hand R, foot L, foot R].
func _spots(b: int, high: int) -> Array[Vector3]:
	var last := ladder.rung_count() - 1
	var h := _hand_rung(ladder, b)
	var out: Array[Vector3] = []
	for side in [-1, 1]:
		out.append(_hand_spot(mini(h + 1 if side == high else h, last), side))
	for side in [-1, 1]:
		out.append(_foot_spot(mini(b if side == high else b + 1, last), side))
	return out


## A hand round rung `k`: the wrist just under and in front of it.
func _hand_spot(k: int, side: int) -> Vector3:
	return ladder.rung_point(k) + ladder.right() * side * tune.ladder_hand_out + ladder.normal() * 0.04 - Vector3.UP * 0.05


## A foot on rung `k`: the ball of the foot on it, the ankle over and out from it.
func _foot_spot(k: int, side: int) -> Vector3:
	return ladder.rung_point(k) + ladder.right() * side * tune.ladder_foot_out + ladder.normal() * tune.toe \
		+ Vector3.UP * (ladder.rung_radius + tune.ankle_height)


func limb_pose() -> Dictionary:
	if ladder == null:
		return {}
	var n := ladder.normal()
	if _mounting > 0.0:
		# Getting on: hands up for the rungs first, then onto them (the rig blends in).
		return {mode = &"leap", normal = n, dir = Vector3.UP, progress = 1.0 - _mounting,
			catch = {mode = &"ladder", normal = n, targets = _limbs, look = _look_at()}}
	return {mode = &"ladder", normal = n, targets = _limbs, look = _look_at()}


## Eyes on the hand reaching, else up the ladder past the hands.
func _look_at() -> Vector3:
	if _dir != 0:
		for i in [ClimbRig.HAND_L, ClimbRig.HAND_R]:
			if _from[i] != _to[i]:
				return _to[i] + Vector3.UP * 0.2
	return (_limbs[0] + _limbs[1]) * 0.5 + Vector3.UP * 0.5


## Upright on the ladder; the weight rolls over to the side stepping up.
func body_lean() -> Array:
	var roll := 0.0
	if _dir != 0:
		roll = -_high * 0.06 * sin(PI * _t)
	return [0.0, _center, Vector3.ZERO, roll]
