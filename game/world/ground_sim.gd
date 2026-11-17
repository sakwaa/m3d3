class_name GroundSim
extends Node
## A small GPU simulation over a square of ground round the camera (`size` metres, `res`
## texels: texture x = world x, y = world z), ping-ponged between two float SubViewports: a
## canvas shader draws each frame's field from the last one's. Used for what moves through
## the ground's surfaces: the mist's and the grass's disturbance (n64_mist_sim.gdshader) and
## water ripples (n64_ripple_sim.gdshader).
## Feeds the shader every frame: `prev` (last field), `shift` (the camera moved: uv offset),
## `dt`, `size`, and with `feed_actors` the actors (group "actors", up to MAX_ACTORS):
## `actors` (uv x, y, radius, landing burst this frame), `actor_vel` (velocity x, z),
## `actor_count`. `params` go to the shader as they are.
## `footprints`: actors are fed only as separate prints, left and right foot in turn, one
## every `stride` metres (actor_vel.w = 1: a stamp, pressed in, nothing pushed).
## blast(): a gust / shockwave at a world point - every GroundSim in the scene takes it as a
## landing-style burst (mist scatters, grass flattens, puddles ring).
## Read it with `texture` (a third viewport copying the newest field: fixed, so materials bind
## it once) and `rect()` (corner x, z, size; changes as the camera moves). With `rect_global`
## the square also goes to that shader global each frame (the very corner the texture is drawn
## for: shaders reading it never slip a texel against it).

const COPY_SHADER := preload("res://addons/n64_runtime/shaders/n64_sim_copy.gdshader")
const MAX_ACTORS := 8

var shader: Shader
var res := 64
var size := 16.0
var params := {}
var feed_actors := true
const GROUP := &"ground_sims"
var footprints := false
## A global shader parameter (vec4) to keep this frame's rect() in, or empty.
var rect_global := &""
var stride := 0.55
## How wide each actor disturbs it (metres): the player's, other actors'.
var radius := 0.45
var radius_other := 0.38
## Stable output (the newest field, copied).
var texture: Texture2D

var _vp: Array[SubViewport] = []
var _mat: Array[ShaderMaterial] = []
var _copy_vp: SubViewport
var _copy_mat: ShaderMaterial
var _i := 0
var _corner := Vector2.INF
var _scan := 0.0
var _actors: Array = []
var _airborne := {}
var _bursts := {}
var _blasts: Array = []  # [Vector3 world, float radius, float strength]
var _prints := {}  # actor -> [last print position, next foot side]


func _init(p_shader: Shader = null, p_res := 64, p_size := 16.0) -> void:
	shader = p_shader
	res = p_res
	size = p_size


## A gust / shockwave at `world` (metres of `radius`, 0..1+) into every GroundSim here.
static func blast(tree: SceneTree, world: Vector3, radius := 2.0, strength := 1.0) -> void:
	for s in tree.get_nodes_in_group(GROUP):
		(s as GroundSim)._blasts.append([world, radius, strength])


func _ready() -> void:
	add_to_group(GROUP)
	for k in 2:
		var m := ShaderMaterial.new()
		m.shader = shader
		_vp.append(_viewport(m))
		_mat.append(m)
	for k in 2:
		_mat[k].set_shader_parameter(&"prev", _vp[1 - k].get_texture())
	_copy_mat = ShaderMaterial.new()
	_copy_mat.shader = COPY_SHADER
	_copy_vp = _viewport(_copy_mat)
	texture = _copy_vp.get_texture()


func _exit_tree() -> void:
	if rect_global != &"":
		RenderingServer.global_shader_parameter_set(rect_global, Vector4.ZERO)


func _viewport(m: ShaderMaterial) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(res, res)
	vp.disable_3d = true
	vp.use_hdr_2d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var rect := ColorRect.new()
	rect.size = Vector2(res, res)
	rect.material = m
	vp.add_child(rect)
	add_child(vp, false, INTERNAL_MODE_BACK)
	return vp


## Corner x, z and size of the square now (world metres).
func rect() -> Vector4:
	var c := _corner if _corner != Vector2.INF else Vector2.ZERO
	return Vector4(c.x, c.y, size, 0.0)


