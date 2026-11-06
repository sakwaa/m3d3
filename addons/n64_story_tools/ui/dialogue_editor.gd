@tool
extends HSplitContainer
## The Story workspace's Dialogue tab:
##  - left: the dialogues (res://story/dialogue, Project Settings > n64/story/dialogue_dir),
##    New, and Export CSV (every translatable string, for translators);
##  - middle: the open dialogue as a graph. Start points at the first node; drag from an
##    output (right) to a node's input (left) to link, or onto empty space to add a node
##    there already linked. Right-click adds a node; Delete removes the selected ones;
##    Ctrl+D duplicates them. Lines edit their speaker and text in place, choices their
##    options; branch cases and action effects open in the inspector;
##  - right: the inspector for the selected node (or case / effect / option), a preview of
##    the selected line in the game's text box (pages, ▶ types it with the speaker's
##    voice), and the dialogue's problems (click one to go to its node).
## Every change is undoable and saves by itself.

const Check := preload("res://addons/n64_story_tools/dialogue_check.gd")
const LinePreview := preload("res://addons/n64_story_tools/ui/line_preview.gd")
const PreviewState := preload("res://addons/n64_story_tools/preview_state.gd")
const Export := preload("res://addons/n64_story_tools/translation_export.gd")
const DIR_SETTING := "n64/story/dialogue_dir"
const DEFAULT_DIR := "res://story/dialogue"
const START := &"__start"
const TYPES := ["Line", "Choice", "Branch", "Action", "Jump"]
const PORT := Color(0.85, 0.85, 0.85)

var db: StoryDatabase:
	set(value):
		db = value
		_gs.story = value
var dialogue: Dialogue

var _gs: Node = PreviewState.new()
var _files: Tree
var _search: LineEdit
var _graph: GraphEdit
var _header: Label
var _inspector: EditorInspector
var _inspected: Object
var _preview: Control
var _problems: ItemList
var _add_menu: PopupMenu
var _add_at := Vector2.ZERO
var _pending_link := []  # [from graph node name, port] while adding from a dropped link
var _new_dialog: ConfirmationDialog
var _new_id: LineEdit
var _save_timer: Timer
var _check_timer: Timer
var _last := {}  # the dialogue as last recorded in the undo history
var _rebuild_queued := false
var _status: Label


func _init() -> void:
	name = "Dialogue"
	size_flags_vertical = SIZE_EXPAND_FILL
	var s := EditorInterface.get_editor_scale()
	add_child(_build_file_list(s))
	var right_split := HSplitContainer.new()
	right_split.size_flags_horizontal = SIZE_EXPAND_FILL
	add_child(right_split)

	var middle := VBoxContainer.new()
	middle.size_flags_horizontal = SIZE_EXPAND_FILL
	right_split.add_child(middle)
	var bar := HBoxContainer.new()
	middle.add_child(bar)
	_header = Label.new()
	_header.size_flags_horizontal = SIZE_EXPAND_FILL
	_header.text = "Open or create a dialogue."
	bar.add_child(_header)
	for t in TYPES:
		var b := Button.new()
		b.text = "+ " + t
		b.flat = true
		b.tooltip_text = "Add a %s node" % t.to_lower()
		b.pressed.connect(func(): _add_node(t, _graph_center()))
		bar.add_child(b)
	_graph = GraphEdit.new()
	_graph.size_flags_vertical = SIZE_EXPAND_FILL
	_graph.right_disconnects = true
	_graph.show_zoom_label = true
	_graph.minimap_enabled = false
	_graph.connection_request.connect(_on_connect)
	_graph.disconnection_request.connect(_on_disconnect)
	_graph.connection_to_empty.connect(_on_connect_to_empty)
	_graph.delete_nodes_request.connect(_on_delete)
	_graph.duplicate_nodes_request.connect(_on_duplicate)
	_graph.popup_request.connect(func(at: Vector2):
		_pending_link = []
		_popup_add(at))
	_graph.node_selected.connect(_on_node_selected)
	_graph.end_node_move.connect(_on_moved)
	middle.add_child(_graph)
	_add_menu = PopupMenu.new()
	for i in TYPES.size():
		_add_menu.add_item(TYPES[i], i)
	_add_menu.id_pressed.connect(func(i: int): _add_node(TYPES[i], _add_at, _pending_link))
	add_child(_add_menu)

	var side := VSplitContainer.new()
	side.custom_minimum_size.x = 600 * s * 0.5 + 40 * s
	right_split.add_child(side)
	_inspector = EditorInspector.new()
	_inspector.size_flags_vertical = SIZE_EXPAND_FILL
	_inspector.custom_minimum_size.y = 200 * s
	_inspector.property_edited.connect(_on_inspector_edited)
	side.add_child(_inspector)
	var lower := VBoxContainer.new()
	side.add_child(lower)
	_preview = LinePreview.new()
	_preview.gs = _gs
	_preview.visible = false
	lower.add_child(_preview)
	var plabel := Label.new()
	plabel.text = "Problems"
	lower.add_child(plabel)
	_problems = ItemList.new()
	_problems.custom_minimum_size.y = 110 * s
	_problems.size_flags_vertical = SIZE_EXPAND_FILL
	_problems.item_selected.connect(_on_problem_selected)
	lower.add_child(_problems)

	_save_timer = _timer(0.5, save)
	_check_timer = _timer(0.3, _check)


