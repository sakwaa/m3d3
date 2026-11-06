class_name LevelPaintTool
extends RefCounted
## Paint-mode state and operations: brush / erase strokes into overlay masks (or base
## texture assignment, or vertex colours), face fill and normal-based fill, all undoable.
## Layer 0 is the base layer (per-face texture); layer n is overlay n - 1;
## VERTEX_LAYER paints per-vertex colours.

enum Tool { BRUSH, ERASE, FILL_FACE, FILL_NORMAL, FACE, FILL_SAME, SCATTER, PLACE, GRADIENT, BORDER }
const VERTEX_LAYER := -1
## Paints per-face Surface overrides (footstep sound | gameplay flags), whole faces.
const SURFACE_LAYER := -2
## AUTO: whatever the clicked face is (floor -> facing up, wall -> walls, ceiling -> down).
enum Direction { UP, DOWN, WALLS, ALL, AUTO }
const TOOL_NAMES := ["Brush", "Erase", "Fill Face", "Fill by Normal", "Paint Face", "Fill Same Texture",
	"Scatter", "Place", "Gradient", "Border"]
const DIRECTION_NAMES := ["Facing up", "Facing down", "Walls", "All faces", "Auto (clicked face)"]

var tool := Tool.BRUSH
var layer := 0
var base_texture: Texture2D
## Vertex colour layer: colour painted towards (erase returns to white).
var vertex_color := Color(0.45, 0.4, 0.38)
## SURFACE_LAYER: the override painted (Surface sound | flags; 0 = none).
var surface_value := 0
## Brush radius in metres.
var size := 1.0
## Max opacity a stroke reaches (Photoshop-style: repeated stamps in one stroke don't exceed it).
var strength := 1.0
## 0 = soft falloff from the centre, 1 = hard edge.
var hardness := 0.5
## Custom brush (greyscale, white = paint). Null = round brush.
var shape: Image
## Rotate custom brush stamps randomly so repeated stamps don't form visible rows.
var scatter_rotation := true
var direction := Direction.AUTO
## World normal of the face under the cursor; set by the plugin, drives Direction.AUTO.
var clicked_normal := Vector3.UP
## Max angle (degrees) between a face and the fill direction.
var angle := 30.0
## Fill by Normal on overlays: width (degrees) of the soft transition around `angle`,
## using smoothed vertex normals so coverage blends across face borders. 0 = hard,
## whole faces (the base layer is always per face).
var soft_edge := 15.0

## Strokes (brush, erase, paint face) only touch the brush they start on, so sweeping
## past a wall standing on the ground doesn't paint it.
var stay_on_brush := true
## Colouring the base texture is painted with (Paint panel, "this paint" mode): palette
## ([dark, light] or empty), color, variation, tile (0 = default). Empty = the texture as
## the level has it. Painting with a look puts a TextureLook in the level palette (one per
## distinct look), so faces painted before keep theirs.
var look := {}
## How the look's colour is painted. VERTEX: as the painted faces' vertex colours (no new
## palette entry; shades like vertex painting, which can keep refining it). TEXTURE: inside
## the TextureLook, like the palette.
## RECOLOUR: vertex colours like VERTEX, and the faces get the texture's recolour look:
## the texture keeps only its brightness detail and takes the colour (not a multiply).
enum ColorMode { VERTEX, TEXTURE, RECOLOUR }
var color_mode := ColorMode.VERTEX
## Base texture rotation (degrees, quarter turns) given to the faces it's painted on.
var rotation := 0.0
## Base texture "Follow slope" (LevelBrush.uv_follows_slope) given to the faces it's
## painted on, like `rotation`.
var follow_slope := false
## Face UV (offset u, offset v, scale) picked along with `base_texture` (pick_face):
## while that texture is the one selected, painted faces get it too (rotation stays
## `rotation`). null = faces keep their own offset / scale.
var picked_uv: Variant = null
var _picked_texture: Texture2D
## Border tool: width (m) of the band painted inside the region's outer edge.
var border_width := 1.0
## Border tool: turn the overlay on each border face so the texture's width (its long side,
## e.g. a brick's) runs along the edge.
var border_follow := true
## Border tool corners (with border_follow), where the band turns between running along the
## texture's width and its height: the faces there are cut so each side's texture runs its
## own way. BUTT: the band along the texture's width runs straight through the corner, the
## other stops against its inner edge. MITRE: the two meet on the 45° line.
enum Corner { BUTT, MITRE }
const CORNER_NAMES := ["Butt (straight seam)", "Mitre (45°)"]
var border_corner := Corner.BUTT
## Border tool (Texture follows the edge): which way the texture lies on the band.
## CONTINUE: the texture carries on from the face across the edge, as if that surface were
## folded over it (a stair's steps onto its side, a hilltop's grass down its slope).
enum Lay { ALONG, ACROSS, ALONG_FLIPPED, ACROSS_FLIPPED, CONTINUE }
const LAY_NAMES := ["Along the edge", "Across the edge", "Along, flipped", "Across, flipped",
	"Continue the neighbour (seamless)"]
## Extra overlay quarter turns per Lay, on top of the along-the-edge frame.
const LAY_TURNS := [0, 3, 2, 1, 0]
var border_direction := Lay.ALONG
## Border tool: sides of the area's outline left out (side keys, see border_sides; Alt+click
## an edge to toggle). Empty = every side.
var border_off := {}
## Border tool: metres over which the band's inner edge fades out (0 = hard). A soft edge
## lets the layer's Height blend break it up along the texture (grass creeping up a wall).
var border_soft := 0.0
## Face mask (Cmd/Ctrl+click in Paint mode): when not empty, every tool only paints these
## faces. [brush, face] -> true.
var face_mask := {}

## Where the last brush / erase stroke ended (Alt+click draws a line on from there), its
## level and brush; null = no stroke yet.
var line_from: Variant = null
var line_root: LevelRoot
var line_brush: LevelBrush

var undo: EditorUndoRedoManager:
	set(value):
		undo = value
		scatter.undo = value
		gradient.undo = value
## Scatter / Place: flowers, grass tufts (ScatterSet).
var scatter := LevelScatterTool.new()
## Gradient: coverage ramps for overlay layers.
var gradient := LevelGradientTool.new()
## The brush the current stroke is held to (stay_on_brush), else null.
var _only: LevelBrush


func stroke_brush() -> LevelBrush:
	return _only if not _stroke.is_empty() else null


## Painting an overlay layer only reaches faces of the overlay set being edited
## (LevelData.edit_set): slot i means another texture on faces of another set.
var layer_set := 0


func in_mask(brush: LevelBrush, face: int) -> bool:
	if layer > 0 and brush.get_face_layer_set(face) != layer_set:
		return false
	return face_mask.is_empty() or face_mask.has([brush, face])


## Corner indices of `brush` inside the face mask (null: no mask, every corner).
func _mask_corners(brush: LevelBrush) -> Variant:
	if face_mask.is_empty():
		return null
	var ids := {}
	for key in face_mask:
		if key[0] == brush and key[1] < brush.get_face_count():
			var start := brush.get_face_start(key[1])
			for k in brush.get_face_vertex_ids(key[1]).size():
				ids[start + k] = true
	return ids


## Vertex colour stroke state for a brush (made on first touch): colours before, the
## corner colours the stroke started from and how strongly each corner is covered so far.
func _vertex_entry(brush: LevelBrush) -> Dictionary:
	if not _stroke.vcolors.has(brush):
		var start := brush.full_corner_colors()
		var cover := PackedFloat32Array()
		cover.resize(start.size())
		_stroke.vcolors[brush] = {before = brush.vertex_colors, before_corners = brush.corner_colors, start = start,
			cover = cover, vcorners = brush.get_vertex_corners(), allowed = _mask_corners(brush)}
	return _stroke.vcolors[brush]
var _stroke := {}
var _stamp_angle := 0.0


func is_stroking() -> bool:
	return not _stroke.is_empty()


# --- Strokes --------------------------------------------------------------------------

## `stamp_first` false: a line carrying on from the last stroke (its start is painted).
func begin_stroke(root: LevelRoot, point: Vector3, brush: LevelBrush = null, stamp_first := true) -> void:
	_only = brush if stay_on_brush else null
	_stroke = {root = root, erase = tool == Tool.ERASE, masks = {}, base_before = {}, last = point, rebuild = false,
		vcolors = {}, free = true, brush = brush}
	if stamp_first:
		_stamp(point)


## Stamps along the segment from the last stamp, spaced a quarter radius apart.
func stroke_to(point: Vector3) -> void:
	if _stroke.is_empty():
		return
	var last: Vector3 = _stroke.last
	var step := maxf(size * 0.25, 0.02)
	var dist := last.distance_to(point)
	if dist < step:
		return
	var n := int(dist / step)
	for i in range(1, n + 1):
		_stamp(last.lerp(point, float(i) / n))
	_stroke.last = point


## Stamps exactly at `point` if the stroke stopped short of it (stroke_to stamps whole
## steps only): a line's end.
func stamp_end(point: Vector3) -> void:
	if not _stroke.is_empty() and _stroke.last.distance_to(point) > 0.001:
		_stamp(point)
		_stroke.last = point


