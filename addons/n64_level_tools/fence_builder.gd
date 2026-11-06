@tool
extends RefCounted
## Builds a Fence's level brushes (OoT / MM style) from flat, double-sided cutout quads with
## their textures fitted exactly (LevelBrush.corner_uvs): a panel per span (the panel texture
## repeated along it in whole repeats), crossed quads per post (extra posts keep spans under
## the style's max spacing), end-cap posts at the path's ends and beside openings, an arch
## over each opening, and an invisible collision wall per closed span. One brush per part
## (panels, posts, caps, arches, collision), in level space.

## `points`: post positions (level-local) in path order; `open_spans`: spans (between
## points i and i + 1) left open. `tex`: {panel, post, cap, arch} texture indices (-1 =
## none); `tiles`: their metres per repeat (the shader divides UVs by it); `aspects`: their
## width / height. Returns [panels, posts, caps, arches, collision] (null where empty).
static func build(points: PackedVector3Array, closed: bool, open_spans: PackedInt32Array,
		style: FenceStyle, tex: Dictionary, tiles := {}, aspects := {}, spacing := 0.0) -> Array:
	var parts := _parts(points, closed, open_spans, style, tex, tiles, aspects, spacing)
	if parts.is_empty():
		return []
	return [parts[0].brush(tex.get("panel", -1), LevelBrush.BakeMode.VISUAL_ONLY),
		parts[1].brush(tex.get("post", -1), LevelBrush.BakeMode.VISUAL_ONLY),
		parts[2].brush(tex.get("cap", -1), LevelBrush.BakeMode.VISUAL_ONLY),
		parts[3].brush(tex.get("arch", -1), LevelBrush.BakeMode.VISUAL_ONLY),
		parts[4].brush(-1, LevelBrush.BakeMode.COLLISION_ONLY, false)]


## The whole fence as one brush's data: {vertices, faces, corner_uvs, textures (per face),
## bake (per face: 1 visual only, 2 collision only)}, or {} when there's nothing to build.
## `ground`: (point) -> ground height under it (float) or null; every post stands on it
## (else on the points / the straight lines between them). `sag`: metres the
## posts between the points sink at the middle of each section (a rickety, droopy look).
static func build_data(points: PackedVector3Array, closed: bool, open_spans: PackedInt32Array,
		style: FenceStyle, tex: Dictionary, tiles := {}, aspects := {}, spacing := 0.0, ground := Callable(),
		sag := 0.0) -> Dictionary:
	var parts := _parts(points, closed, open_spans, style, tex, tiles, aspects, spacing, ground, sag)
	if parts.is_empty():
		return {}
	var out := {vertices = PackedVector3Array(), faces = [] as Array[PackedInt32Array], corner_uvs = PackedVector2Array(),
		textures = PackedInt32Array(), bake = PackedByteArray()}
	var keys := ["panel", "post", "cap", "arch", ""]
	for i in parts.size():
		var q: _Quads = parts[i]
		var t: int = tex.get(keys[i], -1) if keys[i] != "" else -1
		if i < 4 and t < 0:
			continue  # no texture: that part isn't drawn
		var base: int = out.vertices.size()
		out.vertices.append_array(q.verts)
		for f in q.faces:
			var shifted := PackedInt32Array()
			for v in f:
				shifted.append(v + base)
			out.faces.append(shifted)
			out.textures.append(t)
			out.bake.append(2 if i == 4 else 1)
		if i < 4:
			out.corner_uvs.append_array(q.uvs)
		else:
			for k in q.verts.size():
				out.corner_uvs.append(Vector2.ZERO)
	return out if not out.faces.is_empty() else {}


