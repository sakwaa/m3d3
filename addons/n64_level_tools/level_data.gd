@tool
class_name LevelData
extends Resource
## All brushes of a level plus its baked output. Can live inline in a scene or as a
## standalone .tres/.res file shared between scenes.

signal brushes_changed
signal bake_changed
## Texture palette, overlay layers or paint settings changed.
signal paint_changed
## Paint settings that only change materials (palettes, tile sizes, variation, layer
## settings, bake strength): levels update their materials without rebuilding meshes.
signal materials_changed
## The scattered cut-outs (flowers, tufts) changed.
signal scatter_changed
## The grass (mat and tufts) settings changed.
signal grass_changed

const MAX_LAYERS := 4

## DYNAMIC: Godot lights shade the level. BAKED_VERTEX: N64 style — baked per-vertex
## lighting (LevelLighting), the level itself unlit; Godot lights still light actors.
## BAKED_TIMED: one bake per key of the project LightingSchedule, blended by time of day.
## BAKED_VERTEX_DYNAMIC / BAKED_TIMED_DYNAMIC: like Baked Vertex / Baked Timed, but only
## ambient, AO and lights set to Bake Mode Static are baked; every other light lights the
## level live on top — N64 shading that still reacts to the sun, torches, moving lights.
enum LightingMode { DYNAMIC, BAKED_VERTEX, BAKED_TIMED, BAKED_VERTEX_DYNAMIC, BAKED_TIMED_DYNAMIC }


## One bake per LightingSchedule key (Baked Timed, with or without live lights).
static func mode_is_timed(mode: LightingMode) -> bool:
	return mode == LightingMode.BAKED_TIMED or mode == LightingMode.BAKED_TIMED_DYNAMIC


## Bake plus live lights on top.
static func mode_is_hybrid(mode: LightingMode) -> bool:
	return mode == LightingMode.BAKED_VERTEX_DYNAMIC or mode == LightingMode.BAKED_TIMED_DYNAMIC

@export var brushes: Array[LevelBrush] = []:
	set(value):
		brushes = value
		brushes_changed.emit()

@export_group("Paint")
## Base textures used by faces (LevelBrush.face_textures indexes into this).
@export var textures: Array[Texture2D] = []:
	set(value):
		var old := textures
		textures = value
		# Appending (first use of a texture) or dropping the last ones again (its undo)
		# leaves every existing entry's index alone: meshes stay, only materials refresh.
		var n := mini(old.size(), value.size())
		if old.slice(0, n) == value.slice(0, n):
			materials_changed.emit()
		else:
			paint_changed.emit()
## Overlay layers, bottom to top (max 4). Masks are painted per face on the brushes.
@export var layers: Array[PaintLayer] = []:
	set(value):
		for layer in layers:
			if layer and layer.changed.is_connected(_on_layer_changed):
				layer.changed.disconnect(_on_layer_changed)
		layers = value
		for layer in layers:
			if layer and not layer.changed.is_connected(_on_layer_changed):
				layer.changed.connect(_on_layer_changed)
		paint_changed.emit()
## Name of the default overlay stack (`layers`, set 0) in the Paint panel.
@export var default_set_name := "Default"
## More overlay stacks (set 1, 2, …): a barrel's wood and metal, a stair's moss. Faces pick
## theirs with LevelBrush.face_layer_sets (0 = `layers`); mask slot i of a face shows its
## own set's layer i.
@export var layer_sets: Array[PaintLayerSet] = []:
	set(value):
		for ls in layer_sets:
			if ls and ls.changed.is_connected(_on_layer_changed):
				ls.changed.disconnect(_on_layer_changed)
				ls.layers_changed.disconnect(_on_set_layers_changed)
		layer_sets = value
		for ls in layer_sets:
			if ls and not ls.changed.is_connected(_on_layer_changed):
				ls.changed.connect(_on_layer_changed)
				ls.layers_changed.connect(_on_set_layers_changed)
		paint_changed.emit()
## Editor only: the overlay set the Paint panel shows and edits.
var edit_set := 0
## Border tool: width last painted per border (LevelPaintTool.border_key -> metres), so a
## new width replaces the old band and erasing removes all of it.
@export_storage var border_widths := {}
## Metres per repeat for base textures that aren't N64Textures (those carry world_size).
@export var base_tile_size := 1.0:
	set(value):
		base_tile_size = maxf(value, 0.01)
		materials_changed.emit()
