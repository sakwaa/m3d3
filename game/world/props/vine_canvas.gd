class_name VineCanvas
extends Node3D
## Vines grown on the GPU into a texture laid over a surface (a wall, the ground): a compute
## shader (vine_canvas.glsl) runs the tendril tips - wander, seek, climb, branch, leaves, steer
## round holes and drop into hanging strands off a hole's top edge - painting stems and
## leaves into the canvas and each texel's distance from the source into a reach map. The
## panel (vine_canvas.gdshader) shows what the growth front has passed, with a soft shadow:
## `grown` 0..1 / grow_to() grow and shrink it for free, from the shared source, like
## WorldVines. Two triangles whatever the coverage.
## The panel is the node's XY plane (facing +Z), `size` metres, centred; seeds and target are
## in metres on it (x right, y up from its middle). The surface (where the vines may go) is
## found by short rays at the panel's texels against the meshes around it.
## Grows all at once when it enters the tree (`steps` compute steps; a few ms) - or live,
## step by step (`live_speed`).

signal grown_fully
## The canvas is set up (and grown, unless live) and its panel shown.
signal ready_to_show

const COMPUTE := preload("res://game/world/props/vine_canvas.glsl")
const SHADER := preload("res://game/world/props/vine_canvas.gdshader")
const TIP_FLOATS := 12

@export var size := Vector2(10.0, 4.0)
@export_range(8, 128) var texels_per_m := 48
## Where the tendrils start (metres on the panel) - one shared source, or several.
@export var seeds: PackedVector2Array = [Vector2(-4.0, -1.9)]
## Tendrils from each seed.
@export_range(1, 256) var tendrils := 24
@export var target := Vector2(0.0, 1.6)
## Turn towards the target, up the surface, and the wander: per 0.3 m like WorldVines.
@export_range(0.0, 1.0, 0.01) var seek := 0.15
@export_range(-1.0, 1.0, 0.01) var climb := 0.3
@export_range(0.0, 90.0, 1.0, "suffix:°") var wander := 14.0
## Length of each tendril (metres; branches get some of what's left).
@export_range(0.5, 60.0, 0.1, "suffix:m") var length := 9.0
@export_range(0.002, 0.2, 0.001, "suffix:m") var stem_width := 0.025
@export_range(0.0, 0.1, 0.001) var branch := 0.012
@export_range(0.02, 1.0, 0.01, "suffix:m") var leaf_every := 0.09
@export_range(0.02, 1.0, 0.01, "suffix:m") var leaf_size := 0.13
@export_range(0.0, 1.0, 0.05) var hang := 0.7
@export_range(64, 8192) var max_tips := 2048
@export var seed := 1
## Compute steps at start (each moves every tip a texel).
@export_range(1, 4000) var steps := 700
## 0: grown all at once at start; > 0: grown live at this many metres a second instead.
@export_range(0.0, 10.0, 0.05, "suffix:m/s") var live_speed := 0.0
@export_range(0.0, 1.0, 0.01) var grown := 1.0:
	set(v):
		grown = v
		_apply()

var _rd: RenderingDevice
var _shader: RID
var _pipe: RID
var _tips: RID
var _count: RID
var _canvas: RID
var _reach: RID
var _surface: RID
var _set: RID
var _px := Vector2i.ZERO
var _frame := 0
var _live_left := 0.0
var _mat: ShaderMaterial
var _panel: MeshInstance3D
var _tween: Tween
## Milliseconds the start-up growth took (CPU side, incl. waiting for the GPU).
var grow_ms := 0.0


func _ready() -> void:
	_px = Vector2i(int(size.x * texels_per_m), int(size.y * texels_per_m))
	var surface := _find_surface()
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return  # (Compatibility renderer: no compute)
	# (set-up and the start-up growth run on the render thread: the panel waits for them)
	RenderingServer.call_on_render_thread(_setup.bind(surface))
	if live_speed <= 0.0:
		RenderingServer.call_on_render_thread(_run.bind(steps, true))
	else:
		_live_left = float(steps)
	await RenderingServer.frame_post_draw
	_make_panel()
	_apply()
	ready_to_show.emit()


