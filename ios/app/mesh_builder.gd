extends Node3D
## M3D3 Mesh Builder: the game's low-poly character / prop modelling on a phone.
## Runs the same modelling code as the desktop actor tools (ActorModel, ActorEditor's
## operations, ActorPieceOps, ActorPick): the files are the same character scenes.
##
## Touch:
##  - one finger: tap picks (Add mode adds / removes). With something selected a gizmo
##    sits on it (Move: centre = free in the view plane, arrows = one axis, squares = two
##    axes; Rotate: rings, around the Pivot). Dragging a selected element moves it freely.
##    Grid snapped. A drag anywhere else draws a selection box.
##    Cut (toggle): touch an edge to see its loop, slide, release to cut (tap = middle).
##  - orbit pad (bottom right circle): drag from it to orbit.
##  - two fingers: pan + pinch zoom (a second finger cancels a drag in progress).
##  - views: snap to front / back / left / right / top / bottom (orthographic).

const OrbitCamera := preload("res://app/orbit_camera.gd")
const EditOverlay := preload("res://app/edit_overlay.gd")
const AppUI := preload("res://app/app_ui.gd")
const ActorEditor := preload("res://addons/n64_actor_tools/actor_editor.gd")
const Backdrop := preload("res://addons/n64_actor_tools/actor_backdrop.gd")
const References := preload("res://addons/n64_actor_tools/actor_references.gd")
const Tool := ActorEditor.Tool

const MODELS_DIR := "user://models"
## Snap sizes, metric: each is a fifth of a round bold-line spacing (MAJORS), so bold
## lines land on 1 cm, 5 cm, 10 cm, 0.5 m, 1 m, ...
const GRIDS := [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0]
const MAJORS := [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0]
## Auto grid: the snap size whose cells are at least this big on screen (design px).
const AUTO_GRID_PX := 48.0
## Touch distances (design pixels; the UI is 1170 wide).
const SLOP := 18.0
const PICK_RADIUS := 60.0

enum GizmoMode { MOVE, ROTATE }
## Rotation pivot: the selection's middle, the piece's bone joint, or a picked point.
enum Pivot { MEDIAN, JOINT, POINT }
const PIVOT_NAMES := ["Median", "Joint", "Point"]
## Rotate gizmo ring radius (design px); the view ring is a bit bigger.
const ROT_RING := 190.0

var camera: OrbitCamera
var overlay: EditOverlay
var references: References
## The current view's reference image is selected: one finger transforms it (inside =
## move, corners = scale, sides = stretch X / Y, knob = rotate), two fingers move / pinch /
## twist it.
var ref_adjusting := false
var _ref_grab := {}
## Rotate knob distance above the image's top edge; handle touch radius (design px).
const REF_KNOB := 90.0
const REF_HANDLE := 46.0
var ui: AppUI
var editor := ActorEditor.new()
var model: ActorModel
var model_path := ""

## Loop cut mode: one finger cuts instead of selecting.
var cutting := false
var add_mode := false
## Taps select the shortest path from the last picked element (Blender's Ctrl+click).
var path_mode := false
## The snap size follows the zoom (the Grid button cycles Auto -> fixed sizes).
var auto_grid := true
var gizmo_mode := GizmoMode.MOVE
var pivot_mode := Pivot.MEDIAN
## Pivot.POINT: where (world); _picking_pivot: the next tap sets it.
var pivot_point := Vector3.ZERO
var _picking_pivot := false
var _rot_pivot := Vector3.ZERO
var _rot_axis := Vector3.ZERO
var _rot_xf := Transform3D()
## Screen direction of the grabbed ring at the touch (increasing angle).
var _rot_tangent := Vector2.RIGHT
## The selection was picked on the right-side mirrored copy of its piece.
var sel_mirrored := false

var _box: Control
var _touches := {}  # index -> position
var _gesture := ""  # "", "tool", "nav", "done"
var _first := -1
var _press := Vector2.ZERO
var _last := Vector2.ZERO
var _moved := false
var _action := ""  # orbit / box / move / cut
var _nav_c := Vector2.ZERO
var _nav_d := 1.0
var _move_plane := Plane()
var _move_start := Vector3.ZERO
var _move_inv := Basis()
var _cut := {}
var _cut_t := 0.5
var _box_rect := Rect2()
## Move gizmo (screen, design px): centre ring radius, arrow length, plane handle size.
const GIZMO_RING := 34.0
const GIZMO_ARROW := 230.0
const GIZMO_PLANE := 46.0
const AXES := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
const AXIS_COLORS := [Color(0.96, 0.33, 0.33), Color(0.55, 0.9, 0.3), Color(0.3, 0.55, 1.0)]
## What the finger grabbed on touch-down: {} or {kind: "free" | "axis" | "plane", axis}.
var _grab := {}
var _move_axis := Vector3.ZERO
var _move_t0 := 0.0
var _move_kind := ""


func _ready() -> void:
	var backdrop := Backdrop.new()
	add_child(backdrop)
	backdrop.setup(null, Backdrop.Kind.STUDIO)
	camera = OrbitCamera.new()
	add_child(camera)
	camera.make_current()
	overlay = EditOverlay.new()
	add_child(overlay)
	references = References.new()
	add_child(references)
	var layer := CanvasLayer.new()
	add_child(layer)
	_box = Control.new()
	_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.draw.connect(_draw_box)
	layer.add_child(_box)
	ui = AppUI.new()
	ui.app = self
	layer.add_child(ui)
	editor.refreshed.connect(_refresh)
	editor.tool_changed.connect(_refresh)
	DirAccess.make_dir_recursive_absolute(MODELS_DIR)
	var plans := BodyPlan.all().keys()
	plans.sort()
	ui.set_plans(plans)
	ui.select(&"elements", Tool.FACE)
	ui.select(&"view", 0)
	ui.select(&"gizmo", GizmoMode.MOVE)
	ui.set_pivot_visible(false)
	new_model(&"humanoid")


func _process(_delta: float) -> void:
	_box.queue_redraw()  # the gizmo follows the camera
	if model and auto_grid and _action != "move":
		var g := _auto_grid_size()
		if not is_equal_approx(g, model.data.model_grid):
			# Not an undo step: it only follows the view.
			model.data.model_grid = g
			_refresh()
	if model and camera.view != OrbitCamera.View.PERSPECTIVE:
		overlay.show_grid(camera, camera.target, model.data.model_grid, major_step(), camera.size * 0.6)
	else:
		overlay.hide_grid()


# --- Files ---------------------------------------------------------------------------------

func new_model(plan: StringName) -> void:
	var m := ActorModel.new()
	m.name = "%s_%d" % [plan, Time.get_unix_time_from_system() as int % 100000]
	var data := ActorModelData.new()
	data.plan = plan
	m.data = data
	_set_model(m, "")
	editor.set_tool(Tool.FACE)  # starts modelling (starter pieces)
	editor.clear_history()
	ui.select(&"elements", Tool.FACE)
	frame_model()


