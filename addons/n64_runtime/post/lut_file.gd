@tool
class_name LutFile
extends RefCounted
## Colour lookup tables in the forms they're found in, all turned into one: a strip of N
## slices of N x N side by side (red across a slice, green down, blue slice to slice), RGBA8.
##  - strip images (width = height²), as ScreenLook and the texture grade use;
##  - HaldCLUT images (square, side = L³; N = L²: the film-emulation packs);
##  - Adobe / Resolve .cube text files (LUT_3D_SIZE N, red fastest).
## Big tables are resampled to at most `max_n` levels (32 is plenty for 8-bit colour).

const DEFAULT_MAX := 32


## The strip for `img` (a strip or a HaldCLUT), or null if it's neither.
static func strip_from_image(img: Image, max_n := DEFAULT_MAX) -> Image:
	if img == null:
		return null
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	if h >= 2 and w == h * h:
		return _resampled(img, h, max_n)
	if w == h:
		var level := roundi(pow(float(w), 1.0 / 3.0))
		if level >= 2 and level * level * level == w:
			var n := level * level
			var strip := Image.create(n * n, n, false, Image.FORMAT_RGBA8)
			for b in n:
				for g in n:
					for r in n:
						var i := r + g * n + b * n * n
						strip.set_pixel(b * n + r, g, img.get_pixel(i % w, i / w))
			return _resampled(strip, n, max_n)
	return null


## The strip from a .cube file's text, or null.
static func strip_from_cube(text: String, max_n := DEFAULT_MAX) -> Image:
	var n := 0
	var values := PackedColorArray()
	var dmin := Vector3.ZERO
	var dmax := Vector3.ONE
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts := line.split(" ", false)
		var key := parts[0].to_upper()
		if key == "LUT_3D_SIZE":
			n = int(parts[1])
		elif key == "DOMAIN_MIN" and parts.size() >= 4:
			dmin = Vector3(float(parts[1]), float(parts[2]), float(parts[3]))
		elif key == "DOMAIN_MAX" and parts.size() >= 4:
			dmax = Vector3(float(parts[1]), float(parts[2]), float(parts[3]))
		elif key == "TITLE" or key == "LUT_1D_SIZE" or key.begins_with("LUT_"):
			if key == "LUT_1D_SIZE":
				return null  # (1D curves: not a colour cube)
		elif parts.size() >= 3 and parts[0].is_valid_float():
			var v := Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
			v = ((v - dmin) / (dmax - dmin).max(Vector3.ONE * 1e-6)).clamp(Vector3.ZERO, Vector3.ONE)
			values.append(Color(v.x, v.y, v.z))
	if n < 2 or values.size() < n * n * n:
		return null
	var strip := Image.create(n * n, n, false, Image.FORMAT_RGBA8)
	for b in n:
		for g in n:
			for r in n:
				strip.set_pixel(b * n + r, g, values[r + g * n + b * n * n])
	return _resampled(strip, n, max_n)


## The strip from a file (res:// or absolute): .cube, or an image (strip / HaldCLUT).
static func load_strip(path: String, max_n := DEFAULT_MAX) -> Image:
	if path.get_extension().to_lower() == "cube":
		return strip_from_cube(FileAccess.get_file_as_string(path), max_n)
	var img: Image
	if ResourceLoader.exists(path):
		var tex := load(path) as Texture2D
		img = tex.get_image() if tex else null
	else:
		img = Image.load_from_file(path)
	return strip_from_image(img, max_n)


## Levels of a strip.
static func levels(strip: Image) -> int:
	return strip.get_height() if strip else 0


## `c` (display colour) through the strip, trilinear.
static func apply(strip: Image, c: Color) -> Color:
	var n := strip.get_height()
	var g := Vector3(clampf(c.r, 0, 1), clampf(c.g, 0, 1), clampf(c.b, 0, 1)) * float(n - 1)
	var i0 := Vector3i(floori(g.x), floori(g.y), floori(g.z))
	var i1 := Vector3i(mini(i0.x + 1, n - 1), mini(i0.y + 1, n - 1), mini(i0.z + 1, n - 1))
	var f := g - Vector3(i0)
	var at := func(r: int, gg: int, b: int) -> Color: return strip.get_pixel(b * n + r, gg)
	var c00: Color = at.call(i0.x, i0.y, i0.z).lerp(at.call(i1.x, i0.y, i0.z), f.x)
	var c01: Color = at.call(i0.x, i1.y, i0.z).lerp(at.call(i1.x, i1.y, i0.z), f.x)
	var c10: Color = at.call(i0.x, i0.y, i1.z).lerp(at.call(i1.x, i0.y, i1.z), f.x)
	var c11: Color = at.call(i0.x, i1.y, i1.z).lerp(at.call(i1.x, i1.y, i1.z), f.x)
	var out := c00.lerp(c01, f.y).lerp(c10.lerp(c11, f.y), f.z)
	out.a = c.a
	return out


## An untouched strip (each colour maps to itself).
static func neutral(n := 16) -> Image:
	var img := Image.create(n * n, n, false, Image.FORMAT_RGBA8)
	for b in n:
		for g in n:
			for r in n:
				img.set_pixel(b * n + r, g, Color(r / float(n - 1), g / float(n - 1), b / float(n - 1)))
	return img


## `strip` (n levels) at no more than `max_n` levels.
static func _resampled(strip: Image, n: int, max_n: int) -> Image:
	if n <= max_n:
		return strip
	var out := Image.create(max_n * max_n, max_n, false, Image.FORMAT_RGBA8)
	for b in max_n:
		for g in max_n:
			for r in max_n:
				out.set_pixel(b * max_n + r, g, apply(strip, Color(r / float(max_n - 1), g / float(max_n - 1), b / float(max_n - 1))))
	return out
