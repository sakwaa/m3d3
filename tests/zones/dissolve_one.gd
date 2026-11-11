extends Node
## The Blender pass on one brush (TAG) of a level (LEVEL), alone: its faces by texture before
## and after, and the faces Blender returned.


func _ready() -> void:
	var src: LevelData = ResourceLoader.load(OS.get_environment("LEVEL"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var d := LevelData.new()
	d.textures = src.textures
	for b in src.brushes:
		if b and String(b.tag) == OS.get_environment("TAG"):
			d.brushes = [b.duplicate()] as Array[LevelBrush]
	var b: LevelBrush = d.brushes[0]
	print("before: ", _by_tex(d, b))
	var job := BlenderDissolve._job(b)
	var faces: Array = job.mesh.faces
	var mud := []
	for f in faces.size():
		if b.get_face_texture(f) != b.get_face_texture(20):
			mud.append(f)
	print("floor-ish faces (not texture of f20): ", mud.size(), " groups: ", mud.map(func(f): return job.mesh.group[f]).slice(0, 5))
	var r := BlenderDissolve.dissolve(d)
	print("dissolve: ", r)
	print("after: ", _by_tex(d, d.brushes[0]))
	var raw = JSON.parse_string(FileAccess.get_file_as_string(ProjectSettings.globalize_path("user://blender_dissolve_out.json")))
	var srcs: Array = raw.meshes[0].src
	print("src faces returned: ", srcs.size(), " floor srcs among them: ", srcs.filter(func(s): return int(s) in mud).size())
	get_tree().quit()


func _by_tex(d: LevelData, b: LevelBrush) -> Dictionary:
	var m := {}
	for f in b.get_face_count():
		var t := b.get_face_texture(f)
		var k: String = d.textures[t].resource_path.get_file() if t >= 0 else "none"
		m[k] = m.get(k, 0) + 1
	return m
