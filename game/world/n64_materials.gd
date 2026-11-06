class_name N64Materials
extends RefCounted
## Builds N64-look materials (N64 fog, 3-point filtering, shine instead of specular) and
## converts plain Godot materials to them, so nothing in the game uses Godot's own
## specular / roughness lighting or misses the N64 fog.

const TEXTURED := preload("res://addons/n64_runtime/shaders/n64_textured.gdshader")
const ACTOR := preload("res://addons/n64_runtime/shaders/n64_actor.gdshader")
const CHROME := preload("res://textures/shine/chrome.res")
const GLOSS := preload("res://textures/shine/gloss.res")
const WATER := preload("res://textures/shine/water.res")

enum Shine { NONE, GLOSS, METAL, WATER }


## Prop / scenery material: colour x optional texture, optional shine and glint.
static func textured(color: Color, texture: Texture2D = null, shine := Shine.NONE, strength := 0.5, hilite := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = TEXTURED
	m.set_shader_parameter(&"albedo_color", color)
	m.set_shader_parameter(&"albedo_texture", texture)
	m.set_shader_parameter(&"has_texture", texture != null)
	_set_shine(m, shine, strength, hilite)
	return m


## Character / pickup material (stencil for the projected shadow).
static func actor(color: Color, texture: Texture2D = null, shine := Shine.NONE, strength := 0.5, hilite := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ACTOR
	m.set_shader_parameter(&"albedo_color", color)
	if texture:
		m.set_shader_parameter(&"albedo_texture", texture)
	_set_shine(m, shine, strength, hilite)
	return m


## N64 version of a plain Godot material (albedo colour / texture; metallic becomes metal
## shine, low roughness becomes gloss). Other materials pass through unchanged.
static func from_material(material: Material) -> Material:
	var std := material as BaseMaterial3D
	if std == null:
		return material
	var shine := Shine.NONE
	var strength := 0.0
	if std.metallic > 0.1:
		shine = Shine.METAL
		strength = std.metallic * 0.8
	elif std.roughness < 0.6:
		shine = Shine.GLOSS
		strength = (0.6 - std.roughness) * 1.5
	var m := textured(std.albedo_color, std.albedo_texture, shine, strength, 0.6 if shine != Shine.NONE else 0.0)
	m.set_shader_parameter(&"uv_scale", Vector2(std.uv1_scale.x, std.uv1_scale.y))
	return m


static func _set_shine(m: ShaderMaterial, shine: Shine, strength: float, hilite: float) -> void:
	if shine != Shine.NONE:
		m.set_shader_parameter(&"shine_texture", {Shine.GLOSS: GLOSS, Shine.METAL: CHROME, Shine.WATER: WATER}[shine])
		m.set_shader_parameter(&"shine_strength", strength)
		m.set_shader_parameter(&"shine_mode", 1 if shine == Shine.METAL else 0)
	m.set_shader_parameter(&"hilite_strength", hilite)
