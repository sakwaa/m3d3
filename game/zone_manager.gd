extends Node
## Owns the persistent player and zone travel (fade, threaded load, spawn).
## Autoloaded as `ZoneManager`. Any scene whose root is a Zone can be run directly;
## it is adopted on start and the player is placed at its default spawn.

signal zone_changed(zone: Zone)
signal room_changed(room: Room)

const PLAYER_SCENE := "res://player/player.tscn"
const FADE_TIME := 0.25

var zone: Zone
var player: CharacterBody3D
var busy := false
## Ticks (ms) when the player last arrived; ZoneExits ignore the player briefly after.
var arrived_msec := 0

var _loading: LoadingScreen

const PLAY_HERE := "res://addons/n64_level_tools/play_here.gd"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_loading = LoadingScreen.new()
	add_child(_loading)
	add_child(DebugHud.new())
	await get_tree().process_frame
	_adopt_current_scene(GameState.current_spawn)


func travel(zone_path: String, spawn_id: StringName = &"") -> void:
	if busy:
		return
	if not ResourceLoader.exists(zone_path):
		push_error("ZoneManager: zone scene not found: %s" % zone_path)
		return
	busy = true
	GameState.time_running = false
	if player:
		player.process_mode = Node.PROCESS_MODE_DISABLED
	await _loading.fade_in(FADE_TIME)
	GameState.clear_temp_flags()

	ResourceLoader.load_threaded_request(zone_path)
	var progress := []
	var status := ResourceLoader.load_threaded_get_status(zone_path, progress)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		_loading.set_progress(progress[0])
		await get_tree().process_frame
		status = ResourceLoader.load_threaded_get_status(zone_path, progress)
	if status != ResourceLoader.THREAD_LOAD_LOADED:
		push_error("ZoneManager: failed to load %s" % zone_path)
	else:
		_loading.set_progress(1.0)
		get_tree().change_scene_to_packed(ResourceLoader.load_threaded_get(zone_path))
		await get_tree().scene_changed
		_adopt_current_scene(spawn_id)

	await _loading.fade_out(FADE_TIME)
	busy = false


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


func _place_player(spawn: Node3D) -> void:
	var xf: Transform3D = spawn.get_spawn_transform() if spawn else zone.global_transform
	player.teleport(xf)
	arrived_msec = Time.get_ticks_msec()
