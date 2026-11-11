@tool
class_name GroundLOD
extends RefCounted
## The ground's far stand-in, made by the bake: per chunk cell, the ground (upward faces of
## plain brushes with LevelBrush.ground_lod) merged into a few large polygons that follow
## its height only, coloured and lit from the original corners (timed lighting keys too),
## with everything painted on it (base textures, overlays) flattened into one small texture
## laid once over the cell. Past the ground LOD distance it replaces the detailed ground,
## which is seen at a grazing angle there anyway: one surface per cell instead of one per
## texture and overlay, and a few dozen triangles instead of hundreds. Collision stays on
## the detailed ground.

## Far ground texels per metre (4 = a quarter metre each), a power of two across a cell.
const TEXELS_PER_M := 4.0
const SETTING := "n64/build/ground_lod_distance"


static func distance() -> float:
	return ProjectSettings.get_setting(SETTING, 40.0)


## Whether a baked polygon counts as ground (then it's near-only, the far stand-in covers it).
static func is_ground(poly: Dictionary, src: Dictionary) -> bool:
	var brush: LevelBrush = src.brush
	if brush == null or not brush.ground_lod or not poly.visual or poly.get("cutout", false) or poly.material != null:
		return false
	if poly.get("lod", LevelBrush.LOD_ALWAYS) != LevelBrush.LOD_ALWAYS or poly.normal.normalized().y < 0.7:
		return false
	return not (brush.is_house() or brush.opening_spec() != null or brush.is_fence() or brush.is_rope() or brush.blend_file != "")


