@tool
class_name ActorPieceOps
extends RefCounted
## Modelling operations on ActorPieces (in place; callers snapshot for undo). Positions
## are in the piece's bone frame and snapped to `grid`. Centre pieces with `mirror` edit
## symmetrically: vertex moves and face edits also apply to the mirror twins.


static func is_centre(p: ActorPiece) -> bool:
	return not String(p.bone).ends_with("_L") and not String(p.bone).ends_with("_R")


static func symmetric(p: ActorPiece) -> bool:
	return p.mirror and is_centre(p)


## Vertices of the given faces (all vertices when `faces` is empty).
static func face_vertices(p: ActorPiece, faces: Array[int]) -> Array[int]:
	var out: Array[int] = []
	if faces.is_empty():
		for i in p.vertices.size():
			out.append(i)
		return out
	var f := p.faces()
	for fi in faces:
		if fi < f.size():
			for v in f[fi]:
				if not out.has(v):
					out.append(v)
	return out


## Blender's Select Shortest Path: the elements (ActorModel.Select kind: vertex ids, edge
## Vector2i, face ids) along the shortest route over the mesh from `from` to `to`, both
## ends included. Vertices / edges walk the edges (by length), faces step across shared
## edges (by centre distance). Empty when they aren't connected.
static func shortest_path(p: ActorPiece, kind: int, from: Variant, to: Variant) -> Array:
	return path_over(p.vertices, p.faces(), kind, from, to)


## shortest_path over any polygon mesh (level brushes use it too): `f` holds each face's
## vertex ids.
static func path_over(verts: PackedVector3Array, f: Array, kind: int, from: Variant, to: Variant) -> Array:
	var adj: Array = []  # node -> [[node, weight], ...]
	var out: Array = []
	if kind == 2:  # faces
		var centres: Array[Vector3] = []
		var by_edge := {}
		for i in f.size():
			adj.append([])
			var c := Vector3.ZERO
			for v in f[i]:
				c += verts[v]
			centres.append(c / maxf(f[i].size(), 1))
			for k in f[i].size():
				var e := _edge(f[i][k], f[i][(k + 1) % f[i].size()])
				if by_edge.has(e):
					for j in by_edge[e]:
						var w := centres[i].distance_to(centres[j])
						adj[i].append([j, w])
						adj[j].append([i, w])
					by_edge[e].append(i)
				else:
					by_edge[e] = [i]
		if from < f.size() and to < f.size():
			out.assign(_dijkstra(adj, centres, [from], [to]))
		return out
	for i in verts.size():
		adj.append([])
	var seen := {}
	for poly in f:
		for k in poly.size():
			var e := _edge(poly[k], poly[(k + 1) % poly.size()])
			if seen.has(e):
				continue
			seen[e] = true
			var w := verts[e.x].distance_to(verts[e.y])
			adj[e.x].append([e.y, w])
			adj[e.y].append([e.x, w])
	if kind == 0:
		if from < adj.size() and to < adj.size():
			out.assign(_dijkstra(adj, verts, [from], [to]))
		return out
	# Edges: walk from either end of `from` to the nearer end of `to`.
	var a: Vector2i = from
	var b: Vector2i = to
	var chain := _dijkstra(adj, verts, [a.x, a.y], [b.x, b.y])
	if chain.is_empty():
		return out
	out.append(a)
	for i in chain.size() - 1:
		var e := _edge(chain[i], chain[i + 1])
		if not out.has(e):
			out.append(e)
	if not out.has(b):
		out.append(b)
	return out


## Straight-line tie-break weight (per unit off the line), far below any real length gap.
const TIE := 0.001


static func _edge(a: int, b: int) -> Vector2i:
	return Vector2i(mini(a, b), maxi(a, b))


## Nodes from the nearest source to the nearest target ([] if unreachable). Of equally
## short routes (a diagonal across a grid) it takes the one hugging the straight line
## between the ends (`pts`: node positions). Pieces are a few hundred vertices at most,
## so a plain O(n²) scan beats a heap.
static func _dijkstra(adj: Array, pts: Variant, sources: Array, targets: Array) -> Array[int]:
	var n := adj.size()
	var line_a := Vector3.ZERO
	var line_b := Vector3.ZERO
	for s in sources:
		line_a += pts[s] / sources.size()
	for t in targets:
		line_b += pts[t] / targets.size()
	var off := PackedFloat64Array()
	off.resize(n)
	for i in n:
		off[i] = TIE * pts[i].distance_to(Geometry3D.get_closest_point_to_segment(pts[i], line_a, line_b))
	var dist := PackedFloat64Array()
	dist.resize(n)
	dist.fill(INF)
	var prev := PackedInt32Array()
	prev.resize(n)
	prev.fill(-1)
	var done := PackedByteArray()
	done.resize(n)
	for s in sources:
		dist[s] = 0.0
	var end := -1
	while true:
		var u := -1
		for i in n:
			if not done[i] and dist[i] < INF and (u < 0 or dist[i] < dist[u]):
				u = i
		if u < 0:
			break
		if targets.has(u):
			end = u
			break
		done[u] = 1
		for nw in adj[u]:
			var d: float = dist[u] + nw[1] + off[nw[0]]
			if d < dist[nw[0]]:
				dist[nw[0]] = d
				prev[nw[0]] = u
	var path: Array[int] = []
	while end >= 0:
		path.push_front(end)
		end = prev[end]
	return path


