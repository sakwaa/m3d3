@tool
class_name GroundEdgeBlend
extends RefCounted
## Soft edges where grass ground meets dirt: the dirt's overlay layer painted onto the grass
## faces along the border, fading out over `width` metres from it, the fade line broken up
## by noise (no straight seams along the ground's cells). Works on the face masks (paint
## overlays), so no new geometry; existing paint stays (each texel keeps the stronger). The
## border: the dirt's outline (any brush's upward dirt faces), wherever grass lies beside it.
## Kept apart (LevelBrush.blend_base: each changed mask as it was): clear() puts them back,
## except where the mask was painted over since; apply() expects it off (GroundFinish
## clears first).

const NOISE_SCALE := 0.8  # metres across a noise feature


## Paints the blend into `data`. `grass` (textures) / `dirt`: any palette entry drawing them,
## recoloured too. Returns the faces painted, or -1 when no overlay slot can take the dirt.
static func apply(data: LevelData, grass: Array, dirt: Texture2D, width := 0.7, noise := 0.45) -> int:
	var grass_ids := _palette_all(data, grass)
	var dirt_ids := _palette(data, dirt)
	var slot := _slot(data, dirt)
	if slot < 0:
		return -1
	var n := FastNoiseLite.new()
	n.frequency = 1.0 / NOISE_SCALE
	n.seed = 23
	# The dirt's outline (world XZ): edges of upward dirt faces not shared with another dirt
	# face, from every brush (a dirt lane may be a brush of its own beside the grass).
	var bins := {}  # Vector2i (2 m cell) -> [[from, to]]
	var reach := width * (1.0 + noise)
	for b: LevelBrush in data.brushes:
		if not _ground(b):
			continue
		var faces := b.get_faces()
		var dirt_edges := {}
		for f in faces.size():
			if not dirt_ids.has(b.get_face_texture(f)) or b.get_face_normal(f).y < 0.7:
				continue
			var ids: PackedInt32Array = faces[f]
			for k in ids.size():
				var a := ids[k]
				var c := ids[(k + 1) % ids.size()]
				var e := Vector2i(mini(a, c), maxi(a, c))
				dirt_edges[e] = dirt_edges.get(e, 0) + 1
		for e: Vector2i in dirt_edges:
			if dirt_edges[e] != 1:
				continue
			var wp := b.transform * b.vertices[e.x]
			var wq := b.transform * b.vertices[e.y]
			var p := Vector2(wp.x, wp.z)
			var q := Vector2(wq.x, wq.z)
			for bx in range(floori((minf(p.x, q.x) - reach) / 2.0), floori((maxf(p.x, q.x) + reach) / 2.0) + 1):
				for bz in range(floori((minf(p.y, q.y) - reach) / 2.0), floori((maxf(p.y, q.y) + reach) / 2.0) + 1):
					bins.get_or_add(Vector2i(bx, bz), []).append([p, q])
	if bins.is_empty():
		return 0
	var painted := 0
	for b: LevelBrush in data.brushes:
		if _ground(b):
			painted += _blend_brush(data, b, grass_ids, bins, slot, width, noise, n)
	return painted


## Ground a blend goes on: plain brushes (not generated buildings, openings, props...).
static func _ground(b: LevelBrush) -> bool:
	return b != null and not (b.is_house() or b.is_prop() or b.opening_spec() != null or b.is_fence() or b.is_rope())


