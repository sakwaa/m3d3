class_name WindDust
extends Node3D
## Wind-blown dust in the world (n64_dust.gdshader: the Sandstorm's two-layer look, sampled in
## world space and drifting with the wind):
## (the town's dust blowing through the streets is a GroundMist made as dust: Zone._update_dust)
##  - far: one ring round the zone out past the town (`ring_radius`): a low, soft, even
##    haze of dust standing between the town and the mountains (low contrast, so it reads as
##    air thick with dust, not smoke).
## DynamicSky owns one and feeds the weather's `dust` / `dust_far` (0..1), the wind and the
## hour (colours from the sandstorm's dawn / day / dusk / night table).

const SHADER := preload("res://game/sky/n64_dust.gdshader")
## The far ring's most alpha (at the ground) and how much of the noise shows (0 = flat haze).
const FAR_ALPHA := 0.3
const FAR_CONTRAST := 0.3

## Far ring: radius (metres from the zone's origin), height, ground level.
var ring_radius := 72.0
var ring_center := Vector2(-3, 0)
var ring_height := 40.0
var ring_base := 0.0
## 0..1 strengths, the hour, wind (world xz velocity-ish: direction x strength), haze colours.
var far := 0.0
var hour := 12.0
var wind := Vector2(1, 0)
var haze := false

var _ring: MeshInstance3D
var _ring_mat := ShaderMaterial.new()
var _drift0 := Vector2.ZERO
var _drift1 := Vector2.ZERO


func _init() -> void:
	_ring_mat.shader = SHADER
	_ring_mat.set_shader_parameter(&"noise0", Sandstorm._noise(5, false))
	_ring_mat.set_shader_parameter(&"noise1", Sandstorm._noise(9, true))
	_ring_mat.set_shader_parameter(&"ring", true)
	_ring_mat.set_shader_parameter(&"height", ring_height * 0.75)
	_ring_mat.set_shader_parameter(&"scale0", 60.0)
	_ring_mat.set_shader_parameter(&"scale1", 40.0)
	_ring_mat.set_shader_parameter(&"soft", 0.0)
	_ring_mat.set_shader_parameter(&"contrast", FAR_CONTRAST)
	_ring = _cylinder(ring_radius, ring_height, 48)
	_ring.material_override = _ring_mat
	_ring.top_level = true
	add_child(_ring)
	_ring.visible = false


static func _cylinder(r: float, h: float, sides: int) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = h
	c.radial_segments = sides
	c.rings = 1
	c.cap_top = false
	c.cap_bottom = false
	var mi := MeshInstance3D.new()
	mi.mesh = c
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 16384.0
	mi.ignore_occlusion_culling = true  # (a ring round the camera is never "behind" the town)
	return mi


func _process(delta: float) -> void:
	_ring.visible = far > 0.001
	if not _ring.visible:
		return
	# Drift with the wind (texture repeats a second), slow at this distance.
	var w := wind
	_drift0 -= w * delta * 0.05
	_drift1 -= Vector2(w.x + w.y, -0.15 * w.length()) * delta * 0.08
	_drift0 = _drift0.posmod(1.0)
	_drift1 = _drift1.posmod(1.0)
	var cols := colours(hour, haze)
	_ring_mat.set_shader_parameter(&"prim", cols[0])
	_ring_mat.set_shader_parameter(&"env", cols[1])
	_ring_mat.set_shader_parameter(&"drift0", _drift0)
	_ring_mat.set_shader_parameter(&"drift1", _drift1)
	_ring_mat.set_shader_parameter(&"amount", far * FAR_ALPHA)
	_ring.global_position = Vector3(ring_center.x, ring_base + ring_height * 0.5, ring_center.y)
	_ring_mat.set_shader_parameter(&"base_y", ring_base)
	_ring_mat.set_shader_parameter(&"ring_center", ring_center)
	_ring_mat.set_shader_parameter(&"ring_radius", ring_radius)
	if (_ring.mesh as CylinderMesh).top_radius != ring_radius:
		(_ring.mesh as CylinderMesh).top_radius = ring_radius
		(_ring.mesh as CylinderMesh).bottom_radius = ring_radius


## [prim, env] for the hour: the sandstorm's sand colours (dawn / day / dusk / night), or MM's
## neutral haze; the dark colour lifted a little towards the light (thin dust, not a wall).
static func colours(h: float, p_haze: bool) -> Array:
	if p_haze:
		return [Sandstorm.HAZE[0], Sandstorm.HAZE[1]]
	var hh := fposmod(h, 24.0)
	var idx := [3, 0, 1, 2, 3]
	var seg := floori(hh / 6.0)
	var t := (hh - seg * 6.0) / 6.0
	var a: Array = Sandstorm.SAND[idx[seg]]
	var b: Array = Sandstorm.SAND[idx[seg + 1]]
	var prim := (a[0] as Color).lerp(b[0], t)
	var env := (a[1] as Color).lerp(b[1], t)
	return [prim, env.lerp(prim, 0.35)]
