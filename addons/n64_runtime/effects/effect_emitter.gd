@tool
class_name EffectEmitter
extends Node3D
## Plays an N64Effect here: its burst, then its stream (rate) while playing. Sprites are
## simulated in world space (a moving emitter leaves a trail) and drawn as one MultiMesh.
## Emits along the node's +Y (spread around it). Place one for looping effects (torches,
## chimney smoke, waterfall mist; they run in the editor too), or use Effects.spawn() for
## one-shot bursts, which free themselves when done.

## Sprites alive across every emitter; past it new sprites recycle the emitter's oldest.
const GLOBAL_MAX := 256

static var _alive_total := 0
static var _quad: QuadMesh
static var _shaders := {}

@export var effect: N64Effect:
	set(value):
		effect = value
		if is_inside_tree():
			restart()
@export var autoplay := true
## Plays the effect again from the start (editor preview).
@export_tool_button("Play", "Play") var play_button := restart

## Free the node once the burst is over and every sprite has died (Effects.spawn).
var one_shot := false
var playing := false

var _mmi: MultiMeshInstance3D
var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _age := PackedFloat32Array()
var _life := PackedFloat32Array()
var _size := PackedFloat32Array()
var _spin := PackedFloat32Array()
var _spin_speed := PackedFloat32Array()
var _seed := PackedFloat32Array()
var _emit_carry := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	if autoplay:
		restart()


func _exit_tree() -> void:
	_alive_total -= _pos.size()
	_clear()


func restart() -> void:
	_alive_total -= _pos.size()
	_clear()
	if effect == null:
		playing = false
		return
	_ensure_mesh()
	playing = true
	_emit_carry = 0.0
	for i in effect.burst:
		_emit()
	if not Engine.is_editor_hint() or one_shot:
		for e in effect.with:
			if e:
				Effects.spawn(e, global_position, global_basis.y)


func stop() -> void:
	playing = false


func sprite_count() -> int:
	return _pos.size()


func _clear() -> void:
	# (Packed arrays copy on write: each is cleared by name, not through a list.)
	_pos.clear()
	_vel.clear()
	_age.clear()
	_life.clear()
	_size.clear()
	_spin.clear()
	_spin_speed.clear()
	_seed.clear()


func _ensure_mesh() -> void:
	if _quad == null:
		_quad = QuadMesh.new()
	if _mmi == null:
		_mmi = MultiMeshInstance3D.new()
		_mmi.top_level = true
		_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = _quad
		mm.custom_aabb = AABB(Vector3(-5000, -5000, -5000), Vector3(10000, 10000, 10000))
		_mmi.multimesh = mm
		add_child(_mmi, false, INTERNAL_MODE_BACK)
	_mmi.global_transform = Transform3D.IDENTITY
	var mm := _mmi.multimesh
	if mm.instance_count != effect.max_sprites:
		mm.instance_count = effect.max_sprites
	mm.visible_instance_count = 0
	var shader: Shader = _shaders.get(effect.blend)
	if shader == null:
		shader = load("res://addons/n64_runtime/shaders/n64_effect_add.gdshader" if effect.blend == N64Effect.Blend.ADD
			else "res://addons/n64_runtime/shaders/n64_effect_mix.gdshader")
		_shaders[effect.blend] = shader
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter(&"sprite", effect.texture)
	mat.set_shader_parameter(&"grid", Vector2(maxi(effect.columns, 1), effect.rows()))
	mat.set_shader_parameter(&"billboard", effect.facing == N64Effect.Facing.CAMERA)
	_mmi.material_override = mat


