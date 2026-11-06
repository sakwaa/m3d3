class_name ProjectedShadow
extends Node3D
## Fake real-time character shadow (late-N64 / PS1 style): for the sun (or moon) and the
## nearest omni lights, the caster's silhouette is rendered from the light into a tiny
## texture and projected along the light direction (a decal-like box that reprojects the
## depth buffer: projected_shadow.gdshader), so it falls across
## floors, stairs and walls, stretches at dusk and swings away from torches. Cost: the
## caster's own triangles per light plus a 64 x 64 render; no shadow maps.
## Add as a child of the actor (the caster defaults to the parent).

## Visual layers: the caster's meshes move to ACTOR_LAYER (not lit by its own shadow) and
## CASTER_LAYER (what the silhouette cameras see). Its materials write stencil 1 so the
## projection skips it (custom ShaderMaterials need `stencil_mode write, compare_always, 1;`).
const ACTOR_LAYER := 1 << 1
const CASTER_LAYER := 1 << 19
const STENCIL_REF := 1
const SHADER := preload("res://addons/n64_runtime/shaders/projected_shadow.gdshader")

@export var caster: Node3D
## Shadows at most: the sun / moon first, then the strongest omni lights.
@export_range(1, 4) var max_shadows := 3
## Darkness (0 = none, 1 = black); below 0 = the current zone's shadow_strength, so every
## actor's shadow matches.
@export_range(-1.0, 1.0, 0.05) var strength := -1.0
## Silhouette resolution (texels across the caster box): lower = chunkier.
@export var resolution := 128
## Fade out by this height above the ground (jumping, falling).
@export var fade_height := 3.0
## How far the shadow may reach along the light (long dusk shadows).
@export var max_reach := 8.0

var _slots: Array[Dictionary] = []
var _lights: Array[Light3D] = []
var _light_scan := 0.0
var _size := 1.0
var _half_height := 0.9


func _ready() -> void:
	# Keep tracking while the actor is disabled (cutscenes, doors) or the game is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if caster == null:
		caster = get_parent() as Node3D
	if caster == null:
		return
	var box := AABB()
	var first := true
	for mi in caster.find_children("*", "MeshInstance3D", true, false):
		mi.layers = ACTOR_LAYER | CASTER_LAYER
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_mark_stencil(mi)
		var b: AABB = mi.get_aabb()
		b = caster.global_transform.affine_inverse() * mi.global_transform * b
		box = b if first else box.merge(b)
		first = false
	_size = maxf(box.size.x, maxf(box.size.y, box.size.z)) * 1.3
	_half_height = box.size.y * 0.5
	for i in max_shadows:
		_slots.append(_make_slot())


func _make_slot() -> Dictionary:
	var vp := SubViewport.new()
	vp.size = Vector2i(resolution, resolution)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vp.debug_draw = Viewport.DEBUG_DRAW_UNSHADED
	vp.positional_shadow_atlas_size = 0
	add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = _size
	cam.cull_mask = CASTER_LAYER
	cam.near = 0.05
	cam.far = 40.0
	vp.add_child(cam)
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter(&"silhouette", vp.get_texture())
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	box.material_override = mat
	box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	box.top_level = true
	box.visible = false
	add_child(box)
	return {viewport = vp, camera = cam, box = box, material = mat}


