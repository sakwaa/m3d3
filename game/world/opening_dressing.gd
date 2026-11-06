@tool
class_name OpeningDressing
extends Resource
## Casing / trim around a door or passage opening: a left post, a right post and a top bar,
## each its own faces (front + extruded edges), textured with one texture. Butt joints put
## the top bar over the posts (horizontal seams); mitre joints meet at 45° (diagonal seams).
## Save as a .tres to reuse the same trim on several doors / passages.

enum Joint { BUTT, MITRE }
enum Sides { BOTH, FRONT, BACK }

const SHADER := preload("res://addons/n64_runtime/shaders/n64_textured.gdshader")
## Slice length along each piece (posts along y, top bar along x).
const SEGMENT := 0.5

## Used for the fronts and the extruded edges (UVs follow the project texel density).
@export var texture: Texture2D:
	set(value):
		texture = value
		emit_changed()
## Texture size on the trim: 1 = the same texel density as the level's walls (the
## texture's world size), 2 = twice as big, 0.5 = half.
@export_range(0.1, 8.0, 0.05, "or_greater") var texture_scale := 1.0:
	set(value):
		texture_scale = maxf(value, 0.01)
		emit_changed()
## Colour the trim is shaded with (like painted vertex colour: multiplies the texture).
@export var tint := Color.WHITE:
	set(value):
		tint = value
		emit_changed()
@export var joint := Joint.BUTT:
	set(value):
		joint = value
		emit_changed()
## Doors only: which wall face(s) get the trim (passages dress their room side).
@export var sides := Sides.BOTH:
	set(value):
		sides = value
		emit_changed()
## How far the side posts reach out sideways from the opening.
@export_range(0.02, 2.0, 0.01) var side_width := 0.25:
	set(value):
		side_width = value
		emit_changed()
## How tall the top bar is above the opening.
@export_range(0.02, 2.0, 0.01) var top_height := 0.3:
	set(value):
		top_height = value
		emit_changed()
## How far the side posts stand out from the wall.
@export_range(0.0, 1.0, 0.01) var side_depth := 0.06:
	set(value):
		side_depth = value
		emit_changed()
## How far the top bar stands out from the wall (more than the posts for a lintel).
@export_range(0.0, 1.0, 0.01) var top_depth := 0.12:
	set(value):
		top_depth = value
		emit_changed()


## Builds the trim into `mi` (mesh + material) and `shape` (collision) for an opening of
## width x height (local x centred, y from the floor). `faces`: [[z of the wall face,
## +1 / -1 = direction the trim sticks out], ...].
## `ao`: baked AO per mesh vertex (from the editor's Bake AO), applied when it matches.
static func apply(d: OpeningDressing, mi: MeshInstance3D, shape: CollisionShape3D, width: float, height: float,
		faces: Array, ao := PackedFloat32Array(), opening := Vector2.ZERO) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tile := d._tile()
	for f in faces:
		for piece in d._pieces(width, height, opening):
			if piece.has("joints"):
				for pf in _prism_faces(piece.outline, f[0], f[1] * piece.depth, [], 0, piece.joints):
					_add_face(st, pf.pts, pf.normal, tile)
				continue
			# ~SEGMENT m slices along the piece: vertices for baked AO / lighting gradients.
			for band in _slices(piece.outline, piece.axis):
				_add_prism(st, band.outline, f[0], f[1] * piece.depth, tile, band.cuts, band.axis)
	st.index()
	var mesh := st.commit()
	var has_ao := false
	if not ao.is_empty() and mesh.get_surface_count() > 0:
		var arrays := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.size() == ao.size():
			var cols := PackedColorArray()
			cols.resize(ao.size())
			for i in ao.size():
				cols[i] = Color(1, 1, 1, ao[i])
			arrays[Mesh.ARRAY_COLOR] = cols
			mesh = ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			has_ao = true
	mi.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter(&"albedo_texture", d.texture)
	mat.set_shader_parameter(&"has_texture", d.texture != null)
	mat.set_shader_parameter(&"albedo_color", d.tint if d.texture else Color(0.42, 0.36, 0.3) * d.tint)
	mat.set_shader_parameter(&"vertex_ao_in_alpha", has_ao)
	mi.material_override = mat
	shape.shape = mesh.create_trimesh_shape() if mesh.get_surface_count() > 0 else null


## Fingerprint of everything that shapes the trim (not its texture): baked AO is kept
## only while this matches what it was baked for.
func shape_key(width: float, height: float, faces: Array, shape := Vector2.ZERO) -> int:
	return hash([joint, side_width, top_height, side_depth, top_depth, width, height, faces, shape])


