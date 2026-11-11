@tool
extends RefCounted
## Build reports: what each level ships as (the build bake, ExportBake), measured for a
## person (summary.md) and for an agent to sanity-check (report.json): triangle / vertex /
## draw-call totals, per-chunk loads, the heaviest brushes, props, the worst camera views
## (sampled from the floors and spawn points, culled per chunk the way the game does, out to
## the zone's fog), and problems with where to find them. Budgets are project settings
## (n64/build/budget_*). Reports go to build_reports/ (never imported or exported).

const DIR := "res://build_reports/"
const VIEW_WARN := "n64/build/budget_view_tris"
const VIEW_HARD := "n64/build/budget_view_tris_hard"
const CHUNK_TRIS := "n64/build/budget_chunk_tris"
const DRAW_CALLS := "n64/build/budget_draw_calls"
const REPORT_ON_EXPORT := "n64/build/report_on_export"
const DEFAULTS := {VIEW_WARN: 6000, VIEW_HARD: 12000, CHUNK_TRIS: 2000, DRAW_CALLS: 150}

const EYE := 1.6  # metres above the floor
const FOV := 70.0
const ASPECT := 16.0 / 9.0
const SAMPLE_CELL := 8.0  # metres between sampled floor spots
const YAWS := 8
const SLIVER := 0.1  # metres: thinner faces are slivers


static func budgets() -> Dictionary:
	var out := {}
	for k in DEFAULTS:
		out[k.get_file()] = int(ProjectSettings.get_setting(k, DEFAULTS[k]))
	return out


