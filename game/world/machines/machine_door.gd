@tool
class_name MachineDoor
extends Node3D
## A block the machine moves (a machine part prop): a stone block that slides by `move` (local)
## once its `input` channel reaches `threshold` - a doorway's blocks shifting aside when the
## wheel starts - after `delay` seconds (blocks in a row go one after another), grinding. Back
## again when the input drops (unless `latch`). Blocks the player and props while it's there.
## Writes how far it has moved (0..1) to `output`.
## Origin: the block's foot, middle.

@export var input := &""
@export var output := &""
@export_range(0.0, 1.0, 0.01) var threshold := 0.5
## Where it moves to (local, from where it's placed).
@export var move := Vector3(0.0, 0.0, -2.0)
@export_range(0.0, 20.0, 0.1, "suffix:s") var delay := 0.0
@export_range(0.05, 5.0, 0.05, "suffix:m/s") var speed := 0.5
## Stays moved once it has (the input dropping doesn't bring it back).
@export var latch := true
@export var size := Vector3(2.0, 3.0, 1.0):
	set(v):
		size = v
		_rebuild()
@export var texture: Texture2D = preload("res://textures/rock/granite_1.res"):
	set(v):
		texture = v
		_rebuild()
@export var color := Color(0.6, 0.57, 0.52):
	set(v):
		color = v
		_rebuild()

## How far moved (0..1).
var moved := 0.0
var _body: AnimatableBody3D
var _wait := 0.0
var _done := false
var _was_moving := false


func _ready() -> void:
	_rebuild()


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _body == null:
		return
	var on := MachineBus.value(input) >= threshold or (latch and _done)
	if on:
		_wait += delta
	else:
		_wait = 0.0
	var want := 1.0 if on and _wait >= delay else 0.0
	var moving := not is_equal_approx(moved, want)
	if moving:
		moved = move_toward(moved, want, speed / maxf(move.length(), 0.05) * delta)
		_body.position = move * moved
		if moved >= 1.0:
			_done = true
			Sfx.play(&"block_bound", global_position, 0.8, -3.0)
	if moving and not _was_moving:
		Sfx.play(&"block_slide", global_position, 0.6, -2.0)
	_was_moving = moving
	MachineBus.set_value(output, moved)


func _rebuild() -> void:
	if not is_inside_tree():
		return
	if _body:
		_body.queue_free()
	_body = AnimatableBody3D.new()
	_body.sync_to_physics = true
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	cs.position.y = size.y * 0.5
	_body.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position.y = size.y * 0.5
	mi.material_override = N64Materials.textured(color, texture)
	_body.add_child(mi)
	add_child(_body, false, INTERNAL_MODE_BACK)
	_body.position = move * moved


func prop_bounds() -> AABB:
	return AABB(Vector3(-size.x * 0.5, 0.0, -size.z * 0.5), size)
