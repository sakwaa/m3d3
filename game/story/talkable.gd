@tool
class_name Talkable
extends Area3D
## Something to talk to or check: an NPC, a sign, the postbox. Walk up and press interact
## (Talk picks the nearest one offering), or Z-target it first (then it can be talked to from
## anywhere the lock holds). Offers within a cylinder (`radius` across, as much up and
## down), optionally only to someone in front of it (`facing_gate`: MM signs, ±56°). Adds
## its own reach sphere and Targetable.

@export var dialogue: Dialogue
## Node to start at ("" = the dialogue's start).
@export var entry := ""
## Shown in the prompt: "Talk", "Check", "Read"…
@export var prompt := "Talk"
@export var enabled := true
## Reach, in metres.
@export_range(0.5, 6.0, 0.1, "suffix:m") var radius := 1.8:
	set(value):
		radius = value
		if _sphere:
			_sphere.radius = value
## Z-targeting: NPC (someone) or POI (a thing); the lock aims at `target_height`.
@export var target_kind := Targetable.Kind.NPC
@export_range(0.0, 4.0, 0.05, "suffix:m") var target_height := 1.4
## Z-target range type (KIND: NPC townsfolk 4 m, POI sign 2.8 m).
@export var target_range := Targetable.Reach.KIND
## Offers only to someone within this many degrees of its front (+Z); 0 = from anywhere.
@export_range(0.0, 180.0, 0.25, "suffix:°") var facing_gate := 0.0
## The gate works from the back too (a banner written on both sides).
@export var two_sided := false
## Seconds after a conversation before it offers again (MM signs: 1 s).
@export var cooldown := 0.0

const GROUP := &"talkables"

## Time (s) it next offers.
var ready_at := 0.0

var _sphere: SphereShape3D


func _ready() -> void:
	_sphere = SphereShape3D.new()
	_sphere.radius = radius
	var shape := CollisionShape3D.new()
	shape.shape = _sphere
	add_child(shape, false, INTERNAL_MODE_FRONT)
	monitorable = false
	if Engine.is_editor_hint():
		return
	add_to_group(GROUP)
	var target := Targetable.new()
	target.kind = target_kind
	target.range_type = target_range
	target.position.y = target_height
	target.label = prompt
	add_child(target)


func can_talk() -> bool:
	return enabled and dialogue != null and Time.get_ticks_msec() * 0.001 >= ready_at


## Whether it offers to talk to someone at `p` (world): inside the cylinder and the facing gate.
func offers_to(p: Vector3) -> bool:
	var to := p - global_position
	if absf(to.y) > radius or Vector2(to.x, to.z).length() > radius:
		return false
	return in_gate(p)


## `p` is in front of it (facing_gate), or there's no gate.
func in_gate(p: Vector3) -> bool:
	if facing_gate <= 0.0:
		return true
	var to := p - global_position
	to.y = 0.0
	var front := global_basis.z
	front.y = 0.0
	if to.length() < 0.01 or front.length() < 0.01:
		return true
	var ang := rad_to_deg(front.normalized().angle_to(to.normalized()))
	return ang < facing_gate or (two_sided and 180.0 - ang < facing_gate)


func talk() -> void:
	Talk.start(dialogue, entry, self)
