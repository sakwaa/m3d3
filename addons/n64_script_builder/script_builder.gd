@tool
extends HSplitContainer
## The Script Builder tab: pick a glyph on the left (consonants, vowel marks, finals,
## punctuation, whole syllables, spelling marks), draw it pixel by pixel in the middle, see text written in
## the script on the right. Every stroke is saved to the alphabet (with undo) and rebuilds
## banners using it.
##
## Canvas: left drag = draw, right drag = erase, Shift + click = straight line from the last
## pixel. Under the glyph, faintly: the consonant a vowel mark / final goes with, or the
## syllable as it's built from its base + mark (Guide).

const GlyphText := preload("res://addons/n64_level_tools/glyphs/glyph_text.gd")
const Gen := preload("res://addons/n64_level_tools/textures/rope_texture_generator.gd")
const DEFAULT := "res://glyphs/syllabary/alphabet.tres"
const N := SyllabaryAlphabet.CELL
const SECTIONS := ["Consonants", "Vowel marks", "Finals", "Punctuation", "Syllables", "Spelling marks"]
const PAPER := Color(0.93, 0.91, 0.85)
const INK := Color(0.12, 0.1, 0.1)

var undo_redo: EditorUndoRedoManager
var alphabet: SyllabaryAlphabet
var token := "K"
var guide_consonant := "_"

var _picker: Control  # an EditorResourcePicker (editor only)
var _section := OptionButton.new()
var _palette := VBoxContainer.new()  # holds the flowing palette or the syllable grid
var _thumbs := {}  # token -> TextureRect
var _canvas := Canvas.new()
var _title := Label.new()
var _guide := CheckBox.new()
var _zones := CheckBox.new()
var _zone_target := OptionButton.new()
var _guide_pick := OptionButton.new()
var _sample := TextEdit.new()
var _preview := TextureRect.new()
var _notes := Label.new()
var _clipboard := PackedByteArray()


func _init() -> void:
	split_offset = 420
	# --- Left: alphabet + palette.
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 200
	add_child(left)
	if Engine.is_editor_hint():
		_picker = ClassDB.instantiate(&"EditorResourcePicker")
		_picker.set(&"base_type", "SyllabaryAlphabet")
		_picker.connect(&"resource_changed", func(r): _use(r))
		left.add_child(_picker)
	for s in SECTIONS:
		_section.add_item(s)
	_section.add_theme_font_size_override(&"font_size", _fs(16))
	_section.item_selected.connect(_on_section)
	left.add_child(_section)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_palette.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_palette)
	left.add_child(scroll)
	var import := Button.new()
	import.text = "Copy squares drawn on the template"
	import.clip_text = true
	import.custom_minimum_size.x = 120
	import.tooltip_text = "Brings every square drawn on the alphabet's template PNG in as Script Builder glyphs\n(squares already drawn here are kept)."
	import.pressed.connect(_import_template)
	left.add_child(import)

	var right_split := HSplitContainer.new()
	right_split.split_offset = 0
	add_child(right_split)

	# --- Middle: tools + canvas.
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_split.add_child(mid)
	_title.add_theme_font_size_override(&"font_size", _fs(20))
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.custom_minimum_size.x = 100
	mid.add_child(_title)
	var tools := HFlowContainer.new()
	mid.add_child(tools)
	for t in [["Clear", _clear], ["Flip ↔", _flip.bind(true)], ["Flip ↕", _flip.bind(false)], ["←", _nudge.bind(Vector2i.LEFT)],
			["→", _nudge.bind(Vector2i.RIGHT)], ["↑", _nudge.bind(Vector2i.UP)], ["↓", _nudge.bind(Vector2i.DOWN)],
			["Copy", _copy], ["Paste", _paste]]:
		var b := Button.new()
		b.text = t[0]
		b.pressed.connect(t[1])
		tools.add_child(b)
	_zones.text = "Zones"
	_zones.button_pressed = true
	_zones.tooltip_text = "Show where this kind of glyph goes (green: consonant base, orange: vowel mark, purple: final,\npink: spelling mark, red band: the empty margin). Pixels outside show red. Alt+drag on the canvas: set this kind's zone."
	_zones.toggled.connect(func(_on): _canvas.queue_redraw())
	tools.add_child(_zones)
	for label in ["Alt+drag sets: this glyph's zone", "Alt+drag sets: Base (green)", "Alt+drag sets: Mark (orange)",
			"Alt+drag sets: Final (purple)", "Alt+drag sets: Spelling (pink)"]:
		_zone_target.add_item(label)
	_zone_target.tooltip_text = "Which zone Alt+dragging on the canvas sets."
	_zone_target.fit_to_longest_item = false
	_zone_target.clip_text = true
	_zone_target.custom_minimum_size.x = 140
	_zone_target.item_selected.connect(func(_i): _canvas.queue_redraw())
	tools.add_child(_zone_target)
	_guide.text = "Guide"
	_guide.button_pressed = true
	_guide.tooltip_text = "Show faintly what this glyph goes with: the consonant under a vowel mark or final,\nthe base + mark a syllable is built from."
	_guide.toggled.connect(func(_on): _canvas.queue_redraw())
	tools.add_child(_guide)
	for c in SyllabaryAlphabet.CONSONANTS:
		_guide_pick.add_item(SyllabaryAlphabet.NAMES[c][0])
	_guide_pick.tooltip_text = "Consonant shown under vowel marks."
	_guide_pick.item_selected.connect(_on_guide_pick)
	tools.add_child(_guide_pick)
	_canvas.builder = self
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_child(_canvas)
	var help := Label.new()
	help.text = "Left drag: draw · Right drag: erase · Shift + click: line from the last pixel · Alt + drag: set a zone (which one: toolbar) · saved as you draw (Ctrl+Z undoes)"
	help.add_theme_font_size_override(&"font_size", _fs(14))
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.custom_minimum_size.x = 100
	mid.add_child(help)

	# --- Right: preview.
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 240
	right_split.add_child(right)
	var pl := Label.new()
	pl.text = "Preview (English, as on a banner)"
	pl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pl.custom_minimum_size.x = 100
	right.add_child(pl)
	_sample.text = "Welcome to the potion shop!"
	_sample.custom_minimum_size.y = 60
	_sample.text_changed.connect(_refresh_preview)
	right.add_child(_sample)
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_preview)
	_notes.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notes.custom_minimum_size.x = 100
	_notes.add_theme_font_size_override(&"font_size", _fs(14))
	right.add_child(_notes)


