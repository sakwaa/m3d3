extends Node
## Generates res://zones/forest/forest_citadel.tscn: the forest citadel blockout (Permivor doc,
## "Forest citadel"). A Lalibela-style church on a terrace cut into a forested mountainside:
##  - the arrival at the foot of the slope (south); a forest climbing 30 m to the terrace by
##    dirt switchbacks with rough stone-slab steps at the turns (user refs f1-f4);
##  - the terrace: flat, cut into the hillside, its carved walls (sandstone) rising behind and
##    beside it to 20 m at the back; the church standing free on it - a Greek cross 36 m across
##    (arms 12 m wide, 48 m tall), a central tower 64 m - on a stepped plinth, a stone walkway
##    round it; carved stairs up the east wall to the river terrace above;
##  - the river terrace (y 50, tilted downhill to the east): the river falls down the back
##    cliff into a boulder pool (refs f5-f7), then splits round a long gravel island (a braided
##    river): a main branch and a side branch on the terrace's edge. A fork gate (ScrewGate on
##    a capstan) across the side branch's head; below it a basin held by a gravel bar - dry
##    while the gate is shut, filling level with the gate, spilling over the bar and turning
##    the noria (Noria) only once full. The wheel's trough feeds an aqueduct over the carved
##    wall into the north arm high up;
##  - the north arm's end: a doorway at the terrace floor filled by two blocks (MachineDoor)
##    that shift aside once the wheel runs (capstan "fork" -> gate "gate" -> water "side" ->
##    wheel "wheel" -> doors);
##  - the mountain wrapping round the back and sides; the river goes under it to the east
##    beneath a pile of boulders; forest (mostly firs) on the slopes; Forest clouds weather
##    most days (Zone.local_weather; refs c1-c4).
## All level brushes and prop brushes (edited with the level tools afterwards).
##   godot --headless --path . tests/zones/gen_forest_citadel.tscn
## Rerunning rebuilds the level (edits made since are lost).

## CITADEL_OUT=res://...tscn: generate into a copy instead (e.g. while the editor is open).
var PATH: String = OS.get_environment("CITADEL_OUT") if OS.get_environment("CITADEL_OUT") != "" else "res://zones/forest/forest_citadel.tscn"
const SPECIES := "res://addons/n64_level_tools/trees/species/"

var data: LevelData
var root: LevelRoot
var T_GRASS: int
var T_CLIFF: int
var T_FLOOR: int
var T_CHURCH: int
var T_RIVER: int
var T_STEPS: int
var T_GRAVEL: int
var T_BOULDER: int
var T_DIRT: int
## The waterfall's foot (x, z) and the river's last row upstream (x).
var _fall := Vector2.ZERO
var _fall_x0 := -100.0

## The slope and terrace (metres; the arrival is y 0): the hillside rises from ARRIVE_Z to the
## terrace's front (FRONT_Z) at P, on up to its back wall (TERRACE_Z) at UP - the river terrace.
## The terrace cut into it: |x| < TERRACE_X, FRONT_Z..TERRACE_Z, flat at P.
const ARRIVE_Z := -128.0
const FRONT_Z := -20.0
const TERRACE_Z := 46.0
const TERRACE_X := 46.0
const P := 30.0
const UP := 50.0
## The church on it: centre CHURCH_Z; cross half span, arm half width, arms' and tower's heights.
const CHURCH_Z := 13.0
const ARM := 18.0
const ARM_W := 6.0
const ARM_H := 48.0
const TOWER_H := 64.0
## Paths: the switchbacks up the hillside (x, z; `true` = a stone-step climb straight up the
## slope to the next point); half width; the walkway ring round the church (x, z half spans).
const TRAIL := [[0.0, -150.0, false], [0.0, -126.0, false], [36.0, -114.0, true], [36.0, -104.0, false],
	[-36.0, -88.0, true], [-36.0, -78.0, false], [36.0, -62.0, true], [36.0, -52.0, false],
	[-36.0, -36.0, true], [-36.0, -28.0, false], [-12.0, -22.0, false], [0.0, -20.0, false]]
const PATH_HALF := 1.5
const RING := Vector2(23.0, 0.0)  # (x half span; z span below)
const RING_Z := Vector2(-10.0, 37.0)
## The river (flows +X, downhill) on the river terrace (UP), which tilts SLOPE (level at its
## edge, fully tilted a few metres in). Banks BANK_UP above the main water, the island ISLE_UP; main
## water DEEP. Trunk z 54..74 (+ a gentle bend); between ISLE_X the island (up to ISLE_MAX
## wide) splits it: the side branch SIDE_W wide on the south, the main branch north of it.
## Side branch: the gate at GATE_X; the basin (POOL_DEEP, its surface POOL_SLOPE) to BAR_X,
## then the bar rising to its crest (CREST_UP over the river) at CREST_X, then down to the river.
const SLOPE := 0.02
const POOL_SLOPE := 0.004
const BANK_UP := 1.4
const ISLE_UP := 1.1
const DEEP := 1.6
const POOL_DEEP := 1.8
const CREST_UP := 0.4
const RIVER_Z := 64.0
const RIVER_W := 20.0
const SIDE_W := 6.7
const ISLE_MAX := 14.0
const ISLE_X := Vector2(-45.0, 45.0)
const GATE_X := -34.0
const BAR_X := 18.0
const CREST_X := 30.0
const BANK_W := 2.5  # bank slope width
const WHEEL_X := 1.0
## The mountain north of the river: its cliff's foot CLIFF_GAP from the north bank, the line
## kinked every 30 m by these offsets (a few degrees off the river's line each stretch); the
## face rises CLIFF_H over CLIFF_RUN (both varying along it), then the top slopes on up.
const CLIFF_GAP := 20.0
const CLIFF_KINKS := [2.5, -1.5, 3.0, 0.0, -3.0, 1.0, 3.5, -1.0, -2.5, 2.0, 0.5, -2.0, 3.0, -1.5]
## The side walls (the mountain wrapping round): their feet at x WEST_X / EAST_X (kinked along
## z the same way), fading out down the hillside (SIDE_FADE z). Upstream (west of the island)
## the river turns north into the back cliff, where it falls (TURN: metres north at 24 m past
## the island's head, squared); a plunge pool POOL_R round the waterfall's foot.
const WEST_X := -80.0
const EAST_X := 72.0
const SIDE_FADE := Vector2(-60.0, 0.0)
const TURN := 30.0
const POOL_R := 9.0
const CLIFF_H := 38.0
const CLIFF_RUN := 7.5
## The side spurs (east side; the west mirrors it): the valley side's foot (x, z) from the
## entrance cleft (a ~11 m gap at the arrival) up to the side walls, each stretch one big
## faceted rock (its height over the ground there). Behind them the land climbs on
## (SPUR_RISE per metre past SPUR_BACK, up to SPUR_RISE_MAX), faded out up by the terrace.
const SPUR := [Vector3(5.5, -164.0, 24.0), Vector3(6.0, -140.0, 30.0), Vector3(46.0, -122.0, 34.0),
	Vector3(58.0, -92.0, 40.0), Vector3(70.0, -62.0, 44.0), Vector3(77.0, -30.0, 44.0)]
const SPUR_DEPTH := 26.0
const SPUR_BACK := 12.0
const SPUR_RISE := 0.6
const SPUR_RISE_MAX := 42.0


func _ready() -> void:
	await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PATH.get_base_dir()))
	if not FileAccess.file_exists(PATH):
		var err: Error = load("res://addons/n64_level_tools/zone_templates.gd").create(PATH, true)
		print("create: ", error_string(err))
	var data_path := PATH.get_basename() + "_level.res"
	data = load(data_path)
	var uid := ResourceLoader.get_resource_uid(data_path)
	data.textures.assign([load("res://textures/grass/157_green_grass.res"), load("res://textures/rock/rock_cliff.res"),
		load("res://textures/ground/dirt_ground.res"), load("res://textures/rock/sandstone_2.res"),
		load("res://textures/rock/river_rock_1.res"), load("res://textures/rock/stone_blocks_granite.res"),
		load("res://textures/ground/sand_2.res"), load("res://textures/rock/granite_3.res"),
		load("res://textures/ground/brown_earth_2.res")])
	T_GRASS = 0; T_CLIFF = 1; T_FLOOR = 2; T_CHURCH = 3; T_RIVER = 4; T_STEPS = 5; T_GRAVEL = 6; T_BOULDER = 7; T_DIRT = 8
	data.brushes = []
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


