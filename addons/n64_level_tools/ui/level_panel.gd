@tool
extends HBoxContainer
## Floating two-column tool strip (photo-editor style) shown inside the 3D viewport,
## with an optional flyout for bake details and hints. Pure UI: emits signals, the
## plugin acts. Collapsed state, flyout sections and position persist per project.

signal shape_selected(shape: int)
signal mode_selected(mode: int)
signal snap_changed(value: float)
signal action_requested(action: StringName)
signal debug_view_toggled(enabled: bool)
signal preview_baked_toggled(enabled: bool)
signal ao_view_toggled(enabled: bool)
signal anim_view_toggled(enabled: bool)
signal reference_toggled(enabled: bool)
signal sticky_grid_toggled(enabled: bool)
signal refresh_requested
signal door_option_changed(property: StringName, value: Variant)

const ICON_DIR := "res://addons/n64_level_tools/icons/"
const SETTINGS_SECTION := "n64_level_tools_panel"
const SHAPE_ICONS := ["block", "wall", "plane", "grid", "ramp", "stairs", "cylinder", "pyramid"]
const MODES := [
	["mode_object", "Object mode\nSelect, move, resize brushes"],
	["mode_vertex", "Vertex mode"],
	["mode_edge", "Edge mode"],
	["mode_face", "Face mode"],
	["mode_paint", "Paint mode\nPaint textures onto faces"],
	["mode_sculpt", "Sculpt mode\nRaise / lower / smooth / flatten floors with a falloff brush"],
]
const SNAP_PRESETS := [0.05, 0.1, 0.25, 0.5, 1.0, 2.0]

const CELL := 30
const BG := Color(0.07, 0.075, 0.08, 0.96)
const RULE := Color(1, 1, 1, 0.07)
const TEXT := Color(0.82, 0.86, 0.82)
const ICON := Color(0.4, 0.82, 0.42)
const ICON_HOVER := Color(0.6, 1.0, 0.6)
const ICON_ACTIVE := Color(0.82, 1.0, 0.8)
const BUTTON_HOVER := Color(1, 1, 1, 0.07)
const BUTTON_ACTIVE := Color(0.3, 0.75, 0.32, 0.3)

var _scale := 1.0
var _box_empty: StyleBoxEmpty
var _box_hover: StyleBoxFlat
var _box_active: StyleBoxFlat

var _toolbar: PanelContainer
var _tools: VBoxContainer
var _collapse_button: Button
var _shape_buttons: Array[Button] = []
var _mode_buttons: Array[Button] = []
var _mode := 0
var _placing := false
var _brush_ops: Control
var _geometry_ops: Control
var _snap_button: Button
var _props_button: Button
var _props_popup: PopupPanel
var _snap_popup: PopupPanel
var _snap_spin: SpinBox
var _debug_button: Button
var _sticky_button: Button
var _preview_button: Button
var _status_bar: ColorRect
var _details_toggle: Button
var _hint_toggle: Button

## Paint-mode flyout (layers, tools, brush settings).
var paint_panel: PanelContainer
var sculpt_panel: PanelContainer
var door_panel: PanelContainer
var _door_mode: OptionButton
var _door_depth: SpinBox
var _door_hint: Label
var _door_front: SpinBox
var _door_back: SpinBox
var _door_room: CheckBox
var _flyout: PanelContainer
var _summary: Label
var _details: VBoxContainer
var _details_label: Label
var _data_label: Label
var _hint: Label
var _dragging := false


