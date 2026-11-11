extends Node
# Directional sword attacks: presses attack in each situation and prints which state plays,
# chaining, and the jump slash's leap. Run: godot --headless --path . tests/combat/attacks.tscn
var p: Actor
var target: Node3D


func _ready() -> void:
	var floor := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
	cs.shape = box
	floor.add_child(cs)
	floor.position.y = -0.5
	add_child(floor)
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.scripted = true
	target = Node3D.new()
	add_child(target)
	target.position = Vector3(0, 0, -4)
	await _settle()
	await _try("standing", Vector3.ZERO, false)
	await _try("moving", Vector3(0, 0, -1), false)
	await _try("locked, neutral", Vector3.ZERO, true)
	await _try("locked, forward", Vector3(0, 0, -1), true)
	await _try("locked, side", Vector3(1, 0, 0), true)
	# Chain: presses in a row (standing: diagonal -> backhand -> diagonal).
	await _settle()
	p.face_target = null
	p.intent.move = Vector3.ZERO
	p.intent.press(&"attack")
	await _frames(12)
	var first := p.state_of(&"Action").name
	p.intent.press(&"attack")
	await _frames(14)
	var second := _seen
	p.intent.press(&"attack")
	await _frames(30)
	print("chain: %s -> %s -> %s" % [first, second, _seen])
	await _settle()
	# Jump slash: locked on, jump.
	p.face_target = target
	p.intent.press(&"jump_attack")
	var top := 0.0
	var landed_at := -1
	for f in 60:
		await get_tree().physics_frame
		if f % 6 == 0 and OS.get_environment("DBG") != "":
			print("  f%d %s / %s vel %s pos %s" % [f, p.state_of(&"Action").name, p.state_of(&"Locomotion").name, p.velocity, p.global_position])
		top = maxf(top, p.global_position.y)
		if landed_at < 0 and f > 5 and p.is_on_floor():
			landed_at = f
	print("jump slash: state %s, rose %.2f m, landed after %d frames (%.2f s), moved %.2f m forward" % [_seen, top, landed_at, landed_at / 60.0, -p.global_position.z])
	get_tree().quit()


var _seen := ""


func _try(label: String, move: Vector3, locked: bool) -> void:
	await _settle()
	p.face_target = target if locked else null
	p.intent.move = move
	p.intent.press(&"attack")
	await _frames(4)
	print("%-16s -> %s" % [label, p.state_of(&"Action").name])
	p.intent.move = Vector3.ZERO


func _frames(n: int) -> void:
	_seen = ""
	for i in n:
		await get_tree().physics_frame
		var s := String(p.state_of(&"Action").name)
		if not _seen.ends_with(s):
			_seen += (" " if _seen != "" else "") + s


func _settle() -> void:
	p.intent.move = Vector3.ZERO
	p.face_target = null
	for i in 60:
		await get_tree().physics_frame
	p.global_position = Vector3.ZERO
	p.velocity = Vector3.ZERO
	p.facing = Vector3.FORWARD
	await get_tree().physics_frame
