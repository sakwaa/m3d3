@tool
extends VBoxContainer
## Preview of a dialogue line as the game shows it (DialogueBox's box, name tag and
## pixel font, at half size), one page at a time, with ▶ to type it out with the speaker's
## voice. Also measures pages against the box (overflowing_pages).

const SCALE := 0.5

var gs: Node
var _line: DialogueLine
var _pages := []
var _page := 0
var _stage: Control
var _shade: ColorRect
var _box: PanelContainer
var _text: RichTextLabel
var _tag: PanelContainer
var _tag_label: Label
var _tag_style: StyleBoxFlat
var _page_label: Label
var _voice: AudioStreamPlayer
var _typing := -1.0  # letters typed so far while playing (-1 = not playing)
var _since_blip := 1.0


func _init() -> void:
	var holder := Control.new()
	holder.custom_minimum_size = (DialogueBox.BOX_SIZE + Vector2(0, 40)) * SCALE
	holder.clip_contents = true
	add_child(holder)
	_stage = Control.new()
	_stage.scale = Vector2(SCALE, SCALE)
	_stage.position = Vector2(0, 40 * SCALE)
	holder.add_child(_stage)
	_shade = ColorRect.new()
	_shade.color = Color.BLACK
	_shade.position = Vector2(0, -40)
	_shade.size = DialogueBox.BOX_SIZE + Vector2(0, 40)
	_stage.add_child(_shade)
	_box = PanelContainer.new()
	_box.size = DialogueBox.BOX_SIZE
	_box.add_theme_stylebox_override(&"panel", DialogueBox._panel_style(DialogueBox.BOX_COLOR, 30, DialogueBox.BOX_MARGIN))
	_stage.add_child(_box)
	_text = _rich()
	_box.add_child(_text)
	_tag = PanelContainer.new()
	_tag_style = DialogueBox._panel_style(Color.ORANGE, 22, Vector4(26, 6, 26, 8))
	_tag.add_theme_stylebox_override(&"panel", _tag_style)
	_tag.rotation = deg_to_rad(-3.0)
	_tag_label = Label.new()
	_tag_label.add_theme_font_override(&"font", DialogueBox.pixel_font())
	_tag_label.add_theme_font_size_override(&"font_size", DialogueBox.FONT_SIZE)
	_tag_label.add_theme_color_override(&"font_color", Color(0.12, 0.08, 0.05))
	_tag.add_child(_tag_label)
	_stage.add_child(_tag)

	var bar := HBoxContainer.new()
	add_child(bar)
	_button(bar, "PagePrevious", "Previous page", func(): _show_page(_page - 1))
	_page_label = Label.new()
	bar.add_child(_page_label)
	_button(bar, "PageNext", "Next page", func(): _show_page(_page + 1))
	_button(bar, "Play", "Type it out with the speaker's voice", _play)
	_voice = AudioStreamPlayer.new()
	add_child(_voice)


func _ready() -> void:
	set_process(false)


func _button(bar: Control, icon: StringName, tip: String, action: Callable) -> void:
	var b := Button.new()
	b.flat = true
	b.tooltip_text = tip
	b.icon = EditorInterface.get_editor_theme().get_icon(icon, &"EditorIcons")
	b.pressed.connect(action)
	bar.add_child(b)


static func _rich() -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.add_theme_font_override(&"normal_font", DialogueBox.pixel_font())
	r.add_theme_font_size_override(&"normal_font_size", DialogueBox.FONT_SIZE)
	r.add_theme_color_override(&"default_color", DialogueBox.TEXT_COLOR)
	r.add_theme_constant_override(&"line_separation", 6)
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	r.add_theme_stylebox_override(&"normal", StyleBoxEmpty.new())  # the editor theme's frame
	return r


func show_line(line: DialogueLine) -> void:
	_line = line
	_typing = -1.0
	set_process(false)
	_pages = DialogueText.pages(line.text, gs) if line else []
	var who: CharacterDef = gs.story.find_character(line.speaker) if line and gs and gs.story and line.speaker != &"" else null
	var narration := line != null and line.style == DialogueLine.Style.NARRATION
	_shade.visible = narration
	_box.self_modulate.a = 0.0 if narration else 1.0
	_tag.visible = who != null and not line.hide_name and not narration
	if _tag.visible:
		_tag_label.text = who.get_display_name()
		_tag_style.bg_color = who.name_color
		_tag.reset_size()
		_tag.position = Vector2(34, -_tag.size.y * 0.62)
	_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if narration else HORIZONTAL_ALIGNMENT_LEFT
	_show_page(0)


func _show_page(i: int) -> void:
	_page = clampi(i, 0, maxi(_pages.size() - 1, 0))
	_text.text = _pages[_page].bbcode if not _pages.is_empty() else ""
	_text.visible_characters = -1
	var over := overflowing_pages(_line.text, gs, _line.style) if _line else PackedInt32Array()
	_page_label.text = "Page %d / %d%s" % [_page + 1, maxi(_pages.size(), 1), "  (too long!)" if over.has(_page) else ""]
	_page_label.modulate = Color(1, 0.5, 0.4) if over.has(_page) else Color.WHITE


func _play() -> void:
	if _pages.is_empty():
		return
	_typing = 0.0
	_text.visible_characters = 0
	set_process(true)


func _process(delta: float) -> void:
	if _typing < 0.0 or _pages.is_empty():
		set_process(false)
		return
	var who: CharacterDef = gs.story.find_character(_line.speaker) if _line and gs.story and _line.speaker != &"" else null
	var plain: String = _pages[_page].plain
	var before := int(_typing)
	_typing += delta * DialogueBox.TYPE_SPEED * (who.talk_speed if who else 1.0)
	_since_blip += delta
	var now := mini(int(_typing), plain.length())
	if now > before and who and not who.silent and _since_blip >= DialogueBox.MIN_BLIP_GAP:
		var wav := VoiceSynth.blip(who, plain[now - 1])
		if wav:
			_voice.stream = wav
			_voice.volume_db = who.voice_volume
			_voice.play()
			_since_blip = 0.0
	_text.visible_characters = now
	if now >= plain.length():
		set_process(false)


## Pages (0-based) whose text doesn't fit the box (wrapped with the box's font and width).
static func overflowing_pages(text: String, gs: Node, style := DialogueLine.Style.BOX) -> PackedInt32Array:
	var out := PackedInt32Array()
	var font := DialogueBox.pixel_font()
	var area := DialogueBox.BOX_SIZE - Vector2(DialogueBox.BOX_MARGIN.x + DialogueBox.BOX_MARGIN.z, DialogueBox.BOX_MARGIN.y + DialogueBox.BOX_MARGIN.w)
	if style == DialogueLine.Style.NARRATION:
		area = Vector2(1240, 480)
	var sep := 6.0
	var line_h := font.get_height(DialogueBox.FONT_SIZE) + sep
	var max_lines := floori((area.y + sep) / line_h)
	var pages := DialogueText.pages(text, gs)
	for i in pages.size():
		var para := TextParagraph.new()
		para.width = area.x
		para.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
		para.add_string(pages[i].plain, font, DialogueBox.FONT_SIZE)
		if para.get_line_count() > max_lines:
			out.append(i)
	return out