## Spawn at the foot of the slope, facing up it; the name; its own weather (Forest clouds most
## days); forest fog otherwise.
func _scene_setup() -> void:
	var scene: PackedScene = load(PATH)
	var z := scene.instantiate()
	(z.get_node("Spawn_default") as Node3D).position = Vector3(0.0, 0.0, -154.0)  # (in the entrance cleft)
	(z.get_node("Spawn_default") as Node3D).rotation.y = PI  # (facing +Z: up the slope)
	z.set(&"display_name", "Forest Citadel")
	z.set(&"local_weather", &"forest_clouds")
	z.set(&"local_weather_chance", 0.75)
	var fog := FogSettings.new()
	fog.start = 25.0
	fog.end = 120.0
	z.set(&"fog", fog)
	# Mountains all round past the spurs and walls (drawn behind everything, no level
	# triangles), open low to the south where the valley comes in.
	for old in z.find_children("*", "MountainRange", true, false):
		old.free()
	var mr := MountainRange.new()
	mr.name = "Mountains"
	mr.position = Vector3(0.0, 0.0, -10.0)
	mr.seed = 9
	mr.layer_radius = PackedFloat32Array([230.0, 400.0])
	mr.layer_height_min = PackedFloat32Array([100.0, 140.0])
	mr.layer_height_max = PackedFloat32Array([210.0, 300.0])
	mr.sharpness = 2.2
	mr.snow_line = 0.8
	mr.open_arcs = [Vector2(345.0, 15.0)] as Array[Vector2]
	z.add_child(mr)
	mr.owner = z
	var packed := PackedScene.new()
	packed.pack(z)
	ResourceSaver.save(packed, PATH)
	z.free()


# --- Helpers -----------------------------------------------------------------------------------

func _add(b: LevelBrush) -> LevelBrush:
	b.tag = StringName("%s_%08x" % [b.tag if b.tag != &"" else &"brush", randi()])
	data.add_brush(b)
	return b


func _shape(shape: BrushShapes.Shape, size: Vector3, xf: Transform3D, segments := 1) -> LevelBrush:
	var b := LevelBrush.new()
	b.shape = shape
	b.size = size
	b.segments = segments
	b.generate_from_shape()
	b.transform = xf
	return b


## Faces textured by which way they face: tops `top`, the rest `side` (bottoms too).
func _paint(b: LevelBrush, top: int, side: int, top_sound: int, side_sound: int) -> void:
	var faces := b.get_faces()
	var ft := PackedInt32Array()
	var fs := PackedInt32Array()
	for f in faces:
		var n := Vector3.ZERO
		for i in f.size():
			var a: Vector3 = b.vertices[f[i]]
			var c: Vector3 = b.vertices[f[(i + 1) % f.size()]]
			n += Vector3((a.y - c.y) * (a.z + c.z), (a.z - c.z) * (a.x + c.x), (a.x - c.x) * (a.y + c.y))
		var up := (b.transform.basis * n).normalized().y > 0.7
		ft.append(top if up else side)
		fs.append(top_sound if up else side_sound)
	b.face_textures = ft
	b.face_surfaces = fs


