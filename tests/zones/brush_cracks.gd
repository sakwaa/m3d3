extends Node
## Ground T-junctions in a level's stored brushes, split into those inside one brush (its own
## faces disagree) and those between brushes (a neighbour cut differently along the shared
## line), with the brushes involved. Never saves.
##   LEVEL=res://...res godot --headless --path . tests/zones/brush_cracks.tscn


func _ready() -> void:
	var data: LevelData = load(OS.get_environment("LEVEL"))
	if OS.get_environment("DISSOLVE") != "":
		# DISSOLVE=1: on a copy, after the build's cull and Blender dissolve.
		data = data.duplicate(true)
		for b in data.brushes:
			if b:
				b.set_block_signals(true)
				b.ensure_geometry()
		BuildCull.cull(data)
		BlenderDissolve.dissolve(data)
	var faces := []  # [brush index, pts]
	for bi in data.brushes.size():
		var b: LevelBrush = data.brushes[bi]
		if b == null or b.is_prop() or b.is_fence() or b.is_rope() or b.is_house() or b.opening_spec() or b.bake_mode == LevelBrush.BakeMode.COLLISION_ONLY:
			continue
		for f in b.get_face_count():
			if absf((b.transform.basis * b.get_face_normal(f)).normalized().y) < 0.7:
				continue
			var pts := []
			for p in b.get_face_points(f):
				pts.append(b.transform * p)
			faces.append([bi, pts, f])
	var grid := {}
	for fe in faces:
		for p: Vector3 in fe[1]:
			grid.get_or_add(Vector2i(floori(p.x), floori(p.z)), []).append([p, fe[0]])
	var intra := 0
	var inter := 0
	var pairs := {}
	var done := {}
	for fe in faces:
		var pts: Array = fe[1]
		for i in pts.size():
			var a: Vector3 = pts[i]
			var b: Vector3 = pts[(i + 1) % pts.size()]
			var len := a.distance_to(b)
			if len < 0.001 or len > 80.0:
				continue
			var hit_same := false
			var hit_other := -1
			for s in ceili(len) + 1:
				var c := a.lerp(b, float(s) / maxf(ceil(len), 1.0))
				for dx in [-1, 0, 1]:
					for dz in [-1, 0, 1]:
						for e in grid.get(Vector2i(floori(c.x) + dx, floori(c.z) + dz), []):
							var p: Vector3 = e[0]
							if p.distance_to(a) < 0.002 or p.distance_to(b) < 0.002:
								continue
							if Geometry3D.get_closest_point_to_segment(p, a, b).distance_to(p) < 0.002:
								if e[1] == fe[0]:
									hit_same = true
								else:
									hit_other = e[1]
			var ek := [Vector3i(a * 1000), Vector3i(b * 1000)]
			ek.sort()
			if done.has(ek):
				continue
			done[ek] = true
			if hit_same:
				intra += 1
				if intra <= 6:
					var bb: LevelBrush = data.brushes[fe[0]]
					print("  inside %s: edge %s -> %s (%d corners, painted %s)" % [bb.tag, a, b, pts.size(), _painted(bb, fe)])
			if hit_other >= 0:
				inter += 1
				var k := [mini(fe[0], hit_other), maxi(fe[0], hit_other)]
				pairs[k] = pairs.get(k, 0) + 1
				if inter <= 20:
					var ob: LevelBrush = data.brushes[hit_other]
					print("  across: edge %s -> %s of brush %d (%s), point from brush %d (shape %s size %s at %s)" % [a, b, fe[0],
						data.brushes[fe[0]].shape, hit_other, ob.shape, ob.size, ob.transform.origin])
	print("ground edges with a vertex on them: inside one brush %d, from a neighbouring brush %d" % [intra, inter])
	var keys := pairs.keys()
	keys.sort_custom(func(x, y): return pairs[x] > pairs[y])
	for k in keys.slice(0, 8):
		var a: LevelBrush = data.brushes[k[0]]
		var b: LevelBrush = data.brushes[k[1]]
		print("  %s (%d faces) / %s (%d faces): %d" % [a.tag, a.get_face_count(), b.tag, b.get_face_count(), pairs[k]])
	get_tree().quit()


func _painted(b: LevelBrush, fe: Array) -> bool:
	for k: Vector2i in b.face_masks:
		if k.x == fe[2]:
			return true
	return false