func _init() -> void:
	name = "N64LevelTools"
	# Only the panels themselves take clicks; gaps fall through to the viewport.
	mouse_filter = MOUSE_FILTER_IGNORE
	_scale = EditorInterface.get_editor_scale()
	add_theme_constant_override(&"separation", int(4 * _scale))
	minimum_size_changed.connect(reset_size)
	_box_empty = StyleBoxEmpty.new()
	_box_hover = _rounded(BUTTON_HOVER, 4)
	_box_active = _rounded(BUTTON_ACTIVE, 4)

	_toolbar = _panel()
	_toolbar.size_flags_vertical = SIZE_SHRINK_BEGIN
	add_child(_toolbar)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", int(2 * _scale))
	_toolbar.add_child(column)

	# Header: drag grip + collapse.
	var header := _grid(column)
	var grip := TextureRect.new()
	grip.texture = _editor_icon(&"TripleBar")
	grip.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	grip.custom_minimum_size = Vector2(CELL, CELL) * _scale
	grip.modulate = Color(ICON, 0.6)
	grip.mouse_default_cursor_shape = CURSOR_MOVE
	grip.tooltip_text = "Drag to move"
	grip.gui_input.connect(_on_grip_input)
	header.add_child(grip)
	_collapse_button = _button(null, "Collapse / expand")
	_collapse_button.pressed.connect(func(): _set_setting(&"collapsed", _tools.visible); _apply_sections())
	header.add_child(_collapse_button)

	_tools = VBoxContainer.new()
	_tools.add_theme_constant_override(&"separation", int(2 * _scale))
	column.add_child(_tools)

	# Shapes.
	_rule()
	var shapes := _grid(_tools)
	var shape_group := ButtonGroup.new()
	shape_group.allow_unpress = true
	for i in SHAPE_ICONS.size():
		var b := _button(_svg(SHAPE_ICONS[i]), "%s\nClick, then click in the viewport.\nShift keeps placing, Esc cancels." % BrushShapes.NAMES[i], true)
		b.button_group = shape_group
		b.toggled.connect(_on_shape_toggled.bind(i))
		shapes.add_child(b)
		_shape_buttons.append(b)
	var passage := _button(_svg("passage"), "Passage\nOoT-style corridor out of the zone: floor extends outward,\nfades to black, loads another zone. Click a wall or floor.", true)
	passage.button_group = shape_group
	passage.toggled.connect(_on_shape_toggled.bind(SHAPE_ICONS.size()))
	shapes.add_child(passage)
	_shape_buttons.append(passage)
	var door := _button(_svg("door"), "Door\nOoT-style door between two rooms, or to another zone.\nClick a wall (cut the opening yourself).", true)
	door.button_group = shape_group
	door.toggled.connect(_on_shape_toggled.bind(SHAPE_ICONS.size() + 1))
	shapes.add_child(door)
	_shape_buttons.append(door)
	_props_button = _button(_svg("props"), "Props: signs, ropes, fences and other things to place", false, "P")
	_props_button.pressed.connect(_open_props_popup)
	shapes.add_child(_props_button)
	_build_props_popup()

	# Modes + contextual operations.
	_rule()
	var modes := _grid(_tools)
	var mode_group := ButtonGroup.new()
	for i in MODES.size():
		var b := _button(_svg(MODES[i][0]), MODES[i][1], true)
		b.button_group = mode_group
		b.pressed.connect(func(): mode_selected.emit(i))
		modes.add_child(b)
		_mode_buttons.append(b)
	_mode_buttons[0].button_pressed = true
	_brush_ops = _action_grid([
		[_editor_icon(&"RotateLeft"), "Rotate -90° (Shift+R)", &"rotate_ccw", "⟲"],
		[_editor_icon(&"RotateRight"), "Rotate +90° (R; also while placing a brush)", &"rotate_cw", "⟳"],
		[_editor_icon(&"Duplicate"), "Duplicate (%s+D)" % ("Cmd" if OS.get_name() == "macOS" else "Ctrl"), &"duplicate", "D"],
		[_editor_icon(&"Remove"), "Delete brushes (Delete)", &"delete_brushes", "X"],
		[_editor_icon(&"ToolMove"), "Move by exact X / Y / Z…\n(or arrow keys / PgUp / PgDn, Shift x10)", &"move_dialog", "M"],
		[_svg("grid_resize"), "Grid resize… (cells keep their size, walls move with the border)\nor Alt+drag a resize square", &"grid_resize", "G"],
		[_svg("retopo"), "Retopo: rebuild the selected brushes as clean grids sized to the snap\n(cells fit the geometry, not world snap; heights resampled)", &"retopo", "R"],
		[_svg("cleanup"), "Clean up: merge matching flat faces (removes strips left by cuts), then\ncut them back into a grid on world lines one snap apart, for vertex lighting.\nPaint is kept; bake lighting / AO again afterwards", &"cleanup", "C"],
		[_editor_icon(&"ExternalLink"), "Edit in Blender: a set piece's .blend opens in Blender;\nother brushes move into a new one (a set piece: shaped in Blender,\nplaced and painted here). Saving in Blender updates it here.", &"blender", "Bl"],
		[_editor_icon(&"Unlinked"), "Unlink from Blender: the selected set piece brushes go back\nto the brush tools (the .blend stays)", &"blender_unlink", "U"],
	])
	_geometry_ops = _action_grid([
		[_svg("extrude"), "Extrude one snap step (E)\n(or %s+drag a gizmo arrow)" % ("Cmd" if OS.get_name() == "macOS" else "Ctrl") + "\nVertex mode: selected border vertices grow walls\nShift+E: border grows outwards on every side (a floor gets bigger)", &"extrude", "E"],
		[_svg("make_face"), "Make face from selected vertices / edges (F)", &"make_face", "F"],
		[_svg("flip"), "Flip faces", &"flip", "F"],
		[_editor_icon(&"Remove"), "Delete faces (Delete)", &"delete_faces", "X"],
		[_svg("subdivide"), "Subdivide selected faces (Face mode)\ninto quads; press again for finer", &"subdivide", "S"],
		[_svg("retopo"), "Retopo selected faces: a clean grid sized to the snap\n(cells fit the selection, not world snap; heights resampled,\nneighbours stitched)", &"retopo", "R"],
		[_svg("cleanup"), "Clean up selected faces: merge matching flat faces, then a grid\non world lines one snap apart (paint kept; bake lighting / AO again)", &"cleanup", "C"],
		[_svg("ramp"), "Ramp (R): even slope between two rows. Raise the top row to its\nheight, then select the top, the foot row and everything between (vertices\nor faces): the top stays, the low row farthest from it stays, the rest slope evenly", &"ramp", "/"],
		[_editor_icon(&"ToolMove"), "Move by exact X / Y / Z…\n(or arrow keys / PgUp / PgDn, Shift x10)", &"move_dialog", "M"],
	])
	_geometry_ops.visible = false

	# Snap + view.
	_rule()
	_snap_button = _button(null, "Snap size (also the debug checker size)\nClick to change")
	_snap_button.custom_minimum_size = Vector2(CELL * 2, CELL * 0.8) * _scale
	_snap_button.add_theme_font_size_override(&"font_size", int(12 * _scale))
	_snap_button.pressed.connect(_open_snap_popup)
	_tools.add_child(_snap_button)
	_build_snap_popup()
	var view := _grid(_tools)
	var snap_sel := _button(_editor_icon(&"Snap"), "Snap selection to grid", false, "S")
	snap_sel.pressed.connect(func(): action_requested.emit(&"snap_selection"))
	view.add_child(snap_sel)
	_debug_button = _button(_editor_icon(&"Grid"), "Debug grid texture", true, "#")
	_debug_button.toggled.connect(func(on): debug_view_toggled.emit(on))
	view.add_child(_debug_button)
	var ao := _button(_editor_icon(&"VoxelGI"), "Show baked vertex AO (editor only; the game always shows it).\nTurn off to paint without it.", true, "AO")
	ao.button_pressed = true
	ao.toggled.connect(func(on): ao_view_toggled.emit(on))
	view.add_child(ao)
	var anim := _button(_editor_icon(&"Play"), "Play animated textures (scrolling water, flipbooks) in the editor.\nTurn off to paint on still textures; the game always plays them.", true, "Anim")
	anim.button_pressed = true
	anim.toggled.connect(func(on): anim_view_toggled.emit(on))
	view.add_child(anim)
	var ref := _button(_editor_icon(&"CharacterBody3D"), "Reference character (player size, eye and jump height)\nAlt+click a surface to move it", true, "R")
	ref.toggled.connect(func(on): reference_toggled.emit(on))
	view.add_child(ref)
	_sticky_button = _button(_svg("grid"), "Sticky grid (G): a grid across the whole level, spaced at the snap size and at the height\nof the surface under the cursor when turned on; changing the snap afterwards leaves it as is\n(Shift+G: take the current snap and height). ] / [ (or Alt+PgUp / PgDn): up / down one cell.\nBuildings hide it. For laying out greyboxes. Editor only.", true, "G")
	_sticky_button.toggled.connect(func(on): sticky_grid_toggled.emit(on))
	view.add_child(_sticky_button)

	# Bake + status bar.
	_rule()
	var bake_grid := _grid(_tools)
	var bake := _button(_editor_icon(&"Bake"), "Bake all levels (non-destructive, undoable)", false, "B")
	bake.pressed.connect(func(): action_requested.emit(&"bake"))
	bake_grid.add_child(bake)
	_preview_button = _button(_editor_icon(&"GuiVisibilityVisible"), "Preview baked result", true, "P")
	_preview_button.toggled.connect(func(on): preview_baked_toggled.emit(on))
	bake_grid.add_child(_preview_button)
	var play := _button(_editor_icon(&"PlayScene"), "Quick Play: bake, save and run this zone as you see it\nstarting on the reference character, or where the view is centred", false, "▶")
	play.pressed.connect(func(): action_requested.emit(&"play_here"))
	bake_grid.add_child(play)
	var build_play := _button(_editor_icon(&"PlayStart"), "Build & Play: bake as the export does (hidden faces culled, Blender's limited\ndissolve merging flat faces, relit, simplified inside each chunk), save and run from the\nsame spot. Slower (the market: ~11 s); your brushes aren't changed (the next Bake\nreplaces the build's bake)", false, "▶▶")
	build_play.pressed.connect(func(): action_requested.emit(&"build_play"))
	bake_grid.add_child(build_play)
	var report := _button(_editor_icon(&"Search"), "Build report: build this zone as the export does and write what it ships\n(triangles, chunks, worst camera views, heaviest brushes, problems) to\nbuild_reports/ as summary.md + report.json (for an agent to check). Bakes aren't changed", false, "R")
	report.pressed.connect(func(): action_requested.emit(&"build_report"))
	bake_grid.add_child(report)
	var ao_bake := _button(_editor_icon(&"VoxelGI"), "Bake AO only: darkens corners and creases into the vertex AO channel.\nKeeps real-time lighting (Dynamic). Settings: Paint panel > Vertex colour.", false, "AO")
	ao_bake.pressed.connect(func(): action_requested.emit(&"bake_vertex_ao"))
	bake_grid.add_child(ao_bake)
	var light := _button(_editor_icon(&"DirectionalLight3D"), "Bake LIGHTING (N64 style): bakes the scene's lights, sky/ground ambient and AO\ninto the vertices and REPLACES real-time lighting (switches the level to Baked Vertex).\nFor corner darkening with real-time lights, use Bake AO instead.", false, "L")
	light.pressed.connect(func(): action_requested.emit(&"bake_lighting"))
	bake_grid.add_child(light)
	_status_bar = ColorRect.new()
	_status_bar.custom_minimum_size = Vector2(CELL * 2, 3) * _scale
	_status_bar.mouse_filter = MOUSE_FILTER_STOP
	_tools.add_child(_status_bar)

	# Flyout toggles.
	_rule()
	var toggles := _grid(_tools)
	_details_toggle = _button(_editor_icon(&"NodeInfo"), "Show bake details", true, "i")
	_details_toggle.toggled.connect(func(on): _set_setting(&"details", on); _apply_sections())
	toggles.add_child(_details_toggle)
	_hint_toggle = _button(_editor_icon(&"Help"), "Show hints", true, "?")
	_hint_toggle.toggled.connect(func(on): _set_setting(&"hint", on); _apply_sections())
	toggles.add_child(_hint_toggle)

	_build_flyout()
	paint_panel = preload("res://addons/n64_level_tools/ui/paint_panel.gd").new(_panel_style(), _button)
	paint_panel.visible = false
	add_child(paint_panel)
	sculpt_panel = preload("res://addons/n64_level_tools/ui/sculpt_panel.gd").new(_panel_style())
	sculpt_panel.visible = false
	add_child(sculpt_panel)
	_build_door_panel()

	var timer := Timer.new()
	timer.wait_time = 0.5
	timer.autostart = true
	timer.timeout.connect(func(): refresh_requested.emit())
	add_child(timer)

	_apply_sections()


