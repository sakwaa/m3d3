@tool
extends EditorPlugin
## Actor tools: the ActorModel node (a character scene's root), its pose gizmo, the tool
## strip in the 3D view (tool options in the inspector), and the export step that ships
## only the built skeleton + mesh.

const Gizmo := preload("res://addons/n64_actor_tools/actor_gizmo.gd")
const ActorEditor := preload("res://addons/n64_actor_tools/actor_editor.gd")
const Toolbar := preload("res://addons/n64_actor_tools/ui/actor_toolbar.gd")
const Inspector := preload("res://addons/n64_actor_tools/ui/actor_inspector.gd")
const Backdrop := preload("res://addons/n64_actor_tools/actor_backdrop.gd")
const Export := preload("res://addons/n64_actor_tools/export/actor_export_plugin.gd")
const Timeline := preload("res://addons/n64_actor_tools/ui/actor_timeline.gd")
const ViewSnap := preload("res://addons/n64_actor_tools/view_snap.gd")
const ViewAids := preload("res://addons/n64_actor_tools/editor_view_aids.gd")
const RefPanel := preload("res://addons/n64_actor_tools/ui/actor_reference_panel.gd")
const RefMeta := preload("res://addons/n64_actor_tools/actor_references.gd").META
const Blender := preload("res://addons/n64_actor_tools/actor_blender.gd")

var _gizmo: EditorNode3DGizmoPlugin
var editor: ActorEditor
var _toolbar: Toolbar
var _toolbar_in_viewport := false
var _inspector: EditorInspectorPlugin
## Editor-only backdrop on the open character scene (VIEW section of the strip).
var _backdrop: Node3D
var _export: EditorExportPlugin
## Project > Tools > M3D World: "New <body plan> Character…" items (ids 100+).
var _menu_ids := {}  # id -> body plan id
var _new_plan: StringName
var _char_dialog: EditorFileDialog
var timeline: Control
var _timeline_button: Button
## Makes rotation-gizmo axis clicks honour Auto Orthogonal (view_snap.gd).
var _view_snap: Node
## Reference images + ortho grid on the open character scene, and their panel.
var _aids: ViewAids
var _ref_panel: RefPanel
var grid_on := true
## Character editor v2: geometry edited in Blender.
var blender: Blender
## The character being made goes straight to Blender (World menu "… (Blender)").
var _new_in_blender := false
var _blender_confirm: ConfirmationDialog


func _enter_tree() -> void:
	_gizmo = Gizmo.new()
	_gizmo.plugin = self
	add_node_3d_gizmo_plugin(_gizmo)
	editor = ActorEditor.new()
	editor.plugin = self
	# A new tool shows its options: the inspector rebuilds for the model.
	editor.tool_changed.connect(func(): if editor.model: editor.model.notify_property_list_changed())
	_inspector = Inspector.new()
	_inspector.editor = editor
	add_inspector_plugin(_inspector)
	_toolbar = Toolbar.new()
	_toolbar.visible = false
	_attach_toolbar()
	_toolbar.setup(editor, Vector2(12, 44) * EditorInterface.get_editor_scale())
	editor.backdrop = EditorInterface.get_editor_settings().get_project_metadata("n64_actor_tools", "backdrop", Backdrop.Kind.STUDIO)
	scene_changed.connect(apply_backdrop.unbind(1))
	apply_backdrop.call_deferred()
	_export = Export.new()
	add_export_plugin(_export)
	_hook_world_menu.call_deferred()
	timeline = Timeline.new()
	timeline.plugin = self
	_timeline_button = add_control_to_bottom_panel(timeline, "Actor Animation")
	set_force_draw_over_forwarding_enabled()
	# Reference image handles take clicks whatever is selected (the character tools
	# below still only act while the ActorModel is edited).
	set_input_event_forwarding_always_enabled()
	_view_snap = ViewSnap.new()
	add_child(_view_snap)
	grid_on = EditorInterface.get_editor_settings().get_project_metadata("n64_actor_tools", "ortho_grid", true)
	_ref_panel = RefPanel.new()
	_ref_panel.on_grid = set_grid
	EditorInterface.get_base_control().add_child(_ref_panel)
	scene_changed.connect(apply_view_aids.unbind(1))
	apply_view_aids.call_deferred()
	blender = Blender.new()
	blender.plugin = self
	add_child(blender)