## Panels, posts, caps, arches, collision as _Quads ([] when there's nothing to build).
## `spacing` > 0: posts exactly that far apart along each section (the last span takes
## what's left); otherwise the style's post spacing, spans evened out.
static func _parts(points: PackedVector3Array, closed: bool, open_spans: PackedInt32Array,
		style: FenceStyle, tex: Dictionary, tiles: Dictionary, aspects: Dictionary, spacing: float, ground := Callable(),
		sag := 0.0) -> Array:
	var n := points.size()
	if n < 2 or style == null:
		return []
	# Posts along the path (long spans split) and the segments between them.
	# Every post on the ground under it when there is one (`ground`), so the fence stands
	# on the floor however its points / brush sit; the in-between ones sag (`sag`).
	var grounded := func(p: Vector3) -> Vector3:
		if ground.is_valid():
			var gy = ground.call(p)
			if gy != null:
				p.y = gy
		return p
	var posts := PackedVector3Array([grounded.call(points[0])])
	var segs: Array = []  # [post a, post b, open]
	var spans := n - 1 + (1 if closed and n > 2 else 0)
	for i in spans:
		var a := points[i]
		var b := points[(i + 1) % n]
		var length := Vector2(b.x - a.x, b.z - a.z).length()
		# Where the posts along this section go (fractions of it, the end last).
		var cuts := PackedFloat32Array()
		if spacing > 0.0:
			var d := spacing
			while d < length - spacing * 0.15:
				cuts.append(d / length)
				d += spacing
		else:
			var k := maxi(1, ceili(length / style.max_spacing - 0.001))
			for s in range(1, k):
				cuts.append(float(s) / k)
		cuts.append(1.0)
		var open := i in open_spans
		for s in cuts.size():
			var from := posts.size() - 1
			var to: int
			if closed and n > 2 and i == spans - 1 and s == cuts.size() - 1:
				to = 0
			else:
				var p: Vector3 = grounded.call(a.lerp(b, cuts[s]))
				if s < cuts.size() - 1:
					p.y -= sag * sin(PI * cuts[s])
				posts.append(p)
				to = posts.size() - 1
			segs.append([from, to, open])

	var ground_max := -INF
	for p in posts:
		ground_max = maxf(ground_max, p.y)
	# Panel base height at each end of a segment (ground under the panel), per slope mode.
	var base := func(seg: Array, at_a: bool) -> float:
		var ga: float = posts[seg[0]].y
		var gb: float = posts[seg[1]].y
		match style.slope_mode:
			FenceStyle.SlopeMode.STEPPED:
				return maxf(ga, gb)
			FenceStyle.SlopeMode.LEVEL:
				return ground_max
		return ga if at_a else gb

	var has_arch: bool = tex.get("arch", -1) >= 0
	var arch_top := style.arch_clearance + style.arch_height
	# Per post: closed spans touching it, spans touching it, beside an opening; its base
	# (highest panel base around it) and its direction (for the crossed quads).
	var closed_deg := PackedInt32Array()
	var all_deg := PackedInt32Array()
	var by_open := PackedByteArray()
	var post_base := PackedFloat32Array()
	var dirs := []  # per post: the directions of the sections meeting it (one per line)
	for arr in [closed_deg, all_deg, by_open]:
		arr.resize(posts.size())
	post_base.resize(posts.size())
	for j in posts.size():
		dirs.append([])
	for j in posts.size():
		post_base[j] = -INF
	for seg in segs:
		var d := Vector3(posts[seg[1]].x - posts[seg[0]].x, 0.0, posts[seg[1]].z - posts[seg[0]].z).normalized()
		for end in [0, 1]:
			var j: int = seg[end]
			all_deg[j] += 1
			if d.length_squared() > 1e-8 and not dirs[j].any(func(o: Vector3) -> bool: return absf(o.dot(d)) > 0.985):
				dirs[j].append(d)
			post_base[j] = maxf(post_base[j], base.call(seg, end == 0))
			if seg[2]:
				by_open[j] = 1
			else:
				closed_deg[j] += 1

	var panels := _Quads.new()
	var post_q := _Quads.new()
	var cap_q := _Quads.new()
	var arch_q := _Quads.new()
	var wall := _Quads.new()

	# Posts: crossed quads, along the fence and across it. Caps at path ends / openings.
	var has_post: bool = tex.get("post", -1) >= 0
	var has_cap: bool = tex.get("cap", -1) >= 0
	# Half width of each drawn post: panels and arches stop at its edge, so they never lie
	# in the plane of its lengthwise quad (z-fighting) where they'd overlap.
	var post_hw := PackedFloat32Array()
	post_hw.resize(posts.size())
	for j in posts.size():
		var arched: bool = by_open[j] == 1 and has_arch
		if closed_deg[j] == 0 and not arched:
			continue
		var cap: bool = by_open[j] == 1 or all_deg[j] == 1
		var use_cap := cap and has_cap
		if not use_cap and not has_post:
			continue
		var h := style.post_height
		if cap and style.end_cap_height > 0.0:
			h = style.end_cap_height
		var top: float = post_base[j] + h
		if arched:
			top = maxf(top, post_base[j] + arch_top)
		var faces_along: Array = dirs[j] if not dirs[j].is_empty() else [Vector3.RIGHT]
		var d: Vector3 = faces_along[0]
		var c := posts[j]
		var q := cap_q if use_cap else post_q
		var tile: float = tiles.get("cap" if use_cap else "post", 1.0)
		var aspect: float = aspects.get("cap" if use_cap else "post", 1.0)
		var width := style.end_cap_width if use_cap and style.end_cap_width > 0.0 else style.post_width
		# The post body (an end cap's is the post: only its top block is wider).
		post_hw[j] = style.post_width * 0.5
		# One quad along each section meeting the post, so every panel ends flush against a
		# post face in its own plane (corners: one per side, no gap). A lone end cap gets a
		# crossed one too (seen end-on); straight posts just the one.
		if faces_along.size() == 1 and use_cap:
			faces_along = [d, Vector3(-d.z, 0.0, d.x)]
		for w: Vector3 in faces_along:
			var hw := w * width * 0.5
			q.quad(Vector3(c.x, top, c.z) - hw, Vector3(c.x, top, c.z) + hw,
				Vector3(c.x, c.y - style.post_sink, c.z) + hw, Vector3(c.x, c.y - style.post_sink, c.z) - hw, 1.0, 1.0, tile, aspect)

	# Panels on closed spans (whole texture repeats), arches over openings, collision.
	var panel_tile: float = tiles.get("panel", 1.0)
	var arch_tile: float = tiles.get("arch", 1.0)
	var repeat_w: float = style.panel_height * aspects.get("panel", 1.0)
	for seg in segs:
		var a: Vector3 = posts[seg[0]]
		var b: Vector3 = posts[seg[1]]
		var ba: float = base.call(seg, true)
		var bb: float = base.call(seg, false)
		var col_a := a
		var col_b := b
		var col_ba := ba
		var col_bb := bb
		# Trimmed to the posts' edges (heights follow along the span).
		var span := Vector2(b.x - a.x, b.z - a.z).length()
		if span > 1e-4:
			var t0 := clampf(post_hw[seg[0]] / span, 0.0, 0.45)
			var t1 := 1.0 - clampf(post_hw[seg[1]] / span, 0.0, 0.45)
			var na := a.lerp(b, t0)
			var nb := a.lerp(b, t1)
			var nba := lerpf(ba, bb, t0)
			var nbb := lerpf(ba, bb, t1)
			a = na
			b = nb
			ba = nba
			bb = nbb
		if seg[2]:
			if has_arch:
				arch_q.quad(Vector3(a.x, ba + arch_top, a.z), Vector3(b.x, bb + arch_top, b.z),
					Vector3(b.x, bb + style.arch_clearance, b.z), Vector3(a.x, ba + style.arch_clearance, a.z), 1.0, 1.0, arch_tile,
					aspects.get("arch", 1.0))
			continue
		if tex.get("panel", -1) >= 0:
			var lo := style.panel_lift
			var length := Vector2(b.x - a.x, b.z - a.z).length()
			var reps := maxf(1.0, roundf(length / maxf(repeat_w, 0.01)))
			panels.quad(Vector3(a.x, ba + lo + style.panel_height, a.z), Vector3(b.x, bb + lo + style.panel_height, b.z),
				Vector3(b.x, bb + lo, b.z), Vector3(a.x, ba + lo, a.z), reps, 1.0, panel_tile, aspects.get("panel", 1.0))

	if style.collision != FenceStyle.Collision.NONE:
		_walls(wall, posts, segs, base, style)
	return [panels, post_q, cap_q, arch_q, wall]


