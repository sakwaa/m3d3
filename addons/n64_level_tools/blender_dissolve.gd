@tool
class_name BlenderDissolve
## The build's geometry pass through Blender (Build & Play, export): every brush of the
## build's copy of a level goes through Blender's limited dissolve
## (tools/blender_dissolve/dissolve.py, run headless), which merges neighbouring faces in one
## plane and drops vertices left in the middle of straight edges. It never moves or adds a
## vertex, so everything kept per vertex (painted colour) survives as it was; faces only merge
## with faces of the same texture, UV placement, surface, bake mode, layer set, LOD and piece,
## never across a change in painted colour, exact UVs or corner colour (those edges stay), and
## faces with paint in their overlay masks stay as they are. Per-face data comes from the face
## each new face was merged from; per-corner data (exact UVs, corner colours) from the merged
## faces at each corner. Lighting and AO are not kept: the build bakes them afterwards, on the
## merged faces. Project settings: n64/build/blender_dissolve (on / off) and
## n64/build/blender_path (Blender 5's executable).

const SETTING := "n64/build/blender_dissolve"
const PATH_SETTING := "n64/build/blender_path"
const DEFAULT_BLENDER := "/Applications/Blender.app/Contents/MacOS/Blender"
const SCRIPT := "res://tools/blender_dissolve/dissolve.py"
## Faces within this many degrees of one plane merge.
const ANGLE := 1.0


static func blender() -> String:
	var p := String(ProjectSettings.get_setting(PATH_SETTING, DEFAULT_BLENDER))
	return p if FileAccess.file_exists(p) else ""


static func enabled() -> bool:
	return bool(ProjectSettings.get_setting(SETTING, true)) and blender() != ""


## Dissolves `data`'s brushes in place (the build's copy). Returns {before, after} (triangles
## of the brushes sent) or {error} when Blender couldn't be run.
static func dissolve(data: LevelData) -> Dictionary:
	var shade := _prop_shade(data)
	var meshes := []
	var jobs := []  # [brush, per-face group, corner info]
	var before := 0
	for b in data.brushes:
		if b == null or b.is_prop() or b.is_fence() or b.is_rope() or b.blend_file != "":
			continue
		if b.bake_mode == LevelBrush.BakeMode.COLLISION_ONLY or b.get_face_count() < 2:
			continue
		b.ensure_geometry()
		var job := _job(b, shade)
		meshes.append(job.mesh)
		jobs.append(job)
		for f in b.get_faces():
			before += f.size() - 2
	if meshes.is_empty():
		return {before = 0, after = 0}
	var dir := ProjectSettings.globalize_path("user://")
	var inp := dir.path_join("blender_dissolve_in.json")
	var outp := dir.path_join("blender_dissolve_out.json")
	DirAccess.remove_absolute(outp)
	var fh := FileAccess.open(inp, FileAccess.WRITE)
	fh.store_string(JSON.stringify({meshes = meshes}))
	fh.close()
	var log := []
	var code := OS.execute(blender(), ["-b", "--factory-startup", "--python", ProjectSettings.globalize_path(SCRIPT), "--",
		inp, outp, str(ANGLE)], log, true)
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(outp)) if FileAccess.file_exists(outp) else null
	if not parsed is Dictionary or (parsed.meshes as Array).size() != jobs.size():
		return {error = "Blender dissolve failed (exit %d): %s" % [code, "\n".join(log).right(800)]}
	var after := 0
	for i in jobs.size():
		after += _apply(jobs[i], parsed.meshes[i])
	return {before = before, after = after}


## Where props shade the ground (level-space XZ rects: a stall's or tree's footprint and
## SHADE_MARGIN round it, the height it reaches up to): faces lying up in them keep their
## vertices (stay out of the dissolve), so the baked lighting still has the vertices to
## draw the props' shadows with (merged into one big face, the ground under a stall would
## get none).
const SHADE_MARGIN := 1.5
const SHADE_KINDS := [PropSpec.Kind.STALL, PropSpec.Kind.TREE]


