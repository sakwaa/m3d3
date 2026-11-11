@tool
class_name HouseBuilder
extends RefCounted
## A HouseSpec's faces (house brush local: footprint centred on the origin, ground at y = 0,
## +Z the front): the walls (one quad per side and storey; the build's lighting grid adds
## the vertices lighting needs), the plinth, gable ends, and the roof as a slab with eaves
## (top, underside, fascia, verges). Each face: {pts (wound to face `normal`), normal,
## texture (Texture2D), color, band, lod}, where `band` names the outside wall panel it
## belongs to (the trim borders each band; "" = none) and `lod` when it's drawn: the shell
## always (a shop's recess, counter and cloth too: the same faces near and far, so it never
## changes brightness or shape as you walk up) and a shop's shelves only close up
## (LOD_DETAIL_NEAR).
## `joins` (HouseTerrace.joins): sides standing against a neighbour in a terrace, which get
## no plinth lip or gable overhang and only the party wall the neighbour leaves showing.


## Part of HouseSpec.key(): bump it when the faces built change, so houses rebuild.
const VERSION := 16


static func build(spec: HouseSpec, joins := {}) -> Array:
	var out := []
	var hw := spec.width * 0.5
	var hd := spec.depth * 0.5
	var t := minf(spec.wall_thickness, minf(hw, hd) - 0.05)
	var top := spec.wall_height()
	# Walls: each side from one corner to the next, outward normal.
	var sides := [
		[Vector2(-hw, hd), Vector2(hw, hd), Vector3.BACK, "front"],
		[Vector2(hw, hd), Vector2(hw, -hd), Vector3.RIGHT, "right"],
		[Vector2(hw, -hd), Vector2(-hw, -hd), Vector3.FORWARD, "back"],
		[Vector2(-hw, -hd), Vector2(-hw, hd), Vector3.LEFT, "left"],
	]
	for s in sides:
		var a: Vector2 = s[0]
		var b: Vector2 = s[1]
		var n: Vector3 = s[2]
		var inset := Vector2(n.x, n.z) * t
		var ia := a - inset + (b - a).normalized() * t
		var ib := b - inset - (b - a).normalized() * t
		for k in spec.storeys:
			var y0 := spec.foundation + k * spec.storey_height
			var y1 := y0 + spec.storey_height
			if spec.shopfront and k == 0 and s[3] == "front":
				_shop_wall(out, spec, a, b, ib, ia, y0, y1, n, t)
				continue
			# (No inside faces: doors show black behind them, windows an opaque pane, and a shop
			# is a closed recess.)
			_wall(out, a, b, y0, y1, n, spec, "%s_%d" % [s[3], k])
	# Plinth / collision reach on each side (x): the lip, none where it joins a neighbour.
	var xl := -hw - (0.0 if joins.has("left") else spec.foundation_lip)
	var xr := hw + (0.0 if joins.has("right") else spec.foundation_lip)
	_foundation(out, spec, hw, hd, t, xl, xr)
	_collision(out, spec, hw, hd, xl, xr)
	var tan_p := tan(deg_to_rad(spec.roof_pitch))
	var lift := spec.roof_thickness / cos(deg_to_rad(spec.roof_pitch))
	var o := spec.overhang
	if spec.roof == HouseSpec.Roof.GABLE:
		_gable(out, spec, hw, hd, top, tan_p, lift, o, 0.0 if joins.has("left") else o, 0.0 if joins.has("right") else o)
	else:
		_hip(out, spec, hw, hd, top, tan_p, lift, o)
	out = HouseTerrace.cut_faces(out, hw, joins)
	# What collides: the simple box (_collision) and the roof's top; everything else is only
	# drawn (no snagging on awnings, curtains or shelves, and far fewer collision triangles).
	for f in out:
		if f.has("bake"):
			continue
		var roof_top: bool = f.lod == LevelBrush.LOD_ALWAYS and f.texture == spec.roof_texture and f.normal.y > 0.3
		f.bake = 0 if roof_top else 1
	return out


## Faces from `first` on drawn at `lod` instead.
static func _retag(out: Array, first: int, lod: int) -> void:
	for i in range(first, out.size()):
		out[i].lod = lod


