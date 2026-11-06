@tool
extends EditorNode3DGizmoPlugin
## ActorModel handles in the 3D view.
## Pose mode:
##  - bone ends (small dots): drag to aim the bone (snapped to the angle step); none on
##    IK limbs' lower bones and hands / feet (the IK ring moves those);
##  - IK ends (orange discs, wrists / ankles / paws): drag to place them, the limb
##    bends to follow (on the plane facing the camera, snapped to the grid);
##  - the root (orange disc, at the hips): drag to move the body; pinned limbs stay planted.
## Model mode (rest pose, selected piece):
##  - tubes: a handle per ring centre (move the ring) and per ring rim (resize it);
##  - free meshes: a handle per vertex;
##  - the selection centre (big): drag to move the selected faces (or the whole piece).
## Moves snap to the model grid in the piece's bone frame. Every drag is one undo step.

const ROOT_ID := 100000
const CHAIN_ID := 50000
const RING_ID := 200000
const RIM_ID := 300000
const VERT_ID := 400000
const SEL_ID := 500000

var plugin: EditorPlugin
var _drag_targets := {}
var _drag_plane := Plane()
var _drag_start := Vector3.ZERO
var _snapshot: ActorPiece
## Vertex dots (Vertex tool): screen-sized round dots like Blender's; depth-tested on the
## solid mesh, drawn over everything when seeing through (wireframe / X-ray).
var _dots_mat: ShaderMaterial
var _dots_top_mat: ShaderMaterial

