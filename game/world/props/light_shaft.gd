@tool
class_name LightShaft
extends Node3D
## A shaft of daylight (a prop): a faint beam slanting down through mist, as where the sun
## breaks through low cloud in a rainy valley. A few long quads crossed round the beam's axis,
## additive, soft across and at both ends, gone edge-on and right up close, fading into the
## N64 fog with distance and out at night (by the time of day's light). Purely visual.
## Origin: the top (where the light comes in); it falls down -Y, leaning `tilt` towards +Z.

const LENGTH := 40.0
const TILT := 20.0

@export_range(2.0, 200.0, 0.5, "suffix:m") var length := LENGTH:
	set(v):
		length = v
		_rebuild()
## The beam's radius where it comes in.
@export_range(0.1, 30.0, 0.1, "suffix:m") var radius_top := 2.5:
	set(v):
		radius_top = v
		_rebuild()
## Its radius at the foot (it widens as it falls).
@export_range(0.1, 60.0, 0.1, "suffix:m") var radius_bottom := 7.0:
	set(v):
		radius_bottom = v
		_rebuild()
## How far it leans from straight down, towards +Z (degrees).
@export_range(0.0, 80.0, 0.5, "suffix:°") var tilt := TILT:
	set(v):
		tilt = v
		_rebuild()
@export var color := Color(1.0, 0.95, 0.82):
	set(v):
		color = v
		_rebuild()
## How bright it adds (0..1; it's light on mist, so faint).
@export_range(0.0, 1.0, 0.01) var intensity := 0.35:
	set(v):
		intensity = v
		_rebuild()
## Slow streaks and dust drifting down the beam (0: a smooth beam).
@export_range(0.0, 1.0, 0.05) var shimmer := 0.5:
	set(v):
		shimmer = v
		_rebuild()
## Quads crossed round the axis (more: rounder from every side, more fill).
@export_range(2, 4) var planes := 3:
	set(v):
		planes = v
		_rebuild()

const SHADER := preload("res://game/world/props/n64_light_shaft.gdshader")
const SEGS := 2


func _ready() -> void:
	_rebuild()


## The foot's offset from the origin (the beam's axis end).
static func foot_offset(len: float, tilt_deg: float) -> Vector3:
	var a := deg_to_rad(tilt_deg)
	return Vector3(0.0, -cos(a), sin(a)) * len


func _rebuild() -> void:
	if not is_inside_tree():
		return
	for c in get_children(true):
		if c.has_meta(&"light_shaft_part"):
			c.queue_free()
	var axis := foot_offset(1.0, tilt)
	var u := Vector3.RIGHT
	var v := axis.cross(u).normalized()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var base := 0
	for k in planes:
		# (crossed evenly round the axis; each its own normal for the edge-on fade)
		var a := PI * float(k) / planes
		var side := u * cos(a) + v * sin(a)
		var n := axis.cross(side).normalized()
		for i in SEGS + 1:
			var t := float(i) / SEGS  # (0 top .. 1 foot)
			var c := axis * length * t
			var r := lerpf(radius_top, radius_bottom, t)
			st.set_normal(n)
			st.set_uv(Vector2(0.0, t))
			st.set_uv2(Vector2(float(k), length))
			st.add_vertex(c - side * r)
			st.set_normal(n)
			st.set_uv(Vector2(1.0, t))
			st.set_uv2(Vector2(float(k), length))
			st.add_vertex(c + side * r)
		for i in SEGS:
			var b := base + i * 2
			st.add_index(b); st.add_index(b + 1); st.add_index(b + 2)
			st.add_index(b + 1); st.add_index(b + 3); st.add_index(b + 2)
		base += (SEGS + 1) * 2
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter(&"color", color)
	m.set_shader_parameter(&"intensity", intensity)
	m.set_shader_parameter(&"shimmer", shimmer)
	m.set_shader_parameter(&"planes", float(planes))
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.set_meta(&"light_shaft_part", true)
	add_child(mi, false, INTERNAL_MODE_BACK)


func prop_bounds() -> AABB:
	var foot := foot_offset(length, tilt)
	var r := maxf(radius_top, radius_bottom)
	return AABB(Vector3(-r, foot.y, -r), Vector3(r * 2.0, -foot.y, foot.z + r * 2.0))