## Adds mirror twins of `faces` (centre pieces).
static func with_twin_faces(p: ActorPiece, faces: Array[int]) -> Array[int]:
	var out: Array[int] = faces.duplicate()
	if not symmetric(p):
		return out
	var f := p.faces()
	var keys := {}
	for i in f.size():
		keys[_face_key(f[i])] = i
	for fi in faces:
		var tw := PackedInt32Array()
		for v in f[fi]:
			tw.append(p.twin(v))
		if tw.has(-1):
			continue
		var j: int = keys.get(_face_key(tw), -1)
		if j >= 0 and not out.has(j):
			out.append(j)
	return out


static func _face_key(poly: PackedInt32Array) -> String:
	var s := Array(poly)
	s.sort()
	return str(s)


static func snap_v(v: Vector3, grid: float) -> Vector3:
	return v.snapped(Vector3(grid, grid, grid)) if grid > 0.0 else v


# --- Vertices ---------------------------------------------------------------------------------

## Moves vertices by `delta`. `snap_each`: every result lands on the grid (one vertex);
## off for a group, which keeps its shape (snap the delta instead), or a coarse grid
## would pinch it into one point.
## Symmetric centre pieces: the selected vertices move exactly by `delta` (both sides
## selected = they all shift); mirror twins that aren't selected follow mirrored, and
## while that mirroring happens, selected centre-line vertices stay on the centre line.
static func move(p: ActorPiece, ids: Array[int], delta: Vector3, grid: float, snap_each := true) -> void:
	var targets := {}
	for v in ids:
		targets[v] = p.vertices[v] + delta
	if symmetric(p):
		var selected := {}
		for v in ids:
			selected[v] = true
		var twins := {}
		var mirroring := false
		for v in ids:
			var t := p.twin(v)
			twins[v] = t
			if t >= 0 and t != v and not selected.has(t):
				mirroring = true
		if mirroring:
			for v in ids:
				var t: int = twins[v]
				var q: Vector3 = targets[v]
				if t == v:
					q.x = 0.0  # stays on the centre line
					targets[v] = q
				elif t >= 0 and not selected.has(t):
					targets[t] = Vector3(-q.x, q.y, q.z)
	for v in targets:
		p.vertices[v] = snap_v(targets[v], grid) if snap_each else targets[v]


## Rotates vertices by `rot` about `pivot` (both model space). The vertices are seen
## through `xf` (the piece's transform as shown; `mirrored`: its right-side mirror copy,
## whose vertices are the source's with x negated). Not snapped. Symmetric centre
## pieces: unselected mirror twins follow mirrored (like move).
static func rotate(p: ActorPiece, ids: Array[int], rot: Basis, pivot: Vector3, xf: Transform3D, mirrored := false) -> void:
	var inv := xf.affine_inverse()
	var targets := {}
	for v in ids:
		var local := p.vertices[v]
		if mirrored:
			local.x = -local.x
		var world := xf * local
		var back := inv * (pivot + rot * (world - pivot))
		if mirrored:
			back.x = -back.x
		targets[v] = back
	if symmetric(p):
		var selected := {}
		for v in ids:
			selected[v] = true
		for v in ids:
			var t := p.twin(v)
			if t >= 0 and t != v and not selected.has(t):
				var q: Vector3 = targets[v]
				targets[t] = Vector3(-q.x, q.y, q.z)
	for v in targets:
		p.vertices[v] = targets[v]


## Scales vertices about their centre (factor per axis). Not snapped: scaling up then
## down by the same step gets back exactly to where it started.
static func scale(p: ActorPiece, ids: Array[int], factor: Vector3, _grid: float) -> void:
	var c := centre(p, ids)
	if symmetric(p):
		c.x = 0.0
	var all := _with_twins(p, ids)
	for v in all:
		p.vertices[v] = c + (p.vertices[v] - c) * factor


## Pushes vertices out along their normals (negative: in). Turns a torso into a shirt.
## Not snapped, so inflate then deflate undo each other.
static func inflate(p: ActorPiece, ids: Array[int], amount: float, _grid: float) -> void:
	var normals := vertex_normals(p)
	var all := _with_twins(p, ids)
	var moved := {}
	for v in all:
		moved[v] = p.vertices[v] + normals[v] * amount
	for v in moved:
		p.vertices[v] = moved[v]


