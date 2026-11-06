@tool
class_name LevelScatterTool
extends RefCounted
## Scatter / Place for cut-outs (flowers, grass tufts) on a level (ScatterSet):
##  - a Scatter stroke fills the brush circle up to `density` per m², spaced evenly (no
##    clumps), each point a random item with some size jitter, dropped onto the surface
##    below (not walls: steeper than MAX_SLOPE is skipped); Shift erases the items;
##  - Place puts exactly one item where clicked; Shift+click removes the nearest one.
## One undo step per stroke / click. Items of one texture share a ScatterSet (with the
## current style and size).

const MAX_SLOPE := 50.0

## Textures to scatter (a random one per point).
var items: Array[Texture2D] = []
var style := ScatterSet.Style.UPRIGHT
## Metres (ScatterSet.size).
var item_size := 0.4
## 0 – 1: each point's size varies by up to this much.
var size_jitter := 0.3
## Points per square metre a stroke fills to.
var density := 4.0
## Edge treatment of new sets (ScatterSet.edge / edge_dark).
var edge := ScatterSet.Edge.DARKEN
var edge_dark := 0.55

var undo: EditorUndoRedoManager
var _stroke := {}
var _rng := RandomNumberGenerator.new()


func is_stroking() -> bool:
	return not _stroke.is_empty()


## The set holding `texture` with the current style and size (made and added to the level
## if missing; end() records it for undo).
func _set_for(texture: Texture2D) -> ScatterSet:
	var data: LevelData = _stroke.root.data
	for s in data.scatter:
		if s and s.texture == texture and s.style == style and is_equal_approx(s.size, item_size):
			return s
	var made := ScatterSet.new()
	made.texture = texture
	made.style = style
	made.size = item_size
	made.edge = edge
	made.edge_dark = edge_dark
	if not _stroke.has("scatter_before"):
		_stroke.scatter_before = data.scatter.duplicate()
	var list := data.scatter.duplicate()
	list.append(made)
	data.scatter = list
	_stroke.new_sets.append(made)
	return made


func begin(root: LevelRoot, point: Vector3, radius: float, erase: bool) -> void:
	_rng.randomize()
	_stroke = {root = root, radius = radius, erase = erase, before = {}, new_sets = [], last = point,
		surface = LevelLighting.level_occluders(root), spacing = 0.75 / sqrt(maxf(density, 0.01)), grid = {}}
	# Existing points of the items, for even spacing.
	for s in root.data.scatter:
		if s and items.has(s.texture):
			for p in s.points:
				_note(Vector3(p.x, p.y, p.z))
	_stamp(point)


func stroke_to(point: Vector3) -> void:
	if _stroke.is_empty():
		return
	var last: Vector3 = _stroke.last
	var step: float = maxf(_stroke.radius * 0.5, 0.05)
	var d := last.distance_to(point)
	if d < step:
		return
	var n := int(d / step)
	for i in range(1, n + 1):
		_stamp(last.lerp(point, float(i) / n))
	_stroke.last = point


func end() -> void:
	if _stroke.is_empty():
		return
	var root: LevelRoot = _stroke.root
	var new_sets: Array = _stroke.new_sets
	# Sets made by this stroke that ended up empty leave again.
	var empty := new_sets.filter(func(s): return s.points.is_empty())
	if not empty.is_empty():
		var keep: Array[ScatterSet] = []
		keep.assign(root.data.scatter.filter(func(s): return not s in empty))
		root.data.scatter = keep
	if not _stroke.before.is_empty() or new_sets.size() > empty.size():
		undo.create_action("Scatter" if not _stroke.erase else "Erase Scatter", UndoRedo.MERGE_DISABLE, root)
		for s: ScatterSet in _stroke.before:
			if s in new_sets:
				continue
			undo.add_do_property(s, &"points", s.points)
			undo.add_undo_property(s, &"points", _stroke.before[s])
		if _stroke.has("scatter_before") and new_sets.size() > empty.size():
			undo.add_do_property(root.data, &"scatter", root.data.scatter.duplicate())
			undo.add_undo_property(root.data, &"scatter", _stroke.scatter_before)
		undo.commit_action()
	_stroke = {}


