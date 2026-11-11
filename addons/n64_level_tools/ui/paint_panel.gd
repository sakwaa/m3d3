@tool
extends PanelContainer
## Paint-mode flyout: layer stack (base + overlays), layer settings, tools, brush and fill
## options. Pure UI: emits signals, the plugin applies them (with undo).

signal tool_selected(tool: int)
## Turn the overlays of the face-mask faces a quarter turn.
signal overlay_turn_requested
signal layer_selected(index: int)
signal base_texture_selected(texture: Texture2D)
## "Pick from face": the next click in the viewport takes a face's texture and UV.
signal base_pick_requested
signal layer_add_requested
signal layer_remove_requested(index: int)
## Clear an overlay layer's paint (the face-mask faces, or everywhere without a mask).
signal layer_clear_requested(index: int)
## Reset the face-mask faces: every overlay layer's paint, overlay turns, vertex colour and
## surface override (base texture and its UV stay).
signal faces_reset_requested
## Merge the face-mask faces that lie flat together and match (texture, UV, set, surface).
signal faces_merge_requested
## Overlay sets: edit set `index` (its layers fill the list), add one, rename the edited
## one, give the face-mask faces the edited one.
signal layer_set_selected(index: int)
signal layer_set_add_requested
signal layer_set_renamed(new_name: String)
signal layer_set_assign_requested
signal layer_set_duplicate_requested
signal layer_set_delete_requested
## -1 up, +1 down the set list.
signal layer_set_move_requested(dir: int)
signal layer_property_changed(index: int, property: StringName, value: Variant)
signal level_property_changed(property: StringName, value: Variant)
signal brush_changed(property: StringName, value: Variant)
signal brush_add_requested
signal vertex_color_changed(color: Color)
signal vertex_ao_requested(add: bool)
signal vertex_ao_clear_requested
## Scatter: make a flat cover texture of the scatter items (px size) for an overlay layer.
signal scatter_cover_requested(size: int)

const ICON_DIR := "res://addons/n64_level_tools/icons/"
const TOOL_ICONS := ["paint_brush", "paint_erase", "paint_fill", "paint_normal", "paint_face", "paint_fill_same",
	"paint_scatter", "paint_place", "paint_gradient", "paint_border", "paint_grass", "paint_trees"]
const BRUSH_DIR := "res://brushes"

var _scale := 1.0
var _data: LevelData
var _layer := 0
var _updating := false

var _layers: ItemList
var _set_pick: OptionButton
## Set row icon buttons by editor icon name (Duplicate, MoveUp, MoveDown, Remove).
var _set_buttons := {}
var _set_name: LineEdit
var _mask_sets: Label
var _remove_layer: Button
var _base_box: VBoxContainer
var _base_picker: N64TexturePicker
var _base_tile: SpinBox
var _base_var: HSlider
var _base_var_size: SpinBox
var _base_var_mode: OptionButton
var _layer_var: HSlider
var _layer_var_size: SpinBox
var _layer_var_mode: OptionButton
var _noise_cov: HSlider
## Vertex AO bake settings (also used by the toolbar's Bake AO button).
var ao_strength: HSlider
var ao_radius: SpinBox
var ao_add: CheckBox
var _shade_color: ColorPickerButton
var _shade_row: Control
var _noise_size: SpinBox
var _noise_soft: HSlider
var _noise_combine: OptionButton
var _noise_base: N64TexturePicker
var _layer_box: VBoxContainer
var _layer_name: LineEdit
var _layer_picker: N64TexturePicker
var _layer_blend: OptionButton
var _layer_opacity: HSlider
var _layer_tile: SpinBox
var _base_tile_auto: Button
## Every texture this level sizes itself (base_tile_sizes), each with an Auto button.
var _overrides_box: VBoxContainer
var _layer_visible: CheckBox
var _edge_box: VBoxContainer
var _edge_sharp: HSlider
var _edge_noise: HSlider
var _edge_darken: HSlider
var _order_row: Control
var _edge_shadow: HSlider
var _order: HSlider
var _base_tint_check: CheckBox
var _base_dark: ColorPickerButton
var _base_light: ColorPickerButton
var _layer_tint_check: CheckBox
var _layer_dark: ColorPickerButton
var _layer_light: ColorPickerButton
var _base_texture: Texture2D
## Colouring controls edit the level's setting for the texture (every face using it) instead
## of the look of what's painted next.
var _level_wide: CheckBox
var _base_color: ColorPickerButton
var _color_mode: OptionButton
## The look of what's painted next (as the paint tool has it).
var _paint_look := {}
var _vertex_box: VBoxContainer
var _surface_box: VBoxContainer
var _surface_sound: OptionButton
var _surface_flags: Array[CheckBox] = []
var _surface_camera: OptionButton
var _vertex_color: ColorPickerButton
var _vertex_bright: HSlider
var _color_range: OptionButton
var _base_bright: HSlider
var _rotation: OptionButton
var _follow_slope: CheckBox
var _stay: CheckBox
var _tool_buttons: Array[Button] = []
var _size: HSlider
var _strength: HSlider
var _hardness: HSlider
var _shape: OptionButton
var _normal_box: Control
var _scatter_box: Control
var _scatter_list: ItemList
var _scatter_items: Array[Texture2D] = []
var _scatter_style: OptionButton
var _scatter_size: SpinBox
var _scatter_jitter: HSlider
var _scatter_density: SpinBox
var _scatter_edge: OptionButton
var _scatter_edge_dark: HSlider
var _gradient_box: Control
var _border_box: Control
var _border_width: HSlider
var _border_follow: CheckBox
var _border_corner: OptionButton
var _border_direction: OptionButton
var _border_soft: HSlider
var _border_blend: OptionButton
var _border_shadow: HSlider
var _border_darken: HSlider
var _gradient_stops: GradientStopsEdit
var _gradient_dir: OptionButton
var _gradient_style: OptionButton
var _gradient_cover: HSlider
var _gradient_second: OptionButton
var _gradient_combine: OptionButton
var _gradient_blend: OptionButton
var _direction: OptionButton
var _angle: HSlider
var _soft: HSlider
var _n64_filter: CheckBox
var _density: SpinBox
var _preview_hour: SpinBox
var _body: VBoxContainer
## The "Layer setup" section's halves for each layer kind (Paint on keeps the essentials).
var _base_setup: VBoxContainer
var _vertex_setup: VBoxContainer
var _layer_setup: VBoxContainer
## Tool option rows shown only for the tools (and layers) that use them.
var _tool := 0
var _size_row: Control
var _strength_row: Control
var _hardness_row: Control
var _shape_row: Control
const SECTION_COLOR := Color(0.55, 0.9, 0.55)
## Sections that start collapsed (rarely-touched setup).
const COLLAPSED_BY_DEFAULT := ["Layer setup", "Level"]
## Tool button tooltips: name, then how it's used.
const TOOL_HINTS := [
	"Drag to paint (Alt+click: line from the last stroke)",
	"Drag to erase",
	"Click: the whole flat surface (Alt: just the face)",
	"Click: every face facing the chosen direction",
	"Drag: each face crossed, whole",
	"Click: connected faces with the same base texture",
	"Drag to fill the brush circle with the items (Shift: erase)",
	"Click: one item (Shift: remove)",
	"Click a face: gradient across the face mask (else that face) in the direction set.\nDrag: from press (0 %) to release (100 %). Shift: erase. Overlay layers only.",
	"Click a face: a band of the overlay layer along the outer edge of the face mask\n(else the flat surface clicked). Any shape, across brushes. Shift: erase. Overlay layers only.",
	"Drag: grass carpet of the height set, on any ground (Shift: erase carpet, also where\nit grows by itself on grass textures). The outline rounds and frays by itself.",
	"Drag: plant trees of the species listed over the ground, spaced apart, each its own seed,\nsize and turn (Shift: remove trees). Each is a tree brush to edit after. One tree: Props > Tree.",
]
## Section title -> {button, content}.
var _sections := {}


