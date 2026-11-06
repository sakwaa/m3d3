class_name PaintAtlas
extends RefCounted
## Packs every painted face's mask into one atlas per overlay layer (shared layout), and
## builds the paint ShaderMaterials. Used by LevelRoot (editor) and LevelBaker (bake).

const SHADER := preload("res://addons/n64_runtime/shaders/paint.gdshader")
## Baked lighting modes: unshaded variant (colour through ALBEDO, so decals apply).
const SHADER_UNSHADED := preload("res://addons/n64_runtime/shaders/paint_unshaded.gdshader")
const SHADER_HYBRID := preload("res://addons/n64_runtime/shaders/paint_hybrid.gdshader")
## Cutout variants (LevelBrush.cutout): double-sided, the base texture's alpha cuts holes.
const SHADER_CUTOUT := preload("res://addons/n64_runtime/shaders/paint_cutout.gdshader")
const SHADER_UNSHADED_CUTOUT := preload("res://addons/n64_runtime/shaders/paint_unshaded_cutout.gdshader")
const SHADER_HYBRID_CUTOUT := preload("res://addons/n64_runtime/shaders/paint_hybrid_cutout.gdshader")
## Shared seamless noise for repetition-breaking variation (all textures use it).
const VARIATION_NOISE := preload("res://addons/n64_runtime/textures/variation_noise.res")
const PAD := 2
## Top-left block left black: UV2 of unpainted faces points into it.
const EMPTY := 4

## Materials showing an animated texture: "<material id>:base" / ":layers" -> WeakRef.
## The level plugin runs the editor's n64_time clock only while one is alive.
static var _animated := {}


## {rects: {Vector2i(brush_index, face): Rect2i}, size: Vector2i}
static func layout(brushes: Array, painted_only := false) -> Dictionary:
	var items := []
	var area := EMPTY * EMPTY
	for bi in brushes.size():
		var brush: LevelBrush = brushes[bi]
		if brush == null:
			continue
		for f in brush.masked_faces():
			if f >= brush.get_face_count() or (painted_only and not face_painted(brush, f)):
				continue
			var sz := brush.get_face_mask_size(f)
			items.append([Vector2i(bi, f), sz])
			area += (sz.x + PAD * 2) * (sz.y + PAD * 2)
	items.sort_custom(func(a, b): return a[1].y > b[1].y)
	var width := 64
	while width * width < area * 1.3 and width < 4096:
		width *= 2
	var rects := {}
	var x := EMPTY + PAD
	var y := 0
	var row_h := EMPTY
	for item in items:
		var sz: Vector2i = item[1]
		var w := sz.x + PAD * 2
		if x + w > width:
			x = 0
			y += row_h
			row_h = 0
		rects[item[0]] = Rect2i(x + PAD, y + PAD, sz.x, sz.y)
		x += w
		row_h = maxi(row_h, sz.y + PAD * 2)
	var height := 64
	while height < y + row_h:
		height *= 2
	return {rects = rects, size = Vector2i(width, height)}


## A face mask with anything painted in it (erased masks stay stored, all zero).
static func mask_painted(img: Image) -> bool:
	if img == null:
		return false
	var data := img.get_data()
	# Values up to 2 are erase leftovers; count() runs natively (a byte loop is slow on big levels).
	return data.count(0) + data.count(1) + data.count(2) < data.size()


## Whether any overlay layer of the face has paint in it.
static func face_painted(brush: LevelBrush, face: int) -> bool:
	if not brush.face_has_mask(face):
		return false
	for l in LevelData.MAX_LAYERS:
		if mask_painted(brush.get_face_mask(face, l)):
			return true
	return false


static func empty_uv(atlas_size: Vector2i) -> Vector2:
	return Vector2(EMPTY * 0.5, EMPTY * 0.5) / Vector2(atlas_size)


static func chart_uv(chart: Rect2i, atlas_size: Vector2i, face_rect: Rect2, planar: Vector2) -> Vector2:
	var t := (planar - face_rect.position) / face_rect.size.max(Vector2(0.0001, 0.0001))
	return (Vector2(chart.position) + t * Vector2(chart.size)) / Vector2(atlas_size)


static func build_layer(brushes: Array, atlas: Dictionary, layer: int) -> Image:
	var img := Image.create(atlas.size.x, atlas.size.y, false, Image.FORMAT_L8)
	for key in atlas.rects:
		var brush: LevelBrush = brushes[key.x]
		var mask := brush.get_face_mask(key.y, layer)
		if mask:
			blit(img, atlas.rects[key], mask)
	return img


