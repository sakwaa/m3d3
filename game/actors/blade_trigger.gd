@tool
class_name BladeTrigger
extends Node3D
## The part of a sword that strikes: a stretch of the blade `reach` either side of this
## node along its +Y (the blade's length), `radius` thick. Put one in each sword scene where
## the cutting should happen (a little in from the tip). Swings line it up with the strike
## point they aim at (StrikeRig), and only it touches strike points (Combat): the rest of the
## blade and the hilt pass by. `power` is the sword's strength: armour and guards no harder
## than it turn the blade, softer ones it cuts through (StrikePoint.hardness). Shown as a
## capsule in the editor.

@export_range(0.02, 1.0, 0.01, "suffix:m") var reach := 0.14:
	set(v):
		reach = v
		_redraw()
@export_range(0.01, 0.2, 0.005, "suffix:m") var radius := 0.04:
	set(v):
		radius = v
		_redraw()
## 1 practice / Kokiri, 2 a forged blade, 3 a legendary one.
@export_range(1, 5) var power := 1

var _debug: MeshInstance3D


## The striking stretch [low end, high end] in world space, `scale` times as long (round its
## middle; a finisher's longer reach).
func segment(scale := 1.0) -> Array:
	var xf := global_transform
	return [xf * Vector3(0, -reach * scale, 0), xf * Vector3(0, reach * scale, 0)]


## The trigger's middle in `space` (e.g. the hand bone's: blade.transform-relative).
func centre_in(space: Node3D) -> Vector3:
	return space.global_transform.affine_inverse() * global_position


## The trigger of `sword` (a sword scene), or null.
static func of(sword: Node) -> BladeTrigger:
	if sword == null:
		return null
	for c in sword.get_children():
		if c is BladeTrigger:
			return c
	return null


func _ready() -> void:
	if Engine.is_editor_hint():
		_redraw()


func _redraw() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if _debug:
		_debug.queue_free()
	_debug = MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.radius = radius
	m.height = reach * 2.0 + radius * 2.0
	m.radial_segments = 8
	m.rings = 2
	_debug.mesh = m
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.albedo_color = Color(1.0, 0.4, 0.2, 0.45)
	_debug.material_override = mat
	add_child(_debug, false, INTERNAL_MODE_BACK)
