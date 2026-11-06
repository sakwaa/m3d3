@tool
extends EditorExportPlugin
## Ships the story database, dialogues and schedules without editor notes. Everything in this addon is left out
## (export presets too).

const TOOLS_DIR := "res://addons/n64_story_tools/"


func _get_name() -> String:
	return "N64StoryToolsStrip"


func _begin_customize_resources(_platform: EditorExportPlatform, _features: PackedStringArray) -> bool:
	return true


func _get_customization_configuration_hash() -> int:
	return 1


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(TOOLS_DIR):
		skip()


func _customize_resource(resource: Resource, _path: String) -> Resource:
	if resource is StoryDatabase:
		var db: StoryDatabase = resource.duplicate_deep()  # built-in defs copied, not edited in place
		for list in [db.characters, db.items, db.flags]:
			for def in list:
				if def:
					def.notes = ""
		return db
	if resource is NpcSchedule:
		var sc: NpcSchedule = resource.duplicate()
		sc.notes = ""
		return sc
	if resource is Dialogue:
		var d: Dialogue = resource.duplicate()
		d.notes = ""
		return d
	return null
