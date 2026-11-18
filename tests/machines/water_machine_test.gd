extends Node
## The forest citadel's opening machine, in a sandbox: a stream with a side channel and a
## fork gate across it (ScrewGate), a capstan on the bank (Capstan) that raises the gate, the
## side channel's water (MachineWater) following the gate up a step a turn, a noria (Noria) in
## the side channel that only turns once the gate is all the way open, its trough and an
## aqueduct into a tall wall, and two blocks in the wall's doorway (MachineDoor) that shift
## aside once the wheel runs.
## Wiring (MachineBus channels): capstan -> "capstan" -> gate -> "gate" -> side water -> "side"
## -> noria -> "wheel" -> aqueduct water + door blocks.
## The player takes hold of a capstan spoke and keeps pushing (scripted). Checks after each
## full turn: gate open k/turns, the water matching it, the wheel still; once fully open: the
## wheel runs, the doorway opens. Prints MACHINE PASS / FAIL.
##   OUT=dir (frames) [EVERY=n] godot --path . --resolution 1280x720 tests/machines/water_machine_test.tscn

const FLOOR_TEX := "res://textures/rock/cobblestone_square.res"
const ROCK_TEX := "res://textures/rock/granite_1.res"
const SHADER := "res://addons/n64_runtime/shaders/n64_textured.gdshader"

var out := ""
var every := 3
var fails := 0
var cap: Capstan
var gate: ScrewGate
var side: MachineWater
var wheel: Noria
var doors: Array[MachineDoor] = []
var cam: Camera3D
var _frame := 0


func _ready() -> void:
	out = OS.get_environment("OUT")
	if OS.get_environment("EVERY") != "":
		every = int(OS.get_environment("EVERY"))
	GameState.set_time(12.0)
	var zone := Zone.new()
	zone.name = "MachineYard"
	zone.intro = false
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.5, 0.62, 0.72)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.8, 0.8, 0.8)
	zone.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.6, 0)
	zone.add_child(sun)
	var ground := _mat(FLOOR_TEX, Color(0.7, 0.68, 0.6), Vector2(8, 8))
	var rock := _mat(ROCK_TEX, Color(0.62, 0.58, 0.52), Vector2(4, 4))
	# Ground at 0 with two channels 2 m deep along Z: the main stream (x 0..4) and the side
	# channel (x 8..11); banks between and either side; channel floors.
	for r in [[-20.0, 0.0], [4.0, 8.0], [11.0, 20.0]]:
		_box(zone, Vector3((r[0] + r[1]) * 0.5, -1.0, 0.0), Vector3(r[1] - r[0], 2.0, 40.0), ground)
	for r in [[0.0, 4.0], [8.0, 11.0]]:
		_box(zone, Vector3((r[0] + r[1]) * 0.5, -2.5, 0.0), Vector3(r[1] - r[0], 1.0, 40.0), rock)
	# The tall wall (x 20..22) with a 4 x 4 m doorway at z -2..2, and the aqueduct into it.
	_box(zone, Vector3(21.0, 6.0, -11.0), Vector3(2.0, 12.0, 18.0), rock)
	_box(zone, Vector3(21.0, 6.0, 11.0), Vector3(2.0, 12.0, 18.0), rock)
	_box(zone, Vector3(21.0, 8.0, 0.0), Vector3(2.0, 8.0, 4.0), rock)
	var main := MachineWater.new()
	main.size = Vector2(4.0, 40.0)
	main.flow = 1.0
	main.position = Vector3(2.0, -0.6, 0.0)
	zone.add_child(main)
	cap = Capstan.new()
	cap.output = &"capstan"
	cap.turns = 3
	cap.position = Vector3(14.0, 0.0, 12.0)
	zone.add_child(cap)
	gate = ScrewGate.new()
	gate.input = &"capstan"
	gate.output = &"gate"
	gate.width = 3.0
	gate.height = 2.0
	gate.position = Vector3(9.5, -2.0, 10.0)
	zone.add_child(gate)
	side = MachineWater.new()
	side.input = &"gate"
	side.output = &"side"
	side.size = Vector2(3.0, 20.0)
	side.low = 0.02
	side.high = 1.6
	side.flow = 1.0
	side.position = Vector3(9.5, -2.0, 0.0)
	zone.add_child(side)
	wheel = Noria.new()
	wheel.input = &"side"
	wheel.output = &"wheel"
	wheel.radius = 5.0
	wheel.dip = 0.0
	wheel.trough_length = 6.0
	wheel.position = Vector3(9.5, -1.4, -2.0)
	zone.add_child(wheel)
	# The aqueduct from the trough's end into the wall, high up (a channel into it), its water.
	var crest_y := -1.4 + wheel.axle_height() + wheel.radius - 0.9 - 0.2
	_box(zone, Vector3(17.75, crest_y, -1.1), Vector3(4.5, 0.35, 1.0), rock)
	var aq := MachineWater.new()
	aq.input = &"wheel"
	aq.size = Vector2(0.8, 10.5)
	aq.low = 0.0
	aq.high = 0.12
	aq.flow = 1.5
	aq.fill_speed = 0.1
	aq.position = Vector3(15.5, crest_y + 0.18, -1.1)
	aq.rotation.y = -PI * 0.5
	zone.add_child(aq)
	for k in 2:
		var d := MachineDoor.new()
		d.input = &"wheel"
		d.threshold = 0.6
		d.size = Vector3(2.0, 4.0, 2.0)
		d.move = Vector3(0.0, 0.0, -1.9 if k == 0 else 1.9)
		d.delay = 0.0 if k == 0 else 1.2
		d.position = Vector3(21.0, 0.0, -1.0 if k == 0 else 1.0)
		zone.add_child(d)
		doors.append(d)
	cam = Camera3D.new()
	cam.fov = 62.0
	zone.add_child(cam)
	get_tree().root.add_child.call_deferred(zone)
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().current_scene = zone
	ZoneManager._adopt_current_scene(&"")
	_run()