func _process(delta: float) -> void:
	if _live_left > 0.0 and _rd:
		var n := mini(int(ceil(live_speed * texels_per_m * delta)), int(_live_left))
		_live_left -= n
		RenderingServer.call_on_render_thread(_run.bind(n))


## Animates `grown` to `to` over `seconds` (grown_fully on reaching 1).
func grow_to(to: float, seconds: float) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, ^"grown", to, maxf(seconds, 0.01))
	if to >= 1.0:
		_tween.tween_callback(grown_fully.emit)


func _apply() -> void:
	if _mat:
		# (the furthest a texel can be from the source is about a tendril's length)
		_mat.set_shader_parameter(&"grow", grown * length * texels_per_m * 1.02 if grown < 1.0 else 1e9)
		if _panel:
			_panel.visible = grown > 0.0


# --- Set-up -----------------------------------------------------------------------------------

## Where the surface is under the panel (1) or not (0), at texel size: a short ray at each
## texel (every 4th, then filled) against the meshes around it.
func _find_surface() -> PackedByteArray:
	var grid := VineBuilder.TriGrid.new()
	var half := Vector3(size.x * 0.5 + 0.5, size.y * 0.5 + 0.5, 0.6)
	var corners := [Vector3(-half.x, -half.y, -half.z), Vector3(half.x, half.y, half.z)]
	var region := AABB(global_transform * corners[0], Vector3.ZERO).expand(global_transform * corners[1])
	region = region.grow(0.6)
	_gather(get_tree().current_scene if get_tree().current_scene else get_tree().root, region, grid)
	var out := PackedByteArray()
	out.resize(_px.x * _px.y)
	var n := global_basis.z.normalized()
	var k := 4
	var coarse := {}
	for y in range(0, _px.y, k):
		for x in range(0, _px.x, k):
			var p := _texel_world(Vector2(x + k * 0.5, y + k * 0.5))
			coarse[Vector2i(x / k, y / k)] = not grid.ray(p + n * 0.15, p - n * 0.15).is_empty()
	for y in _px.y:
		for x in _px.x:
			out[y * _px.x + x] = 255 if coarse.get(Vector2i(x / k, y / k), false) else 0
	return out


## A texel's place in the world (texture y down = panel y up from the top edge).
func _texel_world(t: Vector2) -> Vector3:
	var local := Vector3(t.x / texels_per_m - size.x * 0.5, size.y * 0.5 - t.y / texels_per_m, 0.0)
	return global_transform * local


func _to_texel(m: Vector2) -> Vector2:
	return Vector2((m.x + size.x * 0.5) * texels_per_m, (size.y * 0.5 - m.y) * texels_per_m)


func _gather(node: Node, region: AABB, grid: VineBuilder.TriGrid) -> void:
	if node == self or node is WorldVines:
		return
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh and mi.is_visible_in_tree():
			if (mi.global_transform * mi.get_aabb()).intersects(region):
				grid.add_faces(mi.mesh.get_faces(), mi.global_transform, region)
	for c in node.get_children(true):
		_gather(c, region, grid)


func _setup(surface: PackedByteArray) -> void:
	_shader = _rd.shader_create_from_spirv(COMPUTE.get_spirv())
	_pipe = _rd.compute_pipeline_create(_shader)
	var tf := RDTextureFormat.new()
	tf.width = _px.x
	tf.height = _px.y
	tf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	_canvas = _rd.texture_create(tf, RDTextureView.new())
	_rd.texture_clear(_canvas, Color(0, 0, 0, 0), 0, 1, 0, 1)
	tf.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	_reach = _rd.texture_create(tf, RDTextureView.new())
	_rd.texture_clear(_reach, Color(0, 0, 0, 0), 0, 1, 0, 1)
	tf.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	_surface = _rd.texture_create(tf, RDTextureView.new(), [surface])
	# Tips: each seed's tendrils fanned towards the target.
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var data := PackedFloat32Array()
	data.resize(max_tips * TIP_FLOATS)
	var n := 0
	for s in seeds:
		var at := _to_texel(s)
		var to := (_to_texel(target) - at).normalized()
		for i in tendrils:
			if n >= max_tips:
				break
			var dir := to.rotated(rng.randf_range(-0.7, 0.7))
			var o := n * TIP_FLOATS
			var tip := [at.x + rng.randf_range(-3, 3), at.y + rng.randf_range(-3, 3), dir.x, dir.y,
				length * texels_per_m * rng.randf_range(0.7, 1.0), maxf(stem_width * texels_per_m, 0.6),
				rng.randf() * leaf_every * texels_per_m, 1.0, 0.0, 1.0 if i % 2 == 0 else -1.0, 0.0, 0.0]
			for k in TIP_FLOATS:
				data[o + k] = tip[k]
			n += 1
	_tips = _rd.storage_buffer_create(data.size() * 4, data.to_byte_array())
	_count = _rd.storage_buffer_create(16, PackedInt32Array([n, 0, 0, 0]).to_byte_array())
	var us := []
	for b in [[0, _tips, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER], [1, _count, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER],
			[2, _canvas, RenderingDevice.UNIFORM_TYPE_IMAGE], [3, _reach, RenderingDevice.UNIFORM_TYPE_IMAGE],
			[4, _surface, RenderingDevice.UNIFORM_TYPE_IMAGE]]:
		var u := RDUniform.new()
		u.binding = b[0]
		u.uniform_type = b[2]
		u.add_id(b[1])
		us.append(u)
	_set = _rd.uniform_set_create(us, _shader, 0)


