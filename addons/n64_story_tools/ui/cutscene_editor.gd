@tool
extends HSplitContainer
## "Cutscenes" tab of the Story workspace: the cutscenes (res://game/story/cutscenes) on
## the left; on the right the selected one's settings, a preview monitor (the open zone
## seen through the cutscene camera at the playhead, actors as ghosts where they'd be),
## its timeline and tools. Keys are edited in the inspector (click one on the timeline).
##  - Camera from view: a camera shot at the playhead from the 3D view (or updates the
##    selected shot);
##  - Position from view / Pick in 3D / From selected node: sets the selected key's
##    position (and facing) from where the 3D view looks, a click in the 3D view, or the
##    selected Node3D (a Marker3D, a spawn point…);
##  - ▶ Play in game: runs the zone and plays the cutscene (editor runs only).
## Changes save by themselves; every edit is undoable.

const Timeline := preload("res://addons/n64_story_tools/ui/cutscene_timeline.gd")
const DIR := "res://game/story/cutscenes"
## Editor "Play in game" hand-off (read by the Cutscenes autoload in editor runs only).
const PREVIEW_FILE := "user://cutscene_preview.json"

var db: StoryDatabase
## Set by the plugin: request_pick.call(callback(point: Vector3)) lets the next click in
## the 3D view pick a point.
var request_pick: Callable

var cutscene: Cutscene
var _list: ItemList
var _new_name: LineEdit
var _id: LineEdit
var _length: SpinBox
var _skip: OptionButton
var _letterbox: CheckBox
var _zone_label: Label
var _timeline: Control
var _time_label: Label
var _play_button: Button
var _add: MenuButton
var _vp: SubViewport
var _cam: Camera3D
var _monitor_note: Label
var _playing := false
var _updating := false
var _save_timer: Timer
var _ghost_root: Node3D
var _scale := 1.0


