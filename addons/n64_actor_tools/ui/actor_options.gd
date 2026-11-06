@tool
extends VBoxContainer
## Tool options for the active actor tool, at the top of the inspector (built by
## actor_inspector.gd on each inspector refresh; tool changes rebuild it, edits refresh
## the values in place).

const ActorEditor := preload("res://addons/n64_actor_tools/actor_editor.gd")
const Tool := ActorEditor.Tool

const ACCENT := Color(0.55, 0.9, 0.55)
const HINT := Color(1, 1, 1, 0.55)

var editor: ActorEditor
## Value refreshers run after every edit: [Callable].
var _refreshers: Array[Callable] = []
var _updating := false


func _init(e: ActorEditor) -> void:
	editor = e
	add_theme_constant_override(&"separation", 4)
	var m := editor.model
	_title(ActorEditor.NAMES[editor.tool])
	var info := _hint("")
	_refreshers.append(func():
		var b := editor.budget()
		info.text = "%s · %d bones · %.2f m · %d / %d tris · %d textures (%.1f KB)" % [m.name, m.bones.size(),
			m.height(), b.tris, b.budget, b.textures, b.kb]
		info.add_theme_color_override(&"font_color", Color(1, 0.55, 0.45) if b.over else HINT))
	match editor.tool:
		Tool.BODY:
			_body_options()
		Tool.POSE:
			_pose_options()
		Tool.PIECE:
			_piece_options()
		Tool.VERTEX, Tool.EDGE, Tool.FACE:
			_element_options()
		Tool.LOOP_CUT:
			_hint("Hover an edge: the yellow line shows the loop. Press and drag to slide it along the edges, release to cut. Esc or right click cancels; hold %s to slide in quarters." % ("Cmd" if OS.get_name() == "macOS" else "Ctrl"))
			var cuts := _slider("Cuts", 1, 6, 1, "")
			cuts.tooltip_text = "Loops per cut: more than one are spaced evenly (no slide)."
			cuts.value_changed.connect(func(v): editor.cut_count = int(v))
			add_child(cuts)
			_refreshers.append(func(): cuts.set_value_no_signal(editor.cut_count))
			_hint("Loops stop at triangles / n-gons and open edges. A cut around a tube adds a ring (it stays a tube); other cuts turn the piece into a plain mesh.")
		Tool.TEXTURE:
			_texture_row(&"texture", "Texture")
			_mirror_paint()
		Tool.OVERLAY:
			_texture_row(&"overlay", "Overlay")
			_hint("Shows where the overlay mask is painted (Overlay Mask tool).")
			_mirror_paint()
		Tool.COLOR_FILL:
			_color_row()
			_mirror_paint()
		Tool.COLOR_BRUSH:
			_color_row()
			_enum_row("Blend", ["Mix", "Multiply", "Lighten", "Darken"], &"blend")
			_brush_rows()
		Tool.MASK_BRUSH:
			_brush_rows()
		Tool.UV:
			_uv_options()
	var rule := HSeparator.new()
	add_child(rule)
	_refresh()


func _enter_tree() -> void:
	if not editor.refreshed.is_connected(_refresh):
		editor.refreshed.connect(_refresh)


func _exit_tree() -> void:
	if editor.refreshed.is_connected(_refresh):
		editor.refreshed.disconnect(_refresh)


func _refresh() -> void:
	if editor.model == null or not is_instance_valid(editor.model) or editor.model.data == null:
		return
	_updating = true
	for r in _refreshers:
		r.call()
	_updating = false


# --- Per tool ------------------------------------------------------------------------------

func _body_options() -> void:
	var m := editor.model
	var plan := OptionButton.new()
	var ids := BodyPlan.all().keys()
	ids.sort()
	for i in ids.size():
		plan.add_item(BodyPlan.find(ids[i]).display_name())
		plan.set_item_metadata(i, ids[i])
	plan.item_selected.connect(func(i): if not _updating: editor.set_plan(plan.get_item_metadata(i)))
	_row("Body plan", plan)
	_refreshers.append(func():
		for i in plan.item_count:
			if plan.get_item_metadata(i) == m.data.plan:
				plan.select(i))
	_section("Proportions")
	var grid := VBoxContainer.new()
	add_child(grid)
	var built := [&""]
	var sliders := {}
	_refreshers.append(func():
		var bp := BodyPlan.find(m.data.plan)
		if bp == null:
			return
		var values := bp.resolve(m.data.proportions)
		if built[0] != m.data.plan:
			built[0] = m.data.plan
			sliders.clear()
			for c in grid.get_children():
				c.queue_free()
			for p in bp.params():
				var s := _slider(String(p.name).capitalize(), p.min, p.max, p.step, "")
				grid.add_child(s)
				var key: StringName = p.name
				s.value_changed.connect(func(v): if not _updating: editor.set_proportion(key, v))
				sliders[key] = s
		for k in sliders:
			sliders[k].set_value_no_signal(values[k]))
	_section("Budget")
	var budget := _slider("Triangle budget", 50, 4000, 10, " tris")
	add_child(budget)
	budget.value_changed.connect(func(v): if not _updating: editor.set_data(&"tri_budget", int(v)))
	_refreshers.append(func(): budget.set_value_no_signal(m.data.tri_budget))