static func _prop_shade(data: LevelData) -> Array:
	var out := []
	for b in data.brushes:
		if b and b.is_prop() and b.prop.kind in SHADE_KINDS:
			var box: AABB = b.transform * b.local_aabb()
			out.append([Rect2(box.position.x, box.position.z, box.size.x, box.size.z).grow(SHADE_MARGIN), box.end.y])
	return out


## Whether brush `b`'s face `f` lies up under / beside a prop (`shade`: _prop_shade).
static func _shaded(b: LevelBrush, f: int, shade: Array) -> bool:
	if shade.is_empty() or (b.transform.basis * b.get_face_normal(f)).normalized().y < 0.7:
		return false
	var c := Vector3.ZERO
	var pts := b.get_face_points(f)
	for p in pts:
		c += b.transform * p
	c /= pts.size()
	for s in shade:
		if (s[0] as Rect2).has_point(Vector2(c.x, c.z)) and c.y < s[1]:
			return true
	return false


## What Blender gets for a brush: its vertices, faces, a merge group per face and the edges
## that must stay; plus what _apply needs to put the corner data back. Painted faces and
## faces in a prop's shade (_prop_shade) each stay whole.
static func _job(b: LevelBrush, shade := []) -> Dictionary:
	var faces := b.get_faces()
	var painted := _painted_faces(b)
	for f in faces.size():
		if _shaded(b, f, shade):
			painted[f] = true
	var cuv := b.has_corner_uvs()
	var ccol := b.has_corner_colors()
	var groups := PackedInt32Array()
	var first := 0  # each face's first corner
	for f in faces.size():
		if painted.has(f):
			groups.append(1000000 + f)  # its own
		else:
			# Exact UVs / corner colours: only faces whose values follow the same linear map
			# across the plane merge (the merged face then shows exactly what they did).
			var maps := []
			if cuv:
				maps.append(_linear_map(b, faces[f], first, func(c): return [b.corner_uvs[c].x, b.corner_uvs[c].y], 0.001))
			if ccol:
				maps.append(_linear_map(b, faces[f], first, func(c): var k: Color = b.corner_colors[c]; return [k.r, k.g, k.b], 1.0 / 255.0))
			groups.append(hash([b.get_face_texture(f), b.get_face_uv(f), b.get_face_surface(f),
				b.face_bake[f] if f < b.face_bake.size() else 0, b.get_face_lod(f), b.get_face_layer_set(f),
				b.get_face_piece(f), cuv, ccol, maps]))
		first += faces[f].size()
	# Per vertex: the corners using it ([face, corner]), and per corner its exact UV / colour.
	var at_vertex := {}
	var corner := 0
	for f in faces.size():
		for v in faces[f]:
			if not at_vertex.has(v):
				at_vertex[v] = []
			at_vertex[v].append([f, corner])
			corner += 1
	# Edges that stay: between faces whose corner data differs at either end, or across a
	# change in painted vertex colour.
	var edge_faces := {}
	corner = 0
	var corner_of := {}  # Vector2i(face, vertex) -> corner
	for f in faces.size():
		var ids: PackedInt32Array = faces[f]
		for k in ids.size():
			corner_of[Vector2i(f, ids[k])] = corner + k
			var e := Vector2i(mini(ids[k], ids[(k + 1) % ids.size()]), maxi(ids[k], ids[(k + 1) % ids.size()]))
			if not edge_faces.has(e):
				edge_faces[e] = []
			edge_faces[e].append(f)
		corner += ids.size()
	var sharp := []
	for e: Vector2i in edge_faces:
		var fs: Array = edge_faces[e]
		var keep := b.get_vertex_color(e.x) != b.get_vertex_color(e.y)
		if not keep and fs.size() == 2 and (cuv or ccol):
			for v in [e.x, e.y]:
				var c0: int = corner_of[Vector2i(fs[0], v)]
				var c1: int = corner_of[Vector2i(fs[1], v)]
				if (cuv and not b.corner_uvs[c0].is_equal_approx(b.corner_uvs[c1])) or (ccol and not b.corner_colors[c0].is_equal_approx(b.corner_colors[c1])):
					keep = true
		if keep:
			sharp.append([e.x, e.y])
	var verts := []
	for v in b.vertices:
		verts.append_array([v.x, v.y, v.z])
	var fl := []
	for f in faces:
		fl.append(Array(f))
	var g32 := []
	for g in groups:
		g32.append(posmod(g, 1 << 30))
	return {brush = b, mesh = {verts = verts, faces = fl, group = g32, sharp = sharp}, groups = groups, faces = faces,
		corner_of = corner_of, at_vertex = at_vertex, cuv = b.corner_uvs.duplicate() if cuv else PackedVector2Array(),
		ccol = b.corner_colors.duplicate() if ccol else PackedColorArray()}


