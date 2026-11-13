extends Node
## Renders the 3D scene at about the same number of lines on every screen (project setting
## n64/render/target_lines: 900 matches MSAA 2x at 0.5 on a Retina MacBook; 540 is softer,
## 360 close to the N64's own), stretched to the window with bilinear filtering: the
## soft, low-resolution N64 picture looks the same on a laptop, a Retina display or a 4K TV
## instead of depending on the window's pixel count. The HUD stays at full resolution.
## Re-applied whenever the window changes size.
## Also puts the N64 video output (N64VideoOut, settings in VIDEO_OUT) on whichever camera is
## current (player, cutscenes), unless that camera has a compositor of its own.

const SETTING := "n64/render/target_lines"
const DEFAULT_LINES := 900
const VIDEO_OUT := "res://game/video_out.tres"

var _compositor: Compositor
var _screen_tween: Tween
var _scene_mix := {}  # ScreenLook -> weight: the place's (Zone sets it each frame)
var _forced_look: ScreenLook  # a cutscene's
var _forced := false
var _look_mix := {}  # ScreenLook -> weight shown now (eases towards the target)
var _override_secs := -1.0  # a force / release's own blend time, while it runs
var _override_left := 0.0


func _ready() -> void:
	get_window().size_changed.connect(_apply)
	_apply()
	var effect := load(VIDEO_OUT) as CompositorEffect if ResourceLoader.exists(VIDEO_OUT) else null
	if effect:
		_compositor = Compositor.new()
		_compositor.compositor_effects = [effect]


## Majora's Mask style screen filters, blended over `seconds`: `grade` towards grey x `tint`
## (white = grey, warm = sepia), `echo` the share of last frame kept (its cutscene blur, ~0.7).
## Back to normal: screen_to(0, Color.WHITE, 0, seconds), or screen_clear().
func screen_to(grade: float, tint: Color, echo: float, seconds: float) -> void:
	var e := video_out()
	if e == null:
		return
	if _screen_tween:
		_screen_tween.kill()
	if seconds <= 0.0:
		e.set(&"grade", grade)
		e.set(&"grade_tint", tint)
		e.set(&"echo", echo)
		return
	_screen_tween = create_tween().set_parallel()
	_screen_tween.tween_property(e, ^"grade", grade, seconds)
	_screen_tween.tween_property(e, ^"grade_tint", tint, seconds)
	_screen_tween.tween_property(e, ^"echo", echo, seconds)


func screen_clear(seconds := 0.5) -> void:
	screen_to(0.0, Color.WHITE, 0.0, seconds)


## The place's screen looks (Zone, every frame): {ScreenLook: weight} (weights sum to at
## most 1; less = the plain picture shows through). Changes ease in over each look's
## blend_time, so time-of-day keys, weather changes and walking between rooms crossfade.
func set_scene_mix(mix: Dictionary) -> void:
	_scene_mix = mix


func set_scene_look(look: ScreenLook) -> void:
	set_scene_mix({look: 1.0} if look else {})


## A cutscene's look, over the place's until release_look().
func force_look(look: ScreenLook, seconds := -1.0) -> void:
	_forced = true
	_forced_look = look
	_override(seconds if seconds >= 0.0 else (look.blend_time if look else 1.0))


func release_look(seconds := -1.0) -> void:
	if not _forced:
		return
	_forced = false
	_forced_look = null
	_override(seconds if seconds >= 0.0 else 1.0)


func _override(seconds: float) -> void:
	_override_secs = seconds
	_override_left = seconds


func _ease_looks(delta: float) -> void:
	var target := ({_forced_look: 1.0} if _forced_look else {}) if _forced else _scene_mix
	var keys := {}
	for k in target:
		keys[k] = true
	for k in _look_mix:
		keys[k] = true
	if _override_left > 0.0:
		_override_left -= delta
	for look: ScreenLook in keys:
		if look == null:
			continue
		var secs := _override_secs if _override_left > 0.0 else look.blend_time
		var step := delta / maxf(secs, 0.001)
		var w := move_toward(float(_look_mix.get(look, 0.0)), float(target.get(look, 0.0)), step)
		if w <= 0.0005 and not target.has(look):
			_look_mix.erase(look)
		else:
			_look_mix[look] = w
	var e := video_out()
	if e:
		var entries := []
		for look: ScreenLook in _look_mix:
			entries.append([look, _look_mix[look] * look.strength])
		entries.sort_custom(func(a, b): return a[1] > b[1])
		e.call(&"set_looks", entries.slice(0, 4))


## The N64VideoOut on the cameras (null without one).
func video_out() -> CompositorEffect:
	return _compositor.compositor_effects[0] if _compositor and not _compositor.compositor_effects.is_empty() else null


## Debug (F1 in the debug HUD): steps off -> greyscale -> 3 value groups -> 5 -> off, to
## judge how a place reads by light and dark.
var _value_mode := 0


func toggle_value_view() -> void:
	var e := video_out()
	if e == null:
		return
	_value_mode = (_value_mode + 1) % 4
	var steps: int = [0, 0, 3, 5][_value_mode]
	screen_to(1.0 if _value_mode > 0 else 0.0, Color.WHITE, float(e.get(&"echo")), 0.0)
	e.set(&"value_steps", steps)
	print("[RenderScale] value view ", ["off", "greyscale", "3 value groups", "5 value groups"][_value_mode])


## Debug (F12 in the debug HUD): the video output on / off, to compare in game.
func toggle_video_out() -> void:
	if _compositor == null:
		return
	for e: CompositorEffect in _compositor.compositor_effects:
		e.enabled = not e.enabled
		print("[RenderScale] N64 video output ", "on" if e.enabled else "off")


func _process(delta: float) -> void:
	_ease_looks(delta)
	var cam := get_viewport().get_camera_3d()
	if cam and cam.compositor == null and _compositor:
		cam.compositor = _compositor


func _apply() -> void:
	var vp := get_viewport()
	var lines := float(ProjectSettings.get_setting(SETTING, DEFAULT_LINES))
	var height := float(get_window().size.y)
	if lines <= 0.0 or height <= 0.0:
		vp.scaling_3d_scale = 1.0
		return
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = clampf(lines / height, 0.1, 1.0)
