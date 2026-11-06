@tool
extends RefCounted
## Editing state for the open ActorModel: the active tool (picked on the viewport
## toolbar), the tool settings (shown in the inspector while the tool is active), and
## every edit the toolbar / inspector run, each one undo step.
## Also runs outside the editor (the iOS mesh builder): with no plugin, edits go through
## its own UndoRedo (see undo_redo(), undo(), redo()).

signal tool_changed
## Selection, pieces or settings changed: the toolbar and options refresh.
signal refreshed

## Toolbar tools. Rig tools pose, model tools edit pieces in the rest pose, paint tools
## paint them.
enum Tool { BODY, POSE, PIECE, VERTEX, EDGE, FACE, LOOP_CUT, TEXTURE, OVERLAY, COLOR_FILL, COLOR_BRUSH, MASK_BRUSH, UV }
enum Blend { MIX, MULTIPLY, LIGHTEN, DARKEN }

const NAMES := {
	Tool.BODY: "Body", Tool.POSE: "Pose", Tool.PIECE: "Piece", Tool.VERTEX: "Vertex",
	Tool.EDGE: "Edge", Tool.FACE: "Face", Tool.LOOP_CUT: "Loop Cut", Tool.TEXTURE: "Texture Fill", Tool.OVERLAY: "Overlay Fill",
	Tool.COLOR_FILL: "Colour Fill", Tool.COLOR_BRUSH: "Colour Brush", Tool.MASK_BRUSH: "Overlay Mask",
	Tool.UV: "UVs & Slots",
}

## The editor plugin (null outside the editor). Untyped: EditorPlugin doesn't exist in
## exported apps.
var plugin
var _local_undo: UndoRedo
var model: ActorModel
var tool := Tool.POSE
## Waiting for a click on the piece to pin the selected vertices to.
var pin_picking := false

## Backdrop kind (actor_backdrop.gd Kind), remembered per project.
var backdrop := 0

# Model tool settings.
## Bone new / copied pieces go on (Piece options).
var piece_bone: StringName
var scale_step := 1.15
## Loop cut: cuts per loop (more than one spaces them evenly, no slide).
var cut_count := 1

# Paint tool settings.
var texture: Texture2D
var overlay: Texture2D
var color := Color(0.85, 0.6, 0.45)
var blend := Blend.MIX
var strength := 0.5
var radius := 40.0
var mirror_paint := true
var uv_step := 0.125
var slot: StringName
var frame_texture: Texture2D
var preview_frame := 0


## The editor's undo history, or (outside the editor) this editor's own.
func undo_redo() -> Object:
	if plugin:
		return plugin.get_undo_redo()
	if _local_undo == null:
		_local_undo = UndoRedo.new()
	return _local_undo


## Outside the editor: forget the undo history (a model was opened / created).
func clear_history() -> void:
	if _local_undo:
		_local_undo.clear_history()


## Outside the editor: step back / forward (the editor has its own shortcuts).
func undo() -> void:
	if _local_undo and _local_undo.has_undo():
		_local_undo.undo()
		refreshed.emit()


func redo() -> void:
	if _local_undo and _local_undo.has_redo():
		_local_undo.redo()
		refreshed.emit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _local_undo:
		_local_undo.free()


## add_do_method / add_undo_method for either undo system (the editor's takes an object
## and method name, the runtime UndoRedo a Callable).
func _ur_method(ur: Object, undo_op: bool, obj: Object, method: StringName) -> void:
	if ur is UndoRedo:
		if undo_op:
			ur.add_undo_method(Callable(obj, method))
		else:
			ur.add_do_method(Callable(obj, method))
	elif undo_op:
		ur.add_undo_method(obj, method)
	else:
		ur.add_do_method(obj, method)


