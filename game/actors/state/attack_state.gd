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
## The blade's line through the swing, in the attacker's space (x right, y up, z forward):
## the impact burst lies along it (OoT remake: vertical chop -> a pillar, side slash -> a
## streak, stab -> forward).
@export var slash_axis := Vector3.UP
## Forward burst when the active window opens (lunges; m/s, fading as `impulse` does).
@export var lunge := 0.0
## Finishers (MM): the blade's trigger starts this much longer and shrinks back to normal
## over `boost_time` seconds.
@export var trigger_boost := 1.0
@export var boost_time := 0.3
## Set by the picker for the next start: step in as the strike lands (MM's forward lunge).
var lunge_next := false
## Its distance (metres).
const STEP_LUNGE := 0.9
## Presses before the "cancel" window (during the swing itself) are dropped, not saved
## (MM: the next attack can only start in the recovery).
@export var drop_early_presses := true
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
## The strike point this swing aims at (Combat.aim_swing), or null.
var aim: StrikePoint
## The blade (base, tip: world) last frame, for sweeping it (Combat).
var last_blade: Array = []
## Targets in reach the blade hasn't touched yet (Combat.settle when the window closes).
var pending := {}
var _lunged := false
var _lunge_now := false
var _was_active := false


func enter(previous: ActorState) -> void:
	super.enter(previous)
	resolved.clear()
	pending.clear()
	_lunge_now = lunge_next
	lunge_next = false
	_was_active = false
	last_blade = []
	_lunged = false
	Combat.aim_swing(self)
	if launch != Vector2.ZERO and actor.is_on_floor():
		actor.velocity = actor.facing * launch.x + Vector3.UP * launch.y


func update(delta: float) -> void:
	if land_state != &"" and time > 0.1 and _ground_close():
		go(land_state, true)
		return
	if drop_early_presses and windows.has(&"cancel") and not in_window(&"cancel"):
		actor.intent.take(&"attack")
	super.update(delta)
	var active := in_window(&"active")
	if _was_active and not active and not pending.is_empty():
		Combat.settle(self)
	_was_active = active
	if (lunge > 0.0 or _lunge_now) and not _lunged and in_window(&"active"):
		_lunged = true
		actor.impulse = actor.facing * maxf(lunge, Actor.impulse_for(STEP_LUNGE) if _lunge_now else 0.0)


## How long the blade's trigger is now (1 = as made; finishers start longer).
func trigger_scale() -> float:
	return lerpf(trigger_boost, 1.0, clampf(time / maxf(boost_time, 0.01), 0.0, 1.0))


## Whether `target` is inside this swing's reach and arc. With strike points, measured to
## the nearest of them (a long body's head is far from its middle).
func reaches(target: Actor) -> bool:
	var points := StrikePoint.of(target)
	if not points.is_empty():
		for p in points:
			p.place()
			var tp := p.global_position - actor.global_position
			var h := Vector2(tp.x, tp.z)
			if h.length() - p.radius > reach or absf(tp.y) > 2.2:
				continue
			if h.length() < 0.01 or Vector2(actor.facing.x, actor.facing.z).dot(h.normalized()) >= cos(deg_to_rad(arc * 0.5)):
				return true
		return false
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
