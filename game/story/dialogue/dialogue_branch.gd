@tool
class_name DialogueBranch
extends DialogueNode
## if / else if / else: the first case whose conditions pass picks the way on; when none
## does, `next` (the else).

@export var cases: Array[DialogueCase] = []
