class_name BrushOps
extends RefCounted
## Topology operations on brush geometry. Faces are vertex-index loops wound CCW
## around their outward normal; operations return new data and never mutate inputs.


static func unpack_faces(indices: PackedInt32Array, counts: PackedInt32Array) -> Array[PackedInt32Array]:
	var faces: Array[PackedInt32Array] = []
	var s := 0
	for c in counts:
		faces.append(indices.slice(s, s + c))
		s += c
	return faces


## Returns [face_indices, face_counts].
static func pack_faces(faces: Array[PackedInt32Array]) -> Array:
	var indices := PackedInt32Array()
	var counts := PackedInt32Array()
	for f in faces:
		indices.append_array(f)
		counts.append(f.size())
	return [indices, counts]


## Extrudes a face region. Boundary vertices are duplicated and joined to the
## original boundary with side quads; returns {verts, faces, moved, map} where `moved`
## are the region's vertices to translate afterwards and map[new_face] = source face.
static func extrude_faces(verts: PackedVector3Array, faces: Array[PackedInt32Array], selected: Array[int]) -> Dictionary:
	var directed := {}
	for f in selected:
		var poly := faces[f]
		for k in poly.size():
			directed[Vector2i(poly[k], poly[(k + 1) % poly.size()])] = f
	var boundary: Array[Vector2i] = []
	for e: Vector2i in directed:
		if not directed.has(Vector2i(e.y, e.x)):
			boundary.append(e)

	var out_verts := verts.duplicate()
	var dup := {}
	for e in boundary:
		for v in [e.x, e.y]:
			if not dup.has(v):
				dup[v] = out_verts.size()
				out_verts.append(verts[v])

	var out_faces := faces.duplicate()
	var moved: Array[int] = []
	for f in selected:
		var poly := faces[f].duplicate()
		for k in poly.size():
			poly[k] = dup.get(poly[k], poly[k])
			if not poly[k] in moved:
				moved.append(poly[k])
		out_faces[f] = poly
	var sources := PackedInt32Array()
	for e in boundary:
		out_faces.append(PackedInt32Array([e.x, e.y, dup[e.y], dup[e.x]]))
		sources.append(directed[e])
	return {verts = out_verts, faces = out_faces, moved = moved, map = _extend_map(faces.size(), sources),
		vertex_map = _vertex_map(verts.size(), dup)}


## Extrudes open (boundary) edges into new quads continuing their face.
## Edges used by two faces are skipped, unless `prefer` (edge (min, max) -> face) names the
## face to continue (a lip off a closed mesh). Returns {verts, faces, moved, new_edges, map}.
static func extrude_edges(verts: PackedVector3Array, faces: Array[PackedInt32Array], edges: Array[Vector2i], prefer := {}) -> Dictionary:
	var used := {}
	for f in faces.size():
		var poly := faces[f]
		for k in poly.size():
			used[Vector2i(poly[k], poly[(k + 1) % poly.size()])] = f
	var out_verts := verts.duplicate()
	var out_faces := faces.duplicate()
	var dup := {}
	var moved: Array[int] = []
	var new_edges: Array[Vector2i] = []
	var sources := PackedInt32Array()
	for e in edges:
		var d: Vector2i
		if used.has(e) and not used.has(Vector2i(e.y, e.x)):
			d = e
		elif used.has(Vector2i(e.y, e.x)) and not used.has(e):
			d = Vector2i(e.y, e.x)
		elif prefer.has(Vector2i(mini(e.x, e.y), maxi(e.x, e.y))):
			var f: int = prefer[Vector2i(mini(e.x, e.y), maxi(e.x, e.y))]
			if used.get(e, -1) == f:
				d = e
			elif used.get(Vector2i(e.y, e.x), -1) == f:
				d = Vector2i(e.y, e.x)
			else:
				continue
		else:
			continue
		for v in [d.x, d.y]:
			if not dup.has(v):
				dup[v] = out_verts.size()
				out_verts.append(verts[v])
				moved.append(dup[v])
		out_faces.append(PackedInt32Array([d.y, d.x, dup[d.x], dup[d.y]]))
		new_edges.append(Vector2i(mini(dup[d.x], dup[d.y]), maxi(dup[d.x], dup[d.y])))
		sources.append(used[d])
	return {verts = out_verts, faces = out_faces, moved = moved, new_edges = new_edges,
		map = _extend_map(faces.size(), sources), vertex_map = _vertex_map(verts.size(), dup)}


## Which edges an outward extrude (Shift+E) grows, and which way. `sel`: selected vertex
## set; `edges`: picked edges (Edge mode) or [] to use every edge between selected
## vertices, skipping ones inside a selected region (`region`). Each edge extends one face:
## its only face on an open border; on a closed mesh a fully selected neighbour, else the
## neighbour nearest the selection's middle (a loop round a box's top extends the top).
## Returns {inside (edge (min, max) -> face), outward (edge -> unit direction in that
## face's plane, away from it)}.
static func outward_plan(verts: PackedVector3Array, faces: Array[PackedInt32Array], sel: Dictionary, edges: Array, region: bool) -> Dictionary:
	var middle := Vector3.ZERO
	for v in sel:
		middle += verts[v]
	middle /= maxf(sel.size(), 1)
	var full := {}  # faces with every vertex selected
	var centres: Array[Vector3] = []
	var edge_faces := {}  # edge (min, max) -> faces using it
	for f in faces.size():
		var poly := faces[f]
		var c := Vector3.ZERO
		var all := true
		for k in poly.size():
			c += verts[poly[k]]
			all = all and sel.has(poly[k])
			var e := Vector2i(mini(poly[k], poly[(k + 1) % poly.size()]), maxi(poly[k], poly[(k + 1) % poly.size()]))
			if not edge_faces.has(e):
				edge_faces[e] = []
			edge_faces[e].append(f)
		centres.append(c / maxf(poly.size(), 1))
		if all:
			full[f] = true
	var candidates: Array = edges.map(func(e): return Vector2i(mini(e.x, e.y), maxi(e.x, e.y))) if not edges.is_empty() \
		else edge_faces.keys().filter(func(e): return sel.has(e.x) and sel.has(e.y))
	var inside := {}
	var outward := {}
	for e in candidates:
		var fs: Array = edge_faces.get(e, [])
		if fs.is_empty():
			continue
		var fully := fs.filter(func(f): return full.has(f))
		if region and fully.size() >= 2:
			continue
		var pick: int = fully[0] if fully.size() == 1 else fs[0]
		if fully.size() != 1:
			for f in fs:
				if centres[f].distance_squared_to(middle) < centres[pick].distance_squared_to(middle):
					pick = f
		var pts := PackedVector3Array()
		for i in faces[pick]:
			pts.append(verts[i])
		var n := (verts[e.y] - verts[e.x]).cross(PolyUtil.newell_normal(pts))
		if n.dot((verts[e.x] + verts[e.y]) * 0.5 - centres[pick]) < 0.0:
			n = -n
		if n.length_squared() < 1e-12:
			continue
		inside[e] = pick
		outward[e] = n.normalized()
	return {inside = inside, outward = outward}