const DOT_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never%s;
uniform float size_px = 8.0;
uniform vec3 rim : source_color = vec3(0.85);
void vertex() {
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view.xyz -= normalize(view.xyz) * 0.01;  // 1 cm toward the camera: off the surface it sits on
	vec4 clip = PROJECTION_MATRIX * view;
	clip.xy += (UV * 2.0 - 1.0) * size_px / VIEWPORT_SIZE * clip.w;
	POSITION = clip;
}
void fragment() {
	float r = length(UV * 2.0 - 1.0);
	if (r > 1.0) {
		discard;
	}
	ALBEDO = r > 0.68 ? rim : COLOR.rgb;
}
"""


func _init() -> void:
	create_material("bones", Color(1.0, 0.85, 0.3), false, true)
	create_material("bones_left", Color(0.45, 0.65, 1.0), false, true)
	create_material("bones_right", Color(1.0, 0.5, 0.45), false, true)
	create_material("bone_selected", Color(1, 1, 1), false, true)
	create_material("piece", Color(1, 1, 1, 0.8), false, true)
	create_material("faces", Color(1.0, 0.75, 0.1), false, true)
	create_material("wire", Color(0.05, 0.05, 0.08, 0.7), false, false)
	create_material("wire_top", Color(0.85, 0.85, 0.9, 0.45), false, true)
	_dots_mat = _dot_material(false)
	_dots_top_mat = _dot_material(true)
	create_handle_material("handles")
	create_handle_material("ik", false, _ring_texture(int(18 * EditorInterface.get_editor_scale()), Color(1.0, 0.6, 0.15)))
	create_material("onion_prev", Color(0.35, 0.6, 1.0, 0.45), false, true)
	create_material("onion_next", Color(0.4, 1.0, 0.5, 0.45), false, true)


func _get_gizmo_name() -> String:
	return "ActorModel"


func _has_gizmo(node: Node3D) -> bool:
	return node is ActorModel


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var model := gizmo.get_node_3d() as ActorModel
	if model == null or model.skeleton == null or model.bones.is_empty():
		return
	if model.mode != ActorModel.Mode.POSE:
		_redraw_model(gizmo, model)
		return
	var lines := {-1: PackedVector3Array(), 0: PackedVector3Array(), 1: PackedVector3Array()}
	for i in model.bones.size():
		var b: BodyPlan.Bone = model.bones[i]
		var pose := model.pose_global(i)
		lines[b.side].append_array([pose.origin, pose * (model.rest_basis(i).inverse() * (b.tail - b.head))])
	_draw_onion(gizmo, model)
	if model.sel_bone >= 0 and model.sel_bone < model.bones.size():
		# Selected bone: a white box around it (lines can't be drawn thicker).
		var i := model.sel_bone
		var b: BodyPlan.Bone = model.bones[i]
		var pose := model.pose_global(i)
		var bone_len := (b.tail - b.head).length()
		var w := clampf(bone_len * 0.12, 0.01, 0.03)
		var box := PackedVector3Array()
		var corners := [Vector3(-w, 0, -w), Vector3(w, 0, -w), Vector3(w, 0, w), Vector3(-w, 0, w)]
		var frame := pose.basis.orthonormalized()
		for k in 4:
			var a: Vector3 = corners[k]
			var c: Vector3 = corners[(k + 1) % 4]
			for y in [0.0, bone_len]:
				box.append_array([pose.origin + frame * (a + Vector3(0, y, 0)), pose.origin + frame * (c + Vector3(0, y, 0))])
			box.append_array([pose.origin + frame * a, pose.origin + frame * (a + Vector3(0, bone_len, 0))])
		gizmo.add_lines(box, get_material("bone_selected", gizmo))
	gizmo.add_lines(lines[0], get_material("bones", gizmo))
	gizmo.add_lines(lines[-1], get_material("bones_left", gizmo))
	gizmo.add_lines(lines[1], get_material("bones_right", gizmo))
	if not model.pose_handles:
		return
	var h := pose_handles(model)
	gizmo.add_handles(h.aim, get_material("handles", gizmo), h.aim_ids)
	gizmo.add_handles(h.ik, get_material("ik", gizmo), h.ik_ids)


## Pose handles (model space): {aim, aim_ids, ik, ik_ids}. Aim dots sit on bone tails,
## except on IK limbs' lower and end bones: their tails are on / next to the IK ring and
## would steal its drags (IK keeps the hand / foot's rotation).
func pose_handles(model: ActorModel) -> Dictionary:
	var out := {aim = PackedVector3Array(), aim_ids = PackedInt32Array(),
		ik = PackedVector3Array([model.pose_global(model.root_index()).origin]), ik_ids = PackedInt32Array([ROOT_ID])}
	var lowers := {}
	for ci in model.chains.size():
		var c: BodyPlan.Chain = model.chains[ci]
		lowers[c.lower] = true
		lowers[c.end] = true
		out.ik.append(model.pose_global(model.bone_index(c.end)).origin)
		out.ik_ids.append(CHAIN_ID + ci)
	for i in model.bones.size():
		var b: BodyPlan.Bone = model.bones[i]
		if i == model.root_index() or lowers.has(b.name):
			continue
		out.aim.append(model.pose_global(i) * (model.rest_basis(i).inverse() * (b.tail - b.head)))
		out.aim_ids.append(i)
	return out


## IK handle texture (IK ends, root): orange discs with a dark centre, so they read apart
## from the aim dots. Kept about dot-sized: the editor only picks handles within ~9.5 px
## of their centre, so a bigger ring would look clickable where it isn't.
static func _ring_texture(size: int, color: Color) -> Texture2D:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var c := (size - 1) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x - c, y - c).length()
			var col := Color(0, 0, 0, 0)
			if d <= c:
				col = Color(0.08, 0.08, 0.08, 0.9)
			if d <= c - 1.5:
				col = color
			if d <= c * 0.3:
				col = Color(0.08, 0.08, 0.08, 0.9)
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


## Onion skin: skeletons of the keys before (blue) and after (green) the playhead.
func _draw_onion(gizmo: EditorNode3DGizmo, model: ActorModel) -> void:
	var a := model.current_animation()
	if a == null or not model.onion or a.keys.size() < 2:
		return
	var f := int(model.frame)
	var prev = null
	var next = null
	for k in a.keys:
		if k.frame < f:
			prev = k
		elif k.frame > f and next == null:
			next = k
	for spec in [[prev, "onion_prev"], [next, "onion_next"]]:
		if spec[0] == null:
			continue
		var g := model.pose_globals(spec[0].pose, spec[0].root)
		var lines := PackedVector3Array()
		for i in model.bones.size():
			var b: BodyPlan.Bone = model.bones[i]
			lines.append_array([g[i].origin, g[i] * (model.rest_basis(i).inverse() * (b.tail - b.head))])
		gizmo.add_lines(lines, get_material(spec[1], gizmo))


func _redraw_model(gizmo: EditorNode3DGizmo, model: ActorModel) -> void:
	# Every piece's edges (both sides): over the mesh in wireframe / X-ray, depth-tested
	# on the solid mesh.
	var wire := PackedVector3Array()
	for entry in ActorMannequin.expanded(model, model.data.pieces):
		var ep: ActorPiece = entry[0]
		var exf := model.piece_transform(ep)
		for poly in ep.faces():
			for k in poly.size():
				wire.append_array([exf * ep.vertices[poly[k]], exf * ep.vertices[poly[(k + 1) % poly.size()]]])
	gizmo.add_lines(wire, get_material("wire_top" if model.sees_through() else "wire", gizmo))
	var p := model.selected_piece()
	if p == null:
		return
	var xf := model.piece_transform(p)
	var edges := PackedVector3Array()
	var sel := PackedVector3Array()
	var f := p.faces()
	for fi in f.size():
		var poly := f[fi]
		for k in poly.size():
			var a := xf * p.vertices[poly[k]]
			var b := xf * p.vertices[poly[(k + 1) % poly.size()]]
			edges.append_array([a, b])
			if model.select_mode == ActorModel.Select.FACE and model.sel_faces.has(fi):
				sel.append_array([a, b])
	if model.select_mode == ActorModel.Select.EDGE:
		for e in model.sel_edges:
			sel.append_array([xf * p.vertices[e.x], xf * p.vertices[e.y]])
	gizmo.add_lines(edges, get_material("piece", gizmo))
	if not sel.is_empty():
		gizmo.add_lines(sel, get_material("faces", gizmo))
	if model.select_mode == ActorModel.Select.VERTEX:
		var pts := PackedVector3Array()
		var cols := PackedColorArray()
		for v in p.vertices.size():
			pts.append(xf * p.vertices[v])
			var col := Color(0.02, 0.02, 0.02)
			if p.pins.has(v):
				col = Color(0.2, 0.9, 1.0)  # pinned
			if model.sel_verts.has(v):
				col = Color(1.0, 0.55, 0.05)  # Blender's selected orange
			cols.append(col)
		gizmo.add_mesh(_dots_mesh(pts, cols), _dots_top_mat if model.sees_through() else _dots_mat)
	if model.mode != ActorModel.Mode.MODEL:
		return
	var hpts := PackedVector3Array()
	var ids := PackedInt32Array()
	if p.is_tube():
		for r in p.rings.size():
			hpts.append(xf * p.ring_centre(r))
			ids.append(RING_ID + r)
			hpts.append(xf * p.vertices[p.rings[r][0]])
			ids.append(RIM_ID + r)
	if not hpts.is_empty():
		gizmo.add_handles(hpts, get_material("handles", gizmo), ids)
	var verts := model.selected_vertices()
	if not verts.is_empty():
		gizmo.add_handles(PackedVector3Array([xf * ActorPieceOps.centre(p, verts)]), get_material("ik", gizmo), PackedInt32Array([SEL_ID]))


## One camera-facing quad per point (the dot shader sizes it in pixels).
static func _dots_mesh(pts: PackedVector3Array, cols: PackedColorArray) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var idx := PackedInt32Array()
	for i in pts.size():
		var base := verts.size()
		for uv in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
			verts.append(pts[i])
			uvs.append(uv)
			colors.append(cols[i])
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Quads collapse to points: keep them from being culled as zero-size.
	m.custom_aabb = AABB(Vector3.ONE * -10.0, Vector3.ONE * 20.0)
	return m


static func _dot_material(on_top: bool) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = DOT_SHADER % (", depth_test_disabled" if on_top else "")
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter(&"size_px", 8.0 * EditorInterface.get_editor_scale())
	mat.render_priority = 10
	return mat


## Every handle position (model space), for click tests that shouldn't steal handle drags.
func handle_points(model: ActorModel) -> PackedVector3Array:
	var out := PackedVector3Array()
	if model.mode == ActorModel.Mode.POSE:
		if not model.pose_handles:
			return out
		var h := pose_handles(model)
		out.append_array(h.ik)
		out.append_array(h.aim)
		return out
	var p := model.selected_piece()
	if model.mode != ActorModel.Mode.MODEL or p == null:
		return out
	var xf := model.piece_transform(p)
	if p.is_tube():
		for r in p.rings.size():
			out.append(xf * p.ring_centre(r))
			out.append(xf * p.vertices[p.rings[r][0]])
	var verts := model.selected_vertices()
	if not verts.is_empty():
		out.append(xf * ActorPieceOps.centre(p, verts))
	return out


func _get_handle_name(gizmo: EditorNode3DGizmo, id: int, _secondary: bool) -> String:
	var model := gizmo.get_node_3d() as ActorModel
	if id >= SEL_ID:
		return "Move selection"
	if id >= VERT_ID:
		return "Vertex %d" % (id - VERT_ID)
	if id >= RIM_ID:
		return "Ring %d size" % (id - RIM_ID)
	if id >= RING_ID:
		return "Ring %d" % (id - RING_ID)
	if id == ROOT_ID:
		return "Root (move body)"
	if id >= CHAIN_ID:
		return "IK %s" % model.chains[id - CHAIN_ID].name
	return "Aim %s" % model.bones[id].name


## Restore value for undo: the pose, or the piece being edited.
func _get_handle_value(gizmo: EditorNode3DGizmo, id: int, _secondary: bool) -> Variant:
	var model := gizmo.get_node_3d() as ActorModel
	_drag_plane = Plane()
	if id >= RING_ID:
		_snapshot = model.selected_piece().duplicate(true)
		if id < RIM_ID:
			model.sel_ring = id - RING_ID
		elif id < VERT_ID:
			model.sel_ring = id - RIM_ID
		return model.sel_piece
	_drag_targets = model.pinned_targets()
	# Grabbing a handle picks its bone for the Pose options' rotate sliders.
	if id == ROOT_ID:
		model.sel_bone = model.root_index()
	elif id >= CHAIN_ID:
		model.sel_bone = model.bone_index(model.chains[id - CHAIN_ID].end)
	else:
		model.sel_bone = id
	if plugin.get(&"editor"):
		plugin.editor.refreshed.emit()
	return [model.data.pose.duplicate(), model.data.root_offset]


func _set_handle(gizmo: EditorNode3DGizmo, id: int, _secondary: bool, camera: Camera3D, screen_pos: Vector2) -> void:
	var model := gizmo.get_node_3d() as ActorModel
	var to_local := model.global_transform.affine_inverse()
	var origin := to_local * camera.project_ray_origin(screen_pos)
	var dir := (to_local.basis * camera.project_ray_normal(screen_pos)).normalized()
	if id >= RING_ID:
		_set_model_handle(model, id, origin, dir, to_local.basis * -camera.global_basis.z)
		return
	var anchor: Vector3
	if id == ROOT_ID:
		anchor = model.pose_global(model.root_index()).origin
	elif id >= CHAIN_ID:
		anchor = model.pose_global(model.bone_index(model.chains[id - CHAIN_ID].end)).origin
	else:
		anchor = model.pose_global(id).origin
	if _drag_plane.normal == Vector3.ZERO:
		var n := (to_local.basis * -camera.global_basis.z).normalized()
		_drag_plane = Plane(n, anchor)
	var hit = _drag_plane.intersects_ray(origin, dir)
	if hit == null:
		return
	var p: Vector3 = hit
	if id == ROOT_ID:
		var rest := model.skeleton.get_bone_rest(model.root_index()).origin
		model.data.root_offset = model.snap(p) - rest
		model.apply_pose()
		model.hold_pins(_drag_targets)
	elif id >= CHAIN_ID:
		var c: BodyPlan.Chain = model.chains[id - CHAIN_ID]
		model.solve_chain(c, model.snap(p), not model.data.ik_end_follows)
		_drag_targets.erase(c)
		model.hold_pins(_drag_targets)
	else:
		model.aim_bone(id, p - anchor)
		model.hold_pins(_drag_targets)
	model.update_gizmos()


## Model-mode drags: re-applied from the snapshot each step (no drift), in the piece's
## bone frame.
func _set_model_handle(model: ActorModel, id: int, origin: Vector3, dir: Vector3, view: Vector3) -> void:
	var xf := model.piece_transform(_snapshot)
	var anchor: Vector3
	if id >= SEL_ID:
		anchor = xf * ActorPieceOps.centre(_snapshot, model.selected_vertices())
	elif id >= VERT_ID:
		anchor = xf * _snapshot.vertices[id - VERT_ID]
	elif id >= RIM_ID:
		anchor = xf * _snapshot.vertices[_snapshot.rings[id - RIM_ID][0]]
	else:
		anchor = xf * _snapshot.ring_centre(id - RING_ID)
	if _drag_plane.normal == Vector3.ZERO:
		_drag_plane = Plane(view.normalized(), anchor)
		_drag_start = anchor
	var hit = _drag_plane.intersects_ray(origin, dir)
	if hit == null:
		return
	var inv := xf.affine_inverse()
	var delta: Vector3 = inv * (hit as Vector3) - inv * _drag_start
	var p := _snapshot.duplicate(true) as ActorPiece
	var grid := model.data.model_grid
	delta = ActorPieceOps.snap_v(delta, grid)
	if id >= SEL_ID:
		var verts := model.selected_vertices()
		ActorPieceOps.move(p, verts, delta, grid, verts.size() == 1)
		if p.is_tube():
			p.rebuild_tube_faces()
	elif id >= VERT_ID:
		ActorPieceOps.move(p, Array([id - VERT_ID], TYPE_INT, &"", null), delta, grid)
	elif id >= RIM_ID:
		var r := id - RIM_ID
		var c := _snapshot.ring_centre(r)
		var start := inv * _drag_start - c
		var now := inv * (hit as Vector3) - c
		var s0 := Vector2(start.x, start.z).length()
		var s1 := Vector2(now.x, now.z).length()
		var f := s1 / maxf(s0, 1e-4)
		ActorPieceOps.ring_scale(p, r, Vector2(f, f), grid)
	else:
		ActorPieceOps.ring_move(p, id - RING_ID, delta, grid)
	model.data.pieces[model.sel_piece] = p
	model.rebuild()


func _commit_handle(gizmo: EditorNode3DGizmo, id: int, _secondary: bool, restore: Variant, cancel: bool) -> void:
	var model := gizmo.get_node_3d() as ActorModel
	var ur := plugin.get_undo_redo()
	if id >= RING_ID:
		var idx: int = restore
		var before := model.pieces_copy()
		before[idx] = _snapshot
		if cancel:
			model.data.pieces = before
			return
		ur.create_action("Edit Actor Piece")
		ur.add_do_property(model.data, &"pieces", model.pieces_copy())
		ur.add_undo_property(model.data, &"pieces", before)
		ur.commit_action(false)
		return
	if cancel:
		model.data.pose = restore[0]
		model.data.root_offset = restore[1]
		model.apply_pose()
		return
	ur.create_action("Pose Actor")
	ur.add_do_property(model.data, &"pose", model.data.pose.duplicate())
	ur.add_do_property(model.data, &"root_offset", model.data.root_offset)
	ur.add_do_method(model, &"apply_pose")
	ur.add_undo_property(model.data, &"pose", restore[0])
	ur.add_undo_property(model.data, &"root_offset", restore[1])
	ur.add_undo_method(model, &"apply_pose")
	# Animating: the pose goes into a key at the playhead (same undo step).
	if plugin.get(&"timeline"):
		plugin.timeline.add_auto_key_ops(ur)
	ur.commit_action(false)
	if plugin.get(&"editor"):
		plugin.editor.refreshed.emit()
