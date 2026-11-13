@tool
class_name GradeFill
extends GradeFilter
## A flat colour: a glaze over the layer through its blend mode (Multiply darkens, Hard
## light glazes like thin paint, Colour recolours, Soft light warms / cools gently).

@export var colour := Color(0.85, 0.6, 0.4)


func _init() -> void:
	blend = Blend.SOFT_LIGHT
	opacity = 0.5


func title() -> String:
	return "Colour fill"


func apply(_c: Color, _i: int) -> Color:
	return colour
