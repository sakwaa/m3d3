@tool
class_name ActorModel
extends Node3D
## Root of a character scene: builds a Skeleton3D from the data's body plan and
## proportions, a mannequin mesh (one starter piece per bone, stitched joints) skinned to
## it, and applies the working pose. Posing happens in the 3D view through the actor
## gizmo (drag bone ends to aim them, hands / feet for IK, the hips to move the body).
## Editor-only: exports replace it with the built skeleton + mesh.

@export var data: ActorModelData:
	set(value):
		if data and data.changed.is_connected(_queue_rebuild):
			data.changed.disconnect(_queue_rebuild)
		data = value
		if data:
			data.changed.connect(_queue_rebuild)
		_queue_rebuild()
## Translucent player-height capsule beside the model, for scale.
@export var show_reference := true:
	set(value):
		show_reference = value
		if _reference:
			_reference.visible = value

enum Mode { POSE, MODEL, PAINT }
## Viewport display: Solid; Wireframe (edges only); X-ray (see-through, select through).
enum Display { SOLID, WIREFRAME, XRAY }
## What clicks / box selects pick (like Blender's 1 / 2 / 3).
enum Select { VERTEX, EDGE, FACE }

## Editor: Pose shows the working pose; Model / Paint show the rest pose.
var mode := Mode.POSE:
	set(value):
		var paint_changed := (value == Mode.PAINT) != (mode == Mode.PAINT)
		mode = value
		if paint_changed and skeleton:
			rebuild()  # side tints only while modelling
		apply_pose()
		_apply_display()
var display := Display.SOLID:
	set(value):
		display = value
		_apply_display()
## Pose handles in the 3D view (Pose tool); the Body tool shows the bones only.
var pose_handles := true:
	set(value):
		pose_handles = value
		update_gizmos()
var select_mode := Select.FACE:
	set(value):
		select_mode = value
		update_gizmos()
## Modelling selection (one piece at a time): its selected vertices / edges / faces, and
## a tube ring.
var sel_piece := -1
var sel_verts: Array[int] = []
var sel_edges: Array[Vector2i] = []
var sel_faces: Array[int] = []
var sel_ring := -1
## Pose: the bone picked last (clicking its handle, or the inspector), rotated by the
## Pose options' sliders and highlighted in the view.
var sel_bone := -1:
	set(value):
		sel_bone = value
		update_gizmos()
## Clickable triangles of the built mesh (rest pose, model space).
var picks := []
var tri_count := 0
## Animation being edited (index into data.animations, -1 = free posing) and the
## playhead frame; onion skin draws the neighbouring keys.
var anim_index := -1
var frame := 0.0
var onion := true
## Set by the exporter: build without editor-only tints.
var export_build := false
## Modelling outside the editor (the iOS mesh builder): the editor's modelling view
## (side tints, wireframe / X-ray, no game AnimationPlayer). Set before adding to the tree.
var authoring := false

## Player capsule size (player/player.gd BODY_HEIGHT / BODY_RADIUS).
const REFERENCE_HEIGHT := 1.6
const REFERENCE_RADIUS := 0.35

var plan: BodyPlan
var bones: Array = []  # BodyPlan.Bone, skeleton order
var chains: Array = []  # BodyPlan.Chain
var skeleton: Skeleton3D
var mesh_instance: MeshInstance3D

var _index := {}  # bone name -> index
var _rebuild_queued := false
var _reference: MeshInstance3D


func _ready() -> void:
	if data == null:
		data = ActorModelData.new()
	rebuild()
	# Running from the editor (not an export, where this node is already flattened): the
	# game plays animations through a regular AnimationPlayer child, as in builds.
	if not Engine.is_editor_hint() and not authoring and not data.animations.is_empty():
		var player := AnimationPlayer.new()
		player.name = "AnimationPlayer"
		player.add_animation_library(&"", build_animation_library())
		add_child(player)


func _queue_rebuild() -> void:
	if _rebuild_queued or not is_inside_tree():
		return
	_rebuild_queued = true
	rebuild.call_deferred()