func end_stroke() -> void:
	if _stroke.is_empty():
		return
	var root: LevelRoot = _stroke.root
	undo.create_action("Paint Vertex Colours" if layer == VERTEX_LAYER else "Paint Surface" if layer == SURFACE_LAYER
		else ("Paint" if layer > 0 else "Paint Base Texture"), UndoRedo.MERGE_DISABLE, root)
	for brush in _stroke.get("surf_before", {}):
		undo.add_do_property(brush, &"face_surfaces", brush.face_surfaces)
		undo.add_undo_property(brush, &"face_surfaces", _stroke.surf_before[brush])
	for brush in _stroke.get("vcolors", {}):
		var entry: Dictionary = _stroke.vcolors[brush]
		undo.add_do_property(brush, &"vertex_colors", brush.vertex_colors)
		undo.add_do_property(brush, &"corner_colors", brush.corner_colors)
		undo.add_undo_property(brush, &"vertex_colors", entry.before)
		undo.add_undo_property(brush, &"corner_colors", entry.before_corners)
	for key in _stroke.masks:
		var entry: Dictionary = _stroke.masks[key]
		undo.add_do_method(entry.brush, &"set_face_mask", entry.face, layer - 1, entry.image)
		undo.add_undo_method(entry.brush, &"set_face_mask", entry.face, layer - 1, entry.before)
	for brush in _stroke.base_before:
		undo.add_do_property(brush, &"face_textures", brush.face_textures)
		undo.add_undo_property(brush, &"face_textures", _stroke.base_before[brush])
	for brush in _stroke.get("uv_before", {}):
		undo.add_do_property(brush, &"face_uv", brush.face_uv)
		undo.add_undo_property(brush, &"face_uv", _stroke.uv_before[brush])
	# Only when the stroke added a texture: setting the palette rebuilds the whole level.
	if layer == 0 and _stroke.has("textures_before") and _stroke.textures_before != root.data.textures:
		undo.add_do_property(root.data, &"textures", root.data.textures)
		undo.add_undo_property(root.data, &"textures", _stroke.textures_before)
	undo.commit_action()
	if _stroke.get("free", false):
		line_from = _stroke.last
		line_root = root
		line_brush = _stroke.brush
	_stroke = {}
	_only = null


## Paint Face: a stroke that paints each face the cursor crosses, whole (overlay mask at
## `strength`, base texture, or its vertices' colour; `erase` removes). One undo step.
func begin_face_stroke(root: LevelRoot, erase: bool, brush: LevelBrush = null) -> void:
	_only = brush if stay_on_brush else null
	_stroke = {root = root, erase = erase, masks = {}, base_before = {}, last = Vector3.ZERO, rebuild = false,
		vcolors = {}, faces = {}}


func paint_face(root: LevelRoot, brush: LevelBrush, face: int) -> void:
	if _stroke.is_empty() or root != _stroke.root or _stroke.faces.has([brush, face]) or (_only and brush != _only) \
			or not in_mask(brush, face):
		return
	_stroke.faces[[brush, face]] = true
	var erase: bool = _stroke.erase
	if layer == VERTEX_LAYER:
		# This face's own corners only: neighbours sharing its vertices keep their colour.
		_vertex_entry(brush)
		var colors := brush.full_corner_colors()
		var start := brush.get_face_start(face)
		for k in brush.get_face_vertex_ids(face).size():
			colors[start + k] = colors[start + k].lerp(Color.WHITE if erase else vertex_color, strength)
		brush.set_corner_paint(colors)
	elif layer == SURFACE_LAYER:
		_assign_surface(brush, [face])
	elif layer == 0:
		_assign_base(root, brush, [face])
	else:
		var overlay := layer - 1
		var before := brush.get_face_mask(face, overlay)
		var sz := before.get_size() if before else brush.get_face_mask_size(face, root.data.mask_density)
		var img := Image.create(sz.x, sz.y, false, Image.FORMAT_L8)
		var v := 0.0 if erase else strength
		if before and not erase:
			# Raise towards the fill value, keeping anything already painted stronger.
			img = before.duplicate()
			for y in sz.y:
				for x in sz.x:
					var c := maxf(img.get_pixel(x, y).r, v)
					img.set_pixel(x, y, Color(c, c, c))
		else:
			img.fill(Color(v, v, v))
		_stroke.masks[[brush, face]] = {brush = brush, face = face, before = before, image = img}
		brush.set_face_mask(face, overlay, img)


func _stamp(point: Vector3) -> void:
	var root: LevelRoot = _stroke.root
	_stamp_angle = randf() * TAU if shape and scatter_rotation else 0.0
	if layer == VERTEX_LAYER:
		_paint_vertices(root, point)
		return
	for hit in faces_near(root, point, size):
		if layer == SURFACE_LAYER:
			_assign_surface(hit.brush, [hit.face])
		elif layer == 0:
			_assign_base(root, hit.brush, [hit.face])
		else:
			_paint_face(root, hit, point)


## Faces of `root` whose plane passes within `radius` of a world point and whose
## outline (grown by radius) contains it: [{brush, face, local_point, normal, plane_d}].
func faces_near(root: LevelRoot, point: Vector3, radius: float) -> Array:
	var out := []
	for brush in root.data.brushes:
		if brush == null or (_only and brush != _only) or root.is_brush_hidden(brush):
			continue
		var xf := root.brush_global_transform(brush)
		var lp := xf.affine_inverse() * point
		var r := radius / maxf(xf.basis.get_scale().x, 0.001)
		if not brush.local_aabb().grow(r).has_point(lp):
			continue
		for f in brush.get_face_count():
			var n := brush.get_face_normal(f)
			if n == Vector3.ZERO or not in_mask(brush, f):
				continue
			var d := n.dot(brush.vertices[brush.get_face_vertex_ids(f)[0]])
			if absf(n.dot(lp) - d) > r:
				continue
			if not brush.get_face_planar_rect(f).grow(r).has_point(PolyUtil.planar_uv(lp, n)):
				continue
			out.append({brush = brush, face = f, local_point = lp, normal = n, plane_d = d, radius = r})
	return out


func _paint_face(root: LevelRoot, hit: Dictionary, _point: Vector3) -> void:
	var brush: LevelBrush = hit.brush
	var face: int = hit.face
	var key := [brush, face]
	var overlay := layer - 1
	if not _stroke.masks.has(key):
		var before := brush.get_face_mask(face, overlay)
		var img: Image
		if before:
			img = before.duplicate()
		else:
			var sz := brush.get_face_mask_size(face, root.data.mask_density)
			img = Image.create(sz.x, sz.y, false, Image.FORMAT_L8)
		var cover := PackedFloat32Array()
		cover.resize(img.get_width() * img.get_height())
		_stroke.masks[key] = {brush = brush, face = face, before = before, start = img.duplicate(), image = img, cover = cover}
		brush.set_face_mask(face, overlay, img, false)
		if before == null:
			_stroke.rebuild = true
	var entry: Dictionary = _stroke.masks[key]
	var img: Image = entry.image
	var start: Image = entry.start
	var cover: PackedFloat32Array = entry.cover
	var rect := brush.get_face_planar_rect(face)
	var lp: Vector3 = hit.local_point
	var r: float = hit.radius
	var n: Vector3 = hit.normal
	var center := PolyUtil.planar_uv(lp, n)
	var w := img.get_width()
	var h := img.get_height()
	var px_lo := Vector2i(((center - Vector2(r, r) - rect.position) / rect.size * Vector2(w, h)).floor()).clamp(Vector2i.ZERO, Vector2i(w - 1, h - 1))
	var px_hi := Vector2i(((center + Vector2(r, r) - rect.position) / rect.size * Vector2(w, h)).ceil()).clamp(Vector2i.ZERO, Vector2i(w - 1, h - 1))
	var target := 0.0 if _stroke.erase else 1.0
	for y in range(px_lo.y, px_hi.y + 1):
		for x in range(px_lo.x, px_hi.x + 1):
			var uv := rect.position + (Vector2(x, y) + Vector2(0.5, 0.5)) / Vector2(w, h) * rect.size
			var q := PolyUtil.planar_unproject(uv, n, hit.plane_d)
			var weight := _brush_weight(q - lp, n, r)
			if weight <= 0.0:
				continue
			var i := y * w + x
			if weight <= cover[i]:
				continue
			cover[i] = weight
			var s := start.get_pixel(x, y).r
			var v := s + (target - s) * weight * strength
			img.set_pixel(x, y, Color(v, v, v))
	entry.cover = cover
	if _stroke.rebuild:
		root.request_rebuild()
		_stroke.rebuild = false
	else:
		root.update_mask_live(brush, face, overlay)


## Vertex colour stroke: vertices within the brush radius move towards the colour (or
## white when erasing), never past `strength` within one stroke. Paints each vertex's face
## corners (only those of masked faces while there's a face mask).
func _paint_vertices(root: LevelRoot, point: Vector3) -> void:
	var target := Color.WHITE if _stroke.erase else vertex_color
	for brush in root.data.brushes:
		if brush == null or (_only and brush != _only) or root.is_brush_hidden(brush):
			continue
		var xf := root.brush_global_transform(brush)
		var lp := xf.affine_inverse() * point
		var r := size / maxf(xf.basis.get_scale().x, 0.001)
		if not brush.local_aabb().grow(r).has_point(lp):
			continue
		var entry := _vertex_entry(brush)
		var start: PackedColorArray = entry.start
		var cover: PackedFloat32Array = entry.cover
		var vcorners: Array[PackedInt32Array] = entry.vcorners
		var allowed: Variant = entry.allowed
		var colors := brush.full_corner_colors()
		var changed := false
		for i in brush.vertices.size():
			var offset := brush.vertices[i] - lp
			if offset.length() >= r or i >= vcorners.size():
				continue
			var w := _brush_weight(offset, brush.get_vertex_normals()[i], r)
			for c in vcorners[i]:
				if c >= colors.size() or w <= cover[c] or (allowed != null and not allowed.has(c)):
					continue
				cover[c] = w
				colors[c] = start[c].lerp(target, w * strength)
				changed = true
		entry.cover = cover
		if changed:
			brush.set_corner_paint(colors)


