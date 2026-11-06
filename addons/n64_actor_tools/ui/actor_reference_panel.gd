@tool
extends PopupPanel
## Reference image settings for the 3D view's current axis view (opened from the tool
## strip's VIEW section): load an image (copied into res://references), adjust it in the
## view, fit it to the model, straighten, remove, opacity, show and lock; plus the
## ortho grid toggle. Every change is one undo step (through the view aids' `edited`).

const ViewAids := preload("res://addons/n64_actor_tools/editor_view_aids.gd")

var aids: ViewAids
## Called with the new state of the ortho grid toggle.
var on_grid: Callable

var _title: Label
var _image: Label
var _rows: Control
var _opacity: HSlider
var _show: CheckBox
var _lock: CheckBox
var _grid: CheckBox
var _dialog: EditorFileDialog
var _before := {}


func _init() -> void:
	var s := EditorInterface.get_editor_scale()
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(250, 0) * s
	add_child(box)
	_title = Label.new()
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_title)
	_rows = VBoxContainer.new()
	box.add_child(_rows)
	_image = Label.new()
	_image.modulate = Color(1, 1, 1, 0.6)
	_image.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_rows.add_child(_image)
	var buttons := GridContainer.new()
	buttons.columns = 3
	_rows.add_child(buttons)
	for spec in [["Load…", _load], ["Adjust", _adjust], ["Fit", _fit], ["Straighten", _straighten], ["Remove", _remove]]:
		var b := Button.new()
		b.text = spec[0]
		b.pressed.connect(spec[1])
		buttons.add_child(b)
	var turn := HBoxContainer.new()
	_rows.add_child(turn)
	var tl := Label.new()
	tl.text = "Rotate"
	turn.add_child(tl)
	for spec in [["⟲ 90°", 90.0], ["⟲ 15°", 15.0], ["⟳ 15°", -15.0], ["⟳ 90°", -90.0]]:
		var b := Button.new()
		b.text = spec[0]
		var deg: float = spec[1]
		b.pressed.connect(func():
			aids.rotate_by(deg)
			refresh())
		turn.add_child(b)
	var op := HBoxContainer.new()
	_rows.add_child(op)
	var l := Label.new()
	l.text = "Opacity"
	op.add_child(l)
	_opacity = HSlider.new()
	_opacity.min_value = 0.05
	_opacity.max_value = 1.0
	_opacity.step = 0.01
	_opacity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_opacity.drag_started.connect(func(): _before = aids.snapshot())
	_opacity.value_changed.connect(func(v): aids.refs.set_value(aids.view, "opacity", v))
	_opacity.drag_ended.connect(func(changed): if changed: aids.commit(_before, "Reference opacity"))
	op.add_child(_opacity)
	_show = _check(_rows, "Show", "visible", "Show reference image")
	_lock = _check(_rows, "Lock (double-click won't select it)", "locked", "Lock reference image")
	box.add_child(HSeparator.new())
	_grid = CheckBox.new()
	_grid.text = "Grid in axis views (model snap size)"
	_grid.toggled.connect(func(on): on_grid.call(on))
	box.add_child(_grid)


func _check(parent: Control, text: String, key: String, label: String) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.toggled.connect(func(on): _change(label, func(): aids.refs.set_value(aids.view, key, on)))
	parent.add_child(c)
	return c


func open_at(rect: Rect2i, grid_on: bool) -> void:
	_grid.set_pressed_no_signal(grid_on)
	refresh()
	popup(Rect2i(rect.position + Vector2i(rect.size.x + 4, 0), Vector2i.ZERO))


func refresh(_v := 0) -> void:
	if aids == null or not is_instance_valid(aids):
		return
	var v := aids.view
	var r := aids.refs.get_ref(v)
	if v == 0:
		_title.text = "Look straight down an axis in orthogonal (click the view gizmo, or numpad 1 / 3 / 7) to set that view's reference image."
	else:
		_title.text = "%s view reference" % ViewAids.VIEW_NAMES[v]
	_rows.visible = v != 0
	_image.text = String(r.get("path", "No image")).get_file() if not r.is_empty() else "No image"
	_opacity.set_value_no_signal(r.get("opacity", 0.55))
	_show.set_pressed_no_signal(r.get("visible", true))
	_lock.set_pressed_no_signal(r.get("locked", false))
	_opacity.editable = not r.is_empty()
	_show.disabled = r.is_empty()
	_lock.disabled = r.is_empty()
	reset_size()


## One undo step around `fn` (changes the current view's reference).
func _change(label: String, fn: Callable) -> void:
	if aids.view == 0:
		return
	var before := aids.snapshot()
	fn.call()
	if aids.refs.refs != before:
		aids.commit(before, label)
	refresh()


func _load() -> void:
	if _dialog == null:
		_dialog = EditorFileDialog.new()
		_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_dialog.title = "Reference image"
		_dialog.add_filter("*.png, *.jpg, *.jpeg, *.webp, *.bmp, *.tga", "Images")
		_dialog.file_selected.connect(_on_file)
		EditorInterface.get_base_control().add_child(_dialog)
	_dialog.current_dir = ProjectSettings.globalize_path(ViewAids.DIR)
	_dialog.popup_file_dialog()


func _on_file(path: String) -> void:
	var local := aids.refs.import_image(path)
	if local == "":
		push_warning("Can't copy %s into %s." % [path, ViewAids.DIR])
		return
	_change("Set reference image", func():
		if not aids.refs.set_image(aids.view, local):
			push_warning("Can't read %s (use PNG or JPG)." % path.get_file()))


func _adjust() -> void:
	aids.set_adjusting(true)
	hide()


func _fit() -> void:
	_change("Fit reference image", func(): aids.refs.fit(aids.view))


func _straighten() -> void:
	_change("Straighten reference image", func():
		aids.refs.set_value(aids.view, "angle", 0.0)
		aids.refs.set_value(aids.view, "stretch", 1.0))


func _remove() -> void:
	aids.set_adjusting(false)
	_change("Remove reference image", func(): aids.refs.clear(aids.view))