## The house as collision: the plinth as a box (its lip's footprint) and the walls as a box
## above it, always there, never drawn. Openings cut through it like through the walls.
## The plinth's box reaches xl..xr across.
static func _collision(out: Array, spec: HouseSpec, hw: float, hd: float, xl: float, xr: float) -> void:
	var lz := hd + spec.foundation_lip
	var parts := [[xl, xr, lz, 0.0, spec.foundation, true], [-hw, hw, hd, spec.foundation, spec.wall_height(), false]]
	for part in parts:
		var x0: float = part[0]
		var x1: float = part[1]
		var z: float = part[2]
		var y0: float = part[3]
		var y1: float = part[4]
		if y1 - y0 < 0.01:
			continue
		for q in [[Vector2(x0, z), Vector2(x1, z), Vector3.BACK], [Vector2(x1, z), Vector2(x1, -z), Vector3.RIGHT],
				[Vector2(x1, -z), Vector2(x0, -z), Vector3.FORWARD], [Vector2(x0, -z), Vector2(x0, z), Vector3.LEFT]]:
			var a: Vector2 = q[0]
			var b: Vector2 = q[1]
			_face(out, [Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(b.x, y1, b.y), Vector3(a.x, y1, a.y)], q[2], null,
				Color.WHITE, "", LevelBrush.LOD_ALWAYS)
			out[-1].bake = 2
		if part[5]:
			_face(out, [Vector3(x0, y1, -z), Vector3(x1, y1, -z), Vector3(x1, y1, z), Vector3(x0, y1, z)], Vector3.UP,
				null, Color.WHITE, "", LevelBrush.LOD_ALWAYS)
			out[-1].bake = 2


## An outside wall panel from `a` to `b` (footprint XZ), y0..y1: one quad, always drawn (two
## where it crosses the top of the wainscot: the skirt below in its own material and band).
static func _wall(out: Array, a: Vector2, b: Vector2, y0: float, y1: float, n: Vector3, spec: HouseSpec, band: String) -> void:
	var wy := spec.foundation + spec.wainscot_height
	if spec.wainscot_height > 0.0 and y0 < wy - 0.01:
		var top := minf(wy, y1)
		_face(out, [Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(b.x, top, b.y), Vector3(a.x, top, a.y)], n,
			spec.wainscot_texture, spec.wainscot_color, band + "_skirt", LevelBrush.LOD_ALWAYS)
		if top >= y1 - 0.01:
			return
		y0 = top
	_face(out, [Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(b.x, y1, b.y), Vector3(a.x, y1, a.y)], n,
		spec.wall_texture, spec.wall_color, band, LevelBrush.LOD_ALWAYS)


