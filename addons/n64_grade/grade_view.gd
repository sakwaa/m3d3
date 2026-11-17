@tool
extends VBoxContainer
## The Grade screen (DESIGN.md): the open zone seen through a Grade camera (the edited
## scene's own world, so it's always the live level; no gizmos, nothing selectable), its
## layer tree with filter stacks (zone / group / texture / variant), view modes (colour /
## grey / value groups, game output), the time key switcher, Measure and a reference picture.
##
## Filters: each texture the zone shows is run through its chain (GradeProcessor, worker
## threads) whenever a filter changes, and the level shows the result in its place
## (LevelRoot.grade_textures; the 3D editor shows it too). Nothing is written to textures.
##
## View: right-drag looks around (WASD / QE fly, Shift faster), middle-drag orbits,
## Shift + middle-drag pans, wheel zooms, left-click selects the surface's layer, F frames
## the selected layer.
##
## Paint (toolbar, or P): the left button paints instead, through the level plugin's paint
## tool (grade_paint_input): the Paint panel's tool and settings, its face mask (Cmd / Ctrl
## + click), undo. Pick Painted colour or an overlay layer in the tree to paint it.

const HIGHLIGHT_LAYER := 1 << 22  # (seen only by the Grade camera)
const VideoOut := preload("res://addons/n64_runtime/post/n64_video_out.gd")

var _level: LevelRoot
var _data: LevelData
var _nodes: Array = []

var _tree: Tree
var _container: SubViewportContainer
var _vp: SubViewport
var _cam: Camera3D
var _highlight: MeshInstance3D
var _view_mode: OptionButton
var _game_out: CheckBox
var _keys_box: HBoxContainer
var _grid_btn: CheckButton
var _game_btn: CheckButton
var _hour: HSlider
var _hour_label: Label
var _level_label: Label
var _info: Label
var _ref_rect: TextureRect
var _ref_label: Label
var _hist: TextureRect
var _stats: Label
var _status: Label

var _compositor: Compositor
var _effect: CompositorEffect
var _ref_path := ""
# Area of the reference picture to read (image pixels; empty = all), dragged on it.
var _ref_area := Rect2i()
var _ref_drag := Vector2(-1, -1)

# Camera: orbit about `_pivot` at `_dist`, looking along yaw / pitch.
var _pivot := Vector3.ZERO
var _dist := 20.0
var _yaw := 0.0
var _pitch := -0.4
var _drag := 0  # 0 none, 1 look, 2 orbit, 3 pan
var _selected_ids := PackedInt32Array()
var _rebuild_queued := false

# Selection: [kind, key, filter, name] of the selected tree node (survives tree rebuilds).
var _sel: Array = []
var _sel_node := {}
var _filters_on: CheckButton
var _filter_head: HBoxContainer
var _filter_box: VBoxContainer
var _add_menu: MenuButton
var _migrate: Button
var _panel_key: Variant = null
var _panel_sig := ""

# Processing: base texture -> RGBA8 source image; entry -> applied chain signature / texture.
var _src := {}
var _applied := {}
var _graded := {}
var _pretinted := {}
# Textures drawn outside the texture list (GradeLayers.extra_textures): texture ->
# [graded, pretinted] / applied signature.
var _plain := {}
var _plain_applied := {}
var _dirty := false
var _task := -1
var _jobs: Array = []
var _results: Array = []
var _paint_btn: CheckButton
# Decals: placing (click a surface), the selected one, a drag in progress.
var _decal_place := false
var _place_tex: Texture2D
var _sel_decal: LevelDecal
var _decal_drag := false
var _edit_shared := false
var _edit_target: OptionButton
var _shared_box: VBoxContainer
var _shared_save_queued := false
var _always: Label
var _time_label: Label
var _overlay: Control
var _variant_btn: Button
var _vertex_sig := "-"
var _fold_sig := ""
var _vertex_task := -1
var _vertex_out := {}


func _ready() -> void:
	size_flags_vertical = SIZE_EXPAND_FILL
	_build_toolbar()
	var split := HSplitContainer.new()
	split.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(split)
	_tree = Tree.new()
	_tree.custom_minimum_size.x = 240
	_tree.columns = 2
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 60)
	_tree.hide_root = true
	_tree.item_selected.connect(_on_tree_selected)
	_tree.button_clicked.connect(_on_tree_button)
	split.add_child(_tree)
	var split2 := HSplitContainer.new()
	split2.size_flags_horizontal = SIZE_EXPAND_FILL
	split.add_child(split2)
	_container = SubViewportContainer.new()
	_container.stretch = true
	_container.size_flags_horizontal = SIZE_EXPAND_FILL
	_container.focus_mode = Control.FOCUS_CLICK
	_container.gui_input.connect(_on_view_input)
	var stack := Control.new()
	stack.size_flags_horizontal = SIZE_EXPAND_FILL
	stack.clip_contents = true
	split2.add_child(stack)
	_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stack.add_child(_container)
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.draw.connect(_draw_overlay)
	stack.add_child(_overlay)
	_vp = SubViewport.new()
	_vp.msaa_3d = Viewport.MSAA_2X
	_vp.handle_input_locally = false
	_container.add_child(_vp)
	_cam = Camera3D.new()
	_cam.fov = 50.0
	_cam.far = 4000.0
	_cam.cull_mask = 0xFFFFF | HIGHLIGHT_LAYER
	_vp.add_child(_cam)
	_highlight = MeshInstance3D.new()
	_highlight.layers = HIGHLIGHT_LAYER
	_highlight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vp.add_child(_highlight)
	split2.add_child(_build_side())
	_status = Label.new()
	_status.add_theme_font_size_override(&"font_size", 11)
	add_child(_status)
	_apply_view_mode()
	_update_camera()
	EditorInterface.get_editor_undo_redo().version_changed.connect(_on_history)


func _build_toolbar() -> void:
	# (Wraps onto more rows when the screen is too narrow for it all.)
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override(&"v_separation", 4)
	add_child(bar)
	_level_label = Label.new()
	_level_label.text = "No level"
	bar.add_child(_level_label)
	bar.add_child(VSeparator.new())
	_view_mode = OptionButton.new()
	for t in ["Colour", "Greyscale", "3 value groups", "5 value groups"]:
		_view_mode.add_item(t)
	_view_mode.tooltip_text = "How the view shows the zone (changes nothing). Value groups: light posterised into\n3 or 5 flat greys (equal steps of screen grey): areas that should read apart but share a grey merge."
	_view_mode.item_selected.connect(func(_i): _apply_view_mode())
	bar.add_child(_view_mode)
	_game_out = CheckBox.new()
	_game_out.text = "Game output"
	_game_out.tooltip_text = "The game's video output on the view: 16-bit colour, dither and the VI's soften."
	_game_out.toggled.connect(func(_on): _apply_view_mode())
	bar.add_child(_game_out)
	_filters_on = CheckButton.new()
	_filters_on.text = "Filters"
	_filters_on.button_pressed = true
	_filters_on.tooltip_text = "Off: the zone as authored (before / after)."
	_filters_on.toggled.connect(func(_on):
		_applied.clear()
		_queue_process())
	bar.add_child(_filters_on)
	bar.add_child(VSeparator.new())
	var tl := Label.new()
	tl.text = "Time"
	bar.add_child(tl)
	_time_label = tl
	_always = Label.new()
	_always.text = "Always (one lighting)"
	_always.tooltip_text = "This zone's lighting has no time of day (Baked Vertex / Baked Vertex Dynamic / Dynamic):\none grade for all times; light filters' Keys and per-key AO don't apply."
	_always.visible = false
	bar.add_child(_always)
	_keys_box = HBoxContainer.new()
	bar.add_child(_keys_box)
	_hour = HSlider.new()
	_hour.min_value = 0.0
	_hour.max_value = 24.0
	_hour.step = 0.25
	_hour.custom_minimum_size.x = 140
	_hour.size_flags_vertical = SIZE_SHRINK_CENTER
	_hour.tooltip_text = "Preview hour (the baked light keys blend as in game). Shared with the Paint panel's Preview hour."
	_hour.value_changed.connect(_set_hour)
	bar.add_child(_hour)
	_hour_label = Label.new()
	_hour_label.custom_minimum_size.x = 44
	bar.add_child(_hour_label)
	bar.add_child(VSeparator.new())
	var measure := Button.new()
	measure.text = "Measure"
	measure.tooltip_text = "Reads the view's values: darks / mids / lights (10th / 50th / 90th percentile lightness,\nLab L), spread (readable daytime ~50-60; under 30 reads flat) and key."
	measure.pressed.connect(_measure)
	bar.add_child(measure)
	var match_cam := Button.new()
	match_cam.text = "Match editor view"
	match_cam.tooltip_text = "Puts the Paint camera where the 3D editor's camera is.\nMove here: trackpad two-finger drag orbits, Shift + two-finger pans, pinch or Cmd + two-finger zooms;\nAlt + drag orbits, Alt + Shift + drag pans; middle drag orbits, Shift + middle pans, wheel zooms;\nhold right mouse + WASD / QE flies; F frames the selection."
	match_cam.pressed.connect(match_editor_camera)
	bar.add_child(match_cam)
	_edit_target = OptionButton.new()
	_edit_target.add_item("Edit: this zone")
	_edit_target.add_item("Edit: shared grade")
	_edit_target.tooltip_text = "This zone: filters only this zone gets (on top of the shared grade).\nShared grade: the filters every zone using it gets (saved to its file)."
	_edit_target.visible = false
	_edit_target.item_selected.connect(func(i):
		_edit_shared = i == 1
		_panel_key = null
		_panel_sig = ""
		_rebuild_tree())
	bar.add_child(_edit_target)
	_paint_btn = CheckButton.new()
	_paint_btn.text = "Paint"
	_paint_btn.tooltip_text = "P: the left button paints (the Paint panel's tool and settings) instead of picking layers.\nPick Painted colour or an overlay layer in the tree to paint it; Cmd / Ctrl + click edits the face mask."
	_paint_btn.toggled.connect(func(_on): _overlay.queue_redraw())
	bar.add_child(_paint_btn)
	_grid_btn = CheckButton.new()
	_grid_btn.text = "Grid"
	_grid_btn.tooltip_text = "The snap-grid checker instead of the real textures (the level panel's debug grid; the same switch)."
	_grid_btn.toggled.connect(func(on):
		if Engine.has_meta(&"n64_level_plugin"):
			Engine.get_meta(&"n64_level_plugin").grade_set_debug_view(on))
	bar.add_child(_grid_btn)
	_game_btn = CheckButton.new()
	_game_btn.text = "Game view"
	_game_btn.tooltip_text = "What the game shows at the preview hour: the zone's fog (darker and closer at night),\nambient light, lamps glowing in the fog, the night tint; NPC spots / paths hidden.\n(With Game output on, the screen grade too.)"
	_game_btn.toggled.connect(func(on):
		if not on:
			GamePreview.clear()
		else:
			GamePreview.hide_helpers(EditorInterface.get_edited_scene_root(), true))
	bar.add_child(_game_btn)
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(refresh_level)
	bar.add_child(refresh)


