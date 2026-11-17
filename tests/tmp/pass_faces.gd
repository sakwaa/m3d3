extends SceneTree
func _init() -> void:
	var d: LevelData = load("res://zones/town1/town_1_market_square_level.res")
	var i := 0
	for b in d.brushes:
		i += 1
		if b == null: continue
		var xf := b.transform
		for f in b.get_face_count():
			var pts := b.get_face_points(f)
			var inside := true
			var wp := []
			for p in pts:
				var w := xf * p
				wp.append(w)
				if w.x > -69.5 or w.x < -76 or w.z < -4.6 or w.z > -0.4 or w.y > 4.5: inside = false
			if not inside: continue
			var n := xf.basis * b.get_face_normal(f)
			var uvs := []
			for p in pts: uvs.append(b.face_uv_at(p, f))
			print("brush ", i - 1, " ", b.resource_name, " face ", f, " n ", n.snapped(Vector3.ONE * 0.01), " tex ", b.face_textures[f] if f < b.face_textures.size() else -1, " uvt ", b.get_face_uv(f), "\n  pts ", wp, "\n  uv ", uvs)
	quit()
