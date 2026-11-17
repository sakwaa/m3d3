extends Node3D
## Showcase renders for the RDP + modern ideas (coverage tags, IDs, barycentrics). Each
## FEATURE builds a small set and saves its variants (OUT/<feature>_<variant>.png):
##   upscale   - 240 lines: bilinear / nearest blocks / edge-aware (N64VideoOut.edge_upscale)
##   wires     - power lines into the distance: true width / thin-line coverage (n64_wire)
##   detail    - close wall: plain / detail texture up close (existing lod_mode 2)
##   decal     - scorch decal by a crate and wall: depth only / clipped to its surface
##   seam      - corner, steps, crate, actor: plain / seam dirt
##   dither    - faded actors over brick: raw dither / dither resolve
##   backdrop  - sky painting at equal bytes: RGBA16 / I4 luma + chroma
##   visible   - three NPCs behind cover: centre raycast vs ID-buffer visible share
##   outline   - same NPCs: plain / the target outlined
##   truesight - wall hiding a passage + chest: plain / true sight wire
## OUT=dir FEATURE=name GODOT=<patched> tools/godot_run.sh --path . --resolution 1280x960 tests/render/rdp_ideas.tscn

const TEXTURED := preload("res://addons/n64_runtime/shaders/n64_textured.gdshader")
const ACTOR := preload("res://addons/n64_runtime/shaders/n64_actor.gdshader")
const WIRE := preload("res://addons/n64_runtime/shaders/n64_wire.gdshader")
const DECAL := preload("res://addons/n64_runtime/shaders/n64_id_decal.gdshader")
const SIGHT := preload("res://addons/n64_runtime/shaders/n64_true_sight.gdshader")
const LUMA := preload("res://addons/n64_runtime/shaders/n64_luma_chroma.gdshader")
const BRICK := "res://textures/brick/brick_1.res"
const COBBLE := "res://textures/rock/cobblestone_square.res"
const WOOD := "res://textures/wood/wood_1.res"

var vo: Resource
var cam: Camera3D
var out := ""
var feature := ""


func _ready() -> void:
	out = OS.get_environment("OUT")
	feature = OS.get_environment("FEATURE")
	vo = load("res://game/video_out.tres")
	vo.set(&"horizontal_soft", 0.0)
	_stage()
	await _frames(2)
	for n in ZoneManager.get_children():
		if n is DebugHud:
			n.queue_free()
	match feature:
		"upscale": await _upscale()
		"wires": await _wires()
		"detail": await _detail()
		"decal": await _decal()
		"seam": await _seam()
		"dither": await _dither()
		"backdrop": await _backdrop()
		"visible": await _visible()
		"outline": await _outline()
		"truesight": await _truesight()
		_: push_error("FEATURE?")
	get_tree().quit()


# --- sets ---------------------------------------------------------------------------

func _stage() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.48, 0.62, 0.82)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.55, 0.62)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 1.1
	add_child(sun)
	RenderingServer.global_shader_parameter_set(&"n64_ambient_light", Color(1, 1, 1))
	cam = Camera3D.new()
	cam.fov = 50
	add_child(cam)
	cam.position = Vector3(0, 1.7, 6.5)
	cam.look_at(Vector3(0, 0.9, 0))


func _yard() -> void:
	_box(Vector3(0, -0.05, 0), Vector3(14, 0.1, 12), load(COBBLE), Vector2(8, 6))
	_box(Vector3(0, 1.75, -2.5), Vector3(14, 3.5, 0.3), load(BRICK), Vector2(8, 2))


func _actor(pos: Vector3, col: Color, id := 0, h := 1.6) -> Node3D:
	var root := Node3D.new()
	root.position = pos
	add_child(root)
	var m := ShaderMaterial.new()
	m.shader = ACTOR
	m.set_shader_parameter(&"albedo_color", col)
	var body := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.28
	cm.height = h * 0.72
	body.mesh = cm
	body.position.y = h * 0.36
	body.material_override = m
	root.add_child(body)
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.2
	sm.height = 0.4
	head.mesh = sm
	head.position.y = h * 0.72 + 0.16
	var hm := m.duplicate()
	hm.set_shader_parameter(&"albedo_color", Color(0.93, 0.76, 0.6))
	head.material_override = hm
	root.add_child(head)
	for mi: MeshInstance3D in [body, head]:
		mi.set_instance_shader_parameter(&"object_id", id)
	return root


