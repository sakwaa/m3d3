@tool
class_name MarketStall
extends Node3D
## A swap-meet seller's pitch, built from simple low-poly pieces: a tent (poles, a peaked
## cloth canopy with a hanging valance, a table), a carpet laid on the ground, a hand cart
## with a parasol, or just a pile of goods. Goods (crates, baskets, sacks, pots, produce)
## are set out on the table / carpet / cart from `goods_seed`. Each kind but GOODS has an
## NpcSpot behind it (`<node name>_seller` in snake case) for a schedule to stand someone at.
## +Z is the customers' side. Placed from the level tools' Props menu.

enum Kind { TENT, CARPET, CART, GOODS }
enum Goods { MIXED, CRATES, BASKETS, SACKS, POTS, PRODUCE }

@export var kind := Kind.TENT:
	set(v):
		kind = v
		_rebuild()
## Footprint: width along X, depth along Z.
@export var size := Vector2(2.4, 1.6):
	set(v):
		size = v
		_rebuild()
@export var goods := Goods.MIXED:
	set(v):
		goods = v
		_rebuild()
## How full: 0 = bare, 1 = packed.
@export_range(0.0, 1.0, 0.05) var fullness := 0.7:
	set(v):
		fullness = v
		_rebuild()
@export var goods_seed := 1:
	set(v):
		goods_seed = v
		_rebuild()
@export_group("Look")
## Canopy, valance, parasol.
@export var cloth_texture: Texture2D = preload("res://textures/fabric/parchment_1.res"):
	set(v):
		cloth_texture = v
		_rebuild()
@export var cloth_color := Color(0.25, 0.32, 0.6):
	set(v):
		cloth_color = v
		_rebuild()
## Every other valance flap in this colour (stripes); same as cloth_color = plain.
@export var trim_color := Color(0.92, 0.88, 0.78):
	set(v):
		trim_color = v
		_rebuild()
@export var carpet_texture: Texture2D = preload("res://textures/fabric/carpet_3.res"):
	set(v):
		carpet_texture = v
		_rebuild()
@export var wood_texture: Texture2D = preload("res://textures/wood/wood_2.res"):
	set(v):
		wood_texture = v
		_rebuild()
@export_range(1.6, 3.5, 0.05, "suffix:m") var tent_height := 2.3:
	set(v):
		tent_height = v
		_rebuild()
@export_group("")

const WEAVE := preload("res://textures/doors/woven_reed.res")
## Near detail / far stand-in distance (the level's, LevelRoot.LOD_SETTING).
const LOD_SETTING := "n64/build/lod_distance"
const SACKCLOTH := preload("res://textures/fabric/parchment_1.res")

var _parts: Node3D
var _surfaces := {}  # Material -> SurfaceTool
var _boxes := []  # collision boxes [size, centre]
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	if _parts:
		_parts.queue_free()
	_parts = Node3D.new()
	_parts.name = "Parts"
	add_child(_parts, false, INTERNAL_MODE_BACK)
	_surfaces.clear()
	_boxes.clear()
	_rng.seed = goods_seed
	var hw := size.x * 0.5
	var hd := size.y * 0.5
	match kind:
		Kind.TENT:
			_tent(hw, hd)
		Kind.CARPET:
			_carpet(hw, hd)
		Kind.CART:
			_cart(hw, hd)
		Kind.GOODS:
			_goods_on(Rect2(-hw, -hd, size.x, size.y), 0.0)
	var lod_at: float = ProjectSettings.get_setting(LOD_SETTING, 40.0)
	var near := _commit_mesh()
	near.visibility_range_end = lod_at
	# Far: the same outline in a handful of triangles, swapped in past the LOD distance.
	_surfaces.clear()
	_far(hw, hd)
	var far := _commit_mesh()
	far.visibility_range_begin = lod_at
	if not _boxes.is_empty():
		var body := StaticBody3D.new()
		_parts.add_child(body)
		for b in _boxes:
			var cs := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = b[0]
			cs.shape = shape
			cs.position = b[1]
			body.add_child(cs)
	if kind != Kind.GOODS:
		var spot := NpcSpot.new()
		spot.spot_id = StringName(String(name).to_snake_case() + "_seller")
		spot.position = Vector3(0, 0, -hd - 0.45)
		_parts.add_child(spot)
	PropBatch.add(_parts)


