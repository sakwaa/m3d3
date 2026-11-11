extends Node
## Vertices of a level (LEVEL) inside an XZ rect (RECT=x0,z0,x1,z1), level space: per brush,
## how many, and their baked light at key KEY (timed keys, index; else corner_lighting) and
## vertex AO, against the brush's average.


func _ready() -> void:
	var d: LevelData = ResourceLoader.load(OS.get_environment("LEVEL"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var r := OS.get_environment("RECT").split(",")
	var rect := Rect2(float(r[0]), float(r[1]), float(r[2]) - float(r[0]), float(r[3]) - float(r[1]))
	var key := int(OS.get_environment("KEY")) if OS.get_environment("KEY") != "" else 2
	for b: LevelBrush in d.brushes:
		if b == null or b.is_prop() or b.is_house():
			continue
		var faces := b.get_faces()
		var corner := 0
		var inside := []
		var lit_in := 0.0
		var lit_all := 0.0
		var n_all := 0
		var keys: Array = b.corner_lighting_keys
		for f in faces.size():
			for v in faces[f]:
				var w := b.transform * b.vertices[v]
				var c := Color.WHITE
				if keys.size() > key and corner < (keys[key] as PackedColorArray).size():
					c = keys[key][corner]
				elif corner < b.corner_lighting.size():
					c = b.corner_lighting[corner]
				lit_all += c.v
				n_all += 1
				if rect.has_point(Vector2(w.x, w.z)):
					inside.append(v)
					lit_in += c.v
					if OS.get_environment("EACH") != "":
						var ao: float = b.vertex_ao[v] if v < b.vertex_ao.size() else -1.0
						print("   %s light %.2f ao %.2f" % [w.snapped(Vector3.ONE * 0.01), c.v, ao])
				corner += 1
		if not inside.is_empty():
			var u := {}
			for v in inside:
				u[v] = true
			print("%s shape %d: %d vertices in rect (%d corners), light %.2f inside vs %.2f overall (keys %d, ao %d)" % [b.tag, b.shape, u.size(), inside.size(),
				lit_in / inside.size(), lit_all / maxf(n_all, 1), keys.size(), b.vertex_ao.size()])
	get_tree().quit()
