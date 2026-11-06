extends Node
## Global game state that persists across zones: clock, calendar, flags, inventory and
## save data. Autoloaded as `GameState`.
## The calendar is a 5-day week that only moves forward (`day` counts days since the
## start; weekday = day % WEEK_DAYS). Registered flags and items (StoryDatabase) reset at
## the end of the day / week, on leaving the zone or when another flag gets set.

signal flag_changed(id: String, value: Variant)
signal hour_changed(hour: int)
signal day_changed(day: int)
signal weather_changed(id: StringName)
signal item_changed(id: StringName, count: int)
signal equipped_changed(id: StringName)

const SAVE_PATH := "user://save_%d.json"
const SAVE_VERSION := 1
const WEEK_DAYS := 5

## Real seconds per in-game hour (Majora's Mask is roughly 45).
var seconds_per_game_hour := 45.0
var time_scale := 1.0
## Zones switch this off (dungeons, interiors); zone transitions pause it too.
var time_running := true
## Holders keeping the clock stopped (hold_clock), e.g. an open conversation.
var _clock_holds := {}
## Hours since midnight, 0.0 – 24.0.
var time_of_day := 6.0
## Days elapsed since the start of the game.
var day := 0

## Persistent flags (saved). Keys are "scope/name" strings, e.g. "temple/vault_gem".
var flags := {}
## Flags cleared whenever the player leaves a zone (room puzzles, switches).
var temp_flags := {}

## Inventory: item id (String) -> count. `equipped` is an item id or "".
var items := {}
var equipped := ""
## The name the player chose ("" = the "player" character's name).
var player_name := ""

## Items and registered flags (Project Settings > n64/story/database).
var story: StoryDatabase

var current_zone_path := ""
var current_spawn := &""

## Project-wide time-of-day lighting keys (Project Settings > n64/lighting/schedule).
var lighting_schedule: LightingSchedule

## Weather presets (Project Settings > n64/weather/table) and the current weather.
var weather_table: WeatherTable
var weather := &"sunny"
## Weather being transitioned away from, and progress towards `weather` (1 = done).
var weather_from := &"sunny"
var weather_blend := 1.0
var _weather_seconds := 1.0
## Current sky / fog / light values (WeatherTable.sample, blended across a transition).
var weather_now := {}


func _ready() -> void:
	lighting_schedule = LightingSchedule.load_project()
	weather_table = WeatherTable.load_project()
	story = StoryDatabase.load_project()
	_update_weather(0.0)


func _process(delta: float) -> void:
	if time_running and _clock_holds.is_empty():
		advance_time(delta * time_scale / seconds_per_game_hour)
	# Which two baked lighting keys bracket the current hour, and the blend between them.
	if lighting_schedule:
		var b := lighting_schedule.blend_for(time_of_day)
		RenderingServer.global_shader_parameter_set(&"n64_light_blend", Vector4(b.x, b.y, b.z, 0.0))
	_update_weather(delta)
	# Animated textures' clock (scroll / flipbook), wrapped like the shaders' TIME.
	RenderingServer.global_shader_parameter_set(&"n64_time", fmod(Time.get_ticks_msec() * 0.001, 3600.0))


# --- Clock --------------------------------------------------------------------------

func advance_time(hours: float) -> void:
	var previous_hour := get_hour()
	time_of_day += hours
	while time_of_day >= 24.0:
		time_of_day -= 24.0
		day += 1
		_on_new_day()
		day_changed.emit(day)
	if get_hour() != previous_hour:
		hour_changed.emit(get_hour())


func set_time(hour: float, new_day := -1) -> void:
	time_of_day = fposmod(hour, 24.0)
	if new_day >= 0 and new_day != day:
		var forward := new_day > day
		var new_week := floori(new_day / float(WEEK_DAYS)) != get_week()
		day = new_day
		if forward:
			_reset(FlagDef.Reset.DAY_END)
			if new_week:
				_reset(FlagDef.Reset.WEEK_END)
		day_changed.emit(day)
	hour_changed.emit(get_hour())


func get_hour() -> int:
	return int(time_of_day)


func get_minute() -> int:
	return int(fmod(time_of_day, 1.0) * 60.0)


## 0 – 4.
func get_day_of_week() -> int:
	return day % WEEK_DAYS


## Weeks since the start of the game.
func get_week() -> int:
	return floori(day / float(WEEK_DAYS))


func get_day_name() -> String:
	return "Day %d" % (get_day_of_week() + 1)


func is_night() -> bool:
	return time_of_day < 6.0 or time_of_day >= 18.0


func clock_text() -> String:
	return "Week %d, %s %02d:%02d" % [get_week() + 1, get_day_name(), get_hour(), get_minute()]


## Stops the clock until every holder has released it (conversations, cutscenes).
func hold_clock(holder: Object) -> void:
	_clock_holds[holder.get_instance_id()] = true


func release_clock(holder: Object) -> void:
	_clock_holds.erase(holder.get_instance_id())


func is_clock_held() -> bool:
	return not _clock_holds.is_empty()


func _on_new_day() -> void:
	_reset(FlagDef.Reset.DAY_END)
	if get_day_of_week() == 0:
		_reset(FlagDef.Reset.WEEK_END)


# --- Weather ------------------------------------------------------------------------

## Changes the weather, blending over `seconds` (0 = instantly).
func set_weather(id: StringName, seconds := 6.0) -> void:
	if id == weather and weather_blend >= 1.0:
		return
	weather_from = weather if weather_blend >= 0.5 else weather_from
	weather = id
	weather_blend = 0.0 if seconds > 0.0 else 1.0
	_weather_seconds = maxf(seconds, 0.001)
	_update_weather(0.0)
	weather_changed.emit(id)


