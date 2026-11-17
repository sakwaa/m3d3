class_name GroundMist
extends MultiMeshInstance3D
## Ground mist (OoT remake style): a knee-deep slab of mist on the level's ground
## (n64_ground_mist.gdshader): one grid patch following the camera, lifted onto the ground by
## a height map at the slab's top, each pixel marching its view ray through the slab in a few
## steps (`layer_count`) against drifting columns of mist - billowy silhouettes, thick seen
## low, thin from above, one blended pass. A second patch on the ground is drawn only while
## the camera is inside the slab.
## Actors disturb it (n64_mist_sim.gdshader, a 64 x 64 GPU simulation round the camera,
## ping-ponged between two SubViewports): moving drags it and pushes it tightly aside into a
## heaped, lit wake that spreads and settles; standing still lets it fill back in; landing
## from a jump sends a ring out.
## The Zone makes one when the weather (WeatherPreset.ground_mist) or the zone / room asks
## for mist, and sets `amount` each frame (0 hides it).
## Ground: every baked mesh surface named "ground" under the zone, rasterised once into a
## height map (MAP_CELL) - roofs, walls and props never get mist; under houses there is none.

const SHADER := preload("res://addons/n64_runtime/shaders/n64_ground_mist.gdshader")
const SHADER_OPEN := preload("res://addons/n64_runtime/shaders/n64_ground_mist_open.gdshader")
const SHADER_DITHER := preload("res://addons/n64_runtime/shaders/n64_ground_mist_dither.gdshader")
const CLOUDS := preload("res://textures/sky/clouds.res")
const MAP_CELL := 0.5
const NO_GROUND := -10000.0

## 0 none .. 1 full.
var amount := 0.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		visible = amount > 0.001
## Top of the mist above the ground (metres), layers, patch size round the camera (metres),
## grid spacing (metres), dithered (G_AC_DITHER) instead of blended.
var height := 0.7
var layer_count := 8
var patch := 60.0
var spacing := 3.0
var dither := false
## Actors disturb it (the GPU simulation); off = undisturbed (comparisons).
var simulate := true
## How wide an actor parts it (metres round its middle).
var part_radius := 0.9

## The look (n64_ground_mist.gdshaderinc uniforms): metres per cloud repeat, drift (m/s at wind
## 1), how much of the ground it covers, opacity per metre, lighter tops; `color` (alpha > 0)
## replaces the fog-pale mist colour (wind-blown dust).
var cloud_size := 12.0
var churn := 0.35
var density := 0.55
var thickness := 1.6
var top_light := 0.35
var color := Color(1, 1, 1, 0)
## Clear air round the camera while inside (metres; 0 = none).
var near_clear := 0.0
## Bunches: metres per repeat (0 = off) and the thickness outside / inside one (x thickness).
var bunch_size := 0.0
var bunch_floor := 1.0
var bunch_peak := 1.0
## The share of the big cloud read that counts as a bunch (from x, full at y): higher = rarer.
var bunch_range := Vector2(0.45, 0.75)
## For a slab the camera stands inside (dust): inside, one screen pass marches from the camera;
## no depth test (the shader stops at the scene). Set before ready.
var open := false

var _mat: ShaderMaterial
var _map: ImageTexture
var _map_origin := Vector2.ZERO
var _heights := PackedFloat32Array()
var _map_w := 0
var _map_h := 0
var _map_size := Vector2.ONE
var _scan := 0.0
var _actors: Array = []
## The disturbance simulation (GroundSim + n64_mist_sim.gdshader) round the camera.
const SIM_SHADER := preload("res://addons/n64_runtime/shaders/n64_mist_sim.gdshader")
var sim: GroundSim


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_build_map()
	_build_mesh()
	if simulate:
		_build_sim()
	amount = amount


func _build_sim() -> void:
	sim = GroundSim.new(SIM_SHADER, 64, 16.0)
	sim.radius = part_radius * 0.5
	sim.radius_other = part_radius * 0.42
	sim.params = {fill_time = 1.4}
	sim.process_priority = -10  # (steps before the mist reads its rect)
	add_child(sim, false, INTERNAL_MODE_BACK)