func setup(snap: float, debug_view: bool, default_position: Vector2) -> void:
	_snap_spin.set_value_no_signal(snap)
	_update_snap_label(snap)
	_debug_button.set_pressed_no_signal(debug_view)
	position = _get_setting(&"position", default_position)


## One active tool at a time: while a shape / passage / door is being placed, no mode
## button is lit; when placing ends, the current mode's button lights again.
func set_place_shape(shape: int) -> void:
	_placing = shape >= 0
	door_panel.visible = shape == SHAPE_ICONS.size() + 1
	for i in _shape_buttons.size():
		_shape_buttons[i].set_pressed_no_signal(i == shape)
	for i in _mode_buttons.size():
		_mode_buttons[i].set_pressed_no_signal(not _placing and i == _mode)


## Door tool options: recess depth in front of / behind the door, and whether to start the
## next room (opposing wall + floor) when nothing is behind the wall yet.
func _build_door_panel() -> void:
	door_panel = PanelContainer.new()
	door_panel.add_theme_stylebox_override(&"panel", _panel_style())
	door_panel.size_flags_vertical = SIZE_SHRINK_BEGIN
	door_panel.mouse_filter = MOUSE_FILTER_STOP
	door_panel.visible = false
	add_child(door_panel)
	var box := VBoxContainer.new()
	door_panel.add_child(box)
	var title := Label.new()
	title.text = "Door"
	title.add_theme_color_override(&"font_color", Color(0.55, 0.9, 0.55))
	box.add_child(title)
	_door_mode = OptionButton.new()
	_door_mode.add_item("Recess (carve the wall)")
	_door_mode.add_item("Between faces")
	_door_mode.tooltip_text = "Recess: cuts the opening and lines a tunnel from the clicked face.\nBetween faces: the door stands between a wall's two faces (like a\nBlender set piece's), cutting both and lining the gap when solid."
	_door_mode.add_theme_font_size_override(&"font_size", int(12 * _scale))
	_door_mode.item_selected.connect(func(i): _show_door_mode(i); door_option_changed.emit(&"door_mode", i))
	box.add_child(_door_mode)
	_door_depth = _door_spin(box, "Depth", "Where the door stands in the wall: 0% on the face you click\n(outside), 50% in the middle, 100% on the face behind it.")
	_door_depth.max_value = 100.0
	_door_depth.step = 5.0
	_door_depth.suffix = "%"
	_door_depth.value_changed.connect(func(v): door_option_changed.emit(&"door_depth", v))
	_door_front = _door_spin(box, "Inset front", "Door sits this far back from the wall you click\n(0 + 0 = flush, the old door placement).")
	_door_front.value_changed.connect(func(v): door_option_changed.emit(&"door_inset_front", v))
	_door_back = _door_spin(box, "Inset back", "Tunnel behind the door to the opposing wall.")
	_door_back.value_changed.connect(func(v): door_option_changed.emit(&"door_inset_back", v))
	_door_room = CheckBox.new()
	_door_room.text = "Start next room"
	_door_room.tooltip_text = "When nothing is behind the wall: build the opposing wall\n(doorway cut) and a floor (door wide, 1 m deep) to grow the room from."
	_door_room.toggled.connect(func(on): door_option_changed.emit(&"door_build_room", on))
	box.add_child(_door_room)
	_door_hint = Label.new()
	_door_hint.add_theme_font_size_override(&"font_size", int(11 * _scale))
	_door_hint.modulate = Color(1, 1, 1, 0.6)
	box.add_child(_door_hint)