func _init(panel_style: StyleBox = null, button_factory: Callable = Callable()) -> void:
	_scale = EditorInterface.get_editor_scale()
	mouse_filter = MOUSE_FILTER_STOP
	size_flags_vertical = SIZE_SHRINK_BEGIN
	if panel_style:
		add_theme_stylebox_override(&"panel", panel_style)
	custom_minimum_size.x = 230 * _scale
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = 420 * _scale
	add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(_body)

	# "Paint on": the layer list (sized to its rows: no inner scrolling) and its buttons.
	var paint_on := VBoxContainer.new()
	_build_set_rows(paint_on)
	_layers = ItemList.new()
	_layers.auto_height = true
	_layers.item_selected.connect(func(i): _select_layer(i, true))
	paint_on.add_child(_layers)
	var layer_row := HBoxContainer.new()
	paint_on.add_child(layer_row)
	var add := Button.new()
	add.text = "+ Overlay"
	add.tooltip_text = "Add an overlay layer (max %d)" % LevelData.MAX_LAYERS
	add.pressed.connect(func(): layer_add_requested.emit())
	layer_row.add_child(add)
	_remove_layer = Button.new()
	_remove_layer.text = "Remove"
	_remove_layer.pressed.connect(func(): layer_remove_requested.emit(_layer - 1))
	layer_row.add_child(_remove_layer)
	var reset := Button.new()
	reset.text = "Reset faces"
	reset.tooltip_text = "Puts the face-mask faces (Cmd/Ctrl+click or drag) back to plain base texture:\nremoves paint on every overlay layer, overlay turns, vertex colour and surface\noverrides. The base texture and its UV stay. Undoable."
	reset.pressed.connect(func(): faces_reset_requested.emit())
	layer_row.add_child(reset)
	var merge := Button.new()
	merge.text = "Merge faces"
	merge.tooltip_text = "Joins face-mask faces (Cmd/Ctrl+click or drag) that touch, lie in one plane and match\n(base texture, UV, overlay set, surface) into bigger faces: e.g. squares a border's\ncorners cut up. Painted overlays carry over. Whole grid squares merge too, so mask only\nthe pieces (fewer faces to sculpt). Undoable."
	merge.pressed.connect(func(): faces_merge_requested.emit())
	layer_row.add_child(merge)

	# Base layer: what to paint (Paint on) and the texture's level look (Layer setup).
	_base_box = VBoxContainer.new()
	paint_on.add_child(_base_box)
	_base_setup = VBoxContainer.new()
	_base_picker = _picker(_base_box, "Texture to apply")
	_base_picker.resource_changed.connect(func(r): _base_texture = r; base_texture_selected.emit(r); _refresh_base_tint({}))
	var pick := Button.new()
	pick.text = "Pick from face (I)"
	pick.icon = EditorInterface.get_editor_theme().get_icon(&"ColorPick", &"EditorIcons")
	pick.tooltip_text = "Click a face (or press I over it) to take its texture, offset, scale and rotation"
	pick.pressed.connect(func(): base_pick_requested.emit())
	_base_box.add_child(pick)
	_level_wide = CheckBox.new()
	_level_wide.text = "Level-wide"
	_level_wide.tooltip_text = "Off: palette, colour, tile size and variation below tune only what you paint next\n(faces painted before keep their look). On: they change this texture across the level."
	_level_wide.toggled.connect(func(_on): _refresh_base_tint(_paint_look))
	_row(_base_setup, "Colouring", _level_wide)
	var base_tint := _tint_row(_base_setup, "Palette")
	_base_tint_check = base_tint[0]
	_base_dark = base_tint[1]
	_base_light = base_tint[2]
	_base_tint_check.tooltip_text = "Recolour the texture with this dark / light palette (e.g. darker grass in a dungeon)."
	_base_color = ColorPickerButton.new()
	_base_color.color = Color.WHITE
	_base_color.custom_minimum_size = Vector2(32, 0) * _scale
	_base_color.tooltip_text = "Multiplied over the texture (darker, warmer, cooler). White = unchanged.\nTunes what you paint next (not used Level-wide)."
	_base_color.popup_closed.connect(_emit_look)
	_base_color.color_changed.connect(func(_c): _emit_look())
	_color_mode = OptionButton.new()
	_color_mode.add_item("As vertex colour")
	_color_mode.add_item("In texture")
	_color_mode.add_item("Recolour texture")
	_color_mode.tooltip_text = "As vertex colour: the painted faces' vertex colours multiply the texture (no extra material;\nrefine it with the Vertex colour layer). In texture: a separate look of the texture.\nRecolour texture: the vertex colour becomes the texture's colour, the texture keeping only its\nbrightness detail (like N64 intensity textures): straw grass from green.\nOne extra material per texture; colours stay per vertex."
	_color_mode.item_selected.connect(func(i): if not _updating: brush_changed.emit(&"color_mode", i))
	var color_row := HBoxContainer.new()
	color_row.add_child(_base_color)
	color_row.add_child(_color_mode)
	_row(_base_setup, "Colour", color_row)
	_base_bright = _slider(_base_setup, "Brightness", 0.0, 2.0, 0.05)
	_base_bright.value = 1.0
	_base_bright.tooltip_text = "Scales the colour. Above 1 brightens: needs the level's 2× colour range (Vertex colour layer)."
	_base_bright.value_changed.connect(func(_v): _emit_look())
	_base_tint_check.toggled.connect(func(_on): _emit_base_tint())
	_base_dark.popup_closed.connect(_emit_base_tint)
	_base_light.popup_closed.connect(_emit_base_tint)
	_base_tile = _spin(_base_setup, "Tile size (m)", 0.1, 16.0, 0.1)
	_base_tile.tooltip_text = "Metres per repeat of the texture to apply, in this level.\nDefault: the texture's World size (Auto = width in px / project texels per metre).\nApplies to every face using it. Changing it makes a level override (beats the project density)."
	_base_tile.value_changed.connect(_emit_base_tile)
	_base_tile_auto = Button.new()
	_base_tile_auto.text = "Auto"
	_base_tile_auto.tooltip_text = "Remove this level's override: use the texture's own size\n(project texels per metre)."
	_base_tile_auto.pressed.connect(_reset_base_tile)
	_base_tile.get_parent().add_child(_base_tile_auto)
	_rotation = OptionButton.new()
	for deg in [0, 90, 180, 270]:
		_rotation.add_item("%d°" % deg)
	_rotation.tooltip_text = "Turns the texture on the faces it's painted on (bricks along a\nnorth-south path vs east-west). R: next quarter turn, Shift+R: back."
	_rotation.item_selected.connect(func(i): if not _updating: brush_changed.emit(&"rotation", i * 90.0))
	_row(_base_box, "Rotation", _rotation)
	_follow_slope = CheckBox.new()
	_follow_slope.text = "Follow slope"
	_follow_slope.tooltip_text = "Lays the texture on each face's own plane instead of projecting it straight down /\nsideways: on a ramp it keeps its size (no stretch up the slope) and rows run level across\nit. Flat floors and straight walls look the same either way. Leave off on bumpy terrain\n(each face would get its own seam). Applies to the faces you paint."
	_follow_slope.toggled.connect(func(on): if not _updating: brush_changed.emit(&"follow_slope", on))
	_base_box.add_child(_follow_slope)
	_overrides_box = VBoxContainer.new()
	_base_setup.add_child(_overrides_box)
	var bv := _variation_rows(_base_setup)
	_base_var = bv[0]
	_base_var_size = bv[1]
	_base_var_mode = bv[2]
	_base_var.value_changed.connect(func(_v): _emit_base_variation())
	_base_var_size.value_changed.connect(func(_v): _emit_base_variation())
	_base_var_mode.item_selected.connect(func(_i): _emit_base_variation())

	# Vertex colour: colour to paint (Paint on); range and AO (Layer setup).
	_vertex_box = VBoxContainer.new()
	paint_on.add_child(_vertex_box)
	_vertex_setup = VBoxContainer.new()
	_vertex_color = ColorPickerButton.new()
	_vertex_color.color = Color(0.45, 0.4, 0.38)
	_vertex_color.tooltip_text = "Colour painted into vertices; it multiplies the final shade (white = unchanged)."
	_vertex_color.color_changed.connect(func(_c): _emit_vertex_color())
	_row(_vertex_box, "Colour", _vertex_color)
	_vertex_bright = _slider(_vertex_box, "Brightness", 0.0, 2.0, 0.05)
	_vertex_bright.value = 1.0
	_vertex_bright.tooltip_text = "Scales the colour. Above 1 brightens the texture: needs the 2× colour range."
	_vertex_bright.value_changed.connect(func(_v): _emit_vertex_color())
	_color_range = OptionButton.new()
	_color_range.add_item("1× (modulate)")
	_color_range.add_item("2× (can brighten)")
	_color_range.tooltip_text = "How this level combines vertex colour with textures (N64 colour combiner):\n1×: texture × colour; colours only darken.\n2×: texture × colour × 2; Brightness above 1 lightens (e.g. sun-dried grass).\nWhite leaves textures unchanged either way."
	_color_range.item_selected.connect(func(i): if not _updating: level_property_changed.emit(&"vertex_color_range", i))
	_row(_vertex_setup, "Colour range", _color_range)
	_vertex_color.tooltip_text += "\nShades vertices (OoT style); detail follows mesh density."
	# The level's AO settings (LevelData > Lighting), shared with the lighting bake.
	ao_strength = _slider(_vertex_setup, "AO strength", 0.0, 1.0, 0.05)
	ao_strength.tooltip_text = "How dark fully enclosed corners get (this level; also used by Bake lighting).\nRe-bakes existing vertex AO automatically."
	ao_strength.value_changed.connect(func(v): if not _updating: level_property_changed.emit(&"light_ao_strength", v))
	ao_radius = _spin(_vertex_setup, "AO radius (m)", 0.1, 10.0, 0.1)
	ao_radius.tooltip_text = "How far geometry occludes: small = tight corner / edge darkening, large = broad shading.\nRe-bakes existing vertex AO automatically."
	ao_radius.value_changed.connect(func(v): if not _updating: level_property_changed.emit(&"light_ao_radius", v))
	ao_add = CheckBox.new()
	ao_add.text = "Add to existing AO"
	ao_add.tooltip_text = "Off: replace the previous AO bake. On: multiply into it (e.g. a tight pass + a broad pass)."
	_vertex_setup.add_child(ao_add)
	var ao_row := HBoxContainer.new()
	var ao_bake := Button.new()
	ao_bake.text = "Bake vertex AO"
	ao_bake.size_flags_horizontal = SIZE_EXPAND_FILL
	ao_bake.tooltip_text = "Darkens corners and edges where geometry occludes. Stored apart from your painted\nvertex colours (multiplies them), so it can be re-baked, cleared, or hidden with the\ntoolbar's AO toggle. Works in every lighting mode. Undoable."
	ao_bake.pressed.connect(func(): vertex_ao_requested.emit(ao_add.button_pressed))
	ao_row.add_child(ao_bake)
	var ao_clear := Button.new()
	ao_clear.text = "Clear"
	ao_clear.tooltip_text = "Remove the baked vertex AO (painted colours stay)."
	ao_clear.pressed.connect(func(): vertex_ao_clear_requested.emit())
	ao_row.add_child(ao_clear)
	_vertex_setup.add_child(ao_row)
	_build_surface()
	paint_on.add_child(_surface_box)

	# Overlay layer: texture, opacity, visibility (Paint on); the rest (Layer setup).
	_layer_box = VBoxContainer.new()
	paint_on.add_child(_layer_box)
	_layer_setup = VBoxContainer.new()
	_layer_name = LineEdit.new()
	_layer_name.text_submitted.connect(func(t): _emit_layer(&"name", t))
	_layer_name.focus_exited.connect(func(): _emit_layer(&"name", _layer_name.text))
	_row(_layer_setup, "Name", _layer_name)
	_layer_picker = _picker(_layer_box, "Texture")
	_layer_picker.resource_changed.connect(func(r): _emit_layer(&"texture", r))
	_shade_color = ColorPickerButton.new()
	_shade_color.custom_minimum_size = Vector2(48, 0) * _scale
	_shade_color.edit_alpha = false
	_shade_color.tooltip_text = "No texture: the layer is this flat colour through its mask\n(black + noise mask = darkening spots; Opacity sets strength)."
	_shade_color.popup_closed.connect(func(): _emit_layer(&"shade_color", _shade_color.color))
	_row(_layer_box, "Colour", _shade_color)
	_shade_row = _shade_color.get_parent()
	_layer_blend = OptionButton.new()
	for n in PaintLayer.BLEND_NAMES:
		_layer_blend.add_item(n)
	_layer_blend.item_selected.connect(func(i):
		_show_edge(i)
		_emit_layer(&"blend", i))
	_layer_blend.tooltip_text = "Height: the edge follows texture detail (mud fills the gaps between grass) instead of cross-fading.\nHeight by order: the same, and layers further down the list stand higher, so they fill the gaps of the ones above and win where they meet."
	_row(_layer_setup, "Blend", _layer_blend)
	_edge_box = VBoxContainer.new()
	_layer_setup.add_child(_edge_box)
	_edge_sharp = _slider(_edge_box, "Edge sharp", 0.0, 1.0, 0.05)
	_edge_sharp.value_changed.connect(func(v): _emit_layer(&"edge_sharpness", v))
	_edge_noise = _slider(_edge_box, "Edge noise", 0.0, 1.0, 0.05)
	_edge_noise.value_changed.connect(func(v): _emit_layer(&"edge_noise", v))
	_edge_darken = _slider(_edge_box, "Edge darken", 0.0, 1.0, 0.05)
	_edge_darken.value_changed.connect(func(v): _emit_layer(&"edge_darken", v))
	_edge_shadow = _slider(_edge_box, "Shadow", 0.0, 1.0, 0.05)
	_edge_shadow.tooltip_text = "Darkens what's below just outside this layer's edge, so it looks like it's lying on top (0 = off)."
	_edge_shadow.value_changed.connect(func(v): _emit_layer(&"edge_shadow", v))
	_order = _slider(_edge_box, "Order height", 0.0, 1.0, 0.05)
	_order.tooltip_text = "How much higher this layer stands for each place down the list (0 = plain Height)."
	_order.value_changed.connect(func(v): _emit_layer(&"order_height", v))
	_order_row = _order.get_parent().get_parent()  # the labelled row
	_layer_opacity = _slider(_layer_box, "Opacity", 0.0, 1.0, 0.05)
	_layer_opacity.value_changed.connect(func(v): _emit_layer(&"opacity", v))
	_layer_tile = _spin(_layer_setup, "Tile size (m)", 0.0, 16.0, 0.1)
	_layer_tile.tooltip_text = "Metres per repeat of this layer's texture.\n0 = Auto: the texture's own size (project texels per metre)."
	_layer_tile.value_changed.connect(func(v): _layer_tile.suffix = "(auto)" if v <= 0.0 else "")
	_layer_tile.value_changed.connect(func(v): _emit_layer(&"tile_size", v))
	_layer_visible = CheckBox.new()
	_layer_visible.text = "Visible"
	_layer_visible.toggled.connect(func(on): _emit_layer(&"enabled", on))
	_layer_box.add_child(_layer_visible)
	var turn := Button.new()
	turn.text = "Turn overlay 90°"
	turn.tooltip_text = "Turns the overlay textures (not the base) on the face-mask faces\n(Cmd/Ctrl+click faces) a quarter turn. Undoable."
	turn.pressed.connect(func(): overlay_turn_requested.emit())
	var clear := Button.new()
	clear.text = "Clear paint"
	clear.tooltip_text = "Removes this layer's paint from the face-mask faces (Cmd/Ctrl+click faces),\nor from the whole level when nothing is masked. The layer and its settings stay. Undoable."
	clear.pressed.connect(func(): layer_clear_requested.emit(_layer - 1))
	var layer_ops := HBoxContainer.new()
	turn.size_flags_horizontal = SIZE_EXPAND_FILL
	clear.size_flags_horizontal = SIZE_EXPAND_FILL
	layer_ops.add_child(turn)
	layer_ops.add_child(clear)
	_layer_box.add_child(layer_ops)
	var lv := _variation_rows(_layer_setup)
	_layer_var = lv[0]
	_layer_var_size = lv[1]
	_layer_var_mode = lv[2]
	_layer_var.value_changed.connect(func(v): _emit_layer(&"variation", v))
	_layer_var_size.value_changed.connect(func(v): _emit_layer(&"variation_size", v))
	_layer_var_mode.item_selected.connect(func(i): _emit_layer(&"variation_mode", i))
	_noise_cov = _slider(_layer_setup, "Noise mask", 0.0, 1.0, 0.05)
	_noise_cov.tooltip_text = "Shows this layer where the shared noise is high (0 = off).\nFollows each face's own projection, so walls and floors differ."
	_noise_cov.value_changed.connect(func(v): _emit_layer(&"noise_coverage", v))
	_noise_size = _spin(_layer_setup, "Noise size (m)", 0.5, 64.0, 0.5)
	_noise_size.value_changed.connect(func(v): _emit_layer(&"noise_size", v))
	_noise_soft = _slider(_layer_setup, "Noise softness", 0.0, 1.0, 0.05)
	_noise_soft.value_changed.connect(func(v): _emit_layer(&"noise_softness", v))
	_noise_combine = OptionButton.new()
	for n in ["Noise only", "Painted + noise", "Break up painting"]:
		_noise_combine.add_item(n)
	_noise_combine.tooltip_text = "Noise only: ignore painting. Painted + noise: either shows it.\nBreak up painting: only where painted AND the noise is high."
	_noise_combine.item_selected.connect(func(i): _emit_layer(&"noise_combine", i))
	_row(_layer_setup, "Noise combine", _noise_combine)
	_noise_base = _picker(_layer_setup, "Noise only on")
	_noise_base.tooltip_text = "Limit the noise mask to faces with this base texture (None = all faces)."
	_noise_base.resource_changed.connect(func(r): _emit_layer(&"noise_base", r))
	var layer_tint := _tint_row(_layer_setup, "Palette")
	_layer_tint_check = layer_tint[0]
	_layer_dark = layer_tint[1]
	_layer_light = layer_tint[2]
	_layer_tint_check.tooltip_text = "Use this layer's own gradient colours instead of the texture's tint."
	_layer_tint_check.toggled.connect(func(on): _emit_layer(&"override_tint", on))
	_layer_dark.popup_closed.connect(func(): _emit_layer(&"tint_dark", _layer_dark.color))
	_layer_light.popup_closed.connect(func(): _emit_layer(&"tint_light", _layer_light.color))

	var tools := GridContainer.new()
	tools.columns = 5
	var group := ButtonGroup.new()
	for i in LevelPaintTool.TOOL_NAMES.size():
		var tip: String = LevelPaintTool.TOOL_NAMES[i] + "\n" + TOOL_HINTS[i]
		var b: Button = button_factory.call(_svg(TOOL_ICONS[i]), tip, true) if button_factory.is_valid() else Button.new()
		if not button_factory.is_valid():
			b.text = LevelPaintTool.TOOL_NAMES[i]
			b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(func(): tool_selected.emit(i); _update_tool_visibility(i))
		tools.add_child(b)
		_tool_buttons.append(b)
	var options := VBoxContainer.new()
	_size = _slider(options, "Size (m)", 0.1, 8.0, 0.05)
	_size.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"size", v))
	_size_row = _size.get_parent().get_parent()
	_strength = _slider(options, "Strength", 0.05, 1.0, 0.05)
	_strength.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"strength", v))
	_strength_row = _strength.get_parent().get_parent()
	_hardness = _slider(options, "Hardness", 0.0, 0.95, 0.05)
	_hardness.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"hardness", v))
	_hardness_row = _hardness.get_parent().get_parent()
	var shape_row := HBoxContainer.new()
	_shape = OptionButton.new()
	_shape.size_flags_horizontal = SIZE_EXPAND_FILL
	_shape.item_selected.connect(func(i): brush_changed.emit(&"shape", _shape.get_item_metadata(i)))
	shape_row.add_child(_shape)
	var add_brush := Button.new()
	add_brush.text = "Add…"
	add_brush.tooltip_text = "Add a custom brush (greyscale image; white paints). Copied into %s/." % BRUSH_DIR
	add_brush.pressed.connect(func(): brush_add_requested.emit())
	shape_row.add_child(add_brush)
	_row(options, "Shape", shape_row)
	_shape_row = shape_row.get_parent()
	_stay = CheckBox.new()
	_stay.text = "Stay on brush"
	_stay.tooltip_text = "A stroke only paints the brush it starts on (sweeping past a wall\nstanding on the ground leaves the wall alone; the cursor sees through it)."
	_stay.toggled.connect(func(on): if not _updating: brush_changed.emit(&"stay_on_brush", on))
	options.add_child(_stay)
	_normal_box = VBoxContainer.new()
	options.add_child(_normal_box)
	_direction = OptionButton.new()
	for n in LevelPaintTool.DIRECTION_NAMES:
		_direction.add_item(n)
	_direction.item_selected.connect(func(i): brush_changed.emit(&"direction", i))
	_row(_normal_box, "Faces", _direction)
	_angle = _slider(_normal_box, "Angle (°)", 0.0, 90.0, 1.0)
	_angle.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"angle", v))
	_soft = _slider(_normal_box, "Soft edge (°)", 0.0, 45.0, 1.0)
	_soft.tooltip_text = "Overlay layers: blend coverage across face borders over this angle band. 0 = whole faces."
	_soft.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"soft_edge", v))

	_build_scatter()
	_build_gradient()
	_build_border()
	_build_grass()
	_build_trees()
	for box in [_scatter_box, _gradient_box, _border_box, _grass_box, _trees_box]:
		options.add_child(box)

	var level := VBoxContainer.new()
	_n64_filter = CheckBox.new()
	_n64_filter.text = "N64 3-point filtering"
	_n64_filter.tooltip_text = "Project-wide: applies to every level and every n64_textured material."
	_n64_filter.toggled.connect(func(on): if not _updating: level_property_changed.emit(&"n64_three_point", on))
	level.add_child(_n64_filter)
	_density = _spin(level, "Mask px / m", 2.0, 64.0, 1.0)
	_density.value_changed.connect(func(v): if not _updating: level_property_changed.emit(&"mask_density", v))
	_preview_hour = _spin(level, "Preview hour", 0.0, 24.0, 0.25)
	_preview_hour.tooltip_text = "Shows Baked Timed lighting at this hour in the editor (keys from the project LightingSchedule)."
	_preview_hour.value = float(EditorInterface.get_editor_settings().get_project_metadata("n64_level_tools", "preview_hour", 12.0))
	_preview_hour.value_changed.connect(func(v): level_property_changed.emit(&"preview_hour", v))

	# Tool-first: tools and their options, the layer to paint on, then folded-away setup.
	_heading("Tool")
	_body.add_child(tools)
	_body.add_child(options)
	_heading("Paint on")
	_body.add_child(paint_on)
	_heading("Layer setup")
	for box in [_base_setup, _vertex_setup, _layer_setup]:
		_body.add_child(box)
	_heading("Level")
	_body.add_child(level)

	_build_sections()

	var hint := Label.new()
	hint.text = "[ ] size · Shift: erase / clear"
	hint.modulate = Color(1, 1, 1, 0.5)
	_body.add_child(hint)

	reload_brushes()
	_select_layer(0, false)


