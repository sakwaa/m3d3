@tool
class_name SyllabaryAlphabet
extends Resource
## A hand-drawn syllabary for the in-game script, drawn in the editor's Script Builder tab
## (or on a template PNG in another program: Make template, in the inspector): every syllable of a word (a consonant + a vowel, ARPAbet
## sounds from GlyphText) is one glyph, 16 x 16 pixels. Draw:
##   - Consonants: each consonant's base shape (and one for "no consonant").
##   - Vowel marks: what each vowel adds to a base shape (drawn where it goes in the square).
##   - Finals: the form a consonant takes with no vowel after it (st-op, ca-t).
##   - Punctuation.
##   - Spelling marks (optional): "#1" .. "#15", drawn under a word that sounds like others
##     (which of them it is); a number left empty gets the automatic tally.
##   - Syllables (optional): any consonant + vowel drawn whole; an empty square is the base
##     shape and the vowel mark laid over each other.
##   - Word symbols (optional): one glyph for a whole word, like a kanji, for special names
##     (token "@" + the word). A sign writes the word with it, or spelled out, as its
##     inspector says (Signpost: Word symbols).
## Dark pixels are ink (draw in black; the template's light blue guides are ignored, and a
## white background is fine). Words that sound alike carry a spelling mark: a line under
## the word with tally ticks. Tooling only: the text is baked into textures; this resource,
## the template and the typed English never ship.

const Pronunciation := preload("res://addons/n64_level_tools/glyphs/pronunciation.gd")

## Glyph size in pixels, and template pixels per glyph pixel.
const CELL := 16
const SCALE := 4
const NONE := "_"
const CONSONANTS := ["_", "P", "B", "T", "D", "K", "G", "CH", "JH", "F", "V", "TH", "DH", "S", "Z", "SH", "ZH", "HH", "M",
	"N", "NG", "L", "R", "W", "Y"]
const VOWELS := ["IY", "IH", "EY", "EH", "AE", "AA", "AO", "OW", "UH", "UW", "AH", "ER", "AY", "AW", "OY"]
const PUNCT := [".", ",", "?", "!", "-", "--"]
## Spelling marks drawn (GlyphText.MAX_SPELLINGS): tokens "#1" .. "#15".
const SPELL_MARKS := 15
## Friendly names and an example word for the template's labels.
const NAMES := {"_": ["none", "vowel"], "P": ["p", "pin"], "B": ["b", "bin"], "T": ["t", "tin"], "D": ["d", "din"],
	"K": ["k", "kin"], "G": ["g", "go"], "CH": ["ch", "chin"], "JH": ["j", "jam"], "F": ["f", "fan"], "V": ["v", "van"],
	"TH": ["th", "thin"], "DH": ["dh", "this"], "S": ["s", "sip"], "Z": ["z", "zip"], "SH": ["sh", "shop"],
	"ZH": ["zh", "vision"], "HH": ["h", "hat"], "M": ["m", "map"], "N": ["n", "nap"], "NG": ["ng", "sing"],
	"L": ["l", "lip"], "R": ["r", "rip"], "W": ["w", "win"], "Y": ["y", "yes"],
	"IY": ["ee", "see"], "IH": ["i", "sit"], "EY": ["ay", "say"], "EH": ["e", "set"], "AE": ["a", "sat"],
	"AA": ["ah", "hot"], "AO": ["aw", "saw"], "OW": ["oh", "go"], "UH": ["uu", "book"], "UW": ["oo", "too"],
	"AH": ["u", "cup"], "ER": ["er", "bird"], "AY": ["eye", "my"], "AW": ["ow", "now"], "OY": ["oy", "boy"],
	".": [".", "full stop"], ",": [",", "comma"], "?": ["?", "question"], "!": ["!", "exclaim"], "-": ["-", "hyphen"],
	"--": ["—", "dash"]}

## Glyphs drawn in the Script Builder (the editor's Script Builder tab): token -> 16 rows
## of 2 bytes (bit x of row y = ink). They win over the template.
@export_storage var glyphs := {}:
	set(v):
		glyphs = v
		_dirty()
## The words that have a symbol square (drawn or still empty), in the order they were added.
@export_storage var symbol_words := PackedStringArray():
	set(v):
		symbol_words = v
		_dirty()
## A filled-in template (PNG), for drawing in another program; squares drawn in the Script
## Builder win over it. Editing / reimporting it rebuilds whatever uses it.
@export var template: Texture2D:
	set(v):
		if template and template.changed.is_connected(_dirty):
			template.changed.disconnect(_dirty)
		template = v
		if template and Engine.is_editor_hint():
			template.changed.connect(_dirty)
		_dirty()
