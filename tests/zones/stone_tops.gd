extends Node
## Ground (largest GRID brush) upward faces of a level (LEVEL) wearing texture TEX (res path)
## inside the town (|x|, |z| < LIMIT): count, area, height range, a few centres.


func _ready() -> void:
	var d: LevelData = ResourceLoader.load(OS.get_environment("LEVEL"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var lim := float(OS.get_environment("LIMIT")) if OS.get_environment("LIMIT") != "" else 60.0
	var tex := OS.get_environment("TEX")
	var ground: LevelBrush
	for b in d.brushes:
		if b and b.shape == BrushShapes.Shape.GRID and (ground == null or b.get_face_count() > ground.get_face_count()):
			ground = b
	var n := 0
	var ys := Vector2(INF, -INF)
	var cells := {}
	for f in ground.get_face_count():
		var ti := ground.get_face_texture(f)
		if ti < 0 or d.textures[ti] == null or d.textures[ti].resource_path != tex:
			continue
		if (ground.transform.basis * ground.get_face_normal(f)).normalized().y < 0.7:
			continue
		var c := Vector3.ZERO
		var pts := ground.get_face_points(f)
		for p in pts:
			c += ground.transform * p
		c /= pts.size()
		if absf(c.x) >= lim or absf(c.z) >= lim:
			continue
		n += 1
		ys = Vector2(minf(ys.x, c.y), maxf(ys.y, c.y))
		cells[Vector2i(floori(c.x / 4.0) * 4, floori(c.z / 4.0) * 4)] = true
	print("%d faces, y %.2f..%.2f, 4 m cells: %s" % [n, ys.x, ys.y, cells.keys().slice(0, 60)])
	get_tree().quit()
