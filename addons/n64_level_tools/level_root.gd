@tool
class_name LevelRoot
extends Node3D
## Single node that displays and bakes a LevelData resource. In the editor each brush
## is drawn by an internal (unsaved) MeshInstance3D; at runtime only the bake is used.

signal geometry_changed

const GROUP := &"level_root"
const FenceBuilder := preload("res://addons/n64_level_tools/fence_builder.gd")
const RopeBuilder := preload("res://addons/n64_level_tools/rope_builder.gd")
const RopeTexture := preload("res://addons/n64_level_tools/textures/rope_texture_generator.gd")
const PassageBuilder := preload("res://addons/n64_level_tools/passage_builder.gd")
const DEBUG_MATERIAL := preload("res://addons/n64_level_tools/materials/debug_grid.tres")

## Editor-wide toggle between the snap-grid checker and real materials.
static var debug_view := true

@export var data: LevelData:
	set(value):
		if data:
			data.brushes_changed.disconnect(_sync_brushes)
			data.bake_changed.disconnect(_queue_apply_bake)
			data.paint_changed.disconnect(_on_paint_changed)
			data.materials_changed.disconnect(_on_materials_changed)
			data.scatter_changed.disconnect(_queue_scatter)
			data.grass_changed.disconnect(_queue_grass)
		data = value
		if data:
			data.brushes_changed.connect(_sync_brushes)
			data.bake_changed.connect(_queue_apply_bake)
			data.paint_changed.connect(_on_paint_changed)
			data.materials_changed.connect(_on_materials_changed)
			data.scatter_changed.connect(_queue_scatter)
			data.grass_changed.connect(_queue_grass)
			_queue_scatter()
			_queue_grass()
		_sync_brushes()
		_queue_apply_bake()
## Bake option: merge adjacent coplanar faces within each brush.
@export var merge_coplanar := true

## Editor-only: show the baked result instead of the editable brushes.
var preview_baked := false:
	set(value):
		preview_baked = value
		_update_visibility()

var _instances := {}  # LevelBrush -> MeshInstance3D (its first chunk; more chunks are its children)
## Big brushes build in chunks of faces, so painting a few faces rebuilds only their chunk.
## LevelBrush -> {ranges: [Vector2i face from, to], base: hash, sigs: [hash per chunk]}
var _chunks := {}
## Brushes with more faces than this are split into chunks of CHUNK_FACES.
const CHUNK_FACES := 400
const CHUNK_ABOVE := 600
var _callbacks := {}  # LevelBrush -> Callable
var _dirty := {}
var _flush_queued := false
var _full_rebuild := false
## Paint state: mask atlas layout, one atlas image/texture per overlay layer, and one
## material per surface key (base texture id; -1 neutral).
var _atlas := {rects = {}, size = Vector2i(64, 64)}
var _atlas_hash := 0
var _mask_images: Array[Image] = []
var _mask_textures: Array[ImageTexture] = []
var _materials := {}
var _bake_queued := false
var _baked_meshes: Array[MeshInstance3D] = []
var _baked_bodies: Array[StaticBody3D] = []
var _baked_occluder: OccluderInstance3D
var _rain_cover: RainCover
var _backdrop: Array[Node3D] = []


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	# Internal children are never saved, but clear any stray copies (e.g. from duplication).
	for child in get_children(true):
		if not child in get_children() and not child in _instances.values() \
				and not child in _baked_meshes and not child in _baked_bodies and child != _baked_occluder and child != _rain_cover and not child in _backdrop and not _scatter_nodes.values().any(func(n): return child in n) and not child in _grass_nodes:
			child.queue_free()
	if data == null:
		data = LevelData.new()
	if not Engine.is_editor_hint() and not data.has_bake() and not data.brushes.is_empty():
		push_warning("LevelRoot '%s' has no bake; baking at runtime." % name)
		var result := LevelBaker.bake(data, merge_coplanar)
		data.baked_mesh = result.mesh
		data.baked_chunks = result.chunks
		data.set_baked_collision(result)
	_sync_brushes()
	_apply_bake()
	_rebuild_scatter()
	_queue_grass()
	_sync_passages()
	_sync_doors()
	_sync_windows()
	_sync_props()
	_sync_ropes()


static func set_debug_view(enabled: bool, tree: SceneTree) -> void:
	debug_view = enabled
	for root in tree.get_nodes_in_group(GROUP):
		(root as LevelRoot)._refresh_materials()


func brush_global_transform(brush: LevelBrush) -> Transform3D:
	return global_transform * brush.transform


func has_brush(brush: LevelBrush) -> bool:
	return data != null and brush in data.brushes


## Editor-only hidden brushes (H / Alt+H): not drawn, not picked, not painted; not saved,
## and the bake and the game ignore it.
var _hidden := {}


func set_brush_hidden(brush: LevelBrush, on: bool) -> void:
	if on:
		_hidden[brush] = true
	else:
		_hidden.erase(brush)
	_update_visibility()


func is_brush_hidden(brush: LevelBrush) -> bool:
	return _hidden.has(brush)


func hidden_count() -> int:
	return _hidden.size()


func show_all_brushes() -> void:
	_hidden.clear()
	_update_visibility()


## Nearest front-facing brush hit: {brush, face, position, normal, distance} (world) or {}.
## Hidden brushes are skipped, and fences and ropes with `skip_fences` (finding the ground
## under one, or a rope's anchor).
func raycast(from: Vector3, dir: Vector3, both_sides := false, skip_fences := false) -> Dictionary:
	var best := {}
	if data == null:
		return best
	for brush in data.brushes:
		if brush == null or _hidden.has(brush):
			continue
		if skip_fences and (brush.is_fence() or brush.is_rope() or String(brush.tag).begins_with("fence_")):
			continue
		var xf := brush_global_transform(brush)
		var inv := xf.affine_inverse()
		var hit: Dictionary = brush.raycast_local(inv * from, inv.basis * dir, both_sides)
		if hit and (best.is_empty() or hit.distance < best.distance):
			best = {
				brush = brush,
				face = hit.face,
				position = xf * hit.position,
				normal = (xf.basis.inverse().transposed() * hit.normal).normalized(),
				distance = hit.distance,
			}
	return best


func get_tagged_brush(tag: StringName) -> LevelBrush:
	if data == null or tag == &"":
		return null
	for brush in data.brushes:
		if brush and brush.tag == tag:
			return brush
	return null


func has_tagged_brush(tag: StringName) -> bool:
	return get_tagged_brush(tag) != null


## Grid segments for a passage floor of `size`: about one cell per metre along the longer side.
static func floor_segments(size: Vector3) -> int:
	return clampi(ceili(maxf(size.x, size.z)), 1, 64)


## Keeps a passage's floor brush at `global_xf` with `size` (resized only until hand-edited).
func sync_floor_brush(tag: StringName, global_xf: Transform3D, size: Vector3) -> void:
	var brush := get_tagged_brush(tag)
	if brush == null:
		return
	var xf := global_transform.affine_inverse() * global_xf
	if not brush.hand_edited and not brush.size.is_equal_approx(size):
		brush.size = size
		if brush.shape == BrushShapes.Shape.GRID:
			brush.segments = floor_segments(size)
	if not brush.transform.is_equal_approx(xf):
		brush.transform = xf


func compute_hash() -> int:
	var parts := [merge_coplanar, data.paint_hash()]
	for brush in data.brushes:
		if brush:
			parts.append(brush.bake_hash())
	return hash(parts)


func is_bake_stale() -> bool:
	return data != null and data.has_bake() and compute_hash() != data.bake_hash


func _sync_brushes() -> void:
	if not is_inside_tree() or not Engine.is_editor_hint():
		return
	var wanted := {}
	if data:
		for brush in data.brushes:
			if brush == null or wanted.has(brush):
				continue
			wanted[brush] = true
			if not _instances.has(brush):
				brush.ensure_geometry()
				var mi := MeshInstance3D.new()
				add_child(mi, false, INTERNAL_MODE_BACK)
				_instances[brush] = mi
				var cb := _mark_dirty.bind(brush)
				_callbacks[brush] = cb
				brush.changed.connect(cb)
				_mark_dirty(brush)
	var lost_house := false
	for brush in _instances.keys():
		if not wanted.has(brush):
			lost_house = lost_house or brush.is_house()
			brush.changed.disconnect(_callbacks[brush])
			_instances[brush].queue_free()
			_instances.erase(brush)
			_callbacks.erase(brush)
			_chunks.erase(brush)
	# A house gone: its terrace neighbours get their party walls back.
	if lost_house:
		for brush in _instances:
			if brush.is_house():
				_mark_dirty(brush)
	_sync_passages()
	_sync_doors()
	_sync_props()
	_sync_ropes()
	_update_visibility()
	geometry_changed.emit()


func _mark_dirty(brush: LevelBrush) -> void:
	_dirty[brush] = true
	if not _flush_queued:
		_flush_queued = true
		_flush.call_deferred()


var _mask_hashes := {}
## Scattered cut-outs: ScatterSet -> its MultiMeshInstance3Ds (editor and editor-run games;
## exports carry them as plain nodes).
var _scatter_nodes := {}
var _scatter_queued := false
## Stair-run material key -> its N64StairTexture (to refresh it in place).
var _stair_sources := {}


