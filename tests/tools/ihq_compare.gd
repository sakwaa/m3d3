extends Node3D
## Side by side, close up: each texture plain (Off), with its Hi-res copy (lod_mode 3, if it has
## one), with its IHQ layer (lod_mode 4, from tests/tools/ihq_detail.tscn) and with the
## colour-keeping IHQ layer (lod_mode 5, KEEP=1). Columns: Off, Hi-res, IHQ, IHQ colour; a row
## per texture. Factors: IHQ_F / IHQ_FC = name:f,... DIST=metres (camera distance; default close up).
##   TEXTURES=res://a.res,... OUT=dir godot --path . --resolution 1500x1000 res://tests/tools/ihq_compare.tscn

const SHADER := "res://addons/n64_runtime/shaders/n64_textured.gdshader"
const HIRES := "res://textures/detail/hires/"
const IHQ := "res://textures/detail/ihq/"

var _frames := 0


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.12, 0.12, 0.14)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(1, 1, 1)
	add_child(env)
	var list := OS.get_environment("TEXTURES").split(",", false)
	var size := 1.0
	var gap := 0.08
	for row in list.size():
		var p: String = list[row]
		var t := load(p) as N64Texture
		var name := p.get_file().get_basename()
		var ihq_path := IHQ + name + "_ihq.res"
		var hi_path := HIRES + name + "_hi.res"
		var ihqc_path := IHQ + name + "_ihqc.res"
		for col in 4:
			var m := ShaderMaterial.new()
			m.shader = load(SHADER)
			m.set_shader_parameter(&"albedo_texture", t)
			m.set_shader_parameter(&"has_texture", true)
			if col == 1 and ResourceLoader.exists(hi_path):
				m.set_shader_parameter(&"lod_mode", 3)
				m.set_shader_parameter(&"detail_texture", load(hi_path))
				m.set_shader_parameter(&"detail", Vector2(1.0, 0.33))
			elif col == 2 and ResourceLoader.exists(ihq_path):
				m.set_shader_parameter(&"lod_mode", 4)
				m.set_shader_parameter(&"detail_texture", load(ihq_path))
				m.set_shader_parameter(&"detail", Vector2(1.0, _factor(name, "IHQ_F")))
			elif col == 3 and ResourceLoader.exists(ihqc_path):
				m.set_shader_parameter(&"lod_mode", 5)
				m.set_shader_parameter(&"detail_texture", load(ihqc_path))
				m.set_shader_parameter(&"detail", Vector2(1.0, _factor(name, "IHQ_FC")))
			var q := MeshInstance3D.new()
			var qm := QuadMesh.new()
			qm.size = Vector2(size, size)
			q.mesh = qm
			q.material_override = m
			q.position = Vector3((col - 1.5) * (size + gap), -(row - (list.size() - 1) * 0.5) * (size + gap), 0.0)
			add_child(q)
	var cam := Camera3D.new()
	cam.fov = 40.0
	var dist := float(OS.get_environment("DIST")) if OS.get_environment("DIST") != "" else (size + gap) * list.size() * 1.45
	cam.position = Vector3(0, 0, dist)
	add_child(cam)
	cam.current = true


## The fitted factor, read back from the tool's log of it (`env`=name:f,...), else 0.25.
func _factor(name: String, env: String) -> float:
	for kv in OS.get_environment(env).split(",", false):
		var a := kv.split(":")
		if a[0] == name:
			return float(a[1])
	return 0.25


func _process(_d: float) -> void:
	_frames += 1
	if _frames == 6:
		for c in get_tree().root.find_children("*", "CanvasLayer", true, false):
			c.visible = false
	if _frames == 10:
		get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/compare.png")
		get_tree().quit()
