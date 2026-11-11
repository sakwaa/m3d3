@tool
class_name BirdFlock
extends Node3D
## Small town birds around this spot. A flock of a few flies in from out of bounds, settles
## on a rooftop and waits for the street below to clear, then drops down to peck at the dirt,
## and scatters back into the air when anyone comes close: the player always, NPCs unless
## they're feeding them (Npc.feeds_birds(), which draws them in instead). In the air they
## steer like boids (keep apart, match heading, stay together) either milling around each
## other or trailing an elected leader. Now and then a scattered flock leaves out of bounds
## and is gone; another arrives a while later. They roost out of sight at night.
## A flock's birds draw as one MultiMesh (one draw call), wings flapped in n64_bird.gdshader.

const SHADER := preload("res://addons/n64_runtime/shaders/n64_bird.gdshader")

## Area the flock lives in (centred here; this node's height is the street level).
@export_range(5.0, 60.0, 0.5, "suffix:m") var radius := 18.0:
	set(v):
		radius = v
		_update_preview()
@export_range(1, 12) var min_birds := 3
@export_range(1, 12) var max_birds := 7
## Bird size (1 = a sparrow about 40 cm across the wings; a little larger reads better).
@export_range(0.5, 3.0, 0.05) var size := 1.3
@export var body_color := Color(0.5, 0.38, 0.27)
@export var belly_color := Color(0.82, 0.76, 0.66)
@export var wing_color := Color(0.3, 0.24, 0.19)
@export var beak_color := Color(0.8, 0.62, 0.3)
## Seconds after a flock leaves before the next arrives (varies by half either way).
@export_range(0.0, 300.0, 1.0, "suffix:s") var respawn_time := 30.0
## Each time it scatters, the chance the flock leaves instead of settling again.
@export_range(0.0, 1.0, 0.05) var leave_chance := 0.3
## Hours of the day the birds are about (they roost out of sight otherwise).
@export_range(0.0, 24.0, 0.25) var active_from := 5.5
@export_range(0.0, 24.0, 0.25) var active_to := 19.5
@export_group("Wariness")
## The player startles them within this distance (on the ground; less when perched up high).
@export_range(0.5, 15.0, 0.25, "suffix:m") var player_distance := 5.0
## NPCs startle them within this distance (not ones feeding them).
@export_range(0.5, 15.0, 0.25, "suffix:m") var npc_distance := 2.5
## The street has to be this clear (metres past the startle distance) before they come down.
@export_range(0.0, 10.0, 0.25, "suffix:m") var clear_margin := 3.0
@export_group("")

enum State { EMPTY, AIR, LANDING, PERCHED, FORAGING, LEAVING }
enum AirMode { MILL, FOLLOW }

const AIR_SPEED := 5.5
const MIN_AIR_SPEED := 2.5
const MAX_AIR_SPEED := 8.0
const STEER := 9.0
const SEPARATION := 0.8
const NEIGHBOUR := 3.0
## Out of bounds: arrive from / leave to this far past the radius, this high.
const OFFSTAGE := 30.0
const OFFSTAGE_HEIGHT := 14.0
const CRUISE_HEIGHT := 6.0
const ROOF_MIN := 2.2

class Bird:
	var pos := Vector3.ZERO
	var vel := Vector3.ZERO
	var grounded := false
	var slot := Vector3.ZERO
	var delay := 0.0
	var yaw := 0.0
	var phase := 0.0
	var flap := 1.0
	var fold := 0.0
	var shade := 0.5
	var hop_from := Vector3.ZERO
	var hop_to := Vector3.ZERO
	var hop_t := 1.0
	var next_hop := 0.0
	var peck := 0.0
	var next_peck := 0.0

