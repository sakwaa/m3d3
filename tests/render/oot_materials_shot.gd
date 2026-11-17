extends Node3D
## OoT / MM material recipes (references/combiners/REPORT.md) on test shapes.
## MODE=props: n64_textured's cc_ section - tinted base (Link's tunic parts: SHADE*T0 x ENV),
##   water cross-fade mix(T0, T1, ENV.a) x SHADE, MM terrain T0*T1 x PRIM, a shiny get-item
##   (texgen, contrast, ramp), MM's lit-add metal (texgen).
## MODE=magic: n64_magic.gdshader - a Din's Fire dome, a blue warp beam, an ice-arrow cone
##   (additive alpha). [T=seconds] OUT=<dir> tools/godot_run.sh --path . tests/render/oot_materials_shot.tscn

const TEXTURED := preload("res://addons/n64_runtime/shaders/n64_textured.gdshader")
const MAGIC := preload("res://addons/n64_runtime/shaders/n64_magic.gdshader")

var _frames := 0


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.12, 0.13, 0.18)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.55, 0.6)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	add_child(sun)
	RenderingServer.global_shader_parameter_set(&"n64_ambient_light", Color(1, 1, 1))
	var cam := Camera3D.new()
	add_child(cam)
	match OS.get_environment("MODE"):
		"props":
			var items := [
				[SphereMesh.new(), {cc_base = 0, cc_tint = 3, cc_env = Color(0.25, 0.65, 0.25),
					albedo_texture = load("res://textures/fabric/canvas_mustard.res")}],
				[_plane(), {cc_base = 4, cc_tint = 1, cc_prim = Color(0.55, 0.8, 1.0), cc_k_from = 1, cc_env = Color(0, 0, 0, 0.5),
					albedo_texture = load("res://textures/water/water_1.res"), texture1 = load("res://textures/water/water_2.res"),
					uv_scroll = Vector2(0.05, 0.02), texture1_scroll = Vector2(-0.03, 0.06), texture1_scale = Vector2(1.4, 1.4)}],
				[_plane(), {cc_base = 5, cc_tint = 1, cc_prim = Color(1.0, 0.95, 0.85),
					albedo_texture = load("res://textures/ground/brown_earth_1.res"), texture1 = load("res://textures/detail/grime_detail.res"),
					texture1_scale = Vector2(5, 5)}],
				[SphereMesh.new(), {cc_base = 7, cc_tint = 4, cc_texgen = true, cc_k = 0.8,
					cc_prim = Color(1.0, 0.95, 0.45), cc_env = Color(0.45, 0.25, 0.0), albedo_texture = load("res://textures/shine/chrome.res")}],
				[SphereMesh.new(), {cc_base = 8, cc_tint = 0, cc_texgen = true, cc_prim = Color(0.5, 0.5, 0.5),
					cc_env = Color(0.5, 0.5, 0.5), albedo_texture = load("res://textures/shine/chrome.res")}],
			]
			for i in items.size():
				var mi := MeshInstance3D.new()
				mi.mesh = items[i][0]
				var m := ShaderMaterial.new()
				m.shader = TEXTURED
				m.set_shader_parameter(&"cc_on", true)
				for key in items[i][1]:
					m.set_shader_parameter(key, items[i][1][key])
				mi.material_override = m
				mi.position = Vector3(-4.4 + i * 2.2, 1.0, 0)
				add_child(mi)
			cam.position = Vector3(0, 1.4, 6.5)
			cam.look_at(Vector3(0, 1.0, 0))
		"magic":
			var n0 := _noise(0.035, FastNoiseLite.TYPE_PERLIN, 3)
			var n1 := _noise(0.06, FastNoiseLite.TYPE_CELLULAR, 9)
			# Din's Fire: a dome, yellow-white over red.
			var dome := SphereMesh.new()
			dome.radius = 1.2
			dome.height = 1.2
			dome.is_hemisphere = true
			_magic(dome, Vector3(-3.2, 0, 0), {texture0 = n0, texture1 = n1, prim = Color(1.0, 0.95, 0.55), env = Color(0.95, 0.15, 0.0), k = 0.7})
			# A warp beam: pale cyan over deep blue, rising.
			var beam := CylinderMesh.new()
			beam.top_radius = 0.55
			beam.bottom_radius = 0.75
			beam.height = 3.0
			beam.cap_top = false
			beam.cap_bottom = false
			_magic(beam, Vector3(0, 1.5, 0), {texture0 = n0, texture1 = n1, prim = Color(0.8, 1.0, 1.0, 0.9), env = Color(0.05, 0.2, 0.9),
				texture0_scroll = Vector2(0.0, 0.5), texture1_scroll = Vector2(0.1, 0.9), k = 0.55})
			# An ice arrow's cone: additive alpha (k*T1 + T0), contrast recipe.
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = 0.6
			cone.height = 2.4
			_magic(cone, Vector3(3.2, 1.2, 0), {texture0 = n0, texture1 = n1, prim = Color(0.85, 0.95, 1.0, 0.85), env = Color(0.1, 0.35, 0.8),
				recipe = 2, alpha_mode = 2, k = 0.5})
			cam.position = Vector3(0, 1.6, 6.5)
			cam.look_at(Vector3(0, 1.0, 0))


func _plane() -> Mesh:
	var p := QuadMesh.new()
	p.size = Vector2(1.9, 1.9)
	return p


func _magic(mesh: Mesh, pos: Vector3, props: Dictionary) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var m := ShaderMaterial.new()
	m.shader = MAGIC
	for key in props:
		m.set_shader_parameter(key, props[key])
	mi.material_override = m
	mi.position = pos
	add_child(mi)
	# (a ground plane to see it against)
	if get_node_or_null(^"Ground") == null:
		var g := MeshInstance3D.new()
		g.name = "Ground"
		var pm := PlaneMesh.new()
		pm.size = Vector2(12, 6)
		g.mesh = pm
		var gm := StandardMaterial3D.new()
		gm.albedo_color = Color(0.25, 0.27, 0.22)
		g.material_override = gm
		add_child(g)


func _noise(freq: float, kind: int, seed_: int) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.noise_type = kind
	n.frequency = freq
	n.seed = seed_
	var t := NoiseTexture2D.new()
	t.width = 64
	t.height = 64
	t.seamless = true
	t.noise = n
	return t


func _process(_d: float) -> void:
	_frames += 1
	if _frames == 20:
		get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/shot.png")
		get_tree().quit()
