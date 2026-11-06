@tool
extends Control
## A schedule's day on a 24-hour line: one row per part (in priority order) showing its
## time window, bright where it's the part in effect and faded where a part above it wins
## or its conditions fail (under the editor's what-if state), and a "Result" row: what
## the NPC does across the day. Walks mark when they arrive (red if after the window
## ends). Drag a bar's ends to change its hours, its middle to move it (15-minute steps);
## click to select.

signal selected(index: int)
## A part's hours were changed by dragging (index); `done` on release.
signal hours_changed(index: int, done: bool)

const LABEL_W := 300.0
const ROW_H := 30.0
const HEAD_H := 26.0
const STEP := 0.25
const COLORS := [Color(0.35, 0.7, 0.4), Color(0.35, 0.55, 0.9), Color(0.45, 0.45, 0.48)]

var schedule: NpcSchedule
## The what-if state (PreviewState); its day is the day shown.
var gs: Node
var selected_index := -1
## Index -> walk arrival in hours after the start (WALK parts with a known path).
var arrivals := {}

var _drag := ""  # "", "from", "to", "move"
var _drag_index := -1
var _drag_hour := 0.0
var _drag_from := Vector2.ZERO


func _init() -> void:
	focus_mode = Control.FOCUS_CLICK
	mouse_default_cursor_shape = Control.CURSOR_ARROW


func refresh() -> void:
	var rows := (schedule.entries.size() if schedule else 0) + 1
	custom_minimum_size.y = HEAD_H + ROW_H * rows + 8
	queue_redraw()


func _hour_x(h: float) -> float:
	return LABEL_W + h / 24.0 * (size.x - LABEL_W - 8)


func _x_hour(x: float) -> float:
	return clampf((x - LABEL_W) / (size.x - LABEL_W - 8) * 24.0, 0.0, 24.0)


## The part index in effect at each 15-minute step of the shown day (-1 = nowhere).
func winners() -> PackedInt32Array:
	var out := PackedInt32Array()
	var keep: float = gs.time_of_day
	for k in int(24.0 / STEP):
		gs.time_of_day = k * STEP + 0.001
		var w := -1
		for i in schedule.entries.size():
			var e: ScheduleEntry = schedule.entries[i]
			if e and e.passes(gs):
				w = i
				break
		out.append(w)
	gs.time_of_day = keep
	return out


## [from, to] hour spans of part `e` on the shown day.
func spans(e: ScheduleEntry) -> Array:
	var today := e.days & (1 << posmod(gs.day, 5)) != 0
	var yesterday := e.days & (1 << posmod(gs.day - 1, 5)) != 0
	if e.from_hour == e.to_hour:
		return [Vector2(0, 24)] if today else []
	if e.from_hour < e.to_hour:
		return [Vector2(e.from_hour, e.to_hour)] if today else []
	var out := []
	if yesterday:
		out.append(Vector2(0, e.to_hour))
	if today:
		out.append(Vector2(e.from_hour, 24))
	return out


func _draw() -> void:
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size()
	var text_col := get_theme_color(&"font_color", &"Label")
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.15))
	if schedule == null or gs == null:
		return
	# Hours.
	for h in 25:
		var x := _hour_x(h)
		draw_line(Vector2(x, HEAD_H - 4), Vector2(x, size.y), Color(1, 1, 1, 0.12 if h % 6 else 0.25))
		if h % 3 == 0 and h < 24:
			draw_string(font, Vector2(x + 3, HEAD_H - 8), "%02d" % h, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(text_col, 0.7))
	var won := winners()
	var n := schedule.entries.size()
	for i in n + 1:
		var y := HEAD_H + i * ROW_H
		if i == selected_index:
			draw_rect(Rect2(0, y, size.x, ROW_H), Color(1, 1, 1, 0.07))
		if i == n:
			draw_line(Vector2(0, y), Vector2(size.x, y), Color(1, 1, 1, 0.3))
			draw_string(font, Vector2(8, y + ROW_H * 0.66), "Result", HORIZONTAL_ALIGNMENT_LEFT, LABEL_W - 16, fs, text_col)
			_draw_result(won, y)
			continue
		var e: ScheduleEntry = schedule.entries[i]
		if e == null:
			continue
		var head := "%d. %s" % [i + 1, ("if " + _conditions_text(e)) if not e.conditions.is_empty() else "always"]
		draw_string(font, Vector2(8, y + ROW_H * 0.66), head, HORIZONTAL_ALIGNMENT_LEFT, LABEL_W - 16, fs, text_col)
		var col: Color = COLORS[e.activity]
		for span in spans(e):
			var r := Rect2(_hour_x(span.x), y + 4, maxf(_hour_x(span.y) - _hour_x(span.x), 2), ROW_H - 8)
			draw_rect(r, Color(col, 0.28))
			draw_rect(r, Color(col, 0.6), false, 1.0)
			# Bright where this part is the one in effect.
			for k in won.size():
				if won[k] == i and k * STEP >= span.x and k * STEP < span.y:
					draw_rect(Rect2(_hour_x(k * STEP), r.position.y, _hour_x((k + 1) * STEP) - _hour_x(k * STEP) + 0.5, r.size.y), col)
			var label := e.label if e.label != "" else (String(e.place) if e.activity != ScheduleEntry.Activity.AWAY else "away")
			draw_string(font, r.position + Vector2(5, r.size.y * 0.72), label, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 8, fs - 1, Color(1, 1, 1, 0.95))
		if arrivals.has(i):
			var ah: float = e.from_hour + arrivals[i]
			var late: bool = arrivals[i] > e.duration()
			var ax := _hour_x(fposmod(ah, 24.0))
			draw_colored_polygon(PackedVector2Array([Vector2(ax - 5, y + 2), Vector2(ax + 5, y + 2), Vector2(ax, y + 10)]),
				Color(1, 0.3, 0.25) if late else Color(1, 1, 1, 0.9))