## Shows the paint settings of a level (null hides layer editing).
func set_data(data: LevelData) -> void:
	_data = data
	refresh()


func set_tool_state(tool: LevelPaintTool) -> void:
	_updating = true
	_size.value = tool.size
	_strength.value = tool.strength
	_hardness.value = tool.hardness
	_border_width.value = tool.border_width
	_border_follow.button_pressed = tool.border_follow
	_border_corner.select(tool.border_corner)
	_border_direction.select(tool.border_direction)
	_border_soft.value = tool.border_soft
	_direction.select(tool.direction)
	_angle.value = tool.angle
	_soft.value = tool.soft_edge
	_base_picker.edited_resource = tool.base_texture
	_base_texture = tool.base_texture
	_rotation.select(int(roundi(tool.rotation / 90.0)) % 4)
	_follow_slope.set_pressed_no_signal(tool.follow_slope)
	_color_mode.select(tool.color_mode)
	_stay.button_pressed = tool.stay_on_brush
	if tool.tool < _tool_buttons.size():
		_tool_buttons[tool.tool].set_pressed_no_signal(true)
	_update_tool_visibility(tool.tool)
	_update_tool_visibility(tool.tool)
	_updating = false
	_refresh_base_tint(tool.look)


## Overlay set picker above the layer list: which set the overlay rows edit.
func _build_set_rows(parent: Control) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = "Overlay set"
	row.add_child(label)
	_set_pick = OptionButton.new()
	_set_pick.size_flags_horizontal = SIZE_EXPAND_FILL
	_set_pick.tooltip_text = "Overlay layers come in sets: each face uses one (Default unless assigned).\nA barrel can use wood + metal while the ground uses dirt + grass.\nThe layers below are this set's; overlay painting only reaches its faces."
	_set_pick.item_selected.connect(func(i):
		if not _updating:
			layer_set_selected.emit(i))
	row.add_child(_set_pick)
	var add := Button.new()
	add.text = "+ Set"
	add.tooltip_text = "New, empty overlay set (up to %d layers of its own)" % LevelData.MAX_LAYERS
	add.pressed.connect(func(): layer_set_add_requested.emit())
	row.add_child(add)
	var editor_theme := EditorInterface.get_editor_theme()
	for spec in [["Duplicate", "Duplicate this overlay set (layers copied, paint not)", func(): layer_set_duplicate_requested.emit()],
			["MoveUp", "Move this set up the list", func(): layer_set_move_requested.emit(-1)],
			["MoveDown", "Move this set down the list", func(): layer_set_move_requested.emit(1)],
			["Remove", "Delete this overlay set: its faces go back to the first set and lose\nthe overlay paint made for it. Undoable.", func(): layer_set_delete_requested.emit()]]:
		var b := Button.new()
		b.icon = editor_theme.get_icon(spec[0], &"EditorIcons")
		b.flat = true
		b.tooltip_text = spec[1]
		b.pressed.connect(spec[2])
		row.add_child(b)
		_set_buttons[spec[0]] = b
	var row2 := HBoxContainer.new()
	parent.add_child(row2)
	_set_name = LineEdit.new()
	_set_name.size_flags_horizontal = SIZE_EXPAND_FILL
	_set_name.placeholder_text = "Set name"
	_set_name.tooltip_text = "Rename this overlay set (Enter)"
	_set_name.text_submitted.connect(func(t):
		layer_set_renamed.emit(t)
		_set_name.release_focus())
	_set_name.focus_exited.connect(func():
		if _data and _set_name.text != _data.layer_set_name(_data.edit_set):
			layer_set_renamed.emit(_set_name.text))
	row2.add_child(_set_name)
	var assign := Button.new()
	assign.text = "Assign to masked"
	assign.tooltip_text = "The face-mask faces (Cmd/Ctrl+click or drag) use this overlay set.\nPaint they already have stays: slot 1 now shows this set's layer 1. Undoable."
	assign.pressed.connect(func(): layer_set_assign_requested.emit())
	row2.add_child(assign)
	_mask_sets = Label.new()
	_mask_sets.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mask_sets.add_theme_color_override(&"font_color", Color(1, 1, 1, 0.6))
	_mask_sets.visible = false
	parent.add_child(_mask_sets)