func _build_side() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 280
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box := VBoxContainer.new()
	box.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(box)
	box.add_child(_head("Layer"))
	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.add_theme_font_size_override(&"font_size", 12)
	_info.text = "Click a surface, or pick a layer on the left."
	box.add_child(_info)
	_migrate = Button.new()
	_migrate.visible = false
	_migrate.tooltip_text = "Turns the Paint panel's Colour adjust on this layer into a Colour adjust filter here\n(the level shader stops applying it). Undoable."
	_migrate.pressed.connect(_on_migrate)
	box.add_child(_migrate)
	_shared_box = VBoxContainer.new()
	_shared_box.visible = false
	box.add_child(_shared_box)
	_variant_btn = Button.new()
	_variant_btn.text = "Variant from face mask"
	_variant_btn.tooltip_text = "The masked faces (Paint on, Cmd / Ctrl + click) get their own copy of their texture:\na variant layer you can grade apart from the rest."
	_variant_btn.pressed.connect(_make_variants)
	_variant_btn.visible = false
	box.add_child(_variant_btn)
	_filter_head = HBoxContainer.new()
	var fl := _head("Filters")
	fl.size_flags_horizontal = SIZE_EXPAND_FILL
	_filter_head.add_child(fl)
	_add_menu = MenuButton.new()
	_add_menu.text = "Add filter"
	_add_menu.flat = false
	var kinds := GradeFilter.kinds()
	for i in kinds.size():
		_add_menu.get_popup().add_item(kinds[i][1], i)
	_add_menu.get_popup().id_pressed.connect(func(i): _add_filter(GradeFilter.kinds()[i][0]))
	_filter_head.add_child(_add_menu)
	_filter_head.visible = false
	box.add_child(_filter_head)
	_filter_box = VBoxContainer.new()
	box.add_child(_filter_box)
	box.add_child(HSeparator.new())
	box.add_child(_head("Values"))
	_hist = TextureRect.new()
	_hist.custom_minimum_size = Vector2(0, 56)
	_hist.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_hist.stretch_mode = TextureRect.STRETCH_SCALE
	box.add_child(_hist)
	_stats = Label.new()
	_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stats.add_theme_font_size_override(&"font_size", 11)
	_stats.text = "Measure reads the view."
	box.add_child(_stats)
	box.add_child(HSeparator.new())
	box.add_child(_head("Reference"))
	var row := HBoxContainer.new()
	var pick := Button.new()
	pick.text = "Picture..."
	pick.tooltip_text = "A picture to grade towards (another game's screenshot, a painting): shown here, and its\nhistogram outlined in orange over the view's when you Measure."
	pick.pressed.connect(_pick_reference)
	row.add_child(pick)
	var clear := Button.new()
	clear.text = "Clear"
	clear.pressed.connect(func(): _set_reference(""))
	row.add_child(clear)
	box.add_child(row)
	_ref_label = Label.new()
	_ref_label.add_theme_font_size_override(&"font_size", 11)
	_ref_label.text = "None"
	box.add_child(_ref_label)
	_ref_rect = TextureRect.new()
	_ref_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_ref_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	_ref_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	_ref_rect.tooltip_text = "Drag a box to read only that part of the picture (Measure, gradient from reference),\ne.g. the ground and walls without the sky. Right-click: the whole picture again."
	_ref_rect.gui_input.connect(_on_ref_input)
	_ref_rect.draw.connect(_draw_ref_area)
	box.add_child(_ref_rect)
	return scroll


func _head(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override(&"font_size", 13)
	return l


# --- Level ---------------------------------------------------------------------------

## Finds the edited scene's level and shows it (called when the scene or the tab changes).
func refresh_level() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var level: LevelRoot = null
	if root:
		var found := root.find_children("*", "LevelRoot", true, false)
		if root is LevelRoot:
			level = root
		elif not found.is_empty():
			level = found[0]
	if level != _level:
		if _data and _data.materials_changed.is_connected(_queue_rebuild):
			_data.materials_changed.disconnect(_queue_rebuild)
		if is_instance_valid(_level):
			_level.set_grade_textures({})
			_level.set_grade_plain({})
		if is_instance_valid(_level):
			_level.set_grade_vertex({})
		_vertex_sig = "-"
		_fold_sig = ""
		_src.clear()
		_applied.clear()
		_graded.clear()
		_pretinted.clear()
		_plain.clear()
		_plain_applied.clear()
		_sel = []
		_panel_key = null
		_panel_sig = ""
		_queue_process()
		_level = level
		_data = level.data if level else null
		if _data:
			_data.materials_changed.connect(_queue_rebuild)
		_vp.world_3d = level.get_world_3d() if level else null
		_selected_ids = PackedInt32Array()
		if level:
			match_editor_camera()
	_level_label.text = (root.scene_file_path.get_file().get_basename() if root else "No scene") if _level else "No level in this scene"
	_rebuild_tree()
	_rebuild_keys()
	var timed := _timed()
	for c in [_keys_box, _hour, _hour_label]:
		c.visible = timed
	var has_shared := _grade_root() != null and _grade_root().shared_grade() != null
	_edit_target.visible = has_shared
	if not has_shared:
		_edit_shared = false
	_edit_target.select(1 if _edit_shared else 0)
	_always.visible = _data != null and not timed
	_hour.set_value_no_signal(float(EditorInterface.get_editor_settings().get_project_metadata("n64_level_tools", "preview_hour", 12.0)))
	_hour_label.text = _fmt_hour(_hour.value)
	_update_highlight()


func _queue_rebuild() -> void:
	if _rebuild_queued:
		return
	_rebuild_queued = true
	get_tree().create_timer(0.3).timeout.connect(func():
		_rebuild_queued = false
		if is_inside_tree():
			_rebuild_tree()
			_update_highlight())


func _rebuild_tree() -> void:
	_tree.clear()
	var root := _tree.create_item()
	_nodes = GradeLayers.build(_data, _grade())
	var reselect: TreeItem = null
	for n in _nodes:
		var it := _add_item(root, n)
		if reselect == null and not _sel.is_empty():
			reselect = _find_sel(it)
	if reselect:
		var p := reselect.get_parent()
		while p:
			p.collapsed = false
			p = p.get_parent()
		reselect.select(0)
	elif _sel.is_empty():
		_show_panel({})
	if _data:
		_status.text = "%d brushes · %d textures in the zone's list (bases + variants; the build budget counts these)" % [_data.brushes.size(), GradeLayers.texture_count(_data)]
	else:
		_status.text = "Open a zone scene with a level."


func _add_item(parent: TreeItem, n: Dictionary) -> TreeItem:
	var it := _tree.create_item(parent)
	it.set_text(0, n.name)
	if n.faces > 0:
		it.set_text(1, str(n.faces))
		it.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)
	it.set_metadata(0, n)
	it.set_tooltip_text(0, n.info)
	var icon := _icon_for(n.kind)
	if icon:
		it.set_icon(0, icon)
	if n.kind == &"group":
		it.collapsed = true
	var theme := EditorInterface.get_editor_theme()
	if n.kind == &"filter":
		var f: GradeFilter = n.filter
		it.add_button(0, theme.get_icon(&"GuiVisibilityVisible" if f.enabled else &"GuiVisibilityHidden", &"EditorIcons"), 0, false, "Filter on / off")
		if not f.enabled:
			it.set_custom_color(0, theme.get_color(&"font_disabled_color", &"Editor"))
	elif n.key != null:
		var hidden := _grade() != null and _grade().hidden.has(n.key)
		it.add_button(0, theme.get_icon(&"GuiVisibilityHidden" if hidden else &"GuiVisibilityVisible", &"EditorIcons"), 0, false, "Layer's filters on / off")
		if hidden:
			it.set_custom_color(0, theme.get_color(&"font_disabled_color", &"Editor"))
	for c in n.children:
		_add_item(it, c)
	return it


func _ident(n: Dictionary) -> Array:
	return [n.kind, n.key, n.filter, n.name]


func _same(a: Variant, b: Variant) -> bool:
	return typeof(a) == typeof(b) and a == b


func _find_sel(it: TreeItem) -> TreeItem:
	var n: Dictionary = it.get_metadata(0)
	var id := _ident(n)
	var ok := true
	for i in 4:
		if not _same(id[i], _sel[i]):
			ok = false
			break
	if ok:
		return it
	for c in it.get_children():
		var f := _find_sel(c)
		if f:
			return f
	return null


func _icon_for(kind: StringName) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	var name: StringName = {
		&"zone": &"WorldEnvironment", &"vertex": &"VertexColors" , &"light": &"DirectionalLight3D",
		&"ao": &"LightOccluder3D", &"paint": &"Paint", &"group": &"Folder", &"texture": &"ImageTexture",
		&"variant": &"Duplicate", &"filter": &"CurveTexture",
	}.get(kind, &"")
	return theme.get_icon(name, &"EditorIcons") if name != &"" and theme.has_icon(name, &"EditorIcons") else null


func _find_ids(it: TreeItem, ids: PackedInt32Array) -> TreeItem:
	if ids.is_empty():
		return null
	var n: Dictionary = it.get_metadata(0)
	if n.ids == ids:
		return it
	for c in it.get_children():
		var f := _find_ids(c, ids)
		if f:
			return f
	return null


func _on_tree_selected() -> void:
	var it := _tree.get_selected()
	if it == null:
		return
	var n: Dictionary = it.get_metadata(0)
	_sel = _ident(n)
	# A filter shows its layer.
	var layer := n
	if n.kind == &"filter" or n.kind == &"legacy":
		layer = it.get_parent().get_metadata(0)
	_sel_node = layer
	_info.text = "%s\n%s" % [layer.name, layer.info]
	_paint_target(n)
	var di: int = n.get("decal", -1)
	_sel_decal = _data.decals[di] if _data and di >= 0 and di < _data.decals.size() else null
	if _sel_decal:
		_update_highlight()
	if _selected_ids != layer.ids:
		_selected_ids = layer.ids
		_update_highlight()
	_show_panel(layer)


## Selects the most specific layer holding texture id `id` (a variant before its texture).
func _select_texture_id(id: int) -> void:
	var best: TreeItem = null
	var stack: Array[TreeItem] = [_tree.get_root()]
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		for c in it.get_children():
			var n: Dictionary = c.get_metadata(0)
			if id in n.ids:
				if n.kind == &"variant" or (n.kind == &"texture" and (best == null or (best.get_metadata(0).kind != &"variant"))):
					best = c
			stack.append(c)
	if best:
		var p := best.get_parent()
		while p:
			p.collapsed = false
			p = p.get_parent()
		best.select(0)
		_tree.scroll_to_item(best)


# --- Highlight -----------------------------------------------------------------------

## The selected layer's faces, tinted over the view (only the Grade camera sees it).
func _update_highlight() -> void:
	_highlight.mesh = null
	if _sel_decal and is_instance_valid(_level) and _sel_decal.texture:
		var tris := DecalBuilder.project(_level, _sel_decal, _level.global_transform.affine_inverse())
		if not tris.is_empty():
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			for v in tris:
				st.add_vertex(_level.global_transform * (v.p + v.n * 0.01))
			var m := st.commit()
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			mat.albedo_color = Color(1.0, 0.55, 0.1, 0.25)
			m.surface_set_material(0, mat)
			_highlight.mesh = m
		return
	if _level == null or _data == null or _selected_ids.is_empty():
		return
	var want := {}
	for id in _selected_ids:
		want[id] = true
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 0
	for b: LevelBrush in _data.brushes:
		if b == null:
			continue
		var xf := _level.brush_global_transform(b)
		var faces := b.get_faces()
		for f in faces.size():
			if not want.has(b.get_face_texture(f)):
				continue
			var idx: PackedInt32Array = faces[f]
			if idx.size() < 3:
				continue
			var pts := PackedVector3Array()
			for i in idx:
				pts.append(xf * b.vertices[i])
			var nrm := (pts[1] - pts[0]).cross(pts[2] - pts[0]).normalized()
			for i in range(1, pts.size() - 1):
				for p in [pts[0], pts[i], pts[i + 1]]:
					st.add_vertex(p + nrm * 0.03)
			n += 1
	if n == 0:
		return
	var m := st.commit()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(1.0, 0.55, 0.1, 0.35)
	mat.no_depth_test = false
	m.surface_set_material(0, mat)
	_highlight.mesh = m


