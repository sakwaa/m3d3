@tool
extends HSplitContainer
## Bottom-panel "N64 Textures": queue hi-res images, review the auto-detected settings and
## previews (source / N64 result / 3x3 tiling / palette), then import as N64Texture.

const C := preload("res://addons/n64_level_tools/textures/n64_texture_converter.gd")
const PREVIEW := 160
const TILE_PREVIEW := 3

var _queue: Array[Dictionary] = []  # {path, source: Image, settings, result, object (analysis)}
var _list: ItemList
var _name_edit: LineEdit
var _category_edit: LineEdit
var _usage: OptionButton
var _object: OptionButton
var _mirror: CheckBox
var _holes: OptionButton
var _tiling: OptionButton
var _format: OptionButton
var _size: OptionButton
var _seam: HSlider
var _zoom: HSlider
var _world_size: SpinBox
var _courses: SpinBox
var _anti: OptionButton
var _tint_mode: OptionButton
var _tint_auto: CheckBox
var _tint_dark: ColorPickerButton
var _tint_light: ColorPickerButton
var _tint_amount: HSlider
var _zoom_auto: CheckBox
var _saturation: HSlider
var _contrast: HSlider
var _brightness: HSlider
var _sharpen: HSlider
var _keep_lines: HSlider
var _info: Label
var _status: Label
var _source_view: TextureRect
var _result_view: TextureRect
var _tiled_view: TextureRect
var _palette_view: Control
var _settings_box: Control
var _dialog: EditorFileDialog
var _convert_timer: Timer
var _updating := false
var _inbox := TextureInbox.new()
var _watch_check: CheckBox
var _watch_path: LineEdit
var _auto_import: CheckBox
var _dir_dialog: EditorFileDialog