func set_model(m: ActorModel) -> void:
	if model and is_instance_valid(model) and model.data and model.data.changed.is_connected(_on_data_changed):
		model.data.changed.disconnect(_on_data_changed)
	model = m
	pin_picking = false
	if model == null:
		return
	if model.data:
		model.data.changed.connect(_on_data_changed)
	# Keep the tool when it fits the model's mode, else take the mode's default tool.
	if mode_for(tool) != model.mode:
		tool = [Tool.POSE, Tool.FACE, Tool.TEXTURE][model.mode]
	if geometry_locked() and is_model_tool(tool):
		tool = Tool.PIECE
	_apply_tool()
	tool_changed.emit()


func _on_data_changed() -> void:
	refreshed.emit()


static func mode_for(t: Tool) -> ActorModel.Mode:
	if t <= Tool.POSE:
		return ActorModel.Mode.POSE
	if t <= Tool.LOOP_CUT:
		return ActorModel.Mode.MODEL
	return ActorModel.Mode.PAINT


static func is_model_tool(t: Tool) -> bool:
	return mode_for(t) == ActorModel.Mode.MODEL


## Paint tools that paint on click / drag (UV & Slots selects faces instead).
func paints() -> bool:
	return tool >= Tool.TEXTURE and tool <= Tool.MASK_BRUSH


func uses_brush() -> bool:
	return tool == Tool.COLOR_BRUSH or tool == Tool.MASK_BRUSH


func set_tool(t: Tool) -> void:
	if model == null:
		return
	if geometry_locked() and is_model_tool(t):
		t = Tool.PIECE
	var new_mode := mode_for(t)
	if new_mode != ActorModel.Mode.POSE and model.data.pieces.is_empty():
		var ur := undo_redo()
		ur.create_action("Start Modelling")
		ur.add_do_property(model.data, &"pieces", ActorMannequin.starters(model))
		ur.add_undo_property(model.data, &"pieces", model.data.pieces)
		ur.commit_action()
	var crossing := (model.mode == ActorModel.Mode.POSE) != (new_mode == ActorModel.Mode.POSE)
	var old := tool
	tool = t
	pin_picking = false
	if model.mode != new_mode:
		model.mode = new_mode
	if crossing:
		model.clear_selection()
	elif old != t and (t == Tool.PIECE or t == Tool.UV or old == Tool.PIECE or is_model_tool(t)):
		model.clear_elements()
	_apply_tool()
	tool_changed.emit()


func _apply_tool() -> void:
	model.pose_handles = tool == Tool.POSE
	match tool:
		Tool.VERTEX:
			model.select_mode = ActorModel.Select.VERTEX
		Tool.EDGE:
			model.select_mode = ActorModel.Select.EDGE
		_:
			model.select_mode = ActorModel.Select.FACE
	model.update_gizmos()


func set_backdrop(k: int) -> void:
	backdrop = k
	var ei = Engine.get_singleton(&"EditorInterface") if Engine.has_singleton(&"EditorInterface") else null
	if ei:
		ei.get_editor_settings().set_project_metadata("n64_actor_tools", "backdrop", k)
	if plugin:
		plugin.apply_backdrop()
	refreshed.emit()


func set_display(d: ActorModel.Display) -> void:
	if model:
		model.display = d
		refreshed.emit()


## A tool setting changed (no undo: tool settings aren't part of the character).
func set_setting(prop: StringName, value: Variant) -> void:
	set(prop, value)
	refreshed.emit()


# --- Character data ------------------------------------------------------------------------

func set_data(prop: StringName, value: Variant, label := "Actor Settings") -> void:
	if model == null:
		return
	var ur := undo_redo()
	ur.create_action(label, UndoRedo.MERGE_ENDS)
	ur.add_do_property(model.data, prop, value)
	ur.add_undo_property(model.data, prop, model.data.get(prop))
	ur.commit_action()


func set_preview_prop(bone: StringName, scene: PackedScene) -> void:
	var props: Dictionary = model.data.preview_props.duplicate()
	if scene:
		props[bone] = scene
	else:
		props.erase(bone)
	set_data(&"preview_props", props, "Preview Prop")


