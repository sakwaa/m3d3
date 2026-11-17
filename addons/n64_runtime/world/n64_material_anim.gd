@tool
class_name N64MaterialAnim
extends Resource
## One animated material, the way Majora's Mask's scenes animate theirs (AnimatedMaterial,
## z_scene_proc.c; notes in references/combiners/mm_animated_materials_distortion.md), run by a
## MaterialAnimator on the games' 20 Hz clock (paused with the game):
##  - Two tex scroll: TEXEL0 and TEXEL1 slide a step at a time (steps in quarter texels per
##    tick, as their data; 1 = 5 texels a second; +y moves the picture up). Water: the same
##    texture twice at different sizes, drifting different ways, mixed half and half.
##  - Color (stepped): one key per tick (the lists are the frames).
##  - Color lerp: straight between keys (ticks in `keys`), the last key held.
##  - Color curve: one smooth curve through every key (their "non-linear interp": a single
##    Lagrange polynomial - it can swing past the keys, so add doubled keys near the ends).
##  - Texture cycle: the texture swapped each tick by `cycle_order` (indices into `textures`).
## It writes the material's parameters (names below: n64_textured's by default; n64_magic
## uses prim / env / k): PRIM -> prim_param (+ its lod fraction -> k_param, the two-texture
## mix), ENV -> env_param.

enum Type { TWO_TEX_SCROLL, COLOR, COLOR_LERP, COLOR_CURVE, TEX_CYCLE }

@export var material: ShaderMaterial
@export var type := Type.TWO_TEX_SCROLL:
	set(v):
		type = v
		notify_property_list_changed()
@export_group("Scroll")
## Quarter texels per tick, TEXEL0 and TEXEL1 (x right, y up).
@export var scroll0 := Vector2i(1, 1)
@export var scroll1 := Vector2i(-1, 1)
## Texture sizes in texels (0: read from the material's textures).
@export var size0 := Vector2i.ZERO
@export var size1 := Vector2i.ZERO
@export_group("Colour")
## Ticks per loop.
@export var length := 20
## Key ticks (Color lerp / curve: ascending, first 0, last length - 1).
@export var keys := PackedInt32Array([0, 19])
## Primitive colour per key (alpha = prim alpha); `lod` per key = its lod fraction (0..1).
@export var prim_keys := PackedColorArray([Color.WHITE, Color.WHITE])
@export var lod_keys := PackedFloat32Array([0.5, 0.5])
## Environment colour per key (empty: ENV left alone).
@export var env_keys := PackedColorArray()
@export_group("Cycle")
@export var textures: Array[Texture2D] = []
## One entry a tick: which texture shows.
@export var cycle_order := PackedInt32Array()
@export_group("Parameter names")
@export var offset0_param := &"uv_offset"
@export var offset1_param := &"texture1_offset"
@export var prim_param := &"cc_prim"
@export var env_param := &"cc_env"
@export var k_param := &"cc_k"
@export var texture_param := &"albedo_texture"


