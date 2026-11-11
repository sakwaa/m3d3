class_name PropBatch
extends RefCounted
## Draw-call batching for small static props (market stalls, signs): in the game, their
## meshes are merged into one mesh per CELL-metre cell and visibility range, one surface per
## look, so a square of stalls is a handful of draws instead of one or more per stall.
## Colours move into the vertex colours (and UV scales into the UVs), so props that differ
## only in tint share a surface. The props keep their collision, spots and talk areas; only
## their MeshInstance3Ds go. Nothing changes in the editor.

const CELL := 8.0  # metres; small, so merged LOD swaps stay close to where each prop's would be
const ARRAYS_META := &"prop_batch_arrays"  # commit(): a surface's arrays, kept for merging
const GROUP := &"prop_batch"  # props' "Parts" nodes whose MeshInstance3D children batch
const TEXTURED := preload("res://addons/n64_runtime/shaders/n64_textured.gdshader")
const FOLDED := [&"albedo_color", &"use_vertex_color", &"uv_scale"]

static var _queued := false
## Project setting n64/build/lod_mode (1 = automatic LOD): props then show their near
## meshes at every distance, no far stand-ins.
const LOD_MODE_SETTING := "n64/build/lod_mode"
## Project setting n64/build/lod_fade: metres a near / far pair cross-fades over (0 = snap).
const LOD_FADE_SETTING := "n64/build/lod_fade"


## Called by a prop once its parts are built: batched at the end of the frame (with every
## other prop that's ready by then).
static func add(parts: Node3D) -> void:
	parts.add_to_group(GROUP)  # also how the build report finds them
	if Engine.is_editor_hint():
		return
	if not _queued:
		_queued = true
		_flush.call_deferred(parts.get_tree())


static func _flush(tree: SceneTree) -> void:
	_queued = false
	if tree == null:
		return
	# Per zone (the prop's scene root), so a zone's batches go with it.
	var by_zone := {}
	for parts: Node in tree.get_nodes_in_group(GROUP):
		parts.remove_from_group(GROUP)
		var prop := parts.get_parent()
		if prop == null or not parts.is_inside_tree():
			continue
		var zone: Node = prop.owner if prop.owner else prop.get_parent()
		by_zone.get_or_add(zone, []).append_array(meshes_of(parts))
	for zone: Node in by_zone:
		var holder := Node3D.new()
		holder.name = "PropBatch"
		zone.add_child(holder)
		for mi in merge(by_zone[zone]):
			holder.add_child(mi)
			mi.top_level = true
			mi.global_transform = Transform3D.IDENTITY
		for mi: MeshInstance3D in by_zone[zone]:
			mi.queue_free()


## Commits `st` as a new surface of `mesh`, keeping its arrays on the mesh for merge():
## reading a surface back from the GPU (surface_get_arrays) is slow, most of a zone's first
## frame when every prop is read back.
static func commit(st: SurfaceTool, mesh: ArrayMesh) -> void:
	commit_arrays(st.commit_to_arrays(), mesh)


## As commit(), from surface arrays (Mesh.ARRAY_MAX long).
static func commit_arrays(arr: Array, mesh: ArrayMesh) -> void:
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var kept: Array = mesh.get_meta(ARRAYS_META, [])
	kept.append(arr)
	mesh.set_meta(ARRAYS_META, kept)


