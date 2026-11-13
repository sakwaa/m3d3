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
## An input mapped to PICK chooses an attack the way MM does (z_player.c func_808335F4,
## references/combat/mm_sword_attacks_decomp.md): from the stick at the moment of the press
## (pushed at least STICK_MIN, in four 90° sectors round the facing: forward, left, back,
## right; else neutral), Z-targeting or not ("lock_" situations: locked on or holding the
## facing), or in the air. `attacks` maps situations to states: neutral, forward, left,
## back, right, lock, lock_forward, lock_left, lock_back, lock_right, air; missing ones fall
## back to lock / neutral. `lunges`: situations that also step in (MM: forward, ~0.9 m).
## Combos (func_80833864): pressing into the same attack again counts up (the same cut once
## more, swung back from where the last one ended); the third in a row is its finisher
## ("<name>Fin" if there is one) and the count starts over; a different attack starts at 1.
const PICK := &"@attack"
const STICK_MIN := 0.9  # (MM: 55 of 60)
@export var attacks: Dictionary[StringName, StringName] = {}
@export var lunges: PackedStringArray = ["forward", "lock_forward"]


func enter(previous: ActorState) -> void:
	super.enter(previous)
	if not self is AttackState:
		actor.combo_attack = &""  # (back to rest: the next press starts a new chain)
		actor.combo_count = 0


func update(_delta: float) -> void:
	for action in inputs:
		if actor.intent.take(action):
			var target: StringName = inputs[action]
			if target == PICK:
				_start_picked()
			else:
				go(target)
			return
	for action in holds:
		if actor.intent.held(action):
			go(holds[action])
			return


## Picks (pick_attack), counts the chain, takes the finisher on the third, and starts it -
## again if it's the attack playing (a repeat swings back and cuts again).
func _start_picked() -> void:
	var situation := attack_situation()
	var name := _lookup(situation)
	if name == &"":
		return
	if name == actor.combo_attack and actor.combo_count < 3:
		actor.combo_count += 1
	else:
		actor.combo_count = 1
	actor.combo_attack = name
	var start := name
	if actor.combo_count >= 3 and machine.states.has(StringName(String(name) + "Fin")):
		start = StringName(String(name) + "Fin")
	var a := machine.states.get(start) as AttackState
	if a:
		a.lunge_next = lunges.has(String(situation))
	if machine.current and machine.current.name == start:
		machine.request(start, false, true)
	else:
		go(start)


## The attack for the situation now (see `attacks`).
func pick_attack() -> StringName:
	return _lookup(attack_situation())


func _lookup(situation: StringName) -> StringName:
	var locked := String(situation).begins_with("lock")
	return attacks.get(situation, attacks.get(&"lock" if locked else &"neutral", attacks.get(&"neutral", &"")))


## The situation key for the press now: air, or [lock_]neutral / forward / left / back / right.
func attack_situation() -> StringName:
	if actor.has_tag(&"airborne") and attacks.has(&"air"):
		return &"air"
	var z := actor.z_targeting()
	var m := Vector3(actor.intent.move.x, 0.0, actor.intent.move.z)
	var dir := ""
	if m.length() >= STICK_MIN:
		var f := actor.facing
		var r := f.cross(Vector3.UP).normalized()
		var a := rad_to_deg(atan2(m.dot(r), m.dot(f)))
		if absf(a) <= 45.0:
			dir = "forward"
		elif absf(a) >= 135.0:
			dir = "back"
		else:
			dir = "right" if a > 0.0 else "left"
	if z:
		return StringName("lock_" + dir) if dir != "" else &"lock"
	return StringName(dir) if dir != "" else &"neutral"
