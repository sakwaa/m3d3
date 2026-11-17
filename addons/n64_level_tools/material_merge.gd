@tool
class_name MaterialMerge
extends RefCounted
## The build's draw-call merge (Build & Play, export; LevelBaker.bake with optimize): the
## plain surfaces of each baked mesh - paint_hybrid, a square base texture, no overlay
## layers, stairs, scrolling or flipbook - become one surface drawn with paint_merged, which
## reads their base textures from one Texture2DArray (each upscaled by a whole number to the
## largest size, read at its native size so the N64 filter and mips match) and their
## settings from a small table, by a material index in UV2.x. Everything else keeps its own
## surface. Ground surfaces merge among themselves (the build report finds them by name).

## Project setting: n64/build/material_merge (on / off).
const SETTING := "n64/build/material_merge"
const SHADER := preload("res://addons/n64_runtime/shaders/paint_merged.gdshader")
const HYBRID := "res://addons/n64_runtime/shaders/paint_hybrid.gdshader"
## Settings that must match across merged materials (one value for the whole merged material).
const SHARED := [&"vertex_color_scale", &"variation_tex", &"light_keys", &"light_contrast", &"bake_strength",
	&"light_floor", &"timed_bake"]


## Merges `meshes` (one level's baked meshes, each with its "formats" meta) in place.
## Returns {surfaces_before, surfaces_after}.
static func merge(meshes: Array) -> Dictionary:
	var before := 0
	for m: ArrayMesh in meshes:
		before += m.get_surface_count()
	# The level's mergeable materials, their textures and settings.
	var mats := {}  # material -> index
	var shared := {}
	for m: ArrayMesh in meshes:
		for si in m.get_surface_count():
			var mat := m.surface_get_material(si) as ShaderMaterial
			if mat and not mats.has(mat) and _plain(mat, shared):
				mats[mat] = mats.size()
	if mats.size() < 2:
		return {surfaces_before = before, surfaces_after = before}
	var textures := {}  # Texture2D -> layer
	var size := 1
	for mat: ShaderMaterial in mats:
		var t: Texture2D = mat.get_shader_parameter(&"base_tex")
		if not textures.has(t):
			textures[t] = textures.size()
			size = maxi(size, t.get_width())
	var images: Array[Image] = []
	for t: Texture2D in textures:
		images.append(_at_size_keep_mips(t.get_image(), size))
	var array := Texture2DArray.new()
	array.create_from_images(images)
	# Base textures' own variation textures (not the shared noise): one array, layer + 1 in
	# the table (0 = shared noise).
	var var_layers := {}  # Texture2D -> layer
	var var_size := 1
	for mat: ShaderMaterial in mats:
		var vt = mat.get_shader_parameter(&"base_variation_tex")
		if vt is Texture2D and vt != shared.get(&"variation_tex") and not var_layers.has(vt):
			var_layers[vt] = var_layers.size()
			var_size = maxi(var_size, maxi(vt.get_width(), vt.get_height()))
	var var_images: Array[Image] = []
	for vt: Texture2D in var_layers:
		var img := vt.get_image()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		img.clear_mipmaps()
		img.resize(var_size, var_size, Image.INTERPOLATE_BILINEAR)
		img.generate_mipmaps()
		var_images.append(img)
	# (Colours as paint_hybrid gets them: its source_color uniforms arrive converted to linear.)
	var table := Image.create(mats.size(), 10, false, Image.FORMAT_RGBAF)
	for mat: ShaderMaterial in mats:
		var i: int = mats[mat]
		var t: Texture2D = mat.get_shader_parameter(&"base_tex")
		var anti: Vector2 = _param(mat, &"base_anti", Vector2(0.0, 0.75))
		var dark: Color = _col(_param(mat, &"base_tint_dark", Color(0.2, 0.2, 0.2))).srgb_to_linear()
		var light: Color = _col(_param(mat, &"base_tint_light", Color.WHITE)).srgb_to_linear()
		var extra: Vector3 = _param(mat, &"base_tint_extra", Vector3(1, 0, 1))
		var tint: Color = _col(_param(mat, &"base_tint", Color.WHITE)).srgb_to_linear()
		var v: Vector3 = _param(mat, &"base_var", Vector3(0, 8, 0))
		table.set_pixel(i, 0, Color(_param(mat, &"base_tile", 1.0), anti.x, anti.y, t.get_width()))
		table.set_pixel(i, 1, Color(_param(mat, &"base_tint_mode", 0.0), dark.r, dark.g, dark.b))
		table.set_pixel(i, 2, Color(1.0 if _param(mat, &"base_recolour", false) else 0.0, light.r, light.g, light.b))
		table.set_pixel(i, 3, Color(extra.x, extra.y, extra.z, textures[t]))
		table.set_pixel(i, 4, tint)
		var vt = mat.get_shader_parameter(&"base_variation_tex")
		table.set_pixel(i, 5, Color(v.x, v.y, v.z, float(var_layers[vt] + 1) if var_layers.has(vt) else 0.0))
		for k in 4:
			var adj: Vector4 = _param(mat, StringName("base_adj%d" % k), Vector4.ZERO)
			table.set_pixel(i, 6 + k, Color(adj.x, adj.y, adj.z, adj.w))
	var merged_mat := ShaderMaterial.new()
	merged_mat.shader = SHADER
	merged_mat.set_shader_parameter(&"base_array", array)
	merged_mat.set_shader_parameter(&"params", ImageTexture.create_from_image(table))
	merged_mat.set_shader_parameter(&"array_size", float(size))
	if not var_images.is_empty():
		var var_array := Texture2DArray.new()
		var_array.create_from_images(var_images)
		merged_mat.set_shader_parameter(&"variation_array", var_array)
	for k in shared:
		merged_mat.set_shader_parameter(k, shared[k])
	var after := 0
	for mi in meshes.size():
		_merge_mesh(meshes[mi], mats, merged_mat)
		after += (meshes[mi] as ArrayMesh).get_surface_count()
	return {surfaces_before = before, surfaces_after = after}


