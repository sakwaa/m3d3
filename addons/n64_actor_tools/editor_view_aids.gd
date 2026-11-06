@tool
extends Node3D
## Editor-only modelling aids for character scenes (an internal child of the edited
## ActorModel, so it's never saved or exported), matching the phone app:
##  - reference images per axis view (actor_references.gd, saved in the model's
##    metadata), shown while the 3D view looks straight down that axis in orthogonal;
##  - a grid in the view plane at the model's snap size (bold lines every few cells),
##    behind the model, in those views, with the bold lines' distances labelled along
##    the right edge (heights in front / side views) and the bottom.
## While "adjusting", the current view's image shows a handle box: drag inside to move,
## corners scale (opposite corner fixed), sides stretch, the knob rotates (snaps near
## 15° steps). The plugin forwards 3D view input and overlay drawing here and records
## undo (`edited` carries the references from before the change).

signal edited(before: Dictionary, label: String)
## The view the active 3D view shows changed (0 = not an axis view).
signal view_changed(view: int)
## The overlay needs redrawing (the grid labels moved).
signal redraw

const References := preload("res://addons/n64_actor_tools/actor_references.gd")
const DIR := "res://references"
## Snap sizes and their bold-line spacings (the phone app's series).
const GRIDS := [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0]
const MAJORS := [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0]
## Most grid lines either side of the centre (finer grids draw coarser when zoomed out).
const MAX_LINES := 80
const ALIGNED := 0.9999
const VIEW_NAMES := ["", "Front", "Back", "Left", "Right", "Top", "Bottom"]
## Handle sizes (editor-scaled pixels).
const KNOB := 30.0
const HANDLE := 9.0
const OUTLINE := Color(1.0, 0.75, 0.2)

var model: ActorModel
var refs: References
var grid_on := true
## The camera of the 3D view last used (the plugin sets it from input).
var camera: Camera3D
var view := 0
var adjusting := false

var _grid := MeshInstance3D.new()
var _grid_key := []
## Bold-line spacing of the grid on show (0 = none), and the camera it was drawn for.
var _major := 0.0
var _label_key := []
var _box := AABB()
var _grab := {}
## A click outside the image ended adjusting: the rest of it (drag, release) is eaten too.
var _swallow := false
## Blender-style G / R / S in progress ("" none), its typed number, the mouse position,
## and the handle under the mouse ([kind, s]).
var _modal := ""
var _typed := ""
var _mouse := Vector2.ZERO
var _hover: Variant = []
var _before := {}
var _hint := ""
var _scale := 1.0


func setup(m: ActorModel) -> void:
	model = m
	name = "EditorViewAids"
	_scale = EditorInterface.get_editor_scale()
	if not FileAccess.file_exists(DIR.path_join(".gdignore")):
		DirAccess.make_dir_recursive_absolute(DIR)
		FileAccess.open(DIR.path_join(".gdignore"), FileAccess.WRITE)
	refs = References.new()
	refs.dir = DIR
	add_child(refs)
	refs.load_from(model)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.render_priority = -1
	_grid.material_override = mat
	_grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_grid)


## Reloads the references from the model's metadata (after undo / redo).
func reload() -> void:
	refs.load_from(model)
	refs.show_view(view)


## Snapshot for undo.
func snapshot() -> Dictionary:
	return refs.refs.duplicate(true)


## Records a finished change (the plugin turns it into an undo step).
func commit(before: Dictionary, label: String) -> void:
	refs.save_to(model)
	edited.emit(before, label)


