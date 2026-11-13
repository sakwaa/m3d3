@tool
class_name Ladder
extends Node3D
## A ladder (a ladder prop brush): two rails and evenly spaced round rungs, standing in its
## XY plane from the origin up, climbed from its +Z side (the climber faces -Z). The player
## climbs it with LocoLadder: hands and feet are placed on the actual rungs, so the spacing,
## height and width set the climb. Its top is meant to meet a floor behind it (-Z) to climb
## off onto (a deck, a ledge); without one the climb stops at the top rung. A thin box over
## its face blocks walking through it. Placed from the level tools' Props menu.

## Metres from the origin to the top (the top rung is at most this high).
@export_range(0.5, 20.0, 0.05, "suffix:m") var height := 3.0:
	set(v):
		height = v
		_rebuild()
@export_range(0.3, 1.2, 0.01, "suffix:m") var width := 0.5:
	set(v):
		width = v
		_rebuild()
## Between rungs (centre to centre).
@export_range(0.15, 0.6, 0.01, "suffix:m") var rung_spacing := 0.3:
	set(v):
		rung_spacing = v
		_rebuild()
## The lowest rung's height over the origin.
@export_range(0.05, 1.0, 0.01, "suffix:m") var first_rung := 0.3:
	set(v):
		first_rung = v
		_rebuild()
## Rails stand this far over the top rung (0 = flush with a deck, MM-style).
@export_range(0.0, 1.5, 0.05, "suffix:m") var rails_above := 0.0:
	set(v):
		rails_above = v
		_rebuild()
@export_group("Look")
@export var wood_texture: Texture2D = preload("res://textures/wood/wood_2.res"):
	set(v):
		wood_texture = v
		_rebuild()
@export var rail_color := Color(0.7, 0.55, 0.42):
	set(v):
		rail_color = v
		_rebuild()
@export var rung_color := Color(0.62, 0.62, 0.66):
	set(v):
		rung_color = v
		_rebuild()
@export_range(0.03, 0.12, 0.005, "suffix:m") var rail_size := 0.06:
	set(v):
		rail_size = v
		_rebuild()
@export_range(0.01, 0.05, 0.005, "suffix:m") var rung_radius := 0.022:
	set(v):
		rung_radius = v
		_rebuild()
@export_group("")

const GROUP := &"ladders"

var _parts: Node3D
var _surfaces := {}  # Material -> SurfaceTool
var _mats := {}


func _ready() -> void:
	add_to_group(GROUP)
	_rebuild()


# --- Rungs (what the climber holds) ----------------------------------------------------

func rung_count() -> int:
	return maxi(int(floorf((height - first_rung) / rung_spacing + 0.001)) + 1, 1)


## Rung `i`'s height over the origin.
func rung_height(i: int) -> float:
	return first_rung + i * rung_spacing


## The middle of rung `i` (world).
func rung_point(i: int) -> Vector3:
	return global_transform * Vector3(0.0, rung_height(i), 0.0)


## Out of the climbing face (world, flat).
func normal() -> Vector3:
	var z := global_basis.z
	z.y = 0.0
	return z.normalized()


## Along the rungs, to the climber's right (world).
func right() -> Vector3:
	return global_basis.x.normalized()


## Height (local) of a world point, and its offset along the rungs.
func local_of(p: Vector3) -> Vector3:
	return global_transform.affine_inverse() * p


## The rung nearest `y` (local height), clamped to the ladder.
func rung_near(y: float) -> int:
	return clampi(roundi((y - first_rung) / rung_spacing), 0, rung_count() - 1)


## The ladders in `tree`.
static func all(tree: SceneTree) -> Array[Node]:
	return tree.get_nodes_in_group(GROUP)


# --- Mesh ----------------------------------------------------------------------------------