func _flush() -> void:
	var batch := _dirty
	_dirty = {}
	_flush_queued = false
	var atlas := PaintAtlas.layout(data.brushes)
	var atlas_hash := hash([atlas.rects, atlas.size])
	# Mask contents changed outside live painting (fills, undo / redo): refresh the layer
	# textures even when the layout is the same.
	var masks_changed := false
	for brush in batch:
		var mh := hash(brush.face_masks)
		if _mask_hashes.get(brush, 0) != mh:
			_mask_hashes[brush] = mh
			masks_changed = true
	if atlas_hash != _atlas_hash or _full_rebuild:
		_atlas = atlas
		_atlas_hash = atlas_hash
		_full_rebuild = false
		_rebuild_masks()
		batch = _instances
	elif masks_changed:
		_rebuild_masks()
	var full := batch == _instances
	# Houses before the openings in them (a rebuilt house gets its openings cut again). A
	# house changed or moved: every house checks its terrace joins (neighbours rebuild too).
	var houses_changed := false
	var houses := []
	for brush in batch:
		if brush.is_house():
			houses = data.brushes.filter(func(b): return b and b.is_house())
			break
	for brush in houses:
		if _instances.has(brush) and (brush.passage_dirty or not batch.has(brush)):
			if _generate_house(brush, houses):
				houses_changed = true
				if not batch.has(brush):  # (batch may be _instances itself: never overwrite)
					batch[brush] = true
	if houses_changed:
		_sync_windows()
	for brush in batch:
		if brush.is_fence() and brush.fence_dirty and _instances.has(brush):
			_generate_fence(brush)
		if brush.is_rope() and _instances.has(brush):
			if brush.rope_dirty or brush.get_meta(&"rope_build", 0) != RopeBuilder.BUILD:
				_generate_rope(brush)
			_sync_rope_node(brush)
		if brush.is_passage() and _instances.has(brush):
			if brush.passage_dirty:
				_generate_passage(brush)
			_sync_passage_node(brush)
			# The level tools keep the wall opening matching (size / place changes).
			if Engine.has_meta(&"n64_passage_changed"):
				(Engine.get_meta(&"n64_passage_changed") as Callable).call(self, brush)
		elif brush.is_door() and _instances.has(brush):
			if brush.passage_dirty:
				_generate_door(brush)
			_sync_door_node(brush)
			if Engine.has_meta(&"n64_passage_changed"):
				(Engine.get_meta(&"n64_passage_changed") as Callable).call(self, brush)
		elif brush.is_prop() and _instances.has(brush):
			_sync_prop_node(brush)
			if brush.passage_dirty or brush.fence_dirty:
				brush.fence_dirty = false
				_generate_prop(brush)
		elif brush.is_window() and _instances.has(brush):
			if brush.passage_dirty:
				_generate_window(brush)
			_sync_window_node(brush)
			if Engine.has_meta(&"n64_passage_changed"):
				(Engine.get_meta(&"n64_passage_changed") as Callable).call(self, brush)
	for brush in batch:
		if _instances.has(brush):
			_build_instance(brush, full)
	geometry_changed.emit()
	if data and data.grass:
		_queue_grass()


## A passage brush's corridor: a floor (~1 m cells, the floor it was placed on continued:
## texture + UV tweak) from the threshold out, and through a wall, side walls + ceiling.
func _generate_passage(brush: LevelBrush) -> void:
	brush.passage_dirty = false
	var p := brush.passage
	var key := passage_key(brush)
	if key == brush.passage_built and brush.get_face_count() > 0:
		return
	var floor := PassageBuilder.corridor_floor(p.width, p.depth, null, 0)
	var verts := PackedVector3Array()
	var faces: Array[PackedInt32Array] = []
	var textures := PackedInt32Array()
	var uvs := PackedVector4Array()
	var colors := []  # per face
	var exact := {}  # face -> its corners' UVs (the trim's), else projected
	var floor_uv := PassageBuilder.continued_uv(p.floor_uv, p.floor_source_xf, brush.transform)
	for v in floor.vertices:
		verts.append(v + Vector3(0, 0, -p.depth * 0.5))
	for f in floor.get_face_count():
		faces.append(floor.get_face_vertex_ids(f))
		textures.append(p.floor_texture)
		uvs.append(floor_uv)
		colors.append(p.floor_color)
	if p.shell:
		# Flush with the opening (the carving leaves no faces of its own around it).
		var shell := PassageBuilder.corridor_shell(self, global_transform, p.width, p.height, p.depth, null, -1, p.shape())
		var base := verts.size()
		verts.append_array(shell.vertices)
		for f in shell.get_face_count():
			var ids := shell.get_face_vertex_ids(f)
			var shifted := PackedInt32Array()
			for i in ids:
				shifted.append(i + base)
			faces.append(shifted)
			textures.append(p.wall_texture)
			uvs.append(p.wall_uv)
			colors.append(p.wall_color)
			var pts := []
			for i in shifted:
				pts.append(verts[i])
			var arch_uv := PassageBuilder.arch_lining_uvs(pts, p.width, p.height, p.shape(), p.wall_uv)
			if not arch_uv.is_empty():
				exact[faces.size() - 1] = arch_uv
	if p.dressing and p.dressing.texture:
		# Trim on the room side, built in so it's lit / baked like the walls around it.
		var tex := data.texture_id(p.dressing.texture)
		if tex < 0:
			data.textures = data.with_texture(p.dressing.texture)
			tex = data.textures.size() - 1
		# Brush faces wind like the corridor floor (whose normal is up).
		var f0: PackedInt32Array = faces[0]
		var ccw := _newell([verts[f0[0]], verts[f0[1]], verts[f0[2]]]).y > 0.0
		for poly in OpeningDressing.polygons(p.dressing, p.width, p.height, [[0.0, 1.0]], p.shape()):
			var pts: Array = poly.pts.duplicate()
			var puv: PackedVector2Array = poly.uvs.duplicate()
			if (_newell(pts).dot(poly.normal) > 0.0) != ccw:
				pts.reverse()
				puv.reverse()
			var ids := PackedInt32Array()
			for v in pts:
				ids.append(verts.size())
				verts.append(v)
			faces.append(ids)
			textures.append(tex)
			uvs.append(Vector4(0, 0, 1, 0))
			colors.append(p.dressing.tint)
			exact[faces.size() - 1] = puv
	# Collision: the floor, and inside a shell its walls and ceiling, one quad each (never
	# drawn); the drawn faces above only show.
	var drawn := faces.size()
	var first: PackedInt32Array = faces[0]
	var up_ccw := _newell([verts[first[0]], verts[first[1]], verts[first[2]]]).y > 0.0
	var hw := p.width * 0.5
	var z0 := 0.0
	var z1 := -p.depth
	var quads := [[[Vector3(-hw, 0, z0), Vector3(hw, 0, z0), Vector3(hw, 0, z1), Vector3(-hw, 0, z1)], Vector3.UP]]
	if p.shell:
		var h := p.height
		quads.append([[Vector3(-hw, 0, z0), Vector3(-hw, 0, z1), Vector3(-hw, h, z1), Vector3(-hw, h, z0)], Vector3.RIGHT])
		quads.append([[Vector3(hw, 0, z0), Vector3(hw, 0, z1), Vector3(hw, h, z1), Vector3(hw, h, z0)], Vector3.LEFT])
		quads.append([[Vector3(-hw, h, z0), Vector3(hw, h, z0), Vector3(hw, h, z1), Vector3(-hw, h, z1)], Vector3.DOWN])
	for q in quads:
		var pts: Array = q[0].duplicate()
		if (_newell(pts).dot(q[1]) > 0.0) != up_ccw:
			pts.reverse()
		var ids := PackedInt32Array()
		for v in pts:
			ids.append(verts.size())
			verts.append(v)
		faces.append(ids)
		textures.append(-1)
		uvs.append(Vector4(0, 0, 1, 0))
		colors.append(Color.WHITE)
	var bake := PackedByteArray()
	bake.resize(faces.size())
	bake.fill(1)
	for f in range(drawn, faces.size()):
		bake[f] = 2
	var w := BrushOps.weld_vertices(verts, faces)
	brush.set_block_signals(true)
	brush.vertices = w.verts
	brush.set_faces(w.faces)
	brush.face_textures = textures
	brush.face_uv = uvs
	brush.corner_uvs = _exact_corner_uvs(w, uvs, exact)
	brush.face_bake = bake
	brush.face_masks = {}
	brush.hand_edited = true
	# The painted colour (and AO) of the floor / wall it continues (recoloured textures need
	# it): floor corners take the floor face's own shade at their spot, so the threshold has
	# no seam; walls its average.
	var corner_colors := PackedColorArray()
	var ao := PackedFloat32Array()
	ao.resize(w.verts.size())
	ao.fill(1.0)
	var floor_faces := floor.get_face_count()
	for f in w.faces.size():
		for k in w.faces[f].size():
			var vi: int = w.faces[f][k]
			var c: Color = colors[f]
			if f < floor_faces and p.floor_source_points.size() >= 3:
				c = PassageBuilder.shade_at(p.floor_source_points, p.floor_source_shades, brush.transform * w.verts[vi])
				ao[vi] = c.a
			corner_colors.append(Color(c.r, c.g, c.b, 1.0))
	brush.corner_colors = corner_colors
	brush.vertex_ao = ao
	brush.corner_lighting = PackedColorArray()
	brush.corner_lighting_keys = [] as Array[PackedColorArray]
	brush.passage_built = key
	brush.set_block_signals(false)


## Part of passage_key(): bump it when the faces a passage builds change, so they rebuild.
const PASSAGE_VERSION := 2


## Fingerprint of everything a passage's / door's geometry is generated from: its settings
## and place.
static func passage_key(brush: LevelBrush) -> int:
	var parts := [brush.transform]
	if brush.passage:
		parts.append(PASSAGE_VERSION)
	var spec := brush.opening_spec()
	for prop in spec.get_property_list():
		var v = spec.get(prop.name)
		# Objects hash by instance (new every load): the dressing by its settings instead.
		if v is OpeningDressing:
			# Every setting of the trim (its texture by path).
			for dp in v.get_property_list():
				if dp.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
					var dv = v.get(dp.name)
					parts.append(dv.resource_path if dv is Resource else dv)
		elif prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and not v is Object:
			parts.append(v)
	return hash(parts)


static func _newell(pts: Array) -> Vector3:
	var n := Vector3.ZERO
	for i in pts.size():
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[(i + 1) % pts.size()]
		n += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
	return n