var _birds: Array[Bird] = []
var _state := State.EMPTY
var _mode := AirMode.MILL
var _timer := 0.0
var _mode_timer := 0.0
var _goal := Vector3.ZERO
var _perch := Vector3.ZERO
var _forage := Vector3.ZERO
var _feeder: Node3D
var _landing_on_roof := true
var _offstage_dir := Vector3.FORWARD
var _threats: Array = []  # [position, startle distance] of everyone around
var _threat_scan := 0.0
var _rng := RandomNumberGenerator.new()
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _preview: MeshInstance3D
var _first := true


func _ready() -> void:
	_rng.randomize()
	if Engine.is_editor_hint():
		_update_preview()
		return
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = make_mesh()
	_mm.instance_count = maxi(max_birds, min_birds)
	_mm.visible_instance_count = 0
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter(&"body_color", body_color)
	mat.set_shader_parameter(&"wing_color", wing_color)
	mat.set_shader_parameter(&"belly_color", belly_color)
	mat.set_shader_parameter(&"beak_color", beak_color)
	_mmi.material_override = mat
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.top_level = true
	add_child(_mmi, false, INTERNAL_MODE_BACK)
	_mmi.global_transform = Transform3D.IDENTITY
	# Wait a moment for the level's collision, then start with birds already about.
	_timer = 0.3


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_threat_scan -= delta
	if _threat_scan <= 0.0:
		_threat_scan = 0.2
		_scan_threats()
	match _state:
		State.EMPTY:
			_timer -= delta
			if _timer <= 0.0 and _is_daytime():
				# The first flock of the visit is often already sitting about.
				_arrive(_first and _rng.randf() < 0.7)
				_first = false
		State.AIR:
			_timer -= delta
			_mode_timer -= delta
			if _mode_timer <= 0.0:
				_mode = AirMode.FOLLOW if _mode == AirMode.MILL else AirMode.MILL
				_mode_timer = _rng.randf_range(3.0, 7.0)
				_goal = _air_point()
			if _timer <= 0.0:
				_settle()
		State.LANDING:
			if _birds.all(func(b: Bird) -> bool: return b.grounded):
				_state = State.PERCHED if _landing_on_roof else State.FORAGING
				_timer = _rng.randf_range(4.0, 10.0) if _landing_on_roof else _rng.randf_range(8.0, 20.0)
			elif _threatened():
				_scatter()
		State.PERCHED:
			_timer -= delta
			if _threatened():
				_scatter()
			elif not _is_daytime():
				_leave()
			elif _timer <= 0.0:
				_timer = _rng.randf_range(2.0, 5.0)
				if _find_forage():
					_land(false)
		State.FORAGING:
			_timer -= delta
			if _threatened():
				_scatter()
			elif _timer <= 0.0 or not _is_daytime():
				# Done here: back up to a roof (or away for the night).
				_take_off(Vector3.ZERO)
				if not _is_daytime():
					_leave()
		State.LEAVING:
			var far := Vector2(_centroid().x - global_position.x, _centroid().z - global_position.z).length()
			if far > radius + OFFSTAGE - 2.0:
				_birds.clear()
				_state = State.EMPTY
				_timer = respawn_time * _rng.randf_range(0.5, 1.5)
	_step_birds(delta)
	_draw_birds()


# --- Flock decisions -------------------------------------------------------------------------

func _is_daytime() -> bool:
	var gs := get_node_or_null(^"/root/GameState")
	if gs == null:
		return true
	var h: float = gs.time_of_day
	return h >= active_from and h < active_to if active_from <= active_to else (h >= active_from or h < active_to)