func _frame_selection() -> void:
	if _highlight.mesh == null:
		return
	var box := _highlight.mesh.get_aabb()
	_pivot = box.get_center()
	_dist = clampf(box.size.length() * 0.9, 3.0, 600.0)
	_update_camera()


# --- View modes ----------------------------------------------------------------------

func _apply_view_mode() -> void:
	var mode := _view_mode.selected
	var game := _game_out.button_pressed
	if mode == 0 and not game:
		_cam.compositor = null
		return
	if _compositor == null:
		_effect = VideoOut.new()
		_compositor = Compositor.new()
		_compositor.compositor_effects = [_effect]
	_effect.set(&"color_16bit", game)
	_effect.set(&"horizontal_soft", 0.5 if game else 0.0)
	_effect.set(&"grade", 1.0 if mode > 0 else 0.0)
	_effect.set(&"value_steps", [0, 0, 3, 5][mode])
	_cam.compositor = _compositor


# --- Time keys -----------------------------------------------------------------------

func _rebuild_keys() -> void:
	for c in _keys_box.get_children():
		c.queue_free()
	var schedule := LightingSchedule.load_project()
	if schedule == null:
		return
	for k: LightingKey in schedule.keys:
		var b := Button.new()
		b.text = k.name
		b.toggle_mode = true
		b.tooltip_text = "%s (%s): the view as this key's baked light shows it.\nLit: the key nearest the preview hour (per-key edits such as AO apply to it)." % [k.name, _fmt_hour(k.hour)]
		var h := k.hour
		b.pressed.connect(func():
			_hour.value = h
			_mark_key())
		_keys_box.add_child(b)
	_mark_key.call_deferred()


## Presses the button of the key nearest the preview hour (the one being viewed / edited),
## the others up.
func _mark_key() -> void:
	if _keys_box == null:
		return
	var current := _current_key()
	var buttons := _keys_box.get_children().filter(func(c): return c is Button and not c.is_queued_for_deletion())
	for i in buttons.size():
		(buttons[i] as Button).set_pressed_no_signal(i == current)


func _set_hour(h: float) -> void:
	_hour_label.text = _fmt_hour(h)
	_mark_key()
	if Engine.has_meta(&"n64_preview_hour"):
		(Engine.get_meta(&"n64_preview_hour") as Callable).call(h)
	if _same(_panel_key, "vertex/ao"):
		_show_panel(_sel_node)  # (per-key AO: the key being edited follows the hour)


## Whether the zone has time-of-day lighting (else one grade for always).
func _timed() -> bool:
	return _data != null and LevelData.mode_is_timed(_data.lighting_mode)


## The time key nearest the preview hour (LightingSchedule slot), for per-key editing; 0
## in zones with one lighting.
func _current_key() -> int:
	if not _timed():
		return 0
	var s := LightingSchedule.load_project()
	if s == null or s.keys.is_empty():
		return 0
	var best := 0
	var bd := INF
	for i in mini(s.keys.size(), 4):
		var d := absf(s.keys[i].hour - _hour.value)
		d = minf(d, 24.0 - d)
		if d < bd:
			bd = d
			best = i
	return best


func _key_name(k: int) -> String:
	var s := LightingSchedule.load_project()
	return s.keys[k].name if s and k < s.keys.size() else "Key %d" % (k + 1)


func _fmt_hour(h: float) -> String:
	return "%d:%02d" % [int(h), int(round(fmod(h, 1.0) * 60.0)) % 60]


# --- Values --------------------------------------------------------------------------

func _measure() -> void:
	var view := ValueStats.of(_vp.get_texture().get_image())
	var ref := ValueStats.of(_ref_image()) if _ref_path != "" else {}
	_hist.texture = ImageTexture.create_from_image(ValueStats.histogram(view, ref))
	var t := "View: " + ValueStats.describe(view)
	if not ref.is_empty():
		t += "\nReference: " + ValueStats.describe(ref)
	_stats.text = t


