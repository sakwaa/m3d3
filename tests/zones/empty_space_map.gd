extends Node
## Spatial-compression survey: where in a zone the player can stand with nothing of interest
## nearby. The ground is sampled every CELL metres (physics rays); cells the player can reach
## from the spawn (walkable slope, step height between neighbours) are kept; each gets its
## distance to the nearest point of interest - level brushes by tag (ruins, walls, boulders,
## steps, carved stone, the church's blocks...) and props (3D trees, machines, the waterfall),
## not the ground, spurs, spires (backdrop) or undergrowth. Prints the reachable area, how
## much of it is further than EMPTY metres from anything, and the biggest empty patches
## (area, centre, size); OUT=file.png writes a top-down map (grey: unreachable; green near ->
## red far from interest; white: points of interest; blue: water).
## NO_TREES=1: trees (and roots) don't count - the moments only, not the dressing.
##   godot --path . tests/zones/empty_space_map.tscn [ZONE=res://...tscn] [OUT=map.png] [EMPTY=10] [NO_TREES=1]

const CELL := 2.0
const STEP_UP := 1.3  # (between neighbouring cells: ~33 degrees over 2 m)
const NOT_INTEREST := ["land", "spur", "spire", "lip", "walkway", "aqueduct"]


func _ready() -> void:
	var path := OS.get_environment("ZONE") if OS.get_environment("ZONE") != "" else "res://zones/forest/forest_citadel.tscn"
	var empty_m := float(OS.get_environment("EMPTY")) if OS.get_environment("EMPTY") != "" else 10.0
	var zone: Node = (load(path) as PackedScene).instantiate()
	add_child(zone)
	for i in 10:
		await get_tree().physics_frame
	var root: LevelRoot = zone.find_children("*", "LevelRoot", true, false)[0]
	var data: LevelData = root.data
	var spawn: Vector3 = (zone.get_node("Spawn_default") as Node3D).global_position
	# Points of interest.
	var poi: Array[Vector2] = []
	var tags := {}
	for b in data.brushes:
		if b == null:
			continue
		if b.is_prop():
			var k: int = b.prop.kind
			if k in [PropSpec.Kind.LIGHT_SHAFT, PropSpec.Kind.AMBIENCE, PropSpec.Kind.BIRD_FLOCK]:
				continue
			if k == PropSpec.Kind.MACHINE_WATER:
				# (the water's edges count: its strip rows, x across from y to z at local z = x)
				var strip = b.prop.settings.get(&"strip", PackedVector3Array())
				for r: Vector3 in strip:
					for x: float in [r.y, r.z]:
						var w := b.transform * Vector3(x, 0.0, r.x)
						poi.append(Vector2(w.x, w.z))
				tags["water edge"] = tags.get("water edge", 0) + strip.size() * 2
				continue
			if k == PropSpec.Kind.TREE and (b.prop.settings.get(&"card_only", false) or OS.get_environment("NO_TREES") != ""):
				continue
			poi.append(Vector2(b.transform.origin.x, b.transform.origin.z))
			tags["prop:" + PropSpec.NAMES[k]] = tags.get("prop:" + PropSpec.NAMES[k], 0) + 1
			continue
		var tag := String(b.tag).split("_")[0]
		if tag in NOT_INTEREST or (tag == "root" and OS.get_environment("NO_TREES") != ""):
			continue
		tags[tag] = tags.get(tag, 0) + 1
		# (big ones - walls, the church - count along their outline, every few metres)
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for v in b.vertices:
			var w := b.transform * v
			lo = Vector2(minf(lo.x, w.x), minf(lo.y, w.z))
			hi = Vector2(maxf(hi.x, w.x), maxf(hi.y, w.z))
		var n := maxi(ceili(maxf(hi.x - lo.x, hi.y - lo.y) / 3.0), 1)
		for i in n + 1:
			poi.append(lo.lerp(hi, float(i) / n))
	print("EMPTY interest points: %d  %s" % [poi.size(), tags])
	# Ground grid.
	var lo := Vector2(-130.0, -170.0)
	var size := Vector2i(130, 160)
	var hs := PackedFloat32Array()
	hs.resize(size.x * size.y)
	var ok := PackedByteArray()
	ok.resize(size.x * size.y)
	var space: PhysicsDirectSpaceState3D = (zone as Node3D).get_world_3d().direct_space_state
	for j in size.y:
		for i in size.x:
			var x := lo.x + (i + 0.5) * CELL
			var z := lo.y + (j + 0.5) * CELL
			var q := PhysicsRayQueryParameters3D.create(Vector3(x, 250.0, z), Vector3(x, -60.0, z))
			var hit := space.intersect_ray(q)
			var k := j * size.x + i
			if hit.is_empty():
				hs[k] = -INF
				continue
			hs[k] = hit.position.y
			ok[k] = 1 if hit.normal.y > 0.6 else 0
	# Reachable from the spawn.
	var reach := PackedByteArray()
	reach.resize(size.x * size.y)
	var si := clampi(int((spawn.x - lo.x) / CELL), 0, size.x - 1)
	var sj := clampi(int((spawn.z - lo.y) / CELL), 0, size.y - 1)
	var stack: Array[int] = [sj * size.x + si]
	reach[stack[0]] = 1
	while not stack.is_empty():
		var k: int = stack.pop_back()
		var i := k % size.x
		var j := k / size.x
		for o: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var ni := i + o.x
			var nj := j + o.y
			if ni < 0 or nj < 0 or ni >= size.x or nj >= size.y:
				continue
			var nk := nj * size.x + ni
			if reach[nk] or not ok[nk] or absf(hs[nk] - hs[k]) > STEP_UP:
				continue
			reach[nk] = 1
			stack.append(nk)
	# Distance to interest, empty patches.
	var dist := PackedFloat32Array()
	dist.resize(size.x * size.y)
	var reach_n := 0
	var empty_n := 0
	for k in size.x * size.y:
		if not reach[k]:
			continue
		reach_n += 1
		var p := lo + Vector2(k % size.x + 0.5, k / size.x + 0.5) * CELL
		var best := INF
		for q in poi:
			best = minf(best, p.distance_squared_to(q))
		dist[k] = sqrt(best)
		if dist[k] > empty_m:
			empty_n += 1
	print("EMPTY reachable %.0f m2, further than %.0f m from interest: %.0f m2 (%.0f%%)" % [
		reach_n * CELL * CELL, empty_m, empty_n * CELL * CELL, 100.0 * empty_n / maxf(reach_n, 1)])
	# Patches (4-connected empty cells).
	var seen := PackedByteArray()
	seen.resize(size.x * size.y)
	var patches := []
	for k0 in size.x * size.y:
		if seen[k0] or not reach[k0] or dist[k0] <= empty_m:
			continue
		var cells: Array[int] = [k0]
		seen[k0] = 1
		var idx := 0
		var far := 0.0
		while idx < cells.size():
			var k: int = cells[idx]
			idx += 1
			far = maxf(far, dist[k])
			var i := k % size.x
			var j := k / size.x
			for o: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var ni := i + o.x
				var nj := j + o.y
				if ni < 0 or nj < 0 or ni >= size.x or nj >= size.y:
					continue
				var nk := nj * size.x + ni
				if seen[nk] or not reach[nk] or dist[nk] <= empty_m:
					continue
				seen[nk] = 1
				cells.append(nk)
		var c := Vector2.ZERO
		var plo := Vector2(INF, INF)
		var phi := Vector2(-INF, -INF)
		for k in cells:
			var p := lo + Vector2(k % size.x + 0.5, k / size.x + 0.5) * CELL
			c += p
			plo = Vector2(minf(plo.x, p.x), minf(plo.y, p.y))
			phi = Vector2(maxf(phi.x, p.x), maxf(phi.y, p.y))
		c /= cells.size()
		var y: float = hs[int((c.y - lo.y) / CELL) * size.x + int((c.x - lo.x) / CELL)]
		patches.append({area = cells.size() * CELL * CELL, centre = Vector3(c.x, y, c.y), span = phi - plo + Vector2.ONE * CELL, far = far})
	patches.sort_custom(func(a, b): return a.area > b.area)
	for p in patches.slice(0, 10):
		print("EMPTY patch %5.0f m2  centre (%.0f, %.0f, %.0f)  span %.0f x %.0f m  furthest %.0f m from interest" % [
			p.area, p.centre.x, p.centre.y, p.centre.z, p.span.x, p.span.y, p.far])
	if OS.get_environment("OUT") != "":
		var img := Image.create(size.x * 4, size.y * 4, false, Image.FORMAT_RGB8)
		for k in size.x * size.y:
			var col := Color(0.12, 0.12, 0.13)
			if reach[k]:
				var t := clampf(dist[k] / (empty_m * 2.0), 0.0, 1.0)
				col = Color(0.15, 0.55, 0.2).lerp(Color(0.95, 0.85, 0.2), clampf(t * 2.0, 0.0, 1.0)) if t < 0.5 else Color(0.95, 0.85, 0.2).lerp(Color(0.85, 0.15, 0.1), (t - 0.5) * 2.0)
			elif hs[k] > -INF and not ok[k]:
				col = Color(0.3, 0.3, 0.32)
			img.fill_rect(Rect2i((k % size.x) * 4, (k / size.x) * 4, 4, 4), col)
		for q in poi:
			var px := Vector2i(((q - lo) / CELL * 4.0).round())
			if px.x >= 0 and px.y >= 0 and px.x < img.get_width() and px.y < img.get_height():
				img.set_pixelv(px, Color.WHITE)
		var sp := Vector2i(((Vector2(spawn.x, spawn.z) - lo) / CELL * 4.0).round())
		img.fill_rect(Rect2i(sp - Vector2i(3, 3), Vector2i(7, 7)), Color(0.2, 0.6, 1.0))
		img.flip_y()  # (north - +Z - up)
		img.save_png(OS.get_environment("OUT"))
		print("EMPTY map: ", OS.get_environment("OUT"))
	get_tree().quit()
