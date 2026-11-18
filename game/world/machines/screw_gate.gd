@tool
class_name ScrewGate
extends Node3D
## A sluice gate on a screw (a machine part prop): a stone slab in a frame across a channel,
## raised by a big screw above it as its `input` channel goes 0 -> 1 (a Capstan's output). It
## follows slowly (a heavy thing on a screw), and writes how open it actually is to `output`
## (what the water behind it follows). The slab blocks the player and props while down.
## Origin: the channel floor's middle at the gate; the channel runs along local Z.

## Machine channel it follows (0 shut .. 1 open).
@export var input := &""
## Machine channel it writes: how open it is now.
@export var output := &""
@export_range(0.5, 20.0, 0.1, "suffix:m") var width := 3.0:
	set(v):
		width = v
		_rebuild()
## Slab height (and how far it rises).
@export_range(0.5, 20.0, 0.1, "suffix:m") var height := 2.4:
	set(v):
		height = v
		_rebuild()
@export_range(0.1, 2.0, 0.05, "suffix:m") var thickness := 0.4:
	set(v):
		thickness = v
		_rebuild()
## Metres a second it rises / falls at most.
@export_range(0.05, 5.0, 0.05, "suffix:m/s") var speed := 0.6
@export var stone_texture: Texture2D = preload("res://textures/rock/granite_1.res"):
	set(v):
		stone_texture = v
		_rebuild()
@export var wood_texture: Texture2D = preload("res://textures/wood/wood_2.res"):
	set(v):
		wood_texture = v
		_rebuild()

## How open it is (0..1).
var open := 0.0
var _slab: AnimatableBody3D
var _screw: MeshInstance3D
var _was_moving := false


func _ready() -> void:
	_rebuild()


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _slab == null:
		return
	var want := MachineBus.value(input)
	var moving := not is_equal_approx(open, want)
	if moving:
		open = move_toward(open, want, speed / height * delta)
		_place()
	if moving and not _was_moving:
		Sfx.play(&"block_slide", global_position + Vector3.UP * height, 0.55, -3.0)
	_was_moving = moving
	MachineBus.set_value(output, open)


func _place() -> void:
	_slab.position = Vector3.UP * (height * 0.5 + open * height)
	if _screw:
		_screw.rotation.y = open * TAU * 6.0  # (the screw turns as it lifts)


func _rebuild() -> void:
	if not is_inside_tree():
		return
	for c in get_children(true):
		if c.has_meta(&"gate_part"):
			c.queue_free()
	var stone := N64Materials.textured(Color(0.6, 0.57, 0.52), stone_texture)
	var wood := N64Materials.textured(Color(0.62, 0.5, 0.38), wood_texture)
	# Frame: two posts and a lintel over the slab's full lift.
	var post_w := 0.6
	var top := height * 2.0 + 0.6
	for sx in [-1.0, 1.0]:
		_part_box(Vector3(post_w, top, thickness + 0.5), Vector3(sx * (width * 0.5 + post_w * 0.5), top * 0.5, 0.0), stone, true)
	_part_box(Vector3(width + post_w * 2.0, 0.6, thickness + 0.5), Vector3(0.0, top + 0.3, 0.0), stone, true)
	# The screw from the lintel down into the slab's top, and its nut.
	_screw = MeshInstance3D.new()
	_screw.set_meta(&"gate_part", true)
	var sm := CylinderMesh.new()
	sm.top_radius = 0.14
	sm.bottom_radius = 0.14
	sm.height = height + 0.6
	sm.radial_segments = 6
	_screw.mesh = sm
	_screw.material_override = wood
	add_child(_screw, false, INTERNAL_MODE_BACK)
	_screw.position = Vector3.UP * (top - sm.height * 0.5)
	# The slab (moves; blocks).
	_slab = AnimatableBody3D.new()
	_slab.sync_to_physics = true
	_slab.set_meta(&"gate_part", true)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(width, height, thickness)
	cs.shape = shape
	_slab.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = shape.size
	mi.mesh = bm
	mi.material_override = stone
	_slab.add_child(mi)
	add_child(_slab, false, INTERNAL_MODE_BACK)
	_place()


func _part_box(size: Vector3, at: Vector3, mat: Material, solid: bool) -> void:
	var root: Node3D = StaticBody3D.new() if solid else Node3D.new()
	root.set_meta(&"gate_part", true)
	root.position = at
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	root.add_child(mi)
	if solid:
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		root.add_child(cs)
	add_child(root, false, INTERNAL_MODE_BACK)


func prop_bounds() -> AABB:
	return AABB(Vector3(-width * 0.5 - 0.6, 0.0, -0.5), Vector3(width + 1.2, height * 2.0 + 1.2, 1.0))
