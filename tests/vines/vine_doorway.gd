extends Node3D
## WorldVines dense-coverage test: a 10 x 4 m wall with a 2.2 x 2.6 m walkway opening. Three
## patches on the wall's top droop down its face (negative climb) and hang strands over the
## opening; two climb from its foot either side; one fills the ground in front. Prints
## counts; OUT=dir saves front / oblique / walk-through shots (WIRE=1: + _wire.png).
##   godot --path . --resolution 1280x720 tests/vines/vine_doorway.tscn

const FLOOR_TEX := "res://textures/rock/cobblestone_square.res"
const WALL_TEX := "res://textures/brick/53_old_bricks.res"
const SHADER := "res://addons/n64_runtime/shaders/n64_textured.gdshader"

var out := ""
var wire := false
var cam: Camera3D
var patches: Array[WorldVines] = []


func _ready() -> void:
	out = OS.get_environment("OUT")
	wire = OS.get_environment("WIRE") != ""
	if wire:
		RenderingServer.set_debug_generate_wireframes(true)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.66, 0.72)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.8, 0.8, 0.8)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.5, 0)
	add_child(sun)
	var ground := _mat(FLOOR_TEX, Color(0.82, 0.8, 0.76), Vector2(10, 10))
	var wall := _mat(WALL_TEX, Color(0.75, 0.73, 0.72), Vector2(1, 1))
	_box(Vector3(0, -0.5, 0), Vector3(30, 1, 30), ground)
	# The wall (z -0.25..0.25), its opening x -1.1..1.1 up to 2.6 m.
	_box(Vector3(-3.05, 2.0, 0), Vector3(3.9, 4.0, 0.5), wall, Vector2(2, 2))
	_box(Vector3(3.05, 2.0, 0), Vector3(3.9, 4.0, 0.5), wall, Vector2(2, 2))
	_box(Vector3(0, 3.3, 0), Vector3(2.2, 1.4, 0.5), wall, Vector2(1.2, 0.7))
	if OS.get_environment("SOURCE") != "":
		# One source: a clump on the ground off to the left; the tendrils flow as a bundle
		# across to the wall, up it to over the doorway, spread there and spill down.
		var s := _vines(Vector3(-6.5, 0, 3.2), int(OS.get_environment("COUNT")) if OS.get_environment("COUNT") != "" else 12, 16.0, 5)
		s.spread = 0.25
		s.fan = 70.0
		s.bundle = float(OS.get_environment("BUNDLE")) if OS.get_environment("BUNDLE") != "" else 0.3
		s.moss_width = 1.6
		s.moss_opacity = 0.95
		s.use_target = true
		s.target = Vector3(-0.7, 3.6, 0.3) - Vector3(-6.5, 0, 3.2)
		s.target_radius = 1.9
		s.seek = 0.3
		s.climb = 0.5
		s.cascade = true
		s.cascade_spread = 2.2
		s.length_jitter = 0.35
		s.branches = 0.08
		s.hang = 0.8
		s.hang_length = 2.4
		s.wander = 12.0
	cam = Camera3D.new()
	cam.fov = 55
	add_child(cam)
	if OS.get_environment("SOURCE") != "":
		_run()
		return
	for x in [-3.0, 0.0, 3.0]:
		var v := _vines(Vector3(x, 4.0, 0), 8, 7.0, int(x) + 11)
		v.spread = 0.2
		v.climb = -0.75
		v.hang = 0.85
		v.hang_length = 2.4
	for x in [-3.0, 3.0]:
		var v := _vines(Vector3(x, 0, 0.6), 14, 6.0, int(x) + 31)
		v.climb = 0.6
		v.spread = 0.8
	var f := _vines(Vector3(0, 0, 3.0), 12, 5.0, 51)
	f.climb = 0.0
	f.spread = 1.5
	cam = Camera3D.new()
	cam.fov = 55
	add_child(cam)
	_run()


func _vines(at: Vector3, n: int, len: float, sd: int) -> WorldVines:
	var v := WorldVines.new()
	v.position = at
	v.count = n
	v.length = len
	v.seed = sd
	v.leaf_density = 7.0
	# LEAF=single|sprig, CAP=n (leaf_cap), STYLE=cards: the variants to compare.
	if OS.get_environment("LEAF") == "single":
		v.leaf_mode = WorldVines.LeafMode.SINGLE
	if OS.get_environment("CAP") != "":
		v.leaf_cap = int(OS.get_environment("CAP"))
	if OS.get_environment("STYLE") == "cards":
		v.style = WorldVines.Style.CARDS
	if OS.get_environment("SHARE") != "":
		v.card_share = float(OS.get_environment("SHARE"))
	if OS.get_environment("VARY") == "0":
		v.leaf_scatter = 0.0
		v.leaf_jitter = 0.35
		v.card_variation = 0.0
	if OS.get_environment("FILLC") == "0":
		v.fill_cards = false
	add_child(v)
	patches.append(v)
	return v


