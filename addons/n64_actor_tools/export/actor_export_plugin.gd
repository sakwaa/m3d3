@tool
extends EditorExportPlugin
## Keeps the actor tools out of builds: every ActorModel becomes a plain Node3D holding
## its built Skeleton3D + skinned mesh (no script, no authoring data), and this addon's
## files are left out.

const TOOLS_DIR := "res://addons/n64_actor_tools/"


func _get_name() -> String:
	return "N64ActorToolsStrip"


func _begin_customize_scenes(_platform: EditorExportPlatform, _features: PackedStringArray) -> bool:
	return true


func _get_customization_configuration_hash() -> int:
	return 1


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(TOOLS_DIR):
		skip()


func _customize_scene(scene: Node, _path: String) -> Node:
	var models: Array = scene.find_children("*", "Node3D", true, false).filter(func(n): return n is ActorModel)
	if scene is ActorModel:
		models.push_front(scene)
	if models.is_empty():
		return null
	for model: ActorModel in models:
		var out := _flatten(model)
		if model == scene:
			scene = out
	return scene


func _flatten(model: ActorModel) -> Node3D:
	model.export_build = true
	model.rebuild()
	var out := Node3D.new()
	out.name = model.name
	out.transform = model.transform
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton"
	for i in model.skeleton.get_bone_count():
		skeleton.add_bone(model.skeleton.get_bone_name(i))
	for i in model.skeleton.get_bone_count():
		skeleton.set_bone_parent(i, model.skeleton.get_bone_parent(i))
		skeleton.set_bone_rest(i, model.skeleton.get_bone_rest(i))
		skeleton.set_bone_pose(i, model.skeleton.get_bone_pose(i))
	out.add_child(skeleton)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = model.mesh_instance.mesh.duplicate()
	mi.skin = model.mesh_instance.skin.duplicate()
	if model.mesh_instance.has_meta(&"n64_swap_slots"):
		mi.set_meta(&"n64_swap_slots", model.mesh_instance.get_meta(&"n64_swap_slots"))
	skeleton.add_child(mi)
	mi.skeleton = NodePath("..")
	# Animations for the game (Actor plays them by state name).
	if not model.data.animations.is_empty():
		var player := AnimationPlayer.new()
		player.name = "AnimationPlayer"
		player.add_animation_library(&"", model.build_animation_library())
		out.add_child(player)
	# Keep the model's own children (attachments, markers) and their owners.
	var parent := model.get_parent()
	for child in model.get_children():
		model.remove_child(child)
		out.add_child(child)
	var scene_root: Node = out
	if parent:
		var index := model.get_index()
		parent.remove_child(model)
		parent.add_child(out)
		parent.move_child(out, index)
		scene_root = parent.owner if parent.owner else parent
		out.owner = scene_root
	_own(out, scene_root, model)
	model.free()
	return out


## Generated nodes, and moved ones owned by the replaced model, get the scene as owner.
func _own(node: Node, scene_root: Node, replaced: Node) -> void:
	for child in node.get_children():
		if child.owner == null or child.owner == replaced:
			child.owner = scene_root
		_own(child, scene_root, replaced)
