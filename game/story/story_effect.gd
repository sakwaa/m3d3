@tool
class_name StoryEffect
extends Resource
## One change to the game state, shared by dialogue (rewards, quest steps) and NPC
## schedules: set / clear a flag, change a counter, give / take / equip an item, change
## the weather, play a cutscene. Giving an item can announce it with a "You got …!" box.

enum Kind { SET_FLAG, CLEAR_FLAG, SET_COUNTER, ADD_TO_COUNTER, GIVE_ITEM, TAKE_ITEM, EQUIP_ITEM, SET_WEATHER, PLAY_CUTSCENE }

@export var kind := Kind.SET_FLAG:
	set(value):
		kind = value
		notify_property_list_changed()
@export var flag := ""
@export var value := 1
@export var item := &""
@export_range(1, 9999) var count := 1
## GIVE_ITEM: show the item in a "You got …!" box.
@export var announce := true
## The announcement's text ("" = the default "You got {item}!"); markup allowed.
@export_multiline var message := ""
@export var weather := &""
## PLAY_CUTSCENE: starts once the conversation (if any) is over.
@export var cutscene: Cutscene

const DEFAULT_MESSAGE := "You got [yellow]{item}[/yellow]!"


## Applies the effect. Returns an announcement ({text, key, icon}) or {}.
## `key` is the translation key for a custom message.
func apply(gs: Node, key := "") -> Dictionary:
	match kind:
		Kind.SET_FLAG:
			gs.set_flag(flag, true)
		Kind.CLEAR_FLAG:
			gs.clear_flag(flag)
		Kind.SET_COUNTER:
			gs.set_flag(flag, value)
		Kind.ADD_TO_COUNTER:
			gs.set_flag(flag, int(gs.get_flag(flag, 0)) + value)
		Kind.GIVE_ITEM:
			gs.give_item(item, count)
			if announce:
				var def: ItemDef = gs.story.find_item(item) if gs.story else null
				var text := StoryDatabase.localized(key, message) if message != "" else \
					StoryDatabase.localized("ui.got_item", DEFAULT_MESSAGE)
				return {text = text.replace("{item}", "{item:%s}" % item), icon = def.icon if def else null}
		Kind.TAKE_ITEM:
			gs.take_item(item, count)
		Kind.EQUIP_ITEM:
			gs.equip_item(item)
		Kind.SET_WEATHER:
			gs.set_weather(weather)
		Kind.PLAY_CUTSCENE:
			var player := gs.get_node_or_null(^"/root/Cutscenes")
			if player and cutscene:
				player.play(cutscene)
	return {}


func describe() -> String:
	match kind:
		Kind.SET_FLAG:
			return "set %s" % flag
		Kind.CLEAR_FLAG:
			return "clear %s" % flag
		Kind.SET_COUNTER:
			return "%s = %d" % [flag, value]
		Kind.ADD_TO_COUNTER:
			return "%s %+d" % [flag, value]
		Kind.GIVE_ITEM:
			return "give %s%s" % [item, " ×%d" % count if count > 1 else ""]
		Kind.TAKE_ITEM:
			return "take %s%s" % [item, " ×%d" % count if count > 1 else ""]
		Kind.EQUIP_ITEM:
			return "equip %s" % item
		Kind.SET_WEATHER:
			return "weather → %s" % weather
		Kind.PLAY_CUTSCENE:
			return "cutscene %s" % (cutscene.resource_path.get_file().get_basename() if cutscene else "?")
	return ""


func _validate_property(property: Dictionary) -> void:
	var used := {
		Kind.SET_FLAG: ["flag"], Kind.CLEAR_FLAG: ["flag"],
		Kind.SET_COUNTER: ["flag", "value"], Kind.ADD_TO_COUNTER: ["flag", "value"],
		Kind.GIVE_ITEM: ["item", "count", "announce", "message"], Kind.TAKE_ITEM: ["item", "count"],
		Kind.EQUIP_ITEM: ["item"], Kind.SET_WEATHER: ["weather"], Kind.PLAY_CUTSCENE: ["cutscene"],
	}
	if property.name in ["flag", "value", "item", "count", "announce", "message", "weather", "cutscene"] and not property.name in used[kind]:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	elif Engine.is_editor_hint():
		suggest(property)


## Editor pickers: flag / item / weather fields suggest the registered ids.
static func suggest(property: Dictionary) -> void:
	var ids := PackedStringArray()
	match property.name:
		"flag":
			var db := StoryDatabase.load_project()
			ids = db.flag_ids() if db else ids
		"item":
			var db := StoryDatabase.load_project()
			ids = db.item_ids() if db else ids
		"weather":
			var table := WeatherTable.load_project()
			if table:
				for id in table.ids():
					ids.append(String(id))
		_:
			return
	property.hint = PROPERTY_HINT_ENUM_SUGGESTION
	property.hint_string = ",".join(ids)
