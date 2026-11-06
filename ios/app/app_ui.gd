extends Control
## The mesh builder's touch interface (built in code, sized for fingers):
##  - top: menu (new / open / save), undo / redo, status;
##  - left: what to select (piece / vertex / edge / face), the gizmo (Move / Rotate +
##    pivot), Add (taps / boxes add to the selection), Mirror, Cut (loop cut mode);
##  - right: views (perspective, front, back, left, right, top, bottom), X-ray, wireframe,
##    frame, reference image, grid size;
##  - bottom right: the orbit pad (drag from it to orbit);
##  - bottom: the action bar: the operations that fit the current selection (fixed, no
##    scrolling) and ⋯ for the full sheet.
## Pure UI: calls back into the builder (`app`).

const ICON_DIR := "res://addons/n64_actor_tools/icons/"
const BG := Color(0.07, 0.075, 0.08, 0.92)
const ACCENT := Color(0.4, 0.82, 0.42)
const ON := Color(0.3, 0.75, 0.32, 0.45)

var app: Node
var status: Label
var _groups := {}  # name -> {value -> Button}
var _toggles := {}  # name -> Button
var _orbit_pad: Control
const PAD_SIZE := 230.0
var _grid_button: Button
var _pivot_button: Button
var _menu: PopupMenu
var _new_menu: PopupMenu
var _bone_menu: PopupMenu
var _merge_menu: PopupMenu
## Merge menu entries, ids = ActorPieceOps.Merge.
const MERGE_ITEMS := ["At Center", "At First", "At Last", "Collapse (each group)", "At Tap Point…", "By Distance"]
var _open_list: ItemList
var _open_panel: PanelContainer
var _open_paths: PackedStringArray
var _name_panel: PanelContainer
var _name_edit: LineEdit
var _top: PanelContainer
var _left: PanelContainer
var _right: PanelContainer
var _bottom: VBoxContainer
## Every operation: id -> [icon, label, sheet group].
const ACTIONS := {
	&"extrude": ["extrude", "Extrude", "Shape"], &"subdivide": ["subdivide", "Subdiv", "Shape"],
	&"merge": ["merge", "Merge", "Shape"], &"dissolve": ["dissolve", "Dissolve", "Shape"], &"flip": ["flip", "Flip", "Shape"],
	&"inflate": ["inflate", "Inflate", "Shape"], &"deflate": ["deflate", "Deflate", "Shape"],
	&"scale_up": ["scale_up", "Scale +", "Shape"], &"scale_down": ["scale_down", "Scale −", "Shape"],
	&"delete": ["", "Delete", "Shape"],
	&"ring_add": ["ring_add", "Ring +", "Tubes"], &"ring_delete": ["ring_delete", "Ring −", "Tubes"],
	&"sides_more": ["sides_more", "Sides +", "Tubes"], &"sides_fewer": ["sides_fewer", "Sides −", "Tubes"],
	&"add_tube": ["add_tube", "Add tube", "Piece"], &"add_box": ["add_box", "Add box", "Piece"],
	&"shell": ["shell", "Shell", "Piece"], &"copy_bone": ["copy_bone", "Copy to", "Piece"],
	&"mirror": ["", "Mirror", "Piece"],
	&"select_all": ["", "All", "Select"], &"select_none": ["", "None", "Select"],
	&"reset_piece": ["", "Reset piece", "Reset"], &"reset_model": ["", "Reset all", "Reset"],
}
const SHEET_GROUPS := ["Shape", "Tubes", "Piece", "Select", "Reset"]
var _actions_row: HBoxContainer
var _shown_actions: Array = []
var _sheet: Control
## Reference image panel (current ortho view).
var _ref_panel: PanelContainer
var _ref_title: Label
var _ref_show: CheckButton
var _ref_lock: CheckButton
var _ref_list: ItemList
var _ref_paths: PackedStringArray
var _ref_hint: Label
var _ref_height: HSlider
var _ref_height_label: Label
var _ref_opacity: HSlider
var _ref_updating := false
## Touches that started on a panel: they belong to the UI, never the 3D view.
var _ui_touches := {}
## Screen edges the UI keeps clear of (Dynamic Island, home indicator; design pixels).
var _safe := Rect2()