## A door brush's geometry: the lining through the wall (when it was cut through one: sides
## + top in the wall's texture, a floor carrying on the floor's), its trim, and invisible
## pick-only faces where the panel hangs (so it can be clicked; the panel is the node's).
func _generate_door(brush: LevelBrush) -> void:
	brush.passage_dirty = false
	var p := brush.door
	var key := passage_key(brush)
	if key == brush.passage_built and brush.get_face_count() > 0:
		return
	var verts := PackedVector3Array()
	var faces: Array[PackedInt32Array] = []
	var textures := PackedInt32Array()
	var uvs := PackedVector4Array()
	var colors := []
	var bake := PackedByteArray()
	var exact := {}  # face -> its corners' UVs (the trim's), else projected
	var add_face := func(pts: Array, tex: int, uv: Vector4, color: Color, flag: int) -> void:
		var ids := PackedInt32Array()
		for v in pts:
			ids.append(verts.size())
			verts.append(v)
		faces.append(ids)
		textures.append(tex)
		uvs.append(uv)
		colors.append(color)
		bake.append(flag)
	var front := p.front_z()
	var depth := p.wall_depth
	if p.lining and depth > 0.02:
		var floor := PassageBuilder.corridor_floor(p.width, depth, null, 0)
		var floor_uv := PassageBuilder.continued_uv(p.floor_uv, p.floor_source_xf, brush.transform)
		for f in floor.get_face_count():
			var pts := []
			for i in floor.get_face_vertex_ids(f):
				pts.append(floor.vertices[i] + Vector3(0, 0, front - depth * 0.5))
			add_face.call(pts, p.floor_texture, floor_uv, p.floor_color, 0)
		var shell := PassageBuilder.corridor_shell(self, global_transform, p.width, p.height, depth, null, -1, p.shape())
		for f in shell.get_face_count():
			var pts := []
			for i in shell.get_face_vertex_ids(f):
				pts.append(shell.vertices[i] + Vector3(0, 0, front))
			add_face.call(pts, p.wall_texture, p.wall_uv, p.wall_color, 0)
			var arch_uv := PassageBuilder.arch_lining_uvs(pts, p.width, p.height, p.shape(), p.wall_uv)
			if not arch_uv.is_empty():
				exact[faces.size() - 1] = arch_uv
	if p.dressing and p.dressing.texture:
		var tex := data.texture_id(p.dressing.texture)
		if tex < 0:
			data.textures = data.with_texture(p.dressing.texture)
			tex = data.textures.size() - 1
		for poly in OpeningDressing.polygons(p.dressing, p.width, p.height, p.dressing_faces(), p.shape()):
			var pts: Array = poly.pts
			var puv: PackedVector2Array = poly.uvs.duplicate()
			if _newell(pts).dot(poly.normal) < 0.0:
				pts = pts.duplicate()
				pts.reverse()
				puv.reverse()
			add_face.call(pts, tex, Vector4(0, 0, 1, 0), p.dressing.tint, 0)
			exact[faces.size() - 1] = puv
	# Pick box where the panel hangs (closed), never drawn / collided / baked.
	var h := Vector3(p.width * 0.5, p.height, maxf(p.thickness, 0.05) * 0.5)
	for q in [[Vector3(-h.x, 0, h.z), Vector3(h.x, 0, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3.BACK],
			[Vector3(h.x, 0, -h.z), Vector3(-h.x, 0, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3.FORWARD]]:
		add_face.call(_wound(q.slice(0, 4), q[4]), -1, Vector4(0, 0, 1, 0), Color.WHITE, 3)
	var w := BrushOps.weld_vertices(verts, faces)
	brush.set_block_signals(true)
	brush.vertices = w.verts
	brush.set_faces(w.faces)
	brush.face_textures = textures
	brush.face_uv = uvs
	brush.corner_uvs = _exact_corner_uvs(w, uvs, exact)
	brush.face_bake = bake
	brush.face_masks = {}
	brush.hand_edited = true
	var corner_colors := PackedColorArray()
	for f in w.faces.size():
		for k in w.faces[f].size():
			corner_colors.append(colors[f])
	brush.corner_colors = corner_colors
	var ao := PackedFloat32Array()
	ao.resize(w.verts.size())
	ao.fill(1.0)
	brush.vertex_ao = ao
	brush.corner_lighting = PackedColorArray()
	brush.corner_lighting_keys = [] as Array[PackedColorArray]
	brush.face_lod = PackedByteArray()
	var door_tex := _palette_index(p.panel_texture) if p.panel_texture else -1
	var door_trim := data.texture_id(p.dressing.texture) if p.dressing and p.dressing.texture else -1
	_opening_far(brush, OpeningShape.outline(p.width, p.height, p.top, p.arch_rise), front, p.trim(),
		p.dressing.tint if p.dressing else Color.WHITE, door_trim, Color(0.55, 0.45, 0.38), door_tex)
	brush.passage_built = key
	brush.set_block_signals(false)


## A window brush's geometry: the reveal through the wall (the wall's texture), the frame
## on both faces, a sill under it outside and a dark pane halfway through the wall.
func _generate_window(brush: LevelBrush) -> void:
	brush.passage_dirty = false
	var p := brush.window
	var key := passage_key(brush)
	if key == brush.passage_built and brush.get_face_count() > 0:
		return
	var verts := PackedVector3Array()
	var faces: Array[PackedInt32Array] = []
	var textures := PackedInt32Array()
	var uvs := PackedVector4Array()
	var colors := []
	var exact := {}
	var add_face := func(pts: Array, tex: int, uv: Vector4, color: Color) -> void:
		var ids := PackedInt32Array()
		for v in pts:
			ids.append(verts.size())
			verts.append(v)
		faces.append(ids)
		textures.append(tex)
		uvs.append(uv)
		colors.append(color)
	var front := p.front_z()
	var depth := p.wall_depth
	var hw := p.width * 0.5
	# Reveal: sides + top (flat or arched) from the corridor shell, and the bottom.
	var shell := PassageBuilder.corridor_shell(self, global_transform, p.width, p.height, depth, null, -1, p.shape())
	for f in shell.get_face_count():
		var pts := []
		for i in shell.get_face_vertex_ids(f):
			pts.append(shell.vertices[i] + Vector3(0, 0, front))
		add_face.call(pts, p.wall_texture, p.wall_uv, p.wall_color)
		var arch_uv := PassageBuilder.arch_lining_uvs(pts, p.width, p.height, p.shape(), p.wall_uv)
		if not arch_uv.is_empty():
			exact[faces.size() - 1] = arch_uv
	add_face.call(_wound([Vector3(-hw, 0, front), Vector3(hw, 0, front), Vector3(hw, 0, front - depth),
		Vector3(-hw, 0, front - depth)], Vector3.UP), p.wall_texture, p.wall_uv, p.wall_color)
	# Pane: the opening's outline halfway through, facing both ways.
	var outline := OpeningShape.outline(p.width, p.height, p.top, p.arch_rise)
	# (Two faces a little apart: on the same vertices they'd be welded away as a pair.) The
	# glass is stretched across the opening once, mirrored inside so it reads the same way.
	var glass := _palette_index(p.pane_texture) if p.pane_texture else -1
	var glass_size := _texture_world_size(p.pane_texture)
	for side in [1.0, -1.0]:
		var pane := []
		for q in outline:
			pane.append(Vector3(q.x, q.y, front - depth * 0.5 + side * 0.01))
		pane = _wound(pane, Vector3(0, 0, side))
		add_face.call(pane, glass, Vector4(0, 0, 1, 0), p.pane_color)
		if glass >= 0:
			var puv := PackedVector2Array()
			for v: Vector3 in pane:
				puv.append(Vector2(0.5 + side * v.x / p.width, 1.0 - v.y / p.height) * glass_size)
			exact[faces.size() - 1] = puv
	var trim_tex := -1
	if p.dressing and p.dressing.texture:
		trim_tex = data.texture_id(p.dressing.texture)
		if trim_tex < 0:
			data.textures = data.with_texture(p.dressing.texture)
			trim_tex = data.textures.size() - 1
		for poly in OpeningDressing.polygons(p.dressing, p.width, p.height, p.dressing_faces(), p.shape()):
			var pts: Array = poly.pts
			var puv: PackedVector2Array = poly.uvs.duplicate()
			if _newell(pts).dot(poly.normal) < 0.0:
				pts = pts.duplicate()
				pts.reverse()
				puv.reverse()
			add_face.call(pts, trim_tex, Vector4(0, 0, 1, 0), p.dressing.tint)
			exact[faces.size() - 1] = puv
	# Sill: a block under the opening, sticking out of the front face.
	if p.sill_depth > 0.0 and p.sill_height > 0.0:
		var sx := hw + p.sill_reach
		var lo := Vector3(-sx, -p.sill_height, front)
		var hi := Vector3(sx, 0.0, front + p.sill_depth)
		var tint := p.dressing.tint if p.dressing else Color.WHITE
		for q in [[Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3.UP],
				[Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z), Vector3.DOWN],
				[Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3.BACK],
				[Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, hi.y, lo.z), Vector3.LEFT],
				[Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z), Vector3.RIGHT]]:
			add_face.call(_wound(q.slice(0, 4), q[4]), trim_tex, Vector4(0, 0, 1, 0), tint)
	_store_generated(brush, verts, faces, textures, uvs, colors, exact, PackedByteArray())
	_opening_far(brush, outline, front, p.trim(), p.dressing.tint if p.dressing else Color.WHITE, trim_tex,
		p.pane_color, glass)
	brush.passage_built = key
	brush.set_block_signals(false)


## Metres one repeat of `tex` covers on a level (its world size, else its width at the
## project's texel density): exact UVs in metres stretch it by this much.
static func _texture_world_size(tex: Texture2D) -> Vector2:
	if tex == null:
		return Vector2.ONE
	var w: float = tex.get("world_size") if tex.get("world_size") else 0.0
	if w <= 0.0:
		w = tex.get_width() / N64Texture.texels_per_metre()
	return Vector2(w, w * tex.get_height() / maxf(tex.get_width(), 1.0))


## A house brush's geometry (HouseBuilder), its timber trim (the face-border overlay round
## each storey's wall panels) and the openings of the doors / windows standing in its walls,
## cut again. Kept as it is while its settings are unchanged (painting and lighting stay).
const HOUSE_SET := "Houses"


