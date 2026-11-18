class_name LocoCapstan
extends ClimbState
## Turning a Capstan, OoT rotating-statue style: hold Grab (interact) beside one of its
## spokes, facing along it the way it turns; the stick into the spoke pushes it round a step,
## away pulls it back. The actor keeps beside the spoke it holds, walking round with it as it
## turns. Hands on the spoke (ClimbRig "push" mode); the body plays Push / Pull / PushWait
## (LocoPush's clips) or leans Idle.

## Facing at most this far off the spoke's way round (cos ~50°).
const FACING := 0.65
## Gap between the capsule and the spoke.
const GAP := 0.12
const STICK := 0.5
const SETTLE := 0.2
const HAND_APART := 0.2

var capstan: Capstan
var _spoke := 0
var _dir := 1  # +1: facing the way that opens (push opens), -1 the other way
var _r := 1.5  # where along the spoke (radius from the middle)
var _push := 0
var _settle := 0.0
var _settle_from := Vector3.ZERO
var _clipped := false
var _cand: Array = []


func _init() -> void:
	super()
	grip_still = 0.0
	grip_moving = 0.0


## A capstan's spoke beside the actor, the actor facing round the way it turns: takes hold.
func try_grab() -> bool:
	read_capsule()
	var f := flat(actor.facing)
	for n in Capstan.all(actor.get_tree()):
		var c := n as Capstan
		var v := actor.global_position - c.global_position
		v.y = 0.0
		var r := v.length()
		if r < c.drum_radius + 0.2 or r > c.drum_radius + c.spoke_length + _radius + 0.5:
			continue
		if absf(actor.global_position.y - c.global_position.y) > 0.6:
			continue
		var dirs := c.spoke_dirs()
		for k in dirs.size():
			var d: Vector3 = dirs[k]
			var t := Vector3.UP.cross(d)
			var along := v.dot(d)
			var side := v.dot(t)  # (how far round from the spoke)
			if along < c.drum_radius or absf(side) > _radius + 0.6:
				continue
			var face := f.dot(t)
			if absf(face) < FACING:
				continue
			var dir := 1 if face > 0.0 else -1
			if side * dir > 0.05:
				continue  # (in front of the spoke, not behind it)
			_cand = [c, k, dir, clampf(along, c.drum_radius + 0.35, c.drum_radius + c.spoke_length - 0.15)]
			return go(name)
	return false


func enter(_previous: ActorState) -> void:
	capstan = _cand[0]
	_spoke = _cand[1]
	_dir = _cand[2]
	_r = _cand[3]
	_push = 0
	_settle = 0.0
	_settle_from = actor.global_position
	actor.velocity = Vector3.ZERO
	_set_clip()


func exit(_next: ActorState) -> void:
	capstan = null


func update(_delta: float) -> void:
	if not is_instance_valid(capstan) or not actor.intent.held(&"grab"):
		go(&"Idle")
		return
	if not is_equal_approx(capstan.angle, capstan._target) or _settle < 1.0:
		return
	var s := actor.intent.move.dot(_tangent() * _dir)
	var want := 0
	if s > STICK:
		want = 1
	elif s < -STICK:
		want = -1
	if want != _push:
		_push = want
		_set_clip()
	if want != 0 and capstan.ready_to_turn():
		capstan.push(_dir * want)


func _set_clip() -> void:
	var want: StringName = &"Push" if _push > 0 else (&"Pull" if _push < 0 else &"PushWait")
	_clipped = actor.animation_length(want) > 0.0
	if not _clipped:
		want = &"Idle"
	if animation != want:
		animation = want
		actor.play_state_animation()


func _spoke_dir() -> Vector3:
	return capstan.spoke_dirs()[_spoke]


func _tangent() -> Vector3:
	return Vector3.UP.cross(_spoke_dir())


## Where the actor stands: beside its spoke, behind it the way it pushes.
func _spot() -> Vector3:
	var p := capstan.global_position + _spoke_dir() * _r - _tangent() * _dir * (_radius + GAP)
	p.y = actor.global_position.y
	return p


func move_actor(delta: float) -> bool:
	if not is_instance_valid(capstan):
		return false
	var to := _spot()
	if _settle < 1.0:
		_settle = minf(_settle + delta / SETTLE, 1.0)
		to = _settle_from.lerp(to, smoothstep(0.0, 1.0, _settle))
	actor.global_position = to
	actor.velocity = Vector3.ZERO
	actor.facing = _tangent() * _dir
	return true


func body_lean() -> Array:
	if _clipped:
		return [0.0, 0.0, Vector3.ZERO, 0.0]
	var lean := -0.22 if _push > 0 else (0.18 if _push < 0 else -0.08)
	return [lean, 0.0, Vector3.ZERO, 0.0]


func limb_pose() -> Dictionary:
	if not is_instance_valid(capstan):
		return {}
	var d := _spoke_dir()
	var grip := capstan.global_position + d * _r + Vector3.UP * capstan.spoke_height
	var n := -_tangent() * _dir  # (the spoke's side facing the actor)
	return {mode = &"push", normal = n, targets = [grip - d * HAND_APART, grip + d * HAND_APART,
		grip - d * HAND_APART, grip + d * HAND_APART], look = grip + Vector3.UP * 0.2}
