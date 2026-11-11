@tool
class_name GrassBuilder
## Builds a level's grass (GrassSettings) as plain nodes under its LevelRoot: per 16 m
## tile, a MeshInstance3D of grass mat and two MultiMeshInstance3Ds of tufts (near crossed
## tufts, far cards; n64_grass_* shaders in n64_runtime, so they ship as they are).
##   Mat: a grid of `cell` metres over the upward grass faces (GrassSettings.grass_textures
##   or Grass-sound faces), each quarter cell kept where a ray from above meets that grass
##   first (walls, houses, the track cut it); the outline then smoothed (rounded corners,
##   filled inside corners, frayed edges), raised `height` +- lumps, with a skirt down to
##   the ground in a darker shade. Plus a GrassField node (where the carpet is, for the
##   player's wading effect).
##   Tufts: scattered over all the open grass (mat or bare), thicker along edges and walls.

const TILE := 16.0
const MAT_SHADER := preload("res://addons/n64_runtime/shaders/n64_grass_mat.gdshader")
const TUFT_SHADER := preload("res://addons/n64_runtime/shaders/n64_grass_tuft.gdshader")
const BIN := 4.0
const FIELD_SCRIPT := "res://game/world/grass_field.gd"
## Carpet outline: how close to a grid point it snaps onto it (share of a step: no
## slivers), and how far simplifying may move it (metres).
const SNAP := 0.25
const OUTLINE_TOLERANCE := 0.06