## Ground polygons reaching past their cell (a big plaza top) are cut along the cell
## lines first, each piece in its own cell: near and far then swap together, cell by cell.
## New corners get colours and lighting keys interpolated from the polygon's own.
static func split_to_cells(polys: Array[Dictionary], sources: Array[Dictionary], origin: Vector3, cell_size: Vector2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for poly in polys:
		if not is_ground(poly, sources[poly.src]):
			out.append(poly)
			continue
		poly.pts = world_pts(poly, sources[poly.src])
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for p: Vector3 in poly.pts:
			lo = lo.min(Vector2(p.x, p.z))
			hi = hi.max(Vector2(p.x, p.z))
		var c0 := Vector2i(floori((lo.x - origin.x) / cell_size.x), floori((lo.y - origin.z) / cell_size.y))
		var c1 := Vector2i(floori((hi.x - origin.x - 0.001) / cell_size.x), floori((hi.y - origin.z - 0.001) / cell_size.y))
		if c0 == c1:
			poly.cell = c0
			out.append(poly)
			continue
		var src: Dictionary = sources[poly.src]
		var inv: Transform3D = src.xf.affine_inverse()
		var outline := PackedVector2Array()
		for p: Vector3 in poly.pts:
			outline.append(Vector2(p.x, p.z))
		var heights := PackedColorArray()  # corner heights, blended like the colours
		for p: Vector3 in poly.pts:
			heights.append(Color(p.y, 0, 0, 0))
		var verts: PackedVector3Array = src.verts  # new corners go on the source's (bake-only) list
		for cx in range(c0.x, c1.x + 1):
			for cz in range(c0.y, c1.y + 1):
				var rect := PackedVector2Array([Vector2(origin.x + cx * cell_size.x, origin.z + cz * cell_size.y),
					Vector2(origin.x + (cx + 1) * cell_size.x, origin.z + cz * cell_size.y),
					Vector2(origin.x + (cx + 1) * cell_size.x, origin.z + (cz + 1) * cell_size.y),
					Vector2(origin.x + cx * cell_size.x, origin.z + (cz + 1) * cell_size.y)])
				for piece: PackedVector2Array in Geometry2D.intersect_polygons(outline, rect):
					if piece.size() < 3 or absf(_area(piece)) < 0.01:
						continue
					# Same winding as the original (seen from above).
					if signf(_area(piece)) != signf(_area(outline)):
						piece.reverse()
					var np := poly.duplicate()
					var pts := PackedVector3Array()
					var ids := PackedInt32Array()
					var cc := PackedColorArray()
					var kcs := []
					for s in poly.key_colors.size():
						kcs.append(PackedColorArray())
					for q in piece:
						# Height from the polygon's own corners, not its plane: sculpted ground
						# isn't flat, and a cut corner must stay on the edge its neighbour shares.
						var bw := _weights(outline, q)
						var w := Vector3(q.x, _blend(heights, bw).r, q.y)
						pts.append(w)
						ids.append(verts.size())
						verts.append(inv * w)
						cc.append(_blend(poly.corner_colors, bw))
						for s in poly.key_colors.size():
							kcs[s].append(_blend(poly.key_colors[s], bw))
					np.pts = pts
					np.ids = ids
					np.corner_colors = cc
					np.key_colors = kcs
					np.exact_uvs = PackedVector2Array()
					np.cell = Vector2i(cx, cz)
					out.append(np)
		src.verts = verts
	return out


## A baked polygon's corners in world space, from its ids (after the bake merges faces
## its `pts` are still the first face's; `ids` are the merged outline).
static func world_pts(poly: Dictionary, src: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in poly.ids:
		out.append(src.xf * src.verts[i])
	return out


## Area of a source face, from its triangles (what actually gets drawn).
static func _tri_area(src: Dictionary, ids: PackedInt32Array) -> float:
	var pts := PackedVector3Array()
	for i in ids:
		pts.append(src.verts[i])
	var n := PolyUtil.newell_normal(pts)
	if n == Vector3.ZERO:
		return 0.0
	var tris := PolyUtil.triangulate(pts, n)
	var a := 0.0
	for t in range(0, tris.size(), 3):
		a += (pts[tris[t + 1]] - pts[tris[t]]).cross(pts[tris[t + 2]] - pts[tris[t]]).length() * 0.5
	return a


static func _area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		a += p[i].cross(p[(i + 1) % p.size()])
	return a * 0.5


## Weights of `outline`'s corners for point `q` inside it (barycentric in the fan triangle
## holding it; nearest corner if none does).
static func _weights(outline: PackedVector2Array, q: Vector2) -> Dictionary:
	for i in range(1, outline.size() - 1):
		var a := outline[0]
		var b := outline[i]
		var c := outline[i + 1]
		var d := (b - a).cross(c - a)
		if absf(d) < 1e-9:
			continue
		var u := (b - q).cross(c - q) / d
		var v := (c - q).cross(a - q) / d
		var w := 1.0 - u - v
		if u >= -1e-4 and v >= -1e-4 and w >= -1e-4:
			return {0: u, i: v, i + 1: w}
	var best := 0
	for i in outline.size():
		if outline[i].distance_squared_to(q) < outline[best].distance_squared_to(q):
			best = i
	return {best: 1.0}


static func _blend(colors: PackedColorArray, weights: Dictionary) -> Color:
	if colors.is_empty():
		return Color.WHITE
	var c := Color(0, 0, 0, 0)
	for i in weights:
		c += colors[mini(i, colors.size() - 1)] * weights[i]
	return c


## Marks the ground polygons near-only (LOD_GROUND_NEAR) and returns them by cell.
static func mark(polys: Array[Dictionary], sources: Array[Dictionary]) -> Dictionary:
	var by_cell := {}
	for poly in polys:
		if is_ground(poly, sources[poly.src]):
			poly.lod = LevelBrush.LOD_GROUND_NEAR
			if not by_cell.has(poly.cell):
				by_cell[poly.cell] = []
			by_cell[poly.cell].append(poly)
	return by_cell


## Adds a far ground surface per cell to the bake's `surfaces` (and its material to
## `materials`). `origin` / `cell_size`: the chunk grid (LevelBaker._assign_cells).
static func add_far(by_cell: Dictionary, sources: Array[Dictionary], data: LevelData, origin: Vector3, cell_size: Vector2,
		atlas_size: Vector2i, masks: Array[ImageTexture], keyed: bool, surfaces: Dictionary, materials: Dictionary,
		stats: Dictionary) -> void:
	var images := {}  # Texture2D -> Image (RGBA8)
	var neutral := LevelBrush.scaled_color(Color.WHITE, data.vertex_color_scale())
	for cell: Vector2i in by_cell:
		var ground: Array = by_cell[cell]
		var x0 := origin.x + cell.x * cell_size.x
		var z0 := origin.z + cell.y * cell_size.y
		var skey := [cell, LevelBrush.LOD_GROUND_FAR, "ground_far"]
		var key := "ground_far:%d:%d" % [cell.x, cell.y]
		var surf := {cell = cell, lod = LevelBrush.LOD_GROUND_FAR, key = key, pos = PackedVector3Array(), nrm = PackedVector3Array(),
			uv = PackedVector2Array(), uv2 = PackedVector2Array(), col = PackedColorArray(), idx = PackedInt32Array(), weld = {},
			keys = [PackedByteArray(), PackedByteArray(), PackedByteArray(), PackedByteArray()]}
		var uv2 := PaintAtlas.empty_uv(atlas_size)
		# Geometry: each source's ground in this cell merged by plane (lighting ignored).
		var by_src := {}
		for poly in ground:
			if not by_src.has(poly.src):
				by_src[poly.src] = []
			by_src[poly.src].append(poly)
		for si in by_src:
			var src: Dictionary = sources[si]
			var group: Array = by_src[si]
			var faces: Array[PackedInt32Array] = []
			var compat := []
			var corner := {}  # vertex id -> [colour, key colours]
			for poly in group:
				faces.append(poly.ids)
				compat.append(0)
				for k in poly.ids.size():
					if corner.has(poly.ids[k]):
						continue
					var kc := []
					for s in 4:
						var arr: PackedColorArray = poly.key_colors[s] if s < poly.key_colors.size() else PackedColorArray()
						kc.append(arr[k] if arr.size() == poly.ids.size() else Color.WHITE)
					var cc: PackedColorArray = poly.corner_colors
					corner[poly.ids[k]] = [cc[k] if cc.size() == poly.ids.size() else Color.WHITE, kc]
			var merged := BrushOps.merge_coplanar(src.verts, faces, compat)
			# A merged outline that doesn't triangulate back to the same area (a hole, a
			# pinch) would leave a gap: then this group keeps its own faces.
			var want := 0.0
			for f in faces:
				want += _tri_area(src, f)
			var got := 0.0
			for f in merged.faces:
				got += _tri_area(src, f)
			var use: Array = merged.faces if absf(got - want) <= maxf(want * 0.005, 0.01) else faces
			for ids: PackedInt32Array in use:
				var pts := PackedVector3Array()
				for i in ids:
					pts.append(src.xf * src.verts[i])
				var n := PolyUtil.newell_normal(pts)
				if n == Vector3.ZERO:
					continue
				var tris := PolyUtil.triangulate(pts, n)
				for t in range(0, tris.size(), 3):
					if (pts[tris[t + 1]] - pts[tris[t]]).cross(pts[tris[t + 2]] - pts[tris[t]]).length_squared() < 1e-10:
						continue
					for k: int in [0, 2, 1]:
						var i: int = tris[t + k]
						var p := pts[i]
						var c: Array = corner.get(ids[i], [Color.WHITE, [Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE]])
						# The paint is in the texture: the corner keeps only its AO (and the lighting keys).
						var col := Color(neutral.r, neutral.g, neutral.b, (c[0] as Color).a)
						surf.idx.append(LevelBaker._weld(surf, p, n, Vector2(p.x - x0, p.z - z0), uv2, col, c[1] if keyed else []))
					stats.ground_far_tris = stats.get("ground_far_tris", 0) + 1
		if surf.idx.is_empty():
			continue
		surfaces[skey] = surf
		var tex := ImageTexture.create_from_image(_flatten(ground, sources, data, Vector2(x0, z0), cell_size, images, neutral))
		var mat := PaintAtlas.make_material(tex, data, masks, 0, false)
		mat.set_shader_parameter(&"base_tile", cell_size.x)
		mat.set_shader_parameter(&"base_var", 0.0)
		mat.set_shader_parameter(&"base_anti", Vector2.ZERO)
		materials[key] = mat


## The cell's ground seen from above: base textures, the overlays painted on them and the
## vertex paint (relative to `neutral`, the scaled white the far corners carry; lighting
## keys stay in the vertices), one texel per
## 1 / TEXELS_PER_M metres. Holes (no ground) take the nearest colour along the row.
static func _flatten(ground: Array, sources: Array[Dictionary], data: LevelData, corner: Vector2, cell_size: Vector2,
		images: Dictionary, neutral: Color) -> Image:
	var texels := clampi(nearest_po2(roundi(cell_size.x * TEXELS_PER_M)), 16, 256)
	var img := Image.create(texels, texels, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	# Ground can stack (a raised square laid on the ground grid): like a view from above,
	# the highest surface at each texel wins.
	var heights := PackedFloat32Array()
	heights.resize(texels * texels)
	heights.fill(-INF)
	var step := cell_size / texels
	for poly in ground:
		var src: Dictionary = sources[poly.src]
		var brush: LevelBrush = src.brush
		var inv: Transform3D = src.xf.affine_inverse()
		poly.pts = world_pts(poly, src)
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for p: Vector3 in poly.pts:
			lo = lo.min(Vector2(p.x, p.z))
			hi = hi.max(Vector2(p.x, p.z))
		# Covered texels by the polygon's triangles (as the bake triangulates it: merged
		# outlines can be too odd for a plain point-in-polygon test).
		var tri_ids := PolyUtil.triangulate(poly.pts, poly.normal)
		var tris2 := []
		var cc: PackedColorArray = poly.corner_colors
		var has_paint: bool = cc.size() == poly.pts.size()
		for t in range(0, tri_ids.size(), 3):
			tris2.append([Vector2(poly.pts[tri_ids[t]].x, poly.pts[tri_ids[t]].z), Vector2(poly.pts[tri_ids[t + 1]].x, poly.pts[tri_ids[t + 1]].z),
				Vector2(poly.pts[tri_ids[t + 2]].x, poly.pts[tri_ids[t + 2]].z), tri_ids[t], tri_ids[t + 1], tri_ids[t + 2]])
		var local_pts := PackedVector3Array()
		for i in poly.ids:
			local_pts.append(src.verts[i])
		var uv_normal := PolyUtil.newell_normal(local_pts) * (-1.0 if src.mirrored else 1.0)
		var plane := Plane(poly.normal.normalized(), poly.pts[0])
		# Base texture.
		var base: Texture2D = data.textures[poly.texture] if poly.texture >= 0 and poly.texture < data.textures.size() else null
		var tint := Color.WHITE
		var palette = data.base_tints.get(base) if base else null
		var look_tile := 0.0
		var recolour := false
		if base is TextureLook:
			tint = base.color
			look_tile = base.tile
			recolour = base.recolour
			if base.palette.size() == 2:
				palette = base.palette
			base = base.texture
		if base is N64StairTexture:
			base = base.base
		var base_tile := look_tile if look_tile > 0.0 else (PaintAtlas.base_tile_for(base, data) if base else 1.0)
		var base_img := _image(base, images, base_tile, step.x)
		var base_mean := _mean_luma(base, images) if recolour else 1.0
		var base_comb := PaintAtlas.texture_tint(base, palette)
		# Overlays painted on this face.
		var overlays := []
		if poly.masked_face >= 0 and brush:
			var f: int = poly.masked_face
			var layers := data.layers_of(brush.get_face_layer_set(f))
			for l in mini(layers.size(), LevelData.MAX_LAYERS):
				var mask := brush.get_face_mask(f, l)
				var layer: PaintLayer = layers[l]
				if mask == null or layer == null or not layer.enabled or layer.texture == null:
					continue
				var lt := PaintAtlas.layer_tile(layer)
				var comb := PaintAtlas.texture_tint(layer.texture,
					PackedColorArray([layer.tint_dark, layer.tint]) if layer.override_tint else null)
				var opacity: float = layer.get(&"opacity") if layer.get(&"opacity") != null else 1.0
				overlays.append([mask, _image(layer.texture, images, lt, step.x), lt, layer.tint if not layer.override_tint else Color.WHITE,
					comb, int(layer.blend), opacity])
			if not overlays.is_empty():
				overlays.append(brush.get_face_normal(f))
				overlays.append(brush.get_face_planar_rect(f))
		var x_from := clampi(floori((lo.x - corner.x) / step.x), 0, texels - 1)
		var x_to := clampi(ceili((hi.x - corner.x) / step.x), 0, texels - 1)
		var y_from := clampi(floori((lo.y - corner.y) / step.y), 0, texels - 1)
		var y_to := clampi(ceili((hi.y - corner.y) / step.y), 0, texels - 1)
		for ty in range(y_from, y_to + 1):
			for tx in range(x_from, x_to + 1):
				var w := corner + Vector2(tx + 0.5, ty + 0.5) * step
				var inside := false
				var paint := Color.WHITE
				for tr in tris2:
					if Geometry2D.point_is_inside_triangle(w, tr[0], tr[1], tr[2]):
						inside = true
						if has_paint:
							var a: Vector2 = tr[0]
							var b: Vector2 = tr[1]
							var e: Vector2 = tr[2]
							var d := (b - a).cross(e - a)
							if absf(d) > 1e-9:
								var u := (b - w).cross(e - w) / d
								var v := (e - w).cross(a - w) / d
								var pc: Color = cc[tr[3]] * u + cc[tr[4]] * v + cc[tr[5]] * (1.0 - u - v)
								paint = Color(pc.r / maxf(neutral.r, 0.001), pc.g / maxf(neutral.g, 0.001), pc.b / maxf(neutral.b, 0.001))
						break
				if not inside:
					continue
				var hit = plane.intersects_ray(Vector3(w.x, 1000.0, w.y), Vector3.DOWN)
				var world: Vector3 = hit if hit != null else Vector3(w.x, poly.pts[0].y, w.y)
				if world.y < heights[ty * texels + tx] - 0.01:
					continue
				heights[ty * texels + tx] = world.y
				var local := inv * world
				var c := tint
				var uv := LevelBrush.tweaked_uv(local, uv_normal, poly.uv_tweak)
				if base_img:
					var bs := _sample(base_img, uv, base_tile)
					if recolour:
						# The shader's recolour: the painted colour, with the texture's light and
						# dark detail around its mean (the paint isn't applied again after).
						var l := bs.r * 0.2126 + bs.g * 0.7152 + bs.b * 0.0722
						c = Color(paint.r, paint.g, paint.b) * (l / maxf(base_mean, 0.05)) * tint
						paint = Color.WHITE
					else:
						c *= _tint(bs, base_comb)
				if overlays.size() > 2:
					var fn: Vector3 = overlays[-2]
					var rect: Rect2 = overlays[-1]
					var planar := PolyUtil.planar_uv(local, fn)
					var muv := (planar - rect.position) / rect.size.max(Vector2(0.001, 0.001))
					for o in overlays.slice(0, overlays.size() - 2):
						var mask: Image = o[0]
						var m := mask.get_pixel(clampi(int(muv.x * mask.get_width()), 0, mask.get_width() - 1),
							clampi(int(muv.y * mask.get_height()), 0, mask.get_height() - 1)).r
						if m > 0.0 and o[1]:
							var oc: Color = _tint(_sample(o[1], uv, o[2]), o[4]) * o[3]
							c = _blend_layer(c, oc, o[5], m * o[6])
				c = Color(c.r * paint.r, c.g * paint.g, c.b * paint.b, 1.0)
				img.set_pixel(tx, ty, c)
	_fill_holes(img)
	img.generate_mipmaps()
	return img


## `tex` as an RGBA8 image, shrunk (by halves, averaging) until a texel is about as big
## as `step` metres when one repeat covers `tile` metres: reading it once per far texel
## then averages what the texel covers instead of aliasing into streaks.
static func _image(tex: Texture2D, cache: Dictionary, tile := 1.0, step := 0.0) -> Image:
	if tex == null:
		return null
	if not cache.has(tex):
		var im := tex.get_image()
		if im:
			im = im.duplicate()
			if im.is_compressed():
				im.decompress()
			im.convert(Image.FORMAT_RGBA8)
		cache[tex] = {0: im}
	var levels: Dictionary = cache[tex]
	var im: Image = levels[0]
	if im == null or step <= 0.0:
		return im
	var texel := tile / maxf(im.get_width(), 1)
	var level := clampi(floori(log(maxf(step / texel, 1.0)) / log(2.0)), 0, 8)
	if not levels.has(level):
		var small: Image = im.duplicate()
		var w := maxi(1, im.get_width() >> level)
		var h := maxi(1, im.get_height() >> level)
		small.resize(w, h, Image.INTERPOLATE_BILINEAR if level == 1 else Image.INTERPOLATE_TRILINEAR)
		levels[level] = small
	return levels[level]


## The shader's layer blend (blend_mode): `mode` PaintLayer.Blend, `m` mask x opacity.
## Height blends and shine are approximated as a plain mix.
static func _blend_layer(c: Color, t: Color, mode: int, m: float) -> Color:
	var r: Color
	match mode:
		PaintLayer.Blend.MULTIPLY: r = c * t
		PaintLayer.Blend.ADD: r = c + t
		PaintLayer.Blend.SUBTRACT: r = c - t
		PaintLayer.Blend.SCREEN: r = Color(1, 1, 1) - (Color(1, 1, 1) - c) * (Color(1, 1, 1) - t)
		PaintLayer.Blend.OVERLAY:
			r = Color(_overlay(c.r, t.r), _overlay(c.g, t.g), _overlay(c.b, t.b))
		PaintLayer.Blend.SHINE: r = c
		_: r = t
	r = Color(clampf(r.r, 0.0, 1.0), clampf(r.g, 0.0, 1.0), clampf(r.b, 0.0, 1.0))
	return c.lerp(r, clampf(m, 0.0, 1.0))


static func _overlay(a: float, b: float) -> float:
	return 2.0 * a * b if a < 0.5 else 1.0 - 2.0 * (1.0 - a) * (1.0 - b)


## A texture's mean brightness (its average colour), for recolour.
static func _mean_luma(tex: Texture2D, cache: Dictionary) -> float:
	var im := _image(tex, cache)
	if im == null:
		return 1.0
	var small: Image = im.duplicate()
	small.resize(1, 1, Image.INTERPOLATE_TRILINEAR)
	var c := small.get_pixel(0, 0)
	return c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722


## The shader's tint combiner (n64_tint): [mode, dark, light, extra(amount, lo, hi)].
static func _tint(c: Color, comb: Array) -> Color:
	var mode: float = comb[0]
	if mode < 0.5:
		return c
	var dark: Color = comb[1]
	var light: Color = comb[2]
	var extra: Vector3 = comb[3]
	var tinted: Color
	if mode < 1.5:
		tinted = c * light
	else:
		var l := c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
		var t := clampf((l - extra.y) / maxf(extra.z - extra.y, 0.01), 0.0, 1.0)
		tinted = dark.lerp(light, t)
	var out := c.lerp(tinted, extra.x)
	out.a = c.a
	return out


## A texture read the way the paint shader tiles it: `uv` in metres, `tile` metres a repeat.
static func _sample(img: Image, uv: Vector2, tile: float) -> Color:
	var w := img.get_width()
	var h := img.get_height()
	var t := uv / maxf(tile, 0.001) * Vector2(1.0, float(w) / maxf(h, 1))
	return img.get_pixel(posmod(floori(t.x * w), w), posmod(floori(t.y * h), h))


## Texels no ground covered (outside the ground, under nothing) take a covered neighbour's
## colour, so filtering at the ground's edge doesn't pull in black.
static func _fill_holes(img: Image) -> void:
	for pass_i in 4:
		var any := false
		for y in img.get_height():
			for x in img.get_width():
				if img.get_pixel(x, y).a > 0.0:
					continue
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var q: Vector2i = Vector2i(x, y) + d
					if q.x >= 0 and q.y >= 0 and q.x < img.get_width() and q.y < img.get_height():
						var c := img.get_pixel(q.x, q.y)
						if c.a > 0.5:
							img.set_pixel(x, y, Color(c.r, c.g, c.b, 0.6))
							any = true
							break
		if not any:
			break