static func centre(p: ActorPiece, ids: Array[int]) -> Vector3:
	var c := Vector3.ZERO
	for v in ids:
		c += p.vertices[v]
	return c / maxf(ids.size(), 1)


static func vertex_normals(p: ActorPiece) -> PackedVector3Array:
	var n := PackedVector3Array()
	n.resize(p.vertices.size())
	for poly in p.faces():
		var fn := face_normal(p, poly)
		for v in poly:
			n[v] += fn
	for i in n.size():
		n[i] = n[i].normalized()
	return n


static func face_normal(p: ActorPiece, poly: PackedInt32Array) -> Vector3:
	var n := Vector3.ZERO
	for k in range(1, poly.size() - 1):
		n += (p.vertices[poly[k]] - p.vertices[poly[0]]).cross(p.vertices[poly[k + 1]] - p.vertices[poly[0]])
	return n.normalized()


static func _with_twins(p: ActorPiece, ids: Array[int]) -> Array[int]:
	var out: Array[int] = ids.duplicate()
	if symmetric(p):
		for v in ids:
			var t := p.twin(v)
			if t >= 0 and not out.has(t):
				out.append(t)
	return out


# --- Faces --------------------------------------------------------------------------------

## Extrudes faces out along their average normal by `amount`. Returns the new selection.
static func extrude(p: ActorPiece, faces: Array[int], amount: float, grid: float) -> Array[int]:
	var sel := with_twin_faces(p, faces)
	p.make_free()
	var snap := p.paint_snapshot()
	var r := BrushOps.extrude_faces(p.vertices, p.faces(), sel)
	p.vertices = r.verts
	p.set_faces(r.faces)
	# Each side moves along its own faces' normal (twins mirror).
	var f := p.faces()
	var push := {}
	for fi in sel:
		var fn := face_normal(p, f[fi])
		for v in f[fi]:
			push[v] = push.get(v, Vector3.ZERO) + fn
	for v in push:
		p.vertices[v] = snap_v(p.vertices[v] + (push[v] as Vector3).normalized() * amount, grid)
	p.restore_paint(snap)
	return sel


## Extrudes open edges (a hole's rim, a flap's edge) outward, continuing their face, by
## `amount`. Returns the new edges.
static func extrude_edges(p: ActorPiece, edges: Array[Vector2i], amount: float, grid: float) -> Array[Vector2i]:
	p.make_free()
	var snap := p.paint_snapshot()
	var before := p.faces()
	var push := {}  # vertex -> direction
	for e in edges:
		var out := BrushOps.boundary_edge_outward(p.vertices, before, e)
		for v in [e.x, e.y]:
			push[v] = push.get(v, Vector3.ZERO) + out
	var r := BrushOps.extrude_edges(p.vertices, before, edges)
	p.vertices = r.verts
	p.set_faces(r.faces)
	var vmap: PackedInt32Array = r.vertex_map
	for nv in r.moved:
		var src := vmap[nv]
		var d: Vector3 = push.get(src, Vector3.ZERO)
		if d.length() > 1e-5:
			p.vertices[nv] = snap_v(p.vertices[nv] + d.normalized() * amount, grid)
	p.restore_paint(snap)
	var out_edges: Array[Vector2i] = []
	out_edges.assign(r.new_edges)
	return out_edges


static func subdivide(p: ActorPiece, faces: Array[int]) -> Array[int]:
	var sel := with_twin_faces(p, faces)
	p.make_free()
	var snap := p.paint_snapshot()
	var r := BrushOps.subdivide_faces(p.vertices, p.faces(), sel)
	p.vertices = r.verts
	p.set_faces(r.faces)
	p.restore_paint(snap)
	var out: Array[int] = []
	out.assign(r.selected)
	return out


static func delete_faces(p: ActorPiece, faces: Array[int]) -> void:
	var sel := with_twin_faces(p, faces)
	p.make_free()
	var snap := p.paint_snapshot()
	var r := BrushOps.delete_faces(p.vertices, p.faces(), sel)
	p.vertices = r.verts
	p.set_faces(r.faces)
	p.restore_paint(snap)


static func flip(p: ActorPiece, faces: Array[int]) -> void:
	p.make_free()
	p.set_faces(BrushOps.flip_faces(p.faces(), with_twin_faces(p, faces)))


