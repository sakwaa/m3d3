extends Node3D
## Render check for the N64 material features: palette swaps (one CI texture, one material,
## three rows), tile mirror vs wrap, dithered fade, faceted vs smooth shine.
## OUT=<dir> [GODOT=…] tools/godot_run.sh --path . --resolution 1280x720 tests/render/n64_features_shot.tscn

const TEXTURED := preload("res://addons/n64_runtime/shaders/n64_textured.gdshader")
const ACTOR := preload("res://addons/n64_runtime/shaders/n64_actor.gdshader")

var _frames := 0


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.22, 0.24, 0.3)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.55, 0.6)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	add_child(sun)
	RenderingServer.global_shader_parameter_set(&"n64_key_light", Vector4(0.4, 0.8, 0.45, 1.0))
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.6, 7.0)
	cam.fov = 50
	add_child(cam)
	cam.look_at(Vector3(0, 0.9, 0))

	_lit_floor()
	# Palette: a CI texture, its palette kept, two swaps; three boxes share one material.
	var ci := _find_ci()
	print("CI texture: ", ci.resource_path if ci else "none")
	if ci:
		var pt := N64PaletteTexture.from_texture(ci, ci.get(&"palette"))
		pt.add_shifted(0.33, 1.2, 1.0)
		pt.add_shifted(0.62, 0.6, 0.85)
		var m := ShaderMaterial.new()
		m.shader = TEXTURED
		N64Materials.use_palette(m, pt)
		for i in 3:
			var b := _box(Vector3(-2.6 + i * 1.05, 2.2, 0), m)
			N64Materials.set_palette_row(b, i)
	# Wrap vs mirror: the same texture, UVs over 2 x 2 repeats.
	var door: Texture2D = load("res://textures/doors/red_flush_number.res")
	for i in 2:
		var m := ShaderMaterial.new()
		m.shader = TEXTURED
		m.set_shader_parameter(&"albedo_texture", door)
		m.set_shader_parameter(&"uv_scale", Vector2(2, 2))
		m.set_shader_parameter(&"wrap_s", 1 if i == 1 else 0)
		m.set_shader_parameter(&"wrap_t", 1 if i == 1 else 0)
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(1.2, 1.2)
		q.mesh = qm
		q.material_override = m
		q.position = Vector3(0.9 + i * 1.3, 2.2, 0)
		add_child(q)
	# Fade: actor material at 1, 0.66, 0.33 (magic square) and 0.5 noise.
	for i in 4:
		var m := ShaderMaterial.new()
		m.shader = ACTOR
		m.set_shader_parameter(&"albedo_color", Color(0.9, 0.5, 0.3))
		m.set_shader_parameter(&"fade_noise", i == 3)
		var s := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.4
		sm.height = 0.8
		s.mesh = sm
		s.material_override = m
		s.position = Vector3(-2.4 + i * 0.95, 0.9, 0)
		add_child(s)
		s.set_instance_shader_parameter(&"fade", [1.0, 0.66, 0.33, 0.5][i])
	# Shine: smooth vs faceted chrome on a low-poly gem.
	for i in 2:
		var m := ShaderMaterial.new()
		m.shader = ACTOR
		m.set_shader_parameter(&"albedo_color", Color(0.5, 0.7, 1.0))
		m.set_shader_parameter(&"shine_texture", load("res://textures/shine/chrome.res"))
		m.set_shader_parameter(&"shine_strength", 1.0)
		m.set_shader_parameter(&"shine_mode", 1)
		m.set_shader_parameter(&"shine_facets", i == 1)
		var s := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.45
		sm.height = 0.9
		sm.radial_segments = 7
		sm.rings = 3
		s.mesh = sm
		s.material_override = m
		s.position = Vector3(1.4 + i * 1.1, 0.9, 0)
		s.rotation_degrees = Vector3(20, 15, 0)
		add_child(s)


## A tiled floor (n64_textured, a 1 m vertex grid) under a live torch-coloured omni light:
## per-vertex lighting shows the N64's blotchy falloff along the grid.
func _lit_floor() -> void:
	var m := ShaderMaterial.new()
	m.shader = TEXTURED
	m.set_shader_parameter(&"albedo_texture", load("res://textures/tiles/" + DirAccess.get_files_at("res://textures/tiles")[0].trim_suffix(".remap")))
	m.set_shader_parameter(&"uv_scale", Vector2(6, 3))
	var f := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(8, 4)
	pm.subdivide_width = 7
	pm.subdivide_depth = 3
	f.mesh = pm
	f.material_override = m
	f.position = Vector3(0, -0.2, 0.6)
	add_child(f)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.6, 0.3)
	l.light_energy = 3.0
	l.omni_range = 3.0
	l.position = Vector3(-0.6, 0.4, 1.2)
	add_child(l)


func _box(pos: Vector3, m: Material, size := Vector3(0.9, 0.9, 0.9)) -> MeshInstance3D:
	var b := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	b.mesh = bm
	b.material_override = m
	b.position = pos
	b.rotation_degrees = Vector3(0, 0 if size.z < 0.5 else 25, 0)
	add_child(b)
	return b


func _find_ci() -> Texture2D:
	for dir in ["res://textures/fabric", "res://textures/patterns", "res://textures/signs", "res://textures/doors"]:
		var d := DirAccess.open(dir)
		if d == null:
			continue
		for f in d.get_files():
			if not f.ends_with(".res"):
				continue
			var t = load(dir + "/" + f)
			if t and t.get(&"format") != null and int(t.get(&"format")) >= 7 and (t.get(&"palette") as PackedColorArray).size() > 4:
				return t
	return null


func _process(_d: float) -> void:
	_frames += 1
	if _frames == 8:
		var out := OS.get_environment("OUT")
		DirAccess.make_dir_recursive_absolute(out)
		get_viewport().get_texture().get_image().save_png(out + "/shot.png")
		get_tree().quit()
