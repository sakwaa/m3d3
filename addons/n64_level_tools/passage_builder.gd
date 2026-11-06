@tool
extends RefCounted
## Passage tool helpers: carve the opening in the wall a passage is placed on, and build
## the corridor shell (side walls + ceiling) behind it.

## Cuts a width x height opening (floor-up, centred on `xf`, -Z = outward) through every
## wall surface of `root` parallel to it, from the clicked face up to `depth` deep (so
## thick walls open fully). Edge loops are cut first so paint elsewhere stays in place.
## Set piece brushes also keep the cut (with `tag`) to cut again after each pull.
## Returns [{brush, before, after}] with the geometry already applied.
## How far past the trim's outline the wall gets its second cut (see carve_brush).
const TRIM_FALLOFF := 0.5
## Above the trim: the first row's lift off the top bar, and where the shadow ends.
const TRIM_TOP_LIFT := 0.12
const TRIM_TOP_FALLOFF := 0.35
## Bumped when carve_brush cuts differently: passages carved before get cut again on load.
const CARVE_VERSION := 3


static func carve_opening(root: LevelRoot, xf: Transform3D, width: float, height: float, depth := 2.0, tag := &"",
		trim := Vector2.ZERO, shape := Vector2.ZERO) -> Array:
	var out := []
	for brush in root.data.brushes:
		if brush == null:
			continue
		var bxf := root.brush_global_transform(brush)
		var before := brush.snapshot()
		if not carve_brush(brush, bxf, xf, width, height, depth, trim, shape):
			continue
		var after := brush.snapshot()
		if brush.blend_file != "":
			before.cuts = brush.cuts
			after.cuts = brush.cuts + [{tag = tag, xf = bxf.affine_inverse() * xf, width = width, height = height, depth = depth,
				trim = trim, shape = shape}]
		out.append({brush = brush, before = before, after = after})
	return out