func _ready() -> void:
	add_child(_gs)


func _timer(wait: float, action: Callable) -> Timer:
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = wait
	t.timeout.connect(action)
	add_child(t)
	return t


func _build_file_list(s: float) -> Control:
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 220 * s
	var bar := HBoxContainer.new()
	left.add_child(bar)
	var new_btn := Button.new()
	new_btn.text = "New"
	new_btn.pressed.connect(func():
		_new_id.text = ""
		_new_dialog.popup_centered()
		_new_id.grab_focus())
	bar.add_child(new_btn)
	var export_btn := Button.new()
	export_btn.text = "Export CSV"
	export_btn.tooltip_text = "Write every translatable string to %s (keeps existing translations)" % Export.DEFAULT_PATH
	export_btn.pressed.connect(export_translations)
	bar.add_child(export_btn)
	_search = LineEdit.new()
	_search.placeholder_text = "Search dialogues"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t): refresh_files())
	left.add_child(_search)
	_files = Tree.new()
	_files.hide_root = true
	_files.size_flags_vertical = SIZE_EXPAND_FILL
	_files.item_selected.connect(func():
		var it := _files.get_selected()
		if it and it.get_metadata(0):
			open_dialogue(it.get_metadata(0)))
	left.add_child(_files)
	_status = Label.new()
	_status.modulate.a = 0.6
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_status)

	_new_dialog = ConfirmationDialog.new()
	_new_dialog.title = "New dialogue"
	var box := VBoxContainer.new()
	var hint := Label.new()
	hint.text = "Id (also the file name and the translation key prefix):"
	box.add_child(hint)
	_new_id = LineEdit.new()
	_new_id.placeholder_text = "postkeeper_day1"
	_new_id.text_submitted.connect(func(_t):
		_new_dialog.hide()
		_create_dialogue(_new_id.text))
	box.add_child(_new_id)
	_new_dialog.add_child(box)
	_new_dialog.confirmed.connect(func(): _create_dialogue(_new_id.text))
	left.add_child(_new_dialog)
	return left


# --- Files --------------------------------------------------------------------------

static func dialogue_dir() -> String:
	return str(ProjectSettings.get_setting(DIR_SETTING, DEFAULT_DIR)).trim_suffix("/")


## Every dialogue in the dialogue folder: [path, …].
static func dialogue_paths() -> PackedStringArray:
	var out := PackedStringArray()
	_collect(dialogue_dir(), out)
	out.sort()
	return out


static func _collect(dir: String, out: PackedStringArray) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		if f.ends_with(".tres") and ResourceLoader.load(dir.path_join(f)) is Dialogue:
			out.append(dir.path_join(f))
	for sub in da.get_directories():
		_collect(dir.path_join(sub), out)