func _process(_delta: float) -> void:
	if model == null:
		return
	var cam := camera if is_instance_valid(camera) else null
	if cam == null:
		var svp := EditorInterface.get_editor_viewport_3d(0)
		cam = svp.get_camera_3d() if svp else null
	if cam == null:
		return
	camera = cam
	var box := model.mesh_instance.mesh.get_aabb() if model.mesh_instance and model.mesh_instance.mesh else AABB()
	if box != _box and box.size != Vector3.ZERO:
		_box = box
		refs.set_model_box(box)
	var v := view_of(cam)
	if v != view:
		view = v
		refs.show_view(v)
		if v == 0:
			adjusting = false
			_grab = {}
		view_changed.emit(v)
	_update_grid(cam)
	var key := [cam.global_transform, cam.size, _major, cam.get_viewport().get_visible_rect().size] if _major > 0.0 else []
	if key != _label_key:
		_label_key = key
		redraw.emit()


## The reference view (1-6) `cam` looks straight along in orthogonal, else 0.
func view_of(cam: Camera3D) -> int:
	if cam.projection != Camera3D.PROJECTION_ORTHOGONAL:
		return 0
	var fwd := -cam.global_basis.z
	for v in References.VIEW_AXES:
		if fwd.dot(References.VIEW_AXES[v][0]) > ALIGNED:
			return v
	return 0


# --- Grid ---------------------------------------------------------------------------------

func _update_grid(cam: Camera3D) -> void:
	if not grid_on or view == 0:
		if _grid.mesh:
			_grid.mesh = null
			_grid_key = []
		_major = 0.0
		return
	var size := cam.get_viewport().get_visible_rect().size
	var extent := cam.size * 0.5 * maxf(size.x / maxf(size.y, 1.0), 1.0) * 1.1
	# The model's snap size, coarser (along the series) when the lines would crowd.
	var i := _grid_index(model.data.model_grid)
	var step: float = GRIDS[i] if i >= 0 else model.data.model_grid
	var major: float = MAJORS[i] if i >= 0 else step * 4.0
	while extent / step > MAX_LINES:
		i += 1
		if i >= GRIDS.size():
			step *= 5.0
			major *= 5.0
		else:
			step = GRIDS[i]
			major = MAJORS[i]
	_major = major
	var centre := refs.to_plane(view, cam.global_position)
	var key := [view, step, roundi(centre.x / step), roundi(centre.y / step), roundi(extent / step), refs._depth(view)]
	if key == _grid_key:
		return
	_grid_key = key
	_grid.mesh = _grid_mesh(centre, step, major, extent)


## Lines on multiples of `step` in the view plane (just in front of the reference image);
## bold every `major`, brighter on whole metres, brightest through the origin.
func _grid_mesh(centre: Vector2, step: float, major: float, extent: float) -> ArrayMesh:
	var n := mini(int(extent / step) + 1, MAX_LINES)
	var ci := roundi(centre.x / step)
	var cj := roundi(centre.y / step)
	var depth := refs._depth(view) - 0.01
	var axes := refs._axes(view)
	var lines := PackedVector3Array()
	var cols := PackedColorArray()
	for k in range(-n, n + 1):
		for horizontal in [false, true]:
			var idx: int = (cj if horizontal else ci) + k
			var at := idx * step
			var bold := absf(at / major - roundf(at / major)) < 1e-3
			var metre := absf(at - roundf(at)) < 1e-4
			var c := Color(1, 1, 1, 0.3 if idx == 0 else (0.2 if metre and bold else (0.12 if bold else 0.045)))
			var a: Vector2
			var b: Vector2
			if horizontal:
				a = Vector2((ci - n) * step, at)
				b = Vector2((ci + n) * step, at)
			else:
				a = Vector2(at, (cj - n) * step)
				b = Vector2(at, (cj + n) * step)
			for p: Vector2 in [a, b]:
				lines.append(axes[0] * p.x + axes[1] * p.y + axes[2] * depth)
				cols.append(c)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	arrays[Mesh.ARRAY_COLOR] = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return m


static func _grid_index(g: float) -> int:
	for i in GRIDS.size():
		if absf(GRIDS[i] - g) < 1e-6:
			return i
	return -1


# --- Adjusting the image -------------------------------------------------------------------

