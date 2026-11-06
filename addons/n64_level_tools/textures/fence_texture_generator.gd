@tool
extends RefCounted
## Draws a FenceStyle's cutout textures from its material inputs (inspector: "Generate
## fence textures"): the panel for its Kind (rails, pickets, lattice, boards; alpha = gaps),
## a post, an end cap (post with a wider cap block; drawn twice the post's width) and an
## arch. Materials are sampled at their own world size, so the wood grain keeps its scale.
## Saved as N64Textures next to the style (<style>_panel.res, ...) and assigned to it;
## generating again updates those files in place (levels using them follow).

const SHADE_LIGHT := 1.2
const SHADE_DARK := 0.62


## Returns an error message ("" = done).
static func generate(style: FenceStyle) -> String:
	if style.resource_path.is_empty() or style.resource_path.contains("::"):
		return "Save the fence style as its own .tres first (the textures are saved next to it)."
	var rail := _source(style.rail_material, style.material_grain)
	if rail.is_empty():
		return "Set a rail material (e.g. a wood texture) first."
	var post := _source(style.post_material, style.material_grain) if style.post_material else rail
	var tpm := float(style.texels_per_metre)
	var base := style.resource_path.get_basename()

	# Panel: one repeat of the pattern, panel_height tall.
	var aspect := 2.0 if style.kind in [FenceStyle.Kind.TWO_RAIL, FenceStyle.Kind.THREE_RAIL] else 1.0
	var ph := _pow2(style.panel_height * tpm, 16, 128)
	var panel := _panel(style.kind, Vector2i(int(ph * aspect), ph), style.panel_height, rail)
	style.panel_texture = _save(panel, base + "_panel.res")

	# Post and end cap (the cap is drawn twice the post's width: post in the middle half).
	var pw := _pow2(style.post_width * tpm, 8, 64)
	var pht := _pow2(style.post_height * tpm, 16, 128)
	style.post_texture = _save(_post(Vector2i(pw, pht), style.post_width, style.post_height, post, false), base + "_post.res")
	var cap_h := style.end_cap_height if style.end_cap_height > 0.0 else style.post_height
	style.end_cap_texture = _save(_post(Vector2i(pw * 2, _pow2(cap_h * tpm, 16, 128)), style.post_width * 2.0, cap_h, post, true),
		base + "_cap.res")
	style.end_cap_width = style.post_width * 2.0

	# Arch: a curved beam the arch quad's height, twice as wide.
	var ah := _pow2(style.arch_height * tpm, 16, 128)
	style.arch_texture = _save(_arch(Vector2i(ah * 2, ah), style.arch_height, style.panel_height, rail),
		base + "_arch.res")
	ResourceSaver.save(style)
	return ""


## {img (RGBA8, no mipmaps), ppm (texels per metre), side (grain runs side to side)} of a
## material, or {}. Auto grain: the direction its brightness changes least along.
static func _source(tex: Texture2D, grain := FenceStyle.Grain.AUTO) -> Dictionary:
	if tex == null or tex.get_image() == null:
		return {}
	var img: Image = tex.get_image().duplicate()
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	var metres := PaintAtlas.tile_size(tex, 1.0)
	var side := grain == FenceStyle.Grain.SIDE_TO_SIDE
	if grain == FenceStyle.Grain.AUTO:
		var gx := 0.0
		var gy := 0.0
		for y in range(0, img.get_height() - 1):
			for x in range(0, img.get_width() - 1):
				var c := img.get_pixel(x, y).get_luminance()
				gx += absf(img.get_pixel(x + 1, y).get_luminance() - c)
				gy += absf(img.get_pixel(x, y + 1).get_luminance() - c)
		side = gy > gx  # stripes along x change most going down
	return {img = img, ppm = img.get_width() / maxf(metres, 0.01), side = side}


## The material at a point (metres), tiled, its grain running side to side (`side`) or up
## and down.
static func _grain(src: Dictionary, x: float, y: float, side: bool) -> Color:
	return _at(src, x, y, src.side != side)


## The material at a point (metres), tiled; `turned`: sampled 90° round.
static func _at(src: Dictionary, x: float, y: float, turned := false) -> Color:
	var img: Image = src.img
	var u := y if turned else x
	var v := x if turned else y
	return img.get_pixel(posmod(int(floor(u * src.ppm)), img.get_width()), posmod(int(floor(v * src.ppm)), img.get_height()))


static func _pow2(px: float, lo: int, hi: int) -> int:
	return clampi(nearest_po2(maxi(int(round(px)), 1)), lo, hi)


static func _shade(c: Color, k: float) -> Color:
	return Color(minf(c.r * k, 1.0), minf(c.g * k, 1.0), minf(c.b * k, 1.0), 1.0)


