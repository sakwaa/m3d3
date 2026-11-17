@tool
class_name LensFlare
extends MeshInstance3D
## Ocarina of Time's sun flare (n64_lens_flare.gdshader; how OoT does it:
## references/sun_flare/OOT_SUN_FLARE.md): ten sprites from the sun back towards the middle
## of the view, and a warm full-screen glare when looking near the sun. Like OoT, whether the
## sun is clear is eased in and out (about a second) rather than popping: here a ray from the
## camera towards the sun (anything with collision) sets the target, and the shader's depth
## taps cut it off at things without collision (trees, mountains). DynamicSky owns one and
## feeds it the sun each frame.

const SHADER := preload("res://game/sky/n64_lens_flare.gdshader")
const COUNT := 10  # sprites (+ 1 glare quad)
## OoT ran its eases once a frame at 20 fps.
const OOT_FPS := 20.0
## How far the clear-sky ray reaches (metres).
const RAY_METRES := 400.0

var _mat: ShaderMaterial
var _dir := Vector3.UP
var _amount := 0.0
var _noon := 1.0
var _vis := 0.0    # OoT's lensFlareAlphaScale
var _glare := 0.0  # OoT's glareAlpha (0..255)


func _init() -> void:
	mesh = _make_mesh()
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter(&"disc_tex", _sprite(false))
	_mat.set_shader_parameter(&"ring_tex", _sprite(true))
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Placed by the shader: never culled.
	custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))


## `dir`: world direction towards the sun; `amount` 0..1 (weather and the sun's height: 0
## hides it); `noon` 0..1: how near midday (the glare's tint: warm orange at the ends of the
## day, near white at noon). (`tint` is unused: OoT's sprites have their own colours.)
func set_sun(dir: Vector3, amount: float, _tint := Color.WHITE, noon := 1.0) -> void:
	_dir = dir.normalized()
	_amount = clampf(amount, 0.0, 1.0)
	_noon = clampf(noon, 0.0, 1.0)


func _process(delta: float) -> void:
	var steps := delta * OOT_FPS  # (OoT frames this frame)
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var target_vis := 0.0
	var glare_target := 0.0
	if cam and _amount > 0.0:
		var look := -cam.global_transform.basis.z
		var pos_dir := (_dir - look * 0.5).normalized()
		var cos_a := look.dot(pos_dir)
		if cos_a >= 0.0:
			var clear := not cam.is_position_behind(cam.global_position + _dir) and _on_screen(cam) and _sky_clear(cam)
			if clear:
				target_vis = minf(cos_a * 3.5, 1.0)
				var g := cos_a - (1.5 - cos_a)
				if g > 0.0:
					glare_target = _amount * 400.0 * g
	elif not cam and _amount > 0.0:
		target_vis = 1.0  # (editor without a game camera: the depth taps alone)
	# Math_SmoothStepToF(x, target, 0.5, max step, min step), per OoT frame.
	_vis = _smooth_step(_vis, target_vis, 0.05, steps)
	_glare = _smooth_step(_glare, glare_target, 50.0, steps)
	_mat.set_shader_parameter(&"sun_dir", _dir)
	_mat.set_shader_parameter(&"state", Vector4(_amount, _vis, clampf(_glare / 255.0, 0.0, 1.0), _noon))
	visible = _amount > 0.001 or _glare > 0.5


static func _smooth_step(x: float, target: float, max_step: float, steps: float) -> float:
	# OoT moved half the gap (at most max_step) once a frame; `steps` frames' worth.
	var n := maxi(int(round(steps)), 1)
	for i in n:
		var d := clampf((target - x) * 0.5, -max_step, max_step)
		x += d
	return x


func _on_screen(cam: Camera3D) -> bool:
	var vp := get_viewport().get_visible_rect().size
	var p := cam.unproject_position(cam.global_position + _dir * 100.0)
	return p.x >= 0.0 and p.y >= 0.0 and p.x <= vp.x and p.y <= vp.y


func _sky_clear(cam: Camera3D) -> bool:
	var space := cam.get_world_3d().direct_space_state if cam.get_world_3d() else null
	if space == null:
		return true
	var from := cam.global_position
	var q := PhysicsRayQueryParameters3D.create(from, from + _dir * RAY_METRES)
	q.collide_with_areas = false
	q.hit_from_inside = true  # (the camera inside a stall or a doorway's collision)
	var player := get_tree().get_first_node_in_group(&"player") as CollisionObject3D
	if player:
		q.exclude = [player.get_rid()]
	return space.intersect_ray(q).is_empty()


## OoT's flare sprites redrawn (64 x 64, 16 grey levels as I4): a solid disc with a soft rim
## a texel or two wide, or a thin ring round the edge.
static func _sprite(ring: bool) -> ImageTexture:
	var img := Image.create(64, 64, false, Image.FORMAT_L8)
	for y in 64:
		for x in 64:
			var r := Vector2(x - 31.5, y - 31.5).length()
			var v := 0.0
			if ring:
				v = clampf(1.0 - absf(r - 29.6) / 2.4, 0.0, 1.0)
			else:
				v = clampf((31.8 - r) / 2.6, 0.0, 1.0)
			v = roundf(v * 15.0) / 15.0
			img.set_pixel(x, y, Color(v, v, v))
	return ImageTexture.create_from_image(img)


static func _make_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in COUNT + 1:
		var b := verts.size()
		for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			verts.append(Vector3(c.x, c.y, i))
		idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