func _init() -> void:
	name = "Cutscenes"
	_scale = EditorInterface.get_editor_scale()
	split_offset = int(200 * _scale)
	var left := VBoxContainer.new()
	add_child(left)
	var title := Label.new()
	title.text = "Cutscenes"
	left.add_child(title)
	_list = ItemList.new()
	_list.size_flags_vertical = SIZE_EXPAND_FILL
	_list.custom_minimum_size.x = 180 * _scale
	_list.item_selected.connect(func(i): open_cutscene(_list.get_item_metadata(i)))
	left.add_child(_list)
	var row := HBoxContainer.new()
	left.add_child(row)
	_new_name = LineEdit.new()
	_new_name.placeholder_text = "new_cutscene"
	_new_name.size_flags_horizontal = SIZE_EXPAND_FILL
	_new_name.text_submitted.connect(func(_t): _create())
	row.add_child(_new_name)
	var add := Button.new()
	add.text = "New"
	add.tooltip_text = "New cutscene in %s, for the open zone scene." % DIR
	add.pressed.connect(_create)
	row.add_child(add)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	add_child(right)
	var head := HBoxContainer.new()
	right.add_child(head)
	head.add_child(_label("Id"))
	_id = LineEdit.new()
	_id.custom_minimum_size.x = 120 * _scale
	_id.tooltip_text = "Names its \"seen\" flag: cutscene/<id>."
	_id.text_submitted.connect(func(t): _set_prop(cutscene, &"id", StringName(t)))
	_id.focus_exited.connect(func(): if cutscene and _id.text != String(cutscene.id): _set_prop(cutscene, &"id", StringName(_id.text)))
	head.add_child(_id)
	head.add_child(_label("Length"))
	_length = SpinBox.new()
	_length.min_value = 0.5
	_length.max_value = 600.0
	_length.step = 0.5
	_length.suffix = "s"
	_length.value_changed.connect(func(v): if not _updating: _set_prop(cutscene, &"length", v))
	head.add_child(_length)
	_skip = OptionButton.new()
	for n in ["Never skippable", "Skippable once seen", "Always skippable"]:
		_skip.add_item(n)
	_skip.item_selected.connect(func(i): if not _updating: _set_prop(cutscene, &"skip", i))
	head.add_child(_skip)
	_letterbox = CheckBox.new()
	_letterbox.text = "Letterbox"
	_letterbox.toggled.connect(func(on): if not _updating: _set_prop(cutscene, &"letterbox", on))
	head.add_child(_letterbox)
	_zone_label = Label.new()
	_zone_label.modulate.a = 0.6
	_zone_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_zone_label.clip_text = true
	head.add_child(_zone_label)
	var use_zone := Button.new()
	use_zone.text = "Use open scene"
	use_zone.tooltip_text = "The cutscene happens in the scene open in the editor."
	use_zone.pressed.connect(func():
		var scene := EditorInterface.get_edited_scene_root()
		if cutscene and scene:
			_set_prop(cutscene, &"zone", scene.scene_file_path))
	head.add_child(use_zone)
	var open_zone := Button.new()
	open_zone.text = "Open zone"
	open_zone.pressed.connect(func():
		if cutscene and cutscene.zone != "":
			EditorInterface.open_scene_from_path(cutscene.zone)
			_update_preview.call_deferred())
	head.add_child(open_zone)

	var split := VSplitContainer.new()
	split.size_flags_vertical = SIZE_EXPAND_FILL
	right.add_child(split)
	var monitor := SubViewportContainer.new()
	monitor.stretch = true
	monitor.size_flags_vertical = SIZE_EXPAND_FILL
	monitor.custom_minimum_size = Vector2(320, 180) * _scale
	split.add_child(monitor)
	_vp = SubViewport.new()
	_vp.size = Vector2i(640, 360)
	_vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	monitor.add_child(_vp)
	_cam = Camera3D.new()
	_cam.current = true
	_vp.add_child(_cam)
	_monitor_note = Label.new()
	_monitor_note.position = Vector2(8, 6) * _scale
	_monitor_note.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_monitor_note.add_theme_constant_override(&"outline_size", 4)
	monitor.add_child(_monitor_note)

	var lower := VBoxContainer.new()
	split.add_child(lower)
	var tools := HFlowContainer.new()
	lower.add_child(tools)
	_play_button = _button(tools, "▶", "Play the preview from the playhead (loops).", func():
		_playing = not _playing
		_play_button.text = "❚❚" if _playing else "▶")
	_time_label = Label.new()
	_time_label.custom_minimum_size.x = 64 * _scale
	tools.add_child(_time_label)
	_add = MenuButton.new()
	_add.text = "Add key"
	_add.flat = false
	_add.about_to_popup.connect(_fill_add_menu)
	_add.get_popup().id_pressed.connect(_on_add)
	tools.add_child(_add)
	_button(tools, "Camera from view", "A camera shot at the playhead from the 3D view's camera\n(updates the selected shot instead).", _camera_from_view)
	_button(tools, "Position from view", "The selected key's position: where the centre of the 3D view looks.", _position_from_view)
	_button(tools, "Pick in 3D", "The selected key's position: click a spot in the 3D view (Esc cancels).", _pick_in_3d)
	_button(tools, "From selected node", "The selected key's position and facing from the selected Node3D\n(a Marker3D, a spawn point, an NPC…).", _from_selected_node)
	_button(tools, "Delete key", "Remove the selected key.", func(): _delete(_timeline.selected))
	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	tools.add_child(spacer)
	_button(tools, "▶ Play in game", "Run the zone and play this cutscene (editor runs only).", _play_in_game)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 140 * _scale
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	lower.add_child(scroll)
	_timeline = Timeline.new(_scale)
	_timeline.size_flags_horizontal = SIZE_EXPAND_FILL
	_timeline.time_changed.connect(func(_t): _update_preview())
	_timeline.key_selected.connect(func(c):
		if c:
			EditorInterface.inspect_object(c, "", true))
	_timeline.key_moved.connect(_on_key_moved)
	_timeline.delete_requested.connect(_delete)
	scroll.add_child(_timeline)

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.4
	_save_timer.timeout.connect(_save)
	add_child(_save_timer)
	visibility_changed.connect(func():
		if not is_visible_in_tree():
			_clear_ghosts()
		else:
			refresh_files()
			_update_preview())


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _button(parent: Control, text: String, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.pressed.connect(action)
	parent.add_child(b)
	return b


# --- Files --------------------------------------------------------------------------------

func refresh_files() -> void:
	_list.clear()
	if not DirAccess.dir_exists_absolute(DIR):
		return
	for f in DirAccess.get_files_at(DIR):
		if f.get_extension() == "tres":
			_list.add_item(f.get_basename())
			_list.set_item_metadata(_list.item_count - 1, DIR + "/" + f)
			if cutscene and cutscene.resource_path == DIR + "/" + f:
				_list.select(_list.item_count - 1)


func _create() -> void:
	var n := _new_name.text.strip_edges().to_snake_case()
	if n == "":
		n = "cutscene_%d" % (_list.item_count + 1)
	var path := "%s/%s.tres" % [DIR, n]
	if FileAccess.file_exists(path):
		push_warning("Cutscenes: %s already exists." % path)
		return
	DirAccess.make_dir_recursive_absolute(DIR)
	var c := Cutscene.new()
	c.id = StringName(n)
	var scene := EditorInterface.get_edited_scene_root()
	c.zone = scene.scene_file_path if scene else ""
	ResourceSaver.save(c, path)
	EditorInterface.get_resource_filesystem().update_file(path)
	_new_name.text = ""
	open_cutscene(path)


func open_cutscene(path: String) -> void:
	var c := load(path) as Cutscene
	if c == null:
		return
	if cutscene and cutscene.changed.is_connected(_on_changed):
		cutscene.changed.disconnect(_on_changed)
	cutscene = c
	cutscene.changed.connect(_on_changed)
	_watch_cues()
	_timeline.set_cutscene(c)
	_timeline.time = 0.0
	refresh_files()
	_sync_header()
	_update_preview()


## Every key's changes (in the inspector) redraw, preview and save.
func _watch_cues() -> void:
	for c in cutscene.cues:
		if c and not c.changed.is_connected(_on_changed):
			c.changed.connect(_on_changed)


func _on_changed() -> void:
	_watch_cues()
	_sync_header()
	_timeline.refresh()
	_update_preview()
	_save_timer.start()


func _save() -> void:
	if cutscene and cutscene.resource_path != "":
		ResourceSaver.save(cutscene, cutscene.resource_path)


func _sync_header() -> void:
	if cutscene == null:
		return
	_updating = true
	_id.text = String(cutscene.id)
	_length.value = cutscene.length
	_skip.select(cutscene.skip)
	_letterbox.button_pressed = cutscene.letterbox
	_zone_label.text = "Zone: " + (cutscene.zone if cutscene.zone != "" else "(none: Use open scene)")
	_updating = false


# --- Editing (undoable) -------------------------------------------------------------------

func _set_prop(obj: Object, prop: StringName, value: Variant, action := "") -> void:
	if obj == null or obj.get(prop) == value:
		return
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action(action if action != "" else "Set Cutscene %s" % String(prop).capitalize(), UndoRedo.MERGE_ENDS)
	ur.add_do_property(obj, prop, value)
	ur.add_undo_property(obj, prop, obj.get(prop))
	ur.add_do_method(self, &"_on_changed")
	ur.add_undo_method(self, &"_on_changed")
	ur.commit_action()


func _set_cues(cues: Array[CutsceneCue], action: String) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action(action)
	ur.add_do_property(cutscene, &"cues", cues)
	ur.add_undo_property(cutscene, &"cues", cutscene.cues.duplicate())
	ur.add_do_method(self, &"_on_changed")
	ur.add_undo_method(self, &"_on_changed")
	ur.commit_action()


func _on_key_moved(c: CutsceneCue, from: float) -> void:
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Move Cutscene Key")
	ur.add_do_property(c, &"time", c.time)
	ur.add_undo_property(c, &"time", from)
	ur.add_do_method(self, &"_on_changed")
	ur.add_undo_method(self, &"_on_changed")
	ur.commit_action(false)
	_on_changed()


func _delete(c: CutsceneCue) -> void:
	if cutscene == null or c == null:
		return
	var cues := cutscene.cues.duplicate()
	cues.erase(c)
	_timeline.selected = null
	_set_cues(cues, "Delete Cutscene Key")


func _add_cue(c: CutsceneCue) -> void:
	if cutscene == null:
		return
	c.time = _timeline.time
	var cues := cutscene.cues.duplicate()
	cues.append(c)
	_set_cues(cues, "Add Cutscene Key")
	_timeline.selected = c
	EditorInterface.inspect_object(c, "", true)


## Add key menu: ids < 100 shot / line / events, 100+ an actor cue per actor.
var _menu_actors: Array[StringName] = []


func _fill_add_menu() -> void:
	var p := _add.get_popup()
	p.clear()
	p.add_item("Camera shot (from the 3D view)", 0)
	p.add_item("Dialogue line", 1)
	p.add_separator("Event")
	for i in CutsceneCue.Event.size():
		p.add_item(CutsceneCue.Event.keys()[i].capitalize(), 10 + i)
	p.add_separator("Actor")
	_menu_actors = [CutsceneCue.PLAYER]
	if db:
		for id in db.character_ids():
			if not _menu_actors.has(StringName(id)):
				_menu_actors.append(StringName(id))
	if cutscene:
		for t in cutscene.track_ids().slice(3):
			if not _menu_actors.has(t):
				_menu_actors.append(t)
	for i in _menu_actors.size():
		p.add_item(String(_menu_actors[i]), 100 + i)


func _on_add(id: int) -> void:
	if cutscene == null:
		return
	var c := CutsceneCue.new()
	if id == 0:
		c.kind = CutsceneCue.Kind.SHOT
		var cam := _editor_camera()
		if cam:
			c.transform = cam.global_transform
			c.fov = cam.fov
		c.move = CutsceneCue.Move.CUT if cutscene.cues.filter(func(x): return x and x.kind == CutsceneCue.Kind.SHOT).is_empty() else CutsceneCue.Move.SMOOTH
	elif id == 1:
		c.kind = CutsceneCue.Kind.LINE
	elif id >= 100:
		c.kind = CutsceneCue.Kind.ACTOR
		c.actor = _menu_actors[id - 100]
		var st := _actor_state(c.actor, _timeline.time)
		c.position = st.position
		c.facing = st.facing
	else:
		c.kind = CutsceneCue.Kind.EVENT
		c.event = id - 10
		if c.event == CutsceneCue.Event.FADE:
			c.duration = 0.5
	_add_cue(c)


func _camera_from_view() -> void:
	var cam := _editor_camera()
	if cam == null or cutscene == null:
		return
	var sel: CutsceneCue = _timeline.selected
	if sel and sel.kind == CutsceneCue.Kind.SHOT:
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action("Cutscene Shot From View")
		ur.add_do_property(sel, &"transform", cam.global_transform)
		ur.add_undo_property(sel, &"transform", sel.transform)
		ur.add_do_property(sel, &"fov", cam.fov)
		ur.add_undo_property(sel, &"fov", sel.fov)
		ur.add_do_property(sel, &"camera_id", 0)
		ur.add_undo_property(sel, &"camera_id", sel.camera_id)
		ur.commit_action()
	else:
		_on_add(0)


func _position_from_view() -> void:
	var cam := _editor_camera()
	if cam == null:
		return
	var vp := cam.get_viewport()
	var centre := vp.get_visible_rect().size * 0.5
	_set_key_position(_ray_point(cam, centre))


func _pick_in_3d() -> void:
	if _position_key() and request_pick.is_valid():
		request_pick.call(func(p: Vector3): _set_key_position(p))


func _from_selected_node() -> void:
	var nodes := EditorInterface.get_selection().get_selected_nodes().filter(func(n): return n is Node3D)
	var c := _position_key()
	if nodes.is_empty() or c == null:
		push_warning("Cutscenes: select a key with a position and a Node3D in the scene.")
		return
	var n: Node3D = nodes[0]
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Cutscene Key From Node")
	ur.add_do_property(c, &"position", n.global_position)
	ur.add_undo_property(c, &"position", c.position)
	var f := -n.global_basis.z
	f.y = 0.0
	if f.length() > 0.01:
		ur.add_do_property(c, &"facing", roundf(Cutscene.facing_degrees(f)))
		ur.add_undo_property(c, &"facing", c.facing)
	ur.commit_action()


## The selected key, if it has a position (actor moves, effects, sounds).
func _position_key() -> CutsceneCue:
	var c: CutsceneCue = _timeline.selected
	if c == null:
		return null
	if c.kind == CutsceneCue.Kind.ACTOR and c.action in [CutsceneCue.Action.WALK, CutsceneCue.Action.RUN, CutsceneCue.Action.TELEPORT]:
		return c
	if c.kind == CutsceneCue.Kind.EVENT and c.event in [CutsceneCue.Event.EFFECT, CutsceneCue.Event.SOUND]:
		return c
	push_warning("Cutscenes: select a Walk / Run / Teleport, Effect or Sound key first.")
	return null


func _set_key_position(p: Vector3) -> void:
	var c := _position_key()
	if c:
		_set_prop(c, &"position", p.snapped(Vector3.ONE * 0.05), "Cutscene Key Position")


func _editor_camera() -> Camera3D:
	return EditorInterface.get_editor_viewport_3d(0).get_camera_3d()


## Where a ray through `screen` hits the zone's collision (bake the level first), else the
## ground plane at the selected key's height.
func _ray_point(cam: Camera3D, screen: Vector2) -> Vector3:
	var from := cam.project_ray_origin(screen)
	var dir := cam.project_ray_normal(screen)
	var world := cam.get_viewport().find_world_3d()
	var hit := world.direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + dir * 500.0))
	if not hit.is_empty():
		return hit.position
	var y: float = _timeline.selected.position.y if _timeline.selected else 0.0
	var p: Variant = Plane(Vector3.UP, y).intersects_ray(from, dir)
	return p if p != null else from + dir * 10.0


