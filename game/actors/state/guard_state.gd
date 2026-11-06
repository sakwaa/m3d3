class_name GuardState
extends ActionState
## Shield up while `hold_action` is held: blocks hits from the front (`arc`), slows the
## actor, and can attack straight out of it (`inputs`). Released -> `release_state`.

@export var hold_action: StringName = &"guard"
@export var release_state: StringName = &"Ready"
## Degrees in front that are covered.
@export var arc := 140.0


func update(delta: float) -> void:
	super.update(delta)
	if machine.current == self and not actor.intent.held(hold_action):
		go(release_state)


func covers(attacker: Actor) -> bool:
	var to := attacker.global_position - actor.global_position
	to.y = 0.0
	return to.length() < 0.01 or actor.facing.dot(to.normalized()) >= cos(deg_to_rad(arc * 0.5))
