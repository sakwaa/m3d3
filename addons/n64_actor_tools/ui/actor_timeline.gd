@tool
extends HSplitContainer
## Bottom panel "Actor Animation": the character's animations and a timeline.
##  - Left: animation list (new, new from selected, mirrored copy, generate a starter
##    cycle, rename, delete) and its settings (fps, length, loop).
##  - Toolbar: playback, keys (key, delete, ease of selected keys, in-betweens, close
##    loop, retime), clipboard (pose / keys, mirrored, across characters of a body plan),
##    pose library, windows and events.
##  - Timeline: frame ruler, keys (diamonds coloured by ease; click selects, Shift adds,
##    drag moves, Alt+drag copies), playhead (click / drag to scrub), window bars (drag
##    ends / middle), event flags.
## Keys (timeline focused): Space play, ←/→ frame, ↑/↓ previous / next key, K key,
## Delete removes selected keys, Ctrl+C / Ctrl+V copy / paste keys, Ctrl+Shift+V mirrored.
## Posing with auto-key on writes a key at the playhead.

const RULER := 22.0
const KEY_ROW := 30.0
const WINDOW_ROW := 18.0
const EVENT_ROW := 20.0
const GUTTER := 70.0

var plugin: EditorPlugin
var model: ActorModel

var playing := false
var auto_key := true
var selected_keys: Array[int] = []  # frames

var _list: ItemList
var _name: LineEdit
var _fps: SpinBox
var _length: SpinBox
var _loop: CheckBox
var _gen: OptionButton
var _canvas: Control
var _frame_label: Label
var _ease: OptionButton
var _onion: CheckBox
var _auto: CheckBox
var _window_pick: OptionButton
var _event_name: LineEdit
var _pose_lib: OptionButton
var _pose_name: LineEdit
var _updating := false

# Canvas drag state.
var _drag := ""  # "", "scrub", "keys", "window_start", "window_end", "window_move"
var _drag_from := 0
var _drag_window := ""
var _drag_copy := false
var _drag_before: Dictionary = {}
var _drag_window_orig := Vector2i.ZERO