## The visible meshes a prop's parts node holds.
static func meshes_of(parts: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for c in parts.get_children():
		if c is MeshInstance3D and c.mesh != null and c.visible:
			out.append(c)
	return out


## The merged meshes (world space, not in the tree) standing in for `mis`.
static func merge(mis: Array) -> Array[MeshInstance3D]:
	var groups := {}  # [cell, range] -> {range, surfaces: {look key -> {material, pos, nrm, uv, col, idx}}}
	var atlased := []  # [surface, first vertex, end, texture]: UVs to move into the atlas
	var auto := int(ProjectSettings.get_setting(LOD_MODE_SETTING, 0)) == 1
	for mi: MeshInstance3D in mis:
		if auto and mi.visibility_range_begin > 0.0:
			continue
		var xf := mi.global_transform
		# By the prop's origin (its "Parts" node), so its near and far meshes share a cell.
		var parent := mi.get_parent() as Node3D
		var centre := parent.global_position if parent else xf * mi.get_aabb().get_center()
		var cell := Vector2i(floori(centre.x / CELL), floori(centre.z / CELL))
		var r := Vector4(mi.visibility_range_begin, mi.visibility_range_end, mi.visibility_range_begin_margin,
			mi.visibility_range_end_margin) if not auto else Vector4.ZERO
		var g: Dictionary = groups.get_or_add([cell, r], {range = r, surfaces = {}})
		var nb := xf.basis.inverse().transposed()
		# Uniform scale (the usual): normals turn with the rotation alone, no renormalising.
		var sc := xf.basis.get_scale()
		var uniform := is_equal_approx(sc.x, sc.y) and is_equal_approx(sc.y, sc.z)
		var nxf := Transform3D(xf.basis.orthonormalized(), Vector3.ZERO)
		for si in mi.mesh.get_surface_count():
			var src := mi.material_override if mi.material_override else mi.get_active_material(si)
			var look := _look(src)
			var s: Dictionary = g.surfaces.get_or_add(look.key, {material = look.material, pos = PackedVector3Array(),
				nrm = PackedVector3Array(), uv = PackedVector2Array(), col = PackedColorArray(), idx = PackedInt32Array()})
			var kept: Array = mi.mesh.get_meta(ARRAYS_META, [])
			var arr: Array = kept[si] if si < kept.size() else mi.mesh.surface_get_arrays(si)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var nrms = arr[Mesh.ARRAY_NORMAL]
			var uvs = arr[Mesh.ARRAY_TEX_UV]
			var cols = arr[Mesh.ARRAY_COLOR]
			var ix = arr[Mesh.ARRAY_INDEX]
			var base: int = s.pos.size()
			var n := verts.size()
			# Whole arrays at once where Godot can (transforms run natively): a per-vertex loop
			# here was most of a zone's first frame.
			s.pos.append_array(xf * verts)
			if nrms == null:
				var up := PackedVector3Array()
				up.resize(n)
				up.fill(Vector3.UP)
				s.nrm.append_array(up)
			elif uniform:
				s.nrm.append_array(nxf * (nrms as PackedVector3Array))
			else:
				for i in n:
					s.nrm.append((nb * nrms[i]).normalized())
			if uvs == null:
				var zero := PackedVector2Array()
				zero.resize(n)
				s.uv.append_array(zero)
			else:
				s.uv.append_array(Transform2D.IDENTITY.scaled(look.uv_scale) * (uvs as PackedVector2Array))
			if cols != null and look.vertex_color:
				for i in n:
					s.col.append(cols[i] * look.tint)
			else:
				var tint := PackedColorArray()
				tint.resize(n)
				tint.fill(look.tint)
				s.col.append_array(tint)
			if look.atlas:
				atlased.append([s, base, s.pos.size(), look.texture])
			if ix != null:
				for i: int in ix:
					s.idx.append(base + i)
			else:
				for i in verts.size():
					s.idx.append(base + i)
	_pack(atlased)
	var out: Array[MeshInstance3D] = []
	var column := {}  # cell -> AABB of all its groups (near and far alike)
	for gk in groups:
		var g: Dictionary = groups[gk]
		var mesh := ArrayMesh.new()
		g.mesh = mesh
		for lk in g.surfaces:
			var s: Dictionary = g.surfaces[lk]
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = s.pos
			arrays[Mesh.ARRAY_NORMAL] = s.nrm
			arrays[Mesh.ARRAY_TEX_UV] = s.uv
			arrays[Mesh.ARRAY_COLOR] = s.col
			arrays[Mesh.ARRAY_INDEX] = s.idx
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, s.material)
		column[gk[0]] = column[gk[0]].merge(mesh.get_aabb()) if column.has(gk[0]) else mesh.get_aabb()
	# Godot measures visibility ranges to the bounds' centre: a cell's near and far meshes get
	# the same bounds (centred on the cell) so they swap together, and the range moves out by
	# the cell's radius so nothing inside the prop's own distance shows its far version.
	var radius := CELL * 0.7072
	var fade := maxf(float(ProjectSettings.get_setting(LOD_FADE_SETTING, 4.0)), 0.0)
	for gk in groups:
		var g: Dictionary = groups[gk]
		var mesh: ArrayMesh = g.mesh
		var all: AABB = column[gk[0]]
		var centre := Vector3((gk[0].x + 0.5) * CELL, all.get_center().y, (gk[0].y + 0.5) * CELL)
		var half := (all.end - centre).max(centre - all.position)
		mesh.custom_aabb = AABB(centre - half, half * 2.0)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var r: Vector4 = g.range
		var begin := r.x + radius if r.x > 0.0 else 0.0
		var end := r.y + radius if r.y > 0.0 else 0.0
		# Dissolve (n64_lod_fade.gdshaderinc) across `fade` metres around the swap, measured to
		# the cell's centre like Godot's range, which only culls, loosely, around the band.
		var slack := fade * 0.5 + 1.0 if fade > 0.0 else 0.0
		mi.visibility_range_begin = maxf(begin - slack, 0.0) if begin > 0.0 else 0.0
		mi.visibility_range_end = end + slack if end > 0.0 else 0.0
		var swap := end if end > 0.0 else -begin
		if fade > 0.0 and swap != 0.0:
			var c := mesh.custom_aabb.get_center()
			mi.set_instance_shader_parameter(&"n64_lod_fade", Vector4(c.x, c.y, c.z, swap))
			mi.set_instance_shader_parameter(&"n64_lod_fade_band", fade)
		out.append(mi)
	return out


