@tool
extends BodyPlan
## A held or placed prop (sword, shield, torch, crate...): one bone from the grip / base
## at the origin along +Y, so held items line up with the hands' prop bones (ActorSockets:
## grip at the origin, blade along +Y). Model the whole prop on that bone.


func id() -> StringName:
	return &"prop"


func params() -> Array[Dictionary]:
	return [
		param("length", 0.6, 0.05, 4.0),
		param("width", 0.08, 0.01, 2.0),
		param("depth", 0.03, 0.01, 2.0),
	]


func define(p: Dictionary) -> Array[BodyPlan.Bone]:
	var bones: Array[BodyPlan.Bone] = [
		block(&"root", &"", Vector3.ZERO, Vector3(0, p.length, 0), p.width, p.depth),
	]
	return bones