## Character scenes on the phone (user://models) and the ones bundled from the project.
func model_files() -> PackedStringArray:
	var out := PackedStringArray()
	for dir: String in [MODELS_DIR, "res://characters"]:
		var d := DirAccess.open(dir)
		if d == null:
			continue
		for f in d.get_files():
			f = f.trim_suffix(".remap")
			if not (f.ends_with(".tscn") or f.ends_with(".scn")):
				continue
			var path: String = dir.path_join(f)
			if dir == MODELS_DIR or _is_character(path):
				out.append(path)
	return out


func _is_character(path: String) -> bool:
	for dep in ResourceLoader.get_dependencies(path):
		if dep.ends_with("actor_model.gd"):
			return true
	return false


func open_model(path: String) -> void:
	var packed := load(path) as PackedScene
	var m := packed.instantiate() if packed else null
	if not m is ActorModel:
		if m:
			m.free()
		_say("%s isn't a character." % path.get_file())
		return
	# Edit a copy: bundled scenes are read-only, and undo shouldn't touch the cache.
	m.data = m.data.duplicate(true) if m.data else ActorModelData.new()
	_set_model(m, path)
	editor.set_tool(ui_elements())
	editor.clear_history()
	frame_model()


func save() -> void:
	if model_path == "" or not model_path.begins_with(MODELS_DIR):
		save_as(model_name())
		return
	_save_to(model_path)


func save_as(file_name: String) -> void:
	var n := file_name.strip_edges().validate_filename()
	if n == "":
		return
	model.name = n.to_pascal_case()
	_save_to(MODELS_DIR.path_join(n + ".tscn"))


func _save_to(path: String) -> void:
	references.save_to(model)
	var packed := PackedScene.new()
	var err := packed.pack(model)
	if err == OK:
		err = ResourceSaver.save(packed, path)
	if err != OK:
		_say("Can't save (%s)." % error_string(err))
		return
	model_path = path
	_say("Saved %s." % path.get_file())


func model_name() -> String:
	return model_path.get_file().get_basename() if model_path != "" else String(model.name).to_snake_case()


func _set_model(m: ActorModel, path: String) -> void:
	editor.set_model(null)
	if model:
		model.queue_free()
	model = m
	model_path = path
	model.authoring = true
	model.show_reference = false
	add_child(model)
	model.mode = ActorModel.Mode.MODEL
	references.load_from(model)
	_update_reference_box()
	sel_mirrored = false
	editor.set_model(model)
	_refresh()


func ui_elements() -> int:
	return editor.tool if ActorEditor.is_model_tool(editor.tool) and editor.tool != Tool.LOOP_CUT else Tool.FACE


# --- Tools / view (from the UI) ------------------------------------------------------------

func set_cutting(on: bool) -> void:
	cutting = on
	_clear_cut()
	ui.set_toggle(&"cut", on)
	if on:
		_say("Cut: touch an edge, slide, lift to cut. Tap Cut again when done.")
	_refresh()


func set_elements(t: int) -> void:
	editor.set_tool(t)
	sel_mirrored = false


## Symmetric editing of the selected piece (centre pieces: mirror twins follow; left
## pieces: the right side is built as a mirror copy).
func set_symmetry(on: bool) -> void:
	var p := editor.piece()
	if p == null:
		_say("Select a piece first.")
		ui.set_toggle(&"sym", false)
		return
	editor.set_piece_mirror(on)
	_say("%s: mirror %s." % [p.bone, "on" if on else "off"])
	_refresh()


func set_view(v: int) -> void:
	if v != camera.view:
		ref_adjusting = false
	camera.set_view(v)
	references.show_view(v)
	if ui.ref_panel_open():
		if v == OrbitCamera.View.PERSPECTIVE:
			toggle_reference_panel()
		else:
			_show_ref_panel()
	_refresh()


# --- Reference images ----------------------------------------------------------------------

func toggle_reference_panel() -> void:
	if ref_adjusting and not ui.ref_panel_open():
		ref_done()
		return
	if ui.ref_panel_open():
		ui.hide_ref_panel()
		ref_adjusting = false
		ui.set_toggle(&"ref", false)
		_refresh()
		return
	if camera.view == OrbitCamera.View.PERSPECTIVE:
		_say("Switch to Front, Back, Left, Right, Top or Bottom to add that view's reference.")
		ui.set_toggle(&"ref", false)
		return
	_show_ref_panel()


func _show_ref_panel() -> void:
	ui.show_ref_panel(camera.view_name(), references.images(), references.get_ref(camera.view))


func ref_pick(path: String) -> void:
	_update_reference_box()
	if not references.set_image(camera.view, path):
		_say("Can't read %s (use PNG or JPG)." % path.get_file())
	_show_ref_panel()


func ref_set(key: String, value: Variant) -> void:
	references.set_value(camera.view, key, value)


func ref_fit() -> void:
	_update_reference_box()
	references.fit(camera.view)
	_show_ref_panel()


func ref_clear() -> void:
	references.clear(camera.view)
	ref_adjusting = false
	_show_ref_panel()


## Selects the image (hides the panel): fingers transform it until a tap outside it.
func ref_adjust() -> void:
	if references.get_ref(camera.view).is_empty():
		_say("Pick an image first.")
		return
	ref_adjusting = true
	ui.hide_ref_panel()
	ui.set_toggle(&"ref", true)
	_say("Reference: drag inside to move, corners scale, sides stretch, ○ rotates (two fingers too). Tap outside it when done.")


func ref_done() -> void:
	ref_adjusting = false
	_ref_grab = {}
	ui.set_toggle(&"ref", ui.ref_panel_open())
	_say("Reference placed.")


## Straight and unstretched again (keeps its place and height).
func ref_straighten() -> void:
	references.set_value(camera.view, "angle", 0.0)
	references.set_value(camera.view, "stretch", 1.0)


func _update_reference_box() -> void:
	if model and model.mesh_instance and model.mesh_instance.mesh:
		references.set_model_box(model.mesh_instance.mesh.get_aabb())


func set_xray(on: bool) -> void:
	model.display = ActorModel.Display.XRAY if on else ActorModel.Display.SOLID
	ui.set_toggle(&"wire", false)
	_refresh()


func set_wire(on: bool) -> void:
	model.display = ActorModel.Display.WIREFRAME if on else ActorModel.Display.SOLID
	ui.set_toggle(&"xray", false)
	_refresh()


func frame_model() -> void:
	if model and model.mesh_instance and model.mesh_instance.mesh:
		camera.frame(model.mesh_instance.mesh.get_aabb())


## Auto -> 0.3 cm -> … -> 20 cm -> Auto.
func cycle_grid() -> void:
	if auto_grid:
		auto_grid = false
		model.data.model_grid = GRIDS[0]
	else:
		var i := _grid_index()
		if i < 0 or i == GRIDS.size() - 1:
			auto_grid = true
			model.data.model_grid = _auto_grid_size()
		else:
			model.data.model_grid = GRIDS[i + 1]
	_refresh()


