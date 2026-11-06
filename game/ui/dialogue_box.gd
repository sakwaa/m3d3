class_name DialogueBox
extends CanvasLayer
## The conversation UI: a Majora's Mask style text box with an Animal Crossing style name
## tag, typed letter by letter with the speaker's voice blips (VoiceSynth). Shows the
## DialogueRunner's events:
##  - lines: pages typed out ([p] pauses, [speed] changes, a beat after . ! ? and ,);
##    the interact button finishes the page, then turns it; a bouncing arrow waits;
##  - narration lines: white text centred on a black screen;
##  - item announcements: the item's icon beside the text;
##  - choices: a list beside the box (up / down, interact picks, cancel if allowed),
##    with the question still showing.
## Emits `advanced` when a line is done and `chosen(index)` for a choice. Also shows the
## "E  Talk" prompt for Talk while nothing is open.
## Laid out for a 1080-pixel-high screen and scaled to the window by steps that keep the
## font's pixels square.

signal advanced
signal chosen(index: int)

## Letters per second at talk speed 1.
const TYPE_SPEED := 38.0
const MIN_BLIP_GAP := 0.055
const BOX_SIZE := Vector2(1100, 240)
## Text inset inside the box (left, top, right, bottom); three lines fit.
const BOX_MARGIN := Vector4(56, 34, 56, 30)
const FONT_SIZE := 36
## The bitmap look: glyphs drawn at this size, scaled up by whole pixels.
const PIXEL_SIZE := 12
const PUNCTUATION_PAUSE := {".": 0.22, "!": 0.22, "?": 0.22, ",": 0.1, "…": 0.3}
const BOX_COLOR := Color(0.07, 0.05, 0.04, 0.9)
const TEXT_COLOR := Color(1.0, 0.98, 0.92)

## The game state text is read against (GameState unless set).
var gs: Node
## Font for all dialogue text (a bitmap font goes here); null = the built-in font drawn
## pixelated.
var font: Font

var is_open := false
var _event := {}
var _pages := []
var _page := 0
var _shown := 0  # letters typed on this page
var _budget := 0.0  # seconds banked towards the next letter
var _wait := 0.0  # pause before the next letter
var _speed := 1.0
var _since_blip := 1.0
var _choosing := false
var _choice := 0
var _options := []
var _cancel := -1

var _root: Control  # everything, at 1080p layout size, scaled to the window
var _shade: ColorRect
var _narration: RichTextLabel
var _frame: Control  # the box and its name tag (scaled together when opening)
var _box: PanelContainer
var _icon: TextureRect
var _text: RichTextLabel
var _tag: PanelContainer
var _tag_label: Label
var _tag_style: StyleBoxFlat
var _next: Control
var _choices_panel: PanelContainer
var _choices_box: VBoxContainer
var _prompt: PanelContainer
var _prompt_label: Label
var _prompt_key: Label
var _voice: AudioStreamPlayer
var _anim: Tween
var _time := 0.0


