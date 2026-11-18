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
## World height of the ground the weather's ground-hugging fog lies on (WeatherPreset
## fog_height counts up from here).
@export var fog_floor := 0.0
## Screen look for the whole zone (ScreenLook: gradient map, palette or LUT); a room's or
## the weather's wins.
@export var screen_look: ScreenLook
## Reverb here (N64Synth.SetReverbPreset, Zelda's model); empty = outdoor under a sky, else
## room. Rooms can override it.
@export var reverb := ""
## Muffles all sound (low-pass, Hz; 0 = off).
@export_range(0.0, 16000.0, 10.0, "suffix:Hz") var muffle_hz := 0.0
## The picture's warp while here (ScreenDistortion): Hot room = OoT's heat shimmer (Death
## Mountain Crater, Fire Temple), Jabu = a breathing belly, Underwater = the slow sway.
@export var distortion := ScreenDistortion.Kind.NONE
@export_group("Ground mist")
## Knee-deep mist on the ground that actors part (GroundMist): 0..1, or -1 = the weather's
## (WeatherPreset.ground_mist: Misty has it). Rooms can override.
@export_range(-1.0, 1.0, 0.05) var ground_mist := -1.0
## Its height (metres; 0 = the weather's), steps each ray takes through it (more = smoother
## tops, a little more cost), and dithered instead of blended.
@export_range(0.0, 2.0, 0.05, "suffix:m") var ground_mist_height := 0.0
@export_range(2, 12) var ground_mist_layers := 8
## How far round the camera it's drawn (metres across; beyond, the regular fog takes over).
@export_range(10.0, 120.0, 1.0, "suffix:m") var ground_mist_reach := 60.0
@export var ground_mist_dither := false
@export_group("Local weather")
## Weather this place makes for itself (a forest up in the clouds): on arriving, most days
## (`local_weather_chance`, rolled per day) the weather turns to it at once, and back to what
## it was on leaving. Empty = the game's weather as it is.
@export var local_weather := &""
@export_range(0.0, 1.0, 0.05) var local_weather_chance := 0.75
## Cloud banks rolling through (WeatherPreset.cloud_banks): 0..1, or -1 = the weather's.
@export_range(-1.0, 1.0, 0.05) var cloud_banks := -1.0
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


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		MachineBus.reset()  # (a new zone's machines start from rest)


func _ready() -> void:
	if zone_id == &"":
		zone_id = StringName(scene_file_path.get_file().get_basename())
	_apply_local_weather()
	if display_name.is_empty():
		display_name = String(zone_id).capitalize()
	_collect(self)
	# Baked Vertex / Timed Dynamic levels: lights baked into them skip them live (before rooms unload).
	LevelLights.apply(self)
	PropBatch.add_auto(self)  # (static props without their own batching)
	if distortion != ScreenDistortion.Kind.NONE and not Engine.is_editor_hint() and not DropPortal.is_preview(self):
		ScreenDistortion.request(distortion, -1)
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
	RenderScale.set_scene_mix(_screen_mix())
	_update_key_light(delta)
	_update_audio(delta)
	_update_mist(delta)
	_update_dust(delta)
	_update_clouds(delta)
	_update_grass_sim(delta)
	_update_ripples(delta)


# --- Ground mist -----------------------------------------------------------------------------

var _mist: GroundMist
var _mist_amount := 0.0


## The mist wanted here (room's, else zone's, else the weather's), eased in / out; the node
## is made the first time any is wanted.
func _update_mist(delta: float) -> void:
	var w: Dictionary = GameState.weather_now
	var want: float = float(w.get("ground_mist", 0.0)) if _sky() != null else 0.0
	if ground_mist >= 0.0:
		want = ground_mist
	if current_room and current_room.ground_mist >= 0.0:
		want = current_room.ground_mist
	_mist_amount = move_toward(_mist_amount, want, delta / 3.0)
	if _mist == null:
		if _mist_amount <= 0.001:
			return
		_mist = GroundMist.new()
		_mist.layer_count = ground_mist_layers
		_mist.patch = ground_mist_reach
		_mist.dither = ground_mist_dither
		add_child(_mist, false, INTERNAL_MODE_BACK)
	_mist.height = ground_mist_height if ground_mist_height > 0.0 else float(w.get("ground_mist_height", 0.7))
	_mist.amount = _mist_amount