## Copies a face mask into its chart and extends its edges into the padding, so
## filtering at face borders never picks up a neighbouring chart.
static func blit(img: Image, chart: Rect2i, mask: Image) -> void:
	var m := mask
	if m.get_size() != chart.size:
		m = mask.duplicate()
		m.resize(chart.size.x, chart.size.y, Image.INTERPOLATE_BILINEAR)
	if m.get_format() != Image.FORMAT_L8:
		m = m.duplicate() if m == mask else m
		m.convert(Image.FORMAT_L8)
	img.blit_rect(m, Rect2i(Vector2i.ZERO, chart.size), chart.position)
	var full := chart.grow(PAD).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	for py in range(full.position.y, full.end.y):
		for px in range(full.position.x, full.end.x):
			if chart.has_point(Vector2i(px, py)):
				continue
			var sx := clampi(px, chart.position.x, chart.end.x - 1)
			var sy := clampi(py, chart.position.y, chart.end.y - 1)
			img.set_pixel(px, py, img.get_pixel(sx, sy))


## Paint material for one base texture (null = neutral grey), sharing the level's layers
## (overlay set `layer_set`, remembered on the material for refreshes).
static func make_material(base: Texture2D, data: LevelData, masks: Array, layer_set := 0, cutout := false) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	if layer_set > 0:
		mat.set_meta(&"layer_set", layer_set)
	match data.lighting_mode:
		LevelData.LightingMode.DYNAMIC:
			mat.shader = SHADER_CUTOUT if cutout else SHADER
		LevelData.LightingMode.BAKED_VERTEX_DYNAMIC, LevelData.LightingMode.BAKED_TIMED_DYNAMIC:
			mat.shader = SHADER_HYBRID_CUTOUT if cutout else SHADER_HYBRID
		_:
			mat.shader = SHADER_UNSHADED_CUTOUT if cutout else SHADER_UNSHADED
	# Stair textures render their base (density, tint, overlays' noise target all follow
	# it); apply_stair() adds the steps once the face run's frame is known.
	set_base(mat, base.base if base is N64StairTexture else base, data)
	apply_layers(mat, data, masks)
	mat.set_shader_parameter(&"vertex_color_scale", data.vertex_color_scale())
	return mat


## Overlay textures turned / shifted on this material's faces (LevelBrush overlay code).
static func set_overlay_code(mat: Material, code: int, data: LevelData) -> void:
	if not mat is ShaderMaterial or code == 0:
		return
	mat.set_shader_parameter(&"overlay_turns", code % 4)
	var frame := code / 4
	if frame > 0 and frame < data.overlay_offsets.size():
		mat.set_shader_parameter(&"overlay_offset", data.overlay_offsets[frame])
		if frame < data.overlay_angles.size():
			mat.set_shader_parameter(&"overlay_angle", data.overlay_angles[frame])
		if frame < data.overlay_bases.size():
			mat.set_shader_parameter(&"overlay_basis", data.overlay_bases[frame])
		if frame < data.overlay_stairs.size() and data.overlay_stairs[frame] != null:
			mat.set_meta(&"overlay_stair", data.overlay_stairs[frame])
			_apply_overlay_stair(mat, data)


## A border continuing a stair (LevelData.overlay_stairs): its overlay layer draws the
## stair's base at the stair's base tile, shaded by the template in folded stair UVs.
static func _apply_overlay_stair(mat: ShaderMaterial, data: LevelData) -> void:
	var st: Dictionary = mat.get_meta(&"overlay_stair")
	var stair := data.textures[st.texture] as N64StairTexture if st.texture >= 0 and st.texture < data.textures.size() else null
	var i: int = st.layer
	if stair == null or stair.base == null or i < 0 or i >= LevelData.MAX_LAYERS:
		mat.set_shader_parameter(&"overlay_stair_layer", -1)
		return
	mat.set_shader_parameter(&"overlay_stair_layer", i)
	mat.set_shader_parameter(&"overlay_stair_basis", st.basis)
	mat.set_shader_parameter(&"overlay_stair_offset", st.offset)
	mat.set_shader_parameter(&"stair_tex", stair.template_texture)
	mat.set_shader_parameter(&"stair_params", Vector3(stair.strength, stair.base_detail, stair.template_neutral))
	var m := stair.base_mean
	mat.set_shader_parameter(&"stair_base_mean", Vector3(m.r, m.g, m.b))
	mat.set_shader_parameter("layer_tex_%d" % i, stair.base)
	var p: Vector4 = mat.get_shader_parameter("layer_%d" % i)
	mat.set_shader_parameter("layer_%d" % i, Vector4(p.x, p.y, base_tile_for(stair, data), p.w))
	mat.set_shader_parameter("anti_%d" % i, anti_tiling(stair.base))
	var tint := texture_tint(stair.base)
	var light: Color = tint[2]
	mat.set_shader_parameter("grad_%d" % i, Vector4(tint[0], light.r, light.g, light.b))
	mat.set_shader_parameter("grad_dark_%d" % i, tint[1])
	mat.set_shader_parameter("grad_extra_%d" % i, tint[3])