## Returns whether it was built again. `houses`: the level's house brushes (terrace joins;
## found when not given).
func _generate_house(brush: LevelBrush, houses := []) -> bool:
	brush.passage_dirty = false
	if houses.is_empty():
		houses = data.brushes.filter(func(b): return b and b.is_house())
	var spec := brush.house
	var joins := HouseTerrace.joins(brush, houses)
	var key := spec.key() if joins.is_empty() else hash([spec.key(), joins])
	if key == brush.passage_built and brush.get_face_count() > 0:
		return false
	var verts := PackedVector3Array()
	var faces: Array[PackedInt32Array] = []
	var textures := PackedInt32Array()
	var uvs := PackedVector4Array()
	var colors := []
	var bands := []
	var lods := PackedByteArray()
	var bake := PackedByteArray()
	var exact := {}  # face -> its corners' UVs (the shop's cloth), else projected
	for f in HouseBuilder.build(spec, joins):
		if f.has("uv"):
			exact[faces.size()] = f.uv
		var ids := PackedInt32Array()
		for v in f.pts:
			ids.append(verts.size())
			verts.append(v)
		faces.append(ids)
		textures.append(_palette_index(f.texture) if f.texture else -1)
		uvs.append(Vector4(0, 0, 1, 0))
		colors.append(f.color)
		bands.append(f.band)
		lods.append(f.lod)
		bake.append(f.get("bake", 0))
	_store_generated(brush, verts, faces, textures, uvs, colors, exact, bake)
	brush.face_lod = lods
	brush.passage_built = key
	_house_trim(brush, bands)
	# Doors / windows whose openings lie in these walls: cut them again.
	var bxf := brush_global_transform(brush)
	for other: LevelBrush in data.brushes:
		var o := other.opening_spec() if other else null
		if o == null or not o.carved:
			continue
		PassageBuilder.carve_brush(brush, bxf, global_transform * o.carved_xf, o.carved_width, o.carved_height,
			o.carve_depth(), o.carved_trim, o.carved_shape)
	brush.set_block_signals(false)
	return true


## The house's trim: a face border in its trim texture round each outside wall band. House
## faces use the overlay set "Houses" (made when needed), whose layers are the trims, so a
## level whose own overlay layers are all taken still gets them.
func _house_trim(brush: LevelBrush, bands: Array) -> void:
	var spec := brush.house
	if spec.trim_texture == null or spec.trim_width <= 0.0:
		return
	var set_index := -1
	for i in data.layer_sets.size():
		if data.layer_sets[i] and data.layer_sets[i].name == HOUSE_SET:
			set_index = i + 1
			break
	if set_index < 0:
		var made := PaintLayerSet.new()
		made.name = HOUSE_SET
		var sets := data.layer_sets.duplicate()
		sets.append(made)
		data.layer_sets = sets
		set_index = sets.size()
	var house_set: PaintLayerSet = data.layer_sets[set_index - 1]
	var slot := -1
	for i in house_set.layers.size():
		if house_set.layers[i] and house_set.layers[i].texture == spec.trim_texture:
			slot = i
			break
	if slot < 0:
		if house_set.layers.size() >= LevelData.MAX_LAYERS:
			push_warning("House: the \"%s\" overlay set has no room for another trim texture; the trim is left out." % HOUSE_SET)
			return
		var layer := PaintLayer.new()
		layer.name = "Trim (%s)" % spec.trim_texture.resource_path.get_file().get_basename()
		layer.texture = spec.trim_texture
		var layers := house_set.layers.duplicate()
		layers.append(layer)
		house_set.layers = layers
		slot = layers.size() - 1
	var sets := PackedInt32Array()
	sets.resize(brush.get_face_count())
	sets.fill(set_index)
	brush.face_layer_sets = sets
	var regions := {}
	for f in bands.size():
		if bands[f] != "":
			if not regions.has(bands[f]):
				regions[bands[f]] = []
			regions[bands[f]].append({brush = brush, face = f})
	var painter := LevelPaintTool.new()
	painter.layer = slot + 1
	painter.border_follow = false
	painter.border_soft = 0.0
	# The border's texture repeat comes from the edited set's layer: edit the house set meanwhile.
	var edit := data.edit_set
	data.edit_set = set_index
	var masks := brush.face_masks.duplicate()
	for band in regions:
		for m: Dictionary in painter.border_masks(self, regions[band], spec.trim_width, slot):
			masks[Vector2i(m.face, slot)] = m.image
	data.edit_set = edit
	brush.face_masks = masks


## Writes generated faces into `brush` (signals blocked; the caller unblocks): welded
## vertices, textures, UV tweaks, exact UVs, colours, bake flags, plain AO, no lighting.
func _store_generated(brush: LevelBrush, verts: PackedVector3Array, faces: Array[PackedInt32Array], textures: PackedInt32Array,
		uvs: PackedVector4Array, colors: Array, exact: Dictionary, bake: PackedByteArray) -> void:
	var w := BrushOps.weld_vertices(verts, faces)
	brush.set_block_signals(true)
	brush.vertices = w.verts
	brush.set_faces(w.faces)
	brush.face_textures = textures
	brush.face_uv = uvs
	brush.corner_uvs = _exact_corner_uvs(w, uvs, exact)
	brush.face_bake = bake
	brush.face_masks = {}
	brush.hand_edited = true
	var corner_colors := PackedColorArray()
	for f in w.faces.size():
		for k in w.faces[f].size():
			corner_colors.append(colors[f])
	brush.corner_colors = corner_colors
	var ao := PackedFloat32Array()
	ao.resize(w.verts.size())
	ao.fill(1.0)
	brush.vertex_ao = ao
	brush.corner_lighting = PackedColorArray()
	brush.corner_lighting_keys = [] as Array[PackedColorArray]
	brush.face_lod = PackedByteArray()


## A door / window in a house's wall: its own faces close up only, and from afar flat
## panels just outside the wall's far stand-in (the frame in `frame_color`, the opening in
## `fill`). `outline`: the opening (OpeningShape points), `front`: z of the wall's face.
func _opening_far(brush: LevelBrush, outline: PackedVector2Array, front: float, frame: Vector2, frame_color: Color,
		frame_tex: int, fill: Color, fill_tex: int) -> void:
	if _house_around(brush.transform.origin) == null:
		return
	var n := brush.get_face_count()
	var lods := PackedByteArray()
	lods.resize(n)
	lods.fill(LevelBrush.LOD_NEAR)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for q in outline:
		lo = lo.min(q)
		hi = hi.max(q)
	var faces := brush.get_faces()
	var verts := brush.vertices.duplicate()
	var textures := brush.face_textures
	textures.resize(n)
	var cc := brush.corner_colors.duplicate()
	var ao := brush.vertex_ao.duplicate()
	var add := func(a: Vector2, b: Vector2, z: float, tex: int, color: Color) -> void:
		var ids := PackedInt32Array()
		for p in [Vector3(a.x, a.y, z), Vector3(b.x, a.y, z), Vector3(b.x, b.y, z), Vector3(a.x, b.y, z)]:
			ids.append(verts.size())
			verts.append(p)
			ao.append(1.0)
			cc.append(color)
		faces.append(ids)
		textures.append(tex)
		lods.append(LevelBrush.LOD_FAR)
	if frame != Vector2.ZERO:
		add.call(Vector2(lo.x - frame.x, lo.y), Vector2(hi.x + frame.x, hi.y + frame.y), front + 0.015, frame_tex, frame_color)
	add.call(lo, hi, front + 0.025, fill_tex, fill)
	# Corner colours first: with the counts no longer matching the old faces, changing the
	# geometry doesn't hold the old corners to carry over.
	brush.corner_colors = cc
	brush.vertices = verts
	brush.set_faces(faces)
	brush.face_textures = textures
	brush.vertex_ao = ao
	brush.face_lod = lods
	brush.corner_uvs = PackedVector2Array()


## LevelBrush.corner_uvs for welded faces `w`: `exact` faces' own UVs (the trim's, unwrapped
## at true size), the rest projected with their tweak as usual. Empty when none are exact.
static func _exact_corner_uvs(w: Dictionary, tweaks: PackedVector4Array, exact: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	if exact.is_empty():
		return out
	for f in w.faces.size():
		var ids: PackedInt32Array = w.faces[f]
		if exact.has(f) and exact[f].size() == ids.size():
			out.append_array(exact[f])
			continue
		var pts := []
		for i in ids:
			pts.append(w.verts[i])
		var n := _newell(pts).normalized()
		for i in ids:
			out.append(LevelBrush.tweaked_uv(w.verts[i], n, tweaks[f]))
	return out


## `pts` (convex) wound so its face normal follows `normal` (brushes: counter-clockwise
## seen from the front, like the corridor floor's).
static func _wound(pts: Array, normal: Vector3) -> Array:
	var out := pts.duplicate()
	if _newell(out).dot(normal) < 0.0:
		out.reverse()
	return out


## Prop brush -> its node (PropSpec: sign, stall, rain drip, bird flock, NPC spot). Placed
## like a door's (under the scene's root, outside any Room), never saved with the scene and
## rebuilt from the brush in the editor and in game; on export it's written out for real.
var _prop_nodes := {}


func _sync_prop_node(brush: LevelBrush) -> void:
	var p := brush.prop
	var host := _door_host()
	var node: Node3D = _prop_nodes.get(brush)
	if node and is_instance_valid(node) and node.get_script() != load(PropSpec.SCRIPTS[p.kind]):
		node.queue_free()  # another kind now
		node = null
	var xf := _xf_to(host) * brush.transform if host != self else brush.transform
	var wanted_name := p.node_name if p.node_name != "" else "%s_%s" % [PropSpec.NAMES[p.kind], brush.tag]
	if node == null or not is_instance_valid(node):
		node = p.instantiate()
		node.name = wanted_name
		# Lets a node that changes itself in the editor (a sign writing its face) keep it.
		node.set_meta(&"prop_spec", p)
		node.transform = xf
		_sync_path_curve(brush, node)
		_prop_nodes[brush] = node
		if host == self:
			add_child(node, true)
		elif host.is_inside_tree() and not host.is_node_ready():
			_attach_door.call_deferred(node, host)
		else:
			host.add_child(node, true)
		return
	p.apply_to(node)
	_sync_path_curve(brush, node)
	if String(node.name) != wanted_name and node.is_inside_tree():
		node.name = wanted_name
	if node.transform != xf:
		node.transform = xf


## An NPC path's curve from its brush's points (a new route gets a short first leg).
func _sync_path_curve(brush: LevelBrush, node: Node) -> void:
	if not brush.is_npc_path():
		return
	if brush.fence_points.size() < 2:
		brush.set_block_signals(true)
		brush.fence_points = PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -3)])
		brush.set_block_signals(false)
	var c: Curve3D = node.curve if node.curve else Curve3D.new()
	var same := c.point_count == brush.fence_points.size()
	if same:
		for i in c.point_count:
			if not c.get_point_position(i).is_equal_approx(brush.fence_points[i]):
				same = false
				break
	if same and node.curve:
		return
	c = Curve3D.new()
	for p in brush.fence_points:
		c.add_point(p)
	node.curve = c


