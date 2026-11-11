@tool
extends RefCounted
## English text <-> the in-game script, and the script drawn into an image. Tooling only:
## the text never ships, only what's drawn.
##
## Every English sound (ARPAbet: 24 consonants, 15 vowels; Pronunciation) has a mark. A
## syllable is one block, laid out like a steno stroke: its starting consonants along the
## top row, its vowel in the middle, its ending consonants along the bottom row (a fourth
## ending consonant carries over into a block of its own, without a vowel). Words that
## sound the same carry a spelling mark on their first block (right of the vowel: which of
## them it is), so decoding gives back the exact English. Words are separated by a gap;
## . , ? ! - (hyphen) and " - " (dash) are marks of their own; a new line starts a new column. Capital letters aren't
## kept (decoding gives lower case).

const Pronunciation := preload("res://addons/n64_level_tools/glyphs/pronunciation.gd")

const PUNCTUATION := ".,?!-"
## A dash between words (" - "), as opposed to a hyphen inside one ("-"): its own mark.
const DASH := "--"
## Spelling marks drawn in the alphabet (spell1 .. spellN).
const MAX_SPELLINGS := 15
## Consonant groups a syllable can start with (besides any single consonant but NG, ZH).
const ONSETS := ["P L", "P R", "B L", "B R", "K L", "K R", "K W", "G L", "G R", "G W", "F L", "F R", "T R", "T W", "D R",
	"D W", "TH R", "TH W", "SH R", "S P", "S T", "S K", "S M", "S N", "S L", "S W", "S F", "P Y", "B Y", "K Y", "G Y",
	"F Y", "V Y", "M Y", "N Y", "HH Y", "L Y", "HH W", "S P L", "S P R", "S T R", "S K R", "S K W", "S K Y", "S P Y", "S M Y"]
## Consonant slots per row (top / bottom).
const SLOTS := 3


## {items: [{word, blocks: [{onset, vowel, coda}], spell} or {symbol} or {punct} or
## {line: true}], errors: [String]} for `text`. Words in `symbols` (lower case) become a
## {symbol: word} item: written with the alphabet's word symbol instead of spelled out (they
## needn't be in the word list). Other unknown words are reported and left out.
static func encode(text: String, symbols := PackedStringArray()) -> Dictionary:
	var items := []
	var errors := []
	var word := ""
	var padded := text + " "
	for i in padded.length():
		var c := padded[i]
		var letter := (c.to_lower() != c.to_upper()) or c == "'"
		if letter:
			word += c
			continue
		if not word.is_empty():
			_add_word(word, items, errors, symbols)
			word = ""
		if c == "\n":
			items.append({line = true})
		elif c == "-":
			# With a space on either side it's a dash between words (here - free), else a
			# hyphen joining them (well-known).
			var spaced := (i > 0 and padded[i - 1] == " ") or padded[i + 1] == " "
			items.append({punct = DASH if spaced else "-"})
		elif c in PUNCTUATION:
			items.append({punct = c})
		elif c != " " and c != "\t" and c != "\r":
			errors.append("can't write '%s' (only letters and %s)" % [c, PUNCTUATION])
	return {items = items, errors = errors}


static func _add_word(raw: String, items: Array, errors: Array, symbols := PackedStringArray()) -> void:
	var w := raw.to_lower().strip_edges().trim_prefix("'").trim_suffix("'")
	if w in symbols:
		items.append({symbol = w})
		return
	var sounds := Pronunciation.sounds_of(w)
	if sounds.is_empty():
		errors.append("'%s' isn't in the word list or CMUdict (add it to %s)" % [w, Pronunciation.WORDS])
		return
	var spell := Pronunciation.words_for(sounds).find(w)
	if spell < 0:
		spell = 0
	if spell > MAX_SPELLINGS:
		errors.append("'%s' is spelling %d of the words sounding %s (marks go to %d)" % [w, spell, " ".join(sounds), MAX_SPELLINGS])
	items.append({word = w, blocks = syllables(sounds), spell = spell})