## Front outlines (local x / y, counter-clockwise seen from +Z) and depth of each piece.
## Arched openings (`shape`: OpeningShape.Top, rise): posts up to the springing and a ring
## of voussoirs top_height thick over the arch (`joints`: their shared edges).
func _pieces(width: float, height: float, shape := Vector2.ZERO) -> Array:
	var hw := width * 0.5
	var sw := side_width
	if int(shape.x) != OpeningShape.Top.FLAT:
		var spring := OpeningShape.spring_of(width, height, int(shape.x), shape.y)
		var inner := OpeningShape.arch_points(width, height, int(shape.x), shape.y)
		var outer := OpeningShape.arch_points(width, height, int(shape.x), shape.y, top_height)
		var out := [
			{outline = [Vector2(-hw - sw, 0), Vector2(-hw, 0), Vector2(-hw, spring), Vector2(-hw - sw, spring)], depth = side_depth, axis = 1},
			{outline = [Vector2(hw, 0), Vector2(hw + sw, 0), Vector2(hw + sw, spring), Vector2(hw, spring)], depth = side_depth, axis = 1},
		]
		for k in inner.size() - 1:
			var joints := []
			if k > 0:
				joints.append([inner[k], outer[k]])
			if k < inner.size() - 2:
				joints.append([inner[k + 1], outer[k + 1]])
			out.append({outline = [outer[k], inner[k], inner[k + 1], outer[k + 1]], depth = top_depth, joints = joints})
		return out
	var top := height + top_height
	if joint == Joint.MITRE:
		return [
			{outline = [Vector2(-hw - sw, 0), Vector2(-hw, 0), Vector2(-hw, height), Vector2(-hw - sw, top)], depth = side_depth, axis = 1},
			{outline = [Vector2(hw, 0), Vector2(hw + sw, 0), Vector2(hw + sw, top), Vector2(hw, height)], depth = side_depth, axis = 1},
			{outline = [Vector2(-hw, height), Vector2(hw, height), Vector2(hw + sw, top), Vector2(-hw - sw, top)], depth = top_depth, axis = 0},
		]
	return [
		{outline = [Vector2(-hw - sw, 0), Vector2(-hw, 0), Vector2(-hw, height), Vector2(-hw - sw, height)], depth = side_depth, axis = 1},
		{outline = [Vector2(hw, 0), Vector2(hw + sw, 0), Vector2(hw + sw, height), Vector2(hw, height)], depth = side_depth, axis = 1},
		{outline = [Vector2(-hw - sw, height), Vector2(hw + sw, height), Vector2(hw + sw, top), Vector2(-hw - sw, top)], depth = top_depth, axis = 0},
	]


## One trim piece: its outline pushed out from the wall plane z0 by `depth` (signed), with
## a front face and a face along every outline edge (the wall side stays open).
## Splits a convex outline into bands ~SEGMENT long along `axis` (0 x, 1 y). Each band
## knows its cut coordinates, so no side faces are built along internal cuts.
static func _slices(outline: Array, axis: int) -> Array:
	var lo := INF
	var hi := -INF
	for p in outline:
		lo = minf(lo, p[axis])
		hi = maxf(hi, p[axis])
	var n := maxi(ceili((hi - lo) / SEGMENT - 0.001), 1)
	var out := []
	for i in n:
		var a := lerpf(lo, hi, float(i) / n)
		var b := lerpf(lo, hi, float(i + 1) / n)
		var band := _clip(_clip(outline, axis, a, 1.0), axis, b, -1.0)
		if band.size() >= 3:
			var cuts := []
			if i > 0:
				cuts.append(a)
			if i < n - 1:
				cuts.append(b)
			out.append({outline = band, cuts = cuts, axis = axis})
	return out


## Keeps the part of a convex polygon with side * (p[axis] - c) >= 0.
static func _clip(poly: Array, axis: int, c: float, side: float) -> Array:
	var out := []
	for i in poly.size():
		var p: Vector2 = poly[i]
		var q: Vector2 = poly[(i + 1) % poly.size()]
		var dp := side * (p[axis] - c)
		var dq := side * (q[axis] - c)
		if dp >= 0.0:
			out.append(p)
		if (dp > 0.0 and dq < 0.0) or (dp < 0.0 and dq > 0.0):
			out.append(p.lerp(q, dp / (dp - dq)))
	return out


static func _add_prism(st: SurfaceTool, outline: Array, z0: float, depth: float, tile: Vector2, cuts := [], axis := 0) -> void:
	for f in _prism_faces(outline, z0, depth, cuts, axis):
		_add_face(st, f.pts, f.normal, tile)


