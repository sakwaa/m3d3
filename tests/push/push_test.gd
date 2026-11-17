extends Node
## PushBlock test: a made-up paved yard with a block-sized pit, the player scripted:
##  1 pit:   push a block three steps towards the pit; it drops in, top flush with the floor;
##  2 stack: push a block with another on top one step; the top one rides along;
##  3 pull:  pull a block two steps back;
##  4 wall:  push a block standing against a wall; it doesn't move;
##  5 ice:   one push of an ice block; it slides until the wall.
##  6 link:  push one of two linked blocks; the other (across the yard) moves with it;
##  7 link wall: the far linked block is against a wall; neither moves;
##  8 link held: push a linked block out over a second pit; its mate on the floor holds it up.
## Prints PASS / FAIL per case; OUT=dir also saves a frame after each.
##   godot --path . --resolution 1280x720 tests/push/push_test.tscn

const FLOOR_TEX := "res://textures/rock/cobblestone_square.res"
const SHADER := "res://addons/n64_runtime/shaders/n64_textured.gdshader"

var out := ""
var blocks := {}
var fails := 0


func _ready() -> void:
	out = OS.get_environment("OUT")
	GameState.set_time(12.0)
	var zone := Zone.new()
	zone.name = "PushYard"
	zone.intro = false
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.35, 0.5, 0.8)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.8, 0.8, 0.8)
	zone.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.5, 0)
	zone.add_child(sun)
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER)
	mat.set_shader_parameter(&"albedo_texture", load(FLOOR_TEX))
	mat.set_shader_parameter(&"has_texture", true)
	mat.set_shader_parameter(&"albedo_color", Color(0.8, 0.78, 0.74))
	mat.set_shader_parameter(&"uv_scale", Vector2(4, 4))
	# 40 x 40 m of paving, 2.4 m pits (x -1.2..1.2 and 14.8..17.2, z -6..-3.6, 2.4 deep), walls.
	for r in [Rect2(-20, -20, 40, 14), Rect2(-20, -3.6, 40, 23.6), Rect2(-20, -6, 18.8, 2.4), Rect2(1.2, -6, 13.6, 2.4),
			Rect2(17.2, -6, 2.8, 2.4)]:
		_box(zone, Vector3(r.position.x + r.size.x * 0.5, -1.5, r.position.y + r.size.y * 0.5), Vector3(r.size.x, 3.0, r.size.y), mat)
	_box(zone, Vector3(0, -2.9, -4.8), Vector3(2.4, 1.0, 2.4), mat)  # the pit's floor (top at -2.4)
	_box(zone, Vector3(12, 1.5, -4.0), Vector3(4, 3, 1), mat)  # wall case: right behind block 4
	_box(zone, Vector3(-12, 1.5, -10.0), Vector3(4, 3, 1), mat)  # ice case: the wall it slides to
	_box(zone, Vector3(16, -2.9, -4.8), Vector3(2.4, 1.0, 2.4), mat)  # the second pit's floor
	_box(zone, Vector3(-10, 1.5, 6.3), Vector3(3, 3, 1), mat)  # link wall case: in front of the far block
	blocks.pit = _block(zone, Vector3(0, 0, -2.4))
	blocks.stack_low = _block(zone, Vector3(6, 0, -2.4))
	blocks.stack_top = _block(zone, Vector3(6, 2.4, -2.4))
	blocks.pull = _block(zone, Vector3(-6, 0, -2.4))
	blocks.wall = _block(zone, Vector3(12, 0, -2.3))
	blocks.ice = _block(zone, Vector3(-12, 0, -2.4))
	blocks.ice.slides = true
	blocks.ice.color = Color(0.6, 0.8, 1.0)
	blocks.link_a = _block(zone, Vector3(8, 0, 8), &"pair")
	blocks.link_b = _block(zone, Vector3(14, 0, 12), &"pair")
	blocks.wall_a = _block(zone, Vector3(-16, 0, 8), &"walled")
	blocks.wall_b = _block(zone, Vector3(-10, 0, 8), &"walled")
	blocks.held_a = _block(zone, Vector3(16, 0, -2.4), &"held")
	blocks.held_b = _block(zone, Vector3(18.5, 0, 2.4), &"held")
	get_tree().root.add_child.call_deferred(zone)
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().current_scene = zone
	ZoneManager._adopt_current_scene(&"")
	if OS.get_environment("ANIMS") != "":
		_add_anims()
	_run()


## ANIMS=1: builds the push / pull clips from references/anims/push/*.json, saves them there
## as .tres (for the actor tools' Import... into the player model) and gives the running
## player model them (the model scene itself isn't touched).
func _add_anims() -> void:
	var p := ZoneManager.player
	var model: ActorModel = p._model
	var built: Array[ActorAnimation] = []
	for n in ["pushwait", "push", "pull"]:
		var path := "res://references/anims/push/%s.json" % n
		var a := ActorAnimSpec.build(model, ActorAnimSpec.load_spec(path))
		ResourceSaver.save(a, path.replace(".json", ".tres"))
		built.append(a)
	var keep := model.data.animations
	model.data.animations = built
	var lib := model.build_animation_library()
	model.data.animations = keep
	var anim := p.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	for name in lib.get_animation_list():
		anim.get_animation_library(&"").add_animation(name, lib.get_animation(name))
	print("PUSH clips added: ", lib.get_animation_list())


