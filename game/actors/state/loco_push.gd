class_name LocoPush
extends ClimbState
## Holding a PushBlock, Ocarina of Time's way (z_player push / pull actions): hold Grab
## (interact) facing a block's face to take hold; then the stick into the block pushes it
## and away from it pulls it (if there's floor behind and nothing in the way, as OoT checks),
## a step at a time - the block sets the pace (PushBlock: OoT's step, speed-up and rest)
## and the actor keeps to its face. Letting go of Grab, or the block falling away, lets go.
## Hands are on the face (ClimbRig "push" mode). The body plays the model's PushWait /
## Push / Pull clips (references/anims/push), or leans the Idle pose when it has none.

## How far ahead of the capsule a face can be taken hold of.
const REACH := 0.35
## Facing at most this far off the face (cos 45°, OoT's grab cone).
const FACING := 0.7
## Gap kept between the capsule and the face.
const GAP := 0.03
## Hands: this far apart, this high over the feet (capped under the block's top).
const HAND_APART := 0.22
const HAND_HEIGHT := 1.1
## Stick strength towards / away from the block that moves it.
const STICK := 0.5
## Seconds to settle onto the face after taking hold.
const SETTLE := 0.15

var block: PushBlock
var _n := Vector3.BACK  # the held face's normal (world, flat; the actor stands on this side)
var _along := 0.0  # where along the face (from its middle, along right_of(_n))
var _push := 0  # +1 pushing, -1 pulling, 0 holding (this step)
var _settle := 0.0
var _settle_from := Vector3.ZERO
var _cand: PushBlock
var _cand_n := Vector3.ZERO
var _clipped := false  # playing a real push / pull clip (not the Idle fallback)


func _init() -> void:
	super()
	grip_still = 0.0
	grip_moving = 0.0


## A block's face just ahead (the way the actor faces): takes hold of it. True if now holding.
func try_grab() -> bool:
	read_capsule()
	var f := flat(actor.facing)
	var from := actor.global_position + Vector3.UP * minf(_center, 0.6)
	var hit := ray(from, f, _radius + REACH)
	if hit.is_empty():
		return false
	var b := PushBlock.of(hit.collider)
	if b == null or b.state == PushBlock.FALL:
		return false
	var n := b.face_dir(hit.normal)
	if f.dot(-n) < FACING or absf(actor.global_position.y - b.pos.y) > 0.4:
		return false
	_cand = b
	_cand_n = n
	return go(name)


func enter(_previous: ActorState) -> void:
	block = _cand
	_n = _cand_n
	var r := right_of(_n)
	var room := maxf(block.half_across(_n) - HAND_APART - 0.05, 0.0)
	_along = clampf((actor.global_position - block.pos).dot(r), -room, room)
	_push = 0
	_settle = 0.0
	_settle_from = actor.global_position
	actor.velocity = Vector3.ZERO
	_set_clip()


func exit(_next: ActorState) -> void:
	if is_instance_valid(block):
		block.show_link_ghosts(Vector3.ZERO)
	block = null


func update(_delta: float) -> void:
	if not is_instance_valid(block) or block.state == PushBlock.FALL or not actor.intent.held(&"grab"):
		go(&"Idle")
		return
	if block.state == PushBlock.PUSH or _settle < 1.0:
		block.show_link_ghosts(Vector3.ZERO)
		return  # (a step goes on as it started)
	# The stick picks: into the block pushes, away pulls (the clip keeps going through the
	# rest between steps while it's held, as OoT's does).
	var s := actor.intent.move.dot(-_n)
	var want := 0
	if s > STICK:
		want = 1
	elif s < -STICK and block.pullable and _room_behind():
		want = -1
	if want != _push:
		_push = want
		_set_clip()
	# A linked block: its mates' ghosts where they'd go (the way the stick says, else a push).
	block.show_link_ghosts(-_n * (want if want != 0 else 1))
	if want != 0 and block.ready_to_move():
		block.shove(-_n * want)


## The model's clip for holding / pushing / pulling (OoT: push_wait, pushing, pulling), if
## it has one; else Idle (leaned by body_lean).
func _set_clip() -> void:
	var want: StringName = &"Push" if _push > 0 else (&"Pull" if _push < 0 else &"PushWait")
	_clipped = actor.animation_length(want) > 0.0
	if not _clipped:
		want = &"Idle"
	if animation != want:
		animation = want
		actor.play_state_animation()


## Pulling: floor under where the actor steps back to and nothing in the way (OoT: a line
## check at 26 units up, 40 back).
func _room_behind() -> bool:
	var back := actor.global_position + _n * block.step
	if not fits(back + Vector3.UP * 0.05):
		return false
	var down := ray(back + Vector3.UP * 0.4, Vector3.DOWN, 0.8)
	return not down.is_empty() and is_floor(down)


## Where the actor stands holding the face.
func _spot() -> Vector3:
	var p := block.pos + _n * (block.half_along(_n) + _radius + GAP) + right_of(_n) * _along
	p.y = actor.global_position.y
	return p


func move_actor(delta: float) -> bool:
	if not is_instance_valid(block):
		return false
	var to := _spot()
	if _settle < 1.0:
		_settle = minf(_settle + delta / SETTLE, 1.0)
		to = _settle_from.lerp(to, smoothstep(0.0, 1.0, _settle))
	actor.global_position = to
	actor.velocity = Vector3.ZERO
	actor.facing = -_n
	return true


## Into the push (the hands out front, leaning from the feet), back off a pull.
func body_lean() -> Array:
	if _clipped:
		return [0.0, 0.0, Vector3.ZERO, 0.0]  # (the clip leans)
	var lean := -0.22 if _push > 0 else (0.18 if _push < 0 else -0.08)
	return [lean, 0.0, Vector3.ZERO, 0.0]


func limb_pose() -> Dictionary:
	if not is_instance_valid(block):
		return {}
	var r := right_of(_n)
	var face := block.pos + _n * (block.half_along(_n) + 0.02) + r * _along
	var y := minf(actor.global_position.y + HAND_HEIGHT, block.pos.y + block.size.y - 0.08)
	face.y = y
	var hl := face - r * HAND_APART
	var hr := face + r * HAND_APART
	return {mode = &"push", normal = _n, targets = [hl, hr, hl, hr], look = face + Vector3.UP * 0.2}
