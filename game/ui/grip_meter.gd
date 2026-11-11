class_name GripMeter
extends Control
## SotC-style grip ring in the lower right: shown while climbing and refilling, fades out
## once full on the ground. Grows a little with each upgrade segment (ticks mark them);
## flashes when nearly empty.

const FULL := Color(0.95, 0.42, 0.62)
const LOW := Color(1.0, 0.2, 0.15)
const BACK := Color(0.05, 0.03, 0.06, 0.55)
const EDGE := Color(1.0, 0.95, 0.9, 0.85)
## Seconds the ring stays after filling up.
const LINGER := 0.8

var grip: Grip
var _alpha := 0.0
var _full_for := 0.0
var _t := 0.0


func _init(p_grip: Grip) -> void:
	grip = p_grip
	name = "GripMeter"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_t += delta
	var show := grip.in_use() or not grip.is_full()
	_full_for = 0.0 if show else _full_for + delta
	var target := 1.0 if show or _full_for < LINGER else 0.0
	_alpha = move_toward(_alpha, target, delta * (6.0 if target > _alpha else 2.5))
	queue_redraw()


func _draw() -> void:
	if _alpha <= 0.01:
		return
	var s := get_viewport_rect().size.y / 1080.0
	var r := (38.0 + 5.0 * grip.segments()) * s
	var w := 14.0 * s
	var center := get_viewport_rect().size - Vector2(80.0, 80.0) * s - Vector2(r, r)
	var ratio := grip.ratio()
	var col := FULL
	if ratio < 0.25:
		col = FULL.lerp(LOW, 0.5 + 0.5 * sin(_t * 14.0))
	col.a *= _alpha
	var back := BACK
	back.a *= _alpha
	var edge := EDGE
	edge.a *= _alpha
	draw_arc(center, r, 0.0, TAU, 48, back, w + 4.0 * s)
	if ratio > 0.0:
		draw_arc(center, r, -PI * 0.5, -PI * 0.5 + TAU * ratio, maxi(int(48 * ratio), 2), col, w)
	draw_arc(center, r + w * 0.5 + s, 0.0, TAU, 48, edge, 2.0 * s)
	draw_arc(center, r - w * 0.5 - s, 0.0, TAU, 48, edge, 2.0 * s)
	# Ticks between the base grip and each upgrade segment.
	var total := grip.max_value()
	for i in grip.segments():
		var a := -PI * 0.5 + TAU * (grip.base + grip.per_segment * i) / total
		var dir := Vector2(cos(a), sin(a))
		draw_line(center + dir * (r - w * 0.5), center + dir * (r + w * 0.5), edge, 2.0 * s)
