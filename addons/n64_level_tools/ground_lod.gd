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
const BuildCache := preload("res://addons/n64_level_tools/export/build_cache.gd")


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
				for raw: PackedVector2Array in Geometry2D.intersect_polygons(outline, rect):
					if raw.size() < 3 or absf(_area(raw)) < 0.01:
						continue
					var piece := _true_piece(raw, outline, rect)
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
						var bw := _edge_weights(outline, q)
						if bw.is_empty():
							bw = _weights(outline, q)
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


## A clipped piece made exact again: the clipper rounds its corners and drops ones in line
## with their neighbours, but a neighbouring face shares those very points (dropped or moved,
## they open hairline cracks). Corners near the outline's go back to them, cut points onto the
## cell line, and outline corners lying on a piece edge go back in.
static func _true_piece(raw: PackedVector2Array, outline: PackedVector2Array, rect: PackedVector2Array) -> PackedVector2Array:
	const SNAP := 0.002
	var lo := rect[0]
	var hi := rect[2]
	var fixed := PackedVector2Array()
	for q in raw:
		var best := -1
		for i in outline.size():
			if outline[i].distance_to(q) < SNAP and (best < 0 or outline[i].distance_squared_to(q) < outline[best].distance_squared_to(q)):
				best = i
		if best >= 0:
			q = outline[best]
		else:
			for k in 2:
				for line in [lo[k], hi[k]]:
					if absf(q[k] - line) < SNAP:
						q[k] = line
			# On an outline edge too: slide onto it along the cell line.
			for i in outline.size():
				var a := outline[i]
				var c := outline[(i + 1) % outline.size()]
				if Geometry2D.get_closest_point_to_segment(q, a, c).distance_to(q) < SNAP:
					var k := 0 if (absf(q.x - lo.x) < 1e-6 or absf(q.x - hi.x) < 1e-6) else 1
					if absf(c[k] - a[k]) > 1e-6:
						var t := clampf((q[k] - a[k]) / (c[k] - a[k]), 0.0, 1.0)
						q = a.lerp(c, t)
						q[k] = lo[k] if absf(q[k] - lo[k]) < 1e-6 else (hi[k] if absf(q[k] - hi[k]) < 1e-6 else q[k])
					break
		if fixed.is_empty() or fixed[-1].distance_to(q) > 1e-6:
			fixed.append(q)
	if fixed.size() > 1 and fixed[0].distance_to(fixed[-1]) <= 1e-6:
		fixed.remove_at(fixed.size() - 1)
	var out := PackedVector2Array()
	for i in fixed.size():
		var a := fixed[i]
		var c := fixed[(i + 1) % fixed.size()]
		out.append(a)
		var len := a.distance_to(c)
		if len < SNAP:
			continue
		var dir := (c - a) / len
		var on := []
		for o in outline:
			var t := (o - a).dot(dir)
			if t > SNAP * 0.5 and t < len - SNAP * 0.5 and (a + dir * t).distance_to(o) < SNAP * 0.5:
				on.append([t, o])
		on.sort_custom(func(x, y): return x[0] < y[0])
		for e in on:
			if out[-1].distance_to(e[1]) > 1e-6:
				out.append(e[1])
	return out