## A new flock: already perched on a roof (`settled`, zone start) or flying in from out of bounds.
func _arrive(settled: bool) -> void:
	_birds.clear()
	var n := _rng.randi_range(mini(min_birds, max_birds), maxi(min_birds, max_birds))
	var a := _rng.randf() * TAU
	_offstage_dir = Vector3(cos(a), 0.0, sin(a))
	var from := global_position + _offstage_dir * (radius + OFFSTAGE) + Vector3.UP * OFFSTAGE_HEIGHT
	for i in n:
		var b := Bird.new()
		b.pos = from + Vector3(_rng.randf_range(-1.5, 1.5), _rng.randf_range(-0.8, 0.8), _rng.randf_range(-1.5, 1.5))
		b.vel = -_offstage_dir * AIR_SPEED
		b.phase = _rng.randf() * TAU
		b.shade = _rng.randf()
		b.yaw = atan2(-b.vel.x, -b.vel.z)
		_birds.append(b)
	if settled and _find_perch():
		_land(true)
		for b in _birds:
			b.pos = b.slot
			b.grounded = true
			b.vel = Vector3.ZERO
			b.fold = 1.0
			b.yaw = _rng.randf() * TAU
		_state = State.PERCHED
		_timer = _rng.randf_range(2.0, 8.0)
		return
	_state = State.AIR
	_mode = AirMode.FOLLOW
	_mode_timer = _rng.randf_range(4.0, 7.0)
	_goal = _air_point()
	_timer = _rng.randf_range(3.0, 6.0)


## Circling done: down onto a roof (or the street, if a feeder's calling), or away.
func _settle() -> void:
	if not _is_daytime():
		_leave()
	elif _feeder_nearby() and _find_forage():
		_land(false)
	elif _find_perch():
		_land(true)
	else:
		_timer = 3.0


## Everyone up and away from whatever startled them (`from`; ZERO = just taking off).
func _take_off(from: Vector3) -> void:
	for b in _birds:
		var away := b.pos - from if from != Vector3.ZERO else Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-1, 1))
		away.y = 0.0
		away = away.normalized() if away.length() > 0.01 else Vector3.FORWARD
		b.grounded = false
		b.vel = away * _rng.randf_range(3.0, 5.0) + Vector3.UP * _rng.randf_range(3.5, 5.5)
		b.fold = 0.0
		b.flap = 1.0
		b.hop_t = 1.0
	_state = State.AIR
	_mode = AirMode.MILL
	_mode_timer = _rng.randf_range(2.0, 4.0)
	_goal = _air_point()
	_timer = _rng.randf_range(4.0, 9.0)


func _scatter() -> void:
	var nearest := Vector3.ZERO
	var best := INF
	var c := _centroid()
	for t in _threats:
		var d := (t[0] as Vector3).distance_to(c)
		if d < best:
			best = d
			nearest = t[0]
	_take_off(nearest)
	if _rng.randf() < leave_chance:
		_leave()


func _leave() -> void:
	if _state != State.AIR:
		_take_off(Vector3.ZERO)
	_state = State.LEAVING
	var a := _rng.randf() * TAU
	_offstage_dir = Vector3(cos(a), 0.0, sin(a))
	_goal = global_position + _offstage_dir * (radius + OFFSTAGE + 10.0) + Vector3.UP * OFFSTAGE_HEIGHT


## Down to the perch (`roof`) or the forage spot, each bird to its own place nearby.
func _land(roof: bool) -> void:
	_landing_on_roof = roof
	var centre := _perch if roof else _forage
	for i in _birds.size():
		var b := _birds[i]
		b.slot = _slot_near(centre, roof, i)
		b.delay = i * _rng.randf_range(0.05, 0.35)
		if b.grounded:
			# From one spot to another (roof down to the street): a hop up first.
			b.grounded = false
			b.hop_t = 1.0
			b.vel = Vector3.UP * 3.0 + (b.slot - b.pos).normalized() * 2.0
	_state = State.LANDING


## A rooftop spot in the area: the top surface well above the street.
func _find_perch() -> bool:
	for i in 24:
		var hit := _ray_down(_random_xz(radius))
		if hit.is_empty() or (hit.normal as Vector3).y < 0.35:
			continue
		var p: Vector3 = hit.position
		if p.y > global_position.y + ROOF_MIN and p.y < global_position.y + 14.0:
			_perch = p
			return true
	return false