## The linear map a face's corner values (`values`: corner -> Array of floats) follow across
## its plane, quantised by `step`: [face plane, for each value its gradient along two in-plane
## axes and its value at the origin]; [] when they don't fit one (then the face stays alone).
static func _linear_map(b: LevelBrush, ids: PackedInt32Array, first: int, values: Callable, step: float) -> Array:
	var pts: Array[Vector3] = []
	for v in ids:
		pts.append(b.vertices[v])
	var n := Vector3.ZERO
	for k in pts.size():
		n += pts[k].cross(pts[(k + 1) % pts.size()])
	if n.length() < 1e-8:
		return [randi()]
	n = n.normalized()
	var u := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var w := n.cross(u)
	# Least squares over every corner: value = gu * (p.u) + gw * (p.w) + c.
	var q: Array[Vector2] = []
	for p in pts:
		q.append(Vector2(p.dot(u), p.dot(w)))
	var vals := []
	for k in ids.size():
		vals.append(values.call(first + k))
	var out := [n.snapped(Vector3.ONE * 0.001), snappedf(n.dot(pts[0]), 0.001)]
	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	var sx := 0.0
	var sy := 0.0
	var cnt := float(q.size())
	for p in q:
		sxx += p.x * p.x
		sxy += p.x * p.y
		syy += p.y * p.y
		sx += p.x
		sy += p.y
	var m := Basis(Vector3(sxx, sxy, sx), Vector3(sxy, syy, sy), Vector3(sx, sy, cnt))
	if absf(m.determinant()) < 1e-10:
		return [randi()]
	var inv := m.inverse()
	for ch in (vals[0] as Array).size():
		var rhs := Vector3.ZERO
		for k in q.size():
			var val: float = vals[k][ch]
			rhs += Vector3(q[k].x * val, q[k].y * val, val)
		var g := inv * rhs
		# Every corner on the plane of values, else it isn't linear: the face stays alone.
		for k in q.size():
			if absf(g.x * q[k].x + g.y * q[k].y + g.z - float(vals[k][ch])) > step * 0.5:
				return [randi()]
		out.append_array([snappedf(g.x, step * 0.1), snappedf(g.y, step * 0.1), snappedf(g.z, step)])
	return out


## Faces with paint in an overlay mask (erased masks are kept, all zero: those don't count).
static func _painted_faces(b: LevelBrush) -> Dictionary:
	var out := {}
	for k: Vector2i in b.face_masks:
		if out.has(k.x):
			continue
		var img: Image = b.face_masks[k]
		if img == null:
			continue
		for byte in img.get_data():
			if byte > 8:
				out[k.x] = true
				break
	return out