## Whether `mat` can merge (and its shared settings match the others').
static func _plain(mat: ShaderMaterial, shared: Dictionary) -> bool:
	if mat.shader == null or mat.shader.resource_path != HYBRID:
		return false
	var t = mat.get_shader_parameter(&"base_tex")
	if not (t is Texture2D) or not _param(mat, &"has_base", false) or t.get_width() != t.get_height():
		return false
	if not is_equal_approx(log(float(t.get_width())) / log(2.0), round(log(float(t.get_width())) / log(2.0))):
		return false  # (whole-number upscales need powers of two)
	if int(_param(mat, &"layer_count", 0)) != 0 or _param(mat, &"stair_on", false):
		return false
	# (paint_merged reads plain colour textures: not palette indices, wrap modes or detail)
	if _param(mat, &"base_use_palette", false) or _param(mat, &"base_wrap", Vector2i.ZERO) != Vector2i.ZERO or int(_param(mat, &"base_lod_mode", 0)) != 0 or float(_param(mat, &"soft_ground", 0.0)) > 0.0:
		return false
	if not is_zero_approx((_param(mat, &"base_scroll", Vector4.ZERO) as Vector4).w) or float((_param(mat, &"base_flip", Vector4(1, 1, 1, 0)) as Vector4).z) > 1.5:
		return false
	for k in SHARED:
		var v = mat.get_shader_parameter(k)
		if shared.has(k):
			if shared[k] != v:
				return false
	for k in SHARED:
		if not shared.has(k):
			shared[k] = mat.get_shader_parameter(k)
	return true


static func _param(mat: ShaderMaterial, name: StringName, fallback: Variant) -> Variant:
	var v = mat.get_shader_parameter(name)
	return fallback if v == null else v


static func _col(v: Variant) -> Color:
	if v is Color:
		return v
	if v is Vector3:
		return Color(v.x, v.y, v.z)
	if v is Vector4:
		return Color(v.x, v.y, v.z, v.w)
	return Color.WHITE


