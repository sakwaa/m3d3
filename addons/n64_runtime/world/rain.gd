@tool
class_name Rain
extends MeshInstance3D
## The rain streaks (n64_rain.gdshader) and their splashes (n64_splash.gdshader, a child):
## a mesh each, placed and animated entirely on the GPU around whatever camera draws it, so
## they need no updates. How hard it
## rains, the wind and the wetness are shader globals (DynamicSky sets them from the weather).

const SHADER := preload("res://addons/n64_runtime/shaders/n64_rain.gdshader")
const SPLASH_SHADER := preload("res://addons/n64_runtime/shaders/n64_splash.gdshader")
## Splashes at full rain.
const SPLASHES := 520
## Streaks at full rain (n64_rain.x picks how many of them show), in a box that much smaller
## than the shader's default (same density close by; the sheet carries it further out).
const STREAKS := 800
const BOX := Vector3(32.0, 18.0, 32.0)
const SHEET_SHADER := preload("res://addons/n64_runtime/shaders/n64_rain_sheet.gdshader")
## The far sheet: cards round the camera, at this radius and height.
const SHEET_CARDS := 12
const SHEET_RADIUS := 15.0
const SHEET_HEIGHT := 22.0


func _init() -> void:
	name = "Rain"
	top_level = true
	mesh = make_mesh(STREAKS)
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter(&"box", BOX)
	material_override = m
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Drawn wherever the camera is: never culled.
	extra_cull_margin = 16384.0
	var splashes := MeshInstance3D.new()
	splashes.name = "Splashes"
	splashes.mesh = make_splash_mesh(SPLASHES)
	var sm := ShaderMaterial.new()
	sm.shader = SPLASH_SHADER
	splashes.material_override = sm
	splashes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(splashes, false, INTERNAL_MODE_BACK)
	var sheet := MeshInstance3D.new()
	sheet.name = "Sheet"
	sheet.mesh = make_sheet_mesh()
	var shm := ShaderMaterial.new()
	shm.shader = SHEET_SHADER
	sheet.material_override = shm
	sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sheet.extra_cull_margin = 16384.0
	add_child(sheet, false, INTERNAL_MODE_BACK)


## The far sheet: SHEET_CARDS quads round the camera (local: it's moved there in the shader),
## facing in; UV.x round the ring, UV.y down.
static func make_sheet_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in SHEET_CARDS:
		var a0 := TAU * i / SHEET_CARDS
		var a1 := TAU * (i + 1) / SHEET_CARDS
		var p0 := Vector3(cos(a0), 0.0, sin(a0)) * SHEET_RADIUS
		var p1 := Vector3(cos(a1), 0.0, sin(a1)) * SHEET_RADIUS
		var top := SHEET_HEIGHT * 0.6
		var bottom := -SHEET_HEIGHT * 0.4
		var u0 := float(i) / SHEET_CARDS
		var u1 := float(i + 1) / SHEET_CARDS
		for c in [[p0, top, u0, 0.0], [p1, top, u1, 0.0], [p1, bottom, u1, 1.0], [p0, top, u0, 0.0], [p1, bottom, u1, 1.0], [p0, bottom, u0, 1.0]]:
			st.set_uv(Vector2(c[2], c[3]))
			st.add_vertex(c[0] + Vector3.UP * c[1])
	var mesh := st.commit()
	mesh.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	return mesh


## `count` streak quads with seeds in CUSTOM0 (xyz = place in the box, w = pick).
static func make_mesh(count: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 64
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	for i in count:
		var seed := Color(rng.randf(), rng.randf(), rng.randf(), (i + rng.randf()) / count)
		for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]:
			st.set_custom(0, seed)
			st.set_uv(corner)
			st.add_vertex(Vector3.ZERO)
	var mesh := st.commit()
	mesh.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	return mesh


## `count` splashes, a ring quad each: CUSTOM0 = (seed x, seed z, phase, pick).
static func make_splash_mesh(count: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 65
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	for i in count:
		var seed := Color(rng.randf(), rng.randf(), rng.randf(), (i + rng.randf()) / count)
		for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]:
			st.set_custom(0, seed)
			st.set_uv(corner)
			st.add_vertex(Vector3.ZERO)
	var mesh := st.commit()
	mesh.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	return mesh
