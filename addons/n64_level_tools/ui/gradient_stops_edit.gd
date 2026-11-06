@tool
class_name GradientStopsEdit
extends Control
## The gradient tool's stops: the coverage ramp drawn left (0 %) to right (100 %), white =
## full layer coverage, with a handle per stop underneath. Drag a handle to move it,
## double-click to add a stop; right-click (on the bar or a handle) or Delete removes one.
## The selected stop's coverage is edited outside (set_coverage).

signal stops_changed(stops: PackedVector2Array)
signal stop_selected(index: int)

const HANDLE := 7.0

var tool: LevelGradientTool
var selected := 0
var _drag := -1
var _scale := 1.0


func _init(ui_scale := 1.0) -> void:
	_scale = ui_scale
	custom_minimum_size = Vector2(0, 40 * ui_scale)
	mouse_filter = MOUSE_FILTER_STOP
	focus_mode = FOCUS_CLICK
	tooltip_text = "Coverage along the gradient (white = full). Drag a handle to move a stop,\ndouble-click to add one, right-click near one (or select it + Delete) to remove it."


func _bar() -> Rect2:
	var h := HANDLE * _scale
	return Rect2(h, 2, size.x - h * 2, size.y - h * 2 - 4)


func _x(t: float) -> float:
	var r := _bar()
	return r.position.x + t * r.size.x


func _draw() -> void:
	if tool == null:
		return
	var r := _bar()
	var steps := int(maxf(r.size.x / 2.0, 2.0))
	for i in steps:
		var t0 := float(i) / steps
		var v := tool.sample(t0 + 0.5 / steps)
		draw_rect(Rect2(r.position.x + t0 * r.size.x, r.position.y, r.size.x / steps + 1.0, r.size.y), Color(v, v, v))
	draw_rect(r, Color(1, 1, 1, 0.35), false, 1.0)
	# 50 % tick, for hard stops at half.
	draw_line(Vector2(_x(0.5), r.end.y), Vector2(_x(0.5), r.end.y + 3 * _scale), Color(1, 1, 1, 0.4))
	var h := HANDLE * _scale
	for i in tool.stops.size():
		var s := tool.stops[i]
		var x := _x(s.x)
		var top := r.end.y + 2
		var pts := PackedVector2Array([Vector2(x, top), Vector2(x + h, top + h * 1.6), Vector2(x - h, top + h * 1.6)])
		draw_colored_polygon(pts, Color(s.y, s.y, s.y))
		var outline := Color(1.0, 0.75, 0.3) if i == selected else Color(0.6, 0.6, 0.6)
		draw_polyline(pts + PackedVector2Array([pts[0]]), outline, 2.0 if i == selected else 1.0)


## The stop nearest `p` horizontally (`anywhere`: also over the bar, not just the handles).
func _handle_at(p: Vector2, anywhere := false) -> int:
	var best := -1
	var best_d := HANDLE * _scale * (3.0 if anywhere else 1.5)
	for i in tool.stops.size():
		var d := absf(p.x - _x(tool.stops[i].x))
		if d < best_d and (anywhere or p.y > _bar().end.y - 4):
			best_d = d
			best = i
	return best


func _gui_input(event: InputEvent) -> void:
	if tool == null:
		return
	if event is InputEventKey and event.pressed and event.keycode in [KEY_DELETE, KEY_BACKSPACE]:
		remove_selected()
		accept_event()
		return
	if event is InputEventMouseButton and event.pressed:
		var i := _handle_at(event.position, event.button_index == MOUSE_BUTTON_RIGHT)
		if event.button_index == MOUSE_BUTTON_RIGHT and i >= 0:
			selected = i
			remove_selected()
		elif event.button_index == MOUSE_BUTTON_LEFT and event.double_click and i < 0:
			var t := clampf((event.position.x - _bar().position.x) / _bar().size.x, 0.0, 1.0)
			var list := tool.stops
			list.append(Vector2(t, tool.sample(t)))
			tool.stops = list
			tool.sort_stops()
			for k in tool.stops.size():
				if is_equal_approx(tool.stops[k].x, t):
					selected = k
			_emit()
		elif event.button_index == MOUSE_BUTTON_LEFT and i >= 0:
			selected = i
			_drag = i
			stop_selected.emit(i)
			queue_redraw()
		accept_event()
	elif event is InputEventMouseButton and not event.pressed and _drag >= 0:
		_drag = -1
		_emit()
	elif event is InputEventMouseMotion and _drag >= 0:
		var t := clampf((event.position.x - _bar().position.x) / _bar().size.x, 0.0, 1.0)
		if not event.shift_pressed:
			t = snappedf(t, 0.05)  # 5 % steps; Shift: free
		var list := tool.stops
		list[_drag].x = t
		var moved := list[_drag]
		tool.stops = list
		tool.sort_stops()
		# The dragged handle may pass another: follow it to its new index.
		_drag = tool.stops.find(moved)
		selected = _drag
		queue_redraw()
		accept_event()


## Removes the selected stop (one always stays).
func remove_selected() -> void:
	if tool == null or tool.stops.size() <= 1 or selected >= tool.stops.size():
		return
	var list := tool.stops
	list.remove_at(selected)
	tool.stops = list
	selected = clampi(selected, 0, tool.stops.size() - 1)
	_emit()


func set_coverage(v: float) -> void:
	if tool == null or selected >= tool.stops.size():
		return
	var list := tool.stops
	list[selected].y = v
	tool.stops = list
	_emit()


func _emit() -> void:
	queue_redraw()
	stop_selected.emit(selected)
	stops_changed.emit(tool.stops)