## The grass nodes for `root` (not yet in the tree; level-local transforms).
static func build(root: LevelRoot, s: GrassSettings) -> Array[Node3D]:
	var out: Array[Node3D] = []
	if s == null or not s.enabled or root.data == null:
		return out
	# Ground triangles (level space), binned in XZ for height lookups: the grass faces, and
	# with painted carpet every upward face (carpet can be painted on any ground).
	var painting := s.paint_map != null
	var bins := {}
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var top := -INF
	var grass_brushes := {}
	for brush in root.data.brushes:
		if brush == null or brush.is_prop() or brush.is_fence() or brush.is_rope() or brush.house or brush.passage or brush.door or brush.window:
			continue
		if brush.bake_mode == LevelBrush.BakeMode.COLLISION_ONLY:
			continue
		var xf := brush.transform
		var faces := brush.get_faces()
		var grassy := {}  # face -> whether it's grass (else ground the carpet can be painted on)
		for f in faces.size():
			var is_grass := _is_grass(root.data, brush, f, s)
			if not is_grass and not painting:
				continue
			var ids: PackedInt32Array = faces[f]
			var pts: Array[Vector3] = []
			for i in ids:
				pts.append(xf * brush.vertices[i])
			var n := PolyUtil.newell_normal(PackedVector3Array(pts)).normalized()  # (a concave face's first corner can point it the wrong way)
			if absf(n.y) < 0.7:
				continue
			grassy[f] = is_grass
			# (Ear clipping: a face can be a large concave polygon, e.g. after a dissolve.)
			var order := PolyUtil.triangulate(PackedVector3Array(pts), n)
			for k in range(0, order.size(), 3):
				var tri := [pts[order[k]], pts[order[k + 1]], pts[order[k + 2]]]
				var tlo := Vector2(minf(tri[0].x, minf(tri[1].x, tri[2].x)), minf(tri[0].z, minf(tri[1].z, tri[2].z)))
				var thi := Vector2(maxf(tri[0].x, maxf(tri[1].x, tri[2].x)), maxf(tri[0].z, maxf(tri[1].z, tri[2].z)))
				lo = lo.min(tlo)
				hi = hi.max(thi)
				top = maxf(top, maxf(tri[0].y, maxf(tri[1].y, tri[2].y)))
				for bx in range(floori(tlo.x / BIN), floori(thi.x / BIN) + 1):
					for bz in range(floori(tlo.y / BIN), floori(thi.y / BIN) + 1):
						var key := Vector2i(bx, bz)
						if not bins.has(key):
							bins[key] = []
						bins[key].append(tri)
		if not grassy.is_empty():
			grass_brushes[brush] = grassy
	if bins.is_empty():
		return out
	if s.area.size != Vector2.ZERO:
		lo = lo.max(s.area.position)
		hi = hi.min(s.area.end)
	var c := s.cell
	var nx := int(ceil((hi.x - lo.x) / c))
	var nz := int(ceil((hi.y - lo.y) / c))
	if nx <= 0 or nz <= 0:
		return out
	var lumps := FastNoiseLite.new()
	lumps.seed = s.seed
	lumps.frequency = 1.0 / s.lump_size
	var patches := FastNoiseLite.new()
	patches.seed = s.seed + 7
	patches.frequency = 1.0 / 9.0
	# Ground height at each grid corner (INF: no grass there).
	var ground := PackedFloat32Array()
	ground.resize((nx + 1) * (nz + 1))
	for iz in nz + 1:
		for ix in nx + 1:
			ground[iz * (nx + 1) + ix] = _height(bins, lo.x + ix * c, lo.y + iz * c)
	# What's kept, by quarter cell (so cuts follow paths to half a cell without a finer
	# grid everywhere): grass under all four of the cell's corners, and at the quarter's
	# middle grass is what a ray from above meets first (nothing lying on it: a path cuts it
	# cleanly). A quarter under something tall (a wall, a house) is kept when grass shows
	# elsewhere in the cell: the mat runs on under the wall's foot, hidden, no bare strip.
	var qn := Vector2i(nx * 2, nz * 2)
	var qkeep := PackedByteArray()
	qkeep.resize(qn.x * qn.y)
	var qstat := PackedByteArray()  # per quarter: 1 open ground, 2 under something tall
	qstat.resize(qn.x * qn.y)
	var qgrass := PackedByteArray()  # per quarter: the open ground there is grass
	qgrass.resize(qn.x * qn.y)
	var hits := _HitBins.new(root)
	for iz in nz:
		for ix in nx:
			var ci := [iz * (nx + 1) + ix, iz * (nx + 1) + ix + 1, (iz + 1) * (nx + 1) + ix + 1, (iz + 1) * (nx + 1) + ix]
			if ci.any(func(i): return ground[i] == INF):
				continue
			var st := []
			var gr := []
			var any_open := false
			for q in 4:
				var qx := lo.x + (ix + 0.25 + 0.5 * (q % 2)) * c
				var qz := lo.y + (iz + 0.25 + 0.5 * (q / 2)) * c
				var qy := _height(bins, qx, qz)
				var o: Array = [0, false] if qy == INF else _open(hits, grass_brushes, Vector3(qx, top + 6.0, qz), qy)
				st.append(o[0])
				gr.append(o[1])
				any_open = any_open or (o[0] == 1 and o[1])
			for q in 4:
				var qi := (iz * 2 + q / 2) * qn.x + ix * 2 + q % 2
				qstat[qi] = st[q]
				qgrass[qi] = 1 if gr[q] else 0
				if s.auto_fill and ((st[q] == 1 and gr[q]) or (st[q] == 2 and any_open)):
					qkeep[qi] = 1
	# Mat only along buildings and walls (mat_band > 0): quarters within that distance of
	# something tall. Distance in quarters, spreading out from the tall ones.
	var qdist := PackedInt32Array()
	qdist.resize(qn.x * qn.y)
	qdist.fill(1 << 20)
	var front: Array[int] = []
	for i in qstat.size():
		if qstat[i] == 2:
			qdist[i] = 0
			front.append(i)
	while not front.is_empty():
		var next: Array[int] = []
		for i in front:
			var x := i % qn.x
			var z := i / qn.x
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx2: int = x + d.x
				var nz2: int = z + d.y
				if nx2 < 0 or nz2 < 0 or nx2 >= qn.x or nz2 >= qn.y:
					continue
				var j := nz2 * qn.x + nx2
				if qdist[j] > qdist[i] + 1:
					qdist[j] = qdist[i] + 1
					next.append(j)
		front = next
	if s.mat_band > 0.0:
		var reach := int(ceil(s.mat_band / (c * 0.5)))
		for i in qkeep.size():
			if qkeep[i] == 1 and qdist[i] > reach:
				qkeep[i] = 0
	# Painted carpet on top: painted quarters carpet any ground (beating mat_band), erased
	# ones none.
	if painting:
		for qi in qkeep.size():
			var v := s.paint_at(lo.x + (qi % qn.x + 0.5) * c * 0.5, lo.y + (qi / qn.x + 0.5) * c * 0.5)
			if v == GrassSettings.ERASED:
				qkeep[qi] = 0
			elif v >= 2 and qstat[qi] != 0:
				qkeep[qi] = 1
	var qkept := func(qx: int, qz: int) -> bool:
		return qx >= 0 and qz >= 0 and qx < qn.x and qz < qn.y and qkeep[qz * qn.x + qx] == 1
	# The carpet's outline, smoothed: the kept quarters blurred over `round` metres plus a
	# little noise, carpet where that's over a half. Straight edges stay put, outer corners
	# round off, inside corners fill in with a curve, edges fray into small patches. Cells
	# well inside are one quad; only cells on the outline are cut finer (marching squares).
	var qh := c * 0.5
	var rad := maxf(s.round, qh * 0.5)
	var rq := int(ceil(rad / qh))
	var fray := FastNoiseLite.new()
	fray.seed = s.seed + 13
	fray.frequency = 1.0 / maxf(rad * 1.5, 0.5)
	var field := func(x: float, z: float) -> float:
		var fx := (x - lo.x) / qh - 0.5
		var fz := (z - lo.y) / qh - 0.5
		var cx := roundi(fx)
		var cz := roundi(fz)
		var sum := 0.0
		var wsum := 0.0
		for dz in range(-rq, rq + 1):
			for dx in range(-rq, rq + 1):
				var d2 := (Vector2(cx + dx, cz + dz) - Vector2(fx, fz)).length_squared() * qh * qh
				if d2 > rad * rad:
					continue
				var w := 1.0 - d2 / (rad * rad)
				wsum += w
				if qkept.call(cx + dx, cz + dz):
					sum += w
		var v := (sum / wsum if wsum > 0.0 else 0.0) + fray.get_noise_2d(x, z) * s.fray - 0.5
		# Paths and anything else lying on the ground cut it hard (rounding would close a
		# narrow path); only open grass and the feet of walls round it off.
		var ox := clampi(floori((x - lo.x) / qh), 0, qn.x - 1)
		var oz := clampi(floori((z - lo.y) / qh), 0, qn.y - 1)
		var oi := oz * qn.x + ox
		if qstat[oi] == 0 or (qstat[oi] == 1 and qgrass[oi] == 0 and qkeep[oi] == 0):
			v = minf(v, -0.3)
		return v
	var ground_at := func(x: float, z: float) -> float:
		var fx := clampf((x - lo.x) / c, 0.0, nx - 0.0001)
		var fz := clampf((z - lo.y) / c, 0.0, nz - 0.0001)
		var ix := int(fx)
		var iz := int(fz)
		var g := [ground[iz * (nx + 1) + ix], ground[iz * (nx + 1) + ix + 1], ground[(iz + 1) * (nx + 1) + ix + 1], ground[(iz + 1) * (nx + 1) + ix]]
		var avg := 0.0
		var n := 0
		for v in g:
			if v != INF:
				avg += v
				n += 1
		avg = avg / n if n > 0 else 0.0
		for k in 4:
			if g[k] == INF:
				g[k] = avg
		var u := fx - ix
		var w := fz - iz
		return lerpf(lerpf(g[0], g[1], u), lerpf(g[3], g[2], u), w)
	var top_at := func(x: float, z: float) -> float:
		var h := s.painted_height(x, z) if painting else -1.0
		if h < 0.0:
			h = s.height
		return ground_at.call(x, z) + maxf(h + lumps.get_noise_2d(x, z) * s.height_var * (h / maxf(s.height, 0.01)), 0.01)
	# Cells: 2 well inside (one quad), 1 on the outline (cut finer), 0 nothing near: the
	# field sampled at the cell's corners, edge middles and middle, clear of the outline.
	var kind := PackedByteArray()
	kind.resize(nx * nz)
	var reach := rq + 1
	for iz in nz:
		for ix in nx:
			var any := false
			for qz in range(iz * 2 - reach, iz * 2 + 2 + reach):
				for qx in range(ix * 2 - reach, ix * 2 + 2 + reach):
					if qkept.call(qx, qz):
						any = true
						break
				if any:
					break
			if not any:
				continue
			var x0 := lo.x + ix * c
			var z0 := lo.y + iz * c
			var lo_v := INF
			var hi_v := -INF
			for f in [Vector2(0, 0), Vector2(0.5, 0), Vector2(1, 0), Vector2(0, 0.5), Vector2(0.5, 0.5), Vector2(1, 0.5), Vector2(0, 1), Vector2(0.5, 1), Vector2(1, 1)]:
				var v: float = field.call(x0 + f.x * c, z0 + f.y * c)
				lo_v = minf(lo_v, v)
				hi_v = maxf(hi_v, v)
			var corners_ok := ground[iz * (nx + 1) + ix] != INF and ground[iz * (nx + 1) + ix + 1] != INF \
				and ground[(iz + 1) * (nx + 1) + ix] != INF and ground[(iz + 1) * (nx + 1) + ix + 1] != INF
			if lo_v > 0.12 and corners_ok:
				kind[iz * nx + ix] = 2
			elif hi_v > -0.12:
				kind[iz * nx + ix] = 1
	# What the carpet can butt against: houses (plinth lip and all) and solid blocks, as
	# footprints (level space: [inverse transform, half extents XZ]).
	var walls := []
	for b: LevelBrush in root.data.brushes:
		if b == null:
			continue
		if b.is_house():
			walls.append([b.transform.affine_inverse(), Vector2(b.house.width * 0.5 + b.house.foundation_lip, b.house.depth * 0.5 + b.house.foundation_lip)])
		elif BuildCull._is_solid_box(b):
			var box := b.local_aabb()
			var c3 := box.get_center()
			walls.append([(b.transform * Transform3D(Basis(), Vector3(c3.x, 0.0, c3.z))).affine_inverse(), Vector2(box.size.x * 0.5, box.size.z * 0.5)])
	var in_wall := func(p: Vector2) -> bool:
		for w in walls:
			var q: Vector3 = (w[0] as Transform3D) * Vector3(p.x, 0.0, p.y)
			if absf(q.x) <= (w[1] as Vector2).x and absf(q.z) <= (w[1] as Vector2).y:
				return true
		return false
	var kind_at := func(ix: int, iz: int) -> int:
		return kind[iz * nx + ix] if ix >= 0 and iz >= 0 and ix < nx and iz < nz else 0
	var tiles := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = s.seed
	var dark := s.color * (1.0 - s.edge_dark)
	var sub := maxi(s.detail, 1)
	# The carpet per tile (tiles aligned to the cells): its outline traced as loops on a
	# grid `sub` times finer than the cells (marching squares: the field on outline cells,
	# inside deep in, outside away), simplified, and each loop filled as one polygon with a
	# skirt down its edge. Top and skirt share every outline vertex; loops keep every vertex
	# on a tile's border so neighbouring tiles meet exactly. The top is flat between its
	# outline points (the lumps show along the edges): far fewer triangles than a grid.
	var tc := maxi(int(round(TILE / c)), 1)
	var h := c / sub
	var fn := Vector2i(nx * sub, nz * sub)
	var nodes := PackedFloat32Array()
	nodes.resize((fn.x + 1) * (fn.y + 1))
	for jz in fn.y + 1:
		for jx in fn.x + 1:
			var kmax := 0
			var all2 := true
			for cz in [(jz - 1) / sub, jz / sub]:
				for cx in [(jx - 1) / sub, jx / sub]:
					var k: int = kind_at.call(cx, cz)
					kmax = maxi(kmax, k)
					all2 = all2 and k == 2
			var v := -1.0
			if all2:
				v = 1.0
			elif kmax > 0:
				v = field.call(lo.x + jx * h, lo.y + jz * h)
			nodes[jz * (fn.x + 1) + jx] = v
	var node_at := func(jx: int, jz: int) -> float:
		return nodes[jz * (fn.x + 1) + jx]
	for tz in ceili(float(nz) / tc):
		for tx in ceili(float(nx) / tc):
			var j0 := Vector2i(tx * tc * sub, tz * tc * sub)
			var j1 := Vector2i(mini((tx + 1) * tc * sub, fn.x), mini((tz + 1) * tc * sub, fn.y))
			var border := Rect2(lo.x + j0.x * h, lo.y + j0.y * h, (j1.x - j0.x) * h, (j1.y - j0.y) * h)
			var loops := _trace(node_at, j0, j1, lo, h)
			if loops.is_empty():
				continue
			var key := Vector2i(tx, tz)
			if not tiles.has(key):
				tiles[key] = {mat = _MatBuf.new(), near = [], far = []}
			var buf: _MatBuf = tiles[key].mat
			var simple: Array[PackedVector2Array] = []
			for loop in loops:
				var sl := _simplify(loop, border, OUTLINE_TOLERANCE)
				if sl.size() >= 3:
					simple.append(sl)
			var idx0 := buf.index.size()
			_fill(buf, simple, s, top_at, ground_at, patches)
			if OS.get_environment("GRASS_FILL_CHECK") != "":
				# Points well inside the outline that no top triangle covers.
				var misses := 0
				var where := Vector2.ZERO
				for jz in range(j0.y, j1.y):
					for jx in range(j0.x, j1.x):
						if node_at.call(jx, jz) < 0.25:
							continue
						var q := lo + Vector2(jx, jz) * h + Vector2(0.01, 0.013)
						var hit := false
						for t in range(idx0, buf.index.size(), 3):
							var a3 := buf.verts[buf.index[t]]
							var b3 := buf.verts[buf.index[t + 1]]
							var c3 := buf.verts[buf.index[t + 2]]
							if Geometry2D.point_is_inside_triangle(q, Vector2(a3.x, a3.z), Vector2(b3.x, b3.z), Vector2(c3.x, c3.z)):
								hit = true
								break
						if not hit:
							misses += 1
							where = q
				if misses > 0:
					print("grass fill: %d point(s) inside the carpet not covered in tile %s, e.g. %s (%d loops)" % [misses, Vector2i(tx, tz), where, simple.size()])
			# Skirts down the outline (not along the tile's border: the next tile goes on),
			# the top rounding over first (edge_round): a quarter round out and down, from
			# the carpet's shade to the skirt's. Each corner rounds out along the average of
			# its two edges' outward ways, so neighbouring edges meet. Right against a wall
			# (a house's or block's footprint just past the whole edge) no skirt (the wall
			# hides it): the carpet's edge there goes darker instead, a soft shadowed corner.
			var fill_end := buf.verts.size()
			var walled := {}
			for loop in simple:
				var ways := _outward(loop, simple)
				var outs: Array = ways[0]
				for j in loop.size():
					var a := loop[j]
					var b := loop[(j + 1) % loop.size()]
					var past: Vector2 = ways[1][j] * WALL_PROBE
					if in_wall.call(a.lerp(b, 0.2) + past) and in_wall.call(a.lerp(b, 0.5) + past) and in_wall.call(a.lerp(b, 0.8) + past):
						walled[Vector2i(roundi(a.x * 1000.0), roundi(a.y * 1000.0))] = true
						walled[Vector2i(roundi(b.x * 1000.0), roundi(b.y * 1000.0))] = true
						continue
					if _on_border(a, b, border):
						# The next tile goes on from here, unless the carpet's own edge runs
						# along the tile's border (then this is its skirt).
						var m := (a + b) * 0.5
						var out_dir := Vector2.ZERO
						if absf(m.x - border.position.x) < 0.001:
							out_dir = Vector2.LEFT
						elif absf(m.x - border.end.x) < 0.001:
							out_dir = Vector2.RIGHT
						elif absf(m.y - border.position.y) < 0.001:
							out_dir = Vector2.UP
						else:
							out_dir = Vector2.DOWN
						var o := m + out_dir * h * 0.75  # (past the border node, never level with it)
						var jx := clampi(roundi((o.x - lo.x) / h), 0, fn.x)
						var jz := clampi(roundi((o.y - lo.y) / h), 0, fn.y)
						if node_at.call(jx, jz) >= 0.0:
							continue
					var ta := Vector3(a.x, top_at.call(a.x, a.y), a.y)
					var tb := Vector3(b.x, top_at.call(b.x, b.y), b.y)
					var ga: float = ground_at.call(a.x, a.y) - 0.02
					var gb: float = ground_at.call(b.x, b.y) - 0.02
					var u: float = (a.x + a.y) / s.tile
					var du := a.distance_to(b) / s.tile
					var oa: Vector2 = outs[j]
					var ob: Vector2 = outs[(j + 1) % loop.size()]
					# The round's radius: no more than a third of the carpet's height there.
					var ra := minf(s.edge_round, (ta.y - ga) * 0.33)
					var rb := minf(s.edge_round, (tb.y - gb) * 0.33)
					var ca := _tint(s, patches, ta)
					var cb := _tint(s, patches, tb)
					var prev := [buf.add(ta, Vector2(ta.x, ta.z) / s.tile, ca, 1.0, 0.0), buf.add(tb, Vector2(tb.x, tb.z) / s.tile, cb, 1.0, 0.0)]
					var pa := ta
					var pb := tb
					var v := 0.0
					var steps := ROUND_STEPS if s.edge_round > 0.0 else 0
					for k in range(1, steps + 1):
						var t := float(k) / steps
						var th := t * PI * 0.5
						var qa := ta + Vector3(oa.x * ra * sin(th), -ra * (1.0 - cos(th)), oa.y * ra * sin(th))
						var qb := tb + Vector3(ob.x * rb * sin(th), -rb * (1.0 - cos(th)), ob.y * rb * sin(th))
						# Shaded smooth over the round: the light falling off as it turns
						# away (1 - cos), the texture laid from above like the top's (no
						# seam where it folds over).
						var fall := 1.0 - cos(th)
						var row := [buf.add(qa, Vector2(qa.x, qa.z) / s.tile, ca.lerp(dark, fall), 1.0, 0.0),
							buf.add(qb, Vector2(qb.x, qb.z) / s.tile, cb.lerp(dark, fall), 1.0, 0.0)]
						buf.quad(prev[0], prev[1], row[1], row[0])
						prev = row
						pa = qa
						pb = qb
					# Then straight down to the ground (its texture hung down the side).
					var vh := (pa.y - ga) / s.tile
					var e0 := buf.add(pa, Vector2(u, 0.0), dark, 1.0, 0.0)
					var e1 := buf.add(pb, Vector2(u + du, 0.0), dark, 1.0, 0.0)
					var e2 := buf.add(Vector3(pb.x, gb, pb.z), Vector2(u + du, vh), dark * 0.6, 0.0, 0.0)
					var e3 := buf.add(Vector3(pa.x, ga, pa.z), Vector2(u, vh), dark * 0.6, 0.0, 0.0)
					buf.quad(e0, e1, e2, e3)
			if not walled.is_empty():
				for i in fill_end:
					var v := buf.verts[i]
					if walled.has(Vector2i(roundi(v.x * 1000.0), roundi(v.z * 1000.0))):
						buf.colors[i] = buf.colors[i] * Color(WALL_SHADE, WALL_SHADE, WALL_SHADE, 1.0)
	# Where the carpet is, for the game (GrassField: what the player wades through).
	var tops := PackedFloat32Array()
	tops.resize(qn.x * qn.y)
	for qz in qn.y:
		for qx in qn.x:
			var x := lo.x + (qx + 0.5) * qh
			var z := lo.y + (qz + 0.5) * qh
			var on: bool = kind_at.call(qx / 2, qz / 2) == 2 or (kind_at.call(qx / 2, qz / 2) == 1 and field.call(x, z) >= 0.0)
			tops[qz * qn.x + qx] = top_at.call(x, z) if on else -1e9
	var gf: Node3D = (load(FIELD_SCRIPT) as Script).new()
	gf.name = "GrassField"
	gf.set(&"origin", lo)
	gf.set(&"step", qh)
	gf.set(&"size", qn)
	gf.set(&"tops", tops)
	gf.set(&"texture", s.top_texture)
	gf.set(&"color", s.color)
	gf.set(&"tile", s.tile)
	# The carpet's top as built (its lumps), for what needs the real surface (GrassWake's
	# divot rim): the upward triangles of the top (not the skirts).
	var surface := PackedVector3Array()
	for key in tiles:
		var mb: _MatBuf = tiles[key].mat
		for t in range(0, mb.index.size(), 3):
			var i0 := mb.index[t]
			var i1 := mb.index[t + 1]
			var i2 := mb.index[t + 2]
			if mb.colors[i0].a < 0.5 or mb.colors[i1].a < 0.5 or mb.colors[i2].a < 0.5:
				continue
			var n := (mb.verts[i1] - mb.verts[i0]).cross(mb.verts[i2] - mb.verts[i0])
			if absf(n.normalized().y) < 0.6:
				continue
			surface.append_array([mb.verts[i0], mb.verts[i1], mb.verts[i2]])
	gf.set(&"surface", surface)
	out.append(gf)
	var mat_mat := ShaderMaterial.new()
	mat_mat.shader = MAT_SHADER
	mat_mat.set_shader_parameter(&"tex", s.top_texture)
	# Tufts over the open grass (on the carpet or on the bare ground beside it), thicker
	# near the carpet's outline and the feet of walls.
	for qi in qstat.size():
		if qstat[qi] != 1 or (qgrass[qi] == 0 and qkeep[qi] == 0):
			continue
		var qx := qi % qn.x
		var qz := qi / qn.x
		var ix := qx / 2
		var iz := qz / 2
		var mx := lo.x + (qx + 0.5) * qh
		var mz := lo.y + (qz + 0.5) * qh
		var fv: float = field.call(mx, mz) if kind_at.call(ix, iz) == 1 else (0.5 if kind_at.call(ix, iz) == 2 else -0.5)
		var edge: bool = qdist[qi] <= 1 or absf(fv) < 0.3
		var want := qh * qh * s.tufts * (s.edge_tufts if edge else 1.0)
		var count := int(want) + (1 if rng.randf() < want - int(want) else 0)
		for k in count:
			var x := mx + rng.randf_range(-0.5, 0.5) * qh
			var z := mz + rng.randf_range(-0.5, 0.5) * qh
			var on: bool = kind_at.call(ix, iz) == 2 or (kind_at.call(ix, iz) == 1 and field.call(x, z) >= 0.0)
			var p := Vector3(x, (top_at.call(x, z) if on else ground_at.call(x, z)) - 0.02, z)
			var key := Vector2i(clampi(floori((p.x - lo.x) / c), 0, nx - 1) / tc, clampi(floori((p.z - lo.y) / c), 0, nz - 1) / tc)
			if not tiles.has(key):
				tiles[key] = {mat = _MatBuf.new(), near = [], far = []}
			var t: Dictionary = tiles[key]
			var size := s.tuft_size * (1.0 + rng.randf_range(-s.tuft_size_var, s.tuft_size_var))
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(size * 1.1, size, size * 1.1))
			var tint := _tint(s, patches, p) * s.tuft_color * rng.randf_range(0.85, 1.12)
			t.near.append([Transform3D(basis, p), tint])
			t.far.append([Transform3D(Basis().scaled(Vector3(size * 1.1, size, 1.0)), p), tint])
	var near_mat := _tuft_material(s, 0)
	var far_mat := _tuft_material(s, 1)
	var near_mesh := _tuft_mesh(true)
	var far_mesh := _tuft_mesh(false)
	var layers := root.level_layers()
	for key in tiles:
		var t: Dictionary = tiles[key]
		if not (t.mat as _MatBuf).index.is_empty():
			var mi := MeshInstance3D.new()
			mi.name = "Grass_%d_%d" % [key.x, key.y]
			mi.mesh = (t.mat as _MatBuf).mesh(mat_mat)
			mi.layers = layers
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.extra_cull_margin = 0.2
			out.append(mi)
		if t.near.is_empty():
			continue
		var half := TILE * 0.75  # visibility ranges measure to the tile's middle
		out.append(_tufts("Tufts_%d_%d" % [key.x, key.y], near_mesh, near_mat, t.near, layers, 0.0, s.near_distance + half))
		out.append(_tufts("TuftCards_%d_%d" % [key.x, key.y], far_mesh, far_mat, t.far, layers, maxf(s.near_distance - s.fade - half, 0.0), s.far_distance + half))
	return out


