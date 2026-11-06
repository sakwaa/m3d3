@tool
class_name Fence
extends Node3D
## A fence made by the level tools' Fence button from a line of selected vertices: its
## posts, rails, rope ties and collision are level brushes (tagged `tag`, so they bake,
## light and paint like the rest of the level). This node keeps the path and style:
## changing them (or the style resource) regenerates the geometry in the editor.

## Points in order, relative to this node (moving the node moves the fence). Each pair of
## neighbours is a section: any direction, its own slope.
@export var points := PackedVector3Array():
	set(v):
		points = v
		_request_rebuild()
## The last point connects back to the first.
@export var closed := false:
	set(v):
		closed = v
		_request_rebuild()
## Spans left open (index i = between post i and i + 1 of the path).
@export var open_spans := PackedInt32Array():
	set(v):
		open_spans = v
		_request_rebuild()
@export var style: FenceStyle:
	set(v):
		if style and style.changed.is_connected(_request_rebuild):
			style.changed.disconnect(_request_rebuild)
		style = v
		if style and Engine.is_editor_hint():
			style.changed.connect(_request_rebuild)
		_request_rebuild()
## The LevelRoot holding the generated brushes.
@export var level: Node3D
@export_storage var tag: StringName

var _queued := false


func _ready() -> void:
	# Moving the node moves the fence: its points are relative to it.
	set_notify_transform(Engine.is_editor_hint())


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_request_rebuild()


func _request_rebuild() -> void:
	# The level tools (editor only) regenerate the brushes; nothing happens in game.
	if not Engine.is_editor_hint() or _queued or not is_inside_tree():
		return
	_queued = true
	_rebuild.call_deferred()


func _rebuild() -> void:
	_queued = false
	if Engine.has_meta(&"n64_fence_rebuild"):
		(Engine.get_meta(&"n64_fence_rebuild") as Callable).call(self)
