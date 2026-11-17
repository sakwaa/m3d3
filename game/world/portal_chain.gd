class_name PortalChain
extends Node
## What a portal's surface shows, rendered level by level (James Lambert's Portal 64 /
## Giles Goddard's Zelda 64 demo: the world drawn again from a camera moved through the
## portal, only where the portal is on screen):
##  - level 1 is the camera moved through the portal once (`crossing`), level 2 twice (the
##    portal seen again through itself: facing portals' tunnel), ... up to `max_depth`;
##  - each level renders only the portal's rectangle on the level before it (a SubViewport
##    that size, the camera's frustum cropped to it): it costs the portal's screen area, and
##    everything outside the rectangle is frustum-culled; the rectangles shrink level by
##    level and the chain stops when one is under `min_pixels` or off screen;
##  - each level's camera clips at the exit (`clip`: an oblique near plane, engine patch 0006
##    Camera3D.clip_plane), so what stands behind the exit doesn't block the view.
## The surface's shader (n64_portal.gdshader) finds which level is drawing it by the camera's
## position and shows the next level's picture, mapped by screen position.
## Levels are nested SubViewports (each inside the one before), so the deepest renders first.
## World: shared with the main view (same zone), or `own_world` (another zone: DropPortal).

const MAX_LEVELS := 8

## The portal's rectangle (local corners, on its plane) and the node it's on.
var entry: Node3D
var corners: PackedVector3Array
## Camera through the portal (world -> world) and the exit's clip plane (world; kept side =
## the normal's).
var crossing := Transform3D.IDENTITY
var clip := Plane()
var use_clip := true
var max_depth := 1
var min_pixels := 12
## The surface's material (views / rects / cam_pos / levels).
var material: ShaderMaterial
var own_world := false
## Levels drawn this frame (0 = none: the surface shows its fallback).
var levels := 0

var _vps: Array[SubViewport] = []
var _cams: Array[Camera3D] = []
static var _has_clip := -1


static func clip_supported() -> bool:
	if _has_clip < 0:
		_has_clip = 1 if ClassDB.class_has_method(&"Camera3D", &"set_clip_plane") else 0
	return _has_clip == 1


## The first level's viewport (an own world's contents go in here).
func root_viewport() -> SubViewport:
	_ensure(1)
	return _vps[0]


func _ensure(n: int) -> void:
	while _vps.size() < mini(n, MAX_LEVELS):
		var vp := SubViewport.new()
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		vp.size = Vector2i(8, 8)
		if _vps.is_empty():
			vp.own_world_3d = own_world
			add_child(vp)
		else:
			_vps[-1].add_child(vp)
		var cam := Camera3D.new()
		# (placed every frame from the main camera, which isn't interpolated either: an
		# interpolated level camera would draw from somewhere between ticks, and the surface
		# wouldn't know it by its position)
		cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		cam.projection = Camera3D.PROJECTION_FRUSTUM
		cam.keep_aspect = Camera3D.KEEP_HEIGHT
		vp.add_child(cam)
		cam.current = true
		_vps.append(vp)
		_cams.append(cam)
		if material:
			material.set_shader_parameter(&"views", _vps.map(func(v: SubViewport): return v.get_texture()))


