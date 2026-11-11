extends Node
## Where a level's triangles go, on a copy of the zone: as the build makes them (MODE=build:
## hidden faces culled, BuildSimplify merges; no relight) or as edited (MODE=quick), counted
## by texture, and how many lie under house footprints (hidden).
##   ZONE=res://...tscn MODE=build|quick godot --headless --path . tests/zones/bake_breakdown.tscn


func _ready() -> void:
	var path := OS.get_environment("ZONE")
	var scene: Node = (load(path) as PackedScene).instantiate()
	var root: LevelRoot = scene.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	var data: LevelData = root.data.duplicate_deep(Resource.DEEP_DUPLICATE_INTERNAL)
	var own: Array[LevelBrush] = []
	for b in data.brushes:
		own.append(b.duplicate() if b else b)
	data.brushes = own
	var mode := OS.get_environment("MODE")  # quick (as Quick Play bakes) / build (cull + simplify, no relight)
	var culled := {}
	if mode != "quick":
		culled = BuildCull.cull(data)
		print("culled: ", culled)
	var copy: LevelData = BuildSimplify.optimized_copy(data).data if mode != "quick" else data
	var houses := []
	for b in copy.brushes:
		if b and b.house:
			houses.append([b.transform.affine_inverse(), b.house.width * 0.5, b.house.depth * 0.5, b.house.foundation])
	var by_tex := {}
	var under := 0
	var under_by := {}
	var total := 0
	var area := {}
	var faces_n := {}
	for b in copy.brushes:
		if b == null or b.is_prop() or b.bake_mode == LevelBrush.BakeMode.COLLISION_ONLY:
			continue
		var faces := b.get_faces()
		for f in faces.size():
			if b.get_face_bake(f) == 3 if b.has_method(&"get_face_bake") else false:
				continue
			var ids: PackedInt32Array = faces[f]
			var n := ids.size() - 2
			if n <= 0:
				continue
			var ti := b.get_face_texture(f)
			var tex := copy.textures[ti] if ti >= 0 and ti < copy.textures.size() and copy.textures[ti] else null
			var name := "none"
			if tex:
				name = tex.resource_path.get_file().get_basename()
				if tex.resource_path.contains("::") and tex.get(&"texture"):
					name = "look:" + String(tex.get(&"texture").resource_path.get_file().get_basename())
			by_tex[name] = by_tex.get(name, 0) + n
			total += n
			var pts := []
			for i in ids:
				pts.append(b.transform * b.vertices[i])
			var ar := 0.0
			for k in range(1, pts.size() - 1):
				ar += (pts[k] - pts[0]).cross(pts[k + 1] - pts[0]).length() * 0.5
			area[name] = area.get(name, 0.0) + ar
			if ar > 0.0:
				var lk: int = b.corner_lighting_keys.size()
				faces_n[name] = faces_n.get(name, 0) + 1
			if b.house:
				continue
			var c := Vector3.ZERO
			for i in ids:
				c += b.transform * b.vertices[i]
			c /= ids.size()
			for h in houses:
				var l: Vector3 = h[0] * c
				if absf(l.x) < h[1] and absf(l.z) < h[2] and l.y <= h[3] + 0.05:
					under += n
					under_by[name] = under_by.get(name, 0) + n
					break
	var keys := by_tex.keys()
	keys.sort_custom(func(a, b): return by_tex[a] > by_tex[b])
	print("built triangles (brush faces after cull + simplify): %d" % total)
	for k in keys.slice(0, 14):
		print("  %-28s %6d tris  %7.0f m2  %5.2f tris/m2  %d faces" % [k, by_tex[k], area.get(k, 0.0), by_tex[k] / maxf(area.get(k, 1.0), 1.0), faces_n.get(k, 0)])
	print("under house footprints (hidden): %d  %s" % [under, under_by])
	get_tree().quit()