func _commit_mesh() -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	for m: Material in _surfaces:
		var st: SurfaceTool = _surfaces[m]
		PropBatch.commit(st, mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, m)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	_parts.add_child(mi)
	return mi


## The far stand-in: canopy, valance, table and one block for the goods (tent); the rug and
## a low block (carpet); bed, goods, parasol (cart); one block (goods).
func _far(hw: float, hd: float) -> void:
	var wood := _mat(Color(0.75, 0.6, 0.45), wood_texture)
	var goods_col := _mat(Color(0.62, 0.5, 0.36), null)
	match kind:
		Kind.TENT:
			var cloth := _mat(cloth_color, cloth_texture)
			var eave := tent_height - 0.25
			var px := hw + 0.15
			var pz := hd + 0.2
			var ox := px + 0.2
			var oz := pz + 0.3
			var ridge := tent_height + 0.35
			for sx in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					_box(wood, Vector3(0.08, eave, 0.08), Vector3(sx * px, eave * 0.5, sz * pz), false)
			for sz in [1.0, -1.0]:
				_quad(cloth, [Vector3(-ox, eave - 0.15, sz * oz), Vector3(ox, eave - 0.15, sz * oz), Vector3(ox, ridge, 0),
					Vector3(-ox, ridge, 0)], Vector3(0, 1, sz * 0.6), true)
				var flap := _mat(cloth_color.lerp(trim_color, 0.5), cloth_texture)
				_quad(flap, [Vector3(-ox, eave - 0.45, sz * oz), Vector3(ox, eave - 0.45, sz * oz), Vector3(ox, eave - 0.15, sz * oz),
					Vector3(-ox, eave - 0.15, sz * oz)], Vector3(0, 0, sz), true)
			for sx in [1.0, -1.0]:
				_tri(cloth, [Vector3(sx * ox, eave - 0.15, oz), Vector3(sx * ox, eave - 0.15, -oz), Vector3(sx * ox, ridge, 0)],
					Vector3(sx, 0, 0), true)
			# The table: top and legs (open underneath, as up close).
			_box(wood, Vector3(size.x, 0.06, size.y), Vector3(0, 0.8, 0), false)
			for sx in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					_post(wood, Vector3(0.07, 0.77, 0.07), Vector3(sx * (hw - 0.08), 0.385, sz * (hd - 0.08)))
			if fullness > 0.0:
				_box(goods_col, Vector3(size.x * 0.85, 0.22, size.y * 0.8), Vector3(0, 0.91, 0), false)
		Kind.CARPET:
			_quad(_mat(Color.WHITE, carpet_texture), [Vector3(-hw, 0.02, hd), Vector3(hw, 0.02, hd), Vector3(hw, 0.02, -hd),
				Vector3(-hw, 0.02, -hd)], Vector3.UP, false, Rect2(0, 0, 1, 1))
			if fullness > 0.0:
				_box(goods_col, Vector3(size.x * 0.8, 0.2, size.y * 0.8), Vector3(0, 0.12, 0), false)
		Kind.CART:
			# Bed and sides as one block, the wheels as flat discs, the leg.
			_box(wood, Vector3(size.x, 0.3, size.y), Vector3(0, 0.86, 0), false)
			for sx in [1.0, -1.0]:
				var rim := []
				for i in 6:
					var a := TAU * i / 6.0
					rim.append(Vector3(sx * (hw + 0.06), 0.4 + 0.4 * sin(a), 0.2 + 0.4 * cos(a)))
				_poly(wood, rim, Vector3(sx, 0, 0), true)
			_post(wood, Vector3(0.06, 0.71, 0.06), Vector3(0, 0.355, -hd + 0.1))
			if fullness > 0.0:
				_box(goods_col, Vector3(size.x * 0.85, 0.15, size.y * 0.8), Vector3(0, 1.05, 0), false)
			_box(wood, Vector3(0.05, 2.4 - 0.75, 0.05), Vector3(hw - 0.3, 0.75 + (2.4 - 0.75) * 0.5, -hd + 0.3), false)
			_cone(_mat(cloth_color, cloth_texture), Vector3(hw - 0.3, 2.25, -hd + 0.3), 0.9, 0.35)
		Kind.GOODS:
			_box(goods_col, Vector3(size.x * 0.85, 0.35, size.y * 0.85), Vector3(0, 0.175, 0), false)


