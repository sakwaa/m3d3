@tool
extends RefCounted
## The writing on a Signpost's face: its text in the in-game script, in rows read left to
## right, painted into the board's wood as one opaque texture (like an N64 sign: the
## console's 3-point filter softens the ink into the wood instead of a cut-out's hard edge). Saved under
## textures/signs/ by a hash (the typed text isn't in the file), and remade when the
## alphabet's glyphs change. Editor only: games just load the saved texture.

const RopeTexture := preload("res://addons/n64_level_tools/textures/rope_texture_generator.gd")
const GlyphText := preload("res://addons/n64_level_tools/glyphs/glyph_text.gd")
const FenceTextureGenerator := preload("res://addons/n64_level_tools/textures/fence_texture_generator.gd")

const DIR := "res://textures/signs/"
## Texture pixels per metre of board, tried in order: the first the text fits at wins, so
## short text is written big and long text smaller.
const DENSITIES := [48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256]
## Bare board left on each side of the writing, as a fraction of the board's width
## (left / right) and height (top / bottom).
const PADDING := 0.1
## Part of every face's file name: bump it when the layout changes so faces are rewritten.
const VERSION := 12
## Dark ink a little darker than asked: filtered into the wood it reads lighter, most of
## all from afar (smaller mips). Light ink (on dark cloth) is left as it is.
const INK_DARKEN := 0.3
## Boards this many times taller than wide are written vertically (_draw).
const VERTICAL_ASPECT := 1.5


## The face texture for `text` on a board `board_size` metres across, written over `board`
## (repeating every metre, tinted `board_color`), or null (no text, no alphabet).
## `alphabet_path` "" = the banners' default.
## `lettering` (Signpost.Lettering): PRINT the glyphs as drawn, BRUSH / HAND restyled (_stylise).
## `symbols`: words written with their word symbol (SyllabaryAlphabet) instead of spelled.
static func face_for(text: String, alphabet_path: String, board_size: Vector2, ink: Color, board: Texture2D,
		board_color: Color, lettering := 0, symbols := PackedStringArray()) -> Texture2D:
	var plain := _plain(text)
	if plain.is_empty():
		return null
	var path_in := alphabet_path if alphabet_path != "" else RopeHang.DEFAULT_ALPHABET
	var alphabet: Resource = load(path_in) if ResourceLoader.exists(path_in) else null
	if alphabet == null:
		return null
	var look := [plain, path_in, board_size, ink, board.resource_path if board else "", board_color, VERSION]
	if lettering != PRINT:
		look.append(lettering)
	if not symbols.is_empty():
		look.append(symbols)
	var path := DIR + "face_%x.res" % hash(look)
	var key: int = alphabet.content_key()
	if ResourceLoader.exists(path):
		var existing: Texture2D = load(path)
		if existing.get_meta(&"glyph_key", 0) == key:
			return existing
	DirAccess.make_dir_recursive_absolute(DIR)
	var enc := GlyphText.checked(plain, symbols)
	for e in enc.errors:
		push_warning("Sign: " + e)
	var writing := _draw(alphabet, enc.items, board_size, ink.darkened(INK_DARKEN) if ink.get_luminance() < 0.5 else ink)
	if lettering != PRINT:
		writing = _stylise(writing, lettering, hash(plain))
	var img := _on_board(writing, board, board_color, board_size)
	var tex := FenceTextureGenerator._save(img, path)
	tex.set_meta(&"glyph_key", key)
	ResourceSaver.save(tex)
	return tex


## The words of `text` that `alphabet_path`'s alphabet ("" = the default) has a word symbol
## drawn for, lower case, each once (Signpost's inspector offers these).
static func symbol_words_in(text: String, alphabet_path: String) -> PackedStringArray:
	var path_in := alphabet_path if alphabet_path != "" else RopeHang.DEFAULT_ALPHABET
	return GlyphText.symbol_words_in(_plain(text), load(path_in) if ResourceLoader.exists(path_in) else null)


## Lettering styles (Signpost.Lettering).
const PRINT := 0
const BRUSH := 1
const HAND := 2
## _stylise works at WORK x the writing's resolution and hands back OUT x it.
const WORK := 4
const OUT := 2
## Nibs, in glyph pixels: BRUSH an ellipse at NIB_ANGLE (radians from +X; half length, half
## width), HAND a round pen (radius). Stamped at each glyph pixel's centre, a stroke stays
## about a glyph pixel wide, so the one-pixel gaps between strokes survive.
const NIB_ANGLE := -0.65
const NIB := Vector2(0.95, 0.38)
const PEN := 0.56
## How far stamps wander (glyph pixels): a little for the brush, more for the hand.
const WANDER := {1: 0.12, 2: 0.22}