func _init() -> void:
	name = "Actor Animation"
	custom_minimum_size.y = 230 * EditorInterface.get_editor_scale()
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 230 * EditorInterface.get_editor_scale()
	add_child(left)
	_list = ItemList.new()
	_list.size_flags_vertical = SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_anim_selected)
	left.add_child(_list)
	var lb := HFlowContainer.new()
	left.add_child(lb)
	_btn(lb, "New", _new_anim, "Empty animation (one key: the current pose)")
	_btn(lb, "New from", _duplicate_anim, "Copy of the selected animation")
	_btn(lb, "Mirrored copy", _mirror_anim, "Copy with left and right swapped")
	_btn(lb, "Delete", _delete_anim)
	var io := HFlowContainer.new()
	left.add_child(io)
	_btn(io, "Import…", func(): _file_dialog(EditorFileDialog.FILE_MODE_OPEN_FILE, ["*.tres ; Animation"], _import_anim),
		"Add an animation saved as a .tres (Export, or the reference tools)")
	_btn(io, "Export…", func(): _file_dialog(EditorFileDialog.FILE_MODE_SAVE_FILE, ["*.tres ; Animation"], _export_anim),
		"Save the selected animation as a .tres (to share between characters, or keep a version)")
	_btn(io, "From spec…", func(): _file_dialog(EditorFileDialog.FILE_MODE_OPEN_FILE, ["*.json ; Animation spec"], _spec_anim),
		"Build an animation from a spec of key poses as joint angles (tools/anim_ref: measured from video)")
	var gr := HBoxContainer.new()
	left.add_child(gr)
	_gen = OptionButton.new()
	_gen.size_flags_horizontal = SIZE_EXPAND_FILL
	gr.add_child(_gen)
	_btn(gr, "Generate", _generate, "Starter cycle from the character's IK")
	var props := GridContainer.new()
	props.columns = 2
	left.add_child(props)
	_name = LineEdit.new()
	_name.text_submitted.connect(func(_t): _apply_props())
	_name.focus_exited.connect(_apply_props)
	_prop(props, "Name", _name)
	_fps = _spin(1, 60, 1)
	_fps.value_changed.connect(func(_v): _apply_props())
	_prop(props, "FPS", _fps)
	_length = _spin(1, 600, 1)
	_length.value_changed.connect(func(_v): _apply_props())
	_prop(props, "Frames", _length)
	_loop = CheckBox.new()
	_loop.text = "Loop"
	_loop.toggled.connect(func(_on): _apply_props())
	_prop(props, "", _loop)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	add_child(right)
	var t1 := HFlowContainer.new()
	right.add_child(t1)
	_btn(t1, "⏮", func(): _go(0))
	_btn(t1, "◆◀", func(): _jump_key(-1), "Previous key (↑)")
	_btn(t1, "◀", func(): _go(int(model.frame) - 1), "Previous frame (←)")
	_btn(t1, "▶ / ❚❚", _toggle_play, "Play / pause (Space)")
	_btn(t1, "▶", func(): _go(int(model.frame) + 1), "Next frame (→)")
	_btn(t1, "▶◆", func(): _jump_key(1), "Next key (↓)")
	_btn(t1, "⏭", func(): _go(_anim().length - 1 if _anim() else 0))
	_frame_label = Label.new()
	_frame_label.custom_minimum_size.x = 90
	t1.add_child(_frame_label)
	_auto = CheckBox.new()
	_auto.text = "Auto-key"
	_auto.button_pressed = true
	_auto.toggled.connect(func(on): auto_key = on)
	t1.add_child(_auto)
	_onion = CheckBox.new()
	_onion.text = "Onion skin"
	_onion.button_pressed = true
	_onion.toggled.connect(func(on): if model: model.onion = on; model.update_gizmos())
	t1.add_child(_onion)
	var t2 := HFlowContainer.new()
	right.add_child(t2)
	_btn(t2, "Key (K)", key_current, "Key the current pose at the playhead")
	_btn(t2, "Delete keys", _delete_keys)
	_ease = OptionButton.new()
	for e in ActorAnimation.EASE_NAMES:
		_ease.add_item(e)
	_ease.tooltip_text = "Ease of the selected keys (into the next key)"
	_ease.item_selected.connect(_set_ease)
	t2.add_child(_ease)
	for spec in [["¼", 0.25], ["½", 0.5], ["¾", 0.75], ["Overshoot", 1.15]]:
		_btn(t2, spec[0], _inbetween.bind(spec[1]), "In-between key at the playhead, weighted towards the next key")
	_btn(t2, "Close loop", _close_loop, "Last frame matches the first (seamless loops)")
	_btn(t2, "Retime ×½", _retime.bind(0.5), "Halve the spacing of the selected keys")
	_btn(t2, "Retime ×2", _retime.bind(2.0), "Double the spacing of the selected keys")
	var t3 := HFlowContainer.new()
	right.add_child(t3)
	_btn(t3, "Copy pose", _copy_pose)
	_btn(t3, "Paste pose", _paste.bind(false, false))
	_btn(t3, "Paste mirrored", _paste.bind(true, false))
	_btn(t3, "Copy keys", _copy_keys, "Selected keys (relative spacing kept)")
	_btn(t3, "Paste keys", _paste.bind(false, true), "At the playhead")
	_btn(t3, "Paste keys mirrored", _paste.bind(true, true), "At the playhead, left ↔ right (other half of a walk)")
	_pose_lib = OptionButton.new()
	_pose_lib.custom_minimum_size.x = 120
	t3.add_child(_pose_lib)
	_btn(t3, "Apply pose", _apply_library_pose)
	_pose_name = LineEdit.new()
	_pose_name.placeholder_text = "pose name"
	_pose_name.custom_minimum_size.x = 110
	t3.add_child(_pose_name)
	_btn(t3, "Save pose", _save_library_pose, "Into this body plan's shared pose library")
	var t4 := HFlowContainer.new()
	right.add_child(t4)
	_window_pick = OptionButton.new()
	for w in ActorAnimation.WINDOW_PRESETS:
		_window_pick.add_item(w)
	t4.add_child(_window_pick)
	_btn(t4, "Add window", _add_window, "Starts at the playhead; drag its ends on the timeline")
	_btn(t4, "Remove window", _remove_window)
	_event_name = LineEdit.new()
	_event_name.placeholder_text = "event (footstep...)"
	_event_name.custom_minimum_size.x = 130
	t4.add_child(_event_name)
	_btn(t4, "Add event", _add_event)
	_btn(t4, "Remove event", _remove_event, "At the playhead")
	_canvas = Control.new()
	_canvas.size_flags_vertical = SIZE_EXPAND_FILL
	_canvas.custom_minimum_size.y = 110
	_canvas.focus_mode = Control.FOCUS_ALL
	_canvas.clip_contents = true
	_canvas.draw.connect(_draw_canvas)
	_canvas.gui_input.connect(_canvas_input)
	right.add_child(_canvas)