## A material's look with its colour and UV scale taken out: {key, material (shared by
## every surface with that key), tint (into the vertex colours), uv_scale (into the UVs),
## vertex_color (keep the mesh's own colours)}. Other materials batch only with themselves.
static var _looks := {}

static func _look(m: Material) -> Dictionary:
	var sm := m as ShaderMaterial
	if sm == null or sm.shader != TEXTURED:
		return {key = m.get_instance_id() if m else 0, material = m, atlas = false, tint = Color.WHITE, uv_scale = Vector2.ONE, vertex_color = true}
	# Atlas textures (whole-texture decals, e.g. a sign's writing) share one atlas texture.
	var atlas := sm.has_meta(&"atlas")
	var parts := ["atlas"] if atlas else []
	for u in sm.shader.get_shader_uniform_list():
		if FOLDED.has(StringName(u.name)) or (atlas and u.name == "albedo_texture"):
			continue
		var v = sm.get_shader_parameter(u.name)
		parts.append(v.get_instance_id() if v is Object else v)
	var key := var_to_str(parts)
	if not _looks.has(key):
		var shared := sm.duplicate() as ShaderMaterial
		shared.set_shader_parameter(&"albedo_color", Color.WHITE)
		shared.set_shader_parameter(&"use_vertex_color", true)
		shared.set_shader_parameter(&"uv_scale", Vector2.ONE)
		_looks[key] = shared
	var tint = sm.get_shader_parameter(&"albedo_color")
	var scale = sm.get_shader_parameter(&"uv_scale")
	# albedo_color is an sRGB colour the shader linearises; vertex colours aren't.
	return {key = key, material = _looks[key], atlas = atlas, texture = sm.get_shader_parameter(&"albedo_texture"), tint = (tint if tint != null else Color.WHITE).srgb_to_linear(),
		uv_scale = scale if scale != null else Vector2.ONE, vertex_color = sm.get_shader_parameter(&"use_vertex_color") == true}


## Packs the atlased surfaces' textures into one image (rows, PAD texels apart) and moves
## their UVs onto it; each such surface gets a material showing the atlas.
const PAD := 4