## The front's ground storey of a shop: wall either side of the opening and over it, and
## behind the opening what its front_style makes of it:
##  - SHOP / WORKSHOP: a shallow room (floor, sides, ceiling and back wall, shop_depth in from
##    the wall's front; like a real shopfront, the street sees only the front room), with a
##    counter and shelves (SHOP) or the trade's tools (WORKSHOP, _workshop);
##  - SHUTTERED: plank shutters filling the opening, set into the wall, and a bar across.
## Then the awning / noren (a shuttered shop keeps only its awning).
static func _shop_wall(out: Array, spec: HouseSpec, a: Vector2, b: Vector2, ib: Vector2, ia: Vector2, y0: float, y1: float,
		n: Vector3, t: float) -> void:
	var hw := absf(a.x)
	var half := clampf(spec.shop_opening * 0.5, 0.3, hw - t - 0.2)
	var top := minf(y0 + spec.shop_height, y1 - 0.2)
	var z := a.y
	var band := "front_0"
	# Outside: left and right of the opening, then over it.
	_wall(out, a, Vector2(-half, z), y0, y1, n, spec, band)
	_wall(out, Vector2(half, z), b, y0, y1, n, spec, band)
	_wall(out, Vector2(-half, z), Vector2(half, z), top, y1, n, spec, band)
	var style := spec.front_style
	# Shutters: set in by SHUTTER_SET, so only that much of the reveal shows.
	var zb := z - SHUTTER_SET if style == HouseSpec.Front.SHUTTERED else \
		z - clampf(spec.shop_depth, t + 0.3, maxf(2.0 * z - 2.0 * t - 0.1, t + 0.3))
	var dark := spec.inside_color.darkened(0.35) if style == HouseSpec.Front.WORKSHOP and spec.trade == HouseSpec.Trade.SMITH \
		else spec.inside_color
	for sx in [-1.0, 1.0]:
		var x: float = sx * half
		_face(out, [Vector3(x, y0, zb), Vector3(x, y0, z), Vector3(x, top, z), Vector3(x, top, zb)], Vector3(-sx, 0, 0),
			spec.wall_texture, dark if style != HouseSpec.Front.SHUTTERED else spec.wall_color, "", LevelBrush.LOD_ALWAYS)
	_face(out, [Vector3(-half, top, zb), Vector3(half, top, zb), Vector3(half, top, z), Vector3(-half, top, z)], Vector3.DOWN,
		spec.eave_texture, spec.eave_color.darkened(0.2), "", LevelBrush.LOD_ALWAYS)
	_face(out, [Vector3(-half, y0, zb), Vector3(half, y0, zb), Vector3(half, y0, z), Vector3(-half, y0, z)], Vector3.UP,
		spec.floor_texture, Color(0.8, 0.72, 0.62), "", LevelBrush.LOD_ALWAYS)
	if style == HouseSpec.Front.SHUTTERED:
		# Vertical planks (the seams in the texture) and a bar across at counter height.
		var w := half * 2.0
		var h := top - y0
		_face(out, [Vector3(-half, y0, zb), Vector3(half, y0, zb), Vector3(half, top, zb), Vector3(-half, top, zb)], Vector3.BACK,
			plank_texture(spec), spec.eave_color.lightened(0.25), "", LevelBrush.LOD_ALWAYS,
			[Vector2(0, h), Vector2(w, h), Vector2(w, 0), Vector2(0, 0)])
		var yb := y0 + clampf(spec.counter_height, 0.6, h - 0.3)
		var first := out.size()
		_block(out, Vector3(-half, yb - 0.07, zb), Vector3(half, yb + 0.07, zb + 0.06), spec.eave_texture,
			spec.eave_color.darkened(0.3), [Vector3.FORWARD, Vector3.LEFT, Vector3.RIGHT])
		_retag(out, first, LevelBrush.LOD_ALWAYS)
		_cover(out, spec, half, top, z, LevelBrush.LOD_ALWAYS, false, false)
		return
	_face(out, [Vector3(-half, y0, zb), Vector3(half, y0, zb), Vector3(half, top, zb), Vector3(-half, top, zb)], Vector3.BACK,
		spec.wall_texture, dark, "", LevelBrush.LOD_ALWAYS)
	if style == HouseSpec.Front.WORKSHOP:
		_cover(out, spec, half, top, z, LevelBrush.LOD_ALWAYS, true)
		var first := out.size()
		_workshop(out, spec, half, y0, top, zb, z)
		_retag(out, first, LevelBrush.LOD_DETAIL_NEAR)
		return
	# Counter across the opening, standing a little proud of the wall: top, front and ends
	# (its back faces into the shop, out of sight).
	if spec.counter_height > 0.0:
		var c0 := Vector3(-half, y0, maxf(z - t - 0.25, zb + 0.3))
		var c1 := Vector3(half, y0 + spec.counter_height, z + 0.08)
		var first := out.size()
		_block(out, c0, c1, spec.eave_texture, spec.eave_color.lightened(0.15), [Vector3.DOWN, Vector3.FORWARD])
		_retag(out, first, LevelBrush.LOD_ALWAYS)
	_cover(out, spec, half, top, z, LevelBrush.LOD_ALWAYS, true)
	# Two shelves on the back wall (their top and front edge): only close up.
	var first := out.size()
	for y in [y0 + 0.95, y0 + 1.55]:
		if y + 0.06 < top - 0.1:
			_block(out, Vector3(-half + 0.15, y, zb), Vector3(half - 0.15, y + 0.06, zb + 0.3), spec.eave_texture, spec.eave_color,
				[Vector3.FORWARD, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT])
	_retag(out, first, LevelBrush.LOD_DETAIL_NEAR)


## How far shutters sit in from the wall's front.
const SHUTTER_SET := 0.08
## Clay, iron and ember colours for the workshops' things.
const CLAY := Color(0.66, 0.42, 0.3)
const IRON := Color(0.24, 0.24, 0.27)
const EMBER := Color(1.0, 0.5, 0.15)