## Dissolves vertices (Blender's Dissolve Vertices): a vertex in the middle of an edge
## (two edges meet there) leaves its faces, its neighbours joining straight; where more
## edges meet, the faces around it merge into one polygon without it. Faces left with
## fewer than 3 corners go. Mirror twins dissolve too on symmetric centre pieces.
static func dissolve(p: ActorPiece, verts: Array[int]) -> void:
	var ids := _with_twins(p, verts)
	p.make_free()
	var snap := p.paint_snapshot()
	var faces := p.faces()
	# First the edges between dissolved vertices (a cut ring's own edges): their two faces
	# merge, so the vertices end up in straight edges and leave cleanly.
	var chosen := {}
	for v in ids:
		chosen[v] = true
	var merged := true
	while merged:
		merged = false
		for fi in faces.size():
			var poly := faces[fi]
			for k in poly.size():
				var a := poly[k]
				var b := poly[(k + 1) % poly.size()]
				if not (chosen.has(a) and chosen.has(b)):
					continue
				for fj in faces.size():
					if fj != fi and _has_edge(faces[fj], b, a):
						faces = _merge_across(faces, fi, fj, a, b)
						merged = true
						break
				if merged:
					break
			if merged:
				break
	for v in ids:
		faces = _dissolve_one(faces, v)
	var kept: Array[PackedInt32Array] = []
	for poly in faces:
		if poly.size() >= 3:
			kept.append(poly)
	var r := BrushOps.compact(p.vertices, kept)
	p.vertices = r.verts
	p.set_faces(r.faces)
	p.restore_paint(snap)


static func _has_edge(poly: PackedInt32Array, a: int, b: int) -> bool:
	for k in poly.size():
		if poly[k] == a and poly[(k + 1) % poly.size()] == b:
			return true
	return false


## Faces fi (with edge a -> b) and fj (with b -> a) become one: fi from b round to a,
## then fj's other corners.
static func _merge_across(faces: Array[PackedInt32Array], fi: int, fj: int, a: int, b: int) -> Array[PackedInt32Array]:
	var p := faces[fi]
	var q := faces[fj]
	var loop := PackedInt32Array()
	var kb := Array(p).find(b)
	for k in p.size():
		loop.append(p[(kb + k) % p.size()])  # b ... a
	var ka := Array(q).find(a)
	for k in range(1, q.size() - 1):
		loop.append(q[(ka + k) % q.size()])  # q's corners between a and b
	var out: Array[PackedInt32Array] = []
	for f in faces.size():
		if f != fi and f != fj:
			out.append(faces[f])
	out.append(loop)
	return out


static func _dissolve_one(faces: Array[PackedInt32Array], v: int) -> Array[PackedInt32Array]:
	var around: Array[int] = []
	var neighbours := {}
	for fi in faces.size():
		var poly := faces[fi]
		var k := Array(poly).find(v)
		if k < 0:
			continue
		around.append(fi)
		neighbours[poly[(k + 1) % poly.size()]] = true
		neighbours[poly[(k - 1 + poly.size()) % poly.size()]] = true
	if around.is_empty():
		return faces
	var out: Array[PackedInt32Array] = []
	if neighbours.size() <= 2 or around.size() == 1:
		# On an edge: just drop the corner from its faces.
		for fi in faces.size():
			var poly := faces[fi]
			if around.has(fi):
				var np := PackedInt32Array()
				for u in poly:
					if u != v:
						np.append(u)
				out.append(np)
			else:
				out.append(poly)
		return out
	# Faces around it merge: chain their edges that don't touch `v` into one loop.
	var next := {}  # start -> end of the boundary edges (face winding kept)
	for fi in around:
		var poly := faces[fi]
		for k in poly.size():
			var a := poly[k]
			var b := poly[(k + 1) % poly.size()]
			if a != v and b != v:
				next[a] = b
	var loop := PackedInt32Array()
	if not next.is_empty():
		# Open fan (v on a border): start where no edge ends.
		var ends := {}
		for a in next:
			ends[next[a]] = true
		var start: int = next.keys()[0]
		for a in next:
			if not ends.has(a):
				start = a
				break
		var cur := start
		while next.has(cur) and loop.size() <= next.size():
			loop.append(cur)
			cur = next[cur]
			if cur == start:
				break
		if cur != start and not loop.has(cur):
			loop.append(cur)
	for fi in faces.size():
		if not around.has(fi):
			out.append(faces[fi])
	if loop.size() >= 3:
		out.append(loop)
	return out


## Collapses vertices to their centre (points, tips, merging).
static func collapse(p: ActorPiece, verts: Array[int], grid: float) -> void:
	merge(p, verts, Merge.CENTER, grid)


## Blender's Merge menu: all to their centre (snapped), to the first / last selected
## (`verts` in selection order), each connected group to its own centre, all to `point`
## (piece space), or only vertices within `dist` of each other (onto the first of them).
enum Merge { CENTER, FIRST, LAST, COLLAPSE, POINT, DISTANCE }