# --- Kinds ---------------------------------------------------------------------------

func _tent(hw: float, hd: float) -> void:
	var wood := _mat(Color(0.75, 0.6, 0.45), wood_texture)
	var cloth := _mat(cloth_color, cloth_texture)
	var stripe := _mat(trim_color, cloth_texture)
	var eave := tent_height - 0.25
	# Four poles, a little outside the table.
	var px := hw + 0.15
	var pz := hd + 0.2
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(wood, Vector3(0.08, eave, 0.08), Vector3(sx * px, eave * 0.5, sz * pz), true)
	# Peaked canopy along X, overhanging the poles.
	var ox := px + 0.2
	var oz := pz + 0.3
	var ridge := tent_height + 0.35
	for sz in [1.0, -1.0]:
		_quad(cloth, [Vector3(-ox, eave - 0.15, sz * oz), Vector3(ox, eave - 0.15, sz * oz), Vector3(ox, ridge, 0), Vector3(-ox, ridge, 0)],
			Vector3(0, 1, sz * 0.6), true)
	for sx in [1.0, -1.0]:
		_tri(cloth, [Vector3(sx * ox, eave - 0.15, oz), Vector3(sx * ox, eave - 0.15, -oz), Vector3(sx * ox, ridge, 0)],
			Vector3(sx, 0, 0), true)
	# Valance: flaps hanging from the front and back eaves, alternating colours.
	var flaps := maxi(3, roundi(ox * 2.0 / 0.4))
	for sz in [1.0, -1.0]:
		for i in flaps:
			var x0 := -ox + ox * 2.0 * i / flaps
			var x1 := -ox + ox * 2.0 * (i + 1) / flaps
			var m := cloth if i % 2 == 0 else stripe
			var z: float = sz * oz
			var y0 := eave - 0.15
			_quad(m, [Vector3(x0, y0 - 0.3, z), Vector3(x1, y0 - 0.3, z), Vector3(x1, y0, z), Vector3(x0, y0, z)],
				Vector3(0, 0, sz), true)
	_table(hw, hd, wood)


func _carpet(hw: float, hd: float) -> void:
	var rug := _mat(Color.WHITE, carpet_texture)
	_quad(rug, [Vector3(-hw, 0.02, hd), Vector3(hw, 0.02, hd), Vector3(hw, 0.02, -hd), Vector3(-hw, 0.02, -hd)], Vector3.UP, false,
		Rect2(0, 0, 1, 1))
	# A low cushion for the seller behind it.
	_box(_mat(cloth_color, cloth_texture), Vector3(0.5, 0.12, 0.4), Vector3(0, 0.06, -hd - 0.45), false)
	_goods_on(Rect2(-hw + 0.15, -hd + 0.15, size.x - 0.3, size.y - 0.3), 0.02)