# --- Wind-blown dust (a GroundMist made as dust) ----------------------------------------------

## Dust blowing through town on a windy day (WeatherPreset.dust): the ground mist's billowing
## columns, taller (DUST_HEIGHT), thinner, sand-coloured for the hour (WindDust.colours) and
## blown quickly along the wind. The far band past the town is WindDust's (DynamicSky).
const DUST_HEIGHT := 4.5
var _dust: GroundMist
var _dust_amount := 0.0
var _dust_age := 0.0


func _update_dust(delta: float) -> void:
	var sky := _sky()
	var want: float = float(GameState.weather_now.get("dust", 0.0)) if sky != null else 0.0
	if current_room and current_room.ground_mist >= 0.0:
		want = 0.0  # (rooms with their own mist setting are indoors / sheltered)
	# (eased in / out as the weather turns; already there when the zone opens)
	_dust_age += delta
	_dust_amount = want if _dust_age < 0.5 else move_toward(_dust_amount, want, delta / 3.0)
	if _dust == null:
		if _dust_amount <= 0.001:
			return
		_dust = GroundMist.new()
		_dust.name = "Dust"
		_dust.simulate = false
		_dust.layer_count = 6
		_dust.patch = 80.0
		_dust.height = DUST_HEIGHT
		_dust.cloud_size = 40.0
		_dust.churn = 2.4
		_dust.density = 0.55
		_dust.thickness = 0.45
		_dust.top_light = 0.25
		_dust.near_clear = 6.0
		_dust.open = true
		# (mostly a light cover, under half as thick, with thick clumps blowing through)
		# (a clump every ~60 m of walking - some 12 s - ~30 m across, ~15% of the town)
		_dust.bunch_size = 300.0
		_dust.bunch_range = Vector2(0.55, 0.8)
		_dust.bunch_floor = 0.3
		_dust.bunch_peak = 2.6
		add_child(_dust, false, INTERNAL_MODE_BACK)
	var cols := WindDust.colours(GameState.time_of_day, false)
	var c: Color = (cols[0] as Color).lerp(cols[1], 0.4)
	# (a little greyed: thin airborne dust, not sand)
	var grey := c.get_luminance()
	c = c.lerp(Color(grey, grey, grey), 0.3)
	c.a = 1.0
	_dust.color = c
	_dust.amount = _dust_amount


# --- Local weather -------------------------------------------------------------------------

var _weather_before := &""


## On arriving: this place's own weather most days (rolled by zone and day, so it holds for
## the day), put back on leaving.
func _apply_local_weather() -> void:
	if local_weather == &"" or Engine.is_editor_hint() or DropPortal.is_preview(self):
		return
	var roll := float(hash(str(zone_id, ":", GameState.day)) % 1000) / 1000.0
	if roll < local_weather_chance and GameState.weather != local_weather:
		_weather_before = GameState.weather
		GameState.set_weather(local_weather, 0.0)


# --- Cloud banks (a GroundMist made tall and white) ------------------------------------------

## Cloud rolling through the trees (WeatherPreset.cloud_banks): the ground mist's columns made
## tall (cloud_banks_height), big and slow-churning, thick banks passing between thinner
## cloud, blown along the wind, in the fog's colour. The camera stands inside it.
var _clouds: GroundMist
var _clouds_amount := 0.0
var _clouds_age := 0.0