## A block between two corners (world, axis-aligned), textured top / sides.
func _block(lo: Vector3, hi: Vector3, top: int, side: int, top_sound := Surface.Sound.GRASS, side_sound := Surface.Sound.STONE, tag := &"block") -> LevelBrush:
	var b := _shape(BrushShapes.Shape.BLOCK, hi - lo, Transform3D(Basis(), Vector3((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)))
	# (BLOCK's origin is its foot's middle)
	b.tag = tag
	_paint(b, top, side, top_sound, side_sound)
	return _add(b)


func _prop(kind: PropSpec.Kind, settings: Dictionary, xf: Transform3D) -> void:
	var spec := PropSpec.new()
	spec.kind = kind
	spec.settings = settings
	var b := LevelBrush.new()
	b.tag = &"prop"
	b.hand_edited = true
	b.transform = xf
	b.prop = spec
	_add(b)
	root._sync_props()
	root._generate_prop(b)


# --- The citadel -------------------------------------------------------------------------------

func _build() -> void:
	_find_fall()
	_ground()
	_church()
	_walkway()
	_carved_stairs()
	_stream()
	_machine()
	_waterfall()
	_boulders()
	_steps()
	_spurs()
	_lips()
	_forest()
	_card_rows()


## All the ground as one heightfield brush: the hillside with its paths, the terrace and its
## carved walls, the river terrace, the mountain. Finer round the terrace and river, coarser
## further out; sample lines on the carved walls' edges so they stand straight. Triangles,
## painted by what they're on.
func _ground() -> void:
	var far := 160.0
	var xs := _samples(-far, far, func(x: float) -> float: return 2.5 if absf(x) < 50.0 else (3.5 if absf(x) < 100.0 else 10.0),
		[-TERRACE_X, -TERRACE_X + 0.6, TERRACE_X - 0.6, TERRACE_X])
	var zs := _samples(-far, far, func(z: float) -> float: return 10.0 if z < -150.0 else (3.0 if z < -15.0 else (2.5 if z < 130.0 else 10.0)),
		[TERRACE_Z - 0.6, TERRACE_Z])
	var hb := BrushShapes.Builder.new()
	var tex := PackedInt32Array()
	var snd := PackedInt32Array()
	var table := [T_GRASS, T_GRAVEL, T_RIVER, T_CLIFF, T_CHURCH, T_DIRT, T_CHURCH]
	var sounds := [Surface.Sound.GRASS, Surface.Sound.STONE, Surface.Sound.STONE, Surface.Sound.STONE, Surface.Sound.STONE, Surface.Sound.DIRT, Surface.Sound.STONE]
	var nx := xs.size()
	var nz := zs.size()
	# Heights on the fine grid, and each fine cell's kind (steep cells: carved wall or cliff rock).
	var hs := PackedFloat32Array()
	hs.resize(nx * nz)
	for i in nx:
		for j in nz:
			hs[i * nz + j] = _land(xs[i], zs[j]).x
	var kinds := PackedInt32Array()
	kinds.resize((nx - 1) * (nz - 1))
	for i in nx - 1:
		for j in nz - 1:
			var p0 := Vector3(xs[i], hs[i * nz + j], zs[j])
			var p1 := Vector3(xs[i + 1], hs[(i + 1) * nz + j], zs[j])
			var p2 := Vector3(xs[i + 1], hs[(i + 1) * nz + j + 1], zs[j + 1])
			var p3 := Vector3(xs[i], hs[i * nz + j + 1], zs[j + 1])
			var mid := Vector2((xs[i] + xs[i + 1]) * 0.5, (zs[j] + zs[j + 1]) * 0.5)
			var kind := int(_land(mid.x, mid.y).y)
			var na := (p1 - p0).cross(p2 - p0).normalized()
			var nb := (p2 - p0).cross(p3 - p0).normalized()
			if minf(absf(na.y), absf(nb.y)) < 0.6:
				kind = 4 if _near_carved(mid) else 3
			kinds[i * (nz - 1) + j] = kind
	# Quadtree over the fine grid: a block stays whole while it's one kind and its two
	# triangles stay within GROUND_TOL of every fine height in it (up to GROUND_MAX across).
	var leaves: Array[Vector4i] = []
	var stack: Array[Vector4i] = []
	var i0 := 0
	while i0 < nx - 1:
		var j0 := 0
		var i1 := mini(i0 + 16, nx - 1)
		while j0 < nz - 1:
			var j1 := mini(j0 + 16, nz - 1)
			stack.append(Vector4i(i0, j0, i1, j1))
			j0 = j1
		i0 = i1
	while not stack.is_empty():
		var r: Vector4i = stack.pop_back()
		if (r.z - r.x <= 1 and r.w - r.y <= 1) or _ground_leaf_ok(r, xs, zs, hs, kinds, nz):
			leaves.append(r)
			continue
		# (split the physically longer side; both when they're near square)
		var wx := xs[r.z] - xs[r.x]
		var wz := zs[r.w] - zs[r.y]
		var mi := (r.x + r.z) / 2 if r.z - r.x > 1 and wx > wz * 0.6 else -1
		var mj := (r.y + r.w) / 2 if r.w - r.y > 1 and wz > wx * 0.6 else -1
		if mi < 0 and mj < 0:
			mi = (r.x + r.z) / 2 if r.z - r.x > 1 else -1
			mj = (r.y + r.w) / 2 if r.w - r.y > 1 else -1
		for a in ([Vector2i(r.x, mi), Vector2i(mi, r.z)] if mi >= 0 else [Vector2i(r.x, r.z)]):
			for c in ([Vector2i(r.y, mj), Vector2i(mj, r.w)] if mj >= 0 else [Vector2i(r.y, r.w)]):
				stack.append(Vector4i(a.x, c.x, a.y, c.y))
	# Every leaf's corners; each leaf takes in the corners on its edges (no T-junction cracks).
	var corner := {}
	for r in leaves:
		for q in [Vector2i(r.x, r.y), Vector2i(r.z, r.y), Vector2i(r.z, r.w), Vector2i(r.x, r.w)]:
			corner[q] = true
	for r in leaves:
		var ring: Array[Vector2i] = []
		for i in range(r.x, r.z):
			if corner.has(Vector2i(i, r.y)): ring.append(Vector2i(i, r.y))
		for j in range(r.y, r.w):
			if corner.has(Vector2i(r.z, j)): ring.append(Vector2i(r.z, j))
		for i in range(r.z, r.x, -1):
			if corner.has(Vector2i(i, r.w)): ring.append(Vector2i(i, r.w))
		for j in range(r.w, r.y, -1):
			if corner.has(Vector2i(r.x, j)): ring.append(Vector2i(r.x, j))
		var pts: Array[Vector3] = []
		for q in ring:
			pts.append(Vector3(xs[q.x], hs[q.x * nz + q.y], zs[q.y]))
		var kind := kinds[r.x * (nz - 1) + r.y]
		var tris := []
		if pts.size() == 4:
			tris = [[pts[0], pts[1], pts[2]], [pts[0], pts[2], pts[3]]]
		else:
			var cx := (xs[r.x] + xs[r.z]) * 0.5
			var cz := (zs[r.y] + zs[r.w]) * 0.5
			var c := Vector3(cx, _ground_interp(r, cx, cz, xs, zs, hs, nz), cz)
			for k in pts.size():
				tris.append([c, pts[k], pts[(k + 1) % pts.size()]])
		for t in tris:
			hb.face(t, Vector3.UP)
			tex.append(table[kind])
			snd.append(sounds[kind])
	print("ground: %d fine cells -> %d blocks, %d triangles" % [(nx - 1) * (nz - 1), leaves.size(), tex.size()])
	if OS.get_environment("GROUND_MAP") != "":
		# GROUND_MAP=/abs.png: the blocks from above (2 px per metre, north up), shaded by kind.
		var img := Image.create(640, 640, false, Image.FORMAT_RGB8)
		var cols := [Color(0.3, 0.55, 0.25), Color(0.7, 0.65, 0.5), Color(0.2, 0.4, 0.7), Color(0.45, 0.45, 0.45), Color(0.8, 0.6, 0.4), Color(0.55, 0.35, 0.2), Color(0.85, 0.75, 0.55)]
		for r in leaves:
			var x0 := int((xs[r.x] + 160.0) * 2.0)
			var x1 := int((xs[r.z] + 160.0) * 2.0)
			var y0 := 639 - int((zs[r.w] + 160.0) * 2.0)
			var y1 := 639 - int((zs[r.y] + 160.0) * 2.0)
			img.fill_rect(Rect2i(x0, y0, maxi(x1 - x0, 1), maxi(y1 - y0, 1)), cols[kinds[r.x * (nz - 1) + r.y]])
			for x in range(x0, x1 + 1):
				img.set_pixel(mini(x, 639), clampi(y0, 0, 639), Color.BLACK)
			for y in range(y0, y1 + 1):
				img.set_pixel(clampi(x0, 0, 639), mini(y, 639), Color.BLACK)
		img.save_png(OS.get_environment("GROUND_MAP"))
	var b := LevelBrush.new()
	b.vertices = hb.verts
	b.face_indices = hb.indices
	b.face_counts = hb.counts
	b.hand_edited = true
	b.face_textures = tex
	b.face_surfaces = snd
	b.tag = &"land"
	_add(b)


const GROUND_TOL := 0.3
const GROUND_MAX := 40.0


## A quadtree block (fine-grid corner indices i0, j0, i1, j1) can stay whole: one kind, not
## too big, its two triangles within GROUND_TOL of every fine height inside it.
func _ground_leaf_ok(r: Vector4i, xs: Array[float], zs: Array[float], hs: PackedFloat32Array, kinds: PackedInt32Array, nz: int) -> bool:
	if xs[r.z] - xs[r.x] > GROUND_MAX or zs[r.w] - zs[r.y] > GROUND_MAX:
		return false
	var k0 := kinds[r.x * (nz - 1) + r.y]
	for i in range(r.x, r.z):
		for j in range(r.y, r.w):
			if kinds[i * (nz - 1) + j] != k0:
				return false
	for i in range(r.x, r.z + 1):
		for j in range(r.y, r.w + 1):
			if absf(_ground_interp(r, xs[i], zs[j], xs, zs, hs, nz) - hs[i * nz + j]) > GROUND_TOL:
				return false
	return true


## The height a block's two triangles (split corner 0 - corner 2) give at x, z.
func _ground_interp(r: Vector4i, x: float, z: float, xs: Array[float], zs: Array[float], hs: PackedFloat32Array, nz: int) -> float:
	var u := (x - xs[r.x]) / (xs[r.z] - xs[r.x])
	var v := (z - zs[r.y]) / (zs[r.w] - zs[r.y])
	var h0 := hs[r.x * nz + r.y]
	var h1 := hs[r.z * nz + r.y]
	var h2 := hs[r.z * nz + r.w]
	var h3 := hs[r.x * nz + r.w]
	if u >= v:
		return h0 + u * (h1 - h0) + v * (h2 - h1)
	return h0 + v * (h3 - h0) + u * (h2 - h3)


## Sample positions from a to b, `step(x)` apart, with `extra` positions put in.
func _samples(a: float, b: float, step: Callable, extra: Array) -> Array[float]:
	var out: Array[float] = []
	var x := a
	while x < b + 0.01:
		out.append(x)
		x += float(step.call(x))
	for e: float in extra:
		if not out.has(e):
			out.append(e)
	out.sort()
	return out


## On one of the terrace's carved walls (its back or sides).
func _near_carved(p: Vector2) -> bool:
	var side := absf(absf(p.x) - TERRACE_X) < 1.5 and p.y > FRONT_Z and p.y < TERRACE_Z + 1.0
	var back := absf(p.y - TERRACE_Z) < 1.5 and absf(p.x) < TERRACE_X + 1.0
	return side or back


## The hillside's height at z (natural, before the terrace is cut): rising from the arrival to
## P at the terrace's front, on to UP at its back.
func _hill(z: float) -> float:
	if z <= ARRIVE_Z:
		return 0.0
	if z <= FRONT_Z:
		var t := (z - ARRIVE_Z) / (FRONT_Z - ARRIVE_Z)
		return P * (0.6 * t + 0.4 * t * t * (3.0 - 2.0 * t))
	if z <= TERRACE_Z:
		return P + (UP - P) * (z - FRONT_Z) / (TERRACE_Z - FRONT_Z)
	return UP


## (height, kind: 0 grass, 1 gravel, 2 river bed, 5 path, 6 terrace floor) at x, z: the
## hillside / terrace / river terrace, the mountain over it, the paths cut into it.
func _land(x: float, z: float) -> Vector2:
	var v: Vector2
	if z >= TERRACE_Z:
		v = _river_land_at(x, z)
	elif absf(x) < TERRACE_X and z > FRONT_Z:
		v = Vector2(P, 6.0)
	else:
		v = Vector2(_hill(z), 0.0)
	v.x += _cliff(x, z) + _spur_rise(x, z)
	var pi := _path_at(x, z)
	if pi.x < PATH_HALF + 3.0:
		v.x = lerpf(v.x, pi.y, 1.0 - smoothstep(PATH_HALF, PATH_HALF + 3.0, pi.x))
		if pi.x < PATH_HALF + 0.3:
			v.y = 5.0
	return v


## The nearest path: (distance, its height there).
func _path_at(x: float, z: float) -> Vector2:
	var best := Vector2(INF, 0.0)
	var q := Vector2(x, z)
	for i in TRAIL.size() - 1:
		var a := Vector2(TRAIL[i][0], TRAIL[i][1])
		var b := Vector2(TRAIL[i + 1][0], TRAIL[i + 1][1])
		var ab := b - a
		var t := clampf((q - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var c := a + ab * t
		var d := q.distance_to(c)
		if d < best.x:
			best = Vector2(d, _hill(c.y) if c.y <= FRONT_Z else P)
	return best


# --- The river's shape (all functions of world x, z) ---

## The bank height along the river (the tilted land) and the main water's surface.
func _bank(x: float) -> float:
	return UP - SLOPE * x


func _water_y(x: float) -> float:
	return _bank(x) - BANK_UP


## The side branch's basin surface when full (nearly level: held by the gate and the bar).
func _pool_y(x: float) -> float:
	return _water_y(GATE_X) - 0.2 - POOL_SLOPE * (x - GATE_X)


func _bend(x: float) -> float:
	return 5.0 * sin(x / 60.0)


func _isle_w(x: float) -> float:
	var t := (x - ISLE_X.x) / (ISLE_X.y - ISLE_X.x)
	return ISLE_MAX * pow(sin(PI * t), 0.6) if t > 0.0 and t < 1.0 else 0.0


## [south bank, side branch / island edge, island / main branch edge, north bank] at x.
## Upstream of the island the river turns north into the back cliff (wider across x as it
## turns, so it keeps its width).
func _edges(x: float) -> Array[float]:
	if x < ISLE_X.x:
		var u := (ISLE_X.x - x) / 24.0
		var slope := 2.0 * TURN * u / 24.0
		var mid := RIVER_Z + _bend(x) + RIVER_W * 0.5 + TURN * u * u
		var half := RIVER_W * 0.5 * sqrt(1.0 + slope * slope)
		return [mid - half, mid - half, mid - half, mid + half]
	var wi := _isle_w(x)
	var zs := RIVER_Z + _bend(x) - 0.6 * wi
	var a := zs + SIDE_W
	return [zs, a, a + wi, zs + RIVER_W + wi]


## Where the river meets the back cliff upstream: the waterfall's foot (the plunge pool's
## middle, a few metres out from the cliff), and the last water row upstream.
func _find_fall() -> void:
	var x := ISLE_X.x
	while x > -150.0:
		var e := _edges(x)
		if (e[0] + e[3]) * 0.5 > _cliff_foot(x) - 7.0:
			break
		x -= 0.5
	var e := _edges(x)
	_fall = Vector2(x, (e[0] + e[3]) * 0.5)
	_fall_x0 = x - POOL_R - 4.0
	print("waterfall at ", _fall)


## The side branch's bed at x: the river's above the gate, the basin, the bar, back down.
func _side_bed(x: float) -> float:
	var w := _water_y(x)
	if x < GATE_X:
		return w - DEEP
	if x < BAR_X:
		return _pool_y(x) - POOL_DEEP
	if x < CREST_X:
		return lerpf(_pool_y(x) - POOL_DEEP, w + CREST_UP, smoothstep(BAR_X, CREST_X, x))
	if x < CREST_X + 6.0:
		return lerpf(w + CREST_UP, w - DEEP, (x - CREST_X) / 6.0)
	return w - DEEP


## A kinked offset along t: CLIFF_KINKS (from `shift` on) through every 30 m.
func _kink(t: float, shift: int) -> float:
	var f := (t + 180.0) / 30.0
	var k := clampi(int(f), 0, CLIFF_KINKS.size() - 2)
	var n := CLIFF_KINKS.size()
	return lerpf(CLIFF_KINKS[(k + shift) % n], CLIFF_KINKS[(k + 1 + shift) % n], f - k)


## Where the back wall's foot is at x (z): CLIFF_GAP past the north bank, plus the kinked offset.
func _cliff_foot(x: float) -> float:
	return RIVER_Z + RIVER_W + _bend(x) + CLIFF_GAP + _kink(x, 0)


func _west_foot(z: float) -> float:
	return WEST_X + _kink(z, 3)


func _east_foot(z: float) -> float:
	return EAST_X + _kink(z, 7)


## How far into the mountain x, z is (past the nearest wall's foot; < 0 inside the valley): the
## three walls blended (rounded corners where they meet).
func _cliff_d(x: float, z: float) -> float:
	var ds := [z - _cliff_foot(x), _west_foot(z) - x, x - _east_foot(z)]
	var m: float = ds.max()
	var k := 6.0
	var sum := 0.0
	for d: float in ds:
		sum += exp((d - m) / k)
	return m + k * log(sum)


## The mountain's height over the land at x, z: the face (steep, its height and run varying
## along it, a little rock relief), then the top sloping on up; fading towards the pit.
func _cliff(x: float, z: float) -> float:
	var d := _cliff_d(x, z)
	if d <= 0.0:
		return 0.0
	var u := x + z  # (along the walls, whichever)
	var hgt := CLIFF_H + 7.0 * sin(u * 0.045 + 1.3) + 3.0 * sin(u * 0.13)
	var run := CLIFF_RUN + 1.5 * sin(u * 0.07 + 0.4)
	var t := clampf(d / run, 0.0, 1.0)
	var face := hgt * (t * t * (3.0 - 2.0 * t) * 0.15 + t * 0.85)
	var relief := 1.2 * sin(x * 0.61 + z * 0.37) * sin(u * 0.23) * (1.0 - absf(2.0 * t - 1.0))
	return (face + relief + maxf(d - run, 0.0) * 0.35) * smoothstep(SIDE_FADE.x, SIDE_FADE.y, z)


## A channel's cross-section between lo and hi: its bed, rising over BANK_W to the tops either side.
func _channel(z: float, lo: float, hi: float, bed: float, top_lo: float, top_hi: float) -> Vector2:
	var e := minf(z - lo, hi - z)
	var top := top_lo if z - lo < hi - z else top_hi
	var h := bed + (top - bed) * (1.0 - smoothstep(0.0, BANK_W, e))
	return Vector2(h, 2.0 if e > BANK_W * 0.6 else 1.0)


func _river_land_at(x: float, z: float) -> Vector2:
	var v := _river_bed_at(x, z)
	# The plunge pool round the waterfall's foot.
	var d := Vector2(x, z).distance_to(_fall)
	if d < POOL_R + BANK_W:
		var pool := lerpf(_water_y(x) - DEEP - 0.6, v.x, smoothstep(POOL_R - 2.0, POOL_R + BANK_W, d))
		if pool < v.x:
			v = Vector2(pool, 2.0 if d < POOL_R - 1.0 else 1.0)
	return v


func _river_bed_at(x: float, z: float) -> Vector2:
	var ground := UP - SLOPE * x * smoothstep(TERRACE_Z + 1.0, TERRACE_Z + 6.0, z)
	var e := _edges(x)
	if z <= e[0] or z >= e[3]:
		return Vector2(ground, 0.0)
	var w := _water_y(x)
	var bank := _bank(x)
	if x <= ISLE_X.x or x >= ISLE_X.y:
		return _channel(z, e[0], e[3], w - DEEP, bank, bank)
	# (the island's tips sink into the river)
	var isle := lerpf(w - DEEP, w + ISLE_UP, smoothstep(1.0, 5.0, _isle_w(x)))
	if z < e[1]:
		return _channel(z, e[0], e[1], _side_bed(x), bank, isle)
	if z <= e[2]:
		return Vector2(isle, 1.0)
	return _channel(z, e[2], e[3], w - DEEP, isle, bank)


## The church: a Greek cross of four arms round a central tower, carved from one rock,
## standing on the terrace; the north arm's end has the machine doorway (a recess at the
## terrace floor, its blocks props).
func _church() -> void:
	var f := P
	var w := ARM_W
	var c := CHURCH_Z
	var top := P + ARM_H
	_block(Vector3(-ARM, f, c - w), Vector3(-w, top, c + w), T_CHURCH, T_CHURCH, Surface.Sound.STONE)  # west
	_block(Vector3(w, f, c - w), Vector3(ARM, top, c + w), T_CHURCH, T_CHURCH, Surface.Sound.STONE)  # east
	_block(Vector3(-w, f, c - ARM), Vector3(w, top, c - w), T_CHURCH, T_CHURCH, Surface.Sound.STONE)  # south
	_block(Vector3(-w, f, c - w), Vector3(w, P + TOWER_H, c + w), T_CHURCH, T_CHURCH, Surface.Sound.STONE)  # tower
	# North arm: solid to 4 m short of its end, then its end round a doorway (x -2.5..2.5, up
	# 7 m) 4 m deep.
	var d0 := c + ARM - 4.0
	_block(Vector3(-w, f, c + w), Vector3(w, top, d0), T_CHURCH, T_CHURCH, Surface.Sound.STONE)
	_block(Vector3(-w, f, d0), Vector3(-2.5, top, c + ARM), T_CHURCH, T_CHURCH, Surface.Sound.STONE)
	_block(Vector3(2.5, f, d0), Vector3(w, top, c + ARM), T_CHURCH, T_CHURCH, Surface.Sound.STONE)
	_block(Vector3(-2.5, f + 7.0, d0), Vector3(2.5, top, c + ARM), T_CHURCH, T_CHURCH, Surface.Sound.STONE)
	# A stepped plinth round the cross's foot (Bete Giyorgis stands on one).
	for k in 2:
		var g := 1.2 + k * 1.2
		var h := 1.2 - k * 0.5
		_block(Vector3(-ARM - g, f, c - w - g), Vector3(ARM + g, f + h, c + w + g), T_STEPS, T_STEPS, Surface.Sound.STONE)
		_block(Vector3(-w - g, f, c - ARM - g), Vector3(w + g, f + h, c - w + g), T_STEPS, T_STEPS, Surface.Sound.STONE)
		_block(Vector3(-w - g, f, c + w - g), Vector3(-2.5, f + h, c + ARM + g), T_STEPS, T_STEPS, Surface.Sound.STONE)
		_block(Vector3(2.5, f, c + w - g), Vector3(w + g, f + h, c + ARM + g), T_STEPS, T_STEPS, Surface.Sound.STONE)


## The stone walkway on the terrace: from the top of the path to a ring round the church, on
## to the doorway behind it and the carved stairs on the east wall. Flagstones laid on the
## floor (drawn only: the floor is under them).
func _walkway() -> void:
	var w := 3.0
	var x1 := RING.x
	var segs := [
		[Vector2(0, FRONT_Z), Vector2(0, RING_Z.x)],
		[Vector2(-x1, RING_Z.x), Vector2(x1, RING_Z.x)],
		[Vector2(-x1, RING_Z.y), Vector2(x1, RING_Z.y)],
		[Vector2(-x1, RING_Z.x), Vector2(-x1, RING_Z.y)],
		[Vector2(x1, RING_Z.x), Vector2(x1, RING_Z.y)],
		[Vector2(0, RING_Z.y), Vector2(0, CHURCH_Z + ARM + 0.5)],
		[Vector2(x1, 4.0), Vector2(TERRACE_X - 2.5, 4.0)],
	]
	for sg in segs:
		var a: Vector2 = sg[0]
		var b: Vector2 = sg[1]
		var along := b - a
		var vertical := absf(along.y) > absf(along.x)
		var size := Vector3(w, 0.0, along.length() + w) if vertical else Vector3(along.length() + w, 0.0, w)
		var m := (a + b) * 0.5
		var pl := _shape(BrushShapes.Shape.PLANE, size, Transform3D(Basis(), Vector3(m.x, P + 0.04, m.y)))
		pl.bake_mode = LevelBrush.BakeMode.VISUAL_ONLY
		pl.uv_world = true
		pl.tag = &"walkway"
		_paint(pl, T_STEPS, T_STEPS, Surface.Sound.STONE, Surface.Sound.STONE)
		_add(pl)


## Stairs carved up the terrace's east wall to the river terrace: 4 m wide against the wall,
## from the walkway up to the top of the back wall.
func _carved_stairs() -> void:
	var run := TERRACE_Z - 6.0
	var s := _shape(BrushShapes.Shape.STAIRS, Vector3(4.0, UP - P, run),
		Transform3D(Basis(Vector3.UP, PI), Vector3(TERRACE_X - 2.5, P, TERRACE_Z - run * 0.5)), 40)
	# (STAIRS' low end is at its +Z: turned round, it climbs north)
	s.tag = &"carved_stairs"
	_paint(s, T_CHURCH, T_CHURCH, Surface.Sound.STONE, Surface.Sound.STONE)
	_add(s)


## Water: the river (one surface down the slope, round the island; the side branch only above
## the gate and below the bar's crest), and the side branch's basin, filling as the gate opens,
## with its spill over the bar.
func _stream() -> void:
	var far := 160.0
	var rows := PackedVector3Array()
	var a := atan(SLOPE)
	var x := far
	while x > _fall_x0:
		# (at the gate and the crest: a row either side, the river's width switching between)
		var at := [x + 0.005, x - 0.005] if (absf(x - CREST_X) < 0.01 or absf(x - GATE_X - 0.3) < 0.01) else [x]
		for xx: float in at:
			var e := _edges(xx)
			var inside := xx > GATE_X + 0.3 and xx < CREST_X
			var z0: float = (e[2] - 0.3) if inside else (e[0] - 0.5)
			var z1: float = e[3] + 0.5
			# (the plunge pool's round edge)
			var dx := absf(xx - _fall.x)
			if dx < POOL_R + 1.0:
				var hz := sqrt(maxf((POOL_R + 1.0) * (POOL_R + 1.0) - dx * dx, 0.0))
				z0 = minf(z0, _fall.y - hz)
				z1 = maxf(z1, _fall.y + hz)
			rows.append(_row(xx, z0, z1, a))
		x -= _step_to(x, 2.5, [CREST_X, GATE_X + 0.3])
	_prop(PropSpec.Kind.MACHINE_WATER, {strip = rows, low = 0.0, high = 0.0, flow = 1.2},
		Transform3D(_slope_basis(a), Vector3(0.0, _water_y(0.0), 0.0)))
	# The basin: from the gate to just past the crest.
	var ap := atan(POOL_SLOPE)
	var pool := PackedVector3Array()
	x = CREST_X + 0.6
	while x > GATE_X + 0.3 - 0.01:
		var e := _edges(x)
		pool.append(_row(x, e[0] - 0.5, e[1] + 0.3, ap))
		x -= _step_to(x, 2.5, [GATE_X + 0.3])
	_prop(PropSpec.Kind.MACHINE_WATER, {input = &"gate", output = &"side", strip = pool, low = 0.02, high = POOL_DEEP, flow = 0.5, fill_speed = 0.3},
		Transform3D(_slope_basis(ap), Vector3(0.0, _pool_y(0.0) - POOL_DEEP, 0.0)))
	# The spill over the crest: a sheet down from the full basin to the river.
	var ec := _edges(CREST_X + 0.6)
	var hgt := _pool_y(CREST_X) - _water_y(CREST_X)
	_prop(PropSpec.Kind.MACHINE_WATER, {input = &"side", low = 0.0, high = 0.0, flow = 0.0, size = Vector2(ec[1] - ec[0], hgt)},
		Transform3D(Basis(Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)),
			Vector3(CREST_X + 0.6, _pool_y(CREST_X) - hgt * 0.5, (ec[0] + ec[1]) * 0.5)))


## The next step back along x: `step`, landing exactly on any of `stops` on the way.
func _step_to(x: float, step: float, stops: Array) -> float:
	for st: float in stops:
		if x - st > 0.011 and x - step < st:
			return x - st
	return step


## A water surface tilted down +X by angle a, its flow (local -Z) downhill: local X = world Z.
func _slope_basis(a: float) -> Basis:
	return Basis(Vector3(0, 0, 1), Vector3(sin(a), cos(a), 0), Vector3(-cos(a), sin(a), 0))


## A strip row at world x, across world z0..z1 (local: z = -x / cos a).
func _row(x: float, z0: float, z1: float, a: float) -> Vector3:
	return Vector3(-x / cos(a), z0, z1)


## The machine: capstan -> fork gate -> side branch basin -> noria -> aqueduct -> the doorway.
func _machine() -> void:
	# Fork gate across the side branch's head; its capstan on the south bank beside it.
	var eg := _edges(GATE_X)
	var dz := (_edges(GATE_X + 1.0)[0] - _edges(GATE_X - 1.0)[0]) * 0.5
	_prop(PropSpec.Kind.SCREW_GATE, {input = &"fork", output = &"gate", width = SIDE_W + 0.8, height = 2.6},
		Transform3D(Basis(Vector3.UP, atan2(1.0, dz)), Vector3(GATE_X, _water_y(GATE_X) - DEEP, eg[0] + SIDE_W * 0.5)))
	_prop(PropSpec.Kind.CAPSTAN, {output = &"fork", turns = 3, drum_radius = 0.9, spoke_length = 1.6},
		Transform3D(Basis(), Vector3(GATE_X + 2.0, _bank(GATE_X + 2.0), eg[0] - 4.5)))
	# The noria in the basin, its axle across the branch (the wheel in line with the flow); its
	# crest on the upstream side, the trough running south over the bank.
	var r := 9.0
	var ew := _edges(WHEEL_X)
	var wz := ew[0] + SIDE_W * 0.5
	var wdz := (_edges(WHEEL_X + 1.0)[0] - _edges(WHEEL_X - 1.0)[0]) * 0.5
	var trough := SIDE_W * 0.5 + 3.0
	var y0 := _pool_y(WHEEL_X) - POOL_DEEP + 0.3
	_prop(PropSpec.Kind.NORIA, {input = &"side", output = &"wheel", radius = r, width = 3.4, dip = 0.0, buckets = 24,
		rpm = 1.5, trough_length = trough, trough_flip = true},
		Transform3D(Basis(Vector3.UP, atan2(-1.0, -wdz)), Vector3(WHEEL_X, y0, wz)))
	# The aqueduct: from the trough's end south over the carved wall into the north arm's end
	# high up (a channel into the wall); a pillar on the river terrace, one in the courtyard.
	var ax := WHEEL_X - 0.9
	var crest := y0 + r + r - 0.9 - 0.2
	var z0 := wz - trough - 0.3
	var face := CHURCH_Z + ARM - 1.0
	_block(Vector3(ax - 0.8, crest - 0.6, face), Vector3(ax + 0.8, crest, z0), T_STEPS, T_STEPS, Surface.Sound.STONE, Surface.Sound.STONE, &"aqueduct")
	for pz in [(TERRACE_Z + z0) * 0.5 + 0.4, TERRACE_Z - 5.0]:
		_block(Vector3(ax - 0.7, _land(ax, pz).x - 0.5, pz - 0.7), Vector3(ax + 0.7, crest - 0.6, pz + 0.7), T_STEPS, T_STEPS, Surface.Sound.STONE, Surface.Sound.STONE, &"pillar")
	_prop(PropSpec.Kind.MACHINE_WATER, {input = &"wheel", size = Vector2(1.0, z0 - face), low = 0.0, high = 0.15, flow = 1.6, fill_speed = 0.1},
		Transform3D(Basis(), Vector3(ax, crest + 0.02, (z0 + face) * 0.5)))
	# The doorway's two blocks, sliding apart into the jambs once the wheel runs.
	for k in 2:
		var sx := -1.0 if k == 0 else 1.0
		_prop(PropSpec.Kind.MACHINE_DOOR, {input = &"wheel", threshold = 0.6, size = Vector3(2.5, 7.0, 3.0),
			move = Vector3(sx * 2.6, 0.0, 0.0), delay = 0.0 if k == 0 else 1.5, speed = 0.35},
			Transform3D(Basis(), Vector3(sx * 1.25, P, CHURCH_Z + ARM - 2.0)))


## The waterfall down the back cliff into the plunge pool: tall strands from the cliff's top
## (its face leaning back), facing downstream.
func _waterfall() -> void:
	var e := _edges(_fall.x)
	var e2 := _edges(_fall.x + 1.0)
	var down := Vector2(1.0, (e2[0] + e2[3]) * 0.5 - (e[0] + e[3]) * 0.5).normalized()
	# (from the pool's middle back towards the cliff until its foot, then 1.5 m out from it)
	var q := _fall
	for i in 60:
		if _cliff_d(q.x, q.y) >= 0.0:
			break
		q -= down * 0.5
	q += down * 1.5
	var top := UP + _cliff(q.x - down.x * (CLIFF_RUN + 1.5), q.y - down.y * (CLIFF_RUN + 1.5)) - 1.5
	var at := Vector3(q.x, _water_y(q.x), q.y)
	_prop(PropSpec.Kind.WATERFALL, {height = top - at.y, width = 10.0, strands = 4, lean = CLIFF_RUN + 1.0, speed = 1.8,
		foam_radius = 6.0, seed = 5}, Transform3D(Basis(Vector3.UP, atan2(down.x, down.y)), at))


## Big grey low-poly standing rocks: a ring round the plunge pool (tall against the cliff,
## lower round the sides, open downstream where the river runs out), and a pile at the east
## wall's foot where the river goes back under the mountain (tall ones against the face, mid
## ones in front, small ones at the water with a gap where it runs through).
func _boulders() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	# Round the pool: angles measured from downstream (the way out stays open).
	var e := _edges(_fall.x)
	var e2 := _edges(_fall.x + 1.0)
	var out := Vector2(1.0, (e2[0] + e2[3]) * 0.5 - (e[0] + e[3]) * 0.5).normalized()
	for i in 14:
		var ang := lerpf(0.9, TAU - 0.9, (i + 0.5) / 14.0) + rng.randf_range(-0.1, 0.1)
		var dir := out.rotated(ang)
		var back := clampf(-dir.dot(out), 0.0, 1.0)  # (1 = against the cliff)
		var rad := POOL_R + rng.randf_range(0.5, 3.0)
		var q := _fall + dir * rad
		# (none up on the cliff: pulled in to its foot)
		var guard := 0
		while _cliff_d(q.x, q.y) > -1.0 and guard < 12:
			q -= dir * 0.5
			guard += 1
		if _cliff_d(q.x, q.y) > -1.0 or q.distance_to(_fall) < POOL_R - 1.0:
			continue
		var h := lerpf(3.5, 12.0, back) * rng.randf_range(0.8, 1.2)
		var w := h * rng.randf_range(0.55, 0.8)
		_boulder(Vector3(q.x, _land(q.x, q.y).x - h * 0.1, q.y), Vector3(w, h, w * rng.randf_range(0.7, 1.0)), rng)
	# The east wall's foot.
	var ee := _edges(EAST_X)
	var mid := (ee[0] + ee[3]) * 0.5
	for row in 3:
		var count: int = [6, 6, 5][row]
		var hr: Vector2 = [Vector2(11.0, 17.0), Vector2(6.0, 9.5), Vector2(3.0, 5.0)][row]
		for i in count:
			var z := lerpf(ee[0] - 7.0, ee[3] + 7.0, (i + 0.5) / count) + rng.randf_range(-2.0, 2.0)
			if row == 2 and absf(z - mid) < 4.5:
				continue  # (the water's way out)
			var h := rng.randf_range(hr.x, hr.y)
			var w := h * rng.randf_range(0.55, 0.8)
			var x: float = _east_foot(z) - (row * 5.0 + w * 0.4 + rng.randf_range(-1.0, 1.0))
			_boulder(Vector3(x, _land(x, z).x - h * 0.08, z), Vector3(w, h, w * rng.randf_range(0.7, 1.0)), rng)


## The stone-step climbs on the switchbacks (refs f1-f4): rough slabs set into the path a
## pace apart straight up the slope, a few loose stones along their edges. Drawn only (the
## path's slope under them is what's walked on).
func _steps() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	for i in TRAIL.size() - 1:
		if not TRAIL[i][2]:
			continue
		var a := Vector2(TRAIL[i][0], TRAIL[i][1])
		var b := Vector2(TRAIL[i + 1][0], TRAIL[i + 1][1])
		var n := int(ceil(a.distance_to(b) / 1.15))
		var dir := (b - a).normalized()
		var side := Vector2(-dir.y, dir.x)
		for k in n:
			var c := a.lerp(b, (k + 0.5) / n) + side * rng.randf_range(-0.25, 0.25)
			var y := _hill(c.y - dir.y * 0.45)  # (its top level with the slope at its front edge)
			var size := Vector3(PATH_HALF * 2.0 * rng.randf_range(0.8, 1.05), 0.45, rng.randf_range(0.8, 1.0))
			_slab(Vector3(c.x, y - 0.3, c.y), size, atan2(dir.x, dir.y) + rng.randf_range(-0.12, 0.12), rng)
			for sd in [-1.0, 1.0]:
				if rng.randf() < 0.7:
					var r: Vector2 = c + side * sd * (PATH_HALF + rng.randf_range(0.3, 0.8))
					var hh := rng.randf_range(0.4, 0.9)
					var rr := Vector3(hh * rng.randf_range(1.0, 1.6), hh, hh * rng.randf_range(0.9, 1.4))
					var bb := _boulder(Vector3(r.x, _land(r.x, r.y).x - hh * 0.3, r.y), rr, rng)
					bb.bake_mode = LevelBrush.BakeMode.VISUAL_ONLY


## A rough stone slab: a flat box with its edges and corners cut off unevenly.
func _slab(at: Vector3, size: Vector3, yaw: float, rng: RandomNumberGenerator) -> void:
	var hx := size.x * 0.5
	var hz := size.z * 0.5
	var h := size.y
	var c := [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz),
		Vector3(-hx, h, -hz), Vector3(hx, h, -hz), Vector3(hx, h, hz), Vector3(-hx, h, hz)]
	var faces: Array[PackedVector3Array] = []
	for q in [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]:
		faces.append(PackedVector3Array([c[q[0]], c[q[1]], c[q[2]], c[q[3]]]))
	var mid := Vector3(0, h * 0.5, 0)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var nv := Vector3(sx * rng.randf_range(0.6, 1.4), 0.0, sz * rng.randf_range(0.6, 1.4)).normalized()
			faces = _clip_hull(faces, nv, nv.dot(mid) + (absf(nv.x) * hx + absf(nv.z) * hz) * rng.randf_range(0.8, 0.95))
			var nt := Vector3(sx * hx, h * 1.5, sz * hz).normalized()
			faces = _clip_hull(faces, nt, nt.dot(mid) + (absf(nt.x) * hx + absf(nt.y) * h * 0.5 + absf(nt.z) * hz) * rng.randf_range(0.82, 0.92))
	var hb := BrushShapes.Builder.new()
	var centre := Vector3(0, h * 0.5, 0)
	for f in faces:
		var fc := Vector3.ZERO
		for v in f:
			fc += v
		hb.face(Array(f), fc / f.size() - centre)
	var bb := LevelBrush.new()
	bb.vertices = hb.verts
	bb.face_indices = hb.indices
	bb.face_counts = hb.counts
	bb.hand_edited = true
	bb.transform = Transform3D(Basis(Vector3.UP, yaw), at)
	var ft := PackedInt32Array()
	var fs := PackedInt32Array()
	ft.resize(hb.counts.size())
	ft.fill(T_BOULDER)
	fs.resize(hb.counts.size())
	fs.fill(Surface.Sound.STONE)
	bb.face_textures = ft
	bb.face_surfaces = fs
	bb.bake_mode = LevelBrush.BakeMode.VISUAL_ONLY
	bb.tag = &"step"
	_add(bb)


## One rock, made the way low-poly rocks are modelled: a tall box with its corners and edges
## sliced off by flat cuts (deep at the top, light at the foot), leaning a little.
func _boulder(at: Vector3, size: Vector3, rng: RandomNumberGenerator) -> LevelBrush:
	var hx := size.x * 0.5
	var hz := size.z * 0.5
	var h := size.y
	# The box as faces (its foot at y 0).
	var c := [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz),
		Vector3(-hx, h, -hz), Vector3(hx, h, -hz), Vector3(hx, h, hz), Vector3(-hx, h, hz)]
	var faces: Array[PackedVector3Array] = []
	for q in [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]:
		faces.append(PackedVector3Array([c[q[0]], c[q[1]], c[q[2]], c[q[3]]]))
	var mid := Vector3(0, h * 0.5, 0)
	var cuts: Array = []  # [normal, keep fraction of the support]
	# (small stones - under 2 m - get the edges and top corners only: ~1/3 the triangles,
	# no difference at their size; medium ones skip the belly belt)
	var detail := 0 if h < 2.0 else (1 if h < 6.0 else 2)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			# vertical edges (deep: an octagon round), top corners (deep: the taper), foot corners
			cuts.append([Vector3(sx, 0, sz), rng.randf_range(0.7, 0.82)])
			cuts.append([Vector3(sx * hx, h * 0.5, sz * hz), rng.randf_range(0.5, 0.64)])
			if detail > 0:
				cuts.append([Vector3(sx * hx, -h * 0.5, sz * hz), rng.randf_range(0.74, 0.86)])
	for k in (4 if detail > 0 else 0):
		# the shoulders (top edges) and a belt of angled cuts low down (the belly)
		var dir := Vector3.FORWARD.rotated(Vector3.UP, k * PI * 0.5)
		cuts.append([dir + Vector3.UP * 1.3, rng.randf_range(0.62, 0.78)])
		if detail > 1:
			var diag := Vector3.FORWARD.rotated(Vector3.UP, k * PI * 0.5 + PI * 0.25)
			cuts.append([diag * Vector3(hx, 0, hz).length() + Vector3.UP * h * 0.12, rng.randf_range(0.8, 0.9)])
			cuts.append([dir * 1.0 + Vector3.DOWN * 0.8, rng.randf_range(0.78, 0.9)])
	for cut in cuts:
		var n: Vector3 = (cut[0] as Vector3).rotated(Vector3.UP, rng.randf_range(-0.25, 0.25)).normalized()
		n = (n + Vector3(rng.randf_range(-0.12, 0.12), rng.randf_range(-0.12, 0.12), rng.randf_range(-0.12, 0.12))).normalized()
		var support := absf(n.x) * hx + absf(n.y) * h * 0.5 + absf(n.z) * hz
		faces = _clip_hull(faces, n, n.dot(mid) + support * float(cut[1]))
	var hb := BrushShapes.Builder.new()
	var centre := Vector3.ZERO
	var nv := 0
	for f in faces:
		for v in f:
			centre += v
			nv += 1
	centre /= maxf(nv, 1)
	for f in faces:
		var fc := Vector3.ZERO
		for v in f:
			fc += v
		fc /= f.size()
		hb.face(Array(f), fc - centre)
	var bb := LevelBrush.new()
	bb.vertices = hb.verts
	bb.face_indices = hb.indices
	bb.face_counts = hb.counts
	bb.hand_edited = true
	var lean := Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.12))
	bb.transform = Transform3D(lean * Basis(Vector3.UP, rng.randf() * TAU), at)
	var n_faces := hb.counts.size()
	var ft := PackedInt32Array()
	var fs := PackedInt32Array()
	ft.resize(n_faces)
	ft.fill(T_BOULDER)
	fs.resize(n_faces)
	fs.fill(Surface.Sound.STONE)
	bb.face_textures = ft
	bb.face_surfaces = fs
	# (a cool grey over the stone texture)
	var vc := PackedColorArray()
	vc.resize(hb.verts.size())
	vc.fill(Color(0.92, 0.95, 1.0))
	bb.vertex_colors = vc
	bb.tag = &"boulder"
	return _add(bb)