## `img` (ink on nothing, one alpha per glyph pixel) redrawn OUT x larger with soft edges, by
## stamping a nib at every inked glyph pixel's centre, nudged by a slow noise:
##  - BRUSH: the angled nib (strokes along it thin, across it thick), sized by a slow
##    "pressure" noise, its edges roughened and a few dry streaks across;
##  - HAND: the round pen, wandering more, a smooth line.
## `seed` varies the noise, so no two signs write alike.
static func _stylise(img: Image, style: int, seed: int) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var ww := w * WORK
	var hh := h * WORK
	var slow := FastNoiseLite.new()
	slow.seed = seed
	slow.frequency = 0.09
	var fine := FastNoiseLite.new()
	fine.seed = seed + 1
	fine.frequency = 1.0 / (WORK * 1.1)
	# The nib as offsets (work pixels) with their size measure (<= 1 inside at full pressure).
	var dir := Vector2.from_angle(NIB_ANGLE)
	var reach := (NIB.x if style == BRUSH else PEN) * WORK * 1.3
	var r := ceili(reach)
	var nib := []
	for oy in range(-r, r + 1):
		for ox in range(-r, r + 1):
			var o := Vector2(ox, oy)
			var e := (pow(o.dot(dir) / (NIB.x * WORK), 2.0) + pow(o.dot(dir.orthogonal()) / (NIB.y * WORK), 2.0)) if style == BRUSH \
				else o.length_squared() / pow(PEN * WORK, 2.0)
			if e <= 1.7:
				nib.append([o, e])
	var a := PackedFloat32Array()
	a.resize(ww * hh)
	var ink := Color.BLACK
	var wander: float = WANDER.get(style, 0.0) * WORK
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a <= 0.5:
				continue
			ink = c
			var centre := Vector2((x + 0.5) * WORK, (y + 0.5) * WORK)
			centre += Vector2(slow.get_noise_2d(x, y), slow.get_noise_2d(x + 311.0, y + 97.0)) * wander * 2.0
			var s := 1.0
			if style == BRUSH:
				s = 0.85 + 0.35 * (slow.get_noise_2d(x * 0.5 + 40.0, y * 0.5) * 0.5 + 0.5)
			var s2 := s * s
			for n in nib:
				if n[1] > s2:
					continue
				var p := Vector2i((centre + n[0]).round())
				if p.x >= 0 and p.y >= 0 and p.x < ww and p.y < hh:
					a[p.y * ww + p.x] = 1.0
	a = _blur(a, ww, hh, 1)
	var streak := FastNoiseLite.new()
	streak.seed = seed + 2
	streak.frequency = 1.0 / (WORK * 0.8)
	for i in a.size():
		var x := i % ww
		var y := i / ww
		if style == BRUSH:
			# Ragged edges, and dry streaks across the strokes (noise stretched along the nib).
			var t := 0.45 + fine.get_noise_2d(x, y) * 0.12
			var q := Vector2(x, y).rotated(-NIB_ANGLE)
			var dry := smoothstep(0.5, 0.8, streak.get_noise_2d(q.x * 0.15, q.y))
			a[i] = smoothstep(t - 0.1, t + 0.1, a[i]) * (1.0 - 0.35 * dry)
		else:
			a[i] = smoothstep(0.3, 0.6, a[i])
	# Down to OUT x: average each block (soft edges for the N64 filter to blend).
	var f := WORK / OUT
	var out := Image.create(w * OUT, h * OUT, false, Image.FORMAT_RGBA8)
	for y in h * OUT:
		for x in w * OUT:
			var sum := 0.0
			for dy in f:
				for dx in f:
					sum += a[(y * f + dy) * ww + x * f + dx]
			out.set_pixel(x, y, Color(ink.r, ink.g, ink.b, sum / (f * f)))
	return out


## `v` (w x h) box-blurred `r` pixels each way (rows, then columns).
static func _blur(v: PackedFloat32Array, w: int, h: int, r: int) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(v.size())
	var n := float(r * 2 + 1)
	for y in h:
		var sum := 0.0
		for x in range(-r, r + 1):
			sum += v[y * w + clampi(x, 0, w - 1)]
		for x in w:
			tmp[y * w + x] = sum / n
			sum += v[y * w + clampi(x + r + 1, 0, w - 1)] - v[y * w + clampi(x - r, 0, w - 1)]
	var out := PackedFloat32Array()
	out.resize(v.size())
	for x in w:
		var sum := 0.0
		for y in range(-r, r + 1):
			sum += tmp[clampi(y, 0, h - 1) * w + x]
		for y in h:
			out[y * w + x] = sum / n
			sum += tmp[clampi(y + r + 1, 0, h - 1) * w + x] - tmp[clampi(y - r, 0, h - 1) * w + x]
	return out