## Merges vertices closer than `eps` and points faces at the survivors. Returns {verts, faces}.
static func weld_vertices(verts: PackedVector3Array, faces: Array[PackedInt32Array], eps := 1e-4) -> Dictionary:
	var keep := {}
	var remap := PackedInt32Array()
	var out_verts := PackedVector3Array()
	for v in verts:
		var key := (v / eps).round()
		if not keep.has(key):
			keep[key] = out_verts.size()
			out_verts.append(v)
		remap.append(keep[key])
	var out_faces: Array[PackedInt32Array] = []
	for poly in faces:
		var np := PackedInt32Array()
		for i in poly:
			np.append(remap[i])
		out_faces.append(np)
	return {verts = out_verts, faces = out_faces}


## Open (boundary) edges whose two vertices are both in `selected`: what a vertex-mode
## extrude grows into walls (interior edges would only make fins).
static func boundary_edges_among(faces: Array[PackedInt32Array], selected: Array[int]) -> Array[Vector2i]:
	var sel := {}
	for v in selected:
		sel[v] = true
	var directed := {}
	for poly in faces:
		for k in poly.size():
			directed[Vector2i(poly[k], poly[(k + 1) % poly.size()])] = true
	var out: Array[Vector2i] = []
	for e in directed:
		if sel.has(e.x) and sel.has(e.y) and not directed.has(Vector2i(e.y, e.x)):
			out.append(Vector2i(mini(e.x, e.y), maxi(e.x, e.y)))
	return out


## New face through `selected` vertices (Blender's F). If they form one loop of open
## edges (e.g. the top of extruded walls), the loop order is used, wound opposite to the
## neighbouring faces so the mesh stays consistent. Otherwise they are ordered around
## their centre and the face is turned towards `toward` (local direction to the viewer).
## Returns {faces, map, face} or {error}.
static func make_face(verts: PackedVector3Array, faces: Array[PackedInt32Array], selected: Array[int], toward: Vector3) -> Dictionary:
	var uniq: Array[int] = []
	for v in selected:
		if not v in uniq:
			uniq.append(v)
	if uniq.size() < 3:
		return {error = "select at least 3 vertices"}
	var key := uniq.duplicate()
	key.sort()
	for poly in faces:
		var pk := Array(poly)
		pk.sort()
		if pk == key:
			return {error = "a face already uses exactly these vertices"}

	var directed := {}
	var owner := {}
	for f in faces.size():
		var poly := faces[f]
		for k in poly.size():
			var e := Vector2i(poly[k], poly[(k + 1) % poly.size()])
			directed[e] = true
			owner[e] = f
	var sel := {}
	for v in uniq:
		sel[v] = true
	# Open edges among the selection, reversed (the new face runs against its neighbours).
	var next := {}
	var ok := true
	for e in directed:
		if sel.has(e.x) and sel.has(e.y) and not directed.has(Vector2i(e.y, e.x)):
			if next.has(e.y):
				ok = false
			next[e.y] = e.x
	var order := PackedInt32Array()
	if ok and next.size() == uniq.size():
		var v: int = uniq[0]
		for i in uniq.size():
			order.append(v)
			v = next.get(v, -1)
			if v == -1:
				break
		if order.size() != uniq.size() or v != uniq[0]:
			order.clear()
	if order.is_empty():
		var c := Vector3.ZERO
		for v in uniq:
			c += verts[v]
		c /= uniq.size()
		var n := toward.normalized() if toward.length_squared() > 1e-8 else Vector3.UP
		var u := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
		var w := n.cross(u)
		var sorted := uniq.duplicate()
		sorted.sort_custom(func(a, b):
			var da := verts[a] - c
			var db := verts[b] - c
			return atan2(da.dot(w), da.dot(u)) < atan2(db.dot(w), db.dot(u)))
		order = PackedInt32Array(sorted)
		var pts := PackedVector3Array()
		for v in order:
			pts.append(verts[v])
		if PolyUtil.newell_normal(pts).dot(toward) < 0.0:
			order.reverse()
	# Inherit texture / UV from the edge-sharing neighbour facing most nearly the same way
	# (a wall patch takes the wall's texture, not the floor's it also touches).
	var new_pts := PackedVector3Array()
	for v in order:
		new_pts.append(verts[v])
	var new_n := PolyUtil.newell_normal(new_pts).normalized()
	var source := -1
	var best := -INF
	for k in order.size():
		var e := Vector2i(order[(k + 1) % order.size()], order[k])
		if not owner.has(e):
			continue
		var f: int = owner[e]
		var pts := PackedVector3Array()
		for v in faces[f]:
			pts.append(verts[v])
		var score := PolyUtil.newell_normal(pts).normalized().dot(new_n)
		if score > best:
			best = score
			source = f
	var out_faces := faces.duplicate()
	out_faces.append(order)
	var map := PackedInt32Array()
	for f in faces.size():
		map.append(f)
	map.append(source)
	return {faces = out_faces, map = map, face = faces.size()}