## Overlay shifts (metres, after a face's overlay turn) that line overlay textures up with
## border edges; faces refer to them by index (LevelBrush overlay code frame; 0 = none).
@export_storage var overlay_offsets := PackedVector2Array([Vector2.ZERO]):
	set(value):
		overlay_offsets = value
		materials_changed.emit()
## Per overlay_offsets entry: a free rotation (radians, after the quarter turn, before the
## shift) laying the texture along a sloped / diagonal border edge. Missing = 0.
@export_storage var overlay_angles := PackedFloat32Array():
	set(value):
		overlay_angles = value
		materials_changed.emit()
## Per overlay_offsets entry: a linear map after the angle (columns x = (x, y), y = (z, w)),
## for borders continuing a neighbour's texture over an edge. Missing = identity.
@export_storage var overlay_bases := PackedVector4Array():
	set(value):
		overlay_bases = value
		materials_changed.emit()
## Per overlay_offsets entry: a stair continued over an edge, or null: {layer (overlay
## slot), texture (stair's index in `textures`), basis, offset (face UV -> stair UV)}.
@export_storage var overlay_stairs := []:
	set(value):
		overlay_stairs = value
		materials_changed.emit()


## Index of the frame (`offset`, `angle`) in the lists (mm / 1e-4 rad precision), appended
## to both if new. 0 = no shift, no angle.
static func overlay_frame_index(offsets: PackedVector2Array, angles: PackedFloat32Array, offset: Vector2, angle: float,
		bases := PackedVector4Array(), basis := IDENTITY_BASIS, stairs := [], stair: Variant = null) -> int:
	if offsets.is_empty():
		offsets.append(Vector2.ZERO)
	while angles.size() < offsets.size():
		angles.append(0.0)
	var o := offset.snappedf(0.001)
	var a := snappedf(angle, 0.0001)
	var m := basis.snappedf(0.0001)
	if stair != null:
		stair = {layer = stair.layer, texture = stair.texture, basis = (stair.basis as Vector4).snappedf(0.0001),
			offset = (stair.offset as Vector2).snappedf(0.0001)}
	if o.is_zero_approx() and is_zero_approx(a) and m.is_equal_approx(IDENTITY_BASIS) and stair == null:
		return 0
	for i in range(1, offsets.size()):
		var mi: Vector4 = bases[i] if i < bases.size() else IDENTITY_BASIS
		var si = stairs[i] if i < stairs.size() else null
		if offsets[i].is_equal_approx(o) and is_equal_approx(angles[i], a) and mi.is_equal_approx(m) and si == stair:
			return i
	offsets.append(o)
	angles.append(a)
	if stair != null or not stairs.is_empty():
		while stairs.size() < offsets.size() - 1:
			stairs.append(null)
		stairs.append(stair)
	if not m.is_equal_approx(IDENTITY_BASIS) or not bases.is_empty():
		while bases.size() < offsets.size() - 1:
			bases.append(IDENTITY_BASIS)
		bases.append(m)
	return offsets.size() - 1


const IDENTITY_BASIS := Vector4(1, 0, 0, 1)


## Per-level tile size for base textures: Texture2D -> metres per repeat. Overrides the
## texture's own size (world_size / Auto) in this level (set from the Paint panel's Tile size).
@export var base_tile_sizes := {}:
	set(value):
		base_tile_sizes = value
		materials_changed.emit()
## Per-level variation for base textures: Texture2D -> Vector3(strength, metres per noise
## repeat, mode 0 light & dark / 1 darken). Breaks up repetition with a shared noise.
@export var base_variation := {}:
	set(value):
		base_variation = value
		materials_changed.emit()
## Per-level palette for base textures: Texture2D -> PackedColorArray([dark, light]).
## Overrides the texture's own tint (e.g. darker grass in a dungeon zone).
@export var base_tints := {}:
	set(value):
		base_tints = value
		materials_changed.emit()