func refresh_files() -> void:
	_files.clear()
	var root := _files.create_item()
	var filter := _search.text.strip_edges().to_lower()
	var base := dialogue_dir() + "/"
	for path in dialogue_paths():
		var rel := path.trim_prefix(base).trim_suffix(".tres")
		if filter != "" and not rel.to_lower().contains(filter):
			continue
		var it := _files.create_item(root)
		it.set_text(0, rel)
		it.set_metadata(0, path)
		if dialogue and dialogue.resource_path == path:
			it.select(0)


func _create_dialogue(id: String) -> void:
	id = id.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
	if id == "" or not id.is_valid_ascii_identifier():
		return
	var path := dialogue_dir().path_join(id + ".tres")
	if FileAccess.file_exists(path):
		_status.text = "%s already exists." % path
		open_dialogue(path)
		return
	var d := Dialogue.new()
	d.id = id
	var first := DialogueLine.new()
	first.id = "n1"
	d.nodes.append(first)
	d.start = "n1"
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	ResourceSaver.save(d, path)
	EditorInterface.get_resource_filesystem().update_file(path)
	refresh_files()
	open_dialogue(path)


func open_dialogue(path: String) -> void:
	if dialogue and dialogue.resource_path == path:
		return
	if dialogue and not _save_timer.is_stopped():
		save()
	dialogue = ResourceLoader.load(path) as Dialogue
	if dialogue == null:
		return
	_last = _snapshot()
	_header.text = "%s  (%s)" % [dialogue.id, path]
	_inspect(null)
	_rebuild_graph()
	refresh_files()


func save() -> void:
	_save_timer.stop()
	if dialogue == null:
		return
	var err := ResourceSaver.save(dialogue, dialogue.resource_path)
	if err != OK:
		push_error("Story: couldn't save %s (%s)" % [dialogue.resource_path, error_string(err)])


func export_translations() -> void:
	save()
	var dialogues := []
	for p in dialogue_paths():
		dialogues.append(ResourceLoader.load(p))
	var path := str(ProjectSettings.get_setting(Export.SETTING, Export.DEFAULT_PATH))
	var n := Export.export_csv(path, db, dialogues)
	var efs := EditorInterface.get_resource_filesystem()
	# The scan (re)imports the CSV into .translation files, then they're registered.
	if efs.is_scanning():
		await efs.filesystem_changed
	efs.scan()
	await efs.filesystem_changed
	Export.register(path)
	_status.text = "Exported %d strings to %s" % [n, path]


# --- Undo ---------------------------------------------------------------------------

func _snapshot() -> Dictionary:
	return {
		start = dialogue.start,
		start_position = dialogue.start_position,
		id = dialogue.id,
		nodes = dialogue.nodes.map(func(n): return n.duplicate_deep() if n else null),
	}


func _restore(snap: Dictionary, path: String) -> void:
	if dialogue == null or dialogue.resource_path != path:
		open_dialogue(path)
	var keep := _inspected_id()
	dialogue.start = snap.start
	dialogue.start_position = snap.start_position
	dialogue.id = snap.id
	dialogue.nodes.assign(snap.nodes.map(func(n): return n.duplicate_deep() if n else null))
	_last = snap
	_rebuild_graph()
	_inspect(dialogue.find(keep) if keep != "" else null)
	_save_timer.start()


## Records the change just made to `dialogue` (undo goes back to the previous record).
## Successive changes with the same `merge_key` (typing in one field) undo together.
func _changed(action: String, merge_key := "") -> void:
	var after := _snapshot()
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action(action + ((" " + merge_key) if merge_key != "" else ""),
		UndoRedo.MERGE_ENDS if merge_key != "" else UndoRedo.MERGE_DISABLE, dialogue)
	ur.add_do_method(self, &"_restore", after, dialogue.resource_path)
	ur.add_undo_method(self, &"_restore", _last, dialogue.resource_path)
	ur.commit_action(false)
	_last = after
	_save_timer.start()
	_check_timer.start()


