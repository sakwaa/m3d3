class_name GrassWake
extends Node3D
## The grass parted where an actor wades through a grass carpet (a GrassField), like a
## zipper: the actor sinks into the carpet (it doesn't collide), and as it goes stamps are laid
## along its path (each staying where it was put, turned along the way it was heading): a row
## of blades rooted along each side of the path. At the legs the two rows swing out; behind,
## they swing back until the sides cross and the carpet is whole again (one stamp after
## another: it zips shut). All the
## stamps draw as one MultiMesh (in world space); the blades swing in the shader. Round the
## legs the carpet dips: the carpet leaves a round hole there (n64_divot, ragged like blade
## tips at its edge) and a shallow bowl (n64_grass_bowl) under it, the carpet's texture
## darker going in, shows the legs down to its floor.

const SHADER := preload("res://addons/n64_runtime/shaders/n64_grass_wake.gdshader")
const BOWL_SHADER := preload("res://addons/n64_runtime/shaders/n64_grass_bowl.gdshader")
## A stamp: blades per side, where their roots are (out from the path's middle, and down in
## the carpet), how long they are, and how wide (along the path).
const BLADES := 3
const ROOT_OUT := 0.13
const ROOT_DOWN := 0.2
const LENGTH := Vector2(0.36, 0.5)
const WIDTH := 0.22
## A new stamp every this many metres waded; stamps closer than OPEN_RADIUS to the legs stay
## open. Seconds to open, and to close once the legs have gone.
const SPACING := 0.35
const OPEN_RADIUS := 0.35
const OPEN_TIME := 0.1
const CLOSE_TIME := 0.3
const MAX_STAMPS := 32
## The divot round the legs: its rim's radius, how deep it dips (metres), how fast it comes
## and goes (seconds), and how fast its rim follows the carpet's top (per second: the top
## steps from cell to cell).
const BOWL_RADIUS := 0.42
const BOWL_DEPTH := 0.12
const BOWL_FADE := 0.15
const BOWL_FOLLOW := 12.0
const BOWL_SEGMENTS := 32
const BOWL_RINGS := 6
const RIM_SAMPLES := 8
## Least carpet round the feet (rim radius, metres) for a divot, and the step its edge is
## looked for in.
const MIN_ROOM := 0.15
const ROOM_STEP := 0.05
## Blades leave the legs clear within this radius (metres): no grass across the shins.
const LEGS_CLEAR := 0.24
const NO_DIVOT := Vector4(0, -1000, 0, 0)

var actor: Node3D
var _mm: MultiMesh
var _mat: ShaderMaterial
var _rings: Array[Dictionary] = []  # the stamps: {pos, open, seed, head}
var _field: GrassField
var _feet := 0.0  # the dip at the feet: 0 gone .. 1 there
var _bowl: MeshInstance3D
var _bowl_mat: ShaderMaterial
var _flange: MeshInstance3D
var _rim := NAN  # the dip's rim height (following the carpet's top)
var _room := NAN  # how wide it may be there (following the carpet's edge)


func _init(p_actor: Node3D = null) -> void:
	actor = p_actor
	name = "GrassWake"
	top_level = true


func _ready() -> void:
	global_transform = Transform3D.IDENTITY
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = _stamp()
	_mm.instance_count = MAX_STAMPS
	_mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	mmi.material_override = _mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = 16.0
	add_child(mmi)
	_bowl_mat = ShaderMaterial.new()
	_bowl_mat.shader = BOWL_SHADER
	_bowl = MeshInstance3D.new()
	_bowl.mesh = _bowl_mesh()
	_bowl.material_override = _bowl_mat
	_bowl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bowl.visible = false
	add_child(_bowl)
	_flange = MeshInstance3D.new()
	_flange.name = "Flange"
	_flange.mesh = _flange_mesh()
	_flange.material_override = _bowl_mat
	_flange.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flange.visible = false
	add_child(_flange)


func _exit_tree() -> void:
	RenderingServer.global_shader_parameter_set(&"n64_divot", NO_DIVOT)


