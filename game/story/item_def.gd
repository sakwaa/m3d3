@tool
class_name ItemDef
extends Resource
## An inventory item. GameState keeps a count per item id (1 for unique and trade items).

##  UNIQUE: one of it (key items, equipment).
##  COUNTED: a stack up to `max_count` (arrows, bombs).
##  CURRENCY: like COUNTED, shown as money.
##  TRADE: one at a time and handed over in trade sequences.
enum Kind { UNIQUE, COUNTED, CURRENCY, TRADE }

@export var id := &"":
	set(value):
		id = StringName(String(value).strip_edges())
		emit_changed()
## English name; translations use the key "item.<id>.name".
@export var display_name := ""
## English description; translations use the key "item.<id>.desc".
@export_multiline var description := ""
@export var icon: Texture2D
@export var kind := Kind.UNIQUE:
	set(value):
		kind = value
		notify_property_list_changed()
@export_range(1, 9999) var max_count := 99
## Can be held as the equipped item (dialogue can check it).
@export var equippable := false
## When the player loses it again (same rules as FlagDef.reset).
@export var reset := FlagDef.Reset.NEVER:
	set(value):
		reset = value
		notify_property_list_changed()
@export var reset_flag := ""
## Editor only (stripped from exports).
@export_multiline var notes := ""


func get_display_name() -> String:
	return StoryDatabase.localized("item.%s.name" % id, display_name if display_name != "" else String(id))


func get_description() -> String:
	return StoryDatabase.localized("item.%s.desc" % id, description)


## Most the player can carry.
func capacity() -> int:
	return max_count if kind == Kind.COUNTED or kind == Kind.CURRENCY else 1


func _validate_property(property: Dictionary) -> void:
	if property.name == "max_count" and kind != Kind.COUNTED and kind != Kind.CURRENCY:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	elif property.name == "reset_flag":
		if reset != FlagDef.Reset.ON_FLAG:
			property.usage = PROPERTY_USAGE_NO_EDITOR
		elif Engine.is_editor_hint():
			var db := StoryDatabase.load_project()
			if db:
				property.hint = PROPERTY_HINT_ENUM_SUGGESTION
				property.hint_string = ",".join(db.flag_ids())
