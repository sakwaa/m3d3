extends Node
# Generates res://zones/debug/climb_sandbox/: one outdoor zone of level brushes testing every
# climb case. Vine faces: vines_wall texture + Climbable surface override.

const PATH := "res://zones/debug/climb_sandbox/climb_sandbox.tscn"
const C := Surface.CLIMBABLE

var data: LevelData
var T_GRASS: int
var T_VINE: int
var T_ROCK: int
var T_RED: int
var T_TOP: int


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PATH.get_base_dir()))
	if not FileAccess.file_exists(PATH):
		var err: Error = load("res://addons/n64_level_tools/zone_templates.gd").create(PATH, true)
		print("create: ", error_string(err))
	var data_path := PATH.get_basename() + "_level.res"
	data = load(data_path)
	var uid := ResourceLoader.get_resource_uid(data_path)
	var tex := [load("res://textures/grass/grass_meadow.res"), load("res://textures/grass/vines_wall.res"),
		load("res://textures/rock/granite_1.res"), load("res://textures/brick/bricks_red.res"),
		load("res://textures/rock/cobblestone_square.res")]
	data.textures.assign(tex)
	T_GRASS = 0; T_VINE = 1; T_ROCK = 2; T_RED = 3; T_TOP = 4
	data.brushes = []
	_build()
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
	_spawn_at(Vector3(0, 0, 6))
	get_tree().quit()


func _spawn_at(p: Vector3) -> void:
	var scene: PackedScene = load(PATH)
	var root := scene.instantiate()
	var spawn: Node3D = root.get_node("Spawn_default")
	spawn.position = p
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, PATH)
	root.free()


# --- Brushes ----------------------------------------------------------------------------

## A block (bottom-centre origin) with `kind`: "vine" (climbable sides, stone top), "plain",
## "noledge" (red, No ledge grab), "ceiling" (climbable underside).
func block(pos: Vector3, size: Vector3, kind := "plain", basis := Basis()) -> LevelBrush:
	var b := LevelBrush.new()
	b.shape = BrushShapes.Shape.BLOCK
	b.size = size
	b.generate_from_shape()
	b.transform = Transform3D(basis, pos)
	_paint(b, kind)
	data.add_brush(b)
	return b


func cylinder(pos: Vector3, radius: float, height: float, sides: int, kind: String) -> void:
	var b := LevelBrush.new()
	b.shape = BrushShapes.Shape.CYLINDER
	b.size = Vector3(radius * 2.0, height, radius * 2.0)
	b.segments = sides
	b.generate_from_shape()
	b.transform = Transform3D(Basis(), pos)
	_paint(b, kind)
	data.add_brush(b)


func _paint(b: LevelBrush, kind: String) -> void:
	var faces := b.get_faces()
	var centre := Vector3.ZERO
	for v in b.vertices:
		centre += v
	centre /= maxf(b.vertices.size(), 1)
	var ft := PackedInt32Array()
	var fs := PackedInt32Array()
	for f in faces:
		var a := b.vertices[f[0]]
		var n := (b.vertices[f[1]] - a).cross(b.vertices[f[2]] - a).normalized()
		var fc := Vector3.ZERO
		for i in f:
			fc += b.vertices[i]
		fc /= f.size()
		if n.dot(fc - centre) < 0.0:
			n = -n
		var wn := (b.transform.basis * n).normalized()
		var t := T_ROCK
		var s := 0
		match kind:
			"face":  # vines on the front (+Z) face only: the edges stop the climb
				if n.z > 0.7:
					t = T_VINE
					s = C
			"vine":
				if wn.y > 0.7:
					t = T_TOP
				else:
					t = T_VINE
					s = C
			"ceiling":
				if wn.y < -0.7:
					t = T_VINE
					s = C
			"noledge":
				t = T_RED
				s = Surface.NO_LEDGE
			"top":
				t = T_TOP
		ft.append(t)
		fs.append(s)
	b.face_textures = ft
	b.face_surfaces = fs


## A slab whose top face is a surface at `angle` degrees from horizontal, rising from
## `start` (on its bottom edge) towards -Z. Returns the top edge point.
func slope(start: Vector3, angle: float, length: float, width: float, kind := "vine") -> Vector3:
	var a := deg_to_rad(angle)
	var d := Vector3(0, sin(a), -cos(a))
	var n := Vector3(0, cos(a), sin(a))
	var basis := Basis(Vector3.RIGHT, n, Vector3.RIGHT.cross(n))
	var thick := 1.2
	var mid := start + d * length * 0.5
	var b := block(mid - n * thick, Vector3(width, thick, length), kind, basis)
	# The surface is the block's local top: paint by local normal instead of world.
	var faces := b.get_faces()
	var ft := b.face_textures
	var fs := b.face_surfaces
	for i in faces.size():
		var f: PackedInt32Array = faces[i]
		var c := Vector3.ZERO
		for k in f:
			c += b.vertices[k]
		c /= f.size()
		var top := c.y > thick - 0.01
		var vine := top and kind == "vine" and angle > 50.0  # flatter: walk on it
		ft[i] = T_VINE if vine else (T_TOP if top else T_ROCK)
		fs[i] = C if vine else 0
	b.face_textures = ft
	b.face_surfaces = fs
	return start + d * length