func _show_door_mode(between: int) -> void:
	_door_depth.get_parent().visible = between == 1
	for c: Control in [_door_front.get_parent(), _door_back.get_parent(), _door_room]:
		c.visible = between != 1
	_door_hint.text = "Click the outside face. A doorway already\nthere: the door fits it. Solid: cuts both\nfaces, lines the gap (a set piece's .blend\nstays as made)." if between == 1 \
		else "Insets snap to the grid.\nTunnel takes the wall / floor textures.\nSet pieces always use Between faces."


func _door_spin(parent: Control, label: String, tip: String) -> SpinBox:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 80 * _scale
	l.add_theme_font_size_override(&"font_size", int(12 * _scale))
	row.add_child(l)
	var s := SpinBox.new()
	s.min_value = 0.0
	s.max_value = 8.0
	s.step = 0.05
	s.suffix = "m"
	s.tooltip_text = tip
	s.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(s)
	parent.add_child(row)
	return s


func set_door_options(front: float, back: float, build_room: bool, door_mode: int, depth: float) -> void:
	_door_front.set_value_no_signal(front)
	_door_back.set_value_no_signal(back)
	_door_room.set_pressed_no_signal(build_room)
	_door_mode.select(door_mode)
	_door_depth.set_value_no_signal(depth)
	_show_door_mode(door_mode)


