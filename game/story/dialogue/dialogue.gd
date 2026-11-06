@tool
class_name Dialogue
extends Resource
## A conversation graph (res://story/dialogue/*.tres): nodes linked by id, starting at
## `start`. Translation keys are "<id>.<node id>", so ids should stay put once a dialogue
## is translated.

## Unique across the game ("baker", "postbox_day1").
@export var id := &""
@export var start := ""
@export var nodes: Array[DialogueNode] = []
## Editor only (stripped from exports).
@export_multiline var notes := ""
## Where the Start marker sits in the dialogue editor's graph.
@export_storage var start_position := Vector2(-280, 0)

var _index := {}


func find(node_id: String) -> DialogueNode:
	if _index.size() != nodes.size() or Engine.is_editor_hint():
		_index.clear()
		for n in nodes:
			if n:
				_index[n.id] = n
	return _index.get(node_id)


func line_key(node: DialogueNode, option: DialogueOption = null) -> String:
	return "%s.%s%s" % [id, node.id, ("." + option.id) if option else ""]


## A node id not used yet ("n1", "n2"…).
func free_id(prefix := "n") -> String:
	var n := 1
	while find("%s%d" % [prefix, n]):
		n += 1
	return "%s%d" % [prefix, n]
