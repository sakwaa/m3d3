class_name ScreenDistortion
extends RefCounted
## Ocarina of Time / Majora's Mask's screen distortion (notes:
## references/combiners/mm_animated_materials_distortion.md): a warp between the view and the projection - an
## uneven stretch of the picture about its centre whose axis can turn - that makes hot rooms
## shimmer, water entry lurch, Jabu-Jabu's belly breathe, the Song of Time swim. Both games
## drive it with two phase angles stepping each 20 Hz tick:
##   orientation = (cos(depth) rx, sin(depth) ry, sin(screen) rz) x fXY / fZ
##   scale       = (1 + sin(screen) sx fXY, 1 + cos(screen) sy fXY, 1 + cos(depth) sz fZ)
## and the current warp follows that target by `speed` a tick (above 1: it overshoots and
## rings). Here the warp reaches the shaders as a 2 x 2 matrix on the picture (global
## n64_distort, applied in n64_snap: level, actors, trees, grass, props): the stretch and its
## turn about the view axis; turns about the other two axes (only the Song of Time uses them,
## for a depth skew) are left out. RenderScale ticks it.

enum Kind {
	NONE,
	HOT_ROOM,        ## OoT: about +-1 % squash flickering every couple of ticks (phases keep going)
	UNDERWATER,      ## OoT weak underwater: slow (1 s) sway, stronger deeper / moving (`factor`)
	WATER_ENTRY,     ## OoT / MM: a big lurch fading over 4 s (80 ticks)
	JABU,            ## OoT Jabu-Jabu's belly: breathes, 1.8 s loop
	SONG_OF_TIME,    ## MM: strong swimming warp (until released)
	MASK_TRANSFORM,  ## MM: a slow growing +-30 % squash, its axis turning
	BOSS_WARP,       ## MM: a huge vertical stretch (0.75 s)
	HIT_PULSE,       ## MM Zora kick / Goron pound: a short ringing pulse (0.6 s)
}

const HZ := 20.0
# Kind -> [depth step deg, screen step deg, rot (deg) xyz, scale xyz, speed, duration ticks
# (-1: until released), phases reset each tick, start phases (binang) depth / screen]
const PRESETS := {
	Kind.HOT_ROOM: [0.0, 150.0, Vector3.ZERO, Vector3(-0.01, 0.01, 0.01), 0.6, -1, false, 0x3F0, 0x156],
	Kind.UNDERWATER: [-0.81, -18.5, Vector3.ZERO, Vector3(0.09, 0.09, 0.01), 0.08, -1, false, 0x3F0, 0x156],
	Kind.WATER_ENTRY: [-112.0, -90.0, Vector3.ZERO, Vector3(-0.3, 0.3, 0.2), 0.2, 80, false, 0x760, 0x1BC],
	Kind.JABU: [10.0, 10.0, Vector3.ZERO, Vector3(0.016, 0.008, 0.02), 0.95, -1, false, 538, 4272],
	Kind.SONG_OF_TIME: [-106.0, 157.8, Vector3(0.2, 1.7, -2.9), Vector3(-0.6, -0.7, 0.6), 0.2, -1, false, 0x9C4, 0xBB8],
	Kind.MASK_TRANSFORM: [-5.0, 5.0, Vector3(0, 0, 2.0), Vector3(0.3, 0.3, 0.0), 0.1, 46, false, 0x1FC, 0x156],
	Kind.BOSS_WARP: [0.0, 50.0 / 15.0, Vector3.ZERO, Vector3(0.01, 100.0, 0.0), 0.2, 15, false, 0, 0],
	Kind.HIT_PULSE: [0.0, 150.0, Vector3.ZERO, Vector3(0.03, 0.03, 0.01), 1.3, 12, false, 0x9C4, 0xBB8],
}

static var kind := Kind.NONE
## Strength for UNDERWATER (OoT: deeper and faster-moving camera = stronger, 0..0.9).
static var factor := 0.5
static var _timer := 0
static var _duration := 0
static var _depth := 0.0   # phases (degrees)
static var _screen := 0.0
static var _tick := 0.0
static var _cur_rot := Vector3.ZERO
static var _cur_scale := Vector3.ONE
static var _speed := 0.0
static var _clearing := false