static func _panel(kind: FenceStyle.Kind, size: Vector2i, height_m: float, src: Dictionary) -> Image:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var mpp := height_m / size.y  # metres per texel
	var bands := []  # horizontal rails: [top, bottom] as fractions of the height, darker = behind
	match kind:
		FenceStyle.Kind.TWO_RAIL:
			bands = [[0.18, 0.36, 1.0], [0.6, 0.78, 1.0]]
		FenceStyle.Kind.THREE_RAIL:
			bands = [[0.08, 0.22, 1.0], [0.43, 0.57, 1.0], [0.78, 0.92, 1.0]]
		FenceStyle.Kind.PICKET:
			bands = [[0.3, 0.38, 0.7], [0.72, 0.8, 0.7]]
		FenceStyle.Kind.LATTICE:
			bands = [[0.0, 0.1, 1.0], [0.9, 1.0, 1.0]]
	for b in bands:
		var y0 := int(round(b[0] * size.y))
		var y1 := maxi(int(round(b[1] * size.y)), y0 + 2)
		for y in range(y0, mini(y1, size.y)):
			var k: float = b[2] * (SHADE_LIGHT if y == y0 else (SHADE_DARK if y == y1 - 1 else 1.0))
			for x in size.x:
				img.set_pixel(x, y, _shade(_grain(src, x * mpp, y * mpp, true), k))
	match kind:
		FenceStyle.Kind.PICKET:
			# Two pickets per repeat, pointed tops, in front of the rails.
			for centre in [0.25, 0.75]:
				var hw := 0.09 * size.x
				for x in size.x:
					var dx := absf(x + 0.5 - centre * size.x)
					if dx > hw:
						continue
					var top := int(round((0.03 + dx / hw * 0.1) * size.y))
					var edge := dx > hw - 1.0
					for y in range(top, size.y):
						var k := SHADE_LIGHT if edge and x < centre * size.x else (SHADE_DARK if edge else 1.0)
						img.set_pixel(x, y, _shade(_grain(src, x * mpp, y * mpp, false), k))
		FenceStyle.Kind.LATTICE:
			# Diagonal slats both ways, period half the height (repeats seamlessly).
			var period := size.y * 0.5
			var t := maxf(2.0, size.y * 0.07)
			for y in range(int(0.1 * size.y), int(0.9 * size.y)):
				for x in size.x:
					var a := fposmod(x + y, period)
					var b := fposmod(x - y, period)
					if a < t or b < t:
						var k := SHADE_DARK if (a < t and a >= t - 1.0) or (b < t and b >= t - 1.0) else 1.0
						img.set_pixel(x, y, _shade(_grain(src, x * mpp, y * mpp, a < t), k))
		FenceStyle.Kind.BOARDS:
			# Solid vertical boards, a dark seam every quarter.
			for y in size.y:
				for x in size.x:
					var seam := x % maxi(size.x / 4, 2) == 0
					img.set_pixel(x, y, _shade(_grain(src, x * mpp, y * mpp, false), SHADE_DARK if seam else 1.0))
	return img


## Post (or end cap: post in the middle half, a block across the top fifth).
static func _post(size: Vector2i, width_m: float, height_m: float, src: Dictionary, cap: bool) -> Image:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var mpx := width_m / size.x
	var mpy := height_m / size.y
	var x0 := size.x / 4 if cap else 0
	var x1 := size.x - x0
	var cap_rows := int(round(size.y * 0.2)) if cap else 0
	for y in size.y:
		var in_cap := y < cap_rows
		var lo := 0 if in_cap else x0
		var hi := size.x if in_cap else x1
		for x in range(lo, hi):
			var k := 1.0
			if x == lo or y == 0:
				k = SHADE_LIGHT
			elif x == hi - 1 or (in_cap and y == cap_rows - 1):
				k = SHADE_DARK
			# Posts: grain up and down (the cap block: side to side).
			img.set_pixel(x, y, _shade(_grain(src, x * mpx, y * mpy, in_cap), k))
	return img


## Curved beam: the band between two half-ellipses meeting the quad's bottom corners.
static func _arch(size: Vector2i, height_m: float, panel_height: float, src: Dictionary) -> Image:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var mpp := height_m / size.y
	var t := clampf(panel_height * 0.18 / mpp, 3.0, size.y * 0.45)  # beam thickness, texels
	var c := Vector2(size.x * 0.5, size.y)
	var outer := Vector2(size.x * 0.5, size.y)
	var inner := outer - Vector2(t, t)
	for y in size.y:
		for x in size.x:
			var p := Vector2(x + 0.5, y + 0.5) - c
			var o := (p / outer).length()
			var i := (p / inner).length()
			if o <= 1.0 and i >= 1.0:
				var k := SHADE_LIGHT if o > 1.0 - 1.5 / size.y else (SHADE_DARK if i < 1.0 + 1.5 / size.y else 1.0)
				img.set_pixel(x, y, _shade(_grain(src, x * mpp, y * mpp, true), k))
	return img


## Saves `img` as an N64Texture at `path` (updating the one there in place, so levels
## already using it follow) and returns it.
static func _save(img: Image, path: String) -> N64Texture:
	var tex: N64Texture = load(path) if ResourceLoader.exists(path) else N64Texture.new()
	tex.format = N64TextureConverter.Format.RGBA16
	tex.texture_size = img.get_size()
	tex.anti_tiling = 0
	tex.tint_mode = N64TextureConverter.TintMode.NONE
	tex.set_image(N64TextureLibrary.with_mipmaps(img))
	tex.emit_changed()
	if tex.resource_path.is_empty():
		ResourceSaver.save(tex, path)
		tex.take_over_path(path)
	else:
		ResourceSaver.save(tex)
	return tex
