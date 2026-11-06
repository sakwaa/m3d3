@tool
extends PanelContainer
## Floating tool strip for character scenes (same look as the level tools' strip), shown
## inside the 3D viewport while an ActorModel is edited. Picks the active tool and runs
## one-click operations; each tool's settings show in the inspector while it's active.

const ActorEditor := preload("res://addons/n64_actor_tools/actor_editor.gd")
const Tool := ActorEditor.Tool
const ICON_DIR := "res://addons/n64_actor_tools/icons/"
const SETTINGS_SECTION := "n64_actor_tools_toolbar"

const CELL := 30
const BG := Color(0.07, 0.075, 0.08, 0.96)
const RULE := Color(1, 1, 1, 0.07)
const ICON := Color(0.4, 0.82, 0.42)
const ICON_HOVER := Color(0.6, 1.0, 0.6)
const ICON_ACTIVE := Color(0.82, 1.0, 0.8)
const BUTTON_HOVER := Color(1, 1, 1, 0.07)
const BUTTON_ACTIVE := Color(0.3, 0.75, 0.32, 0.3)
const LABEL := Color(0.55, 0.62, 0.55)
const STATUS_OK := Color(0.45, 0.85, 0.45)
const STATUS_OVER := Color(1.0, 0.45, 0.35)

## [tool, icon, tooltip] per section.
const RIG_TOOLS := [
	[Tool.BODY, "body", "Body\nBody plan and proportions (leg length, …) in the inspector."],
	[Tool.POSE, "pose", "Pose\nDrag bone ends to aim, big handles for hands / feet (IK)\nand the hips (body). Snaps and pinned limbs in the inspector."],
]
const MODEL_TOOLS := [
	[Tool.PIECE, "piece", "Piece\nClick to select whole pieces; add / copy / delete pieces,\njoint and stitch settings in the inspector."],
	[Tool.VERTEX, "vertex", "Vertex (1)\nClick / box-drag to select, Shift adds, %s+click selects the shortest path.\nL picks the piece under the mouse, A all, Alt+A none."],
	[Tool.EDGE, "edge", "Edge (2)"],
	[Tool.FACE, "face", "Face (3)"],
	[Tool.LOOP_CUT, "loop_cut", "Loop cut (like Blender's Ctrl+R)\nHover an edge to preview the loop across it; press and drag to slide it,\nrelease to cut (Esc / right click cancels). Hold %s to slide in quarters.\nTubes cut around get a new ring."],
]
const PAINT_TOOLS := [
	[Tool.TEXTURE, "texture_fill", "Texture fill\nClick a face (Shift = whole piece)."],
	[Tool.OVERLAY, "overlay_fill", "Overlay fill\nClick a face: the overlay texture shows where the mask is painted."],
	[Tool.COLOR_FILL, "color_fill", "Colour fill\nClick a face (Shift = whole piece)."],
	[Tool.COLOR_BRUSH, "color_brush", "Colour brush\nPaint vertex colour, Shift erases."],
	[Tool.MASK_BRUSH, "mask_brush", "Overlay mask brush\nWhere the overlay shows; Shift erases."],
	[Tool.UV, "uv", "UVs & swap slots\nClick / box-drag faces, then fit / rotate / move their texture,\nor assign them to a swap slot (eyes, mouth)."],
]

var _merge_menu: PopupMenu
var editor: ActorEditor

var _scale := 1.0
var _box_empty: StyleBoxEmpty
var _box_hover: StyleBoxFlat
var _box_active: StyleBoxFlat
var _tools: VBoxContainer
## Scrolls the tools when the viewport is shorter than the strip.
var _scroll: ScrollContainer
var _collapse_button: Button
var _tool_buttons := {}  # Tool -> Button
var _pose_ops: Control
var _piece_ops: Control
var _element_ops: Control
var _ring_ops: Control
var _uv_ops: Control
var _pin_buttons: Array[Button] = []
var _display_buttons: Array[Button] = []
var _reference_button: Button
var _mirror_button: Button
## Character editor v2: Move to / Edit in Blender, Pull now; and what hides meanwhile.
var _blender_button: Button
var _pull_button: Button
var _geometry_tools: Array[Control] = []
var _backdrop_buttons: Array[Button] = []
var _status_bar: ColorRect
var _dragging := false