## carve_opening on one brush (`bxf`: where it stands, in `xf`'s space). False when no
## wall surface of it is in the opening (left as it was). `trim`: the trim's reach (side,
## top; zero = none): the wall is also cut along its outline, so the wall vertices it covers
## (dark in baked AO) only shade faces under it, not long streaks up the wall.
static func carve_brush(brush: LevelBrush, bxf: Transform3D, xf: Transform3D, width: float, height: float, depth := 2.0,
		trim := Vector2.ZERO, shape := Vector2.ZERO) -> bool:
	const EPS := 0.02
	var c := xf.origin
	var t := xf.basis.x.normalized()          # along the wall
	var inward := xf.basis.z.normalized()     # into the room
	var planes := [[t, t.dot(c) - width * 0.5], [t, t.dot(c) + width * 0.5],
		[Vector3.UP, c.y], [Vector3.UP, c.y + height]]
	# Plus a row TRIM_FALLOFF further out: the trim's contact shadow on the wall fades out
	# there instead of across the whole face.
	if trim.x > 0.0:
		for off in [trim.x, trim.x + TRIM_FALLOFF]:
			planes.append_array([[t, t.dot(c) - width * 0.5 - off], [t, t.dot(c) + width * 0.5 + off]])
	if trim.y > 0.0:
		# Above the top bar the first row sits a little up the wall: right at the bar's edge
		# the bar blocks every downward ray, much darker than beside the posts.
		for off in [trim.y + TRIM_TOP_LIFT, trim.y + TRIM_TOP_FALLOFF]:
			planes.append([Vector3.UP, c.y + height + off])
	# Any wall surface of this brush inside the opening's box?
	if _opening_faces(brush, bxf, c, t, inward, width, height, depth, EPS, true).is_empty():
		return false
	var rects := {}
	for f in brush.get_face_count():
		rects[f] = brush.get_face_planar_rect(f)
	var verts := brush.vertices
	var faces := brush.get_faces()
	var map := PackedInt32Array()
	for f in faces.size():
		map.append(f)
	var sources: Array[PackedInt32Array] = []
	for i in verts.size():
		sources.append(PackedInt32Array([i]))
	for pl in planes:
		# World plane n.p = d in brush-local space.
		var nl: Vector3 = bxf.basis.transposed() * pl[0]
		var dl: float = pl[1] - pl[0].dot(bxf.origin)
		var len := nl.length()
		var cut := BrushOps.cut_plane(verts, faces, nl / len, dl / len)
		verts = cut.verts
		faces = cut.faces
		for pair in cut.new_vertices:
			var src := PackedInt32Array(sources[pair.x])
			src.append_array(sources[pair.y])
			sources.append(src)
		var nm := PackedInt32Array()
		for f in cut.map.size():
			nm.append(map[cut.map[f]])
		map = nm
	# Arched: cut along the arch (and the trim's outer arch) inside the opening's box only,
	# segment by segment through the faces each segment crosses (no lines across the wall).
	var top := int(shape.x)
	if top != OpeningShape.Top.FLAT:
		var arcs := [OpeningShape.arch_points(width, height, top, shape.y)]
		if trim.y > 0.0:
			arcs.append(OpeningShape.arch_points(width, height, top, shape.y, trim.y))
		var spring := OpeningShape.spring_of(width, height, top, shape.y)
		var to_local := bxf.affine_inverse()
		# The springing line across the opening (and trim) only.
		var reach := width * 0.5 + maxf(trim.x, trim.y)
		var lines := [[Vector2(-reach, spring), Vector2(reach, spring)]]
		for arc: PackedVector2Array in arcs:
			for k in arc.size() - 1:
				lines.append([arc[k], arc[k + 1]])
		for ln in lines:
			var a2: Vector2 = ln[0]
			var b2: Vector2 = ln[1]
			var wa := c + t * a2.x + Vector3.UP * a2.y
			var wb := c + t * b2.x + Vector3.UP * b2.y
			# Plane through the segment, perpendicular to the wall.
			var n := (wb - wa).cross(inward).normalized()
			if n == Vector3.ZERO:
				continue
			var only := {}
			for f in faces.size():
				var poly := PackedVector2Array()
				var pts := PackedVector3Array()
				for v in faces[f]:
					pts.append(bxf * verts[v])
				var fn := PolyUtil.newell_normal(pts).normalized()
				if absf(fn.dot(inward)) < 0.99:
					continue
				var behind := -inward.dot(pts[0] - c)
				if behind < -EPS or behind > depth:
					continue
				for w in pts:
					poly.append(Vector2(t.dot(w - c), w.y - c.y))
				if not Geometry2D.intersect_polyline_with_polygon(PackedVector2Array([a2, b2]), poly).is_empty():
					only[f] = true
			if only.is_empty():
				continue
			var nl := (to_local.basis * n).normalized()
			var dl := nl.dot(to_local * wa)
			var cut := BrushOps.cut_plane(verts, faces, nl, dl, only)
			verts = cut.verts
			faces = cut.faces
			for pair in cut.new_vertices:
				var src := PackedInt32Array(sources[pair.x])
				src.append_array(sources[pair.y])
				sources.append(src)
			var nm := PackedInt32Array()
			for f in cut.map.size():
				nm.append(map[cut.map[f]])
			map = nm
	brush.hand_edited = true
	brush.vertices = verts
	brush.set_faces(faces)
	brush.remap_faces(map)
	brush.blend_vertex_colors(sources)
	var child_parents := {}
	for f in map.size():
		child_parents[f] = rects[map[f]]
	brush.crop_child_masks(child_parents)
	var doomed := _opening_faces(brush, bxf, c, t, inward, width, height, depth, EPS, false,
		OpeningShape.outline(width, height, top, shape.y) if top != OpeningShape.Top.FLAT else PackedVector2Array())
	var del := BrushOps.delete_faces(brush.vertices, brush.get_faces(), doomed)
	brush.vertices = del.verts
	brush.set_faces(del.faces)
	brush.remap_faces(del.map)
	brush.remap_vertex_colors(del.vertex_map)
	return true


## Faces of `brush` parallel to the wall whose centre lies inside the opening box (or,
## with `overlap`, that merely overlap it: the check before cutting, when big faces still
## extend past the opening).
static func _opening_faces(brush: LevelBrush, bxf: Transform3D, c: Vector3, t: Vector3, inward: Vector3,
		width: float, height: float, depth: float, eps: float, overlap := false, outline := PackedVector2Array()) -> Array[int]:
	var out: Array[int] = []
	var nb := bxf.basis.inverse().transposed()
	for f in brush.get_face_count():
		var n := (nb * brush.get_face_normal(f)).normalized()
		if absf(n.dot(inward)) < 0.99:
			continue
		var pts := brush.get_face_points(f)
		if overlap:
			var lo := Vector3.INF
			var hi := -Vector3.INF
			for p in pts:
				var w := bxf * p
				var q := Vector3(t.dot(w - c), w.y - c.y, -inward.dot(w - c))
				lo = lo.min(q)
				hi = hi.max(q)
			if hi.x > -width * 0.5 + eps and lo.x < width * 0.5 - eps and hi.y > eps and lo.y < height - eps \
					and hi.z > -eps and lo.z < depth:
				out.append(f)
			continue
		var m := Vector3.ZERO
		for p in pts:
			m += bxf * p
		m /= pts.size()
		var along := t.dot(m - c)
		var up := m.y - c.y
		var behind := -inward.dot(m - c)
		if absf(along) < width * 0.5 - eps and up > eps and up < height - eps and behind > -eps and behind < depth \
				and (outline.is_empty() or Geometry2D.is_point_in_polygon(Vector2(along, up), outline)):
			out.append(f)
	return out