## The finest snap size whose cells are at least AUTO_GRID_PX on screen.
func _auto_grid_size() -> float:
	var wpp: float = camera.world_per_pixel()
	for g in GRIDS:
		if g / wpp >= AUTO_GRID_PX:
			return g
	return GRIDS[-1]


func undo() -> void:
	editor.undo()
	_sanitize_selection()
	_refresh()


func redo() -> void:
	editor.redo()
	_sanitize_selection()
	_refresh()


var _bone_action: StringName

func action(a: StringName) -> void:
	match a:
		&"extrude": editor.extrude()
		&"subdivide": editor.subdivide()
		&"merge":
			if model.selected_piece() == null:
				_say("Select vertices to merge.")
				return
			ui.show_merge_menu(model.select_mode == ActorModel.Select.VERTEX and model.sel_verts.size() >= 2)
			return
		&"dissolve": editor.dissolve()
		&"flip": editor.flip_faces()
		&"inflate": editor.inflate(1.0)
		&"deflate": editor.inflate(-1.0)
		&"scale_up": editor.scale(true)
		&"scale_down": editor.scale(false)
		&"ring_add":
			_ring_from_selection()
			editor.add_ring()
		&"ring_delete":
			_ring_from_selection()
			editor.delete_ring()
		&"sides_more": editor.tube_sides(1)
		&"sides_fewer": editor.tube_sides(-1)
		&"shell": editor.shell()
		&"add_tube", &"add_box", &"copy_bone":
			_bone_action = a
			var bones := []
			for b in model.bones:
				if b.side != 1:
					bones.append(b.name)
			ui.show_bones(bones)
			return
		&"mirror":
			var p := editor.piece()
			if p:
				editor.set_piece_mirror(not p.mirror)
		&"select_all": _select_all()
		&"reset_piece": _reset_piece()
		&"reset_model":
			editor.edit("Reset Model", func():
				model.data.pieces = ActorMannequin.starters(model)
				model.clear_selection())
			sel_mirrored = false
			_say("Model reset to the starting mesh (↶ brings it back).")
		&"select_none": model.clear_elements()
		&"delete":
			if editor.tool == Tool.PIECE or not model.has_selection():
				editor.delete_piece()
			else:
				editor.delete_faces()
	_sanitize_selection()
	_refresh()


## Merge menu choice (ActorPieceOps.Merge). At Tap Point waits for the next tap; By
## Distance with nothing picked works on the whole piece.
var _merge_pending := false

func merge_picked(mode: int) -> void:
	match mode:
		ActorPieceOps.Merge.POINT:
			_merge_pending = true
			_say("Tap a vertex (or the surface) to merge there.")
			return
	if model.selected_vertices().size() < 2 and mode != ActorPieceOps.Merge.DISTANCE:
		_say("Select at least two vertices.")
		return
	var removed := editor.merge_by(mode)
	_sanitize_selection()
	_say("Merged: %d vertices removed." % removed if removed > 0 else "Nothing to merge (no vertices that close).")
	_refresh()


## At Tap Point: the vertex nearest the tap, else the surface under it (piece space of
## the selected piece, on its source side).
func _merge_at_tap(pos: Vector2) -> void:
	var world = null
	var e := ActorPick.nearest(model, camera, pos, ActorModel.Select.VERTEX, PICK_RADIUS)
	if not e.is_empty():
		world = model.global_transform * e.at
	else:
		var f := ActorPick.face_at(model, camera, pos)
		if not f.is_empty():
			world = model.global_transform * f.point
	_merge_pending = false
	if world == null:
		_say("Tap a vertex or the model to merge there.")
		return
	var local: Vector3 = (model.global_transform * model.piece_transform(_shown_piece())).affine_inverse() * (world as Vector3)
	if sel_mirrored:
		local.x = -local.x
	var removed := editor.merge_by(ActorPieceOps.Merge.POINT, local)
	_sanitize_selection()
	_say("Merged: %d vertices removed." % removed)
	_refresh()


func bone_picked(bone: StringName) -> void:
	match _bone_action:
		&"add_tube": editor.add_piece(bone, true)
		&"add_box": editor.add_piece(bone, false)
		&"copy_bone": editor.copy_to_bone(bone)
	sel_mirrored = false
	_refresh()


# --- Touch ---------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if model == null:
		return
	var touch := event as InputEventScreenTouch
	var drag := event as InputEventScreenDrag
	if touch:
		if touch.pressed:
			_touches[touch.index] = touch.position
			_down(touch.index, touch.position)
		else:
			_touches.erase(touch.index)
			_up(touch.index, touch.position)
	elif drag:
		_touches[drag.index] = drag.position
		_dragged(drag.index, drag.position)
	elif event is InputEventMouseButton and event.pressed:
		# Desktop testing: the wheel zooms. (Touches also arrive as emulated mouse
		# clicks, for menus and lists; the left button is ignored here.)
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera.zoom(1.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera.zoom(1.0 / 1.1)
	elif event is InputEventMagnifyGesture:
		camera.zoom(event.factor)
	elif event is InputEventPanGesture:
		camera.pan(-event.delta * 8.0)


func _down(index: int, pos: Vector2) -> void:
	if _touches.size() == 1:
		_gesture = "tool"
		_first = index
		_press = pos
		_last = pos
		_moved = false
		_action = ""
		_grab = {}
		if ui.on_orbit_pad(pos):
			_action = "orbit"
			_moved = true
		elif ref_adjusting:
			_ref_grab = _ref_grab_at(pos)
		elif cutting:
			_begin_cut(pos)
		else:
			_grab = _grab_at(pos)
	elif ref_adjusting:
		_ref_last = {}
	elif _touches.size() == 2 and _gesture == "tool":
		_cancel_action()
		_gesture = "nav"
		_nav_start()


func _dragged(index: int, pos: Vector2) -> void:
	if ref_adjusting and camera.view != OrbitCamera.View.PERSPECTIVE and _action != "orbit":
		_ref_drag(index, pos)
		return
	if _gesture == "nav" and _touches.size() >= 2:
		var c := _centroid()
		var d := _spread()
		camera.pan(c - _nav_c)
		camera.zoom(d / maxf(_nav_d, 1.0))
		_nav_c = c
		_nav_d = d
		return
	if _gesture != "tool" or index != _first:
		return
	if not _moved and pos.distance_to(_press) > SLOP:
		_moved = true
		_start_action()
	if _moved:
		_continue_action(pos)
	_last = pos


## Reference transforms. Two fingers: move + pinch-size + twist about the point between
## them (from their last positions). One finger: what _ref_grab holds (from the start of
## the drag).
var _ref_last := {}

func _ref_drag(index: int, pos: Vector2) -> void:
	var v: int = camera.view
	if pos.distance_to(_press) > SLOP:
		_moved = true
	if _touches.size() >= 2:
		var keys := _touches.keys().slice(0, 2)
		var p1 := _plane(_touches[keys[0]])
		var p2 := _plane(_touches[keys[1]])
		var f := references.frame(v)
		if _ref_last.has("p1") and not f.is_empty():
			var q1: Vector2 = _ref_last.p1
			var q2: Vector2 = _ref_last.p2
			var k := (p2 - p1).length() / maxf((q2 - q1).length(), 1e-5)
			var da := (p2 - p1).angle() - (q2 - q1).angle()
			var c: Vector2 = (p1 + p2) * 0.5 + ((f.centre - (q1 + q2) * 0.5) * k).rotated(da)
			references.set_frame(v, c, f.half * 2.0 * k, f.angle + da)
		_ref_last = {p1 = p1, p2 = p2}
		_ref_grab = {}
	elif index == _first and not _ref_grab.is_empty():
		_ref_transform(_plane(pos))
		_ref_last = {}
	_last = pos


## Plane coordinates (current view) under a screen point.
func _plane(pos: Vector2) -> Vector2:
	return references.to_plane(camera.view, camera.project_ray_origin(pos))


func _ref_screen(f: Dictionary, local: Vector2) -> Vector2:
	return camera.unproject_position(references.to_world(camera.view, f.centre + local.rotated(f.angle)))


## The selected image's handles on screen: {outline, handles: [{kind, s, at}]}.
func _ref_handles() -> Dictionary:
	var f := references.frame(camera.view)
	if f.is_empty():
		return {}
	var h: Vector2 = f.half
	var outline := PackedVector2Array()
	for s in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1)]:
		outline.append(_ref_screen(f, s * h))
	var handles := []
	var knob := Vector2(0, h.y + REF_KNOB * camera.world_per_pixel())
	handles.append({kind = "rotate", s = Vector2.ZERO, at = _ref_screen(f, knob), from = _ref_screen(f, Vector2(0, h.y))})
	for s in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1), Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
		handles.append({kind = "scale", s = s, at = _ref_screen(f, s * h)})
	return {outline = outline, handles = handles, frame = f}