func _exit_tree() -> void:
	remove_node_3d_gizmo_plugin(_gizmo)
	editor.set_model(null)
	if _backdrop and is_instance_valid(_backdrop):
		_backdrop.queue_free()
	remove_inspector_plugin(_inspector)
	if not _toolbar_in_viewport:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, _toolbar)
	_toolbar.queue_free()
	remove_export_plugin(_export)
	_unhook_world_menu()
	if _char_dialog:
		_char_dialog.queue_free()
	remove_control_from_bottom_panel(timeline)
	timeline.queue_free()
	_view_snap.queue_free()
	_ref_panel.queue_free()
	blender.queue_free()
	if _blender_confirm:
		_blender_confirm.queue_free()
	if _aids and is_instance_valid(_aids):
		_aids.queue_free()


## Puts the chosen backdrop on the open scene when it's a character (and only there).
func apply_backdrop() -> void:
	var root := EditorInterface.get_edited_scene_root() as ActorModel
	if _backdrop and is_instance_valid(_backdrop):
		if root and _backdrop.get_parent() == root:
			_backdrop.set_kind(editor.backdrop)
			return
		_backdrop.queue_free()
	_backdrop = null
	if root == null:
		return
	_backdrop = Backdrop.new()
	root.add_child(_backdrop, false, Node.INTERNAL_MODE_BACK)
	_backdrop.setup(root, editor.backdrop)


## Puts the reference images / ortho grid on the open scene when it's a character.
func apply_view_aids() -> void:
	var root := EditorInterface.get_edited_scene_root() as ActorModel
	if _aids and is_instance_valid(_aids):
		if root and _aids.get_parent() == root:
			return
		_aids.queue_free()
	_aids = null
	_ref_panel.aids = null
	if root == null:
		return
	_aids = ViewAids.new()
	root.add_child(_aids, false, Node.INTERNAL_MODE_BACK)
	_aids.setup(root)
	_aids.grid_on = grid_on
	_aids.edited.connect(_ref_undo)
	_aids.redraw.connect(update_overlays)
	_aids.view_changed.connect(func(_v):
		if _ref_panel.visible:
			_ref_panel.refresh()
		update_overlays())
	_ref_panel.aids = _aids


func open_reference_panel(at: Rect2i) -> void:
	if _aids and is_instance_valid(_aids):
		_ref_panel.open_at(at, grid_on)


func set_grid(on: bool) -> void:
	grid_on = on
	EditorInterface.get_editor_settings().set_project_metadata("n64_actor_tools", "ortho_grid", on)
	if _aids and is_instance_valid(_aids):
		_aids.grid_on = on


## A finished reference change (already applied) as one undo step on the model's metadata.
func _ref_undo(before: Dictionary, label: String) -> void:
	var model := _aids.model
	var ur := get_undo_redo()
	ur.create_action(label, UndoRedo.MERGE_DISABLE, model)
	for step in [[true, _aids.snapshot()], [false, before]]:
		var refs: Dictionary = step[1]
		var args := [&"remove_meta", RefMeta] if refs.is_empty() else [&"set_meta", RefMeta, refs]
		if step[0]:
			ur.add_do_method.callv([model] + args)
			ur.add_do_method(self, &"_reload_aids")
		else:
			ur.add_undo_method.callv([model] + args)
			ur.add_undo_method(self, &"_reload_aids")
	ur.commit_action(false)
	update_overlays()


func _reload_aids() -> void:
	if _aids and is_instance_valid(_aids):
		_aids.reload()
		if _ref_panel.visible:
			_ref_panel.refresh()
		update_overlays()


## Floats the tool strip over the 3D view like the level tools' strip:
## Node3DEditorViewport > [SubViewportContainer > SubViewport, input surface]; the strip
## goes last so it sits above the surface and gets clicks.
func _attach_toolbar() -> void:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var container := vp.get_parent() if vp else null
	var host := container.get_parent() if container else null
	if host is Control:
		host.add_child(_toolbar)
		_toolbar_in_viewport = true
	else:
		add_control_to_container(CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, _toolbar)