func get_weather_preset() -> WeatherPreset:
	return weather_table.find(weather) if weather_table else null


func _update_weather(delta: float) -> void:
	if weather_table == null or weather_table.presets.is_empty():
		return
	weather_blend = minf(weather_blend + delta / _weather_seconds, 1.0)
	var to := WeatherTable.sample(weather_table.find(weather), lighting_schedule, time_of_day)
	if weather_blend >= 1.0:
		weather_now = to
	else:
		var from := WeatherTable.sample(weather_table.find(weather_from), lighting_schedule, time_of_day)
		weather_now = WeatherTable.mix(from, to, smoothstep(0.0, 1.0, weather_blend))


# --- Flags --------------------------------------------------------------------------

## Unset flags read as `default` (registered counters: 0).
func get_flag(id: String, default: Variant = null) -> Variant:
	if temp_flags.has(id):
		return temp_flags[id]
	if flags.has(id):
		return flags[id]
	if default == null:
		var def := story.find_flag(id) if story else null
		return 0 if def and def.kind == FlagDef.Kind.COUNTER else false
	return default


## `temporary` (or a registered ZONE_EXIT flag) is cleared when the player leaves the zone.
func set_flag(id: String, value: Variant = true, temporary := false) -> void:
	var def := story.find_flag(id) if story else null
	if def and def.reset == FlagDef.Reset.ZONE_EXIT:
		temporary = true
	var store := temp_flags if temporary else flags
	if store.has(id) and store[id] == value:
		return
	store[id] = value
	flag_changed.emit(id, value)
	if value:
		_reset(FlagDef.Reset.ON_FLAG, id)


func clear_flag(id: String) -> void:
	if flags.erase(id) or temp_flags.erase(id):
		flag_changed.emit(id, null)


func clear_temp_flags() -> void:
	temp_flags.clear()
	_reset(FlagDef.Reset.ZONE_EXIT)


## Unsets the registered flags and takes away the items that reset on `rule`.
func _reset(rule: FlagDef.Reset, trigger := "") -> void:
	if story == null:
		return
	var due := story.resetting(rule, trigger)
	for id in due.flags:
		if id != trigger:
			clear_flag(id)
	for id in due.items:
		take_item(StringName(id), item_count(StringName(id)))


# --- Inventory ----------------------------------------------------------------------

func item_count(id: StringName) -> int:
	return int(items.get(String(id), 0))


func has_item(id: StringName, count := 1) -> bool:
	return item_count(id) >= count


## Adds `count` (clamped to the item's capacity); returns the new count.
func give_item(id: StringName, count := 1) -> int:
	var def := story.find_item(id) if story else null
	if def == null:
		push_warning("GameState: item '%s' isn't in the story database." % id)
	var cap := def.capacity() if def else 9999
	var n := clampi(item_count(id) + count, 0, cap)
	_set_count(id, n)
	return n


## Removes `count`; false (and nothing removed) if the player has fewer.
func take_item(id: StringName, count := 1) -> bool:
	var have := item_count(id)
	if have < count:
		return false
	if count > 0:
		_set_count(id, have - count)
	return true


func equip_item(id: StringName) -> void:
	if String(id) == equipped:
		return
	equipped = String(id)
	equipped_changed.emit(id)


func _set_count(id: StringName, n: int) -> void:
	if n == item_count(id):
		return
	if n > 0:
		items[String(id)] = n
	else:
		items.erase(String(id))
		if equipped == String(id):
			equip_item(&"")
	item_changed.emit(id, n)


# --- Save / load --------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		version = SAVE_VERSION,
		time_of_day = time_of_day,
		day = day,
		flags = flags.duplicate(true),
		items = items.duplicate(),
		equipped = equipped,
		player_name = player_name,
		weather = String(weather),
		zone = current_zone_path,
		spawn = String(current_spawn),
	}


func from_dict(data: Dictionary) -> void:
	time_of_day = float(data.get("time_of_day", 6.0))
	day = int(data.get("day", 0))
	flags = data.get("flags", {}).duplicate(true)
	# JSON reads numbers back as floats.
	for id in flags:
		if flags[id] is float and flags[id] == floorf(flags[id]):
			flags[id] = int(flags[id])
	items.clear()
	var saved_items: Dictionary = data.get("items", {})
	for id in saved_items:
		items[id] = int(saved_items[id])
	equipped = data.get("equipped", "")
	player_name = data.get("player_name", "")
	weather = StringName(data.get("weather", "sunny"))
	weather_from = weather
	weather_blend = 1.0
	temp_flags.clear()
	current_zone_path = data.get("zone", "")
	current_spawn = StringName(data.get("spawn", ""))


func has_save(slot := 0) -> bool:
	return FileAccess.file_exists(SAVE_PATH % slot)


## Values must be JSON-friendly (bool, number, string, array, dictionary).
func save_game(slot := 0) -> Error:
	var file := FileAccess.open(SAVE_PATH % slot, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(to_dict(), "\t"))
	return OK


## Restores state and travels to the saved zone/spawn.
func load_game(slot := 0) -> Error:
	if not has_save(slot):
		return ERR_FILE_NOT_FOUND
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH % slot))
	if not parsed is Dictionary:
		return ERR_PARSE_ERROR
	from_dict(parsed)
	if not current_zone_path.is_empty():
		ZoneManager.travel(current_zone_path, current_spawn)
	return OK
