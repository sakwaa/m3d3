@tool
class_name PushBlock
extends Node3D
## A block the player pushes and pulls (a push block prop brush), by Ocarina of Time's
## rules (decomp: ObjOshihiki, "push-pull"): hold Grab (interact) against a face, then the
## stick pushes or pulls it one `step` at a time. A step starts slow and gathers speed
## (OoT: +0.5 units a frame, up to 2, at 20 Hz), then the block rests briefly (`rest`, OoT
## 10 frames) before the next. It stops at walls (a thud if a step ends against one).
## Pushed past an edge until nothing is under it, it falls (OoT: gravity 1 unit a frame²)
## and lands in the hole or on whatever is below, another block included. Blocks standing
## on it ride along (if they fit where it goes). `slides`: an ice block, which keeps going
## step after step until something stops it.
## `link`: blocks with the same link name are joined (a chain under the floor): they move
## together, step for step, only if all of them can, and are held up if any of them is
## (Dittori's entanglement as machinery). Pushing one moves the others from afar; a ghost
## shows where they'd go while one is held. Keep linked blocks square to each other.
## Origin: the middle of the bottom face. Placed from the level tools' Props menu.
## Scale: our world is 0.04 m to an OoT/MM unit (human Link 40 units = 1.6 m): OoT's small
## block (60 units) is 2.4 m, the step (20 units) 0.8 m.

signal moved  ## a step ended (on the floor, or landed after a fall)
signal fell

const UNIT := 0.04  # metres per OoT unit
const OOT_HZ := 20.0
## OoT: push speed +0.5 units a frame each frame, at most 2 units a frame.
const ACCEL := 0.5 * UNIT * OOT_HZ * OOT_HZ  # m/s²
const MAX_SPEED := 2.0 * UNIT * OOT_HZ  # m/s
## OoT: gravity -1 unit a frame each frame, falling at most 20 units a frame.
const GRAVITY := 1.0 * UNIT * OOT_HZ * OOT_HZ
const MAX_FALL := 20.0 * UNIT * OOT_HZ
const GROUP := &"push_blocks"

## Weight on a scale or a pulley's pan (BalanceLift; the player weighs 1).
@export_range(0.0, 20.0, 0.1) var weight := 2.0
## Width (x), height (y), depth (z), metres. OoT: small 2.4, medium 4, large 4.8, huge 8.
@export var size := Vector3(2.4, 2.4, 2.4):
	set(v):
		size = v.max(Vector3(0.4, 0.4, 0.4))
		_rebuild()
## How far one push moves it (OoT: 20 units).
@export_range(0.1, 4.0, 0.05, "suffix:m") var step := 0.8
## Seconds after a step before the next can start (OoT: 10 frames).
@export_range(0.0, 2.0, 0.05, "suffix:s") var rest := 0.5
## Can be pulled as well as pushed.
@export var pullable := true
## Won't move at all (held by something: a root, a lock).
@export var locked := false
## Ice: slides on, step after step, until it can't.
@export var slides := false
## Joined to every other block with this link name (empty: none).
@export var link := &"":
	set(v):
		link = v
		_rebuild()
@export_group("Look")
@export var texture: Texture2D = preload("res://textures/rock/granite_1.res"):
	set(v):
		texture = v
		_rebuild()
## OoT tints per dungeon (Deku Tree 110,86,40; Forest 142,99,86; Water 102,144,182).
@export var color := Color8(142, 99, 86):
	set(v):
		color = v
		_rebuild()
## Texture repeats per metre.
@export_range(0.05, 4.0, 0.05) var texture_scale := 0.5:
	set(v):
		texture_scale = v
		_rebuild()
## The band round a linked block's sides (and its mates' ghosts).
@export var link_color := Color(0.35, 0.8, 1.0):
	set(v):
		link_color = v
		_rebuild()
@export_group("")

enum { IDLE, PUSH, FALL }

var state := IDLE
## Where it is now (world, the bottom's middle): the node stays where it was placed and the
## body inside it moves (an AnimatableBody synced to physics, so what stands on it rides).
var pos := Vector3.ZERO
var _body: AnimatableBody3D
var _mesh: MeshInstance3D
var _dir := Vector3.ZERO  # this step's direction (world, flat unit)
var _from := Vector3.ZERO  # where the step started
var _dist := 0.0
var _speed := 0.0
var _timer := 0.0
var _fall_v := 0.0
var _riders: Array[PushBlock] = []
var _mates: Array[PushBlock] = []  # linked blocks (same `link`)
var _carried := false  # moved by a linked block this step / fall, not on its own
var _ghosts: Array[MeshInstance3D] = []