## Vertex colours of whole faces set towards the colour (white when erasing): their own
## corners, so faces next to them keep their colour.
func fill_vertex_colors(root: LevelRoot, targets: Array, erase := false) -> void:
	var target := Color.WHITE if erase else vertex_color
	var by_brush := {}
	for t in targets:
		var start: int = t.brush.get_face_start(t.face)
		for k in t.brush.get_face_vertex_ids(t.face).size():
			by_brush.get_or_add(t.brush, {})[start + k] = true
	undo.create_action("Fill Vertex Colours", UndoRedo.MERGE_DISABLE, root)
	for brush: LevelBrush in by_brush:
		var colors := brush.full_corner_colors()
		for c in by_brush[brush]:
			colors[c] = colors[c].lerp(target, strength)
		_add_corner_paint(brush, colors)
	undo.commit_action()


## Soft fill by normal for vertex colours: each vertex weighted by its smoothed normal.
## Returns brush -> new corner colours.
func soft_fill_vertex_colors(root: LevelRoot, erase := false) -> Dictionary:
	var target := Color.WHITE if erase else vertex_color
	var out := {}
	for brush in root.data.brushes:
		if brush == null:
			continue
		var nb := root.brush_global_transform(brush).basis.inverse().transposed()
		var vn := brush.get_vertex_normals()
		var colors := brush.full_corner_colors()
		var vcorners := brush.get_vertex_corners()
		var allowed: Variant = _mask_corners(brush)
		var changed := false
		for i in mini(vn.size(), vcorners.size()):
			var w := normal_weight((nb * vn[i]).normalized()) * strength
			if w <= 0.0:
				continue
			for c in vcorners[i]:
				if allowed != null and not allowed.has(c):
					continue
				colors[c] = colors[c].lerp(target, w)
				changed = true
		if changed:
			out[brush] = colors
	return out


## Undo ops (in the open action) setting a brush's painted corner colours.
func _add_corner_paint(brush: LevelBrush, colors: PackedColorArray) -> void:
	var state := brush.corner_paint(colors)
	undo.add_do_property(brush, &"vertex_colors", state.vertex_colors)
	undo.add_do_property(brush, &"corner_colors", state.corner_colors)
	undo.add_undo_property(brush, &"vertex_colors", brush.vertex_colors)
	undo.add_undo_property(brush, &"corner_colors", brush.corner_colors)


## 0..1 brush influence for an offset from the brush centre (brush-local units).
func _brush_weight(offset: Vector3, n: Vector3, r: float) -> float:
	var d := offset.length() / r
	if d >= 1.0:
		return 0.0
	if shape == null:
		return 1.0 - smoothstep(clampf(hardness, 0.0, 0.99), 1.0, d)
	# Custom brush: sample the image in the face's planar frame.
	var uv := PolyUtil.planar_uv(offset, n).rotated(_stamp_angle) / (2.0 * r) + Vector2(0.5, 0.5)
	var px := Vector2i((uv * Vector2(shape.get_size())).floor()).clamp(Vector2i.ZERO, shape.get_size() - Vector2i.ONE)
	var c := shape.get_pixelv(px)
	return c.get_luminance() * c.a


func _assign_base(root: LevelRoot, brush: LevelBrush, faces: Array) -> void:
	var erase: bool = tool == Tool.ERASE or _stroke.get("erase", false)
	if base_texture == null and not erase:
		return
	if not _stroke.has("textures_before"):
		_stroke.textures_before = root.data.textures
	var paint_tex := base_texture if erase else look_texture(root.data)
	if paint_tex and not erase and root.data.texture_id(paint_tex) < 0:
		root.data.textures = root.data.with_texture(paint_tex)
	if not _stroke.base_before.has(brush):
		_stroke.base_before[brush] = brush.face_textures
	var id := -1 if erase else root.data.texture_id(paint_tex)
	var changed := false
	for f in faces:
		if brush.get_face_texture(f) != id:
			changed = true
	if changed:
		brush.face_textures = brush.with_face_textures(faces, id)
	if erase:
		return
	if color_mode != ColorMode.TEXTURE and (look.has("color") or color_mode == ColorMode.RECOLOUR):
		_tint_faces(brush, faces, look.get("color", Color.WHITE))
	var uv := brush.face_uv.duplicate()
	var rotated := false
	var pick: Variant = picked_uv if picked_uv != null and base_texture == _picked_texture else null
	for f in faces:
		while uv.size() <= f:
			uv.append(LevelBrush.DEFAULT_UV)
		# Keep the face's overlay turns (whole extra turns of the stored rotation).
		var w := rotation + 360.0 * LevelBrush.uv_overlay_code(uv[f])
		var z: float = absf(pick.z if pick != null else uv[f].z) * (-1.0 if follow_slope else 1.0)
		var want: Vector4 = Vector4(pick.x, pick.y, z, w) if pick != null else Vector4(uv[f].x, uv[f].y, z, w)
		if uv[f] != want:
			uv[f] = want
			rotated = true
	if rotated:
		if not _stroke.has("uv_before"):
			_stroke.uv_before = {}
		if not _stroke.uv_before.has(brush):
			_stroke.uv_before[brush] = brush.face_uv
		brush.face_uv = uv


## Sets the Surface override of `faces` (erase: clears it), recording the stroke's undo.
func _assign_surface(brush: LevelBrush, faces: Array) -> void:
	var value := 0 if tool == Tool.ERASE or _stroke.get("erase", false) else surface_value
	var changed := false
	for f in faces:
		if brush.get_face_surface(f) != value:
			changed = true
	if not changed:
		return
	if not _stroke.has("surf_before"):
		_stroke.surf_before = {}
	if not _stroke.surf_before.has(brush):
		_stroke.surf_before[brush] = brush.face_surfaces
	brush.face_surfaces = brush.with_face_surfaces(faces, value)


## Eyedropper: takes `face`'s base texture (its level tile / palette / variation settings
## come with it) and its offset, scale and rotation for painting. False if the face has
## no texture.
func pick_face(root: LevelRoot, brush: LevelBrush, face: int) -> bool:
	var id := brush.get_face_texture(face)
	if id < 0 or id >= root.data.textures.size() or root.data.textures[id] == null:
		return false
	var picked: Texture2D = root.data.textures[id]
	base_texture = TextureLook.source_of(picked)
	look = look_of(picked)
	if picked is TextureLook and picked.recolour:
		color_mode = ColorMode.RECOLOUR
	elif color_mode == ColorMode.RECOLOUR:
		color_mode = ColorMode.VERTEX
	if color_mode != ColorMode.TEXTURE:
		# The colour comes back from the face's vertex colours (times any look colour).
		look.color = face_color(brush, face) * look.get("color", Color.WHITE)
	var uv := brush.get_face_uv(face)
	rotation = fposmod(uv.w, 360.0)
	follow_slope = LevelBrush.uv_follows_slope(uv)
	picked_uv = uv
	_picked_texture = base_texture
	return true


## The palette entry to paint: base_texture itself when `look` matches how the level
## already shows it, else the TextureLook with these settings (existing or new).
func look_texture(data: LevelData) -> Texture2D:
	var recolour := color_mode == ColorMode.RECOLOUR
	if base_texture == null or (look.is_empty() and not recolour) or base_texture is N64StairTexture:
		return base_texture
	var pal: PackedColorArray = look.get("palette", PackedColorArray())
	var col: Color = look.get("color", Color.WHITE) if color_mode == ColorMode.TEXTURE else Color.WHITE
	var v: Vector3 = look.get("variation", PaintAtlas.base_variation_for(base_texture, data))
	var t: float = look.get("tile", 0.0)
	var level_pal = data.base_tints.get(base_texture)
	var plain_pal: bool = pal.is_empty() or (level_pal is PackedColorArray and level_pal == pal)
	var plain_tile := t <= 0.0 or is_equal_approx(t, PaintAtlas.base_tile_for(base_texture, data))
	if plain_pal and col.is_equal_approx(Color.WHITE) and v.is_equal_approx(PaintAtlas.base_variation_for(base_texture, data)) \
			and plain_tile and not recolour:
		return base_texture
	for tex in data.textures:
		if tex is TextureLook and tex.same_as(base_texture, pal, col, v, t, recolour):
			return tex
	var made := TextureLook.new()
	made.recolour = recolour
	made.texture = base_texture
	made.palette = pal
	made.color = col
	made.variation = v
	made.tile = t
	return made