## `n` compute steps (every tip moves a texel each).
func _run(n: int, timed := false) -> void:
	if not _pipe.is_valid():
		return
	var t0 := Time.get_ticks_usec()
	if timed:
		_rd.capture_timestamp("vine_canvas_start")
	var groups := ceili(max_tips / 64.0)
	for i in n:
		_frame += 1
		# (settings are per 0.3 m like WorldVines'; a step here is one texel)
		var per := 1.0 / (0.3 * texels_per_m)
		var pc := PackedFloat32Array([_px.x, _px.y, _frame, deg_to_rad(wander) * per,
			_to_texel(target).x, _to_texel(target).y, seek * per, climb * per,
			branch, leaf_every * texels_per_m, leaf_size * texels_per_m, hang,
			max_tips, float(seed % 1000), 0.0, 0.0]).to_byte_array()
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _pipe)
		_rd.compute_list_bind_uniform_set(list, _set, 0)
		_rd.compute_list_set_push_constant(list, pc, pc.size())
		_rd.compute_list_dispatch(list, groups, 1, 1)
		_rd.compute_list_end()
	if timed:
		_rd.capture_timestamp("vine_canvas_end")
		grow_ms = (Time.get_ticks_usec() - t0) / 1000.0  # (recording the steps; the GPU runs them after)


## GPU time of the last timed run (ms, -1 if not captured yet): call a frame or two after.
func gpu_ms() -> float:
	var t := {}
	for i in _rd.get_captured_timestamps_count():
		t[_rd.get_captured_timestamp_name(i)] = _rd.get_captured_timestamp_gpu_time(i)
	if t.has("vine_canvas_start") and t.has("vine_canvas_end"):
		return (t.vine_canvas_end - t.vine_canvas_start) / 1e6
	return -1.0


func _make_panel() -> void:
	_panel = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = size
	_panel.mesh = q
	_panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	var ct := Texture2DRD.new()
	ct.texture_rd_rid = _canvas
	var rt := Texture2DRD.new()
	rt.texture_rd_rid = _reach
	_mat.set_shader_parameter(&"canvas", ct)
	_mat.set_shader_parameter(&"reach", rt)
	_mat.set_shader_parameter(&"texels", Vector2(_px))
	# (the shadow: away from the light the level is lit by, on the panel's plane)
	var l := global_basis.inverse() * Vector3(-0.45, 0.8, 0.4).normalized()
	_mat.set_shader_parameter(&"shadow_offset", Vector2(-l.x, l.y) / maxf(l.z, 0.3) * 0.06 * texels_per_m)
	_panel.material_override = _mat
	add_child(_panel, false, INTERNAL_MODE_BACK)
	_panel.position = Vector3(0, 0, 0.012)


func _exit_tree() -> void:
	if _rd == null:
		return
	var rids := [_set, _tips, _count, _canvas, _reach, _surface, _shader]
	RenderingServer.call_on_render_thread(func():
		for r in rids:
			if r.is_valid():
				_rd.free_rid(r))
