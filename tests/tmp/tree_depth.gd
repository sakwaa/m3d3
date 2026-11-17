extends Node3D
## Per species: bark / leaf tris, leaf cards, and the canopy's depth complexity (leaf quads
## rasterised orthographically from the side and from below at 30°), plus the leaf texture's
## opaque share (alpha-tested: transparent texels still run the shader).
const CELL := 0.1

func _ready() -> void:
	var names := ["sycamore", "oak", "crabapple", "london_plane", "american_elm", "fir", "willow"]
	print("[td] species | bark tris | leaf cards | leaf tris | side: covered m2, mean, p95, max | low30: mean, p95 | tex opaque %")
	for nm in names:
		var path := "res://addons/n64_level_tools/trees/species/%s.tres" % nm
		if not ResourceLoader.exists(path):
			continue
		var sp: TreeSpecies = load(path)
		var means := []
		for seed in [7, 11, 23]:
			var mesh: ArrayMesh = TreeBuilder.build(sp, seed)
			var bark_t := mesh.surface_get_array_index_len(0) / 3 if mesh.surface_get_array_index_len(0) > 0 else mesh.surface_get_array_len(0) / 3
			if mesh.get_surface_count() < 2:
				continue
			var arr := mesh.surface_get_arrays(1)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var ix = arr[Mesh.ARRAY_INDEX]
			var idx: PackedInt32Array = ix if ix is PackedInt32Array and not (ix as PackedInt32Array).is_empty() else PackedInt32Array(range(v.size()))
			var side := _depth(v, idx, Basis())
			var low := _depth(v, idx, Basis(Vector3.RIGHT, deg_to_rad(-30)))
			means.append([bark_t, idx.size() / 6, idx.size() / 3, side, low])
		if means.is_empty():
			continue
		var m: Array = means[0]
		var op := _opaque(sp.leaf_texture)
		print("[td] %s | %d | %d | %d | %.1f m2, %.1f, %.0f, %.0f | %.1f, %.0f | %.0f%%" % [nm, m[0], m[1], m[2], m[3].area, m[3].mean, m[3].p95, m[3].max, m[4].mean, m[4].p95, op * 100.0])
	get_tree().quit()

func _opaque(t: Texture2D) -> float:
	if t == null:
		return -1.0
	var img := t.get_image()
	if img == null:
		return -1.0
	if img.is_compressed():
		img.decompress()
	var n := 0
	var o := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			n += 1
			if img.get_pixel(x, y).a >= 0.5:
				o += 1
	return float(o) / max(n, 1)

## Orthographic layer count looking along -Z of `view` (rotate points by its inverse).
func _depth(v: PackedVector3Array, idx: PackedInt32Array, view: Basis) -> Dictionary:
	var inv := view.inverse()
	var pts := PackedVector2Array()
	pts.resize(v.size())
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in v.size():
		var p := inv * v[i]
		pts[i] = Vector2(p.x, p.y)
		lo = lo.min(pts[i])
		hi = hi.max(pts[i])
	var w := int(ceil((hi.x - lo.x) / CELL)) + 1
	var h := int(ceil((hi.y - lo.y) / CELL)) + 1
	var grid := PackedInt32Array()
	grid.resize(w * h)
	for t in range(0, idx.size(), 3):
		var a := (pts[idx[t]] - lo) / CELL
		var b := (pts[idx[t + 1]] - lo) / CELL
		var c := (pts[idx[t + 2]] - lo) / CELL
		var mn := a.min(b).min(c)
		var mx := a.max(b).max(c)
		for y in range(maxi(int(mn.y), 0), mini(int(mx.y) + 1, h)):
			for x in range(maxi(int(mn.x), 0), mini(int(mx.x) + 1, w)):
				var p := Vector2(x + 0.5, y + 0.5)
				if _inside(p, a, b, c):
					grid[y * w + x] += 1
	var vals := []
	for g in grid:
		if g > 0:
			vals.append(g)
	vals.sort()
	var s := 0
	for x in vals:
		s += x
	return {area = vals.size() * CELL * CELL, mean = float(s) / max(vals.size(), 1), p95 = vals[int(vals.size() * 0.95)] if vals else 0, max = vals[-1] if vals else 0}

func _inside(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (p - b).cross(a - b)
	var d2 := (p - c).cross(b - c)
	var d3 := (p - a).cross(c - a)
	return not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0))