func set_model(m: ActorModel) -> void:
	model = m
	playing = false
	selected_keys.clear()
	refresh()


func _anim() -> ActorAnimation:
	return model.current_animation() if model else null


func refresh() -> void:
	if model == null:
		return
	_updating = true
	_list.clear()
	for a in model.data.animations:
		_list.add_item("%s  (%d f%s)" % [a.name, a.length, ", loop" if a.loop else ""])
	if model.anim_index >= 0 and model.anim_index < _list.item_count:
		_list.select(model.anim_index)
	var a := _anim()
	_name.editable = a != null
	_fps.editable = a != null
	_length.editable = a != null
	_loop.disabled = a == null
	if a:
		_name.text = a.name
		_fps.value = a.fps
		_length.value = a.length
		_loop.button_pressed = a.loop
	_gen.clear()
	for k in ActorCycles.kinds(model.data.plan):
		_gen.add_item(k)
	_pose_lib.clear()
	var lib := ActorPoseLibrary.open(model.data.plan)
	var names := lib.poses.keys()
	names.sort()
	for n in names:
		_pose_lib.add_item(String(n))
	_updating = false
	_frame_label.text = "Frame %d / %d" % [int(model.frame), a.length if a else 0]
	_canvas.queue_redraw()


func _process(delta: float) -> void:
	if not playing or model == null:
		return
	var a := _anim()
	if a == null:
		playing = false
		return
	var f := model.frame + delta * a.fps
	if f >= a.length:
		f = fposmod(f, a.length) if a.loop else 0.0
	model.show_frame(f)
	_frame_label.text = "Frame %d / %d" % [int(f), a.length]
	_canvas.queue_redraw()


# --- Undo helpers -----------------------------------------------------------------------

func _snapshot(a: ActorAnimation) -> Dictionary:
	return {keys = a.keys.duplicate(true), windows = a.windows.duplicate(true), events = a.events.duplicate(true),
		length = a.length, fps = a.fps, loop = a.loop, name = a.name}


## One undo step around changes to the current animation (fn mutates it in place).
func _edit(label: String, fn: Callable) -> void:
	var a := _anim()
	if a == null:
		return
	var before := _snapshot(a)
	fn.call(a)
	_commit(label, a, before)


func _commit(label: String, a: ActorAnimation, before: Dictionary) -> void:
	var after := _snapshot(a)
	var ur := plugin.get_undo_redo()
	ur.create_action(label)
	for k in after:
		ur.add_do_property(a, k, after[k])
		ur.add_undo_property(a, k, before[k])
	ur.add_do_method(self, &"_after_undo")
	ur.add_undo_method(self, &"_after_undo")
	ur.commit_action()


func _after_undo() -> void:
	if model:
		model.show_frame(model.frame)
	refresh()


## Auto-key from a pose drag: undo ops added to the gizmo's own action.
func add_auto_key_ops(ur: EditorUndoRedoManager) -> void:
	var a := _anim()
	if a == null or not auto_key:
		return
	var before: Array = a.keys.duplicate(true)
	a.set_key(int(model.frame), model.data.pose, model.data.root_offset)
	ur.add_do_property(a, &"keys", a.keys.duplicate(true))
	ur.add_undo_property(a, &"keys", before)
	ur.add_do_method(self, &"_after_undo")
	ur.add_undo_method(self, &"_after_undo")


# --- Animation list -----------------------------------------------------------------------

func _on_anim_selected(i: int) -> void:
	if _updating or model == null:
		return
	model.anim_index = i
	selected_keys.clear()
	model.show_frame(0.0)
	refresh()


