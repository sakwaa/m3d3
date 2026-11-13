class_name ImpactBurst
extends MeshInstance3D
## The flash of a sword landing, after the OoT remake: a streak of light along the blade's
## swing (a vertical chop flashes a pillar, a side slash a horizontal streak), white at its
## core and `edge` coloured at its rim, facing the camera round its long axis. Timed from
## the remake at 60 fps: shoots out to full length in 2 frames, bright for 8, then thins and
## fades over 4 (0.23 s). Additive, drawn over everything.

const GROW := 2.0 / 60.0
const HOLD := 8.0 / 60.0
const FADE := 4.0 / 60.0

const SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_test_disabled, depth_draw_never;
uniform vec4 edge : source_color = vec4(1.0, 0.35, 0.45, 1.0);
uniform float strength = 1.0;
void fragment() {
	float across = abs(UV.x * 2.0 - 1.0);
	float along = abs(UV.y * 2.0 - 1.0);
	float core = exp(-across * across * 40.0);
	float glow = exp(-across * across * 6.0);
	float taper = 1.0 - along * along;
	vec3 c = edge.rgb * glow + vec3(1.0) * core;
	ALBEDO = c * taper * strength;
}
"""

static var _shader: Shader

var axis := Vector3.UP
var length := 3.0
var width := 0.5
var _t := 0.0
var _mat: ShaderMaterial


## A burst at `at` along `along` (world), `length` long; `edge` the rim colour.
static func spawn(at: Vector3, along: Vector3, length := 3.0, edge := Color(1.0, 0.35, 0.45)) -> ImpactBurst:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return null
	var b := ImpactBurst.new()
	b.axis = along.normalized() if along.length() > 0.001 else Vector3.UP
	b.length = length
	b.width = length * 0.17
	tree.current_scene.add_child(b)
	b.global_position = at
	b._mat.set_shader_parameter(&"edge", edge)
	return b


func _init() -> void:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	mesh = q
	_mat = ShaderMaterial.new()
	_mat.shader = _shader
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	top_level = true


func _process(delta: float) -> void:
	_t += delta
	if _t >= GROW + HOLD + FADE:
		queue_free()
		return
	var grow := clampf(_t / GROW, 0.0, 1.0)
	var fade := clampf((_t - GROW - HOLD) / FADE, 0.0, 1.0)
	_mat.set_shader_parameter(&"strength", 1.0 - fade)
	# Face the camera round the long axis.
	var cam := get_viewport().get_camera_3d()
	var to_cam := (cam.global_position - global_position).normalized() if cam else Vector3.BACK
	var side := axis.cross(to_cam)
	if side.length() < 0.01:
		side = axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT)  # (seen end on)
	side = side.normalized()
	var normal := side.cross(axis).normalized()
	global_basis = Basis(side * width * (1.0 - 0.6 * fade), axis * length * (0.15 + 0.85 * grow), normal)
