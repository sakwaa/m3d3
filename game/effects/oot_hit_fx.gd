class_name OotHitFx
extends Node3D
## Ocarina of Time / Majora's Mask's hit effects (notes: references/combat/oot_sword_trail_hit_fx.md),
## run at the games' 20 Hz:
##  - hit_mark(): the camera-facing flash where a blow lands - an 8-frame intensity flipbook
##    (a bright blob bursting into a starburst and breaking up; dust: a puff opening into a
##    ring), coloured mix(ENV, PRIM, texel) with prim / env easing to their targets over its
##    life, alpha noise-dithered. Types WHITE (flesh), METAL (armour, shields), RED, DUST (wood).
##  - clang(): a metal (or wood) hit's streaks - 16 flat glowing dashes shot out in random
##    directions, each head racing out and its tail chasing it, colour cyan / white -> yellow
##    -> orange / red over 8 ticks; metal also flashes a blue point light whose reach halves
##    each tick.
##  - blood(): 27 droplets flung out under gravity for 17 ticks, flickering in size, fading by
##    darkening (blue: most enemies; green, red, water).
## Sizes are in the games' units (UNIT metres each: an adult Master Sword is 40).
## Textures are drawn here (no game assets).

enum Mark { WHITE, DUST, RED, METAL }
enum Blood { BLUE, GREEN, RED, WATER }

const HZ := 20.0
## Metres per game unit (OoT's Master Sword is 40 units; ours ~0.66 m).
const UNIT := 0.0165
const SHADER := preload("res://game/effects/n64_hit_fx.gdshader")

# Hit mark: [prim start, env start, prim target, env target] (RGB 0..255).
const MARK_COLOURS := {
	Mark.WHITE: [Color8(255, 255, 255), Color8(255, 255, 0), Color8(255, 255, 255), Color8(255, 0, 0)],
	Mark.DUST: [Color8(255, 200, 100), Color8(200, 150, 0), Color8(150, 100, 0), Color8(100, 50, 0)],
	Mark.RED: [Color8(255, 255, 255), Color8(255, 0, 0), Color8(255, 255, 0), Color8(255, 0, 0)],
	Mark.METAL: [Color8(255, 255, 255), Color8(0, 255, 200), Color8(255, 255, 255), Color8(150, 0, 255)],
}
# Clang streaks: prim (core) / env (edge) at start, mid, end.
const STREAK_PRIM := [Color8(0, 200, 255, 255), Color8(255, 255, 128, 255), Color8(255, 64, 0, 200)]
const STREAK_ENV := [Color8(255, 255, 255, 255), Color8(255, 255, 0, 255), Color8(255, 0, 0, 255)]
# Blood: corner 0 start, corners 1-3 start, end c0/c1, end c2/c3.
const BLOOD_COLOURS := {
	Blood.BLUE: [Color8(10, 10, 200), Color8(0, 0, 128), Color8(0, 0, 32), Color8(0, 0, 64)],
	Blood.GREEN: [Color8(10, 200, 10), Color8(0, 128, 0), Color8(0, 32, 0), Color8(0, 64, 0)],
	Blood.RED: [Color8(128, 0, 64), Color8(255, 128, 0), Color8(64, 0, 32), Color8(128, 0, 64)],
	Blood.WATER: [Color8(255, 255, 255), Color8(100, 100, 100), Color8(50, 50, 50), Color8(0, 0, 0)],
}

enum Kind { MARK, STREAKS, BLOOD }

static var _circle: ImageTexture
static var _marks := {}  # Mark -> ImageTexture (8 frames side by side)

var _kind := Kind.MARK
var _type := 0
var _tick := 0.0
var _timer := 0      # ticks run
var _life := 8       # ticks it lasts
var _prim := Color.WHITE
var _env := Color.WHITE
var _parts: Array = []
var _light: OmniLight3D
var _im := ImmediateMesh.new()
var _mat := ShaderMaterial.new()
var _rng := RandomNumberGenerator.new()


## The flash where a blow lands.
static func hit_mark(parent: Node, at: Vector3, type := Mark.WHITE, scale_ := 1.0) -> OotHitFx:
	var fx := _make(parent, at, Kind.MARK)
	fx._type = type
	fx._life = 16 if type == Mark.DUST else 8
	var c: Array = MARK_COLOURS[type]
	fx._prim = c[0]
	fx._env = c[1]
	fx.scale = Vector3.ONE * scale_
	fx._mat.set_shader_parameter(&"tex", _mark_texture(type))
	fx._mat.set_shader_parameter(&"mode", 0)
	return fx


