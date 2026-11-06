@tool
extends EditorPlugin
## Viewport tools for LevelRoot/LevelData geometry: shape placement, brush selection and
## transforms, resize handles, vertex/edge/face editing with grid snapping, extrusion,
## debug texture toggle and non-destructive baking.

const LevelPanel := preload("res://addons/n64_level_tools/ui/level_panel.gd")
const TextureImporterPanel := preload("res://addons/n64_level_tools/ui/texture_importer_panel.gd")
const LevelBlender := preload("res://addons/n64_level_tools/level_blender.gd")

enum Mode { OBJECT, VERTEX, EDGE, FACE, PAINT, SCULPT }
enum Drag { NONE, AXIS_X, AXIS_Y, AXIS_Z, PLANE_XZ, BOX, RESIZE }

const SETTINGS_SECTION := "n64_level_tools"
const GRID_PARAM := &"level_grid_size"
const FILTER_PARAM := &"n64_three_point"
const ExportBakeSetting := "n64/export/bake_on_export"
const TINT_PARAM := &"n64_world_tint"
const BLEND_PARAM := &"n64_light_blend"
const WEATHER_PARAM := &"n64_weather_tint"
const AO_PARAM := &"n64_vertex_ao"
## Animated textures' rate (1 = play, 0 = frozen while painting); the game always plays.
const TIME_PARAM := &"n64_time"
## Shortcut modifier as Godot reads it (is_command_or_control_pressed): Cmd on macOS.
static var MOD := "Cmd" if OS.get_name() == "macOS" else "Ctrl"
const PICK_RADIUS := 10.0
const HANDLE_RADIUS := 8.0
const GIZMO_PIXELS := 80.0
const AXES := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
const AXIS_COLORS := [Color(0.96, 0.33, 0.33), Color(0.55, 0.9, 0.3), Color(0.3, 0.55, 1.0)]
const SEL_COLOR := Color(1.0, 0.62, 0.12)
const REMOVE_COLOR := Color(1.0, 0.3, 0.3)
const GHOST_COLOR := Color(0.3, 0.9, 1.0)
## Tool index after the brush shapes.
const PASSAGE_TOOL := 8
const DOOR_TOOL := 9
const STATUS_OK := Color(0.45, 0.85, 0.45)
const STATUS_STALE := Color(1.0, 0.75, 0.3)
const STATUS_IDLE := Color(0.75, 0.75, 0.75, 0.8)

var panel: LevelPanel
## Set pieces: brushes made in Blender.
var blender: LevelBlender
var _set_piece_dialog: ConfirmationDialog
var _set_piece_name: LineEdit
var _trash_dialog: ConfirmationDialog
var texture_panel: TextureImporterPanel
## Strips tooling and authoring data from exports (see export/n64_export_plugin.gd).
var _export_plugin: EditorExportPlugin
## N64 texture picker for texture slots on dressing / stair resources.
var _texture_inspector: EditorInspectorPlugin
## Project > Tools > M3D World (new zone scenes).
const WORLD_MENU := "M3D World"
const ZoneTemplates := preload("res://addons/n64_level_tools/zone_templates.gd")
var _zone_dialog: EditorFileDialog
var _zone_outdoor := true
var _grid_dialog: ConfirmationDialog
var _ao_timer: Timer
var _grid_axis: OptionButton
var _grid_side: OptionButton
var _grid_amount: SpinBox
var _grid_info: Label
## Editor-only player-sized scale reference (never saved; see reference_character.gd).
const ReferenceCharacter := preload("res://addons/n64_level_tools/reference_character.gd")
const PlayHere := preload("res://addons/n64_level_tools/play_here.gd")
const PassageBuilder := preload("res://addons/n64_level_tools/passage_builder.gd")
const FenceBuilder := preload("res://addons/n64_level_tools/fence_builder.gd")
const FenceEditor := preload("res://addons/n64_level_tools/fence_editor.gd")
const RopeTexture := preload("res://addons/n64_level_tools/textures/rope_texture_generator.gd")
const ZoneLinks := preload("res://addons/n64_level_tools/zone_links.gd")
## Dragging / adding / removing the selected Fence's points in the 3D view.
var fence_edit
const FENCE_STYLE_PATH := "res://game/world/fence_default_style.tres"
const ROPE_STYLE_PATH := "res://addons/n64_level_tools/rope/rope_default_style.tres"
const ROPE_TEXTURE_PATH := "res://textures/rope/rope_default.res"
## A fence's brushes by role (FenceBuilder.build order), kept in their resource_name.
const FENCE_PARTS := ["fence_panels", "fence_posts", "fence_caps", "fence_arches", "fence_collision"]
var _reference: Node3D
## Paint fill preview: the faces a click would paint, drawn in the scene so walls in front
## hide it (overlay lines would draw over everything). Editor only, never saved.
## In-scene face previews by slot (&"fill": what a click would paint, &"mask": the paint
## face mask): slot -> [MeshInstance3D, content hash].
## The level panel's Anim toggle. n64_time only advances while it's on and an animated
## texture is in use: each change redraws the viewport, so ticking it for nothing would
## keep the editor rendering nonstop (why the shaders don't read TIME).
var _anim_on := true
var _anim_time := 0.0
var _previews := {}
const MASK_COLOR := Color(0.35, 0.8, 1.0)
## While masking: faces of the edited overlay set (or, editing Default, of other sets).
const SET_COLOR := Color(1.0, 0.6, 0.2)
const OTHER_SET_COLOR := Color(0.6, 0.6, 0.6)
## Cmd/Ctrl+drag in Paint mode edits the face mask: 1 adds faces, -1 removes, 0 idle.
var _mask_drag := 0
## Cmd/Ctrl press in Paint mode: where it started and what was under it (a click toggles
## that face on release); dragging past a few pixels turns it into a box select.
var _mask_from := Vector2.ZERO
var _mask_click := {}
var _mask_box := false
## Fill Same Texture's hover preview: the region for the hovered face, recomputed only when
## the face (or "stay on brush") changes. {key, region}
var _region_cache := {}
## Paint mode: the next click picks a face's texture ("Pick from face").
var _picking := false
## What the last pick took, shown by the cursor for a moment: [text, msec].
var _pick_note := ["", 0]
var _reference_on := false
var _panel_in_viewport := false
var _file_dialog: EditorFileDialog
var _save_target: LevelRoot

var mode := Mode.OBJECT
var snap := 0.1
var place_shape := -1
## Quarter turns (about Y) for the next placed brush; R / Shift+R while placing. Kept
## between placements so a row of ramps can share a facing.
var place_turns := 0

var level: LevelRoot
var sel_brushes: Array[LevelBrush] = []
var sel_verts: Array[int] = []
var sel_edges: Array[Vector2i] = []
var sel_faces: Array[int] = []

var hover_root: LevelRoot
var hover_brush: LevelBrush
## Object mode: the surface under the cursor ({position, normal}) for the reference grid.
var hover_hit := {}
var hover_vert := -1
var hover_edge := Vector2i(-1, -1)
var hover_face := -1
var hover_handle := Drag.NONE
var hover_resize := -1

var drag := Drag.NONE
var drag_origin := Vector3.ZERO
var drag_axis := Vector3.ZERO
var drag_start_t := 0.0
var drag_start_point := Vector3.ZERO
var drag_delta := Vector3.ZERO
var drag_start_verts := PackedVector3Array()
var drag_geom_before := {}
var drag_extruded := false
var drag_xforms: Array[Transform3D] = []
var drag_resize := {}
var box_from := Vector2.ZERO

var paint := LevelPaintTool.new()
var paint_hit := {}
var sculpt := LevelSculptTool.new()
## Terrain under the cursor in Sculpt mode (a _pick() hit).
var sculpt_hit := {}
var _paint_saved_tool := -1
## Gradient tool in progress: {root, start, normal, screen, dragged, targets}.
var _grad := {}
## Gradient hover: the faces a click would cover and their preset ends (cached per region).
var _grad_hover := {}
## The last gradient's click: {basis (camera), normal, dragged}, to re-aim it when the options change.
var _grad_last := {}
var _brush_dialog: EditorFileDialog
var _move_dialog: ConfirmationDialog
var _move_fields: Array[SpinBox] = []

var ghost_valid := false
var ghost_base := Vector3.ZERO
var ghost_basis := Basis()
var ghost_root: LevelRoot
var ghost_other_root: LevelRoot
## Door tool: the clicked wall face at floor height ({point, brush, face, floor}) and the
## recess settings (Door options flyout; persisted per project).
var ghost_door := {}
var door_inset_front := 0.5
var door_inset_back := 0.5
var door_build_room := true
## 0 recess (carve), 1 between faces (the wall has its opening; set pieces always).
var door_mode := 0
## Between faces: how far into the wall the door stands (% from the clicked face).
var door_depth := 50.0
var _last_density := N64Texture.texels_per_metre()
var ghost_material: Material
var ghost_wall_depth := 0.25
var ghost_wall_center := 0.0
## Passage ghost on a wall: {root, normal (into the room), point, brush, face}; the floor
## face under it: {brush, face}. Used to carve the opening and texture the corridor.
var ghost_wall := {}
## Passage tool with Cmd/Ctrl held: the passage under the cursor ({passage, root, brushes}).
var _remove_hover := {}
var ghost_floor := {}
var mouse_pos := Vector2.ZERO
var input_camera: Camera3D


func _process(delta: float) -> void:
	if _anim_on and PaintAtlas.any_animated():
		_anim_time = fmod(_anim_time + delta, 3600.0)
		RenderingServer.global_shader_parameter_set(TIME_PARAM, _anim_time)


func _enter_tree() -> void:
	fence_edit = FenceEditor.new(self)
	_export_plugin = preload("res://addons/n64_level_tools/export/n64_export_plugin.gd").new()
	_texture_inspector = preload("res://addons/n64_level_tools/ui/n64_texture_inspector.gd").new()
	add_inspector_plugin(_texture_inspector)
	Engine.set_meta(&"n64_fence_rebuild", _rebuild_fence)
	EditorInterface.get_resource_filesystem().resources_reimported.connect(_on_resources_reimported)
	Engine.set_meta(&"n64_passage_changed", _on_passage_changed)
	Engine.set_meta(&"n64_door_changed", _on_door_changed)
	add_export_plugin(_export_plugin)
	var world_menu := PopupMenu.new()
	world_menu.add_item("New Outdoor Zone…", 0)
	world_menu.add_item("New Indoor Zone…", 1)
	world_menu.add_separator()
	world_menu.add_item("New Stair Texture (from selected texture)", 2)
	world_menu.add_separator()
	world_menu.add_item("Check Zone Links…", 3)
	world_menu.id_pressed.connect(_on_world_menu)
	add_tool_submenu_item(WORLD_MENU, world_menu)
	# Other plugins (actor tools: new characters) add their items to this menu (ids 100+).
	Engine.set_meta(&"n64_world_menu", world_menu)
	EditorInterface.get_inspector().property_edited.connect(_on_inspector_property_edited)
	snap = float(EditorInterface.get_editor_settings().get_project_metadata(SETTINGS_SECTION, "snap", 0.1))
	var es := EditorInterface.get_editor_settings()
	door_inset_front = float(es.get_project_metadata(SETTINGS_SECTION, "door_inset_front", 0.5))
	door_inset_back = float(es.get_project_metadata(SETTINGS_SECTION, "door_inset_back", 0.5))
	door_build_room = bool(es.get_project_metadata(SETTINGS_SECTION, "door_build_room", true))
	door_mode = int(es.get_project_metadata(SETTINGS_SECTION, "door_mode", 0))
	door_depth = float(es.get_project_metadata(SETTINGS_SECTION, "door_depth", 50.0))
	if not RenderingServer.global_shader_parameter_get_list().has(GRID_PARAM):
		RenderingServer.global_shader_parameter_add(GRID_PARAM, RenderingServer.GLOBAL_VAR_TYPE_FLOAT, snap)
	RenderingServer.global_shader_parameter_set(GRID_PARAM, snap)
	if not RenderingServer.global_shader_parameter_get_list().has(FILTER_PARAM):
		RenderingServer.global_shader_parameter_add(FILTER_PARAM, RenderingServer.GLOBAL_VAR_TYPE_BOOL, true)
	if not RenderingServer.global_shader_parameter_get_list().has(TINT_PARAM):
		RenderingServer.global_shader_parameter_add(TINT_PARAM, RenderingServer.GLOBAL_VAR_TYPE_COLOR, Color.WHITE)
	if not RenderingServer.global_shader_parameter_get_list().has(BLEND_PARAM):
		RenderingServer.global_shader_parameter_add(BLEND_PARAM, RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4.ZERO)
	if not RenderingServer.global_shader_parameter_get_list().has(WEATHER_PARAM):
		RenderingServer.global_shader_parameter_add(WEATHER_PARAM, RenderingServer.GLOBAL_VAR_TYPE_COLOR, Color.WHITE)
	if not RenderingServer.global_shader_parameter_get_list().has(AO_PARAM):
		RenderingServer.global_shader_parameter_add(AO_PARAM, RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 1.0)
	if not RenderingServer.global_shader_parameter_get_list().has(TIME_PARAM):
		RenderingServer.global_shader_parameter_add(TIME_PARAM, RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	if not ProjectSettings.has_setting(LightingSchedule.SETTING):
		ProjectSettings.set_setting(LightingSchedule.SETTING, LightingSchedule.DEFAULT_PATH)
	ProjectSettings.set_initial_value(LightingSchedule.SETTING, LightingSchedule.DEFAULT_PATH)
	ProjectSettings.add_property_info({name = LightingSchedule.SETTING, type = TYPE_STRING,
		hint = PROPERTY_HINT_FILE, hint_string = "*.tres,*.res"})
	if not ProjectSettings.has_setting(N64Texture.DENSITY_SETTING):
		ProjectSettings.set_setting(N64Texture.DENSITY_SETTING, N64Texture.DEFAULT_DENSITY)
	ProjectSettings.set_initial_value(N64Texture.DENSITY_SETTING, N64Texture.DEFAULT_DENSITY)
	ProjectSettings.add_property_info({name = N64Texture.DENSITY_SETTING, type = TYPE_INT,
		hint = PROPERTY_HINT_RANGE, hint_string = "4,256,1"})
	if not ProjectSettings.has_setting(ExportBakeSetting):
		ProjectSettings.set_setting(ExportBakeSetting, true)
	ProjectSettings.set_initial_value(ExportBakeSetting, true)
	ProjectSettings.add_property_info({name = ExportBakeSetting, type = TYPE_BOOL})
	# Weather table lives in game/ (WeatherTable); only the setting is registered here.
	const WEATHER_SETTING := "n64/weather/table"
	if not ProjectSettings.has_setting(WEATHER_SETTING):
		ProjectSettings.set_setting(WEATHER_SETTING, "res://game/weather.tres")
	ProjectSettings.set_initial_value(WEATHER_SETTING, "res://game/weather.tres")
	ProjectSettings.add_property_info({name = WEATHER_SETTING, type = TYPE_STRING,
		hint = PROPERTY_HINT_FILE, hint_string = "*.tres,*.res"})
	_apply_editor_globals()
	# Any project-settings change makes Godot reload every shader global from
	# project.godot (level_grid_size = 0.1 there), so re-apply the editor's own values.
	ProjectSettings.settings_changed.connect(_on_project_settings_changed)

	set_input_event_forwarding_always_enabled()
	set_force_draw_over_forwarding_enabled()

	panel = LevelPanel.new()
	_attach_panel()
	panel.setup(snap, LevelRoot.debug_view, Vector2(12, 44) * EditorInterface.get_editor_scale())
	panel.shape_selected.connect(_set_place_shape)
	# A mode button always ends placement (even Object mode, which placing itself uses).
	panel.mode_selected.connect(func(m):
		if place_shape >= 0:
			_set_place_shape(-1)
		_set_mode(m))
	panel.snap_changed.connect(_on_snap_changed)
	panel.action_requested.connect(_on_action)
	panel.debug_view_toggled.connect(func(on): LevelRoot.set_debug_view(on, get_tree()))
	panel.preview_baked_toggled.connect(_preview_baked)
	panel.reference_toggled.connect(_toggle_reference)
	panel.sticky_grid_toggled.connect(_set_sticky_grid)
	# Editor-only view toggle: the project value (1) is what the game uses.
	panel.ao_view_toggled.connect(func(on): RenderingServer.global_shader_parameter_set(AO_PARAM, 1.0 if on else 0.0))
	panel.anim_view_toggled.connect(func(on): _anim_on = on)
	scene_changed.connect(func(_root): if _reference_on: _show_reference())
	panel.refresh_requested.connect(_refresh_status)
	paint.undo = get_undo_redo()
	var pp = panel.paint_panel
	pp.tool_selected.connect(func(t): paint.tool = t; update_overlays())
	pp.layer_selected.connect(func(i): paint.layer = i)
	pp.base_texture_selected.connect(func(t):
		paint.base_texture = t
		paint.look = {})
	pp.scatter_cover_requested.connect(_make_scatter_cover)
	pp.base_pick_requested.connect(func():
		_picking = true
		update_overlays())
	pp.brush_changed.connect(_on_paint_brush_changed)
	pp.overlay_turn_requested.connect(_turn_mask_overlays)
	pp.layer_clear_requested.connect(_clear_paint_layer)
	pp.faces_reset_requested.connect(_reset_mask_faces)
	pp.faces_merge_requested.connect(_merge_mask_faces)
	pp.layer_add_requested.connect(_add_paint_layer)
	pp.layer_set_selected.connect(_select_layer_set)
	pp.layer_set_add_requested.connect(_add_layer_set)
	pp.layer_set_renamed.connect(_rename_layer_set)
	pp.layer_set_assign_requested.connect(_assign_layer_set)
	pp.layer_set_duplicate_requested.connect(_duplicate_layer_set)
	pp.layer_set_delete_requested.connect(_delete_layer_set)
	pp.layer_set_move_requested.connect(_move_layer_set)
	pp.layer_remove_requested.connect(_remove_paint_layer)
	pp.layer_property_changed.connect(_set_layer_property)
	pp.level_property_changed.connect(_set_paint_level_property)
	pp.brush_add_requested.connect(_add_custom_brush)
	pp.vertex_color_changed.connect(func(c): paint.vertex_color = c)
	pp.vertex_ao_requested.connect(_bake_vertex_ao)
	pp.vertex_ao_clear_requested.connect(_clear_vertex_ao)
	pp.set_tool_state(paint)
	sculpt.undo = get_undo_redo()
	sculpt.snap_step = snap
	var sp = panel.sculpt_panel
	sp.tool_selected.connect(func(t): sculpt.tool = t; update_overlays())
	sp.setting_changed.connect(func(prop, value): sculpt.set(prop, value); update_overlays())
	sp.set_tool_state(sculpt)
	panel.door_option_changed.connect(_on_door_option)
	panel.set_door_options(door_inset_front, door_inset_back, door_build_room, door_mode, door_depth)
	texture_panel = TextureImporterPanel.new()
	add_control_to_bottom_panel(texture_panel, "N64 Textures")
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	scene_changed.connect(func(_root): panel.set_preview_baked(false))
	# Opening a scene can come with Godot reloading the shader globals: put ours back.
	scene_changed.connect(func(_root): _apply_editor_globals.call_deferred())
	# Character scenes have their own tool strip (actor tools): hide this one there.
	scene_changed.connect(func(root): panel.visible = not _is_character_scene(root))
	panel.visible = not _is_character_scene(EditorInterface.get_edited_scene_root())
	_set_mode(Mode.OBJECT)
	blender = LevelBlender.new()
	blender.plugin = self
	add_child(blender)


func _exit_tree() -> void:
	if is_instance_valid(_sticky_mi):
		_sticky_mi.queue_free()
	for w in _wires.values():
		if is_instance_valid(w.mi):
			w.mi.queue_free()
	_wires.clear()
	_hide_fill_preview()
	_hide_fill_preview(&"mask")
	_hide_fill_preview(&"surfaces")
	if blender:
		blender.queue_free()
	if _set_piece_dialog:
		_set_piece_dialog.queue_free()
	if _trash_dialog:
		_trash_dialog.queue_free()
	RenderingServer.global_shader_parameter_set(AO_PARAM, 1.0)
	if ProjectSettings.settings_changed.is_connected(_on_project_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_project_settings_changed)
	if EditorInterface.get_resource_filesystem().resources_reimported.is_connected(_on_resources_reimported):
		EditorInterface.get_resource_filesystem().resources_reimported.disconnect(_on_resources_reimported)
	remove_export_plugin(_export_plugin)
	remove_inspector_plugin(_texture_inspector)
	if Engine.has_meta(&"n64_fence_rebuild"):
		Engine.remove_meta(&"n64_fence_rebuild")
	if Engine.has_meta(&"n64_passage_changed"):
		Engine.remove_meta(&"n64_passage_changed")
	if Engine.has_meta(&"n64_door_changed"):
		Engine.remove_meta(&"n64_door_changed")
	remove_tool_menu_item(WORLD_MENU)
	if Engine.has_meta(&"n64_world_menu"):
		Engine.remove_meta(&"n64_world_menu")
	if EditorInterface.get_inspector().property_edited.is_connected(_on_inspector_property_edited):
		EditorInterface.get_inspector().property_edited.disconnect(_on_inspector_property_edited)
	_hide_reference()
	if _zone_dialog:
		_zone_dialog.queue_free()
	EditorInterface.get_selection().selection_changed.disconnect(_on_selection_changed)
	_set_level(null)
	if not _panel_in_viewport:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, panel)
	panel.queue_free()
	remove_control_from_bottom_panel(texture_panel)
	texture_panel.queue_free()
	if _file_dialog:
		_file_dialog.queue_free()


func _handles(object: Object) -> bool:
	return object is LevelRoot


## Writes LevelData stored in its own file whenever the scene is saved.
func _save_external_data() -> void:
	for root in _scene_level_roots():
		if root.data and _is_external(root.data):
			ResourceSaver.save(root.data)


# --- Panel / state -------------------------------------------------------------------

func _attach_panel() -> void:
	# Node3DEditorViewport > [SubViewportContainer > SubViewport, input surface]. Adding the
	# panel as the viewport's last child puts it above the surface so it receives clicks.
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var container := vp.get_parent() if vp else null
	var host := container.get_parent() if container else null
	if host is Control:
		host.add_child(panel)
		_panel_in_viewport = true
	else:
		add_control_to_container(CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, panel)


## A character scene (ActorModel root, from the actor tools) rather than a zone.
func _is_character_scene(root: Node) -> bool:
	var script: Script = root.get_script() if root else null
	return script != null and script.get_global_name() == &"ActorModel"


## Bakes every level in the open zone, saves it, and runs it with the player on the
## reference character (if shown), else on the surface at the centre of the 3D view
## (facing the way the camera looks), else at the zone's default spawn.
func _play_here() -> void:
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null or not scene is Zone:
		push_warning("N64 Level Tools: Play here needs an open zone scene (root with zone.gd).")
		return
	if scene.scene_file_path.is_empty():
		push_warning("N64 Level Tools: save the zone scene once before using Play here.")
		return
	_bake_all()
	for root in _scene_level_roots():
		if root.data and _is_external(root.data):
			ResourceSaver.save(root.data)
	EditorInterface.save_scene()

	var pos = null
	var yaw := 0.0
	var hit_root: Node = null
	var camera := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	if _reference and is_instance_valid(_reference):
		pos = _reference.global_position
		var fwd := -_reference.global_basis.z
		yaw = atan2(-fwd.x, -fwd.z)
		var hit := _ray_scene(pos + Vector3.UP * 0.5, Vector3.DOWN)
		hit_root = hit.get("root")
	elif camera:
		var hit := _pick(camera, camera.get_viewport().get_visible_rect().size * 0.5)
		if hit:
			pos = hit.position
			hit_root = hit.root
			var fwd := -camera.global_basis.z
			yaw = atan2(-fwd.x, -fwd.z)
	if pos == null:
		PlayHere.clear()
	else:
		var room_path := ""
		var n := hit_root
		while n and n != scene and not n is Room:
			n = n.get_parent()
		if n is Room:
			room_path = String(scene.get_path_to(n))
		var hour := float(EditorInterface.get_editor_settings().get_project_metadata(SETTINGS_SECTION, "preview_hour", 12.0))
		PlayHere.write(scene.scene_file_path, scene.global_transform.affine_inverse() * pos, yaw, room_path, hour)
	EditorInterface.play_current_scene()


## Bakes ambient occlusion into the vertex AO channel of the active level (replacing the
## previous bake, or multiplied into it). Occluders: every level in the scene.
## Strength / radius / samples come from the level (LevelData > Lighting AO settings).
func _bake_vertex_ao(add := false, merge := false) -> void:
	if not _level_ok():
		push_warning("N64 Level Tools: select a level to bake AO into.")
		return
	var d := level.data
	var t := Time.get_ticks_msec()
	var occluders: Array = _scene_level_roots() + _dressing_occluders()
	var samples := maxi(d.light_ao_samples, 16)
	var ao := LevelLighting.bake_vertex_ao(level, occluders, d.light_ao_strength, d.light_ao_radius, samples)
	var ur := get_undo_redo()
	ur.create_action("Bake Vertex AO", UndoRedo.MERGE_ENDS if merge else UndoRedo.MERGE_DISABLE, level)
	for brush in ao:
		var values: PackedFloat32Array = ao[brush]
		if add:
			for i in values.size():
				values[i] *= brush.get_vertex_ao(i)
		ur.add_do_property(brush, &"vertex_ao", values)
		ur.add_undo_property(brush, &"vertex_ao", brush.vertex_ao)
	# Door / passage dressing: AO per trim vertex, with the shape it was baked for.
	for node in LevelLighting.dressed_nodes(EditorInterface.get_edited_scene_root()):
		var mi: MeshInstance3D = node.get(&"_dressing")
		var arrays := mi.mesh.surface_get_arrays(0)
		var pts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var wp := PackedVector3Array()
		var wn := PackedVector3Array()
		for i in pts.size():
			wp.append(mi.global_transform * pts[i])
			wn.append(mi.global_basis * nrm[i])
		var dao := LevelLighting.bake_points_ao(wp, wn, occluders, d.light_ao_strength, d.light_ao_radius, samples)
		ur.add_do_property(node, &"dressing_ao", dao)
		ur.add_undo_property(node, &"dressing_ao", node.dressing_ao)
		ur.add_do_property(node, &"dressing_ao_key", node.dressing_shape_key())
		ur.add_undo_property(node, &"dressing_ao_key", node.dressing_ao_key)
		ur.add_do_method(node, &"_queue_rebuild")
		ur.add_undo_method(node, &"_queue_rebuild")
	ur.commit_action()
	print("[N64 Level Tools] Baked vertex AO for %d brushes in %d ms" % [ao.size(), Time.get_ticks_msec() - t])


## Door / passage trim in the edited scene, as extra occluders for the bakes.
func _dressing_occluders() -> Array:
	return LevelLighting.dressing_occluders(EditorInterface.get_edited_scene_root())


func _clear_vertex_ao() -> void:
	if not _level_ok():
		return
	var ur := get_undo_redo()
	ur.create_action("Clear Vertex AO", UndoRedo.MERGE_DISABLE, level)
	for brush in level.data.brushes:
		if brush and not brush.vertex_ao.is_empty():
			ur.add_do_property(brush, &"vertex_ao", PackedFloat32Array())
			ur.add_undo_property(brush, &"vertex_ao", brush.vertex_ao)
	for node in LevelLighting.dressed_nodes(EditorInterface.get_edited_scene_root()):
		if not node.dressing_ao.is_empty():
			ur.add_do_property(node, &"dressing_ao", PackedFloat32Array())
			ur.add_undo_property(node, &"dressing_ao", node.dressing_ao)
			ur.add_do_method(node, &"_queue_rebuild")
			ur.add_undo_method(node, &"_queue_rebuild")
	ur.commit_action()


func _toggle_reference(on: bool) -> void:
	_reference_on = on
	if on:
		_show_reference()
	else:
		_hide_reference()


## Puts the reference on the surface at the centre of the 3D view (else the scene origin).
func _show_reference() -> void:
	_hide_reference()
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null:
		return
	_reference = ReferenceCharacter.new()
	_reference.name = "_ReferenceCharacter"
	scene.add_child(_reference, false, Node.INTERNAL_MODE_BACK)
	var camera := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	if camera:
		var size := camera.get_viewport().get_visible_rect().size
		var hit := _pick(camera, size * 0.5)
		_reference.global_position = hit.position if hit else Vector3.ZERO
		_face_reference(camera)


func _hide_reference() -> void:
	if _reference and is_instance_valid(_reference):
		_reference.queue_free()
	_reference = null


## Turns the reference's facing marker towards the camera (flat).
func _face_reference(camera: Camera3D) -> void:
	var to_cam := camera.global_position - _reference.global_position
	to_cam.y = 0.0
	if to_cam.length_squared() > 1e-4:
		_reference.global_basis = Basis.looking_at(to_cam.normalized(), Vector3.UP)


func _on_world_menu(id: int) -> void:
	if id >= 100:
		return  # another plugin's item
	if id == 2:
		_new_stair_texture()
		return
	if id == 3:
		# Every exit / zone door / passage must lead to an existing zone (also run on export).
		var errors := ZoneLinks.report()
		var dialog := AcceptDialog.new()
		dialog.title = "Zone Links"
		dialog.dialog_text = "All zone links lead somewhere." if errors == 0 \
			else "%d zone link(s) lead nowhere — details in the Output panel." % errors
		EditorInterface.get_base_control().add_child(dialog)
		dialog.confirmed.connect(dialog.queue_free)
		dialog.canceled.connect(dialog.queue_free)
		dialog.popup_centered()
		return
	_zone_outdoor = id == 0
	if _zone_dialog == null:
		_zone_dialog = EditorFileDialog.new()
		_zone_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_zone_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		_zone_dialog.add_filter("*.tscn", "Zone scene")
		_zone_dialog.file_selected.connect(_create_zone)
		EditorInterface.get_base_control().add_child(_zone_dialog)
	_zone_dialog.title = "New %s Zone" % ("Outdoor" if _zone_outdoor else "Indoor")
	_zone_dialog.current_dir = "res://zones"
	_zone_dialog.current_file = "new_zone.tscn"
	_zone_dialog.popup_file_dialog()


## Stair texture over the texture selected in the FileSystem dock (or none yet: set `base`
## in the inspector), saved in res://textures/stairs and opened in the inspector.
func _new_stair_texture() -> void:
	const DEFAULT_TEMPLATE := "res://textures/_source/stairs/type_1/Stairs_04_64px.png"
	var base: Texture2D = null
	for path in EditorInterface.get_selected_paths():
		if ResourceLoader.exists(path) and not path.begins_with(N64StairTexture.TEMPLATE_DIR):
			base = load(path) as Texture2D
			if base and not base is N64StairTexture:
				break
			base = null
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://textures/stairs"))
	var stem := (base.resource_path.get_file().get_basename() if base else "new") + "_stairs"
	var path := "res://textures/stairs/%s.res" % stem
	var i := 2
	while FileAccess.file_exists(path):
		path = "res://textures/stairs/%s_%d.res" % [stem, i]
		i += 1
	var tex := N64StairTexture.new()
	tex.category = &"stairs"
	tex.base = base
	tex.template = DEFAULT_TEMPLATE
	tex.steps_per_repeat = N64StairTexture.detect_steps(DEFAULT_TEMPLATE)
	tex.set_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	if ResourceSaver.save(tex, path) != OK:
		push_error("N64 Level Tools: can't save %s." % path)
		return
	tex.take_over_path(path)
	if base:
		tex.rebuild()
	EditorInterface.get_resource_filesystem().scan()
	EditorInterface.edit_resource(tex)
	print("[N64 Level Tools] Created %s%s. Pick a template / base in the inspector; paint it on ramp slopes." % [
		path, "" if base else " (no texture was selected: set `base`)"])


func _create_zone(path: String) -> void:
	if ZoneTemplates.create(path, _zone_outdoor) != OK:
		return
	EditorInterface.get_resource_filesystem().scan()
	EditorInterface.open_scene_from_path(path)


func _on_action(action: StringName) -> void:
	match action:
		&"rotate_ccw": _rotate_brushes(-1.0)
		&"rotate_cw": _rotate_brushes(1.0)
		&"duplicate": _duplicate_brushes()
		&"delete_brushes": _delete_brushes()
		&"extrude": _extrude_step()
		&"make_face": _make_face()
		&"flip": _flip_faces()
		&"subdivide": _subdivide_faces()
		&"retopo": _retopo()
		&"fence": _fence_from_selection()
		&"rope": _start_rope()
		&"ramp": _ramp()
		&"move_dialog": _open_move_dialog()
		&"grid_resize": _open_grid_resize_dialog()
		&"play_here": _play_here()
		&"bake_vertex_ao":
			_bake_vertex_ao(panel.paint_panel.ao_add.button_pressed)
		&"delete_faces": _delete_faces()
		&"snap_selection": _snap_selection()
		&"bake": _bake_all()
		&"bake_lighting": _bake_lighting()
		&"save_data_as": _save_data_as()
		&"blender": _edit_in_blender()
		&"blender_unlink": _unlink_blender()
	_refresh_status()
	update_overlays()