## Starts `k` (replacing a weaker or equal one, as MM's priority does by order here: later
## kinds in the list win). `ticks` overrides the preset's duration (20 a second).
static func request(k: Kind, ticks := -2) -> void:
	if k == Kind.NONE:
		release()
		return
	if kind != Kind.NONE and k < kind and _timer != 0:
		return
	var p: Array = PRESETS[k]
	kind = k
	_duration = p[5] if ticks == -2 else ticks
	_timer = _duration
	_depth = p[7] * 360.0 / 65536.0
	_screen = p[8] * 360.0 / 65536.0
	_clearing = false


## Ends `k` (or whatever runs): the warp snaps back to none.
static func release(k := Kind.NONE) -> void:
	if k != Kind.NONE and k != kind:
		return
	kind = Kind.NONE
	_clearing = true


## Advances at 20 Hz (RenderScale, unless paused) and publishes the warp (`aspect`: the
## view's width / height).
static func update(delta: float, aspect: float) -> void:
	_tick += delta * HZ
	while _tick >= 1.0:
		_tick -= 1.0
		_step()
	var m := _picture_matrix(aspect)
	RenderingServer.global_shader_parameter_set(&"n64_distort", m)


static func _step() -> void:
	if kind == Kind.NONE:
		if _clearing:
			_cur_rot = Vector3.ZERO
			_cur_scale = Vector3.ONE
			_clearing = false
		return
	var p: Array = PRESETS[kind]
	var f_xy := 1.0
	var f_z := 1.0
	var speed: float = p[4]
	match kind:
		Kind.UNDERWATER:
			f_xy = factor
			f_z = factor
			speed *= factor
		Kind.WATER_ENTRY:
			f_xy = float(_timer) / maxf(_duration, 1)
			f_z = f_xy
		Kind.MASK_TRANSFORM, Kind.BOSS_WARP:
			f_xy = float(_duration - _timer) / maxf(_duration, 1)
			f_z = f_xy
		Kind.HIT_PULSE:
			f_xy = float(_timer) / maxf(_duration, 1) if _timer < 4 else 0.0
			f_z = f_xy
	_depth = fposmod(_depth + p[0], 360.0)
	_screen = fposmod(_screen + p[1], 360.0)
	var d := deg_to_rad(_depth)
	var s := deg_to_rad(_screen)
	var rot: Vector3 = p[2]
	var sc: Vector3 = p[3]
	var target_rot := Vector3(cos(d) * deg_to_rad(rot.x) * f_xy, sin(d) * deg_to_rad(rot.y) * f_xy, sin(s) * deg_to_rad(rot.z) * f_z)
	var target_scale := Vector3(1.0 + sin(s) * sc.x * f_xy, 1.0 + cos(s) * sc.y * f_xy, 1.0 + cos(d) * sc.z * f_z)
	if kind == Kind.JABU:
		# (its own: sx with sin B, sy cos B, sz cos A)
		target_scale = Vector3(1.0 + 0.016 * sin(s), 1.0 + 0.008 * cos(s), 1.0 + 0.02 * cos(d))
	_cur_rot += (target_rot - _cur_rot) * speed
	_cur_scale += (target_scale - _cur_scale) * speed
	if _duration > 0:
		_timer -= 1
		if _timer <= 0:
			release()


## The eye-space warp R S R^-1 (turn about the view axis only) as a 2 x 2 on the picture:
## columns (x, y), (z, w).
static func _picture_matrix(aspect: float) -> Vector4:
	var c := cos(_cur_rot.z)
	var sn := sin(_cur_rot.z)
	var sx := _cur_scale.x
	var sy := _cur_scale.y
	# R S R^-1 in eye xy
	var m00 := c * c * sx + sn * sn * sy
	var m01 := c * sn * (sx - sy)
	var m11 := sn * sn * sx + c * c * sy
	var sz := maxf(_cur_scale.z, 0.05)
	# To the picture: diag(P00, P11) M diag(1/P00, 1/P11) / sz, P00 / P11 = 1 / aspect.
	return Vector4(m00 / sz, m01 * aspect / sz, m01 / aspect / sz, m11 / sz)
