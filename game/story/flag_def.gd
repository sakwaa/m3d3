@tool
class_name FlagDef
extends Resource
## A registered GameState flag: its kind and when it resets. Flags that aren't registered
## still work (switches that never reset); registering one gives editors a picker entry
## and lets it reset with the calendar or with another flag.

## When the flag (or item, see ItemDef.reset) goes back to unset.
##  NEVER: story progress (key items, finished quests).
##  ZONE_EXIT: cleared whenever the player leaves the zone (room puzzles, switches).
##  DAY_END / WEEK_END: at midnight / when day 5 rolls over to day 1.
##  ON_FLAG: when `reset_flag` gets set (a quest's fail condition, e.g. "missed the 6pm
##  meeting" sends an A > B > C sequence back to A).
enum Reset { NEVER, ZONE_EXIT, DAY_END, WEEK_END, ON_FLAG }
## SWITCH: true / unset. COUNTER: a number (unset = 0).
enum Kind { SWITCH, COUNTER }

## "scope/name", e.g. "baker/met" or "temple/vault_gem".
@export var id := "":
	set(value):
		id = value.strip_edges()
		emit_changed()
@export var kind := Kind.SWITCH
@export var reset := Reset.NEVER:
	set(value):
		reset = value
		notify_property_list_changed()
## ON_FLAG: the flag whose setting resets this one.
@export var reset_flag := ""
## Editor only (stripped from exports).
@export_multiline var notes := ""


func scope() -> String:
	var slash := id.find("/")
	return id.substr(0, slash) if slash > 0 else ""


func _validate_property(property: Dictionary) -> void:
	if property.name == "reset_flag":
		if reset != Reset.ON_FLAG:
			property.usage = PROPERTY_USAGE_NO_EDITOR
		elif Engine.is_editor_hint():
			var db := StoryDatabase.load_project()
			if db:
				property.hint = PROPERTY_HINT_ENUM_SUGGESTION
				var ids := db.flag_ids()
				if ids.has(id):
					ids.remove_at(ids.find(id))
				property.hint_string = ",".join(ids)