func _place_basis() -> Basis:
	return Basis(Vector3.UP, place_turns * PI * 0.5)


## The next placed brush's world footprint (x / z swap on a quarter turn).
func _placed_size() -> Vector3:
	var size := BrushShapes.default_size(place_shape)
	return Vector3(size.z, size.y, size.x) if place_turns % 2 == 1 else size


func _set_place_shape(shape: int) -> void:
	if shape >= 0 and EditorInterface.get_edited_scene_root() == null:
		push_warning("N64 Level Tools: open or create a scene before placing brushes.")
		shape = -1
	place_shape = shape
	ghost_valid = false
	if shape >= 0 and mode != Mode.OBJECT:
		_set_mode(Mode.OBJECT)
	panel.set_place_shape(shape)
	_refresh_status()
	update_overlays()


func _set_mode(new_mode: int) -> void:
	mode = new_mode
	_clear_sub()
	if mode != Mode.OBJECT and place_shape >= 0:
		_set_place_shape(-1)
	if mode != Mode.OBJECT and sel_brushes.size() > 1:
		sel_brushes = [sel_brushes.back()]
	if mode == Mode.PAINT or mode == Mode.SCULPT:
		_ensure_paint_level()
	if mode == Mode.PAINT:
		# Painting needs the real textures, not the snap-grid checker.
		LevelRoot.set_debug_view(false, get_tree())
		panel.set_debug_view(false)
		_sync_paint_panel()
	panel.set_mode(mode)
	_refresh_status()
	update_overlays()


func _on_snap_changed(value: float) -> void:
	snap = maxf(value, 0.001)
	EditorInterface.get_editor_settings().set_project_metadata(SETTINGS_SECTION, "snap", snap)
	_store_grid_setting()
	RenderingServer.global_shader_parameter_set(GRID_PARAM, snap)
	update_overlays()


func _on_selection_changed() -> void:
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	var root: LevelRoot = nodes[0] if nodes.size() == 1 and nodes[0] is LevelRoot else null
	# Painting / sculpting keeps working on the current level while another node (a door,
	# a light) is selected in the editor.
	if root == null and (mode == Mode.PAINT or mode == Mode.SCULPT) and _level_ok():
		root = level
	_set_level(root)
	if _active():
		_inspect_active.call_deferred()
	_refresh_status()
	update_overlays()


func _set_level(root: LevelRoot) -> void:
	if root == level:
		return
	if level and is_instance_valid(level) and level.geometry_changed.is_connected(_on_level_geometry_changed):
		level.geometry_changed.disconnect(_on_level_geometry_changed)
	if level and is_instance_valid(level) and level.data and level.data.paint_changed.is_connected(_sync_paint_panel):
		level.data.paint_changed.disconnect(_sync_paint_panel)
		level.data.materials_changed.disconnect(_sync_paint_panel)
	level = root
	sel_brushes.clear()
	_clear_sub()
	paint.face_mask.clear()
	if level:
		level.geometry_changed.connect(_on_level_geometry_changed)
		if level.data:
			level.data.paint_changed.connect(_sync_paint_panel)
			level.data.materials_changed.connect(_sync_paint_panel)
	_sync_paint_panel()


func _on_level_geometry_changed() -> void:
	if _level_ok():
		sel_brushes = sel_brushes.filter(func(b): return level.has_brush(b))
	update_overlays()


## Cmd/Ctrl+D while a level is being edited duplicates brushes, never the Level node.
## Handled here, before the GUI: the Scene dock owns Cmd+D whenever the 3D view lacks
## focus (e.g. after clicking a panel button) and would duplicate the LevelRoot, which is
## the editor selection while brushes are picked. A second LevelRoot on the same data
## draws and bakes the whole level twice.
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_H \
			and not event.is_command_or_control_pressed() and _hide_key(event.alt_pressed):
		get_viewport().set_input_as_handled()
		return
	# Esc over the 3D view in Paint mode is ours, whatever holds the keyboard focus (keys
	# only reach _forward_3d_gui_input when the 3D view has it), and never reaches the
	# editor's own Esc handling.
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE \
			and mode == Mode.PAINT and panel.visible and _mouse_over_view():
		if not event.echo:
			_paint_escape()
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_D
			and event.is_command_or_control_pressed() and not event.shift_pressed and not event.alt_pressed):
		return
	if not _level_ok() or _other_node_selected():
		return
	var focus := EditorInterface.get_base_control().get_viewport().gui_get_focus_owner()
	if focus is TextEdit or focus is LineEdit:
		return
	if mode == Mode.OBJECT and not sel_brushes.is_empty():
		_duplicate_brushes()
		update_overlays()
	else:
		push_warning("N64 Level Tools: select brushes in Object mode to duplicate them (%s+D copies brushes, not the level)." % MOD)
	get_viewport().set_input_as_handled()


## H / Alt+H over the 3D view while the level tools are in use: hide brushes / show all.
## Handled before the GUI because the editor's own H (toggle visibility) would hide the
## selected node, i.e. the whole Level. Returns false to leave the key to the editor.
func _hide_key(show_all: bool) -> bool:
	if not panel.visible or _scene_level_roots().is_empty() or _other_node_selected() or not _mouse_over_view():
		return false
	if show_all:
		_show_all_brushes()
	elif mode == Mode.OBJECT and not sel_brushes.is_empty() and _level_ok():
		_hide_brushes(level, sel_brushes.duplicate())
		sel_brushes.clear()
		_inspect_active()
	else:
		# Paint / sculpt / sub-modes, or nothing selected: the brush under the cursor.
		var hit := _pick(input_camera, mouse_pos)
		if hit.is_empty():
			return true  # still ours: the editor's H would hide the Level
		_hide_brushes(hit.root, [hit.brush])
		if mode == Mode.PAINT:
			paint_hit = _pick(input_camera, mouse_pos)
	update_overlays()
	return true


## The mouse is over the 3D view last used and no text field has the keyboard focus.
func _mouse_over_view() -> bool:
	if input_camera == null or not is_instance_valid(input_camera):
		return false
	var vp := input_camera.get_viewport()
	if not Rect2(Vector2.ZERO, vp.get_visible_rect().size).has_point(vp.get_mouse_position()):
		return false
	var focus := EditorInterface.get_base_control().get_viewport().gui_get_focus_owner()
	return not (focus is TextEdit or focus is LineEdit)


func _level_ok() -> bool:
	return level != null and is_instance_valid(level) and level.is_inside_tree() and level.data != null


func _active() -> LevelBrush:
	if sel_brushes.is_empty() or not _level_ok():
		return null
	var b: LevelBrush = sel_brushes.back()
	return b if level.has_brush(b) else null


func _inspect_active() -> void:
	if _active():
		EditorInterface.inspect_object(_active(), "", true)


func _select_brush(root: LevelRoot, brush: LevelBrush, additive: bool) -> void:
	_set_level(root)
	if not additive:
		sel_brushes = [brush]
	elif brush in sel_brushes:
		sel_brushes.erase(brush)
	else:
		sel_brushes.append(brush)
	_clear_sub()
	var selection := EditorInterface.get_selection()
	var nodes := selection.get_selected_nodes()
	if not (nodes.size() == 1 and nodes[0] == root):
		selection.clear()
		selection.add_node(root)
	_inspect_active()
	_refresh_status()


func _clear_sub() -> void:
	sel_verts.clear()
	sel_edges.clear()
	sel_faces.clear()
	hover_vert = -1
	hover_edge = Vector2i(-1, -1)
	hover_face = -1
	hover_handle = Drag.NONE
	hover_resize = -1
	drag = Drag.NONE


func _valid_sel() -> Array[int]:
	var out: Array[int] = []
	var b := _active()
	if b:
		for i in sel_verts:
			if i < b.vertices.size():
				out.append(i)
	return out


func _bxf(brush: LevelBrush) -> Transform3D:
	return level.brush_global_transform(brush)


func _refresh_status() -> void:
	if panel == null:
		return
	var roots := _scene_level_roots()
	var fresh := 0
	var stale := 0
	var tris := 0
	var details := []
	for root in roots:
		var line := "not baked"
		if root.data and root.data.has_bake():
			tris += root.data.bake_summary.to_int()
			if root.is_bake_stale():
				stale += 1
				line = "stale"
			else:
				fresh += 1
				line = root.data.bake_summary
		details.append("%s: %s" % [root.name, line])

	var summary := "No level"
	var color := STATUS_IDLE
	if roots.size() == 1:
		summary = "Stale · rebake" if stale else ("Baked · %d tris" % tris if fresh else "Not baked")
	elif roots.size() > 1:
		summary = "%d/%d baked" % [fresh, roots.size()] + (" · %d stale" % stale if stale else "")
	if stale or (roots.size() > fresh and fresh > 0):
		color = STATUS_STALE
	elif fresh and fresh == roots.size():
		color = STATUS_OK

	var target := _target_level_root()
	var data_text := "No level data"
	if target and target.data:
		data_text = target.data.resource_path.get_file() if _is_external(target.data) else "Data: inline in scene"

	var hint := ""
	if place_shape >= 0:
		match place_shape:
			PASSAGE_TOOL: hint = "Click a wall or floor: passage opens outward · %s+click a passage: remove · Esc: cancel" % MOD
			DOOR_TOOL: hint = "Click a wall: door sits in it, joins the rooms on both sides · %s+click a door: remove · Esc: cancel" % MOD
			_: hint = "Click: place · Shift: keep placing · R / Shift+R: turn 90° · Esc: cancel"
	elif fence_edit and fence_edit.placing:
		hint = "Rope: click where it hangs from (snaps to corners near the mouse), then where it goes to · Esc: cancel"
	elif fence_edit and fence_edit.selected_fence() and fence_edit.selected_fence().is_rope():
		hint = "Rope: drag a point to move it (snaps to corners near the mouse) · click a section's + to add a point there · Shift+click: extend · Alt+click a point: remove · Alt+click a section: leave it out / put it back · Sag and look: in the inspector"
	elif fence_edit and fence_edit.selected_fence():
		hint = "Fence: drag a point to move it (snaps, sits on the ground) · click a section's + to split it · Shift+click the ground: extend · Alt+click a point: remove · Alt+click a section: open / close · gizmo: move the whole fence · squares: stretch it (posts added at the spacing)"
	elif mode == Mode.OBJECT:
		hint = "Click: select · Shift: add · R / Shift+R: turn 90° · H / Alt+H: hide / show · G: sticky grid (Shift+G: current snap + this height) · Squares: resize (Alt: keep grid) · Del · %s+D" % MOD
	elif mode == Mode.PAINT:
		hint = "Click/drag on surfaces to paint · Shift: erase · [ ]: size · Alt+click: line from the last stroke · I: pick a face's texture · A: line the base texture up with the nearest edge (Shift+A: flipped) · Border: Alt+click an edge to leave that side out · H: hide the brush under the cursor (Alt+H: show all) · %s+click: mask a face (Alt: flat region) · %s+drag: box mask (Shift: remove) · Esc: clear mask" % [MOD, MOD]
	elif mode == Mode.SCULPT:
		hint = "Drag on floors to sculpt · Shift: Raise ⇄ Lower · [ ]: radius · %s+click: pick height" % MOD
	elif _active() == null:
		hint = "Click a brush to edit it"
	elif mode == Mode.FACE:
		hint = "Click: select · Shift: add · %s+drag: extrude · Del · Arrows/PgUp/PgDn: nudge" % MOD
	else:
		hint = "Click/box: select · Shift: add · %s+drag: extrude · E / Shift+E: extrude up / out · R: ramp · Arrows/PgUp/PgDn: nudge" % MOD
	var hidden := 0
	for root in _scene_level_roots():
		hidden += root.hidden_count()
	if hidden > 0:
		hint = "%d brush(es) hidden — Alt+H shows them · " % hidden + hint
	if _sticky_grid:
		hint = "Grid at y %.2f m, %.2f m cells ([ ]: down / up) · " % [_sticky_y, _sticky_step] + hint
	panel.set_status(summary, color, "\n".join(details), data_text, hint)


# --- Input --------------------------------------------------------------------------

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if not panel.visible:
		return AFTER_GUI_INPUT_PASS
	if event is InputEventMouse:
		mouse_pos = event.position
		input_camera = camera
	if _reference and is_instance_valid(_reference) and event is InputEventMouseButton \
			and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and event.alt_pressed \
			and not (mode == Mode.OBJECT and _resize_at(camera, event.position) >= 0):
		var hit := _pick(camera, event.position)
		if hit:
			_reference.global_position = hit.position
			_face_reference(camera)
		return AFTER_GUI_INPUT_STOP
	if fence_edit.placing:
		return fence_edit.place_input(camera, event)
	if place_shape >= 0:
		return _placement_input(camera, event)
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		return AFTER_GUI_INPUT_PASS
	# A selected Fence: its points / sections are handles (FenceEditor).
	var editing_fence: LevelBrush = fence_edit.selected_fence()
	if editing_fence and fence_edit.input(editing_fence, camera, event) == AFTER_GUI_INPUT_STOP:
		return AFTER_GUI_INPUT_STOP
	# Another node is selected (light, spawn point, …): leave clicks, gizmo drags and keys
	# (Delete!) to the editor. Clicking level geometry selects the level again.
	if drag == Drag.NONE and mode != Mode.PAINT and mode != Mode.SCULPT and _other_node_selected():
		if hover_brush or hover_handle != Drag.NONE or hover_resize >= 0:
			hover_brush = null
			hover_handle = Drag.NONE
			hover_resize = -1
			update_overlays()
		return AFTER_GUI_INPUT_PASS
	if mode == Mode.PAINT:
		return _paint_input(camera, event)
	if mode == Mode.SCULPT:
		return _sculpt_input(camera, event)
	return _tool_input(camera, event)


## The editor selection is non-level nodes only (nothing selected counts as level: the
## tools may pick a brush then).
func _other_node_selected() -> bool:
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	if nodes.is_empty():
		return false
	for n in nodes:
		if n is LevelRoot:
			return false
	return true


func _placement_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_set_place_shape(-1)
		return AFTER_GUI_INPUT_STOP
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R \
			and not event.is_command_or_control_pressed() and place_shape != PASSAGE_TOOL and place_shape != DOOR_TOOL:
		place_turns = posmod(place_turns + (-1 if event.shift_pressed else 1), 4)
		_update_ghost(camera)
		update_overlays()
		return AFTER_GUI_INPUT_STOP
	# Cmd/Ctrl held with the Passage tool = removal: no placement ghost, highlight the
	# passage under the cursor instead (refreshed on mouse move and on key press/release).
	if (place_shape == PASSAGE_TOOL or place_shape == DOOR_TOOL) and (event is InputEventMouseMotion
			or (event is InputEventKey and (event.keycode == KEY_META or event.keycode == KEY_CTRL))):
		if event is InputEventMouseMotion:
			mouse_pos = event.position
		if _removal_held():
			ghost_valid = false
			_remove_hover = _passage_under(camera) if place_shape == PASSAGE_TOOL else _door_under(camera)
		else:
			_remove_hover = {}
			_update_ghost(camera)
		update_overlays()
		return AFTER_GUI_INPUT_PASS
	if event is InputEventMouseMotion:
		_update_ghost(camera)
		update_overlays()
		return AFTER_GUI_INPUT_PASS
	# Remove a passage: Cmd+click on macOS, Ctrl+click elsewhere. macOS also turns
	# Ctrl+click into a right click, so accept that form too.
	if (place_shape == PASSAGE_TOOL or place_shape == DOOR_TOOL) and event is InputEventMouseButton and event.pressed \
			and ((event.button_index == MOUSE_BUTTON_LEFT and event.is_command_or_control_pressed())
				or (event.button_index == MOUSE_BUTTON_RIGHT and event.ctrl_pressed)):
		mouse_pos = event.position
		if place_shape == PASSAGE_TOOL:
			_remove_passage_at(camera)
		else:
			_remove_door_at(camera)
		return AFTER_GUI_INPUT_STOP
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_update_ghost(camera)
			if ghost_valid:
				if place_shape == PASSAGE_TOOL:
					_place_passage()
				elif place_shape == DOOR_TOOL:
					_place_door()
				else:
					_place_brush()
			if not event.shift_pressed:
				_set_place_shape(-1)
		return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS


func _tool_input(camera: Camera3D, event: InputEvent) -> int:
	var sub := mode != Mode.OBJECT and _active() != null
	if event is InputEventKey:
		return _key_input(event, sub)
	if event is InputEventMouseMotion:
		if drag == Drag.BOX:
			update_overlays()
			return AFTER_GUI_INPUT_STOP
		if drag != Drag.NONE:
			_update_drag(camera)
			update_overlays()
			return AFTER_GUI_INPUT_STOP
		_update_hover(camera, sub)
		update_overlays()
		return AFTER_GUI_INPUT_PASS
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			return _press(camera, event, sub)
		if drag == Drag.NONE:
			return AFTER_GUI_INPUT_PASS
		if drag == Drag.BOX:
			_finish_box(camera, event.shift_pressed, event.is_command_or_control_pressed())
		else:
			_end_drag()
		drag = Drag.NONE
		_refresh_status()
		update_overlays()
		return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS


func _key_input(event: InputEventKey, sub: bool) -> int:
	if not event.pressed or event.echo:
		return AFTER_GUI_INPUT_PASS
	match event.keycode:
		KEY_ESCAPE:
			if sub and not (sel_verts.is_empty() and sel_edges.is_empty() and sel_faces.is_empty()):
				_clear_sub()
			elif not sel_brushes.is_empty():
				sel_brushes.clear()
			else:
				return AFTER_GUI_INPUT_PASS
		KEY_DELETE, KEY_BACKSPACE:
			if sub:
				_delete_faces()
			elif mode == Mode.OBJECT and not sel_brushes.is_empty():
				_delete_brushes()
			else:
				return AFTER_GUI_INPUT_PASS
		KEY_E:
			if sub and not event.is_command_or_control_pressed():
				if event.shift_pressed:
					_extrude_outward()
				else:
					_extrude_step()
			else:
				return AFTER_GUI_INPUT_PASS
		KEY_BRACKETLEFT, KEY_BRACKETRIGHT:
			if not _sticky_grid or event.is_command_or_control_pressed():
				return AFTER_GUI_INPUT_PASS
			_raise_sticky_grid(1 if event.keycode == KEY_BRACKETRIGHT else -1)
		KEY_G:
			if event.is_command_or_control_pressed() or event.alt_pressed:
				return AFTER_GUI_INPUT_PASS
			if event.shift_pressed:
				_set_sticky_grid(true)  # move it to the height under the cursor
			else:
				_set_sticky_grid(not _sticky_grid)
		KEY_R:
			if event.is_command_or_control_pressed():
				return AFTER_GUI_INPUT_PASS
			if sub:
				_ramp()
			elif mode == Mode.OBJECT and not sel_brushes.is_empty():
				_rotate_brushes(-1.0 if event.shift_pressed else 1.0)
			else:
				return AFTER_GUI_INPUT_PASS
		KEY_F:
			if (mode == Mode.VERTEX or mode == Mode.EDGE) and not event.is_command_or_control_pressed():
				_make_face()
			else:
				return AFTER_GUI_INPUT_PASS
		KEY_PAGEUP, KEY_PAGEDOWN when _sticky_grid and event.alt_pressed:
			_raise_sticky_grid(1 if event.keycode == KEY_PAGEUP else -1)
		KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_PAGEUP, KEY_PAGEDOWN:
			var has_sel := (mode == Mode.OBJECT and not sel_brushes.is_empty()) or (sub and not sel_verts.is_empty())
			if not has_sel or input_camera == null:
				return AFTER_GUI_INPUT_PASS
			_move_selection(_nudge_vector(event.keycode) * snap * (10.0 if event.shift_pressed else 1.0), "Nudge")
		_:
			return AFTER_GUI_INPUT_PASS
	update_overlays()
	return AFTER_GUI_INPUT_STOP


func _update_hover(camera: Camera3D, sub: bool) -> void:
	hover_handle = _gizmo_at(camera, mouse_pos)
	hover_resize = _resize_at(camera, mouse_pos) if mode == Mode.OBJECT else -1
	hover_vert = -1
	hover_edge = Vector2i(-1, -1)
	hover_face = -1
	hover_brush = null
	hover_hit = {}
	if sub and mode == Mode.VERTEX:
		hover_vert = _vertex_at(camera, mouse_pos)
	elif sub and mode == Mode.EDGE:
		hover_edge = _edge_at(camera, mouse_pos)
	if hover_vert >= 0 or hover_edge.x >= 0:
		return
	var hit := _pick(camera, mouse_pos)
	if hit.is_empty():
		return
	if mode == Mode.OBJECT:
		hover_hit = hit
	if sub and mode == Mode.FACE and hit.brush == _active():
		hover_face = hit.face
	elif not sub or hit.brush != _active():
		hover_root = hit.root
		hover_brush = hit.brush


func _press(camera: Camera3D, event: InputEventMouseButton, sub: bool) -> int:
	var shift := event.shift_pressed
	if mode == Mode.OBJECT:
		var r := _resize_at(camera, mouse_pos)
		if r >= 0:
			_begin_resize(camera, r)
			return AFTER_GUI_INPUT_STOP
	var handle := _gizmo_at(camera, mouse_pos)
	if handle != Drag.NONE:
		_begin_drag(camera, handle, event.is_command_or_control_pressed())
		return AFTER_GUI_INPUT_STOP

	# Sub-element modes: every press may become a box select; it's only a click (pick a
	# vertex / edge / face, or another brush) if the mouse barely moved on release.
	if sub:
		drag = Drag.BOX
		box_from = mouse_pos
		update_overlays()
		return AFTER_GUI_INPUT_STOP
	return _click(camera, shift, sub)


## Click (press + release without dragging) in the current mode. `path` (Cmd/Ctrl):
## selects the shortest path from the last picked vertex / edge / face (Blender).
func _click(camera: Camera3D, shift: bool, sub: bool, path := false) -> int:
	if sub and mode == Mode.VERTEX:
		var v := _vertex_at(camera, mouse_pos)
		if v >= 0:
			if not (path and _extend_path(sel_verts, v)):
				_toggle(sel_verts, v, shift)
			update_overlays()
			return AFTER_GUI_INPUT_STOP
	elif sub and mode == Mode.EDGE:
		var e := _edge_at(camera, mouse_pos)
		if e.x >= 0:
			if not (path and _extend_path(sel_edges, e)):
				_toggle(sel_edges, e, shift)
			_sync_verts_from_edges()
			update_overlays()
			return AFTER_GUI_INPUT_STOP

	var hit := _pick(camera, mouse_pos)
	if hit and not (sub and hit.brush == _active()):
		_select_brush(hit.root, hit.brush, shift and mode == Mode.OBJECT)
		update_overlays()
		return AFTER_GUI_INPUT_STOP
	if sub:
		if mode == Mode.FACE and hit:
			if not (path and _extend_path(sel_faces, hit.face)):
				_toggle(sel_faces, hit.face, shift)
			_sync_verts_from_faces()
		elif not shift:
			_clear_sub()
		update_overlays()
		return AFTER_GUI_INPUT_STOP
	# Object mode, empty space: let Godot handle it (deselect / pick other nodes).
	if not shift:
		sel_brushes.clear()
	update_overlays()
	return AFTER_GUI_INPUT_PASS


## Adds the shortest path over the active brush from the last picked element to `item`
## (which becomes the last, so clicks chain). False when there's nothing to start from.
func _extend_path(list: Array, item: Variant) -> bool:
	var b := _active()
	if b == null or list.is_empty() or list.back() == item:
		return false
	var faces: Array = []
	for f in b.get_face_count():
		faces.append(b.get_face_vertex_ids(f))
	var kind: int = {Mode.VERTEX: 0, Mode.EDGE: 1, Mode.FACE: 2}[mode]
	var route := ActorPieceOps.path_over(b.vertices, faces, kind, list.back(), item)
	if route.is_empty():
		return false
	for e in route:
		list.erase(e)
		list.append(e)
	return true


func _toggle(list: Array, item: Variant, additive: bool) -> void:
	if not additive:
		list.clear()
		list.append(item)
	elif item in list:
		list.erase(item)
	else:
		list.append(item)


func _sync_verts_from_edges() -> void:
	sel_verts.clear()
	for e in sel_edges:
		for v in [e.x, e.y]:
			if not v in sel_verts:
				sel_verts.append(v)


func _sync_verts_from_faces() -> void:
	sel_verts.clear()
	var b := _active()
	for f in sel_faces:
		if f >= b.get_face_count():
			continue
		for v in b.get_face_vertex_ids(f):
			if not v in sel_verts:
				sel_verts.append(v)


func _finish_box(camera: Camera3D, shift: bool, path := false) -> void:
	var b := _active()
	var rect := Rect2(box_from, Vector2.ZERO).expand(mouse_pos)
	if b == null or rect.size.length() < 4.0:
		_click(camera, shift, b != null, path)
		return
	var xf := _bxf(b)
	var inside := {}
	for i in b.vertices.size():
		var w := xf * b.vertices[i]
		if not camera.is_position_behind(w) and rect.has_point(camera.unproject_position(w)):
			inside[i] = true
	if mode == Mode.VERTEX:
		if not shift:
			sel_verts.clear()
		for i in inside:
			if not i in sel_verts:
				sel_verts.append(i)
	elif mode == Mode.EDGE:
		if not shift:
			sel_edges.clear()
		for e in b.get_edges():
			if inside.has(e.x) and inside.has(e.y) and not e in sel_edges:
				sel_edges.append(e)
		_sync_verts_from_edges()
	elif mode == Mode.FACE:
		if not shift:
			sel_faces.clear()
		for f in b.get_face_count():
			if Array(b.get_face_vertex_ids(f)).all(func(i): return inside.has(i)) and not f in sel_faces:
				sel_faces.append(f)
		_sync_verts_from_faces()


# --- Dragging: move gizmo -----------------------------------------------------------

func _gizmo_center() -> Variant:
	if not _level_ok():
		return null
	if mode == Mode.OBJECT:
		var live := sel_brushes.filter(func(b): return level.has_brush(b))
		if live.is_empty():
			return null
		var c := Vector3.ZERO
		for b in live:
			c += _bxf(b).origin
		return c / live.size()
	var b := _active()
	var ids := _valid_sel()
	if b == null or ids.is_empty():
		return null
	var xf := _bxf(b)
	var c := Vector3.ZERO
	for i in ids:
		c += xf * b.vertices[i]
	return c / ids.size()


func _begin_drag(camera: Camera3D, handle: Drag, ctrl: bool) -> void:
	if mode != Mode.OBJECT and _active() and _active().blend_file != "":
		_set_piece_locked()
		return
	drag = handle
	drag_delta = Vector3.ZERO
	drag_extruded = false
	drag_origin = _gizmo_center()
	drag_axis = AXES[handle - Drag.AXIS_X] if handle <= Drag.AXIS_Z else Vector3.ZERO
	if mode == Mode.OBJECT:
		drag_xforms.clear()
		for b in sel_brushes:
			drag_xforms.append(b.transform)
	else:
		var b := _active()
		drag_geom_before = b.snapshot()
		if ctrl:
			drag_extruded = _extrude(b)
		drag_start_verts = b.vertices.duplicate()
	var from := camera.project_ray_origin(mouse_pos)
	var dir := camera.project_ray_normal(mouse_pos)
	if handle == Drag.PLANE_XZ:
		var p = Plane(Vector3.UP, drag_origin).intersects_ray(from, dir)
		drag_start_point = p if p != null else drag_origin
	else:
		drag_start_t = _line_param(drag_origin, drag_axis, from, dir)


func _update_drag(camera: Camera3D) -> void:
	if drag == Drag.RESIZE:
		_update_resize(camera)
		return
	var from := camera.project_ray_origin(mouse_pos)
	var dir := camera.project_ray_normal(mouse_pos)
	var world_delta := Vector3.ZERO
	if drag == Drag.PLANE_XZ:
		var p = Plane(Vector3.UP, drag_origin).intersects_ray(from, dir)
		if p == null:
			return
		var d: Vector3 = p - drag_start_point
		world_delta = Vector3(snappedf(d.x, snap), 0.0, snappedf(d.z, snap))
	else:
		world_delta = drag_axis * snappedf(_line_param(drag_origin, drag_axis, from, dir) - drag_start_t, snap)
	if world_delta == drag_delta:
		return
	drag_delta = world_delta
	if mode == Mode.OBJECT:
		var local := level.global_basis.inverse() * world_delta
		for i in sel_brushes.size():
			var t := drag_xforms[i]
			t.origin += local
			sel_brushes[i].transform = t
		return
	var b := _active()
	var local_delta := _bxf(b).basis.inverse() * world_delta
	var verts := drag_start_verts.duplicate()
	for i in _valid_sel():
		verts[i] = drag_start_verts[i] + local_delta
	b.vertices = verts


func _end_drag() -> void:
	if drag == Drag.RESIZE:
		_end_resize()
		return
	if mode == Mode.OBJECT:
		if drag_delta == Vector3.ZERO:
			return
		var ur := get_undo_redo()
		ur.create_action("Move Brushes", UndoRedo.MERGE_DISABLE, level)
		for i in sel_brushes.size():
			ur.add_do_property(sel_brushes[i], &"transform", sel_brushes[i].transform)
			ur.add_undo_property(sel_brushes[i], &"transform", drag_xforms[i])
		for b: LevelBrush in sel_brushes:
			if b.opening_spec():
				_refresh_cut_surroundings(ur, _recarve_passage(ur, level, b))
		ur.commit_action()
		return
	var b := _active()
	if drag_delta == Vector3.ZERO:
		if drag_extruded:
			_apply_snapshot(b, drag_geom_before)
			_clear_sub()
		return
	_commit_geometry(b, drag_geom_before, "Extrude" if drag_extruded else "Move Brush Vertices")


## Parameter along a world line closest to the mouse ray.
func _line_param(origin: Vector3, axis: Vector3, from: Vector3, dir: Vector3) -> float:
	var w0 := origin - from
	var b := axis.dot(dir)
	var denom := axis.length_squared() - b * b
	if absf(denom) < 1e-6:
		return drag_start_t
	return (b * dir.dot(w0) - axis.dot(w0)) / denom


# --- Dragging: resize handles -------------------------------------------------------

func _resize_handles() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if mode != Mode.OBJECT or sel_brushes.size() != 1 or _active() == null or _active().blend_file != "":
		return out
	var b := _active()
	var box := b.resize_box()
	var xf := _bxf(b)
	var c := box.get_center()
	for axis in 3:
		if box.size[axis] < 1e-4:
			continue
		for side in [1, -1]:
			var p := c
			p[axis] = box.end[axis] if side > 0 else box.position[axis]
			out.append({id = axis * 2 + (0 if side > 0 else 1), axis = axis, side = side, world = xf * p})
	return out


func _resize_at(camera: Camera3D, pos: Vector2) -> int:
	for h in _resize_handles():
		if not camera.is_position_behind(h.world) and camera.unproject_position(h.world).distance_to(pos) < HANDLE_RADIUS:
			return h.id
	return -1


func _begin_resize(camera: Camera3D, id: int) -> void:
	var b := _active()
	for h in _resize_handles():
		if h.id != id:
			continue
		drag = Drag.RESIZE
		drag_delta = Vector3.ZERO
		drag_resize = {id = id, axis = h.axis, side = h.side, box = b.resize_box(), size = b.size,
			transform = b.transform, verts = b.vertices.duplicate(), geom = b.snapshot(), fence_points = b.path_points().duplicate(),
			passage = {width = b.passage.width, height = b.passage.height, depth = b.passage.depth} if b.is_passage() \
				else ({width = b.door.width, height = b.door.height} if b.is_door() else {}),
			# Alt: grid-preserving (cells keep their size, new loops are added).
			grid = Input.is_key_pressed(KEY_ALT),
			cell = BrushOps.border_cell(b.vertices, h.axis, h.side)}
		drag_origin = h.world
		drag_axis = (_bxf(b).basis * AXES[h.axis]).normalized()
		drag_start_t = _line_param(drag_origin, drag_axis, camera.project_ray_origin(mouse_pos), camera.project_ray_normal(mouse_pos))
		return


