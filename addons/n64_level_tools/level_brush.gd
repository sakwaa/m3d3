@tool
class_name LevelBrush
extends Resource
## One editable low-poly brush stored inside a LevelData resource. Geometry is
## `vertices` + polygon faces (CCW around the outward normal) in brush-local space;
## `transform` places the brush relative to its LevelRoot.

enum BakeMode { VISUAL_AND_COLLISION, VISUAL_ONLY, COLLISION_ONLY }

@export var shape: BrushShapes.Shape = BrushShapes.Shape.BLOCK:
	set(value):
		shape = value
		notify_property_list_changed()
		_on_shape_params_changed()
@export var size := Vector3(2, 2, 2):
	set(value):
		size = value.max(Vector3.ZERO)
		_on_shape_params_changed()
@export_range(1, 64) var segments := 1:
	set(value):
		segments = value
		_on_shape_params_changed()
## Regenerates geometry from shape/size/segments, discarding vertex edits (undoable).
@export_tool_button("Rebuild From Shape", "Reload") var rebuild_from_shape_button := _rebuild_from_shape_pressed
@export var transform := Transform3D.IDENTITY:
	set(value):
		transform = value
		emit_changed()
@export var material: Material:
	set(value):
		material = value
		emit_changed()
## Optional id so other nodes can find this brush (e.g. a Passage's floor).
@export var tag: StringName
## Fence brush (style set): its geometry is generated from these (FenceBuilder, by the
## LevelRoot): points (brush-local, in order; each neighbouring pair a section, any
## direction and slope), loop, open sections. Moving the brush moves the fence.
@export var fence_style: FenceStyle:
	set(value):
		if fence_style and fence_style.changed.is_connected(_on_fence_changed):
			fence_style.changed.disconnect(_on_fence_changed)
		fence_style = value
		if fence_style and Engine.is_editor_hint():
			fence_style.changed.connect(_on_fence_changed)
		_on_fence_changed()
## Distance between posts along each section (0 = the style's); the last span of a
## section takes what's left. End caps go on the ends and beside open sections.
@export_range(0.0, 10.0, 0.05, "or_greater", "suffix:m") var fence_spacing := 0.0:
	set(value):
		fence_spacing = value
		_on_fence_changed()
## Every post stands on the ground under it (moving the fence up / down onto a platform
## just works). Off: posts on the points and the straight lines between them (bridges,
## ledges, floating fences).
@export var fence_follow_ground := true:
	set(value):
		fence_follow_ground = value
		_on_fence_changed()
## Posts between the points sink this far at the middle of each section (a droopy, rickety
## look; 0 = they stand on the ground).
@export_range(0.0, 1.0, 0.01, "or_greater", "suffix:m") var fence_sag := 0.0:
	set(value):
		fence_sag = value
		_on_fence_changed()
@export_storage var fence_points := PackedVector3Array():
	set(value):
		fence_points = value
		_on_fence_changed()
@export_storage var fence_closed := false:
	set(value):
		fence_closed = value
		_on_fence_changed()
## Open sections (i = between point i and i + 1): an arch, no panel.
@export_storage var fence_open := PackedInt32Array():
	set(value):
		fence_open = value
		_on_fence_changed()
## Set when the fence geometry needs generating again (LevelRoot does it).
var fence_dirty := false
## Rope brush (style set): a ribbon hanging between its points (RopeBuilder, by the
## LevelRoot): points (brush-local, in order, anchored anywhere: building corners, poles),
## each neighbouring pair a section that droops `rope_sag` at its middle; open sections are
## left out. Moving the brush moves the rope.
@export var rope_style: RopeStyle:
	set(value):
		if rope_style and rope_style.changed.is_connected(_on_rope_changed):
			rope_style.changed.disconnect(_on_rope_changed)
		rope_style = value
		if rope_style and Engine.is_editor_hint():
			rope_style.changed.connect(_on_rope_changed)
		_on_rope_changed()
## How far each section hangs below the straight line between its points, at its middle.
@export_range(0.0, 4.0, 0.01, "or_greater", "suffix:m") var rope_sag := 0.4:
	set(value):
		rope_sag = maxf(value, 0.0)
		_on_rope_changed()
## What hangs along the rope (lanterns, shimenawa tassels, shide, banners …), each with its
## own placement; they mix (RopeHang).
@export var rope_hangs: Array[RopeHang] = []:
	set(value):
		for h in rope_hangs:
			if h and h.changed.is_connected(_on_rope_changed):
				h.changed.disconnect(_on_rope_changed)
		rope_hangs = value
		if Engine.is_editor_hint():
			for h in rope_hangs:
				if h and not h.changed.is_connected(_on_rope_changed):
					h.changed.connect(_on_rope_changed)
		_on_rope_changed()
## Before rope_hangs: one scene, spacing and cord (read once into rope_hangs, then cleared).
@export_storage var rope_hang_scene: PackedScene
@export_storage var rope_hang_spacing := 1.5
@export_storage var rope_hang_drop := 0.25
@export_storage var rope_points := PackedVector3Array():
	set(value):
		rope_points = value
		_on_rope_changed()
## Open sections (i = between point i and i + 1): no rope there.
@export_storage var rope_open := PackedInt32Array():
	set(value):
		rope_open = value
		_on_rope_changed()
## Set when the rope geometry needs generating again (LevelRoot does it).
var rope_dirty := false
## Passage brush (set): the LevelRoot builds its corridor geometry and its Passage node from
## this. Origin = the threshold, -Z out of the zone.
@export var passage: PassageSpec:
	set(value):
		if passage and passage.changed.is_connected(_on_passage_changed):
			passage.changed.disconnect(_on_passage_changed)
		passage = value
		if passage:
			passage.changed.connect(_on_passage_changed)
		_on_passage_changed()
## Set when the passage / door geometry needs generating again (LevelRoot does it).
var passage_dirty := false
## Fingerprint of what the corridor was last generated from (LevelRoot.passage_key): loading
## a level marks passages dirty, and an unchanged one keeps its geometry and baked lighting.
@export_storage var passage_built := 0
## Door brush (set): the LevelRoot builds its lining / trim and its Door node from this.
## Origin = where the panel hangs (bottom centre), +Z towards the side it was placed from.
@export var door: DoorSpec:
	set(value):
		if door and door.changed.is_connected(_on_passage_changed):
			door.changed.disconnect(_on_passage_changed)
		door = value
		if door:
			door.changed.connect(_on_passage_changed)
		_on_passage_changed()
## Double-sided, and the base texture's alpha cuts holes (fences, grilles, hanging cloth).
@export var cutout := false:
	set(value):
		cutout = value
		emit_changed()
@export var bake_mode := BakeMode.VISUAL_AND_COLLISION:
	set(value):
		bake_mode = value
		emit_changed()
## Stairs only: bake collision as a smooth ramp so characters can walk up the steps.
@export var stairs_collision_ramp := true:
	set(value):
		stairs_collision_ramp = value
		emit_changed()
@export_group("Blender")
## Set piece: the .blend (res://) this brush's geometry is made in; Godot keeps where it
## stands and its paint. Empty = shaped here. See LevelBlender.
@export var blend_file := ""
## The Blender object this brush is (a set piece's brushes share its space).
@export var blend_object := ""
@export_group("")

## Blender's face ids (`n64_face`) per face: paint follows them on each pull.
@export_storage var face_ids := PackedInt32Array()
## The .blend's modified time at the last pull.
@export_storage var blend_stamp := 0
## Openings cut here into a set piece's geometry (doors, passages), cut again after every
## pull so the .blend stays as made: [{tag, xf (brush space, PassageBuilder opening),
## width, height, depth}].
@export_storage var cuts := []

@export_storage var vertices := PackedVector3Array():
	set(value):
		_hold_corners()
		# Same vertex count over a valid cache: only positions moved (sculpting, dragging),
		# so the triangulation can stay (see _ensure_cache).
		if _cache_valid and value.size() == vertices.size():
			_positions_only = true
		vertices = value
		_on_geometry_changed()
## Flattened polygon vertex indices; `face_counts[i]` is the corner count of face i.
@export_storage var face_indices := PackedInt32Array():
	set(value):
		_hold_corners()
		face_indices = value
		_positions_only = false
		_on_geometry_changed()
@export_storage var face_counts := PackedInt32Array():
	set(value):
		_hold_corners()
		face_counts = value
		_positions_only = false
		_on_geometry_changed()
## Set once geometry is edited by hand; shape params then stop auto-regenerating.
@export_storage var hand_edited := false