func _ready() -> void:
	# Under a CanvasLayer the screen is the parent rect: fill it (and follow rotations).
	mouse_filter = MOUSE_FILTER_IGNORE
	_fit_screen()
	get_viewport().size_changed.connect(_fit_screen)
	theme = _make_theme()
	_build_top()
	_build_left()
	_build_right()
	_build_bottom()
	_build_popups()
	_build_ref_panel()
	_fit_screen.call_deferred()


## A touch that starts on a panel is the UI's: the 3D view never sees it (no selecting
## or orbiting behind the buttons). Runs before the GUI and the 3D view.
func _input(event: InputEvent) -> void:
	var touch := event as InputEventScreenTouch
	var drag := event as InputEventScreenDrag
	if touch:
		if touch.pressed and _over_ui(touch.position):
			_ui_touches[touch.index] = true
		if _ui_touches.has(touch.index):
			if not touch.pressed:
				_ui_touches.erase(touch.index)
			get_viewport().set_input_as_handled()
	elif drag and _ui_touches.has(drag.index):
		get_viewport().set_input_as_handled()


## Is a point (design px) on one of the panels?
func _over_ui(pos: Vector2) -> bool:
	if _sheet.visible:
		return true
	if _open_panel.get_parent().visible or _name_panel.get_parent().visible:
		return true
	var panels: Array = [_top, _left, _right, _ref_panel]
	panels.append_array(_bottom.get_children().filter(func(c): return c != _orbit_pad))
	for c in panels:
		if c is Control and c.is_visible_in_tree() and c.get_global_rect().has_point(pos):
			return true
	return false


func _fit_screen() -> void:
	position = Vector2.ZERO
	size = get_viewport().get_visible_rect().size
	_safe = Rect2(Vector2.ZERO, size)
	if OS.has_feature("mobile"):
		# The display's safe area (screen pixels) in design pixels.
		var win := Vector2(DisplayServer.window_get_size())
		var area := DisplayServer.get_display_safe_area()
		if win.x > 0 and area.size.x > 0:
			var k := size / win
			_safe = Rect2(Vector2(area.position) * k, Vector2(area.size) * k)
	_place()


## Puts the panels inside the safe area: top bar under the island, columns below it,
## actions above the home indicator.
func _place() -> void:
	if _top == null:
		return
	var left := _safe.position.x + 24
	var right := size.x - _safe.end.x + 24
	_top.offset_left = left
	_top.offset_right = -right
	_top.offset_top = _safe.position.y + 12
	var below_top := _top.offset_top + maxf(_top.size.y, 130.0) + 30
	_left.offset_left = left
	_left.offset_top = below_top
	_right.offset_right = -right
	_right.offset_left = _right.offset_right - _right.get_combined_minimum_size().x
	_right.offset_top = below_top
	_bottom.offset_left = left
	_bottom.offset_right = -right
	_bottom.offset_bottom = -(size.y - _safe.end.y) - 24


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 30
	var flat := StyleBoxFlat.new()
	flat.bg_color = Color(1, 1, 1, 0.0)
	flat.set_corner_radius_all(18)
	var hover := flat.duplicate()
	hover.bg_color = Color(1, 1, 1, 0.08)
	var pressed := flat.duplicate()
	pressed.bg_color = ON
	for s in ["normal", "focus", "disabled"]:
		t.set_stylebox(s, "Button", flat)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("hover_pressed", "Button", pressed)
	t.set_color("font_color", "Button", Color(0.85, 0.9, 0.85))
	t.set_color("font_pressed_color", "Button", Color(0.9, 1, 0.9))
	t.set_color("icon_normal_color", "Button", ACCENT)
	t.set_color("icon_pressed_color", "Button", Color(0.85, 1, 0.85))
	t.set_color("icon_hover_color", "Button", ACCENT.lightened(0.3))
	t.set_color("icon_hover_pressed_color", "Button", Color(0.85, 1, 0.85))
	t.set_color("icon_focus_color", "Button", ACCENT)
	var panel := StyleBoxFlat.new()
	panel.bg_color = BG
	panel.set_corner_radius_all(26)
	panel.set_content_margin_all(10)
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_font_size("font_size", "PopupMenu", 40)
	t.set_constant("v_separation", "PopupMenu", 24)
	t.set_font_size("font_size", "ItemList", 40)
	t.set_font_size("font_size", "LineEdit", 40)
	return t


