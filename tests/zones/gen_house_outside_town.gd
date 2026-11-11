extends Node
## Generates res://zones/town1/house_outside_town.tscn from the measured layout
## references/zones/house_outside_town.json (from screenshots/house_outside_town.png; plan:
## references/zones/house_outside_town_plan.png): a lane between dry stone walls leading out
## of town, a stone field barn with a lean-to, a field gate, a sycamore opposite, pastures
## either side and a small field where the lane opens out. All level brushes (house, fence,
## tree and passage brushes too), so it's edited with the level tools afterwards.
##   godot --headless --path . tests/zones/gen_house_outside_town.tscn
## Rerunning rebuilds the level from the layout (edits made since are lost).

const PATH := "res://zones/town1/house_outside_town.tscn"
const LAYOUT := "res://references/zones/house_outside_town.json"
const MARKET := "res://zones/town1/town_1_market_square.tscn"

var data: LevelData
var root: LevelRoot
var L: Dictionary
var T_GRASS: int
var T_TRACK: int
var T_WALL: int
var T_ROOF: int


func _ready() -> void:
	await get_tree().process_frame
	L = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PATH.get_base_dir()))
	if not FileAccess.file_exists(PATH):
		var err: Error = load("res://addons/n64_level_tools/zone_templates.gd").create(PATH, true)
		print("create: ", error_string(err))
	var data_path := PATH.get_basename() + "_level.res"
	data = load(data_path)
	var uid := ResourceLoader.get_resource_uid(data_path)
	data.textures.assign([load("res://textures/grass/157_green_grass.res"), load("res://textures/ground/brown_earth_2.res"),
		load("res://textures/rock/river_rock_1.res"), load("res://textures/roof/shingles_3.res")])
	T_GRASS = 0; T_TRACK = 1; T_WALL = 2; T_ROOF = 3
	data.brushes = []
	# Built inside the zone itself, so the lighting bake sees its sun and sky.
	var zone: Node = (load(PATH) as PackedScene).instantiate()
	add_child(zone)
	root = zone.get_node("Level")
	root.data = data
	_build()
	var schedule := LightingSchedule.load_project()
	if schedule and LevelData.mode_is_timed(data.lighting_mode):
		var keyed := LevelLighting.bake_keys(root, [root], LevelLighting.gather_lights(zone), schedule)
		for brush in keyed:
			var arr: Array[PackedColorArray] = []
			arr.assign(keyed[brush])
			brush.corner_lighting_keys = arr
		print("lit %d brushes (timed)" % keyed.size())
	var res := LevelBaker.bake(data, false)
	data.baked_mesh = res.mesh
	data.baked_chunks = res.chunks
	data.baked_collision = null
	data.baked_collision_parts = res.collision_parts
	data.baked_collision_surfaces = res.collision_surfaces
	var err := ResourceSaver.save(data, data_path, ResourceSaver.FLAG_COMPRESS)
	if uid != ResourceUID.INVALID_ID:
		ResourceSaver.set_uid(data_path, uid)
	print("saved %s: %s, %d brushes, %d tris" % [data_path, error_string(err), data.brushes.size(), res.stats.baked_tris])
	zone.queue_free()
	await get_tree().process_frame
	_scene_setup()
	get_tree().quit()


## Spawn at the town end of the lane, the zone's name, fog for the open country.
func _scene_setup() -> void:
	var scene: PackedScene = load(PATH)
	var z := scene.instantiate()
	var e: Array = L.entrance.pos
	(z.get_node("Spawn_default") as Node3D).position = Vector3(e[0], 0.0, float(e[2]) - 2.0)
	(z.get_node("Spawn_default") as Node3D).rotation.y = 0.0
	z.set(&"display_name", "Outside Town")
	var fog := FogSettings.new()
	fog.start = float(L.fog.start)
	fog.end = float(L.fog.end)
	z.set(&"fog", fog)
	var packed := PackedScene.new()
	packed.pack(z)
	ResourceSaver.save(packed, PATH)
	z.free()


func _v(p: Array, y := 0.0) -> Vector3:
	return Vector3(float(p[0]), y, float(p[1]))


func _add(b: LevelBrush) -> LevelBrush:
	b.tag = StringName("%s_%08x" % [b.tag if b.tag != &"" else &"brush", randi()])
	data.add_brush(b)
	return b


func _paint(b: LevelBrush, tex: int, surface := 0) -> void:
	var n := b.get_faces().size()
	var ft := PackedInt32Array()
	ft.resize(n)
	ft.fill(tex)
	b.face_textures = ft
	var fs := PackedInt32Array()
	fs.resize(n)
	fs.fill(surface)
	b.face_surfaces = fs