func rebuild() -> void:
	_rebuild_queued = false
	if data == null:
		return
	plan = BodyPlan.find(data.plan)
	if plan == null:
		push_error("ActorModel: unknown body plan '%s'." % data.plan)
		return
	bones = plan.all_bones(data.proportions)
	chains = plan.all_chains()
	_index.clear()
	for i in bones.size():
		_index[bones[i].name] = i
	if skeleton == null:
		skeleton = Skeleton3D.new()
		skeleton.name = "Skeleton"
		# Internal in the editor (never saved); a plain child in the game so other nodes
		# (the projected shadow, the AnimationPlayer) find the mesh and bones.
		add_child(skeleton, false, INTERNAL_MODE_BACK if Engine.is_editor_hint() else INTERNAL_MODE_DISABLED)
		mesh_instance = MeshInstance3D.new()
		mesh_instance.name = "Mesh"
		skeleton.add_child(mesh_instance)
	_build_skeleton()
	var built := ActorMannequin.build(self, (Engine.is_editor_hint() or authoring) and not export_build and mode != Mode.PAINT)
	mesh_instance.mesh = built.mesh
	picks = built.picks
	tri_count = built.tris
	# Swap slots for the game (ActorFaces): surface + frames per slot.
	mesh_instance.set_meta(&"n64_swap_slots", built.slots)
	_apply_display()
	if sel_piece >= data.pieces.size():
		clear_selection()
	mesh_instance.skin = skeleton.create_skin_from_rest_transforms()
	mesh_instance.skeleton = NodePath("..")
	_build_reference()
	_build_preview_props()
	apply_pose()


# --- Skeleton -------------------------------------------------------------------------------

## Rest orientation of a bone (model space): +Y along the bone. Right-side bones mirror
## their left twins, so mirrored poses are simple quaternion reflections.
func rest_basis(i: int) -> Basis:
	var b: BodyPlan.Bone = bones[i]
	if b.side == 1:
		var left: int = _index.get(BodyPlan.mirror_name(b.name), -1)
		if left >= 0:
			return MIRROR * rest_basis(left) * MIRROR
	var y := (b.tail - b.head).normalized()
	if y.length() < 0.5:
		y = Vector3.UP
	var ref := Vector3.RIGHT if absf(y.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x := (ref - y * ref.dot(y)).normalized()
	return Basis(x, y, x.cross(y))


const MIRROR := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))


func rest_global(i: int) -> Transform3D:
	return Transform3D(rest_basis(i), bones[i].head)


func _build_skeleton() -> void:
	skeleton.clear_bones()
	for b in bones:
		skeleton.add_bone(b.name)
	for i in bones.size():
		var b: BodyPlan.Bone = bones[i]
		var parent: int = _index.get(b.parent, -1)
		skeleton.set_bone_parent(i, parent)
		var rest := rest_global(i)
		if parent >= 0:
			rest = rest_global(parent).affine_inverse() * rest
		skeleton.set_bone_rest(i, rest)
	skeleton.reset_bone_poses()


func bone_index(bone_name: StringName) -> int:
	return _index.get(bone_name, -1)


## Current pose of a bone in model space.
func pose_global(i: int) -> Transform3D:
	return skeleton.get_bone_global_pose(i)


func root_index() -> int:
	return 0


# --- Pose -----------------------------------------------------------------------------------

func apply_pose() -> void:
	if skeleton == null:
		return
	var posed := mode == Mode.POSE
	for i in bones.size():
		var rest := skeleton.get_bone_rest(i)
		var delta: Quaternion = data.pose.get(bones[i].name, Quaternion.IDENTITY) if posed else Quaternion.IDENTITY
		skeleton.set_bone_pose_rotation(i, rest.basis.get_rotation_quaternion() * delta)
		skeleton.set_bone_pose_position(i, rest.origin + (data.root_offset if i == root_index() and posed else Vector3.ZERO))
	skeleton.force_update_all_bone_transforms()
	update_gizmos()


## Sets bone `i` to `rot` (model space orientation), stored as a delta from rest.
func set_global_rotation_of(i: int, rot: Basis) -> void:
	var parent := skeleton.get_bone_parent(i)
	var parent_rot := pose_global(parent).basis.orthonormalized() if parent >= 0 else Basis.IDENTITY
	var local := (parent_rot.inverse() * rot.orthonormalized()).get_rotation_quaternion()
	var rest := skeleton.get_bone_rest(i).basis.get_rotation_quaternion()
	var delta := (rest.inverse() * local).normalized()
	data.pose[bones[i].name] = delta
	skeleton.set_bone_pose_rotation(i, local)
	skeleton.force_update_all_bone_transforms()


## Aims bone `i` (its +Y) along `dir` (model space), keeping its twist, with the
## resulting local rotation snapped to the angle step.
func aim_bone(i: int, dir: Vector3) -> void:
	if dir.length() < 1e-4:
		return
	var cur := pose_global(i).basis.orthonormalized()
	var q := Quaternion(cur.y.normalized(), dir.normalized())
	set_global_rotation_of(i, Basis(q) * cur)
	_snap_bone(i)


