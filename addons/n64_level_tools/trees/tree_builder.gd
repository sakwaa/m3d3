@tool
class_name TreeBuilder
## Grows a tree mesh from a TreeSpecies and a seed (same seed, same tree). Weber & Penn
## style: a trunk, then each TreeLevel's stems off the level before (spiral or whorls, at
## the level's angle, bending up or drooping, longest where the crown's outline says),
## each a low-poly tapered tube; leaf cards on the last level's stems (and the tips of the
## level before). N64 style lighting baked into the vertex colours: the leaf cards are
## shaded by where they sit in the crown (normals bent out from its middle, darker inside)
## so the crown reads as one soft mass. Vertex alpha = wind sway weight (n64_tree shader).
## Two surfaces: bark (0) and leaves (1).

const SHADER := preload("res://addons/n64_runtime/shaders/n64_tree.gdshader")
## Light the vertex colours are baked for (from the top left, like the level's key light).
const SUN := Vector3(-0.45, 0.8, 0.4)
## Metres of bark per texture repeat.
const BARK_TILE := 1.5


class Stem:
	var points := PackedVector3Array()
	var radii := PackedFloat32Array()
	var length := 0.0
	var level := 0
	var sides := 4
	var bark := true

	## Point and direction `t` (0..1) along the stem.
	func at(t: float) -> Array:
		var n := points.size() - 1
		var f := clampf(t, 0.0, 1.0) * n
		var i := mini(int(f), n - 1)
		var k := f - i
		var d := (points[i + 1] - points[i]).normalized()
		return [points[i].lerp(points[i + 1], k), d, lerpf(radii[i], radii[i + 1], k)]


class Buf:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var index := PackedInt32Array()

	func add(v: Vector3, n: Vector3, uv: Vector2) -> int:
		verts.append(v)
		normals.append(n)
		uvs.append(uv)
		colors.append(Color(1, 1, 1, 1))
		return verts.size() - 1

	func tri(a: int, b: int, c: int) -> void:
		index.append_array([a, b, c])

	func arrays() -> Array:
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = verts
		a[Mesh.ARRAY_NORMAL] = normals
		a[Mesh.ARRAY_TEX_UV] = uvs
		a[Mesh.ARRAY_COLOR] = colors
		a[Mesh.ARRAY_INDEX] = index
		return a


## The tree for `species` and `seed`: an ArrayMesh with bark and leaf surfaces.
static func build(species: TreeSpecies, seed: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var sp := species
	var h := sp.height * (1.0 + rng.randf_range(-1.0, 1.0) * sp.height_var)
	var stems: Array[Stem] = []
	# Trunk: from just under the ground, leaning a little, out to trunk_top.
	var lean_dir := Vector3.UP.rotated(Vector3.FORWARD.rotated(Vector3.UP, rng.randf() * TAU), deg_to_rad(sp.lean * rng.randf()))
	var trunk := _grow(Vector3.DOWN * 0.3, lean_dir, h * sp.trunk_top + 0.3, sp.trunk_radius, sp.trunk_radius * sp.trunk_taper,
		sp.segments, 0.0, 1.0, sp.wander, rng)
	trunk.sides = sp.sides
	trunk.level = 0
	stems.append(trunk)
	var parents: Array[Stem] = [trunk]
	var levels: Array[Array] = [[trunk]]
	for li in sp.levels.size():
		var L: TreeLevel = sp.levels[li]
		var kids: Array[Stem] = []
		for p in parents:
			kids.append_array(_children(sp, L, li + 1, p, h, rng))
		stems.append_array(kids)
		levels.append(kids)
		parents = kids
	# Leaves: along the last level's stems, plus the tips of the level before.
	var cards: Array = []  # [centre, quad corners (4 Vector3), sway at the top / bottom]
	var last: Array = levels[levels.size() - 1]
	for s: Stem in last:
		_leaves_on(sp, s, sp.clumps, sp.leaf_start, cards, rng)
	if levels.size() >= 3:
		var inner_from := 0.45 if sp.cards == TreeSpecies.Cards.HANGING else 0.85
		for s: Stem in levels[levels.size() - 2]:
			_leaves_on(sp, s, sp.inner_clumps, inner_from, cards, rng)
	# The crown: an ellipsoid round the leaf cards (for shading).
	var c := Vector3.ZERO
	for card in cards:
		c += card[0]
	c = c / maxf(cards.size(), 1)
	var radii := Vector3(0.5, 0.5, 0.5)
	for card in cards:
		var d: Vector3 = (card[0] - c).abs()
		radii = radii.max(d)
	radii *= 1.1
	var sun := SUN.normalized()
	var bark := Buf.new()
	for s in stems:
		if s.bark:
			_tube(bark, s, h, c, radii, sun, sp)
	var leaves := Buf.new()
	for card in cards:
		_card(leaves, card, c, radii, sun, sp)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, bark.arrays())
	mesh.surface_set_material(0, _material(sp.bark_texture, sp.bark_color, false))
	if not leaves.verts.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, leaves.arrays())
		mesh.surface_set_material(1, _material(sp.leaf_texture, sp.leaf_color, true))
	return mesh