func set_sticky_grid(on: bool) -> void:
	_sticky_button.set_pressed_no_signal(on)


func set_mode(mode: int) -> void:
	_mode = mode
	for i in _mode_buttons.size():
		_mode_buttons[i].set_pressed_no_signal(not _placing and i == mode)
	_brush_ops.visible = mode == 0
	_geometry_ops.visible = mode >= 1 and mode <= 3
	paint_panel.visible = mode == 4
	sculpt_panel.visible = mode == 5


func set_debug_view(enabled: bool) -> void:
	_debug_button.set_pressed_no_signal(enabled)


func set_preview_baked(enabled: bool) -> void:
	_preview_button.set_pressed_no_signal(enabled)


func set_status(summary: String, color: Color, details: String, data_text: String, hint: String) -> void:
	_status_bar.color = color
	_status_bar.tooltip_text = summary
	_summary.text = summary
	_summary.add_theme_color_override(&"font_color", color)
	_details_label.text = details
	_data_label.text = data_text
	_hint.text = hint


# --- Building blocks ------------------------------------------------------------------

func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override(&"panel", _panel_style())
	p.mouse_filter = MOUSE_FILTER_STOP
	return p


func _panel_style() -> StyleBoxFlat:
	var box := _rounded(BG, 6)
	box.set_content_margin_all(4 * _scale)
	box.border_color = RULE
	box.set_border_width_all(1)
	return box