## The spurs' valley-side foot at z (|x|; past the side walls' start: none).
func _spur_x(z: float) -> float:
	if z <= SPUR[0].y:
		return SPUR[0].x
	for k in SPUR.size() - 1:
		var a: Vector3 = SPUR[k]
		var b: Vector3 = SPUR[k + 1]
		if z <= b.y:
			return lerpf(a.x, b.x, (z - a.y) / (b.y - a.y))
	return 1000.0


## The land climbing on behind the spurs (into the mountain), faded out up by the terrace.
func _spur_rise(x: float, z: float) -> float:
	if z > -20.0:
		return 0.0
	var d := absf(x) - (_spur_x(z) + SPUR_BACK)
	if d <= 0.0:
		return 0.0
	return minf(d * SPUR_RISE, SPUR_RISE_MAX) * (1.0 - smoothstep(-45.0, -20.0, z))


## The side spurs: each stretch of SPUR (both sides) one big faceted rock along the valley's
## edge - its valley face leaning back, a ridge along the top, facets cut at random - its foot
## following the slope; the first stretch each side makes the entrance cleft.
func _spurs() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 31
	var tris := 0
	for side: float in [1.0, -1.0]:
		for k in SPUR.size() - 1:
			var a := Vector2(SPUR[k].x * side, SPUR[k].y)
			var b := Vector2(SPUR[k + 1].x * side, SPUR[k + 1].y)
			var dir := (b - a).normalized()
			var out := Vector2(dir.y, -dir.x)
			if signf(out.x) != side:
				out = -out
			var l := a.distance_to(b)
			var h: float = (SPUR[k].z + SPUR[k + 1].z) * 0.5 * rng.randf_range(0.9, 1.1)
			var bury := 10.0
			var ov := 5.0
			var box := AABB(Vector3(-ov, -bury, 0.0), Vector3(l + ov * 2.0, h + bury, SPUR_DEPTH))
			var cuts := []
			for f in 2:
				var lean := rng.randf_range(0.28, 0.4)
				var n := Vector3(rng.randf_range(-0.2, 0.2), lean, -1.0)
				cuts.append([n, n.dot(Vector3(l * (0.25 + 0.5 * f), -bury, rng.randf_range(0.0, 1.5)))])
			var nf := Vector3(0, 1, -0.9)
			cuts.append([nf, nf.dot(Vector3(l * 0.5, h * rng.randf_range(0.78, 0.9), (h + bury) * 0.34))])
			var nb := Vector3(0, 1, 0.7)
			cuts.append([nb, nb.dot(Vector3(l * 0.5, h * rng.randf_range(0.8, 0.92), SPUR_DEPTH))])
			var n0 := Vector3(-1, 0.6, -0.4)
			cuts.append([n0, n0.dot(Vector3(-ov + 1.0, h * 0.7, 0.0))])
			var n1 := Vector3(1, 0.6, -0.4)
			cuts.append([n1, n1.dot(Vector3(l + ov - 1.0, h * 0.7, 0.0))])
			for f in 4:
				cuts.append(_cut(Vector3(rng.randf_range(-1, 1), rng.randf_range(0.2, 1.0), rng.randf_range(-1, -0.2)), box, rng.randf_range(0.85, 0.95)))
			cuts.append(_cut(Vector3(rng.randf_range(-0.5, 0.5), 1.0, 0.0), box, rng.randf_range(0.88, 0.97)))
			var ya := _land(a.x, a.y).x
			var yb := _land(b.x, b.y).x
			var br := _crag(Vector3(a.x, ya, a.y), dir, out, (yb - ya) / l, 0.0, box, cuts, T_GRASS, T_CLIFF, &"spur")
			tris += _tri_count(br)
	print("spurs: %d triangles" % tris)