func _init() -> void:
	name = "N64ActorTools"
	_scale = EditorInterface.get_editor_scale()
	_box_empty = StyleBoxEmpty.new()
	_box_hover = _rounded(BUTTON_HOVER, 4)
	_box_active = _rounded(BUTTON_ACTIVE, 4)
	var style := _rounded(BG, 6)
	style.set_content_margin_all(4 * _scale)
	style.border_color = RULE
	style.set_border_width_all(1)
	add_theme_stylebox_override(&"panel", style)
	mouse_filter = MOUSE_FILTER_STOP
	minimum_size_changed.connect(reset_size)

	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", int(2 * _scale))
	add_child(column)
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
	_collapse_button.pressed.connect(func(): _set_setting(&"collapsed", _tools.visible); _apply_collapsed())
	header.add_child(_collapse_button)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	column.add_child(_scroll)
	_tools = VBoxContainer.new()
	_tools.add_theme_constant_override(&"separation", int(2 * _scale))
	_tools.minimum_size_changed.connect(_fit_height, CONNECT_DEFERRED)
	_scroll.add_child(_tools)
	var group := ButtonGroup.new()

	_section("RIG")
	_tool_grid(RIG_TOOLS, group)
	_pose_ops = _action_grid([
		[_editor_icon(&"Reload"), "Reset pose", func(): editor.reset_pose()],
		[_svg("mirror_lr"), "Mirror pose: left side onto right", func(): editor.mirror_pose(-1)],
		[_svg("mirror_rl"), "Mirror pose: right side onto left", func(): editor.mirror_pose(1)],
	])

	_section("MODEL")
	var model_grid := _tool_grid(MODEL_TOOLS, group)
	_mirror_button = _button(_svg("mirror_piece"), "Mirror (selected piece)\nLeft pieces build the right side; centre pieces stay symmetric.\nTurning it off splits the right side into its own piece.", true)
	_mirror_button.toggled.connect(func(on): editor.set_piece_mirror(on))
	model_grid.add_child(_mirror_button)
	_blender_button = _button(_svg("edit_blender"), "")
	_blender_button.pressed.connect(func(): if editor.plugin: editor.plugin.blender_button())
	model_grid.add_child(_blender_button)
	_pull_button = _button(_editor_icon(&"Reload"), "Pull from Blender now\n(happens by itself whenever the .blend is saved)")
	_pull_button.pressed.connect(func(): if editor.plugin: editor.plugin.blender.pull(editor.model))
	model_grid.add_child(_pull_button)
	for t in [Tool.VERTEX, Tool.EDGE, Tool.FACE, Tool.LOOP_CUT]:
		_geometry_tools.append(_tool_buttons[t])
	_geometry_tools.append(_mirror_button)
	_piece_ops = _action_grid([
		[_svg("add_tube"), "Add tube on the bone picked in the inspector", func(): editor.add_piece(editor.piece_bone, true)],
		[_svg("add_box"), "Add box on the bone picked in the inspector", func(): editor.add_piece(editor.piece_bone, false)],
		[_svg("shell"), "Shell copy: a slightly bigger copy of the piece (sleeves, armour)", func(): editor.shell()],
		[_svg("copy_bone"), "Copy the piece to the bone picked in the inspector", func(): editor.copy_to_bone(editor.piece_bone)],
		[_svg("pin"), "Pin to nearest…: the selected vertices (or the whole piece) take the\nnearest vertex of the piece you click next, in every pose.", func(): editor.start_pin(), true],
		[_svg("unpin"), "Unpin the selected vertices (or the whole piece)", func(): editor.unpin()],
		[_editor_icon(&"Remove"), "Delete piece", func(): editor.delete_piece()],
	])
	for i in [0, 1, 2, 3, 6]:
		_geometry_tools.append(_piece_ops.get_child(i))
	_element_ops = _action_grid([
		[_svg("extrude"), "Extrude faces (edges in Edge mode) two grid steps", func(): editor.extrude()],
		[_svg("subdivide"), "Subdivide faces", func(): editor.subdivide()],
		[_svg("merge"), "Merge vertices: at center / first / last selected, collapse each\nconnected group, or by distance (the whole piece when nothing is selected)", _show_merge_menu],
		[_svg("dissolve"), "Dissolve the selected vertices: neighbours reconnect, faces around merge", func(): editor.dissolve()],
		[_svg("flip"), "Flip faces", func(): editor.flip_faces()],
		[_svg("inflate"), "Inflate: push out along the normals one grid step", func(): editor.inflate(1.0)],
		[_svg("deflate"), "Deflate: pull in along the normals one grid step", func(): editor.inflate(-1.0)],
		[_svg("scale_up"), "Scale up (step in the inspector)", func(): editor.scale(true)],
		[_svg("scale_down"), "Scale down", func(): editor.scale(false)],
		[_svg("conform"), "Conform: shrink-wrap onto the pieces underneath", func(): editor.conform()],
		[_svg("pin"), "Pin to nearest…: the selected vertices take the nearest vertex\nof the piece you click next, in every pose.", func(): editor.start_pin(), true],
		[_svg("unpin"), "Unpin the selected vertices", func(): editor.unpin()],
		[_editor_icon(&"Remove"), "Delete faces", func(): editor.delete_faces()],
	])
	_ring_ops = _action_grid([
		[_svg("ring_add"), "Add ring (after the picked ring; drag a ring handle to pick)", func(): editor.add_ring()],
		[_svg("ring_delete"), "Delete the picked ring", func(): editor.delete_ring()],
		[_editor_icon(&"RotateLeft"), "Twist the picked ring (angle snap step)", func(): editor.twist_ring(-1.0)],
		[_editor_icon(&"RotateRight"), "Twist the picked ring the other way", func(): editor.twist_ring(1.0)],
		[_svg("sides_more"), "More tube sides", func(): editor.tube_sides(1)],
		[_svg("sides_fewer"), "Fewer tube sides", func(): editor.tube_sides(-1)],
	])

	_section("PAINT")
	_tool_grid(PAINT_TOOLS, group)
	_uv_ops = _action_grid([
		[_svg("texture_to_sel"), "Texture (inspector) onto the selected faces", func(): editor.fill_selection(&"texture")],
		[_svg("overlay_to_sel"), "Overlay (inspector) onto the selected faces", func(): editor.fill_selection(&"overlay")],
		[_editor_icon(&"Clear"), "Clear texture + overlay on the selected faces", func(): editor.fill_selection(&"clear")],
		[_svg("uv_fit"), "Fit the texture to each face / tile it (toggle)", func(): editor.uv_fit()],
		[_editor_icon(&"RotateRight"), "Rotate the texture 90°", func(): editor.uv_nudge(Vector4(0, 0, 1, 1))],
		[_editor_icon(&"Reload"), "Reset UVs", func(): editor.uv_reset()],
		[_svg("slot_assign"), "Assign the selected faces to the swap slot (inspector)", func(): editor.assign_slot()],
		[_svg("slot_clear"), "Remove the selected faces from their swap slot", func(): editor.clear_slot()],
	])

	_section("VIEW")
	var view := _grid(_tools)
	var dg := ButtonGroup.new()
	for spec in [["view_solid", "Solid"], ["view_wire", "Wireframe (Shift+Z)\nEdges only; select through"], ["view_xray", "X-ray (Alt+Z)\nSee-through; select through"]]:
		var b := _button(_svg(spec[0]), spec[1], true)
		b.button_group = dg
		var d := _display_buttons.size()
		b.pressed.connect(func(): editor.set_display(d))
		view.add_child(b)
		_display_buttons.append(b)
	_reference_button = _button(_editor_icon(&"CharacterBody3D"), "Player scale reference (capsule beside the model)", true)
	_reference_button.toggled.connect(func(on): if editor.model: editor.model.show_reference = on)
	view.add_child(_reference_button)
	var refs_button := _button(_editor_icon(&"Image"), "Reference images & grid\nPer axis view (orthogonal: click the view gizmo or numpad 1 / 3 / 7):\nload, adjust, fit, opacity, lock. Double-click an image to adjust it.")
	refs_button.pressed.connect(func(): if editor.plugin: editor.plugin.open_reference_panel(Rect2i(refs_button.get_screen_position(), refs_button.size)))
	view.add_child(refs_button)
	var backdrops := _grid(_tools)
	var bg := ButtonGroup.new()
	for spec in [["bg_studio", "Studio grey background\nFlat grey, soft light, floor shadows: for animating"],
			["bg_silhouette", "Silhouette\nThe character solid black on light grey: does the pose read?"],
			["bg_measure", "Measure grid\n0.25 m grid on the floor and walls, with the player's step / eye /\njump apex / body heights: arcs, crouch depth, foot sliding"],
			["bg_sky", "Preview sky\nGodot's preview sky and sun (in-game style check)"]]:
		var b := _button(_svg(spec[0]), spec[1], true)
		b.button_group = bg
		var k := _backdrop_buttons.size()
		b.pressed.connect(func(): editor.set_backdrop(k))
		backdrops.add_child(b)
		_backdrop_buttons.append(b)

	_status_bar = ColorRect.new()
	_status_bar.custom_minimum_size = Vector2(CELL * 2, 3) * _scale
	_status_bar.mouse_filter = MOUSE_FILTER_STOP
	_tools.add_child(_status_bar)
	_apply_collapsed()