func _rounded(color: Color, radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(int(radius * _scale))
	return box


func _grid(parent: Control) -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override(&"h_separation", int(2 * _scale))
	g.add_theme_constant_override(&"v_separation", int(2 * _scale))
	parent.add_child(g)
	return g


func _rule() -> void:
	var r := ColorRect.new()
	r.color = RULE
	r.custom_minimum_size = Vector2(0, 1)
	r.mouse_filter = MOUSE_FILTER_IGNORE
	_tools.add_child(r)


func _button(icon: Texture2D, tip: String, toggle := false, fallback_text := "") -> Button:
	var b := Button.new()
	b.focus_mode = FOCUS_NONE
	b.toggle_mode = toggle
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(CELL, CELL) * _scale
	for state in [&"normal", &"focus", &"disabled"]:
		b.add_theme_stylebox_override(state, _box_empty)
	b.add_theme_stylebox_override(&"hover", _box_hover)
	for state in [&"pressed", &"hover_pressed"]:
		b.add_theme_stylebox_override(state, _box_active)
	for prefix in [&"icon_", &"font_"]:
		b.add_theme_color_override(prefix + &"normal_color", ICON)
		b.add_theme_color_override(prefix + &"focus_color", ICON)
		b.add_theme_color_override(prefix + &"hover_color", ICON_HOVER)
		b.add_theme_color_override(prefix + &"pressed_color", ICON_ACTIVE)
		b.add_theme_color_override(prefix + &"hover_pressed_color", ICON_ACTIVE)
	if icon:
		b.icon = icon
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	else:
		b.text = fallback_text
	return b


func _action_grid(specs: Array) -> Control:
	var grid := _grid(_tools)
	for spec in specs:
		var b := _button(spec[0], spec[1], false, spec[3])
		b.pressed.connect(func(): action_requested.emit(spec[2]))
		grid.add_child(b)
	return grid


func _label(size_px := 12) -> Label:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 180 * _scale
	l.add_theme_color_override(&"font_color", TEXT)
	l.add_theme_font_size_override(&"font_size", int(size_px * _scale))
	return l


func _build_snap_popup() -> void:
	_snap_popup = PopupPanel.new()
	_snap_popup.add_theme_stylebox_override(&"panel", _panel_style())
	var box := VBoxContainer.new()
	_snap_popup.add_child(box)
	_snap_spin = SpinBox.new()
	_snap_spin.min_value = 0.01
	_snap_spin.max_value = 10.0
	_snap_spin.step = 0.01
	_snap_spin.suffix = "m"
	_snap_spin.value_changed.connect(func(v): _update_snap_label(v); snap_changed.emit(v))
	box.add_child(_snap_spin)
	var presets := GridContainer.new()
	presets.columns = 3
	box.add_child(presets)
	for v in SNAP_PRESETS:
		var b := _button(null, "", false, str(v))
		b.custom_minimum_size = Vector2(CELL * 1.3, CELL * 0.8) * _scale
		b.pressed.connect(func(): _snap_spin.value = v; _snap_popup.hide())
		presets.add_child(b)
	add_child(_snap_popup)


## The Props toolbar: one row of placeable things beside the Props button.
func _build_props_popup() -> void:
	_props_popup = PopupPanel.new()
	_props_popup.add_theme_stylebox_override(&"panel", _panel_style())
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", int(2 * _scale))
	_props_popup.add_child(row)
	for spec in [
		[_svg("prop"), "Prop: drops a prop brush where the view looks, facing you, and selects it. Pick what\nit is in the Inspector (sign, stall, rain drip, bird flock, NPC spot) and set it up there;\nmove, turn and duplicate it like any brush. The quicker buttons beside this make the\ncommon ones ready set up.", &"prop", "P"],
		[_svg("tree"), "Tree: drops a generated tree where the view looks (the species last placed, sycamore\nat first) with a new seed, and selects it. Species, seed (tick New Seed for another tree\nof the species), size and far card in the Inspector. Species presets live in\naddons/n64_level_tools/trees/species (tools/tree_import makes more from photos).", &"tree", "Tr"],
		[_svg("sign"), "Sign: drops a signpost where the view looks, facing you, and selects it.\nSet what it says (Text) and its look in the Inspector; the player reads it with interact.", &"sign", "S"],
		[_svg("house"), "House: drops a Kakariko-style house where the view looks, its front facing you,\nwith a door (to its own interior zone) and windows, and selects it. Size, storeys,\nroof, textures and trim in the Inspector (House). Drag the door and windows along\nits walls; add more with the Door tool and Window.", &"house", "H"],
		[_svg("shop"), "Shop: a house with a shopfront (counter, awning and noren curtain, shelves inside)\nand a sign over it, placed like House. Shopfront settings in the Inspector (House > Shop).", &"shop", "Sh"],
		[_svg("tent"), "Tent stall: poles, a peaked cloth canopy with a striped valance and a table of\ngoods, dropped where the view looks. Kind, size, goods and colours in the Inspector.", &"stall_tent", "T"],
		[_svg("carpet"), "Carpet seller: a rug on the ground with goods set out on it and a cushion behind.", &"stall_carpet", "Ca"],
		[_svg("cart"), "Cart seller: a hand cart of goods under a parasol.", &"stall_cart", "Cr"],
		[_svg("goods"), "Goods: a pile of crates, baskets, sacks, pots or produce to dress any stall or corner.", &"stall_goods", "G"],
		[_svg("drips"), "Roof drips: rain running off every house's eaves (and shop awnings) in the level,\nas rain drip prop brushes. Houses that already have drips are left alone, so moved,\nstretched or deleted drips stay as you left them. Shows only in rain.", &"drips", "D"],
		[_svg("window"), "Window: cuts a window into the wall where the view looks (frame, sill, dark pane)\nand selects it. Drag it to move it (the opening follows); size and look in the Inspector.", &"window", "W"],
		[_svg("rope"), "Rope: click where it hangs from, then where it goes to (anchors snap to\ncorners near the mouse: building corners, posts). It sags between its points and\nrepeats its style's texture along itself. Selected: drag its points, Shift+click to\nextend, click a section's + to add a point, Alt+click a point / section to remove / leave it out.", &"rope", "~"],
		[_svg("fence"), "Fence: drops a fence on the ground where the view looks and selects it:\ndrag its points (snapped, on the ground), click a section's + to split it,\nShift+click the ground to extend, Alt+click a point / section to remove / open it.\nVertex mode with a line of vertices selected: follows them instead.", &"fence", "▥"],
	]:
		var b := _button(spec[0], spec[1], false, spec[3])
		b.pressed.connect(func(): _props_popup.hide(); action_requested.emit(spec[2]))
		row.add_child(b)
	add_child(_props_popup)


func _open_props_popup() -> void:
	_props_popup.position = Vector2i(_props_button.get_screen_position() + Vector2(_props_button.size.x + 8 * _scale, 0))
	_props_popup.popup()


func _open_snap_popup() -> void:
	_snap_popup.position = Vector2i(_snap_button.get_screen_position() + Vector2(_snap_button.size.x + 8 * _scale, 0))
	_snap_popup.popup()


func _update_snap_label(value: float) -> void:
	_snap_button.text = "%sm" % snappedf(value, 0.01)


func _build_flyout() -> void:
	_flyout = _panel()
	_flyout.size_flags_vertical = SIZE_SHRINK_BEGIN
	add_child(_flyout)
	var box := VBoxContainer.new()
	_flyout.add_child(box)
	_summary = _label(13)
	box.add_child(_summary)
	_details = VBoxContainer.new()
	box.add_child(_details)
	_details_label = _label()
	_details.add_child(_details_label)
	var data_row := HBoxContainer.new()
	_details.add_child(data_row)
	_data_label = _label()
	_data_label.custom_minimum_size.x = 140 * _scale
	_data_label.size_flags_horizontal = SIZE_EXPAND_FILL
	data_row.add_child(_data_label)
	var save_as := _button(_editor_icon(&"Save"), "Save level data to its own .res/.tres file", false, "Save")
	save_as.pressed.connect(func(): action_requested.emit(&"save_data_as"))
	data_row.add_child(save_as)
	_hint = _label()
	_hint.modulate = Color(1, 1, 1, 0.65)
	box.add_child(_hint)


# --- Icons / settings ---------------------------------------------------------------

## Our SVGs, rasterised a bit larger than editor icons and at the editor scale.
func _svg(icon_name: String) -> Texture2D:
	var image := Image.new()
	if image.load_svg_from_string(FileAccess.get_file_as_string(ICON_DIR + icon_name + ".svg"), _scale * 1.25) != OK:
		return null
	return ImageTexture.create_from_image(image)


func _editor_icon(icon_name: StringName) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	return theme.get_icon(icon_name, &"EditorIcons") if theme.has_icon(icon_name, &"EditorIcons") else null


func _get_setting(key: StringName, default: Variant) -> Variant:
	return EditorInterface.get_editor_settings().get_project_metadata(SETTINGS_SECTION, key, default)


func _set_setting(key: StringName, value: Variant) -> void:
	EditorInterface.get_editor_settings().set_project_metadata(SETTINGS_SECTION, key, value)


func _apply_sections() -> void:
	var collapsed: bool = _get_setting(&"collapsed", false)
	var show_details: bool = _get_setting(&"details", false)
	var show_hint: bool = _get_setting(&"hint", false)
	_tools.visible = not collapsed
	_details_toggle.set_pressed_no_signal(show_details)
	_hint_toggle.set_pressed_no_signal(show_hint)
	_details.visible = show_details
	_hint.visible = show_hint
	_summary.visible = show_details
	_flyout.visible = not collapsed and (show_details or show_hint)
	_collapse_button.icon = _editor_icon(&"GuiTreeArrowRight" if collapsed else &"GuiTreeArrowDown")
	if _collapse_button.icon == null:
		_collapse_button.text = "+" if collapsed else "–"


# --- Input --------------------------------------------------------------------------

func _on_shape_toggled(pressed: bool, shape: int) -> void:
	if pressed:
		shape_selected.emit(shape)
	elif not _shape_buttons.any(func(b): return b.button_pressed):
		shape_selected.emit(-1)


func _on_grip_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if not _dragging:
			_set_setting(&"position", position)
	elif event is InputEventMouseMotion and _dragging:
		position += event.relative
		var parent := get_parent_control()
		if parent:
			position = position.clamp(Vector2.ZERO, (parent.size - _toolbar.size).max(Vector2.ZERO))