## Outward in-plane direction of a boundary edge (local space), or ZERO if not boundary.
static func boundary_edge_outward(verts: PackedVector3Array, faces: Array[PackedInt32Array], edge: Vector2i) -> Vector3:
	for poly in faces:
		for k in poly.size():
			var a := poly[k]
			var b := poly[(k + 1) % poly.size()]
			if Vector2i(a, b) == edge or Vector2i(b, a) == edge:
				var pts := PackedVector3Array()
				for i in poly:
					pts.append(verts[i])
				return (verts[b] - verts[a]).cross(PolyUtil.newell_normal(pts)).normalized()
	return Vector3.ZERO


## Splits each selected face into quads around a new centre vertex, through new edge
## midpoints (a quad becomes 4 quads, an n-gon n quads). Unselected neighbours get the
## split-edge midpoints inserted so no T-junction cracks open.
## Returns {verts, faces, map (new face -> source face), vertex_sources (per new vertex:
## the original vertices it averages), selected (the new child faces)}.
static func subdivide_faces(verts: PackedVector3Array, faces: Array[PackedInt32Array], selected: Array[int]) -> Dictionary:
	var out_verts := verts.duplicate()
	var sources: Array[PackedInt32Array] = []
	for i in verts.size():
		sources.append(PackedInt32Array([i]))
	var mids := {}
	for f in selected:
		var poly := faces[f]
		for k in poly.size():
			var a := poly[k]
			var b := poly[(k + 1) % poly.size()]
			var e := Vector2i(mini(a, b), maxi(a, b))
			if not mids.has(e):
				mids[e] = out_verts.size()
				out_verts.append((verts[a] + verts[b]) * 0.5)
				sources.append(PackedInt32Array([a, b]))
	var out_faces: Array[PackedInt32Array] = []
	var map := PackedInt32Array()
	var children: Array[int] = []
	for f in faces.size():
		var poly := faces[f]
		var n := poly.size()
		if f in selected:
			var centre := Vector3.ZERO
			for i in poly:
				centre += verts[i]
			var c := out_verts.size()
			out_verts.append(centre / n)
			sources.append(poly.duplicate())
			for k in n:
				var v := poly[k]
				var nxt := poly[(k + 1) % n]
				var prv := poly[(k + n - 1) % n]
				out_faces.append(PackedInt32Array([v, mids[Vector2i(mini(v, nxt), maxi(v, nxt))], c,
					mids[Vector2i(mini(prv, v), maxi(prv, v))]]))
				map.append(f)
				children.append(out_faces.size() - 1)
		else:
			var np := PackedInt32Array()
			for k in n:
				var a := poly[k]
				var b := poly[(k + 1) % n]
				np.append(a)
				var e := Vector2i(mini(a, b), maxi(a, b))
				if mids.has(e):
					np.append(mids[e])
			out_faces.append(np)
			map.append(f)
	return {verts = out_verts, faces = out_faces, map = map, vertex_sources = sources, selected = children}


## Removes faces and any vertices left unused. Returns {verts, faces, map} with
## map[new_face] = old face.
static func delete_faces(verts: PackedVector3Array, faces: Array[PackedInt32Array], selected: Array[int]) -> Dictionary:
	var kept: Array[PackedInt32Array] = []
	var map := PackedInt32Array()
	for f in faces.size():
		if not f in selected:
			kept.append(faces[f])
			map.append(f)
	var result := compact(verts, kept)
	result.map = map
	return result


## Identity for the original vertices, then each duplicated vertex's source.
static func _vertex_map(count: int, dup: Dictionary) -> PackedInt32Array:
	var map := PackedInt32Array()
	map.resize(count + dup.size())
	for i in count:
		map[i] = i
	for old in dup:
		map[dup[old]] = old
	return map


## Identity map for the first `count` faces, then `sources` for appended ones.
static func _extend_map(count: int, sources: PackedInt32Array) -> PackedInt32Array:
	var map := PackedInt32Array()
	for i in count:
		map.append(i)
	map.append_array(sources)
	return map


static func flip_faces(faces: Array[PackedInt32Array], selected: Array[int]) -> Array[PackedInt32Array]:
	var out := faces.duplicate()
	for f in selected:
		var poly := faces[f].duplicate()
		poly.reverse()
		out[f] = poly
	return out


## Drops unused vertices and remaps face indices. Returns {verts, faces, vertex_map} with
## vertex_map[new_vertex] = old vertex.
static func compact(verts: PackedVector3Array, faces: Array[PackedInt32Array]) -> Dictionary:
	var remap := {}
	var out_verts := PackedVector3Array()
	var out_faces: Array[PackedInt32Array] = []
	for poly in faces:
		var np := PackedInt32Array()
		for i in poly:
			if not remap.has(i):
				remap[i] = out_verts.size()
				out_verts.append(verts[i])
			np.append(remap[i])
		out_faces.append(np)
	var vertex_map := PackedInt32Array()
	vertex_map.resize(out_verts.size())
	for old in remap:
		vertex_map[remap[old]] = old
	return {verts = out_verts, faces = out_faces, vertex_map = vertex_map}


