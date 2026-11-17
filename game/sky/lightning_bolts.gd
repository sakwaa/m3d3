class_name LightningBolts
extends MeshInstance3D
## OoT / MM's lightning bolts (Environment_DrawLightning; notes references/sky/oot_mm_env_fx.md):
## up to 3 camera-facing bolts, far ahead of the camera (9500 units), their tops 4000-5000
## units up, scattered +-2500 and tilted up to 20 degrees, each 680 x 9500 units hanging down;
## they appear 3, 6 and 9 ticks after the strike and play 8 frames (a thick branching bolt,
## thinner and broken, then sparks), one a tick. Colour mix(cyan, white, texel), alpha half
## the texel at most; behind mountains and buildings (depth-tested), not fogged.
## DynamicSky calls strike(n) with its flash. Textures are drawn here.

const HZ := 20.0
const UNIT := 0.0165  # metres per game unit
const SHADER := preload("res://game/sky/n64_lightning.gdshader")

var _bolts: Array = []  # {pos, tilt (Basis), delay, frame}
var _tick := 0.0
var _im := ImmediateMesh.new()
var _mat := ShaderMaterial.new()
var _rng := RandomNumberGenerator.new()
static var _tex: ImageTexture


func _init() -> void:
	mesh = _im
	_mat.shader = SHADER
	_mat.set_shader_parameter(&"frames", _frames_texture())
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	top_level = true
	custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	_rng.randomize()


## `n` bolts (1..3), staggered.
func strike(n: int) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var eye := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var d := Vector2(fwd.x, fwd.z)
	d = d.normalized() if d.length() > 0.001 else Vector2(0, -1)
	for i in mini(n, 3):
		var pos := Vector3(eye.x + d.x * 9500.0 * UNIT, (_rng.randf() * 1000.0 + 4000.0) * UNIT, eye.z + d.y * 9500.0 * UNIT)
		pos += Vector3((_rng.randf() - 0.5) * 5000.0, 0.0, (_rng.randf() - 0.5) * 5000.0) * UNIT
		var tilt := Basis(Vector3.RIGHT, deg_to_rad((_rng.randf() - 0.5) * 40.0)) * Basis(Vector3.BACK, deg_to_rad((_rng.randf() - 0.5) * 40.0))
		_bolts.append({pos = pos, tilt = tilt, delay = 3 * (i + 1), frame = -1})


func _process(delta: float) -> void:
	global_transform = Transform3D.IDENTITY
	_tick += delta * HZ
	while _tick >= 1.0:
		_tick -= 1.0
		for b in _bolts:
			if b.delay > 0:
				b.delay -= 1
				if b.delay == 0:
					b.frame = 0
			else:
				b.frame += 1
		_bolts = _bolts.filter(func(b): return b.frame < 8)
	_im.clear_surfaces()
	var cam := get_viewport().get_camera_3d()
	if cam == null or _bolts.is_empty():
		return
	var right := cam.global_transform.basis.x
	var up := Vector3.UP
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in _bolts:
		if b.frame < 0:
			continue
		var tilt: Basis = b.tilt
		var r: Vector3 = tilt * right
		var u: Vector3 = tilt * up
		var top: Vector3 = b.pos
		# x -15 .. 16, y 0 .. -95 (x22, x100 units)
		var x0 := r * (-15.0 * 22.0 * UNIT)
		var x1 := r * (16.0 * 22.0 * UNIT)
		var y1 := u * (-95.0 * 100.0 * UNIT)
		var f := float(b.frame)
		var uv := [Vector2(f / 8.0, 0), Vector2((f + 1) / 8.0, 0), Vector2((f + 1) / 8.0, 1), Vector2(f / 8.0, 1)]
		var pts := [top + x0, top + x1, top + x1 + y1, top + x0 + y1]
		for i in [0, 1, 2, 0, 2, 3]:
			_im.surface_set_uv(uv[i])
			_im.surface_add_vertex(pts[i])
	_im.surface_end()


## 8 frames of 32 x 96 (I4) side by side: frames 1-3 a thick jagged bolt with branches,
## 4-6 thinner and broken, 7-8 scattered sparks.
static func _frames_texture() -> ImageTexture:
	if _tex:
		return _tex
	var w := 32
	var h := 96
	var img := Image.create(w * 8, h, false, Image.FORMAT_L8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	# One main path and two branches, reused (redrawn thinner / broken / as sparks).
	var path := []
	var x := 16.0
	for y in h:
		x = clampf(x + rng.randf_range(-1.6, 1.6) + (0.9 if rng.randf() < 0.06 else 0.0) * signf(rng.randf() - 0.5) * 3.0, 3.0, w - 4.0)
		path.append(x)
	var branches := []
	for bi in 2:
		var start := rng.randi_range(20, 60)
		var bx: float = path[start]
		var dirx := -1.0 if bi == 0 else 1.0
		var pts := []
		for y in range(start, mini(start + 26, h)):
			bx = clampf(bx + dirx * rng.randf_range(0.2, 1.4) + rng.randf_range(-0.6, 0.6), 1.0, w - 2.0)
			pts.append([y, bx])
		branches.append(pts)
	for f in 8:
		var width := 2.2 if f < 3 else 1.3
		for y in h:
			var cx: float = path[y]
			var keep := f < 3 or (f < 6 and int(y / (6 + f)) % 3 != 0) or (f >= 6 and rng.randf() < 0.08)
			if not keep:
				continue
			for xx in w:
				var d := absf(xx - cx)
				var v := clampf(1.0 - d / width, 0.0, 1.0)
				if f >= 6:
					v *= 0.8 if d < 1.0 else 0.0
				if v > 0.0:
					var m := maxf(v, img.get_pixel(f * w + xx, y).r)
					img.set_pixel(f * w + xx, y, Color(m, m, m))
		if f < 5:
			for br in branches:
				for p in br:
					var px := int(p[1])
					var py: int = p[0]
					if f >= 3 and py % 4 == 0:
						continue
					var m := maxf(0.8, img.get_pixel(f * w + px, py).r)
					img.set_pixel(f * w + px, py, Color(m, m, m))
	# (I4: 16 grey steps)
	for yy in h:
		for xx in w * 8:
			var v := roundf(img.get_pixel(xx, yy).r * 15.0) / 15.0
			img.set_pixel(xx, yy, Color(v, v, v))
	_tex = ImageTexture.create_from_image(img)
	return _tex
