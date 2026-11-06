@tool
class_name DialogueJump
extends DialogueNode
## Continues in another dialogue (shared lines, a character's common replies).
## `next` is unused.

@export var dialogue: Dialogue
## Node to start at ("" = that dialogue's start).
@export var entry := ""