func _init() -> void:
	name = "N64 Textures"
	custom_minimum_size.y = 260 * EditorInterface.get_editor_scale()
	var scale := EditorInterface.get_editor_scale()

	# Queue.
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 260 * scale
	add_child(left)
	_build_watch_row(left)
	var buttons := HBoxContainer.new()
	left.add_child(buttons)
	var add := Button.new()
	add.text = "Add Images…"
	add.pressed.connect(_open_dialog)
	buttons.add_child(add)
	var remove := Button.new()
	remove.text = "Remove"
	remove.pressed.connect(_remove_selected)
	buttons.add_child(remove)
	var clear := Button.new()
	clear.text = "Clear"
	clear.pressed.connect(func(): _queue.clear(); _refresh_list())
	buttons.add_child(clear)
	_list = ItemList.new()
	_list.size_flags_vertical = SIZE_EXPAND_FILL
	_list.select_mode = ItemList.SELECT_MULTI
	_list.fixed_icon_size = Vector2i(32, 32) * int(scale)
	_list.multi_selected.connect(func(_i, _s): _on_selection())
	_list.item_selected.connect(func(_i): _on_selection())
	left.add_child(_list)
	var import_row := HBoxContainer.new()
	left.add_child(import_row)
	var import_sel := Button.new()
	import_sel.text = "Import Selected"
	import_sel.pressed.connect(func(): _import(_selected_indices()))
	import_row.add_child(import_sel)
	var import_all := Button.new()
	import_all.text = "Import All"
	import_all.pressed.connect(func(): _import(range(_queue.size())))
	import_row.add_child(import_all)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.modulate = Color(1, 1, 1, 0.7)
	left.add_child(_status)

	var right := HSplitContainer.new()
	add_child(right)

	# Settings (applied to every selected item).
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 300 * scale
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(grid)
	_settings_box = grid
	_name_edit = _add_row(grid, "Name", LineEdit.new())
	_name_edit.text_submitted.connect(func(_t): _on_setting_changed())
	_name_edit.focus_exited.connect(_on_setting_changed)
	_category_edit = _add_row(grid, "Category", LineEdit.new())
	_category_edit.text_submitted.connect(func(_t): _on_setting_changed())
	_category_edit.focus_exited.connect(_on_setting_changed)
	_object = _add_row(grid, "Object", _options(N64ObjectExtract.KIND_NAMES))
	_object.tooltip_text = "Photo of one object on a plain background: cut it out and crop it.\nDoor: crops to the panel, hinges turned to the left edge. Window: frame, outside transparent.\nProp: cut-out with transparent background."
	_object.item_selected.connect(_on_object_changed)
	_mirror = CheckBox.new()
	_mirror.text = "Mirror (doors: hinges must end up on the left)"
	_mirror.toggled.connect(func(_on): _on_setting_changed())
	grid.add_child(Control.new())
	grid.add_child(_mirror)
	_holes = _add_row(grid, "Openings", _options(N64ObjectExtract.HOLES_NAMES))
	_holes.tooltip_text = "Doors: background seen through the door (glass panes, screens, gate bars).\nDark glass keeps the door solid; Cut out makes it see-through."
	_holes.item_selected.connect(func(_i): _on_setting_changed())
	_usage = _add_row(grid, "Usage", _options(C.USAGE_NAMES))
	_tiling = _add_row(grid, "Tiling", _options(C.TILING_NAMES))
	_format = _add_row(grid, "Format", _options(C.FORMAT_NAMES))
	_size = _add_row(grid, "Size", OptionButton.new())
	_seam = _add_row(grid, "Seam blend", _slider(0.0, 1.0, 0.05))
	_seam.tooltip_text = "0 = source already tiles (e.g. files named '...seamless...')"
	_zoom = _add_row(grid, "Zoom", _slider(1.0, 8.0, 0.25))
	_zoom.tooltip_text = "Use a 1/zoom subsection of the image for bigger, chunkier detail.\nClick/drag on the Source preview to choose where."
	_zoom.drag_started.connect(func(): _zoom_auto.set_pressed_no_signal(false))
	_zoom_auto = CheckBox.new()
	_zoom_auto.text = "Auto zoom (from image detail / pattern size)"
	_zoom_auto.tooltip_text = "Measures detail size and repeating patterns so features land at a readable size\nin the N64 texture, and picks the most typical-looking region."
	_zoom_auto.toggled.connect(func(_on): _on_setting_changed())
	grid.add_child(Control.new())
	grid.add_child(_zoom_auto)
	_world_size = SpinBox.new()
	_world_size.min_value = 0.0
	_world_size.max_value = 16.0
	_world_size.step = 0.1
	_world_size.suffix = "m"
	_world_size.tooltip_text = "Metres covered by one repeat on levels.\n0 = Auto: width in px / project texels per metre (Project Settings > n64/textures/texels_per_metre)"
	_world_size.value_changed.connect(func(_v): _on_setting_changed())
	_add_row(grid, "Tile size", _world_size)
	_courses = SpinBox.new()
	_courses.min_value = 0
	_courses.max_value = 16
	_courses.tooltip_text = "Bricks / planks (tile one way): whole courses per repeat.\n0 = auto (~16 texels per course). Fewer = bigger bricks. Needs Auto zoom."
	_courses.value_changed.connect(func(_v): _on_setting_changed())
	_add_row(grid, "Courses", _courses)
	_anti = _add_row(grid, "Anti-tiling", _options(["Off", "Offset", "Offset + Rotate", "Row shuffle"]))
	_anti.tooltip_text = "Hide repetition in the shader. Offset / Rotate: hex tiling for organic textures.\nRow shuffle: rows of repeats slide sideways at random (bricks, planks)."
	_anti.item_selected.connect(func(_i): _on_setting_changed())
	_tint_mode = _add_row(grid, "Tint", _options(C.TINT_NAMES))
	_tint_mode.tooltip_text = "Colour combiner. Gradient: greyscale texture coloured by a dark -> light palette (classic N64)."
	_tint_mode.item_selected.connect(func(_i): _on_setting_changed())
	var tint_row := HBoxContainer.new()
	_tint_dark = ColorPickerButton.new()
	_tint_dark.custom_minimum_size = Vector2(40, 0)
	_tint_dark.tooltip_text = "Dark colour (texel 0)"
	_tint_dark.popup_closed.connect(func(): _tint_auto.set_pressed_no_signal(false); _on_setting_changed())
	tint_row.add_child(_tint_dark)
	_tint_light = ColorPickerButton.new()
	_tint_light.custom_minimum_size = Vector2(40, 0)
	_tint_light.tooltip_text = "Light colour (texel 1); the multiply colour in Multiply mode"
	_tint_light.popup_closed.connect(func(): _tint_auto.set_pressed_no_signal(false); _on_setting_changed())
	tint_row.add_child(_tint_light)
	_tint_auto = CheckBox.new()
	_tint_auto.text = "Auto from photo"
	_tint_auto.toggled.connect(func(_on): _on_setting_changed())
	tint_row.add_child(_tint_auto)
	_add_row(grid, "Palette", tint_row)
	_tint_amount = _add_row(grid, "Tint amount", _slider(0.0, 1.0, 0.05))
	_tint_amount.tooltip_text = "0 = texture's own colours, 1 = full gradient palette"
	_saturation = _add_row(grid, "Saturation", _slider(0.0, 2.0, 0.05))
	_contrast = _add_row(grid, "Contrast", _slider(0.0, 2.0, 0.05))
	_brightness = _add_row(grid, "Brightness", _slider(-0.5, 0.5, 0.02))
	_sharpen = _add_row(grid, "Sharpen", _slider(0.0, 2.0, 0.05))
	_sharpen.tooltip_text = "Crisper edges at the N64 size (photos shrunk this far go soft).\nKeep low on tiling textures: it shows as repeating noise."
	_keep_lines = _add_row(grid, "Keep thin lines", _slider(0.0, 1.0, 0.05))
	_keep_lines.tooltip_text = "Thin dark lines (plank gaps, outlines, iron straps) stay visible instead of averaging away."
	for o in [_usage, _tiling, _size]:
		o.item_selected.connect(func(_i): _on_setting_changed())
	_format.item_selected.connect(func(_i): _fill_sizes(); _on_setting_changed())
	var auto := Button.new()
	auto.text = "Reset to auto"
	auto.tooltip_text = "Re-guess category, usage, tiling and format from the file name"
	auto.pressed.connect(_reset_to_auto)
	grid.add_child(Control.new())
	grid.add_child(auto)
	_info = Label.new()
	_info.modulate = Color(1, 1, 1, 0.7)
	grid.add_child(Control.new())
	grid.add_child(_info)

	# Previews.
	var previews := HBoxContainer.new()
	right.add_child(previews)
	_source_view = _preview(previews, "Source")
	_source_view.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_source_view.mouse_filter = Control.MOUSE_FILTER_STOP
	_source_view.mouse_default_cursor_shape = Control.CURSOR_CROSS
	_source_view.tooltip_text = "Click/drag to place the zoomed region"
	_source_view.draw.connect(_draw_crop)
	_source_view.gui_input.connect(_on_source_input)
	_result_view = _preview(previews, "N64")
	_tiled_view = _preview(previews, "Tiled %dx%d" % [TILE_PREVIEW, TILE_PREVIEW])
	_tiled_view.stretch_mode = TextureRect.STRETCH_TILE
	var pal_box := VBoxContainer.new()
	previews.add_child(pal_box)
	var pal_label := Label.new()
	pal_label.text = "Palette"
	pal_box.add_child(pal_label)
	_palette_view = Control.new()
	_palette_view.custom_minimum_size = Vector2(PREVIEW * 0.6, PREVIEW) * scale
	_palette_view.draw.connect(_draw_palette)
	pal_box.add_child(_palette_view)

	_convert_timer = Timer.new()
	_convert_timer.one_shot = true
	_convert_timer.wait_time = 0.15
	_convert_timer.timeout.connect(_convert_selected)
	add_child(_convert_timer)
	_set_settings_enabled(false)

	var poll := Timer.new()
	poll.wait_time = 2.0
	poll.autostart = true
	poll.timeout.connect(_poll_inbox)
	add_child(poll)
	if _get_setting(&"watching", false):
		_watch_check.button_pressed = true