func _build() -> void:
	var g := LevelBrush.new()
	g.shape = BrushShapes.Shape.GRID
	g.size = Vector3(160, 0, 160)
	g.segments = 16
	g.generate_from_shape()
	g.transform = Transform3D(Basis(), Vector3(0, 0, -16))
	var gt := PackedInt32Array()
	gt.resize(g.get_faces().size())
	gt.fill(T_GRASS)
	g.face_textures = gt
	data.add_brush(g)

	# Row A: faces towards +Z (the spawn), along z = -6.
	var z := -6.0
	# A1 short ledges to jump / catch up onto: 0.6 .. 3.6 m.
	var x := -48.0
	for h in [0.6, 1.0, 1.4, 1.9, 2.4, 3.0, 3.6]:
		block(Vector3(x, 0, z - 1.0), Vector3(1.8, h, 2.0), "plain")
		x += 2.2
	# A2 plain vertical vine wall, 6 m, room on top to pull up.
	block(Vector3(-26, 0, z - 1.5), Vector3(6, 6, 3), "vine")
	# A3 overhangs leaning out 10 / 20 / 30 (limit) / 40 degrees (too steep: won't hold).
	x = -17.0
	for deg in [10.0, 20.0, 30.0, 40.0]:
		var basis := Basis(Vector3.RIGHT, deg_to_rad(deg))
		block(Vector3(x, -1.0, z - 1.2), Vector3(2.4, 6.0, 1.2), "vine", basis)
		x += 3.4
	# A4 walls leaning back 10 / 20 / 30 / 38 degrees (still too steep to walk).
	x = -1.0
	for deg in [10.0, 20.0, 30.0, 38.0]:
		var basis := Basis(Vector3.RIGHT, -deg_to_rad(deg))
		block(Vector3(x, -1.0, z - 1.0), Vector3(2.4, 6.0, 1.2), "vine", basis)
		x += 3.6
	# A5 a climb that flattens out until it's walkable: 85, 75, 65, 55 (climb), 45, 35 (walk).
	var p := Vector3(19, 0, z)
	for deg in [85.0, 75.0, 65.0, 55.0, 45.0, 35.0]:
		p = slope(p, deg, 1.6, 4.0)
	block(Vector3(19, p.y - 1.0, p.z - 1.5), Vector3(4.0, 1.0, 3.0), "top")
	# A6 inside corners: a U of vine walls (two 90 degree corners) and a 135 degree corner.
	block(Vector3(31, 0, z - 4.0), Vector3(6, 6, 1), "vine")  # back
	block(Vector3(28.5, 0, z - 1.5), Vector3(1, 6, 4), "vine")  # left side
	block(Vector3(33.5, 0, z - 1.5), Vector3(1, 6, 4), "vine")  # right side
	block(Vector3(39, 0, z - 2.0), Vector3(4, 6, 1), "vine")
	var d2 := Vector3(0.7071, 0, 0.7071)
	var n2 := Vector3(-0.7071, 0, 0.7071)
	block(Vector3(41, 0, z - 1.5) + d2 * 2.0 - n2 * 0.5, Vector3(4, 6, 1), "vine", Basis(Vector3.UP, deg_to_rad(-45.0)))
	# A7 outside corners: square pillar, octagonal pillar.
	block(Vector3(50, 0, z - 1.25), Vector3(2.5, 6, 2.5), "vine")
	cylinder(Vector3(56, 0, z - 1.5), 1.5, 6.0, 8, "vine")

	# Row B: faces towards -Z (back to the spawn), along z = 22.
	z = 22.0
	# B1 no-climb areas: a vine wall with a plain stripe up the middle (leap across) and a
	# plain band across it (leap up over); a ledge painted No ledge grab beside a plain one.
	var wx := -44.0
	block(Vector3(wx - 2.5, 0, z + 1), Vector3(3, 3, 2), "vine")
	block(Vector3(wx - 2.5, 3, z + 1), Vector3(3, 1.2, 2), "plain")
	block(Vector3(wx - 2.5, 4.2, z + 1), Vector3(3, 3.8, 2), "vine")
	block(Vector3(wx, 0, z + 1), Vector3(2, 8, 2), "plain")
	block(Vector3(wx + 2.5, 0, z + 1), Vector3(3, 8, 2), "vine")
	block(Vector3(-34, 0, z + 1), Vector3(3, 2.6, 2), "noledge")
	block(Vector3(-30, 0, z + 1), Vector3(3, 2.6, 2), "plain")
	# B2 gaps: pillars 1.4 / 2.1 / 3.2 m apart sideways, and a diagonal step-up pair.
	x = -22.0
	for gap in [1.4, 2.1, 3.2]:
		block(Vector3(x, 0, z + 1), Vector3(2, 5, 2), "vine")
		x += 2.0 + gap
	block(Vector3(x, 0, z + 1), Vector3(2, 5, 2), "vine")
	block(Vector3(x + 4.5, 0, z + 1), Vector3(2, 3, 2), "vine")
	block(Vector3(x + 7.9, 4.4, z + 1), Vector3(2, 3, 2), "vine")
	block(Vector3(x + 7.9, 0, z + 1), Vector3(2, 4.4, 2), "plain")
	# B3 shimmying: a plain tower with a lip all round at 2.6 m (catch from a jump), a
	# landing behind with vines above it; and an L wall with a lip round its inside corner.
	var tx := 8.0
	block(Vector3(tx, 0, z + 2), Vector3(4, 7, 4), "plain")
	for side in [[Vector3(0, 0, -2.15), Vector3(4.6, 0.3, 0.3)], [Vector3(0, 0, 2.15), Vector3(4.6, 0.3, 0.3)],
			[Vector3(-2.15, 0, 0), Vector3(0.3, 0.3, 4.0)], [Vector3(2.15, 0, 0), Vector3(0.3, 0.3, 4.0)]]:
		block(Vector3(tx, 2.3, z + 2) + side[0], side[1], "plain")
	block(Vector3(tx, 2.3, z + 5.0), Vector3(4.6, 0.3, 1.6), "top")  # landing at the back
	block(Vector3(tx, 2.6, z + 4.15), Vector3(2.0, 4.4, 0.3), "vine")  # vines above it
	block(Vector3(tx + 8, 0, z + 1), Vector3(6, 5, 1), "plain")
	block(Vector3(tx + 10.5, 0, z + 3), Vector3(1, 5, 5), "plain")
	block(Vector3(tx + 7.5, 2.3, z + 1.65), Vector3(5, 0.3, 0.3), "plain")  # lips on the inside
	block(Vector3(tx + 9.85, 2.3, z + 3.5), Vector3(0.3, 0.3, 4.0), "plain")
	# B4 ceiling: a vine underside at 3.4 m held by a back wall, a vine wall at its far end.
	block(Vector3(26, 3.4, z + 2), Vector3(6, 0.5, 8), "ceiling")
	block(Vector3(26, 0, z + 6.5), Vector3(6, 4.4, 1), "vine")
	# B5 grip: 22 m of vines (more than the base grip). The left half steps back at 11 m: a
	# ledge to pull up onto and rest (grip refills on the ground); the right half doesn't.
	block(Vector3(42.5, 0, z + 1.5), Vector3(3, 11, 3), "vine")
	block(Vector3(42.5, 11, z + 2.5), Vector3(3, 11, 1), "vine")
	block(Vector3(45.5, 0, z + 1.5), Vector3(3, 22, 3), "vine")

	_tower()