# --- Preview ------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _playing and cutscene and is_visible_in_tree():
		var t: float = _timeline.time + delta
		_timeline.time = 0.0 if t > cutscene.length else t
		_timeline.queue_redraw()
		_update_preview()


func _scene() -> Node:
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null or cutscene == null:
		return null
	if cutscene.zone != "" and scene.scene_file_path != cutscene.zone:
		return null
	return scene


## An actor's state at `t` (from where it stands in the scene, or its first position key).
func _actor_state(id: StringName, t: float) -> Dictionary:
	var start := {position = Vector3.ZERO, facing = 0.0, visible = true, animation = &""}
	var node := _scene_actor(id)
	if node:
		start.position = node.global_position
		var f := -node.global_basis.z
		start.facing = Cutscene.facing_degrees(Vector3(f.x, 0, f.z)) if Vector2(f.x, f.z).length() > 0.01 else 0.0
	elif cutscene:
		for c in cutscene.sorted():
			if c.kind == CutsceneCue.Kind.ACTOR and c.actor == id and c.action in [CutsceneCue.Action.WALK, CutsceneCue.Action.RUN, CutsceneCue.Action.TELEPORT]:
				start.position = c.position
				start.facing = c.facing
				break
	return cutscene.actor_at(id, t, start) if cutscene else start


