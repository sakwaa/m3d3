@tool
class_name ActorAnimSpec
extends RefCounted
## Builds an ActorAnimation from an animation spec: a small JSON of key poses as joint
## angles, written by hand or by the reference tools (tools/anim_ref: measured from video).
##
##   {"name": "Run", "fps": 30, "length": 16, "loop": true,
##    "root": "auto",          # hips at the height that puts the lower foot on the ground
##    "mirror_half": false,    # true: keys given for half the cycle, the rest mirrored L/R
##    "keys": [{"frame": 0, "ease": "ease_out", "lean": 12, "lift": 0.0,
##              "thigh_L": 34, "shin_L": [18, 0], "upper_arm_R": [32, 17], ...}]}
##
## Limb angles (thigh, shin, upper_arm, forearm, foot, _L / _R): degrees from straight down
## in the side plane, + = forward; or [swing, out] with out = degrees away from the body.
## lean / neck / head: degrees forward from upright. twist: degrees the chest turns to its
## right (right shoulder back; negative = to the left). lift: metres added to the hips.
## hip_twist / hip_roll: degrees the pelvis turns (like twist) / rocks (+ = right hip up).
## blade_R / blade_L: [swing, out] direction of the held prop (prop_R / prop_L +Y, the
## blade), set by turning the hand (the wrist); omitted = the hand follows the forearm.
## air: true = no foot on the ground (hips stay at rest height; root "auto" skipped).
## windows: {"active": [first, last], ...} frames; events: [{"frame": 3, "name": "swoosh"}].
## Omitted bones keep their rest pose. The model faces -Z.

const EASES := {"smooth": ActorAnimation.Ease.SMOOTH, "linear": ActorAnimation.Ease.LINEAR,
	"ease_in": ActorAnimation.Ease.EASE_IN, "ease_out": ActorAnimation.Ease.EASE_OUT,
	"snap": ActorAnimation.Ease.SNAP, "pop": ActorAnimation.Ease.POP, "step": ActorAnimation.Ease.STEP}
## Posed parents before children (aim_bone works from the parent's posed frame).
const LIMBS := ["thigh", "shin", "foot", "upper_arm", "forearm", "hand"]
## Degrees a shin may swing ahead of its thigh before the knee counts as bent backwards.
const KNEE_TOLERANCE := 8.0


static func load_spec(path: String) -> Dictionary:
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