## Puts Blender's faces on the brush. Returns its triangles now.
static func _apply(job: Dictionary, r: Dictionary) -> int:
	var b: LevelBrush = job.brush
	var old_faces: Array = job.faces
	var groups: PackedInt32Array = job.groups
	var painted := _painted_faces(b)
	var faces: Array[PackedInt32Array] = []
	var map := PackedInt32Array()
	var new_uv := PackedVector2Array()
	var new_col := PackedColorArray()
	var has_uv: bool = not (job.cuv as PackedVector2Array).is_empty()
	var has_col: bool = not (job.ccol as PackedColorArray).is_empty()
	var tris := 0
	for k in r.faces.size():
		var poly := PackedInt32Array(r.faces[k])
		var src := int(r.src[k])
		faces.append(poly)
		map.append(src)
		tris += poly.size() - 2
		if has_uv or has_col:
			# Each corner's data from a merged face at that vertex: one of src's group whose
			# middle lies inside this face (two regions of a group can meet at a vertex).
			var pts := PackedVector3Array()
			for v in poly:
				pts.append(b.vertices[v])
			var n := PolyUtil.newell_normal(pts).normalized()
			for v in poly:
				var pick := -1
				for fc in job.at_vertex.get(v, []):
					if groups[fc[0]] != groups[src]:
						continue
					if pick < 0:
						pick = fc[1]
					if _inside(b, old_faces[fc[0]], pts, n):
						pick = fc[1]
						break
				if pick < 0:
					pick = int(job.corner_of.get(Vector2i(src, v), 0))
				if has_uv:
					new_uv.append(job.cuv[pick])
				if has_col:
					new_col.append(job.ccol[pick])
	b.hand_edited = true
	b.set_faces(faces)
	b.remap_faces(map)
	# Masks: only faces with paint keep theirs (each such face stayed whole).
	var masks := {}
	for key: Vector2i in b.face_masks:
		if painted.has(map[key.x]) if key.x < map.size() else false:
			masks[key] = b.face_masks[key]
	b.face_masks = masks
	if has_uv:
		b.corner_uvs = new_uv
	if has_col:
		b.corner_colors = new_col
	b.corner_lighting = PackedColorArray()
	b.corner_lighting_keys = [] as Array[PackedColorArray]
	var had_ao := not b.vertex_ao.is_empty()
	b.drop_unused_vertices()
	if had_ao:
		# Re-baked by the build on the merged faces (open until then; non-empty so it is).
		var ao := PackedFloat32Array()
		ao.resize(b.vertices.size())
		ao.fill(1.0)
		b.vertex_ao = ao
	return tris


## Whether old face `face`'s middle lies inside the polygon `pts` (normal `n`).
static func _inside(b: LevelBrush, face: PackedInt32Array, pts: PackedVector3Array, n: Vector3) -> bool:
	var c := Vector3.ZERO
	for v in face:
		c += b.vertices[v]
	c /= face.size()
	var u := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var w := n.cross(u)
	var poly := PackedVector2Array()
	for p in pts:
		poly.append(Vector2(p.dot(u), p.dot(w)))
	return Geometry2D.is_point_in_polygon(Vector2(c.dot(u), c.dot(w)), poly)


# --- Generated meshes -----------------------------------------------------------------