func _check(case: String, ok: bool, detail: String) -> void:
	print("MACHINE %s %s  %s" % ["PASS" if ok else "FAIL", case, detail])
	if not ok:
		fails += 1


func _run() -> void:
	var p := ZoneManager.player
	for i in 20:
		await get_tree().physics_frame
	cam.current = true
	# Stand behind spoke 0 (it points +X; pushing it turns towards -Z), facing -Z.
	var d0: Vector3 = cap.spoke_dirs()[0]
	var t0 := Vector3.UP.cross(d0)
	p.scripted = true
	p.intent.clear()
	p.teleport(Transform3D(Basis.IDENTITY, cap.global_position + d0 * cap.grip_radius() - t0 * 0.55 + Vector3.UP * 0.05))
	p.facing = t0
	for i in 20:
		await _step()
	p.intent.hold(&"grab", true)
	for i in 15:
		await _step()
	print("MACHINE grabbed: ", p.machines[0].current.name)
	var steps_per_turn := int(round(360.0 / cap.step))
	for turn in cap.turns:
		for s in steps_per_turn:
			# (the stick held the way the actor faces: round with the capstan)
			var guard := 0
			var start := cap._target
			while is_equal_approx(cap._target, start) and guard < 600:
				p.intent.move = p.facing
				await _step()
				guard += 1
			while not is_equal_approx(cap.angle, cap._target):
				p.intent.move = p.facing
				await _step()
		# Settle: the gate and the water catch up.
		p.intent.move = Vector3.ZERO
		for i in 150:
			await _step()
		var k := float(turn + 1) / cap.turns
		_check("turn %d" % (turn + 1), absf(gate.open - k) < 0.02 and absf(side.full - gate.open) < 0.02
			and (wheel.running < 0.01 if turn + 1 < cap.turns else true),
			"capstan %.2f gate %.2f water %.2f (level %.2f m) wheel %.2f" % [cap.value(), gate.open, side.full, side.level(), wheel.running])
	p.intent.hold(&"grab", false)
	# The wheel spins up; the doorway's blocks shift once it runs.
	for i in 60 * 12:
		await _step()
	_check("wheel", wheel.running > 0.99, "running %.2f" % wheel.running)
	_check("door", doors[0].moved > 0.99 and doors[1].moved > 0.99, "blocks moved %.2f / %.2f" % [doors[0].moved, doors[1].moved])
	print("MACHINE done, %d failed" % fails)
	get_tree().quit(1 if fails else 0)


## One physics frame; the camera follows the action (capstan, then the wheel and door);
## every `every` frames saved to OUT.
func _step() -> void:
	await get_tree().physics_frame
	_frame += 1
	var p := ZoneManager.player
	if _frame == 1:
		for c in get_tree().root.find_children("*", "CanvasLayer", true, false):
			c.visible = false
	if gate.open < 0.999:
		# (the capstan, the gate and the side channel filling)
		cam.look_at_from_position(Vector3(4.0, 7.5, 24.0), Vector3(11.5, -0.5, 7.0))
	else:
		# (the wheel, its trough and aqueduct, the wall's doorway)
		cam.look_at_from_position(Vector3(-3.0, 9.0, -15.0), Vector3(14.5, 2.0, -0.5))
	if out != "" and _frame % every == 0:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out + "/m_%05d.png" % (_frame / every))


func _mat(tex: String, color: Color, uv: Vector2) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(SHADER)
	m.set_shader_parameter(&"albedo_texture", load(tex))
	m.set_shader_parameter(&"has_texture", true)
	m.set_shader_parameter(&"albedo_color", color)
	m.set_shader_parameter(&"uv_scale", uv)
	return m


func _box(parent: Node, at: Vector3, size: Vector3, mat: Material) -> void:
	var body := StaticBody3D.new()
	body.position = at
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	body.add_child(mi)
	parent.add_child(body)