func set_plan(plan_id: StringName) -> void:
	if model == null or plan_id == model.data.plan:
		return
	var ur := undo_redo()
	ur.create_action("Change Body Plan")
	ur.add_do_property(model.data, &"plan", plan_id)
	ur.add_do_property(model.data, &"pose", {})
	ur.add_do_property(model.data, &"pins", {})
	ur.add_undo_property(model.data, &"plan", model.data.plan)
	ur.add_undo_property(model.data, &"pose", model.data.pose)
	ur.add_undo_property(model.data, &"pins", model.data.pins)
	ur.commit_action()


func set_proportion(param_name: StringName, value: float) -> void:
	var props: Dictionary = model.data.proportions.duplicate()
	props[param_name] = value
	set_data(&"proportions", props, "Actor Proportions")


func set_pin(chain_name: StringName, on: bool) -> void:
	var pins: Dictionary = model.data.pins.duplicate()
	pins[chain_name] = on
	set_data(&"pins", pins, "Pin Limb")


# --- Pose ----------------------------------------------------------------------------------

func reset_pose() -> void:
	_pose_action("Reset Pose", func(): model.reset_pose())


func mirror_pose(from_side: int) -> void:
	_pose_action("Mirror Pose", func(): model.mirror_pose(from_side))


## Rotates bone `i` to `degrees` (its own frame: x / z bend, y twist), one undo step per
## slider drag. Pinned limbs stay planted unless the bone is one of their IK bones.
func rotate_bone(i: int, degrees: Vector3) -> void:
	if model == null or i < 0:
		return
	var bone: StringName = model.bones[i].name
	var targets := model.pinned_targets()
	for c in targets.keys():
		if c.upper == bone or c.lower == bone:
			targets.erase(c)
	_pose_action("Rotate Bone", func():
		model.set_bone_euler(i, degrees)
		model.hold_pins(targets), true)


func reset_bone(i: int) -> void:
	if model and i >= 0:
		rotate_bone(i, Vector3.ZERO)


func _emit_refreshed() -> void:
	refreshed.emit()


func _pose_action(label: String, fn: Callable, merge := false) -> void:
	if model == null:
		return
	var before: Dictionary = model.data.pose.duplicate()
	var before_root := model.data.root_offset
	fn.call()
	var ur := undo_redo()
	ur.create_action(label, UndoRedo.MERGE_ENDS if merge else UndoRedo.MERGE_DISABLE)
	ur.add_do_property(model.data, &"pose", model.data.pose.duplicate())
	ur.add_do_property(model.data, &"root_offset", model.data.root_offset)
	_ur_method(ur, false, model, &"apply_pose")
	ur.add_undo_property(model.data, &"pose", before)
	ur.add_undo_property(model.data, &"root_offset", before_root)
	_ur_method(ur, true, model, &"apply_pose")
	# Undo / redo refresh the rotate sliders too (pose has no changed signal).
	_ur_method(ur, false, self, &"_emit_refreshed")
	_ur_method(ur, true, self, &"_emit_refreshed")
	if plugin and plugin.get(&"timeline"):
		plugin.timeline.add_auto_key_ops(ur)
	ur.commit_action(false)
	refreshed.emit()


# --- Pieces --------------------------------------------------------------------------------

## Character editor v2: the geometry lives in a .blend (ActorModelData.blend_file) and is
## edited in Blender; here only pieces' rigging (stitch, pins) and paint change.
func geometry_locked() -> bool:
	return model != null and model.data != null and model.data.blend_file != ""


## True (with a hint) when a geometry edit has to happen in Blender.
func _in_blender() -> bool:
	if geometry_locked():
		push_warning("N64 Actor Tools: %s's geometry is edited in Blender (%s)." % [model.name, model.data.blend_file])
		return true
	return false


## One undo step around an edit of the pieces (fn mutates model.data.pieces in place).
## Pins on other pieces follow vertices that moved in a topology change.
func edit(label: String, fn: Callable) -> void:
	if model == null:
		return
	var before := model.pieces_copy()
	fn.call()
	for i in mini(before.size(), model.data.pieces.size()):
		var b: ActorPiece = before[i]
		var a: ActorPiece = model.data.pieces[i]
		if b.id == a.id and (b.vertices.size() != a.vertices.size() or b.face_counts != a.face_counts):
			ActorPieceOps.remap_pins_to(model.data.pieces, b, a)
	var ur := undo_redo()
	ur.create_action(label)
	ur.add_do_property(model.data, &"pieces", model.pieces_copy())
	ur.add_undo_property(model.data, &"pieces", before)
	ur.commit_action()
	model.update_gizmos()
	refreshed.emit()


