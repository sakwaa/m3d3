@tool
class_name WorldVines
extends Node3D
## Creeping vines (a vines prop brush): thick ropey tendrils that grow out from their roots
## round the origin and crawl over whatever is near - the ground, up walls, round edges,
## over objects - seeking `target` if it's set (and wrapping round it once there), branching,
## leafy (VineBuilder). Density, length, thickness, wander, leaves... in the Inspector.
##
## Growth is a mechanic: `grown` (0..1) reveals them from the roots out (the shader does it:
## free at run time), `grow_to()` animates it (a Permivor's growth power coming back,
## watering a root), `auto_grow` grows them in when the zone starts. Fully grown: the
## `grown_fully` signal.
## Baked or live: in the editor and when playing from it they're grown here (from the
## meshes around them); on export the mesh is baked into the scene (no crawling in the
## shipped game). `live`: keeps growing them in game at load (and lets regrow() crawl again
## over what's there now: a block moved, a gate opened) - costs the crawl at run time.

signal grown_fully

const SHADER := preload("res://addons/n64_runtime/shaders/n64_vine.gdshader")

@export var seed := 1:
	set(v):
		seed = v
		_queue()
## Tick for other vines (another seed).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var new_seed := false:
	set(v):
		if v:
			seed = randi_range(1, 99999)
## Tick to grow them again over what's around them now (after moving walls or props).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var regrow_now := false:
	set(v):
		if v:
			_queue()

@export_group("Growth")
## Tendrils from the roots (density).
@export_range(1, 64) var count := 10:
	set(v):
		count = v
		_queue()
## Roots spread over a disc this wide (radius).
@export_range(0.0, 10.0, 0.05, "suffix:m") var spread := 0.6:
	set(v):
		spread = v
		_queue()
## How far each tendril crawls.
@export_range(0.5, 60.0, 0.1, "suffix:m") var length := 7.0:
	set(v):
		length = v
		_queue()
## Some tendrils shorter (0: all the full length).
@export_range(0.0, 0.9, 0.05) var length_jitter := 0.4:
	set(v):
		length_jitter = v
		_queue()
## Metres per segment (shorter: smoother bends, more triangles).
@export_range(0.1, 1.0, 0.01, "suffix:m") var step := 0.3:
	set(v):
		step = v
		_queue()
## How much they meander: the most they turn a segment (degrees; the turn itself drifts,
## so they sweep in curves and loops).
@export_range(0.0, 60.0, 1.0, "suffix:°") var wander := 14.0:
	set(v):
		wander = v
		_queue()
## Bias up walls (0: go where they go).
@export_range(0.0, 1.0, 0.05) var climb := 0.3:
	set(v):
		climb = v
		_queue()
## Branches per metre.
@export_range(0.0, 2.0, 0.01) var branches := 0.15:
	set(v):
		branches = v
		_queue()
## A branch's length, as a share of what its parent had left.
@export_range(0.1, 1.0, 0.05) var branch_length := 0.5:
	set(v):
		branch_length = v
		_queue()
## Branches of branches (0: none).
@export_range(0, 3) var branch_depth := 2:
	set(v):
		branch_depth = v
		_queue()

@export_group("Target")
## Seek a point (local): the tendrils head for it and wrap round what's there.
@export var use_target := false:
	set(v):
		use_target = v
		_queue()
@export var target := Vector3(0, 0.5, -4):
	set(v):
		target = v
		_queue()
## How hard they turn towards it (0..1 a segment).
@export_range(0.0, 1.0, 0.01) var seek := 0.15:
	set(v):
		seek = v
		_queue()
## Within this of it they wander round it (wrapping) instead of heading in.
@export_range(0.1, 10.0, 0.1, "suffix:m") var target_radius := 1.5:
	set(v):
		target_radius = v
		_queue()

@export_group("Stem")
## Stem radius at the roots (branches thinner).
@export_range(0.01, 0.5, 0.005, "suffix:m") var thickness := 0.07:
	set(v):
		thickness = v
		_queue()
## Radius at the tips, a share of the root's.
@export_range(0.05, 1.0, 0.05) var tip := 0.35:
	set(v):
		tip = v
		_queue()
