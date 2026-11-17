@tool
class_name DropPortal
extends Node3D
## A hole in the floor that drops you into another zone: you fall through and come out of
## that zone's sky, still falling, and land in it (a dream fall, a pit into the depths, a
## painting you jump into). The origin is the middle of the hole at floor level, +Y up; the
## floor round it needs the hole cut in it (level geometry) - this adds the picture in the
## hole, the trigger under it and the move.
## Looking into the hole shows the other zone, one of two ways (`style`):
##  - SEAMLESS: the other zone (loaded into a SubViewport with its own world) drawn from where
##    your camera would be on the other side, every frame at the screen's resolution, laid in
##    the hole by screen position: the hole is a window into the other zone's sky. Falling
##    through swaps the zones under a held frame and a short crossfade (the next frame is
##    the same view), carrying your fall, facing and camera across.
##  - RDP: as an N64 would - a small framebuffer copy (`rdp_size`, RGBA16, `rdp_rate` a
##    second, three-point filtered) of the view straight down from the exit, laid on the
##    hole like a picture (Mario Kart 64's big screens, Super Mario 64's paintings), rippling
##    as you come over it; you fall in through the ripple warp (N64VideoOut.Warp).
## Either way the other zone's copy here only draws: its scripts don't run (its sky does,
## without touching the shared shader globals), so it's lit by this zone's globals - the
## same hour and weather, this zone's fog.

enum Style { SEAMLESS, RDP }

@export_file("*.tscn") var target_zone := ""
## Where the hole's middle comes out in the target zone (high in its sky), and how far the
## view turns on the way (degrees about Y).
@export var exit_position := Vector3(0, 40, 0)
@export_range(-180.0, 180.0, 1.0) var exit_yaw := 0.0
## The hole (metres along local x, z).
@export var size := Vector2(3, 3):
	set(v):
		size = v.max(Vector2(0.2, 0.2))
		_rebuild()
@export var style := Style.SEAMLESS
## RDP: the copy's size (texels) and how often it's taken (a second).
@export var rdp_size := Vector2i(64, 64)
@export var rdp_rate := 20.0
## RDP: the view's field of view straight down from the exit (degrees).
@export var rdp_fov := 70.0
## How far below the floor the player falls before the swap (metres).
@export var depth := 1.0
## The other zone is loaded and drawn while the camera is this close (metres).
@export var reach := 45.0

const SHADER := preload("res://game/world/n64_drop_portal.gdshader")
const SEAMLESS_SHADER := preload("res://game/world/n64_portal.gdshader")
## Hidden (no visible pixel in the coverage pass's count) for this many frames: not drawn.
const HIDDEN_FRAMES := 6
const META := &"drop_portal_preview"

var _surface: MeshInstance3D
var _mat: ShaderMaterial
var _trigger: Area3D
var _view: SubViewport
var _cam: Camera3D
var _preview: Node
## The other zone, once loaded (ZoneManager.drop_through uses it: a threaded load is only
## handed out once).
var scene: PackedScene
var _rdp_wait := 0.0
var _ripple := 0.0
var _ripple_at := Vector2(0.5, 0.5)
var _used := false
## SEAMLESS: the view through (PortalChain: only the hole's rectangle on screen, clipped at
## the exit), its frame (+Z up out of the hole) and the surface's material.
var _chain: PortalChain
var _frame: Node3D
var _seam_mat: ShaderMaterial
var _id := 0
var _hidden := 0


## True for nodes in a DropPortal's copy of another zone (they mustn't touch shared state:
## shader globals, screen distortion, the zone manager).
static func is_preview(node: Node) -> bool:
	var vp := node.get_viewport() if node.is_inside_tree() else null
	return vp != null and vp.has_meta(META)


## The move from this side to the other: here (hole, floor level) -> the exit in the sky.
func crossing() -> Transform3D:
	var exit := Transform3D(Basis(Vector3.UP, deg_to_rad(exit_yaw)), exit_position)
	return exit * global_transform.affine_inverse()