## What a touch grabs on the selected image: a handle, the image (move) or {} (outside).
func _ref_grab_at(pos: Vector2) -> Dictionary:
	var rh := _ref_handles()
	if rh.is_empty():
		return {}
	var best := {}
	var best_d := REF_HANDLE
	for hd in rh.handles:
		var d: float = pos.distance_to(hd.at)
		if d < best_d:
			best_d = d
			best = hd
	var p := _plane(pos)
	if not best.is_empty():
		return {kind = best.kind, s = best.s, start = rh.frame, p0 = p}
	if references.contains(camera.view, p):
		return {kind = "move", start = rh.frame, p0 = p}
	return {}


## One-finger transform from the drag's start frame to the finger at `p` (plane).
func _ref_transform(p: Vector2) -> void:
	var g := _ref_grab
	var f: Dictionary = g.start
	var c: Vector2 = f.centre
	var half: Vector2 = f.half
	var a: float = f.angle
	match g.kind:
		"move":
			references.set_frame(camera.view, c + p - g.p0, half * 2.0, a)
		"rotate":
			var ang := _magnet(a + (p - c).angle() - (g.p0 - c).angle())
			references.set_frame(camera.view, c, half * 2.0, ang)
			_say("Reference %d°" % roundi(rad_to_deg(ang)))
		"scale":
			# The opposite corner / side stays put.
			var s: Vector2 = g.s
			var q := (p - c).rotated(-a)
			var anchor := -s * half
			var full := half * 2.0
			if s.x != 0.0 and s.y != 0.0:
				var dir := s * half * 2.0
				full *= maxf((q - anchor).dot(dir) / dir.length_squared(), 0.02)
			elif s.x != 0.0:
				full.x = maxf(s.x * (q.x - anchor.x), 0.01)
			else:
				full.y = maxf(s.y * (q.y - anchor.y), 0.01)
			references.set_frame(camera.view, c + (anchor + s * full * 0.5).rotated(a), full, a)
			_say("Reference %s × %s" % [length_text(full.x), length_text(full.y)])


## Angles near a multiple of 15° snap to it.
static func _magnet(a: float) -> float:
	var n := snappedf(a, PI / 12.0)
	return n if absf(a - n) < deg_to_rad(2.0) else a


## A tap on empty space over the current view's (unlocked) image selects it.
func _ref_tap(pos: Vector2) -> bool:
	if camera.view == OrbitCamera.View.PERSPECTIVE:
		return false
	var r := references.get_ref(camera.view)
	if r.is_empty() or not r.get("visible", true) or r.get("locked", false):
		return false
	if not references.contains(camera.view, _plane(pos)):
		return false
	ref_adjust()
	return true


func _up(index: int, pos: Vector2) -> void:
	if ref_adjusting:
		_ref_last = {}
	if _gesture == "tool" and index == _first:
		if _moved:
			_end_action(pos)
		else:
			_tap(pos)
		_gesture = "done"
	if _gesture == "nav" and _touches.size() == 1:
		_gesture = "done"
	if _touches.is_empty():
		_gesture = ""


func _nav_start() -> void:
	_nav_c = _centroid()
	_nav_d = _spread()


func _centroid() -> Vector2:
	var c := Vector2.ZERO
	var keys := _touches.keys().slice(0, 2)
	for k in keys:
		c += _touches[k]
	return c / maxf(keys.size(), 1)


func _spread() -> float:
	var keys := _touches.keys()
	return _touches[keys[0]].distance_to(_touches[keys[1]]) if keys.size() >= 2 else 1.0


## Orbit pad drag. Leaving a snapped view goes back to perspective (and the 3D button).
func _orbit(delta: Vector2) -> void:
	var was_snapped := camera.view != OrbitCamera.View.PERSPECTIVE
	camera.orbit(delta)
	if was_snapped:
		ui.select(&"view", 0)
		set_view(OrbitCamera.View.PERSPECTIVE)


# --- Tool actions --------------------------------------------------------------------------

func _tap(pos: Vector2) -> void:
	if ref_adjusting:
		if _ref_grab.is_empty():
			ref_done()
		return
	if cutting:
		if not _cut.is_empty():
			_cut_t = 0.5
			_commit_cut()
		return
	if _merge_pending:
		_merge_at_tap(pos)
		return
	if _picking_pivot:
		_place_pivot(pos)
		return
	# A tap on the gizmo keeps the selection.
	if not _grab.is_empty() and _grab.get("gizmo", false):
		return
	_select_at(pos)


func _start_action() -> void:
	if not _grab.is_empty() and _begin_move(_grab):
		_action = "move"
		return
	if cutting:
		_action = "cut" if not _cut.is_empty() else ""
	elif editor.tool != Tool.PIECE:
		_action = "box"


