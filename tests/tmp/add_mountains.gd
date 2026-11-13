@tool
extends EditorScript
## Adds a MountainRange to the open scene (the market): low-poly ranges far round the town.
## Tweak it in the inspector (seed, radii, heights, colours, open arcs); Ctrl+Z removes it.
## Run with the market scene open: File > Run, then save.


func _run() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_error("Open the zone scene first.")
		return
	if root.find_children("*", "MountainRange", true, false).size() > 0:
		print("[mountains] the scene already has a MountainRange")
		return
	var mr := MountainRange.new()
	mr.name = "Mountains"
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Add Mountains")
	ur.add_do_method(root, &"add_child", mr, true)
	ur.add_do_property(mr, &"owner", root)
	ur.add_do_reference(mr)
	ur.add_undo_method(root, &"remove_child", mr)
	ur.commit_action()
	EditorInterface.edit_node(mr)
	print("[mountains] added; save the scene to keep them")