## Grid-preserving resize along local `axis` (0 x, 1 y, 2 z) on `side` (+1 / -1) by
## `delta` metres (+ grows, - shrinks). Vertices on that border move; growing then cuts
## new edge loops every `cell` metres (0 = detect the border cell size) so grid cells keep
## their size; walls on the border move with it and side walls gain matching columns.
## Shrinking collapses the cells past the new border (welds, drops flat faces).
## Returns {verts, faces, map (face -> source face), vertex_sources (per vertex: original
## vertices it averages), split (faces cut from a source face), fresh (faces wholly past
## the old border), cell} or {error}.
static func grid_resize(verts: PackedVector3Array, faces: Array[PackedInt32Array], axis: int, side: int,
		delta: float, cell := 0.0) -> Dictionary:
	const EPS := 1e-4
	if verts.is_empty() or absf(delta) < EPS:
		return {error = "nothing to resize"}
	var edge := -INF if side > 0 else INF
	for v in verts:
		edge = maxf(edge, v[axis]) if side > 0 else minf(edge, v[axis])
	if cell <= 0.0:
		cell = border_cell(verts, axis, side)
	var out_verts := verts.duplicate()
	var out_faces: Array[PackedInt32Array] = faces.duplicate()
	var sources: Array[PackedInt32Array] = []
	for i in verts.size():
		sources.append(PackedInt32Array([i]))
	var map := PackedInt32Array()
	for f in faces.size():
		map.append(f)

	if delta > 0.0:
		var new_edge := edge + side * delta
		for i in out_verts.size():
			if absf(out_verts[i][axis] - edge) < EPS:
				var v := out_verts[i]
				v[axis] = new_edge
				out_verts[i] = v
		var split := {}
		var k := 0
		while true:
			var plane := edge + side * k * cell
			if side * (new_edge - plane) <= EPS:
				break
			var cut := cut_axis_plane(out_verts, out_faces, axis, plane)
			out_verts = cut.verts
			out_faces = cut.faces
			for pair in cut.new_vertices:
				var src := PackedInt32Array(sources[pair.x])
				src.append_array(sources[pair.y])
				sources.append(src)
			var new_map := PackedInt32Array()
			var new_split := {}
			for f in cut.map.size():
				var prev: int = cut.map[f]
				new_map.append(map[prev])
				if cut.split.has(prev) or split.has(prev):
					new_split[f] = true
			map = new_map
			split = new_split
			k += 1
		# Faces now lying wholly past the old border are new cells (no paint carried over).
		var fresh := {}
		for f in out_faces.size():
			var past := true
			for i in out_faces[f]:
				if side * (out_verts[i][axis] - edge) < -EPS:
					past = false
					break
			if past and split.has(f):
				fresh[f] = true
		return {verts = out_verts, faces = out_faces, map = map, vertex_sources = sources,
			split = split, fresh = fresh, cell = cell}

	# Shrink: clamp everything past the new border onto it, weld, drop collapsed faces.
	var new_edge2 := edge + side * delta
	var on_plane := {}
	for i in out_verts.size():
		if side * (out_verts[i][axis] - new_edge2) >= -EPS:
			var v := out_verts[i]
			v[axis] = new_edge2
			out_verts[i] = v
			on_plane[i] = true
	var weld := {}
	var canonical := {}
	for i in on_plane:
		var key := (out_verts[i] / EPS).round()
		if canonical.has(key):
			weld[i] = canonical[key]
		else:
			canonical[key] = i
	var kept: Array[PackedInt32Array] = []
	var kept_map := PackedInt32Array()
	for f in out_faces.size():
		var poly := PackedInt32Array()
		for i in out_faces[f]:
			var j: int = weld.get(i, i)
			if poly.is_empty() or poly[poly.size() - 1] != j:
				poly.append(j)
		if poly.size() > 1 and poly[0] == poly[poly.size() - 1]:
			poly.resize(poly.size() - 1)
		if poly.size() < 3:
			continue
		var pts := PackedVector3Array()
		for i in poly:
			pts.append(out_verts[i])
		if PolyUtil.newell_normal(pts).length() < EPS:
			continue
		kept.append(poly)
		kept_map.append(f)
	var c := compact(out_verts, kept)
	var shrink_sources: Array[PackedInt32Array] = []
	for old in c.vertex_map:
		shrink_sources.append(PackedInt32Array([old]))
	return {verts = c.verts, faces = c.faces, map = kept_map, vertex_sources = shrink_sources,
		split = {}, fresh = {}, cell = cell}


## Spacing between the border on `side` of `axis` and the nearest vertex line inside it.
static func border_cell(verts: PackedVector3Array, axis: int, side: int) -> float:
	var edge := -INF if side > 0 else INF
	for v in verts:
		edge = maxf(edge, v[axis]) if side > 0 else minf(edge, v[axis])
	var best := INF
	for v in verts:
		var d := side * (edge - v[axis])
		if d > 1e-4:
			best = minf(best, d)
	return best if best < INF else 1.0


## Cuts every face crossing the plane `coord = plane` (local axis) into two, sharing the
## new vertices on crossed edges (no T-junctions). Returns {verts, faces, map (face ->
## source face), split (set of source faces that were cut), new_vertices (per added
## vertex: Vector2i of the edge it lies on)}.
static func cut_axis_plane(verts: PackedVector3Array, faces: Array[PackedInt32Array], axis: int, plane: float) -> Dictionary:
	var n := Vector3.ZERO
	n[axis] = 1.0
	return cut_plane(verts, faces, n, plane)


