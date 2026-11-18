extends SceneTree
## Prints every N64Texture using lod_mode 3 (Hi-res) as a comma list.
func _init() -> void:
	var out: Array[String] = []
	for d in DirAccess.get_directories_at("res://textures"):
		if d.begins_with("_") or d == "detail":
			continue
		var stack := ["res://textures/" + d]
		while not stack.is_empty():
			var dir: String = stack.pop_back()
			for sub in DirAccess.get_directories_at(dir):
				stack.append(dir + "/" + sub)
			for f in DirAccess.get_files_at(dir):
				if f.ends_with(".res"):
					var t = load(dir + "/" + f)
					if t is N64Texture and t.lod_mode == 3:
						out.append(dir + "/" + f)
	print("LOD3 ", ",".join(out))
	quit()
