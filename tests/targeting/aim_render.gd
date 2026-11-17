extends Node
## Bow aiming (AimState / AimRig / CameraDirector aim / Arrow): the real player, a dummy 3 m
## ahead and one 12 m out to the right. Holds Aim, shoots the near one, turns to the far one,
## shoots, lets go. Prints each shot: where the reticle pointed vs where the arrow hit, and
## the dummies' health. OUT=dir saves every 3rd frame (and the frame numbers of the events).
##   OUT=dir tools/godot_run.sh --path . --resolution 960x540 --fixed-fps 60 tests/targeting/aim_render.tscn

var p: Actor
var near: CombatDummy
var far: CombatDummy
var t := 0.0
var frame := 0
var steps := [[0.6, "aim"], [1.15, "snap"], [1.3, "attack"], [1.36, "snap_ready"], [1.8, "turn"], [2.6, "attack"], [3.4, "release"], [4.2, "end"]]
var _turning := false
var _shots := []


func _ready() -> void:
	var floor := StaticBody3D.new(); var cs := CollisionShape3D.new(); var sh := BoxShape3D.new(); sh.size = Vector3(60, 1, 60)
	cs.shape = sh; floor.add_child(cs); floor.position.y = -0.5; add_child(floor)
	var fm := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = sh.size; fm.mesh = bm; floor.add_child(fm)
	var fmat := StandardMaterial3D.new(); fmat.albedo_color = Color(0.4, 0.45, 0.35); fm.material_override = fmat
	# A wall far behind the targets (arrows that miss stick in it).
	var wall := StaticBody3D.new(); var wcs := CollisionShape3D.new(); var wsh := BoxShape3D.new(); wsh.size = Vector3(60, 8, 1)
	wcs.shape = wsh; wall.add_child(wcs); wall.position = Vector3(0, 4, -24); add_child(wall)
	var wm := MeshInstance3D.new(); var wbm := BoxMesh.new(); wbm.size = wsh.size; wm.mesh = wbm; wall.add_child(wm)
	var wmat := StandardMaterial3D.new(); wmat.albedo_color = Color(0.55, 0.5, 0.45); wm.material_override = wmat
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.45, 0.55, 0.7)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.environment = e; add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 30, 0); add_child(sun)
	near = _dummy(Vector3(0, 0.1, -3.0))
	far = _dummy(Vector3(7.0, 0.1, -10.0))
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.facing = Vector3(0, 0, -1)
	Actor.show_debug = false


func _dummy(at: Vector3) -> CombatDummy:
	var d := CombatDummy.new()
	d.position = at
	d.respawn = 99.0
	d.rooted = true
	d.profile = EnemyProfile.new()
	d.profile.max_health = 9
	add_child(d)
	return d


func _physics_process(delta: float) -> void:
	t += delta
	while not steps.is_empty() and t >= steps[0][0]:
		var s: String = steps.pop_front()[1]
		match s:
			"aim":
				Input.action_press(&"aim")
				_mark("aim")
			"attack":
				var a := p.state_of(Actor.ACTION) as AimState
				if a:
					_shots.append({at = t, aim_point = a.aim_point, aim_actor = a.aim_actor.name if a.aim_actor else "-", shots = a.shots})
				Input.action_press(&"attack")
				get_tree().create_timer(0.05).timeout.connect(func(): Input.action_release(&"attack"))
				_mark("fire")
			"turn":
				_turning = true
			"snap_ready":
				_snaps("ready_")
			"snap":
				for k in p.aim_rig.ik_report:
					var r: Dictionary = p.aim_rig.ik_report[k]
					print("[ik] %s miss %.3f  shoulder %s elbow %s (want %s) hand %s target %s" % [k, r.miss, r.shoulder, r.elbow, r.elbow_want, r.hand, r.target])
				_snaps()
			"release":
				Input.action_release(&"aim")
				_mark("release")
			"end":
				_report()
				get_tree().quit()
	if _turning:
		# Swing the rig's yaw (as the mouse would) until the reticle is on the far dummy.
		var d: CameraDirector = p.director
		var to := far.global_position + Vector3.UP * 1.0 - (p.global_position + Vector3.UP * 1.45)
		var want := atan2(-to.x, -to.z)
		d.yaw.global_rotation.y = lerp_angle(d.yaw.global_rotation.y, want, 0.15)
		d.pitch.rotation.x = lerpf(d.pitch.rotation.x, atan2(to.y, Vector2(to.x, to.z).length()), 0.15)
		if absf(wrapf(d.yaw.global_rotation.y - want, -PI, PI)) < 0.01:
			_turning = false
	for n in get_children():
		if n is Arrow and not n.has_meta(&"seen") and n.get(&"_stuck"):
			n.set_meta(&"seen", true)
			print("[aim] arrow stuck at %s" % n.global_position)
	var out := OS.get_environment("OUT")
	if out != "":
		frame += 1
		if frame % 3 == 0:
			get_viewport().get_texture().get_image().save_png("%s/f_%04d.png" % [out, frame])


func _mark(what: String) -> void:
	print("[aim] %.2f %s (frame %d)" % [t, what, frame])


func _report() -> void:
	for s in _shots:
		print("[aim] shot at %.2f: reticle on %s at %s" % [s.at, s.aim_actor, s.aim_point])
	print("[aim] near dummy health %d/9, far dummy health %d/9" % [near.health, far.health])
	var a := p.state_of(Actor.ACTION)
	print("[aim] action now %s" % (a.name if a else "-"))


## Side, front and three-quarter views of the held aim (OUT/pose_*.png), then back.
func _snaps(prefix := "") -> void:
	var out := OS.get_environment("OUT")
	if out == "":
		return
	var main := get_viewport().get_camera_3d()
	var cam := Camera3D.new()
	cam.fov = 40.0
	add_child(cam)
	var c := p.global_position + Vector3.UP * 1.0
	for v in [["side", Vector3(3.2, 0.4, 0)], ["front", Vector3(0.6, 0.3, -3.2)], ["quarter", Vector3(-2.4, 0.8, 2.0)], ["top", Vector3(0.3, 3.4, 0.3)], ["behind", Vector3(0.9, 0.6, 2.6)]]:
		cam.global_position = c + v[1]
		cam.look_at(c)
		cam.make_current()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/%spose_%s.png" % [out, prefix, v[0]])
	main.make_current()
	cam.queue_free()