func set_adjusting(on: bool) -> void:
	adjusting = on and view != 0 and not refs.get_ref(view).is_empty()
	_grab = {}
	_hover = []
	_hint = "Reference: drag inside to move, corners scale, sides stretch, ○ rotates (Shift: keep shape, Ctrl: 15° steps) · G / R / S + mouse or a number (R90) · click outside / Esc when done." if adjusting else ""


## A double-click on the current view's unlocked image (empty space) starts adjusting.
func try_select(cam: Camera3D, pos: Vector2) -> bool:
	var r := refs.get_ref(view)
	if view == 0 or r.is_empty() or not r.get("visible", true) or r.get("locked", false):
		return false
	if not refs.contains(view, _plane(cam, pos)):
		return false
	set_adjusting(true)
	return true


## 3D view input while adjusting; true = used.
func gui_input(cam: Camera3D, event: InputEvent) -> bool:
	camera = cam
	if _swallow:
		var b := event as InputEventMouseButton
		if b and b.button_index == MOUSE_BUTTON_LEFT and not b.pressed:
			_swallow = false
		return event is InputEventMouse
	if not adjusting:
		return false
	if _modal != "":
		return _modal_input(cam, event)
	var key := event as InputEventKey
	if key and key.pressed and not key.echo:
		if key.keycode in [KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER]:
			set_adjusting(false)
			return true
		if key.keycode in [KEY_G, KEY_R, KEY_S] and not (key.ctrl_pressed or key.meta_pressed or key.alt_pressed):
			_start_modal(cam, {KEY_G: "move", KEY_R: "rotate", KEY_S: "scale"}[key.keycode])
			return true
		return false
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_grab = _grab_at(cam, mb.position)
			if _grab.is_empty():
				set_adjusting(false)
				_swallow = true
			else:
				_before = snapshot()
			return true
		if not _grab.is_empty():
			_grab = {}
			if refs.refs != _before:
				commit(_before, "Adjust reference image")
		return true
	var mm := event as InputEventMouseMotion
	if mm:
		_mouse = mm.position
		if not _grab.is_empty() and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_transform(_plane(cam, mm.position), mm.shift_pressed, mm.ctrl_pressed or mm.meta_pressed)
			return true
		var hover := _grab_at(cam, mm.position)
		var h: Variant = [hover.get("kind", ""), hover.get("s", Vector2.ZERO)]
		if h != _hover:
			_hover = h
			redraw.emit()
	return false


# --- Blender-style keys: G / R / S, then mouse or a typed number ------------------------------

## Starts a modal move / rotate / scale from the mouse's position (like Blender's G / R /
## S): the mouse drives it, or type a number for R (degrees) and S (factor); Ctrl snaps
## (grid / 15° / 0.1×); Enter or a click confirms, Esc or right click cancels.
func _start_modal(cam: Camera3D, kind: String) -> void:
	var f := refs.frame(view)
	if f.is_empty():
		return
	_modal = kind
	_typed = ""
	_before = snapshot()
	_grab = {kind = kind, start = f, p0 = _plane(cam, _mouse), m0 = _mouse,
		c_screen = cam.unproject_position(refs.to_world(view, f.centre))}
	_modal_apply(cam, false)