# --- Layout ------------------------------------------------------------------------------

func _build_top() -> void:
	var bar := PanelContainer.new()
	add_child(bar)
	bar.set_anchors_and_offsets_preset(PRESET_TOP_WIDE, PRESET_MODE_MINSIZE, 24)
	bar.offset_top = 70
	_top = bar
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 8)
	bar.add_child(row)
	_big(_button(row, null, "☰", _open_menu, false, Vector2(110, 110)))
	_big(_button(row, null, "↶", func(): app.undo(), false, Vector2(110, 110)))
	_big(_button(row, null, "↷", func(): app.redo(), false, Vector2(110, 110)))
	status = Label.new()
	status.size_flags_horizontal = SIZE_EXPAND_FILL
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_font_size_override(&"font_size", 26)
	status.modulate = Color(1, 1, 1, 0.75)
	row.add_child(status)


func _build_left() -> void:
	var col := _column(PRESET_TOP_LEFT, Vector2(24, 250))
	_left = col.get_parent()
	_radio(col, &"elements", [["piece", "Piece", 2], ["vertex", "Vert", 3], ["edge", "Edge", 4], ["face", "Face", 5]], func(v): app.set_elements(v))
	_rule(col)
	_radio(col, &"gizmo", [["extrude", "Move", 0], ["", "Rotate", 1]], func(v): app.set_gizmo_mode(v))
	_pivot_button = _button(col, null, "Pivot\nMedian", func(): app.cycle_pivot())
	_pivot_button.add_theme_font_size_override(&"font_size", 22)
	_rule(col)
	_toggle(col, &"add", "", "+ Add", func(on): app.add_mode = on)
	var path := _toggle(col, &"path", "", "Path", func(on): app.path_mode = on)
	path.tooltip_text = "Taps select the shortest path from the last picked vertex / edge / face"
	var sym := _toggle(col, &"sym", "", "Mirror", func(on): app.set_symmetry(on))
	sym.tooltip_text = "Mirror editing for the selected piece: unselected mirror partners follow"
	_rule(col)
	_toggle(col, &"cut", "loop_cut", "Cut", func(on): app.set_cutting(on))


func _build_right() -> void:
	var col := _column(PRESET_TOP_RIGHT, Vector2(-24, 250))
	_right = col.get_parent()
	_radio(col, &"view", [["", "3D", 0], ["", "Front", 1], ["", "Back", 2], ["", "Left", 3], ["", "Right", 4],
		["", "Top", 5], ["", "Bottom", 6]], func(v): app.set_view(v))
	_rule(col)
	_toggle(col, &"xray", "view_xray", "X-ray", func(on): app.set_xray(on))
	_toggle(col, &"wire", "view_wire", "Wire", func(on): app.set_wire(on))
	_button(col, null, "Frame", func(): app.frame_model())
	_rule(col)
	_toggle(col, &"ref", "", "Ref", func(_on): app.toggle_reference_panel())
	_grid_button = _button(col, null, "Grid\nAuto", func(): app.cycle_grid())
	_grid_button.add_theme_font_size_override(&"font_size", 22)


