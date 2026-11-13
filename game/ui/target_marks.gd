class_name TargetMarks
extends Control
## Z-targeting marks, after MM (references/targeting/z_targeting_spec.md 4): the arrow
## spinning over what Z would lock (the next target while locked), and the lock reticle -
## four triangles that fly in from the middle of the screen onto the target (5 MM frames,
## radius 500 -> 80 with three trailing copies), pop out to 120 and spin; letting go they
## spread out and fade. Colours by kind (NPC blue, enemy yellow, the rest green). Sizes are
## MM's 320x240 screen pixels, scaled to the viewport. Plays lock_on / lock_on_human /
## lock_off (Sfx).

const FPS := 20.0
## Degrees per MM frame: reticle spin, arrow spin.
const SPIN := 8.44
const ARROW_SPIN := 16.5
## Seconds the arrow takes to move to a new target (Tatl's 3 frames).
const ARROW_MOVE := 0.15
## Arrow above the target's focus (metres).
const ARROW_UP := 0.6

var lock: TargetLock
## Says whether the camera is Z-targeting (letterbox), e.g. CameraDirector.z_targeting.
var letterboxed: Callable

## Letterbox bars while Z-targeting (MM's medium: 27 of 240 lines each), easing in / out.
const BARS := 27.0 / 240.0
const BARS_TIME := 0.25
var _bars := 0.0

var _target: Targetable
var _color := Color.WHITE
var _r := 500.0  # reticle radius (MM px)
var _fly := false
var _spinning := false
var _out := false
var _fade := 0.0
var _angle := 0.0
var _anchor := Vector3.ZERO
var _trail: Array = []  # [radius, screen position] of the last frames during the fly-in
var _frames := 0.0
var _arrow_t: Targetable
var _arrow_from := Vector3.ZERO
var _arrow_k := 1.0
var _arrow_angle := 0.0


func _init(p_lock: TargetLock) -> void:
	lock = p_lock
	name = "TargetMarks"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_frames += delta * FPS
	var boxed: bool = letterboxed.is_valid() and letterboxed.call()
	_bars = move_toward(_bars, 1.0 if boxed else 0.0, delta / BARS_TIME)
	var on: Targetable = lock.target if lock.active() else null
	if on != _target and on != null:
		_target = on
		_color = on.color()
		_r = 500.0
		_fly = true
		_spinning = false
		_out = false
		_fade = 256.0
		_trail.clear()
		Sfx.play(&"lock_on" if on.is_hostile() else &"lock_on_human", on.global_position)
	elif on == null and _target != null and not _out:
		_out = true
		_fly = false
		if _spinning:
			Sfx.play(&"lock_off", _anchor)
	if _target and is_instance_valid(_target) and not _out:
		_anchor = _target.global_position
	while _frames >= 1.0:
		_frames -= 1.0
		_tick()
	_arrow(delta)
	queue_redraw()


## One MM frame of the reticle.
func _tick() -> void:
	_arrow_angle += ARROW_SPIN
	if _target == null:
		return
	if _fly:
		_trail.push_front([_r, _screen_pos()])
		if _trail.size() > 3:
			_trail.pop_back()
		_r = maxf(_r - clampf((500.0 - _r) * 3.0, 30.0, 100.0), 80.0)
		if _r <= 80.0:
			_r = 120.0
			_fly = false
			_spinning = true
			_trail.clear()
	elif _out:
		_r += 80.0
		_fade -= 120.0
		if _fade <= 0.0:
			_target = null
			_out = false
	if _spinning:
		_angle += SPIN


func _arrow(delta: float) -> void:
	var h: Targetable = lock.hover
	if h and h.lock_disabled:
		h = null
	if h != _arrow_t:
		_arrow_from = _arrow_pos() if _arrow_t and is_instance_valid(_arrow_t) else (h.global_position if h else Vector3.ZERO)
		_arrow_t = h
		_arrow_k = 0.0
	_arrow_k = minf(_arrow_k + delta / ARROW_MOVE, 1.0)


func _arrow_pos() -> Vector3:
	var to := _arrow_t.global_position + Vector3.UP * ARROW_UP
	return _arrow_from.lerp(to, _arrow_k) if _arrow_k < 1.0 else to


func _cam() -> Camera3D:
	return get_viewport().get_camera_3d()


## Where the reticle is on screen: flying in, from the middle out to the target as it shrinks.
func _screen_pos() -> Vector2:
	var cam := _cam()
	var mid := get_viewport_rect().size * 0.5
	if cam == null or cam.is_position_behind(_anchor):
		return mid
	var p := cam.unproject_position(_anchor)
	return mid + (p - mid) * clampf((500.0 - _r) / 420.0, 0.0, 1.0) if _fly else p


func _draw() -> void:
	var px := get_viewport_rect().size.y / 240.0  # MM pixel
	if _bars > 0.0:
		var size := get_viewport_rect().size
		var h := size.y * BARS * smoothstep(0.0, 1.0, _bars)
		draw_rect(Rect2(0, 0, size.x, h), Color.BLACK)
		draw_rect(Rect2(0, size.y - h, size.x, h), Color.BLACK)
	var cam := _cam()
	if _arrow_t and is_instance_valid(_arrow_t) and cam:
		var at := _arrow_pos()
		if not cam.is_position_behind(at):
			var c := _arrow_t.color()
			var p := cam.unproject_position(at)
			var w := 6.0 * px * cos(deg_to_rad(_arrow_angle))  # spinning: seen edge-on twice a turn
			var hgt := 9.0 * px
			var pts := PackedVector2Array([p + Vector2(-w, -hgt), p + Vector2(w, -hgt), p])
			if absf(w) > 0.3:
				draw_colored_polygon(pts, c)
				draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[0]]), c.darkened(0.5), maxf(px * 0.5, 1.0))
	if _target == null:
		return
	var alpha := clampf(_fade / 256.0, 0.0, 1.0)
	for i in range(_trail.size() - 1, -1, -1):
		_reticle(_trail[i][1], _trail[i][0], alpha * (1.0 - 0.33 * (i + 1)), px)
	_reticle(_screen_pos(), _r, alpha, px)


## Four triangles round `at`, `r` MM px out, pointing in; stretched sideways while far out.
func _reticle(at: Vector2, r: float, alpha: float, px: float) -> void:
	if alpha <= 0.0:
		return
	var c := Color(_color, alpha)
	var edge := Color(_color.darkened(0.6), alpha)
	var stretch := 1.0 + maxf(r - 120.0, 0.0) * 0.0067  # (MM: 0.15 + (r - 120) * 0.001 over 0.15)
	var d := r * 0.12 * px  # (MM's radius is in its own scaled units)
	for k in 4:
		var rot := deg_to_rad(_angle + 90.0 * k + 45.0)
		var dir := Vector2(cos(rot), sin(rot))
		var side := dir.orthogonal()
		var tip := at + dir * d
		var back := tip + dir * 7.0 * px
		var pts := PackedVector2Array([tip, back + side * 4.5 * px * stretch, back - side * 4.5 * px * stretch])
		draw_colored_polygon(pts, c)
		draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[0]]), edge, maxf(px * 0.5, 1.0))