## Re-applies the level's paint settings to a material made by make_material /
## convert_material (palette, tile, variation, layers…) for `base` and `tint`.
static func refresh_material(mat: ShaderMaterial, base: Texture2D, tint: Color, data: LevelData, masks: Array) -> void:
	set_base(mat, base.base if base is N64StairTexture else base, data, tint)
	apply_layers(mat, data, masks)
	mat.set_shader_parameter(&"vertex_color_scale", data.vertex_color_scale())


## Painted-on steps for one run of stair faces (frame from N64StairTexture.frame()).
static func apply_stair(mat: ShaderMaterial, stair: N64StairTexture, frame: Array[Vector4]) -> void:
	mat.set_shader_parameter(&"stair_on", true)
	mat.set_shader_parameter(&"stair_tex", stair.template_texture)
	mat.set_shader_parameter(&"stair_u", frame[0])
	mat.set_shader_parameter(&"stair_v", frame[1])
	mat.set_shader_parameter(&"stair_params", Vector3(stair.strength, stair.base_detail, stair.template_neutral))
	var m := stair.base_mean
	mat.set_shader_parameter(&"stair_base_mean", Vector3(m.r, m.g, m.b))


## A TextureLook renders its texture with the look's palette / colour / variation / tile
## (each falling back to the level's or texture's own).
static func set_base(mat: ShaderMaterial, base: Texture2D, data: LevelData, tint := Color.WHITE) -> void:
	var look := base as TextureLook
	if look:
		base = look.texture
		tint *= look.color
	mat.set_shader_parameter(&"has_base", base != null)
	mat.set_shader_parameter(&"base_tex", base)
	mat.set_shader_parameter(&"base_tint", tint)
	mat.set_shader_parameter(&"base_tile", look.tile if look and look.tile > 0.0 else base_tile_for(base, data))
	mat.set_shader_parameter(&"base_anti", anti_tiling(base))
	var anim: Array = base.anim_params() if base is N64Texture else [Vector4.ZERO, Vector4(1, 1, 1, 0)]
	mat.set_shader_parameter(&"base_scroll", anim[0])
	mat.set_shader_parameter(&"base_flip", anim[1])
	_mark_animated(mat, &"base", _is_animated(anim))
	mat.set_shader_parameter(&"variation_tex", VARIATION_NOISE)
	mat.set_shader_parameter(&"base_var", look.variation if look else base_variation_for(base, data))
	var palette = look.palette if look and look.palette.size() == 2 else (data.base_tints.get(base) if base else null)
	var combiner := texture_tint(base, palette)
	mat.set_shader_parameter(&"base_recolour", look != null and look.recolour)
	mat.set_shader_parameter(&"base_tint_mode", combiner[0])
	mat.set_shader_parameter(&"base_tint_dark", combiner[1])
	mat.set_shader_parameter(&"base_tint_light", combiner[2])
	mat.set_shader_parameter(&"base_tint_extra", combiner[3])


## [mode, dark, light, extra(amount, range lo, range hi)] for a texture. An override
## palette ([dark, light]) forces gradient mode but keeps the texture's amount and range;
## plain textures are untinted.
static func texture_tint(texture: Texture2D, override = null) -> Array:
	var extra := Vector3(1.0, 0.0, 1.0)
	if texture is N64Texture:
		extra = Vector3(texture.tint_amount, texture.tint_range.x, texture.tint_range.y)
	if override is PackedColorArray and override.size() == 2:
		return [2.0, override[0], override[1], extra]
	if texture is N64Texture:
		return [float(texture.tint_mode), texture.tint_dark, texture.tint_light, extra]
	return [0.0, Color(0.2, 0.2, 0.2), Color.WHITE, extra]


