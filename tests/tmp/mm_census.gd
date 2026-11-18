extends Node
## MultiMeshInstance3Ds in a zone grouped by parent / name prefix: count, instances, triangles.
func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(zone)
	for i in 200:
		await get_tree().process_frame
	var by := {}
	for mmi: MultiMeshInstance3D in zone.find_children("*", "MultiMeshInstance3D", true, false):
		var mm := mmi.multimesh
		var tris := 0
		if mm and mm.mesh:
			for s in mm.mesh.get_surface_count():
				var a := mm.mesh.surface_get_arrays(s)
				tris += (a[Mesh.ARRAY_INDEX].size() if a[Mesh.ARRAY_INDEX] else a[Mesh.ARRAY_VERTEX].size()) / 3
		var key := "%s/%s" % [mmi.get_parent().name, String(mmi.name).left(9)]
		var e: Array = by.get(key, [0, 0, 0, 0.0])
		var n := mm.instance_count if mm else 0
		by[key] = [e[0] + 1, e[1] + n, e[2] + n * tris, maxf(e[3], mmi.visibility_range_end)]
	for k in by:
		print("MM %-34s %4d nodes %6d inst %7d tris  range_end %.0f" % [k, by[k][0], by[k][1], by[k][2], by[k][3]])
	get_tree().quit()