func _pose_options() -> void:
	var m := editor.model
	_hint("Drag bone ends to aim, big handles for hands / feet (IK) and the hips (body).")
	_data_slider("Angle snap", 0.0, 45.0, 0.5, "°", &"angle_step")
	_data_slider("Grid snap", 0.0, 0.25, 0.005, " m", &"grid")
	var follow := CheckBox.new()
	follow.text = "Hands / feet follow the limb"
	follow.tooltip_text = "On: dragging an IK disc keeps the hand / foot at the same angle to the forearm / shin.\nOff: it keeps pointing the same way in the world (e.g. a foot staying flat).\nPinned limbs always stay as they are."
	follow.toggled.connect(func(on): if not _updating: editor.set_data(&"ik_end_follows", on, "IK Follow"))
	add_child(follow)
	_refreshers.append(func(): follow.set_pressed_no_signal(m.data.ik_end_follows))
	_section("Rotate bone")
	_hint("Click a dot / disc to pick its bone (the hand / foot disc picks the hand / foot), or pick one here.")
	var bone := OptionButton.new()
	for i in m.bones.size():
		bone.add_item(String(m.bones[i].name))
	bone.item_selected.connect(func(i): m.sel_bone = i; _refresh())
	_row("Bone", bone)
	var axes: Array[EditorSpinSlider] = []
	for spec in [["Bend X", "Bend forward / back"], ["Twist", "Roll around the bone's length"], ["Bend Z", "Bend sideways"]]:
		var s := _slider(spec[0], -180.0, 180.0, 0.5, "°")
		s.tooltip_text = spec[1]
		add_child(s)
		axes.append(s)
	for k in 3:
		axes[k].value_changed.connect(func(_v):
			if _updating or m.sel_bone < 0:
				return
			editor.rotate_bone(m.sel_bone, Vector3(axes[0].value, axes[1].value, axes[2].value)))
	var buttons := HBoxContainer.new()
	add_child(buttons)
	_button(buttons, "Reset bone", func(): editor.reset_bone(m.sel_bone))
	_refreshers.append(func():
		var has := m.sel_bone >= 0 and m.sel_bone < m.bones.size()
		bone.select(m.sel_bone if has else -1)
		var e := m.bone_euler(m.sel_bone) if has else Vector3.ZERO
		for k in 3:
			axes[k].read_only = not has
			axes[k].set_value_no_signal(e[k]))
	_section("Preview props")
	_hint("Shown in the hand while you pose / animate; the game attaches items with ActorSockets. Rotate the prop bone (its dot, or pick it above) to shift the grip.")
	for prop in m.prop_bones():
		var pick := EditorResourcePicker.new()
		pick.base_type = "PackedScene"
		var key: StringName = prop
		pick.resource_changed.connect(func(r): if not _updating: editor.set_preview_prop(key, r))
		_row(String(prop), pick)
		_refreshers.append(func(): pick.edited_resource = m.data.preview_props.get(key))
	if m.prop_bones().is_empty():
		_hint("This body plan has no prop bones.")
	_section("Pinned limbs (stay planted)")
	var pins := VBoxContainer.new()
	add_child(pins)
	for c in m.chains:
		var cb := CheckBox.new()
		cb.text = String(c.name).capitalize()
		var chain: StringName = c.name
		cb.toggled.connect(func(on): if not _updating: editor.set_pin(chain, on))
		pins.add_child(cb)
		_refreshers.append(func(): cb.set_pressed_no_signal(m.data.pins.get(chain, false)))


func _piece_options() -> void:
	var m := editor.model
	var in_blender := editor.geometry_locked()
	_selection_label()
	if in_blender:
		_blender_options()
	_data_slider("Grid snap", 0.0, 0.1, 0.0025, " m", &"model_grid")
	if not in_blender:
		_new_piece_options()
	_selected_piece_options()


