extends Node
var cam: Camera3D
var shots := []
var shot_i := 0
var _benched := false
var _phys := []
var _poselog := PackedStringArray()
# Climb phases test: leap, ledge hang, ceiling, grip, fall damage.
var p: Actor
var t := 0.0
var phase := -1
var log_t := 0.0
var steps := []  # [until_time, move, label, press]
const C := Surface.CLIMBABLE

func box(pos: Vector3, size: Vector3, surface: int) -> void:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new(); sh.size = size
	cs.shape = sh; cs.set_meta(Surface.META, surface)
	b.add_child(cs); b.position = pos
	add_child(b)

func _ready() -> void:
	box(Vector3(0, -0.5, 0), Vector3(200, 1, 200), 0)
	# Leap up: climbable 0-3, plain 3-4.2, climbable 4.2-8 (face z=0.5).
	box(Vector3(32, 1.5, 0), Vector3(4, 3, 1), C)
	box(Vector3(32, 3.6, 0), Vector3(4, 1.2, 1), 0)
	box(Vector3(32, 6.1, 0), Vector3(4, 3.8, 1), C)
	# Leap sideways: climbable x44-47, plain 47-48.4, climbable 48.4-52.
	box(Vector3(45.5, 3, 0), Vector3(3, 6, 1), C)
	box(Vector3(47.7, 3, 0), Vector3(1.4, 6, 1), 0)
	box(Vector3(50.2, 3, 0), Vector3(3.6, 6, 1), C)
	# Ledge block (plain): top 2.6, front face z=1.
	box(Vector3(24, 1.3, 0), Vector3(4, 2.6, 2), 0)
	# Ceiling slab (climbable) y 3.5-4 over z 7..13, climbable wall at its far end (face z=13).
	box(Vector3(40, 3.75, 10), Vector3(6, 0.5, 6), C)
	box(Vector3(40, 2, 13.5), Vector3(6, 4, 1), C)
	# Vines up to a bare wall with a ledge: climbable 0-3, plain 3-4 (top 4).
	box(Vector3(70, 1.5, 0), Vector3(4, 3, 1), C)
	box(Vector3(70, 3.5, 0), Vector3(4, 1, 1), 0)
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.5, 0.6, 0.75)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment = e; add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 30, 0); add_child(sun)
	# Show the boxes.
	for b in get_children():
		if b is StaticBody3D:
			var cs: CollisionShape3D = b.get_child(0)
			var mi := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = cs.shape.size; mi.mesh = bm
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(0.3, 0.6, 0.25) if cs.get_meta(Surface.META) & C else Color(0.6, 0.58, 0.55)
			mi.material_override = m; b.add_child(mi)
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	cam = Camera3D.new(); cam.fov = 50; add_child(cam)
	var st := OS.get_environment("SHOTS")
	if st != "":
		for x in st.split(","): shots.append(float(x))
	if OS.get_environment("LOGST") != "": p.debug_log = true
	if OS.get_environment("NOLABEL") != "": Actor.show_debug = false
	if OS.get_environment("POSELOG") != "":
		var rig = p.find_children("*", "ClimbRig", true, false)[0]
		rig.modification_processed.connect(func():
			if p.state_of(&"Locomotion").name != &"Climb":
				return
			# Side-plane joints after the IK (x: off the wall, y: up), metres.
			var sk: Skeleton3D = rig.get_skeleton()
			var out := PackedStringArray()
			for b in ["head", "upper_arm_L", "forearm_L", "hand_L", "upper_arm_R", "forearm_R", "hand_R", "thigh_L", "shin_L", "foot_L", "thigh_R", "shin_R", "foot_R"]:
				var w: Vector3 = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(b)).origin
				out.append("%.3f,%.3f" % [w.z, w.y])
			_poselog.append("%.4f;%s" % [t, ";".join(out)]))
	if OS.get_environment("HEADLOG") != "":
		var rig2 = p.find_children("*", "ClimbRig", true, false)[0]
		rig2.modification_processed.connect(func():
			if p.state_of(&"Locomotion").name != &"Climb":
				return
			var sk: Skeleton3D = rig2.get_skeleton()
			var hi := sk.find_bone(&"head")
			var fl: Vector3 = (sk.get_bone_global_rest(hi).basis.inverse() * Vector3.FORWARD).normalized()
			var d: Vector3 = (sk.global_transform.basis * sk.get_bone_global_pose(hi).basis * fl).normalized()
			_poselog.append("%.4f;%.4f,%.4f,%.4f" % [t, d.x, d.y, d.z]))
	print("rig: ", p.find_children("*", "ClimbRig", true, false))
	p.scripted = true
	var F := Vector3(0, 0, -1)
	match OS.get_environment("CLIMB_TEST"):
		"leap":
			p.global_position = Vector3(32, 0, 3)
			steps = [[2.6, F, "climb to the plain band"], [2.62, F, "leap up", &"jump"], [4.0, Vector3.ZERO, "hold"], [5.0, F, "climb on"]]
		"leapside":
			p.global_position = Vector3(46, 0, 3)
			steps = [[1.5, F, "grab+up"], [2.6, Vector3(1, 0, 0), "right to the gap"], [3.0, Vector3(1, 0, 0), "leap right", &"jump"], [4.0, Vector3.ZERO, "hold"]]
		"back":
			p.global_position = Vector3(46, 0, 3)
			steps = [[1.8, F, "grab+up"], [1.82, Vector3(0, 0, 1), "back jump", &"jump"], [3.5, Vector3.ZERO, "air"]]
		"ledge":
			p.global_position = Vector3(24, 0, 2.6)
			steps = [[0.25, F, "run"], [0.27, F, "jump", &"jump"], [1.4, Vector3.ZERO, "catch"], [4.5, Vector3(1, 0, 0), "shimmy right + corner"], [5.0, Vector3.ZERO, "hold"], [5.02, Vector3.ZERO, "pull up", &"jump"], [6.5, Vector3.ZERO, "on top"]]
		"ceiling":
			p.global_position = Vector3(40, 0, 9)
			steps = [[0.1, Vector3.ZERO, "stand"], [0.12, Vector3.ZERO, "jump", &"jump"], [1.2, Vector3.ZERO, "catch ceiling"], [5.0, Vector3(0, 0, 1), "hang forward into wall"], [6.0, Vector3.ZERO, "hold"]]
		"top":
			p.global_position = Vector3(46, 0, 3)
			steps = [[9.0, Vector3(0, 0, -1), "climb to the top and over"], [9.5, Vector3.ZERO, "stand"]]
		"grip":
			p.global_position = Vector3(46, 0, 3)
			steps = [[1.2, F, "grab"], [1.22, Vector3.ZERO, "low grip", &"lowgrip"], [6.0, Vector3.ZERO, "hold till empty"], [8.0, Vector3.ZERO, "refill on ground"]]
		"fall":
			p.global_position = Vector3(10, 14, 10)
			steps = [[3.0, Vector3.ZERO, "drop 14m"]]
		"vineledge":
			p.global_position = Vector3(70, 0, 3)
			steps = [[3.0, F, "climb to bare wall"], [4.5, F, "hang + pull up"], [5.0, Vector3.ZERO, "hold"]]

