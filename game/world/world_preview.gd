class_name WorldPreview
extends RefCounted
## Editor-only translucent boxes/arrows for trigger-style nodes. Built as internal
## children so they're never saved and never exist at runtime.


static func box(parent: Node3D, size: Vector3, color: Color, arrow_z := 0) -> MeshInstance3D:
	if not Engine.is_editor_hint():
		return null
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position.y = size.y * 0.5
	mi.material_override = _material(Color(color, 0.25))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi, false, Node.INTERNAL_MODE_BACK)
	if arrow_z != 0:
		mi.add_child(arrow(color, arrow_z, Vector3(0, -size.y * 0.5 + 0.05, size.z * 0.5 * arrow_z)))
	return mi


## Flat arrow on the ground pointing along +Z (direction 1) or -Z (direction -1).
static func arrow(color: Color, direction: int, offset := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := PrismMesh.new()
	mesh.size = Vector3(0.6, 0.8, 0.05)
	mi.mesh = mesh
	mi.rotation.x = PI * 0.5 * direction
	mi.position = offset + Vector3(0, 0, 0.4 * direction)
	mi.material_override = _material(Color(color, 0.8))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat
