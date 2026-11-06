@tool
extends EditorPlugin
## N64 story tools: the "Story" main-screen workspace (beside 2D / 3D / Script) for
## dialogues and the story database (characters, items, registered flags), and the
## export step that strips editor notes. Editor-only; the runtime lives in game/story.

const Workspace := preload("res://addons/n64_story_tools/ui/story_workspace.gd")
const Export := preload("res://addons/n64_story_tools/export_plugin.gd")

var _workspace: Control
var _export: EditorExportPlugin
## Cutscenes "Pick in 3D": the next click in the 3D view calls this with the point.
var _pick_cb: Callable


func _enter_tree() -> void:
	if not ProjectSettings.has_setting(StoryDatabase.SETTING):
		ProjectSettings.set_setting(StoryDatabase.SETTING, StoryDatabase.DEFAULT_PATH)
	ProjectSettings.set_initial_value(StoryDatabase.SETTING, StoryDatabase.DEFAULT_PATH)
	ProjectSettings.add_property_info({name = StoryDatabase.SETTING, type = TYPE_STRING,
		hint = PROPERTY_HINT_FILE, hint_string = "*.tres"})
	_setting(Workspace.DialogueEditor.DIR_SETTING, Workspace.DialogueEditor.DEFAULT_DIR, PROPERTY_HINT_DIR, "")
	_setting(Workspace.DialogueEditor.Export.SETTING, Workspace.DialogueEditor.Export.DEFAULT_PATH, PROPERTY_HINT_FILE, "*.csv")
	_workspace = Workspace.new()
	_workspace.visible = false
	_workspace.cutscene_editor.request_pick = start_pick
	EditorInterface.get_editor_main_screen().add_child(_workspace)
	_export = Export.new()
	add_export_plugin(_export)


func _setting(name: String, value: String, hint: int, hint_string: String) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, value)
	ProjectSettings.set_initial_value(name, value)
	ProjectSettings.add_property_info({name = name, type = TYPE_STRING, hint = hint, hint_string = hint_string})


func _exit_tree() -> void:
	_workspace.queue_free()
	remove_export_plugin(_export)


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "Story"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon(&"Script", &"EditorIcons")


func _make_visible(visible: bool) -> void:
	_workspace.visible = visible
	if visible:
		_workspace.open()


func _handles(object: Object) -> bool:
	if _pick_cb.is_valid() and object is Node:
		return true  # picking a point: take the 3D view's clicks
	return object is StoryDatabase or object is Dialogue or object is NpcSchedule or object is Cutscene


func _edit(object: Object) -> void:
	if object is StoryDatabase or object is Dialogue or object is NpcSchedule or object is Cutscene:
		EditorInterface.set_main_screen_editor("Story")
	if object is Cutscene and object.resource_path != "":
		_workspace.open_cutscene(object.resource_path)
	if object is NpcSchedule:
		_workspace.open_schedule(object)
	if object is Dialogue and object.resource_path != "":
		_workspace.open_dialogue(object.resource_path)


# --- Picking a point in the 3D view (Cutscenes tab) -------------------------------------

## The next click in the 3D view calls `callback(point)` (Esc cancels); switches to 3D.
func start_pick(callback: Callable) -> void:
	_pick_cb = callback
	EditorInterface.set_main_screen_editor("3D")
	var root := EditorInterface.get_edited_scene_root()
	if root:
		EditorInterface.edit_node(root)  # so _handles() claims the 3D view's input
	update_overlays()


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if not _pick_cb.is_valid():
		return AFTER_GUI_INPUT_PASS
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_end_pick()
		return AFTER_GUI_INPUT_STOP
	if event is InputEventMouseMotion:
		update_overlays()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var cb := _pick_cb
		var point: Vector3 = _workspace.cutscene_editor._ray_point(camera, event.position)
		_end_pick()
		cb.call(point)
		return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	if _pick_cb.is_valid():
		var font := overlay.get_theme_default_font()
		var pos := overlay.get_local_mouse_position() + Vector2(16, 16)
		overlay.draw_string_outline(font, pos, "Click to place the cutscene key (Esc cancels)", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, 4, Color.BLACK)
		overlay.draw_string(font, pos, "Click to place the cutscene key (Esc cancels)", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.85, 0.4))


func _end_pick() -> void:
	_pick_cb = Callable()
	update_overlays()
	EditorInterface.set_main_screen_editor("Story")
