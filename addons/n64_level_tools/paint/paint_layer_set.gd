@tool
class_name PaintLayerSet
extends Resource
## A named stack of overlay layers (max LevelData.MAX_LAYERS) that faces can use instead of
## the level's default stack (LevelData.layers = set 0). Faces pick their set with
## LevelBrush.face_layer_sets; a face's mask slot i shows its own set's layer i.

signal layers_changed

@export var name := "Set":
	set(value):
		name = value
		emit_changed()
## Overlay layers, bottom to top.
@export var layers: Array[PaintLayer] = []:
	set(value):
		for layer in layers:
			if layer and layer.changed.is_connected(_on_layer_changed):
				layer.changed.disconnect(_on_layer_changed)
		layers = value
		for layer in layers:
			if layer and not layer.changed.is_connected(_on_layer_changed):
				layer.changed.connect(_on_layer_changed)
		layers_changed.emit()


func _on_layer_changed() -> void:
	emit_changed()