## Vertex-colour mode: `faces` get `col` on their own corners (neighbours keep theirs;
## baked AO in alpha stays). Undone with the stroke.
func _tint_faces(brush: LevelBrush, faces: Array, col: Color) -> void:
	if not _stroke.has("vcolors"):
		_stroke.vcolors = {}
	_vertex_entry(brush)
	var colors := brush.full_corner_colors()
	var changed := false
	for f in faces:
		var start := brush.get_face_start(f)
		for k in brush.get_face_vertex_ids(f).size():
			var c := Color(col.r, col.g, col.b, colors[start + k].a)
			if not colors[start + k].is_equal_approx(c):
				colors[start + k] = c
				changed = true
	if changed:
		brush.set_corner_paint(colors)


## Average vertex colour of a face's corners.
static func face_color(brush: LevelBrush, face: int) -> Color:
	var colors := brush.full_corner_colors()
	var start := brush.get_face_start(face)
	var n := brush.get_face_vertex_ids(face).size()
	var sum := Color(0, 0, 0, 0)
	for k in n:
		sum += colors[start + k]
	return Color(sum.r / n, sum.g / n, sum.b / n) if n > 0 else Color.WHITE


## The look settings a palette entry was painted with ({} for a plain texture).
static func look_of(t: Texture2D) -> Dictionary:
	if t is TextureLook:
		return {palette = t.palette, color = t.color, variation = t.variation, tile = t.tile}
	return {}


## Whether painting applies a picked offset / scale right now.
func has_picked_uv() -> bool:
	return picked_uv != null and base_texture == _picked_texture


# --- Fills ----------------------------------------------------------------------------

## Fills whole faces: overlay -> mask set to `strength` (0 with Erase); base -> texture.
## Paint-bucket region for Fill Face: `face` plus every face of `brush` connected to it
## by shared edges and lying in the same plane (a subdivided slab top, a wall split into
## 1 m cells). [{brush, face}].
static func coplanar_region(brush: LevelBrush, face: int) -> Array:
	var n := brush.get_face_normal(face)
	var d := n.dot(brush.vertices[brush.get_face_vertex_ids(face)[0]])
	var edge_faces := {}
	for f in brush.get_face_count():
		var ids := brush.get_face_vertex_ids(f)
		for k in ids.size():
			var e := Vector2i(mini(ids[k], ids[(k + 1) % ids.size()]), maxi(ids[k], ids[(k + 1) % ids.size()]))
			if not edge_faces.has(e):
				edge_faces[e] = []
			edge_faces[e].append(f)
	var seen := {face: true}
	var queue: Array[int] = [face]
	var out := []
	while not queue.is_empty():
		var f: int = queue.pop_back()
		out.append({brush = brush, face = f})
		var ids := brush.get_face_vertex_ids(f)
		for k in ids.size():
			var e := Vector2i(mini(ids[k], ids[(k + 1) % ids.size()]), maxi(ids[k], ids[(k + 1) % ids.size()]))
			for g: int in edge_faces[e]:
				if seen.has(g):
					continue
				var gn := brush.get_face_normal(g)
				if gn.dot(n) > 0.999 and absf(gn.dot(brush.vertices[brush.get_face_vertex_ids(g)[0]]) - d) < 0.002:
					seen[g] = true
					queue.append(g)
	return out


## Paint bucket for Fill Same Texture: `face` plus every face reached through shared edges
## that has the same base texture (palette entry; untextured faces match each other),
## crossing into touching brushes unless `one_brush`. [{brush, face}].
static func texture_region(root: LevelRoot, brush: LevelBrush, face: int, one_brush := false) -> Array:
	var target := brush.get_face_texture(face)
	var brushes: Array = [brush] if one_brush else root.data.brushes.filter(func(b): return b != null)
	# World-space edges (rounded to 1 mm) -> faces on them, so touching brushes connect.
	var edge_faces := {}
	var face_edges := {}  # [brush, face] -> its edge keys
	for b: LevelBrush in brushes:
		var xf := b.transform
		var world := PackedVector3Array()
		world.resize(b.vertices.size())
		for i in b.vertices.size():
			world[i] = xf * b.vertices[i]
		for f in b.get_face_count():
			if b.get_face_texture(f) != target:
				continue
			var ids := b.get_face_vertex_ids(f)
			var keys := []
			for k in ids.size():
				var p := Vector3i((world[ids[k]] * 1000.0).round())
				var q := Vector3i((world[ids[(k + 1) % ids.size()]] * 1000.0).round())
				var e := [p, q] if p < q else [q, p]
				keys.append(e)
				if not edge_faces.has(e):
					edge_faces[e] = []
				edge_faces[e].append([b, f])
			face_edges[[b, f]] = keys
	var start := [brush, face]
	var seen := {start: true}
	var queue := [start]
	var out := []
	while not queue.is_empty():
		var cur: Array = queue.pop_back()
		out.append({brush = cur[0], face = cur[1]})
		for e in face_edges.get(cur, []):
			for other in edge_faces[e]:
				if not seen.has(other):
					seen[other] = true
					queue.append(other)
	return out


func fill_faces(root: LevelRoot, targets: Array, erase := false) -> void:
	targets = targets.filter(func(t): return in_mask(t.brush, t.face))
	if targets.is_empty():
		return
	if layer == VERTEX_LAYER:
		fill_vertex_colors(root, targets, erase)
		return
	if layer == SURFACE_LAYER:
		_stroke = {root = root, erase = erase, masks = {}, base_before = {}, last = Vector3.ZERO, rebuild = false, vcolors = {}}
		var by_brush := {}
		for t in targets:
			if not by_brush.has(t.brush):
				by_brush[t.brush] = []
			by_brush[t.brush].append(t.face)
		for brush in by_brush:
			_assign_surface(brush, by_brush[brush])
		end_stroke()
		return
	if layer == 0:
		_stroke = {root = root, erase = erase, masks = {}, base_before = {}, last = Vector3.ZERO, rebuild = false, vcolors = {}}
		var saved_tool := tool
		if erase:
			tool = Tool.ERASE
		var by_brush := {}
		for t in targets:
			if not by_brush.has(t.brush):
				by_brush[t.brush] = []
			by_brush[t.brush].append(t.face)
		for brush in by_brush:
			_assign_base(root, brush, by_brush[brush])
		tool = saved_tool
		end_stroke()
		return
	var overlay := layer - 1
	undo.create_action("Fill Overlay", UndoRedo.MERGE_DISABLE, root)
	for t in targets:
		var brush: LevelBrush = t.brush
		var before := brush.get_face_mask(t.face, overlay)
		var sz := before.get_size() if before else brush.get_face_mask_size(t.face, root.data.mask_density)
		var img := Image.create(sz.x, sz.y, false, Image.FORMAT_L8)
		var v := 0.0 if erase else strength
		if before and not erase:
			# Raise towards the fill value, keeping anything already painted stronger.
			img = before.duplicate()
			for y in sz.y:
				for x in sz.x:
					var c := maxf(img.get_pixel(x, y).r, v)
					img.set_pixel(x, y, Color(c, c, c))
		else:
			img.fill(Color(v, v, v))
		undo.add_do_method(brush, &"set_face_mask", t.face, overlay, img)
		undo.add_undo_method(brush, &"set_face_mask", t.face, overlay, before)
	undo.commit_action()