## The scene's stand-in for an actor: the default spawn for the player, the NPC (or node)
## playing a character.
func _scene_actor(id: StringName) -> Node3D:
	var scene := _scene()
	if scene == null:
		return null
	if id == CutsceneCue.PLAYER:
		var spawns := scene.find_children("*", "", true, false).filter(func(n): return n is Node3D and n.has_method(&"get_spawn_transform"))
		for s in spawns:
			if String(s.name).to_lower().contains("default"):
				return s
		return spawns[0] if not spawns.is_empty() else null
	for n in scene.find_children("*", "", true, false):
		if n is Node3D and n.get(&"character") == id:
			return n
	return scene.find_child(String(id), true, false) as Node3D


func _zone_view(id: int) -> Camera3D:
	var scene := _scene()
	if scene:
		for z in scene.find_children("*", "CameraZone", true, false):
			if z.camera_id == id:
				return z.view()
	return null


func _update_preview() -> void:
	if cutscene == null or not is_visible_in_tree():
		return
	var t: float = _timeline.time
	_time_label.text = "%.2f s" % t
	var scene := _scene()
	if scene == null:
		_monitor_note.text = "Open the cutscene's zone to preview (Open zone)." if cutscene.zone != "" else "Set the zone: open it and press Use open scene."
		_clear_ghosts()
		return
	_vp.world_3d = EditorInterface.get_editor_viewport_3d(0).find_world_3d()
	var states := {}
	for id in cutscene.track_ids().slice(3):
		states[id] = _actor_state(id, t)
	var cam := cutscene.camera_at(t, func(id): return states[id].position if states.has(id) else null, _zone_view)
	if cam.is_empty():
		var first := cutscene.sorted().filter(func(c): return c.kind == CutsceneCue.Kind.SHOT)
		cam = cutscene.camera_at(first[0].time, func(id): return states[id].position if states.has(id) else null, _zone_view) if not first.is_empty() else {}
	if cam.is_empty():
		var ed := _editor_camera()
		cam = {xf = ed.global_transform, fov = ed.fov}
		_monitor_note.text = "No camera shot yet (showing the 3D view): Camera from view."
	else:
		_monitor_note.text = ""
	_cam.global_transform = cam.xf
	_cam.fov = cam.fov
	_draw_ghosts(scene, states)