## A metal (light flash) or wood hit's 16 streaks.
static func clang(parent: Node, at: Vector3, metal := true) -> OotHitFx:
	var fx := _make(parent, at, Kind.STREAKS)
	fx._life = 8
	for i in 16:
		var speed := 35.0 * (0.5 + 0.5 * fx._rng.randf())
		fx._parts.append({dir = _random_dir(fx._rng), yaw = fx._rng.randf() * TAU, pitch = fx._rng.randf() * TAU,
			v0 = speed, head = 0.0, tail = 0.0, hv = speed, tv = 0.0, tail_moving = false})
	fx._mat.set_shader_parameter(&"tex", _circle_texture())
	fx._mat.set_shader_parameter(&"mode", 1)
	if metal:
		fx._light = OmniLight3D.new()
		fx._light.light_color = Color(0.0, 0.5, 1.0)
		fx._light.omni_range = 300.0 * UNIT
		fx._light.light_energy = 2.0
		fx.add_child(fx._light)
	return fx


## Droplets flung from a wound.
static func blood(parent: Node, at: Vector3, type := Blood.BLUE) -> OotHitFx:
	var fx := _make(parent, at, Kind.BLOOD)
	fx._type = type
	fx._life = 16
	for i in 27:
		var v := Vector3(fx._rng.randf() - 0.5, fx._rng.randf() - 0.5, fx._rng.randf() - 0.5)
		v = v.normalized() if v.length() > 0.001 else Vector3.UP
		fx._parts.append({pos = Vector3.ZERO, vel = v * 8.0, size = 1.5 + 2.5 * fx._rng.randf()})
	fx._mat.set_shader_parameter(&"tex", _circle_texture())
	fx._mat.set_shader_parameter(&"mode", 2)
	return fx


static func _make(parent: Node, at: Vector3, kind: Kind) -> OotHitFx:
	var fx := OotHitFx.new()
	fx._kind = kind
	fx._rng.randomize()
	parent.add_child(fx)
	fx.global_position = at
	return fx


static func _random_dir(rng: RandomNumberGenerator) -> Vector3:
	var v := Vector3(rng.randf() - 0.5, rng.randf() - 0.5, rng.randf() - 0.5)
	return v.normalized() if v.length() > 0.001 else Vector3.UP


func _init() -> void:
	_mat.shader = SHADER
	var mi := MeshInstance3D.new()
	mi.mesh = _im
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _process(delta: float) -> void:
	_tick += delta * HZ
	while _tick >= 1.0:
		_tick -= 1.0
		_step()
		if _timer > _life:
			queue_free()
			return
	_draw()


## One 20 Hz tick.
func _step() -> void:
	_timer += 1
	match _kind:
		Kind.MARK:
			# From the second tick, colours ease so they land on the target on the last
			# (c += (target - c) / (life + 1), life counting down).
			if _timer > 1:
				var c: Array = MARK_COLOURS[_type]
				var left := float(maxi(_life - _timer, 0) + 1)
				_prim += (c[2] - _prim) / left
				_env += (c[3] - _env) / left
		Kind.STREAKS:
			for p in _parts:
				p.hv = maxf(p.hv - 2.1, 0.0)
				p.head += p.hv
				if p.tail_moving:
					p.tv = maxf(p.tv - 2.1, 0.0)
					p.tail += p.tv
				elif p.head - p.tail > 30.0:
					p.tail_moving = true
					p.tv = p.v0
			if _light:
				_light.omni_range *= 0.5
				if _light.omni_range < 0.05:
					_light.queue_free()
					_light = null
		Kind.BLOOD:
			for p in _parts:
				p.pos += p.vel
				p.vel.y -= 1.0
				p.size = 1.5 + 2.5 * _rng.randf()


