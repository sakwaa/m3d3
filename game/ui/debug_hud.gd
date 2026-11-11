class_name DebugHud
extends CanvasLayer
## Development overlay: zone, room, clock and flags.
## F3 toggle, hold T to fast-forward time, F2 save slot 0, F4 load slot 0, F6 next weather,
## F7 profiler, F8 actor state labels, F9 collision view (surfaces), F10 wireframe (over
## the game, lines only, off: where the triangles pile up), F11 fullscreen,
## F5 warp to the climb sandbox (zones/debug: never exported).

const FAST_TIME_SCALE := 60.0
## Profiler budgets (rough N64 / OoT-style targets); counts turn yellow past 80 %, red past 100 %.
const BUDGET_TRIANGLES := 6000
const BUDGET_DRAW_CALLS := 150
const BUDGET_FRAME_MS := 1000.0 / 60.0
## Profiler refresh interval (seconds); min / max cover the last second.
const PROFILE_INTERVAL := 0.25

const CLIMB_SANDBOX := "res://zones/debug/climb_sandbox/climb_sandbox.tscn"

var _label: Label
var _profile: RichTextLabel
var _profile_t := 0.0
var _window_t := 0.0
var _worst_frame := 0.0
var _shown_worst := 0.0
var _peak_tris := 0
var _shown_peak_tris := 0
var _collision_view: CollisionView
var _wireframe: WireframeView


func _init() -> void:
	layer = 90
	_label = Label.new()
	_label.position = Vector2(12, 8)
	_label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_label.add_theme_constant_override(&"outline_size", 4)
	add_child(_label)
	_profile = RichTextLabel.new()
	_profile.bbcode_enabled = true
	_profile.fit_content = true
	_profile.scroll_active = false
	_profile.autowrap_mode = TextServer.AUTOWRAP_OFF
	_profile.custom_minimum_size = Vector2(380, 0)
	_profile.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_profile.position = Vector2(-392, 8)
	_profile.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_profile.add_theme_constant_override(&"outline_size", 4)
	_profile.visible = false
	add_child(_profile)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_F3:
			visible = not visible
		KEY_F2:
			print("[GameState] save: ", error_string(GameState.save_game(0)))
		KEY_F4:
			print("[GameState] load: ", error_string(GameState.load_game(0)))
		KEY_F8:
			Actor.show_debug = not Actor.show_debug
		KEY_F7:
			_profile.visible = not _profile.visible
			if _profile.visible:
				visible = true
		KEY_F9:
			if _collision_view:
				_collision_view.queue_free()
				_collision_view = null
			else:
				_collision_view = CollisionView.new()
				get_tree().root.add_child(_collision_view)
				visible = true
		KEY_F10:
			if _wireframe == null:
				_wireframe = WireframeView.new()
				get_tree().root.add_child(_wireframe)
			elif _wireframe.mode == WireframeView.Mode.OVERLAY:
				_wireframe.mode = WireframeView.Mode.LINES
			else:
				_wireframe.queue_free()
				_wireframe = null
		KEY_F5:
			if OS.is_debug_build() and ResourceLoader.exists(CLIMB_SANDBOX):
				ZoneManager.travel(CLIMB_SANDBOX)
		KEY_F11:
			var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)
		KEY_F6:
			if GameState.weather_table:
				var ids := GameState.weather_table.ids()
				if not ids.is_empty():
					GameState.set_weather(ids[(ids.find(GameState.weather) + 1) % ids.size()])