func _continue_action(pos: Vector2) -> void:
	match _action:
		"orbit":
			_orbit(pos - _last)
		"box":
			_box_rect = Rect2(_press, Vector2.ZERO).expand(pos)
			_box.queue_redraw()
		"move":
			_update_move(pos)
		"cut":
			var axis: Vector2 = _cut.sb - _cut.sa
			_cut_t = clampf(0.5 + (pos - _press).dot(axis) / maxf(axis.length_squared(), 1.0), 0.02, 0.98)
			_show_cut()


func _end_action(_pos: Vector2) -> void:
	match _action:
		"box":
			_box_select(_box_rect)
			_box_rect = Rect2()
			_box.queue_redraw()
		"move":
			editor.end_move()
		"cut":
			_commit_cut()
	_action = ""
	_refresh()


## A second finger landed: undo what the first one was doing.
func _cancel_action() -> void:
	match _action:
		"move":
			editor.cancel_move()
		"box":
			_box_rect = Rect2()
			_box.queue_redraw()
	if cutting:
		_clear_cut()
	_action = ""
	_refresh()


# --- Selection -----------------------------------------------------------------------------

func _select_at(pos: Vector2) -> void:
	var hit := {}
	if editor.tool == Tool.PIECE:
		var f := ActorPick.face_at(model, camera, pos)
		if not f.is_empty():
			hit = {piece = f.piece, mirrored = f.mirrored}
	else:
		hit = ActorPick.nearest(model, camera, pos, model.select_mode, PICK_RADIUS)
	if hit.is_empty():
		# Nothing selected: a tap on the reference image selects it.
		if model.sel_piece < 0 and _ref_tap(pos):
			return
		if not add_mode:
			model.clear_selection()
		_refresh()
		return
	var same: bool = hit.piece == model.sel_piece and hit.mirrored == sel_mirrored
	if path_mode and same and editor.tool != Tool.PIECE and _extend_path(hit.id):
		_refresh()
		return
	if not same:
		model.sel_piece = hit.piece
		sel_mirrored = hit.mirrored
		model.clear_elements()
	elif not add_mode and not path_mode:
		model.clear_elements()
	if editor.tool != Tool.PIECE:
		_toggle(hit.id)
	_refresh()


## Path mode: adds the shortest path from the last picked element to `id` (which becomes
## the last, so taps chain). False when there's nothing to start from.
func _extend_path(id: Variant) -> bool:
	var list: Array = [model.sel_verts, model.sel_edges, model.sel_faces][model.select_mode]
	if list.is_empty() or list.back() == id:
		return false
	var route := ActorPieceOps.shortest_path(model.selected_piece(), model.select_mode, list.back(), id)
	if route.is_empty():
		return false
	for e in route:
		list.erase(e)
		list.append(e)
	return true


func _toggle(id: Variant) -> void:
	var list: Array = [model.sel_verts, model.sel_edges, model.sel_faces][model.select_mode]
	if list.has(id):
		list.erase(id)
	else:
		list.append(id)


func _box_select(rect: Rect2) -> void:
	if editor.tool == Tool.PIECE:
		return
	var hits := {}  # [piece, mirrored] -> ids
	for e in ActorPick.elements(model, camera, model.select_mode):
		if e.behind or not rect.has_point(e.screen):
			continue
		if model.select_mode == ActorModel.Select.EDGE and not (rect.has_point(e.sa) and rect.has_point(e.sb)):
			continue
		if not ActorPick.visible(model, camera, e.at):
			continue
		var key := [e.piece, e.mirrored]
		if not hits.has(key):
			hits[key] = []
		hits[key].append(e.id)
	if hits.is_empty():
		if not add_mode:
			model.clear_elements()
		return
	# One piece at a time: the selected one, else the one with the most hits.
	var key: Array = [model.sel_piece, sel_mirrored]
	if not hits.has(key):
		key = hits.keys()[0]
		for k in hits:
			if hits[k].size() > hits[key].size():
				key = k
	if key[0] != model.sel_piece or key[1] != sel_mirrored:
		model.sel_piece = key[0]
		sel_mirrored = key[1]
		model.clear_elements()
	elif not add_mode:
		model.clear_elements()
	var list: Array = [model.sel_verts, model.sel_edges, model.sel_faces][model.select_mode]
	for id in hits[key]:
		if not list.has(id):
			list.append(id)


func _select_all() -> void:
	var p := model.selected_piece()
	if p == null:
		return
	model.clear_elements()
	match model.select_mode:
		ActorModel.Select.VERTEX:
			for i in p.vertices.size():
				model.sel_verts.append(i)
		ActorModel.Select.EDGE:
			for poly in p.faces():
				for k in poly.size():
					var e := Vector2i(mini(poly[k], poly[(k + 1) % poly.size()]), maxi(poly[k], poly[(k + 1) % poly.size()]))
					if not model.sel_edges.has(e):
						model.sel_edges.append(e)
		ActorModel.Select.FACE:
			for i in p.faces().size():
				model.sel_faces.append(i)


## After undo / topology changes: drop selected ids the piece no longer has.
func _sanitize_selection() -> void:
	var p := model.selected_piece()
	if p == null:
		model.clear_selection()
		return
	var nv := p.vertices.size()
	var nf := p.faces().size()
	if model.sel_verts.any(func(v): return v >= nv) or model.sel_edges.any(func(e): return e.x >= nv or e.y >= nv) \
			or model.sel_faces.any(func(f): return f >= nf):
		model.clear_elements()


## The selected piece back to its starting shape for its bone (one undo step).
func _reset_piece() -> void:
	var p := editor.piece()
	if p == null:
		_say("Select a piece to reset.")
		return
	for s in ActorMannequin.starters(model):
		if s.bone == p.bone:
			var idx := model.sel_piece
			editor.edit("Reset Piece", func():
				s.mirror = p.mirror
				model.data.pieces[idx] = s
				model.clear_elements())
			_say("%s reset (↶ brings it back)." % p.bone)
			return
	_say("%s has no starting shape (added piece): delete it instead." % p.bone)


## Ring tools need a ring: the one the selected vertices sit on.
func _ring_from_selection() -> void:
	var p := editor.piece()
	if p == null or not p.is_tube():
		return
	var vs := model.selected_vertices()
	for r in p.rings.size():
		if vs.size() > 0 and Array(p.rings[r]).has(vs[0]):
			model.sel_ring = r
			return


# --- Moving --------------------------------------------------------------------------------

## The selected piece as built on the side it was picked (source / mirrored copy).
func _shown_piece() -> ActorPiece:
	for entry in ActorMannequin.expanded(model, model.data.pieces):
		if entry[1] == model.sel_piece and entry[2] == sel_mirrored:
			return entry[0]
	return model.selected_piece()


