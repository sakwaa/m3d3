extends Camera3D
## Orbit camera for the mesh builder: orbits / pans / zooms around a target, and snaps
## to orthographic views of the model's sides (models face -Z: Front looks at their face).
## Changes ease in over a few frames. Orbiting away from a snapped view goes back to
## perspective (like Blender / Godot's auto orthographic).

enum View { PERSPECTIVE, FRONT, BACK, LEFT, RIGHT, TOP, BOTTOM }
const VIEW_ANGLES := {
	View.FRONT: Vector2(PI, 0.0), View.BACK: Vector2(0.0, 0.0),
	View.LEFT: Vector2(-PI / 2.0, 0.0), View.RIGHT: Vector2(PI / 2.0, 0.0),
	View.TOP: Vector2(PI, PI / 2.0), View.BOTTOM: Vector2(PI, -PI / 2.0),
}
const ORBIT_SPEED := 0.004  # radians per design pixel: a full-width swipe ~ 270°
## Up / down is gentler: portrait screens are tall, and pitch only spans 180°.
const PITCH_SPEED := 0.0018
const EASE := 14.0

var target := Vector3(0, 0.9, 0)
var yaw := PI * 0.85
var pitch := 0.25
var distance := 3.2
var view := View.PERSPECTIVE

var _goal_target := target
var _goal_yaw := yaw
var _goal_pitch := pitch
var _goal_distance := distance


func _ready() -> void:
	fov = 40.0
	near = 0.02
	far = 200.0
	_apply()


func _process(delta: float) -> void:
	var k := 1.0 - exp(-EASE * delta)
	target = target.lerp(_goal_target, k)
	yaw = lerp_angle(yaw, _goal_yaw, k)
	pitch = lerpf(pitch, _goal_pitch, k)
	distance = lerpf(distance, _goal_distance, k)
	_apply()


func _apply() -> void:
	var dir := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	position = target + dir * distance
	# Straight down / up: screen up is the model's front (-Z).
	var up := Vector3.UP if absf(pitch) < 1.5 else Vector3(-sin(yaw), 0, -cos(yaw))
	look_at(target, up)
	if view == View.PERSPECTIVE:
		projection = PROJECTION_PERSPECTIVE
	else:
		projection = PROJECTION_ORTHOGONAL
		size = 2.0 * distance * tan(deg_to_rad(fov) * 0.5)


## One-finger drag (pixels).
func orbit(delta: Vector2) -> void:
	_goal_yaw -= delta.x * ORBIT_SPEED
	_goal_pitch = clampf(_goal_pitch + delta.y * PITCH_SPEED, -1.55, 1.55)
	yaw = _goal_yaw
	pitch = _goal_pitch
	view = View.PERSPECTIVE


## Two-finger drag (pixels): the model follows the fingers.
func pan(delta: Vector2) -> void:
	var w := world_per_pixel()
	_goal_target += (-global_basis.x * delta.x + global_basis.y * delta.y) * w
	target = _goal_target


## Pinch: > 1 closer.
func zoom(factor: float) -> void:
	_goal_distance = clampf(_goal_distance / maxf(factor, 0.01), 0.15, 40.0)
	distance = _goal_distance


func set_view(v: View) -> void:
	view = v
	if VIEW_ANGLES.has(v):
		var a: Vector2 = VIEW_ANGLES[v]
		# Shortest way round to the new yaw.
		_goal_yaw = yaw + wrapf(a.x - yaw, -PI, PI)
		_goal_pitch = a.y


## Centres on a box (model space = world here) and fits it in view.
func frame(box: AABB) -> void:
	_goal_target = box.get_center()
	var radius := maxf(box.size.length() * 0.5, 0.1)
	_goal_distance = radius / tan(deg_to_rad(fov) * 0.5) * 1.15


## World units per screen pixel at the target's depth.
func world_per_pixel() -> float:
	var h := float(get_viewport().get_visible_rect().size.y)
	return 2.0 * distance * tan(deg_to_rad(fov) * 0.5) / maxf(h, 1.0)


func view_name() -> String:
	return ["Perspective", "Front", "Back", "Left", "Right", "Top", "Bottom"][view]
