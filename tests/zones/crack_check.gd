extends Node
## Finds cracks in a level's baked ground: edges of upward triangles used by only one
## triangle (across every baked mesh, positions welded to 1 mm) that aren't the ground's real
## outline - i.e. another upward triangle's edge runs along them (a T-junction: a vertex on
## one side, none on the other). Prints counts and where they bunch (x / z lines).
##   LEVEL=res://...res godot --headless --path . tests/zones/crack_check.tscn


func _ready() -> void:
	var d: LevelData = load(OS.get_environment("LEVEL"))
	var edges := {}  # [a, b] (welded keys) -> count
	var segs := []
	for m in d.baked_meshes():
		for si in m.get_surface_count():
			var arr := m.surface_get_arrays(si)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var range: Vector2 = m.get_meta(&"range", Vector2.ZERO)
			if range.x > 0.0:
				continue  # (far versions: checked against each other separately; skip)
			for t in range(0, idx.size(), 3):
				var p := [v[idx[t]], v[idx[t + 1]], v[idx[t + 2]]]
				var n: Vector3 = (p[1] - p[0]).cross(p[2] - p[0])
				if n.length() < 1e-8 or absf(n.normalized().y) < 0.7:
					continue
				for k in 3:
					var a := _key(p[k])
					var b := _key(p[(k + 1) % 3])
					var e := [a, b] if a < b else [b, a]
					edges[e] = edges.get(e, 0) + 1
					segs.append([p[k], p[(k + 1) % 3]])
	var open := []
	for e in edges:
		if edges[e] == 1:
			open.append(e)
	# A T-junction: an open edge with some vertex lying inside it (on another triangle's edge).
	var pts := {}
	for s in segs:
		pts[_key(s[0])] = s[0]
	var grid := {}
	for k in pts:
		var p: Vector3 = pts[k]
		grid.get_or_add(Vector2i(floori(p.x), floori(p.z)), []).append(p)
	var t_count := 0
	var lines := {}
	for e in open:
		var a := _unkey(e[0])
		var b := _unkey(e[1])
		var lo := Vector2i(floori(minf(a.x, b.x)), floori(minf(a.z, b.z)))
		var hi := Vector2i(floori(maxf(a.x, b.x)), floori(maxf(a.z, b.z)))
		if (hi - lo).length() > 80:
			continue
		var found := false
		for x in range(lo.x, hi.x + 1):
			for z in range(lo.y, hi.y + 1):
				for p: Vector3 in grid.get(Vector2i(x, z), []):
					if p.distance_to(a) < 0.002 or p.distance_to(b) < 0.002:
						continue
					var q := Geometry3D.get_closest_point_to_segment(p, a, b)
					if q.distance_to(p) < 0.003:
						found = true
						break
				if found: break
			if found: break
		if found:
			t_count += 1
			var key := ("x=%.1f" % a.x) if absf(a.x - b.x) < 0.01 else (("z=%.1f" % a.z) if absf(a.z - b.z) < 0.01 else "diag")
			lines[key] = lines.get(key, 0) + 1
	var keys := lines.keys()
	keys.sort_custom(func(x, y): return lines[x] > lines[y])
	var tris := 0
	for m in d.baked_meshes():
		for si in m.get_surface_count():
			tris += m.surface_get_array_index_len(si) / 3
	print("baked tris %d, upward edges %d, open %d, T-junction cracks %d" % [tris, edges.size(), open.size(), t_count])
	print("  by line: ", keys.slice(0, 16).map(func(k): return "%s:%d" % [k, lines[k]]))
	get_tree().quit()


static func _key(p: Vector3) -> String:
	return "%d,%d,%d" % [roundi(p.x * 1000.0), roundi(p.y * 1000.0), roundi(p.z * 1000.0)]


static func _unkey(k: String) -> Vector3:
	var s := k.split(",")
	return Vector3(int(s[0]), int(s[1]), int(s[2])) / 1000.0
