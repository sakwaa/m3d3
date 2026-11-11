extends Node
## The Blender mesh pass on generated meshes: a stall, a sign, a passage's trim, a tree and a
## grass carpet tile from a zone; prints triangles before / after per kind.
##   ZONE=res://...tscn godot --path . tests/zones/mesh_dissolve_test.tscn


func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(zone)
	for i in 60:
		await get_tree().process_frame
	var kinds := {}
	for mi in zone.find_children("*", "MeshInstance3D", true, false) + _internal(zone):
		if not mi is MeshInstance3D or not mi.mesh is ArrayMesh or not mi.is_inside_tree():
			continue
		var owner_kind := ""
		var n: Node = mi
		while n and n != zone:
			var sc = n.get_script()
			if sc and sc.resource_path.get_file() in ["market_stall.gd", "signpost.gd", "passage.gd", "door.gd", "world_tree.gd"]:
				owner_kind = sc.resource_path.get_file().get_basename()
				break
			if String(n.name).begins_with("Grass_"):
				owner_kind = "grass carpet"
				break
			n = n.get_parent()
		if owner_kind == "":
			owner_kind = "other: " + String(mi.get_parent().name).left(14) if mi.get_parent() else "other"
			if String(mi.name).begins_with("Chunk") or mi.get_parent() is LevelRoot or String(mi.get_parent().name).begins_with("Level"):
				continue  # (the baked level: the brush pass)
		if not kinds.has(owner_kind):
			kinds[owner_kind] = []
		if not mi.mesh in kinds[owner_kind]:
			kinds[owner_kind].append(mi.mesh)
	for k in kinds:
		var r := BlenderDissolve.dissolve_meshes(kinds[k])
		print("%-14s %3d meshes: %5d -> %5d triangles %s" % [k, kinds[k].size(), r.before, r.after, r.get("error", "")])
	get_tree().quit()


func _internal(n: Node) -> Array:
	var out := []
	for c in n.get_children(true):
		out.append(c)
		out.append_array(_internal(c))
	return out
