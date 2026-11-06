@tool
class_name ScheduleEntry
extends Resource
## One part of an NPC's week: on `days`, from `from_hour` to `to_hour` (wrapping past
## midnight), when all `conditions` pass, the NPC is in `zone` doing `activity`. An
## NpcSchedule tries its parts in order and the first that passes wins (if / else if /
## else), so put special cases (rain, a quest step) above the usual routine.

##  STAY: at the NpcSpot `place` (facing its arrow), playing `animation`.
##  WALK: along the NpcPath `place`, starting at `from_hour` at the character's walking
##        speed; on arrival they wait at the end (or vanish, `vanish_at_end`: into a door).
##  AWAY: nowhere to be seen.
enum Activity { STAY, WALK, AWAY }

## What they're doing, in a few words (timeline, notebook): "Sweeps the square".
@export var label := ""
@export_flags("Day 1", "Day 2", "Day 3", "Day 4", "Day 5") var days := 31
@export_range(0.0, 24.0, 0.25) var from_hour := 8.0
@export_range(0.0, 24.0, 0.25) var to_hour := 12.0
@export var conditions: Array[StoryCondition] = []
@export var activity := Activity.STAY:
	set(value):
		activity = value
		notify_property_list_changed()
@export_file("*.tscn") var zone := "":
	set(value):
		zone = value
		notify_property_list_changed()
## NpcSpot id (STAY) or NpcPath id (WALK) in `zone`.
@export var place := &""
## WALK: from the path's last point to its first.
@export var reverse := false
## WALK: gone once the path is walked (through a door, out of the zone).
@export var vanish_at_end := false
## STAY: animation to play instead of idling ("Sit", "Sweep"), if the model has it.
@export var animation := &""
## Talking to them during this part ("" entry = the dialogue's start); none = the
## schedule's dialogue.
@export var dialogue: Dialogue
@export var dialogue_entry := ""
## Applied once each time this part starts (also off-screen): e.g. set "baker/missed"
## when the 6pm meeting part begins without the player.
@export var effects: Array[StoryEffect] = []


## Whether the time window covers `hour` on absolute day `day` (the part of a window past
## midnight belongs to the day it started on).
func covers(day: int, hour: float) -> bool:
	var today := 1 << posmod(day, 5)
	var yesterday := 1 << posmod(day - 1, 5)
	if from_hour < to_hour:
		return days & today != 0 and hour >= from_hour and hour < to_hour
	if from_hour == to_hour:
		return days & today != 0  # all day
	return (days & today != 0 and hour >= from_hour) or (days & yesterday != 0 and hour < to_hour)


func passes(gs: Node) -> bool:
	return covers(gs.day, gs.time_of_day) and StoryCondition.all(conditions, gs)


## Game hours since this part started (at `hour`).
func elapsed(hour: float) -> float:
	return fposmod(hour - from_hour, 24.0)


func duration() -> float:
	return 24.0 if from_hour == to_hour else fposmod(to_hour - from_hour, 24.0)


func describe() -> String:
	var what: String = ["at %s", "walks %s", "away"][activity]
	if activity != Activity.AWAY:
		what = what % (place if place != &"" else "?")
	return "%s–%s %s" % [StoryCondition._hour_text(from_hour), StoryCondition._hour_text(to_hour), label if label != "" else what]


func _validate_property(property: Dictionary) -> void:
	var walk_only := ["reverse", "vanish_at_end"]
	if property.name in walk_only and activity != Activity.WALK:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	elif property.name == "animation" and activity != Activity.STAY:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	elif property.name in ["zone", "place", "dialogue", "dialogue_entry"] and activity == Activity.AWAY:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	elif property.name == "place" and Engine.is_editor_hint() and zone != "":
		var places := places_in(zone)
		property.hint = PROPERTY_HINT_ENUM_SUGGESTION
		property.hint_string = ",".join(places.paths.keys() if activity == Activity.WALK else places.spots.keys())


static var _places_cache := {}


## The NpcPaths (id -> length in metres) and NpcSpots (id -> true) saved in a zone scene
## (editor; cached until the scene file changes).
static func places_in(zone_path: String) -> Dictionary:
	var stamp := FileAccess.get_modified_time(zone_path) if FileAccess.file_exists(zone_path) else 0
	var cached: Dictionary = _places_cache.get(zone_path, {})
	if not cached.is_empty() and cached.stamp == stamp:
		return cached
	var out := {stamp = stamp, paths = {}, spots = {}}
	var scene := load(zone_path) as PackedScene if stamp != 0 else null
	if scene:
		var root := scene.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
		for n in root.find_children("*", "", true, false):
			if n is NpcPath:
				var id: StringName = n.path_id if n.path_id != &"" else StringName(String(n.name).to_snake_case())
				out.paths[id] = n.length()
			elif n is NpcSpot:
				out.spots[n.spot_id if n.spot_id != &"" else StringName(String(n.name).to_snake_case())] = true
		root.free()
	_places_cache[zone_path] = out
	return out