## Sounds split into blocks: one per vowel, the consonants between two vowels split so the
## second starts with the longest group a syllable can start with.
static func syllables(sounds: PackedStringArray) -> Array:
	var vowels := []
	for i in sounds.size():
		if Pronunciation.is_vowel(sounds[i]):
			vowels.append(i)
	if vowels.is_empty():
		return _spill([], "", Array(sounds))
	var blocks := []
	var start := 0
	for v in vowels.size():
		var at: int = vowels[v]
		var onset := Array(sounds.slice(start, at))
		var end := sounds.size()
		if v + 1 < vowels.size():
			var between := Array(sounds.slice(at + 1, vowels[v + 1]))
			var take := _onset_length(between)
			end = at + 1 + between.size() - take
		var coda := Array(sounds.slice(at + 1, end))
		blocks.append_array(_spill(onset, sounds[at], coda))
		start = end
	return blocks


## Longest end of `cluster` a syllable can start with.
static func _onset_length(cluster: Array) -> int:
	for n in range(mini(cluster.size(), 3), 0, -1):
		var tail := cluster.slice(cluster.size() - n)
		if n == 1:
			return 0 if tail[0] in ["NG", "ZH"] else 1
		if " ".join(tail) in ONSETS:
			return n
	return 0


## A block, plus vowel-less blocks for consonants past the row's slots.
static func _spill(onset: Array, vowel: String, coda: Array) -> Array:
	var out := []
	while onset.size() > SLOTS:
		out.append({onset = onset.slice(0, SLOTS), vowel = "", coda = []})
		onset = onset.slice(SLOTS)
	out.append({onset = onset, vowel = vowel, coda = coda.slice(0, SLOTS)})
	coda = coda.slice(SLOTS)
	while not coda.is_empty():
		out.append({onset = coda.slice(0, SLOTS), vowel = "", coda = []})
		coda = coda.slice(SLOTS)
	return out


## The English back from encode()'s items (lower case): each word's sounds and spelling
## mark looked up again. Returns {text, errors}.
static func decode(items: Array) -> Dictionary:
	var out := ""
	var errors := []
	var joined := true  # no space before the next word
	for it in items:
		if it.has("line"):
			out += "\n"
			joined = true
		elif it.has("punct") and it.punct == DASH:
			out += " - "
			joined = true
		elif it.has("punct"):
			out += it.punct
			joined = it.punct == "-"
		elif it.has("symbol"):
			out += ("" if joined else " ") + it.symbol
			joined = false
		else:
			var sounds := PackedStringArray()
			for b in it.blocks:
				sounds.append_array(PackedStringArray(b.onset))
				if b.vowel != "":
					sounds.append(b.vowel)
				sounds.append_array(PackedStringArray(b.coda))
			var words := Pronunciation.words_for(sounds)
			var w := words[it.spell] if it.spell < words.size() else "?"
			if w == "?":
				errors.append("no word sounds %s with spelling mark %d" % [" ".join(sounds), it.spell])
			out += ("" if joined else " ") + w
			joined = false
	return {text = out, errors = errors}


## The text as it should come back from decode(): lower case, single spaces, no space
## before . , ? ! or around -.
static func normalised(text: String) -> String:
	var lines := []
	for line in text.to_lower().split("\n"):
		var s := " ".join(line.split(" ", false))
		for p in ".,?!":
			s = s.replace(" " + p, p)
		# A dash (a space on either side) gets one space each side; a hyphen none.
		var out := ""
		for i in s.length():
			if s[i] == "-" and ((i > 0 and s[i - 1] == " ") or (i + 1 < s.length() and s[i + 1] == " ")):
				out = out.strip_edges(false, true) + " - "
			elif s[i] == " " and out.ends_with(" - "):
				continue
			else:
				out += s[i]
		lines.append(out.strip_edges())
	return "\n".join(lines)


## Encodes, decodes and compares: {items, errors (encoding, decoding, mismatch)}.
static func checked(text: String, symbols := PackedStringArray()) -> Dictionary:
	var enc := encode(text, symbols)
	var errors: Array = enc.errors.duplicate()
	if errors.is_empty():
		var dec := decode(enc.items)
		errors.append_array(dec.errors)
		if dec.text != normalised(text):
			errors.append("decodes as \"%s\", not \"%s\"" % [dec.text, normalised(text)])
	return {items = enc.items, errors = errors}


