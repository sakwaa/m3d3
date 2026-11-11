extends Node
## Texture survey of a level (LEVEL): per texture, area facing up vs walls (vertical), the
## brushes using it, and the XZ bounds of its faces (level space).


func _ready() -> void:
	var d: LevelData = ResourceLoader.load(OS.get_environment("LEVEL"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var stats := {}
	for b: LevelBrush in d.brushes:
		if b == null or b.is_prop():
			continue
		for f in b.get_face_count():
			var ti := b.get_face_texture(f)
			var name: String = d.textures[ti].resource_path.get_file() if ti >= 0 and d.textures[ti] else "none"
			var pts := PackedVector3Array()
			for p in b.get_face_points(f):
				pts.append(b.transform * p)
			var n := Vector3.ZERO
			for i in pts.size():
				n += pts[i].cross(pts[(i + 1) % pts.size()])
			var area := n.length() * 0.5
			if area < 1e-4:
				continue
			var up := absf(n.normalized().y) > 0.7
			if not stats.has(name):
				stats[name] = {up = 0.0, wall = 0.0, brushes = {}, lo = Vector2(INF, INF), hi = -Vector2(INF, INF), wall_brushes = {}}
			var s: Dictionary = stats[name]
			if up:
				s.up += area
			else:
				s.wall += area
				s.wall_brushes[String(b.tag) + ":" + str(b.shape)] = true
			s.brushes[String(b.tag)] = true
			for p in pts:
				s.lo = (s.lo as Vector2).min(Vector2(p.x, p.z))
				s.hi = (s.hi as Vector2).max(Vector2(p.x, p.z))
	for name in stats:
		var s: Dictionary = stats[name]
		print("%-28s up %7.1f  wall %7.1f  brushes %3d  x %.0f..%.0f z %.0f..%.0f" % [name, s.up, s.wall, s.brushes.size(), s.lo.x, s.hi.x, s.lo.y, s.hi.y])
		if s.wall > 1.0 and s.wall_brushes.size() < 12:
			print("      walls in: ", s.wall_brushes.keys())
	get_tree().quit()