func _pick_reference() -> void:
	var dlg := EditorFileDialog.new()
	dlg.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	dlg.access = EditorFileDialog.ACCESS_FILESYSTEM
	dlg.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Pictures"])
	dlg.file_selected.connect(func(path):
		_set_reference(path)
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_file_dialog()


func _set_reference(path: String) -> void:
	_ref_path = path
	_ref_area = Rect2i()
	EditorInterface.get_editor_settings().set_project_metadata("n64_grade", "reference", path)
	var img := Image.load_from_file(path) if path != "" else null
	_ref_rect.texture = ImageTexture.create_from_image(img) if img else null
	_ref_label.text = path.get_file() if img else "None"


func restore_reference() -> void:
	var dt := String(EditorInterface.get_editor_settings().get_project_metadata("n64_grade", "decal_texture", ""))
	if dt != "" and ResourceLoader.exists(dt) and _place_tex == null:
		_place_tex = load(dt)
	var p := String(EditorInterface.get_editor_settings().get_project_metadata("n64_grade", "reference", ""))
	if p != "" and FileAccess.file_exists(p):
		_set_reference(p)


# --- Camera --------------------------------------------------------------------------

func match_editor_camera() -> void:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var cam := vp.get_camera_3d() if vp else null
	if cam == null:
		return
	var xf := cam.global_transform
	var e := xf.basis.get_euler()
	_pitch = e.x
	_yaw = e.y
	_dist = 12.0
	_pivot = xf.origin - xf.basis.z * _dist
	_cam.fov = cam.fov
	_update_camera()


func _basis() -> Basis:
	return Basis.from_euler(Vector3(_pitch, _yaw, 0.0))


func _update_camera() -> void:
	if _cam == null:
		return
	var b := _basis()
	_cam.global_transform = Transform3D(b, _pivot + b.z * _dist)


func _painting() -> bool:
	return _paint_btn.button_pressed and is_instance_valid(_level) and Engine.has_meta(&"n64_level_plugin")


func _on_view_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and (ev as InputEventKey).keycode == KEY_P \
			and not (ev as InputEventKey).is_command_or_control_pressed() and _drag == 0:
		_paint_btn.button_pressed = not _paint_btn.button_pressed
		_container.accept_event()
		return
	# Trackpad: two-finger drag orbits, Shift + two-finger drag pans, Cmd / Ctrl + two-finger
	# drag or a pinch zooms. Alt + left drag orbits, Alt + Shift + left drag pans (a mouse
	# with no middle button). Before painting / picking: they never paint.
	if _trackpad_input(ev):
		_container.accept_event()
		return
	if _decal_input(ev):
		_container.accept_event()
		return
	# Painting: the left button, plain motion and the paint keys go to the paint tool.
	if _painting() and _drag == 0 and not (ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index != MOUSE_BUTTON_LEFT) \
			and not (ev is InputEventKey and (ev as InputEventKey).keycode == KEY_F):
		if ev is InputEventMouseButton and ev.pressed:
			_container.grab_focus()
		var took: bool = Engine.get_meta(&"n64_level_plugin").grade_paint_input(_cam, ev, _level)
		_overlay.queue_redraw()
		if took:
			_container.accept_event()
			return
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(_dist * 0.88, 0.5)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(_dist / 0.88, 2000.0)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_drag = 1 if mb.pressed else 0
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mb.pressed else Input.MOUSE_MODE_VISIBLE
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_drag = (3 if mb.shift_pressed else 2) if mb.pressed else 0
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_container.grab_focus()
			_pick(mb.position)
		_container.accept_event()
	elif ev is InputEventMouseMotion and _drag != 0:
		var r := (ev as InputEventMouseMotion).relative
		match _drag:
			1:  # look: turn about the camera itself
				var eye := _cam.global_position
				_yaw -= r.x * 0.004
				_pitch = clampf(_pitch - r.y * 0.004, -1.55, 1.55)
				_pivot = eye - _basis().z * _dist
			2:
				_yaw -= r.x * 0.006
				_pitch = clampf(_pitch - r.y * 0.006, -1.55, 1.55)
			3:
				var b := _basis()
				var k := _dist * 0.0018
				_pivot += (-b.x * r.x + b.y * r.y) * k
		_update_camera()
		_container.accept_event()
	elif ev is InputEventKey and ev.pressed and not ev.echo and (ev as InputEventKey).keycode == KEY_F and _drag == 0:
		_frame_selection()
		_container.accept_event()


func _trackpad_input(ev: InputEvent) -> bool:
	if ev is InputEventPanGesture:
		var g := ev as InputEventPanGesture
		if g.is_command_or_control_pressed():
			_dist = clampf(_dist * pow(1.04, g.delta.y), 0.5, 2000.0)
		elif g.shift_pressed:
			var b := _basis()
			var k := _dist * 0.02
			_pivot += (b.x * g.delta.x - b.y * g.delta.y) * k
		else:
			_yaw -= g.delta.x * 0.04
			_pitch = clampf(_pitch - g.delta.y * 0.04, -1.55, 1.55)
		_update_camera()
		return true
	if ev is InputEventMagnifyGesture:
		var m := ev as InputEventMagnifyGesture
		_dist = clampf(_dist / maxf(m.factor, 0.01), 0.5, 2000.0)
		_update_camera()
		return true
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.alt_pressed:
			_drag = 3 if mb.shift_pressed else 2
			return true
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and _drag in [2, 3]:
			_drag = 0
			return true
	return false


func _process(delta: float) -> void:
	_poll_processing()
	if _game_btn and _game_btn.button_pressed and is_visible_in_tree():
		GamePreview.apply(EditorInterface.get_edited_scene_root(), _hour.value, _cam)
	if _drag != 1 or not is_visible_in_tree():
		return
	var b := _basis()
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move -= b.z
	if Input.is_key_pressed(KEY_S):
		move += b.z
	if Input.is_key_pressed(KEY_D):
		move += b.x
	if Input.is_key_pressed(KEY_A):
		move -= b.x
	if Input.is_key_pressed(KEY_E):
		move += Vector3.UP
	if Input.is_key_pressed(KEY_Q):
		move -= Vector3.UP
	if move != Vector3.ZERO:
		var speed := 30.0 if Input.is_key_pressed(KEY_SHIFT) else 8.0
		_pivot += move.normalized() * speed * delta
		_update_camera()


func _pick(pos: Vector2) -> void:
	if _level == null:
		return
	var from := _cam.project_ray_origin(pos)
	var dir := _cam.project_ray_normal(pos)
	var hit := _level.raycast(from, dir)
	if hit.is_empty():
		return
	var id: int = hit.brush.get_face_texture(hit.face)
	if id < 0:
		_info.text = "This face has no texture."
		return
	_select_texture_id(id)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and _game_btn and _game_btn.button_pressed:
		# (Leaving the Paint screen: the 3D view goes back to the editor's own look.)
		if is_visible_in_tree():
			GamePreview.hide_helpers(EditorInterface.get_edited_scene_root(), true)
		else:
			GamePreview.clear()
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_visible_in_tree() and _grid_btn:
		_grid_btn.set_pressed_no_signal(LevelRoot.debug_view)  # (it may have changed in the 3D view)
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree() and _drag == 1:
		_drag = 0
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# --- Filter panel --------------------------------------------------------------------

## The grade being edited: the zone's, or (Edit: Shared) the shared grade under it.
func _grade() -> ZoneGrade:
	var root := _grade_root()
	if _edit_shared and root and root.shared_grade():
		return root.shared_grade()
	return root


## The zone's grade (with its shared grade under it): what the level shows.
func _grade_root() -> ZoneGrade:
	return _data.grade as ZoneGrade if _data else null


## The selected layer's filters (top first) and its buttons; rebuilt only when the layer or
## its list of filters changed, so editing a filter doesn't tear down its controls.
func _show_panel(layer: Dictionary) -> void:
	var key: Variant = layer.get("key")
	var g := _grade()
	var list: Array = g.filters(key) if g and key != null else []
	var sig := str(list.map(func(f): return f.get_instance_id())) if key != null else ""
	_migrate.visible = false
	_variant_btn.visible = layer.get("kind") == &"texture" or layer.get("kind") == &"group"
	_show_shared(layer.get("kind") == &"zone")
	if not layer.is_empty():
		var n := _legacy_count(layer)
		if n > 0:
			_migrate.visible = true
			_migrate.text = "Move Paint panel adjusts here (%d)" % n if layer.kind == &"zone" else "Move Paint panel adjust here"
	if layer.get("kind") in [&"decals", &"decal"]:
		sig = "decal%d|%d|%s" % [layer.get("decal", -1), _data.decals.size() if _data else 0, _decal_place]
	if layer.get("kind") == &"ao_layer" or _same(key, "vertex/ao_layers"):
		sig = "aol%d|%d|%s" % [layer.get("ao_id", -1), _current_key(), str(g.ao_layers.map(func(l): return [l.id, l.linked]) if g else [])]
	if _same(key, "vertex/ao"):
		# (not the values: dragging a slider must not rebuild the panel under it)
		sig = "ao%d%s%s" % [_current_key(), g != null and g.ao != null, g.ao.linked if g and g.ao else true]
	if _same(key, _panel_key) and sig == _panel_sig:
		return
	_panel_key = key
	_panel_sig = sig
	for c in _filter_box.get_children():
		c.queue_free()
	_filter_head.visible = key != null and not _same(key, "vertex/ao")
	if _same(key, "vertex/ao"):
		_ao_panel()
		return
	if _same(key, "vertex/ao_layers") or layer.get("kind") == &"ao_layer":
		_filter_head.visible = false
		_ao_layers_panel(layer)
		return
	if layer.get("kind") in [&"decals", &"decal"]:
		_filter_head.visible = false
		_decals_panel(layer)
		return
	if key == null:
		if layer.get("kind") == &"vertex":
			var l := Label.new()
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.add_theme_font_size_override(&"font_size", 11)
			l.text = "Pick Baked light, Baked AO or Painted colour. Light filters can be limited to some time keys (Keys); AO takes strength / curve / tint per key."
			_filter_box.add_child(l)
		return
	if list.is_empty():
		var l := Label.new()
		l.add_theme_font_size_override(&"font_size", 11)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.text = "No filters. Add one: Gradient map on Soft light for temperature bands, Levels for values."
		_filter_box.add_child(l)
	for i in range(list.size() - 1, -1, -1):
		_filter_box.add_child(_filter_row(key, list, i))


func _filter_row(key: Variant, list: Array, i: int) -> Control:
	var f: GradeFilter = list[i]
	var panel := PanelContainer.new()
	var box := VBoxContainer.new()
	panel.add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	var t := Label.new()
	t.text = f.title()
	t.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(t)
	var theme := EditorInterface.get_editor_theme()
	for spec in [[&"MoveUp", "Up (applies later)", 1], [&"MoveDown", "Down (applies earlier)", -1], [&"Duplicate", "Duplicate", 0], [&"Remove", "Remove", 99]]:
		var b := Button.new()
		b.icon = theme.get_icon(spec[0], &"EditorIcons")
		b.tooltip_text = spec[1]
		b.flat = true
		var op: int = spec[2]
		b.pressed.connect(func(): _filter_op(key, f, op))
		if (op == 1 and i == list.size() - 1) or (op == -1 and i == 0):
			b.disabled = true
		head.add_child(b)
	var insp := EditorInspector.new()
	insp.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	insp.size_flags_horizontal = SIZE_EXPAND_FILL
	box.add_child(insp)
	insp.edit(f)
	insp.property_edited.connect(func(_p):
		_queue_process()
		_queue_rebuild())
	if f is GradeGradientMap:
		var row := HBoxContainer.new()
		var from := Button.new()
		from.text = "From reference"
		from.tooltip_text = "Reads the gradient from the reference picture (Reference, right): its colour at each\nlightness, darks to lights. On Colour the textures take those colours outright; on Soft\nlight they lean towards them."
		var stops := SpinBox.new()
		stops.min_value = 3
		stops.max_value = 12
		stops.value = 7
		stops.tooltip_text = "Bands of lightness (gradient stops)."
		from.pressed.connect(func():
			var img := _ref_image() if _ref_path != "" else null
			var g := GradeGradientMap.from_image(img, int(stops.value), f.perceptual)
			if g == null:
				_status.text = "Gradient from reference: pick a reference picture first (Reference > Picture...)."
				return
			_set_filter(f, &"gradient", g, insp)
			_status.text = "Gradient read from %s (%d stops)." % [_ref_path.get_file(), g.get_point_count()])
		row.add_child(from)
		row.add_child(stops)
		box.add_child(row)
		box.add_child(_ramp_row(f, insp))
	elif f is GradeLut:
		box.add_child(_lut_picker(f, insp))
	elif f is GradePalette:
		box.add_child(_palette_picker(f, insp))
	return panel


## Gradient map: make a colour ramp (GradeGradientMap.ramp) from a base colour: steps even
## in perceived lightness, darks cooler / lights warmer by Temperature; Random rolls one.
func _ramp_row(f: GradeGradientMap, insp: EditorInspector) -> Control:
	var v := VBoxContainer.new()
	var row := HBoxContainer.new()
	var base := ColorPickerButton.new()
	base.color = Color(0.36, 0.52, 0.25)
	base.edit_alpha = false
	base.custom_minimum_size = Vector2(36, 0)
	base.tooltip_text = "Ramp colour: its hue and colourfulness (lightness comes from the steps)."
	_okhsl(base)
	var steps := SpinBox.new()
	steps.min_value = 2
	steps.max_value = 12
	steps.value = 5
	steps.tooltip_text = "Steps (colours), evenly spaced in perceived lightness."
	var temp := SpinBox.new()
	temp.min_value = -90
	temp.max_value = 90
	temp.value = 30
	temp.suffix = "°"
	temp.tooltip_text = "Temperature: darks turn this far towards blue, lights towards yellow
(cool shadows, warm lights; negative: the other way)."
	var flat := CheckBox.new()
	flat.text = "Steps"
	flat.button_pressed = true
	flat.tooltip_text = "Flat bands (value groups in colour); off: a smooth ramp."
	row.add_child(base)
	row.add_child(steps)
	row.add_child(temp)
	row.add_child(flat)
	var row2 := HBoxContainer.new()
	var make := Button.new()
	make.text = "Make ramp"
	make.size_flags_horizontal = SIZE_EXPAND_FILL
	make.tooltip_text = "Replace the gradient with a ramp of the ramp colour (OKLab: even steps, same hue)."
	var rand := Button.new()
	rand.text = "Random"
	rand.size_flags_horizontal = SIZE_EXPAND_FILL
	rand.tooltip_text = "Roll a random harmonious ramp (a hue, a colourfulness, a temperature)."
	var build := func():
		var lab := GradePalette.oklab(base.color)
		var c := Vector2(lab.y, lab.z).length()
		var g := GradeGradientMap.ramp(base.color, int(steps.value), temp.value, c * 0.75, c, 0.2, 0.94, flat.button_pressed)
		_set_filter(f, &"gradient", g, insp)
		if flat.button_pressed and not f.stretch:
			_set_filter(f, &"stretch", true, insp)  # (bands meet each texture's own values)
		_status.text = "Ramp: %d steps, temperature %d°." % [int(steps.value), int(temp.value)]
	make.pressed.connect(build)
	rand.pressed.connect(func():
		var h := randf() * TAU
		var c := randf_range(0.04, 0.14)
		base.color = GradePalette.from_oklab_fit(Vector3(0.65, c * cos(h), c * sin(h)))
		temp.value = randf_range(10.0, 60.0) * (1.0 if randf() < 0.8 else -1.0)
		build.call())
	row2.add_child(make)
	row2.add_child(rand)
	v.add_child(row)
	v.add_child(row2)
	return v


## A colour picker opening in OKHSL (perceptual: moving round the wheel keeps lightness).
static func _okhsl(b: ColorPickerButton) -> void:
	b.get_picker().color_mode = ColorPicker.MODE_OKHSL


## Sets a filter property as one undo step and refreshes its inspector.
func _set_filter(f: GradeFilter, prop: StringName, value: Variant, insp: EditorInspector) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Grade Filter: " + String(prop).capitalize(), UndoRedo.MERGE_DISABLE, _level)
	ur.add_do_property(f, prop, value)
	ur.add_undo_property(f, prop, f.get(prop))
	ur.commit_action()
	if is_instance_valid(insp):
		insp.edit(null)
		insp.edit(f)
	_queue_process()
	_queue_rebuild()


## LUT packs: pick a pack, then flip through its LUTs (◀ ▶); Import adds a pack.
func _lut_picker(f: GradeLut, insp: EditorInspector) -> Control:
	var box := VBoxContainer.new()
	var row := HBoxContainer.new()
	box.add_child(row)
	var packs := OptionButton.new()
	packs.size_flags_horizontal = SIZE_EXPAND_FILL
	packs.tooltip_text = "LUT pack (textures/_grade/luts/<pack>)"
	row.add_child(packs)
	var imp := Button.new()
	imp.text = "Import pack..."
	imp.tooltip_text = "A folder or .zip of LUTs (HaldCLUT PNGs, .cube): each is stored as a small 32-level\nstrip in textures/_grade/luts/<name> (the folder / zip name)."
	row.add_child(imp)
	var row2 := HBoxContainer.new()
	box.add_child(row2)
	var prev := Button.new()
	prev.text = "◀"
	row2.add_child(prev)
	var list := OptionButton.new()
	list.size_flags_horizontal = SIZE_EXPAND_FILL
	list.fit_to_longest_item = false
	row2.add_child(list)
	var next := Button.new()
	next.text = "▶"
	row2.add_child(next)
	var fill_list := func(pack: String):
		list.clear()
		for path in LutPacks.luts(pack):
			list.add_item(path.get_file().get_basename())
			list.set_item_metadata(list.item_count - 1, path)
			if path == f.lut_path:
				list.select(list.item_count - 1)
		if list.selected < 0 and list.item_count > 0:
			list.select(-1)
	var fill_packs := func():
		packs.clear()
		var names := LutPacks.packs()
		for n in names:
			packs.add_item(n)
		var cur := f.lut_path.get_base_dir().get_file() if f.lut_path.begins_with(LutPacks.DIR) else ""
		var i := names.find(cur)
		if i >= 0:
			packs.select(i)
		if names.is_empty():
			packs.add_item("(no packs: import one)")
			packs.disabled = true
		else:
			packs.disabled = false
			fill_list.call(packs.get_item_text(packs.selected))
	fill_packs.call()
	packs.item_selected.connect(func(i): fill_list.call(packs.get_item_text(i)))
	var pick := func(i: int):
		if i >= 0 and i < list.item_count:
			list.select(i)
			_set_filter(f, &"lut_path", list.get_item_metadata(i), insp)
	list.item_selected.connect(pick)
	prev.pressed.connect(func(): pick.call(maxi(list.selected - 1, 0)))
	next.pressed.connect(func(): pick.call(mini(list.selected + 1, list.item_count - 1)))
	imp.pressed.connect(func():
		var dlg := EditorFileDialog.new()
		dlg.file_mode = EditorFileDialog.FILE_MODE_OPEN_ANY
		dlg.access = EditorFileDialog.ACCESS_FILESYSTEM
		dlg.filters = PackedStringArray(["*.zip ; Zipped LUT pack"])
		dlg.title = "LUT pack: a folder or .zip"
		var go := func(path: String):
			dlg.queue_free()
			var name := path.get_file().get_basename() if path.get_extension() != "" else path.trim_suffix("/").get_file()
			_status.text = "Importing LUT pack %s..." % name
			await get_tree().process_frame
			var r := LutPacks.import_pack(path, name)
			_status.text = "LUT pack %s: %d imported, %d skipped (not a LUT)." % [name, r[0], r[1]]
			fill_packs.call()
		dlg.file_selected.connect(go)
		dlg.dir_selected.connect(go)
		dlg.canceled.connect(dlg.queue_free)
		add_child(dlg)
		dlg.popup_file_dialog())
	return box


## Palettes: pick one of textures/_grade/palettes, or download a Lospec palette by name.
func _palette_picker(f: GradePalette, insp: EditorInspector) -> Control:
	var box := VBoxContainer.new()
	var list := OptionButton.new()
	list.tooltip_text = "Palettes in textures/_grade/palettes (.hex / .gpl / .png)"
	box.add_child(list)
	var sw := TextureRect.new()
	sw.custom_minimum_size = Vector2(0, 18)
	sw.tooltip_text = "Click colours to pick the ones this texture may use (marked below the swatch);\nnone picked = chosen automatically. Ramp: the picked colours are the ramp."
	sw.mouse_filter = Control.MOUSE_FILTER_STOP
	sw.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sw.stretch_mode = TextureRect.STRETCH_SCALE
	sw.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	box.add_child(sw)
	var row := HBoxContainer.new()
	box.add_child(row)
	var slug := LineEdit.new()
	slug.placeholder_text = "lospec name, e.g. endesga-32"
	slug.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(slug)
	var get_btn := Button.new()
	get_btn.text = "Get"
	get_btn.tooltip_text = "Downloads lospec.com/palette-list/<name>.hex into textures/_grade/palettes."
	row.add_child(get_btn)
	var show_swatch := func():
		var cols := GradePalettes.load_colours(f.palette_path)
		if cols.is_empty():
			sw.texture = null
			return
		var img := GradePalettes.swatch(cols, 6)
		for i in cols.size():
			img.set_pixel(i, 5, Color.WHITE if i in f.picked else Color(0.1, 0.1, 0.12))
		sw.texture = ImageTexture.create_from_image(img)
	var clear := Button.new()
	clear.text = "Clear picks"
	clear.pressed.connect(func():
		_set_filter(f, &"picked", PackedInt32Array(), insp)
		show_swatch.call())
	box.add_child(clear)
	sw.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			var cols := GradePalettes.load_colours(f.palette_path)
			if cols.is_empty():
				return
			var i := clampi(int(ev.position.x / sw.size.x * cols.size()), 0, cols.size() - 1)
			var p := f.picked.duplicate()
			if i in p:
				p.remove_at(p.find(i))
			else:
				p.append(i)
			_set_filter(f, &"picked", p, insp)
			show_swatch.call())
	var fill := func():
		list.clear()
		list.add_item("(none)")
		for path in GradePalettes.list():
			list.add_item(path.get_file().get_basename())
			list.set_item_metadata(list.item_count - 1, path)
			if path == f.palette_path:
				list.select(list.item_count - 1)
		show_swatch.call()
	fill.call()
	list.item_selected.connect(func(i):
		_set_filter(f, &"palette_path", list.get_item_metadata(i) if i > 0 else "", insp)
		if not f.picked.is_empty():
			_set_filter(f, &"picked", PackedInt32Array(), insp)  # (indices belong to the old palette)
		show_swatch.call())
	get_btn.pressed.connect(func():
		var name := slug.text.strip_edges()
		if name == "":
			return
		GradePalettes.ensure_dir()
		var http := HTTPRequest.new()
		http.timeout = 20.0
		add_child(http)
		http.request_completed.connect(func(result: int, code: int, _h, body: PackedByteArray):
			http.queue_free()
			var text := body.get_string_from_utf8()
			if result != HTTPRequest.RESULT_SUCCESS or code != 200 or not text.strip_edges().substr(0, 6).is_valid_hex_number():
				_status.text = "Lospec: no palette called \"%s\" (%d)." % [name, code]
				return
			var path := GradePalettes.path_for(name)
			FileAccess.open(path, FileAccess.WRITE).store_string(text)
			_status.text = "Lospec palette %s saved (%s)." % [name, path]
			fill.call()
			_set_filter(f, &"palette_path", path, insp)
			show_swatch.call())
		if http.request(GradePalettes.lospec_url(name)) != OK:
			http.queue_free()
			_status.text = "Lospec: request failed.")
	return box


