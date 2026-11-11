@tool
class_name WorldTree
extends Node3D
## A tree (a tree prop brush): grown by the tree generator from a species and a seed (same
## seed, same tree; another seed, another tree of that species), N64 style. A cylinder
## round the trunk collides; far off, the species' photo card stands in for it (imported
## species). In the editor and when playing from it the tree is grown here; on export it's
## baked into the scene (the generator and the species don't ship).

const BUILDER := "res://addons/n64_level_tools/trees/tree_builder.gd"
const CARD_SHADER := preload("res://addons/n64_runtime/shaders/n64_scatter.gdshader")
const SPECIES_DIR := "res://addons/n64_level_tools/trees/species/"

## The species (a TreeSpecies preset from addons/n64_level_tools/trees/species/).
@export var species: Resource:
	set(v):
		species = v
		_rebuild()
## Which tree of the species.
@export var seed := 1:
	set(v):
		seed = v
		_rebuild()
## Tick for another seed (a new tree of the same species).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var new_seed := false:
	set(v):
		if v:
			seed = randi_range(1, 99999)
## Overall size (1 = the species' height).
@export_range(0.3, 2.0, 0.05) var size := 1.0:
	set(v):
		size = v
		_rebuild()
## Beyond this distance (metres) the photo card stands in (0 = never; species without a card
## never switch).
@export_range(0.0, 300.0, 1.0, "suffix:m") var card_distance := 80.0:
	set(v):
		card_distance = v
		_rebuild()
## Only the card, at any distance (backdrop trees the player can't reach: 2 triangles).
@export var card_only := false:
	set(v):
		card_only = v
		_rebuild()
## A cylinder round the trunk blocks the player.
@export var collide := true:
	set(v):
		collide = v
		_rebuild()

## Set on export: the parts are saved children, nothing to grow.
@export_storage var baked := false

var _parts: Array[Node] = []
var _trunk := Vector2(0.3, 4.0)  # radius, height


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	if baked or not is_inside_tree():
		return
	for p in _parts:
		if is_instance_valid(p):
			p.queue_free()
	_parts.clear()
	if species == null or not ResourceLoader.exists(BUILDER):
		return
	var mesh: ArrayMesh = load(BUILDER).build(species, seed)
	_trunk = Vector2(float(species.get(&"trunk_radius")), float(species.get(&"height")) * float(species.get(&"trunk_top"))) * size
	var pick: Array = species.card_for(seed)
	var tiles: Array = pick[0]
	var card: Texture2D = tiles[0] if not tiles.is_empty() else null
	var only_card := card_only and card != null
	var mi := MeshInstance3D.new()
	if not only_card:
		mi.name = "Tree"
		mi.mesh = mesh
		mi.scale = Vector3.ONE * size
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 0.6  # (the wind sways it past its bounds)
		_add_part(mi)
	if card and (card_distance > 0.0 or only_card):
		if not only_card:
			mi.visibility_range_end = card_distance
			mi.visibility_range_end_margin = 4.0
		var aspect: float = pick[1]
		var h: float = mesh.get_aabb().end.y * size
		var q := MeshInstance3D.new()
		q.name = "Card"
		q.mesh = _card_mesh(tiles, pick[3], pick[2])
		q.position = Vector3(0.0, h * 0.5, 0.0)
		q.scale = Vector3(h * aspect, h, 1.0)
		if not only_card:
			q.visibility_range_begin = card_distance
			q.visibility_range_begin_margin = 4.0
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The card turns to face the camera in its shader; its bounds are the unturned quad
		# (a thin slab), so seen side on it was culled while still on screen.
		q.extra_cull_margin = h * aspect * 0.5
		_add_part(q)
	if collide:
		var body := StaticBody3D.new()
		body.name = "Trunk"
		var shape := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = maxf(_trunk.x, 0.1)
		cyl.height = maxf(_trunk.y, 1.0)
		shape.shape = cyl
		shape.position = Vector3(0.0, cyl.height * 0.5, 0.0)
		body.add_child(shape)
		_add_part(body)


## The card: a unit quad (centred, facing +Z) cut into the tile grid, one surface per
## tile with its texture, mirrored left / right if `mirror`.
static func _card_mesh(tiles: Array, grid: Vector2i, mirror: bool) -> ArrayMesh:
	var m := ArrayMesh.new()
	for k in tiles.size():
		var cx := k % grid.x
		var cy := k / grid.x
		var col := grid.x - 1 - cx if mirror else cx
		var x0 := -0.5 + float(col) / grid.x
		var x1 := -0.5 + float(col + 1) / grid.x
		var y0 := 0.5 - float(cy) / grid.y
		var y1 := 0.5 - float(cy + 1) / grid.y
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(x0, y0, 0), Vector3(x1, y0, 0), Vector3(x1, y1, 0), Vector3(x0, y1, 0)])
		a[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
		var u0 := 1.0 if mirror else 0.0
		a[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(u0, 0), Vector2(1.0 - u0, 0), Vector2(1.0 - u0, 1), Vector2(u0, 1)])
		a[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		var mat := ShaderMaterial.new()
		mat.shader = CARD_SHADER
		mat.set_shader_parameter(&"tex", tiles[k])
		mat.set_shader_parameter(&"billboard", true)
		mat.set_shader_parameter(&"edge_mode", 0)
		mat.set_shader_parameter(&"shade", 1.0)
		m.surface_set_material(k, mat)
	return m


func _add_part(n: Node) -> void:
	add_child(n, false, Node.INTERNAL_MODE_BACK)
	_parts.append(n)


## Pick box for the level tools: round the trunk (the crown would block clicks around it).
func prop_bounds() -> AABB:
	var r := maxf(_trunk.x, 0.25) + 0.1
	return AABB(Vector3(-r, 0.0, -r), Vector3(r * 2.0, maxf(_trunk.y, 1.5), r * 2.0))


## Export (LevelRoot.make_prop_nodes_for_export): the grown parts become saved children
## and the species reference goes (it lives in the tools, which don't ship).
func bake_for_export(scene: Node) -> void:
	_rebuild()
	for p in _parts:
		remove_child(p)
		add_child(p, true)
		p.owner = scene
		for c in p.get_children():
			c.owner = scene
	_parts.clear()
	baked = true
	species = null