## Triangles in a mesh (all surfaces).
static func triangles(mesh: ArrayMesh) -> int:
	var n := 0
	for i in mesh.get_surface_count():
		n += (mesh.surface_get_arrays(i)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	return n


static func _material(texture: Texture2D, color: Color, cutout: bool) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter(&"tex", texture)
	m.set_shader_parameter(&"cutout", cutout)
	m.set_shader_parameter(&"color", color)
	m.set_shader_parameter(&"shade", 1.0)
	if not cutout:
		m.set_shader_parameter(&"wind", 0.15)
	return m


## A stem from `from` along `dir`: `segments` pieces, radius r0 -> r1, bending `curve`
## degrees towards the sky (- = drooping; `power` puts it towards the tip), wandering.
static func _grow(from: Vector3, dir: Vector3, length: float, r0: float, r1: float, segments: int,
		curve: float, power: float, wander: float, rng: RandomNumberGenerator) -> Stem:
	var s := Stem.new()
	s.length = length
	var p := from
	var d := dir.normalized()
	s.points.append(p)
	s.radii.append(r0)
	var seg := length / segments
	for k in segments:
		var bend := deg_to_rad(curve) * (pow(float(k + 1) / segments, power) - pow(float(k) / segments, power))
		var axis := d.cross(Vector3.UP)
		if axis.length() > 0.001 and bend != 0.0:
			if bend > 0.0:
				bend = minf(bend, d.angle_to(Vector3.UP))
			d = d.rotated(axis.normalized(), bend)
		if wander > 0.0:
			var w := _perp(d).rotated(d, rng.randf() * TAU)
			d = d.rotated(w, deg_to_rad(rng.randf_range(-wander, wander)))
		p += d * seg
		s.points.append(p)
		s.radii.append(lerpf(r0, r1, float(k + 1) / segments))
	return s


## Some direction at right angles to `d`.
static func _perp(d: Vector3) -> Vector3:
	var o := Vector3.UP if absf(d.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	return d.cross(o).normalized()


static func _children(sp: TreeSpecies, L: TreeLevel, level: int, parent: Stem, h: float, rng: RandomNumberGenerator) -> Array[Stem]:
	var out: Array[Stem] = []
	# Where along the parent: level 1 starts at the crown's base (clear), measured on the
	# trunk's own length.
	var t0 := L.start
	var t1 := L.end
	if level == 1:
		var trunk_len := parent.length
		t0 = clampf((sp.clear * h + 0.3) / trunk_len, 0.0, 0.98)
		t1 = maxf(t0, L.end)
	var spots: Array = []  # [t, azimuth]
	if L.whorls > 0:
		for w in L.whorls:
			var t := lerpf(t0, t1, float(w) / maxf(L.whorls - 1, 1))
			var off := rng.randf() * TAU
			for k in L.count:
				spots.append([t, off + TAU * k / L.count + rng.randf_range(-0.2, 0.2)])
	else:
		for k in L.count:
			var t := lerpf(t0, t1, (k + 0.5) / L.count + rng.randf_range(-0.3, 0.3) / L.count)
			spots.append([t, deg_to_rad(137.5) * k + rng.randf_range(-0.4, 0.4)])
	for spot in spots:
		var a: Array = parent.at(spot[0])
		var p: Vector3 = a[0]
		var d: Vector3 = a[1]
		var pr: float = a[2]
		var q := _perp(d).rotated(d, spot[1])
		var ang := deg_to_rad(L.angle + rng.randf_range(-L.angle_var, L.angle_var))
		var dir := (d * cos(ang) + q * sin(ang)).normalized()
		var len: float
		if level == 1:
			# The crown's outline over the limbs' span of the trunk (0 lowest .. 1 highest).
			var crown_pos := clampf((float(spot[0]) - t0) / maxf(t1 - t0, 0.01), 0.0, 1.0)
			len = L.length * h * sp.crown_ratio(crown_pos)
		else:
			len = L.length * parent.length * (1.0 - 0.5 * float(spot[0]))
		len *= 1.0 + rng.randf_range(-L.length_var, L.length_var)
		if len < 0.2:
			continue
		var r0 := minf(pr * L.radius, pr * 0.9)
		var s := _grow(p - d * 0.0, dir, len, r0, maxf(r0 * 0.2, 0.015), L.segments, L.curve, L.curve_power, L.wander, rng)
		s.level = level
		s.sides = L.sides
		s.bark = L.bark
		out.append(s)
	return out


## Leaf cards along a stem: `n` clumps from `from` (0..1) out to the tip.
static func _leaves_on(sp: TreeSpecies, s: Stem, n: int, from: float, cards: Array, rng: RandomNumberGenerator) -> void:
	if n <= 0:
		return
	if sp.cards == TreeSpecies.Cards.SPRAYS:
		# Flat sprays lying along the stem, two crossed in an X about it.
		var k0 := int(floor(from * (s.points.size() - 1)))
		for i in range(k0, s.points.size() - 1):
			var a := s.points[i]
			var b := s.points[i + 1]
			var d := (b - a)
			var along := d.normalized()
			var t := float(i) / (s.points.size() - 1)
			var w := sp.card_size * (1.0 - 0.45 * t) * (1.0 + rng.randf_range(-sp.card_var, sp.card_var)) * 0.5
			var flat := along.cross(Vector3.UP)
			if flat.length() < 0.01:
				flat = Vector3.RIGHT
			flat = flat.normalized()
			var a2 := a - along * d.length() * 0.1
			var b2 := b + along * d.length() * 0.15
			for tilt in [-0.45, 0.45]:
				var side := flat.rotated(along, tilt) * w
				cards.append([(a2 + b2) * 0.5, [a2 - side, b2 - side, b2 + side, a2 + side], 0.7, 1.0])
		return
	for k in n:
		var t := lerpf(from, 1.0, (k + 0.5) / n) + rng.randf_range(-0.08, 0.08)
		var p: Vector3 = s.at(t)[0]
		var size := sp.card_size * (1.0 + rng.randf_range(-sp.card_var, sp.card_var))
		var yaw := rng.randf() * TAU
		if sp.cards == TreeSpecies.Cards.HANGING:
			# Streamers hang most of the way to the ground (a curtain), at most hang_length.
			var length := minf(sp.hang_length, p.y - 0.4 - rng.randf_range(0.0, 1.6))
			length *= 1.0 + rng.randf_range(-sp.hang_var, 0.0)
			if length < 0.6:
				continue
			for turn in [0.0, PI * 0.5]:
				var r := Vector3.RIGHT.rotated(Vector3.UP, yaw + turn) * size * 0.5
				var top := p + Vector3.UP * 0.2
				var bottom := p - Vector3.UP * length
				cards.append([(top + bottom) * 0.5, [top - r, top + r, bottom + r, bottom - r], 0.5, 1.0])
		else:
			# Clumps: two upright cards crossed and one lying nearly flat (fills the crown
			# seen from above or below), tipped a little at random.
			var tilt := Vector3.RIGHT.rotated(Vector3.UP, rng.randf() * TAU)
			var b := Basis(tilt, rng.randf_range(-0.35, 0.35)) * Basis(Vector3.UP, yaw)
			for turn in [0.0, PI * 0.5]:
				var r := b * Vector3.RIGHT.rotated(Vector3.UP, turn) * size * 0.5
				var u := b * Vector3.UP * size * 0.5
				cards.append([p, [p - r + u, p + r + u, p + r - u, p - r - u], 1.0, 1.0])
			var flat := b * Basis(Vector3.RIGHT, -PI * 0.5 + rng.randf_range(-0.3, 0.3))
			var fr := flat * Vector3.RIGHT * size * 0.5
			var fu := flat * Vector3.UP * size * 0.5
			cards.append([p, [p - fr + fu, p + fr + fu, p + fr - fu, p - fr - fu], 1.0, 1.0])


## How much light a point gets: the side facing the sun brighter, deep in the crown darker.
static func _crown_light(p: Vector3, n: Vector3, c: Vector3, radii: Vector3, sun: Vector3, sp: TreeSpecies, bent: float) -> float:
	var q := (p - c) / radii
	var depth := clampf(q.length(), 0.0, 1.0)
	var nn := n.lerp(q.normalized() if q.length() > 0.001 else n, bent).normalized()
	var lit := (1.0 - sp.shadow_side) + sp.shadow_side * (nn.dot(sun) * 0.5 + 0.5) * 1.15
	var ao := 1.0 - sp.crown_ao * (1.0 - depth) * (1.0 if q.length() < 1.0 else 0.0)
	return lit * ao


static func _tube(buf: Buf, s: Stem, h: float, c: Vector3, radii: Vector3, sun: Vector3, sp: TreeSpecies) -> void:
	var sides := s.sides
	var n := s.points.size()
	var base := buf.verts.size()
	var frame := _perp((s.points[1] - s.points[0]).normalized())
	var v_len := 0.0
	var circ := TAU * s.radii[0]
	var u_rep := maxf(1.0, roundf(circ / BARK_TILE))
	for i in n:
		var d := (s.points[mini(i + 1, n - 1)] - s.points[maxi(i - 1, 0)]).normalized()
		frame = (frame - d * frame.dot(d)).normalized()  # parallel transport
		var side := d.cross(frame)
		var r := s.radii[i]
		if i == 0 and s.level == 0:
			r += sp.root_flare
		if i > 0:
			v_len += s.points[i].distance_to(s.points[i - 1])
		for k in sides + 1:
			var a := TAU * k / sides
			var nrm := (frame * cos(a) + side * sin(a))
			var v := buf.add(s.points[i] + nrm * r, nrm, Vector2(u_rep * k / sides, v_len / BARK_TILE))
			var light := _crown_light(buf.verts[v], nrm, c, radii, sun, sp, 0.0)
			var sway := clampf(buf.verts[v].y / h, 0.0, 1.0)
			sway = sway * sway * (0.3 if s.level == 0 else 0.7)
			buf.colors[v] = Color(light, light, light, sway)
	for i in n - 1:
		for k in sides:
			var a := base + i * (sides + 1) + k
			var b := a + sides + 1
			buf.tri(a, b, a + 1)
			buf.tri(a + 1, b, b + 1)
	# Cap the tip.
	var tip := s.points[n - 1] + (s.points[n - 1] - s.points[n - 2]).normalized() * s.radii[n - 1] * 2.0
	var t := buf.add(tip, (tip - s.points[n - 2]).normalized(), Vector2(0.5, (v_len + 0.1) / BARK_TILE))
	buf.colors[t] = buf.colors[t - 1]
	var last := base + (n - 1) * (sides + 1)
	for k in sides:
		buf.tri(last + k, t, last + k + 1)


static func _card(buf: Buf, card: Array, c: Vector3, radii: Vector3, sun: Vector3, sp: TreeSpecies) -> void:
	var q: Array = card[1]
	var n: Vector3 = (q[1] - q[0]).cross(q[3] - q[0]).normalized()
	var uvs := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	var sways := [card[2], card[2], card[3], card[3]]
	var ids := []
	for i in 4:
		var v := buf.add(q[i], n, uvs[i])
		var light := _crown_light(q[i], n, c, radii, sun, sp, 0.85)
		buf.colors[v] = Color(light, light, light, sways[i])
		ids.append(v)
	buf.tri(ids[0], ids[1], ids[2])
	buf.tri(ids[0], ids[2], ids[3])