## The carpet's outline in the fine-grid squares j0..j1 (node_at: the field at a node, >= 0
## inside): closed loops (level x / z), counter-clockwise round carpet, clockwise round
## holes. Each square's inside part is a small polygon; edges two of them share cancel out
## and what's left is the outline (and the tile's border, where the carpet runs on).
static func _trace(node_at: Callable, j0: Vector2i, j1: Vector2i, lo: Vector2, h: float) -> Array[PackedVector2Array]:
	var edges := {}  # start key -> [[start, end], ...]
	var pairs := {}  # "a|b" -> count (to cancel a->b with b->a)
	var add := func(a: Vector2, b: Vector2) -> void:
		var ka := _key(a)
		var kb := _key(b)
		if ka == kb:
			return
		var back := kb + "|" + ka
		if pairs.get(back, 0) > 0:
			pairs[back] -= 1
			return
		pairs[ka + "|" + kb] = pairs.get(ka + "|" + kb, 0) + 1
	var pts := {}  # key -> Vector2
	for jz in range(j0.y, j1.y):
		for jx in range(j0.x, j1.x):
			var cpos := [lo + Vector2(jx, jz) * h, lo + Vector2(jx + 1, jz) * h, lo + Vector2(jx + 1, jz + 1) * h, lo + Vector2(jx, jz + 1) * h]
			var cv: Array[float] = [node_at.call(jx, jz), node_at.call(jx + 1, jz), node_at.call(jx + 1, jz + 1), node_at.call(jx, jz + 1)]
			var inside := 0
			for v in cv:
				if v >= 0.0:
					inside += 1
			if inside == 0:
				continue
			var cross := func(j: int) -> Vector2:
				var a: float = cv[j]
				var b: float = cv[(j + 1) % 4]
				var t := a / (a - b)
				t = 0.0 if t < SNAP else (1.0 if t > 1.0 - SNAP else t)
				return (cpos[j] as Vector2).lerp(cpos[(j + 1) % 4], t)
			var polys: Array = []
			if inside == 2 and (cv[0] >= 0.0) == (cv[2] >= 0.0):
				# Saddle: joined through the middle, or two corners apart.
				var mid := (cv[0] + cv[1] + cv[2] + cv[3]) * 0.25
				var poly: Array[Vector2] = []
				if mid >= 0.0:
					for j in 4:
						if cv[j] >= 0.0:
							poly.append(cpos[j])
						if (cv[j] >= 0.0) != (cv[(j + 1) % 4] >= 0.0):
							poly.append(cross.call(j))
					polys.append(poly)
				else:
					for j in 4:
						if cv[j] >= 0.0:
							polys.append([cross.call((j + 3) % 4), cpos[j], cross.call(j)])
			else:
				var poly: Array[Vector2] = []
				for j in 4:
					if cv[j] >= 0.0:
						poly.append(cpos[j])
					if (cv[j] >= 0.0) != (cv[(j + 1) % 4] >= 0.0):
						poly.append(cross.call(j))
				polys.append(poly)
			for poly in polys:
				for j in poly.size():
					var a: Vector2 = poly[j]
					var b: Vector2 = poly[(j + 1) % poly.size()]
					pts[_key(a)] = a
					pts[_key(b)] = b
					add.call(a, b)
	# Chain what's left into loops.
	for k in pairs:
		for n in pairs[k]:
			var parts: PackedStringArray = (k as String).split("|")
			if not edges.has(parts[0]):
				edges[parts[0]] = []
			edges[parts[0]].append(parts[1])
	var loops: Array[PackedVector2Array] = []
	for start in edges.keys():
		while not edges[start].is_empty():
			var loop := PackedVector2Array()
			var at: String = start
			var guard := 0
			while guard < 100000:
				guard += 1
				loop.append(pts[at])
				var nexts: Array = edges.get(at, [])
				if nexts.is_empty():
					break
				var nxt: String = nexts.pop_back()
				at = nxt
				if at == start:
					break
			if loop.size() >= 3:
				loops.append(loop)
	return loops


