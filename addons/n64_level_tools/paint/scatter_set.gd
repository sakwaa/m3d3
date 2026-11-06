@tool
class_name ScatterSet
extends Resource
## Cut-outs scattered on a level (flowers, grass tufts): one texture drawn at many points,
## as one MultiMesh per CELL metres (a draw call each, so the camera skips cells out of view),
## drawn out to draw_distance. Painted with the Scatter / Place tools; in level space, so
## they move with the level. Shipped as plain MultiMeshInstance3Ds (the shader lives in
## n64_runtime).

##  UPRIGHT: a quad standing up, turned to face the camera around Y (flowers on stems).
##  CROSS: two quads crossed at right angles, fixed (grass tufts, shrubs).
##  FLAT: lying on the ground (flower heads seen from above, petals).
enum Style { UPRIGHT, CROSS, FLAT }

const SHADER := preload("res://addons/n64_runtime/shaders/n64_scatter.gdshader")
## Metres: points are split into cells this size, one MultiMesh each.
const CELL := 16.0
## Auto draw distance: this many times the item size (a 0.4 m flower: 60 m, a few pixels).
const AUTO_DISTANCE := 150.0

@export var texture: Texture2D:
	set(value):
		texture = value
		emit_changed()
@export var style := Style.UPRIGHT:
	set(value):
		style = value
		emit_changed()
## Metres: height of UPRIGHT / CROSS quads, width of FLAT ones (each point scales it).
@export_range(0.05, 8.0, 0.05, "suffix:m") var size := 0.4:
	set(value):
		size = value
		emit_changed()
## The cut-out's outer ring of texels: as is, darkened (a contact-shadow outline), or
## trimmed (the ground shows through: hides a pale photo fringe).
enum Edge { OFF, DARKEN, TRIM }
@export var edge := Edge.DARKEN:
	set(value):
		edge = value
		emit_changed()
## DARKEN: how dark the edge gets (1 = not at all).
@export_range(0.0, 1.0, 0.05) var edge_dark := 0.55:
	set(value):
		edge_dark = value
		emit_changed()
## Metres from the camera before the items stop drawing (0 = auto, from the size).
@export_range(0.0, 500.0, 1.0, "or_greater", "suffix:m") var draw_distance := 0.0:
	set(value):
		draw_distance = value
		emit_changed()
## Level-space positions (xyz) and size multipliers (w).
@export_storage var points := PackedVector4Array():
	set(value):
		points = value
		emit_changed()

static var _meshes := {}


## Rotation (radians) and brightness of a point, from its position: the same every rebuild.
static func point_random(p: Vector3) -> Vector2:
	var h := absf(sin(p.dot(Vector3(12.9898, 78.233, 37.719))) * 43758.5453)
	var h2 := absf(sin(p.dot(Vector3(39.346, 11.135, 83.155))) * 24634.6345)
	return Vector2(fposmod(h, 1.0) * TAU, 0.82 + 0.18 * fposmod(h2, 1.0))


func aspect() -> float:
	return float(texture.get_width()) / maxf(texture.get_height(), 1) if texture else 1.0


## The instances as MultiMeshInstance3Ds, one per CELL (empty when there's nothing to draw).
func build_nodes(layers := 1) -> Array[MultiMeshInstance3D]:
	var out: Array[MultiMeshInstance3D] = []
	if texture == null or points.is_empty():
		return out
	var cells := {}
	for p in points:
		var c := Vector2i(floori(p.x / CELL), floori(p.z / CELL))
		if not cells.has(c):
			cells[c] = PackedVector4Array()
		cells[c].append(p)
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter(&"tex", texture)
	mat.set_shader_parameter(&"billboard", style == Style.UPRIGHT)
	mat.set_shader_parameter(&"edge_mode", edge)
	mat.set_shader_parameter(&"edge_dark", edge_dark)
	var a := aspect()
	var reach := (draw_distance if draw_distance > 0.0 else size * AUTO_DISTANCE)
	for c in cells:
		var pts: PackedVector4Array = cells[c]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _mesh(style)
		mm.instance_count = pts.size()
		for i in pts.size():
			var p := pts[i]
			var at := Vector3(p.x, p.y, p.z)
			var r := point_random(at)
			var s := size * p.w
			var basis := Basis(Vector3.UP, r.x)
			match style:
				Style.UPRIGHT:
					basis = Basis.from_scale(Vector3(s * a, s, s * a))  # the shader turns it
				Style.CROSS:
					basis = basis.scaled_local(Vector3(s * a, s, s * a))
				Style.FLAT:
					basis = basis.scaled_local(Vector3(s, 1.0, s / a))
			mm.set_instance_transform(i, Transform3D(basis, at))
			mm.set_instance_color(i, Color(r.y, r.y, r.y))
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.layers = layers
		# Billboards turn in the shader: leave room so they aren't culled while turning.
		node.extra_cull_margin = size * maxf(a, 1.0)
		# Range is measured to the cell's centre: add its half-diagonal so edge items reach it too.
		node.visibility_range_end = reach + CELL * 0.71
		node.visibility_range_end_margin = 2.0
		out.append(node)
	return out


static func _mesh(s: Style) -> ArrayMesh:
	if _meshes.has(s):
		return _meshes[s]
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var quads := []
	match s:
		Style.FLAT:
			quads.append([Vector3(-0.5, 0.02, -0.5), Vector3(0.5, 0.02, -0.5), Vector3(0.5, 0.02, 0.5), Vector3(-0.5, 0.02, 0.5)])
		Style.CROSS:
			quads.append([Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 1, 0), Vector3(-0.5, 1, 0)])
			quads.append([Vector3(0, 0, -0.5), Vector3(0, 0, 0.5), Vector3(0, 1, 0.5), Vector3(0, 1, -0.5)])
		_:
			quads.append([Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 1, 0), Vector3(-0.5, 1, 0)])
	var quad_uv := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	if s == Style.FLAT:
		quad_uv = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for q in quads:
		for k in [0, 1, 2, 0, 2, 3]:
			verts.append(q[k])
			uvs.append(quad_uv[k])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var colors := PackedColorArray()
	colors.resize(verts.size())
	colors.fill(Color.WHITE)
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_meshes[s] = mesh
	return mesh