func _on_guide_pick(i: int) -> void:
	guide_consonant = SyllabaryAlphabet.CONSONANTS[i]
	_canvas.queue_redraw()


func _ready() -> void:
	if alphabet == null and ResourceLoader.exists(DEFAULT):
		_use(load(DEFAULT))


func _use(a: Resource) -> void:
	if alphabet and alphabet.changed.is_connected(_on_alphabet_changed):
		alphabet.changed.disconnect(_on_alphabet_changed)
	alphabet = a as SyllabaryAlphabet
	if _picker:
		_picker.set(&"edited_resource", alphabet)
	if alphabet:
		alphabet.changed.connect(_on_alphabet_changed)
	_fill_palette()
	_select(token)


func _on_alphabet_changed() -> void:
	for t in _thumbs:
		_thumbs[t].texture = _thumb(t)
	_canvas.queue_redraw()
	_refresh_preview()


# --- Palette ----------------------------------------------------------------------------

func _section_tokens(i: int) -> Array:
	match i:
		0: return SyllabaryAlphabet.CONSONANTS
		1: return SyllabaryAlphabet.VOWELS.map(func(v): return "~" + v)
		2: return SyllabaryAlphabet.CONSONANTS.slice(1).map(func(c): return "-" + c)
		3: return SyllabaryAlphabet.PUNCT
		5: return range(1, SyllabaryAlphabet.SPELL_MARKS + 1).map(SyllabaryAlphabet.spell_token)
	var out := []
	for c in SyllabaryAlphabet.CONSONANTS:
		for v in SyllabaryAlphabet.VOWELS:
			out.append(c + "." + v)
	return out


## A section picked: its glyphs in the palette, and the first one on the canvas (unless the
## current glyph is in it).
func _on_section(i: int) -> void:
	_fill_palette()
	var tokens := _section_tokens(i)
	if not token in tokens:
		_select(tokens[0])