func _snap_bone(i: int) -> void:
	var step := deg_to_rad(maxf(data.angle_step, 0.0))
	if step <= 0.0:
		return
	var delta: Quaternion = data.pose.get(bones[i].name, Quaternion.IDENTITY)
	var e := delta.get_euler()
	e = Vector3(snappedf(e.x, step), snappedf(e.y, step), snappedf(e.z, step))
	delta = Quaternion.from_euler(e)
	data.pose[bones[i].name] = delta
	var rest := skeleton.get_bone_rest(i).basis.get_rotation_quaternion()
	skeleton.set_bone_pose_rotation(i, rest * delta)
	skeleton.force_update_all_bone_transforms()


## Bone `i`'s pose rotation in its own frame, in degrees: x / z bend, y twists along the
## bone (Godot's default YXZ Euler order). Right-side bones read mirrored (y / z negated,
## as mirror_pose does), so the same numbers on a left and a right bone give mirror images.
func bone_euler(i: int) -> Vector3:
	var delta: Quaternion = data.pose.get(bones[i].name, Quaternion.IDENTITY)
	return _side_euler(i, delta.get_euler() * (180.0 / PI))


func set_bone_euler(i: int, degrees: Vector3) -> void:
	data.pose[bones[i].name] = Quaternion.from_euler(_side_euler(i, degrees) * (PI / 180.0))
	apply_pose()


func _side_euler(i: int, e: Vector3) -> Vector3:
	return Vector3(e.x, -e.y, -e.z) if bones[i].side == 1 else e


func find_chain(chain_name: StringName) -> BodyPlan.Chain:
	for c in chains:
		if c.name == chain_name:
			return c
	return null


## Two-bone IK: bends `c` so its end's head reaches `target` (model space), knee / elbow
## toward the chain's pole. The end bone keeps its model-space orientation, or with
## `keep_end_rotation` off its rotation relative to the lower bone (it follows the limb).
func solve_chain(c: BodyPlan.Chain, target: Vector3, keep_end_rotation := true) -> void:
	var u := bone_index(c.upper)
	var l := bone_index(c.lower)
	var e := bone_index(c.end)
	if u < 0 or l < 0 or e < 0:
		return
	var end_rot := pose_global(e).basis.orthonormalized()
	var a := pose_global(u).origin
	var bu: BodyPlan.Bone = bones[u]
	var bl: BodyPlan.Bone = bones[l]
	var be: BodyPlan.Bone = bones[e]
	var l1 := bu.head.distance_to(bl.head)
	var l2 := bl.head.distance_to(be.head)
	var to := target - a
	var d := clampf(to.length(), absf(l1 - l2) + 1e-3, (l1 + l2) * 0.999)
	var dir := to.normalized() if to.length() > 1e-4 else Vector3.DOWN
	var along := (l1 * l1 - l2 * l2 + d * d) / (2.0 * d)
	var h := sqrt(maxf(l1 * l1 - along * along, 0.0))
	# Pole direction relative to the character's current facing (root rotation).
	var pole := pose_global(root_index()).basis.orthonormalized() * c.pole
	var bend := (pole - dir * pole.dot(dir))
	bend = bend.normalized() if bend.length() > 1e-4 else Vector3.FORWARD
	var knee := a + dir * along + bend * h
	var end := a + dir * d
	_point(u, knee - a)
	_point(l, end - pose_global(l).origin)
	if keep_end_rotation:
		set_global_rotation_of(e, end_rot)


func _point(i: int, dir: Vector3) -> void:
	var cur := pose_global(i).basis.orthonormalized()
	set_global_rotation_of(i, Basis(Quaternion(cur.y.normalized(), dir.normalized())) * cur)


## Where each pinned chain's end is now (model space), to hold them while the body moves.
func pinned_targets() -> Dictionary:
	var out := {}
	for c in chains:
		if data.pins.get(c.name, false):
			out[c] = pose_global(bone_index(c.end)).origin
	return out


func hold_pins(targets: Dictionary) -> void:
	for c in targets:
		solve_chain(c, targets[c])


func reset_pose() -> void:
	data.pose = {}
	data.root_offset = Vector3.ZERO
	apply_pose()


