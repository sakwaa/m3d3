class_name MeshOptimize
## Generated meshes swapped for their build-optimized copies (props, stalls, signs, doorway
## trim: built from script in game). The export runs each generator's mesh through the
## build's Blender pass and stores the result on the node (metadata OPTIMIZED: key of the
## generated mesh -> optimized mesh); in game a generator hands its fresh mesh to pick(), and
## gets the stored copy back when it built the very same mesh (else its own: settings changed
## since the export, or none stored).

const OPTIMIZED := &"_optimized_meshes"


## A key for `mesh`'s geometry (every surface's vertices, indices, UVs and colours).
static func key(mesh: ArrayMesh) -> int:
	var parts := []
	for s in mesh.get_surface_count():
		var a := mesh.surface_get_arrays(s)
		parts.append([a[Mesh.ARRAY_VERTEX], a[Mesh.ARRAY_INDEX], a[Mesh.ARRAY_TEX_UV], a[Mesh.ARRAY_COLOR]])
	return hash(parts)


## `mesh`, or the optimized copy stored on `node` for it.
static func pick(node: Node, mesh: ArrayMesh) -> ArrayMesh:
	if mesh == null or not node.has_meta(OPTIMIZED):
		return mesh
	var stored: Dictionary = node.get_meta(OPTIMIZED)
	var hit = stored.get(key(mesh))
	if hit is ArrayMesh:
		# The generator's materials (they may be shared or set after): onto the copy.
		for s in mini(mesh.get_surface_count(), hit.get_surface_count()):
			if mesh.surface_get_material(s):
				hit.surface_set_material(s, mesh.surface_get_material(s))
		return hit
	return mesh