## Shader anti-tiling parameters (mode, hex size) of a texture; off for non-N64Textures.
## Offset + Rotate is sent as 1 + rotation amount; Row shuffle as 3.
static func anti_tiling(texture: Texture2D) -> Vector2:
	if texture is N64Texture:
		var mode: float = texture.anti_tiling
		if texture.anti_tiling == 2:
			mode = 1.0 + texture.anti_tiling_rotation
		return Vector2(mode, texture.anti_tiling_scale)
	return Vector2(0.0, 0.75)


## Variation (strength, metres per noise repeat, mode) of a base texture in a level.
static func base_variation_for(texture: Texture2D, data: LevelData) -> Vector3:
	if texture and data.base_variation.has(texture):
		return data.base_variation[texture]
	return Vector3(0.0, 8.0, 0.0)


## Metres per repeat of a base texture in a level: the level's override, else the
## texture's own world size, else the level fallback.
static func base_tile_for(texture: Texture2D, data: LevelData) -> float:
	if texture is N64StairTexture:  # renders its base
		texture = texture.base
	if texture and data.base_tile_sizes.has(texture):
		return data.base_tile_sizes[texture]
	return tile_size(texture, data.base_tile_size)


## Metres per repeat: an N64Texture's own (or Auto) size, else the fallback.
static func tile_size(texture: Texture2D, fallback: float) -> float:
	return texture.metres_per_repeat() if texture is N64Texture else fallback


## Brush `material`s render through the paint shader too, so they get 3-point filtering
## and can take overlays: StandardMaterial albedo texture/colour become the base. Other
## material types (custom shaders) are used as-is.
static func convert_material(material: Material, data: LevelData, masks: Array) -> Material:
	var std := material as BaseMaterial3D
	if std == null:
		return material
	var mat := make_material(std.albedo_texture, data, masks)
	if std.albedo_texture:
		mat.set_shader_parameter(&"base_tint", std.albedo_color)
	else:
		mat.set_shader_parameter(&"base_color", std.albedo_color)
	return mat


static func is_paint_shader(shader: Shader) -> bool:
	return shader in [SHADER, SHADER_UNSHADED, SHADER_HYBRID, SHADER_CUTOUT, SHADER_UNSHADED_CUTOUT, SHADER_HYBRID_CUTOUT]


## Baked surfaces: switches off overlay layers that can't show on this surface (nothing
## painted on its faces for that layer, and the layer's noise targets another base or is
## off), so the shader skips them outright; layer_count drops to the last useful layer.
## `painted`: bit per layer with painted coverage on the surface.
static func prune_layers(mat: ShaderMaterial, data: LevelData, painted: int) -> void:
	var count: int = mat.get_shader_parameter(&"layer_count")
	var last := -1
	for i in count:
		var p: Vector4 = mat.get_shader_parameter("layer_%d" % i)
		if p.w < 0.5:
			continue
		var noise: Vector4 = mat.get_shader_parameter("noise_%d" % i)
		var has_paint := (painted & (1 << i)) != 0
		# Mirrors layer_mask(): no noise -> painted; Noise only -> noise; Painted + noise ->
		# either; Break up (painted x noise) -> needs paint.
		var shows := has_paint
		if noise.x > 0.001 and noise.w < 1.5:
			shows = true
		if shows:
			last = i
		else:
			mat.set_shader_parameter("layer_%d" % i, Vector4(p.x, p.y, p.z, 0.0))
	mat.set_shader_parameter(&"layer_count", last + 1)


## Metres per repeat of a layer (0 = Auto: its texture's own size).
static func layer_tile(layer: Resource) -> float:
	var ts: float = layer.get("tile_size")
	if ts > 0.0:
		return ts
	var tex = layer.get("texture")
	return tex.metres_per_repeat() if tex is N64Texture else 1.0


