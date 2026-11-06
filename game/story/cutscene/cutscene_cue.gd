@tool
class_name CutsceneCue
extends Resource
## One key on a Cutscene's timeline, at `time` seconds. Its `kind` decides its track and
## which settings apply (the inspector shows only those):
##  - SHOT (Camera track): the camera moves from the previous shot to `transform` / `fov`
##    over `duration` (CUT: at once), or uses a CameraZone's View (`camera_id`); `look_at`
##    keeps an actor in frame.
##  - ACTOR (one track per actor: "player" or a character id): walk / run to `position`,
##    teleport, face a direction or another actor, play an animation clip, show or hide.
##  - LINE (Dialogue track): a dialogue entry; `wait` holds the timeline until it closes.
##  - EVENT (Events track): story effects (flags, items, weather), a sprite effect, a
##    sound, music, a screen fade, waiting for a button, or setting the clock.
## Positions are in the zone's space.

enum Kind { SHOT, ACTOR, LINE, EVENT }
enum Move { CUT, LINEAR, SMOOTH }
enum Action { WALK, RUN, TELEPORT, FACE, ANIMATE, SHOW, HIDE }
enum Event { STORY, EFFECT, SOUND, MUSIC, FADE, WAIT_INPUT, SET_TIME }

const PLAYER := &"player"

@export var kind := Kind.SHOT:
	set(value):
		kind = value
		notify_property_list_changed()
		emit_changed()
@export var time := 0.0:
	set(value):
		time = maxf(value, 0.0)
		emit_changed()
## Seconds the cue takes: a shot's move from the previous one, a fade, a walk's time limit.
@export_range(0.0, 30.0, 0.05, "or_greater") var duration := 1.0:
	set(value):
		duration = maxf(value, 0.0)
		emit_changed()

@export_group("Shot")
@export var move := Move.SMOOTH:
	set(value):
		move = value
		emit_changed()
@export var transform := Transform3D(Basis(), Vector3(0, 2, 6)):
	set(value):
		transform = value
		emit_changed()
@export_range(10.0, 120.0, 1.0) var fov := 60.0:
	set(value):
		fov = value
		emit_changed()
## Use this CameraZone's View camera instead (0 = the transform above).
@export_range(0, 255) var camera_id := 0:
	set(value):
		camera_id = value
		emit_changed()
## Turn to keep this actor in frame ("" = keep the shot's angle).
@export var look_at := &"":
	set(value):
		look_at = value
		emit_changed()

@export_group("Actor")
## "player", or a character id (the NPC playing that character in the zone).
@export var actor := PLAYER:
	set(value):
		actor = value
		emit_changed()
@export var action := Action.WALK:
	set(value):
		action = value
		notify_property_list_changed()
		emit_changed()
@export var position := Vector3.ZERO:
	set(value):
		position = value
		emit_changed()
## Degrees, turning the actor to face this way once there (WALK / RUN / TELEPORT / FACE).
@export_range(-180.0, 180.0, 1.0) var facing := 0.0:
	set(value):
		facing = value
		emit_changed()
## FACE: look at this actor instead of `facing` ("" = use facing).
@export var face_actor := &"":
	set(value):
		face_actor = value
		emit_changed()
## ANIMATE: the model's clip ("" = back to its normal animations).
@export var animation := &"":
	set(value):
		animation = value
		emit_changed()
@export var loop := false:
	set(value):
		loop = value
		emit_changed()

@export_group("Line")
@export var dialogue: Dialogue:
	set(value):
		dialogue = value
		emit_changed()
@export var entry := "":
	set(value):
		entry = value
		emit_changed()
## Who's talking (actor id; the player faces them).
@export var speaker := &"":
	set(value):
		speaker = value
		emit_changed()
## Hold the timeline until the box closes.
@export var wait := true:
	set(value):
		wait = value
		emit_changed()

@export_group("Event")
@export var event := Event.STORY:
	set(value):
		event = value
		notify_property_list_changed()
		emit_changed()
@export var effects: Array[StoryEffect] = []
@export var effect: N64Effect:
	set(value):
		effect = value
		emit_changed()