# --- The ruin: a long multi-pitch climb round a stepped cylindrical tower ------------------

const TC := Vector3(0, 0, -52)  # tower centre (on the ground)
const SIDES := 32
## Stages: [radius, from y, to y]. Each steps in, leaving a terrace ring to rest on.
const STAGES := [[10.0, 0, 8], [8.0, 8, 16], [6.5, 16, 27], [5.2, 27, 38]]
## Climbable patches on the tower itself: [from deg, to deg, from y, to y]. Angles turn
## right as seen facing the tower (0 = facing the spawn side).
const PATCHES := [
	# Pitch 1 (stage 2): vines, a plain band to leap over, up to a lip to shimmy along.
	[60, 82, 8, 10], [60, 82, 11, 13],
	[92, 124, 13, 16],  # vines above the lip's far end: climb on up to the terrace
	# Pitch 2 (stage 3): up to an overhang, a vine ceiling, round its edge onto it.
	[188, 228, 16, 19],
	# Pitch 3 (stage 3): from the cornice, right through buttress fins to the terrace.
	[220, 272, 22, 27],
	# The grip column (stage 4): 11 m of unbroken vines, no rest, the other way round.
	[100, 124, 27, 38],
	# Pitch 4 (stage 4): vines above the last lip, to the top.
	[8, 34, 34, 38],
]


