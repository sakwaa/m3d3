extends Node3D
## Which brush face is at a screen point (PX, PY: 0..1) from a camera (CAM, LOOK, FOV), in a
## zone with LEVEL_OVERRIDE: its brush, face, texture, corner UVs and colours.


func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	var lr: LevelRoot = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	if OS.get_environment("LEVEL_OVERRIDE") != "":
		lr.data = ResourceLoader.load(OS.get_environment("LEVEL_OVERRIDE"), "", ResourceLoader.CACHE_MODE_IGNORE)
	add_child(zone)
	var cam := Camera3D.new()
	cam.fov = float(OS.get_environment("FOV"))
	add_child(cam)
	var c := OS.get_environment("CAM").split(",")
	var l := OS.get_environment("LOOK").split(",")
	cam.position = Vector3(float(c[0]), float(c[1]), float(c[2]))
	cam.look_at(Vector3(float(l[0]), float(l[1]), float(l[2])))
	cam.make_current()
	await get_tree().process_frame
	var size := get_viewport().get_visible_rect().size
	for px in [float(OS.get_environment("PX")) - 0.01, float(OS.get_environment("PX")), float(OS.get_environment("PX")) + 0.01]:
		var sp := Vector2(px, float(OS.get_environment("PY"))) * size
		var from := cam.project_ray_origin(sp)
		var dir := cam.project_ray_normal(sp)
		var hit := lr.raycast(from, dir, true)
		while not hit.is_empty() and (hit.brush as LevelBrush).is_prop():  # (props are pick boxes)
			from = (hit.position as Vector3) + dir * 0.01
			hit = lr.raycast(from, dir, true)
		if hit.is_empty():
			print("no hit")
			continue
		var b: LevelBrush = hit.brush
		var f: int = hit.face
		var t := b.get_face_texture(f)
		var tex: Texture2D = lr.data.textures[t] if t >= 0 else null
		var name := (tex.resource_path.get_file() + " " + (str(tex.get(&"texture").resource_path.get_file()) if tex and tex.get(&"texture") else "")) if tex else "none"
		var first := 0
		for k in f:
			first += b.get_faces()[k].size()
		var uvs := []
		var cols := []
		for k in b.get_faces()[f].size():
			if b.has_corner_uvs():
				uvs.append(b.corner_uvs[first + k].snapped(Vector2.ONE * 0.01))
			if b.has_corner_colors():
				cols.append(b.corner_colors[first + k].to_html(false))
		print("%s face %d of %d  tex %s  corners %d  uv %s  col %s  face_uv %s" % [b.tag, f, b.get_face_count(), name, b.get_faces()[f].size(), uvs, cols, b.get_face_uv(f)])
	get_tree().quit()