## Corridor walls + ceiling from the opening outward (passage local: x across, y up, -z
## out), facing inward, ~1 m cells so lighting / AO have vertices; `wall_texture` is the
## clicked wall's texture index (read before carving, which renumbers its faces).
static func corridor_shell(root: LevelRoot, xf: Transform3D, width: float, height: float, depth: float,
		wall_brush: LevelBrush, wall_texture: int, shape := Vector2.ZERO) -> LevelBrush:
	var w := width * 0.5
	var d := depth
	var nz := maxi(ceili(d), 1)
	# The cross-section from the bottom left, up the left side, over the top (flat or the
	# arch), down the right side; ~1 m pieces on the sides and a flat top.
	var top := int(shape.x)
	var side_h := OpeningShape.spring_of(width, height, top, shape.y)
	var ny := maxi(ceili(side_h), 1)
	var profile := PackedVector2Array()
	for iy in ny + 1:
		profile.append(Vector2(-w, side_h * iy / ny))
	if top == OpeningShape.Top.FLAT:
		var nx := maxi(ceili(width), 1)
		for ix in range(1, nx):
			profile.append(Vector2(-w + width * ix / nx, height))
		profile.append(Vector2(w, height))
	else:
		var arch := OpeningShape.arch_points(width, height, top, shape.y)
		for k in range(1, arch.size()):
			profile.append(arch[k])
	for iy in range(ny - 1, -1, -1):
		profile.append(Vector2(w, side_h * iy / ny))
	var verts := PackedVector3Array()
	var faces: Array[PackedInt32Array] = []
	for iz in nz:
		var z0 := -d * iz / nz
		var z1 := -d * (iz + 1) / nz
		for k in profile.size() - 1:
			var p0 := profile[k]
			var p1 := profile[k + 1]
			if p0.is_equal_approx(p1):
				continue
			# Faces inward (left side +x, top down, right side -x).
			var i := verts.size()
			verts.append_array([Vector3(p0.x, p0.y, z0), Vector3(p0.x, p0.y, z1), Vector3(p1.x, p1.y, z1), Vector3(p1.x, p1.y, z0)])
			faces.append(PackedInt32Array([i, i + 1, i + 2, i + 3]))
	var merged := BrushOps.weld_vertices(verts, faces)
	var b := LevelBrush.new()
	b.vertices = merged.verts
	b.set_faces(merged.faces)
	b.hand_edited = true
	b.material = wall_brush.material if wall_brush else null
	b.transform = root.global_transform.affine_inverse() * xf
	if wall_texture >= 0:
		var tex := PackedInt32Array()
		tex.resize(b.get_face_count())
		tex.fill(wall_texture)
		b.face_textures = tex
	return b



## UVs (metres, like the level's projection) for a face of an arched lining (`pts`: its
## corners, opening-local), unwrapped along the arch so its slanted faces aren't stretched:
## v carries on from the side wall's (-y) by the length round the arch from that side's
## springing, u runs through the wall like the side wall's. Empty for faces not on the arch.
static func arch_lining_uvs(pts: Array, width: float, height: float, shape: Vector2, tweak: Vector4) -> PackedVector2Array:
	var out := PackedVector2Array()
	var top := int(shape.x)
	if top == OpeningShape.Top.FLAT:
		return out
	var n := PolyUtil.newell_normal(PackedVector3Array(pts)).normalized()
	if absf(n.x) > 0.999 or absf(n.y) > 0.999:
		return out  # side walls (and flat bits) keep the projection
	var arch := OpeningShape.arch_points(width, height, top, shape.y)
	var spring := OpeningShape.spring_of(width, height, top, shape.y)
	var cx := 0.0
	for p in pts:
		cx += p.x
	var left := cx < 0.0
	# Arch length from the face's side's springing to each point (nearest arch point).
	var lengths := PackedFloat32Array([0.0])
	for k in range(1, arch.size()):
		lengths.append(lengths[k - 1] + arch[k].distance_to(arch[k - 1]))
	var total := lengths[lengths.size() - 1]
	var scale := LevelBrush.uv_scale(tweak)
	for p in pts:
		var best := 0
		for k in arch.size():
			if Vector2(p.x, p.y).distance_squared_to(arch[k]) < Vector2(p.x, p.y).distance_squared_to(arch[best]):
				best = k
		var s := lengths[best] if left else total - lengths[best]
		var u: float = -p.z if left else p.z
		out.append(Vector2(u, -(spring + s)) / scale + Vector2(tweak.x, tweak.y))
	return out


