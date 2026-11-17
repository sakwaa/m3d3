extends Node
## Renders the 3D scene at about the same number of lines on every screen (project setting
## n64/render/target_lines: 900 matches MSAA 2x at 0.5 on a Retina MacBook; 540 is softer,
## 360 close to the N64's own), stretched to the window with bilinear filtering: the
## soft, low-resolution N64 picture looks the same on a laptop, a Retina display or a 4K TV
## instead of depending on the window's pixel count. The HUD stays at full resolution.
## Re-applied whenever the window changes size.
## Edge-aware upscale (project setting n64/render/edge_upscale, default off): instead of the
## bilinear stretch, the picture is enlarged by N64VideoOut's edge-aware upscale (texels as
## blocks, polygon silhouettes redrawn where the coverage says they run) and shown on a
## full-window layer under every other canvas layer. Off, or without the video output: bilinear.
## Also puts the N64 video output (N64VideoOut, settings in VIDEO_OUT) on whichever camera is
## current (player, cutscenes), unless that camera has a compositor of its own.

const SETTING := "n64/render/target_lines"
const DEFAULT_LINES := 720
const UPSCALE_SETTING := "n64/render/edge_upscale"
## Round the render to a whole number of window pixels per line (target_lines the nearest).
const INTEGER_SETTING := "n64/render/integer_scale"
const VIDEO_OUT := "res://game/video_out.tres"

var _compositor: Compositor
var _screen_tween: Tween
var _scene_mix := {}  # ScreenLook -> weight: the place's (Zone sets it each frame)
var _forced_look: ScreenLook  # a cutscene's
var _forced := false
var _look_mix := {}  # ScreenLook -> weight shown now (eases towards the target)
var _override_secs := -1.0  # a force / release's own blend time, while it runs
var _override_left := 0.0
## The HUD through the N64 video output (video_hud()): drawn at the 3D render's size into the
## framebuffer, so it's dithered and VI-softened with the picture, as on the N64. Off (or
## with the video output off) layers draw normally, sharp at full resolution.
var hud_through_video := true:
	set(v):
		hud_through_video = v
		_route_hud()
var _hud_vp: SubViewport
var _up_layer: CanvasLayer
var _up_rect: TextureRect
var _up_tex: Texture2DRD
var _up_info: Texture2DRD
var _up_mat: ShaderMaterial
var _hud_layers: Array[CanvasLayer] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # (the pause backdrop follows the pause)
	# (ScreenDistortion's global, in case project.godot lost it: listing the globals is
	# editor-only, so check the setting)
	if not ProjectSettings.has_setting("shader_globals/n64_distort"):
		RenderingServer.global_shader_parameter_add(&"n64_distort", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(1, 0, 0, 1))
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


var _frame_tween: Tween


## A framebuffer transition (OoT / MM): the picture now is copied, then carried away by
## `warp` (N64VideoOut.Warp: 0 crossfade, 1 spin-zoom, 2 ripple) over `seconds` while the
## new view shows through. Call it, then change the scene / camera.
func transition(warp: int, seconds := 1.0) -> void:
	var e := video_out()
	if e == null:
		return
	if _frame_tween:
		_frame_tween.kill()
	e.call(&"take_snapshot")
	e.set(&"snapshot_soften", 0)
	e.set(&"snapshot_dim", 0.0)
	e.set(&"snapshot_warp", warp)
	e.set(&"snapshot_warp_amount", 0.0)
	e.set(&"snapshot_show", 1.0)
	_frame_tween = create_tween().set_parallel().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_frame_tween.tween_property(e, ^"snapshot_warp_amount", 1.0, seconds)
	_frame_tween.tween_property(e, ^"snapshot_show", 0.0, seconds).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)


## Warps between places (ZoneManager.travel's `warp`): hold_snapshot() freezes the picture
## now (the old place stays on screen while the next loads); release_snapshot() carries it
## away (`warp`: N64VideoOut.Warp) over `seconds`, the new place showing through.
func hold_snapshot() -> void:
	var e := video_out()
	if e == null:
		return
	if _frame_tween:
		_frame_tween.kill()
	e.set(&"snapshot_soften", 0)
	e.set(&"snapshot_dim", 0.0)
	e.set(&"snapshot_warp", 0)
	e.set(&"snapshot_warp_amount", 0.0)
	e.call(&"take_snapshot")
	e.set(&"snapshot_show", 1.0)