static func apply_layers(mat: ShaderMaterial, data: LevelData, masks: Array) -> void:
	var layers := data.layers_of(mat.get_meta(&"layer_set", 0))
	var count := mini(layers.size(), LevelData.MAX_LAYERS)
	mat.set_shader_parameter(&"layer_count", count)
	var timed := LevelData.mode_is_timed(data.lighting_mode)
	mat.set_shader_parameter(&"vertex_lit", data.lighting_mode != LevelData.LightingMode.DYNAMIC)
	var schedule := LightingSchedule.load_project() if timed else null
	var keys := schedule.sorted_keys().size() if schedule else 0
	if data.lighting_mode == LevelData.LightingMode.BAKED_VERTEX_DYNAMIC:
		keys = 1  # the single bake rides in CUSTOM0, apart from the painted colours
	mat.set_shader_parameter(&"light_keys", keys)
	mat.set_shader_parameter(&"timed_bake", timed)
	mat.set_shader_parameter(&"light_contrast", data.light_contrast)
	mat.set_shader_parameter(&"bake_strength", data.light_bake_strength)
	var animated := false
	for i in LevelData.MAX_LAYERS:
		# Untyped on purpose: right after the paint layer script changes, the editor can hold
		# layers whose script is the previous version; a typed cast would turn them into
		# null (overlays baked as off). Their properties still read fine by name.
		var layer = layers[i] if i < count else null
		var on: bool = layer != null and layer.enabled
		# Without a texture the layer is a flat "shade" colour through its mask.
		var state: float = (1.0 if layer.texture else 2.0) if on else 0.0
		mat.set_shader_parameter("layer_tex_%d" % i, layer.texture if layer else null)
		mat.set_shader_parameter("mask_%d" % i, masks[i] if i < masks.size() else null)
		mat.set_shader_parameter("layer_%d" % i, Vector4(layer.blend if layer else 0, layer.opacity if layer else 0.0,
			layer_tile(layer) if layer else 1.0, state))
		mat.set_shader_parameter("tint_%d" % i, (layer.tint if layer.texture else layer.get_shade()) if layer else Color.WHITE)
		# Noise mask, off on materials whose base texture isn't the layer's target.
		var noise_on: bool = layer != null and layer.noise_coverage > 0.0 \
			and (layer.noise_base == null or layer.noise_base == mat.get_shader_parameter(&"base_tex"))
		mat.set_shader_parameter("noise_%d" % i, Vector4(layer.noise_coverage if noise_on else 0.0,
			layer.noise_size if layer else 4.0, layer.noise_softness if layer else 0.3, layer.noise_combine if layer else 1))
		mat.set_shader_parameter("var_%d" % i, Vector3(layer.variation, layer.variation_size, layer.variation_mode)
			if layer else Vector3(0.0, 8.0, 0.0))
		mat.set_shader_parameter("edge_%d" % i, Vector3(layer.edge_sharpness, layer.edge_noise, layer.edge_darken)
			if layer else Vector3(0.6, 0.5, 0.35))
		mat.set_shader_parameter("order_%d" % i, layer.order_offset(i) if layer and layer.has_method(&"order_offset") else 0.0)
		mat.set_shader_parameter("shadow_%d" % i, layer.edge_shadow if layer and &"edge_shadow" in layer else 0.0)
		mat.set_shader_parameter("anti_%d" % i, anti_tiling(layer.texture if layer else null))
		var anim: Array = layer.anim_params() if layer and layer.has_method(&"anim_params") else [Vector4.ZERO, Vector4(1, 1, 1, 0)]
		mat.set_shader_parameter("scroll_%d" % i, anim[0])
		mat.set_shader_parameter("flip_%d" % i, anim[1])
		animated = animated or (on and _is_animated(anim))
		var tint := texture_tint(layer.texture if layer else null,
			PackedColorArray([layer.tint_dark, layer.tint_light]) if layer and layer.override_tint else null)
		var light: Color = tint[2]
		mat.set_shader_parameter("grad_%d" % i, Vector4(tint[0], light.r, light.g, light.b))
		mat.set_shader_parameter("grad_dark_%d" % i, tint[1])
		mat.set_shader_parameter("grad_extra_%d" % i, tint[3])
	_mark_animated(mat, &"layers", animated)
	if mat.has_meta(&"overlay_stair"):
		_apply_overlay_stair(mat, data)


static func _is_animated(anim: Array) -> bool:
	return absf(anim[0].w) > 0.0001 or anim[1].z > 1.5


static func _mark_animated(mat: ShaderMaterial, slot: StringName, on: bool) -> void:
	var key := "%d:%s" % [mat.get_instance_id(), slot]
	if on:
		_animated[key] = weakref(mat)
	else:
		_animated.erase(key)


## Any live material showing an animated texture (drops freed ones).
static func any_animated() -> bool:
	for key in _animated.keys():
		if _animated[key].get_ref() == null:
			_animated.erase(key)
	return not _animated.is_empty()
