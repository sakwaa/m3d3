@tool
class_name MountainRange
extends MeshInstance3D
## Large low-poly mountains far outside the level, all the way round (or with arcs left
## open): a ring of ridges per layer, made from a seed (same seed, same mountains), flat
## shaded by a fixed sun, snow above `snow_line`. Layers further out are hazier and bluer
## (atmospheric perspective). Drawn behind the level and the backdrop ring, never clipped by
## the fog's draw distance (n64_mountains.gdshader). Its position is the ring's centre.

const SHADER := preload("res://addons/n64_runtime/shaders/n64_mountains.gdshader")

@export var seed := 1:
	set(v):
		seed = v
		_queue()
## Per layer (near to far): distance to the ridge (m), peak heights (min, max), haze.
@export var layer_radius := PackedFloat32Array([320.0, 520.0]):
	set(v):
		layer_radius = v
		_queue()
@export var layer_height_min := PackedFloat32Array([70.0, 110.0]):
	set(v):
		layer_height_min = v
		_queue()
@export var layer_height_max := PackedFloat32Array([175.0, 260.0]):
	set(v):
		layer_height_max = v
		_queue()
@export var layer_haze := PackedFloat32Array([0.35, 0.58]):
	set(v):
		layer_haze = v
		_queue()
## Ridge samples round the ring (more = more, smaller peaks).
@export_range(16, 256) var segments := 72:
	set(v):
		segments = v
		_queue()
## How jagged: low = rolling, high = sharp separate peaks.
@export_range(0.5, 4.0, 0.1) var sharpness := 1.6:
	set(v):
		sharpness = v
		_queue()
## Colours: foot (dark slopes), rock, and snow above `snow_line` (share of the layer's max).
@export var foot_color := Color(0.2, 0.26, 0.16):
	set(v):
		foot_color = v
		_queue()
@export var rock_color := Color(0.5, 0.44, 0.37):
	set(v):
		rock_color = v
		_queue()
@export var snow_color := Color(0.92, 0.93, 0.96):
	set(v):
		snow_color = v
		_queue()
@export_range(0.0, 1.5, 0.05) var snow_line := 0.68:
	set(v):
		snow_line = v
		_queue()
## Arcs left open (degrees, from -Z clockwise seen from above): Vector2(from, to) each.
@export var open_arcs: Array[Vector2] = []:
	set(v):
		open_arcs = v
		_queue()
## Large-scale N64 textures on the faces (detail around the colours above; empty = flat
## colour): slopes at the foot, rock, snow. `texture_scale`: metres per repeat.
@export var foot_texture: Texture2D = preload("res://textures/grass/1_moss.res"):
	set(v):
		foot_texture = v
		_apply_material()
@export var rock_texture: Texture2D = preload("res://textures/rock/stone_wall_rubble.res"):
	set(v):
		rock_texture = v
		_apply_material()
@export var snow_texture: Texture2D = preload("res://textures/rock/marble_1.res"):
	set(v):
		snow_texture = v
		_apply_material()
@export_range(8.0, 300.0, 1.0, "suffix:m") var texture_scale := 45.0:
	set(v):
		texture_scale = v
		_apply_material()
## How strongly the textures show (0 = flat colour).
@export_range(0.0, 1.0, 0.05) var texture_detail := 0.8:
	set(v):
		texture_detail = v
		_apply_material()
## Pushes the textures' light and dark apart (soft photos read at a distance).
@export_range(0.5, 4.0, 0.1) var texture_contrast := 1.8:
	set(v):
		texture_contrast = v
		_apply_material()
## Two-scale ground on the foot and rock faces (OoT's Hyrule Field look; empty = the
## textures above): a detail texture (dirt) tiled every `ground_scale` metres, mottled by a
## blend texture tiled every `blend_scale` metres (`blend_amount` of it).
@export var ground_texture: Texture2D:
	set(v):
		ground_texture = v
		_apply_material()
@export var blend_texture: Texture2D:
	set(v):
		blend_texture = v
		_apply_material()
@export_range(2.0, 100.0, 0.5, "suffix:m") var ground_scale := 14.0:
	set(v):
		ground_scale = v
		_apply_material()