func piece() -> ActorPiece:
	return model.selected_piece() if model else null


func add_piece(bone: StringName, tube: bool) -> void:
	if _in_blender():
		return
	var i := model.bone_index(bone)
	if i < 0:
		push_warning("N64 Actor Tools: pick a bone for the new piece (inspector).")
		return
	var b: BodyPlan.Bone = model.bones[i]
	var r := 0.05
	edit("Add Piece", func():
		var p := ActorPiece.tube(bone, b.length(), r, r * 0.8, 6) if tube else ActorPiece.box(bone, b.length(), r * 2.0, r * 2.0)
		model.data.pieces.append(p)
		model.sel_piece = model.data.pieces.size() - 1
		model.clear_elements())


func shell() -> void:
	var p := _need_piece()
	if p == null or _in_blender():
		return
	edit("Shell Copy", func():
		model.data.pieces.append(ActorPieceOps.shell(p, model.data.model_grid * 2.0, model.data.model_grid))
		model.sel_piece = model.data.pieces.size() - 1
		model.clear_elements())


func copy_to_bone(bone: StringName) -> void:
	var p := _need_piece()
	if p == null or bone == &"" or _in_blender():
		return
	edit("Copy Piece To Bone", func():
		model.data.pieces.append(ActorPieceOps.copy_to_bone(model, p, bone))
		model.sel_piece = model.data.pieces.size() - 1
		model.clear_elements())


func delete_piece() -> void:
	if _need_piece() == null or _in_blender():
		return
	var idx := model.sel_piece
	edit("Delete Piece", func():
		model.data.pieces.remove_at(idx)
		model.clear_selection())


func set_piece_mirror(on: bool) -> void:
	var p := piece()
	if p == null or _in_blender():
		return
	if not on and String(p.bone).ends_with("_L"):
		# Breaking the mirror: the right side becomes its own piece, free to differ.
		edit("Break Mirror", func():
			p.mirror = false
			model.data.pieces.append(p.mirrored(BodyPlan.mirror_name(p.bone))))
	else:
		edit("Piece Mirror", func(): p.mirror = on)


func set_rigid(on: bool) -> void:
	var p := piece()
	if p == null:
		return
	var joints: Dictionary = model.data.rigid_joints.duplicate()
	joints[p.bone] = on
	if String(p.bone).ends_with("_L"):
		joints[BodyPlan.mirror_name(p.bone)] = on
	set_data(&"rigid_joints", joints, "Rigid Joint")


func set_stitch(prop: StringName, value: Variant) -> void:
	var p := piece()
	if p:
		edit("Stitch", func(): p.set(prop, value))


## Arms pin picking: the next click on a piece pins the selected vertices to it.
func start_pin() -> void:
	pin_picking = piece() != null and not pin_picking
	if piece() == null:
		push_warning("N64 Actor Tools: select a piece (or its vertices) to pin first.")
	refreshed.emit()


## Called by the plugin with the piece clicked while picking a pin target.
func pin_to(target: int) -> void:
	pin_picking = false
	refreshed.emit()
	if model == null or piece() == null or target < 0 or target == model.sel_piece:
		return
	var pi := model.sel_piece
	var verts := model.selected_vertices()
	var n := [0]
	edit("Pin Vertices", func(): n[0] = ActorPieceOps.pin_to_nearest(model, pi, verts, target))
	print("[N64 Actor Tools] Pinned %d vertices of %s to %s." % [n[0], model.data.pieces[pi].bone, model.data.pieces[target].bone])


func unpin() -> void:
	var p := _need_piece()
	if p:
		edit("Unpin", func(): ActorPieceOps.unpin(p, model.selected_vertices()))


