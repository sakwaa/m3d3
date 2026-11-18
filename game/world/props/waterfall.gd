@tool
class_name Waterfall
extends Node3D
## A waterfall (a prop): water falling down a cliff in `strands` (thin tall ribbons like a
## spring-fed fall, or one wide sheet with strands 1), from `height` above its foot to the
## pool, the top `lean` metres back into the cliff (following its face), and a churned foam
## patch where it lands. Purely visual (no collision); the pool is the level's water.
## Origin: the foot (where it lands), middle; it falls towards +Z (its face looks +Z).

@export_range(1.0, 120.0, 0.5, "suffix:m") var height := 30.0:
	set(v):
		height = v
		_rebuild()
@export_range(0.5, 40.0, 0.1, "suffix:m") var width := 6.0:
	set(v):
		width = v
		_rebuild()
@export_range(1, 8) var strands := 3:
	set(v):
		strands = v
		_rebuild()
## How far back the top is (the cliff face's slope).
@export_range(-10.0, 20.0, 0.1, "suffix:m") var lean := 4.0:
	set(v):
		lean = v
		_rebuild()
@export_range(0.2, 6.0, 0.1) var speed := 1.6:
	set(v):
		speed = v
		_rebuild()
@export var color := Color(0.74, 0.84, 0.88):
	set(v):
		color = v
		_rebuild()
@export_range(0.0, 1.0, 0.05) var opacity := 0.8:
	set(v):
		opacity = v
		_rebuild()
@export var seed := 1:
	set(v):
		seed = v
		_rebuild()
## The foam patch's radius at the foot (0: none).
@export_range(0.0, 20.0, 0.1, "suffix:m") var foam_radius := 4.0:
	set(v):
		foam_radius = v
		_rebuild()

const SHADER := preload("res://game/world/props/n64_waterfall.gdshader")


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	for c in get_children(true):
		if c.has_meta(&"waterfall_part"):
			c.queue_free()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for k in strands:
		# Strands spread across the width, each its own width, a little shorter or longer
		# (some leave the lip lower), bowing out from the face as they fall.
		var w := width / strands * rng.randf_range(0.45, 0.9) if strands > 1 else width
		var x := (float(k) + 0.5) / strands * width - width * 0.5 + rng.randf_range(-0.2, 0.2) * width / strands
		var h := height * (rng.randf_range(0.82, 1.0) if strands > 1 else 1.0)
		_strand(x, w, h, rng.randf() * 10.0)
	if foam_radius > 0.0:
		var f := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(foam_radius * 2.0, foam_radius * 2.0)
		q.orientation = PlaneMesh.FACE_Y
		f.mesh = q
		f.material_override = _mat(true, 0.0, 1.0)
		f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		f.position = Vector3(0, 0.06, foam_radius * 0.4)
		f.set_meta(&"waterfall_part", true)
		add_child(f, false, INTERNAL_MODE_BACK)


## One ribbon from (x, h, -lean·h/height) down to (x, 0, 0), bowed out a little mid-fall.
func _strand(x: float, w: float, h: float, s: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 6
	var top_back := lean * h / height
	for i in segs + 1:
		var t := float(i) / segs  # (0 top .. 1 foot)
		var z := -top_back * (1.0 - t) + sin(t * PI) * 0.6
		var y := h * (1.0 - t)
		var ww := w * lerpf(0.75, 1.15, t)  # (spreading as it falls)
		st.set_uv(Vector2(0.0, t))
		st.add_vertex(Vector3(x - ww * 0.5, y, z))
		st.set_uv(Vector2(1.0, t))
		st.add_vertex(Vector3(x + ww * 0.5, y, z))
	for i in segs:
		var a := i * 2
		st.add_index(a); st.add_index(a + 1); st.add_index(a + 2)
		st.add_index(a + 1); st.add_index(a + 3); st.add_index(a + 2)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _mat(false, s, h / 3.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_meta(&"waterfall_part", true)
	add_child(mi, false, INTERNAL_MODE_BACK)


func _mat(foam: bool, s: float, repeats: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter(&"color", color)
	m.set_shader_parameter(&"opacity", opacity)
	m.set_shader_parameter(&"speed", speed)
	m.set_shader_parameter(&"seed", s)
	m.set_shader_parameter(&"repeats", repeats)
	m.set_shader_parameter(&"foam", foam)
	return m


func prop_bounds() -> AABB:
	return AABB(Vector3(-width * 0.5, 0.0, -lean - 0.5), Vector3(width, height, lean + maxf(foam_radius, 1.0) + 0.5))