## Selection centre in world space (on the side it was picked), or null.
func _gizmo_anchor() -> Variant:
	if model.selected_piece() == null:
		return null
	var ep := _shown_piece()
	var xf := model.global_transform * model.piece_transform(ep)
	if gizmo_mode == GizmoMode.ROTATE:
		match pivot_mode:
			Pivot.JOINT:
				return xf * Vector3.ZERO
			Pivot.POINT:
				return pivot_point
	return xf * ActorPieceOps.centre(ep, model.selected_vertices())


## Rotate gizmo rings (screen polylines) around the pivot: one per axis + the view ring.
func _rot_rings(anchor: Vector3) -> Array:
	var w: float = camera.world_per_pixel()
	var out := []
	for i in 3:
		var ax: Vector3 = AXES[i]
		var u := ax.cross(Vector3.UP if absf(ax.y) < 0.9 else Vector3.RIGHT).normalized()
		var v := ax.cross(u)
		out.append({axis = ax, color = AXIS_COLORS[i], pts = _ring_points(anchor, u, v, ROT_RING * w)})
	var cu := camera.global_basis.x
	var cv := camera.global_basis.y
	out.append({axis = -camera.global_basis.z, color = Color(1, 1, 1), pts = _ring_points(anchor, cu, cv, ROT_RING * 1.22 * w)})
	return out