static func _key(p: Vector2) -> String:
	return "%d,%d" % [roundi(p.x * 1000.0), roundi(p.y * 1000.0)]


## Whether a and b both lie on one side of `r` (the tile's border).
static func _on_border(a: Vector2, b: Vector2, r: Rect2) -> bool:
	var e := 0.0005
	return (absf(a.x - r.position.x) < e and absf(b.x - r.position.x) < e) or (absf(a.x - r.end.x) < e and absf(b.x - r.end.x) < e) \
		or (absf(a.y - r.position.y) < e and absf(b.y - r.position.y) < e) or (absf(a.y - r.end.y) < e and absf(b.y - r.end.y) < e)


static func _pinned(p: Vector2, r: Rect2) -> bool:
	var e := 0.0005
	return absf(p.x - r.position.x) < e or absf(p.x - r.end.x) < e or absf(p.y - r.position.y) < e or absf(p.y - r.end.y) < e


## A loop with points dropped where it runs straight (within `tol`), keeping every point
## on the tile's border.
static func _simplify(loop: PackedVector2Array, border: Rect2, tol: float) -> PackedVector2Array:
	var n := loop.size()
	var keep := PackedByteArray()
	keep.resize(n)
	var pins: Array[int] = []
	for i in n:
		if _pinned(loop[i], border):
			keep[i] = 1
			pins.append(i)
	if pins.size() < 2:
		# No pins: split at the point furthest from the first.
		var far := 0
		for i in n:
			if loop[i].distance_squared_to(loop[0]) > loop[far].distance_squared_to(loop[0]):
				far = i
		pins.assign([0, far] if far != 0 else [0, n / 2])
		for i in pins:
			keep[i] = 1
	for k in pins.size():
		var a := pins[k]
		var b := pins[(k + 1) % pins.size()]
		_dp(loop, a, b, tol, keep)
	var out := PackedVector2Array()
	for i in n:
		if keep[i] == 1:
			out.append(loop[i])
	return out