func _update_resize(camera: Camera3D) -> void:
	var t := _line_param(drag_origin, drag_axis, camera.project_ray_origin(mouse_pos), camera.project_ray_normal(mouse_pos))
	var r := drag_resize
	var d := snappedf(t - drag_start_t, r.cell if r.grid else snap)
	if drag_delta.x == d:
		return
	drag_delta = Vector3(d, 0, 0)
	if r.grid:
		var gb := _active()
		_apply_snapshot(gb, r.geom)
		if d != 0.0:
			_apply_grid_resize(gb, r.axis, r.side, d * r.side, r.cell)
		return
	var a: int = r.axis
	var box: AABB = r.box
	var lo := box.position[a]
	var hi := box.end[a]
	var nlo := lo
	var nhi := hi
	if r.side > 0:
		nhi = maxf(hi + d, lo + snap)
	else:
		nlo = minf(lo + d, hi - snap)
	var b := _active()
	if not b.hand_edited:
		var s: Vector3 = r.size
		s[a] = nhi - nlo
		var off := Vector3.ZERO
		off[a] = (nlo - lo) if a == 1 else ((nlo + nhi) - (lo + hi)) * 0.5
		var xf: Transform3D = r.transform
		xf.origin += xf.basis * off
		b.size = s
		b.transform = xf
	elif b.is_passage() or b.is_door():
		# A passage's / door's size: width (either side, the other stays), height (top),
		# a passage's depth (the far end; the threshold stays). The level rebuilds it.
		var spec := b.opening_spec()
		var xf: Transform3D = r.transform
		# The dragged side lands on a grid line (not just a whole step from where it was).
		var axis_w: Vector3 = (xf.basis * AXES[a]).normalized()
		var at := xf.origin.dot(axis_w) if a != 1 else 0.0
		if r.side > 0:
			nhi = maxf(snappedf(at + nhi, snap) - at, nlo + snap)
		else:
			nlo = minf(snappedf(at + nlo, snap) - at, nhi - snap)
		if a == 0:
			spec.set(&"width", nhi - nlo)
			xf.origin += xf.basis.x * ((nlo + nhi) - (lo + hi)) * 0.5
		elif a == 1 and r.side > 0:
			spec.set(&"height", nhi - nlo)
		elif a == 2 and r.side < 0 and b.is_passage():
			b.passage.depth = nhi - nlo
		b.transform = xf
	elif b.is_fence() or b.is_rope():
		# A fence / rope stretches its points; posts and panels fill the new length (a
		# fence's height comes from the ground, a rope's points can go up and down too).
		if (a != 1 or b.is_rope()) and hi - lo > 1e-6:
			var pts: PackedVector3Array = r.fence_points.duplicate()
			var kf := (nhi - nlo) / (hi - lo)
			for i in pts.size():
				var v := pts[i]
				v[a] = nlo + (v[a] - lo) * kf
				pts[i] = v
			b.set(b.path_properties()[0], pts)
	elif hi - lo > 1e-6:
		var verts: PackedVector3Array = r.verts.duplicate()
		var k := (nhi - nlo) / (hi - lo)
		for i in verts.size():
			var v := verts[i]
			v[a] = nlo + (v[a] - lo) * k
			verts[i] = v
		b.vertices = verts


func _end_resize() -> void:
	if drag_delta == Vector3.ZERO:
		return
	var b := _active()
	var r := drag_resize
	if b.is_passage() or b.is_door():
		var spec := b.opening_spec()
		var pur := get_undo_redo()
		pur.create_action("Resize %s" % ("Door" if b.is_door() else "Passage"), UndoRedo.MERGE_DISABLE, level)
		for prop in r.passage:
			pur.add_do_property(spec, prop, spec.get(prop))
			pur.add_undo_property(spec, prop, r.passage[prop])
		pur.add_do_property(b, &"transform", b.transform)
		pur.add_undo_property(b, &"transform", r.transform)
		_refresh_cut_surroundings(pur, _recarve_passage(pur, level, b))
		pur.commit_action(false)
		return
	var before: Dictionary = r.geom
	var after := b.snapshot()
	var ur := get_undo_redo()
	ur.create_action("Resize Brush", UndoRedo.MERGE_DISABLE, level)
	ur.add_do_property(b, &"size", b.size)
	ur.add_undo_property(b, &"size", r.size)
	ur.add_do_property(b, &"transform", b.transform)
	ur.add_undo_property(b, &"transform", r.transform)
	for key in after:
		ur.add_do_property(b, key, after[key])
		ur.add_undo_property(b, key, before[key])
	ur.commit_action()


# --- Geometry operations ------------------------------------------------------------

func _apply_snapshot(b: LevelBrush, s: Dictionary) -> void:
	for key in s:
		b.set(key, s[key])


func _commit_geometry(b: LevelBrush, before: Dictionary, action: String) -> void:
	if b.blend_file != "":
		_apply_snapshot(b, before)
		_set_piece_locked()
		return
	_weld_coincident(b)
	var after := b.snapshot()
	after.hand_edited = true
	var ur := get_undo_redo()
	ur.create_action(action, UndoRedo.MERGE_DISABLE, level)
	for key in after:
		ur.add_do_property(b, key, after[key])
		ur.add_undo_property(b, key, before[key])
	ur.commit_action()


## Auto-weld after every geometry edit: vertices of `b` at the same spot (a wall ring
## extruded back to its start, a vertex dragged onto another) become one, so later edits
## move them together and lighting / AO blend across. Keeps the sub-selection.
func _weld_coincident(b: LevelBrush) -> void:
	var w := BrushOps.weld_coincident(b.vertices, b.get_faces())
	if w.merged == 0:
		return
	b.vertices = w.verts
	b.set_faces(w.faces)
	b.remap_faces(w.map)
	b.blend_vertex_colors(w.vertex_sources)
	if b != _active():
		return
	var remap: PackedInt32Array = w.remap
	var verts: Array[int] = []
	for v in sel_verts:
		if v < remap.size() and not remap[v] in verts:
			verts.append(remap[v])
	sel_verts = verts
	var edges: Array[Vector2i] = []
	for e in sel_edges:
		if e.x < remap.size() and e.y < remap.size() and remap[e.x] != remap[e.y]:
			var ne := Vector2i(mini(remap[e.x], remap[e.y]), maxi(remap[e.x], remap[e.y]))
			if not ne in edges:
				edges.append(ne)
	sel_edges = edges
	var new_of := {}
	for i in w.map.size():
		new_of[w.map[i]] = i
	var faces: Array[int] = []
	for f in sel_faces:
		if new_of.has(f):
			faces.append(new_of[f])
	sel_faces = faces
	print("[N64 Level Tools] Welded %d overlapping vertices." % w.merged)


## After _extrude: vertex -> the vertex it was copied from (itself for old ones).
var _extrude_sources := PackedInt32Array()


## Extrudes the face/edge selection in place (zero length). Returns false if nothing to do.
func _extrude(b: LevelBrush) -> bool:
	var result := {}
	if mode == Mode.FACE and not sel_faces.is_empty():
		result = BrushOps.extrude_faces(b.vertices, b.get_faces(), sel_faces)
	elif mode == Mode.EDGE and not sel_edges.is_empty():
		result = BrushOps.extrude_edges(b.vertices, b.get_faces(), sel_edges)
		if result.moved.is_empty():
			push_warning("N64 Level Tools: only open edges (used by one face) can be extruded.")
			return false
		sel_edges = result.new_edges
	elif mode == Mode.VERTEX and sel_verts.size() >= 2:
		# Blender-style: selected border vertices grow walls; the floor stays.
		var edges := BrushOps.boundary_edges_among(b.get_faces(), sel_verts)
		if edges.is_empty():
			var sel := {}
			for v in sel_verts:
				sel[v] = true
			if not BrushOps.outward_plan(b.vertices, b.get_faces(), sel, [], true).inside.is_empty():
				push_warning("N64 Level Tools: these vertices' edges already have faces on both sides (e.g. a wall stands on them), so there's no open border to grow a wall from. Shift+E extends the surface outwards instead.")
			else:
				push_warning("N64 Level Tools: select 2+ neighbouring vertices along an open border to extrude.")
			return false
		result = BrushOps.extrude_edges(b.vertices, b.get_faces(), edges)
	else:
		return false
	_apply_extrude(b, result)
	return true


## Puts an extrude result on the brush (faces, paint and colours follow); its new
## vertices become the selection.
func _apply_extrude(b: LevelBrush, result: Dictionary) -> void:
	var old_faces := b.get_faces()
	var old_corners := b.corner_colors.duplicate() if b.has_corner_colors() else PackedColorArray()
	b.vertices = result.verts
	b.set_faces(result.faces)
	b.remap_faces(result.map, false)
	b.remap_vertex_colors(result.vertex_map)
	if not old_corners.is_empty():
		b.remap_corner_colors(old_faces, old_corners, result.map, result.vertex_map)
	b.hand_edited = true
	sel_verts = result.moved
	_extrude_sources = result.vertex_map


## Fills a face through the selected vertices (Vertex mode) or edges' vertices (Edge mode).
func _make_face() -> void:
	var b := _active()
	if b == null or not (mode == Mode.VERTEX or mode == Mode.EDGE):
		push_warning("N64 Level Tools: Make Face works on selected vertices or edges.")
		return
	var picked: Array[int] = []
	if mode == Mode.EDGE:
		for e in sel_edges:
			for v in [e.x, e.y]:
				if not v in picked:
					picked.append(v)
	else:
		picked = sel_verts.duplicate()
	var toward := Vector3.UP
	if input_camera:
		var xf := _bxf(b)
		var c := Vector3.ZERO
		for v in picked:
			c += b.vertices[v]
		c /= maxi(picked.size(), 1)
		toward = xf.basis.inverse() * (input_camera.global_position - xf * c)
	var result := BrushOps.make_face(b.vertices, b.get_faces(), picked, toward)
	if result.has("error"):
		push_warning("N64 Level Tools: can't make a face: %s." % result.error)
		return
	var before := b.snapshot()
	b.set_faces(result.faces)
	b.remap_faces(result.map, false)
	b.hand_edited = true
	_commit_geometry(b, before, "Make Face")


func _extrude_step() -> void:
	var b := _active()
	if b == null or mode == Mode.OBJECT:
		return
	var before := b.snapshot()
	var dir := Vector3.ZERO
	var faces := b.get_faces()
	if mode == Mode.FACE:
		for f in sel_faces:
			dir += PolyUtil.newell_normal(b.get_face_points(f))
	elif mode == Mode.EDGE:
		for e in sel_edges:
			dir += BrushOps.boundary_edge_outward(b.vertices, faces, e)
	elif mode == Mode.VERTEX:
		# Along the faces the vertices belong to (a floor's border extrudes up).
		var vf := b.get_vertex_faces()
		var seen := {}
		for v in sel_verts:
			if v >= vf.size():
				continue
			for f in vf[v]:
				if not seen.has(f):
					seen[f] = true
					dir += PolyUtil.newell_normal(b.get_face_points(f))
	dir = _dominant_axis(_bxf(b).basis * dir)
	if not _extrude(b):
		return
	var local := _bxf(b).basis.inverse() * (dir * snap)
	var verts := b.vertices.duplicate()
	for i in sel_verts:
		verts[i] += local
	b.vertices = verts
	_commit_geometry(b, before, "Extrude")


## Shift+E: extrudes the selected border (Vertex / Edge mode) one snap step outwards,
## each edge along its own direction in the surface, away from the face it extends, so a
## floor grows on every side; corners move diagonally (mitred: both sides move a full
## step). The face an edge extends: its only face on an open border; on a closed mesh (a
## box) a fully selected neighbour, else the neighbour nearest the selection's middle (the
## top for a loop round a box's top: a lip). Edges inside a selected region are skipped.
func _extrude_outward() -> void:
	var b := _active()
	if b == null or not (mode == Mode.VERTEX or mode == Mode.EDGE):
		push_warning("N64 Level Tools: outward extrude works on border vertices or edges.")
		return
	var faces := b.get_faces()
	var verts := b.vertices
	var sel := {}
	if mode == Mode.VERTEX:
		for v in sel_verts:
			sel[v] = true
	else:
		for e in sel_edges:
			sel[e.x] = true
			sel[e.y] = true
	if sel.is_empty():
		return
	var plan := BrushOps.outward_plan(verts, faces, sel, sel_edges if mode == Mode.EDGE else [], mode == Mode.VERTEX)
	var inside: Dictionary = plan.inside
	if inside.is_empty():
		push_warning("N64 Level Tools: select 2+ neighbouring vertices (or edges) along the edge of a surface to extrude outwards.")
		return
	var basis := _bxf(b).basis
	var normals := {}  # original vertex -> outward directions (world) of its edges
	var edges: Array[Vector2i] = []
	for e: Vector2i in inside:
		edges.append(e)
		var n: Vector3 = (basis * plan.outward[e]).normalized()
		for v in [e.x, e.y]:
			if not normals.has(v):
				normals[v] = []
			normals[v].append(n)
	var before := b.snapshot()
	var result := BrushOps.extrude_edges(verts, faces, edges, inside)
	if result.moved.is_empty():
		return
	_apply_extrude(b, result)
	if mode == Mode.EDGE:
		sel_edges = result.new_edges
	var out := b.vertices.duplicate()
	var inv := basis.inverse()
	for i in sel_verts:
		out[i] += inv * (_miter(normals.get(_extrude_sources[i], [])) * snap)
	b.vertices = out
	_commit_geometry(b, before, "Extrude Outward")


## Offset moving every edge with outward direction in `dirs` (unit) out by 1: one edge
## its own direction, a corner the mitre of its two.
static func _miter(dirs: Array) -> Vector3:
	var uniq: Array[Vector3] = []
	for d in dirs:
		if not uniq.any(func(u): return u.dot(d) > 0.999):
			uniq.append(d)
	if uniq.is_empty():
		return Vector3.ZERO
	if uniq.size() == 1:
		return uniq[0]
	if uniq.size() == 2:
		var c := 1.0 + uniq[0].dot(uniq[1])
		if c > 0.05:
			return (uniq[0] + uniq[1]) / c
	var sum := Vector3.ZERO
	for u in uniq:
		sum += u
	return sum.normalized() if sum.length_squared() > 1e-8 else Vector3.ZERO


## Camera-relative nudge: Up/Down along the view direction snapped to X or Z, Left/Right
## along the screen's horizontal axis, PageUp/PageDown along Y.
func _nudge_vector(key: Key) -> Vector3:
	var fwd := -input_camera.global_basis.z
	fwd.y = 0.0
	fwd = _dominant_axis(fwd) if fwd.length_squared() > 1e-6 else Vector3.FORWARD
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	match key:
		KEY_UP: return fwd
		KEY_DOWN: return -fwd
		KEY_RIGHT: return right
		KEY_LEFT: return -right
		KEY_PAGEUP: return Vector3.UP
		KEY_PAGEDOWN: return Vector3.DOWN
	return Vector3.ZERO


## Moves the current selection by a world offset: brushes in Object mode, else the
## selected vertices of the active brush. Undoable.
## Ramp (R): the selection's highest vertices are the top, the low row farthest from them
## the foot; the vertices between get the height for how far they lie from the foot toward
## the top (measured flat), so the slope is even. See BrushOps.ramp_heights.
func _ramp() -> void:
	var b := _active()
	if b == null:
		return
	var xf := _bxf(b)
	var world := {}
	for i in _valid_sel():
		world[i] = xf * b.vertices[i]
	var r := BrushOps.ramp_heights(world)
	if r.has("error"):
		push_warning("N64 Level Tools: Ramp: " + r.error)
		return
	var before := b.snapshot()
	var inv := xf.affine_inverse()
	var verts := b.vertices.duplicate()
	for i in r.heights:
		var p: Vector3 = world[i]
		verts[i] = inv * Vector3(p.x, r.heights[i], p.z)
	b.vertices = verts
	_commit_geometry(b, before, "Ramp Brush Vertices")
	update_overlays()


func _move_selection(world_delta: Vector3, action := "Move") -> void:
	if not _level_ok() or world_delta == Vector3.ZERO:
		return
	if mode == Mode.OBJECT:
		if sel_brushes.is_empty():
			return
		var local := level.global_basis.inverse() * world_delta
		var ur := get_undo_redo()
		ur.create_action(action + " Brushes", UndoRedo.MERGE_DISABLE, level)
		for b in sel_brushes:
			var t := b.transform
			t.origin += local
			ur.add_do_property(b, &"transform", t)
			ur.add_undo_property(b, &"transform", b.transform)
		ur.commit_action()
		return
	var b := _active()
	if b == null or sel_verts.is_empty():
		return
	var before := b.snapshot()
	var local := _bxf(b).basis.inverse() * world_delta
	var verts := b.vertices.duplicate()
	for i in _valid_sel():
		verts[i] += local
	b.vertices = verts
	_commit_geometry(b, before, action + " Brush Vertices")
	update_overlays()


func _open_move_dialog() -> void:
	if _move_dialog == null:
		_move_dialog = ConfirmationDialog.new()
		_move_dialog.title = "Move Selection"
		_move_dialog.ok_button_text = "Move"
		var grid := GridContainer.new()
		grid.columns = 2
		for axis in ["X", "Y", "Z"]:
			var l := Label.new()
			l.text = axis + " (m)"
			grid.add_child(l)
			var s := SpinBox.new()
			s.min_value = -1000
			s.max_value = 1000
			s.allow_greater = true
			s.allow_lesser = true
			s.custom_minimum_size.x = 120
			grid.add_child(s)
			_move_fields.append(s)
		_move_dialog.add_child(grid)
		_move_dialog.confirmed.connect(func():
			_move_selection(Vector3(_move_fields[0].value, _move_fields[1].value, _move_fields[2].value), "Move"))
		EditorInterface.get_base_control().add_child(_move_dialog)
	for s in _move_fields:
		s.step = snap
		s.value = 0.0
	_move_dialog.popup_centered()


## Grid-preserving resize of `b` (see BrushOps.grid_resize); paint stays on the cells it
## was on, new cells start unpainted. Returns false if nothing changed.
func _apply_grid_resize(b: LevelBrush, axis: int, side: int, delta: float, cell := 0.0) -> bool:
	var result := BrushOps.grid_resize(b.vertices, b.get_faces(), axis, side, delta, cell)
	if result.has("error"):
		return false
	var rects := {}
	for f in b.get_faces().size():
		rects[f] = b.get_face_planar_rect(f)
	b.hand_edited = true
	b.vertices = result.verts
	b.set_faces(result.faces)
	b.remap_faces(result.map)
	b.blend_vertex_colors(result.vertex_sources)
	var child_parents := {}
	for f in result.split:
		child_parents[f] = rects[result.map[f]]
	b.crop_child_masks(child_parents)
	if not result.fresh.is_empty():
		var masks := {}
		for key in b.face_masks:
			if not result.fresh.has(key.x):
				masks[key] = b.face_masks[key]
		b.face_masks = masks
	return true


func _open_grid_resize_dialog() -> void:
	var b := _active()
	if b == null:
		push_warning("N64 Level Tools: select one brush to grid-resize.")
		return
	if _grid_dialog == null:
		_grid_dialog = ConfirmationDialog.new()
		_grid_dialog.title = "Grid Resize"
		_grid_dialog.ok_button_text = "Resize"
		var grid := GridContainer.new()
		grid.columns = 2
		var add_row := func(label: String, control: Control) -> void:
			var l := Label.new()
			l.text = label
			grid.add_child(l)
			control.custom_minimum_size.x = 140
			grid.add_child(control)
		_grid_axis = OptionButton.new()
		for n in ["X", "Y", "Z"]:
			_grid_axis.add_item(n)
		add_row.call("Axis", _grid_axis)
		_grid_side = OptionButton.new()
		for n in ["+ side", "− side", "Both sides"]:
			_grid_side.add_item(n)
		add_row.call("Side", _grid_side)
		_grid_amount = SpinBox.new()
		_grid_amount.min_value = -1000
		_grid_amount.max_value = 1000
		_grid_amount.allow_greater = true
		_grid_amount.allow_lesser = true
		_grid_amount.suffix = "m"
		add_row.call("Grow by (− shrinks)", _grid_amount)
		_grid_info = Label.new()
		_grid_info.modulate = Color(1, 1, 1, 0.6)
		var box := VBoxContainer.new()
		box.add_child(grid)
		box.add_child(_grid_info)
		_grid_dialog.add_child(box)
		var refresh := func(_i := 0) -> void:
			var ab := _active()
			if ab == null:
				return
			var cell := BrushOps.border_cell(ab.vertices, _grid_axis.selected, 1 if _grid_side.selected != 1 else -1)
			_grid_amount.step = cell
			_grid_info.text = "Cells along %s: %.2f m. Cells keep their size; walls\non that side move with the border." % [_grid_axis.get_item_text(_grid_axis.selected), cell]
		_grid_axis.item_selected.connect(refresh)
		_grid_side.item_selected.connect(refresh)
		_grid_dialog.about_to_popup.connect(refresh)
		_grid_dialog.confirmed.connect(func():
			var cb := _active()
			if cb == null or _grid_amount.value == 0.0:
				return
			var before := cb.snapshot()
			var sides: Array = [1] if _grid_side.selected == 0 else [-1] if _grid_side.selected == 1 else [1, -1]
			var changed := false
			for side in sides:
				changed = _apply_grid_resize(cb, _grid_axis.selected, side, _grid_amount.value) or changed
			if changed:
				_commit_geometry(cb, before, "Grid Resize"))
		EditorInterface.get_base_control().add_child(_grid_dialog)
	_grid_amount.value = 0.0
	_grid_dialog.popup_centered()


func _subdivide_faces() -> void:
	var b := _active()
	if b == null:
		return
	var targets := _faces_from_selection(b)
	if targets.is_empty():
		push_warning("N64 Level Tools: select faces to subdivide (Face mode).")
		return
	var before := b.snapshot()
	var parent_rects := {}
	for f in targets:
		parent_rects[f] = b.get_face_planar_rect(f)
	var result := BrushOps.subdivide_faces(b.vertices, b.get_faces(), targets)
	b.vertices = result.verts
	b.set_faces(result.faces)
	b.remap_faces(result.map)
	b.blend_vertex_colors(result.vertex_sources)
	var child_parents := {}
	for i in result.map.size():
		if parent_rects.has(result.map[i]):
			child_parents[i] = parent_rects[result.map[i]]
	b.crop_child_masks(child_parents)
	_commit_geometry(b, before, "Subdivide Faces")
	if mode == Mode.FACE:
		sel_faces = result.selected
		_sync_verts_from_faces()


## Rebuilds the selection as grids sized to the snap (BrushOps.retopo): whole brushes in
## Object mode, the selected faces (or faces touching the selected vertices / edges)
## otherwise.
func _retopo() -> void:
	var jobs := []
	if mode == Mode.OBJECT:
		for b in sel_brushes:
			var all: Array[int] = []
			for f in b.get_face_count():
				all.append(f)
			jobs.append([b, all])
	elif _active():
		jobs.append([_active(), _faces_from_selection(_active())])
	jobs = jobs.filter(func(j): return not j[1].is_empty())
	if jobs.is_empty():
		push_warning("N64 Level Tools: select brushes (Object mode) or faces / vertices to retopo.")
		return
	var before_faces := 0
	var after_faces := 0
	for job in jobs:
		var b: LevelBrush = job[0]
		var targets: Array[int] = []
		targets.assign(job[1])
		var result := BrushOps.retopo(b.vertices, b.get_faces(), targets, snap)
		if result.has("error"):
			push_warning("N64 Level Tools: retopo: %s." % result.error)
			continue
		var before := b.snapshot()
		var parent_rects := {}
		for f in targets:
			parent_rects[f] = b.get_face_planar_rect(f)
		before_faces += b.get_face_count()
		b.vertices = result.verts
		b.set_faces(result.faces)
		b.remap_faces(result.map)
		b.blend_vertex_colors(result.vertex_sources)
		var child_parents := {}
		for i in result.selected:
			if parent_rects.has(result.map[i]):
				child_parents[i] = parent_rects[result.map[i]]
		b.crop_child_masks(child_parents)
		after_faces += b.get_face_count()
		_commit_geometry(b, before, "Retopo")
		if mode == Mode.FACE and b == _active():
			sel_faces = result.selected
			_sync_verts_from_faces()
	print("[N64 Level Tools] Retopo at %.2f m: %d -> %d faces. Re-bake lighting / AO for these brushes." % [snap, before_faces, after_faces])
	_refresh_status()
	update_overlays()


# --- Fences --------------------------------------------------------------------------------

## Fence button (Vertex mode): selected vertices on two neighbouring posts of an existing
## fence toggle that span open / closed (one post alone: the span after it, or before it at
## the path's end); otherwise each connected line of selected vertices
## (joined by edges; gaps where they aren't) becomes a new Fence.
func _fence_from_selection() -> void:
	var b := _active()
	if b == null or mode != Mode.VERTEX or sel_verts.is_empty():
		_new_fence_at_view()
		return
	var to_level := level.global_transform.affine_inverse() * level.brush_global_transform(b)
	var pos := {}
	for v in sel_verts:
		pos[v] = to_level * b.vertices[v]
	if _toggle_fence_openings(pos.values()):
		return
	if sel_verts.size() < 2:
		push_warning("N64 Level Tools: select a line of vertices (Vertex mode) for the fence, or a fence post to open / close it.")
		return
	# Lines: selected vertices joined by edges of the brush.
	var adj := {}
	for v in sel_verts:
		adj[v] = []
	for e in b.get_edges():
		if adj.has(e.x) and adj.has(e.y):
			adj[e.x].append(e.y)
			adj[e.y].append(e.x)
	var chains := []
	var seen := {}
	var starts: Array = sel_verts.filter(func(v): return adj[v].size() == 1)
	starts.append_array(sel_verts.filter(func(v): return adj[v].size() != 1))
	for start in starts:
		if seen.has(start) or adj[start].is_empty():
			continue
		var chain := [start]
		seen[start] = true
		var cur: int = start
		while true:
			var nxt := -1
			for o in adj[cur]:
				if not seen.has(o):
					nxt = o
					break
			if nxt < 0:
				break
			chain.append(nxt)
			seen[nxt] = true
			cur = nxt
		var closed: bool = chain.size() > 2 and chain[0] in adj[chain[-1]]
		chains.append([chain, closed])
	if chains.is_empty():
		# No edges between them: follow the order they were selected in.
		chains.append([sel_verts.duplicate(), false])
	var style := _default_fence_style()
	for c in chains:
		if c[0].size() < 2:
			continue
		var start: Vector3 = level.global_transform * pos[c[0][0]]
		var pts := PackedVector3Array()
		for v in c[0]:
			pts.append(level.global_transform * pos[v] - start)
		_add_fence_brush(start, pts, c[1], style)


## Fence button with no vertex line selected: a fence brush on the ground where the view
## looks (snapped), selected for editing (drag its points, Shift+click to extend, stretch).
func _new_fence_at_view() -> void:
	if not _ensure_paint_level():
		push_warning("N64 Level Tools: open a scene with a level first.")
		return
	var camera := input_camera if input_camera and is_instance_valid(input_camera) else null
	var start := level.global_position
	var along := Vector3.RIGHT
	if camera:
		var vp_size := camera.get_viewport().get_visible_rect().size
		var hit := _pick(camera, vp_size * 0.5)
		if not hit.is_empty():
			start = hit.position
		var f := -camera.global_basis.z
		var side := Vector3(f.x, 0.0, f.z).cross(Vector3.UP)
		along = Vector3.RIGHT if absf(side.x) >= absf(side.z) else Vector3.BACK
	var step := maxf(snap, 0.25)
	start.x = snappedf(start.x, step)
	start.z = snappedf(start.z, step)
	var style := _default_fence_style()
	var length := snappedf(maxf(style.max_spacing * 2.0, step), step)
	_add_fence_brush(start, PackedVector3Array([Vector3.ZERO, along * length]), false, style)


## Adds a fence brush at `origin` (world) with `points` relative to it, selected.
func _add_fence_brush(origin: Vector3, points: PackedVector3Array, closed: bool, style: FenceStyle) -> LevelBrush:
	var b := LevelBrush.new()
	b.hand_edited = true
	b.cutout = true
	var xf := Transform3D.IDENTITY
	xf.origin = level.global_transform.affine_inverse() * origin
	b.transform = xf
	b.fence_points = points
	b.fence_closed = closed
	b.fence_style = style
	var ur := get_undo_redo()
	ur.create_action("Add Fence", UndoRedo.MERGE_DISABLE, level)
	ur.add_do_method(level.data, &"add_brush", b)
	ur.add_do_reference(b)
	ur.add_undo_method(level.data, &"remove_brush", b)
	ur.commit_action()
	if mode != Mode.OBJECT:
		_set_mode(Mode.OBJECT)
	sel_brushes = [b]
	_inspect_active()
	_refresh_status()
	update_overlays()
	print("[N64 Level Tools] Fence added (Object mode): drag its points, Shift+click the ground to extend, squares stretch it. Post spacing: in the inspector.")
	return b


## Selected points on two neighbouring points of a fence brush: toggle the section(s)
## between them.
func _toggle_fence_openings(points: Array) -> bool:
	for fence: LevelBrush in level.data.brushes:
		if fence == null or not fence.is_fence():
			continue
		var xf := level.brush_global_transform(fence)
		var hit := {}
		for i in fence.fence_points.size():
			for p: Vector3 in points:
				if (xf * fence.fence_points[i]).distance_to(level.global_transform * p) < 0.02:
					hit[i] = true
		var n := fence.fence_points.size()
		var spans := PackedInt32Array()
		for i in n - 1 + (1 if fence.fence_closed else 0):
			if hit.has(i) and hit.has((i + 1) % n):
				spans.append(i)
		if spans.is_empty():
			continue
		var open := fence.fence_open.duplicate()
		for sp in spans:
			var at := open.find(sp)
			if at >= 0:
				open.remove_at(at)
			else:
				open.append(sp)
		var ur := get_undo_redo()
		ur.create_action("Open / Close Fence", UndoRedo.MERGE_DISABLE, level)
		ur.add_do_property(fence, &"fence_open", open)
		ur.add_undo_property(fence, &"fence_open", fence.fence_open)
		ur.commit_action()
		return true
	return false


## {brushes, textures}: the fence's generated brushes (tagged) and the level's texture
## list including the style's textures.
func _fence_brushes(fence: Fence) -> Dictionary:
	var data: LevelData = (fence.level as LevelRoot).data
	var textures := data.textures
	var idx := {}
	var tiles := {}
	var aspects := {}
	for key in ["panel", "post", "cap", "arch"]:
		var t: Texture2D = fence.style.get(("end_cap" if key == "cap" else key) + "_texture") if fence.style else null
		if t:
			if not t in textures:
				textures = textures.duplicate()
				textures.append(t)
			idx[key] = textures.find(t)
			# Fitted UVs are in metres: the shader divides by the texture's tile in this level.
			tiles[key] = PaintAtlas.base_tile_for(t, data)
			aspects[key] = float(t.get_width()) / maxf(t.get_height(), 1.0)
	# Points are relative to the Fence node; the builder works in the level's space.
	var root := fence.level as LevelRoot
	var fence_xf: Transform3D = fence.global_transform if fence.is_inside_tree() else \
		EditorInterface.get_edited_scene_root().global_transform * fence.transform
	var to_level := root.global_transform.affine_inverse() * fence_xf
	var pts := PackedVector3Array()
	for p in fence.points:
		pts.append(to_level * p)
	var out: Array[LevelBrush] = []
	var parts := FenceBuilder.build(pts, fence.closed, fence.open_spans, fence.style, idx, tiles, aspects)
	for i in parts.size():
		var nb: LevelBrush = parts[i]
		if nb:
			nb.tag = fence.tag
			nb.resource_name = FENCE_PARTS[i]  # its role: rebuilds update it in place
			out.append(nb)
	return {brushes = out, textures = textures}


## Called by Fence when its path / style changes: swaps its brushes for new ones.
func _rebuild_fence(fence: Fence) -> void:
	var root := fence.level as LevelRoot
	if root == null or root.data == null or fence.tag == &"":
		return
	var built := _fence_brushes(fence)
	if built.textures != root.data.textures:
		root.data.textures = built.textures
	# Parts update in place (same brushes, same places in the level: only their meshes
	# rebuild, nothing else shifts), so dragging a fence stays smooth.
	var existing := {}
	for old in root.data.brushes:
		if old and old.tag == fence.tag and FENCE_PARTS.has(old.resource_name) and not existing.has(old.resource_name):
			existing[old.resource_name] = old
	for nb: LevelBrush in built.brushes:
		var old: LevelBrush = existing.get(nb.resource_name)
		if old == null:
			root.data.add_brush(nb)
			continue
		existing.erase(nb.resource_name)
		old.set_block_signals(true)
		for key in ["vertices", "face_indices", "face_counts", "face_textures", "corner_uvs", "cutout", "bake_mode", "hand_edited"]:
			old.set(key, nb.get(key))
		old.set_block_signals(false)
		old.emit_changed()
	var gone := existing.values()
	for old in root.data.brushes:
		if old and old.tag == fence.tag and not FENCE_PARTS.has(old.resource_name):
			gone.append(old)  # from before parts had roles
	for old in gone:
		sel_brushes.erase(old)
		root.data.remove_brush(old)
	EditorInterface.mark_scene_as_unsaved()
	update_overlays()


