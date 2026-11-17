class_name SwordTrail
extends MeshInstance3D
## The ribbon a blade leaves through a swing. Two looks (`style`):
##  - OOT (default): Ocarina of Time / Majora's Mask's own trail (z_eff_blure.c, the player's
##    "smooth" draw; notes in references/combat/oot_sword_trail_hit_fx.md). At the game's
##    20 Hz it samples the blade's hand-end and tip whenever the blade has moved, keeps each
##    sample 4 ticks (born already a quarter faded), and draws white: tip opaque, hilt a
##    quarter, fading linearly with age; between samples a Hermite curve of 7 pieces unless
##    the path turns sharply (>= 120 degrees, or the tip and hilt move 45 degrees apart: kept
##    straight). Untextured, alpha-blended, depth-tested, no depth write, both sides.
##  - REMAKE: the OoT remake's wide pale crescent (every physics tick, 0.1 s, Catmull-Rom).

enum Style { OOT, REMAKE }
static var style := Style.OOT

# OoT
const OOT_HZ := 20.0
const OOT_DURATION := 4  # elemDuration (ticks)
const OOT_MAX := 16      # elements
const OOT_PIECES := 7    # Hermite sub-quads per segment
const OOT_TIP := Color(1, 1, 1, 1.0)
const OOT_HILT := Color(1, 1, 1, 64.0 / 255.0)
# REMAKE
const LIFE := 0.1
const STEPS := 4  # smoothing points between samples

var blade: Node3D
## True while the trail should take samples (a swing).
var swinging: Callable
## The actor swinging: its hitstop freezes the trail too.
var actor: Actor
## Blade local +Y: where the ribbon starts (the hand end) and ends (the tip). OoT runs it
## from the grip; the remake from just past the guard.
var base := 0.15
var tip := 0.66
var color := Color(1.0, 1.0, 1.0, 0.75)

var _samples: Array = []  # REMAKE: [time, base, tip]; OOT: [timer (ticks), tip, base]
var _time := 0.0
var _tick := 0.0  # OOT: time into the current 20 Hz tick
var _last := []   # OOT: the blade's last sampled [tip, base]
var _im := ImmediateMesh.new()


func _init(p_blade: Node3D = null, p_swinging := Callable(), p_actor: Actor = null) -> void:
	blade = p_blade
	swinging = p_swinging
	actor = p_actor
	name = "SwordTrail"
	top_level = true
	mesh = _im
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.vertex_color_use_as_albedo = true
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material_override = m


## Samples on the physics tick (steady however slowly frames draw), drawn each frame.
func _physics_process(delta: float) -> void:
	if actor and actor.in_hitstop():
		return
	if style == Style.OOT:
		_oot_step(delta)
		return
	_time += delta
	if _active():
		var xf := blade.global_transform
		_samples.append([_time, xf * Vector3(0, base, 0), xf * Vector3(0, tip, 0)])
	while not _samples.is_empty() and (_samples[0].size() != 3 or _time - _samples[0][0] > LIFE):
		_samples.pop_front()


func _active() -> bool:
	return is_instance_valid(blade) and blade.is_visible_in_tree() and swinging.is_valid() and swinging.call()


func _process(_delta: float) -> void:
	global_transform = Transform3D.IDENTITY
	_im.clear_surfaces()
	if style == Style.OOT:
		_oot_draw()
		return
	if _samples.size() < 2:
		return
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var n := _samples.size()
	for i in n - 1:
		for s in STEPS:
			var t := float(s) / STEPS
			_vertex(i, t)
	_vertex(n - 2, 1.0)
	_im.surface_end()


# --- OoT --------------------------------------------------------------------------------

## EffectBlure_Update + the player's AddVertex, once per 20 Hz tick.
func _oot_step(delta: float) -> void:
	_tick += delta * OOT_HZ
	while _tick >= 1.0:
		_tick -= 1.0
		for s in _samples:
			s[0] = mini(s[0] + 1, OOT_DURATION + 1)
		if not _samples.is_empty() and _samples[0][0] > OOT_DURATION:
			_samples.pop_front()  # (one a tick)
		if _active():
			var xf := blade.global_transform
			var tp := xf * Vector3(0, tip, 0)
			var bs := xf * Vector3(0, 0.0, 0)  # (OoT: from the grip)
			# Only when the blade has moved (a still blade lets the trail drain away).
			var moved := _last.is_empty() or (_last[0] as Vector3).distance_to(tp) > 0.004 \
				or (_last[1] as Vector3).distance_to(bs) > 0.004
			if moved and _samples.size() < OOT_MAX:
				_samples.append([1, tp, bs])
			_last = [tp, bs]
		else:
			_last = []


