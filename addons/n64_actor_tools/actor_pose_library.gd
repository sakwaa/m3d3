@tool
class_name ActorPoseLibrary
extends Resource
## Named poses shared by every character of a body plan (fighting stance, crouch, point,
## sit...): consistent poses across characters, quick starting points for keys.
## Saved at res://characters/poses/<plan>.tres.

const DIR := "res://characters/poses/"

## Pose name -> {pose: {bone: Quaternion}, root: Vector3}
@export var poses := {}


static func path_for(plan: StringName) -> String:
	return DIR.path_join("%s.tres" % plan)


static func open(plan: StringName) -> ActorPoseLibrary:
	var path := path_for(plan)
	if ResourceLoader.exists(path):
		var lib := load(path) as ActorPoseLibrary
		if lib:
			return lib
	return ActorPoseLibrary.new()


func save_for(plan: StringName) -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	ResourceSaver.save(self, path_for(plan))
