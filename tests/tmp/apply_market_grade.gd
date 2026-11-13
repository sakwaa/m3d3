@tool
extends EditorScript
## One-off: the market's first grading pass (market_grade_def.gd). Saves the shared town
## grade to textures/_grade/shared/town1.tres (other town zones: Grade > Zone filters > Use
## shared...) and gives the open market a grade on top of it. Undoable (the shared file
## stays). Run with the market scene open: File > Run, then save; Build & Play to see it
## in game. Replaces any grade the market already has.

const SHARED := "res://textures/_grade/shared/town1.tres"


func _run() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var level: LevelRoot = root if root is LevelRoot else (root.find_children("*", "LevelRoot", true, false).front() if root else null)
	if level == null or level.data == null or not root.scene_file_path.contains("market"):
		push_warning("Open the market scene first.")
		return
	var made: Array = preload("res://tests/tmp/market_grade_def.gd").make()
	DirAccess.make_dir_recursive_absolute(SHARED.get_base_dir())
	print("[market grade] shared grade: %s" % error_string(ResourceSaver.save(made[0], SHARED)))
	var zone: ZoneGrade = made[1]
	zone.shared = load(SHARED)
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Market Grade (first pass)", UndoRedo.MERGE_DISABLE, level)
	ur.add_do_property(level.data, &"grade", zone)
	ur.add_undo_property(level.data, &"grade", level.data.grade)
	ur.commit_action()
	print("[market grade] applied: open the Grade tab to see / tweak it; save the scene to keep it.")