## Sides round the stem (3-6; N64: 3 or 4).
@export_range(3, 8) var sides := 4:
	set(v):
		sides = v
		_queue()
## Leave out the stem's face lying on the surface (never seen: a quarter fewer triangles
## at 4 sides, a third at 3).
@export var open_back := true:
	set(v):
		open_back = v
		_queue()
## A ring only where the stem bends more than this (degrees) since the last; straight runs
## get one long segment (0: a ring every crawl step).
@export_range(0.0, 45.0, 0.5, "suffix:°") var stem_bend := 8.0:
	set(v):
		stem_bend = v
		_queue()
@export var stem_texture: Texture2D = preload("res://textures/plants/vine_stem.res"):
	set(v):
		stem_texture = v
		_queue()
@export var stem_color := Color(0.85, 0.9, 0.75):
	set(v):
		stem_color = v
		_queue()
## Texture repeats along the stem per circumference (1: square).
@export_range(0.25, 8.0, 0.05) var stem_tile := 2.0:
	set(v):
		stem_tile = v
		_queue()

@export_group("Leaves")
## Leaves per metre of stem (0: bare).
@export_range(0.0, 20.0, 0.1) var leaf_density := 5.0:
	set(v):
		leaf_density = v
		_queue()
@export_range(0.05, 1.0, 0.01, "suffix:m") var leaf_size := 0.3:
	set(v):
		leaf_size = v
		_queue()
## Some leaves smaller.
@export_range(0.0, 0.9, 0.05) var leaf_jitter := 0.35:
	set(v):
		leaf_jitter = v
		_queue()
## Tipped up off the surface (degrees).
@export_range(0.0, 80.0, 1.0, "suffix:°") var leaf_lift := 25.0:
	set(v):
		leaf_lift = v
		_queue()
## One triangle a leaf (pointed single leaves) instead of a quad (clumps, sprigs).
@export var leaf_triangles := true:
	set(v):
		leaf_triangles = v
		_queue()
@export var leaf_texture: Texture2D = preload("res://textures/plants/vine_leaf.res"):
	set(v):
		leaf_texture = v
		_queue()
@export var leaf_color := Color(1, 1, 1):
	set(v):
		leaf_color = v
		_queue()
## Leaves stir in the wind (metres at full wind).
@export_range(0.0, 0.5, 0.01) var leaf_wind := 0.06:
	set(v):
		leaf_wind = v
		_queue()

@export_group("In game")
## How grown they are: 0 nothing .. 1 all (free to change: the shader reveals them).
@export_range(0.0, 1.0, 0.01) var grown := 1.0:
	set(v):
		grown = v
		_apply_grown()
## Grow in over this many seconds when the zone starts (0: start as `grown`).
@export_range(0.0, 60.0, 0.1, "suffix:s") var auto_grow := 0.0
## Grow them at load in game too (not baked on export), so regrow() can crawl again over
## what's there now. Costs the crawl at load.
@export var live := false
## Meshes in these groups (and their children) aren't climbed.
@export var ignore_groups: Array[StringName] = [&"actors", &"no_vines"]

## Set on export: the mesh is a saved child, nothing to grow.
@export_storage var baked := false

var _mesh_node: MeshInstance3D
var _queued := false
var _tween: Tween
var _tris := 0


func _ready() -> void:
	if baked:
		for c in get_children():
			if c is MeshInstance3D:
				_mesh_node = c
		_apply_grown()
		_start_growth()
		return
	_queue()


func _queue() -> void:
	if _queued or not is_inside_tree() or baked:
		return
	_queued = true
	_build_later.call_deferred()


func _build_later() -> void:
	# (a couple of frames: the level's brushes and the other props build their meshes first)
	await get_tree().process_frame
	await get_tree().process_frame
	_queued = false
	if not is_inside_tree():
		return
	regrow()
	if not Engine.is_editor_hint():
		_start_growth()


func _start_growth() -> void:
	if Engine.is_editor_hint() or auto_grow <= 0.0:
		return
	grown = 0.0
	grow_to(1.0, auto_grow)


## Animates `grown` to `to` over `seconds` (emits grown_fully on reaching 1).
func grow_to(to: float, seconds: float) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, ^"grown", to, maxf(seconds, 0.01))
	if to >= 1.0:
		_tween.tween_callback(grown_fully.emit)


