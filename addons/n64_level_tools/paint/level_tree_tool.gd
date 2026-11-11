class_name LevelTreeTool
extends RefCounted
## Trees paint mode: a stroke drops tree brushes (PropSpec TREE, each a normal tree brush
## to edit after) over the ground under the brush circle, no closer than `spacing` to any
## tree, each of `species` (one picked at random from the list) with its own seed, size
## (within `size_var`) and turn; Shift removes the trees under the circle. Steep ground
## (walls, roofs) is skipped. One undo step per stroke. Placing a single tree stays on the
## toolbar (Props > Tree).

const SPECIES_DIR := "res://addons/n64_level_tools/trees/species/"
const MAX_SLOPE := 35.0

## Species to plant (a random one per tree).
var species: Array[Resource] = []
## Closest two trees stand (metres).
var spacing := 6.0
## Size variation (fraction either way).
var size_var := 0.2
var undo: EditorUndoRedoManager
var _stroke := {}


func _init() -> void:
	if ResourceLoader.exists(SPECIES_DIR + "sycamore.tres"):
		species.append(load(SPECIES_DIR + "sycamore.tres"))
var _rng := RandomNumberGenerator.new()


func is_stroking() -> bool:
	return not _stroke.is_empty()


func begin(root: LevelRoot, point: Vector3, radius: float, erase: bool) -> void:
	_rng.randomize()
	var trees := []  # positions (level space) of every tree, for spacing
	for b in root.data.brushes:
		if b and b.is_prop() and b.prop.kind == PropSpec.Kind.TREE:
			trees.append(b.transform.origin)
	_stroke = {root = root, radius = radius, erase = erase, added = [], removed = [], trees = trees, last = point,
		surface = LevelLighting.level_occluders(root)}
	_stamp(point)


func stroke_to(point: Vector3) -> void:
	if _stroke.is_empty():
		return
	var last: Vector3 = _stroke.last
	var step: float = maxf(_stroke.radius * 0.5, 0.25)
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
	var added: Array = _stroke.added
	var removed: Array = _stroke.removed
	if undo and (not added.is_empty() or not removed.is_empty()):
		undo.create_action("Plant Trees" if not _stroke.erase else "Remove Trees", UndoRedo.MERGE_DISABLE, root)
		for b in added:
			undo.add_do_method(root.data, &"add_brush", b)
			undo.add_do_reference(b)
			undo.add_undo_method(root.data, &"remove_brush", b)
		for b in removed:
			undo.add_do_method(root.data, &"remove_brush", b)
			undo.add_undo_method(root.data, &"add_brush", b)
			undo.add_undo_reference(b)
		undo.commit_action(false)  # (already planted / removed)
	_stroke = {}


func _stamp(point: Vector3) -> void:
	var root: LevelRoot = _stroke.root
	var r: float = _stroke.radius
	var c := root.to_local(point)
	if _stroke.erase:
		for b in root.data.brushes.duplicate():
			if b and b.is_prop() and b.prop.kind == PropSpec.Kind.TREE and not b in _stroke.removed \
					and Vector2(b.transform.origin.x - c.x, b.transform.origin.z - c.z).length() <= r:
				_stroke.removed.append(b)
				root.data.remove_brush(b)
		return
	if species.is_empty() or _stroke.surface == null:
		return
	var min_up := cos(deg_to_rad(MAX_SLOPE))
	var xf := root.global_transform
	var tries := ceili(PI * r * r / maxf(spacing * spacing, 0.25) * 3.0) + 1
	for t in tries:
		var a := _rng.randf() * TAU
		var d := sqrt(_rng.randf()) * r
		var w := point + Vector3(cos(a) * d, 0.0, sin(a) * d)
		var hit: Dictionary = _stroke.surface.cast(w + Vector3.UP * 3.0, w + Vector3.DOWN * 6.0)
		if hit.is_empty() or (hit.normal as Vector3).y < min_up:
			continue
		var p := xf.affine_inverse() * (hit.position as Vector3)
		var crowded := false
		for q in _stroke.trees:
			if Vector2(q.x - p.x, q.z - p.z).length() < spacing:
				crowded = true
				break
		if crowded:
			continue
		var spec := PropSpec.new()
		spec.kind = PropSpec.Kind.TREE
		spec.settings = {species = species[_rng.randi() % species.size()], seed = _rng.randi_range(1, 99999),
			size = 1.0 + _rng.randf_range(-size_var, size_var)}
		var b := LevelBrush.new()
		b.tag = StringName("prop_%08x" % _rng.randi())
		b.hand_edited = true
		b.transform = Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), Vector3(snappedf(p.x, 0.25), p.y, snappedf(p.z, 0.25)))
		b.prop = spec
		root.data.add_brush(b)
		_stroke.added.append(b)
		_stroke.trees.append(b.transform.origin)