func _update_clouds(delta: float) -> void:
	var w: Dictionary = GameState.weather_now
	var want: float = float(w.get("cloud_banks", 0.0)) if _sky() != null else 0.0
	if cloud_banks >= 0.0:
		want = cloud_banks
	if current_room and current_room.ground_mist >= 0.0:
		want = 0.0  # (rooms with their own mist are indoors / sheltered)
	_clouds_age += delta
	_clouds_amount = want if _clouds_age < 0.5 else move_toward(_clouds_amount, want, delta / 4.0)
	if _clouds == null:
		if _clouds_amount <= 0.001:
			return
		_clouds = GroundMist.new()
		_clouds.name = "Clouds"
		_clouds.simulate = false
		_clouds.layer_count = 8
		_clouds.patch = 110.0
		_clouds.spacing = 4.0
		_clouds.cloud_size = 70.0
		_clouds.churn = 0.9
		_clouds.density = 0.5
		_clouds.thickness = 0.05
		_clouds.top_light = 0.4
		_clouds.near_clear = 8.0
		_clouds.open = true
		# (banks ~60 m across passing through every so often, thin cloud between)
		_clouds.bunch_size = 260.0
		_clouds.bunch_range = Vector2(0.4, 0.75)
		_clouds.bunch_floor = 0.2
		_clouds.bunch_peak = 2.6
		add_child(_clouds, false, INTERNAL_MODE_BACK)
	_clouds.height = float(w.get("cloud_banks_height", 14.0))
	var c: Color = n64_fog_colour_now()
	c.a = 1.0
	_clouds.color = c
	_clouds.amount = _clouds_amount


## The fog colour on screen now (the clouds take it, so they melt into the distance).
func n64_fog_colour_now() -> Color:
	var f := fog_target()
	return f.get("color", Color(0.8, 0.82, 0.85)) as Color


# --- Grass wading (GroundSim) --------------------------------------------------------------

const GRASS_MAT := "res://addons/n64_runtime/shaders/n64_grass_mat.gdshader"
const GRASS_TUFT := "res://addons/n64_runtime/shaders/n64_grass_tuft.gdshader"
const MIST_SIM := preload("res://addons/n64_runtime/shaders/n64_mist_sim.gdshader")
var _grass_sim: GroundSim
var _grass_mats: Array[ShaderMaterial] = []
var _grass_scan := 0.0


## The grass simulation (made when the zone has carpets / tufts): actors dent the carpet and
## bend the tufts; it stays flattened ~3 s, then rises back slowly (~2 s). Its texture goes to every grass
## material here once, its square (which follows the camera) each frame.
func _update_grass_sim(delta: float) -> void:
	_grass_scan -= delta
	if _grass_scan <= 0.0:
		_grass_scan = 2.0
		var found: Array[ShaderMaterial] = []
		_find_grass_mats(self, found)
		if found.size() != _grass_mats.size():
			_grass_mats = found
			if not _grass_mats.is_empty() and _grass_sim == null:
				_grass_sim = GroundSim.new(MIST_SIM, 64, 16.0)
				_grass_sim.radius = 0.4
				_grass_sim.radius_other = 0.34
				_grass_sim.params = {press_hold = 3.0, fill_time = 1.6, return_rate = 0.25, snap_press = 0.85, stand_press = 0.55, spread = 0.03, carry = 0.0}
				_grass_sim.process_priority = -10
				add_child(_grass_sim, false, INTERNAL_MODE_BACK)
			if _grass_sim:
				for m in _grass_mats:
					m.set_shader_parameter(&"field_map", _grass_sim.texture)
	if _grass_sim:
		var r := _grass_sim.rect()
		for m in _grass_mats:
			m.set_shader_parameter(&"field_rect", r)


func _find_grass_mats(node: Node, out: Array[ShaderMaterial]) -> void:
	var g := node as GeometryInstance3D
	if g:
		var mats: Array = [g.material_override]
		var mesh: Mesh = null
		if g is MeshInstance3D:
			mesh = (g as MeshInstance3D).mesh
		elif g is MultiMeshInstance3D and (g as MultiMeshInstance3D).multimesh:
			mesh = (g as MultiMeshInstance3D).multimesh.mesh
		if mesh:
			for i in mesh.get_surface_count():
				mats.append(mesh.surface_get_material(i))
				if g is MeshInstance3D:
					mats.append((g as MeshInstance3D).get_surface_override_material(i))
		for m in mats:
			var sm := m as ShaderMaterial
			if sm and sm.shader and sm.shader.resource_path in [GRASS_MAT, GRASS_TUFT] and not sm in out:
				out.append(sm)
	for c in node.get_children(true):
		_find_grass_mats(c, out)


# --- Ripples (GroundSim) -------------------------------------------------------------------

const RIPPLE_SIM := preload("res://addons/n64_runtime/shaders/n64_ripple_sim.gdshader")
const RIPPLE_RES := 128
const RIPPLE_SIZE := 12.0
const RIPPLE_SHADERS := ["paint.gdshader", "paint_cutout.gdshader", "paint_hybrid.gdshader",
	"paint_hybrid_cutout.gdshader", "paint_unshaded.gdshader", "paint_unshaded_cutout.gdshader",
	"paint_merged.gdshader", "n64_water.gdshader"]
var _ripple_sim: GroundSim
## Footprints on soft ground (sand, snow, dirt): their own slow simulation, 128 texels over
## 16 m round the camera (each print holds PRINT_HOLD seconds, then fades out over PRINT_FADE;
## and as the camera leaves them).
const PRINT_RES := 128
const PRINT_SIZE := 16.0
const PRINT_HOLD := 6.0
const PRINT_FADE := 3.0
var _print_sim: GroundSim
var _print_mats := {}
var _ripple_mats := {}  # ShaderMaterial -> true (bound)
var _ripple_scan := 0.0
var _drip_lines: Array = []  # [Vector3 a, Vector3 b] where each roof drip lands


## The ripple simulation (outdoors, or with water): drips off the eaves while it rains,
## actors' wakes and landings; its texture is bound once to the level's and water's materials
## (its square each frame through the n64_ripple_rect / n64_print_rect shader globals).
func _update_ripples(delta: float) -> void:
	_ripple_scan -= delta
	if _ripple_scan <= 0.0:
		_ripple_scan = 3.0
		var mats: Array[ShaderMaterial] = []
		_find_shader_mats(self, RIPPLE_SHADERS, mats)
		var water := mats.any(func(m): return m.shader.resource_path.ends_with("n64_water.gdshader"))
		if _ripple_sim == null and (_sky() != null or water):
			_ripple_sim = GroundSim.new(RIPPLE_SIM, RIPPLE_RES, RIPPLE_SIZE)
			_ripple_sim.radius = 0.5
			_ripple_sim.radius_other = 0.4
			_ripple_sim.rect_global = &"n64_ripple_rect"
			_ripple_sim.process_priority = -10
			add_child(_ripple_sim, false, INTERNAL_MODE_BACK)
		var soft := mats.any(func(m): return float(m.get_shader_parameter(&"soft_ground") if m.get_shader_parameter(&"soft_ground") != null else 0.0) > 0.0)
		if _print_sim == null and soft:
			_print_sim = GroundSim.new(MIST_SIM, PRINT_RES, PRINT_SIZE)
			_print_sim.footprints = true
			_print_sim.radius = 0.13
			_print_sim.radius_other = 0.11
			_print_sim.params = {hold_time = PRINT_HOLD, fade_time = PRINT_FADE, spread = 0.0, carry = 0.0}
			_print_sim.rect_global = &"n64_print_rect"
			_print_sim.process_priority = -10
			add_child(_print_sim, false, INTERNAL_MODE_BACK)
		for m in mats:
			if _ripple_sim and not _ripple_mats.has(m):
				_ripple_mats[m] = true
				m.set_shader_parameter(&"ripple_map", _ripple_sim.texture)
				m.set_shader_parameter(&"ripple_dims", Vector2(RIPPLE_SIZE, RIPPLE_RES))
			if _print_sim and not _print_mats.has(m):
				_print_mats[m] = true
				m.set_shader_parameter(&"print_map", _print_sim.texture)
				m.set_shader_parameter(&"print_dims", Vector2(PRINT_SIZE, PRINT_RES))
		_drip_lines.clear()
		for d in find_children("*", "Node3D", true, false).filter(func(n): return n is RainDrip):
			var hw: float = float(d.get(&"width")) * 0.5
			var drop: float = float(d.get(&"drop"))
			var xf: Transform3D = d.global_transform
			_drip_lines.append([xf * Vector3(-hw, -drop, 0.0), xf * Vector3(hw, -drop, 0.0)])
	if _ripple_sim == null:
		return
	var rain: float = float(GameState.weather_now.get("rain", 0.0)) if _sky() != null else 0.0
	var r := _ripple_sim.rect()
	var lines := PackedVector4Array()
	if rain > 0.0:
		var centre := Vector2(r.x, r.y) + Vector2.ONE * r.z * 0.5
		var near := _drip_lines.filter(func(l): return Vector2(l[0].x, l[0].z).distance_to(centre) < r.z * 0.8)
		for l in near.slice(0, 16):
			var a := (Vector2(l[0].x, l[0].z) - Vector2(r.x, r.y)) / r.z
			var b := (Vector2(l[1].x, l[1].z) - Vector2(r.x, r.y)) / r.z
			lines.append(Vector4(a.x, a.y, b.x, b.y))
	var n := lines.size()
	while lines.size() < 16:
		lines.append(Vector4.ZERO)
	_ripple_sim.params = {time = Time.get_ticks_msec() / 1000.0, rain = rain, drips = lines, drip_count = n}