# --- Ropes ---------------------------------------------------------------------------------

## An alphabet's atlas / template was edited / reimported: ropes with words in it rebuild
## their banners.
func _on_resources_reimported(paths: PackedStringArray) -> void:
	for root: LevelRoot in _scene_level_roots():
		if root.data == null:
			continue
		for b: LevelBrush in root.data.brushes:
			if b == null or not b.is_rope():
				continue
			for h: RopeHang in b.rope_hangs:
				if h == null or h.kind != RopeHang.Kind.BANNER or h.text.strip_edges().is_empty():
					continue
				var a := h.text_alphabet()
				var art: Texture2D = a.get("atlas") if a is GlyphAlphabet else (a.get("template") if a is SyllabaryAlphabet else null)
				if art and art.resource_path in paths:
					a.emit_changed()  # drops its cached pixels
					b.rope_dirty = true
					b.emit_changed()

## Rope button: click the rope's two anchors in the 3D view (FenceEditor.place_input).
func _start_rope() -> void:
	if not _ensure_paint_level():
		push_warning("N64 Level Tools: open a scene with a level first.")
		return
	place_shape = -1
	fence_edit.start_rope()
	_refresh_status()


## Adds a rope brush hanging from `from` to `to` (world), selected for editing.
func _add_rope_brush(from: Vector3, to: Vector3) -> LevelBrush:
	var b := LevelBrush.new()
	b.hand_edited = true
	b.cutout = true
	var xf := Transform3D.IDENTITY
	xf.origin = level.global_transform.affine_inverse() * from
	b.transform = xf
	var inv := (level.global_transform * xf).affine_inverse()
	b.rope_points = PackedVector3Array([Vector3.ZERO, inv * to])
	b.rope_sag = _default_rope_sag(from.distance_to(to))
	b.rope_style = _default_rope_style()
	var ur := get_undo_redo()
	ur.create_action("Add Rope", UndoRedo.MERGE_DISABLE, level)
	ur.add_do_method(level.data, &"add_brush", b)
	ur.add_do_reference(b)
	ur.add_undo_method(level.data, &"remove_brush", b)
	ur.commit_action()
	if mode != Mode.OBJECT:
		_set_mode(Mode.OBJECT)
	sel_brushes = [b]
	_inspect_active()
	_refresh_status()
	update_overlays()
	print("[N64 Level Tools] Rope added: drag its points, Shift+click to extend it, click a section's + for a point between. Sag / style: in the inspector.")
	return b


## A new rope's sag: a little slack for its length (`length` 0: what the preview shows).
func _default_rope_sag(length := 0.0) -> float:
	if length <= 0.0 and fence_edit._first != null and fence_edit._cursor != null:
		length = fence_edit._first.distance_to(fence_edit._cursor)
	return snappedf(clampf(length * 0.08, 0.05, 2.0), 0.05)


## Shared default style with a generated rope texture (made the first time it's needed).
func _default_rope_style() -> RopeStyle:
	if ResourceLoader.exists(ROPE_STYLE_PATH):
		return load(ROPE_STYLE_PATH)
	var style := RopeStyle.new()
	style.texture = _default_rope_texture()
	DirAccess.make_dir_recursive_absolute(ROPE_STYLE_PATH.get_base_dir())
	ResourceSaver.save(style, ROPE_STYLE_PATH)
	style.take_over_path(ROPE_STYLE_PATH)
	return style


## A small twisted-rope cutout texture (three strands, rope running left to right).
func _default_rope_texture() -> Texture2D:
	if ResourceLoader.exists(ROPE_TEXTURE_PATH):
		return load(ROPE_TEXTURE_PATH)
	DirAccess.make_dir_recursive_absolute(ROPE_TEXTURE_PATH.get_base_dir())
	return RopeTexture.generate(ROPE_TEXTURE_PATH)


## Shared default style (set its textures once; every fence made with it follows).
func _default_fence_style() -> FenceStyle:
	if ResourceLoader.exists(FENCE_STYLE_PATH):
		return load(FENCE_STYLE_PATH)
	var style := FenceStyle.new()
	ResourceSaver.save(style, FENCE_STYLE_PATH)
	style.take_over_path(FENCE_STYLE_PATH)
	return style


func _dominant_axis(v: Vector3) -> Vector3:
	if v.length_squared() < 1e-8:
		return Vector3.UP
	var a := v.abs()
	if a.x >= a.y and a.x >= a.z:
		return Vector3(signf(v.x), 0, 0)
	if a.y >= a.z:
		return Vector3(0, signf(v.y), 0)
	return Vector3(0, 0, signf(v.z))


func _faces_from_selection(b: LevelBrush) -> Array[int]:
	var out: Array[int] = []
	var faces := b.get_faces()
	for f in faces.size():
		var poly := faces[f]
		var hit := false
		match mode:
			Mode.FACE:
				hit = f in sel_faces
			Mode.VERTEX:
				hit = Array(poly).any(func(i): return i in sel_verts)
			Mode.EDGE:
				for k in poly.size():
					var a := poly[k]
					var c := poly[(k + 1) % poly.size()]
					if Vector2i(mini(a, c), maxi(a, c)) in sel_edges:
						hit = true
						break
		if hit:
			out.append(f)
	return out


func _delete_faces() -> void:
	var b := _active()
	if b == null:
		return
	var doomed := _faces_from_selection(b)
	if doomed.is_empty():
		return
	var before := b.snapshot()
	var result := BrushOps.delete_faces(b.vertices, b.get_faces(), doomed)
	b.vertices = result.verts
	b.set_faces(result.faces)
	b.remap_faces(result.map)
	b.remap_vertex_colors(result.vertex_map)
	_commit_geometry(b, before, "Delete Brush Faces")
	_clear_sub()


func _flip_faces() -> void:
	var b := _active()
	if b == null:
		return
	var targets := _faces_from_selection(b)
	if targets.is_empty():
		return
	var before := b.snapshot()
	b.set_faces(BrushOps.flip_faces(b.get_faces(), targets))
	_commit_geometry(b, before, "Flip Brush Faces")


func _snap_selection() -> void:
	if not _level_ok():
		return
	var grid := Vector3.ONE * snap
	if mode == Mode.OBJECT:
		if sel_brushes.is_empty():
			return
		var ur := get_undo_redo()
		ur.create_action("Snap Brushes To Grid", UndoRedo.MERGE_DISABLE, level)
		for b in sel_brushes:
			var t := b.transform
			t.origin = level.global_transform.affine_inverse() * (level.global_transform * t.origin).snapped(grid)
			ur.add_do_property(b, &"transform", t)
			ur.add_undo_property(b, &"transform", b.transform)
		ur.commit_action()
		return
	var b := _active()
	if b == null or sel_verts.is_empty():
		return
	var before := b.snapshot()
	var xf := _bxf(b)
	var verts := b.vertices.duplicate()
	for i in _valid_sel():
		verts[i] = xf.affine_inverse() * (xf * verts[i]).snapped(grid)
	b.vertices = verts
	_commit_geometry(b, before, "Snap Brush Vertices")


# --- Brush operations ---------------------------------------------------------------

func _rotate_brushes(direction: float) -> void:
	if not _level_ok() or sel_brushes.is_empty():
		return
	var ur := get_undo_redo()
	ur.create_action("Rotate Brushes", UndoRedo.MERGE_DISABLE, level)
	for b in sel_brushes:
		var t := b.transform
		t.basis = Basis(Vector3.UP, direction * PI * 0.5) * t.basis
		ur.add_do_property(b, &"transform", t)
		ur.add_undo_property(b, &"transform", b.transform)
	ur.commit_action()


func _duplicate_brushes() -> void:
	if not _level_ok() or sel_brushes.is_empty():
		return
	var copies: Array[LevelBrush] = []
	var ur := get_undo_redo()
	ur.create_action("Duplicate Brushes", UndoRedo.MERGE_DISABLE, level)
	for b in sel_brushes:
		var copy := b.duplicate() as LevelBrush
		copies.append(copy)
		ur.add_do_method(level.data, &"add_brush", copy)
		ur.add_do_reference(copy)
		ur.add_undo_method(level.data, &"remove_brush", copy)
	ur.commit_action()
	sel_brushes = copies
	_inspect_active()


func _delete_brushes() -> void:
	if not _level_ok() or sel_brushes.is_empty():
		return
	var data := level.data
	var doomed := sel_brushes.filter(func(b): return level.has_brush(b))
	doomed.sort_custom(func(a, b): return data.brushes.find(a) < data.brushes.find(b))
	var ur := get_undo_redo()
	ur.create_action("Delete Brushes", UndoRedo.MERGE_DISABLE, level)
	var filled := []
	for b in doomed:
		if b.opening_spec():
			# A passage / door closes the wall opening it carved.
			filled.append_array(_remove_passage_brush(ur, level, b))
			continue
		ur.add_do_method(data, &"remove_brush", b)
		ur.add_undo_method(data, &"add_brush", b, data.brushes.find(b))
		ur.add_undo_reference(b)
	if not filled.is_empty():
		_refresh_cut_surroundings(ur, filled)
	ur.commit_action()
	sel_brushes.clear()
	EditorInterface.inspect_object(level)
	var files := {}
	for b in doomed:
		if b.blend_file != "":
			files[b.blend_file] = true
	if not files.is_empty():
		_offer_trash_blends(blender.orphaned(files.keys()))


# --- Paint ----------------------------------------------------------------------------

func _paint_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventKey:
		if event.pressed and event.keycode in [KEY_BRACKETLEFT, KEY_BRACKETRIGHT]:
			paint.size = clampf(paint.size * (0.8 if event.keycode == KEY_BRACKETLEFT else 1.25), 0.1, 8.0)
			panel.paint_panel.set_tool_state(paint)
			update_overlays()
			return AFTER_GUI_INPUT_STOP
		if event.pressed and not event.echo and event.keycode == KEY_R and not event.is_command_or_control_pressed():
			# Next quarter turn for the base texture (Shift: back).
			paint.rotation = fposmod(paint.rotation + (-90.0 if event.shift_pressed else 90.0), 360.0)
			panel.paint_panel.set_tool_state(paint)
			update_overlays()
			return AFTER_GUI_INPUT_STOP
		if event.pressed and not event.echo and event.keycode == KEY_I and not event.is_command_or_control_pressed():
			_pick_face_texture(_pick(camera, mouse_pos))
			return AFTER_GUI_INPUT_STOP
		if event.pressed and not event.echo and event.keycode == KEY_A and not event.is_command_or_control_pressed():
			_align_base_to_edge(_pick(camera, mouse_pos), event.shift_pressed)
			return AFTER_GUI_INPUT_STOP
		if event.keycode == KEY_ESCAPE:
			if event.pressed and not event.echo:
				_paint_escape()
			return AFTER_GUI_INPUT_STOP
		if event.keycode in [KEY_META, KEY_CTRL, KEY_ALT]:
			update_overlays()  # mask preview follows the modifiers
		return AFTER_GUI_INPUT_PASS
	if event is InputEventMouseMotion:
		var held := paint.stroke_brush()
		paint_hit = _pick_brush(camera, mouse_pos, level, held) if held else _pick(camera, mouse_pos)
		if _mask_drag != 0:
			if not _mask_box and mouse_pos.distance_to(_mask_from) > 6.0:
				_mask_box = true
			update_overlays()
			return AFTER_GUI_INPUT_STOP
		if not _grad.is_empty():
			if not _grad.dragged and event.position.distance_to(_grad.screen) > 6.0:
				_grad.dragged = true
			if _grad.dragged:
				var end = Plane(_grad.normal, _grad.start).intersects_ray(camera.project_ray_origin(event.position),
					camera.project_ray_normal(event.position))
				if end != null:
					paint.gradient.preview(_grad.start, end)
			update_overlays()
			return AFTER_GUI_INPUT_STOP
		if paint.scatter.is_stroking() and paint_hit:
			paint.scatter.stroke_to(paint_hit.position)
		if paint.is_stroking() and paint_hit:
			if paint.tool == LevelPaintTool.Tool.FACE:
				paint.paint_face(paint_hit.root, paint_hit.brush, paint_hit.face)
			else:
				paint.stroke_to(paint_hit.position)
		update_overlays()
		return AFTER_GUI_INPUT_STOP if paint.is_stroking() or paint.scatter.is_stroking() else AFTER_GUI_INPUT_PASS
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			_region_cache = {}  # neighbours may have changed
			if paint.scatter.is_stroking():
				paint.scatter.end()
				update_overlays()
				return AFTER_GUI_INPUT_STOP
			if not _grad.is_empty():
				paint.gradient.commit()
				_grad_last = {basis = _grad.basis, normal = _grad.normal, dragged = _grad.dragged}
				_grad = {}
				_grad_hover = {}
				update_overlays()
				return AFTER_GUI_INPUT_STOP
			if _mask_drag != 0:
				if _mask_box:
					_set_mask(_faces_in_box(camera, Rect2(_mask_from, Vector2.ZERO).expand(mouse_pos)), not event.shift_pressed)
				elif not _mask_click.is_empty():
					var h: Dictionary = _mask_click.hit
					_set_mask(LevelPaintTool.coplanar_region(h.brush, h.face) if _mask_click.alt
						else [{brush = h.brush, face = h.face}], _mask_drag > 0)
				_mask_drag = 0
				_mask_box = false
				_mask_click = {}
				update_overlays()
				return AFTER_GUI_INPUT_STOP
			if paint.is_stroking():
				paint.end_stroke()
				if _paint_saved_tool >= 0:
					paint.tool = _paint_saved_tool
					_paint_saved_tool = -1
				_refresh_status()
			return AFTER_GUI_INPUT_STOP
		var hit := _pick(camera, mouse_pos)
		if _picking:
			_picking = false
			_pick_face_texture(hit)
			return AFTER_GUI_INPUT_STOP
		if event.is_command_or_control_pressed() and hit.is_empty() and _level_ok():
			# Mask box started off the level (e.g. against the sky): box only.
			_mask_drag = 1
			_mask_from = mouse_pos
			_mask_click = {}
			_mask_box = false
			return AFTER_GUI_INPUT_STOP
		if hit.is_empty():
			return AFTER_GUI_INPUT_PASS
		if hit.root != level:
			_select_level(hit.root)
		if event.is_command_or_control_pressed():
			# Face mask: click toggles the face (Alt: its flat region) on release; dragging
			# box-selects instead (Shift on release: remove).
			_mask_drag = -1 if paint.face_mask.has([hit.brush, hit.face]) else 1
			_mask_from = mouse_pos
			_mask_click = {hit = hit, alt = event.alt_pressed}
			_mask_box = false
			update_overlays()
			return AFTER_GUI_INPUT_STOP
		var erase: bool = event.shift_pressed
		match paint.tool:
			LevelPaintTool.Tool.BRUSH, LevelPaintTool.Tool.ERASE:
				if paint.layer > 0 and paint.layer > hit.root.data.active_layers().size() and paint.layer != LevelPaintTool.VERTEX_LAYER:
					push_warning("N64 Level Tools: add an overlay layer first.")
					return AFTER_GUI_INPUT_STOP
				if erase:
					_paint_saved_tool = paint.tool
					paint.tool = LevelPaintTool.Tool.ERASE
				if event.alt_pressed and _can_line(hit.root):
					_paint_line(camera, hit.root)
					if _paint_saved_tool >= 0:
						paint.tool = _paint_saved_tool
						_paint_saved_tool = -1
					_refresh_status()
					update_overlays()
					return AFTER_GUI_INPUT_STOP
				paint.begin_stroke(hit.root, hit.position, hit.brush)
			LevelPaintTool.Tool.FACE:
				# One face per click; drag on to paint each face crossed (one undo step).
				if paint.layer > 0 and paint.layer > hit.root.data.active_layers().size():
					push_warning("N64 Level Tools: add an overlay layer first.")
					return AFTER_GUI_INPUT_STOP
				paint.begin_face_stroke(hit.root, erase, hit.brush)
				paint.paint_face(hit.root, hit.brush, hit.face)
			LevelPaintTool.Tool.FILL_FACE:
				# Bucket: the whole flat surface the face belongs to; Alt = just this face.
				var targets := [{brush = hit.brush, face = hit.face}] if event.alt_pressed \
					else LevelPaintTool.coplanar_region(hit.brush, hit.face)
				paint.fill_faces(hit.root, targets, erase)
			LevelPaintTool.Tool.SCATTER:
				if paint.scatter.items.is_empty() and not erase:
					push_warning("N64 Level Tools: add items to scatter first (Scatter section).")
				else:
					paint.scatter.begin(hit.root, hit.position, paint.size, erase)
			LevelPaintTool.Tool.GRADIENT:
				if paint.layer <= 0 or paint.layer > hit.root.data.active_layers().size():
					push_warning("N64 Level Tools: the gradient paints overlay layers: select (or add) one.")
					return AFTER_GUI_INPUT_STOP
				var targets := LevelGradientTool.targets_for(paint, hit.brush, hit.face)
				paint.gradient.begin(hit.root, targets, paint.layer - 1, paint.strength, erase)
				_grad = {root = hit.root, start = hit.position, normal = hit.normal, screen = mouse_pos, dragged = false, targets = targets,
					basis = camera.global_transform.basis}
				# A click: the preset direction across the faces (a drag replaces it).
				var ends := LevelGradientTool.fit(hit.root, targets, paint.gradient.preset_axis(camera.global_transform.basis, hit.normal))
				paint.gradient.preview(ends[0], ends[1])
			LevelPaintTool.Tool.PLACE:
				paint.scatter.place_one(hit.root, hit.position, hit.normal, erase, maxf(paint.scatter.item_size, 0.5))
			LevelPaintTool.Tool.BORDER:
				if paint.layer <= 0 or paint.layer > hit.root.data.active_layers().size():
					push_warning("N64 Level Tools: Border paints an overlay layer: select (or add) one, e.g. bricks.")
					return AFTER_GUI_INPUT_STOP
				var region := _border_region(hit)
				if region.is_empty():
					push_warning("N64 Level Tools: Border: click a face inside the face mask.")
					return AFTER_GUI_INPUT_STOP
				if event.alt_pressed:
					# Alt+click an edge of the area: leave that side out (again: back in).
					var side := _side_near(camera, _border_outline(hit.root, region))
					if not side.is_empty():
						if paint.border_off.has(side.key):
							paint.border_off.erase(side.key)
						else:
							paint.border_off[side.key] = true
					update_overlays()
					return AFTER_GUI_INPUT_STOP
				var t0 := Time.get_ticks_msec()
				var n := paint.border_fill(hit.root, region, paint.border_width, erase)
				print("[N64 Level Tools] Border: %d of %d faces painted (%.1f m) in %d ms" % [n, region.size(), paint.border_width, Time.get_ticks_msec() - t0])
			LevelPaintTool.Tool.FILL_SAME:
				# Bucket: every connected face with the clicked face's base texture.
				paint.fill_faces(hit.root, LevelPaintTool.texture_region(hit.root, hit.brush, hit.face, paint.stay_on_brush), erase)
				_region_cache = {}
			LevelPaintTool.Tool.FILL_NORMAL:
				paint.clicked_normal = hit.normal
				if paint.uses_soft_fill():
					paint.fill_normal_soft(hit.root, erase)
				else:
					paint.fill_faces(hit.root, paint.faces_by_normal(hit.root), erase)
		update_overlays()
		return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS


## Turns the overlay textures of the face-mask faces a quarter turn (one undo step).
func _turn_mask_overlays() -> void:
	if paint.face_mask.is_empty():
		push_warning("N64 Level Tools: Turn overlay: Cmd/Ctrl+click faces to mask them first.")
		return
	var by_brush := {}
	for key in paint.face_mask:
		var brush: LevelBrush = key[0]
		if key[1] >= brush.get_face_count():
			continue
		if not by_brush.has(brush):
			by_brush[brush] = [[], []]
		by_brush[brush][0].append(key[1])
		by_brush[brush][1].append(brush.get_face_overlay_turns(key[1]) + 1)
	var ur := get_undo_redo()
	ur.create_action("Turn Overlay", UndoRedo.MERGE_DISABLE, level if _level_ok() else null)
	for brush: LevelBrush in by_brush:
		ur.add_do_property(brush, &"face_uv", brush.with_overlay_turns(by_brush[brush][0], by_brush[brush][1]))
		ur.add_undo_property(brush, &"face_uv", brush.face_uv)
	ur.commit_action()


## Editor-only hiding (H): the brushes stop drawing and can't be picked or painted, so
## what's behind them can be. Not saved; the bake and the game ignore it. Alt+H: show all.
func _hide_brushes(root: LevelRoot, brushes: Array) -> void:
	if root == null:
		return
	for b in brushes:
		root.set_brush_hidden(b, true)
	hover_brush = null
	print("[N64 Level Tools] Hidden %d brush(es) (%d hidden in %s). Alt+H shows them again." % [brushes.size(), root.hidden_count(), root.name])
	_refresh_status()


func _show_all_brushes() -> void:
	var n := 0
	for root in _scene_level_roots():
		n += root.hidden_count()
		root.show_all_brushes()
	if n > 0:
		print("[N64 Level Tools] Showing %d hidden brush(es)." % n)
	_refresh_status()


## Border tool region for a hit: the face mask (this level's part of it) when the hit face
## is in it, else nothing while a mask exists, else the hit face's flat surface.
func _border_region(hit: Dictionary) -> Array:
	if paint.face_mask.is_empty():
		return LevelPaintTool.coplanar_region(hit.brush, hit.face)
	if not paint.face_mask.has([hit.brush, hit.face]):
		return []
	var out := []
	for key in paint.face_mask:
		if hit.root.has_brush(key[0]) and key[1] < key[0].get_face_count():
			out.append({brush = key[0], face = key[1]})
	return out


## Gradient: the faces it covers and its direction (an arrow from 0 % to 100 % with the stops
## marked); while dragging, the dragged line.
func _draw_gradient_cursor(overlay: Control, camera: Camera3D, color: Color) -> void:
	var ends: Array
	if not _grad.is_empty():
		_show_fill_preview(_grad.root, _grad.targets, Color(color, 0.25), &"fill", true)
		ends = paint.gradient.gradient_ends()
	else:
		var key := [paint_hit.root, paint.face_mask.size(), paint.gradient.direction, camera.global_transform.basis]
		if _grad_hover.get("key") != key or not _grad_hover.members.has([paint_hit.brush, paint_hit.face]):
			var targets := LevelGradientTool.targets_for(paint, paint_hit.brush, paint_hit.face)
			var members := {}
			for t in targets:
				members[[t.brush, t.face]] = true
			if not paint.face_mask.is_empty() and not members.has([paint_hit.brush, paint_hit.face]):
				members[[paint_hit.brush, paint_hit.face]] = true  # anywhere: the mask is the target
			_grad_hover = {key = key, targets = targets, members = members,
				ends = LevelGradientTool.fit(paint_hit.root, targets, paint.gradient.preset_axis(camera.global_transform.basis, paint_hit.normal))}
		_show_fill_preview(paint_hit.root, _grad_hover.targets, Color(color, 0.35), &"fill", true)
		ends = _grad_hover.ends
	if ends.size() < 2:
		return
	var a: Vector3 = ends[0]
	var b: Vector3 = ends[1]
	var lift: Vector3 = (_grad.normal if not _grad.is_empty() else paint_hit.normal) * 0.02
	_line3d(overlay, camera, a + lift, b + lift, color, 2.0)
	# Arrow head at 100 %, ticks at the stops (shade = coverage).
	var dir := (b - a).normalized()
	var side := dir.cross(lift.normalized()) * minf(a.distance_to(b) * 0.05, 0.3)
	_line3d(overlay, camera, b + lift, b + lift - dir * side.length() * 1.5 + side, color, 2.0)
	_line3d(overlay, camera, b + lift, b + lift - dir * side.length() * 1.5 - side, color, 2.0)
	for st in paint.gradient.stops:
		var p := a.lerp(b, st.x) + lift
		_line3d(overlay, camera, p - side, p + side, Color(st.y, st.y, st.y), 3.0)
	if not camera.is_position_behind(b):
		_draw_label(overlay, camera.unproject_position(b) + Vector2(10, -10), "%s · %.1f m" % [
			"Drag" if _grad.get("dragged", false) else LevelGradientTool.DIR_NAMES[paint.gradient.direction], a.distance_to(b)])


## The options changed: redo the last gradient with them (a click is re-aimed along the new
## direction; a drag keeps its ends until a direction is picked).
func _reapply_gradient() -> void:
	var last := paint.gradient.last_gradient()
	if last.is_empty() or _grad_last.is_empty() or not _grad.is_empty():
		return
	var ends := [last.from, last.to]
	if not _grad_last.dragged:
		ends = LevelGradientTool.fit(last.root, last.targets, paint.gradient.preset_axis(_grad_last.basis, _grad_last.normal))
	paint.gradient.reapply(ends[0], ends[1])


func _hover_region() -> Array:
	# Moving within the region shows the same region: only leaving it recomputes (a big
	# ground's region takes tens of ms).
	var key := [paint_hit.root, paint.stay_on_brush]
	if _region_cache.get("key") != key or not _region_cache.members.has([paint_hit.brush, paint_hit.face]):
		var region := LevelPaintTool.texture_region(paint_hit.root, paint_hit.brush, paint_hit.face, paint.stay_on_brush)
		var members := {}
		for r in region:
			members[[r.brush, r.face]] = true
		_region_cache = {key = key, region = region, members = members}
	return _region_cache.region


## Scatter's "Make cover texture": the items sprinkled into a tileable texture, added as a
## new overlay layer (Mix) ready to paint.
func _make_scatter_cover(size: int) -> void:
	if paint.scatter.items.is_empty():
		push_warning("N64 Level Tools: add items to scatter first.")
		return
	if not _ensure_paint_level():
		return
	if level.data.active_layers().size() >= LevelData.MAX_LAYERS:
		push_warning("N64 Level Tools: an overlay set has at most %d layers." % LevelData.MAX_LAYERS)
		return
	var tex := ScatterCover.make(paint.scatter.items, size, 0.75 if size == 32 else 1.5, 6 if size == 32 else 14, 9 if size == 32 else 12,
		0, paint.scatter.edge_dark if paint.scatter.edge == ScatterSet.Edge.DARKEN else 1.0)
	if tex == null:
		return
	var layer := PaintLayer.new()
	layer.name = "Flower cover"
	layer.texture = tex
	layer.tile_size = (tex as N64Texture).world_size
	var list := level.data.active_layers().duplicate()
	list.append(layer)
	var owner := _layers_owner(level.data)
	var ur := get_undo_redo()
	ur.create_action("Add Cover Layer", UndoRedo.MERGE_DISABLE, level)
	ur.add_do_property(owner, &"layers", list)
	ur.add_undo_property(owner, &"layers", level.data.active_layers())
	ur.commit_action()
	print("[N64 Level Tools] Cover texture %s added as overlay layer %d." % [tex.resource_path, list.size()])


func _can_line(root: LevelRoot) -> bool:
	return paint.line_from != null and paint.line_root == root and is_instance_valid(root) \
		and paint.tool in [LevelPaintTool.Tool.BRUSH, LevelPaintTool.Tool.ERASE]


## Brush / Erase, Alt+click: a straight stroke from where the last one ended to the cursor,
## straight on screen and laid on the surfaces under it (so it follows the ground rather
## than cutting through it). One undo step; the line's end is where the next one starts.
func _paint_line(camera: Camera3D, root: LevelRoot) -> void:
	var start: Vector3 = paint.line_from
	var held: LevelBrush = paint.line_brush if paint.stay_on_brush and root.has_brush(paint.line_brush) else null
	var points := PackedVector3Array()
	if camera.is_position_behind(start):
		# Start is behind the view: straight through space instead.
		var end_hit := _pick_brush(camera, mouse_pos, root, held) if held else _pick(camera, mouse_pos)
		if end_hit.is_empty():
			return
		points.append(end_hit.position)
	else:
		var a := camera.unproject_position(start)
		var steps := maxi(ceili(a.distance_to(mouse_pos) / 4.0), 1)
		for i in range(1, steps + 1):
			var p := a.lerp(mouse_pos, float(i) / steps)
			var h := _pick_brush(camera, p, root, held) if held else _pick(camera, p)
			if not h.is_empty() and h.root == root:
				points.append(h.position)
	if points.is_empty():
		return
	paint.begin_stroke(root, start, held, false)
	for p in points:
		paint.stroke_to(p)
	paint.stamp_end(points[points.size() - 1])
	paint.end_stroke()


## Eyedropper: the face under `hit` gives the base texture, offset, scale and rotation
## to paint with (and switches to the base layer).
func _pick_face_texture(hit: Dictionary) -> void:
	if hit.is_empty():
		return
	if hit.root != level:
		_select_level(hit.root)
	if not paint.pick_face(hit.root, hit.brush, hit.face):
		_pick_note = ["No texture on that face", Time.get_ticks_msec()]
		update_overlays()
		return
	# The face's overlay set becomes the edited one (its layers fill the list).
	var face_set: int = hit.brush.get_face_layer_set(hit.face)
	if face_set != level.data.edit_set:
		_select_layer_set(face_set)
	if paint.layer != 0:
		panel.paint_panel._select_layer(0, true)
	panel.paint_panel.set_tool_state(paint)
	var uv: Vector4 = paint.picked_uv
	var name := paint.base_texture.resource_path.get_file().get_basename() if paint.base_texture.resource_path != "" else "texture"
	var bits := PackedStringArray([name])
	if paint.rotation != 0.0:
		bits.append("%d°" % roundi(paint.rotation))
	if not is_equal_approx(absf(uv.z), 1.0):
		bits.append("×%s" % snappedf(absf(uv.z), 0.01))
	if LevelBrush.uv_follows_slope(uv):
		bits.append("follows slope")
	if not Vector2(uv.x, uv.y).is_zero_approx():
		bits.append("offset %s, %s" % [snappedf(uv.x, 0.01), snappedf(uv.y, 0.01)])
	if face_set != 0:
		bits.append("set %s" % level.data.layer_set_name(face_set))
	_pick_note = ["Picked " + " · ".join(bits), Time.get_ticks_msec()]
	update_overlays()


## A over a face: turns and shifts its base texture (and its overlays, dropping any border
## slant) so the texture's rows run along the face edge nearest the cursor, starting at that
## edge with the image's top pointing into the face (`flip`: the other way). Face-mask faces too when the hovered one is masked,
## all lined up on the same world edge. Any angle (stored in the face UV's rotation).
func _align_base_to_edge(hit: Dictionary, flip: bool) -> void:
	if hit.is_empty():
		return
	if hit.root != level:
		_select_level(hit.root)
	var root: LevelRoot = hit.root
	var brush: LevelBrush = hit.brush
	var xf := root.brush_global_transform(brush)
	var lp: Vector3 = xf.affine_inverse() * hit.position
	var ids := brush.get_face_vertex_ids(hit.face)
	var best := -1
	var best_d := INF
	for k in ids.size():
		var a := brush.vertices[ids[k]]
		var b := brush.vertices[ids[(k + 1) % ids.size()]]
		var d := lp.distance_to(Geometry3D.get_closest_point_to_segment(lp, a, b))
		if d < best_d:
			best_d = d
			best = k
	var wa := xf * brush.vertices[ids[best]]
	var wb := xf * brush.vertices[ids[(best + 1) % ids.size()]]
	var centre := Vector3.ZERO
	for i in ids:
		centre += xf * brush.vertices[i]
	centre /= ids.size()
	var foot := Geometry3D.get_closest_point_to_segment_uncapped(centre, wa, wb)
	var inward := centre - foot
	var targets := [{brush = brush, face = hit.face}]
	if paint.face_mask.has([brush, hit.face]):
		targets = _mask_targets()
	var by_brush := {}
	for t in targets:
		var b: LevelBrush = t.brush
		var inv := root.brush_global_transform(b).affine_inverse()
		var aligned = LevelBrush.uv_aligned_to_edge(b.get_face_uv(t.face), b.get_face_normal(t.face), inv * wa, inv * wb,
			inv * foot, inv * (foot + inward), flip)
		if aligned == null:
			continue  # the edge runs along this face's normal: nothing to line up
		if not by_brush.has(b):
			by_brush[b] = b.face_uv.duplicate()
		var uv: PackedVector4Array = by_brush[b]
		while uv.size() <= t.face:
			uv.append(LevelBrush.DEFAULT_UV)
		uv[t.face] = aligned
	if by_brush.is_empty():
		return
	var ur := get_undo_redo()
	ur.create_action("Align Texture To Edge", UndoRedo.MERGE_DISABLE, root)
	for b: LevelBrush in by_brush:
		ur.add_do_property(b, &"face_uv", by_brush[b])
		ur.add_undo_property(b, &"face_uv", b.face_uv)
	ur.commit_action()
	_pick_note = ["Texture lined up with that edge%s · %d face%s" % [" (flipped)" if flip else "", targets.size(),
		"" if targets.size() == 1 else "s"], Time.get_ticks_msec()]
	update_overlays()