func setup(e: ActorEditor, default_position: Vector2) -> void:
	editor = e
	editor.tool_changed.connect(refresh)
	editor.refreshed.connect(refresh)
	position = _get_setting(&"position", default_position)


func refresh() -> void:
	var m := editor.model if editor else null
	if m == null or not is_instance_valid(m):
		return
	var t := editor.tool
	for k in _tool_buttons:
		_tool_buttons[k].set_pressed_no_signal(k == t)
	_pose_ops.visible = t == Tool.POSE
	var p := editor.piece() if ActorEditor.is_model_tool(t) else null
	_mirror_button.disabled = p == null
	_mirror_button.set_pressed_no_signal(p != null and p.mirror)
	var in_blender := editor.geometry_locked()
	for c in _geometry_tools:
		c.visible = not in_blender
	_pull_button.visible = in_blender
	var issues: Array = editor.plugin.blender.issues if editor.plugin and in_blender else []
	_blender_button.modulate = Color(1, 0.6, 0.5) if not issues.is_empty() else Color.WHITE
	if in_blender:
		var tip := "Edit in Blender (%s)\nOpens the .blend (or brings Blender forward). Save there to update the character here.\nModel in Blender; pieces' stitching, pins and paint stay here." % m.data.blend_file
		for issue: Dictionary in issues:
			tip += "\n• %s%s" % ["%s: " % issue.object if issue.object != "" else "", issue.message]
		_blender_button.tooltip_text = tip
	else:
		_blender_button.tooltip_text = "Move geometry to Blender (character editor v2)…\nMakes characters/blend/<name>.blend from these pieces (one object per bone) and opens it.\nGeometry is then edited in Blender; stitching, pins, paint and posing stay here."
	_piece_ops.visible = t == Tool.PIECE
	_element_ops.visible = t >= Tool.VERTEX and t <= Tool.FACE
	_ring_ops.visible = ActorEditor.is_model_tool(t) and editor.selected_tube()
	_uv_ops.visible = t == Tool.UV
	for b in _pin_buttons:
		b.set_pressed_no_signal(editor.pin_picking)
	for i in _display_buttons.size():
		_display_buttons[i].set_pressed_no_signal(m.display == i)
	_reference_button.set_pressed_no_signal(m.show_reference)
	for i in _backdrop_buttons.size():
		_backdrop_buttons[i].set_pressed_no_signal(editor.backdrop == i)
	var info := editor.budget()
	_status_bar.color = STATUS_OVER if info.over else STATUS_OK
	_status_bar.tooltip_text = "%d / %d tris · %d textures (%.1f KB TMEM)" % [info.tris, info.budget, info.textures, info.kb]


