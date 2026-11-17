extends SceneTree
func _init() -> void:
	var d: LevelData = load(OS.get_environment("LEVEL"))
	var tris := []
	for m: ArrayMesh in d.baked_meshes():
		if (m.get_meta(&"range", Vector2.ZERO) as Vector2).x > 0.0: continue
		for s in m.get_surface_count():
			var a := m.surface_get_arrays(s)
			var pos: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
			for t in range(0, idx.size(), 3):
				var p := [pos[idx[t]], pos[idx[t+1]], pos[idx[t+2]]]
				var near := false
				for q in p:
					if q.x > -70.5 and q.x < -69.5 and q.z > -4.6 and q.z < -0.4 and q.y < 4.6: near = true
				if near: tris.append(p)
	print("tris ", tris.size())
	var pts := {}
	for t in tris:
		for q in t: pts[Vector3i((q * 1000).round())] = q
	var hits := 0
	for t in tris:
		for k in 3:
			var a: Vector3 = t[k]; var b: Vector3 = t[(k + 1) % 3]
			var len := a.distance_to(b)
			if len < 0.01: continue
			var dir := (b - a) / len
			for key in pts:
				var p: Vector3 = pts[key]
				var al := (p - a).dot(dir)
				if al <= 0.002 or al >= len - 0.002: continue
				if (a + dir * al).distance_to(p) < 0.002:
					hits += 1
					if hits <= 25: print("T at ", p.snapped(Vector3.ONE * 0.001), " on edge ", a.snapped(Vector3.ONE * 0.001), " -> ", b.snapped(Vector3.ONE * 0.001))
	print("T-junctions ", hits)
	quit()
