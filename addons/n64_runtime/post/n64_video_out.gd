@tool
class_name N64VideoOut
extends CompositorEffect
## The N64's video output on the 3D image (not the TV): 16-bit colour with the RDP's ordered
## dither, the VI's dither filter smoothing most of it back out, the VI's softer-along-the-line
## picture, and optionally composite video's colour bleed. Plus, while in use, Majora's Mask's
## screen filters: an echo (its cutscene motion blur) and a grade (grey / tinted), and a
## colour-blind correction. Small compute passes at the internal render size (RenderScale's
## lines), before the upscale and the HUD. Attached to the current camera by RenderScale
## (which also blends the echo / grade over time: RenderScale.screen_to); settings in
## res://game/video_out.tres.

const DITHER_SHADER := preload("res://addons/n64_runtime/post/n64_video_dither.glsl")
const SOFT_SHADER := preload("res://addons/n64_runtime/post/n64_video_soft.glsl")
const CONTEXT := &"n64_video_out"
const TEMP := &"temp"
const HISTORY := [&"history_a", &"history_b"]
const GRADE_SHADER := preload("res://addons/n64_runtime/post/n64_video_grade.glsl")

enum ColourVision { NORMAL, PROTANOPIA, DEUTERANOPIA, TRITANOPIA }

## Colour-blind simulation matrices (Machado et al. 2009, full severity, linear RGB).
const _SIM := {
	ColourVision.PROTANOPIA: [Vector3(0.152286, 1.052583, -0.204868), Vector3(0.114503, 0.786281, 0.099216), Vector3(-0.003882, -0.048116, 1.051998)],
	ColourVision.DEUTERANOPIA: [Vector3(0.367322, 0.860646, -0.227968), Vector3(0.280085, 0.672501, 0.047413), Vector3(-0.01182, 0.04294, 0.968881)],
	ColourVision.TRITANOPIA: [Vector3(1.255528, -0.076749, -0.178779), Vector3(-0.078411, 0.930809, 0.147602), Vector3(0.004733, 0.691367, 0.3039)],
}

## 16-bit colour (5 bits a channel), as the N64's framebuffer.
@export var color_16bit := true
## The ordered dither's strength (1 = the N64's 4x4 magic square; 0 = plain rounding).
@export_range(0.0, 1.0, 0.05) var dither := 1.0
## The video chip's dither filter: how much of the dither it smooths back out.
@export_range(0.0, 1.0, 0.05) var dedither := 1.0
## Softer along the line than across it (the VI stretching ~320 pixels to the screen).
@export_range(0.0, 1.0, 0.05) var horizontal_soft := 0.5
## Composite video: colour smeared along the line, brightness kept sharp.
@export_range(0.0, 1.0, 0.05) var composite_bleed := 0.0
@export_group("Screen filters")
## Echo (Majora's Mask's cutscene blur): share of last frame kept over this one; older frames
## fade out on their own. Usually blended in and out by RenderScale.screen_to.
@export_range(0.0, 0.95, 0.05) var echo := 0.0
## Pictures the echo takes a second (Majora's Mask ran at 20): fewer, further-apart ghosts
## instead of a strobe of one per frame.
@export_range(5.0, 60.0, 1.0, "suffix:/s") var echo_rate := 20.0
## How far (pixels at the render size) the echo's picture blurs each time it's taken: older
## ghosts melt together.
@export_range(0, 10) var echo_soften := 6
## Grade: how far towards grey x `grade_tint` (white = grey, warm = sepia).
@export_range(0.0, 1.0, 0.05) var grade := 0.0
@export var grade_tint := Color.WHITE
## Colour-blind correction (daltonising: what that eye loses shifted into what it sees).
@export var colour_vision := ColourVision.NORMAL
## Value groups (value view): the picture's light in this many flat greys (0 = off; 3 or 5
## for the squint test: which shapes share a value).
@export_range(0, 8) var value_steps := 0
@export_group("")

## Screen looks: up to SLOTS looks blended by weight (RenderScale.set_looks keeps them).
const SLOTS := 4

