class_name Sandstorm
extends MeshInstance3D
## OoT / MM's sandstorm layer (n64_sandstorm.gdshader; notes references/sky/oot_mm_env_fx.md),
## at the games' 20 Hz:
##  - its two alphas (primA: how thick; envA: which layer's alpha leads) step 9 a tick
##    towards their targets: ACTIVE breathes primA 73 -> 137 -> 73 over 6.4 s (OoT), FILL
##    thickens to a solid wall (255 / 255), DISSIPATE thins it away;
##  - it scrolls slower the thicker it is (k = min((512 - primA - envA) x 3 / 128, 6) a tick;
##    a full storm stands still), the two layers at different rates and directions;
##  - colours from the time of day (dawn / day / dusk / night), ENV pulled towards PRIM as it
##    thickens (a full storm is one flat colour). `haze`: MM's neutral white over grey (its
##    sea murk, snow haze, wind) instead of sand.
## DynamicSky owns one and drives it from the weather (WeatherPreset.sandstorm).

enum State { OFF, FILL, ACTIVE, DISSIPATE }
const HZ := 20.0
const STEP := 9
# dawn, day, dusk, night: [prim, env]
const SAND := [[Color8(210, 156, 85), Color8(155, 106, 35)], [Color8(255, 200, 100), Color8(200, 150, 50)],
	[Color8(225, 160, 50), Color8(170, 110, 0)], [Color8(105, 90, 40), Color8(50, 40, 0)]]
const HAZE := [Color8(255, 255, 255), Color8(100, 100, 100)]

var state := State.OFF
## MM's neutral haze colours instead of sand.
var haze := false
## 0..1: scales ACTIVE's thickness (weather strength).
var strength := 1.0
var hour := 12.0

var _prim_a := 0
var _env_a := 0
var _scroll := 0
var _frames := 0
var _tick := 0.0
var _mat := ShaderMaterial.new()


func _init() -> void:
	var q := QuadMesh.new()
	q.size = Vector2(2, 2)
	mesh = q
	_mat.shader = preload("res://game/sky/n64_sandstorm.gdshader")
	_mat.set_shader_parameter(&"noise0", _noise(5, false))
	_mat.set_shader_parameter(&"noise1", _noise(9, true))
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	visible = false


func _process(delta: float) -> void:
	if get_tree().paused:
		return
	_tick += delta * HZ
	while _tick >= 1.0:
		_tick -= 1.0
		_step()
	visible = _prim_a > 0
	if visible:
		_publish()


func _step() -> void:
	_frames += 1
	var prim_t := 0
	var env_t := 0
	match state:
		State.FILL:
			prim_t = 255
			env_t = 255 if _prim_a >= 255 else 128
		State.ACTIVE:
			var t := _frames % 128
			if t > 64:
				t = 128 - t
			prim_t = int((t + 73) * strength)
			env_t = 128
		State.DISSIPATE, State.OFF:
			prim_t = 255 if _env_a > 128 else _env_a >> 1
			env_t = 0
	_prim_a = _toward(_prim_a, prim_t)
	_env_a = _toward(_env_a, env_t)
	var k := mini(int((512 - (_prim_a + _env_a)) * 3 / 128.0), 6)
	_scroll = (_scroll + maxi(k, 0)) & 0xFFFF


static func _toward(v: int, target: int) -> int:
	if absi(target - v) <= STEP:
		return target
	return v + (STEP if target > v else -STEP)


func _publish() -> void:
	var k := clampf((512 - (_prim_a + _env_a)) * 3 / 128.0, 0.0, 6.0)
	var prim: Color
	var env: Color
	if haze:
		prim = HAZE[0]
		env = HAZE[1]
	else:
		# dawn 6, day 12, dusk 18, night 0/24: lerp between the neighbouring keys
		var h := fposmod(hour, 24.0)
		var idx := [3, 0, 1, 2, 3]  # 0h night, 6h dawn, 12h day, 18h dusk, 24h night
		var seg := floori(h / 6.0)
		var t := (h - seg * 6.0) / 6.0
		var a: Array = SAND[idx[seg]]
		var b: Array = SAND[idx[seg + 1]]
		prim = (a[0] as Color).lerp(b[0], t)
		env = (a[1] as Color).lerp(b[1], t)
	env = Color((env.r * k + prim.r * (6.0 - k)) / 6.0, (env.g * k + prim.g * (6.0 - k)) / 6.0, (env.b * k + prim.b * (6.0 - k)) / 6.0)
	_mat.set_shader_parameter(&"prim", Color(prim, _prim_a / 255.0))
	_mat.set_shader_parameter(&"env", Color(env, _env_a / 255.0))
	# Offsets in quarter texels: layer 0 S += scroll x 11/6; layer 1 S scroll x 9/6, T runs back.
	_mat.set_shader_parameter(&"offset0", Vector2(fposmod(_scroll * 11.0 / 6.0 / 4.0 / 64.0, 1.0), 0.0))
	_mat.set_shader_parameter(&"offset1", Vector2(fposmod(_scroll * 9.0 / 6.0 / 4.0 / 64.0, 1.0),
		fposmod((4095 - _scroll) / 4.0 / 32.0, 1.0)))


## Blurry 64 x 32 noise (an I8 or IA8 texture: a second, different field in alpha).
static func _noise(seed_: int, two: bool) -> ImageTexture:
	var n := FastNoiseLite.new()
	n.seed = seed_
	n.frequency = 0.09
	var n2 := FastNoiseLite.new()
	n2.seed = seed_ + 100
	n2.frequency = 0.07
	var img := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 64:
			# (tiling: blend the field with its wrapped copies)
			var v := _tile(n, x, y)
			var a := _tile(n2, x, y) if two else v
			img.set_pixel(x, y, Color(v, v, v, a))
	return ImageTexture.create_from_image(img)


static func _tile(n: FastNoiseLite, x: int, y: int) -> float:
	var fx := x / 64.0
	var fy := y / 32.0
	var v := n.get_noise_2d(x, y) * (1.0 - fx) * (1.0 - fy) + n.get_noise_2d(x - 64, y) * fx * (1.0 - fy) \
		+ n.get_noise_2d(x, y - 32) * (1.0 - fx) * fy + n.get_noise_2d(x - 64, y - 32) * fx * fy
	return clampf(v * 1.4 + 0.5, 0.0, 1.0)
