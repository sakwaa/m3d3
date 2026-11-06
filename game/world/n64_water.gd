class_name N64Water
extends MeshInstance3D
## Water surface (use the n64_water shader, e.g. game/materials/water.tres, on a subdivided
## plane) with an optional low-res planar reflection: a camera mirrored below the water
## renders the scene into a small texture, which the water shows rippled by its waves.
## Only renders while the water is on screen. The water must be level (flat in X / Z).

## Visual layer of water surfaces (left out of reflections).
const WATER_LAYER := 1 << 18

@export var reflections := true:
	set(value):
		reflections = value
		_apply()
## Reflection texture height in pixels (width follows the screen); low = chunkier, cheaper.
@export_range(32, 480, 8) var resolution := 240:
	set(value):
		resolution = value
		_apply()
## How strongly reflections show (they grow towards grazing angles).
@export_range(0.0, 1.0, 0.05) var strength := 0.75:
	set(value):
		strength = value
		_apply()
## How much the waves wobble the reflection.
@export_range(0.0, 0.1, 0.005) var distortion := 0.025:
	set(value):
		distortion = value
		_apply()

var _viewport: SubViewport
var _camera: Camera3D
var _notifier: VisibleOnScreenNotifier3D
var _material: ShaderMaterial


func _ready() -> void:
	layers = WATER_LAYER
	_material = get_active_material(0) as ShaderMaterial
	if _material:
		# Own copy: each water body shows its own reflection.
		_material = _material.duplicate()
		set_surface_override_material(0, _material)
	if Engine.is_editor_hint():
		return
	_viewport = SubViewport.new()
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.positional_shadow_atlas_size = 0
	add_child(_viewport)
	_camera = Camera3D.new()
	_camera.cull_mask = ~WATER_LAYER & 0xFFFFF
	_viewport.add_child(_camera)
	_notifier = VisibleOnScreenNotifier3D.new()
	_notifier.aabb = get_aabb().grow(0.5)
	add_child(_notifier)
	_apply()


func _apply() -> void:
	if _material == null:
		return
	var on := reflections and _viewport != null
	_material.set_shader_parameter(&"reflect_on", on)
	_material.set_shader_parameter(&"reflect_strength", strength)
	_material.set_shader_parameter(&"reflect_distortion", distortion)
	if on:
		_material.set_shader_parameter(&"reflect_tex", _viewport.get_texture())


func _process(_delta: float) -> void:
	if _viewport == null:
		return
	var main := get_viewport().get_camera_3d()
	if not reflections or main == null or not _notifier.is_on_screen() or not is_visible_in_tree():
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	# One water body reflects at a time with the under-water cut (the last one updated).
	var screen := get_viewport().get_visible_rect().size
	_viewport.size = Vector2i(maxi(int(resolution * screen.x / maxf(screen.y, 1.0)), 16), resolution)
	# Mirror the main camera in the water plane. A mirrored basis flips handedness, so the
	# camera looks along the mirrored forward with the mirrored up; the image comes out
	# left-right flipped, which the shader undoes.
	var h := global_position.y
	var p := main.global_position
	var forward := -main.global_basis.z
	var up := main.global_basis.y
	var mp := Vector3(p.x, 2.0 * h - p.y, p.z)
	var mf := Vector3(forward.x, -forward.y, forward.z)
	var mu := Vector3(up.x, -up.y, up.z)
	_camera.global_transform = Transform3D(Basis.looking_at(mf, mu), mp)
	_camera.fov = main.fov
	_camera.near = main.near
	_camera.far = main.far
	_camera.keep_aspect = main.keep_aspect
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Lets our shaders flatten what's under the water during this camera's pass.
	RenderingServer.global_shader_parameter_set(&"n64_reflect_cam", Vector4(mp.x, mp.y, mp.z, h))