## Which overlay sets the face-mask faces use (empty: no mask).
func set_mask_sets(names: Array) -> void:
	if _mask_sets == null:
		return
	_mask_sets.visible = not names.is_empty()
	if names.size() == 1:
		_mask_sets.text = "Masked faces use: %s" % names[0]
	elif names.size() > 1:
		_mask_sets.text = "Masked faces: mixed (%s)" % ", ".join(names)


func refresh() -> void:
	_updating = true
	_set_pick.clear()
	if _data:
		for i in _data.layer_set_count():
			_set_pick.add_item(_data.layer_set_name(i))
		_set_pick.select(_data.edit_set)
		_set_name.text = _data.layer_set_name(_data.edit_set)
		# Default stays first and can't go.
		_set_buttons.Remove.disabled = _data.edit_set == 0
		_set_buttons.MoveUp.disabled = _data.edit_set <= 1
		_set_buttons.MoveDown.disabled = _data.edit_set == 0 or _data.edit_set >= _data.layer_set_count() - 1
	_layers.clear()
	_layers.add_item("Base · per-face texture")
	if _data:
		for i in _data.active_layers().size():
			var l: PaintLayer = _data.active_layers()[i]
			_layers.add_item("%d · %s (%s %d%%)%s%s" % [i + 1, l.name, PaintLayer.BLEND_NAMES[l.blend], roundi(l.opacity * 100),
				"" if l.texture else " shade", "" if l.enabled else " hidden"])
		_layers.add_item("Vertex colour · shading")
		_layers.add_item("Surface · footsteps & hazards")
		_refresh_gradient_layers()
		_density.value = _data.mask_density
		ao_strength.value = _data.light_ao_strength
		_color_range.select(_data.vertex_color_range)
		_vertex_bright.max_value = _data.vertex_color_scale()
		_base_bright.max_value = _data.vertex_color_scale()
		ao_radius.value = _data.light_ao_radius
	_n64_filter.button_pressed = bool(ProjectSettings.get_setting("shader_globals/n64_three_point", {value = true}).get("value", true))
	_layer = clampi(_layer, 0, _layers.item_count - 1)
	_refresh_base_tint(_paint_look)
	_layers.select(_layer)
	_updating = false
	_select_layer(_layer, false)


func reload_brushes() -> void:
	var current = _shape.get_item_metadata(_shape.selected) if _shape.selected >= 0 else ""
	_shape.clear()
	_shape.add_item("Round (soft)")
	_shape.set_item_metadata(0, "")
	if DirAccess.dir_exists_absolute(BRUSH_DIR):
		for f in DirAccess.get_files_at(BRUSH_DIR):
			if f.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
				_shape.add_item(f.get_basename().capitalize())
				_shape.set_item_metadata(_shape.item_count - 1, BRUSH_DIR + "/" + f)
				if BRUSH_DIR + "/" + f == current:
					_shape.select(_shape.item_count - 1)