# --- Watch folder ---------------------------------------------------------------------

func _build_watch_row(parent: Control) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	_watch_check = CheckBox.new()
	_watch_check.text = "Watch"
	_watch_check.tooltip_text = "Pick up new image / zip / rar downloads from this folder automatically.\nDownload from your browser as usual (logged-in sites work)."
	_watch_check.toggled.connect(_set_watching)
	row.add_child(_watch_check)
	_watch_path = LineEdit.new()
	_watch_path.size_flags_horizontal = SIZE_EXPAND_FILL
	_watch_path.text = _get_setting(&"watch_folder", OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS))
	_watch_path.text_submitted.connect(func(t): _set_setting(&"watch_folder", t); _restart_watch())
	row.add_child(_watch_path)
	var browse := Button.new()
	browse.text = "…"
	browse.pressed.connect(_browse_watch_folder)
	row.add_child(browse)
	_auto_import = CheckBox.new()
	_auto_import.text = "Auto-import (skip review)"
	_auto_import.button_pressed = _get_setting(&"auto_import", false)
	_auto_import.toggled.connect(func(on): _set_setting(&"auto_import", on))
	parent.add_child(_auto_import)


func _set_watching(on: bool) -> void:
	_set_setting(&"watching", on)
	if on:
		_inbox.start(_watch_path.text)
		_status.text = "Watching %s for new downloads…" % _watch_path.text
	else:
		_inbox.stop()
		_status.text = "Stopped watching."


