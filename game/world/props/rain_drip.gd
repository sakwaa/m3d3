@tool
class_name RainDrip
extends Node3D
## Rain running off an edge (a roof's eave, an awning): a curtain of thin streams hanging
## from the node along its X, falling `drop` metres, and a line of splashes where they land
## (on +Z of the node is outside). Only shows while it rains. The level tools put them along
## every house's eaves (Props > Roof drips); move, stretch or delete them like any prop, or
## add more. In game all of a zone's drips draw as one mesh (one draw call).

const SHADER := preload("res://addons/n64_runtime/shaders/n64_drip.gdshader")
const GROUP := &"rain_drips"

## Length of the edge (metres, centred on the node).
@export_range(0.2, 40.0, 0.05, "suffix:m") var width := 4.0:
	set(v):
		width = v
		_rebuild()
## How far the water falls before it lands.
@export_range(0.2, 20.0, 0.05, "suffix:m") var drop := 3.0:
	set(v):
		drop = v
		_rebuild()
## Share of the edge with a stream running off it.
@export_range(0.0, 1.0, 0.05) var density := 0.55:
	set(v):
		density = v
		_rebuild()
## A line of splashes where the water lands.
@export var splashes := true:
	set(v):
		splashes = v
		_rebuild()

static var _material: ShaderMaterial
static var _queued := false
var _mesh: MeshInstance3D


func _ready() -> void:
	add_to_group(GROUP)
	if Engine.is_editor_hint():
		_rebuild()
	elif not _queued:
		_queued = true
		_flush.call_deferred(get_tree())


func _rebuild() -> void:
	if not is_inside_tree() or not Engine.is_editor_hint():
		return
	if _mesh == null:
		_mesh = MeshInstance3D.new()
		_mesh.material_override = material()
		_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mesh, false, INTERNAL_MODE_BACK)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	add_to(st, Transform3D.IDENTITY)
	_mesh.mesh = st.commit()


## The drip's quads into `st`, through `xf`.
func add_to(st: SurfaceTool, xf: Transform3D) -> void:
	var seed := float(hash(name) & 0xffff) / 65535.0
	var hw := width * 0.5
	var quad := func(pts: Array, uvs: Array, kind: float) -> void:
		for i in [0, 1, 2, 0, 2, 3]:
			st.set_color(Color(seed, kind, 0.0, density))
			st.set_uv(uvs[i])
			st.add_vertex(xf * (pts[i] as Vector3))
	quad.call([Vector3(-hw, 0, 0), Vector3(hw, 0, 0), Vector3(hw, -drop, 0), Vector3(-hw, -drop, 0)],
		[Vector2(0, 0), Vector2(width, 0), Vector2(width, drop), Vector2(0, drop)], 0.0)
	if splashes:
		var y := -drop + 0.03
		quad.call([Vector3(-hw, y, -0.25), Vector3(hw, y, -0.25), Vector3(hw, y, 0.25), Vector3(-hw, y, 0.25)],
			[Vector2(0, 0), Vector2(width, 0), Vector2(width, 0.5), Vector2(0, 0.5)], 1.0)


static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
	return _material


## In game: each zone's drips (by their scene, like PropBatch) as one mesh in world space.
static func _flush(tree: SceneTree) -> void:
	_queued = false
	if tree == null:
		return
	var by_zone := {}
	for d: RainDrip in tree.get_nodes_in_group(GROUP):
		d.remove_from_group(GROUP)
		if d.is_inside_tree() and d.is_visible_in_tree():
			by_zone.get_or_add(d.owner if d.owner else d.get_parent(), []).append(d)
	for zone: Node in by_zone:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for d: RainDrip in by_zone[zone]:
			d.add_to(st, d.global_transform)
		var mi := MeshInstance3D.new()
		mi.name = "RainDrips"
		mi.mesh = st.commit()
		mi.material_override = material()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		zone.add_child(mi)
		mi.top_level = true
		mi.global_transform = Transform3D.IDENTITY
