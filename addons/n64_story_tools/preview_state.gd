@tool
extends Node
## Stand-in for GameState in editor previews: names come from the story database, the
## player hasn't been named, and the clock, weather, flags and items are whatever the
## editor's what-if controls say (nothing by default).

var story: StoryDatabase
var player_name := ""
var day := 0
var time_of_day := 12.0
var weather := &"sunny"
var flags := {}
var items := {}
var equipped := ""


func get_flag(id: String, default: Variant = null) -> Variant:
	if flags.has(id):
		return flags[id]
	return false if default == null else default


func item_count(id: StringName) -> int:
	return int(items.get(String(id), 0))


func has_item(id: StringName, count := 1) -> bool:
	return item_count(id) >= count


func get_day_of_week() -> int:
	return posmod(day, 5)
