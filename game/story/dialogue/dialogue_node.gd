@tool
class_name DialogueNode
extends Resource
## One step of a Dialogue. Subclasses: DialogueLine (a text box), DialogueChoice (the
## player picks), DialogueBranch (if / else-if / else on conditions), DialogueAction
## (effects: flags, items), DialogueJump (into another dialogue). Nodes link by `id`.

## Unique within its dialogue; also the stem of its translation keys, so it shouldn't
## change once lines are translated.
@export var id := ""
## The node after this one ("" = the conversation ends).
@export var next := ""
## Where the node sits in the dialogue editor's graph.
@export_storage var graph_position := Vector2.ZERO