## Add / move / duplicate / remove a filter (one undo step each).
func _filter_op(key: Variant, f: GradeFilter, op: int) -> void:
	var g := _grade()
	if g == null:
		return
	var list := g.filters(key).duplicate()
	var i := list.find(f)
	if i < 0:
		return
	var name := "Grade Filter"
	match op:
		1, -1:
			var j := i + op
			if j < 0 or j >= list.size():
				return
			list[i] = list[j]
			list[j] = f
			name = "Move Grade Filter"
		0:
			list.insert(i + 1, f.duplicate(true))
			name = "Duplicate Grade Filter"
		99:
			list.remove_at(i)
			name = "Remove Grade Filter"
	_commit_stacks(g, g.with_stack(key, list), name)


func _add_filter(script_path: String) -> void:
	if _panel_key == null or _data == null:
		return
	var g := _grade()
	var new_grade := g == null
	if new_grade:
		g = ZoneGrade.new()
	var f: GradeFilter = load(script_path).new()
	if &"perceptual" in f:
		f.set(&"perceptual", true)  # (new filters work in OKLab; old ones keep their maths)
	f.on_light = _same(_panel_key, GradeVertex.LIGHT) and _timed()  # (Keys: time-of-day zones)
	var list := g.filters(_panel_key).duplicate()
	list.append(f)
	_commit_stacks(g, g.with_stack(_panel_key, list), "Add Grade Filter: " + f.title(), new_grade)


func _commit_stacks(g: ZoneGrade, stacks: Dictionary, name: String, attach := false) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action(name, UndoRedo.MERGE_DISABLE, _level)
	if attach:
		ur.add_do_property(_data, &"grade", g)
		ur.add_undo_property(_data, &"grade", _data.grade)
	ur.add_do_property(g, &"stacks", stacks)
	ur.add_undo_property(g, &"stacks", g.stacks)
	ur.add_do_method(self, &"_after_structure")
	ur.add_undo_method(self, &"_after_structure")
	ur.commit_action()


func _after_structure() -> void:
	_rebuild_tree()
	if not _sel_node.is_empty():
		_show_panel(_sel_node)
	_queue_process()


func _on_tree_button(item: TreeItem, _col: int, _id: int, _mb: int) -> void:
	var n: Dictionary = item.get_metadata(0)
	var ur := EditorInterface.get_editor_undo_redo()
	if n.kind == &"filter":
		var f: GradeFilter = n.filter
		ur.create_action("Grade Filter On / Off", UndoRedo.MERGE_DISABLE, _level)
		ur.add_do_property(f, &"enabled", not f.enabled)
		ur.add_undo_property(f, &"enabled", f.enabled)
	else:
		var g := _grade()
		if g == null or n.key == null:
			return
		var hidden := g.hidden.duplicate()
		if hidden.has(n.key):
			hidden.erase(n.key)
		else:
			hidden[n.key] = true
		ur.create_action("Grade Layer On / Off", UndoRedo.MERGE_DISABLE, _level)
		ur.add_do_property(g, &"hidden", hidden)
		ur.add_undo_property(g, &"hidden", g.hidden)
	ur.add_do_method(self, &"_after_structure")
	ur.add_undo_method(self, &"_after_structure")
	ur.commit_action()


func _on_history() -> void:
	if _data == null:
		return
	_queue_shared_save()
	_queue_process()
	_queue_rebuild()


# --- Moving Paint panel adjusts in ---------------------------------------------------

## Paint panel Colour adjusts a layer (or, for the zone, the whole level) still has.
func _legacy_count(layer: Dictionary) -> int:
	return _legacy_items(layer).size()


## [[key, ColourAdjust, look or null]] for `layer`.
func _legacy_items(layer: Dictionary) -> Array:
	var out := []
	if _data == null:
		return out
	var kind: StringName = layer.get("kind", &"")
	for base in _data.base_adjusts:
		var a: ColourAdjust = _data.base_adjusts[base]
		if a and not a.is_identity() and (kind == &"zone" or (kind == &"texture" and _same(layer.key, base))):
			out.append([base, a, null])
	for t in _data.textures:
		if t is TextureLook and (t as TextureLook).adjust and not (t as TextureLook).adjust.is_identity():
			if kind == &"zone" or (kind == &"variant" and _same(layer.key, t)):
				out.append([t, (t as TextureLook).adjust, t])
	return out


func _on_migrate() -> void:
	var items := _legacy_items(_sel_node)
	if items.is_empty():
		return
	var g := _grade()
	var attach := g == null
	if attach:
		g = ZoneGrade.new()
	var stacks: Dictionary = g.with_stack("zone", g.filters("zone").duplicate())
	var adjusts := _data.base_adjusts.duplicate()
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Move Colour Adjusts Into Grade", UndoRedo.MERGE_DISABLE, _level)
	for it in items:
		var f := GradeColourAdjust.new()
		f.adjust = (it[1] as ColourAdjust).duplicate()
		var list: Array = stacks.get(it[0], []).duplicate()
		list.insert(0, f)  # (nearest the texture, where the shader applied it)
		stacks[it[0]] = list
		if it[2] == null:
			adjusts.erase(it[0])
		else:
			ur.add_do_property(it[2], &"adjust", null)
			ur.add_undo_property(it[2], &"adjust", it[1])
	if attach:
		ur.add_do_property(_data, &"grade", g)
		ur.add_undo_property(_data, &"grade", _data.grade)
	ur.add_do_property(g, &"stacks", stacks)
	ur.add_undo_property(g, &"stacks", g.stacks)
	ur.add_do_property(_data, &"base_adjusts", adjusts)
	ur.add_undo_property(_data, &"base_adjusts", _data.base_adjusts)
	ur.add_do_method(_data, &"emit_signal", &"materials_changed")
	ur.add_undo_method(_data, &"emit_signal", &"materials_changed")
	ur.add_do_method(self, &"_after_structure")
	ur.add_undo_method(self, &"_after_structure")
	ur.commit_action()


# --- Processing ----------------------------------------------------------------------

func _queue_process() -> void:
	_dirty = true


func _poll_processing() -> void:
	if _task >= 0:
		if not WorkerThreadPool.is_group_task_completed(_task):
			return
		WorkerThreadPool.wait_for_group_task_completion(_task)
		_task = -1
		_finish_jobs()
	if _vertex_task >= 0 and WorkerThreadPool.is_task_completed(_vertex_task):
		WorkerThreadPool.wait_for_task_completion(_vertex_task)
		_vertex_task = -1
		var params := {}
		for k in _vertex_out:
			var v = _vertex_out[k]
			params[k] = ImageTexture.create_from_image(v) if v is Image else v
		if is_instance_valid(_level):
			_level.set_grade_vertex(params)
	if _dirty:
		_dirty = false
		_start_jobs()
		_start_vertex()