## Closes the opening carved by carve_opening: in every brush of `root` (except those in
## `skip`), the open edge loop(s) lying on the opening's rectangle become a face again,
## one per wall surface (front and back of thick walls). Texture / winding come from the
## neighbouring wall faces. Set piece brushes also drop the cuts made with `tag`.
## Returns [{brush, before, after}] with the faces already added.
static func fill_opening(root: LevelRoot, xf: Transform3D, width: float, height: float, skip: Array, tag := &"",
		shape := Vector2.ZERO) -> Array:
	var out := []
	for brush in root.data.brushes:
		if brush == null or brush in skip:
			continue
		var before := brush.snapshot()
		var changed := fill_brush(brush, root.brush_global_transform(brush), xf, width, height, shape)
		var cut := brush.blend_file != "" and tag != &"" and brush.cuts.any(func(k): return k.tag == tag)
		if not changed and not cut:
			continue
		var after := brush.snapshot()
		if cut:
			before.cuts = brush.cuts
			after.cuts = brush.cuts.filter(func(k): return k.tag != tag)
		out.append({brush = brush, before = before, after = after})
	return out


## fill_opening on one brush (`bxf`: where it stands). False when it had no hole there.
static func fill_brush(brush: LevelBrush, bxf: Transform3D, xf: Transform3D, width: float, height: float,
		shape := Vector2.ZERO) -> bool:
	const DEPTH := 2.0
	const EPS := 0.02
	var to_passage := xf.affine_inverse()
	# Vertices on the opening's outline (rectangle or arch), grouped by wall surface (depth).
	var outline := OpeningShape.outline(width, height, int(shape.x), shape.y)
	var groups := {}
	for i in brush.vertices.size():
		var q := to_passage * (bxf * brush.vertices[i])
		if q.z > EPS or q.z < -DEPTH - EPS or q.y < -EPS or q.y > height + EPS or absf(q.x) > width * 0.5 + EPS:
			continue
		var on_rim := false
		var q2 := Vector2(q.x, q.y)
		for k in outline.size():
			var a2 := outline[k]
			var b2 := outline[(k + 1) % outline.size()]
			if Geometry2D.get_closest_point_to_segment(q2, a2, b2).distance_to(q2) < EPS:
				on_rim = true
				break
		if on_rim:
			var key := snappedf(q.z, 0.01)
			if not groups.has(key):
				groups[key] = [] as Array[int]
			groups[key].append(i)
	var changed := false
	for key in groups:
		var ring: Array[int] = groups[key]
		# Only the vertices on open edges (the hole's rim) form the loop.
		var edges := BrushOps.boundary_edges_among(brush.get_faces(), ring)
		var rim: Array[int] = []
		for e in edges:
			for v in [e.x, e.y]:
				if not v in rim:
					rim.append(v)
		if rim.size() < 3:
			continue
		var toward := bxf.basis.inverse() * xf.basis.z
		var made := BrushOps.make_face(brush.vertices, brush.get_faces(), rim, toward)
		if made.has("error"):
			continue
		brush.set_faces(made.faces)
		brush.remap_faces(made.map, false)
		changed = true
	return changed