@export_group("Zones")
## Where things go in the 16 x 16 square (a drawing guide for the Script Builder; it doesn't
## change how text is written): consonant base shapes, vowel marks, finals, and the empty
## margin kept round every glyph so neighbours don't touch. Set them by Alt+dragging on
## the Script Builder's canvas.
@export var zone_base := Rect2i(1, 2, 10, 12):
	set(v):
		zone_base = v
		emit_changed()
@export var zone_mark := Rect2i(12, 2, 3, 12):
	set(v):
		zone_mark = v
		emit_changed()
@export var zone_final := Rect2i(1, 2, 10, 12):
	set(v):
		zone_final = v
		emit_changed()
## Spelling marks: only the rows inside this zone are written, centred under the word.
@export var zone_spell := Rect2i(1, 11, 14, 4):
	set(v):
		zone_spell = v
		_dirty()
@export_range(0, 4, 1) var margin := 1:
	set(v):
		margin = v
		emit_changed()
@export_group("")

## Trim each glyph's empty columns (letters sit close, wide ones take more room); off: every
## glyph is a full 16 pixel square (monospaced).
@export var proportional := true:
	set(v):
		proportional = v
		_dirty()
## Pixels between glyphs, and between words.
@export_range(0, 8, 1) var glyph_gap := 1:
	set(v):
		glyph_gap = v
		_dirty()
@export_range(1, 16, 1) var word_gap := 5:
	set(v):
		word_gap = v
		_dirty()

var _cells := {}  # token -> Image or null, read from the template on demand
var _image: Image


func _dirty() -> void:
	_cells.clear()
	_image = null
	emit_changed()


## The zones a glyph `token` should stay inside (consonant / carrier: base; "~": mark;
## "-": final; a syllable: base and mark; punctuation: the square inside the margin; "#":
## spelling mark).
func zones_for(token: String) -> Array[Rect2i]:
	if token in PUNCT:  # before the prefix checks: "-", "--" and "." are punctuation
		return [Rect2i(margin, margin, CELL - margin * 2, CELL - margin * 2)]
	if token.begins_with(SYMBOL):
		return [Rect2i(0, 0, CELL, CELL)]
	if token.begins_with("#"):
		return [zone_spell]
	if token.begins_with("~"):
		return [zone_mark]
	if token.begins_with("-"):
		return [zone_final]
	if token.contains("."):
		return [zone_base, zone_mark]
	return [zone_base]


func content_key() -> int:
	var img := _template_image()
	return hash([img.get_data() if img else PackedByteArray(), glyphs, proportional, glyph_gap, word_gap, zone_spell])


## Word symbols' tokens: SYMBOL + the word (lower case).
const SYMBOL := "@"


static func symbol_token(word: String) -> String:
	return SYMBOL + word.to_lower()


## The words with a symbol drawn.
func drawn_symbols() -> PackedStringArray:
	var out := PackedStringArray()
	for w in symbol_words:
		if cell(symbol_token(w)) != null:
			out.append(w)
	return out


## The token for spelling mark `n` (1 .. SPELL_MARKS).
static func spell_token(n: int) -> String:
	return "#%d" % n


## [short name, description] for any token (the template's and Script Builder's labels).
static func name_of(token: String) -> Array:
	if token.begins_with("#"):
		return [token.substr(1), "spelling"]
	return NAMES.get(token, [token, ""])


# --- Template layout ---------------------------------------------------------------------

const GUTTER := 14
const LABEL_H := 20
const SECTION_H := 34
const PER_ROW := 13
const MARGIN := 24
const INTRO_H := 120
const HEADER_W := 92
const HEADER_H := 40


## Where everything is on the template: {size, cells: {token: Rect2i (template pixels)},
## labels: [[text, position, font size]], sections: [[title, position]]}. Tokens:
## consonant "K" / "_", vowel mark "~AA", final "-K", syllable "K.AA", punctuation,
## spelling mark "#1".
static var _layout := {}


static func layout() -> Dictionary:
	if _layout.is_empty():
		_layout = _make_layout()
	return _layout