## Same as cut_axis_plane for any plane `normal . p = d` (normal unit length). `only`
## (face -> true, empty = all) limits which faces are cut; faces left whole that share a cut
## edge get its new vertex too, so no T-junctions open.
static func cut_plane(verts: PackedVector3Array, faces: Array[PackedInt32Array], normal: Vector3, d: float, only := {}) -> Dictionary:
	const EPS := 1e-5
	var out_verts := verts.duplicate()
	var out_faces: Array[PackedInt32Array] = []
	var map := PackedInt32Array()
	var split := {}
	var new_vertices: Array[Vector2i] = []
	var on_edge := {}
	for f in faces.size():
		var poly := faces[f]
		if not only.is_empty() and not only.has(f):
			out_faces.append(poly)
			map.append(f)
			continue
		var signs := PackedFloat32Array()
		var pos := false
		var neg := false
		for i in poly:
			var s := normal.dot(verts[i]) - d
			if absf(s) < EPS:
				s = 0.0
			signs.append(s)
			pos = pos or s > 0.0
			neg = neg or s < 0.0
		if not (pos and neg):
			out_faces.append(poly)
			map.append(f)
			continue
		var a := PackedInt32Array()
		var b := PackedInt32Array()
		for k in poly.size():
			var i := poly[k]
			var j := poly[(k + 1) % poly.size()]
			var si := signs[k]
			var sj := signs[(k + 1) % poly.size()]
			if si >= 0.0:
				a.append(i)
			if si <= 0.0:
				b.append(i)
			if (si > 0.0 and sj < 0.0) or (si < 0.0 and sj > 0.0):
				var key := Vector2i(mini(i, j), maxi(i, j))
				if not on_edge.has(key):
					var t := si / (si - sj)
					on_edge[key] = out_verts.size()
					out_verts.append(verts[i].lerp(verts[j], t))
					new_vertices.append(key)
				a.append(on_edge[key])
				b.append(on_edge[key])
		split[f] = true
		out_faces.append(a)
		map.append(f)
		out_faces.append(b)
		map.append(f)
	if not only.is_empty() and not on_edge.is_empty():
		for k in out_faces.size():
			if split.has(map[k]):
				continue
			var poly := out_faces[k]
			var grown := PackedInt32Array()
			for e in poly.size():
				var i := poly[e]
				var j := poly[(e + 1) % poly.size()]
				grown.append(i)
				var key := Vector2i(mini(i, j), maxi(i, j))
				if on_edge.has(key):
					grown.append(on_edge[key])
			out_faces[k] = grown
	return {verts = out_verts, faces = out_faces, map = map, split = split, new_vertices = new_vertices}


## Merges edge-adjacent coplanar faces that share the same `compat` value, then removes
## collinear vertices no other face needs. Returns {faces, compat, members} (members[i]:
## the input faces that make output face i, the surviving one first).
static func merge_coplanar(verts: PackedVector3Array, faces: Array[PackedInt32Array], compat: Array) -> Dictionary:
	var polys := []  # untyped so merged-away faces can be nulled
	polys.append_array(faces)
	var members := []
	for f in polys.size():
		members.append([f])
	var keys := []
	for f in polys.size():
		keys.append([compat[f], _plane_key(verts, polys[f])])

	var owner := {}
	var usage := {}
	for f in polys.size():
		_register(polys[f], f, owner, usage, 1)

	var queue := range(polys.size())
	while not queue.is_empty():
		var i: int = queue.pop_back()
		if polys[i] == null:
			continue
		var p: PackedInt32Array = polys[i]
		for k in p.size():
			var j: int = owner.get(Vector2i(p[(k + 1) % p.size()], p[k]), -1)
			if j < 0 or j == i or polys[j] == null or keys[j] != keys[i]:
				continue
			var merged := _try_merge(p, polys[j], usage)
			if merged.is_empty():
				continue
			_register(p, i, owner, usage, -1)
			_register(polys[j], j, owner, usage, -1)
			polys[i] = merged
			polys[j] = null
			members[i].append_array(members[j])
			_register(merged, i, owner, usage, 1)
			queue.append(i)
			break

	var out_faces: Array[PackedInt32Array] = []
	var out_compat := []
	var out_members := []
	for f in polys.size():
		if polys[f] != null:
			out_faces.append(_drop_collinear(verts, polys[f], usage))
			out_compat.append(compat[f])
			out_members.append(members[f])
	return {faces = out_faces, compat = out_compat, members = out_members}


static func _plane_key(verts: PackedVector3Array, poly: PackedInt32Array) -> Array:
	var pts := PackedVector3Array()
	for i in poly:
		pts.append(verts[i])
	var n := PolyUtil.newell_normal(pts)
	return [Vector3i((n * 1000.0).round()), roundi(n.dot(pts[0]) * 1000.0)]


static func _register(poly: PackedInt32Array, f: int, owner: Dictionary, usage: Dictionary, delta: int) -> void:
	for k in poly.size():
		var e := Vector2i(poly[k], poly[(k + 1) % poly.size()])
		if delta > 0:
			owner[e] = f
		elif owner.get(e, -1) == f:
			owner.erase(e)
		usage[poly[k]] = usage.get(poly[k], 0) + delta


## Joins P and Q along one contiguous run of shared edges. Empty result = can't merge
## (would leave a hole, pinch, or orphan a vertex another face depends on).
static func _try_merge(p: PackedInt32Array, q: PackedInt32Array, usage: Dictionary) -> PackedInt32Array:
	var qnext := {}
	for m in q.size():
		qnext[q[m]] = q[(m + 1) % q.size()]
	var n := p.size()
	var shared := []
	var shared_count := 0
	for k in n:
		var s: bool = qnext.get(p[(k + 1) % n], -1) == p[k]
		shared.append(s)
		if s:
			shared_count += 1
	if shared_count == 0 or shared_count == n:
		return PackedInt32Array()

	var start := -1
	for k in n:
		if shared[k] and not shared[(k + n - 1) % n]:
			start = k
			break
	var run := 0
	while shared[(start + run) % n]:
		run += 1
	if run != shared_count:
		return PackedInt32Array()
	for r in range(1, run):
		if usage.get(p[(start + r) % n], 0) != 2:
			return PackedInt32Array()

	var merged := PackedInt32Array()
	var run_end := p[(start + run) % n]
	var run_start := p[start]
	for k in n - run + 1:
		merged.append(p[(start + run + k) % n])
	var v: int = qnext[run_start]
	while v != run_end:
		if v in merged:
			return PackedInt32Array()
		merged.append(v)
		v = qnext[v]
	return merged


