class_name LevelBaker
extends RefCounted
## Turns a LevelData's brushes into gameplay geometry:
##   - transforms every brush polygon into LevelRoot space
##   - culls interior faces (coincident, opposite-facing polygons between touching brushes)
##   - merges adjacent coplanar faces within each brush (optional; never faces with painted
##     masks or vertex colours, since merging drops their interior vertices)
##   - `optimize` (the build: Build & Play, export): first a copy of the level whose faces
##     keep only the vertices their shape or vertex data needs (BuildSimplify)
##   - drops degenerate triangles left behind by collapsed vertices
##   - one indexed surface per base texture (paint shader + baked mask atlases) or per
##     legacy brush material, with welded vertices
##   - big levels split into CHUNK_SIZE cells, one mesh each, so the camera culls the ones
##     out of view or past the fog (coplanar merging stays inside a cell)
##   - builds trimesh collision, one shape per Surface (LevelSurfaces: footstep sound and
##     gameplay flags per face; stairs can use a ramp proxy)
## Returns {mesh: ArrayMesh or null (one chunk), chunks: Array[ArrayMesh] (more than one; mesh
## is null then), collision_parts: Array[ConcavePolygonShape3D], collision_surfaces:
## PackedInt32Array (the Surface of each part), stats}.

const GroundCollision := preload("res://addons/n64_level_tools/ground_collision.gd")
const QUANT := 1000.0
## Metres: cell size of the baked mesh chunks. Levels up to 1.5 cells across stay one mesh.
const CHUNK_SIZE := 32.0
## Project setting: chunk cell size (metres). Smaller cells cull and swap LOD more finely
## (fewer triangles in view) but split each material into more draws.
const CHUNK_SETTING := "n64/build/chunk_size"
## Project setting: cell size (metres) for everything that swaps by distance (near / far
## house faces, shop detail, ground). Godot measures a mesh's visibility range to its
## bounds' centre, so a cell's swap lands up to its radius early or late; smaller cells keep
## the swap close to the set distance (LOD distances are pushed out by the radius so nothing
## inside them ever shows its far version).
const LOD_CELL_SETTING := "n64/build/lod_cell_size"
const LOD_CELL := 16.0


## Why `data` can't bake right now ("" = fine): right after the tool scripts change, the
## editor reloads them and layers / textures briefly aren't their classes; a bake then
## would silently drop overlays (moss) or bake untextured.
## `data` with its hidden faces culled (BuildCull), its brushes copied so the level being
## edited keeps them: {data, culled}.
static func _culled_copy(data: LevelData) -> Dictionary:
	var copy: LevelData = data.duplicate(false)
	var own: Array[LevelBrush] = []
	for b in data.brushes:
		var c: LevelBrush = b.duplicate(false) if b else null
		if c:
			c.set_block_signals(true)
		own.append(c)
	copy.set_block_signals(true)
	copy.brushes = own
	var culled := BuildCull.cull(copy)
	return {data = copy, culled = culled}


static func not_ready_reason(data: LevelData) -> String:
	for ls in data.layer_set_count():
		var layers := data.layers_of(ls)
		for i in layers.size():
			var l = layers[i]
			if l != null and l.get("tile_size") == null:
				return "overlay layer %d isn't loaded (editor still reloading scripts)" % (i + 1)
	for i in data.textures.size():
		if data.textures[i] == null:
			return "texture %d of the level didn't load" % i
	return ""


