class_name Zone
extends Node3D
## Root node of a zone scene (an area loaded as a whole behind a loading screen, e.g.
## a field or a dungeon). Streams its Rooms based on RoomPortals the player crosses:
## the current room is active, rooms the player is between (inside a portal) are active,
## and neighbours of active rooms keep geometry only. Everything else is removed from
## the scene tree.

signal room_changed(room: Room)

## Defaults to the scene file name.
@export var zone_id: StringName
@export var display_name := ""
## Whether the GameState clock runs here (off for dungeons and interiors).
@export var time_flows := true
## Darkness of actors' projected shadows here (0 = none, 1 = black). Match it to the
## zone's baked shadows: lower in bright, open zones, higher in dark interiors.
@export_range(0.0, 1.0, 0.05) var shadow_strength := 0.7
## Room the player starts in when the spawn point doesn't name one.
@export var start_room: Room

@export_group("Fog")
## N64-style fog here. Empty = the weather's fog in zones with a DynamicSky, else none.
## Rooms can override it (Room.fog_override).
@export var fog: FogSettings
## Wind (grass, trees, rain): direction it blows towards (degrees, 0 = +X, 90 = -Z) and
## strength (0 still .. 1 a stiff breeze), scaled by the weather (WeatherPreset.wind).
## Sheltered zones (valleys, towns) want less than open fields.
@export_range(0.0, 360.0, 1.0) var wind_direction := 30.0
@export_range(0.0, 2.0, 0.05) var wind_strength := 0.35
## Draw distance follows the fog: the camera's far clip sits at the fog end + margin, so
## distant geometry fades out instead of popping (and isn't drawn past it). Only while
## the fog is fully opaque at its end; off = keep the camera's own far clip.
@export var clip_at_fog_end := true
@export_range(0.0, 50.0, 0.5, "suffix:m") var clip_margin := 2.0
@export_group("Intro")
## The first time the player arrives (Majora's Mask style): a camera pan over the area and
## its name as a title card. Plays once (its cutscene's "seen" flag).
@export var intro := true
## The intro to play (author it in the Story workspace's Cutscenes tab: camera shots and a
## Title event). Empty = a pan made from the area's size: high over a corner, sweeping
## round towards where the player stands, with display_name as the title.
@export var intro_cutscene: Cutscene
@export_group("")

var rooms: Array[Room] = []
var portals: Array[RoomPortal] = []
var current_room: Room
var player: Node3D

## Fog currently applied (blends towards the target): color, start, end, amount, curve.
var fog_now := {}
var _env: Environment
var _camera_far := {}

var _inside_portals: Array[RoomPortal] = []
var _held_rooms: Array[Room] = []


func _ready() -> void:
	if zone_id == &"":
		zone_id = StringName(scene_file_path.get_file().get_basename())
	if display_name.is_empty():
		display_name = String(zone_id).capitalize()
	_collect(self)
	# Baked Vertex / Timed Dynamic levels: lights baked into them skip them live (before rooms unload).
	LevelLights.apply(self)
	for room in rooms:
		room.setup()
	for portal in portals:
		portal.body_entered.connect(_on_portal_entered.bind(portal))
		portal.body_exited.connect(_on_portal_exited.bind(portal))


func _notification(what: int) -> void:
	# Unloaded rooms are outside the tree, so they aren't freed with the scene.
	if what == NOTIFICATION_PREDELETE:
		for room in rooms:
			if is_instance_valid(room) and not room.is_inside_tree():
				room.free()


func _process(delta: float) -> void:
	_update_fog(delta)
	_update_key_light(delta)


# --- Key light (shine glints) -----------------------------------------------------------

var _lights: Array[Light3D] = []
var _light_scan := 0.0


## n64_key_light: the sun while it's up, else the nearest omni light to the camera, as a
## direction towards the light + strength. Hilite glints on N64 materials follow it.
func _update_key_light(delta: float) -> void:
	_light_scan -= delta
	if _light_scan <= 0.0:
		_light_scan = 1.0
		_lights.clear()
		for n in find_children("*", "Light3D", true, false):
			_lights.append(n)
	var cam := get_viewport().get_camera_3d()
	var from := cam.global_position if cam else Vector3.ZERO
	var key := Vector4(0.3, 0.9, 0.3, 0.0)
	var best := 0.0
	for l in _lights:
		if not is_instance_valid(l) or not l.is_inside_tree() or not l.is_visible_in_tree() or l.light_energy <= 0.01:
			continue
		var dir: Vector3
		var w: float
		if l is DirectionalLight3D:
			dir = l.global_basis.z
			w = clampf(l.light_energy, 0.0, 1.0) * smoothstep(0.0, 0.15, dir.y)
		elif l is OmniLight3D:
			var to := l.global_position - from
			var r: float = (l as OmniLight3D).omni_range
			if to.length() >= r:
				continue
			dir = to.normalized()
			w = clampf(l.light_energy, 0.0, 1.0) * (1.0 - to.length() / r)
		else:
			continue
		if w > best:
			best = w
			key = Vector4(dir.x, dir.y, dir.z, w)
	RenderingServer.global_shader_parameter_set(&"n64_key_light", key)