func _tool_grid(specs: Array, group: ButtonGroup) -> GridContainer:
	var grid := _grid(_tools)
	var mod := "Cmd" if OS.get_name() == "macOS" else "Ctrl"
	for spec in specs:
		var tip: String = spec[2] % mod if spec[2].contains("%s") else spec[2]
		var b := _button(_svg(spec[1]), tip, true)
		b.button_group = group
		var t: int = spec[0]
		b.pressed.connect(func(): editor.set_tool(t))
		grid.add_child(b)
		_tool_buttons[t] = b
	return grid


## [icon, tooltip, callable, toggle?]
## Blender's Merge menu (ids = ActorPieceOps.Merge), at the mouse.
func _show_merge_menu() -> void:
	if _merge_menu == null:
		_merge_menu = PopupMenu.new()
		for item in [["At Center", 0], ["At First", 1], ["At Last", 2], ["Collapse (each group)", 3], ["By Distance", 5]]:
			_merge_menu.add_item(item[0], item[1])
		_merge_menu.id_pressed.connect(func(id): editor.merge_by(id))
		add_child(_merge_menu)
	_merge_menu.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i.ZERO))


func _action_grid(specs: Array) -> Control:
	var grid := _grid(_tools)
	for spec in specs:
		var toggle: bool = spec.size() > 3 and spec[3]
		var b := _button(spec[0], spec[1], toggle)
		var fn: Callable = spec[2]
		b.pressed.connect(func(): fn.call())
		grid.add_child(b)
		if toggle:
			_pin_buttons.append(b)
	return grid


