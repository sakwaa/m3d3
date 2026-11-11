extends Node
## Dumps one brush (TAG) of a level file (LEVEL): every face's texture, area, normal, corners.


func _ready() -> void:
	var d: LevelData = ResourceLoader.load(OS.get_environment("LEVEL"), "", ResourceLoader.CACHE_MODE_IGNORE)
	for br in d.brushes:
		if br and String(br.tag) == OS.get_environment("TAG"):
			var faces := br.get_faces()
			print("%d faces, %d vertices, corner uvs %s, corner colours %s" % [faces.size(), br.vertices.size(), br.has_corner_uvs(), br.has_corner_colors()])
			for f in faces.size():
				var pts := PackedVector3Array()
				for v in faces[f]:
					pts.append(br.vertices[v])
				var n := PolyUtil.newell_normal(pts)
				var ti := br.get_face_texture(f)
				print("  f%-3d %-22s area %6.2f n %s corners %d" % [f, d.textures[ti].resource_path.get_file() if ti >= 0 else "none", n.length() * 0.5, n.normalized().snapped(Vector3.ONE * 0.01), pts.size()])
	get_tree().quit()
