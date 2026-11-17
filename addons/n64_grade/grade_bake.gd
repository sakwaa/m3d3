@tool
class_name GradeBake
extends RefCounted
## Step 4 (DESIGN.md): a zone's Grade baked into its build, so the game does no grading.
## Runs in the build (ExportBake._bake_level) on the build's private copy of the level,
## after lighting and before LevelBaker makes meshes and materials:
##  - vertex layers: painted colours through the Painted colour filters; each time key's
##    baked light through that key's Baked light filters, with Grade AO folded in (plain AO
##    then 1: the light keys hold it), exactly as the editor preview shows;
##  - texture layers: each palette entry with filters gets its own graded copy of its
##    texture (GradeProcessor, the preview's code), its combiner tint already in the pixels.
## Needs texture pixels: the editor or a build worker with a renderer (not --headless).


## Painted AO as the level was before the build reshaped its brushes (cull, dissolve,
## lighting grid): brush -> {tris: [[a, b, c, va, vb, vc]...] (local points, per-layer
## darkness at the corners), grid: cell -> [tri index]}. Call at the start of the build.
static func capture(data: LevelData) -> Dictionary:
	var g := data.grade as ZoneGrade
	if g == null or g.ao_fold().is_empty():
		return {}
	var ids := g.ao_fold().map(func(e): return e[0])
	var out := {}
	for b: LevelBrush in data.brushes:
		if b == null or b.ao_paint.is_empty():
			continue
		var tris := []
		var grid := {}
		for f in b.get_faces():
			for i in range(1, f.size() - 1):
				var idx := [f[0], f[i], f[i + 1]]
				var vals := []
				var any := false
				for id in ids:
					var v := Vector3(b.get_ao_paint(id, idx[0]), b.get_ao_paint(id, idx[1]), b.get_ao_paint(id, idx[2]))
					any = any or v != Vector3.ZERO
					vals.append(v)
				if not any:
					continue
				var t := tris.size()
				tris.append([b.vertices[idx[0]], b.vertices[idx[1]], b.vertices[idx[2]], vals])
				var box := AABB(b.vertices[idx[0]], Vector3.ZERO).expand(b.vertices[idx[1]]).expand(b.vertices[idx[2]]).grow(0.05)
				for x in range(floori(box.position.x / CELL), floori(box.end.x / CELL) + 1):
					for y in range(floori(box.position.y / CELL), floori(box.end.y / CELL) + 1):
						for z in range(floori(box.position.z / CELL), floori(box.end.z / CELL) + 1):
							grid.get_or_add(Vector3i(x, y, z), []).append(t)
		if not tris.is_empty():
			out[b] = {tris = tris, grid = grid, ids = ids}
	return out


const CELL := 2.0


## Applies `data.grade` to `data` (a build copy). `ao_before`: capture() from before the
## build reshaped the brushes. Returns stats for the build log.
static func apply(data: LevelData, ao_before := {}) -> Dictionary:
	var g := data.grade as ZoneGrade
	if g == null:
		return {}
	var stats := {graded_textures = 0, graded_brushes = 0}
	_ao_layers(data, g, ao_before, stats)
	_vertex(data, g, stats)
	var extras := GradeLayers.extra_textures(data)  # (before the texture list changes)
	_textures(data, g, stats)
	_extras(data, g, extras, stats)
	return stats


