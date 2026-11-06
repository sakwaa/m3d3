@tool
class_name LevelGradientTool
extends RefCounted
## Gradient for overlay layers: writes a coverage ramp into the face masks of a set of faces
## (the face mask, else just the clicked face), along a direction:
##  - click: a preset direction (up, down, or left / right / away / toward as seen from the
##    camera, or a diagonal: corner to corner), 0 – 100 % spanning the faces;
##  - drag: from the press point (0 %) to the release point (100 %), any direction.
## The ramp is a list of stops (position, coverage) drawn Fade (linear), Smooth or Sharp
## (coverage holds until the next stop: hard edges). With a second layer the two textures
## blend into each other: the upper one fades over the lower one, which fills underneath so
## the base never shows through. Baked into the masks (one undo step): plain paint after,
## except the last gradient, which changing the options re-applies (until it's painted over).

enum Style { FADE, SMOOTH, SHARP }
enum Dir { UP, DOWN, LEFT, RIGHT, AWAY, TOWARD, UP_LEFT, UP_RIGHT, DOWN_LEFT, DOWN_RIGHT }
const STYLE_NAMES := ["Fade", "Smooth", "Sharp"]
const DIR_NAMES := ["Up", "Down", "Left", "Right", "Away", "Toward", "Up-left (corner)", "Up-right (corner)",
	"Down-left (corner)", "Down-right (corner)"]
## name -> [stops, style].
const PRESETS := {
	"Fade": [[Vector2(0, 1), Vector2(1, 0)], Style.FADE],
	"Hard stop 50%": [[Vector2(0, 1), Vector2(0.5, 0)], Style.SHARP],
	"Fade out from 50%": [[Vector2(0, 1), Vector2(0.5, 1), Vector2(1, 0)], Style.SMOOTH],
	"Band (middle)": [[Vector2(0, 0), Vector2(0.35, 1), Vector2(0.65, 0)], Style.SHARP],
	"Soft band": [[Vector2(0, 0), Vector2(0.5, 1), Vector2(1, 0)], Style.SMOOTH],
}

## (position 0 – 1, coverage 0 – 1), sorted by position.
var stops := PackedVector2Array([Vector2(0, 1), Vector2(1, 0)])
var style := Style.FADE
var direction := Dir.UP
## Overlay index the active layer blends into (-1: none, texture -> no texture).
var second_layer := -1
## Keep paint already stronger than the gradient (else the gradient replaces it).
var keep_stronger := false

var undo: EditorUndoRedoManager
var _op := {}
## The last committed gradient (its op, and the masks it wrote): reapply() redoes it.
var _last := {}


## Coverage at `t` (0 – 1 along the gradient).
func sample(t: float) -> float:
	if stops.is_empty():
		return 0.0
	if t <= stops[0].x:
		return stops[0].y
	for i in range(1, stops.size()):
		var b := stops[i]
		if t < b.x:
			var a := stops[i - 1]
			if style == Style.SHARP:
				return a.y
			var f := (t - a.x) / maxf(b.x - a.x, 1e-6)
			if style == Style.SMOOTH:
				f = smoothstep(0.0, 1.0, f)
			return lerpf(a.y, b.y, f)
	return stops[stops.size() - 1].y


func sort_stops() -> void:
	var list := Array(stops)
	list.sort_custom(func(a, b): return a.x < b.x)
	stops = PackedVector2Array(list)


func reverse() -> void:
	var out := PackedVector2Array()
	var n := stops.size()
	if style == Style.SHARP:
		# Each stop's coverage holds up to the next stop: mirrored, a segment's value starts
		# where its next stop was.
		out.append(Vector2(0.0, stops[n - 1].y))
		for i in range(n - 1, 0, -1):
			var at := 1.0 - stops[i].x
			if is_equal_approx(out[out.size() - 1].x, at):
				out[out.size() - 1] = Vector2(at, stops[i - 1].y)
			else:
				out.append(Vector2(at, stops[i - 1].y))
	else:
		for i in range(n - 1, -1, -1):
			out.append(Vector2(1.0 - stops[i].x, stops[i].y))
	stops = out


func apply_preset(name: String) -> void:
	var p: Array = PRESETS[name]
	stops = PackedVector2Array(p[0])
	style = p[1]