func _inspected_id() -> String:
	return _inspected.id if _inspected is DialogueNode else ""


# --- Graph --------------------------------------------------------------------------

func _queue_rebuild() -> void:
	if not _rebuild_queued:
		_rebuild_queued = true
		_rebuild_graph.call_deferred()


func _rebuild_graph() -> void:
	_rebuild_queued = false
	var selected := []
	for c in _graph.get_children():
		if c is GraphNode:
			if c.selected:
				selected.append(c.name)
			_graph.remove_child(c)
			c.queue_free()
	if dialogue == null:
		_problems.clear()
		return
	_graph.add_child(_start_node())
	for n in dialogue.nodes:
		if n:
			_graph.add_child(_graph_node(n))
	for name in selected:
		var g := _graph.get_node_or_null(NodePath(name))
		if g:
			g.selected = true
	_rebuild_connections()
	_check()


func _rebuild_connections() -> void:
	_graph.clear_connections()
	if dialogue.start != "" and _graph.has_node(NodePath(dialogue.start)):
		_graph.connect_node(START, 0, StringName(dialogue.start), 0)
	for n in dialogue.nodes:
		if n == null:
			continue
		var outs := Check.outputs(dialogue, n)
		for i in outs.size():
			var to: String = outs[i][0].get(outs[i][1])
			if to != "" and _graph.has_node(NodePath(to)):
				_graph.connect_node(StringName(n.id), i, StringName(to), 0)


func _start_node() -> GraphNode:
	var g := GraphNode.new()
	g.name = START
	g.title = "Start"
	g.position_offset = dialogue.start_position
	var l := Label.new()
	l.text = "conversation starts"
	g.add_child(l)
	g.set_slot(0, false, 0, PORT, true, 0, PORT)
	_title_color(g, Color(0.3, 0.55, 0.35))
	return g


func _graph_node(n: DialogueNode) -> GraphNode:
	var g := GraphNode.new()
	g.name = n.id
	g.position_offset = n.graph_position
	g.set_meta(&"node", n)
	if n is DialogueLine:
		_build_line(g, n)
	elif n is DialogueChoice:
		_build_choice(g, n)
	elif n is DialogueBranch:
		_build_branch(g, n)
	elif n is DialogueAction:
		_build_action(g, n)
	elif n is DialogueJump:
		_build_jump(g, n)
	return g


func _build_line(g: GraphNode, n: DialogueLine) -> void:
	var who: CharacterDef = db.find_character(n.speaker) if db and n.speaker != &"" else null
	g.title = "%s  %s%s" % [n.id, "Narration" if n.style == DialogueLine.Style.NARRATION else "Line",
		" (name hidden)" if n.hide_name else ""]
	_title_color(g, who.name_color.darkened(0.45) if who else Color(0.3, 0.3, 0.34))
	var speaker := OptionButton.new()
	speaker.fit_to_longest_item = false
	speaker.add_item("(no one)")
	speaker.set_item_metadata(0, "")
	if db:
		for id in db.character_ids():
			speaker.add_item(db.find_character(StringName(id)).get_display_name())
			speaker.set_item_metadata(speaker.item_count - 1, id)
			if StringName(id) == n.speaker:
				speaker.select(speaker.item_count - 1)
	if n.speaker != &"" and who == null:
		speaker.add_item("? %s" % n.speaker)
		speaker.set_item_metadata(speaker.item_count - 1, String(n.speaker))
		speaker.select(speaker.item_count - 1)
	speaker.item_selected.connect(func(i: int):
		n.speaker = StringName(speaker.get_item_metadata(i))
		_changed("Change speaker")
		_queue_rebuild()
		_show_preview(n))
	g.add_child(speaker)
	g.set_slot(0, true, 0, PORT, true, 0, PORT)
	var text := TextEdit.new()
	text.text = n.text
	text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	text.custom_minimum_size = Vector2(320, 96) * EditorInterface.get_editor_scale()
	text.placeholder_text = "What they say. A blank line starts a new page."
	text.text_changed.connect(func():
		n.text = text.text
		_changed("Edit line", n.id)
		if _inspected == n:
			_show_preview(n))
	text.focus_entered.connect(func(): _inspect(n))
	g.add_child(text)