## Place: one item at `point` (world); Shift: removes the nearest item within `radius`.
func place_one(root: LevelRoot, point: Vector3, normal: Vector3, remove := false, radius := 0.5) -> void:
	if items.is_empty() and not remove:
		return
	_rng.randomize()
	_stroke = {root = root, radius = radius, erase = remove, before = {}, new_sets = [], last = point, surface = null,
		spacing = 0.0, grid = {}}
	var local := root.to_local(point)
	if remove:
		var best: ScatterSet = null
		var best_i := -1
		var best_d := radius
		for s in root.data.scatter:
			if s == null or (not items.is_empty() and not items.has(s.texture)):
				continue
			for i in s.points.size():
				var p := s.points[i]
				var d := Vector3(p.x, p.y, p.z).distance_to(local)
				if d < best_d:
					best_d = d
					best = s
					best_i = i
		if best:
			_touch(best)
			var pts := best.points.duplicate()
			pts.remove_at(best_i)
			best.points = pts
	elif normal.y >= cos(deg_to_rad(MAX_SLOPE)):
		var s := _set_for(items[_rng.randi() % items.size()])
		_touch(s)
		var pts := s.points.duplicate()
		pts.append(Vector4(local.x, local.y, local.z, _scale()))
		s.points = pts
	end()


func _scale() -> float:
	return 1.0 + _rng.randf_range(-size_jitter, size_jitter)


func _touch(s: ScatterSet) -> void:
	if not _stroke.before.has(s):
		_stroke.before[s] = s.points.duplicate()


func _cell(p: Vector3) -> Vector2i:
	var c: float = maxf(_stroke.spacing, 0.05)
	return Vector2i(floori(p.x / c), floori(p.z / c))


func _note(p: Vector3) -> void:
	var k := _cell(p)
	if not _stroke.grid.has(k):
		_stroke.grid[k] = []
	_stroke.grid[k].append(p)


func _crowded(p: Vector3) -> bool:
	var k := _cell(p)
	var sp: float = _stroke.spacing
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for q in _stroke.grid.get(k + Vector2i(dx, dz), []):
				if Vector2(q.x - p.x, q.z - p.z).length() < sp:
					return true
	return false


func _stamp(point: Vector3) -> void:
	var root: LevelRoot = _stroke.root
	var r: float = _stroke.radius
	var centre := root.to_local(point)
	if _stroke.erase:
		for s in root.data.scatter:
			if s == null or (not items.is_empty() and not items.has(s.texture)):
				continue
			var keep := PackedVector4Array()
			for p in s.points:
				if Vector2(p.x - centre.x, p.z - centre.z).length() > r:
					keep.append(p)
			if keep.size() != s.points.size():
				_touch(s)
				s.points = keep
		return
	if items.is_empty() or _stroke.surface == null:
		return
	# Candidates: enough tries to fill the circle at the density; spacing rejects extras.
	var tries := ceili(PI * r * r * density * 1.5)
	var min_up := cos(deg_to_rad(MAX_SLOPE))
	var xf := root.global_transform
	for t in tries:
		var a := _rng.randf() * TAU
		var d := sqrt(_rng.randf()) * r
		var w := point + Vector3(cos(a) * d, 0.0, sin(a) * d)
		var hit: Dictionary = _stroke.surface.cast(w + Vector3.UP * 1.5, w + Vector3.DOWN * 3.0)
		if hit.is_empty() or (hit.normal as Vector3).y < min_up:
			continue
		var local := xf.affine_inverse() * (hit.position as Vector3)
		if _crowded(local):
			continue
		_note(local)
		var s := _set_for(items[_rng.randi() % items.size()])
		_touch(s)
		var pts := s.points
		pts.append(Vector4(local.x, local.y, local.z, _scale()))
		s.points = pts
