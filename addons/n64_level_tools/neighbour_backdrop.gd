@tool
class_name NeighbourBackdrop
extends RefCounted
## Bakes what's past a level's walls from the zones next door, so they needn't be built
## twice. Each passage brush leads to a zone (target_zone) and arrives at its passage with
## the matching spawn id: the two are the same doorway, which lines the zone up with this
## one (their corridors' far ends meet). Every neighbour's level is read (not the scene's
## nodes: no props, NPCs, doors or windows), its larger faces kept as flat-coloured
## polygons (each face its texture's average colour, shaded by which way it faces) and
## anything that would land inside this level left out. What's within RING_MARGIN of this
## level's edge stays geometry (Backdrop mesh); what's further off is painted from the
## level's middle onto a ring of cards (Backdrop ring). Stored on the level data
## (backdrop_*), drawn by Backdrop.

## Faces smaller than this (m²) are left out: trim, sills, small details (walls, roofs
## and the ground stay).
const MIN_AREA := 1.5
## Further than this past the level's edge (metres): on the ring instead of geometry.
const RING_MARGIN := 80.0
const RING_SEGMENTS := 12
const RING_FOV := 36.0
const RING_PITCH := 8.0
const RING_SIZE := Vector2i(160, 192)
## Brush kinds that never show from afar.
const EYE_HEIGHT := 1.7


## The near geometry and the ring's paint list for `root`: {mesh: ArrayMesh or null,
## ring: Array of [p0, p1, p2, colour] (level space), centre: Vector3, zones: Array[String]}.
static func gather(root: LevelRoot) -> Dictionary:
	var own := _bounds(root.data)
	var centre := Vector3(own.get_center().x, own.position.y + EYE_HEIGHT, own.get_center().z)
	var inside := Rect2(Vector2(own.position.x, own.position.z), Vector2(own.size.x, own.size.z)).grow(-1.0)
	var ring_from := maxf(own.size.x, own.size.z) * 0.5 + RING_MARGIN
	var near := {pos = PackedVector3Array(), col = PackedColorArray()}
	var far := []
	var zones: Array[String] = []
	var colours := {}
	for b in root.data.brushes:
		if b == null or not b.is_passage() or b.passage.target_zone.is_empty():
			continue
		var target := b.passage.target_zone
		if not ResourceLoader.exists(target) or target == root.scene_file_path:
			continue
		var levels := _zone_levels(target)
		var placed := _place(b, levels)
		if placed.is_empty():
			continue
		zones.append(target)
		# One polygon (this level's space) into the near mesh or onto the ring, unless it
		# would land inside this level.
		var add_poly := func(pts: PackedVector3Array, col: Color) -> void:
			var c := Vector3.ZERO
			for p in pts:
				c += p
			c /= pts.size()
			if inside.has_point(Vector2(c.x, c.z)):
				return
			var n := PolyUtil.newell_normal(pts)
			col = col * (0.7 + 0.3 * clampf(n.y * 0.5 + 0.5, 0.0, 1.0))
			col.a = 1.0
			var to_ring := Vector2(c.x - centre.x, c.z - centre.z).length() > ring_from
			for k in range(1, pts.size() - 1):
				if to_ring:
					far.append([pts[0], pts[k], pts[k + 1], col])
				else:
					near.pos.append_array([pts[0], pts[k], pts[k + 1]])
					near.col.append_array([col, col, col])
		for lv in levels:
			var xf: Transform3D = placed.xf * lv.to_meet
			for nb: LevelBrush in lv.data.brushes:
				if nb == null or nb.is_prop() or nb.is_door() or nb.is_window() or nb.is_passage() or nb.is_rope() or nb.is_fence():
					continue
				var bxf := xf * nb.transform
				if nb.is_house():
					# A house: its block and roof, a dozen triangles.
					for poly in _house_proxy(nb.house, colours):
						var pts := PackedVector3Array()
						for p: Vector3 in poly[0]:
							pts.append(bxf * p)
						add_poly.call(pts, poly[1])
					continue
				nb.ensure_geometry()
				if nb.shape == BrushShapes.Shape.GRID and nb.blend_file == "":
					# Ground: one flat quad at its average height, cut away where it would lie
					# over this level (a big neighbour's ground reaches well past the doorway:
					# whole, it would cover this level's own ground).
					var flat := _flat_ground(nb)
					if not flat.is_empty():
						var pts := PackedVector3Array()
						for p: Vector3 in flat:
							pts.append(bxf * p)
						var y := pts[0].y
						var poly2 := PackedVector2Array()
						for p in pts:
							poly2.append(Vector2(p.x, p.z))
						var hole := PackedVector2Array([inside.position, Vector2(inside.end.x, inside.position.y), inside.end, Vector2(inside.position.x, inside.end.y)])
						for piece in Geometry2D.clip_polygons(poly2, hole):
							if Geometry2D.is_polygon_clockwise(piece):
								continue  # (a hole: the ground surrounds this level)
							var tri := Geometry2D.triangulate_polygon(piece)
							var col := _face_colour(lv.data, nb, 0, colours)
							for t in range(0, tri.size(), 3):
								var tp := PackedVector3Array()
								for k in 3:
									var q := piece[tri[t + k]]
									tp.append(Vector3(q.x, y, q.y))
								if PolyUtil.newell_normal(tp).y < 0.0:
									tp.reverse()  # facing up, like the ground it stands for
								add_poly.call(tp, col)
					continue
				for f in nb.get_face_count():
					if not nb.face_visual(f) or nb.face_pick_only(f):
						continue
					if nb.get_face_lod(f) in [LevelBrush.LOD_NEAR, LevelBrush.LOD_DETAIL_NEAR, LevelBrush.LOD_GROUND_NEAR]:
						continue
					var pts := PackedVector3Array()
					for p in nb.get_face_points(f):
						pts.append(bxf * p)
					var area := 0.0
					for k in range(1, pts.size() - 1):
						area += (pts[k] - pts[0]).cross(pts[k + 1] - pts[0]).length() * 0.5
					if area < MIN_AREA:
						continue
					add_poly.call(pts, _face_colour(lv.data, nb, f, colours))
		for lv in levels:
			if is_instance_valid(lv.scene):
				lv.scene.free()
			break
	var mesh: ArrayMesh = null
	if not near.pos.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = near.pos
		arrays[Mesh.ARRAY_COLOR] = near.col
		mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {mesh = mesh, ring = far, centre = centre, zones = zones}