func _fill_palette() -> void:
	for c in _palette.get_children():
		c.queue_free()
	_thumbs.clear()
	var sec := _section.selected
	var syllables := sec == 4
	# Sections wrap to the panel's width; the syllable grid keeps its rows (scrolls sideways).
	var holder: Container
	if syllables:
		var grid := GridContainer.new()
		grid.columns = SyllabaryAlphabet.VOWELS.size() + 1
		grid.add_child(Control.new())
		for v in SyllabaryAlphabet.VOWELS:
			grid.add_child(_small_label(SyllabaryAlphabet.NAMES[v][0]))
		holder = grid
	else:
		holder = HFlowContainer.new()
		holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_theme_constant_override(&"h_separation", 10)
	holder.add_theme_constant_override(&"v_separation", 10)
	_palette.add_child(holder)
	for t: String in _section_tokens(sec):
		if syllables and t.ends_with("." + SyllabaryAlphabet.VOWELS[0]):
			holder.add_child(_small_label(SyllabaryAlphabet.NAMES[t.get_slice(".", 0)][0]))
		var box := VBoxContainer.new()
		var b := Button.new()
		b.flat = true
		b.tooltip_text = _describe(t)
		b.pressed.connect(_select.bind(t))
		var tr := TextureRect.new()
		tr.texture = _thumb(t)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(tr)
		b.custom_minimum_size = Vector2(N * 3 + 4, N * 3 + 4)
		box.add_child(b)
		if not syllables:
			box.add_child(_small_label(_short_name(t)))
		_thumbs[t] = tr
		holder.add_child(box)


func _small_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override(&"font_size", _fs(14))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


## A font size scaled for the editor's display scale.
static func _fs(base: int) -> int:
	return roundi(base * (EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0))


func _bare(t: String) -> String:
	if t in SyllabaryAlphabet.PUNCT:
		return t
	return t.trim_prefix("~").trim_prefix("-")


func _short_name(t: String) -> String:
	var n: Array = SyllabaryAlphabet.name_of(_bare(t))
	return "%s\n%s" % [n[0], n[1]]


func _describe(t: String) -> String:
	if t in SyllabaryAlphabet.PUNCT:  # before the prefix checks: "-", "--" and "." are punctuation
		return "Punctuation: %s (%s)" % SyllabaryAlphabet.NAMES[t]
	if t.begins_with("#"):
		return "Spelling mark %s: under a word that sounds like others (the %s most common of them)%s" % [t.substr(1),
			_ordinal(t.substr(1).to_int() + 1), "" if _drawn(t) else " — empty: a tally"]
	if t.contains("."):
		var c := t.get_slice(".", 0)
		var v := t.get_slice(".", 1)
		return "Syllable %s + %s (%s / %s)%s" % [SyllabaryAlphabet.NAMES[c][0], SyllabaryAlphabet.NAMES[v][0],
			SyllabaryAlphabet.NAMES[c][1], SyllabaryAlphabet.NAMES[v][1],
			"" if _drawn(t) else " — empty: built from the base + mark"]
	if t.begins_with("~"):
		return "Vowel mark: %s (as in %s)" % SyllabaryAlphabet.NAMES[_bare(t)]
	if t.begins_with("-"):
		return "Final %s (as in %s): a consonant with no vowel after it%s" % [SyllabaryAlphabet.NAMES[_bare(t)][0],
			SyllabaryAlphabet.NAMES[_bare(t)][1], "" if _drawn(t) else " — empty: uses the base shape"]
	if t == SyllabaryAlphabet.NONE:
		return "Vowel carrier (no consonant): what a vowel mark sits on at the start of a syllable"
	return "Consonant %s (as in %s): its base shape" % SyllabaryAlphabet.NAMES[t]


static func _ordinal(n: int) -> String:
	var suffix := "th" if n % 100 in [11, 12, 13] else ({1: "st", 2: "nd", 3: "rd"} as Dictionary).get(n % 10, "th")
	return "%d%s" % [n, suffix]


func _drawn(t: String) -> bool:
	return alphabet != null and alphabet.cell(t) != null