static func bake(data: LevelData, merge_coplanar: bool, optimize := false) -> Dictionary:
	var simplified := {}
	var hidden := {}
	if optimize:
		simplified = BuildSimplify.optimized_copy(data)
		data = simplified.data
	else:
		# Faces nobody can see (ground under houses, walls pressed against a neighbour) out
		# of every bake, on a copy (the build culls its own copy before relighting).
		var copy := _culled_copy(data)
		hidden = copy.culled
		data = copy.data
	var timed := LevelData.mode_is_timed(data.lighting_mode)
	# Stored corner lighting only counts in Baked Vertex mode (Dynamic = real-time lights).
	var baked_light := data.lighting_mode == LevelData.LightingMode.BAKED_VERTEX
	# Baked Vertex Dynamic: the bake rides in CUSTOM0 like a one-key timed bake, so the
	# painted colours stay clean for the live lights.
	var hybrid := data.lighting_mode == LevelData.LightingMode.BAKED_VERTEX_DYNAMIC
	var keyed := timed or hybrid
	var stats := {
		brushes = 0, source_tris = 0, culled_faces = 0, merged_faces = 0, degenerate_tris = 0,
		baked_tris = 0, baked_verts = 0, surfaces = 0, collision_tris = 0, chunks = 0,
		simplified_from = simplified.get("before", 0), simplified_to = simplified.get("after", 0),
		hidden_ground_faces = hidden.get("ground", 0), hidden_wall_faces = hidden.get("walls", 0),
	}
	# Only faces with paint get a mask chart (erased masks stay stored, all zero).
	var atlas := PaintAtlas.layout(data.brushes, true)
	var sources: Array[Dictionary] = []
	var polys: Array[Dictionary] = []
	for bi in data.brushes.size():
		var brush: LevelBrush = data.brushes[bi]
		if brush == null:
			continue
		brush.ensure_geometry()
		stats.brushes += 1
		var visual := brush.bake_mode != LevelBrush.BakeMode.COLLISION_ONLY
		var collide := brush.bake_mode != LevelBrush.BakeMode.VISUAL_ONLY
		var ramp := collide and brush.uses_collision_ramp()
		var surf := LevelSurfaces.brush_faces(data, brush) if collide else PackedInt32Array()
		_add_source(sources, polys, brush.vertices, brush.get_faces(), brush.transform,
			brush, bi, visual, collide and not ramp, stats, brush.vertex_colors, timed, baked_light, hybrid, data.vertex_color_scale(), surf)
		if ramp:
			# The ramp sounds like the steps' treads (the first face facing up).
			var tread := 0
			for f in brush.get_face_count():
				if brush.get_face_normal(f).y > 0.7:
					tread = surf[f]
					break
			var r := BrushShapes.build_stairs_ramp(brush.size, brush.segments)
			_add_source(sources, polys, r.verts, BrushOps.unpack_faces(r.indices, r.counts),
				brush.transform, null, bi, false, true, stats, PackedColorArray(), false, false, false, 1.0, PackedInt32Array(), tread)

	var grid := _assign_cells(polys)
	# Distance-swapped polygons (and below, the ground) go in the finer LOD grid, by their
	# brush's origin: a house's near and far faces must share a cell to swap together.
	var lgrid := {origin = grid.origin, size = Vector2(lod_cell(), lod_cell())}
	for poly in polys:
		if poly.get("lod", LevelBrush.LOD_ALWAYS) != LevelBrush.LOD_ALWAYS:
			poly.cell = _cell_of(PackedVector3Array([sources[poly.src].xf.origin]), lgrid)
	_cull_coincident(polys, "visual", stats)
	_cull_coincident(polys, "collide", stats)
	if merge_coplanar:
		polys = _merge_coplanar(sources, polys, stats)

	_assign_stair_runs(sources, polys, data.stair_textures())
	# The ground goes near-only, cut along the cell lines; its flattened far stand-in is
	# added per cell below.
	polys = GroundLOD.split_to_cells(polys, sources, lgrid.origin, lgrid.size)
	var ground := GroundLOD.mark(polys, sources)

	var surfaces := {}
	var painted := {}  # surface key -> overlay layers painted on it (any cell)
	var collision := {}  # Surface -> PackedVector3Array
	var ground_collision := {}  # the same, for the ground (GroundCollision)
	for poly in polys:
		if not (poly.visual or poly.collide):
			continue
		var src: Dictionary = sources[poly.src]
		var ids: PackedInt32Array = poly.ids
		var local := PackedVector3Array()
		var pts := PackedVector3Array()
		for i in ids:
			local.append(src.verts[i])
			pts.append(src.xf * src.verts[i])
		var n := PolyUtil.newell_normal(pts)
		if n == Vector3.ZERO:
			continue
		var uv_normal := PolyUtil.newell_normal(local) * (-1.0 if src.mirrored else 1.0)
		var tris := PolyUtil.triangulate(pts, n)
		var surf: Dictionary = {}
		var chart = null
		var face_rect := Rect2()
		if poly.visual:
			var lod: int = poly.get("lod", LevelBrush.LOD_ALWAYS)
			var skey := [poly.cell, lod, poly.key]
			if not surfaces.has(skey):
				surfaces[skey] = {cell = poly.cell, lod = lod, key = poly.key, pos = PackedVector3Array(), nrm = PackedVector3Array(), uv = PackedVector2Array(),
					uv2 = PackedVector2Array(), col = PackedColorArray(), idx = PackedInt32Array(), weld = {},
					keys = [PackedByteArray(), PackedByteArray(), PackedByteArray(), PackedByteArray()],
					material = poly.material, texture = poly.texture, overlay = poly.get("overlay", 0), stair_frame = poly.get("stair_frame"),
					layer_set = poly.get("layer_set", 0), cutout = poly.get("cutout", false)}
			surf = surfaces[skey]
			if poly.masked_face >= 0:
				chart = atlas.rects.get(Vector2i(src.brush_index, poly.masked_face))
				face_rect = src.brush.get_face_planar_rect(poly.masked_face)
				# Overlay layers painted on this surface (others may be switched off).
				for l in LevelData.MAX_LAYERS:
					if PaintAtlas.mask_painted(src.brush.get_face_mask(poly.masked_face, l)):
						painted[poly.key] = painted.get(poly.key, 0) | (1 << l)
		for t in range(0, tris.size(), 3):
			var a := pts[tris[t]]
			var b := pts[tris[t + 1]]
			var c := pts[tris[t + 2]]
			if (b - a).cross(c - a).length_squared() < 1e-10:
				stats.degenerate_tris += 1
				continue
			# Godot front faces are clockwise.
			for k: int in [0, 2, 1]:
				var i := tris[t + k]
				if poly.visual:
					var exact: PackedVector2Array = poly.get("exact_uvs", PackedVector2Array())
					var uv := exact[i] if exact.size() == ids.size() else LevelBrush.tweaked_uv(local[i], uv_normal, poly.uv_tweak)
					var uv2 := PaintAtlas.chart_uv(chart, atlas.size, face_rect, PolyUtil.planar_uv(local[i], uv_normal)) \
						if chart != null else PaintAtlas.empty_uv(atlas.size)
					var cc: PackedColorArray = poly.get("corner_colors", PackedColorArray())
					var col: Color = cc[i] if cc.size() == ids.size() else LevelBrush.scaled_color(Color.WHITE, data.vertex_color_scale())
					var kc := []
					if keyed:
						var all_keys: Array = poly.get("key_colors", [])
						for s in 4:
							var arr: PackedColorArray = all_keys[s] if s < all_keys.size() else PackedColorArray()
							kc.append(arr[i] if arr.size() == ids.size() else Color.WHITE)
					surf.idx.append(_weld(surf, pts[i], n, uv, uv2, col, kc))
				if poly.collide:
					# The ground's collision is simplified on its own below (optimize).
					var into := ground_collision if optimize and poly.get("lod", 0) == LevelBrush.LOD_GROUND_NEAR else collision
					if not into.has(poly.surface):
						into[poly.surface] = PackedVector3Array()
					into[poly.surface].append(pts[i])
			if poly.visual:
				stats.baked_tris += 1

	for k in ground_collision:
		var coarse := GroundCollision.simplify(ground_collision[k])
		stats.ground_collision_from = stats.get("ground_collision_from", 0) + ground_collision[k].size() / 3
		stats.ground_collision_to = stats.get("ground_collision_to", 0) + coarse.size() / 3
		if not collision.has(k):
			collision[k] = PackedVector3Array()
		collision[k].append_array(coarse)

	# A layer with nothing painted on it gets no atlas (null: the shader reads unpainted),
	# instead of a full-size image of zeros in the level, in memory and on the GPU.
	var masks: Array[ImageTexture] = []
	for i in data.mask_slot_count():
		var img := PaintAtlas.build_layer(data.brushes, atlas, i)
		masks.append(ImageTexture.create_from_image(img) if PaintAtlas.mask_painted(img) else null)
	var meshes := {}  # cell -> ArrayMesh
	var materials := {}  # surface key -> Material (shared by every cell)
	if not auto_lod():
		GroundLOD.add_far(ground, sources, data, lgrid.origin, lgrid.size, atlas.size, masks, keyed, surfaces, materials, stats)
	# Distance bands: each surface's visibility range (metres; end 0 = no end). Surfaces with
	# the same range in a cell share a mesh. Always-drawn ones stay in their own chunk mesh
	# (roofs never swap).
	# Surfaces sharing a mesh and material are one draw: append them (ground kept apart, named
	# "ground" for the build report's floor spots).
	var merged := {}  # [cell, range, key, ground] -> surface dict
	for sk in surfaces:
		var s: Dictionary = surfaces[sk]
		if s.idx.is_empty():
			continue
		var targets := [lod_range(s.lod)]
		var is_ground: bool = s.lod == LevelBrush.LOD_GROUND_NEAR
		for r: Vector2 in targets:
			var gkey := [s.cell, r, s.key, is_ground]
			if not merged.has(gkey):
				merged[gkey] = {s = s, range = r, ground = is_ground, parts = []}
			merged[gkey].parts.append(s)
	for gkey in merged:
		var g: Dictionary = merged[gkey]
		var s: Dictionary = g.s
		var pos := PackedVector3Array()
		var nrm := PackedVector3Array()
		var uv := PackedVector2Array()
		var uv2 := PackedVector2Array()
		var col := PackedColorArray()
		var idx := PackedInt32Array()
		var keys := [PackedByteArray(), PackedByteArray(), PackedByteArray(), PackedByteArray()]
		for part: Dictionary in g.parts:
			var base := pos.size()
			pos.append_array(part.pos)
			nrm.append_array(part.nrm)
			uv.append_array(part.uv)
			uv2.append_array(part.uv2)
			col.append_array(part.col)
			for i: int in part.idx:
				idx.append(base + i)
			if keyed:
				for k in 4:
					keys[k].append_array(part.keys[k])
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = nrm
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		arrays[Mesh.ARRAY_COLOR] = col
		arrays[Mesh.ARRAY_INDEX] = idx
		var flags := 0
		if keyed:
			for k in 4:
				arrays[Mesh.ARRAY_CUSTOM0 + k] = keys[k]
			flags = LevelBrush.KEY_FORMAT
		if not materials.has(s.key):
			materials[s.key] = _bake_material(s, data, masks, painted.get(s.key, 0))
		# One mesh per chunk cell and visibility range (the "range" meta; LevelRoot applies it).
		var r: Vector2 = g.range
		var mkey := [s.cell, r]
		if not meshes.has(mkey):
			meshes[mkey] = ArrayMesh.new()
			if r != Vector2.ZERO:
				meshes[mkey].set_meta(&"range", r)
		var mesh: ArrayMesh = meshes[mkey]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
		var si := mesh.get_surface_count() - 1
		mesh.surface_set_material(si, materials[s.key])
		if g.ground:
			mesh.surface_set_name(si, "ground")
			mesh.set_meta(&"ground", true)
		mesh.set_meta(&"formats", mesh.get_meta(&"formats", PackedInt32Array()) + PackedInt32Array([flags]))
		stats.surfaces += 1
	for sk in surfaces:
		stats.baked_verts += surfaces[sk].pos.size()
	# Every swapping mesh of a LOD cell gets the same bounds, centred on the cell, so its near
	# and far versions measure the same distance and swap at the same moment (no gap where
	# neither shows, no overlap).
	var column := {}  # cell -> AABB of its swapping meshes
	for mkey in meshes:
		if mkey[1] != Vector2.ZERO:
			var box: AABB = meshes[mkey].get_aabb()
			column[mkey[0]] = column[mkey[0]].merge(box) if column.has(mkey[0]) else box
	for mkey in meshes:
		if mkey[1] == Vector2.ZERO:
			continue
		var cell: Vector2i = mkey[0]
		var all: AABB = column[cell]
		var centre := Vector3(lgrid.origin.x + (cell.x + 0.5) * lgrid.size.x, all.get_center().y,
			lgrid.origin.z + (cell.y + 0.5) * lgrid.size.y)
		var half := (all.end - centre).max(centre - all.position)
		meshes[mkey].custom_aabb = AABB(centre - half, half * 2.0)
	var chunks: Array[ArrayMesh] = []
	for cell in meshes:
		var mesh: ArrayMesh = meshes[cell]
		if auto_lod():
			mesh = with_auto_lods(mesh)
		mesh.remove_meta(&"formats")
		chunks.append(mesh)
	stats.chunks = chunks.size()
	var parts: Array[ConcavePolygonShape3D] = []
	var part_surfaces := PackedInt32Array()
	var keys := collision.keys()
	keys.sort()
	for k in keys:
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(collision[k])
		parts.append(shape)
		part_surfaces.append(k)
		stats.collision_tris += collision[k].size() / 3
	return {mesh = chunks[0] if chunks.size() == 1 else null, chunks = chunks if chunks.size() > 1 else ([] as Array[ArrayMesh]),
		collision_parts = parts, collision_surfaces = part_surfaces, stats = stats}