## Merges `verts` (see Merge); symmetric pieces merge the mirror partners to the mirrored
## spot. Returns how many vertices were removed.
static func merge(p: ActorPiece, verts: Array[int], mode: Merge, grid: float, point := Vector3.ZERO, dist := 0.001) -> int:
	if verts.is_empty():
		return 0
	p.make_free()
	var before := p.vertices.size()
	var snap := p.paint_snapshot()
	var groups: Array = []  # [ids, target]
	match mode:
		Merge.COLLAPSE:
			for island in _islands(p, verts):
				groups.append([island, snap_v(centre(p, island), grid)])
		Merge.DISTANCE:
			for cluster in _clusters(p, verts, dist):
				if cluster.size() > 1:
					groups.append([cluster, p.vertices[cluster[0]]])
		_:
			var target: Vector3 = {Merge.CENTER: snap_v(centre(p, verts), grid), Merge.FIRST: p.vertices[verts[0]],
				Merge.LAST: p.vertices[verts[-1]], Merge.POINT: point}[mode]
			groups.append([verts, target])
	if symmetric(p):
		var taken := {}
		for g in groups:
			for v in g[0]:
				taken[v] = true
		var twins: Array = []
		for g in groups:
			var tw: Array[int] = []
			var both_sides := false
			for v in g[0]:
				var t := p.twin(v)
				if t < 0 or t == v:
					continue
				if taken.has(t):
					both_sides = true
				else:
					tw.append(t)
			if both_sides:
				# Both sides in one group: the merged vertex stays on the centre line.
				g[1] = Vector3(0.0, g[1].y, g[1].z)
			if not tw.is_empty():
				twins.append([tw, Vector3(-g[1].x, g[1].y, g[1].z)])
		groups.append_array(twins)
	for g in groups:
		for v in g[0]:
			p.vertices[v] = g[1]
	var r := BrushOps.weld_vertices(p.vertices, p.faces())
	p.vertices = r.verts
	var cleaned: Array[PackedInt32Array] = []
	for poly in r.faces:
		var np := PackedInt32Array()
		for v in poly:
			if np.is_empty() or np[-1] != v:
				np.append(v)
		if np.size() > 1 and np[0] == np[-1]:
			np.resize(np.size() - 1)
		if np.size() >= 3:
			cleaned.append(np)
	p.set_faces(cleaned)
	p.restore_paint(snap)
	return before - p.vertices.size()


## `verts` split into groups connected by edges between them.
static func _islands(p: ActorPiece, verts: Array[int]) -> Array:
	var sel := {}
	for v in verts:
		sel[v] = true
	var links := {}
	for poly in p.faces():
		for k in poly.size():
			var a := poly[k]
			var b := poly[(k + 1) % poly.size()]
			if sel.has(a) and sel.has(b):
				links.get_or_add(a, []).append(b)
				links.get_or_add(b, []).append(a)
	var seen := {}
	var out := []
	for v in verts:
		if seen.has(v):
			continue
		var island: Array[int] = []
		var stack := [v]
		seen[v] = true
		while not stack.is_empty():
			var u: int = stack.pop_back()
			island.append(u)
			for w in links.get(u, []):
				if not seen.has(w):
					seen[w] = true
					stack.append(w)
		out.append(island)
	return out


## `verts` grouped by closeness (each within `dist` of the group's first).
static func _clusters(p: ActorPiece, verts: Array[int], dist: float) -> Array:
	var seen := {}
	var out := []
	for v in verts:
		if seen.has(v):
			continue
		var cluster: Array[int] = [v]
		seen[v] = true
		for u in verts:
			if not seen.has(u) and p.vertices[u].distance_to(p.vertices[v]) <= dist:
				cluster.append(u)
				seen[u] = true
		out.append(cluster)
	return out


# --- Loop cut -----------------------------------------------------------------------------

## The edge ring through `start` (Blender's loop cut): the edges a cut across `start`
## passes, walking through quads to their opposite edge both ways, until a non-quad face,
## an open edge or back to the start. Edges are oriented consistently (`a` sides line up),
## so one slide factor places the cut on all of them.
## {edges: Array[Vector2i] (in order), closed: bool}
static func edge_ring(p: ActorPiece, start: Vector2i) -> Dictionary:
	var f := p.faces()
	var faces_of := {}
	for fi in f.size():
		var poly := f[fi]
		for k in poly.size():
			var key := _edge_key(poly[k], poly[(k + 1) % poly.size()])
			if not faces_of.has(key):
				faces_of[key] = []
			faces_of[key].append(fi)
	var start_key := _edge_key(start.x, start.y)
	var start_faces: Array = faces_of.get(start_key, [])
	var forward: Array[Vector2i] = []
	var closed := false
	var used := {}
	if start_faces.size() > 0:
		closed = _walk_ring(f, faces_of, start, start_faces[0], start_key, forward, used)
	var backward: Array[Vector2i] = []
	if not closed and start_faces.size() > 1:
		_walk_ring(f, faces_of, start, start_faces[1], start_key, backward, used)
	var edges: Array[Vector2i] = []
	for i in range(backward.size() - 1, -1, -1):
		edges.append(backward[i])
	edges.append(start)
	edges.append_array(forward)
	return {edges = edges, closed = closed}


