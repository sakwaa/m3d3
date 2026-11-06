@tool
class_name DialogueCase
extends Resource
## One "if" of a DialogueBranch: when all `conditions` pass, go to `next`.

@export var conditions: Array[StoryCondition] = []
@export var next := ""
