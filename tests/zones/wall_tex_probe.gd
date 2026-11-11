extends Node
## Vertical faces (UP=1: upward ones) of a level (LEVEL) wearing texture index TEX: per brush, area, height range
## and a coarse map of where they stand (4 m cells).


func _ready() -> void:
	var d: LevelData = ResourceLoader.load(OS.get_environment("LEVEL"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var want := int(OS.get_environment("TEX"))
	for b: LevelBrush in d.brushes:
		if b == null:
			continue
		var area := 0.0
		var ylo := INF
		var yhi := -INF
		var cells := {}
		var n_faces := 0
		for f in b.get_face_count():
			if b.get_face_texture(f) != want:
				continue
			var pts := PackedVector3Array()
			for p in b.get_face_points(f):
				pts.append(b.transform * p)
			var n := Vector3.ZERO
			for i in pts.size():
				n += pts[i].cross(pts[(i + 1) % pts.size()])
			if (absf(n.normalized().y) > 0.7) != (OS.get_environment("UP") != ""):
				continue
			area += n.length() * 0.5
			n_faces += 1
			var c := Vector3.ZERO
			for p in pts:
				c += p
				ylo = minf(ylo, p.y)
				yhi = maxf(yhi, p.y)
			c /= pts.size()
			cells[Vector2i(floori(c.x / 8.0), floori(c.z / 8.0))] = true
		if area > 0.5:
			print("%s shape %d bake %d: %d faces %.0f m2, y %.1f..%.1f, cells(8m) %s" % [b.tag, b.shape, b.bake_mode, n_faces, area, ylo, yhi, cells.keys().slice(0, 40)])
	get_tree().quit()