## Prop nodes for every prop brush, dropping those whose brush went away.
func _sync_props() -> void:
	var wanted := {}
	if data:
		for brush in data.brushes:
			if brush and brush.is_prop():
				wanted[brush] = true
				_sync_prop_node(brush)
	for brush in _prop_nodes.keys():
		if not wanted.has(brush):
			if is_instance_valid(_prop_nodes[brush]):
				_prop_nodes[brush].queue_free()
			_prop_nodes.erase(brush)


## A prop brush's geometry: only a pick box round its node (prop_bounds(), else its meshes'
## bounds, else a small cube; an NPC path, a block at each point), never drawn, collided or
## baked, so the prop is selected and moved like a brush.
func _generate_prop(brush: LevelBrush) -> void:
	brush.passage_dirty = false
	var node: Node = _prop_nodes.get(brush)
	var box := AABB(Vector3(-0.25, 0.0, -0.25), Vector3(0.5, 0.5, 0.5))
	var boxes: Array[AABB] = []
	if brush.is_npc_path():
		# A route: a small block at each point to pick it by (not one box over the area).
		for p in brush.fence_points:
			boxes.append(AABB(p + Vector3(-0.2, 0.0, -0.2), Vector3(0.4, 0.5, 0.4)))
	elif node and is_instance_valid(node):
		if node.has_method(&"prop_bounds"):
			box = node.prop_bounds()
		else:
			var built := _mesh_bounds(node, Transform3D.IDENTITY)
			if built.size != Vector3.ZERO:
				box = built
	if boxes.is_empty():
		boxes.append(box)
	var verts := PackedVector3Array()
	var faces: Array[PackedInt32Array] = []
	for bx in boxes:
		bx = bx.grow(0.02)
		var lo := bx.position
		var hi := bx.end
		for q in [[Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3.BACK],
				[Vector3(hi.x, lo.y, lo.z), Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3.FORWARD],
				[Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3.RIGHT],
				[Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, hi.y, lo.z), Vector3.LEFT],
				[Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3.UP],
				[Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z), Vector3.DOWN]]:
			var ids := PackedInt32Array()
			for v in _wound(q.slice(0, 4), q[4]):
				ids.append(verts.size())
				verts.append(v)
			faces.append(ids)
	var w := BrushOps.weld_vertices(verts, faces)
	brush.set_block_signals(true)
	brush.vertices = w.verts
	brush.set_faces(w.faces)
	var tex := PackedInt32Array()
	tex.resize(w.faces.size())
	tex.fill(-1)
	brush.face_textures = tex
	brush.face_uv = PackedVector4Array()
	brush.corner_uvs = PackedVector2Array()
	var bake := PackedByteArray()
	bake.resize(w.faces.size())
	bake.fill(3)
	brush.face_bake = bake
	brush.face_masks = {}
	brush.face_lod = PackedByteArray()
	brush.vertex_ao = PackedFloat32Array()
	brush.corner_lighting = PackedColorArray()
	brush.corner_lighting_keys = [] as Array[PackedColorArray]
	brush.hand_edited = true
	brush.set_block_signals(false)


