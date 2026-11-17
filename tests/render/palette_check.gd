extends Node3D
## The awning palette swaps drawn two ways side by side: left their own image (plain
## texture), right the shared indices looked up in their row (n64_textured use_palette).
## The two must match. OUT=<dir> tools/godot_run.sh --path . tests/render/palette_check.tscn

const TEXTURED := preload("res://addons/n64_runtime/shaders/n64_textured.gdshader")
var _frames := 0


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.2, 0.2, 0.2)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 1.0
	add_child(env)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 7.0
	cam.position = Vector3(1.1, 2.5, 5)
	add_child(cam)
	var i := 0
	for f in DirAccess.get_files_at(HouseBuilder.CLOTH_DIR):
		if not f.begins_with("awning_") or f.ends_with("_ci.res"):
			continue
		var t = load(HouseBuilder.CLOTH_DIR + "/" + f)
		if not t is N64PaletteSwap:
			continue
		for side in 2:
			var m := ShaderMaterial.new()
			m.shader = TEXTURED
			m.set_shader_parameter(&"albedo_texture", t)
			if side == 1:
				N64Materials.use_palette(m, t.palette_texture)
			var q := MeshInstance3D.new()
			var qm := QuadMesh.new()
			qm.size = Vector2(1.0, 0.8)
			q.mesh = qm
			q.material_override = m
			q.position = Vector3(side * 1.1 + 0.5, 4.6 - i * 0.9, 0)
			add_child(q)
			if side == 1:
				q.set_instance_shader_parameter(&"palette_row", t.palette_row)
		i += 1


func _process(_d: float) -> void:
	_frames += 1
	if _frames == 8:
		get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/shot.png")
		get_tree().quit()