func _ready() -> void:
	add_to_group(GROUP)
	_rebuild()
	if not Engine.is_editor_hint():
		top_level = true  # (moves on its own, not with its brush)
		global_transform = Transform3D(Basis(Vector3.UP, global_rotation.y), global_position)
	pos = global_position
	if not Engine.is_editor_hint():
		_find_mates.call_deferred()


func _find_mates() -> void:
	_mates.clear()
	if link == &"":
		return
	for n in all(get_tree()):
		if n != self and (n as PushBlock).link == link:
			_mates.append(n)


## This block and its linked mates.
func group() -> Array[PushBlock]:
	var out: Array[PushBlock] = [self]
	for m in _mates:
		if is_instance_valid(m):
			out.append(m)
	return out


static func all(tree: SceneTree) -> Array[Node]:
	return tree.get_nodes_in_group(GROUP)


## The block a collider belongs to, if any.
static func of(collider: Object) -> PushBlock:
	var n := collider as Node
	while n:
		if n is PushBlock:
			return n
		n = n.get_parent()
	return null


# --- Being pushed ---------------------------------------------------------------------------

## Whether a step could start now.
func ready_to_move() -> bool:
	for b in group():
		if b.state != IDLE or b._timer > 0.0 or b.locked:
			return false
	return true


## Whether the block and its mates could all step along `dir` (a face direction).
func can_step(dir: Vector3) -> bool:
	for b in group():
		if b._walled(b.pos + dir * step):
			return false
	return true


## Starts a step along `dir` (world, flat; snapped to the nearest face direction). Returns
## false if it can't go (resting, walled, locked).
func shove(dir: Vector3) -> bool:
	if not ready_to_move():
		return false
	dir = face_dir(dir)
	if dir == Vector3.ZERO or not can_step(dir):
		return false
	_begin(dir)
	return true


## The face direction (world) nearest `dir` (flat), or zero.
func face_dir(dir: Vector3) -> Vector3:
	dir.y = 0.0
	if dir.length() < 0.001:
		return Vector3.ZERO
	var best := Vector3.ZERO
	var dot := -2.0
	for a in [global_basis.x, -global_basis.x, global_basis.z, -global_basis.z]:
		var d := Vector3(a.x, 0.0, a.z).normalized()
		if d.dot(dir) > dot:
			dot = d.dot(dir)
			best = d
	return best


## Half the block's extent along a face direction `d` (world, flat unit).
func half_along(d: Vector3) -> float:
	return absf(d.dot(global_basis.x.normalized())) * size.x * 0.5 + absf(d.dot(global_basis.z.normalized())) * size.z * 0.5


## Half the face's width across `d`.
func half_across(d: Vector3) -> float:
	return half_along(d.cross(Vector3.UP).normalized())


func _begin(dir: Vector3) -> void:
	_dir = dir
	_from = pos
	_dist = 0.0
	_speed = 0.0
	state = PUSH
	_gather_riders(dir)
	for m in group():
		if m != self:
			m.state = PUSH
			m._dir = Vector3.ZERO
			m._carried = true
			m._gather_riders(dir)
			Sfx.play(&"block_slide", m.pos, 1.0, -4.0)
	Sfx.play(&"block_slide", pos)


## Blocks standing on this one come along if they'd fit where it's going.
func _gather_riders(dir: Vector3) -> void:
	_riders.clear()
	for b in _on_top():
		if not b in _mates and not b._walled(b.pos + dir * step):
			b.state = PUSH  # (carried: not stepping on its own)
			b._dir = Vector3.ZERO
			_riders.append(b)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _carried:
		return
	match state:
		IDLE:
			_timer -= delta
			_follow_floor()
		PUSH:
			if _dir == Vector3.ZERO:
				return  # riding another block
			_speed = minf(_speed + ACCEL * delta, MAX_SPEED)
			var was := _dist
			_dist = move_toward(_dist, step, _speed * delta)
			_move_by(_dir * (_dist - was))
			if not _group_supported():
				# (the probes sit just inside the edges: off a ledge a hair before the step
				# ends, so it finishes the step and drops square into a block-sized hole)
				if step - _dist < 0.05:
					_move_by(_dir * (step - _dist))
				_end_step()
				_start_fall()
			elif _dist >= step:
				var walled := not can_step(_dir)
				if walled:
					Sfx.play(&"block_bound", pos)
				var dir := _dir
				_end_step()
				for b in group():
					b._timer = b.rest
					b.moved.emit()
				if slides and not walled:
					_timer = 0.0
					shove(dir)
					_speed = MAX_SPEED  # (keeps sliding at speed)
		FALL:
			_fall_v = minf(_fall_v + GRAVITY * delta, MAX_FALL)
			var drop := _fall_v * delta
			var land := INF  # (metres down to where the first of the group lands)
			for b in group():
				var y := b._floor_below(b.pos, drop + 0.05)
				if y > -INF:
					land = minf(land, b.pos.y - y)
			if land < INF:
				_move_by(Vector3.DOWN * land)
				_fall_v = 0.0
				for b in group():
					b.state = IDLE
					b._carried = false
					b._timer = b.rest
					Sfx.play(&"block_bound", b.pos, 1.0, -5.0)
					b.moved.emit()
			else:
				_move_by(Vector3.DOWN * drop)
				if pos.y < -200.0:
					set_physics_process(false)


