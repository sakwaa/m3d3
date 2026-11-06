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
## Seconds off the floor before falling (walking off ledges; small bumps don't count).
@export var coyote_time := 0.12

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
	if jump_state != &"" and actor.intent.take(&"jump"):
		go(jump_state)
		return
	var m := actor.intent.move.length()
	if m < min_input:
		if idle_state != &"" and idle_state != name:
			go(idle_state)
	elif move_state != &"":
		go(move_state)
	elif faster != &"" and m > faster_above:
		go(faster)
	elif slower != &"" and m < slower_below:
		go(slower)