## The prism's faces: [{pts: Array[Vector3] (convex), normal, uvs}], front first. `uvs`
## (metres): the front projected like the level's walls, each edge face unwrapped (along the
## outline x across the depth), so slanted edges (arch voussoirs) aren't stretched.
## `joints`: outline edges ([a, b]) shared with a neighbouring piece (no face built there).
static func _prism_faces(outline: Array, z0: float, depth: float, cuts := [], axis := 0, joints := []) -> Array:
	var z1 := z0 + depth
	var out := Vector3(0, 0, signf(depth) if depth != 0.0 else 1.0)
	var front: Array[Vector3] = []
	for p in outline:
		front.append(Vector3(p.x, p.y, z1))
	var front_uvs := PackedVector2Array()
	for p in front:
		front_uvs.append(Vector2(p.x * out.z, -p.y))
	var faces := [{pts = front, normal = out, uvs = front_uvs}]
	if absf(depth) < 0.0005:
		return faces
	var n := outline.size()
	var along := 0.0  # outline length so far: edge faces' u runs on round the piece
	for i in n:
		var a: Vector2 = outline[i]
		var b: Vector2 = outline[(i + 1) % n]
		var length := a.distance_to(b)
		var u0 := along
		along += length
		if _on_cut(a, b, cuts, axis) or _is_joint(a, b, joints):
			continue
		var edge_out := Vector3(b.y - a.y, -(b.x - a.x), 0.0).normalized()  # outward of a CCW outline
		faces.append({pts = [Vector3(a.x, a.y, z0), Vector3(b.x, b.y, z0), Vector3(b.x, b.y, z1), Vector3(a.x, a.y, z1)] as Array[Vector3],
			normal = edge_out,
			uvs = PackedVector2Array([Vector2(u0, z0), Vector2(u0 + length, z0), Vector2(u0 + length, z1), Vector2(u0, z1)])})
	return faces


## The trim as polygons ([{pts: Array[Vector3] (convex, any winding), normal}]), for level
## geometry (passage brushes build it into the level, so it's lit and baked like the walls).
## `shape`: (OpeningShape.Top, arch rise) of the opening.
static func polygons(d: OpeningDressing, width: float, height: float, faces: Array, shape := Vector2.ZERO) -> Array:
	var out := []
	for f in faces:
		for piece in d._pieces(width, height, shape):
			if piece.has("joints"):
				out.append_array(_prism_faces(piece.outline, f[0], f[1] * piece.depth, [], 0, piece.joints))
				continue
			for band in _slices(piece.outline, piece.axis):
				out.append_array(_prism_faces(band.outline, f[0], f[1] * piece.depth, band.cuts, band.axis))
	for poly in out:
		var uvs: PackedVector2Array = poly.uvs
		for i in uvs.size():
			uvs[i] /= d.texture_scale
		poly.uvs = uvs
	return out


static func _is_joint(a: Vector2, b: Vector2, joints: Array) -> bool:
	for j in joints:
		if (a.is_equal_approx(j[0]) and b.is_equal_approx(j[1])) or (a.is_equal_approx(j[1]) and b.is_equal_approx(j[0])):
			return true
	return false


## Edge lying on an internal slice cut (both ends on the same cut line of `axis`).
static func _on_cut(a: Vector2, b: Vector2, cuts: Array, axis: int) -> bool:
	for c in cuts:
		if absf(a[axis] - c) < 1e-5 and absf(b[axis] - c) < 1e-5:
			return true
	return false


## Convex polygon facing `normal`; UVs planar in metres / tile like the level's world UVs.
static func _add_face(st: SurfaceTool, pts: Array[Vector3], normal: Vector3, tile: Vector2) -> void:
	var nn := Vector3.ZERO
	for i in pts.size():
		nn += pts[i].cross(pts[(i + 1) % pts.size()])
	if nn.dot(normal) < 0.0:
		pts.reverse()
	var a := normal.abs()
	for i in range(1, pts.size() - 1):
		# Godot front faces are clockwise: emit the counter-clockwise fan reversed.
		for p in [pts[0], pts[i + 1], pts[i]]:
			var uv: Vector2
			if a.z >= a.x and a.z >= a.y:
				uv = Vector2(p.x * signf(normal.z), -p.y)
			elif a.x >= a.y:
				uv = Vector2(-p.z * signf(normal.x), -p.y)
			else:
				uv = Vector2(p.x, p.z * signf(normal.y))
			st.set_normal(normal)
			st.set_uv(uv / tile)
			st.add_vertex(p)


## Metres per texture repeat from the project texel density (same as level textures).
func _tile() -> Vector2:
	if texture == null:
		return Vector2.ONE
	var density := maxf(float(ProjectSettings.get_setting("n64/textures/texels_per_metre", 32)), 1.0)
	return Vector2(texture.get_size()) / density * texture_scale
