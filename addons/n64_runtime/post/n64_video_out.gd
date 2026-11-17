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
const EDGE_SHADER := preload("res://addons/n64_runtime/post/n64_video_edge.glsl")
const COVERAGE_SHADER := preload("res://addons/n64_runtime/post/n64_video_coverage.glsl")
const TEMP2 := &"temp2"
const SEAM_FRONT := &"seam_front"  # (full size: front code, depth)
const SEAM_AO := &"seam_ao"  # (half size: contact shadow, depth)
const CONTEXT := &"n64_video_out"
const TEMP := &"temp"
const HISTORY := [&"history_a", &"history_b"]
const GRADE_SHADER := preload("res://addons/n64_runtime/post/n64_video_grade.glsl")
const FRAME_SHADER := preload("res://addons/n64_runtime/post/n64_video_frame.glsl")
const SNAP := &"snapshot"
const HUD_SHADER := preload("res://addons/n64_runtime/post/n64_video_hud.glsl")
const UPSCALE_SHADER := preload("res://addons/n64_runtime/post/n64_video_upscale.glsl")
const UPSCALE_SRC_SHADER := preload("res://addons/n64_runtime/post/n64_video_upscale_src.glsl")
const SEAM_SHADER := preload("res://addons/n64_runtime/post/n64_video_seam.glsl")
const DOWN_SHADER := preload("res://addons/n64_runtime/post/n64_video_down.glsl")
const COMBINE_SHADER := preload("res://addons/n64_runtime/post/n64_video_combine.glsl")
const TAPE_SHADER := preload("res://addons/n64_runtime/post/n64_video_tape.glsl")
const TAPE_PREP_SHADER := preload("res://addons/n64_runtime/post/n64_video_tape_prep.glsl")
const BLUR_LEVELS := [&"blur_half", &"blur_quarter", &"blur_eighth", &"blur_rows"]
## Rows of the screen combiner's smallest BLUR (Tharo's 40 x 30).
const BLUR_ROWS := 30

enum ColourVision { NORMAL, PROTANOPIA, DEUTERANOPIA, TRITANOPIA }

## Colour-blind simulation matrices (Machado et al. 2009, full severity, linear RGB).
const _SIM := {
	ColourVision.PROTANOPIA: [Vector3(0.152286, 1.052583, -0.204868), Vector3(0.114503, 0.786281, 0.099216), Vector3(-0.003882, -0.048116, 1.051998)],
	ColourVision.DEUTERANOPIA: [Vector3(0.367322, 0.860646, -0.227968), Vector3(0.280085, 0.672501, 0.047413), Vector3(-0.01182, 0.04294, 0.968881)],
	ColourVision.TRITANOPIA: [Vector3(1.255528, -0.076749, -0.178779), Vector3(-0.078411, 0.930809, 0.147602), Vector3(0.004733, 0.691367, 0.3039)],
}