## Somewhere to peck: bare dirt (or grass, sand) out in the open with nobody near, or by
## whoever's feeding them.
func _find_forage() -> bool:
	_feeder = _feeder_nearby()
	if _feeder:
		var a := _rng.randf() * TAU
		var hit := _ray_down(Vector2(_feeder.global_position.x, _feeder.global_position.z) + Vector2(cos(a), sin(a)) * 1.6)
		if not hit.is_empty():
			_forage = hit.position
			return true
	for i in 16:
		var hit := _ray_down(_random_xz(radius * 0.8))
		if hit.is_empty() or (hit.normal as Vector3).y < 0.8 or (hit.position as Vector3).y > global_position.y + 0.8:
			continue
		var s := Surface.sound(Surface.of_ray(hit))
		if not s in [Surface.Sound.DIRT, Surface.Sound.GRASS, Surface.Sound.SAND]:
			continue
		if _clear_around(hit.position, clear_margin):
			_forage = hit.position
			return true
	return false


func _slot_near(centre: Vector3, roof: bool, i: int) -> Vector3:
	if i == 0:
		return centre
	for k in 6:
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(0.25, 0.9 if roof else 1.6)
		var hit := _ray_down(Vector2(centre.x + cos(a) * r, centre.z + sin(a) * r))
		if not hit.is_empty() and absf((hit.position as Vector3).y - centre.y) < (0.45 if roof else 0.3):
			return hit.position
	return centre + Vector3(_rng.randf_range(-0.2, 0.2), 0.0, _rng.randf_range(-0.2, 0.2))


func _air_point() -> Vector3:
	var xz := _random_xz(radius * 0.7)
	return Vector3(xz.x, global_position.y + CRUISE_HEIGHT + _rng.randf_range(-1.5, 2.5), xz.y)


func _random_xz(r: float) -> Vector2:
	var a := _rng.randf() * TAU
	var d := sqrt(_rng.randf()) * r
	return Vector2(global_position.x + cos(a) * d, global_position.z + sin(a) * d)


func _ray_down(xz: Vector2) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(xz.x, global_position.y + 30.0, xz.y),
		Vector3(xz.x, global_position.y - 10.0, xz.y), Surface.SOLID_LAYER)
	var hit := space.intersect_ray(q)
	return hit if not hit.is_empty() and hit.collider is StaticBody3D else {}


# --- Who's around -----------------------------------------------------------------------------

func _scan_threats() -> void:
	_threats.clear()
	var reach := radius + 15.0
	for a in get_tree().get_nodes_in_group(&"actors"):
		var n := a as Node3D
		if n == null or not n.is_visible_in_tree():
			continue
		if n.global_position.distance_to(global_position) > reach:
			continue
		if n.is_in_group(&"player"):
			_threats.append([n.global_position, player_distance])
		elif n.has_method(&"feeds_birds") and n.feeds_birds():
			continue
		elif n is Npc:
			_threats.append([n.global_position, npc_distance])
		else:
			_threats.append([n.global_position, player_distance])


func _feeder_nearby() -> Node3D:
	for a in get_tree().get_nodes_in_group(&"actors"):
		if a.has_method(&"feeds_birds") and a.feeds_birds() \
				and (a as Node3D).global_position.distance_to(global_position) < radius:
			return a
	return null


## Anyone within their startle distance of a bird (on a roof the birds sit tight unless
## someone's right up there with them).
func _threatened() -> bool:
	for b in _birds:
		for t in _threats:
			var p: Vector3 = t[0]
			var limit: float = t[1]
			var d := p.distance_to(b.pos)
			if b.grounded and _state == State.PERCHED:
				limit = minf(limit, 2.5)
			if d < limit:
				return true
	return false


func _clear_around(p: Vector3, margin: float) -> bool:
	for t in _threats:
		if (t[0] as Vector3).distance_to(p) < (t[1] as float) + margin:
			return false
	return true


