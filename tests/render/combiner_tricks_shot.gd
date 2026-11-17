extends Node3D
## Render checks for the material combiner tricks (Kaze, "3D Art is Math (on the N64)").
## MODE=water (glisten off / on), cut (clamp cut-out by painted vertex alpha / hexagons near
## the player, player far and near), reflect (IA texture: alpha as reflect mask, screen-space
## and env map; glow mask), push (grey texture: plain / pushed clamped / pushed wrapping).
## [T=seconds of animation] OUT=<dir> tools/godot_run.sh --path . tests/render/combiner_tricks_shot.tscn

const TEXTURED := preload("res://addons/n64_runtime/shaders/n64_textured.gdshader")

var _frames := 0


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.25, 0.27, 0.33)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 150, 0)
	add_child(sun)
	RenderingServer.global_shader_parameter_set(&"n64_ambient_light", Color(1, 1, 1))
	RenderingServer.global_shader_parameter_set(&"n64_time", float(OS.get_environment("T")) if OS.get_environment("T") != "" else 3.0)
	var cam := Camera3D.new()
	add_child(cam)
	match OS.get_environment("MODE"):
		"water":
			for i in 2:
				var w := (load("res://game/materials/water.tres") as ShaderMaterial).duplicate()
				w.set_shader_parameter(&"wobble_on", false)
				w.set_shader_parameter(&"opacity", 1.0)
				w.set_shader_parameter(&"glisten", 1.2 * i)
				var p := MeshInstance3D.new()
				var pm := PlaneMesh.new()
				pm.size = Vector2(3.9, 8)
				pm.subdivide_width = 12
				pm.subdivide_depth = 24
				p.mesh = pm
				p.material_override = w
				p.position = Vector3(-2.0 + i * 4.0, 0, -2)
				add_child(p)
			cam.position = Vector3(0, 2.2, 3.5)
			cam.look_at(Vector3(0, 0, -2))
		"cut":
			var holes := _noise_alpha_texture()
			# 1: a "sail" painted 0.75 alpha at the top, 0 at the bottom: torn only below.
			_quad(Vector3(-2.2, 1.0, 0), _mat({cut_mode = 1, albedo_texture = holes}), true)
			# 2, 3: hexagons near the player (player 2 m in front / 0.6 m in front).
			var hexes := {cut_mode = 2, cut_pattern = 1, hex_size = 5.0, cut_near = 0.5, cut_far = 2.5,
				albedo_texture = load("res://textures/fabric/" + _first("res://textures/fabric"))}
			_quad(Vector3(0, 1.0, 0), _mat(hexes), false)
			_quad(Vector3(2.2, 1.0, 0), _mat(hexes), false)
			# (n64_see_through is one point: put it between the two hex quads' distances by
			# placing it near the right quad - the middle one sits ~2.2 m away from it)
			RenderingServer.global_shader_parameter_set(&"n64_see_through", Vector4(2.2, 1.0, 0.6, 0.4))
			cam.position = Vector3(0, 1.0, 4.2)
			cam.look_at(Vector3(0, 1.0, 0))
		"reflect":
			var ia := _ia_wall_texture()
			var stars := _stars_texture()
			_quad(Vector3(-2.2, 1.0, 0), _mat({albedo_texture = ia, alpha_as = 1, reflect_space = 1,
				reflect_texture = stars, reflect_strength = 1.0, reflect_scale = Vector2(2, 2)}), false)
			_quad(Vector3(0, 1.0, 0), _mat({albedo_texture = ia, alpha_as = 1, reflect_space = 0,
				reflect_texture = load("res://textures/sky/cloudy_sky_1.res"), reflect_strength = 0.9}), false)
			_quad(Vector3(2.2, 1.0, 0), _mat({albedo_texture = ia, alpha_as = 2,
				glow_color = Color(1.0, 0.8, 0.45, 1.0)}), false)
			cam.position = Vector3(0, 1.0, 4.2)
			cam.look_at(Vector3(0, 1.0, 0))
		"push":
			var grey := _coin_texture()
			var sets := [{}, {push = Vector4(1.7, 1.35, 0.45, 0.0), push_wrap = false},
				{push = Vector4(2.3, 1.7, 0.5, -0.05), push_wrap = true}]
			for i in 3:
				var props: Dictionary = sets[i].duplicate()
				props.albedo_texture = grey
				props.tint_mode = 0.0
				var s := MeshInstance3D.new()
				var sm := SphereMesh.new()
				sm.radius = 0.9
				sm.height = 1.8
				s.mesh = sm
				s.material_override = _mat(props)
				s.position = Vector3(-2.1 + i * 2.1, 1.0, 0)
				add_child(s)
			cam.position = Vector3(0, 1.2, 4.6)
			cam.look_at(Vector3(0, 1.0, 0))