## Which entries' chains changed since they were last made; runs those on worker threads.
func _start_jobs() -> void:
	if not is_instance_valid(_level) or _data == null:
		return
	var g := _grade_root()
	var on := _filters_on.button_pressed
	var changed := false
	var seen := {}
	_jobs = []
	for t: Texture2D in _data.textures:
		if t == null or t is N64StairTexture or seen.has(t):
			continue
		seen[t] = true
		var base := TextureLook.source_of(t)
		if base == null:
			continue
		var chain: Array = g.chain_for(t, GradeLayers.group_of(base)) if g and on else []
		if chain.is_empty():
			if _graded.has(t):
				_graded.erase(t)
				_applied.erase(t)
				_pretinted.erase(t)
				changed = true
			continue
		var tint := _combiner(t, base)
		var sig := GradeProcessor.signature(chain) + var_to_str(tint)
		if _applied.get(t, "") == sig:
			continue
		if not _src.has(base):
			_src[base] = GradeProcessor.source_image(base)
		if _src[base] == null:
			continue
		for f in chain:
			f.prepare()
		_jobs.append({entry = t, chain = chain, sig = sig, src = _src[base], tint = tint})
	# (entries no longer in the level)
	for t in _graded.keys():
		if not seen.has(t):
			_graded.erase(t)
			_applied.erase(t)
			_pretinted.erase(t)
			changed = true
	# Stairs' bases, overlay layers, grass, scatter.
	var extras := GradeLayers.extra_textures(_data)
	var plain_changed := false
	for t: Texture2D in extras:
		var chain: Array = g.chain_for(t, GradeLayers.group_of(t)) if g and on else []
		if chain.is_empty():
			if _plain.has(t):
				_plain.erase(t)
				_plain_applied.erase(t)
				plain_changed = true
			continue
		var tint: Array = extras[t].tint
		var sig := GradeProcessor.signature(chain) + var_to_str(tint)
		if _plain_applied.get(t, "") == sig:
			continue
		if not _src.has(t):
			_src[t] = GradeProcessor.source_image(t)
		if _src[t] == null:
			continue
		for f in chain:
			f.prepare()
		_jobs.append({entry = t, chain = chain, sig = sig, src = _src[t], tint = tint, plain = true})
	for t in _plain.keys():
		if not extras.has(t):
			_plain.erase(t)
			_plain_applied.erase(t)
			plain_changed = true
	if _jobs.is_empty():
		if changed:
			_level.set_grade_textures(_graded.duplicate(), _pretinted.duplicate())
		if plain_changed:
			_level.set_grade_plain(_plain.duplicate())
		return
	_results = []
	_results.resize(_jobs.size())
	_task = WorkerThreadPool.add_group_task(_run_job, _jobs.size(), -1, true, "Grade filters")


func _run_job(i: int) -> void:
	_results[i] = GradeProcessor.process(_jobs[i].src, _jobs[i].chain, _jobs[i].tint)


## The combiner tint the level gives palette entry `t` (graded in first), or [] for none.
func _combiner(t: Texture2D, base: Texture2D) -> Array:
	var look := t as TextureLook
	var palette = look.palette if look and look.palette.size() == 2 else _data.base_tints.get(base)
	var c := PaintAtlas.texture_tint(base, palette)
	return c if c[0] > 0.5 else []


func _finish_jobs() -> void:
	var any_plain := false
	for i in _jobs.size():
		var img: Image = _results[i]
		if img == null:
			continue
		if _jobs[i].get("plain", false):
			var tex := ImageTexture.create_from_image(img)
			tex.set_meta(&"grade_source", _jobs[i].entry)
			_plain[_jobs[i].entry] = [tex, not _jobs[i].tint.is_empty()]
			_plain_applied[_jobs[i].entry] = _jobs[i].sig
			any_plain = true
			continue
		_graded[_jobs[i].entry] = ImageTexture.create_from_image(img)
		_applied[_jobs[i].entry] = _jobs[i].sig
		if _jobs[i].tint.is_empty():
			_pretinted.erase(_jobs[i].entry)
		else:
			_pretinted[_jobs[i].entry] = true
	_jobs = []
	_results = []
	if is_instance_valid(_level):
		_level.set_grade_textures(_graded.duplicate(), _pretinted.duplicate())
		if any_plain or _plain.size() != _level.grade_plain.size():
			_level.set_grade_plain(_plain.duplicate())


# --- Vertex layers -------------------------------------------------------------------

## Recompiles the vertex preview (colour tables, AO per key) when its layers changed.
func _start_vertex() -> void:
	if not is_instance_valid(_level) or _vertex_task >= 0:
		if _vertex_task >= 0:
			_dirty = true  # (try again once the running one is done)
		return
	var g := _grade_root() if _filters_on.button_pressed else null
	var mode := _data.lighting_mode
	var sig := GradeVertex.signature(g, mode)
	if sig == _vertex_sig:
		return
	var had := _vertex_sig
	_vertex_sig = sig
	# What's built into the mesh (AO layers; all of it in Baked Vertex zones) needs a rebuild
	# when it changes (the level built it right on load).
	var fold_sig := str(g.ao_fold()) if g else ""
	if had != "-" and (fold_sig != _fold_sig or mode == LevelData.LightingMode.BAKED_VERTEX):
		_queue_ao_rebuild()
	_fold_sig = fold_sig
	if sig == "":
		_level.set_grade_vertex({})
		return
	GradeVertex.prepare(g)
	_vertex_task = WorkerThreadPool.add_task(func(): _vertex_out = GradeVertex.compile(g, mode), true, "Grade vertex")


## Baked AO: strength / curve / tint, for every key (linked) or the key nearest the
## preview hour (switch keys with the toolbar).
func _ao_panel() -> void:
	var g := _grade()
	var ao: GradeAO = g.ao as GradeAO if g else null
	var k := _current_key()
	var view: GradeAO = ao if ao else GradeAO.new()
	var i := view.slot(k)
	var box := _filter_box
	var linked := CheckBox.new()
	linked.text = "Same for every time key"
	linked.button_pressed = view.linked
	linked.toggled.connect(func(on): _set_ao(&"linked", on))
	linked.visible = _timed()
	box.add_child(linked)
	var l := Label.new()
	l.add_theme_font_size_override(&"font_size", 11)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.text = ("All keys" if view.linked else "Editing: %s (pick another key in the toolbar)" % _key_name(k)) if _timed() else "Always (this zone has one lighting)"
	box.add_child(l)
	for spec in [[&"strength", "Strength", 0.0, 1.5, "How much AO shows (1 = as baked)."],
			[&"curve", "Curve", 0.3, 3.0, "> 1: only the deepest corners; < 1: wider and softer."]]:
		var row := HBoxContainer.new()
		var name := Label.new()
		name.text = spec[1]
		name.custom_minimum_size.x = 70
		row.add_child(name)
		var sl := HSlider.new()
		sl.min_value = spec[2]
		sl.max_value = spec[3]
		sl.step = 0.01
		sl.size_flags_horizontal = SIZE_EXPAND_FILL
		sl.size_flags_vertical = SIZE_SHRINK_CENTER
		sl.tooltip_text = spec[4]
		sl.value = (view.get(spec[0]) as PackedFloat32Array)[i]
		var val := Label.new()
		val.text = "%.2f" % sl.value
		val.custom_minimum_size.x = 36
		var prop: StringName = spec[0]
		sl.value_changed.connect(func(v):
			val.text = "%.2f" % v
			_set_ao(prop, v))
		row.add_child(sl)
		row.add_child(val)
		box.add_child(row)
	var trow := HBoxContainer.new()
	var tl := Label.new()
	tl.text = "Corner colour"
	tl.custom_minimum_size.x = 70
	trow.add_child(tl)
	var pick := ColorPickerButton.new()
	pick.color = view.tint[i]
	pick.edit_alpha = false
	_okhsl(pick)
	pick.size_flags_horizontal = SIZE_EXPAND_FILL
	pick.tooltip_text = "What corners sink towards: black = plain AO; deep blue at night, a warm bounce at noon."
	pick.color_changed.connect(func(c): _set_ao(&"tint", c))
	trow.add_child(pick)
	box.add_child(trow)
	var reset := Button.new()
	reset.text = "Reset AO (as baked)"
	reset.pressed.connect(func():
		if g and g.ao:
			var ur := EditorInterface.get_editor_undo_redo()
			ur.create_action("Reset Grade AO", UndoRedo.MERGE_DISABLE, _level)
			ur.add_do_property(g, &"ao", null)
			ur.add_undo_property(g, &"ao", g.ao)
			ur.add_do_method(self, &"_after_structure")
			ur.add_undo_method(self, &"_after_structure")
			ur.commit_action())
	box.add_child(reset)


## One AO setting for the current key (or all, linked), as an undo step (drags merge).
func _set_ao(prop: StringName, value: Variant) -> void:
	if _data == null:
		return
	var ur := EditorInterface.get_editor_undo_redo()
	var g := _grade()
	var new_grade := g == null
	if new_grade:
		g = ZoneGrade.new()
	var ao: GradeAO = g.ao as GradeAO
	var new_ao := ao == null
	if new_ao:
		ao = GradeAO.new()
	ur.create_action("Grade AO: " + String(prop).capitalize(), UndoRedo.MERGE_ENDS, _level)
	if new_grade:
		ur.add_do_property(_data, &"grade", g)
		ur.add_undo_property(_data, &"grade", _data.grade)
	if new_ao:
		ur.add_do_property(g, &"ao", ao)
		ur.add_undo_property(g, &"ao", null)
	if prop == &"linked":
		# (linked edits write every key, so unlinking starts each key from the shared value)
		ur.add_do_property(ao, &"linked", value)
		ur.add_undo_property(ao, &"linked", ao.linked)
	else:
		var arr = ao.get(prop).duplicate()
		var k := _current_key()
		if ao.linked:
			for i in 4:
				arr[i] = value
		else:
			arr[k] = value
		ur.add_do_property(ao, prop, arr)
		ur.add_undo_property(ao, prop, ao.get(prop))
	ur.add_do_method(self, &"_queue_process")
	ur.add_undo_method(self, &"_queue_process")
	ur.commit_action()
	if prop == &"linked":
		_panel_sig = ""
		_show_panel(_sel_node)


# --- Painting ------------------------------------------------------------------------

func _draw_overlay() -> void:
	if _painting():
		Engine.get_meta(&"n64_level_plugin").grade_draw_paint(_overlay, _cam)


## A tree layer that can be painted (Painted colour, an overlay): the brush paints it.
func _paint_target(layer: Dictionary) -> void:
	if not Engine.has_meta(&"n64_level_plugin") or not is_instance_valid(_level):
		return
	if layer.get("kind") == &"ao_layer":
		Engine.get_meta(&"n64_level_plugin").grade_set_ao_layer(int(layer.ao_id), _level)
		_status.text = "Painting AO layer %s (Paint on: left button darkens, Shift erases)." % layer.name
		return
	if layer.get("paint") == null:
		return
	Engine.get_meta(&"n64_level_plugin").grade_set_paint_layer(int(layer.paint), _level)
	_status.text = "Painting: %s (Paint on: left button; tool and brush in the Paint panel)." % layer.name


## The face mask's faces get their own variant of their texture (a new layer under it).
func _make_variants() -> void:
	if not Engine.has_meta(&"n64_level_plugin"):
		return
	var host = Engine.get_meta(&"n64_level_plugin")
	if host.grade_mask_size() == 0:
		_status.text = "Mask faces first: Paint on, Cmd / Ctrl + click (or drag a box) on the faces."
		return
	var n: int = host.grade_mask_variants()
	_status.text = "%d variant%s for the masked faces (in the tree under their textures)." % [n, "" if n == 1 else "s"]
	_rebuild_tree()


# --- AO layers -----------------------------------------------------------------------

var _ao_rebuild_queued := false