func _init() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	font = pixel_font()
	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_shade = ColorRect.new()
	_shade.color = Color.BLACK
	_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shade.modulate.a = 0.0
	_shade.visible = false
	_root.add_child(_shade)
	_narration = _rich(TEXT_COLOR)
	_narration.set_anchors_preset(Control.PRESET_CENTER)
	_narration.offset_left = -620
	_narration.offset_right = 620
	_narration.offset_top = -240
	_narration.offset_bottom = 240
	_narration.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_narration.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_shade.add_child(_narration)

	_frame = Control.new()
	_frame.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_frame.offset_left = -BOX_SIZE.x * 0.5
	_frame.offset_right = BOX_SIZE.x * 0.5
	_frame.offset_top = -BOX_SIZE.y - 56
	_frame.offset_bottom = -56
	_frame.pivot_offset = BOX_SIZE * 0.5
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.visible = false
	_root.add_child(_frame)
	_box = PanelContainer.new()
	_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_box.add_theme_stylebox_override(&"panel", _panel_style(BOX_COLOR, 30, BOX_MARGIN))
	_frame.add_child(_box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 28)
	_box.add_child(row)
	_icon = TextureRect.new()
	_icon.custom_minimum_size = Vector2(96, 96)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_icon)
	_text = _rich(TEXT_COLOR)
	_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(_text)

	# Name tag: a tilted pill over the box's top-left corner.
	_tag = PanelContainer.new()
	_tag_style = _panel_style(Color.ORANGE, 22, Vector4(26, 6, 26, 8))
	_tag.add_theme_stylebox_override(&"panel", _tag_style)
	_tag.rotation = deg_to_rad(-3.0)
	_tag_label = Label.new()
	_tag_label.add_theme_font_override(&"font", font)
	_tag_label.add_theme_font_size_override(&"font_size", FONT_SIZE)
	_tag_label.add_theme_color_override(&"font_color", Color(0.12, 0.08, 0.05))
	_tag_label.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_tag.add_child(_tag_label)
	_frame.add_child(_tag)
	_tag.resized.connect(func(): _tag.position = Vector2(34, -_tag.size.y * 0.62))

	_next = Control.new()
	_next.custom_minimum_size = Vector2(28, 20)
	_next.draw.connect(_draw_next)
	_next.visible = false
	_root.add_child(_next)

	_choices_panel = PanelContainer.new()
	_choices_panel.add_theme_stylebox_override(&"panel", _panel_style(BOX_COLOR, 24, Vector4(30, 18, 40, 18)))
	_choices_panel.visible = false
	_root.add_child(_choices_panel)
	_choices_box = VBoxContainer.new()
	_choices_box.add_theme_constant_override(&"separation", 6)
	_choices_panel.add_child(_choices_box)

	_prompt = PanelContainer.new()
	_prompt.add_theme_stylebox_override(&"panel", _panel_style(Color(0.07, 0.05, 0.04, 0.75), 18, Vector4(20, 6, 22, 8)))
	_prompt.visible = false
	_root.add_child(_prompt)
	var prompt_row := HBoxContainer.new()
	prompt_row.add_theme_constant_override(&"separation", 14)
	_prompt.add_child(prompt_row)
	_prompt_key = _label("", DialogueText.COLORS.yellow)
	prompt_row.add_child(_prompt_key)
	_prompt_label = _label("", TEXT_COLOR)
	prompt_row.add_child(_prompt_label)

	_voice = AudioStreamPlayer.new()
	_voice.max_polyphony = 3
	add_child(_voice)


func _ready() -> void:
	if gs == null:
		gs = get_node_or_null(^"/root/GameState")
	get_viewport().size_changed.connect(_fit)
	_fit()


func _fit() -> void:
	var vp := get_viewport().get_visible_rect().size
	# Thirds, so the 3× pixel font lands on whole screen pixels.
	var s := maxf(roundf(vp.y / 1080.0 * 3.0) / 3.0, 1.0 / 3.0)
	_root.scale = Vector2(s, s)
	_root.size = vp / s


## The interact button's first key ("E").
static func _key_name() -> String:
	if InputMap.has_action(&"interact"):
		for e in InputMap.action_get_events(&"interact"):
			if e is InputEventKey:
				return OS.get_keycode_string(e.physical_keycode if e.physical_keycode else e.keycode)
	return "A"


## The built-in font with hard pixels (no smoothing, scaled by whole steps), until a bitmap
## font is set.
static func pixel_font() -> Font:
	var base := ThemeDB.fallback_font
	if not base is FontFile:
		return base
	var f: FontFile = base.duplicate()
	f.fixed_size = PIXEL_SIZE
	f.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_INTEGER_ONLY
	f.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	f.hinting = TextServer.HINTING_NORMAL
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	f.generate_mipmaps = false
	return f


func _rich(color: Color) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	r.add_theme_font_override(&"normal_font", font)
	r.add_theme_font_size_override(&"normal_font_size", FONT_SIZE)
	r.add_theme_color_override(&"default_color", color)
	r.add_theme_constant_override(&"line_separation", 6)
	return r