@export_range(20.0, 600.0, 5.0, "suffix:m") var blend_scale := 160.0:
	set(v):
		blend_scale = v
		_apply_material()
@export_range(0.0, 1.0, 0.05) var blend_amount := 0.7:
	set(v):
		blend_amount = v
		_apply_material()
## Far translation (Ocarina of Time's backgrounds): how much the range moves with the camera
## (1 = fully: it stays as far as it was built whatever the player does - infinitely far,
## no parallax; 0 = fixed in the world). A little under 1 keeps a hint of parallax.
@export_range(0.0, 1.0, 0.01) var follow_camera := 1.0:
	set(v):
		follow_camera = v
		_apply_material()
## ... and its height (0: the range stays on the ground - climbing shows more of it, never
## its underside).
@export_range(0.0, 1.0, 0.01) var follow_height := 0.0:
	set(v):
		follow_height = v
		_apply_material()
## Where the light comes from (for the flat shading; doesn't move with the time of day).
@export var sun_direction := Vector3(-0.5, 0.8, 0.35):
	set(v):
		sun_direction = v
		_queue()

var _queued := false
## The generated mountains: an internal child (never saved, so rebuilding them doesn't
## touch this node's own properties - the inspector stays put while a slider drags).
var _mi: MeshInstance3D
var _mat: ShaderMaterial


func _ready() -> void:
	mesh = null  # (scenes saved before: the mesh lived here; it's the child's now)
	rebuild()


func _queue() -> void:
	if not is_inside_tree() or _queued:
		return
	_queued = true
	(func():
		_queued = false
		rebuild()).call_deferred()


## The shader's settings (textures, scales, blend): no rebuild needed.
func _apply_material() -> void:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = SHADER
	_mat.set_shader_parameter(&"foot_tex", foot_texture)
	_mat.set_shader_parameter(&"rock_tex", rock_texture)
	_mat.set_shader_parameter(&"snow_tex", snow_texture)
	_mat.set_shader_parameter(&"tex_scale", texture_scale)
	_mat.set_shader_parameter(&"detail", texture_detail)
	_mat.set_shader_parameter(&"tex_contrast", texture_contrast)
	_mat.set_shader_parameter(&"use_ground", ground_texture != null)
	_mat.set_shader_parameter(&"ground_tex", ground_texture)
	_mat.set_shader_parameter(&"blend_tex", blend_texture if blend_texture else ground_texture)
	_mat.set_shader_parameter(&"ground_scale", ground_scale)
	_mat.set_shader_parameter(&"blend_scale", blend_scale)
	_mat.set_shader_parameter(&"blend_amount", blend_amount if blend_texture else 0.0)
	# The zone's own fog (the parent Zone's FogSettings): the haze per layer is measured
	# against it, so the time of day's fog moves the mountains like everything else.
	var zf = get_parent().get(&"fog") if get_parent() else null
	var ref := Vector2(90.0, 220.0)
	if zf is FogSettings and (zf as FogSettings).end > (zf as FogSettings).start:
		ref = Vector2((zf as FogSettings).start, (zf as FogSettings).end)
	_mat.set_shader_parameter(&"fog_ref", ref)
	_mat.set_shader_parameter(&"follow", follow_camera)
	_mat.set_shader_parameter(&"follow_height", follow_height)


func rebuild() -> void:
	if not is_inside_tree():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sun := sun_direction.normalized()
	for li in layer_radius.size():
		_layer(st, li, sun)
	var m := st.commit()
	_apply_material()
	if _mi == null:
		_mi = MeshInstance3D.new()
		_mi.name = "Ridges"
		_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mi, false, Node.INTERNAL_MODE_BACK)
	_mi.mesh = m
	_mi.material_override = _mat
	# (Always "visible": the camera is inside the ring.)
	var r := (layer_radius[layer_radius.size() - 1] if not layer_radius.is_empty() else 100.0) * 1.3
	_mi.custom_aabb = AABB(Vector3(-r, -50, -r), Vector3(r * 2, 400, r * 2))
	# (It follows the camera in its shader: never culled however far the camera goes.)
	_mi.extra_cull_margin = 16384.0