## World direction of a preset, seen from `camera_basis`, on faces with normal `n`. Up is
## world up along the faces (on a floor: away from the camera; looking straight down:
## screen up), left / right are square to it, so every direction lies on the faces.
## Diagonals: corner to corner (0 % in the opposite corner, 100 % in the named one).
func preset_axis(camera_basis: Basis, n: Vector3) -> Vector3:
	var up := _along(Vector3.UP, n)
	if up.length() < 0.1:
		up = _along(-camera_basis.z, n)
	if up.length() < 0.1:
		up = _along(camera_basis.y, n)
	up = up.normalized()
	var side := _along(camera_basis.x, n)
	side -= up * side.dot(up)
	side = side.normalized() if side.length() > 0.1 else up.cross(n).normalized()
	var away := _along(-camera_basis.z, n)
	if away.length() < 0.1:
		away = _along(camera_basis.y, n)  # straight down at a floor: away = screen up
	away = away.normalized() if away.length() > 0.001 else up
	var v := up
	match direction:
		Dir.DOWN: v = -up
		Dir.LEFT: v = -side
		Dir.RIGHT: v = side
		Dir.AWAY: v = away
		Dir.TOWARD: v = -away
		Dir.UP_LEFT: v = up - side
		Dir.UP_RIGHT: v = up + side
		Dir.DOWN_LEFT: v = -up - side
		Dir.DOWN_RIGHT: v = -up + side
	return v.normalized() if v.length() > 0.001 else Vector3.RIGHT


static func _along(v: Vector3, n: Vector3) -> Vector3:
	return v - n * v.dot(n)


## The faces a gradient started on `face` covers: the face mask, else just that face.
static func targets_for(paint: LevelPaintTool, brush: LevelBrush, face: int) -> Array:
	if paint.face_mask.is_empty():
		return [{brush = brush, face = face}]
	var out := []
	for key in paint.face_mask:
		if key[0] != null and key[1] < key[0].get_face_count():
			out.append({brush = key[0], face = key[1]})
	return out


## 0 % and 100 % points spanning `targets` along `axis` (world).
static func fit(root: LevelRoot, targets: Array, axis: Vector3) -> Array:
	var lo := INF
	var hi := -INF
	var centre := Vector3.ZERO
	var count := 0
	for t in targets:
		var xf := root.brush_global_transform(t.brush)
		for p: Vector3 in t.brush.get_face_points(t.face):
			var w := xf * p
			var d := w.dot(axis)
			lo = minf(lo, d)
			hi = maxf(hi, d)
			centre += w
			count += 1
	if count == 0:
		return [Vector3.ZERO, axis]
	centre /= count
	var base := centre - axis * centre.dot(axis)
	return [base + axis * lo, base + axis * maxf(hi, lo + 0.001)]


func is_active() -> bool:
	return not _op.is_empty()


## Starts a gradient on `targets` for overlay `layer` (the masks before are kept to restore).
func begin(root: LevelRoot, targets: Array, layer: int, strength: float, erase: bool) -> void:
	var layers := [layer]
	if second_layer >= 0 and second_layer != layer and second_layer < root.data.active_layers().size() and not erase:
		layers.append(second_layer)
	var before := {}
	for t in targets:
		for l in layers:
			before[[t.brush, t.face, l]] = t.brush.get_face_mask(t.face, l)
	_op = {root = root, targets = targets, layer = layer, layers = layers, strength = strength, erase = erase,
		before = before, created = {}, from = Vector3.ZERO, to = Vector3.ZERO}


## Writes the gradient from `from` (0 %) to `to` (100 %) into the masks, live (no undo yet).
func preview(from: Vector3, to: Vector3) -> void:
	if _op.is_empty():
		return
	_op.from = from
	_op.to = to
	var root: LevelRoot = _op.root
	var span := to - from
	var len2 := maxf(span.length_squared(), 1e-8)
	var rebuild := false
	var a: int = _op.layer
	var b: int = _op.layers[1] if _op.layers.size() > 1 else -1
	for t in _op.targets:
		var brush: LevelBrush = t.brush
		var face: int = t.face
		var n := brush.get_face_normal(face)
		if n == Vector3.ZERO:
			continue
		var d := n.dot(brush.vertices[brush.get_face_vertex_ids(face)[0]])
		var rect := brush.get_face_planar_rect(face)
		var xf := root.brush_global_transform(brush)
		var first: Image = _op.before[[brush, face, a]]
		var sz := first.get_size() if first else brush.get_face_mask_size(face, root.data.mask_density)
		var g := PackedFloat32Array()
		g.resize(sz.x * sz.y)
		for y in sz.y:
			for x in sz.x:
				var uv := rect.position + (Vector2(x, y) + Vector2(0.5, 0.5)) / Vector2(sz) * rect.size
				var w := xf * PolyUtil.planar_unproject(uv, n, d)
				g[y * sz.x + x] = sample(clampf((w - from).dot(span) / len2, 0.0, 1.0))
		for l in _op.layers:
			# A pair: the upper layer takes its share of the gradient, the lower one fills
			# fully underneath (so the base never shows through the blend).
			var share := 1
			if l == b:
				share = -1 if b > a else 2
			elif b >= 0 and b > a:
				share = 2
			var img := _write(_op.before[[brush, face, l]], sz, g, share)
			brush.set_face_mask(face, l, img, false)
			var key := [brush, face, l]
			if _op.created.has(key) or _op.before[key] != null:
				root.update_mask_live(brush, face, l)
			else:
				# A new mask needs an atlas chart: relayout once, then it updates in place.
				_op.created[key] = true
				rebuild = true
	if rebuild:
		root.request_rebuild()