func _label(text: String, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	l.add_theme_font_override(&"font", font)
	l.add_theme_font_size_override(&"font_size", FONT_SIZE)
	l.add_theme_color_override(&"font_color", color)
	return l


static func _panel_style(color: Color, radius: int, margin: Vector4) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.corner_detail = 6  # a little chunky
	s.content_margin_left = margin.x
	s.content_margin_top = margin.y
	s.content_margin_right = margin.z
	s.content_margin_bottom = margin.w
	return s


# --- Showing events -----------------------------------------------------------------

func show_line(event: Dictionary) -> void:
	_event = event
	_choosing = false
	_choices_panel.visible = false
	var narration: bool = event.style == DialogueLine.Style.NARRATION
	_set_shade(narration)
	if narration:
		_frame.visible = false
	else:
		_open_box()
		var tag: String = event.name
		_tag.visible = tag != ""
		_tag_label.text = tag
		_tag.reset_size()
		_tag_style.bg_color = event.color
		_icon.texture = event.icon
		_icon.visible = event.icon != null
	is_open = true
	_pages = DialogueText.pages(event.text, gs)
	_page = 0
	_start_page()


func show_choice(event: Dictionary) -> void:
	_choosing = true
	_options = event.options
	_cancel = event.cancel
	_choice = 0
	for c in _choices_box.get_children():
		_choices_box.remove_child(c)
		c.queue_free()
	for i in _options.size():
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 12)
		var cursor := Control.new()
		cursor.custom_minimum_size = Vector2(20, 0)
		cursor.draw.connect(_draw_cursor.bind(cursor))
		row.add_child(cursor)
		row.add_child(_label(DialogueText.parse_page(DialogueText.expand(_options[i], gs)).plain, TEXT_COLOR))
		_choices_box.add_child(row)
	_next.visible = false
	_update_choices()
	_choices_panel.visible = true
	_choices_panel.reset_size()
	_place_choices()


func close() -> void:
	is_open = false
	_choosing = false
	_choices_panel.visible = false
	_next.visible = false
	_set_shade(false)
	if _frame.visible:
		if _anim:
			_anim.kill()
		_anim = create_tween().set_parallel()
		_anim.tween_property(_frame, "scale", Vector2(0.92, 0.92), 0.08)
		_anim.tween_property(_frame, "modulate:a", 0.0, 0.08)
		_anim.chain().tween_callback(func(): _frame.visible = false)


## The "E  Talk" hint ("" hides it).
func set_prompt(text: String) -> void:
	_prompt.visible = text != "" and not is_open
	if _prompt.visible and _prompt_label.text != text:
		_prompt_label.text = text
		_prompt_key.text = _key_name()  # read late: the player sets up the input map
		_prompt.reset_size()
	if _prompt.visible:
		_prompt.position = _root.size - _prompt.size - Vector2(48, 40)


func _open_box() -> void:
	if _frame.visible and _frame.modulate.a > 0.5:
		return
	_frame.visible = true
	if _anim:
		_anim.kill()
	_frame.scale = Vector2(0.85, 0.85)
	_frame.modulate.a = 0.0
	_anim = create_tween().set_parallel().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_anim.tween_property(_frame, "scale", Vector2.ONE, 0.16)
	_anim.tween_property(_frame, "modulate:a", 1.0, 0.1)


func _set_shade(on: bool) -> void:
	if on == (_shade.visible and _shade.modulate.a > 0.5):
		return
	_shade.visible = true
	var t := create_tween()
	t.tween_property(_shade, "modulate:a", 1.0 if on else 0.0, 0.35)
	if not on:
		t.tween_callback(func(): _shade.visible = false)
	if not on:
		_narration.text = ""


func _target() -> RichTextLabel:
	return _narration if _event.get("style") == DialogueLine.Style.NARRATION else _text


func _start_page() -> void:
	var page: Dictionary = _pages[_page]
	var label := _target()
	label.text = page.bbcode
	label.visible_characters = 0
	_shown = 0
	_budget = 0.0
	_wait = 0.0
	_speed = 1.0
	_apply_marks()
	_next.visible = false


func is_typing() -> bool:
	return is_open and not _pages.is_empty() and _shown < _pages[_page].plain.length()


func _finish_page() -> void:
	var page: Dictionary = _pages[_page]
	_shown = page.plain.length()
	_target().visible_characters = -1


