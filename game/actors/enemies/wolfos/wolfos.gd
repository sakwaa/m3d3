class_name Wolfos
extends Enemy
## Wolfos-style fighter (quadruped model from the actor tools): circles, guards, lunges
## with a snapping claw; see WolfosBrain for its behaviour.

const BODY_HEIGHT := 1.0
const MODEL := preload("res://characters/wolfos_model.tscn")


func build() -> void:
	radius = 0.45
	floor_snap_length = 0.3
	var capsule := CapsuleShape3D.new()
	capsule.radius = radius
	capsule.height = BODY_HEIGHT
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	shape.position.y = BODY_HEIGHT * 0.5
	add_child(shape)
	# Model (actor tools: quadruped skeleton, mesh, animations named after the states).
	body = Node3D.new()
	body.name = "Body"
	add_child(body)
	body.add_child(MODEL.instantiate())
	add_child(ProjectedShadow.new())

	add_machine(WolfosBrain.build())
	add_machine(_locomotion())
	add_machine(_action())
	add_machine(Enemy.make_condition_machine())


func _locomotion() -> StateMachine:
	var m := StateMachine.new()
	m.name = "Locomotion"
	var idle := LocoGround.new()
	idle.name = "Idle"
	idle.idle_state = &""
	idle.move_state = &"Walk"
	idle.speed = 0.0
	var walk := LocoGround.new()
	walk.name = "Walk"
	walk.faster = &"Run"
	walk.speed = profile.walk_speed
	var run := LocoGround.new()
	run.name = "Run"
	run.slower = &"Walk"
	run.speed = profile.run_speed
	for s: LocoGround in [idle, walk, run]:
		s.jump_state = &""
		s.fall_state = &""
		m.add_child(s)
	return m


func _action() -> StateMachine:
	var m := StateMachine.new()
	m.name = Actor.ACTION
	var ready_state := ActionState.new()
	ready_state.name = "Ready"
	ready_state.inputs = {&"attack": &"Claw"}
	ready_state.holds = {&"guard": &"Guard"}
	m.add_child(ready_state)
	# Lunging swipe: telegraphed wind-up, lunge into the active frames, long recovery
	# (the player's opening).
	var claw := AttackState.new()
	claw.name = "Claw"
	claw.length = 0.9
	claw.exit_mode = ActorState.Exit.FINISH
	claw.next_state = &"Ready"
	claw.windows = {&"windup": Vector2(0.0, 0.4), &"active": Vector2(0.4, 0.55), &"opening": Vector2(0.6, 1.0)}
	claw.restrict = {&"Locomotion": PackedStringArray(["Idle"])}
	claw.can_turn = false
	claw.lunge = 5.0
	claw.reach = 1.3
	claw.tags = PackedStringArray(["attacking"])
	m.add_child(claw)
	var guard := GuardState.new()
	guard.name = "Guard"
	guard.restrict = {&"Locomotion": PackedStringArray(["Idle"])}
	guard.inputs = {&"attack": &"Claw"}
	guard.tags = PackedStringArray(["guarding"])
	m.add_child(guard)
	Actor.add_reaction_states(m, &"Ready")
	return m