## Copies one side's pose onto the other (`from_side`: -1 left, 1 right).
func mirror_pose(from_side: int) -> void:
	var pose: Dictionary = data.pose.duplicate()
	for b in bones:
		if b.side != from_side:
			continue
		var q: Quaternion = pose.get(b.name, Quaternion.IDENTITY)
		pose[BodyPlan.mirror_name(b.name)] = Quaternion(q.x, -q.y, -q.z, q.w)
	data.pose = pose
	apply_pose()


# --- Animation ----------------------------------------------------------------------------

func current_animation() -> ActorAnimation:
	return data.animations[anim_index] if anim_index >= 0 and anim_index < data.animations.size() else null


## Shows the current animation at `f` as the working pose.
func show_frame(f: float) -> void:
	frame = f
	var a := current_animation()
	if a == null or a.keys.is_empty():
		update_gizmos()
		return
	var r := a.evaluate(f)
	data.pose = r.pose.duplicate()
	data.root_offset = r.root
	apply_pose()


## Model-space bone transforms for a pose without touching the skeleton (onion skin).
func pose_globals(pose: Dictionary, root: Vector3) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for i in bones.size():
		var rest := skeleton.get_bone_rest(i)
		var delta: Quaternion = pose.get(bones[i].name, Quaternion.IDENTITY)
		var local := Transform3D(Basis(rest.basis.get_rotation_quaternion() * delta), rest.origin + (root if i == root_index() else Vector3.ZERO))
		var parent := skeleton.get_bone_parent(i)
		out.append(out[parent] * local if parent >= 0 else local)
	return out


## Bone names this character has (paste filters).
func bone_names() -> Dictionary:
	var out := {}
	for b in bones:
		out[b.name] = true
	return out


## Every animation baked per frame into a Godot library: bone rotation tracks
## ("Skeleton:<bone>") + the root's position; windows / events as metadata the game's
## state machines read ("n64_windows" fractions, "n64_events").
func build_animation_library() -> AnimationLibrary:
	var lib := AnimationLibrary.new()
	for a in data.animations:
		if a == null or a.keys.is_empty():
			continue
		var anim := Animation.new()
		var dt := 1.0 / maxf(a.fps, 1)
		anim.length = a.length * dt
		anim.loop_mode = Animation.LOOP_LINEAR if a.loop else Animation.LOOP_NONE
		var tracks := {}
		for i in bones.size():
			var t := anim.add_track(Animation.TYPE_ROTATION_3D)
			anim.track_set_path(t, NodePath("Skeleton:%s" % bones[i].name))
			tracks[i] = t
		var root_track := anim.add_track(Animation.TYPE_POSITION_3D)
		anim.track_set_path(root_track, NodePath("Skeleton:%s" % bones[root_index()].name))
		var frames := a.length + (0 if a.loop else 1)
		for f in frames:
			var r := a.evaluate(f)
			for i in bones.size():
				var rest := skeleton.get_bone_rest(i)
				var delta: Quaternion = r.pose.get(bones[i].name, Quaternion.IDENTITY)
				anim.rotation_track_insert_key(tracks[i], f * dt, rest.basis.get_rotation_quaternion() * delta)
			anim.position_track_insert_key(root_track, f * dt, skeleton.get_bone_rest(root_index()).origin + r.root)
		anim.set_meta(&"n64_windows", a.window_fractions())
		var ev := []
		for e in a.events:
			ev.append({time = e.frame * dt, name = e.name})
		anim.set_meta(&"n64_events", ev)
		lib.add_animation(StringName(a.name), anim)
	return lib


# --- Modelling ---------------------------------------------------------------------------

## Pieces become editable data (copied from the starter shapes the first time).
func begin_modelling() -> void:
	if data.pieces.is_empty():
		var starters := ActorMannequin.starters(self)
		data.pieces = starters


## Deep copy of the pieces (undo snapshots).
func pieces_copy() -> Array[ActorPiece]:
	var out: Array[ActorPiece] = []
	for p in data.pieces:
		out.append(p.duplicate(true) as ActorPiece)
	return out


## Vertices the selection covers in the selected piece (all of them when nothing is
## picked: tools then act on the whole piece).
func selected_vertices() -> Array[int]:
	var p := selected_piece()
	if p == null:
		return []
	var out: Array[int] = []
	match select_mode:
		Select.VERTEX:
			out = sel_verts.duplicate()
		Select.EDGE:
			for e in sel_edges:
				for v in [e.x, e.y]:
					if not out.has(v):
						out.append(v)
		Select.FACE:
			if not sel_faces.is_empty():
				out = ActorPieceOps.face_vertices(p, sel_faces)
	if out.is_empty():
		for i in p.vertices.size():
			out.append(i)
	return out


