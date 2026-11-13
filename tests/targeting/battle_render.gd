extends Node
# Battle render: the real player against two Wolfos, played by a simple script through
# Input (holds Z on the nearest, closes in, swings, raises the shield when one winds up a
# claw, strafes now and then). Run with --fixed-fps 60; OUT=dir saves every other frame.
const WOLFOS := preload("res://game/actors/enemies/wolfos/wolfos.gd")
var p: Actor
var t := 0.0
var frame := 0
var _swing_cd := 0.0
var _strafe := 0.0
var _held: Array[StringName] = []

func _ready() -> void:
	Actor.show_debug = false
	var floor := StaticBody3D.new(); var cs := CollisionShape3D.new(); var sh := BoxShape3D.new(); sh.size = Vector3(60, 1, 60)
	cs.shape = sh; floor.add_child(cs); floor.position.y = -0.5; add_child(floor)
	var fm := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = sh.size; fm.mesh = bm; floor.add_child(fm)
	var fmat := StandardMaterial3D.new(); fmat.albedo_color = Color(0.42, 0.5, 0.36); fm.material_override = fmat
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.5, 0.6, 0.75)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment = e; add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 30, 0); sun.shadow_enabled = true; add_child(sun)
	for x in [-1.5, 2.0]:
		var w: Node3D = WOLFOS.new()
		w.position = Vector3(x, 0.1, -6.0 - absf(x))
		add_child(w)
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.facing = Vector3(0, 0, -1)

func hold(a: StringName, on: bool) -> void:
	if on and not _held.has(a):
		Input.action_press(a); _held.append(a)
	elif not on and _held.has(a):
		Input.action_release(a); _held.erase(a)

func tap(a: StringName) -> void:
	Input.action_press(a)
	get_tree().create_timer(0.05).timeout.connect(func(): Input.action_release(a))

func _physics_process(delta: float) -> void:
	t += delta
	_swing_cd -= delta
	_strafe -= delta
	var lock: TargetLock = p.lock
	hold(&"target", t > 0.3)
	var tgt: Actor = lock.target.actor() if lock.target else null
	var guard := false
	var near := false
	if tgt:
		var d := tgt.global_position.distance_to(p.global_position)
		near = d < 2.3
		var claw = tgt.state_of(&"Action")
		guard = claw is AttackState and (claw.in_window(&"windup") or claw.in_window(&"active")) and d < 3.5
		if _strafe < -2.5:
			_strafe = 0.6
		hold(&"move_forward", d > 1.5 and not guard and _strafe <= 0.0)
		hold(&"move_right", _strafe > 0.0 and not near)
		if near and not guard and _swing_cd <= 0.0:
			tap(&"attack")
			_swing_cd = 0.32
	else:
		hold(&"move_forward", false); hold(&"move_right", false)
	hold(&"guard", guard)
	if t > 14.0:
		get_tree().quit()
	var out := OS.get_environment("OUT")
	if out != "":
		frame += 1
		if frame % 2 == 0:
			get_viewport().get_texture().get_image().save_png("%s/f_%04d.png" % [out, frame / 2])