# --- Moving the selection (drag) ------------------------------------------------------------

var _move_from: ActorPiece
var _move_before: Array

## Starts dragging the selected vertices (or the whole selected piece). False if nothing
## is selected.
func begin_move() -> bool:
	var p := piece()
	if p == null or geometry_locked():
		return false
	_move_from = p.duplicate(true) as ActorPiece
	_move_before = model.pieces_copy()
	return true


## Moves the selection by `delta` (the piece's bone frame) from where the drag started:
## the move snaps to the model grid (a single vertex lands on it; a group keeps its shape).
func update_move(delta: Vector3) -> void:
	if _move_from == null:
		return
	var grid := model.data.model_grid
	var p := _move_from.duplicate(true) as ActorPiece
	var verts := model.selected_vertices()
	ActorPieceOps.move(p, verts, ActorPieceOps.snap_v(delta, grid), grid, verts.size() == 1)
	if p.is_tube():
		p.rebuild_tube_faces()
	model.data.pieces[model.sel_piece] = p
	model.rebuild()


## Rotates the selection (begin_move() first) by `rot` about `pivot`, both model space,
## from where the drag started. `xf` / `mirrored`: the piece as shown (its right-side
## mirror copy when the selection was picked there).
func update_rotate(rot: Basis, pivot: Vector3, xf: Transform3D, mirrored := false) -> void:
	if _move_from == null:
		return
	var p := _move_from.duplicate(true) as ActorPiece
	ActorPieceOps.rotate(p, model.selected_vertices(), rot, pivot, xf, mirrored)
	if p.is_tube():
		p.rebuild_tube_faces()
	model.data.pieces[model.sel_piece] = p
	model.rebuild()


## Ends the drag: one undo step (none if nothing moved).
func end_move() -> void:
	if _move_from == null:
		return
	_move_from = null
	var ur := undo_redo()
	ur.create_action("Move")
	ur.add_do_property(model.data, &"pieces", model.pieces_copy())
	ur.add_undo_property(model.data, &"pieces", _move_before)
	ur.commit_action(false)
	refreshed.emit()


func cancel_move() -> void:
	if _move_from == null:
		return
	_move_from = null
	model.data.pieces = _move_before
	model.rebuild()


# --- Elements ------------------------------------------------------------------------------

func faces_op(label: String, fn: Callable) -> void:
	var p := _need_piece()
	if p == null:
		return
	var faces := model.selected_faces()
	if faces.is_empty():
		push_warning("N64 Actor Tools: no whole faces selected.")
		return
	edit(label, func():
		fn.call(p, faces, model.data.model_grid)
		if model.select_mode != ActorModel.Select.FACE:
			model.clear_elements())


func verts_op(label: String, fn: Callable) -> void:
	var p := _need_piece()
	if p == null:
		return
	edit(label, func():
		fn.call(p, model.selected_vertices(), model.data.model_grid)
		if p.is_tube():
			p.rebuild_tube_faces())


## Extrude: faces out along their normal (face / vertex mode), or open edges outward
## (edge mode), two grid steps; the new part stays selected.
func extrude() -> void:
	var p := _need_piece()
	if p == null:
		return
	var g := model.data.model_grid
	if model.select_mode == ActorModel.Select.EDGE and not model.sel_edges.is_empty():
		var edges: Array[Vector2i] = model.sel_edges.duplicate()
		edit("Extrude Edges", func(): model.sel_edges = ActorPieceOps.extrude_edges(p, edges, g * 2.0, g))
		return
	faces_op("Extrude", func(pp, f, gg):
		var out := ActorPieceOps.extrude(pp, f, gg * 2.0, gg)
		if model.select_mode == ActorModel.Select.FACE:
			model.sel_faces = out)


func subdivide() -> void:
	faces_op("Subdivide", func(p, f, _g): model.sel_faces = ActorPieceOps.subdivide(p, f))


func delete_faces() -> void:
	faces_op("Delete Faces", func(p, f, _g): ActorPieceOps.delete_faces(p, f); model.sel_faces.clear())


