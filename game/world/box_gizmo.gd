@tool
class_name BoxGizmo
extends RefCounted
## Editor-only outline of a box volume (CameraZone, TriggerVolume): an internal, unsaved
## MeshInstance3D child drawn through walls.


## Draws (or clears) a `size` box centred on `owner_node` in `color`; returns the gizmo.
static func draw(owner_node: Node3D, gizmo: MeshInstance3D, size: Vector3, color: Color) -> MeshInstance3D:
	if gizmo == null:
		gizmo = MeshInstance3D.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = color
		mat.no_depth_test = true
		gizmo.material_override = mat
		gizmo.mesh = ImmediateMesh.new()
		owner_node.add_child(gizmo, false, Node.INTERNAL_MODE_BACK)
	var im: ImmediateMesh = gizmo.mesh
	im.clear_surfaces()
	if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		return gizmo
	var h := size * 0.5
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for a in 8:
		var p := Vector3(h.x if a & 1 else -h.x, h.y if a & 2 else -h.y, h.z if a & 4 else -h.z)
		for bit in [1, 2, 4]:
			if not a & bit:
				var b: int = a | bit
				im.surface_add_vertex(p)
				im.surface_add_vertex(Vector3(h.x if b & 1 else -h.x, h.y if b & 2 else -h.y, h.z if b & 4 else -h.z))
	im.surface_end()
	return gizmo