func _build_choice(g: GraphNode, n: DialogueChoice) -> void:
	g.title = "%s  Choice" % n.id
	_title_color(g, Color(0.45, 0.38, 0.15))
	var head := Label.new()
	head.text = "The player picks (the line before stays up):"
	g.add_child(head)
	g.set_slot(0, true, 0, PORT, false, 0, PORT)
	for i in n.options.size():
		var o: DialogueOption = n.options[i]
		if o == null:
			continue
		var row := HBoxContainer.new()
		var edit := LineEdit.new()
		edit.text = o.text
		edit.placeholder_text = "Answer"
		edit.size_flags_horizontal = SIZE_EXPAND_FILL
		edit.custom_minimum_size.x = 220 * EditorInterface.get_editor_scale()
		edit.text_changed.connect(func(t: String):
			o.text = t
			_changed("Edit option", "%s.%s" % [n.id, o.id]))
		row.add_child(edit)
		var more := _icon_button("Tools", "Conditions, cancel (%d condition%s)" % [o.conditions.size(), "" if o.conditions.size() == 1 else "s"],
			func(): _inspect(o))
		if not o.conditions.is_empty():
			more.text = str(o.conditions.size())
		row.add_child(more)
		row.add_child(_icon_button("Remove", "Remove option", func():
			n.options.erase(o)
			_changed("Remove option")
			_queue_rebuild()))
		g.add_child(row)
		g.set_slot(g.get_child_count() - 1, false, 0, PORT, true, 0, PORT)
	var add := Button.new()
	add.text = "+ Option"
	add.pressed.connect(func():
		var o := DialogueOption.new()
		var k := 1
		while n.options.any(func(x): return x and x.id == "o%d" % k):
			k += 1
		o.id = "o%d" % k
		n.options.append(o)
		_changed("Add option")
		_queue_rebuild())
	g.add_child(add)


func _build_branch(g: GraphNode, n: DialogueBranch) -> void:
	g.title = "%s  Branch" % n.id
	_title_color(g, Color(0.22, 0.35, 0.55))
	var head := Label.new()
	head.text = "First case that passes:"
	g.add_child(head)
	g.set_slot(0, true, 0, PORT, false, 0, PORT)
	for c in n.cases:
		if c == null:
			continue
		var row := HBoxContainer.new()
		var b := Button.new()
		b.text = "if " + (" and ".join(c.conditions.filter(func(x): return x).map(func(x): return x.describe())) if not c.conditions.is_empty() else "(always)")
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = SIZE_EXPAND_FILL
		b.tooltip_text = "Edit this case's conditions"
		b.pressed.connect(func(): _inspect(c))
		row.add_child(b)
		row.add_child(_icon_button("Remove", "Remove case", func():
			n.cases.erase(c)
			_changed("Remove case")
			_queue_rebuild()))
		g.add_child(row)
		g.set_slot(g.get_child_count() - 1, false, 0, PORT, true, 0, PORT)
	var otherwise := Label.new()
	otherwise.text = "else"
	otherwise.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	g.add_child(otherwise)
	g.set_slot(g.get_child_count() - 1, false, 0, PORT, true, 0, PORT)
	var add := Button.new()
	add.text = "+ Case"
	add.pressed.connect(func():
		var c := DialogueCase.new()
		c.conditions.append(StoryCondition.new())
		n.cases.append(c)
		_changed("Add case")
		_queue_rebuild()
		_inspect(c))
	g.add_child(add)


