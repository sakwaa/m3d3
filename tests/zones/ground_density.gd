extends Node
## Where a level's ground triangles come from (faces facing up, not houses / props): total,
## the part in props' shade (BlenderDissolve merges it only within each prop's zones, along
## shadow-edge cuts), painted faces (the dissolve leaves them too), the cell sizes, and what the
## dissolve leaves of each. Never saves.
##   LEVEL=res://...res godot --headless --path . tests/zones/ground_density.tscn


func _ready() -> void:
	var data: LevelData = (load(OS.get_environment("LEVEL")) as LevelData).duplicate(true)
	var shade := BlenderDissolve._prop_shade(data)
	print("shade rects (stalls / trees): %d" % shade.size())
	var before := _count(data, shade)
	print("before: ", before)
	var r := BlenderDissolve.dissolve(data)
	print("after:  ", _count(data, shade), "  ", r.get("error", ""))
	get_tree().quit()


func _count(data: LevelData, shade: Array) -> Dictionary:
	var out := {ground_tris = 0, shaded_tris = 0, painted_tris = 0, brushes = 0, cells = {}}
	for b: LevelBrush in data.brushes:
		if b == null or b.is_prop() or b.is_house() or b.opening_spec() or b.is_fence() or b.is_rope():
			continue
		var painted := BlenderDissolve._painted_faces(b)
		var any := false
		for f in b.get_face_count():
			if (b.transform.basis * b.get_face_normal(f)).normalized().y < 0.7:
				continue
			any = true
			var t := b.get_faces()[f].size() - 2
			out.ground_tris += t
			if BlenderDissolve._shade_zone(b, f, shade) >= 0:
				out.shaded_tris += t
				var pts := b.get_face_points(f)
				var lo := Vector2(INF, INF)
				var hi := -lo
				for p in pts:
					lo = lo.min(Vector2(p.x, p.z))
					hi = hi.max(Vector2(p.x, p.z))
				var k := "%.2fx%.2f" % [hi.x - lo.x, hi.y - lo.y]
				out.cells[k] = out.cells.get(k, 0) + 1
			if painted.has(f):
				out.painted_tris += t
		if any:
			out.brushes += 1
	var keys: Array = out.cells.keys()
	keys.sort_custom(func(a, b): return out.cells[a] > out.cells[b])
	var top := {}
	for k in keys.slice(0, 5):
		top[k] = out.cells[k]
	out.cells = top
	return out
