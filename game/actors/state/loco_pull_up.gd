class_name LocoPullUp
extends ClimbState
## Mantling over the top of a wall or ledge onto the ground behind it, in four beats: pull
## (the chest comes up to the edge, arms bending), press (arms straighten pushing down,
## the hips come up over the edge and the body pitches forward over it), knee (the right
## leg hooks up onto the top), stand (step forward onto it and straighten). Longer the
## further it has to rise (from a hang).

## Timing (seconds for a short pull plus per metre risen, where each beat ends) and pitch:
## ClimbTuning ClimbUp.

## The actor's origin at the end.
var target := Vector3.ZERO
var _from := Vector3.ZERO
var _edge := 0.0


## Pulls up onto `spot` (ground behind a top edge).
func start(spot: Vector3) -> bool:
	target = spot
	return go(name)


func enter(_previous: ActorState) -> void:
	_from = actor.global_position
	actor.velocity = Vector3.ZERO
	length = tune.pull_up_time + tune.pull_up_per_metre * maxf(target.y - _from.y, 0.0)
	_edge = target.y


func limb_pose() -> Dictionary:
	return {mode = &"pull", normal = flat(Vector3(_from.x - target.x, 0.0, _from.z - target.z)), edge = _edge, progress = progress(),
		target = target}


## Pitches forward over the edge while pressing up and kneeing on, upright again to stand.
func body_lean() -> Array:
	var p := progress()
	var t := tune
	var over := smoothstep(t.beat_pull * 0.8, t.beat_press, p) - smoothstep(t.beat_knee, 1.0, p)
	return [-t.pull_up_pitch * over, 0.85, Vector3.ZERO, 0.12 * smoothstep(t.beat_press, t.beat_knee, p) * (1.0 - smoothstep(t.beat_knee, 1.0, p))]


func move_actor(_delta: float) -> bool:
	var p := progress()
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
	actor.velocity = Vector3.ZERO
	return true