func _build_bottom() -> void:
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(PRESET_BOTTOM_WIDE, PRESET_MODE_MINSIZE, 24)
	box.offset_bottom = -60
	_bottom = box
	box.grow_vertical = GROW_DIRECTION_BEGIN
	box.add_theme_constant_override(&"separation", 14)
	box.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(box)
	_orbit_pad = Control.new()
	_orbit_pad.custom_minimum_size = Vector2(PAD_SIZE, PAD_SIZE)
	_orbit_pad.size_flags_horizontal = SIZE_SHRINK_END
	_orbit_pad.mouse_filter = MOUSE_FILTER_IGNORE
	_orbit_pad.draw.connect(_draw_orbit_pad)
	box.add_child(_orbit_pad)
	var actions := _panel_in(box)
	_actions_row = HBoxContainer.new()
	_actions_row.add_theme_constant_override(&"separation", 6)
	_actions_row.custom_minimum_size.y = 150
	actions.add_child(_actions_row)
	_build_sheet()


## The action bar: `ids` (fitting the selection, at most 6) + ⋯ (every operation).
func set_actions(ids: Array) -> void:
	if ids == _shown_actions:
		return
	_shown_actions = ids.duplicate()
	for c in _actions_row.get_children():
		c.queue_free()
	for id in ids.slice(0, 6):
		var spec: Array = ACTIONS[id]
		var b := _button(_actions_row, _svg(spec[0]), spec[1], func(): app.action(id), false, Vector2(150, 150))
		b.size_flags_horizontal = SIZE_EXPAND_FILL
	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	_actions_row.add_child(spacer)
	var more := _button(_actions_row, null, "⋯", _open_sheet, false, Vector2(130, 150))
	more.add_theme_font_size_override(&"font_size", 60)


## Every operation in groups, over a dimmed screen: tap one to run it (the sheet closes),
## tap outside to close.
func _build_sheet() -> void:
	_sheet = ColorRect.new()
	_sheet.color = Color(0, 0, 0, 0.45)
	_sheet.set_anchors_preset(PRESET_FULL_RECT)
	_sheet.visible = false
	# Closes when the finger lifts: closing on touch-down would let the rest of the tap
	# fall through to the model.
	_sheet.gui_input.connect(func(e):
		if e is InputEventMouseButton and not e.pressed:
			_sheet.visible = false)
	add_child(_sheet)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(PRESET_BOTTOM_WIDE, PRESET_MODE_MINSIZE, 24)
	panel.grow_vertical = GROW_DIRECTION_BEGIN
	panel.name = "SheetPanel"
	_sheet.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 10)
	panel.add_child(col)
	for group in SHEET_GROUPS:
		var title := Label.new()
		title.text = "  " + group
		title.add_theme_color_override(&"font_color", Color(0.7, 0.85, 1.0))
		col.add_child(title)
		var grid := GridContainer.new()
		grid.columns = 5
		grid.add_theme_constant_override(&"h_separation", 6)
		col.add_child(grid)
		for id in ACTIONS:
			var spec: Array = ACTIONS[id]
			if spec[2] != group:
				continue
			var action: StringName = id
			var b := _button(grid, _svg(spec[0]), spec[1], func(): _sheet.visible = false; app.action(action), false, Vector2(200, 150))
			b.size_flags_horizontal = SIZE_EXPAND_FILL


func _open_sheet() -> void:
	var panel: Control = _sheet.get_node("SheetPanel")
	panel.offset_left = _safe.position.x + 24
	panel.offset_right = -(size.x - _safe.end.x) - 24
	panel.offset_bottom = -(size.y - _safe.end.y) - 24
	_sheet.visible = true


