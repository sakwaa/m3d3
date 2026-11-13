extends Node
# Sword attacks picked MM's way (references/combat/mm_sword_attacks_decomp.md): which state
# each stick direction gives free and locked on, chains (the same cut again counts up, the
# third is its finisher, another direction starts over, presses mid-swing are dropped), and
# the jump slash's leap. Prints PASS / FAIL. Run: godot --headless --path . tests/combat/attacks.tscn
var p: Actor
var target: Node3D
var fails := 0


func check(label: String, ok: bool, got := "") -> void:
	print(("PASS " if ok else "FAIL ") + label + ("  (%s)" % got if got != "" else ""))
	if not ok:
		fails += 1


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
	# The player faces -Z: forward (0, 0, -1), right (1, 0, 0).
	for spec in [["free, neutral", Vector3.ZERO, false, "SlashH"], ["free, forward", Vector3(0, 0, -1), false, "SlashV"],
			["free, left", Vector3(-1, 0, 0), false, "SlashH"], ["free, back", Vector3(0, 0, 1), false, "SlashH"],
			["free, right", Vector3(1, 0, 0), false, "SlashH2"], ["locked, neutral", Vector3.ZERO, true, "SlashV"],
			["locked, forward", Vector3(0, 0, -1), true, "Stab"], ["locked, left", Vector3(-1, 0, 0), true, "SlashH"],
			["locked, right", Vector3(1, 0, 0), true, "SlashH2"], ["half-tilt forward = neutral", Vector3(0, 0, -0.6), false, "SlashH"]]:
		var got := await _try(spec[0], spec[1], spec[2])
		check("%-28s -> %s" % [spec[0], spec[3]], got == spec[3], got)
	# Chains: neutral presses in each recovery: the same cut three times (1, 2, 3), then over.
	await _settle()
	var counts := []
	var anims := []
	var entries := [0]  # (lambdas capture locals by value: count in an array)
	p.state_of(&"Action").machine.state_changed.connect(func(_f, to): if to == &"SlashH": entries[0] += 1)
	for i in 4:
		p.intent.press(&"attack")
		await get_tree().physics_frame
		counts.append(p.combo_count)
		anims.append(String(p._anim.current_animation))
		await _until_cancel()
	await _frames(40)
	check("chain: same cut re-entered each press", entries[0] == 4, "entries %d" % entries[0])
	check("chain: count 1, 2, 3 then over", counts == [1, 2, 3, 1], str(counts))
	check("chain: each repeat restarts the clip (alternating names)", anims[0] != anims[1] and anims[1] != anims[2], str(anims))
	# Locked on, neutral three times: chop, chop, the vertical finisher (longer reach at first).
	await _settle()
	p.face_target = target
	var picked := []
	var boosted := false
	for i in 3:
		p.intent.press(&"attack")
		await get_tree().physics_frame
		picked.append(String(p.state_of(&"Action").name))
		if i == 2:
			var fin := p.state_of(&"Action") as AttackState
			boosted = fin != null and fin.trigger_scale() > 1.3
		await _until_cancel()
	await _frames(40)
	check("locked neutral x3: chop, chop, finisher", picked == ["SlashV", "SlashV", "SlashVFin"], str(picked))
	check("finisher: blade reach starts 1.5x", boosted)
	p.face_target = null
	# A press during the swing (before its recovery) is dropped.
	await _settle()
	p.intent.press(&"attack")
	await _frames(3)
	p.intent.press(&"attack")
	await _frames(40)
	check("press mid-swing dropped", _seen.split(" ").count("SlashH") == 1, _seen)
	# Another direction starts a new chain.
	await _settle()
	p.intent.press(&"attack")
	await get_tree().physics_frame
	await _until_cancel()
	p.intent.move = Vector3(1, 0, 0)
	p.intent.press(&"attack")
	await get_tree().physics_frame
	check("new direction starts over", p.state_of(&"Action").name == &"SlashH2" and p.combo_count == 1,
		"%s %d" % [p.state_of(&"Action").name, p.combo_count])
	# Forward held through the swing: one step in (MM: ~0.9 m), no slide; a forward chain
	# steps once per cut.
	for n in [1, 3]:
		await _settle()
		p.intent.move = Vector3(0, 0, -1)
		await get_tree().physics_frame
		var from := p.global_position
		for i in n:
			p.intent.press(&"attack")
			await get_tree().physics_frame
			await _until_cancel()
		p.intent.move = Vector3.ZERO  # (let go in the recovery: running would move on)
		await _frames(40)
		var moved := -(p.global_position.z - from.z)
		print("forward held, %d cut(s): moved %.2f m" % [n, moved])
		check("forward held x%d: steps ~0.9 m a cut, no slide" % n, absf(moved - 0.9 * n) < 0.35 * n, "%.2f m" % moved)
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
	check("jump slash leaps and lands", top > 0.5 and landed_at > 0)
	# Strafing while Z-targeting: standing = the stance; left / right / back = strafes (the
	# facing held on the target); forward = walk at it; letting go of the lock = idle again.
	await _settle()
	p.face_target = target
	for spec in [[Vector3.ZERO, "BattleIdle"], [Vector3(1, 0, 0), "StrafeR"], [Vector3(-1, 0, 0), "StrafeL"],
			[Vector3(0, 0, 1), "StrafeB"], [Vector3(0, 0, -1), "Walk"]]:
		p.global_position = Vector3.ZERO
		p.facing = Vector3.FORWARD
		p.intent.move = spec[0]
		await _frames(20)
		var st := String(p.state_of(&"Locomotion").name)
		var ok: bool = st == spec[1] or (spec[1] == "Walk" and st == "Run")
		check("z-targeting %-16s -> %s" % [str(spec[0]), spec[1]], ok, st)
	p.intent.move = Vector3(1, 0, 0)
	p.global_position = Vector3.ZERO
	await _frames(30)
	check("strafing right keeps facing the target", p.facing.dot((target.global_position - p.global_position).normalized() * Vector3(1, 0, 1)) > 0.9 and p.global_position.x > 0.5,
		"x %.2f" % p.global_position.x)
	p.face_target = null
	p.intent.move = Vector3.ZERO
	await _frames(10)
	check("lock off: back to idle", p.state_of(&"Locomotion").name == &"Idle", String(p.state_of(&"Locomotion").name))
	print("DONE fails=%d" % fails)
	get_tree().quit()


var _seen := ""


func _try(_label: String, move: Vector3, locked: bool) -> String:
	await _settle()
	p.face_target = target if locked else null
	p.intent.move = move
	p.intent.press(&"attack")
	await _frames(4)
	p.intent.move = Vector3.ZERO
	return String(p.state_of(&"Action").name)


## Waits for the playing attack's recovery ("cancel" window).
func _until_cancel() -> void:
	for i in 60:
		var a := p.state_of(&"Action") as AttackState
		if a and a.in_window(&"cancel"):
			return
		await get_tree().physics_frame


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
