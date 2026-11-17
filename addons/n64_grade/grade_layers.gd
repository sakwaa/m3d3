@tool
class_name GradeLayers
extends RefCounted
## The Grade screen's layer tree for a level (DESIGN.md): zone filters, the vertex stack,
## then texture groups > base textures > variants. Read-only for now (step 1): it shows how
## the zone breaks down into layers; filters and painting come later.
##
## Each node is a Dictionary: {kind: StringName, name: String, info: String,
## ids: PackedInt32Array (texture ids whose faces belong to the layer; empty = not
## face-bound), faces: int, children: Array, key: the ZoneGrade stack key (null = takes no
## filters yet), filter: the GradeFilter (filter nodes)}. Kinds: &"zone", &"vertex",
## &"light", &"ao", &"paint", &"group", &"texture", &"variant", &"filter", &"legacy" (a
## Paint panel Colour adjust still in the shader).


## The group a base texture belongs to: an N64Texture's grade category (its folder, or its
## Grade As), else its folder; "other" if neither.
static func group_of(base: Texture2D) -> String:
	var g := ""
	if base is N64Texture:
		g = String((base as N64Texture).grade_category())
	if g == "" and base:
		g = base.resource_path.get_base_dir().get_file()
	return g if g != "" else "other"


## `edit`: the grade being edited (the zone's, or the shared one under it); its filters are
## the ones listed. Default: the zone's.
static func build(data: LevelData, edit: ZoneGrade = null) -> Array:
	if data == null:
		return []
	var counts := {}  # texture id -> faces
	var painted := 0
	var with_ao := 0
	var lit := 0
	var keys := 0
	for b: LevelBrush in data.brushes:
		if b == null:
			continue
		for f in b.get_face_count():
			var id := b.get_face_texture(f)
			counts[id] = counts.get(id, 0) + 1
		if not b.corner_colors.is_empty() or _any_not_white(b.vertex_colors):
			painted += 1
		if not b.vertex_ao.is_empty():
			with_ao += 1
		if not b.corner_lighting_keys.is_empty() or not b.corner_lighting.is_empty():
			lit += 1
			keys = maxi(keys, b.corner_lighting_keys.size())
	var grade: ZoneGrade = edit if edit else data.grade as ZoneGrade
	var out := []
	var zone := _node(&"zone", "Zone filters", "Adjustment layers over every texture in the zone (applied last, over group and texture filters).")
	_stackable(zone, "zone", grade)
	out.append(zone)
	var vertex := _node(&"vertex", "Vertex", "The zone's vertex shading, per time key where it applies.")
	var mode_name: String = LevelData.LightingMode.keys()[data.lighting_mode].capitalize()
	var light := _node(&"light", "Baked light", "%s · %d brushes lit%s. Filters here shade the light itself, per time key (each filter's Keys); the relight never touches them." % [
		mode_name, lit, (" · %d time keys" % keys) if keys > 0 else ""])
	var ao := _node(&"ao", "Baked AO", "%d brushes with AO · strength %.2f, radius %.1f m. Shape it per time key: strength, curve, the colour corners sink to." % [with_ao, data.light_ao_strength, data.light_ao_radius])
	ao.key = "vertex/ao"
	var paint := _node(&"paint", "Painted colour", "%d brushes painted (Paint panel vertex colour). Filters here change the painted colours." % painted)
	paint.paint = -1  # (LevelPaintTool.VERTEX_LAYER: the brush paints vertex colour)
	var ao_layers := _node(&"ao_layers", "AO layers", "Darkness you paint (alleys, under eaves, a lamp's reach), each layer with its own strength and corner colour per time key. Add one here, then paint it with Paint on.")
	ao_layers.key = "vertex/ao_layers"
	if grade:
		for l in grade.ao_layers:
			if l == null:
				continue
			var on := 0
			for b: LevelBrush in data.brushes:
				if b and b.ao_paint.has(l.id):
					on += 1
			var ln := _node(&"ao_layer", l.name, "Painted AO on %d brush%s%s." % [on, "" if on == 1 else "es", "" if l.enabled else " · off"])
			ln.key = "ao_layer/%d" % l.id
			ln.ao_id = l.id
			ao_layers.children.append(ln)
	vertex.children = [light, ao, ao_layers, paint]
	_stackable(light, "vertex/light", grade)
	_stackable(paint, "vertex/paint", grade)
	out.append(vertex)
	# Overlay paint layers (the set being edited): what the brush paints into, with masks.
	var layers := data.active_layers()
	if not layers.is_empty():
		var ov := _node(&"overlays", "Overlays", "Overlay paint layers of set \"%s\" (dirt, moss, grime...): pick one and paint with Paint on. Layers are added and set up in the Paint panel." % data.layer_set_name(data.edit_set))
		for i in layers.size():
			var l: PaintLayer = layers[i]
			if l == null:
				continue
			var n := _node(&"overlay", l.name if l.name != "" else "Overlay %d" % (i + 1), "%s · %s%s" % [
				l.texture.resource_path.get_file().get_basename() if l.texture else "shade (no texture)",
				PaintLayer.Blend.keys()[l.blend].capitalize(), "" if l.enabled else " · off"])
			n.paint = i + 1
			ov.children.append(n)
		out.append(ov)
	# Decals: images placed on the surfaces (Place decals in their panel).
	var dn := _node(&"decals", "Decals", "Images placed on the surfaces (posters, cracks, stains, a pattern under a door): projected onto the faces under them, lit like them, baked into the build. Select this to place them.")
	for i in data.decals.size():
		var d: LevelDecal = data.decals[i]
		if d == null:
			continue
		var c := _node(&"decal", d.title(), "%.2f × %.2f m · %d° · depth %.2f m. Drag it over the surfaces (Paint off); R / Shift+R turn it, [ ] size it, Delete removes it." % [
			d.size.x, d.size.y, roundi(d.rotation), d.depth])
		c.decal = i
		dn.children.append(c)
	out.append(dn)
	# Base textures and their variants (looks), grouped.
	var bases := {}  # base -> {ids: [], variants: [[id, look]]}
	for i in data.textures.size():
		var t: Texture2D = data.textures[i]
		if t == null or t is N64StairTexture:
			continue
		var base := TextureLook.source_of(t)
		if base == null:
			continue
		if not bases.has(base):
			bases[base] = {ids = PackedInt32Array(), variants = []}
		if t is TextureLook and ((t as TextureLook).adjust != null or (t as TextureLook).recolour or not (t as TextureLook).palette.is_empty() \
				or (grade and grade.stacks.has(t))):
			bases[base].variants.append([i, t])
		else:
			bases[base].ids.append(i)
	var groups := {}
	for base: Texture2D in bases:
		var g := group_of(base)
		if not groups.has(g):
			groups[g] = []
		groups[g].append(base)
	# Textures drawn outside the texture list (stairs, overlays, grass, scatter): layers too.
	var extras := extra_textures(data)
	for t: Texture2D in extras:
		if bases.has(t):
			continue
		var g := group_of(t)
		if not groups.has(g):
			groups[g] = []
		groups[g].append(t)
		bases[t] = {ids = PackedInt32Array(), variants = [], extra = extras[t].uses}
	var names := groups.keys()
	names.sort()
	for g in names:
		var gnode := _node(&"group", g, "")
		var g_ids := PackedInt32Array()
		var list: Array = groups[g]
		list.sort_custom(func(a, b): return a.resource_path.get_file() < b.resource_path.get_file())
		for base: Texture2D in list:
			var e: Dictionary = bases[base]
			var tnode := _node(&"texture", base.resource_path.get_file().get_basename(), "")
			var adj: ColourAdjust = data.base_adjusts.get(base)
			if adj and not adj.is_identity():
				tnode.children.append(_node(&"legacy", "Colour adjust (Paint panel)", "Still applied by the level shader. Select the texture layer and use \"Move Paint panel adjusts here\" to make it a filter."))
			var all_ids: PackedInt32Array = e.ids.duplicate()
			var vn := 1
			for v in e.variants:
				if counts.get(v[0], 0) == 0:
					continue  # (a variant no face uses any more)
				var vnode := _node(&"variant", "Variant %d" % vn, "")
				vn += 1
				vnode.ids = PackedInt32Array([v[0]])
				vnode.faces = counts.get(v[0], 0)
				var look: TextureLook = v[1]
				var what := []
				if look.adjust and not look.adjust.is_identity():
					what.append("colour adjusted")
				if look.recolour:
					what.append("recoloured")
				if not look.palette.is_empty():
					what.append("palette")
				vnode.info = "%s on %d faces (its own copy of %s). Shows %s's filters, then its own." % [", ".join(what) if not what.is_empty() else "look", vnode.faces, tnode.name, tnode.name]
				_stackable(vnode, look, grade)
				tnode.children.append(vnode)
				all_ids.append(v[0])
			tnode.faces = _sum(counts, all_ids)
			var uses: Array = e.get("extra", extras[base].uses if extras.has(base) else [])
			if tnode.faces == 0 and uses.is_empty():
				continue  # (in the texture list, but on no face)
			# (selecting a texture layer highlights its variants' faces too)
			tnode.ids = all_ids
			_stackable(tnode, base, grade)
			tnode.info = "%s · %d×%d · %d faces%s%s\n%s" % [g, base.get_width(), base.get_height(), tnode.faces,
				" · colour adjusted (Paint panel)" if adj and not adj.is_identity() else "",
				(" · also drawn by: " + ", ".join(uses)) if not uses.is_empty() else "", base.resource_path]
			g_ids.append_array(all_ids)
			gnode.children.append(tnode)
		if gnode.children.is_empty():
			continue
		gnode.ids = g_ids
		gnode.faces = _sum(counts, g_ids)
		gnode.info = "%d texture%s · %d faces. Group filters apply to every texture here (over their own filters)." % [
			gnode.children.size(), "" if gnode.children.size() == 1 else "s", gnode.faces]
		_stackable(gnode, ZoneGrade.group_key(g), grade)
		out.append(gnode)
	return out