func _set_anims(label: String, anims: Array[ActorAnimation], select: int) -> void:
	var ur := plugin.get_undo_redo()
	ur.create_action(label)
	ur.add_do_property(model.data, &"animations", anims)
	ur.add_undo_property(model.data, &"animations", model.data.animations)
	ur.commit_action()
	model.anim_index = select
	model.show_frame(0.0)
	refresh()


func _new_anim() -> void:
	if model == null:
		return
	var a := ActorAnimation.new()
	a.name = _unique("NewAnimation")
	a.set_key(0, model.data.pose, model.data.root_offset)
	var anims := model.data.animations.duplicate()
	anims.append(a)
	_set_anims("New Animation", anims, anims.size() - 1)


func _duplicate_anim() -> void:
	var src := _anim()
	if src == null:
		return
	var a := src.duplicate(true) as ActorAnimation
	a.name = _unique(src.name + "Copy")
	var anims := model.data.animations.duplicate()
	anims.append(a)
	_set_anims("Animation From", anims, anims.size() - 1)


func _mirror_anim() -> void:
	var src := _anim()
	if src == null:
		return
	var anims := model.data.animations.duplicate()
	anims.append(src.mirrored(_unique(src.name + "Mirrored")))
	_set_anims("Mirrored Animation", anims, anims.size() - 1)


func _delete_anim() -> void:
	if _anim() == null:
		return
	var anims := model.data.animations.duplicate()
	anims.remove_at(model.anim_index)
	_set_anims("Delete Animation", anims, mini(model.anim_index, anims.size() - 1))


func _generate() -> void:
	if model == null or _gen.selected < 0:
		return
	var kind := _gen.get_item_text(_gen.selected)
	var a := ActorCycles.generate(model, kind)
	a.name = _unique(a.name)
	var anims := model.data.animations.duplicate()
	anims.append(a)
	_set_anims("Generate %s" % kind, anims, anims.size() - 1)


func _file_dialog(mode: EditorFileDialog.FileMode, filters: PackedStringArray, done: Callable) -> void:
	if model == null:
		return
	var d := EditorFileDialog.new()
	d.file_mode = mode
	d.access = EditorFileDialog.ACCESS_RESOURCES
	d.filters = filters
	d.current_dir = "res://references/anims"
	d.file_selected.connect(func(path: String):
		done.call(path)
		d.queue_free())
	d.canceled.connect(d.queue_free)
	EditorInterface.get_base_control().add_child(d)
	d.popup_file_dialog()


func _import_anim(path: String) -> void:
	var src := load(path) as ActorAnimation
	if src == null:
		push_error("Actor tools: %s isn't an ActorAnimation." % path)
		return
	var a := src.duplicate(true) as ActorAnimation
	a.name = _unique(a.name)
	var anims := model.data.animations.duplicate()
	anims.append(a)
	_set_anims("Import Animation", anims, anims.size() - 1)


func _export_anim(path: String) -> void:
	var a := _anim()
	if a == null:
		return
	var err := ResourceSaver.save(a.duplicate(true), path)
	print("Actor tools: exported %s to %s (%s)" % [a.name, path, error_string(err)])


func _spec_anim(path: String) -> void:
	var spec := ActorAnimSpec.load_spec(path)
	if spec.is_empty():
		push_error("Actor tools: %s isn't a valid animation spec." % path)
		return
	var a := ActorAnimSpec.build(model, spec)
	a.name = _unique(a.name)
	var anims := model.data.animations.duplicate()
	anims.append(a)
	_set_anims("Animation From Spec", anims, anims.size() - 1)


func _unique(base: String) -> String:
	var n := base
	var i := 2
	while model.data.animations.any(func(a): return a.name == n):
		n = "%s%d" % [base, i]
		i += 1
	return n


func _apply_props() -> void:
	var a := _anim()
	if _updating or a == null:
		return
	if a.name == _name.text and a.fps == int(_fps.value) and a.length == int(_length.value) and a.loop == _loop.button_pressed:
		return
	_edit("Animation Settings", func(an):
		an.name = _name.text.strip_edges() if not _name.text.strip_edges().is_empty() else an.name
		an.fps = int(_fps.value)
		an.length = int(_length.value)
		an.loop = _loop.button_pressed)


# --- Playback / keys ------------------------------------------------------------------------

