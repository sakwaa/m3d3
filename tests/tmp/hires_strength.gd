extends SceneTree
## Sets detail_strength on every texture using the Hi-res close-up mode (lod_mode 3).
func _init() -> void:
	var v := float(OS.get_environment("STRENGTH"))
	var n := 0
	for d in DirAccess.get_directories_at("res://textures"):
		if d.begins_with("_"):
			continue
		for f in DirAccess.get_files_at("res://textures/" + d):
			if not f.ends_with(".res"):
				continue
			var p := "res://textures/" + d + "/" + f
			var t = load(p)
			if t is N64Texture and t.lod_mode == 3:
				t.detail_strength = v
				ResourceSaver.save(t, p)
				n += 1
	print("STRENGTH set on ", n)
	quit()
