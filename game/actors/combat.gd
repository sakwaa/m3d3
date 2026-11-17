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

## Hit juice, after the OoT remake (references/combat/ootr_remake_combat.md, 60 fps frames):
## both fighters freeze 8 frames on a hit (12 on a kill), the target flashes red 14 frames
## then fades over 4, a burst of light flashes along the swing, and blades leave smears
## (SwordTrail). Each can be switched off (the combat sandbox compares them).
static var juice := {hitstop = true, flash = true, burst = true, trail = true}
const HITSTOP := 8.0 / 60.0
const KILL_HITSTOP := 12.0 / 60.0
const FLASH_COLOR := Color(1.0, 0.12, 0.1, 0.85)
const FLASH_HOLD := 14.0 / 60.0
const FLASH_FADE := 4.0 / 60.0
const BURST_EDGE := Color(1.0, 0.35, 0.45)
const KILL_EDGE := Color(0.7, 0.35, 1.0)
## A turned blade: a short hot streak, a white flash on the part, a brief stop.
const RICOCHET_EDGE := Color(1.0, 0.7, 0.25)
const RICOCHET_FLASH := Color(1.0, 1.0, 1.0, 0.8)
const RICOCHET_STOP := 4.0 / 60.0
## Hit effects: OoT / MM's own (OotHitFx: hit mark + blood on flesh, metal mark + clang
## streaks + blue flash on armour, guards and clashes) or the remake-style emitters + burst.
enum HitFx { OOT, REMAKE }
static var hit_fx := HitFx.OOT


## OoT's effects for a blow landing at `at`: `metal` (armour, a guard, a clash) or flesh.
static func _oot_fx(near: Node, at: Vector3, metal: bool) -> void:
	var root := near.get_tree().current_scene if near.get_tree().current_scene else near.get_parent()
	if metal:
		OotHitFx.hit_mark(root, at, OotHitFx.Mark.METAL)
		OotHitFx.clang(root, at, true)
	else:
		OotHitFx.hit_mark(root, at, OotHitFx.Mark.WHITE)
		OotHitFx.blood(root, at, OotHitFx.Blood.BLUE)


static func update_attacks(attacker: Actor) -> void:
	var swing := attacker.active_attack()
	if swing == null or attacker.is_dead():
		return
	var blade := attacker.blade()
	var prev := swing.last_blade if not swing.last_blade.is_empty() else blade
	swing.last_blade = blade
	for node in attacker.get_tree().get_nodes_in_group(&"actors"):
		var target := node as Actor
		if target == null or target == attacker or target.team == attacker.team or target.is_dead():
			continue
		if swing.resolved.has(target) or not swing.reaches(target):
			continue
		var points := StrikePoint.of(target)
		var met: StrikePoint = null
		if not blade.is_empty() and not points.is_empty():
			# The blade's sweep this frame decides what it meets; untouched by the end of the
			# active window, the point it aimed at takes it (settle(): a near miss isn't a whiff).
			met = _sweep(prev, blade, points, swing.aim, attacker.global_position + Vector3.UP * 1.1, attacker.blade_power())
			if met == null:
				swing.pending[target] = true  # (settled when the active window closes)
				continue
		swing.resolved[target] = true
		# Which way the blade was travelling as it struck (world; zero without a blade).
		var motion := Vector3.ZERO
		if not blade.is_empty() and not prev.is_empty():
			motion = (blade[0] + blade[1]) * 0.5 - (prev[0] + prev[1]) * 0.5
		_resolve(attacker, swing, target, met, motion)
		if attacker.active_attack() != swing:
			return  # the attacker got interrupted (clash / block / ricochet)


const HIT_EFFECT := preload("res://game/effects/hit_flash.tres")
const CLASH_EFFECT := preload("res://game/effects/clash_spark.tres")


## Where two actors' blows meet (between them, at chest height).
static func _between(a: Actor, b: Actor) -> Vector3:
	return a.global_position.lerp(b.global_position, 0.5) + Vector3.UP * 1.1


