extends Node
## Retextures a level's faces wearing palette index FROM (UP=1: only upward ones) to the
## texture at TO (res path), keeping lighting; saves the level and bakes (quick).
##   LEVEL=res://..._level.res FROM=12 TO=res://textures/grass/157_green_grass.res tools/godot_run.sh --headless --path . tests/zones/retex_faces.tscn


func _ready() -> void:
	var path := OS.get_environment("LEVEL")
	var uid := ResourceLoader.get_resource_uid(path)
	var data: LevelData = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var from := int(OS.get_environment("FROM"))
	var tex: Texture2D = load(OS.get_environment("TO"))
	var to := data.textures.find(tex)
	if to < 0:
		push_error("%s isn't in the level's palette" % tex.resource_path)
		get_tree().quit(1)
		return
	var up_only := OS.get_environment("UP") != ""
	var changed := 0
	for b: LevelBrush in data.brushes:
		if b == null:
			continue
		var ft := PackedInt32Array()
		var hit := false
		for f in b.get_face_count():
			var t := b.get_face_texture(f)
			if t == from and (not up_only or (b.transform.basis * b.get_face_normal(f)).normalized().y > 0.7):
				t = to
				hit = true
				changed += 1
			ft.append(t)
		if hit:
			b.face_textures = ft
	var res := LevelBaker.bake(data, true)
	data.baked_mesh = res.mesh
	data.baked_chunks = res.chunks
	data.set_baked_collision(res)
	var err := ResourceSaver.save(data, path, ResourceSaver.FLAG_COMPRESS)
	if uid != ResourceUID.INVALID_ID:
		ResourceSaver.set_uid(path, uid)
	print("%d faces retextured; saved %s: %s" % [changed, path, error_string(err)])
	get_tree().quit()