## Everything about one built level. `root`: its LevelRoot holding the build copy (in a
## tree, so world transforms are right); `editor_data`: the level as edited; `stats`:
## LevelBaker's stats for the build; `scene`: the zone scene (fog, spawns, props).
static func level(root: LevelRoot, scene: Node, scene_path: String, editor_data: LevelData, stats: Dictionary,
		bake_ms: int) -> Dictionary:
	var b := budgets()
	var data := root.data
	var xf := root.global_transform
	var problems := []
	# Chunks (the baked meshes, culled one by one in the game).
	var chunks := []
	var meshes := data.baked_meshes()
	for i in meshes.size():
		var m := meshes[i]
		var box := xf * m.get_aabb()
		var tris := m.get_faces().size() / 3
		var r: Vector2 = m.get_meta(&"range", Vector2.ZERO)
		chunks.append({index = i, tris = tris, surfaces = m.get_surface_count(), center = _v(box.get_center()),
			size = _v(box.size), aabb = box, begin = r.x, end = r.y})
		if tris > b.budget_chunk_tris:
			problems.append(_problem("warning", "chunk_over_budget", "chunk %d has %d tris (budget %d)" % [i, tris,
				b.budget_chunk_tris], box.get_center()))
	# Props: meshes in the scene that aren't the level's own (lanterns, hangs, dressing).
	var props := {}
	var prop_boxes := []
	# Batched props (stalls, signs) count as the game draws them: PropBatch's merged meshes.
	var batched: Array[MeshInstance3D] = []
	var all: Array = scene.find_children("*", "MeshInstance3D", true, false)
	for mi: MeshInstance3D in all.duplicate():
		if mi.get_parent() and mi.get_parent().is_in_group(PropBatch.GROUP) and mi.mesh != null and mi.is_visible_in_tree():
			batched.append(mi)
			all.erase(mi)
	for mi in PropBatch.merge(batched):
		mi.name = "PropBatch"
		all.append(mi)
	for mi: MeshInstance3D in all:
		var merged: bool = not mi.is_inside_tree()
		if mi.mesh == null or (not merged and (not mi.is_visible_in_tree() or (root.is_ancestor_of(mi) and not _hung(mi, root)))):
			continue
		var tris := mi.mesh.get_faces().size() / 3
		var key := "PropBatch %d" % prop_boxes.size() if merged else (mi.mesh.resource_path if mi.mesh.resource_path != "" else String(scene.get_path_to(mi)))
		var p: Dictionary = props.get_or_add(key, {mesh = key, tris = tris, surfaces = mi.mesh.get_surface_count(), instances = 0})
		p.instances += 1
		prop_boxes.append({aabb = (Transform3D.IDENTITY if merged else mi.global_transform) * mi.get_aabb(), tris = tris, surfaces = mi.mesh.get_surface_count(),
			begin = mi.visibility_range_begin, end = mi.visibility_range_end})
	for mi: MeshInstance3D in all:
		if not mi.is_inside_tree():
			mi.free()
	# Views.
	var fog = scene.get(&"fog")
	var far: float = fog.end if fog != null and fog.get(&"end") != null else 150.0
	var spots := _sample_spots(meshes, xf, scene)
	var occluders := _occluder_boxes(data, xf)
	var views := []
	for s in spots:
		for k in YAWS:
			var yaw := TAU * k / YAWS
			var v := _view(s.position + Vector3.UP * EYE, yaw, far, chunks, prop_boxes, occluders)
			v.spot = s.kind
			views.append(v)
	views.sort_custom(func(a, c): return a.tris > c.tris)
	var over_warn := views.filter(func(v): return v.tris > b.budget_view_tris)
	var over_hard := views.filter(func(v): return v.tris > b.budget_view_tris_hard)
	var over_draws := views.filter(func(v): return v.draw_calls > b.budget_draw_calls)
	if not over_hard.is_empty():
		problems.append(_problem("error", "view_over_hard_budget", "%d of %d sampled views over %d tris (worst %d)" % [
			over_hard.size(), views.size(), b.budget_view_tris_hard, views[0].tris], views[0].position))
	elif not over_warn.is_empty():
		problems.append(_problem("warning", "view_over_budget", "%d of %d sampled views over %d tris (worst %d)" % [
			over_warn.size(), views.size(), b.budget_view_tris, views[0].tris], views[0].position))
	if not over_draws.is_empty():
		var worst: Dictionary = over_draws.reduce(func(a, c): return a if a.draw_calls >= c.draw_calls else c)
		problems.append(_problem("warning", "draw_calls_over_budget", "%d sampled views over %d draw calls (worst %d)" % [
			over_draws.size(), b.budget_draw_calls, worst.draw_calls], worst.position))
	# The level as edited: heaviest brushes, slivers.
	var brushes := []
	var editor_tris := 0
	var editor_faces := 0
	for bi in editor_data.brushes.size():
		var br: LevelBrush = editor_data.brushes[bi]
		if br == null:
			continue
		var t := 0
		var slivers := 0
		for f in br.get_face_count():
			t += br.face_counts[f] - 2
			var r := br.get_face_planar_rect(f)
			if minf(r.size.x, r.size.y) < SLIVER:
				slivers += 1
		editor_tris += t
		editor_faces += br.get_face_count()
		var built: LevelBrush = data.brushes[bi] if bi < data.brushes.size() else null
		var where := br.transform * (br.vertices[0] if not br.vertices.is_empty() else Vector3.ZERO)
		brushes.append({index = bi, kind = _kind(br), tag = String(br.tag), faces = br.get_face_count(), tris = t,
			build_faces = built.get_face_count() if built else 0, slivers = slivers, position = _v(xf * where)})
		if slivers > 50:
			problems.append(_problem("info", "sliver_faces", "brush %d (%s) has %d faces thinner than %.2f m: run Clean Up" % [
				bi, _kind(br), slivers, SLIVER], xf * where))
	brushes.sort_custom(func(a, c): return a.tris > c.tris)
	if stats.get("degenerate_tris", 0) > 0:
		problems.append(_problem("info", "degenerate_tris", "%d degenerate triangles dropped by the bake" % stats.degenerate_tris, null))
	for i in editor_data.textures.size():
		if editor_data.textures[i] == null:
			problems.append(_problem("error", "missing_texture", "texture slot %d didn't load" % i, null))
	# Collision by what it comes from (the build's copy: hidden faces already gone).
	var collision := {ground = 0, houses = 0, doors_windows = 0, fences_ropes = 0, other = 0}
	for br: LevelBrush in data.brushes:
		if br == null or br.bake_mode == LevelBrush.BakeMode.VISUAL_ONLY:
			continue
		var cat := "houses" if br.is_house() else ("doors_windows" if br.opening_spec() != null else \
			("fences_ropes" if br.is_fence() or br.is_rope() else ""))
		for f in br.get_face_count():
			if not br.face_collides(f) or br.get_face_lod(f) in [LevelBrush.LOD_FAR, LevelBrush.LOD_DETAIL_FAR]:
				continue
			var key := cat
			if key == "":
				key = "ground" if (br.transform.basis * br.get_face_normal(f)).normalized().y > 0.7 else "other"
			collision[key] += br.face_counts[f] - 2
	var prop_list := props.values()
	prop_list.sort_custom(func(a, c): return a.tris * a.instances > c.tris * c.instances)
	for c in chunks:
		c.erase("aabb")
	return {
		scene = scene_path, level = String(scene.get_path_to(root)) if scene != root else ".", bake_ms = bake_ms,
		editor = {brushes = brushes.size(), faces = editor_faces, tris = editor_tris},
		build = {tris = stats.get("baked_tris", 0), verts = stats.get("baked_verts", 0), surfaces = stats.get("surfaces", 0),
			chunks = stats.get("chunks", meshes.size()), collision_tris = stats.get("collision_tris", 0), collision_by_source = collision,
			hidden_ground_faces = stats.get("hidden_ground_faces", 0), hidden_wall_faces = stats.get("hidden_wall_faces", 0),
			occluders = occluders.size(),
			faces_before_simplify = stats.get("simplified_from", 0), faces_after_simplify = stats.get("simplified_to", 0),
			light_grid = float(ProjectSettings.get_setting("n64/build/light_grid", 4.0))},
		chunks = chunks, heaviest_brushes = brushes.slice(0, 10), props = prop_list.slice(0, 20),
		views = {sampled = views.size(), fog_end = far, fov = FOV, eye_height = EYE,
			over_budget = over_warn.size(), over_hard_budget = over_hard.size(), over_draw_calls = over_draws.size(),
			worst = views.slice(0, 10).map(func(v): return {position = _v(v.position), yaw_degrees = roundi(rad_to_deg(v.yaw)),
				tris = v.tris, tris_unoccluded = v.tris_unoccluded, draw_calls = v.draw_calls, chunks = v.chunks, prop_tris = v.prop_tris,
				spot = v.spot})},
		problems = problems,
	}


