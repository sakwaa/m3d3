class_name LevelLights
extends RefCounted
## Baked Vertex / Timed Dynamic levels: the level's meshes sit on LAYER alone. Lights set to Bake Mode
## Static are baked into the level's vertices, so they must not light it live as well:
## they lose LAYER from their cull mask (they still light actors). Every other light keeps
## it and lights the level live, on top of the bake.

const LAYER := 1 << 17


## Updates the cull masks of all Light3Ds under `root`.
static func apply(root: Node) -> void:
	if root is Light3D:
		var light := root as Light3D
		if light.light_bake_mode == Light3D.BAKE_STATIC:
			light.light_cull_mask &= ~LAYER
		else:
			light.light_cull_mask |= LAYER
	for child in root.get_children():
		apply(child)
