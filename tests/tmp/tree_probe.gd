extends Node3D
## Probe: trees in a zone (WorldTree nodes, their parts, tris, materials).
func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(zone)
	await get_tree().process_frame
	await get_tree().process_frame
	var trees := get_tree().root.find_children("*", "", true, false).filter(func(n): return n is WorldTree)
	print("[tree] WorldTree nodes: ", trees.size())
	for t in trees.slice(0, 5):
		print("[tree] ", t.get_path(), " species=", t.get(&"species"), " seed=", t.get(&"seed"))
		for c in t.find_children("*", "GeometryInstance3D", true, false):
			var gi := c as GeometryInstance3D
			var m: Mesh = gi.mesh if gi is MeshInstance3D else null
			print("    ", c.name, " ", c.get_class(), " tris=", (m.get_faces().size() / 3) if m else -1, " vis=", gi.visibility_range_begin, "-", gi.visibility_range_end)
	var lr: LevelRoot = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	var kinds := {}
	for p in lr.data.get(&"props") if lr.data.get(&"props") != null else []:
		kinds[str(p.get(&"kind"))] = kinds.get(str(p.get(&"kind")), 0) + 1
	print("[tree] prop kinds: ", kinds)
	get_tree().quit()