## ShaderMaterials under `node` whose shader file is one of `names`.
func _find_shader_mats(node: Node, names: Array, out: Array[ShaderMaterial]) -> void:
	var g := node as GeometryInstance3D
	if g:
		var mats: Array = [g.material_override]
		var mesh: Mesh = null
		if g is MeshInstance3D:
			mesh = (g as MeshInstance3D).mesh
		elif g is MultiMeshInstance3D and (g as MultiMeshInstance3D).multimesh:
			mesh = (g as MultiMeshInstance3D).multimesh.mesh
		if mesh:
			for i in mesh.get_surface_count():
				mats.append(mesh.surface_get_material(i))
				if g is MeshInstance3D:
					mats.append((g as MeshInstance3D).get_surface_override_material(i))
		for m in mats:
			var sm := m as ShaderMaterial
			if sm and sm.shader and sm.shader.resource_path.get_file() in names and not sm in out:
				out.append(sm)
	for c in node.get_children(true):
		_find_shader_mats(c, names, out)


# --- Audio (Zelda reverb / muffling on every N64Synth) ---------------------------------------

var _audio_key := ""
var _audio_scan := 0.0


## The current room's reverb and muffling, else the zone's, on every synth (music, effects):
## sent when they change, and again when a synth appears.
func _update_audio(delta: float) -> void:
	_audio_scan -= delta
	var preset := current_room.reverb if current_room and current_room.reverb != "" else reverb
	if preset == "":
		preset = "outdoor" if _sky() != null else "room"
	var muffle := current_room.muffle_hz if current_room and current_room.muffle_hz > 0.0 else muffle_hz
	var synths := get_tree().get_node_count_in_group(&"n64_synth")
	var key := "%s|%s|%d" % [preset, muffle, synths]
	if key == _audio_key or (synths == 0 and _audio_scan > 0.0):
		return
	_audio_scan = 1.0
	_audio_key = key
	get_tree().call_group(&"n64_synth", &"SetReverbPreset", preset)
	get_tree().call_group(&"n64_synth", &"SetOutputLowPass", muffle)


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
	var room_fog := current_room.fog_override if current_room and current_room.fog_override else null
	return fog_for(room_fog if room_fog else fog, room_fog != null, _sky() != null, GameState.weather_now,
		GameState.lighting_schedule, GameState.time_of_day)


