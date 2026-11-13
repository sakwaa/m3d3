class_name LocoPullUp
extends ClimbState
## Mantling over the top of a wall or ledge onto the ground behind it, in four beats: pull
## (the chest comes up to the edge, arms bending), press (arms straighten pushing down,
## the hips come up over the edge and the body pitches forward over it), knee (the right
## leg hooks up onto the top), stand (step forward onto it and straighten). Longer the
## further it has to rise (from a hang). Off a ladder's top the feet climb its rungs while
## the body rises (ClimbRig); start_down() plays it backwards to get onto a ladder from the
## floor behind its top.

## Timing (seconds for a short pull plus per metre risen, where each beat ends) and pitch:
## ClimbTuning ClimbUp.

## The actor's origin at the end.
var target := Vector3.ZERO
var _from := Vector3.ZERO
var _edge := 0.0
var _time := 0.0  # fixed length (0 = from the rise)
var _ladder: Ladder
var _reverse := false
var _then: StringName = &""
var _down_to := Vector3.ZERO
var _face0 := Vector3.FORWARD  # getting down: facing at the start (turns round to the ladder)


## Pulls up onto `spot` (ground behind a top edge), over `time` seconds (0 = from the
## rise), off `ladder` if climbing one.
func start(spot: Vector3, time := 0.0, ladder: Ladder = null) -> bool:
	target = spot
	_time = time
	_ladder = ladder
	_reverse = false
	return go(name)


## Backwards: from standing on the top down over the edge to `hang` (holding `ladder`'s top
## rungs), over `time` seconds, then state `then`.
func start_down(hang: Vector3, then: StringName, time: float, ladder: Ladder) -> bool:
	target = actor.global_position
	_down_to = hang
	_face0 = actor.facing
	_then = then
	_time = time
	_ladder = ladder
	_reverse = true
	return go(name)


func enter(_previous: ActorState) -> void:
	_from = _down_to if _reverse else actor.global_position
	actor.velocity = Vector3.ZERO
	length = _time if _time > 0.0 else tune.pull_up_time + tune.pull_up_per_metre * maxf(target.y - _from.y, 0.0)
	_edge = target.y


func update(_delta: float) -> void:
	if _reverse and finished():
		go(_then, true)


## 0..1 through the mantle (backwards when getting down).
func _p() -> float:
	return 1.0 - progress() if _reverse else progress()


func limb_pose() -> Dictionary:
	var pose := {mode = &"pull", normal = flat(Vector3(_from.x - target.x, 0.0, _from.z - target.z)), edge = _edge, progress = _p(),
		target = target, from = _from}
	if _ladder:
		pose[&"ladder"] = _ladder
	return pose


## Pitches forward over the edge while pressing up and kneeing on, upright again to stand.
func body_lean() -> Array:
	var p := _p()
	var t := tune
	var over := smoothstep(t.beat_pull * 0.8, t.beat_press, p) - smoothstep(t.beat_knee, 1.0, p)
	return [-t.pull_up_pitch * over, 0.85, Vector3.ZERO, 0.12 * smoothstep(t.beat_press, t.beat_knee, p) * (1.0 - smoothstep(t.beat_knee, 1.0, p))]


func move_actor(_delta: float) -> bool:
	var p := _p()
	var t := tune
	var pull := t.beat_pull
	var press := t.beat_press
	var knee := t.beat_knee
	# Height: chest to the edge, hips over it, up on top.
	var chest := maxf(_from.y, _edge - 1.3)
	var hips := maxf(chest, _edge - 0.35)
	var y: float
	if p < pull:
		y = lerpf(_from.y, chest, smoothstep(0.0, pull, p))
	elif p < press:
		y = lerpf(chest, hips, smoothstep(pull, press, p))
	else:
		y = lerpf(hips, target.y, smoothstep(press, knee, p))
	# Across: nothing until the press is done, most of the way while kneeing on, then the rest.
	var across := 0.6 * smoothstep(press - 0.05, knee, p) + 0.4 * smoothstep(knee, 1.0, p)
	var flat_pos := Vector3(_from.x, 0.0, _from.z).lerp(Vector3(target.x, 0.0, target.z), across)
	actor.global_position = Vector3(flat_pos.x, y, flat_pos.z)
	if _reverse:
		# Turning round to face the ladder before stepping back over the edge.
		var to := flat(target - _from)
		var a := lerp_angle(atan2(_face0.x, _face0.z), atan2(to.x, to.z), smoothstep(0.0, 0.3, progress()))
		actor.facing = Vector3(sin(a), 0.0, cos(a))
	actor.velocity = Vector3.ZERO
	return true