## Character editor v2: the .blend that owns the geometry.
func _blender_options() -> void:
	var m := editor.model
	_section("Blender")
	_hint("Geometry is edited in %s: save there and it updates here (paint follows the faces). Stitching, pins and paint are set here." % m.data.blend_file)
	var row := HBoxContainer.new()
	add_child(row)
	_button(row, "Edit in Blender", func(): editor.plugin.blender.open_blender(m))
	_button(row, "Pull now", func(): editor.plugin.blender.pull(m))
	_button(row, "Unlink", func(): editor.plugin.blender.unlink(m)).tooltip_text = "Back to the built-in modelling tools with the geometry as it is now (the .blend stays)."
	var fit := CheckBox.new()
	fit.text = "Skeleton follows the geometry"
	fit.tooltip_text = "After each edit in Blender, fit the body proportions to the pieces' lengths along their bones (the meshes stay put). Off: bones change only from the Body tool."
	fit.toggled.connect(func(on): if not _updating: editor.set_data(&"blend_fit", on, "Skeleton Follows Geometry"))
	add_child(fit)
	_refreshers.append(func(): fit.set_pressed_no_signal(m.data.blend_fit))
	var problems := _hint("")
	problems.add_theme_color_override(&"font_color", Color(1, 0.6, 0.5))
	_refreshers.append(func():
		var lines := PackedStringArray()
		for issue: Dictionary in editor.plugin.blender.issues:
			lines.append("• %s%s" % ["%s: " % issue.object if issue.object != "" else "", issue.message])
		problems.text = "\n".join(lines)
		problems.visible = not lines.is_empty())


func _new_piece_options() -> void:
	var m := editor.model
	_section("New piece")
	var bone := OptionButton.new()
	bone.tooltip_text = "Bone for Add tube / Add box / Copy to bone (toolbar)"
	for b: BodyPlan.Bone in m.bones:
		if b.side == 1:
			continue
		bone.add_item(String(b.name))
		bone.set_item_metadata(bone.item_count - 1, b.name)
	bone.item_selected.connect(func(i): editor.piece_bone = bone.get_item_metadata(i))
	_row("Bone", bone)
	# Follows the selected piece's bone when the selection changes; a pick here sticks
	# until then.
	var followed := [-2]
	_refreshers.append(func():
		var want := editor.piece_bone
		if followed[0] != m.sel_piece:
			followed[0] = m.sel_piece
			if editor.piece():
				want = editor.piece().bone
		for i in bone.item_count:
			if bone.get_item_metadata(i) == want:
				bone.select(i)
		if bone.selected >= 0:
			editor.piece_bone = bone.get_item_metadata(bone.selected))


func _selected_piece_options() -> void:
	var m := editor.model
	_section("Selected piece")
	var props := VBoxContainer.new()
	add_child(props)
	var none := _hint("Click a piece in the viewport.")
	var mirror := CheckBox.new()
	mirror.text = "Mirror"
	mirror.tooltip_text = "Left pieces build the right side; centre pieces stay symmetric.\nTurning it off splits the right side into its own piece."
	mirror.toggled.connect(func(on): if not _updating: editor.set_piece_mirror(on))
	mirror.visible = not editor.geometry_locked()
	props.add_child(mirror)
	var rigid := CheckBox.new()
	rigid.text = "Rigid joint"
	rigid.tooltip_text = "Rigid: the piece moves with its bone only. Off: stitched to the parent."
	rigid.toggled.connect(func(on): if not _updating: editor.set_rigid(on))
	props.add_child(rigid)
	var stitch_to := OptionButton.new()
	stitch_to.tooltip_text = "Bone the joint end stitches to (an ancestor skips bones without a piece, e.g. clavicle -> chest)"
	stitch_to.item_selected.connect(func(i): if not _updating: editor.set_stitch(&"stitch_to", stitch_to.get_item_metadata(i)))
	_row("Stitch to", stitch_to, props)
	var weight := OptionButton.new()
	for w in ["Rigid (0%)", "Soft (50%)", "Mostly body (75%)", "Glued (100%)"]:
		weight.add_item(w)
	weight.tooltip_text = "How much the joint end follows the stitch-to bone (Glued = N64 style)."
	weight.item_selected.connect(func(i): if not _updating: editor.set_stitch(&"stitch_weight", [0.0, 0.5, 0.75, 1.0][i]))
	_row("Stitch", weight, props)
	var rings := _slider("Blend over", 1, 4, 1, " rings")
	rings.tooltip_text = "Tubes: blend the stitch over this many rings (sleeves, skirts)"
	rings.value_changed.connect(func(v): if not _updating: editor.set_stitch(&"stitch_rings", int(v)))
	props.add_child(rings)
	_refreshers.append(func():
		var p := editor.piece()
		props.visible = p != null
		none.visible = p == null
		if p == null:
			return
		mirror.set_pressed_no_signal(p.mirror)
		rigid.set_pressed_no_signal(m.data.rigid_joints.get(p.bone, false))
		stitch_to.clear()
		stitch_to.add_item("Parent bone")
		stitch_to.set_item_metadata(0, &"")
		var bi := m.bone_index(p.bone)
		var anc := m.skeleton.get_bone_parent(bi) if bi >= 0 else -1
		while anc >= 0:
			stitch_to.add_item(String(m.bones[anc].name))
			stitch_to.set_item_metadata(stitch_to.item_count - 1, m.bones[anc].name)
			if m.bones[anc].name == p.stitch_to:
				stitch_to.select(stitch_to.item_count - 1)
			anc = m.skeleton.get_bone_parent(anc)
		if p.stitch_to == &"":
			stitch_to.select(0)
		weight.select(0 if p.stitch_weight < 0.25 else (1 if p.stitch_weight < 0.6 else (2 if p.stitch_weight < 0.9 else 3)))
		rings.set_value_no_signal(p.stitch_rings)
		rings.read_only = not p.is_tube())
	_pin_hint()


