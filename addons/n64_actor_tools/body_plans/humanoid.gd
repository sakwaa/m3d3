@tool
extends BodyPlan
## Two legs, two arms, upright (people, Moblins, Stalfos...). Arms hang slightly out
## (A-pose); knees bend forward, elbows backward.


func id() -> StringName:
	return &"humanoid"


func params() -> Array[Dictionary]:
	return [
		param("leg_length", 0.78, 0.3, 1.4),
		param("torso_length", 0.48, 0.2, 0.9),
		param("neck_length", 0.07, 0.0, 0.3),
		param("head_size", 0.24, 0.12, 0.6),
		param("hip_width", 0.22, 0.1, 0.5),
		param("shoulder_width", 0.38, 0.2, 0.8),
		param("arm_length", 0.6, 0.3, 1.2),
		param("hand_size", 0.1, 0.05, 0.25),
		param("foot_length", 0.22, 0.1, 0.45),
		param("thickness", 1.0, 0.5, 2.0, 0.05),
		param("arm_spread", 18.0, 0.0, 90.0, 1.0),
	]


func define(p: Dictionary) -> Array[BodyPlan.Bone]:
	var t: float = p.thickness
	var ankle := 0.07
	var hip_y: float = ankle + p.leg_length
	var spine_y := hip_y + 0.12
	var chest_y: float = hip_y + p.torso_length
	var neck_y: float = chest_y + p.neck_length
	var hx: float = p.hip_width * 0.5
	var sx: float = p.shoulder_width * 0.5
	var sh_y := chest_y - 0.05
	var knee_y: float = hip_y - p.leg_length * 0.5
	var a := deg_to_rad(p.arm_spread)
	var arm_dir := Vector3(-sin(a), -cos(a), 0.0)
	var upper: float = p.arm_length * 0.5
	var lower: float = p.arm_length * 0.5
	var shoulder := Vector3(-sx, sh_y, 0.0)
	var elbow := shoulder + arm_dir * upper
	var wrist := elbow + arm_dir * lower
	var bones: Array[BodyPlan.Bone] = [
		block(&"hips", &"", Vector3(0, hip_y, 0), Vector3(0, spine_y, 0), p.hip_width + 0.08 * t, 0.18 * t),
		tube(&"spine", &"hips", Vector3(0, spine_y, 0), Vector3(0, lerpf(spine_y, chest_y, 0.45), 0), 0.11 * t, 0.12 * t),
		block(&"chest", &"spine", Vector3(0, lerpf(spine_y, chest_y, 0.45), 0), Vector3(0, chest_y, 0), p.shoulder_width * 0.85, 0.2 * t),
		tube(&"neck", &"chest", Vector3(0, chest_y, 0), Vector3(0, neck_y, 0), 0.05 * t, 0.05 * t),
		block(&"head", &"neck", Vector3(0, neck_y, 0), Vector3(0, neck_y + p.head_size, 0), p.head_size * 0.8, p.head_size * 0.85),
		joint(&"clavicle_L", &"chest", Vector3(-0.04, sh_y, 0), shoulder),
		tube(&"upper_arm_L", &"clavicle_L", shoulder, elbow, 0.045 * t, 0.04 * t),
		tube(&"forearm_L", &"upper_arm_L", elbow, wrist, 0.04 * t, 0.032 * t),
		block(&"hand_L", &"forearm_L", wrist, wrist + arm_dir * p.hand_size, p.hand_size * 0.7, 0.04 * t),
		# Prop bone: the grip in the middle of the hand, +Y along a held blade (forward).
		# Keyed like any bone (grip shifts, spins); items attach here (ActorSockets).
		joint(&"prop_L", &"hand_L", wrist + arm_dir * p.hand_size * 0.5, wrist + arm_dir * p.hand_size * 0.5 + Vector3(0, 0, -0.15)),
		tube(&"thigh_L", &"hips", Vector3(-hx * 0.5 - 0.02, hip_y, 0), Vector3(-hx, knee_y, 0), 0.07 * t, 0.055 * t),
		tube(&"shin_L", &"thigh_L", Vector3(-hx, knee_y, 0), Vector3(-hx, ankle, 0), 0.05 * t, 0.04 * t),
		block(&"foot_L", &"shin_L", Vector3(-hx, ankle, 0), Vector3(-hx, 0.02, -p.foot_length * 0.75), 0.09 * t, 0.06 * t),
	]
	return bones


func chains() -> Array[BodyPlan.Chain]:
	return [
		chain(&"arm_L", &"upper_arm_L", &"forearm_L", &"hand_L", Vector3.BACK),
		chain(&"leg_L", &"thigh_L", &"shin_L", &"foot_L", Vector3.FORWARD),
	]