## Vertex colour range. 1×: texture × vertex colour (the N64's usual modulate combiner;
## colours only darken). 2×: texture × vertex colour × 2 (also an N64 combiner setup):
## painted colours go up to 2 (Brightness in the Paint panel), so tints can brighten.
## White leaves the texture unchanged in both; meshes store colours halved in 2×.
@export_enum("1× (modulate)", "2× (can brighten)") var vertex_color_range := 0:
	set(value):
		vertex_color_range = value
		paint_changed.emit()
## Scattered cut-outs (flowers, grass tufts): one set per texture / style / size.
@export var scatter: Array[ScatterSet] = []:
	set(value):
		for s in scatter:
			if s and s.changed.is_connected(_on_scatter_changed):
				s.changed.disconnect(_on_scatter_changed)
		scatter = value
		for s in scatter:
			if s and not s.changed.is_connected(_on_scatter_changed):
				s.changed.connect(_on_scatter_changed)
		scatter_changed.emit()
## Grass: a lumpy mat over the grass-textured ground with tufts in it (GrassSettings;
## empty or disabled = none). Rebuilt with the brushes.
@export var grass: GrassSettings:
	set(value):
		if grass and grass.changed.is_connected(_on_grass_changed):
			grass.changed.disconnect(_on_grass_changed)
		grass = value
		if grass and not grass.changed.is_connected(_on_grass_changed):
			grass.changed.connect(_on_grass_changed)
		grass_changed.emit()
## Ground finish: soft edges where grass meets dirt, ground piled up a little at the foot of
## buildings (GroundFinish). Taken off and put back with its buttons; never changes the
## ground for good.
@export var ground_finish: GroundFinish:
	set(value):
		ground_finish = value
		if ground_finish:
			ground_finish.level = weakref(self)
## Mask texels per metre for newly painted faces.
@export_range(2.0, 64.0) var mask_density := 16.0
@export_group("")

@export_group("Lighting")
@export var lighting_mode := LightingMode.BAKED_TIMED_DYNAMIC:
	set(value):
		lighting_mode = value
		paint_changed.emit()
## Ambient light from above / below (blended by surface direction).
@export var light_sky := Color(0.5, 0.55, 0.68)
@export var light_ground := Color(0.3, 0.27, 0.24)
## Ambient occlusion, shared by Bake AO (vertex AO, keeps real-time lighting) and the
## lighting bake: how dark fully enclosed corners / crevices get.
@export_range(0.0, 1.0) var light_ao_strength := 0.75
## Metres the occlusion rays reach: small = tight corner / edge lines, large = broad.
@export_range(0.1, 10.0) var light_ao_radius := 2.0
@export_range(4, 64) var light_ao_samples := 12
## Shadows from scene lights (one ray per light per vertex).
@export var light_shadows := true
## The bake lifts a sun / moon lower than this (degrees above the horizon) up to it, so
## dawn / dusk keys still light the ground and throw readable long shadows. Only the
## direction changes; key colours and hours are untouched. 0 = true angle.
@export_range(0.0, 60.0, 0.5, "suffix:°") var light_min_sun_elevation := 42.5
## Overall multiplier of the baked lighting (not used by Bake AO).
@export_range(0.0, 4.0) var light_intensity := 1.0
## Baked modes: how strongly baked shading darkens on screen. 0 = soft (linear),
## 1 = N64-style (half the light looks half as bright). Editor preview is live; Bake
## Level to apply in game (no re-light needed).
@export_range(0.0, 1.0, 0.05) var light_contrast := 1.0:
	set(value):
		light_contrast = value
		materials_changed.emit()
## Baked modes: the darkest the baked lighting gets on screen, as a fraction of a surface's
## fully lit look (its painted colour kept, tinted like the light). Lifts corners the AO
## and shadows would otherwise turn black; 0.2 is about Majora's Mask's darkest scenes.
## Editor preview is live; Bake Level to apply in game.
@export_range(0.0, 0.5, 0.01) var light_floor := 0.2:
	set(value):
		light_floor = value
		materials_changed.emit()
## Baked Vertex / Timed Dynamic: how much of the bake shows. 0 = none (plain Dynamic: the scene's own
## ambient / environment), 1 = full bake in place of the scene's ambient, above 1 brighter.
## Live lights are unaffected. Editor preview is live; Bake Level to apply in game.
@export_range(0.0, 2.0, 0.05) var light_bake_strength := 1.0:
	set(value):
		light_bake_strength = value
		materials_changed.emit()