## Overhangs: rock brows jutting from the top of the back cliff and the west wall by the
## plunge pool (drooping a little, thinning to a lip), and sandstone brows left above the
## carved back wall of the terrace.
func _lips() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 37
	var tris := 0
	var spots := []  # [line point (x, z), along, out (to the valley)]
	for x: float in [-112.0, -92.0, -40.0, -18.0, 8.0, 30.0, 52.0]:
		if absf(x - _fall.x) < 14.0:
			continue
		spots.append([Vector2(x, _cliff_foot(x) + CLIFF_RUN + 1.0), Vector2(1, 0), Vector2(0, -1)])
	for z: float in [74.0, 100.0]:
		spots.append([Vector2(_west_foot(z) - CLIFF_RUN - 1.0, z), Vector2(0, 1), Vector2(1, 0)])
	for s in spots:
		var p: Vector2 = s[0]
		var dir: Vector2 = s[1]
		var out: Vector2 = s[2]
		var l := rng.randf_range(10.0, 16.0)
		var t := rng.randf_range(2.5, 4.0)
		var jut := rng.randf_range(5.0, 8.0)
		var a := p - dir * l * 0.5
		var y := _land(p.x, p.y).x + 0.3
		tris += _tri_count(_crag(Vector3(a.x, y, a.y), dir, out, 0.0, -0.12, AABB(Vector3(0, -t, -6.0), Vector3(l, t, 6.0 + jut)),
			_lip_cuts(l, t, 6.0, jut, rng), T_GRASS, T_CLIFF, &"lip"))
	for r: Vector2 in [Vector2(-42, -30), Vector2(-25, -13), Vector2(14, 26), Vector2(30, 39)]:
		var y: float = minf(minf(_land(r.x, TERRACE_Z + 0.6).x, _land(r.y, TERRACE_Z + 0.6).x), _land((r.x + r.y) * 0.5, TERRACE_Z + 0.6).x) - 0.05
		var l: float = r.y - r.x
		tris += _tri_count(_crag(Vector3(r.x, y, TERRACE_Z + 0.6), Vector2(1, 0), Vector2(0, -1), 0.0, 0.0,
			AABB(Vector3(0, -2.4, -3.0), Vector3(l, 2.4, 7.0)), _lip_cuts(l, 2.4, 3.0, 4.0, rng), T_CHURCH, T_CHURCH, &"lip"))
	print("lips: %d triangles" % tris)