## Bakes `root`'s backdrop onto its data: the near mesh, and the ring painted in a viewport
## under `host` (needs a renderer; awaited). Returns the zones it drew from.
static func bake(root: LevelRoot, host: Node) -> Array[String]:
	var g := gather(root)
	var data := root.data
	data.backdrop_mesh = g.mesh
	data.backdrop_ring = null
	data.backdrop_ring_info = Vector4.ZERO
	if not (g.ring as Array).is_empty() and host and host.is_inside_tree():
		var img: Image = await paint_ring(host, g.ring, g.centre)
		if img:
			data.backdrop_ring = ImageTexture.create_from_image(img)
			data.backdrop_ring_info = Vector4(RING_SEGMENTS, RING_FOV, RING_PITCH, float(RING_SIZE.x) / RING_SIZE.y)
	return g.zones


## The ring's strip: each segment seen from `centre`, side by side; transparent where
## there's nothing (the sky shows through).
static func paint_ring(host: Node, tris: Array, centre: Vector3) -> Image:
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	for t in tris:
		pos.append_array([t[0] - centre, t[1] - centre, t[2] - centre])
		col.append_array([t[3], t[3], t[3]])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_COLOR] = col
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var vp := SubViewport.new()
	vp.size = RING_SIZE
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	vp.add_child(mi)
	var cam := Camera3D.new()
	cam.fov = RING_FOV
	cam.near = 1.0
	cam.far = 5000.0
	vp.add_child(cam)
	host.add_child(vp)
	var strip := Image.create(RING_SIZE.x * RING_SEGMENTS, RING_SIZE.y, false, Image.FORMAT_RGBA8)
	for i in RING_SEGMENTS:
		cam.transform = Transform3D(Backdrop.segment_basis(i, RING_SEGMENTS, RING_PITCH), Vector3.ZERO)
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var shot := vp.get_texture().get_image()
		shot.convert(Image.FORMAT_RGBA8)
		strip.blit_rect(shot, Rect2i(Vector2i.ZERO, RING_SIZE), Vector2i(i * RING_SIZE.x, 0))
	vp.queue_free()
	return strip


## The level files of the zone at `path`: [{data, to_meet (its level space -> that of the
## first level, through the scene), scene (to free)}].
static func _zone_levels(path: String) -> Array:
	var ps := load(path) as PackedScene
	if ps == null:
		return []
	var scene := ps.instantiate()
	var roots := []
	for n in [scene] + scene.find_children("*", "", true, false):
		if n is LevelRoot and n.data:
			roots.append(n)
	var out := []
	for r: LevelRoot in roots:
		out.append({data = r.data, scene_xf = _scene_xf(r, scene), scene = scene})
	return out


static func _scene_xf(n: Node, scene: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	while n and n != scene:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## Where the neighbour sits: its passage arriving at our `b` lined up so the two corridors'
## far ends meet. Sets each level's to_meet (its level space -> the arrival level's) and
## returns {xf: arrival level space -> ours}, or {} without a matching passage.
static func _place(b: LevelBrush, levels: Array) -> Dictionary:
	for lv in levels:
		for other: LevelBrush in lv.data.brushes:
			if other and other.is_passage() and other.passage.spawn_id == b.passage.target_spawn:
				var xf: Transform3D = b.transform * Transform3D(Basis(), Vector3(0, 0, -b.passage.depth)) \
					* Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO) \
					* Transform3D(Basis(), Vector3(0, 0, other.passage.depth)) * other.transform.affine_inverse()
				for l2 in levels:
					l2.to_meet = (lv.scene_xf as Transform3D).affine_inverse() * l2.scene_xf
				return {xf = xf}
	return {}