func _ready() -> void:
	_rebuild()
	if Engine.is_editor_hint():
		return
	process_priority = 110  # (after CameraDirector places the camera, at 100)
	_trigger = Area3D.new()
	_trigger.monitorable = false
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size.x, 1.0, size.y)
	shape.shape = box
	shape.position.y = -depth - 0.5
	_trigger.add_child(shape)
	add_child(_trigger, false, INTERNAL_MODE_BACK)
	_trigger.body_entered.connect(_on_body_entered)
	if style == Style.SEAMLESS:
		_seam_mat = ShaderMaterial.new()
		_seam_mat.shader = SEAMLESS_SHADER
		_seam_mat.set_shader_parameter(&"fallback", Color.BLACK)
		_surface.material_override = _seam_mat
		_id = WallPortal._next_id
		WallPortal._next_id = maxi(WallPortal._next_id - 1, 40)
		_surface.set_instance_shader_parameter(&"object_id", _id)
		# (the chain's frame: +Z up out of the hole, the hole on its XY plane)
		_frame = Node3D.new()
		_frame.rotation.x = -PI * 0.5
		add_child(_frame, false, INTERNAL_MODE_BACK)
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
	var plane := PlaneMesh.new()
	plane.size = size
	_surface.mesh = plane
	# (just under the floor: the hole's rim covers its edge)
	_surface.position.y = -0.02


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or target_zone.is_empty():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var near := cam.global_position.distance_to(global_position) < reach
	if near and _preview == null:
		_load_preview()
	if _view == null:
		_mat.set_shader_parameter(&"ready", false)
		return
	_mat.set_shader_parameter(&"ready", _preview != null)
	_mat.set_shader_parameter(&"rdp", style == Style.RDP)
	if style == Style.SEAMLESS:
		# The camera as it would be on the other side, only the hole's rectangle, clipped at
		# the exit (what's above it in the other zone's sky doesn't block).
		var hw := size.x * 0.5
		var hd := size.y * 0.5
		_chain.entry = _frame
		_chain.corners = PackedVector3Array([Vector3(-hw, -hd, 0.02), Vector3(hw, -hd, 0.02), Vector3(hw, hd, 0.02), Vector3(-hw, hd, 0.02)])
		_chain.crossing = crossing()
		_chain.clip = Plane(Vector3.DOWN, exit_position)
		_chain.max_depth = 1
		var vp := get_viewport()
		var px := Vector2i((Vector2(vp.get_visible_rect().size) * vp.scaling_3d_scale).round())
		_chain.update(cam, px, near and _preview != null and not _occluded())
	else:
		_rdp_wait -= delta
		if near and _rdp_wait <= 0.0:
			_rdp_wait = 1.0 / maxf(rdp_rate, 1.0)
			_view.render_target_update_mode = SubViewport.UPDATE_ONCE
		_update_ripple(delta)


## Loads the other zone (in the background) into the SubViewport, drawing only.
func _load_preview() -> void:
	if _view == null and style == Style.SEAMLESS:
		_chain = PortalChain.new()
		_chain.own_world = true
		_chain.material = _seam_mat
		add_child(_chain, false, INTERNAL_MODE_BACK)
		_view = _chain.root_viewport()
		_view.set_meta(META, true)
	if _view == null:
		_view = SubViewport.new()
		_view.own_world_3d = true
		_view.set_meta(META, true)
		_view.msaa_3d = get_viewport().msaa_3d
		_view.size = rdp_size if style == Style.RDP else Vector2i(320, 240)
		_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_cam = Camera3D.new()
		_view.add_child(_cam)
		_cam.current = true
		if style == Style.RDP:
			# Straight down from the exit, the picture's top towards the exit's -Z (the hole's
			# UV: u along +x, v along +z).
			var down := Basis(Vector3.RIGHT, Vector3.FORWARD, Vector3.UP)
			_cam.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(exit_yaw)) * down, exit_position)
			_cam.fov = rdp_fov
			_cam.far = 400.0
		add_child(_view, false, INTERNAL_MODE_BACK)
		_mat.set_shader_parameter(&"view", _view.get_texture())
		_mat.set_shader_parameter(&"rdp_size", Vector2(rdp_size))
	var zm := get_node_or_null(^"/root/ZoneManager")
	if zm:
		zm.preload_zone(target_zone)
	var status := ResourceLoader.load_threaded_get_status(target_zone)
	if status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		ResourceLoader.load_threaded_request(target_zone)
		return
	if status != ResourceLoader.THREAD_LOAD_LOADED:
		return
	scene = ResourceLoader.load_threaded_get(target_zone) as PackedScene
	if scene == null:
		return
	if zm:
		zm.forget_preload(target_zone)  # (handed out: travel must ask again)
	_preview = scene.instantiate()
	# Draw only: nothing in it runs but its skies (which leave the shared globals alone).
	_preview.process_mode = Node.PROCESS_MODE_DISABLED
	_view.add_child(_preview)
	for sky in _preview.find_children("*", "DynamicSky", true, false):
		sky.process_mode = Node.PROCESS_MODE_ALWAYS


## No pixel of the hole seen for a while (the coverage pass's count; a frame or two late).
func _occluded() -> bool:
	var vo = RenderScale.video_out()
	if vo == null or not vo.call(&"counting"):
		return false
	if int(vo.call(&"visible_pixels", _id)) > 0:
		_hidden = 0
	else:
		_hidden += 1
	return _hidden > HIDDEN_FRAMES


## RDP: the picture ripples out from where the player crosses over it (SM64's paintings).
func _update_ripple(delta: float) -> void:
	_ripple = maxf(_ripple - delta * 0.6, 0.0)
	var player := get_tree().get_first_node_in_group(&"player") as Node3D
	if player:
		var l := to_local(player.global_position)
		if absf(l.x) < size.x * 0.5 + 0.5 and absf(l.z) < size.y * 0.5 + 0.5 and l.y < 2.5 and l.y > -depth:
			_ripple = 1.0
			_ripple_at = Vector2(l.x / size.x + 0.5, l.z / size.y + 0.5)
	_mat.set_shader_parameter(&"ripple", _ripple)
	_mat.set_shader_parameter(&"ripple_at", _ripple_at)


func _on_body_entered(body: Node3D) -> void:
	if _used or not body.is_in_group(&"player"):
		return
	var zm := get_node_or_null(^"/root/ZoneManager")
	if zm == null or zm.busy:
		return
	_used = true
	zm.drop_through(self, body)
