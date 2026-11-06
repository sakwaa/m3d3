@tool
class_name DarknessVolume
extends MeshInstance3D
## Box that fades everything rendered inside it to black along its local -Z, per pixel:
## level geometry, props and characters alike (OoT doorway / exit darkness). The origin
## is the threshold; the box spans box_min..box_max in local space.

const SHADER := preload("res://game/world/darkness_volume.gdshader")

@export var box_min := Vector3(-1.5, -0.5, -5.0):
	set(value):
		box_min = value
		_rebuild()
@export var box_max := Vector3(1.5, 3.5, 0.0):
	set(value):
		box_max = value
		_rebuild()
## Depth fraction (0 = threshold, 1 = deep end) where darkening begins / is total.
@export_range(0.0, 1.0) var fade_start := 0.1:
	set(value):
		fade_start = value
		_rebuild()
@export_range(0.0, 1.0) var fade_end := 0.8:
	set(value):
		fade_end = value
		_rebuild()
## The opening at the threshold (local x from / to, y from / to; zero = none): in front of
## the threshold and on its wall (z >= 0), only what lies within the opening darkens, so
## the margin around the box doesn't shade the room's wall around the doorway.
@export var opening := Vector4.ZERO:
	set(value):
		opening = value
		_rebuild()
## The opening's arch (OpeningShape.Top, springing height, then round: half width, rise;
## pointed: arc centre x, radius): above the springing only what's under the arch darkens.
@export var opening_arch := Vector4.ZERO:
	set(value):
		opening_arch = value
		_rebuild()
## Show black past the box's far end instead of whatever lies beyond (sky, void).
@export var black_beyond := true:
	set(value):
		black_beyond = value
		_rebuild()


func _validate_property(property: Dictionary) -> void:
	if property.name in [&"mesh", &"material_override"]:
		property.usage = PROPERTY_USAGE_NONE


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	var size := (box_max - box_min).abs()
	var center := (box_min + box_max) * 0.5
	var box := BoxMesh.new()
	box.size = size
	var arrays := box.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] += center
	arrays[Mesh.ARRAY_VERTEX] = verts
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am

	var mat := material_override as ShaderMaterial
	if mat == null:
		mat = ShaderMaterial.new()
		mat.shader = SHADER
		material_override = mat
	# Last of the transparent pass: anything drawn over the corridor afterwards (editor
	# wires / grids, effects) would skip the darkening and glow in the black.
	mat.render_priority = Material.RENDER_PRIORITY_MAX
	mat.set_shader_parameter(&"box_min", box_min)
	mat.set_shader_parameter(&"box_max", box_max)
	mat.set_shader_parameter(&"fade_start", fade_start)
	mat.set_shader_parameter(&"fade_end", fade_end)
	mat.set_shader_parameter(&"black_beyond", black_beyond)
	mat.set_shader_parameter(&"opening", opening)
	mat.set_shader_parameter(&"opening_arch", opening_arch)
