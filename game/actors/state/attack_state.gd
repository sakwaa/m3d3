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
## Leaps on starting, if on the ground: speed forward and up (jump slash).
@export var launch := Vector2.ZERO
## Airborne attack (jump slash, OoT): its animation holds its last pose for as long as the
## actor is in the air, then `land_state` (the strike and landing) takes over when the
## ground is `land_lead` seconds away at the current fall speed, so the blow lands on
## contact whatever the height.
@export var land_state: StringName
@export var land_lead := 0.17  # (~0.13 s actual: the fall keeps speeding up)

## Actors this swing already resolved against.
var resolved := {}
var _lunged := false


func enter(previous: ActorState) -> void:
	super.enter(previous)
	resolved.clear()
	_lunged = false
	if launch != Vector2.ZERO and actor.is_on_floor():
		actor.velocity = actor.facing * launch.x + Vector3.UP * launch.y


func update(delta: float) -> void:
	if land_state != &"" and time > 0.1 and _ground_close():
		go(land_state, true)
		return
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


func _ground_close() -> bool:
	if actor.is_on_floor():
		return true
	if actor.velocity.y >= 0.0:
		return false
	var from := actor.global_position + Vector3.UP * 0.1
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * (0.1 - actor.velocity.y * land_lead), actor.collision_mask, [actor.get_rid()])
	return not actor.get_world_3d().direct_space_state.intersect_ray(q).is_empty()