## Adds the character items to the level tools' M3D World menu (after it exists).
func _hook_world_menu() -> void:
	var menu := Engine.get_meta(&"n64_world_menu") as PopupMenu if Engine.has_meta(&"n64_world_menu") else null
	if menu == null:
		return
	menu.add_separator("Characters")
	var ids := BodyPlan.all().keys()
	ids.sort()
	for i in ids.size():
		menu.add_item("New %s Character…" % BodyPlan.find(ids[i]).display_name(), 100 + i)
		_menu_ids[100 + i] = ids[i]
	for i in ids.size():
		menu.add_item("New %s Character (Blender)…" % BodyPlan.find(ids[i]).display_name(), 200 + i)
		_menu_ids[200 + i] = ids[i]
	menu.id_pressed.connect(_on_world_menu)


func _unhook_world_menu() -> void:
	var menu := Engine.get_meta(&"n64_world_menu") as PopupMenu if Engine.has_meta(&"n64_world_menu") else null
	if menu == null or not is_instance_valid(menu):
		return
	if menu.id_pressed.is_connected(_on_world_menu):
		menu.id_pressed.disconnect(_on_world_menu)
	for id in _menu_ids:
		var idx := menu.get_item_index(id)
		if idx >= 0:
			menu.remove_item(idx)
	# The separator before them.
	if menu.item_count > 0 and menu.is_item_separator(menu.item_count - 1):
		menu.remove_item(menu.item_count - 1)


func _on_world_menu(id: int) -> void:
	if not _menu_ids.has(id):
		return
	_new_plan = _menu_ids[id]
	_new_in_blender = id >= 200
	if _char_dialog == null:
		_char_dialog = EditorFileDialog.new()
		_char_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_char_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		_char_dialog.add_filter("*.tscn", "Character scene")
		_char_dialog.file_selected.connect(_create_character)
		EditorInterface.get_base_control().add_child(_char_dialog)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://characters"))
	_char_dialog.title = "New %s Character" % BodyPlan.find(_new_plan).display_name()
	_char_dialog.current_dir = "res://characters"
	_char_dialog.current_file = "new_%s.tscn" % _new_plan
	_char_dialog.popup_file_dialog()


## A character scene: an ActorModel root (named after the file) with the chosen body plan,
## saved and opened, ready for Pose / Model / Paint and the Actor Animation timeline.
func _create_character(path: String) -> void:
	if FileAccess.file_exists(path):
		push_error("M3D World: %s already exists; pick another name." % path)
		return
	var model := ActorModel.new()
	model.name = path.get_file().get_basename().to_pascal_case()
	var data := ActorModelData.new()
	data.plan = _new_plan
	model.data = data
	var packed := PackedScene.new()
	var err := packed.pack(model)
	model.free()
	if err == OK:
		err = ResourceSaver.save(packed, path)
	if err != OK:
		push_error("M3D World: can't save %s (%s)." % [path, error_string(err)])
		return
	EditorInterface.get_resource_filesystem().scan()
	EditorInterface.open_scene_from_path(path)
	if _new_in_blender:
		_to_blender.call_deferred(path)


## The tool strip's Blender button: opens the character's .blend, or first moves its
## geometry into one (after asking).
func blender_button() -> void:
	var model := editor.model
	if model == null:
		return
	if model.data.blend_file != "":
		blender.open_blender(model)
		return
	if _blender_confirm == null:
		_blender_confirm = ConfirmationDialog.new()
		_blender_confirm.title = "Move Geometry to Blender"
		_blender_confirm.ok_button_text = "Move to Blender"
		_blender_confirm.confirmed.connect(func(): blender.create(editor.model))
		EditorInterface.get_base_control().add_child(_blender_confirm)
	_blender_confirm.dialog_text = ("Make characters/blend/%s.blend from %s's pieces and open it in Blender?\n\n" +
		"Geometry is then edited in Blender: save there and the character updates here. Stitching, pins, " +
		"paint and posing stay in Godot. Undo (or Unlink in the Piece options) goes back to the built-in tools.") % [
		model.scene_file_path.get_file().get_basename(), model.name]
	_blender_confirm.popup_centered()


## A new character's base, straight into a .blend (opened in Blender).
func _to_blender(path: String) -> void:
	var root := EditorInterface.get_edited_scene_root() as ActorModel
	if root and root.scene_file_path == path:
		blender.create(root)
		EditorInterface.save_scene()


func _handles(object: Object) -> bool:
	return object is ActorModel


func _edit(object: Object) -> void:
	editor.set_model(object as ActorModel)
	timeline.set_model(object as ActorModel)
	if object:
		make_bottom_panel_item_visible(timeline)