static func _bake_material(s: Dictionary, data: LevelData, masks: Array[ImageTexture], painted: int) -> Material:
	var mat: Material = PaintAtlas.convert_material(s.material, data, masks) if s.material else null
	if mat == null:
		var base: Texture2D = data.textures[s.texture] if s.texture >= 0 and s.texture < data.textures.size() else null
		if s.texture >= 0 and base == null:
			# Faces want a texture that didn't load (e.g. a bake during a script reload):
			# say so instead of silently baking grey.
			push_error("N64 bake: texture %d of the level didn't load; faces using it bake untextured. Re-bake after restarting the editor." % s.texture)
		mat = PaintAtlas.make_material(base, data, masks, s.get("layer_set", 0), s.get("cutout", false))
		PaintAtlas.set_overlay_code(mat, s.get("overlay", 0), data)
		if base is N64StairTexture and s.stair_frame != null:
			PaintAtlas.apply_stair(mat, base, s.stair_frame)
	if mat is ShaderMaterial and PaintAtlas.is_paint_shader(mat.shader):
		PaintAtlas.prune_layers(mat, data, painted)
	return mat


## Project setting: 0 = the hand-made LOD (far stand-ins swapped in by distance), 1 =
## automatic: no stand-ins, every chunk simplified by Godot's mesh LOD (meshoptimizer),
## picked by its size on screen.
const LOD_MODE_SETTING := "n64/build/lod_mode"