# --- Fog ------------------------------------------------------------------------------

## The fog this place wants right now: the current room's override, else the zone's,
## else (outdoors) the weather's. {color, start, end, amount, curve, blend}.
func fog_target() -> Dictionary:
	var s: FogSettings = current_room.fog_override if current_room and current_room.fog_override else fog
	var w: Dictionary = GameState.weather_now
	var outdoor := _sky() != null and w.has("fog_end")
	if s == null:
		if outdoor:
			var d := outdoor_fog_distance()
			return {color = w.horizon, start = w.fog_begin * d, end = w.fog_end * d, amount = w.fog_amount,
				curve = FogSettings.FogCurve.N64_DEPTH, sampling = FogSettings.Sampling.SOFT_GRID, grid = 3.0, center = FogSettings.Center.CAMERA, tint = 0.3, halos = 0.6, lights = 4, light_sampling = FogSettings.LightSampling.FOLLOW_FOG, blend = 1.0}
		return {color = Color.BLACK, start = 10.0, end = 60.0, amount = 0.0, curve = FogSettings.FogCurve.N64_DEPTH,
			sampling = FogSettings.Sampling.SOFT_GRID, grid = 3.0, center = FogSettings.Center.CAMERA, tint = 0.3, halos = 0.6, lights = 4, light_sampling = FogSettings.LightSampling.FOLLOW_FOG, blend = 1.0}
	if not s.enabled:
		return {color = s.color, start = s.start, end = s.end, amount = 0.0, curve = s.curve, sampling = s.sampling, grid = s.grid_size, center = s.center, tint = s.light_tint, halos = s.light_halos, lights = s.max_fog_lights, light_sampling = s.light_sampling,
			blend = s.blend_time}
	if s.from_weather and outdoor:
		var d := outdoor_fog_distance() if s == fog else 1.0
		return {color = w.horizon, start = w.fog_begin * d, end = w.fog_end * d, amount = w.fog_amount * s.amount,
			curve = s.curve, sampling = s.sampling, grid = s.grid_size, center = s.center, tint = s.light_tint, halos = s.light_halos, lights = s.max_fog_lights, light_sampling = s.light_sampling, blend = s.blend_time}
	# A fixed colour under the open sky is lit like the level: dark and blue at night.
	# ... and closes in when the keys say so (night hides the distance).
	var lit := s.color * outdoor_light() * outdoor_fog_brightness() if s == fog else s.color
	var dist := outdoor_fog_distance() if s == fog else 1.0
	return {color = lit, start = s.start * dist, end = s.end * dist, amount = s.amount, curve = s.curve, sampling = s.sampling, grid = s.grid_size, center = s.center, tint = s.light_tint, halos = s.light_halos, lights = s.max_fog_lights, light_sampling = s.light_sampling,
		blend = s.blend_time}


## Outdoor fog distance multiplier now (LightingSchedule.fog_distance_at); 1 with no sky,
## no schedule, or in a room with its own fog.
func outdoor_fog_distance() -> float:
	if _sky() == null or GameState.lighting_schedule == null or (current_room and current_room.fog_override):
		return 1.0
	return GameState.lighting_schedule.fog_distance_at(GameState.time_of_day)


## Outdoor fog colour multiplier now (LightingSchedule.fog_brightness_at); same cases.
func outdoor_fog_brightness() -> float:
	if _sky() == null or GameState.lighting_schedule == null or (current_room and current_room.fog_override):
		return 1.0
	return GameState.lighting_schedule.fog_brightness_at(GameState.time_of_day)


## How lit things out under this zone's sky are now (LightingSchedule.light_at: the baked
## keys' ambient + sun / moon); white with no sky, no schedule, or in a room with its own fog.
func outdoor_light() -> Color:
	if _sky() == null or GameState.lighting_schedule == null or (current_room and current_room.fog_override):
		return Color.WHITE
	return GameState.lighting_schedule.light_at(GameState.time_of_day)