## Thumbnail: the glyph as it's written (a syllable built from its parts shows faintly).
func _thumb(t: String) -> Texture2D:
	var img := Image.create(N, N, false, Image.FORMAT_RGBA8)
	img.fill(PAPER)
	if alphabet:
		var g := alphabet.cell(t)
		var faint := false
		if g == null and t.contains(".") and not t in SyllabaryAlphabet.PUNCT:
			g = alphabet.syllable(t.get_slice(".", 0), t.get_slice(".", 1))
			faint = true
		if g:
			for y in N:
				for x in N:
					if g.get_pixel(x, y).a > 0.5:
						img.set_pixel(x, y, INK.lerp(PAPER, 0.6) if faint else INK)
	img.resize(N * 3, N * 3, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(img)


func _select(t: String) -> void:
	token = t
	_title.text = _describe(t)
	_canvas.queue_redraw()


# --- Editing ----------------------------------------------------------------------------

func bits() -> PackedByteArray:
	if alphabet == null:
		return PackedByteArray()
	var b := alphabet.glyph_bits(token)
	if b.is_empty():
		# Not drawn here yet: start from the template's square, if it has one.
		b = SyllabaryAlphabet.image_to_bits(alphabet.template_cell(token))
	return b


## Commits a change to the current glyph (one undo step), saving the alphabet.
func commit(new_bits: PackedByteArray, action := "Draw Glyph") -> void:
	if alphabet == null:
		return
	var old := alphabet.glyph_bits(token)
	if old == new_bits:
		return
	undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, alphabet)
	undo_redo.add_do_method(self, &"_apply", alphabet, token, new_bits)
	undo_redo.add_undo_method(self, &"_apply", alphabet, token, old)
	undo_redo.commit_action()


func _apply(a: SyllabaryAlphabet, t: String, b: PackedByteArray) -> void:
	a.set_glyph_bits(t, b)
	if a.resource_path != "":
		ResourceSaver.save(a)


func _clear() -> void:
	var b := PackedByteArray()
	b.resize(N * N / 8)
	commit(b, "Clear Glyph")


func _transform(f: Callable, action: String) -> void:
	var src := SyllabaryAlphabet.bits_to_image(bits())
	var out := PackedByteArray()
	out.resize(N * N / 8)
	if src:
		for y in N:
			for x in N:
				if src.get_pixel(x, y).a > 0.5:
					var p: Vector2i = f.call(Vector2i(x, y))
					if p.x >= 0 and p.y >= 0 and p.x < N and p.y < N:
						out[p.y * 2 + p.x / 8] |= 1 << (p.x % 8)
	commit(out, action)


func _flip(horizontal: bool) -> void:
	_transform(func(p: Vector2i) -> Vector2i: return Vector2i(N - 1 - p.x, p.y) if horizontal else Vector2i(p.x, N - 1 - p.y),
		"Flip Glyph")


func _nudge(d: Vector2i) -> void:
	_transform(func(p: Vector2i) -> Vector2i: return p + d, "Move Glyph")


func _copy() -> void:
	_clipboard = bits()


func _paste() -> void:
	if not _clipboard.is_empty():
		commit(_clipboard.duplicate(), "Paste Glyph")


func _import_template() -> void:
	if alphabet == null or alphabet.template == null:
		push_warning("Script Builder: this alphabet has no template to copy from.")
		return
	var g := alphabet.glyphs.duplicate()
	var n := 0
	for t in SyllabaryAlphabet.layout().cells:
		if g.has(t):
			continue
		var img := alphabet.template_cell(t)
		if img:
			g[t] = SyllabaryAlphabet.image_to_bits(img)
			n += 1
	undo_redo.create_action("Copy Template Glyphs", UndoRedo.MERGE_DISABLE, alphabet)
	undo_redo.add_do_property(alphabet, &"glyphs", g)
	undo_redo.add_undo_property(alphabet, &"glyphs", alphabet.glyphs)
	undo_redo.commit_action()
	if alphabet.resource_path != "":
		ResourceSaver.save(alphabet)
	print("[Script Builder] %d squares copied from the template." % n)


## The zone property the current glyph kind uses ("": punctuation, which has none of its own).
func zone_property() -> StringName:
	if token in SyllabaryAlphabet.PUNCT:
		return &""
	if token.begins_with("#"):
		return &"zone_spell"
	if token.begins_with("~"):
		return &"zone_mark"
	if token.begins_with("-"):
		return &"zone_final"
	return &"zone_base"  # consonants, the carrier, syllables (their base)


## The zone Alt+drag sets: the one picked in the toolbar, else the current glyph kind's.
func target_zone() -> StringName:
	match _zone_target.selected:
		1: return &"zone_base"
		2: return &"zone_mark"
		3: return &"zone_final"
		4: return &"zone_spell"
	return zone_property()


func set_zone(rect: Rect2i) -> void:
	var prop := target_zone()
	if alphabet == null or prop == &"" or alphabet.get(prop) == rect:
		return
	undo_redo.create_action("Set Glyph Zone", UndoRedo.MERGE_DISABLE, alphabet)
	undo_redo.add_do_property(alphabet, prop, rect)
	undo_redo.add_undo_property(alphabet, prop, alphabet.get(prop))
	undo_redo.add_do_method(self, &"_save")
	undo_redo.add_undo_method(self, &"_save")
	undo_redo.commit_action()