func _centroid() -> Vector3:
	var c := Vector3.ZERO
	for b in _birds:
		c += b.pos
	return c / maxf(_birds.size(), 1.0)


# --- Each bird --------------------------------------------------------------------------------

func _step_birds(delta: float) -> void:
	var c := _centroid()
	var leader: Bird = _birds[0] if not _birds.is_empty() else null
	for i in _birds.size():
		var b := _birds[i]
		if b.grounded:
			_step_ground(b, delta)
			continue
		var desired := Vector3.ZERO
		var landing := _state == State.LANDING
		if landing:
			b.delay -= delta
			var to := b.slot - b.pos
			var d := to.length()
			if b.delay > 0.0:
				desired = (_goal_for(b, c, leader, i) - b.pos).normalized() * AIR_SPEED
			elif d < 0.3:
				b.pos = b.slot
				b.vel = Vector3.ZERO
				b.grounded = true
				b.next_hop = _rng.randf_range(0.3, 1.5)
				b.next_peck = _rng.randf_range(0.5, 2.0)
				continue
			else:
				# Glide in, slowing as it gets close; from a little above at the end.
				var aim := b.slot + Vector3.UP * clampf(d * 0.25, 0.0, 1.0)
				desired = (aim - b.pos).normalized() * clampf(d * 2.2, 0.8, AIR_SPEED)
		else:
			desired = (_goal_for(b, c, leader, i) - b.pos).normalized() * AIR_SPEED
		# Boids: keep apart, match the others' heading, keep together.
		var sep := Vector3.ZERO
		var align := Vector3.ZERO
		var near := 0
		for o in _birds:
			if o == b or o.grounded:
				continue
			var off := b.pos - o.pos
			var dist := off.length()
			if dist < SEPARATION and dist > 0.001:
				sep += off / dist * (SEPARATION - dist) / SEPARATION
			if dist < NEIGHBOUR:
				align += o.vel
				near += 1
		# Coming in to its own spot, spacing is already settled: no pushing apart then.
		var settling := landing and b.delay <= 0.0 and (b.slot - b.pos).length() < 2.0
		var steer := desired - b.vel + (sep * 6.0 if not settling else Vector3.ZERO)
		if near > 0 and not landing:
			steer += (align / near - b.vel) * 0.4
		# Shy of the player in the air too.
		for t in _threats:
			var off: Vector3 = b.pos - (t[0] as Vector3)
			var dist := off.length()
			if dist < (t[1] as float) * 0.7 and dist > 0.01:
				steer += off / dist * 6.0
		b.vel += steer.limit_length(STEER) * delta * (2.5 if landing else 1.0)
		var top := MAX_AIR_SPEED if not landing else AIR_SPEED
		var speed := b.vel.length()
		if speed > top:
			b.vel *= top / speed
		elif speed < MIN_AIR_SPEED and not landing:
			b.vel = b.vel / maxf(speed, 0.01) * MIN_AIR_SPEED
		b.pos += b.vel * delta
		# Beat climbing and taking off, glide when level or dropping.
		var beat := clampf(0.35 + b.vel.y * 0.25, 0.0, 1.0)
		if landing and b.delay <= 0.0:
			beat = 1.0 if (b.slot - b.pos).length() < 1.2 else 0.15  # braking beats at the end
		b.flap = lerpf(b.flap, beat, delta * 4.0)
		b.phase += delta * lerpf(14.0, 22.0, b.flap)
		b.fold = maxf(b.fold - delta * 4.0, 0.0)
		var flat := Vector2(b.vel.x, b.vel.z)
		if flat.length() > 0.2:
			b.yaw = lerp_angle(b.yaw, atan2(-b.vel.x, -b.vel.z), delta * 8.0)