func _box(pos: Vector3, size: Vector3, tex: Texture2D, rep: Vector2, col := Color.WHITE) -> MeshInstance3D:
	var m := ShaderMaterial.new()
	m.shader = TEXTURED
	m.set_shader_parameter(&"albedo_color", col)
	m.set_shader_parameter(&"has_texture", tex != null)
	if tex:
		m.set_shader_parameter(&"albedo_texture", tex)
		m.set_shader_parameter(&"uv_scale", rep)
	var b := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	b.mesh = bm
	b.material_override = m
	b.position = pos
	add_child(b)
	return b


## Render `n` lines tall (whatever the window: Retina doubles it).
func _lines(n: int) -> void:
	get_viewport().scaling_3d_scale = float(n) / float(get_window().size.y)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _save(variant: String, wait := 8) -> void:
	await _frames(wait)
	get_viewport().get_texture().get_image().save_png("%s/%s_%s.png" % [out, feature, variant])


# --- features -----------------------------------------------------------------------

func _upscale() -> void:
	_yard()
	_box(Vector3(-1.6, 0.45, -0.6), Vector3(0.9, 0.9, 0.9), load(WOOD), Vector2.ONE)
	_box(Vector3(2.6, 1.2, -1.2), Vector3(0.18, 2.4, 0.18), null, Vector2.ONE, Color(0.35, 0.3, 0.28))
	var a := _actor(Vector3(0.6, 0, 0.4), Color(0.25, 0.45, 0.8))
	a.rotation_degrees.y = 25
	cam.position = Vector3(0.4, 1.5, 4.2)
	cam.look_at(Vector3(0.3, 0.9, -0.5))
	_lines(240)
	await _save("bilinear")
	vo.set(&"edge_upscale", clampi(roundi(get_window().size.y / 240.0), 2, 8))
	for mode in [0, 1]:
		vo.set(&"upscale_mode", mode)
		await _frames(8)
		var t := Texture2DRD.new()
		t.texture_rd_rid = vo.get(&"upscaled_rid")
		var img := t.get_image()
		img.convert(Image.FORMAT_RGBA8)
		img.save_png("%s/upscale_%s.png" % [out, ["nearest", "edge"][mode]])


func _wires() -> void:
	_box(Vector3(0, -0.05, -40), Vector3(60, 0.1, 100), load("res://textures/grass/157_green_grass.res") if ResourceLoader.exists("res://textures/grass/157_green_grass.res") else null, Vector2(30, 50), Color(0.6, 0.75, 0.45))
	var lines := []
	for side in [-1.0, 1.0]:
		for k in 3:
			var pts := PackedVector3Array()
			for i in 13:
				var z := 4.0 - i * 8.0
				var x: float = side * (2.2 + k * 0.45)
				pts.append(Vector3(x, 5.0 + k * 0.3, z))
			lines.append(pts)
		for i in 13:
			_box(Vector3(side * 2.6, 2.6, 4.0 - i * 8.0), Vector3(0.14, 5.2, 0.14), null, Vector2.ONE, Color(0.36, 0.28, 0.22))
	var mats := []
	for pts in lines:
		mats.append(_wire(pts, 0.008))
	cam.position = Vector3(0, 1.7, 8.0)
	cam.look_at(Vector3(0, 3.2, -30))
	_lines(480)
	for m: ShaderMaterial in mats:
		m.set_shader_parameter(&"rescue", false)
	await _save("plain")
	for m: ShaderMaterial in mats:
		m.set_shader_parameter(&"rescue", true)
		if OS.get_environment("WDBG") != "":
			m.set_shader_parameter(&"line_color", Color(1, 0, 0))
	print("rescue now: ", (mats[0] as ShaderMaterial).get_shader_parameter(&"rescue"), " shader ", (mats[0] as ShaderMaterial).shader.resource_path)
	await _save("coverage")


