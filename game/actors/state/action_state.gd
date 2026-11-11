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
## An input mapped to PICK chooses an attack by situation (OoT): `attacks` maps situations
## to states. Situations: neutral (standing), moving, lock (locked on, stick neutral),
## lock_forward, lock_side, lock_back, air. Missing ones fall back to neutral / lock.
## Picking the attack that's playing chains into its "<name>2" (a backhand) if there is one.
const PICK := &"@attack"
@export var attacks: Dictionary[StringName, StringName] = {}


func update(_delta: float) -> void:
	for action in inputs:
		if actor.intent.take(action):
			var target: StringName = inputs[action]
			go(pick_attack() if target == PICK else target)
			return
	for action in holds:
		if actor.intent.held(action):
			go(holds[action])
			return


## The attack for the situation now (see `attacks`).
func pick_attack() -> StringName:
	var situation := &"neutral"
	var m := Vector3(actor.intent.move.x, 0.0, actor.intent.move.z)
	var locked := is_instance_valid(actor.face_target)
	if actor.has_tag(&"airborne") and attacks.has(&"air"):
		situation = &"air"
	elif locked:
		situation = &"lock"
		if m.length() > 0.3:
			var f := actor.facing.dot(m.normalized())
			situation = &"lock_forward" if f > 0.7 else (&"lock_back" if f < -0.7 else &"lock_side")
	elif m.length() > 0.3:
		situation = &"moving"
	var name: StringName = attacks.get(situation, attacks.get(&"lock" if locked else &"neutral", attacks.get(&"neutral", &"")))
	var chained := StringName(String(name) + "2")
	if machine.current and machine.current.name == name and machine.states.has(chained):
		name = chained
	return name