## Collision: one slab per run of closed sections, `collision_thickness` thick, mitred at
## the posts (no inside edges for the player to catch on while sliding along), its faces
## pointing out (the level's collision is one-sided), ends capped where a run stops.
static func _walls(wall: _Quads, posts: PackedVector3Array, segs: Array, base: Callable, style: FenceStyle) -> void:
	var ch := maxf(style.panel_height + style.panel_lift, style.post_height) if style.collision == FenceStyle.Collision.FULL \
		else style.low_collision_height
	var half := style.collision_thickness * 0.5
	# Runs: consecutive closed sections (a closed fence with no openings: one loop).
	var runs := []
	var cur := []
	for seg in segs:
		if seg[2]:
			if not cur.is_empty():
				runs.append(cur)
			cur = []
			continue
		if not cur.is_empty() and cur[-1][1] != seg[0]:
			runs.append(cur)
			cur = []
		cur.append(seg)
	if not cur.is_empty():
		runs.append(cur)
	if runs.size() > 1 and runs[-1][-1][1] == runs[0][0][0]:
		runs[-1].append_array(runs[0])  # the last run continues into the first
		runs.remove_at(0)
	for run: Array in runs:
		var loop: bool = run[-1][1] == run[0][0]
		var dirs := []
		for seg in run:
			var d := Vector3(posts[seg[1]].x - posts[seg[0]].x, 0.0, posts[seg[1]].z - posts[seg[0]].z)
			dirs.append(d.normalized() if d.length_squared() > 1e-8 else Vector3.RIGHT)
		# Mitred offset at the start of each section (and the run's last post).
		var offs := []
		for i in run.size() + 1:
			var prev: Vector3 = dirs[i - 1] if i > 0 else (dirs[-1] if loop else dirs[0])
			var next: Vector3 = dirs[i] if i < run.size() else (dirs[0] if loop else dirs[-1])
			var n1 := Vector3(-prev.z, 0.0, prev.x)
			var n2 := Vector3(-next.z, 0.0, next.x)
			var n := (n1 + n2).normalized() if (n1 + n2).length_squared() > 1e-6 else n2
			offs.append(n * half / maxf(n.dot(n2), 0.35))
		for i in run.size():
			var seg: Array = run[i]
			var a := posts[seg[0]]
			var b := posts[seg[1]]
			var ta: float = base.call(seg, true) + ch
			var tb: float = base.call(seg, false) + ch
			var ba := minf(a.y, ta - ch) - 0.1
			var bb := minf(b.y, tb - ch) - 0.1
			var oa: Vector3 = offs[i]
			var ob: Vector3 = offs[i + 1]
			var la := Vector3(a.x, 0, a.z) + oa
			var ra := Vector3(a.x, 0, a.z) - oa
			var lb := Vector3(b.x, 0, b.z) + ob
			var rb := Vector3(b.x, 0, b.z) - ob
			var centre := Vector3((a.x + b.x) * 0.5, (ba + ta + bb + tb) * 0.25, (a.z + b.z) * 0.5)
			var at := func(p: Vector3, y: float) -> Vector3: return Vector3(p.x, y, p.z)
			wall.quad_out(at.call(la, ba), at.call(lb, bb), at.call(lb, tb), at.call(la, ta), centre)
			wall.quad_out(at.call(ra, ba), at.call(rb, bb), at.call(rb, tb), at.call(ra, ta), centre)
			wall.quad_out(at.call(la, ta), at.call(lb, tb), at.call(rb, tb), at.call(ra, ta), centre)
			if i == 0 and not loop:
				wall.quad_out(at.call(la, ba), at.call(ra, ba), at.call(ra, ta), at.call(la, ta), centre)
			if i == run.size() - 1 and not loop:
				wall.quad_out(at.call(lb, bb), at.call(rb, bb), at.call(rb, tb), at.call(lb, tb), centre)
			# Stepped sections: close the step to the next section's top.
			if i < run.size() - 1:
				var tn: float = base.call(run[i + 1], true) + ch
				if absf(tn - tb) > 1e-3:
					var lo := minf(tn, tb)
					var hi := maxf(tn, tb)
					# Faces the lower section: away from a point on the higher side.
					var step_dir: Vector3 = dirs[i] if tb < tn else -dirs[i]
					wall.quad_out(at.call(lb, lo), at.call(rb, lo), at.call(rb, hi), at.call(lb, hi),
						Vector3(b.x, (lo + hi) * 0.5, b.z) + step_dir)


