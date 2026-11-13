extends Node
## Where ground cracks (T-junctions: a vertex on the middle of another ground face's edge)
## come from in the build: counted on a copy of a level after each step of ExportBake's level
## bake - as stored, after BuildCull, after the Blender dissolve, and in the baked mesh (with
## CrackClose off). Faces facing up only, level space, all brushes together. Never saves.
##   LEVEL=res://...res godot --path . tests/zones/stage_cracks.tscn   (windowed: the bake renders)


func _ready() -> void:
	CrackClose.enabled = OS.get_environment("KEEP_CLOSE") != ""
	var data: LevelData = (load(OS.get_environment("LEVEL")) as LevelData).duplicate(true)
	for b in data.brushes:
		if b:
			b.set_block_signals(true)
			b.ensure_geometry()
	_report("stored", _brush_polys(data))
	BuildCull.cull(data)
	_report("after cull", _brush_polys(data))
	var r := BlenderDissolve.dissolve(data)
	_report("after dissolve (%s)" % r.get("error", "ok"), _brush_polys(data))
	_report("after simplify", _brush_polys(BuildSimplify.optimized_copy(data).data))
	var res := LevelBaker.bake(data, true, true)
	var polys := []
	var meshes: Array = res.chunks if not res.chunks.is_empty() else [res.mesh]
	for m: ArrayMesh in meshes:
		if (m.get_meta(&"range", Vector2.ZERO) as Vector2).x > 0.0:
			continue
		for si in m.get_surface_count():
			var arr := m.surface_get_arrays(si)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var tex = (m.surface_get_material(si) as ShaderMaterial).get_shader_parameter(&"base_tex") if m.surface_get_material(si) is ShaderMaterial else null
			if OS.get_environment("GROUND_ONLY") != "" and m.surface_get_name(si) != "ground":
				continue
			for t in range(0, idx.size(), 3):
				polys.append([v[idx[t]], v[idx[t + 1]], v[idx[t + 2]]])
	_report("baked", polys)
	get_tree().quit()


## Every brush face (level space) as a point list.
func _brush_polys(data: LevelData) -> Array:
	var out := []
	for b: LevelBrush in data.brushes:
		if b == null or b.is_prop() or b.is_fence() or b.is_rope() or b.bake_mode == LevelBrush.BakeMode.COLLISION_ONLY:
			continue
		if OS.get_environment("GROUND_ONLY") != "" and (b.is_house() or b.opening_spec()):
			continue
		for f in b.get_face_count():
			var pts := []
			for p in b.get_face_points(f):
				pts.append(b.transform * p)
			out.append(pts)
	return out


func _report(stage: String, polys: Array) -> void:
	var up := []
	for pts: Array in polys:
		if pts.size() < 3:
			continue
		var n := Vector3.ZERO
		for i in pts.size():
			var a: Vector3 = pts[i]
			var c: Vector3 = pts[(i + 1) % pts.size()]
			n += Vector3((a.y - c.y) * (a.z + c.z), (a.z - c.z) * (a.x + c.x), (a.x - c.x) * (a.y + c.y))
		if n.length() > 1e-9 and absf(n.normalized().y) > 0.7:
			up.append(pts)
	var grid := {}
	var seen := {}
	for pts in up:
		for p: Vector3 in pts:
			var k := Vector3i(roundi(p.x * 1000), roundi(p.y * 1000), roundi(p.z * 1000))
			if seen.has(k):
				continue
			seen[k] = true
			grid.get_or_add(Vector2i(floori(p.x), floori(p.z)), []).append(p)
	var tj := 0
	var near_dup := 0
	var where := {}
	var done := {}
	for pts in up:
		for i in pts.size():
			var a: Vector3 = pts[i]
			var b: Vector3 = pts[(i + 1) % pts.size()]
			var ek := [Vector3i(a * 1000), Vector3i(b * 1000)]
			ek.sort()
			if done.has(ek):
				continue
			done[ek] = true
			var len := a.distance_to(b)
			if len < 0.001 or len > 80.0:
				continue
			var hit := false
			for s in ceili(len) + 1:
				var c := a.lerp(b, float(s) / maxf(ceil(len), 1.0))
				for dx in [-1, 0, 1]:
					for dz in [-1, 0, 1]:
						for p: Vector3 in grid.get(Vector2i(floori(c.x) + dx, floori(c.z) + dz), []):
							if p.distance_to(a) < 0.002 or p.distance_to(b) < 0.002:
								if p.distance_to(a) > 0.0002 and p.distance_to(a) < 0.002 or p.distance_to(b) > 0.0002 and p.distance_to(b) < 0.002:
									near_dup += 1
								continue
							if Geometry3D.get_closest_point_to_segment(p, a, b).distance_to(p) < 0.002:
								hit = true
			if hit:
				tj += 1
				var key := "%d,%d" % [floori(a.x / 8) * 8, floori(a.z / 8) * 8]
				where[key] = where.get(key, 0) + 1
	var fan := 0
	var straight := 0  # corners in line with both neighbours (each costs a triangle)
	for pts in up:
		fan += pts.size() - 2
		for i in pts.size():
			var p0: Vector3 = pts[i - 1]
			var p1: Vector3 = pts[i]
			var p2: Vector3 = pts[(i + 1) % pts.size()]
			if Geometry3D.get_closest_point_to_segment(p1, p0, p2).distance_to(p1) < 0.002:
				straight += 1
	var slivers := 0  # triangles with a corner under 5 degrees
	for pts in up:
		if pts.size() != 3:
			continue
		for i in 3:
			var e1: Vector3 = pts[(i + 1) % 3] - pts[i]
			var e2: Vector3 = pts[(i + 2) % 3] - pts[i]
			if e1.length() > 1e-6 and e2.length() > 1e-6 and rad_to_deg(e1.angle_to(e2)) < 5.0:
				slivers += 1
				break
	print("    as triangles %d, in-line corners %d, slivers %d" % [fan, straight, slivers])
	var keys := where.keys()
	keys.sort_custom(func(x, y): return where[x] > where[y])
	print("%-28s ground faces %6d  T-junction edges %5d  near-duplicate points %d  hot 8m cells %s" % [stage, up.size(), tj, near_dup,
		keys.slice(0, 6).map(func(k): return "%s:%d" % [k, where[k]])])