# --- Sculpt ---------------------------------------------------------------------------

func _sculpt_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventKey:
		if event.pressed and event.keycode in [KEY_BRACKETLEFT, KEY_BRACKETRIGHT]:
			sculpt.radius = clampf(sculpt.radius * (0.8 if event.keycode == KEY_BRACKETLEFT else 1.25), 0.25, 16.0)
			panel.sculpt_panel.set_tool_state(sculpt)
			update_overlays()
			return AFTER_GUI_INPUT_STOP
		return AFTER_GUI_INPUT_PASS
	if event is InputEventMouseMotion:
		sculpt_hit = _pick(camera, mouse_pos)
		if sculpt.is_stroking() and sculpt_hit:
			sculpt.stroke_to(sculpt_hit.position)
		update_overlays()
		return AFTER_GUI_INPUT_STOP if sculpt.is_stroking() else AFTER_GUI_INPUT_PASS
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			if sculpt.is_stroking():
				sculpt.end_stroke()
				_refresh_status()
			return AFTER_GUI_INPUT_STOP
		var hit := _pick(camera, mouse_pos)
		if hit.is_empty():
			return AFTER_GUI_INPUT_PASS
		if hit.root != level:
			_select_level(hit.root)
		if event.is_command_or_control_pressed():  # pick the target height
			sculpt.height = snappedf(hit.position.y, 0.01)
			panel.sculpt_panel.set_tool_state(sculpt)
			update_overlays()
			return AFTER_GUI_INPUT_STOP
		sculpt.begin_stroke(hit.root, hit.position, event.shift_pressed)
		update_overlays()
		return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS


func _draw_sculpt_cursor(overlay: Control, camera: Camera3D) -> void:
	if sculpt_hit.is_empty():
		return
	var center: Vector3 = sculpt_hit.position
	var lower := (sculpt.tool == LevelSculptTool.Tool.LOWER) != Input.is_key_pressed(KEY_SHIFT)
	var color := Color(1.0, 0.55, 0.4) if lower and sculpt.tool <= LevelSculptTool.Tool.LOWER else Color(0.55, 1.0, 0.55)
	# Radius ring, flat on the brush plane (top-down distance).
	var prev := Vector3.ZERO
	for i in 49:
		var a := TAU * i / 48.0
		var p := center + Vector3(cos(a), 0.0, sin(a)) * sculpt.radius
		if i > 0:
			_line3d(overlay, camera, prev, p, color, 2.0)
		prev = p
	# Affected vertices, dot size = weight.
	for h in sculpt.affected(sculpt_hit.root, center):
		var w: Vector3 = h.world
		if camera.is_position_behind(w):
			continue
		overlay.draw_circle(camera.unproject_position(w), 1.5 + 3.5 * h.weight, Color(color, 0.35 + 0.6 * h.weight))
	if sculpt.tool == LevelSculptTool.Tool.HEIGHT:
		var target := Vector3(center.x, sculpt.height, center.z)
		_line3d(overlay, camera, center, target, Color(0.5, 0.8, 1.0), 1.5)
	var label: String = LevelSculptTool.TOOL_NAMES[sculpt.tool]
	if sculpt.tool == LevelSculptTool.Tool.HEIGHT:
		label += " %.2fm" % sculpt.height
	_draw_label(overlay, mouse_pos + Vector2(18, 18), "%s · r %.2fm · y %.2f" % [label, sculpt.radius, center.y])


func _select_level(root: LevelRoot) -> void:
	_set_level(root)
	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(root)


func _sync_paint_panel() -> void:
	if panel and panel.paint_panel:
		if _level_ok():
			level.data.edit_set = clampi(level.data.edit_set, 0, level.data.layer_set_count() - 1)
			paint.layer_set = level.data.edit_set
		panel.paint_panel.set_data(level.data if _level_ok() else null)
		_refresh_mask_sets()
		panel.paint_panel.set_scatter_state(paint.scatter)
		panel.paint_panel.set_gradient_state(paint.gradient)


func _on_paint_brush_changed(property: StringName, value: Variant) -> void:
	if String(property).begins_with("gradient_"):
		paint.gradient.set(String(property).trim_prefix("gradient_"), value)
		_grad_hover = {}
		if property == &"gradient_direction" and not _grad_last.is_empty():
			_grad_last.dragged = false  # picking a direction overrides a drag's ends
		_reapply_gradient()
		update_overlays()
		return
	if String(property).begins_with("scatter_"):
		var key := String(property).trim_prefix("scatter_")
		if key == "items":
			paint.scatter.items.assign(value)
		else:
			paint.scatter.set(key, value)
		if key in ["edge", "edge_dark"] and _level_ok():
			# The listed items already placed follow (one undo step).
			var sets := level.data.scatter.filter(func(s): return s and paint.scatter.items.has(s.texture) and s.get(key) != value)
			if not sets.is_empty():
				var ur := get_undo_redo()
				ur.create_action("Scatter Edge", UndoRedo.MERGE_ENDS, level)
				for s in sets:
					ur.add_do_property(s, StringName(key), value)
					ur.add_undo_property(s, StringName(key), s.get(key))
				ur.commit_action()
		update_overlays()
		return
	if property == &"shape":
		paint.shape = Image.load_from_file(value) if value != "" else null
		if paint.shape:
			paint.shape.convert(Image.FORMAT_RGBA8)
	else:
		paint.set(property, value)
	update_overlays()


## Paint panel actions with no active level: use the edited scene's level.
func _ensure_paint_level() -> bool:
	if not _level_ok():
		var root := _target_level_root()
		if root:
			_set_level(root)
			_sync_paint_panel()
	return _level_ok()


func _add_paint_layer() -> void:
	if not _ensure_paint_level():
		push_warning("N64 Level Tools: click a level surface (or select a LevelRoot) first.")
		return
	var data := level.data
	if data.active_layers().size() >= LevelData.MAX_LAYERS:
		push_warning("N64 Level Tools: an overlay set has at most %d layers." % LevelData.MAX_LAYERS)
		return
	var layer := PaintLayer.new()
	layer.name = "Overlay %d" % (data.active_layers().size() + 1)
	var list := data.active_layers().duplicate()
	list.append(layer)
	var owner := _layers_owner(data)
	var ur := get_undo_redo()
	ur.create_action("Add Paint Layer", UndoRedo.MERGE_DISABLE, level)
	ur.add_do_property(owner, &"layers", list)
	ur.add_undo_property(owner, &"layers", data.active_layers())
	ur.commit_action()


## What holds the edited overlay set's layer list (LevelData for the default set, else its
## PaintLayerSet): undo / redo set its `layers`.
func _layers_owner(data: LevelData) -> Resource:
	var s := data.edit_set
	if s > 0 and s <= data.layer_sets.size() and data.layer_sets[s - 1]:
		return data.layer_sets[s - 1]
	return data


## New overlay set (empty), made the edited one.
func _add_layer_set() -> void:
	if not _ensure_paint_level():
		push_warning("N64 Level Tools: click a level surface (or select a LevelRoot) first.")
		return
	var data := level.data
	var ls := PaintLayerSet.new()
	ls.name = "Set %d" % data.layer_set_count()
	var list := data.layer_sets.duplicate()
	list.append(ls)
	var ur := get_undo_redo()
	ur.create_action("Add Overlay Set", UndoRedo.MERGE_DISABLE, level)
	ur.add_do_property(data, &"layer_sets", list)
	ur.add_undo_property(data, &"layer_sets", data.layer_sets)
	ur.commit_action()
	_select_layer_set(data.layer_set_count() - 1)


## The Paint panel edits (and overlay painting reaches) set `s`.
func _select_layer_set(s: int) -> void:
	if not _ensure_paint_level():
		return
	level.data.edit_set = clampi(s, 0, level.data.layer_set_count() - 1)
	paint.layer_set = level.data.edit_set
	if paint.layer > level.data.active_layers().size():
		paint.layer = 0
	_sync_paint_panel()
	_refresh_status()
	update_overlays()


func _rename_layer_set(new_name: String) -> void:
	if not _ensure_paint_level() or new_name.strip_edges().is_empty():
		return
	var data := level.data
	var owner: Object = data if data.edit_set == 0 else _layers_owner(data)
	var property := &"default_set_name" if owner == data else &"name"
	var ur := get_undo_redo()
	ur.create_action("Rename Overlay Set", UndoRedo.MERGE_DISABLE, level)
	ur.add_do_property(owner, property, new_name.strip_edges())
	ur.add_undo_property(owner, property, owner.get(property))
	ur.add_do_method(self, &"_sync_paint_panel")
	ur.add_undo_method(self, &"_sync_paint_panel")
	ur.commit_action()


## "Assign to masked": the face-mask faces use the edited overlay set. Their painted slots
## stay (slot i now shows this set's layer i).
func _assign_layer_set() -> void:
	if not _ensure_paint_level():
		return
	if paint.face_mask.is_empty():
		push_warning("N64 Level Tools: mask the faces first (%s+click or %s+drag)." % [MOD, MOD])
		return
	var s := level.data.edit_set
	var by_brush := {}
	for key in paint.face_mask:
		if is_instance_valid(key[0]) and level.has_brush(key[0]) and key[1] < key[0].get_face_count():
			by_brush.get_or_add(key[0], []).append(key[1])
	var ur := get_undo_redo()
	ur.create_action("Assign Overlay Set", UndoRedo.MERGE_DISABLE, level)
	var count := 0
	for brush: LevelBrush in by_brush:
		var sets := brush.with_face_layer_sets(by_brush[brush], s)
		count += by_brush[brush].size()
		if sets != brush.face_layer_sets:
			ur.add_do_property(brush, &"face_layer_sets", sets)
			ur.add_undo_property(brush, &"face_layer_sets", brush.face_layer_sets)
	ur.add_do_method(self, &"_refresh_mask_sets")
	ur.add_undo_method(self, &"_refresh_mask_sets")
	ur.commit_action()
	print("[N64 Level Tools] %d faces now use overlay set \"%s\"." % [count, level.data.layer_set_name(s)])


## Copy of the edited overlay set (its layers duplicated, textures shared), made the edited one.
func _duplicate_layer_set() -> void:
	if not _ensure_paint_level():
		return
	var data := level.data
	var ls := PaintLayerSet.new()
	ls.name = "%s copy" % data.layer_set_name(data.edit_set)
	var copies: Array[PaintLayer] = []
	for layer in data.active_layers():
		copies.append(layer.duplicate() if layer else null)
	ls.layers = copies
	var list := data.layer_sets.duplicate()
	list.append(ls)
	var ur := get_undo_redo()
	ur.create_action("Duplicate Overlay Set", UndoRedo.MERGE_DISABLE, level)
	ur.add_do_property(data, &"layer_sets", list)
	ur.add_undo_property(data, &"layer_sets", data.layer_sets)
	ur.commit_action()
	_select_layer_set(data.layer_set_count() - 1)


## Deletes the edited overlay set (not Default): its faces go back to Default and lose the
## overlay paint made for it; later sets move down one. One undo step.
func _delete_layer_set() -> void:
	if not _ensure_paint_level():
		return
	var data := level.data
	var gone := data.edit_set
	if gone <= 0:
		push_warning("N64 Level Tools: the Default overlay set can't be deleted.")
		return
	var list := data.layer_sets.duplicate()
	list.remove_at(gone - 1)
	var ur := get_undo_redo()
	ur.create_action("Delete Overlay Set", UndoRedo.MERGE_DISABLE, level)
	ur.add_do_property(data, &"layer_sets", list)
	ur.add_undo_property(data, &"layer_sets", data.layer_sets)
	var faces := 0
	for brush in data.brushes:
		if brush == null or brush.face_layer_sets.is_empty():
			continue
		var sets := brush.face_layer_sets.duplicate()
		var dropped := {}
		for f in sets.size():
			if sets[f] == gone:
				sets[f] = 0
				dropped[f] = true
			elif sets[f] > gone:
				sets[f] -= 1
		if sets == brush.face_layer_sets:
			continue
		faces += dropped.size()
		ur.add_do_property(brush, &"face_layer_sets", sets)
		ur.add_undo_property(brush, &"face_layer_sets", brush.face_layer_sets)
		if not dropped.is_empty():
			var masks := {}
			for key: Vector2i in brush.face_masks:
				if not dropped.has(key.x):
					masks[key] = brush.face_masks[key]
			if masks.size() != brush.face_masks.size():
				ur.add_do_property(brush, &"face_masks", masks)
				ur.add_undo_property(brush, &"face_masks", brush.face_masks)
	ur.add_do_property(data, &"edit_set", 0)
	ur.add_undo_property(data, &"edit_set", gone)
	ur.add_do_method(self, &"_sync_paint_panel")
	ur.add_undo_method(self, &"_sync_paint_panel")
	ur.commit_action()
	print("[N64 Level Tools] Deleted overlay set %d; %d faces went back to %s." % [gone, faces, data.layer_set_name(0)])


## Moves the edited overlay set up (-1) / down (+1) the list (Default stays first).
func _move_layer_set(dir: int) -> void:
	if not _ensure_paint_level():
		return
	var data := level.data
	var a := data.edit_set
	var b := a + dir
	if a <= 0 or b <= 0 or b >= data.layer_set_count():
		return
	var list := data.layer_sets.duplicate()
	var t = list[a - 1]
	list[a - 1] = list[b - 1]
	list[b - 1] = t
	var ur := get_undo_redo()
	ur.create_action("Move Overlay Set", UndoRedo.MERGE_DISABLE, level)
	ur.add_do_property(data, &"layer_sets", list)
	ur.add_undo_property(data, &"layer_sets", data.layer_sets)
	for brush in data.brushes:
		if brush == null or brush.face_layer_sets.is_empty():
			continue
		var sets := brush.face_layer_sets.duplicate()
		for f in sets.size():
			if sets[f] == a:
				sets[f] = b
			elif sets[f] == b:
				sets[f] = a
		if sets != brush.face_layer_sets:
			ur.add_do_property(brush, &"face_layer_sets", sets)
			ur.add_undo_property(brush, &"face_layer_sets", brush.face_layer_sets)
	ur.add_do_property(data, &"edit_set", b)
	ur.add_undo_property(data, &"edit_set", a)
	ur.add_do_method(self, &"_sync_paint_panel")
	ur.add_undo_method(self, &"_sync_paint_panel")
	ur.commit_action()


## Paint panel: which overlay sets the face-mask faces use ("Mixed: …" when several).
func _refresh_mask_sets() -> void:
	if not _level_ok() or panel == null:
		return
	var used := {}
	for key in paint.face_mask:
		if is_instance_valid(key[0]) and key[1] < key[0].get_face_count():
			used[key[0].get_face_layer_set(key[1])] = true
	var names := []
	var ids := used.keys()
	ids.sort()
	for s in ids:
		names.append(level.data.layer_set_name(s))
	panel.paint_panel.set_mask_sets(names)


## Removing a layer shifts the masks of the layers above it down one slot.
## Clears overlay layer `index`'s paint on the face-mask faces, or the whole level without a
## mask (one undo step).
func _clear_paint_layer(index: int) -> void:
	if not _ensure_paint_level() or index < 0 or index >= level.data.active_layers().size():
		return
	var s := level.data.edit_set
	var ur := get_undo_redo()
	ur.create_action("Clear Paint Layer", UndoRedo.MERGE_DISABLE, level)
	var faces := 0
	for brush in level.data.brushes:
		if brush == null or brush.face_masks.is_empty():
			continue
		var masks := {}
		for key: Vector2i in brush.face_masks:
			if key.y == index and brush.get_face_layer_set(key.x) == s \
					and (paint.face_mask.is_empty() or paint.face_mask.has([brush, key.x])):
				faces += 1
			else:
				masks[key] = brush.face_masks[key]
		if masks.size() != brush.face_masks.size():
			ur.add_do_property(brush, &"face_masks", masks)
			ur.add_undo_property(brush, &"face_masks", brush.face_masks)
	ur.commit_action()
	print("[N64 Level Tools] Cleared layer %d (%s) on %d faces%s." % [index + 1, level.data.active_layers()[index].name, faces,
		" (face mask)" if not paint.face_mask.is_empty() else ""])


## "Reset faces": the face-mask faces lose every overlay layer's paint, their overlay
## turns / border frames, painted vertex colour and surface override (one undo step).
## Base texture and UV stay.
func _reset_mask_faces() -> void:
	if not _ensure_paint_level():
		return
	if paint.face_mask.is_empty():
		push_warning("N64 Level Tools: mask the faces to reset first (%s+click or %s+drag)." % [MOD, MOD])
		return
	var by_brush := {}
	for key in paint.face_mask:
		if is_instance_valid(key[0]) and level.has_brush(key[0]):
			by_brush.get_or_add(key[0], []).append(key[1])
	var ur := get_undo_redo()
	ur.create_action("Reset Faces", UndoRedo.MERGE_DISABLE, level)
	var count := 0
	for brush: LevelBrush in by_brush:
		var faces: Array = by_brush[brush].filter(func(f): return f < brush.get_face_count())
		count += faces.size()
		var chosen := {}
		for f in faces:
			chosen[f] = true
		var masks := {}
		for key: Vector2i in brush.face_masks:
			if not chosen.has(key.x):
				masks[key] = brush.face_masks[key]
		if masks.size() != brush.face_masks.size():
			ur.add_do_property(brush, &"face_masks", masks)
			ur.add_undo_property(brush, &"face_masks", brush.face_masks)
		var codes := []
		codes.resize(faces.size())
		codes.fill(0)
		var uv := brush.with_overlay_codes(faces, codes)
		if uv != brush.face_uv:
			ur.add_do_property(brush, &"face_uv", uv)
			ur.add_undo_property(brush, &"face_uv", brush.face_uv)
		var surfaces := brush.face_surfaces.duplicate()
		for f in faces:
			if f < surfaces.size():
				surfaces[f] = 0
		if surfaces != brush.face_surfaces:
			ur.add_do_property(brush, &"face_surfaces", surfaces)
			ur.add_undo_property(brush, &"face_surfaces", brush.face_surfaces)
		if brush.corner_colors.size() == brush.face_indices.size() and not brush.corner_colors.is_empty():
			var corners := brush.corner_colors.duplicate()
			for f in faces:
				var start := brush.get_face_start(f)
				for k in brush.face_counts[f]:
					corners[start + k] = Color.WHITE
			if corners != brush.corner_colors:
				ur.add_do_property(brush, &"corner_colors", corners)
				ur.add_undo_property(brush, &"corner_colors", brush.corner_colors)
		elif not brush.vertex_colors.is_empty():
			# Per-vertex colour only: shared with the neighbours, which fade to white here too.
			var colors := brush.vertex_colors.duplicate()
			for f in faces:
				for i in brush.get_face_vertex_ids(f):
					if i < colors.size():
						colors[i] = Color.WHITE
			if colors != brush.vertex_colors:
				ur.add_do_property(brush, &"vertex_colors", colors)
				ur.add_undo_property(brush, &"vertex_colors", brush.vertex_colors)
	ur.commit_action()
	print("[N64 Level Tools] Reset %d faces to their base texture." % count)


## "Merge faces": joins the face-mask faces that touch, lie in one plane and match (one
## undo step; the brushes are recorded whole). Blender set pieces are left alone.
func _merge_mask_faces() -> void:
	if not _ensure_paint_level():
		return
	if paint.face_mask.is_empty():
		push_warning("N64 Level Tools: mask the faces to merge first (%s+click or %s+drag)." % [MOD, MOD])
		return
	var by_brush := {}
	for key in paint.face_mask:
		var b = key[0]
		if is_instance_valid(b) and level.has_brush(b) and b.blend_file == "" and key[1] < b.get_face_count():
			by_brush.get_or_add(b, []).append(key[1])
	var ur := get_undo_redo()
	ur.create_action("Merge Faces", UndoRedo.MERGE_DISABLE, level)
	var before_count := 0
	var after_count := 0
	for brush: LevelBrush in by_brush:
		var before := brush.snapshot()
		var n := brush.get_face_count()
		var map := brush.merge_faces(by_brush[brush], level.data.mask_density)
		if map.is_empty():
			continue
		before_count += n
		after_count += brush.get_face_count()
		paint._remap_face_mask(brush, map)
		var after := brush.snapshot()
		for key in after:
			ur.add_do_property(brush, key, after[key])
			ur.add_undo_property(brush, key, before[key])
	ur.commit_action()
	_show_mask()
	_refresh_status()
	update_overlays()
	if before_count == after_count:
		print("[N64 Level Tools] Nothing to merge: masked faces must touch, lie in one plane and match.")
	else:
		print("[N64 Level Tools] Merged faces: %d -> %d." % [before_count, after_count])


func _remove_paint_layer(index: int) -> void:
	if not _ensure_paint_level() or index < 0 or index >= level.data.active_layers().size():
		return
	var data := level.data
	var list := data.active_layers().duplicate()
	list.remove_at(index)
	var owner := _layers_owner(data)
	var ur := get_undo_redo()
	ur.create_action("Remove Paint Layer", UndoRedo.MERGE_DISABLE, level)
	ur.add_do_property(owner, &"layers", list)
	ur.add_undo_property(owner, &"layers", data.active_layers())
	# Only faces of this set: other sets' slots keep their meaning.
	for brush in data.brushes:
		if brush == null or brush.face_masks.is_empty():
			continue
		var masks := {}
		for key in brush.face_masks:
			if brush.get_face_layer_set(key.x) != data.edit_set or key.y < index:
				masks[key] = brush.face_masks[key]
			elif key.y > index:
				masks[Vector2i(key.x, key.y - 1)] = brush.face_masks[key]
		ur.add_do_property(brush, &"face_masks", masks)
		ur.add_undo_property(brush, &"face_masks", brush.face_masks)
	ur.commit_action()


func _set_layer_property(index: int, property: StringName, value: Variant) -> void:
	if not _ensure_paint_level() or index >= level.data.active_layers().size():
		return
	var layer: PaintLayer = level.data.active_layers()[index]
	var ur := get_undo_redo()
	ur.create_action("Edit Paint Layer", UndoRedo.MERGE_ENDS, level)
	ur.add_do_property(layer, property, value)
	ur.add_undo_property(layer, property, layer.get(property))
	if property == &"texture" and value is N64Texture:
		# Adopt the texture's own world size as the layer's tile size.
		ur.add_do_property(layer, &"tile_size", value.metres_per_repeat())
		ur.add_undo_property(layer, &"tile_size", layer.tile_size)
	ur.commit_action()


## Editor preview of Baked Timed lighting at an hour.
## Editor-driven shader globals: debug grid = snap size, baked-light blend = preview hour.
func _apply_editor_globals() -> void:
	_store_grid_setting()
	RenderingServer.global_shader_parameter_set(GRID_PARAM, snap)
	_set_preview_hour(float(EditorInterface.get_editor_settings().get_project_metadata(SETTINGS_SECTION, "preview_hour", 12.0)))


## Godot reloads shader globals from project settings at times we don't get told about
## (editor startup, settings edits), so keep the stored value equal to the snap size.
func _store_grid_setting() -> void:
	var key := "shader_globals/" + String(GRID_PARAM)
	var current = ProjectSettings.get_setting(key)
	if current is Dictionary and is_equal_approx(float(current.get("value", 0.0)), snap):
		return
	ProjectSettings.set_setting(key, {"type": "float", "value": snap})


func _on_project_settings_changed() -> void:
	# Godot's own reload of the globals runs on the same signal; apply after it.
	_apply_editor_globals.call_deferred()
	# Texel density changed: Auto-sized textures change size, so refresh the levels.
	var density := N64Texture.texels_per_metre()
	if density != _last_density:
		_last_density = density
		for root in _scene_level_roots():
			if root.data:
				root.data.paint_changed.emit()
		if panel:
			panel.paint_panel.refresh()


func _set_preview_hour(hour: float) -> void:
	EditorInterface.get_editor_settings().set_project_metadata(SETTINGS_SECTION, "preview_hour", hour)
	var schedule := LightingSchedule.load_project()
	if schedule:
		var b := schedule.blend_for(hour)
		var value := Vector4(b.x, b.y, b.z, 0.0)
		RenderingServer.global_shader_parameter_set(BLEND_PARAM, value)
		# Godot reloads shader globals from project settings (editor startup, settings
		# edits): store the preview blend there too, or Baked Timed levels fall back to the
		# first key (midnight) and their unlit sides go black. The game sets it every frame.
		var key := "shader_globals/" + String(BLEND_PARAM)
		var current = ProjectSettings.get_setting(key)
		if not (current is Dictionary and current.get("value") == value):
			ProjectSettings.set_setting(key, {"type": "vec4", "value": value})


func _set_paint_level_property(property: StringName, value: Variant) -> void:
	if property == &"preview_hour":
		_set_preview_hour(value)
		return
	if property == FILTER_PARAM:
		# Project-wide shader global: applies now and is saved to project.godot.
		RenderingServer.global_shader_parameter_set(FILTER_PARAM, value)
		ProjectSettings.set_setting("shader_globals/n64_three_point", {type = "bool", value = value})
		ProjectSettings.save()
		return
	if not _ensure_paint_level():
		return
	var ur := get_undo_redo()
	ur.create_action("Edit Level Paint", UndoRedo.MERGE_ENDS, level)
	ur.add_do_property(level.data, property, value)
	ur.add_undo_property(level.data, property, level.data.get(property))
	ur.commit_action()
	if property == &"light_ao_strength" or property == &"light_ao_radius":
		_queue_vertex_ao_rebake()


## AO strength / radius edited in the inspector (LevelData > Lighting) re-bake too.
func _on_inspector_property_edited(property: String) -> void:
	if (property == "light_ao_strength" or property == "light_ao_radius" or property == "light_ao_samples") \
			and EditorInterface.get_inspector().get_edited_object() is LevelData:
		_queue_vertex_ao_rebake()
		panel.paint_panel.refresh()
	# A texture's own settings (World size, anti-tiling, tint, …): levels using it refresh
	# their preview materials (the game picks it up at the next bake).
	var edited := EditorInterface.get_inspector().get_edited_object()
	if edited is Texture2D:
		var refreshed := false
		for root in _scene_level_roots():
			if root.data and _level_uses_texture(root.data, edited):
				root.data.paint_changed.emit()
				refreshed = true
		if refreshed:
			panel.paint_panel.refresh()


func _level_uses_texture(data: LevelData, tex: Texture2D) -> bool:
	for t in data.textures:
		if t == tex or (t is N64StairTexture and t.base == tex) or (t is TextureLook and t.texture == tex):
			return true
	for s in data.layer_set_count():
		for layer in data.layers_of(s):
			if layer and (layer.texture == tex or layer.noise_base == tex):
				return true
	return false


## Live AO tweaking: re-bake existing vertex AO shortly after the settings stop changing.
func _queue_vertex_ao_rebake() -> void:
	if not _level_ok() or not level.data.brushes.any(func(b): return b and not b.vertex_ao.is_empty()):
		return
	if _ao_timer == null:
		_ao_timer = Timer.new()
		_ao_timer.one_shot = true
		_ao_timer.wait_time = 0.35
		_ao_timer.timeout.connect(func(): _bake_vertex_ao(false, true))
		add_child(_ao_timer)
	_ao_timer.start()


func _add_custom_brush() -> void:
	if _brush_dialog == null:
		_brush_dialog = EditorFileDialog.new()
		_brush_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILES
		_brush_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_brush_dialog.title = "Add brush images (greyscale, white paints)"
		for ext in ["png", "jpg", "jpeg", "webp"]:
			_brush_dialog.add_filter("*." + ext)
		_brush_dialog.files_selected.connect(_on_brush_files)
		EditorInterface.get_base_control().add_child(_brush_dialog)
	_brush_dialog.popup_file_dialog()


func _on_brush_files(paths: PackedStringArray) -> void:
	var dir: String = panel.paint_panel.BRUSH_DIR
	DirAccess.make_dir_recursive_absolute(dir)
	for path in paths:
		var img := Image.load_from_file(path)
		if img == null:
			continue
		var longest := maxi(img.get_width(), img.get_height())
		if longest > 128:
			img.resize(maxi(1, img.get_width() * 128 / longest), maxi(1, img.get_height() * 128 / longest), Image.INTERPOLATE_LANCZOS)
		img.save_png("%s/%s.png" % [dir, N64TextureConverter.clean_name(path.get_file())])
	EditorInterface.get_resource_filesystem().scan()
	panel.paint_panel.reload_brushes()


func _draw_paint_cursor(overlay: Control, camera: Camera3D) -> void:
	_show_mask()
	_show_set_faces()
	_show_surfaces()
	if _mask_box:
		var rect := Rect2(_mask_from, Vector2.ZERO).expand(mouse_pos)
		var removing := Input.is_key_pressed(KEY_SHIFT)
		var col := Color(1.0, 0.45, 0.4) if removing else MASK_COLOR
		overlay.draw_rect(rect, Color(col, 0.12))
		overlay.draw_rect(rect, col, false, 1.0)
		_hide_fill_preview()
		_draw_label(overlay, mouse_pos + Vector2(18, 18), "%s mask (box) · %d faces" % ["Remove from" if removing else "Add to", paint.face_mask.size()])
		return
	if paint_hit.is_empty():
		_hide_fill_preview()
		return
	if Input.is_key_pressed(KEY_META if OS.get_name() == "macOS" else KEY_CTRL) or _mask_drag != 0:
		# Editing the mask: preview the face (Alt: its flat region) it would add / remove.
		var masked := paint.face_mask.has([paint_hit.brush, paint_hit.face])
		var adding := _mask_drag > 0 or (_mask_drag == 0 and not masked)
		_show_fill_preview(paint_hit.root, LevelPaintTool.coplanar_region(paint_hit.brush, paint_hit.face)
			if Input.is_key_pressed(KEY_ALT) else [{brush = paint_hit.brush, face = paint_hit.face}],
			MASK_COLOR if adding else Color(1.0, 0.45, 0.4))
		_draw_label(overlay, mouse_pos + Vector2(18, 18), "%s mask · %d faces" % ["Add to" if adding else "Remove from", paint.face_mask.size()])
		return
	var one := [{brush = paint_hit.brush, face = paint_hit.face}]
	if _picking:
		_show_fill_preview(paint_hit.root, one, Color(1.0, 0.85, 0.35))
		_draw_label(overlay, mouse_pos + Vector2(18, 18), "Pick: click a face")
		return
	var color := Color(1.0, 0.45, 0.4) if Input.is_key_pressed(KEY_SHIFT) or paint.tool == LevelPaintTool.Tool.ERASE else Color(0.55, 1.0, 0.55)
	match paint.tool:
		LevelPaintTool.Tool.FACE:
			_show_fill_preview(paint_hit.root, one, color)
		LevelPaintTool.Tool.FILL_FACE:
			_show_fill_preview(paint_hit.root, one if Input.is_key_pressed(KEY_ALT)
				else LevelPaintTool.coplanar_region(paint_hit.brush, paint_hit.face), color)
		LevelPaintTool.Tool.FILL_SAME:
			_show_fill_preview(paint_hit.root, _hover_region(), color)
		LevelPaintTool.Tool.GRADIENT:
			_draw_gradient_cursor(overlay, camera, color)
		LevelPaintTool.Tool.BORDER:
			var region := _border_region(paint_hit)
			_show_fill_preview(paint_hit.root, region, color)
			_draw_border_sides(overlay, camera, _border_outline(paint_hit.root, region))
		LevelPaintTool.Tool.PLACE:
			_hide_fill_preview()
			var n: Vector3 = paint_hit.normal
			var t1 := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
			var t2 := n.cross(t1)
			var r := maxf(paint.scatter.item_size * 0.5, 0.05)
			var prev := Vector3.ZERO
			for i in 17:
				var a := TAU * i / 16.0
				var p: Vector3 = paint_hit.position + n * 0.01 + (t1 * cos(a) + t2 * sin(a)) * r
				if i > 0:
					_line3d(overlay, camera, prev, p, color, 2.0)
				prev = p
			_line3d(overlay, camera, paint_hit.position, paint_hit.position + Vector3.UP * paint.scatter.item_size, color, 2.0)
		LevelPaintTool.Tool.FILL_NORMAL:
			paint.clicked_normal = paint_hit.normal
			_show_fill_preview(paint_hit.root, paint.faces_by_normal(paint_hit.root,
				paint.soft_edge * 0.5 if paint.uses_soft_fill() else 0.0), Color(color, 0.7))
		_:
			_hide_fill_preview()
			var n: Vector3 = paint_hit.normal
			var t1 := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
			var t2 := n.cross(t1)
			var center: Vector3 = paint_hit.position + n * 0.01
			var prev := Vector3.ZERO
			for i in 33:
				var a := TAU * i / 32.0
				var p := center + (t1 * cos(a) + t2 * sin(a)) * paint.size
				if i > 0:
					_line3d(overlay, camera, prev, p, color, 2.0)
				prev = p
			if paint.hardness < 0.9:
				for i in 33:
					var a := TAU * i / 32.0
					var p := center + (t1 * cos(a) + t2 * sin(a)) * paint.size * maxf(paint.hardness, 0.05)
					if i > 0:
						_line3d(overlay, camera, prev, p, Color(color, 0.4), 1.0)
					prev = p
	var lining := Input.is_key_pressed(KEY_ALT) and _can_line(paint_hit.root) and not camera.is_position_behind(paint.line_from)
	if lining:
		var a := camera.unproject_position(paint.line_from)
		overlay.draw_line(a, mouse_pos, Color(color, 0.85), 2.0)
		overlay.draw_circle(a, 4.0, color)
	var label := "Vertex colour" if paint.layer == LevelPaintTool.VERTEX_LAYER else ("Base" if paint.layer == 0 else "Layer %d" % paint.layer)
	if paint.layer == LevelPaintTool.SURFACE_LAYER:
		label = "Surface: " + Surface.describe(LevelSurfaces.face(paint_hit.root.data, paint_hit.brush, paint_hit.face))
	if lining:
		label = "Line · " + label
	if paint.layer == 0 and paint.rotation != 0.0:
		label += " %d°" % roundi(paint.rotation)
	if paint.layer == 0 and paint.has_picked_uv():
		label += " (picked UV)"
	if not paint.face_mask.is_empty():
		label += " · mask %d" % paint.face_mask.size()
	var text := "%s · %s · %.2fm" % [label, LevelPaintTool.TOOL_NAMES[paint.tool], paint.size]
	if _picking:
		text = "Pick: click a face"
	elif Time.get_ticks_msec() - _pick_note[1] < 2000:
		text = _pick_note[0]
	_draw_label(overlay, mouse_pos + Vector2(18, 18), text)


