@tool
extends RefCounted
## Draws the rope tool's default textures, saved as N64Textures (RGBA16) under DIR:
## twisted rope (hemp, or straw for a shimenawa: strands running left to right, tiling
## along the rope, a scalloped cutout silhouette where they turn), and the hang cards: a
## shimenawa straw tassel, a zigzag shide paper streamer, and cloth banners (one per colour
## / crest combination).

const FenceTextureGenerator := preload("res://addons/n64_level_tools/textures/fence_texture_generator.gd")
const GlyphText := preload("res://addons/n64_level_tools/glyphs/glyph_text.gd")

const DIR := "res://textures/rope/"
const SIZE := Vector2i(32, 8)
## Pixels between strand twists along the rope (divides SIZE.x so it tiles).
const PERIOD := 8
const HEMP := Color(0.66, 0.53, 0.35)
const STRAW := Color(0.86, 0.74, 0.42)
const PAPER := Color(0.96, 0.95, 0.9)


static func generate(path: String, color := HEMP) -> Texture2D:
	var img := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBA8)
	for y in SIZE.y:
		var across := (y + 0.5) / SIZE.y * 2.0 - 1.0  # -1 top .. 1 bottom
		var roundness := sqrt(maxf(1.0 - across * across, 0.0))
		for x in SIZE.x:
			# Position within a strand: the twist runs diagonally (one pixel per row).
			var f := fposmod(x + y, PERIOD) / float(PERIOD)
			var bulge := sin(f * PI)  # 0 at the groove between strands, 1 mid-strand
			var k := 0.45 + 0.4 * bulge * (0.5 + 0.5 * roundness) + 0.15 * roundness
			var c := Color(color.r * k, color.g * k, color.b * k, 1.0)
			# The silhouette dips in at the grooves on the top and bottom rows.
			if (y == 0 or y == SIZE.y - 1) and bulge < 0.5:
				c.a = 0.0
			img.set_pixel(x, y, c)
	return FenceTextureGenerator._save(img, path)


## The texture a hang uses when it has none of its own (made the first time, in the
## editor), or null (scenes, plain cards). A banner with text is remade when its alphabet's
## atlas changes (its file is named by a hash: the typed text isn't in it).
static func default_for(h: RopeHang) -> Texture2D:
	var path := ""
	var key := 0
	var alphabet: Resource = null
	match h.kind:
		RopeHang.Kind.TASSEL: path = DIR + "tassel.res"
		RopeHang.Kind.SHIDE: path = DIR + "shide.res"
		RopeHang.Kind.BANNER:
			var look := [h.cloth_color.to_html(false), h.trim_color.to_html(false), h.crest]
			if not h.text.strip_edges().is_empty():
				alphabet = h.text_alphabet()
				look = [h.cloth_color, h.trim_color, h.ink_color, h.text, alphabet.resource_path if alphabet else ""]
				key = alphabet.content_key() if alphabet else 0
			path = DIR + "banner_%x.res" % hash(look)
		_: return null
	if ResourceLoader.exists(path):
		var existing: Texture2D = load(path)
		if alphabet == null or existing.get_meta(&"glyph_key", 0) == key or not Engine.is_editor_hint():
			return existing
	if not Engine.is_editor_hint():
		return null
	DirAccess.make_dir_recursive_absolute(DIR)
	match h.kind:
		RopeHang.Kind.TASSEL: return FenceTextureGenerator._save(_tassel(), path)
		RopeHang.Kind.SHIDE: return FenceTextureGenerator._save(_shide(), path)
	if alphabet == null:
		return FenceTextureGenerator._save(_banner(h.cloth_color, h.trim_color, h.crest), path)
	# Words: checked both ways, then on the smallest banner they fit on.
	var enc := GlyphText.checked(h.text)
	for e in enc.errors:
		push_warning("Rope banner: " + e)
	var img := text_banner(h.cloth_color, h.trim_color, h.ink_color, alphabet, enc.items)
	var tex := FenceTextureGenerator._save(img, path)
	tex.set_meta(&"glyph_key", key)
	ResourceSaver.save(tex)
	return tex