## A brow's cuts (u along it 0..l, y -t..0, v -back..jut): the underside thinning to the lip,
## its front corners and top edge bevelled, a couple of random facets.
func _lip_cuts(l: float, t: float, back: float, jut: float, rng: RandomNumberGenerator) -> Array:
	var box := AABB(Vector3(0, -t, -back), Vector3(l, t, back + jut))
	var s := (t - 0.7) / (jut + back)
	var nu := Vector3(0, -1, s)
	var cuts := [[nu, nu.dot(Vector3(0, -t, -back))]]
	var c0 := Vector3(-1, 0, 1)
	cuts.append([c0, c0.dot(Vector3(rng.randf_range(1.0, 3.0), 0, jut))])
	var c1 := Vector3(1, 0, 1)
	cuts.append([c1, c1.dot(Vector3(l - rng.randf_range(1.0, 3.0), 0, jut))])
	var tb := Vector3(0, 1, 1.2)
	cuts.append([tb, tb.dot(Vector3(l * 0.5, -0.4, jut))])
	for f in 2:
		cuts.append(_cut(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 0.3), rng.randf_range(0.3, 1)), box, rng.randf_range(0.85, 0.95)))
	return cuts


## A cut keeping `k` of the box's reach along n (from its centre).
func _cut(n: Vector3, box: AABB, k: float) -> Array:
	n = n.normalized()
	var c := box.get_center()
	var e := box.size * 0.5
	return [n, n.dot(c) + k * (absf(n.x) * e.x + absf(n.y) * e.y + absf(n.z) * e.z)]