## A workshop's tools in its room (x -half..half, floor y0 up to `top`, back wall zb to the
## front z), kept off the front so the opening reads: blocks and flat cloth, a few dozen
## triangles, drawn close up only.
static func _workshop(out: Array, spec: HouseSpec, half: float, y0: float, top: float, zb: float, z: float) -> void:
	var wood := spec.eave_texture
	var wc := spec.eave_color
	var stone := spec.foundation_texture
	var mid := (zb + z - 0.5) * 0.5  # middle of the room, clear of the front
	var none := [Vector3.DOWN]
	match spec.trade:
		HouseSpec.Trade.POTTER:
			# Wheel (pedestal, head, a lump of clay) and a stool; racks of pots on the back wall.
			var wx := -half * 0.45
			_block(out, Vector3(wx - 0.18, y0, mid - 0.18), Vector3(wx + 0.18, y0 + 0.45, mid + 0.18), wood, wc.darkened(0.2), none)
			_block(out, Vector3(wx - 0.3, y0 + 0.45, mid - 0.3), Vector3(wx + 0.3, y0 + 0.5, mid + 0.3), wood, wc, none)
			_block(out, Vector3(wx - 0.1, y0 + 0.5, mid - 0.1), Vector3(wx + 0.1, y0 + 0.66, mid + 0.1), null, CLAY, none)
			_block(out, Vector3(wx - 0.15, y0, mid - 0.65), Vector3(wx + 0.15, y0 + 0.35, mid - 0.4), wood, wc, none)
			for y in [y0 + 0.7, y0 + 1.3]:
				if y + 0.3 > top:
					continue
				_block(out, Vector3(-half + 0.1, y, zb), Vector3(half - 0.1, y + 0.05, zb + 0.3), wood, wc, none)
				var x := -half + 0.25
				var i := 0
				while x < half - 0.25:
					var r := 0.08 + 0.03 * (i % 2)
					_block(out, Vector3(x - r, y + 0.05, zb + 0.15 - r), Vector3(x + r, y + 0.05 + r * 2.2, zb + 0.15 + r), null,
						CLAY.lightened(0.12 * (i % 3)), none)
					x += 0.32
					i += 1
		HouseSpec.Trade.WEAVER:
			# A loom across the room (posts, beams, the warp half woven) and baskets of yarn.
			var lw := minf(half * 0.7, 0.8)
			var lz := mid
			var lt := minf(y0 + 1.6, top - 0.1)
			for sx in [-1.0, 1.0]:
				_block(out, Vector3(sx * lw - 0.04, y0, lz - 0.04), Vector3(sx * lw + 0.04, lt, lz + 0.04), wood, wc, none)
			_block(out, Vector3(-lw - 0.06, lt - 0.08, lz - 0.05), Vector3(lw + 0.06, lt, lz + 0.05), wood, wc, none)
			_block(out, Vector3(-lw, y0 + 0.5, lz - 0.05), Vector3(lw, y0 + 0.58, lz + 0.05), wood, wc, none)
			_cloth(out, spec, -lw + 0.04, lw - 0.04, y0 + 0.58, lt - 0.08, lz, spec.cloth_color)
			_block(out, Vector3(-lw * 0.6, y0, lz - 0.7), Vector3(lw * 0.6, y0 + 0.42, lz - 0.45), wood, wc, none)
			for i in 3:
				var bx := half - 0.3 - i * 0.32
				_block(out, Vector3(bx - 0.12, y0, zb + 0.1), Vector3(bx + 0.12, y0 + 0.22, zb + 0.34), null,
					[spec.cloth_color, spec.stripe_color, spec.cloth_color.lightened(0.3)][i], none)
		HouseSpec.Trade.SMITH:
			# Forge against the back wall (stone hearth, embers, an iron hood up to the ceiling),
			# an anvil on its stump, a quench tub.
			var fx := -half * 0.4
			_block(out, Vector3(fx - 0.5, y0, zb), Vector3(fx + 0.5, y0 + 0.75, zb + 0.7), stone, spec.foundation_color.darkened(0.3), none)
			_face(out, [Vector3(fx - 0.38, y0 + 0.76, zb + 0.1), Vector3(fx + 0.38, y0 + 0.76, zb + 0.1),
				Vector3(fx + 0.38, y0 + 0.76, zb + 0.6), Vector3(fx - 0.38, y0 + 0.76, zb + 0.6)], Vector3.UP, null, EMBER, "")
			if top - y0 > 1.7:
				_block(out, Vector3(fx - 0.45, y0 + 1.55, zb), Vector3(fx + 0.45, top, zb + 0.6), null, IRON, [])
			var ax := half * 0.3
			_block(out, Vector3(ax - 0.17, y0, mid - 0.17), Vector3(ax + 0.17, y0 + 0.5, mid + 0.17), wood, wc.darkened(0.3), none)
			_block(out, Vector3(ax - 0.28, y0 + 0.5, mid - 0.1), Vector3(ax + 0.28, y0 + 0.68, mid + 0.1), null, IRON, none)
			_block(out, Vector3(half - 0.55, y0, zb + 0.1), Vector3(half - 0.1, y0 + 0.5, zb + 0.55), wood, wc.darkened(0.4), [Vector3.DOWN, Vector3.UP])
			_face(out, [Vector3(half - 0.52, y0 + 0.45, zb + 0.13), Vector3(half - 0.13, y0 + 0.45, zb + 0.13),
				Vector3(half - 0.13, y0 + 0.45, zb + 0.52), Vector3(half - 0.52, y0 + 0.45, zb + 0.52)], Vector3.UP, null,
				Color(0.12, 0.14, 0.16), "")
		HouseSpec.Trade.DYER:
			# Vats of dye along the back and lengths of dyed cloth drying from a pole overhead.
			var dyes := [spec.cloth_color, spec.cloth_color.darkened(0.4), spec.stripe_color.lerp(spec.cloth_color, 0.4)]
			var n := clampi(int(half * 2.0 / 0.8), 1, 3)
			for i in n:
				var vx := -half + (i + 0.5) * half * 2.0 / n
				_block(out, Vector3(vx - 0.3, y0, zb + 0.1), Vector3(vx + 0.3, y0 + 0.6, zb + 0.7), wood, wc.lightened(0.1), [Vector3.DOWN, Vector3.UP])
				_face(out, [Vector3(vx - 0.27, y0 + 0.55, zb + 0.13), Vector3(vx + 0.27, y0 + 0.55, zb + 0.13),
					Vector3(vx + 0.27, y0 + 0.55, zb + 0.67), Vector3(vx - 0.27, y0 + 0.55, zb + 0.67)], Vector3.UP, null,
					dyes[i % dyes.size()], "")
			var py := top - 0.15
			var pz := mid + 0.2
			_block(out, Vector3(-half, py - 0.03, pz - 0.03), Vector3(half, py + 0.03, pz + 0.03), wood, wc, [])
			var cx := -half + 0.2
			var i := 0
			while cx + 0.45 < half - 0.1:
				_cloth(out, spec, cx, cx + 0.45, py - 1.0 + 0.15 * (i % 2), py - 0.03, pz, dyes[i % dyes.size()])
				cx += 0.55
				i += 1


