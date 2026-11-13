extends Node
## Grass carpet triangle quality in a zone: triangles, slivers (smallest angle under 5° / 2°)
## and T-junction cracks between carpet triangles (a vertex on another's edge). GRASS_NO_FLIP=1
## builds it without the Delaunay flips, to compare.
##   ZONE=res://... godot --headless --path . tests/zones/carpet_quality.tscn


func _ready() -> void:
	var z: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(z)
	for i in 30:
		await get_tree().process_frame
	var tris := 0
	var s5 := 0
	var s2 := 0
	var pts := {}
	var edges := []
	for mi in get_tree().root.find_children("Grass_*", "MeshInstance3D", true, false):
		var m: Mesh = (mi as MeshInstance3D).mesh
		if m == null:
			continue
		var xf: Transform3D = (mi as MeshInstance3D).global_transform
		for si in m.get_surface_count():
			var arr := m.surface_get_arrays(si)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			for t in range(0, idx.size(), 3):
				var p := [xf * v[idx[t]], xf * v[idx[t + 1]], xf * v[idx[t + 2]]]
				var n: Vector3 = (p[1] - p[0]).cross(p[2] - p[0])
				if absf(n.normalized().y) < 0.7:
					continue  # (the carpet's tops only)
				tris += 1
				var m_ang := PI
				for k in 3:
					var a: Vector3 = p[(k + 1) % 3] - p[k]
					var b: Vector3 = p[(k + 2) % 3] - p[k]
					m_ang = minf(m_ang, a.angle_to(b))
				if m_ang < deg_to_rad(5.0):
					s5 += 1
				if m_ang < deg_to_rad(2.0):
					s2 += 1
				for k in 3:
					pts[Vector2i(roundi(p[k].x * 500), roundi(p[k].z * 500))] = Vector2(p[k].x, p[k].z)
					edges.append([Vector2(p[k].x, p[k].z), Vector2(p[(k + 1) % 3].x, p[(k + 1) % 3].z)])
	var grid := {}
	for k in pts:
		var q: Vector2 = pts[k]
		grid.get_or_add(Vector2i(floori(q.x), floori(q.y)), []).append(q)
	var seen := {}
	var tj := 0
	for e in edges:
		var a: Vector2 = e[0]
		var b: Vector2 = e[1]
		var key := [a, b] if a < b else [b, a]
		if seen.has(key):
			continue
		seen[key] = true
		var len := a.distance_to(b)
		if len < 0.01 or len > 40.0:
			continue
		var steps := ceili(len)
		var hit := false
		for s in steps + 1:
			var c := a.lerp(b, float(s) / steps)
			for dx in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					for q: Vector2 in grid.get(Vector2i(floori(c.x) + dx, floori(c.y) + dz), []):
						if q.distance_to(a) < 0.003 or q.distance_to(b) < 0.003:
							continue
						if Geometry2D.get_closest_point_to_segment(q, a, b).distance_to(q) < 0.002:
							hit = true
		if hit:
			tj += 1
	print("carpet tops: %d tris, slivers <5° %d, <2° %d, T-junction edges %d" % [tris, s5, s2, tj])
	get_tree().quit()