## Where word symbols come from: they're drawn once, in a SyllabaryAlphabet (the Script
## Builder), and every script writes with them: `alphabet` itself when it's a syllabary,
## else the project's (SYMBOL_SOURCE). Null without one.
const SYMBOL_SOURCE := "res://glyphs/syllabary/alphabet.tres"


static func symbol_source(alphabet: Resource) -> SyllabaryAlphabet:
	if alphabet is SyllabaryAlphabet:
		return alphabet
	return load(SYMBOL_SOURCE) as SyllabaryAlphabet if ResourceLoader.exists(SYMBOL_SOURCE) else null


## The symbol for `word` (white ink on clear) as `alphabet` writes it, `side` pixels square
## (whole multiples of its 16 pixels stay crisp), or null when it isn't drawn.
static func symbol_image(alphabet: Resource, word: String, side: int) -> Image:
	var src := symbol_source(alphabet)
	var cell: Image = src.cell(SyllabaryAlphabet.symbol_token(word)) if src else null
	if cell == null:
		return null
	var img := cell.duplicate()
	if side != img.get_width():
		img.resize(side, side, Image.INTERPOLATE_NEAREST if side % img.get_width() == 0 else Image.INTERPOLATE_BILINEAR)
	return img


## The words of `text` with a word symbol drawn (symbol_source(`alphabet`)), lower case, each
## once, in order: the words an inspector lets you write as symbols.
static func symbol_words_in(text: String, alphabet: Resource) -> PackedStringArray:
	var out := PackedStringArray()
	var src := symbol_source(alphabet)
	if src == null:
		return out
	var drawn: PackedStringArray = src.drawn_symbols()
	if drawn.is_empty():
		return out
	var re := RegEx.create_from_string("[A-Za-z']+")
	for m in re.search_all(text):
		var w := m.get_string().to_lower().trim_prefix("'").trim_suffix("'")
		if w in drawn and not w in out:
			out.append(w)
	return out


## One line per word for the inspector: "shop  SH | AA | P", "write  R | AY | T  (spelling 3)".
static func breakdown(text: String, symbols := PackedStringArray()) -> String:
	var enc := checked(text, symbols)
	var lines := []
	for it in enc.items:
		if it.has("symbol"):
			lines.append("%s   (word symbol)" % it.symbol)
		if not it.has("word"):
			continue
		var parts := []
		for b in it.blocks:
			parts.append("%s | %s | %s" % [" ".join(b.onset), b.vowel, " ".join(b.coda)])
		lines.append("%s   %s%s" % [it.word, "  ·  ".join(parts), "   (spelling %d)" % it.spell if it.spell > 0 else ""])
	for e in enc.errors:
		lines.append("! " + e)
	return "\n".join(lines)


# --- Drawing ------------------------------------------------------------------------------

## A block's picture: 3 x 3 cells (top row: starting consonants, centred; middle: the vowel,
## with the spelling mark to its right; bottom: ending consonants). Null when the alphabet
## lacks a mark (`missing` gets its name).
static func block_image(alphabet: GlyphAlphabet, block: Dictionary, spell := 0, missing := []) -> Image:
	var cs := alphabet.cell_size
	var img := Image.create(cs.x * 3, cs.y * 3, false, Image.FORMAT_RGBA8)
	var before := missing.size()
	var place := func(token: String, x: float, row: int) -> void:
		var c := alphabet.cell(token)
		if c == null:
			missing.append(token)
			return
		img.blend_rect(c, Rect2i(Vector2i.ZERO, cs), Vector2i(roundi(x * cs.x), row * cs.y))
	for row in [0, 2]:
		var marks: Array = block.onset if row == 0 else block.coda
		for i in marks.size():
			place.call(marks[i], 1.0 - (marks.size() - 1) * 0.5 + i, row)
	if block.vowel != "":
		place.call(block.vowel, 1.0, 1)
	if spell > 0:
		place.call("spell%d" % spell, 2.0, 1)
	return img if missing.size() == before else null


