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
const MOSS_SHADER := preload("res://addons/n64_runtime/shaders/n64_vine_moss.gdshader")

enum Style {
	TUBES,  ## 3D stems (tubes / ground tents / flat base fill) with leaves
	CARDS,  ## each vine one flat strip, stem and leaves in its texture (no stem geometry)
}
enum LeafMode {
	SINGLE,  ## one leaf a triangle (leaf_texture)
	SPRIG,  ## three leaves a triangle (sprig_texture)
}
## Single leaf (vine_leaf) round its triangle: base corners and tip, in texture space.
const LEAF_TRI := [Vector2(-0.3, 1.0), Vector2(1.3, 1.0), Vector2(0.5, -0.07)]
## Sprig (vine_sprig): the stalks at the bottom apex, the fan inside (measured).
const SPRIG_TRI := [Vector2(0.5, 1.1), Vector2(-0.92, 0.0), Vector2(1.92, 0.0)]

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
## Bias up walls (0: go where they go; negative: droop down them, as from a wall top).
@export_range(-1.0, 1.0, 0.05) var climb := 0.3:
	set(v):
		climb = v
		_queue()
## Chance a tendril reaching an overhang (a doorway's top, a ledge) hangs down from it as a
## free strand instead of crawling under (0: never).
@export_range(0.0, 1.0, 0.05) var hang := 0.6:
	set(v):
		hang = v
		_queue()
## Longest hanging strand (some shorter).
@export_range(0.2, 10.0, 0.1, "suffix:m") var hang_length := 2.0:
	set(v):
		hang_length = v
		_queue()
## Leaves near the player flutter aside this much (metres; hanging strands are swung by
## their pendulums instead - see swing_damping).
@export_range(0.0, 2.0, 0.05) var player_push := 0.6:
	set(v):
		player_push = v
		_queue()
## Hanging strands: how quickly a swing dies away (per second; low = they swing on, heavy).
@export_range(0.0, 10.0, 0.05) var swing_damping := 0.7
## Hanging strands: how hard the body shoves them out of its way.
@export_range(10.0, 2000.0, 10.0) var swing_push := 500.0
## Stem thickness tapers only over the last this many metres (blunter tips).
@export_range(0.05, 10.0, 0.05, "suffix:m") var taper_length := 0.4:
	set(v):
		taper_length = v
		_queue()
## Hanging strands get this many times the leaves along them.
@export_range(1.0, 4.0, 0.1) var hang_leaves := 1.8:
	set(v):
		hang_leaves = v
		_queue()
## Hanging strands sway this much in the wind (metres at full wind, at their ends).
@export_range(0.0, 1.0, 0.01) var hang_sway := 0.15:
	set(v):
		hang_sway = v
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
## Roots' heading: all set off towards the target within this fan (degrees; 360: every
## way, as from a planted root clump).
@export_range(0.0, 360.0, 1.0, "suffix:°") var fan := 360.0:
	set(v):
		fan = v
		_queue()
## How much the tendrils share their wandering (0: each its own; 1: one path, a bundle that
## flows together like a single creeping mass).
@export_range(0.0, 1.0, 0.05) var bundle := 0.0:
	set(v):
		bundle = v
		_queue()
## Seek a point (local): the tendrils head for it and wrap round what's there.
@export var use_target := false:
	set(v):
		use_target = v
		_queue()
@export var target := Vector3(0, 0.5, -4):
	set(v):
		target = v
		_queue()
## Once at the target, pour down from it (they climb to it, then cascade down over the far
## side, a ledge, a doorway's top).
@export var cascade := false:
	set(v):
		cascade = v
		_queue()
## Cascade: how far each goes on across the target (to its far side from where it came in)
## before turning down - spreads them over it first.
@export_range(0.0, 10.0, 0.1, "suffix:m") var cascade_spread := 1.5:
	set(v):
		cascade_spread = v
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

## How the vines are drawn: 3D stems with leaves, or vine cards.
@export var style := Style.TUBES:
	set(v):
		style = v
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
## Stems on the ground (surface facing up) as a sunk tent: the ring turned 45° so a corner
## points up, half under the ground, only its top faces drawn (4 sides: two faces).
@export var ground_tent := true:
	set(v):
		ground_tent = v
		_queue()
## How much a surface must face up to count as ground (1 = flat only).
@export_range(0.0, 1.0, 0.01) var tent_up := 0.7:
	set(v):
		tent_up = v
		_queue()
## Tents sunk this far below their middle (share of the radius; 0: side corners on the ground).
@export_range(0.0, 0.8, 0.01) var tent_sink := 0.0:
	set(v):
		tent_sink = v
		_queue()