## A landing ring from `actor` this frame (0..1).
func splash(actor: Node, strength := 1.0) -> void:
	_bursts[actor] = maxf(_bursts.get(actor, 0.0), strength)


func _process(delta: float) -> void:
	if _vp.size() < 2:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var c := cam.global_position
	var cell := size / res
	var corner := Vector2(snappedf(c.x, cell), snappedf(c.z, cell)) - Vector2.ONE * size * 0.5
	var shift := Vector2.ZERO if _corner == Vector2.INF else (corner - _corner) / size
	_corner = corner
	if rect_global != &"":
		RenderingServer.global_shader_parameter_set(rect_global, rect())
	var m := _mat[_i]
	m.set_shader_parameter(&"shift", shift)
	m.set_shader_parameter(&"dt", minf(delta, 0.05))
	m.set_shader_parameter(&"size", size)
	for k in params:
		m.set_shader_parameter(k, params[k])
	if feed_actors:
		_feed(m, corner, delta)
	_vp[_i].render_target_update_mode = SubViewport.UPDATE_ONCE
	_copy_mat.set_shader_parameter(&"src", _vp[_i].get_texture())
	_copy_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_i = 1 - _i


func _feed(m: ShaderMaterial, corner: Vector2, delta: float) -> void:
	_scan -= delta
	if _scan <= 0.0:
		_scan = 1.0
		_actors = get_tree().get_nodes_in_group(&"actors")
	var pos := PackedVector4Array()
	var vel := PackedVector4Array()
	for a in _actors:
		if pos.size() >= MAX_ACTORS:
			break
		if not is_instance_valid(a) or not a.is_inside_tree():
			continue
		var p: Vector3 = a.global_position
		var v: Vector3 = a.get(&"velocity") if a.get(&"velocity") != null else Vector3.ZERO
		_detect_landing(a, v)
		if footprints:
			# A print each stride, feet in turn either side of the path.
			var st: Array = _prints.get(a, [Vector3.INF, 1.0])
			var flat := Vector2(v.x, v.z)
			if absf(v.y) < 1.5 and (st[0] == Vector3.INF or (st[0] as Vector3).distance_to(p) >= stride) and flat.length() > 0.3:
				var side := Vector2(-flat.y, flat.x).normalized() * 0.11 * float(st[1])
				_prints[a] = [p, -float(st[1])]
				var fuv := (Vector2(p.x, p.z) + side - corner) / size
				pos.append(Vector4(fuv.x, fuv.y, radius, 0.0))
				vel.append(Vector4(flat.x, flat.y, p.y, 1.0))
			elif st[0] == Vector3.INF:
				_prints[a] = [p, 1.0]
			continue
		var uv := (Vector2(p.x, p.z) - corner) / size
		pos.append(Vector4(uv.x, uv.y, radius if a.is_in_group(&"player") else radius_other, _bursts.get(a, 0.0)))
		vel.append(Vector4(v.x, v.z, p.y, 0.0))
	_bursts.clear()
	for b in _blasts:
		if pos.size() >= MAX_ACTORS:
			break
		var buv := (Vector2(b[0].x, b[0].z) - corner) / size
		pos.append(Vector4(buv.x, buv.y, float(b[1]) * 0.5, float(b[2])))
		vel.append(Vector4(0.0, 0.0, b[0].y, 2.0))  # (w 2: a blast)
	_blasts.clear()
	var n := pos.size()
	while pos.size() < MAX_ACTORS:
		pos.append(Vector4.ZERO)
		vel.append(Vector4.ZERO)
	m.set_shader_parameter(&"actors", pos)
	m.set_shader_parameter(&"actor_vel", vel)
	m.set_shader_parameter(&"actor_count", n)


## A landing (on the floor again after falling): a burst as strong as the fall was fast.
func _detect_landing(a: Node, v: Vector3) -> void:
	var on_floor: bool = a.call(&"is_on_floor") if a.has_method(&"is_on_floor") else true
	if not on_floor:
		_airborne[a] = minf(_airborne.get(a, 0.0), v.y)
	elif _airborne.has(a):
		var fall: float = -float(_airborne[a])
		_airborne.erase(a)
		if fall > 2.0:
			splash(a, clampf(fall / 8.0, 0.25, 1.0))