## Border: paints the overlay layer in a hard-edged band `width` metres wide along the
## outer edge of `region` ([{brush, face}], any shape, across brushes): edges no other
## region face shares (by world position) are the border. Faces farther than `width` from
## it are left alone. Erase clears the band instead. One undo step; returns faces changed.
func border_fill(root: LevelRoot, region: Array, width: float, erase := false) -> int:
	var overlay := layer - 1
	# Mitred corners: cut the corner faces first (geometry; those brushes undo as a whole).
	var cut := {}  # brush -> snapshot before
	if border_follow and not erase:
		var before := {}
		for t in region:
			if not before.has(t.brush) and t.brush.blend_file == "":
				before[t.brush] = t.brush.snapshot()
		var m := corner_cut(root, region, width, border_corner)
		region = m.region
		for brush in m.maps:
			cut[brush] = before[brush]
			_remap_face_mask(brush, m.maps[brush])
	# The border painted here before (any width) is replaced / erased whole.
	var border_id := border_key(root, region, overlay)
	var widths: Dictionary = root.data.border_widths.duplicate()
	var reach: float = maxf(width, widths.get(border_id, 0.0))
	var masks := border_masks(root, region, width, overlay, erase, reach)
	if masks.is_empty() and cut.is_empty():
		return 0
	if erase:
		# Erasing: the brushes are recorded whole, so the corner cuts' pieces can merge back.
		for m: Dictionary in masks:
			if not cut.has(m.brush) and m.brush.blend_file == "":
				cut[m.brush] = m.brush.snapshot()
	undo.create_action("Paint Border", UndoRedo.MERGE_DISABLE, root)
	if erase:
		widths.erase(border_id)
	else:
		widths[border_id] = width
	if widths != root.data.border_widths:
		undo.add_do_property(root.data, &"border_widths", widths)
		undo.add_undo_property(root.data, &"border_widths", root.data.border_widths)
	# Overlay codes (turn + the level's offset entry lining the texture up with the edge).
	var follow := border_follow and not erase
	if follow:
		var offsets := root.data.overlay_offsets.duplicate()
		var angles := root.data.overlay_angles.duplicate()
		var bases := root.data.overlay_bases.duplicate()
		var stairs := root.data.overlay_stairs.duplicate()
		for m: Dictionary in masks:
			m.code = m.turns + 4 * LevelData.overlay_frame_index(offsets, angles, m.offset, m.angle, bases,
				m.get("basis", LevelData.IDENTITY_BASIS), stairs, m.get("stair"))
		if stairs != root.data.overlay_stairs:
			undo.add_do_property(root.data, &"overlay_stairs", stairs)
			undo.add_undo_property(root.data, &"overlay_stairs", root.data.overlay_stairs)
			root.data.overlay_stairs = stairs
		if bases != root.data.overlay_bases:
			undo.add_do_property(root.data, &"overlay_bases", bases)
			undo.add_undo_property(root.data, &"overlay_bases", root.data.overlay_bases)
			root.data.overlay_bases = bases
		if offsets != root.data.overlay_offsets or angles != root.data.overlay_angles:
			undo.add_do_property(root.data, &"overlay_angles", angles)
			undo.add_undo_property(root.data, &"overlay_angles", root.data.overlay_angles)
			undo.add_do_property(root.data, &"overlay_offsets", offsets)
			undo.add_undo_property(root.data, &"overlay_offsets", root.data.overlay_offsets)
			root.data.overlay_angles = angles
			root.data.overlay_offsets = offsets
	# Cut brushes: apply their masks / codes now and record whole before / after states.
	var cut_codes := {}
	for m: Dictionary in masks:
		if cut.has(m.brush):
			m.brush.set_face_mask(m.face, overlay, m.image, false)
			if not follow:
				continue
			if not cut_codes.has(m.brush):
				cut_codes[m.brush] = [[], []]
			cut_codes[m.brush][0].append(m.face)
			cut_codes[m.brush][1].append(m.code)
	for brush: LevelBrush in cut:
		if cut_codes.has(brush):
			brush.face_uv = brush.with_overlay_codes(cut_codes[brush][0], cut_codes[brush][1])
		brush.face_masks = brush.face_masks  # one change notification for the masks set above
		if erase:
			# Only the pieces of faces this border covered (other borders keep their cuts).
			var ids := {}
			for m: Dictionary in masks:
				if m.brush == brush and brush.get_face_piece(m.face) != 0:
					ids[brush.get_face_piece(m.face)] = true
			var parts := []
			for f in brush.get_face_count():
				if ids.has(brush.get_face_piece(f)):
					parts.append(f)
			var healed := brush.merge_faces(parts, root.data.mask_density, true)
			if not healed.is_empty():
				_remap_face_mask(brush, healed)
		var after := brush.snapshot()
		for key in after:
			undo.add_do_property(brush, key, after[key])
			undo.add_undo_property(brush, key, cut[brush][key])
	var turned := {}  # brush -> [faces, codes]
	for m: Dictionary in masks:
		if cut.has(m.brush):
			continue
		undo.add_do_method(m.brush, &"set_face_mask", m.face, overlay, m.image)
		undo.add_undo_method(m.brush, &"set_face_mask", m.face, overlay, m.before)
		if follow and m.code != m.brush.get_face_overlay_code(m.face):
			if not turned.has(m.brush):
				turned[m.brush] = [[], []]
			turned[m.brush][0].append(m.face)
			turned[m.brush][1].append(m.code)
	for brush: LevelBrush in turned:
		undo.add_do_property(brush, &"face_uv", brush.with_overlay_codes(turned[brush][0], turned[brush][1]))
		undo.add_undo_property(brush, &"face_uv", brush.face_uv)
	undo.commit_action()
	return masks.size()


## Face mask entries follow a face remap (map[new] = old).
func _remap_face_mask(brush: LevelBrush, map: PackedInt32Array) -> void:
	if face_mask.is_empty():
		return
	var out := {}
	for key in face_mask:
		if key[0] != brush:
			out[key] = true
	for f in map.size():
		if face_mask.has([brush, map[f]]):
			out[[brush, f]] = true
	face_mask = out


## Region border segments in world space: [[a, b, normal]] (edges no other region face
## shares, by snapped world position; normal of the face they bound).
static func border_segments(root: LevelRoot, region: Array) -> Array:
	var count := {}
	var ends := {}
	var xfs := {}
	for t in region:
		var brush: LevelBrush = t.brush
		if not xfs.has(brush):
			xfs[brush] = root.brush_global_transform(brush)
		var xf: Transform3D = xfs[brush]
		var n: Vector3 = (xf.basis.inverse().transposed() * brush.get_face_normal(t.face)).normalized()
		var pts := brush.get_face_points(t.face)
		for k in pts.size():
			var a: Vector3 = xf * pts[k]
			var b: Vector3 = xf * pts[(k + 1) % pts.size()]
			var ka := a.snappedf(0.001)
			var kb := b.snappedf(0.001)
			var key := [ka, kb] if [ka.x, ka.y, ka.z] < [kb.x, kb.y, kb.z] else [kb, ka]
			count[key] = count.get(key, 0) + 1
			ends[key] = [a, b, n]
	var out := []
	for key in count:
		if count[key] == 1:
			out.append(ends[key])
	return out


## The area's outline split into sides at its corners (where the edge turns more than
## SIDE_ANGLE): [{key, segs: indices into `segs`}]. Works for any shape (a triangle has 3
## sides, a ramp's side wall its slope, base and back). `key` (its snapped end points) stays
## the same while the outline does, so border_off can name it.
const SIDE_ANGLE := 20.0


static func border_sides(segs: Array) -> Array:
	var starts := {}  # snapped start point -> segment (region on the left: outlines chain a -> b)
	for i in segs.size():
		starts[segs[i][0].snappedf(0.001)] = i
	var used := {}
	var out := []
	for first in segs.size():
		if used.has(first):
			continue
		# Walk one outline loop (or open chain).
		var loop: Array[int] = []
		var i := first
		while i >= 0 and not used.has(i):
			used[i] = true
			loop.append(i)
			i = starts.get(segs[i][1].snappedf(0.001), -1)
		# Rotate the loop to start at a corner, then cut it at every corner.
		var cos_max := cos(deg_to_rad(SIDE_ANGLE))
		var turn_at := func(k: int) -> bool:
			var p: Array = segs[loop[(k - 1 + loop.size()) % loop.size()]]
			var q: Array = segs[loop[k]]
			return (p[1] - p[0]).normalized().dot((q[1] - q[0]).normalized()) < cos_max
		var start := 0
		for k in loop.size():
			if turn_at.call(k):
				start = k
				break
		var side: Array[int] = []
		for k in loop.size():
			var idx := (start + k) % loop.size()
			if k > 0 and turn_at.call(idx):
				out.append(_side(segs, side))
				side = []
			side.append(loop[idx])
		if not side.is_empty():
			out.append(_side(segs, side))
	return out


static func _side(segs: Array, ids: Array[int]) -> Dictionary:
	var a: Vector3 = segs[ids[0]][0].snappedf(0.001)
	var b: Vector3 = segs[ids[-1]][1].snappedf(0.001)
	return {key = "%s|%s" % [a, b], segs = ids}


## border_segments without the sides in border_off.
func active_border_segments(root: LevelRoot, region: Array) -> Array:
	var segs := border_segments(root, region)
	if border_off.is_empty():
		return segs
	var out := []
	for side in border_sides(segs):
		if not border_off.has(side.key):
			for i in side.segs:
				out.append(segs[i])
	return out