## Tents this much wider than the stem (they show only their top: wider keeps them as stout).
@export_range(0.5, 2.0, 0.05) var tent_width := 1.3:
	set(v):
		tent_width = v
		_queue()
## Base fill: where a vine runs under another (trunks over branches, thicker over thinner)
## it's a flat strip on the surface (one face); the one on top stays 3D.
@export var flat_under := false:
	set(v):
		flat_under = v
		_queue()
## A share of the thinnest tendrils flat all along (a cheap fill under the 3D detail).
@export_range(0.0, 1.0, 0.05) var fill_share := 0.0:
	set(v):
		fill_share = v
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

@export_group("Moss")
## A band of moss under each vine on its surfaces, blended in (0: none).
@export_range(0.0, 3.0, 0.05, "suffix:m") var moss_width := 0.9:
	set(v):
		moss_width = v
		_queue()
@export var moss_texture: Texture2D = preload("res://textures/grass/1_moss.res"):
	set(v):
		moss_texture = v
		_queue()
## Metres per moss texture repeat.
@export_range(0.1, 8.0, 0.05, "suffix:m") var moss_tile := 1.2:
	set(v):
		moss_tile = v
		_queue()
@export_range(0.0, 1.0, 0.05) var moss_opacity := 0.75:
	set(v):
		moss_opacity = v
		_queue()
@export var moss_color := Color(0.5, 0.62, 0.4):
	set(v):
		moss_color = v
		_queue()

@export_group("Cards")
## CARDS: the vine texture (tiling along its length).
@export var card_texture: Texture2D = preload("res://textures/plants/vine_card.res"):
	set(v):
		card_texture = v
		_queue()
## CARDS: strip width at the roots (branches narrower), and the texture's tile length.
@export_range(0.1, 2.0, 0.01, "suffix:m") var card_width := 0.5:
	set(v):
		card_width = v
		_queue()
## TUBES: this share of the tendrils are vine cards under the 3D ones, intermixed (the
## lowest in the pecking order: branches before trunks, thinner before thicker; 0: none).
@export_range(0.0, 1.0, 0.05) var card_share := 0.0:
	set(v):
		card_share = v
		_queue()
## TUBES: a stretch of 3D vine running under another is a vine card (leaves and all)
## instead of a bare flat strip.
@export var fill_cards := false:
	set(v):
		fill_cards = v
		_queue()
## Cards: each strip its own start in the leaf pattern, mirrored or not, its own repeat
## length and a width that swells and narrows (0: all alike).
@export_range(0.0, 1.0, 0.05) var card_variation := 0.7:
	set(v):
		card_variation = v
		_queue()
## Cards: 3D sprigs on top of the cards per metre (a little depth; 0: none).
@export_range(0.0, 10.0, 0.1) var card_leaves := 1.0:
	set(v):
		card_leaves = v
		_queue()

@export_group("Leaves")
## Bare stems near the source: no leaves for this far from the roots (metres)...
@export_range(0.0, 30.0, 0.1, "suffix:m") var bare_start := 0.0:
	set(v):
		bare_start = v
		_queue()
## ...then leaves fading in over this far.
@export_range(0.0, 20.0, 0.1, "suffix:m") var bare_ramp := 2.0:
	set(v):
		bare_ramp = v
		_queue()
## One leaf or a sprig of three per triangle.
@export var leaf_mode := LeafMode.SPRIG:
	set(v):
		leaf_mode = v
		_queue()
@export var sprig_texture: Texture2D = preload("res://textures/plants/vine_sprig.res"):
	set(v):
		sprig_texture = v
		_queue()
## At most this many leaf triangles in each leaf_cap_cell-wide patch of surface (the vines on
## top first: dense mats lose the leaves underneath; 0: no cap).
@export_range(0, 20) var leaf_cap := 3:
	set(v):
		leaf_cap = v
		_queue()
@export_range(0.05, 2.0, 0.01, "suffix:m") var leaf_cap_cell := 0.35:
	set(v):
		leaf_cap_cell = v
		_queue()
## Leaves per metre of stem (0: bare).
@export_range(0.0, 20.0, 0.1) var leaf_density := 5.0:
	set(v):
		leaf_density = v
		_queue()
@export_range(0.05, 1.0, 0.01, "suffix:m") var leaf_size := 0.3:
	set(v):
		leaf_size = v
		_queue()
## Leaf sizes vary this much (smaller and bigger).
@export_range(0.0, 0.9, 0.05) var leaf_jitter := 0.35:
	set(v):
		leaf_jitter = v
		_queue()