static func _dp(loop: PackedVector2Array, a: int, b: int, tol: float, keep: PackedByteArray) -> void:
	var n := loop.size()
	var span := (b - a + n) % n
	if span < 2:
		return
	var pa := loop[a]
	var pb := loop[b]
	var worst := -1.0
	var wi := -1
	for s in range(1, span):
		var i := (a + s) % n
		var d := Geometry2D.get_closest_point_to_segment(loop[i], pa, pb).distance_to(loop[i])
		if d > worst:
			worst = d
			wi = i
	if worst > tol:
		keep[wi] = 1
		_dp(loop, a, wi, tol, keep)
		_dp(loop, wi, b, tol, keep)


## The carpet's top: each outer loop with its holes, as one polygon (holes bridged in),
## triangulated.
static func _fill(buf: _MatBuf, loops: Array[PackedVector2Array], s: GrassSettings, top_at: Callable, ground_at: Callable, patches: FastNoiseLite) -> void:
	var outers: Array[PackedVector2Array] = []
	var holes: Array[PackedVector2Array] = []
	for l in loops:
		if Geometry2D.is_polygon_clockwise(l):
			holes.append(l)
		else:
			outers.append(l)
	if OS.get_environment("GRASS_FILL_CHECK") != "":
		for hl in holes:
			if not outers.any(func(o): return Geometry2D.is_point_in_polygon(hl[0], o)):
				print("grass fill: a 'hole' inside no outline near %s, area %.2f: never filled" % [hl[0], absf(_area2(hl))])
	for outer in outers:
		var poly := outer
		var mine: Array[PackedVector2Array] = []
		for hl in holes:
			if Geometry2D.is_point_in_polygon(hl[0], outer):
				mine.append(hl)
		mine.sort_custom(func(p, q): return _max_x(p) > _max_x(q))
		for hl in mine:
			poly = _bridge(poly, hl)
		var tri := Geometry2D.triangulate_polygon(poly)
		if OS.get_environment("GRASS_FILL_CHECK") != "":
			var want := absf(_area2(poly))
			var got := 0.0
			for t in range(0, tri.size(), 3):
				got += absf((poly[tri[t + 1]] - poly[tri[t]]).cross(poly[tri[t + 2]] - poly[tri[t]])) * 0.5
			if tri.is_empty() or absf(got - want) > 0.05 * want + 0.01:
				print("grass fill: polygon of %d points near %s: area %.2f, triangulated %.2f (%d holes)%s" % [poly.size(), poly[0], want, got, mine.size(), " EMPTY" if tri.is_empty() else ""])
		if tri.is_empty():
			tri = Geometry2D.triangulate_delaunay(poly)
			var ok := PackedInt32Array()
			for t in range(0, tri.size(), 3):
				var c := (poly[tri[t]] + poly[tri[t + 1]] + poly[tri[t + 2]]) / 3.0
				if Geometry2D.is_point_in_polygon(c, outer) and not mine.any(func(hh): return Geometry2D.is_point_in_polygon(c, hh)):
					ok.append_array([tri[t], tri[t + 1], tri[t + 2]])
			tri = ok
		var ids := PackedInt32Array()
		for p in poly:
			var y: float = top_at.call(p.x, p.y)
			var v := Vector3(p.x, y, p.y)
			ids.append(buf.add(v, p / s.tile, _tint(s, patches, v), 1.0, y - float(ground_at.call(p.x, p.y))))
		for t in range(0, tri.size(), 3):
			buf.index.append_array([ids[tri[t]], ids[tri[t + 2]], ids[tri[t + 1]]])