static func _drop_collinear(verts: PackedVector3Array, poly: PackedInt32Array, usage: Dictionary) -> PackedInt32Array:
	var out := poly.duplicate()
	var changed := true
	while changed and out.size() > 3:
		changed = false
		for k in out.size():
			var v := out[k]
			if usage.get(v, 0) != 1:
				continue
			var a := verts[out[(k + out.size() - 1) % out.size()]]
			var b := verts[v]
			var c := verts[out[(k + 1) % out.size()]]
			var d1 := b - a
			var d2 := c - b
			if d1.cross(d2).length() <= 1e-5 * d1.length() * d2.length() and d1.dot(d2) > 0.0:
				out.remove_at(k)
				changed = true
				break
	return out


## Rebuilds the `selected` faces as clean grids sized to `cell`: the selection splits into
## surfaces (connected faces within 60° of each other), and each becomes a grid aligned to
## its own longest border edge and extents, with round(length / cell) cells per side
## stretched to fit exactly (so the grid lines up with the geometry, not world snap).
## Heights come from the old surface (resampled along the surface normal), so sculpted
## terrain keeps its shape at the new density. Cells whose centre is off the old surface
## are dropped. Neighbouring faces gain the new border vertices (no T-junctions).
## Returns {verts, faces, map (face -> source face), vertex_sources, selected} or {error}.
static func retopo(verts: PackedVector3Array, faces: Array[PackedInt32Array], selected: Array[int], cell: float) -> Dictionary:
	cell = maxf(cell, 0.01)
	var normals: Array[Vector3] = []
	for poly in faces:
		var pts := PackedVector3Array()
		for i in poly:
			pts.append(verts[i])
		normals.append(PolyUtil.newell_normal(pts).normalized())
	var chosen := {}
	for f in selected:
		chosen[f] = true
	var edge_faces := {}
	for f in faces.size():
		var poly := faces[f]
		for k in poly.size():
			var e := Vector2i(mini(poly[k], poly[(k + 1) % poly.size()]), maxi(poly[k], poly[(k + 1) % poly.size()]))
			if not edge_faces.has(e):
				edge_faces[e] = []
			edge_faces[e].append(f)

	# Surfaces: connected selected faces within 60° of the seed face.
	var groups: Array = []
	var grouped := {}
	for seed in selected:
		if grouped.has(seed) or normals[seed] == Vector3.ZERO:
			continue
		var group: Array[int] = [seed]
		grouped[seed] = true
		var queue: Array[int] = [seed]
		while not queue.is_empty():
			var f: int = queue.pop_back()
			var poly := faces[f]
			for k in poly.size():
				var e := Vector2i(mini(poly[k], poly[(k + 1) % poly.size()]), maxi(poly[k], poly[(k + 1) % poly.size()]))
				for g: int in edge_faces[e]:
					if chosen.has(g) and not grouped.has(g) and normals[g].dot(normals[seed]) > 0.5:
						grouped[g] = true
						group.append(g)
						queue.append(g)
		groups.append(group)
	if groups.is_empty():
		return {error = "nothing to retopo"}

	var out_verts := verts.duplicate()
	var sources: Array[PackedInt32Array] = []
	for i in verts.size():
		sources.append(PackedInt32Array([i]))
	var new_faces: Array[PackedInt32Array] = []
	var new_map := PackedInt32Array()
	var border_verts := {}  # new vertex index -> true (may need inserting into neighbours)
	for group: Array[int] in groups:
		var made := _retopo_group(verts, faces, normals, group, edge_faces, chosen, cell, out_verts, sources)
		if made.has("error"):
			return made
		new_faces.append_array(made.faces)
		new_map.append_array(made.map)
		for v in made.border:
			border_verts[v] = true

	# Kept faces + new faces; then close T-junctions both ways along the region border.
	var all_faces: Array[PackedInt32Array] = []
	var map := PackedInt32Array()
	for f in faces.size():
		if not chosen.has(f):
			all_faces.append(faces[f])
			map.append(f)
	var first_new := all_faces.size()
	all_faces.append_array(new_faces)
	map.append_array(new_map)
	# Old vertices still used by unselected faces: where the neighbours meet the region.
	var kept_use := {}
	for f in faces.size():
		if not chosen.has(f):
			for i in faces[f]:
				kept_use[i] = true
	var shared := PackedInt32Array()
	for f in selected:
		for i in faces[f]:
			if kept_use.has(i) and not i in shared:
				shared.append(i)
	var new_border := PackedInt32Array()
	for v in border_verts:
		new_border.append(v)
	if not shared.is_empty():
		for f in all_faces.size():
			var poly := all_faces[f]
			if f < first_new:
				# Neighbours touching the region gain the new outline vertices.
				if Array(poly).any(func(i): return i in shared):
					all_faces[f] = _insert_on_edges(poly, out_verts, new_border)
			elif Array(poly).any(func(i): return border_verts.has(i)):
				# New outline faces gain the neighbours' old vertices along them.
				all_faces[f] = _insert_on_edges(poly, out_verts, shared)

	# Weld coincident vertices (shared group borders), drop unused ones.
	var keep := {}
	var remap := PackedInt32Array()
	for i in out_verts.size():
		var key := (out_verts[i] / 1e-4).round()
		if not keep.has(key):
			keep[key] = i
		remap.append(keep[key])
	var used := {}
	var final_faces: Array[PackedInt32Array] = []
	for poly in all_faces:
		var np := PackedInt32Array()
		for i in poly:
			var j := remap[i]
			if np.is_empty() or (np[np.size() - 1] != j and np[0] != j):
				np.append(j)
		final_faces.append(np)
		for j in np:
			used[j] = true
	var index := {}
	var final_verts := PackedVector3Array()
	var final_sources: Array[PackedInt32Array] = []
	for i in out_verts.size():
		if used.has(i):
			index[i] = final_verts.size()
			final_verts.append(out_verts[i])
			final_sources.append(sources[i])
	var faces_out: Array[PackedInt32Array] = []
	var map_out := PackedInt32Array()
	var selected_out: Array[int] = []
	for f in final_faces.size():
		if final_faces[f].size() < 3:
			continue
		var np := PackedInt32Array()
		for i in final_faces[f]:
			np.append(index[i])
		if f >= first_new:
			selected_out.append(faces_out.size())
		faces_out.append(np)
		map_out.append(map[f])
	return {verts = final_verts, faces = faces_out, map = map_out, vertex_sources = final_sources, selected = selected_out}