## The items laid out top to bottom, columns right to left, centred in `area` (marks
## `scale` times their size):
## {glyphs: [{image, at}], fits, missing}. Words aren't split between columns unless one
## is taller than a column.
static func layout(alphabet: GlyphAlphabet, items: Array, area: Rect2i, scale := 1) -> Dictionary:
	var cs := alphabet.cell_size * scale
	var grow := func(img: Image) -> Image:
		if img and scale > 1:
			img = img.duplicate()
			img.resize(img.get_width() * scale, img.get_height() * scale, Image.INTERPOLATE_NEAREST)
		return img
	var block_h := cs.y * 3
	var gap := scale
	var word_gap := maxi(cs.y / 2, 2)
	var missing := []
	# Pieces: [image, height, starts a word]
	var cols := [[]]
	for it in items:
		if it.has("line"):
			cols.append([])
		elif it.has("punct"):
			cols[-1].append({image = grow.call(alphabet.cell(it.punct)), height = cs.y, word = false})
			if alphabet.cell(it.punct) == null:
				missing.append(it.punct)
		elif it.has("symbol"):
			# A word symbol fills a block's square.
			var s := symbol_image(alphabet, it.symbol, mini(cs.x * 3, block_h))
			if s == null:
				missing.append("symbol " + it.symbol)
			cols[-1].append({image = s, height = block_h, word = true})
		else:
			var first := true
			for b in it.blocks:
				cols[-1].append({image = grow.call(block_image(alphabet, b, it.spell if first else 0, missing)), height = block_h,
					word = first})
				first = false
	var wrapped := []
	for col in cols:
		var cur := []
		var h := 0
		var i := 0
		while i < col.size():
			var item: Dictionary = col[i]
			# A word moves to the next column whole when it doesn't fit (and would in one).
			var need: int = item.height
			if item.word:
				var j := i + 1
				while j < col.size() and not col[j].word and col[j].height == block_h:
					need += block_h + gap
					j += 1
			var lead := word_gap if item.word and not cur.is_empty() else 0
			if h + lead + need > area.size.y and not cur.is_empty() and need <= area.size.y:
				wrapped.append(cur)
				cur = []
				h = 0
				lead = 0
			elif h + lead + item.height > area.size.y and not cur.is_empty():
				wrapped.append(cur)
				cur = []
				h = 0
				lead = 0
			cur.append({image = item.image, y = h + lead})
			h += lead + item.height + gap
			i += 1
		wrapped.append(cur)
	var col_w := cs.x * 3
	var count := wrapped.size()
	var fits := count * (col_w + gap) - gap <= area.size.x
	if not fits:
		count = maxi(1, (area.size.x + gap) / (col_w + gap))
	var width := count * (col_w + gap) - gap
	var right := area.position.x + (area.size.x + width) / 2
	var out := []
	for c in count:
		var x := right - (c + 1) * col_w - c * gap
		for piece in wrapped[c]:
			if piece.image:
				var px: int = x + (col_w - piece.image.get_width()) / 2
				out.append({image = piece.image, at = Vector2i(px, area.position.y + piece.y)})
	return {glyphs = out, fits = fits, missing = missing}


## Draws encoded `items` into `img` inside `area` in `ink` (the cells' alpha is coverage).
## `scale`: whole-pixel magnification of the marks.
static func draw(img: Image, alphabet: GlyphAlphabet, items: Array, area: Rect2i, ink: Color, scale := 1) -> Dictionary:
	var l := layout(alphabet, items, area, scale)
	var bounds := Rect2i(Vector2i.ZERO, img.get_size())
	for g in l.glyphs:
		var cell: Image = g.image
		for y in cell.get_height():
			for x in cell.get_width():
				var p: Vector2i = g.at + Vector2i(x, y)
				if cell.get_pixel(x, y).a < 0.5 or not bounds.has_point(p):
					continue
				img.set_pixel(p.x, p.y, Color(ink.r, ink.g, ink.b, img.get_pixel(p.x, p.y).a))
	return l