func _restart_watch() -> void:
	if _watch_check.button_pressed:
		_inbox.start(_watch_path.text)


func _browse_watch_folder() -> void:
	if _dir_dialog == null:
		_dir_dialog = EditorFileDialog.new()
		_dir_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
		_dir_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_dir_dialog.dir_selected.connect(func(d): _watch_path.text = d; _set_setting(&"watch_folder", d); _restart_watch())
		EditorInterface.get_base_control().add_child(_dir_dialog)
	_dir_dialog.current_dir = _watch_path.text
	_dir_dialog.popup_file_dialog()


func _poll_inbox() -> void:
	if not _inbox.is_watching():
		return
	var files := _inbox.poll()
	if files.is_empty():
		return
	var first_new := _queue.size()
	add_files(files)
	if _auto_import.button_pressed and _queue.size() > first_new:
		_import(range(first_new, _queue.size()))
	else:
		_status.text = "%d new download(s) queued for review." % (_queue.size() - first_new)


func _get_setting(key: StringName, default: Variant) -> Variant:
	return EditorInterface.get_editor_settings().get_project_metadata("n64_texture_importer", key, default)


func _set_setting(key: StringName, value: Variant) -> void:
	EditorInterface.get_editor_settings().set_project_metadata("n64_texture_importer", key, value)


# --- Queue ----------------------------------------------------------------------------

func add_files(paths: PackedStringArray) -> void:
	var skipped := PackedStringArray()
	for path in paths:
		if C.is_non_color_map(path):
			skipped.append(path.get_file())
			continue
		var source := N64TextureLibrary.load_preview_source(path)
		if source == null:
			skipped.append(path.get_file())
			continue
		var item := {path = path, source = source, result = {}}
		_auto_settings(item)
		_queue.append(item)
	_refresh_list()
	if _list.item_count > 0 and _list.get_selected_items().is_empty():
		_list.select(0)
		_on_selection()
	_status.text = "Added %d image(s)." % (paths.size() - skipped.size())
	if not skipped.is_empty():
		_status.text += " Skipped (non-colour maps / unreadable): " + ", ".join(skipped)


