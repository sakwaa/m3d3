@tool
extends BodyPlan
## Four legs, horizontal spine, neck, head with a jaw, tail (wolves, dogs, boars...).
## Front elbows bend backward, back knees forward. Faces -Z.


func id() -> StringName:
	return &"quadruped"


func params() -> Array[Dictionary]:
	return [
		param("body_length", 0.9, 0.4, 2.5),
		param("body_width", 0.28, 0.12, 0.8),
		param("shoulder_height", 0.6, 0.2, 1.5),
		param("hip_height", 0.58, 0.2, 1.5),
		param("neck_length", 0.28, 0.05, 0.8),
		param("head_length", 0.3, 0.12, 0.8),
		param("tail_length", 0.45, 0.0, 1.5),
		param("thickness", 1.0, 0.5, 2.0, 0.05),
	]


func define(p: Dictionary) -> Array[BodyPlan.Bone]:
	var t: float = p.thickness
	var bl: float = p.body_length
	var w: float = p.body_width * 0.5
	var sh: float = p.shoulder_height
	var hh: float = p.hip_height
	var back := bl * 0.5
	var front := -bl * 0.5
	var pelvis := Vector3(0, hh, back)
	var mid := Vector3(0, lerpf(hh, sh, 0.5) + 0.03, 0)
	var chest := Vector3(0, sh, front)
	var neck_end: Vector3 = chest + Vector3(0, 0.7, -0.7).normalized() * p.neck_length
	var head_end: Vector3 = neck_end + Vector3(0, -0.15, -1).normalized() * p.head_length
	var tail_mid: Vector3 = pelvis + Vector3(0, 0.1, 1).normalized() * p.tail_length * 0.5
	var tail_end: Vector3 = tail_mid + Vector3(0, -0.2, 1).normalized() * p.tail_length * 0.5
	var paw := 0.06
	var bones: Array[BodyPlan.Bone] = [
		block(&"pelvis", &"", pelvis, pelvis.lerp(mid, 0.5), p.body_width * 0.9, 0.24 * t),
		tube(&"spine", &"pelvis", pelvis.lerp(mid, 0.5), mid, 0.13 * t, 0.14 * t, 6),
		block(&"chest", &"spine", mid, chest, p.body_width, 0.3 * t),
		tube(&"neck", &"chest", chest, neck_end, 0.08 * t, 0.07 * t),
		block(&"head", &"neck", neck_end, head_end, 0.16 * t, 0.15 * t),
		block(&"jaw", &"head", neck_end + Vector3(0, -0.05, -0.05), head_end + Vector3(0, -0.07, 0), 0.12 * t, 0.05 * t),
		tube(&"tail_1", &"pelvis", pelvis, tail_mid, 0.05 * t, 0.04 * t, 5),
		tube(&"tail_2", &"tail_1", tail_mid, tail_end, 0.04 * t, 0.015 * t, 5),
		# Front legs: elbow behind the shoulder.
		tube(&"upper_front_L", &"chest", Vector3(-w, sh - 0.05, front + 0.05), Vector3(-w, sh * 0.5, front + 0.1), 0.055 * t, 0.045 * t),
		tube(&"lower_front_L", &"upper_front_L", Vector3(-w, sh * 0.5, front + 0.1), Vector3(-w, paw, front + 0.05), 0.04 * t, 0.032 * t),
		block(&"paw_front_L", &"lower_front_L", Vector3(-w, paw, front + 0.05), Vector3(-w, 0.02, front - 0.06), 0.07 * t, 0.04 * t),
		# Back legs: knee forward of the hip.
		tube(&"thigh_L", &"pelvis", Vector3(-w, hh - 0.05, back - 0.02), Vector3(-w, hh * 0.5, back - 0.12), 0.07 * t, 0.05 * t),
		tube(&"shin_L", &"thigh_L", Vector3(-w, hh * 0.5, back - 0.12), Vector3(-w, paw, back), 0.04 * t, 0.03 * t),
		block(&"paw_back_L", &"shin_L", Vector3(-w, paw, back), Vector3(-w, 0.02, back - 0.11), 0.07 * t, 0.04 * t),
	]
	return bones


func chains() -> Array[BodyPlan.Chain]:
	return [
		chain(&"front_leg_L", &"upper_front_L", &"lower_front_L", &"paw_front_L", Vector3.BACK),
		chain(&"back_leg_L", &"thigh_L", &"shin_L", &"paw_back_L", Vector3.FORWARD),
	]
