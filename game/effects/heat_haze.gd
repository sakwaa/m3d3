@tool
class_name HeatHaze
extends MeshInstance3D
## Air shimmering above something hot (n64_heat_haze.gdshader): a camera-facing card,
## `width` x `height` metres, its bottom on this node. What's behind it wavers and rises;
## what's in front stays sharp. Put one over a fire, a torch, a forge, lava.

const SHADER := preload("res://addons/n64_runtime/shaders/n64_heat_haze.gdshader")
const NOISE := preload("res://addons/n64_runtime/textures/variation_noise.res")

@export_range(0.1, 10.0, 0.05, "suffix:m") var width := 0.8:
	set(v):
		width = v
		_build()
@export_range(0.1, 10.0, 0.05, "suffix:m") var height := 1.4:
	set(v):
		height = v
		_build()
@export_range(0.0, 1.0, 0.05) var amount := 1.0:
	set(v):
		amount = v
		if material_override:
			(material_override as ShaderMaterial).set_shader_parameter(&"amount", v)


func _ready() -> void:
	_build()


func _build() -> void:
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	q.center_offset = Vector3(0, 0.5, 0)
	mesh = q
	scale = Vector3(width, height, 1.0)
	if material_override == null:
		var m := ShaderMaterial.new()
		m.shader = SHADER
		m.set_shader_parameter(&"noise_tex", NOISE)
		m.set_shader_parameter(&"amount", amount)
		m.render_priority = 2
		material_override = m
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