func _go(f: int) -> void:
	var a := _anim()
	if a == null:
		return
	f = posmod(f, a.length) if a.loop else clampi(f, 0, a.length - 1)
	model.show_frame(f)
	refresh()


func _toggle_play() -> void:
	playing = not playing and _anim() != null


func _jump_key(dir: int) -> void:
	var a := _anim()
	if a == null or a.keys.is_empty():
		return
	var f := int(model.frame)
	var frames: Array = a.keys.map(func(k): return k.frame)
	if dir > 0:
		for kf in frames:
			if kf > f:
				_go(kf)
				return
		_go(frames[0])
	else:
		for i in range(frames.size() - 1, -1, -1):
			if frames[i] < f:
				_go(frames[i])
				return
		_go(frames[-1])


func key_current() -> void:
	_edit("Key Pose", func(a): a.set_key(int(model.frame), model.data.pose, model.data.root_offset))


func _delete_keys() -> void:
	var frames: Array[int] = selected_keys.duplicate() if not selected_keys.is_empty() else [int(model.frame)] as Array[int]
	_edit("Delete Keys", func(a):
		for f in frames:
			a.remove_key(f))
	selected_keys.clear()


func _set_ease(e: int) -> void:
	if _updating:
		return
	var frames: Array[int] = selected_keys.duplicate() if not selected_keys.is_empty() else [int(model.frame)] as Array[int]
	_edit("Key Ease", func(a):
		for f in frames:
			var i: int = a.key_index(f)
			if i >= 0:
				a.keys[i].ease = e)


## Breakdown at the playhead between the surrounding keys, `w` toward the next one
## (>1 overshoots).
func _inbetween(w: float) -> void:
	var a := _anim()
	if a == null or a.keys.size() < 2:
		return
	var f := int(model.frame)
	var prev = null
	var next = null
	for k in a.keys:
		if k.frame < f:
			prev = k
		elif k.frame > f and next == null:
			next = k
	if a.loop:
		prev = prev if prev != null else a.keys[-1]
		next = next if next != null else a.keys[0]
	if prev == null or next == null:
		return
	var r := ActorAnimation.blend(prev, next, w)
	_edit("In-between", func(an): an.set_key(f, r.pose, r.root, ActorAnimation.Ease.SMOOTH))
	model.show_frame(f)


func _close_loop() -> void:
	var a := _anim()
	if a == null or a.keys.is_empty():
		return
	# A looping animation wraps to frame 0 by itself; a one-shot gets the first pose on
	# its last frame.
	_edit("Close Loop", func(an):
		if an.loop:
			an.remove_key(an.length)
		else:
			an.set_key(an.length - 1, an.keys[0].pose, an.keys[0].root))


func _retime(factor: float) -> void:
	var a := _anim()
	if a == null or selected_keys.size() < 2:
		push_warning("N64 Actor Tools: select two or more keys to retime.")
		return
	var frames := selected_keys.duplicate()
	frames.sort()
	var first: int = frames[0]
	_edit("Retime Keys", func(an):
		var moved := []
		for f in frames:
			var i: int = an.key_index(f)
			if i >= 0:
				moved.append(an.keys[i])
		for k in moved:
			an.keys.erase(k)
		for k in moved:
			k.frame = first + roundi((k.frame - first) * factor)
			an.remove_key(k.frame)
			an.keys.append(k)
		an.sort_keys()
		an.length = maxi(an.length, an.keys[-1].frame + 1))
	selected_keys.clear()


# --- Clipboard / pose library ---------------------------------------------------------------

func _copy_pose() -> void:
	if model:
		ActorClipboard.copy_pose(model.data.plan, model.data.pose, model.data.root_offset)


func _copy_keys() -> void:
	var a := _anim()
	if a == null:
		return
	var src := a.keys.filter(func(k): return selected_keys.has(k.frame))
	if src.is_empty():
		push_warning("N64 Actor Tools: select keys (click, Shift adds) to copy.")
		return
	ActorClipboard.copy_keys(model.data.plan, src)