func _process(delta: float) -> void:
	if caster == null or _slots.is_empty():
		return
	if not caster.is_visible_in_tree():  # between zones, cutscene hides
		for slot in _slots:
			_hide(slot)
		return
	_light_scan -= delta
	if _light_scan <= 0.0:
		_light_scan = 1.0
		_lights.clear()
		for l in get_tree().root.find_children("*", "Light3D", true, false):
			if l is DirectionalLight3D or l is OmniLight3D:
				_lights.append(l)
	var center := caster.global_position + Vector3.UP * _half_height
	var ground_fade := 1.0 - clampf(_height_above_ground(center) / maxf(fade_height, 0.01), 0.0, 1.0)

	# Candidates: [direction light travels, weight].
	var picks := []
	var omnis := []
	for l in _lights:
		if not is_instance_valid(l) or not l.is_inside_tree() or not l.is_visible_in_tree() or l.light_energy <= 0.01:
			continue
		if l is DirectionalLight3D:
			var dir := -l.global_basis.z
			if dir.y < -0.05:  # above the horizon
				# Dusk sun is dim but still throws a clear (long) shadow.
				picks.append([dir, smoothstep(0.0, 0.4, l.light_energy) * smoothstep(0.05, 0.2, -dir.y)])
		else:
			var to := center - l.global_position
			var d := to.length()
			var r: float = (l as OmniLight3D).omni_range
			if d < r and d > 0.05:
				var fall := 1.0 - d / r
				omnis.append([to / d, smoothstep(0.0, 0.5, l.light_energy) * smoothstep(0.0, 0.5, fall)])
	# Torches barely register in full sun.
	var sun_weight: float = picks[0][1] if not picks.is_empty() else 0.0
	for o in omnis:
		o[1] *= 1.0 - 0.75 * sun_weight
	omnis.sort_custom(func(a, b): return a[1] > b[1])
	picks.append_array(omnis.slice(0, max_shadows - picks.size()))

	for i in _slots.size():
		var slot: Dictionary = _slots[i]
		if i >= picks.size() or picks[i][1] * ground_fade <= 0.02:
			_hide(slot)
			continue
		_aim(slot, center, picks[i][0], picks[i][1] * ground_fade)


func _hide(slot: Dictionary) -> void:
	slot.box.visible = false
	slot.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	slot.live = false


## Points one slot's silhouette camera and projector box along `dir` (the way the light travels).
func _aim(slot: Dictionary, center: Vector3, dir: Vector3, weight: float) -> void:
	dir = dir.normalized()
	# Box +Y points at the light; silhouette uv = local xz.
	var y := -dir
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y).normalized()
	# Reach: far enough along the light to hit the ground under a low sun.
	var reach := minf(_half_height * 2.0 / maxf(-dir.y, 0.15) + 1.0, max_reach)
	var box: MeshInstance3D = slot.box
	box.global_transform = Transform3D(Basis(x * _size, y * reach, z * _size),
		center + dir * (reach * 0.5 - _half_height * 0.5))
	box.visible = true
	var mat: ShaderMaterial = slot.material
	mat.set_shader_parameter(&"to_light", y)
	mat.set_shader_parameter(&"strength", _strength() * weight)
	# Silhouettes refresh at half rate, staggered between lights (one small render per
	# frame per two lights); the projection itself follows every frame.
	var vp: SubViewport = slot.viewport
	if not slot.get("live", false) or (Engine.get_process_frames() + _slots.find(slot)) % 2 == 0:
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	slot.live = true
	# Camera: looks along dir, image right = box +X, image down = box +Z.
	var cam: Camera3D = slot.camera
	cam.global_transform = Transform3D(Basis(x, -z, y), center - dir * 10.0)


func _strength() -> float:
	if strength >= 0.0:
		return strength
	var zone: Node = ZoneManager.zone if is_instance_valid(ZoneManager.zone) else null
	return zone.shadow_strength if zone is Zone else 0.7


func _height_above_ground(from: Vector3) -> float:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * (fade_height + _half_height + 1.0))
	if caster is CollisionObject3D:
		q.exclude = [(caster as CollisionObject3D).get_rid()]
	var hit := space.intersect_ray(q)
	return maxf((from - hit.position).length() - _half_height, 0.0) if hit else fade_height


## Caster materials (copies) write stencil STENCIL_REF so the projection leaves it lit.
func _mark_stencil(mi: MeshInstance3D) -> void:
	if mi.material_override:
		mi.material_override = _stencil_copy(mi.material_override)
	elif mi.mesh:
		for i in mi.mesh.get_surface_count():
			mi.set_surface_override_material(i, _stencil_copy(mi.get_active_material(i)))


func _stencil_copy(m: Material) -> Material:
	var base := (m.duplicate() if m else StandardMaterial3D.new()) as BaseMaterial3D
	if base == null:
		return m  # ShaderMaterial: its shader sets stencil_mode itself.
	base.stencil_mode = BaseMaterial3D.STENCIL_MODE_CUSTOM
	base.stencil_flags = BaseMaterial3D.STENCIL_FLAG_WRITE
	base.stencil_compare = BaseMaterial3D.STENCIL_COMPARE_ALWAYS
	base.stencil_reference = STENCIL_REF
	return base