## The fog for settings `s` (the zone's, or a room's override when `is_room`), under a sky
## or not, in weather `w` at `hour` (fog_target's core; also the editor's game preview).
static func fog_for(s: FogSettings, is_room: bool, has_sky: bool, w: Dictionary, sched: LightingSchedule, hour: float) -> Dictionary:
	var outdoor := has_sky and w.has("fog_end")
	var zone_fog := not is_room
	var lit_sky := has_sky and sched != null and zone_fog
	var dist_k := sched.fog_distance_at(hour) if lit_sky else 1.0
	if outdoor and zone_fog and float(w.get("fog_override", 0.0)) > 0.5:
		s = null  # (the weather's fog takes over: below)
	if s == null:
		if outdoor:
			return {color = _weather_fog_color(w), start = w.fog_begin * dist_k, end = w.fog_end * dist_k, amount = w.fog_amount,
				curve = FogSettings.FogCurve.N64_DEPTH, sampling = FogSettings.Sampling.SOFT_GRID, grid = 3.0, center = FogSettings.Center.CAMERA, tint = 0.3, halos = 0.6, lights = 4, light_sampling = FogSettings.LightSampling.FOLLOW_FOG, blend = 1.0}
		return {color = Color.BLACK, start = 10.0, end = 60.0, amount = 0.0, curve = FogSettings.FogCurve.N64_DEPTH,
			sampling = FogSettings.Sampling.SOFT_GRID, grid = 3.0, center = FogSettings.Center.CAMERA, tint = 0.3, halos = 0.6, lights = 4, light_sampling = FogSettings.LightSampling.FOLLOW_FOG, blend = 1.0}
	if not s.enabled:
		return {color = s.color, start = s.start, end = s.end, amount = 0.0, curve = s.curve, sampling = s.sampling, grid = s.grid_size, center = s.center, tint = s.light_tint, halos = s.light_halos, lights = s.max_fog_lights, light_sampling = s.light_sampling,
			blend = s.blend_time}
	if s.from_weather and outdoor:
		return {color = _weather_fog_color(w), start = w.fog_begin * dist_k, end = w.fog_end * dist_k, amount = w.fog_amount * s.amount,
			curve = s.curve, sampling = s.sampling, grid = s.grid_size, center = s.center, tint = s.light_tint, halos = s.light_halos, lights = s.max_fog_lights, light_sampling = s.light_sampling, blend = s.blend_time}
	# A fixed colour under the open sky is lit like the level: dark and blue at night.
	# ... and closes in when the keys say so (night hides the distance).
	var lit := s.color * sched.light_at(hour) * sched.fog_brightness_at(hour) if lit_sky else s.color
	return {color = lit, start = s.start * dist_k, end = s.end * dist_k, amount = s.amount, curve = s.curve, sampling = s.sampling, grid = s.grid_size, center = s.center, tint = s.light_tint, halos = s.light_halos, lights = s.max_fog_lights, light_sampling = s.light_sampling,
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


## The screen looks wanted here, {ScreenLook: weight}: the current room's; else outdoors
## the weather's look for the time of day (its SkyKeys' looks blended by the hour like the
## sky, then its own screen_look, then the zone's), both weathers while the weather changes;
## else the zone's.
func _screen_mix() -> Dictionary:
	if current_room and current_room.screen_look:
		return {current_room.screen_look: 1.0}
	var out := {}
	var add := func(look: ScreenLook, w: float) -> void:
		if look and w > 0.0:
			out[look] = out.get(look, 0.0) + w
	if _sky() != null and GameState.weather_table and not (current_room and current_room.fog_override):
		var sched := GameState.lighting_schedule
		var b := sched.blend_for(GameState.time_of_day) if sched else Vector3.ZERO
		var tb := smoothstep(0.0, 1.0, GameState.weather_blend)
		for pair in [[GameState.weather_from, 1.0 - tb], [GameState.weather, tb]]:
			if pair[1] <= 0.0:
				continue
			var p: WeatherPreset = GameState.weather_table.find(pair[0])
			if p == null:
				add.call(screen_look, pair[1])
				continue
			for k in [[int(b.x), 1.0 - b.z], [int(b.y), b.z]]:
				var key_look: ScreenLook = p.get_key(k[0]).screen_look if not p.keys.is_empty() else null
				add.call(key_look if key_look else (p.screen_look if p.screen_look else screen_look), pair[1] * k[1])
		return out
	add.call(screen_look, 1.0)
	return out


## The weather's fog colour: its horizon shaded by fog_shade by day, fog_night_shade once
## the sky is dark (night fog glows paler than the sky).
static func _weather_fog_color(w: Dictionary) -> Color:
	var h: Color = w.horizon
	var day := smoothstep(0.12, 0.4, h.get_luminance())
	return h * lerpf(float(w.get("fog_night_shade", 1.0)), float(w.get("fog_shade", 1.0)), day)


## The weather's fog look (WeatherPreset "Fog look") when the fog comes from the weather,
## else none: {height, thin, drift, drift_size, glow}.
func _fog_look() -> Dictionary:
	var none := {height = 0.0, thin = 0.0, drift = 0.0, drift_size = 14.0, glow = 0.0}
	var s: FogSettings = current_room.fog_override if current_room and current_room.fog_override else fog
	var w: Dictionary = GameState.weather_now
	var takes_over := s == fog and float(w.get("fog_override", 0.0)) > 0.5
	if _sky() == null or not w.has("fog_height") or (s != null and not takes_over and not (s.enabled and s.from_weather)):
		return none
	return {height = w.fog_height, thin = w.fog_height_thin, drift = w.fog_drift, drift_size = w.fog_drift_size, glow = w.fog_glow}


func _update_fog(delta: float) -> void:
	var t := fog_target()
	t.merge(_fog_look())
	if fog_now.is_empty():
		fog_now = t.duplicate()
	else:
		var k := clampf(delta / maxf(t.blend, 0.001), 0.0, 1.0)
		fog_now.color = (fog_now.color as Color).lerp(t.color, k)
		for key in [&"start", &"end", &"amount", &"tint", &"halos", &"height", &"thin", &"drift", &"drift_size", &"glow"]:
			fog_now[key] = lerpf(fog_now.get(key, t[key]), t[key], k)
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
	RenderingServer.global_shader_parameter_set(&"n64_fog_height",
		Vector4(fog_floor, fog_now.get("height", 0.0), fog_now.get("thin", 0.0), 0.0))
	# Banks drift with the wind (the zone's, scaled by the weather's, as DynamicSky's n64_wind),
	# at a slow walk.
	var a := deg_to_rad(wind_direction)
	var strength: float = wind_strength * float(GameState.weather_now.get("wind", 1.0))
	var drift_v := Vector2(cos(a), -sin(a)) * (0.4 + 0.8 * strength)
	RenderingServer.global_shader_parameter_set(&"n64_fog_drift",
		Vector4(fog_now.get("drift", 0.0), fog_now.get("drift_size", 14.0), drift_v.x, drift_v.y))
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
	# Thick fog (the weather's fog_glow): light hangs in the air, a wider, brighter glow.
	var glow: float = fog_now.get("glow", 0.0)
	var tint: float = fog_now.get("tint", 0.0) + rain * RAIN_TINT + glow * 0.6
	var halos: float = fog_now.get("halos", 0.0) * (1.0 + rain + glow) + rain * RAIN_HALOS
	RenderingServer.global_shader_parameter_set(&"n64_fog_lights", Vector4(tint, halos, follow, 1.0 + glow * 1.5))
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
	if _weather_before != &"" and GameState.weather == local_weather:
		GameState.set_weather(_weather_before, 0.0)
	if distortion != ScreenDistortion.Kind.NONE and not DropPortal.is_preview(self):
		ScreenDistortion.release(distortion)
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