static func auto_lod() -> bool:
	return int(ProjectSettings.get_setting(LOD_MODE_SETTING, 0)) == 1


## `mesh` with Godot's automatic LOD levels (ImporterMesh.generate_lods, meshoptimizer)
## added to every surface; materials, surface names and metadata kept.
static func with_auto_lods(mesh: ArrayMesh) -> ArrayMesh:
	var formats: PackedInt32Array = mesh.get_meta(&"formats", PackedInt32Array())
	var im := ImporterMesh.new()
	for si in mesh.get_surface_count():
		var flags := formats[si] if si < formats.size() else 0
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, mesh.surface_get_arrays(si), [], {}, mesh.surface_get_material(si),
			mesh.surface_get_name(si), flags)
	im.generate_lods(25.0, 60.0, [])
	var out := im.get_mesh()
	for m in mesh.get_meta_list():
		out.set_meta(m, mesh.get_meta(m))
	out.custom_aabb = mesh.custom_aabb
	return out


## The visibility range (begin, end; metres, end 0 = none) faces of `lod` are drawn in.
static func chunk_size() -> float:
	return maxf(float(ProjectSettings.get_setting(CHUNK_SETTING, CHUNK_SIZE)), 4.0)


static func lod_cell() -> float:
	return maxf(float(ProjectSettings.get_setting(LOD_CELL_SETTING, LOD_CELL)), 4.0)