## Walks from `edge` into `face` and on; appends the exit edges. True if it came back to
## the start edge (a closed loop).
static func _walk_ring(f: Array[PackedInt32Array], faces_of: Dictionary, edge: Vector2i, face: int, start_key: String, out: Array[Vector2i], used: Dictionary) -> bool:
	var e := edge
	var fi := face
	while true:
		if used.has(fi):
			return false
		var poly := f[fi]
		if poly.size() != 4:
			return false
		used[fi] = true
		var ia := Array(poly).find(e.x)
		var ib := Array(poly).find(e.y)
		if ia < 0 or ib < 0:
			return false
		# The opposite edge, oriented so its first vertex is the one next to e.x.
		var d: int = poly[(ia + 3) % 4] if poly[(ia + 1) % 4] == e.y else poly[(ia + 1) % 4]
		var c: int = poly[(ib + 1) % 4] if poly[(ib + 3) % 4] == e.x else poly[(ib + 3) % 4]
		var nxt := Vector2i(d, c)
		var key := _edge_key(d, c)
		if key == start_key:
			return true
		out.append(nxt)
		var others: Array = faces_of.get(key, []).filter(func(x): return x != fi)
		if others.is_empty():
			return false
		e = nxt
		fi = others[0]
	return false


static func _edge_key(a: int, b: int) -> String:
	return "%d_%d" % [mini(a, b), maxi(a, b)]


## Cuts `ring` (edge_ring()) at the slide factors `ts` (0..1 from each edge's first vertex):
## a new vertex per cut on every ring edge, each crossed quad split into strips, and
## other faces on the ring's end edges get the new vertices in their outline (no holes).
## Tubes whose cut runs around them get new rings instead (they stay tubes).
## Returns the new edges (for selection).
static func loop_cut(p: ActorPiece, ring: Dictionary, ts: Array) -> Array[Vector2i]:
	var edges: Array[Vector2i] = []
	edges.assign(ring.edges)
	var cuts: Array = ts.duplicate()
	cuts.sort()
	var out: Array[Vector2i] = []
	if edges.is_empty() or cuts.is_empty():
		return out
	if p.is_tube() and _cut_tube_rings(p, edges, cuts):
		return out
	p.make_free()
	var snap := p.paint_snapshot()
	# New vertices per ring edge (ordered from the edge's first vertex).
	var new_on := {}  # oriented key "a_b" -> PackedInt32Array
	for e in edges:
		var ids := PackedInt32Array()
		for t in cuts:
			ids.append(p.vertices.size())
			p.vertices.append(p.vertices[e.x].lerp(p.vertices[e.y], t))
		new_on["%d_%d" % [e.x, e.y]] = ids
	var f := p.faces()
	var crossed := {}
	var nf: Array[PackedInt32Array] = []
	var count := edges.size() if ring.closed else edges.size() - 1
	for i in count:
		var e1 := edges[i]
		var e2 := edges[(i + 1) % edges.size()]
		var fi := _quad_with(f, e1, e2)
		if fi < 0:
			continue
		crossed[fi] = true
		var n1: PackedInt32Array = new_on["%d_%d" % [e1.x, e1.y]]
		var n2: PackedInt32Array = new_on["%d_%d" % [e2.x, e2.y]]
		# Strips from the a-side (e1.x, e2.x) to the b-side, same winding as the quad.
		var poly := f[fi]
		var ia := Array(poly).find(e1.x)
		var same_dir := poly[(ia + 1) % 4] == e1.y
		var side_a := [e1.x] + Array(n1) + [e1.y]
		var side_b := [e2.x] + Array(n2) + [e2.y]
		for k in side_a.size() - 1:
			var strip := PackedInt32Array([side_a[k], side_a[k + 1], side_b[k + 1], side_b[k]])
			if not same_dir:
				strip.reverse()
			nf.append(strip)
	for fi in f.size():
		if crossed.has(fi):
			continue
		var poly := f[fi]
		var np := PackedInt32Array()
		for k in poly.size():
			var a := poly[k]
			var b := poly[(k + 1) % poly.size()]
			np.append(a)
			if new_on.has("%d_%d" % [a, b]):
				np.append_array(new_on["%d_%d" % [a, b]])
			elif new_on.has("%d_%d" % [b, a]):
				var rev: PackedInt32Array = new_on["%d_%d" % [b, a]].duplicate()
				rev.reverse()
				np.append_array(rev)
		nf.append(np)
	p.set_faces(nf)
	p.restore_paint(snap)
	for i in count:
		var n1: PackedInt32Array = new_on["%d_%d" % [edges[i].x, edges[i].y]]
		var n2: PackedInt32Array = new_on["%d_%d" % [edges[(i + 1) % edges.size()].x, edges[(i + 1) % edges.size()].y]]
		for k in n1.size():
			out.append(Vector2i(mini(n1[k], n2[k]), maxi(n1[k], n2[k])))
	return out


static func _quad_with(f: Array[PackedInt32Array], e1: Vector2i, e2: Vector2i) -> int:
	for fi in f.size():
		var poly := f[fi]
		if poly.size() == 4 and poly.has(e1.x) and poly.has(e1.y) and poly.has(e2.x) and poly.has(e2.y):
			return fi
	return -1