## A big faceted rock brush: `box` in local (u along `dir`, y up, v along `out`), cut by
## `cuts` ([normal, d]: n.p <= d kept), then placed at `origin` with its foot following
## `slope` along u and drooping `tilt` along v (both shears keep the faces flat). Faces facing
## up get `tex_up`, the rest `tex_side`.
func _crag(origin: Vector3, dir: Vector2, out: Vector2, slope: float, tilt: float, box: AABB, cuts: Array, tex_up: int, tex_side: int, tag: StringName) -> LevelBrush:
	var lo := box.position
	var hi := box.end
	var c := [Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)]
	var faces: Array[PackedVector3Array] = []
	for q in [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]:
		faces.append(PackedVector3Array([c[q[0]], c[q[1]], c[q[2]], c[q[3]]]))
	for cut in cuts:
		var n: Vector3 = cut[0]
		var len := n.length()
		faces = _clip_hull(faces, n / len, float(cut[1]) / len)
	var d3 := Vector3(dir.x, 0, dir.y)
	var o3 := Vector3(out.x, 0, out.y)
	var mapped: Array[PackedVector3Array] = []
	var centre := Vector3.ZERO
	var nv := 0
	for f in faces:
		var m := PackedVector3Array()
		for p in f:
			var w := d3 * p.x + o3 * p.z + Vector3.UP * (p.y + slope * p.x + tilt * p.z)
			m.append(w)
			centre += w
			nv += 1
		mapped.append(m)
	centre /= maxf(nv, 1)
	var hb := BrushShapes.Builder.new()
	var ft := PackedInt32Array()
	var fs := PackedInt32Array()
	for m in mapped:
		var fc := Vector3.ZERO
		var nn := Vector3.ZERO
		for i in m.size():
			fc += m[i]
			var p0 := m[i]
			var p1 := m[(i + 1) % m.size()]
			nn += Vector3((p0.y - p1.y) * (p0.z + p1.z), (p0.z - p1.z) * (p0.x + p1.x), (p0.x - p1.x) * (p0.y + p1.y))
		fc /= m.size()
		var outward := fc - centre
		if nn.dot(outward) < 0.0:
			nn = -nn
		hb.face(Array(m), outward)
		var up := nn.normalized().y > 0.7
		ft.append(tex_up if up else tex_side)
		fs.append(Surface.Sound.GRASS if up and tex_up == T_GRASS else Surface.Sound.STONE)
	var bb := LevelBrush.new()
	bb.vertices = hb.verts
	bb.face_indices = hb.indices
	bb.face_counts = hb.counts
	bb.hand_edited = true
	bb.transform = Transform3D(Basis(), origin)
	bb.face_textures = ft
	bb.face_surfaces = fs
	bb.tag = tag
	return _add(bb)


