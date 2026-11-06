@tool
extends RefCounted
## Editing a fence or rope brush (the only brush selected, Object mode) in the 3D view, and
## placing a new rope (click its two anchors). Its points are handles: a fence's snap to
## the grid and drop onto the ground, a rope's sit where they're put on the level (pulled
## onto corners near the mouse); each pair of neighbouring points a section (any direction,
## its own slope). Drag a point to move it, click a section's "+" to split it there,
## Shift+click the ground to extend the fence from its nearer end, Alt+click a point to
## remove it, Alt+click a section to open / close it. One undo step per change.

const PICK_PX := 12.0
const POINT_COLOR := Color(1.0, 0.75, 0.25)
const HOVER_COLOR := Color(1.0, 1.0, 1.0)
const OPEN_COLOR := Color(1.0, 0.4, 0.35)
const LINE_COLOR := Color(1.0, 0.75, 0.25, 0.8)
const CORNER_COLOR := Color(0.4, 1.0, 0.5)
## Screen distance within which a rope's anchor snaps to a corner.
const SNAP_PX := 16.0
const RopeBuilder := preload("res://addons/n64_level_tools/rope_builder.gd")

var plugin: EditorPlugin
## {kind: "point" / "mid" / "line", index} under the mouse, or {}.
var hover := {}
## Point being dragged (-1 = none) and the fence's points before the drag.
var drag := -1
var _before := PackedVector3Array()
var _before_open := PackedInt32Array()
## Rope tool: waiting for its anchors (first one clicked, the one under the mouse).
var placing := false
var _first = null
var _cursor = null
## The last anchor_at_mouse() landed on a corner.
var anchor_on_corner := false


func _init(p: EditorPlugin) -> void:
	plugin = p


## The fence or rope brush being edited: the only brush selected in Object mode, or null.
func selected_fence() -> LevelBrush:
	if plugin.mode != plugin.Mode.OBJECT or plugin.sel_brushes.size() != 1 or not plugin._level_ok():
		return null
	var b: LevelBrush = plugin.sel_brushes[0]
	return b if b and (b.is_fence() or b.is_rope()) and plugin.level.has_brush(b) else null


func _xf(fence: LevelBrush) -> Transform3D:
	return plugin.level.brush_global_transform(fence)


