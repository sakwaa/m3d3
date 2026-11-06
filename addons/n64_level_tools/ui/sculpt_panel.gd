@tool
extends PanelContainer
## Sculpt-mode flyout: terrain tool, brush radius / strength / falloff, target height and
## height snapping. Pure UI: emits signals, the plugin applies them.

signal tool_selected(tool: int)
signal setting_changed(property: StringName, value: Variant)

var _scale := 1.0
var _updating := false
var _body: VBoxContainer
var _tool_buttons: Array[Button] = []
var _radius: HSlider
var _strength: HSlider
var _falloff: OptionButton
var _height_row: Control
var _height: SpinBox
var _snap: CheckBox
var _snap_step: SpinBox


func _init(panel_style: StyleBox = null) -> void:
	_scale = EditorInterface.get_editor_scale()
	mouse_filter = MOUSE_FILTER_STOP
	size_flags_vertical = SIZE_SHRINK_BEGIN
	if panel_style:
		add_theme_stylebox_override(&"panel", panel_style)
	custom_minimum_size.x = 230 * _scale
	_body = VBoxContainer.new()
	add_child(_body)

	_heading("Sculpt terrain")
	var tools := GridContainer.new()
	tools.columns = 2
	_body.add_child(tools)
	var group := ButtonGroup.new()
	for i in LevelSculptTool.TOOL_NAMES.size():
		var b := Button.new()
		b.text = LevelSculptTool.TOOL_NAMES[i]
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		b.pressed.connect(func(): tool_selected.emit(i); _height_row.visible = i == LevelSculptTool.Tool.HEIGHT)
		tools.add_child(b)
		_tool_buttons.append(b)

	_radius = _slider("Radius (m)", 0.25, 16.0, 0.25)
	_radius.value_changed.connect(func(v): _emit(&"radius", v))
	_strength = _slider("Strength", 0.01, 1.0, 0.01)
	_strength.tooltip_text = "Raise / Lower: metres per dab at the centre.\nSmooth / Flatten / Height: how far towards the target per dab."
	_strength.value_changed.connect(func(v): _emit(&"strength", v))
	_falloff = OptionButton.new()
	for n in LevelSculptTool.FALLOFF_NAMES:
		_falloff.add_item(n)
	_falloff.tooltip_text = "How the effect fades towards the edge:\nSmooth = dome, Linear = cone, Sharp = peak, Constant = plateau"
	_falloff.item_selected.connect(func(i): _emit(&"falloff", i))
	_row("Falloff", _falloff)

	_height = SpinBox.new()
	_height.min_value = -100.0
	_height.max_value = 100.0
	_height.step = 0.05
	_height.suffix = "m"
	_height.tooltip_text = "World height the vertices move to.\n%s+click the terrain to pick a height." % ("Cmd" if OS.get_name() == "macOS" else "Ctrl")
	_height.value_changed.connect(func(v): _emit(&"height", v))
	_height_row = _row("Height", _height)
	_height_row.visible = false

	_snap = CheckBox.new()
	_snap.text = "Snap heights"
	_snap.tooltip_text = "Round touched heights to the step when a stroke ends\n(N64-style terraces instead of smooth slopes)."
	_snap.toggled.connect(func(on): _emit(&"snap_heights", on))
	_body.add_child(_snap)
	_snap_step = SpinBox.new()
	_snap_step.min_value = 0.05
	_snap_step.max_value = 4.0
	_snap_step.step = 0.05
	_snap_step.suffix = "m"
	_snap_step.value_changed.connect(func(v): _emit(&"snap_step", v))
	_row("Step", _snap_step)

	var hint := Label.new()
	hint.text = "Drag to sculpt floors (Grid / Plane brushes).\nShift: Raise ⇄ Lower · [ ]: radius\n%s+click: pick height" % ("Cmd" if OS.get_name() == "macOS" else "Ctrl")
	hint.add_theme_font_size_override(&"font_size", int(11 * _scale))
	hint.modulate = Color(1, 1, 1, 0.6)
	_body.add_child(hint)


func set_tool_state(t: LevelSculptTool) -> void:
	_updating = true
	_tool_buttons[t.tool].button_pressed = true
	_height_row.visible = t.tool == LevelSculptTool.Tool.HEIGHT
	_radius.value = t.radius
	_strength.value = t.strength
	_falloff.select(t.falloff)
	_height.value = t.height
	_snap.button_pressed = t.snap_heights
	_snap_step.value = t.snap_step
	_updating = false


func _emit(property: StringName, value: Variant) -> void:
	if not _updating:
		setting_changed.emit(property, value)


func _heading(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override(&"font_color", Color(0.55, 0.9, 0.55))
	_body.add_child(l)


func _row(label: String, control: Control) -> Control:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 80 * _scale
	l.add_theme_font_size_override(&"font_size", int(12 * _scale))
	row.add_child(l)
	control.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(control)
	_body.add_child(row)
	return row


func _slider(label: String, lo: float, hi: float, step: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.size_flags_vertical = SIZE_SHRINK_CENTER
	var value := Label.new()
	value.custom_minimum_size.x = 34 * _scale
	value.add_theme_font_size_override(&"font_size", int(11 * _scale))
	s.value_changed.connect(func(v): value.text = str(snappedf(v, step)))
	var box := HBoxContainer.new()
	s.size_flags_horizontal = SIZE_EXPAND_FILL
	box.add_child(s)
	box.add_child(value)
	_row(label, box)
	return s