func _process(delta: float) -> void:
	if actor == null:
		return
	var feet := actor.global_position
	var probe := feet + Vector3.UP * 0.05
	var field := GrassField.at(probe)
	var top := field.top_here(probe) if field else -INF
	var wading := top > feet.y + 0.08 and top < feet.y + 1.2
	if field and field != _field:
		_field = field
		_mat.set_shader_parameter(&"tex", field.texture)
		_mat.set_shader_parameter(&"color", field.color)
		_bowl_mat.set_shader_parameter(&"tex", field.texture)
		_bowl_mat.set_shader_parameter(&"color", field.color)
		_bowl_mat.set_shader_parameter(&"tile", field.tile)
	# A new stamp once the legs have moved on from the last one.
	if wading:
		var last: Dictionary = _rings[-1] if not _rings.is_empty() else {}
		var flat := Vector2(feet.x, feet.z)
		if last.is_empty() or Vector2(last.pos.x, last.pos.z).distance_to(flat) > SPACING:
			var v: Vector3 = actor.get(&"velocity") if actor.get(&"velocity") != null else Vector3.ZERO
			var head := Vector2(v.x, v.z).normalized() if Vector2(v.x, v.z).length() > 0.1 else Vector2.ZERO
			if head == Vector2.ZERO:
				var f: Vector3 = actor.get(&"facing") if actor.get(&"facing") != null else Vector3.FORWARD
				head = Vector2(f.x, f.z).normalized() if Vector2(f.x, f.z).length() > 0.01 else Vector2(0, -1)
			_rings.append({pos = Vector3(feet.x, top, feet.z), open = 0.0, seed = randf(), head = head,
				mask = _carpet_mask(feet, head, top)})
			if _rings.size() > MAX_STAMPS:
				_rings.pop_front()
	# Open near the legs, close behind them; drop the closed ones.
	var i := 0
	while i < _rings.size():
		var r := _rings[i]
		var near := wading and Vector2(r.pos.x - feet.x, r.pos.z - feet.z).length() < OPEN_RADIUS
		r.open = move_toward(r.open, 1.0 if near else 0.0, delta / (OPEN_TIME if near else CLOSE_TIME))
		if r.open <= 0.0 and not near:
			_rings.remove_at(i)
			continue
		i += 1
	# The dip round the legs: grows in / shrinks away, its rim easing after the carpet's top,
	# never wider than the carpet round the feet (near its edge it shrinks, and goes where
	# there's too little carpet: no divot hanging out over the bare ground).
	var room := _carpet_room(field, feet, top) if wading else 0.0
	_room = room if is_nan(_room) else lerpf(_room, room, minf(delta * BOWL_FOLLOW, 1.0))
	var dipping := wading and room >= MIN_ROOM
	_feet = move_toward(_feet, 1.0 if dipping else 0.0, delta / BOWL_FADE)
	if dipping:
		var want := _rim_height(field, feet, top, minf(BOWL_RADIUS, _room))
		_rim = want if is_nan(_rim) else lerpf(_rim, want, minf(delta * BOWL_FOLLOW, 1.0))
	_bowl.visible = _feet > 0.0 and not is_nan(_rim)
	_flange.visible = _bowl.visible
	if _bowl.visible:
		var e := smoothstep(0.0, 1.0, _feet)
		var r := minf(BOWL_RADIUS * lerpf(0.5, 1.0, e), _room)
		var deep := maxf(minf(BOWL_DEPTH, _rim - feet.y), 0.01) * e
		_bowl.global_transform = Transform3D(Basis.from_scale(Vector3(r, deep, r)), Vector3(feet.x, _rim, feet.z))
		_flange.global_transform = Transform3D(Basis.from_scale(Vector3(r, 1.0, r)), Vector3(feet.x, _rim, feet.z))
	else:
		_rim = NAN
		_room = NAN
	# The hole in the carpet over the bowl (carpet shader; one divot: the player's).
	RenderingServer.global_shader_parameter_set(&"n64_divot",
		Vector4(feet.x, _rim, feet.z, _bowl.scale.x) if _bowl.visible else NO_DIVOT)
	_mat.set_shader_parameter(&"legs", Vector3(feet.x, feet.z, LEGS_CLEAR if wading else 0.0))
	_mm.visible_instance_count = _rings.size()
	for k in _rings.size():
		var r := _rings[k]
		# Local z along the way it was heading (a little jitter: no straight rows).
		var yaw: float = atan2(r.head.x, r.head.y) + (r.seed - 0.5) * 0.3
		_mm.set_instance_transform(k, Transform3D(Basis(Vector3.UP, yaw), r.pos))
		_mm.set_instance_custom_data(k, Color(r.open, float(int(r.mask) & 15), r.head.x, r.head.y))


## Which parts of a stamp at `feet` (heading `head`) have carpet under them, as bits:
## 1 left-back, 2 left-front, 4 right-back, 8 right-front. Blades over no carpet (the edge of a patch, the path just stepped off) aren't drawn.
func _carpet_mask(feet: Vector3, head: Vector2, top: float) -> int:
	var fwd := Vector3(head.x, 0.0, head.y)
	var right := fwd.cross(Vector3.UP)
	var reach := SPACING * 0.5
	var mask := 0
	var bit := 1
	for side in [-1.0, 1.0]:
		for along in [-1.0, 1.0]:
			# (Local +z of the stamp is the heading's way; the blade roots are ROOT_OUT out.)
			var p: Vector3 = feet + right * side * (ROOT_OUT + 0.1) + fwd * along * reach + Vector3.UP * 0.05
			var t := GrassField.top_at(p)
			if t > -INF and absf(t - top) < 0.4:
				mask |= bit
			bit <<= 1
	return mask