## Index of the "Vertex colour" row in the layer list.
func _vertex_row() -> int:
	return (_data.active_layers().size() if _data else 0) + 1


## Index of the "Surface" row (after Vertex colour).
func _surface_row() -> int:
	return _vertex_row() + 1


## Surface overrides: the sound and flags painted onto faces (on top of their textures').
func _build_surface() -> void:
	_surface_box = VBoxContainer.new()
	var hint := Label.new()
	hint.text = "Overrides the surface faces get from their texture: a sound replaces it, flags add. Shift clears."
	hint.tooltip_text = "Faces get their surface from their texture (inspector: N64Texture > Surface) or an overlay covering most of the face.\nCamera switches to a CameraZone's camera while standing there. The tinted overlay shows each face's surface; hover for its name."
	hint.mouse_filter = MOUSE_FILTER_PASS
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.55)
	hint.add_theme_font_size_override(&"font_size", int(11 * _scale))
	_surface_box.add_child(hint)
	_surface_sound = OptionButton.new()
	_surface_sound.add_item("From texture", 0)
	for i in range(1, Surface.SOUND_NAMES.size()):
		_surface_sound.add_item(Surface.SOUND_NAMES[i], i)
	_surface_sound.tooltip_text = "Footstep sound painted onto faces (From texture: keep the texture's)."
	_surface_sound.item_selected.connect(func(_i): _emit_surface())
	_row(_surface_box, "Sound", _surface_sound)
	var grid := GridContainer.new()
	grid.columns = 2
	var tips := ["Speed builds up and dies away slowly (ice).", "Hurts and bounces actors standing on it (lava, spikes).",
		"Sends actors back to the last safe ground, with a heart of damage (pits, deep water).",
		"The camera passes through (canopies, railings, the near side of a wall).",
		"Vines: walls and ceilings the player climbs.", "Hookshot targets (stored for the hookshot).",
		"Ledges here can't be caught or hung from (any other top edge with a wall below can)."]
	for i in Surface.FLAGS.size():
		var c := CheckBox.new()
		c.text = Surface.FLAG_NAMES[i]
		c.tooltip_text = tips[i]
		c.toggled.connect(func(_on): _emit_surface())
		grid.add_child(c)
		_surface_flags.append(c)
	_surface_box.add_child(grid)
	_surface_camera = OptionButton.new()
	_surface_camera.tooltip_text = "Standing on these faces uses this CameraZone's camera (beats camera boxes).\nAdd a CameraZone node to the scene to list it here."
	_surface_camera.item_selected.connect(func(_i): _emit_surface())
	_row(_surface_box, "Camera", _surface_camera)
	_refresh_surface_cameras()


## CameraZones of the edited scene for the Camera dropdown (id 0 = none).
func _refresh_surface_cameras() -> void:
	if _surface_camera == null:
		return
	var keep := _surface_camera.get_selected_id() if _surface_camera.item_count > 0 else 0
	_surface_camera.clear()
	_surface_camera.add_item("None", 0)
	var scene := EditorInterface.get_edited_scene_root()
	if scene:
		# Duck typed: CameraZone is game code (the shared tools mustn't depend on it).
		var zones := scene.find_children("*", "CameraZone", true, false)
		zones.sort_custom(func(a, b): return a.get(&"camera_id") < b.get(&"camera_id"))
		var modes := ["Follow", "Fixed", "Parallel", "Frame point"]
		for z in zones:
			var id: int = z.get(&"camera_id")
			if id > 0 and _surface_camera.get_item_index(id) < 0:
				_surface_camera.add_item("%d · %s (%s)" % [id, z.name, modes[clampi(z.get(&"mode"), 0, 3)]], id)
	var idx := _surface_camera.get_item_index(keep)
	_surface_camera.select(idx if idx >= 0 else 0)


func _emit_surface() -> void:
	if _updating:
		return
	var v := _surface_sound.get_selected_id()
	for i in _surface_flags.size():
		if _surface_flags[i].button_pressed:
			v |= Surface.FLAGS[i]
	v = Surface.with_camera(v, maxi(_surface_camera.get_selected_id(), 0))
	brush_changed.emit(&"surface_value", v)


func _select_layer(index: int, emit: bool) -> void:
	_layer = index
	_refresh_gradient_layers()
	if not _sections.is_empty():
		_apply_sections()
	var vertex := _data != null and index == _vertex_row()
	var surface := _data != null and index == _surface_row()
	var overlay: PaintLayer = _data.active_layers()[index - 1] if _data and index > 0 and index - 1 < _data.active_layers().size() else null
	_vertex_box.visible = vertex
	_surface_box.visible = surface
	if surface:
		_refresh_surface_cameras()
	_base_box.visible = index == 0
	_base_setup.visible = index == 0
	_vertex_setup.visible = vertex
	_layer_box.visible = overlay != null
	_layer_setup.visible = overlay != null
	if _size_row:
		_update_tool_visibility(_tool)
	_remove_layer.disabled = overlay == null
	if overlay:
		_updating = true
		_layer_name.text = overlay.name
		_layer_picker.edited_resource = overlay.texture
		_shade_color.color = overlay.get_shade()
		_shade_row.visible = overlay.texture == null
		_layer_blend.select(overlay.blend)
		_show_edge(overlay.blend)
		_order.value = overlay.order_height
		_edge_shadow.value = overlay.edge_shadow
		_edge_sharp.value = overlay.edge_sharpness
		_edge_noise.value = overlay.edge_noise
		_edge_darken.value = overlay.edge_darken
		_border_blend.select(overlay.blend)
		_border_shadow.value = overlay.edge_shadow
		_border_darken.value = overlay.edge_darken
		_layer_opacity.value = overlay.opacity
		_layer_tile.value = overlay.tile_size
		_layer_visible.button_pressed = overlay.enabled
		_noise_cov.value = overlay.noise_coverage
		_noise_size.value = overlay.noise_size
		_noise_soft.value = overlay.noise_softness
		_noise_combine.select(overlay.noise_combine)
		_noise_base.edited_resource = overlay.noise_base
		_layer_var.value = overlay.variation
		_layer_var_size.value = overlay.variation_size
		_layer_var_mode.select(overlay.variation_mode)
		_layer_tint_check.button_pressed = overlay.override_tint
		var t := PaintAtlas.texture_tint(overlay.texture,
			PackedColorArray([overlay.tint_dark, overlay.tint_light]) if overlay.override_tint else null)
		_layer_dark.color = t[1]
		_layer_light.color = t[2]
		_updating = false
	if emit:
		layer_selected.emit(LevelPaintTool.VERTEX_LAYER if vertex else LevelPaintTool.SURFACE_LAYER if surface else index)


func _tint_row(parent: Control, label: String) -> Array:
	var row := HBoxContainer.new()
	var check := CheckBox.new()
	check.text = "Override"
	var dark := ColorPickerButton.new()
	dark.custom_minimum_size = Vector2(32, 0) * _scale
	dark.tooltip_text = "Dark colour"
	var light := ColorPickerButton.new()
	light.custom_minimum_size = Vector2(32, 0) * _scale
	light.tooltip_text = "Light colour"
	row.add_child(dark)
	row.add_child(light)
	row.add_child(check)
	_row(parent, label, row)
	return [check, dark, light]


## Shows the colouring of the texture to apply: the look of the next paint (unless
## Level-wide) over the level's own settings for the texture.
func _refresh_base_tint(look := {}) -> void:
	_updating = true
	_paint_look = look
	if _level_wide.button_pressed:
		look = {}
	if _data:
		var level_tile := PaintAtlas.base_tile_for(_base_texture, _data)
		_base_tile.value = look.tile if look.get("tile", 0.0) > 0.0 else level_tile
		var overridden := _base_texture != null and _data.base_tile_sizes.has(_base_texture)
		_base_tile.suffix = "(level)" if overridden else ""
		_base_tile_auto.disabled = not overridden and look.get("tile", 0.0) <= 0.0
		var v: Vector3 = look.get("variation", PaintAtlas.base_variation_for(_base_texture, _data))
		_base_var.value = v.x
		_base_var_size.value = v.y
		_base_var_mode.select(int(v.z))
	_refresh_overrides()
	var override = _data.base_tints.get(_base_texture) if _data and _base_texture else null
	var pal: PackedColorArray = look.get("palette", PackedColorArray())
	if pal.size() == 2:
		override = pal
	var t := PaintAtlas.texture_tint(_base_texture, override)
	_base_tint_check.button_pressed = override != null
	_base_dark.color = t[1]
	_base_light.color = t[2]
	var split := _split_brightness(look.get("color", Color.WHITE))
	_base_color.color = split[0]
	_base_bright.value = split[1]
	_base_color.disabled = _level_wide.button_pressed
	_color_mode.disabled = _level_wide.button_pressed
	_updating = false


## [colour 0 – 1, brightness]: a painted colour that may exceed 1 (2× range) as the
## picker + Brightness show it.
static func _split_brightness(c: Color) -> Array:
	var b := maxf(maxf(c.r, c.g), maxf(c.b, 1.0))
	return [Color(c.r / b, c.g / b, c.b / b), b]


func _emit_vertex_color() -> void:
	var b := _vertex_bright.value
	vertex_color_changed.emit(_vertex_color.color * Color(b, b, b))


