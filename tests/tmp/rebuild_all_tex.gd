extends SceneTree
## Rebuilds every N64Texture (exactly that class) with a source image under res://textures
## and res://game: new N64 mip chains. Reports textures whose level 0 changed too.
##   DRY=1: list only.
var _changed := []
var _done := 0
var _skipped := {}

func _init() -> void:
	var files := []
	for root in ["res://textures", "res://game"]:
		_scan(root, files)
	var dry := OS.get_environment("DRY") != ""
	var t0 := Time.get_ticks_msec()
	for p in files:
		var r = ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_REUSE)
		if not (r is N64Texture) or (r as Object).get_script() != N64Texture:
			continue
		var t := r as N64Texture
		if t.source_path == "" or not FileAccess.file_exists(t.source_path):
			_skipped[p] = "no source"
			continue
		if dry:
			_done += 1
			continue
		var before := t.get_image().duplicate() as Image
		before.convert(Image.FORMAT_RGBA8)
		before.clear_mipmaps()
		var err := t.rebuild()
		if err != OK:
			_skipped[p] = error_string(err)
			continue
		_done += 1
		var after_t: Texture2D = ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE)
		var after := after_t.get_image().duplicate() as Image
		after.convert(Image.FORMAT_RGBA8)
		after.clear_mipmaps()
		if before.get_size() != after.get_size() or before.get_data() != after.get_data():
			_changed.append("%s %s -> %s" % [p, before.get_size(), after.get_size()])
	print("REBUILT %d in %d s, skipped %d" % [_done, (Time.get_ticks_msec() - t0) / 1000, _skipped.size()])
	for c in _changed:
		print("LEVEL0 CHANGED ", c)
	var reasons := {}
	for k in _skipped:
		reasons[_skipped[k]] = int(reasons.get(_skipped[k], 0)) + 1
	print("SKIP REASONS ", reasons)
	quit()

func _scan(dir: String, out: Array) -> void:
	for d in DirAccess.get_directories_at(dir):
		if d.begins_with("_") or d.begins_with("."):
			continue
		_scan(dir + "/" + d, out)
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".res") or f.ends_with(".tres"):
			out.append(dir + "/" + f)
