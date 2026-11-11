extends Node
## Ground finish round trip on a level (LEVEL, not saved): apply, clear, and check every
## brush's vertices and paint masks are as they were.


func _ready() -> void:
	var d: LevelData = ResourceLoader.load(OS.get_environment("LEVEL"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var before := _snapshot(d)
	var gf := GroundFinish.new()
	d.ground_finish = gf
	gf.fill_textures()
	print("applied: ", gf.apply())
	var during := _snapshot(d)
	gf.clear()
	var after := _snapshot(d)
	var changed := 0
	for k in before:
		if before[k] != during.get(k):
			changed += 1
	var bad := []
	for k in before:
		if before[k] != after.get(k):
			bad.append(k)
	print("brushes changed by the finish: %d; not restored after clear: %d %s" % [changed, bad.size(), bad.slice(0, 5)])
	get_tree().quit()


func _snapshot(d: LevelData) -> Dictionary:
	var out := {}
	for i in d.brushes.size():
		var b: LevelBrush = d.brushes[i]
		if b == null:
			continue
		var masks := []
		for k in b.face_masks:
			masks.append([k, b.face_masks[k].get_data() if b.face_masks[k] else null])
		masks.sort_custom(func(a, c): return str(a[0]) < str(c[0]))
		out[i] = hash([b.vertices, masks])
	return out
