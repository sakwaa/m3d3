extends Node
## Owns the persistent player and zone travel (fade, threaded load, spawn).
## Autoloaded as `ZoneManager`. Any scene whose root is a Zone can be run directly;
## it is adopted on start and the player is placed at its default spawn.

signal zone_changed(zone: Zone)
signal room_changed(room: Room)

const PLAYER_SCENE := "res://player/player.tscn"
## Majora's Mask timing: a quick fade to black as the player walks out, a slower fade back
## in as they walk in (LoadingScreen steps both at ~20 fps).
const FADE_OUT_TIME := 0.4
const FADE_IN_TIME := 0.6
## Where travel ends up when it doesn't know where to put the player (a missing or unset
## target zone, a failed load). Never reachable on purpose.
const NOWHERE := "res://zones/nowhere/nowhere.tscn"

var zone: Zone
var player: CharacterBody3D
var busy := false
## Ticks (ms) when the player last arrived; ZoneExits ignore the player briefly after.
var arrived_msec := 0
## The zone travelled from and the spawn there that leads back (ZoneExit.here_spawn), for
## exits marked `back` (the nowhere room's way out).
var previous_zone_path := ""
var previous_spawn := &""

var _loading: LoadingScreen
## Zones asked for ahead of travel (preload()), so travel doesn't ask again.
var _requested := {}

const PLAY_HERE := "res://addons/n64_level_tools/play_here.gd"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_loading = LoadingScreen.new()
	add_child(_loading)
	add_child(DebugHud.new())
	await get_tree().process_frame
	_adopt_current_scene(GameState.current_spawn)


func travel(zone_path: String, spawn_id: StringName = &"", return_spawn: StringName = &"") -> void:
	if busy:
		return
	if zone_path.is_empty() or not ResourceLoader.exists(zone_path):
		if zone_path == NOWHERE or not ResourceLoader.exists(NOWHERE):
			push_error("ZoneManager: zone scene not found: %s" % zone_path)
			return
		push_warning("ZoneManager: no zone at \"%s\"; going nowhere." % zone_path)
		zone_path = NOWHERE
		spawn_id = &""
	previous_zone_path = GameState.current_zone_path
	previous_spawn = return_spawn
	busy = true
	GameState.time_running = false
	# Start loading now: it runs while the player walks out and the screen fades.
	preload_zone(zone_path)
	# The player keeps walking the way they were going while it fades (a door has already
	# taken them over and walks them itself).
	var walked := _walk_out()
	await _loading.fade_in(FADE_OUT_TIME)
	if player:
		if walked:
			player.intent.clear()
			player.scripted = false
		player.process_mode = Node.PROCESS_MODE_DISABLED
	GameState.clear_temp_flags()

	var progress := []
	var status := ResourceLoader.load_threaded_get_status(zone_path, progress)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		_loading.set_progress(progress[0])
		await get_tree().process_frame
		status = ResourceLoader.load_threaded_get_status(zone_path, progress)
	if status != ResourceLoader.THREAD_LOAD_LOADED and zone_path != NOWHERE and ResourceLoader.exists(NOWHERE):
		push_warning("ZoneManager: failed to load %s; going nowhere." % zone_path)
		zone_path = NOWHERE
		spawn_id = &""
		preload_zone(zone_path)
		status = ResourceLoader.load_threaded_get_status(zone_path, progress)
		while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await get_tree().process_frame
			status = ResourceLoader.load_threaded_get_status(zone_path, progress)
	if status != ResourceLoader.THREAD_LOAD_LOADED:
		push_error("ZoneManager: failed to load %s" % zone_path)
	else:
		_loading.set_progress(1.0)
		_requested.erase(zone_path)
		get_tree().change_scene_to_packed(ResourceLoader.load_threaded_get(zone_path))
		await get_tree().scene_changed
		_adopt_current_scene(spawn_id)

	await _loading.fade_out(FADE_IN_TIME)
	busy = false


## Starts loading `zone_path` in the background (doors call it as they open, travel as it
## starts), so it's ready, or nearly, by the time the screen is black.
func preload_zone(zone_path: String) -> void:
	if zone_path.is_empty() or not ResourceLoader.exists(zone_path) or _requested.has(zone_path):
		return
	if ResourceLoader.load_threaded_request(zone_path) == OK:
		_requested[zone_path] = true


## Exits: the player carries on the way they were going (at their pace, at least a walk)
## while the screen fades. Returns whether it took them over.
func _walk_out() -> bool:
	if player == null or player.process_mode == Node.PROCESS_MODE_DISABLED or not player is Actor:
		return false
	var a := player as Actor
	if a.scripted or a.is_dead():
		return false
	var dir := Vector3(a.velocity.x, 0.0, a.velocity.z)
	var pace := clampf(dir.length() / 4.0, 0.5, 1.0)
	if dir.length() < 0.3:
		dir = a.facing
	a.scripted = true
	a.intent.clear()
	a.intent.move = dir.normalized() * pace
	return true


func respawn_player() -> void:
	if zone and player:
		_place_player(zone.find_spawn(GameState.current_spawn))


func _adopt_current_scene(spawn_id: StringName) -> void:
	zone = get_tree().current_scene as Zone
	if zone == null:
		if player:
			player.process_mode = Node.PROCESS_MODE_DISABLED
			player.visible = false
		return
	if player == null:
		player = (load(PLAYER_SCENE) as PackedScene).instantiate()
		add_child(player)
	player.visible = true
	player.process_mode = Node.PROCESS_MODE_INHERIT

	# Neutral world tint; a DayNightSun in the zone takes over each frame.
	RenderingServer.global_shader_parameter_set(&"n64_world_tint", Color.WHITE)
	var spawn: Node3D = zone.find_spawn(spawn_id)
	var found := spawn
	# Editor "Play here": start where the designer was looking (editor runs only; the
	# helper lives in the level tools, which never ship).
	if OS.has_feature("editor") and ResourceLoader.exists(PLAY_HERE):
		spawn = load(PLAY_HERE).take_spawn(zone, spawn)
	_place_player(spawn)
	zone.room_changed.connect(func(room): room_changed.emit(room))
	zone.begin(player, spawn)
	if spawn and spawn.has_method(&"play_arrival"):
		spawn.play_arrival(player)

	GameState.current_zone_path = zone.scene_file_path
	GameState.current_spawn = spawn.spawn_id if spawn else &""
	GameState.time_running = zone.time_flows
	zone_changed.emit(zone)
	# The area's intro the first time here (not when the editor's "Play here" put us down).
	if spawn == found:
		zone.play_intro()


func _place_player(spawn: Node3D) -> void:
	var xf: Transform3D = spawn.get_spawn_transform() if spawn else zone.global_transform
	player.teleport(xf)
	arrived_msec = Time.get_ticks_msec()