func _modal_input(cam: Camera3D, event: InputEvent) -> bool:
	var key := event as InputEventKey
	if key and key.pressed:
		var ctrl := key.ctrl_pressed or key.meta_pressed
		match key.keycode:
			KEY_ESCAPE:
				_end_modal(false)
			KEY_ENTER, KEY_KP_ENTER:
				_end_modal(true)
			KEY_BACKSPACE:
				_typed = _typed.left(-1)
				_modal_apply(cam, ctrl)
			KEY_MINUS, KEY_KP_SUBTRACT:
				_typed = _typed.substr(1) if _typed.begins_with("-") else "-" + _typed
				_modal_apply(cam, ctrl)
			KEY_PERIOD, KEY_KP_PERIOD:
				if not _typed.contains("."):
					_typed += "."
					_modal_apply(cam, ctrl)
			_:
				var digit := -1
				if key.keycode >= KEY_0 and key.keycode <= KEY_9:
					digit = key.keycode - KEY_0
				elif key.keycode >= KEY_KP_0 and key.keycode <= KEY_KP_9:
					digit = key.keycode - KEY_KP_0
				if digit >= 0 and _modal != "move":
					_typed += str(digit)
					_modal_apply(cam, ctrl)
		return true
	var mb := event as InputEventMouseButton
	if mb and mb.pressed:
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_end_modal(true)
			_swallow = true
			return true
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_end_modal(false)
			_swallow = true
			return true
		return false
	var mm := event as InputEventMouseMotion
	if mm:
		_mouse = mm.position
		_modal_apply(cam, mm.ctrl_pressed or mm.meta_pressed)
		return true
	return event is InputEventMouse


func _modal_apply(cam: Camera3D, snap: bool) -> void:
	var g := _grab
	var f: Dictionary = g.start
	var c: Vector2 = f.centre
	var full: Vector2 = f.half * 2.0
	var a: float = f.angle
	var typed := _typed.trim_suffix(".")
	var has_number := typed != "" and typed != "-"
	match _modal:
		"move":
			var d := _plane(cam, _mouse) - (g.p0 as Vector2)
			if snap:
				d = d.snapped(Vector2.ONE * model.data.model_grid)
			refs.set_frame(view, c + d, full, a)
			_hint = "Move %s, %s   (Ctrl snaps to the grid · Enter / click confirms · Esc cancels)" % [_length_signed(d.x), _length_signed(d.y)]
		"rotate":
			var da: float
			if has_number:
				# Typed degrees turn counter-clockwise on screen (like Blender).
				da = deg_to_rad(float(typed)) * _screen_ccw(cam)
			else:
				var cs: Vector2 = g.c_screen
				# Screen y points down: a clockwise screen turn is a positive angle there.
				da = -((_mouse - cs).angle() - ((g.m0 as Vector2) - cs).angle()) * _screen_ccw(cam)
				da = snappedf(da, PI / 12.0) if snap else da
			var ang := a + da
			if not has_number and not snap:
				ang = _magnet(ang)
			refs.set_frame(view, c, full, ang)
			_hint = "Rotate %s°   (type degrees, Ctrl snaps 15° · Enter / click confirms · Esc cancels)" % (typed if has_number else str(snappedf(rad_to_deg(ang - a) * _screen_ccw(cam), 0.1)))
		"scale":
			var k: float
			if has_number:
				k = float(typed)
			else:
				var cs: Vector2 = g.c_screen
				k = _mouse.distance_to(cs) / maxf((g.m0 as Vector2).distance_to(cs), 1.0)
				k = snappedf(k, 0.1) if snap else k
			k = maxf(absf(k), 0.01)
			refs.set_frame(view, c, full * k, a)
			_hint = "Scale ×%s   (type a factor, Ctrl snaps 0.1 · Enter / click confirms · Esc cancels)" % (typed if has_number else str(snappedf(k, 0.01)))
	redraw.emit()


func _end_modal(confirm: bool) -> void:
	var label: String = {"move": "Move", "rotate": "Rotate", "scale": "Scale"}.get(_modal, "Adjust") + " reference image"
	if not confirm:
		var f: Dictionary = _grab.start
		refs.set_frame(view, f.centre, f.half * 2.0, f.angle)
	_modal = ""
	_typed = ""
	_grab = {}
	if confirm and refs.refs != _before:
		commit(_before, label)
	set_adjusting(true)
	redraw.emit()


## 1 when the view plane's angle runs counter-clockwise on screen, -1 when mirrored.
func _screen_ccw(cam: Camera3D) -> float:
	var axes := refs._axes(view)
	return signf((axes[0] as Vector3).dot(cam.global_basis.x) * (axes[1] as Vector3).dot(cam.global_basis.y))


