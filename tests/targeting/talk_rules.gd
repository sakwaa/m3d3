extends Node
# Talking with Z-targeting (MM): sign facing gate, nearest offer wins, a locked target talks
# from anywhere the lock holds, locked onto something else = nobody, cooldown after reading.
var p: Actor
var fails := 0
const DT := 1.0 / 60.0

func _ready() -> void:
	var floor := StaticBody3D.new(); var cs := CollisionShape3D.new(); var sh := BoxShape3D.new(); sh.size = Vector3(100, 1, 100)
	cs.shape = sh; floor.add_child(cs); floor.position.y = -0.5; add_child(floor)
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.scripted = true
	p.lock.check_screen = false
	for i in 10:
		await get_tree().physics_frame
	await _run()
	print("DONE fails=%d" % fails)
	get_tree().quit()

func talkable(at: Vector3, kind: int, yaw := 0.0, gate := 0.0) -> Talkable:
	var t := Talkable.new()
	t.dialogue = Dialogue.new()
	t.target_kind = kind
	t.radius = 2.7 if kind == Targetable.Kind.POI else 4.0
	t.facing_gate = gate
	t.cooldown = 1.0
	t.position = at
	t.rotation.y = yaw
	add_child(t)
	return t

func check(name: String, ok: bool) -> void:
	print(("PASS " if ok else "FAIL ") + name)
	if not ok:
		fails += 1

func at(pos: Vector3, face := Vector3(0, 0, -1)) -> void:
	p.global_position = pos
	p.facing = face
	await get_tree().physics_frame

func _run() -> void:
	# Sign at the origin facing +Z.
	var sign := talkable(Vector3.ZERO, Targetable.Kind.POI, 0.0, 56.25)
	await at(Vector3(0, 0, 2))
	check("sign: offers in front", Talk.best_talkable() == sign)
	await at(Vector3(2, 0, 0.3))  # ~82° off its front
	check("sign: not from the side", Talk.best_talkable() == null)
	await at(Vector3(0, 0, -2))
	check("sign: not from behind", Talk.best_talkable() == null)
	await at(Vector3(0, 0, 3.2))
	check("sign: not past 2.7 m", Talk.best_talkable() == null)
	# Nearest offer wins.
	var npc := talkable(Vector3(1.5, 0, 3.5), Targetable.Kind.NPC)
	await at(Vector3(0.5, 0, 2.2))
	check("nearest: NPC 1.6 m beats sign 2.3 m", Talk.best_talkable() == npc)
	# Locked: talks from beyond reach; locked onto something else: nobody.
	sign.queue_free()
	await at(Vector3(1.5, 0, 7.6), Vector3(0, 0, -1))  # 4.1 m: outside reach, inside townsfolk acquire? (4.0) -> step to 3.9 to lock
	await at(Vector3(1.5, 0, 7.4))
	p.lock.update(DT, false, false, false)
	p.lock.update(DT, true, true, false)
	check("locked: NPC locked at 3.9 m", p.lock.target != null and p.lock.target.get_parent() == npc)
	await at(Vector3(1.5, 0, 7.55))  # 4.05 m: past its 4.0 m reach, inside its 4.1 m release
	p.lock.update(DT, false, true, false)
	check("locked: talks from 4.05 m (past reach)", Talk.best_talkable() == npc)
	var enemy := Node3D.new(); enemy.position = Vector3(1.5, 0, 9); add_child(enemy)
	var et := Targetable.new(); et.kind = Targetable.Kind.ENEMY; et.position.y = 1.0; enemy.add_child(et)
	p.lock.lock(et)
	await at(Vector3(1.5, 0, 5))
	check("locked on an enemy: nobody, even beside the NPC", Talk.best_talkable() == null)
	p.lock.release()
	check("unlocked beside the NPC: NPC", Talk.best_talkable() == npc)
	# Cooldown.
	npc.ready_at = Time.get_ticks_msec() * 0.001 + 1.0
	check("cooldown: not right after", Talk.best_talkable() == null)