## Bounds of every mesh under `node` (internal children too), in `node`'s space.
static func _mesh_bounds(node: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	for c in node.get_children(true):
		var cxf := xf * (c as Node3D).transform if c is Node3D else xf
		if c is MeshInstance3D and (c as MeshInstance3D).mesh and (c as MeshInstance3D).visibility_range_begin <= 0.0:
			var b := cxf * (c as MeshInstance3D).get_aabb()
			out = b if out.size == Vector3.ZERO else out.merge(b)
		var sub := _mesh_bounds(c, cxf)
		if sub.size != Vector3.ZERO:
			out = sub if out.size == Vector3.ZERO else out.merge(sub)
	return out


## Export: the prop nodes as saved nodes (owner = `scene`).
func make_prop_nodes_for_export(scene: Node) -> void:
	_sync_props()
	for brush in _prop_nodes:
		var node: Node = _prop_nodes[brush]
		if node.get_parent() == null:
			_door_host().add_child(node, true)
		node.owner = scene
		node.remove_meta(&"prop_spec")
		if node.has_method(&"bake_for_export"):
			node.bake_for_export(scene)


## Door brush -> its generated Door node. It lives under the scene's root outside any Room
## (a door must not unload with the room it's in), is never saved with the scene and is
## rebuilt from the brush in the editor and in game; on export it's written out for real.
var _door_nodes := {}


## Where door nodes go: the parent of the outermost Room above the level, else the level.
func _door_host() -> Node:
	var host: Node = self
	var n := get_parent()
	while n:
		if n is Room:
			host = n.get_parent()
		n = n.get_parent()
	return host if host else self


## This level's transform relative to `host` (works outside the tree, e.g. on export).
func _xf_to(host: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = self
	while n and n != host:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


func _sync_door_node(brush: LevelBrush) -> void:
	var p := brush.door
	var host := _door_host()
	var node: Door = _door_nodes.get(brush)
	if node == null or not is_instance_valid(node):
		node = Door.new()
		node.name = "Door_" + (String(p.door_id) if p.door_id != &"" else String(brush.tag))
		_door_nodes[brush] = node
		if host == self:
			add_child(node, true)
		elif host.is_inside_tree() and not host.is_node_ready():
			_attach_door.call_deferred(node, host)  # the host is still setting up its children
		else:
			host.add_child(node, true)
	for prop in DoorSpec.NODE_PROPERTIES:
		if node.get(prop) != p.get(prop):
			node.set(prop, p.get(prop))
	# Room paths are from the scene's root.
	var base: Node = owner if owner else host
	for pair in [[&"room_a", p.room_a], [&"room_b", p.room_b], [&"arrival_room", p.arrival_room]]:
		var room: Node = base.get_node_or_null(pair[1]) if not pair[1].is_empty() else null
		if node.get(pair[0]) != room:
			node.set(pair[0], room if room is Room else null)
	var xf := _xf_to(host) * brush.transform if host != self else brush.transform
	if node.transform != xf:
		node.transform = xf


func _attach_door(node: Door, host: Node) -> void:
	if is_instance_valid(node) and node.get_parent() == null and is_instance_valid(host):
		host.add_child(node, true)


## Door nodes for every door brush, dropping those whose brush went away.
func _sync_doors() -> void:
	var wanted := {}
	if data:
		for brush in data.brushes:
			if brush and brush.is_door():
				wanted[brush] = true
				_sync_door_node(brush)
	for brush in _door_nodes.keys():
		if not wanted.has(brush):
			if is_instance_valid(_door_nodes[brush]):
				_door_nodes[brush].queue_free()
			_door_nodes.erase(brush)


## Export: the door nodes (and window lights) as saved nodes (owner = `scene`).
func make_door_nodes_for_export(scene: Node) -> void:
	_sync_doors()
	for brush in _door_nodes:
		var node: Door = _door_nodes[brush]
		if node.get_parent() == null:
			_door_host().add_child(node, true)
		node.owner = scene
	_sync_windows()
	for brush in _window_nodes:
		_window_nodes[brush].owner = scene


## Window brush -> its WindowLight (a plain child; never saved, rebuilt from the brush, saved
## for real on export).
var _window_nodes := {}


func _sync_window_node(brush: LevelBrush) -> void:
	var p := brush.window
	var node: WindowLight = _window_nodes.get(brush)
	if not p.lights:
		if node and is_instance_valid(node):
			node.queue_free()
		_window_nodes.erase(brush)
		return
	if node == null or not is_instance_valid(node):
		node = WindowLight.new()
		node.name = "WindowLight_" + String(brush.tag)
		node.light_seed = hash(brush.tag)
		_window_nodes[brush] = node
		add_child(node, true)
	var house := _house_around(brush.transform.origin)
	var want := {width = p.width, height = p.height, top = p.top, arch_rise = p.arch_rise,
		gap = 0.04, far_offset = p.wall_depth * 0.5 + 0.035 if house else 0.0, home = house.house.someone_home if house else true,
		home_flag = house.house.home_flag if house else p.home_flag}
	for key in want:
		if node.get(key) != want[key]:
			node.set(key, want[key])
	# Over the pane, halfway through the wall (the glass faces sit 1 cm either side of it).
	var xf := brush.transform * Transform3D(Basis(), Vector3(0, 0, p.front_z() - p.wall_depth * 0.5))
	if node.transform != xf:
		node.transform = xf


func _sync_windows() -> void:
	var wanted := {}
	if data:
		for brush in data.brushes:
			if brush and brush.is_window():
				wanted[brush] = true
				_sync_window_node(brush)
	for brush in _window_nodes.keys():
		if not wanted.has(brush):
			if is_instance_valid(_window_nodes[brush]):
				_window_nodes[brush].queue_free()
			_window_nodes.erase(brush)


## The house brush whose walls stand around level point `p` (its footprint), or null.
func _house_around(p: Vector3) -> LevelBrush:
	for brush in data.brushes:
		if brush and brush.is_house():
			var q := brush.transform.affine_inverse() * p
			var h := brush.house
			if absf(q.x) <= h.width * 0.5 + 0.1 and absf(q.z) <= h.depth * 0.5 + 0.1 and q.y >= -0.1 and q.y <= h.wall_height() + 0.1:
				return brush
	return null


func _notification(what: int) -> void:
	# In the editor the door nodes (outside this level) go with it: removed / scene closed.
	if what == NOTIFICATION_EXIT_TREE and Engine.is_editor_hint():
		for nodes in [_door_nodes, _prop_nodes]:
			for brush in nodes:
				if is_instance_valid(nodes[brush]):
					nodes[brush].queue_free()
			nodes.clear()
	elif what == NOTIFICATION_ENTER_TREE and Engine.is_editor_hint() and is_node_ready():
		_sync_doors.call_deferred()
		_sync_props.call_deferred()


## Passage brush -> its generated Passage node (a plain child: zones find spawns among the
## level's children; never saved with the scene, rebuilt from the brush).
var _passage_nodes := {}


func _sync_passage_node(brush: LevelBrush) -> void:
	var node: Passage = _passage_nodes.get(brush)
	if node == null or not is_instance_valid(node):
		node = Passage.new()
		node.name = "Passage_" + (String(brush.passage.spawn_id) if brush.passage.spawn_id != &"" else "passage")
		_passage_nodes[brush] = node
		add_child(node, true)
	for prop in PassageSpec.NODE_PROPERTIES:
		if node.get(prop) != brush.passage.get(prop):
			node.set(prop, brush.passage.get(prop))
	if node.transform != brush.transform:
		node.transform = brush.transform


## Passage nodes for every passage brush, dropping those whose brush went away.
func _sync_passages() -> void:
	var wanted := {}
	if data:
		for brush in data.brushes:
			if brush and brush.is_passage():
				wanted[brush] = true
				_sync_passage_node(brush)
	for brush in _passage_nodes.keys():
		if not wanted.has(brush):
			if is_instance_valid(_passage_nodes[brush]):
				_passage_nodes[brush].queue_free()
			_passage_nodes.erase(brush)


## Export: the passage nodes as saved children (owner = `scene`), so the shipped level keeps
## them once the LevelRoot is swapped for its bake.
func make_passage_nodes_for_export(scene: Node) -> void:
	_sync_passages()
	for brush in _passage_nodes:
		var node: Passage = _passage_nodes[brush]
		node.owner = scene


## Rope brush -> the node holding the scenes hung along it (a plain child, like passage
## nodes: never saved with the scene, rebuilt from the brush; written out on export).
var _rope_nodes := {}


## The rope's hangs (RopeHang), its old single-scene settings read into the list once.
func _hang_list(brush: LevelBrush) -> Array[RopeHang]:
	if brush.rope_hang_scene and brush.rope_hangs.is_empty():
		var h := RopeHang.preset(RopeHang.Kind.SCENE)
		h.scene = brush.rope_hang_scene
		h.spacing = brush.rope_hang_spacing
		h.drop = brush.rope_hang_drop
		brush.set_block_signals(true)
		brush.rope_hangs = [h] as Array[RopeHang]
		brush.rope_hang_scene = null
		brush.set_block_signals(false)
	return brush.rope_hangs.filter(func(h): return h != null)


## Spots one hang uses on a rope brush (RopeBuilder.hang_points), brush-local.
func _hang_spots(brush: LevelBrush, h: RopeHang) -> Array:
	return RopeBuilder.hang_points(brush.rope_points, brush.rope_open, brush.rope_sag, brush.rope_style.segment_length,
		h.placement, h.spacing, h.offset, brush.rope_style.width * 0.5, brush.rope_style.max_bend)


func _sync_rope_node(brush: LevelBrush) -> void:
	var node: Node3D = _rope_nodes.get(brush)
	var scenes: Array = _hang_list(brush).filter(func(h: RopeHang): return h.kind == RopeHang.Kind.SCENE and h.scene) \
		if brush.is_rope() else []
	var lights: Array = _hang_list(brush).filter(func(h: RopeHang): return h.kind == RopeHang.Kind.LIGHTS) \
		if brush.is_rope() else []
	if scenes.is_empty() and lights.is_empty():
		if node and is_instance_valid(node):
			node.queue_free()
		_rope_nodes.erase(brush)
		return
	var placed := []  # [scene, transform]
	for h: RopeHang in scenes:
		for spot in _hang_spots(brush, h):
			var d: Vector3 = spot.direction
			placed.append([h.scene, Transform3D(Basis(d, Vector3.UP, d.cross(Vector3.UP)), spot.position + Vector3.DOWN * h.drop)])
	var strings := []  # [hang, bulb centres]
	for h: RopeHang in lights:
		var bulbs := PackedVector3Array()
		for spot in _hang_spots(brush, h):
			bulbs.append(spot.position + Vector3.DOWN * (h.drop + h.bulb_size * 0.5))
		strings.append([h, bulbs])
	var key := hash([placed.map(func(p): return [p[0].resource_path, p[0].get_instance_id(), p[1]]),
		strings.map(func(s): return [s[1], s[0].light_color, s[0].bulb_size, s[0].glow_size, s[0].flicker])])
	if node == null or not is_instance_valid(node):
		node = Node3D.new()
		node.name = "RopeHangs"
		_rope_nodes[brush] = node
		add_child(node, true)
	if node.transform != brush.transform:
		node.transform = brush.transform
	if node.get_meta(&"key", 0) == key:
		return
	node.set_meta(&"key", key)
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
	for p in placed:
		var inst := (p[0] as PackedScene).instantiate() as Node3D
		if inst == null:
			continue
		inst.transform = p[1]
		node.add_child(inst, true)
	for st in strings:
		var h: RopeHang = st[0]
		var sl: Node3D = STRING_LIGHTS.new()
		sl.name = "StringLights"
		sl.bulbs = st[1]
		sl.color = h.light_color
		sl.bulb_size = h.bulb_size
		sl.glow_size = h.glow_size
		sl.flicker = h.flicker
		node.add_child(sl, true)


const STRING_LIGHTS := preload("res://game/world/props/string_lights.gd")


## Hung-scene nodes for every rope brush, dropping those whose brush went away.
func _sync_ropes() -> void:
	var wanted := {}
	if data:
		for brush in data.brushes:
			if brush and brush.is_rope():
				wanted[brush] = true
				_sync_rope_node(brush)
	for brush in _rope_nodes.keys():
		if not wanted.has(brush):
			if is_instance_valid(_rope_nodes[brush]):
				_rope_nodes[brush].queue_free()
			_rope_nodes.erase(brush)


## Export: the hung scenes (each an instance of its scene) and string lights as saved
## children (owner = `scene`).
func make_rope_nodes_for_export(scene: Node) -> void:
	_sync_ropes()
	for brush in _rope_nodes:
		var node: Node3D = _rope_nodes[brush]
		node.owner = scene
		for child in node.get_children():
			child.owner = scene


## A fence brush's geometry from its fence data (FenceBuilder): faces, fitted UVs, per-face
## textures (added to the palette as needed) and collision-only wall faces.
func _generate_fence(brush: LevelBrush) -> void:
	brush.fence_dirty = false
	var style := brush.fence_style
	var idx := {}
	var tiles := {}
	var aspects := {}
	var textures := data.textures
	for key in ["panel", "post", "cap", "arch"]:
		var t: Texture2D = style.get(("end_cap" if key == "cap" else key) + "_texture")
		if t == null:
			continue
		if not t in textures:
			textures = textures.duplicate()
			textures.append(t)
		idx[key] = textures.find(t)
		tiles[key] = PaintAtlas.base_tile_for(t, data)
		aspects[key] = float(t.get_width()) / maxf(t.get_height(), 1.0)
	if textures != data.textures:
		data.textures = textures
	# Posts between the points stand on the ground under them (fences ignored).
	var xf := brush_global_transform(brush)
	var inv := xf.affine_inverse()
	# A few rays just around the post, highest hit: one ray right on a grid line can slip
	# between two faces and find something underneath.
	var ground := func(p: Vector3) -> Variant:
		var w := xf * p
		var best = null
		for o: Vector3 in [Vector3.ZERO, Vector3(0.02, 0, 0.013), Vector3(-0.017, 0, 0.02), Vector3(0.013, 0, -0.02), Vector3(-0.02, 0, -0.011)]:
			var hit := raycast(w + o + Vector3.UP * 2.0, Vector3.DOWN, false, true)
			if not hit.is_empty() and hit.distance <= 6.0 and (best == null or hit.position.y > best):
				best = hit.position.y
		if best == null:
			return null
		return (inv * Vector3(w.x, best, w.z)).y
	var built := FenceBuilder.build_data(brush.fence_points, brush.fence_closed, brush.fence_open, style, idx, tiles,
		aspects, brush.fence_spacing, ground if brush.fence_follow_ground else Callable(), brush.fence_sag)
	brush.set_block_signals(true)
	if built.is_empty():
		brush.vertices = PackedVector3Array()
		brush.set_faces([] as Array[PackedInt32Array])
		brush.corner_uvs = PackedVector2Array()
		brush.face_textures = PackedInt32Array()
		brush.face_bake = PackedByteArray()
	else:
		brush.vertices = built.vertices
		brush.set_faces(built.faces)
		brush.corner_uvs = built.corner_uvs
		brush.face_textures = built.textures
		brush.face_bake = built.bake
	brush.face_masks = {}
	brush.face_uv = PackedVector4Array()
	brush.cutout = true
	brush.hand_edited = true
	brush.set_block_signals(false)


## A rope brush's geometry from its rope data (RopeBuilder): ribbons with fitted UVs in the
## style's texture (added to the palette as needed), drawn but not collided.
func _generate_rope(brush: LevelBrush) -> void:
	brush.rope_dirty = false
	brush.set_meta(&"rope_build", RopeBuilder.BUILD)
	var style := brush.rope_style
	var idx := -1
	var tile := 1.0
	var aspect := 1.0
	var t := style.texture
	if t:
		idx = _palette_index(t)
		tile = PaintAtlas.base_tile_for(t, data)
		aspect = float(t.get_width()) / maxf(t.get_height(), 1.0)
	var hangs := []
	for h in _hang_list(brush):
		var card := {}
		if h.kind != RopeHang.Kind.SCENE and h.kind != RopeHang.Kind.LIGHTS:
			var ct := h.texture if h.texture else RopeTexture.default_for(h)
			if ct:
				var ci := _palette_index(ct)
				var size := h.size
				if h.kind == RopeHang.Kind.BANNER:
					# A banner with long text is a longer texture (64 x 256): longer cloth too.
					size.y *= maxf(1.0, float(ct.get_height()) / maxf(ct.get_width(), 1.0) / 2.0)
				card = {tex = ci, tile = PaintAtlas.base_tile_for(ct, data), size = size, crossed = h.crossed,
					aspect = float(ct.get_width()) / maxf(ct.get_height(), 1.0)}
		for spot in _hang_spots(brush, h):
			# A scene's / bulb's cord is drawn here too; the scene itself, or the lights, is a
			# node (_sync_rope_node).
			hangs.append({position = spot.position, direction = spot.direction, drop = h.drop, card = card})
	var built := RopeBuilder.build_data(brush.rope_points, brush.rope_open, style, idx, tile, aspect, brush.rope_sag,
		hangs)
	brush.set_block_signals(true)
	brush.vertices = built.get("vertices", PackedVector3Array())
	brush.set_faces(built.get("faces", [] as Array[PackedInt32Array]))
	brush.corner_uvs = built.get("corner_uvs", PackedVector2Array())
	brush.face_textures = built.get("textures", PackedInt32Array())
	brush.face_bake = built.get("bake", PackedByteArray())
	brush.face_masks = {}
	brush.face_uv = PackedVector4Array()
	brush.cutout = true
	brush.hand_edited = true
	brush.set_block_signals(false)


## `t`'s index in the level's texture list (added when it isn't there yet).
func _palette_index(t: Texture2D) -> int:
	if not t in data.textures:
		var textures := data.textures.duplicate()
		textures.append(t)
		data.textures = textures
	return data.textures.find(t)


## Rebuilds the brush's mesh, chunk by chunk: a chunk whose faces' paint didn't change
## keeps its mesh (unless `force`, or the brush's geometry / shared data changed).
func _build_instance(brush: LevelBrush, force := false) -> void:
	var main: MeshInstance3D = _instances[brush]
	var faces := brush.get_face_count()
	var ranges: Array[Vector2i] = []
	if faces > CHUNK_ABOVE:
		for a in range(0, faces, CHUNK_FACES):
			ranges.append(Vector2i(a, mini(a + CHUNK_FACES, faces)))
	else:
		ranges.append(Vector2i(0, faces))
	var bi := data.brushes.find(brush)
	var timed := LevelData.mode_is_timed(data.lighting_mode)
	var baked := data.lighting_mode == LevelData.LightingMode.BAKED_VERTEX
	var hybrid := data.lighting_mode == LevelData.LightingMode.BAKED_VERTEX_DYNAMIC
	var stairs := data.stair_textures()
	# Everything a chunk's mesh depends on beyond its own faces (their vertices' positions,
	# AO and colours are in each chunk's signature, so sculpting rebuilds only its chunks).
	var base := hash([brush.vertices.size(), brush.has_corner_colors(),
		brush.material, bi, _atlas_hash,
		data.lighting_mode, data.vertex_color_scale(), stairs.keys(), brush.corner_lighting_keys.size()])
	var prev: Dictionary = _chunks.get(brush, {})
	var all: bool = force or prev.get("base") != base or prev.get("ranges", []) != ranges
	var sigs := []
	var meshes := _chunk_meshes(main, ranges.size())
	for i in ranges.size():
		var sig := _chunk_sig(brush, ranges[i])
		sigs.append(sig)
		if not all and i < prev.sigs.size() and prev.sigs[i] == sig:
			continue
		var mi: MeshInstance3D = meshes[i]
		var built := brush.build_painted_mesh(_atlas, bi, timed, baked, stairs, hybrid, data.vertex_color_scale(),
			ranges[i].x, ranges[i].y)
		mi.mesh = built.mesh
		if mi.mesh:
			for k in built.keys.size():
				var key: int = built.keys[k]
				if LevelBrush.key_base(key) >= LevelBrush.STAIR_KEY:
					mi.mesh.surface_set_material(k, _stair_material(brush, key,
						built.stair_runs[LevelBrush.key_base(key) - LevelBrush.STAIR_KEY]))
				else:
					mi.mesh.surface_set_material(k, _material_for(key, brush))
	_chunks[brush] = {ranges = ranges, base = base, sigs = sigs}
	main.transform = brush.transform
	for mi in meshes:
		mi.layers = level_layers()
		mi.material_override = DEBUG_MATERIAL if debug_view else null


## The brush's chunk meshes: its instance, then internal children for chunks 1…
func _chunk_meshes(main: MeshInstance3D, count: int) -> Array:
	var out := [main]
	var extra := main.get_children(true).filter(func(c): return c is MeshInstance3D)
	for i in range(1, count):
		if i - 1 < extra.size():
			out.append(extra[i - 1])
		else:
			var mi := MeshInstance3D.new()
			main.add_child(mi, false, INTERNAL_MODE_BACK)
			out.append(mi)
	for i in range(count - 1, extra.size()):
		extra[i].queue_free()
	return out


## Hash of a chunk's own faces: topology, texture, UV tweak, corner colours / lighting and
## painted-mask charts (all stored per face / corner, so slices are cheap).
func _chunk_sig(brush: LevelBrush, r: Vector2i) -> int:
	var n := brush.get_face_count()
	var c0 := brush.get_face_start(r.x) if r.x < n else brush.face_indices.size()
	var c1 := brush.get_face_start(r.y) if r.y < n else brush.face_indices.size()
	var parts := [r, brush.face_counts.slice(r.x, r.y), brush.face_indices.slice(c0, c1),
		brush.face_textures.slice(r.x, r.y), brush.face_uv.slice(r.x, r.y), brush.face_layer_sets.slice(r.x, r.y),
		brush.corner_uvs.slice(c0, c1), brush.cutout,
		brush._resolved_corners().slice(c0, c1),
		brush.corner_lighting.slice(c0, c1)]
	for keys in brush.corner_lighting_keys:
		parts.append(keys.slice(c0, c1))
	var bi := data.brushes.find(brush)
	for f in brush.masked_faces():
		if f >= r.x and f < r.y:
			parts.append([f, _atlas.rects.get(Vector2i(bi, f))])
	# Its vertices (positions, AO, and colours where there are no per-corner ones).
	var verts := brush.vertices
	var ao := brush.vertex_ao
	var vcol := brush.vertex_colors
	var use_vcol := not brush.has_corner_colors()
	var pos := PackedVector3Array()
	pos.resize(c1 - c0)
	var vals := PackedFloat32Array()
	vals.resize((c1 - c0) * (4 if use_vcol else 1))
	var w := 0
	for c in range(c0, c1):
		var vi := brush.face_indices[c]
		pos[c - c0] = verts[vi] if vi < verts.size() else Vector3.ZERO
		vals[w] = ao[vi] if vi < ao.size() else 1.0
		w += 1
		if use_vcol:
			var col: Color = vcol[vi] if vi < vcol.size() else Color.WHITE
			vals[w] = col.r
			vals[w + 1] = col.g
			vals[w + 2] = col.b
			w += 3
	parts.append(pos)
	parts.append(vals)
	return hash(parts)


func _material_for(key: int, brush: LevelBrush) -> Material:
	if key == -2:
		if not _materials.has(brush.material):
			_materials[brush.material] = PaintAtlas.convert_material(brush.material, data, _mask_textures)
		return _materials[brush.material]
	if not _materials.has(key):
		var tex := LevelBrush.key_texture(key)
		var base: Texture2D = data.textures[tex] if tex >= 0 and tex < data.textures.size() else null
		_materials[key] = PaintAtlas.make_material(base, data, _mask_textures, LevelBrush.key_set(key), LevelBrush.key_cutout(key))
		PaintAtlas.set_overlay_code(_materials[key], LevelBrush.key_overlay(key), data)
	return _materials[key]


## Per brush and run: each flight of painted stairs carries its own step frame.
func _stair_material(brush: LevelBrush, key: int, run: Dictionary) -> Material:
	var stair := data.textures[run.texture] as N64StairTexture
	var mat := PaintAtlas.make_material(stair, data, _mask_textures, LevelBrush.key_set(key), LevelBrush.key_cutout(key))
	PaintAtlas.apply_stair(mat, stair, run.frame)
	_materials[[brush.get_instance_id(), key]] = mat
	_stair_sources[[brush.get_instance_id(), key]] = stair
	return mat


func _rebuild_masks() -> void:
	_mask_images.clear()
	_mask_textures.clear()
	for i in data.mask_slot_count():
		var img := PaintAtlas.build_layer(data.brushes, _atlas, i)
		_mask_images.append(img)
		_mask_textures.append(ImageTexture.create_from_image(img))
	for mat in _materials.values():
		if mat is ShaderMaterial and PaintAtlas.is_paint_shader(mat.shader):
			PaintAtlas.apply_layers(mat, data, _mask_textures)


## Settings that only feed materials: update the existing ones in place (meshes stay).
func _on_materials_changed() -> void:
	if not is_inside_tree() or not Engine.is_editor_hint():
		return
	for key in _materials:
		var mat = _materials[key]
		if not mat is ShaderMaterial or not PaintAtlas.is_paint_shader(mat.shader):
			continue
		if key is int:
			var tex := LevelBrush.key_texture(key)
			PaintAtlas.refresh_material(mat, data.textures[tex] if tex >= 0 and tex < data.textures.size() else null, Color.WHITE, data, _mask_textures)
		elif key is Array:  # stair run: [brush id, surface key] -> its stair texture
			PaintAtlas.refresh_material(mat, _stair_sources.get(key), Color.WHITE, data, _mask_textures)
		elif key is BaseMaterial3D:  # brush material converted to the paint shader
			PaintAtlas.refresh_material(mat, key.albedo_texture, key.albedo_color if key.albedo_texture else Color.WHITE, data, _mask_textures)


func _on_paint_changed() -> void:
	if not is_inside_tree() or not Engine.is_editor_hint():
		return
	# Base palette / layer list may have changed: rebuild materials and masks.
	_materials.clear()
	_stair_sources.clear()
	_full_rebuild = true
	for brush in _instances:
		_mark_dirty(brush)


## Live painting: copies one face's mask into the layer atlas without a mesh rebuild.
## Returns false when the face has no chart yet (call request_rebuild()).
func update_mask_live(brush: LevelBrush, face: int, layer: int) -> bool:
	var chart = _atlas.rects.get(Vector2i(data.brushes.find(brush), face))
	if chart == null or layer >= _mask_images.size():
		return false
	var mask := brush.get_face_mask(face, layer)
	if mask == null:
		return false
	PaintAtlas.blit(_mask_images[layer], chart, mask)
	_mask_textures[layer].update(_mask_images[layer])
	return true


var _grass_nodes: Array[Node3D] = []
var _grass_at := -1.0


## Rebuilds the grass a moment after the last change (brush edits come in bursts).
func _queue_grass() -> void:
	if not is_inside_tree():
		return
	var first := _grass_at < 0.0
	_grass_at = Time.get_ticks_msec() * 0.001 + (0.6 if Engine.is_editor_hint() else 0.0)
	if first:
		_grass_wait.call_deferred()


func _grass_wait() -> void:
	while Time.get_ticks_msec() * 0.001 < _grass_at:
		await get_tree().process_frame
		if not is_inside_tree():
			_grass_at = -1.0
			return
	_grass_at = -1.0
	_rebuild_grass()


## The grass mat and tufts (GrassBuilder) from data.grass.
func _rebuild_grass() -> void:
	for n in _grass_nodes:
		if is_instance_valid(n):
			remove_child(n)  # (now: the new nodes take the same names)
			n.queue_free()
	_grass_nodes.clear()
	if data == null or data.grass == null or not data.grass.enabled:
		return
	_grass_nodes = GrassBuilder.build(self, data.grass)
	for n in _grass_nodes:
		add_child(n, false, INTERNAL_MODE_BACK)


## Export: the grass nodes, built fresh (not owned: the caller adds them to the bake).
func build_grass_for_export() -> Array[Node3D]:
	if data == null or data.grass == null or not data.grass.enabled:
		return [] as Array[Node3D]
	return GrassBuilder.build(self, data.grass)


func _queue_scatter() -> void:
	if is_inside_tree() and not _scatter_queued:
		_scatter_queued = true
		_rebuild_scatter.call_deferred()


## Rebuilds the scattered cut-outs' MultiMeshes (cheap: a few hundred transforms per set).
func _rebuild_scatter() -> void:
	_scatter_queued = false
	for nodes in _scatter_nodes.values():
		for node in nodes:
			if is_instance_valid(node):
				node.queue_free()
	_scatter_nodes.clear()
	if data == null:
		return
	for s in data.scatter:
		if s == null:
			continue
		var nodes := s.build_nodes(level_layers())
		for node in nodes:
			add_child(node, false, INTERNAL_MODE_BACK)
		_scatter_nodes[s] = nodes


## Re-layouts the atlas and rebuilds every brush mesh (new painted faces, layer changes).
func request_rebuild() -> void:
	_full_rebuild = true
	for brush in _instances:
		_mark_dirty(brush)


func _refresh_materials() -> void:
	for brush in _instances:
		var main: MeshInstance3D = _instances[brush]
		for mi in [main] + main.get_children(true).filter(func(c): return c is MeshInstance3D):
			mi.material_override = DEBUG_MATERIAL if debug_view else null


func _queue_apply_bake() -> void:
	if is_inside_tree() and not _bake_queued:
		_bake_queued = true
		_apply_bake.call_deferred()


## Visual layers for the level's meshes: Baked Vertex / Timed Dynamic levels sit on LevelLights.LAYER
## alone so lights baked into them (Bake Mode Static) can skip them live.
func level_layers() -> int:
	if data and LevelData.mode_is_hybrid(data.lighting_mode):
		return LevelLights.LAYER
	return 1


## Where near detail gives way to far stand-ins (Project Settings > n64/build/lod_distance).
const LOD_SETTING := "n64/build/lod_distance"
## Project setting: metres over which a near / far pair cross-fades instead of snapping
## (0 = snap): our own ordered dither in the level shaders (n64_lod_fade.gdshaderinc), one
## pattern for both, so each pixel shows exactly one of them. Godot's own fade dissolves
## the two independently (gaps show the sky), and its margins are hysteresis, which can
## leave both hidden; so its ranges only cull, loosely, around the band.
const LOD_FADE_SETTING := "n64/build/lod_fade"
const LOD_FADE := 4.0


static func lod_fade() -> float:
	return maxf(float(ProjectSettings.get_setting(LOD_FADE_SETTING, LOD_FADE)), 0.0)


static func lod_distance() -> float:
	return ProjectSettings.get_setting(LOD_SETTING, 40.0)


## Where small detail gives way to its flat stand-in (n64/build/detail_lod_distance).
const DETAIL_SETTING := "n64/build/detail_lod_distance"


static func detail_distance() -> float:
	return ProjectSettings.get_setting(DETAIL_SETTING, 20.0)


## How far a house's occluder stops short of its front (metres): an open shopfront's room
## and a little more (the camera can stand in it); nothing for shutters or no shop.
static func shop_inset(h: HouseSpec) -> float:
	if not h.shopfront or h.front_style == HouseSpec.Front.SHUTTERED:
		return 0.0
	return h.shop_depth + 0.1


## Occluders for the engine's occlusion culling: a box per house, its walls from the
## ground to the eaves (a little inside them), level space. Null without houses.
static func house_occluder(data: LevelData) -> ArrayOccluder3D:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for b: LevelBrush in data.brushes:
		if b == null or not b.is_house():
			continue
		var h := b.house
		var hw := h.width * 0.5 - 0.05
		var hd := h.depth * 0.5 - 0.05
		var top := h.wall_height() - 0.1
		# A shop is open at the front (+Z): the camera can stand in its doorway, and inside
		# the box it would see everything culled. Its box stops short of the front (shop_inset).
		var front := hd - shop_inset(h)
		if front + hd < 0.5:
			continue
		var base := verts.size()
		for y in [0.0, top]:
			for c in [Vector2(-hw, -hd), Vector2(hw, -hd), Vector2(hw, front), Vector2(-hw, front)]:
				verts.append(b.transform * Vector3(c.x, y, c.y))
		for q in [[0, 1, 2, 3], [7, 6, 5, 4], [0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0]]:
			idx.append_array([base + q[0], base + q[1], base + q[2], base + q[0], base + q[2], base + q[3]])
	if idx.is_empty():
		return null
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(verts, idx)
	return occ


## A baked chunk's visibility range from its mesh's "range" meta (near detail ends where its
## far stand-ins begin). The distances are baked in: change a LOD distance, bake again.
static func apply_lod_range(mi: MeshInstance3D, _at := 0.0) -> void:
	var r: Vector2 = mi.mesh.get_meta(&"range", Vector2.ZERO) if mi.mesh else Vector2.ZERO
	set_lod_fade(mi, r.x, r.y, lod_fade())


## `mi` drawn from `begin` to `end` metres (0 = no limit), dissolving over `band` metres
## around each limit (n64_lod_fade.gdshaderinc), measured to its bounds' centre.
static func set_lod_fade(mi: GeometryInstance3D, begin: float, end: float, band: float) -> void:
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	mi.visibility_range_begin_margin = 0.0
	mi.visibility_range_end_margin = 0.0
	var slack := band * 0.5 + 1.0 if band > 0.0 else 0.0
	mi.visibility_range_begin = maxf(begin - slack, 0.0) if begin > 0.0 else 0.0
	mi.visibility_range_end = end + slack if end > 0.0 else 0.0
	var swap := end if end > 0.0 else -begin
	if band <= 0.0 or swap == 0.0 or not (mi is MeshInstance3D) or mi.mesh == null:
		mi.set_instance_shader_parameter(&"n64_lod_fade", Vector4.ZERO)
		return
	var box: AABB = mi.mesh.custom_aabb if mi.mesh.custom_aabb.has_volume() else mi.mesh.get_aabb()
	var centre := box.get_center()  # mesh space: the shader places it with the model matrix
	mi.set_instance_shader_parameter(&"n64_lod_fade", Vector4(centre.x, centre.y, centre.z, swap))
	mi.set_instance_shader_parameter(&"n64_lod_fade_band", band)


func _apply_bake() -> void:
	_bake_queued = false
	if _baked_occluder:
		_baked_occluder.queue_free()
		_baked_occluder = null
	if _rain_cover:
		_rain_cover.queue_free()
		_rain_cover = null
	for n in _backdrop:
		n.queue_free()
	_backdrop.clear()
	for node in _baked_meshes + _baked_bodies:
		if node:
			node.queue_free()
	_baked_meshes.clear()
	_baked_bodies.clear()
	if data:
		var lod_at := lod_distance()
		for mesh in data.baked_meshes():
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.layers = level_layers()
			apply_lod_range(mi, lod_at)
			add_child(mi, false, INTERNAL_MODE_BACK)
			_baked_meshes.append(mi)
	if data:
		var c := data.baked_collision_set()
		for body in Surface.build_bodies(c[0], c[1]):
			add_child(body, false, INTERNAL_MODE_BACK)
			_baked_bodies.append(body)
		# Buildings hide what's behind them (occlusion culling, game only).
		var occ := house_occluder(data) if not Engine.is_editor_hint() else null
		if occ:
			var oi := OccluderInstance3D.new()
			oi.occluder = occ
			add_child(oi, false, INTERNAL_MODE_BACK)
			_baked_occluder = oi
		# Where rain lands (and what gets wet).
		_rain_cover = RainCover.from_build(data.rain_cover_built(), data.rain_light_built())
		if _rain_cover:
			add_child(_rain_cover, false, INTERNAL_MODE_BACK)
		# What's past the walls (the zones next door).
		_backdrop = Backdrop.build_nodes(data.backdrop_mesh, data.backdrop_ring, data.backdrop_ring_info)
		for n in _backdrop:
			add_child(n, false, INTERNAL_MODE_BACK)
	_update_visibility()


func _update_visibility() -> void:
	var show_baked: bool = not Engine.is_editor_hint() or (preview_baked and data != null and data.has_bake())
	for brush in _instances:
		# A fence's collision wall stays invisible (it would hide behind the see-through panels).
		var fence_wall: bool = brush.bake_mode == LevelBrush.BakeMode.COLLISION_ONLY and String(brush.tag).begins_with("fence_")
		_instances[brush].visible = not show_baked and not _hidden.has(brush) and not fence_wall
	for mi in _baked_meshes:
		mi.visible = show_baked