func _run() -> void:
	for i in 6:
		await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	var tris := 0
	var hanging := 0
	for v in patches:
		v.regrow()
		tris += v.triangle_count()
		hanging += v._hanging
	print("DOORWAY %d patches, %d tris, %d hanging strands, %d ms" % [patches.size(), tris, hanging, Time.get_ticks_msec() - t0])
	var st := 0
	var lv := 0
	for v in patches:
		var m := v._mesh_node.mesh as ArrayMesh
		st += (m.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		if m.get_surface_count() > 1:
			for si in range(1, m.get_surface_count()):
				lv += (m.surface_get_arrays(si)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	print("DOORWAY stems %d tris, leaves + cards %d tris (top patches: %s)" % [st, lv, patches.slice(0, 3).map(func(v): return v.triangle_count())])
	# Strands across the opening: stem vertices inside it (x -1.1..1.1, 0.3..2.6 m, in the wall's depth band).
	var across := 0
	for v in patches:
		var m := v._mesh_node.mesh as ArrayMesh
		for si in m.get_surface_count():
			if m.surface_get_name(si) == "leaves":
				continue
			for p: Vector3 in m.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]:
				var w := v.to_global(p)
				if absf(w.x) < 1.1 and w.y > 0.3 and w.y < 2.55 and absf(w.z) < 0.6:
					across += 1
	print("DOORWAY stem vertices hanging in the opening: %d" % across)
	if OS.get_environment("WALK_FRAMES") != "":
		await _record_walk(int(OS.get_environment("WALK_FRAMES")))
		get_tree().quit()
		return
	if OS.get_environment("GROW_FRAMES") != "":
		await _record_growth(int(OS.get_environment("GROW_FRAMES")))
		get_tree().quit()
		return
	await _shot("front", Vector3(0, 1.7, 7.5), Vector3(0, 2.0, 0))
	await _shot("oblique", Vector3(5.0, 1.8, 5.0), Vector3(0, 1.9, 0))
	await _shot("walk", Vector3(0.4, 1.6, 3.0), Vector3(0, 1.7, -3))
	print("DOORWAY %s" % ("PASS" if hanging > 0 and across > 0 else "FAIL"))
	get_tree().quit(0 if hanging > 0 and across > 0 else 1)


## WALK_FRAMES=n: a stand-in player (a capsule; n64_bender0 like player.gd) walks through
## the doorway over n frames, the hanging strands parting round it; frames to OUT/walk_####.png.
func _record_walk(n: int) -> void:
	for c in get_tree().root.find_children("*", "CanvasLayer", true, false):
		c.visible = false
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.3
	cap.height = 1.6
	body.mesh = cap
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.25, 0.5, 0.3)
	body.material_override = m
	add_child(body)
	cam.look_at_from_position(Vector3(2.2, 1.8, 4.2), Vector3(-0.4, 1.4, 0.0))
	for f in n + 90:
		var k := minf(float(f) / (n - 1), 1.0)  # (then standing past the doorway: the strands swing back)
		var p := Vector3(-0.45, 0.0, lerpf(3.0, -2.5, k))
		body.position = p + Vector3.UP * 0.8
		RenderingServer.global_shader_parameter_set(&"n64_bender0", Vector4(p.x, p.y, p.z, 0.9))
		WorldVines.bender = Vector4(p.x, p.y, p.z, 0.4)
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.resize(1280, int(1280.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_BILINEAR)
		img.save_png(out + "/walk_%04d.png" % f)
	RenderingServer.global_shader_parameter_set(&"n64_bender0", Vector4(0, -1000, 0, 0))
	WorldVines.bender = Vector4(0, -1000, 0, 0)
	print("DOORWAY walk: %d frames" % n)


## GROW_FRAMES=n: grows the vines in over n frames, holds, shrinks them back over n frames,
## saving every frame (OUT/grow_####.png, 1280 wide, debug text hidden).
func _record_growth(n: int) -> void:
	for c in get_tree().root.find_children("*", "CanvasLayer", true, false):
		c.visible = false
	cam.look_at_from_position(Vector3(2.6, 2.4, 8.0), Vector3(-2.4, 1.6, 0.4))
	var hold := n / 4
	var total := n * 2 + hold * 2
	for f in total:
		var g := 0.0
		if f < hold / 2:
			g = 0.0
		elif f < hold / 2 + n:
			g = smoothstep(0.0, 1.0, float(f - hold / 2) / n)
		elif f < hold / 2 + n + hold:
			g = 1.0
		elif f < hold / 2 + 2 * n + hold:
			g = 1.0 - smoothstep(0.0, 1.0, float(f - hold / 2 - n - hold) / n)
		for v in patches:
			v.grown = g
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.resize(1280, int(1280.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_BILINEAR)
		img.save_png(out + "/grow_%04d.png" % f)
	print("DOORWAY growth: %d frames" % total)


func _shot(name: String, from: Vector3, at: Vector3) -> void:
	cam.look_at_from_position(from, at)
	for i in 3:
		await get_tree().process_frame
	if out == "":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out + "/" + name + ".png")
	if wire:
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
		for i in 3:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out + "/" + name + "_wire.png")
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED


func _mat(tex: String, color: Color, uv: Vector2) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(SHADER)
	m.set_shader_parameter(&"albedo_texture", load(tex))
	m.set_shader_parameter(&"has_texture", true)
	m.set_shader_parameter(&"albedo_color", color)
	m.set_shader_parameter(&"uv_scale", uv)
	return m


func _box(at: Vector3, size: Vector3, mat: ShaderMaterial, uv := Vector2.ZERO) -> void:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	if uv != Vector2.ZERO:
		mat = mat.duplicate()
		mat.set_shader_parameter(&"uv_scale", uv)
	mi.material_override = mat
	mi.position = at
	add_child(mi)