## The level's walkable extent (level space): its ground (grids, planes) and houses, or
## failing those every brush but props. Scenery (a distant hill) doesn't stretch it.
static func _bounds(data: LevelData) -> AABB:
	var walkable := data.brushes.filter(func(b): return b and (b.is_house() or (not b.is_prop() and b.blend_file == ""
		and b.shape in [BrushShapes.Shape.GRID, BrushShapes.Shape.PLANE] and not b.hand_edited)))
	if walkable.is_empty():
		walkable = data.brushes.filter(func(b): return b and not b.is_prop())
	var out := AABB()
	var first := true
	for b: LevelBrush in walkable:
		b.ensure_geometry()
		for v in b.vertices:
			var w := b.transform * v
			out = AABB(w, Vector3.ZERO) if first else out.expand(w)
			first = false
	return out


## A house from afar (house space): its walls as a block and its roof (gable or hip) over
## the eaves, each [points, colour] in its wall / roof texture's average colour.
static func _house_proxy(h: HouseSpec, cache: Dictionary) -> Array:
	var hw := h.width * 0.5
	var hd := h.depth * 0.5
	var top := h.wall_height()
	var wall := _average(h.wall_texture, cache) * h.wall_color
	var roof := _average(h.roof_texture, cache) * h.roof_color
	var o := h.overhang
	var rise := (hd + o) * tan(deg_to_rad(h.roof_pitch))
	var eave := top - o * tan(deg_to_rad(h.roof_pitch))
	var out := []
	var c := [Vector3(-hw, 0, hd), Vector3(hw, 0, hd), Vector3(hw, 0, -hd), Vector3(-hw, 0, -hd)]
	for i in 4:
		var a: Vector3 = c[i]
		var b: Vector3 = c[(i + 1) % 4]
		out.append([PackedVector3Array([a, b, b + Vector3.UP * top, a + Vector3.UP * top]), wall])
	var ex := hw + o
	var ez := hd + o
	var peak := top + rise - o * tan(deg_to_rad(h.roof_pitch))
	if h.roof == HouseSpec.Roof.HIP:
		var r := maxf(ex - ez, 0.0)
		out.append([PackedVector3Array([Vector3(-ex, eave, ez), Vector3(ex, eave, ez), Vector3(r, peak, 0), Vector3(-r, peak, 0)]), roof])
		out.append([PackedVector3Array([Vector3(ex, eave, -ez), Vector3(-ex, eave, -ez), Vector3(-r, peak, 0), Vector3(r, peak, 0)]), roof])
		out.append([PackedVector3Array([Vector3(ex, eave, ez), Vector3(ex, eave, -ez), Vector3(r, peak, 0)]), roof])
		out.append([PackedVector3Array([Vector3(-ex, eave, -ez), Vector3(-ex, eave, ez), Vector3(-r, peak, 0)]), roof])
	else:
		out.append([PackedVector3Array([Vector3(-ex, eave, ez), Vector3(ex, eave, ez), Vector3(ex, peak, 0), Vector3(-ex, peak, 0)]), roof])
		out.append([PackedVector3Array([Vector3(ex, eave, -ez), Vector3(-ex, eave, -ez), Vector3(-ex, peak, 0), Vector3(ex, peak, 0)]), roof])
		for sx in [-1.0, 1.0]:
			out.append([PackedVector3Array([Vector3(sx * hw, top, hd), Vector3(sx * hw, top, -hd), Vector3(sx * hw, peak, 0)]), wall])
	return out


## A ground grid as one flat quad (brush space): its extent at its average height.
static func _flat_ground(b: LevelBrush) -> PackedVector3Array:
	if b.vertices.is_empty():
		return PackedVector3Array()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var y := 0.0
	for v in b.vertices:
		lo = lo.min(Vector2(v.x, v.z))
		hi = hi.max(Vector2(v.x, v.z))
		y += v.y
	y /= b.vertices.size()
	return PackedVector3Array([Vector3(lo.x, y, hi.y), Vector3(hi.x, y, hi.y), Vector3(hi.x, y, lo.y), Vector3(lo.x, y, lo.y)])


## A face's colour from afar: its texture's average colour (cached), else a neutral grey.
static func _face_colour(data: LevelData, b: LevelBrush, f: int, cache: Dictionary) -> Color:
	var t := b.get_face_texture(f)
	if t < 0 or t >= data.textures.size() or data.textures[t] == null:
		return Color(0.55, 0.55, 0.52)
	return _average(data.textures[t], cache)


## A texture's average colour (cached in `cache`), else a neutral grey.
static func _average(tex: Texture2D, cache: Dictionary) -> Color:
	if tex == null:
		return Color(0.55, 0.55, 0.52)
	if not cache.has(tex):
		var img := tex.get_image()
		var c := Color(0.55, 0.55, 0.52)
		if img:
			img = img.duplicate()
			if img.is_compressed():
				img.decompress()
			img.convert(Image.FORMAT_RGBA8)
			img.resize(4, 4, Image.INTERPOLATE_BILINEAR)
			var sum := Color(0, 0, 0, 0)
			for y in 4:
				for x in 4:
					sum += img.get_pixel(x, y)
			c = sum / 16.0
			c.a = 1.0
		cache[tex] = c
	return cache[tex]