## The VI's edge anti-aliasing (the N64's own): polygon edges (found from depth jumps)
## softened towards their neighbours, then the divot filter; textures left alone. 0 = off.
## Meant instead of MSAA (with it on, edges are already smooth).
@export_range(0.0, 1.0, 0.05) var edge_aa := 0.0
## Relative depth jump that counts as an edge (lower: more creases soften too).
@export_range(0.005, 0.5, 0.005) var edge_threshold := 0.04
@export var edge_divot := true
## Creases too (where surfaces meet at an angle with no jump in depth: a wall on the ground,
## a roof on its wall): the depth's relative second difference that counts. 0 = off.
@export_range(0.0, 0.05, 0.0005) var edge_crease := 0.002
## With MSAA on and our patched Godot (engine/README.md): real per-triangle coverage from
## the MSAA samples (the N64's own way) instead of edges guessed from depth; the picture
## isn't MSAA-averaged, the VI blend does the smoothing. Off: the depth-guessed edges.
@export var edge_coverage := true
## Debug: edges found shown in red.
@export var edge_show := false
## 16-bit colour (5 bits a channel), as the N64's framebuffer.
@export var color_16bit := true
## The RDP's dither pattern: the magic square (most games), Bayer, noise (a new pattern each
## frame: some games' fades and skies), or none (truncation).
enum DitherMode { MAGIC_SQUARE, BAYER, NOISE, NONE }
@export var dither_mode := DitherMode.MAGIC_SQUARE
## The ordered dither's strength (1 = the N64's 4x4 magic square; 0 = plain rounding).
@export_range(0.0, 1.0, 0.05) var dither := 1.0
## The video chip's dither filter: how much of the dither it smooths back out.
@export_range(0.0, 1.0, 0.05) var dedither := 1.0
## Softer along the line than across it (the VI stretching ~320 pixels to the screen).
@export_range(0.0, 1.0, 0.05) var horizontal_soft := 0.5
## Composite video: colour smeared along the line, brightness kept sharp.
@export_range(0.0, 1.0, 0.05) var composite_bleed := 0.0
## How wide the colour bleed is, in N64 pixels (320 across the picture; composite colour
## carried about a third of the brightness detail: ~1.5). 0: the old 5 render pixels.
@export_range(0.0, 6.0, 0.25) var chroma_width := 0.0
## A CRT's gamma (~2.5) instead of a modern screen's (2.2): darker, richer mid-tones, as N64
## art was seen on TVs. 1 = off; 2.5 / 2.2 = 1.14 matches a typical CRT.
@export_range(1.0, 1.4, 0.01) var crt_gamma := 1.0
## The VI's own gamma (VI_CTRL_GAMMA, a few games turned it on): the framebuffer's values
## raised by a square root on the way out - a much lighter, flatter picture for art made for it.
@export var vi_gamma := false
@export_group("Coverage extras")
## (These read the coverage tags: MSAA on, our patched Godot, edge_coverage.)
## Contact shadow ("seam dirt"): how dark it gets where another surface touches (an
## actor's feet on the ground, a crate's base, a post), from depth + coverage IDs. 0 = off.
@export_range(0.0, 1.0, 0.05) var seam_dirt := 0.0
## How far the contact shadow reaches (metres).
@export_range(0.05, 2.0, 0.05, "suffix:m") var seam_metres := 0.5
## Reach between two level surfaces (a wall's foot on the floor, a step, a foundation):
## longer, as seen low a short reach is only a pixel or two of floor.
@export_range(0.05, 3.0, 0.05, "suffix:m") var seam_level_metres := 2.0
## Level joints' share of the gain (soft, wide: a building's foot shades the ground gently).
@export_range(0.0, 2.0, 0.05) var seam_level_gain := 0.75
## How fast the contact shadow builds to full strength (higher: darker, wider dark core;
## seam_dirt then caps how dark full is).
@export_range(0.5, 10.0, 0.1) var seam_gain := 6.0
## Most pixels it may reach at the render size (close up, the reach is capped here).
@export_range(1, 128) var seam_radius := 96
## Debug: 1 the contact shadow alone (grey), 2 rebuilt view depth (4 m bands).
@export_range(0, 3) var seam_debug := 0
## Seam dirt only this near (metres; fades over the last third): far off the depth buffer
## can't tell touching from passing in front.
@export_range(5.0, 200.0, 1.0, "suffix:m") var seam_distance := 60.0
## Only contacts involving an object (actor, prop, tree, crate): seams between level brushes
## are left to the baked vertex AO (no double darkening), so this adds what the bake can't
## see - things that move or aren't part of the level.
@export var seam_objects_only := true
## Dither-faded objects (Actor.fade < 1: the RDP's dither) blended back into see-through.
@export var dither_resolve := false
## Object code to outline (64 + its object_id; -1 = none): a 1-pixel line inside its
## silhouette (targets, things to climb / grab).
@export var outline_code := -1
@export var outline_color := Color(1.0, 0.85, 0.35)
## 1: the outline is a flat colour; 0: the object's own colour times outline_color.
@export_range(0.0, 1.0, 0.05) var outline_flat := 1.0
@export_range(0.0, 1.0, 0.05) var outline_mix := 1.0
## Count each object's visible pixels (by object_id: visible_pixels()), read a frame late.
@export var count_visible := false
## Edge-aware upscale (0 = off): the picture enlarged this many times into upscaled_rid
## (any factor: e.g. window height / render lines), texels as blocks but polygon edges
## redrawn where they run (from the coverage).
@export_range(0.0, 8.0, 0.01) var edge_upscale := 0.0
## 0: plain nearest blocks (comparison); 1: edge-aware.
@export_range(0, 1) var upscale_mode := 1
@export var upscale_show := false
## On screen (RenderScale): only the picture and its edge info are kept (upscale_src_rid,
## upscale_info_rid, render size) and the screen layer's shader enlarges them straight to the
## window - one pass at window size. Off: the full-size upscaled_rid (captures, tests).
@export var upscale_screen := true
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
@export_group("Frame copy")
## Framebuffer copies (OoT / MM): take_snapshot() copies the 3D picture (before the HUD);
## this much of it is then drawn over the live picture (pause background, a held photo, the
## old place during a transition: RenderScale.transition()).
@export_range(0.0, 1.0, 0.01) var snapshot_show := 0.0
enum Warp { NONE, SPIN_ZOOM, RIPPLE }
## How the shown snapshot moves: Spin-zoom (MM's warps), Ripple (OoT's warp songs).
@export var snapshot_warp := Warp.NONE
## 0..1: how far the warp has run.
@export_range(0.0, 1.0, 0.01) var snapshot_warp_amount := 0.0
## Blur (pixels) when the snapshot is taken (OoT's soft pause background).
@export_range(0, 16) var snapshot_soften := 0
## Darkens the shown snapshot (pause background).
@export_range(0.0, 1.0, 0.05) var snapshot_dim := 0.0
@export_group("Tape")
## A vintage studio-video recording look (VideoTape: lens defocus, camera bloom and edge
## halos, tape colour smear); after the looks / combiners, before the HUD and the dither.
@export var tape: VideoTape:
	set(v):
		tape = v
		if tape and tape.uses_depth() and not access_resolved_depth:
			access_resolved_depth = true  # (the lens reads depth; stays on once asked)
@export_group("")