func flip_faces() -> void:
	faces_op("Flip Faces", func(p, f, _g): ActorPieceOps.flip(p, f))


## Dissolves the selected vertices (whole selection, or the vertices of selected edges /
## faces): neighbours reconnect, the faces around merge.
func dissolve() -> void:
	var p := _need_piece()
	if p == null or not model.has_selection():
		push_warning("N64 Actor Tools: select vertices to dissolve.")
		return
	var verts := model.selected_vertices()
	edit("Dissolve", func():
		ActorPieceOps.dissolve(p, verts)
		model.clear_elements())


func merge() -> void:
	merge_by(ActorPieceOps.Merge.CENTER)


## Merge the selected vertices (ActorPieceOps.Merge; `point` in piece space for POINT;
## By Distance with nothing selected = the whole piece). Returns how many vertices were
## removed.
func merge_by(mode: ActorPieceOps.Merge, point := Vector3.ZERO) -> int:
	var removed := [0]  # (lambdas capture locals by value)
	verts_op("Merge", func(p, v, g):
		if v.is_empty() and mode == ActorPieceOps.Merge.DISTANCE:
			for i in p.vertices.size():
				v.append(i)
		removed[0] = ActorPieceOps.merge(p, v, mode, g, point)
		model.clear_elements())
	return removed[0]


func inflate(dir: float) -> void:
	verts_op("Inflate" if dir > 0.0 else "Deflate", func(p, v, g): ActorPieceOps.inflate(p, v, g * dir, g))


func scale(up: bool) -> void:
	var f := scale_step if up else 1.0 / scale_step
	verts_op("Scale", func(p, v, g): ActorPieceOps.scale(p, v, Vector3.ONE * f, g))


func conform() -> void:
	var p := _need_piece()
	if p == null:
		return
	var idx := model.sel_piece
	edit("Conform", func():
		ActorPieceOps.conform(model, idx, model.selected_vertices(), model.data.model_grid, model.data.model_grid)
		if p.is_tube():
			p.rebuild_tube_faces())


## Loop cut on piece `pi` (source piece index) through `ring` at the slide factors `ts`.
func loop_cut(pi: int, ring: Dictionary, ts: Array) -> void:
	if model == null or pi < 0 or pi >= model.data.pieces.size() or _in_blender():
		return
	edit("Loop Cut", func():
		ActorPieceOps.loop_cut(model.data.pieces[pi], ring, ts)
		model.sel_piece = pi
		model.clear_elements())


# --- Rings ---------------------------------------------------------------------------------

func selected_tube() -> bool:
	var p := piece()
	return p != null and p.is_tube()


func ring_op(label: String, fn: Callable, needs_ring := false) -> void:
	var p := piece()
	if p == null or not p.is_tube():
		push_warning("N64 Actor Tools: select a tube piece (ring tools).")
		return
	if needs_ring and model.sel_ring < 0:
		push_warning("N64 Actor Tools: drag (or click) a ring handle first to pick the ring.")
		return
	edit(label, func(): fn.call(p, model.sel_ring, model.data.model_grid))


func add_ring() -> void:
	ring_op("Add Ring", func(p, r, g): model.sel_ring = ActorPieceOps.ring_insert(p, maxi(r, 0), g))


func delete_ring() -> void:
	ring_op("Delete Ring", func(p, r, _g): ActorPieceOps.ring_delete(p, r); model.sel_ring = -1, true)


func twist_ring(dir: float) -> void:
	ring_op("Twist Ring", func(p, r, _g): ActorPieceOps.ring_twist(p, r, model.data.angle_step * dir), true)


func tube_sides(delta: int) -> void:
	ring_op("Tube Sides", func(p, _r, _g): ActorPieceOps.set_sides(p, p.sides() + delta))


func _need_piece() -> ActorPiece:
	var p := piece()
	if p == null:
		push_warning("N64 Actor Tools: select a piece first.")
	return p


# --- Paint ---------------------------------------------------------------------------------