static func _resolve(attacker: Actor, swing: AttackState, target: Actor, met: StrikePoint = null, motion := Vector3.ZERO) -> void:
	var theirs := target.active_attack()
	if theirs and theirs.reaches(attacker) and not theirs.resolved.has(attacker):
		theirs.resolved[attacker] = true
		if hit_fx == HitFx.OOT:
			_oot_fx(attacker, _between(attacker, target), true)
		else:
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
	if met and met.defends_from(attacker.global_position + Vector3.UP * 1.1, attacker.blade_power()):
		_ricochet(attacker, swing, target, met)
		return
	var guard := target.state_of(Actor.ACTION) as GuardState
	if met == null and guard and guard.covers(attacker):
		_log(attacker, "blocked by %s" % target.name)
		if hit_fx == HitFx.OOT:
			_oot_fx(attacker, _between(attacker, target), true)
		else:
			Effects.spawn(CLASH_EFFECT, _between(attacker, target), (attacker.global_position - target.global_position).normalized())
		attacker.react(&"Recoil")
		target.counter_left = COUNTER_TIME
		return
	var damage := swing.damage if met == null else maxi(int(round(swing.damage * met.damage_scale)), 1)
	var at := met.global_position if met else _hit_spot(attacker, target)
	_log(attacker, "hits %s%s for %d" % [target.name, " (%s)" % met.part if met else "", damage])
	if hit_fx == HitFx.OOT:
		_oot_fx(attacker, at, false)
	else:
		Effects.spawn(HIT_EFFECT, at, (attacker.global_position - target.global_position).normalized())
	target.take_hit(damage, attacker, swing.knockback, _hit_info(attacker, swing, target, at, motion))
	_juice_hit(attacker, swing, target, at)


## A blade turned by armour or a guard: the attacker bounces off (recoils, open to a
## counter), sparks fly where it struck, the part flashes white and a short hot streak
## shows which way it glanced off.
static func _ricochet(attacker: Actor, swing: AttackState, target: Actor, met: StrikePoint) -> void:
	_log(attacker, "turned by %s's %s" % [target.name, met.part])
	var at := met.global_position
	var away := attacker.global_position - target.global_position
	away.y = 0.0
	away = away.normalized() if away.length() > 0.01 else -attacker.facing
	if hit_fx == HitFx.OOT:
		_oot_fx(attacker, at, true)
	else:
		Effects.spawn(CLASH_EFFECT, at, away)
	if juice.burst and hit_fx != HitFx.OOT:
		ImpactBurst.spawn(at, (away + Vector3.UP * 0.6).normalized(), 1.4, RICOCHET_EDGE)
	if juice.flash:
		target.flash(RICOCHET_FLASH, 3.0 / 60.0, 6.0 / 60.0)
	if juice.hitstop:
		attacker.hitstop(RICOCHET_STOP)
		target.hitstop(RICOCHET_STOP)
	attacker.react(&"Recoil")
	target.counter_left = COUNTER_TIME


## How a hit pushes (Actor.take_hit): along the blade's travel at contact (a right-to-left
## slash shoves the target to the attacker's left as well as back), blended with straight
## away from the attacker; stronger for stronger blades and finishers (trigger_boost).
static func _hit_info(attacker: Actor, swing: AttackState, target: Actor, at: Vector3, motion: Vector3) -> Dictionary:
	var away := target.global_position - attacker.global_position
	away.y = 0.0
	away = away.normalized() if away.length() > 0.01 else attacker.facing
	var travel := Vector3(motion.x, 0.0, motion.z)
	if travel.length() < 0.001:
		# No blade (a bite, a claw) or a settled near miss: the swing's own line in the world.
		var f := attacker.facing
		var right := f.cross(Vector3.UP).normalized()
		travel = right * swing.slash_axis.x + f * swing.slash_axis.z
		travel.y = 0.0
	var dir := away * 0.55 + (travel.normalized() if travel.length() > 0.001 else Vector3.ZERO) * 0.75
	var heavy := swing.trigger_boost > 1.0
	var strength := (1.0 + 0.35 * (attacker.blade_power() - 1)) * (1.5 if heavy else 1.0)
	return {dir = dir.normalized() if dir.length() > 0.01 else away, at = at, strength = strength, heavy = heavy}