func _cart(hw: float, hd: float) -> void:
	var wood := _mat(Color(0.7, 0.55, 0.4), wood_texture)
	var bed := 0.75
	# Bed, sides and handles.
	_box(wood, Vector3(size.x, 0.08, size.y), Vector3(0, bed, 0), true)
	for sz in [1.0, -1.0]:
		_box(wood, Vector3(size.x, 0.22, 0.05), Vector3(0, bed + 0.15, sz * (hd - 0.025)), false)
	for sx in [1.0, -1.0]:
		_box(wood, Vector3(0.05, 0.22, size.y), Vector3(sx * (hw - 0.025), bed + 0.15, 0), false)
		_box(wood, Vector3(0.06, 0.06, 0.9), Vector3(sx * (hw - 0.2), bed - 0.05, -hd - 0.4), false)
	# Two wheels (6-sided) on the sides, a leg at the handle end.
	for sx in [1.0, -1.0]:
		_cylinder(wood, Vector3(sx * (hw + 0.06), 0.4, 0.2), 0.4, 0.4, 0.08, Vector3.RIGHT)
	_box(wood, Vector3(0.06, bed, 0.06), Vector3(0, bed * 0.5, -hd + 0.1), false)
	# Parasol on a pole.
	var top := 2.4
	_box(wood, Vector3(0.05, top - bed, 0.05), Vector3(hw - 0.3, bed + (top - bed) * 0.5, -hd + 0.3), false)
	_cone(_mat(cloth_color, cloth_texture), Vector3(hw - 0.3, top - 0.15, -hd + 0.3), 0.9, 0.35)
	_goods_on(Rect2(-hw + 0.1, -hd + 0.1, size.x - 0.2, size.y - 0.2), bed + 0.04)


func _table(hw: float, hd: float, wood: Dictionary) -> void:
	var h := 0.8
	_box(wood, Vector3(size.x, 0.06, size.y), Vector3(0, h, 0), false)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(wood, Vector3(0.07, h, 0.07), Vector3(sx * (hw - 0.08), h * 0.5, sz * (hd - 0.08)), false)
	_boxes.append([Vector3(size.x, h, size.y), Vector3(0, h * 0.5, 0)])
	_goods_on(Rect2(-hw + 0.08, -hd + 0.08, size.x - 0.16, size.y - 0.16), h + 0.03)


# --- Goods ---------------------------------------------------------------------------

## Fills `area` (XZ) at height `y` with goods in a loose grid.
func _goods_on(area: Rect2, y: float) -> void:
	var cell := 0.45
	var nx := maxi(1, floori(area.size.x / cell))
	var nz := maxi(1, floori(area.size.y / cell))
	for i in nx:
		for j in nz:
			if _rng.randf() > fullness:
				continue
			var c := area.position + Vector2((i + 0.5) * area.size.x / nx, (j + 0.5) * area.size.y / nz)
			c += Vector2(_rng.randf_range(-0.05, 0.05), _rng.randf_range(-0.05, 0.05))
			var what := goods if goods != Goods.MIXED else _rng.randi_range(1, Goods.size() - 1)
			_item(what, Vector3(c.x, y, c.y))


func _item(what: int, at: Vector3) -> void:
	match what:
		Goods.CRATES:
			var s := _rng.randf_range(0.3, 0.4)
			_box(_mat(Color(0.8, 0.68, 0.5), wood_texture), Vector3(s, s * 0.8, s), at + Vector3(0, s * 0.4, 0), false)
			# Produce showing in the top.
			_box(_mat(_produce_color(), null), Vector3(s * 0.85, 0.04, s * 0.85), at + Vector3(0, s * 0.8 + 0.01, 0), false)
		Goods.BASKETS:
			var r := _rng.randf_range(0.14, 0.19)
			_cylinder(_mat(Color(0.85, 0.72, 0.5), WEAVE), at + Vector3(0, 0.1, 0), r, r * 0.8, 0.2, Vector3.UP)
			_cylinder(_mat(_produce_color(), null), at + Vector3(0, 0.2, 0), r * 0.85, r * 0.6, 0.06, Vector3.UP)
		Goods.SACKS:
			var r := _rng.randf_range(0.14, 0.18)
			var sack := _mat(Color(0.78, 0.68, 0.5), SACKCLOTH)
			_cylinder(sack, at + Vector3(0, 0.17, 0), r, r * 1.1, 0.34, Vector3.UP)
			_cone(sack, at + Vector3(0, 0.34, 0), r * 0.9, 0.08)
		Goods.POTS:
			var r := _rng.randf_range(0.1, 0.15)
			var clay := _mat(Color(0.72, 0.38, 0.22).lerp(Color(0.45, 0.35, 0.3), _rng.randf()), null)
			_cylinder(clay, at + Vector3(0, r * 0.9, 0), r * 0.6, r, r * 1.8, Vector3.UP)
			_cylinder(clay, at + Vector3(0, r * 1.9, 0), r * 0.5, r * 0.6, r * 0.25, Vector3.UP)
		Goods.PRODUCE:
			var m := _mat(_produce_color(), null)
			for k in 3:
				var o := Vector3(_rng.randf_range(-0.1, 0.1), 0.05 + k * 0.04, _rng.randf_range(-0.1, 0.1))
				_box(m, Vector3(0.1, 0.08, 0.1), at + o, false)


