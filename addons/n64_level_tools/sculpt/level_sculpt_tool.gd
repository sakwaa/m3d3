@tool
class_name LevelSculptTool
extends RefCounted
## Terrain sculpting on floor brushes (GRID / PLANE shapes, untagged): a round brush in
## top-down (XZ) space moves vertices along world Y, weighted by distance and falloff.
## Vertices of neighbouring floors at the same spot get the same weight, so seams stay
## closed. One undo step per stroke; heights can snap to the grid (N64-style terraces).

enum Tool { RAISE, LOWER, SMOOTH, FLATTEN, HEIGHT }
enum Falloff { SMOOTH, LINEAR, SHARP, CONSTANT }

const TOOL_NAMES := ["Raise", "Lower", "Smooth", "Flatten", "Raise to Height"]
const FALLOFF_NAMES := ["Smooth", "Linear", "Sharp", "Constant"]

var tool := Tool.RAISE
## Brush radius in metres (top-down).
var radius := 2.0
## Raise / Lower: metres per stamp at the centre. Smooth / Flatten / Height: fraction of
## the way to the target per stamp at the centre.
var strength := 0.25
var falloff := Falloff.SMOOTH
## Raise to Height target (world Y).
var height := 1.0
## Round touched heights to `snap_step` when the stroke ends.
var snap_heights := false
var snap_step := 0.25
var undo: EditorUndoRedoManager

var _stroke := {}


func is_stroking() -> bool:
	return not _stroke.is_empty()


## `invert`: Shift held (Raise <-> Lower). Flatten samples its target height at `point`.
func begin_stroke(root: LevelRoot, point: Vector3, invert: bool) -> void:
	_stroke = {root = root, before = {}, last = point, invert = invert, flat_y = point.y}
	_stamp(point)


func stroke_to(point: Vector3) -> void:
	if _stroke.is_empty():
		return
	var last: Vector3 = _stroke.last
	var flat := Vector2(point.x - last.x, point.z - last.z)
	var spacing := maxf(radius * 0.25, 0.05)
	if flat.length() < spacing:
		return
	var steps := int(flat.length() / spacing)
	for i in steps:
		_stamp(last.lerp(point, float(i + 1) / steps))
	_stroke.last = point


func end_stroke() -> void:
	if _stroke.is_empty():
		return
	var root: LevelRoot = _stroke.root
	var before: Dictionary = _stroke.before
	if snap_heights and snap_step > 0.0:
		for brush: LevelBrush in before:
			var verts := brush.vertices.duplicate()
			var xf := root.brush_global_transform(brush)
			var inv := xf.affine_inverse()
			var orig: PackedVector3Array = before[brush]
			for i in verts.size():
				if verts[i] == orig[i]:
					continue
				var w := xf * verts[i]
				w.y = snappedf(w.y, snap_step)
				verts[i] = inv * w
			brush.vertices = verts
	if not before.is_empty() and undo != null:
		undo.create_action("Sculpt Terrain", UndoRedo.MERGE_DISABLE, root)
		for brush: LevelBrush in before:
			undo.add_do_property(brush, &"vertices", brush.vertices)
			undo.add_undo_property(brush, &"vertices", before[brush])
			undo.add_do_property(brush, &"hand_edited", true)
			undo.add_undo_property(brush, &"hand_edited", brush.hand_edited)
		undo.commit_action()
	_stroke = {}


## Weight 0..1 of a top-down distance `d` from the brush centre.
func weight(d: float) -> float:
	if d >= radius:
		return 0.0
	var t := d / maxf(radius, 0.001)
	match falloff:
		Falloff.LINEAR:
			return 1.0 - t
		Falloff.SHARP:
			return (1.0 - t) * (1.0 - t)
		Falloff.CONSTANT:
			return 1.0
	return 0.5 + 0.5 * cos(t * PI)  # smooth dome


## Sculptable brushes of `root`: untagged GRID / PLANE floors (passage floors and set
## pieces excluded).
static func is_terrain(brush: LevelBrush) -> bool:
	return brush != null and String(brush.tag).is_empty() and brush.blend_file == "" \
		and (brush.shape == BrushShapes.Shape.GRID or brush.shape == BrushShapes.Shape.PLANE)


## [{brush, index, world, weight}] for every terrain vertex under the brush at `point`.
func affected(root: LevelRoot, point: Vector3) -> Array:
	var out := []
	for brush in root.data.brushes:
		if not is_terrain(brush):
			continue
		var xf := root.brush_global_transform(brush)
		for i in brush.vertices.size():
			var w := xf * brush.vertices[i]
			var k := weight(Vector2(w.x - point.x, w.z - point.z).length())
			if k > 0.0:
				out.append({brush = brush, index = i, world = w, weight = k})
	return out


func _stamp(point: Vector3) -> void:
	var root: LevelRoot = _stroke.root
	var hits := affected(root, point)
	if hits.is_empty():
		return
	var mode := tool
	if _stroke.invert:
		if mode == Tool.RAISE:
			mode = Tool.LOWER
		elif mode == Tool.LOWER:
			mode = Tool.RAISE
	var neighbour_y := _neighbour_heights(root, hits) if mode == Tool.SMOOTH else {}
	var target_y: float = _stroke.flat_y if mode == Tool.FLATTEN else height
	var edits := {}
	for h in hits:
		var w: Vector3 = h.world
		var k: float = h.weight
		match mode:
			Tool.RAISE:
				w.y += strength * k
			Tool.LOWER:
				w.y -= strength * k
			Tool.SMOOTH:
				w.y = lerpf(w.y, neighbour_y.get([h.brush, h.index], w.y), clampf(strength * 2.0, 0.0, 1.0) * k)
			Tool.FLATTEN, Tool.HEIGHT:
				w.y = lerpf(w.y, target_y, clampf(strength * 2.0, 0.0, 1.0) * k)
		if not edits.has(h.brush):
			edits[h.brush] = []
		edits[h.brush].append([h.index, w])
	for brush: LevelBrush in edits:
		if not _stroke.before.has(brush):
			_stroke.before[brush] = brush.vertices.duplicate()
		var inv := root.brush_global_transform(brush).affine_inverse()
		var verts := brush.vertices.duplicate()
		for e in edits[brush]:
			verts[e[0]] = inv * (e[1] as Vector3)
		brush.vertices = verts


## Average world height of each hit vertex's edge neighbours (same brush). The neighbour
## lists are built once per stroke (sculpting moves vertices, not edges).
func _neighbour_heights(root: LevelRoot, hits: Array) -> Dictionary:
	var out := {}
	if not _stroke.has("adjacency"):
		_stroke.adjacency = {}
	for h in hits:
		var brush: LevelBrush = h.brush
		if not _stroke.adjacency.has(brush):
			var adj := []
			adj.resize(brush.vertices.size())
			for i in adj.size():
				adj[i] = PackedInt32Array()
			for e in brush.get_edges():
				adj[e.x].append(e.y)
				adj[e.y].append(e.x)
			_stroke.adjacency[brush] = adj
		var near: PackedInt32Array = _stroke.adjacency[brush][h.index]
		if near.is_empty():
			continue
		var xf := root.brush_global_transform(brush)
		var sum := 0.0
		for j in near:
			sum += (xf * brush.vertices[j]).y
		out[[brush, h.index]] = sum / near.size()
	return out
