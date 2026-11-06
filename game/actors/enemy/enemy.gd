class_name Enemy
extends Actor
## Base for enemies: senses, condition (health bands), and machines built by the type.
## Machines tick in order: Brain (decides, fills `intent` like a controller would),
## Locomotion, Action (the body), Condition.
##
## A type extends this, overrides build() to make its body and machines, and writes its
## own brain states (BrainState) — behaviour is per enemy; the helpers here (senses,
## moving, circling) are shared.

const BRAIN := &"Brain"
const CONDITION := &"Condition"

@export var profile: EnemyProfile

## The actor being fought / watched (the player for now).
var target: Actor
var last_seen := Vector3.ZERO
## Seconds since the target was last seen or heard (INF = never).
var since_seen := INF
## Seconds since last hit.
var since_hit := INF
var home := Vector3.ZERO
var targetable: Targetable


func _ready() -> void:
	if profile == null:
		profile = EnemyProfile.new()
	max_health = profile.max_health
	team = 1
	home = global_position
	build()
	targetable = Targetable.new()
	targetable.kind = Targetable.Kind.ENEMY
	targetable.position.y = 1.0
	add_child(targetable)
	super._ready()
	died.connect(_on_died)
	damaged.connect(_on_damaged)


## Override: body visuals / collision and the machines (Brain first).
func build() -> void:
	pass


func drive(delta: float) -> void:
	target = get_tree().get_first_node_in_group(&"player") as Actor
	since_hit += delta
	since_seen += delta
	if target and not target.is_dead() and (can_see(target) or can_hear(target)):
		last_seen = target.global_position
		since_seen = 0.0


func can_see(t: Actor) -> bool:
	var to := t.global_position - global_position
	to.y = 0.0
	var d := to.length()
	if d > profile.sight_range:
		return false
	# Once fighting it keeps track all around; otherwise only in front.
	var alert := since_seen < profile.memory
	if not alert and d > 0.01 and rad_to_deg(facing.angle_to(to / d)) > profile.sight_angle * 0.5:
		return false
	var q := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 1.0, t.global_position + Vector3.UP * 1.0)
	q.exclude = [get_rid(), t.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func can_hear(t: Actor) -> bool:
	var v := Vector2(t.velocity.x, t.velocity.z).length()
	return v > 3.5 and global_position.distance_to(t.global_position) <= profile.hear_range


func sees_target() -> bool:
	return since_seen == 0.0


func distance_to_target() -> float:
	if target == null:
		return INF
	return Vector2(target.global_position.x - global_position.x, target.global_position.z - global_position.z).length()


## Healthy / Wounded / Critical as 0 / 1 / 2.
func condition_index() -> int:
	var c := state_of(CONDITION)
	match c.name if c else &"Healthy":
		&"Wounded":
			return 1
		&"Critical":
			return 2
	return 0


## Picks the value for the current condition from a (healthy, wounded, critical) vector.
func by_condition(v: Vector3) -> float:
	return v[condition_index()]


# --- Movement helpers for brain states ----------------------------------------------------

## Head for `pos` at `strength` (input strength: < 0.6 walks, > 0.7 runs).
func move_toward(pos: Vector3, strength := 1.0) -> void:
	var to := pos - global_position
	to.y = 0.0
	intent.move = to.normalized() * strength if to.length() > 0.2 else Vector3.ZERO


## Circle `around` at `distance`, `side` = +1 / -1 (direction), at walking strength.
func circle(around: Vector3, distance: float, side: float, strength := 0.5) -> void:
	var to := global_position - around
	to.y = 0.0
	var d := to.length()
	if d < 0.01:
		return
	var out := to / d
	var tangent := Vector3(-out.z, 0.0, out.x) * side
	var radial := out * clampf((distance - d) * 1.5, -1.0, 1.0)
	intent.move = (tangent + radial).normalized() * strength


func stop() -> void:
	intent.move = Vector3.ZERO


# --- Health bands, death ------------------------------------------------------------------

func _on_damaged(_amount: int, by: Actor) -> void:
	since_hit = 0.0
	last_seen = by.global_position
	since_seen = 0.0
	var r := float(health) / maxf(max_health, 1)
	var cond := machine(CONDITION)
	if cond:
		if r < profile.critical_below:
			cond.request(&"Critical", true)
		elif r < profile.wounded_below:
			cond.request(&"Wounded", true)


func _on_died() -> void:
	targetable.enabled = false
	collision_layer = 0
	intent.clear()
	var brain := machine(BRAIN)
	if brain and brain.states.has(&"Death"):
		brain.request(&"Death", true)


## Standard condition machine (Healthy / Wounded / Critical); brain states read it.
static func make_condition_machine() -> StateMachine:
	var m := StateMachine.new()
	m.name = CONDITION
	for n in [&"Healthy", &"Wounded", &"Critical"]:
		var s := ActorState.new()
		s.name = n
		s.tags = PackedStringArray([String(n).to_lower()])
		m.add_child(s)
	return m