## Weights for a point on `outline`'s boundary: its corner, or the two ends of its edge
## (linear along the edge, so a neighbour sharing the edge gets the same height). Empty if
## `q` is inside.
static func _edge_weights(outline: PackedVector2Array, q: Vector2) -> Dictionary:
	for i in outline.size():
		if outline[i].distance_to(q) < 1e-5:
			return {i: 1.0}
	for i in outline.size():
		var j := (i + 1) % outline.size()
		var a := outline[i]
		var c := outline[j]
		var d := c - a
		var l2 := d.length_squared()
		if l2 < 1e-12:
			continue
		var t := (q - a).dot(d) / l2
		if t > 0.0 and t < 1.0 and (a + d * t).distance_to(q) < 1e-4:
			return {i: 1.0 - t, j: t}
	return {}


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
	# Build & Play keeps each cell's picture (BuildCache "groundfar"): painting it is the
	# slow part (every texel in script), and an edit changes only the cells it touches.
	var painter = null  # the GPU view, made when the first cell needs painting
	var level_sig: Variant = [BuildCache.pipeline_hash(), _sig(data.textures), _sig(data.base_tints), _sig(data.layers),
		_sig(data.layer_sets), neutral, TEXELS_PER_M, ProjectSettings.get_setting("n64/textures/texels_per_metre", 32)] \
		if BuildCache.active else null
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
					# (key 0's alpha: the brush's coverage ID, as LevelBaker writes it)
					kc[0] = Color(kc[0], (float(int(src.brush_index) % 7) + 1.0) / 255.0)
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
		var flat: Image = null
		var ckey := 0
		if level_sig != null:
			ckey = BuildCache.key([level_sig, x0, z0, cell_size, ground.map(func(p): return _poly_sig(p, sources[p.src]))])
			var hit = BuildCache.read("groundfar", ckey)
			if hit is Array and hit.size() == 5:
				flat = Image.create_from_data(hit[0], hit[1], hit[2], hit[3], hit[4])
		if flat == null:
			if painter == null:
				painter = _gpu_painter(clampi(nearest_po2(roundi(cell_size.x * TEXELS_PER_M)), 16, 256)) \
					if OS.get_environment("GROUND_FAR_CPU") == "" else {}
			flat = _flatten_gpu(painter, ground, sources, data, Vector2(x0, z0), cell_size, images, neutral) if not painter.is_empty() \
				else _flatten(ground, sources, data, Vector2(x0, z0), cell_size, images, neutral)
			if level_sig != null:
				BuildCache.write("groundfar", ckey, [flat.get_width(), flat.get_height(), flat.has_mipmaps(), flat.get_format(), flat.get_data()])
		var tex := ImageTexture.create_from_image(flat)
		var mat := PaintAtlas.make_material(tex, data, masks, 0, false)
		mat.set_shader_parameter(&"base_tile", cell_size.x)
		mat.set_shader_parameter(&"base_var", Vector3(0.0, 8.0, 0.0))  # (variation off; a vec3 uniform)
		mat.set_shader_parameter(&"base_anti", Vector2.ZERO)
		materials[key] = mat
	if painter:
		_free_painter(painter)


## What a ground polygon's far picture depends on (for the cache key).
static func _poly_sig(poly: Dictionary, src: Dictionary) -> Array:
	var local := PackedVector3Array()
	for i in poly.ids:
		local.append(src.verts[i])
	var brush: LevelBrush = src.brush
	var masks := []
	var f: int = poly.masked_face
	if f >= 0 and brush:
		masks.append(brush.get_face_layer_set(f))
		for l in LevelData.MAX_LAYERS:
			var m := brush.get_face_mask(f, l)
			masks.append(hash(m.get_data()) if m else 0)
		masks.append_array([brush.get_face_normal(f), brush.get_face_planar_rect(f)])
	return [local, src.xf, src.mirrored, poly.normal, poly.texture, poly.get("uv_tweak"), poly.get("uv_stretch"),
		brush.uv_anchor() if brush else Vector3.ZERO, poly.get("corner_colors"), masks]


## A stable signature of resource settings (textures by file and its date; others by their
## stored properties, a few levels deep), for cache keys.
static func _sig(v: Variant, depth := 0) -> Variant:
	if v is Array:
		return v.map(func(x): return _sig(x, depth))
	if v is Dictionary:
		var out := []
		for k in v:
			out.append([_sig(k, depth), _sig(v[k], depth)])
		return out
	if v is Resource:
		var path: String = v.resource_path
		if path != "" and not path.contains("::"):
			return [path, FileAccess.get_modified_time(path)]
		if depth > 3:
			return v.get_class()
		var out := [v.get_class()]
		for p in v.get_property_list():
			if p.usage & PROPERTY_USAGE_STORAGE and p.name != "script":
				out.append(_sig(v.get(p.name), depth + 1))
		return out
	return v


## How a ground polygon looks from above (its base texture and tint, and the overlays painted
## on it: [mask, layer image, tile, tint, tint combiner, blend, opacity, layer texture] then
## the face normal and planar rect), shared by the CPU and GPU pictures.
static func _poly_look(poly: Dictionary, brush: LevelBrush, data: LevelData, images: Dictionary, step: float) -> Dictionary:
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
	var base_img := _image(base, images, base_tile, step)
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
			overlays.append([mask, _image(layer.texture, images, lt, step), lt, layer.tint if not layer.override_tint else Color.WHITE,
				comb, int(layer.blend), opacity, layer.texture])
		if not overlays.is_empty():
			overlays.append(brush.get_face_normal(f))
			overlays.append(brush.get_face_planar_rect(f))
	return {base = base, tint = tint, recolour = recolour, base_tile = base_tile, base_img = base_img, base_mean = base_mean,
		base_comb = base_comb, overlays = overlays}


