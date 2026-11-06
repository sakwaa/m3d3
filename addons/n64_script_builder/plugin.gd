@tool
extends EditorPlugin
## The Script Builder: a main-screen tab (beside 2D / 3D / Script) for drawing the in-game
## script's glyphs (SyllabaryAlphabet). Tooling only: never exported.

const ScriptBuilder := preload("res://addons/n64_script_builder/script_builder.gd")

var _view: Control


func _enter_tree() -> void:
	_view = ScriptBuilder.new()
	_view.undo_redo = get_undo_redo()
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	EditorInterface.get_editor_main_screen().add_child(_view)
	_make_visible(false)


func _exit_tree() -> void:
	if _view:
		_view.queue_free()
		_view = null


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if _view:
		_view.visible = visible


func _get_plugin_name() -> String:
	return "Script Builder"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon(&"Font", &"EditorIcons")