## The grass faces of `b` near the dirt's outline (`bins`, world XZ) get the dirt painted on.
static func _blend_brush(data: LevelData, b: LevelBrush, grass_ids: Dictionary, bins: Dictionary, slot: int,
		width: float, noise: float, n: FastNoiseLite) -> int:
	var faces := b.get_faces()
	var painted := 0
	for f in faces.size():
		if not grass_ids.has(b.get_face_texture(f)) or b.get_face_layer_set(f) != 0 or b.get_face_normal(f).y < 0.7:
			continue
		var rect := b.get_face_planar_rect(f)
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for c in [rect.position, rect.end, Vector2(rect.position.x, rect.end.y), Vector2(rect.end.x, rect.position.y)]:
			var w3 := b.transform * Vector3(c.x, 0.0, c.y)
			lo = lo.min(Vector2(w3.x, w3.z))
			hi = hi.max(Vector2(w3.x, w3.z))
		var near := []
		for bx in range(floori(lo.x / 2.0), floori(hi.x / 2.0) + 1):
			for bz in range(floori(lo.y / 2.0), floori(hi.y / 2.0) + 1):
				near.append_array(bins.get(Vector2i(bx, bz), []))
		if near.is_empty():
			continue
		var img := b.get_face_mask(f, slot)
		if img:
			img = img.duplicate()
		else:
			var sz := b.get_face_mask_size(f, data.mask_density)
			img = Image.create(sz.x, sz.y, false, Image.FORMAT_L8)
		var w := img.get_width()
		var h := img.get_height()
		var touched := false
		for y in h:
			for x in w:
				var uv := rect.position + (Vector2(x, y) + Vector2(0.5, 0.5)) / Vector2(w, h) * rect.size
				var world := b.transform * Vector3(uv.x, 0.0, uv.y)
				var at := Vector2(world.x, world.z)
				var d := INF
				for sg in near:
					d = minf(d, at.distance_to(Geometry2D.get_closest_point_to_segment(at, sg[0], sg[1])))
				d += n.get_noise_2d(world.x, world.z) * noise * width
				var v := 1.0 - smoothstep(0.0, width, d)
				if v <= 0.0:
					continue
				if v > img.get_pixel(x, y).r:
					img.set_pixel(x, y, Color(v, v, v))
					touched = true
		if touched:
			var key := Vector2i(f, slot)
			if not b.blend_base.has(key):
				var before := b.get_face_mask(f, slot)
				b.blend_base[key] = before.duplicate() if before else null
			b.set_face_mask(f, slot, img, false)
			b.blend_written[key] = hash(img.get_data())
			painted += 1
	if painted > 0:
		b.emit_changed()
	return painted


## Takes the blend off `data`: each mask it changed back as it was, unless painted over since.
static func clear(data: LevelData) -> void:
	for b: LevelBrush in data.brushes:
		if b == null or b.blend_base.is_empty():
			continue
		for key: Vector2i in b.blend_base:
			if key.x >= b.get_face_count():
				continue  # (the brush was rebuilt since: its faces aren't those any more)
			var now := b.get_face_mask(key.x, key.y)
			if now and hash(now.get_data()) != b.blend_written.get(key, 0):
				continue  # painted since: kept
			b.set_face_mask(key.x, key.y, b.blend_base[key], false)
		b.blend_base = {}
		b.blend_written = {}
		b.emit_changed()


## Palette entries drawing any of `textures`: {index: true}.
static func _palette_all(data: LevelData, textures: Array) -> Dictionary:
	var out := {}
	for t: Texture2D in textures:
		if t:
			out.merge(_palette(data, t))
	return out


## Palette entries drawing `tex` (itself, or a recoloured entry of it): {index: true}.
static func _palette(data: LevelData, tex: Texture2D) -> Dictionary:
	var out := {}
	for i in data.textures.size():
		var t: Texture2D = data.textures[i]
		if t == null:
			continue
		var inner = t.get(&"texture")
		if t == tex or t.resource_path == tex.resource_path or (inner is Texture2D and (inner as Texture2D).resource_path == tex.resource_path):
			out[i] = true
	return out


## The default overlay set's slot drawing `tex` (added when there's room), or -1.
static func _slot(data: LevelData, tex: Texture2D) -> int:
	for i in data.layers.size():
		if data.layers[i] and data.layers[i].texture and data.layers[i].texture.resource_path == tex.resource_path:
			return i
	if data.layers.size() >= LevelData.MAX_LAYERS:
		return -1
	var layer := PaintLayer.new()
	layer.name = tex.resource_path.get_file().get_basename()
	layer.texture = tex
	var layers := data.layers.duplicate()
	layers.append(layer)
	data.layers = layers
	return layers.size() - 1
