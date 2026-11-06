@tool
class_name DialogueLine
extends DialogueNode
## A text box. Text markup (DialogueText): a blank line starts a new page;
## [red]…[/red] (also blue, green, yellow, orange, purple, grey) colours words;
## [p] or [p=0.8] pauses; [speed=0.5]…[/speed] types slower / faster;
## {player}, {char:baker}, {item:key} insert names by reference.

##  BOX: the normal text box (name tag when there's a speaker).
##  NARRATION: white text centred on a black screen (dreams, inner voice).
enum Style { BOX, NARRATION }

## Character id; "" = no one (signs, the narrator).
@export var speaker := &""
## Hide the speaker's name tag (a voice heard from somewhere unseen). Still uses their
## voice and colour.
@export var hide_name := false
@export var style := Style.BOX
## English text; translations use the key "<dialogue id>.<node id>".
@export_multiline var text := ""


func _validate_property(property: Dictionary) -> void:
	if property.name == "speaker" and Engine.is_editor_hint():
		var db := StoryDatabase.load_project()
		if db:
			property.hint = PROPERTY_HINT_ENUM_SUGGESTION
			property.hint_string = ",".join(db.character_ids())