## One surface of a retopo: appends grid vertices to `out_verts` / `sources` and returns
## {faces, map, border (new vertex indices on the surface's outline)}.
static func _retopo_group(verts: PackedVector3Array, faces: Array[PackedInt32Array], normals: Array[Vector3],
		group: Array[int], edge_faces: Dictionary, chosen: Dictionary, cell: float,
		out_verts: PackedVector3Array, sources: Array[PackedInt32Array]) -> Dictionary:
	var n := Vector3.ZERO
	for f in group:
		n += normals[f]
	n = n.normalized()
	# Grid direction: the longest border edge of the surface, flattened onto its plane.
	var in_group := {}
	for f in group:
		in_group[f] = true
	var u_axis := Vector3.ZERO
	var best := -1.0
	for f in group:
		var poly := faces[f]
		for k in poly.size():
			var a := poly[k]
			var b := poly[(k + 1) % poly.size()]
			var e := Vector2i(mini(a, b), maxi(a, b))
			var inside := 0
			for g in edge_faces[e]:
				if in_group.has(g):
					inside += 1
			if inside != 1:
				continue
			var d := verts[b] - verts[a]
			d -= n * n.dot(d)
			if d.length() > best:
				best = d.length()
				u_axis = d
	if u_axis.length_squared() < 1e-10:
		u_axis = n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT)
	u_axis = u_axis.normalized()
	var v_axis := n.cross(u_axis).normalized()
	# Old surface as 2D triangles (u, v) with height h along n.
	var tris := []
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for f in group:
		var poly := faces[f]
		var pts := PackedVector3Array()
		for i in poly:
			pts.append(verts[i])
		var idx := PolyUtil.triangulate(pts, normals[f])
		for t in range(0, idx.size(), 3):
			var tri := []
			for k in 3:
				var vi := poly[idx[t + k]]
				var p := verts[vi]
				var q := Vector2(p.dot(u_axis), p.dot(v_axis))
				lo = lo.min(q)
				hi = hi.max(q)
				tri.append([q, p.dot(n), vi])
			tris.append([tri, f])
	var size := hi - lo
	var cu := maxi(1, roundi(size.x / cell))
	var cv := maxi(1, roundi(size.y / cell))
	var step := Vector2(size.x / cu, size.y / cv)
	# Grid points: surface height where they fall on it (nearest triangle otherwise).
	var grid := PackedInt32Array()
	grid.resize((cu + 1) * (cv + 1))
	for j in cv + 1:
		for i in cu + 1:
			var q := lo + Vector2(i * step.x, j * step.y)
			var s := _sample_surface(tris, q)
			grid[j * (cu + 1) + i] = out_verts.size()
			out_verts.append(u_axis * q.x + v_axis * q.y + n * s.h)
			sources.append(s.src)
	# Cells whose centre lies on the old surface; winding follows the surface normal.
	var out_faces: Array[PackedInt32Array] = []
	var map := PackedInt32Array()
	var used_points := {}
	for j in cv:
		for i in cu:
			var centre := lo + Vector2((i + 0.5) * step.x, (j + 0.5) * step.y)
			var src_face := _face_at(tris, centre)
			if src_face < 0:
				continue
			var a := grid[j * (cu + 1) + i]
			var b := grid[j * (cu + 1) + i + 1]
			var c := grid[(j + 1) * (cu + 1) + i + 1]
			var d := grid[(j + 1) * (cu + 1) + i]
			var quad := PackedInt32Array([a, b, c, d])
			var qn := (out_verts[b] - out_verts[a]).cross(out_verts[d] - out_verts[a])
			if qn.dot(n) < 0.0:
				quad.reverse()
			out_faces.append(quad)
			map.append(src_face)
			for v in quad:
				used_points[v] = used_points.get(v, 0) + 1
	if out_faces.is_empty():
		return {error = "the selection is smaller than one grid cell"}
	# Outline points: used by fewer than 4 cells of the grid.
	var border: Array[int] = []
	for v in used_points:
		if used_points[v] < 4:
			border.append(v)
	return {faces = out_faces, map = map, border = border}


## Height and source vertices of the old surface at 2D point `q` (barycentric inside a
## triangle, else the closest triangle's clamped point).
static func _sample_surface(tris: Array, q: Vector2) -> Dictionary:
	var best := INF
	var out := {h = 0.0, src = PackedInt32Array()}
	for entry in tris:
		var tri: Array = entry[0]
		var a: Vector2 = tri[0][0]
		var b: Vector2 = tri[1][0]
		var c: Vector2 = tri[2][0]
		var bary := _barycentric(q, a, b, c)
		var inside := bary.x >= -1e-4 and bary.y >= -1e-4 and bary.z >= -1e-4
		var clamped := bary.clamp(Vector3.ZERO, Vector3.ONE)
		clamped /= maxf(clamped.x + clamped.y + clamped.z, 1e-6)
		var p := a * clamped.x + b * clamped.y + c * clamped.z
		var dist := 0.0 if inside else p.distance_to(q)
		if dist < best:
			best = dist
			var w := bary if inside else clamped
			out = {h = tri[0][1] * w.x + tri[1][1] * w.y + tri[2][1] * w.z,
				src = PackedInt32Array([tri[0][2], tri[1][2], tri[2][2]])}
			if inside:
				break
	return out


