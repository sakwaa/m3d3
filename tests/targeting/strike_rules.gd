extends Node
# Strike points (headless): a frozen Wolfos struck from the front, the side and behind
# (aimed at / landed on), the same guarding (front turns the blade, side doesn't), and the
# shield dummy. Prints PASS / FAIL.
const WOLFOS := preload("res://game/actors/enemies/wolfos/wolfos.gd")
var p: Actor
var fails := 0
var log_lines: Array[String] = []
var cam: Camera3D
var focus: Actor
var frame := 0

func _ready() -> void:
	Actor.show_debug = true
	var floor := StaticBody3D.new(); var cs := CollisionShape3D.new(); var sh := BoxShape3D.new(); sh.size = Vector3(60, 1, 60)
	cs.shape = sh; floor.add_child(cs); floor.position.y = -0.5; add_child(floor)
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.global_position = Vector3(0, 0, 8)
	p.scripted = true
	if OS.get_environment("OUT") != "":
		# Rendering: a side camera on each strike, every frame saved (run with --fixed-fps 60).
		var env := WorldEnvironment.new(); var e := Environment.new()
		e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.5, 0.6, 0.75)
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.6, 0.6, 0.65)
		env.environment = e; add_child(env)
		var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 30, 0); add_child(sun)
		var fm := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = Vector3(60, 1, 60); fm.mesh = bm; fm.position.y = -0.5
		var fmat := StandardMaterial3D.new(); fmat.albedo_color = Color(0.42, 0.5, 0.36); fm.material_override = fmat; add_child(fm)
		cam = Camera3D.new(); cam.fov = 45; add_child(cam)
		Actor.show_debug = false
	await _settle(10)
	await _run()
	print("DONE fails=%d" % fails)
	get_tree().quit()

func _settle(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _physics_process(_delta: float) -> void:
	if cam == null or not is_instance_valid(focus):
		return
	cam.make_current()
	var mid := (focus.global_position + p.global_position) * 0.5
	var across := (focus.global_position - p.global_position)
	across.y = 0.0
	var side := across.normalized().cross(Vector3.UP) if across.length() > 0.1 else Vector3.RIGHT
	cam.global_position = mid + side * 3.6 + Vector3.UP * 1.3
	cam.look_at(mid + Vector3.UP * 0.9)
	frame += 1
	get_viewport().get_texture().get_image().save_png("%s/f_%04d.png" % [OS.get_environment("OUT"), frame])

func check(name: String, ok: bool, extra := "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ("  (%s)" % extra if extra else ""))
	if not ok:
		fails += 1

func target(kind: String, guard := false) -> Actor:
	var a: Actor
	if kind == "wolfos":
		a = WOLFOS.new()
	else:
		a = CombatDummy.new()
		a.shield = kind == "dummy"
		a.armored = kind == "armored"
	a.position = Vector3.ZERO
	add_child(a)
	await _settle(3)
	a.set_physics_process(false)  # posed: no AI, no moving
	if guard:
		a.intent.hold(&"guard", true)
		a.machine(&"Action").request(&"Guard", true)
		a.machine(&"Action").tick(0.0)
	a.health = 99
	focus = a
	return a

## Swings from `local` (in the target's body space: -Z its front), facing it: [aimed part, outcome].
func swing(a: Actor, local: Vector3) -> Array:
	var from: Vector3 = a.body.global_transform * local
	from.y = 0.0
	p.global_position = from
	p.velocity = Vector3.ZERO
	p.impulse = Vector3.ZERO
	var to := a.global_position - from
	to.y = 0.0
	p.facing = to.normalized()
	p.face_target = a.targetable
	p.machine(&"Action").request(&"Ready", true)
	p.counter_left = 0.0
	await _settle(20)
	for i in 120:
		if p.is_on_floor() and p.state_of(&"Locomotion").name == &"Idle":
			break
		await get_tree().physics_frame
	p._sheathe(false)  # (scripted: drive() isn't drawing it)
	var hp := a.health
	if OS.get_environment("DEBUG") != "":
		print("  before: loco=%s floor=%s y=%.2f tags=%s" % [p.state_of(&"Locomotion").name, p.is_on_floor(), p.global_position.y, p.has_tag(&"airborne")])
	p.intent.press(&"attack")
	await _settle(2)
	var s := p.state_of(&"Action") as AttackState
	var aimed: String = s.aim.part if s and s.aim else "-"
	var outcome := "miss"
	for i in 50:
		await get_tree().physics_frame
		if OS.get_environment("DEBUG") != "":
			var st = p.state_of(&"Action")
			var aa = p.active_attack()
			print("  f%d %s p=%.2f active=%s reach=%s d=%.2f blade=%d" % [i, st.name, st.progress(), aa != null, st.reaches(a) if st is AttackState else false,
				Vector2(a.global_position.x - p.global_position.x, a.global_position.z - p.global_position.z).length(), p.blade().size()])
		if a.health < hp:
			outcome = "hit %d" % (hp - a.health)
			break
		if p.state_of(&"Action").name == &"Recoil":
			outcome = "turned"
			break
	await _settle(40)
	return [aimed, outcome]

func _run() -> void:
	var w := await target("wolfos")
	# The Wolfos faces -Z: its front is towards -Z.
	var r := await swing(w, Vector3(0, 0, -2.0))
	check("front: aims at the head", r[0] == "head", str(r))
	check("front: head hit for double (vertical 2 x 2)", r[1] == "hit 4", str(r))
	r = await swing(w, Vector3(-2.0, 0, 0))
	check("left side: aims at the left flank", r[0] == "left flank", str(r))
	check("left side: lands", r[1] == "hit 2", str(r))
	r = await swing(w, Vector3(2.0, 0, 0))
	check("right side: right flank", r[0] == "right flank", str(r))
	r = await swing(w, Vector3(0, 0, 2.2))
	check("behind: haunch", r[0] == "haunch", str(r))
	w.queue_free()
	await _settle(2)
	var g := await target("wolfos", true)
	r = await swing(g, Vector3(0, 0, -2.0))
	check("guarding, front: claws turn the blade", r[1] == "turned", str(r))
	r = await swing(g, Vector3(-2.0, 0, 0))
	check("guarding, side: lands on the flank", r[1].begins_with("hit"), str(r))
	g.queue_free()
	await _settle(2)
	var d := await target("dummy", true)
	r = await swing(d, Vector3(0, 0, -1.8))
	check("shield dummy, front: shield turns it", r[1] == "turned", str(r))
	r = await swing(d, Vector3(1.8, 0, 0))
	check("shield dummy, side: lands", r[1].begins_with("hit"), str(r))
	d.queue_free()
	await _settle(2)
	# Sword power vs armour (hardness 2): the practice sword (1) bounces off, a power 3 blade
	# cuts through.
	var k := await target("armored")
	r = await swing(k, Vector3(0, 0, -1.8))
	check("armour vs power 1: turned", r[1] == "turned", str(r))
	p._sword_trigger().power = 3
	r = await swing(k, Vector3(0, 0, -1.8))
	check("armour vs power 3: cuts through", r[1].begins_with("hit"), str(r))
	p._sword_trigger().power = 1