class _Quads:
	var verts := PackedVector3Array()
	var faces: Array[PackedInt32Array] = []
	var uvs := PackedVector2Array()

	## Quad top-left, top-right, bottom-right, bottom-left; the texture spans `reps_u` x
	## `reps_v` repeats over it. UVs in metres as the shader reads them: `tile` metres per
	## repeat across the texture's width, its height `tile / aspect` (square texels).
	func quad(tl: Vector3, tr: Vector3, br: Vector3, bl: Vector3, reps_u: float, reps_v: float, tile: float,
			aspect := 1.0) -> void:
		var i := verts.size()
		verts.append_array([tl, tr, br, bl])
		faces.append(PackedInt32Array([i, i + 1, i + 2, i + 3]))
		var size := Vector2(tile, tile / maxf(aspect, 0.001))
		uvs.append_array([Vector2(0.0, 0.0), Vector2(reps_u, 0.0), Vector2(reps_u, reps_v), Vector2(0.0, reps_v)].map(
			func(t: Vector2) -> Vector2: return t * size))

	## Quad with its normal pointing away from `centre` (no UVs: collision).
	func quad_out(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, centre: Vector3) -> void:
		var n := (p1 - p0).cross(p2 - p0) + (p2 - p0).cross(p3 - p0)
		var i := verts.size()
		verts.append_array([p0, p1, p2, p3])
		if n.dot((p0 + p1 + p2 + p3) * 0.25 - centre) < 0.0:
			faces.append(PackedInt32Array([i + 3, i + 2, i + 1, i]))
		else:
			faces.append(PackedInt32Array([i, i + 1, i + 2, i + 3]))
		uvs.append_array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])

	## Collision slab from `a` to `b` (bottom points) up to tops `ta` / `tb`, half thickness `w`.
	func box(a: Vector3, b: Vector3, ta: float, tb: float, w: Vector3) -> void:
		var bot := [a - w, b - w, b + w, a + w]
		var top := [Vector3(a.x, ta, a.z) - w, Vector3(b.x, tb, b.z) - w, Vector3(b.x, tb, b.z) + w, Vector3(a.x, ta, a.z) + w]
		for k in 4:
			var i := verts.size()
			verts.append_array([bot[k], bot[(k + 1) % 4], top[(k + 1) % 4], top[k]])
			faces.append(PackedInt32Array([i, i + 1, i + 2, i + 3]))
		for ring in [top, bot]:
			var i := verts.size()
			verts.append_array(ring)
			faces.append(PackedInt32Array([i, i + 1, i + 2, i + 3]))

	func brush(texture: int, bake_mode: LevelBrush.BakeMode, cutout := true) -> LevelBrush:
		if faces.is_empty() or (cutout and texture < 0):
			return null
		var b := LevelBrush.new()
		b.vertices = verts
		b.set_faces(faces)
		b.hand_edited = true
		b.bake_mode = bake_mode
		b.cutout = cutout
		if cutout:
			b.corner_uvs = uvs
		if texture >= 0:
			var t := PackedInt32Array()
			t.resize(b.get_face_count())
			t.fill(texture)
			b.face_textures = t
		return b