## How loosely leaves are set: gathered in clumps with gaps, further from the stem, turned,
## tipped and now and then two on one side (0: evenly, neatly alternating).
@export_range(0.0, 1.0, 0.05) var leaf_scatter := 0.0:
	set(v):
		leaf_scatter = v
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

## Where bodies that part the hanging strands are (feet position, body radius) - the player
## sets it each frame (player.gd), next to the grass's n64_bender0.
static var bender := Vector4(0, -1000, 0, 0)

var _mesh_node: MeshInstance3D
var _strands := []  # [top, rest end (world), length, room (8 directions)] per hanging strand
var _off := PackedVector2Array()
var _vel := PackedVector2Array()
var _wind := Vector4(1, 0, 0, 0)
var _wind_at := -10.0
var _swing_time := 0.0
var _queued := false
var _tween: Tween
var _tris := 0
var _hanging := 0  # strands hanging free (last grown)


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
	_hanging = tendrils.filter(func(t): return t.hang_from >= 0).size()
	if _mesh_node == null:
		_mesh_node = MeshInstance3D.new()
		_mesh_node.name = "Vines"
		_mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mesh_node, false, INTERNAL_MODE_BACK)
	_mesh_node.mesh = mesh
	_mesh_node.extra_cull_margin = leaf_wind + 0.1 + hang_length * 0.8
	_strands.clear()
	for sd in mesh.get_meta(&"strands", []):
		var top: Vector3 = _mesh_node.global_transform * (sd[0] as Vector3)
		var end: Vector3 = _mesh_node.global_transform * (sd[1] as Vector3)
		_strands.append([top, end, sd[2], _room(grid, top, end, float(sd[2]))])
	_off.resize(_strands.size())
	_vel.resize(_strands.size())
	_off.fill(Vector2.ZERO)
	_vel.fill(Vector2.ZERO)
	var leaf_tex := sprig_texture if leaf_mode == LeafMode.SPRIG else leaf_texture
	for si in mesh.get_surface_count():
		match mesh.surface_get_name(si):
			"stems": mesh.surface_set_material(si, _material(stem_texture, stem_color, false))
			"leaves": mesh.surface_set_material(si, _material(leaf_tex, leaf_color, true))
			"cards": mesh.surface_set_material(si, _material(card_texture, leaf_color, true, hang_sway))
			"moss":
				var mm := ShaderMaterial.new()
				mm.shader = MOSS_SHADER
				mm.set_shader_parameter(&"tex", moss_texture)
				mm.set_shader_parameter(&"color", moss_color)
				mm.set_shader_parameter(&"opacity", moss_opacity)
				mesh.surface_set_material(si, mm)
	_apply_grown()
	if OS.is_debug_build() and Engine.is_editor_hint():
		print("WorldVines %s: %d tendrils, %d tris, %d surface tris read, %d ms" % [name, tendrils.size(), _tris, grid.count(), Time.get_ticks_msec() - t0])


## Hanging strands as pendulums: weight (a period from their length), little damping, the
## wind's slow sway, the body shoving them out of its way - they part like a bead curtain
## and swing back.
func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _strands.is_empty() or _mesh_node == null:
		return
	_swing_time += delta
	if _swing_time - _wind_at > 1.0:
		_wind_at = _swing_time
		var w = RenderingServer.global_shader_parameter_get(&"n64_wind")
		if w is Vector4:
			_wind = w
	var wd := Vector2(_wind.x, _wind.y)
	var b := bender
	var out := []
	for j in _strands.size():
		var top: Vector3 = _strands[j][0]
		var end: Vector3 = _strands[j][1]
		var l: float = _strands[j][2]
		var w2 := 9.8 / maxf(l * 0.65, 0.2)  # (a hanging strand's mass spread along it)
		# Rest: leaning a little with the wind, slowly breathing.
		var rest := wd * hang_sway * _wind.z * (0.6 + 0.4 * sin(_swing_time * 0.6 + j * 1.7))
		var acc := -w2 * (_off[j] - rest) - swing_damping * _vel[j]
		_vel[j] += acc * delta
		_off[j] += _vel[j] * delta
		# The body: moves the strand out of its way (where it touches it, just enough), and
		# hands it some speed - it swings on, then back.
		if b.w > 0.0:
			for u: float in [0.35, 0.6, 0.85, 1.0]:
				var pt := top.lerp(end, u) + Vector3(_off[j].x, 0.0, _off[j].y) * u
				if pt.y < b.y - 0.1 or pt.y > b.y + 1.9:
					continue
				var d := Vector2(pt.x - b.x, pt.z - b.z)
				var dist := d.length()
				if dist < b.w:
					var away := d / dist if dist > 0.001 else Vector2(cos(j * 2.4), sin(j * 2.4))
					var fix := away * (b.w - dist) / u
					_off[j] += fix * 0.5
					_vel[j] += fix * swing_push * 0.01
			if _vel[j].length() > 3.0:
				_vel[j] = _vel[j].normalized() * 3.0
		# Walls: never further than the room it has that way (and no speed on into them).
		var o := _off[j]
		if o.length() > 0.0001:
			var room := minf(_room_towards(_strands[j][3], o), l * 0.9)
			if o.length() > room:
				var dir := o.normalized()
				_off[j] = dir * room
				var into := _vel[j].dot(dir)
				if into > 0.0:
					_vel[j] -= dir * into * 1.3  # (and a little bounce back)
		out.append(Vector4(_off[j].x, _off[j].y, _off[j].length_squared() / (2.0 * l), 0.0))
	for si in _mesh_node.mesh.get_surface_count():
		var m := _mesh_node.mesh.surface_get_material(si) as ShaderMaterial
		if m:
			m.set_shader_parameter(&"strands", out)


