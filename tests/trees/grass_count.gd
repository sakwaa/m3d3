extends Node
## Grass cost for a zone: mat triangles and tuft counts (ZONE=res://...tscn).
##   ZONE=res://zones/town1/house_outside_town.tscn godot --headless --path . tests/trees/grass_count.tscn


func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	if OS.get_environment("LEVEL_OVERRIDE") != "":
		var lr: Node = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
		lr.set(&"data", ResourceLoader.load(OS.get_environment("LEVEL_OVERRIDE"), "", ResourceLoader.CACHE_MODE_IGNORE))
	add_child(zone)
	var t0 := Time.get_ticks_msec()
	for i in 90:
		await get_tree().process_frame
	var root: Node = zone.get_node("Level")
	var mat := 0
	var tufts := 0
	var tiles := 0
	var skirt := 0
	for n in root._grass_nodes:
		if n is MeshInstance3D:
			var arr: Array = n.mesh.surface_get_arrays(0)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var col: PackedColorArray = arr[Mesh.ARRAY_COLOR]
			mat += idx.size() / 3
			for t in range(0, idx.size(), 3):
				if col[idx[t]].a < 0.5 or col[idx[t + 1]].a < 0.5 or col[idx[t + 2]].a < 0.5:
					skirt += 1
			tiles += 1
		elif n is MultiMeshInstance3D and String(n.name).begins_with("Tufts"):
			tufts += n.multimesh.instance_count
	print("skirt triangles: %d of the mat's" % skirt)
	for n in root._grass_nodes:
		if n is GrassField:
			var on := 0
			for t in n.tops:
				if t > -1e8:
					on += 1
			print("carpet cells: %d of %d (%.0f m2)" % [on, n.tops.size(), on * n.step * n.step])
	# SPOTS=1: a few places in the carpet (level space x, z, top), nearest the middle first.
	if OS.get_environment("SPOTS") != "":
		for n in root._grass_nodes:
			if n is GrassField:
				var spots := []
				for i in n.tops.size():
					if n.tops[i] > -1e8:
						var x: float = n.origin.x + (i % n.size.x + 0.5) * n.step
						var z: float = n.origin.y + (i / n.size.x + 0.5) * n.step
						spots.append(Vector3(x, n.tops[i], z))
				spots.sort_custom(func(a, b): return Vector2(a.x, a.z).length() < Vector2(b.x, b.z).length())
				print("carpet spots: ", spots.slice(0, 400).slice(0, 400).filter(func(v): return randf() < 0.03))
	print("(%d ms) grass: %d mat tiles, %d mat triangles, %d tufts (near %d tris max, cards %d)" % [Time.get_ticks_msec() - t0, tiles, mat, tufts, tufts * 4, tufts * 2])
	get_tree().quit()