func _tri_count(b: LevelBrush) -> int:
	var n := 0
	for c in b.face_counts:
		n += c - 2
	return n


## Rows of fir cards (2 triangles each) along the spurs' feet: dense forest to the rock in
## the fog, hiding where the rock meets the slope. They block (a trunk cylinder) like trees.
func _card_rows() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 43
	var n := 0
	for side: float in [1.0, -1.0]:
		var z := -136.0
		while z < -36.0:
			var zz := z + rng.randf_range(-1.5, 1.5)
			var x := side * (_spur_x(zz) - rng.randf_range(3.0, 6.5))
			z += rng.randf_range(5.5, 8.0)
			if _path_at(x, zz).x < PATH_HALF + 3.0:
				continue
			var sp: String = "fir" if rng.randf() < 0.8 else "oak"
			_prop(PropSpec.Kind.TREE, {species = load(SPECIES + sp + ".tres"), seed = rng.randi_range(1, 99999),
				size = rng.randf_range(1.0, 1.5), card_only = true}, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(x, _land(x, zz).x, zz)))
			n += 1
	print("card rows: %d" % n)


## A convex hull (its faces) cut by the plane n.p = d: the part with n.p <= d kept, the cut capped.
func _clip_hull(faces: Array[PackedVector3Array], n: Vector3, d: float) -> Array[PackedVector3Array]:
	var out: Array[PackedVector3Array] = []
	var cap := PackedVector3Array()
	for f in faces:
		var poly := PackedVector3Array()
		for i in f.size():
			var a := f[i]
			var b := f[(i + 1) % f.size()]
			var da := n.dot(a) - d
			var db := n.dot(b) - d
			if da <= 0.0:
				poly.append(a)
			if (da < 0.0 and db > 0.0) or (da > 0.0 and db < 0.0):
				var p := a.lerp(b, da / (da - db))
				poly.append(p)
				cap.append(p)
		if poly.size() >= 3:
			out.append(poly)
	if cap.size() >= 3:
		# (the cut's points in order round their middle)
		var m := Vector3.ZERO
		for p in cap:
			m += p
		m /= cap.size()
		var u := (cap[0] - m).normalized()
		var v := n.cross(u)
		var pts := Array(cap)
		pts.sort_custom(func(p: Vector3, q: Vector3) -> bool:
			return atan2((p - m).dot(v), (p - m).dot(u)) < atan2((q - m).dot(v), (q - m).dot(u)))
		var ring := PackedVector3Array()
		for p: Vector3 in pts:
			if ring.is_empty() or ring[ring.size() - 1].distance_to(p) > 0.001:
				ring.append(p)
		if ring.size() > 1 and ring[0].distance_to(ring[ring.size() - 1]) < 0.001:
			ring.remove_at(ring.size() - 1)
		if ring.size() >= 3:
			out.append(ring)
	return out


## The forest: mostly firs (some oaks and sycamores) over the hillside and the slopes round
## the terraces (3D close, cards further out), clear of the paths, the terrace, the river and
## the cliff faces.
func _forest() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var kinds := ["fir", "fir", "fir", "oak", "sycamore"]
	var placed := 0
	for i in 1400:
		var p := Vector3(rng.randf_range(-120, 120), 0.0, rng.randf_range(-150, 120))
		if absf(p.x) < TERRACE_X + 4.0 and p.z > FRONT_Z - 4.0 and p.z < TERRACE_Z + 2.0:
			continue  # (the terrace and its rim)
		if _path_at(p.x, p.z).x < PATH_HALF + 2.5:
			continue  # (the paths)
		if absf(p.x) < 6.0 and p.z < ARRIVE_Z + 6.0:
			continue  # (the arrival)
		if p.z < -30.0 and absf(p.x) > _spur_x(p.z) - 2.0:
			continue  # (in or behind the side spurs)
		var cd := _cliff_d(p.x, p.z)
		if cd > -4.0 and cd < 14.0:
			continue  # (the cliff's foot and face)
		if p.z > TERRACE_Z - 2.0:
			var e := _edges(p.x)
			if p.z > e[0] - 7.0 and p.z < e[3] + 5.0:
				continue  # (the river, its banks, the capstan)
			if Vector2(p.x, p.z).distance_to(_fall) < POOL_R + 6.0:
				continue  # (the pool and its rocks)
			if absf(p.x - WHEEL_X) < 6.0 and p.z < e[0]:
				continue  # (under the aqueduct)
			if p.x > TERRACE_X - 6.0 and p.x < TERRACE_X + 4.0 and p.z < TERRACE_Z + 6.0:
				continue  # (the top of the carved stairs)
		p.y = _land(p.x, p.z).x
		var dist := Vector2(p.x, p.z - CHURCH_Z).length()
		var sp: String = kinds[rng.randi() % kinds.size()]
		var settings := {species = load(SPECIES + sp + ".tres"), seed = rng.randi_range(1, 99999), size = rng.randf_range(0.9, 1.5)}
		if dist > 110.0:
			settings.card_only = true
			settings.collide = false
		_prop(PropSpec.Kind.TREE, settings, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), p))
		placed += 1
		if placed >= 230:
			break
	print("trees: %d" % placed)
