class_name TargetLock
extends Node3D
## Z-targeting for an actor (the player): picks the best Targetable in view, holds it,
## and shows a reticle over it. Kind-agnostic rules:
##  - in range (the target's lock_range), roughly in front of the view (`max_angle`) and
##    in line of sight (level geometry blocks);
##  - kind order: enemies first, then NPCs, then points of interest; within a kind the
##    one nearest the view centre (weighted by distance) wins, `priority` breaking ties;
##  - the lock drops when the target is disabled, dies, leaves 1.3x its range or stays
##    out of sight for `lose_time`.

@export var max_angle := 75.0
## Seconds out of sight before the lock drops.
@export var lose_time := 1.0

var target: Targetable

var _reticle: Label3D
var _unseen := 0.0
var _owner_actor: Actor


func _ready() -> void:
	_owner_actor = get_parent() as Actor
	_reticle = Label3D.new()
	_reticle.text = "▼"
	_reticle.font_size = 64
	_reticle.outline_size = 12
	_reticle.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_reticle.no_depth_test = true
	_reticle.fixed_size = true
	_reticle.pixel_size = 0.0015
	_reticle.top_level = true
	_reticle.visible = false
	add_child(_reticle)


## Best target seen from `from` looking along `view` (horizontal), or null.
func pick(from: Vector3, view: Vector3, exclude: Targetable = null) -> Targetable:
	view.y = 0.0
	view = view.normalized()
	var best: Targetable = null
	var best_key := Vector3.ZERO
	for node in get_tree().get_nodes_in_group(Targetable.GROUP):
		var t := node as Targetable
		if t == null or t == exclude or not _valid(t):
			continue
		var to := t.global_position - from
		var flat := Vector3(to.x, 0.0, to.z)
		var d := flat.length()
		if d > t.lock_range() or d < 0.01:
			continue
		var angle := rad_to_deg(view.angle_to(flat / d))
		if angle > max_angle or not _visible(from, t):
			continue
		# Lower is better: kind, then off-centre angle scaled by distance, then priority.
		var key := Vector3(int(t.kind), angle * (1.0 + d * 0.15), -t.priority)
		if best == null or _better(key, best_key):
			best = t
			best_key = key
	return best


static func _better(a: Vector3, b: Vector3) -> bool:
	if a.x != b.x:
		return a.x < b.x
	if absf(a.y - b.y) > 2.0:
		return a.y < b.y
	return a.z < b.z if a.z != b.z else a.y < b.y


func lock(t: Targetable) -> void:
	target = t
	_unseen = 0.0


func release() -> void:
	target = null


func _valid(t: Targetable) -> bool:
	if not is_instance_valid(t) or not t.enabled or not t.is_visible_in_tree():
		return false
	var a := t.actor()
	return a == null or (a != _owner_actor and not a.is_dead())


func _visible(from: Vector3, t: Targetable) -> bool:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, t.global_position)
	var exclude: Array[RID] = []
	for a in get_tree().get_nodes_in_group(&"actors"):
		exclude.append((a as CollisionObject3D).get_rid())
	q.exclude = exclude
	return space.intersect_ray(q).is_empty()


func _physics_process(delta: float) -> void:
	if target and not _valid(target):
		release()
	if target and _owner_actor:
		var eye := _owner_actor.global_position + Vector3.UP * 1.4
		var d := Vector2(target.global_position.x - eye.x, target.global_position.z - eye.z).length()
		if d > target.lock_range() * 1.3:
			release()
		elif not _visible(eye, target):
			_unseen += delta
			if _unseen > lose_time:
				release()
		else:
			_unseen = 0.0
	_reticle.visible = target != null
	if target:
		_reticle.global_position = target.global_position + Vector3.UP * 0.55
		_reticle.modulate = Color(1.0, 0.85, 0.2) if target.kind == Targetable.Kind.ENEMY else Color(0.4, 1.0, 0.5)