func _rebuild() -> void:
	if not is_inside_tree():
		return
	if _parts:
		_parts.queue_free()
	_parts = Node3D.new()
	_parts.name = "Parts"
	add_child(_parts, false, INTERNAL_MODE_BACK)
	_surfaces.clear()
	var rail := _mat(rail_color)
	var rung := _mat(rung_color)
	var top := rung_height(rung_count() - 1) + rails_above + rail_size * 0.5
	var hw := width * 0.5
	for s in [-1.0, 1.0]:
		_box(rail, Vector3(rail_size, top, rail_size), Vector3(s * (hw + rail_size * 0.5), top * 0.5, 0.0))
	for i in rung_count():
		_rung(rung, rung_height(i), hw)
	var mesh := ArrayMesh.new()
	for m: Material in _surfaces:
		PropBatch.commit(_surfaces[m], mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, m)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	_parts.add_child(mi)
	# Blocks walking through the ladder (climbing reads the rungs, not this).
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(width + rail_size * 2.0, top, rail_size)
	cs.shape = shape
	cs.position = Vector3(0.0, top * 0.5, 0.0)
	body.add_child(cs)
	_parts.add_child(body)
	PropBatch.add(_parts)


func _mat(color: Color) -> Dictionary:
	if not _mats.has(wood_texture):
		var m := N64Materials.textured(Color.WHITE, wood_texture)
		m.set_shader_parameter(&"use_vertex_color", true)
		_mats[wood_texture] = m
	return {material = _mats[wood_texture], color = color}


func _st(m: Material) -> SurfaceTool:
	if not _surfaces.has(m):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_surfaces[m] = st
	return _surfaces[m]


## A quad `pts` (counter-clockwise seen from `normal`'s side); UVs `uvs`.
func _quad(m: Dictionary, pts: Array, normal: Vector3, uvs: Array) -> void:
	var st := _st(m.material)
	for k in [0, 2, 1, 0, 3, 2]:  # (Godot fronts are clockwise)
		st.set_normal(normal)
		st.set_color(m.color)
		st.set_uv(uvs[k])
		st.add_vertex(pts[k])


## A rail: four sides and a cap, UVs along its length (1 repeat per metre).
func _box(m: Dictionary, s: Vector3, c: Vector3) -> void:
	var h := s * 0.5
	var sides := [[Vector3.BACK, Vector3.RIGHT], [Vector3.RIGHT, Vector3.FORWARD], [Vector3.FORWARD, Vector3.LEFT],
		[Vector3.LEFT, Vector3.BACK]]
	for side in sides:
		var n: Vector3 = side[0]
		var u: Vector3 = side[1]
		var o := c + n * (h * n.abs()).length()
		var a := (h * u.abs()).length()
		_quad(m, [o - u * a - Vector3.UP * h.y, o + u * a - Vector3.UP * h.y, o + u * a + Vector3.UP * h.y,
			o - u * a + Vector3.UP * h.y], n, [Vector2(0, s.y), Vector2(0.1, s.y), Vector2(0.1, 0), Vector2(0, 0)])
	var t := c + Vector3.UP * h.y
	_quad(m, [t + Vector3(-h.x, 0, h.z), t + Vector3(h.x, 0, h.z), t + Vector3(h.x, 0, -h.z), t + Vector3(-h.x, 0, -h.z)],
		Vector3.UP, [Vector2(0, 0.1), Vector2(0.1, 0.1), Vector2(0.1, 0), Vector2(0, 0)])


## A rung: a 6-sided bar across the rails at height `y`.
func _rung(m: Dictionary, y: float, hw: float) -> void:
	var sides := 6
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var d0 := Vector3(0, sin(a0), cos(a0)) * rung_radius
		var d1 := Vector3(0, sin(a1), cos(a1)) * rung_radius
		var c := Vector3(0, y, 0)
		var n := ((d0 + d1) * 0.5).normalized()
		_quad(m, [c + d0 - Vector3.RIGHT * hw, c + d0 + Vector3.RIGHT * hw, c + d1 + Vector3.RIGHT * hw,
			c + d1 - Vector3.RIGHT * hw], n, [Vector2(0, 0), Vector2(width, 0), Vector2(width, 0.05), Vector2(0, 0.05)])
