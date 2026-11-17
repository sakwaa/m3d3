@tool
class_name BalanceLift
extends Node3D
## Two pans that balance each other (a balance lift prop brush): whatever's heavier on one
## sinks it and raises the other, `travel` metres between the extremes. Push blocks weigh
## their `weight` (2 by default), the player 1; a block stacked on another counts too. A
## Permivor's counterweight in two shapes (`style`):
##   SCALE: the pans hang from a beam on a post between them (side by side).
##   PULLEY: the pans hang from a rope over two wheels (a lift: drop a weight in the basket
##     and the platform across the room goes up).
## Equal weights (or none) level it. `balance` (-1..1, + = pan A down) and the `tipped`
## signal are what other machine parts (gates, sluices) read.
## Frame: pan A's top-middle at the origin when level, pan B's at `pan_b` (local); both
## travel straight up and down. Leave room under each pan for it to sink into.

signal tipped(side: int)  ## came to rest fully down on a side (+1 A, -1 B) or level (0)

enum Style { SCALE, PULLEY }

@export var style := Style.SCALE:
	set(v):
		style = v
		_rebuild()
## Pan B's top-middle, level (local; pan A's is the origin).
@export var pan_b := Vector3(4.0, 0.0, 0.0):
	set(v):
		pan_b = v
		_rebuild()
## Each pan's size across (x, z) and thickness.
@export var pan_size := Vector3(2.8, 0.2, 2.8):
	set(v):
		pan_size = v.max(Vector3(0.5, 0.05, 0.5))
		_rebuild()
## Metres between a pan's highest and lowest (each moves half of it from level).
@export_range(0.1, 20.0, 0.1, "suffix:m") var travel := 2.4:
	set(v):
		travel = v
		_rebuild()
## Weight difference that tips it all the way (less tips it part way).
@export_range(0.1, 20.0, 0.1) var full_tip := 1.0
## How fast the pans move (m/s at most; eased in and out).
@export_range(0.1, 10.0, 0.1, "suffix:m/s") var speed := 1.2
## SCALE: the beam's pivot over the pans' level height. PULLEY: the wheels' height.
@export_range(0.5, 20.0, 0.1, "suffix:m") var top_height := 3.5:
	set(v):
		top_height = v
		_rebuild()
@export_group("Look")
@export var pan_texture: Texture2D = preload("res://textures/wood/wood_2.res"):
	set(v):
		pan_texture = v
		_rebuild()
@export var frame_texture: Texture2D = preload("res://textures/metal/metal_2.res"):
	set(v):
		frame_texture = v
		_rebuild()
@export var rope_texture: Texture2D = preload("res://textures/rope/rope_default.res"):
	set(v):
		rope_texture = v
		_rebuild()
@export var pan_color := Color(0.75, 0.6, 0.45):
	set(v):
		pan_color = v
		_rebuild()
@export var frame_color := Color(0.55, 0.5, 0.45):
	set(v):
		frame_color = v
		_rebuild()
@export_group("")

## The player's weight on a pan.
const ACTOR_WEIGHT := 1.0

## Where it is: -1..1, + = pan A down (B up).
var balance := 0.0
var _vel := 0.0
var _rest_side := 0
var _pans: Array[AnimatableBody3D] = []
var _parts: Node3D
var _beam: MeshInstance3D
var _rods: Array[MeshInstance3D] = []
var _mats := {}


func _ready() -> void:
	_rebuild()


## Weight on pan `i` (0 = A, 1 = B) now.
func weight_on(i: int) -> float:
	var pan := _pans[i]
	var q := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(pan_size.x - 0.05, 0.3, pan_size.z - 0.05)
	q.shape = box
	q.transform = Transform3D(pan.global_basis, pan.global_position + pan.global_basis.y * 0.17)
	q.collision_mask = pan.collision_mask
	q.exclude = [pan.get_rid()]
	var w := 0.0
	var seen := {}
	for hit in get_world_3d().direct_space_state.intersect_shape(q, 16):
		var c: Object = hit.collider
		var b := PushBlock.of(c)
		if b:
			w += _stack_weight(b, seen)
		elif c is Actor and not seen.has(c):
			seen[c] = true
			w += ACTOR_WEIGHT
	return w


## A block and everything standing on it.
func _stack_weight(b: PushBlock, seen: Dictionary) -> float:
	if seen.has(b):
		return 0.0
	seen[b] = true
	var w := b.weight
	for top in b._on_top():
		w += _stack_weight(top, seen)
	return w


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _pans.size() < 2:
		return
	var diff := weight_on(0) - weight_on(1)
	var target := clampf(diff / full_tip, -1.0, 1.0)
	# Eased: speeds up towards the target and slows into it (a heavy machine).
	var to_go := target - balance
	var max_v := speed / (travel * 0.5)  # (balance units a second)
	var want := clampf(to_go * 4.0, -max_v, max_v)
	_vel = move_toward(_vel, want, max_v * 3.0 * delta)
	var was := balance
	balance = clampf(balance + _vel * delta, -1.0, 1.0)
	if absf(balance - target) < 0.002 and absf(_vel) < 0.05:
		balance = target
		_vel = 0.0
	if balance != was:
		_place()
	# Come to rest all the way down on a side, or level: once per arrival.
	if balance == target and _vel == 0.0:
		var side := 0 if target == 0.0 else (signi(int(target)) if absf(target) >= 1.0 else 99)
		if side != 99 and side != _rest_side:
			_rest_side = side
			tipped.emit(side)
			Sfx.play(&"block_bound", global_position + pan_b * 0.5, 0.6, 3.0)