## Not Level-wide: the controls' values become the look of what's painted next.
func _emit_look() -> void:
	if _updating or _data == null or _base_texture == null or _level_wide.button_pressed:
		return
	var level_tile := PaintAtlas.base_tile_for(_base_texture, _data)
	var look := {
		color = _base_color.color * Color(_base_bright.value, _base_bright.value, _base_bright.value),
		variation = Vector3(_base_var.value, _base_var_size.value, _base_var_mode.selected),
		# The box rounds to its step: within half a step of the level's size is "unchanged".
		tile = 0.0 if absf(_base_tile.value - level_tile) <= _base_tile.step * 0.5 + 0.0001 else _base_tile.value,
	}
	if _base_tint_check.button_pressed:
		look.palette = PackedColorArray([_base_dark.color, _base_light.color])
	_paint_look = look
	brush_changed.emit(&"look", look)


func _emit_base_tint() -> void:
	if not _level_wide.button_pressed:
		_emit_look()
		return
	if _updating or _data == null or _base_texture == null:
		return
	var tints := _data.base_tints.duplicate()
	if _base_tint_check.button_pressed:
		tints[_base_texture] = PackedColorArray([_base_dark.color, _base_light.color])
	else:
		tints.erase(_base_texture)
	level_property_changed.emit(&"base_tints", tints)


## Tile size for the texture to apply: stored per texture in this level; back to the
## texture's own size removes the override.
## Variation controls (strength / size / mode) under `parent`.
func _variation_rows(parent: Control) -> Array:
	var strength := _slider(parent, "Variation", 0.0, 1.0, 0.05)
	strength.tooltip_text = "Breaks up repetition with a shared, seamless noise (0 = off).\nSampled in each face's own projection, so walls and floors vary independently."
	var size := _spin(parent, "Variation size (m)", 0.5, 64.0, 0.5)
	size.tooltip_text = "Metres per noise repeat: bigger = broader patches."
	var mode := OptionButton.new()
	mode.add_item("Light & dark")
	mode.add_item("Darken")
	mode.tooltip_text = "Light & dark: patches both ways. Darken: only grime-like darker patches."
	_row(parent, "Variation mode", mode)
	return [strength, size, mode]


## Variation for the texture to apply: stored per texture in this level; 0 removes it.
func _emit_base_variation() -> void:
	if not _level_wide.button_pressed:
		_emit_look()
		return
	if _updating or _data == null or _base_texture == null:
		return
	var vars := _data.base_variation.duplicate()
	if _base_var.value <= 0.0:
		vars.erase(_base_texture)
	else:
		vars[_base_texture] = Vector3(_base_var.value, _base_var_size.value, _base_var_mode.selected)
	level_property_changed.emit(&"base_variation", vars)


func _emit_base_tile(v: float) -> void:
	if _updating or _data == null:
		return
	if not _level_wide.button_pressed and _base_texture:
		_emit_look()
		return
	if _base_texture == null:
		level_property_changed.emit(&"base_tile_size", v)
		return
	var sizes := _data.base_tile_sizes.duplicate()
	if _base_texture is N64Texture and is_equal_approx(v, _base_texture.metres_per_repeat()):
		sizes.erase(_base_texture)
	else:
		sizes[_base_texture] = v
	level_property_changed.emit(&"base_tile_sizes", sizes)


func _reset_base_tile() -> void:
	if _base_texture and not _level_wide.button_pressed:
		_updating = true
		_base_tile.value = PaintAtlas.base_tile_for(_base_texture, _data)
		_updating = false
		_emit_look()
	elif _base_texture:
		_clear_override(_base_texture)


func _clear_override(texture: Texture2D) -> void:
	if _data == null or not _data.base_tile_sizes.has(texture):
		return
	var sizes := _data.base_tile_sizes.duplicate()
	sizes.erase(texture)
	level_property_changed.emit(&"base_tile_sizes", sizes)


func _refresh_overrides() -> void:
	for c in _overrides_box.get_children():
		c.queue_free()
	if _data == null or _data.base_tile_sizes.is_empty():
		return
	var title := Label.new()
	title.text = "Level size overrides"
	title.add_theme_font_size_override(&"font_size", int(11 * _scale))
	title.modulate = Color(1, 1, 1, 0.7)
	title.tooltip_text = "Textures this level sizes itself; they ignore the project texel density."
	_overrides_box.add_child(title)
	for tex: Texture2D in _data.base_tile_sizes:
		var row := HBoxContainer.new()
		var l := Label.new()
		var tex_name := tex.resource_path.get_file().get_basename() if tex and tex.resource_path else "(texture)"
		var auto_size := (tex as N64Texture).metres_per_repeat() if tex is N64Texture else 0.0
		l.text = "%s: %.2f m (auto %.2f)" % [tex_name, _data.base_tile_sizes[tex], auto_size]
		l.add_theme_font_size_override(&"font_size", int(11 * _scale))
		l.size_flags_horizontal = SIZE_EXPAND_FILL
		l.clip_text = true
		l.tooltip_text = tex.resource_path if tex else ""
		row.add_child(l)
		var b := Button.new()
		b.text = "Auto"
		b.tooltip_text = "Remove the override: use the project texel density."
		b.pressed.connect(_clear_override.bind(tex))
		row.add_child(b)
		_overrides_box.add_child(row)


func _emit_layer(property: StringName, value: Variant) -> void:
	if not _updating and _layer > 0:
		layer_property_changed.emit(_layer - 1, property, value)


## Only the options the tool (on the selected layer) uses: brush size / hardness / shape for
## strokes, strength wherever coverage or colour is blended (not base / surface paint).
func _update_tool_visibility(tool: int) -> void:
	_tool = tool
	var T := LevelPaintTool.Tool
	var stroke := tool == T.BRUSH or tool == T.ERASE
	var whole := _layer == 0 or (_data != null and _layer == _surface_row())
	_size_row.visible = stroke or tool in [T.SCATTER, T.GRASS, T.TREES]
	_hardness_row.visible = stroke and not whole
	_shape_row.visible = stroke and not whole
	_strength_row.visible = not whole and not tool in [T.SCATTER, T.PLACE, T.GRASS, T.TREES]
	_stay.visible = tool in [T.BRUSH, T.ERASE, T.FACE, T.FILL_SAME]
	_normal_box.visible = tool == T.FILL_NORMAL
	_scatter_box.visible = tool == T.SCATTER or tool == T.PLACE
	_gradient_box.visible = tool == T.GRADIENT
	_border_box.visible = tool == T.BORDER
	_grass_box.visible = tool == T.GRASS
	_trees_box.visible = tool == T.TREES


var _grass_box: Control
var _grass_height: SpinBox
var _trees_box: Control
var _trees_list: ItemList
var _trees_spacing: SpinBox
var _trees_size_var: HSlider


## Grass settings: the carpet height painted.
func _build_grass() -> void:
	_grass_box = VBoxContainer.new()
	_grass_height = _spin(_grass_box, "Carpet height (m)", 0.05, 1.0, 0.05)
	_grass_height.tooltip_text = "Height of the carpet painted (about a quarter to a third of the player's height reads\nlike Majora's Mask: 0.45 m). The rest (lumps, rounding, tufts) is in the level's Grass settings."
	_grass_height.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"grass_height", v))


## Trees settings: which species (several = a mix), spacing, size variation.
func _build_trees() -> void:
	_trees_box = VBoxContainer.new()
	_trees_list = ItemList.new()
	_trees_list.select_mode = ItemList.SELECT_MULTI
	_trees_list.auto_height = true
	_trees_list.custom_minimum_size.y = 120 * _scale
	_trees_list.tooltip_text = "Species to plant: select one, or several for a mix (a random one per tree)."
	var dir := "res://addons/n64_level_tools/trees/species/"
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".tres"):
			var i := _trees_list.add_item(f.get_basename().capitalize())
			_trees_list.set_item_metadata(i, dir + f)
	_trees_list.multi_selected.connect(func(_i, _on): _emit_tree_species())
	_trees_list.item_selected.connect(func(_i): _emit_tree_species())
	_trees_box.add_child(_trees_list)
	_trees_spacing = _spin(_trees_box, "Spacing (m)", 1.0, 40.0, 0.5)
	_trees_spacing.tooltip_text = "Closest two trees stand (also to trees already there)."
	_trees_spacing.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"trees_spacing", v))
	_trees_size_var = _slider(_trees_box, "Size variation", 0.0, 0.6, 0.05)
	_trees_size_var.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"trees_size_var", v))


func _emit_tree_species() -> void:
	if _updating:
		return
	var list: Array[Resource] = []
	for i in _trees_list.get_selected_items():
		list.append(load(_trees_list.get_item_metadata(i)))
	brush_changed.emit(&"trees_species", list)


func set_grass_state(g: LevelGrassTool, t: LevelTreeTool) -> void:
	_updating = true
	_grass_height.value = g.height
	_trees_spacing.value = t.spacing
	_trees_size_var.value = t.size_var
	_trees_list.deselect_all()
	for i in _trees_list.item_count:
		for sp in t.species:
			if sp and sp.resource_path == _trees_list.get_item_metadata(i):
				_trees_list.select(i, false)
	_updating = false