func _oot_ratio(i: int) -> float:
	# (timer / duration; the tick's progress smooths the fade between ticks)
	return clampf((float(_samples[i][0]) + _tick) / OOT_DURATION, 0.0, 1.0)


## 2 = edge, 0 = sharp, 1 = smooth (EffectBlure_UpdateFlags).
func _oot_class(i: int) -> int:
	var n := _samples.size()
	if i == 0 or i == n - 1:
		return 2
	var tp: Vector3 = (_samples[i][1] as Vector3) - (_samples[i - 1][1] as Vector3)
	var tn: Vector3 = (_samples[i + 1][1] as Vector3) - (_samples[i][1] as Vector3)
	var bp: Vector3 = (_samples[i][2] as Vector3) - (_samples[i - 1][2] as Vector3)
	var bn: Vector3 = (_samples[i + 1][2] as Vector3) - (_samples[i][2] as Vector3)
	for v in [tp, tn, bp, bn]:
		if v.length_squared() < 1e-10:
			return 0
	if tp.normalized().dot(tn.normalized()) <= -0.5 or bp.normalized().dot(bn.normalized()) <= -0.5 \
			or tn.normalized().dot(bn.normalized()) <= 0.7071:
		return 0
	return 1


func _oot_draw() -> void:
	var n := _samples.size()
	if n < 2:
		return
	var cls := []
	for i in n:
		cls.append(_oot_class(i))
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in n - 1:
		var ra := _oot_ratio(i)
		var rb := _oot_ratio(i + 1)
		if cls[i] != 1 and cls[i + 1] != 1:
			_oot_quad(_samples[i][1], _samples[i][2], ra, _samples[i + 1][1], _samples[i + 1][2], rb)
			continue
		var prev := [[], []]
		for k in OOT_PIECES + 1:
			var t := float(k) / OOT_PIECES
			var tp := _hermite(i, 1, t, cls)
			var bs := _hermite(i, 2, t, cls)
			if k > 0:
				_oot_quad(prev[0], prev[1], lerpf(ra, rb, float(k - 1) / OOT_PIECES), tp, bs, lerpf(ra, rb, t))
			prev = [tp, bs]
	_im.surface_end()


## Point `slot` (1 tip, 2 base) on segment i -> i+1 at t: cubic Hermite, Catmull-Rom tangents
## (one-sided at edges).
func _hermite(i: int, slot: int, t: float, cls: Array) -> Vector3:
	var n := _samples.size()
	var p0: Vector3 = _samples[i][slot]
	var p1: Vector3 = _samples[i + 1][slot]
	var m0: Vector3 = 0.5 * (p1 - p0) if cls[i] == 2 or i == 0 else 0.5 * (p1 - (_samples[i - 1][slot] as Vector3))
	var m1: Vector3 = 0.5 * (p1 - p0) if cls[i + 1] == 2 or i + 2 >= n else 0.5 * ((_samples[i + 2][slot] as Vector3) - p0)
	var t2 := t * t
	var t3 := t2 * t
	return (2.0 * t3 - 3.0 * t2 + 1.0) * p0 + (3.0 * t2 - 2.0 * t3) * p1 + (t3 - 2.0 * t2 + t) * m0 + (t3 - t2) * m1


func _oot_quad(ta: Vector3, ba: Vector3, ra: float, tb: Vector3, bb: Vector3, rb: float) -> void:
	var cta := Color(OOT_TIP, OOT_TIP.a * (1.0 - ra))
	var cba := Color(OOT_HILT, OOT_HILT.a * (1.0 - ra))
	var ctb := Color(OOT_TIP, OOT_TIP.a * (1.0 - rb))
	var cbb := Color(OOT_HILT, OOT_HILT.a * (1.0 - rb))
	for v in [[ta, cta], [ba, cba], [tb, ctb], [ba, cba], [bb, cbb], [tb, ctb]]:
		_im.surface_set_color(v[1])
		_im.surface_add_vertex(v[0])


# --- REMAKE -----------------------------------------------------------------------------

func _vertex(i: int, t: float) -> void:
	var n := _samples.size()
	var a: Array = _samples[maxi(i - 1, 0)]
	var b: Array = _samples[i]
	var c: Array = _samples[i + 1]
	var d: Array = _samples[mini(i + 2, n - 1)]
	var age: float = _time - lerpf(b[0], c[0], t)
	var k := clampf(1.0 - age / LIFE, 0.0, 1.0)
	var lo := _cr(a[1], b[1], c[1], d[1], t)
	var hi := _cr(a[2], b[2], c[2], d[2], t)
	_im.surface_set_color(Color(color, 0.0))
	_im.surface_add_vertex(lo)
	_im.surface_set_color(Color(color, color.a * k * k))
	_im.surface_add_vertex(hi)


static func _cr(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (2.0 * p1 + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3)