func _save() -> void:
	if alphabet and alphabet.resource_path != "":
		ResourceSaver.save(alphabet)


func zones_visible() -> bool:
	return _zones.button_pressed


## What the canvas shows faintly under the current glyph (null: nothing).
func guide_image() -> Image:
	if not _guide.button_pressed or alphabet == null or token in SyllabaryAlphabet.PUNCT:
		return null
	if token.begins_with("#"):
		# The mark before it, to keep the numbers alike.
		var n := token.substr(1).to_int()
		return alphabet.cell(SyllabaryAlphabet.spell_token(n - 1)) if n > 1 else null
	if token.begins_with("~"):
		return alphabet.cell(guide_consonant)
	if token.begins_with("-"):
		return alphabet.cell(_bare(token))
	if token.contains("."):
		var c := token.get_slice(".", 0)
		var v := token.get_slice(".", 1)
		var out := Image.create(N, N, false, Image.FORMAT_RGBA8)
		for part in [alphabet.cell(c), alphabet.cell("~" + v)]:
			if part:
				out.blend_rect(part, Rect2i(0, 0, N, N), Vector2i.ZERO)
		return out
	return null


# --- Preview ----------------------------------------------------------------------------

func _refresh_preview() -> void:
	if alphabet == null:
		_preview.texture = null
		_notes.text = "Pick or make a SyllabaryAlphabet (top left)."
		return
	var enc := GlyphText.checked(_sample.text)
	var img: Image = Gen.text_banner(Color(0.93, 0.92, 0.86), Color(0.6, 0.14, 0.1), INK, alphabet, enc.items).duplicate()
	var k := maxi(1, 480 / img.get_height())
	img.resize(img.get_width() * k, img.get_height() * k, Image.INTERPOLATE_NEAREST)
	_preview.texture = ImageTexture.create_from_image(img)
	var missing: Array = alphabet.draw(Image.create(512, 512, false, Image.FORMAT_RGBA8), enc.items, Rect2i(0, 0, 512, 512),
		INK).missing
	var lines := []
	if not missing.is_empty():
		lines.append("Not drawn yet: " + ", ".join(missing))
	lines.append(GlyphText.breakdown(_sample.text))
	_notes.text = "\n".join(lines)