## How far a strand's end may swing in 8 directions (world xz, from +x round to +z) before
## some part of it would touch a wall: rays from points down it, each allowed swing scaled to
## the end (a point u of the way down moves u times the end's swing).
static func _room(grid: VineBuilder.TriGrid, top: Vector3, end: Vector3, l: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for k in 8:
		var a := TAU * k / 8.0
		var d := Vector3(cos(a), 0.0, sin(a))
		var room := l * 0.9
		for u: float in [0.25, 0.5, 0.75, 1.0]:
			var p := top.lerp(end, u)
			var hit := grid.ray(p, p + d * (l * 0.9 * u + 0.1))
			if not hit.is_empty():
				room = minf(room, maxf(p.distance_to(hit.position) - 0.08, 0.0) / u)
		out.append(room)
	return out


## The room a strand has towards xz direction `v` (between its two nearest measured directions).
static func _room_towards(room: PackedFloat32Array, v: Vector2) -> float:
	var a := fposmod(atan2(v.y, v.x), TAU) / (TAU / 8.0)
	var i := int(a) % 8
	return lerpf(room[i], room[(i + 1) % 8], a - floorf(a))


func triangle_count() -> int:
	return _tris


func _cfg() -> Dictionary:
	var sprig := leaf_mode == LeafMode.SPRIG
	var c := _cfg_raw()
	c.leaf_density = leaf_density / (3.0 if sprig else 1.0)
	c.card_leaf_density = card_leaves
	c.leaf_size = leaf_size * (1.7 if sprig else 1.0)
	return c


func _cfg_raw() -> Dictionary:
	return {seed = seed, count = count, spread = spread, length = length, length_jitter = length_jitter,
		step = step, wander = wander, climb = climb, branches = branches, branch_length = branch_length,
		branch_depth = branch_depth, fan = fan, bundle = bundle, cascade = cascade, moss_width = moss_width, moss_tile = moss_tile, taper_length = taper_length, hang_leaves = hang_leaves, cascade_spread = cascade_spread, bare_start = bare_start, bare_ramp = bare_ramp, hang = hang, hang_length = hang_length, seek = seek, target_radius = target_radius, thickness = thickness,
		tip = tip, sides = sides, open_back = open_back, stem_bend = stem_bend, ground_tent = ground_tent, tent_up = tent_up, tent_sink = tent_sink, tent_width = tent_width, flat_under = flat_under, fill_share = fill_share, leaf_triangles = leaf_triangles, stem_tile = stem_tile, leaf_density = leaf_density, leaf_size = leaf_size,
		leaf_jitter = leaf_jitter, leaf_lift = leaf_lift,
		cards = style == Style.CARDS, card_width = card_width, card_share = card_share, fill_cards = fill_cards, card_variation = card_variation, leaf_scatter = leaf_scatter, leaf_cap = leaf_cap, leaf_cap_cell = leaf_cap_cell,
		leaf_tri = SPRIG_TRI if leaf_mode == LeafMode.SPRIG else LEAF_TRI}


func _material(tex: Texture2D, color: Color, cutout: bool, sway := -1.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter(&"tex", tex)
	m.set_shader_parameter(&"cutout", cutout)
	m.set_shader_parameter(&"color", color)
	# (stems / cards: only hanging strands carry a sway weight)
	m.set_shader_parameter(&"wind", leaf_wind if cutout and sway < 0.0 else 0.0)  # (strands swing by their pendulums)
	# (the player parts hanging strands; leaves only flutter a little - pushed far they'd
	# go into the wall)
	m.set_shader_parameter(&"bend", player_push * (0.25 if cutout and sway < 0.0 else 1.0))
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
