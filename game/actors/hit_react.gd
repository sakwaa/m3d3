class_name HitReact
extends SkeletonModifier3D
## Physical hit reactions over whatever animation plays: a hit kicks a few springy bones
## (pelvis / hips, spine, chest, neck, head) in the way the blow pushed, harder the nearer
## the bone is to where it landed, and they swing back with a little overshoot. A head hit
## snaps the head away from the blade, a flank hit folds the body sideways, a stab doubles
## it over; always in step with the strike, because the strike drives it. Through the
## hitstop freeze the body holds its impact pose, then springs. A child of the actor's
## Skeleton3D (Actor.hit_react; Actor.take_hit kicks it).

## Bones that react, with how much each gives, base first. Each turn rides on its parents',
## so the head's total is the sum down the chain (about 1.3 x a single bone's here).
const CHAIN := [[&"pelvis", 0.12], [&"hips", 0.12], [&"spine", 0.22], [&"chest", 0.3], [&"neck", 0.28], [&"head", 0.4]]
## Spring: angular frequency (rad/s) and damping ratio (< 1: a small overshoot).
const OMEGA := 17.0
const DAMPING := 0.42
## Most a bone turns away (radians).
const MAX_ANGLE := 0.45
## Share of the kick shown at once (the impact pose held through the hitstop).
const IMPACT_SHARE := 0.4

var actor: Actor
## Off: no reactions (the sandbox compares).
static var enabled := true

var _bones := []  # [bone index, weight]
var _angle := []  # per bone: rotation vector (skeleton space)
var _vel := []


func _init(p_actor: Actor = null) -> void:
	actor = p_actor
	name = "HitReact"


## A blow pushing `dir` (world) with `strength` (about 1 = an ordinary hit) at `at` (world).
func kick(dir: Vector3, strength: float, at: Vector3) -> void:
	var sk := get_skeleton()
	if sk == null or not enabled:
		return
	_find_bones(sk)
	var inv := sk.global_transform.affine_inverse()
	var d := (inv.basis * dir).normalized()
	var p := inv * at
	for i in _bones.size():
		var b: int = _bones[i][0]
		var origin := sk.get_bone_global_pose(b).origin
		# Torque: the push across the lever from the bone to the hit (pivoting at the bone);
		# straight through it (a stab at the chest) still bends the body back.
		var lever := p - origin
		var axis := lever.cross(d)
		if axis.length() < 0.05:
			axis = Vector3.UP.cross(d)
		var near := clampf(1.0 - lever.length() / 1.6, 0.25, 1.0)
		var amount: float = strength * _bones[i][1] * near
		var kick_v := axis.normalized() * amount * OMEGA * 0.6
		_vel[i] += kick_v
		_angle[i] += kick_v / OMEGA * IMPACT_SHARE


func _find_bones(sk: Skeleton3D) -> void:
	if not _bones.is_empty():
		return
	for spec in CHAIN:
		var b := sk.find_bone(spec[0])
		if b >= 0:
			_bones.append([b, spec[1]])
			_angle.append(Vector3.ZERO)
			_vel.append(Vector3.ZERO)


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or _bones.is_empty():
		return
	var frozen := actor != null and actor.in_hitstop()
	var any := false
	for i in _bones.size():
		var a: Vector3 = _angle[i]
		var v: Vector3 = _vel[i]
		if not frozen:
			# Damped spring back to the animation's pose.
			var acc := -OMEGA * OMEGA * a - 2.0 * DAMPING * OMEGA * v
			v += acc * delta
			a += v * delta
			if a.length() > MAX_ANGLE:
				a = a.normalized() * MAX_ANGLE
			if a.length() < 0.0005 and v.length() < 0.005:
				a = Vector3.ZERO
				v = Vector3.ZERO
			_angle[i] = a
			_vel[i] = v
		if a != Vector3.ZERO:
			any = true
	if not any:
		return
	# Base first, so each bone's turn rides on its parents'.
	for i in _bones.size():
		var a: Vector3 = _angle[i]
		if a == Vector3.ZERO:
			continue
		var b: int = _bones[i][0]
		var parent := sk.get_bone_parent(b)
		var pb := sk.get_bone_global_pose(parent).basis if parent >= 0 else Basis()
		var axis_parent := (pb.inverse() * a.normalized()).normalized()
		var turn := Quaternion(axis_parent, a.length())
		sk.set_bone_pose_rotation(b, turn * sk.get_bone_pose_rotation(b))