## A LOD band's visibility range: the set distance plus the LOD cell's radius (the swap is
## measured to the cell's centre), so nothing within the distance shows its far version.
static func lod_range(lod: int) -> Vector2:
	if auto_lod():
		return Vector2.ZERO
	var r := lod_cell() * 0.7072
	match lod:
		LevelBrush.LOD_NEAR: return Vector2(0, LevelRoot.lod_distance() + r)
		LevelBrush.LOD_FAR: return Vector2(LevelRoot.lod_distance() + r, 0)
		LevelBrush.LOD_GROUND_NEAR: return Vector2(0, GroundLOD.distance() + r)
		LevelBrush.LOD_GROUND_FAR: return Vector2(GroundLOD.distance() + r, 0)
		LevelBrush.LOD_DETAIL_NEAR: return Vector2(0, LevelRoot.detail_distance() + r)
		LevelBrush.LOD_DETAIL_FAR: return Vector2(LevelRoot.detail_distance() + r, 0)
	return Vector2.ZERO


## Puts every polygon in a CHUNK_SIZE cell (by centre, on a grid from the level's corner);
## levels that fit in about one cell get a single cell. Returns the grid: {origin, size}
## (a cell's XZ size).
## The cell of `grid` ({origin, size}) holding the polygon's centre.
static func _cell_of(pts: PackedVector3Array, grid: Dictionary) -> Vector2i:
	var centre := Vector3.ZERO
	for p: Vector3 in pts:
		centre += p
	centre /= pts.size()
	return Vector2i(floori((centre.x - grid.origin.x) / grid.size.x), floori((centre.z - grid.origin.z) / grid.size.y))