## Places the levels for this frame from the main camera (the picture `size` pixels).
## `active` false: nothing renders (the surface keeps its last pictures).
func update(cam: Camera3D, size: Vector2i, active: bool) -> void:
	if not active:
		# (hidden: nothing renders; the surface keeps its last pictures and mapping, so a
		# portal coming back into view shows them for the frame or two before it's drawn)
		for vp in _vps:
			vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	var rects: Array[Vector4] = [Vector4(0, 0, 1, 1)]
	var cam_pos: Array[Vector3] = [cam.global_position]
	levels = 0
	var tan_h := tan(deg_to_rad(cam.fov) * 0.5)
	var aspect := float(size.x) / maxf(float(size.y), 1.0)
	if cam.keep_aspect == Camera3D.KEEP_WIDTH:
		tan_h /= aspect  # (fov is horizontal then)
	var xf := cam.global_transform
	var rect := Rect2(0, 0, 1, 1)
	if active and entry and entry.is_inside_tree():
		var world := entry.global_transform
		for j in range(1, max_depth + 1):
			var r: Variant = _project(world, xf, tan_h, aspect, cam.near)
			if r == null:
				break
			var rr: Rect2 = (r as Rect2).intersection(rect)
			if rr.size.x * size.x < min_pixels or rr.size.y * size.y < min_pixels:
				break
			xf = crossing * xf
			rect = rr
			_ensure(j)
			if _vps.size() < j:
				break
			_place(j - 1, xf, rect, size, tan_h, aspect, cam)
			rects.append(Vector4(rect.position.x, rect.position.y, rect.size.x, rect.size.y))
			cam_pos.append(xf.origin)
			levels = j
	for i in _vps.size():
		_vps[i].render_target_update_mode = SubViewport.UPDATE_ALWAYS if i < levels else SubViewport.UPDATE_DISABLED
	if material:
		while rects.size() < MAX_LEVELS + 1:
			rects.append(Vector4(0, 0, 1, 1))
		while cam_pos.size() < MAX_LEVELS + 1:
			cam_pos.append(Vector3(1e9, 1e9, 1e9))
		material.set_shader_parameter(&"rects", rects)
		material.set_shader_parameter(&"cam_pos", cam_pos)
		material.set_shader_parameter(&"levels", levels)


## Level `i`'s viewport and camera: `xf`, the main camera's lens cropped to `rect` (screen
## UV, y down), the exit's clip plane.
func _place(i: int, xf: Transform3D, rect: Rect2, size: Vector2i, tan_h: float, aspect: float, cam: Camera3D) -> void:
	var vp := _vps[i]
	var px := Vector2i((rect.size * Vector2(size)).round()).max(Vector2i.ONE)
	if vp.size != px:
		vp.size = px
	# (MSAA on the first level only: the tunnel's far levels are small, and each level's
	# resolve is a fixed cost)
	vp.msaa_3d = get_viewport().msaa_3d if i == 0 else Viewport.MSAA_DISABLED
	var c := _cams[i]
	c.global_transform = xf
	var hn := cam.near * tan_h
	var wn := hn * aspect
	var cx := (rect.position.x + rect.size.x * 0.5) * 2.0 - 1.0
	var cy := 1.0 - (rect.position.y + rect.size.y * 0.5) * 2.0
	c.set_frustum(rect.size.y * 2.0 * hn, Vector2(cx * wn, cy * hn), cam.near, cam.far)
	c.cull_mask = cam.cull_mask
	if clip_supported():
		c.set(&"clip_plane_enabled", use_clip)
		c.set(&"clip_plane", clip)


## The portal's screen rectangle (UV, y down) seen from a camera at `xf` with the main lens,
## or null when it faces away / is out of view. A corner at or behind the camera: the whole
## screen (conservative).
func _project(world: Transform3D, xf: Transform3D, tan_h: float, aspect: float, near: float) -> Variant:
	var normal := world.basis.z.normalized()
	if (xf.origin - world.origin).dot(normal) <= 0.0:
		return null
	var inv := xf.affine_inverse()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var behind := 0
	for c in corners:
		var p := inv * (world * c)
		if -p.z <= near:
			behind += 1
			continue
		var ndc := Vector2(p.x / (-p.z) / (tan_h * aspect), p.y / (-p.z) / tan_h)
		var uv := Vector2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5)
		lo = lo.min(uv)
		hi = hi.max(uv)
	if behind == corners.size():
		return null  # (all behind the camera)
	if behind > 0:
		return Rect2(0, 0, 1, 1)  # (straddling the camera: conservative)
	var r := Rect2(lo, hi - lo)
	if not r.intersects(Rect2(0, 0, 1, 1)):
		return null
	return r
