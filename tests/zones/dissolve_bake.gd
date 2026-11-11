extends Node
## Look test for a Blender-dissolve build (never touches the zone's own files): on a copy of
## the zone's level, hidden faces culled, every brush goes through Blender 5's limited
## dissolve (tools/blender_dissolve/dissolve.py: faces merge only within the same texture /
## UV / surface / bake / layer / LOD group; edges where painted colour or AO changes stay),
## then the copy is relit (timed keys, rain light) and baked, and saved to OUT (a .res) for
## tests/zones/shot.tscn LEVEL_OVERRIDE=OUT. Prints triangles before / after.
##   ZONE=res://...tscn OUT=/abs/path.res [ANGLE=1] [REFINE=0] godot --headless --path . tests/zones/dissolve_bake.tscn
## REFINE=m: before lighting, cut the dissolved faces on an m-metre grid (BrushCleanup), as the
## build's lighting grid does (0 = light the dissolved faces as they are).

const BLENDER := "/Applications/Blender.app/Contents/MacOS/Blender"
const SCRIPT := "res://tools/blender_dissolve/dissolve.py"


func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(zone)
	await get_tree().process_frame
	var root: LevelRoot = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	var copy: LevelData = LevelBaker._culled_copy(root.data).data
	var before := _tris(copy)
	# Brushes to dissolve: plain geometry (fences, ropes, exact-UV set pieces and corner-painted
	# brushes keep their faces).
	var meshes := []
	var brushes: Array[LevelBrush] = []
	var mask_faces := 0
	var painted_faces := 0
	for b in copy.brushes:
		if b == null or b.is_prop() or b.is_fence() or b.is_rope() or b.has_corner_uvs() or b.has_corner_colors() or b.blend_file != "":
			continue
		if b.bake_mode == LevelBrush.BakeMode.COLLISION_ONLY:
			continue
		b.ensure_geometry()
		var faces := b.get_faces()
		var verts := []
		for v in b.vertices:
			verts.append_array([v.x, v.y, v.z])
		var fl := []
		var groups := []
		# Faces with paint in their overlay masks (erased masks stay stored, all zero: those
		# don't count).
		var painted := {}
		for k: Vector2i in b.face_masks:
			var img: Image = b.face_masks[k]
			if img and not painted.has(k.x):
				var bytes := img.get_data()
				for byte in bytes:
					if byte > 8:
						painted[k.x] = true
						break
		mask_faces += b.face_masks.size()
		painted_faces += painted.size()
		for f in faces.size():
			fl.append(Array(faces[f]))
			var masked: bool = painted.has(f)
			# A face with painted masks stays itself (its own group).
			groups.append((f + 1) * 7919 if masked else (hash([b.get_face_texture(f), b.get_face_uv(f), b.get_face_surface(f),
				b.face_bake[f] if f < b.face_bake.size() else 0, b.get_face_lod(f),
				b.face_layer_sets[f] if f < b.face_layer_sets.size() else 0,
				b.face_pieces[f] if f < b.face_pieces.size() else -1]) & 0x3fffffff))
		# Edges across a change in painted colour or AO stay.
		var sharp := []
		for f in faces.size():
			var ids: PackedInt32Array = faces[f]
			for k in ids.size():
				var a := ids[k]
				var c := ids[(k + 1) % ids.size()]
				if _paint(b, a) != _paint(b, c):
					sharp.append([a, c])
		meshes.append({verts = verts, faces = fl, group = groups.map(func(g): return g % 32760), sharp = sharp})
		brushes.append(b)
	print("masks: %d stored, %d faces with paint in them" % [mask_faces, painted_faces])
	var inp := ProjectSettings.globalize_path("user://dissolve_in.json")
	var outp := ProjectSettings.globalize_path("user://dissolve_out.json")
	DirAccess.remove_absolute(outp)
	var fh := FileAccess.open(inp, FileAccess.WRITE)
	fh.store_string(JSON.stringify({meshes = meshes}))
	fh.close()
	var angle := OS.get_environment("ANGLE") if OS.get_environment("ANGLE") != "" else "1.0"
	var log := []
	var code := OS.execute(BLENDER, ["-b", "--factory-startup", "--python", ProjectSettings.globalize_path(SCRIPT), "--", inp, outp, angle], log, true)
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(outp)) if FileAccess.file_exists(outp) else null
	if not parsed is Dictionary:
		print("blender failed (exit %d): %s" % [code, "\n".join(log).right(1500)])
		get_tree().quit()
		return
	for i in brushes.size():
		var b := brushes[i]
		var r: Dictionary = parsed.meshes[i]
		var faces: Array[PackedInt32Array] = []
		var map := PackedInt32Array()
		for k in r.faces.size():
			faces.append(PackedInt32Array(r.faces[k]))
			map.append(int(r.src[k]))
		b.hand_edited = true
		b.set_faces(faces)
		b.remap_faces(map)
		b.drop_unused_vertices()
	var dissolved := _tris(copy)
	var refine := float(OS.get_environment("REFINE")) if OS.get_environment("REFINE") != "" else 0.0
	if refine > 0.0:
		for b in brushes:
			var all: Array[int] = []
			for f in b.get_face_count():
				all.append(f)
			BrushCleanup.clean_up(b, all, refine, copy.mask_density, false)
	var refined := _tris(copy)
	# Relight the copy as Bake Lighting does.
	root.data = copy
	await get_tree().process_frame
	var lights := LevelLighting.gather_lights(zone)
	var occluders: Array = [root] + LevelLighting.dressing_occluders(zone)
	LevelLighting.bake_rain_light(root, occluders, lights)
	var schedule := LightingSchedule.load_project()
	if LevelData.mode_is_timed(copy.lighting_mode) and schedule:
		var baked_lights := lights
		if LevelData.mode_is_hybrid(copy.lighting_mode):
			baked_lights = lights.filter(func(l: Light3D): return l.light_bake_mode == Light3D.BAKE_STATIC)
		var keyed := LevelLighting.bake_keys(root, occluders, baked_lights, schedule)
		for brush in keyed:
			var arr: Array[PackedColorArray] = []
			arr.assign(keyed[brush])
			brush.corner_lighting_keys = arr
	var res := LevelBaker.bake(copy, false)
	copy.baked_mesh = res.mesh
	copy.baked_chunks = res.chunks
	copy.set_baked_collision(res)
	var err := ResourceSaver.save(copy, OS.get_environment("OUT"), ResourceSaver.FLAG_COMPRESS)
	print("brush triangles: culled %d -> dissolved %d -> refined (%.1f m) %d | baked %d | saved %s" % [before, dissolved, refine, refined, res.stats.baked_tris, error_string(err)])
	get_tree().quit()


func _paint(b: LevelBrush, v: int) -> Array:
	var c: Color = b.vertex_colors[v] if v < b.vertex_colors.size() else Color.WHITE
	var ao: float = b.vertex_ao[v] if v < b.vertex_ao.size() else 1.0
	return [c.to_html(), snappedf(ao, 0.02)]


func _tris(d: LevelData) -> int:
	var n := 0
	for b in d.brushes:
		if b == null or b.is_prop() or b.bake_mode == LevelBrush.BakeMode.COLLISION_ONLY:
			continue
		for f in b.get_faces():
			n += f.size() - 2
	return n
