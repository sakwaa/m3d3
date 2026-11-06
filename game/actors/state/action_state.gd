class_name ActionState
extends ActorState
## Action machine state (ready, attacks, interactions): button presses lead to other
## states (`inputs`: action -> state). Requests made while this state can't be left
## (FINISH / WINDOW) are buffered by the machine, so pressing attack late in a swing
## chains into the next one when its "cancel" window opens.

## Driver actions -> states, e.g. {attack: "Attack2"}.
@export var inputs: Dictionary[StringName, StringName] = {}
## Held buttons -> states, e.g. {guard: "Guard"}.
@export var holds: Dictionary[StringName, StringName] = {}


func update(_delta: float) -> void:
	for action in inputs:
		if actor.intent.take(action):
			go(inputs[action])
			return
	for action in holds:
		if actor.intent.held(action):
			go(holds[action])
			return