var _rd: RenderingDevice
var _dither_shader: RID
var _dither_pipe: RID
var _soft_shader: RID
var _soft_pipe: RID
var _grade_shader: RID
var _grade_pipe: RID
var _history_ok := false
var _hist := 0  # history buffer holding the last picture
var _next_take := 0
var _slot_look: Array = [null, null, null, null]  # ScreenLook per slot
var _slot_weight := PackedFloat32Array([0, 0, 0, 0])
var _look_img: Array = [null, null, null, null]  # [Image, n] baked on the main thread
var _look_ver := [0, 0, 0, 0]
var _look_tex: Array[RID] = [RID(), RID(), RID(), RID()]
var _look_tex_ver := [-1, -1, -1, -1]
var _look_n := [1, 1, 1, 1]
var _look_mode := [0, 0, 0, 0]
var _look_dither := [0.0, 0.0, 0.0, 0.0]
var _dummy: RID
var _looks_ubo: RID


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	RenderingServer.call_on_render_thread(_setup)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd:
		for rid in _look_tex + [_dummy, _looks_ubo, _dither_shader, _soft_shader, _grade_shader]:  # (their pipelines go with them)
			if rid.is_valid():
				_rd.free_rid(rid)


func _setup() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return  # (Compatibility renderer: no compute)
	_dither_shader = _rd.shader_create_from_spirv(DITHER_SHADER.get_spirv())
	_dither_pipe = _rd.compute_pipeline_create(_dither_shader)
	_soft_shader = _rd.shader_create_from_spirv(SOFT_SHADER.get_spirv())
	_soft_pipe = _rd.compute_pipeline_create(_soft_shader)
	_grade_shader = _rd.shader_create_from_spirv(GRADE_SHADER.get_spirv())
	_grade_pipe = _rd.compute_pipeline_create(_grade_shader)
	var one := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	_dummy = _upload(one)
	_looks_ubo = _rd.uniform_buffer_create(64)


## The looks to show, as [[ScreenLook, weight]] (weights already include each look's
## strength; at most SLOTS used, sum at most 1). Looks keep their slot while they stay, so a
## look is only baked when it arrives.
func set_looks(entries: Array) -> void:
	var want := {}
	for e in entries:
		if e[0] and e[1] > 0.0005:
			want[e[0]] = want.get(e[0], 0.0) + float(e[1])
	for i in SLOTS:
		if _slot_look[i] and not want.has(_slot_look[i]):
			_slot_weight[i] = 0.0
	for look: ScreenLook in want:
		var slot := _slot_look.find(look)
		if slot < 0:
			for i in SLOTS:
				if _slot_look[i] == null or _slot_weight[i] <= 0.0:
					slot = i
					break
			if slot < 0:
				continue  # (more looks than slots: the faintest wait)
			_assign(slot, look)
		_slot_weight[slot] = want[look]


func _assign(slot: int, look: ScreenLook) -> void:
	var old: ScreenLook = _slot_look[slot]
	if old and old.changed.is_connected(_bake_look.bind(slot)):
		old.changed.disconnect(_bake_look.bind(slot))
	_slot_look[slot] = look
	if look:
		look.changed.connect(_bake_look.bind(slot))
	_bake_look(slot)


## Bakes slot `slot`'s look (main thread; the render thread uploads it).
func _bake_look(slot: int) -> void:
	var look: ScreenLook = _slot_look[slot]
	_look_mode[slot] = (look.mode + 1) if look else 0
	_look_dither[slot] = look.palette_dither if look else 0.0
	_look_img[slot] = look.bake() if look else null
	_look_ver[slot] += 1


func _upload(img: Image) -> RID:
	var f := RDTextureFormat.new()
	f.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	f.width = img.get_width()
	f.height = img.get_height()
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	return _rd.texture_create(f, RDTextureView.new(), [img.get_data()])


