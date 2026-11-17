@tool
class_name WallPortal
extends Node3D
## One end of a pair of portals in walls (`pair`): you see through it to what's in front
## of the other end, and walking through comes out of the other end. Facing portals see
## each other: the view through recurses, level after level, each only the portal's
## shrinking rectangle on screen (PortalChain).
## Frame: the origin is the bottom middle of the opening on the wall's face, +Z points
## out of the wall (the side you look and walk in from), the opening `size` (x across,
## y up). The wall needs the opening cut and room behind it (an alcove a few metres deep):
## the third-person camera's arm reaches back through the other portal as you come out of it,
## and the view is then drawn as if from this side (`follow_camera`), so it doesn't jump.
## Culling: a level is drawn only where the rectangle is on screen and large enough; the
## main view's coverage pass counts the surface's visible pixels (N64VideoOut.count_visible)
## and a portal no pixel of which was seen (behind a wall) isn't drawn at all.
## Needs the patched engine (0006, Camera3D.clip_plane) for the exit's clip; without it the
## view isn't clipped at the exit (what's behind it shows).

@export var pair: NodePath
@export var size := Vector2(2.4, 3.2):
	set(v):
		size = v.max(Vector2(0.2, 0.2))
		_rebuild()
## Levels of the view through (facing portals: the tunnel's depth).
@export_range(1, 8) var max_depth := 6
## A level smaller than this (pixels, either way) isn't drawn: the tunnel's far end.
@export var min_pixels := 12
## Shown past the last level.
@export var fallback := Color(0.02, 0.02, 0.03)
## Carry the third-person camera through with the player (see above).
@export var follow_camera := true

const SHADER := preload("res://game/world/n64_portal.gdshader")
## Hidden for this many count frames (no visible pixel) before it stops drawing.
const HIDDEN_FRAMES := 6

static var _next_id := 62
static var _remapped_frame := -1
static var _all: Array[WallPortal] = []

var chain: PortalChain
var _surface: MeshInstance3D
var _mat: ShaderMaterial
var _id := 0
var _hidden := 0
var _prev_side := {}


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		_all.append(self)


func _exit_tree() -> void:
	_all.erase(self)


func _ready() -> void:
	_rebuild()
	if Engine.is_editor_hint():
		return
	# (after the player moves and the camera is placed: CameraDirector runs at 100)
	process_priority = 110
	process_physics_priority = 100
	_id = _next_id
	_next_id = maxi(_next_id - 1, 40)
	_surface.set_instance_shader_parameter(&"object_id", _id)
	chain = PortalChain.new()
	chain.material = _mat
	add_child(chain, false, INTERNAL_MODE_BACK)
	var vo = RenderScale.video_out()
	if vo:
		vo.set(&"count_visible", true)


func _rebuild() -> void:
	if not is_inside_tree():
		return
	if _surface == null:
		_surface = MeshInstance3D.new()
		_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_mat = ShaderMaterial.new()
		_mat.shader = SHADER
		_surface.material_override = _mat
		add_child(_surface, false, INTERNAL_MODE_BACK)
	var q := QuadMesh.new()
	q.size = size
	_surface.mesh = q
	_surface.position = Vector3(0, size.y * 0.5, 0)
	_mat.set_shader_parameter(&"fallback", fallback)


func other() -> WallPortal:
	return get_node_or_null(pair) as WallPortal


## World -> world: in front of this portal to behind the other, and behind this one to in
## front of the other (turned round: you come out facing away from it).
func crossing() -> Transform3D:
	var o := other()
	if o == null:
		return Transform3D.IDENTITY
	return o.global_transform * Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO) * global_transform.affine_inverse()


## The opening's corners (local).
func corners() -> PackedVector3Array:
	var hw := size.x * 0.5
	return PackedVector3Array([Vector3(-hw, 0, 0), Vector3(hw, 0, 0), Vector3(hw, size.y, 0), Vector3(-hw, size.y, 0)])


## Whether world point `p` lies in the opening's span (across and up) and its side (+ front).
func _side(p: Vector3) -> float:
	return (global_transform.affine_inverse() * p).z


func _in_opening(p: Vector3) -> bool:
	var l := global_transform.affine_inverse() * p
	return absf(l.x) <= size.x * 0.5 and l.y >= -0.5 and l.y <= size.y + 0.5


func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or other() == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	if _remapped_frame != Engine.get_process_frames():
		_remapped_frame = Engine.get_process_frames()
		_follow(cam)
	var o := other()
	chain.entry = self
	chain.corners = corners()
	chain.crossing = crossing()
	# (the exit's plane, its front kept: what's behind the other portal doesn't block)
	chain.clip = Plane(o.global_transform.basis.z.normalized(), o.global_position)
	chain.max_depth = max_depth
	chain.min_pixels = min_pixels
	var vp := get_viewport()
	var px := Vector2i((Vector2(vp.get_visible_rect().size) * vp.scaling_3d_scale).round())
	chain.update(cam, px, not _occluded())


## No pixel of the surface seen for a while (the coverage pass's count; a frame or two late).
func _occluded() -> bool:
	var vo = RenderScale.video_out()
	if vo == null or not vo.call(&"counting"):
		return false
	if int(vo.call(&"visible_pixels", _id)) > 0:
		_hidden = 0
	else:
		_hidden += 1
	return _hidden > HIDDEN_FRAMES


## The camera's arm reaching back through a portal (the player just came out of it): the
## view is drawn from where it would be on the other side, looking through - as it was a
## moment before, so the crossing doesn't jump.
static func _follow(cam: Camera3D) -> void:
	var player := cam.get_tree().get_first_node_in_group(&"player") as Node3D
	if player == null or not "_yaw" in player:
		return
	var pivot: Vector3 = (player.get(&"_yaw") as Node3D).global_position
	var at := cam.global_position
	for p in _all:
		if not p.follow_camera or p.other() == null:
			continue
		var a := p._side(pivot)
		var b := p._side(at)
		if a > 0.0 and b < 0.0:
			var hit := pivot.lerp(at, a / (a - b))
			if p._in_opening(hit):
				cam.global_transform = p.crossing() * cam.global_transform
				return


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or other() == null:
		return
	# Walking through: the player's middle crossing the plane inside the opening.
	for body in get_tree().get_nodes_in_group(&"player"):
		var b := body as CharacterBody3D
		if b == null:
			continue
		var mid := b.global_position + Vector3.UP * 0.9
		var s := _side(mid)
		var was: float = _prev_side.get(b.get_instance_id(), s)
		_prev_side[b.get_instance_id()] = s
		if was > 0.0 and s <= 0.0 and _in_opening(mid):
			_carry(b)


## Moves `b` through: the same place, fall, facing and camera turn, out of the other one.
func _carry(b: CharacterBody3D) -> void:
	var xf := crossing()
	var turn := xf.basis.get_euler().y
	var vel := xf.basis * b.velocity
	var at := xf * b.global_position
	if b.has_method(&"teleport"):
		var yaw: float = (b.get(&"_yaw") as Node3D).rotation.y if "_yaw" in b else 0.0
		b.teleport(Transform3D(Basis.IDENTITY, at))
		if "_yaw" in b:
			(b.get(&"_yaw") as Node3D).rotation.y = yaw + turn
	else:
		b.global_position = at
		b.reset_physics_interpolation()
	b.velocity = vel
	if b is Actor:
		(b as Actor).facing = xf.basis * (b as Actor).facing
	# (no crossing straight back: the other end starts on its front side)
	var o := other()
	o._prev_side[b.get_instance_id()] = o._side(at + Vector3.UP * 0.9)