## A cut running around a tube between two neighbouring rings: inserts rings there.
static func _cut_tube_rings(p: ActorPiece, edges: Array[Vector2i], cuts: Array) -> bool:
	var ring_of := {}
	for r in p.rings.size():
		for v in p.rings[r]:
			ring_of[v] = r
	var lo := -1
	var flip := false
	for e in edges:
		if not ring_of.has(e.x) or not ring_of.has(e.y):
			return false
		var ra: int = ring_of[e.x]
		var rb: int = ring_of[e.y]
		if absi(ra - rb) != 1:
			return false
		if lo < 0:
			lo = mini(ra, rb)
			flip = ra > rb
		elif mini(ra, rb) != lo or (ra > rb) != flip:
			return false
	if edges.size() != p.sides():
		return false
	var a := p.rings[lo]
	var b := p.rings[lo + 1]
	var new_rings: Array[PackedInt32Array] = []
	for t in cuts:
		var tt: float = 1.0 - t if flip else t
		var nr := PackedInt32Array()
		for k in a.size():
			nr.append(p.vertices.size())
			p.vertices.append(p.vertices[a[k]].lerp(p.vertices[b[k]], tt))
		new_rings.append(nr)
	# Insert nearest-to-`lo` first.
	new_rings.sort_custom(func(x, y): return p.vertices[x[0]].distance_squared_to(p.vertices[a[0]]) < p.vertices[y[0]].distance_squared_to(p.vertices[a[0]]))
	for i in new_rings.size():
		p.rings.insert(lo + 1 + i, new_rings[i])
	p.rebuild_tube_faces()
	return true


# --- Rings (tubes) ------------------------------------------------------------------------

static func ring_scale(p: ActorPiece, ring: int, factor: Vector2, grid: float) -> void:
	var c := p.ring_centre(ring)
	for v in p.rings[ring]:
		var d := p.vertices[v] - c
		p.vertices[v] = snap_v(c + Vector3(d.x * factor.x, d.y, d.z * factor.y), grid)
	p.rebuild_tube_faces()


static func ring_move(p: ActorPiece, ring: int, delta: Vector3, grid: float) -> void:
	for v in p.rings[ring]:
		p.vertices[v] = snap_v(p.vertices[v] + delta, grid)
	p.rebuild_tube_faces()


static func ring_twist(p: ActorPiece, ring: int, degrees: float) -> void:
	var c := p.ring_centre(ring)
	var b := Basis(Vector3.UP, deg_to_rad(degrees))
	for v in p.rings[ring]:
		p.vertices[v] = c + b * (p.vertices[v] - c)
	p.rebuild_tube_faces()


## Adds a ring halfway to the next one (or past the last, continuing the tube).
static func ring_insert(p: ActorPiece, after: int, grid: float) -> int:
	var a := p.rings[after]
	var ring := PackedInt32Array()
	var last := after == p.rings.size() - 1
	for k in a.size():
		var pa := p.vertices[a[k]]
		var pb: Vector3
		if last:
			var prev := p.vertices[p.rings[after - 1][k]] if after > 0 else pa - Vector3(0, grid * 4.0, 0)
			pb = pa + (pa - prev) * 0.5
		else:
			pb = (pa + p.vertices[p.rings[after + 1][k]]) * 0.5
		ring.append(p.vertices.size())
		p.vertices.append(snap_v(pb, grid) if last else pb)
	p.rings.insert(after + 1, ring)
	p.rebuild_tube_faces()
	return after + 1


static func ring_delete(p: ActorPiece, ring: int) -> void:
	if p.rings.size() <= 2:
		return
	p.rings.remove_at(ring)
	p.rebuild_tube_faces()


## Re-samples every ring with `n` sides (keeping each ring's centre and radii).
static func set_sides(p: ActorPiece, n: int) -> void:
	n = clampi(n, 3, 16)
	var rings_out: Array[PackedInt32Array] = []
	var verts := PackedVector3Array()
	for r in p.rings:
		var c := Vector3.ZERO
		for v in r:
			c += p.vertices[v]
		c /= r.size()
		var rx := 0.0
		var rz := 0.0
		for v in r:
			rx = maxf(rx, absf(p.vertices[v].x - c.x))
			rz = maxf(rz, absf(p.vertices[v].z - c.z))
		var ring := PackedInt32Array()
		for k in n:
			var a := TAU * (k + 0.5) / n
			ring.append(verts.size())
			verts.append(c + Vector3(cos(a) * rx, 0.0, sin(a) * rz))
		rings_out.append(ring)
	p.vertices = verts
	p.rings = rings_out
	p.rebuild_tube_faces()


# --- Pieces -------------------------------------------------------------------------------

