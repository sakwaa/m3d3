class_name SwordTrail
extends MeshInstance3D
## The smear a blade leaves through a swing (OoT remake: a wide pale crescent the size of the
## whole arc, gone a few frames after). Samples the blade's base and tip (`blade`'s local
## +Y from `base` to `tip`) every frame while `swinging` says so, and draws the band between
## the last LIFE seconds of samples (Catmull-Rom smoothed, so a fast swing still reads as an
## arc), fading with age and towards the hilt.

const LIFE := 0.1
const STEPS := 4  # smoothing points between samples

var blade: Node3D
## True while the trail should draw (e.g. an attack's active window).
var swinging: Callable
## The actor swinging: its hitstop freezes the smear too (it hangs in the air, as in the remake).
var actor: Actor
var base := 0.15
var tip := 0.66
var color := Color(1.0, 1.0, 1.0, 0.75)

var _samples: Array = []  # [time, base (world), tip (world)]
var _time := 0.0
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
	_time += delta
	if is_instance_valid(blade) and blade.is_visible_in_tree() and swinging.is_valid() and swinging.call():
		var xf := blade.global_transform
		_samples.append([_time, xf * Vector3(0, base, 0), xf * Vector3(0, tip, 0)])
	while not _samples.is_empty() and _time - _samples[0][0] > LIFE:
		_samples.pop_front()


func _process(_delta: float) -> void:
	global_transform = Transform3D.IDENTITY
	_im.clear_surfaces()
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