## Scatter / Place settings: the items (cut-outs) and how they're placed.
func _build_scatter() -> void:
	_scatter_box = VBoxContainer.new()
	_scatter_list = ItemList.new()
	_scatter_list.auto_height = true
	_scatter_list.custom_minimum_size.y = 40 * _scale
	_scatter_list.max_columns = 0
	_scatter_list.icon_mode = ItemList.ICON_MODE_TOP
	_scatter_list.fixed_icon_size = Vector2i(32, 32) * int(maxf(_scale, 1.0))
	_scatter_list.tooltip_text = "Cut-outs to scatter (a random one per point)."
	_scatter_box.add_child(_scatter_list)
	var row := HBoxContainer.new()
	_scatter_box.add_child(row)
	var picker := _picker(row, "Add")
	picker.resource_changed.connect(func(r):
		if r is Texture2D and not _scatter_items.has(r):
			_scatter_items.append(r)
			_emit_scatter_items()
		picker.edited_resource = null)
	var remove := Button.new()
	remove.text = "Remove"
	remove.pressed.connect(func():
		for i in _scatter_list.get_selected_items():
			_scatter_items.erase(_scatter_list.get_item_metadata(i))
		_emit_scatter_items())
	row.add_child(remove)
	_scatter_style = OptionButton.new()
	for n in ["Upright (faces camera)", "Cross (two quads)", "Flat (on the ground)"]:
		_scatter_style.add_item(n)
	_scatter_style.tooltip_text = "Upright: flowers on stems. Cross: grass tufts, bushes. Flat: flower heads seen from above, petals."
	_scatter_style.item_selected.connect(func(i): if not _updating: brush_changed.emit(&"scatter_style", i))
	_row(_scatter_box, "Style", _scatter_style)
	_scatter_size = _spin(_scatter_box, "Item size (m)", 0.05, 8.0, 0.05)
	_scatter_size.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"scatter_item_size", v))
	_scatter_jitter = _slider(_scatter_box, "Size variation", 0.0, 0.9, 0.05)
	_scatter_jitter.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"scatter_size_jitter", v))
	_scatter_density = _spin(_scatter_box, "Density (per m²)", 0.1, 60.0, 0.1)
	_scatter_density.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"scatter_density", v))
	_scatter_edge = OptionButton.new()
	for n in ["As is", "Darken (outline)", "Trim (ground shows)"]:
		_scatter_edge.add_item(n)
	_scatter_edge.tooltip_text = "The cut-out's outermost texels: Darken gives a contact-shadow outline (like the Height blend),\nTrim removes them so the ground shows (hides a pale fringe). Also changes the listed items already placed."
	_scatter_edge.item_selected.connect(func(i):
		if not _updating:
			_scatter_edge_dark.get_parent().get_parent().visible = i == ScatterSet.Edge.DARKEN
			brush_changed.emit(&"scatter_edge", i))
	_row(_scatter_box, "Edge", _scatter_edge)
	_scatter_edge_dark = _slider(_scatter_box, "Edge darkness", 0.0, 1.0, 0.05)
	_scatter_edge_dark.tooltip_text = "How dark the edge outline is (1 = not darkened)."
	_scatter_edge_dark.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"scatter_edge_dark", v))
	var cover_row := HBoxContainer.new()
	var cover := Button.new()
	cover.text = "Make cover texture"
	cover.size_flags_horizontal = SIZE_EXPAND_FILL
	cover.tooltip_text = "Sprinkles the items into a small tileable texture and adds it as an overlay layer:\npaint flat flower cover with the brush, no geometry. 32 px stays within N64 texture memory."
	var cover_size := OptionButton.new()
	cover_size.add_item("32 px")
	cover_size.add_item("64 px")
	cover.pressed.connect(func(): scatter_cover_requested.emit(32 if cover_size.selected == 0 else 64))
	cover_row.add_child(cover)
	cover_row.add_child(cover_size)
	_scatter_box.add_child(cover_row)


## Border settings: the band's width (the layer picked above is what it paints).
func _build_border() -> void:
	_border_box = VBoxContainer.new()
	_border_width = _slider(_border_box, "Width (m)", 0.05, 8.0, 0.05)
	_border_width.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"border_width", v))
	_border_follow = CheckBox.new()
	_border_follow.text = "Texture follows the edge"
	_border_follow.tooltip_text = "Turns the overlay on each border face so the texture's width (a brick's long side)\nruns along the edge. Off: faces keep their overlay turn."
	_border_follow.toggled.connect(func(on): if not _updating: brush_changed.emit(&"border_follow", on))
	_border_box.add_child(_border_follow)
	_border_corner = OptionButton.new()
	for n in LevelPaintTool.CORNER_NAMES:
		_border_corner.add_item(n)
	_border_corner.tooltip_text = "Where the band turns a corner (Texture follows the edge), the faces there are cut so each\nside's texture runs its own way (adds a few faces; base textures don't change).\nButt: the band along the texture's width runs straight through, the other stops against\nits inner edge. Mitre: the two meet on the 45° line."
	_border_corner.item_selected.connect(func(i): if not _updating: brush_changed.emit(&"border_corner", i))
	_row(_border_box, "Corners", _border_corner)
	_border_direction = OptionButton.new()
	for n in LevelPaintTool.LAY_NAMES:
		_border_direction.add_item(n)
	_border_direction.tooltip_text = "Which way the texture lies on the band (Texture follows the edge).\nAlong: its width runs along the edge (a brick course). Across: turned 90°, its width\nruns inward (soldier bricks, planks). Flipped: the same, upside down (e.g. a grass-edge\ntexture's fringe pointing the other way). Rows stay lined up with the edge.\nContinue the neighbour: the texture carries on seamlessly from the face across the edge,\nas if that surface were folded over it (stair steps onto the ramp's side, hilltop grass\ndown the slope). Give the layer the neighbour's texture (a stair texture continues the\nsteps); Alt+click to keep only the edge to continue from."
	_border_direction.item_selected.connect(func(i): if not _updating: brush_changed.emit(&"border_direction", i))
	_row(_border_box, "Texture", _border_direction)
	_border_soft = _slider(_border_box, "Soft edge (m)", 0.0, 2.0, 0.05)
	_border_soft.tooltip_text = "Fades the band's inner edge over this distance (0 = hard). With the layer's\nHeight blend the fade breaks up along the texture: grass creeping up a wall's base."
	_border_soft.value_changed.connect(func(v): if not _updating: brush_changed.emit(&"border_soft", v))
	var sides := Button.new()
	sides.text = "All sides"
	sides.tooltip_text = "Sides: the band runs along every side of the area by default.\nAlt+click an edge of the area in the viewport to leave that side out (dim red), again to add it back.\nThis puts every side back."
	sides.pressed.connect(func(): brush_changed.emit(&"border_off", {}))
	_row(_border_box, "Sides", sides)
	# The layer's look, here for convenience (same settings as Layer setup).
	_border_blend = OptionButton.new()
	for n in PaintLayer.BLEND_NAMES:
		_border_blend.add_item(n)
	_border_blend.tooltip_text = "The selected layer's blend (also in Layer setup). Height: the edge follows the\ntexture's detail; with Soft edge, a ragged, natural edge."
	_border_blend.item_selected.connect(func(i):
		_emit_layer(&"blend", i)
		_layer_blend.select(i)
		_show_edge(i))
	_row(_border_box, "Blend", _border_blend)
	_border_shadow = _slider(_border_box, "Shadow", 0.0, 1.0, 0.05)
	_border_shadow.tooltip_text = "Darkens what's just outside the band's edge, so it looks raised (the layer's Shadow)."
	_border_shadow.value_changed.connect(func(v):
		_emit_layer(&"edge_shadow", v)
		if not _updating:
			_edge_shadow.set_value_no_signal(v))
	_border_darken = _slider(_border_box, "Edge darken", 0.0, 1.0, 0.05)
	_border_darken.tooltip_text = "Darkens a band along the edge (the layer's Edge darken; Height blends)."
	_border_darken.value_changed.connect(func(v):
		_emit_layer(&"edge_darken", v)
		if not _updating:
			_edge_darken.set_value_no_signal(v))