## The drawing surface: the glyph's 16 x 16 pixels, as big as fits, a grid between them.
class Canvas extends Control:
	const N := SyllabaryAlphabet.CELL
	const PAPER := Color(0.93, 0.91, 0.85)
	const INK := Color(0.12, 0.1, 0.1)
	var builder
	var _painting := 0  # 1 drawing, -1 erasing
	var _bits := PackedByteArray()
	var _last := Vector2i(-1, -1)

	func _init() -> void:
		custom_minimum_size = Vector2(200, 200)
		focus_mode = Control.FOCUS_CLICK

	func _cell() -> float:
		return floorf(minf(size.x, size.y) / N)

	func _origin() -> Vector2:
		var c := _cell()
		return ((size - Vector2(c * N, c * N)) * 0.5).floor()

	func _pixel_at(p: Vector2) -> Vector2i:
		var q := ((p - _origin()) / _cell()).floor()
		return Vector2i(q)

	var _zone_from := Vector2i(-1, -1)
	var _zone_to := Vector2i(-1, -1)

	func _gui_input(event: InputEvent) -> void:
		if builder.alphabet == null:
			return
		# Alt + drag: set a zone (which one: toolbar).
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and (event.alt_pressed or _zone_from.x >= 0):
			var p := _pixel_at(event.position).clamp(Vector2i.ZERO, Vector2i(N - 1, N - 1))
			if event.pressed:
				_zone_from = p
				_zone_to = p
			else:
				var lo := _zone_from.min(p)
				var hi := _zone_from.max(p)
				_zone_from = Vector2i(-1, -1)
				builder.set_zone(Rect2i(lo, hi - lo + Vector2i.ONE))
			queue_redraw()
			accept_event()
			return
		if event is InputEventMouseMotion and _zone_from.x >= 0:
			_zone_to = _pixel_at(event.position).clamp(Vector2i.ZERO, Vector2i(N - 1, N - 1))
			queue_redraw()
			accept_event()
			return
		if event is InputEventMouseButton:
			if event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
				_painting = 1 if event.button_index == MOUSE_BUTTON_LEFT else -1
				_bits = builder.bits().duplicate()
				if _bits.size() != N * N / 8:
					_bits.resize(N * N / 8)
				var p := _pixel_at(event.position)
				if event.shift_pressed and _last.x >= 0:
					_line(_last, p)
				else:
					_plot(p)
				_last = p
				queue_redraw()
				accept_event()
			elif not event.pressed and _painting != 0:
				_painting = 0
				builder.commit(_bits)
				_bits = PackedByteArray()
				accept_event()
		elif event is InputEventMouseMotion and _painting != 0:
			var p := _pixel_at(event.position)
			if p != _last:
				_line(_last, p)
				_last = p
				queue_redraw()
			accept_event()

	func _plot(p: Vector2i) -> void:
		if p.x < 0 or p.y < 0 or p.x >= N or p.y >= N:
			return
		var i := p.y * 2 + p.x / 8
		if _painting > 0:
			_bits[i] |= 1 << (p.x % 8)
		else:
			_bits[i] &= ~(1 << (p.x % 8))

	func _line(a: Vector2i, b: Vector2i) -> void:
		var steps := maxi(absi(b.x - a.x), absi(b.y - a.y))
		for i in steps + 1:
			var t := float(i) / maxf(steps, 1)
			_plot(Vector2i(roundi(lerpf(a.x, b.x, t)), roundi(lerpf(a.y, b.y, t))))

	func _draw() -> void:
		var c := _cell()
		var o := _origin()
		draw_rect(Rect2(o, Vector2(c * N, c * N)), PAPER)
		var guide: Image = builder.guide_image()
		var current: PackedByteArray = _bits if _painting != 0 else builder.bits()
		var a: SyllabaryAlphabet = builder.alphabet
		var show_zones: bool = builder.zones_visible() and a != null
		var allowed: Array[Rect2i] = a.zones_for(builder.token) if a else ([] as Array[Rect2i])
		var m: int = a.margin if a else 0
		for y in N:
			for x in N:
				var r := Rect2(o + Vector2(x, y) * c, Vector2(c, c))
				var on: bool = current.size() == N * N / 8 and (current[y * 2 + x / 8] & (1 << (x % 8))) != 0
				var in_margin := x < m or y < m or x >= N - m or y >= N - m
				if show_zones and in_margin:
					draw_rect(r, Color(0.9, 0.35, 0.3, 0.12))
				if on:
					var inside := not show_zones or (not in_margin and allowed.any(func(z: Rect2i) -> bool: return z.has_point(Vector2i(x, y))))
					draw_rect(r, INK if inside else Color(0.8, 0.15, 0.1))
				elif guide and guide.get_pixel(x, y).a > 0.5:
					draw_rect(r, Color(0.35, 0.65, 0.95, 0.35))
		if show_zones:
			var colors := {&"zone_base": Color(0.2, 0.65, 0.3), &"zone_mark": Color(0.95, 0.55, 0.1), &"zone_final": Color(0.6, 0.3, 0.8),
				&"zone_spell": Color(0.9, 0.3, 0.6)}
			var active: StringName = builder.zone_property()
			var target: StringName = builder.target_zone()
			for prop in colors:
				var z: Rect2i = a.get(prop)
				var mine: bool = prop == active or prop == target or (builder.token.contains(".") and not builder.token in SyllabaryAlphabet.PUNCT and prop == &"zone_mark")
				var col: Color = colors[prop]
				col.a = 1.0 if mine else 0.3
				draw_rect(Rect2(o + Vector2(z.position) * c, Vector2(z.size) * c).grow(-1), col, false, 3.0 if mine else 1.5)
			if _zone_from.x >= 0:
				var lo := _zone_from.min(_zone_to)
				var hi := _zone_from.max(_zone_to)
				var col: Color = colors.get(target, Color.WHITE)
				draw_rect(Rect2(o + Vector2(lo) * c, Vector2(hi - lo + Vector2i.ONE) * c), col, false, 3.0)
		var line := Color(0, 0, 0, 0.12)
		for i in N + 1:
			var w := 2.0 if i == N / 2 else 1.0
			draw_line(o + Vector2(i * c, 0), o + Vector2(i * c, c * N), line, w)
			draw_line(o + Vector2(0, i * c), o + Vector2(c * N, i * c), line, w)
