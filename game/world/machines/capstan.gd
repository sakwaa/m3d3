@tool
class_name Capstan
extends Node3D
## A capstan (a machine part prop): a stone drum with spokes the player pushes round, OoT
## rotating-statue style - hold Grab against a spoke, the stick turns it a `step` at a time
## (gathering speed like a push block, a short rest between), the player walking round with
## it (LocoCapstan). A ratchet holds it wherever it's left; pushing the other way turns it
## back. How far it's turned (0 .. `turns` full turns) goes out on `output` (0..1), which a
## ScrewGate or anything else reads.
## `seized`: won't turn at all (rust, roots) until something frees it.
## Origin: the drum's foot, middle.

signal turned(value: float)  ## a step ended

const GROUP := &"capstans"

## Machine channel this writes (0 none .. 1 all the way round).
@export var output := &""
## Full turns from closed to open.
@export_range(1, 12) var turns := 4
## Degrees one push turns it.
@export_range(10.0, 180.0, 5.0, "suffix:°") var step := 90.0
## Seconds after a step before the next.
@export_range(0.0, 2.0, 0.05, "suffix:s") var rest := 0.35
## Won't turn (freed by setting it false: a puzzle's reward).
@export var seized := false
@export_group("Shape")
@export_range(0.2, 3.0, 0.05, "suffix:m") var drum_radius := 0.7:
	set(v):
		drum_radius = v
		_rebuild()
@export_range(0.3, 3.0, 0.05, "suffix:m") var drum_height := 1.2:
	set(v):
		drum_height = v
		_rebuild()
@export_range(2, 8) var spokes := 4:
	set(v):
		spokes = v
		_rebuild()
@export_range(0.3, 3.0, 0.05, "suffix:m") var spoke_length := 1.4:
	set(v):
		spoke_length = v
		_rebuild()
## Spokes' height off the ground (chest height for the player).
@export_range(0.3, 2.0, 0.05, "suffix:m") var spoke_height := 1.05:
	set(v):
		spoke_height = v
		_rebuild()
@export var stone_texture: Texture2D = preload("res://textures/rock/granite_1.res"):
	set(v):
		stone_texture = v
		_rebuild()
@export var wood_texture: Texture2D = preload("res://textures/wood/wood_2.res"):
	set(v):
		wood_texture = v
		_rebuild()
@export var stone_color := Color(0.62, 0.58, 0.52):
	set(v):
		stone_color = v
		_rebuild()
@export_group("")

## Turned this far (degrees, 0 .. turns * 360).
var angle := 0.0
var _target := 0.0
var _speed := 0.0
var _timer := 0.0
var _rotor: Node3D


func _ready() -> void:
	add_to_group(GROUP)
	_rebuild()


static func all(tree: SceneTree) -> Array[Node]:
	return tree.get_nodes_in_group(GROUP)


## 0..1 of the way round.
func value() -> float:
	return angle / (turns * 360.0)


## Whether a push could start now.
func ready_to_turn() -> bool:
	return not seized and _timer <= 0.0 and is_equal_approx(angle, _target)


## Starts a step: +1 the way that opens, -1 back. False if it can't (resting, at an end, seized).
func push(dir: int) -> bool:
	if not ready_to_turn():
		return false
	var to := clampf(_target + step * signf(dir), 0.0, turns * 360.0)
	if is_equal_approx(to, _target):
		return false
	_target = to
	_speed = 0.0
	Sfx.play(&"block_slide", global_position, 0.7, -2.0)
	return true


## The spokes' world directions (flat unit) now.
func spoke_dirs() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for k in spokes:
		var a := deg_to_rad(angle) + TAU * k / spokes
		out.append((global_basis * Vector3(cos(a), 0.0, -sin(a))).normalized())
	return out


## Where on a spoke the player holds it (radius from the middle).
func grip_radius() -> float:
	return drum_radius + spoke_length * 0.8


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_timer -= delta
	if not is_equal_approx(angle, _target):
		# (the same speed-up as a push block, in degrees at the grip)
		var deg_per_m := rad_to_deg(1.0 / grip_radius())
		_speed = minf(_speed + PushBlock.ACCEL * deg_per_m * delta, PushBlock.MAX_SPEED * deg_per_m * 0.8)
		angle = move_toward(angle, _target, _speed * delta)
		if is_equal_approx(angle, _target):
			angle = _target
			_timer = rest
			Sfx.play(&"block_bound", global_position, 1.6, -6.0)  # (the ratchet's click)
			turned.emit(value())
		_rotor.rotation.y = deg_to_rad(angle)
	MachineBus.set_value(output, value())


# --- Mesh -------------------------------------------------------------------------------------

func _rebuild() -> void:
	if not is_inside_tree():
		return
	for c in get_children(true):
		if c.has_meta(&"capstan_part"):
			c.queue_free()
	var stone := N64Materials.textured(stone_color, stone_texture)
	var wood := N64Materials.textured(Color(0.7, 0.58, 0.45), wood_texture)
	# The drum's housing (fixed) and collision.
	var body := StaticBody3D.new()
	body.set_meta(&"capstan_part", true)
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = drum_radius
	cyl.height = drum_height
	cs.shape = cyl
	cs.position.y = drum_height * 0.5
	body.add_child(cs)
	add_child(body, false, INTERNAL_MODE_BACK)
	var base := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = drum_radius * 1.15
	bm.bottom_radius = drum_radius * 1.25
	bm.height = 0.25
	bm.radial_segments = 8
	base.mesh = bm
	base.material_override = stone
	base.position.y = 0.125
	base.set_meta(&"capstan_part", true)
	add_child(base, false, INTERNAL_MODE_BACK)
	# The rotor: drum, cap and spokes turning together.
	_rotor = Node3D.new()
	_rotor.set_meta(&"capstan_part", true)
	add_child(_rotor, false, INTERNAL_MODE_BACK)
	_rotor.rotation.y = deg_to_rad(angle)
	var drum := MeshInstance3D.new()
	var dm := CylinderMesh.new()
	dm.top_radius = drum_radius * 0.9
	dm.bottom_radius = drum_radius
	dm.height = drum_height - 0.25
	dm.radial_segments = 8
	drum.mesh = dm
	drum.material_override = stone
	drum.position.y = 0.25 + (drum_height - 0.25) * 0.5
	_rotor.add_child(drum)
	var cap := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = drum_radius * 0.6
	cm.bottom_radius = drum_radius * 1.0
	cm.height = 0.3
	cm.radial_segments = 8
	cap.mesh = cm
	cap.material_override = stone
	cap.position.y = drum_height + 0.15
	_rotor.add_child(cap)
	for k in spokes:
		var a := TAU * k / spokes
		var s := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(spoke_length + drum_radius * 0.5, 0.16, 0.16)
		s.mesh = sm
		s.material_override = wood
		var dir := Vector3(cos(a), 0.0, -sin(a))
		s.position = dir * (drum_radius * 0.75 + spoke_length * 0.5) + Vector3.UP * spoke_height
		s.rotation.y = a
		_rotor.add_child(s)


## Pick box for the level tools.
func prop_bounds() -> AABB:
	var r := drum_radius + spoke_length
	return AABB(Vector3(-r, 0.0, -r), Vector3(r * 2.0, drum_height + 0.3, r * 2.0))