func input(fence: LevelBrush, camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventMouseMotion:
		if drag >= 0:
			var p = _ground_at_mouse(fence, camera, event.position, _xf(fence) * fence.path_points()[drag])
			if p != null:
				var pts := fence.path_points().duplicate()
				pts[drag] = _xf(fence).affine_inverse() * p
				if pts != fence.path_points():
					fence.set(fence.path_properties()[0], pts)
			plugin.update_overlays()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		var h := _hover(fence, camera, event.position)
		if h != hover:
			hover = h
			plugin.update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not event.pressed:
		if drag >= 0:
			drag = -1
			_commit(fence, "Move %s Point" % _noun(fence).capitalize())
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	hover = _hover(fence, camera, event.position)
	_before = fence.path_points().duplicate()
	_before_open = fence.path_open().duplicate()
	if event.alt_pressed:
		if hover.get("kind") == "point":
			if fence.path_points().size() <= 2:
				push_warning("N64 Level Tools: a %s needs at least two points (Delete removes the whole thing)." % _noun(fence))
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			_remove_point(fence, hover.index)
			_commit(fence, "Remove %s Point" % _noun(fence).capitalize())
		elif hover.get("kind") in ["line", "mid"]:
			var open := fence.path_open().duplicate()
			var at := open.find(hover.index)
			if at >= 0:
				open.remove_at(at)
			else:
				open.append(hover.index)
			fence.set(fence.path_properties()[1], open)
			_commit(fence, "Open / Close %s Section" % _noun(fence).capitalize())
		else:
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		hover = {}
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	match hover.get("kind"):
		"point":
			drag = hover.index
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		"mid":
			drag = _insert_point(fence, hover.index)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event.shift_pressed:
		# Extend from the nearer end (a closed fence: after the nearest point).
		var p = _ground_at_mouse(fence, camera, event.position, null)
		if p == null:
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		var local: Vector3 = _xf(fence).affine_inverse() * p
		var pts := fence.path_points().duplicate()
		if not fence.path_closed() and local.distance_to(pts[0]) < local.distance_to(pts[pts.size() - 1]):
			pts.insert(0, local)
			fence.set(fence.path_properties()[1], _shifted(fence.path_open(), -1, 1))
			drag = 0
		else:
			pts.append(local)
			drag = pts.size() - 1
		fence.set(fence.path_properties()[0], pts)
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func draw(fence: LevelBrush, overlay: Control, camera: Camera3D) -> void:
	var xf := _xf(fence)
	var n := fence.path_points().size()
	var sections := n - 1 + (1 if fence.path_closed() and n > 2 else 0)
	for i in sections:
		var a := xf * fence.path_points()[i]
		var b := xf * fence.path_points()[(i + 1) % n]
		var open := i in fence.path_open()
		var hot: bool = hover.get("index", -1) == i and hover.get("kind") in ["line", "mid"]
		var col := HOVER_COLOR if hot else (OPEN_COLOR if open else LINE_COLOR)
		var line := _section_line(fence, i)
		for k in line.size() - 1:
			plugin._line3d(overlay, camera, line[k], line[k + 1], col, 3.0 if hot else 2.0)
		var mid := line[line.size() / 2]
		if not camera.is_position_behind(mid):
			var m := camera.unproject_position(mid)
			var r := 6.0 * EditorInterface.get_editor_scale()
			overlay.draw_line(m - Vector2(r, 0), m + Vector2(r, 0), col, 2.0)
			overlay.draw_line(m - Vector2(0, r), m + Vector2(0, r), col, 2.0)
			if hot:
				plugin._draw_label(overlay, m + Vector2(12, 12), "Click: split here · Alt+click: %s this section · %.2f m" % [
					"close" if open else "open", a.distance_to(b) if fence.is_rope() else Vector2(b.x - a.x, b.z - a.z).length()])
	for i in n:
		var p := xf * fence.path_points()[i]
		if camera.is_position_behind(p):
			continue
		var s := camera.unproject_position(p)
		var hot: bool = hover.get("kind") == "point" and hover.index == i or drag == i
		var r := (7.0 if hot else 5.0) * EditorInterface.get_editor_scale()
		overlay.draw_circle(s, r, HOVER_COLOR if hot else POINT_COLOR)
		overlay.draw_arc(s, r, 0.0, TAU, 16, Color.BLACK, 1.0)
		if hot:
			plugin._draw_label(overlay, s + Vector2(12, 12), "(%.2f, %.2f, %.2f) · drag: move · Alt+click: remove" % [p.x, p.y, p.z])


func _hover(fence: LevelBrush, camera: Camera3D, pos: Vector2) -> Dictionary:
	var xf := _xf(fence)
	var n := fence.path_points().size()
	var r := PICK_PX * EditorInterface.get_editor_scale()
	for i in n:
		var p := xf * fence.path_points()[i]
		if not camera.is_position_behind(p) and camera.unproject_position(p).distance_to(pos) <= r:
			return {kind = "point", index = i}
	var best := {}
	var best_d := r
	for i in n - 1 + (1 if fence.path_closed() and n > 2 else 0):
		var line := _section_line(fence, i)
		if line.size() % 2 == 1 and not camera.is_position_behind(line[line.size() / 2]) \
				and camera.unproject_position(line[line.size() / 2]).distance_to(pos) <= r:
			return {kind = "mid", index = i}
		for k in line.size() - 1:
			if camera.is_position_behind(line[k]) or camera.is_position_behind(line[k + 1]):
				continue
			var d := pos.distance_to(Geometry2D.get_closest_point_to_segment(pos,
				camera.unproject_position(line[k]), camera.unproject_position(line[k + 1])))
			if d < best_d:
				best_d = d
				best = {kind = "line", index = i}
	return best


## Section `i` as drawn (world, an odd number of points: the middle one is its "+"): a
## fence's straight line just above the ground, a rope's hanging curve.
func _section_line(fence: LevelBrush, i: int) -> PackedVector3Array:
	var xf := _xf(fence)
	var pts := fence.path_points()
	var a := pts[i]
	var b := pts[(i + 1) % pts.size()]
	var out := PackedVector3Array()
	if fence.is_rope():
		var sag := fence.rope_sag
		for k in 9:
			var t := k / 8.0
			out.append(xf * (a.lerp(b, t) + Vector3.DOWN * sag * 4.0 * t * (1.0 - t)))
		return out
	for p in [xf * a, (xf * a + xf * b) * 0.5, xf * b]:
		out.append(p + Vector3.UP * 0.05)
	return out


## World point on the ground under the mouse, its x / z on the snap grid and dropped onto
## the level (fences ignored). `fallback`: when nothing's under the mouse, the mouse ray
## meets that point's height instead. null = nowhere.
func _ground_at_mouse(fence: LevelBrush, camera: Camera3D, pos: Vector2, fallback) -> Variant:
	if fence.is_rope():
		return anchor_at_mouse(camera, pos, fallback)
	var from := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var hit := _ray(from, dir)
	var p: Vector3
	if not hit.is_empty():
		p = hit.position
	elif fallback != null:
		var at = Plane(Vector3.UP, fallback.y).intersects_ray(from, dir)
		if at == null:
			return null
		p = at
	else:
		return null
	var snap: float = plugin.snap
	if snap > 0.0:
		p.x = snappedf(p.x, snap)
		p.z = snappedf(p.z, snap)
	var down := _ray(Vector3(p.x, p.y + 4.0, p.z), Vector3.DOWN)
	if not down.is_empty():
		p.y = down.position.y
	return p


## A rope's anchor under the mouse (world): where the mouse ray meets the level, pulled
## onto a corner of what it hits when one is near the mouse (building corners, posts).
## `fallback`: when nothing's under the mouse, the ray meets that point's height instead.
## null = nowhere.
func anchor_at_mouse(camera: Camera3D, pos: Vector2, fallback) -> Variant:
	var from := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var hit := _ray(from, dir)
	anchor_on_corner = false
	if hit.is_empty():
		if fallback == null:
			return null
		return Plane(Vector3.UP, fallback.y).intersects_ray(from, dir)
	var p: Vector3 = hit.position
	var root: LevelRoot = hit.root
	var xf := root.brush_global_transform(hit.brush)
	var best_d := SNAP_PX * EditorInterface.get_editor_scale()
	for v in (hit.brush as LevelBrush).vertices:
		var w := xf * v
		if camera.is_position_behind(w):
			continue
		var d := camera.unproject_position(w).distance_to(pos)
		if d < best_d:
			best_d = d
			p = w
			anchor_on_corner = true
	return p


# --- Placing a rope -------------------------------------------------------------------

## Rope tool: click one anchor, then the other; the rope hangs between them (selected).
func start_rope() -> void:
	placing = true
	_first = null
	_cursor = null
	plugin.update_overlays()


func place_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		placing = false
		plugin.update_overlays()
		plugin._refresh_status()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event is InputEventMouseMotion:
		_cursor = anchor_at_mouse(camera, event.position, _first)
		plugin.update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not event.pressed:
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	var p = anchor_at_mouse(camera, event.position, _first)
	if p == null:
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if _first == null:
		_first = p
	elif p.distance_to(_first) > 0.05:
		placing = false
		plugin._add_rope_brush(_first, p)
	plugin.update_overlays()
	plugin._refresh_status()
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func draw_placing(overlay: Control, camera: Camera3D) -> void:
	if _first != null and _cursor != null:
		var curve := RopeBuilder.section_curve(_first, _cursor, plugin._default_rope_sag(), 0.25)
		for k in curve.size() - 1:
			plugin._line3d(overlay, camera, curve[k], curve[k + 1], LINE_COLOR, 2.0)
	for p in [_first, _cursor]:
		if p == null or camera.is_position_behind(p):
			continue
		var s := camera.unproject_position(p)
		var r := 6.0 * EditorInterface.get_editor_scale()
		overlay.draw_circle(s, r, CORNER_COLOR if p == _cursor and anchor_on_corner else POINT_COLOR)
		overlay.draw_arc(s, r, 0.0, TAU, 16, Color.BLACK, 1.0)
	if _cursor != null and not camera.is_position_behind(_cursor):
		var text := "Click: first anchor" if _first == null else "Click: other anchor (%.2f m)" % _first.distance_to(_cursor)
		if anchor_on_corner:
			text += " · on a corner"
		plugin._draw_label(overlay, camera.unproject_position(_cursor) + Vector2(12, 12), text + " · Esc: cancel")


static func _noun(b: LevelBrush) -> String:
	return "rope" if b.is_rope() else "fence"


## Nearest level hit along a ray ({root} added), skipping fences' and ropes' own brushes.
func _ray(from: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	for root: LevelRoot in plugin._scene_level_roots():
		if not root.is_visible_in_tree():
			continue
		var hit := root.raycast(from, dir, false, true)
		if hit and (best.is_empty() or hit.distance < best.distance):
			best = hit
			best.root = root
	return best


## Splits section `i` at its middle (on the ground); returns the new point's index.
func _insert_point(fence: LevelBrush, i: int) -> int:
	var n := fence.path_points().size()
	var xf := _xf(fence)
	var mid := (xf * fence.path_points()[i] + xf * fence.path_points()[(i + 1) % n]) * 0.5
	if fence.is_rope():
		mid = _section_line(fence, i)[4]  # where the rope hangs there (the new point holds it up)
	else:
		var down := _ray(mid + Vector3.UP * 4.0, Vector3.DOWN)
		if not down.is_empty():
			mid.y = down.position.y
	var pts := fence.path_points().duplicate()
	pts.insert(i + 1, xf.affine_inverse() * mid)
	# Sections after i move up one; an open section stays open on both halves.
	var open := _shifted(fence.path_open(), i, 1)
	if i in fence.path_open():
		open.append(i + 1)
	fence.set(fence.path_properties()[1], open)
	fence.set(fence.path_properties()[0], pts)
	return i + 1


func _remove_point(fence: LevelBrush, k: int) -> void:
	var pts := fence.path_points().duplicate()
	pts.remove_at(k)
	# Sections k - 1 and k join (open if the first was); later ones move down one.
	var open := PackedInt32Array()
	for s in fence.path_open():
		if s < k:
			open.append(s)
		elif s > k:
			open.append(s - 1)
	fence.set(fence.path_properties()[1], open)
	fence.set(fence.path_properties()[0], pts)


## Open sections after `after` moved by `by`.
static func _shifted(open: PackedInt32Array, after: int, by: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for s in open:
		out.append(s + by if s > after else s)
	return out


func _commit(fence: LevelBrush, action: String) -> void:
	if fence.path_points() == _before and fence.path_open() == _before_open:
		return
	var ur := plugin.get_undo_redo()
	ur.create_action(action, UndoRedo.MERGE_DISABLE, plugin.level)
	var props := fence.path_properties()
	ur.add_do_property(fence, props[0], fence.path_points())
	ur.add_do_property(fence, props[1], fence.path_open())
	ur.add_undo_property(fence, props[0], _before)
	ur.add_undo_property(fence, props[1], _before_open)
	ur.commit_action(false)
