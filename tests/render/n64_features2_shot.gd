extends Node3D
## Render checks, second set. MODE=prim (smoke sprites through a wall: plain vs primitive
## depth), water (average / multiply / difference / lava), detail (texture LOD off / sharpen /
## detail up close). OUT=<dir> tools/godot_run.sh --path . tests/render/n64_features2_shot.tscn

const MIX := preload("res://addons/n64_runtime/shaders/n64_effect_mix.gdshader")
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
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	RenderingServer.global_shader_parameter_set(&"n64_ambient_light", Color(1, 1, 1))
	var cam := Camera3D.new()
	add_child(cam)
	match OS.get_environment("MODE"):
		"prim":
			for i in 2:
				var wall := MeshInstance3D.new()
				var bm := BoxMesh.new()
				bm.size = Vector3(1.6, 2.0, 0.2)
				wall.mesh = bm
				var wm := StandardMaterial3D.new()
				wm.albedo_color = Color(0.35, 0.25, 0.2)
				wall.material_override = wm
				wall.position = Vector3(-1.0 + i * 2.0, 1.0, 0)
				add_child(wall)
				var floor_ := MeshInstance3D.new()
				var pm := PlaneMesh.new()
				pm.size = Vector2(1.8, 2.0)
				floor_.mesh = pm
				var fm := StandardMaterial3D.new()
				fm.albedo_color = Color(0.3, 0.35, 0.25)
				floor_.material_override = fm
				floor_.position = Vector3(-1.0 + i * 2.0, 0, 0.6)
				add_child(floor_)
				var m := ShaderMaterial.new()
				m.shader = MIX
				m.set_shader_parameter(&"sprite", load("res://textures/effects/puff.res"))
				m.set_shader_parameter(&"intensity", true)
				m.set_shader_parameter(&"prim_depth", 0.5 if i == 1 else -1.0)
				var q := MeshInstance3D.new()
				var qm := QuadMesh.new()
				qm.size = Vector2(1, 1)
				q.mesh = qm
				q.material_override = m
				q.scale = Vector3.ONE * 1.3
				q.position = Vector3(-1.0 + i * 2.0, 0.35, 0.15)
				add_child(q)
			cam.position = Vector3(0, 1.6, 3.6)
			cam.look_at(Vector3(0, 0.6, 0))
		"water":
			var mats := []
			for c in 3:
				var w := (load("res://game/materials/water.tres") as ShaderMaterial).duplicate()
				w.set_shader_parameter(&"combine", c)
				w.set_shader_parameter(&"wobble_on", false)
				w.set_shader_parameter(&"opacity", 1.0)
				mats.append(w)
			mats.append(load("res://game/materials/lava.tres"))
			for i in 4:
				var p := MeshInstance3D.new()
				var pm := PlaneMesh.new()
				pm.size = Vector2(1.9, 3)
				pm.subdivide_width = 8
				pm.subdivide_depth = 8
				p.mesh = pm
				p.material_override = mats[i]
				p.position = Vector3(-3.0 + i * 2.0, 0, 0)
				add_child(p)
			cam.position = Vector3(0, 3.2, 4.2)
			cam.look_at(Vector3(0, 0, 0))
		"detail":
			var tex: Texture2D = load("res://textures/ground/" + DirAccess.get_files_at("res://textures/ground")[0].trim_suffix(".remap"))
			print("ground texture ", tex.resource_path)
			for i in 3:
				var m := ShaderMaterial.new()
				m.shader = TEXTURED
				m.set_shader_parameter(&"albedo_texture", tex)
				m.set_shader_parameter(&"lod_mode", int(OS.get_environment("LODMODE")) if OS.get_environment("LODMODE") != "" else i)
				m.set_shader_parameter(&"detail_texture", load("res://textures/detail/grime_detail.res"))
				m.set_shader_parameter(&"detail", Vector2(6.0, 1.0))
				var p := MeshInstance3D.new()
				var pm := PlaneMesh.new()
				pm.size = Vector2(1.0, 1.6)
				p.mesh = pm
				p.material_override = m
				p.position = Vector3(-1.05 + i * 1.05, 0, 0)
				add_child(p)
			cam.position = Vector3(0, 0.12, 0.45)
			cam.look_at(Vector3(0, 0, 0.0))


func _process(_d: float) -> void:
	_frames += 1
	if _frames == 10:
		get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/shot.png")
		get_tree().quit()
