@tool
extends RefCounted
## Draws a blank SyllabaryAlphabet template: section titles and labels on paper, and for
## every glyph a clear square (CELL x CELL glyph pixels, SCALE template pixels each) with a
## faint light-blue pixel grid and centre lines to draw on. Labels need text rendering, so
## this renders a SubViewport under `host` (any node in a tree that draws).

const INTRO := "Syllabary template. Draw in black (any dark colour) inside the squares: one glyph per square, 16 x 16 pixels (each pixel of the grid = 4 x 4 here).\nThe light blue guides and a white background are ignored. Save as PNG; the alphabet using it rebuilds its banners.\nConsonants + vowel marks are enough: every syllable is built from them unless you draw it whole in the grid at the bottom."
const PAPER := Color(0.95, 0.94, 0.9)
const INK := Color(0.2, 0.18, 0.16)
const GUIDE := Color(0.3, 0.75, 1.0, 0.18)
const GUIDE_MID := Color(0.3, 0.75, 1.0, 0.4)
const FRAME := Color(0.55, 0.53, 0.5)


## Saves the template PNG at `path` (res://). Returns OK or an error.
static func make(path: String, host: Node) -> Error:
	var L := SyllabaryAlphabet.layout()
	var size: Vector2i = L.size
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	host.add_child(vp)
	var add_label := func(text: String, at: Vector2, font_size: int) -> void:
		var l := Label.new()
		l.text = text
		l.position = at
		l.add_theme_font_size_override(&"font_size", font_size)
		l.add_theme_color_override(&"font_color", INK)
		vp.add_child(l)
	add_label.call(INTRO, Vector2(SyllabaryAlphabet.MARGIN, SyllabaryAlphabet.MARGIN), 15)
	for sec in L.sections:
		add_label.call(sec[0], sec[1], 18)
	for lab in L.labels:
		add_label.call(lab[0], lab[1], lab[2])
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var text := vp.get_texture().get_image()
	vp.queue_free()
	text.convert(Image.FORMAT_RGBA8)
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(PAPER)
	img.blend_rect(text, Rect2i(Vector2i.ZERO, size), Vector2i.ZERO)
	var px := SyllabaryAlphabet.SCALE
	var n := SyllabaryAlphabet.CELL
	for token in L.cells:
		var r: Rect2i = L.cells[token]
		img.fill_rect(r.grow(1), FRAME)
		img.fill_rect(r, Color(1, 1, 1, 0))
		for i in range(1, n):
			var mid := i == n / 2
			var c := GUIDE_MID if mid else GUIDE
			for k in r.size.y:
				img.set_pixel(r.position.x + i * px, r.position.y + k, c)
			for k in r.size.x:
				img.set_pixel(r.position.x + k, r.position.y + i * px, c)
	return img.save_png(ProjectSettings.globalize_path(path))
