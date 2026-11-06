@tool
class_name DialogueAction
extends DialogueNode
## Applies effects in order (set flags, give / take items…), showing any item
## announcements, then goes on to `next`.

@export var effects: Array[StoryEffect] = []