func _process(delta: float) -> void:
	GameState.time_scale = FAST_TIME_SCALE if Input.is_physical_key_pressed(KEY_T) else 1.0
	if not visible:
		return
	if _profile.visible:
		_update_profile(delta)
	var zone: Zone = ZoneManager.zone
	var lines := [
		"Zone: %s" % (zone.display_name if zone else "—"),
		"Room: %s" % (zone.current_room.room_id if zone and zone.current_room else "—"),
		"%s%s" % [GameState.clock_text(), " (held)" if GameState.is_clock_held() else "" if GameState.time_running else " (paused)"],
		"Weather: %s%s" % [GameState.weather, "" if GameState.weather_blend >= 1.0 else " (from %s)" % GameState.weather_from],
		"Flags: %s" % (", ".join(GameState.flags.keys()) if not GameState.flags.is_empty() else "none"),
		"Items: %s" % (", ".join(GameState.items.keys().map(func(id): return "%s x%d" % [id, GameState.items[id]])) if not GameState.items.is_empty() else "none"),
		"[F3] hud  [T] fast time  [F2] save  [F4] load  [F6] weather  [F7] profiler  [F9] collision  [F10] wireframe  [F11] fullscreen",
	]
	if _collision_view:
		var player := get_tree().get_first_node_in_group(&"player") as Actor
		if player:
			lines.insert(lines.size() - 1, "Ground: %s" % (Surface.describe(player.floor_surface) if player.is_on_floor() else "(in the air)"))
	if zone:
		var states := []
		for room in zone.rooms:
			states.append("%s=%s" % [room.room_id, Room.State.keys()[room.state].to_lower()])
		lines.insert(2, "Rooms: " + ", ".join(states))
	_label.text = "\n".join(lines)


# --- Profiler -----------------------------------------------------------------------

func _update_profile(delta: float) -> void:
	# Track the worst frame / most triangles over a one-second window.
	_worst_frame = maxf(_worst_frame, delta * 1000.0)
	var tris := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_peak_tris = maxi(_peak_tris, tris)
	_window_t += delta
	if _window_t >= 1.0:
		_window_t = 0.0
		_shown_worst = _worst_frame
		_shown_peak_tris = _peak_tris
		_worst_frame = 0.0
		_peak_tris = 0
	_profile_t += delta
	if _profile_t < PROFILE_INTERVAL:
		return
	_profile_t = 0.0
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var frame_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var objects := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var vram := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var tex_mem := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
	var buf_mem := Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0
	var ram := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var bodies := int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	var pairs := int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
	var lines := [
		"[b]Profiler[/b]  [F7]",
		"FPS %s   frame %s ms (worst %s)" % [_rate(fps, 60.0), "%.1f" % (1000.0 / maxf(fps, 1.0)),
			_budget(_shown_worst, BUDGET_FRAME_MS, "%.1f")],
		"CPU process %.1f ms   physics %.1f ms" % [frame_ms, physics_ms],
		"Triangles %s / %s   (peak %s)" % [_budget(tris, BUDGET_TRIANGLES, "%d"), _k(BUDGET_TRIANGLES),
			_budget(_shown_peak_tris, BUDGET_TRIANGLES, "%d")],
		"Draw calls %s / %d   objects %d" % [_budget(draws, BUDGET_DRAW_CALLS, "%d"), BUDGET_DRAW_CALLS, objects],
		"VRAM %.0f MB  (textures %.1f, buffers %.1f)" % [vram, tex_mem, buf_mem],
		"RAM %.0f MB   nodes %d" % [ram, nodes],
		"Physics: %d active bodies, %d pairs" % [bodies, pairs],
	]
	_profile.text = "\n".join(lines)


## Value coloured against a budget: white, yellow past 80 %, red past 100 %.
func _budget(value: float, budget: float, fmt: String) -> String:
	var color := "#ffffff"
	if value > budget:
		color = "#ff6060"
	elif value > budget * 0.8:
		color = "#ffd24a"
	return "[color=%s]%s[/color]" % [color, fmt % value]


## FPS coloured: green at target, yellow below 90 %, red below 50 %.
func _rate(fps: float, target: float) -> String:
	var color := "#8cff8c"
	if fps < target * 0.5:
		color = "#ff6060"
	elif fps < target * 0.9:
		color = "#ffd24a"
	return "[color=%s]%d[/color]" % [color, roundi(fps)]


func _k(n: int) -> String:
	return "%.1fk" % (n / 1000.0) if n >= 1000 else str(n)