## Border corners: wherever two border edges meet and run different ways in the texture
## frame (one along u, one along v), the region faces at the corner are cut so each side
## can take its own overlay turn: along the bisector (MITRE), or along the inner edge of the
## band that runs along u, across the other band (BUTT; at an inside corner, along the u
## edge's extension). Brushes from Blender aren't cut. Returns {region (the faces after the
## cuts), maps: brush -> face map (new -> old) for brushes that changed}.
func corner_cut(root: LevelRoot, region: Array, width: float, corner := Corner.MITRE) -> Dictionary:
	var segs := active_border_segments(root, region)
	var at := {}  # snapped point -> [[seg, which end]]
	for i in segs.size():
		for e in 2:
			var key: Vector3 = segs[i][e].snappedf(0.001)
			if not at.has(key):
				at[key] = []
			at[key].append([i, e])
	var corners := []  # [plane normal (world), point on the plane, cut from, cut to]
	for key in at:
		if at[key].size() != 2:
			continue
		var s1: Array = segs[at[key][0][0]]
		var s2: Array = segs[at[key][1][0]]
		var c: Vector3 = s1[at[key][0][1]]
		var e1: Vector3 = (s1[1 - at[key][0][1]] - c).normalized()
		var e2: Vector3 = (s2[1 - at[key][1][1]] - c).normalized()
		var n: Vector3 = s1[2]
		var u1 := PolyUtil.planar_uv(e1, n)
		var u2 := PolyUtil.planar_uv(e2, n)
		var along1 := absf(u1.x) >= absf(u1.y)
		if along1 == (absf(u2.x) >= absf(u2.y)):
			continue
		if corner == Corner.MITRE:
			var bis := e1 + e2
			if bis.length_squared() < 1e-6:
				continue
			bis = bis.normalized()
			var reach := width / maxf(sin(e1.angle_to(e2) * 0.5), 0.25) + 0.01
			corners.append([bis.cross(n).normalized(), c, c - bis * reach, c + bis * reach])
			continue
		# Butt: t = the edge along u (runs through), o = the other.
		var t_seg: Array = s1 if along1 else s2
		var et := e1 if along1 else e2
		var eo := e2 if along1 else e1
		var inward: Vector3 = n.cross(t_seg[1] - t_seg[0]).normalized()  # region side (CCW faces)
		if eo.dot(inward) > 0.0:
			# Outside corner: across the other band at the through band's inner edge.
			var p0 := c + inward * width
			corners.append([inward, p0, p0 - et * 0.01, p0 + et * (width + 0.01)])
		else:
			# Inside corner: the through edge carries on past the corner by a band's width.
			corners.append([inward, c, c + et * 0.01, c - et * (width + 0.01)])
	var by_brush := {}
	for t in region:
		if not by_brush.has(t.brush):
			by_brush[t.brush] = {}
		by_brush[t.brush][t.face] = true
	var out_region := []
	var maps := {}
	for brush: LevelBrush in by_brush:
		var faces_in: Dictionary = by_brush[brush]
		if brush.blend_file != "" or corners.is_empty():
			for f in faces_in:
				out_region.append({brush = brush, face = f})
			continue
		var xf := root.brush_global_transform(brush)
		var inv := xf.affine_inverse()
		var verts := brush.vertices
		var faces := brush.get_faces()
		var map := PackedInt32Array()
		for f in faces.size():
			map.append(f)
		var sources: Array[PackedInt32Array] = []
		for i in verts.size():
			sources.append(PackedInt32Array([i]))
		var rects := {}
		for f in faces.size():
			rects[f] = brush.get_face_planar_rect(f)
		var changed := false
		for cut in corners:
			var nl: Vector3 = xf.basis.transposed() * cut[0]
			var dl: float = cut[0].dot(cut[1]) - cut[0].dot(xf.origin)
			var len := nl.length()
			nl /= len
			dl /= len
			var from_l: Vector3 = inv * cut[2]
			var to_l: Vector3 = inv * cut[3]
			# Region faces the cut line crosses within its span.
			var only := {}
			for f in faces.size():
				if not faces_in.has(map[f]):
					continue
				var poly := faces[f]
				var cross := PackedVector3Array()
				for k in poly.size():
					var p := verts[poly[k]]
					var q := verts[poly[(k + 1) % poly.size()]]
					var sp := nl.dot(p) - dl
					var sq := nl.dot(q) - dl
					if absf(sp) < 1e-5:
						cross.append(p)
					elif (sp > 0.0) != (sq > 0.0) and absf(sq) >= 1e-5:
						cross.append(p.lerp(q, sp / (sp - sq)))
				if cross.size() >= 2:
					var pair := Geometry3D.get_closest_points_between_segments(cross[0], cross[1], from_l, to_l)
					if pair[0].distance_to(pair[1]) <= 1e-4:
						only[f] = true
			if only.is_empty():
				continue
			var r := BrushOps.cut_plane(verts, faces, nl, dl, only)
			if r.split.is_empty():
				continue
			changed = true
			verts = r.verts
			faces = r.faces
			for pair in r.new_vertices:
				var src := PackedInt32Array(sources[pair.x])
				src.append_array(sources[pair.y])
				sources.append(src)
			var nm := PackedInt32Array()
			for f in r.map.size():
				nm.append(map[r.map[f]])
			map = nm
		if not changed:
			for f in faces_in:
				out_region.append({brush = brush, face = f})
			continue
		brush.hand_edited = true
		brush.vertices = verts
		brush.set_faces(faces)
		brush.remap_faces(map)
		brush.mark_pieces(map)
		brush.blend_vertex_colors(sources)
		var child_parents := {}
		for f in map.size():
			child_parents[f] = rects[map[f]]
		brush.crop_child_masks(child_parents)
		maps[brush] = map
		for f in map.size():
			if faces_in.has(map[f]):
				out_region.append({brush = brush, face = f})
	return {region = out_region, maps = maps}


## The new overlay masks border_fill() paints: [{brush, face, before, image, turns, offset}]:
## the overlay turn and shift (LevelBrush overlay code) that lay the texture's width along
## the edge the face's band follows (most of its texels), rows running inward from that
## edge, so every side's texture starts at its edge and corners meet.
## Identifies a border by its outline (bounds and length: the same after corner cuts split
## its edges), overlay slot and overlay set, for LevelData.border_widths.
func border_key(root: LevelRoot, region: Array, overlay: int) -> int:
	var segs := border_segments(root, region)
	if segs.is_empty():
		return 0
	var box := AABB(segs[0][0], Vector3.ZERO)
	var length := 0.0
	for seg: Array in segs:
		box = box.expand(seg[0]).expand(seg[1])
		length += seg[0].distance_to(seg[1])
	return hash([box.position.snappedf(0.01), box.size.snappedf(0.01), snappedf(length, 0.01), overlay, layer_set])


## `reach` (>= width): texels this far from the edge are rewritten: the band up to `width`,
## cleared beyond it (a narrower border replacing a wider one); erasing clears all of it.
func border_masks(root: LevelRoot, region: Array, width: float, overlay: int, erase := false, reach := 0.0) -> Array:
	reach = maxf(reach, width)
	var density: float = root.data.mask_density
	var region_set := {}
	for t in region:
		region_set[[t.brush, t.face]] = true
	var xfs := {}
	for t in region:
		if not xfs.has(t.brush):
			xfs[t.brush] = root.brush_global_transform(t.brush)
	# Border segments bucketed on a grid so each face only checks the ones near it.
	var cell := maxf(reach, 1.0)
	var grid := {}
	var segs := []
	for seg: Array in active_border_segments(root, region):
		var box := AABB(seg[0], Vector3.ZERO).expand(seg[1]).grow(reach)
		var lo := Vector3i((box.position / cell).floor())
		var hi := Vector3i((box.end / cell).floor())
		for x in range(lo.x, hi.x + 1):
			for y in range(lo.y, hi.y + 1):
				for z in range(lo.z, hi.z + 1):
					var c := Vector3i(x, y, z)
					if not grid.has(c):
						grid[c] = []
					grid[c].append(segs.size())
		segs.append(seg)
	var out := []
	if segs.is_empty():
		return out
	var px := 1.0 / density
	var butt := border_follow and border_corner == Corner.BUTT
	# The overlay texture's height in metres (one repeat across the band).
	var repeat := 1.0
	var repeat_u := 1.0  # and its width
	if overlay >= 0 and overlay < root.data.active_layers().size():
		var l: PaintLayer = root.data.active_layers()[overlay]
		repeat = PaintAtlas.layer_tile(l)
		repeat_u = repeat
		if l.texture:
			repeat *= float(l.texture.get_height()) / maxf(l.texture.get_width(), 1.0)
	for t in region:
		var brush: LevelBrush = t.brush
		var face: int = t.face
		var xf: Transform3D = xfs[brush]
		var box := AABB()
		var pts := brush.get_face_points(face)
		for k in pts.size():
			box = AABB(xf * pts[k], Vector3.ZERO) if k == 0 else box.expand(xf * pts[k])
		var near := {}
		var lo := Vector3i((box.position / cell).floor())
		var hi := Vector3i((box.end / cell).floor())
		for x in range(lo.x, hi.x + 1):
			for y in range(lo.y, hi.y + 1):
				for z in range(lo.z, hi.z + 1):
					for i in grid.get(Vector3i(x, y, z), []):
						near[i] = true
		if near.is_empty():
			continue
		var n := brush.get_face_normal(face)
		var d := n.dot(brush.vertices[brush.get_face_vertex_ids(face)[0]])
		var rect := brush.get_face_planar_rect(face)
		var before := brush.get_face_mask(face, overlay)
		var sz := before.get_size() if before else brush.get_face_mask_size(face, density)
		var img: Image = before.duplicate() if before else Image.create(sz.x, sz.y, false, Image.FORMAT_L8)
		var any := false
		# Each border segment's direction in this face's texture frame: |u| >= |v| = runs along u.
		var along_u := {}
		var inv := xf.basis.inverse()
		var face_tweak := brush.get_face_uv(face)
		var uv_origin := LevelBrush.tweaked_uv(Vector3.ZERO, n, face_tweak)
		for i in near:
			var seg: Array = segs[i]
			var dir := LevelBrush.tweaked_uv(inv * (seg[1] - seg[0]), n, face_tweak) - uv_origin
			along_u[i] = absf(dir.x) >= absf(dir.y)
		var votes := {}  # border segment -> texels of this face nearest it
		# Only texels inside the face vote (a mitre half's mask spans its whole bounding rect).
		var poly2 := PackedVector2Array()
		for p in brush.get_face_points(face):
			poly2.append(PolyUtil.planar_uv(p, n))
		for y in sz.y:
			for x in sz.x:
				var uv := rect.position + (Vector2(x, y) + Vector2(0.5, 0.5)) / Vector2(sz) * rect.size
				var q: Vector3 = xf * PolyUtil.planar_unproject(uv, n, d)
				var dist := INF
				var nearest := -1
				var tie := -INF
				for i in near:
					var seg: Array = segs[i]
					var cp := Geometry3D.get_closest_point_to_segment(q, seg[0], seg[1])
					var di := q.distance_to(cp)
					if di > dist + 1e-4:
						continue
					# Equally near (around an inside corner both edges are nearest at the shared
					# end): the edge running most toward the texel wins, which splits on the mitre.
					var other: Vector3 = seg[1] if cp.distance_squared_to(seg[0]) < cp.distance_squared_to(seg[1]) else seg[0]
					var lean := (q - cp).dot((other - cp).normalized())
					if di < dist - 1e-4 or lean > tie:
						dist = minf(di, dist)
						nearest = i
						tie = lean
				# Hard edge, antialiased over one mask pixel. Erasing clears that rim pixel too
				# (scaling a half-covered rim down would leave a faint outline).
				if dist > reach + px:
					continue
				var w := 1.0 if erase \
					else clampf((width - dist) / maxf(border_soft, px) + (0.0 if border_soft > px else 0.5), 0.0, 1.0)
				w *= strength
				if w <= 0.0:
					# Between the new width and an older, wider border: cleared.
					if img.get_pixel(x, y).r > 0.0:
						img.set_pixel(x, y, Color.BLACK)
						any = true
					continue
				if Geometry2D.is_point_in_polygon(uv, poly2):
					if butt and not along_u[nearest]:
						# Butt corners: the band along u runs through (wins wherever it reaches).
						for i in near:
							if along_u[i] and q.distance_to(Geometry3D.get_closest_point_to_segment(q, segs[i][0], segs[i][1])) <= width:
								nearest = i
								break
					votes[nearest] = votes.get(nearest, 0) + 1
				var v := img.get_pixel(x, y).r
				v = v * (1.0 - w) if erase else (w if dist > width - px else maxf(v, w))
				img.set_pixel(x, y, Color(v, v, v))
				any = true
		if any:
			var best := -1
			for i in votes:
				if best < 0 or votes[i] > votes[best]:
					best = i
			var frame := {turns = 0, angle = 0.0, offset = Vector2.ZERO}
			if best >= 0 and border_direction == Lay.CONTINUE:
				var fold := _continue_frame(root, brush, face, xf, segs[best], region_set, overlay)
				if not fold.is_empty():
					frame = fold
			elif best >= 0:
				frame = _edge_frame(brush, face, xf, segs[best], repeat, repeat_u, LAY_TURNS[border_direction])
			out.append({brush = brush, face = face, before = before, image = img, turns = frame.turns, angle = frame.angle,
				offset = frame.offset, basis = frame.get("basis", LevelData.IDENTITY_BASIS), stair = frame.get("stair")})
	return out