## Turns the current view's image by `degrees` counter-clockwise on screen (one undo step).
func rotate_by(degrees: float) -> void:
	var f := refs.frame(view)
	if f.is_empty():
		return
	var before := snapshot()
	var sense := _screen_ccw(camera) if is_instance_valid(camera) else 1.0
	refs.set_frame(view, f.centre, f.half * 2.0, f.angle + deg_to_rad(degrees) * sense)
	commit(before, "Rotate reference image")
	redraw.emit()


static func _length_signed(m: float) -> String:
	return ("−" if m < 0.0 else "") + _length(absf(m))


func _plane(cam: Camera3D, pos: Vector2) -> Vector2:
	return refs.to_plane(view, cam.project_ray_origin(pos))


func _screen(cam: Camera3D, f: Dictionary, local: Vector2) -> Vector2:
	return cam.unproject_position(refs.to_world(view, f.centre + local.rotated(f.angle)))


func _world_per_pixel(cam: Camera3D) -> float:
	return cam.size / maxf(cam.get_viewport().get_visible_rect().size.y, 1.0)


## The image's handles on screen: {outline, handles: [{kind, s, at}], frame}.
func _handles(cam: Camera3D) -> Dictionary:
	var f := refs.frame(view)
	if f.is_empty():
		return {}
	var h: Vector2 = f.half
	var outline := PackedVector2Array()
	for s in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1)]:
		outline.append(_screen(cam, f, s * h))
	var handles := []
	var knob := Vector2(0, h.y + KNOB * _scale * _world_per_pixel(cam))
	handles.append({kind = "rotate", s = Vector2.ZERO, at = _screen(cam, f, knob), from = _screen(cam, f, Vector2(0, h.y))})
	for s in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1), Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
		handles.append({kind = "scale", s = s, at = _screen(cam, f, s * h)})
	return {outline = outline, handles = handles, frame = f}


## What a click grabs: a handle, the image (move) or {} (outside).
func _grab_at(cam: Camera3D, pos: Vector2) -> Dictionary:
	var rh := _handles(cam)
	if rh.is_empty():
		return {}
	var best := {}
	var best_d := HANDLE * 2.2 * _scale
	for hd in rh.handles:
		var d: float = pos.distance_to(hd.at)
		if d < best_d:
			best_d = d
			best = hd
	var p := _plane(cam, pos)
	if not best.is_empty():
		return {kind = best.kind, s = best.s, start = rh.frame, p0 = p}
	if refs.contains(view, p):
		return {kind = "move", start = rh.frame, p0 = p}
	return {}


## Drag from the grab's start frame to plane point `p`. Shift on a side handle scales
## proportionally about the opposite side.
func _transform(p: Vector2, keep_aspect: bool, snap := false) -> void:
	var g := _grab
	var f: Dictionary = g.start
	var c: Vector2 = f.centre
	var half: Vector2 = f.half
	var a: float = f.angle
	match g.kind:
		"move":
			refs.set_frame(view, c + p - g.p0, half * 2.0, a)
			_hint = ""
		"rotate":
			var ang: float = a + (p - c).angle() - (g.p0 - c).angle()
			ang = snappedf(ang, PI / 12.0) if snap else _magnet(ang)
			refs.set_frame(view, c, half * 2.0, ang)
			_hint = "Reference %d°" % roundi(rad_to_deg(ang))
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
				var w := maxf(s.x * (q.x - anchor.x), 0.01)
				full = full * (w / full.x) if keep_aspect else Vector2(w, full.y)
			else:
				var hgt := maxf(s.y * (q.y - anchor.y), 0.01)
				full = full * (hgt / full.y) if keep_aspect else Vector2(full.x, hgt)
			refs.set_frame(view, c + (anchor + s * full * 0.5).rotated(a), full, a)
			_hint = "Reference %s × %s" % [_length(full.x), _length(full.y)]