func polar(deg: float, r: float, y: float) -> Vector3:
	var t := deg_to_rad(deg)
	return TC + Vector3(sin(t) * r, y, cos(t) * r)


## A block set tangent to the tower at `deg`: its back at radius `r_in`, `depth` outwards,
## `width` along the curve, bottom at `y`. `tilt` leans it (degrees; + = top outwards).
func tangent_block(deg: float, r_in: float, depth: float, y: float, h: float, width: float, kind: String, tilt := 0.0) -> LevelBrush:
	var basis := Basis(Vector3.UP, deg_to_rad(deg)) * Basis(Vector3.RIGHT, deg_to_rad(tilt))
	return block(polar(deg, r_in + depth * 0.5, y), Vector3(width, h, depth), kind, basis)


func _in_patch(deg: float, y0: float, y1: float) -> bool:
	for p in PATCHES:
		var d := fposmod(deg - p[0], 360.0)
		if d <= fposmod(p[1] - p[0], 360.0) and y0 >= p[2] - 0.01 and y1 <= p[3] + 0.01:
			return true
	return false


func _tower() -> void:
	# Drums 1 m tall, so patches can start and stop on any metre.
	for st in STAGES:
		var r: float = st[0]
		for y in range(st[1], st[2]):
			var b := LevelBrush.new()
			b.shape = BrushShapes.Shape.CYLINDER
			b.size = Vector3(r * 2.0, 1.0, r * 2.0)
			b.segments = SIDES
			b.generate_from_shape()
			b.transform = Transform3D(Basis(), TC + Vector3(0, y, 0))
			var ft := PackedInt32Array()
			var fs := PackedInt32Array()
			for f in b.get_faces():
				var a := b.vertices[f[0]]
				var n := (b.vertices[f[1]] - a).cross(b.vertices[f[2]] - a).normalized()
				var c := Vector3.ZERO
				for k in f:
					c += b.vertices[k]
				c /= f.size()
				if n.dot(c - Vector3(0, 0.5, 0)) < 0.0:
					n = -n
				if absf(n.y) > 0.7:
					var crown := y == 37 and n.y > 0.0
					ft.append(T_GRASS if crown else T_TOP)
					fs.append(0)
					continue
				var deg := rad_to_deg(atan2(n.x, n.z))
				var vine := _in_patch(deg, y, y + 1)
				ft.append(T_VINE if vine else T_ROCK)
				fs.append(C if vine else 0)
			b.face_textures = ft
			b.face_surfaces = fs
			data.add_brush(b)

	# Pitch 0 (stage 1, the base): a battered skirt of vine slabs leaning back 14 degrees,
	# one missing (leap across), a plain one to the left; pull up onto the first terrace.
	for deg in [-24.0, -12.0, 0.0, 12.0, 32.0, 44.0]:
		tangent_block(deg, 11.4, 0.6, 0.0, 8.25, 2.45, "plain" if deg < -20.0 else "face", -14.0)
	# Pitch 1: a lip at 13 m round to the right (shimmy), catchable from the vines below.
	var d := 70.0
	while d <= 104.0:
		tangent_block(d, 7.95, 0.4, 12.7, 0.3, 1.75, "plain")
		d += 11.25
	# Pitch 2: overhanging vine slabs (22 degrees) up to a cornice with a vine underside.
	for deg in [196.0, 210.0, 224.0]:
		tangent_block(deg, 5.97, 0.5, 18.8, 3.4, 1.7, "face", 22.0)  # front flush with the wall at the foot
	d = 186.0
	var lift := 0.0
	while d <= 234.0:
		tangent_block(d, 6.4, 3.2, 22.0 + lift, 0.8, 1.95, "ceiling")
		lift = 0.004 - lift  # neighbours overlap a little: no coplanar fighting
		d += 7.5
	# Pitch 3: buttress fins (vines) standing out of the wall: inside and outside corners.
	for deg in [240.0, 256.0]:
		var basis := Basis(Vector3.UP, deg_to_rad(deg))
		block(polar(deg, 7.4, 22.8), Vector3(0.5, 4.2, 1.9), "vine", basis)
	# Pitch 4 (stage 4): vine pilasters on plain wall with gaps between (leap right,
	# rising), a ledge painted No ledge grab as a decoy, a real lip reached with a leap up,
	# a shimmy, and vines to the top.
	var py := 27.0
	for deg in [292.0, 317.0]:
		tangent_block(deg, 5.15, 0.7, py, 4.5, 1.2, "face")
		py += 1.5
	for deg in [350.0, 361.0]:
		tangent_block(deg, 5.15, 0.4, 31.2, 0.3, 1.1, "noledge")
	d = 330.0
	while d <= 382.0:
		tangent_block(d, 5.15, 0.4, 33.9, 0.3, 1.15, "plain")
		d += 11.25