static func _pack(atlased: Array) -> void:
	if atlased.is_empty():
		return
	# The same faces as last time (a zone visited again): its atlas is kept for the session.
	var keys := {}  # texture -> its key (path, or instance for an unsaved one)
	for a in atlased:
		var tex: Texture2D = a[3]
		if tex and not keys.has(tex):
			keys[tex] = tex.resource_path if tex.resource_path != "" else str(tex.get_instance_id())
	var sorted: Array = keys.values()
	sorted.sort()
	var packed: Array = _packed.get(hash(sorted), [])
	if packed.is_empty():
		packed = _pack_atlas(keys)
		if _packed.size() >= PACKED_KEEP:
			_packed.clear()
		_packed[hash(sorted)] = packed
	var atlas_tex: ImageTexture = packed[0]
	var rects: Dictionary = packed[1]  # texture key -> Rect2i
	var size: Vector2 = packed[2]
	for a in atlased:
		var s: Dictionary = a[0]
		if not s.get("atlased", false):
			var m := (s.material as ShaderMaterial).duplicate() as ShaderMaterial
			m.set_shader_parameter(&"albedo_texture", atlas_tex)
			m.set_shader_parameter(&"has_texture", true)
			s.material = m
			s.atlased = true
		if a[3] == null or not rects.has(keys[a[3]]):
			continue
		var r := Rect2(rects[keys[a[3]]])
		for i in range(a[1], a[2]):
			var uv: Vector2 = s.uv[i]
			s.uv[i] = (r.position + uv.clamp(Vector2.ZERO, Vector2.ONE) * r.size) / size


## Packed atlases kept (by their faces) for zones visited again; dropped past PACKED_KEEP.
const PACKED_KEEP := 8
static var _packed := {}


## One texture holding every texture in `keys` (texture -> key): [ImageTexture, {key ->
## Rect2i}, size].
static func _pack_atlas(keys: Dictionary) -> Array:
	var images := {}  # texture -> Image
	for tex: Texture2D in keys:
		var img := tex.get_image()
		if img == null:
			continue
		if img.is_compressed():
			img.decompress()
		img.clear_mipmaps()
		img.convert(Image.FORMAT_RGBA8)
		images[tex] = img
	# Tallest first, in rows across a square-ish width.
	var order := images.keys()
	order.sort_custom(func(a, b): return images[a].get_height() > images[b].get_height())
	var area := 0
	for t in order:
		area += (images[t].get_width() + PAD * 2) * (images[t].get_height() + PAD * 2)
	var width := 64
	while width * width < area * 1.3:
		width *= 2
	var rects := {}
	var x := 0
	var y := 0
	var row := 0
	for t in order:
		var img: Image = images[t]
		var w := img.get_width() + PAD * 2
		if x + w > width:
			x = 0
			y += row
			row = 0
		rects[keys[t]] = Rect2i(x + PAD, y + PAD, img.get_width(), img.get_height())
		x += w
		row = maxi(row, img.get_height() + PAD * 2)
	var height := 64
	while height < y + row:
		height *= 2
	var atlas := Image.create(width, height, false, Image.FORMAT_RGBA8)
	for t in order:
		var img: Image = images[t]
		var r: Rect2i = rects[keys[t]]
		var w := r.size.x
		var h := r.size.y
		atlas.blit_rect(img, Rect2i(Vector2i.ZERO, r.size), r.position)
		# Edge texels smeared into the padding (strips, then the corners): no seams from
		# filtering / mips.
		for i in range(1, PAD + 1):
			atlas.blit_rect(img, Rect2i(0, 0, 1, h), r.position + Vector2i(-i, 0))
			atlas.blit_rect(img, Rect2i(w - 1, 0, 1, h), r.position + Vector2i(w - 1 + i, 0))
			atlas.blit_rect(img, Rect2i(0, 0, w, 1), r.position + Vector2i(0, -i))
			atlas.blit_rect(img, Rect2i(0, h - 1, w, 1), r.position + Vector2i(0, h - 1 + i))
		var pad := Vector2i(PAD, PAD)
		atlas.fill_rect(Rect2i(r.position - pad, pad), img.get_pixel(0, 0))
		atlas.fill_rect(Rect2i(r.position + Vector2i(w, -PAD), pad), img.get_pixel(w - 1, 0))
		atlas.fill_rect(Rect2i(r.position + Vector2i(-PAD, h), pad), img.get_pixel(0, h - 1))
		atlas.fill_rect(Rect2i(r.position + r.size, pad), img.get_pixel(w - 1, h - 1))
	atlas.generate_mipmaps()
	return [ImageTexture.create_from_image(atlas), rects, Vector2(width, height)]