## Textures the zone draws outside its texture list: stairs' bases, overlay layers'
## textures, the grass carpet / tufts, scatter sets. texture -> {uses: [String],
## tint: [] or the combiner tint to grade in first (PaintAtlas.texture_tint form)}.
static func extra_textures(data: LevelData) -> Dictionary:
	var out := {}
	var add := func(t: Texture2D, use: String, tint: Array) -> void:
		if t == null or t is N64StairTexture:
			return
		if not out.has(t):
			out[t] = {uses = [], tint = tint}
		if not use in out[t].uses:
			out[t].uses.append(use)
	for t in data.textures:
		if t is N64StairTexture and (t as N64StairTexture).base:
			var b := (t as N64StairTexture).base
			add.call(b, "stairs", _tint_or_none(PaintAtlas.texture_tint(b, data.base_tints.get(b))))
	for s in data.layer_set_count():
		for l in data.layers_of(s):
			if l and l.texture:
				add.call(l.texture, "overlay", _tint_or_none(PaintAtlas.texture_tint(l.texture,
					PackedColorArray([l.tint_dark, l.tint_light]) if l.override_tint else null)))
	for d in data.decals:
		if d and d.texture:
			add.call(d.texture, "decal", _tint_or_none(PaintAtlas.texture_tint(d.texture, data.base_tints.get(d.texture))))
	if data.grass and data.grass.enabled:
		for t in [data.grass.top_texture, data.grass.side_texture, data.grass.rim_texture, data.grass.tuft_texture]:
			add.call(t, "grass", [])
	for sc in data.scatter:
		if sc and sc.texture:
			add.call(sc.texture, "scatter", [])
	return out


