class_name LandDip
extends SkeletonModifier3D
## Soft landings (Actor.land_dip()): lowers the hips a little and bends the knees to keep
## the feet where the animation put them, so the body gives on impact without the feet
## sinking into the ground. A child of the actor's Skeleton3D.

const LEGS := [[&"thigh_L", &"shin_L", &"foot_L"], [&"thigh_R", &"shin_R", &"foot_R"]]

var actor: Actor
var _hips := -1
var _legs := []


func _init(p_actor: Actor = null) -> void:
	actor = p_actor
	name = "LandDip"


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or actor == null:
		return
	var dip := actor.land_dip()
	if dip <= 0.0:
		return
	if _hips < 0:
		_hips = sk.find_bone(&"hips")
		for chain in LEGS:
			_legs.append([sk.find_bone(chain[0]), sk.find_bone(chain[1]), sk.find_bone(chain[2])])
		if _hips < 0 or _legs.any(func(ids): return ids.has(-1)):
			active = false
			return
	var feet := []
	for ids in _legs:
		feet.append(sk.get_bone_global_pose(ids[2]).origin)
	var down := sk.global_transform.basis.inverse() * Vector3.DOWN * dip
	var h := sk.get_bone_global_pose(_hips)
	sk.set_bone_global_pose(_hips, Transform3D(h.basis, h.origin + down))
	var fwd := sk.global_transform.basis.inverse() * actor.facing  # knees bend forward
	for k in _legs.size():
		var ids: Array = _legs[k]
		ClimbRig.two_bone(sk, ids, feet[k], sk.get_bone_global_pose(ids[0]).origin + fwd)