static func _assign_cells(polys: Array[Dictionary]) -> Dictionary:
	var box := AABB()
	var first := true
	for poly in polys:
		for p: Vector3 in poly.pts:
			if first:
				box = AABB(p, Vector3.ZERO)
				first = false
			else:
				box = box.expand(p)
	var size := chunk_size()
	var split := maxf(box.size.x, box.size.z) > size * 1.5
	for poly in polys:
		var c := Vector2i.ZERO
		if split:
			var centre := Vector3.ZERO
			for p: Vector3 in poly.pts:
				centre += p
			centre /= poly.pts.size()
			c = Vector2i(floori((centre.x - box.position.x) / size), floori((centre.z - box.position.z) / size))
		poly.cell = c
	return {origin = box.position, size = Vector2(size, size) if split else Vector2(maxf(box.size.x, box.size.z), maxf(box.size.x, box.size.z))}


static func _add_source(sources: Array[Dictionary], polys: Array[Dictionary], verts: PackedVector3Array,
		faces: Array[PackedInt32Array], xf: Transform3D, brush: LevelBrush, brush_index: int, visual: bool,
		collide: bool, stats: Dictionary, colors := PackedColorArray(), timed := false, baked_light := false, hybrid := false,
		color_scale := 1.0, surfaces := PackedInt32Array(), fixed_surface := 0) -> void:
	if not (visual or collide):
		return
	var mirrored := xf.basis.determinant() < 0.0
	# A copy: packed arrays are shared, and the bake adds corners to a source's list
	# (GroundLOD.split_to_cells), which would otherwise grow the brush's own vertices.
	sources.append({verts = verts.duplicate(), xf = xf, mirrored = mirrored, brush = brush, brush_index = brush_index, colors = colors})
	var brush_visual := visual
	var brush_collide := collide
	for f in faces.size():
		# Per-face override (a fence's wall faces: collision only; its panels: visual only).
		visual = brush_visual
		collide = brush_collide
		if brush and not brush.face_bake.is_empty():
			visual = brush.face_visual(f)
			collide = brush_collide and brush.face_collides(f)
			if not (visual or collide):
				continue
		# Far stand-ins are only seen, never walked on (the near faces collide).
		var lod := brush.get_face_lod(f) if brush else LevelBrush.LOD_ALWAYS
		if lod == LevelBrush.LOD_FAR or lod == LevelBrush.LOD_DETAIL_FAR:
			collide = false
			# Automatic LOD: no hand-made stand-ins (the near faces are drawn at every distance).
			if not visual or auto_lod():
				continue
		var ids := faces[f].duplicate()
		if mirrored:
			ids.reverse()
		var pts := PackedVector3Array()
		for i in ids:
			pts.append(xf * verts[i])
		var n := PolyUtil.newell_normal(pts)
		if n == Vector3.ZERO:
			continue
		if visual:
			stats.source_tris += ids.size() - 2
		var key := -1
		var texture := -1
		var material: Material = null
		var masked := -1
		var tweak := LevelBrush.DEFAULT_UV
		var overlay := 0
		var layer_set := 0
		var cut := false
		var exact_uvs := PackedVector2Array()
		if brush:
			cut = brush.cutout
			if brush.has_corner_uvs():
				var s0 := brush.get_face_start(f)
				exact_uvs = brush.corner_uvs.slice(s0, s0 + faces[f].size())
				if mirrored:
					exact_uvs.reverse()
			texture = brush.get_face_texture(f)
			key = brush.get_surface_key(f)
			if key == -2:
				material = brush.material
			masked = f if PaintAtlas.face_painted(brush, f) else -1
			tweak = brush.get_face_uv(f)
			overlay = LevelBrush.uv_overlay_code(tweak) if material == null else 0
			layer_set = brush.get_face_layer_set(f) if material == null else 0
		# Corner colour = painted vertex colour x baked corner lighting.
		var corner_colors := PackedColorArray()
		var key_colors := []
		var colored := false
		if brush:
			var start := brush.get_face_start(f)
			for k in faces[f].size():
				var light := brush.get_corner_light(start + k) if baked_light else Color.WHITE
				var c := LevelBrush.scaled_color(brush.get_corner_shade(start + k, faces[f][k]) * light, color_scale)
				corner_colors.append(c)
				colored = colored or not c.is_equal_approx(LevelBrush.scaled_color(Color.WHITE, color_scale))
			if mirrored:
				corner_colors.reverse()
			if hybrid:
				var kc := PackedColorArray()
				for k in faces[f].size():
					var lc := brush.get_corner_light(start + k)
					kc.append(lc)
					colored = colored or not lc.is_equal_approx(Color.WHITE)
				if mirrored:
					kc.reverse()
				key_colors.append(kc)
			elif timed:
				for s in brush.corner_lighting_keys.size():
					var kc := PackedColorArray()
					for k in faces[f].size():
						var lc := brush.get_corner_key_light(s, start + k)
						kc.append(lc)
						colored = colored or not lc.is_equal_approx(Color.WHITE)
					if mirrored:
						kc.reverse()
					key_colors.append(kc)
		polys.append({src = sources.size() - 1, ids = ids, pts = pts, normal = n, visual = visual, collide = collide, lod = lod,
			colored = colored, corner_colors = corner_colors, key_colors = key_colors,
			key = ("mat:%d" % material.get_instance_id()) if material else ("tex:%d:%d:%d%s" % [texture, overlay, layer_set, ":cut" if cut else ""]),
			texture = texture, overlay = overlay, layer_set = layer_set, cutout = cut, exact_uvs = exact_uvs, material = material, masked_face = masked, uv_tweak = tweak,
			surface = surfaces[f] if f < surfaces.size() else fixed_surface})