## Screen looks: up to SLOTS looks blended by weight (RenderScale.set_looks keeps them).
const SLOTS := 4
## Screen combiners (looks in Combiner mode) shown at once.
const COMBINER_SLOTS := 2

var _rd: RenderingDevice
var _dither_shader: RID
var _dither_pipe: RID
var _soft_shader: RID
var _soft_pipe: RID
var _edge_shader: RID
var _edge_pipe: RID
var _depth_sampler: RID
var _cov_shader: RID
var _cov_pipe: RID
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
var _frame_shader: RID
var _frame_pipe: RID
var _snap_request := false
var _hud_shader: RID
var _hud_pipe: RID
var _hud_sampler: RID
## RenderScale's HUD viewport texture (RenderingServer RID): drawn into the picture before the
## video passes (N64: the HUD was in the framebuffer, dithered and VI-filtered with the 3D).
var hud_texture := RID()
var _snap_ok := false
var _looks_ubo: RID
var _up_shader: RID
var _up_pipe: RID
var _ups_shader: RID
var _ups_pipe: RID
var _seam_shader: RID
var _seam_pipe: RID
var upscale_src_rid := RID()
var upscale_info_rid := RID()
var _ups_size := Vector2i.ZERO
var _counts: RID
var _counts_live := false
var _visible := PackedInt32Array()
## (the counts copied out each frame and read back without stalling: a request in flight at
## a time, so they're a frame or two late)
var _counts_read: RID
var _read_pending := false
## The edge-aware upscale's output (RenderingDevice texture; Texture2DRD to show it).
var upscaled_rid := RID()
var _up_size := Vector2i.ZERO
var _down_shader: RID
var _down_pipe: RID
var _comb_shader: RID
var _comb_pipe: RID
var _lin_sampler: RID
var _comb_ubo: RID
var _comb_data := PackedFloat32Array()  # the combiners' blocks (main thread -> render thread)
var _comb_count := 0
var _comb_depth := false
var _comb_bright := 0
var _tape_shader: RID
var _tape_pipe: RID
var _tprep_shader: RID
var _tprep_pipe: RID
var _up_retired := []  # [rid, frames left]: replaced upscale textures, freed once nothing draws them


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	RenderingServer.call_on_render_thread(_setup)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd:
		for rid in _look_tex + [_dummy, _looks_ubo, _dither_shader, _soft_shader, _grade_shader, _edge_shader, _cov_shader, _depth_sampler, _frame_shader, _hud_shader, _hud_sampler, _up_shader, _ups_shader, _seam_shader, _down_shader, _comb_shader, _tape_shader, _tprep_shader, _lin_sampler, _comb_ubo, _counts, _counts_read, upscaled_rid, upscale_src_rid, upscale_info_rid] + _up_retired.map(func(r): return r[0]):  # (their pipelines go with them)
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
	_edge_shader = _rd.shader_create_from_spirv(EDGE_SHADER.get_spirv())
	_edge_pipe = _rd.compute_pipeline_create(_edge_shader)
	_cov_shader = _rd.shader_create_from_spirv(COVERAGE_SHADER.get_spirv())
	_cov_pipe = _rd.compute_pipeline_create(_cov_shader)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_depth_sampler = _rd.sampler_create(ss)
	_grade_shader = _rd.shader_create_from_spirv(GRADE_SHADER.get_spirv())
	_grade_pipe = _rd.compute_pipeline_create(_grade_shader)
	_frame_shader = _rd.shader_create_from_spirv(FRAME_SHADER.get_spirv())
	_frame_pipe = _rd.compute_pipeline_create(_frame_shader)
	_hud_shader = _rd.shader_create_from_spirv(HUD_SHADER.get_spirv())
	_hud_pipe = _rd.compute_pipeline_create(_hud_shader)
	var hs := RDSamplerState.new()
	hs.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	hs.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_hud_sampler = _rd.sampler_create(hs)
	var one := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	_dummy = _upload(one)
	_looks_ubo = _rd.uniform_buffer_create(64)
	_up_shader = _rd.shader_create_from_spirv(UPSCALE_SHADER.get_spirv())
	_up_pipe = _rd.compute_pipeline_create(_up_shader)
	_ups_shader = _rd.shader_create_from_spirv(UPSCALE_SRC_SHADER.get_spirv())
	_ups_pipe = _rd.compute_pipeline_create(_ups_shader)
	_seam_shader = _rd.shader_create_from_spirv(SEAM_SHADER.get_spirv())
	_seam_pipe = _rd.compute_pipeline_create(_seam_shader)
	var zeros := PackedByteArray()
	zeros.resize(256)
	_counts = _rd.storage_buffer_create(256, zeros)
	_counts_read = _rd.storage_buffer_create(256, zeros)
	_down_shader = _rd.shader_create_from_spirv(DOWN_SHADER.get_spirv())
	_down_pipe = _rd.compute_pipeline_create(_down_shader)
	_comb_shader = _rd.shader_create_from_spirv(COMBINE_SHADER.get_spirv())
	_comb_pipe = _rd.compute_pipeline_create(_comb_shader)
	var ls := RDSamplerState.new()
	ls.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ls.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ls.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ls.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_lin_sampler = _rd.sampler_create(ls)
	_comb_ubo = _rd.uniform_buffer_create(COMBINER_SLOTS * 8 * 16)
	_tape_shader = _rd.shader_create_from_spirv(TAPE_SHADER.get_spirv())
	_tape_pipe = _rd.compute_pipeline_create(_tape_shader)
	_tprep_shader = _rd.shader_create_from_spirv(TAPE_PREP_SHADER.get_spirv())
	_tprep_pipe = _rd.compute_pipeline_create(_tprep_shader)


