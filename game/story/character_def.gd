@tool
class_name CharacterDef
extends Resource
## Someone who speaks: an NPC (or a group of identical ones, like the collectors), the
## player, an object's voice. Dialogue refers to characters by id, so renaming one
## changes every line that names them.

## Animal Crossing style voice: SOFT is round and breathy, BRIGHT a clear reed, BUZZY a
## nasal buzz.
enum Timbre { SOFT, BRIGHT, BUZZY }

## "baker", "collector", "player"...
@export var id := &"":
	set(value):
		id = StringName(String(value).strip_edges())
		emit_changed()
## English name; translations use the key "char.<id>.name".
@export var display_name := ""
## Name tag colour in the text box.
@export var name_color := Color(0.95, 0.55, 0.3)

@export_group("Body")
## Model scene (built with the actor tools); none = a coloured stand-in.
@export var model: PackedScene
## Walking speed along schedule paths (they run when they've fallen behind).
@export_range(0.5, 4.0, 0.05, "suffix:m/s") var walk_speed := 1.4
@export_group("Voice")
## No blips (narration-like characters, the player).
@export var silent := false
## Base pitch of the voice, in Hz.
@export_range(60.0, 800.0, 1.0, "suffix:Hz") var voice_pitch := 220.0
## How far each syllable wanders from the base pitch, in semitones.
@export_range(0.0, 12.0, 0.5) var voice_range := 4.0
@export var voice_timbre := Timbre.SOFT
## Typing speed (1 = normal; blips follow the letters).
@export_range(0.25, 4.0, 0.05) var talk_speed := 1.0
@export_range(-24.0, 6.0, 0.5, "suffix:dB") var voice_volume := -6.0
@export_group("")

## Editor only (stripped from exports).
@export_multiline var notes := ""


func get_display_name() -> String:
	return StoryDatabase.localized("char.%s.name" % id, display_name if display_name != "" else String(id).capitalize())