func _draw_result(won: PackedInt32Array, y: float) -> void:
	var font := get_theme_default_font()
	var fs := get_theme_default_font_size()
	var k := 0
	while k < won.size():
		var w := won[k]
		var end := k
		while end + 1 < won.size() and won[end + 1] == w:
			end += 1
		if w >= 0:
			var e: ScheduleEntry = schedule.entries[w]
			var r := Rect2(_hour_x(k * STEP), y + 4, _hour_x((end + 1) * STEP) - _hour_x(k * STEP), ROW_H - 8)
			draw_rect(r, COLORS[e.activity])
			draw_string(font, r.position + Vector2(5, r.size.y * 0.72), str(w + 1), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 8, fs - 1, Color.WHITE)
		k = end + 1


static func _conditions_text(e: ScheduleEntry) -> String:
	return " and ".join(e.conditions.filter(func(c): return c).map(func(c): return c.describe()))


func _row_at(y: float) -> int:
	var i := floori((y - HEAD_H) / ROW_H)
	return i if schedule and i >= 0 and i < schedule.entries.size() else -1


func _gui_input(event: InputEvent) -> void:
	if schedule == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var i := _row_at(event.position.y)
			if i < 0:
				return
			selected_index = i
			selected.emit(i)
			_drag = ""
			var e: ScheduleEntry = schedule.entries[i]
			var h := _x_hour(event.position.x)
			for span in spans(e):
				var x0 := _hour_x(span.x)
				var x1 := _hour_x(span.y)
				if event.position.x < x0 - 6 or event.position.x > x1 + 6:
					continue
				if absf(event.position.x - x0) <= 6 and span.x == e.from_hour:
					_drag = "from"
				elif absf(event.position.x - x1) <= 6 and span.y == e.to_hour:
					_drag = "to"
				elif event.position.x > LABEL_W:
					_drag = "move"
			_drag_index = i
			_drag_hour = h
			queue_redraw()
			accept_event()
		elif _drag != "":
			_drag = ""
			hours_changed.emit(_drag_index, true)
			accept_event()
	elif event is InputEventMouseMotion:
		if _drag != "":
			var e: ScheduleEntry = schedule.entries[_drag_index]
			var h := snappedf(_x_hour(event.position.x), STEP)
			match _drag:
				"from":
					e.from_hour = h
				"to":
					e.to_hour = h
				"move":
					var dh := snappedf(_x_hour(event.position.x) - _drag_hour, STEP)
					if dh != 0.0:
						e.from_hour = fposmod(e.from_hour + dh, 24.0)
						e.to_hour = fposmod(e.to_hour + dh, 24.0) if e.to_hour != 24.0 else 24.0
						_drag_hour += dh
			hours_changed.emit(_drag_index, false)
			queue_redraw()
			accept_event()
		else:
			var i := _row_at(event.position.y)
			var cursor := Control.CURSOR_ARROW
			if i >= 0:
				var e: ScheduleEntry = schedule.entries[i]
				for span in spans(e):
					if absf(event.position.x - _hour_x(span.x)) <= 6 or absf(event.position.x - _hour_x(span.y)) <= 6:
						cursor = Control.CURSOR_HSIZE
			mouse_default_cursor_shape = cursor


func _get_tooltip(at: Vector2) -> String:
	var i := _row_at(at.y)
	if i < 0:
		return ""
	var e: ScheduleEntry = schedule.entries[i]
	var tip := e.describe()
	if not e.conditions.is_empty():
		tip += "\nif " + _conditions_text(e)
	if arrivals.has(i):
		tip += "\narrives after %d min" % roundi(arrivals[i] * 60.0)
	return tip