func _element_options() -> void:
	_selection_label()
	_hint("Click / box-drag to select (Shift adds, %s+click selects the shortest path, L picks the piece under the mouse, A all, Alt+A none). Drag the big handle to move, ring handles on tubes." % ("Cmd" if OS.get_name() == "macOS" else "Ctrl"))
	_data_slider("Grid snap", 0.0, 0.1, 0.0025, " m", &"model_grid")
	var step := _slider("Scale step", 1.01, 2.0, 0.01, "×")
	step.tooltip_text = "Scale up / down (toolbar) multiplies by this"
	step.value_changed.connect(func(v): editor.scale_step = v)
	add_child(step)
	_refreshers.append(func(): step.set_value_no_signal(editor.scale_step))
	_hint("Inflate / deflate and extrude move one / two grid steps; twist uses the angle snap (Pose).")
	_pin_hint()


func _uv_options() -> void:
	_selection_label()
	_hint("Click / box-drag faces (Shift adds; nothing picked = whole piece).")
	_section("Textures for the selection")
	_texture_row(&"texture", "Texture")
	_texture_row(&"overlay", "Overlay")
	_section("Move texture")
	var pad := GridContainer.new()
	pad.columns = 4
	add_child(pad)
	for spec in [["←", Vector4(-1, 0, 1, 0)], ["→", Vector4(1, 0, 1, 0)], ["↑", Vector4(0, -1, 1, 0)], ["↓", Vector4(0, 1, 1, 0)]]:
		var d: Vector4 = spec[1]
		_button(pad, spec[0], func(): editor.uv_nudge(Vector4(d.x * editor.uv_step, d.y * editor.uv_step, 1, 0)))
	_button(pad, "Scale +", func(): editor.uv_nudge(Vector4(0, 0, 2, 0)))
	_button(pad, "Scale −", func(): editor.uv_nudge(Vector4(0, 0, 0.5, 0)))
	var step := _slider("Move step", 0.015625, 0.5, 0.015625, "")
	step.value_changed.connect(func(v): editor.uv_step = v)
	add_child(step)
	_refreshers.append(func(): step.set_value_no_signal(editor.uv_step))

	_section("Swap slots (eyes, mouth)")
	var m := editor.model
	var new_row := HBoxContainer.new()
	add_child(new_row)
	var slot_name := LineEdit.new()
	slot_name.placeholder_text = "new slot, e.g. eyes"
	slot_name.size_flags_horizontal = SIZE_EXPAND_FILL
	new_row.add_child(slot_name)
	_button(new_row, "Add slot", func(): editor.add_slot(slot_name.text); slot_name.clear())
	var slot := OptionButton.new()
	slot.item_selected.connect(func(i): editor.slot = slot.get_item_metadata(i))
	_row("Slot", slot)
	var frame := N64TexturePicker.new()
	frame.edited_resource = editor.frame_texture
	frame.resource_changed.connect(func(r): editor.frame_texture = r)
	var frame_row := HBoxContainer.new()
	add_child(frame_row)
	_row("New frame", frame, frame_row)
	_button(frame_row, "Add", func(): editor.add_frame())
	var preview := _slider("Preview frame", 0, 16, 1, "")
	preview.value_changed.connect(func(v): editor.show_frame(int(v)))
	add_child(preview)
	_refreshers.append(func():
		slot.clear()
		for key in m.data.swap_slots:
			slot.add_item("%s (%d frames)" % [key, m.data.swap_slots[key].size()])
			slot.set_item_metadata(slot.item_count - 1, StringName(key))
			if StringName(key) == editor.slot:
				slot.select(slot.item_count - 1)
		if slot.selected < 0 and slot.item_count > 0:
			slot.select(0)
		editor.slot = slot.get_item_metadata(slot.selected) if slot.selected >= 0 else &""
		preview.set_value_no_signal(editor.preview_frame))