## AO layers are folded into the level's mesh (LevelBrush.build_painted_mesh): their
## settings changing rebuilds it (debounced).
func _queue_ao_rebuild() -> void:
	if _ao_rebuild_queued or _data == null:
		return
	_ao_rebuild_queued = true
	get_tree().create_timer(0.35).timeout.connect(func():
		_ao_rebuild_queued = false
		if is_instance_valid(_level):
			_level.regrade_meshes(not _filters_on.button_pressed))


func _ao_layer(id: int) -> GradeAOLayer:
	var g := _grade()
	if g:
		for l in g.ao_layers:
			if l and l.id == id:
				return l
	return null


## AO layers node: add one. A layer: name, per-key strength / corner colour, remove.
func _ao_layers_panel(layer: Dictionary) -> void:
	var box := _filter_box
	var add := Button.new()
	add.text = "Add AO layer"
	add.pressed.connect(_add_ao_layer)
	box.add_child(add)
	var l := _ao_layer(int(layer.get("ao_id", -1)))
	if l == null:
		var hint := Label.new()
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override(&"font_size", 11)
		hint.text = "Pick a layer to paint it (Paint on) and set how it shades each time of day."
		box.add_child(hint)
		return
	var name := LineEdit.new()
	name.text = l.name
	name.text_submitted.connect(func(t): _set_ao_layer(l, &"name", t))
	name.focus_exited.connect(func(): if name.text != l.name: _set_ao_layer(l, &"name", name.text))
	box.add_child(name)
	var linked := CheckBox.new()
	linked.text = "Same for every time key"
	linked.button_pressed = l.linked
	linked.toggled.connect(func(on): _set_ao_layer(l, &"linked", on))
	linked.visible = _timed()
	box.add_child(linked)
	var k := _current_key()
	var i := l.slot(k)
	var info := Label.new()
	info.add_theme_font_size_override(&"font_size", 11)
	info.text = ("All keys" if l.linked else "Editing: %s (pick another key in the toolbar)" % _key_name(k)) if _timed() else "Always (this zone has one lighting)"
	box.add_child(info)
	var row := HBoxContainer.new()
	var sl_l := Label.new()
	sl_l.text = "Strength"
	sl_l.custom_minimum_size.x = 70
	row.add_child(sl_l)
	var sl := HSlider.new()
	sl.min_value = 0.0
	sl.max_value = 1.0
	sl.step = 0.01
	sl.value = l.strength[i]
	sl.size_flags_horizontal = SIZE_EXPAND_FILL
	sl.size_flags_vertical = SIZE_SHRINK_CENTER
	sl.tooltip_text = "How far fully painted corners go towards the corner colour (0 = this key ignores the layer)."
	var val := Label.new()
	val.text = "%.2f" % sl.value
	val.custom_minimum_size.x = 36
	sl.value_changed.connect(func(v):
		val.text = "%.2f" % v
		_set_ao_layer(l, &"strength", v))
	row.add_child(sl)
	row.add_child(val)
	box.add_child(row)
	var trow := HBoxContainer.new()
	var tl := Label.new()
	tl.text = "Corner colour"
	tl.custom_minimum_size.x = 70
	trow.add_child(tl)
	var pick := ColorPickerButton.new()
	pick.color = l.tint[i]
	pick.edit_alpha = false
	_okhsl(pick)
	pick.size_flags_horizontal = SIZE_EXPAND_FILL
	pick.color_changed.connect(func(c): _set_ao_layer(l, &"tint", c))
	trow.add_child(pick)
	box.add_child(trow)
	var remove := Button.new()
	remove.text = "Remove layer (and its paint)"
	remove.pressed.connect(func(): _remove_ao_layer(l))
	box.add_child(remove)


func _add_ao_layer() -> void:
	if _data == null:
		return
	if _edit_shared:
		_status.text = "AO layers are painted on this zone's faces: switch the toolbar to Edit: this zone."
		return
	var g := _grade()
	var attach := g == null
	if attach:
		g = ZoneGrade.new()
	var l := GradeAOLayer.new()
	l.id = g.next_ao_id()
	l.name = "AO layer %d" % l.id
	var list := g.ao_layers.duplicate()
	list.append(l)
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Add AO Layer", UndoRedo.MERGE_DISABLE, _level)
	if attach:
		ur.add_do_property(_data, &"grade", g)
		ur.add_undo_property(_data, &"grade", _data.grade)
	ur.add_do_property(g, &"ao_layers", list)
	ur.add_undo_property(g, &"ao_layers", g.ao_layers)
	ur.add_do_method(self, &"_after_structure")
	ur.add_undo_method(self, &"_after_structure")
	ur.commit_action()
	_sel = [&"ao_layer", "ao_layer/%d" % l.id, null, l.name]
	_rebuild_tree()


## One AO layer setting (strength / tint: the current key, or every key when linked).
func _set_ao_layer(l: GradeAOLayer, prop: StringName, value: Variant) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("AO Layer: " + String(prop).capitalize(), UndoRedo.MERGE_ENDS, _level)
	if prop == &"strength" or prop == &"tint":
		var arr = l.get(prop).duplicate()
		if l.linked:
			for k in 4:
				arr[k] = value
		else:
			arr[_current_key()] = value
		ur.add_do_property(l, prop, arr)
	else:
		ur.add_do_property(l, prop, value)
	ur.add_undo_property(l, prop, l.get(prop))
	ur.add_do_method(self, &"_queue_ao_rebuild")
	ur.add_undo_method(self, &"_queue_ao_rebuild")
	ur.commit_action()
	if prop == &"linked" or prop == &"name":
		_panel_sig = ""
		_queue_rebuild()


## Removes a layer and its paint from every brush (one undo step).
func _remove_ao_layer(l: GradeAOLayer) -> void:
	var g := _grade()
	if g == null:
		return
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Remove AO Layer", UndoRedo.MERGE_DISABLE, _level)
	var list := g.ao_layers.duplicate()
	list.erase(l)
	ur.add_do_property(g, &"ao_layers", list)
	ur.add_undo_property(g, &"ao_layers", g.ao_layers)
	for b: LevelBrush in _data.brushes:
		if b and b.ao_paint.has(l.id):
			var d := b.ao_paint.duplicate()
			d.erase(l.id)
			ur.add_do_property(b, &"ao_paint", d)
			ur.add_undo_property(b, &"ao_paint", b.ao_paint)
	ur.add_do_method(self, &"_after_structure")
	ur.add_undo_method(self, &"_after_structure")
	ur.commit_action()
	_sel = [&"ao_layers", "vertex/ao_layers", null, "AO layers"]
	_rebuild_tree()


# --- Reference area ------------------------------------------------------------------

## The reference picture, or only its dragged area.
func _ref_image() -> Image:
	var img := Image.load_from_file(_ref_path)
	if img and _ref_area.has_area():
		img = img.get_region(_ref_area.intersection(Rect2i(Vector2i.ZERO, img.get_size())))
	return img


func _ref_scale() -> float:
	var t := _ref_rect.texture
	return float(t.get_width()) / maxf(_ref_rect.size.x, 1.0) if t else 1.0


func _on_ref_input(ev: InputEvent) -> void:
	if _ref_rect.texture == null:
		return
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_RIGHT and ev.pressed:
		_ref_area = Rect2i()
		_ref_label.text = _ref_path.get_file()
		_ref_rect.queue_redraw()
	elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		if ev.pressed:
			_ref_drag = ev.position
		else:
			var r := Rect2(_ref_drag, Vector2.ZERO).expand(ev.position)
			var k := _ref_scale()
			if r.size.x > 4 and r.size.y > 4:
				_ref_area = Rect2i(Vector2i(r.position * k), Vector2i(r.size * k))
				_ref_label.text = "%s · area %d×%d" % [_ref_path.get_file(), _ref_area.size.x, _ref_area.size.y]
			_ref_drag = Vector2(-1, -1)
			_ref_rect.queue_redraw()
	elif ev is InputEventMouseMotion and _ref_drag.x >= 0:
		_ref_rect.set_meta(&"drag_to", ev.position)
		_ref_rect.queue_redraw()


func _draw_ref_area() -> void:
	var col := Color(1.0, 0.6, 0.2)
	if _ref_drag.x >= 0 and _ref_rect.has_meta(&"drag_to"):
		_ref_rect.draw_rect(Rect2(_ref_drag, Vector2.ZERO).expand(_ref_rect.get_meta(&"drag_to")), col, false, 1.5)
	elif _ref_area.has_area():
		var k := _ref_scale()
		_ref_rect.draw_rect(Rect2(Vector2(_ref_area.position) / k, Vector2(_ref_area.size) / k), col, false, 1.5)


# --- Shared grades -------------------------------------------------------------------

const SHARED_DIR := "res://textures/_grade/shared"


## The Zone filters layer shows where the zone's grade comes from and how to share it.
func _show_shared(on: bool) -> void:
	_shared_box.visible = on
	if not on:
		return
	for c in _shared_box.get_children():
		c.queue_free()
	var root := _grade_root()
	var sh := root.shared_grade() if root else null
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override(&"font_size", 11)
	l.text = ("Shared grade: %s (its filters first in every layer, this zone's on top; switch what you edit in the toolbar)." % sh.resource_path.get_file()) if sh \
		else "No shared grade: this zone's filters are its own."
	_shared_box.add_child(l)
	var row := HBoxContainer.new()
	_shared_box.add_child(row)
	if sh:
		var detach := Button.new()
		detach.text = "Detach (keep its look)"
		detach.tooltip_text = "Stops using the shared grade; its filters are copied into this zone so nothing changes."
		detach.pressed.connect(_detach_shared)
		row.add_child(detach)
	else:
		var make := Button.new()
		make.text = "Make shared..."
		make.tooltip_text = "Moves this zone's filters (all but variants) and AO into a new shared grade file that\nother zones can use; this zone then uses it."
		make.pressed.connect(func(): _shared_dialog(true))
		row.add_child(make)
	var use := Button.new()
	use.text = "Use shared..." if not sh else "Use another..."
	use.tooltip_text = "This zone's grade sits on top of a shared grade file (its filters first in every layer)."
	use.pressed.connect(func(): _shared_dialog(false))
	row.add_child(use)


func _shared_dialog(save: bool) -> void:
	DirAccess.make_dir_recursive_absolute(SHARED_DIR)
	var dlg := EditorFileDialog.new()
	dlg.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE if save else EditorFileDialog.FILE_MODE_OPEN_FILE
	dlg.access = EditorFileDialog.ACCESS_RESOURCES
	dlg.current_dir = SHARED_DIR
	dlg.filters = PackedStringArray(["*.tres ; Shared grade"])
	dlg.file_selected.connect(func(path):
		dlg.queue_free()
		if save:
			_make_shared(path)
		else:
			var r = load(path)
			if r is ZoneGrade:
				_set_shared(r)
			else:
				_status.text = "%s isn't a grade." % path.get_file())
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_file_dialog()


## This zone's filters (all but its variants') and AO into a new shared grade at `path`.
func _make_shared(path: String) -> void:
	if _data == null:
		return
	var root := _grade_root()
	var attach := root == null
	if attach:
		root = ZoneGrade.new()
	var sh := ZoneGrade.new()
	var own := {}
	for k in root.stacks:
		if k is TextureLook:
			own[k] = root.stacks[k]
		else:
			sh.stacks[k] = root.stacks[k]
	sh.ao = root.ao
	if ResourceSaver.save(sh, path) != OK:
		_status.text = "Couldn't save %s." % path
		return
	sh = load(path)
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Make Shared Grade", UndoRedo.MERGE_DISABLE, _level)
	if attach:
		ur.add_do_property(_data, &"grade", root)
		ur.add_undo_property(_data, &"grade", _data.grade)
	ur.add_do_property(root, &"stacks", own)
	ur.add_undo_property(root, &"stacks", root.stacks)
	ur.add_do_property(root, &"ao", null)
	ur.add_undo_property(root, &"ao", root.ao)
	ur.add_do_property(root, &"shared", sh)
	ur.add_undo_property(root, &"shared", root.shared)
	ur.add_do_method(self, &"refresh_level")
	ur.add_undo_method(self, &"refresh_level")
	ur.commit_action()
	_status.text = "Shared grade %s made; other zones: Zone filters > Use shared..." % path.get_file()


