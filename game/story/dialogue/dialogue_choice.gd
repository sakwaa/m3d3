@tool
class_name DialogueChoice
extends DialogueNode
## The player picks one of `options` (2–4 shown; hidden ones fail their conditions).
## The question is the line before it, which stays on screen. `next` is unused.

@export var options: Array[DialogueOption] = []
## The option B / cancel picks (-1 = can't cancel).
@export var cancel_option := -1
