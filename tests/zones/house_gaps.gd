extends Node
## Lists house wall faces BuildCull removes as pressed against a neighbour, with the real gap
## between the two walls (LEVEL).


func _ready() -> void:
	var d: LevelData = ResourceLoader.load(OS.get_environment("LEVEL"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var houses := []
	for b: LevelBrush in d.brushes:
		if b and b.is_house():
			houses.append(b)
	var gaps := {}
	var tris := 0
	for b: LevelBrush in houses:
		for f in b.get_face_count():
			var n := (b.transform.basis * b.get_face_normal(f)).normalized()
			if absf(n.y) >= 0.3:
				continue
			var c := Vector3.ZERO
			var pts := b.get_face_points(f)
			for p in pts:
				c += b.transform * p
			c /= pts.size()
			for o: LevelBrush in houses:
				if o == b:
					continue
				var inv := o.transform.affine_inverse()
				var half := Vector2(o.house.width * 0.5, o.house.depth * 0.5)
				for i in 51:
					var g := i * 0.005
					var q := inv * (c + n * g)
					if absf(q.x) <= half.x + 0.001 and absf(q.z) <= half.y + 0.001 and q.y >= o.house.foundation and q.y <= o.house.wall_height():
						var key := "%s | %s" % [b.tag, o.tag]
						gaps[key] = "%.3f m  (face %d, %d corners)" % [g, f, pts.size()]
						if g > 0.02: tris += pts.size() - 2
						break
	for k in gaps:
		print(k, "  gap ", gaps[k])
	print("triangles back if only flush walls cull: ", tris)
	get_tree().quit()