## Where an airborne bird is headed: the flock's goal for the leader (and everyone, leaving);
## following, a place behind and beside the leader; milling, round the flock's centre.
func _goal_for(b: Bird, c: Vector3, leader: Bird, i: int) -> Vector3:
	var in_line := _mode == AirMode.FOLLOW or _state == State.LEAVING or _state == State.LANDING
	if b == leader:
		return _goal if in_line else _orbit(b, c)
	if in_line:
		var back := -leader.vel.normalized() if leader.vel.length() > 0.1 else Vector3.BACK
		var side := back.cross(Vector3.UP).normalized() * (1.0 if i % 2 == 0 else -1.0)
		return leader.pos + back * (0.8 + i * 0.45) + side * (0.5 + (i / 2) * 0.35) + Vector3.UP * 0.2 * (i % 3)
	return _orbit(b, c)


## Milling: on round the flock's centre (radius ~2.5 m, over the goal) at its own height.
func _orbit(b: Bird, c: Vector3) -> Vector3:
	var centre := c.lerp(_goal, 0.2)
	var off := b.pos - centre
	off.y = 0.0
	if off.length() < 0.01:
		off = Vector3.RIGHT
	var r := off.normalized()
	var tangent := Vector3.UP.cross(r)
	return centre + r * 2.5 + tangent * 3.0 + Vector3.UP * (_goal.y - b.pos.y) * 0.5


## On a roof or the street: hop about now and then, peck (more in the street), look round.
func _step_ground(b: Bird, delta: float) -> void:
	b.fold = minf(b.fold + delta * 5.0, 1.0)
	b.flap = 0.0
	if b.hop_t < 1.0:
		b.hop_t = minf(b.hop_t + delta / 0.22, 1.0)
		b.pos = b.hop_from.lerp(b.hop_to, b.hop_t) + Vector3.UP * sin(b.hop_t * PI) * 0.07 * size
		return
	b.peck = maxf(b.peck - delta * 4.0, 0.0)
	b.next_hop -= delta
	b.next_peck -= delta
	var foraging := _state == State.FORAGING or (_state == State.LANDING and not _landing_on_roof)
	if b.next_peck <= 0.0 and foraging:
		b.peck = 1.0
		b.next_peck = _rng.randf_range(0.4, 1.6)
	if b.next_hop <= 0.0:
		b.next_hop = _rng.randf_range(0.8, 2.5) if foraging else _rng.randf_range(2.0, 6.0)
		var a := _rng.randf() * TAU
		var step := _rng.randf_range(0.12, 0.35) * size
		var to := b.pos + Vector3(cos(a), 0.0, sin(a)) * step
		# Stay near the spot; follow the surface (roof slope, kerb) by a short ray.
		var home := _forage if foraging else _perch
		if Vector2(to.x - home.x, to.z - home.z).length() > (2.0 if foraging else 1.0):
			to = b.pos + (home - b.pos).normalized() * step
		var hit := _ray_down(Vector2(to.x, to.z))
		if not hit.is_empty() and absf((hit.position as Vector3).y - b.pos.y) < 0.3:
			b.hop_from = b.pos
			b.hop_to = hit.position
			b.hop_t = 0.0
			b.yaw = atan2(-(to.x - b.pos.x), -(to.z - b.pos.z))
		else:
			b.yaw += _rng.randf_range(-1.2, 1.2)


func _draw_birds() -> void:
	_mm.visible_instance_count = _birds.size()
	for i in _birds.size():
		var b := _birds[i]
		var basis := Basis(Vector3.UP, b.yaw)
		if b.grounded:
			basis = basis * Basis(Vector3.RIGHT, -b.peck * 0.7)
		else:
			# Pitch with the climb, bank into turns a little.
			var pitch := clampf(b.vel.y * 0.08, -0.5, 0.5)
			basis = basis * Basis(Vector3.RIGHT, pitch)
		_mm.set_instance_transform(i, Transform3D(basis.scaled(Vector3.ONE * size), b.pos + Vector3.UP * 0.035 * size))
		_mm.set_instance_custom_data(i, Color(fmod(b.phase, TAU), b.flap, b.fold, b.shade))