## A sagging wire through `pts` (pole tops) as an n64_wire ribbon.
func _wire(pts: PackedVector3Array, width: float) -> ShaderMaterial:
	var verts := PackedVector3Array()
	var custom := PackedFloat32Array()
	var idx := PackedInt32Array()
	for s in pts.size() - 1:
		var a := pts[s]
		var b := pts[s + 1]
		for j in 9:
			var t := j / 8.0
			var p := a.lerp(b, t) + Vector3(0, -0.6 * 4.0 * t * (1.0 - t), 0)
			var tan := (b - a).normalized() + Vector3(0, -0.6 * 4.0 * (1.0 - 2.0 * t) / a.distance_to(b), 0)
			tan = tan.normalized()
			for side in [-1.0, 1.0]:
				verts.append(p)
				custom.append_array([tan.x, tan.y, tan.z, side])
			if j > 0:
				var base := verts.size() - 4
				idx.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_CUSTOM0] = custom
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	var m := ShaderMaterial.new()
	m.shader = WIRE
	m.set_shader_parameter(&"width", width)
	m.set_shader_parameter(&"render_lines", 480.0 if OS.get_environment("WIRE_VP") == "" else 0.0)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.extra_cull_margin = 100.0
	add_child(mi)
	return m


func _detail() -> void:
	var wall := _box(Vector3(0, 1.5, 0), Vector3(4, 3, 0.3), load("res://textures/brick/53_old_bricks.res") if ResourceLoader.exists("res://textures/brick/53_old_bricks.res") else load(BRICK), Vector2(3, 2))
	cam.position = Vector3(0.5, 1.3, 1.1)
	cam.look_at(Vector3(-0.4, 1.2, 0))
	var m: ShaderMaterial = wall.material_override
	await _save("plain")
	m.set_shader_parameter(&"lod_mode", 2)
	m.set_shader_parameter(&"detail_texture", load("res://textures/detail/grime_detail.res"))
	m.set_shader_parameter(&"detail", Vector2(6.0, 1.0))
	await _save("detail")


func _decal() -> void:
	_yard()
	_box(Vector3(0.75, 0.45, -1.2), Vector3(0.9, 0.9, 0.9), load(WOOD), Vector2.ONE)
	var a := _actor(Vector3(-0.8, 0, -1.3), Color(0.8, 0.35, 0.3))
	a.rotation_degrees.y = 15
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var d := Vector2(x - 31.5, y - 31.5).length() / 32.0
			var n := fmod(sin(x * 12.9898 + y * 78.233) * 43758.5453, 1.0)
			var al := clampf((1.0 - d) * 1.8 + n * 0.25 - 0.25, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, al))
	var m := ShaderMaterial.new()
	m.shader = DECAL
	m.set_shader_parameter(&"decal", ImageTexture.create_from_image(img))
	m.set_shader_parameter(&"tint", Color(0.85, 0.12, 0.1, 0.9))
	var box := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	box.mesh = bm
	box.material_override = m
	box.position = Vector3(0.1, 0.5, -0.9)
	box.scale = Vector3(2.6, 1.4, 2.2)
	add_child(box)
	cam.position = Vector3(0.2, 2.6, 3.4)
	cam.look_at(Vector3(0.0, 0.4, -1.4))
	if OS.get_environment("DBG") != "":
		m.set_shader_parameter(&"debug_view", 1)
		await _save("dbg1")
		m.set_shader_parameter(&"debug_view", 2)
		await _save("dbg2")
		m.set_shader_parameter(&"debug_view", 0)
	m.set_shader_parameter(&"clip_to_surface", false)
	await _save("depth")
	m.set_shader_parameter(&"clip_to_surface", true)
	await _save("clipped")


func _seam() -> void:
	_yard()
	_box(Vector3(-3.5, 1.75, 0), Vector3(0.3, 3.5, 5), load(BRICK), Vector2(3, 2))
	var conc: Texture2D = load("res://textures/concrete/concrete_bare.res") if ResourceLoader.exists("res://textures/concrete/concrete_bare.res") else null
	for i in 3:
		var sh := (i + 1) * 0.24
		_box(Vector3(2.2, sh * 0.5, -0.9 - i * 0.45), Vector3(2.4, sh, 0.45), conc, Vector2(2, 1), Color(0.85, 0.82, 0.78))
	_box(Vector3(-1.8, 0.45, -1.3), Vector3(0.9, 0.9, 0.9), load(WOOD), Vector2.ONE)
	var a := _actor(Vector3(-0.1, 0, 0.3), Color(0.25, 0.45, 0.8), 5)
	a.rotation_degrees.y = 20
	cam.position = Vector3(0, 2.2, 5.2)
	cam.look_at(Vector3(-0.2, 0.6, -1.0))
	_lines(480)
	await _save("plain")
	vo.set(&"seam_dirt", float(OS.get_environment("SEAM")) if OS.get_environment("SEAM") != "" else 0.85)
	vo.set(&"seam_radius", 9)
	vo.set(&"seam_objects_only", false)
	await _save("dirt")
	vo.set(&"seam_objects_only", true)
	await _save("objects")