## Rebuilds `mesh`'s surfaces: mergeable ones (by ground / not) into one each, the rest as
## they were.
static func _merge_mesh(mesh: ArrayMesh, mats: Dictionary, merged_mat: ShaderMaterial) -> void:
	var formats: PackedInt32Array = mesh.get_meta(&"formats", PackedInt32Array())
	var keep := []  # [arrays, material, name, flags]
	var groups := {}  # ground -> [arrays...]
	var gflags := {}
	for si in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(si)
		var mat := mesh.surface_get_material(si)
		var flags := formats[si] if si < formats.size() else 0
		var name := mesh.surface_get_name(si)
		if mats.has(mat):
			var g := name == "ground"
			var n: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			var uv2 := PackedVector2Array()
			uv2.resize(n)
			uv2.fill(Vector2(mats[mat], 0.0))
			arrays[Mesh.ARRAY_TEX_UV2] = uv2
			groups.get_or_add(g, []).append(arrays)
			gflags[g] = flags
		else:
			keep.append([arrays, mat, name, flags])
	if groups.is_empty() or (groups.size() == 1 and groups.values()[0].size() < 2 and keep.is_empty()):
		return
	var meta := {}
	for k in mesh.get_meta_list():
		meta[k] = mesh.get_meta(k)
	var aabb := mesh.custom_aabb
	mesh.clear_surfaces()
	var out_formats := PackedInt32Array()
	for k in keep:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, k[0], [], {}, k[3])
		var si := mesh.get_surface_count() - 1
		mesh.surface_set_material(si, k[1])
		if k[2] != "":
			mesh.surface_set_name(si, k[2])
		out_formats.append(k[3])
	for g in groups:
		var parts: Array = groups[g]
		var joined := _join(parts)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, joined, [], {}, gflags[g])
		var si := mesh.get_surface_count() - 1
		mesh.surface_set_material(si, merged_mat)
		if g:
			mesh.surface_set_name(si, "ground")
		out_formats.append(gflags[g])
	for k in meta:
		mesh.set_meta(k, meta[k])
	mesh.set_meta(&"formats", out_formats)
	mesh.custom_aabb = aabb


## Surface arrays appended into one (indices offset).
static func _join(parts: Array) -> Array:
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	for slot in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_COLOR,
			Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
		var first = parts[0][slot]
		if first == null:
			continue
		var acc = first.duplicate()
		for i in range(1, parts.size()):
			acc.append_array(parts[i][slot])
		out[slot] = acc
	var idx := PackedInt32Array()
	var base := 0
	for p in parts:
		for i: int in p[Mesh.ARRAY_INDEX]:
			idx.append(base + i)
		base += (p[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	out[Mesh.ARRAY_INDEX] = idx
	return out


## `src` as a size x size layer with a full mip chain, keeping the texture's own levels (N64
## textures carry hand-made ones: N64TextureConverter.mip_chain): levels bigger than the
## texture are it blown up texel for texel, the rest are its own levels. Non-square or odd
## sizes fall back to generated levels.
static func _at_size_keep_mips(src: Image, size: int) -> Image:
	var img := src.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var k := size / maxi(w, 1)
	if not img.has_mipmaps() or w != img.get_height() or k < 1 or k * w != size or (k & (k - 1)) != 0:
		img.clear_mipmaps()
		img.resize(size, size, Image.INTERPOLATE_NEAREST)
		img.generate_mipmaps()
		return img
	if k == 1:
		return img
	var shift := int(round(log(k) / log(2.0)))
	var base := img.get_region(Rect2i(0, 0, w, w))  # (level 0 alone)
	base.clear_mipmaps()  # (get_region keeps them, and resize would rebuild them)
	var data := PackedByteArray()
	var n := Image.create_empty(size, size, true, Image.FORMAT_RGBA8).get_mipmap_count()
	for m in n + 1:
		var lsz := maxi(size >> m, 1)
		if m < shift:
			var up := base.duplicate() as Image
			up.resize(lsz, lsz, Image.INTERPOLATE_NEAREST)
			data.append_array(up.get_data())
		else:
			var own := m - shift
			var off := img.get_mipmap_offset(own)
			var bytes := lsz * lsz * 4
			data.append_array(img.get_data().slice(off, off + bytes))
	return Image.create_from_data(size, size, true, Image.FORMAT_RGBA8, data)