## Gradient settings: the ramp (stops), its direction and what it blends into.
func _build_gradient() -> void:
	_gradient_box = VBoxContainer.new()
	_gradient_dir = OptionButton.new()
	for n in LevelGradientTool.DIR_NAMES:
		_gradient_dir.add_item(n)
	_gradient_dir.tooltip_text = "Click direction (the gradient runs 0 % to 100 % this way). Left / Right / Away / Toward and the\ncorners are as seen from the editor camera, along the faces. Corners: from the opposite corner\nto the named one (on a floor, up = away from the camera)."
	_gradient_dir.item_selected.connect(func(i): if not _updating: brush_changed.emit(&"gradient_direction", i))
	_row(_gradient_box, "Direction", _gradient_dir)
	var presets := OptionButton.new()
	presets.add_item("Presets…")
	for n in LevelGradientTool.PRESETS:
		presets.add_item(n)
	presets.item_selected.connect(func(i):
		if i > 0:
			_gradient_stops.tool.apply_preset(presets.get_item_text(i))
			_gradient_stops.selected = 0
			_sync_gradient()
			brush_changed.emit(&"gradient_stops", _gradient_stops.tool.stops)
		presets.select(0))
	var reverse := Button.new()
	reverse.text = "Reverse"
	reverse.tooltip_text = "Flip the ramp end to end."
	reverse.pressed.connect(func():
		_gradient_stops.tool.reverse()
		_sync_gradient()
		brush_changed.emit(&"gradient_stops", _gradient_stops.tool.stops))
	var row := HBoxContainer.new()
	presets.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(presets)
	row.add_child(reverse)
	_row(_gradient_box, "Ramp", row)
	_gradient_stops = GradientStopsEdit.new(_scale)
	_gradient_stops.stops_changed.connect(func(st): brush_changed.emit(&"gradient_stops", st))
	_gradient_stops.stop_selected.connect(func(i):
		_updating = true
		_gradient_cover.value = _gradient_stops.tool.stops[i].y
		_updating = false)
	_gradient_box.add_child(_gradient_stops)
	_gradient_cover = _slider(_gradient_box, "Stop coverage", 0.0, 1.0, 0.05)
	_gradient_cover.tooltip_text = "Coverage of the selected stop (1 = the layer fully shows)."
	_gradient_cover.value_changed.connect(func(v): if not _updating: _gradient_stops.set_coverage(v))
	var remove_stop := Button.new()
	remove_stop.text = "Remove stop"
	remove_stop.tooltip_text = "Removes the selected stop (also: right-click it, or Delete)."
	remove_stop.pressed.connect(func(): _gradient_stops.remove_selected())
	_gradient_cover.get_parent().add_child(remove_stop)
	_gradient_style = OptionButton.new()
	for n in LevelGradientTool.STYLE_NAMES:
		_gradient_style.add_item(n)
	_gradient_style.tooltip_text = "Fade: straight blend between stops. Smooth: eased blend. Sharp: each stop's coverage holds to the next stop (hard edges)."
	_gradient_style.item_selected.connect(func(i):
		if not _updating:
			brush_changed.emit(&"gradient_style", i)
			_gradient_stops.queue_redraw())
	_row(_gradient_box, "Style", _gradient_style)
	_gradient_second = OptionButton.new()
	_gradient_second.tooltip_text = "Texture -> texture: the active layer blends into this overlay layer (the upper one fades\nover the lower one, which fills in underneath). None: the active layer fades out to what's below."
	_gradient_second.item_selected.connect(func(i):
		if not _updating:
			brush_changed.emit(&"gradient_second_layer", _gradient_second.get_item_id(i))
			_refresh_gradient_layers())
	_row(_gradient_box, "Blend into", _gradient_second)
	_gradient_blend = OptionButton.new()
	for n in PaintLayer.BLEND_NAMES:
		_gradient_blend.add_item(n)
	_gradient_blend.tooltip_text = "How the fading layer shows through the gradient: its blend mode (the upper layer of a\nBlend into pair). Height: texels break up along the ramp. Per layer: changes it everywhere the layer is painted."
	_gradient_blend.item_selected.connect(func(i):
		var upper := _gradient_upper()
		if not _updating and upper >= 0:
			layer_property_changed.emit(upper, &"blend", i))
	_row(_gradient_box, "Transition", _gradient_blend)
	_gradient_combine = OptionButton.new()
	_gradient_combine.add_item("Replace")
	_gradient_combine.add_item("Keep stronger paint")
	_gradient_combine.tooltip_text = "Replace: the faces get the gradient (Strength blends it in). Keep stronger: paint already stronger stays."
	_gradient_combine.item_selected.connect(func(i): if not _updating: brush_changed.emit(&"gradient_keep_stronger", i == 1))
	_row(_gradient_box, "Existing paint", _gradient_combine)


## The stops editor and its controls from the gradient tool (after presets / reverse).
func _sync_gradient() -> void:
	var g := _gradient_stops.tool
	_updating = true
	_gradient_style.select(g.style)
	_gradient_dir.select(g.direction)
	_gradient_combine.select(1 if g.keep_stronger else 0)
	_gradient_stops.selected = clampi(_gradient_stops.selected, 0, g.stops.size() - 1)
	_gradient_cover.value = g.stops[_gradient_stops.selected].y if not g.stops.is_empty() else 0.0
	_updating = false
	_refresh_gradient_layers()
	_gradient_stops.queue_redraw()


func _refresh_gradient_layers() -> void:
	if _gradient_second == null:
		return
	var g := _gradient_stops.tool
	_gradient_second.clear()
	_gradient_second.add_item("None (fade to below)", -1)
	if _data:
		for i in _data.active_layers().size():
			_gradient_second.add_item("%d · %s" % [i + 1, _data.active_layers()[i].name], i)
	var want := g.second_layer if g else -1
	var idx := _gradient_second.get_item_index(want)
	_gradient_second.select(idx if idx >= 0 else 0)
	var upper := _gradient_upper()
	_gradient_blend.disabled = upper < 0
	if upper >= 0:
		_gradient_blend.select(_data.active_layers()[upper].blend)
		_gradient_blend.get_parent().get_child(0).text = "Transition (%d)" % (upper + 1)


## The overlay layer whose blend mode shapes the gradient: the active one, or the upper of
## the pair when it blends into another layer (-1: no overlay layer selected).
func _gradient_upper() -> int:
	if _data == null or _layer <= 0 or _layer - 1 >= _data.active_layers().size():
		return -1
	var g := _gradient_stops.tool if _gradient_stops else null
	var second := g.second_layer if g and g.second_layer < _data.active_layers().size() else -1
	return maxi(_layer - 1, second)


## The gradient tool's settings into the controls.
func set_gradient_state(g: LevelGradientTool) -> void:
	_gradient_stops.tool = g
	_sync_gradient()


func _emit_scatter_items() -> void:
	_refresh_scatter_list()
	brush_changed.emit(&"scatter_items", _scatter_items.duplicate())


func _refresh_scatter_list() -> void:
	_scatter_list.clear()
	for t in _scatter_items:
		var i := _scatter_list.add_item(t.resource_path.get_file().get_basename().trim_prefix("flower_") if t.resource_path else "item", t)
		_scatter_list.set_item_metadata(i, t)


## The scatter tool's settings into the controls.
func set_scatter_state(sc: LevelScatterTool) -> void:
	_updating = true
	_scatter_items.assign(sc.items)
	_refresh_scatter_list()
	_scatter_style.select(sc.style)
	_scatter_size.value = sc.item_size
	_scatter_jitter.value = sc.size_jitter
	_scatter_density.value = sc.density
	_scatter_edge.select(sc.edge)
	_scatter_edge_dark.value = sc.edge_dark
	_scatter_edge_dark.get_parent().get_parent().visible = sc.edge == ScatterSet.Edge.DARKEN
	_updating = false


# --- Widgets ------------------------------------------------------------------------

## Marks the start of a collapsible section; _build_sections() wraps what follows it.
## Edge settings for the Height blends; Order height for Height by order only.
func _show_edge(blend: int) -> void:
	_edge_box.visible = blend == PaintLayer.Blend.HEIGHT or blend == PaintLayer.Blend.HEIGHT_ORDER
	_order_row.visible = blend == PaintLayer.Blend.HEIGHT_ORDER


func _heading(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.set_meta(&"section", text)
	_body.add_child(l)


## Turns each heading and the controls after it into a section with a collapse arrow
## (like the main toolbar). Collapsed state persists per project.
func _build_sections() -> void:
	var children := _body.get_children()
	for c in children:
		_body.remove_child(c)
	var content: VBoxContainer = null
	for c in children:
		if not c.has_meta(&"section"):
			(content if content else _body).add_child(c)
			continue
		var title: String = c.get_meta(&"section")
		c.free()
		var button := Button.new()
		button.flat = true
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.add_theme_color_override(&"font_color", SECTION_COLOR)
		button.add_theme_color_override(&"font_hover_color", SECTION_COLOR.lightened(0.3))
		button.tooltip_text = "Collapse / expand"
		_body.add_child(button)
		content = VBoxContainer.new()
		_body.add_child(content)
		_sections[title] = {button = button, content = content}
		button.pressed.connect(func():
			var key := "paint_collapsed_" + title.to_snake_case()
			var es := EditorInterface.get_editor_settings()
			es.set_project_metadata("n64_level_tools", key, not es.get_project_metadata("n64_level_tools", key, title in COLLAPSED_BY_DEFAULT))
			_apply_sections())
	_apply_sections()


func _apply_sections() -> void:
	var es := EditorInterface.get_editor_settings()
	for title in _sections:
		var s: Dictionary = _sections[title]
		var collapsed: bool = es.get_project_metadata("n64_level_tools", "paint_collapsed_" + String(title).to_snake_case(),
			title in COLLAPSED_BY_DEFAULT)
		s.content.visible = not collapsed
		s.button.icon = EditorInterface.get_editor_theme().get_icon(
			&"GuiTreeArrowRight" if collapsed else &"GuiTreeArrowDown", &"EditorIcons")
		var text := String(title)
		# Collapsed Paint on still says what you're painting; Layer setup always says whose.
		if (collapsed and title == "Paint on" or title == "Layer setup") and _layers and _layers.item_count > 0:
			text += " · " + _current_layer_label()
		s.button.text = text
		if title == "Layer setup":
			# Surface has nothing to set up.
			var surface := _data != null and _layer == _surface_row()
			s.button.visible = not surface
			s.content.visible = s.content.visible and not surface


func _current_layer_label() -> String:
	if _data and _layer > 0 and _layer - 1 < _data.active_layers().size():
		return _data.active_layers()[_layer - 1].name
	if _data and _layer == _vertex_row():
		return "Vertex colour"
	if _data and _layer == _surface_row():
		return "Surface"
	return "Base"


func _row(parent: Control, label: String, control: Control) -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 80 * _scale
	l.add_theme_font_size_override(&"font_size", int(12 * _scale))
	row.add_child(l)
	control.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(control)
	parent.add_child(row)


func _slider(parent: Control, label: String, lo: float, hi: float, step: float) -> HSlider:
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
	_row(parent, label, box)
	return s


func _spin(parent: Control, label: String, lo: float, hi: float, step: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	_row(parent, label, s)
	return s


func _picker(parent: Control, label: String) -> N64TexturePicker:
	var p := N64TexturePicker.new()
	_row(parent, label, p)
	return p


func _svg(icon_name: String) -> Texture2D:
	var image := Image.new()
	if image.load_svg_from_string(FileAccess.get_file_as_string(ICON_DIR + icon_name + ".svg"), _scale * 1.25) != OK:
		return null
	return ImageTexture.create_from_image(image)
