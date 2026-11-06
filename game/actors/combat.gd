class_name Combat
extends RefCounted
## Melee resolution between Actors (no physics areas: reach / arc tests against the
## actors' positions). Rules:
##  - an AttackState hits during its "active" window, once per target per swing;
##  - both sides mid-swing and in each other's reach: a clash. Equal weights both recoil
##    (both open); the heavier attack staggers the lighter side;
##  - target guarding and facing the attacker: blocked. The attacker recoils and the
##    defender gets a short counter window (Actor.counter_left);
##  - otherwise damage + knockback, and Hurt (or Death).

## Seconds a successful block leaves to counter.
const COUNTER_TIME := 0.6


static func update_attacks(attacker: Actor) -> void:
	var swing := attacker.active_attack()
	if swing == null or attacker.is_dead():
		return
	for node in attacker.get_tree().get_nodes_in_group(&"actors"):
		var target := node as Actor
		if target == null or target == attacker or target.team == attacker.team or target.is_dead():
			continue
		if swing.resolved.has(target) or not swing.reaches(target):
			continue
		swing.resolved[target] = true
		_resolve(attacker, swing, target)
		if attacker.active_attack() != swing:
			return  # the attacker got interrupted (clash / block)


const HIT_EFFECT := preload("res://game/effects/hit_flash.tres")
const CLASH_EFFECT := preload("res://game/effects/clash_spark.tres")


## Where two actors' blows meet (between them, at chest height).
static func _between(a: Actor, b: Actor) -> Vector3:
	return a.global_position.lerp(b.global_position, 0.5) + Vector3.UP * 1.1


static func _resolve(attacker: Actor, swing: AttackState, target: Actor) -> void:
	var theirs := target.active_attack()
	if theirs and theirs.reaches(attacker) and not theirs.resolved.has(attacker):
		theirs.resolved[attacker] = true
		Effects.spawn(CLASH_EFFECT, _between(attacker, target))
		if swing.weight == theirs.weight:
			_log(attacker, "clash with %s: both recoil" % target.name)
			attacker.react(&"Recoil")
			target.react(&"Recoil")
		elif swing.weight > theirs.weight:
			_log(attacker, "clash with %s: wins, %s staggers" % [target.name, target.name])
			target.react(&"Stagger")
		else:
			_log(attacker, "clash with %s: loses, staggers" % target.name)
			attacker.react(&"Stagger")
		return
	var guard := target.state_of(Actor.ACTION) as GuardState
	if guard and guard.covers(attacker):
		_log(attacker, "blocked by %s" % target.name)
		Effects.spawn(CLASH_EFFECT, _between(attacker, target), (attacker.global_position - target.global_position).normalized())
		attacker.react(&"Recoil")
		target.counter_left = COUNTER_TIME
		return
	_log(attacker, "hits %s for %d" % [target.name, swing.damage])
	Effects.spawn(HIT_EFFECT, target.global_position + Vector3.UP * 1.0, (attacker.global_position - target.global_position).normalized())
	target.take_hit(swing.damage, attacker, swing.knockback)


static func _log(actor: Actor, text: String) -> void:
	if actor.debug_log or Actor.show_debug:
		print("[combat] %s %s" % [actor.name, text])