## Applies frame `step` (20 Hz ticks since start).
func apply(step: int) -> void:
	if material == null:
		return
	match type:
		Type.TWO_TEX_SCROLL:
			material.set_shader_parameter(offset0_param, _offset(scroll0, step, size0, &"albedo_texture"))
			material.set_shader_parameter(offset1_param, _offset(scroll1, step, size1, &"texture1"))
		Type.COLOR:
			var f := step % maxi(prim_keys.size(), 1)
			_set_colour(prim_keys[f] if f < prim_keys.size() else Color.WHITE, lod_keys[f] if f < lod_keys.size() else -1.0,
				env_keys[f] if f < env_keys.size() else null)
		Type.COLOR_LERP:
			var f := step % maxi(length, 1)
			var i := 1
			while i < keys.size() and f >= keys[i]:
				i += 1
			if i >= keys.size():
				_set_colour(_at(prim_keys, keys.size() - 1), _atf(lod_keys, keys.size() - 1), _at_env(keys.size() - 1))
			else:
				var t := float(f - keys[i - 1]) / maxf(keys[i] - keys[i - 1], 1)
				var env = null
				if not env_keys.is_empty():
					env = _trunc_lerp(_at(env_keys, i - 1), _at(env_keys, i), t)
				_set_colour(_trunc_lerp(_at(prim_keys, i - 1), _at(prim_keys, i), t),
					lerpf(_atf(lod_keys, i - 1), _atf(lod_keys, i), t), env)
		Type.COLOR_CURVE:
			var f := float(step % maxi(length, 1))
			var prim := Color(_lagrange(f, 0, prim_keys), _lagrange(f, 1, prim_keys), _lagrange(f, 2, prim_keys), _lagrange(f, 3, prim_keys))
			var env = null
			if not env_keys.is_empty():
				env = Color(_lagrange(f, 0, env_keys), _lagrange(f, 1, env_keys), _lagrange(f, 2, env_keys), _lagrange(f, 3, env_keys))
			var lod := -1.0
			if not lod_keys.is_empty():
				var lods := PackedColorArray()
				for v in lod_keys:
					lods.append(Color(v, v, v, v))
				lod = _lagrange(f, 0, lods)
			_set_colour(prim, lod, env)
		Type.TEX_CYCLE:
			if not cycle_order.is_empty() and not textures.is_empty():
				var idx := cycle_order[step % cycle_order.size()]
				if idx >= 0 and idx < textures.size():
					material.set_shader_parameter(texture_param, textures[idx])


func _offset(steps: Vector2i, step: int, size: Vector2i, tex_param: StringName) -> Vector2:
	var s := size
	if s == Vector2i.ZERO:
		var t := material.get_shader_parameter(tex_param) as Texture2D
		s = Vector2i(t.get_width(), t.get_height()) if t else Vector2i(32, 32)
	# (quarter texels, wrapped at 2048 as the RDP's tile coordinates; y negated: +y moves up)
	var qx := posmod(steps.x * step, 2048)
	var qy := posmod(-steps.y * step, 2048)
	return Vector2(fposmod(-qx / (4.0 * s.x), 1.0), fposmod(-qy / (4.0 * s.y), 1.0))


func _set_colour(prim: Color, lod: float, env) -> void:
	material.set_shader_parameter(prim_param, prim)
	if lod >= 0.0:
		material.set_shader_parameter(k_param, clampf(lod, 0.0, 1.0))
	if env is Color:
		material.set_shader_parameter(env_param, env)


func _at(a: PackedColorArray, i: int) -> Color:
	return a[clampi(i, 0, a.size() - 1)] if not a.is_empty() else Color.WHITE


func _atf(a: PackedFloat32Array, i: int) -> float:
	return a[clampi(i, 0, a.size() - 1)] if not a.is_empty() else -1.0


func _at_env(i: int):
	return null if env_keys.is_empty() else _at(env_keys, i)


## Lerp truncated to whole 0..255 steps, as their integer maths.
static func _trunc_lerp(a: Color, b: Color, t: float) -> Color:
	var out := Color()
	for c in 4:
		var lo := roundi(a[c] * 255.0)
		var hi := roundi(b[c] * 255.0)
		out[c] = (int((hi - lo) * t) + lo) / 255.0
	return out


## Channel `ch` of `values` at tick f: the Lagrange polynomial through all keys, truncated and
## clamped to 0..255.
func _lagrange(f: float, ch: int, values: PackedColorArray) -> float:
	var n := mini(keys.size(), values.size())
	var sum := 0.0
	for i in n:
		var w := 1.0
		for j in n:
			if j != i:
				w *= (f - keys[j]) / float(keys[i] - keys[j])
		sum += values[i][ch] * 255.0 * w
	return clampi(int(sum), 0, 255) / 255.0