func _dither() -> void:
	_yard()
	var actors := [_actor(Vector3(-0.9, 0, -0.6), Color(0.25, 0.45, 0.8)), _actor(Vector3(0.9, 0, -0.6), Color(0.85, 0.5, 0.25))]
	var fades := [0.5, 0.25]
	for i in 2:
		for mi in actors[i].find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).set_instance_shader_parameter(&"fade", fades[i])
	cam.position = Vector3(0, 1.4, 4.0)
	cam.look_at(Vector3(0, 1.0, -1.0))
	_lines(480)
	await _save("raw")
	vo.set(&"dither_resolve", true)
	await _save("resolved")


func _backdrop() -> void:
	var src := Image.load_from_file(ProjectSettings.globalize_path("res://textures/_source/sky/cloudy_sky_2.bmp"))
	src.convert(Image.FORMAT_RGBA8)
	# Equal bytes: RGBA16 at W x H (2 B/px) vs I4 luma at 2W x 2H (0.5 B/px) + Cb/Cr at
	# W/2 x H/2 (8-bit pair: 2 B/px): 2WH vs 2WH + WH/2.
	var w := 64
	var h := 32
	var rgb: Image = src.duplicate()
	rgb.resize(w, h, Image.INTERPOLATE_LANCZOS)
	for y in h:
		for x in w:
			var c := rgb.get_pixel(x, y)
			rgb.set_pixel(x, y, Color(roundf(c.r * 31) / 31, roundf(c.g * 31) / 31, roundf(c.b * 31) / 31))
	var luma: Image = src.duplicate()
	luma.resize(w * 2, h * 2, Image.INTERPOLATE_LANCZOS)
	var ly := Image.create(w * 2, h * 2, false, Image.FORMAT_L8)
	for y in h * 2:
		for x in w * 2:
			var c := luma.get_pixel(x, y)
			var yv := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			ly.set_pixel(x, y, Color(roundf(yv * 15) / 15, 0, 0))
	var chroma: Image = src.duplicate()
	chroma.resize(w / 2, h / 2, Image.INTERPOLATE_LANCZOS)
	var cc := Image.create(w / 2, h / 2, false, Image.FORMAT_RG8)
	for y in h / 2:
		for x in w / 2:
			var c := chroma.get_pixel(x, y)
			var yv := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			cc.set_pixel(x, y, Color((c.b - yv) / 1.772 + 0.5, (c.r - yv) / 1.402 + 0.5, 0))
	var m := ShaderMaterial.new()
	m.shader = LUMA
	m.set_shader_parameter(&"rgb_tex", ImageTexture.create_from_image(rgb))
	m.set_shader_parameter(&"luma_tex", ImageTexture.create_from_image(ly))
	m.set_shader_parameter(&"chroma_tex", ImageTexture.create_from_image(cc))
	var q := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(8, 4)
	q.mesh = qm
	q.material_override = m
	q.position = Vector3(0, 2, -3)
	add_child(q)
	cam.position = Vector3(0, 2, 2.0)
	cam.look_at(Vector3(0, 2, -3))
	_lines(480)
	m.set_shader_parameter(&"rgb_mode", true)
	await _save("rgba16")
	m.set_shader_parameter(&"rgb_mode", false)
	await _save("luma")


func _npcs() -> Array:
	_yard()
	var npcs := [_actor(Vector3(-2.0, 0, -0.8), Color(0.3, 0.6, 0.35), 1),
		_actor(Vector3(0.0, 0, -1.4), Color(0.8, 0.35, 0.3), 2),
		_actor(Vector3(2.2, 0, -1.4), Color(0.6, 0.4, 0.8), 3)]
	# Cover: a low crate wall hides the middle one up to the shoulders, a tall one hides the right.
	var cover := [_box(Vector3(0.0, 0.55, -0.6), Vector3(1.6, 1.1, 0.5), load(WOOD), Vector2(2, 1)),
		_box(Vector3(2.2, 1.2, -0.7), Vector3(1.4, 2.4, 0.4), load(BRICK), Vector2(1, 1))]
	cam.position = Vector3(0, 1.5, 5.5)
	cam.look_at(Vector3(0, 1.0, -1.0))
	_lines(480)
	return [npcs, cover]