func _shape(shape: BrushShapes.Shape, size: Vector3, xf: Transform3D, segments := 1) -> LevelBrush:
	var b := LevelBrush.new()
	b.shape = shape
	b.size = size
	b.segments = segments
	b.generate_from_shape()
	b.transform = xf
	return b


## A run of wall from a to b (centre line): a block overlapping its neighbours at the corners.
func _wall(a: Vector3, b: Vector3, h: float, t: float, tex: int, mode := LevelBrush.BakeMode.VISUAL_AND_COLLISION) -> void:
	var d := b - a
	var yaw := atan2(-d.z, d.x)
	var w := _shape(BrushShapes.Shape.BLOCK, Vector3(d.length() + t, h, t), Transform3D(Basis(Vector3.UP, yaw), (a + b) * 0.5))
	w.bake_mode = mode
	w.tag = &"wall"
	_paint(w, tex, Surface.Sound.STONE)
	_add(w)


func _build() -> void:
	var bx: Array = L.boundary.x
	var bz: Array = L.boundary.z
	# Ground: grass well past the walls (fog takes the far side).
	var g := _shape(BrushShapes.Shape.GRID, Vector3(120, 0, 140), Transform3D(Basis(), Vector3(0, 0, 0)), 14)
	g.tag = &"ground"
	_paint(g, T_GRASS, Surface.Sound.GRASS)
	_add(g)
	# The worn track up the lane (just above the grass, drawn only).
	var track: Array = L.lane.track
	for i in track.size() - 1:
		var a := _v(track[i], 0.02)
		var b := _v(track[i + 1], 0.02)
		var d := b - a
		var yaw := atan2(d.x, d.z)
		var p := _shape(BrushShapes.Shape.PLANE, Vector3(float(L.lane.track_width), 0, d.length() + 0.5), Transform3D(Basis(Vector3.UP, yaw), (a + b) * 0.5))
		p.bake_mode = LevelBrush.BakeMode.VISUAL_ONLY
		p.tag = &"track"
		_paint(p, T_TRACK, Surface.Sound.DIRT)
		_add(p)
	# Dry stone walls.
	var h := float(L.walls.height)
	var t := float(L.walls.thickness)
	for k in L.walls:
		if L.walls[k] is Array:
			var pts: Array = L.walls[k]
			for i in pts.size() - 1:
				_wall(_v(pts[i]), _v(pts[i + 1]), h, t, T_WALL)
	# The zone's edge: invisible collision above the outer walls (no climbing out).
	var edge := [[[bx[0], bz[1]], [bx[0], bz[0]]], [[bx[1], bz[1]], [bx[1], bz[0]]], [[bx[0], bz[0]], [bx[1], bz[0]]],
		[[bx[0], bz[1]], [-2.0, bz[1]]], [[2.0, bz[1]], [bx[1], bz[1]]]]
	for e in edge:
		var a := _v(e[0], 0.0)
		var b := _v(e[1], 0.0)
		_wall(a, b, h + float(L.boundary.invisible_height), t, T_WALL, LevelBrush.BakeMode.COLLISION_ONLY)
	_grass()
	_barn()
	_gate()
	_tree()
	_edge_trees()
	_entrance()


## Auto grass over the grass ground inside the zone's edge (the walls, barn and track cut it).
func _grass() -> void:
	var G: Dictionary = L.grass
	var s := GrassSettings.new()
	var bx: Array = L.boundary.x
	var bz: Array = L.boundary.z
	s.area = Rect2(float(bx[0]) - 1.0, float(bz[0]) - 1.0, float(bx[1]) - float(bx[0]) + 2.0, float(bz[1]) - float(bz[0]) + 6.0)
	s.height = float(G.height)
	s.height_var = float(G.height_var)
	s.tufts = float(G.tufts)
	s.edge_tufts = float(G.edge_tufts)
	data.grass = s


