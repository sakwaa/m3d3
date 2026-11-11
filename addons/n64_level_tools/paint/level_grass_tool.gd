class_name LevelGrassTool
extends RefCounted
## Grass paint mode: paints the level's grass carpet (GrassSettings.paint_map) with a round
## brush: carpet of `height` where painted, on any ground; Shift erases carpet (also where
## it grows by itself on grass textures). The level gets its grass settings with the first
## stroke if it had none. One undo step per stroke; the carpet rebuilds when it ends.

## Carpet height painted (metres; Majora's Mask carpets are about a quarter to a third of the
## player's height).
var height := 0.45
var undo: EditorUndoRedoManager
var _stroke := {}


func is_stroking() -> bool:
	return not _stroke.is_empty()


func begin(root: LevelRoot, point: Vector3, radius: float, erase: bool) -> void:
	var data := root.data
	var made := false
	if data.grass == null:
		data.set_block_signals(true)
		data.grass = GrassSettings.new()
		data.set_block_signals(false)
		made = true
	var s := data.grass
	_stroke = {root = root, radius = radius, erase = erase, settings = s, made = made,
		before_map = s.paint_map, before_origin = s.paint_origin, last = point}
	if s.paint_map:
		s.set_block_signals(true)
		s.paint_map = s.paint_map.duplicate()  # painted from here on; the old one is the undo
	s.set_block_signals(true)  # (rebuilt once, when the stroke ends)
	_stamp(point)


func stroke_to(point: Vector3) -> void:
	if _stroke.is_empty():
		return
	var last: Vector3 = _stroke.last
	var step: float = maxf(_stroke.radius * 0.35, GrassSettings.PAINT_CELL)
	var d := last.distance_to(point)
	if d < step:
		return
	var n := int(d / step)
	for i in range(1, n + 1):
		_stamp(last.lerp(point, float(i) / n))
	_stroke.last = point


func end() -> void:
	if _stroke.is_empty():
		return
	var root: LevelRoot = _stroke.root
	var s: GrassSettings = _stroke.settings
	s.set_block_signals(false)
	var after_map: Image = s.paint_map
	var after_origin := s.paint_origin
	if undo == null:  # (scripts / tests: no undo)
		s.emit_changed()
		_stroke = {}
		return
	undo.create_action("Paint Grass" if not _stroke.erase else "Erase Grass", UndoRedo.MERGE_DISABLE, root)
	if _stroke.made:
		undo.add_do_property(root.data, &"grass", s)
		undo.add_undo_property(root.data, &"grass", null)
	undo.add_do_property(s, &"paint_origin", after_origin)
	undo.add_undo_property(s, &"paint_origin", _stroke.before_origin)
	undo.add_do_property(s, &"paint_map", after_map)
	undo.add_undo_property(s, &"paint_map", _stroke.before_map)
	undo.commit_action(false)  # (already painted)
	if _stroke.made:
		root.data.grass_changed.emit()
	s.emit_changed()  # the carpet rebuilds
	_stroke = {}


## Paints the brush circle at `point` (world) into the map, growing the map to cover it.
func _stamp(point: Vector3) -> void:
	var root: LevelRoot = _stroke.root
	var s: GrassSettings = _stroke.settings
	var r: float = _stroke.radius
	var c := root.to_local(point)
	var cell := GrassSettings.PAINT_CELL
	_cover(s, Rect2(c.x - r, c.z - r, r * 2.0, r * 2.0))
	var img := s.paint_map  # (the stroke's own: the one before it was copied for undo)
	var value := GrassSettings.ERASED if _stroke.erase else GrassSettings.value_of(height)
	var x0 := floori((c.x - r - s.paint_origin.x) / cell)
	var z0 := floori((c.z - r - s.paint_origin.y) / cell)
	var x1 := ceili((c.x + r - s.paint_origin.x) / cell)
	var z1 := ceili((c.z + r - s.paint_origin.y) / cell)
	for pz in range(maxi(z0, 0), mini(z1, img.get_height())):
		for px in range(maxi(x0, 0), mini(x1, img.get_width())):
			var wx := s.paint_origin.x + (px + 0.5) * cell
			var wz := s.paint_origin.y + (pz + 0.5) * cell
			if Vector2(wx - c.x, wz - c.z).length() <= r:
				img.set_pixel(px, pz, Color(value / 255.0, 0, 0))
	s.paint_map = img


## Grows the paint map (keeping what's painted) to cover `rect` (level x, z).
static func _cover(s: GrassSettings, rect: Rect2) -> void:
	var cell := GrassSettings.PAINT_CELL
	if s.paint_map != null:
		var have := Rect2(s.paint_origin, Vector2(s.paint_map.get_width(), s.paint_map.get_height()) * cell)
		if have.encloses(rect):
			return
		rect = rect.merge(have)
	var margin := 8.0
	var origin := ((rect.position - Vector2.ONE * margin) / cell).floor() * cell
	var size := Vector2i(((rect.end + Vector2.ONE * margin - origin) / cell).ceil())
	var img := Image.create(size.x, size.y, false, Image.FORMAT_L8)
	if s.paint_map != null:
		var off := Vector2i(((s.paint_origin - origin) / cell).round())
		img.blit_rect(s.paint_map, Rect2i(Vector2i.ZERO, s.paint_map.get_size()), off)
	s.paint_origin = origin
	s.paint_map = img