## New animation for `model` from `spec` (the model's pose / root / angle step are restored).
static func build(model: ActorModel, spec: Dictionary) -> ActorAnimation:
	var saved_pose: Dictionary = model.data.pose.duplicate()
	var saved_root := model.data.root_offset
	var saved_step := model.data.angle_step
	var saved_mode := model.mode
	model.mode = ActorModel.Mode.POSE
	model.data.angle_step = 0.0
	var a := ActorAnimation.new()
	a.name = spec.get("name", "Animation")
	a.fps = int(spec.get("fps", 20))
	a.length = int(spec.get("length", 20))
	a.loop = bool(spec.get("loop", false))
	var keys: Array = spec.get("keys", [])
	if spec.get("mirror_half", false):
		var half := a.length / 2
		for k in keys.duplicate():
			var m := {}
			for f in k:
				m[_swap_side(f)] = k[f]
			m["frame"] = int(k.frame) + half
			keys.append(m)
	var legs := _leg_lengths(model)
	# Knees only bend one way: the shin's angle (forward from straight down) must not be
	# ahead of the thigh's. A spec that has it so is a sign mix-up, not a pose.
	for k in keys:
		for side in ["L", "R"]:
			if k.has("thigh_" + side) and k.has("shin_" + side) and _swing(k, "shin_" + side) > _swing(k, "thigh_" + side) + KNEE_TOLERANCE:
				push_warning("%s frame %d: %s knee bends backwards (shin %.0f deg ahead of thigh %.0f deg: shin angles must be <= thigh)" % [
					a.name, int(k.frame), side, _swing(k, "shin_" + side), _swing(k, "thigh_" + side)])
	for k in keys:
		model.reset_pose()
		var hip_twist := float(k.get("hip_twist", 0.0))
		var hip_roll := float(k.get("hip_roll", 0.0))
		if hip_twist != 0.0 or hip_roll != 0.0:
			var hi := model.bone_index(&"hips")
			if hi >= 0:
				var b := Basis(Vector3.UP, -deg_to_rad(hip_twist)) * Basis(Vector3.BACK, deg_to_rad(hip_roll))
				model.set_global_rotation_of(hi, b * model.pose_global(hi).basis)
		var lean := float(k.get("lean", spec.get("lean", 0.0)))
		_aim(model, &"spine", _upright(lean))
		_aim(model, &"chest", _upright(lean + float(k.get("chest", 0.0))))
		var twist := float(k.get("twist", 0.0))
		if twist != 0.0:
			var ci := model.bone_index(&"chest")
			if ci >= 0:
				model.set_global_rotation_of(ci, Basis(Vector3.UP, -deg_to_rad(twist)) * model.pose_global(ci).basis)
		if k.has("neck") or k.has("lean"):
			_aim(model, &"neck", _upright(float(k.get("neck", lean * 0.4))))
		if k.has("head") or k.has("lean"):
			_aim(model, &"head", _upright(float(k.get("head", 0.0))))
		for limb in LIMBS:
			for side in ["L", "R"]:
				var key: String = limb + "_" + side
				if k.has(key):
					var v = k[key]
					var swing := float(v[0]) if v is Array else float(v)
					var out := float(v[1]) if v is Array and v.size() > 1 else 0.0
					_aim(model, StringName(key), _limb_dir(swing, out, -1.0 if side == "L" else 1.0))
		for side in ["L", "R"]:
			if k.has("blade_" + side):
				var v = k["blade_" + side]
				_point_prop(model, side, _limb_dir(float(v[0]), float(v[1]) if v.size() > 1 else 0.0, -1.0 if side == "L" else 1.0))
		var root := Vector3.ZERO
		if spec.get("root", "auto") == "auto" and legs.x > 0.0 and not k.get("air", false):
			var ext := 0.0
			for side in ["L", "R"]:
				ext = maxf(ext, legs.x * cos(deg_to_rad(_swing(k, "thigh_" + side))) + legs.y * cos(deg_to_rad(_swing(k, "shin_" + side))))
			root.y = ext - (legs.x + legs.y)
		root.y += float(k.get("lift", 0.0))
		model.data.root_offset = root
		model.apply_pose()
		a.set_key(int(k.get("frame", 0)), model.data.pose.duplicate(), root, EASES.get(String(k.get("ease", "smooth")), ActorAnimation.Ease.SMOOTH))
	var windows: Dictionary = spec.get("windows", {})
	for w in windows:
		a.windows[w] = Vector2i(int(windows[w][0]), int(windows[w][1]))
	for e in spec.get("events", []):
		a.events.append({frame = int(e.frame), name = String(e.name)})
	model.data.pose = saved_pose
	model.data.root_offset = saved_root
	model.data.angle_step = saved_step
	model.mode = saved_mode
	model.apply_pose()
	return a


## Direction leaning `deg` forward from straight up (model faces -Z).
static func _upright(deg: float) -> Vector3:
	var r := deg_to_rad(deg)
	return Vector3(0.0, cos(r), -sin(r))


## Limb direction: `swing` degrees from straight down (+ forward), `out` degrees away from
## the body on `side` (-1 left, +1 right).
static func _limb_dir(swing: float, out: float, side: float) -> Vector3:
	var s := deg_to_rad(swing)
	var o := deg_to_rad(out)
	return Vector3(side * sin(o), -cos(s) * cos(o), -sin(s) * cos(o)).normalized()


static func _swing(k: Dictionary, key: String) -> float:
	var v = k.get(key, 0.0)
	return float(v[0]) if v is Array else float(v)


static func _swap_side(field: String) -> String:
	if field.ends_with("_L"):
		return field.substr(0, field.length() - 2) + "_R"
	if field.ends_with("_R"):
		return field.substr(0, field.length() - 2) + "_L"
	return field


## Thigh and shin lengths (rest), for hip height.
static func _leg_lengths(model: ActorModel) -> Vector2:
	var t := model.bone_index(&"thigh_L")
	var s := model.bone_index(&"shin_L")
	var f := model.bone_index(&"foot_L")
	if t < 0 or s < 0 or f < 0:
		return Vector2.ZERO
	return Vector2(model.rest_global(t).origin.distance_to(model.rest_global(s).origin),
		model.rest_global(s).origin.distance_to(model.rest_global(f).origin))


## Turns the hand so its prop bone (+Y: the held blade) points along `dir` (model space).
static func _point_prop(model: ActorModel, side: String, dir: Vector3) -> void:
	var hand := model.bone_index(StringName("hand_" + side))
	var prop := model.bone_index(StringName("prop_" + side))
	if hand < 0 or prop < 0:
		return
	var cur := model.pose_global(prop).basis.y.normalized()
	var q := Quaternion(cur, dir.normalized()) if cur.dot(dir.normalized()) > -0.9999 else Quaternion(Vector3.UP, PI)
	model.set_global_rotation_of(hand, Basis(q) * model.pose_global(hand).basis)


static func _aim(model: ActorModel, bone: StringName, dir: Vector3) -> void:
	var i := model.bone_index(bone)
	if i >= 0:
		model.aim_bone(i, dir)