func _open_dialog() -> void:
	if _dialog == null:
		_dialog = EditorFileDialog.new()
		_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILES
		_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_dialog.title = "Add hi-res textures"
		for ext in ["png", "jpg", "jpeg", "webp", "tga", "bmp"]:
			_dialog.add_filter("*." + ext)
		_dialog.files_selected.connect(add_files)
		EditorInterface.get_base_control().add_child(_dialog)
	_dialog.popup_file_dialog()


## Settings guessed from the file name, or from the object analysis for photos of one
## object on a plain background.
func _auto_settings(item: Dictionary) -> void:
	item.settings = C.guess_settings(item.path, item.source.detect_alpha() != Image.ALPHA_NONE, _aspect(item.source))
	item.result = {}
	if not item.has("object"):
		item.object = N64ObjectExtract.analyse(item.source, item.path)
	var a: Dictionary = item.object
	if a.background and a.kind != N64ObjectExtract.Kind.NONE:
		C.apply_object(item.settings, a.kind, a.mirror, a.aspect, a.holes)
	elif item.settings.zoom_auto:
		_auto_zoom(item)


func _on_object_changed(kind: int) -> void:
	if _updating:
		return
	for i in _selected_indices():
		var item: Dictionary = _queue[i]
		var keep_name: String = item.settings.name
		item.object = N64ObjectExtract.analyse(item.source, item.path, kind)
		if kind == N64ObjectExtract.Kind.NONE or not item.object.background:
			item.settings = C.guess_settings(item.path, item.source.detect_alpha() != Image.ALPHA_NONE, _aspect(item.source))
			if item.settings.zoom_auto:
				_auto_zoom(item)
		else:
			C.apply_object(item.settings, item.object.kind, item.object.mirror, item.object.aspect, item.object.holes)
		item.settings.name = keep_name
		item.result = {}
	_on_selection()


## Auto zoom: measures the image once (cached), then sizes zoom/centre for the output.
func _auto_zoom(item: Dictionary) -> void:
	if not item.has("measure"):
		item.measure = N64TextureAnalysis.measure(item.source)
	N64TextureAnalysis.apply(item.measure, item.settings)
	if item.settings.tiling == C.Tiling.NONE:
		item.settings.zoom_auto = false


func _aspect(img: Image) -> float:
	return float(img.get_width()) / img.get_height()


func _remove_selected() -> void:
	var idx := _selected_indices()
	idx.reverse()
	for i in idx:
		_queue.remove_at(i)
	_refresh_list()
	_on_selection()


func _refresh_list() -> void:
	var selected := _selected_indices()
	_list.clear()
	for item in _queue:
		var s: Dictionary = item.settings
		var i := _list.add_item("%s\n%s · %s · %s %dx%d" % [s.name, s.category, C.TILING_NAMES[s.tiling].get_slice(" (", 0),
			C.FORMAT_NAMES[s.format], s.size.x, s.size.y])
		if item.result.has("image"):
			_list.set_item_icon(i, ImageTexture.create_from_image(item.result.image))
	for i in selected:
		if i < _list.item_count:
			_list.select(i, false)


func _selected_indices() -> Array[int]:
	var out: Array[int] = []
	for i in _list.get_selected_items():
		out.append(i)
	return out


# --- Settings -------------------------------------------------------------------------

func _on_selection() -> void:
	var idx := _selected_indices()
	_set_settings_enabled(not idx.is_empty())
	if idx.is_empty():
		_show_previews({})
		return
	var item: Dictionary = _queue[idx[0]]
	_load_settings(item.settings)
	_name_edit.editable = idx.size() == 1
	_show_previews(item)
	if not item.result.has("image"):
		_convert_timer.start()