## Per-face base texture: index into LevelData.textures; -1 = brush `material` / neutral.
@export_storage var face_textures := PackedInt32Array():
	set(value):
		face_textures = value
		emit_changed()
## Per-face surface override (Surface sound | flags; 0 = none): a sound replaces the one
## from the face's textures, flags are added to theirs. Painted with the Surface layer.
@export_storage var face_surfaces := PackedInt32Array():
	set(value):
		face_surfaces = value
		emit_changed()
## Exact UV per face corner (aligned with face_indices), in metres like the projected UVs
## (the shader divides by the texture's tile): a texture fitted to a quad (fence panels).
## Replaces the projection + face_uv where set; dropped when the topology no longer matches.
@export_storage var corner_uvs := PackedVector2Array():
	set(value):
		corner_uvs = value
		emit_changed()
## Per-face bake override: 0 = the brush's bake_mode, 1 visual only, 2 collision only
## (a fence's invisible wall inside the fence brush; not drawn). Missing entries are 0.
@export_storage var face_bake := PackedByteArray():
	set(value):
		face_bake = value
		emit_changed()
## Per-face overlay set (LevelData.layers_of; 0 = the level's default layers). Missing
## entries are 0.
@export_storage var face_layer_sets := PackedInt32Array():
	set(value):
		face_layer_sets = value
		emit_changed()
## Pieces of one face cut by the Border tool's corners share an id here (0 = not cut), so
## erasing the border can merge them back (merge_faces). Missing entries are 0.
@export_storage var face_pieces := PackedInt32Array():
	set(value):
		face_pieces = value
		emit_changed()
## Per-face UV tweak: (offset u, offset v, scale, rotation degrees) on top of the
## world-aligned projection.
@export_storage var face_uv := PackedVector4Array():
	set(value):
		face_uv = value
		emit_changed()
## Painted overlay masks: Vector2i(face, layer) -> Image (L8) covering the face's planar
## bounds. Images are never edited in place once stored (replace them), so duplicated
## brushes and undo snapshots can share them safely.
@export_storage var face_masks := {}:
	set(value):
		face_masks = value
		_masked_faces.clear()
		for key in face_masks:
			_masked_faces[key.x] = true
		emit_changed()

## Per-vertex colour (aligned with `vertices`), multiplied into the final shade like the
## N64's vertex colours. Missing entries are white (no change).
@export_storage var vertex_colors := PackedColorArray():
	set(value):
		vertex_colors = value
		emit_changed()

## Painted colour per face corner (aligned with face_indices, like corner_lighting), so
## neighbouring faces can differ at a shared vertex (hard colour edges, no extra geometry).
## Replaces vertex_colors in the shade once painted; vertex_colors then holds the average
## per vertex (fallback, Blender context). Empty = vertex_colors only. Follows topology
## edits by itself (see _hold_corners).
@export_storage var corner_colors := PackedColorArray():
	set(value):
		corner_colors = value
		_corner_src = {}
		emit_changed()

## Baked ambient occlusion per vertex (1 = open), from "Bake AO into vertex colours".
## Multiplies the shade like vertex_colors but is kept apart from painting, so it can be
## re-baked, cleared or hidden in the editor (n64_vertex_ao) without touching paint.
## Rendered through the vertex colour alpha. Missing entries are 1.
@export_storage var vertex_ao := PackedFloat32Array():
	set(value):
		vertex_ao = value
		emit_changed()

## Baked lighting per face corner (aligned with face_indices), from LevelLighting.
## Multiplies vertex_colors; stale sizes (after topology edits) count as white.
@export_storage var corner_lighting := PackedColorArray():
	set(value):
		corner_lighting = value
		emit_changed()

## Time-of-day lighting: one corner array per LightingSchedule key (slot order).
@export_storage var corner_lighting_keys: Array[PackedColorArray] = []:
	set(value):
		corner_lighting_keys = value
		emit_changed()

