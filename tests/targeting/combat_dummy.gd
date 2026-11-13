class_name CombatDummy
extends Enemy
## A training dummy for the combat sandbox: takes hits (Hurt / Death reactions, knockback),
## never attacks; `rooted` (default) it takes no knockback, so combos stay in reach. `shield`: turns to face the player and holds its shield up (blocks from
## the front: hit it from the side or behind). Knocked out, it comes back `respawn`
## seconds later.

@export var shield := false
@export var respawn := 2.0
@export var color := Color(0.8, 0.6, 0.35)
## Stays put when hit (no knockback), so combos can be tried on it.
@export var rooted := true
## Plated all over (every point ARMOR, hardness 2): a weak blade bounces off, a strong one
## (power 3) cuts through.
@export var armored := false

var _down := 0.0
var _layer := 1


func build() -> void:
	_layer = collision_layer
	radius = 0.35
	var capsule := CapsuleShape3D.new()
	capsule.radius = radius
	capsule.height = 1.7
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	shape.position.y = 0.85
	add_child(shape)
	body = Node3D.new()
	body.name = "Body"
	add_child(body)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0.62, 0.68) if armored else color
	if armored:
		mat.metallic = 0.6
		mat.roughness = 0.35
	var post := MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.radius = radius
	m.height = 1.7
	post.mesh = m
	post.position.y = 0.85
	post.material_override = mat
	body.add_child(post)
	var head := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.22
	hm.height = 0.44
	head.mesh = hm
	head.position = Vector3(0, 1.85, 0)
	head.material_override = mat
	body.add_child(head)
	if shield:
		var s := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(0.75, 1.1, 0.08)
		s.mesh = sm
		s.position = Vector3(0, 1.4, -0.45)  # raised in front, head to chest (the body faces -Z)
		var smat := StandardMaterial3D.new()
		smat.albedo_color = Color(0.35, 0.4, 0.55)
		s.material_override = smat
		body.add_child(s)
	# Strike points: the head (double), the body front and back; the shield guards the front.
	var K := StrikePoint.Kind
	var flesh := K.ARMOR if armored else K.OPEN
	add_child(StrikePoint.new(flesh, &"", Vector3(0, 1.85, 0), Vector3.ZERO, 0.22, 2.0, "head"))
	add_child(StrikePoint.new(flesh, &"", Vector3(0, 1.1, -0.2), Vector3(0, 0, -1), 0.3, 1.0, "chest"))
	add_child(StrikePoint.new(flesh, &"", Vector3(0, 1.1, 0.2), Vector3(0, 0, 1), 0.3, 1.0, "back"))
	if shield:
		add_child(StrikePoint.new(K.GUARD, &"", Vector3(0, 1.45, -0.5), Vector3(0, 0, -1), 0.55, 0.0, "shield"))
	var loco := StateMachine.new()
	loco.name = "Locomotion"
	var idle := LocoGround.new()
	idle.name = "Idle"
	idle.idle_state = &""
	idle.speed = 0.0
	idle.jump_state = &""
	idle.fall_state = &""
	loco.add_child(idle)
	add_machine(loco)
	var action := StateMachine.new()
	action.name = Actor.ACTION
	var ready_state := ActionState.new()
	ready_state.name = "Ready"
	ready_state.holds = {&"guard": &"Guard"}
	action.add_child(ready_state)
	var guard := GuardState.new()
	guard.name = "Guard"
	action.add_child(guard)
	Actor.add_reaction_states(action, &"Ready")
	add_machine(action)
	add_machine(Enemy.make_condition_machine())


func drive(delta: float) -> void:
	super.drive(delta)
	if is_dead():
		_down += delta
		body.rotation.x = lerpf(body.rotation.x, -1.4, clampf(8.0 * delta, 0.0, 1.0))  # keeled over
		if _down >= respawn:
			_back_up()
		return
	if shield:
		face_target = target
		intent.hold(&"guard", true)


func take_hit(damage: int, by: Actor, knockback: float) -> void:
	super.take_hit(damage, by, 0.0 if rooted else knockback)


func _back_up() -> void:
	_down = 0.0
	body.rotation.x = 0.0
	heal_full()
	targetable.enabled = true
	collision_layer = _layer