func _load_settings(s: Dictionary) -> void:
	_updating = true
	_name_edit.text = s.name
	_category_edit.text = s.category
	_object.select(s.get("object", 0))
	_mirror.button_pressed = s.get("mirror", false)
	_holes.select(s.get("holes", 0))
	_usage.select(s.usage)
	_tiling.select(s.tiling)
	_format.select(s.format)
	_fill_sizes()
	for i in _size.item_count:
		if _size.get_item_metadata(i) == s.size:
			_size.select(i)
	_seam.value = s.seam_blend
	_zoom.value = s.get("zoom", 1.0)
	_zoom_auto.button_pressed = s.get("zoom_auto", false)
	_world_size.value = s.get("world_size", 0.0)
	_courses.value = s.get("courses", 0)
	_anti.select(s.get("anti_tiling", 0))
	_tint_mode.select(s.get("tint_mode", 0))
	_tint_auto.button_pressed = s.get("tint_auto", true)
	_tint_dark.color = s.get("tint_dark", Color(0.2, 0.2, 0.2))
	_tint_light.color = s.get("tint_light", Color.WHITE)
	_tint_amount.value = s.get("tint_amount", 0.5)
	_saturation.value = s.saturation
	_contrast.value = s.contrast
	_brightness.value = s.brightness
	_sharpen.value = s.get("sharpen", 0.0)
	_keep_lines.value = s.get("keep_lines", 0.0)
	_updating = false
	_update_info(s)


func _on_setting_changed() -> void:
	if _updating:
		return
	var idx := _selected_indices()
	for i in idx:
		var s: Dictionary = _queue[i].settings
		if idx.size() == 1:
			s.name = _name_edit.text.strip_edges().to_snake_case()
		s.category = _category_edit.text.strip_edges().to_snake_case()
		s.mirror = _mirror.button_pressed
		s.holes = _holes.selected
		s.usage = _usage.selected
		s.tiling = _tiling.selected
		s.format = _format.selected
		s.size = _size.get_item_metadata(_size.selected) if _size.selected >= 0 else s.size
		s.seam_blend = _seam.value
		s.zoom = _zoom.value
		s.zoom_auto = _zoom_auto.button_pressed
		s.world_size = _world_size.value
		s.courses = int(_courses.value)
		s.anti_tiling = _anti.selected
		s.tint_mode = _tint_mode.selected
		s.tint_auto = _tint_auto.button_pressed
		s.tint_amount = _tint_amount.value
		if not s.tint_auto:
			s.tint_dark = _tint_dark.color
			s.tint_light = _tint_light.color
		if s.zoom_auto:
			_auto_zoom(_queue[i])
		s.saturation = _saturation.value
		s.contrast = _contrast.value
		s.brightness = _brightness.value
		s.sharpen = _sharpen.value
		s.keep_lines = _keep_lines.value
		_queue[i].result = {}
	if not idx.is_empty():
		_update_info(_queue[idx[0]].settings)
		if _queue[idx[0]].settings.zoom_auto:
			_updating = true
			_zoom.value = _queue[idx[0]].settings.zoom
			_updating = false
		_source_view.queue_redraw()
	_convert_timer.start()


func _reset_to_auto() -> void:
	for i in _selected_indices():
		var item: Dictionary = _queue[i]
		item.erase("object")
		_auto_settings(item)
	_on_selection()
	_refresh_list()


func _fill_sizes() -> void:
	var current: Vector2i = _size.get_item_metadata(_size.selected) if _size.selected >= 0 else Vector2i.ZERO
	_size.clear()
	for sz in C.size_options(_format.selected):
		_size.add_item("%d × %d" % [sz.x, sz.y])
		_size.set_item_metadata(_size.item_count - 1, sz)
		if sz == current:
			_size.select(_size.item_count - 1)
	if _size.selected < 0 and _size.item_count > 0:
		_size.select(0)