func _produce_color() -> Color:
	return [Color(0.85, 0.2, 0.15), Color(0.95, 0.65, 0.15), Color(0.4, 0.65, 0.2), Color(0.9, 0.85, 0.4),
		Color(0.55, 0.25, 0.5), Color(0.95, 0.95, 0.85)][_rng.randi() % 6]


# --- Building blocks -----------------------------------------------------------------

var _mats := {}


## A colour on a texture: one material per texture (colours go in the vertices), so a
## stall is a few draw calls however many colours its goods have.
func _mat(color: Color, tex: Texture2D) -> Dictionary:
	if not _mats.has(tex):
		var m := N64Materials.textured(Color.WHITE, tex)
		m.set_shader_parameter(&"use_vertex_color", true)
		_mats[tex] = m
	return {material = _mats[tex], color = color}


func _st(m: Material) -> SurfaceTool:
	if not _surfaces.has(m):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_surfaces[m] = st
	return _surfaces[m]


## A convex polygon facing `normal` (both sides when `both`). UVs: planar, 1 repeat per
## metre, or `rect` stretched over the polygon's bounds.
func _poly(m: Dictionary, pts: Array, normal: Vector3, both: bool, rect := Rect2()) -> void:
	var st := _st(m.material)
	var n: Vector3 = (pts[1] - pts[0]).cross(pts[2] - pts[0])
	var ordered: Array = pts if n.dot(normal) < 0.0 else _reversed(pts)  # Godot fronts: clockwise
	var axis := normal.abs()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var flat := []
	for p: Vector3 in ordered:
		var uv := Vector2(p.x, p.z) if axis.y >= axis.x and axis.y >= axis.z else (Vector2(p.z, -p.y) if axis.x >= axis.z else Vector2(p.x, -p.y))
		flat.append(uv)
		lo = lo.min(uv)
		hi = hi.max(uv)
	for i in range(1, ordered.size() - 1):
		for k in [0, i, i + 1]:
			var uv: Vector2 = flat[k]
			if rect.has_area():
				uv = rect.position + (uv - lo) / (hi - lo).max(Vector2(0.001, 0.001)) * rect.size
			st.set_normal(normal.normalized())
			st.set_color(m.color)
			st.set_uv(uv)
			st.add_vertex(ordered[k])
	if both:
		_poly(m, pts, -normal, false, rect)


func _quad(m: Dictionary, pts: Array, normal: Vector3, both: bool, rect := Rect2()) -> void:
	_poly(m, pts, normal, both, rect)


func _tri(m: Dictionary, pts: Array, normal: Vector3, both: bool) -> void:
	_poly(m, pts, normal, both)


static func _reversed(a: Array) -> Array:
	var b := a.duplicate()
	b.reverse()
	return b


