class_name LensOfTruth
extends Node
## The Lens of Truth (Ocarina of Time): while it's on, a circle in the middle of the screen
## shows what's hidden and removes what's false. Mark things with `mark(node, mode)`: HIDDEN
## (only seen through the lens: secret platforms, ghosts) or FALSE (gone through it: fake
## walls). Marked meshes use n64_actor / n64_textured materials (lens uniforms, dithered).
## `LensOfTruth.set_on(tree, true)`; the circle grows in / shrinks out over GROW seconds.

enum Mode { NONE, HIDDEN, FALSE }
const GROUP := &"lens_objects"
const GROW := 0.25

## Share of the screen height the circle's radius covers.
var radius := 0.32
var _on := false
var _k := 0.0


## Marks every mesh under `node`.
static func mark(node: Node, mode: Mode) -> void:
	node.add_to_group(GROUP)
	_apply(node, &"lens_mode", int(mode))
	_apply(node, &"lens", Vector4(0.5, 0.5, 0.0, 0.0))


static func set_on(tree: SceneTree, on: bool) -> void:
	var l := tree.root.get_node_or_null(^"LensOfTruth") as LensOfTruth
	if l == null:
		l = LensOfTruth.new()
		l.name = "LensOfTruth"
		tree.root.add_child.call_deferred(l)
	l._on = on


static func is_on(tree: SceneTree) -> bool:
	var l := tree.root.get_node_or_null(^"LensOfTruth") as LensOfTruth
	return l != null and l._on


func _process(delta: float) -> void:
	_k = move_toward(_k, 1.0 if _on else 0.0, delta / GROW)
	var v := Vector4(0.5, 0.5, radius * (0.6 + 0.4 * _k), _k)
	for n in get_tree().get_nodes_in_group(GROUP):
		_apply(n, &"lens", v)


static func _apply(node: Node, param: StringName, value: Variant) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).set_instance_shader_parameter(param, value)
	for c in node.get_children():
		_apply(c, param, value)