## Lay.CONTINUE: the overlay frame (offset + linear basis, no turn) under which the band on
## `face` shows the overlay as the face across border `seg` would show it if folded over the
## edge: that face's own texture projection (scaled from its base tile to the layer's), or,
## for a stair face with a stair-texture layer, its step layout. {} = no face across.
func _continue_frame(root: LevelRoot, brush: LevelBrush, face: int, xf: Transform3D, seg: Array, region_set: Dictionary,
		overlay: int) -> Dictionary:
	var a: Vector3 = seg[0]
	var b: Vector3 = seg[1]
	var nb := _face_across(root, a, b, region_set)
	if nb.is_empty():
		return {}
	var nbrush: LevelBrush = nb.brush
	var nface: int = nb.face
	var e := (b - a).normalized()
	var into := func(c: Vector3) -> Vector3:
		var foot := a + e * (c - a).dot(e)
		return (c - foot).normalized()
	var c_s := Vector3.ZERO
	for p in brush.get_face_points(face):
		c_s += xf * p
	c_s /= brush.get_face_points(face).size()
	var nxf := root.brush_global_transform(nbrush)
	var c_n := Vector3.ZERO
	for p in nbrush.get_face_points(nface):
		c_n += nxf * p
	c_n /= nbrush.get_face_points(nface).size()
	var w_s: Vector3 = into.call(c_s)
	var w_n: Vector3 = into.call(c_n)
	var data := root.data
	var layers := data.active_layers()
	var layer: PaintLayer = layers[overlay] if overlay >= 0 and overlay < layers.size() else null
	var l_tile := PaintAtlas.layer_tile(layer) if layer else 1.0
	# A stair-texture layer continuing a stair draws the stair's base at its base tile
	# (PaintAtlas._apply_overlay_stair), with the steps shaded on top in their own fold.
	var stair_layer: bool = layer != null and layer.texture is N64StairTexture
	if stair_layer:
		l_tile = PaintAtlas.base_tile_for(layer.texture, root.data)
	var ntex := nbrush.get_face_texture(nface)
	var tex: Texture2D = data.textures[ntex] if ntex >= 0 and ntex < data.textures.size() else null
	var stair_frame = null
	if layer and layer.texture is N64StairTexture and tex is N64StairTexture:
		var runs := nbrush.stair_runs(data.stair_textures())
		if runs.faces.has(nface):
			stair_frame = runs.runs[runs.faces[nface]].frame
	var base_tile := PaintAtlas.base_tile_for(tex.base if tex is N64StairTexture else tex, data) if tex else 1.0
	var ninv := nxf.affine_inverse()
	var nn := nbrush.get_face_normal(nface)
	var ntweak := nbrush.get_face_uv(nface)
	# Where a point of the band lands folded onto the neighbour, and what it shows there.
	var fold := func(p: Vector3) -> Vector3:
		var foot := a + e * (p - a).dot(e)
		return ninv * (foot - w_n * (p - foot).dot(w_s))
	var target := func(p: Vector3) -> Vector2:
		return LevelBrush.tweaked_uv(fold.call(p), nn, ntweak) * (l_tile / maxf(base_tile, 0.001))
	var stair_target := func(p: Vector3) -> Vector2:
		var q: Vector3 = fold.call(p)
		var q4 := Vector4(q.x, q.y, q.z, 1.0)
		return Vector2(q4.dot(stair_frame[0]), q4.dot(stair_frame[1]))
	var inv := xf.affine_inverse()
	var sn := brush.get_face_normal(face)
	var stweak := brush.get_face_uv(face)
	var uv_at := func(p: Vector3) -> Vector2:
		return LevelBrush.tweaked_uv(inv * p, sn, stweak)
	# The affine map from this face's UV to a target, through three points on the face.
	var u0: Vector2 = uv_at.call(c_s)
	var s1: Vector2 = uv_at.call(c_s + e) - u0
	var s2: Vector2 = uv_at.call(c_s + w_s) - u0
	var det := s1.x * s2.y - s2.x * s1.y
	if absf(det) < 1e-9:
		return {}
	var solve := func(to: Callable) -> Array:
		var t0: Vector2 = to.call(c_s)
		var t1: Vector2 = to.call(c_s + e) - t0
		var t2: Vector2 = to.call(c_s + w_s) - t0
		var col0 := (t1 * s2.y - t2 * s1.y) / det
		var col1 := (t2 * s1.x - t1 * s2.x) / det
		return [Vector4(col0.x, col0.y, col1.x, col1.y), t0 - (col0 * u0.x + col1 * u0.y)]
	var main: Array = solve.call(target)
	var out := {turns = 0, angle = 0.0, offset = main[1], basis = main[0]}
	if stair_layer and stair_frame != null:
		var st: Array = solve.call(stair_target)
		out.stair = {layer = overlay, texture = ntex, basis = st[0], offset = st[1]}
	return out


## The face outside the region with edge a→b (world) on its outline, any brush: textured
## faces first, then the most upward-facing (a ramp's top over its hidden bottom). {} = none.
func _face_across(root: LevelRoot, a: Vector3, b: Vector3, region_set: Dictionary) -> Dictionary:
	var mid := (a + b) * 0.5
	var dir := (b - a).normalized()
	var best := {}
	var best_score := -INF
	for nbrush: LevelBrush in root.data.brushes:
		if nbrush == null or root.is_brush_hidden(nbrush):
			continue
		var nxf := root.brush_global_transform(nbrush)
		if not (nxf * nbrush.local_aabb()).grow(0.01).has_point(mid):
			continue
		var inv := nxf.affine_inverse()
		var lm: Vector3 = inv * mid
		var ld: Vector3 = (inv.basis * dir).normalized()
		for f in nbrush.get_face_count():
			if region_set.has([nbrush, f]):
				continue
			var ids := nbrush.get_face_vertex_ids(f)
			var on_edge := false
			for k in ids.size():
				var p := nbrush.vertices[ids[k]]
				var q := nbrush.vertices[ids[(k + 1) % ids.size()]]
				if absf((q - p).normalized().dot(ld)) > 0.999 \
						and lm.distance_to(Geometry3D.get_closest_point_to_segment(lm, p, q)) < 0.002:
					on_edge = true
					break
			if not on_edge:
				continue
			var n := (nxf.basis.inverse().transposed() * nbrush.get_face_normal(f)).normalized()
			var score := (2.0 if nbrush.get_face_texture(f) >= 0 else 0.0) + n.y
			if score > best_score:
				best_score = score
				best = {brush = nbrush, face = f}
	return best


## Overlay quarter turns of the texture coordinates (as the paint shader turns them).
static func _turn(v: Vector2, turns: int) -> Vector2:
	match turns:
		1: return Vector2(-v.y, v.x)
		2: return -v
		3: return Vector2(v.y, -v.x)
	return v