## Pastes the clipboard at the playhead (keys: spaced as copied). With no animation open,
## a pasted pose goes to the working pose.
func _paste(mirror: bool, as_keys: bool) -> void:
	if model == null or not ActorClipboard.has_pose():
		return
	var pasted := ActorClipboard.paste(model.bone_names(), mirror)
	var a := _anim()
	if a == null:
		var before := [model.data.pose.duplicate(), model.data.root_offset]
		model.data.pose = pasted[0].pose
		model.data.root_offset = pasted[0].root
		model.apply_pose()
		var ur := plugin.get_undo_redo()
		ur.create_action("Paste Pose")
		ur.add_do_property(model.data, &"pose", model.data.pose.duplicate())
		ur.add_do_property(model.data, &"root_offset", model.data.root_offset)
		ur.add_do_method(model, &"apply_pose")
		ur.add_undo_property(model.data, &"pose", before[0])
		ur.add_undo_property(model.data, &"root_offset", before[1])
		ur.add_undo_method(model, &"apply_pose")
		ur.commit_action(false)
		return
	var at := int(model.frame)
	var list := pasted if as_keys else [pasted[0]]
	_edit("Paste Keys" if as_keys else "Paste Pose", func(an):
		for k in list:
			var f: int = at + int(k.offset)
			if an.loop:
				f = posmod(f, an.length)
			an.set_key(f, k.pose, k.root, k.ease)
			if not an.loop:
				an.length = maxi(an.length, f + 1))
	model.show_frame(at)


func _apply_library_pose() -> void:
	if _pose_lib.selected < 0 or model == null:
		return
	var lib := ActorPoseLibrary.open(model.data.plan)
	var p: Dictionary = lib.poses.get(_pose_lib.get_item_text(_pose_lib.selected), {})
	if p.is_empty():
		return
	ActorClipboard.copy_pose(model.data.plan, p.pose, p.root)
	_paste(false, false)


func _save_library_pose() -> void:
	var n := _pose_name.text.strip_edges()
	if n.is_empty() or model == null:
		return
	var lib := ActorPoseLibrary.open(model.data.plan)
	lib.poses[n] = {pose = model.data.pose.duplicate(), root = model.data.root_offset}
	lib.save_for(model.data.plan)
	EditorInterface.get_resource_filesystem().scan()
	refresh()


# --- Windows / events -------------------------------------------------------------------------

func _add_window() -> void:
	var w := _window_pick.get_item_text(_window_pick.selected)
	var f := int(model.frame)
	_edit("Add Window", func(a): a.windows[w] = Vector2i(f, mini(f + 2, a.length - 1)))


func _remove_window() -> void:
	var w := _window_pick.get_item_text(_window_pick.selected)
	_edit("Remove Window", func(a): a.windows.erase(w))


func _add_event() -> void:
	var n := _event_name.text.strip_edges()
	if n.is_empty():
		return
	var f := int(model.frame)
	_edit("Add Event", func(a): a.events.append({frame = f, name = n}))


func _remove_event() -> void:
	var f := int(model.frame)
	_edit("Remove Event", func(a): a.events = a.events.filter(func(e): return e.frame != f))


# --- Canvas -------------------------------------------------------------------------------------

func _px() -> float:
	var a := _anim()
	return (_canvas.size.x - GUTTER - 12.0) / float(maxi(a.length if a else 20, 1))


func _x(frame: float) -> float:
	return GUTTER + frame * _px()


func _frame_at(x: float) -> int:
	return roundi((x - GUTTER) / _px())


func _window_rows(a: ActorAnimation) -> Array:
	var names := a.windows.keys()
	names.sort_custom(func(x, y): return ActorAnimation.WINDOW_PRESETS.find(x) < ActorAnimation.WINDOW_PRESETS.find(y) if x in ActorAnimation.WINDOW_PRESETS and y in ActorAnimation.WINDOW_PRESETS else String(x) < String(y))
	return names