static func _hit_spot(attacker: Actor, target: Actor) -> Vector3:
	var to := attacker.global_position - target.global_position
	to.y = 0.0
	return target.global_position + Vector3.UP * 1.0 + (to.normalized() * 0.3 if to.length() > 0.01 else Vector3.ZERO)


static func _juice_hit(attacker: Actor, swing: AttackState, target: Actor, at: Vector3) -> void:
	var kill := target.is_dead()
	if juice.hitstop:
		var t := KILL_HITSTOP if kill else HITSTOP
		attacker.hitstop(t)
		target.hitstop(t)
	if juice.flash:
		target.flash(FLASH_COLOR, FLASH_HOLD, FLASH_FADE)
	if juice.burst and hit_fx != HitFx.OOT:
		var f := attacker.facing
		var right := f.cross(Vector3.UP).normalized()
		var axis := right * swing.slash_axis.x + Vector3.UP * swing.slash_axis.y + f * swing.slash_axis.z
		ImpactBurst.spawn(at, axis, 4.0 if kill else 3.0, KILL_EDGE if kill else BURST_EDGE)


static func _log(actor: Actor, text: String) -> void:
	if actor.debug_log or Actor.show_debug:
		print("[combat] %s %s" % [actor.name, text])


# --- Strike points ---------------------------------------------------------------------------

## Picks where `swing` aims (StrikePoint) on whoever it's swung at - the locked target, else
## the nearest foe in front - and steps in or out so the blade's natural contact distance
## meets it (StrikeRig bends the body for the rest).
static func aim_swing(swing: AttackState) -> void:
	swing.aim = null
	var attacker := swing.actor
	var target := _swing_target(attacker, swing)
	if target == null:
		return
	var points := StrikePoint.of(target)
	for p in points:
		p.place()
	swing.aim = _best_target(points, attacker, swing)
	if swing.aim == null:
		swing.aim = _best_target(points, attacker, swing, true)  # (nothing it can hurt: swing anyway, and bounce)
	if swing.aim == null:
		return
	var to := swing.aim.global_position - attacker.global_position
	to.y = 0.0
	var step := clampf(to.length() - CONTACT_REACH, -0.4, 0.8)
	attacker.impulse += attacker.facing * Actor.impulse_for(step)


## Metres in front of the attacker the blade naturally meets things.
const CONTACT_REACH := 1.0


static func _swing_target(attacker: Actor, swing: AttackState) -> Actor:
	var t := attacker.face_target as Targetable
	if t and t.actor() and t.actor().team != attacker.team:
		return t.actor()
	var best: Actor = null
	var best_d := INF
	for node in attacker.get_tree().get_nodes_in_group(&"actors"):
		var a := node as Actor
		if a == null or a == attacker or a.team == attacker.team or a.is_dead():
			continue
		var to := a.global_position - attacker.global_position
		to.y = 0.0
		if to.length() > swing.reach + 1.5 or (to.length() > 0.01 and attacker.facing.dot(to.normalized()) < cos(deg_to_rad(swing.arc * 0.5))):
			continue
		if to.length() < best_d:
			best_d = to.length()
			best = a
	return best


## The point `swing` suits best seen from `attacker`, among those its blade can hurt (open
## ones, and armour / guards it's strong enough to cut through): facing them (the head from
## the front, the flank from the side), at the height the swing's line favours (chops high,
## side slashes and stabs mid), and near.
static func _best_target(points: Array[StrikePoint], attacker: Actor, swing: AttackState, any := false) -> StrikePoint:
	var power := attacker.blade_power()
	var from := attacker.global_position + Vector3.UP * 1.1
	var want := 1.0
	var line := swing.slash_axis
	if absf(line.y) > 0.9:
		want = 1.4  # a chop comes down from high
	elif absf(line.x) > 0.9 or absf(line.z) > 0.9:
		want = 0.9
	var best: StrikePoint = null
	var best_s := -INF
	for p in points:
		if not (p.takes_from(from, power) or (any and p.exposure(from) > 0.25)):
			continue
		var e := p.exposure(from)
		var h := p.global_position.y - attacker.global_position.y
		var d := Vector2(p.global_position.x - attacker.global_position.x, p.global_position.z - attacker.global_position.z).length()
		var s := e * 1.5 - absf(h - want) * 0.8 - d * 0.3
		if s > best_s:
			best_s = s
			best = p
	return best


## What the blade's trigger, moving from `prev` to `cur` ([low, high] ends), reached first this frame (ties:
## a defending point, then `aim`, then the nearest). Open points on the far side of the
## body from `from` (the attacker) can't be reached through it. An open point with a defending one
## between it and the attacker (a raised shield, claws up) is the defending one's.
static func _sweep(prev: Array, cur: Array, points: Array[StrikePoint], aim: StrikePoint, from: Vector3, power: int) -> StrikePoint:
	var best: StrikePoint = null
	var best_key := Vector3(INF, INF, INF)
	for p in points:
		p.place()
		var c := p.global_position
		for k in 5:
			var s := k / 4.0
			var a: Vector3 = (prev[0] as Vector3).lerp(cur[0], s)
			var b: Vector3 = (prev[1] as Vector3).lerp(cur[1], s)
			var q := Geometry3D.get_closest_point_to_segment(c, a, b)
			if q.distance_to(c) > p.radius + BLADE_RADIUS:
				continue
			var guards := p.defends_from(from, power)
			if not guards and not p.takes_from(from, power):
				break  # (a guard that isn't up or faces elsewhere, or the far side)
			var key := Vector3(k, 0 if guards else (1 if p == aim else 2), c.distance_to(cur[0]))
			if key.x < best_key.x or (key.x == best_key.x and (key.y < best_key.y or (key.y == best_key.y and key.z < best_key.z))):
				best_key = key
				best = p
			break
	if best and not best.defends_from(from, power):
		var guard := _covering(points, from, best.global_position, from, power)
		if guard:
			return guard
	return best


## A defending point between `from` and `to` (a shield in the blade's way), or null.
static func _covering(points: Array[StrikePoint], from: Vector3, to: Vector3, attacker_at: Vector3, power: int) -> StrikePoint:
	for p in points:
		if p.defends_from(attacker_at, power):
			var q := Geometry3D.get_closest_point_to_segment(p.global_position, from, to)
			if q.distance_to(p.global_position) <= p.radius and q.distance_to(to) > 0.05:
				return p
	return null


## The active window closed with targets in reach the blade never touched: they take it
## on the point aimed at (or the best it can hurt, else the most exposed: a turned blade) -
## unless a guard covers it.
static func settle(swing: AttackState) -> void:
	var attacker := swing.actor
	for target: Actor in swing.pending.keys():
		if not is_instance_valid(target) or swing.resolved.has(target) or target.is_dead():
			continue
		var points := StrikePoint.of(target)
		var met := swing.aim if swing.aim and swing.aim.actor == target else _best_target(points, attacker, swing)
		if met == null:
			met = _best_target(points, attacker, swing, true)
		var blade := attacker.blade()
		if met and not blade.is_empty():
			var chest := attacker.global_position + Vector3.UP * 1.1
			var guard := _covering(points, chest, met.global_position, chest, attacker.blade_power())
			if guard:
				met = guard
		swing.resolved[target] = true
		_resolve(attacker, swing, target, met)
		if attacker.active_attack() != swing and attacker.state_of(Actor.ACTION) != swing:
			break
	swing.pending.clear()


const BLADE_RADIUS := 0.04