func _physics_process(delta: float) -> void:
	t += delta
	while phase + 1 <= steps.size() and (phase < 0 or t > steps[phase][0]):
		phase += 1
		if phase < steps.size():
			print("--- ", steps[phase][2])
			if steps[phase].size() > 3:
				match steps[phase][3]:
					&"lowgrip": p.grip.value = 2.0
					var b: p.intent.press(b)
	if phase >= steps.size():
		if OS.get_environment("BENCH") != "":
			var acc := {}
			for e in _phys:
				if not acc.has(e[0]): acc[e[0]] = [0.0, 0]
				acc[e[0]][0] += e[1]; acc[e[0]][1] += 1
			for k in acc: print("BENCH player tick ms %s: %.3f (%d ticks)" % [k, acc[k][0] / acc[k][1], acc[k][1]])
		if OS.get_environment("POSELOG") != "" or OS.get_environment("HEADLOG") != "":
			var fh := FileAccess.open(OS.get_environment("POSELOG") + OS.get_environment("HEADLOG"), FileAccess.WRITE)
			fh.store_string("\n".join(_poselog))
		get_tree().quit()
		return
	p.intent.move = steps[phase][1]
	if cam:
		cam.make_current()
		var o := p.global_position
		var side := p.facing.cross(Vector3.UP).normalized()
		cam.global_position = o - p.facing * 2.6 + side * 1.6 + Vector3.UP * 1.6
		if OS.get_environment("CAMLOW") != "":
			cam.global_position = o - p.facing * 3.4 + Vector3.UP * 0.1
		if OS.get_environment("CAMBACK") != "":
			cam.global_position = o - p.facing * 3.2 + Vector3.UP * 1.3
		if OS.get_environment("CAMSIDE") != "":
			cam.global_position = o + side * 3.0 - p.facing * 0.8 + Vector3.UP * 1.2
		cam.look_at(o + Vector3.UP * (1.4 if OS.get_environment("CAMLOW") != "" else 1.1))
	if OS.get_environment("BENCH") != "":
		var st: StringName = p.state_of(&"Locomotion").name
		if p.is_physics_processing():
			p.set_physics_process(false)  # driven by hand below, timed
		var t1 := Time.get_ticks_usec()
		p._physics_process(delta)
		_phys.append([st, (Time.get_ticks_usec() - t1) / 1000.0])
		if not _benched and st == &"Climb" and t > 2.0:
			_benched = true
			var rig = p.find_children("*", "ClimbRig", true, false)[0]
			var t0 := Time.get_ticks_usec()
			for k in 2000:
				rig._process_modification_with_delta(1.0 / 60.0)
			print("BENCH rig us/call %.1f" % [(Time.get_ticks_usec() - t0) / 2000.0])
	if shot_i < shots.size() and t >= shots[shot_i]:
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/shot_%s_%d.png" % [OS.get_environment("OUT"), OS.get_environment("CLIMB_TEST"), shot_i])
		shot_i += 1
	log_t += delta
	if log_t >= 0.2:
		log_t = 0.0
		print("%.1f %s pos=(%.2f,%.2f,%.2f) f=(%.2f,%.2f) grip=%.1f hp=%d" % [t, p.state_of(&"Locomotion").name, p.global_position.x, p.global_position.y, p.global_position.z, p.facing.x, p.facing.z, p.grip.value, p.health])