static func _area2(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		a += p[i].cross(p[(i + 1) % p.size()])
	return a * 0.5


static func _max_x(p: PackedVector2Array) -> float:
	var m := -INF
	for v in p:
		m = maxf(m, v.x)
	return m


## `outer` with `hole` spliced in through a cut from the hole's rightmost point to an outer
## point it can see (one polygon to triangulate).
static func _bridge(outer: PackedVector2Array, hole: PackedVector2Array) -> PackedVector2Array:
	var hi := 0
	for i in hole.size():
		if hole[i].x > hole[hi].x:
			hi = i
	var hp := hole[hi]
	var best := -1
	var best_d := INF
	for i in outer.size():
		var d := outer[i].distance_squared_to(hp)
		if d >= best_d or outer[i].x < hp.x - 0.001:
			continue
		var clear := true
		for j in outer.size():
			var a := outer[j]
			var b := outer[(j + 1) % outer.size()]
			if j == i or (j + 1) % outer.size() == i:
				continue
			if Geometry2D.segment_intersects_segment(hp, outer[i], a, b) != null:
				clear = false
				break
		if clear:
			best = i
			best_d = d
	if best < 0:
		for i in outer.size():
			if outer[i].distance_squared_to(hp) < best_d:
				best = i
				best_d = outer[i].distance_squared_to(hp)
	var out := PackedVector2Array()
	for i in best + 1:
		out.append(outer[i])
	for k in hole.size() + 1:
		out.append(hole[(hi + k) % hole.size()])
	for i in range(best, outer.size()):
		out.append(outer[i])
	return out


## What's at a spot (`from`: above it, level space; ground at `gy`): [1 open ground, 2 under
## something tall (a wall, a house: hides the mat's edge) or 0 anything else, whether the
## open ground is grass].
static func _open(hits: _HitBins, grass_brushes: Dictionary, from: Vector3, gy: float) -> Array:
	var hit := hits.down(from)
	if hit.is_empty():
		return [0, false]
	var hy: float = (hit.position as Vector3).y
	if absf(hy - gy) <= 0.03 and grass_brushes.has(hit.brush) and grass_brushes[hit.brush].has(hit.face):
		return [1, grass_brushes[hit.brush][hit.face]]
	return [2 if hy - gy > 0.4 else 0, false]


static func _is_grass(data: LevelData, brush: LevelBrush, f: int, s: GrassSettings) -> bool:
	if (brush.get_face_surface(f) & 0xFF) == Surface.Sound.GRASS:
		return true
	var ti := brush.get_face_texture(f)
	if ti < 0 or ti >= data.textures.size() or data.textures[ti] == null:
		return false
	var tex := data.textures[ti]
	if s.grass_textures.is_empty():
		return tex.resource_path.begins_with("res://textures/grass/")
	return tex in s.grass_textures


## Ground height at (x, z) on the grass triangles (the highest there), INF if none.
static func _height(bins: Dictionary, x: float, z: float) -> float:
	var key := Vector2i(floori(x / BIN), floori(z / BIN))
	if not bins.has(key):
		return INF
	var best := INF
	var p := Vector2(x, z)
	for tri in bins[key]:
		var a := Vector2(tri[0].x, tri[0].z)
		var b := Vector2(tri[1].x, tri[1].z)
		var cc := Vector2(tri[2].x, tri[2].z)
		var d := (b - a).cross(cc - a)
		if absf(d) < 1e-6:
			continue
		var u := (p - a).cross(cc - a) / d
		var v := (b - a).cross(p - a) / d
		if u < -1e-4 or v < -1e-4 or u + v > 1.0 + 1e-4:
			continue
		var y: float = tri[0].y + (tri[1].y - tri[0].y) * u + (tri[2].y - tri[0].y) * v
		best = y if best == INF else maxf(best, y)
	return best


static func _tint(s: GrassSettings, patches: FastNoiseLite, p: Vector3) -> Color:
	var k := 1.0 + patches.get_noise_2d(p.x, p.z) * s.patchiness * 0.6
	return Color(s.color.r * k, s.color.g * k, s.color.b * k)


static func _tuft_material(s: GrassSettings, level: int) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = TUFT_SHADER
	m.set_shader_parameter(&"tex", s.tuft_texture)
	m.set_shader_parameter(&"level", level)
	m.set_shader_parameter(&"near_end", s.near_distance)
	m.set_shader_parameter(&"far_end", s.far_distance)
	m.set_shader_parameter(&"fade", s.fade)
	return m


## Near: two quads crossed (4 triangles); far: one (2, turned to the camera in the shader).
## Unit size, origin at the root, UV.y 1 at the root.
static func _tuft_mesh(crossed: bool) -> ArrayMesh:
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for k in (2 if crossed else 1):
		var r := Vector3.RIGHT.rotated(Vector3.UP, PI * 0.5 * k) * 0.5
		var b := v.size()
		v.append_array([-r + Vector3.UP, r + Vector3.UP, r, -r])
		uv.append_array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
		idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = v
	a[Mesh.ARRAY_TEX_UV] = uv
	a[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	return m


static func _tufts(name: String, mesh: Mesh, mat: Material, items: Array, layers: int, begin: float, end: float) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = items.size()
	for i in items.size():
		mm.set_instance_transform(i, items[i][0])
		mm.set_instance_color(i, items[i][1])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = name
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.layers = layers
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = 1.0
	mmi.visibility_range_begin = begin
	mmi.visibility_range_end = end
	return mmi


## Straight-down rays against the level's brushes (level space): every face cut into
## triangles binned by XZ, so a ray tests only the few under it (LevelRoot.raycast tries
## every triangle of every brush). Fences, ropes, props (only pick boxes) and collision-only
## brushes are left out: they don't cut grass.
class _HitBins:
	const SIZE := 4.0
	var bins := {}

	func _init(root: LevelRoot) -> void:
		for brush in root.data.brushes:
			if brush == null or brush.is_fence() or brush.is_rope() or String(brush.tag).begins_with("fence_"):
				continue
			# Props are only pick boxes; collision-only brushes aren't seen.
			if brush.is_prop() or brush.bake_mode == LevelBrush.BakeMode.COLLISION_ONLY:
				continue
			var faces := brush.get_faces()
			for f in faces.size():
				var ids: PackedInt32Array = faces[f]
				if ids.size() < 3:
					continue
				var pts := PackedVector3Array()
				for i in ids:
					pts.append(brush.transform * brush.vertices[i])
				var order := PolyUtil.triangulate(pts, PolyUtil.newell_normal(pts).normalized())
				for k in range(0, order.size(), 3):
					var a := pts[order[k]]
					var b := pts[order[k + 1]]
					var c := pts[order[k + 2]]
					if absf((b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x)) < 1e-6:
						continue  # edge-on from above (a wall's side)
					var tri := [a, b, c, brush, f]
					for bx in range(floori(minf(a.x, minf(b.x, c.x)) / SIZE), floori(maxf(a.x, maxf(b.x, c.x)) / SIZE) + 1):
						for bz in range(floori(minf(a.z, minf(b.z, c.z)) / SIZE), floori(maxf(a.z, maxf(b.z, c.z)) / SIZE) + 1):
							var key := Vector2i(bx, bz)
							if not bins.has(key):
								bins[key] = []
							bins[key].append(tri)

	## Nearest surface straight down from `from`: {brush, face, position} or {}.
	func down(from: Vector3) -> Dictionary:
		var best := {}
		var best_y := -INF
		var p := Vector2(from.x, from.z)
		for tri in bins.get(Vector2i(floori(from.x / SIZE), floori(from.z / SIZE)), []):
			var a := Vector2(tri[0].x, tri[0].z)
			var b := Vector2(tri[1].x, tri[1].z)
			var c := Vector2(tri[2].x, tri[2].z)
			var d := (b - a).cross(c - a)
			var u := (p - a).cross(c - a) / d
			var v := (b - a).cross(p - a) / d
			if u < -1e-4 or v < -1e-4 or u + v > 1.0 + 1e-4:
				continue
			var y: float = tri[0].y + (tri[1].y - tri[0].y) * u + (tri[2].y - tri[0].y) * v
			if y <= from.y and y > best_y:
				best_y = y
				best = {brush = tri[3], face = tri[4], position = Vector3(from.x, y, from.z)}
		return best


## Segments in the quarter round at the carpet's edge.
const ROUND_STEPS := 2
## How far out past an outline edge a wall must stand (metres: along the whole edge, inside a
## house's or block's footprint) for the edge to go without its skirt, and the carpet's
## shade where it meets one.
const WALL_PROBE := 0.08
const WALL_SHADE := 0.62


## Each corner of `loop`'s way out of the carpet (XZ, unit): the average of its two edges'
## outward normals, an edge's outside being the side away from the carpet (`loops`: all the
## tile's outline loops, holes too, the carpet inside them by even-odd).
## Returns [corner ways, edge ways] (edge j from corner j to j + 1).
static func _outward(loop: PackedVector2Array, loops: Array) -> Array:
	var n := loop.size()
	var edge_out := []
	for j in n:
		var a := loop[j]
		var b := loop[(j + 1) % n]
		var d := (b - a).normalized()
		var side := Vector2(d.y, -d.x)
		if _inside(loops, (a + b) * 0.5 + side * 0.02):
			side = -side
		edge_out.append(side)
	var out := []
	for j in n:
		var o: Vector2 = edge_out[(j - 1 + n) % n] + edge_out[j]
		out.append(o.normalized() if o.length() > 0.001 else edge_out[j])
	return [out, edge_out]


static func _inside(loops: Array, p: Vector2) -> bool:
	var inside := false
	for loop: PackedVector2Array in loops:
		var n := loop.size()
		for i in n:
			var a := loop[i]
			var b := loop[(i + 1) % n]
			if (a.y > p.y) != (b.y > p.y) and p.x < a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x):
				inside = not inside
	return inside


class _MatBuf:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var colors := PackedColorArray()
	var index := PackedInt32Array()

	func add(p: Vector3, uv: Vector2, c: Color, move: float, h: float) -> int:
		verts.append(p)
		uvs.append(uv)
		uv2.append(Vector2(h, 0.0))
		colors.append(Color(c.r, c.g, c.b, move))
		return verts.size() - 1

	func quad(a: int, b: int, c: int, d: int) -> void:
		index.append_array([a, b, c, a, c, d])

	func mesh(material: Material) -> ArrayMesh:
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = verts
		a[Mesh.ARRAY_TEX_UV] = uvs
		a[Mesh.ARRAY_TEX_UV2] = uv2
		a[Mesh.ARRAY_COLOR] = colors
		a[Mesh.ARRAY_INDEX] = index
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		m.surface_set_material(0, material)
		return m
