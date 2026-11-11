@tool
extends EditorInspectorPlugin
## Texture slots on our game resources (door / passage dressing, stair textures) use the
## N64 texture picker (imported library by folder, search, FileSystem drops) instead of
## Godot's generic resource picker. Passage brushes' floor / wall textures (indices into the
## level's palette) get the same picker, also shown on the brush itself above its Passage
## settings: the chosen texture joins the palette if missing.


func _can_handle(object: Object) -> bool:
	return object is OpeningDressing or object is N64StairTexture or object is Door or object is FenceStyle or object is OpeningSpec \
		or object is StrokeAlphabet or object is SyllabaryAlphabet \
		or (object is LevelBrush and (object.is_passage() or object.is_door()))


const FenceTextureGenerator := preload("res://addons/n64_level_tools/textures/fence_texture_generator.gd")


## Fence styles: a button that draws their cutout textures from the Generate inputs.
## Stroke alphabets: a chart of every mark, redrawn as they're edited.
func _parse_begin(object: Object) -> void:
	if object is StrokeAlphabet:
		add_custom_control(StrokeChart.new(object))
		return
	if object is SyllabaryAlphabet:
		add_custom_control(SyllabaryTools.new(object))
		return
	if not object is FenceStyle:
		return
	var button := Button.new()
	button.text = "Generate fence textures"
	button.tooltip_text = "Draws the panel (for the chosen Kind), post, end cap and arch textures from the\nGenerate group's materials, saves them next to this style and assigns them.\nFences using the style update. Generate again after changing the inputs."
	button.pressed.connect(func():
		var err := FenceTextureGenerator.generate(object)
		if err != "":
			push_warning("N64 Level Tools: " + err)
		else:
			print("[N64 Level Tools] Fence textures generated next to %s." % object.resource_path))
	add_custom_control(button)


func _parse_property(_object: Object, type: Variant.Type, name: String, _hint_type: PropertyHint,
		hint_string: String, usage_flags: int, _wide: bool) -> bool:
	if type == TYPE_OBJECT and hint_string == "Texture2D" and usage_flags & PROPERTY_USAGE_EDITOR:
		add_property_editor(name, TextureProperty.new())
		return true
	if _object is OpeningSpec and name in ["floor_texture", "wall_texture"]:
		add_property_editor(name, PaletteTextureProperty.new())
		return true
	if _object is LevelBrush and name in ["passage", "door"]:
		# Shown right above the Passage settings (the corridor's textures).
		for prop in ["floor_texture", "wall_texture"]:
			var row := PaletteTextureProperty.new()
			row.spec = _object.opening_spec()
			row.spec_property = prop
			row.label = "Floor" if prop == "floor_texture" else "Walls"
			row.tooltip_text = "%s %s texture (its own; the room around it is painted as usual)" % [
				"Door lining" if _object.is_door() else "Passage", row.label.to_lower()]
			add_custom_control(row)
		return false
	return false


class TextureProperty extends EditorProperty:
	var _picker := N64TexturePicker.new()
	var _updating := false

	func _init() -> void:
		add_child(_picker)
		add_focusable(_picker)
		_picker.resource_changed.connect(func(r):
			if not _updating:
				emit_changed(get_edited_property(), r))

	func _update_property() -> void:
		_updating = true
		_picker.edited_resource = get_edited_object().get(get_edited_property()) as Texture2D
		_updating = false


## Palette index (-1 = none) edited as a texture: picking one adds it to the level's palette
## (one undo step). Edits the inspected passage / door spec's property, or `spec_property` of `spec`
## when shown on its brush.
class PaletteTextureProperty extends EditorProperty:
	var spec: OpeningSpec
	var spec_property := ""
	var _picker := N64TexturePicker.new()
	var _updating := false

	func _init() -> void:
		add_child(_picker)
		add_focusable(_picker)
		_picker.resource_changed.connect(_on_picked)

	func _ready() -> void:
		if spec:
			spec.changed.connect(_update_property)
			_update_property()

	func _target() -> OpeningSpec:
		return spec if spec else get_edited_object() as OpeningSpec

	func _property() -> String:
		return spec_property if spec else String(get_edited_property())

	func _on_picked(tex: Texture2D) -> void:
		if _updating:
			return
		var target := _target()
		var data := level_of(target)
		if data == null and tex != null:
			push_warning("N64 Level Tools: open the scene with this passage's / door's level to pick its textures.")
			_update_property()
			return
		var prop := _property()
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action("Set Passage " + prop.capitalize(), UndoRedo.MERGE_DISABLE, target)
		var index := -1
		if tex:
			index = data.texture_id(tex)
			if index < 0:
				var list := data.with_texture(tex)
				index = list.size() - 1
				ur.add_do_property(data, &"textures", list)
				ur.add_undo_property(data, &"textures", data.textures)
		ur.add_do_property(target, prop, index)
		ur.add_undo_property(target, prop, target.get(prop))
		ur.commit_action()
		_update_property()

	func _update_property() -> void:
		var target := _target()
		if target == null:
			return
		_updating = true
		var i: int = target.get(_property())
		var data := level_of(target)
		_picker.edited_resource = data.textures[i] if data and i >= 0 and i < data.textures.size() else null
		_updating = false

	## The level whose brush owns `spec` (in the edited scene), or null.
	static func level_of(target: OpeningSpec) -> LevelData:
		var scene := EditorInterface.get_edited_scene_root()
		if scene == null or target == null:
			return null
		var roots: Array[Node] = [scene]
		roots.append_array(scene.find_children("*", "", true, false))
		for r in roots:
			if r is LevelRoot and r.data:
				for b: LevelBrush in r.data.brushes:
					if b and b.opening_spec() == target:
						return r.data
		return null