static func _tint_or_none(t: Array) -> Array:
	return t if t[0] > 0.5 else []


## Unique textures the zone shows (bases + variants), for the texture budget.
static func texture_count(data: LevelData) -> int:
	var seen := {}
	for t in data.textures:
		if t and not t is N64StairTexture:
			seen[t] = true
	return seen.size()


static func _node(kind: StringName, name: String, info: String) -> Dictionary:
	return {kind = kind, name = name, info = info, ids = PackedInt32Array(), faces = 0, children = [], key = null, filter = null, paint = null, ao_id = -1, decal = -1}


## Makes `n` a layer that takes filters (stack `key`), its filters listed first, top first.
static func _stackable(n: Dictionary, key: Variant, grade: ZoneGrade) -> void:
	n.key = key
	if grade == null:
		return
	# (filters from a shared grade under this one: counted in the layer's info)
	var inh := grade.inherited(key).size() if grade.shared_grade() else 0
	if inh > 0:
		n.info += " · +%d shared filter%s under these" % [inh, "" if inh == 1 else "s"]
	var list := grade.filters(key)
	for i in range(list.size() - 1, -1, -1):
		var f: GradeFilter = list[i]
		if f == null:
			continue
		var fn := _node(&"filter", f.title(), "%s · %s · %d%%%s" % [f.title(), GradeFilter.Blend.keys()[f.blend].capitalize(), roundi(f.opacity * 100.0), "" if f.enabled else " · off"])
		fn.filter = f
		fn.key = key
		fn.ids = n.ids
		n.children.insert(list.size() - 1 - i, fn)


static func _sum(counts: Dictionary, ids: PackedInt32Array) -> int:
	var n := 0
	for id in ids:
		n += counts.get(id, 0)
	return n


static func _any_not_white(cols: PackedColorArray) -> bool:
	for c in cols:
		if not c.is_equal_approx(Color.WHITE):
			return true
	return false