## Paint at a screen point (the plugin calls this on press and while dragging; it wraps
## the whole stroke in one undo step).
func paint_at(m: ActorModel, camera: Camera3D, pos: Vector2, shift: bool, first: bool) -> void:
	match tool:
		Tool.TEXTURE, Tool.OVERLAY, Tool.COLOR_FILL:
			if first:
				_fill_click(m, camera, pos, shift)
		Tool.COLOR_BRUSH, Tool.MASK_BRUSH:
			_brush(m, camera, pos, shift)
	m.rebuild()


## Index of `tex` in the character's textures (added if new).
func _texture_index(tex: Texture2D) -> int:
	if tex == null:
		return -1
	var i := model.data.textures.find(tex)
	if i < 0:
		var t := model.data.textures.duplicate()
		t.append(tex)
		model.data.textures = t
		i = t.size() - 1
	return i


func _fill_click(m: ActorModel, camera: Camera3D, pos: Vector2, whole: bool) -> void:
	var inv := m.global_transform.affine_inverse()
	var hit := m.pick(inv * camera.project_ray_origin(pos), (inv.basis * camera.project_ray_normal(pos)).normalized())
	if hit.is_empty():
		return
	var p: ActorPiece = m.data.pieces[hit.piece]
	p.ensure_attributes()
	var faces: Array[int] = []
	if whole:
		for i in p.faces().size():
			faces.append(i)
	else:
		faces = ActorPieceOps.with_twin_faces(p, [hit.face] as Array[int]) if mirror_paint else [hit.face] as Array[int]
	match tool:
		Tool.TEXTURE:
			var ti := _texture_index(texture)
			for f in faces:
				p.face_textures[f] = ti
		Tool.OVERLAY:
			var oi := _texture_index(overlay)
			for f in faces:
				p.face_overlays[f] = oi
		Tool.COLOR_FILL:
			for v in ActorPieceOps.face_vertices(p, faces):
				p.colors[v] = Color(color, p.colors[v].a)


func _brush(m: ActorModel, camera: Camera3D, pos: Vector2, erase: bool) -> void:
	var to_world := m.global_transform
	var mask := tool == Tool.MASK_BRUSH
	for entry in ActorMannequin.expanded(m, m.data.pieces):
		var p: ActorPiece = m.data.pieces[entry[1]]
		var ep: ActorPiece = entry[0]
		p.ensure_attributes()
		var xf := m.piece_transform(ep)
		for v in ep.vertices.size():
			var world: Vector3 = to_world * (xf * ep.vertices[v])
			if camera.is_position_behind(world):
				continue
			var d := camera.unproject_position(world).distance_to(pos)
			if d > radius or not ActorPick.visible(m, camera, xf * ep.vertices[v]):
				continue
			var w := strength * smoothstep(1.0, 0.0, d / radius)
			var targets := [v]
			if mirror_paint and ActorPieceOps.symmetric(p):
				var t := p.twin(v)
				if t >= 0 and t != v:
					targets.append(t)
			for tv in targets:
				var c := p.colors[tv]
				if mask:
					c.a = lerpf(c.a, 0.0 if erase else 1.0, w)
				else:
					var rgb := Color(c.r, c.g, c.b)
					var target := Color.WHITE if erase else _blended(rgb, color)
					rgb = rgb.lerp(target, w)
					c = Color(rgb.r, rgb.g, rgb.b, c.a)
				p.colors[tv] = c


func _blended(base: Color, paint: Color) -> Color:
	match blend:
		Blend.MULTIPLY:
			return base * paint
		Blend.LIGHTEN:
			return Color(maxf(base.r, paint.r), maxf(base.g, paint.g), maxf(base.b, paint.b))
		Blend.DARKEN:
			return Color(minf(base.r, paint.r), minf(base.g, paint.g), minf(base.b, paint.b))
	return paint


# --- UVs & slots (selected faces) ---------------------------------------------------------