## Coverage image: `share` 1 = gradient, -1 = inverse gradient, 2 = full; combined with
## what was there (replace, keep stronger, or erase).
func _write(before: Image, sz: Vector2i, g: PackedFloat32Array, share: int) -> Image:
	var old := PackedByteArray()
	if before:
		var b := before
		if b.get_format() != Image.FORMAT_L8:
			b = before.duplicate()
			b.convert(Image.FORMAT_L8)
		old = b.get_data()
	var out := PackedByteArray()
	out.resize(sz.x * sz.y)
	var s: float = _op.strength
	for i in out.size():
		var v := 1.0 if share == 2 else (g[i] if share == 1 or share == 0 else 1.0 - g[i])
		var prev := old[i] / 255.0 if i < old.size() else 0.0  # no mask before: nothing painted
		var r: float
		if _op.erase:
			r = prev * (1.0 - v * s)
		elif keep_stronger:
			r = maxf(prev, v * s)
		else:
			r = lerpf(prev, v, s)
		out[i] = int(roundf(clampf(r, 0.0, 1.0) * 255.0))
	return Image.create_from_data(sz.x, sz.y, false, Image.FORMAT_L8, out)


## Keeps the masks as they are now: one undo step (`prior`: the masks to undo to, else the
## ones from before the gradient).
func commit(action := "Paint Gradient", prior := {}) -> void:
	if _op.is_empty():
		return
	var root: LevelRoot = _op.root
	var wrote := {}
	undo.create_action(action, UndoRedo.MERGE_ENDS if action != "Paint Gradient" else UndoRedo.MERGE_DISABLE, root)
	for key in _op.before:
		var brush: LevelBrush = key[0]
		wrote[key] = brush.get_face_mask(key[1], key[2])
		undo.add_do_method(brush, &"set_face_mask", key[1], key[2], wrote[key])
		undo.add_undo_method(brush, &"set_face_mask", key[1], key[2], prior.get(key, _op.before[key]))
	for key in prior:
		if not _op.before.has(key):  # a layer the edit dropped (Blend into changed)
			var brush: LevelBrush = key[0]
			undo.add_do_method(brush, &"set_face_mask", key[1], key[2], brush.get_face_mask(key[1], key[2]))
			undo.add_undo_method(brush, &"set_face_mask", key[1], key[2], prior[key])
	undo.commit_action()
	_last = {op = _op, wrote = wrote}
	_op = {}


## The last gradient's {root, targets, from, to}, while its masks are as it left them.
func last_gradient() -> Dictionary:
	if _last.is_empty():
		return {}
	for key in _last.wrote:
		if not is_instance_valid(key[0]) or key[0].get_face_mask(key[1], key[2]) != _last.wrote[key]:
			_last = {}  # painted over or undone: no longer editable
			return {}
	return _last.op


## Redoes the last gradient with the current options, from `from` to `to` (one undo step,
## merged with the next tweaks). False when there's none to redo.
func reapply(from: Vector3, to: Vector3) -> bool:
	var last := last_gradient()
	if last.is_empty() or is_active():
		return false
	var prior := {}
	for key in _last.wrote:
		prior[key] = _last.wrote[key]
	var dropped := false
	for key in last.before:
		key[0].set_face_mask(key[1], key[2], last.before[key], false)
	begin(last.root, last.targets, last.layer, last.strength, last.erase)
	for key in last.before:
		if not _op.before.has(key):
			_op.before[key] = last.before[key]  # restored, so undo / redo cover it too
			dropped = dropped or prior[key] != null
	for key in _op.before:
		if not prior.has(key):
			prior[key] = _op.before[key]
	preview(from, to)
	if dropped:
		last.root.request_rebuild()
	commit("Edit Gradient", prior)
	return true


## Puts the masks back as they were.
func cancel() -> void:
	if _op.is_empty():
		return
	for key in _op.before:
		key[0].set_face_mask(key[1], key[2], _op.before[key], false)
	_op.root.request_rebuild()
	_op = {}


func gradient_ends() -> Array:
	return [_op.from, _op.to] if not _op.is_empty() else []