func _ring_points(c: Vector3, u: Vector3, v: Vector3, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 49:
		var a := TAU * k / 48.0
		pts.append(camera.unproject_position(c + (u * cos(a) + v * sin(a)) * r))
	return pts


## Screen-space gizmo: {centre, ends: [3 screen points or null (axis faces the camera)],
## planes: [{pair: [i, j], pos}]}, or {}.
func _gizmo() -> Dictionary:
	var anchor = _gizmo_anchor()
	if anchor == null or camera.is_position_behind(anchor):
		return {}
	var c := camera.unproject_position(anchor)
	var step := camera.world_per_pixel() * 100.0
	var dirs := []
	for ax in AXES:
		var d: Vector2 = camera.unproject_position(anchor + ax * step) - c
		dirs.append(d / 100.0 if d.length() > 25.0 else null)
	var ends := []
	for d in dirs:
		ends.append(c + d.normalized() * GIZMO_ARROW if d != null else null)
	var planes := []
	for pair in [[0, 1], [0, 2], [1, 2]]:
		# No square when its two arrows look nearly parallel (it would sit on them).
		if dirs[pair[0]] != null and dirs[pair[1]] != null \
				and absf(dirs[pair[0]].normalized().cross(dirs[pair[1]].normalized())) > 0.4:
			planes.append({pair = pair, pos = c + (dirs[pair[0]].normalized() + dirs[pair[1]].normalized()) * GIZMO_ARROW * 0.42})
	return {centre = c, ends = ends, planes = planes}


## What a touch at `pos` grabs: the gizmo's centre / an arrow / a plane square, or a
## selected element (free move); {} = nothing (the tool's normal drag).
func _grab_at(pos: Vector2) -> Dictionary:
	var g := _gizmo()
	if g.is_empty():
		return {}
	if gizmo_mode == GizmoMode.ROTATE:
		var anchor: Vector3 = _gizmo_anchor()
		var best := {}
		var best_d := 40.0
		for ring in _rot_rings(anchor):
			var pts: PackedVector2Array = ring.pts
			for k in pts.size() - 1:
				var d := pos.distance_to(Geometry2D.get_closest_point_to_segment(pos, pts[k], pts[k + 1]))
				if d < best_d:
					best_d = d
					var t := (pts[k + 1] - pts[k]).normalized()
					best = {kind = "rotate", axis = ring.axis, tangent = t, gizmo = true}
		return best
	if pos.distance_to(g.centre) <= GIZMO_RING + 22.0:
		return {kind = "free", gizmo = true}
	for pl in g.planes:
		if pos.distance_to(pl.pos) <= GIZMO_PLANE * 0.5 + 18.0:
			return {kind = "plane", axis = AXES[3 - pl.pair[0] - pl.pair[1]], gizmo = true}
	var best := -1
	var best_d := 42.0
	for i in 3:
		if g.ends[i] == null:
			continue
		var on := Geometry2D.get_closest_point_to_segment(pos, g.centre, g.ends[i])
		if pos.distance_to(on) <= best_d and on.distance_to(g.centre) > GIZMO_RING:
			best_d = pos.distance_to(on)
			best = i
	if best >= 0:
		return {kind = "axis", axis = AXES[best], gizmo = true}
	# Dragging a selected element moves the selection.
	if model.has_selection() and _on_selection(pos):
		return {kind = "free"}
	return {}


func _on_selection(pos: Vector2) -> bool:
	if model.select_mode == ActorModel.Select.FACE:
		var f := ActorPick.face_at(model, camera, pos)
		return not f.is_empty() and f.piece == model.sel_piece and f.mirrored == sel_mirrored and model.sel_faces.has(f.face)
	var e := ActorPick.nearest(model, camera, pos, model.select_mode, PICK_RADIUS, model.sel_piece)
	if e.is_empty() or e.mirrored != sel_mirrored:
		return false
	return (model.sel_verts if model.select_mode == ActorModel.Select.VERTEX else model.sel_edges).has(e.id)


func _begin_move(grab: Dictionary) -> bool:
	if not editor.begin_move():
		return false
	var ep := _shown_piece()
	var xf := model.global_transform * model.piece_transform(ep)
	var anchor := xf * ActorPieceOps.centre(ep, model.selected_vertices())
	_move_inv = xf.basis.inverse()
	_move_kind = grab.kind
	if _move_kind == "rotate":
		_rot_pivot = _gizmo_anchor()
		_rot_axis = grab.axis
		_rot_xf = model.piece_transform(ep)
		_rot_tangent = grab.tangent
		return true
	match _move_kind:
		"axis":
			_move_axis = grab.axis
			_move_start = anchor
			_move_t0 = _axis_param(anchor, _move_axis, _press)
		"plane":
			_move_plane = Plane(grab.axis, anchor)
		_:
			_move_plane = Plane(camera.global_basis.z, anchor)
	if _move_kind != "axis":
		var hit = _move_plane.intersects_ray(camera.project_ray_origin(_press), camera.project_ray_normal(_press))
		_move_start = hit if hit != null else anchor
	return true


## Where along the line `origin + t * axis` the finger's ray passes closest.
func _axis_param(origin: Vector3, axis: Vector3, pos: Vector2) -> float:
	var o := camera.project_ray_origin(pos)
	var v := camera.project_ray_normal(pos)
	var w0 := origin - o
	var b := axis.dot(v)
	var denom := 1.0 - b * b
	if denom < 1e-4:
		return 0.0
	return (b * v.dot(w0) - axis.dot(w0)) / denom


func _update_move(pos: Vector2) -> void:
	if _move_kind == "rotate":
		_update_rotate(pos)
		return
	var d := Vector3.ZERO
	if _move_kind == "axis":
		d = _move_axis * (_axis_param(_move_start, _move_axis, pos) - _move_t0)
	else:
		var hit = _move_plane.intersects_ray(camera.project_ray_origin(pos), camera.project_ray_normal(pos))
		if hit == null:
			return
		d = (hit as Vector3) - _move_start
	var local := _move_inv * d
	if sel_mirrored:
		local.x = -local.x
	editor.update_move(local)
	overlay.refresh(model, sel_mirrored)


## Rotation follows the drag along the grabbed ring's direction at the touch (one ring
## radius of drag = 1 radian), whatever angle the ring is seen at (Blender-like); snapped
## to the angle step.
func _update_rotate(pos: Vector2) -> void:
	var angle := (pos - _press).dot(_rot_tangent) / ROT_RING
	var step := deg_to_rad(maxf(model.data.angle_step, 1.0))
	angle = snappedf(angle, step)
	var inv := model.global_transform.affine_inverse()
	var pivot_model := inv * _rot_pivot
	var axis_model := (inv.basis * _rot_axis).normalized()
	editor.update_rotate(Basis(axis_model, angle), pivot_model, _rot_xf, sel_mirrored)
	_say("Rotate %d°" % roundi(rad_to_deg(angle)))
	overlay.refresh(model, sel_mirrored)


func set_gizmo_mode(m: int) -> void:
	gizmo_mode = m
	ui.set_pivot_visible(m == GizmoMode.ROTATE)
	if m != GizmoMode.ROTATE:
		_picking_pivot = false
	elif pivot_mode == Pivot.POINT and pivot_point == Vector3.ZERO:
		_picking_pivot = true
	_refresh()


## Median -> Joint -> Point (then tap a vertex / the surface to place it) -> Median.
func cycle_pivot() -> void:
	pivot_mode = (pivot_mode + 1) % 3
	_picking_pivot = pivot_mode == Pivot.POINT
	if _picking_pivot:
		_say("Tap a vertex (or the surface) to place the pivot.")
	ui.set_pivot_text("Pivot\n%s" % PIVOT_NAMES[pivot_mode])
	_refresh()


## Pivot.POINT: the vertex nearest the tap, else the surface under it.
func _place_pivot(pos: Vector2) -> void:
	var e := ActorPick.nearest(model, camera, pos, ActorModel.Select.VERTEX, PICK_RADIUS)
	if not e.is_empty():
		pivot_point = model.global_transform * e.at
	else:
		var f := ActorPick.face_at(model, camera, pos)
		if f.is_empty():
			_say("Tap a vertex or the model to place the pivot.")
			return
		pivot_point = model.global_transform * f.point
	_picking_pivot = false
	_say("Pivot placed.")


# --- Loop cut ------------------------------------------------------------------------------

func _begin_cut(pos: Vector2) -> void:
	var e := ActorPick.nearest(model, camera, pos, ActorModel.Select.EDGE, PICK_RADIUS)
	if e.is_empty():
		_clear_cut()
		return
	var ep := ActorPick.built_piece(model, e.piece, e.id.x, e.a)
	if ep == null:
		return
	var ring := ActorPieceOps.edge_ring(ep, e.id)
	var xf := model.global_transform * model.piece_transform(ep)
	_cut = {piece = e.piece, ep = ep, ring = ring, xf = xf,
		sa = camera.unproject_position(xf * ep.vertices[e.id.x]), sb = camera.unproject_position(xf * ep.vertices[e.id.y])}
	_cut_t = 0.5
	_show_cut()


func _show_cut() -> void:
	var pts := PackedVector3Array()
	var ep: ActorPiece = _cut.ep
	for e in _cut.ring.edges:
		pts.append(_cut.xf * ep.vertices[e.x].lerp(ep.vertices[e.y], _cut_t))
	overlay.show_cut(pts, _cut.ring.closed)


func _commit_cut() -> void:
	if _cut.is_empty():
		return
	editor.loop_cut(_cut.piece, _cut.ring, [_cut_t])
	sel_mirrored = false
	_clear_cut()
	_refresh()


func _clear_cut() -> void:
	_cut = {}
	if overlay:
		overlay.clear_cut()


# --- Display -------------------------------------------------------------------------------

func _refresh() -> void:
	if model == null or not is_instance_valid(model):
		return
	overlay.refresh(model, sel_mirrored)
	var b := editor.budget()
	ui.status.text = "%s\n%s · %d / %d tris · grid %s" % [_note if Time.get_ticks_msec() < _note_until else editor.selection_text(),
		camera.view_name(), b.tris, b.budget, _grid_text()]
	ui.set_grid_text("Grid\n%s" % ("Auto" if auto_grid else length_text(model.data.model_grid)))
	ui.set_actions(_context_actions())
	var sp := model.selected_piece()
	ui.set_toggle(&"sym", sp != null and sp.mirror)


## The action bar's operations for what's selected now (the rest are under ⋯).
func _context_actions() -> Array:
	var p := model.selected_piece()
	if p == null:
		return [&"add_tube", &"add_box", &"select_all"]
	if not model.has_selection():
		# The whole piece.
		if p.is_tube():
			return [&"ring_add", &"sides_more", &"sides_fewer", &"shell", &"mirror", &"delete"]
		return [&"shell", &"copy_bone", &"mirror", &"scale_up", &"scale_down", &"delete"]
	match model.select_mode:
		ActorModel.Select.FACE:
			return [&"extrude", &"subdivide", &"inflate", &"scale_up", &"scale_down", &"delete"]
		ActorModel.Select.EDGE:
			return [&"extrude", &"merge", &"scale_up", &"scale_down", &"inflate", &"delete"]
	# Vertices: on a tube ring, the ring tools come first.
	if p.is_tube():
		return [&"merge", &"dissolve", &"ring_add", &"ring_delete", &"scale_up", &"delete"]
	return [&"merge", &"dissolve", &"inflate", &"scale_up", &"scale_down", &"delete"]


## The current snap size's place in GRIDS (nearest, for sizes set elsewhere).
func _grid_index() -> int:
	var g: float = model.data.model_grid
	var best := 0
	for i in GRIDS.size():
		if absf(GRIDS[i] - g) < absf(GRIDS[best] - g):
			best = i
	return best if absf(GRIDS[best] - g) < 1e-6 else -1


## Bold-line spacing for the current snap size (5 cells; 4 for off-series sizes).
func major_step() -> float:
	var i := _grid_index()
	return MAJORS[i] if i >= 0 else model.data.model_grid * 4.0


static func length_text(m: float) -> String:
	if m >= 1.0:
		return "%s m" % _trim(m, 2)
	if m >= 0.01:
		return "%s cm" % _trim(m * 100.0, 1)
	return "%s mm" % _trim(m * 1000.0, 1)


## 75.0 -> "75", 2.50 -> "2.5".
static func _trim(v: float, decimals: int) -> String:
	var t := String.num(snappedf(v, pow(10.0, -decimals)), decimals)
	if t.contains("."):
		t = t.rstrip("0").rstrip(".")
	return t


func _grid_text() -> String:
	var t := "%s · bold %s" % [length_text(model.data.model_grid), length_text(major_step())]
	return "Auto " + t if auto_grid else t


## A note on the status line, kept for a few seconds over the selection summary.
var _note := ""
var _note_until := 0

func _say(text: String) -> void:
	_note = text
	_note_until = Time.get_ticks_msec() + 4000
	ui.status.text = text


func _draw_box() -> void:
	if ref_adjusting:
		_draw_ref_gizmo()
	else:
		_draw_gizmo()
	_draw_grid_labels()
	if _box_rect.size != Vector2.ZERO:
		_box.draw_rect(_box_rect, Color(1, 1, 1, 0.08))
		_box.draw_rect(_box_rect, Color(1, 1, 1, 0.8), false, 3.0)


func _draw_ref_gizmo() -> void:
	var rh := _ref_handles()
	if rh.is_empty():
		return
	var col := Color(1, 0.8, 0.25)
	_box.draw_polyline(rh.outline, col, 4.0, true)
	for hd in rh.handles:
		var hot: bool = _ref_grab.get("kind", "") == hd.kind and _ref_grab.get("s", Vector2.ZERO) == hd.s and _moved
		if hd.kind == "rotate":
			_box.draw_line(hd.from, hd.at, col, 3.0, true)
			_box.draw_circle(hd.at, 24.0, col.lightened(0.4) if hot else col)
			_box.draw_arc(hd.at, 13.0, 0.3, TAU - 0.6, 16, Color(0.1, 0.1, 0.1), 3.5, true)
		elif hd.s.x != 0.0 and hd.s.y != 0.0:
			var r := Rect2(hd.at - Vector2(17, 17), Vector2(34, 34))
			_box.draw_rect(r, col.lightened(0.4) if hot else col)
			_box.draw_rect(r, Color(0.1, 0.1, 0.1), false, 3.0)
		else:
			_box.draw_circle(hd.at, 15.0, col.lightened(0.4) if hot else Color(1, 1, 1))
			_box.draw_arc(hd.at, 15.0, 0.0, TAU, 20, Color(0.1, 0.1, 0.1), 3.0, true)


func _draw_gizmo() -> void:
	if model == null or cutting:
		return
	if gizmo_mode == GizmoMode.ROTATE and pivot_mode == Pivot.POINT and not _picking_pivot:
		var pp := camera.unproject_position(pivot_point)
		_box.draw_arc(pp, 16.0, 0.0, TAU, 24, Color(1, 0.85, 0.2), 4.0, true)
		_box.draw_line(pp - Vector2(26, 0), pp + Vector2(26, 0), Color(1, 0.85, 0.2), 3.0)
		_box.draw_line(pp - Vector2(0, 26), pp + Vector2(0, 26), Color(1, 0.85, 0.2), 3.0)
	var g := _gizmo()
	if g.is_empty():
		return
	var active: Dictionary = _grab if _action == "move" else {}
	if gizmo_mode == GizmoMode.ROTATE:
		for ring in _rot_rings(_gizmo_anchor()):
			var hot: bool = active.get("kind", "") == "rotate" and active.axis.is_equal_approx(ring.axis)
			var col: Color = ring.color.lightened(0.35) if hot else ring.color
			_box.draw_polyline(ring.pts, Color(col, 0.95 if hot else 0.8), 7.0 if hot else 5.0, true)
		_box.draw_circle(g.centre, 9.0, Color(1, 1, 1, 0.9))
		return
	for pl in g.planes:
		var a: Color = AXIS_COLORS[pl.pair[0]]
		var b: Color = AXIS_COLORS[pl.pair[1]]
		var col := a.lerp(b, 0.5)
		var hot: bool = active.get("kind", "") == "plane" and active.axis == AXES[3 - pl.pair[0] - pl.pair[1]]
		var r := Rect2(pl.pos - Vector2.ONE * GIZMO_PLANE * 0.5, Vector2.ONE * GIZMO_PLANE)
		_box.draw_rect(r, Color(col, 0.85 if hot else 0.45))
		_box.draw_rect(r, Color(1, 1, 1, 0.7), false, 3.0)
	for i in 3:
		if g.ends[i] == null:
			continue
		var hot: bool = active.get("kind", "") == "axis" and active.axis == AXES[i]
		var col: Color = AXIS_COLORS[i].lightened(0.35) if hot else AXIS_COLORS[i]
		var dir: Vector2 = (g.ends[i] - g.centre).normalized()
		var from: Vector2 = g.centre + dir * GIZMO_RING
		_box.draw_line(from, g.ends[i] - dir * 30.0, col, 10.0, true)
		var n := Vector2(-dir.y, dir.x)
		_box.draw_colored_polygon(PackedVector2Array([g.ends[i], g.ends[i] - dir * 44.0 + n * 22.0, g.ends[i] - dir * 44.0 - n * 22.0]), col)
	var free_hot: bool = active.get("kind", "") == "free"
	_box.draw_circle(g.centre, GIZMO_RING, Color(1, 1, 1, 0.35 if free_hot else 0.18))
	_box.draw_arc(g.centre, GIZMO_RING, 0.0, TAU, 40, Color(1, 1, 1, 0.95), 5.0, true)


## Ortho views: the bold grid lines' lengths along the left edge (heights in front /
## side views) and the bottom edge.
func _draw_grid_labels() -> void:
	if model == null or camera.view == OrbitCamera.View.PERSPECTIVE:
		return
	var major := major_step()
	var font := ui.get_theme_default_font()
	var right := camera.global_basis.x
	var up := camera.global_basis.y
	var screen := get_viewport().get_visible_rect().size
	var x_label := 210.0
	var y_label := screen.y - 520.0
	for spec in [[up, true], [right, false]]:
		var axis: Vector3 = spec[0]
		var vertical: bool = spec[1]
		var c := camera.target.dot(axis)
		var span := camera.size * 0.6
		var k0 := ceili((c - span) / major)
		var k1 := floori((c + span) / major)
		if k1 - k0 > 40:
			continue
		for k in range(k0, k1 + 1):
			var value := k * major
			var at := camera.target + axis * (value - c)
			var p := camera.unproject_position(at)
			var text := length_text(absf(value)) if k != 0 else "0"
			if value < 0.0:
				text = "−" + text
			if vertical:
				if p.y < 260.0 or p.y > y_label - 50.0:
					continue
				_box.draw_string_outline(font, Vector2(x_label, p.y - 6), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, 6, Color(0, 0, 0, 0.7))
				_box.draw_string(font, Vector2(x_label, p.y - 6), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color(1, 1, 1, 0.85))
			else:
				if p.x < 220.0 or p.x > screen.x - 230.0:
					continue
				_box.draw_string_outline(font, Vector2(p.x + 6, y_label), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, 6, Color(0, 0, 0, 0.7))
				_box.draw_string(font, Vector2(p.x + 6, y_label), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color(1, 1, 1, 0.85))