## Shows `targets` ([{brush, face}] of `root`) filled translucent with their outline, in
## the scene (depth tested). Rebuilt only when the faces or colour change.
## `cells`: also every face's own edges (dimmer), so the faces read as a grid.
func _show_fill_preview(root: LevelRoot, targets: Array, color: Color, slot := &"fill", cells := false) -> void:
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null:
		return
	var entry: Array = _previews.get(slot, [null, 0])
	var mi: MeshInstance3D = entry[0] if is_instance_valid(entry[0]) else null
	if mi == null or mi.get_parent() != scene:
		_hide_fill_preview(slot)
		mi = MeshInstance3D.new()
		mi.name = "_Preview_%s" % slot
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.vertex_color_use_as_albedo = true
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.render_priority = 10
		mi.material_override = mat
		mi.mesh = ImmediateMesh.new()
		scene.add_child(mi, false, Node.INTERNAL_MODE_BACK)
		entry = [mi, 0]
		_previews[slot] = entry
	var key := hash([root.get_instance_id(), targets.map(func(t): return [t.brush.get_instance_id(), t.face]), color, cells])
	mi.visible = true
	if key == entry[1]:
		return
	entry[1] = key
	var im: ImmediateMesh = mi.mesh
	im.clear_surfaces()
	if targets.is_empty():
		return
	# Lifted off the surface a little so it doesn't z-fight with the faces it covers.
	var lift_by := 0.01 if slot == &"fill" else 0.006
	var fill := Color(color, color.a * 0.3)
	var edges := {}  # [brush, a, b] (a < b) -> [p, q, count]
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for t in targets:
		var b: LevelBrush = t.brush
		var xf := root.brush_global_transform(b)
		var ids := b.get_face_vertex_ids(t.face)
		var lift := (xf.basis.inverse().transposed() * b.get_face_normal(t.face)).normalized() * lift_by
		var pts := PackedVector3Array()
		for i in ids:
			pts.append(xf * b.vertices[i] + lift)
		for k in range(1, pts.size() - 1):
			for p in [pts[0], pts[k], pts[k + 1]]:
				im.surface_set_color(fill)
				im.surface_add_vertex(p)
		for k in ids.size():
			var a := ids[k]
			var c := ids[(k + 1) % ids.size()]
			var e := [b, mini(a, c), maxi(a, c)]
			if edges.has(e):
				edges[e][2] += 1
			else:
				edges[e] = [pts[k], pts[(k + 1) % pts.size()], 1]
	im.surface_end()
	# Outline: edges of only one target face (the region's border; `cells`: every cell, dimmer).
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for e in edges.values():
		if e[2] == 1 or cells:
			for p in [e[0], e[1]]:
				im.surface_set_color(Color(color, 1.0 if e[2] == 1 else 0.45))
				im.surface_add_vertex(p)
	im.surface_end()


func _hide_fill_preview(slot := &"fill") -> void:
	var entry: Array = _previews.get(slot, [null, 0])
	if is_instance_valid(entry[0]):
		entry[0].queue_free()
	_previews.erase(slot)


## The paint face mask as preview targets (faces still on their brush in `level`).
func _mask_targets() -> Array:
	var out := []
	if not _level_ok():
		return out
	for key in paint.face_mask:
		var b: LevelBrush = key[0]
		if is_instance_valid(b) and level.has_brush(b) and key[1] < b.get_face_count():
			out.append({brush = b, face = key[1]})
	return out


## Surface layer: every face of the level tinted by the surface it bakes (Surface.color),
## rebuilt when a brush or the level's textures / layers change.
func _show_surfaces() -> void:
	if paint.layer != LevelPaintTool.SURFACE_LAYER or not _level_ok():
		_hide_fill_preview(&"surfaces")
		return
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null:
		return
	var entry: Array = _previews.get(&"surfaces", [null, 0])
	var mi: MeshInstance3D = entry[0] if is_instance_valid(entry[0]) else null
	if mi == null or mi.get_parent() != scene:
		_hide_fill_preview(&"surfaces")
		mi = MeshInstance3D.new()
		mi.name = "_Preview_surfaces"
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.vertex_color_use_as_albedo = true
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.render_priority = 9
		mi.material_override = mat
		mi.mesh = ImmediateMesh.new()
		scene.add_child(mi, false, Node.INTERNAL_MODE_BACK)
		entry = [mi, 0]
		_previews[&"surfaces"] = entry
	var key := level.data.surface_signature()
	if key == entry[1]:
		return
	entry[1] = key
	var im: ImmediateMesh = mi.mesh
	im.clear_surfaces()
	var tris := PackedVector3Array()
	var cols := PackedColorArray()
	for b: LevelBrush in level.data.brushes:
		if b == null or b.bake_mode == LevelBrush.BakeMode.VISUAL_ONLY:
			continue
		var xf := level.brush_global_transform(b)
		var surfs := LevelSurfaces.brush_faces(level.data, b)
		for f in b.get_face_count():
			var c := Surface.color(surfs[f])
			c.a = 0.45
			var ids := b.get_face_vertex_ids(f)
			var lift := (xf.basis.inverse().transposed() * b.get_face_normal(f)).normalized() * 0.008
			for k in range(1, ids.size() - 1):
				for i in [ids[0], ids[k], ids[k + 1]]:
					tris.append(xf * b.vertices[i] + lift)
					cols.append(c)
	if tris.is_empty():
		return
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in tris.size():
		im.surface_set_color(cols[i])
		im.surface_add_vertex(tris[i])
	im.surface_end()


func _show_mask() -> void:
	if paint.face_mask.is_empty() or not _level_ok():
		_hide_fill_preview(&"mask")
	else:
		_show_fill_preview(level, _mask_targets(), MASK_COLOR, &"mask")


## Cache for _show_set_faces: [key, targets].
var _set_faces_cache := []


## While masking (Cmd/Ctrl held or a mask drag) in a level with several overlay sets: the
## edited set's faces in orange, or, editing Default, the faces of other sets in grey.
func _show_set_faces() -> void:
	var masking := Input.is_key_pressed(KEY_META if OS.get_name() == "macOS" else KEY_CTRL) or _mask_drag != 0
	if not masking or not _level_ok() or level.data.layer_set_count() < 2:
		_hide_fill_preview(&"sets")
		return
	var s := level.data.edit_set
	var key := [level, s, level.data.brushes.map(func(b): return b.face_layer_sets if b else null)].hash()
	if _set_faces_cache.is_empty() or _set_faces_cache[0] != key:
		var targets := []
		for b: LevelBrush in level.data.brushes:
			if b == null or level.is_brush_hidden(b) or (s == 0 and b.face_layer_sets.is_empty()):
				continue
			for f in b.get_face_count():
				var fs := b.get_face_layer_set(f)
				if (fs == s) if s > 0 else (fs != 0):
					targets.append({brush = b, face = f})
		_set_faces_cache = [key, targets]
	if _set_faces_cache[1].is_empty():
		_hide_fill_preview(&"sets")
	else:
		_show_fill_preview(level, _set_faces_cache[1], SET_COLOR if s > 0 else OTHER_SET_COLOR, &"sets")


## Adds (on) or removes faces of the mask.
## Faces of the edited level facing the camera whose centre lies in a screen rect (hidden
## faces count too: no occlusion test, the editor's raycast is too slow for thousands).
func _faces_in_box(camera: Camera3D, rect: Rect2) -> Array:
	var out := []
	if not _level_ok():
		return out
	var cam := camera.global_position
	var ortho := camera.projection == Camera3D.PROJECTION_ORTHOGONAL
	var fwd := -camera.global_basis.z
	for brush in level.data.brushes:
		if brush == null or level.is_brush_hidden(brush):
			continue
		var xf := level.brush_global_transform(brush)
		var nb := xf.basis.inverse().transposed()
		for f in brush.get_face_count():
			var pts := brush.get_face_points(f)
			var c := Vector3.ZERO
			for p in pts:
				c += p
			c = xf * (c / maxf(pts.size(), 1))
			if camera.is_position_behind(c) or not rect.has_point(camera.unproject_position(c)):
				continue
			var n := (nb * brush.get_face_normal(f))
			if n.dot(-fwd if ortho else cam - c) <= 0.0:
				continue
			out.append({brush = brush, face = f})
	return out


## Border tool outline of an area: {segs, sides} (cached while the area stays the same).
var _outline_cache := {}


func _border_outline(root: LevelRoot, region: Array) -> Dictionary:
	if region.is_empty():
		return {segs = [], sides = []}
	var key := [root, region.size(), region[0].brush, region[0].face, region[-1].face, region[0].brush.get_face_count(),
		paint.face_mask.size()]
	if _outline_cache.get("key") != key:
		var segs := LevelPaintTool.border_segments(root, region)
		_outline_cache = {key = key, segs = segs, sides = LevelPaintTool.border_sides(segs)}
	return _outline_cache


## The side whose edge passes within a few pixels of the cursor ({} = none).
func _side_near(camera: Camera3D, outline: Dictionary) -> Dictionary:
	var best := {}
	var best_d := 12.0 * EditorInterface.get_editor_scale()
	for side: Dictionary in outline.get("sides", []):
		for i: int in side.segs:
			var seg: Array = outline.segs[i]
			if camera.is_position_behind(seg[0]) or camera.is_position_behind(seg[1]):
				continue
			var d := mouse_pos.distance_to(Geometry2D.get_closest_point_to_segment(mouse_pos,
				camera.unproject_position(seg[0]), camera.unproject_position(seg[1])))
			if d < best_d:
				best_d = d
				best = side
	return best


## Border tool: the area's sides, bright when the band runs there, dim red when left out;
## with Alt held, the one an Alt+click would toggle.
func _draw_border_sides(overlay: Control, camera: Camera3D, outline: Dictionary) -> void:
	var hover := _side_near(camera, outline) if Input.is_key_pressed(KEY_ALT) else {}
	for side: Dictionary in outline.get("sides", []):
		var off := paint.border_off.has(side.key)
		var col := Color(1.0, 0.45, 0.4, 0.7) if off else Color(0.45, 1.0, 0.55)
		var w := 1.5 if off else 3.0
		if not hover.is_empty() and hover.key == side.key:
			col = Color.WHITE
			w = 4.0
		for i: int in side.segs:
			_line3d(overlay, camera, outline.segs[i][0], outline.segs[i][1], col, w)
	if Input.is_key_pressed(KEY_ALT):
		_draw_label(overlay, mouse_pos + Vector2(18, 34), "Alt+click an edge: side on / off")


func _set_mask(targets: Array, on: bool) -> void:
	paint.border_off.clear()  # sides belong to the old outline
	for t in targets:
		if on:
			paint.face_mask[[t.brush, t.face]] = true
		else:
			paint.face_mask.erase([t.brush, t.face])
	_show_mask()  # now, not on the next overlay draw (the 3D view may not redraw until later)
	_refresh_mask_sets()
	_refresh_status()


## Esc in Paint mode, one thing at a time: cancel a gradient drag, else stop picking, else
## clear the face mask. Always finishes a stroke still open (its release went elsewhere)
## and drops a half-done mask click / box, so the next click paints normally.
func _paint_escape() -> void:
	if paint.is_stroking():
		paint.end_stroke()
	if paint.scatter.is_stroking():
		paint.scatter.end()
	if _paint_saved_tool >= 0:
		paint.tool = _paint_saved_tool
		_paint_saved_tool = -1
		panel.paint_panel.set_tool_state(paint)
	_mask_drag = 0
	_mask_box = false
	_mask_click = {}
	if not _grad.is_empty():
		paint.gradient.cancel()
		_grad = {}
	elif _picking:
		_picking = false
	elif not paint.face_mask.is_empty():
		_clear_mask()
	_refresh_status()
	update_overlays()


## Esc: empties the face mask and drops any half-done mask click / box.
func _clear_mask() -> void:
	paint.face_mask.clear()
	paint.border_off.clear()
	_mask_drag = 0
	_mask_box = false
	_mask_click = {}
	_show_mask()
	_refresh_mask_sets()
	_refresh_status()
	update_overlays()


func _outline_face(overlay: Control, camera: Camera3D, root: LevelRoot, brush: LevelBrush, face: int, color: Color) -> void:
	var xf := root.brush_global_transform(brush)
	var ids := brush.get_face_vertex_ids(face)
	for k in ids.size():
		_line3d(overlay, camera, xf * brush.vertices[ids[k]], xf * brush.vertices[ids[(k + 1) % ids.size()]], color, 2.0)


# --- Picking helpers ----------------------------------------------------------------

func _gizmo_length(camera: Camera3D, at: Vector3) -> float:
	var vp_height := camera.get_viewport().get_visible_rect().size.y
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return camera.size * GIZMO_PIXELS / vp_height
	var depth := (at - camera.global_position).dot(-camera.global_basis.z)
	return depth * tan(deg_to_rad(camera.fov) * 0.5) * 2.0 * GIZMO_PIXELS / vp_height


func _gizmo_at(camera: Camera3D, pos: Vector2) -> Drag:
	var center = _gizmo_center()
	if center == null or camera.is_position_behind(center):
		return Drag.NONE
	var cs := camera.unproject_position(center)
	if pos.distance_to(cs) < 9.0:
		return Drag.PLANE_XZ
	var best := Drag.NONE
	var best_d := 7.0
	var length := _gizmo_length(camera, center)
	for a in 3:
		var tip: Vector3 = center + AXES[a] * length
		if camera.is_position_behind(tip):
			continue
		var d := Geometry2D.get_closest_point_to_segment(pos, cs, camera.unproject_position(tip)).distance_to(pos)
		if d < best_d:
			best_d = d
			best = (Drag.AXIS_X + a) as Drag
	return best


func _vertex_at(camera: Camera3D, pos: Vector2) -> int:
	var b := _active()
	var xf := _bxf(b)
	var best := -1
	var best_d := PICK_RADIUS
	for i in b.vertices.size():
		var w := xf * b.vertices[i]
		if camera.is_position_behind(w):
			continue
		var d := camera.unproject_position(w).distance_to(pos)
		if d < best_d:
			best_d = d
			best = i
	return best


func _edge_at(camera: Camera3D, pos: Vector2) -> Vector2i:
	var b := _active()
	var xf := _bxf(b)
	var best := Vector2i(-1, -1)
	var best_d := PICK_RADIUS * 0.8
	for e in b.get_edges():
		var wa := xf * b.vertices[e.x]
		var wb := xf * b.vertices[e.y]
		if camera.is_position_behind(wa) or camera.is_position_behind(wb):
			continue
		var d := Geometry2D.get_closest_point_to_segment(pos, camera.unproject_position(wa), camera.unproject_position(wb)).distance_to(pos)
		if d < best_d:
			best_d = d
			best = e
	return best


func _scene_level_roots() -> Array[LevelRoot]:
	var out: Array[LevelRoot] = []
	var root := EditorInterface.get_edited_scene_root()
	if root:
		_collect_level_roots(root, out)
	return out


func _collect_level_roots(node: Node, out: Array[LevelRoot]) -> void:
	if node is LevelRoot:
		out.append(node)
	for child in node.get_children():
		_collect_level_roots(child, out)


## Nearest brush hit under the mouse across all LevelRoots: {root, brush, face, position, normal, distance}.
func _pick(camera: Camera3D, pos: Vector2) -> Dictionary:
	return _ray_scene(camera.project_ray_origin(pos), camera.project_ray_normal(pos))


## `both_sides`: back faces too (from inside a wall, its far face).
## `_pick` against one brush only (seeing through the others).
func _pick_brush(camera: Camera3D, pos: Vector2, root: LevelRoot, brush: LevelBrush) -> Dictionary:
	if root == null or not root.has_brush(brush):
		return {}
	var from := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var xf := root.brush_global_transform(brush)
	var inv := xf.affine_inverse()
	var hit := brush.raycast_local(inv * from, inv.basis * dir)
	if hit.is_empty():
		return {}
	return {root = root, brush = brush, face = hit.face, position = xf * hit.position,
		normal = (xf.basis.inverse().transposed() * hit.normal).normalized(), distance = hit.distance}


func _ray_scene(from: Vector3, dir: Vector3, both_sides := false) -> Dictionary:
	var best := {}
	for root in _scene_level_roots():
		if not root.is_visible_in_tree():
			continue
		var hit := root.raycast(from, dir, both_sides)
		if hit and (best.is_empty() or hit.distance < best.distance):
			best = hit
			best.root = root
	return best


func _is_external(res: Resource) -> bool:
	return not res.resource_path.is_empty() and not res.resource_path.contains("::")


## The active LevelRoot, else the first one in the edited scene.
func _target_level_root() -> LevelRoot:
	if _level_ok():
		return level
	var roots := _scene_level_roots()
	return roots[0] if roots.size() > 0 else null


# --- Placement ----------------------------------------------------------------------

func _update_ghost(camera: Camera3D) -> void:
	if place_shape == PASSAGE_TOOL:
		_update_passage_ghost(camera)
		return
	if place_shape == DOOR_TOOL:
		_update_door_ghost(camera)
		return
	var hit := _pick(camera, mouse_pos)
	var p: Vector3
	var n := Vector3.UP
	if hit:
		p = hit.position
		n = hit.normal
	else:
		var from := camera.project_ray_origin(mouse_pos)
		var g = Plane(Vector3.UP, 0.0).intersects_ray(from, camera.project_ray_normal(mouse_pos))
		if g == null:
			ghost_valid = false
			return
		p = g
	var size := _placed_size()
	if n.y < -0.7:
		p.y -= size.y
	elif n.y <= 0.7:
		if absf(n.x) > absf(n.z):
			p.x += signf(n.x) * size.x * 0.5
		else:
			p.z += signf(n.z) * size.z * 0.5
	ghost_base = p.snapped(Vector3.ONE * snap)
	ghost_valid = true


## Passage ghost: on a wall it opens outward through the wall at the floor height below;
## on a floor it opens in the camera's facing direction (snapped to 90°).
func _update_passage_ghost(camera: Camera3D) -> void:
	var hit := _pick(camera, mouse_pos)
	var outward := -camera.global_basis.z
	var p: Vector3
	var floor_hit := {}
	ghost_wall = {}
	if hit and absf(hit.normal.y) < 0.5:
		outward = -hit.normal
		p = hit.position
		floor_hit = _ray_scene(p + hit.normal * 0.3 + Vector3.UP * 0.05, Vector3.DOWN)
		p.y = floor_hit.position.y if floor_hit else 0.0
		ghost_wall = {root = hit.root, normal = hit.normal, point = hit.position, brush = hit.brush, face = hit.face}
	elif hit:
		p = hit.position
		floor_hit = hit
	else:
		var g = Plane(Vector3.UP, 0.0).intersects_ray(camera.project_ray_origin(mouse_pos), camera.project_ray_normal(mouse_pos))
		if g == null:
			ghost_valid = false
			return
		p = g
	outward.y = 0.0
	if outward.length_squared() < 1e-6:
		outward = Vector3.FORWARD
	ghost_basis = Basis.looking_at(_dominant_axis(outward), Vector3.UP)
	ghost_base = p.snapped(Vector3.ONE * snap)
	if not ghost_wall.is_empty():
		# Keep the opening on the wall: snap along it, not off its plane.
		var n: Vector3 = ghost_wall.normal
		n.y = 0.0
		n = n.normalized()
		ghost_base -= n * n.dot(ghost_base - ghost_wall.point)
	ghost_floor = {brush = floor_hit.brush, face = floor_hit.face} if floor_hit else {}
	ghost_root = floor_hit.root if floor_hit else (hit.root if hit else null)
	ghost_material = floor_hit.brush.material if floor_hit else null
	ghost_valid = true


## Door ghost: needs a wall. Sits at the floor height, centred in the wall's thickness
## (between this face and the next room's wall behind it, when there is one), +Z facing
## the side that was clicked.
func _update_door_ghost(camera: Camera3D) -> void:
	var hit := _pick(camera, mouse_pos)
	if hit.is_empty() or absf(hit.normal.y) >= 0.5:
		ghost_valid = false
		return
	if door_mode == 1 or hit.brush.blend_file != "":
		_update_door_between(hit)
		return
	# Recess with no insets on a solid wall (a face behind): cut through it and stand the door
	# in the gap, as between faces; otherwise it'd sit hidden inside the wall, nothing cut.
	if _door_inset(door_inset_front) + _door_inset(door_inset_back) <= 0.0:
		var thick := _ray_scene(hit.position - hit.normal.normalized() * 0.01, -Vector3(hit.normal.x, 0, hit.normal.z).normalized(), true)
		if thick and thick.distance < 3.0:
			_update_door_between(hit)
			return
	var n := _dominant_axis(Vector3(hit.normal.x, 0, hit.normal.z))
	var p: Vector3 = hit.position
	var floor_hit := _ray_scene(p + n * 0.3 + Vector3.UP * 0.05, Vector3.DOWN)
	p.y = floor_hit.position.y if floor_hit else 0.0
	var behind := _ray_scene(hit.position - n * 0.01, -n)
	var wall_depth := 0.25
	ghost_other_root = null
	if behind and behind.distance < 2.0:
		wall_depth = behind.distance + 0.01
		ghost_other_root = behind.root
	# Between two rooms: centre in the wall. Otherwise (zone door): on the wall face, so
	# opening it reveals the dark doorway instead of the inside of the wall.
	var joins_rooms := _room_of(ghost_other_root) != null and _room_of(ghost_other_root) != _room_of(hit.root)
	var center := p - n * (wall_depth * 0.5) if joins_rooms else p + n * 0.08
	ghost_wall_depth = wall_depth
	# Wall centre along the door's +Z (towards the clicked side), for the dressing.
	ghost_wall_center = 0.0 if joins_rooms else -0.08 - wall_depth * 0.5
	ghost_base = center.snapped(Vector3.ONE * snap)
	if absf(n.x) > 0.5:
		ghost_base.x = center.x
	else:
		ghost_base.z = center.z
	ghost_base.y = p.y
	ghost_basis = Basis.looking_at(-n, Vector3.UP)
	ghost_root = hit.root
	# Recess door: the opening starts on the clicked face (snapped along the wall only).
	var face := p.snapped(Vector3.ONE * snap)
	if absf(n.x) > 0.5:
		face.x = p.x
	else:
		face.z = p.z
	face.y = p.y
	ghost_door = {point = face, brush = hit.brush, face = hit.face, behind = behind.distance if behind else INF,
		floor = {brush = floor_hit.brush, face = floor_hit.face} if floor_hit else {}}
	ghost_valid = true


## Door between a wall's two faces (set pieces from Blender always): faces the clicked
## face's own way (not snapped to the axes) and stands `door_depth` % of the way from it
## to the face behind. When the wall has its doorway already (open below the cursor, with
## jambs and a lintel), the door fits it and nothing is built; otherwise placing cuts the
## opening through both faces and lines the gap (see _place_door_between).
func _update_door_between(hit: Dictionary) -> void:
	var n := Vector3(hit.normal.x, 0, hit.normal.z).normalized()
	var basis := Basis.looking_at(-n, Vector3.UP)
	var side := basis.x
	var p: Vector3 = hit.position
	var behind := _ray_scene(p - n * 0.01, -n, true)
	var depth: float = behind.distance + 0.01 if behind and behind.distance < 3.0 else 0.0
	var floor_hit := _ray_scene(p + n * 0.3 + Vector3.UP * 0.05, Vector3.DOWN)
	var base := p
	base.y = floor_hit.position.y if floor_hit else p.y
	var width := 1.2
	var height := 2.4
	var fit := false
	# Open at waist height under the cursor: the doorway.
	var waist := base + Vector3.UP * 1.0
	var through := _ray_scene(waist + n * 0.05, -n)
	if depth > 0.0 and (through.is_empty() or through.distance > depth + 0.1):
		var mid := waist - n * depth * 0.5
		var right := _ray_scene(mid, side)
		var left := _ray_scene(mid, -side)
		var up := _ray_scene(mid, Vector3.UP)
		var down := _ray_scene(mid, Vector3.DOWN)
		if right and left and up and right.distance + left.distance < 6.0 and up.distance < 6.0:
			fit = true
			width = right.distance + left.distance
			mid += side * (right.distance - left.distance) * 0.5
			if down and down.distance < 1.5:
				mid.y -= down.distance
			else:
				mid.y = base.y
			height = waist.y + up.distance - mid.y
			base = mid + n * depth * 0.5
	if not fit:
		base += side * (snappedf(side.dot(base), snap) - side.dot(base))
	var t := clampf(door_depth / 100.0, 0.0, 1.0)
	ghost_basis = basis
	ghost_base = base - n * depth * t
	ghost_root = hit.root
	ghost_other_root = behind.root if behind and depth > 0.0 else null
	ghost_wall_depth = depth
	ghost_wall_center = depth * (t - 0.5)
	ghost_door = {between = true, point = base, depth = depth, width = width, height = height, fit = fit,
		brush = hit.brush, face = hit.face, floor = {brush = floor_hit.brush, face = floor_hit.face} if floor_hit else {}}
	ghost_valid = true


func _place_door() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var root := ghost_root
	if root == null or root.data == null:
		push_warning("N64 Level Tools: doors go on level walls.")
		return
	if _door_recessed():
		_place_door_recess(scene_root)
		return
	if ghost_door.get("between", false) and not ghost_door.fit:
		_place_door_between(scene_root)
		return
	# On the wall's face (or fitted into a doorway that's already there): nothing cut.
	var spec := _new_door_spec(ghost_door.get("width", 1.2) if ghost_door.get("fit", false) else 1.2,
		ghost_door.get("height", 2.4) if ghost_door.get("fit", false) else 2.4)
	spec.wall_depth = ghost_wall_depth
	spec.wall_center_z = ghost_wall_center
	_set_door_rooms(spec, scene_root, _room_of(root), _room_of(ghost_other_root), false)
	_add_door_brush(root, Transform3D(ghost_basis, ghost_base), spec, false, [])


## Between faces, no doorway yet: cuts the door's opening through the wall's faces (on a
## set piece the brush keeps the cut and makes it again after every pull: the .blend
## stays as made), lines the gap between them (sides + top, the wall's texture; a floor)
## and puts the door `door_depth` % in. One undo step; deleting the door closes it.
func _place_door_between(scene_root: Node) -> void:
	var root := ghost_root
	var spec := _new_door_spec(ghost_door.width, ghost_door.height)
	spec.wall_depth = ghost_wall_depth
	spec.wall_center_z = ghost_wall_center
	_door_surfaces(spec, ghost_door.depth > 0.02)
	_set_door_rooms(spec, scene_root, _room_of(root), _room_of(ghost_other_root), false)
	_add_door_brush(root, Transform3D(ghost_basis, ghost_base), spec, true, [])


## A DoorSpec for a new door (id from a fresh tag; sizes on the grid).
func _new_door_spec(w: float, h: float) -> DoorSpec:
	var spec := DoorSpec.new()
	spec.width = w
	spec.height = h
	spec.door_id = StringName("door_%08x" % randi())
	return spec


## The lining's textures / colours from the wall and floor under the ghost (read before
## carving: cutting renumbers the wall's faces).
func _door_surfaces(spec: DoorSpec, lining: bool) -> void:
	spec.lining = lining
	var wall: LevelBrush = ghost_door.get("brush")
	if wall:
		var face: int = ghost_door.face
		spec.wall_texture = wall.get_face_texture(face)
		var wuv := wall.get_face_uv(face)
		spec.wall_uv = Vector4(wuv.x, wuv.y, wuv.z, fposmod(wuv.w, 360.0))
		spec.wall_color = PassageBuilder.face_color(wall, face)
	var floor_info: Dictionary = ghost_door.get("floor", {})
	var fb: LevelBrush = floor_info.get("brush")
	if fb:
		var ff: int = floor_info.get("face", 0)
		spec.floor_texture = fb.get_face_texture(ff)
		var fuv := fb.get_face_uv(ff)
		spec.floor_uv = Vector4(fuv.x, fuv.y, fuv.z, fposmod(fuv.w, 360.0))
		spec.floor_source_xf = fb.transform
		spec.floor_color = PassageBuilder.face_color(fb, ff)


## Room / zone mode from the rooms in front (+Z) and behind; rooms as paths from the
## scene's root. `grows`: the next room grows from this level (an in-level ROOM door).
func _set_door_rooms(spec: DoorSpec, scene_root: Node, front: Room, back: Room, grows: bool) -> void:
	if front and back and front != back:
		spec.mode = Door.Mode.ROOM
		spec.room_b = scene_root.get_path_to(front)
		spec.room_a = scene_root.get_path_to(back)
	elif grows:
		spec.mode = Door.Mode.ROOM
		if front:
			spec.room_b = scene_root.get_path_to(front)
	else:
		spec.mode = Door.Mode.ZONE
		if front:
			spec.arrival_room = scene_root.get_path_to(front)


## Adds a door brush at `world_xf` (where the panel hangs) to `root`; `cut`: carve the
## opening through the wall (its front face, wall_depth deep). `extra`: brushes built with
## it (next room's wall / floor; deleted with the door while untouched). One undo step.
func _add_door_brush(root: LevelRoot, world_xf: Transform3D, spec: DoorSpec, cut: bool, extra: Array[LevelBrush]) -> void:
	var b := LevelBrush.new()
	b.tag = spec.door_id
	b.hand_edited = true
	b.transform = root.global_transform.affine_inverse() * world_xf
	var carved := []
	if cut:
		var oxf := spec.opening_xf(b.transform)
		carved = PassageBuilder.carve_opening(root, root.global_transform * oxf, spec.width, spec.height,
			spec.carve_depth(), b.tag, spec.trim(), spec.shape())
		spec.mark_carved(oxf)
	for e in extra:
		spec.extra_hashes[e.tag] = _shape_hash(e)
	b.door = spec
	_passage_seen[b] = _passage_key(b)
	var ur := get_undo_redo()
	ur.create_action("Add Door", UndoRedo.MERGE_DISABLE, root)
	for c in carved:
		for key in c.after:
			ur.add_do_property(c.brush, key, c.after[key])
			ur.add_undo_property(c.brush, key, c.before[key])
	for nb in [b] + extra:
		ur.add_do_method(root.data, &"add_brush", nb)
		ur.add_do_reference(nb)
		ur.add_undo_method(root.data, &"remove_brush", nb)
	_refresh_cut_surroundings(ur, carved)
	ur.commit_action()
	_select_level(root)
	if mode != Mode.OBJECT:
		_set_mode(Mode.OBJECT)
	sel_brushes = [b]
	_inspect_active()
	update_overlays()
	_rebake_vertex_ao_if_used(root)
	print("[N64 Level Tools] Door added (a level brush): its rooms / zone, lock and look are in the inspector (Door). Delete removes it and closes the wall.")


## After cutting into / closing set pieces (`changed`: [{brush, ...}]): Blender's view of
## their door cuts follows (on do and undo).
func _refresh_cut_surroundings(ur: EditorUndoRedoManager, changed: Array) -> void:
	var files := {}
	for c in changed:
		if c.brush.blend_file != "":
			files[c.brush.blend_file] = true
	for file: String in files:
		ur.add_do_method(blender, &"refresh_surroundings", file)
		ur.add_undo_method(blender, &"refresh_surroundings", file)