## Meshes (props, stalls, signs, doorway trim, grass carpet, trees) through the same pass:
## each surface's triangles merge with neighbours in one plane where every vertex they share
## has the same UVs and colour (texture seams and colour changes stay), and vertices whose
## colour differs from a neighbour's stay too (gradients keep their vertices). The vertex
## arrays are kept as they are; only the triangles change, so every vertex attribute comes
## through untouched. Returns the meshes in the same order (a mesh unchanged where nothing
## merged or Blender failed), with {before, after} triangles under "stats".
static func dissolve_meshes(meshes: Array) -> Dictionary:
	var jobs := []
	var payload := []
	var before := 0
	for m in meshes:
		var job := _mesh_job(m)
		jobs.append(job)
		before += job.tris
		for sj in job.surfaces:
			payload.append(sj.mesh)
	var out := meshes.duplicate()
	if payload.is_empty() or blender() == "":
		return {meshes = out, before = before, after = before}
	var dir := ProjectSettings.globalize_path("user://")
	var inp := dir.path_join("blender_mesh_in.json")
	var outp := dir.path_join("blender_mesh_out.json")
	DirAccess.remove_absolute(outp)
	var fh := FileAccess.open(inp, FileAccess.WRITE)
	fh.store_string(JSON.stringify({meshes = payload}))
	fh.close()
	var log := []
	OS.execute(blender(), ["-b", "--factory-startup", "--python", ProjectSettings.globalize_path(SCRIPT), "--", inp, outp, str(ANGLE)], log, true)
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(outp)) if FileAccess.file_exists(outp) else null
	if not parsed is Dictionary or (parsed.meshes as Array).size() != payload.size():
		return {meshes = out, before = before, after = before, error = "Blender mesh pass failed: " + "\n".join(log).right(400)}
	var after := 0
	var k := 0
	for i in jobs.size():
		var job: Dictionary = jobs[i]
		if job.surfaces.is_empty():
			after += job.tris
			continue
		var results := []
		for sj in job.surfaces:
			results.append(parsed.meshes[k])
			k += 1
		var rebuilt := _mesh_rebuild(meshes[i], job, results)
		out[i] = rebuilt.mesh
		after += rebuilt.tris
	return {meshes = out, before = before, after = after}


static func _attr_key(a: Array, v: int) -> Array:
	var out := []
	for t in [Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_COLOR, Mesh.ARRAY_CUSTOM0]:
		var arr = a[t]
		if arr != null and v < arr.size():
			var x = arr[v]
			out.append(x.snapped(Vector2.ONE * 0.0001) if x is Vector2 else (Color(snappedf(x.r, 0.004), snappedf(x.g, 0.004), snappedf(x.b, 0.004), snappedf(x.a, 0.004)) if x is Color else x))
	return out


## Per surface: positions welded, triangles, and the edges that must stay.
static func _mesh_job(mesh: ArrayMesh) -> Dictionary:
	var job := {surfaces = [], tris = 0}
	if mesh == null:
		return job
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var a := mesh.surface_get_arrays(s)
		var pos: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(pos.size()))
		job.tris += idx.size() / 3
		var weld := {}
		var geo := PackedInt32Array()  # original vertex -> welded position
		var gpos := []
		for v in pos.size():
			var k := pos[v].snapped(Vector3.ONE * 0.0001)
			if not weld.has(k):
				weld[k] = gpos.size() / 3
				gpos.append_array([pos[v].x, pos[v].y, pos[v].z])
			geo.append(weld[k])
		var faces := []
		var corners := []  # per triangle: its original vertex indices
		var at := {}  # welded vertex -> [[triangle, original vertex], ...]
		for t in range(0, idx.size(), 3):
			var tri := [geo[idx[t]], geo[idx[t + 1]], geo[idx[t + 2]]]
			faces.append(tri)
			corners.append([idx[t], idx[t + 1], idx[t + 2]])
			for c in 3:
				if not at.has(tri[c]):
					at[tri[c]] = []
				at[tri[c]].append([faces.size() - 1, idx[t + c]])
		# Edges that stay: the triangles sharing an end don't agree on its UVs / colour, or the
		# two ends differ in colour (a gradient keeps its vertices).
		var sharp := []
		var seen := {}
		for fi in faces.size():
			for c in 3:
				var g0: int = faces[fi][c]
				var g1: int = faces[fi][(c + 1) % 3]
				var e := Vector2i(mini(g0, g1), maxi(g0, g1))
				if seen.has(e):
					continue
				seen[e] = true
				var keep := false
				for g in [g0, g1]:
					var ref := []
					for pair in at[g]:
						var key := _attr_key(a, pair[1])
						if ref.is_empty():
							ref = key
						elif key != ref:
							keep = true
							break
					if keep:
						break
				if not keep and a[Mesh.ARRAY_COLOR] != null:
					var c0: Color = a[Mesh.ARRAY_COLOR][corners[fi][c]]
					var c1: Color = a[Mesh.ARRAY_COLOR][corners[fi][(c + 1) % 3]]
					keep = not c0.is_equal_approx(c1)
				if keep:
					sharp.append([e.x, e.y])
		var groups := []
		groups.resize(faces.size())
		groups.fill(1)
		job.surfaces.append({surface = s, mesh = {verts = gpos, faces = faces, group = groups, sharp = sharp}, corners = corners,
			at = at, gpos = gpos})
	return job