func _make_visible(visible: bool) -> void:
	_toolbar.visible = visible
	if visible:
		_toolbar.refresh()


## Model / Paint tools in the 3D view (Blender-like):
##  - click picks a vertex / edge / face (by tool; through the mesh in wireframe /
##    X-ray), Shift adds / removes, Ctrl / Cmd selects the shortest path from the last
##    picked one, L (or the Piece tool) picks the whole piece under the mouse, empty
##    space clears;
##  - drag on empty space box-selects (Shift adds);
##  - 1 / 2 / 3 vertex / edge / face, Alt+Z X-ray, Shift+Z wireframe, A all, Alt+A none,
##    Esc cancels pin picking;
##  - paint tools: brush strokes / fills (UVs & Slots selects faces instead).
## Clicks on handles are left to the gizmo.
var _press := Vector2.INF
var _mouse := Vector2.ZERO
var _box := Rect2()
var _boxing := false
var _stroke_before: Array = []
var _painting := false


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	var model := editor.model
	if _aids and is_instance_valid(_aids):
		var was := _aids.adjusting
		if _aids.gui_input(camera, event):
			update_overlays()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		var dc := event as InputEventMouseButton
		if not was and dc and dc.double_click and dc.button_index == MOUSE_BUTTON_LEFT and not dc.alt_pressed \
				and not (model and _on_handle(model, camera, dc.position)) and _aids.try_select(camera, dc.position):
			_press = Vector2.INF
			update_overlays()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	if model == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if model.mode == ActorModel.Mode.POSE:
		return _pose_input(model, camera, event)
	if event is InputEventMouse:
		_mouse = event.position
	var key := event as InputEventKey
	if key and key.pressed and not key.echo:
		return _key(model, camera, key)
	if editor.paints():
		return _paint_input(model, camera, event)
	if editor.tool == ActorEditor.Tool.LOOP_CUT:
		return _cut_input(model, camera, event)
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			if mb.alt_pressed or _on_handle(model, camera, mb.position):
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			_press = mb.position
			_boxing = false
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if _press == Vector2.INF:
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		if _boxing:
			_box_select(model, camera, _box, mb.shift_pressed)
		else:
			var path := (mb.ctrl_pressed or mb.meta_pressed) and editor.tool != ActorEditor.Tool.PIECE
			_click(model, camera, mb.position, mb.shift_pressed, editor.tool == ActorEditor.Tool.PIECE, path)
		_press = Vector2.INF
		_boxing = false
		update_overlays()
		editor.refreshed.emit()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	var mm := event as InputEventMouseMotion
	if mm and _press != Vector2.INF and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
		if _boxing or mm.position.distance_to(_press) > 4.0:
			_boxing = true
			_box = Rect2(_press, Vector2.ZERO).expand(mm.position)
			update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS


## Rig tools: clicks on a handle go to the gizmo (drag to pose); a click that misses
## (or a box drag) is eaten, so it can't fall through to the editor's selection and
## deselect the character (its mesh is internal, so a click on it selects nothing).
var _pose_eating := false


func _pose_input(model: ActorModel, camera: Camera3D, event: InputEvent) -> int:
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_pose_eating = not mb.alt_pressed and not _on_handle(model, camera, mb.position)
			return EditorPlugin.AFTER_GUI_INPUT_STOP if _pose_eating else EditorPlugin.AFTER_GUI_INPUT_PASS
		if _pose_eating:
			_pose_eating = false
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event is InputEventMouseMotion and _pose_eating:
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	_draw_cut(overlay)
	if _aids and is_instance_valid(_aids):
		_aids.draw(overlay, _aids.camera)
	if _boxing:
		overlay.draw_rect(_box, Color(1, 1, 1, 0.08))
		overlay.draw_rect(_box, Color(1, 1, 1, 0.7), false, 1.0)
	var model := editor.model
	if model and model.mode == ActorModel.Mode.PAINT and editor.uses_brush():
		var mp := overlay.get_local_mouse_position()
		overlay.draw_arc(mp, editor.radius, 0.0, TAU, 32, Color(1, 1, 1, 0.8), 1.0)


