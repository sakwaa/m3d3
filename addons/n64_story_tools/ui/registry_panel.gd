@tool
extends HSplitContainer
## One list of the story database (items or flags): a searchable tree on the left with
## add / duplicate / delete, the selected entry's inspector on the right. Entries with an
## empty or duplicate id are shown in red. Adding / deleting goes through the editor's
## undo history; inspector edits do too (the workspace saves after either).

signal edited

var db: StoryDatabase
## The database property this panel lists ("items" / "flags").
var property := ""
var noun := ""
## () -> Resource: a fresh entry.
var make_new: Callable
## (entry) -> PackedStringArray: column texts.
var row_text: Callable
## (entry) -> String: tree group (folder) for the entry, or "" for top level.
var group_of: Callable
var columns := PackedStringArray()

var _tree: Tree
var _search: LineEdit
var _inspector: EditorInspector
var _empty: Label
var _selected: Resource


func setup(p_property: String, p_noun: String, p_columns: PackedStringArray, p_make: Callable, p_row: Callable, p_group := Callable()) -> void:
	property = p_property
	noun = p_noun
	columns = p_columns
	make_new = p_make
	row_text = p_row
	group_of = p_group
	name = p_property.capitalize()
	size_flags_vertical = SIZE_EXPAND_FILL
	var s := EditorInterface.get_editor_scale()
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 380 * s
	add_child(left)
	var bar := HBoxContainer.new()
	left.add_child(bar)
	_search = LineEdit.new()
	_search.placeholder_text = "Search %ss" % noun
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t): refresh())
	bar.add_child(_search)
	_button(bar, "Add", "Add", add_entry)
	_button(bar, "Duplicate", "Duplicate", duplicate_selected)
	_button(bar, "Remove", "Remove", remove_selected)
	_tree = Tree.new()
	_tree.columns = columns.size()
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.size_flags_vertical = SIZE_EXPAND_FILL
	for c in columns.size():
		_tree.set_column_title(c, columns[c])
		_tree.set_column_expand(c, c == 0)
		_tree.set_column_custom_minimum_width(c, 110 * s)
	_tree.item_selected.connect(_on_select)
	left.add_child(_tree)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	add_child(right)
	_empty = Label.new()
	_empty.text = "Select a %s, or Add one." % noun
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.size_flags_vertical = SIZE_EXPAND_FILL
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	right.add_child(_empty)
	_inspector = EditorInspector.new()
	_inspector.size_flags_vertical = SIZE_EXPAND_FILL
	_inspector.property_edited.connect(func(_p): edited.emit())
	right.add_child(_inspector)
	_inspector.visible = false


func _button(bar: Control, icon: StringName, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.icon = EditorInterface.get_editor_theme().get_icon(icon, &"EditorIcons")
	b.tooltip_text = "%s %s" % [tip, noun]
	b.flat = true
	b.pressed.connect(action)
	bar.add_child(b)
	return b


func entries() -> Array:
	return db.get(property) if db else []


func set_database(p_db: StoryDatabase) -> void:
	db = p_db
	select(null)
	refresh()


func refresh() -> void:
	_tree.clear()
	if db == null:
		return
	var root := _tree.create_item()
	var counts := {}
	for e in entries():
		if e:
			var id := String(e.id)
			counts[id] = counts.get(id, 0) + 1
	var filter := _search.text.strip_edges().to_lower()
	var sorted := entries().filter(func(e): return e != null)
	sorted.sort_custom(func(a, b): return String(a.id).naturalnocasecmp_to(String(b.id)) < 0)
	var groups := {}
	var warn := EditorInterface.get_editor_theme().get_color(&"error_color", &"Editor")
	for e in sorted:
		var texts: PackedStringArray = row_text.call(e)
		if filter != "" and not (String(e.id).to_lower().contains(filter) or texts[0].to_lower().contains(filter)):
			continue
		var parent := root
		var group: String = group_of.call(e) if group_of.is_valid() else ""
		if group != "":
			if not groups.has(group):
				var g := _tree.create_item(root)
				g.set_text(0, group + "/")
				g.set_selectable(0, false)
				for c in range(1, columns.size()):
					g.set_selectable(c, false)
				groups[group] = g
			parent = groups[group]
		var it := _tree.create_item(parent)
		for c in columns.size():
			it.set_text(c, texts[c] if c < texts.size() else "")
		it.set_metadata(0, e)
		var id := String(e.id)
		if id == "" or counts.get(id, 0) > 1:
			for c in columns.size():
				it.set_custom_color(c, warn)
			it.set_tooltip_text(0, "Empty id" if id == "" else "Duplicate id: %s" % id)
		if e == _selected:
			it.select(0)
			_tree.scroll_to_item(it)


func select(entry: Resource) -> void:
	_selected = entry
	_inspector.visible = entry != null
	_empty.visible = entry == null
	_inspector.edit(entry)


func _on_select() -> void:
	var it := _tree.get_selected()
	var e = it.get_metadata(0) if it else null
	if e != _selected:
		select(e)


func add_entry() -> void:
	var e: Resource = make_new.call()
	_commit("Add %s" % noun, entries().duplicate() + [e], e)


func duplicate_selected() -> void:
	if _selected == null:
		return
	var e: Resource = _selected.duplicate()
	e.id = _unique_id(String(_selected.id))
	_commit("Duplicate %s" % noun, entries().duplicate() + [e], e)


func remove_selected() -> void:
	if _selected == null:
		return
	var list := entries().duplicate()
	list.erase(_selected)
	_commit("Remove %s" % noun, list, null)


## Free id: `base` with a number on the end.
func _unique_id(base: String) -> String:
	var ids := entries().map(func(e): return String(e.id) if e else "")
	var stem := base.rstrip("0123456789")
	var n := 2
	while ids.has("%s%d" % [stem, n]):
		n += 1
	return "%s%d" % [stem, n]


func _commit(action: String, list: Array, select_after: Resource) -> void:
	var typed: Array = entries().duplicate()  # keeps the property's array type
	typed.assign(list)
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action(action, UndoRedo.MERGE_DISABLE, db)
	ur.add_do_property(db, property, typed)
	ur.add_undo_property(db, property, entries().duplicate())
	ur.add_do_method(self, &"_after_change", select_after)
	ur.add_undo_method(self, &"_after_change", _selected)
	ur.commit_action()


func _after_change(entry: Resource) -> void:
	db.reindex()
	select(entry if entry and entries().has(entry) else null)
	refresh()
	edited.emit()
