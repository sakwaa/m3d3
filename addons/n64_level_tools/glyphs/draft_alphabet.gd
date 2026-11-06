@tool
extends RefCounted
## The first draft of the script: one 8 x 8 pixel mark per English sound (paint over the
## atlas PNG to refine it; glyph_text.gd lays the marks out in syllable blocks).
##
## Consonants: a shape in the cell's lower left (5 x 6). Voiced consonants are their
## voiceless partner plus a dot top-right: b = p, d = t, g = k, v = f, dh = th, z = s,
## zh = sh, j = ch.
## Vowels: a bar across the middle with strokes that say where in the mouth it is: left =
## front (ee, i, e, a, ay), right = back (oo, u, aw, ah, oh), middle = central; up = high,
## down = low; long strokes for the tense / long ones. ay, ow and oy (the glides) combine
## a middle stroke with a side one.
## Spelling marks: dots counting in binary (1 - 15), right of a word's first vowel.

const CELL := 8
const COLUMNS := 8

## Voiceless / plain consonant shapes (rows 2 - 7 of the cell, columns 0 - 4).
const SHAPES := {
	"P": ["#####", "....#", "....#", "....#", "....#", "...##"],
	"T": ["#####", "..#..", "..#..", "..#..", "..#..", ".###."],
	"K": ["...#.", "..#..", ".#...", ".#...", "..#..", "...#."],
	"F": ["#####", "#....", "###..", "#....", "#....", "#...."],
	"TH": [".###.", "#...#", "#####", "#...#", "#...#", ".###."],
	"S": ["..#..", "..#..", ".#.#.", ".#.#.", "#...#", "#...#"],
	"SH": ["..#..", ".#.#.", "#...#", ".....", ".....", "#####"],
	"CH": ["..#..", ".#.#.", "#.#.#", "..#..", "..#..", "..#.."],
	"HH": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#"],
	"M": ["#####", "#...#", "#...#", "#...#", "#...#", "#####"],
	"N": ["#....", "#....", "#....", "#....", "#....", "#####"],
	"NG": ["#####", "#....", "#....", "#....", "#....", "#####"],
	"L": ["..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
	"R": ["#####", "#....", "#####", "....#", "....#", "#####"],
	"W": ["#...#", "#...#", "#.#.#", "#.#.#", ".#.#.", ".#.#."],
	"Y": ["#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
}
const VOICED := {"B": "P", "D": "T", "G": "K", "V": "F", "DH": "TH", "Z": "S", "ZH": "SH", "JH": "CH"}
## Vowels: strokes off the middle bar, [side (0 left, 1 middle, 2 right), up (true) /
## down, long].
const VOWELS := {
	"AH": [],
	"ER": [[1, true, true]],
	"IY": [[0, true, true]], "IH": [[0, true, false]], "EH": [[0, false, false]], "AE": [[0, false, true]],
	"EY": [[0, true, true], [0, false, true]],
	"UW": [[2, true, true]], "UH": [[2, true, false]], "AO": [[2, false, false]], "AA": [[2, false, true]],
	"OW": [[2, true, true], [2, false, true]],
	"AY": [[1, false, true], [0, true, false]],
	"AW": [[1, false, true], [2, true, false]],
	"OY": [[2, false, false], [0, true, false]],
}
const PUNCT := {
	".": ["........", "........", "........", "...##...", "..#..#..", "..#..#..", "...##...", "........"],
	",": ["........", "........", "........", "...##...", "...##...", "....#...", "...#....", "........"],
	"?": ["..###...", ".#...#..", ".....#..", "....#...", "...#....", "........", "...#....", "........"],
	"!": ["...#....", "...#....", "...#....", "...#....", "........", "...#....", "........", "........"],
	"-": ["........", "........", "........", "........", "..####..", "........", "........", "........"],
	"--": ["........", "........", "........", "........", "########", "........", "........", "........"],
}


static func tokens() -> PackedStringArray:
	var out := PackedStringArray()
	for k in SHAPES:
		out.append(k)
	for k in VOICED:
		out.append(k)
	for k in VOWELS:
		out.append(k)
	for n in range(1, 16):
		out.append("spell%d" % n)
	for k in PUNCT:
		out.append(k)
	return out


## Pixel rows (8 strings of 8) of one mark.
static func pixels(token: String) -> PackedStringArray:
	var rows := []  # an Array, so the lambda below changes it in place
	for y in CELL:
		rows.append("........")
	var put := func(x: int, y: int) -> void:
		rows[y] = rows[y].substr(0, x) + "#" + rows[y].substr(x + 1)
	var base: String = VOICED.get(token, token)
	if SHAPES.has(base):
		var shape: Array = SHAPES[base]
		for y in shape.size():
			for x in shape[y].length():
				if shape[y][x] == "#":
					put.call(x, y + 2)
		if VOICED.has(token):
			for p in [Vector2i(5, 0), Vector2i(6, 0), Vector2i(5, 1), Vector2i(6, 1)]:
				put.call(p.x, p.y)
	elif VOWELS.has(token):
		for x in CELL:
			put.call(x, 4)
		for s: Array in VOWELS[token]:
			var cols: Array = [[0], [3, 4], [7]][s[0]]
			var ys: Array = ([1, 2, 3] if s[2] else [3]) if s[1] else ([5, 6, 7] if s[2] else [5])
			for x in cols:
				for y in ys:
					put.call(x, y)
	elif token.begins_with("spell"):
		var n := token.substr(5).to_int()
		var spots := [Vector2i(1, 1), Vector2i(5, 1), Vector2i(1, 5), Vector2i(5, 5)]
		for bit in 4:
			if n & (1 << bit):
				for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
					put.call(spots[bit].x + d.x, spots[bit].y + d.y)
	elif PUNCT.has(token):
		rows = PUNCT[token].duplicate()
	return PackedStringArray(rows)


## The atlas image: white ink (alpha) on transparent, tokens() in order.
static func atlas_image() -> Image:
	var list := tokens()
	var rows := ceili(float(list.size()) / COLUMNS)
	var img := Image.create(COLUMNS * CELL, rows * CELL, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	for i in list.size():
		var origin := Vector2i(i % COLUMNS, i / COLUMNS) * CELL
		var px := pixels(list[i])
		for y in CELL:
			for x in CELL:
				if px[y][x] == "#":
					img.set_pixel(origin.x + x, origin.y + y, Color.WHITE)
	return img


## Writes `dir`/atlas.png (unless one is there and not `overwrite_png`: it may have been
## refined by hand) and `dir`/alphabet.tres. Returns the alphabet.
static func make(dir: String, overwrite_png := false) -> GlyphAlphabet:
	DirAccess.make_dir_recursive_absolute(dir)
	var png := dir.path_join("atlas.png")
	if overwrite_png or not FileAccess.file_exists(png):
		atlas_image().save_png(png)
	var a := GlyphAlphabet.new()
	a.cell_size = Vector2i(CELL, CELL)
	a.tokens = tokens()
	if ResourceLoader.exists(png):
		a.atlas = load(png)
	ResourceSaver.save(a, dir.path_join("alphabet.tres"))
	return a