## Resting: keeps on a floor that moves a little (a scale's pan, a lift: up or down by up
## to FOLLOW a frame); falls when there's none that close.
const FOLLOW := 0.25


func _follow_floor() -> void:
	# (a linked group follows together, led by one of them: up to the highest floor under
	# any of them, falling only when none has one)
	var g := group()
	for b in g:
		if b.get_instance_id() < get_instance_id():
			return
	var dy := -INF
	for b in g:
		if b.state != IDLE:
			return
		var y := b._floor_below(b.pos + Vector3.UP * FOLLOW, FOLLOW * 2.0)
		if y > -INF:
			dy = maxf(dy, y - b.pos.y)
	if dy == -INF:
		_start_fall()
	elif absf(dy) > 0.0005:
		for b in g:
			b._move_by(Vector3.UP * dy, false)


## Moves the block (and what rides on it; and its carried mates if `mates`).
func _move_by(d: Vector3, mates := true) -> void:
	pos += d
	_body.position = global_basis.inverse() * (pos - global_position)
	for r in _riders:
		if is_instance_valid(r):
			r._move_by(d)
	if mates:
		for m in _mates:
			if is_instance_valid(m) and m._carried:
				m._move_by(d, false)


## Something under any of the group's blocks (it's held up if one of them is).
func _group_supported() -> bool:
	for b in group():
		if b._supported(b.pos):
			return true
	return false


func _end_step() -> void:
	for b in group():
		if b != self and not b._carried:
			continue
		b.state = IDLE
		b._carried = false
		for r in b._riders:
			if is_instance_valid(r):
				r.state = IDLE
				r._timer = r.rest
		b._riders.clear()


func _start_fall() -> void:
	for b in group():
		b.state = FALL
		b._fall_v = 0.0
		b._carried = b != self
		b.fell.emit()


# --- Probes ---------------------------------------------------------------------------------

## The things a probe ignores: this block, its riders, actors (people don't wall a block in).
func _exclude() -> Array[RID]:
	var out: Array[RID] = []
	for b in group():
		out.append(b._body.get_rid())
		for r in b._riders:
			if is_instance_valid(r):
				out.append(r._body.get_rid())
	for a in get_tree().get_nodes_in_group(&"actors"):
		if a is CollisionObject3D:
			out.append((a as CollisionObject3D).get_rid())
	return out


## Whether the block, at `at`, would overlap something (a little smaller, lifted off the floor).
func _walled(at: Vector3) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new()
	box.size = size - Vector3(0.1, 0.15, 0.1)
	q.shape = box
	q.transform = Transform3D(global_basis.orthonormalized(), at + Vector3.UP * (size.y * 0.5 + 0.05))
	q.collision_mask = _body.collision_mask
	q.exclude = _exclude()
	return not get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


## The bottom's corners (just inside) and middle, at `at`.
func _feet(at: Vector3) -> Array[Vector3]:
	var b := global_basis.orthonormalized()
	var hx := size.x * 0.5 - 0.02
	var hz := size.z * 0.5 - 0.02
	return [at, at + b * Vector3(hx, 0, hz), at + b * Vector3(-hx, 0, hz), at + b * Vector3(hx, 0, -hz), at + b * Vector3(-hx, 0, -hz)]


## Something under any of the bottom's corners or middle, at `at` (OoT: its five points).
func _supported(at: Vector3) -> bool:
	return _floor_below(at, 0.05) > -INF


## The highest floor under the bottom's points within `reach` below `at` (its height), or -INF.
func _floor_below(at: Vector3, reach: float) -> float:
	var space := get_world_3d().direct_space_state
	var ex := _exclude()
	var best := -INF
	for p in _feet(at):
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.1, p + Vector3.DOWN * reach, _body.collision_mask, ex)
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and hit.normal.y > 0.7:
			best = maxf(best, hit.position.y)
	return best


