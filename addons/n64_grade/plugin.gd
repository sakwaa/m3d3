@tool
extends EditorPlugin
## The Grade main screen (DESIGN.md): tuning how a zone looks, beside 2D / 3D / Script.
## Editor only (stripped from exports like the other tool addons).

const View := preload("res://addons/n64_grade/grade_view.gd")

var _view: Control


func _enter_tree() -> void:
	_view = View.new()
	EditorInterface.get_editor_main_screen().add_child(_view)
	_make_visible(false)
	scene_changed.connect(_on_scene_changed)


func _exit_tree() -> void:
	if _view:
		_view.queue_free()
		_view = null


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "Grade"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon(&"ColorPick", &"EditorIcons")


func _make_visible(visible: bool) -> void:
	if _view == null:
		return
	_view.visible = visible
	if visible:
		_view.refresh_level()
		_view.restore_reference()


## Always (not only while the tab shows): the zone's graded textures show in the 3D editor too.
func _on_scene_changed(_root: Node) -> void:
	if _view:
		_view.refresh_level()
