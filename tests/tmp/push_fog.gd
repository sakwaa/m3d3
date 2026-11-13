@tool
extends EditorScript
## One-off: pushes the open zone's distance fog out to start 90 m / end 220 m (the market
## was 60 / 150). Undoable. Run with the zone scene open: File > Run, then save.

const START := 90.0
const END := 220.0


func _run() -> void:
	var zone := EditorInterface.get_edited_scene_root()
	var fog: Resource = zone.get(&"fog") if zone else null
	if fog == null:
		push_error("Open a zone scene with its own fog first.")
		return
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Push fog out")
	ur.add_do_property(fog, &"start", START)
	ur.add_undo_property(fog, &"start", fog.get(&"start"))
	ur.add_do_property(fog, &"end", END)
	ur.add_undo_property(fog, &"end", fog.get(&"end"))
	ur.commit_action()
	print("[fog] %s: %d..%d m; save the scene to keep it" % [zone.name, START, END])