## The far picture drawn on the GPU (the same sums as _flatten, from straight above into a
## texels x texels image; the highest ground wins by depth): one draw per cell instead of
## every texel in script. Paint (relative to the scaled white) rides in CUSTOM0 (it can pass
## 1), the base UV (metres) in UV, the overlay masks' UV in UV2. Colours go through raw (no
## sRGB hints) to a linear HDR target, so they come back as computed.
const FLAT_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled, depth_draw_always;
uniform sampler2D base_tex : filter_nearest_mipmap, repeat_enable;
uniform bool has_base = false;
uniform float base_tile = 1.0;
uniform vec4 tint = vec4(1.0);
uniform bool recolour = false;
uniform float base_mean = 1.0;
uniform vec4 comb = vec4(0.0, 1.0, 0.0, 1.0); // mode, extra (amount, lo, hi)
uniform vec3 comb_dark = vec3(0.2);
uniform vec3 comb_light = vec3(1.0);
uniform int layer_count = 0;
uniform sampler2D mask_0 : filter_nearest, repeat_disable;
uniform sampler2D mask_1 : filter_nearest, repeat_disable;
uniform sampler2D mask_2 : filter_nearest, repeat_disable;
uniform sampler2D mask_3 : filter_nearest, repeat_disable;
uniform sampler2D layer_0 : filter_nearest_mipmap, repeat_enable;
uniform sampler2D layer_1 : filter_nearest_mipmap, repeat_enable;
uniform sampler2D layer_2 : filter_nearest_mipmap, repeat_enable;
uniform sampler2D layer_3 : filter_nearest_mipmap, repeat_enable;
uniform vec4 lparam_0 = vec4(1.0, 0.0, 1.0, 0.0); // tile, blend, opacity, -
uniform vec4 lparam_1 = vec4(1.0, 0.0, 1.0, 0.0);
uniform vec4 lparam_2 = vec4(1.0, 0.0, 1.0, 0.0);
uniform vec4 lparam_3 = vec4(1.0, 0.0, 1.0, 0.0);
uniform vec4 ltint_0 = vec4(1.0);
uniform vec4 ltint_1 = vec4(1.0);
uniform vec4 ltint_2 = vec4(1.0);
uniform vec4 ltint_3 = vec4(1.0);
uniform vec4 lcomb_0 = vec4(0.0, 1.0, 0.0, 1.0);
uniform vec4 lcomb_1 = vec4(0.0, 1.0, 0.0, 1.0);
uniform vec4 lcomb_2 = vec4(0.0, 1.0, 0.0, 1.0);
uniform vec4 lcomb_3 = vec4(0.0, 1.0, 0.0, 1.0);
uniform vec3 ldark_0 = vec3(0.2);
uniform vec3 ldark_1 = vec3(0.2);
uniform vec3 ldark_2 = vec3(0.2);
uniform vec3 ldark_3 = vec3(0.2);
uniform vec3 llight_0 = vec3(1.0);
uniform vec3 llight_1 = vec3(1.0);
uniform vec3 llight_2 = vec3(1.0);
uniform vec3 llight_3 = vec3(1.0);
varying vec3 paint;

void vertex() {
	paint = CUSTOM0.rgb;
}

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec3 tinted(vec3 c, vec4 k, vec3 dark, vec3 light) {
	if (k.x < 0.5) {
		return c;
	}
	vec3 t = k.x < 1.5 ? c * light : mix(dark, light, clamp((luma(c) - k.z) / max(k.w - k.z, 0.01), 0.0, 1.0));
	return mix(c, t, k.y);
}

vec3 read(sampler2D tex, vec2 uv, float tile) {
	vec2 size = vec2(textureSize(tex, 0));
	// (Bias: the sharper of the two nearest mips, as _image picks for the CPU picture.)
	return texture(tex, uv / tile * vec2(1.0, size.x / max(size.y, 1.0)), -0.5).rgb;
}

