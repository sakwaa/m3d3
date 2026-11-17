extends SceneTree
func _init() -> void:
	var d: LevelData = load("res://zones/town1/town_1_market_square_level.res")
	var ms: Array = d.baked_meshes()
	print("meshes ", ms.size())
	for m: ArrayMesh in ms:
		for s in m.get_surface_count():
			var a := m.surface_get_arrays(s)
			var pos: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
			for t in range(0, idx.size(), 3):
				var ok := true
				for k in 3:
					var p := pos[idx[t + k]]
					if not (absf(p.z + 1.0) < 0.01 and p.x < -69.9 and p.x > -75.1): ok = false
				if ok:
					var mat := m.surface_get_material(s)
					print(m.resource_name, " s", s, " ", mat.resource_name if mat else "", " tri ", [pos[idx[t]], pos[idx[t+1]], pos[idx[t+2]]], " uv ", [uv[idx[t]], uv[idx[t+1]], uv[idx[t+2]]])
	quit()