## Corridor floor centred on (0, 0, -depth / 2) of the passage, ~1 m cells on each axis so
## its threshold vertices line up with a metre grid floor (no T-junctions, matching vertex
## lighting / AO across the seam). Textured like `floor_brush`'s `floor_face`.
static func corridor_floor(width: float, depth: float, floor_brush: LevelBrush, floor_face: int) -> LevelBrush:
	var nx := maxi(roundi(width), 1)
	var nz := maxi(roundi(depth), 1)
	var verts := PackedVector3Array()
	var faces: Array[PackedInt32Array] = []
	for iz in nz + 1:
		for ix in nx + 1:
			verts.append(Vector3(-width * 0.5 + width * ix / nx, 0.0, -depth * 0.5 + depth * iz / nz))
	for iz in nz:
		for ix in nx:
			var a := iz * (nx + 1) + ix
			# Counter-clockwise seen from above, so the face normal points up (+Y).
			faces.append(PackedInt32Array([a, a + nx + 1, a + nx + 2, a + 1]))
	var b := LevelBrush.new()
	b.shape = BrushShapes.Shape.GRID
	b.size = Vector3(width, 0, depth)
	b.vertices = verts
	b.set_faces(faces)
	b.hand_edited = true
	if floor_brush:
		b.material = floor_brush.material
		var tex := PackedInt32Array()
		tex.resize(b.get_face_count())
		tex.fill(floor_brush.get_face_texture(floor_face))
		b.face_textures = tex
	return b


## Wall facing -Z around a `w` x `h` doorway at the bottom centre, `side` metres either
## side and `top` above (~1 m cells for vertex lighting), textured like `wall_brush`.
static func doorway_wall(w: float, h: float, side: float, top: float, wall_brush: LevelBrush, wall_tex: int) -> LevelBrush:
	var verts := PackedVector3Array()
	var faces: Array[PackedInt32Array] = []
	var cols := [-w * 0.5 - side, -w * 0.5, w * 0.5, w * 0.5 + side]
	var total := h + top
	var rows := []
	for i in maxi(ceili(total), 1) + 1:
		rows.append(minf(total * i / maxi(ceili(total), 1), total))
	if not h in rows:
		rows.append(h)
		rows.sort()
	for ci in 3:
		for ri in rows.size() - 1:
			var x0: float = cols[ci]
			var x1: float = cols[ci + 1]
			var y0: float = rows[ri]
			var y1: float = rows[ri + 1]
			if ci == 1 and y1 <= h + 0.001:
				continue  # the doorway
			var i := verts.size()
			# Counter-clockwise seen from -Z, so the normal faces the room behind.
			verts.append_array([Vector3(x0, y0, 0), Vector3(x0, y1, 0), Vector3(x1, y1, 0), Vector3(x1, y0, 0)])
			faces.append(PackedInt32Array([i, i + 1, i + 2, i + 3]))
	var merged := BrushOps.weld_vertices(verts, faces)
	var b := LevelBrush.new()
	b.vertices = merged.verts
	b.set_faces(merged.faces)
	b.hand_edited = true
	b.material = wall_brush.material if wall_brush else null
	if wall_tex >= 0:
		var tex := PackedInt32Array()
		tex.resize(b.get_face_count())
		tex.fill(wall_tex)
		b.face_textures = tex
	return b


## The UV tweak that makes a brush at `xf` (level space) continue the floor texture of a
## brush at `source_xf` with face tweak `t` (floors: its projection turned and shifted by
## the difference between the two brushes; scale and follow-slope kept).
static func continued_uv(t: Vector4, source_xf: Transform3D, xf: Transform3D) -> Vector4:
	var m := source_xf.affine_inverse() * xf  # this brush's local -> the source's local
	var phi := atan2(m.basis.x.z, m.basis.x.x)
	var w := deg_to_rad(fposmod(t.w, 360.0))
	var shift := Vector2(m.origin.x, m.origin.z).rotated(w) / LevelBrush.uv_scale(t)
	return Vector4(t.x + shift.x, t.y + shift.y, t.z, fposmod(rad_to_deg(w + phi), 360.0))


## Average painted colour of a face's corners.
static func face_color(brush: LevelBrush, face: int) -> Color:
	var start := brush.get_face_start(face)
	var ids := brush.get_face_vertex_ids(face)
	var c := Color(0, 0, 0, 0)
	for k in ids.size():
		c += brush.get_corner_color(start + k, ids[k])
	c /= maxf(ids.size(), 1)
	return Color(c.r, c.g, c.b, 1.0)


## A face's corners (level space, through its brush transform) and their shades (painted
## rgb, AO alpha), for shade_at.
static func face_shades(brush: LevelBrush, face: int) -> Array:
	var start := brush.get_face_start(face)
	var ids := brush.get_face_vertex_ids(face)
	var pts := PackedVector3Array()
	var shades := PackedColorArray()
	for k in ids.size():
		pts.append(brush.transform * brush.vertices[ids[k]])
		shades.append(brush.get_corner_shade(start + k, ids[k]))
	return [pts, shades]