func _draw_canvas() -> void:
	var c := _canvas
	var font := c.get_theme_default_font()
	c.draw_rect(Rect2(Vector2.ZERO, c.size), Color(0.12, 0.13, 0.15))
	var a := _anim()
	if a == null:
		c.draw_string(font, Vector2(12, 40), "Select or create an animation (left). Generate gives a starter cycle.", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.6))
		return
	var h := c.size.y
	# Ruler: a tick per frame, numbers every 5.
	c.draw_rect(Rect2(0, 0, c.size.x, RULER), Color(0.17, 0.18, 0.21))
	for f in a.length + 1:
		var x := _x(f)
		var major := f % 5 == 0
		c.draw_line(Vector2(x, RULER - (10 if major else 5)), Vector2(x, RULER), Color(1, 1, 1, 0.5 if major else 0.25))
		c.draw_line(Vector2(x, RULER), Vector2(x, h), Color(1, 1, 1, 0.07 if major else 0.03))
		if major:
			c.draw_string(font, Vector2(x + 2, 11), str(f), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.75))
	# Rows' labels.
	c.draw_string(font, Vector2(6, RULER + 19), "Keys", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.7))
	# Ease segments between keys + diamonds.
	var ky := RULER + KEY_ROW * 0.5
	for i in a.keys.size():
		var k: Dictionary = a.keys[i]
		var nx := _x(a.keys[i + 1].frame) if i + 1 < a.keys.size() else (_x(a.length) if a.loop else _x(k.frame))
		c.draw_line(Vector2(_x(k.frame), ky), Vector2(nx, ky), ActorAnimation.EASE_COLORS[k.ease] * Color(1, 1, 1, 0.45), 3.0)
	for k in a.keys:
		var x := _x(k.frame)
		var col: Color = ActorAnimation.EASE_COLORS[k.ease]
		var pts := PackedVector2Array([Vector2(x, ky - 8), Vector2(x + 8, ky), Vector2(x, ky + 8), Vector2(x - 8, ky)])
		c.draw_colored_polygon(pts, col)
		if selected_keys.has(k.frame):
			pts.append(pts[0])
			c.draw_polyline(pts, Color(1, 0.85, 0.1), 2.0)
	# Windows: one row each.
	var y := RULER + KEY_ROW
	for w in _window_rows(a):
		var r: Vector2i = a.windows[w]
		var col: Color = ActorAnimation.WINDOW_COLORS.get(w, Color(0.8, 0.8, 0.8))
		c.draw_string(font, Vector2(6, y + 13), String(w), HORIZONTAL_ALIGNMENT_LEFT, GUTTER - 8, 12, col)
		var rect := Rect2(_x(r.x), y + 3, _x(r.y + 1) - _x(r.x), WINDOW_ROW - 6)
		c.draw_rect(rect, col * Color(1, 1, 1, 0.55))
		c.draw_rect(rect, col, false, 1.0)
		y += WINDOW_ROW
	# Events.
	if not a.events.is_empty():
		c.draw_string(font, Vector2(6, y + 14), "Events", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.7))
		for e in a.events:
			var x := _x(e.frame)
			c.draw_line(Vector2(x, y + 2), Vector2(x, y + EVENT_ROW), Color(0.9, 0.7, 1.0), 2.0)
			c.draw_string(font, Vector2(x + 3, y + 13), String(e.name), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.9, 0.7, 1.0))
	# Playhead.
	var px := _x(model.frame)
	c.draw_line(Vector2(px, 0), Vector2(px, h), Color(1, 0.3, 0.3), 2.0)
	c.draw_rect(Rect2(px - 5, 0, 10, 8), Color(1, 0.3, 0.3))


func _key_under(a: ActorAnimation, pos: Vector2) -> int:
	if pos.y < RULER or pos.y > RULER + KEY_ROW:
		return -1
	for k in a.keys:
		if absf(_x(k.frame) - pos.x) <= 9.0:
			return k.frame
	return -1


## [window name, part ("start" / "end" / "move")] under a point, or [].
func _window_under(a: ActorAnimation, pos: Vector2) -> Array:
	var y := RULER + KEY_ROW
	for w in _window_rows(a):
		if pos.y >= y and pos.y < y + WINDOW_ROW:
			var r: Vector2i = a.windows[w]
			var x0 := _x(r.x)
			var x1 := _x(r.y + 1)
			if absf(pos.x - x0) < 6:
				return [w, "start"]
			if absf(pos.x - x1) < 6:
				return [w, "end"]
			if pos.x > x0 and pos.x < x1:
				return [w, "move"]
		y += WINDOW_ROW
	return []