## The looks to show, as [[ScreenLook, weight]] (weights already include each look's
## strength; at most SLOTS used, sum at most 1). Looks keep their slot while they stay, so a
## look is only baked when it arrives.
func set_looks(entries: Array) -> void:
	var want := {}
	var combs := []  # [[ScreenCombiner, weight]]
	for e in entries:
		if e[0] and e[1] > 0.0005:
			if (e[0] as ScreenLook).mode == ScreenLook.Mode.COMBINER:
				if (e[0] as ScreenLook).combiner:
					combs.append([(e[0] as ScreenLook).combiner, float(e[1])])
				continue
			want[e[0]] = want.get(e[0], 0.0) + float(e[1])
	set_combiners(combs)
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


## The screen combiners to show, as [[ScreenCombiner, weight]] (the strongest COMBINER_SLOTS;
## weights summing to at most 1). Looks in Combiner mode come here through set_looks.
func set_combiners(entries: Array) -> void:
	entries = entries.duplicate()
	entries.sort_custom(func(a, b): return a[1] > b[1])
	var data := PackedFloat32Array()
	var depth := false
	var n := 0
	for e in entries.slice(0, COMBINER_SLOTS):
		var c: ScreenCombiner = e[0]
		data.append_array(c.pack(clampf(e[1], 0.0, 1.0)))
		depth = depth or c.uses(ScreenCombiner.Source.DEPTH) or c.uses(ScreenCombiner.Source.DEPTH_BANDS)
		n += 1
	data.resize(COMBINER_SLOTS * 32)
	# (one BLUR copy for both: its bright pass is the strongest combiner's)
	_comb_bright = int(data[28]) if n > 0 else 0
	_comb_data = data
	_comb_count = n
	_comb_depth = depth
	if depth and not access_resolved_depth:
		access_resolved_depth = true  # (DEPTH reads the resolved depth; stays on once asked)


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
	var edges := edge_aa > 0.0 or edge_show or seam_dirt > 0.0 or dither_resolve or outline_code >= 0 or count_visible or edge_upscale > 1.0
	var frame := _snap_request or (snapshot_show > 0.0 and _snap_ok)
	var combine := _comb_count > 0 and _comb_pipe.is_valid()
	var taping := tape != null and tape.strength > 0.0 and _tape_pipe.is_valid()
	var hud_rd := RenderingServer.texture_get_rd_texture(hud_texture) if hud_texture.is_valid() else RID()
	var hud := hud_rd.is_valid() and _rd.texture_is_valid(hud_rd)
	if crt_gamma <= 1.001 and not vi_gamma and not color_16bit and horizontal_soft <= 0.0 and composite_bleed <= 0.0 and not filters and not edges and not frame and not hud and not combine and not taping:
		_history_ok = false
		return
	if not buffers.has_texture(CONTEXT, TEMP):
		buffers.create_texture(CONTEXT, TEMP, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT,
			RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
	var groups := Vector3i(ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	var a := PackedFloat32Array([size.x, size.y, dither, dedither, 1.0 if color_16bit else 0.0, float(dither_mode),
		float(Engine.get_frames_drawn() % 65536), (crt_gamma * (0.5 if vi_gamma else 1.0)) if crt_gamma > 1.001 or vi_gamma else 0.0]).to_byte_array()
	var b := PackedFloat32Array([size.x, size.y, horizontal_soft, composite_bleed,
		chroma_width * size.x / 320.0, 0, 0, 0]).to_byte_array()
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
	var video := color_16bit or horizontal_soft > 0.0 or composite_bleed > 0.0 or crt_gamma > 1.001 or vi_gamma
	if edges and not buffers.has_texture(CONTEXT, TEMP2):
		buffers.create_texture(CONTEXT, TEMP2, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT,
			RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
	if edges and not buffers.has_texture(CONTEXT, SEAM_AO):
		buffers.create_texture(CONTEXT, SEAM_FRONT, RenderingDevice.DATA_FORMAT_R32G32_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
		buffers.create_texture(CONTEXT, SEAM_AO, RenderingDevice.DATA_FORMAT_R32G32_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT, RenderingDevice.TEXTURE_SAMPLES_1, (size + Vector2i.ONE) / 2, 1, 1, true, false)
	# Coverage AA: MSAA on and the engine patch present (the shaders write coverage).
	var samples: int = [1, 2, 4, 8][clampi(buffers.get_msaa_3d(), 0, 3)]
	var cov := edges and edge_coverage and samples > 1 and _engine_has_coverage()
	var e := PackedFloat32Array([size.x, size.y, edge_aa, edge_threshold, 1.0 if edge_divot else 0.0,
		1.0 if edge_show else 0.0, edge_crease, 1.0 if cov else 0.0]).to_byte_array()
	var up := edge_upscale > 1.0 and cov
	var oc := outline_color.srgb_to_linear()
	var cp := PackedFloat32Array([size.x, size.y, 0.0 if up else edge_aa, 1.0 if edge_divot else 0.0,
		1.0 if edge_show else 0.0, seam_dirt, float(seam_radius), 1.0 if dither_resolve else 0.0,
		float(outline_code), outline_mix if outline_code >= 0 else 0.0, _seam_near_raw(render_data), 1.0 if seam_objects_only else 0.0,
		oc.r, oc.g, oc.b, 1.0 - outline_flat, 1.0 if count_visible else 0.0, 1.0 if up else 0.0, seam_metres, float(seam_debug),
		] + _proj_params(render_data) + [seam_level_metres, seam_gain, seam_level_gain, 0.0]).to_byte_array()
	if cov and count_visible:
		# Last frame's counts, copied aside and read back asynchronously (buffer_get_data
		# would wait for the GPU every frame).
		if _counts_live and not _read_pending:
			_rd.buffer_copy(_counts, _counts_read, 0, 0, 256)
			_read_pending = true
			_rd.buffer_get_data_async(_counts_read, _on_counts_read, 0, 256)
		_rd.buffer_clear(_counts, 0, 256)
		_counts_live = true
	var copy := PackedFloat32Array([size.x, size.y, 0, 0, 0, 0, 0, 0]).to_byte_array()
	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view, false)
		if edges:
			# VI edge AA first (the RDP's picture as drawn), back into the colour.
			var t2 := buffers.get_texture_slice(CONTEXT, TEMP2, view, 0, 1, 1)
			if cov:
				# Front triangle's colour + coverage from the samples, and the VI blend on
				# edge pixels: one pass straight into the colour.
				# (upscaling on screen: the edge info straight into the texture the screen
				# layer reads - no copy)
				var info_to := t2
				if up and upscale_screen and view == 0:
					_ensure_upscale_src(size)
					info_to = upscale_info_rid
				var ao := buffers.get_texture_slice(CONTEXT, SEAM_AO, view, 0, 1, 1)
				if seam_dirt > 0.0:
					_seam(buffers.get_color_layer(view, true), buffers.get_depth_layer(view, true),
						buffers.get_texture_slice(CONTEXT, SEAM_FRONT, view, 0, 1, 1), ao, size, render_data)
				_coverage(buffers.get_color_layer(view, true), buffers.get_depth_layer(view, true), color, info_to, ao, cp, groups)
			else:
				_edge(color, t2, buffers.get_depth_layer(view, false), e, groups)
				_pass(_soft_shader, _soft_pipe, t2, color, copy, groups)
		if filters:
			_grade(color, buffers.get_texture_slice(CONTEXT, HISTORY[_hist], view, 0, 1, 1),
				buffers.get_texture_slice(CONTEXT, HISTORY[1 - _hist], view, 0, 1, 1), c, groups)
		if combine:
			_combine(buffers, view, color, size, render_data)
		if taping:
			_tape(buffers, view, color, size, render_data)
		if frame:
			if not buffers.has_texture(CONTEXT, SNAP):
				buffers.create_texture(CONTEXT, SNAP, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
					RenderingDevice.TEXTURE_USAGE_STORAGE_BIT, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
				_snap_ok = false  # (new or resized)
			var snap := buffers.get_texture_slice(CONTEXT, SNAP, view, 0, 1, 1)
			if _snap_request:
				_pass(_frame_shader, _frame_pipe, color, snap, PackedFloat32Array([size.x, size.y, 0.0,
					float(snapshot_soften), 0, 0, 0, 0]).to_byte_array(), groups)
			if snapshot_show > 0.0 and (_snap_ok or _snap_request):
				_pass(_frame_shader, _frame_pipe, snap, color, PackedFloat32Array([size.x, size.y, 1.0,
					snapshot_show, float(snapshot_warp), snapshot_warp_amount, snapshot_dim,
					Time.get_ticks_msec() / 1000.0]).to_byte_array(), groups)
		if hud:
			_hud(color, hud_rd, PackedFloat32Array([size.x, size.y, 0, 0, 0, 0, 0, 0]).to_byte_array(), groups)
		# The VI last: dither to 16 bits and the line filter over everything, HUD included.
		if video:
			var temp := buffers.get_texture_slice(CONTEXT, TEMP, view, 0, 1, 1)
			_pass(_dither_shader, _dither_pipe, color, temp, a, groups)
			_pass(_soft_shader, _soft_pipe, temp, color, b, groups)
		if edge_upscale > 1.0 and view == 0:
			_upscale(color, (upscale_info_rid if up and upscale_screen else buffers.get_texture_slice(CONTEXT, TEMP2, view, 0, 1, 1)) if edges else color, size, up)
			upscale_edge_live = up and upscale_mode == 1
	if take:
		_hist = 1 - _hist
	if _snap_request:
		_snap_request = false
		_snap_ok = true
	# The echo needs an earlier picture: only kept while the filters run (MM's "setup frame").
	_history_ok = filters


## The screen combiners (n64_video_combine.glsl): the BLUR levels shrunk from the picture,
## then each pixel through the combiners' cycles.
func _combine(buffers: RenderSceneBuffersRD, view: int, color: RID, size: Vector2i, render_data: RenderData) -> void:
	var levels := _blur_levels(buffers, view, color, size, 1.0 + _comb_bright)
	_combine_with(buffers, view, color, size, render_data, levels)


## The BLUR levels (half, quarter, eighth, 30 rows) shrunk from the picture, in display
## values (`encode`: 1, or 1 + n bright passes).
func _blur_levels(buffers: RenderSceneBuffersRD, view: int, color: RID, size: Vector2i, encode: float, rows := true, run := true) -> Array[RID]:
	var sizes := []
	var s := size
	for i in 3:
		s = (s + Vector2i.ONE) / 2
		sizes.append(s)
	sizes.append(Vector2i(maxi(roundi(BLUR_ROWS * float(size.x) / size.y), 1), mini(BLUR_ROWS, size.y)))
	var levels: Array[RID] = []
	for i in BLUR_LEVELS.size():
		var name: StringName = BLUR_LEVELS[i]
		if not buffers.has_texture(CONTEXT, name):
			buffers.create_texture(CONTEXT, name, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
				RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT,
				RenderingDevice.TEXTURE_SAMPLES_1, sizes[i], 1, 1, true, false)
		levels.append(buffers.get_texture_slice(CONTEXT, name, view, 0, 1, 1))
	# Halve three times (the first also into framebuffer values); the 30-row copy from the quarter.
	var chain := [[color, size, levels[0], sizes[0], encode], [levels[0], sizes[0], levels[1], sizes[1], 0.0],
		[levels[1], sizes[1], levels[2], sizes[2], 0.0], [levels[1], sizes[1], levels[3], sizes[3], 0.0]]
	if not rows:
		chain.pop_back()  # (the 30-row level: the combiners' only)
	if not run:
		chain.clear()  # (just there to bind: nothing reads them)
	for step in chain:
		var src_size: Vector2i = step[1]
		var dst_size: Vector2i = step[3]
		var params := PackedFloat32Array([src_size.x, src_size.y, dst_size.x, dst_size.y, step[4], 0, 0, 0]).to_byte_array()
		_pass(_down_shader, _down_pipe, step[0], step[2], params, Vector3i(ceili(dst_size.x / 8.0), ceili(dst_size.y / 8.0), 1))
	return levels


func _combine_with(buffers: RenderSceneBuffersRD, view: int, color: RID, size: Vector2i, render_data: RenderData, levels: Array[RID]) -> void:
	_rd.buffer_update(_comb_ubo, 0, _comb_data.size() * 4, _comb_data.to_byte_array())
	var us := []
	var u_c := RDUniform.new()
	u_c.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_c.binding = 0
	u_c.add_id(color)
	us.append(u_c)
	for i in 4:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u.binding = 1 + i
		u.add_id(_lin_sampler)
		u.add_id(levels[i])
		us.append(u)
	var depth_rid := buffers.get_depth_layer(view, false) if _comb_depth else RID()
	var u_d := RDUniform.new()
	u_d.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_d.binding = 5
	u_d.add_id(_depth_sampler)
	u_d.add_id(depth_rid if depth_rid.is_valid() else levels[3])  # (no DEPTH: any texture)
	us.append(u_d)
	var ubo := RDUniform.new()
	ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	ubo.binding = 6
	ubo.add_id(_comb_ubo)
	us.append(ubo)
	var set := UniformSetCacheRD.get_cache(_comb_shader, 0, us)
	var pr: Array = _proj_params(render_data)
	var params := PackedFloat32Array([size.x, size.y, float(Engine.get_frames_drawn() % 65536), float(_comb_count),
		pr[2], pr[3], 0, 0]).to_byte_array()
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _comb_pipe)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_set_push_constant(list, params, params.size())
	_rd.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	_rd.compute_list_end()


## The video tape (n64_video_tape.glsl): the picture copied aside, then read back through the
## lens / camera / tape stages into the colour.
func _tape(buffers: RenderSceneBuffersRD, view: int, color: RID, size: Vector2i, render_data: RenderData) -> void:
	# (the blur levels only when the lens or the bloom read them)
	var soft_levels := tape.defocus > 0.0 or tape.bloom > 0.0
	var levels := _blur_levels(buffers, view, color, size, 1.0, false, soft_levels)
	var temp := buffers.get_texture_slice(CONTEXT, TEMP, view, 0, 1, 1)
	var groups := Vector3i(ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	_pass(_tprep_shader, _tprep_pipe, color, temp, PackedFloat32Array([size.x, size.y, 0, 0, 0, 0, 0, 0]).to_byte_array(), groups)
	var us := []
	for i in 2:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = i
		u.add_id(temp if i == 0 else color)
		us.append(u)
	for i in 3:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u.binding = 2 + i
		u.add_id(_lin_sampler)
		u.add_id(levels[i])
		us.append(u)
	var depth_rid := buffers.get_depth_layer(view, false) if access_resolved_depth else RID()
	var has_depth := depth_rid.is_valid()
	var u_d := RDUniform.new()
	u_d.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_d.binding = 5
	u_d.add_id(_depth_sampler)
	u_d.add_id(depth_rid if has_depth else levels[3])
	us.append(u_d)
	var set := UniformSetCacheRD.get_cache(_tape_shader, 0, us)
	var pr: Array = _proj_params(render_data)
	var params := PackedFloat32Array([size.x, size.y, float(Engine.get_frames_drawn() % 65536), pr[2], pr[3],
		1.0 if has_depth else 0.0] + tape.params(size.y) + [0.0, 0.0]).to_byte_array()
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _tape_pipe)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_set_push_constant(list, params, params.size())
	_rd.compute_list_dispatch(list, groups.x, groups.y, 1)
	_rd.compute_list_end()


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


## Whether this Godot has the coverage built-ins (engine/patches/0001-coverage-builtins):
## our builds carry the build name "m3d3" (tools/engine/build.sh); official ones "official".
static func _engine_has_coverage() -> bool:
	var build := String(Engine.get_version_info().get("build", "official"))
	return build.begins_with("m3d3") or build == "custom_build"


## |P00|, |P11|, P22, P32 of the camera projection (the coverage pass rebuilds view
## positions from raw depth: distance = P32 / (raw + P22)).
func _proj_params(render_data: RenderData) -> Array:
	var pr := render_data.get_render_scene_data().get_cam_projection()
	return [absf(pr.x.x), absf(pr.y.y), pr.z.z, pr.w.z]


## The raw (reversed-Z) depth at seam_distance: about near / distance.
func _seam_near_raw(render_data: RenderData) -> float:
	var proj := render_data.get_render_scene_data().get_cam_projection()
	var clip := proj * Vector4(0.0, 0.0, -seam_distance, 1.0)
	return clip.z / clip.w if clip.w != 0.0 else 0.0


func _on_counts_read(data: PackedByteArray) -> void:
	_visible = data.to_int32_array()
	_read_pending = false


## Pixels of object `object_id` seen a frame or two ago (count_visible on; 0 when off or
## unseen). `counting()`: whether counts are coming at all (the coverage pass running).
func counting() -> bool:
	return count_visible and _counts_live


## Pixels of object `object_id` seen last frame (count_visible on; 0 when off or unseen).
func visible_pixels(object_id: int) -> int:
	var i := object_id if object_id > 0 else 0
	return _visible[i] if i < _visible.size() else 0


func _upscale(color: RID, info: RID, size: Vector2i, edge_aware: bool) -> void:
	var out := Vector2i((Vector2(size) * edge_upscale).round())
	for i in range(_up_retired.size() - 1, -1, -1):
		_up_retired[i][1] -= 1
		if _up_retired[i][1] <= 0:
			if _rd.texture_is_valid(_up_retired[i][0]):
				_rd.free_rid(_up_retired[i][0])
			_up_retired.remove_at(i)
	if upscale_screen:
		_upscale_src(color, info, size)
		return
	if out != _up_size or not upscaled_rid.is_valid():
		if upscaled_rid.is_valid():
			# (not freed yet: the screen layer showing it (RenderScale) still draws it this
			# frame, and picks up the new one next frame)
			_up_retired.append([upscaled_rid, 4])
		var f := RDTextureFormat.new()
		# 8 bits: the picture is already sRGB-encoded (and 16-bit dithered) - half the traffic.
		f.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
		f.width = out.x
		f.height = out.y
		f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		upscaled_rid = _rd.texture_create(f, RDTextureView.new())
		_up_size = out
	var ids := [color, info, upscaled_rid]
	var us := []
	for i in 3:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = i
		u.add_id(ids[i])
		us.append(u)
	var set := UniformSetCacheRD.get_cache(_up_shader, 0, us)
	var params := PackedFloat32Array([size.x, size.y, float(edge_upscale), float(upscale_mode) if edge_aware else 0.0,
		1.0 if upscale_show else 0.0, 0, 0, 0]).to_byte_array()
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _up_pipe)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_set_push_constant(list, params, params.size())
	_rd.compute_list_dispatch(list, ceili(out.x / 8.0), ceili(out.y / 8.0), 1)
	_rd.compute_list_end()


## The picture (sRGB, 8 bits) and its edge info kept at render size for the screen layer.
func _upscale_src(color: RID, info: RID, size: Vector2i) -> void:
	_ensure_upscale_src(size)
	var in_place := info == upscale_info_rid
	# (in place: the read slot gets the colour, never read - one image isn't bound twice)
	var ids := [color, color if in_place else info, upscale_src_rid, upscale_info_rid]
	var us := []
	for i in 4:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = i
		u.add_id(ids[i])
		us.append(u)
	var set := UniformSetCacheRD.get_cache(_ups_shader, 0, us)
	# (info already in place when the coverage pass wrote it there: colour only)
	var params := PackedFloat32Array([size.x, size.y, 0.0 if in_place else 1.0, 0]).to_byte_array()
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _ups_pipe)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_set_push_constant(list, params, params.size())
	_rd.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	_rd.compute_list_end()


func _ensure_upscale_src(size: Vector2i) -> void:
	if size != _ups_size or not upscale_src_rid.is_valid():
		for rid in [upscale_src_rid, upscale_info_rid]:
			if rid.is_valid():
				_up_retired.append([rid, 4])  # (the screen layer may still draw it this frame)
		var usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		var f := RDTextureFormat.new()
		f.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
		f.width = size.x
		f.height = size.y
		f.usage_bits = usage
		upscale_src_rid = _rd.texture_create(f, RDTextureView.new())
		var fi := RDTextureFormat.new()
		fi.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		fi.width = size.x
		fi.height = size.y
		fi.usage_bits = usage
		upscale_info_rid = _rd.texture_create(fi, RDTextureView.new())
		_ups_size = size


## Whether the screen layer should run the edge-aware logic (coverage available this frame).
var upscale_edge_live := false


## The contact shadow's two stages (n64_video_seam.glsl): front surfaces, then the shadow at
## half size into `ao` for the coverage pass.
func _seam(color_ms: RID, depth_ms: RID, front: RID, ao: RID, size: Vector2i, render_data: RenderData) -> void:
	var us := []
	for b in 2:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u.binding = b
		u.add_id(_depth_sampler)
		u.add_id(color_ms if b == 0 else depth_ms)
		us.append(u)
	for b in [2, 3]:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = b
		u.add_id(front if b == 2 else ao)
		us.append(u)
	var set := UniformSetCacheRD.get_cache(_seam_shader, 0, us)
	var base := [size.x, size.y, 0.0, float(seam_radius), _seam_near_raw(render_data), 1.0 if seam_objects_only else 0.0,
		seam_metres, seam_level_metres, seam_gain, seam_level_gain, 0.0, 0.0]
	var half := (size + Vector2i.ONE) / 2
	for stage in 2:
		var pc := base.duplicate()
		pc[2] = float(stage)
		var params := (PackedFloat32Array(pc) + PackedFloat32Array(_proj_params(render_data))).to_byte_array()
		var dims := size if stage == 0 else half
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _seam_pipe)
		_rd.compute_list_bind_uniform_set(list, set, 0)
		_rd.compute_list_set_push_constant(list, params, params.size())
		_rd.compute_list_dispatch(list, ceili(dims.x / 8.0), ceili(dims.y / 8.0), 1)
		_rd.compute_list_end()


