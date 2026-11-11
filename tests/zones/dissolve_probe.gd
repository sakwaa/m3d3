extends Node
## How much Blender's limited dissolve would save on a level: the level as Quick Play bakes
## it (hidden faces culled), our BuildSimplify, and Blender 5's dissolve (geometry only:
## faces merge within their texture / UV / surface / bake group), counted in triangles.
##   ZONE=res://...tscn godot --headless --path . tests/zones/dissolve_probe.tscn

const BLENDER := "/Applications/Blender.app/Contents/MacOS/Blender"
const SCRIPT := "res://tools/blender_dissolve/dissolve.py"


func _ready() -> void:
	var scene: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	var root: LevelRoot = scene.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	var copy: Dictionary = LevelBaker._culled_copy(root.data)
	var data: LevelData = copy.data
	var raw := 0
	var meshes := []
	var brushes := []
	for b in data.brushes:
		if b == null or b.is_prop() or b.bake_mode == LevelBrush.BakeMode.COLLISION_ONLY:
			continue
		b.ensure_geometry()
		var faces := b.get_faces()
		var verts := []
		for v in b.vertices:
			verts.append_array([v.x, v.y, v.z])
		var fl := []
		var groups := []
		for f in faces.size():
			fl.append(Array(faces[f]))
			groups.append(hash([b.get_face_texture(f), b.face_uv[f] if f < b.face_uv.size() else Vector4.ZERO,
				b.get_face_surface(f), b.face_bake[f] if f < b.face_bake.size() else 0, b.get_face_lod(f)]) & 0x7fff)
			raw += faces[f].size() - 2
		meshes.append({verts = verts, faces = fl, group = groups})
		brushes.append(b)
	var t0 := Time.get_ticks_msec()
	var simp: LevelData = BuildSimplify.optimized_copy(data).data
	print("BuildSimplify %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	var ours := 0
	for b in simp.brushes:
		if b == null or b.is_prop() or b.bake_mode == LevelBrush.BakeMode.COLLISION_ONLY:
			continue
		for f in b.get_faces():
			ours += f.size() - 2
	var tmp := ProjectSettings.globalize_path("user://dissolve_in.json")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://dissolve_out.json"))
	var outp := ProjectSettings.globalize_path("user://dissolve_out.json")
	var fh := FileAccess.open(tmp, FileAccess.WRITE)
	fh.store_string(JSON.stringify({meshes = meshes}))
	fh.close()
	var t := Time.get_ticks_msec()
	var log := []
	var code := OS.execute(BLENDER, ["-b", "--factory-startup", "--python", ProjectSettings.globalize_path(SCRIPT), "--", tmp, outp, "1.0"], log, true)
	var secs := (Time.get_ticks_msec() - t) / 1000.0
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(outp)) if FileAccess.file_exists(outp) else null
	if not parsed is Dictionary:
		print("blender failed (exit %d):\n%s" % [code, "\n".join(log).right(1500)])
		get_tree().quit()
		return
	var res: Dictionary = parsed
	var blend := 0
	for m in res.meshes:
		for f in m.faces:
			blend += f.size() - 2
	print("blender exit %d in %.1f s" % [code, secs])
	print("triangles: raw %d | BuildSimplify %d | Blender limited dissolve %d (geometry only; before relighting)" % [raw, ours, blend])
	get_tree().quit()