func _build_action(g: GraphNode, n: DialogueAction) -> void:
	g.title = "%s  Action" % n.id
	_title_color(g, Color(0.5, 0.25, 0.4))
	var list := Label.new()
	list.text = "\n".join(n.effects.filter(func(e): return e).map(func(e): return e.describe())) if not n.effects.is_empty() else "(no effects)"
	g.add_child(list)
	g.set_slot(0, true, 0, PORT, true, 0, PORT)
	var add := Button.new()
	add.text = "+ Effect"
	add.pressed.connect(func():
		var e := StoryEffect.new()
		n.effects.append(e)
		_changed("Add effect")
		_queue_rebuild()
		_inspect(e))
	g.add_child(add)


func _build_jump(g: GraphNode, n: DialogueJump) -> void:
	g.title = "%s  Jump" % n.id
	_title_color(g, Color(0.35, 0.35, 0.35))
	var l := Label.new()
	l.text = "→ %s%s" % [n.dialogue.id if n.dialogue else "(pick a dialogue)", (" : " + n.entry) if n.entry != "" else ""]
	g.add_child(l)
	g.set_slot(0, true, 0, PORT, false, 0, PORT)
	if n.dialogue:
		var open := Button.new()
		open.text = "Open"
		open.pressed.connect(func(): open_dialogue.call_deferred(n.dialogue.resource_path))
		g.add_child(open)