## Stairs' bases, overlay layers' textures, the grass carpet / tufts and scatter sets get
## graded copies too (stairs and overlays tinted first, their tint then off).
static func _extras(data: LevelData, g: ZoneGrade, extras: Dictionary, stats: Dictionary) -> void:
	var jobs := []
	for t: Texture2D in extras:
		var chain := g.chain_for(t, GradeLayers.group_of(t))
		if chain.is_empty():
			continue
		var src := GradeProcessor.source_image(t)
		if src == null:
			push_warning("[Grade] %s: no pixels (a build needs a renderer); left ungraded." % t.resource_path)
			continue
		for f in chain:
			f.prepare()
		jobs.append({t = t, chain = chain, tint = extras[t].tint, src = src})
	if jobs.is_empty():
		return
	var results := []
	results.resize(jobs.size())
	var task := WorkerThreadPool.add_group_task(func(j): results[j] = GradeProcessor.process(jobs[j].src, jobs[j].chain, jobs[j].tint),
		jobs.size(), -1, true, "Grade bake extras")
	WorkerThreadPool.wait_for_group_task_completion(task)
	var copy := {}  # original -> graded copy
	var tinted := {}
	for j in jobs.size():
		copy[jobs[j].t] = _texture_copy(jobs[j].t, results[j], not jobs[j].tint.is_empty())
		tinted[jobs[j].t] = not jobs[j].tint.is_empty()
		stats.graded_textures += 1
	# Stairs: a copy whose base is the graded base.
	var textures := data.textures.duplicate()
	for i in textures.size():
		var st := textures[i] as N64StairTexture
		if st and st.base and copy.has(st.base):
			var s2 := st.duplicate() as N64StairTexture
			s2.base = copy[st.base]
			textures[i] = s2
	data.textures = textures
	# Overlay layers (every set).
	var swap_layers := func(list: Array) -> Array[PaintLayer]:
		var out: Array[PaintLayer] = []
		for l: PaintLayer in list:
			if l and l.texture and copy.has(l.texture):
				var l2 := l.duplicate() as PaintLayer
				var was: Texture2D = l.texture
				l2.texture = copy[was]
				if tinted[was]:
					l2.override_tint = false
				out.append(l2)
			else:
				out.append(l)
		return out
	data.layers = swap_layers.call(data.layers)
	var sets: Array[PaintLayerSet] = []
	for ls in data.layer_sets:
		if ls:
			var ls2 := ls.duplicate() as PaintLayerSet
			ls2.layers = swap_layers.call(ls.layers)
			sets.append(ls2)
		else:
			sets.append(ls)
	data.layer_sets = sets
	# Decals.
	var decals: Array[LevelDecal] = []
	for d0 in data.decals:
		if d0 and d0.texture and copy.has(d0.texture):
			var d1 := d0.duplicate() as LevelDecal
			d1.texture = copy[d0.texture]
			decals.append(d1)
		else:
			decals.append(d0)
	data.decals = decals
	# Grass.
	if data.grass:
		var gs := data.grass.duplicate() as GrassSettings
		for prop in [&"top_texture", &"side_texture", &"rim_texture", &"tuft_texture"]:
			var t: Texture2D = gs.get(prop)
			if t and copy.has(t):
				gs.set(prop, copy[t])
		data.grass = gs
	# Scatter.
	var sc: Array[ScatterSet] = []
	for s0 in data.scatter:
		if s0 and s0.texture and copy.has(s0.texture):
			var s1 := s0.duplicate() as ScatterSet
			s1.texture = copy[s0.texture]
			sc.append(s1)
		else:
			sc.append(s0)
	data.scatter = sc
	# Per-texture settings (tile size, variation...) follow the copies.
	for prop in [&"base_tile_sizes", &"base_variation", &"base_variation_textures"]:
		var d: Dictionary = (data.get(prop) as Dictionary).duplicate()
		for t in copy:
			if d.has(t):
				d[copy[t]] = d[t]
		data.set(prop, d)


## Painted AO layers into the time keys (as LevelBrush.build_painted_mesh does in the
## editor), the darkness found again by position on the brushes as they were.
static func _ao_layers(data: LevelData, g: ZoneGrade, before: Dictionary, stats: Dictionary) -> void:
	var fold := g.ao_fold()
	var timed := LevelData.mode_is_timed(data.lighting_mode)
	var single := GradeVertex.single_light(data.lighting_mode)
	if fold.is_empty() or before.is_empty() or not (timed or single):
		return
	for b: LevelBrush in before:
		if (timed and b.corner_lighting_keys.is_empty()) or (single and b.corner_lighting.size() != b.face_indices.size()):
			continue
		var cap: Dictionary = before[b]
		# Darkness per layer at each vertex of the brush as built.
		var dark := []
		for v in b.vertices.size():
			dark.append(_sample(cap, b.vertices[v]))
		var keys: Array[PackedColorArray] = []
		var src: Array[PackedColorArray] = b.corner_lighting_keys if timed else ([b.corner_lighting] as Array[PackedColorArray])
		for s in src.size():
			var arr := src[s].duplicate()
			if s < 4 and arr.size() == b.face_indices.size():
				for li in fold.size():
					var e: Array = fold[li]
					var j: int = cap.ids.find(e[0])
					if j < 0:
						continue
					for c in arr.size():
						var dv: float = dark[b.face_indices[c]][j]
						if dv > 0.0:
							arr[c] = LevelBrush.fold_ao(arr[c], dv, e[1][s], e[2][s])
			keys.append(arr)
		if timed:
			b.corner_lighting_keys = keys
		else:
			b.corner_lighting = keys[0]
		stats.graded_brushes += 1