func _update_info(s: Dictionary) -> void:
	var info: Dictionary = C.FORMAT_INFO[s.format]
	var text := "%d B of 4096 B TMEM" % C.tmem_bytes(s.format, s.size)
	if info.palette > 0:
		text += " · up to %d colours" % info.palette
	elif info.gray:
		text += " · greyscale (tint with vertex/prim colour)"
	var idx := _selected_indices()
	if not idx.is_empty() and s.get("object", 0) == N64ObjectExtract.Kind.DOOR:
		var a: Dictionary = _queue[idx[0]].get("object", {})
		if a.get("kind", -1) == N64ObjectExtract.Kind.DOOR:
			text += "\nHinges found on the %s by %s (%d%% sure)%s" % ["right" if a.mirror else "left", a.hinge_by,
				roundi(a.hinge_confidence * 100.0), ", mirrored to the left" if a.mirror else ""]
	_info.text = text


func _set_settings_enabled(enabled: bool) -> void:
	for child in _settings_box.get_children():
		if child is LineEdit:
			child.editable = enabled
		elif child is BaseButton:
			child.disabled = not enabled
		elif child is Range:
			child.editable = enabled


# --- Conversion / previews ------------------------------------------------------------

func _convert_selected() -> void:
	for i in _selected_indices():
		var item: Dictionary = _queue[i]
		if not item.result.has("image"):
			item.result = C.convert(item.source, item.settings)
	_refresh_list()
	var idx := _selected_indices()
	if not idx.is_empty():
		_show_previews(_queue[idx[0]])


func _show_previews(item: Dictionary) -> void:
	_source_view.texture = ImageTexture.create_from_image(item.source) if item.has("source") else null
	_source_view.queue_redraw()
	var result: Dictionary = item.get("result", {})
	if not result.has("image"):
		_result_view.texture = null
		_tiled_view.texture = null
		_palette_view.set_meta(&"palette", PackedColorArray())
		_palette_view.queue_redraw()
		return
	var img: Image = _tinted(result.image, item.settings, result)
	if item.settings.get("tint_auto", true) and result.has("tint_dark"):
		item.settings.tint_dark = result.tint_dark
		item.settings.tint_light = result.tint_light
		_tint_dark.color = result.tint_dark
		_tint_light.color = result.tint_light
	var scale := float(PREVIEW * EditorInterface.get_editor_scale()) / maxi(img.get_width(), img.get_height())
	var big := img.duplicate() as Image
	big.resize(int(img.get_width() * scale), int(img.get_height() * scale), Image.INTERPOLATE_NEAREST)
	_result_view.texture = ImageTexture.create_from_image(big)
	var small := img.duplicate() as Image
	small.resize(int(big.get_width() / TILE_PREVIEW), int(big.get_height() / TILE_PREVIEW), Image.INTERPOLATE_NEAREST)
	_tiled_view.texture = ImageTexture.create_from_image(small)
	_palette_view.set_meta(&"palette", result.palette)
	_palette_view.queue_redraw()


## Where the source texture is drawn inside its (keep-aspect, centred) TextureRect.
func _source_draw_rect() -> Rect2:
	var tex := _source_view.texture
	if tex == null:
		return Rect2()
	var box := _source_view.size
	var k := minf(box.x / tex.get_width(), box.y / tex.get_height())
	var sz := Vector2(tex.get_width(), tex.get_height()) * k
	return Rect2((box - sz) * 0.5, sz)


func _draw_crop() -> void:
	var idx := _selected_indices()
	if idx.is_empty() or _source_view.texture == null:
		return
	var item: Dictionary = _queue[idx[0]]
	var r := C.crop_rect(item.source.get_size(), item.settings)
	var area := _source_draw_rect()
	var rect := Rect2(area.position + r.position * area.size, r.size * area.size)
	_source_view.draw_rect(rect, Color(0.4, 1.0, 0.45), false, 2.0)
	if item.settings.seam_blend <= 0.0:
		# Region wraps around a tiling source: show the wrapped parts too.
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				if dx != 0 or dy != 0:
					var wrapped := Rect2(rect.position + Vector2(dx, dy) * area.size, rect.size).intersection(area)
					if wrapped.has_area():
						_source_view.draw_rect(wrapped, Color(0.4, 1.0, 0.45, 0.5), false, 1.0)