func _layer(st: SurfaceTool, li: int, sun: Vector3) -> void:
	var radius := layer_radius[li]
	var h_min: float = layer_height_min[li] if li < layer_height_min.size() else 60.0
	var h_max: float = layer_height_max[li] if li < layer_height_max.size() else 150.0
	var haze: float = layer_haze[li] if li < layer_haze.size() else 0.4
	var noise := FastNoiseLite.new()
	noise.seed = seed * 31 + li * 7
	noise.frequency = 1.0
	noise.fractal_octaves = 3
	var depth := radius * 0.35
	var n := segments
	# Rows outwards: skirt (well below the horizon, a little inwards: looking down from high up
	# - a tower, a cliff, the range following the camera - still lands on mountain), foot
	# (below the horizon), shoulder, ridge, back.
	var rows := []
	for row in 5:
		var pts := PackedVector3Array()
		for i in n:
			var a := TAU * i / n
			var dir := Vector3(sin(a), 0.0, -cos(a))
			var v := (noise.get_noise_2d(cos(a) * 2.2, sin(a) * 2.2) + 1.0) * 0.5
			var peak := h_min + (h_max - h_min) * pow(clampf(v, 0.0, 1.0), sharpness)
			var jitter := (noise.get_noise_2d(cos(a) * 9.0 + row, sin(a) * 9.0) * 0.5)
			var out: float = [-0.4, 0.0, 0.3, 0.55, 1.0][row]
			var up: float = [-radius * 0.45, -25.0, peak * (0.45 + jitter * 0.2), peak, peak * (0.35 + jitter * 0.2)][row]
			pts.append(dir * (radius + depth * out + jitter * depth * 0.1 * float(row > 1)) + Vector3(0, up, 0))
		rows.append([pts, h_max])
	for row in 4:
		var a_pts: PackedVector3Array = rows[row][0]
		var b_pts: PackedVector3Array = rows[row + 1][0]
		for i in n:
			var j := (i + 1) % n
			if _open(TAU * (i + 0.5) / n):
				continue
			var q := [a_pts[i], a_pts[j], b_pts[j], b_pts[i]]
			if (i + row) % 2 == 0:
				_tri(st, q[0], q[1], q[2], sun, h_max, haze)
				_tri(st, q[0], q[2], q[3], sun, h_max, haze)
			else:
				_tri(st, q[0], q[1], q[3], sun, h_max, haze)
				_tri(st, q[1], q[2], q[3], sun, h_max, haze)


func _open(a: float) -> bool:
	var deg := fposmod(rad_to_deg(a), 360.0)
	for arc in open_arcs:
		var lo := fposmod(arc.x, 360.0)
		var hi := fposmod(arc.y, 360.0)
		if (lo <= hi and deg >= lo and deg <= hi) or (lo > hi and (deg >= lo or deg <= hi)):
			return true
	return false


## One flat-shaded triangle: coloured by height (foot -> rock -> snow) and lit by `sun`.
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, sun: Vector3, h_max: float, haze: float) -> void:
	var nrm := (b - a).cross(c - a).normalized()
	var centre := (a + b + c) / 3.0
	if nrm.dot(-Vector3(centre.x, 0, centre.z)) < 0.0:
		nrm = -nrm  # (the side seen from inside the ring)
	var h := clampf(centre.y / maxf(h_max, 1.0), 0.0, 1.5)
	var rockiness := smoothstep(0.1, 0.55, h)
	var base := foot_color.lerp(rock_color, rockiness)
	var kind := 1.0 if rockiness > 0.5 else 0.0
	if h > snow_line and nrm.y > 0.2:
		base = snow_color
		kind = 2.0
	var light := 0.42 + 0.7 * maxf(nrm.dot(sun), 0.0)
	var col := Color(base.r * light, base.g * light, base.b * light)
	for p in [a, b, c]:
		st.set_color(col)
		st.set_normal(nrm)
		st.set_uv(Vector2(haze, kind))
		st.add_vertex(p)
