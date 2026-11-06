@tool
class_name N64TexturePicker
extends HBoxContainer
## Texture slot for the paint tools: shows the current texture (thumbnail + name) and opens
## a browser of the imported library (res://textures/<category>/…), grouped by folder in
## filesystem order, with free-text search on file names (every word must appear). Accepts drags from the
## FileSystem dock. Same interface as EditorResourcePicker (edited_resource /
## resource_changed), so it drops in where one was used.

signal resource_changed(resource: Resource)

const ROOT := "res://textures"
const SKIP_DIRS := ["_source"]
const THUMB := 32

var edited_resource: Texture2D:
	set(value):
		edited_resource = value
		_refresh_button()

var _button: Button
var _clear: Button
var _popup: PopupPanel
var _search: LineEdit
var _tree: Tree


func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button = Button.new()
	_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_button.expand_icon = false
	_button.clip_text = true
	_button.tooltip_text = "Choose an imported texture (or drop one from the FileSystem dock)"
	_button.pressed.connect(_open)
	add_child(_button)
	_clear = Button.new()
	_clear.flat = true
	_clear.tooltip_text = "Clear"
	_clear.pressed.connect(func(): _pick(null))
	add_child(_clear)


func _ready() -> void:
	_clear.icon = get_theme_icon(&"Close", &"EditorIcons")
	_refresh_button()


func _refresh_button() -> void:
	if _button == null:
		return
	if edited_resource:
		_button.text = edited_resource.resource_path.get_file().get_basename() if edited_resource.resource_path else "(texture)"
		_button.icon = _thumbnail(edited_resource, 20)
		_button.tooltip_text = edited_resource.resource_path
	else:
		_button.text = "None"
		_button.icon = null
		_button.tooltip_text = "Choose an imported texture (or drop one from the FileSystem dock)"
	_clear.visible = edited_resource != null


func _pick(tex: Texture2D) -> void:
	if _popup:
		_popup.hide()
	if tex == edited_resource:
		return
	edited_resource = tex
	resource_changed.emit(tex)


# --- Browser ------------------------------------------------------------------------

func _open() -> void:
	if _popup == null:
		_build_popup()
	_search.text = ""
	_populate("")
	var rect := _button.get_global_rect()
	var scale := EditorInterface.get_editor_scale()
	_popup.popup(Rect2i(Vector2i(rect.position + Vector2(0, rect.size.y)), Vector2i(Vector2(340, 440) * scale)))
	_search.grab_focus()


func _build_popup() -> void:
	_popup = PopupPanel.new()
	var box := VBoxContainer.new()
	_popup.add_child(box)
	_search = LineEdit.new()
	_search.placeholder_text = "Search textures…"
	_search.clear_button_enabled = true
	_search.right_icon = get_theme_icon(&"Search", &"EditorIcons")
	_search.text_changed.connect(_populate)
	_search.text_submitted.connect(func(_t): _pick_first())
	_search.gui_input.connect(func(e):
		if e is InputEventKey and e.pressed and e.keycode == KEY_DOWN:
			_tree.grab_focus()
			var first := _first_texture_item()
			if first:
				first.select(0)
			_search.accept_event())
	box.add_child(_search)
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.select_mode = Tree.SELECT_SINGLE
	_tree.item_activated.connect(_on_activated)
	_tree.item_mouse_selected.connect(func(_p, _b): _on_activated())
	box.add_child(_tree)
	add_child(_popup)


## Fills the tree with library textures whose file name contains every search word.
func _populate(filter: String) -> void:
	_tree.clear()
	var root := _tree.create_item()
	var words := filter.to_lower().split(" ", false)
	var none := _tree.create_item(root)
	none.set_text(0, "None")
	none.set_metadata(0, "")
	none.set_custom_color(0, Color(1, 1, 1, 0.5))
	var folder_icon := get_theme_icon(&"Folder", &"EditorIcons")
	for category in _sorted(DirAccess.get_directories_at(ROOT)):
		if category in SKIP_DIRS or category.begins_with("."):
			continue
		var files := _texture_files(ROOT.path_join(category))
		var matches: Array[String] = []
		for f in files:
			if _matches(f.get_file().get_basename().to_lower(), words):
				matches.append(f)
		if matches.is_empty():
			continue
		var cat := _tree.create_item(root)
		cat.set_text(0, "%s  (%d)" % [category, matches.size()])
		cat.set_icon(0, folder_icon)
		cat.set_selectable(0, false)
		for path in matches:
			var item := _tree.create_item(cat)
			item.set_text(0, path.get_file().get_basename())
			item.set_metadata(0, path)
			item.set_tooltip_text(0, path)
			var tex := load(path) as Texture2D
			if tex:
				item.set_icon(0, _thumbnail(tex, THUMB))
			if edited_resource and edited_resource.resource_path == path:
				item.select(0)


func _matches(haystack: String, words: PackedStringArray) -> bool:
	for w in words:
		if not haystack.contains(w):
			return false
	return true


## Textures directly in `dir` (.res / .tres), sorted like the FileSystem dock.
func _texture_files(dir: String) -> Array[String]:
	var out: Array[String] = []
	for f in _sorted(DirAccess.get_files_at(dir)):
		var ext := f.get_extension()
		if ext == "res" or ext == "tres":
			out.append(dir.path_join(f))
	return out


func _sorted(names: PackedStringArray) -> PackedStringArray:
	var arr := Array(names)
	arr.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	return PackedStringArray(arr)


func _first_texture_item() -> TreeItem:
	var cat := _tree.get_root().get_first_child()
	while cat:
		if cat.get_first_child():
			return cat.get_first_child()
		cat = cat.get_next()
	return null


func _pick_first() -> void:
	var item := _first_texture_item()
	if item:
		_pick(load(item.get_metadata(0)))


func _on_activated() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var path: String = item.get_metadata(0)
	_pick(null if path.is_empty() else load(path) as Texture2D)


func _thumbnail(tex: Texture2D, px: int) -> Texture2D:
	var img := tex.get_image()
	if img == null:
		return tex
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	var s := float(px * EditorInterface.get_editor_scale()) / maxf(img.get_width(), img.get_height())
	img.resize(maxi(1, int(img.get_width() * s)), maxi(1, int(img.get_height() * s)), Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(img)


# --- Drag and drop from the FileSystem dock ------------------------------------------

func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return _dropped_texture(data) != null


func _drop_data(_at: Vector2, data: Variant) -> void:
	_pick(_dropped_texture(data))


func _dropped_texture(data: Variant) -> Texture2D:
	if data is Dictionary and data.get("type") == "files" and data.files.size() == 1:
		return load(data.files[0]) as Texture2D
	if data is Dictionary and data.get("type") == "resource":
		return data.resource as Texture2D
	return null