func _clear_ghosts() -> void:
	if is_instance_valid(_ghost_root):
		_ghost_root.queue_free()
	_ghost_root = null


## Ghost capsules (with a nose for facing and a name) where actors are at the playhead,
## lines along their moves, and the camera shots' positions. Internal: never saved.
func _draw_ghosts(scene: Node, states: Dictionary) -> void:
	if not is_instance_valid(_ghost_root) or _ghost_root.get_parent() != scene:
		_clear_ghosts()
		_ghost_root = Node3D.new()
		_ghost_root.name = "_CutscenePreview"
		scene.add_child(_ghost_root, false, Node.INTERNAL_MODE_BACK)
	for child in _ghost_root.get_children():
		child.free()
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	var any := false
	for id in states:
		var s: Dictionary = states[id]
		var col: Color = _timeline._track_color(id)
		var ghost := MeshInstance3D.new()
		var capsule := CapsuleMesh.new()
		capsule.radius = 0.3
		capsule.height = 1.6
		ghost.mesh = capsule
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(col, 0.55 if s.visible else 0.15)
		ghost.material_override = mat
		_ghost_root.add_child(ghost)
		ghost.global_position = s.position + Vector3.UP * 0.8
		var nose := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.12, 0.12, 0.35)
		nose.mesh = box
		nose.material_override = mat
		ghost.add_child(nose)
		var dir := Cutscene.facing_vector(s.facing)
		nose.position = Vector3(0, 0.45, 0) + dir * 0.35
		nose.basis = Basis.looking_at(dir, Vector3.UP)
		var tag := Label3D.new()
		tag.text = String(id) + ("  " + String(s.animation) if s.animation != &"" else "")
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.no_depth_test = true
		tag.pixel_size = 0.006
		tag.modulate = col
		tag.position.y = 1.1
		ghost.add_child(tag)
		# The actor's route: start, then each position key.
		var prev: Vector3 = _actor_state(id, 0.0).position
		for c in cutscene.sorted():
			if c.kind == CutsceneCue.Kind.ACTOR and c.actor == id and c.action in [CutsceneCue.Action.WALK, CutsceneCue.Action.RUN, CutsceneCue.Action.TELEPORT]:
				lines.surface_set_color(col)
				lines.surface_add_vertex(prev + Vector3.UP * 0.05)
				lines.surface_set_color(col)
				lines.surface_add_vertex(c.position + Vector3.UP * 0.05)
				prev = c.position
				any = true
	for c in cutscene.sorted():
		if c.kind == CutsceneCue.Kind.SHOT and c.camera_id == 0:
			# A little camera: its position and look direction.
			var o := c.transform.origin
			var f := -c.transform.basis.z.normalized() * 0.6
			for e in [[o, o + f], [o + Vector3.UP * 0.12, o - Vector3.UP * 0.12], [o + c.transform.basis.x * 0.12, o - c.transform.basis.x * 0.12]]:
				lines.surface_set_color(Color(1.0, 0.6, 0.15))
				lines.surface_add_vertex(e[0])
				lines.surface_set_color(Color(1.0, 0.6, 0.15))
				lines.surface_add_vertex(e[1])
			any = true
	if not any:
		lines.surface_set_color(Color.TRANSPARENT)
		lines.surface_add_vertex(Vector3.ZERO)
		lines.surface_add_vertex(Vector3.ZERO)
	lines.surface_end()
	var path := MeshInstance3D.new()
	path.mesh = lines
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.vertex_color_use_as_albedo = true
	lm.no_depth_test = true
	path.material_override = lm
	_ghost_root.add_child(path)


# --- Play in game -------------------------------------------------------------------------

func _play_in_game() -> void:
	if cutscene == null or cutscene.zone == "":
		push_warning("Cutscenes: set the cutscene's zone first (Use open scene).")
		return
	_save()
	var f := FileAccess.open(PREVIEW_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({cutscene = cutscene.resource_path}))
		f.close()
	EditorInterface.play_custom_scene(cutscene.zone)