func _key(model: ActorModel, camera: Camera3D, key: InputEventKey) -> int:
	match key.keycode:
		KEY_1, KEY_2, KEY_3:
			if key.alt_pressed or key.ctrl_pressed or key.meta_pressed:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			editor.set_tool([ActorEditor.Tool.VERTEX, ActorEditor.Tool.EDGE, ActorEditor.Tool.FACE][key.keycode - KEY_1])
		KEY_ESCAPE:
			if not editor.pin_picking:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			editor.pin_picking = false
		KEY_Z:
			if key.alt_pressed:
				model.display = ActorModel.Display.SOLID if model.display == ActorModel.Display.XRAY else ActorModel.Display.XRAY
			elif key.shift_pressed:
				model.display = ActorModel.Display.SOLID if model.display == ActorModel.Display.WIREFRAME else ActorModel.Display.WIREFRAME
			else:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
		KEY_L:
			if key.alt_pressed or key.ctrl_pressed or key.meta_pressed:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			_click(model, camera, _mouse, key.shift_pressed, true)
			update_overlays()
		KEY_A:
			if key.ctrl_pressed or key.meta_pressed:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			if key.alt_pressed:
				model.clear_elements()
			else:
				_select_all(model)
		_:
			return EditorPlugin.AFTER_GUI_INPUT_PASS
	editor.refreshed.emit()
	return EditorPlugin.AFTER_GUI_INPUT_STOP


## Within the editor's own handle pick radius (EditorNode3DGizmo, ~9.5 px).
func _on_handle(model: ActorModel, camera: Camera3D, pos: Vector2) -> bool:
	for h in _gizmo.handle_points(model):
		var world: Vector3 = model.global_transform * h
		if not camera.is_position_behind(world) and camera.unproject_position(world).distance_to(pos) < 9.0:
			return true
	return false


# --- Picking ------------------------------------------------------------------------------

func _visible(model: ActorModel, camera: Camera3D, p: Vector3) -> bool:
	return ActorPick.visible(model, camera, p)


func _elements(model: ActorModel, camera: Camera3D, kind: int, only_piece := -1) -> Array:
	return ActorPick.elements(model, camera, kind, only_piece)


func _click(model: ActorModel, camera: Camera3D, pos: Vector2, add: bool, whole: bool, path := false) -> void:
	if editor.pin_picking:
		var inv0 := model.global_transform.affine_inverse()
		var h := model.pick(inv0 * camera.project_ray_origin(pos), (inv0.basis * camera.project_ray_normal(pos)).normalized())
		editor.pin_to(h.piece if not h.is_empty() else -1)
		return
	var piece := -1
	var id: Variant = null
	if model.select_mode == ActorModel.Select.FACE or whole:
		var inv := model.global_transform.affine_inverse()
		var hit := model.pick(inv * camera.project_ray_origin(pos), (inv.basis * camera.project_ray_normal(pos)).normalized())
		if not hit.is_empty():
			piece = hit.piece
			id = hit.face
	else:
		var best := 12.0 if model.select_mode == ActorModel.Select.VERTEX else 10.0
		for e in _elements(model, camera, model.select_mode):
			if e.behind:
				continue
			var d: float = e.screen.distance_to(pos) if model.select_mode == ActorModel.Select.VERTEX \
				else pos.distance_to(Geometry2D.get_closest_point_to_segment(pos, e.sa, e.sb))
			if d < best and _visible(model, camera, e.at):
				best = d
				piece = e.piece
				id = e.id
	if piece < 0:
		if not add:
			model.clear_selection()
		return
	if path and piece == model.sel_piece and _extend_path(model, id):
		model.update_gizmos()
		return
	if piece != model.sel_piece:
		model.sel_piece = piece
		model.clear_elements()
	elif not add and not path:
		model.clear_elements()
	if whole:
		model.clear_elements()
	elif path:
		var list: Array = [model.sel_verts, model.sel_edges, model.sel_faces][model.select_mode]
		list.erase(id)
		list.append(id)
	else:
		_toggle(model, id)
	model.update_gizmos()


## Ctrl+click: adds the shortest path from the last picked element to `id` (which
## becomes the last, so clicks chain). False when there's nothing to start from.
func _extend_path(model: ActorModel, id: Variant) -> bool:
	var list: Array = [model.sel_verts, model.sel_edges, model.sel_faces][model.select_mode]
	if list.is_empty() or list.back() == id:
		return false
	var route := ActorPieceOps.shortest_path(model.selected_piece(), model.select_mode, list.back(), id)
	if route.is_empty():
		return false
	for e in route:
		list.erase(e)
		list.append(e)
	return true