## The field barn (a house brush: bare stone, slate roof, no trim, no door yet) with its
## lean-to across the town-facing gable.
func _barn() -> void:
	var B: Dictionary = L.barn
	var spec := HouseSpec.new()
	spec.width = float(B.along_lane) - 0.1  # the ridge runs along the lane
	spec.depth = float(B.across) - 0.1
	spec.storeys = 1
	spec.storey_height = float(B.storey_height)
	spec.foundation = float(B.foundation)
	spec.wall_thickness = 0.45
	spec.wall_texture = load("res://textures/rock/river_rock_1.res")
	spec.wall_color = Color(0.72, 0.7, 0.66)
	spec.foundation_texture = load("res://textures/rock/river_rock_1.res")
	spec.roof_texture = load("res://textures/roof/shingles_3.res")
	spec.roof_color = Color(0.85, 0.83, 0.8)
	spec.roof_pitch = 35.0
	spec.overhang = 0.25
	spec.trim_texture = null
	spec.wainscot_height = 0.0
	var b := LevelBrush.new()
	b.tag = &"house"
	b.hand_edited = true
	b.house = spec
	var c := _v(B.centre)
	# House +Z (its front) faces the lane (+X); its width (ridge) along Z.
	b.transform = Transform3D(Basis(Vector3.UP, PI * 0.5), c)
	_add(b)
	root._generate_house(b)
	# Lean-to: stone walls up to the eaves at the front, a slate roof rising to the barn.
	var lt: Dictionary = L.lean_to
	var x0 := float(lt.x[0])
	var x1 := float(lt.x[1])
	var z0 := float(lt.from_z)
	var z1 := float(lt.to_z)
	var wall_h := float(lt.wall_height)
	var body := _shape(BrushShapes.Shape.BLOCK, Vector3(x1 - x0, wall_h, z1 - z0), Transform3D(Basis(), Vector3((x0 + x1) * 0.5, 0, (z0 + z1) * 0.5)))
	body.tag = &"lean_to"
	_paint(body, -1, Surface.Sound.STONE)
	body.face_textures.fill(_palette(spec.wall_texture))
	_add(body)
	var roof_rise := float(lt.roof_top) - wall_h
	var roof := _shape(BrushShapes.Shape.RAMP, Vector3(x1 - x0 + 0.3, roof_rise, z1 - z0 + 0.3),
		Transform3D(Basis(), Vector3((x0 + x1) * 0.5, wall_h, (z0 + z1) * 0.5 + 0.15)))
	roof.tag = &"lean_to_roof"
	_paint(roof, T_ROOF, Surface.Sound.STONE)
	_add(roof)


func _palette(tex: Texture2D) -> int:
	var i := data.textures.find(tex)
	if i < 0:
		data.textures.append(tex)
		i = data.textures.size() - 1
	return i


## The field gate beside the barn: a fence brush in the default (wooden) style.
func _gate() -> void:
	var G: Dictionary = L.gate
	var a := _v(G.from)
	var b := LevelBrush.new()
	b.tag = &"fence"
	b.hand_edited = true
	b.cutout = true
	b.transform = Transform3D(Basis(), a)
	b.fence_style = load("res://game/world/fence_default_style.tres")
	b.fence_points = PackedVector3Array([Vector3.ZERO, _v(G.to) - a])
	_add(b)
	root._generate_fence(b)


## The sycamore opposite the barn (a tree prop brush, fixed seed).
func _tree() -> void:
	var T: Dictionary = L.tree
	var spec := PropSpec.new()
	spec.kind = PropSpec.Kind.TREE
	var sp: Resource = load("res://addons/n64_level_tools/trees/species/sycamore.tres")
	spec.settings = {species = sp, seed = 7, size = float(T.height) / float(sp.height)}
	var b := LevelBrush.new()
	b.tag = &"prop"
	b.hand_edited = true
	b.transform = Transform3D(Basis(), _v(T.pos))
	b.prop = spec
	_add(b)
	root._sync_props()
	root._generate_prop(b)


## Trees round the zone's edge (layout edge_trees): inside the walls full 3D (the player
## walks round them), just outside them 3D without collision, far out cards only.
func _edge_trees() -> void:
	for group in ["inside", "near", "far"]:
		for t: Array in L.edge_trees[group]:
			var spec := PropSpec.new()
			spec.kind = PropSpec.Kind.TREE
			spec.settings = {species = load("res://addons/n64_level_tools/trees/species/%s.tres" % t[2]), seed = int(t[3]), size = float(t[4])}
			if group != "inside":
				spec.settings.collide = false  # out of reach beyond the walls
			if group == "far":
				spec.settings.card_only = true  # 2 triangles
			var b := LevelBrush.new()
			b.tag = &"prop"
			b.hand_edited = true
			b.transform = Transform3D(Basis(Vector3.UP, float(int(t[3]) % 8) * PI / 4.0), Vector3(float(t[0]), 0.0, float(t[1])))
			b.prop = spec
			_add(b)
			root._sync_props()
			root._generate_prop(b)


## Back to town: a passage at the lane's town end, out towards +Z.
func _entrance() -> void:
	var E: Dictionary = L.entrance
	var spec := PassageSpec.new()
	spec.target_zone = MARKET
	spec.target_spawn = &"north"
	spec.spawn_id = &"market"
	spec.width = float(E.width)
	spec.height = 3.0
	spec.depth = 5.0
	spec.shell = false
	spec.floor_texture = T_GRASS
	var b := LevelBrush.new()
	b.tag = &"passage"
	b.hand_edited = true
	b.passage = spec
	var p: Array = E.pos
	b.transform = Transform3D(Basis(Vector3.UP, PI), Vector3(float(p[0]), float(p[1]), float(p[2])))
	_add(b)
	root._generate_passage(b)