## The ground height map from the zone's "ground" surfaces (call again after a rebake).
func _build_map() -> void:
	var tris := PackedVector3Array()
	_collect(get_parent(), tris)
	if tris.is_empty():
		_map = null
		return
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in tris:
		lo = lo.min(Vector2(p.x, p.z))
		hi = hi.max(Vector2(p.x, p.z))
	lo -= Vector2.ONE * MAP_CELL
	hi += Vector2.ONE * MAP_CELL
	var w := clampi(ceili((hi.x - lo.x) / MAP_CELL), 1, 2048)
	var h := clampi(ceili((hi.y - lo.y) / MAP_CELL), 1, 2048)
	var hm := PackedFloat32Array()
	hm.resize(w * h)
	hm.fill(NO_GROUND)
	for t in range(0, tris.size(), 3):
		var a := tris[t]
		var b := tris[t + 1]
		var c := tris[t + 2]
		# Only floors (facing up): a wall's ground-named sliver mustn't lift the mist.
		var n := (b - a).cross(c - a)
		if absf(n.y) < 0.35 * n.length():
			continue
		var a2 := (Vector2(a.x, a.z) - lo) / MAP_CELL
		var b2 := (Vector2(b.x, b.z) - lo) / MAP_CELL
		var c2 := (Vector2(c.x, c.z) - lo) / MAP_CELL
		var x0 := maxi(floori(minf(a2.x, minf(b2.x, c2.x))), 0)
		var x1 := mini(ceili(maxf(a2.x, maxf(b2.x, c2.x))), w - 1)
		var y0 := maxi(floori(minf(a2.y, minf(b2.y, c2.y))), 0)
		var y1 := mini(ceili(maxf(a2.y, maxf(b2.y, c2.y))), h - 1)
		var den := (b2.y - c2.y) * (a2.x - c2.x) + (c2.x - b2.x) * (a2.y - c2.y)
		if absf(den) < 1e-8:
			continue
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var p := Vector2(x + 0.5, y + 0.5)
				var l1 := ((b2.y - c2.y) * (p.x - c2.x) + (c2.x - b2.x) * (p.y - c2.y)) / den
				var l2 := ((c2.y - a2.y) * (p.x - c2.x) + (a2.x - c2.x) * (p.y - c2.y)) / den
				var l3 := 1.0 - l1 - l2
				if l1 < -0.02 or l2 < -0.02 or l3 < -0.02:
					continue
				var y_at := a.y * l1 + b.y * l2 + c.y * l3
				var i := y * w + x
				hm[i] = maxf(hm[i], y_at)
	# Empty cells take their nearest ground's height (rings outwards), so the patch's vertices
	# never drop away (giant slanted triangles filling the screen); G marks real ground.
	var valid := PackedFloat32Array()
	valid.resize(w * h)
	for i in w * h:
		valid[i] = 1.0 if hm[i] > NO_GROUND * 0.5 else 0.0
	var filled := hm.duplicate()
	for pass_i in 64:
		var changed := false
		var next := filled.duplicate()
		for y in h:
			for x in w:
				var i := y * w + x
				if filled[i] > NO_GROUND * 0.5:
					continue
				var best := NO_GROUND
				for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx: int = x + o.x
					var ny: int = y + o.y
					if nx >= 0 and ny >= 0 and nx < w and ny < h:
						best = maxf(best, filled[ny * w + nx])
				if best > NO_GROUND * 0.5:
					next[i] = best
					changed = true
		filled = next
		if not changed:
			break
	var rg := PackedFloat32Array()
	rg.resize(w * h * 2)
	for i in w * h:
		rg[i * 2] = filled[i] if filled[i] > NO_GROUND * 0.5 else 0.0
		rg[i * 2 + 1] = valid[i]
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGF, rg.to_byte_array())
	_map = ImageTexture.create_from_image(img)
	_heights = filled
	_map_w = w
	_map_h = h
	_map_origin = lo
	_map_size = Vector2(w, h) * MAP_CELL


## World-space triangles of every surface named "ground" in meshes under `node` (internal
## children too: LevelRoot keeps its baked meshes there).
func _collect(node: Node, out: PackedVector3Array) -> void:
	if node == self:
		return
	var mi := node as MeshInstance3D
	if mi and mi.mesh and mi.is_visible_in_tree():
		var xf := mi.global_transform
		for s in mi.mesh.get_surface_count():
			if mi.mesh is ArrayMesh and (mi.mesh as ArrayMesh).surface_get_name(s) == "ground":
				var arr := mi.mesh.surface_get_arrays(s)
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var idx = arr[Mesh.ARRAY_INDEX]
				if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty():
					for i in idx:
						out.append(xf * v[i])
				else:
					for p in v:
						out.append(xf * p)
	for c in node.get_children(true):
		_collect(c, out)


