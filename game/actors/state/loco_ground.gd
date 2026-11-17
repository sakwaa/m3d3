class_name LocoGround
extends ActorState
## Locomotion on the ground (idle, walk, run): picks the next ground state from the
## movement input's strength, jumps on "jump", falls when the floor drops away.
## Separate up / down thresholds (`faster_above` > `slower_below`) stop an input held near
## the boundary from flickering between walk and run.

## Below this input strength: go to `idle_state` (empty = this is idle).
@export var min_input := 0.1
@export var idle_state: StringName = &"Idle"
## From idle: the state to start moving in.
@export var move_state: StringName
@export var faster: StringName
@export_range(0.0, 1.0) var faster_above := 0.7
@export var slower: StringName
@export_range(0.0, 1.0) var slower_below := 0.6
@export var jump_state: StringName = &"Jump"
@export var fall_state: StringName = &"Fall"
## Walking into a climbable wall grabs it (a LocoClimb state; empty = can't climb).
@export var climb_state: StringName
## Holding Grab facing a PushBlock's face takes hold of it (a LocoPush state; empty = can't).
@export var push_state: StringName
## Seconds off the floor before falling (walking off ledges; small bumps don't count).
@export var coyote_time := 0.12
@export_group("Z-targeting")
## While Z-targeting (Actor.z_targeting): standing is `z_stance` (battle-ready), moving left /
## right / back relative to the facing are the strafes, forward is `z_forward` (walking at
## the target as usual). Empty = no change.
@export var z_stance: StringName
@export var z_left: StringName
@export var z_right: StringName
@export var z_back: StringName
@export var z_forward: StringName
## One of those: without Z-targeting it hands back to `idle_state` / `z_forward`.
@export var z_only := false
@export_group("")

var _air := 0.0


func enter(_previous: ActorState) -> void:
	_air = 0.0


func update(delta: float) -> void:
	if not actor.is_on_floor():
		_air += delta
		if _air > coyote_time and fall_state != &"":
			go(fall_state)
			return
	else:
		_air = 0.0
	if push_state != &"" and actor.intent.held(&"grab"):
		var push := machine.states.get(push_state) as LocoPush
		if push and push.try_grab():
			return
	if climb_state != &"" and actor.intent.move.length() > 0.3:
		var climb := machine.states.get(climb_state) as LocoClimb
		if climb and climb.try_grab(actor.intent.move):
			return
	if jump_state != &"" and actor.intent.take(&"jump"):
		go(jump_state)
		return
	var m := actor.intent.move.length()
	if z_stance != &"" and actor.z_targeting():
		var want := _z_state(m)
		if want != &"" and want != name:
			go(want)
			return
		if want != &"" or z_only:
			return
	elif z_only:
		go(idle_state if m < min_input else z_forward)
		return
	if m < min_input:
		if idle_state != &"" and idle_state != name:
			go(idle_state)
	elif move_state != &"":
		go(move_state)
	elif faster != &"" and m > faster_above:
		go(faster)
	elif slower != &"" and m < slower_below:
		go(slower)


## The Z-targeting state for input strength `m`: the stance, a strafe by the stick's side of
## the facing, or z_forward ahead (empty: as usual).
func _z_state(m: float) -> StringName:
	if m < min_input:
		return z_stance
	var mv := Vector3(actor.intent.move.x, 0.0, actor.intent.move.z)
	var f := actor.facing
	var a := rad_to_deg(atan2(mv.dot(f.cross(Vector3.UP).normalized()), mv.dot(f)))
	if absf(a) <= 45.0:
		return z_forward if z_only else &""
	if absf(a) >= 135.0:
		return z_back
	return z_right if a > 0.0 else z_left