## SOUND: Sfx effect name; MUSIC: song name.
@export var sound := &"":
	set(value):
		sound = value
		emit_changed()
## FADE: the colour to fade to (alpha 0 = fade back in).
@export var color := Color(0, 0, 0, 1):
	set(value):
		color = value
		emit_changed()
@export_range(0.0, 24.0, 0.25) var hour := 12.0:
	set(value):
		hour = value
		emit_changed()
@export_group("")


## The timeline row this cue sits on.
func track() -> StringName:
	match kind:
		Kind.SHOT:
			return &"camera"
		Kind.LINE:
			return &"dialogue"
		Kind.EVENT:
			return &"events"
	return actor


## Short text for the timeline key.
func label() -> String:
	match kind:
		Kind.SHOT:
			return "Zone camera %d" % camera_id if camera_id > 0 else ["Cut", "Move", "Ease"][move]
		Kind.ACTOR:
			match action:
				Action.ANIMATE:
					return String(animation) if animation != &"" else "Normal anims"
				Action.FACE:
					return "Face " + String(face_actor) if face_actor != &"" else "Face %d°" % roundi(facing)
			return Action.keys()[action].capitalize()
		Kind.LINE:
			return entry if entry != "" else (dialogue.resource_path.get_file().get_basename() if dialogue else "Line")
	match event:
		Event.STORY:
			return ", ".join(effects.filter(func(e): return e != null).map(func(e): return e.describe())) if not effects.is_empty() else "Story"
		Event.EFFECT:
			return effect.resource_name if effect and effect.resource_name != "" else "Effect"
		Event.SOUND:
			return "♪ " + String(sound)
		Event.MUSIC:
			return "Music " + String(sound)
		Event.FADE:
			return "Fade in" if color.a < 0.5 else "Fade out"
		Event.WAIT_INPUT:
			return "Wait for button"
	return "Time %s" % StoryCondition._hour_text(hour)


## Seconds the cue spans on the timeline (0 = an instant).
func span() -> float:
	match kind:
		Kind.SHOT:
			return 0.0 if move == Move.CUT or camera_id > 0 else duration
		Kind.EVENT:
			return duration if event == Event.FADE else 0.0
	return 0.0


func _validate_property(property: Dictionary) -> void:
	var groups := {
		Kind.SHOT: ["move", "transform", "fov", "camera_id", "look_at"],
		Kind.ACTOR: ["actor", "action", "position", "facing", "face_actor", "animation", "loop"],
		Kind.LINE: ["dialogue", "entry", "speaker", "wait"],
		Kind.EVENT: ["event", "effects", "effect", "sound", "color", "hour"],
	}
	var name := String(property.name)
	if name == "position" and kind == Kind.EVENT and event in [Event.EFFECT, Event.SOUND]:
		return  # where the effect / sound plays
	for k in groups:
		if name in groups[k] and k != kind:
			property.usage = PROPERTY_USAGE_NO_EDITOR
			return
	if kind == Kind.ACTOR:
		var by_action := {position = [Action.WALK, Action.RUN, Action.TELEPORT], facing = [Action.WALK, Action.RUN, Action.TELEPORT, Action.FACE],
			face_actor = [Action.FACE], animation = [Action.ANIMATE], loop = [Action.ANIMATE]}
		if by_action.has(name) and not action in by_action[name]:
			property.usage = PROPERTY_USAGE_NO_EDITOR
	if kind == Kind.EVENT:
		var by_event := {effects = [Event.STORY], effect = [Event.EFFECT], sound = [Event.SOUND, Event.MUSIC],
			color = [Event.FADE], hour = [Event.SET_TIME]}
		if by_event.has(name) and not event in by_event[name]:
			property.usage = PROPERTY_USAGE_NO_EDITOR
	if name == "duration" and not (kind == Kind.SHOT or (kind == Kind.EVENT and event == Event.FADE) or (kind == Kind.ACTOR and action in [Action.WALK, Action.RUN])):
		property.usage = PROPERTY_USAGE_NO_EDITOR
