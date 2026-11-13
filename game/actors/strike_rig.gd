class_name StrikeRig
extends SkeletonModifier3D
## Bends a swing onto the strike point it aims at (AttackState.aim, picked by Combat): over
## whatever swing animation plays, the spine and chest turn and pitch so the blade's natural
## contact point (where the animation alone would put the sword's BladeTrigger when the
## active window opens) lines up with the target - a chop at a Wolfos' head from the front, lower into its
## flank from the side. Blends in over the wind-up, holds through the strike, eases out.
## (Stepping in or out to the right distance is Combat.aim_swing's.)
##
## Edge first: through every swing the blade rolls about its length so an edge (the held
## prop's ±X, the blade's width) leads the way the blade moves - it cuts with the edge,
## never slaps with the flat - and follows through the same way. Whichever edge is nearer
## leads (no flipping mid-arc).

## Share of the bend taken by the spine (the chest takes the rest).
const SPINE_SHARE := 0.4
## Most the body turns / pitches for an aim (radians).
const MAX_YAW := 0.6
const MAX_PITCH := 0.7
## Where the trigger lands at contact before a swing has been seen (skeleton space).
const DEFAULT_CONTACT := Vector3(0.0, 1.15, -0.8)

var actor: Actor
## Off: swings play as authored (the sandbox compares).
static var enabled := true

var _spine := -1
var _chest := -1
var _prop := -1
var _contact := {}  # swing name -> blade trigger at contact (skeleton space, as animated)
var _seen := {}  # swing name -> already measured this swing
var _swing: AttackState
var _prev_sweet := Vector3.INF
var _roll := 0.0  # the edge roll applied last frame (smoothed)
## Off: the blade keeps the animation's roll (the sandbox compares).
static var edge_lead := true


func _init(p_actor: Actor = null) -> void:
	actor = p_actor
	name = "StrikeRig"


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or actor == null:
		return
	if _spine < 0:
		_spine = sk.find_bone(&"spine")
		_chest = sk.find_bone(&"chest")
		_prop = sk.find_bone(&"prop_R")
		if _spine < 0 or _chest < 0 or _prop < 0:
			active = false
			return
	var swing := actor.state_of(Actor.ACTION) as AttackState
	if swing != _swing:
		_swing = swing
		_seen.erase(swing.name if swing else &"")
	if swing == null or not swing.windows.has(&"active"):
		_prev_sweet = Vector3.INF
		_roll = 0.0
		return
	var w: Vector2 = swing.windows[&"active"]
	var p := swing.progress()
	# Measure the animation's own contact point the first time through (before bending it).
	if not _seen.has(swing.name) and p >= w.x:
		_seen[swing.name] = true
		if not _contact.has(swing.name):
			_contact[swing.name] = sk.get_bone_global_pose(_prop) * actor.blade_trigger_local()
	var k := smoothstep(0.0, maxf(w.x, 0.01), p) * (1.0 - smoothstep(w.y, minf(w.y + 0.3, 1.0), p))
	_aim_bend(sk, swing, k)
	# The edge leads from the first moment of the swing to the end of the follow-through.
	_lead_edge(sk, smoothstep(0.0, 0.08, p) * (1.0 - smoothstep(minf(w.y + 0.3, 0.9), 1.0, p)))


## Rolls the blade so an edge leads its motion (see the class notes).
func _lead_edge(sk: Skeleton3D, k: float) -> void:
	var g := sk.get_bone_global_pose(_prop)
	var along := g.basis.y.normalized()
	var sweet := g * actor.blade_trigger_local()
	var moved := sweet - _prev_sweet if _prev_sweet != Vector3.INF else Vector3.ZERO
	_prev_sweet = sweet
	if not edge_lead or k <= 0.0:
		_roll = 0.0
		return
	var across := moved - along * moved.dot(along)
	var want := _roll
	if across.length() > 0.004:
		var edge := (g.basis.x - along * g.basis.x.dot(along)).normalized()
		var a := edge.signed_angle_to(across.normalized(), along)
		if absf(a) > PI * 0.5:
			a -= signf(a) * PI  # the other edge is nearer: it leads
		want = a
	_roll = lerp_angle(_roll, want, 0.7)
	sk.set_bone_global_pose(_prop, Transform3D(Basis(along, _roll * k) * g.basis, g.origin))


func _aim_bend(sk: Skeleton3D, swing: AttackState, k: float) -> void:
	var aim := swing.aim
	if aim == null or not enabled or not is_instance_valid(aim) or k <= 0.0:
		return
	var to_sk := sk.global_transform.affine_inverse()
	var pivot := sk.get_bone_global_pose(_chest).origin
	var nominal: Vector3 = _contact.get(swing.name, DEFAULT_CONTACT) - pivot
	var target := to_sk * aim.global_position - pivot
	# The model faces -Z: yaw about +Y, pitch about +X (+ lifts the front).
	var yaw := clampf(atan2(-target.x, -target.z) - atan2(-nominal.x, -nominal.z), -MAX_YAW, MAX_YAW)
	var pitch := clampf(atan2(target.y, Vector2(target.x, target.z).length()) - atan2(nominal.y, Vector2(nominal.x, nominal.z).length()),
		-MAX_PITCH, MAX_PITCH)
	_bend(sk, _spine, yaw * SPINE_SHARE * k, pitch * SPINE_SHARE * k)
	_bend(sk, _chest, yaw * (1.0 - SPINE_SHARE) * k, pitch * (1.0 - SPINE_SHARE) * k)


## Turns `bone` (and so everything above it) by `yaw` about up, then `pitch` about the
## body's right, in skeleton space.
static func _bend(sk: Skeleton3D, bone: int, yaw: float, pitch: float) -> void:
	var g := sk.get_bone_global_pose(bone)
	var r := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	sk.set_bone_global_pose(bone, Transform3D(r * g.basis, g.origin))
