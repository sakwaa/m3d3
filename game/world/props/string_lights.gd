@tool
class_name StringLights
extends Node3D
## String lights hung along a rope (RopeHang LIGHTS; built by the level from the rope): a
## bulb at each point of `bulbs` (local), a round billboard core (n64_bulb) and a soft
## additive glow round it (n64_bulb_glow), 4 triangles a bulb in one mesh. They glow by the
## lighting schedule's local_lights for the hour (off at noon, on at dusk and night, like
## the window lights), and in the rain. They light the level through its light bake: a
## bake light (OmniLight3D, BAKE_STATIC) every `bake_spacing` metres along them, seen by
## Bake Lighting and the build (which scale lamps by the hour, like the glow), switched
## off in the game (the bake has their light by then).

const CORE := preload("res://addons/n64_runtime/shaders/n64_bulb.gdshader")
const HALO := preload("res://addons/n64_runtime/shaders/n64_bulb_glow.gdshader")
## How lit they look in the editor (no clock there).
const EDITOR_GLOW := 0.6
## How much rain turns them up (by day too).
const RAIN_GLOW := 0.5

@export var bulbs := PackedVector3Array():
	set(v):
		bulbs = v
		_rebuild()
@export var color := Color(1.0, 0.75, 0.4):
	set(v):
		color = v
		_rebuild()
@export var bulb_size := 0.09:
	set(v):
		bulb_size = v
		_rebuild()
@export var glow_size := 0.5:
	set(v):
		glow_size = v
		_rebuild()
@export var flicker := false:
	set(v):
		flicker = v
		_rebuild()
@export_group("Light Bake")
## Whether they light the level when it's baked, how strongly, how far, and how far apart
## the bake lights stand along the string.
@export var bake_light := true:
	set(v):
		bake_light = v
		_rebuild()
@export_range(0.0, 4.0, 0.05) var bake_energy := 1.6:
	set(v):
		bake_energy = v
		_rebuild()
@export_range(0.5, 12.0, 0.25, "suffix:m") var bake_range := 8.0:
	set(v):
		bake_range = v
		_rebuild()
@export_range(0.5, 10.0, 0.25, "suffix:m") var bake_spacing := 3.0:
	set(v):
		bake_spacing = v
		_rebuild()
@export_group("")

var _mesh: MeshInstance3D
var _core: ShaderMaterial
var _halo: ShaderMaterial
var _glow := -1.0
var _lights: Array[OmniLight3D] = []


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	if _mesh == null:
		_mesh = MeshInstance3D.new()
		_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mesh, false, INTERNAL_MODE_BACK)
		_core = ShaderMaterial.new()
		_core.shader = CORE
		_halo = ShaderMaterial.new()
		_halo.shader = HALO
	_core.set_shader_parameter(&"color", color)
	_core.set_shader_parameter(&"radius", bulb_size * 0.5)
	_halo.set_shader_parameter(&"color", color)
	_halo.set_shader_parameter(&"radius", glow_size * 0.5)
	_halo.set_shader_parameter(&"flicker", 1.0 if flicker else 0.0)
	_bake_lights()
	if bulbs.is_empty():
		_mesh.mesh = null
		return
	var m := ArrayMesh.new()
	for material in [_core, _halo]:
		var verts := PackedVector3Array()
		var uvs := PackedVector2Array()
		var uv2 := PackedVector2Array()
		var idx := PackedInt32Array()
		var rng := RandomNumberGenerator.new()
		rng.seed = 11
		for p in bulbs:
			var b := verts.size()
			var r := rng.randf()
			for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				verts.append(p)
				uvs.append(c)
				uv2.append(Vector2(r, 0.0))
			idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = verts
		a[Mesh.ARRAY_TEX_UV] = uvs
		a[Mesh.ARRAY_TEX_UV2] = uv2
		a[Mesh.ARRAY_INDEX] = idx
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		m.surface_set_material(m.get_surface_count() - 1, material)
	# (The quads open up in the shader: room for the glow round the centres.)
	var box := AABB(bulbs[0], Vector3.ZERO)
	for p in bulbs:
		box = box.expand(p)
	m.custom_aabb = box.grow(maxf(glow_size, bulb_size))
	_mesh.mesh = m
	_glow = -1.0
	_update()


## The bake lights: one every bake_spacing metres along the bulbs (the first a half step in),
## visible only where the level is lit (editor, build; Engine meta n64_baking for tools).
func _bake_lights() -> void:
	for l in _lights:
		if is_instance_valid(l):
			l.queue_free()
	_lights.clear()
	if not bake_light or bulbs.size() < 2:
		return
	var baking := Engine.is_editor_hint() or Engine.has_meta(&"n64_baking")
	var along := 0.0
	var next := bake_spacing * 0.5
	for i in range(1, bulbs.size()):
		var a := bulbs[i - 1]
		var b := bulbs[i]
		var seg := a.distance_to(b)
		while next <= along + seg:
			var l := OmniLight3D.new()
			l.position = a.lerp(b, (next - along) / maxf(seg, 0.0001))
			l.light_color = color
			l.light_energy = bake_energy
			l.omni_range = bake_range
			l.light_bake_mode = Light3D.BAKE_STATIC
			l.shadow_enabled = false
			l.visible = baking
			add_child(l)  # (not internal: the bake looks among children; unowned: never saved)
			_lights.append(l)
			next += bake_spacing
		along += seg


func _process(_delta: float) -> void:
	_update()


func _update() -> void:
	if _core == null:
		return
	var g := _target()
	if is_equal_approx(g, _glow):
		return
	_glow = g
	_core.set_shader_parameter(&"glow", g)
	_halo.set_shader_parameter(&"glow", g)
	if _mesh:
		_mesh.visible = not bulbs.is_empty()


## How lit: the schedule's local_lights for the hour (keys blended), turned up in the rain.
func _target() -> float:
	if Engine.is_editor_hint():
		return EDITOR_GLOW
	var gs := get_node_or_null(^"/root/GameState")
	if gs == null or gs.lighting_schedule == null:
		return 1.0
	var keys: Array = gs.lighting_schedule.sorted_keys()
	if keys.is_empty():
		return 1.0
	var b: Vector3 = gs.lighting_schedule.blend_for(gs.time_of_day)
	var v := lerpf(keys[int(b.x)].local_lights, keys[int(b.y)].local_lights, b.z)
	v = maxf(v, float(gs.weather_now.get("rain", 0.0)) * RAIN_GLOW)
	return clampf(v, 0.0, 1.0)