func _toggle(model: ActorModel, id: Variant) -> void:
	var list: Array = [model.sel_verts, model.sel_edges, model.sel_faces][model.select_mode]
	if list.has(id):
		list.erase(id)
	else:
		list.append(id)


func _box_select(model: ActorModel, camera: Camera3D, rect: Rect2, add: bool) -> void:
	var hits := {}  # piece -> ids
	for e in _elements(model, camera, model.select_mode, model.sel_piece):
		if e.behind or not rect.has_point(e.screen):
			continue
		if model.select_mode == ActorModel.Select.EDGE and not (rect.has_point(e.sa) and rect.has_point(e.sb)):
			continue
		if not _visible(model, camera, e.at):
			continue
		if not hits.has(e.piece):
			hits[e.piece] = []
		if not hits[e.piece].has(e.id):
			hits[e.piece].append(e.id)
	if hits.is_empty():
		if not add:
			model.clear_elements()
		return
	# One piece at a time: the selected one, or the one with the most hits.
	var piece := model.sel_piece
	if not hits.has(piece):
		piece = hits.keys()[0]
		for k in hits:
			if hits[k].size() > hits[piece].size():
				piece = k
	if piece != model.sel_piece:
		model.sel_piece = piece
		model.clear_elements()
	elif not add:
		model.clear_elements()
	if editor.tool == ActorEditor.Tool.PIECE:
		model.update_gizmos()
		return
	var list: Array = [model.sel_verts, model.sel_edges, model.sel_faces][model.select_mode]
	for id in hits[piece]:
		if not list.has(id):
			list.append(id)
	model.update_gizmos()


func _select_all(model: ActorModel) -> void:
	var p := model.selected_piece()
	if p == null:
		return
	model.clear_elements()
	match model.select_mode:
		ActorModel.Select.VERTEX:
			for i in p.vertices.size():
				model.sel_verts.append(i)
		ActorModel.Select.EDGE:
			for poly in p.faces():
				for k in poly.size():
					var e := Vector2i(mini(poly[k], poly[(k + 1) % poly.size()]), maxi(poly[k], poly[(k + 1) % poly.size()]))
					if not model.sel_edges.has(e):
						model.sel_edges.append(e)
		ActorModel.Select.FACE:
			for i in p.faces().size():
				model.sel_faces.append(i)
	model.update_gizmos()


# --- Loop cut ----------------------------------------------------------------------------

## Hovered loop: {piece (source index), ep (the drawn piece: a mirrored copy on the right),
## xf, ring, sa, sb (hovered edge on screen, oriented like the ring)}; empty = none.
var _cut := {}
var _cut_t := 0.5
var _cut_drag := false
var _cut_press := Vector2.ZERO
var _cut_camera: Camera3D
## The tool took the last left press (so it takes the release too). Presses it passes on
## (Alt+drag orbits) must have their release passed on as well, even if Alt is let go
## first, or the editor's navigation never sees the drag end and stays orbiting.
var _cut_owns_press := false
const CUT_COLOR := Color(1.0, 0.85, 0.15)


func _cut_input(model: ActorModel, camera: Camera3D, event: InputEvent) -> int:
	_cut_camera = camera
	var mm := event as InputEventMouseMotion
	var mb := event as InputEventMouseButton
	if mm:
		if _cut_drag:
			var axis: Vector2 = _cut.sb - _cut.sa
			var t := 0.5 + (mm.position - _cut_press).dot(axis) / maxf(axis.length_squared(), 1.0)
			if mm.is_command_or_control_pressed():
				t = snappedf(t, 0.25)
			_cut_t = clampf(t, 0.02, 0.98)
			update_overlays()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if mm.button_mask == 0:
			_cut_hover(model, camera, mm.position)
			update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if mb and mb.pressed and _cut_drag and (mb.button_index == MOUSE_BUTTON_RIGHT):
		_cut_drag = false
		_cut_t = 0.5
		update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if mb and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_cut_owns_press = not mb.alt_pressed
			if not _cut_owns_press:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			if not _cut.is_empty():
				_cut_drag = true
				_cut_press = mb.position
				_cut_t = 0.5
			# Eaten either way: a miss mustn't deselect the character.
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if not _cut_owns_press:
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		_cut_owns_press = false
		if _cut_drag:
			_cut_drag = false
			editor.loop_cut(_cut.piece, _cut.ring, _cut_ts())
			_cut_t = 0.5
			_cut_hover(model, camera, mb.position)
			update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	var key := event as InputEventKey
	if key and key.pressed and key.keycode == KEY_ESCAPE and _cut_drag:
		_cut_drag = false
		_cut_t = 0.5
		update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS


## Slide factors for the current cut: one (slid), or several spaced evenly.
func _cut_ts() -> Array:
	if editor.cut_count <= 1:
		return [_cut_t]
	var ts := []
	for i in editor.cut_count:
		ts.append(float(i + 1) / float(editor.cut_count + 1))
	return ts


## The loop across the visible edge nearest the cursor (any piece).
func _cut_hover(model: ActorModel, camera: Camera3D, pos: Vector2) -> void:
	_cut = {}
	var best := 12.0
	var hit := {}
	for e in _elements(model, camera, ActorModel.Select.EDGE):
		if e.behind:
			continue
		var d := pos.distance_to(Geometry2D.get_closest_point_to_segment(pos, e.sa, e.sb))
		if d < best and _visible(model, camera, e.at):
			best = d
			hit = e
	if hit.is_empty():
		return
	var entries := ActorMannequin.expanded(model, model.data.pieces)
	var ep: ActorPiece = null
	for entry in entries:
		var cand: ActorPiece = entry[0]
		if entry[1] != hit.piece:
			continue
		var xf0 := model.piece_transform(cand)
		if (xf0 * cand.vertices[hit.id.x]).is_equal_approx(hit.a):
			ep = cand
	if ep == null:
		return
	var ring := ActorPieceOps.edge_ring(ep, hit.id)
	var start: Vector2i = hit.id
	var xf := model.piece_transform(ep)
	var to_world := model.global_transform
	_cut = {piece = hit.piece, ep = ep, xf = xf, ring = ring,
		sa = camera.unproject_position(to_world * (xf * ep.vertices[start.x])),
		sb = camera.unproject_position(to_world * (xf * ep.vertices[start.y]))}


func _draw_cut(overlay: Control) -> void:
	var model := editor.model
	if _cut.is_empty() or _cut_camera == null or model == null or editor.tool != ActorEditor.Tool.LOOP_CUT:
		return
	var ep: ActorPiece = _cut.ep
	var xf: Transform3D = _cut.xf
	var to_world := model.global_transform
	var edges: Array = _cut.ring.edges
	for t in _cut_ts():
		var pts := PackedVector2Array()
		for e in edges:
			if e.x >= ep.vertices.size() or e.y >= ep.vertices.size():
				return
			var w: Vector3 = to_world * (xf * ep.vertices[e.x].lerp(ep.vertices[e.y], t))
			if _cut_camera.is_position_behind(w):
				continue
			pts.append(_cut_camera.unproject_position(w))
		if _cut.ring.closed and pts.size() > 2:
			pts.append(pts[0])
		if pts.size() >= 2:
			overlay.draw_polyline(pts, CUT_COLOR, 2.0 * EditorInterface.get_editor_scale(), true)


# --- Paint mode ------------------------------------------------------------------------

func _paint_input(model: ActorModel, camera: Camera3D, event: InputEvent) -> int:
	var mb := event as InputEventMouseButton
	var mm := event as InputEventMouseMotion
	if mm:
		update_overlays()
	if mb and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			# Alt+drag orbits: the press (and later its release) go to the editor.
			if mb.alt_pressed:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			_stroke_before = model.pieces_copy()
			_painting = true
			editor.paint_at(model, camera, mb.position, mb.shift_pressed, true)
		else:
			# Only the release of our own stroke is ours (Alt may be let go before it).
			if not _painting:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			_painting = false
			var ur := get_undo_redo()
			ur.create_action("Paint Actor")
			ur.add_do_property(model.data, &"pieces", model.pieces_copy())
			ur.add_undo_property(model.data, &"pieces", _stroke_before)
			ur.commit_action(false)
			editor.refreshed.emit()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if mm and _painting and mm.button_mask & MOUSE_BUTTON_MASK_LEFT and editor.uses_brush():
		editor.paint_at(model, camera, mm.position, mm.shift_pressed, false)
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS
