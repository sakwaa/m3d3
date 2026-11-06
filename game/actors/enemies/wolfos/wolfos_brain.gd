class_name WolfosBrain
extends RefCounted
## Wolfos-style sword fighter: notices, chases, loses track; squares off by circling at a
## distance, punishes openings, guards or backs off when swung at, counters after a block.
## Wounded: keeps further away, attacks less, guards more. Critical (if the profile says)
## flees. Each state is a small class; build() makes the Brain machine.


static func build() -> StateMachine:
	var m := StateMachine.new()
	m.name = Enemy.BRAIN
	m.buffer_time = 0.0
	for s: BrainState in [Idle.new(), Notice.new(), Chase.new(), Lost.new(), SquareOff.new(),
			Attack.new(), Defend.new(), Flee.new(), Death.new()]:
		s.name = _name_of(s)
		m.add_child(s)
	return m


static func _name_of(s: BrainState) -> StringName:
	if s is Idle: return &"Idle"
	if s is Notice: return &"Notice"
	if s is Chase: return &"Chase"
	if s is Lost: return &"Lost"
	if s is SquareOff: return &"SquareOff"
	if s is Attack: return &"Attack"
	if s is Defend: return &"Defend"
	if s is Flee: return &"Flee"
	return &"Death"


## Unaware: stands at home (back there after losing the target).
class Idle extends BrainState:
	func enter(_p: ActorState) -> void:
		enemy.face_target = null

	func update(_d: float) -> void:
		if enemy.global_position.distance_to(enemy.home) > 0.6:
			enemy.move_toward(enemy.home, 0.5)
		else:
			enemy.stop()
		if enemy.sees_target():
			go(&"Notice")


## Spotted: freezes and stares (a howl later) before giving chase.
class Notice extends BrainState:
	func _init() -> void:
		length = 0.6
		exit_mode = Exit.FINISH
		next_state = &"Chase"

	func enter(_p: ActorState) -> void:
		enemy.stop()
		enemy.face_target = target()


## Runs to where the target was last seen.
class Chase extends BrainState:
	func enter(_p: ActorState) -> void:
		enemy.face_target = null

	func update(_d: float) -> void:
		if target() == null or target().is_dead():
			go(&"Lost")
			return
		enemy.move_toward(enemy.last_seen, 1.0)
		if enemy.sees_target() and dist() < profile().engage_range:
			go(&"SquareOff")
		elif enemy.since_seen > profile().memory:
			go(&"Lost")


## Lost track: checks the last known spot, looks around, then goes home.
class Lost extends BrainState:
	func enter(_p: ActorState) -> void:
		enemy.face_target = null

	func update(_d: float) -> void:
		if enemy.sees_target() and target() and not target().is_dead():
			go(&"Chase")
			return
		if enemy.global_position.distance_to(enemy.last_seen) > 0.8 and time < 4.0:
			enemy.move_toward(enemy.last_seen, 0.5)
		else:
			enemy.stop()
			if time > 6.0:
				go(&"Idle")


## Faces the target and circles it, waiting for an opening.
class SquareOff extends BrainState:
	var _side := 1.0
	var _next_turn := 0.0
	var _next_decision := 0.0

	func enter(_p: ActorState) -> void:
		enemy.face_target = target()
		_side = 1.0 if randf() < 0.5 else -1.0
		_next_turn = time + randf_range(1.5, 3.0)
		_next_decision = time + randf_range(profile().decision_time.x, profile().decision_time.y)

	func update(_d: float) -> void:
		var t := target()
		if t == null or t.is_dead():
			go(&"Lost")
			return
		if enemy.condition_index() == 2 and profile().flee_when_critical:
			go(&"Flee")
			return
		if dist() > profile().engage_range * 1.6 or enemy.since_seen > 0.5:
			go(&"Chase")
			return
		if not body_ready():
			enemy.stop()
			return
		# Punish: the target is open (recovering from a swing, reeling) or we just blocked.
		if enemy.counter_left > 0.0 or (t.in_window(&"opening") and dist() < profile().attack_range + 1.5):
			go(&"Attack")
			return
		# Threat: the target is swinging close by.
		if t.has_tag(&"attacking") and dist() < 3.0:
			go(&"Defend")
			return
		if time > _next_turn:
			_side = -_side
			_next_turn = time + randf_range(1.5, 3.0)
		var keep := profile().circle_distance + (profile().wounded_distance if enemy.condition_index() > 0 else 0.0)
		enemy.circle(t.global_position, keep, _side)
		if time > _next_decision:
			_next_decision = time + randf_range(profile().decision_time.x, profile().decision_time.y)
			if randf() < enemy.by_condition(profile().aggression):
				go(&"Attack")


## Closes in and strikes once, then backs off to square off again.
class Attack extends BrainState:
	var _struck := false

	func enter(_p: ActorState) -> void:
		enemy.face_target = target()
		_struck = false

	func update(_d: float) -> void:
		var t := target()
		if t == null or t.is_dead():
			go(&"Lost")
			return
		if not _struck:
			if body_reeling() or time > 2.5:
				go(&"SquareOff")
				return
			if dist() > profile().attack_range:
				enemy.move_toward(t.global_position, 1.0)
			else:
				enemy.stop()
				enemy.intent.press(&"attack")
				_struck = true
		else:
			enemy.stop()
			if body_ready() and time > 0.3:
				go(&"SquareOff")


## Shield up while the target swings; counters right after a block, else backs off.
class Defend extends BrainState:
	var _guard := true

	func enter(_p: ActorState) -> void:
		enemy.face_target = target()
		_guard = randf() < enemy.by_condition(profile().guard_chance)

	func exit(_n: ActorState) -> void:
		enemy.intent.hold(&"guard", false)

	func update(_d: float) -> void:
		var t := target()
		if t == null or t.is_dead():
			go(&"Lost")
			return
		if enemy.counter_left > 0.0:
			go(&"Attack")
			return
		if _guard:
			enemy.stop()
			enemy.intent.hold(&"guard", true)
		else:
			# Back off out of reach.
			enemy.move_toward(enemy.global_position * 2.0 - t.global_position, 1.0)
		if (not t.has_tag(&"attacking") and time > 0.3) or time > 1.5:
			go(&"SquareOff")


## Critical and cowardly: runs from the target until far enough, then squares off.
class Flee extends BrainState:
	func enter(_p: ActorState) -> void:
		enemy.face_target = null

	func update(_d: float) -> void:
		var t := target()
		if t == null or t.is_dead():
			go(&"Lost")
			return
		enemy.move_toward(enemy.global_position * 2.0 - t.global_position, 1.0)
		if dist() > profile().engage_range * 2.0:
			enemy.face_target = t
			enemy.stop()


## Dead: stops thinking; the body is removed after a moment.
class Death extends BrainState:
	func _init() -> void:
		priority = 100

	func enter(_p: ActorState) -> void:
		enemy.face_target = null
		enemy.intent.clear()

	func update(_d: float) -> void:
		if time > 2.0:
			enemy.queue_free()