func _update_fog(delta: float) -> void:
	var t := fog_target()
	if fog_now.is_empty():
		fog_now = t.duplicate()
	else:
		var k := clampf(delta / maxf(t.blend, 0.001), 0.0, 1.0)
		fog_now.color = (fog_now.color as Color).lerp(t.color, k)
		for key in [&"start", &"end", &"amount", &"tint", &"halos"]:
			fog_now[key] = lerpf(fog_now[key], t[key], k)
		fog_now.curve = t.curve
		fog_now.sampling = t.sampling
		fog_now.grid = t.grid
		fog_now.center = t.center
		fog_now.lights = t.lights
		fog_now.light_sampling = t.light_sampling
	var c: Color = fog_now.color
	var start: float = fog_now.start
	var end: float = maxf(fog_now.end, start + 0.5)
	var amount: float = fog_now.amount
	var n64_curve: bool = fog_now.curve == FogSettings.FogCurve.N64_DEPTH
	# Shaders blend in linear colour (Environment converts its own colours itself).
	var lin := c.srgb_to_linear()
	lin.a = fog_now.grid  # alpha carries the soft-grid cell size
	RenderingServer.global_shader_parameter_set(&"n64_fog_color", lin)
	# Unbaked things (effect sprites) are lit by it too.
	RenderingServer.global_shader_parameter_set(&"n64_ambient_light", outdoor_light().srgb_to_linear())
	# Shader sampling code: 0 per pixel / 1 per vertex / 2 soft grid.
	var code := {FogSettings.Sampling.PER_PIXEL: 0.0, FogSettings.Sampling.PER_VERTEX: 1.0,
		FogSettings.Sampling.SOFT_GRID: 2.0}
	var mode: float = (0.0 if n64_curve else 1.0) + 2.0 * float(code[fog_now.sampling])
	RenderingServer.global_shader_parameter_set(&"n64_fog", Vector4(start, end, mode, amount))
	var cam := get_viewport().get_camera_3d()
	var origin := cam.global_position if cam else Vector3.ZERO
	if fog_now.center == FogSettings.Center.PLAYER and is_instance_valid(player):
		origin = player.global_position + Vector3.UP * 1.0  # around chest height
	RenderingServer.global_shader_parameter_set(&"n64_fog_origin", origin)
	_update_fog_lights(cam, end, amount)
	# Plain Godot materials (doors, labels…) get Godot's own depth fog matched to it; the
	# N64 shaders write their own fog and ignore this.
	if _env == null:
		for n in get_children():
			if n is WorldEnvironment and n.environment:
				_env = n.environment
				break
	if _env:
		_env.fog_enabled = amount > 0.001
		_env.fog_mode = Environment.FOG_MODE_DEPTH
		_env.fog_light_color = c
		_env.fog_light_energy = 1.0
		_env.fog_sun_scatter = 0.0
		_env.fog_sky_affect = 0.0
		_env.fog_density = amount
		_env.fog_depth_begin = start
		_env.fog_depth_end = end
		_env.fog_depth_curve = 4.0 if n64_curve else 1.0
	# Draw distance at the fog end (only once fog fully hides what's past it). Measured
	# from the camera, so allow for the camera's distance from the fog centre.
	if cam:
		if not _camera_far.has(cam):
			_camera_far[cam] = cam.far
		cam.far = end + clip_margin + cam.global_position.distance_to(origin) if clip_at_fog_end and amount >= 0.99 else _camera_far[cam]


const CORONA_SHADER := preload("res://addons/n64_runtime/shaders/n64_corona.gdshader")
var _coronas: MeshInstance3D

## Extra fog tint and halo strength around lights at full rain (outdoors).
const RAIN_TINT := 0.5
const RAIN_HALOS := 0.6