## The pans' tops (local) at the current balance.
func _pan_at(i: int) -> Vector3:
	var h := travel * 0.5 * balance
	return Vector3.DOWN * h if i == 0 else pan_b + Vector3.UP * h


func _place() -> void:
	for i in _pans.size():
		_pans[i].position = _pan_at(i)
	_place_frame()


# --- Mesh ------------------------------------------------------------------------------------

func _mat(tex: Texture2D, color: Color) -> Material:
	var key := [tex, color]
	if not _mats.has(key):
		var m := N64Materials.textured(color, tex)
		_mats[key] = m
	return _mats[key]


func _box_mesh(size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	return mi


func _rebuild() -> void:
	if not is_inside_tree():
		return
	if _parts:
		_parts.queue_free()
	for p in _pans:
		p.queue_free()
	_pans.clear()
	_rods.clear()
	_parts = Node3D.new()
	_parts.name = "Frame"
	add_child(_parts, false, INTERNAL_MODE_BACK)
	var pan_mat := _mat(pan_texture, pan_color)
	for i in 2:
		var body := AnimatableBody3D.new()
		body.sync_to_physics = true
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = pan_size
		cs.shape = shape
		cs.position = Vector3.DOWN * pan_size.y * 0.5
		body.add_child(cs)
		var mi := _box_mesh(pan_size, pan_mat)
		mi.position = cs.position
		body.add_child(mi)
		add_child(body, false, INTERNAL_MODE_BACK)
		body.position = _pan_at(i)
		_pans.append(body)
	var frame_mat := _mat(frame_texture, frame_color)
	var rope_mat := _mat(rope_texture, Color.WHITE)
	var mid := pan_b * 0.5
	if style == Style.SCALE:
		# A post from below the pans' lowest up to the pivot, a beam across, rods down to the pans.
		var foot := -travel * 0.5 - 0.3
		var post := _box_mesh(Vector3(0.3, top_height - foot, 0.3), frame_mat)
		post.position = mid + Vector3.UP * (foot + top_height) * 0.5
		_parts.add_child(post)
		_beam = _box_mesh(Vector3(pan_b.length() + 0.4, 0.22, 0.22), frame_mat)
		_parts.add_child(_beam)
	else:
		_beam = null
		# Two wheels over the pans, a rope across between them.
		for at in [Vector3.ZERO, pan_b]:
			var w := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.35
			cyl.bottom_radius = 0.35
			cyl.height = 0.15
			cyl.radial_segments = 8
			w.mesh = cyl
			w.material_override = frame_mat
			w.position = at + Vector3.UP * top_height
			var across := pan_b.normalized() if pan_b.length() > 0.01 else Vector3.RIGHT
			w.basis = Basis.looking_at(across.cross(Vector3.UP).normalized(), Vector3.UP) * Basis(Vector3.RIGHT, PI * 0.5)
			_parts.add_child(w)
		var top_rope := _box_mesh(Vector3(0.06, 0.06, 1.0), rope_mat)
		_parts.add_child(top_rope)
		top_rope.basis = Basis.looking_at(pan_b.normalized() if pan_b.length() > 0.01 else Vector3.FORWARD, Vector3.UP)
		top_rope.scale = Vector3(1, 1, maxf(pan_b.length(), 0.01))
		top_rope.position = mid + Vector3.UP * (top_height + 0.35)
	for i in 2:
		var rod := _box_mesh(Vector3(0.06, 1.0, 0.06), rope_mat if style == Style.PULLEY else frame_mat)
		_parts.add_child(rod)
		_rods.append(rod)
	_place_frame()


## The beam's tilt (SCALE) and the rods / ropes from the pans up to it.
func _place_frame() -> void:
	if _rods.size() < 2:
		return
	var tops: Array[Vector3] = []
	if style == Style.SCALE and _beam:
		var mid := pan_b * 0.5 + Vector3.UP * top_height
		var a := Vector3.ZERO + Vector3.UP * top_height
		var b := pan_b + Vector3.UP * top_height
		var h := travel * 0.5 * balance
		a.y -= h
		b.y += h
		var dir := (b - a)
		_beam.basis = Basis.looking_at(dir.normalized(), Vector3.UP) * Basis(Vector3.UP, PI * 0.5)
		_beam.position = mid
		tops = [a, b]
	else:
		tops = [Vector3.UP * top_height, pan_b + Vector3.UP * top_height]
	for i in 2:
		var bottom := _pan_at(i)
		var top: Vector3 = tops[i]
		var len := maxf(top.y - bottom.y, 0.01)
		_rods[i].scale = Vector3(1, len, 1)
		_rods[i].position = Vector3(bottom.x, (top.y + bottom.y) * 0.5, bottom.z)