# --- Mesh and editor preview ----------------------------------------------------------------

## The bird: a plump body (lighter belly), a round darker head with a beak, a tail fan and
## two wings (forward -Z, ~0.4 m across the wings at size 1). COLOR as n64_bird.gdshader
## reads it.
static func make_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tri := func(a: Vector3, b: Vector3, c: Vector3, part: float, wing: bool) -> void:
		var n := (b - a).cross(c - a).normalized()
		var shade := 0.7 + 0.3 * clampf(n.y * 0.5 + 0.5, 0.0, 1.0) if not wing else 0.9
		for p in [a, b, c]:
			st.set_color(Color(shade, part, 0.0, 1.0 if wing and absf(p.x) > 0.02 else 0.0))
			st.set_normal(n)
			st.add_vertex(p)
	# An octahedron: the top four faces as `top_part`, the bottom four as `bottom_part`.
	var blob := func(front: Vector3, back: Vector3, up: Vector3, down: Vector3, half_w: float, mid: Vector3,
			top_part: float, bottom_part: float) -> void:
		var l := mid + Vector3(-half_w, 0, 0)
		var r := mid + Vector3(half_w, 0, 0)
		for f in [[front, up, l], [front, r, up], [back, l, up], [back, up, r]]:
			tri.call(f[0], f[1], f[2], top_part, false)
		for f in [[front, down, r], [front, l, down], [back, r, down], [back, down, l]]:
			tri.call(f[0], f[1], f[2], bottom_part, false)
	# Body, belly underneath.
	blob.call(Vector3(0, 0.025, -0.065), Vector3(0, 0.015, 0.09), Vector3(0, 0.068, -0.005), Vector3(0, -0.042, 0.0),
		0.052, Vector3(0, 0.014, -0.005), 0.0, 0.33)
	# Head, sat up at the front.
	blob.call(Vector3(0, 0.068, -0.112), Vector3(0, 0.07, -0.045), Vector3(0, 0.1, -0.078), Vector3(0, 0.035, -0.072),
		0.032, Vector3(0, 0.068, -0.078), 0.66, 0.66)
	# Beak.
	tri.call(Vector3(-0.009, 0.066, -0.106), Vector3(0.009, 0.066, -0.106), Vector3(0, 0.058, -0.135), 1.0, false)
	tri.call(Vector3(-0.009, 0.066, -0.106), Vector3(0, 0.058, -0.135), Vector3(0.009, 0.066, -0.106), 1.0, false)
	# Tail fan.
	tri.call(Vector3(0, 0.024, 0.05), Vector3(-0.035, 0.022, 0.155), Vector3(0.035, 0.022, 0.155), 0.66, false)
	for side in [-1.0, 1.0]:
		var root_f := Vector3(0.035 * side, 0.04, -0.03)
		var root_b := Vector3(0.035 * side, 0.04, 0.04)
		var tip := Vector3(0.2 * side, 0.036, 0.045)
		var mid := Vector3(0.12 * side, 0.036, 0.07)
		tri.call(root_f, tip, root_b, 0.66, true)
		tri.call(root_b, tip, mid, 0.66, true)
	return st.commit()


## Prop brush pick box (PropSpec): a small block at the flock's centre (the ring shows its area).
func prop_bounds() -> AABB:
	return AABB(Vector3(-0.4, 0.0, -0.4), Vector3(0.8, 0.8, 0.8))


## Editor: the area as a ring on the ground.
func _update_preview() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if _preview == null:
		_preview = MeshInstance3D.new()
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(0.55, 0.85, 1.0)
		_preview.material_override = m
		add_child(_preview, false, INTERNAL_MODE_BACK)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in 65:
		var a := TAU * i / 64.0
		im.surface_add_vertex(Vector3(cos(a), 0.05, sin(a)) * Vector3(radius, 1.0, radius))
	im.surface_end()
	_preview.mesh = im