static func _face_at(tris: Array, q: Vector2) -> int:
	for entry in tris:
		var tri: Array = entry[0]
		var bary := _barycentric(q, tri[0][0], tri[1][0], tri[2][0])
		if bary.x >= -1e-4 and bary.y >= -1e-4 and bary.z >= -1e-4:
			return entry[1]
	return -1


static func _barycentric(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> Vector3:
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var den := v0.x * v1.y - v1.x * v0.y
	if absf(den) < 1e-12:
		return Vector3(-1, -1, -1)
	var v := (v2.x * v1.y - v1.x * v2.y) / den
	var w := (v0.x * v2.y - v2.x * v0.y) / den
	return Vector3(1.0 - v - w, v, w)


## `poly` with any of `candidates` that lie strictly inside one of its edges inserted
## there (in order), so neighbouring faces share vertices instead of T-junctions.
static func _insert_on_edges(poly: PackedInt32Array, verts: PackedVector3Array, candidates: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k in poly.size():
		var a := poly[k]
		var b := poly[(k + 1) % poly.size()]
		out.append(a)
		var pa := verts[a]
		var ab := verts[b] - pa
		var len2 := ab.length_squared()
		if len2 < 1e-10:
			continue
		var hits := []
		for c in candidates:
			if c == a or c == b or c in poly:
				continue
			var t := (verts[c] - pa).dot(ab) / len2
			if t <= 1e-4 or t >= 1.0 - 1e-4:
				continue
			if (pa + ab * t).distance_squared_to(verts[c]) > 1e-6:
				continue
			hits.append([t, c])
		hits.sort_custom(func(x, y): return x[0] < y[0])
		for h in hits:
			out.append(h[1])
	return out


## Merges vertices closer than `eps` (e.g. where an extruded wall ring closes on itself),
## dropping faces that collapse. Returns {merged: 0} when nothing coincides, else {verts,
## faces, map (face -> source face), vertex_sources, remap (old vertex -> new), merged}.
static func weld_coincident(verts: PackedVector3Array, faces: Array[PackedInt32Array], eps := 0.001) -> Dictionary:
	var keep := {}
	var remap := PackedInt32Array()
	var out_verts := PackedVector3Array()
	var sources: Array[PackedInt32Array] = []
	for i in verts.size():
		var key := (verts[i] / eps).round()
		var j: int = keep.get(key, -1)
		if j < 0:
			j = out_verts.size()
			keep[key] = j
			out_verts.append(verts[i])
			sources.append(PackedInt32Array([i]))
		else:
			sources[j].append(i)
		remap.append(j)
	if out_verts.size() == verts.size():
		return {merged = 0}
	var out_faces: Array[PackedInt32Array] = []
	var map := PackedInt32Array()
	for f in faces.size():
		var np := PackedInt32Array()
		for i in faces[f]:
			var j := remap[i]
			if np.is_empty() or np[np.size() - 1] != j:
				np.append(j)
		if np.size() > 1 and np[0] == np[np.size() - 1]:
			np.remove_at(np.size() - 1)
		if np.size() >= 3:
			out_faces.append(np)
			map.append(f)
	return {verts = out_verts, faces = out_faces, map = map, vertex_sources = sources, remap = remap,
		merged = verts.size() - out_verts.size()}


## Ramp heights for `points` (id -> world position). The highest points are the top; the
## lowest point farthest (flat) from the top marks the foot line. Points between the top's
## near edge and the foot line get an even slope (measured along top -> foot); points past
## the top's edge keep their height. Returns {heights: id -> y} or {error: String}.
static func ramp_heights(points: Dictionary) -> Dictionary:
	var lo := INF
	var hi := -INF
	for i in points:
		lo = minf(lo, points[i].y)
		hi = maxf(hi, points[i].y)
	if points.size() < 3:
		return {error = "select the foot row, the top row and the vertices between them."}
	if hi - lo < 0.01:
		return {error = "the selection is flat. Raise the top row to the ramp's height first, then select both rows and the vertices between and press R."}
	var eps := minf(0.01, (hi - lo) * 0.1)
	var top_c := Vector3.ZERO
	var low_c := Vector3.ZERO
	var n_top := 0
	var n_low := 0
	for i in points:
		var p: Vector3 = points[i]
		if p.y >= hi - eps:
			top_c += p
			n_top += 1
		elif p.y <= lo + eps:
			low_c += p
			n_low += 1
	top_c /= n_top
	low_c /= n_low
	var dir := Vector3(low_c.x - top_c.x, 0.0, low_c.z - top_c.z)
	if dir.length_squared() < 0.0001:
		return {error = "the low vertices aren't off to one side of the top ones, so there's no direction to slope in."}
	dir = dir.normalized()
	var s_top := -INF
	var s_foot := -INF
	for i in points:
		var p: Vector3 = points[i]
		var s := p.dot(dir)
		if p.y >= hi - eps:
			s_top = maxf(s_top, s)
		elif p.y <= lo + eps:
			s_foot = maxf(s_foot, s)
	if s_foot - s_top < 0.01:
		return {error = "the foot row has to be off to one side of the top row."}
	var heights := {}
	for i in points:
		var p: Vector3 = points[i]
		var s := p.dot(dir)
		if p.y >= hi - eps or s < s_top - 0.001:
			continue
		heights[i] = lerpf(hi, lo, clampf((s - s_top) / (s_foot - s_top), 0.0, 1.0))
	return {heights = heights}
