class_name ActorFaces
extends RefCounted
## Swap slots of modelled characters (eyes, mouth): faces in a slot show one of the
## slot's frames (open / half / closed, mouth shapes). The built mesh carries the slots
## as metadata ("n64_swap_slots": slot -> {surface, frames}).


static func slots(mesh: MeshInstance3D) -> Dictionary:
	return mesh.get_meta(&"n64_swap_slots", {}) if mesh else {}


## Shows frame `frame` of `slot` on this mesh instance (per instance: other copies of the
## character keep theirs).
static func set_frame(mesh: MeshInstance3D, slot: StringName, frame: int) -> void:
	var s: Dictionary = slots(mesh).get(slot, {})
	var frames: Array = s.get("frames", [])
	if frames.is_empty():
		return
	var surface: int = s.surface
	var mat := mesh.get_surface_override_material(surface) as ShaderMaterial
	if mat == null:
		var base := mesh.mesh.surface_get_material(surface) as ShaderMaterial
		if base == null:
			return
		mat = base.duplicate()
		mesh.set_surface_override_material(surface, mat)
	mat.set_shader_parameter(&"albedo_texture", frames[clampi(frame, 0, frames.size() - 1)])