static func _make_layout() -> Dictionary:
	var side := CELL * SCALE
	var cells := {}
	var labels := []
	var sections := []
	var y := MARGIN + INTRO_H
	var small := [
		["Consonants — the base shape of each consonant", CONSONANTS, ""],
		["Vowel marks — what each vowel adds (drawn where it sits in the square)", VOWELS, "~"],
		["Finals — a consonant with no vowel after it (end of a syllable, or before another consonant)", CONSONANTS.slice(1), "-"],
		["Punctuation", PUNCT, ""],
	]
	for sec in small:
		sections.append([sec[0], Vector2(MARGIN, y)])
		y += SECTION_H
		var list: Array = sec[1]
		for i in list.size():
			var col := i % PER_ROW
			var row := i / PER_ROW
			var at := Vector2i(MARGIN + col * (side + GUTTER), y + row * (LABEL_H + side + GUTTER) + LABEL_H)
			cells[sec[2] + list[i]] = Rect2i(at, Vector2i(side, side))
			var n: Array = NAMES[list[i]]
			labels.append(["%s  %s" % [n[0], n[1]], Vector2(at.x, at.y - LABEL_H + 2), 12])
		y += ceili(float(list.size()) / PER_ROW) * (LABEL_H + side + GUTTER) + 10
	# The syllable grid: a row per consonant, a column per vowel.
	sections.append(["Syllables (optional) — consonant + vowel drawn whole; empty squares are built from the base + mark",
		Vector2(MARGIN, y)])
	y += SECTION_H
	var pitch := side + 8
	for v in VOWELS.size():
		var n: Array = NAMES[VOWELS[v]]
		labels.append(["%s\n%s" % [n[0], n[1]], Vector2(MARGIN + HEADER_W + v * pitch, y), 12])
	y += HEADER_H
	for c in CONSONANTS.size():
		var n: Array = NAMES[CONSONANTS[c]] if CONSONANTS[c] != NONE else ["none", "(vowel alone)"]
		labels.append(["%s\n%s" % [n[0], n[1]], Vector2(MARGIN, y + c * pitch + 16), 12])
		for v in VOWELS.size():
			cells[CONSONANTS[c] + "." + VOWELS[v]] = Rect2i(Vector2i(MARGIN + HEADER_W + v * pitch, y + c * pitch), Vector2i(side, side))
	y += CONSONANTS.size() * pitch + MARGIN
	# After the grid, so templates filled in before it keep their squares.
	sections.append(["Spelling marks (optional) — under a word that sounds like others; empty: a tally", Vector2(MARGIN, y)])
	y += SECTION_H
	for i in SPELL_MARKS:
		var at := Vector2i(MARGIN + (i % PER_ROW) * (side + GUTTER), y + (i / PER_ROW) * (LABEL_H + side + GUTTER) + LABEL_H)
		cells[spell_token(i + 1)] = Rect2i(at, Vector2i(side, side))
		labels.append(["mark %d" % (i + 1), Vector2(at.x, at.y - LABEL_H + 2), 12])
	y += ceili(float(SPELL_MARKS) / PER_ROW) * (LABEL_H + side + GUTTER) + MARGIN
	var w := maxi(MARGIN * 2 + HEADER_W + VOWELS.size() * pitch, MARGIN * 2 + PER_ROW * (side + GUTTER))
	return {size = Vector2i(w, y), cells = cells, labels = labels, sections = sections}


# --- Reading the template ----------------------------------------------------------------

func _template_image() -> Image:
	if _image == null and template:
		_image = template.get_image()
		if _image:
			_image = _image.duplicate()
			if _image.is_compressed():
				_image.decompress()
			_image.convert(Image.FORMAT_RGBA8)
	return _image


## A square's glyph (white ink on clear, CELL x CELL), or null when it's empty: drawn in the
## Script Builder, else on the template.
func cell(token: String) -> Image:
	if _cells.has(token):
		return _cells[token]
	var out: Image = null
	if glyphs.has(token):
		out = bits_to_image(glyphs[token])
		_cells[token] = out
		return out
	out = template_cell(token)
	_cells[token] = out
	return out


## The template's square for `token` (ignoring the Script Builder's), or null.
func template_cell(token: String) -> Image:
	var out: Image = null
	var img := _template_image()
	var rect: Rect2i = layout().cells.get(token, Rect2i())
	if img and rect.has_area():
		var g := Image.create(CELL, CELL, false, Image.FORMAT_RGBA8)
		var any := false
		for y in CELL:
			for x in CELL:
				var p := rect.position + Vector2i(x * SCALE + SCALE / 2, y * SCALE + SCALE / 2)
				if p.x >= img.get_width() or p.y >= img.get_height():
					continue
				var c := img.get_pixel(p.x, p.y)
				if c.a > 0.5 and c.get_luminance() < 0.5:  # dark = ink (guides are light)
					g.set_pixel(x, y, Color.WHITE)
					any = true
		if any:
			out = g
	return out


## The Script Builder's bits for `token` (empty: not drawn there).
func glyph_bits(token: String) -> PackedByteArray:
	return glyphs.get(token, PackedByteArray())


