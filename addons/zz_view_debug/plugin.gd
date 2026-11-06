@tool
extends EditorPlugin
## TEMPORARY diagnostic (delete after use): logs input reaching the editor and every
## change of the 3D view's camera (projection / direction) to user://view_debug.log.

var _file: FileAccess
var _last := ""
var _t0 := 0


func _enter_tree() -> void:
	_file = FileAccess.open("user://view_debug.log", FileAccess.WRITE)
	_t0 = Time.get_ticks_msec()
	_log("start; log at " + ProjectSettings.globalize_path("user://view_debug.log"))
	set_process(true)
	set_process_input(true)


func _exit_tree() -> void:
	if _file:
		_file.close()


func _log(s: String) -> void:
	if _file:
		_file.store_line("%7d  %s" % [Time.get_ticks_msec() - _t0, s])
		_file.flush()


func _process(_d: float) -> void:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var cam := vp.get_camera_3d() if vp else null
	if cam == null:
		return
	var state := "CAMERA %s dir %s" % ["ORTHO" if cam.projection == Camera3D.PROJECTION_ORTHOGONAL else "persp", (-cam.global_basis.z).snappedf(0.01)]
	if state != _last:
		_last = state
		var root := EditorInterface.get_edited_scene_root()
		_log("%s   (scene %s)" % [state, root.name if root else "-"])


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var m := event as InputEventMouseMotion
		if m.button_mask != 0 or m.alt_pressed or m.shift_pressed or m.ctrl_pressed or m.meta_pressed:
			_log("motion mask %d rel %s alt %s shift %s ctrl %s meta %s at %s" % [m.button_mask, m.relative, m.alt_pressed, m.shift_pressed, m.ctrl_pressed, m.meta_pressed, m.position])
		return
	if event is InputEventMouseButton:
		var b := event as InputEventMouseButton
		_log("button %d %s at %s alt %s meta %s" % [b.button_index, "DOWN" if b.pressed else "up", b.position, b.alt_pressed, b.meta_pressed])
	elif event is InputEventPanGesture:
		_log("PAN GESTURE delta %s" % (event as InputEventPanGesture).delta)
	elif event is InputEventMagnifyGesture:
		_log("magnify %s" % (event as InputEventMagnifyGesture).factor)
	elif event is InputEventKey:
		var k := event as InputEventKey
		if not k.echo:
			_log("key %s %s" % [OS.get_keycode_string(k.keycode), "DOWN" if k.pressed else "up"])
