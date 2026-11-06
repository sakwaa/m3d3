@tool
class_name ActorClipboard
extends RefCounted
## Editor clipboard for poses and key ranges, by bone name: pastes into any character
## (same body plan = every bone matches; other plans take the bones they share),
## optionally mirrored (left <-> right) — e.g. copy the first half of a walk and paste it
## mirrored for the other leg. Lives for the editor session.

## [{offset: int (frames from the first copied key), pose, root, ease}]
static var keys: Array = []
static var plan: StringName


static func copy_pose(from_plan: StringName, pose: Dictionary, root: Vector3) -> void:
	plan = from_plan
	keys = [{offset = 0, pose = pose.duplicate(), root = root, ease = ActorAnimation.Ease.SMOOTH}]


static func copy_keys(from_plan: StringName, src: Array) -> void:
	plan = from_plan
	keys.clear()
	if src.is_empty():
		return
	var first: int = src[0].frame
	for k in src:
		first = mini(first, k.frame)
	for k in src:
		keys.append({offset = k.frame - first, pose = k.pose.duplicate(), root = k.root, ease = k.ease})
	keys.sort_custom(func(a, b): return a.offset < b.offset)


static func has_pose() -> bool:
	return not keys.is_empty()


## The copied keys, mirrored if asked, keeping only bones `bones` has (by name).
static func paste(bones: Dictionary, mirror: bool) -> Array:
	var out := []
	for k in keys:
		var pose: Dictionary = ActorAnimation.mirror_pose(k.pose) if mirror else k.pose.duplicate()
		var kept := {}
		for b in pose:
			if bones.has(b):
				kept[b] = pose[b]
		out.append({offset = k.offset, pose = kept, root = ActorAnimation.mirror_root(k.root) if mirror else k.root, ease = k.ease})
	return out
