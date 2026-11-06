@tool
class_name Talkable
extends Area3D
## Something to talk to or check: an NPC, a sign, the postbox. Walk up and press interact
## (Talk picks the best one in reach), or Z-target it first. Adds its own reach sphere
## and Targetable.

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
	var target := Targetable.new()
	target.kind = target_kind
	target.position.y = target_height
	target.label = prompt
	add_child(target)
	body_entered.connect(func(b: Node3D):
		if b.is_in_group(&"player"):
			Talk.register(self))
	body_exited.connect(func(b: Node3D):
		if b.is_in_group(&"player"):
			Talk.unregister(self))


func _exit_tree() -> void:
	if not Engine.is_editor_hint():
		Talk.unregister(self)


func can_talk() -> bool:
	return enabled and dialogue != null


func talk() -> void:
	Talk.start(dialogue, entry, self)
