@tool
extends EditorInspectorPlugin
## Puts the active actor tool's options at the top of the inspector for an ActorModel.
## The model's own properties (data, reference) follow underneath as usual.

const ActorOptions := preload("res://addons/n64_actor_tools/ui/actor_options.gd")

var editor: RefCounted


func _can_handle(object: Object) -> bool:
	return object is ActorModel


func _parse_begin(object: Object) -> void:
	if editor.model == object:
		add_custom_control(ActorOptions.new(editor))