func _build_ref_panel() -> void:
	_ref_panel = PanelContainer.new()
	_ref_panel.visible = false
	add_child(_ref_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 12)
	_ref_panel.add_child(col)
	var head := HBoxContainer.new()
	col.add_child(head)
	_ref_title = Label.new()
	_ref_title.size_flags_horizontal = SIZE_EXPAND_FILL
	_ref_title.add_theme_font_size_override(&"font_size", 36)
	head.add_child(_ref_title)
	_ref_show = CheckButton.new()
	_ref_show.text = "Show"
	_ref_show.toggled.connect(func(on): if not _ref_updating: app.ref_set("visible", on))
	head.add_child(_ref_show)
	_ref_lock = CheckButton.new()
	_ref_lock.text = "Lock"
	_ref_lock.tooltip_text = "Locked: taps on the image don't select it"
	_ref_lock.toggled.connect(func(on): if not _ref_updating: app.ref_set("locked", on))
	head.add_child(_ref_lock)
	_ref_list = ItemList.new()
	_ref_list.custom_minimum_size.y = 380
	_ref_list.item_selected.connect(func(i): app.ref_pick(_ref_paths[i]))
	col.add_child(_ref_list)
	_ref_hint = Label.new()
	_ref_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Wrapping text measures as one word per line until it has a width.
	_ref_hint.custom_minimum_size.x = 700
	_ref_hint.add_theme_font_size_override(&"font_size", 24)
	_ref_hint.modulate = Color(1, 1, 1, 0.65)
	_ref_hint.text = "Add images in the Files app: On My iPhone › M3D3 Mesh Builder › references (PNG / JPG; save HEIC photos as JPG)."
	col.add_child(_ref_hint)
	var hrow := HBoxContainer.new()
	col.add_child(hrow)
	var hl := Label.new()
	hl.text = "Height"
	hl.custom_minimum_size.x = 150
	hrow.add_child(hl)
	_ref_height = HSlider.new()
	_ref_height.min_value = 0.05
	_ref_height.max_value = 4.0
	_ref_height.step = 0.01
	_ref_height.size_flags_horizontal = SIZE_EXPAND_FILL
	_ref_height.custom_minimum_size.y = 90
	_ref_height.value_changed.connect(func(v):
		_ref_height_label.text = "%.2f m" % v
		if not _ref_updating: app.ref_set("height", v))
	hrow.add_child(_ref_height)
	_ref_height_label = Label.new()
	_ref_height_label.custom_minimum_size.x = 140
	hrow.add_child(_ref_height_label)
	_button(hrow, null, "Fit", func(): app.ref_fit(), false, Vector2(110, 90))
	var orow := HBoxContainer.new()
	col.add_child(orow)
	var ol := Label.new()
	ol.text = "Opacity"
	ol.custom_minimum_size.x = 150
	orow.add_child(ol)
	_ref_opacity = HSlider.new()
	_ref_opacity.min_value = 0.1
	_ref_opacity.max_value = 1.0
	_ref_opacity.step = 0.05
	_ref_opacity.size_flags_horizontal = SIZE_EXPAND_FILL
	_ref_opacity.custom_minimum_size.y = 90
	_ref_opacity.value_changed.connect(func(v): if not _ref_updating: app.ref_set("opacity", v))
	orow.add_child(_ref_opacity)
	var brow := HBoxContainer.new()
	col.add_child(brow)
	var adj := _button(brow, null, "Select", func(): app.ref_adjust(), false, Vector2(0, 110))
	adj.size_flags_horizontal = SIZE_EXPAND_FILL
	_button(brow, null, "Straighten", func(): app.ref_straighten(), false, Vector2(200, 110))
	_button(brow, null, "Remove", func(): app.ref_clear(), false, Vector2(170, 110))
	_button(brow, null, "Done", func(): app.toggle_reference_panel(), false, Vector2(150, 110))