## Up to fog_now.lights omni / spot lights for the fog (tint + halos), most relevant to
## the camera first: strong and close (within their range + the fog distance).
func _update_fog_lights(cam: Camera3D, fog_end: float, amount: float) -> void:
	var picks := []
	# Rain reads the slots too (which way the lamps are, n64_rain_light.gdshaderinc).
	var rain: float = float(GameState.weather_now.get("rain", 0.0)) if _sky() != null else 0.0
	var max_lights: int = maxi(fog_now.get("lights", 4), 4 if rain > 0.0 else 0)
	if cam and (amount > 0.001 or rain > 0.0) and max_lights > 0:
		for l in _lights:
			if not is_instance_valid(l) or l is DirectionalLight3D or not l.is_inside_tree() \
					or not l.is_visible_in_tree() or l.light_energy <= 0.01:
				continue
			var r: float = l.get("omni_range") if l is OmniLight3D else l.get("spot_range")
			var d := cam.global_position.distance_to(l.global_position)
			var reach := r + fog_end
			if d >= reach:
				continue
			picks.append([l.light_energy * (1.0 - d / reach), l, r])
		picks.sort_custom(func(a, b): return a[0] > b[0])
	for i in 4:
		var pos := Vector4(0, -10000, 0, 0)
		var col := Vector4.ZERO
		if i < mini(picks.size(), max_lights):
			var l: Light3D = picks[i][1]
			var c := l.light_color.srgb_to_linear() * minf(l.light_energy, 2.0)
			pos = Vector4(l.global_position.x, l.global_position.y, l.global_position.z, picks[i][2])
			col = Vector4(c.r, c.g, c.b, 1.0)
		RenderingServer.global_shader_parameter_set(StringName("n64_fog_light_pos%d" % i), pos)
		RenderingServer.global_shader_parameter_set(StringName("n64_fog_light_col%d" % i), col)
	var follow := 1.0 if fog_now.get("light_sampling", 0) == FogSettings.LightSampling.FOLLOW_FOG else 0.0
	# Rain outdoors: lights glow wider and haze the wet air around them more.
	var tint: float = fog_now.get("tint", 0.0) + rain * RAIN_TINT
	var halos: float = fog_now.get("halos", 0.0) * (1.0 + rain) + rain * RAIN_HALOS
	RenderingServer.global_shader_parameter_set(&"n64_fog_lights", Vector4(tint, halos, follow, 0.0))
	if _coronas == null:
		_coronas = _make_coronas()
		add_child(_coronas, false, INTERNAL_MODE_BACK)


## The glow sprites on the fog lights (n64_corona.gdshader): a quad per light slot.
static func _make_coronas() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 4:
		for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]:
			st.set_uv(corner)
			st.set_uv2(Vector2(i, 0))
			st.add_vertex(Vector3.ZERO)
	var mesh := st.commit()
	mesh.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	var mi := MeshInstance3D.new()
	mi.name = "LightGlows"
	mi.mesh = mesh
	var m := ShaderMaterial.new()
	m.shader = CORONA_SHADER
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.top_level = true
	return mi


func _sky() -> DynamicSky:
	for n in get_children():
		if n is DynamicSky:
			return n
	return null


func _exit_tree() -> void:
	# The camera (the player's) outlives the zone: give it back its own draw distance.
	for cam in _camera_far:
		if is_instance_valid(cam):
			cam.far = _camera_far[cam]


## Called by ZoneManager once the player is placed.
func begin(new_player: Node3D, spawn: Node3D) -> void:
	player = new_player
	_inside_portals.clear()
	_held_rooms.clear()
	var room: Room = spawn.get_room() if spawn else null
	_set_current_room(room if room else start_room)


## Plays the area intro if it's on and hasn't played yet (ZoneManager, once the player is in).
func play_intro() -> void:
	if not intro:
		return
	var c := intro_cutscene if intro_cutscene else default_intro()
	if c and GameState.get_flag(c.seen_flag(), false) != true:
		Cutscenes.play(c)


## Seconds of the made-up intro, and when its title shows (and for how long).
const INTRO_LENGTH := 6.5
const INTRO_TITLE_AT := 1.4
const INTRO_TITLE_LENGTH := 4.6


## The intro made from the area's size (no intro_cutscene): over the drawn level's bounds,
## from high above one corner, sweeping 40° round (and a little down) towards the player's
## side, looking across the middle; the title fades in on the way.
func default_intro() -> Cutscene:
	var box := _drawn_bounds()
	if box.size == Vector3.ZERO:
		return null
	var c := box.get_center()
	c.y = box.position.y + minf(box.size.y * 0.15, 3.0)
	var reach := maxf(box.size.x, box.size.z) * 0.5
	var height := clampf(reach * 0.55, 14.0, 40.0)
	var toward := 0.0  # (yaw from the middle to the player)
	if player:
		var d := player.global_position - c
		toward = atan2(d.x, d.z)
	var shot := func(yaw: float, up: float) -> Transform3D:
		var at := c + Vector3(sin(yaw), 0.0, cos(yaw)) * reach * 0.7 + Vector3.UP * up
		return Transform3D(Basis.looking_at(c - at, Vector3.UP), at)
	var cs := Cutscene.new()
	cs.id = StringName("intro_%s" % zone_id)
	cs.length = INTRO_LENGTH
	cs.skip = Cutscene.Skip.ALWAYS
	var a := CutsceneCue.new()
	a.kind = CutsceneCue.Kind.SHOT
	a.move = CutsceneCue.Move.CUT
	a.transform = shot.call(toward + deg_to_rad(140.0), height)
	a.fov = 55.0
	var b := CutsceneCue.new()
	b.kind = CutsceneCue.Kind.SHOT
	b.time = 0.01
	b.move = CutsceneCue.Move.SMOOTH
	b.duration = INTRO_LENGTH
	b.transform = shot.call(toward + deg_to_rad(180.0), height * 0.8)
	b.fov = 55.0
	var t := CutsceneCue.new()
	t.kind = CutsceneCue.Kind.EVENT
	t.event = CutsceneCue.Event.TITLE
	t.time = INTRO_TITLE_AT
	t.duration = INTRO_TITLE_LENGTH
	cs.cues = [a, b, t]
	return cs