func _door_recessed() -> bool:
	return _door_inset(door_inset_front) + _door_inset(door_inset_back) > 0.0 and not ghost_door.is_empty() \
		and not ghost_door.get("between", false)


## Insets snap to the grid (0 stays 0).
func _door_inset(v: float) -> float:
	return maxf(snappedf(v, snap), 0.0)


func _on_door_option(property: StringName, value: Variant) -> void:
	set(property, value)
	EditorInterface.get_editor_settings().set_project_metadata(SETTINGS_SECTION, String(property), value)
	update_overlays()


## Door in a passage: carves the wall, lines a tunnel (inset front + inset back deep) with
## the wall's texture and floor, sets the door `inset front` back from the wall face, and
## (when nothing is behind yet) builds the opposing wall with the doorway and a starter
## floor (door wide, 1 m deep) for the next room. One undo step.
func _place_door_recess(scene_root: Node) -> void:
	var root := ghost_root
	if root == null or root.data == null:
		return
	var spec := _new_door_spec(1.2, 2.4)
	var w := spec.width
	var h := spec.height
	var fi := _door_inset(door_inset_front)
	var bi := _door_inset(door_inset_back)
	var depth := fi + bi
	var face_xf := Transform3D(ghost_basis, ghost_door.point)
	var to_level := root.global_transform.affine_inverse()
	var wall_brush: LevelBrush = ghost_door.brush
	var wall_tex := wall_brush.get_face_texture(ghost_door.face)
	var floor_info: Dictionary = ghost_door.floor
	var floor_brush: LevelBrush = floor_info.get("brush")
	var floor_face: int = floor_info.get("face", 0)
	spec.wall_depth = depth
	spec.wall_center_z = (fi - bi) * 0.5
	_door_surfaces(spec, true)
	var extra: Array[LevelBrush] = []
	var grows: bool = door_build_room and ghost_door.behind > depth + 0.05
	if grows:
		var back_wall := PassageBuilder.doorway_wall(w, h, 1.0, 1.0, wall_brush, wall_tex)
		back_wall.transform = to_level * face_xf * Transform3D(Basis(), Vector3(0, 0, -depth))
		back_wall.tag = StringName(String(spec.door_id) + "_wall")
		extra.append(back_wall)
		var start := PassageBuilder.corridor_floor(w, 1.0, floor_brush, floor_face)
		start.transform = to_level * face_xf * Transform3D(Basis(), Vector3(0, 0, -depth - 0.5))
		start.tag = StringName(String(spec.door_id) + "_room")
		extra.append(start)
	var back := _room_of(ghost_other_root) if ghost_door.behind <= depth + 0.05 else null
	_set_door_rooms(spec, scene_root, _room_of(root), back, grows)
	_add_door_brush(root, face_xf * Transform3D(Basis(), Vector3(0, 0, -fi)), spec, true, extra)


func _room_of(node: Node) -> Room:
	while node and not node is Room:
		node = node.get_parent()
	return node as Room


func _place_passage() -> void:
	var root := ghost_root if ghost_root else _target_level_root()
	if root == null or root.data == null:
		push_warning("N64 Level Tools: place some level geometry before adding a passage.")
		return
	# A passage brush: the level builds its corridor and gameplay node (PassageSpec).
	var spec := PassageSpec.new()
	# Sizes in whole grid steps, and the sides on grid lines (axis-aligned walls).
	var step := maxf(snap, 0.25)
	spec.width = maxf(snappedf(spec.width, step), step)
	spec.height = maxf(snappedf(spec.height, step), step)
	spec.depth = maxf(snappedf(spec.depth, step), step)
	var side := ghost_basis.x.normalized()
	var origin := ghost_base
	var left := (origin - side * spec.width * 0.5).dot(side)
	origin += side * (snappedf(left, step) - left)
	var world_xf := Transform3D(ghost_basis, origin)
	var b := LevelBrush.new()
	b.tag = StringName("passage_%08x" % randi())
	b.hand_edited = true
	b.transform = root.global_transform.affine_inverse() * world_xf
	# The floor carries on into the corridor: its texture, its pattern lined up across.
	if not ghost_floor.is_empty():
		var src: LevelBrush = ghost_floor.brush
		spec.floor_texture = src.get_face_texture(ghost_floor.face)
		var fuv := src.get_face_uv(ghost_floor.face)
		spec.floor_uv = Vector4(fuv.x, fuv.y, fuv.z, fposmod(fuv.w, 360.0))
		spec.floor_source_xf = src.transform
		spec.floor_color = PassageBuilder.face_color(src, ghost_floor.face)
		var fs: Array = PassageBuilder.face_shades(src, ghost_floor.face)
		spec.floor_source_points = fs[0]
		spec.floor_source_shades = fs[1]
		b.material = src.material
	if b.material == null and spec.floor_texture < 0:
		b.material = ghost_material
	# On a wall: cut the opening; the corridor gets side walls + ceiling like the wall.
	var carved := []
	if not ghost_wall.is_empty() and ghost_wall.root == root:
		# Read the wall's texture before carving: cutting renumbers the wall's faces.
		spec.shell = true
		spec.wall_texture = ghost_wall.brush.get_face_texture(ghost_wall.face)
		var wuv: Vector4 = ghost_wall.brush.get_face_uv(ghost_wall.face)
		spec.wall_uv = Vector4(wuv.x, wuv.y, wuv.z, fposmod(wuv.w, 360.0))
		spec.wall_color = PassageBuilder.face_color(ghost_wall.brush, ghost_wall.face)
		carved = PassageBuilder.carve_opening(root, world_xf, spec.width, spec.height, 2.0, b.tag, spec.trim(), spec.shape())
		spec.carved = true
		spec.carved_width = spec.width
		spec.carved_height = spec.height
		spec.carved_trim = spec.trim()
		spec.carved_version = PassageBuilder.CARVE_VERSION
		spec.carved_xf = b.transform
	b.passage = spec
	_passage_seen[b] = _passage_key(b)
	# The room floor gets vertices along the threshold, matching the corridor floor's.
	carved.append_array(_cut_room_floor(root, b, world_xf, spec.width))

	var ur := get_undo_redo()
	ur.create_action("Add Passage", UndoRedo.MERGE_DISABLE, root)
	for c in carved:
		for key in c.after:
			ur.add_do_property(c.brush, key, c.after[key])
			ur.add_undo_property(c.brush, key, c.before[key])
	ur.add_do_method(root.data, &"add_brush", b)
	ur.add_do_reference(b)
	ur.add_undo_method(root.data, &"remove_brush", b)
	_refresh_cut_surroundings(ur, carved)
	ur.commit_action()
	_select_level(root)
	if mode != Mode.OBJECT:
		_set_mode(Mode.OBJECT)
	sel_brushes = [b]
	_inspect_active()
	update_overlays()
	_rebake_vertex_ao_if_used(root)
	print("[N64 Level Tools] Passage added: set its zone / spawn in the inspector (Passage). Delete removes it and closes the wall.")


## The room floor just inside a passage's threshold (the brush under it), cut along the
## corridor floor's cell lines (PassageBuilder.cut_threshold). [{brush, before, after}].
func _cut_room_floor(root: LevelRoot, b: LevelBrush, world_xf: Transform3D, width: float) -> Array:
	var probe := world_xf.origin + world_xf.basis.z.normalized() * 0.05 + Vector3.UP * 0.5
	var best := {}
	for other: LevelBrush in root.data.brushes:
		if other == null or other == b or other.is_passage() or other.is_door() or other.is_fence() or other.is_rope():
			continue
		var bxf := root.brush_global_transform(other)
		var inv := bxf.affine_inverse()
		var hit := other.raycast_local(inv * probe, (inv.basis * Vector3.DOWN).normalized())
		if hit and (best.is_empty() or hit.distance < best.distance):
			best = {brush = other, distance = hit.distance}
	if best.is_empty() or best.distance > 1.0:
		return []
	var cut := PassageBuilder.cut_threshold(root, best.brush, world_xf, width, maxi(roundi(width), 1))
	return [] if cut.is_empty() else [{brush = best.brush, before = cut.before, after = cut.after}]


## Passage brush -> its size / place last seen (_on_passage_changed: inspector edits, undo).
var _passage_seen := {}


func _passage_key(b: LevelBrush) -> Array:
	var spec := b.opening_spec()
	return [spec.opening_size(), spec.opening_xf(b.transform), spec.trim(), spec.shape()]


## A passage's / door's wall opening cut again where / as big as it is now (fill the old
## one, carve the new; applied now, recorded into `ur`). Returns the brushes changed.
func _recarve_passage(ur: EditorUndoRedoManager, root: LevelRoot, b: LevelBrush) -> Array:
	var p := b.opening_spec()
	if p == null:
		return []
	var oxf := p.opening_xf(b.transform)
	if not p.carved or p.carve_matches(oxf):
		return []
	var gx := root.global_transform
	var size := p.opening_size()
	var cuts: Array = PassageBuilder.fill_opening(root, gx * p.carved_xf, p.carved_width, p.carved_height, [b], b.tag, p.carved_shape) \
			+ PassageBuilder.carve_opening(root, gx * oxf, size.x, size.y, p.carve_depth(), b.tag, p.trim(), p.shape())
	if b.is_passage():
		cuts += _cut_room_floor(root, b, gx * oxf, size.x)
	var changes := {}  # brush -> [before, after]
	for c in cuts:
		if changes.has(c.brush):
			changes[c.brush][1] = c.after
		else:
			changes[c.brush] = [c.before, c.after]
	var out := []
	for brush: LevelBrush in changes:
		for key in changes[brush][1]:
			ur.add_do_property(brush, key, changes[brush][1][key])
			ur.add_undo_property(brush, key, changes[brush][0][key])
		out.append({brush = brush, before = changes[brush][0], after = changes[brush][1]})
	const CARVED := [&"carved_width", &"carved_height", &"carved_xf", &"carved_trim", &"carved_version", &"carved_shape"]
	for prop in CARVED:
		ur.add_undo_property(p, prop, p.get(prop))
	p.mark_carved(oxf)
	for prop in CARVED:
		ur.add_do_property(p, prop, p.get(prop))
	_passage_seen[b] = _passage_key(b)
	return out


## LevelRoot: a passage / door brush was rebuilt. When its size / place changed outside our
## own actions (inspector, undo), cut its opening again as a step of its own.
func _on_passage_changed(root: LevelRoot, b: LevelBrush) -> void:
	var p := b.opening_spec()
	if p == null:
		return
	var key := _passage_key(b)
	var seen = _passage_seen.get(b)
	_passage_seen[b] = key
	# First sight (scene opened): only a trim the wall wasn't cut for yet (older passages).
	if seen == null and p.carved and (not p.carved_trim.is_equal_approx(p.trim()) or p.stale_cut()
			or not p.carved_shape.is_equal_approx(p.shape())):
		seen = []
	if seen == null or seen == key or drag != Drag.NONE:
		return
	_recarve_deferred.call_deferred(root, b)


func _recarve_deferred(root: LevelRoot, b: LevelBrush) -> void:
	if not is_instance_valid(root) or not root.has_brush(b) or b.opening_spec() == null:
		return
	var p := b.opening_spec()
	if not p.carved or p.carve_matches(p.opening_xf(b.transform)):
		return  # already matches (e.g. an undo put both back)
	var ur := get_undo_redo()
	ur.create_action("Cut %s Opening" % ("Door" if b.is_door() else "Passage"), UndoRedo.MERGE_DISABLE, root)
	var changed := _recarve_passage(ur, root, b)
	_refresh_cut_surroundings(ur, changed)
	ur.commit_action(false)


## Door: rebuilt. A cut-through door whose width / height no longer match its opening gets
## it cut again (a step of its own, like passages).
func _on_door_changed(door: Door) -> void:
	if drag == Drag.NONE and _door_cut_stale(door):
		_recut_door_deferred.call_deferred(door)


func _door_cut_stale(door: Door) -> bool:
	return is_instance_valid(door) and door.is_inside_tree() and door.recess_tag != &"" and door.recess_hashes.is_empty() \
		and not door.cut_size.is_equal_approx(Vector2(door.width, door.height))


func _recut_door_deferred(door: Door) -> void:
	if not _door_cut_stale(door):
		return  # already matches (handled, or an undo put it back)
	var found := _door_target(door)
	var root: LevelRoot = found.root
	if root == null:
		return
	var rt := String(door.recess_tag)
	var shell: LevelBrush = null
	var gap_floor: LevelBrush = null
	for b: LevelBrush in found.brushes:
		if String(b.tag) == rt + "_shell":
			shell = b
		elif String(b.tag) == rt:
			gap_floor = b
	var old := door.cut_size
	if old == Vector2.ZERO:
		# Placed before sizes were recorded: the lining shows the opening's size.
		if shell == null:
			push_warning("N64 Level Tools: can't tell how big door '%s''s opening was; remove and place it again to resize the cut." % door.name)
			return
		var lo := Vector3.INF
		var hi := -Vector3.INF
		for v in shell.vertices:
			lo = lo.min(v)
			hi = hi.max(v)
		old = Vector2(hi.x - lo.x, hi.y)
	var w := door.width
	var h := door.height
	var depth := door.wall_depth
	var face_xf := door.global_transform * Transform3D(Basis(), Vector3(0, 0, door.wall_center_z + door.wall_depth * 0.5))
	var doomed: Array = []
	for b in [shell, gap_floor]:
		if b:
			doomed.append(b)
	var changes := {}  # brush -> [before, after]
	for c in PassageBuilder.fill_opening(root, face_xf, old.x, old.y, doomed, door.recess_tag) \
			+ PassageBuilder.carve_opening(root, face_xf, w, h, depth + 0.02, door.recess_tag):
		if changes.has(c.brush):
			changes[c.brush][1] = c.after
		else:
			changes[c.brush] = [c.before, c.after]
	var added: Array[LevelBrush] = []
	if shell:
		var ns := PassageBuilder.corridor_shell(root, face_xf, w, h, depth, shell, shell.get_face_texture(0))
		ns.tag = shell.tag
		added.append(ns)
	if gap_floor:
		var nf := PassageBuilder.corridor_floor(w, depth, gap_floor, 0)
		nf.tag = gap_floor.tag
		nf.transform = root.global_transform.affine_inverse() * face_xf * Transform3D(Basis(), Vector3(0, 0, -depth * 0.5))
		added.append(nf)
	var ur := get_undo_redo()
	ur.create_action("Cut Door Opening", UndoRedo.MERGE_DISABLE, EditorInterface.get_edited_scene_root())
	var changed := []
	for brush: LevelBrush in changes:
		for key in changes[brush][1]:
			ur.add_do_property(brush, key, changes[brush][1][key])
			ur.add_undo_property(brush, key, changes[brush][0][key])
		changed.append({brush = brush, before = changes[brush][0], after = changes[brush][1]})
	for b in doomed:
		sel_brushes.erase(b)
		ur.add_do_method(root.data, &"remove_brush", b)
		ur.add_undo_method(root.data, &"add_brush", b, root.data.brushes.find(b))
		ur.add_undo_reference(b)
	for b in added:
		ur.add_do_method(root.data, &"add_brush", b)
		ur.add_do_reference(b)
		ur.add_undo_method(root.data, &"remove_brush", b)
	ur.add_do_property(door, &"cut_size", Vector2(w, h))
	ur.add_undo_property(door, &"cut_size", door.cut_size)
	_refresh_cut_surroundings(ur, changed)
	ur.commit_action(false)
	for b in doomed:
		root.data.remove_brush(b)
	for b in added:
		root.data.add_brush(b)
	door.cut_size = Vector2(w, h)
	_rebake_vertex_ao_if_used(root)


## Removes a passage / door brush and closes the wall opening it carved (into `ur`); a
## door also takes the brushes built with it for the next room while still untouched.
func _remove_passage_brush(ur: EditorUndoRedoManager, root: LevelRoot, b: LevelBrush) -> Array:
	var p := b.opening_spec()
	var filled: Array = []
	if p.carved:
		filled = PassageBuilder.fill_opening(root, root.global_transform * p.carved_xf, p.carved_width, p.carved_height, [b], b.tag,
			p.carved_shape)
	for c in filled:
		for key in c.after:
			ur.add_do_property(c.brush, key, c.after[key])
			ur.add_undo_property(c.brush, key, c.before[key])
	var doomed := [b]
	if b.is_door():
		for other: LevelBrush in root.data.brushes:
			if other and other != b and b.door.extra_hashes.get(other.tag) == _shape_hash(other):
				doomed.append(other)
	for d in doomed:
		sel_brushes.erase(d)
		ur.add_do_method(root.data, &"remove_brush", d)
		ur.add_undo_method(root.data, &"add_brush", d, root.data.brushes.find(d))
		ur.add_undo_reference(d)
	return filled


## Cmd/Ctrl+click with the Passage tool: removes the passage whose corridor (floor or shell)
## is under the cursor, its brushes, and closes the wall opening it carved. One undo step.
func _removal_held() -> bool:
	return Input.is_key_pressed(KEY_META) or Input.is_key_pressed(KEY_CTRL)


## The passage whose corridor floor / shell is under the cursor: {passage, root, brushes}.
func _passage_under(camera: Camera3D) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {}
	var hit := _pick(camera, mouse_pos)
	if hit.is_empty():
		return _passage_by_volume(camera, scene_root)
	var tag := String(hit.brush.tag)
	if tag.ends_with("_shell"):
		tag = tag.trim_suffix("_shell")
	if tag == "":
		return _passage_by_volume(camera, scene_root)
	for n in scene_root.find_children("*", "Node3D", true, false):
		if n is Passage and String(n.floor_tag) == tag:
			var brushes: Array = []
			for b in hit.root.data.brushes:
				if b and (String(b.tag) == tag or String(b.tag) == tag + "_shell"):
					brushes.append(b)
			return {passage = n, root = hit.root, brushes = brushes}
	return {}


## Fallback: the passage whose corridor box (opening x depth, where its exit trigger
## sits) the cursor ray passes through — for passages whose corridor brushes are gone.
func _passage_by_volume(camera: Camera3D, scene_root: Node) -> Dictionary:
	var from := camera.project_ray_origin(mouse_pos)
	var dir := camera.project_ray_normal(mouse_pos)
	var best := {}
	var best_d := INF
	for n in scene_root.find_children("*", "Node3D", true, false):
		if not n is Passage:
			continue
		var inv: Transform3D = n.global_transform.affine_inverse()
		var box := AABB(Vector3(-n.width * 0.5, 0, -n.depth), Vector3(n.width, n.height, n.depth))
		var hit = box.intersects_segment(inv * from, inv * (from + dir * 500.0))
		if hit == null:
			continue
		var d: float = (n.global_transform * hit).distance_to(from)
		if d < best_d:
			best_d = d
			var root: LevelRoot = n.level as LevelRoot
			var brushes: Array = []
			if root and root.data:
				for b in root.data.brushes:
					if b and (b.tag == n.floor_tag or String(b.tag) == String(n.floor_tag) + "_shell"):
						brushes.append(b)
			best = {passage = n, root = root, brushes = brushes}
	return best


func _remove_passage_at(camera: Camera3D) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	var hit := _pick(camera, mouse_pos)
	if not hit.is_empty() and hit.brush.is_passage():
		var pr: LevelRoot = hit.root
		sel_brushes.erase(hit.brush)
		var pur := get_undo_redo()
		pur.create_action("Remove Passage", UndoRedo.MERGE_DISABLE, pr)
		var pfilled := _remove_passage_brush(pur, pr, hit.brush)
		_refresh_cut_surroundings(pur, pfilled)
		pur.commit_action()
		_rebake_vertex_ao_if_used(pr)
		return
	var found := _passage_under(camera)
	_remove_hover = {}
	if found.is_empty():
		push_warning("N64 Level Tools: %s+click a passage's corridor floor or walls to remove it." % MOD)
		return
	var passage: Passage = found.passage
	var root: LevelRoot = found.root
	var doomed: Array = found.brushes
	# Deselect what's going away, or the editor keeps drawing its selection box.
	var selection := EditorInterface.get_selection()
	for n in selection.get_selected_nodes():
		if n == passage or passage.is_ancestor_of(n):
			selection.remove_node(n)
	for b in doomed:
		sel_brushes.erase(b)
	var filled: Array = PassageBuilder.fill_opening(root, passage.global_transform, passage.width, passage.height, doomed, passage.floor_tag) \
		if root and root.data else []
	var ur := get_undo_redo()
	ur.create_action("Remove Passage", UndoRedo.MERGE_DISABLE, scene_root)
	for c in filled:
		for key in c.after:
			ur.add_do_property(c.brush, key, c.after[key])
			ur.add_undo_property(c.brush, key, c.before[key])
	for b in doomed if root and root.data else []:
		ur.add_do_method(root.data, &"remove_brush", b)
		ur.add_undo_method(root.data, &"add_brush", b, root.data.brushes.find(b))
		ur.add_undo_reference(b)
	ur.add_do_method(passage.get_parent(), &"remove_child", passage)
	ur.add_undo_method(self, &"_restore_child", passage.get_parent(), passage, scene_root)
	ur.add_undo_reference(passage)
	_refresh_cut_surroundings(ur, filled)
	ur.commit_action()
	print("[N64 Level Tools] Removed passage '%s' (%d brushes, %d wall openings closed)" % [passage.name, doomed.size(), filled.size()])
	_rebake_vertex_ao_if_used(root)


## The door under the cursor ({door, root, brushes}): a recess brush that was hit, else
## the door's own box (panel + wall thickness).
func _door_under(camera: Camera3D) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {}
	var doors: Array = scene_root.find_children("*", "Node3D", true, false).filter(func(n): return n is Door)
	var hit := _pick(camera, mouse_pos)
	if hit:
		var tag := String(hit.brush.tag)
		for d in doors:
			var rt := String(d.recess_tag)
			if not rt.is_empty() and (tag == rt or tag.begins_with(rt + "_")):
				return _door_target(d)
	var from := camera.project_ray_origin(mouse_pos)
	var dir := camera.project_ray_normal(mouse_pos)
	var best := {}
	var best_d := INF
	for d: Door in doors:
		var inv := d.global_transform.affine_inverse()
		var half := maxf(d.wall_depth * 0.5, 0.2)
		var box := AABB(Vector3(-d.width * 0.5, 0, d.wall_center_z - half), Vector3(d.width, d.height, half * 2.0))
		var p = box.intersects_segment(inv * from, inv * (from + dir * 500.0))
		if p == null:
			continue
		var dist: float = (d.global_transform * p).distance_to(from)
		# Only when nothing nearer (a wall in front) is hit.
		if dist < best_d and (hit.is_empty() or dist <= hit.distance + 0.3):
			best_d = dist
			best = _door_target(d)
	return best


## {door, root, brushes}: the recess brushes to delete with it (the opposing wall and the
## starter floor only while unchanged since placing).
func _door_target(d: Door) -> Dictionary:
	var out := {door = d, root = null, brushes = []}
	var rt := String(d.recess_tag)
	if rt.is_empty():
		return out
	for root in _scene_level_roots():
		if root.data == null:
			continue
		for b in root.data.brushes:
			if b == null:
				continue
			var tag := String(b.tag)
			if tag == rt or tag == rt + "_shell":
				out.brushes.append(b)
			elif tag.begins_with(rt + "_") and d.recess_hashes.get(b.tag) == _shape_hash(b):
				out.brushes.append(b)
		if not out.brushes.is_empty():
			out.root = root
			break
	return out


func _shape_hash(b: LevelBrush) -> int:
	return hash([b.vertices, b.face_indices, b.face_counts, b.transform])


func _draw_door_outline(overlay: Control, camera: Camera3D, d: Door) -> void:
	var xf := d.global_transform
	var z := d.wall_center_z + d.wall_depth * 0.5
	var c := [Vector3(-d.width * 0.5, 0, z), Vector3(-d.width * 0.5, d.height, z), Vector3(d.width * 0.5, d.height, z), Vector3(d.width * 0.5, 0, z)]
	for k in 4:
		_line3d(overlay, camera, xf * c[k], xf * c[(k + 1) % 4], REMOVE_COLOR, 3.0)


## Cmd/Ctrl+click with the Door tool: removes the door; a recessed door also loses its
## tunnel (wall opening closed) and, while untouched, its opposing wall and starter floor.
func _remove_door_at(camera: Camera3D) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	# Door brushes: delete the brush (closes the wall, drops untouched next-room brushes).
	var hit := _pick(camera, mouse_pos)
	if not hit.is_empty() and hit.brush.is_door():
		var dr: LevelRoot = hit.root
		_remove_hover = {}
		var dur := get_undo_redo()
		dur.create_action("Remove Door", UndoRedo.MERGE_DISABLE, dr)
		var closed := _remove_passage_brush(dur, dr, hit.brush)
		_refresh_cut_surroundings(dur, closed)
		dur.commit_action()
		_rebake_vertex_ao_if_used(dr)
		update_overlays()
		return
	var found := _door_under(camera)
	_remove_hover = {}
	if found.is_empty():
		push_warning("N64 Level Tools: %s+click a door (or its recess) to remove it." % MOD)
		return
	var door: Door = found.door
	var root: LevelRoot = found.root
	var doomed: Array = found.brushes
	var selection := EditorInterface.get_selection()
	for n in selection.get_selected_nodes():
		if n == door or door.is_ancestor_of(n):
			selection.remove_node(n)
	for b in doomed:
		sel_brushes.erase(b)
	var filled: Array = []
	if root and not String(door.recess_tag).is_empty():
		# The opening was carved at the front wall face.
		var face_xf := door.global_transform * Transform3D(Basis(), Vector3(0, 0, door.wall_center_z + door.wall_depth * 0.5))
		filled = PassageBuilder.fill_opening(root, face_xf, door.width, door.height, doomed, door.recess_tag)
	var ur := get_undo_redo()
	ur.create_action("Remove Door", UndoRedo.MERGE_DISABLE, scene_root)
	for c in filled:
		for key in c.after:
			ur.add_do_property(c.brush, key, c.after[key])
			ur.add_undo_property(c.brush, key, c.before[key])
	if root:
		for b in doomed:
			ur.add_do_method(root.data, &"remove_brush", b)
			ur.add_undo_method(root.data, &"add_brush", b, root.data.brushes.find(b))
			ur.add_undo_reference(b)
	ur.add_do_method(door.get_parent(), &"remove_child", door)
	ur.add_undo_method(self, &"_restore_child", door.get_parent(), door, scene_root)
	ur.add_undo_reference(door)
	_refresh_cut_surroundings(ur, filled)
	ur.commit_action()
	print("[N64 Level Tools] Removed door '%s' (%d brushes, %d wall openings closed)" % [door.name, doomed.size(), filled.size()])
	if root:
		_rebake_vertex_ao_if_used(root)


## Geometry changed around a passage: refresh vertex AO (if the level uses it) so the
## threshold and the new corridor match. Its own undo step.
func _rebake_vertex_ao_if_used(root: LevelRoot) -> void:
	if root == null or root != level or not root.data.brushes.any(func(b): return b and not b.vertex_ao.is_empty()):
		return
	_bake_vertex_ao()


func _restore_child(parent: Node, child: Node, owner_node: Node) -> void:
	parent.add_child(child, true)
	child.owner = owner_node


func _place_brush() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var root := _target_level_root()
	var create_root := root == null
	var parent_xf := Transform3D.IDENTITY
	if create_root:
		root = LevelRoot.new()
		root.name = "Level"
		root.data = LevelData.new()
		if scene_root is Node3D:
			parent_xf = scene_root.global_transform
	else:
		parent_xf = root.global_transform

	var b := LevelBrush.new()
	b.shape = place_shape as BrushShapes.Shape
	b.size = BrushShapes.default_size(place_shape)
	b.segments = BrushShapes.default_segments(place_shape)
	b.transform = Transform3D(parent_xf.basis.inverse() * _place_basis(), parent_xf.affine_inverse() * ghost_base)

	var ur := get_undo_redo()
	# Scene context: the new brush (no path yet) counts as part of the scene, so the action
	# must live in the scene's history, not the global one the level data alone would pick.
	ur.create_action("Add %s Brush" % BrushShapes.shape_name(place_shape), UndoRedo.MERGE_DISABLE, scene_root)
	if create_root:
		ur.add_do_method(scene_root, &"add_child", root, true)
		ur.add_do_method(root, &"set_owner", scene_root)
		ur.add_do_reference(root)
		ur.add_undo_method(scene_root, &"remove_child", root)
	ur.add_do_method(root.data, &"add_brush", b)
	ur.add_do_reference(b)
	ur.add_undo_method(root.data, &"remove_brush", b)
	ur.commit_action()
	_select_brush(root, b, false)


# --- Set pieces (Blender) -------------------------------------------------------------

## Edit in Blender: opens the selected set piece's .blend, or moves the selected brushes
## into a new one (asks its name).
func _edit_in_blender() -> void:
	var b := _active()
	if b == null:
		EditorInterface.get_editor_toaster().push_toast("Select the brushes to make into a set piece (or one of a set piece's).", EditorToaster.SEVERITY_WARNING)
		return
	if b.blend_file != "":
		blender.open_blender(b.blend_file, b.blend_object)
		return
	if _set_piece_dialog == null:
		_set_piece_dialog = ConfirmationDialog.new()
		_set_piece_dialog.title = "New Set Piece in Blender"
		var box := VBoxContainer.new()
		var hint := Label.new()
		hint.text = "The selected brushes move into a .blend (next to the scene, in blend/),\nedited in Blender. Placement and paint stay here."
		box.add_child(hint)
		_set_piece_name = LineEdit.new()
		_set_piece_name.placeholder_text = "Name (e.g. amphitheatre)"
		_set_piece_name.text_submitted.connect(func(_t): _set_piece_dialog.get_ok_button().pressed.emit())
		box.add_child(_set_piece_name)
		_set_piece_dialog.add_child(box)
		_set_piece_dialog.confirmed.connect(func():
			var brushes: Array[LevelBrush] = []
			for x in sel_brushes:
				if x.blend_file == "" and level.has_brush(x):
					brushes.append(x)
			blender.create(level, brushes, _set_piece_name.text))
		EditorInterface.get_base_control().add_child(_set_piece_dialog)
	_set_piece_name.text = String(b.tag) if b.tag != &"" else ""
	_set_piece_dialog.popup_centered(Vector2i(420, 0))
	_set_piece_name.grab_focus()


## Selected set piece brushes back to the brush tools (their .blend stays).
func _unlink_blender() -> void:
	if not _level_ok():
		return
	var brushes: Array[LevelBrush] = []
	for b in sel_brushes:
		if b.blend_file != "":
			brushes.append(b)
	if not brushes.is_empty():
		blender.unlink(level, brushes)


## After deleting a set piece's last brushes: asks to move its .blend to the Trash.
func _offer_trash_blends(files: PackedStringArray) -> void:
	if files.is_empty():
		return
	if _trash_dialog == null:
		_trash_dialog = ConfirmationDialog.new()
		_trash_dialog.title = "Delete Set Piece Files"
		_trash_dialog.ok_button_text = "Move to Trash"
		_trash_dialog.cancel_button_text = "Keep"
		_trash_dialog.confirmed.connect(func():
			for file: String in _trash_dialog.get_meta(&"files"):
				var err: String = blender.trash(file)
				if err != "":
					EditorInterface.get_editor_toaster().push_toast(err, EditorToaster.SEVERITY_WARNING))
		EditorInterface.get_base_control().add_child(_trash_dialog)
	var names := Array(files).map(func(f: String): return f.get_file())
	_trash_dialog.set_meta(&"files", files)
	_trash_dialog.dialog_text = "No brush uses %s any more.\nMove it to the Trash?\n(Undo brings the brushes back, not the file: restore it from the Trash.)" % ", ".join(names)
	_trash_dialog.popup_centered()


func _set_piece_locked() -> void:
	EditorInterface.get_editor_toaster().push_toast("Set piece: its shape is edited in Blender (Edit in Blender). Move, rotate and paint it here.", EditorToaster.SEVERITY_WARNING)


# --- Bake / data --------------------------------------------------------------------