func _section(text: String) -> void:
	var r := ColorRect.new()
	r.color = RULE
	r.custom_minimum_size = Vector2(0, 1)
	r.mouse_filter = MOUSE_FILTER_IGNORE
	_tools.add_child(r)
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override(&"font_size", int(9 * _scale))
	l.add_theme_color_override(&"font_color", LABEL)
	l.mouse_filter = MOUSE_FILTER_IGNORE
	_tools.add_child(l)


func _grid(parent: Control) -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override(&"h_separation", int(2 * _scale))
	g.add_theme_constant_override(&"v_separation", int(2 * _scale))
	parent.add_child(g)
	return g


func _button(icon: Texture2D, tip: String, toggle := false) -> Button:
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
	return b


func _rounded(color: Color, radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(int(radius * _scale))
	return box


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


func _notification(what: int) -> void:
	if what == NOTIFICATION_PARENTED and get_parent_control():
		get_parent_control().resized.connect(_fit_height, CONNECT_DEFERRED)


## Fits the strip below its position: two columns when there's room, more when the 3D
## view is short (e.g. with the Actor Animation panel open); scrolls past four.
var _fitting := false


func _fit_height() -> void:
	var parent := get_parent_control()
	if _fitting or parent == null:
		return
	_fitting = true
	var room := parent.size.y - position.y - (CELL + 16) * _scale
	var want := Vector2.ZERO
	for cols in [2, 3, 4]:
		for g in _tools.get_children():
			if g is GridContainer:
				g.columns = cols
		want = _tools.get_combined_minimum_size()
		if want.y <= room:
			break
	var scrolls := want.y > room
	var bar := _scroll.get_v_scroll_bar().get_combined_minimum_size().x if scrolls else 0.0
	_scroll.custom_minimum_size = Vector2(want.x + bar, clampf(room, CELL * 2 * _scale, want.y))
	reset_size()
	_fitting = false


func _apply_collapsed() -> void:
	var collapsed: bool = _get_setting(&"collapsed", false)
	_scroll.visible = not collapsed
	_collapse_button.icon = _editor_icon(&"GuiTreeArrowRight" if collapsed else &"GuiTreeArrowDown")


func _on_grip_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if not _dragging:
			_set_setting(&"position", position)
	elif event is InputEventMouseMotion and _dragging:
		position += event.relative
		var parent := get_parent_control()
		if parent:
			position = position.clamp(Vector2.ZERO, (parent.size - size).max(Vector2.ZERO))
		_fit_height()