## A hanging length of cloth (both sides), x0..x1 by y0..y1 across the room at depth `z`.
static func _cloth(out: Array, spec: HouseSpec, x0: float, x1: float, y0: float, y1: float, z: float, color: Color) -> void:
	for side in [1.0, -1.0]:
		var zz: float = z + side * 0.005
		_face(out, [Vector3(x0, y0, zz), Vector3(x1, y0, zz), Vector3(x1, y1, zz), Vector3(x0, y1, zz)], Vector3(0, 0, side),
			spec.cloth_texture, color, "")


## The plinth under the walls (stone, standing out by the lip, down into the ground; always
## drawn) and the ground floor's floor inside (seen through doors; a shop has its own). The
## plinth reaches xl..xr across (no lip on a side joined to a neighbour).
static func _foundation(out: Array, spec: HouseSpec, hw: float, hd: float, t: float, xl: float, xr: float) -> void:
	var f := spec.foundation
	var ix := hw - t
	var iz := hd - t
	if not spec.shopfront:
		_face(out, [Vector3(-ix, f, iz), Vector3(ix, f, iz), Vector3(ix, f, -iz), Vector3(-ix, f, -iz)], Vector3.UP,
			spec.floor_texture, Color(0.8, 0.72, 0.62), "")
	if f <= 0.0 and spec.foundation_sink <= 0.0:
		return
	var lz := hd + spec.foundation_lip
	var y0 := -spec.foundation_sink
	var tex := spec.foundation_texture
	var col := spec.foundation_color
	_face(out, [Vector3(xl, y0, lz), Vector3(xr, y0, lz), Vector3(xr, f, lz), Vector3(xl, f, lz)], Vector3.BACK, tex, col, "", LevelBrush.LOD_ALWAYS)
	_face(out, [Vector3(xl, y0, -lz), Vector3(xr, y0, -lz), Vector3(xr, f, -lz), Vector3(xl, f, -lz)], Vector3.FORWARD, tex, col, "", LevelBrush.LOD_ALWAYS)
	_face(out, [Vector3(xr, y0, -lz), Vector3(xr, y0, lz), Vector3(xr, f, lz), Vector3(xr, f, -lz)], Vector3.RIGHT, tex, col, "", LevelBrush.LOD_ALWAYS)
	_face(out, [Vector3(xl, y0, -lz), Vector3(xl, y0, lz), Vector3(xl, f, lz), Vector3(xl, f, -lz)], Vector3.LEFT, tex, col, "", LevelBrush.LOD_ALWAYS)
	# The lip's top: a ring round the walls (open on a joined side).
	if spec.foundation_lip > 0.0:
		_face(out, [Vector3(xl, f, hd), Vector3(xr, f, hd), Vector3(xr, f, lz), Vector3(xl, f, lz)], Vector3.UP, tex, col, "", LevelBrush.LOD_ALWAYS)
		_face(out, [Vector3(xl, f, -lz), Vector3(xr, f, -lz), Vector3(xr, f, -hd), Vector3(xl, f, -hd)], Vector3.UP, tex, col, "", LevelBrush.LOD_ALWAYS)
		if xr > hw + 0.001:
			_face(out, [Vector3(hw, f, -hd), Vector3(xr, f, -hd), Vector3(xr, f, hd), Vector3(hw, f, hd)], Vector3.UP, tex, col, "", LevelBrush.LOD_ALWAYS)
		if xl < -hw - 0.001:
			_face(out, [Vector3(xl, f, -hd), Vector3(-hw, f, -hd), Vector3(-hw, f, hd), Vector3(xl, f, hd)], Vector3.UP, tex, col, "", LevelBrush.LOD_ALWAYS)