const DEFAULT_UV := Vector4(0, 0, 1, 0)
## Mesh flags storing up to 4 lighting keys as RGBA8 in CUSTOM0..3.
const KEY_FORMAT := (Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
	| (Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
	| (Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT) \
	| (Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT)

var _face_starts := PackedInt32Array()
var _face_normals := PackedVector3Array()
var _face_rects: Array[Rect2] = []
var _vertex_normals := PackedVector3Array()
var _masked_faces := {}
var _tri_indices := PackedInt32Array()
var _tri_faces := PackedInt32Array()
var _tri_corners := PackedInt32Array()
var _vertex_faces: Array[PackedInt32Array] = []
var _edges: Array[Vector2i] = []
var _cache_valid := false
## Since the cache was built only vertex positions changed (not faces).
var _positions_only := false
## Topology before an edit, while corner_colors still match it: carried over to the new
## faces on the next read (_resolve_corners).
var _corner_src := {}


## Settings that only mean something on one kind of brush.
const FENCE_PROPERTIES := [&"fence_style", &"fence_spacing", &"fence_follow_ground", &"fence_sag"]
const ROPE_PROPERTIES := [&"rope_style", &"rope_sag", &"rope_hangs"]
## Shape settings: fences / passages / doors generate their geometry from their own settings.
const SHAPE_PROPERTIES := [&"shape", &"size", &"segments", &"rebuild_from_shape_button", &"stairs_collision_ramp",
	&"material", &"cutout", &"blend_file", &"blend_object"]


## The inspector shows only what applies to this kind of brush (fence, passage or plain);
## the rest is still saved. Fences, passages and doors are made with their tools, not by
## setting a style / spec on a plain brush.
func _validate_property(property: Dictionary) -> void:
	var name: StringName = property.name
	var hide := false
	if name in FENCE_PROPERTIES:
		hide = not is_fence()
	elif name in ROPE_PROPERTIES:
		hide = not is_rope()
	elif name == &"passage":
		hide = not is_passage()
	elif name == &"door":
		hide = not is_door()
	elif name in SHAPE_PROPERTIES:
		hide = is_fence() or is_rope() or is_passage() or is_door() or (name == &"stairs_collision_ramp" and shape != BrushShapes.Shape.STAIRS)
	if hide:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func ensure_geometry() -> void:
	if face_counts.is_empty() and not hand_edited:
		generate_from_shape()


func generate_from_shape() -> void:
	var b := BrushShapes.build(shape, size, segments)
	vertices = b.verts
	face_indices = b.indices
	face_counts = b.counts
	hand_edited = false


func uses_collision_ramp() -> bool:
	return shape == BrushShapes.Shape.STAIRS and stairs_collision_ramp and not hand_edited


func get_faces() -> Array[PackedInt32Array]:
	return BrushOps.unpack_faces(face_indices, face_counts)


func set_faces(faces: Array[PackedInt32Array]) -> void:
	var packed: Array = BrushOps.pack_faces(faces)
	face_indices = packed[0]
	face_counts = packed[1]


## Geometry (and per-face paint) state for undo/redo.
func snapshot() -> Dictionary:
	return {vertices = vertices.duplicate(), face_indices = face_indices.duplicate(),
		face_counts = face_counts.duplicate(), face_ids = face_ids.duplicate(), hand_edited = hand_edited,
		face_textures = face_textures.duplicate(), face_uv = face_uv.duplicate(), face_masks = face_masks.duplicate(),
		face_surfaces = face_surfaces.duplicate(), face_layer_sets = face_layer_sets.duplicate(),
		face_pieces = face_pieces.duplicate(), face_bake = face_bake.duplicate(), corner_uvs = corner_uvs.duplicate(),
		fence_points = fence_points.duplicate(), fence_open = fence_open.duplicate(),
		rope_points = rope_points.duplicate(), rope_open = rope_open.duplicate(), vertex_colors = vertex_colors.duplicate(), vertex_ao = vertex_ao.duplicate(), corner_lighting = corner_lighting.duplicate(),
		corner_lighting_keys = corner_lighting_keys.duplicate(), corner_colors = _resolved_corners().duplicate()}


# --- Per-face paint -------------------------------------------------------------------

func get_corner_light(corner: int) -> Color:
	if corner_lighting.size() != face_indices.size() or corner >= corner_lighting.size():
		return Color.WHITE
	return corner_lighting[corner]


## Lighting of a corner for one time key (white when not baked / stale).
func get_corner_key_light(key: int, corner: int) -> Color:
	if key >= corner_lighting_keys.size():
		return Color.WHITE
	var arr := corner_lighting_keys[key]
	return arr[corner] if arr.size() == face_indices.size() else Color.WHITE


## Appends a colour as 4 RGBA8 bytes (mesh CUSTOM channel data).
## A vertex colour as the mesh stores it: rgb / `scale`, clamped to 0 – 1 (alpha = AO kept).
static func scaled_color(c: Color, scale: float) -> Color:
	return Color(clampf(c.r / scale, 0.0, 1.0), clampf(c.g / scale, 0.0, 1.0), clampf(c.b / scale, 0.0, 1.0), c.a)


static func push_rgba8(bytes: PackedByteArray, c: Color) -> void:
	bytes.append(clampi(roundi(c.r * 255.0), 0, 255))
	bytes.append(clampi(roundi(c.g * 255.0), 0, 255))
	bytes.append(clampi(roundi(c.b * 255.0), 0, 255))
	bytes.append(255)


func get_face_start(face: int) -> int:
	_ensure_cache()
	return _face_starts[face]


## Faces using each vertex.
func get_vertex_faces() -> Array[PackedInt32Array]:
	_ensure_cache()
	if _vertex_faces.size() != vertices.size():
		_vertex_faces.resize(vertices.size())
		for i in vertices.size():
			_vertex_faces[i] = PackedInt32Array()
		for f in face_counts.size():
			for i in get_face_vertex_ids(f):
				_vertex_faces[i].append(f)
	return _vertex_faces


## Triangle corner positions (brush-local), 3 per triangle.
func get_triangle_positions() -> PackedVector3Array:
	_ensure_cache()
	var out := PackedVector3Array()
	for i in _tri_indices:
		out.append(vertices[i])
	return out


## Triangles that block light / AO (all but pick-only faces).
func get_occluder_triangle_positions() -> PackedVector3Array:
	if not face_bake.has(3):
		return get_triangle_positions()
	_ensure_cache()
	var out := PackedVector3Array()
	for t in _tri_faces.size():
		if not face_pick_only(_tri_faces[t]):
			for k in 3:
				out.append(vertices[_tri_indices[t * 3 + k]])
	return out


func get_vertex_color(i: int) -> Color:
	return vertex_colors[i] if i < vertex_colors.size() else Color.WHITE


func get_vertex_ao(i: int) -> float:
	return vertex_ao[i] if i < vertex_ao.size() else 1.0


## What the mesh carries per vertex: painted colour (rgb) and baked AO (alpha).
func get_vertex_shade(i: int) -> Color:
	var c := get_vertex_color(i)
	c.a = get_vertex_ao(i)
	return c


# --- Corner colours ---------------------------------------------------------------------

## Painted colour of a face corner (`vi`: its vertex): corner_colors once painted, else the
## vertex colour.
func get_corner_color(corner: int, vi: int) -> Color:
	var cc := _resolved_corners()
	return cc[corner] if cc.size() == face_indices.size() and corner < cc.size() else get_vertex_color(vi)


## What the mesh carries per corner: painted colour (rgb) and baked AO (alpha).
func get_corner_shade(corner: int, vi: int) -> Color:
	var c := get_corner_color(corner, vi)
	c.a = get_vertex_ao(vi)
	return c


func has_corner_colors() -> bool:
	return _resolved_corners().size() == face_indices.size() and not corner_colors.is_empty()


## A colour for every corner (from vertex_colors before the brush was painted per corner),
## for editing.
func full_corner_colors() -> PackedColorArray:
	if has_corner_colors():
		return corner_colors.duplicate()
	var out := PackedColorArray()
	out.resize(face_indices.size())
	for c in face_indices.size():
		out[c] = get_vertex_color(face_indices[c])
	return out


## Corner indices using each vertex.
func get_vertex_corners() -> Array[PackedInt32Array]:
	var out: Array[PackedInt32Array] = []
	out.resize(vertices.size())
	for i in vertices.size():
		out[i] = PackedInt32Array()
	for c in face_indices.size():
		if face_indices[c] < out.size():
			out[face_indices[c]].append(c)
	return out


## {corner_colors, vertex_colors} for painted corner colours `cc`: vertex_colors become
## the average of each vertex's corners. For undoable paint (set both).
func corner_paint(cc: PackedColorArray) -> Dictionary:
	var vc := PackedColorArray()
	vc.resize(vertices.size())
	vc.fill(Color(0, 0, 0, 0))
	var counts := PackedInt32Array()
	counts.resize(vertices.size())
	for c in mini(cc.size(), face_indices.size()):
		var vi := face_indices[c]
		vc[vi] += cc[c]
		counts[vi] += 1
	for i in vc.size():
		vc[i] = vc[i] / counts[i] if counts[i] > 0 else Color.WHITE
	return {corner_colors = cc, vertex_colors = vc}


func set_corner_paint(cc: PackedColorArray) -> void:
	var state := corner_paint(cc)
	vertex_colors = state.vertex_colors
	corner_colors = state.corner_colors


## Corner colours after an edit that knows where its faces came from (extrude): new face i
## continues old face map[i] (-1: none) and new vertex v copies old vertex_map[v], so each
## corner takes its source face's corner at that vertex. Extruded sides carry the colours
## of the face they grew from, like Blender. Call once the new faces are set.
func remap_corner_colors(old_faces: Array[PackedInt32Array], old_colors: PackedColorArray,
		map: PackedInt32Array, vertex_map: PackedInt32Array) -> void:
	var old_starts := PackedInt32Array()
	var s := 0
	for f in old_faces:
		old_starts.append(s)
		s += f.size()
	var out := PackedColorArray()
	out.resize(face_indices.size())
	s = 0
	for f in face_counts.size():
		var of := map[f] if f < map.size() else -1
		for k in face_counts[f]:
			var v := face_indices[s + k]
			var ov := vertex_map[v] if v < vertex_map.size() else -1
			var c := get_vertex_color(v)
			if of >= 0 and of < old_faces.size() and ov >= 0:
				var at := old_faces[of].find(ov)
				if at >= 0 and old_starts[of] + at < old_colors.size():
					c = old_colors[old_starts[of] + at]
			out[s + k] = c
		s += face_counts[f]
	corner_colors = out


## Remembers the current topology (once per edit) before vertices / faces change, while
## corner_colors still match it.
func _hold_corners() -> void:
	if not _corner_src.is_empty() or corner_colors.is_empty() or corner_colors.size() != face_indices.size():
		return
	_corner_src = {vertices = vertices, face_indices = face_indices, face_counts = face_counts, colors = corner_colors}


func _resolved_corners() -> PackedColorArray:
	_resolve_corners()
	return corner_colors


## After an edit: same faces keep their corners; new topology takes them over by position.
func _resolve_corners() -> void:
	if _corner_src.is_empty():
		return
	var src := _corner_src
	_corner_src = {}
	var total := 0
	for n in face_counts:
		total += n
	if total != face_indices.size():
		_corner_src = src  # mid-edit (faces half set): wait for the rest
		return
	if src.face_indices == face_indices and src.face_counts == face_counts:
		return  # vertices moved only: corners still line up
	var cc := transfer_corner_colors(src.vertices, src.face_indices, src.face_counts, src.colors,
		vertices, face_indices, face_counts, vertex_colors)
	corner_colors = cc


## Corner colours for new topology from old (same space). A new corner takes the old corner
## at the same spot on a face turned the same way (preferring the old face its own face sits
## in); a corner new to the surface (a split, a cut) blends the old face it lies on; anything
## else gets its vertex colour from `fallback`.
static func transfer_corner_colors(old_verts: PackedVector3Array, old_indices: PackedInt32Array,
		old_counts: PackedInt32Array, old_colors: PackedColorArray, verts: PackedVector3Array,
		indices: PackedInt32Array, counts: PackedInt32Array, fallback: PackedColorArray) -> PackedColorArray:
	const EPS := 0.001
	var old_faces := []  # {start, n, d, pts, uv}
	var at := {}  # quantized position -> [[old face, corner]]
	# Old faces by grid cell (their bounds), so big brushes don't compare every face pair.
	var bounds := AABB(old_verts[0] if not old_verts.is_empty() else Vector3.ZERO, Vector3.ZERO)
	for v in old_verts:
		bounds = bounds.expand(v)
	var cell := maxf(bounds.get_longest_axis_size() / 32.0, 0.25)
	var grid := {}  # Vector3i -> [old face]
	var s := 0
	for f in old_counts.size():
		var pts := PackedVector3Array()
		for k in old_counts[f]:
			pts.append(old_verts[old_indices[s + k]] if old_indices[s + k] < old_verts.size() else Vector3.ZERO)
		var n := PolyUtil.newell_normal(pts)
		var uv := PackedVector2Array()
		for p in pts:
			uv.append(PolyUtil.planar_uv(p, n))
		old_faces.append({start = s, n = n, d = n.dot(pts[0]) if not pts.is_empty() else 0.0, pts = pts, uv = uv})
		for k in pts.size():
			at.get_or_add(Vector3i((pts[k] / EPS).round()), []).append([f, s + k])
		if not pts.is_empty():
			var box := AABB(pts[0], Vector3.ZERO)
			for p in pts:
				box = box.expand(p)
			box = box.grow(EPS * 10.0)
			var lo := Vector3i((box.position / cell).floor())
			var hi := Vector3i((box.end / cell).floor())
			for x in range(lo.x, hi.x + 1):
				for y in range(lo.y, hi.y + 1):
					for z in range(lo.z, hi.z + 1):
						grid.get_or_add(Vector3i(x, y, z), []).append(f)
		s += old_counts[f]
	var out := PackedColorArray()
	out.resize(indices.size())
	s = 0
	for f in counts.size():
		var pts := PackedVector3Array()
		for k in counts[f]:
			pts.append(verts[indices[s + k]])
		var n := PolyUtil.newell_normal(pts)
		var centre := Vector3.ZERO
		for p in pts:
			centre += p
		centre /= maxf(pts.size(), 1.0)
		# Old faces this one sits in (same plane, centre inside): first choice for its corners.
		var home := {}
		if n != Vector3.ZERO:
			for of in grid.get(Vector3i((centre / cell).floor()), []):
				var o: Dictionary = old_faces[of]
				if o.n.dot(n) > 0.95 and absf(o.n.dot(centre) - o.d) < EPS * 10.0 \
						and _on_polygon(PolyUtil.planar_uv(centre, o.n), o.uv, EPS):
					home[of] = true
		for k in pts.size():
			var vi := indices[s + k]
			var c := Color.WHITE
			var found := false
			if n != Vector3.ZERO:
				var best_dot := 0.95
				for cand: Array in at.get(Vector3i((pts[k] / EPS).round()), []):
					var dot: float = old_faces[cand[0]].n.dot(n) + (1.0 if home.has(cand[0]) else 0.0)
					if dot > best_dot:
						best_dot = dot
						c = old_colors[cand[1]]
						found = true
				if not found:
					for of in (home.keys() if not home.is_empty() else grid.get(Vector3i((pts[k] / cell).floor()), [])):
						var o: Dictionary = old_faces[of]
						if o.n.dot(n) <= 0.95 or absf(o.n.dot(pts[k]) - o.d) > EPS * 10.0:
							continue
						var w := _blend_on_polygon(PolyUtil.planar_uv(pts[k], o.n), o.uv, EPS)
						if w.is_empty():
							continue
						c = Color(0, 0, 0, 0)
						for j in w.size():
							c += old_colors[o.start + j] * w[j]
						found = true
						break
			if not found:
				c = fallback[vi] if vi < fallback.size() else Color.WHITE
			out[s + k] = c
		s += counts[f]
	return out


## Point inside (or within eps of the edge of) a 2D polygon.
static func _on_polygon(p: Vector2, poly: PackedVector2Array, eps: float) -> bool:
	if poly.size() < 3:
		return false
	if Geometry2D.is_point_in_polygon(p, poly):
		return true
	for i in poly.size():
		var q := Geometry2D.get_closest_point_to_segment(p, poly[i], poly[(i + 1) % poly.size()])
		if p.distance_to(q) <= eps:
			return true
	return false


## Weights of the polygon's corners for a point on it (on an edge: just that edge's two
## ends; inside: inverse distance). Empty when the point is off the polygon.
static func _blend_on_polygon(p: Vector2, poly: PackedVector2Array, eps: float) -> PackedFloat32Array:
	var w := PackedFloat32Array()
	if not _on_polygon(p, poly, eps):
		return w
	w.resize(poly.size())
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		if p.distance_to(q) <= eps:
			var t := clampf((q - a).length() / maxf((b - a).length(), 1e-9), 0.0, 1.0)
			w.fill(0.0)
			w[i] = 1.0 - t
			w[(i + 1) % poly.size()] += t
			return w
	var total := 0.0
	for i in poly.size():
		w[i] = 1.0 / maxf(p.distance_to(poly[i]), 1e-6)
		total += w[i]
	for i in poly.size():
		w[i] /= total
	return w


## vertex_colors padded to the vertex count (white), for editing.
func full_vertex_colors() -> PackedColorArray:
	var out := vertex_colors.duplicate()
	var old := out.size()
	if old < vertices.size():
		out.resize(vertices.size())
		for i in range(old, out.size()):
			out[i] = Color.WHITE
	return out


## New vertices that average several old ones (subdivision) average their colours.
func blend_vertex_colors(sources: Array[PackedInt32Array]) -> void:
	if not vertex_ao.is_empty():
		var ao := PackedFloat32Array()
		ao.resize(sources.size())
		for i in sources.size():
			var sum := 0.0
			for src in sources[i]:
				sum += get_vertex_ao(src)
			ao[i] = sum / maxf(sources[i].size(), 1.0)
		vertex_ao = ao
	if vertex_colors.is_empty():
		return
	var out := PackedColorArray()
	out.resize(sources.size())
	for i in sources.size():
		var c := Color(0, 0, 0, 0)
		for s in sources[i]:
			c += get_vertex_color(s)
		out[i] = c / maxf(sources[i].size(), 1.0)
	vertex_colors = out


## After a face was split, crops each child's (copied) parent masks to the part of the
## parent's planar bounds the child covers, so painting stays in place.
func crop_child_masks(parent_rects: Dictionary) -> void:
	var masks := face_masks.duplicate()
	var changed := false
	for key in face_masks:
		if not parent_rects.has(key.x):
			continue
		var parent: Rect2 = parent_rects[key.x]
		var child := get_face_planar_rect(key.x)
		var img: Image = face_masks[key]
		var size := Vector2(img.get_size())
		var from := ((child.position - parent.position) / parent.size * size).floor()
		var to := ((child.end - parent.position) / parent.size * size).ceil()
		var region := Rect2i(Vector2i(from), Vector2i(to - from)).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
		if not region.has_area():
			continue
		var cropped := img.get_region(region)
		if cropped.get_width() < 4 or cropped.get_height() < 4:
			cropped.resize(maxi(cropped.get_width(), 4), maxi(cropped.get_height(), 4), Image.INTERPOLATE_BILINEAR)
		masks[key] = cropped
		changed = true
	if changed:
		face_masks = masks


## Follows a vertex remap (vertex_map[new] = old, -1 = new white vertex).
func remap_vertex_colors(vertex_map: PackedInt32Array) -> void:
	if not vertex_ao.is_empty():
		var ao := PackedFloat32Array()
		ao.resize(vertex_map.size())
		for i in vertex_map.size():
			ao[i] = get_vertex_ao(vertex_map[i]) if vertex_map[i] >= 0 else 1.0
		vertex_ao = ao
	if vertex_colors.is_empty():
		return
	var out := PackedColorArray()
	out.resize(vertex_map.size())
	for i in vertex_map.size():
		out[i] = get_vertex_color(vertex_map[i]) if vertex_map[i] >= 0 else Color.WHITE
	vertex_colors = out


func get_face_texture(face: int) -> int:
	return face_textures[face] if face < face_textures.size() else -1


func get_face_surface(face: int) -> int:
	return face_surfaces[face] if face < face_surfaces.size() else 0


func is_fence() -> bool:
	return fence_style != null


func is_rope() -> bool:
	return rope_style != null


## A fence's or rope's points / open sections / whether it loops (the point editor's view).
func path_points() -> PackedVector3Array:
	return rope_points if is_rope() else fence_points


func path_open() -> PackedInt32Array:
	return rope_open if is_rope() else fence_open


func path_closed() -> bool:
	return fence_closed and not is_rope()


## Property names behind path_points() / path_open() (undo).
func path_properties() -> Array[StringName]:
	return [&"rope_points", &"rope_open"] if is_rope() else [&"fence_points", &"fence_open"]


func is_passage() -> bool:
	return passage != null


func is_door() -> bool:
	return door != null


## The passage's or door's spec (the wall opening it cuts), or null.
func opening_spec() -> OpeningSpec:
	return passage if passage else door


func _on_passage_changed() -> void:
	passage_dirty = true
	emit_changed()


func _on_fence_changed() -> void:
	fence_dirty = true
	emit_changed()


func _on_rope_changed() -> void:
	rope_dirty = true
	emit_changed()


## Face `f` drawn / collided (brush bake_mode with face_bake on top).
## face_bake 3: pick only (door brushes' panel box): neither drawn, collided nor occluding.
func face_pick_only(f: int) -> bool:
	return f < face_bake.size() and face_bake[f] == 3


func face_visual(f: int) -> bool:
	var o := face_bake[f] if f < face_bake.size() else 0
	return o == 1 or (o == 0 and bake_mode != BakeMode.COLLISION_ONLY)


func face_collides(f: int) -> bool:
	var o := face_bake[f] if f < face_bake.size() else 0
	return o == 2 or (o == 0 and bake_mode != BakeMode.VISUAL_ONLY)


func has_corner_uvs() -> bool:
	return not corner_uvs.is_empty() and corner_uvs.size() == face_indices.size()


func get_face_piece(face: int) -> int:
	return face_pieces[face] if face < face_pieces.size() else 0


## After a cut (map[new] = old face): faces that came from the same old face share a piece
## id (the old face's own, or a new one).
func mark_pieces(map: PackedInt32Array) -> void:
	var count := {}
	for old in map:
		count[old] = count.get(old, 0) + 1
	var next := 1
	for p in face_pieces:
		next = maxi(next, p + 1)
	var ids := {}
	var out := PackedInt32Array()
	out.resize(map.size())
	for f in map.size():
		var old := map[f]
		var id := get_face_piece(f)
		if old >= 0 and count[old] > 1 and id == 0:
			if not ids.has(old):
				ids[old] = next
				next += 1
			id = ids[old]
		out[f] = id
	face_pieces = out


## Merges edge-adjacent coplanar faces among `faces` that match in texture, UV (with its
## overlay turn), surface and overlay set (`pieces_only`: and are pieces of one cut face).
## Painted masks are rebuilt for the merged faces from their parts; corner colours follow.
## `density`: mask texels per metre. Returns map[new face] = old face (its first part), or
## an empty array when nothing merged.
func merge_faces(faces: Array, density: float, pieces_only := false) -> PackedInt32Array:
	var chosen := {}
	for f in faces:
		if f < get_face_count() and (not pieces_only or get_face_piece(f) != 0):
			chosen[f] = true
	if chosen.size() < 2:
		return PackedInt32Array()
	var polys: Array[PackedInt32Array] = []
	var compat := []
	for f in get_face_count():
		polys.append(get_face_vertex_ids(f))
		# Pieces: their overlay turns came from the border being undone, so they don't count.
		var tweak := get_face_uv(f)
		if pieces_only:
			tweak.w = fposmod(tweak.w, 360.0)
		compat.append([get_face_texture(f), tweak, get_face_surface(f), get_face_layer_set(f),
			get_face_piece(f) if pieces_only else 0] if chosen.has(f) else ["keep", f])
	var r := BrushOps.merge_coplanar(vertices, polys, compat)
	if r.faces.size() == polys.size():
		return PackedInt32Array()
	# Parts' outlines and masks before the faces change.
	var old_poly := {}
	var old_rect := {}
	var old_masks := {}
	for m: Array in r.members:
		if m.size() < 2:
			continue
		for f: int in m:
			var n := get_face_normal(f)
			var pts := PackedVector2Array()
			for p in get_face_points(f):
				pts.append(PolyUtil.planar_uv(p, n))
			old_poly[f] = pts
			old_rect[f] = get_face_planar_rect(f)
			for layer in LevelData.MAX_LAYERS:
				var img: Image = face_masks.get(Vector2i(f, layer))
				if img:
					old_masks[Vector2i(f, layer)] = img
	var map := PackedInt32Array()
	for m: Array in r.members:
		map.append(m[0])
	var pieces := face_pieces.duplicate()
	hand_edited = true
	set_faces(r.faces)
	remap_faces(map)
	# Merged faces: masks resampled from whichever part covers each texel; whole again.
	var masks := face_masks.duplicate()
	var out_pieces := face_pieces.duplicate()
	for i in r.members.size():
		var m: Array = r.members[i]
		if m.size() < 2:
			continue
		if i < out_pieces.size():
			out_pieces[i] = 0
		var layers := {}
		for key: Vector2i in old_masks:
			if m.has(key.x):
				layers[key.y] = true
		var n := get_face_normal(i)
		var rect := get_face_planar_rect(i)
		var size := get_face_mask_size(i, density)
		for layer: int in layers:
			var img := Image.create(size.x, size.y, false, Image.FORMAT_L8)
			for y in size.y:
				for x in size.x:
					var uv := rect.position + (Vector2(x, y) + Vector2(0.5, 0.5)) / Vector2(size) * rect.size
					for f: int in m:
						if not old_poly.has(f) or not Geometry2D.is_point_in_polygon(uv, old_poly[f]):
							continue
						var src: Image = old_masks.get(Vector2i(f, layer))
						if src:
							var orect: Rect2 = old_rect[f]
							var t := ((uv - orect.position) / orect.size.max(Vector2(0.0001, 0.0001)) * Vector2(src.get_size())).floor()
							img.set_pixel(x, y, src.get_pixel(clampi(int(t.x), 0, src.get_width() - 1), clampi(int(t.y), 0, src.get_height() - 1)))
						break
			masks[Vector2i(i, layer)] = img
	face_masks = masks
	face_pieces = out_pieces if not pieces.is_empty() else PackedInt32Array()
	if pieces_only:
		var merged := []
		for i in r.members.size():
			if r.members[i].size() > 1:
				merged.append(i)
		var zero := []
		zero.resize(merged.size())
		zero.fill(0)
		face_uv = with_overlay_codes(merged, zero)
	return map


func get_face_layer_set(face: int) -> int:
	return face_layer_sets[face] if face < face_layer_sets.size() else 0


## face_layer_sets with `faces` set to `value` (for undoable assignment).
func with_face_layer_sets(faces: Array, value: int) -> PackedInt32Array:
	var out := face_layer_sets.duplicate()
	if out.size() < face_counts.size():
		out.resize(face_counts.size())
	for f in faces:
		out[f] = value
	return out


## face_surfaces with `faces` set to `value` (for undoable assignment).
func with_face_surfaces(faces: Array, value: int) -> PackedInt32Array:
	var out := face_surfaces.duplicate()
	if out.size() < face_counts.size():
		out.resize(face_counts.size())
	for f in faces:
		out[f] = value
	return out


func get_face_uv(face: int) -> Vector4:
	return face_uv[face] if face < face_uv.size() else DEFAULT_UV


## Overlay code of a face: how its overlay textures sit on top of the base's projection.
## turns (0-3, code % 4): quarter turns (bricks along a border running the other way);
## frame (code / 4): index into LevelData.overlay_offsets / overlay_angles (0 = none), a
## free rotation and shift after the turn
## that lines the texture up with a border's edge. Stored in the face UV's rotation as whole
## extra turns (rotation + 360 * code), so the base angle is unchanged and the value follows
## the face wherever face_uv does (extrude, undo, Blender).
static func uv_overlay_code(tweak: Vector4) -> int:
	return maxi(floori(tweak.w / 360.0 + 0.001), 0)


static func uv_overlay_turns(tweak: Vector4) -> int:
	return uv_overlay_code(tweak) % 4


func get_face_overlay_code(face: int) -> int:
	return uv_overlay_code(get_face_uv(face))


func get_face_overlay_turns(face: int) -> int:
	return uv_overlay_turns(get_face_uv(face))


## face_uv with `faces` given overlay `codes` (turns + 4 * frame; base rotation kept).
func with_overlay_codes(faces: Array, codes: Array) -> PackedVector4Array:
	var out := face_uv.duplicate()
	for i in faces.size():
		var f: int = faces[i]
		while out.size() <= f:
			out.append(DEFAULT_UV)
		var t := out[f]
		out[f] = Vector4(t.x, t.y, t.z, fposmod(t.w, 360.0) + 360.0 * maxi(codes[i], 0))
	return out


## face_uv with `faces` given `turns` overlay quarter turns (their frames kept).
func with_overlay_turns(faces: Array, turns: Array) -> PackedVector4Array:
	var codes := []
	for i in faces.size():
		codes.append(get_face_overlay_code(faces[i]) / 4 * 4 + posmod(turns[i], 4))
	return with_overlay_codes(faces, codes)


## face_textures with `faces` set to `texture_id` (for undoable assignment).
func with_face_textures(faces: Array, texture_id: int) -> PackedInt32Array:
	var out := face_textures.duplicate()
	if out.size() < face_counts.size():
		var old := out.size()
		out.resize(face_counts.size())
		for i in range(old, out.size()):
			out[i] = -1
	for f in faces:
		out[f] = texture_id
	return out


func get_face_normal(face: int) -> Vector3:
	_ensure_cache()
	return _face_normals[face]


## Smooth per-vertex normals (area-weighted average of the faces sharing each vertex).
func get_vertex_normals() -> PackedVector3Array:
	_ensure_cache()
	if _vertex_normals.size() != vertices.size():
		_vertex_normals.resize(vertices.size())
		_vertex_normals.fill(Vector3.ZERO)
		for f in face_counts.size():
			var ids := get_face_vertex_ids(f)
			var pts := get_face_points(f)
			# Unnormalised Newell normal ~ face area * normal.
			var weighted := Vector3.ZERO
			for k in pts.size():
				var a := pts[k]
				var b := pts[(k + 1) % pts.size()]
				weighted += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
			for i in ids:
				_vertex_normals[i] += weighted
		for i in _vertex_normals.size():
			_vertex_normals[i] = _vertex_normals[i].normalized()
	return _vertex_normals


## Per-corner normals of `face` (same order as its vertices), each averaging only the
## faces around that vertex within `smooth_angle` of this face: a floor meeting a wall at
## 90° keeps a straight-up normal, while gentle slopes still blend.
func get_corner_normals(face: int, smooth_angle := 50.0) -> PackedVector3Array:
	var limit := cos(deg_to_rad(smooth_angle))
	var nf := get_face_normal(face)
	var vf := get_vertex_faces()
	var out := PackedVector3Array()
	for i in get_face_vertex_ids(face):
		var sum := Vector3.ZERO
		for g in vf[i]:
			var ng := get_face_normal(g)
			if ng.dot(nf) >= limit:
				# Weight by area like get_vertex_normals (Newell length ~ area).
				sum += ng * PolyUtil.newell_normal(get_face_points(g)).length()
		out.append(sum.normalized() if sum.length_squared() > 1e-12 else nf)
	return out


## Bounds of the face in its world-aligned planar projection (metres, brush-local).
func get_face_planar_rect(face: int) -> Rect2:
	_ensure_cache()
	return _face_rects[face]


func face_has_mask(face: int) -> bool:
	return _masked_faces.has(face)


func get_face_mask(face: int, layer: int) -> Image:
	return face_masks.get(Vector2i(face, layer))


## Mask size for a face: matches any existing layer mask, else from bounds * density.
func get_face_mask_size(face: int, density := 16.0) -> Vector2i:
	# Direct lookups (not a scan of every mask: the atlas asks this for each masked face).
	if _masked_faces.has(face):
		for layer in LevelData.MAX_LAYERS:
			var img: Image = face_masks.get(Vector2i(face, layer))
			if img:
				return img.get_size()
	var r := get_face_planar_rect(face).size * density
	return Vector2i(clampi(ceili(r.x), 4, 256), clampi(ceili(r.y), 4, 256))


## Replaces (or with null removes) one mask. `notify` false skips the rebuild signal,
## for live painting where the LevelRoot updates its atlas directly.
func set_face_mask(face: int, layer: int, image: Image, notify := true) -> void:
	var d := face_masks.duplicate()
	if image:
		d[Vector2i(face, layer)] = image
	else:
		d.erase(Vector2i(face, layer))
	set_block_signals(not notify)
	face_masks = d
	set_block_signals(false)


func masked_faces() -> Array:
	return _masked_faces.keys()


## Reorders per-face paint after a topology change: new face i takes old face map[i]
## (-1 = fresh face with defaults). With `masks_follow` false, only faces that kept their
## index keep masks (extruded side faces inherit texture/UVs but start unpainted).
func remap_faces(map: PackedInt32Array, masks_follow := true) -> void:
	var tex := PackedInt32Array()
	var uv := PackedVector4Array()
	var surf := PackedInt32Array()
	var sets := PackedInt32Array()
	var pieces := PackedInt32Array()
	var masks := {}
	for i in map.size():
		var old := map[i]
		pieces.append(get_face_piece(old) if old >= 0 else 0)
		tex.append(get_face_texture(old) if old >= 0 else -1)
		surf.append(get_face_surface(old) if old >= 0 else 0)
		sets.append(get_face_layer_set(old) if old >= 0 else 0)
		uv.append(get_face_uv(old) if old >= 0 else DEFAULT_UV)
		if old >= 0 and (masks_follow or old == i) and _masked_faces.has(old):
			for layer in LevelData.MAX_LAYERS:
				var img: Image = face_masks.get(Vector2i(old, layer))
				if img:
					masks[Vector2i(i, layer)] = img
	face_textures = tex
	face_uv = uv
	face_masks = masks
	face_surfaces = surf if not face_surfaces.is_empty() else PackedInt32Array()
	face_layer_sets = sets if not face_layer_sets.is_empty() else PackedInt32Array()
	face_pieces = pieces if not face_pieces.is_empty() else PackedInt32Array()
	corner_uvs = PackedVector2Array()  # exact UVs belong to the old faces
	if not face_ids.is_empty():
		var ids := PackedInt32Array()
		for old in map:
			ids.append(face_ids[old] if old >= 0 and old < face_ids.size() else 0)
		face_ids = ids


## Surface keys from STAIR_KEY up: one run of coplanar faces painted with the same
## N64StairTexture (each run gets its own material carrying its step frame).
const STAIR_KEY := 1 << 30


## Step frames for faces painted with stair textures (`stairs`: LevelData.stair_textures()).
## Coplanar faces with the same stair texture share one run, so a segmented ramp still
## gets one flight. Returns {faces: {face: run}, runs: [{texture, frame}]}.
func stair_runs(stairs: Dictionary) -> Dictionary:
	var faces := {}
	var runs := []
	if stairs.is_empty():
		return {faces = faces, runs = runs}
	_ensure_cache()
	var planes := {}
	for f in get_face_count():
		var tex := get_face_texture(f)
		if not stairs.has(tex):
			continue
		var n := _face_normals[f]
		var key := [tex, n.snappedf(0.001), snappedf(n.dot(vertices[face_indices[_face_starts[f]]]), 0.001)]
		if not planes.has(key):
			planes[key] = {faces = [], pts = PackedVector3Array(), n = n, tex = tex}
		planes[key].faces.append(f)
		planes[key].pts.append_array(get_face_points(f))
	for key in planes:
		var pl: Dictionary = planes[key]
		var stair: N64StairTexture = stairs[pl.tex]
		for f in pl.faces:
			faces[f] = runs.size()
		runs.append({texture = pl.tex, frame = N64StairTexture.frame(pl.pts, pl.n, stair.length_per_repeat())})
	return {faces = faces, runs = runs}


## UV in metres for a brush-local point on a face: world-aligned projection + face tweak.
static func tweaked_uv(p: Vector3, n: Vector3, tweak: Vector4) -> Vector2:
	var uv := slope_uv(p, n) if uv_follows_slope(tweak) else PolyUtil.planar_uv(p, n)
	if tweak.w != 0.0:
		uv = uv.rotated(deg_to_rad(tweak.w))
	return uv / uv_scale(tweak) + Vector2(tweak.x, tweak.y)


## `tweak` turned and shifted so the texture's rows run along edge a→b (local points) and
## start on it (texture origin at a), the image's top pointing from `foot` (on the edge
## line) toward `inside` (`flip`: away). Scale and follow-slope kept; the overlay code is
## cleared, so overlays (a border's turn / slant) line up with the same edge. null when the
## edge runs along the face normal.
static func uv_aligned_to_edge(tweak: Vector4, n: Vector3, a: Vector3, b: Vector3, foot: Vector3, inside: Vector3,
		flip: bool) -> Variant:
	var slope := uv_follows_slope(tweak)
	var ua := slope_uv(a, n) if slope else PolyUtil.planar_uv(a, n)
	var along := (slope_uv(b, n) if slope else PolyUtil.planar_uv(b, n)) - ua
	if along.length_squared() < 1e-10:
		return null
	var theta := -along.angle()
	var into := ((slope_uv(inside, n) - slope_uv(foot, n)) if slope
		else (PolyUtil.planar_uv(inside, n) - PolyUtil.planar_uv(foot, n))).rotated(theta)
	if (into.y > 0.0) != flip:
		theta += PI
	var off := -ua.rotated(theta) / uv_scale(tweak)
	return Vector4(off.x, off.y, tweak.z, fposmod(rad_to_deg(theta), 360.0))


## Face UV tweak scale (its sign is the follow-slope flag).
static func uv_scale(tweak: Vector4) -> float:
	return maxf(absf(tweak.z), 0.001)


## Follow slope (stored as a negative scale): the base texture lies on the face's own
## plane instead of being projected along the nearest axis, so a ramp shows it unstretched
## with rows level across the slope. Axis-aligned faces look the same either way.
static func uv_follows_slope(tweak: Vector4) -> bool:
	return tweak.z < 0.0


## Planar UV on the face's own plane: PolyUtil.planar_uv's axes laid onto the plane (u
## level, v up / down the slope), true lengths. Equals planar_uv on axis-aligned faces.
static func slope_uv(p: Vector3, n: Vector3) -> Vector2:
	n = n.normalized()
	var a := n.abs()
	var u0 := Vector3(1, 0, 0)
	var v0 := Vector3(0, 0, 1)
	if not (a.y >= a.x and a.y >= a.z):
		u0 = Vector3(0, 0, -signf(n.x)) if a.x >= a.z else Vector3(signf(n.z), 0, 0)
		v0 = Vector3(0, -1, 0)
	var eu := u0 - n * n.dot(u0)
	if eu.length_squared() < 1e-8:
		return Vector2(p.dot(u0), p.dot(v0))
	eu = eu.normalized()
	var ev := n.cross(eu)
	if ev.dot(v0) < 0.0:
		ev = -ev
	return Vector2(p.dot(eu), p.dot(ev))


func get_face_count() -> int:
	return face_counts.size()


func get_face_vertex_ids(face: int) -> PackedInt32Array:
	_ensure_cache()
	var start := _face_starts[face]
	return face_indices.slice(start, start + face_counts[face])


func get_face_points(face: int) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for i in get_face_vertex_ids(face):
		pts.append(vertices[i])
	return pts


## Unique undirected edges as Vector2i(min, max).
func get_edges() -> Array[Vector2i]:
	_ensure_cache()
	return _edges


func local_aabb() -> AABB:
	if vertices.is_empty():
		return AABB()
	var box := AABB(vertices[0], Vector3.ZERO)
	for v in vertices:
		box = box.expand(v)
	return box


## Box used by resize handles: generator box while parametric, vertex bounds once edited.
func resize_box() -> AABB:
	# Passages / doors resize their opening (the trim around it follows).
	if passage:
		return AABB(Vector3(-passage.width * 0.5, 0, -passage.depth), Vector3(passage.width, passage.height, passage.depth))
	if door:
		var d := maxf(door.wall_depth, door.thickness)
		return AABB(Vector3(-door.width * 0.5, 0, door.wall_center_z - d * 0.5), Vector3(door.width, door.height, d))
	if hand_edited:
		return local_aabb()
	return AABB(Vector3(-size.x * 0.5, 0, -size.z * 0.5), size)


func bake_hash() -> int:
	return hash([transform, vertices, face_indices, face_counts, material, bake_mode, stairs_collision_ramp,
		face_textures, face_uv, face_masks, face_surfaces, face_layer_sets, face_pieces, corner_uvs, cutout, face_bake, vertex_colors, vertex_ao, corner_lighting, corner_lighting_keys, _resolved_corners()])


## Flat-shaded, unoptimised editor mesh.
func build_mesh() -> ArrayMesh:
	_ensure_cache()
	if _tri_faces.is_empty():
		return null
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	for t in _tri_faces.size():
		var n := _face_normals[_tri_faces[t]]
		# Our polygons are CCW; Godot front faces are clockwise.
		for k: int in [0, 2, 1]:
			var p := vertices[_tri_indices[t * 3 + k]]
			pos.append(p)
			nrm.append(n)
			uv.append(PolyUtil.planar_uv(p, n))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TEX_UV] = uv
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Surface key of a face: base texture id (>= 0), -1 neutral paint, -2 brush `material`.
## Faces of another overlay set (face_layer_sets) get their own keys: see with_set; cutout
## brushes too (with_cutout).
func get_surface_key(face: int) -> int:
	var tex := get_face_texture(face)
	if tex < 0 and material:
		return -2
	return with_cutout(with_set(surface_key(tex, get_face_overlay_code(face)), get_face_layer_set(face)), cutout)


## Surface keys below STAIR_KEY: the palette texture (-1 = none), plus TURN_KEY steps per
## overlay code for faces whose overlays are turned / shifted (their own material).
const TURN_KEY := 1 << 16


static func surface_key(tex: int, code: int) -> int:
	return tex if code == 0 else TURN_KEY * code + tex + 1


static func key_texture(key: int) -> int:
	key = key_base(key)
	return key if key < TURN_KEY else key % TURN_KEY - 1


static func key_overlay(key: int) -> int:
	key = key_base(key)
	return 0 if key < TURN_KEY else key / TURN_KEY


## Overlay set steps above every other key (64-bit): key + 2 (keys start at -2) plus
## SET_KEY per set. Set 0 leaves the key as it was.
const SET_KEY := 1 << 32


static func with_set(key: int, layer_set: int) -> int:
	return key if layer_set <= 0 else SET_KEY * layer_set + key + 2


static func key_set(key: int) -> int:
	key = key_uncut(key)
	return key / SET_KEY if key >= SET_KEY else 0


## The key without its overlay set and cutout (texture, overlay code or stair run).
static func key_base(key: int) -> int:
	key = key_uncut(key)
	return key % SET_KEY - 2 if key >= SET_KEY else key


## Faces not drawn (collision only): left out of the editor mesh.
const HIDDEN_KEY := -1000

## Cutout brushes' keys sit above every other (their own materials, cutout shader).
const CUT_KEY := 1 << 50


static func with_cutout(key: int, on: bool) -> int:
	return CUT_KEY + key + 2 if on else key


static func key_cutout(key: int) -> bool:
	return key >= CUT_KEY


static func key_uncut(key: int) -> int:
	return key - CUT_KEY - 2 if key >= CUT_KEY else key


## Editor mesh with world-aligned UVs (+ face tweaks), atlas UV2 for painted masks and
## one surface per surface key. Returns {mesh: ArrayMesh or null, keys: Array[int]}.
## `baked`: apply corner_lighting (Baked Vertex mode only; other modes keep any stored
## bake but ignore it, so switching back to Dynamic doesn't double-light).
## `hybrid` (Baked Vertex Dynamic): corner_lighting goes in CUSTOM0, apart from the painted
## colours that live lights also use.
## `color_scale`: the level's vertex colour scale (LevelData.vertex_color_scale()); colours
## go into the mesh divided by it (mesh colours are 8-bit, so 2× keeps headroom to brighten).
## `face_from` / `face_to` (-1 = the end): only those faces (a chunk of a big brush).
func build_painted_mesh(atlas: Dictionary, brush_index: int, timed := false, baked := false, stairs := {}, hybrid := false,
		color_scale := 1.0, face_from := 0, face_to := -1) -> Dictionary:
	_ensure_cache()
	if _tri_faces.is_empty():
		return {mesh = null, keys = []}
	var stair := stair_runs(stairs)
	var tri_count := _tri_faces.size()
	# Triangles are stored in face order: the range's triangles are one run.
	var t_from := _tri_faces.bsearch(face_from) if face_from > 0 else 0
	var t_to := _tri_faces.bsearch(face_to) if face_to >= 0 else tri_count
	if t_from >= t_to:
		return {mesh = null, keys = [], stair_runs = stair.runs}
	# Surface key per triangle, and the keys in first-seen order.
	var tri_key := PackedInt64Array()
	tri_key.resize(tri_count)
	var keys: Array[int] = []
	var key_count := {}
	for t in range(t_from, t_to):
		var f := _tri_faces[t]
		if not face_bake.is_empty() and not face_visual(f):
			tri_key[t] = HIDDEN_KEY
			continue
		var key: int = with_cutout(with_set(STAIR_KEY + stair.faces[f], get_face_layer_set(f)), cutout) if stair.faces.has(f) \
			else get_surface_key(f)
		tri_key[t] = key
		if not key_count.has(key):
			key_count[key] = 0
			keys.append(key)
		key_count[key] += 1
	# Per-brush data read once (this loop runs for every corner of every triangle).
	var cc := _resolved_corners()
	var cc_ok := cc.size() == face_indices.size()
	var vcol := vertex_colors
	var ao := vertex_ao
	var light := corner_lighting
	var light_ok := light.size() == face_indices.size()
	var key_lights: Array[PackedColorArray] = []
	for s in 4:
		var arr: PackedColorArray = corner_lighting_keys[s] if s < corner_lighting_keys.size() else PackedColorArray()
		key_lights.append(arr if arr.size() == face_indices.size() else PackedColorArray())
	var keyed := timed or hybrid
	var inv_scale := 1.0 / color_scale
	var atlas_size := Vector2(atlas.size)
	var empty := PaintAtlas.empty_uv(atlas.size)
	var mesh := ArrayMesh.new()
	for key in keys:
		var n_verts: int = key_count[key] * 3
		var pos := PackedVector3Array()
		pos.resize(n_verts)
		var nrm := PackedVector3Array()
		nrm.resize(n_verts)
		var uv := PackedVector2Array()
		uv.resize(n_verts)
		var uv2 := PackedVector2Array()
		uv2.resize(n_verts)
		var col := PackedColorArray()
		col.resize(n_verts)
		var kb: Array[PackedByteArray] = []
		if keyed:
			for s in 4:
				var b := PackedByteArray()
				b.resize(n_verts * 4)
				kb.append(b)
		var w := 0
		for t in range(t_from, t_to):
			if tri_key[t] != key:
				continue
			var f := _tri_faces[t]
			var n := _face_normals[f]
			var tweak := get_face_uv(f)
			var rot := deg_to_rad(tweak.w)
			var inv_zoom := 1.0 / uv_scale(tweak)
			var on_slope := uv_follows_slope(tweak)
			var exact := has_corner_uvs()
			var chart = atlas.rects.get(Vector2i(brush_index, f)) if face_has_mask(f) else null
			var rect := _face_rects[f]
			var rect_size := rect.size.max(Vector2(0.0001, 0.0001))
			# Our polygons are CCW; Godot front faces are clockwise.
			for k: int in [0, 2, 1]:
				var vi := _tri_indices[t * 3 + k]
				var corner := _tri_corners[t * 3 + k]
				var p := vertices[vi]
				pos[w] = p
				nrm[w] = n
				# Painted colour (rgb) and baked AO (alpha), as get_corner_shade().
				var c: Color = cc[corner] if cc_ok else (vcol[vi] if vi < vcol.size() else Color.WHITE)
				c.a = ao[vi] if vi < ao.size() else 1.0
				if hybrid:
					_put_rgba8(kb[0], w, light[corner] if light_ok else Color.WHITE)
					for s in range(1, 4):
						_put_rgba8(kb[s], w, Color.WHITE)
				elif timed:
					for s in 4:
						_put_rgba8(kb[s], w, key_lights[s][corner] if not key_lights[s].is_empty() else Color.WHITE)
				elif baked and light_ok:
					c *= light[corner]
				col[w] = Color(clampf(c.r * inv_scale, 0.0, 1.0), clampf(c.g * inv_scale, 0.0, 1.0), clampf(c.b * inv_scale, 0.0, 1.0), c.a)
				var planar := PolyUtil.planar_uv(p, n)
				var base_uv := slope_uv(p, n) if on_slope else planar
				uv[w] = corner_uvs[corner] if exact else (base_uv.rotated(rot) if rot != 0.0 else base_uv) * inv_zoom + Vector2(tweak.x, tweak.y)
				if chart != null:
					var tt := (planar - rect.position) / rect_size
					uv2[w] = (Vector2(chart.position) + tt * Vector2(chart.size)) / atlas_size
				else:
					uv2[w] = empty
				w += 1
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pos
		arrays[Mesh.ARRAY_NORMAL] = nrm
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		arrays[Mesh.ARRAY_COLOR] = col
		var flags := 0
		if keyed:
			for s in 4:
				arrays[Mesh.ARRAY_CUSTOM0 + s] = kb[s]
			flags = KEY_FORMAT
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	return {mesh = mesh, keys = keys, stair_runs = stair.runs}


## RGBA8 of `c` (alpha 255) at vertex `i` of a pre-sized custom channel.
static func _put_rgba8(bytes: PackedByteArray, i: int, c: Color) -> void:
	bytes[i * 4] = clampi(roundi(c.r * 255.0), 0, 255)
	bytes[i * 4 + 1] = clampi(roundi(c.g * 255.0), 0, 255)
	bytes[i * 4 + 2] = clampi(roundi(c.b * 255.0), 0, 255)
	bytes[i * 4 + 3] = 255


## Ray test in brush-local space, front faces only.
## Returns {face, position, normal, distance} (local) or {}.
func raycast_local(from: Vector3, dir: Vector3, both_sides := false) -> Dictionary:
	_ensure_cache()
	var best := {}
	var best_t := INF
	for t in _tri_faces.size():
		var a := vertices[_tri_indices[t * 3]]
		var b := vertices[_tri_indices[t * 3 + 1]]
		var c := vertices[_tri_indices[t * 3 + 2]]
		var n := (b - a).cross(c - a)
		if n.dot(dir) >= 0.0 and not both_sides:
			continue
		var hit = Geometry3D.ray_intersects_triangle(from, dir, a, b, c)
		if hit == null:
			continue
		var dist: float = (hit - from).dot(dir) / dir.length_squared()
		if dist < best_t:
			best_t = dist
			best = {face = _tri_faces[t], position = hit, normal = n.normalized(), distance = dist}
	return best


func _on_shape_params_changed() -> void:
	# Skip while loading (geometry not set yet) and once vertices are hand-edited.
	if face_counts.is_empty() or hand_edited:
		emit_changed()
		return
	generate_from_shape()


func _on_geometry_changed() -> void:
	_cache_valid = false
	emit_changed()


func _ensure_cache() -> void:
	if _cache_valid:
		return
	if _positions_only and _refresh_positions():
		return
	_positions_only = false
	_cache_valid = true
	_face_starts.resize(face_counts.size())
	_face_normals.resize(face_counts.size())
	_face_rects.resize(face_counts.size())
	_tri_indices.clear()
	_tri_faces.clear()
	_tri_corners.clear()
	_edges.clear()
	_vertex_normals.clear()
	_vertex_faces.clear()
	var s := 0
	for f in face_counts.size():
		_face_starts[f] = s
		s += face_counts[f]
	if s > face_indices.size():
		push_error("LevelBrush: face data is corrupt.")
		face_counts = PackedInt32Array()
		return

	var seen := {}
	for f in face_counts.size():
		var ids := face_indices.slice(_face_starts[f], _face_starts[f] + face_counts[f])
		var pts := PackedVector3Array()
		for i in ids:
			pts.append(vertices[i] if i < vertices.size() else Vector3.ZERO)
		for k in ids.size():
			var a := ids[k]
			var b := ids[(k + 1) % ids.size()]
			var e := Vector2i(mini(a, b), maxi(a, b))
			if not seen.has(e):
				seen[e] = true
				_edges.append(e)
		var n := PolyUtil.newell_normal(pts)
		_face_normals[f] = n
		var rect := Rect2()
		for k in pts.size():
			var uv := PolyUtil.planar_uv(pts[k], n)
			rect = Rect2(uv, Vector2.ZERO) if k == 0 else rect.expand(uv)
		_face_rects[f] = rect
		if n == Vector3.ZERO:
			continue
		var tris := PolyUtil.triangulate(pts, n)
		for t in range(0, tris.size(), 3):
			for k in 3:
				_tri_indices.append(ids[tris[t + k]])
				_tri_corners.append(_face_starts[f] + tris[t + k])
			_tri_faces.append(f)


## Positions moved, faces didn't: new normals and planar bounds, same triangles / edges.
## False (full rebuild needed) when a face became or stopped being degenerate.
func _refresh_positions() -> bool:
	_positions_only = false
	if _face_normals.size() != face_counts.size():
		return false
	for f in face_counts.size():
		var start := _face_starts[f]
		var pts := PackedVector3Array()
		pts.resize(face_counts[f])
		for k in face_counts[f]:
			var i := face_indices[start + k]
			pts[k] = vertices[i] if i < vertices.size() else Vector3.ZERO
		var n := PolyUtil.newell_normal(pts)
		if (n == Vector3.ZERO) != (_face_normals[f] == Vector3.ZERO):
			return false
		_face_normals[f] = n
		var rect := Rect2()
		for k in pts.size():
			var uv := PolyUtil.planar_uv(pts[k], n)
			rect = Rect2(uv, Vector2.ZERO) if k == 0 else rect.expand(uv)
		_face_rects[f] = rect
	_vertex_normals.clear()
	_cache_valid = true
	return true


func _rebuild_from_shape_pressed() -> void:
	var b := BrushShapes.build(shape, size, segments)
	var ur = Engine.get_singleton(&"EditorInterface").get_editor_undo_redo()
	ur.create_action("Rebuild Brush From Shape")
	for prop in [[&"vertices", b.verts, vertices], [&"face_indices", b.indices, face_indices],
			[&"face_counts", b.counts, face_counts], [&"hand_edited", false, hand_edited]]:
		ur.add_do_property(self, prop[0], prop[1])
		ur.add_undo_property(self, prop[0], prop[2])
	ur.commit_action()
