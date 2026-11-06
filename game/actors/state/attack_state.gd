class_name AttackState
extends ActionState
## A strike. While its "active" window is open, Combat checks every actor of another team
## inside `reach` / `arc` in front of the attacker: a hit, a block (target guarding and
## facing it) or a clash (target mid-swing at us too). Each target is resolved once per
## swing.

@export var damage := 1
## Metres from the attacker's centre to the target's surface.
@export var reach := 1.4
## Degrees in front of the attacker.
@export var arc := 120.0
## Clashes: the heavier attack wins and staggers the other; equal ones both recoil.
@export var weight := 1
## Push given to the target on a hit.
@export var knockback := 4.0
## Forward burst when the active window opens (lunges).
@export var lunge := 0.0

## Actors this swing already resolved against.
var resolved := {}
var _lunged := false


func enter(previous: ActorState) -> void:
	super.enter(previous)
	resolved.clear()
	_lunged = false


func update(delta: float) -> void:
	super.update(delta)
	if lunge > 0.0 and not _lunged and in_window(&"active"):
		_lunged = true
		actor.impulse = actor.facing * lunge


## Whether `target` is inside this swing's reach and arc.
func reaches(target: Actor) -> bool:
	var to := target.global_position - actor.global_position
	if absf(to.y) > 1.5:
		return false
	to.y = 0.0
	var d := to.length()
	if d > reach + target.radius:
		return false
	return d < 0.01 or actor.facing.dot(to / d) >= cos(deg_to_rad(arc * 0.5))
