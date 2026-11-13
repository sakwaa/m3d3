@tool
extends EditorScript
## One-off: the market's light floor 0.35 -> 0.15 and contrast 0.7 -> 1.0, with the new noon
## key (game/lighting_schedule.tres: stronger sun, lower ambient): shaded faces drop dark,
## the value spread opens from ~29 to ~44 (Kakariko ~56). Undoable. Run with the market
## scene open: File > Run, then save and Build & Play.

const LEVEL := "res://zones/town1/town_1_market_square_level.res"


func _run() -> void:
	var data: LevelData = load(LEVEL)
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Value light", UndoRedo.MERGE_DISABLE, data)
	ur.add_do_property(data, &"light_floor", 0.15)
	ur.add_undo_property(data, &"light_floor", data.light_floor)
	ur.add_do_property(data, &"light_contrast", 1.0)
	ur.add_undo_property(data, &"light_contrast", data.light_contrast)
	ur.commit_action()
	print("[value light] applied, saved: %s" % error_string(ResourceSaver.save(data, LEVEL)))