## Ink on a transparent board-shaped image, at the coarsest density the words fit.
static func _draw(alphabet: Resource, items: Array, board_size: Vector2, ink: Color) -> Image:
	var img: Image
	for density: int in DENSITIES:
		var size := Vector2i(maxi(8, roundi(board_size.x * density)), maxi(8, roundi(board_size.y * density)))
		# The alphabets recolour pixels they draw on and keep the alpha, so draw black on
		# white and turn it into ink on nothing afterwards.
		img = Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		var pad := Vector2i(roundi(size.x * PADDING), roundi(size.y * PADDING))
		var area := Rect2i(pad, size - pad * 2)
		var r: Dictionary
		if board_size.y > board_size.x * VERTICAL_ASPECT and alphabet is SyllabaryAlphabet:
			r = _draw_column(alphabet, img, items, area, Color.BLACK)
		elif alphabet is SyllabaryAlphabet or alphabet is StrokeAlphabet:
			r = alphabet.draw(img, items, area, Color.BLACK)
		else:
			r = GlyphText.draw(img, alphabet, items, area, Color.BLACK, 1)
		if density == DENSITIES[0] and not r.missing.is_empty():
			push_warning("Sign: the alphabet has nothing drawn for %s yet." % [r.missing])
		if r.fits:
			break
		if density == DENSITIES[-1]:
			push_warning("Sign: the text doesn't fit on the board; the rest is left out.")
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(ink.r, ink.g, ink.b, 1.0) if c.r < 0.5 else Color(0, 0, 0, 0))
	return img


## A tall face's writing: top to bottom, one glyph per row in a centred column, a wider gap
## between words (and lines). {fits, missing} as SyllabaryAlphabet.draw.
static func _draw_column(alphabet: SyllabaryAlphabet, img: Image, items: Array, area: Rect2i, ink: Color) -> Dictionary:
	var missing := []
	var glyphs := []  # images; null = a word break
	for it in items:
		if it.has("line"):
			glyphs.append(null)
		elif it.has("punct"):
			continue  # punctuation stays off vertical banners
		elif it.has("symbol"):
			if not glyphs.is_empty():
				glyphs.append(null)
			var s := alphabet.cell(SyllabaryAlphabet.symbol_token(it.symbol))
			if s == null:
				missing.append("symbol " + it.symbol)
			else:
				glyphs.append(s)
		else:
			if not glyphs.is_empty():
				glyphs.append(null)
			glyphs.append_array(alphabet.word_glyphs(it, missing))
	var gap := alphabet.glyph_gap * 2
	var total := -gap
	for g in glyphs:
		total += (g.get_height() + gap) if g else alphabet.word_gap
	var fits := total <= area.size.y
	var y: int = area.position.y + maxi(0, (area.size.y - total) / 2)
	for g in glyphs:
		if g == null:
			y += alphabet.word_gap
			continue
		if g.get_width() > area.size.x:
			fits = false
		var x: int = area.position.x + (area.size.x - g.get_width()) / 2
		for py in g.get_height():
			for px in g.get_width():
				var at := Vector2i(x + px, y + py)
				if g.get_pixel(px, py).a > 0.5 and Rect2i(Vector2i.ZERO, img.get_size()).has_point(at):
					img.set_pixel(at.x, at.y, Color(ink.r, ink.g, ink.b, img.get_pixel(at.x, at.y).a))
		y += g.get_height() + gap
	return {fits = fits, missing = missing}


## `ink` (ink on nothing) painted over the board's wood at the same size: the wood tiled
## over the board's metres at its own resolution, then resampled smoothly to the ink's.
static func _on_board(ink: Image, board: Texture2D, board_color: Color, board_size: Vector2) -> Image:
	var size := ink.get_size()
	var wood: Image = board.get_image() if board else null
	var out := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	if wood == null:
		out.fill(board_color)
	else:
		wood = wood.duplicate()
		if wood.is_compressed():
			wood.decompress()
		wood.clear_mipmaps()
		wood.convert(Image.FORMAT_RGBA8)
		var ws := wood.get_size()
		var tiled := Image.create(maxi(1, roundi(ws.x * board_size.x)), maxi(1, roundi(ws.y * board_size.y)), false, Image.FORMAT_RGBA8)
		for y in tiled.get_height():
			for x in tiled.get_width():
				tiled.set_pixel(x, y, wood.get_pixel(x % ws.x, y % ws.y))
		tiled.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
		for y in size.y:
			for x in size.x:
				out.set_pixel(x, y, Color(tiled.get_pixel(x, y) * board_color, 1.0))
	for y in size.y:
		for x in size.x:
			var c := ink.get_pixel(x, y)
			if c.a > 0.0:
				out.set_pixel(x, y, Color(out.get_pixel(x, y).lerp(c, c.a), 1.0))
	return out


## The words only: dialogue markup ([red]…[/red], [p], {player}) dropped, pages joined.
static func _plain(text: String) -> String:
	var re := RegEx.create_from_string("\\[[^\\]]*\\]|\\{[^}]*\\}")
	var out := re.sub(text, "", true)
	var lines := PackedStringArray()
	for line in out.split("\n"):
		if line.strip_edges() != "":
			lines.append(line.strip_edges())
	return "\n".join(lines)
