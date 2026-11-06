@tool
class_name NpcSchedule
extends Resource
## One NPC's week (res://story/schedules/*.tres, listed in the story database): the
## character they are, and their parts in priority order (the first part that passes
## right now is what they're doing; none = they're nowhere). Identical-looking NPCs
## (the collectors) each get their own schedule with the same character.

## This NPC ("baker", "collector_2").
@export var id := &""
## Their CharacterDef (name, model, voice, walking speed).
@export var character := &"":
	set(value):
		character = value
		emit_changed()
## Talking to them when the current part has no dialogue of its own.
@export var dialogue: Dialogue
@export var entries: Array[ScheduleEntry] = []
## Editor only (stripped from exports).
@export_multiline var notes := ""


## The part in effect for `gs` (time, day, weather, flags, items), or null.
func current(gs: Node) -> ScheduleEntry:
	for e in entries:
		if e and e.passes(gs):
			return e
	return null


func _validate_property(property: Dictionary) -> void:
	if property.name == "character" and Engine.is_editor_hint():
		var db := StoryDatabase.load_project()
		if db:
			property.hint = PROPERTY_HINT_ENUM_SUGGESTION
			property.hint_string = ",".join(db.character_ids())