## Opens / refreshes the panel for `view_name` with the image list and `ref` values.
func show_ref_panel(view_name: String, images: PackedStringArray, ref: Dictionary) -> void:
	_ref_updating = true
	_ref_title.text = "%s reference" % view_name
	_ref_paths = images
	_ref_list.clear()
	for i in images.size():
		_ref_list.add_item(images[i].get_file())
		if ref.get("path", "") == images[i]:
			_ref_list.select(i)
	_ref_hint.visible = true
	_ref_show.button_pressed = ref.get("visible", false)
	_ref_show.disabled = ref.is_empty()
	_ref_lock.button_pressed = ref.get("locked", false)
	_ref_lock.disabled = ref.is_empty()
	_ref_height.value = ref.get("height", 1.0)
	_ref_height_label.text = "%.2f m" % _ref_height.value
	_ref_opacity.value = ref.get("opacity", 0.55)
	_ref_updating = false
	_ref_panel.visible = true
	_place_ref_panel()
	_place_ref_panel.call_deferred()  # again once laid out
	set_toggle(&"ref", true)


## Bottom of the screen, full width inside the safe area, never above the top bar.
func _place_ref_panel() -> void:
	_ref_panel.anchor_left = 0.0
	_ref_panel.anchor_right = 1.0
	_ref_panel.anchor_top = 1.0
	_ref_panel.anchor_bottom = 1.0
	_ref_panel.offset_left = _safe.position.x + 24
	_ref_panel.offset_right = -(size.x - _safe.end.x) - 24
	_ref_panel.offset_bottom = -(size.y - _safe.end.y) - 24
	var room := size.y + _ref_panel.offset_bottom - (_top.position.y + _top.size.y + 20)
	_ref_panel.offset_top = _ref_panel.offset_bottom - minf(_ref_panel.get_combined_minimum_size().y, room)


func hide_ref_panel() -> void:
	_ref_panel.visible = false


func ref_panel_open() -> bool:
	return _ref_panel.visible


## A centred panel over a dimmed screen: tapping outside it closes it (on release, so
## the tap can't fall through to the model).
func _modal(panel_size: Vector2) -> PanelContainer:
	var back := ColorRect.new()
	back.color = Color(0, 0, 0, 0.45)
	back.set_anchors_preset(PRESET_FULL_RECT)
	back.visible = false
	back.gui_input.connect(func(e):
		if e is InputEventMouseButton and not e.pressed:
			back.visible = false)
	add_child(back)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = panel_size
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -panel_size.x * 0.5
	panel.offset_right = panel_size.x * 0.5
	panel.offset_top = -panel_size.y * 0.5
	panel.offset_bottom = panel_size.y * 0.5
	back.add_child(panel)
	return panel


func _open_modal(panel: Control) -> void:
	panel.get_parent().visible = true


func _close_modal(panel: Control) -> void:
	panel.get_parent().visible = false