## How wide the divot may be at `feet` (its rim's radius): how far the carpet reaches out
## round the feet (RIM_SAMPLES ways, the nearest edge), less its flange.
func _carpet_room(field: GrassField, feet: Vector3, top: float) -> float:
	var reach := BOWL_RADIUS * FLANGE.x
	var room := reach
	for i in RIM_SAMPLES:
		var a := TAU * (i + 0.5) / RIM_SAMPLES
		var way := Vector3(cos(a), 0.0, sin(a))
		var d := ROOM_STEP
		while d <= room:
			var h := field.surface_at(feet + way * d)
			if h == -INF or absf(h - top) > 0.3:
				room = d - ROOM_STEP
				break
			d += ROOM_STEP
	return room / FLANGE.x


## Where the divot's rim should sit: the carpet's real top (its lumps) round the rim,
## averaged; the cell's height where it isn't known.
func _rim_height(field: GrassField, feet: Vector3, fallback: float, radius: float) -> float:
	var sum := 0.0
	var n := 0
	for i in RIM_SAMPLES:
		var a := TAU * i / RIM_SAMPLES
		var h := field.surface_at(feet + Vector3(cos(a), 0.0, sin(a)) * radius)
		if h > -INF and absf(h - fallback) < 0.3:
			sum += h
			n += 1
	return sum / n if n > 0 else fallback


## The divot: a round dish, rim radius 1 at y 0, deepest (y -1) in the middle, its profile a
## cosine (level with the carpet at the rim, flat in the middle: no creases), wound to show
## its inside from above.
func _bowl_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var at := func(k: int, i: int) -> Vector3:
		# Rings from the rim (k 0) in to the middle (k BOWL_RINGS).
		var r := 1.0 - float(k) / BOWL_RINGS
		var t := TAU * i / BOWL_SEGMENTS
		return Vector3(cos(t) * r, -0.5 * (1.0 + cos(PI * r)), sin(t) * r)
	for k in BOWL_RINGS:
		for i in BOWL_SEGMENTS:
			var a: Vector3 = at.call(k, i)
			var b: Vector3 = at.call(k, i + 1)
			var c: Vector3 = at.call(k + 1, i + 1)
			var d: Vector3 = at.call(k + 1, i)
			if k == BOWL_RINGS - 1:
				for p in [a, b, c]:
					st.add_vertex(p)
			else:
				for p in [a, b, c, a, c, d]:
					st.add_vertex(p)
	return st.commit()


## Past the divot's rim a flange rises outward under the carpet (the carpet's hole is only
## the rim wide): where the carpet's lumps stand above the rim, its cut edge shows the flange
## behind it, never the hollow under the carpet. Radius 1 at y 0 out to FLANGE.x at y
## FLANGE.y metres (scaled across only: its height is the carpet's lumps').
const FLANGE := Vector2(1.12, 0.04)


func _flange_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in BOWL_SEGMENTS:
		var a := TAU * i / BOWL_SEGMENTS
		var b := TAU * (i + 1) / BOWL_SEGMENTS
		var ra := Vector3(cos(a), 0, sin(a))
		var rb := Vector3(cos(b), 0, sin(b))
		var oa := Vector3(ra.x * FLANGE.x, FLANGE.y, ra.z * FLANGE.x)
		var ob := Vector3(rb.x * FLANGE.x, FLANGE.y, rb.z * FLANGE.x)
		for p in [oa, ob, rb, oa, rb, ra]:
			st.add_vertex(p)
	return st.commit()


## One stamp (local z along the path): per side, BLADES flaps rooted along the path's
## edge, standing up (the shader swings them about their roots). CUSTOM0 = (pivot x, pivot y,
## side, front / back); colour r = shade.
func _stamp() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	var half := SPACING * 0.5 + 0.08  # (overlapping the next stamp: no gaps along the path)
	var quad := func(pts: Array, uvs: Array, shades: Array, custom: Color) -> void:
		for k in [0, 1, 2, 0, 2, 3]:
			st.set_custom(0, custom)
			st.set_color(Color(shades[k], 1.0, 1.0))
			st.set_uv(uvs[k])
			st.add_vertex(pts[k])
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for side in [-1.0, 1.0]:
		for i in BLADES:
			var z := lerpf(-half, half, (i + 0.5) / BLADES) + rng.randf_range(-0.04, 0.04)
			var w := WIDTH * rng.randf_range(0.8, 1.2) * 0.5
			var x: float = side * (ROOT_OUT + rng.randf_range(-0.03, 0.03))
			var length := rng.randf_range(LENGTH.x, LENGTH.y)
			var pivot := Color(x, -ROOT_DOWN, side, 1.0 if z > 0.0 else -1.0)  # (w: front / back half)
			quad.call([Vector3(x, -ROOT_DOWN + length, z - w), Vector3(x, -ROOT_DOWN + length, z + w), Vector3(x, -ROOT_DOWN, z + w * 0.8), Vector3(x, -ROOT_DOWN, z - w * 0.8)],
				[Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)], [1.3, 1.3, 0.5, 0.5], pivot)
	return st.commit()