## Every consonant's stroke (voiced ones with their tick) and every vowel beside a t, with
## the sound's name and an example word; redrawn when the alphabet changes.
class StrokeChart extends VBoxContainer:
	const EXAMPLES := {"P": "pin", "B": "bin", "T": "tin", "D": "din", "K": "kin", "G": "go", "F": "fan", "V": "van",
		"TH": "thin", "DH": "this", "S": "sip", "Z": "zip", "SH": "shop", "ZH": "vision", "CH": "chin", "JH": "jam",
		"HH": "hat", "M": "map", "N": "nap", "NG": "sing", "L": "lip", "R": "rip", "W": "win", "Y": "yes", "IY": "see",
		"IH": "sit", "EY": "say", "EH": "set", "AE": "sat", "AH": "cup", "ER": "bird", "UW": "too", "UH": "book",
		"OW": "go", "AO": "saw", "AA": "hot", "AY": "my", "AW": "now", "OY": "boy"}
	var alphabet: StrokeAlphabet
	var grid := GridContainer.new()

	func _init(a: StrokeAlphabet) -> void:
		alphabet = a
		grid.columns = 6
		add_child(grid)
		alphabet.changed.connect(_redraw)
		_redraw()

	func _exit_tree() -> void:
		if alphabet.changed.is_connected(_redraw):
			alphabet.changed.disconnect(_redraw)

	func _redraw() -> void:
		for c in grid.get_children():
			c.queue_free()
		var sounds: Array = alphabet.strokes.keys() + alphabet.voiced.keys()
		for s in sounds:
			_add(alphabet.outline(PackedStringArray([s]), 0, 14.0), s)
		for v in alphabet.vowels:
			_add(alphabet.outline(PackedStringArray(["T", v]), 0, 14.0), "t+" + v)

	func _add(img: Image, name: String) -> void:
		var out := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
		out.fill(Color(0.93, 0.91, 0.85))
		for y in img.get_height():
			for x in img.get_width():
				out.set_pixel(x, y, out.get_pixel(x, y).lerp(Color(0.12, 0.1, 0.1), img.get_pixel(x, y).a))
		out.resize(out.get_width() * 2, out.get_height() * 2, Image.INTERPOLATE_NEAREST)
		var box := VBoxContainer.new()
		var t := TextureRect.new()
		t.texture = ImageTexture.create_from_image(out)
		t.stretch_mode = TextureRect.STRETCH_KEEP
		box.add_child(t)
		var l := Label.new()
		l.text = "%s\n%s" % [name.to_lower(), EXAMPLES.get(name.trim_prefix("t+"), "")]
		l.add_theme_font_size_override(&"font_size", 11)
		box.add_child(l)
		grid.add_child(box)


## Syllabary alphabets: make the template to draw on, and preview text written with it.
class SyllabaryTools extends VBoxContainer:
	const Template := preload("res://addons/n64_level_tools/glyphs/syllabary_template.gd")
	const GlyphText := preload("res://addons/n64_level_tools/glyphs/glyph_text.gd")
	var alphabet: SyllabaryAlphabet
	var sample := LineEdit.new()
	var preview := TextureRect.new()
	var note := Label.new()

	func _init(a: SyllabaryAlphabet) -> void:
		alphabet = a
		var make := Button.new()
		make.text = "Make template"
		make.tooltip_text = "Draws a blank template PNG next to this alphabet (template.png, or template_blank.png\nwhen one is there already, so a drawn one is never overwritten) and uses it if none is set."
		make.pressed.connect(_make)
		add_child(make)
		sample.text = "Welcome to the potion shop!"
		sample.text_changed.connect(func(_t): _redraw())
		add_child(sample)
		preview.stretch_mode = TextureRect.STRETCH_KEEP
		add_child(preview)
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_font_size_override(&"font_size", 11)
		add_child(note)
		alphabet.changed.connect(_redraw)
		_redraw.call_deferred()

	func _exit_tree() -> void:
		if alphabet.changed.is_connected(_redraw):
			alphabet.changed.disconnect(_redraw)

	func _make() -> void:
		var dir := alphabet.resource_path.get_base_dir() if alphabet.resource_path != "" else "res://glyphs/syllabary"
		DirAccess.make_dir_recursive_absolute(dir)
		var path := dir.path_join("template.png")
		if FileAccess.file_exists(path):
			path = dir.path_join("template_blank.png")
		var err: Error = await Template.make(path, EditorInterface.get_base_control())
		if err != OK:
			push_warning("N64 Level Tools: couldn't save the template (%s)." % error_string(err))
			return
		EditorInterface.get_resource_filesystem().scan()
		print("[N64 Level Tools] Syllabary template saved: %s" % path)
		if alphabet.template == null and path.ends_with("template.png"):
			await EditorInterface.get_resource_filesystem().filesystem_changed
			alphabet.template = load(path)

	func _redraw() -> void:
		# Every word with a symbol drawn is written with it here.
		var enc := GlyphText.checked(sample.text, alphabet.drawn_symbols() if alphabet is SyllabaryAlphabet else PackedStringArray())
		var img := Image.create(240, 120, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.93, 0.91, 0.85))
		var r: Dictionary = alphabet.draw(img, enc.items, Rect2i(4, 4, 232, 112), Color(0.12, 0.1, 0.1))
		img.resize(480, 240, Image.INTERPOLATE_NEAREST)
		preview.texture = ImageTexture.create_from_image(img)
		var lines := []
		if not r.missing.is_empty():
			lines.append("Not drawn yet: " + ", ".join(r.missing.slice(0, 12)) + (" …" if r.missing.size() > 12 else ""))
		lines.append_array(enc.errors)
		note.text = "\n".join(lines)