## The mesh with each surface's triangles from Blender's faces (each face triangulated, its
## corners the original vertices of a merged triangle at each end).
static func _mesh_rebuild(mesh: ArrayMesh, job: Dictionary, results: Array) -> Dictionary:
	var out := ArrayMesh.new()
	var tris := 0
	var done := {}
	for r in results.size():
		done[job.surfaces[r].surface] = r
	for s in mesh.get_surface_count():
		var a := mesh.surface_get_arrays(s)
		var fmt := mesh.surface_get_format(s)
		if done.has(s):
			var sj: Dictionary = job.surfaces[done[s]]
			var res: Dictionary = results[done[s]]
			var pos: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var idx := PackedInt32Array()
			for k in res.faces.size():
				var poly: Array = (res.faces[k] as Array).map(func(g): return int(g))  # (JSON numbers are floats)
				var src := int(res.src[k])
				var src_c: Array = sj.corners[src]
				var src_n := (pos[src_c[1]] - pos[src_c[0]]).cross(pos[src_c[2]] - pos[src_c[0]])
				var pts := PackedVector3Array()
				for g in poly:
					pts.append(Vector3(sj.gpos[g * 3], sj.gpos[g * 3 + 1], sj.gpos[g * 3 + 2]))
				var n := PolyUtil.newell_normal(pts).normalized()
				# Each corner: an original vertex at that position, from a merged triangle
				# lying inside this face (two regions can meet at a point).
				var orig := PackedInt32Array()
				for g in poly:
					var pick := -1
					for pair in sj.at[g]:
						var tc: Array = sj.corners[pair[0]]
						var c := (pos[tc[0]] + pos[tc[1]] + pos[tc[2]]) / 3.0
						if pick < 0:
							pick = pair[1]
						if _in_poly(c, pts, n):
							pick = pair[1]
							break
					orig.append(pick)
				var order := PolyUtil.triangulate(pts, n)
				var flip := n.dot(src_n) < 0.0
				for t in range(0, order.size(), 3):
					if flip:
						idx.append_array([orig[order[t]], orig[order[t + 2]], orig[order[t + 1]]])
					else:
						idx.append_array([orig[order[t]], orig[order[t + 1]], orig[order[t + 2]]])
			a[Mesh.ARRAY_INDEX] = idx
		tris += (a[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3 if a[Mesh.ARRAY_INDEX] != null else (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		out.add_surface_from_arrays(mesh.surface_get_primitive_type(s), a, [], {}, fmt & ~((1 << Mesh.ARRAY_MAX) - 1))
		out.surface_set_material(s, mesh.surface_get_material(s))
		out.surface_set_name(s, mesh.surface_get_name(s))
	return {mesh = out, tris = tris}


static func _in_poly(p: Vector3, pts: PackedVector3Array, n: Vector3) -> bool:
	var u := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var w := n.cross(u)
	var poly := PackedVector2Array()
	for q in pts:
		poly.append(Vector2(q.dot(u), q.dot(w)))
	return Geometry2D.is_point_in_polygon(Vector2(p.dot(u), p.dot(w)), poly)