func _bake_all() -> void:
	var roots := _scene_level_roots()
	if roots.is_empty():
		push_warning("N64 Level Tools: no LevelRoot in the edited scene.")
		return
	var ur := get_undo_redo()
	var lights := LevelLighting.gather_lights(EditorInterface.get_edited_scene_root())
	var baked := {}
	for root in roots:
		if root.data == null:
			continue
		if baked.has(root.data):
			push_warning("N64 Level Tools: %s uses the same level data as %s, so it was baked once. Two LevelRoots on one data draw everything twice; delete the extra one unless that's intended." % [root.name, baked[root.data].name])
			continue
		baked[root.data] = root
		var not_ready := LevelBaker.not_ready_reason(root.data)
		if not not_ready.is_empty():
			push_error("N64 Level Tools: not baking %s: %s. Wait a moment (or restart the editor) and bake again." % [root.name, not_ready])
			continue
		var relit := {}
		if LevelData.mode_is_timed(root.data.lighting_mode):
			# Timed levels re-light per key before baking (applied directly; part of this bake).
			var schedule := LightingSchedule.load_project()
			if schedule:
				var keyed := LevelLighting.bake_keys(root, roots + _dressing_occluders(), _baked_lights(root.data.lighting_mode, lights), schedule)
				for brush in keyed:
					var arr: Array[PackedColorArray] = []
					arr.assign(keyed[brush])
					brush.set_block_signals(true)
					brush.corner_lighting_keys = arr
					brush.set_block_signals(false)
		elif root.data.lighting_mode in [LevelData.LightingMode.BAKED_VERTEX, LevelData.LightingMode.BAKED_VERTEX_DYNAMIC]:
			# Re-light first so the bake always carries current lighting.
			relit = LevelLighting.bake(root, roots + _dressing_occluders(), _baked_lights(root.data.lighting_mode, lights))
			for brush in relit:
				brush.set_block_signals(true)
				var old: PackedColorArray = brush.corner_lighting
				brush.corner_lighting = relit[brush]
				relit[brush] = [old, relit[brush]]
				brush.set_block_signals(false)
		var result := LevelBaker.bake(root.data, root.merge_coplanar)
		var s: Dictionary = result.stats
		var summary := "%d tris, %d surfaces in %d chunks (from %d tris, %d brushes)" % [s.baked_tris, s.surfaces, s.chunks, s.source_tris, s.brushes]
		ur.create_action("Bake Level", UndoRedo.MERGE_DISABLE, root)
		for brush in relit:
			ur.add_do_property(brush, &"corner_lighting", relit[brush][1])
			ur.add_undo_property(brush, &"corner_lighting", relit[brush][0])
		for prop in [[&"baked_mesh", result.mesh], [&"baked_chunks", result.chunks], [&"baked_collision", null],
				[&"baked_collision_parts", result.collision_parts], [&"baked_collision_surfaces", result.collision_surfaces],
				[&"bake_hash", root.compute_hash()], [&"bake_summary", summary]]:
			ur.add_do_property(root.data, prop[0], prop[1])
			ur.add_undo_property(root.data, prop[0], root.data.get(prop[0]))
		ur.commit_action()
		print("[N64 Level Tools] Baked %s: %d brushes, %d -> %d tris, %d interior faces culled, %d coplanar faces merged, %d degenerate tris removed, %d verts, %d surfaces, %d chunks, %d collision tris" % [
			root.name, s.brushes, s.source_tris, s.baked_tris, s.culled_faces, s.merged_faces,
			s.degenerate_tris, s.baked_verts, s.surfaces, s.chunks, s.collision_tris])


## Lighting undo ops for one level: per-key bakes for Baked Timed, else a single bake.
## Returns the number of corners lit.
func _add_lighting_ops(ur: EditorUndoRedoManager, root: LevelRoot, roots: Array, lights: Array, mode := -1) -> int:
	var corners := 0
	if mode < 0:
		mode = root.data.lighting_mode
	if LevelData.mode_is_timed(mode):
		var schedule := LightingSchedule.load_project()
		if schedule == null:
			push_warning("N64 Level Tools: Baked Timed needs a LightingSchedule (Project Settings > n64/lighting/schedule).")
			return 0
		var keyed := LevelLighting.bake_keys(root, roots + _dressing_occluders(), _baked_lights(mode, lights), schedule)
		for brush in keyed:
			var arr: Array[PackedColorArray] = []
			arr.assign(keyed[brush])
			ur.add_do_property(brush, &"corner_lighting_keys", arr)
			ur.add_undo_property(brush, &"corner_lighting_keys", brush.corner_lighting_keys)
			corners += arr.size() * (arr[0].size() if not arr.is_empty() else 0)
		return corners
	var lit := LevelLighting.bake(root, roots + _dressing_occluders(), _baked_lights(mode, lights))
	for brush in lit:
		ur.add_do_property(brush, &"corner_lighting", lit[brush])
		ur.add_undo_property(brush, &"corner_lighting", brush.corner_lighting)
		corners += lit[brush].size()
	return corners


## Lights that go into a level's bake: all of them, except in the Dynamic bake modes, where only
## lights set to Bake Mode Static are baked (the rest light the level live).
func _baked_lights(mode: int, lights: Array) -> Array:
	if not LevelData.mode_is_hybrid(mode):
		return lights
	return lights.filter(func(l: Light3D): return l.light_bake_mode == Light3D.BAKE_STATIC)


## Bakes vertex lighting for every level in the scene (one pass, or one per schedule key
## for Baked Timed levels); Dynamic levels switch to Baked Vertex Dynamic (undoable), so live
## lights keep working. Lights, ambient and occlusion come from LevelData's Lighting settings
## and the scene's DirectionalLight3D / OmniLight3D nodes.
func _bake_lighting() -> void:
	var roots := _scene_level_roots()
	if roots.is_empty():
		push_warning("N64 Level Tools: no LevelRoot in the edited scene.")
		return
	var lights := LevelLighting.gather_lights(EditorInterface.get_edited_scene_root())
	var ur := get_undo_redo()
	ur.create_action("Bake Vertex Lighting", UndoRedo.MERGE_DISABLE, EditorInterface.get_edited_scene_root())
	var t0 := Time.get_ticks_msec()
	var corners := 0
	for root in roots:
		if root.data == null:
			continue
		var mode := root.data.lighting_mode
		if mode == LevelData.LightingMode.DYNAMIC:
			mode = LevelData.LightingMode.BAKED_VERTEX_DYNAMIC
			ur.add_do_property(root.data, &"lighting_mode", mode)
			ur.add_undo_property(root.data, &"lighting_mode", root.data.lighting_mode)
		corners += _add_lighting_ops(ur, root, roots, lights, mode)
	ur.commit_action()
	LevelLights.apply(EditorInterface.get_edited_scene_root())
	print("[N64 Level Tools] Lit %d corners with %d light(s) in %d ms. Bake the level to use it in game." % [
		corners, lights.size(), Time.get_ticks_msec() - t0])
	_refresh_status()


func _preview_baked(enabled: bool) -> void:
	for root in _scene_level_roots():
		root.preview_baked = enabled


func _save_data_as() -> void:
	_save_target = _target_level_root()
	if _save_target == null or _save_target.data == null:
		push_warning("N64 Level Tools: no LevelRoot to save data from.")
		return
	if _file_dialog == null:
		_file_dialog = EditorFileDialog.new()
		_file_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		_file_dialog.add_filter("*.res", "Binary resource (compact)")
		_file_dialog.add_filter("*.tres", "Text resource (diffable)")
		_file_dialog.file_selected.connect(_on_save_path_selected)
		EditorInterface.get_base_control().add_child(_file_dialog)
	var scene := EditorInterface.get_edited_scene_root()
	var base := scene.scene_file_path.get_basename() if scene and scene.scene_file_path else "res://level"
	_file_dialog.current_path = "%s_%s.res" % [base, _save_target.name.to_snake_case()]
	_file_dialog.popup_file_dialog()


func _on_save_path_selected(path: String) -> void:
	var data := _save_target.data
	var err := ResourceSaver.save(data, path, ResourceSaver.FLAG_CHANGE_PATH)
	if err != OK:
		push_error("N64 Level Tools: failed to save level data to %s (%s)." % [path, error_string(err)])
		return
	data.take_over_path(path)
	EditorInterface.get_resource_filesystem().update_file(path)
	EditorInterface.mark_scene_as_unsaved()
	_refresh_status()


# --- Overlay drawing ----------------------------------------------------------------

## Brushes with more edges than this draw their wireframe / vertex dots as GPU meshes
## (built once per edit) instead of per-redraw overlay lines: a 5k-vertex set piece meant
## ~20k draw calls in GDScript on every mouse move while panning.
const DENSE_EDGES := 1500
# Depth-tested (geometry in front hides them) but pulled 0.1% towards the camera, so they
# win against the brush's own faces they lie on.
const WIRE_HEAD := """shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, shadows_disabled, fog_disabled, skip_vertex_transform;
uniform vec4 color : source_color = vec4(1.0);
"""
const WIRE_LINES := WIRE_HEAD + """void vertex() {
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz * 0.999;
}
void fragment() {
	ALBEDO = color.rgb;
	ALPHA = color.a;
}
"""
# Separate shader: one writing POINT_SIZE draws nothing on line meshes (Metal).
const WIRE_DOTS := WIRE_HEAD + """uniform float point_size = 7.0;
void vertex() {
	// More pull than lines: the dot sprite is flat at its vertex's depth, so a floor seen at
	// a grazing angle would clip its lower half.
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz * 0.99;
	POINT_SIZE = point_size;
}
void fragment() {
	// Round dot with a dark rim, like the overlay's.
	float d = length(POINT_COORD - vec2(0.5)) * 2.0;
	if (d > 1.0) {
		discard;
	}
	ALBEDO = d > 0.68 ? vec3(0.1) : color.rgb;
}
"""
static var _wire_shaders := {}
## Wire / dot meshes: key -> {mi, geo (geometry hash), frame (last drawn)}.
var _wires := {}


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	_draw_over(overlay)
	if _sticky_grid:
		_update_sticky_grid()  # follows scene switches / brush edits (cheap when unchanged)
	# Meshes nothing asked for this frame (every viewport's overlay draws in the same one).
	var frame := Engine.get_process_frames()
	for key in _wires.keys():
		var w: Dictionary = _wires[key]
		if not is_instance_valid(w.mi):
			_wires.erase(key)
		elif w.frame != frame:
			w.mi.queue_free()
			_wires.erase(key)


func _dense(b: LevelBrush) -> bool:
	return b.get_edges().size() > DENSE_EDGES


## Shows `b`'s edges (or `dots`: its vertices) as a mesh this frame.
func _wire(b: LevelBrush, xf: Transform3D, color: Color, dots := false) -> void:
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null:
		return
	var key := [b.get_instance_id(), color, dots]
	var w: Dictionary = _wires.get(key, {})
	if w.is_empty() or not is_instance_valid(w.mi) or w.mi.get_parent() != scene:
		if not w.is_empty() and is_instance_valid(w.mi):
			w.mi.queue_free()
		if not _wire_shaders.has(dots):
			var sh := Shader.new()
			sh.code = WIRE_DOTS if dots else WIRE_LINES
			_wire_shaders[dots] = sh
		var mat := ShaderMaterial.new()
		mat.shader = _wire_shaders[dots]
		mat.render_priority = 120 if dots else 110
		mat.set_shader_parameter(&"color", color)
		if dots:
			# Physical pixels: the overlay's 7 px dot on a hi-dpi screen too.
			mat.set_shader_parameter(&"point_size", 7.0 * EditorInterface.get_editor_scale())
		var mi := MeshInstance3D.new()
		mi.name = "_Wire"
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.material_override = mat
		mi.mesh = ArrayMesh.new()
		scene.add_child(mi, false, Node.INTERNAL_MODE_BACK)
		w = {mi = mi, geo = 0, frame = 0}
		_wires[key] = w
	w.frame = Engine.get_process_frames()
	w.mi.global_transform = xf
	var geo := hash([b.vertices, b.face_indices, b.face_counts])
	if geo == w.geo:
		return
	w.geo = geo
	var mesh: ArrayMesh = w.mi.mesh
	mesh.clear_surfaces()
	if b.vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = b.vertices
	if dots:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
		return
	var idx := PackedInt32Array()
	for e in b.get_edges():
		idx.append(e.x)
		idx.append(e.y)
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)


func _draw_over(overlay: Control) -> void:
	if mode != Mode.PAINT or not panel.visible:
		_hide_fill_preview()
		_hide_fill_preview(&"mask")
		_hide_fill_preview(&"surfaces")
	if not panel.visible:
		return
	var camera := _overlay_camera(overlay)
	if camera == null:
		return
	var is_input_view := camera == input_camera
	if place_shape >= 0 and ghost_valid and is_input_view:
		_draw_ghost(overlay, camera)
	var hover_node: Node3D = _remove_hover.get("passage", _remove_hover.get("door"))
	if (place_shape == PASSAGE_TOOL or place_shape == DOOR_TOOL) and is_input_view and is_instance_valid(hover_node):
		var rr: LevelRoot = _remove_hover.root
		if rr:
			for b in _remove_hover.brushes:
				_draw_brush_edges(overlay, camera, rr.brush_global_transform(b), b, REMOVE_COLOR, 2.5)
		if hover_node is Door:
			_draw_door_outline(overlay, camera, hover_node)
		var at: Vector3 = hover_node.global_position + Vector3.UP * 0.2
		if not camera.is_position_behind(at):
			_draw_label(overlay, camera.unproject_position(at) + Vector2(10, -10),
				"Remove %s (click)" % hover_node.name)
	var editing_fence: LevelBrush = fence_edit.selected_fence() if fence_edit else null
	if editing_fence and is_input_view:
		fence_edit.draw(editing_fence, overlay, camera)
	if fence_edit and fence_edit.placing and is_input_view:
		fence_edit.draw_placing(overlay, camera)
	# Another node is being edited: no brush selection / handles that look clickable.
	if mode != Mode.PAINT and mode != Mode.SCULPT and _other_node_selected():
		return
	if mode == Mode.PAINT and is_input_view:
		_draw_paint_cursor(overlay, camera)
		return
	if mode == Mode.SCULPT and is_input_view:
		_draw_sculpt_cursor(overlay, camera)
		return
	if is_input_view and hover_brush and is_instance_valid(hover_root) and hover_root.has_brush(hover_brush) \
			and not hover_brush in sel_brushes:
		_draw_brush_edges(overlay, camera, hover_root.brush_global_transform(hover_brush), hover_brush, Color(1, 1, 1, 0.5), 1.0)
	if is_input_view and mode == Mode.OBJECT and place_shape < 0 and not hover_hit.is_empty() and drag == Drag.NONE:
		_draw_reference_grid(overlay, camera, hover_hit.position, hover_hit.normal)
	if not _level_ok():
		return
	if mode == Mode.OBJECT:
		for b in sel_brushes:
			if level.has_brush(b):
				_draw_brush_edges(overlay, camera, _bxf(b), b, SEL_COLOR, 2.0)
		for h in _resize_handles():
			if camera.is_position_behind(h.world):
				continue
			var p := camera.unproject_position(h.world)
			var hot: bool = (drag == Drag.RESIZE and drag_resize.id == h.id) \
				or (is_input_view and drag == Drag.NONE and hover_resize == h.id)
			var color: Color = AXIS_COLORS[h.axis].lightened(0.5 if hot else 0.15)
			var rect := Rect2(p - Vector2(5, 5), Vector2(10, 10))
			overlay.draw_rect(rect, color)
			overlay.draw_rect(rect, Color(0, 0, 0, 0.7), false, 1.0)
	elif _active():
		_draw_brush_edit(overlay, camera, is_input_view)
	_draw_gizmo(overlay, camera, is_input_view)
	if is_input_view and drag == Drag.BOX:
		var rect := Rect2(box_from, Vector2.ZERO).expand(mouse_pos)
		overlay.draw_rect(rect, Color(SEL_COLOR, 0.12))
		overlay.draw_rect(rect, SEL_COLOR, false, 1.0)
	if is_input_view and drag == Drag.RESIZE and _active():
		var s := _active().resize_box().size
		_draw_label(overlay, mouse_pos + Vector2(16, -12), "size %.2f × %.2f × %.2f" % [s.x, s.y, s.z])


func _overlay_camera(overlay: Control) -> Camera3D:
	var n: Node = overlay
	while n:
		for c in n.get_children():
			if c is SubViewportContainer:
				for v in c.get_children():
					if v is SubViewport:
						return v.get_camera_3d()
		n = n.get_parent()
	var vp := EditorInterface.get_editor_viewport_3d(0)
	return vp.get_camera_3d() if vp else null


## Sticky grid (G): a depth-tested grid over the whole level on a horizontal plane, staying
## put whatever the cursor is over (laying out greyboxes). Its spacing is the snap and its
## height the surface under the cursor when turned on (Shift+G takes both again). Editor only: an
## unowned internal node of the edited scene, never saved.
var _sticky_grid := false
var _sticky_y := 0.0
## The snap size when the grid was turned on (G) / moved (Shift+G): changing the snap
## afterwards leaves the grid alone.
var _sticky_step := 1.0
var _sticky_mi: MeshInstance3D
var _sticky_key := []


func _set_sticky_grid(on: bool) -> void:
	_sticky_grid = on
	if on:
		var hit := _pick(input_camera, mouse_pos) if input_camera and is_instance_valid(input_camera) else {}
		_sticky_y = hit.position.y if hit else 0.0
		_sticky_step = snap
		_sticky_key = []
	panel.set_sticky_grid(on)
	_refresh_status()
	_update_sticky_grid()
	update_overlays()


## ] / [ (or Alt+PgUp / PgDn) while the sticky grid is on: up / down one locked step.
func _raise_sticky_grid(dir: int) -> void:
	_sticky_y = snappedf(_sticky_y + dir * _sticky_step, 0.0001)
	_update_sticky_grid()
	_refresh_status()
	update_overlays()


func _update_sticky_grid() -> void:
	var scene := EditorInterface.get_edited_scene_root()
	if not _sticky_grid or scene == null or not scene is Node3D:
		if is_instance_valid(_sticky_mi):
			_sticky_mi.queue_free()
		_sticky_mi = null
		_sticky_key = []
		return
	var box := AABB()
	var any := false
	for root in _scene_level_roots():
		for b in root.data.brushes if root.data else []:
			if b:
				var bb := root.brush_global_transform(b) * b.local_aabb()
				box = bb if not any else box.merge(bb)
				any = true
	if not any:
		box = AABB(Vector3(-20, 0, -20), Vector3(40, 0, 40))
	box = box.grow(10.0)
	var key := [scene, _sticky_step, _sticky_y, box]
	if key == _sticky_key and is_instance_valid(_sticky_mi) and _sticky_mi.get_parent() == scene:
		return
	_sticky_key = key
	if not is_instance_valid(_sticky_mi) or _sticky_mi.get_parent() != scene:
		if is_instance_valid(_sticky_mi):
			_sticky_mi.queue_free()
		_sticky_mi = MeshInstance3D.new()
		_sticky_mi.name = "_StickyGrid"
		_sticky_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		scene.add_child(_sticky_mi, false, Node.INTERNAL_MODE_BACK)
	_sticky_mi.global_transform = Transform3D.IDENTITY
	var mesh := ArrayMesh.new()
	var y := _sticky_y + 0.01
	# Lines every snap (faint) and every metre (stronger); the faint set is left out when it
	# would be too dense to read.
	var steps := [[_sticky_step, 0.45]] if _sticky_step >= 1.0 else [[_sticky_step, 0.18], [1.0, 0.45]]
	for st in steps:
		var step: float = st[0]
		if box.size.x / step > 2000.0 or box.size.z / step > 2000.0:
			continue
		var verts := PackedVector3Array()
		var x0 := floorf(box.position.x / step) * step
		var z0 := floorf(box.position.z / step) * step
		var x := x0
		while x <= box.end.x:
			if step >= 1.0 or not is_zero_approx(fposmod(x + 0.0001, 1.0) - 0.0001):
				verts.append(Vector3(x, y, box.position.z))
				verts.append(Vector3(x, y, box.end.z))
			x += step
		var z := z0
		while z <= box.end.z:
			if step >= 1.0 or not is_zero_approx(fposmod(z + 0.0001, 1.0) - 0.0001):
				verts.append(Vector3(box.position.x, y, z))
				verts.append(Vector3(box.end.x, y, z))
			z += step
		if verts.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		if not _wire_shaders.has(false):
			var sh := Shader.new()
			sh.code = WIRE_LINES
			_wire_shaders[false] = sh
		var mat := ShaderMaterial.new()
		mat.shader = _wire_shaders[false]
		mat.render_priority = 100
		mat.set_shader_parameter(&"color", Color(1.0, 0.85, 0.3, st[1]))
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	_sticky_mi.mesh = mesh
	_sticky_mi.visible = panel.visible


## Snap-size grid on the surface under the cursor (Object mode hover), fading out a few
## cells away. Lines sit on world multiples of the snap, in the plane of the hit face, so
## they show where snapped moves / resizes land whatever the brush's own cell size.
func _draw_reference_grid(overlay: Control, camera: Camera3D, p: Vector3, n: Vector3) -> void:
	const CELLS := 5
	var cell := snap
	var axis := 1 if absf(n.y) >= absf(n.x) and absf(n.y) >= absf(n.z) else (0 if absf(n.x) >= absf(n.z) else 2)
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	if absf(n[axis]) < 0.001:
		return
	# A point on the hit plane at in-plane coordinates (a, b).
	var at := func(a: float, b: float) -> Vector3:
		var q := Vector3.ZERO
		q[u] = a
		q[v] = b
		q[axis] = p[axis] - (n[u] * (a - p[u]) + n[v] * (b - p[v])) / n[axis]
		return q
	var cu := snappedf(p[u], cell)
	var cv := snappedf(p[v], cell)
	var reach := CELLS * cell
	for i in range(-CELLS, CELLS + 1):
		for j in range(-CELLS, CELLS):
			# Lines along v at u = cu + i·cell, and along u at v = cv + i·cell, one cell per segment.
			for k in 2:
				var a0 := cu + i * cell if k == 0 else cu + j * cell
				var b0 := cv + j * cell if k == 0 else cv + i * cell
				var a1 := a0 if k == 0 else a0 + cell
				var b1 := b0 + cell if k == 0 else b0
				var mid := Vector2((a0 + a1) * 0.5 - p[u], (b0 + b1) * 0.5 - p[v])
				var fade := 1.0 - mid.length() / reach
				if fade > 0.0:
					_line3d(overlay, camera, at.call(a0, b0), at.call(a1, b1), Color(1.0, 0.85, 0.3, 0.55 * fade), 1.0)


func _line3d(overlay: Control, camera: Camera3D, a: Vector3, b: Vector3, color: Color, width := 1.0) -> void:
	if camera.is_position_behind(a) or camera.is_position_behind(b):
		return
	overlay.draw_line(camera.unproject_position(a), camera.unproject_position(b), color, width, true)


func _draw_brush_edges(overlay: Control, camera: Camera3D, xf: Transform3D, b: LevelBrush, color: Color, width: float) -> void:
	if _dense(b):
		_wire(b, xf, color)
		return
	for e in b.get_edges():
		if e.x < b.vertices.size() and e.y < b.vertices.size():
			_line3d(overlay, camera, xf * b.vertices[e.x], xf * b.vertices[e.y], color, width)


func _draw_ghost(overlay: Control, camera: Camera3D) -> void:
	var c := []
	var label := ""
	if place_shape == DOOR_TOOL and _door_recessed():
		# Recess: tunnel from the wall face back to the opposing wall, door inside it.
		var fi := _door_inset(door_inset_front)
		var depth := fi + _door_inset(door_inset_back)
		var xf := Transform3D(ghost_basis, ghost_door.point)
		for i in 8:
			c.append(xf * Vector3(-1.0 + 2.0 * (i & 1), 3.0 * ((i >> 1) & 1), -depth * ((i >> 2) & 1)))
		for k in [[Vector3(-1, 0, -fi), Vector3(1, 0, -fi)], [Vector3(-1, 3, -fi), Vector3(1, 3, -fi)],
				[Vector3(-1, 0, -fi), Vector3(-1, 3, -fi)], [Vector3(1, 0, -fi), Vector3(1, 3, -fi)]]:
			_line3d(overlay, camera, xf * k[0], xf * k[1], Color(1, 0.8, 0.3), 3.0)
		if door_build_room and ghost_door.behind > depth + 0.05:
			for k in [[Vector3(-1, 0, -depth - 1), Vector3(1, 0, -depth - 1)], [Vector3(-1, 0, -depth), Vector3(-1, 0, -depth - 1)],
					[Vector3(1, 0, -depth), Vector3(1, 0, -depth - 1)]]:
				_line3d(overlay, camera, xf * k[0], xf * k[1], Color(GHOST_COLOR, 0.6), 1.5)
		_line3d(overlay, camera, ghost_door.point, xf * Vector3(0, 0, 1.0), GHOST_COLOR, 3.0)
		label = "Door, inset %.2f / %.2f m" % [fi, depth - fi]
	elif place_shape == DOOR_TOOL and ghost_door.get("between", false):
		# Between faces: the wall slab (clicked face to the one behind), the door inside it.
		var xf := Transform3D(ghost_basis, ghost_door.point)
		var hw: float = ghost_door.width * 0.5
		var h: float = ghost_door.height
		var d: float = ghost_door.depth
		for i in 8:
			c.append(xf * Vector3(hw * (-1.0 + 2.0 * (i & 1)), h * ((i >> 1) & 1), -d * ((i >> 2) & 1)))
		var z := -d * clampf(door_depth / 100.0, 0.0, 1.0)
		for k in [[Vector3(-hw, 0, z), Vector3(hw, 0, z)], [Vector3(-hw, h, z), Vector3(hw, h, z)],
				[Vector3(-hw, 0, z), Vector3(-hw, h, z)], [Vector3(hw, 0, z), Vector3(hw, h, z)]]:
			_line3d(overlay, camera, xf * k[0], xf * k[1], Color(1, 0.8, 0.3), 3.0)
		_line3d(overlay, camera, ghost_base, Transform3D(ghost_basis, ghost_base) * Vector3(0, 0, 1.0), GHOST_COLOR, 3.0)
		label = "Door %d%% into %.2f m wall%s" % [roundi(door_depth), d, ", fits opening %.2f x %.2f m" % [ghost_door.width, h] if ghost_door.fit else ", cuts + lines opening"]
	elif place_shape == DOOR_TOOL:
		var xf := Transform3D(ghost_basis, ghost_base)
		for i in 8:
			c.append(xf * Vector3(-1.0 + 2.0 * (i & 1), 3.0 * ((i >> 1) & 1), -0.1 + 0.2 * ((i >> 2) & 1)))
		_line3d(overlay, camera, ghost_base, xf * Vector3(0, 0, 1.0), GHOST_COLOR, 3.0)
		label = "Door → %s" % ("room" if _room_of(ghost_other_root) and _room_of(ghost_other_root) != _room_of(ghost_root) else "zone")
	elif place_shape == PASSAGE_TOOL:
		var xf := Transform3D(ghost_basis, ghost_base)
		for i in 8:
			c.append(xf * Vector3(-1.0 + 2.0 * (i & 1), 3.0 * ((i >> 1) & 1), -5.0 * ((i >> 2) & 1)))
		_line3d(overlay, camera, ghost_base, xf * Vector3(0, 0, -2.0), GHOST_COLOR, 3.0)
		label = "Passage"
	else:
		var size := _placed_size()
		var lo := ghost_base + Vector3(-size.x * 0.5, 0, -size.z * 0.5)
		for i in 8:
			c.append(lo + Vector3(size.x * (i & 1), size.y * ((i >> 1) & 1), size.z * ((i >> 2) & 1)))
		label = BrushShapes.shape_name(place_shape)
		if place_shape == BrushShapes.Shape.RAMP or place_shape == BrushShapes.Shape.STAIRS:
			# Uphill arrow (the shapes rise toward their local -Z).
			var up := _place_basis() * Vector3(0, 0, -1)
			var reach: float = absf(up.x) * size.x * 0.5 + absf(up.z) * size.z * 0.5
			_line3d(overlay, camera, ghost_base, ghost_base + up * reach, GHOST_COLOR, 3.0)
		if place_turns != 0:
			label += " %d°" % (place_turns * 90)
	for e in [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]:
		_line3d(overlay, camera, c[e[0]], c[e[1]], GHOST_COLOR, 2.0)
	if not camera.is_position_behind(ghost_base):
		var p := camera.unproject_position(ghost_base)
		overlay.draw_circle(p, 4.0, GHOST_COLOR)
		_draw_label(overlay, p + Vector2(10, -10), "%s  (%.2f, %.2f, %.2f)" % [
			label, ghost_base.x, ghost_base.y, ghost_base.z])


func _draw_brush_edit(overlay: Control, camera: Camera3D, is_input_view: bool) -> void:
	var b := _active()
	var xf := _bxf(b)
	var verts := b.vertices

	if mode == Mode.FACE:
		var faces := sel_faces.duplicate()
		if is_input_view and hover_face >= 0 and not hover_face in faces:
			faces.append(hover_face)
		for f in faces:
			if f < b.get_face_count():
				_fill_face(overlay, camera, b, xf, f, Color(SEL_COLOR, 0.3) if f in sel_faces else Color(1, 1, 1, 0.12))

	_draw_brush_edges(overlay, camera, xf, b, Color(1, 1, 1, 0.45), 1.0)

	if mode == Mode.EDGE:
		var edges := sel_edges.duplicate()
		if is_input_view and hover_edge.x >= 0 and not hover_edge in edges:
			edges.append(hover_edge)
		for e in edges:
			if e.x < verts.size() and e.y < verts.size():
				_line3d(overlay, camera, xf * verts[e.x], xf * verts[e.y], SEL_COLOR if e in sel_edges else Color.WHITE, 3.0)
	elif mode == Mode.FACE:
		for f in sel_faces:
			if f >= b.get_face_count():
				continue
			var ids := b.get_face_vertex_ids(f)
			for k in ids.size():
				_line3d(overlay, camera, xf * verts[ids[k]], xf * verts[ids[(k + 1) % ids.size()]], SEL_COLOR, 2.0)

	if mode == Mode.VERTEX:
		if _dense(b):
			_wire(b, xf, Color.WHITE, true)
		else:
			for i in verts.size():
				var w := xf * verts[i]
				if not camera.is_position_behind(w):
					var p := camera.unproject_position(w)
					overlay.draw_circle(p, 3.5, Color(0.1, 0.1, 0.1))
					overlay.draw_circle(p, 2.5, Color.WHITE)
	for i in sel_verts:
		var w := xf * verts[i] if i < verts.size() else Vector3.ZERO
		if i < verts.size() and not camera.is_position_behind(w):
			overlay.draw_circle(camera.unproject_position(w), 5.0 if mode == Mode.VERTEX else 3.5, SEL_COLOR)
	if is_input_view and hover_vert >= 0 and hover_vert < verts.size() and not camera.is_position_behind(xf * verts[hover_vert]):
		overlay.draw_arc(camera.unproject_position(xf * verts[hover_vert]), 8.0, 0.0, TAU, 16, Color.WHITE, 1.5)


func _fill_face(overlay: Control, camera: Camera3D, b: LevelBrush, xf: Transform3D, face: int, color: Color) -> void:
	var pts := b.get_face_points(face)
	var n := PolyUtil.newell_normal(pts)
	if n == Vector3.ZERO:
		return
	var tris := PolyUtil.triangulate(pts, n)
	var colors := PackedColorArray([color, color, color])
	for t in range(0, tris.size(), 3):
		var tri := PackedVector2Array()
		for k in 3:
			var w := xf * pts[tris[t + k]]
			if camera.is_position_behind(w):
				break
			tri.append(camera.unproject_position(w))
		if tri.size() == 3:
			overlay.draw_primitive(tri, colors, PackedVector2Array())


func _draw_gizmo(overlay: Control, camera: Camera3D, is_input_view: bool) -> void:
	var center = _gizmo_center()
	if center == null or camera.is_position_behind(center):
		return
	var cs := camera.unproject_position(center)
	var length := _gizmo_length(camera, center)
	for a in 3:
		var tip: Vector3 = center + AXES[a] * length
		if camera.is_position_behind(tip):
			continue
		var ts := camera.unproject_position(tip)
		var active := (drag == Drag.AXIS_X + a) or (is_input_view and drag == Drag.NONE and hover_handle == Drag.AXIS_X + a)
		var color: Color = AXIS_COLORS[a].lightened(0.45) if active else AXIS_COLORS[a]
		overlay.draw_line(cs, ts, color, 4.0 if active else 2.5, true)
		overlay.draw_circle(ts, 6.0 if active else 4.5, color)
	var plane_active := drag == Drag.PLANE_XZ or (is_input_view and drag == Drag.NONE and hover_handle == Drag.PLANE_XZ)
	var sq := Rect2(cs - Vector2(6, 6), Vector2(12, 12))
	overlay.draw_rect(sq, Color(1, 1, 1, 0.9) if plane_active else Color(1, 1, 1, 0.55))
	overlay.draw_rect(sq, Color(0, 0, 0, 0.6), false, 1.0)
	if is_input_view and drag in [Drag.AXIS_X, Drag.AXIS_Y, Drag.AXIS_Z, Drag.PLANE_XZ]:
		var label := "Δ (%.2f, %.2f, %.2f)" % [drag_delta.x, drag_delta.y, drag_delta.z]
		if drag_extruded:
			label = "Extrude " + label
		_draw_label(overlay, mouse_pos + Vector2(16, -12), label)


func _draw_label(overlay: Control, pos: Vector2, text: String) -> void:
	var font := ThemeDB.fallback_font
	overlay.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, 4, Color(0, 0, 0, 0.8))
	overlay.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