## Texture / overlay / clear on the selected faces.
func fill_selection(what: StringName) -> void:
	if _need_piece() == null:
		return
	var ti := _texture_index(texture) if what == &"texture" else -1
	var oi := _texture_index(overlay) if what == &"overlay" else -1
	uv_op("Paint Faces", func(pp, f):
		if what == &"texture":
			pp.face_textures[f] = ti
		elif what == &"overlay":
			pp.face_overlays[f] = oi
		else:
			pp.face_textures[f] = -1
			pp.face_overlays[f] = -1)


## Applies fn(piece, face) to every selected face (mirror twins included on centre pieces).
func uv_op(label: String, fn: Callable) -> void:
	var p := _need_piece()
	if p == null:
		return
	var faces := ActorPieceOps.with_twin_faces(p, model.selected_faces())
	edit(label, func():
		p.ensure_attributes()
		for f in faces:
			fn.call(p, f))


## d: (u offset, v offset, scale factor, quarter turns).
func uv_nudge(d: Vector4) -> void:
	uv_op("Nudge UVs", func(p, f):
		var cur: Vector4 = p.face_uv.get(f, Vector4(0, 0, 1, 0))
		p.face_uv[f] = Vector4(cur.x + d.x, cur.y + d.y, cur.z * d.z, fmod(cur.w + d.w, 4.0)))


func uv_fit() -> void:
	uv_op("Fit Texture", func(p, f): p.face_fit[f] = 0 if p.face_fit.get(f, 0) == 1 else 1)


func uv_reset() -> void:
	uv_op("Reset UVs", func(p, f): p.face_uv.erase(f))


func assign_slot() -> void:
	if slot == &"":
		push_warning("N64 Actor Tools: add / pick a swap slot first (inspector).")
		return
	var s := slot
	uv_op("Assign Slot", func(p, f): p.face_slots[f] = s)


func clear_slot() -> void:
	uv_op("Clear Slot", func(p, f): p.face_slots.erase(f))


func add_slot(slot_name: String) -> void:
	var n := StringName(slot_name.strip_edges().to_snake_case())
	if n == &"" or model.data.swap_slots.has(n):
		return
	var slots: Dictionary = model.data.swap_slots.duplicate(true)
	slots[n] = []
	set_data(&"swap_slots", slots, "Add Swap Slot")
	slot = n


func add_frame() -> void:
	if slot == &"" or frame_texture == null or not model.data.swap_slots.has(slot):
		return
	var slots: Dictionary = model.data.swap_slots.duplicate(true)
	var frames: Array = slots[slot].duplicate()
	frames.append(frame_texture)
	slots[slot] = frames
	set_data(&"swap_slots", slots, "Add Slot Frame")


func show_frame(frame: int) -> void:
	preview_frame = frame
	if model and model.mesh_instance:
		ActorFaces.set_frame(model.mesh_instance, slot, frame)


# --- Info ----------------------------------------------------------------------------------

## {tris, budget, textures, kb, over}
func budget() -> Dictionary:
	var d := model.data
	var bytes := 0
	var used := {}
	for t in d.textures:
		if t and not used.has(t):
			used[t] = true
	for frames in d.swap_slots.values():
		for t in frames:
			if t and not used.has(t):
				used[t] = true
	for t in used:
		if t is N64Texture:
			bytes += N64TextureConverter.tmem_bytes(t.format, t.texture_size)
	return {tris = model.tri_count, budget = d.tri_budget, textures = used.size(), kb = bytes / 1024.0,
		over = model.tri_count > d.tri_budget}


func selection_text() -> String:
	var p := piece()
	if p == null:
		return "Nothing selected: click a piece."
	var kind := "tube, %d rings × %d sides" % [p.rings.size(), p.sides()] if p.is_tube() else "mesh, %d verts" % p.vertices.size()
	var picked := "whole piece"
	if model.has_selection():
		picked = "%d %s" % [[model.sel_verts, model.sel_edges, model.sel_faces][model.select_mode].size(),
			["vertices", "edges", "faces"][model.select_mode]]
	return "%s (%s) · %s%s" % [p.bone, kind, picked, " · ring %d" % model.sel_ring if model.sel_ring >= 0 else ""]