## A banner with encoded words (GlyphText.encode items) on it: the glyphs the same size on
## the banner (a block a quarter of its width) on the smallest one they fit, smaller when
## the text needs more room.
static func text_banner(cloth: Color, trim: Color, ink: Color, alphabet: Resource, items: Array) -> Image:
	var img: Image
	if alphabet is SyllabaryAlphabet:
		# Hand-drawn glyphs at their own size: longer text, longer banner.
		for size in [Vector2i(64, 128), Vector2i(64, 192), Vector2i(64, 256)]:
			img = _banner(cloth, trim, 0, size)
			var r: Dictionary = alphabet.draw(img, items, _text_area(size), ink)
			if not r.missing.is_empty() and size.y == 128:
				push_warning("Rope banner: the syllabary has nothing drawn for %s yet." % [r.missing])
			if r.fits:
				return img
		push_warning("Rope banner: the text doesn't fit; the rest is left out.")
		return img
	if alphabet is StrokeAlphabet:
		# Shorthand outlines at one size, like a font size: longer text makes a longer banner
		# (64 x 192 / 256: the cloth 1.5 / 2 times as long), not smaller writing. Only past that does it
		# shrink a little, with a nudge to split the text.
		var steps := [[Vector2i(64, 128), 18.0], [Vector2i(64, 192), 18.0], [Vector2i(64, 256), 18.0], [Vector2i(64, 256), 15.0]]
		for t in steps:
			img = _banner(cloth, trim, 0, t[0])
			if alphabet.draw(img, items, _text_area(t[0]), ink, t[1]).fits:
				if t == steps[-1]:
					push_warning("Rope banner: long text, written a little smaller; split it over two banners to keep it full size.")
				return img
		push_warning("Rope banner: the text doesn't fit; the rest is left out.")
		return img
	var tries := [[Vector2i(32, 64), 1], [Vector2i(64, 128), 2], [Vector2i(128, 256), 4], [Vector2i(64, 128), 1],
		[Vector2i(128, 256), 2], [Vector2i(128, 256), 1]]
	for t in tries:
		img = _banner(cloth, trim, 0, t[0])
		var r := GlyphText.draw(img, alphabet, items, _text_area(t[0]), ink, t[1])
		if not r.missing.is_empty():
			push_warning("Rope banner: %s has no mark for %s." % [alphabet.resource_path, r.missing])
		if r.fits:
			return img
	push_warning("Rope banner: the text doesn't fit; the rest is left out.")
	return img


## Where a banner of `size` pixels has room for words (inside its hem and border, above
## the slit at the bottom).
static func _text_area(size: Vector2i) -> Rect2i:
	var k := size.x / 32
	return Rect2i(3 * k, 7 * k, size.x - 6 * k, size.y - 21 * k)


## Shimenawa tassel: straw bound at the top, its strands flaring out to ragged ends.
static func _tassel() -> Image:
	var w := 16
	var h := 32
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in h:
		var f := float(y) / (h - 1)
		var half := lerpf(2.5, 7.5, pow(f, 0.8))
		for x in w:
			var dx := absf(x + 0.5 - w * 0.5)
			if dx > half:
				continue
			# Ragged ends: each strand stops a little sooner or later.
			var strand := x * 7 % 5
			if y > h - 1 - strand:
				continue
			var k := 0.8 + 0.2 * float((x * 3 + 1) % 3) / 2.0 - 0.25 * dx / maxf(half, 1.0)
			var c := STRAW * k
			if y >= 3 and y <= 5:
				c = Color(0.45, 0.32, 0.16)  # the binding
			elif y < 3:
				c = STRAW * 0.7
			c.a = 1.0
			img.set_pixel(x, y, c)
	return img


## Shide: a white paper strip folded into a zigzag (four steps, each joined to the next by a
## fold across), a tab at the top where it's tucked into the rope.
static func _shide() -> Image:
	var w := 16
	var h := 32
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var strip := 8
	var put := func(x: int, y: int, k: float) -> void:
		img.set_pixel(x, y, Color(PAPER.r * k, PAPER.g * k, PAPER.b * k, 1.0))
	for y in h:
		if y < 3:
			for x in range(w / 2 - 2, w / 2 + 2):
				put.call(x, y, 0.9)
			continue
		var step := (y - 3) / 7
		var left := 0 if step % 2 == 0 else w - strip
		for x in range(left, left + strip):
			put.call(x, y, 0.88 if x == left or x == left + strip - 1 else 1.0)
		# The fold across to the next step (its last two rows span both).
		if (y - 3) % 7 >= 5 and y < h - 2:
			for x in w:
				put.call(x, y, 0.82 if (y - 3) % 7 == 5 else 0.95)
	return img


## Cloth banner: a hem along the top (it folds over the rope), a border and a crest.
static func _banner(cloth: Color, trim: Color, crest: int, size := Vector2i(32, 64)) -> Image:
	var w := size.x
	var h := size.y
	var k := w / 32  # pixel scale of the hem, border and crest
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var cx := w * 0.5
	var cy := h * 0.42
	for y in h:
		for x in w:
			var c := cloth
			# A soft fold shade every few pixels down the cloth.
			c = c * (0.94 if (x / 4) % 2 == 0 else 1.0)
			if y < 5 * k or x < 2 * k or x >= w - 2 * k or y >= h - 3 * k:
				c = trim
			var px := (x + 0.5 - cx) / k
			var py := (y + 0.5 - cy) / k
			match crest:
				1:
					var r := Vector2(px, py).length()
					if r < 8.0 and r > 5.0:
						c = trim
				2:
					var m := absf(px) + absf(py)
					if m < 9.0 and m > 6.0:
						c = trim
				3:
					if absf(px) < 7.0 and (absf(py) < 1.0 or absf(py - 4.0) < 1.0 or absf(py + 4.0) < 1.0):
						c = trim
			c.a = 1.0
			# A notch in the bottom middle (noren-style split).
			if y >= h - 12 * k and absf(px) < 1.0:
				c.a = 0.0
			img.set_pixel(x, y, c)
	return img