func _on_source_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouse
	if mouse == null:
		return
	var press: bool = mouse is InputEventMouseButton and mouse.button_index == MOUSE_BUTTON_LEFT and mouse.pressed
	var drag: bool = mouse is InputEventMouseMotion and (mouse.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
	if not (press or drag):
		return
	var area := _source_draw_rect()
	if not area.has_area():
		return
	var c: Vector2 = ((mouse.position - area.position) / area.size).clamp(Vector2.ZERO, Vector2.ONE)
	for i in _selected_indices():
		_queue[i].settings.crop_center = c
		_queue[i].result = {}
	_source_view.queue_redraw()
	_convert_timer.start()


## Preview of what the shader will show: the combiner tint applied to the stored texels.
func _tinted(img: Image, s: Dictionary, result: Dictionary) -> Image:
	var mode: int = s.get("tint_mode", 0)
	if mode == C.TintMode.NONE:
		return img
	var dark: Color = result.get("tint_dark", s.tint_dark)
	var light: Color = result.get("tint_light", s.tint_light)
	var tr: Vector2 = result.get("tint_range", Vector2(0, 1))
	var amount: float = s.get("tint_amount", 0.5)
	var out := img.duplicate() as Image
	for y in out.get_height():
		for x in out.get_width():
			var c := out.get_pixel(x, y)
			var tinted: Color
			if mode == C.TintMode.GRADIENT:
				tinted = dark.lerp(light, clampf((c.get_luminance() - tr.x) / maxf(tr.y - tr.x, 0.01), 0.0, 1.0))
			else:
				tinted = Color(c.r * light.r, c.g * light.g, c.b * light.b)
			var rgb := c.lerp(tinted, amount)
			out.set_pixel(x, y, Color(rgb.r, rgb.g, rgb.b, c.a))
	return out


func _draw_palette() -> void:
	var palette: PackedColorArray = _palette_view.get_meta(&"palette", PackedColorArray())
	if palette.is_empty():
		return
	var cols := 4 if palette.size() <= 16 else 16
	var cell := _palette_view.size.x / cols
	for i in palette.size():
		var r := Rect2(Vector2(i % cols, i / cols) * cell, Vector2(cell, cell))
		if palette[i].a == 0.0:
			_palette_view.draw_rect(r.grow(-1), Color(1, 1, 1, 0.3), false)
		else:
			_palette_view.draw_rect(r.grow(-1), palette[i])


# --- Import ---------------------------------------------------------------------------

func _import(indices: Array) -> void:
	var done := PackedStringArray()
	var imported := []
	for i in indices:
		var item: Dictionary = _queue[i]
		var tex := N64TextureLibrary.import_image(item.path, item.settings, item.source)
		if tex:
			done.append(tex.resource_path)
			imported.append(i)
	imported.reverse()
	for i in imported:
		_queue.remove_at(i)
	_refresh_list()
	_on_selection()
	EditorInterface.get_resource_filesystem().scan()
	_status.text = "Imported %d texture(s) into %s/." % [done.size(), N64TextureLibrary.ROOT]


# --- Widgets --------------------------------------------------------------------------

func _add_row(grid: GridContainer, label_text: String, control: Control) -> Control:
	var l := Label.new()
	l.text = label_text
	grid.add_child(l)
	control.size_flags_horizontal = SIZE_EXPAND_FILL
	grid.add_child(control)
	return control


func _options(names: Array) -> OptionButton:
	var o := OptionButton.new()
	for n in names:
		o.add_item(n)
	return o


func _slider(lo: float, hi: float, step: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.custom_minimum_size.x = 120
	s.value_changed.connect(func(_v): _on_setting_changed())
	return s


func _preview(parent: Control, title: String) -> TextureRect:
	var box := VBoxContainer.new()
	parent.add_child(box)
	var l := Label.new()
	l.text = title
	box.add_child(l)
	var tr := TextureRect.new()
	tr.custom_minimum_size = Vector2.ONE * PREVIEW * EditorInterface.get_editor_scale()
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	box.add_child(tr)
	return tr