## Writes report.json + summary.md for `levels` under build_reports/<time>_<label>/.
## Returns the folder (res:// path).
static func write(levels: Array, label: String, kind: String) -> String:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var dir := DIR + "%s_%s/" % [stamp, label.validate_filename()]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	# Not a part of the project: Godot neither imports nor exports it.
	var ignore := ProjectSettings.globalize_path(DIR + ".gdignore")
	if not FileAccess.file_exists(ignore):
		FileAccess.open(ignore, FileAccess.WRITE)
	var errors := 0
	var warnings := 0
	for l in levels:
		for p in l.problems:
			errors += 1 if p.severity == "error" else 0
			warnings += 1 if p.severity == "warning" else 0
	var report := {kind = kind, generated = Time.get_datetime_string_from_system(), godot = Engine.get_version_info().string,
		budgets = budgets(), errors = errors, warnings = warnings, levels = levels,
		notes = "Views: camera at eye height on sampled floor spots and spawn points, %d directions each, chunks culled by their bounds out to the zone's fog end; props counted when their bounds are in view. Editor numbers are the brushes as authored; build numbers are what ships." % YAWS}
	var f := FileAccess.open(ProjectSettings.globalize_path(dir + "report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "\t", false))
	f = FileAccess.open(ProjectSettings.globalize_path(dir + "summary.md"), FileAccess.WRITE)
	f.store_string(_summary(report))
	return dir


static func _summary(r: Dictionary) -> String:
	var b: Dictionary = r.budgets
	var lines := ["# Build report (%s)" % r.kind, "", "%s · %d error(s), %d warning(s) · budgets: view %d (hard %d) tris, chunk %d tris, %d draw calls" % [
		r.generated, r.errors, r.warnings, b.budget_view_tris, b.budget_view_tris_hard, b.budget_chunk_tris, b.budget_draw_calls], ""]
	lines.append("| Level | Editor tris | Build tris | Chunks | Collision tris | Worst view tris | Views over budget | Bake |")
	lines.append("|---|---|---|---|---|---|---|---|")
	for l in r.levels:
		var worst: int = l.views.worst[0].tris if not l.views.worst.is_empty() else 0
		lines.append("| %s (%s) | %d | %d | %d | %d | %d | %d / %d | %.1f s |" % [l.scene.get_file(), l.level, l.editor.tris,
			l.build.tris, l.build.chunks, l.build.collision_tris, worst, l.views.over_budget, l.views.sampled, l.bake_ms / 1000.0])
	for l in r.levels:
		var cb: Dictionary = l.build.get("collision_by_source", {})
		if not cb.is_empty():
			lines.append("")
			lines.append("%s: collision tris by source: ground %d, houses %d, doors / windows %d, fences / ropes %d, other %d. Hidden faces removed: %d ground, %d walls. Occluders: %d." % [
				l.scene.get_file(), cb.ground, cb.houses, cb.doors_windows, cb.fences_ropes, cb.other,
				l.build.get("hidden_ground_faces", 0), l.build.get("hidden_wall_faces", 0), l.build.get("occluders", 0)])
	for l in r.levels:
		if l.problems.is_empty():
			continue
		lines.append_array(["", "## %s (%s)" % [l.scene.get_file(), l.level]])
		for p in l.problems:
			lines.append("- **%s** %s%s" % [p.severity, p.message, (" at %s" % str(p.position)) if p.position != null else ""])
	return "\n".join(lines) + "\n"


## Floor spots to stand on: one per SAMPLE_CELL cell of upward-facing baked floor (the
## highest in the cell), plus the zone's spawn points.
static func _sample_spots(meshes: Array[ArrayMesh], xf: Transform3D, scene: Node) -> Array:
	var cells := {}
	# With the ground tagged (GroundLOD's near ground), stand only on the ground: roofs face
	# up too, and views from rooftops (seeing the whole level) aren't where the player is.
	var ground: Array[ArrayMesh] = []
	for m in meshes:
		if m.get_meta(&"ground", false):
			ground.append(m)
	for m in (ground if not ground.is_empty() else meshes):
		var faces := PackedVector3Array()
		if ground.is_empty():
			faces = m.get_faces()
		else:
			# Only the ground's surfaces (a near mesh also holds the houses near it).
			for si in m.get_surface_count():
				if m.surface_get_name(si) != "ground":
					continue
				var arr := m.surface_get_arrays(si)
				var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var ix: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
				for i in ix:
					faces.append(verts[i])
		for t in range(0, faces.size(), 3):
			var a := xf * faces[t]
			var bb := xf * faces[t + 1]
			var c := xf * faces[t + 2]
			var n := (bb - a).cross(c - a)
			if n.length_squared() < 1e-8 or absf(n.normalized().y) < 0.7:
				continue
			var centre := (a + bb + c) / 3.0
			var key := Vector2i(floori(centre.x / SAMPLE_CELL), floori(centre.z / SAMPLE_CELL))
			if not cells.has(key) or centre.y > cells[key].y:
				cells[key] = centre
	var out := []
	for k in cells:
		out.append({position = cells[k], kind = "floor"})
	for sp in scene.find_children("*", "Node3D", true, false):
		if sp is SpawnPoint:
			out.append({position = sp.global_position, kind = "spawn"})
	return out


## One camera: tris, draw calls and chunks in view (whole chunks, as the game culls them).
static func _view(eye: Vector3, yaw: float, far: float, chunks: Array, props: Array, occluders := []) -> Dictionary:
	var planes := _frustum(eye, Basis(Vector3.UP, yaw), far)
	var tris := 0
	var unoccluded := 0
	var draws := 0
	var seen := []
	# Nearest occluders first: they block most.
	var occ := occluders.filter(func(o): return eye.distance_to(o.centre) < far + o.radius)
	occ.sort_custom(func(a, c): return eye.distance_squared_to(a.centre) < eye.distance_squared_to(c.centre))
	for c in chunks:
		if _in_view(c.aabb, planes) and _in_range(eye, c):
			unoccluded += c.tris
			if _occluded(eye, c.aabb, occ):
				continue
			tris += c.tris
			draws += c.surfaces
			seen.append(c.index)
	var prop_tris := 0
	for p in props:
		if _in_view(p.aabb, planes) and _in_range(eye, p):
			unoccluded += p.tris
			if _occluded(eye, p.aabb, occ):
				continue
			prop_tris += p.tris
			draws += p.surfaces
	return {position = eye, yaw = yaw, tris = tris + prop_tris, tris_unoccluded = unoccluded, prop_tris = prop_tris,
		draw_calls = draws, chunks = seen}


## The house occluders (LevelRoot.house_occluder) as oriented boxes in world space:
## {inv (world -> box), half (extents), centre, radius}.
static func _occluder_boxes(data: LevelData, xf: Transform3D) -> Array:
	var out := []
	for b: LevelBrush in data.brushes:
		if b == null or not b.is_house():
			continue
		var h := b.house
		# As LevelRoot.house_occluder: a shop's box stops short of its open front (+Z).
		var hd := h.depth * 0.5 - 0.05
		var front := hd - LevelRoot.shop_inset(h)
		if front + hd < 0.5:
			continue
		var half := Vector3(h.width * 0.5 - 0.05, (h.wall_height() - 0.1) * 0.5, (front + hd) * 0.5)
		var box_xf := xf * b.transform * Transform3D(Basis(), Vector3(0, half.y, (front - hd) * 0.5))
		out.append({inv = box_xf.affine_inverse(), half = half, centre = box_xf.origin, radius = half.length()})
	return out


## Whether every sample point of `box` (its corners, face centres and centre) is hidden from
## `eye` behind an occluder, like the engine's occlusion test (whole instance or nothing).
static func _occluded(eye: Vector3, box: AABB, occ: Array) -> bool:
	if occ.is_empty():
		return false
	var lo := box.position + box.size * 0.02
	var hi := box.end - box.size * 0.02
	for x in [lo.x, (lo.x + hi.x) * 0.5, hi.x]:
		for y in [lo.y, hi.y]:
			for z in [lo.z, (lo.z + hi.z) * 0.5, hi.z]:
				if not _blocked(eye, Vector3(x, y, z), occ):
					return false
	return true


static func _blocked(eye: Vector3, p: Vector3, occ: Array) -> bool:
	for o in occ:
		var inv: Transform3D = o.inv
		var a: Vector3 = inv * eye
		var d: Vector3 = inv * p - a
		var half: Vector3 = o.half
		var t0 := 0.0
		var t1 := 0.999  # the point itself may sit on the box
		var hit := true
		for k in 3:
			if absf(d[k]) < 1e-9:
				if absf(a[k]) > half[k]:
					hit = false
					break
				continue
			var ta := (-half[k] - a[k]) / d[k]
			var tb := (half[k] - a[k]) / d[k]
			t0 = maxf(t0, minf(ta, tb))
			t1 = minf(t1, maxf(ta, tb))
			if t0 > t1:
				hit = false
				break
		if hit and t0 > 0.001:
			return true
	return false


## Within a mesh's visibility range from `eye` (begin / end 0 = open), measured to the
## centre of its box like the engine does.
static func _in_range(eye: Vector3, m: Dictionary) -> bool:
	var d := eye.distance_to((m.aabb as AABB).get_center())
	return d >= m.get("begin", 0.0) and (m.get("end", 0.0) <= 0.0 or d < m.end)


## The view's planes, normals pointing out (vertical FOV, like Camera3D's default).
static func _frustum(eye: Vector3, basis: Basis, far: float) -> Array[Plane]:
	var f := -basis.z
	var r := basis.x
	var u := basis.y
	var tv := tan(deg_to_rad(FOV) * 0.5)
	var th := tv * ASPECT
	var out: Array[Plane] = [Plane(-f, eye + f * 0.05), Plane(f, eye + f * far)]
	out.append(Plane(u.cross(f - r * th).normalized(), eye))
	out.append(Plane((f + r * th).cross(u).normalized(), eye))
	out.append(Plane(r.cross(f + u * tv).normalized(), eye))
	out.append(Plane((f - u * tv).cross(r).normalized(), eye))
	return out


static func _in_view(box: AABB, planes: Array[Plane]) -> bool:
	for pl in planes:
		var outside := true
		for i in 8:
			if not pl.is_point_over(box.get_endpoint(i)):
				outside = false
				break
		if outside:
			return false
	return true


## Whether `mi` is a scene hung on one of `root`'s ropes (its RopeHangs node), not the
## level's own geometry.
static func _hung(mi: Node, root: LevelRoot) -> bool:
	var n := mi.get_parent()
	while n and n != root:
		if n.name.begins_with("RopeHangs"):
			return true
		n = n.get_parent()
	return false


static func _kind(b: LevelBrush) -> String:
	if b.is_fence():
		return "fence"
	if b.is_rope():
		return "rope"
	if b.is_passage():
		return "passage"
	if b.is_door():
		return "door"
	if b.blend_file != "":
		return "set_piece"
	return "brush"


static func _problem(severity: String, kind: String, message: String, at) -> Dictionary:
	return {severity = severity, kind = kind, message = message, position = _v(at) if at is Vector3 else null}


static func _v(p: Vector3) -> Array:
	return [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)]

