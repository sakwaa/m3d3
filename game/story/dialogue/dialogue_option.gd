@tool
class_name DialogueOption
extends Resource
## One answer of a DialogueChoice.

## Unique within its choice; the translation key is "<dialogue id>.<node id>.<id>".
@export var id := ""
@export var text := ""
## Shown only when all of these pass.
@export var conditions: Array[StoryCondition] = []
## Where picking it leads ("" = end).
@export var next := ""