func _process(delta: float) -> void:
	_time += delta
	_since_blip += delta
	if _next.visible:
		_next.queue_redraw()
	if _choosing:
		for row in _choices_box.get_children():
			row.get_child(0).queue_redraw()
	if not is_open or _pages.is_empty():
		return
	var page: Dictionary = _pages[_page]
	var who: CharacterDef = _event.get("speaker")
	var cps := TYPE_SPEED * (who.talk_speed if who else 1.0)
	_budget += delta
	while _shown < page.plain.length():
		if _wait > 0.0:
			var used := minf(_wait, _budget)
			_wait -= used
			_budget -= used
			if _wait > 0.0:
				break
		var cost := 1.0 / (cps * _speed)
		if _budget < cost:
			break
		_budget -= cost
		var ch: String = page.plain[_shown]
		_shown += 1
		_target().visible_characters = _shown
		_blip(who, ch)
		_wait += PUNCTUATION_PAUSE.get(ch, 0.0) if _shown < page.plain.length() and page.plain[_shown] in [" ", "\n"] else 0.0
		_apply_marks()
	if _shown >= page.plain.length():
		_budget = 0.0
		if not _next.visible and not _choosing:
			_next.visible = true
			_place_next()


## [p] pauses and [speed] changes that start at the current letter.
func _apply_marks() -> void:
	var page: Dictionary = _pages[_page]
	_wait += page.pauses.get(_shown, 0.0)
	for s in page.speeds:
		if s[0] == _shown:
			_speed = s[1]


func _blip(who: CharacterDef, ch: String) -> void:
	if who == null or who.silent or _since_blip < MIN_BLIP_GAP:
		return
	var wav := VoiceSynth.blip(who, ch)
	if wav:
		_voice.stream = wav
		_voice.volume_db = who.voice_volume
		_voice.play()
		_since_blip = 0.0


# --- Input --------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not is_open or event.is_echo():
		return
	if _choosing and not is_typing():
		if _pressed(event, [&"ui_up"], [KEY_W, KEY_UP]):
			_choice = (_choice + _options.size() - 1) % _options.size()
			_update_choices()
		elif _pressed(event, [&"ui_down"], [KEY_S, KEY_DOWN]):
			_choice = (_choice + 1) % _options.size()
			_update_choices()
		elif _pressed(event, [&"interact", &"ui_accept"], []):
			_choosing = false
			chosen.emit(_choice)
		elif _cancel >= 0 and _pressed(event, [&"ui_cancel", &"guard"], []):
			_choosing = false
			chosen.emit(_cancel)
		else:
			return
		get_viewport().set_input_as_handled()
		return
	if _pressed(event, [&"interact", &"ui_accept", &"attack"], []):
		get_viewport().set_input_as_handled()
		if is_typing():
			_finish_page()
		elif _page + 1 < _pages.size():
			_page += 1
			_start_page()
		elif not _choosing:
			advanced.emit()
	elif event is InputEventKey or event is InputEventJoypadButton:
		# The world doesn't see other buttons while a conversation is open.
		get_viewport().set_input_as_handled()


static func _pressed(event: InputEvent, actions: Array, keys: Array) -> bool:
	if not event.is_pressed():
		return false
	for a in actions:
		if InputMap.has_action(a) and event.is_action_pressed(a):
			return true
	return event is InputEventKey and event.physical_keycode in keys


func _update_choices() -> void:
	for i in _choices_box.get_child_count():
		var row := _choices_box.get_child(i)
		var on := i == _choice
		row.get_child(0).modulate.a = 1.0 if on else 0.0
		row.get_child(0).queue_redraw()
		row.get_child(1).add_theme_color_override(&"font_color", DialogueText.COLORS.yellow if on else TEXT_COLOR)


func _place_choices() -> void:
	var r := _frame.get_rect()
	var size := _choices_panel.get_combined_minimum_size()
	_choices_panel.position = Vector2(r.end.x - size.x - 24, r.position.y - size.y - 18)


func _place_next() -> void:
	var r := _narration.get_rect() if _target() == _narration else _frame.get_rect()
	_next.position = Vector2(r.end.x - 64, r.end.y - 42) if _target() == _text else Vector2(r.get_center().x - 14, r.end.y + 30)


func _draw_cursor(c: Control) -> void:
	var x := 3.0 * absf(sin(_time * 6.0))
	var mid := c.size.y * 0.5
	c.draw_colored_polygon(PackedVector2Array([Vector2(x, mid - 10), Vector2(x + 16, mid), Vector2(x, mid + 10)]), DialogueText.COLORS.yellow)


func _draw_next() -> void:
	var y := 4.0 * absf(sin(_time * 5.0))
	_next.draw_colored_polygon(PackedVector2Array([Vector2(0, y), Vector2(28, y), Vector2(14, y + 16)]), DialogueText.COLORS.yellow)
