extends Node
## Which brushes a camera pixel's ray passes through, nearest first (brush index, kind, face,
## distance, point): for tracking down what a gap in a shot shows. Uses the stored brush
## faces (before the build's culling). PX / PY in the shot's pixels, W / H its size, FOV
## vertical (the shot tool's default 50).
##   LEVEL=res://... CAM=x,y,z LOOK=x,y,z PX= PY= W= H= godot --headless --path . tests/tools/pick_ray.tscn


func _ready() -> void:
	var d: LevelData = load(OS.get_environment("LEVEL"))
	var cam := _v(OS.get_environment("CAM"))
	var look := _v(OS.get_environment("LOOK"))
	var w := float(OS.get_environment("W"))
	var h := float(OS.get_environment("H"))
	var fov := float(OS.get_environment("FOV")) if OS.get_environment("FOV") != "" else 50.0
	var basis := Basis.looking_at(look - cam, Vector3.UP)
	var t := tan(deg_to_rad(fov) * 0.5)
	var nx := 2.0 * float(OS.get_environment("PX")) / w - 1.0
	var ny := 1.0 - 2.0 * float(OS.get_environment("PY")) / h
	var dir := (basis * Vector3(nx * t * w / h, ny * t, -1.0)).normalized()
	var hits := []
	for bi in d.brushes.size():
		var b: LevelBrush = d.brushes[bi]
		if b == null:
			continue
		b.ensure_geometry()
		for f in b.get_face_count():
			var pts := b.get_face_points(f)
			var world := PackedVector3Array()
			for p in pts:
				world.append(b.transform * p)
			for i in range(1, world.size() - 1):
				var hit = Geometry3D.ray_intersects_triangle(cam, dir, world[0], world[i], world[i + 1])
				if hit != null:
					var kind := "house" if b.is_house() else ("prop" if b.is_prop() else ("opening" if b.opening_spec() else "shape%d" % b.shape))
					hits.append([cam.distance_to(hit), "brush %d (%s) face %d tex %d at %s normal %s" % [bi, kind, f, b.get_face_texture(f),
						(hit as Vector3).snappedf(0.01), (b.transform.basis * b.get_face_normal(f)).normalized().snappedf(0.01)]])
					break
	if OS.get_environment("BAKED") != "":
		# BAKED=1: the baked meshes instead (what the build draws).
		hits.clear()
		var meshes := d.baked_meshes()
		for mi in meshes.size():
			var m: Mesh = meshes[mi]
			var r: Vector2 = m.get_meta(&"range", Vector2.ZERO)
			for si in m.get_surface_count():
				var a := m.surface_get_arrays(si)
				var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
				var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
				for k in range(0, idx.size(), 3):
					var hit = Geometry3D.ray_intersects_triangle(cam, dir, v[idx[k]], v[idx[k + 1]], v[idx[k + 2]])
					if hit != null:
						hits.append([cam.distance_to(hit), "mesh %d range %s surface %d tri %s %s %s" % [mi, r, si, v[idx[k]].snappedf(0.01),
							v[idx[k + 1]].snappedf(0.01), v[idx[k + 2]].snappedf(0.01)]])
	hits.sort_custom(func(x, y): return x[0] < y[0])
	for e in hits.slice(0, 12):
		print("%6.2f m  %s" % [e[0], e[1]])
	get_tree().quit()


func _v(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))
