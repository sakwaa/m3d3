extends RefCounted
## Preview of a texture grade (TextureGrade) on a loaded level, in memory only (nothing
## saved): every N64Texture a material uses gets its finished image graded, and merged
## Texture2DArray layers are matched back to their textures and graded by category. Grades
## the final N64 images rather than re-converting from source (palettes aren't re-picked),
## so it's close to Apply To Textures, not exact. Used by shot.gd TEXGRADE=.

## `spec`: "current" (the project's texture_grade.tres) or "uniform:<sample name>" (that
## sample LUT on everything, no category LUTs / normalising).
static func apply(root: Node, spec: String) -> void:
	var g: TextureGrade
	if spec == "current":
		g = TextureGrade.current()
	else:
		g = TextureGrade.new()
		g.lut = load("res://textures/_grade/samples/%s.png" % spec.trim_prefix("uniform:"))
		g.category_strength = {&"effects": 0.0, &"signs": 0.0, &"sky": 0.0, &"variation": 0.0, &"shine": 0.0}
	if g == null:
		return
	var done := {}
	var arrays := {}
	var known: Array[N64Texture] = []
	for gi: GeometryInstance3D in root.find_children("*", "GeometryInstance3D", true, false):
		var mats: Array[Material] = []
		if gi.material_override:
			mats.append(gi.material_override)
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh:
			var mi := gi as MeshInstance3D
			for s in mi.mesh.get_surface_count():
				var m := mi.get_active_material(s)
				if m:
					mats.append(m)
		elif gi is MultiMeshInstance3D and (gi as MultiMeshInstance3D).multimesh and (gi as MultiMeshInstance3D).multimesh.mesh:
			var mm := (gi as MultiMeshInstance3D).multimesh.mesh
			for s in mm.get_surface_count():
				if mm.surface_get_material(s):
					mats.append(mm.surface_get_material(s))
		for m in mats:
			var sm := m as ShaderMaterial
			if sm == null or sm.shader == null:
				continue
			for u in sm.shader.get_shader_uniform_list():
				var v = sm.get_shader_parameter(u.name)
				if v is N64Texture and not done.has(v):
					done[v] = true
					known.append(v)
					_grade_texture(v, g)
				elif v is Texture2DArray:
					arrays[v] = true
			_retint(sm)
	# Merged arrays: each layer matched to the texture it came from (by its look).
	var lib := TextureGrade.library()
	for arr: Texture2DArray in arrays:
		for i in arr.get_layers():
			var img := arr.get_layer_data(i)
			if img == null:
				continue
			var t := _match(img, lib)
			var st := g.settings_for(t.grade_category() if t else &"", t.grade_amount if t else 1.0, t.resource_path if t else "")
			if st.is_empty():
				continue
			img = img.duplicate()
			if img.is_compressed():
				img.decompress()
			img.clear_mipmaps()
			img.convert(Image.FORMAT_RGBA8)
			N64TextureConverter.apply_grade(img, st)
			img.generate_mipmaps()
			arr.update_layer(img, i)
	print("[texgrade preview] %d textures, %d merged arrays" % [done.size(), arrays.size()])


static func _grade_texture(t: N64Texture, g: TextureGrade) -> void:
	var st := g.settings_for(t.grade_category(), t.grade_amount, t.resource_path)
	if st.is_empty():
		return
	var img := t.get_image()
	if img == null:
		return
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	N64TextureConverter.apply_grade(img, st)
	t.set_image(N64TextureLibrary.with_mipmaps(img))
	# Gradient-tinted textures take most of their colour from their two tints: Apply To
	# Textures re-picks auto tints from the graded image, so do the same here.
	if t.tint_mode == N64TextureConverter.TintMode.GRADIENT and t.tint_auto:
		var tints := N64TextureConverter.suggest_tints(img)
		t.tint_dark = tints[0]
		t.tint_light = tints[1]
		t.tint_range = Vector2(tints[0].get_luminance(), maxf(tints[1].get_luminance(), tints[0].get_luminance() + 0.01))


## A paint material's base / layer gradient tints, from its (graded) textures again.
static func _retint(sm: ShaderMaterial) -> void:
	var base = sm.get_shader_parameter(&"base_tex")
	if base is N64Texture:
		var tint := PaintAtlas.texture_tint(base)
		sm.set_shader_parameter(&"base_tint_mode", tint[0])
		sm.set_shader_parameter(&"base_tint_dark", tint[1])
		sm.set_shader_parameter(&"base_tint_light", tint[2])
		sm.set_shader_parameter(&"base_tint_extra", tint[3])
	for i in 4:
		var lt = sm.get_shader_parameter(StringName("layer_tex_%d" % i))
		if lt is N64Texture:
			var tint := PaintAtlas.texture_tint(lt)
			var light: Color = tint[2]
			sm.set_shader_parameter("grad_%d" % i, Vector4(tint[0], light.r, light.g, light.b))
			sm.set_shader_parameter("grad_dark_%d" % i, tint[1])
			sm.set_shader_parameter("grad_extra_%d" % i, tint[3])


static var _thumbs := {}


## The library texture whose image looks most like `img` (8 x 8 thumbnails).
static func _match(img: Image, lib: Array) -> N64Texture:
	var a := _thumb(img)
	var best: N64Texture = null
	var best_d := INF
	for e in lib:
		var t: N64Texture = e[1]
		if not _thumbs.has(t):
			var ti := t.get_image()
			_thumbs[t] = _thumb(ti) if ti else PackedFloat32Array()
		var b: PackedFloat32Array = _thumbs[t]
		if b.size() != a.size():
			continue
		var d := 0.0
		for k in a.size():
			d += (a[k] - b[k]) * (a[k] - b[k])
		if d < best_d:
			best_d = d
			best = t
	return best


static func _thumb(img: Image) -> PackedFloat32Array:
	var t := img.duplicate() as Image
	if t.is_compressed():
		t.decompress()
	t.clear_mipmaps()
	t.convert(Image.FORMAT_RGBA8)
	t.resize(8, 8, Image.INTERPOLATE_BILINEAR)
	var out := PackedFloat32Array()
	for y in 8:
		for x in 8:
			var c := t.get_pixel(x, y)
			out.append_array([c.r, c.g, c.b])
	return out
