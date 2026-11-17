@tool
class_name DecalBuilder
extends RefCounted
## Decals (LevelDecal) made into meshes: each projected along its normal onto the level's
## visible faces, clipped to its box, lifted a little off the surface. Each vertex takes the
## surface's painted colour, AO and baked light at that point (per time key), the same data
## the level's own mesh carries, so a decal sits in the level's lighting, weather and time of
## day. The editor shows them live (LevelRoot); the build bakes them (ExportBake).

## Decals sit on the surface (no lift): the shader passes them by depth as the RDP's
## ZMODE_DEC did (decal_depth: the share of their distance moved towards the camera, so they
## hold at any distance and never float off the surface at a grazing angle).
const LIFT := 0.0
const DEPTH := 0.002


## One ArrayMesh (a surface per decal texture, materials set) for `root`'s decals in
## `root`'s space, or null when there are none. `decals`: a subset (default: all).
static func build(root: LevelRoot, decals: Array = []) -> ArrayMesh:
	var data := root.data
	if data == null:
		return null
	if decals.is_empty():
		decals = data.decals
	var timed := LevelData.mode_is_timed(data.lighting_mode)
	var hybrid := data.lighting_mode == LevelData.LightingMode.BAKED_VERTEX_DYNAMIC
	var baked := data.lighting_mode == LevelData.LightingMode.BAKED_VERTEX
	var keyed := timed or hybrid
	var scale := data.vertex_color_scale()
	var by_tex := {}  # texture -> {pos, nrm, uv, col, keys[4]}
	var to_root := root.global_transform.affine_inverse()
	for d: LevelDecal in decals:
		if d == null or d.texture == null:
			continue
		var tris := project(root, d, to_root)
		if tris.is_empty():
			continue
		if not by_tex.has(d.texture):
			var kb: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray(), PackedByteArray(), PackedByteArray()]
			by_tex[d.texture] = {pos = PackedVector3Array(), nrm = PackedVector3Array(), uv = PackedVector2Array(),
				uv2 = PackedVector2Array(), col = PackedColorArray(), keys = kb}
		var s: Dictionary = by_tex[d.texture]
		for v in tris:
			s.pos.append(v.p)
			s.nrm.append(v.n)
			s.uv.append(v.uv)
			s.uv2.append(Vector2(-1, -1))
			var c: Color = v.paint
			if baked:
				c = Color(c.r * v.light.r, c.g * v.light.g, c.b * v.light.b, c.a)
			s.col.append(Color(clampf(c.r / scale, 0.0, 1.0), clampf(c.g / scale, 0.0, 1.0), clampf(c.b / scale, 0.0, 1.0), v.ao))
			if keyed:
				for k in 4:
					var lc: Color = (v.keys[k] if timed else (v.light if k == 0 else Color.WHITE))
					var b: PackedByteArray = s.keys[k]
					# (key 0's alpha: the host brush's coverage ID, as LevelBaker writes it -
					# the decal counts as the surface it lies on)
					var id_byte: int = (int(v.brush) % 7 + 1) if k == 0 and v.has("brush") else 255
					b.append_array(PackedByteArray([clampi(roundi(lc.r * 255.0), 0, 255), clampi(roundi(lc.g * 255.0), 0, 255),
						clampi(roundi(lc.b * 255.0), 0, 255), id_byte]))
	if by_tex.is_empty():
		return null
	var mesh := ArrayMesh.new()
	for tex: Texture2D in by_tex:
		var s: Dictionary = by_tex[tex]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = s.pos
		arrays[Mesh.ARRAY_NORMAL] = s.nrm
		arrays[Mesh.ARRAY_TEX_UV] = s.uv
		arrays[Mesh.ARRAY_TEX_UV2] = s.uv2
		arrays[Mesh.ARRAY_COLOR] = s.col
		var flags := 0
		if keyed:
			for k in 4:
				arrays[Mesh.ARRAY_CUSTOM0 + k] = s.keys[k]
			flags = LevelBrush.KEY_FORMAT
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material(tex, data))
	return mesh


## The paint shader set up for a decal: its texture once over the decal (no tiling,
## anti-tiling, variation or overlays), cut out by alpha, lit like the level.
static func material(tex: Texture2D, data: LevelData) -> ShaderMaterial:
	var mat := PaintAtlas.make_material(tex, data, [], 0, true)
	mat.set_shader_parameter(&"base_tile", 1.0)
	mat.set_shader_parameter(&"base_anti", Vector2.ZERO)
	mat.set_shader_parameter(&"base_var", Vector3(0.0, 8.0, 0.0))
	mat.set_shader_parameter(&"base_scroll", Vector4.ZERO)
	mat.set_shader_parameter(&"layer_count", 0)
	mat.set_shader_parameter(&"decal_depth", DEPTH)
	mat.set_meta(&"decal", true)
	return mat