## Blocks standing on this one.
func _on_top() -> Array[PushBlock]:
	var out: Array[PushBlock] = []
	var top := pos.y + size.y
	var inv := Transform3D(global_basis, pos).affine_inverse()
	for n in all(get_tree()):
		var b := n as PushBlock
		if b == self or b in _mates or absf(b.pos.y - top) > 0.05:
			continue
		var l := inv * b.pos
		if absf(l.x) < size.x * 0.5 and absf(l.z) < size.z * 0.5:
			out.append(b)
	return out


# --- Link ghosts ---------------------------------------------------------------------------

## Shows where the linked mates would go if this block stepped along `dir` (world; their
## colour, red if the group can't go); ZERO hides them.
func show_link_ghosts(dir: Vector3) -> void:
	dir = face_dir(dir) if dir != Vector3.ZERO else dir
	if dir == Vector3.ZERO or _mates.is_empty():
		for gh in _ghosts:
			gh.visible = false
		return
	var ok := can_step(dir)
	var i := 0
	for m in _mates:
		if not is_instance_valid(m):
			continue
		if i >= _ghosts.size():
			var gh := MeshInstance3D.new()
			gh.mesh = BoxMesh.new()
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			gh.material_override = mat
			gh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			gh.top_level = true
			add_child(gh, false, INTERNAL_MODE_BACK)
			_ghosts.append(gh)
		var g := _ghosts[i]
		(g.mesh as BoxMesh).size = m.size + Vector3.ONE * 0.04
		var c := link_color if ok else Color(1.0, 0.3, 0.25)
		c.a = 0.3
		(g.material_override as StandardMaterial3D).albedo_color = c
		g.global_transform = Transform3D(m.global_basis.orthonormalized(), m.pos + dir * m.step + Vector3.UP * m.size.y * 0.5)
		g.visible = true
		i += 1
	for k in range(i, _ghosts.size()):
		_ghosts[k].visible = false


# --- Mesh -----------------------------------------------------------------------------------

func _rebuild() -> void:
	if not is_inside_tree():
		return
	if _body == null:
		_body = AnimatableBody3D.new()
		_body.name = "Body"
		_body.sync_to_physics = true
		var cs := CollisionShape3D.new()
		cs.shape = BoxShape3D.new()
		_body.add_child(cs)
		add_child(_body, false, INTERNAL_MODE_BACK)
		_mesh = MeshInstance3D.new()
		_body.add_child(_mesh)
	var cs := _body.get_child(0) as CollisionShape3D
	(cs.shape as BoxShape3D).size = size
	cs.position = Vector3.UP * size.y * 0.5
	var mat := N64Materials.textured(Color.WHITE, texture)
	mat.set_shader_parameter(&"use_vertex_color", true)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := size * 0.5
	var c := Vector3.UP * h.y
	# Faces: normal, the face's right, its up (UVs in metres along those).
	for f in [[Vector3.BACK, Vector3.RIGHT, Vector3.UP], [Vector3.FORWARD, Vector3.LEFT, Vector3.UP],
			[Vector3.RIGHT, Vector3.FORWARD, Vector3.UP], [Vector3.LEFT, Vector3.BACK, Vector3.UP],
			[Vector3.UP, Vector3.RIGHT, Vector3.FORWARD], [Vector3.DOWN, Vector3.RIGHT, Vector3.BACK]]:
		var n: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = f[2]
		var o := c + n * (h * n.abs()).length()
		var a := (h * u.abs()).length()
		var b := (h * v.abs()).length()
		var pts := [o - u * a - v * b, o + u * a - v * b, o + u * a + v * b, o - u * a + v * b]
		var uvs := [Vector2(0, 2 * b), Vector2(2 * a, 2 * b), Vector2(2 * a, 0), Vector2(0, 0)]
		# (OoT's blocks: the top a touch lighter, the sides as tinted)
		var col := color.lightened(0.12) if n == Vector3.UP else color
		for k in [0, 2, 1, 0, 3, 2]:  # (Godot fronts are clockwise)
			st.set_normal(n)
			st.set_color(col)
			st.set_uv(uvs[k] * texture_scale)
			st.add_vertex(pts[k])
		# Linked: a band round the sides, a little proud of the face.
		if link != &"" and absf(n.y) < 0.5:
			var bo := o + n * 0.01
			var bh := minf(0.12, h.y * 0.2)
			var bp := [bo - u * a - v * bh, bo + u * a - v * bh, bo + u * a + v * bh, bo - u * a + v * bh]
			for k in [0, 2, 1, 0, 3, 2]:
				st.set_normal(n)
				st.set_color(link_color)
				st.set_uv(uvs[k] * texture_scale * Vector2(1, 0.1))
				st.add_vertex(bp[k])
	_mesh.mesh = st.commit()
	_mesh.material_override = mat