## Per-layer darkness at local point `p` on the captured faces (0 off them).
static func _sample(cap: Dictionary, p: Vector3) -> Array:
	var cell := Vector3i(floori(p.x / CELL), floori(p.y / CELL), floori(p.z / CELL))
	var best := -1
	var bw := Vector3.ZERO
	var bd := 0.03
	for t in cap.grid.get(cell, []):
		var tri: Array = cap.tris[t]
		var a: Vector3 = tri[0]
		var b2: Vector3 = tri[1]
		var c2: Vector3 = tri[2]
		var n := (b2 - a).cross(c2 - a)
		if n.length_squared() < 1e-12:
			continue
		var dist := absf((p - a).dot(n.normalized()))
		if dist > bd:
			continue
		var w := _bary(p, a, b2, c2)
		if w.x >= -0.01 and w.y >= -0.01 and w.z >= -0.01:
			best = t
			bw = w
			bd = dist
	var out := []
	for j in cap.ids.size():
		if best < 0:
			out.append(0.0)
		else:
			var v: Vector3 = cap.tris[best][3][j]
			out.append(clampf(v.dot(bw), 0.0, 1.0))
	return out


static func _bary(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var den := d00 * d11 - d01 * d01
	if absf(den) < 1e-12:
		return Vector3(-1, -1, -1)
	var v := (d11 * d20 - d01 * d21) / den
	var w := (d00 * d21 - d01 * d20) / den
	return Vector3(1.0 - v - w, v, w)


static func _vertex(data: LevelData, g: ZoneGrade, stats: Dictionary) -> void:
	GradeVertex.prepare(g)
	var paint := GradeVertex.paint_chain(g)
	var timed := LevelData.mode_is_timed(data.lighting_mode)
	# (one lighting, no time of day: the single bake as key 0, every light filter)
	var single := GradeVertex.single_light(data.lighting_mode)
	var light := []
	var any_light := false
	for k in 4:
		light.append(GradeVertex.light_chain(g, k) if timed else (GradeVertex.light_chain(g, 0, false) if single and k == 0 else []))
		any_light = any_light or not light[k].is_empty()
	var ao := g.effective_ao() if (timed or single) and not g.hidden.has("vertex/ao") else null
	if paint.is_empty() and not any_light and ao == null:
		return
	var scale := 2.0 if data.vertex_color_range == 1 else 1.0
	var ao_p := ao.params() if ao else {}
	for b: LevelBrush in data.brushes:
		if b == null:
			continue
		var touched := false
		if not paint.is_empty():
			if not b.corner_colors.is_empty():
				b.corner_colors = _paint(b.corner_colors, paint, scale)
				touched = true
			if not b.vertex_colors.is_empty():
				b.vertex_colors = _paint(b.vertex_colors, paint, scale)
				touched = true
		var src: Array[PackedColorArray] = b.corner_lighting_keys if timed else \
			(([b.corner_lighting] as Array[PackedColorArray]) if b.corner_lighting.size() == b.face_indices.size() else ([] as Array[PackedColorArray]))
		if (any_light or ao) and not src.is_empty():
			var keys: Array[PackedColorArray] = []
			for k in src.size():
				var arr := src[k].duplicate()
				var chain: Array = light[k] if k < 4 else []
				for c in arr.size():
					var col := arr[c]
					for f in chain:
						col = f.run(col, 0)
					if ao and k < 4:
						var v := b.face_indices[c] if c < b.face_indices.size() else -1
						var a := b.vertex_ao[v] if v >= 0 and v < b.vertex_ao.size() else 1.0
						var m := _ao(a, k, ao_p)
						col = Color(col.r * m.x, col.g * m.y, col.b * m.z, col.a)
					arr[c] = col.clamp()
				keys.append(arr)
			if timed:
				b.corner_lighting_keys = keys
			else:
				b.corner_lighting = keys[0]
			if ao and not b.vertex_ao.is_empty():
				# (the keys hold the AO now; the shader's own AO would double it)
				var ones := PackedFloat32Array()
				ones.resize(b.vertex_ao.size())
				ones.fill(1.0)
				b.vertex_ao = ones
			touched = true
		if touched:
			stats.graded_brushes += 1


static func _paint(cols: PackedColorArray, chain: Array, scale: float) -> PackedColorArray:
	var out := cols.duplicate()
	for i in out.size():
		var c := out[i]
		var d := Color(c.r / scale, c.g / scale, c.b / scale, c.a)
		for f in chain:
			d = f.run(d, 0)
		out[i] = Color(d.r * scale, d.g * scale, d.b * scale, c.a)
	return out


## The paint shader's grade_ao(): AO per key (strength, curve, corner colour).
static func _ao(a: float, k: int, p: Dictionary) -> Vector3:
	var g := pow(clampf(a, 0.0, 1.0), (p.grade_ao_gamma as Vector4)[k])
	var tint: Vector4 = (p.grade_ao_tint as Projection)[k]
	var m := Vector3(tint.x, tint.y, tint.z).lerp(Vector3.ONE, g)
	return Vector3.ONE.lerp(m, (p.grade_ao_strength as Vector4)[k]).clamp(Vector3.ZERO, Vector3.ONE)


## Each palette entry with filters swapped for a graded copy (an N64Texture copy keeps its
## settings: world size, anti-tiling, animation, surface sound); the level's per-texture
## settings follow the copy. One copy per entry (a variant grades its own).
static func _textures(data: LevelData, g: ZoneGrade, stats: Dictionary) -> void:
	var textures := data.textures.duplicate()
	var renamed := {}  # original base -> [copy] (for the per-texture dictionaries)
	var drop_tint := {}
	var jobs := []
	for i in textures.size():
		var t: Texture2D = textures[i]
		if t == null or t is N64StairTexture:
			continue
		var base := TextureLook.source_of(t)
		if base == null:
			continue
		var chain := g.chain_for(t, GradeLayers.group_of(base))
		if chain.is_empty():
			continue
		var look := t as TextureLook
		var palette = look.palette if look and look.palette.size() == 2 else data.base_tints.get(base)
		var tint := PaintAtlas.texture_tint(base, palette)
		if tint[0] < 0.5:
			tint = []
		var src := GradeProcessor.source_image(base)
		if src == null:
			push_warning("[Grade] %s: no pixels (a build needs a renderer); left ungraded." % base.resource_path)
			continue
		for f in chain:
			f.prepare()
		jobs.append({i = i, t = t, base = base, chain = chain, tint = tint, src = src})
	var results := []
	results.resize(jobs.size())
	var task := WorkerThreadPool.add_group_task(func(j): results[j] = GradeProcessor.process(jobs[j].src, jobs[j].chain, jobs[j].tint),
		jobs.size(), -1, true, "Grade bake")
	WorkerThreadPool.wait_for_group_task_completion(task)
	for j in jobs.size():
		var job: Dictionary = jobs[j]
		var copy := _texture_copy(job.base, results[j], not job.tint.is_empty())
		if job.t is TextureLook:
			var look := (job.t as TextureLook).duplicate() as TextureLook
			look.texture = copy
			if not job.tint.is_empty():
				look.palette = PackedColorArray()
			textures[job.i] = look
		else:
			textures[job.i] = copy
		if not renamed.has(job.base):
			renamed[job.base] = []
		renamed[job.base].append(copy)
		if not job.tint.is_empty():
			drop_tint[copy] = true
		stats.graded_textures += 1
	data.textures = textures
	# Per-texture settings keyed by the original base follow its copies.
	for prop in [&"base_tile_sizes", &"base_variation", &"base_adjusts", &"base_variation_textures", &"base_tints"]:
		var d: Dictionary = (data.get(prop) as Dictionary).duplicate()
		for base in renamed:
			if d.has(base):
				for copy in renamed[base]:
					if not (prop == &"base_tints" and drop_tint.has(copy)):
						d[copy] = d[base]
		data.set(prop, d)


## A copy of `base` showing `img`; `pretinted`: its combiner tint is in the pixels already.
## Meta `grade_source`: the original (what the build matches textures by, e.g. grass faces).
static func _texture_copy(base: Texture2D, img: Image, pretinted: bool) -> Texture2D:
	var t: Texture2D
	if base is N64PaletteSwap and (base as N64PaletteSwap).palette_texture:
		# Palette variants grade their palette row (the N64 way: the TLUT recoloured), each
		# entry taking the graded colour of a texel that uses it.
		var swap := (base as N64PaletteSwap).duplicate() as N64PaletteSwap
		var pal := swap.palette_texture
		var idx := pal.index.get_image().duplicate() as Image
		idx.clear_mipmaps()
		var graded := img.duplicate() as Image
		graded.clear_mipmaps()
		graded.convert(Image.FORMAT_RGBA8)
		var row: PackedColorArray = pal.palettes[swap.palette_row].duplicate()
		var done := {}
		for y in mini(idx.get_height(), graded.get_height()):
			for x in mini(idx.get_width(), graded.get_width()):
				var k := roundi(idx.get_pixel(x, y).r * 255.0)
				if k < row.size() and not done.has(k):
					done[k] = true
					row[k] = graded.get_pixel(x, y)
		var copy := N64PaletteTexture.new()
		copy.index = pal.index
		copy.palettes = [row]
		swap.palette_texture = copy
		swap.palette_row = 0
		swap.set_image(img)
		if pretinted:
			swap.tint_mode = 0
		t = swap
	elif base is N64Texture:
		t = (base as N64Texture).duplicate()
		(t as N64Texture).set_image(img)
		if pretinted:
			(t as N64Texture).tint_mode = 0
	else:
		t = ImageTexture.create_from_image(img)
	t.set_meta(&"grade_source", base)
	return t