## Sets (or, with no ink, clears) the Script Builder's glyph for `token`.
func set_glyph_bits(token: String, bits: PackedByteArray) -> void:
	var g := glyphs.duplicate()
	if bits.size() != CELL * CELL / 8 or bits.count(0) == bits.size():
		g.erase(token)
	else:
		g[token] = bits
	glyphs = g


static func bits_to_image(bits: PackedByteArray) -> Image:
	if bits.count(0) == bits.size():
		return null
	var img := Image.create(CELL, CELL, false, Image.FORMAT_RGBA8)
	for y in CELL:
		for x in CELL:
			if bits[y * 2 + x / 8] & (1 << (x % 8)):
				img.set_pixel(x, y, Color.WHITE)
	return img


static func image_to_bits(img: Image) -> PackedByteArray:
	var bits := PackedByteArray()
	bits.resize(CELL * CELL / 8)
	if img:
		for y in CELL:
			for x in CELL:
				if img.get_pixel(x, y).a > 0.5:
					bits[y * 2 + x / 8] |= 1 << (x % 8)
	return bits


## The glyph for consonant `c` (NONE: a vowel alone) + vowel `v`: drawn whole, or the base
## shape with the vowel mark over it. Null when there's nothing to draw it from.
func syllable(c: String, v: String) -> Image:
	var whole := cell(c + "." + v)
	if whole:
		return whole
	var base := cell(c)
	var mark := cell("~" + v)
	if base == null and mark == null:
		return null
	var out := Image.create(CELL, CELL, false, Image.FORMAT_RGBA8)
	for part in [base, mark]:
		if part:
			out.blend_rect(part, Rect2i(0, 0, CELL, CELL), Vector2i.ZERO)
	return out


## A consonant with no vowel after it: its final form, else its base shape.
func final(c: String) -> Image:
	var f := cell("-" + c)
	return f if f else cell(c)


# --- Writing -----------------------------------------------------------------------------

## A word's glyphs in order: consonants before the last one starting a syllable, and those
## ending it, as finals; the last starting consonant + the vowel as one syllable glyph.
## `missing` collects what the template doesn't have yet.
func word_glyphs(it: Dictionary, missing: Array) -> Array[Image]:
	var out: Array[Image] = []
	var add := func(img: Image, what: String) -> void:
		if img:
			out.append(_trimmed(img))
		elif not what in missing:
			missing.append(what)
	for b in it.blocks:
		var onset: Array = b.onset
		if b.vowel == "":
			for c in onset + b.coda:
				add.call(final(c), "final " + c)
			continue
		for i in onset.size() - 1:
			add.call(final(onset[i]), "final " + onset[i])
		var c: String = onset[-1] if not onset.is_empty() else NONE
		add.call(syllable(c, b.vowel), c + " + " + b.vowel)
		for c2 in b.coda:
			add.call(final(c2), "final " + c2)
	return out


func _trimmed(img: Image) -> Image:
	if not proportional:
		return img
	var used := img.get_used_rect()
	if not used.has_area():
		return img
	return img.get_region(Rect2i(used.position.x, 0, used.size.x, CELL))


## One word as an image: its glyphs in a row (wrapping onto more rows past `max_w`), its
## spelling mark under it.
func word_image(it: Dictionary, max_w: int, missing: Array) -> Image:
	var glyphs := word_glyphs(it, missing)
	var rows := [[]]
	var w := 0
	for g in glyphs:
		if not rows[-1].is_empty() and w + glyph_gap + g.get_width() > max_w:
			rows.append([])
			w = 0
		w += (glyph_gap if not rows[-1].is_empty() else 0) + g.get_width()
		rows[-1].append(g)
	var width := 1
	for row in rows:
		var rw := -glyph_gap
		for g in row:
			rw += g.get_width() + glyph_gap
		width = maxi(width, rw)
	var z := {line = 1, bold = 2, dot = 3, heavy_dot = 4}
	var mark := spell_image(it.spell)
	var mark_h: int = 0 if it.spell == 0 else (glyph_gap + mark.get_height() if mark else StrokeAlphabet._tally_height(z))
	if it.spell > 0:
		width = maxi(width, mark.get_width() if mark else StrokeAlphabet._tally_width(it.spell, z) + 2)
	var img := Image.create(width, rows.size() * (CELL + glyph_gap) - glyph_gap + mark_h, false, Image.FORMAT_RGBA8)
	for r in rows.size():
		var x := 0
		for g: Image in rows[r]:
			img.blend_rect(g, Rect2i(Vector2i.ZERO, g.get_size()), Vector2i(x, r * (CELL + glyph_gap)))
			x += g.get_width() + glyph_gap
	img.set_meta(&"last_row", (rows.size() - 1) * (CELL + glyph_gap))
	if mark:
		img.blend_rect(mark, Rect2i(Vector2i.ZERO, mark.get_size()), Vector2i((width - mark.get_width()) / 2, img.get_height() - mark.get_height()))
	elif it.spell > 0:
		StrokeAlphabet._tally(img, Rect2i(1, img.get_height() - mark_h, width - 2, mark_h), it.spell, z)
	return img


