extends Node3D
## What the profiler's "Triangles" (RENDER_TOTAL_PRIMITIVES_IN_FRAME) is made of from one view:
## the total, then the drop with each kind of object hidden (level bake, grass, props, actors,
## the rest). LEVEL_OVERRIDE= a build copy (tests/zones/build_bake) to see Build & Play's.
##   ZONE=res://... CAM=x,y,z LOOK=x,y,z [LEVEL_OVERRIDE=...] godot --path . tests/zones/tri_breakdown.tscn


func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	if OS.get_environment("LEVEL_OVERRIDE") != "":
		var lr: Node = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
		lr.set(&"data", ResourceLoader.load(OS.get_environment("LEVEL_OVERRIDE"), "", ResourceLoader.CACHE_MODE_IGNORE))
	add_child(zone)
	var cam := Camera3D.new()
	cam.fov = 50.0
	add_child(cam)
	cam.position = _v(OS.get_environment("CAM"))
	cam.look_at(_v(OS.get_environment("LOOK")))
	cam.make_current()
	for i in 30:
		await RenderingServer.frame_post_draw
	var total := await _tris()
	print("method %s  total %d  draws %d" % [ProjectSettings.get_setting("rendering/renderer/rendering_method"), total,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])
	var groups := {}
	for g in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
		if not (g as GeometryInstance3D).is_visible_in_tree():
			continue
		var k := _kind(g)
		if not groups.has(k):
			groups[k] = []
		groups[k].append(g)
	if OS.get_environment("DETAIL") != "":
		var by := {}
		for g in groups.get(OS.get_environment("DETAIL"), []):
			var path := String(g.get_path())
			var key: String = path.get_slice("/", path.get_slice_count("/") - 2) + "/" + g.get_class() + ":" + String(g.name).left(12)
			by[key] = by.get(key, 0) + 1
		print("  detail: ", by)
	if OS.get_environment("HIDDEN") != "":
		# HIDDEN=1: every object drawn in this view, by whether it shows (hiding it changes
		# pixels) or is drawn for nothing (behind walls: what visibility culling could skip).
		await _hidden_report()
	for k in groups:
		for g in groups[k]:
			g.visible = false
		var t := await _tris()
		for g in groups[k]:
			g.visible = true
		print("  %-26s %5d tris (%d objects)" % [k, total - t, groups[k].size()])
	get_tree().quit()


func _kind(n: Node) -> String:
	var p := n
	while p:
		if p is Actor:
			return "actors"
		var s: Script = p.get_script()
		var path := s.resource_path if s else ""
		if path.contains("grass") or String(p.name).to_lower().contains("grass"):
			return "grass"
		if path.contains("/props/") or path.contains("prop_batch") or path.contains("world_tree") or path.contains("string_lights") \
				or path.contains("signpost") or path.contains("rope"):
			return "props"
		if p is LevelRoot:
			# Which of the level's children: the baked chunks, or a built node (door, window...).
			var c := n
			while c.get_parent() != p:
				c = c.get_parent()
			var cs: Script = c.get_script()
			var what := cs.resource_path.get_file().get_basename() if cs else c.get_class()
			if c is MeshInstance3D and cs == null:
				what = "baked chunk"
			return "level: " + what
		p = p.get_parent()
	return "other"


func _tris() -> int:
	for i in 3:
		await RenderingServer.frame_post_draw
	return int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))


func _v(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


func _hidden_report() -> void:
	var base := await _shot()
	var total := await _tris()
	var shown := 0
	var wasted := 0
	var lines := []
	for g in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
		if not (g as GeometryInstance3D).is_visible_in_tree():
			continue
		g.visible = false
		var t := await _tris()
		var img := await _shot()
		g.visible = true
		var drop := total - t
		if drop <= 0:
			continue
		var diff := 0
		for y in range(0, img.get_height(), 2):
			for x in range(0, img.get_width(), 2):
				if not img.get_pixel(x, y).is_equal_approx(base.get_pixel(x, y)):
					diff += 1
		var box := (g as GeometryInstance3D).get_aabb()
		box = (g as Node3D).global_transform * box
		if diff > 0:
			shown += drop
		else:
			wasted += drop
		var extra := ""
		if g is MeshInstance3D and (g as MeshInstance3D).mesh:
			var m := (g as MeshInstance3D).mesh
			extra = " range %s vis %s-%s surfaces %s" % [m.get_meta(&"range", "-"), (g as GeometryInstance3D).visibility_range_begin,
				(g as GeometryInstance3D).visibility_range_end, range(m.get_surface_count()).map(func(i): return (m as ArrayMesh).surface_get_name(i) if m is ArrayMesh else "")]
		lines.append([drop, "  %-6s %5d tris  %-22s centre %s size %s%s" % ["shows" if diff > 0 else "HIDDEN", drop, _kind(g).left(22),
			Vector3i(box.get_center()), Vector3i(box.size), extra]])
	lines.sort_custom(func(x, y): return x[0] > y[0])
	for l in lines.slice(0, 25):
		print(l[1])
	print("  drawn and showing %d tris, drawn but hidden %d tris" % [shown, wasted])


func _shot() -> Image:
	for i in 3:
		await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()
