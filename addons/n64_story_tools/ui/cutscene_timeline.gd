@tool
extends Control
## The Cutscenes tab's timeline: a ruler (click / drag = playhead) over one row per track
## (camera, dialogue, events, each actor), keys as diamonds (bars for ones that take time).
## Click a key to select it, drag to move it (0.1 s steps; Shift: free), Delete removes it.

signal time_changed(t: float)
signal key_selected(cue: CutsceneCue)
## A key was dragged from `from` to its current time (one undo step for the whole drag).
signal key_moved(cue: CutsceneCue, from: float)
signal delete_requested(cue: CutsceneCue)

const RULER := 22.0
const ROW := 24.0
const LABEL_W := 92.0
const ROW_COLORS := {camera = Color(1.0, 0.6, 0.15), dialogue = Color(0.5, 0.8, 1.0), events = Color(0.85, 0.55, 1.0)}

var cutscene: Cutscene
var time := 0.0
var selected: CutsceneCue
var _drag: CutsceneCue
var _drag_from := 0.0
var _drag_offset := 0.0
var _scrubbing := false
var _scale := 1.0


func _init(ui_scale := 1.0) -> void:
	_scale = ui_scale
	focus_mode = FOCUS_CLICK
	mouse_filter = MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0, (RULER + ROW * 4) * ui_scale)
	tooltip_text = "Click the ruler to move the playhead. Click a key to edit it in the inspector,\ndrag to move it (Shift: no snapping), Delete removes it."


func set_cutscene(c: Cutscene) -> void:
	cutscene = c
	selected = null
	refresh()


func refresh() -> void:
	if cutscene:
		custom_minimum_size.y = (RULER + ROW * cutscene.track_ids().size()) * _scale
	queue_redraw()


func _px_per_s() -> float:
	return (size.x - LABEL_W * _scale - 8.0) / maxf(cutscene.length if cutscene else 1.0, 0.5)


func _x(t: float) -> float:
	return LABEL_W * _scale + t * _px_per_s()


func _t(x: float) -> float:
	return clampf((x - LABEL_W * _scale) / _px_per_s(), 0.0, cutscene.length if cutscene else 0.0)


func _row_y(track: StringName) -> float:
	return (RULER + ROW * cutscene.track_ids().find(track)) * _scale


func _draw() -> void:
	var font := get_theme_default_font()
	var fs := int(11 * _scale)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.1, 0.11, 0.13))
	if cutscene == null:
		draw_string(font, Vector2(12, 30) * _scale, "Pick or create a cutscene on the left.", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.5))
		return
	# Ruler: a tick every second (labelled), every 0.5 s short.
	var step := 0.5
	var t := 0.0
	while t <= cutscene.length + 0.001:
		var x := _x(t)
		var whole := is_equal_approx(fmod(t, 1.0), 0.0)
		draw_line(Vector2(x, RULER * _scale - (8 if whole else 4) * _scale), Vector2(x, RULER * _scale), Color(1, 1, 1, 0.4))
		if whole:
			draw_string(font, Vector2(x + 2, 11 * _scale), "%ds" % int(t), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.55))
		t += step
	var tracks := cutscene.track_ids()
	for i in tracks.size():
		var y := (RULER + ROW * i) * _scale
		draw_rect(Rect2(0, y, size.x, ROW * _scale), Color(1, 1, 1, 0.03 if i % 2 == 0 else 0.0))
		var label := String(tracks[i]).capitalize()
		draw_string(font, Vector2(6 * _scale, y + 16 * _scale), label, HORIZONTAL_ALIGNMENT_LEFT, LABEL_W * _scale - 8, fs, _track_color(tracks[i]))
	draw_line(Vector2(LABEL_W * _scale, RULER * _scale), Vector2(LABEL_W * _scale, size.y), Color(1, 1, 1, 0.15))
	# Labels stop short of the next key on the same row.
	var keys := cutscene.sorted()
	for i in keys.size():
		var room := 160.0 * _scale
		for j in range(i + 1, keys.size()):
			if keys[j].track() == keys[i].track():
				room = minf(room, _x(keys[j].time) - _x(keys[i].time) - 12.0 * _scale)
				break
		_draw_key(keys[i], font, fs, room)
	var px := _x(time)
	draw_line(Vector2(px, 0), Vector2(px, size.y), Color(1.0, 0.3, 0.3), 2.0)


func _track_color(track: StringName) -> Color:
	if ROW_COLORS.has(String(track)):
		return ROW_COLORS[String(track)]
	return Color(0.55, 1.0, 0.55) if track == CutsceneCue.PLAYER else Color.from_hsv(fposmod(hash(track) * 0.0001, 1.0), 0.45, 1.0)


func _draw_key(c: CutsceneCue, font: Font, fs: int, room: float) -> void:
	var y := _row_y(c.track()) + ROW * 0.5 * _scale
	var x := _x(c.time)
	var col := _track_color(c.track())
	var span := c.span()
	if span > 0.0:
		draw_rect(Rect2(x, y - 5 * _scale, _x(c.time + span) - x, 10 * _scale), Color(col, 0.35))
	var r := 6.0 * _scale
	var pts := PackedVector2Array([Vector2(x, y - r), Vector2(x + r, y), Vector2(x, y + r), Vector2(x - r, y)])
	draw_colored_polygon(pts, col)
	if c == selected:
		draw_polyline(pts + PackedVector2Array([pts[0]]), Color.WHITE, 2.0)
	if room > 14.0 * _scale:
		draw_string(font, Vector2(x + r + 3, y + 4 * _scale), c.label(), HORIZONTAL_ALIGNMENT_LEFT, room, fs, Color(1, 1, 1, 0.75))


func _key_at(p: Vector2) -> CutsceneCue:
	if cutscene == null:
		return null
	var best: CutsceneCue = null
	var best_d := 9.0 * _scale
	for c in cutscene.sorted():
		var y := _row_y(c.track()) + ROW * 0.5 * _scale
		if absf(p.y - y) > ROW * 0.5 * _scale:
			continue
		var d := absf(p.x - _x(c.time))
		if d < best_d:
			best_d = d
			best = c
	return best


func _gui_input(event: InputEvent) -> void:
	if cutscene == null:
		return
	if event is InputEventKey and event.pressed and event.keycode in [KEY_DELETE, KEY_BACKSPACE] and selected:
		delete_requested.emit(selected)
		accept_event()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.position.y < RULER * _scale:
				_scrubbing = true
				_set_time(_t(event.position.x))
			else:
				var c := _key_at(event.position)
				selected = c
				if c:
					_drag = c
					_drag_from = c.time
					_drag_offset = c.time - _t(event.position.x)
				key_selected.emit(c)
				queue_redraw()
			accept_event()
		else:
			if _drag and not is_equal_approx(_drag.time, _drag_from):
				key_moved.emit(_drag, _drag_from)
			_drag = null
			_scrubbing = false
	elif event is InputEventMouseMotion:
		if _scrubbing:
			_set_time(_t(event.position.x))
		elif _drag:
			var t := _t(event.position.x) + _drag_offset
			_drag.time = clampf(t if event.shift_pressed else snappedf(t, 0.1), 0.0, cutscene.length)
			queue_redraw()


func _set_time(t: float) -> void:
	time = snappedf(t, 0.05)
	time_changed.emit(time)
	queue_redraw()