## The look slots' textures, uploaded when a slot's look changed.
func _sync_looks() -> void:
	for slot in SLOTS:
		if _look_tex_ver[slot] == _look_ver[slot]:
			continue
		_look_tex_ver[slot] = _look_ver[slot]
		if _look_tex[slot].is_valid():
			_rd.free_rid(_look_tex[slot])
			_look_tex[slot] = RID()
		var baked = _look_img[slot]
		if baked:
			_look_tex[slot] = _upload(baked[0])
			_look_n[slot] = baked[1]


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if _rd == null or callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or not _dither_pipe.is_valid():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	var look_sum := 0.0
	for i in SLOTS:
		if _look_mode[i] > 0:
			look_sum += _slot_weight[i]
	var filters: bool = echo > 0.0 or grade > 0.0 or colour_vision != ColourVision.NORMAL or look_sum > 0.001 or value_steps > 1
	if not color_16bit and horizontal_soft <= 0.0 and composite_bleed <= 0.0 and not filters:
		_history_ok = false
		return
	if not buffers.has_texture(CONTEXT, TEMP):
		buffers.create_texture(CONTEXT, TEMP, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT,
			RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
	var groups := Vector3i(ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	var a := PackedFloat32Array([size.x, size.y, dither, dedither, 1.0 if color_16bit else 0.0, 0, 0, 0]).to_byte_array()
	var b := PackedFloat32Array([size.x, size.y, horizontal_soft, composite_bleed, 0, 0, 0, 0]).to_byte_array()
	var c := PackedByteArray()
	var take := false
	if filters:
		if not buffers.has_texture(CONTEXT, HISTORY[0]):
			for h in HISTORY:
				buffers.create_texture(CONTEXT, h, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
					RenderingDevice.TEXTURE_USAGE_STORAGE_BIT, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
			_history_ok = false  # (new or resized: nothing to echo yet)
		var now := Time.get_ticks_msec()
		take = not _history_ok or now >= _next_take
		if take:
			_next_take = now + int(1000.0 / maxf(echo_rate, 1.0))
		var t := grade_tint.srgb_to_linear()
		var m := colour_matrix(colour_vision)
		c = PackedFloat32Array([size.x, size.y, echo, grade, t.r, t.g, t.b, 1.0 if _history_ok else 0.0,
			m[0].x, m[0].y, m[0].z, 1.0 if take else 0.0, m[1].x, m[1].y, m[1].z, float(echo_soften),
			m[2].x, m[2].y, m[2].z, float(value_steps) if value_steps > 1 else 0.0]).to_byte_array()
		_sync_looks()
		var k := 1.0 / maxf(look_sum, 1.0)
		var ub := PackedFloat32Array()
		for i in SLOTS:
			ub.append_array([float(_look_mode[i]), _slot_weight[i] * k if _look_mode[i] > 0 else 0.0, float(_look_n[i]), _look_dither[i]])
		_rd.buffer_update(_looks_ubo, 0, 64, ub.to_byte_array())
	var video := color_16bit or horizontal_soft > 0.0 or composite_bleed > 0.0
	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view, false)
		if video:
			var temp := buffers.get_texture_slice(CONTEXT, TEMP, view, 0, 1, 1)
			_pass(_dither_shader, _dither_pipe, color, temp, a, groups)
			_pass(_soft_shader, _soft_pipe, temp, color, b, groups)
		if filters:
			_grade(color, buffers.get_texture_slice(CONTEXT, HISTORY[_hist], view, 0, 1, 1),
				buffers.get_texture_slice(CONTEXT, HISTORY[1 - _hist], view, 0, 1, 1), c, groups)
	if take:
		_hist = 1 - _hist
	# The echo needs an earlier picture: only kept while the filters run (MM's "setup frame").
	_history_ok = filters


func _grade(color: RID, hist_in: RID, hist_out: RID, params: PackedByteArray, groups: Vector3i) -> void:
	var us := []
	var ids := [color, hist_in, hist_out]
	for i in SLOTS:
		ids.append(_look_tex[i] if _look_tex[i].is_valid() else _dummy)
	for i in ids.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = i
		u.add_id(ids[i])
		us.append(u)
	var ubo := RDUniform.new()
	ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	ubo.binding = 7
	ubo.add_id(_looks_ubo)
	us.append(ubo)
	var set := UniformSetCacheRD.get_cache(_grade_shader, 0, us)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _grade_pipe)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_set_push_constant(list, params, params.size())
	_rd.compute_list_dispatch(list, groups.x, groups.y, groups.z)
	_rd.compute_list_end()


## Rows of the colour-blind correction for `vision` (identity for normal vision):
## c + ERR * (c - simulated(c)), what that eye loses moved into channels it still sees.
static func colour_matrix(vision: int) -> Array[Vector3]:
	var out: Array[Vector3] = [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]
	if not _SIM.has(vision):
		return out
	var sim: Array = _SIM[vision]
	var err := [Vector3(0, 0, 0), Vector3(0.7, 1, 0), Vector3(0.7, 0, 1)]
	for r in 3:
		for col in 3:
			var v := 0.0
			for k in 3:
				v += (err[r] as Vector3)[k] * ((1.0 if k == col else 0.0) - (sim[k] as Vector3)[col])
			out[r][col] += v
	return out


func _pass(shader: RID, pipe: RID, from: RID, to: RID, params: PackedByteArray, groups: Vector3i) -> void:
	var u_from := RDUniform.new()
	u_from.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_from.binding = 0
	u_from.add_id(from)
	var u_to := RDUniform.new()
	u_to.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_to.binding = 1
	u_to.add_id(to)
	var set := UniformSetCacheRD.get_cache(shader, 0, [u_from, u_to])
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, pipe)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_set_push_constant(list, params, params.size())
	_rd.compute_list_dispatch(list, groups.x, groups.y, groups.z)
	_rd.compute_list_end()