## The overlay turn, angle and shift for a face whose band follows border `seg` ([a, b,
## normal], world, region on the left): texture width (u) along the edge (exactly, also on
## slopes), v growing inward, and v = 0 on the edge (mod `repeat`, the texture's height).
## `extra` quarter turns lay it another way (Lay): across the edge, u grows inward
## from u = 0 on the edge (mod `repeat_u`, the texture's width); flipped, the other way.
static func _edge_frame(brush: LevelBrush, face: int, xf: Transform3D, seg: Array, repeat: float, repeat_u := 1.0,
		extra := 0) -> Dictionary:
	var n := brush.get_face_normal(face)
	var tweak := brush.get_face_uv(face)
	var inv := xf.affine_inverse()
	var inward: Vector3 = seg[2].cross(seg[1] - seg[0]).normalized()
	var lin := func(dir: Vector3) -> Vector2:
		return LevelBrush.tweaked_uv(inv.basis * dir, n, tweak) - LevelBrush.tweaked_uv(Vector3.ZERO, n, tweak)
	var along: Vector2 = lin.call(seg[1] - seg[0])
	var into: Vector2 = lin.call(inward)
	var turns := 0
	var score := -INF
	for t in 4:
		var a := _turn(along, t)
		var s := _turn(into, t).y + (1.0 if absf(a.x) >= absf(a.y) else -2.0)
		if s > score:
			score = s
			turns = t
	# The rest of the way onto the edge (sloped / diagonal edges): a free rotation.
	# (Only the small turn onto the u axis it already lies along, either way: the quarter
	# turn chose the direction that makes v grow inward.)
	var angle := wrapf(-_turn(along, turns).angle(), -PI * 0.5, PI * 0.5)
	if absf(angle) < 0.002:
		angle = 0.0
	# Quarter turns commute with the free rotation: the extra turns keep the edge on an axis.
	turns = (turns + extra) % 4
	var p0 := _turn(LevelBrush.tweaked_uv(inv * seg[0], n, tweak), turns).rotated(angle)
	if extra % 2 == 1:
		return {turns = turns, angle = angle, offset = Vector2(fposmod(-p0.x, maxf(repeat_u, 0.001)), 0.0)}
	return {turns = turns, angle = angle, offset = Vector2(0.0, fposmod(-p0.y, maxf(repeat, 0.001)))}


## Every face of `root` matching the direction / angle settings, in world space.
## `extra` widens the angle (soft fills touch faces up to angle + soft_edge / 2).
func faces_by_normal(root: LevelRoot, extra := 0.0) -> Array:
	var out := []
	var a_limit := angle + extra
	var limit := cos(deg_to_rad(a_limit))
	for brush in root.data.brushes:
		if brush == null or root.is_brush_hidden(brush):
			continue
		var basis := root.brush_global_transform(brush).basis
		for f in brush.get_face_count():
			var n := brush.get_face_normal(f)
			if n == Vector3.ZERO or not in_mask(brush, f):
				continue
			var wn := (basis.inverse().transposed() * n).normalized()
			var ok := false
			match effective_direction():
				Direction.UP:
					ok = wn.dot(Vector3.UP) >= limit
				Direction.DOWN:
					ok = wn.dot(Vector3.DOWN) >= limit
				Direction.WALLS:
					ok = absf(wn.y) <= sin(deg_to_rad(a_limit))
				Direction.ALL:
					ok = true
			if ok:
				out.append({brush = brush, face = f})
	return out


# --- Soft fill by normal ----------------------------------------------------------------

## The direction actually used: AUTO resolves from the clicked face (within 45° of up /
## down counts as floor / ceiling, anything steeper as a wall).
func effective_direction() -> Direction:
	if direction != Direction.AUTO:
		return direction
	if clicked_normal.y >= 0.7071:
		return Direction.UP
	if clicked_normal.y <= -0.7071:
		return Direction.DOWN
	return Direction.WALLS


func uses_soft_fill() -> bool:
	return (layer > 0 or layer == VERTEX_LAYER) and soft_edge > 0.0


## 0..1 match of a world normal against the direction, softened over `soft_edge`.
func normal_weight(wn: Vector3) -> float:
	var a := 0.0
	match effective_direction():
		Direction.UP:
			a = rad_to_deg(acos(clampf(wn.y, -1.0, 1.0)))
		Direction.DOWN:
			a = rad_to_deg(acos(clampf(-wn.y, -1.0, 1.0)))
		Direction.WALLS:
			a = rad_to_deg(absf(asin(clampf(wn.y, -1.0, 1.0))))
		Direction.ALL:
			return 1.0
	var half := soft_edge * 0.5
	return 1.0 - smoothstep(angle - half, angle + half, a)


## Fills the overlay by slope per mask texel: vertex normals are interpolated across each
## face, so the transition is smooth even where faces meet at hard angles.
func fill_normal_soft(root: LevelRoot, erase := false) -> void:
	if layer == VERTEX_LAYER:
		var colors := soft_fill_vertex_colors(root, erase)
		undo.create_action("Soft Fill Vertex Colours", UndoRedo.MERGE_DISABLE, root)
		for brush in colors:
			_add_corner_paint(brush, colors[brush])
		undo.commit_action()
		return
	var overlay := layer - 1
	undo.create_action("Soft Fill by Normal", UndoRedo.MERGE_DISABLE, root)
	for r in soft_fill_masks(root, erase):
		undo.add_do_method(r.brush, &"set_face_mask", r.face, overlay, r.image)
		undo.add_undo_method(r.brush, &"set_face_mask", r.face, overlay, r.brush.get_face_mask(r.face, overlay))
	undo.commit_action()


## Crease angle for soft fills: faces meeting at a sharper angle don't blend normals.
const SMOOTH_ANGLE := 50.0


## New overlay masks for a soft fill: [{brush, face, image}] for every face it reaches.
func soft_fill_masks(root: LevelRoot, erase := false) -> Array:
	var overlay := layer - 1
	var out := []
	for brush in root.data.brushes:
		if brush == null or root.is_brush_hidden(brush):
			continue
		var nb := root.brush_global_transform(brush).basis.inverse().transposed()
		for f in brush.get_face_count():
			var n := brush.get_face_normal(f)
			if n == Vector3.ZERO or not in_mask(brush, f):
				continue
			# Corner normals smoothed only across faces within SMOOTH_ANGLE: smoothing across
			# a floor/wall corner would tilt the floor's edge normals and paint the floor too.
			var corner := brush.get_corner_normals(f, SMOOTH_ANGLE)
			var world_cn := PackedVector3Array()
			var local_ids := PackedInt32Array()
			for k in corner.size():
				world_cn.append((nb * corner[k]).normalized())
				local_ids.append(k)
			var any := normal_weight((nb * n).normalized()) > 0.0
			for cn in world_cn:
				any = any or normal_weight(cn) > 0.0
			if any:
				out.append({brush = brush, face = f,
					image = _soft_mask(brush, f, local_ids, n, world_cn, root.data.mask_density, erase, overlay)})
	return out


func _soft_mask(brush: LevelBrush, face: int, ids: PackedInt32Array, n: Vector3, world_vn: PackedVector3Array,
		density: float, erase: bool, overlay: int) -> Image:
	var before := brush.get_face_mask(face, overlay)
	var sz := before.get_size() if before else brush.get_face_mask_size(face, density)
	var img: Image = before.duplicate() if before else Image.create(sz.x, sz.y, false, Image.FORMAT_L8)
	var pts := brush.get_face_points(face)
	var p2 := PackedVector2Array()
	for p in pts:
		p2.append(PolyUtil.planar_uv(p, n))
	var tris := PolyUtil.triangulate(pts, n)
	var rect := brush.get_face_planar_rect(face)
	for y in sz.y:
		for x in sz.x:
			var uv := rect.position + (Vector2(x, y) + Vector2(0.5, 0.5)) / Vector2(sz) * rect.size
			var wn := _interpolated_normal(uv, p2, tris, ids, world_vn)
			var w := normal_weight(wn) * strength
			var v := img.get_pixel(x, y).r
			v = v * (1.0 - w) if erase else maxf(v, w)
			img.set_pixel(x, y, Color(v, v, v))
	return img


## Normal at a planar point of a face: barycentric blend of its triangle's vertex normals
## (points outside the polygon use the closest triangle, clamped).
func _interpolated_normal(uv: Vector2, p2: PackedVector2Array, tris: PackedInt32Array, ids: PackedInt32Array,
		world_vn: PackedVector3Array) -> Vector3:
	var best := Vector3(1, 0, 0)
	var best_tri := 0
	var best_score := -INF
	for t in range(0, tris.size(), 3):
		var a := p2[tris[t]]
		var b := p2[tris[t + 1]]
		var c := p2[tris[t + 2]]
		var den := (b - a).cross(c - a)
		if absf(den) < 1e-10:
			continue
		var wb := (uv - a).cross(c - a) / den
		var wc := (b - a).cross(uv - a) / den
		var bary := Vector3(1.0 - wb - wc, wb, wc)
		var score := minf(bary.x, minf(bary.y, bary.z))
		if score > best_score:
			best_score = score
			best = bary
			best_tri = t
			if score >= 0.0:
				break
	best = best.max(Vector3.ZERO)
	best /= maxf(best.x + best.y + best.z, 1e-6)
	var nrm := world_vn[ids[tris[best_tri]]] * best.x + world_vn[ids[tris[best_tri + 1]]] * best.y \
		+ world_vn[ids[tris[best_tri + 2]]] * best.z
	return nrm.normalized()