## One grid patch (patch x patch metres, `spacing` apart): the slab's lid and its floor.
func _build_mesh() -> void:
	var n := maxi(int(patch / spacing), 2)
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for y in n + 1:
		for x in n + 1:
			verts.append(Vector3(x * spacing - patch * 0.5, 0.0, y * spacing - patch * 0.5))
	for y in n:
		for x in n:
			var i := y * (n + 1) + x
			idx.append_array([i, i + 1, i + n + 1, i + 1, i + n + 2, i + n + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var grid := ArrayMesh.new()
	grid.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = grid
	mm.instance_count = 2  # the slab's lid, and its floor (camera inside only)
	for k in 2:
		mm.set_instance_transform(k, Transform3D.IDENTITY)
		mm.set_instance_custom_data(k, Color(1.0 - k, k, 0, 0))
	multimesh = mm
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER_OPEN if open else (SHADER_DITHER if dither else SHADER)
	if open:
		# (after the doorways' darkness - DarknessVolume, MAX - 1: dust in the air in front of a
		# dark doorway veils it, rather than the black punching through)
		_mat.render_priority = Material.RENDER_PRIORITY_MAX
	_mat.set_shader_parameter(&"cloud_tex", CLOUDS)
	material_override = _mat
	# Placed by the shader round the camera: never culled.
	custom_aabb = AABB(Vector3(-1e4, -1e3, -1e4), Vector3(2e4, 2e3, 2e4))


## Rebuilds the patch and material (after layer_count / patch / spacing / dither changed).
func rebuild() -> void:
	_build_mesh()


func _process(delta: float) -> void:
	if not visible or _mat == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	# The patch follows the camera in whole grid steps (no swimming).
	var c := cam.global_position
	global_transform = Transform3D(Basis.IDENTITY, Vector3(snappedf(c.x, spacing), 0.0, snappedf(c.z, spacing)))
	if sim:
		sim.process_mode = Node.PROCESS_MODE_INHERIT if simulate else Node.PROCESS_MODE_DISABLED
		_mat.set_shader_parameter(&"part_map", sim.texture if simulate else null)
		_mat.set_shader_parameter(&"part_rect", sim.rect())
	_mat.set_shader_parameter(&"cloud_size", cloud_size)
	_mat.set_shader_parameter(&"churn", churn)
	_mat.set_shader_parameter(&"density", density)
	_mat.set_shader_parameter(&"thickness", thickness)
	_mat.set_shader_parameter(&"top_light", top_light)
	_mat.set_shader_parameter(&"solid_tint", color.a > 0.0)
	_mat.set_shader_parameter(&"near_clear", near_clear)
	_mat.set_shader_parameter(&"screen_floor", open)
	_mat.set_shader_parameter(&"bunch_size", bunch_size)
	_mat.set_shader_parameter(&"bunch_floor", bunch_floor)
	_mat.set_shader_parameter(&"bunch_peak", bunch_peak)
	_mat.set_shader_parameter(&"bunch_range", bunch_range)
	if color.a > 0.0:
		_mat.set_shader_parameter(&"mist_tint", color)
	# The floor patch only while the camera is inside the slab (else it would fill for nothing).
	# (a metre's margin: the shader decides exactly, from its own smoother height map)
	# (open: the screen pass is always drawn - the shader decides inside / outside itself, and
	# a cheap early-out otherwise)
	multimesh.visible_instance_count = 2 if open or c.y < ground_at(Vector2(c.x, c.z)) + height + 1.0 else 1
	_mat.set_shader_parameter(&"height_map", _map)
	_mat.set_shader_parameter(&"map_rect", Vector4(_map_origin.x, _map_origin.y, _map_size.x, _map_size.y))
	_mat.set_shader_parameter(&"has_map", _map != null)
	_mat.set_shader_parameter(&"mist_height", height)
	_mat.set_shader_parameter(&"amount", amount)
	_mat.set_shader_parameter(&"patch", patch)
	_mat.set_shader_parameter(&"layer_count", float(layer_count))


## Sends a landing ring out from `actor` (0..1). Tests and scripted moments call it too.
func splash(actor: Node, strength := 1.0) -> void:
	if sim and simulate:
		sim.splash(actor, strength)


## The ground height under `xz` (the nearest ground's where there is none).
func ground_at(xz: Vector2) -> float:
	if _heights.is_empty():
		return 0.0
	var c := ((xz - _map_origin) / MAP_CELL).floor()
	var x := clampi(int(c.x), 0, _map_w - 1)
	var y := clampi(int(c.y), 0, _map_h - 1)
	var v := _heights[y * _map_w + x]
	return v if v > NO_GROUND * 0.5 else 0.0