## Crawls the vines again over the meshes around them now and rebuilds the mesh.
func regrow() -> void:
	if baked:
		return
	var t0 := Time.get_ticks_msec()
	var cfg := _cfg()
	var reach := length * 1.15 + spread + (target.length() if use_target else 0.0) + 1.0
	var region := AABB(global_position - Vector3.ONE * reach, Vector3.ONE * reach * 2.0)
	var grid := VineBuilder.TriGrid.new()
	_gather(_scene_root(), region, grid)
	var tgt: Variant = to_global(target) if use_target else null
	var tendrils := VineBuilder.crawl(cfg, global_transform, tgt, grid)
	var mesh := VineBuilder.build_mesh(cfg, tendrils, global_transform)
	_tris = VineBuilder.triangles(mesh)
	if _mesh_node == null:
		_mesh_node = MeshInstance3D.new()
		_mesh_node.name = "Vines"
		_mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mesh_node, false, INTERNAL_MODE_BACK)
	_mesh_node.mesh = mesh
	_mesh_node.extra_cull_margin = leaf_wind + 0.1
	if mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, _material(stem_texture, stem_color, false))
	if mesh.get_surface_count() > 1:
		mesh.surface_set_material(1, _material(leaf_texture, leaf_color, true))
	_apply_grown()
	if OS.is_debug_build() and Engine.is_editor_hint():
		print("WorldVines %s: %d tendrils, %d tris, %d surface tris read, %d ms" % [name, tendrils.size(), _tris, grid.count(), Time.get_ticks_msec() - t0])


func triangle_count() -> int:
	return _tris


func _cfg() -> Dictionary:
	return {seed = seed, count = count, spread = spread, length = length, length_jitter = length_jitter,
		step = step, wander = wander, climb = climb, branches = branches, branch_length = branch_length,
		branch_depth = branch_depth, seek = seek, target_radius = target_radius, thickness = thickness,
		tip = tip, sides = sides, open_back = open_back, stem_bend = stem_bend, leaf_triangles = leaf_triangles, stem_tile = stem_tile, leaf_density = leaf_density, leaf_size = leaf_size,
		leaf_jitter = leaf_jitter, leaf_lift = leaf_lift}


func _material(tex: Texture2D, color: Color, cutout: bool) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter(&"tex", tex)
	m.set_shader_parameter(&"cutout", cutout)
	m.set_shader_parameter(&"color", color)
	m.set_shader_parameter(&"wind", leaf_wind if cutout else 0.0)
	return m


func _apply_grown() -> void:
	if _mesh_node:
		_mesh_node.set_instance_shader_parameter(&"grow", grown)
		_mesh_node.visible = grown > 0.0


func _scene_root() -> Node:
	var tree := get_tree()
	if Engine.is_editor_hint() and tree.edited_scene_root:
		return tree.edited_scene_root
	return tree.current_scene if tree.current_scene else tree.root


## The visible meshes in `region` (not actors, other vines, far cards, or `ignore_groups`).
func _gather(n: Node, region: AABB, grid: VineBuilder.TriGrid) -> void:
	if n == self or n is WorldVines or n is WorldTree:
		return
	for g in ignore_groups:
		if n.is_in_group(g):
			return
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh and mi.is_visible_in_tree() and mi.visibility_range_begin <= 0.0:
			var box := mi.global_transform * mi.get_aabb()
			if box.intersects(region):
				grid.add_faces(mi.mesh.get_faces(), mi.global_transform, region)
	for c in n.get_children(true):
		_gather(c, region, grid)


## Pick box for the level tools: round the roots.
func prop_bounds() -> AABB:
	var r := maxf(spread, 0.3) + 0.2
	return AABB(Vector3(-r, 0.0, -r), Vector3(r * 2.0, 0.6, r * 2.0))


## Export (LevelRoot.make_prop_nodes_for_export): the mesh becomes a saved child, unless live.
func bake_for_export(scene: Node) -> void:
	if live:
		return
	regrow()
	if _mesh_node == null:
		return
	remove_child(_mesh_node)
	add_child(_mesh_node, true)
	_mesh_node.owner = scene
	baked = true