func _coverage(color_ms: RID, depth_ms: RID, to: RID, info: RID, ao: RID, params: PackedByteArray, groups: Vector3i) -> void:
	var u_c := RDUniform.new()
	u_c.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_c.binding = 0
	u_c.add_id(_depth_sampler)
	u_c.add_id(color_ms)
	var u_d := RDUniform.new()
	u_d.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_d.binding = 1
	u_d.add_id(_depth_sampler)
	u_d.add_id(depth_ms)
	var u_to := RDUniform.new()
	u_to.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_to.binding = 2
	u_to.add_id(to)
	var u_n := RDUniform.new()
	u_n.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_n.binding = 3
	u_n.add_id(_counts)
	var u_i := RDUniform.new()
	u_i.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_i.binding = 4
	u_i.add_id(info)
	var u_a := RDUniform.new()
	u_a.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_a.binding = 5
	u_a.add_id(ao)
	var set := UniformSetCacheRD.get_cache(_cov_shader, 0, [u_c, u_d, u_to, u_n, u_i, u_a])
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _cov_pipe)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_set_push_constant(list, params, params.size())
	_rd.compute_list_dispatch(list, groups.x, groups.y, groups.z)
	_rd.compute_list_end()


func _edge(from: RID, to: RID, depth: RID, params: PackedByteArray, groups: Vector3i) -> void:
	var u_from := RDUniform.new()
	u_from.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_from.binding = 0
	u_from.add_id(from)
	var u_to := RDUniform.new()
	u_to.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_to.binding = 1
	u_to.add_id(to)
	var u_d := RDUniform.new()
	u_d.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_d.binding = 2
	u_d.add_id(_depth_sampler)
	u_d.add_id(depth)
	var set := UniformSetCacheRD.get_cache(_edge_shader, 0, [u_from, u_to, u_d])
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _edge_pipe)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_set_push_constant(list, params, params.size())
	_rd.compute_list_dispatch(list, groups.x, groups.y, groups.z)
	_rd.compute_list_end()


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


## Copies the 3D picture on the next frame (before the HUD) for snapshot_show to draw back.
func take_snapshot() -> void:
	_snap_request = true


## A snapshot has been taken (and the render size hasn't changed since).
func has_snapshot() -> bool:
	return _snap_ok


func _hud(color: RID, hud_rd: RID, params: PackedByteArray, groups: Vector3i) -> void:
	var u_c := RDUniform.new()
	u_c.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_c.binding = 0
	u_c.add_id(color)
	var u_h := RDUniform.new()
	u_h.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_h.binding = 1
	u_h.add_id(_hud_sampler)
	u_h.add_id(hud_rd)
	var set := UniformSetCacheRD.get_cache(_hud_shader, 0, [u_c, u_h])
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _hud_pipe)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_set_push_constant(list, params, params.size())
	_rd.compute_list_dispatch(list, groups.x, groups.y, groups.z)
	_rd.compute_list_end()