func _canvas_input(event: InputEvent) -> void:
	var a := _anim()
	if a == null or model == null:
		return
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_canvas.grab_focus()
			var kf := _key_under(a, mb.position)
			var win := _window_under(a, mb.position)
			if kf >= 0:
				if mb.shift_pressed:
					if selected_keys.has(kf):
						selected_keys.erase(kf)
					else:
						selected_keys.append(kf)
				elif not selected_keys.has(kf):
					selected_keys = [kf] as Array[int]
				_drag = "keys"
				_drag_from = kf
				_drag_copy = mb.alt_pressed
				_drag_before = _snapshot(a)
				_go(kf)
			elif not win.is_empty():
				_drag = "window_" + win[1]
				_drag_window = win[0]
				_drag_from = _frame_at(mb.position.x)
				_drag_window_orig = a.windows[win[0]]
				_drag_before = _snapshot(a)
			else:
				if not mb.shift_pressed:
					selected_keys.clear()
				_drag = "scrub"
				_go(_frame_at(mb.position.x))
		else:
			if _drag == "keys" or _drag.begins_with("window"):
				if _snapshot(a) != _drag_before:
					_commit("Move Keys" if _drag == "keys" else "Edit Window", a, _drag_before)
			_drag = ""
		_canvas.queue_redraw()
		_canvas.accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm and _drag != "":
		var f := _frame_at(mm.position.x)
		match _drag:
			"scrub":
				_go(f)
			"keys":
				_move_keys(a, f - _drag_from)
				_drag_from = f
			"window_start", "window_end", "window_move":
				var r := _drag_window_orig
				var d := f - _drag_from
				match _drag:
					"window_start":
						r.x = clampi(r.x + d, 0, r.y)
					"window_end":
						r.y = clampi(r.y + d, r.x, a.length - 1)
					_:
						var span := r.y - r.x
						r.x = clampi(r.x + d, 0, a.length - 1 - span)
						r.y = r.x + span
				a.windows[_drag_window] = r
		_canvas.queue_redraw()
		_canvas.accept_event()
		return
	var key := event as InputEventKey
	if key and key.pressed:
		var handled := true
		match key.keycode:
			KEY_SPACE:
				_toggle_play()
			KEY_LEFT:
				_go(int(model.frame) - 1)
			KEY_RIGHT:
				_go(int(model.frame) + 1)
			KEY_UP:
				_jump_key(-1)
			KEY_DOWN:
				_jump_key(1)
			KEY_K:
				key_current()
			KEY_DELETE, KEY_BACKSPACE:
				_delete_keys()
			KEY_C:
				if key.ctrl_pressed or key.meta_pressed:
					if selected_keys.is_empty():
						_copy_pose()
					else:
						_copy_keys()
				else:
					handled = false
			KEY_V:
				if key.ctrl_pressed or key.meta_pressed:
					_paste(key.shift_pressed, true)
				else:
					handled = false
			_:
				handled = false
		if handled:
			_canvas.accept_event()


## Moves (or with Alt, copies) the selected keys by `d` frames while dragging.
func _move_keys(a: ActorAnimation, d: int) -> void:
	if d == 0:
		return
	var moving := a.keys.filter(func(k): return selected_keys.has(k.frame))
	if moving.is_empty():
		return
	for k in moving:
		var nf: int = k.frame + d
		if nf < 0 or nf >= a.length:
			return
	if _drag_copy:
		for k in moving:
			a.keys.append({frame = k.frame, pose = k.pose.duplicate(), root = k.root, ease = k.ease})
		_drag_copy = false
	var new_sel: Array[int] = []
	for k in moving:
		k.frame += d
		new_sel.append(k.frame)
	# A moved key replaces one it lands on.
	var taken := {}
	var kept := []
	for k in a.keys:
		if k in moving:
			kept.append(k)
			taken[k.frame] = true
	for k in a.keys:
		if not k in moving and not taken.has(k.frame):
			kept.append(k)
	a.keys = kept
	a.sort_keys()
	selected_keys = new_sel
	_go(int(model.frame) + d)


func _btn(parent: Control, text: String, fn: Callable, tip := "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.pressed.connect(fn)
	parent.add_child(b)
	return b


func _prop(grid: GridContainer, label: String, control: Control) -> void:
	var l := Label.new()
	l.text = label
	grid.add_child(l)
	control.size_flags_horizontal = SIZE_EXPAND_FILL
	grid.add_child(control)


func _spin(lo: float, hi: float, step: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	return s
