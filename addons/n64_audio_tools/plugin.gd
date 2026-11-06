@tool
extends EditorPlugin
## N64 audio tools: the "N64 Sounds" main-screen workspace (beside 2D / 3D / Script) for
## sound banks and the instrument library (bank sets, areas), and the export step that
## strips authoring data (recording paths, processing settings, tags) from them. Editor-only; the synth and decoder live in game/audio.

const Workspace := preload("res://addons/n64_audio_tools/ui/sound_workspace.gd")
const Export := preload("res://addons/n64_audio_tools/export_plugin.gd")

var _workspace: Control
var _export: EditorExportPlugin


func _enter_tree() -> void:
	_workspace = Workspace.new()
	_workspace.visible = false
	EditorInterface.get_editor_main_screen().add_child(_workspace)
	_export = Export.new()
	add_export_plugin(_export)
	# Sample RAM budget per bank (the workspace's toolbar warns past it).
	if not ProjectSettings.has_setting(Workspace.BUDGET_SETTING):
		ProjectSettings.set_setting(Workspace.BUDGET_SETTING, Workspace.DEFAULT_BUDGET_KB)
	ProjectSettings.set_initial_value(Workspace.BUDGET_SETTING, Workspace.DEFAULT_BUDGET_KB)
	ProjectSettings.add_property_info({name = Workspace.BUDGET_SETTING, type = TYPE_INT,
		hint = PROPERTY_HINT_RANGE, hint_string = "16,4096,16,suffix:KB"})
	# Folder of the instrument library (instruments, samples, bank sets, areas).
	if not ProjectSettings.has_setting(Workspace.LIBRARY_SETTING):
		ProjectSettings.set_setting(Workspace.LIBRARY_SETTING, Workspace.DEFAULT_LIBRARY)
	ProjectSettings.set_initial_value(Workspace.LIBRARY_SETTING, Workspace.DEFAULT_LIBRARY)
	ProjectSettings.add_property_info({name = Workspace.LIBRARY_SETTING, type = TYPE_STRING, hint = PROPERTY_HINT_DIR})


func _exit_tree() -> void:
	_workspace.queue_free()
	remove_export_plugin(_export)


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "N64 Sounds"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon(&"AudioStreamPlayer", &"EditorIcons")


func _make_visible(visible: bool) -> void:
	_workspace.visible = visible


## Opening a sound bank, a song, the library, a bank set or an area from the FileSystem dock
## brings it up in the workspace.
func _handles(object: Object) -> bool:
	return object is Resource and (("Samples" in object and "Instruments" in object) or ("Events" in object and "Tracks" in object)
		or ("Entries" in object and "Kind" in object) or ("MusicSets" in object and "SfxSets" in object))


func _edit(object: Object) -> void:
	if object and object is Resource and object.resource_path != "":
		if "Tracks" in object:
			_workspace.open_song(object.resource_path)
		elif "Entries" in object or "MusicSets" in object:
			_workspace.open_library()
			_workspace._select_meta(object)
		else:
			_workspace.open_bank(object.resource_path)
		EditorInterface.set_main_screen_editor("N64 Sounds")