func _icon_button(icon: StringName, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.flat = true
	b.icon = EditorInterface.get_editor_theme().get_icon(icon, &"EditorIcons")
	b.tooltip_text = tip
	b.pressed.connect(action)
	return b


static func _title_color(g: GraphNode, color: Color) -> void:
	for state in [&"titlebar", &"titlebar_selected"]:
		var base := g.get_theme_stylebox(state)
		var sb: StyleBoxFlat = base.duplicate() if base is StyleBoxFlat else StyleBoxFlat.new()
		sb.bg_color = color.lightened(0.15) if state == &"titlebar_selected" else color
		g.add_theme_stylebox_override(state, sb)


func _graph_center() -> Vector2:
	return (_graph.scroll_offset + _graph.size * 0.5) / _graph.zoom


func _popup_add(at: Vector2) -> void:
	_add_at = (_graph.scroll_offset + at) / _graph.zoom
	_add_menu.position = Vector2i(_graph.get_screen_position() + at)
	_add_menu.reset_size()
	_add_menu.popup()


func _add_node(type: String, at: Vector2, link := []) -> void:
	if dialogue == null:
		return
	var n: DialogueNode
	match type:
		"Line": n = DialogueLine.new()
		"Choice":
			n = DialogueChoice.new()
			for k in 2:
				var o := DialogueOption.new()
				o.id = "o%d" % (k + 1)
				n.options.append(o)
		"Branch": n = DialogueBranch.new()
		"Action": n = DialogueAction.new()
		_: n = DialogueJump.new()
	n.id = dialogue.free_id()
	n.graph_position = at.snapped(Vector2(20, 20))
	# A new line keeps the speaker of the line it continues from.
	if n is DialogueLine and not link.is_empty():
		var from = _node_by_name(link[0])
		if from is DialogueLine:
			n.speaker = from.speaker
	dialogue.nodes.append(n)
	if not link.is_empty():
		_set_link(link[0], link[1], n.id)
	if dialogue.start == "":
		dialogue.start = n.id
	_changed("Add %s" % type.to_lower())
	_rebuild_graph()
	_inspect(n)
	var g := _graph.get_node_or_null(NodePath(n.id))
	if g:
		_graph.set_selected(g)


func _node_by_name(name: StringName) -> DialogueNode:
	return null if name == START else dialogue.find(String(name))


## Points output `port` of graph node `from` at node id `to` ("" = unlink).
func _set_link(from: StringName, port: int, to: String) -> bool:
	var outs := Check.outputs(dialogue, _node_by_name(from)) if from != START else Check.outputs(dialogue, null)
	if port < 0 or port >= outs.size():
		return false
	outs[port][0].set(outs[port][1], to)
	return true


func _on_connect(from: StringName, from_port: int, to: StringName, _to_port: int) -> void:
	if to == START or not _set_link(from, from_port, String(to)):
		return
	_changed("Link")
	_rebuild_connections()
	_check()


func _on_disconnect(from: StringName, from_port: int, _to: StringName, _to_port: int) -> void:
	if _set_link(from, from_port, ""):
		_changed("Unlink")
		_rebuild_connections()
		_check()


func _on_connect_to_empty(from: StringName, from_port: int, release: Vector2) -> void:
	_pending_link = [from, from_port]
	_popup_add(release)


func _on_delete(names: Array) -> void:
	var gone := {}
	for name in names:
		if name != START:
			gone[String(name)] = true
	if gone.is_empty():
		return
	dialogue.nodes.assign(dialogue.nodes.filter(func(n): return n and not gone.has(n.id)))
	# Links into deleted nodes are cleared.
	for n in [null] + Array(dialogue.nodes):
		for o in Check.outputs(dialogue, n):
			if gone.has(o[0].get(o[1])):
				o[0].set(o[1], "")
	_changed("Delete nodes")
	_inspect(null)
	_rebuild_graph()


func _on_duplicate() -> void:
	var made := []
	for c in _graph.get_children():
		if c is GraphNode and c.selected and c.name != START:
			var n: DialogueNode = _node_by_name(c.name).duplicate_deep()
			n.id = dialogue.free_id()
			n.graph_position += Vector2(40, 40)
			for o in Check.outputs(dialogue, n):
				o[0].set(o[1], "")
			dialogue.nodes.append(n)
			made.append(n.id)
	if made.is_empty():
		return
	_changed("Duplicate nodes")
	_rebuild_graph()
	for c in _graph.get_children():
		if c is GraphNode:
			c.selected = made.has(String(c.name))


func _on_moved() -> void:
	for c in _graph.get_children():
		if c is GraphNode and c.selected:
			if c.name == START:
				dialogue.start_position = c.position_offset
			else:
				var n := _node_by_name(c.name)
				if n:
					n.graph_position = c.position_offset
	_changed("Move nodes")


func _on_node_selected(g: Node) -> void:
	if g.name == START:
		_inspect(dialogue)
	else:
		_inspect(_node_by_name(g.name))


# --- Inspector, preview, problems ---------------------------------------------------

func _inspect(obj: Object) -> void:
	_inspected = obj
	_inspector.edit(obj)
	_show_preview(obj if obj is DialogueLine else null)


func _show_preview(line: DialogueLine) -> void:
	_preview.visible = line != null
	if line:
		_preview.show_line(line)


func _on_inspector_edited(_property: String) -> void:
	if dialogue == null:
		return
	if _inspected == dialogue:
		_header.text = "%s  (%s)" % [dialogue.id, dialogue.resource_path]
	_changed("Edit %s" % _property)
	_queue_rebuild()
	if _inspected is DialogueLine:
		_show_preview(_inspected)


func _check() -> void:
	_problems.clear()
	if dialogue == null:
		return
	var found := Check.problems(dialogue, db, _gs)
	var marked := {}
	var theme := EditorInterface.get_editor_theme()
	for p in found:
		var i := _problems.add_item(("%s: " % p.node if p.node != "" else "") + p.text,
			theme.get_icon(&"StatusError" if p.error else &"StatusWarning", &"EditorIcons"))
		_problems.set_item_metadata(i, p.node)
		if p.node != "":
			marked[p.node] = marked.get(p.node, false) or p.error
	for c in _graph.get_children():
		if c is GraphNode:
			var id := String(c.name)
			c.self_modulate = (Color(1, 0.6, 0.6) if marked[id] else Color(1, 0.9, 0.6)) if marked.has(id) else Color.WHITE
	if found.is_empty():
		_problems.add_item("No problems.")


func _on_problem_selected(i: int) -> void:
	var id: String = _problems.get_item_metadata(i) if _problems.get_item_metadata(i) else ""
	var g := _graph.get_node_or_null(NodePath(id)) if id != "" else null
	if g:
		_graph.set_selected(g)
		_graph.scroll_offset = g.position_offset * _graph.zoom - _graph.size * 0.5 + g.size * 0.5
		_inspect(_node_by_name(g.name))
