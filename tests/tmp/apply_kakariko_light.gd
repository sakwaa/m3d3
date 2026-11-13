@tool
extends EditorScript
## One-off: the market's Kakariko-matched brightness (option B of the light trial): baked
## light shown x1.2, grass and mud brighter / a little calmer through the zone-wide colour
## adjust (Paint panel > Colour adjust shows and tweaks them afterwards). Undoable. Run with
## the market scene open: File > Run, then save and Build & Play.

const LEVEL := "res://zones/town1/town_1_market_square_level.res"


func _run() -> void:
	var data: LevelData = load(LEVEL)
	var adjusts := data.base_adjusts.duplicate()
	for spec in [["res://textures/grass/157_green_grass.res", 1.35, 0.9], ["res://textures/ground/mud.res", 1.2, 0.9]]:
		var a := ColourAdjust.new()
		a.brightness = spec[1]
		a.saturation = spec[2]
		adjusts[load(spec[0])] = a
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Kakariko brightness", UndoRedo.MERGE_DISABLE, data)
	ur.add_do_property(data, &"light_bake_strength", 1.2)
	ur.add_undo_property(data, &"light_bake_strength", data.light_bake_strength)
	ur.add_do_property(data, &"base_adjusts", adjusts)
	ur.add_undo_property(data, &"base_adjusts", data.base_adjusts)
	ur.commit_action()
	print("[kakariko light] applied, saved: %s" % error_string(ResourceSaver.save(data, LEVEL)))