## Angles near a multiple of 15° snap to it.
static func _magnet(a: float) -> float:
	var n := snappedf(a, PI / 12.0)
	return n if absf(a - n) < deg_to_rad(2.0) else a


static func _length(m: float) -> String:
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


func draw(overlay: Control, cam: Camera3D) -> void:
	if cam == null or view == 0:
		return
	_draw_grid_labels(overlay, cam)
	if not adjusting:
		return
	var rh := _handles(cam)
	if rh.is_empty():
		return
	var w := 1.5 * _scale
	# What a click would grab is drawn solid (the outline: the image itself, to move).
	var hover_kind: String = _hover[0] if _hover.size() == 2 and _modal == "" else ""
	overlay.draw_polyline(rh.outline, OUTLINE, w * (2.0 if hover_kind == "move" else 1.0))
	for hd in rh.handles:
		var hot: bool = hover_kind == hd.kind and _hover[1] == hd.s
		if hd.kind == "rotate":
			overlay.draw_line(hd.from, hd.at, OUTLINE, w)
			overlay.draw_circle(hd.at, HANDLE * _scale, OUTLINE if hot else Color(0.1, 0.1, 0.1, 0.8))
			overlay.draw_arc(hd.at, HANDLE * _scale, 0.0, TAU, 24, OUTLINE, w)
		else:
			var r := Rect2(hd.at - Vector2.ONE * HANDLE * 0.6 * _scale, Vector2.ONE * HANDLE * 1.2 * _scale)
			overlay.draw_rect(r, OUTLINE if hot else Color(0.1, 0.1, 0.1, 0.8))
			overlay.draw_rect(r, OUTLINE, false, w)
	if _modal in ["rotate", "scale"]:
		overlay.draw_dashed_line(_grab.c_screen, _mouse, OUTLINE, w, 6.0 * _scale)
	if _hint != "":
		var font := overlay.get_theme_default_font()
		var fs := int(13 * _scale)
		var at := Vector2(12, overlay.size.y - 14) * Vector2(_scale, 1)
		overlay.draw_string_outline(font, at, _hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, int(4 * _scale), Color(0, 0, 0, 0.8))
		overlay.draw_string(font, at, _hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, OUTLINE)


## The bold grid lines' distances (metres in the view plane: right, up) along the right
## edge and the bottom, clear of the tool strip and the view gizmo.
func _draw_grid_labels(overlay: Control, cam: Camera3D) -> void:
	if _major <= 0.0:
		return
	var font := overlay.get_theme_default_font()
	var fs := int(12 * _scale)
	var size := overlay.size
	var right_x := size.x - 64.0 * _scale
	var bottom_y := size.y - 34.0 * _scale
	var centre := refs.to_plane(view, cam.global_position)
	var half := Vector2(cam.size * 0.5 * size.x / maxf(size.y, 1.0), cam.size * 0.5)
	for vertical in [true, false]:
		var c: float = centre.y if vertical else centre.x
		var span: float = half.y if vertical else half.x
		var k0 := ceili((c - span) / _major)
		var k1 := floori((c + span) / _major)
		if k1 - k0 > 40:
			continue
		for k in range(k0, k1 + 1):
			var value := k * _major
			var plane := Vector2(centre.x, value) if vertical else Vector2(value, centre.y)
			var p := cam.unproject_position(refs.to_world(view, plane))
			var text := "0" if k == 0 else ("−" if value < 0.0 else "") + _length(absf(value))
			var at: Vector2
			if vertical:
				if p.y < 180.0 * _scale or p.y > bottom_y - 24.0 * _scale:
					continue
				at = Vector2(right_x, p.y - 4.0 * _scale)
			else:
				if p.x < 90.0 * _scale or p.x > right_x - 50.0 * _scale:
					continue
				at = Vector2(p.x + 4.0 * _scale, bottom_y)
			overlay.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, int(4 * _scale), Color(0, 0, 0, 0.7))
			overlay.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.85))