## Punctuation `p` after `word`, level with its last row of glyphs (not its spelling mark).
func _after(word: Image, p: Image) -> Image:
	var y: int = word.get_meta(&"last_row", maxi(0, word.get_height() - p.get_height()))
	var out := Image.create(word.get_width() + glyph_gap + p.get_width(), maxi(word.get_height(), y + p.get_height()), false,
		Image.FORMAT_RGBA8)
	out.blit_rect(word, Rect2i(Vector2i.ZERO, word.get_size()), Vector2i.ZERO)
	out.blit_rect(p, Rect2i(Vector2i.ZERO, p.get_size()), Vector2i(word.get_width() + glyph_gap, y))
	out.set_meta(&"last_row", y)
	return out


## Spelling mark `n` as drawn: the rows of zone_spell, empty columns trimmed. Null when
## it isn't drawn (the word gets a tally).
func spell_image(n: int) -> Image:
	var g := cell(spell_token(n)) if n > 0 else null
	if g == null:
		return null
	var band := Rect2i(0, zone_spell.position.y, CELL, zone_spell.size.y).intersection(Rect2i(0, 0, CELL, CELL))
	var img := g.get_region(band)
	var used := img.get_used_rect()
	if not used.has_area():
		return null
	return img.get_region(Rect2i(used.position.x, 0, used.size.x, band.size.y))


## Encoded `items` (GlyphText.encode) drawn into `img` inside `area`: words left to right in
## rows, wrapping, centred both ways. `_px` is unused (the glyphs have their own size).
## Returns {fits, missing}.
func draw(img: Image, items: Array, area: Rect2i, ink: Color, _px := 0.0) -> Dictionary:
	var missing := []
	var words := []  # images; null = new line
	for it in items:
		if it.has("line"):
			words.append(null)
		elif it.has("symbol"):
			# A word symbol keeps its whole square (they read as a set, like kanji).
			var s := cell(symbol_token(it.symbol))
			if s == null:
				missing.append("symbol " + it.symbol)
			else:
				words.append(s)
		elif it.has("punct"):
			var p := cell(it.punct)
			if p == null:
				missing.append(it.punct)
				continue
			p = _trimmed(p)
			var prev = words[-1] if not words.is_empty() else null
			if it.punct != "--" and prev != null and prev.get_width() + glyph_gap + p.get_width() <= area.size.x:
				words[-1] = _after(prev, p)
			else:
				words.append(p)
		else:
			words.append(word_image(it, area.size.x, missing))
	var rows := [[]]
	var w := 0
	for word in words:
		if word == null:
			rows.append([])
			w = 0
			continue
		if not rows[-1].is_empty() and w + word_gap + word.get_width() > area.size.x:
			rows.append([])
			w = 0
		w += (word_gap if not rows[-1].is_empty() else 0) + word.get_width()
		rows[-1].append(word)
	var heights := []
	var total := 0
	for row in rows:
		var h := 0
		for word: Image in row:
			h = maxi(h, word.get_height())
		heights.append(h)
		total += h + glyph_gap * 2
	total -= glyph_gap * 2
	var fits := total <= area.size.y
	var y: int = area.position.y + maxi(0, (area.size.y - total) / 2)
	for r in rows.size():
		var rw := -word_gap
		for word: Image in rows[r]:
			rw += word.get_width() + word_gap
		var x: int = area.position.x + (area.size.x - rw) / 2
		for word: Image in rows[r]:
			if word.get_width() > area.size.x:
				fits = false
			for py in word.get_height():
				for pxx in word.get_width():
					var at := Vector2i(x + pxx, y + py)
					if word.get_pixel(pxx, py).a > 0.5 and Rect2i(Vector2i.ZERO, img.get_size()).has_point(at):
						img.set_pixel(at.x, at.y, Color(ink.r, ink.g, ink.b, img.get_pixel(at.x, at.y).a))
			x += word.get_width() + word_gap
		y += heights[r] + glyph_gap * 2
	return {fits = fits, missing = missing}
