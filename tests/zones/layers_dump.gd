extends Node
## A level's (LEVEL) overlay layers: the default set and each named set, their textures, and
## how many face masks the ground brush (largest GRID brush) holds per slot.


func _ready() -> void:
	var d: LevelData = ResourceLoader.load(OS.get_environment("LEVEL"), "", ResourceLoader.CACHE_MODE_IGNORE)
	print("default set: ", d.layers.map(func(l): return l.texture.resource_path.get_file() if l and l.texture else "none"))
	for s in d.layer_sets:
		print("set %s: %s" % [s.name, s.layers.map(func(l): return l.texture.resource_path.get_file() if l and l.texture else "none")])
	print("mask density ", d.mask_density)
	var ground: LevelBrush
	for b in d.brushes:
		if b and b.shape == BrushShapes.Shape.GRID and (ground == null or b.get_face_count() > ground.get_face_count()):
			ground = b
	var per := {}
	for k: Vector2i in ground.face_masks:
		per[k.y] = per.get(k.y, 0) + 1
	var sets := {}
	for v in ground.face_layer_sets:
		sets[v] = sets.get(v, 0) + 1
	print("ground: %d faces, %d vertices, masks per slot %s, sets used %s" % [ground.get_face_count(), ground.vertices.size(), per, sets])
	var sizes := []
	for f in mini(ground.get_face_count(), 60):
		var pts := ground.get_face_points(f)
		sizes.append(snappedf((pts[0] - pts[1]).length(), 0.05))
	print("edge lengths sample: ", sizes)
	get_tree().quit()
