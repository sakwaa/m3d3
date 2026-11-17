class_name AimState
extends ActionState
## Aiming an AimItem (the bow) while `hold_action` is held, Tears of the Kingdom style
## (references/aiming/totk_aim_reference.md): the camera sits just behind and above the
## actor (CameraDirector), the body turns to the aim and walks slowly (strafing, like
## Z-targeting's Parallel), the bow comes up over raise_time and the string draws back.
## `fire_action` shoots: the projectile flies from the nock to the point the reticle's ray
## hit (what you aim at is what you hit, at any range); after reload_time the next arrow is
## nocked and drawn. Released -> `release_state`.
##
## Where the reticle points comes from the actor's `aim_view()` (the player: its camera),
## else straight ahead from the head. AimRig poses the body from `raise`, `draw` and
## `aim_dir`; the reticle reads `aim_actor`.

@export var hold_action: StringName = &"aim"
@export var fire_action: StringName = &"attack"
@export var release_state: StringName = &"Ready"

var item: AimItem = AimItem.bow()
## 0..1: the bow coming up (AimRig blends the pose by it).
var raise := 0.0
## 0..1: the string drawn back (0 right after a shot).
var draw := 0.0
## Where the reticle points (world, unit) and what its ray hit.
var aim_dir := Vector3.FORWARD
var aim_point := Vector3.ZERO
## The actor under the reticle (null: none).
var aim_actor: Actor
## Seconds since the last shot (the follow-through, then the next arrow).
var since_shot := INF
var shots := 0


func _init() -> void:
	name = "Aim"
	tags = PackedStringArray(["aiming"])
	blocked_by_tags = PackedStringArray(["airborne", "climbing"])
	restrict = {&"Locomotion": PackedStringArray(["Idle", "Walk", "BattleIdle", "StrafeL", "StrafeR", "StrafeB"])}
	move_scale = 0.45


func enter(previous: ActorState) -> void:
	super.enter(previous)
	raise = 0.0
	draw = 0.0
	since_shot = INF
	_aim()


func exit(next: ActorState) -> void:
	super.exit(next)
	actor.face_dir = Vector3.ZERO


func update(delta: float) -> void:
	if not actor.intent.held(hold_action):
		go(release_state)
		return
	_aim()
	raise = minf(raise + delta / maxf(item.raise_time, 0.01), 1.0)
	since_shot += delta
	if raise >= 1.0 and since_shot >= item.reload_time:
		draw = minf(draw + delta / maxf(item.draw_time, 0.01), 1.0)
	# (A press a moment early stays buffered by the intent and fires once drawn enough.)
	if raise >= 1.0 and draw >= item.min_draw and actor.intent.take(fire_action):
		_fire()
	# Facing the aim (the strafe states take over the legs, as in Z-targeting's Parallel).
	var flat := Vector3(aim_dir.x, 0.0, aim_dir.z)
	if flat.length() > 0.01:
		actor.face_dir = flat.normalized()
	actor.face_target = null


## The reticle's ray: from the view (the camera), starting level with the actor (nothing
## between the camera and the actor counts), out to item.reach.
func _aim() -> void:
	var view: Transform3D
	if actor.has_method(&"aim_view"):
		view = actor.call(&"aim_view")
	else:
		view = Transform3D(Basis.looking_at(actor.facing, Vector3.UP), actor.global_position + Vector3.UP * 1.45)
	var eye := view.origin
	aim_dir = -view.basis.z.normalized()
	var chest := actor.global_position + Vector3.UP * 1.2
	var from := eye + aim_dir * maxf((chest - eye).dot(aim_dir), 0.0)
	var to := eye + aim_dir * item.reach
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [actor.get_rid()]
	var hit := actor.get_world_3d().direct_space_state.intersect_ray(q)
	aim_point = hit.position if not hit.is_empty() else to
	aim_actor = Arrow._actor_of(hit.collider) if not hit.is_empty() else null


## Where the arrow leaves from: the nock (AimRig's, between the hands), else the chest.
func nock_point() -> Vector3:
	var rig = actor.get(&"aim_rig")
	if rig and rig.has_method(&"nock_point"):
		return rig.nock_point()
	return actor.global_position + Vector3.UP * 1.3 + aim_dir * 0.4


func _fire() -> void:
	var from := nock_point()
	var dir := (aim_point - from).normalized() if aim_point.distance_to(from) > 0.5 else aim_dir
	var p := item.make_projectile()
	actor.get_parent().add_child(p)
	if p.has_method(&"launch"):
		p.call(&"launch", from, dir, item.speed, actor, item)
	draw = 0.0
	since_shot = 0.0
	shots += 1
