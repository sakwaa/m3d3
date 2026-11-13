extends Node
# Z-targeting marks render: two enemies, an NPC, a sign; the real player (not scripted) is
# driven through Input: arrow before pressing, lock fly-in, tap-tap to the next enemy, let
# go, enemies gone (arrow to the NPC, blue), lock the NPC. OUT=dir saves every other frame.
var p: Actor
var t := 0.0
var frame := 0
var enemies: Array[Targetable] = []
var script_steps := [[0.6, "press"], [1.8, "release"], [1.9, "press"], [3.0, "release"], [3.4, "clear"], [3.9, "press"], [5.0, "release"], [5.6, "end"]]

func dummy(at: Vector3, kind: int, color: Color, h := 1.6) -> Targetable:
	var n := Node3D.new(); n.position = at; add_child(n)
	var mi := MeshInstance3D.new(); var m := CapsuleMesh.new(); m.height = h; m.radius = 0.3; mi.mesh = m
	mi.position.y = h * 0.5
	var mat := StandardMaterial3D.new(); mat.albedo_color = color; mi.material_override = mat
	n.add_child(mi)
	var tg := Targetable.new(); tg.kind = kind; tg.position.y = h * 0.85; n.add_child(tg)
	return tg

func _ready() -> void:
	var floor := StaticBody3D.new(); var cs := CollisionShape3D.new(); var sh := BoxShape3D.new(); sh.size = Vector3(60, 1, 60)
	cs.shape = sh; floor.add_child(cs); floor.position.y = -0.5; add_child(floor)
	var fm := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = sh.size; fm.mesh = bm; floor.add_child(fm)
	var fmat := StandardMaterial3D.new(); fmat.albedo_color = Color(0.45, 0.55, 0.35); fm.material_override = fmat
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.5, 0.6, 0.75)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment = e; add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 30, 0); add_child(sun)
	enemies.append(dummy(Vector3(-1.0, 0, -5), Targetable.Kind.ENEMY, Color(0.7, 0.25, 0.2)))
	enemies.append(dummy(Vector3(2.2, 0, -8), Targetable.Kind.ENEMY, Color(0.7, 0.25, 0.2)))
	dummy(Vector3(0.8, 0, -2.6), Targetable.Kind.NPC, Color(0.3, 0.4, 0.8))
	dummy(Vector3(-1.6, 0, -2.0), Targetable.Kind.POI, Color(0.55, 0.4, 0.25), 1.0)
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.facing = Vector3(0, 0, -1)

func _physics_process(delta: float) -> void:
	t += delta
	while not script_steps.is_empty() and t >= script_steps[0][0]:
		var s: String = script_steps.pop_front()[1]
		print("%.2f %s" % [t, s])
		match s:
			"press": Input.action_press(&"target")
			"release": Input.action_release(&"target")
			"clear":
				for e in enemies: e.enabled = false
			"end": get_tree().quit()
	var out := OS.get_environment("OUT")
	if out != "":
		frame += 1
		if frame % 2 == 0:
			get_viewport().get_texture().get_image().save_png("%s/f_%04d.png" % [out, frame / 2])
	if frame % 12 == 0:
		var l: TargetLock = p.lock
		print("%.2f target=%s hover=%s active=%s" % [t, l.target.get_parent().position if l.target else "-", l.hover.get_parent().position if l.hover else "-", l.active()])