func release_snapshot(warp: int, seconds := 1.0) -> void:
	var e := video_out()
	if e == null:
		return
	if _frame_tween:
		_frame_tween.kill()
	e.set(&"snapshot_warp", warp)
	_frame_tween = create_tween().set_parallel().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_frame_tween.tween_property(e, ^"snapshot_warp_amount", 1.0, seconds)
	_frame_tween.tween_property(e, ^"snapshot_show", 0.0, seconds).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)


## Holds a softened, dimmed copy of the picture (OoT's pause background) while `on`; the
## live 3D picture is hidden behind it (pause the game tree while held).
func freeze_frame(on: bool, soften := 4, dim := 0.35, seconds := 0.2) -> void:
	var e := video_out()
	if e == null:
		return
	if _frame_tween:
		_frame_tween.kill()
	if on:
		e.set(&"snapshot_soften", soften)
		e.set(&"snapshot_dim", dim)
		e.set(&"snapshot_warp", 0)
		e.call(&"take_snapshot")
	_frame_tween = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_frame_tween.tween_property(e, ^"snapshot_show", 1.0 if on else 0.0, seconds)


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
	_route_hud()


## Draws `layer` (the game HUD: meters, target marks, dialogue) through the N64 video output.
## Debug overlays and full-screen fades stay out (sharp, on top).
func video_hud(layer: CanvasLayer) -> void:
	for i in range(_hud_layers.size() - 1, -1, -1):
		if not is_instance_valid(_hud_layers[i]):
			_hud_layers.remove_at(i)
	if not layer in _hud_layers:
		_hud_layers.append(layer)
	_route_hud()


func _route_hud() -> void:
	var e := video_out()
	var on := hud_through_video and e != null and e.enabled
	if on and _hud_vp == null:
		_hud_vp = SubViewport.new()
		_hud_vp.name = "VideoHud"
		_hud_vp.transparent_bg = true
		_hud_vp.disable_3d = true
		_hud_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_hud_vp.size_2d_override_stretch = true
		# Pixel-exact 2D like the RDP's copy mode (HUD sprites blitted, never filtered).
		_hud_vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
		add_child(_hud_vp)
		_size_hud()
	var target: Viewport = _hud_vp if on else null
	for l in _hud_layers:
		if is_instance_valid(l) and l.custom_viewport != target:
			# Set out of the tree: changing it on a layer inside the tree trips an engine error
			# (it disconnects a parent signal it never connected).
			var parent := l.get_parent()
			var at := l.get_index()
			if parent:
				parent.remove_child(l)
			l.custom_viewport = target
			if parent:
				parent.add_child(l)
				parent.move_child(l, at)
	if e:
		e.set(&"hud_texture", _hud_vp.get_texture().get_rid() if on else RID())


## The HUD viewport: the 3D render's pixel size, laid out in the window's canvas size.
func _size_hud() -> void:
	if _hud_vp == null:
		return
	var vp := get_viewport()
	var px := Vector2(get_window().size) * vp.scaling_3d_scale
	_hud_vp.size = Vector2i(maxi(int(px.x), 1), maxi(int(px.y), 1))
	_hud_vp.size_2d_override = Vector2i(vp.get_visible_rect().size)


## While the game is paused (get_tree().paused), the picture is held as OoT's pause
## background: softened and dimmed (freeze_frame). Off: plain pause.
var pause_backdrop := true
var _was_paused := false


func _process(delta: float) -> void:
	var paused := get_tree().paused
	if paused != _was_paused and pause_backdrop:
		_was_paused = paused
		freeze_frame(paused)
	_ease_looks(delta)
	_show_upscale()
	if not paused:
		var vs := get_viewport().get_visible_rect().size
		ScreenDistortion.update(delta, vs.x / maxf(vs.y, 1.0))
	var cam := get_viewport().get_camera_3d()
	if cam and cam.compositor == null and _compositor:
		cam.compositor = _compositor