## `d` projected onto `root`'s faces: triangle corners [{p, n, uv, paint, ao, light, keys}],
## in root space (`to_root`: root's global transform inverse).
static func project(root: LevelRoot, d: LevelDecal, to_root: Transform3D) -> Array:
	var out := []
	var f := d.frame()
	var o: Vector3 = f[0]
	var r: Vector3 = f[1]
	var u: Vector3 = f[2]
	var n: Vector3 = f[3]
	var hw := d.size.x * 0.5
	var hh := d.size.y * 0.5
	var box := AABB(o, Vector3.ZERO)
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			for sz in [-1, 1]:
				box = box.expand(o + r * hw * sx + u * hh * sy + n * d.depth * sz)
	var min_dot := cos(deg_to_rad(d.max_angle))
	var aspect := float(d.texture.get_height()) / maxf(d.texture.get_width(), 1.0)
	for bi in root.data.brushes.size():
		var b: LevelBrush = root.data.brushes[bi]
		if b == null or b.is_fence() or b.is_rope() or root.is_brush_hidden(b):
			continue
		var xf := to_root * root.brush_global_transform(b)
		if not (xf * b.local_aabb()).intersects(box):
			continue
		var nb := xf.basis.inverse().transposed()
		var paint := b.full_corner_colors()
		for face in b.get_face_count():
			if not b.face_visual(face) or b.get_face_lod(face) in [LevelBrush.LOD_FAR, LevelBrush.LOD_DETAIL_FAR]:
				continue
			var fn := (nb * b.get_face_normal(face)).normalized()
			if fn.dot(n) < min_dot:
				continue
			var ids := b.get_face_vertex_ids(face)
			var start := b.get_face_start(face)
			var pts := PackedVector3Array()
			var local := PackedVector3Array()
			for vi in ids:
				var p := xf * b.vertices[vi]
				pts.append(p)
				var dp := p - o
				local.append(Vector3(dp.dot(r), dp.dot(u), dp.dot(n)))
			var clipped := _clip(local, hw, hh, d.depth)
			if clipped.size() < 3:
				continue
			# Corner data of the face, interpolated at each clipped point.
			var corners := []
			for k in ids.size():
				var c := start + k
				var keys := []
				for s in 4:
					keys.append(b.get_corner_key_light(s, c))
				corners.append({paint = paint[c] if c < paint.size() else Color.WHITE, ao = b.get_vertex_ao(ids[k]),
					light = b.get_corner_light(c), keys = keys})
			var verts := []
			for q in clipped:
				var p := o + r * q.x + u * q.y + n * q.z
				var v := _sample(pts, corners, p)
				v.p = p + fn * LIFT
				v.n = fn
				v.brush = bi
				v.uv = Vector2(q.x / d.size.x + 0.5, (0.5 - q.y / d.size.y) * aspect)
				verts.append(v)
			# Fan, wound clockwise for Godot (our polygons are counter-clockwise).
			for i in range(1, verts.size() - 1):
				out.append(verts[0])
				out.append(verts[i + 1])
				out.append(verts[i])
	return out


## A convex-or-not polygon clipped to the box |x| <= hw, |y| <= hh, |z| <= hd.
static func _clip(poly: PackedVector3Array, hw: float, hh: float, hd: float) -> PackedVector3Array:
	for plane in [[0, 1.0, hw], [0, -1.0, hw], [1, 1.0, hh], [1, -1.0, hh], [2, 1.0, hd], [2, -1.0, hd]]:
		var axis: int = plane[0]
		var sgn: float = plane[1]
		var lim: float = plane[2]
		var out := PackedVector3Array()
		var n := poly.size()
		if n == 0:
			return out
		for i in n:
			var a := poly[i]
			var c := poly[(i + 1) % n]
			var da := lim - a[axis] * sgn
			var dc := lim - c[axis] * sgn
			if da >= 0.0:
				out.append(a)
			if (da >= 0.0) != (dc >= 0.0):
				out.append(a.lerp(c, da / (da - dc)))
		poly = out
	return poly


## The face's corner data at point `p` on it (barycentric in the fan triangle holding it).
static func _sample(pts: PackedVector3Array, corners: Array, p: Vector3) -> Dictionary:
	var best := [0, 1, 2]
	var bw := Vector3(1, 0, 0)
	var worst := -INF
	for i in range(1, pts.size() - 1):
		var w := _bary(p, pts[0], pts[i], pts[i + 1])
		var m := minf(w.x, minf(w.y, w.z))
		if m > worst:
			worst = m
			best = [0, i, i + 1]
			bw = w
		if m >= -0.001:
			break
	bw = bw.clamp(Vector3.ZERO, Vector3.ONE)
	bw /= maxf(bw.x + bw.y + bw.z, 0.0001)
	var a: Dictionary = corners[best[0]]
	var b: Dictionary = corners[best[1]]
	var c: Dictionary = corners[best[2]]
	var keys := []
	for s in 4:
		keys.append(a.keys[s] * bw.x + b.keys[s] * bw.y + c.keys[s] * bw.z)
	return {paint = a.paint * bw.x + b.paint * bw.y + c.paint * bw.z, ao = a.ao * bw.x + b.ao * bw.y + c.ao * bw.z,
		light = a.light * bw.x + b.light * bw.y + c.light * bw.z, keys = keys}


static func _bary(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
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
