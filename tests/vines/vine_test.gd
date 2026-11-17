extends Node3D
## WorldVines test (like the reference clip: tendrils from a wall's foot that find their way
## to an object and wrap it): a paved yard, a wall, a car-sized lump (body, cabin, wheels).
## Patch A roots at the wall's foot and seeks the lump; patch B only climbs the wall.
## Prints tendril / triangle counts and crawl times; OUT=dir saves renders:
##   full_<cam>.png (grown 1), grow_<k>.png (grown 0.25 / 0.5 / 0.75), dense / sparse.
##   godot --path . --resolution 1280x720 tests/vines/vine_test.tscn

const FLOOR_TEX := "res://textures/rock/cobblestone_square.res"
const WALL_TEX := "res://textures/brick/53_old_bricks.res"
const SHADER := "res://addons/n64_runtime/shaders/n64_textured.gdshader"

var out := ""
var cam: Camera3D
var a: WorldVines
var b: WorldVines


func _ready() -> void:
	out = OS.get_environment("OUT")
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
	var wall := _mat(WALL_TEX if ResourceLoader.exists(WALL_TEX) else FLOOR_TEX, Color(0.7, 0.7, 0.72), Vector2(4, 1.5))
	var paint := _mat(FLOOR_TEX, Color(0.85, 0.86, 0.9), Vector2(1, 1))
	var dark := _mat(FLOOR_TEX, Color(0.2, 0.2, 0.22), Vector2(1, 1))
	_box(Vector3(0, -0.5, 0), Vector3(30, 1, 30), ground)
	_box(Vector3(-6, 1.5, -4), Vector3(0.6, 3, 10), wall)  # the wall (x -6.3..-5.7)
	# The lump: a car-ish body, a cabin, four wheels.
	_box(Vector3(0, 0.55, 0), Vector3(4.2, 0.7, 1.9), paint)
	_box(Vector3(-0.3, 1.15, 0), Vector3(2.2, 0.55, 1.6), paint)
	for x in [-1.4, 1.4]:
		for z in [-0.9, 0.9]:
			_wheel(Vector3(x, 0.35, z), dark)
	a = _vines(Vector3(-5.4, 0, -1), true, 14, 9.0)
	a.target = Vector3(5.4, 0.9, 1.0)  # (local: the lump's middle)
	a.climb = 0.0
	a.seek = 0.25
	b = _vines(Vector3(-5.4, 0, -6.5), false, 8, 6.0)
	b.climb = 0.9
	b.seed = 7
	# BASE=1: without the triangle savings (every ring, closed stems, quad leaves).
	if OS.get_environment("BASE") != "":
		for v in [a, b]:
			v.open_back = false
			v.stem_bend = 0.0
			v.leaf_triangles = false
	cam = Camera3D.new()
	cam.fov = 50
	add_child(cam)
	_run()


func _vines(at: Vector3, seek: bool, n: int, len: float) -> WorldVines:
	var v := WorldVines.new()
	v.position = at
	v.use_target = seek
	v.count = n
	v.length = len
	add_child(v)
	return v


func _run() -> void:
	for i in 6:
		await get_tree().process_frame
	var t0 := Time.get_ticks_msec()
	a.regrow()
	var ta := Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	b.regrow()
	var tb := Time.get_ticks_msec() - t0
	print("VINES A (seek): %d tris %s, crawl+mesh %d ms" % [a.triangle_count(), _split(a), ta])
	print("VINES B (climb): %d tris %s, crawl+mesh %d ms" % [b.triangle_count(), _split(b), tb])
	var ok := a.triangle_count() > 500 and b.triangle_count() > 300
	# Did A reach the lump? (some stem vertex near its top)
	var reached := false
	var arr := (a._mesh_node.mesh as ArrayMesh).surface_get_arrays(0)
	for v: Vector3 in arr[Mesh.ARRAY_VERTEX]:
		var w := a.to_global(v)
		if w.y > 1.3 and absf(w.x) < 2.0 and absf(w.z) < 1.0:
			reached = true
			break
	# Did B climb? (stem vertices up the wall)
	var top := 0.0
	for v: Vector3 in (b._mesh_node.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		top = maxf(top, b.to_global(v).y)
	print("VINES reached the lump's top: %s; B climbed to %.2f m" % [reached, top])
	ok = ok and reached and top > 1.5
	await _shot("full_a", Vector3(6, 6.5, 9), Vector3(-1, 0.5, -1))
	await _shot("full_b", Vector3(-1, 2.2, 4.5), Vector3(-4.5, 1.0, -2))
	await _shot("full_c", Vector3(3.5, 1.6, 3.8), Vector3(0, 0.8, 0))
	await _shot("wall_end", Vector3(-3.2, 1.6, 3.0), Vector3(-5.8, 1.2, 0.0))
	for k in [0.25, 0.5, 0.75]:
		a.grown = k
		b.grown = k
		await _shot("grow_%d" % int(k * 100), Vector3(6, 6.5, 9), Vector3(-1, 0.5, -1))
	a.grown = 1.0
	b.grown = 1.0
	a.count = 30
	a.leaf_density = 9.0
	a.thickness = 0.09
	a.regrow()
	print("VINES dense: %d tris" % a.triangle_count())
	await _shot("dense", Vector3(6, 6.5, 9), Vector3(-1, 0.5, -1))
	a.count = 5
	a.leaf_density = 2.0
	a.thickness = 0.05
	a.leaf_texture = load("res://textures/plants/vine_leaf_heart.res")
	a.regrow()
	print("VINES sparse: %d tris" % a.triangle_count())
	await _shot("sparse", Vector3(6, 6.5, 9), Vector3(-1, 0.5, -1))
	print("VINES %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


## "(stems N, leaves M)".
func _split(v: WorldVines) -> String:
	var m := v._mesh_node.mesh as ArrayMesh
	var c := []
	for i in m.get_surface_count():
		c.append((m.surface_get_arrays(i)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3)
	return "(stems %d, leaves %d)" % [c[0], c[1] if c.size() > 1 else 0]


func _shot(name: String, from: Vector3, at: Vector3) -> void:
	cam.look_at_from_position(from, at)
	for i in 3:
		await get_tree().process_frame
	if out == "":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out + "/" + name + ".png")


func _mat(tex: String, color: Color, uv: Vector2) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(SHADER)
	m.set_shader_parameter(&"albedo_texture", load(tex))
	m.set_shader_parameter(&"has_texture", true)
	m.set_shader_parameter(&"albedo_color", color)
	m.set_shader_parameter(&"uv_scale", uv)
	return m


func _box(at: Vector3, size: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	mi.position = at
	add_child(mi)


func _wheel(at: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = 0.35
	m.bottom_radius = 0.35
	m.height = 0.3
	m.radial_segments = 10
	mi.mesh = m
	mi.material_override = mat
	mi.position = at
	mi.rotation.x = PI * 0.5
	add_child(mi)
