extends Node
## Triangle counts: every species preset (seeds 1-5: min / avg / max, bark vs leaves) and,
## with ZONE_LAYOUT=<layout json>, each tree in a zone layout.
##   godot --headless --path . tests/trees/tri_count.tscn


func _ready() -> void:
	var dir := "res://addons/n64_level_tools/trees/species/"
	print("species               min  avg  max   (bark / leaves avg)")
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".tres"):
			continue
		var sp: Resource = load(dir + f)
		var lo := 1 << 30
		var hi := 0
		var sum := 0
		var bark := 0
		for s in range(1, 6):
			var m: ArrayMesh = TreeBuilder.build(sp, s)
			var n := TreeBuilder.triangles(m)
			lo = mini(lo, n)
			hi = maxi(hi, n)
			sum += n
			bark += (m.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		print("%-20s %4d %4d %4d   (%d / %d)" % [f.get_basename(), lo, sum / 5, hi, bark / 5, sum / 5 - bark / 5])
	var layout := OS.get_environment("ZONE_LAYOUT")
	if layout != "":
		var L: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(layout))
		var total := 0
		for group in ["inside", "outside"]:
			for t: Array in L.edge_trees[group]:
				var n := TreeBuilder.triangles(TreeBuilder.build(load(dir + String(t[2]) + ".tres"), int(t[3])))
				total += n
				print("%-8s %-14s seed %3d at (%5.1f, %5.1f): %d" % [group, t[2], int(t[3]), t[0], t[1], n])
		if L.has("tree"):
			var n := TreeBuilder.triangles(TreeBuilder.build(load(dir + "sycamore.tres"), 7))
			total += n
			print("lane     sycamore       seed   7: %d" % n)
		print("zone trees total: %d" % total)
	get_tree().quit()