## Faces the selection covers: picked faces, or faces whose vertices are all selected
## (vertex / edge modes). All faces when nothing is picked.
func selected_faces() -> Array[int]:
	var p := selected_piece()
	var out: Array[int] = []
	if p == null:
		return out
	var f := p.faces()
	if select_mode == Select.FACE:
		out = sel_faces.duplicate()
	elif has_selection():
		var vs := selected_vertices()
		for i in f.size():
			if Array(f[i]).all(func(v): return vs.has(v)):
				out.append(i)
	if out.is_empty() and not has_selection():
		for i in f.size():
			out.append(i)
	return out


## Anything picked below the piece level.
func has_selection() -> bool:
	match select_mode:
		Select.VERTEX:
			return not sel_verts.is_empty()
		Select.EDGE:
			return not sel_edges.is_empty()
	return not sel_faces.is_empty()


func clear_selection() -> void:
	sel_piece = -1
	clear_elements()


func clear_elements() -> void:
	sel_verts.clear()
	sel_edges.clear()
	sel_faces.clear()
	sel_ring = -1
	update_gizmos()


## Wireframe hides the solid mesh (the gizmo draws every edge); X-ray makes it
## see-through. Only in the editor's Model / Paint modes.
func _apply_display() -> void:
	if mesh_instance == null:
		return
	var editing := (Engine.is_editor_hint() or authoring) and mode != Mode.POSE
	var d := display if editing or Engine.is_editor_hint() else Display.SOLID
	mesh_instance.visible = d != Display.WIREFRAME
	mesh_instance.transparency = 0.65 if d == Display.XRAY else 0.0
	update_gizmos()


## Through-geometry selection (wireframe / X-ray).
func sees_through() -> bool:
	return display != Display.SOLID


func selected_piece() -> ActorPiece:
	return data.pieces[sel_piece] if sel_piece >= 0 and sel_piece < data.pieces.size() else null


## Bone frame -> model space (rest) for a piece.
func piece_transform(p: ActorPiece) -> Transform3D:
	return ActorMannequin.piece_transform(self, p)


## Nearest face under a ray (model space): {piece, face, mirrored, point} or {}.
func pick(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var best_t := INF
	for t in picks:
		var hit = Geometry3D.ray_intersects_triangle(origin, dir, t.a, t.b, t.c)
		if hit == null:
			continue
		var d := origin.distance_to(hit)
		if d < best_t:
			best_t = d
			best = {piece = t.piece, face = t.face, mirrored = t.mirrored, point = hit}
	return best


func snap(v: Vector3) -> Vector3:
	var g := data.grid
	return v.snapped(Vector3(g, g, g)) if g > 0.0 else v


## Height of the model (top of the highest bone end in rest).
func height() -> float:
	var top := 0.0
	for b in bones:
		top = maxf(top, maxf(b.head.y, b.tail.y))
	return top


## Editor only: the preview props (data.preview_props) held on their prop bones.
func _build_preview_props() -> void:
	if not Engine.is_editor_hint() or export_build or skeleton == null:
		return
	for c in skeleton.get_children(true):
		if c.has_meta(&"n64_preview_prop"):
			c.free()
	for bone in data.preview_props:
		var scene := data.preview_props[bone] as PackedScene
		if scene == null or bone_index(bone) < 0:
			continue
		var att := BoneAttachment3D.new()
		att.name = "Preview_%s" % bone
		att.bone_name = bone
		att.set_meta(&"n64_preview_prop", true)
		skeleton.add_child(att, false, INTERNAL_MODE_BACK)
		att.add_child(scene.instantiate())


## Prop bones (items attach there), in skeleton order.
func prop_bones() -> Array[StringName]:
	var out: Array[StringName] = []
	for b in bones:
		if String(b.name).begins_with("prop"):
			out.append(b.name)
	return out


func _build_reference() -> void:
	if not Engine.is_editor_hint():
		return
	if _reference == null:
		_reference = MeshInstance3D.new()
		var m := CapsuleMesh.new()
		m.radius = REFERENCE_RADIUS
		m.height = REFERENCE_HEIGHT
		m.radial_segments = 12
		m.rings = 4
		_reference.mesh = m
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.4, 0.7, 1.0, 0.25)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_reference.material_override = mat
		add_child(_reference, false, INTERNAL_MODE_BACK)
	var width := 0.0
	for b in bones:
		width = maxf(width, absf(b.head.x))
	_reference.position = Vector3(width + 0.6, REFERENCE_HEIGHT * 0.5, 0)
	_reference.visible = show_reference