## Copy of `p` moved into `to_bone`'s frame (same place on the model at rest).
static func copy_to_bone(model: ActorModel, p: ActorPiece, to_bone: StringName) -> ActorPiece:
	var out := p.duplicate(true) as ActorPiece
	out.id = ""
	out.ensure_id()
	var from_xf := model.piece_transform(p)
	out.bone = to_bone
	var tb: BodyPlan.Bone = model.bones[model.bone_index(to_bone)]
	out.bone_length = tb.length()
	var to_xf := model.piece_transform(out).affine_inverse()
	var vs := PackedVector3Array()
	for v in p.vertices:
		vs.append(to_xf * (from_xf * v))
	out.vertices = vs
	return out


## Shell copy: the same piece pushed out along its normals (shirts, armour, gloves).
static func shell(p: ActorPiece, amount: float, grid: float) -> ActorPiece:
	var out := p.duplicate(true) as ActorPiece
	out.id = ""
	out.ensure_id()
	out.pins = {}
	var ids: Array[int] = []
	for i in out.vertices.size():
		ids.append(i)
	inflate(out, ids, amount, grid)
	if out.is_tube():
		out.rebuild_tube_faces()
	return out


## Lays vertices onto the nearest surface of the model's other pieces (rest pose), then
## `offset` out along that surface (capes, straps, pauldrons).
static func conform(model: ActorModel, piece_index: int, ids: Array[int], offset: float, grid: float) -> void:
	var p: ActorPiece = model.data.pieces[piece_index]
	var xf := model.piece_transform(p)
	var inv := xf.affine_inverse()
	var tris := []
	for t in model.picks:
		if t.piece != piece_index:
			tris.append(t)
	if tris.is_empty():
		return
	for v in _with_twins(p, ids):
		var w := xf * p.vertices[v]
		var best := w
		var best_n := Vector3.UP
		var best_d := INF
		for t in tris:
			var q := _closest_on_triangle(w, t.a, t.b, t.c)
			var d := w.distance_squared_to(q)
			if d < best_d:
				best_d = d
				best = q
				best_n = (t.b - t.a).cross(t.c - t.a).normalized()
		p.vertices[v] = snap_v(inv * (best + best_n * offset), grid)


static func _closest_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-12:
		return a
	n = n.normalized()
	var q := p - n * n.dot(p - a)
	# Inside test with barycentrics; otherwise nearest point on the edges.
	var bc := Geometry3D.get_closest_point_to_segment(q, a, b)
	var inside := (b - a).cross(q - a).dot(n) >= 0 and (c - b).cross(q - b).dot(n) >= 0 and (a - c).cross(q - c).dot(n) >= 0
	if inside:
		return q
	var cands := [bc, Geometry3D.get_closest_point_to_segment(q, b, c), Geometry3D.get_closest_point_to_segment(q, c, a)]
	var best: Vector3 = cands[0]
	for x: Vector3 in cands:
		if x.distance_squared_to(p) < best.distance_squared_to(p):
			best = x
	return best


# --- Vertex pins ----------------------------------------------------------------------------

## Pins each vertex of `verts` (piece `pi`) to the nearest vertex of piece `target` (rest,
## model space) and moves it there. Returns how many were pinned.
static func pin_to_nearest(model: ActorModel, pi: int, verts: Array[int], target: int) -> int:
	var p: ActorPiece = model.data.pieces[pi]
	var t: ActorPiece = model.data.pieces[target]
	if p == t:
		return 0
	t.ensure_id()
	var pxf := model.piece_transform(p)
	var txf := model.piece_transform(t)
	var inv := pxf.affine_inverse()
	var n := 0
	for v in verts:
		var w := pxf * p.vertices[v]
		var best := -1
		var best_d := INF
		for u in t.vertices.size():
			var d := w.distance_squared_to(txf * t.vertices[u])
			if d < best_d:
				best_d = d
				best = u
		if best < 0:
			continue
		p.pins[v] = [t.id, best]
		p.vertices[v] = inv * (txf * t.vertices[best])
		n += 1
	if p.is_tube():
		p.rebuild_tube_faces()
	return n


static func unpin(p: ActorPiece, verts: Array[int]) -> void:
	for v in verts:
		p.pins.erase(v)


## After a topology edit of `target` (`before` = its copy from before): pins on other
## pieces that point at it follow to the new vertex nearest the old one.
static func remap_pins_to(pieces: Array, before: ActorPiece, target: ActorPiece) -> void:
	for p: ActorPiece in pieces:
		if p == target:
			continue
		for v in p.pins:
			var pin: Array = p.pins[v]
			if pin[0] != target.id or pin[1] >= before.vertices.size():
				continue
			var old_pos := before.vertices[pin[1]]
			var best := -1
			var best_d := INF
			for u in target.vertices.size():
				var d := target.vertices[u].distance_squared_to(old_pos)
				if d < best_d:
					best_d = d
					best = u
			if best >= 0:
				p.pins[v] = [pin[0], best]
