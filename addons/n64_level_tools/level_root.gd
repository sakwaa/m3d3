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
		data = value
		if data:
			data.brushes_changed.connect(_sync_brushes)
			data.bake_changed.connect(_queue_apply_bake)
			data.paint_changed.connect(_on_paint_changed)
			data.materials_changed.connect(_on_materials_changed)
			data.scatter_changed.connect(_queue_scatter)
			_queue_scatter()
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


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	# Internal children are never saved, but clear any stray copies (e.g. from duplication).
	for child in get_children(true):
		if not child in get_children() and not child in _instances.values() \
				and not child in _baked_meshes and not child in _baked_bodies and not _scatter_nodes.values().any(func(n): return child in n):
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
	_sync_passages()
	_sync_doors()
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
	for brush in _instances.keys():
		if not wanted.has(brush):
			brush.changed.disconnect(_callbacks[brush])
			_instances[brush].queue_free()
			_instances.erase(brush)
			_callbacks.erase(brush)
			_chunks.erase(brush)
	_sync_passages()
	_sync_doors()
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
	for brush in batch:
		if _instances.has(brush):
			_build_instance(brush, full)
	geometry_changed.emit()


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
	var w := BrushOps.weld_vertices(verts, faces)
	brush.set_block_signals(true)
	brush.vertices = w.verts
	brush.set_faces(w.faces)
	brush.face_textures = textures
	brush.face_uv = uvs
	brush.corner_uvs = _exact_corner_uvs(w, uvs, exact)
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


## Fingerprint of everything a passage's / door's geometry is generated from: its settings
## and place.
static func passage_key(brush: LevelBrush) -> int:
	var parts := [brush.transform]
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
	brush.passage_built = key
	brush.set_block_signals(false)


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


## Export: the door nodes as saved nodes (owner = `scene`).
func make_door_nodes_for_export(scene: Node) -> void:
	_sync_doors()
	for brush in _door_nodes:
		var node: Door = _door_nodes[brush]
		if node.get_parent() == null:
			_door_host().add_child(node, true)
		node.owner = scene


func _notification(what: int) -> void:
	# In the editor the door nodes (outside this level) go with it: removed / scene closed.
	if what == NOTIFICATION_EXIT_TREE and Engine.is_editor_hint():
		for brush in _door_nodes:
			if is_instance_valid(_door_nodes[brush]):
				_door_nodes[brush].queue_free()
		_door_nodes.clear()
	elif what == NOTIFICATION_ENTER_TREE and Engine.is_editor_hint() and is_node_ready():
		_sync_doors.call_deferred()


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
	if scenes.is_empty():
		if node and is_instance_valid(node):
			node.queue_free()
		_rope_nodes.erase(brush)
		return
	var placed := []  # [scene, transform]
	for h: RopeHang in scenes:
		for spot in _hang_spots(brush, h):
			var d: Vector3 = spot.direction
			placed.append([h.scene, Transform3D(Basis(d, Vector3.UP, d.cross(Vector3.UP)), spot.position + Vector3.DOWN * h.drop)])
	var key := hash(placed.map(func(p): return [p[0].resource_path, p[0].get_instance_id(), p[1]]))
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


## Export: the hung scenes as saved children (owner = `scene`; each an instance of its scene).
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
		if h.kind != RopeHang.Kind.SCENE:
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
			# A scene's cord is drawn here too; the scene itself is a node (_sync_rope_node).
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


func _apply_bake() -> void:
	_bake_queued = false
	for node in _baked_meshes + _baked_bodies:
		if node:
			node.queue_free()
	_baked_meshes.clear()
	_baked_bodies.clear()
	if data:
		for mesh in data.baked_meshes():
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.layers = level_layers()
			add_child(mi, false, INTERNAL_MODE_BACK)
			_baked_meshes.append(mi)
	if data:
		var c := data.baked_collision_set()
		for body in Surface.build_bodies(c[0], c[1]):
			add_child(body, false, INTERNAL_MODE_BACK)
			_baked_bodies.append(body)
	_update_visibility()


func _update_visibility() -> void:
	var show_baked: bool = not Engine.is_editor_hint() or (preview_baked and data != null and data.has_bake())
	for brush in _instances:
		# A fence's collision wall stays invisible (it would hide behind the see-through panels).
		var fence_wall: bool = brush.bake_mode == LevelBrush.BakeMode.COLLISION_ONLY and String(brush.tag).begins_with("fence_")
		_instances[brush].visible = not show_baked and not _hidden.has(brush) and not fence_wall
	for mi in _baked_meshes:
		mi.visible = show_baked