## The shop's awning (a sloping striped sheet, its valance and, `inside`, the underside) and
## noren (split curtain hanging in the top of the opening, both sides when `inside`): one
## quad each, the stripes and splits in the texture (cloth_textures). `z`: the wall's front.
## `noren` false: the awning only.
static func _cover(out: Array, spec: HouseSpec, half: float, top: float, z: float, lod: int, inside: bool,
		noren := true) -> void:
	var tex := cloth_textures(spec)
	if spec.cover == HouseSpec.Cover.AWNING or spec.cover == HouseSpec.Cover.BOTH:
		var cloth_w := half + 0.3
		var stripes := maxi(3, roundi(cloth_w * 2.0 / 0.5))
		# One texture repeat: a cloth stripe, then a light one.
		var repeats := stripes * 0.5
		var ya := top + 0.35
		var drop := spec.awning_depth * 0.35
		var zf := z + spec.awning_depth
		var slope := Vector2(spec.awning_depth, drop).length()
		var up := Vector3(0, spec.awning_depth, drop).normalized()
		var u1 := repeats * AWNING_METRES
		var sheet := [Vector3(-cloth_w, ya, z), Vector3(cloth_w, ya, z), Vector3(cloth_w, ya - drop, zf), Vector3(-cloth_w, ya - drop, zf)]
		var sheet_uv := [Vector2(0, 0), Vector2(u1, 0), Vector2(u1, slope), Vector2(0, slope)]
		_face(out, sheet, up, tex.awning, Color.WHITE, "", lod, sheet_uv)
		var yv := ya - drop - 0.22
		_face(out, [Vector3(-cloth_w, yv, zf), Vector3(cloth_w, yv, zf), Vector3(cloth_w, ya - drop, zf), Vector3(-cloth_w, ya - drop, zf)],
			Vector3.BACK, tex.awning, Color.WHITE, "", lod, [Vector2(0, 0.22), Vector2(u1, 0.22), Vector2(u1, 0), Vector2(0, 0)])
		# Underside a little lower (on the same corners the bake would cull the pair).
		var under := []
		for p: Vector3 in sheet:
			under.append(p + Vector3(0, -0.02, 0))
		_face(out, under, -up, tex.awning, Color(0.7, 0.7, 0.7), "", lod, sheet_uv)
	if noren and (spec.cover == HouseSpec.Cover.NOREN or spec.cover == HouseSpec.Cover.BOTH):
		var panels := maxi(2, roundi(half * 2.0 / 0.45))
		var u1 := panels * NOREN_METRES.x
		var uv := [Vector2(0, 0.75), Vector2(u1, 0.75), Vector2(u1, 0), Vector2(0, 0)]
		for side: float in ([1.0, -1.0] if inside else [1.0]):
			var zz: float = z + 0.03 + side * 0.006 if inside else z + 0.04
			_face(out, [Vector3(-half, top - 0.75, zz), Vector3(half, top - 0.75, zz), Vector3(half, top, zz), Vector3(-half, top, zz)],
				Vector3(0, 0, side), tex.noren, spec.cloth_color, "", lod, uv)


## Metres one repeat of the cloth textures covers: the awning's (a stripe of each colour),
## the noren's (one panel and its split).
const AWNING_METRES := 1.0
const NOREN_METRES := Vector2(0.5, 1.0)
const CLOTH_DIR := "res://textures/fabric/generated"


## The shop cloth textures for `spec`, made (and saved under CLOTH_DIR) the first time:
## {awning: the cloth in cloth_color then stripe_color, side by side; noren: the cloth with
## a dark split down its right edge, tinted by the face colour}.
static func cloth_textures(spec: HouseSpec) -> Dictionary:
	var base := spec.cloth_texture.resource_path.get_file().get_basename() if spec.cloth_texture else "plain"
	var paths := {
		awning = "%s/awning_%s_%s_%s.res" % [CLOTH_DIR, base, spec.cloth_color.to_html(false), spec.stripe_color.to_html(false)],
		noren = "%s/noren_%s.res" % [CLOTH_DIR, base],
	}
	var out := {}
	var src: Image = null
	for kind: String in paths:
		var path: String = paths[kind]
		if ResourceLoader.exists(path):
			out[kind] = load(path)
			continue
		if src == null:
			src = _cloth_source(spec.cloth_texture)
		var metres := Vector2(AWNING_METRES, AWNING_METRES) if kind == "awning" else NOREN_METRES
		var density := N64Texture.texels_per_metre()
		var w := maxi(4, roundi(metres.x * density / 2.0) * 2)
		var h := maxi(1, roundi(metres.y * density))
		var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
		for y in h:
			for x in w:
				var c := src.get_pixel(x % src.get_width(), y % src.get_height())
				if kind == "awning":
					c *= spec.cloth_color if x < w / 2 else spec.stripe_color
				elif x == w - 1:
					c = c.darkened(0.8)
				img.set_pixel(x, y, Color(c, 1.0))
		img.generate_mipmaps()
		var tex := N64Texture.new()
		tex.set_image(img)
		tex.category = &"fabric"
		tex.usage = N64TextureConverter.Usage.SURFACE
		tex.tiling = N64TextureConverter.Tiling.SEAMLESS
		tex.format = N64TextureConverter.Format.RGBA16
		tex.texture_size = Vector2i(w, h)
		tex.world_size = metres.x
		DirAccess.make_dir_recursive_absolute(CLOTH_DIR)
		if ResourceSaver.save(tex, path) == OK:
			tex.take_over_path(path)
			if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
				Engine.get_singleton(&"EditorInterface").get_resource_filesystem().update_file(path)
		out[kind] = tex
	return out