## Stair-textured polygons: coplanar ones of the same brush and texture form one flight
## with one step frame (world space, like the baked mesh) and their own surface key.
static func _assign_stair_runs(sources: Array[Dictionary], polys: Array[Dictionary], stairs: Dictionary) -> void:
	if stairs.is_empty():
		return
	var planes := {}
	for poly in polys:
		if not poly.visual or not stairs.has(poly.texture) or poly.material != null:
			continue
		var src: Dictionary = sources[poly.src]
		var pts := PackedVector3Array()
		for i: int in poly.ids:
			pts.append(src.xf * src.verts[i])
		var n := PolyUtil.newell_normal(pts)
		if n == Vector3.ZERO:
			continue
		n = n.normalized()
		var key := [poly.src, poly.texture, poly.get("layer_set", 0), poly.get("cutout", false), n.snappedf(0.001), snappedf(n.dot(pts[0]), 0.001)]
		if not planes.has(key):
			planes[key] = {polys = [], pts = PackedVector3Array(), n = n, tex = poly.texture, id = planes.size()}
		planes[key].polys.append(poly)
		planes[key].pts.append_array(pts)
	for key in planes:
		var pl: Dictionary = planes[key]
		var stair: N64StairTexture = stairs[pl.tex]
		var frame := N64StairTexture.frame(pl.pts, pl.n, stair.length_per_repeat())
		for poly: Dictionary in pl.polys:
			poly.key = "stair:%d" % pl.id
			poly.stair_frame = frame


## Two brushes touching face-to-face produce identical opposite-facing polygons that can
## never be seen; remove both. Exact duplicates (overlapping brushes) keep one copy.
static func _cull_coincident(polys: Array[Dictionary], channel: String, stats: Dictionary) -> void:
	var groups := {}
	for i in polys.size():
		if not polys[i][channel]:
			continue
		var key := _poly_key(polys[i].pts)
		if groups.has(key):
			groups[key].append(i)
		else:
			groups[key] = [i]
	for key in groups:
		var ids: Array = groups[key]
		for x in ids.size():
			for y in range(x + 1, ids.size()):
				var a: Dictionary = polys[ids[x]]
				var b: Dictionary = polys[ids[y]]
				if not (a[channel] and b[channel]) or a.get("lod", 0) != b.get("lod", 0):
					continue
				var d: float = a.normal.dot(b.normal)
				if d < -0.99:
					a[channel] = false
					b[channel] = false
					if channel == "visual":
						stats.culled_faces += 2
				elif d > 0.99:
					b[channel] = false
					if channel == "visual":
						stats.culled_faces += 1