func _first(dir: String) -> String:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".res") or f.ends_with(".res.remap"):
			return f.trim_suffix(".remap")
	return ""


func _mat(props: Dictionary) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = TEXTURED
	for k in props:
		m.set_shader_parameter(k, props[k])
	return m


## A 2 x 2 m upright quad (subdivided 4 x 4), vertex alpha 0.75 at the top falling to 0 at
## the bottom when `paint`, else 1.
func _quad(pos: Vector3, m: ShaderMaterial, paint: bool) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 4
	for y in n + 1:
		for x in n + 1:
			var u := float(x) / n
			var v := float(y) / n
			st.set_color(Color(1, 1, 1, 0.75 * (1.0 - v) if paint else 1.0))
			st.set_uv(Vector2(u, v))
			st.set_normal(Vector3(0, 0, 1))
			st.add_vertex(Vector3(u * 2.0 - 1.0, 1.0 - v * 2.0, 0))
	for y in n:
		for x in n:
			var i := y * (n + 1) + x
			st.add_index(i)
			st.add_index(i + 1)
			st.add_index(i + n + 1)
			st.add_index(i + 1)
			st.add_index(i + n + 2)
			st.add_index(i + n + 1)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = m
	mi.position = pos
	add_child(mi)


## Cloth-ish colour with blotchy alpha (the "torn" pattern), 64 x 64.
func _noise_alpha_texture() -> Texture2D:
	var noise := FastNoiseLite.new()
	noise.frequency = 0.09
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var a := clampf(noise.get_noise_2d(x, y) * 0.8 + 0.55, 0.0, 1.0)
			img.set_pixel(x, y, Color(0.85, 0.78, 0.62, a))
	return ImageTexture.create_from_image(img)


## IA "building": intensity = plaster with dark frames, alpha = window panes (the mask).
func _ia_wall_texture() -> Texture2D:
	var img := Image.create(64, 64, false, Image.FORMAT_LA8)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.2
	for y in 64:
		for x in 64:
			var wx := x % 32
			var wy := y % 32
			var pane := wx > 8 and wx < 24 and wy > 6 and wy < 26 and wx != 16 and wy != 16
			var frame := wx >= 7 and wx <= 25 and wy >= 5 and wy <= 27 and not pane
			var i := 0.15 if pane else 0.3 if frame else 0.7 + noise.get_noise_2d(x, y) * 0.12
			img.set_pixel(x, y, Color(i, i, i, 1.0 if pane else 0.0))
	return ImageTexture.create_from_image(img)


## A grey embossed "coin" face: rings and a star, 64 x 64.
func _coin_texture() -> Texture2D:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var p := Vector2(x - 31.5, y - 31.5) / 32.0
			var r := p.length()
			var ang := atan2(p.y, p.x)
			var star := r < 0.45 + 0.15 * cos(ang * 5.0)
			var v := 0.55 + 0.3 * cos(r * 18.0) * 0.5
			if star:
				v = 0.85 - r * 0.5
			if r > 0.85:
				v = 0.75 - (r - 0.85) * 2.0
			img.set_pixel(x, y, Color(v, v, v))
	return ImageTexture.create_from_image(img)


func _stars_texture() -> Texture2D:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.03, 0.04, 0.12))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 40:
		var b := rng.randf_range(0.5, 1.0)
		img.set_pixel(rng.randi() % 64, rng.randi() % 64, Color(b, b, b * 0.9 + 0.1))
	return ImageTexture.create_from_image(img)


func _process(_d: float) -> void:
	_frames += 1
	if _frames == 10:
		get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/shot.png")
		get_tree().quit()