## The shade a polygon (corner points + shades) has at `p`: interpolated over its triangle
## fan (as the mesh draws it), clamped to the nearest triangle outside the polygon.
static func shade_at(points: PackedVector3Array, shades: PackedColorArray, p: Vector3) -> Color:
	var n := PolyUtil.newell_normal(points).normalized()
	var q := p - n * n.dot(p - points[0])
	var best := Color.WHITE
	var best_out := INF
	for i in range(1, points.size() - 1):
		var a := points[0]
		var b := points[i]
		var c := points[i + 1]
		var bc := _barycentric(q, a, b, c)
		var outside := -minf(minf(bc.x, bc.y), bc.z)
		if outside < best_out:
			best_out = outside
			var w := Vector3(maxf(bc.x, 0.0), maxf(bc.y, 0.0), maxf(bc.z, 0.0))
			w /= maxf(w.x + w.y + w.z, 1e-6)
			best = shades[0] * w.x + shades[i] * w.y + shades[i + 1] * w.z
	return best


static func _barycentric(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var den := d00 * d11 - d01 * d01
	if absf(den) < 1e-12:
		return Vector3(1, 0, 0)
	var v := (d11 * d20 - d01 * d21) / den
	var w := (d00 * d21 - d01 * d20) / den
	return Vector3(1.0 - v - w, v, w)


## Gives the room floor `brush` vertices where the corridor floor meets it: cuts its faces
## touching the threshold along the corridor's cell lines (`xf`: the passage in world space,
## -Z out; `width` split into `cells`), so both floors share the same vertices on that edge
## and anything worked out per vertex (fog, baked shade, AO) matches across: no seam.
## Big floor faces would otherwise smear those values over tens of metres. Returns
## {before, after} snapshots (applied), or {} when nothing was cut.
static func cut_threshold(root: LevelRoot, brush: LevelBrush, xf: Transform3D, width: float, cells: int) -> Dictionary:
	if brush == null or brush.blend_file != "":
		return {}
	var bxf := root.brush_global_transform(brush)
	var inv := bxf.affine_inverse()
	var t := xf.basis.x.normalized()
	var inward := xf.basis.z.normalized()
	var before := brush.snapshot()
	var verts := brush.vertices
	var faces := brush.get_faces()
	var map := PackedInt32Array()
	for f in faces.size():
		map.append(f)
	var sources: Array[PackedInt32Array] = []
	for i in verts.size():
		sources.append(PackedInt32Array([i]))
	var changed := false
	for i in cells + 1:
		var at := xf.origin + t * (-width * 0.5 + width * i / cells)
		# Faces of the floor at this point of the threshold (just inside the room).
		var probe := inv * (at + inward * 0.05)
		var only := {}
		for f in faces.size():
			var pts := PackedVector3Array()
			for v in faces[f]:
				pts.append(verts[v])
			var n := PolyUtil.newell_normal(pts).normalized()
			if n.y < 0.7 or absf(n.dot(probe - pts[0])) > 0.05:
				continue
			var poly := PackedVector2Array()
			for p in pts:
				poly.append(Vector2(p.x, p.z))
			if Geometry2D.is_point_in_polygon(Vector2(probe.x, probe.z), poly):
				only[f] = true
		if only.is_empty():
			continue
		var nl := (bxf.basis.transposed() * t).normalized()
		var dl := nl.dot(inv * at)
		var r := BrushOps.cut_plane(verts, faces, nl, dl, only)
		if r.split.is_empty():
			continue
		changed = true
		verts = r.verts
		faces = r.faces
		for pair in r.new_vertices:
			var src := PackedInt32Array(sources[pair.x])
			src.append_array(sources[pair.y])
			sources.append(src)
		var nm := PackedInt32Array()
		for f in r.map.size():
			nm.append(map[r.map[f]])
		map = nm
	if not changed:
		return {}
	var rects := {}
	for f in brush.get_face_count():
		rects[f] = brush.get_face_planar_rect(f)
	brush.hand_edited = true
	brush.vertices = verts
	brush.set_faces(faces)
	brush.remap_faces(map)
	brush.blend_vertex_colors(sources)
	var child_parents := {}
	for f in map.size():
		child_parents[f] = rects[map[f]]
	brush.crop_child_masks(child_parents)
	return {before = before, after = brush.snapshot()}