func _build_popups() -> void:
	_menu = PopupMenu.new()
	_new_menu = PopupMenu.new()
	_new_menu.name = "New"
	_menu.add_child(_new_menu)
	_menu.add_submenu_node_item("New", _new_menu)
	_menu.add_item("Open…", 1)
	_menu.add_item("Save", 2)
	_menu.add_item("Save as…", 3)
	_menu.id_pressed.connect(_on_menu)
	_new_menu.id_pressed.connect(func(id): app.new_model(_new_menu.get_item_metadata(_new_menu.get_item_index(id))))
	add_child(_menu)
	_bone_menu = PopupMenu.new()
	add_child(_bone_menu)
	_bone_menu.id_pressed.connect(func(id): app.bone_picked(_bone_menu.get_item_metadata(_bone_menu.get_item_index(id))))
	_merge_menu = PopupMenu.new()
	for i in MERGE_ITEMS.size():
		_merge_menu.add_item(MERGE_ITEMS[i], i)
	_merge_menu.id_pressed.connect(func(id): app.merge_picked(id))
	add_child(_merge_menu)

	_open_panel = _modal(Vector2(940, 1100))
	var ob := VBoxContainer.new()
	_open_panel.add_child(ob)
	var ot := Label.new()
	ot.text = "Open a model"
	ob.add_child(ot)
	_open_list = ItemList.new()
	_open_list.size_flags_vertical = SIZE_EXPAND_FILL
	_open_list.item_activated.connect(func(i): _close_modal(_open_panel); app.open_model(_open_paths[i]))
	_open_list.item_selected.connect(func(i): _close_modal(_open_panel); app.open_model(_open_paths[i]))
	ob.add_child(_open_list)
	_button(ob, null, "Cancel", func(): _close_modal(_open_panel))

	_name_panel = _modal(Vector2(940, 380))
	var nb := VBoxContainer.new()
	_name_panel.add_child(nb)
	var nt := Label.new()
	nt.text = "Save as"
	nb.add_child(nt)
	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size.y = 110
	nb.add_child(_name_edit)
	var nr := HBoxContainer.new()
	nb.add_child(nr)
	_button(nr, null, "Save", func(): _close_modal(_name_panel); app.save_as(_name_edit.text))
	_button(nr, null, "Cancel", func(): _close_modal(_name_panel))


## The menu drops down under the top bar (clear of the Dynamic Island).
func _open_menu() -> void:
	var at := Vector2i(_top.position + Vector2(10, _top.size.y + 10))
	_menu.popup(Rect2i(at, Vector2i(560, 0)))


func _on_menu(id: int) -> void:
	match id:
		1: _show_open()
		2: app.save()
		3: _show_name()


# --- Called by the builder ----------------------------------------------------------------

func set_plans(plans: Array) -> void:
	_new_menu.clear()
	for i in plans.size():
		_new_menu.add_item(BodyPlan.find(plans[i]).display_name(), i)
		_new_menu.set_item_metadata(i, plans[i])


func show_bones(bones: Array) -> void:
	_bone_menu.clear()
	for i in bones.size():
		_bone_menu.add_item(String(bones[i]), i)
		_bone_menu.set_item_metadata(i, bones[i])
	_bone_menu.popup(Rect2i(Vector2i(200, 500), Vector2i(600, 0)))


## Blender's Merge menu, just above the action bar. First / Last need vertices picked
## one by one (selection order).
func show_merge_menu(order_known: bool) -> void:
	for i in [1, 2]:
		_merge_menu.set_item_disabled(i, not order_known)
	_merge_menu.reset_size()
	var h := _merge_menu.get_contents_minimum_size().y
	var at := Vector2i(int(_bottom.position.x), int(_bottom.position.y - h - 20))
	_merge_menu.popup(Rect2i(at, Vector2i(620, 0)))


func _show_open() -> void:
	_open_paths = app.model_files()
	_open_list.clear()
	for p in _open_paths:
		_open_list.add_item(("📱 " if p.begins_with("user://") else "🖥 ") + p.get_file().get_basename())
	_open_modal(_open_panel)


func _show_name() -> void:
	_name_edit.text = app.model_name()
	_open_modal(_name_panel)
	_name_edit.grab_focus()


func select(group: StringName, value: int) -> void:
	for v in _groups.get(group, {}):
		_groups[group][v].set_pressed_no_signal(v == value)


func set_toggle(name_key: StringName, on: bool) -> void:
	if _toggles.has(name_key):
		_toggles[name_key].set_pressed_no_signal(on)


## Touches starting here orbit (the builder checks; the pad is not a UI panel).
func on_orbit_pad(pos: Vector2) -> bool:
	return _orbit_pad.is_visible_in_tree() \
		and _orbit_pad.get_global_rect().get_center().distance_to(pos) <= PAD_SIZE * 0.5 + 10.0