func _box(m: Dictionary, s: Vector3, c: Vector3, collide: bool) -> void:
	var h := s * 0.5
	var p := func(x: float, y: float, z: float) -> Vector3: return c + Vector3(x * h.x, y * h.y, z * h.z)
	_quad(m, [p.call(-1, 1, -1), p.call(1, 1, -1), p.call(1, 1, 1), p.call(-1, 1, 1)], Vector3.UP, false)
	_quad(m, [p.call(-1, -1, -1), p.call(1, -1, -1), p.call(1, -1, 1), p.call(-1, -1, 1)], Vector3.DOWN, false)
	_quad(m, [p.call(-1, -1, 1), p.call(1, -1, 1), p.call(1, 1, 1), p.call(-1, 1, 1)], Vector3.BACK, false)
	_quad(m, [p.call(-1, -1, -1), p.call(1, -1, -1), p.call(1, 1, -1), p.call(-1, 1, -1)], Vector3.FORWARD, false)
	_quad(m, [p.call(1, -1, -1), p.call(1, -1, 1), p.call(1, 1, 1), p.call(1, 1, -1)], Vector3.RIGHT, false)
	_quad(m, [p.call(-1, -1, -1), p.call(-1, -1, 1), p.call(-1, 1, 1), p.call(-1, 1, -1)], Vector3.LEFT, false)
	if collide:
		_boxes.append([s, c])


## A box's four sides (a post or leg seen from afar: no top or bottom).
func _post(m: Dictionary, s: Vector3, c: Vector3) -> void:
	var h := s * 0.5
	var p := func(x: float, y: float, z: float) -> Vector3: return c + Vector3(x * h.x, y * h.y, z * h.z)
	_quad(m, [p.call(-1, -1, 1), p.call(1, -1, 1), p.call(1, 1, 1), p.call(-1, 1, 1)], Vector3.BACK, false)
	_quad(m, [p.call(-1, -1, -1), p.call(1, -1, -1), p.call(1, 1, -1), p.call(-1, 1, -1)], Vector3.FORWARD, false)
	_quad(m, [p.call(1, -1, -1), p.call(1, -1, 1), p.call(1, 1, 1), p.call(1, 1, -1)], Vector3.RIGHT, false)
	_quad(m, [p.call(-1, -1, -1), p.call(-1, -1, 1), p.call(-1, 1, 1), p.call(-1, 1, -1)], Vector3.LEFT, false)


## A 6-sided tapered cylinder centred on `c` along `axis` (UP or RIGHT): radius `r0` at the
## low / left end, `r1` at the other, `length` long, capped.
func _cylinder(m: Dictionary, c: Vector3, r0: float, r1: float, length: float, axis: Vector3) -> void:
	var sides := 6
	var u := Vector3.RIGHT if axis == Vector3.UP else Vector3.UP
	var v := axis.cross(u)
	var a := c - axis * length * 0.5
	var b := c + axis * length * 0.5
	var ring0 := []
	var ring1 := []
	for i in sides:
		var t := TAU * i / sides
		var d := u * cos(t) + v * sin(t)
		ring0.append(a + d * r0)
		ring1.append(b + d * r1)
	for i in sides:
		var j := (i + 1) % sides
		var mid: Vector3 = (ring0[i] + ring0[j] + ring1[i] + ring1[j]) * 0.25 - c
		mid -= axis * mid.dot(axis)
		_quad(m, [ring0[i], ring0[j], ring1[j], ring1[i]], mid, false)
	_poly(m, ring1, axis, false)
	_poly(m, ring0, -axis, false)


## A 6-sided cone (a parasol, a sack's neck): base radius `r` at `base`, `rise` tall, both sides.
func _cone(m: Dictionary, base: Vector3, r: float, rise: float) -> void:
	var sides := 6
	var tip := base + Vector3(0, rise, 0)
	for i in sides:
		var t0 := TAU * i / sides
		var t1 := TAU * (i + 1) / sides
		var p0 := base + Vector3(cos(t0), 0, sin(t0)) * r
		var p1 := base + Vector3(cos(t1), 0, sin(t1)) * r
		var out := ((p0 + p1) * 0.5 - base).normalized() + Vector3(0, r / maxf(rise, 0.01), 0)
		_tri(m, [p0, p1, tip], out, true)