@export_group("")

@export_storage var baked_mesh: ArrayMesh:
	set(value):
		baked_mesh = value
		bake_changed.emit()
## Big levels: the bake split into cells (baked_mesh is null then), so the camera culls
## the ones out of view.
@export_storage var baked_chunks: Array[ArrayMesh] = []:
	set(value):
		baked_chunks = value
		bake_changed.emit()
## Old bakes: one collision shape for everything (new bakes split it by surface below).
@export_storage var baked_collision: ConcavePolygonShape3D:
	set(value):
		baked_collision = value
		bake_changed.emit()
## Collision split by Surface (footstep sound | flags): one shape per surface.
@export_storage var baked_collision_parts: Array[ConcavePolygonShape3D] = []:
	set(value):
		baked_collision_parts = value
		bake_changed.emit()
@export_storage var baked_collision_surfaces := PackedInt32Array():
	set(value):
		baked_collision_surfaces = value
		bake_changed.emit()
@export_storage var bake_hash := 0
## The bake's rain cover (RainCover.build), kept until the bake changes (rain_cover_built()).
@export_storage var rain_cover_image: Image
@export_storage var rain_cover_area := Rect2()
@export_storage var rain_cover_range := Vector2(0.0, 1.0)
@export_storage var rain_cover_key := 0
## The light rain catches around the lamps (LevelLighting.bake_rain_light): XZ layers
## stacked by height (light / 2), the first point's level-local position, metres between
## points, and lamp strength per lighting key (Baked Timed; else 1).
## What's past the walls, from the zones next door (NeighbourBackdrop, baked with Bake):
## the near zones' flat-coloured mesh (level space), the far ring's painted strip and its
## layout (Backdrop.build_nodes).
@export_storage var backdrop_mesh: ArrayMesh
@export_storage var backdrop_ring: Texture2D
@export_storage var backdrop_ring_info := Vector4.ZERO
@export_storage var rain_light_image: Image
@export_storage var rain_light_origin := Vector3.ZERO
@export_storage var rain_light_cell := 1.0
@export_storage var rain_light_layers := 1
@export_storage var rain_light_keys := Vector4.ONE
@export_storage var bake_summary := ""


func add_brush(brush: LevelBrush, index := -1) -> void:
	var list := brushes.duplicate()
	if index < 0 or index > list.size():
		list.append(brush)
	else:
		list.insert(index, brush)
	brushes = list


func remove_brush(brush: LevelBrush) -> void:
	var list := brushes.duplicate()
	list.erase(brush)
	brushes = list


## Index of `texture` in the palette, or -1. See with_texture() to add one.
func texture_id(texture: Texture2D) -> int:
	return textures.find(texture)


## The palette with `texture` appended if missing (for undoable assignment).
func with_texture(texture: Texture2D) -> Array[Texture2D]:
	var list := textures.duplicate()
	if not texture in list:
		list.append(texture)
	return list


func paint_hash() -> int:
	var parts := [textures, base_tile_size, base_tile_sizes, base_tints, base_variation, lighting_mode, light_contrast, light_floor, light_bake_strength,
		vertex_color_range, overlay_offsets, overlay_angles, overlay_bases, overlay_stairs]
	for s in layer_set_count():
		parts.append(s)
		for layer in layers_of(s):
			if layer:
				parts.append([layer.texture, layer.blend, layer.opacity, layer.tile_size, layer.tint, layer.enabled,
					layer.override_tint, layer.tint_dark, layer.tint_light])
	return hash(parts)


## Overlay sets: 1 (the default `layers`) + layer_sets.
func layer_set_count() -> int:
	return 1 + layer_sets.size()


## Overlay layers of set `s` (0 or out of range = the default `layers`).
func layers_of(s: int) -> Array[PaintLayer]:
	if s <= 0 or s > layer_sets.size() or layer_sets[s - 1] == null:
		return layers
	return layer_sets[s - 1].layers


func layer_set_name(s: int) -> String:
	if s <= 0 or s > layer_sets.size() or layer_sets[s - 1] == null:
		return default_set_name
	return layer_sets[s - 1].name