func _draw_orbit_pad() -> void:
	var c := _orbit_pad.size * 0.5
	var r := PAD_SIZE * 0.5 - 4.0
	_orbit_pad.draw_circle(c, r, BG)
	_orbit_pad.draw_arc(c, r, 0.0, TAU, 48, Color(ACCENT, 0.6), 4.0, true)
	_orbit_pad.draw_arc(c, r * 0.42, PI * 0.15, PI * 1.85, 32, Color(1, 1, 1, 0.55), 5.0, true)
	for k in 4:
		var d := Vector2.from_angle(k * PI * 0.5)
		var n := Vector2(-d.y, d.x)
		var tip := c + d * (r - 14.0)
		_orbit_pad.draw_colored_polygon(PackedVector2Array([tip, tip - d * 26.0 + n * 18.0, tip - d * 26.0 - n * 18.0]), Color(1, 1, 1, 0.55))


func set_pivot_visible(on: bool) -> void:
	_pivot_button.visible = on


func set_pivot_text(text: String) -> void:
	_pivot_button.text = text


func set_grid_text(text: String) -> void:
	_grid_button.text = text


# --- Widgets -----------------------------------------------------------------------------

func _panel_in(parent: Control) -> PanelContainer:
	var p := PanelContainer.new()
	parent.add_child(p)
	return p


func _column(preset: LayoutPreset, offset: Vector2) -> VBoxContainer:
	var p := PanelContainer.new()
	add_child(p)
	p.set_anchors_and_offsets_preset(preset, PRESET_MODE_MINSIZE)
	if preset == PRESET_TOP_RIGHT:
		p.grow_horizontal = GROW_DIRECTION_BEGIN
		p.offset_right = offset.x
		p.offset_left = offset.x - p.get_combined_minimum_size().x
	else:
		p.offset_left = offset.x
	p.offset_top = offset.y
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 4)
	p.add_child(col)
	return col


func _rule(parent: Control) -> void:
	var r := ColorRect.new()
	r.color = Color(1, 1, 1, 0.1)
	r.custom_minimum_size = Vector2(0, 2)
	r.mouse_filter = MOUSE_FILTER_IGNORE
	parent.add_child(r)


## [icon, label, value] buttons, one pressed at a time.
func _radio(parent: Control, group: StringName, specs: Array, fn: Callable) -> void:
	var bg := ButtonGroup.new()
	_groups[group] = {}
	for s in specs:
		var b := _button(parent, _svg(s[0]) if s[0] != "" else null, s[1], Callable(), true)
		b.button_group = bg
		var v: int = s[2]
		b.pressed.connect(func(): fn.call(v))
		_groups[group][v] = b


func _toggle(parent: Control, name_key: StringName, icon: String, text: String, fn: Callable, size := Vector2(150, 120)) -> Button:
	var b := _button(parent, _svg(icon) if icon != "" else null, text, Callable(), true, size)
	b.toggled.connect(fn)
	_toggles[name_key] = b
	return b


func _button(parent: Control, icon: Texture2D, text: String, fn: Callable, toggle := false, size := Vector2(150, 120)) -> Button:
	var b := Button.new()
	b.toggle_mode = toggle
	b.focus_mode = FOCUS_NONE
	b.custom_minimum_size = size
	b.text = text
	b.add_theme_font_size_override(&"font_size", 24 if icon else 30)
	if icon:
		b.icon = icon
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.expand_icon = false
	if fn.is_valid():
		b.pressed.connect(fn)
	parent.add_child(b)
	return b


## Top-bar glyph buttons: bigger text.
func _big(b: Button) -> Button:
	b.add_theme_font_size_override(&"font_size", 56)
	return b


func _svg(icon_name: String) -> Texture2D:
	if icon_name == "":
		return null
	var path := ICON_DIR + icon_name + ".svg"
	if not FileAccess.file_exists(path):
		return null
	var image := Image.new()
	if image.load_svg_from_string(FileAccess.get_file_as_string(path), 3.6) != OK:
		return null
	return ImageTexture.create_from_image(image)