func _visible() -> void:
	var set: Array = _npcs()
	var npcs: Array = set[0]
	var cover: Array = set[1]
	vo.set(&"count_visible", true)
	for c: Node3D in cover:
		c.visible = false
	await _frames(8)
	var full := []
	for i in 3:
		full.append(vo.call(&"visible_pixels", i + 1))
	for c: Node3D in cover:
		c.visible = true
	await _frames(8)
	var space := get_world_3d().direct_space_state
	for c: MeshInstance3D in cover:
		c.create_trimesh_collision()
	await _frames(2)
	for i in 3:
		var seen: int = vo.call(&"visible_pixels", i + 1)
		var centre: Vector3 = (npcs[i] as Node3D).global_position + Vector3(0, 0.8, 0)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(cam.global_position, centre))
		var l := Label3D.new()
		l.text = "ray: %s\nseen: %d%%" % ["blocked" if hit else "clear", roundi(100.0 * seen / maxf(full[i], 1))]
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.fixed_size = true
		l.pixel_size = 0.0012
		l.font_size = 22
		l.outline_size = 6
		l.modulate = Color(1, 1, 0.85)
		l.position = (npcs[i] as Node3D).global_position + Vector3(0, 2.25, 0)
		add_child(l)
		print("npc %d: ray %s, seen %d of %d" % [i + 1, "blocked" if hit else "clear", seen, full[i]])
	await _save("ids")


func _outline() -> void:
	_npcs()
	cam.position = Vector3(0.3, 1.45, 3.2)
	cam.look_at(Vector3(0.3, 1.1, -1.2))
	await _save("plain")
	vo.set(&"outline_code", 64 + 2)
	vo.set(&"outline_color", Color(1.0, 0.86, 0.3))
	await _save("target")
	vo.set(&"outline_code", 64 + 1)
	vo.set(&"outline_color", Color(0.15, 0.15, 0.15))
	vo.set(&"outline_flat", 0.0)
	await _save("ink")


func _truesight() -> void:
	_box(Vector3(0, -0.05, 0), Vector3(14, 0.1, 12), load(COBBLE), Vector2(8, 6))
	# A wall with a false section (the passage behind it) and a chest hidden in the passage.
	_box(Vector3(-3.6, 1.75, -1.5), Vector3(5.6, 3.5, 0.4), load(BRICK), Vector2(3, 2))
	_box(Vector3(3.6, 1.75, -1.5), Vector3(5.6, 3.5, 0.4), load(BRICK), Vector2(3, 2))
	var fake := _box(Vector3(0, 1.75, -1.5), Vector3(1.6, 3.5, 0.4), load(BRICK), Vector2(1, 2))
	_box(Vector3(0, 1.75, -4.0), Vector3(1.6, 3.5, 0.3), load(BRICK), Vector2(1, 2), Color(0.6, 0.6, 0.6))
	var chest := _box(Vector3(0, 0.35, -3.2), Vector3(0.9, 0.7, 0.6), load(WOOD), Vector2.ONE, Color(0.9, 0.7, 0.4))
	var sm := SphereMesh.new()
	sm.radius = 0.25
	sm.height = 0.5
	sm.radial_segments = 8
	sm.rings = 4
	var orb := MeshInstance3D.new()
	orb.mesh = sm
	orb.position = Vector3(0, 0.95, -3.2)
	cam.position = Vector3(0.8, 1.8, 4.5)
	cam.look_at(Vector3(0, 1.2, -1.5))
	_lines(480)
	await _save("plain")
	# (the orb is only ever seen in true sight: wire alone)
	var om := ShaderMaterial.new()
	om.shader = SIGHT
	om.set_shader_parameter(&"wire_color", Color(1.0, 0.5, 0.9))
	om.set_shader_parameter(&"fill", 0.15)
	orb.material_override = om
	add_child(orb)
	var colours := {fake: Color(0.45, 0.9, 1.0), chest: Color(1.0, 0.8, 0.35)}
	for n: MeshInstance3D in colours:
		var m := ShaderMaterial.new()
		m.shader = SIGHT
		m.set_shader_parameter(&"wire_color", colours[n])
		var o := MeshInstance3D.new()
		o.mesh = n.mesh
		o.material_override = m
		n.add_child(o)
	vo.set(&"grade", 0.7)
	vo.set(&"grade_tint", Color(0.6, 0.7, 0.9))
	await _save("sight")