## The set the Paint panel edits (edit_set, clamped).
func active_layers() -> Array[PaintLayer]:
	return layers_of(edit_set)


## Mask slots in use: the longest set's layer count (max MAX_LAYERS). One mask atlas each.
func mask_slot_count() -> int:
	var n := layers.size()
	for ls in layer_sets:
		if ls:
			n = maxi(n, ls.layers.size())
	return mini(n, MAX_LAYERS)


func _on_set_layers_changed() -> void:
	paint_changed.emit()


func _on_scatter_changed() -> void:
	scatter_changed.emit()


func _on_grass_changed() -> void:
	grass_changed.emit()


## What the shader multiplies vertex colour by (meshes store colour / this).
func vertex_color_scale() -> float:
	return 2.0 if vertex_color_range == 1 else 1.0


func _on_layer_changed() -> void:
	materials_changed.emit()


## Stair textures in use: {texture index: N64StairTexture}, for fitted step frames.
func stair_textures() -> Dictionary:
	var out := {}
	for i in textures.size():
		var t := textures[i] as N64StairTexture
		if t:
			out[i] = t
	return out


func has_bake() -> bool:
	return baked_mesh != null or not baked_chunks.is_empty() or baked_collision != null or not baked_collision_parts.is_empty()


## Changes whenever a face's Surface could (geometry, textures and their surfaces,
## overlay layers and masks, overrides): the editor's surface view rebuilds on it.
func surface_signature() -> int:
	var parts := [textures.map(func(t): return LevelSurfaces.texture_surface(t)),
		layers.map(func(l): return [l.texture, l.enabled, LevelSurfaces.texture_surface(l.texture)] if l else null)]
	for ls in layer_sets:
		if ls:
			parts.append(ls.layers.map(func(l): return [l.texture, l.enabled, LevelSurfaces.texture_surface(l.texture)] if l else null))
	for b in brushes:
		if b:
			parts.append([b.transform, b.vertices, b.face_counts, b.face_textures, b.face_surfaces, b.face_masks, b.face_layer_sets, b.bake_mode])
	return hash(parts)


## Baked collision as [parts, surfaces] (an old single-shape bake: one Default part).
func baked_collision_set() -> Array:
	if not baked_collision_parts.is_empty():
		return [baked_collision_parts, baked_collision_surfaces]
	if baked_collision:
		return [[baked_collision], PackedInt32Array([0])]
	return [[], PackedInt32Array()]


## Stores a LevelBaker result's collision (clearing an old single-shape one).
func set_baked_collision(result: Dictionary) -> void:
	baked_collision = null
	baked_collision_surfaces = result.collision_surfaces
	baked_collision_parts = result.collision_parts


## The rain cover of the current bake ({image, area, height_range}, empty without one): the
## stored one, or made (and stored) when the bake has changed since.
## The rain light grid for RainCover.from_build ({image, origin, cell, layers, keys}), or
## empty when the level has none (no lamps, or not lit since it was added).
func rain_light_built() -> Dictionary:
	if rain_light_image == null:
		return {}
	return {image = rain_light_image, origin = rain_light_origin, cell = rain_light_cell,
		layers = rain_light_layers, keys = rain_light_keys}


func rain_cover_built() -> Dictionary:
	var meshes := baked_meshes()
	if meshes.is_empty():
		return {}
	var count := 0
	for m in meshes:
		for s in m.get_surface_count():
			count += m.surface_get_array_len(s)
	var key := hash([bake_hash, meshes.size(), count, RainCover.CELL])
	if key != rain_cover_key or rain_cover_image == null:
		var built := RainCover.build(meshes)
		if built.is_empty():
			return {}
		rain_cover_image = built.image
		rain_cover_area = built.area
		rain_cover_range = built.height_range
		rain_cover_key = key
	return {image = rain_cover_image, area = rain_cover_area, height_range = rain_cover_range}


## The baked visual meshes: the chunks, or the single mesh.
func baked_meshes() -> Array[ArrayMesh]:
	if not baked_chunks.is_empty():
		return baked_chunks
	var out: Array[ArrayMesh] = []
	if baked_mesh:
		out.append(baked_mesh)
	return out
