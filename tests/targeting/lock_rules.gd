extends Node
# Z-targeting rules (MM, references/targeting/z_targeting_spec.md), driven headless:
# prints PASS / FAIL per case and a summary. The player faces -Z; targets are plain nodes
# with a Targetable at 1.2 m.
var p: Actor
var lock: TargetLock
var fails := 0
const DT := 1.0 / 60.0

func _ready() -> void:
	var floor := StaticBody3D.new()
	var cs := CollisionShape3D.new(); var sh := BoxShape3D.new(); sh.size = Vector3(200, 1, 200)
	cs.shape = sh; floor.add_child(cs); floor.position.y = -0.5; add_child(floor)
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.scripted = true
	lock = p.lock
	await get_tree().physics_frame
	await get_tree().physics_frame
	await _run()
	print("DONE fails=%d" % fails)
	get_tree().quit()

func target(kind: int, at: Vector3, range_type := Targetable.Reach.KIND) -> Targetable:
	var n := Node3D.new(); n.position = at; add_child(n)
	var t := Targetable.new(); t.kind = kind; t.range_type = range_type; t.position.y = 1.2
	n.add_child(t)
	return t

func wall(at: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new(); var c := CollisionShape3D.new(); var s := BoxShape3D.new(); s.size = size
	c.shape = s; b.add_child(c); b.position = at; add_child(b)
	return b

func clear() -> void:
	lock.release()
	lock.update(DT, false, false, false, true)  # (blocked: timer to 0, parallel off)
	for c in get_children():
		if c != p and not c is StaticBody3D or (c is StaticBody3D and c.position.y > -0.5):
			c.free()
	p.global_position = Vector3.ZERO
	p.facing = Vector3(0, 0, -1)

func step(seconds: float, pressed := false, held := false, back := false) -> void:
	var n := maxi(int(round(seconds / DT)), 1)
	for i in n:
		lock.update(DT, pressed and i == 0, held, back)

func check(name: String, ok: bool) -> void:
	print(("PASS " if ok else "FAIL ") + name)
	if not ok:
		fails += 1

func _run() -> void:
	# Cone: ±60° off the body's facing.
	clear()
	var a := target(Targetable.Kind.ENEMY, Vector3(3, 0, 0).rotated(Vector3.UP, deg_to_rad(90 + 50)))
	var b := target(Targetable.Kind.ENEMY, Vector3(3, 0, 0).rotated(Vector3.UP, deg_to_rad(90 - 70)))
	await get_tree().physics_frame
	lock.check_screen = false
	step(DT)
	lock.check_screen = true
	check("cone: 50° in, 70° out", lock.hover == a)
	check("screen: both off screen behind the camera's view", (func():
		step(DT)
		return lock.hover == null).call())
	# Tier: a far enemy beats a near NPC.
	clear()
	var e := target(Targetable.Kind.ENEMY, Vector3(0, 0, -10))
	var npc := target(Targetable.Kind.NPC, Vector3(0.5, 0, -2))
	await get_tree().physics_frame
	step(DT)
	check("tier: enemy 10 m beats NPC 2 m", lock.hover == e)
	e.enabled = false
	step(DT)
	check("tier: NPC once no enemy", lock.hover == npc)
	# Range: townsfolk acquire 4.0 m.
	clear()
	var near := target(Targetable.Kind.NPC, Vector3(0, 0, -3.8))
	var far := target(Targetable.Kind.NPC, Vector3(1, 0, -4.3))
	await get_tree().physics_frame
	step(DT)
	check("range: NPC 3.8 m in", lock.hover == near)
	near.enabled = false
	step(DT)
	check("range: NPC 4.4 m out", lock.hover == null and far != null)
	# Leash: default enemy acquire 14 m, release 17.1 m, ignored for 0.5 s.
	clear()
	e = target(Targetable.Kind.ENEMY, Vector3(0, 0, -13))
	await get_tree().physics_frame
	step(DT)
	step(DT, true, true)
	check("leash: locked at 13 m", lock.target == e)
	p.global_position = Vector3(0, 0, 5)  # 18 m away
	step(0.3, false, true)
	check("leash: grace keeps it at 18 m (0.3 s)", lock.target == e)
	p.global_position = Vector3(0, 0, 3.5)  # 16.5 m
	step(0.5, false, true)
	check("leash: kept at 16.5 m", lock.target == e)
	p.global_position = Vector3(0, 0, 4.5)  # 17.5 m
	step(DT, false, true)
	check("leash: lost at 17.5 m", lock.target == null and lock.forced)
	step(DT, true, true)
	check("forced: no Parallel while Z still held", not lock.parallel)
	# Line of sight: blocks acquiring, not keeping.
	clear()
	e = target(Targetable.Kind.ENEMY, Vector3(0, 0, -6))
	var w := wall(Vector3(0, 1.5, -3), Vector3(4, 3, 0.3))
	await get_tree().physics_frame
	step(DT)
	check("los: wall blocks the hover", lock.hover == null)
	w.free()
	await get_tree().physics_frame
	step(DT)
	step(DT, true, true)
	w = wall(Vector3(0, 1.5, -3), Vector3(4, 3, 0.3))
	await get_tree().physics_frame
	step(2.0, false, true)
	check("los: lock holds through a wall", lock.target == e)
	# Hold mode: tap-tap takes the next one; a slow re-press the best again.
	clear()
	lock.switch_mode = false
	a = target(Targetable.Kind.ENEMY, Vector3(0, 0, -5))
	b = target(Targetable.Kind.ENEMY, Vector3(2, 0, -8))
	await get_tree().physics_frame
	step(DT)
	step(0.6, true, true)
	check("hold: locks nearest", lock.target == a and lock.active())
	check("hold: arrow on the next", lock.hover == b)
	step(DT * 2)  # let go
	check("hold: reticle off at once", not lock.active())
	step(DT, true, true)
	check("hold: tap-tap moves to the next", lock.target == b)
	step(0.6, false, true)
	step(DT * 2)
	step(0.3)
	check("hold: lock gone 0.25 s after letting go", lock.target == null)
	step(DT, true, true)
	check("hold: slow re-press takes the best again", lock.target == a)
	step(0.6, false, true)
	# Pressing while held with an other target: next.
	step(DT, true, true)
	check("hold: press while locked moves on", lock.target == b)
	step(0.5)
	# Hold, one target, tap-tap: the old lock stays.
	clear()
	a = target(Targetable.Kind.ENEMY, Vector3(0, 0, -5))
	await get_tree().physics_frame
	step(DT)
	step(0.6, true, true)
	step(DT * 2)
	step(DT, true, true)
	step(0.1, false, true)
	check("hold: tap-tap with one target keeps it", lock.target == a and lock.active())
	# Switch mode.
	clear()
	lock.switch_mode = true
	a = target(Targetable.Kind.ENEMY, Vector3(0, 0, -5))
	b = target(Targetable.Kind.ENEMY, Vector3(2, 0, -8))
	await get_tree().physics_frame
	step(DT)
	step(DT, true, true)
	step(1.0)
	check("switch: latched after letting go", lock.target == a and lock.active())
	step(DT, true, true)
	step(0.1)
	check("switch: press moves on", lock.target == b)
	step(0.6)
	step(DT, false, false, true)
	step(DT, true, true, true)
	step(0.1, false, false, true)
	check("switch: stick back + press lets go", lock.target == null)
	b.enabled = false
	step(DT)
	step(DT, true, true)
	step(0.1)
	step(DT, true, true)
	step(0.1)
	check("switch: press with nothing else lets go", lock.target == null)
	lock.switch_mode = false
	# Parallel, squared to a wall.
	clear()
	wall(Vector3(0, 1, -0.6), Vector3(4, 2, 0.2))
	p.facing = Vector3(0.5, 0, -1).normalized()  # 27° off the wall
	await get_tree().physics_frame
	step(DT)
	step(DT, true, true)
	check("parallel: on with nothing to lock", lock.parallel)
	check("parallel: squared up to the wall", lock.parallel_facing.distance_to(Vector3(0, 0, -1)) < 0.01)
	step(DT)
	check("parallel: off on letting go", not lock.parallel)
	# Death: a disabled target drops the lock.
	clear()
	e = target(Targetable.Kind.ENEMY, Vector3(0, 0, -5))
	await get_tree().physics_frame
	step(DT)
	step(DT, true, true)
	e.enabled = false
	step(DT, false, true)
	check("death: lock released", lock.target == null)
	# Next target weighting: ahead x0.6 beats a nearer one off to the side.
	clear()
	e = target(Targetable.Kind.ENEMY, Vector3(0, 0, -3))
	a = target(Targetable.Kind.ENEMY, Vector3(0, 0, -7.5))  # ahead (through the locked one): 7.5 x sqrt(0.6) = 5.8
	b = target(Targetable.Kind.ENEMY, Vector3(-6.2, 0, -0.2))  # ~88° off: ~6.2
	await get_tree().physics_frame
	step(DT)
	step(DT, true, true)
	step(0.3, false, true)
	check("next: ahead weighted over side", lock.target == e and lock.hover == a)
	# Battle music: nearest hostile enemy within 20 m, behind or through walls; bosses don't.
	clear()
	e = target(Targetable.Kind.ENEMY, Vector3(0, 0, 10))  # behind
	wall(Vector3(0, 1.5, 5), Vector3(4, 3, 0.3))
	await get_tree().physics_frame
	step(DT)
	check("battle: enemy behind a wall counts", lock.bgm_enemy == e)
	check("battle: level at 10 m = 0.71", absf(lock.battle_level - (1.0 - 4.0 / 14.0)) < 0.01)
	p.global_position = Vector3(0, 0, 7)  # 3 m
	step(DT)
	check("battle: full within 6 m", is_equal_approx(lock.battle_level, 1.0))
	p.global_position = Vector3(0, 0, -12)  # 22 m
	step(DT)
	check("battle: none past 20 m", lock.bgm_enemy == null and lock.battle_level == 0.0)
	clear()
	var boss := target(Targetable.Kind.BOSS, Vector3(0, 0, -8))
	var friend := target(Targetable.Kind.ENEMY, Vector3(1, 0, -6))
	friend.hostile = false
	await get_tree().physics_frame
	step(DT)
	check("battle: bosses and friendly enemies don't", lock.bgm_enemy == null)
	step(DT, true, true)
	check("hostile: friendly enemy lock is not hostile", lock.target == friend and not lock.hostile())
	step(0.6, false, true)
	step(DT, true, true)
	check("hostile: boss lock is", lock.target == boss and lock.hostile())