func _emit() -> void:
	if _pos.size() >= effect.max_sprites or _alive_total >= GLOBAL_MAX:
		if _pos.is_empty():
			return
		_kill(_oldest())
	var up := global_basis.y.normalized()
	var dir := _random_cone(up, deg_to_rad(effect.spread))
	var off := Vector3.ZERO
	if effect.radius > 0.0:
		var side := _random_cone(up, PI * 0.5)
		off = (side - up * side.dot(up)).normalized() * effect.radius * sqrt(_rng.randf())
	_pos.append(global_position + off)
	_vel.append(dir * _rng.randf_range(effect.speed.x, effect.speed.y))
	_age.append(0.0)
	_life.append(maxf(_rng.randf_range(effect.lifetime.x, effect.lifetime.y), 0.01))
	_size.append(_rng.randf_range(effect.size.x, effect.size.y))
	_spin.append(_rng.randf() * TAU)
	_spin_speed.append(_rng.randf_range(effect.spin.x, effect.spin.y) * TAU * (1.0 if _rng.randf() < 0.5 else -1.0))
	_seed.append(_rng.randf())
	_alive_total += 1


## A random unit vector within `angle` (radians) of `axis`.
func _random_cone(axis: Vector3, angle: float) -> Vector3:
	var z := lerpf(1.0, cos(angle), _rng.randf())
	var a := _rng.randf() * TAU
	var r := sqrt(maxf(1.0 - z * z, 0.0))
	var t1 := axis.cross(Vector3.RIGHT if absf(axis.x) < 0.9 else Vector3.FORWARD).normalized()
	var t2 := axis.cross(t1)
	return (axis * z + (t1 * cos(a) + t2 * sin(a)) * r).normalized()


func _oldest() -> int:
	var best := 0
	for i in _age.size():
		if _age[i] / _life[i] > _age[best] / _life[best]:
			best = i
	return best


## Swap-removes sprite `i`.
func _kill(i: int) -> void:
	var last := _pos.size() - 1
	_pos[i] = _pos[last]
	_vel[i] = _vel[last]
	_age[i] = _age[last]
	_life[i] = _life[last]
	_size[i] = _size[last]
	_spin[i] = _spin[last]
	_spin_speed[i] = _spin_speed[last]
	_seed[i] = _seed[last]
	_pos.resize(last)
	_vel.resize(last)
	_age.resize(last)
	_life.resize(last)
	_size.resize(last)
	_spin.resize(last)
	_spin_speed.resize(last)
	_seed.resize(last)
	_alive_total -= 1


func _process(delta: float) -> void:
	if effect == null or _mmi == null:
		return
	if playing and effect.rate > 0.0:
		_emit_carry += effect.rate * delta
		while _emit_carry >= 1.0:
			_emit_carry -= 1.0
			_emit()
	elif playing and effect.rate <= 0.0:
		playing = false  # a burst: nothing more to emit
	var drag := exp(-effect.drag * delta)
	var i := 0
	while i < _pos.size():
		_age[i] += delta
		if _age[i] >= _life[i]:
			_kill(i)
			continue
		var v := _vel[i]
		v.y -= effect.gravity * delta
		v *= drag
		_vel[i] = v
		_pos[i] += v * delta
		_spin[i] += _spin_speed[i] * delta
		i += 1
	_draw()
	if one_shot and not playing and _pos.is_empty():
		queue_free()


func _draw() -> void:
	var mm := _mmi.multimesh
	var n := mini(_pos.size(), mm.instance_count)
	var flat := effect.facing == N64Effect.Facing.FLAT
	var up := global_basis.y.normalized()
	var flat_basis := Basis()
	if flat:
		var x := up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
		flat_basis = Basis(x, up.cross(x), up)  # the quad (XY) lies across the emit direction
	for k in n:
		var t := _age[k] / _life[k]
		var s := _size[k] * lerpf(1.0, effect.size_end, t)
		var b := Basis.from_scale(Vector3(s, s, s))
		if flat:
			b = flat_basis.rotated(up, _spin[k]).scaled_local(Vector3(s, s, s))
		# Flat sprites ride a little above the surface they lie on (no z-fighting).
		mm.set_instance_transform(k, Transform3D(b, _pos[k] + up * 0.02 if flat else _pos[k]))
		mm.set_instance_color(k, effect.color_at(t))
		var frame := 0.0
		if effect.frames > 1:
			frame = floorf(t * effect.frames) if effect.fps <= 0.0 else fmod(floorf(_age[k] * effect.fps + _seed[k] * effect.frames), effect.frames)
		mm.set_instance_custom_data(k, Color(frame, _spin[k], 0.0, 0.0))
	mm.visible_instance_count = n