## What the zone draws, world space: its meshes' bounds together (the sky, far backdrops
## and anything over 300 m across left out).
func _drawn_bounds() -> AABB:
	var box := AABB()
	var first := true
	for n in find_children("*", "GeometryInstance3D", true, false):
		var g := n as GeometryInstance3D
		if not g.is_visible_in_tree() or not (g is MeshInstance3D or g is MultiMeshInstance3D):
			continue
		var b := g.global_transform * g.get_aabb()
		if b.size.x > 300.0 or b.size.z > 300.0 or b.size == Vector3.ZERO:
			continue
		box = b if first else box.merge(b)
		first = false
	return box


## Spawn (SpawnPoint, Passage or zone Door) by id, else one named `default`, else the first found.
## Spawns provide `spawn_id`, `get_spawn_transform()` and `get_room()`.
func find_spawn(spawn_id: StringName) -> Node3D:
	var spawns: Array[Node3D] = []
	_collect_spawns(self, spawns)
	for wanted in [spawn_id, &"default"]:
		for spawn in spawns:
			if spawn.spawn_id == wanted:
				return spawn
	for spawn in spawns:
		if spawn is SpawnPoint:
			return spawn
	return spawns[0] if spawns.size() > 0 else null


## Keeps a room active regardless of where the player is (e.g. while a Door is open).
func hold_room(room: Room) -> void:
	if room and not room in _held_rooms:
		_held_rooms.append(room)
		_refresh_rooms()


func release_room(room: Room) -> void:
	if _held_rooms.has(room):
		_held_rooms.erase(room)
		_refresh_rooms()


func set_current_room(room: Room) -> void:
	_set_current_room(room)


## Flag id scoped to this zone, e.g. flag("door_open") -> "temple/door_open".
func flag(key: String) -> String:
	return "%s/%s" % [zone_id, key]


func _set_current_room(room: Room) -> void:
	if room != current_room:
		current_room = room
		room_changed.emit(room)
	_refresh_rooms()


func _on_portal_entered(body: Node3D, portal: RoomPortal) -> void:
	if body != player or portal in _inside_portals:
		return
	_inside_portals.append(portal)
	# Room state changes add/remove physics bodies; never do that mid physics callback.
	_refresh_rooms.call_deferred()


func _on_portal_exited(body: Node3D, portal: RoomPortal) -> void:
	if body != player:
		return
	_inside_portals.erase(portal)
	var room := portal.room_on_side(player.global_position)
	if room:
		_set_current_room.call_deferred(room)
	else:
		_refresh_rooms.call_deferred()


func _refresh_rooms() -> void:
	if rooms.is_empty():
		return
	if current_room == null:
		for room in rooms:
			room.set_state(Room.State.ACTIVE)
		return
	var active := {current_room: true}
	for room in _held_rooms:
		active[room] = true
	for portal in _inside_portals:
		for room in [portal.room_a, portal.room_b]:
			if room:
				active[room] = true
	var geometry := {}
	for portal in portals:
		if not portal.preload_neighbors:
			continue
		if active.has(portal.room_a) and portal.room_b:
			geometry[portal.room_b] = true
		if active.has(portal.room_b) and portal.room_a:
			geometry[portal.room_a] = true
	for room in rooms:
		if active.has(room):
			room.set_state(Room.State.ACTIVE)
		elif geometry.has(room):
			room.set_state(Room.State.GEOMETRY)
		else:
			room.set_state(Room.State.UNLOADED)


func _collect(node: Node) -> void:
	for child in node.get_children():
		if child is Room:
			rooms.append(child)
		elif child is RoomPortal:
			portals.append(child)
		_collect(child)


func _collect_spawns(node: Node, out: Array[Node3D]) -> void:
	for child in node.get_children():
		if child is SpawnPoint or child is Passage or (child is Door and child.mode == Door.Mode.ZONE):
			out.append(child)
		_collect_spawns(child, out)
