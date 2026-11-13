@tool
class_name GradeProcessor
extends RefCounted
## Runs filter chains over texture images (every mip level, each pixel through the chain),
## on worker threads. The same code makes the live preview and (step 4) the baked copies, so
## they can't differ. Colours seen before are reused unless a filter is per pixel (noise).


## The texture's pixels as RGBA8 with mipmaps (main thread), or null.
static func source_image(tex: Texture2D) -> Image:
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null or img.is_empty():
		return null
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


## `src` through `chain` (a new image; `src` untouched). Thread-safe. `tint`: the
## texture's combiner tint ([mode, dark, light, extra] as PaintAtlas.texture_tint gives;
## mode 0 / empty = none), applied first so the filters work on the colours the level shows
## (the level then skips its own tint for this texture: LevelRoot.set_grade_textures).
## Filters that look at the whole texture first (needs_image: palette ramps / fits) get a
## copy made for this texture as it is after the filters below them.
static func process(src: Image, chain: Array, tint: Array = []) -> Image:
	var data := src.get_data()
	var seg := []
	var tint_left := tint
	for f in chain:
		if f.needs_image():
			data = _pass(src, data, seg, tint_left)
			tint_left = []
			seg = [f.for_image(Image.create_from_data(src.get_width(), src.get_height(), src.has_mipmaps(), Image.FORMAT_RGBA8, data))]
		else:
			seg.append(f)
	data = _pass(src, data, seg, tint_left)
	return Image.create_from_data(src.get_width(), src.get_height(), src.has_mipmaps(), Image.FORMAT_RGBA8, data)


## One pass of `chain` (and `tint` first) over every texel of every mip level.
static func _pass(src: Image, data: PackedByteArray, chain: Array, tint: Array) -> PackedByteArray:
	var do_tint: bool = not tint.is_empty() and tint[0] > 0.5
	if chain.is_empty() and not do_tint:
		return data
	data = data.duplicate()
	var n := data.size() / 4
	var cache := {}
	var cacheable := true
	for f in chain:
		if f.per_pixel():
			cacheable = false
	# Texel positions per mip level (for position-dependent filters such as dither).
	var levels := src.get_mipmap_count() + 1 if src.has_mipmaps() else 1
	for m in levels:
		var start := src.get_mipmap_offset(m) / 4 if m > 0 else 0
		var w := maxi(src.get_width() >> m, 1)
		var h := maxi(src.get_height() >> m, 1)
		for y in h:
			for x in w:
				var p := start + y * w + x
				if p >= n:
					break
				var o := p * 4
				var key := data.decode_u32(o)
				if cacheable and cache.has(key):
					data.encode_u32(o, cache[key])
					continue
				var c := Color8(data[o], data[o + 1], data[o + 2], data[o + 3])
				if do_tint:
					c = combiner_tint(c, tint)
				var xy := Vector2i(x, y)
				for f in chain:
					c = f.run(c, p, xy)
				data[o] = clampi(roundi(c.r * 255.0), 0, 255)
				data[o + 1] = clampi(roundi(c.g * 255.0), 0, 255)
				data[o + 2] = clampi(roundi(c.b * 255.0), 0, 255)
				if cacheable:
					cache[key] = data.decode_u32(o)
	return data


## The paint shader's n64_tint on a display colour (the shader works in linear).
static func combiner_tint(c: Color, tint: Array) -> Color:
	var lin := c.srgb_to_linear()
	var dark: Color = (tint[1] as Color).srgb_to_linear()
	var light: Color = (tint[2] as Color).srgb_to_linear()
	var extra: Vector3 = tint[3]
	var t: Color
	if tint[0] < 1.5:
		t = Color(lin.r * light.r, lin.g * light.g, lin.b * light.b)
	else:
		var l := lin.r * 0.2126 + lin.g * 0.7152 + lin.b * 0.0722
		t = dark.lerp(light, clampf((l - extra.y) / maxf(extra.z - extra.y, 0.01), 0.0, 1.0))
	var o := lin.lerp(t, extra.x)
	o.a = c.a
	return o.clamp().linear_to_srgb()


## A chain's signature (skip work when nothing changed).
static func signature(chain: Array) -> String:
	var s := ""
	for f in chain:
		s += f.get_script().resource_path + f.signature() + ";"
	return s