func _set_shared(sh: ZoneGrade) -> void:
	if _data == null:
		return
	var root := _grade_root()
	var attach := root == null
	if attach:
		root = ZoneGrade.new()
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Use Shared Grade", UndoRedo.MERGE_DISABLE, _level)
	if attach:
		ur.add_do_property(_data, &"grade", root)
		ur.add_undo_property(_data, &"grade", _data.grade)
	ur.add_do_property(root, &"shared", sh)
	ur.add_undo_property(root, &"shared", root.shared)
	ur.add_do_method(self, &"refresh_level")
	ur.add_undo_method(self, &"refresh_level")
	ur.commit_action()
	_queue_process()


## Stops using the shared grade, its filters (copies) put under this zone's own.
func _detach_shared() -> void:
	var root := _grade_root()
	var sh := root.shared_grade() if root else null
	if sh == null:
		return
	var stacks := {}
	for k in root.stacks:
		stacks[k] = (root.stacks[k] as Array).duplicate()
	for k in sh.stacks:
		var copies := (sh.stacks[k] as Array).map(func(f): return f.duplicate(true))
		stacks[k] = copies + stacks.get(k, [])
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Detach Shared Grade", UndoRedo.MERGE_DISABLE, _level)
	ur.add_do_property(root, &"stacks", stacks)
	ur.add_undo_property(root, &"stacks", root.stacks)
	if root.ao == null and sh.ao:
		ur.add_do_property(root, &"ao", sh.ao.duplicate(true))
		ur.add_undo_property(root, &"ao", null)
	ur.add_do_property(root, &"shared", null)
	ur.add_undo_property(root, &"shared", sh)
	ur.add_do_method(self, &"refresh_level")
	ur.add_undo_method(self, &"refresh_level")
	ur.commit_action()
	_edit_shared = false


## The shared grade is its own file: saved a moment after edits (every zone using it
## picks them up when it loads).
func _queue_shared_save() -> void:
	var root := _grade_root()
	if _shared_save_queued or root == null or root.shared_grade() == null:
		return
	_shared_save_queued = true
	get_tree().create_timer(1.0).timeout.connect(func():
		_shared_save_queued = false
		var r := _grade_root()
		var sh := r.shared_grade() if r else null
		if sh and sh.resource_path != "":
			ResourceSaver.save(sh, sh.resource_path))


# --- Decals --------------------------------------------------------------------------

## Placing (left click on a surface), dragging the selected decal, its keys. True: taken.
func _decal_input(ev: InputEvent) -> bool:
	if _data == null or not is_instance_valid(_level) or _paint_btn.button_pressed or _drag != 0:
		return false
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		if not ev.pressed:
			if _decal_drag:
				_decal_drag = false
				return true
			return false
		_container.grab_focus()
		var hit := _hit(ev.position)
		if hit.is_empty():
			return false
		if _decal_place:
			_place_decal(hit)
			return true
		# On the selected decal: drag it. On another: select that one.
		if _sel_decal and _sel_decal.covers(hit.local):
			_decal_drag = true
			return true
		for i in range(_data.decals.size() - 1, -1, -1):
			var d: LevelDecal = _data.decals[i]
			if d and d.covers(hit.local):
				_select_decal(d)
				return true
		return false
	if ev is InputEventMouseMotion and _decal_drag and _sel_decal:
		var hit := _hit(ev.position)
		if not hit.is_empty():
			_set_decal(_sel_decal, {position = hit.local, normal = hit.local_normal}, "Move Decal")
		return true
	if ev is InputEventKey and ev.pressed and _sel_decal and not ev.is_command_or_control_pressed():
		match ev.keycode:
			KEY_R:
				_set_decal(_sel_decal, {rotation = wrapf(_sel_decal.rotation + (-15.0 if ev.shift_pressed else 15.0), -180.0, 180.0)}, "Turn Decal")
				return true
			KEY_BRACKETLEFT, KEY_BRACKETRIGHT:
				var k := 0.9 if ev.keycode == KEY_BRACKETLEFT else 1.0 / 0.9
				_set_decal(_sel_decal, {size = (_sel_decal.size * k).max(Vector2(0.05, 0.05))}, "Size Decal")
				return true
			KEY_DELETE, KEY_BACKSPACE:
				_remove_decal(_sel_decal)
				return true
	return false


## The drawn surface under a view point: {position, local (level space), local_normal} or
## {}. Looks through faces that are only collision (a prop's invisible box): decals land on
## what's drawn.
func _hit(pos: Vector2) -> Dictionary:
	var from := _cam.project_ray_origin(pos)
	var dir := _cam.project_ray_normal(pos)
	var hit := {}
	for _i in 8:
		hit = _level.raycast(from, dir)
		if hit.is_empty() or (hit.brush as LevelBrush).face_visual(hit.face):
			break
		from = hit.position + dir * 0.01
		hit = {}
	if hit.is_empty():
		return {}
	var inv := _level.global_transform.affine_inverse()
	hit.local = inv * hit.position
	hit.local_normal = (inv.basis * hit.normal).normalized()
	return hit


func _place_decal(hit: Dictionary) -> void:
	if _place_tex == null:
		_status.text = "Pick the decal texture first (Decals panel: Texture to place)."
		return
	var d := LevelDecal.new()
	d.texture = _place_tex
	d.position = hit.local
	d.normal = hit.local_normal
	# Upright on walls; on floors and ceilings, the image's top away from the camera.
	if absf(d.normal.y) > 0.7:
		var inv := _level.global_transform.affine_inverse()
		var fwd: Vector3 = inv.basis * -_cam.global_transform.basis.z
		d.up = Vector3(fwd.x, 0.0, fwd.z).normalized() if Vector2(fwd.x, fwd.z).length() > 0.01 else Vector3.FORWARD
	else:
		d.up = Vector3.UP
	d.size = Vector2(1.0, float(_place_tex.get_height()) / maxf(_place_tex.get_width(), 1.0))
	var list := _data.decals.duplicate()
	list.append(d)
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Place Decal", UndoRedo.MERGE_DISABLE, _level)
	ur.add_do_property(_data, &"decals", list)
	ur.add_undo_property(_data, &"decals", _data.decals)
	ur.add_do_method(self, &"_rebuild_tree")
	ur.add_undo_method(self, &"_rebuild_tree")
	ur.commit_action()
	_select_decal(d)


func _remove_decal(d: LevelDecal) -> void:
	var list := _data.decals.duplicate()
	list.erase(d)
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Remove Decal", UndoRedo.MERGE_DISABLE, _level)
	ur.add_do_property(_data, &"decals", list)
	ur.add_undo_property(_data, &"decals", _data.decals)
	ur.add_do_method(self, &"_rebuild_tree")
	ur.add_undo_method(self, &"_rebuild_tree")
	ur.commit_action()
	_sel_decal = null
	_sel = [&"decals", null, null, "Decals"]
	_rebuild_tree()
	_update_highlight()


## Decal properties as one undo step (repeats of `name` merge: a drag is one step).
func _set_decal(d: LevelDecal, values: Dictionary, name: String) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action(name, UndoRedo.MERGE_ENDS, _level)
	for k in values:
		ur.add_do_property(d, k, values[k])
		ur.add_undo_property(d, k, d.get(k))
	ur.add_do_method(self, &"_update_highlight")
	ur.add_undo_method(self, &"_update_highlight")
	ur.commit_action()


func _select_decal(d: LevelDecal) -> void:
	var i := _data.decals.find(d)
	_sel = [&"decal", null, null, d.title()]
	_rebuild_tree()
	# (titles can repeat: pick the item by index)
	var stack: Array[TreeItem] = [_tree.get_root()]
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		for c in it.get_children():
			var n: Dictionary = c.get_metadata(0)
			if n.kind == &"decal" and n.decal == i:
				var p := c.get_parent()
				while p:
					p.collapsed = false
					p = p.get_parent()
				c.select(0)
				_tree.scroll_to_item(c)
				return
			stack.append(c)


func _decals_panel(layer: Dictionary) -> void:
	var box := _filter_box
	var place := CheckButton.new()
	place.text = "Place decals (click a surface)"
	place.button_pressed = _decal_place
	place.toggled.connect(func(on):
		_decal_place = on
		if on:
			_paint_btn.button_pressed = false)
	box.add_child(place)
	box.add_child(_texture_row("Texture to place", _place_tex, func(t):
		_place_tex = t
		EditorInterface.get_editor_settings().set_project_metadata("n64_grade", "decal_texture", t.resource_path if t else "")))
	var d := _sel_decal
	if d == null:
		var hint := Label.new()
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override(&"font_size", 11)
		hint.text = "Pick a texture with transparency (cut out at half alpha) and click surfaces. Click a decal (Place off) to select it; drag it to move."
		box.add_child(hint)
		return
	box.add_child(HSeparator.new())
	box.add_child(_texture_row("Texture", d.texture, func(t): _set_decal(d, {texture = t}, "Decal Texture")))
	for spec in [[&"width", "Width (m)", 0.05, 20.0, d.size.x], [&"height", "Height (m)", 0.05, 20.0, d.size.y],
			[&"rotation", "Rotation (°)", -180.0, 180.0, d.rotation], [&"depth", "Depth (m)", 0.02, 3.0, d.depth],
			[&"max_angle", "Max angle (°)", 10.0, 89.0, d.max_angle]]:
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = spec[1]
		l.custom_minimum_size.x = 90
		row.add_child(l)
		var sp := SpinBox.new()
		sp.min_value = spec[2]
		sp.max_value = spec[3]
		sp.step = 0.01 if spec[0] in [&"width", &"height", &"depth"] else 1.0
		sp.value = spec[4]
		sp.size_flags_horizontal = SIZE_EXPAND_FILL
		var prop: StringName = spec[0]
		sp.value_changed.connect(func(v):
			if prop == &"width":
				_set_decal(d, {size = Vector2(v, d.size.y)}, "Size Decal")
			elif prop == &"height":
				_set_decal(d, {size = Vector2(d.size.x, v)}, "Size Decal")
			else:
				_set_decal(d, {prop: v}, "Decal " + String(prop).capitalize()))
		row.add_child(sp)
		box.add_child(row)
	var row2 := HBoxContainer.new()
	var aspect := Button.new()
	aspect.text = "Match texture aspect"
	aspect.pressed.connect(func():
		if d.texture:
			_set_decal(d, {size = Vector2(d.size.x, d.size.x * d.texture.get_height() / maxf(d.texture.get_width(), 1.0))}, "Size Decal")
			_panel_sig = ""
			_show_panel(_sel_node))
	row2.add_child(aspect)
	var del := Button.new()
	del.text = "Delete"
	del.pressed.connect(func(): _remove_decal(d))
	row2.add_child(del)
	box.add_child(row2)


func _texture_row(label: String, tex: Texture2D, set_fn: Callable) -> Control:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 90
	row.add_child(l)
	var pick := EditorResourcePicker.new()
	pick.base_type = "Texture2D"
	pick.edited_resource = tex
	pick.size_flags_horizontal = SIZE_EXPAND_FILL
	pick.resource_changed.connect(func(r): set_fn.call(r as Texture2D))
	row.add_child(pick)
	return row