## Faces only merge when everything that affects shading matches; painted faces keep
## their own mask chart, so they never merge. Coloured faces merge only with faces of the
## very same single colour on every corner (and lighting key): nothing to interpolate.
static func _merge_coplanar(sources: Array[Dictionary], polys: Array[Dictionary], stats: Dictionary) -> Array[Dictionary]:
	var by_src := {}
	for poly in polys:
		if poly.visual or poly.collide:
			if not by_src.has(poly.src):
				by_src[poly.src] = []
			by_src[poly.src].append(poly)
	var out: Array[Dictionary] = []
	for src in by_src:
		var group: Array = by_src[src]
		var faces: Array[PackedInt32Array] = []
		var compat := []
		for i in group.size():
			var poly: Dictionary = group[i]
			faces.append(poly.ids)
			var tone := _uniform_tone(poly) if poly.colored else []
			var unique: bool = poly.masked_face >= 0 or (poly.colored and tone.is_empty()) or not poly.get("exact_uvs", PackedVector2Array()).is_empty()
			compat.append([poly.visual, poly.collide, poly.key, poly.uv_tweak, i if unique else -1, poly.cell, tone,
				poly.surface if poly.collide else 0, poly.get("lod", 0)])
		var merged := BrushOps.merge_coplanar(sources[src].verts, faces, compat)
		var visual_before := group.filter(func(p): return p.visual).size()
		for f in merged.faces.size():
			var flags: Array = merged.compat[f]
			var template: Dictionary = group[flags[4]] if flags[4] >= 0 else _first_with(group, flags)
			var poly := template.duplicate()
			poly.ids = merged.faces[f]
			if flags[4] < 0 and template.colored:
				# One colour throughout: spread it over the merged polygon's corners.
				var cc := PackedColorArray()
				cc.resize(poly.ids.size())
				cc.fill(template.corner_colors[0])
				poly.corner_colors = cc
				var keys := []
				for kc: PackedColorArray in template.key_colors:
					var k := PackedColorArray()
					k.resize(poly.ids.size())
					k.fill(kc[0])
					keys.append(k)
				poly.key_colors = keys
			out.append(poly)
			if flags[0]:
				visual_before -= 1
		stats.merged_faces += visual_before
	return out


static func _first_with(group: Array, flags: Array) -> Dictionary:
	for poly in group:
		if poly.visual == flags[0] and poly.collide == flags[1] and poly.key == flags[2] and poly.uv_tweak == flags[3] \
				and poly.cell == flags[5] and poly.masked_face < 0 and (poly.surface if poly.collide else 0) == flags[7] \
				and poly.get("lod", 0) == flags[8] \
				and ((not poly.colored and flags[6].is_empty()) or (poly.colored and _uniform_tone(poly) == flags[6])):
			return poly
	return group[0]


## A coloured polygon's single colour (every corner, every lighting key) as [rgba32...], or
## [] when its corners differ.
static func _uniform_tone(poly: Dictionary) -> Array:
	var tone := []
	for list: PackedColorArray in [poly.corner_colors] + poly.key_colors:
		if list.is_empty():
			return []
		var c := list[0].to_rgba32()
		for x in list:
			if x.to_rgba32() != c:
				return []
		tone.append(c)
	return tone


static func _poly_key(pts: PackedVector3Array) -> Array:
	var key := []
	for p in pts:
		key.append(Vector3i((p * QUANT).round()))
	key.sort()
	return key


static func _weld(surf: Dictionary, p: Vector3, n: Vector3, uv: Vector2, uv2: Vector2, col: Color, key_colors := []) -> int:
	var key := [Vector3i((p * QUANT).round()), Vector3i((n * QUANT).round()), Vector2i((uv * QUANT).round()),
		Vector2i((uv2 * 100000.0).round()), col.to_rgba32()]
	for kc: Color in key_colors:
		key.append(kc.to_rgba32())
	var weld: Dictionary = surf.weld
	if weld.has(key):
		return weld[key]
	surf.pos.append(p)
	surf.nrm.append(n)
	surf.uv.append(uv)
	surf.uv2.append(uv2)
	surf.col.append(col)
	if not key_colors.is_empty():
		for s in 4:
			LevelBrush.push_rgba8(surf.keys[s], key_colors[s])
	weld[key] = surf.pos.size() - 1
	return weld[key]