# --- Shared rows ---------------------------------------------------------------------------

func _selection_label() -> void:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(l)
	_refreshers.append(func(): l.text = editor.selection_text())


func _pin_hint() -> void:
	var l := _hint("")
	_refreshers.append(func():
		l.text = "Pin: click the piece to pin to…" if editor.pin_picking else ""
		l.add_theme_color_override(&"font_color", Color(1, 0.8, 0.3))
		l.visible = editor.pin_picking)


func _texture_row(prop: StringName, label: String) -> void:
	var pick := N64TexturePicker.new()
	pick.edited_resource = editor.get(prop)
	pick.resource_changed.connect(func(r): editor.set(prop, r))
	_row(label, pick)


func _color_row() -> void:
	var c := ColorPickerButton.new()
	c.color = editor.color
	c.custom_minimum_size = Vector2(60, 24)
	c.color_changed.connect(func(v): editor.color = v)
	_row("Colour", c)


func _brush_rows() -> void:
	var strength := _slider("Strength", 0.05, 1.0, 0.05, "")
	strength.value_changed.connect(func(v): editor.strength = v)
	add_child(strength)
	var radius := _slider("Radius", 4, 200, 1, " px")
	radius.value_changed.connect(func(v): editor.radius = v)
	add_child(radius)
	_refreshers.append(func():
		strength.set_value_no_signal(editor.strength)
		radius.set_value_no_signal(editor.radius))
	_hint("Shift erases.")
	_mirror_paint()


func _mirror_paint() -> void:
	var cb := CheckBox.new()
	cb.text = "Mirror on centre pieces"
	cb.button_pressed = editor.mirror_paint
	cb.toggled.connect(func(on): editor.mirror_paint = on)
	add_child(cb)


func _enum_row(label: String, items: Array, prop: StringName) -> void:
	var o := OptionButton.new()
	for it in items:
		o.add_item(it)
	o.select(editor.get(prop))
	o.item_selected.connect(func(i): editor.set(prop, i))
	_row(label, o)


## A slider bound to an ActorModelData property (undoable).
func _data_slider(label: String, lo: float, hi: float, step: float, suffix: String, prop: StringName) -> void:
	var s := _slider(label, lo, hi, step, suffix)
	s.value_changed.connect(func(v): if not _updating: editor.set_data(prop, v))
	add_child(s)
	_refreshers.append(func(): s.set_value_no_signal(editor.model.data.get(prop)))


func _slider(label: String, lo: float, hi: float, step: float, suffix: String) -> EditorSpinSlider:
	var s := EditorSpinSlider.new()
	s.label = label
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.suffix = suffix
	s.size_flags_horizontal = SIZE_EXPAND_FILL
	return s


func _row(label: String, control: Control, parent: Control = self) -> HBoxContainer:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 80 * EditorInterface.get_editor_scale()
	h.add_child(l)
	control.size_flags_horizontal = SIZE_EXPAND_FILL
	if control is OptionButton:
		control.fit_to_longest_item = false
		control.clip_text = true
	h.add_child(control)
	parent.add_child(h)
	return h


func _button(parent: Control, text: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(fn)
	parent.add_child(b)
	return b


func _title(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override(&"font_size", int(15 * EditorInterface.get_editor_scale()))
	l.add_theme_color_override(&"font_color", ACCENT)
	add_child(l)


func _section(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override(&"font_color", Color(0.7, 0.85, 1.0))
	add_child(l)


func _hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 120
	l.add_theme_color_override(&"font_color", HINT)
	add_child(l)
	return l
