@tool
class_name N64PaletteTexture
extends Resource
## A CI4 / CI8 texture kept as the N64 kept it: palette indices plus a palette (TLUT), looked
## up per texel when drawn and filtered after the lookup, as the RDP did. Rows of `palettes`
## are swaps (row 0 = the original): every mesh using the same material picks its own with
## the `palette_row` instance parameter (N64Materials.set_palette_row), so one texture and
## one material dress an enemy's colour variants, team colours, a house's awnings...
## Made from an N64Texture with from_texture(); n64_textured / n64_actor draw it
## (N64Materials.use_palette).

## Palette indices (R8, index / 255), with mip levels re-indexed from the shrunk colours.
@export var index: ImageTexture
## The palette rows (row 0 the original); all the same length.
@export var palettes: Array[PackedColorArray] = []:
	set(v):
		palettes = v
		_lut = null
		emit_changed()

var _lut: ImageTexture


## The palettes as a texture: a row each, an entry per texel (nearest, no mips).
func lut() -> ImageTexture:
	if _lut == null and not palettes.is_empty():
		var n := 0
		for p in palettes:
			n = maxi(n, p.size())
		var img := Image.create(maxi(n, 1), palettes.size(), false, Image.FORMAT_RGBA8)
		for r in palettes.size():
			for i in palettes[r].size():
				img.set_pixel(i, r, palettes[r][i])
		_lut = ImageTexture.create_from_image(img)
	return _lut


## Adds a swap: row 0 with each colour's hue turned `hue` (0..1), saturation and value
## scaled. Returns its row.
func add_shifted(hue: float, saturation := 1.0, value := 1.0) -> int:
	var row := PackedColorArray()
	for c in palettes[0]:
		row.append(Color.from_hsv(fposmod(c.h + hue, 1.0), clampf(c.s * saturation, 0.0, 1.0),
			clampf(c.v * value, 0.0, 1.0), c.a))
	var all := palettes.duplicate()
	all.append(row)
	palettes = all
	return all.size() - 1


## From a texture whose texels are all palette colours (an N64Texture in CI4 / CI8: its
## image and `palette`). Mip levels: the colours shrunk, then each texel the nearest entry.
static func from_texture(tex: Texture2D, palette: PackedColorArray) -> N64PaletteTexture:
	var src := tex.get_image().duplicate() as Image
	if src.is_compressed():
		src.decompress()
	src.clear_mipmaps()
	src.convert(Image.FORMAT_RGBA8)
	var w := src.get_width()
	var h := src.get_height()
	var data := PackedByteArray()
	var level := src
	while true:
		data.append_array(_indices(level, palette))
		if level.get_width() == 1 and level.get_height() == 1:
			break
		level = level.duplicate()
		level.resize(maxi(level.get_width() / 2, 1), maxi(level.get_height() / 2, 1), Image.INTERPOLATE_BILINEAR)
	var img := Image.create_from_data(w, h, true, Image.FORMAT_R8, data)
	var t := N64PaletteTexture.new()
	t.index = ImageTexture.create_from_image(img)
	t.palettes = [palette]
	return t


## From palette indices (`w` x `h`, one byte each) and the palette rows. Mip levels pick, for
## each 2 x 2 block, the block's index whose colour (row 0) is nearest the block's average,
## so a level never invents an index the block didn't have (two-colour halves stay apart).
static func from_indices(w: int, h: int, idx: PackedByteArray, rows: Array[PackedColorArray]) -> N64PaletteTexture:
	var ref := rows[0]
	var data := idx.duplicate()
	var level := idx
	var lw := w
	var lh := h
	while lw > 1 or lh > 1:
		var nw := maxi(lw / 2, 1)
		var nh := maxi(lh / 2, 1)
		var next := PackedByteArray()
		next.resize(nw * nh)
		for y in nh:
			for x in nw:
				var cand: Array[int] = []
				var avg := Color(0, 0, 0, 0)
				for dy in 2:
					for dx in 2:
						var k: int = level[mini(y * 2 + dy, lh - 1) * lw + mini(x * 2 + dx, lw - 1)]
						cand.append(k)
						avg += ref[k] if k < ref.size() else Color.BLACK
				avg /= 4.0
				var best: int = cand[0]
				var bd := INF
				for k in cand:
					var c: Color = ref[k] if k < ref.size() else Color.BLACK
					var d := (c.r - avg.r) ** 2 + (c.g - avg.g) ** 2 + (c.b - avg.b) ** 2
					if d < bd:
						bd = d
						best = k
				next[y * nw + x] = best
		data.append_array(next)
		level = next
		lw = nw
		lh = nh
	var t := N64PaletteTexture.new()
	t.index = ImageTexture.create_from_image(Image.create_from_data(w, h, true, Image.FORMAT_R8, data))
	t.palettes = rows
	return t


## Row `row` drawn out as colours (`w` x `h`, mipmapped): previews and anything that wants a
## plain texture.
func render_row(row: int) -> Image:
	var src := index.get_image().duplicate() as Image  # (get_image can hand back the stored image itself)
	src.clear_mipmaps()
	var pal := palettes[clampi(row, 0, palettes.size() - 1)]
	var img := Image.create(src.get_width(), src.get_height(), false, Image.FORMAT_RGBA8)
	for y in src.get_height():
		for x in src.get_width():
			var k := roundi(src.get_pixel(x, y).r * 255.0)
			img.set_pixel(x, y, pal[k] if k < pal.size() else Color.BLACK)
	img.generate_mipmaps()
	return img


## Row `row`'s average brightness (the shader's texel height reference: the index texture's
## own average means nothing).
func mean_luma(row: int) -> float:
	var src := index.get_image().duplicate() as Image  # (get_image can hand back the stored image itself)
	src.clear_mipmaps()
	var pal := palettes[clampi(row, 0, palettes.size() - 1)]
	var sum := 0.0
	for y in src.get_height():
		for x in src.get_width():
			var k := roundi(src.get_pixel(x, y).r * 255.0)
			var c: Color = pal[k] if k < pal.size() else Color.BLACK
			sum += c.r * 0.299 + c.g * 0.587 + c.b * 0.114
	return sum / float(src.get_width() * src.get_height())


static func _indices(img: Image, palette: PackedColorArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(img.get_width() * img.get_height())
	var cache := {}
	var k := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var key := c.to_rgba32()
			var best: int = cache.get(key, -1)
			if best < 0:
				var bd := INF
				for i in palette.size():
					var p := palette[i]
					var d := (p.r - c.r) ** 2 + (p.g - c.g) ** 2 + (p.b - c.b) ** 2 + (p.a - c.a) ** 2
					if d < bd:
						bd = d
						best = i
				cache[key] = best
			out[k] = best
			k += 1
	return out