## Shutter planks for `spec`, made (and saved under CLOTH_DIR) the first time: the eave wood
## in vertical boards PLANK_WIDTH wide, each a little lighter or darker, a dark seam between
## them. One repeat covers a metre (u along the opening, v down it).
const PLANK_WIDTH := 0.25

static func plank_texture(spec: HouseSpec) -> Texture2D:
	var base := spec.eave_texture.resource_path.get_file().get_basename() if spec.eave_texture else "plain"
	var path := "%s/planks_%s.res" % [CLOTH_DIR, base]
	if ResourceLoader.exists(path):
		return load(path)
	var src := _cloth_source(spec.eave_texture)
	var size := maxi(8, roundi(N64Texture.texels_per_metre()))
	var per := maxi(2, roundi(size * PLANK_WIDTH))
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var c := src.get_pixel(x % src.get_width(), y % src.get_height())
			var plank := x / per
			c = c.lightened(0.08) if plank % 3 == 1 else (c.darkened(0.1) if plank % 3 == 2 else c)
			if x % per == per - 1:
				c = c.darkened(0.7)
			img.set_pixel(x, y, Color(c, 1.0))
	img.generate_mipmaps()
	var tex := N64Texture.new()
	tex.set_image(img)
	tex.category = &"wood"
	tex.usage = N64TextureConverter.Usage.SURFACE
	tex.tiling = N64TextureConverter.Tiling.SEAMLESS
	tex.format = N64TextureConverter.Format.RGBA16
	tex.texture_size = Vector2i(size, size)
	tex.world_size = 1.0
	DirAccess.make_dir_recursive_absolute(CLOTH_DIR)
	if ResourceSaver.save(tex, path) == OK:
		tex.take_over_path(path)
		if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
			Engine.get_singleton(&"EditorInterface").get_resource_filesystem().update_file(path)
	return tex


## The cloth texture's pixels (RGBA8; plain white without one).
static func _cloth_source(tex: Texture2D) -> Image:
	var img := tex.get_image() if tex else null
	if img == null:
		img = Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		return img
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	return img


## A box from `lo` to `hi` (faces facing `skip` left out: against a wall / the ground).
static func _block(out: Array, lo: Vector3, hi: Vector3, tex: Texture2D, color: Color, skip: Array) -> void:
	var c := [
		[[Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)], Vector3.UP],
		[[Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z)], Vector3.DOWN],
		[[Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)], Vector3.BACK],
		[[Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z)], Vector3.FORWARD],
		[[Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, hi.y, lo.z)], Vector3.LEFT],
		[[Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z)], Vector3.RIGHT],
	]
	for f in c:
		if not f[1] in skip:
			_face(out, f[0], f[1], tex, color, "")