func _block(zone: Node, at: Vector3, link := &"") -> PushBlock:
	var b := PushBlock.new()
	b.position = at
	b.link = link
	zone.add_child(b)
	return b


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


## Stands the player in front of `b`'s +Z face, facing it, holding Grab; then holds the
## stick `stick` (world) for `seconds`, then lets go.
func _drive(b: PushBlock, stick: Vector3, seconds: float) -> void:
	var p := ZoneManager.player
	p.scripted = true
	p.intent.clear()
	p.teleport(Transform3D(Basis.IDENTITY, b.pos + Vector3(0.3, 0.05, 1.2 + 0.4)))
	p.facing = Vector3.FORWARD
	# (SIDE=1: the camera off to the side, to see the push / pull poses)
	p._yaw.rotation.y = -PI * 0.5 if OS.get_environment("SIDE") != "" else 0.0
	p._pitch.rotation.x = -0.15 if OS.get_environment("SIDE") != "" else -0.35
	for i in 20:
		await get_tree().physics_frame
	p.intent.hold(&"grab", true)
	for i in 15:
		await get_tree().physics_frame
	var st: StringName = p.machines[0].current.name
	print("PUSH grabbed: ", st)
	p.intent.move = stick
	var t := 0.0
	var shot := false
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		if not shot and t > 0.3:
			shot = true
			await _save("mid_%s" % b.name)
	p.intent.move = Vector3.ZERO
	for i in 40:
		await get_tree().physics_frame
	p.intent.hold(&"grab", false)
	for i in 10:
		await get_tree().physics_frame


func _check(case: String, ok: bool, detail: String) -> void:
	print("PUSH %s %s  %s" % ["PASS" if ok else "FAIL", case, detail])
	if not ok:
		fails += 1


func _run() -> void:
	for i in 30:
		await get_tree().physics_frame
	var b: PushBlock = blocks.pit
	var t0 := Time.get_ticks_msec()
	await _drive(b, Vector3.FORWARD, 3.0)
	_check("pit", b.pos.distance_to(Vector3(0, -2.4, -4.8)) < 0.05, "block at %s (want 0,-2.4,-4.8) state %d" % [b.pos, b.state])
	await _save("1_pit")
	b = blocks.stack_low
	var top: PushBlock = blocks.stack_top
	await _drive(b, Vector3.FORWARD, 0.9)
	_check("stack", b.pos.distance_to(Vector3(6, 0, -3.2)) < 0.05 and top.pos.distance_to(Vector3(6, 2.4, -3.2)) < 0.05,
		"low %s top %s" % [b.pos, top.pos])
	await _save("2_stack")
	b = blocks.pull
	await _drive(b, Vector3.BACK, 1.6)
	_check("pull", b.pos.distance_to(Vector3(-6, 0, -0.8)) < 0.05, "block at %s (want -6,0,-0.8)" % b.pos)
	await _save("3_pull")
	b = blocks.wall
	await _drive(b, Vector3.FORWARD, 1.5)
	_check("wall", b.pos.distance_to(Vector3(12, 0, -2.3)) < 0.01, "block at %s" % b.pos)
	b = blocks.ice
	await _drive(b, Vector3.FORWARD, 0.3)
	for i in 240:
		await get_tree().physics_frame
	_check("ice", absf(b.pos.z - (-8.0)) < 0.05, "block at %s (want z -8.0: against the wall at -9.5)" % b.pos)
	await _save("5_ice")
	var a: PushBlock = blocks.link_a
	await _drive(a, Vector3.FORWARD, 0.9)
	_check("link", a.pos.distance_to(Vector3(8, 0, 7.2)) < 0.05 and blocks.link_b.pos.distance_to(Vector3(14, 0, 11.2)) < 0.05,
		"a %s b %s" % [a.pos, blocks.link_b.pos])
	await _save("6_link")
	a = blocks.wall_a
	await _drive(a, Vector3.FORWARD, 1.5)
	_check("link wall", a.pos.distance_to(Vector3(-16, 0, 8)) < 0.01 and blocks.wall_b.pos.distance_to(Vector3(-10, 0, 8)) < 0.01,
		"a %s b %s" % [a.pos, blocks.wall_b.pos])
	a = blocks.held_a
	await _drive(a, Vector3.FORWARD, 3.0)
	_check("link held", a.pos.distance_to(Vector3(16, 0, -4.8)) < 0.05 and blocks.held_b.pos.distance_to(Vector3(18.5, 0, 0)) < 0.05,
		"a %s (want 16,0,-4.8 over the pit) b %s" % [a.pos, blocks.held_b.pos])
	await _save("8_link_held")
	print("PUSH done in %d ms, %d failed" % [Time.get_ticks_msec() - t0, fails])
	get_tree().quit(1 if fails else 0)


func _save(name: String) -> void:
	if out == "":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out + "/" + name + ".png")
