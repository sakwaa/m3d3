extends SceneTree
## Brushes with geometry inside a box (env BOX="x0,y0,z0,x1,y1,z1") of a level (env LEVEL).
func _init() -> void:
	var d: LevelData = load(OS.get_environment("LEVEL"))
	var v := OS.get_environment("BOX").split_floats(",")
	var box := AABB(Vector3(v[0], v[1], v[2]), Vector3(v[3] - v[0], v[4] - v[1], v[5] - v[2]))
	for b in d.brushes:
		var n := 0
		for p in b.vertices:
			if box.has_point(b.transform * p):
				n += 1
		var bb := AABB(b.transform * b.vertices[0], Vector3.ZERO) if b.vertices.size() else AABB()
		for p in b.vertices:
			bb = bb.expand(b.transform * p)
		if n > 0 or (bb.intersects(box) and b.prop == null and bb.size.length() < 150.0):
			print("HIT ", b.tag, " verts in box ", n, " aabb ", bb, " tex ", Array(b.face_textures).slice(0, 6))
	quit()