func _apply() -> void:
	var vp := get_viewport()
	# Apple GPUs (Metal): MSAA 8x isn't real there (4x samples) and Godot's resolved depth
	# breaks at 8x - depth-reading effects (the passages' darkness) cover their surroundings.
	# 4x gives the same coverage AA.
	if vp.msaa_3d == Viewport.MSAA_8X and RenderingServer.get_video_adapter_vendor().contains("Apple"):
		vp.msaa_3d = Viewport.MSAA_4X
		push_warning("RenderScale: MSAA 8x isn't supported on this GPU; using 4x.")
	var lines := float(ProjectSettings.get_setting(SETTING, DEFAULT_LINES))
	var height := float(get_window().size.y)
	if lines <= 0.0 or height <= 0.0:
		vp.scaling_3d_scale = 1.0
		return
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	if bool(ProjectSettings.get_setting(INTEGER_SETTING, false)):
		# A whole number of window pixels per rendered line (the nearest to the target): a
		# fractional stretch spreads lines unevenly, and they crawl as the camera moves.
		var factor := maxf(roundf(height / lines), 1.0)
		vp.scaling_3d_scale = clampf(1.0 / factor, 0.1, 1.0)
	else:
		vp.scaling_3d_scale = clampf(lines / height, 0.1, 1.0)
	_size_hud()


## Shows N64VideoOut's upscaled picture over Godot's bilinear stretch (a full-window layer
## under every other canvas layer: debug overlays and fades stay on top). Hidden whenever the
## video output or the upscale is off, so the plain stretch shows.
func _show_upscale() -> void:
	var e := video_out()
	if e:
		# Render size -> window size exactly (any factor; from the scale in use now).
		var vp := get_viewport()
		var height := float(get_window().size.y)
		var up_on := bool(ProjectSettings.get_setting(UPSCALE_SETTING, false)) and vp.scaling_3d_scale < 0.999
		var rows := maxi(roundi(height * vp.scaling_3d_scale), 1)
		var f := height / float(rows) if up_on else 0.0
		if not is_equal_approx(float(e.get(&"edge_upscale")), f):
			e.set(&"edge_upscale", f)
	# On screen (N64VideoOut.upscale_screen): the render-size picture + edge info, enlarged by
	# the layer's shader; otherwise the full-size upscaled picture, copied.
	var screen: bool = e != null and bool(e.get(&"upscale_screen"))
	var rid: RID = (e.get(&"upscale_src_rid") if screen else e.get(&"upscaled_rid")) if e else RID()
	var on := e != null and e.enabled and float(e.get(&"edge_upscale")) > 1.0 and rid.is_valid() \
		and get_viewport().get_camera_3d() != null
	if not on:
		if _up_layer:
			_up_layer.visible = false
		return
	if _up_layer == null:
		_up_layer = CanvasLayer.new()
		_up_layer.name = "EdgeUpscale"
		_up_layer.layer = -128
		_up_rect = TextureRect.new()
		_up_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_up_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_up_rect.stretch_mode = TextureRect.STRETCH_SCALE
		_up_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_up_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_up_mat = ShaderMaterial.new()
		_up_mat.shader = preload("res://addons/n64_runtime/post/n64_upscale_layer.gdshader")
		_up_rect.material = _up_mat
		_up_tex = Texture2DRD.new()
		_up_info = Texture2DRD.new()
		_up_rect.texture = _up_tex
		_up_mat.set_shader_parameter(&"info_tex", _up_info)
		_up_layer.add_child(_up_rect)
		add_child(_up_layer)
	if _up_tex.texture_rd_rid != rid:
		_up_tex.texture_rd_rid = rid
	if screen:
		var info: RID = e.get(&"upscale_info_rid")
		if _up_info.texture_rd_rid != info:
			_up_info.texture_rd_rid = info
		_up_mat.set_shader_parameter(&"mode", 1 if bool(e.get(&"upscale_edge_live")) else 0)
		_up_mat.set_shader_parameter(&"src_size", Vector2(_up_tex.get_size()))
		_up_mat.set_shader_parameter(&"factor", float(e.get(&"edge_upscale")))
		_up_mat.set_shader_parameter(&"show_edges", bool(e.get(&"upscale_show")))
	else:
		_up_mat.set_shader_parameter(&"mode", -1)
	_up_layer.visible = true