## Ridge along X: two slopes over the front and back, gable ends at the left and right
## (overhanging them by ol / or_: none where a neighbour joins).
static func _gable(out: Array, spec: HouseSpec, hw: float, hd: float, top: float, tan_p: float, lift: float, o: float,
		ol: float, or_: float) -> void:
	var ridge := top + hd * tan_p
	var eave := top - o * tan_p
	var x0 := -hw - ol
	var x1 := hw + or_
	for sg in [1.0, -1.0]:
		var z_eave: float = sg * (hd + o)
		var up := Vector3(0, 1, sg * tan_p).normalized()
		var lo := [Vector3(x0, eave, z_eave), Vector3(x1, eave, z_eave), Vector3(x1, ridge, 0), Vector3(x0, ridge, 0)]
		var hi := []
		for p: Vector3 in lo:
			hi.append(p + Vector3(0, lift, 0))
		_face(out, hi, up, spec.roof_texture, spec.roof_color, "", LevelBrush.LOD_ALWAYS)
		_face(out, lo, -up, spec.eave_texture, spec.eave_color, "", LevelBrush.LOD_ALWAYS)
		# Fascia along the eave, verges at the gable ends.
		_face(out, [lo[0], lo[1], hi[1], hi[0]], Vector3(0, 0, sg), spec.eave_texture, spec.eave_color, "", LevelBrush.LOD_ALWAYS)
		_face(out, [lo[1], lo[2], hi[2], hi[1]], Vector3.RIGHT, spec.eave_texture, spec.eave_color, "", LevelBrush.LOD_ALWAYS)
		_face(out, [lo[3], lo[0], hi[0], hi[3]], Vector3.LEFT, spec.eave_texture, spec.eave_color, "", LevelBrush.LOD_ALWAYS)
	# Gable triangles above the end walls, up to the roof's underside.
	for sx in [1.0, -1.0]:
		var x: float = sx * hw
		_face(out, [Vector3(x, top, hd), Vector3(x, top, -hd), Vector3(x, ridge, 0)], Vector3(sx, 0, 0),
			spec.wall_texture, spec.wall_color, "gable_%s" % ("right" if sx > 0 else "left"), LevelBrush.LOD_ALWAYS)


## Four slopes: a ridge along the longer side (a point on a square footprint), hips down to
## the corners.
static func _hip(out: Array, spec: HouseSpec, hw: float, hd: float, top: float, tan_p: float, lift: float, o: float) -> void:
	var along_x := hw >= hd
	# Work in a frame where the ridge runs along a (long half `la`, short half `lb`).
	var la := hw if along_x else hd
	var lb := hd if along_x else hw
	var to3 := func(a: float, y: float, b: float) -> Vector3:
		return Vector3(a, y, b) if along_x else Vector3(b, y, a)
	var ridge_y := top + lb * tan_p
	var eave := top - o * tan_p
	var ra := la - lb  # half the ridge's length
	var ea := la + o
	var eb := lb + o
	var lo_ridge := [to3.call(-ra, ridge_y, 0.0), to3.call(ra, ridge_y, 0.0)]
	var corner := func(sa: float, sb: float) -> Vector3:
		return to3.call(sa * ea, eave, sb * eb)
	var planes := []  # [points (low), outward-ish normal]
	for sb in [1.0, -1.0]:
		var n: Vector3 = to3.call(0.0, 1.0, sb * tan_p)
		var pts := [corner.call(-1.0, sb), corner.call(1.0, sb), lo_ridge[1], lo_ridge[0]]
		if ra < 0.001:
			pts = [corner.call(-1.0, sb), corner.call(1.0, sb), lo_ridge[1]]
		planes.append([pts, n.normalized()])
	for sa in [1.0, -1.0]:
		var n: Vector3 = to3.call(sa * tan_p, 1.0, 0.0)
		planes.append([[corner.call(sa, 1.0), corner.call(sa, -1.0), lo_ridge[1] if sa > 0 else lo_ridge[0]], n.normalized()])
	for pl in planes:
		var lo: Array = pl[0]
		var n: Vector3 = pl[1]
		var hi := []
		for p: Vector3 in lo:
			hi.append(p + Vector3(0, lift, 0))
		_face(out, hi, n, spec.roof_texture, spec.roof_color, "", LevelBrush.LOD_ALWAYS)
		_face(out, lo, -n, spec.eave_texture, spec.eave_color, "", LevelBrush.LOD_ALWAYS)
	# Fascia all round the eaves.
	var ring := [corner.call(-1.0, 1.0), corner.call(1.0, 1.0), corner.call(1.0, -1.0), corner.call(-1.0, -1.0)]
	for i in 4:
		var p: Vector3 = ring[i]
		var q: Vector3 = ring[(i + 1) % 4]
		var mid := (p + q) * 0.5
		var n := Vector3(mid.x, 0, mid.z).normalized()
		_face(out, [p, q, q + Vector3(0, lift, 0), p + Vector3(0, lift, 0)], n, spec.eave_texture, spec.eave_color, "", LevelBrush.LOD_ALWAYS)


## `uv` (optional): each corner's UV in metres (else projected).
static func _face(out: Array, pts: Array, normal: Vector3, tex: Texture2D, color: Color, band: String,
		lod := LevelBrush.LOD_NEAR, uv := []) -> void:
	var p := pts.duplicate()
	var q := uv.duplicate()
	if _newell(p).dot(normal) < 0.0:
		p.reverse()
		q.reverse()
	var f := {pts = p, normal = normal, texture = tex, color = color, band = band, lod = lod}
	if not q.is_empty():
		f.uv = PackedVector2Array(q)
	out.append(f)


static func _newell(pts: Array) -> Vector3:
	var n := Vector3.ZERO
	for i in pts.size():
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[(i + 1) % pts.size()]
		n += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
	return n
