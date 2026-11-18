extends SceneTree
## Trail wall heights: per front column, top minus the front foot (bottom + 0.45 m bury).
func _init() -> void:
	var d: LevelData = load(OS.get_environment("LEVEL"))
	var hs: Array[float] = []
	for b in d.brushes:
		if not String(b.tag).begins_with("wall"):
			continue
		var cols := {}
		for v in b.vertices:
			var w := b.transform * v
			var key := Vector2i(roundi(w.x * 50.0), roundi(w.z * 50.0))
			var e: Vector2 = cols.get(key, Vector2(INF, -INF))
			cols[key] = Vector2(minf(e.x, w.y), maxf(e.y, w.y))
		for k in cols:
			var e: Vector2 = cols[k]
			if e.y - e.x > 0.3:
				hs.append(e.y - e.x - 0.45)
	hs.sort()
	print("WALL columns %d  min %.2f  median %.2f  p90 %.2f  max %.2f" % [hs.size(), hs[0], hs[hs.size() / 2], hs[int(hs.size() * 0.9)], hs[-1]])
	quit()