func _draw() -> void:
	_im.clear_surfaces()
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var right := cam.global_transform.basis.x
	var up := cam.global_transform.basis.y
	var inv := global_transform.basis.inverse()
	right = inv * right
	up = inv * up
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	match _kind:
		Kind.MARK:
			var frame := (_timer - 1) / 2 if _type == Mark.DUST else _timer - 1
			_mat.set_shader_parameter(&"frame", clampi(frame, 0, 7))
			_mat.set_shader_parameter(&"prim", _prim)
			_mat.set_shader_parameter(&"env", _env)
			# (-11 .. 12 units, x3)
			var lo := -11.0 * 3.0 * UNIT
			var hi := 12.0 * 3.0 * UNIT
			_quad(right * lo + up * lo, right * hi + up * lo, right * hi + up * hi, right * lo + up * hi, Color.WHITE)
		Kind.STREAKS:
			var half := 4.0
			var k := float(_timer) / half
			var prim: Color = STREAK_PRIM[0].lerp(STREAK_PRIM[1], k) if k <= 1.0 else STREAK_PRIM[1].lerp(STREAK_PRIM[2], minf(k - 1.0, 1.0))
			var env: Color = STREAK_ENV[0].lerp(STREAK_ENV[1], k) if k <= 1.0 else STREAK_ENV[1].lerp(STREAK_ENV[2], minf(k - 1.0, 1.0))
			_mat.set_shader_parameter(&"prim", prim)
			_mat.set_shader_parameter(&"env", env)
			for p in _parts:
				# A flat card along its own X (yaw about Y, then pitch about Z), from tail to head.
				var b := Basis(Vector3.UP, p.yaw) * Basis(Vector3.BACK, p.pitch)
				var along: Vector3 = b.x
				var side: Vector3 = b.y * 0.64 * UNIT
				var a: Vector3 = along * p.tail * UNIT
				var h: Vector3 = along * maxf(p.head, p.tail + 1.0) * UNIT
				_quad(a - side, h - side, h + side, a + side, Color.WHITE)
		Kind.BLOOD:
			var c: Array = BLOOD_COLOURS[_type]
			var k := clampf(float(_timer) / 16.0, 0.0, 1.0)
			var c0: Color = c[0].lerp(c[2], k)
			var c1: Color = c[1].lerp(c[2], k)
			var c2: Color = c[1].lerp(c[3], k)
			for p in _parts:
				var s: float = p.size * 0.5 * UNIT
				var o: Vector3 = p.pos * UNIT
				_quad(o - right * s - up * s, o + right * s - up * s, o + right * s + up * s, o - right * s + up * s, c0, c1, c2, c2)
	_im.surface_end()


func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, ca: Color, cb := Color(-1, 0, 0), cc := Color(-1, 0, 0), cd := Color(-1, 0, 0)) -> void:
	if cb.r < 0.0:
		cb = ca
		cc = ca
		cd = ca
	var uv := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	var pts := [a, b, c, d]
	var cols := [ca, cb, cc, cd]
	for i in [0, 1, 2, 0, 2, 3]:
		_im.surface_set_color(cols[i])
		_im.surface_set_uv(uv[i])
		_im.surface_add_vertex(pts[i])


# --- Textures (drawn, not taken from the games) ------------------------------------------

## A soft-edged disc filling most of a 32 x 32 tile (I8).
static func _circle_texture() -> ImageTexture:
	if _circle == null:
		var img := Image.create(32, 32, false, Image.FORMAT_L8)
		for y in 32:
			for x in 32:
				var r := Vector2(x - 15.5, y - 15.5).length() / 15.5
				var v := clampf((1.0 - r) / 0.35, 0.0, 1.0)
				img.set_pixel(x, y, Color(v, v, v))
		_circle = ImageTexture.create_from_image(img)
	return _circle


## 8 frames of 32 x 24 (I4) side by side: WHITE / METAL / RED a blob bursting into a
## starburst of thin rays that fades and breaks up (RED: into speckles), DUST a lumpy puff
## opening into a ring and drifting apart. The last frame is empty.
static func _mark_texture(type: int) -> ImageTexture:
	var key := Mark.WHITE if type == Mark.METAL else type
	if _marks.has(key):
		return _marks[key]
	var img := Image.create(32 * 8, 24, false, Image.FORMAT_L8)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.25
	noise.seed = 11 + key
	var rays := 9
	for f in 8:
		var t := f / 7.0
		for y in 24:
			for x in 32:
				var p := Vector2(x - 15.5, (y - 11.5) * 32.0 / 24.0)
				var r := p.length() / 15.5
				var ang := atan2(p.y, p.x)
				var n := noise.get_noise_3d(x, y, f * 7.0) * 0.5 + 0.5
				var v := 0.0
				if f == 7:
					v = 0.0
				elif key == Mark.DUST:
					var ring := 0.25 + 0.55 * t
					v = clampf(1.0 - absf(r - ring) / (0.22 + 0.1 * t), 0.0, 1.0) * (0.6 + 0.6 * n) * (1.0 - t * 0.8)
				else:
					var core := clampf(1.0 - r / maxf(0.55 - 0.45 * t, 0.05), 0.0, 1.0) * (0.7 + 0.5 * n)
					var ray_w := pow(maxf(cos(ang * rays * 0.5 + key), 0.0), 18.0)
					var reach := clampf(t * 2.2, 0.2, 1.0)
					var ray := ray_w * clampf(1.0 - r / reach, 0.0, 1.0) * (1.0 - smoothstep(0.4, 0.9, t))
					v = maxf(core * (1.0 - t), ray)
					if key == Mark.RED and t > 0.3:
						v *= 1.0 if n >= 0.62 else 0.0  # (scattering into speckles)
					elif t > 0.55:
						v *= smoothstep(0.35, 0.6, n)  # (breaking up)
				v = roundf(clampf(v, 0.0, 1.0) * 15.0) / 15.0
				img.set_pixel(f * 32 + x, y, Color(v, v, v))
	_marks[key] = ImageTexture.create_from_image(img)
	return _marks[key]