float ov(float a, float b) {
	return a < 0.5 ? 2.0 * a * b : 1.0 - 2.0 * (1.0 - a) * (1.0 - b);
}

vec3 blend(vec3 c, vec3 t, int mode, float m) {
	vec3 r = t;
	if (mode == 1) { r = c * t; }
	else if (mode == 2) { r = c + t; }
	else if (mode == 3) { r = c - t; }
	else if (mode == 4) { r = vec3(1.0) - (vec3(1.0) - c) * (vec3(1.0) - t); }
	else if (mode == 5) { r = vec3(ov(c.r, t.r), ov(c.g, t.g), ov(c.b, t.b)); }
	else if (mode == 7) { r = c; }
	return mix(c, clamp(r, 0.0, 1.0), clamp(m, 0.0, 1.0));
}

vec3 layer(vec3 c, sampler2D mask, sampler2D tex, vec4 p, vec4 lt, vec4 k, vec3 dark, vec3 light, vec2 muv, vec2 uv) {
	float m = texture(mask, muv).r;
	if (m <= 0.0) {
		return c;
	}
	return blend(c, tinted(read(tex, uv, p.x), k, dark, light) * lt.rgb, int(p.y + 0.5), m * p.z);
}

void fragment() {
	vec3 pt = paint;
	vec3 c = tint.rgb;
	if (has_base) {
		vec3 bs = read(base_tex, UV, base_tile);
		if (recolour) {
			c = pt * (luma(bs) / max(base_mean, 0.05)) * tint.rgb;
			pt = vec3(1.0);
		} else {
			c *= tinted(bs, comb, comb_dark, comb_light);
		}
	}
	if (layer_count > 0) { c = layer(c, mask_0, layer_0, lparam_0, ltint_0, lcomb_0, ldark_0, llight_0, UV2, UV); }
	if (layer_count > 1) { c = layer(c, mask_1, layer_1, lparam_1, ltint_1, lcomb_1, ldark_1, llight_1, UV2, UV); }
	if (layer_count > 2) { c = layer(c, mask_2, layer_2, lparam_2, ltint_2, lcomb_2, ldark_2, llight_2, UV2, UV); }
	if (layer_count > 3) { c = layer(c, mask_3, layer_3, lparam_3, ltint_3, lcomb_3, ldark_3, llight_3, UV2, UV); }
	ALBEDO = c * pt;
}
"""


## A top-down view for _flatten_gpu ({} without a RenderingDevice: the CPU paints instead).
static func _gpu_painter(texels: int) -> Dictionary:
	if RenderingServer.get_rendering_device() == null:
		return {}
	var rs := RenderingServer
	var scenario := rs.scenario_create()
	var vp := rs.viewport_create()
	rs.viewport_set_size(vp, texels, texels)
	rs.viewport_set_scenario(vp, scenario)
	rs.viewport_set_transparent_background(vp, true)
	rs.viewport_set_use_hdr_2d(vp, true)
	rs.viewport_set_msaa_3d(vp, RenderingServer.VIEWPORT_MSAA_DISABLED)
	rs.viewport_set_screen_space_aa(vp, RenderingServer.VIEWPORT_SCREEN_SPACE_AA_DISABLED)
	rs.viewport_set_use_debanding(vp, false)
	rs.viewport_set_positional_shadow_atlas_size(vp, 0)
	var cam := rs.camera_create()
	rs.viewport_attach_camera(vp, cam)
	rs.viewport_set_active(vp, true)
	var shader := Shader.new()
	shader.code = FLAT_SHADER
	return {scenario = scenario, vp = vp, cam = cam, shader = shader, texels = texels}


static func _free_painter(painter: Dictionary) -> void:
	if painter.is_empty():
		return
	for r in [painter.vp, painter.cam, painter.scenario]:
		RenderingServer.free_rid(r)


## _flatten on the GPU (`painter`: _gpu_painter for this cell size).
static func _flatten_gpu(painter: Dictionary, ground: Array, sources: Array[Dictionary], data: LevelData, corner: Vector2,
		cell_size: Vector2, images: Dictionary, neutral: Color) -> Image:
	var rs := RenderingServer
	var texels: int = painter.texels
	var step := cell_size / texels
	var top := -INF
	var keep := []  # meshes, materials and textures the draw uses, alive until it's done
	var insts := []
	for poly in ground:
		var src: Dictionary = sources[poly.src]
		var brush: LevelBrush = src.brush
		poly.pts = world_pts(poly, src)
		for p: Vector3 in poly.pts:
			top = maxf(top, p.y)
		var local_pts := PackedVector3Array()
		for i in poly.ids:
			local_pts.append(src.verts[i])
		var uv_normal := PolyUtil.newell_normal(local_pts) * (-1.0 if src.mirrored else 1.0)
		var anchor := brush.uv_anchor() if brush else Vector3.ZERO
		var look := _poly_look(poly, brush, data, images, step.x)
		var overlays: Array = look.overlays
		var cc: PackedColorArray = poly.corner_colors
		var has_paint: bool = cc.size() == poly.pts.size()
		var mask_n := Vector3.UP
		var mask_rect := Rect2(0, 0, 1, 1)
		if overlays.size() > 2:
			mask_n = overlays[-2]
			mask_rect = overlays[-1]
		var order := PolyUtil.triangulate(poly.pts, poly.normal)
		var pos := PackedVector3Array()
		var uv := PackedVector2Array()
		var uv2 := PackedVector2Array()
		var custom := PackedFloat32Array()
		for i in order:
			pos.append(poly.pts[i])
			uv.append(LevelBrush.tweaked_uv(local_pts[i] + anchor, uv_normal, poly.uv_tweak, poly.get("uv_stretch", Vector2.ONE)))
			uv2.append((PolyUtil.planar_uv(local_pts[i], mask_n) - mask_rect.position) / mask_rect.size.max(Vector2(0.001, 0.001)))
			var pc := Color.WHITE
			if has_paint:
				pc = Color(cc[i].r / maxf(neutral.r, 0.001), cc[i].g / maxf(neutral.g, 0.001), cc[i].b / maxf(neutral.b, 0.001))
			custom.append_array([pc.r, pc.g, pc.b, 1.0])
		if pos.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		arrays[Mesh.ARRAY_CUSTOM0] = custom
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
			Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		var mat := ShaderMaterial.new()
		mat.shader = painter.shader
		var comb: Array = look.base_comb
		var tint: Color = look.tint
		mat.set_shader_parameter(&"has_base", look.base != null)
		mat.set_shader_parameter(&"base_tex", look.base)
		mat.set_shader_parameter(&"base_tile", look.base_tile)
		mat.set_shader_parameter(&"tint", Vector4(tint.r, tint.g, tint.b, tint.a))
		mat.set_shader_parameter(&"recolour", look.recolour)
		mat.set_shader_parameter(&"base_mean", look.base_mean)
		_set_comb(mat, comb, "comb", "comb_dark", "comb_light")
		var n := 0
		for o in overlays.slice(0, maxi(overlays.size() - 2, 0)):
			if n >= 4 or o[7] == null:
				continue
			var mt := ImageTexture.create_from_image(o[0])
			keep.append(mt)
			var lt: Color = o[3]
			mat.set_shader_parameter("mask_%d" % n, mt)
			mat.set_shader_parameter("layer_%d" % n, o[7])
			mat.set_shader_parameter("lparam_%d" % n, Vector4(o[2], o[5], o[6], 0.0))
			mat.set_shader_parameter("ltint_%d" % n, Vector4(lt.r, lt.g, lt.b, lt.a))
			_set_comb(mat, o[4], "lcomb_%d" % n, "ldark_%d" % n, "llight_%d" % n)
			n += 1
		mat.set_shader_parameter(&"layer_count", n)
		keep.append_array([mesh, mat])
		var inst := rs.instance_create2(mesh.get_rid(), painter.scenario)
		rs.instance_geometry_set_material_override(inst, mat.get_rid())
		insts.append(inst)
	if top > -INF:
		rs.camera_set_orthogonal(painter.cam, cell_size.y, 0.05, top + 1000.0)
		rs.camera_set_transform(painter.cam, Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD),
			Vector3(corner.x + cell_size.x * 0.5, top + 10.0, corner.y + cell_size.y * 0.5)))
	rs.viewport_set_update_mode(painter.vp, RenderingServer.VIEWPORT_UPDATE_ONCE)
	rs.force_draw(false)
	var img := rs.texture_2d_get(rs.viewport_get_texture(painter.vp))
	for inst in insts:
		rs.free_rid(inst)
	keep.clear()
	img.convert(Image.FORMAT_RGBA8)
	_fill_holes(img)
	img.generate_mipmaps()
	return img


## A tint combiner ([mode, dark, light, extra]) into FLAT_SHADER's uniforms.
static func _set_comb(mat: ShaderMaterial, comb: Array, k: String, dark: String, light: String) -> void:
	var extra: Vector3 = comb[3]
	var d: Color = comb[1]
	var l: Color = comb[2]
	mat.set_shader_parameter(k, Vector4(comb[0], extra.x, extra.y, extra.z))
	mat.set_shader_parameter(dark, Vector3(d.r, d.g, d.b))
	mat.set_shader_parameter(light, Vector3(l.r, l.g, l.b))


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
		var look := _poly_look(poly, brush, data, images, step.x)
		var tint: Color = look.tint
		var recolour: bool = look.recolour
		var base_tile: float = look.base_tile
		var base_img: Image = look.base_img
		var base_mean: float = look.base_mean
		var base_comb: Array = look.base_comb
		var overlays: Array = look.overlays
		var x_from := clampi(floori((lo.x - corner.x) / step.x), 0, texels - 1)
		var x_to := clampi(ceili((hi.x - corner.x) / step.x), 0, texels - 1)
		var y_from := clampi(floori((lo.y - corner.y) / step.y), 0, texels - 1)
		var y_to := clampi(ceili((hi.y - corner.y) / step.y), 0, texels - 1)
		# Which triangle covers each texel (the first, in order), found triangle by triangle
		# over just its own texels: a merged polygon has many triangles, and testing every
		# texel of its bounds against all of them was most of the bake.
		var bw := x_to - x_from + 1
		var owner := PackedInt32Array()
		owner.resize(bw * (y_to - y_from + 1))
		owner.fill(-1)
		for ti in tris2.size():
			var tr: Array = tris2[ti]
			var tlo: Vector2 = (tr[0] as Vector2).min(tr[1]).min(tr[2])
			var thi: Vector2 = (tr[0] as Vector2).max(tr[1]).max(tr[2])
			for ty in range(maxi(floori((tlo.y - corner.y) / step.y - 0.5), y_from), mini(ceili((thi.y - corner.y) / step.y - 0.5), y_to) + 1):
				for tx in range(maxi(floori((tlo.x - corner.x) / step.x - 0.5), x_from), mini(ceili((thi.x - corner.x) / step.x - 0.5), x_to) + 1):
					var o := (ty - y_from) * bw + tx - x_from
					if owner[o] < 0 and Geometry2D.point_is_inside_triangle(corner + Vector2(tx + 0.5, ty + 0.5) * step, tr[0], tr[1], tr[2]):
						owner[o] = ti
		for ty in range(y_from, y_to + 1):
			for tx in range(x_from, x_to + 1):
				var ti := owner[(ty - y_from) * bw + tx - x_from]
				if ti < 0:
					continue
				var w := corner + Vector2(tx + 0.5, ty + 0.5) * step
				var paint := Color.WHITE
				if has_paint:
					var tr: Array = tris2[ti]
					var a: Vector2 = tr[0]
					var b: Vector2 = tr[1]
					var e: Vector2 = tr[2]
					var d := (b - a).cross(e - a)
					if absf(d) > 1e-9:
						var u := (b - w).cross(e - w) / d
						var v := (e - w).cross(a - w) / d
						var pc: Color = cc[tr[3]] * u + cc[tr[4]] * v + cc[tr[5]] * (1.0 - u - v)
						paint = Color(pc.r / maxf(neutral.r, 0.001), pc.g / maxf(neutral.g, 0.001), pc.b / maxf(neutral.b, 0.001))
				var hit = plane.intersects_ray(Vector3(w.x, 1000.0, w.y), Vector3.DOWN)
				var world: Vector3 = hit if hit != null else Vector3(w.x, poly.pts[0].y, w.y)
				if world.y < heights[ty * texels + tx] - 0.01:
					continue
				heights[ty * texels + tx] = world.y
				var local := inv * world
				var c := tint
				var uv := LevelBrush.tweaked_uv(local + (src.brush.uv_anchor() if src.brush else Vector3.ZERO), uv_normal, poly.uv_tweak, poly.get("uv_stretch", Vector2.ONE))
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
